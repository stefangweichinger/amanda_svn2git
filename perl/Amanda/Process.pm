# Copyright (c) 2008-2012 Zmanda, Inc.  All Rights Reserved.
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
# Sunnyvale, CA 94085, or: http://www.zmanda.com

package Amanda::Process::Message;
use strict;
use warnings;

use Amanda::Message;
use vars qw( @ISA );
@ISA = qw( Amanda::Message );

sub local_message {
    my $self = shift;

    if ($self->{'code'} == 3500000) {
	return "pid $self->{'pid'} doesn't match: $self->{'pname'} != $self->{'ps_pname'}";
    } elsif ($self->{'code'} == 3500001) {
	return "Sending $self->{'signal'} signal to process '$self->{'process'}' (pid $self->{'pid'})";
    } elsif ($self->{'code'} == 3500002) {
	return "pid $self->{'pid'} is done";
    } elsif ($self->{'code'} == 3500003) {
	return "pid $self->{'pid'} is dead";
    } elsif ($self->{'code'} == 3500004) {
	return "Can't open trace_log file '$self->{'trace_log'}': $self->{'errnostr'}";
    } else {
	return "no message for code $self->{'code'}";
    }
}
package Amanda::Process;

use strict;
use warnings;
use Carp;
use POSIX ();
use Exporter;
use vars qw( @ISA @EXPORT_OK );
use File::Basename;
use Amanda::Constants;
use Amanda::Debug qw( debug );
use Amanda::Config qw( :getconf config_dir_relative );
@ISA = qw( Exporter );

=head1 NAME

Amanda::Process -- interface to process

=head1 SYNOPSIS

  use Amanda::Process;

  Amanda::Process::load_ps_table();

  Amanda::Process::scan_log($logfile);

  Amanda::Process::add_child();

  Amanda::Process::set_master_process(@pname);

  Amanda::Process::set_master($pname, $pid);

  Amanda::Process::kill_process($signal);

  my $count = Amanda::Process::process_running();

  my $count = Amanda::Process::count_process();

  my $alive = Amanda::Process::process_alive($pid, $pname);

=head1 INTERFACE

This module provides an object-oriented interface to track process used by
amanda.

my $Amanda_process = Amanda::Process->new($verbose);

=over

=item load_ps_table

  $Amanda_process->load_ps_table();

Load a table of all processes in the system.

=item scan_log

  $Amanda_process->scan_log($logfile);

Parse all 'pid' and 'pid-done' lines of the logfile.

=item add_child

  $Amanda_process->add_child();

Add all children of already known amanda processes.

=item set_master_process

  $Amanda_process->set_master_process($arg, @pname);

Search the process table to find a process in @pname and make it the master, $arg must be an argument of the process.

=item set_master

  $Amanda_process->set_master($pname, $pid);

Set $Amanda_process->{master_pname} and $Amanda_process->{master_pid}.

=item kill_process

  $Amanda_process->kill_process($signal);

Send the $signal to all amanda processes.

=item process_running

  my $count = $Amanda_process->process_running();

Return the number of amanda process alive.

=item count_process

  my $count = $Amanda_process->count_process();

Return the number of amanda process in the table.

=item process_alive

  my $alive = Amanda::Process::process_alive($pid, $pname);

Return 0 if the process is not alive.
Return 1 if the process is still alive.

=back

=cut

sub new {
    my $class = shift;
    my ($verbose) = shift;
    my ($user_message) = shift;

    my $self = {
	verbose => $verbose,
	master_name => "",
	master_pid => "",
	user_message => $user_message,
	pids => {},
	pstable => {},
	ppid => {},
    };
    bless ($self, $class);
    return $self;
}

# Get information about the current set of processes, using ps -e
# and ps -ef.
#
# Side effects:
# - sets %pstable to a map (pid => process name) of all running
#   processes
# - sets %ppid to a map (pid -> parent pid) of all running
#   processes' parent pids
#
sub load_ps_table() {
    my $self = shift;
    $self->{pstable} = {};
    $self->{ppid} = ();
    my $ps_argument = $Amanda::Constants::PS_ARGUMENT;
    if ($ps_argument eq "CYGWIN") {
	open(PSTABLE, "-|", "ps -ef") || die("ps -ef: $!");
	my $psline = <PSTABLE>; #header line
	while($psline = <PSTABLE>) {
	    chomp $psline;
	    my @psline = split " ", $psline;
	    my $pid = $psline[1];
	    my $ppid = $psline[2];
	    my $stime = $psline[4];
	    my $pname;
	    if ($stime =~ /:/) {  # 10:32:44
		$pname = basename($psline[5])
	    } else {              # May 22
		$pname = basename($psline[6])
	    }
	    $self->{pstable}->{$pid} = $pname;
	    $self->{ppid}->{$pid} = $ppid;
	}
	close(PSTABLE);
    } else {
	open(PSTABLE, "-|", "$Amanda::Constants::PS $ps_argument")
	    or die("$Amanda::Constants::PS $ps_argument: $!");
	my $psline = <PSTABLE>; #header line
	while($psline = <PSTABLE>) {
	    chomp $psline;
	    next if $psline =~ /\<defunct\>/;
	    my ($pid, $ppid, $pname, @args) = split " ", $psline;
	    next if !defined $pid;
	    next if !defined $ppid;
	    next if !defined $pname;
	    $pname = basename($pname);
	    if ($pname =~ /perl/ && @args) {
		foreach my $arg (@args) {
		    next if $arg =~ /^\-/;
		    $pname = $arg;
		    last;
		}
		$pname = basename($pname);
	    }
	    $self->{pstable}->{$pid} = $pname;
	    $self->{ppid}->{$pid} = $ppid;
	}
	close(PSTABLE);
    }
}

