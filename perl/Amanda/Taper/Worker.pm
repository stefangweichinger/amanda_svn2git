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

=head1 NAME

Amanda::Taper::Worker

=head1 DESCRIPTION

This package is a component of the Amanda taper, and is not intended for use by
other scripts or applications.

This package interface between L<Amanda::Taper::Controller> and L<Amanda::Taper::Scribe>.

The worker use an L<Amanda::Taper::Scribe> object to execute the request
received from the L<Amanda::Taper::Controller>.

=cut

use strict;
use warnings;

package Amanda::Taper::Worker;

use Carp;
use POSIX qw( :errno_h );
use Amanda::Changer;
use Amanda::Config qw( :getconf config_dir_relative );
use Amanda::Debug qw( :logging );
use Amanda::Device qw( :constants );
use Amanda::Header;
use Amanda::Holding;
use Amanda::MainLoop qw( :GIOCondition );
use Amanda::MainLoop;
use Amanda::Taper::Protocol;
use Amanda::Taper::Scan;
use Amanda::Taper::Scribe qw( get_splitting_args_from_config );
use Amanda::Logfile qw( :logtype_t log_add make_stats );
use Amanda::Xfer qw( :constants );
use Amanda::Util qw( quote_string );
use Amanda::Tapelist;
use Amanda::Recovery::Planner;
use Amanda::Recovery::Scan;
use Amanda::Recovery::Clerk;
use File::Temp;

use parent -norequire, qw( Amanda::Taper::Scribe::Feedback Amanda::Recovery::Clerk::Feedback);

our $tape_num = 0;

sub new {
    my $class           = shift;
    my $taper_name      = shift;
    my $worker_name     = shift;
    my $controller      = shift;
    my $write_timestamp = shift;

    my $self = bless {
	state       => "init",
	taper_name  => $taper_name,
	worker_name => $worker_name,
	controller  => $controller,
	scribe      => undef,
	timestamp   => $write_timestamp,

	# filled in when a write starts:
	xfer => undef,
	xfer_source => undef,
	xfer_dest => undef,
	handle => undef,
	hostname => undef,
	diskname => undef,
	datestamp => undef,
	level => undef,
	header => undef,
	doing_port_write => undef,
	doing_shm_write => undef,
	input_errors => [],

	# periodic status updates
	timer => undef,
	status_filename => undef,
	status_fh => undef,

	# filled in after the header is available
	header => undef,

	# filled in when a new tape is started:
	label => undef
    }, $class;

    my $scribe = Amanda::Taper::Scribe->new(
	worker => $self,
	taperscan => $controller->{'taperscan'},
	feedback => $self,
	debug => $Amanda::Config::debug_taper);

    $self->{'scribe'} = $scribe;
    $self->{'scribe'}->start(write_timestamp => $write_timestamp,
	finished_cb => sub { $self->_scribe_started_cb(@_); });

    return $self;
}

# called when the scribe is fully started up and ready to go
sub _scribe_started_cb {
    my $self = shift;
    my $err  = shift;
    my $allow_take_scribe_from = shift;

    if ($err) {
	$self->{'controller'}->{'proto'}->send(Amanda::Taper::Protocol::TAPE_ERROR,
		worker_name  => $self->{'worker_name'},
		message => "$err");
	$self->{'state'} = "error";

	# log the error (note that the message is intentionally not quoted)
	log_add($L_ERROR, "no-tape error [$err]");

    } else {
	$self->{'controller'}->{'proto'}->send(Amanda::Taper::Protocol::TAPER_OK,
		worker_name => $self->{'worker_name'},
		allow_take_scribe_from => $allow_take_scribe_from?"ALLOW-TAKE-SCRIBE-FROM":"NO-TAKE-SCRIBE-FROM");
	$self->{'state'} = "idle";
    }
}


sub FILE_WRITE {
    my $self = shift;
    my ($msgtype, %params) = @_;
    $self->_assert_in_state("idle") or return;

    $self->{'doing_port_write'} = 0;
    $self->{'doing_shm_write'} = 0;
    $self->{'doing_vault'} = 0;

    $self->setup_and_start_dump($msgtype,
	dump_cb => sub { $self->dump_cb(@_); },
	%params);
}

sub PORT_WRITE {
    my $self = shift;
    my ($msgtype, %params) = @_;

    my $read_cb;

    $self->_assert_in_state("idle") or return;

    $self->{'doing_port_write'} = 1;
    $self->{'doing_shm_write'} = 0;
    $self->{'doing_vault'} = 0;

    $self->setup_and_start_dump($msgtype,
	dump_cb => sub { $self->dump_cb(@_); },
	%params);
}

sub SHM_WRITE {
    my $self = shift;
    my ($msgtype, %params) = @_;

    my $read_cb;

    $self->_assert_in_state("idle") or return;

    $self->{'doing_port_write'} = 0;
    $self->{'doing_shm_write'} = 1;
    $self->{'doing_vault'} = 0;

    $self->setup_and_start_dump($msgtype,
	dump_cb => sub { $self->dump_cb(@_); },
	%params);
}

sub VAULT_WRITE {
    my $self = shift;
    my ($msgtype, %params) = @_;

    my $read_cb;

    $self->_assert_in_state("idle") or return;

    $self->{'doing_port_write'} = 0;
    $self->{'doing_shm_write'} = 0;
    $self->{'doing_vault'} = 1;

    $self->setup_and_start_dump($msgtype,
	dump_cb => sub { $self->dump_cb(@_); },
	%params);
}

sub START_SCAN {
    my $self = shift;
    my ($msgtype, %params) = @_;

    $self->{'scribe'}->start_scan(undef);
}

sub NEW_TAPE {
    my $self = shift;
    my ($msgtype, %params) = @_;

    $self->_assert_in_state("writing") or return;

    $self->{'perm_cb'}->(allow => 1);
}

