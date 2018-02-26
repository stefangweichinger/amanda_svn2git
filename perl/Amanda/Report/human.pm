# Copyright (c) 2010-2012 Zmanda, Inc.  All Rights Reserved.
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
# Contact information: Zmanda Inc., 465 S Mathlida Ave, Suite 300
# Sunnyvale, CA 94085, or: http://www.zmanda.com
#

package Amanda::Report::human;

use strict;
use warnings;
use Carp;

use POSIX;
use Data::Dumper;

use Amanda::Config qw(:getconf config_dir_relative);
use Amanda::Util qw(:constants quote_string );
use Amanda::Holding;
use Amanda::Policy;
use Amanda::Storage;
use Amanda::Changer;
use Amanda::Tapelist;
use Amanda::Debug qw( debug );
use Amanda::Util qw( quote_string );

use Amanda::Report;

## constants that define the column specification output format.

use constant COLSPEC_NAME      => 0;    # column name; used internally
use constant COLSPEC_PRE_SPACE => 1;    # prefix spaces
use constant COLSPEC_WIDTH     => 2;    # column width
use constant COLSPEC_PREC      => 3;    # post-decimal precision
use constant COLSPEC_MAXWIDTH  => 4;    # resize if set
use constant COLSPEC_FORMAT    => 5;    # sprintf format
use constant COLSPEC_TITLE     => 6;    # column title

use constant PROGRAM_ORDER =>
  qw(amcleanup amdump planner amflush amvault driver dumper chunker taper amreport amtrmidx amtrmlog);


## helper functions

sub divzero
{
    my ($self) = shift;
    my ( $a, $b ) = @_;
    my $q;
    return
        ( $b == 0 )              ? "-- "
      : ( ($q = $a / $b) > 99999.95 ) ? "#####"
      : ( $q > 999.95 ) ? sprintf( "%5.0f", $q )
      :                   sprintf( "%5.1f", $q );
}

sub divzero_wide
{
    my ($self) = shift;
    my ( $a, $b ) = @_;
    my $q;
    return
        ( $b == 0 )              ? "-- "
      : ( ($q = $a / $b) > 9999999.95 ) ? "#######"
      : ( $q > 99999.95 ) ? sprintf( "%7.0f", $q )
      :                     sprintf( "%7.1f", $q );
}

sub divzero_col
{
    my ($self) = shift;
    my ( $a, $b, $col ) = @_;
    return ( $b == 0 )
      ? "-- "
      : sprintf( $col->[5], $col->[2], $col->[3], ( $a / $b ) );
}

sub swrite
{
    my ( $format, @args ) = @_;
    my @copy_args = @args;
    local $^A = "";
    formline( $format, @copy_args );
    return $^A;
}

sub max
{
    my ( $max, @args ) = @_;    # first element starts as max

    foreach my $elt (@args) {
        $max = $elt if $elt > $max;
    }
    return $max;
}

sub min
{
    my ( $min, @args ) = @_;    # first element starts as min

    foreach my $elt (@args) {
        $min = $elt if $elt < $min;
    }
    return $min;
}

sub hrmn
{
    my ($self) = shift;
    my ($sec) = @_;
    $sec += 30; # round up
    my ( $hr, $mn ) = ( int( $sec / ( 60 * 60 ) ), int( $sec / 60 ) % 60 );
    return sprintf( '%d:%02d', $hr, $mn );
}

sub mnsc
{
    my ($self) = shift;
    my ($sec) = @_;
    $sec += 0.5; # round up
    my ( $mn, $sc ) = ( int( $sec / (60) ), int( $sec % 60 ) );
    return sprintf( '%d:%02d', $mn, $sc );
}

## helper methods

# return $val/$unit_divisor as a a floating-point number
sub tounits {
    my $self = shift;
    my ($val, %params) = @_;

    return $params{'zero'} if ($val == 0 and exists $params{'zero'});

    # $orig_size and $out_size are bigints, which must be stringified to cast
    # them to floats.  We need floats, because they round nicely.  This is
    # ugly and hard to track down.
    my $flval = $val.".0";
    my $flunit = $self->{'unit_div'}.".0";
    return $flval / $flunit;
}

## class functions

sub new
{
    my ($class, $report, $config_name, $logfname) = @_;

    my $self = {
        report      => $report,
        config_name => $config_name,
        logfname    => $logfname,

        ## config info
        disp_unit => getconf($CNF_DISPLAYUNIT),
        unit_div  => getconf_unit_divisor(),

        ## statistics
        incr_stats  => {},
        full_stats  => {},
        total_stats => {},
        dumpdisks   => [ 0, 0 ],    # full_count, incr_count
        tapedisks   => [ 0, 0 ],
        tapeparts  => [ 0, 0 ],
    };

    if (defined $report) {

        my (@errors, @stranges, @notes);

        @errors =
          map { @{ $report->get_program_info($_, "errors", []) }; }
          PROGRAM_ORDER;

        ## prepend program name to notes lines.
        foreach my $program (PROGRAM_ORDER) {
            push @notes,
              map { "$program: $_" }
              @{ $report->get_program_info($program, "notes", []) };
        }

        $self->{errors} = \@errors;
        $self->{notes}  = \@notes;
    }

    bless $self, $class;
    return $self;
}

sub calculate_stats
{
    my ($self) = @_;
    my $fh     = $self->{fh};
    my $report = $self->{report};

    # TODO: the hashes are a cheap fix.  fix these.
    my @dles        = $report->get_dles();
    my $full_stats  = $self->{full_stats};
    my $incr_stats  = $self->{incr_stats};
    my $total_stats = $self->{total_stats};
    my $dumpdisks   = $self->{dumpdisks};
    my $tapedisks   = $self->{tapedisks};
    my $tapeparts   = $self->{tapeparts};

    ## initialize all relevant fields to 0
    map { $incr_stats->{$_} = $full_stats->{$_} = 0; }
      qw/dumpdisk_count tapedisk_count tapepart_count outsize origsize
      tapesize coutsize corigsize taper_time dumper_time/;

    foreach my $dle_entry (@dles) {

        # $dle_entry = [$hostname, $disk]
        my $dle      = $report->get_dle_info(@$dle_entry);
	my $alldumps = $dle->{'dumps'};

	while( my ($timestamp, $tries) = each %$alldumps ) {
	    foreach my $try ( @$tries ) {

		if (exists $try->{'retry'}) {
		    next;
		}

		my $level = exists $try->{dumper} ? $try->{dumper}{'level'} :
			    exists $try->{taper} ? $try->{taper}{'level'} :
			    0;
		my $stats = ($level > 0) ? $incr_stats : $full_stats;

		# compute out size, skipping flushes (tries without a dumper run)
		my $outsize = 0;
		if (exists $try->{dumper}
		    && exists $try->{chunker} && defined $try->{chunker}->{kb}
		    && ( $try->{chunker}{status} eq 'success'
		      || $try->{chunker}{status} eq 'partial')) {
		    $outsize = $try->{chunker}->{kb};
		} elsif (exists $try->{dumper}
		    && exists $try->{taper} && defined $try->{taper}->{kb}
		    && (   $try->{taper}{status} eq 'done'
			|| $try->{taper}{status} eq 'partial')) {
		    $outsize = $try->{taper}->{kb};
		}

		# compute orig size, again skipping flushes
		my $origsize = 0;
		if ( exists $try->{dumper}
		    && (   $try->{dumper}{status} eq 'success'
			|| $try->{dumper}{status} eq 'strange')
		    && (   (   exists $try->{chunker}
			    && exists $try->{chunker}{status}
		            && (   $try->{chunker}{status} eq 'success'
		                || $try->{chunker}{status} eq 'partial'))
			|| (   exists $try->{taper}
			    && exists $try->{taper}{status}
		            && (   $try->{taper}{status} eq 'done'
			        || $try->{taper}{status} eq 'partial')))) {

		    $origsize = $try->{dumper}{orig_kb};
		    $stats->{dumper_time} += $try->{dumper}{sec};
		    $stats->{dumpdisk_count}++; # count this as a dumped filesystem
		    $dumpdisks->[$try->{dumper}{'level'}]++; #by level count
		} elsif (exists $try->{dumper}
		    && exists $try->{taper} && defined $try->{taper}->{kb}
		    && (   $try->{taper}{status} eq 'done'
			|| $try->{taper}{status} eq 'partial')) {
		    # orig_kb doesn't always exist (older logfiles)
		    if ($try->{taper}->{orig_kb}) {
			$origsize = $try->{taper}->{orig_kb};
		    }
		}

		if ( exists $try->{taper}
		    && ( $try->{taper}{status} eq 'done'
		      || $try->{taper}{status} eq 'partial')) {

		    $stats->{tapesize}   += $try->{taper}{kb};
		    $stats->{taper_time} += $try->{taper}{sec};
		    $stats->{tapepart_count} += @{ $try->{taper}{parts} }
			if $try->{taper}{parts};
		    $stats->{tapedisk_count}++;

		    $tapedisks->[ $try->{taper}{level} ]++;    #by level count
		    $tapeparts->[$try->{taper}{level}] += @{ $try->{taper}{parts} }
			if $try->{taper}{parts};
		}

		# add those values to the stats
		$stats->{'origsize'} += $origsize;
		$stats->{'outsize'} += $outsize;

		# if the sizes differ, then we have a compressed dump, so also add it to
		# c{out,orig}size
		$stats->{'corigsize'} += $origsize;
		$stats->{'coutsize'} += $outsize;
	    }
        }
    }

    %$total_stats = map { $_ => $incr_stats->{$_} + $full_stats->{$_} }
      keys %$incr_stats;

    $total_stats->{planner_time} =
      $report->get_program_info("planner", "time", 0);

    if ($report->get_flag("got_finish")) {
        $total_stats->{total_time} =
             $report->get_program_info("driver",  "time", 0)
          || $report->get_program_info("amflush", "time", 0)
          || $report->get_program_info("amvault", "time", 0);
    } else {
        $total_stats->{total_time} =
          $total_stats->{taper_time} + $total_stats->{planner_time};
    }

    $total_stats->{idle_time} =
      ( $total_stats->{total_time} - $total_stats->{planner_time} ) -
      $total_stats->{taper_time};

    # TODO: tape info is very sparse.  There either needs to be a
    # function that collects and fills in tape info post-processing in
    # Amanda::Report, or it needs to be done here.
    return;
}

