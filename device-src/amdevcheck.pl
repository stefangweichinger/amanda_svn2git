#! @PERL@
# Copyright (c) 2009-2012 Zmanda, Inc.  All Rights Reserved.
# Copyright (c) 2013-2016 Carbonite, Inc.  All Rights Reserved.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
# for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 59 Temple Place, Suite 330, Boston, MA  02111-1307 USA
#
# Contact information: Carbonite Inc., 756 N Pastoria Ave
# Sunnyvale, CA 94086, USA, or: http://www.zmanda.com

use lib '@amperldir@';
use Getopt::Long;

use strict;
use warnings;
use Amanda::Device qw( :constants );
use Amanda::Config qw( :getconf :init );
use Amanda::Debug qw( :logging );
use Amanda::Util qw( :constants );
use Amanda::Storage;
use Amanda::Changer;

# try to open the device and read its label, returning the device_read_label
# result (one or more of ReadLabelStatusFlags)
sub try_read_label {
    my ($device) = @_;

    my $result;
    $result = $device->read_label();
    if ($device->status() != $DEVICE_STATUS_SUCCESS ) {
        $result = $device->status();
    }
    return $result;
}

sub list_device_property {
    my ( $device, $plist ) = @_;
    my @proplist;

    my $result;
    if (!$plist ) {
        if ($device->status() == $DEVICE_STATUS_SUCCESS ) {
            my @list = $device->property_list();
            foreach my $line (@list) {
                push(@proplist, $line->{'name'} );
            }
        } else {
            $result = $device->status();
            print_result($result, $device->error() );
            return $result;
        }
    } else {
        @proplist = split(/,/, $plist );
    }

    foreach my $prop (sort @proplist ) {
        my $value = $device->property_get(lc($prop) );
        print uc($prop) . "=$value\n" if (defined($value) );
    }
    return;
}

# print the results, one flag per line
sub print_result {
    my ($flags, $errmsg) = @_;

    if ($flags != $DEVICE_STATUS_SUCCESS) {
	print "MESSAGE $errmsg\n";
    }
    print join( "\n", DeviceStatusFlags_to_strings($flags) ), "\n";
}

sub usage {
    print <<EOF;
Usage: amdevcheck [--label] [--properties {prop1,prop2,prop3}] [-o configoption]* <config> [<device name>]
EOF
    exit(1);
}

## Application initialization

Amanda::Util::setup_application("amdevcheck", "server", $CONTEXT_SCRIPTUTIL, "amanda", "amanda");

my $config_overrides = new_config_overrides($#ARGV+1);
my $getproplist;
my $device_name;
my $print_label;

debug("Arguments: " . join(' ', @ARGV));
Getopt::Long::Configure(qw(bundling));
GetOptions(
    'version' => \&Amanda::Util::version_opt,
    'help|usage|?' => \&usage,
    'o=s' => sub { add_config_override_opt($config_overrides, $_[1]); },
    'properties:s' => \$getproplist,
    'label' => \$print_label
) or usage();

usage() if ( @ARGV < 1 || @ARGV > 3 );
my $config_name = $ARGV[0];

set_config_overrides($config_overrides);
config_init_with_global($CONFIG_INIT_EXPLICIT_NAME, $config_name);
my ($cfgerr_level, @cfgerr_errors) = config_errors();
if ($cfgerr_level >= $CFGERR_WARNINGS) {
    config_print_errors();
    if ($cfgerr_level >= $CFGERR_ERRORS) {
	die("errors processing config file");
    }
}

Amanda::Util::finish_setup($RUNNING_AS_DUMPUSER);

my $result;

if (defined $getproplist && defined $print_label) {
    die("Can't set both --label and --properties");
}

my $chg;
my $res;
my $device;
if ( $#ARGV == 1 ) {
    $device_name = $ARGV[1];
    $device = Amanda::Device->new($device_name);
} elsif (getconf_seen($CNF_TAPEDEV)) {
    $device_name = getconf($CNF_TAPEDEV);
    $device = Amanda::Device->new($device_name);
} else {
    my ($storage, $err) = Amanda::Storage->new();
    die "$err" if !$storage;
    $chg = $storage->{'chg'};
    $chg->load(relative_slot => "current",
	res_cb => sub {
	    (my $err, $res) = @_;
	    $device = $res->{'device'};
	    $device_name = $device->device_name();
	    Amanda::MainLoop::quit();
    });
    Amanda::MainLoop::run();
}

if ( !$device ) {
    die("Error creating $device_name");
}

$result = $device->status();
my $exit_status = 0;
if ($result == $DEVICE_STATUS_SUCCESS ||
    $result == $DEVICE_STATUS_VOLUME_UNLABELED) {
    $device->configure(1);
    if (defined $getproplist) {
        list_device_property($device,$getproplist);
    } else {
	$result = try_read_label($device);
	if (defined $print_label) {
            if ($result == $DEVICE_STATUS_SUCCESS) {
		print $device->volume_label(), "\n";
            } else {
		$exit_status = 1;
	    }
	} else {
            print_result($result, $device->error());
	}
    }
} else {
    if (!defined $getproplist && !defined $print_label) {
        print_result($result, $device->error());
    } else {
        $exit_status = 1;
    }
}

if ($res) {
    $res->release(finished_cb => sub { Amanda::MainLoop::quit() });
    Amanda::MainLoop::run();
}
$chg->quit() if $chg;

Amanda::Util::finish_application();
exit $exit_status;