sub NO_NEW_TAPE {
    my $self = shift;
    my ($msgtype, %params) = @_;

    $self->_assert_in_state("writing") or return;

    # log the error (note that the message is intentionally not quoted)
    log_add($L_ERROR, "no-tape config [$params{reason}]");

    $self->{'perm_cb'}->(cause => "config", message => $params{'reason'});
}

sub TAKE_SCRIBE_FROM {
    my $self = shift;
    my ($worker1, $msgtype, %params) = @_;

    $self->_assert_in_state("writing") or return;
    $worker1->_assert_in_state("idle") or return;

    my $scribe = $self->{'scribe'};
    my $scribe1 = $worker1->{'scribe'};
    $self->{'scribe'} = $scribe1;
    $scribe1->{'worker'} = $self;
    $worker1->{'scribe'} = $scribe;
    $scribe->{'worker'} = $worker1;

    $self->{'label'} = $worker1->{'label'};
    $self->{'perm_cb'}->(scribe => $scribe1);
    delete $worker1->{'scribe'};
    $worker1->{'state'} = 'error';
    $scribe->quit(finished_cb => sub {});
    $scribe1->{'cancelled'} = 0;
 }

sub DONE {
    my $self = shift;
    my ($msgtype, %params) = @_;

    if (!defined($self->{'handle'}) or $params{'handle'} ne $self->{'handle'}) {
	# ignore message for previous handle
	return;
    }

    if (defined $self->{'dumper_status'}) {
	# ignore duplicate message
	return
    }

    $self->{'dumper_status'} = "DONE";
    $self->{'orig_kb'} = $params{'orig_kb'};
    $self->{'native_crc'} = $params{'native_crc'};
    $self->{'client_crc'} = $params{'client_crc'};
    if (defined $self->{'result'}) {
	$self->result_cb(undef);
    }
}

sub FAILED {
    my $self = shift;
    my ($msgtype, %params) = @_;

    if (!defined($self->{'handle'}) or $params{'handle'} ne $self->{'handle'}) {
	# ignore message for previous handle
	return;
    }

    if (defined $self->{'dumper_status'}) {
	# ignore duplicate message
	return
    }

    $self->{'dumper_status'} = "FAILED";
    if (defined $self->{'header_xfer'}) {
	$self->{'header_xfer'}->cancel();
    } elsif (defined $self->{'result'}) {
	$self->result_cb(undef);
    } elsif (!defined $self->{'scribe'}->{'xdt'}) {
	# ignore, the dump is already cancelled or not yet started.
    } elsif (!defined $self->{'scribe'}->{'xfer'}) {
	# ignore, the dump is already cancelled or not yet started.
    } else { # Abort the dump
	push @{$self->{'input_errors'}}, "dumper failed";
	$self->{'scribe'}->cancel_dump(
		xfer => $self->{'scribe'}->{'xfer'},
		dump_cb => $self->{'dump_cb'});
    }
}

sub CLOSE_VOLUME {
    my $self = shift;
    my ($msgtype, %params) = @_;

    $self->_assert_in_state("idle") or return;

    $self->{'scribe'}->close_volume(close_volume_cb => sub {
	    my %msg_params = (
		worker_name => $self->{'worker_name'}
	    );
	    $msgtype = Amanda::Taper::Protocol::CLOSED_VOLUME;
	    $self->{'controller'}->{'proto'}->send($msgtype, %msg_params);
    });
}

sub CLOSE_SOURCE_VOLUME {
    my $self = shift;
    my ($msgtype, %params) = @_;

    $self->_assert_in_state("idle") or return;

    $self->{'src'}->{'clerk'}->close_volume(close_volume_cb => sub {

	    my %msg_params = (
		worker_name => $self->{'worker_name'}
	    );
	    $msgtype = Amanda::Taper::Protocol::CLOSED_SOURCE_VOLUME;
	    $self->{'controller'}->{'proto'}->send($msgtype, %msg_params);
    }) if defined $self->{'src'}->{'clerk'};
}