sub zprint
{
    my $self = shift;

    print {$self->{'fh'}} @_;
}

sub zsprint
{
    my $self = shift;

    return ($self->zprint(@_));
}

sub write_report
{
    my ( $self, $fh ) = @_;

    $fh || confess "error: no file handle given to Amanda::Report::human::write_report\n";
    $self->{fh} = $fh;

    ## collect statistics
    $self->calculate_stats();

    ## print the basic info header
    $self->print_header();

    ## print out statements about past and predicted tape usage
    $self->output_tapeinfo();

    ## print out error messages from the run
    $self->output_error_summaries();

    ## print out aggregated statistics for the whole dump
    $self->output_stats();

    ## print out statistics for each tape used
    $self->output_tape_stats();

    ## print out all errors & comments
    $self->output_details();

    ## print out dump statistics per DLE
    $self->output_summary();

    ## footer
    $self->zprint(
      "(brought to you by Amanda version $Amanda::Constants::VERSION)\n");

    return;
}

sub print_header
{
    my ($self) = @_;

    my $report      = $self->{report};
    my $fh          = $self->{fh};
    my $config_name = $self->{config_name};

    my $hostname = $report->{hostname};
    my $org      = getconf($CNF_ORG);

    # TODO: this should be a shared method somewhere
    my $timestamp = $report->get_timestamp();
    my ($year, $month, $day) = ($timestamp =~ m/^(\d\d\d\d)(\d\d)(\d\d)/);
    my $date  = POSIX::strftime('%B %e, %Y', 0, 0, 0, $day, $month - 1, $year - 1900);
    $date =~ s/  / /g; # get rid of intervening space

    $self->zprint("*** THE DUMPS DID NOT FINISH PROPERLY!\n\n")
      unless ($report->{flags}{got_finish});

    my $header_format = <<EOF;
@<<<<<<<: ^<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<...
EOF

    $self->zprint(swrite($header_format, "Hostname", $hostname)) if $hostname;
    $self->zprint(swrite($header_format, "Org",      $org)) if $org;
    $self->zprint(swrite($header_format, "Config",   $config_name)) if $config_name;
    $self->zprint(swrite($header_format, "Date",     $date)) if $date;
    $self->zprint("\n");

    return;
}

sub output_tapeinfo
{
    my ($self)   = @_;
    my $report   = $self->{report};
    my $fh       = $self->{fh};
    my $logfname = $self->{logfname};

    my $taper       = $report->get_program_info("taper");
    my $tapes       = $taper->{tapes}       || {};
    my $tape_labels = $taper->{tape_labels} || [];

    my %full_stats  = %{ $self->{full_stats} };
    my %incr_stats  = %{ $self->{incr_stats} };
    my %total_stats = %{ $self->{total_stats} };

    for my $storage_n (@{$report->{'storage_list'}}) {
	my $st = Amanda::Config::lookup_storage($storage_n);
	if (!$st) {
	    debug("Storage '%s' not found", $storage_n);
	    next;
	}
	if (storage_getconf($st, $STORAGE_REPORT_USE_MEDIA)) {
	    # find and count label use for the storage

	    my @storage_tape_labels;
	    foreach my $tape_label (@$tape_labels) {
		my $tape = $tapes->{$tape_label};
		if ($tape->{'storage'} eq $storage_n) {
		    push @storage_tape_labels, $tape_label;
		}
	    }

	    if (@storage_tape_labels > 0) {

		my $to_storage = '';
		$to_storage = " to storage '$storage_n'" if @{$report->{'storage_list'}} > 1;
		# slightly different sentence depending on the run type
	        my $tapelist_str;
		if ($report->get_flag("amflush_run")) {
		    $tapelist_str = "The dumps" . $to_storage . " were flushed ";
		} elsif ($report->get_flag("amvault_run")) {
		    $tapelist_str = "The dumps" . $to_storage . " were vaulted ";
		} else {
		    $tapelist_str = "These dumps" . $to_storage . " were ";
		}
	        $tapelist_str .= (@storage_tape_labels > 1) ? "to tapes " : "to tape ";
	        $tapelist_str .= join(", ", @storage_tape_labels) . ".\n";
	        $self->zprint($tapelist_str);
	    }
	}
    }

    if (my $tape_error =
        $report->get_program_info("taper", "tape_error", undef)) {

	if ($report->get_program_info("taper", "failure_from", undef) eq "config") {
	    # remove leading [ and trailling ]
	    $tape_error =~ s/^\[//;
	    $tape_error =~ s/\]$//;
	    $self->zprint("Not using all tapes because $tape_error.\n");
	} else {
            $self->zprint("*** A TAPE ERROR OCCURRED: $tape_error.\n");
	}
        #$tape_error =~ s{^no-tape }{};
    }

    ## if this is a historical report, do not generate holding disk
    ## information.  If this dump is the most recent, output holding
    ## disk info.
    if ($report->get_flag("historical")) {
        $self->zprint("Some dumps may have been left in the holding disk.\n\n")
          if $report->get_flag("degraded_mode")

    } else {

        my @holding_list = Amanda::Holding::get_files_for_flush(0);
        my $h_size = 0;
        foreach my $holding_file (@holding_list) {
            $h_size += (0 + Amanda::Holding::file_size($holding_file, 1));
        }

        my $h_size_u =
          sprintf("%.0f%s", $self->tounits($h_size), $self->{disp_unit});

        if ($h_size > 0) {
            $self->zprint(
              "There are $h_size_u of dumps left in the holding disk.\n");

            (getconf($CNF_AUTOFLUSH))
              ? $self->zprint("They will be flushed on the next run.\n")
              : $self->zprint("Run amflush to flush them to tape.\n");

        } elsif ($report->get_flag("degraded_mode")) {
            $self->zprint("No dumps are left in the holding disk.\n");
        }
    }

    for my $storage_n (@{$report->{'storage_list'}}) {
	my $st = Amanda::Config::lookup_storage($storage_n);
	if (!$st) {
	    debug("Storage '%s' not found", $storage_n);
	    next;
	}
	if (storage_getconf($st, $STORAGE_REPORT_NEXT_MEDIA)) {
	    my $run_tapes   = storage_getconf($st, $STORAGE_RUNTAPES);
	    my $nb_new_tape = 0;
	    my $first = 1;

	    my $for_storage = '';
	    $for_storage = " for storage '$storage_n'" if @{$report->{'storage_list'}} > 1;
	    my $text;
	    if ($run_tapes) {
		$text = ($run_tapes > 1)
	          ? "The next $run_tapes tapes Amanda expects to use" . $for_storage . " are: "
	          : "The next tape Amanda expects to use" . $for_storage . " is: ";
	    }

	    my $tlf = Amanda::Config::config_dir_relative(getconf($CNF_TAPELIST));
	    my ($tl, $message) = Amanda::Tapelist->new($tlf);

	    my $labelstr = storage_getconf($st, $STORAGE_LABELSTR);
	    my $tapepool = storage_getconf($st, $STORAGE_TAPEPOOL);
	    my $policy = Amanda::Policy->new(policy => storage_getconf($st, $STORAGE_POLICY));
	    my $retention_tapes = $policy->{'retention_tapes'};
	    my $retention_days = $policy->{'retention_days'};
	    my $retention_recover = $policy->{'retention_recover'};
	    my $retention_full = $policy->{'retention_full'};

	    foreach my $i ( 0 .. ( $run_tapes - 1 ) ) {

		if ( my $tape_label =
		    Amanda::Tapelist::get_last_reusable_tape_label(
					$labelstr->{'template'},
					$tapepool,
					$storage_n,
					$retention_tapes,
					$retention_days,
					$retention_recover,
					$retention_full,
					$i) ) {
		    if ($nb_new_tape) {
			$text .= ", " if !$first;
			$text .= "$nb_new_tape new tape"
				. ( $nb_new_tape > 1 ? "s" : "" );
			$nb_new_tape = 0;
			$first = 0;
		    }

		    $text .=
		    ($first ? "" : ", ") .
		    $tape_label;
		    $first = 0;
		} else {
		    $nb_new_tape++;
		}
	    }

	    if ($nb_new_tape) {
		$text .= ", " if !$first;
		$text .= "$nb_new_tape new tape"
			. ( $nb_new_tape > 1 ? "s" : "" );
	    }
	    $self->zprint("$text.\n");

	    my @new_tapes = Amanda::Tapelist::list_new_tapes(
						$storage_n,
						$run_tapes);
	    if (@new_tapes == 1) {
		$self->zprint("The next new tape already labelled is: $new_tapes[0].");
	    } elsif (@new_tapes > 1) {
		$self->zprint("The next " . @new_tapes . " tape already labelled are: " . join(',', @new_tapes) . ".");
	    }
	}
    }

    return;
}

