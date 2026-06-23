#!/usr/bin/perl
#
# zeversolar_status.pl — CGI JSON endpoint for the Zeversolar dashboard
#
# Install in your CGI directory, e.g. /usr/lib/cgi-bin/zeversolar_status.pl
# Make executable: chmod +x zeversolar_status.pl
#
# eversolar.pl writes a small JSON state file to /tmp/zeversolar_state.json
# every poll cycle. This CGI reads that file and returns it.
#
# Add to eversolar.ini:  state_file = /tmp/zeversolar_state.json
#

use strict;
use warnings;
use JSON;
use POSIX qw(strftime);

my $state_file = "/tmp/zeversolar_state.json";

print "Content-Type: application/json\r\n";
print "Access-Control-Allow-Origin: *\r\n";
print "\r\n";

if ( -e $state_file ) {
    open( my $fh, '<', $state_file ) or do {
        print encode_json({ error => "Cannot read state file: $!" });
        exit;
    };
    local $/;
    my $json = <$fh>;
    close $fh;
    # Validate it's valid JSON before passing through
    eval { decode_json($json) };
    if ($@) {
        print encode_json({ error => "Invalid state file" });
    } else {
        print $json;
    }
} else {
    print encode_json({
        error     => "No data yet",
        pac       => 0,
        e_today   => 0,
        e_total   => 0,
        temp      => 0,
        vac1      => 0, vac2 => 0, vac3 => 0,
        iac1      => 0, iac2 => 0, iac3 => 0,
        vpv1      => 0, vpv2 => 0,
        ipv1      => 0, ipv2 => 0,
        frequency => 0,
        hours_up  => 0,
        op_mode   => 0,
        impedance => 0,
        power_limit => 0,
        timestamp => strftime("%Y-%m-%d %H:%M:%S", localtime),
    });
}