sub result_cb {
    my $self = shift;
    my %params = %{$self->{'dump_params'}};
    my $msgtype;
    my $logtype;

    if (!defined $self->{'source_server_crc'}) {
	$self->{'source_server_crc'} = '00000000:0';
    }
    if (!defined $self->{'dest_server_crc'}) {
	$self->{'dest_server_crc'} = '00000000:0';
    }
    if (!defined $self->{'server_crc'}) {
	$self->{'server_crc'} = '00000000:0';
    }
    if ($self->{'server_crc'} ne '00000000:0' and
	$self->{'source_server_crc'} ne '00000000:0' and
	$self->{'server_crc'} ne $self->{'source_server_crc'}) {
	if ($params{'result'} eq 'DONE') {
	    $params{'result'} = 'PARTIAL';
	    push @{$self->{'input_errors'}}, "source server crc ($self->{'source_server_crc'}) and input server crc ($self->{'server_crc'}) differ)";
	}
    }

    if ($self->{'source_server_crc'} ne '00000000:0' and
	$self->{'dest_server_crc'} ne '00000000:0' and
	$self->{'source_server_crc'} ne $self->{'dest_server_crc'}) {
	if ($params{'result'} eq 'DONE') {
	    $params{'result'} = 'PARTIAL';
	    push @{$self->{'input_errors'}}, "source server crc ($self->{'source_server_crc'}) and dest server crc ($self->{'dest_server_crc'}) differ)";
	}
    }

    if ($self->{'server_crc'} ne '00000000:0' and
	$self->{'source_server_crc'} ne '00000000:0' and
	$self->{'server_crc'} ne $self->{'source_server_crc'}) {
	if ($params{'result'} eq 'DONE') {
	    $params{'result'} = 'PARTIAL';
	    push @{$self->{'input_errors'}}, "server crc ($self->{'server_crc'}) and source server crc ($self->{'source_server_crc'}) differ)";
	}
    }
    if ($self->{'server_crc'} eq '00000000:0') {
	$self->{'server_crc'} = $self->{'source_server_crc'};
    }

    if ($params{'result'} eq 'DONE') {
	if ($self->{'dumper_status'} eq "DONE") {
	    $msgtype = Amanda::Taper::Protocol::DONE;
	    $logtype = $L_DONE;
	} else {
	    $msgtype = Amanda::Taper::Protocol::DONE;
	    $logtype = $L_PARTIAL;
	}
    } elsif ($params{'result'} eq 'PARTIAL') {
	$msgtype = Amanda::Taper::Protocol::PARTIAL;
	$logtype = $L_PARTIAL;
    } elsif ($params{'result'} eq 'FAILED') {
	$msgtype = Amanda::Taper::Protocol::FAILED;
	$logtype = $L_FAIL;
    }

    if (!defined $params{'device_errors'}) {
	$params{'device_errors'} = [];
    }
    # note that we use total_duration here, which is the total time between
    # start_dump and dump_cb, so the kps generated here is much less than the
    # actual tape write speed.  Think of this as the *taper* speed, rather than
    # the *tape* speed.
    my $stats = make_stats($params{'size'}, $params{'total_duration'}, $self->{'orig_kb'});

    # consider this a config-derived failure only if there were no errors
    my $failure_from = (defined $params{'config_denial_message'})?  'config' : 'error';

    if (defined $params{'input_errors'}) {
	push @{$self->{'input_errors'}},  @{$params{'input_errors'}};
    }
    delete $params{'input_errors'};
    my @all_messages = (@{$params{'device_errors'}}, @{$self->{'input_errors'}});
    push @all_messages, $params{'config_denial_message'} if $params{'config_denial_message'};
    my $msg = quote_string(join("; ", @all_messages));

    # write a DONE/PARTIAL/FAIL log line
    if ($logtype == $L_FAIL) {
	my $format = "%s %s %s %s %s %s %s %s";
	$format = "VAULT %s %s %s %s %s %s %s %s" if $self->{'doing_vault'};
	log_add($L_FAIL, sprintf($format,
	    quote_string("ST:" . $self->{'controller'}->{'storage'}->{'storage_name'}),
	    quote_string("POOL:" . $self->{'controller'}->{'storage'}->{'tapepool'}),
	    quote_string($self->{'hostname'}.""), # " is required for SWIG..
	    quote_string($self->{'diskname'}.""),
	    $self->{'datestamp'},
	    $self->{'level'},
	    $failure_from,
	    $msg));
    } else {
	log_add($logtype, sprintf("%s %s %s %s %s %s %s %s %s %s %s%s",
	    quote_string("ST:" . $self->{'controller'}->{'storage'}->{'storage_name'}),
	    quote_string("POOL:" . $self->{'controller'}->{'storage'}->{'tapepool'}),
	    quote_string($self->{'hostname'}.""), # " is required for SWIG..
	    quote_string($self->{'diskname'}.""),
	    $self->{'datestamp'},
	    $params{'nparts'},
	    $self->{'level'},
	    $self->{'native_crc'},
	    $self->{'client_crc'},
	    $self->{'server_crc'},
	    $stats,
	    ($logtype == $L_PARTIAL and @all_messages)? " $msg" : ""));
    }

    # and send a message back to the driver
    my %msg_params = (
	handle => $self->{'handle'},
    );

    $msg_params{'server_crc'} = $self->{'dest_server_crc'};
    # reflect errors in our own elements in INPUT-ERROR or INPUT-GOOD
    if (@{$self->{'input_errors'}}) {
	$msg_params{'input'} = 'INPUT-ERROR';
	$msg_params{'inputerr'} = join("; ", @{$self->{'input_errors'}});
    } else {
	$msg_params{'input'} = 'INPUT-GOOD';
	$msg_params{'inputerr'} = '';
    }

    # and errors from the scribe in TAPE-ERROR or TAPE-GOOD
    if (@{$params{'device_errors'}}) {
	$msg_params{'taper'} = 'TAPE-ERROR';
	$msg_params{'tapererr'} = join("; ", @{$params{'device_errors'}});
    } elsif ($params{'config_denial_message'}) {
	$msg_params{'taper'} = 'TAPE-CONFIG';
	$msg_params{'tapererr'} = $params{'config_denial_message'};
    } else {
	$msg_params{'taper'} = 'TAPE-GOOD';
	$msg_params{'tapererr'} = '';
    }

    if ($msgtype ne Amanda::Taper::Protocol::FAILED) {
	$msg_params{'stats'} = $stats;
    }
    $msg_params{'worker_name'} = $self->{'worker_name'};

    # reset things to 'idle' before sending the message
    $self->{'xfer'} = undef;
    $self->{'xfer_source'} = undef;
    $self->{'xfer_dest'} = undef;
    $self->{'handle'} = undef;
    $self->{'hostname'} = undef;
    $self->{'diskname'} = undef;
    $self->{'datestamp'} = undef;
    $self->{'level'} = undef;
    $self->{'header'} = undef;
    $self->{'state'} = 'idle';
    delete $self->{'result'};
    delete $self->{'dumper_status'};
    delete $self->{'dump_params'};

    $self->{'controller'}->{'proto'}->send($msgtype, %msg_params);
    if ($self->{timer}) {
	$self->{timer}->remove();
	undef $self->{timer};
	$self->{status_fh}->close();
	undef $self->{status_fh};
	unlink($self->{status_filename});
	undef $self->{status_filename};
    }
}


##
# Scribe feedback