# Scan a logfile for processes that should still be running: processes
# having an "INFO foo bar pid 1234" line in the log, but no corresponding
# "INFO pid-done 1234", and only if pid 1234 has the correct process
# name.
#
# Prerequisites:
#  %pstable must be set up (use load_ps_table)
#
# Side effects:
# - sets %pids to a map (pid => process name) of all still-running
#   Amanda processes
# - sets $master_pname to the top-level process for this run (e.g.,
#   amdump, amflush)
# - sets $master_pid to the pid of $master_pname
#
# @param $logfile: the logfile to scan
#
sub scan_log($) {
    my $self = shift;
    my $logfile = shift;
    my $first = 1;
    my($line);

    if ($logfile !~ /^\//) {
	$logfile = config_dir_relative(Amanda::Config::getconf($CNF_LOGDIR)) . '/' . $logfile;
    }
    if (!open(LOGFILE, "<", $logfile)) {
	$self->{'user_message'}(Amanda::Process::Message->new(
			source_filename	=> __FILE__,
                        source_line	=> __LINE__,
                        code		=> 3500004,
                        severity	=> $Amanda::Message::ERROR,
			trace_log	=> $logfile,
			errno		=> $!));
	return;
    }

    while($line = <LOGFILE>) {
	if ($line =~ /^INFO .* (.*) pid (\d*)$/) {
	    my ($pname, $pid) = ($1, $2);
	    if ($first == 1) {
		$self->{master_pname} = $pname;
		$self->{master_pid} = $pid;
		$first = 0;
	    }
	    if (defined $self->{pstable}->{$pid} && $pname eq $self->{pstable}->{$pid}) {
		$self->{pids}->{$pid} = $pname;
	    } elsif (defined $self->{pstable}->{$pid} && $self->{pstable}->{$pid} =~ /perl/) {
		# We can get 'perl' for a perl script.
		$self->{pids}->{$pid} = $pname;
	    } elsif (defined $self->{pstable}->{$pid} && $self->{pstable}->{$pid} =~ /^$pname\d*$/) {
		$self->{pids}->{$pid} = $pname;
	    } elsif (defined $self->{pstable}->{$pid} && $self->{pstable}->{$pid} =~ /^am$pname\d*$/) {
		$self->{pids}->{$pid} = $pname;
	    } elsif (defined $self->{pstable}->{$pid}) {
		$self->{'user_message'}(Amanda::Process::Message->new(
			source_filename	=> __FILE__,
                        source_line	=> __LINE__,
                        code		=> 3500000,
                        severity	=> $Amanda::Message::WARNING,
			pname		=> $pname,
			ps_pname	=> $self->{pstable}->{$pid},
			pid		=> $pid)) if $self->{verbose};;
	    }
	} elsif ($line =~ /^INFO .* pid-done (\d*)$/) {
	    my $pid = $1;
	    $self->{'user_message'}(Amanda::Process::Message->new(
			source_filename	=> __FILE__,
                        source_line	=> __LINE__,
                        code		=> 3500002,
                        severity	=> $Amanda::Message::INFO,
			pid		=> $pid)) if $self->{verbose};;
	}
    }
    close(LOGFILE);

    # log unexpected dead process
    if ($self->{verbose}) {
	for my $pid (keys %{$self->{pids}}) {
	    if (!defined $self->{pstable}->{$pid}) {
	        $self->{'user_message'}(Amanda::Process::Message->new(
			source_filename	=> __FILE__,
                        source_line	=> __LINE__,
                        code		=> 3500003,
                        severity	=> $Amanda::Message::INFO,
			pid		=> $pid));
	    }
	}
    }
}

# Recursive function to add all child processes of $pid to %amprocess.
#
# Prerequisites:
# - %ppid must be set (load_ps_table)
#
# Side-effects:
# - adds all child processes of $pid to %amprocess
#
# @param $pid: the process to start at
#
sub add_child_pid($);
sub add_child_pid($) {
    my $self = shift;
    my $pid = shift;
    foreach my $cpid (keys %{$self->{ppid}}) {
	my $ppid = $self->{ppid}->{$cpid};
	if ($pid == $ppid) {
	    if (!defined $self->{amprocess}->{$cpid}) {
		$self->{amprocess}->{$cpid} = $cpid;
		$self->add_child_pid($cpid);
	    }
	}
    }
}

