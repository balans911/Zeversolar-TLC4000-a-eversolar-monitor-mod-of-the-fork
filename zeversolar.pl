#! /usr/bin/perl
#
# Eversolar communications packet definition:
# 0xaa, 0x55,   # header
# 0x00, 0x00,   # source address
# 0x00, 0x00,   # destination address
# 0x00,         # control code
# 0x00,         # function code
# 0x00,         # data length
# 0x00...0x00   # data
# 0x00, 0x00    # checksum
#

use AppConfig;
use Time::HiRes;        # Used for timestamp precision
use JSON;               # Used by MQTT command response
use POSIX qw(strftime); # Used for timestamp formatting in MQTT
use File::Copy;
use POSIX;
use utf8;
use AnyEvent;
use AnyEvent::MQTT;
use LWP::UserAgent;     # Used for PVOutput, InfluxDB and Domoticz HTTP calls
use HTTP::Request;
use HTTP::Request::Common qw(POST GET);

#use warnings;

our $config = AppConfig->new();

# Basic and required settings
$config->define("configFile=s");
$config->define("options_debug=s");
$config->define("options_query_inverter_secs=s");
$config->define("options_log_file=s");
$config->define("options_output_to_log=s");
$config->define("options_clean_log=s");
$config->define("options_state_file=s");      # JSON state file for web dashboard
$config->define("options_communication_method=s");
$config->define("options_strings=s");
$config->define("options_power_limit_refresh_mins=s");

# Connection method: SERIAL only in this case - add eth2ser if needed.
$config->define("serial_port=s");

# MQTT (Home Assistant) config
$config->define("mqtt_enabled=s");
$config->define("mqtt_inverter_model=s");
$config->define("mqtt_host=s");
$config->define("mqtt_port=s");
$config->define("mqtt_enable_pass=s");
$config->define("mqtt_user=s");
$config->define("mqtt_password=s");
$config->define("mqtt_topic_prefix=s");
$config->define("mqtt_ha_discovery=s");
$config->define("mqtt_command_topic=s");
$config->define("mqtt_response_topic=s");

# PVOutput config
$config->define("pvoutput_enabled=s");
$config->define("pvoutput_api_key=s");
$config->define("pvoutput_system_id=s");
$config->define("pvoutput_interval_mins=s");   # Upload interval in minutes (5 = minimum for free accounts)

# InfluxDB config
$config->define("influxdb_enabled=s");
$config->define("influxdb_host=s");
$config->define("influxdb_port=s");
$config->define("influxdb_database=s");         # InfluxDB v1 database name
$config->define("influxdb_measurement=s");      # Measurement / table name
$config->define("influxdb_user=s");
$config->define("influxdb_password=s");
$config->define("influxdb_version=s");          # "1" for InfluxDB 1.x, "2" for InfluxDB 2.x
$config->define("influxdb_org=s");              # InfluxDB 2.x org
$config->define("influxdb_bucket=s");           # InfluxDB 2.x bucket
$config->define("influxdb_token=s");            # InfluxDB 2.x token

# Domoticz config
$config->define("domoticz_enabled=s");
$config->define("domoticz_host=s");
$config->define("domoticz_port=s");
$config->define("domoticz_idx_power=s");        # IDX of kWh / Power device
$config->define("domoticz_idx_temp=s");         # IDX of temperature sensor (optional)
$config->define("domoticz_use_https=s");        # 1 = use https, 0 = http
$config->define("domoticz_user=s");             # optional basic auth username
$config->define("domoticz_password=s");         # optional basic auth password


# MQTT listening features
our $mqtt_limit_command;            # shared variable to hold latest power limit request
our $mqtt;                          # the MQTT client object
our $last_power_limit = 99;        # Power limit variable to use for when inverter is registered
our $sleep_time_cnt = 0;            # Counter for sleep time when no inverters are registered

# PVOutput tracking
our $pvoutput_last_upload_min = -1; # Track last upload minute to avoid duplicate uploads

$config->define("configFile=s");
$config->args();

if ( $config->configFile eq '' ) {
    $config->configFile('zeversolar.ini');
}

-e $config->configFile or die "Configfile '", $config->configFile, "' not found\n";

$config->file( $config->configFile );
pmu_log( "Severity 1, Configfile is: " . $config->configFile );

# Ensure that MQTT listener is enabled if enabled in eversolar.ini
if ($config->mqtt_enabled && $config->mqtt_enabled == 1) {
    init_mqtt_command_listener();
}

# Control codes and function codes
%CTRL_FUNC_CODES = (
    "REGISTER" => {    # CONTROL CODE 0x10
        "OFFLINE_QUERY" => {
            "REQUEST"  => [ 0x10, 0x00 ],
            "RESPONSE" => [ 0x10, 0x80 ]
        },
        "SEND_REGISTER_ADDRESS" => {
            "REQUEST"  => [ 0x10, 0x01 ],
            "RESPONSE" => [ 0x10, 0x81 ]
        },
        "RE_REGISTER" => {
            "REQUEST"  => [ 0x10, 0x04 ],
            "RESPONSE" => ""
        }
    },
    "READ" => {    # CONTROL CODE 0x11
        "QUERY_INVERTER_ID" => {
            "REQUEST"  => [ 0x11, 0x03 ],
            "RESPONSE" => [ 0x11, 0x83 ]
        },
        "QUERY_NORMAL_INFO" => {
            "REQUEST"  => [ 0x11, 0x02 ],
            "RESPONSE" => [ 0x11, 0x82 ]
        },
        "QUERY_DESCRIPTION" => {
            "REQUEST"  => [ 0x11, 0x00 ],
            "RESPONSE" => [ 0x11, 0x80 ]
        },
    },
    "WRITE" => {    # CONTROL CODE 0x12
    },
    "EXECUTE" => {    # CONTROL CODE 0x13
        "LIMIT_POWER" => {
            "REQUEST"  => [ 0x13, 0x20 ],
            "RESPONSE" => ""
        },
    }
);

# DATA_BYTES mapping fully verified against live TLC4000 24-word packet:
#
# Packet (48 data bytes = 24 words after parse_packet) — verified TLC4000:
# [0]  TEMP        /10   -> °C
# [1]  VPV2        /10   -> V   (DC string 2 voltage)
# [2]  VPV1        /10   -> V   (DC string 1 voltage)
# [3]  IPV1        /10   -> A   (DC string 1 current)
# [4]  IPV2        /10   -> A   (DC string 2 current)
# [5]  OP_MODE           -> status flag (4 = normal)
# [6]  HOURS_UP          -> total uptime in hours
# [7]  NA_0              -> always 0
# [8]  E_TOTAL low word  -> combined with [10]: E_TOTAL=(word[10]*65536+word[8])/10 kWh
# [9]  PAC               -> instantaneous AC power in W
# [10] E_TOTAL high word -> see [8]
# [11] E_TODAY     /100  -> kWh produced today
# [12] IAC1        /10   -> A   (AC phase 1 current)
# [13] VAC2        /10   -> V   (AC phase 2 voltage)
# [14] FREQUENCY   /100  -> Hz
# [15] IAC2        /10   -> A   (AC phase 2 current)
# [16] VAC3        /10   -> V   (AC phase 3 voltage)
# [17] IAC3        /10   -> A   (AC phase 3 current)
# [18] VAC1        /10   -> V   (AC phase 1 voltage)
# [19] 0xFF00            -> internal status register, ignore
# [20] unknown           -> 0
# [21] unknown           -> 0
# [22] power limit %     -> inverter power limit feedback
# [23] unknown           -> 0