sub output_error_summaries
{
    my ($self)   = @_;
    my $errors   = $self->{errors};
    my $report   = $self->{report};

    my @dles     = $report->get_dles();
    my @failures = ();
    my @fatal_failures = ();
    my @error_failures = ();
    my @missing_failures = ();
    my @driver_failures = ();
    my @planner_failures = ();
    my @dump_failures = ();
    my @stranges = ();

    foreach my $program (PROGRAM_ORDER) {

        push @fatal_failures,
          map { "$program: FATAL $_" }
          @{ $report->get_program_info($program, "fatal", []) };
        push @error_failures,
          map { "$program: ERROR $_" }
          @{ $report->get_program_info($program, "errors", []) };
    }

    foreach my $dle_entry (@dles) {

        my ($hostname, $disk) = @$dle_entry;
        my $alldumps = $report->get_dle_info(@$dle_entry, "dumps");
	my $dle = $report->get_dle_info($hostname, $disk);
        my $qdisk = quote_string($disk);

	if ($report->get_flag('results_missing') and
	    !defined($alldumps->{$report->{run_timestamp}}) and
	    $report->{dump_disk}->{$hostname}->{$disk} &&
	    !$dle->{driver} and
	    !$dle->{planner}) {
	    push @missing_failures, "$hostname $qdisk RESULTS MISSING";
	}

	if (   exists $dle->{driver}
	    && exists $dle->{driver}->{error}) {
	    push @driver_failures, "$hostname $qdisk lev $dle->{driver}->{level}  FAILED [$dle->{driver}->{error}]";
	}

	if (   exists $dle->{planner}
	    && exists $dle->{planner}->{error}) {
	    push @planner_failures, "$hostname $qdisk lev $dle->{planner}->{level}  FAILED [$dle->{planner}->{error}]";
	}

	while( my ($timestamp, $tries) = each %$alldumps ) {
	    my $failed = 0;
	    my $datestr = '';
	    $datestr = "date $timestamp " if $timestamp != $report->{run_timestamp};
	    foreach my $try (@$tries) {

		if (exists $try->{'retry'}) {
		    push @dump_failures, "$hostname $qdisk ${datestr}lev $try->{dumper}->{level}  FAILED [$try->{'retry_message'}: Will retry at level $try->{'retry_level'}]";
		    next;
		}
		if (exists $try->{dumper} &&
		    $try->{dumper}->{status} &&
		    $try->{dumper}->{status} eq 'fail' &&
		    $try->{dumper}->{error} ne 'Aborted by driver') {
		    push @dump_failures, "$hostname $qdisk ${datestr}lev $try->{dumper}->{level}  FAILED [$try->{dumper}->{error}]";
		    $failed = 1;
		}
		if (exists $try->{chunker} && !exists $dle->{driver} &&
		    $try->{chunker}->{status} eq 'fail') {
		    push @dump_failures, "$hostname $qdisk ${datestr}lev $try->{chunker}->{level}  FAILED [$try->{chunker}->{error}]";
		    $failed = 1;
		}
		if (   exists $try->{taper}
		    && ((exists $try->{dumper} && !exists $dle->{driver})
			|| (!exists $try->{dumper} && !exists $dle->{driver}))
		    && (   $try->{taper}->{status} eq 'fail'
			|| (   $try->{taper}->{status} eq 'partial'))) {
		    my $flush = "FLUSH";
		    $flush = "VAULT" if $report->get_flag("amvault_run");
		    $flush = "VAULT" if $try->{taper}->{vault};
		    if (defined $report->{'flush_or_vault'}->{$try->{taper}->{storage}}) {
			$flush = "$report->{'flush_or_vault'}->{$try->{taper}->{storage}}($try->{taper}->{storage})";
		    }
		    $flush = "FAILED" if exists $try->{dumper} && !exists $try->{chunker};
		    $flush = "FAILED" if !exists $try->{dumper} && exists $try->{chunker};
		    if ($flush eq "FAILED" or !defined $try->{taper}->{failure_from}
					   or $try->{taper}->{failure_from} ne 'config') {
		        if ($try->{taper}->{status} eq 'partial') {
			    # if the error message is omitted, then the taper only got a partial
			    # dump from the dumper/chunker, rather than failing with a taper error
			    my $errmsg = $try->{taper}{error} || "successfully taped a partial dump";
			    $flush = "partial taper: $errmsg";
		        } else {
			    $flush .= " [" . $try->{taper}{error} . "]";
		        }

		        push @dump_failures, "$hostname $qdisk ${datestr}lev $try->{taper}->{level}  $flush";
		        $failed = 1;
		    }
		}

		# detect retried dumps
		if (   $failed
		    && exists $try->{dumper}
		    && (   $try->{dumper}->{status} eq "success"
			|| $try->{dumper}->{status} eq "strange")
		    && (   !exists $try->{chunker}
			|| $try->{chunker}->{status} eq "success")
		    && (   !exists $try->{taper}
			|| $try->{taper}->{status} eq "done")) {
		    push @dump_failures, "$hostname $qdisk ${datestr}lev $try->{dumper}->{level}  was successfully retried";
		    $failed = 0;
		}

		# detect dumps re-flushed from holding
		if (   $failed
		    && !exists $try->{dumper} && !exists $dle->{driver}
		    && !exists $try->{chunker}
		    && exists $try->{taper}
		    && $try->{taper}->{status} eq "done") {
		    push @dump_failures, "$hostname $qdisk ${datestr}lev $try->{taper}->{level}  was successfully re-flushed";
		    $failed = 0;
		}

		push @stranges,
    "$hostname $qdisk ${datestr}lev $try->{dumper}->{level}  STRANGE (see below)"
		  if (defined $try->{dumper}
		    && $try->{dumper}->{status} eq 'strange');
	    }
	}
    }
    push @failures, @fatal_failures, @error_failures, @missing_failures,
		    @driver_failures, @planner_failures, @dump_failures;

    $self->print_if_def(\@failures, "FAILURE DUMP SUMMARY:");
    $self->print_if_def(\@stranges, "STRANGE DUMP SUMMARY:");

    return;
}

sub by_level_count
{
    my ($count) = @_;
    my @lc;

    # start at level 1 - don't include fulls
    foreach my $i (1 .. (@$count - 1)) {
        push @lc, "$i:$count->[$i]" if defined $count->[$i] and $count->[$i] > 0;
    }
    return join(' ', @lc);
}

