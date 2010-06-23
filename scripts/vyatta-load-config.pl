#!/usr/bin/perl

# Author: An-Cheng Huang <ancheng@vyatta.com.
# Date: 2007
# Description: Perl script for loading config file at run time.

# **** License ****
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2006, 2007, 2008 Vyatta, Inc.
# All Rights Reserved.
# **** End License ****

# $0: config file.

use strict;
use lib "/opt/vyatta/share/perl5/";
use POSIX;
use IO::Prompt;
use Getopt::Long;
use Sys::Syslog qw(:standard :macros);
use Vyatta::ConfigLoad;

$SIG{'INT'} = 'IGNORE';

my $etcdir       = $ENV{vyatta_sysconfdir};
my $sbindir      = $ENV{vyatta_sbindir};
my $bootpath     = $etcdir . "/config";
my $load_file    = $bootpath . "/config.boot";
my $url_tmp_file = $bootpath . "/config.boot.$$";


#
# Note: to get merge to work on arbitrary nodes
# within the configuration multinodes need to be escaped.
# i.e.:
# load --merge='load-balancing/wan/interface-health\ eth0'
#
# will start loading of the configuration node from:
#
# load-balancing/wan/interface-health:eth0
#
# Note current loading is limited to first new
# multinode.
#
sub usage() {
    print "Usage: $0 --merge=<root>\n";
    exit 0;
}

my $merge;
GetOptions(
    "merge:s"              => \$merge,
    ) or usage();

my $merge_mode = 'false';
if (defined $merge) {
    $merge_mode = 'true';
}

my $mode = 'local';
my $proto;

if ( defined( $ARGV[0] ) ) {
    $load_file = $ARGV[0];
}
my $orig_load_file = $load_file;

if ( $load_file =~ /^[^\/]\w+:\// ) {
    if ( $load_file =~ /^(\w+):\/\/\w/ ) {
        $mode  = 'url';
        $proto = lc($1);
        unless( $proto eq 'tftp' ||
		$proto eq 'ftp'  ||
		$proto eq 'http' ||
		$proto eq 'scp' ) {
	    die "Invalid url protocol [$proto]\n";
        }
    } else {
        print "Invalid url [$load_file]\n";
        exit 1;
    }
}