if ( $config->options_strings == 1 ) {
    %DATA_BYTES = (
        "TEMP"      => 0,
        "VPV2"      => 1,
        "VPV1"      => 2,
        "IPV1"      => 3,
        "IPV2"      => 3,
        "OP_MODE"   => 5,
        "HOURS_UP"  => 6,
        "NA_0"      => 7,
        "PAC"       => 9,
        "E_TOTAL"   => 8,
        "NA_1"      => 10,
        "E_TODAY"   => 11,
        "IAC1"      => 12,
        "IAC2"      => 12,
        "IAC3"      => 12,
        "VAC2"      => 13,
        "FREQUENCY" => 14,
        "VAC3"      => 16,
        "VAC1"      => 18,
        "IMPEDANCE" => 19,
        "NA_2"      => 22
    );
}
elsif ( $config->options_strings == 2 ) {
    %DATA_BYTES = (
        "TEMP"      => 0,
        "VPV2"      => 1,
        "VPV1"      => 2,
        "IPV1"      => 3,
        "IPV2"      => 4,
        "OP_MODE"   => 5,
        "HOURS_UP"  => 6,
        "NA_0"      => 7,
        "PAC"       => 9,
        "E_TOTAL"   => 8,
        "NA_1"      => 10,
        "E_TODAY"   => 11,
        "IAC1"      => 12,
        "VAC2"      => 13,
        "FREQUENCY" => 14,
        "IAC2"      => 15,
        "VAC3"      => 16,
        "IAC3"      => 17,
        "VAC1"      => 18,
        "IMPEDANCE" => 19,
        "NA_2"      => 22
    );
}
else {
    die "Incorrect config option for 'strings'\n";
}

use constant START_INVERTER_ADDRESS => 0x10;
use constant OUR_ADDRESS            => 0x01;

our $sock           = 0;
our $last_min       = -1;
our $pvlog_last_min = -1;
our $e_last_wh      = -1;

our $next_inverter_address = START_INVERTER_ADDRESS;
our %inverters;

##
## sub routines
##

sub send_request {
    if ( !$sock ) {
        pmu_log("Severity 3, Socket not present for sending");
        return 0
    }

    my $destination_address = shift;
    my ( $ctrl_func_code, $data ) = @_;
    %ctrl_func_code = %$ctrl_func_code;
    @data           = @$data;

    my $data_length = scalar(@data);

    @tmp_packet = ( 0xAA, 0x55, OUR_ADDRESS, 0x00, 0x00, $destination_address, $ctrl_func_code{"REQUEST"}[0], $ctrl_func_code{"REQUEST"}[1], $data_length );
    if ($data_length) {
        push( @tmp_packet, @data );
    }

    $tmp_packet_length = scalar(@tmp_packet);

    my $checksum = 0;
    for ( $i = 0 ; $i < $tmp_packet_length ; $i++ ) {
        $checksum += $tmp_packet[$i];
    }

    $packet = pack( "C" . $tmp_packet_length . "n", ( @tmp_packet, $checksum ) );

    if ( $config->options_debug >= 4 ) {
        print "sending packet to inverter... \n";
        print_bytes( $packet, length($packet) );
    }

    if ( $config->options_communication_method eq "serial" ) {
        $sock->write($packet);
    }

    sleep 1;

    if ( $ctrl_func_code{"RESPONSE"} ne "" ) {
        if ( $config->options_communication_method eq "serial" ) {
            ( $count_in, $response ) = $sock->read(256);
        }

        if ( length($response) ) {
            @recv_packet = unpack( "C*", $response );

            if ( $config->options_debug >= 4 ) {
                print "received packet from inverter: \n";
                print_bytes( $response, length($response) );
            }

            if ( validate_checksum(@recv_packet) ) {
                my $len = length($response) - 11;
                my ( $ctrl_code, $func_code, @data ) = unpack( "xxxxxxCCxC" . $len . "xx", $response );

                if (   $ctrl_code == $ctrl_func_code{"RESPONSE"}[0]
                    && $func_code == $ctrl_func_code{"RESPONSE"}[1] )
                {
                    return pack( "C*", @data );
                }
            }
        }
    }
    else {
        return 1;
    }

    pmu_log("Severity 3, fallback to no response");
    return 0;
}

sub print_bytes {
    my $buf        = shift;
    my $len        = shift;
    my $line_count = 0;

    if ( $len <= 0 ) {
        return;
    }

    my @bytes = unpack( "C$len", $buf );

    if ( $len > 0 ) {
        for ( my $i = 0 ; $i < $len ; $i++ ) {
            printf "%02x ", $bytes[$i];
            if ( $line_count++ > 15 ) {
                $line_count = 0;
                print "\n";
            }
        }
    }
    printf "\n";
}

sub serial_connect {
    if ( $^O eq 'MSWin32' ) {
        eval "use Win32::SerialPort";
        $sock = Win32::SerialPort->new( $config->serial_port, 0, '' ) || die "Can\'t open $port: $!";
    }
    else {
        eval "use Device::SerialPort";
        $sock = Device::SerialPort->new( $config->serial_port, 0, '' ) || die "Can\'t open $port: $!";
    }

    $sock->baudrate(9600)    || die 'fail setting baudrate, try -b option';
    $sock->parity("none")    || die 'fail setting parity';
    $sock->databits(8)       || die 'fail setting databits';
    $sock->stopbits(1)       || die 'fail setting stopbits';
    $sock->handshake("none") || die 'fail setting handshake';
    $sock->datatype("raw")   || die 'fail setting datatype';
    $sock->write_settings    || die 'could not write settings';
    $sock->read_char_time(0);
    $sock->read_const_time(1000);
}

sub re_register_inverters {
    for ( my $i = 0 ; $i < 8 ; $i++ ) {
        unless ( send_request( 0x00, $CTRL_FUNC_CODES{"REGISTER"}{"RE_REGISTER"} ) ) {
            pmu_log("Severity 2, Failed to send re-register message");
            return 0;
        }
    }
    return 1;
}