sub output_stats
{
    my ($self) = @_;
    my $fh     = $self->{fh};
    my $report = $self->{report};

    $self->zprint("\n");
    $self->zprint("\n");
    $self->zsprint("STATISTICS:\n");
    my $header = <<EOF;
                          Total       Full      Incr.   Level:#
                        --------   --------   --------  --------
EOF

    my $st_format = <<EOF;
@<<<<<<<<<<<<<<<<<<<<<<@>>>>>>>>  @>>>>>>>>  @>>>>>>>>  @<<<<<<<<<<<<<<<<<<
EOF

    # TODO: the hashes are a cheap fix.  fix these.
    my $full_stats  = $self->{full_stats};
    my $incr_stats  = $self->{incr_stats};
    my $total_stats = $self->{total_stats};

    my ($tapesize, $marksize );

    if ($report->{'storage_list'}[0]) {
	my $st = Amanda::Config::lookup_storage($report->{'storage_list'}[0]);
	if (!$st) {
	}
	my $tapetype_name = storage_getconf($st, $STORAGE_TAPETYPE);
	my $tt = lookup_tapetype($tapetype_name) if $tapetype_name;

	if ( $tapetype_name && $tt ) {
            $tapesize = "".tapetype_getconf( $tt, $TAPETYPE_LENGTH );
            $marksize = "".tapetype_getconf( $tt, $TAPETYPE_FILEMARK );
	}
    }

    # these values should never be zero; assign defaults
    $tapesize = 100 * 1024 * 1024 if !$tapesize;
    $marksize = 1 * 1024 * 1024   if !$marksize;

    $self->zprint($header);

    $self->zprint(swrite(
        $st_format,
        "Estimate Time (hrs:min)",
        $self->hrmn( $total_stats->{planner_time} ),
        "", "", ""
    ));

    $self->zprint(swrite(
        $st_format,
        "Run Time (hrs:min)",
        $self->hrmn( $total_stats->{total_time} ),
        "", "", ""
    ));

    $self->zprint(swrite(
        $st_format,
        "Dump Time (hrs:min)",
        $self->hrmn( $total_stats->{dumper_time} ),
        $self->hrmn( $full_stats->{dumper_time} ),
        $self->hrmn( $incr_stats->{dumper_time} ),
	""
    ));

    $self->zprint(swrite(
        $st_format,
        "Output Size (meg)",
        sprintf( "%8.1f", $total_stats->{outsize}/1024 ),
        sprintf( "%8.1f", $full_stats->{outsize}/1024 ),
        sprintf( "%8.1f", $incr_stats->{outsize}/1024 ),
        "",
    ));

    $self->zprint(swrite(
        $st_format,
        "Original Size (meg)",
        sprintf( "%8.1f", $total_stats->{origsize}/1024 ),
        sprintf( "%8.1f", $full_stats->{origsize}/1024 ),
        sprintf( "%8.1f", $incr_stats->{origsize}/1024 ),
        "",
    ));

    my $comp_size = sub {
        my ($stats) = @_;
        return $self->divzero(100 * $stats->{outsize}, $stats->{origsize});
    };

    $self->zprint(swrite(
        $st_format,
        "Avg Compressed Size (%)",
        $comp_size->($total_stats),
        $comp_size->($full_stats),
        $comp_size->($incr_stats),
        "",
    ));

    $self->zprint(swrite(
        $st_format,
        "DLEs Dumped",
        sprintf("%4d", $total_stats->{dumpdisk_count}),
        sprintf("%4d", $full_stats->{dumpdisk_count}),
        sprintf("%4d", $incr_stats->{dumpdisk_count}),
        (has_incrementals($self->{dumpdisks}) ? by_level_count($self->{dumpdisks}) : "")
    ));

    $self->zprint(swrite(
        $st_format,
        "Avg Dump Rate (k/s)",
        $self->divzero_wide( $total_stats->{outsize}, $total_stats->{dumper_time} ),
        $self->divzero_wide( $full_stats->{outsize},  $full_stats->{dumper_time} ),
        $self->divzero_wide( $incr_stats->{outsize},  $incr_stats->{dumper_time} ),
        ""
    ));
    $self->zprint("\n");

    $self->zprint(swrite(
        $st_format,
        "Tape Time (hrs:min)",
        $self->hrmn( $total_stats->{taper_time} ),
        $self->hrmn( $full_stats->{taper_time} ),
        $self->hrmn( $incr_stats->{taper_time} ),
	""
    ));

    $self->zprint(swrite(
        $st_format,
        "Tape Size (meg)",
        sprintf( "%8.1f", $total_stats->{tapesize}/1024 ),
        sprintf( "%8.1f", $full_stats->{tapesize}/1024 ),
        sprintf( "%8.1f", $incr_stats->{tapesize}/1024 ),
        ""
    ));

    my $tape_usage = sub {
        my ($stat_ref) = @_;
        return $self->divzero(
            100 * (
                $marksize *
                  ($stat_ref->{tapedisk_count} + $stat_ref->{tapepart_count}) +
                  $stat_ref->{tapesize}
            ),
            $tapesize
        );
    };

    $self->zprint(swrite(
        $st_format,
        "Tape Used (%)",
        $tape_usage->($total_stats),
        $tape_usage->($full_stats),
        $tape_usage->($incr_stats),
	""
    ));

    my $nb_incr_dle = 0;
    my @incr_dle = @{$self->{tapedisks}};
    foreach my $level (1 .. $#incr_dle) {
	$nb_incr_dle += $incr_dle[$level] if defined $incr_dle[$level];
    }
    $self->zprint(swrite(
        $st_format,
        "DLEs Taped",
        $self->{tapedisks}[0] + $nb_incr_dle,
        $self->{tapedisks}[0],
        $nb_incr_dle,
        (
            (has_incrementals($self->{tapedisks}))
            ? by_level_count($self->{tapedisks})
            : ""
        )
    ));

    # NOTE: only print out the per-level tapeparts if there are
    # incremental tapeparts
    $self->zprint(swrite(
        $st_format,
        "Parts Taped",
        sprintf("%4d", $total_stats->{tapepart_count}),
        sprintf("%4d", $full_stats->{tapepart_count}),
        sprintf("%4d", $incr_stats->{tapepart_count}),
        (
            $self->{tapeparts}[1] > 0
            ? by_level_count($self->{tapeparts})
            : ""
        )
    ));

    $self->zprint(swrite(
        $st_format,
        "Avg Tp Write Rate (k/s)",
        $self->divzero_wide( $total_stats->{tapesize}, $total_stats->{taper_time} ),
        $self->divzero_wide( $full_stats->{tapesize},  $full_stats->{taper_time} ),
        $self->divzero_wide( $incr_stats->{tapesize},  $incr_stats->{taper_time} ),
        ""
    ));

    return;
}

sub has_incrementals
{
    my $array = shift;

    for ($a = 1; $a < @$array; $a+=1) {
	return 1 if defined $array->[$a] and $array->[$a] > 0;
    }
    return 0;
}

sub output_tape_stats
{
    my ($self) = @_;
    my $fh     = $self->{fh};
    my $report = $self->{report};

    my $taper       = $report->get_program_info("taper");
    my $tapes       = $taper->{tapes}       || {};
    my $tape_labels = $taper->{tape_labels} || [];

    # if no tapes used, do nothing
    return if (!@$tape_labels);

    my $label_length = 19;
    foreach my $label (@$tape_labels) {
        $label_length = length($label) if length($label) > $label_length;
    }
    my $ts_format = "  @"
      . '<' x ($label_length - 1)
      . " @>>>>> @>>>>>>>>>>> @>>>>> @>>>> @>>>>\n";

    $self->zsprint("\n\nUSAGE BY TAPE:\n");
    $self->zprint(swrite($ts_format, "Label", "Time", "Size", "%", "DLEs", "Parts"));

    my $st = Amanda::Config::lookup_storage($report->{'storage_list'}[0]);
    if (!$st) {
    }
    my $tapetype_name = storage_getconf($st, $STORAGE_TAPETYPE);
    my $tapetype      = lookup_tapetype($tapetype_name);
    my $tapesize      = "" . tapetype_getconf($tapetype, $TAPETYPE_LENGTH);
    my $marksize      = "" . tapetype_getconf($tapetype, $TAPETYPE_FILEMARK);

    foreach my $label (@$tape_labels) {

        my $tape = $tapes->{$label};

	my $tapeused = $tape->{'kb'};
	$tapeused += $marksize * (1 + $tape->{'files'});

        $self->zprint(swrite(
            $ts_format,
            $label,
            $self->hrmn($tape->{time}),                               # time
            sprintf("%.0f", $self->tounits($tape->{kb})) . $self->{disp_unit},  # size
            $self->divzero(100 * $tapeused, $tapesize),    # % usage
            int($tape->{dle}),                        # # of dles
            int($tape->{files})                       # # of parts
        ));
    }
    return;
}