# Find all children of all amanda processes, as determined by traversing
# the process graph (via %ppid).
#
# Prerequisites:
# - %ppid must be set (load_ps_table)
# - %pids must be set (scan_log)
#
# Side-effects:
# - sets %amprocess to a map (pid => pid) of all amanda processes, including
#   children
#
sub add_child() {
    my $self = shift;
    foreach my $pid (keys %{$self->{pids}}) {
	if (defined $pid) {
	    $self->{amprocess}->{$pid} = $pid;
	}
    }

    foreach my $pid (keys %{$self->{pids}}) {
	$self->add_child_pid($pid);
    }
}

# Set master_pname and master_pid.
#
# Side-effects:
# - sets $self->{master_pname} and $self->{master_pid}.
#
sub set_master_process {
    my $self = shift;
    my $arg = shift;
    my @pname = @_;

    my $ps_argument_args = $Amanda::Constants::PS_ARGUMENT_ARGS;
    for my $pname (@pname) {
	my $pid;

	if ($ps_argument_args eq "CYGWIN") {
	    $pid = `ps -ef|grep -w ${pname}|grep -w ${arg}| grep -v grep | awk '{print \$2}'`;
	} else {
	    $pid = `$Amanda::Constants::PS $ps_argument_args|grep -w ${pname}|grep -w ${arg}| grep -v grep | awk '{print \$1}'`;
	}
	chomp $pid;
	if ($pid ne "") {
	    $self->set_master($pname, $pid);
	}
    }
}

# Set master_pname and master_pid.
#
# Side-effects:
# - sets $self->{master_pname} and $self->{master_pid}.
#
sub set_master($$) {
    my $self = shift;
    my $pname = shift;
    my $pid = shift;

    $self->{master_pname} = $pname;
    $self->{master_pid} = $pid;
    $self->{pids}->{$pid} = $pname;
}
# Send a signal to all amanda process
#
# Side-effects:
# - All amanda process receive the signal.
#
# Prerequisites:
# - %amprocess must be set (add_child)
#
# @param $signal: the signal to send
#
sub kill_process($) {
    my $self = shift;
    my $signal = shift;

    foreach my $pid (keys %{$self->{amprocess}}) {
	$self->{'user_message'}(Amanda::Process::Message->new(
			source_filename	=> __FILE__,
                        source_line	=> __LINE__,
                        code		=> 3500001,
                        severity	=> $Amanda::Message::INFO,
			signal		=> $signal,
			process		=> $self->{'pids'}->{$pid},
			pid		=> $pid));
	kill $signal, $pid;
    }
}

# Count the number of processes in %amprocess that are still running.  This
# re-runs 'ps -e' every time, so calling it repeatedly may result in a
# decreasing count.
#
# Prerequisites:
# - %amprocess must be set (add_child)
#
# @returns: number of pids in %amprocess that are still alive
sub process_running() {
    my $self = shift;

    $self->load_ps_table();
    my $count = 0;
    foreach my $pid (keys %{$self->{amprocess}}) {
	if (defined $self->{pstable}->{$pid}) {
	    $count++;
	}
    }

    return $count;
}

sub which_process_running() {
    my $self = shift;

    $self->load_ps_table();
    my $count = 0;
    my @pids;
    foreach my $pid (keys %{$self->{amprocess}}) {
	if (defined $self->{pstable}->{$pid}) {
	    $count++;
	    push @pids, $pid;
	}
    }

    return ( $count, \@pids );
}

# Count the number of processes in %amprocess.
#
# Prerequisites:
# - %amprocess must be set (add_child)
#
# @returns: number of pids in %amprocess.
sub count_process() {
    my $self = shift;

    return scalar keys( %{$self->{amprocess}} );
}

# return if a process is alive.  If $pname is provided,
# only returns 1 if the name matches.
#
# Prerequisites:
# - %pstable must be set (load_ps_table)
#
# @param $pid: the pid of the process
# @param $pname: the name of the process (optional)
#
# @returns: 1 if process is alive
#           '' if process is dead

my $Amanda_process;
my $Amanda_process_timestamps;
sub process_alive() {
    my $self = shift;
    my $pid = shift;
    my $pname = shift;

    if ($self eq 'Amanda::Process') {
	if (!$Amanda_process || $Amanda_process_timestamps+60 < time()) {
	    $Amanda_process = Amanda::Process->new(0);
	    $Amanda_process->load_ps_table();
	    $Amanda_process_timestamps = time();
	}
	$self = $Amanda_process;
    }

    if (defined $pname && defined $self->{pstable}->{$pid}) {
	return $self->{pstable}->{$pid} eq $pname ||
	       $self->{pstable}->{$pid} eq "starman";
    } else {
	return defined $self->{pstable}->{$pid};
    }
}

1;