sub register_inverter {
    $serial_num_response = send_request( 0x00, $CTRL_FUNC_CODES{"REGISTER"}{"OFFLINE_QUERY"} );
    if ($serial_num_response) {
        my $serial_number = unpack( "Z*", $serial_num_response );
        pmu_log("Severity 3, Unpacked received serial number: $serial_number .");
        $serial_number =~ s/\W//g;
        pmu_log("Severity 1, Cleaned received serial number: $serial_number .");

        my @register_address = unpack( "C*", $serial_num_response );
        push( @register_address, $next_inverter_address );
        $address_response =
          send_request( 0x00, $CTRL_FUNC_CODES{"REGISTER"}{"SEND_REGISTER_ADDRESS"}, \@register_address );
        if ($address_response) {
            my $len                      = length($address_response);
            my $register_acknowledgement = unpack( "C", $address_response );
            if ( $register_acknowledgement == 06 ) {
                pmu_log("Severity 1, Inverter acknowledged registration");

                $inverter_id_response =
                  send_request( $next_inverter_address, $CTRL_FUNC_CODES{"READ"}{"QUERY_INVERTER_ID"} );
                if ($inverter_id_response) {
                    my $len         = length($inverter_id_response);
                    my $inverter_id = unpack( "A*", $inverter_id_response );
                    pmu_log("Severity 1, Connected to inverter: $inverter_id");

                    $timestamp                                      = get_timestamp();
                    $inverters{$next_inverter_address}{"id_string"} = $inverter_id;
                    $inverters{$next_inverter_address}{"serial"}    = $serial_number;
                    $inverters{$next_inverter_address}{"connected"} = $timestamp;
                    $inverters{$next_inverter_address}{"max"}       = {
                        "pac" => {
                            "watts"     => 0,
                            "timestamp" => $timestamp
                        }
                    };
                    $inverters{$next_inverter_address}{"daily_retrieved"} = 0;
                    $inverters{$next_inverter_address}{"daily_retrieved_value"} = 0;
                    $inverters{$next_inverter_address}{"daily_stored"} = 0;

                    if (defined $mqtt_limit_command) {
                        set_power_limit($next_inverter_address, $mqtt_limit_command, 10);
                        pmu_log("Severity 1, MQTT power limit $mqtt_limit_command% applied to newly registered inverter");
                    }

                    $next_inverter_address++;
                }
                else {
                    pmu_log("Severity 2, No response to 'query inverter id' request for inverter $serial_number");
                }
            }
            else {
                pmu_log("Severity 1, Inverter register acknowledgement incorrect for inverter $serial_number. Expected 06, received $register_acknowledgement");
            }
        }
        else {
            pmu_log("Severity 2, No response to 'send register address' request for inverter $serial_number");
        }
    }
    else {
        pmu_log("Severity 3, No response to 'offline query' request - no offline inverters");
    }
}

sub register_known_inverter {
    my $serial_number = shift;
    pmu_log("Severity 2, Try to register known serial number: $serial_number");

    $serial_num_response = pack( "A*", $serial_number );
    my @register_address = unpack( "C*", $serial_num_response );
    push( @register_address, $next_inverter_address );
    $address_response = send_request( 0x00, $CTRL_FUNC_CODES{"REGISTER"}{"SEND_REGISTER_ADDRESS"}, \@register_address );
    if ($address_response) {
        my $len                      = length($address_response);
        my $register_acknowledgement = unpack( "C", $address_response );
        if ( $register_acknowledgement == 06 ) {
            pmu_log("Severity 1, Inverter $serial_number acknowledged registration");

            $inverter_id_response =
              send_request( $next_inverter_address, $CTRL_FUNC_CODES{"READ"}{"QUERY_INVERTER_ID"} );
            if ($inverter_id_response) {
                my $len         = length($inverter_id_response);
                my $inverter_id = unpack( "A*", $inverter_id_response );
                pmu_log("Severity 1, Connected to inverter: $inverter_id");

                $timestamp                                      = get_timestamp();
                $inverters{$next_inverter_address}{"id_string"} = $inverter_id;
                $inverters{$next_inverter_address}{"serial"}    = $serial_number;
                $inverters{$next_inverter_address}{"connected"} = $timestamp;
                $inverters{$next_inverter_address}{"max"}       = {
                    "pac" => {
                        "watts"     => 0,
                        "timestamp" => $timestamp
                    }
                };

                $inverters{$next_inverter_address}{"daily_retrieved"} = 0;
                set_power_limit($next_inverter_address, 100, 10);
                $inverters{$next_inverter_address}{"daily_retrieved_value"} = 0;
                $inverters{$next_inverter_address}{"daily_stored"} = 0;

                if (defined $mqtt_limit_command) {
                    set_power_limit($next_inverter_address, $mqtt_limit_command, 10);
                    pmu_log("Severity 1, MQTT power limit $mqtt_limit_command% applied to newly registered inverter");
                }

                $next_inverter_address++;
            }
            else {
                pmu_log("Severity 2, No response to 'query inverter id' request for known inverter $serial_number");
            }
        }
        else {
            pmu_log("Severity 1, Inverter register acknowledgement incorrect for known inverter $serial_number. Expected 06, received $register_acknowledgement");
        }
    }
    else {
        pmu_log("Severity 2, No response to 'send register address' request for known inverter $serial_number");
    }
}

sub set_power_limit {
    my ($inverter_address, $percent_limit, $ramp_time_secs) = @_;

    $percent_limit = 99 if $percent_limit > 99;
    $percent_limit = 5  if $percent_limit < 5;

    my $ramp_time_secs = 30;

    my @data = ($percent_limit, $ramp_time_secs);

    my $success = send_request(
        $inverter_address,
        { "REQUEST" => [ 0x13, 0x20 ], "RESPONSE" => "" },
        \@data
    );

    if ($success) {
        pmu_log("Severity 1, Power limit set to $percent_limit% over $ramp_time_secs seconds for inverter $inverter_address");
        $inverters{$inverter_address}{"power_limit"} = {
            percent   => $percent_limit,
            ramp_time => $ramp_time_secs,
        };
        return 1;
    } else {
        pmu_log("Severity 1, Failed to set power limit for inverter $inverter_address");
        return 0;
    }
}

##
## MQTT command listener
## =====================
## Luistert op zeversolar/SX00046011830383/power_limit voor een getal (5-99)
## dat direct vanuit Home Assistant (slider) gepubliceerd wordt.
## Bewaard ook de oude "limit power N" syntax op het command topic.
##