sub request_volume_permission {
    my $self = shift;
    my %params = @_;

    $self->{'perm_cb'} = $params{'perm_cb'};
    # and send the request to the driver
    $self->{'controller'}->{'proto'}->send(Amanda::Taper::Protocol::REQUEST_NEW_TAPE,
	worker_name => $self->{'worker_name'},
	handle => $self->{'handle'});
}

sub scribe_notif_new_tape {
    my $self = shift;
    my %params = @_;

    # TODO: if $params{error} is set, report it back to the driver
    # (this will be a change to the protocol)
    log_add($L_INFO, "$params{'error'}") if defined $params{'error'};

    if ($params{'volume_label'} && !$params{'error'}) {
	$self->{'label'} = $params{'volume_label'};

	# add to the trace log
	log_add($L_START, sprintf("datestamp %s %s %s label %s tape %s",
		$self->{'timestamp'},
		quote_string("ST:" . $self->{'controller'}->{'storage'}->{'storage_name'}),
		quote_string("POOL:" . $self->{'controller'}->{'storage'}->{'tapepool'}),
		quote_string($self->{'label'}),
		++$tape_num));

	# and the amdump log
	print STDERR "taper: wrote label '$self->{label}'\n";

	# and inform the driver
	$self->{'controller'}->{'proto'}->send(Amanda::Taper::Protocol::NEW_TAPE,
	    worker_name => $self->{'worker_name'},
	    handle => $self->{'handle'},
	    label => $params{'volume_label'});
    } else {
	$self->{'label'} = undef;

	$self->{'controller'}->{'proto'}->send(Amanda::Taper::Protocol::NO_NEW_TAPE,
	    worker_name => $self->{'worker_name'},
	    handle => $self->{'handle'});
    }
}

sub scribe_ready {
    my $self = shift;
    my %params = @_;

    $self->{'controller'}->{'proto'}->send(Amanda::Taper::Protocol::READY,
	worker_name => $self->{'worker_name'},
	handle => $self->{'handle'});
}

sub scribe_notif_part_done {
    my $self = shift;
    my %params = @_;

    $self->_assert_in_state("writing") or return;

    my $stats = make_stats($params{'size'}, $params{'duration'}, $self->{'orig_kb'});

    # log the part, using PART or PARTPARTIAL
    my $logbase = sprintf("%s %s %s %s %s %s %s %s/%s %s %s",
	quote_string("ST:" . $self->{'controller'}->{'storage'}->{'storage_name'}),
	quote_string("POOL:" . $self->{'controller'}->{'storage'}->{'tapepool'}),
	quote_string($self->{'label'}),
	$params{'fileno'},
	quote_string($self->{'header'}->{'name'}.""), # " is required for SWIG..
	quote_string($self->{'header'}->{'disk'}.""),
	$self->{'datestamp'},
	$params{'partnum'}, -1, # totalparts is always -1
	$self->{'level'},
	$stats);
    if ($params{'successful'}) {
	log_add($L_PART, $logbase);
    } else {
	log_add($L_PARTPARTIAL, "$logbase \"No space left on device\"");
    }

    # only send a PARTDONE if it was successful
    if ($params{'successful'}) {
	$self->{'controller'}->{'proto'}->send(Amanda::Taper::Protocol::PARTDONE,
	    worker_name => $self->{'worker_name'},
	    handle => $self->{'handle'},
	    label => $self->{'label'},
	    fileno => $params{'fileno'},
	    stats => $stats,
	    kb => $params{'size'} / 1024);
    }
}

sub scribe_notif_log_info {
    my $self = shift;
    my %params = @_;

    debug("$params{'message'}");
    log_add($L_INFO, "$params{'message'}");
}

##
# recovery feedback

sub recovery_clerk_notif_open_volume {
    my $self = shift;
    my %params = @_;

    $self->{'controller'}->{'proto'}->send(
	Amanda::Taper::Protocol::OPENED_SOURCE_VOLUME,
	worker_name => $self->{'worker_name'},
	handle => $self->{'handle'},
	label => $params{'label'}
    );
}

sub recovery_clerk_notif_close_volume {
    my $self = shift;
    my %params = @_;

    $self->{'controller'}->{'proto'}->send(
	Amanda::Taper::Protocol::CLOSED_SOURCE_VOLUME,
	worker_name => $self->{'worker_name'},
	handle => $self->{'handle'},
	label => $params{'label'}
    );
}

##
# Utilities

sub _assert_in_state {
    my $self = shift;
    my ($state) = @_;
    if ($self->{'state'} eq $state) {
	return 1;
    } else {
	$self->{'controller'}->{'proto'}->send(Amanda::Taper::Protocol::BAD_COMMAND,
	    message => "command not appropriate in state '$self->{state}' : '$state'");
	return 0;
    }
}

sub create_status_file {
    my $self = shift;

    # create temporary file
    ($self->{status_fh}, $self->{status_filename}) =
	File::Temp::tempfile("taper_status_file_XXXXXX",
				DIR => $Amanda::Paths::AMANDA_TMPDIR,
				UNLINK => 1);

    # tell amstatus about it by writing it to the dump log
    my $qdisk = Amanda::Util::quote_string($self->{'diskname'});
    my $qhost = Amanda::Util::quote_string($self->{'hostname'});
    print STDERR "taper: status file $self->{'taper_name'} $self->{'worker_name'} $qhost $qdisk:" .
		    "$self->{status_filename}\n";
    print {$self->{status_fh}} "0";

    # create timer callback, firing every 5s (=5000msec)
    $self->{timer} = Amanda::MainLoop::timeout_source(5000);
    $self->{timer}->set_callback(sub {
	my $size = $self->{scribe}->get_bytes_written();
	seek $self->{status_fh}, 0, 0;
	print {$self->{status_fh}} $size;
	truncate $self->{status_fh}, length($size);
	$self->{status_fh}->flush();
    });
}

