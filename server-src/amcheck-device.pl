#! @PERL@
# Copyright (c) 2009-2012 Zmanda Inc.  All Rights Reserved.
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
use strict;
use warnings;

use Amanda::Util qw( :constants );
use Amanda::Config qw( :init :getconf );
use Amanda::Logfile qw( :logtype_t log_add $amanda_log_trace_log );
use Amanda::Debug;
use Amanda::Device qw( :constants );
use Amanda::MainLoop;
use Amanda::Policy;
use Amanda::Storage;
use Amanda::Changer;
use Amanda::Taper::Scan;
use Amanda::Interactivity;
use Getopt::Long;

Amanda::Util::setup_application("amcheck-device", "server", $CONTEXT_CMDLINE, "amanda", "amanda");

my $config_overrides = new_config_overrides($#ARGV+1);
my $overwrite = 0;
my $opt_message = 0;
Getopt::Long::Configure(qw{bundling});
GetOptions(
    'version' => \&Amanda::Util::version_opt,
    'o=s' => sub { add_config_override_opt($config_overrides, $_[1]); },
    'message' => \$opt_message,
    'w' => \$overwrite,
) or usage();

sub usage {
    print STDERR "USAGE: amcheck-device <config> <storage> [--message] [-w] <config-overwrites>";
    exit 1;
}

if (@ARGV != 2) {
    usage();
}

set_config_overrides($config_overrides);
config_init_with_global($CONFIG_INIT_EXPLICIT_NAME, $ARGV[0]);
my ($cfgerr_level, @cfgerr_errors) = config_errors();
if ($cfgerr_level >= $CFGERR_WARNINGS) {
    config_print_errors();
    if ($cfgerr_level >= $CFGERR_ERRORS) {
        print STDERR "Errors processing config file";
	exit 1;
    }
}

my $storage_name = $ARGV[1];
my $storage;
Amanda::Util::finish_setup($RUNNING_AS_DUMPUSER);
my $exit_status = 0;

sub _user_msg_fn {
        my %params = @_;
        if (exists $params{'scan_failed'}) {
	    print STDERR "Taper scan algorithm did not find an acceptable volume.\n";
	    if ($params{'expected_label'} or $params{'expected_new'}) {
		my @exp;
		if ($params{'expected_label'}) {
		    push @exp, "volume '$params{expected_label}'";
		}
		if ($params{'expected_new'}) {
		    push @exp, "a new volume";
		}
		my $exp = join(" or ", @exp);
		print STDERR "    (expecting $exp)\n";
	    }
	} elsif (exists($params{'text'})) {
            print STDERR "$params{'text'}\n";
        } elsif (exists($params{'scan_slot'})) {
            print STDERR "slot $params{'slot'}:";
        } elsif (exists($params{'search_label'})) {
            print STDERR "Searching for label '$params{'label'}':";
        } elsif (exists($params{'slot_result'}) ||
                 exists($params{'search_result'})) {
            if (defined($params{'err'}) and
		 (ref($params{'err'}) eq "HASH" ||
		  ref($params{'err'}) eq "Amanda::Changer::Error")) {
                if (exists($params{'search_result'}) &&
                    defined($params{'err'}->{'this_slot'})) {
                    print STDERR "slot $params{'err'}->{'this_slot'}: ";
                }
                print STDERR "$params{'err'}\n";
            } elsif (!$params{'res'}) {
                my $volume_label = $params{'label'};
		if ($params{'slot'}) {
		    print STDERR "slot $params{'slot'}:";
		}
                if ($params{'active'}) {
                    print STDERR " volume '$volume_label' is still active and cannot be overwritten\n";
                } elsif ($params{'does_not_match_labelstr'}) {
                    print STDERR " volume '$volume_label' does not match labelstr '$params{'labelstr'}'\n";
                } elsif ($params{'not_in_tapelist'}) {
                    print STDERR " volume '$volume_label' is not in the tapelist\n"
		} elsif ($params{'non_amanda'}) {
		    print STDERR " not an amanda volume\n";
		} elsif ($params{'volume_error'}) {
		    print STDERR " $params{'err'}\n";
		} elsif ($params{'not_autolabel'}) {
		    print STDERR " The volume can't be labelled\n";
		} elsif ($params{'empty'}) {
		    print STDERR " The volume is empty\n";
		} elsif ($params{'not_success'}) {
		    print STDERR " $params{'err'}\n";
                } elsif (defined $volume_label) {
                    print STDERR " volume '$volume_label'\n";
		} elsif ($params{'err'}) {
		    print STDERR " $params{'err'}\n";
                } else {
                    #print STDERR " volume '$volume_label'\n";
                }
            } else { # res must be defined
		my $directtcp = "";
                my $res = $params{'res'};
                my $dev = $res->{'device'};

		if ($dev->directtcp_supported()) {
		    $directtcp = "DIRECTTCP ";
		}

                if (exists($params{'search_result'})) {
                    print STDERR "found in slot $res->{'this_slot'}:";
                }
                if ($dev->status == $DEVICE_STATUS_SUCCESS) {
                    my $volume_label = $res->{device}->volume_label;
                    if ($params{'active'}) {
                        print STDERR " volume '$volume_label' is still active and cannot be overwritten\n";
                    } elsif ($params{'does_not_match_labelstr'}) {
                        print STDERR " volume '$volume_label' does not match labelstr '$params{'labelstr'}'\n";
                    } elsif ($params{'not_in_tapelist'}) {
                        print STDERR " volume '$volume_label' is not in the tapelist\n"
                    } else {
                        print STDERR " volume '$volume_label'\n";
                    }
                } elsif ($dev->status & $DEVICE_STATUS_VOLUME_UNLABELED and
                         $dev->volume_header and
                         $dev->volume_header->{'type'} == $Amanda::Header::F_EMPTY) {
                    print STDERR " contains an empty volume\n";
                } elsif ($dev->status & $DEVICE_STATUS_VOLUME_UNLABELED and
                         $dev->volume_header and
                         $dev->volume_header->{'type'} == $Amanda::Header::F_WEIRD) {
		    my $autolabel = storage_getconf($storage, $STORAGE_AUTOLABEL);
		    if ($autolabel->{'non_amanda'}) {
			print STDERR " contains a non-Amanda volume\n";
		    } else {
			print STDERR " contains a non-Amanda volume; check and relabel it with 'amlabel -f'\n";
		    }
                } elsif ($dev->status & $DEVICE_STATUS_VOLUME_ERROR) {
                    my $message = $dev->error_or_status();
                    print STDERR " Can't read label: $message\n";
                } else {
                    my $errmsg = $res->{device}->error_or_status();
                    print STDERR " $errmsg\n";
                }
            }
        } else {
            print STDERR "UNKNOWN\n";
        }
}

sub failure {
    my ($msg, $finished_cb) = @_;
    print STDERR "ERROR: $msg\n";
    $exit_status = 1;
    $finished_cb->();
}

sub do_check {
    my ($finished_cb) = @_;
    my ($res, $label, $mode);
    my $tlf = Amanda::Config::config_dir_relative(getconf($CNF_TAPELIST));
    my ($tl, $message) = Amanda::Tapelist->new($tlf);
    if (defined $message) {
	if ($message->{'severity'} >= $Amanda::Message::CRITICAL) {
	    return failure("$message", $finished_cb);
	} else {
	    print STDERR "ERROR: $message\n";
	}
    }

    $storage  = Amanda::Storage->new(storage_name => $storage_name,
				     tapelist => $tl);
    return failure("$storage", $finished_cb) if $storage->isa("Amanda::Message");
    my $chg = $storage->{'chg'};
    if ($chg->isa("Amanda::Message")) {
	$storage->quit();
	return failure($chg, $finished_cb);
    }
    my $interactivity = Amanda::Interactivity->new(
					name => $storage->{'interactivity'});
    my $scan_name = $storage->{'taperscan_name'};
    my $taperscan = Amanda::Taper::Scan->new(algorithm => $scan_name,
					     storage => $storage,
					     changer => $chg,
					     interactivity => $interactivity,
					     tapelist => $tl);

    my $steps = define_steps
	cb_ref => \$finished_cb,
	finalize => sub { $storage->quit();
			  $taperscan->quit(); };

    step start => sub {
	$taperscan->scan(
	    result_cb => $steps->{'result_cb'},
	    user_msg_fn => \&_user_msg_fn
	);
    };

    step result_cb => sub {
	(my $err, $res, $label, $mode) = @_;
	if ($err) {
	    if ($res) {
		$res->release(finished_cb => sub {
		    return failure($err, $finished_cb);
		});
		return;
	    } else {
		return failure($err, $finished_cb);
	    }
	}

	my $modestr = ($mode == $ACCESS_APPEND)? "append" : "write";
	my $slot = $res->{'this_slot'};
	if (defined $res->{'device'} and defined $res->{'device'}->volume_label()) {
	    print "Will $modestr to volume '$label' in slot $slot.\n";
	} else {
	    my $header = $res->{'device'}->volume_header();
	    if (defined $header and defined $header->{'type'} and
		$header->{'type'} == $Amanda::Header::F_WEIRD) {
		print "Will $modestr label '$label' to non-Amanda volume in slot $slot.\n";
	    } else {
		print "Will $modestr label '$label' to new volume in slot $slot.\n";
	    }
	}

	$steps->{'check_access_type'}->();
    };

    step check_access_type => sub {
	my $mat = $res->{'device'}->property_get('medium_access_type');
	if (defined $mat and $mat == $MEDIA_ACCESS_MODE_WRITE_ONLY) {
	    print "WARNING: Media access mode is WRITE_ONLY; dumps may not be recoverable\n";
	}

	if ($storage->{'seen_device_output_buffer_size'}) {
	    my $dobs = $storage->{'device_output_buffer_size'};
	    my $block_size = $res->{'device'}->property_get("BLOCK_SIZE");
	    if ($block_size * 2 > $dobs) {
		print "WARNING: DEVICE-OUTPUT-BUFFER-SIZE is not at least twice the block size of the device, it should be increased for better throughput\n";
	    }
	}
	$steps->{'check_writable'}->();
    };

    step check_writable => sub {

	if($res->{'device'} and !$res->{'device'}->check_writable()) {
	    print "ERROR: " . $res->{'device'}->error_or_status() . "\n";
	    return $steps->{'release'}->();
	}
	$steps->{'check_overwrite'}->();
    };

    step check_overwrite => sub {
	# if we're not overwriting, just release the reservation
	if (!$overwrite) {
	    print "NOTE: skipping tape-writable test\n";
	    return $steps->{'release'}->();
	}

	if ($mode != $ACCESS_WRITE) {
	    my $modestr = Amanda::Device::DeviceAccessMode_to_string($mode);
	    print "NOTE: taperscan specified access mode $modestr; skipping volume-writeable test\n";
	    return $steps->{'release'}->();
	}

	print "Writing label '$label' to check writability\n";
	if (!$res->{'device'}->start($ACCESS_WRITE, $label, "X")) {
	    print "ERROR: writing to volume: " . $res->{'device'}->error_or_status(), "\n";
	    $exit_status = 1;
	} else {
	    print "Volume '$label' is writeable.\n";
	}

	$steps->{'release'}->();
    };

    step release => sub {
	$res->release(finished_cb => $steps->{'released'});
    };

    step released => sub {
	my ($err) = @_;
	return failure($err, $finished_cb) if $err;

	$finished_cb->();
    };
}

Amanda::MainLoop::call_later(\&do_check, \&Amanda::MainLoop::quit);
Amanda::MainLoop::run();
Amanda::Util::finish_application();
exit($exit_status);