sub init_mqtt_command_listener {
    my $host         = $config->mqtt_host;
    my $port         = $config->mqtt_port;
    my $username     = $config->mqtt_user;
    my $password     = $config->mqtt_password;
    my $status_topic = $config->mqtt_response_topic;

    $mqtt = AnyEvent::MQTT->new(
        host             => $host,
        port             => $port,
        user_name        => $username,
        password         => $password,
        keep_alive_timer => 60,
        client_id        => "eversolar_listener_" . int(rand(10000)),
    );

    # Luister direct op het power_limit topic
    # HA stuurt gewoon een getal: 5 t/m 99
    $mqtt->subscribe(
        topic    => "zeversolar/SX00046011830383/power_limit/set",
        qos      => 1,
        callback => sub {
            my ($topic, $message) = @_;
            my $payload = $message;
            $payload =~ s/^\s+|\s+$//g;   # trim whitespace

            pmu_log("Severity 1, MQTT power_limit ontvangen: $payload");

            if ($payload =~ /^(\d{1,3})$/) {
                my $limit = $1;
                $limit = 99 if $limit > 99;
                $limit = 5  if $limit < 5;
                $mqtt_limit_command = $limit;
                $last_power_limit   = $limit;
                pmu_log("Severity 1, Power limit bijgewerkt naar $limit%");
            } else {
                pmu_log("Severity 1, Onbekend power_limit payload: $payload");
            }
        }
    );

    # Oude command topic bewaard voor achterwaartse compatibiliteit
    # (formaat: "limit power 50")
    $mqtt->subscribe(
        topic    => $config->mqtt_command_topic,
        qos      => 1,
        callback => sub {
            my ($topic, $message) = @_;
            my $payload = $message;
            pmu_log("Severity 1, MQTT command ontvangen: $payload");

            if ($payload =~ /^limit power (\d{1,3})$/i) {
                my $limit = $1;
                $limit = 99 if $limit > 99;
                $limit = 5  if $limit < 5;
                $mqtt_limit_command = $limit;
                $last_power_limit   = $limit;
                my $response = encode_json({ status => "Power limit set to $limit%" });
                $mqtt->publish(topic => $status_topic, message => $response);
                pmu_log("Severity 1, Power limit via command topic: $limit%");
            }
        }
    );

    my $mqtt_timer = AnyEvent->timer(
        after    => 1,
        interval => 1,
        cb       => sub { 1; },
    );

    pmu_log("Severity 1, MQTT listener gestart op zeversolar/SX00046011830383/power_limit");
}

###############################################################################
##
##  Upload data to PVOutput (https://pvoutput.org)
##
###############################################################################

sub upload_pvoutput {
    my ($pac_watts, $e_today_wh, $vac, $iac, $temp) = @_;

    return unless $config->pvoutput_enabled && $config->pvoutput_enabled == 1;

    my $api_key   = $config->pvoutput_api_key;
    my $system_id = $config->pvoutput_system_id;

    unless ($api_key && $system_id) {
        pmu_log("Severity 1, PVOutput: api_key or system_id not configured");
        return;
    }

    my @lt = localtime(time);
    my $date = sprintf("%04d%02d%02d", $lt[5]+1900, $lt[4]+1, $lt[3]);
    my $time = sprintf("%02d:%02d", $lt[2], $lt[1]);

    my $energy_wh = int($e_today_wh);

    my %params = (
        d  => $date,
        t  => $time,
        v1 => $energy_wh,
        v2 => int($pac_watts),
    );
    $params{v5} = sprintf("%.1f", $temp) if defined $temp && $temp ne '';
    $params{v6} = sprintf("%.1f", $vac)  if defined $vac  && $vac  ne '';

    my $ua = LWP::UserAgent->new(timeout => 15);
    my $req = POST(
        'https://pvoutput.org/service/r2/addstatus.jsp',
        [%params]
    );
    $req->header('X-Pvoutput-Apikey'   => $api_key);
    $req->header('X-Pvoutput-SystemId' => $system_id);

    my $res = $ua->request($req);

    if ($res->is_success) {
        pmu_log("Severity 1, PVOutput upload OK: $energy_wh Wh, $pac_watts W at $date $time");
    } else {
        pmu_log("Severity 1, PVOutput upload FAILED: " . $res->status_line . " - " . $res->content);
    }
}

###############################################################################
##
##  Write data to InfluxDB
##
###############################################################################

sub upload_influxdb {
    my ($inverter_serial, $data_ref) = @_;

    return unless $config->influxdb_enabled && $config->influxdb_enabled == 1;

    my $host        = $config->influxdb_host   || "localhost";
    my $port        = $config->influxdb_port   || 8086;
    my $measurement = $config->influxdb_measurement || "solar";
    my $version     = $config->influxdb_version || "1";

    my $serial_safe = $inverter_serial;
    $serial_safe =~ s/[, =]/_/g;

    my %fields;
    for my $key (keys %$data_ref) {
        my $val = $data_ref->{$key};
        next unless defined $val && $val ne '';
        next if $key eq 'timestamp' || $key eq 'connected' || $key eq 'op_mode';
        $fields{$key} = $val + 0;
    }

    if (defined $data_ref->{'op_mode'}) {
        $fields{'op_mode'} = '"' . $data_ref->{'op_mode'} . '"';
    }

    my $field_set = join(",", map { "$_=$fields{$_}" } sort keys %fields);
    return unless $field_set;

    my $line = "${measurement},serial=${serial_safe} ${field_set}";

    my ($url, $req);
    my $ua = LWP::UserAgent->new(timeout => 10);

    if ($version eq "2") {
        my $org    = $config->influxdb_org    || "";
        my $bucket = $config->influxdb_bucket || "solar";
        my $token  = $config->influxdb_token  || "";

        $url = "http://${host}:${port}/api/v2/write?org=${org}&bucket=${bucket}&precision=s";
        $req = HTTP::Request->new(POST => $url);
        $req->header('Authorization' => "Token $token");
        $req->header('Content-Type'  => 'text/plain; charset=utf-8');
        $req->content($line);
    } else {
        my $db   = $config->influxdb_database || "solar";
        my $user = ($config->influxdb_user     && $config->influxdb_user     ne 'none') ? $config->influxdb_user     : "";
        my $pass = ($config->influxdb_password && $config->influxdb_password ne 'none') ? $config->influxdb_password : "";

        my $auth = ($user ne '') ? "u=${user}&p=${pass}&" : "";
        $url = "http://${host}:${port}/write?${auth}db=${db}&precision=s";
        $req = HTTP::Request->new(POST => $url);
        $req->header('Content-Type' => 'text/plain');
        $req->content($line);
    }

    my $res = $ua->request($req);

    if ($res->code == 204 || $res->is_success) {
        pmu_log("Severity 3, InfluxDB write OK for inverter $inverter_serial");
    } else {
        pmu_log("Severity 1, InfluxDB write FAILED: " . $res->status_line . " - " . $res->content);
    }
}

###############################################################################
##
##  Send data to Domoticz
##
###############################################################################