sub send_port_and_get_header {
    my $self = shift;
    my ($finished_cb) = @_;

    my ($xsrc, $xdst);
    my $errmsg;

    my $steps = define_steps
	cb_ref => \$finished_cb;

    step start => sub {
	if ($self->{'doing_port_write'}) {
            $steps->{'send_port'}->();
        } else {
            $steps->{'send_shm_name'}->();
        }
    };

    step send_shm_name => sub {
	# get the shm_name
	my $shm_name = $self->{'xfer_source'}->get_shm_name();

	if (!$shm_name) {
	    if (@{$self->{'scribe'}->{'device_errors'}}) {
		$self->{'scribe'}->abort_setup(dump_cb => $self->{'dump_cb'});
		return;
	    }
	    #An XMSG_ERROR will call the dump_cb
	    $self->{'scribe'}->set_dump_cb(dump_cb => $self->{'dump_cb'});
	    return;
	}

	# and set up an xfer for the header, too, using DirectTCP as an easy
	# way to implement a listen/accept/read process.  Note that this does
	# not enforce a maximum size, so this portion of Amanda at least can
	# handle any size header
	($xsrc, $xdst) = (
	    Amanda::Xfer::Source::DirectTCPListen->new(),
	    Amanda::Xfer::Dest::Buffer->new(0));
	$self->{'header_xfer'} = Amanda::Xfer->new([$xsrc, $xdst]);
	$self->{'header_xfer'}->start($steps->{'header_xfer_xmsg_cb'});

	my $header_addrs = $xsrc->get_addrs();
	my $header_port = $header_addrs->[0][1];

	# and tell the driver which ports we're listening on
	$self->{'controller'}->{'proto'}->send(Amanda::Taper::Protocol::SHM_NAME,
	    worker_name => $self->{'worker_name'},
	    handle => $self->{'handle'},
	    port => $header_port,
	    shm_name => $shm_name);
    };

    step send_port => sub {
	# get the ip:port pairs for the data connection from the data xfer source,
	# which should be an Amanda::Xfer::Source::DirectTCPListen
	my $data_addrs = $self->{'xfer_source'}->get_addrs();

	if (!$data_addrs || @$data_addrs == 0) {
	    if (@{$self->{'scribe'}->{'device_errors'}}) {
		$self->{'scribe'}->abort_setup(dump_cb => $self->{'dump_cb'});
		return;
	    }
	    #An XMSG_ERROR will call the dump_cb
	    $self->{'scribe'}->set_dump_cb(dump_cb => $self->{'dump_cb'});
	    return;
	}

	$data_addrs = join ";", map { $_->[0] . ':' . $_->[1] } @$data_addrs;

	# and set up an xfer for the header, too, using DirectTCP as an easy
	# way to implement a listen/accept/read process.  Note that this does
	# not enforce a maximum size, so this portion of Amanda at least can
	# handle any size header
	($xsrc, $xdst) = (
	    Amanda::Xfer::Source::DirectTCPListen->new(),
	    Amanda::Xfer::Dest::Buffer->new(0));
	$self->{'header_xfer'} = Amanda::Xfer->new([$xsrc, $xdst]);
	$self->{'header_xfer'}->start($steps->{'header_xfer_xmsg_cb'});

	my $header_addrs = $xsrc->get_addrs();
	my $header_port = $header_addrs->[0][1];

	# and tell the driver which ports we're listening on
	$self->{'controller'}->{'proto'}->send(Amanda::Taper::Protocol::PORT,
	    worker_name => $self->{'worker_name'},
	    handle => $self->{'handle'},
	    port => $header_port,
	    ipports => $data_addrs);
    };

    step header_xfer_xmsg_cb => sub {
	my ($src, $xmsg, $xfer) = @_;
	if ($xmsg->{'type'} == $XMSG_INFO) {
	    info($xmsg->{'message'});
	} elsif ($xmsg->{'type'} == $XMSG_ERROR) {
	    $errmsg = $xmsg->{'message'};
	} elsif ($xmsg->{'type'} == $XMSG_DONE) {
	    if ($errmsg) {
		$finished_cb->($errmsg);
	    } else {
		$steps->{'got_header'}->();
	    }
	}
    };

    step got_header => sub {
	my $hdr_buf = $xdst->get();

	# close stuff up
	$self->{'header_xfer'} = $xsrc = $xdst = undef;

	if (!defined $hdr_buf) {
	    return $finished_cb->("Got empty header");
	}

	# parse the header, finally!
	$self->{'header'} = Amanda::Header->from_string($hdr_buf);
	$self->{'native_crc'} = $self->{'header'}->{'native_crc'};
	$self->{'client_crc'} = $self->{'header'}->{'client_crc'};
	$self->{'server_crc'} = $self->{'header'}->{'server_crc'};

	Amanda::Debug::debug("header native_crc: $self->{'native_crc'}");
	Amanda::Debug::debug("header client_crc: $self->{'client_crc'}");
	Amanda::Debug::debug("header server_crc: $self->{'server_crc'}");

	$finished_cb->(undef);
    };
}

