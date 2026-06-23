#!/usr/bin/perl
#
# zeversolar_web.pl — Standalone webserver voor het ZeverSolar dashboard
#
# Gebruik: perl zeversolar_web.pl
# Of op de achtergrond: perl zeversolar_web.pl &
#
# Standaard poort: 3837  (bereikbaar via http://<pi-ip>:3837/)
#

use strict;
use warnings;
use IO::Socket::INET;
use JSON;
use POSIX qw(strftime);
use File::Basename qw(dirname);

my $PORT       = 3837;
my $STATE_FILE = "/tmp/zeversolar_state.json";
my $WWW_DIR    = dirname(__FILE__) . "/www";

# MQTT instellingen — zelfde als in zeversolar.ini
my $MQTT_HOST  = "192.168.1.113";
my $MQTT_PORT  = 1883;
my $MQTT_USER  = "zeversolar";
my $MQTT_PASS  = "zeversolar";
my $MQTT_TOPIC = "zeversolar/SX00046011830383/power_limit/set";

my %MIME = (
    html => 'text/html; charset=utf-8',
    css  => 'text/css',
    js   => 'application/javascript',
    png  => 'image/png',
    ico  => 'image/x-icon',
    json => 'application/json',
);

print "ZeverSolar webserver gestart op http://0.0.0.0:$PORT/\n";
print "State file: $STATE_FILE\n";
print "www dir:    $WWW_DIR\n";
print "Ctrl+C om te stoppen\n\n";

my $server = IO::Socket::INET->new(
    LocalPort => $PORT,
    Proto     => 'tcp',
    Listen    => 10,
    Reuse     => 1,
) or die "Kan geen socket openen op poort $PORT: $!\n";

while (1) {
    my $client = $server->accept() or next;

    # Lees HTTP request
    my $request = '';
    my $content_length = 0;
    while (my $line = <$client>) {
        $request .= $line;
        if ($line =~ /^Content-Length:\s*(\d+)/i) {
            $content_length = $1;
        }
        last if $line eq "\r\n";
    }

    # Lees body als POST
    my $body = '';
    if ($content_length > 0) {
        read($client, $body, $content_length);
    }

    # Parseer request line
    my ($method, $path) = $request =~ /^(GET|POST)\s+(\S+)\s+HTTP/;
    $path //= '/';
    $path =~ s/\?.*$//;

    # Route
    if ($path eq '/status' || $path eq '/status.json') {
        serve_json($client);
    } elsif ($path eq '/set_limit' && $method eq 'POST') {
        serve_set_limit($client, $body);
    } elsif ($path eq '/' || $path eq '/index.html') {
        serve_file($client, "$WWW_DIR/index.html", 'html');
    } else {
        my $file = $WWW_DIR . $path;
        $file =~ s|/+|/|g;
        if ($file !~ m|^\Q$WWW_DIR\E|) {
            send_response($client, 403, 'text/plain', 'Forbidden');
        } elsif (-f $file) {
            my ($ext) = $file =~ /\.(\w+)$/;
            serve_file($client, $file, $ext || 'html');
        } else {
            send_response($client, 404, 'text/plain', 'Not found: ' . $path);
        }
    }

    close $client;
}

# --- subroutines ---

sub serve_set_limit {
    my ($client, $body) = @_;

    my $data = eval { decode_json($body) };
    if ($@ || !defined $data->{limit}) {
        send_response($client, 400, 'application/json',
            encode_json({ error => 'Ongeldige JSON of ontbrekend limit veld' }));
        return;
    }

    my $limit = int($data->{limit});
    $limit = 99 if $limit > 99;
    $limit = 5  if $limit < 5;

    # Publiceer via mosquitto_pub naar het /set topic
    my $cmd = "mosquitto_pub -h $MQTT_HOST -p $MQTT_PORT -u \"$MQTT_USER\" -P \"$MQTT_PASS\" -q 1 -r -t '$MQTT_TOPIC' -m '$limit'";
    my $result = system($cmd);

    if ($result == 0) {
        print "Web: power limit $limit% verstuurd via MQTT\n";
        send_response($client, 200, 'application/json',
            encode_json({ ok => 1, limit => $limit }));
    } else {
        send_response($client, 500, 'application/json',
            encode_json({ error => 'mosquitto_pub mislukt' }));
    }
}

sub serve_json {
    my ($client) = @_;

    my $json;
    if (-e $STATE_FILE) {
        open(my $fh, '<', $STATE_FILE) or do {
            send_response($client, 500, 'application/json',
                encode_json({ error => "Cannot read state file: $!" }));
            return;
        };
        local $/;
        $json = <$fh>;
        close $fh;

        eval { decode_json($json) };
        if ($@) {
            send_response($client, 500, 'application/json',
                encode_json({ error => 'Corrupt state file' }));
            return;
        }
    } else {
        $json = encode_json({
            error     => 'No data yet — omvormer nog niet verbonden',
            pac       => 0,
            e_today   => 0,
            e_total   => 0,
            temp      => 0,
            timestamp => strftime("%Y-%m-%d %H:%M:%S", localtime),
        });
    }

    send_response($client, 200, 'application/json', $json);
}

sub serve_file {
    my ($client, $file, $ext) = @_;

    open(my $fh, '<:raw', $file) or do {
        send_response($client, 404, 'text/plain', "File not found: $file");
        return;
    };
    local $/;
    my $content = <$fh>;
    close $fh;

    my $mime = $MIME{lc($ext)} || 'application/octet-stream';
    send_response($client, 200, $mime, $content);
}

sub send_response {
    my ($client, $code, $mime, $body) = @_;
    my $len = length($body);
    my $status = $code == 200 ? 'OK'
               : $code == 400 ? 'Bad Request'
               : $code == 403 ? 'Forbidden'
               : $code == 404 ? 'Not Found'
               :                'Internal Server Error';

    print $client "HTTP/1.1 $code $status\r\n";
    print $client "Content-Type: $mime\r\n";
    print $client "Content-Length: $len\r\n";
    print $client "Access-Control-Allow-Origin: *\r\n";
    print $client "Connection: close\r\n";
    print $client "\r\n";
    print $client $body;
}