sub upload_domoticz {
    my ($pac_watts, $e_total_kwh, $temp) = @_;

    return unless $config->domoticz_enabled && $config->domoticz_enabled == 1;

    my $host      = $config->domoticz_host || "localhost";
    my $port      = $config->domoticz_port || 8080;
    my $use_https = $config->domoticz_use_https || 0;
    my $scheme    = $use_https ? "https" : "http";
    my $idx_power = $config->domoticz_idx_power;
    my $idx_temp  = $config->domoticz_idx_temp;
    my $domo_user = ($config->domoticz_user     && $config->domoticz_user     ne 'none') ? $config->domoticz_user     : "";
    my $domo_pass = ($config->domoticz_password && $config->domoticz_password ne 'none') ? $config->domoticz_password : "";

    unless ($idx_power) {
        pmu_log("Severity 1, Domoticz: domoticz_idx_power not configured");
        return;
    }

    my $ua = LWP::UserAgent->new(timeout => 10);

    my $e_total_wh = int($e_total_kwh * 1000);

    my $power_url = sprintf(
        "%s://%s:%s/json.htm?type=command&param=udevice&idx=%s&nvalue=0&svalue=%d;%d",
        $scheme, $host, $port,
        $idx_power,
        int($pac_watts),
        $e_total_wh
    );

    my $req = HTTP::Request->new(GET => $power_url);
    if ($domo_user ne '') {
        $req->authorization_basic($domo_user, $domo_pass);
    }

    my $res = $ua->request($req);
    if ($res->is_success) {
        my $body = decode_json($res->content);
        if ($body->{'status'} eq 'OK') {
            pmu_log("Severity 3, Domoticz power update OK: ${pac_watts}W, ${e_total_wh}Wh total");
        } else {
            pmu_log("Severity 1, Domoticz power update returned: " . $res->content);
        }
    } else {
        pmu_log("Severity 1, Domoticz power update FAILED: " . $res->status_line);
    }

    if ($idx_temp && defined $temp && $temp ne '') {
        my $temp_url = sprintf(
            "%s://%s:%s/json.htm?type=command&param=udevice&idx=%s&nvalue=0&svalue=%.1f",
            $scheme, $host, $port,
            $idx_temp,
            $temp
        );

        my $treq = HTTP::Request->new(GET => $temp_url);
        if ($domo_user ne '') {
            $treq->authorization_basic($domo_user, $domo_pass);
        }

        my $tres = $ua->request($treq);
        if ($tres->is_success) {
            pmu_log("Severity 3, Domoticz temperature update OK: ${temp}C");
        } else {
            pmu_log("Severity 1, Domoticz temperature update FAILED: " . $tres->status_line);
        }
    }
}

##
## Write JSON state file for web dashboard
##

sub write_state_file {
    my ($inverter_addr) = @_;
    return unless $config->options_state_file;
    my $state_file = $config->options_state_file;
    my %d = %{ $inverters{$inverter_addr}{'data'} };
    $d{serial}      = $inverters{$inverter_addr}{'serial'};
    $d{id_string}   = $inverters{$inverter_addr}{'id_string'};
    $d{connected}   = $inverters{$inverter_addr}{'connected'};
    $d{max_pac}     = $inverters{$inverter_addr}{'max'}{'pac'}{'watts'};
    $d{power_limit} = $inverters{$inverter_addr}{'power_limit'}{'percent'} // 0;
    open(my $fh, '>', $state_file) or do {
        pmu_log("Severity 2, Cannot write state file: $!");
        return;
    };
    print $fh encode_json(\%d);
    close $fh;
    pmu_log("Severity 3, State file written: $state_file");
}

##
## Write a log file entry
##

sub pmu_log {
    my $msg = shift;

    ( my $sec, my $min, my $hour, my $mday, my $mon, my $year, my $wday, my $yday, my $isdst ) = localtime(time);
    my $timestamp = sprintf( "%04d-%02d-%02d %02d:%02d:%02d", $year + 1900, $mon + 1, $mday, $hour, $min, $sec );

    if ( $config->options_debug >= substr( $msg, 9, 1 ) ) {
        print sprintf( "%s: %s\n", $timestamp, $msg );
        if ( $config->options_output_to_log != 0) {
            open( OUT, ">>" . $config->options_log_file )
              or die "Cannot open file " . $config->options_log_file . " for writing\n";
            printf( OUT "%s: %s\n", $timestamp, $msg );
            close OUT;
        }
    }
}

sub validate_checksum {
    my @packet = @_;
    my $csum   = 0;
    my $len    = scalar(@packet);
    for ( $i = 0 ; $i < $len - 2 ; $i++ ) {
        $csum += $packet[$i];
    }
    return ( $csum > 0 ) && ( $csum == ( ( $packet[ $len - 2 ] << 8 ) + $packet[ $len - 1 ] ) );
}

sub parse_packet {
    my @packet = @_;
    my @data;
    my $j   = 0;
    my $len = scalar(@packet);
    for ( $i = 0 ; $i < $len ; $i += 2 ) {
        $data[ $j++ ] = ( $packet[$i] << 8 ) + $packet[ ( $i + 1 ) ];
    }
    return @data;
}

sub inverter_connect {
    my $connected = 0;
    while ( !$connected ) {
            pmu_log("Severity 1, Connecting to the serial port");
            serial_connect();

        $next_inverter_address = START_INVERTER_ADDRESS;

        pmu_log("Severity 2, Asking all inverters to re-register");
        $connected = re_register_inverters();
    }

    $last_min  = -1;
    $e_last_wh = -1;
}

sub get_timestamp {
    ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) = localtime(time);
    return sprintf( "%04d-%02d-%02d %02d:%02d:%02d", $year + 1900, $mon + 1, $mday, $hour, $min, $sec );
}

###############################################################################
##
##  Main Loop
##
###############################################################################