# do the work of starting a new xfer; this contains the code common to
# msg_PORT_WRITE and msg_FILE_WRITE.
sub setup_and_start_dump {
    my $self = shift;
    my ($msgtype, %params) = @_;
    my %splitting_args;
    my %get_xfer_dest_args;
    my @dumper_cb_result;
    my $wait_for_recovery_cb;

    $self->{'dump_cb'} = $params{'dump_cb'};

    # setting up the dump is a bit complex, due to the requirements of
    # a directtcp port_write.  This function:
    # 1. creates and starts a transfer (make_xfer)
    # 2. gets the header
    # 3. calls the scribe's start_dump method with the new header

    my $steps = define_steps
	cb_ref => \$params{'dump_cb'};

    step setup => sub {
	$self->{'handle'} = $params{'handle'};
	$self->{'src_storage'} = $params{'src_storage'};
	$self->{'src_pool'} = $params{'src_pool'};
	$self->{'src_label'} = $params{'src_label'};
	$self->{'hostname'} = $params{'hostname'};
	$self->{'diskname'} = $params{'diskname'};
	$self->{'datestamp'} = $params{'datestamp'};
	$self->{'level'} = $params{'level'};
	$self->{'header'} = undef; # no header yet
	$self->{'orig_kb'} = $params{'orig_kb'};
	$self->{'native_crc'} = undef;
	$self->{'client_crc'} = undef;
	$self->{'server_crc'} = undef;
	$self->{'source_server_crc'} = undef;
	$self->{'dest_server_crc'} = undef;
	$self->{'input_errors'} = [];

	$steps->{'process_args'}->();
    };

    step process_args => sub {
	# extract the splitting-related parameters, stripping out empty strings
	%splitting_args = map {
	    (defined $params{$_} && $params{$_} ne '')? ($_, $params{$_}) : ()
	} qw(
	    dle_tape_splitsize dle_split_diskbuffer dle_fallback_splitsize dle_allow_split
	    part_size part_cache_type part_cache_dir part_cache_max_size data_path
	);

	# convert numeric values to BigInts
	for (qw(dle_tape_splitsize dle_fallback_splitsize part_size part_cache_max_size)) {
	    $splitting_args{$_} = Math::BigInt->new($splitting_args{$_})
		if (exists $splitting_args{$_});
	}

	if ($msgtype eq Amanda::Taper::Protocol::VAULT_WRITE) {

	    my $src = $self->{'src'};

	    if (defined $src and defined $src->{'storage'} and
		$src->{'storage'}->{'storage_name'} ne $self->{'src_storage'}) {
		return $src->{'clerk'}->quit(finished_cb => $steps->{'quit_clerk_finished'});
	    } else {
		return $steps->{'get_src_clerk'}->();
	    }
	}
	$self->{'scribe'}->wait_device(finished_cb => $steps->{'got_device'});
    };

    step quit_clerk_finished => sub {
	Amanda::Debug::debug("quit_clerk_finished $self->{'name'}");
	$self->{'src'}->{'storage'}->quit();
	$self->{'src'}->{'clerk'}->quit();
	delete $self->{'src'}->{'clerk'};
	delete $self->{'src'}->{'scan'};
	delete $self->{'src'}->{'storage'};
	delete $self->{'src'}->{'chg'};
	$steps->{'get_src_clerk'}->();
    };

    step get_src_clerk => sub {

	my $src;
	if (defined $self->{'src'}) {
	    $src = $self->{'src'};
	} else {
	    $src = $self->{'src'} = {};
	}
	my $chg;
	if (!defined $src->{'clerk'}) {
	    my $tlf = Amanda::Config::config_dir_relative(getconf($CNF_TAPELIST));
	    my ($tl, $message) = Amanda::Tapelist->new($tlf);
	    if (defined $message) {
		return $self->failure($message);
	    }

	    my $storage = $self->{'storages'}->{$self->{'src_storage'}};
	    if (!$storage) {
		$storage = Amanda::Storage->new(
				storage_name => $self->{'src_storage'},
				tapelist => $tl);
		return $self->failure($storage)
		    if $storage->isa("Amanda::Changer::Error");
		$self->{'storages'}->{$self->{'src_storage'}} = $storage;
	    }

	    $chg = $storage->{'chg'};
	    if ($chg->isa('Amanda::Changer::Error')) {
		$storage->quit();
		return $self->failure($chg);
	    }

	    $src->{'storage'} = $storage;
	    $src->{'chg'} = $chg;

	    $src->{'scan'} = Amanda::Recovery::Scan->new(chg => $chg);

	    $src->{'clerk'} = Amanda::Recovery::Clerk->new(
		changer => $chg,
		feedback => $self,
		scan    => $src->{'scan'});
	}

	my @dumpspecs;
	push @dumpspecs => Amanda::Cmdline::dumpspec_t->new(
					$self->{'hostname'},
					$self->{'diskname'},
					$self->{'datestamp'},
					$self->{'level'},
					undef);
	my @storage_list = ( $self->{'src_storage'} );
	Amanda::Recovery::Planner::make_plan(
			hostname => $self->{'hostname'},
			diskname => $self->{'diskname'},
			dump_timestamp => $self->{'datestamp'},
			level => $self->{'level'},
			changer => $chg,
			storage_list => \@storage_list,
			only_in_storage => 1,
			status => 'OK',
			plan_cb => sub { $steps->{'plan_cb'}->(@_) });
	return;
    };

    step plan_cb => sub {
	my ($err, $plan) = @_;

	if ($err) {
	    return $params{'dump_cb'}->(
		result => "FAILED",
		input_errors => [ "$err" ],
		size => 0,
		duration => 0.0,
		total_duration => 0);
	}

	if (!@{$plan->{'dumps'}}) {
	    return $params{'dump_cb'}->(
                result => "FAILED",
                input_errors => [ "Dump not found" ],
                size => 0,
                duration => 0.0,
                total_duration => 0);
	}

	$self->{'src'}->{'plan'} = $plan;

	# we've started the xfer now, but the destination won't actually write
	# any data until we call start_dump.  And we'll need a device for that.
	$self->{'scribe'}->wait_device(finished_cb => $steps->{'got_device'});
    };

    step got_device => sub {
	my ($err) = @_;

	if ($err) {
	    return $params{'dump_cb'}->(
		result => "FAILED",
		device_errors => [ 'error', "got_device failed: $err" ],
		size => 0,
		duration => 0.0,
		total_duration => 0);
	}

	my $device = $self->{'scribe'}->get_device();
	if (!defined $device) {
	    confess "no device is available to create an xfer_dest";
	}

	if ($msgtype eq Amanda::Taper::Protocol::PORT_WRITE &&
	    (my $err = $self->{'scribe'}->check_data_path($params{'data_path'}))) {
	    return $params{'dump_cb'}->(
		result => "FAILED",
		device_errors => [ 'error', "$err" ],
		size => 0,
		duration => 0.0,
		total_duration => 0);
	}

	$splitting_args{'leom_supported'} = $device->property_get("leom");
	# and convert those to get_xfer_dest args
        %get_xfer_dest_args = get_splitting_args_from_config(
		%splitting_args);
	$get_xfer_dest_args{'max_memory'} = $self->{'controller'}->{'storage'}->{'device_output_buffer_size'};
	if (!$self->{'controller'}->{'storage'}->{'seen_device_output_buffer_size'}) {
	    my $block_size4 = $device->block_size * 4;
	    if ($block_size4 > $get_xfer_dest_args{'max_memory'}) {
		$get_xfer_dest_args{'max_memory'} = $block_size4;
	    }
	}
	$get_xfer_dest_args{'can_cache_inform'} = ($msgtype eq Amanda::Taper::Protocol::FILE_WRITE and $get_xfer_dest_args{'allow_split'});

	# if we're unable to fulfill the user's splitting needs, we can still give
	# the dump a shot - but we'll warn them about the problem
	if ($get_xfer_dest_args{'warning'}) {
	    log_add($L_WARNING, sprintf("%s:%s: %s",
		    $params{'hostname'}, $params{'diskname'},
		    $get_xfer_dest_args{'warning'}));
	    delete $get_xfer_dest_args{'warning'};
	}

	$steps->{'make_xfer'}->();
    };

    step make_xfer => sub {
        $self->_assert_in_state("idle") or return;
        $self->{'state'} = 'making_xfer';

	if ($msgtype eq Amanda::Taper::Protocol::PORT_WRITE) {
	    $self->{'xfer_source'} = Amanda::Xfer::Source::DirectTCPListen->new();
	} elsif ($msgtype eq Amanda::Taper::Protocol::SHM_WRITE) {
	    $self->{'xfer_source'} = Amanda::Xfer::Source::ShmRing->new();
	} elsif ($msgtype eq Amanda::Taper::Protocol::FILE_WRITE) {
	    $self->{'xfer_source'} = Amanda::Xfer::Source::Holding->new($params{'filename'});
	} elsif ($msgtype eq Amanda::Taper::Protocol::VAULT_WRITE) {
	    my $dump = $self->{'src'}->{'plan'}->shift_dump();
	    return $self->{'src'}->{'clerk'}->get_xfer_src(
		dump => $dump,
		xfer_src_cb => $steps->{'got_xfer_src'});
	} else {
	    die("Bad msgtype: $msgtype");
	}

	if ($msgtype eq Amanda::Taper::Protocol::VAULT_WRITE) {
	}
	$steps->{'make_xfer_2'}->();
    };

    step got_xfer_src => sub {
	my ($errors, $header, $xfer_src_, $directtcp_supported) = @_;

	if ($errors) {
	    push @{$self->{'input_errors'}}, @$errors;
	    return $params{'dump_cb'}->(
		result => "FAILED",
		size => 0,
		duration => 0.0,
		total_duration => 0);
	}

	$self->{'xfer_source'} = $xfer_src_;
	$self->{'header'} = $header;
	    $self->{'native_crc'} = $self->{'header'}->{'native_crc'};
	    $self->{'client_crc'} = $self->{'header'}->{'client_crc'};
	    $self->{'server_crc'} = $self->{'header'}->{'server_crc'};
	    Amanda::Debug::debug("header native_crc: $self->{'native_crc'}");
	    Amanda::Debug::debug("header client_crc: $self->{'client_crc'}");
	    Amanda::Debug::debug("header server_crc: $self->{'server_crc'}");

	    if ($self->{'header'}->{'is_partial'}) {
		$self->{'dumper_status'} = "FAILED";
	    } else {
		$self->{'dumper_status'} = "DONE";
	    }
	$steps->{'make_xfer_2'}->();
    };

    step make_xfer_2 => sub {
        $self->{'xfer_dest'} = $self->{'scribe'}->get_xfer_dest(%get_xfer_dest_args);

        $self->{'xfer'} = Amanda::Xfer->new([$self->{'xfer_source'}, $self->{'xfer_dest'}]);
        $self->{'xfer'}->start(sub {
	    my ($src, $msg, $xfer) = @_;

	    if ($msg->{'type'} == $XMSG_CRC) {
		if ($msg->{'elt'} == $self->{'xfer_source'}) {
		    $self->{'source_server_crc'} = $msg->{'crc'}.":".$msg->{'size'};
		} elsif ($msg->{'elt'} == $self->{'xfer_dest'}) {
		    $self->{'dest_server_crc'} = $msg->{'crc'}.":".$msg->{'size'};
		} else {
		}
	    }
	    if ($msgtype eq Amanda::Taper::Protocol::VAULT_WRITE) {
		$self->{'src'}->{'clerk'}->handle_xmsg($src, $msg, $xfer);
	    }
	    $self->{'scribe'}->handle_xmsg($src, $msg, $xfer);

	    # if this is an error message that's not from the scribe's element, then
	    # we'll need to keep track of it ourselves
	    if ($msg->{'type'} == $XMSG_ERROR and $msg->{'elt'} != $self->{'xfer_dest'}) {
		push @{$self->{'input_errors'}}, $msg->{'message'};
	    }
        });

	# we've found a device, but the destination won't actually write
	# any data until we call start_dump.  And we'll need a header for that.

	$steps->{'get_header'}->();
    };

    step get_header => sub {
        $self->_assert_in_state("making_xfer") or return;
        $self->{'state'} = 'getting_header';

	if ($msgtype eq Amanda::Taper::Protocol::FILE_WRITE) {
	    # getting the header is easy for FILE-WRITE..
	    my $hdr = $self->{'header'} = Amanda::Holding::get_header($params{'filename'});

	    if (!defined $hdr || $hdr->{'type'} != $Amanda::Header::F_DUMPFILE) {
		confess("Could not read header from '$params{filename}'");
	    }

	    # strip out header fields we don't need
	    $hdr->{'cont_filename'} = '';

	    $self->{'native_crc'} = $self->{'header'}->{'native_crc'};
	    $self->{'client_crc'} = $self->{'header'}->{'client_crc'};
	    $self->{'server_crc'} = $self->{'header'}->{'server_crc'};
	    Amanda::Debug::debug("header native_crc: $self->{'native_crc'}");
	    Amanda::Debug::debug("header client_crc: $self->{'client_crc'}");
	    Amanda::Debug::debug("header server_crc: $self->{'server_crc'}");

	    if ($self->{'header'}->{'is_partial'}) {
		$self->{'dumper_status'} = "FAILED";
	    } else {
		$self->{'dumper_status'} = "DONE";
	    }

	    $self->{'xfer_source'}->start_recovery();
	    $steps->{'start_dump'}->(undef);
	} elsif ($msgtype eq Amanda::Taper::Protocol::PORT_WRITE ||
		 $msgtype eq Amanda::Taper::Protocol::SHM_WRITE) {
	    # ..but quite a bit harder for PORT-WRITE; this method will send the
	    # proper PORT command, then read the header from the dumper and parse
	    # it, placing the result in $self->{'header'}
	    $self->send_port_and_get_header($steps->{'start_dump'});
	} else { # VAULT_WRITE
	    # already done
	    $steps->{'start_dump'}->(undef);
	}
    };

    step start_dump => sub {
	my ($err) = @_;

        $self->_assert_in_state("getting_header") or return;
        $self->{'state'} = 'writing';

	# abort if we already got a device_errors
	if (@{$self->{'scribe'}->{'device_errors'}}) {
	    $self->{'scribe'}->abort_setup(dump_cb => $params{'dump_cb'});
	    return;
	}
	# abort if we already got a input_errors
	if (@{$self->{'input_errors'}}) {
	    $self->{'scribe'}->abort_setup(dump_cb => $params{'dump_cb'});
	    return;
	}
        # if $err is set, cancel the dump, treating it as a input error
        if ($err) {
	    push @{$self->{'input_errors'}}, $err;
	    return $self->{'scribe'}->cancel_dump(
		xfer => $self->{'xfer'},
		dump_cb => $params{'dump_cb'});
        }

        # sanity check the header..
        my $hdr = $self->{'header'};
        if ($hdr->{'dumplevel'} != $params{'level'}
            or $hdr->{'name'} ne $params{'hostname'}
            or $hdr->{'disk'} ne $params{'diskname'}
	    or $hdr->{'datestamp'} ne $params{'datestamp'}) {
            confess("Header of dumpfile does not match command from driver $hdr->{'dumplevel'} $hdr->{'name'} $hdr->{'disk'} $hdr->{'datestamp'} ------ $params{'level'} $params{'hostname'} $params{'diskname'} $params{'datestamp'}");
        }

	# start producing status
	$self->create_status_file();

	# and fix it up before writing it
        $hdr->{'totalparts'} = -1;
        $hdr->{'type'} = $Amanda::Header::F_SPLIT_DUMPFILE;

	$wait_for_recovery_cb = 0;
	if ($msgtype eq Amanda::Taper::Protocol::VAULT_WRITE) {
	    $wait_for_recovery_cb = 1;
	    $self->{'src'}->{'clerk'}->start_recovery(
		xfer => $self->{'xfer'},
		recovery_cb => $steps->{'recovery_cb'});
	}
        $self->{'scribe'}->start_dump(
	    xfer => $self->{'xfer'},
            dump_header => $hdr,
	    dump_cb => $steps->{'dump_cb'});
            #dump_cb => $params{'dump_cb'});
    };

    step recovery_cb => sub {
	$wait_for_recovery_cb = 0;
	return if @dumper_cb_result == 0;
	Amanda::Debug::debug("quit_clerk_finished aa");
	$params{'dump_cb'}->(@dumper_cb_result);
    };

    step dump_cb => sub {
	my @paramsX = @_;
	@dumper_cb_result = @paramsX;
	if (!$wait_for_recovery_cb) {
	    $params{'dump_cb'}->(@dumper_cb_result);
	}
    };
}

sub dump_cb {
    my $self = shift;
    my %params = @_;

    $self->{'dump_params'} = \%params;
    $self->{'result'} = $params{'result'};

    # if we need to the dumper status (to differentiate a dropped network
    # connection from a normal EOF) and have not done so yet, then send a
    # DUMPER_STATUS message and re-call this method (dump_cb) with the result.
    if ($params{'result'} eq "DONE"
	    and ($self->{'doing_port_write'} || $self->{'doing_shm_write'})
	    and !exists $self->{'dumper_status'}) {
	my $controller = $self->{'controller'};
	my $proto = $controller->{'proto'};
	my $handle = $self->{'handle'};
	$proto->send(Amanda::Taper::Protocol::DUMPER_STATUS,
		worker_name => $self->{'worker_name'},
		handle => "$handle");
    } else {
	$self->result_cb();
    }
}

1;