sub output_details
{
    ## takes no arguments
    my ($self)   = @_;
    my $fh       = $self->{fh};
    my $errors   = $self->{errors};
    my $notes    = $self->{notes};
    my $report   = $self->{report};
    my $stranges = $report->{stranges};

    my $disp_unit = $self->{disp_unit};

    my @failed_dump_details;
    my @strange_dump_details;

    my @dles = $report->get_dles();

    foreach my $dle_entry (@dles) {

        my ($hostname, $disk) = @$dle_entry;
        my $dle      = $report->get_dle_info(@$dle_entry);
        my $alldumps = $dle->{'dumps'} || {};
        my $qdisk    = quote_string($disk);
        my $outsize  = undef;

	while( my ($timestamp, $tries) = each %$alldumps ) {
	    foreach my $try (@$tries) {

		#
		# check for failed dumper details
		#
		if (defined $try->{dumper}
		    && $try->{dumper}->{status} eq 'fail'
		    && $try->{dumper}->{error} ne 'Aborted by driver') {

		    push @failed_dump_details,
    "/-- $hostname $qdisk lev $try->{dumper}->{level} FAILED [$try->{dumper}->{error}]",
		      @{ $try->{dumper}->{errors} },
		      "\\--------";

		    if ($try->{dumper}->{nb_errors} > 100) {
			my $nb = $try->{dumper}->{nb_errors} - 100;

			push @failed_dump_details,
    "$nb lines follow, see the corresponding log.* file for the complete list",
			  "\\--------";
		    }
		}

		#
		# check for strange dumper details
		#
		if (defined $try->{dumper}
		    && $try->{dumper}->{status} eq 'strange') {

		    push @strange_dump_details,
		      "/-- $hostname $qdisk lev $try->{dumper}->{level} STRANGE",
		      @{ $try->{dumper}->{stranges} },
		      "\\--------";

		    if ($try->{dumper}->{nb_stranges} > 100) {
			my $nb = $try->{dumper}->{nb_stranges} - 100;
			push @strange_dump_details,
    "$nb lines follow, see the corresponding log.* file for the complete list",
			  "\\--------";
		    }
		}

		# note: copied & modified from calculate_stats.
		if (
		    exists $try->{dumper}
		    && exists $try->{chunker}
		    && defined $try->{chunker}->{kb}
		    && (   $try->{chunker}{status} eq 'success'
			|| $try->{chunker}{status} eq 'partial')
		  ) {
		    $outsize = $try->{chunker}->{kb};
		} elsif (
		       exists $try->{dumper}
		    && exists $try->{taper}
		    && defined $try->{taper}->{kb}
		    && (   $try->{taper}{status} eq 'done'
			|| $try->{taper}{status} eq 'partial')
		  ) {
		    $outsize = $try->{taper}->{kb};
		}
	    }
	}

        #
        # check for bad estimates
        #

        if (exists $dle->{estimate} && defined $outsize) {
            my $est = $dle->{estimate};

            push @$notes,
              "big estimate: $hostname $qdisk $dle->{estimate}{level}",
              sprintf('                est: %.0f%s    out %.0f%s',
                $self->tounits($est->{ckb}), $disp_unit,
		$self->tounits($outsize), $disp_unit)
              if (defined $est->{'ckb'} && ($est->{ckb} * .9 > $outsize)
                && ($est->{ckb} - $outsize > 1.0e5));
        }
    }
    $self->print_if_def(\@failed_dump_details,  "FAILED DUMP DETAILS:");
    $self->print_if_def(\@strange_dump_details, "STRANGE DUMP DETAILS:");
    $self->print_if_def($notes,                 "NOTES:");

    return;
}

sub output_summary
{
    ## takes no arguments
    my ($self) = @_;
    my $fh     = $self->{fh};
    my $report = $self->{report};

    ## get the dles
    my @dles =
      sort { ( $a->[0] cmp $b->[0] ) || ( $a->[1] cmp $b->[1] ) }
      $report->get_dles();

    ## set the col_spec, which is the configuration for the summary
    ## output.
    my $col_spec = $self->set_col_spec();

    ## collect all the output line specs (see get_summary_info)
    my @summary_linespecs = ();
    foreach my $dle (@dles) {
	push @summary_linespecs, $self->get_summary_info($dle, $report, $col_spec);
    }

    # shift off the first element of each tuple
    my @summary_linedata =
      map { my @x = @$_; shift @x; [ @x ] } @summary_linespecs;

    ## get the summary format. this is based on col_spec, but may
    ## expand maxwidth columns if they have large fields.  Note that
    ## this modifies $col_spec in place.  Ordering is important: the summary
    ## format must be generated before the others.
    my $title_format = get_summary_format($col_spec, 'title', @summary_linedata);
    my $summary_format = get_summary_format($col_spec, 'full', @summary_linedata);
    my $missing_format = get_summary_format($col_spec, 'missing', @summary_linedata);
    my $noflush_format = get_summary_format($col_spec, 'noflush', @summary_linedata);
    my $nodump_PARTIAL_format = get_summary_format($col_spec, 'nodump-PARTIAL', @summary_linedata);
    my $nodump_FAILED_format = get_summary_format($col_spec, 'nodump-FAILED', @summary_linedata);
    my $nodump_FLUSH_format = get_summary_format($col_spec, 'nodump-FLUSH', @summary_linedata);
    my $nodump_VAULT_format = get_summary_format($col_spec, 'nodump-VAULT', @summary_linedata);
    my $nodump_NOT_FLUSHED_format = get_summary_format($col_spec, 'nodump-NOT FLUSHED', @summary_linedata);
    my $skipped_format = get_summary_format($col_spec, 'skipped', @summary_linedata);

    ## print the header names
    my $hdl =
      $col_spec->[0]->[COLSPEC_WIDTH] +
      $col_spec->[1]->[COLSPEC_PRE_SPACE] +
      $col_spec->[1]->[COLSPEC_WIDTH] +
      $col_spec->[2]->[COLSPEC_PRE_SPACE] +
      $col_spec->[2]->[COLSPEC_WIDTH];
    my $xs =
      $col_spec->[3]->[COLSPEC_WIDTH] +
      $col_spec->[4]->[COLSPEC_PRE_SPACE] +
      $col_spec->[4]->[COLSPEC_WIDTH] +
      $col_spec->[5]->[COLSPEC_PRE_SPACE] +
      $col_spec->[5]->[COLSPEC_WIDTH];
    my $ds =
      $col_spec->[6]->[COLSPEC_WIDTH] +
      $col_spec->[7]->[COLSPEC_PRE_SPACE] +
      $col_spec->[7]->[COLSPEC_WIDTH];
    my $ts =
      $col_spec->[8]->[COLSPEC_WIDTH] +
      $col_spec->[9]->[COLSPEC_PRE_SPACE] +
      $col_spec->[9]->[COLSPEC_WIDTH];


    ## use perl's ancient formatting support for the header, since we get free string
    ## centering..
    my $summary_header_format =
      ' ' x ($col_spec->[0]->[COLSPEC_PRE_SPACE] +
          $hdl + $col_spec->[3]->[COLSPEC_PRE_SPACE] + $xs + $col_spec->[6]->[COLSPEC_PRE_SPACE])
      . '@' . '|' x ($ds - 1)
      . ' ' x $col_spec->[8]->[COLSPEC_PRE_SPACE]
      . '@'. '|' x ($ts - 1) . "\n";
    my $summary_header = swrite($summary_header_format, "DUMPER STATS", "TAPER STATS");

    my $summary_dashes =
        ' ' x $col_spec->[0]->[COLSPEC_PRE_SPACE]
      . '-' x $hdl
      . ' ' x $col_spec->[3]->[COLSPEC_PRE_SPACE]
      . '-' x $xs
      . ' ' x $col_spec->[6]->[COLSPEC_PRE_SPACE]
      . '-' x $ds
      . ' ' x $col_spec->[8]->[COLSPEC_PRE_SPACE]
      . '-' x $ts . "\n";

    $self->zsprint("\n\nDUMP SUMMARY:\n");
    $self->zprint($summary_header);
    $self->zprint(sprintf($title_format, map { $_->[COLSPEC_TITLE] } @$col_spec));
    $self->zprint($summary_dashes);

    ## write out each output line
    for (@summary_linespecs) {
	my ($type, @data) = @$_;
	if ($type eq 'full') {
	    $self->zprint(sprintf($summary_format, @data));
	} elsif ($type eq 'nodump-PARTIAL') {
	    $self->zprint(sprintf($nodump_PARTIAL_format, @data));
	} elsif ($type eq 'nodump-FAILED') {
	    $self->zprint(sprintf($nodump_FAILED_format, @data));
	} elsif ($type eq 'nodump-FLUSH') {
	    $self->zprint(sprintf($nodump_FLUSH_format, @data));
	} elsif ($type eq 'nodump-VAULT') {
	    $self->zprint(sprintf($nodump_VAULT_format, @data));
	} elsif ($type eq 'nodump-NOT FLUSHED') {
	    $self->zprint(sprintf($nodump_NOT_FLUSHED_format, @data));
	} elsif ($type eq 'missing') {
	    $self->zprint(sprintf($missing_format, @data[0..2]));
	} elsif ($type eq 'noflush') {
	    $self->zprint(sprintf($noflush_format, @data[0..2]));
	} elsif ($type eq 'skipped') {
	    $self->zprint(sprintf($skipped_format, @data[0..2]));
	} else {
	    die("type eq $type");
	}
    }

    $self->zprint("\n");
    return;
}