sub main_loop {
    my $timestamp = get_timestamp();

    AnyEvent->now_update;

    $timestamp = get_timestamp();

    my $combined_power  = 0;
    my $combined_daykwh = 0;
    my $d365            = 0;

    if ( !$sock ) {
        inverter_connect();

        pmu_log("Severity 2, Delaying 10 seconds after inverter_connect before polling...");
        my $delay = AnyEvent->timer(
            after => 10,
            cb => sub {
                main_loop();
            }
        );
        return;
    }

    my $sleep_time = 0;

    while ( keys(%inverters) == 0 ) {
        register_inverter();

        if ( !$sock ) {
            pmu_log("Severity 1, no valid sock present");
            last;
        }

        $sleep_time_cnt++;

        my $sleep_time = 10 * floor($sleep_time_cnt / 5 + 1);
        $sleep_time = 60 if $sleep_time > 60;

        pmu_log("Severity 2, No inverters registered yet, sleeping for $sleep_time seconds");

        my $delay = AnyEvent->timer(
            after => $sleep_time,
            cb => sub {
                pmu_log("Severity 3, Delay complete during inverter connect");
                main_loop();
            }
        );
        return;
    }

    $timestamp = get_timestamp();

    if ( $min != $last_min ) {
        pmu_log("Severity 2, Asking for any inverters to register");
        register_inverter();
    }

    $combined_power  = 0;
    $combined_daykwh = 0;
    foreach $inverter ( keys(%inverters) ) {
        $response = send_request( $inverter, $CTRL_FUNC_CODES{"READ"}{"QUERY_NORMAL_INFO"} );
        if ($response) {

            $inverters{$inverter}{"response_timeout_count"} = 0;

            my $len  = length($response);
            my @data = parse_packet( unpack( "C$len", $response ) );

            if ( $config->options_debug >= 3 ) {
                my $dump = "RAW WORDS: ";
                for my $i (0 .. $#data) { $dump .= "[$i]=$data[$i] "; }
                pmu_log("Severity 3, $dump");
            }

            my $e_today_kwh  = $data[ $DATA_BYTES{'E_TODAY'} ] / 100;
            my $e_today_wh   = $e_today_kwh * 1000;
            my $e_total_high = $data[ $DATA_BYTES{'NA_1'} ] || 0;
            my $e_total      = ( $e_total_high * 65536 + $data[ $DATA_BYTES{'E_TOTAL'} ] ) / 10;
            my $pac          = $data[ $DATA_BYTES{'PAC'} ];
            if ( $data[ $DATA_BYTES{'TEMP'} ] >= 0x8000 ) {
                $data[ $DATA_BYTES{'TEMP'} ] -= 0x10000;
            }
            my $temp    = $data[ $DATA_BYTES{'TEMP'} ] / 10;
            my $dc_volt = $data[ $DATA_BYTES{'VPV1'} ] / 10,
            my $dc_imp  = $data[ $DATA_BYTES{'IPV1'} ] / 10,
            my $ac_volt = $data[ $DATA_BYTES{'VAC1'} ] / 10,
            my $ac_imp  = $data[ $DATA_BYTES{'IAC1'} ] / 10,

            $combined_power  = $combined_power + $data[ $DATA_BYTES{'PAC'} ];
            $combined_daykwh = $combined_daykwh + $data[ $DATA_BYTES{'E_TODAY'} ] / 100;

            $d365 = $e_total - $inverters{$inverter}{"daily_retrieved_value"};

            pmu_log("Severity 3, " . $inverters{$inverter}{"serial"} . " output: $pac W, Total: $e_total kWh, Today: $e_today_kwh kWh, 365 days : $d365 " );

            $inverters{$inverter}{"data"} = {
                "timestamp"    => $timestamp,
                "pac"          => $data[ $DATA_BYTES{'PAC'} ],
                "e_today"      => $e_today_kwh,
                "e_total"      => $e_total,
                "vpv1"         => $data[ $DATA_BYTES{'VPV1'} ] / 10,
                "vpv2"         => $data[ $DATA_BYTES{'VPV2'} ] / 10,
                "ipv1"         => $data[ $DATA_BYTES{'IPV1'} ] / 10,
                "ipv2"         => $data[ $DATA_BYTES{'IPV2'} ] / 10,
                "vac1"         => $data[ $DATA_BYTES{'VAC1'} ] / 10,
                "vac2"         => $data[ $DATA_BYTES{'VAC2'} ] / 10,
                "vac3"         => $data[ $DATA_BYTES{'VAC3'} ] / 10,
                "iac1"         => $data[ $DATA_BYTES{'IAC1'} ] / 10,
                "iac2"         => $data[ $DATA_BYTES{'IAC2'} ] / 10,
                "iac3"         => $data[ $DATA_BYTES{'IAC3'} ] / 10,
                "frequency"    => sprintf("%.2f", $data[ $DATA_BYTES{'FREQUENCY'} ] / 100) + 0,
                "d365"         => $d365,
                "impedance"    => ($data[ $DATA_BYTES{'IMPEDANCE'} ] == 0xFF00) ? 0 : $data[ $DATA_BYTES{'IMPEDANCE'} ] / 10,
                "hours_up"     => $data[ $DATA_BYTES{'HOURS_UP'} ],
                "op_mode"      => $data[ $DATA_BYTES{'OP_MODE'} ],
                "temp"         => $temp,
                "total_power"  => $combined_power,
                "total_daykwh" => $combined_daykwh
            };

            if ( $data[ $DATA_BYTES{'PAC'} ] > $inverters{$inverter}{"max"}{"pac"}{"watts"} ) {
                $inverters{$inverter}{"max"}{"pac"} = {
                    "timestamp" => $timestamp,
                    "watts"     => $data[ $DATA_BYTES{'PAC'} ]
                };
            }

           ###########################################################################
           ##  MQTT (Home Assistant)
           ###########################################################################
           if ( $config->mqtt_enabled ) {
               pmu_log("Severity 3: MQTT Start");
               my $mqtt_host           = $config->mqtt_host;
               my $mqtt_port           = $config->mqtt_port;
               my $mqtt_user           = $config->mqtt_user;
               my $mqtt_password       = $config->mqtt_password;
               my $mqtt_topic_prefix   = $config->mqtt_topic_prefix;
               my $mqtt_inverter_model = $config->mqtt_inverter_model;
               my $mqtt_serial = $inverters{$inverter}{'serial'};
               my $cmd;
               pmu_log("Severity 3: MQTT Config info is read");

               my %mqtt_data = (
                   pac             => $inverters{$inverter}{'data'}{'pac'},
                   max_power_today => $inverters{$inverter}{'max'}{'pac'}{'watts'},
                   d365            => $inverters{$inverter}{'data'}{'d365'},
                   total_daykwh    => $inverters{$inverter}{'data'}{'total_daykwh'},
                   e_total         => $inverters{$inverter}{'data'}{'e_total'},
                   temp            => $inverters{$inverter}{'data'}{'temp'},
                   impedance       => $inverters{$inverter}{'data'}{'impedance'},
                   frequency       => $inverters{$inverter}{'data'}{'frequency'},
                   iac1            => $inverters{$inverter}{'data'}{'iac1'},
                   iac2            => $inverters{$inverter}{'data'}{'iac2'},
                   iac3            => $inverters{$inverter}{'data'}{'iac3'},
                   ipv1            => $inverters{$inverter}{'data'}{'ipv1'},
                   ipv2            => $inverters{$inverter}{'data'}{'ipv2'},
                   vac1            => $inverters{$inverter}{'data'}{'vac1'},
                   vac2            => $inverters{$inverter}{'data'}{'vac2'},
                   vac3            => $inverters{$inverter}{'data'}{'vac3'},
                   vpv1            => $inverters{$inverter}{'data'}{'vpv1'},
                   vpv2            => $inverters{$inverter}{'data'}{'vpv2'},
                   op_mode         => $inverters{$inverter}{'data'}{'op_mode'},
                   hours_up        => $inverters{$inverter}{'data'}{'hours_up'},
                   timestamp       => $inverters{$inverter}{'data'}{'timestamp'},
                   connected       => $inverters{$inverter}{'connected'},
                   power_limit     => $inverters{$inverter}{"power_limit"}{"percent"},
               );
               pmu_log("Severity 3: MQTT inverter hash is flattened");

              sub ha_disc_config {
                       my $mqtt_serial_HA = $inverters{$inverter}{'serial'};
                       my %config_data = (
                           device => {
                               identifiers  => [ $mqtt_serial_HA ],
                               manufacturer => "Eversolar",
                               model        => $mqtt_inverter_model,
                               name         => "Solar Inverter"
                           },
                           state_topic => "$mqtt_topic_prefix/$mqtt_serial_HA/$_[0]",
                           unique_id   => "$mqtt_serial_HA\_$_[0]",
                           state_class => "measurement",
                       );
                     if ( $_[0] eq "pac" ){
                           $config_data{'icon'} = "mdi:solar-power";
                           $config_data{'name'} = "PV Solar Power Right Now";
                           $config_data{'unit_of_measurement'} = "W";
                           $config_data{'device_class'} = "power";
                           $config_data{'state_class'} = "measurement";
                       } elsif ( $_[0] eq "max_power_today" ){
                           $config_data{'icon'} = "mdi:solar-power";
                           $config_data{'name'} = "PV Maximum Solar Power Today";
                           $config_data{'unit_of_measurement'} = "W";
                           $config_data{'device_class'} = "power";
                           $config_data{'state_class'} = "measurement";
                       } elsif ( $_[0] eq "d365" ){
                           $config_data{'icon'} = "mdi:solar-power";
                           $config_data{'name'} = "PV Last 365 Days Production";
                           $config_data{'unit_of_measurement'} = "kWh";
                           $config_data{'device_class'} = "energy";
                       } elsif ( $_[0] eq "total_daykwh" ){
                           $config_data{'icon'} = "mdi:solar-power";
                           $config_data{'name'} = "PV Total Energy Today";
                           $config_data{'unit_of_measurement'} = "kWh";
                           $config_data{'device_class'} = "energy";
                       } elsif ( $_[0] eq "e_total" ){
                           $config_data{'icon'} = "mdi:solar-power";
                           $config_data{'name'} = "PV Total Energy Production";
                           $config_data{'unit_of_measurement'} = "kWh";
                           $config_data{'device_class'} = "energy";
                           $config_data{"state_class"} = "total_increasing";
                       } elsif ( $_[0] eq "temp" ){
                           $config_data{'icon'} = "mdi:temperature-celsius";
                           $config_data{'name'} = "PV Inverter Temperature";
                           binmode(STDOUT, ":utf8");
                           $config_data{'unit_of_measurement'} = "\x{00b0}C";
                           $config_data{'device_class'} = "temperature";
                           $config_data{'state_class'} = "measurement";
                       } elsif ( $_[0] eq "impedance" ){
                           $config_data{'icon'} = "mdi:omega";
                           $config_data{'name'} = "PV Inverter Impedance";
                           $config_data{'unit_of_measurement'} = "Ohm";
                           $config_data{'state_class'} = "measurement";
                       } elsif ( $_[0] eq "frequency" ){
                           $config_data{'icon'} = "mdi:sine-wave";
                           $config_data{'name'} = "PV AC Frequency";
                           $config_data{'unit_of_measurement'} = "Hz";
                           $config_data{'device_class'} = "frequency";
                           $config_data{'state_class'} = "measurement";
                        } elsif ( $_[0] eq "iac1" ){
                            $config_data{'icon'} = "mdi:current-ac";
                            $config_data{'name'} = "PV AC1 Current";
                            $config_data{'unit_of_measurement'} = "A";
                            $config_data{'device_class'} = "current";
                        } elsif ( $_[0] eq "iac2" ){
                            $config_data{'icon'} = "mdi:current-ac";
                            $config_data{'name'} = "PV AC2 Current";
                            $config_data{'unit_of_measurement'} = "A";
                            $config_data{'device_class'} = "current";
                        } elsif ( $_[0] eq "iac3" ){
                            $config_data{'icon'} = "mdi:current-ac";
                            $config_data{'name'} = "PV AC3 Current";
                            $config_data{'unit_of_measurement'} = "A";
                            $config_data{'device_class'} = "current";
                        } elsif ( $_[0] eq "ipv1" ){
                            $config_data{'icon'} = "mdi:current-ac";
                            $config_data{'name'} = "PV Current1";
                            $config_data{'unit_of_measurement'} = "A";
                            $config_data{'device_class'} = "current";
                        } elsif ( $_[0] eq "ipv2" ){
                            $config_data{'icon'} = "mdi:current-ac";
                            $config_data{'name'} = "PV Current2";
                            $config_data{'unit_of_measurement'} = "A";
                            $config_data{'device_class'} = "current";
                        } elsif ( $_[0] eq "vac1" ){
                            $config_data{'icon'} =  "mdi:sine-wave";
                            $config_data{'name'} = "PV AC1 Voltage";
                            $config_data{'unit_of_measurement'} = "V";
                            $config_data{'device_class'} = "voltage";
                        } elsif ( $_[0] eq "vac2" ){
                            $config_data{'icon'} =  "mdi:sine-wave";
                            $config_data{'name'} = "PV AC2 Voltage";
                            $config_data{'unit_of_measurement'} = "V";
                            $config_data{'device_class'} = "voltage";
                        } elsif ( $_[0] eq "vac3" ){
                            $config_data{'icon'} =  "mdi:sine-wave";
                            $config_data{'name'} = "PV AC3 Voltage";
                            $config_data{'unit_of_measurement'} = "V";
                            $config_data{'device_class'} = "voltage";
                        } elsif ( $_[0] eq "vpv1" ){
                            $config_data{'icon'} = "mdi:sine-wave";
                            $config_data{'name'} = "PV Voltage1";
                            $config_data{'unit_of_measurement'} = "V";
                            $config_data{'device_class'} = "voltage";
                        } elsif ( $_[0] eq "vpv2" ){
                            $config_data{'icon'} = "mdi:sine-wave";
                            $config_data{'name'} = "PV Voltage2";
                            $config_data{'unit_of_measurement'} = "V";
                            $config_data{'device_class'} = "voltage";
                       } elsif ( $_[0] eq "op_mode" ){
                           $config_data{'icon'} = "mdi:cog";
                           $config_data{'name'} = "PV Operation Mode";
                       } elsif ( $_[0] eq "hours_up" ){
                           $config_data{'icon'} = "mdi:timer-cog";
                           $config_data{'name'} = "PV Total Uptime";
                           $config_data{'unit_of_measurement'} = "hours";
                           $config_data{"state_class"} = "total_increasing";
                       } elsif ( $_[0] eq "timestamp" ){
                           $config_data{'icon'} =  "mdi:update";
                           $config_data{'name'} = "PV Updated At";
                           $config_data{'device_class'} = "timestamp";
                       } elsif ( $_[0] eq "connected" ){
                           $config_data{'icon'} = "mdi:connection";
                           $config_data{'name'} = "PV Connected At";
                           $config_data{'device_class'} = "timestamp";
                        } elsif ( $_[0] eq "power_limit" ) {
                            $config_data{'icon'} = "mdi:transmission-tower-export";
                            $config_data{'name'} = "PV Power Limit";
                            $config_data{'unit_of_measurement'} = "%";
                            $config_data{'device_class'} = "power_factor";
                            $config_data{'state_class'} = "measurement";
                       } else {
                           print "$_[0] - No data passed, or hash is corrupted";
                           pmu_log("Severity 1: $_[0] - No data passed, or hash is corrupted");
                       };
                       return %config_data;
                   }

                   sub jsonify_config {
                       my %config_hash = @_;
                       my $config_json = encode_json \%config_hash;
                       return $config_json;
                   }

               keys %mqtt_data;
               while(my($k, $v) = each %mqtt_data)
               {
                   if( $config->mqtt_ha_discovery ) {
                       my $config_send = jsonify_config(ha_disc_config("$k"));
                       if ( $config->mqtt_enable_pass ){
                           $cmd = `mosquitto_pub -h $mqtt_host -p $mqtt_port -u "$mqtt_user" -P "$mqtt_password" -q 0 -t 'homeassistant/sensor/$mqtt_topic_prefix/$mqtt_serial\_$k/config' -m '$config_send'`;
                       } else {
                           $cmd = `mosquitto_pub -h $mqtt_host -p $mqtt_port -q 0 -t 'homeassistant/sensor/$mqtt_topic_prefix/$mqtt_serial\_$k/config' -m '$config_send'`;
                       }
                       chomp $cmd;
                       sleep 0.5;
                       pmu_log("Severity 3: MQTT $k's HA configuration is published");
                   }

                   my @ts_data = ("timestamp", "connected");
                   if( grep( /$k/ , @ts_data ) ){
                       my $tz   = strftime("%z", localtime());
                       my $tz_h = substr($tz, 0, -2);
                       my $tz_m = substr($tz,-2);
                       $v = "$v$tz_h:$tz_m";
                   }

                   if ( $config->mqtt_enable_pass ){
                       $cmd = `mosquitto_pub -h $mqtt_host -p $mqtt_port -u "$mqtt_user" -P "$mqtt_password" -q 1 -t '$mqtt_topic_prefix/$mqtt_serial/$k' -m '$v'`;
                   } else {
                       $cmd = `mosquitto_pub -h $mqtt_host -p $mqtt_port -q 1 -t '$mqtt_topic_prefix/$mqtt_serial/$k' -m '$v'`;
                   }
                   chomp $cmd;
                   sleep 0.5;
                   pmu_log("Severity 3: MQTT $k = $v is published");
               }
               pmu_log("Severity 3: Mqtt messages published");
           }
           # end of MQTT

           ###########################################################################
           ##  Write JSON state file for web dashboard
           ###########################################################################
           write_state_file($inverter);

           ###########################################################################
           ##  PVOutput upload
           ###########################################################################
           if ( $config->pvoutput_enabled && $config->pvoutput_enabled == 1 ) {
               my $interval = $config->pvoutput_interval_mins || 5;
               if ( ($min % $interval == 0) && ($min != $pvoutput_last_upload_min) ) {
                   pmu_log("Severity 1, PVOutput: uploading data for minute $min");
                   upload_pvoutput(
                       $inverters{$inverter}{'data'}{'pac'},
                       $inverters{$inverter}{'data'}{'e_today'} * 1000,
                       $inverters{$inverter}{'data'}{'vac1'},
                       $inverters{$inverter}{'data'}{'iac1'},
                       $inverters{$inverter}{'data'}{'temp'}
                   );
                   $pvoutput_last_upload_min = $min;
               }
           }

           ###########################################################################
           ##  InfluxDB upload
           ###########################################################################
           if ( $config->influxdb_enabled && $config->influxdb_enabled == 1 ) {
               pmu_log("Severity 3, InfluxDB: writing data");
               upload_influxdb(
                   $inverters{$inverter}{'serial'},
                   $inverters{$inverter}{'data'}
               );
           }

           ###########################################################################
           ##  Domoticz upload
           ###########################################################################
           if ( $config->domoticz_enabled && $config->domoticz_enabled == 1 ) {
               pmu_log("Severity 3, Domoticz: sending data");
               upload_domoticz(
                   $inverters{$inverter}{'data'}{'pac'},
                   $inverters{$inverter}{'data'}{'e_total'},
                   $inverters{$inverter}{'data'}{'temp'}
               );
           }

            if ( $hour == 1 && $min == 1 ) {
                if ( $inverters{$inverter}{"daily_retrieved"} == 1 ) {
                    $inverters{$inverter}{"daily_retrieved"} = 0;
                    $inverters{$inverter}{"daily_retrieved_value"} = 0;
                    pmu_log("Severity 3, daily retrieved reset");
                }
                if ($inverters{$inverter}{"daily_stored"} == 1) {
                    $inverters{$inverter}{"daily_stored"} = 0;
                    pmu_log("Severity 3, daily stored reset");
                }
            }
        }
        else {
            $inverters{$inverter}{"response_timeout_count"}++;
            pmu_log("Severity 2, "
                  . $inverters{$inverter}{"serial"}
                  . " lost contact with inverter ("
                  . $inverters{$inverter}{"response_timeout_count"}
                  . " time(s))" );

            if ( $inverters{$inverter}{"response_timeout_count"} == 3 ) {
                pmu_log( "Severity 1, " . $inverters{$inverter}{"serial"} . " lost contact with inverter, forgetting inverter" );

                # Publiceer 0 op MQTT zodat HA niet de laatste waarde blijft tonen
                my $mqtt_host   = $config->mqtt_host;
                my $mqtt_port   = $config->mqtt_port;
                my $mqtt_serial = $inverters{$inverter}{'serial'};
                my $prefix      = $config->mqtt_topic_prefix;
                my $cmd0;
                if ( $config->mqtt_enable_pass ) {
                    my $u = $config->mqtt_user;
                    my $p = $config->mqtt_password;
                    $cmd0 = `mosquitto_pub -h $mqtt_host -p $mqtt_port -u "$u" -P "$p" -q 1 -r -t '$prefix/$mqtt_serial/pac' -m '0'`;
                    $cmd0 = `mosquitto_pub -h $mqtt_host -p $mqtt_port -u "$u" -P "$p" -q 1 -r -t '$prefix/$mqtt_serial/power_limit' -m '0'`;
                } else {
                    $cmd0 = `mosquitto_pub -h $mqtt_host -p $mqtt_port -q 1 -r -t '$prefix/$mqtt_serial/pac' -m '0'`;
                    $cmd0 = `mosquitto_pub -h $mqtt_host -p $mqtt_port -q 1 -r -t '$prefix/$mqtt_serial/power_limit' -m '0'`;
                }
                pmu_log("Severity 1, MQTT pac en power_limit op 0 gezet na uitschakeling omvormer");

                delete $inverters{$inverter};

                if ( $config->options_clean_log && $mday == 1 && keys(%inverters) == 0 && $hour == 1 ) {
                    unlink( $config->options_log_file );
                }
            }
            last;
        }
    }

    $last_min = $min;

    if (defined $mqtt_limit_command) {
        foreach my $addr (keys %inverters) {
            set_power_limit($addr, $mqtt_limit_command, 10);
        }
        pmu_log("Severity 1, Applied MQTT power limit: $mqtt_limit_command%");
        $mqtt_limit_command = undef;
    }
}

###############################################################################
##  AnyEvent timers — main program entry point
###############################################################################

my $main_loop_timer = AnyEvent->timer(
    after    => 0,
    interval => $config->options_query_inverter_secs,
    cb       => sub {
        main_loop();
    }
);

my $power_limit_refresh_timer = AnyEvent->timer(
    after    => $config->options_query_inverter_secs / 2,
    interval => $config->options_power_limit_refresh_mins * 60,
    cb       => sub {
        foreach my $inverter (keys %inverters) {
            set_power_limit($inverter, $last_power_limit, 30);
            pmu_log("Severity 2, Refreshed power limit $last_power_limit% for inverter $inverter");
        }
    }
);

AnyEvent->condvar->recv;

pmu_log("Severity 1, Main loop ended - about to exit - why?");

if ( $config->options_communication_method eq "eth2ser" ) {
    close $sock;
}
elsif ( $config->options_communication_method eq "serial" ) {
    $sock->close;
}