if ( $mode eq 'local' and !( $load_file =~ /^\// ) ) {
    # relative path
    $load_file = "$bootpath/$load_file";
}

my $cfg;
if ( $mode eq 'local' ) {
    die "Cannot open configuration file $load_file: $!\n"
	unless open( $cfg, '<', $load_file);
}
elsif ( $mode eq 'url' ) {
    if ( !-f '/usr/bin/curl' ) {
        print "Package [curl] not installed\n";
        exit 1;
    }
    if ( $proto eq 'http' ) {

        #
        # error codes are send back in html, so 1st try a header
        # and look for "HTTP/1.1 200 OK"
        #
        my $rc = `curl -q -I $load_file 2>&1`;
        if ( $rc =~ /HTTP\/\d+\.?\d\s+(\d+)\s+(.*)$/mi ) {
            my $rc_code   = $1;
            my $rc_string = $2;
            if ( $rc_code == 200 ) {

                # good resonse
            }
            else {
                print "http error: [$rc_code] $rc_string\n";
                exit 1;
            }
        }
        else {
            print "Error: $rc\n";
            exit 1;
        }
    }
    my $rc = system("curl -# -o $url_tmp_file $load_file");
    if ($rc) {
        print "Can not open remote configuration file $load_file\n";
        exit 1;
    }
    die "Cannot open configuration file $load_file: $!\n"
	unless open( $cfg, '<', $url_tmp_file);

    $load_file = $url_tmp_file;
}

my $xorp_cfg  = 0;
my $valid_cfg = 0;
while (<$cfg>) {
    if (/\/\*XORP Configuration File, v1.0\*\//) {
        $xorp_cfg = 1;
        last;
    }
    elsif (/vyatta-config-version/) {
        $valid_cfg = 1;
        last;
    }
}
if ( $xorp_cfg or !$valid_cfg ) {
    if ($xorp_cfg) {
        print "Warning: Loading a pre-Glendale configuration.\n";
    }
    else {
        print "Warning: file does NOT appear to be a valid config file.\n";
    }
    if ( !prompt( "Do you want to continue? ", -tty, -Yes, -default => 'no' ) )
    {
        print "Configuration not loaded\n";
        exit 1;
    }
}
close $cfg;

# log it
openlog( $0, "", LOG_USER );
my $login = getlogin() || getpwuid($<) || "unknown";
syslog( "warning", "Load config [$orig_load_file] by $login" );

# do config migration
system("$sbindir/vyatta_config_migrate.pl $load_file");

print "Loading configuration from '$load_file'...\n";
my %cfg_hier = Vyatta::ConfigLoad::loadConfigHierarchy($load_file,$merge);
if ( scalar( keys %cfg_hier ) == 0 ) {
    print "The specified file does not contain any configuration.\n";
    print
      "Do you want to remove everything in the running configuration? [no] ";
    my $resp = <STDIN>;
    if ( !( $resp =~ /^yes$/i ) ) {
        print "Configuration not loaded\n";
        exit 1;
    }
}

my %cfg_diff = Vyatta::ConfigLoad::getConfigDiff( \%cfg_hier, 'true' );
my @set_list    = @{ $cfg_diff{'set'} };
my @deactivate_list    = @{ $cfg_diff{'deactivate'} };
my @activate_list = @{ $cfg_diff{'activate'} };
my @comment_list    = @{ $cfg_diff{'comment'} };

if ($merge_mode eq 'false') {
    my @delete_list = @{ $cfg_diff{'delete'} };
    
    foreach (@delete_list) {
	my ( $cmd_ref, $rank ) = @{$_};
	my @cmd = ( "$sbindir/my_delete", @{$cmd_ref} );
	my $cmd_str = join ' ', @cmd;
	system("$cmd_str");
	if ( $? >> 8 ) {
	    $cmd_str =~ s/^$sbindir\/my_//;
	    print "\"$cmd_str\" failed\n";
	}
    }
}

foreach (@set_list) {
    my ( $cmd_ref, $rank ) = @{$_};
    my @cmd = ( "$sbindir/my_set", @{$cmd_ref} );
    my $cmd_str = join ' ', @cmd;
    system("$cmd_str");
    if ( $? >> 8 ) {
        $cmd_str =~ s/^$sbindir\/my_//;
        print "\"$cmd_str\" failed\n";
    }
}




foreach (@activate_list) {
    my $cmd = "$sbindir/vyatta-activate-config.pl activate $_";
    system("$cmd 1>/dev/null");
    #ignore error on complaint re: nested nodes
}

foreach (@deactivate_list) {
    my @cp = split(" ",$_);
    my $p = join("/",@cp[0..$#cp-1]);
    my $leaf = "$ENV{VYATTA_TEMP_CONFIG_DIR}/$p/node.val";
    my $c = "";
    if (-e $leaf) {
	$c = join(" ",@cp[0..$#cp-1]);
    }
    else {
	$c = join(" ",@cp);
    }
    my $cmd = "$sbindir/vyatta-activate-config.pl deactivate $c";
    system("$cmd 1>/dev/null");
    #ignore error on complaint re: nested nodes
}

foreach (@comment_list) {
    my ( $cmd_ref ) = $_;
    #apply comment if it doesn't have an empty element at the array and a .comment file exists and this is not a merge
    if ($merge_mode eq 'false' && $cmd_ref =~ /\"\"$/) {
	my @cmd_array = split(" ",$cmd_ref);
	pop(@cmd_array);
	my $rel_path = join '/', @cmd_array;
	my $path = "/opt/vyatta/config/active/" . $rel_path . "/.comment";
	if (-e $path) {
	    my @cmd = ( "$sbindir/vyatta-comment-config.pl ", $cmd_ref );
	    my $cmd_str = join ' ', @cmd;
	    system("$cmd_str 1>/dev/null");
	}
	else {
	    #not found, maybe a leaf?
	    pop(@cmd_array);
	    $rel_path = join '/', @cmd_array;
	    my $leaf = "/opt/vyatta/config/active/" . $rel_path . "/node.val";
	    if (-e $leaf) {
		$path = "/opt/vyatta/config/active/" . $rel_path . "/.comment";
		if (-e $path) {
		    my @cmd = ( "$sbindir/vyatta-comment-config.pl ", $cmd_ref );
		    my $cmd_str = join ' ', @cmd;
		    system("$cmd_str 1>/dev/null");
		}
	    }
	}
    }
    else {
	my @cmd = ( "$sbindir/vyatta-comment-config.pl ", $cmd_ref );
	my $cmd_str = join ' ', @cmd;
	system("$cmd_str 1>/dev/null");
    }
    #ignore error on complaint re: nested nodes
}

system("$sbindir/my_commit");
if ( $? >> 8 ) {
    print "Load failed (commit failed)\n";
    exit 1;
}

print "Done\n";
exit 0;