## output_summary helper functions.  mostly for formatting, but some
## for data collection.  Returns an 12-tuple matching one of
##
##  ('full', host, disk, level, orig, out, comp%, dumptime, dumprate,
##    tapetime, taperate, taperpartial)
##  ('missing', host, disk, '' ..) # MISSING -----
##  ('noflush', host, disk, '' ..) # NO FILE TO FLUSH ------
##  ('nodump-$msg', host, disk, level, '', out, '--', '',
##	    '', tapetime, taperate, taperpartial)  # ... {VAULT|FLUSH|NOT FLUSHED|FAILED|PARTIAL} ...
##  ('skipped', host, disk, '' ..) # SKIPPED -----
##
## the taperpartial column is not covered by the columnspec, and "hangs off"
## the right side.  It's usually empty, but set to " PARTIAL" when the taper
## write was partial

sub get_summary_info
{
    my $self = shift;
    my ( $dle, $report, $col_spec ) = @_;
    my ( $hostname, $disk ) = @$dle;
    my @rvs;

    my $dle_info = $report->get_dle_info(@$dle);

    my $tail_quote_trunc = sub {
        my ($str, $len) = @_;

        my $q_str = quote_string($str);
        my $qt_str;

        if (length($q_str) > $len) {

            $qt_str = substr($q_str, length($q_str) - $len, $len);
            if ($q_str eq $str) {
                $qt_str =~ s{^.}{-}
            } else {
                $qt_str =~ s{^..}{"-};
            }
        } else {
            $qt_str = $q_str;
        }

        return $qt_str;
    };

    my $disk_out =
      ($col_spec->[1]->[COLSPEC_MAXWIDTH])
      ? quote_string($disk)
      : $tail_quote_trunc->($disk, $col_spec->[1]->[COLSPEC_WIDTH]);

    my $alldumps = $dle_info->{'dumps'};
    if (($dle_info->{'planner'} &&
         $dle_info->{'planner'}->{'status'} eq 'fail') or
	($dle_info->{'driver'} &&
         $dle_info->{'driver'}->{'status'} eq 'fail')) {
	# Do not report driver error if we have a try with dumper
	my $tries = $alldumps->{$report->{'run_timestamp'}};
	my $to_report = !defined $tries || !@$tries;
	foreach my $try ( @$tries ) {
	    $to_report = 1 if !defined $try->{'dumper'};
	}
	#if (!exists $alldumps->{$report->{'run_timestamp'}}) {
	if ($to_report) {
	    my @rv;
	    push @rv, 'nodump-FAILED';
	    push @rv, $hostname;
	    push @rv, $disk_out;
	    push @rv, ("",) x 9;
	    push @rvs, [@rv];
	}
    } elsif ($dle_info->{'planner'} &&
        $dle_info->{'planner'}->{'status'} eq 'skipped') {
	my @rv;
	push @rv, 'skipped';
	push @rv, $hostname;
	push @rv, $disk_out;
	push @rv, ("",) x 8;
	push @rvs, [@rv];
    } elsif (keys %{$alldumps} == 0) {
	my @rv;
	push @rv, $report->get_flag("amflush_run")? 'nodump-NOT FLUSHED' : 'missing';
	push @rv, $hostname;
	push @rv, $disk_out;
	push @rv, ("",) x 9;
	push @rvs, [@rv];
    }

    foreach my $timestamp (sort keys %$alldumps) {
	my $tries = $alldumps->{$timestamp};
	my $last_try = $tries->[-1];
	my $level =
	    exists $last_try->{taper}   ? $last_try->{taper}{level}
	  : exists $last_try->{chunker} ? $last_try->{chunker}{level}
	  :                               $last_try->{dumper}{level};

	my $orig_size = undef;
	my $storage = undef;
	my $flush_or_vault = undef;

	# find the try with the successful dumper entry
	my $dumper = undef;
	foreach my $try (@$tries) {
	    if ( exists $try->{dumper}
		&& exists $try->{dumper}{status}
		&& (   $try->{dumper}{status} eq "success"
		    || $try->{dumper}{status} eq "strange")) {
		$dumper = $try->{dumper};
		$storage = $try->{taper}->{storage} if defined $try->{taper} and defined $try->{taper}->{storage};
		last;
	    }
	}
	# Do not report taper/chunker error if no dumper for this run and driver error
	next if (!$dumper && $timestamp eq $report->get_timestamp() && $dle_info->{'driver'} && $dle_info->{'driver'}->{'status'} eq 'fail');
	$orig_size = $dumper->{orig_kb}
	    if defined $dumper;

	my ( $out_size, $dump_time, $dump_rate, $tape_time, $tape_rate ) = (0) x 5;
	my $tape_failure_from = '';
	my ($dumper_status) = "";
	my $saw_dumper = 0; # no dumper will mean this was a flush
	my $taper_partial = 0; # was the last taper run partial?
	my $taper_try = undef;

	## Use this loop to set values
	foreach my $try ( @$tries ) {
	    ## find the outsize for the output summary
	    if (
		exists $try->{taper} && defined $try->{taper}->{storage}
		&& (!$storage || $try->{taper}->{storage} eq $storage)
		&& (   $try->{taper}{status} eq "done"
		    || $try->{taper}{status} eq "part+partial" )
	      ) {
		$taper_partial = 0;
		$taper_try = $try;
		$orig_size = $try->{taper}{orig_kb} if !defined($orig_size);
		$out_size  = $try->{taper}{kb};
		$tape_time = $try->{taper}{sec};
		$tape_rate = $try->{taper}{kps};
	    } elsif ( exists $try->{taper} && defined $try->{taper}->{storage}
		&& (!$storage || $try->{taper}->{storage} eq $storage)
		&& ( $try->{taper}{status} eq "partial" ) ) {

		$taper_partial = 1;
		$taper_try = $try;
		$orig_size = $try->{taper}{orig_kb} if !defined($orig_size);
		$out_size  = $try->{taper}{kb};
		$tape_time = $try->{taper}{sec} if !$tape_time;
		$tape_rate = $try->{taper}{kps} if !$tape_rate;
	    } elsif (exists $try->{taper} && defined $try->{taper}->{storage}
		&& (!$storage || $try->{taper}->{storage} eq $storage)
		&& ( $try->{taper}{status} eq "fail")) {
		$taper_try = $try;
		$tape_time = undef;
		$tape_rate = undef;
	    }

	    if (exists $try->{taper}->{failure_from}) {
		$tape_failure_from = $try->{taper}->{failure_from};
	    } else {
		$tape_failure_from = '';
	    }
	    if (!$out_size &&
		exists $try->{chunker} && defined $try->{chunker}->{status}
		&& (   $try->{chunker}{status} eq "success"
		    || $try->{chunker}{status} eq "partial" )
	      ) {
		$out_size = $try->{chunker}{kb};
	    }

	    if (!$out_size &&
		exists $try->{dumper} && defined $try->{dumper}{kb}) {
		$out_size = $try->{dumper}{kb};
	    }

	    if ( exists $try->{dumper} && defined $try->{dumper}{status}) {
		$saw_dumper = 1;
		$dumper_status = $try->{dumper}{status};
	    }

	    ## find the dump time
	    if ( exists $try->{dumper} && defined $try->{dumper}{status}
		&& exists $try->{dumper}{status}
		&& (   $try->{dumper}{status} eq "success"
		    || $try->{dumper}{status} eq "strange")) {

		$dump_time = $try->{dumper}{sec};
		$dump_rate = $try->{dumper}{kps};
	    }
	    last if defined $taper_try;
	}

	# sometimes the driver logs an orig_size of -1, which makes the
	# compression percent very large and negative
	$orig_size = 0 if (defined $orig_size && $orig_size < 0);

	# pre-format the compression column, with '--' replacing 100% (i.e.,
	# no compression)
	my $compression;
	if (!defined $orig_size || $orig_size == 0 ||
	    $taper_partial ||
	    ($out_size/$orig_size > 0.99  && $out_size/$orig_size < 1.01)) {
	    $compression = '--';
	    $compression = $self->divzero(0, 0);
	} else {
	    $compression =
	      $self->divzero_col((100 * $out_size), $orig_size, $col_spec->[5]);
	}

	## simple formatting macros
	my $fmt_col_field;
	if ($self->isa("Amanda::Report::json")) {
	    $fmt_col_field = sub {
		my ( $column, $data ) = @_;
		return $data;
	    };
	} else {
	    $fmt_col_field = sub {
		my ( $column, $data ) = @_;

		return sprintf(
		    $col_spec->[$column]->[COLSPEC_FORMAT],
		    $col_spec->[$column]->[COLSPEC_WIDTH],
		    $col_spec->[$column]->[COLSPEC_PREC], $data
		);
	    };
	}

	my $format_space = sub {
	    my ( $column, $data ) = @_;

	    return sprintf("%*s",$col_spec->[$column]->[COLSPEC_WIDTH], $data);
	};

	my @rv;

	if ( !$orig_size && !$out_size && ((!defined($tape_time) || !$tape_time) && !defined($tape_failure_from))) {
	    push @rv, $report->get_flag("amflush_run")? 'noflush' : 'missing';
	    push @rv, $hostname;
	    push @rv, $disk_out;
	    push @rv, ("",) x 8;
	} elsif ($saw_dumper and ($dumper_status eq 'success' or $dumper_status eq 'strange')) {
	    push @rv, "full";
	    push @rv, $hostname;
	    push @rv, $disk_out;
	    push @rv, $fmt_col_field->(2, $level);
	    push @rv, $orig_size ? $fmt_col_field->(3, $self->tounits($orig_size)) : '';
	    push @rv, $out_size ? $fmt_col_field->(4, $self->tounits($out_size)) : '';
	    push @rv, $compression;
	    push @rv, $dump_time ? $fmt_col_field->(6, $self->mnsc($dump_time)) : "PARTIAL";
	    push @rv, $dump_rate ? $fmt_col_field->(7, $dump_rate) : "";
	    if (defined $tape_failure_from and $tape_failure_from eq 'config') {
		push @rv, $format_space->(8,"");
		push @rv, $format_space->(9,"");
	    } else {
		push @rv, $fmt_col_field->(8,
		    (defined $tape_time) ?
			    $tape_time ? $self->mnsc($tape_time) : ""
			  : "FAILED");
		push @rv, (defined $tape_rate) ?
			  $tape_rate ?
			        $fmt_col_field->(9, $tape_rate)
			      : $format_space->(9, "")
			  : $format_space->(9, "FAILED");
	    }
	    push @rv, $taper_partial? " PARTIAL" : ""; # column 10
	    # if others try with successful taper (sent to another storage)
	    foreach my $try ( @$tries ) {
		next if !$try->{'taper'};
		next if !defined $try->{'taper'}->{status};
		next if defined $taper_try && $try == $taper_try;
		#next if $try->{taper}{status} ne "done";
		push @rvs, [@rv];
		if ($report->get_flag("amvault_run")) {
		     @rv = 'nodump-VAULT';
		} else {
		    if ($try->{taper}->{storage}) {
			$storage = $try->{taper}->{storage};
			$flush_or_vault = $report->{'flush_or_vault'}->{$storage};
		    }
		    if (defined $flush_or_vault) {
			@rv = "nodump-$flush_or_vault";
		    } else {
			@rv = 'nodump-FLUSH';
		    }
		}
		#@rv = 'nodump-FLUSH';
		#@rv = 'nodump-VAULT' if $report->get_flag("amvault_run");
		push @rv, '';
		push @rv, '';
		push @rv, '';
		push @rv, '';
		push @rv, '';
		push @rv, '';
		push @rv, '';
		push @rv, '';
		$tape_time = $try->{taper}{sec};
		$tape_rate = $try->{taper}{kps};
	        push @rv, $fmt_col_field->(8,
		       (defined $tape_time) ?
			       $tape_time ? $self->mnsc($tape_time) : ""
			     : "FAILED");
	        push @rv, (defined $tape_rate) ?
		   $tape_rate ?
		       $fmt_col_field->(9, $tape_rate)
		     : $format_space->(9, "")
	           : $format_space->(9, "FAILED");
	        push @rv, '';

	    }
	} else {
	    if ($taper_try && $taper_try->{taper}->{storage} && $report->{'flush_or_vault'}->{$taper_try->{taper}->{storage}}) {
		$storage = $taper_try->{taper}->{storage};
		$flush_or_vault = $report->{'flush_or_vault'}->{$storage};
	    }
	    my $message = $saw_dumper?
			    ($dumper_status eq 'failed') ? 'FAILED' : 'PARTIAL'
			  : (defined $tape_failure_from and
			     $tape_failure_from eq 'config') ? 'NOT FLUSHED'
			  : $report->get_flag("amvault_run") ? 'VAULT'
			  : $report->get_flag("amflush_run") ? 'FLUSH'
			  : defined $flush_or_vault          ? $flush_or_vault
							     : 'FAILED';
	    push @rv, "nodump-$message";
	    push @rv, $hostname;
	    push @rv, $disk_out;
	    push @rv, $fmt_col_field->(2, $level);
	    push @rv, $orig_size ? $fmt_col_field->(4, $self->tounits($orig_size)) :'';
	    push @rv, $out_size ? $fmt_col_field->(4, $self->tounits($out_size)) : '';
	    push @rv, $compression;
	    push @rv, '';
	    push @rv, '';
	    if (defined $tape_failure_from and $tape_failure_from eq 'config') {
		push @rv, $format_space->(8,"");
		push @rv, $format_space->(9,"");
		next if !$report->get_flag("amflush_run"); # do not print a line for flush with config error
	    } else {
	       push @rv, $fmt_col_field->(8,
		       (defined $tape_time) ?
			       $tape_time ? $self->mnsc($tape_time) : ""
			     : "FAILED");
	       push @rv, (defined $tape_rate) ?
		   $tape_rate ?
		       $fmt_col_field->(9, $tape_rate)
		     : $format_space->(9, "")
	         : $format_space->(9, "FAILED");
	    }
	    push @rv, $taper_partial? " PARTIAL" : "";
	    # if others try with successful taper (sent to another storage)
	    foreach my $try ( @$tries ) {
		next if !$try->{'taper'};
		next if defined $taper_try and $try eq $taper_try;
		next if !defined $try->{taper}{status} or $try->{taper}{status} ne "done";
		push @rvs, [@rv];

		if ($try->{taper}->{storage} && $report->{'flush_or_vault'}->{$try->{taper}->{storage}}) {
		    $storage = $try->{taper}->{storage};
		    $flush_or_vault = $report->{'flush_or_vault'}->{$storage};
		    @rv = "nodump-$flush_or_vault";
		} else {
		    @rv = 'nodump-FLUSH';
		    @rv = 'nodump-VAULT' if $report->get_flag("amvault_run");
		}
		push @rv, '';
		push @rv, '';
		push @rv, '';
		push @rv, '';
		push @rv, '';
		push @rv, '';
		push @rv, '';
		push @rv, '';
		$tape_time = $try->{taper}{sec};
		$tape_rate = $try->{taper}{kps};
	        push @rv, $fmt_col_field->(8,
		       (defined $tape_time) ?
			       $tape_time ? $self->mnsc($tape_time) : ""
			     : "FAILED");
	        push @rv, (defined $tape_rate) ?
		   $tape_rate ?
		       $fmt_col_field->(9, $tape_rate)
		     : $format_space->(9, "")
	           : $format_space->(9, "FAILED");
	        push @rv, " ";

	    }
	}
	push @rvs, [@rv];
    }
    return @rvs;
}

sub get_summary_format
{
    my ($col_spec, $type, @summary_lines) = @_;
    my @col_format = ();

    if ($type eq 'full' || $type eq 'title') {
	foreach my $i ( 0 .. ( @$col_spec - 1 ) ) {
	    push @col_format,
	      get_summary_col_format( $i, $col_spec->[$i],
		map { $_->[$i] } @summary_lines );
	}
    } else {
	# first two columns are the same
	foreach my $i ( 0 .. 1 ) {
	    push @col_format,
	      get_summary_col_format( $i, $col_spec->[$i],
		map { $_->[$i] } @summary_lines );
	}

	# some of these have a lovely text rule, just to be difficult
	my $rulewidth =
	    $col_spec->[3]->[COLSPEC_WIDTH] +
	    $col_spec->[4]->[COLSPEC_PRE_SPACE] +
	    $col_spec->[4]->[COLSPEC_WIDTH] +
	    $col_spec->[5]->[COLSPEC_PRE_SPACE] +
	    $col_spec->[5]->[COLSPEC_WIDTH] +
	    $col_spec->[6]->[COLSPEC_PRE_SPACE] +
	    $col_spec->[6]->[COLSPEC_WIDTH] +
	    $col_spec->[7]->[COLSPEC_PRE_SPACE] +
	    $col_spec->[7]->[COLSPEC_WIDTH] +
	    $col_spec->[8]->[COLSPEC_PRE_SPACE] +
	    $col_spec->[8]->[COLSPEC_WIDTH] +
	    $col_spec->[9]->[COLSPEC_PRE_SPACE] +
	    $col_spec->[9]->[COLSPEC_WIDTH];

	if ($type eq 'missing') {
	    # add a blank level column and the space for the origkb column
	    push @col_format, ' ' x $col_spec->[2]->[COLSPEC_PRE_SPACE];
	    push @col_format, ' ' x $col_spec->[2]->[COLSPEC_WIDTH];
	    push @col_format, ' ' x $col_spec->[3]->[COLSPEC_PRE_SPACE];
	    my $str = "MISSING ";
	    $str .= '-' x ($rulewidth - length($str));
	    push @col_format, $str;
	} elsif ($type eq 'noflush') {
	    # add a blank level column and the space for the origkb column
	    push @col_format, ' ' x $col_spec->[2]->[COLSPEC_PRE_SPACE];
	    push @col_format, ' ' x $col_spec->[2]->[COLSPEC_WIDTH];
	    push @col_format, ' ' x $col_spec->[3]->[COLSPEC_PRE_SPACE];

	    my $str = "NO FILE TO FLUSH ";
	    $str .= '-' x ($rulewidth - length($str));
	    push @col_format, $str;
	} elsif ($type =~ /^nodump-(.*)$/) {
	    my $msg = $1;

	    # nodump has level, origkb, outkb, and comp% although origkb is usually blank and
	    # comp% is "--".
	    foreach my $i ( 2 .. 5 ) {
		push @col_format,
		  get_summary_col_format( $i, $col_spec->[$i],
		    map { $_->[$i] } @summary_lines );
	    }

	    # and then the message is centered across columns 6 and 7, which are both blank
	    push @col_format, ' ' x $col_spec->[6]->[COLSPEC_PRE_SPACE];
	    my $width =
		$col_spec->[6]->[COLSPEC_WIDTH] +
		$col_spec->[7]->[COLSPEC_PRE_SPACE] +
		$col_spec->[7]->[COLSPEC_WIDTH];

	    my $str = ' ' x (($width - length($msg))/2);
	    $str .= $msg;
	    $str .= ' ' x ($width - length($str));
	    push @col_format, $str;
	    push @col_format, "%s%s"; # consume empty columns 6 and 7

	    # and finally columns 8 and 9 as usual
	    foreach my $i ( 8 .. 9 ) {
		push @col_format,
		  get_summary_col_format( $i, $col_spec->[$i],
		    map { $_->[$i] } @summary_lines );
	    }
	} elsif ($type eq 'skipped') {
	    # add a blank level column and the space for the origkb column
	    push @col_format, ' ' x $col_spec->[2]->[COLSPEC_PRE_SPACE];
	    push @col_format, ' ' x $col_spec->[2]->[COLSPEC_WIDTH];
	    push @col_format, ' ' x $col_spec->[3]->[COLSPEC_PRE_SPACE];
	    my $str = "SKIPPED ";
	    $str .= '-' x ($rulewidth - length($str));
	    push @col_format, $str;
	}
    }

    # and format the hidden 10th column.  This is not part of the columnspec,
    # so its width is not counted in any of the calculations here.
    push @col_format, "%s" if $type ne 'title';

    return join( "", @col_format ) . "\n";
}

sub get_summary_col_format
{
    my ( $i, $col, @entries ) = @_;

    my $col_width = $col->[COLSPEC_WIDTH];
    my $left_align = ($i == 0 || $i == 1); # first 2 cols left-aligned
    my $limit_width = ($i == 0 || $i == 1); # and not allowed to overflow

    ## if necessary, resize COLSPEC_WIDTH to the maximum widht
    ## of any row
    if ($col->[COLSPEC_MAXWIDTH]) {

        push @entries, $col->[COLSPEC_TITLE];
	my $strmax = max( map { length $_ } @entries );
	$col_width = max($strmax, $col_width);
	# modify the spec in place, so the headers and
	# whatnot all add up .. yuck!
	$col->[COLSPEC_WIDTH] = $col_width;
    }

    # put together a "%s" format for this column
    my $rv = ' ' x $col->[COLSPEC_PRE_SPACE]; # space on left
    $rv .= '%';
    $rv .= '-' if $left_align;
    $rv .= $col_width;
    $rv .= ".$col_width" if $limit_width;
    $rv .= "s";
}

## col_spec functions.  I want to deprecate this stuff so bad it hurts.

sub set_col_spec
{
    my ($self) = @_;
    my $report = $self->{report};
    my $disp_unit = $self->{disp_unit};

    $self->{col_spec} = [
        [ "HostName", 0, 12, 12, 1, "%-*.*s", "HOSTNAME" ],
        [ "Disk",     1, 11, 11, 1, "%-*.*s", "DISK" ],
        [ "Level",    1, 1,  1,  1, "%*.*d",  "L" ],
        [ "OrigKB",   1, 7,  0,  1, "%*.*f",  "ORIG-" . $disp_unit . "B" ],
        [ "OutKB",    1, 7,  0,  1, "%*.*f",  "OUT-" . $disp_unit . "B" ],
        [ "Compress", 1, 6,  1,  1, "%*.*f",  "COMP%" ],
        [ "DumpTime", 1, 7,  7,  1, "%*.*s",  "MMM:SS" ],
        [ "DumpRate", 1, 6,  1,  1, "%*.*f",  "KB/s" ],
        [ "TapeTime", 1, 6,  6,  1, "%*.*s",  "MMM:SS" ],
        [ "TapeRate", 1, 6,  1,  1, "%*.*f",  "KB/s" ]
    ];

    $self->apply_col_spec_override();
    return $self->{col_spec};
}

sub apply_col_spec_override
{
    my ($self) = @_;
    my $col_spec = $self->{col_spec};

    my %col_spec_override = $self->read_col_spec_override();

    foreach my $col (@$col_spec) {
        if ( my $col_override = $col_spec_override{ $col->[COLSPEC_NAME] } ) {
            my $override_col_val_if_def = sub {
                my ( $field, $or_num ) = @_;
                if ( defined $col_override->[$or_num]
                    && !( $col_override->[$or_num] eq "" ) ) {
                    $col->[$field] = $col_override->[$or_num];
                }
            };

            $override_col_val_if_def->( COLSPEC_PRE_SPACE, 0 );
            $override_col_val_if_def->( COLSPEC_WIDTH,     1 );
            $override_col_val_if_def->( COLSPEC_PREC,      2 );
            $override_col_val_if_def->( COLSPEC_MAXWIDTH,  3 );
        }
    }
}

sub read_col_spec_override
{
    my ($self) = @_;

    my $col_spec_str = getconf($CNF_COLUMNSPEC) || return;
    my %col_spec_override = ();
    my $col_spec = $self->{col_spec};

    foreach (split(",", $col_spec_str)) {

        $_ =~ m/^(\w+)           # field name
                =([-:\d]+)       # field values
                $/x
          or confess "error: malformed columnspec string:$col_spec_str";

        my $field = $1;
	my $found = 0;

	foreach my $col (@$col_spec) {
	    if (lc $field eq lc $col->[0]) {
		$field = $col->[0];
		$found = 1;
	    }
	}
	if ($found == 0) {
	    die("Invalid field name: $field");
	}

        my @field_values = split ':', $2;

        # too many values
        confess "error: malformed columnspec string:$col_spec_str"
          if (@field_values > 3);

        # all values *should* be in the right place.  If not enough
        # were given, pad the array.
        push @field_values, "" while (@field_values < 4);

	# if the second value is negative, that means MAXWIDTH=1, so
	# sort that out now.  Yes, this is pretty ugly.  Imagine this in C!
	if ($field_values[1] ne '') {
	    if ($field_values[1] =~ /^-/) {
		$field_values[1] =~ s/^-//;
		$field_values[3] = 1;
	    } else {
		$field_values[3] = 0;
	    }
	}

        $col_spec_override{$field} = \@field_values;
    }

    return %col_spec_override;
}

sub print_if_def
{
    my ($self, $msgs, $header) = @_;
    my $fh = $self->{fh};

    @$msgs or return;    # do not print section if no messages

    $self->zsprint("\n");
    $self->zsprint("\n");
    $self->zsprint("$header\n");
    foreach my $msg (@$msgs) {
        $self->zprint("  $msg\n");
    }
}


1;
