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
# Contact information: Carbonite Inc., 756 N Pastoria Ave
# Sunnyvale, CA 94085, or: http://www.zmanda.com


=head1 NAME

Amanda::Curinfo::Info - Perl extension for representing dump
information

=head1 SYNOPSIS

   use Amanda::Curinfo::Info;

   my $info = Amanda::Curinfo::Info->new($infofile);

=head1 DESCRIPTION

C<Amanda::Curinfo::Info> is the format representation for the curinfo
database.  It handles the reading and writing of the individual
entries, while the entry management is left to C<Amanda::Curinfo>.
Further parsing is also dispatched to C<Amanda::Curinfo::History>,
C<Amanda::Curinfo::Stats>, and C<Amanda::Curinfo::Perf>.

=head1 INTERFACE

The constructor for a new info object is very simple.

   my $info = Amanda::Curinfo::Info->new();

Will return an empty info object with the necessary fields all blank.

Given an existing C<$info> object, for example, as provided by
C<Amanda::Curinfo::get_info>, there are other functions present in this
library, but they are helper functions to the previously described
methods, and not to be used directly.

It should also be noted that the reading and writing methods of
C<Amanda::Curinfo::Info> are not meant to be used directly, and should be
left to L<Amanda::Curinfo>.

Reading a previously stored info object is handled with the same
subroutine.

   my $info = Amanda::Curinfo::Info->new($infofile);

Here, C<$info> will contain all the information that was stored in
C<$infofile>.

To write the file to a new location, use the following command:

   $info->write_to_file($infofile);

There are also three corresponding container classes that hold data
and perform parsing functions.  They should only be used when actually
writing info file data.

   my $history =
     Amanda::Curinfo::History->new( $level, $size, $csize, $date, $secs );
   my $stats =
     Amanda::Curinfo::Stats->new( $level, $size, $csize, $secs, $date, $filenum,
       $label );

   my $perf = Amanda::Curinfo::Perf->new();
   $perf->set_rate( $pct1, $pct2, $pct3 );
   $perf->set_comp( $dbl1, $dbl2, $dbl3 );

Note that C<Amanda::Curinfo::Perf> is different.  This is because its
structure is broken up into two lines in the infofile format, and the
length of the C<rate> and C<comp> arrays maybe subject to change in
the future.

You can also instantiate these objects directly from a
properly-formatted line in an infofile:

   my $history = Amanda::Curinfo::History->from_line($info, $hist_line);
   my $stats   = Amanda::Curinfo::Stats->from_line($info, $stat_line);

   my $perf = Amanda::Curinfo::Perf->new();
   $perf->set_rate_from_line($rate_line);
   $perf->set_comp_from_line($comp_line);

Again, creating C<Amanda::Curinfo::Perf> is broken into two calls
because its object appears on two lines.

Writing these objects back to the info file, however, are all identical:

   print $infofh $history->to_line();
   print $infofh $stats->to_line();
   print $infofh $perf_full->to_line("full");
   print $infofh $perf_incr->to_line("incr");

Additionally, the C<$perf> object accepts a prefix to the line.

=head1 SEE ALSO

This package is meant to replace the file reading and writing portions
of server-src/infofile.h.  If you notice any bugs or compatibility
issues, please report them.

=head1 AUTHOR

Paul C. Mantz E<lt>pcmantz@zmanda.comE<gt>

=cut

my $numdot = qr{[.\d]};
#my $minusnumdot = qr{[.\d\-]};
my $minusnumdot = "[.\\d\-]";

package Amanda::Curinfo::Info;

use strict;
use warnings;

our $NO_COMMAND    = 0;
our $FORCE_FULL    = 1;
our $FORCE_BUMP    = 2;
our $FORCE_NO_BUMP = 4;
our $FORCE_LEVEL_1 = 8;

use Carp;

use Amanda::Config qw( :getconf );

sub new
{
    my ($class, $infofile) = @_;

    my $self = {
        command => undef,
	infofile => $infofile,
        full    => Amanda::Curinfo::Perf->new(),
        incr    => Amanda::Curinfo::Perf->new(),
        inf              => [],      # contains Amanda::Curinfo::Stats
        history          => [],      # contains Amanda::Curinfo::History
	last_level       => -1,
	consecutive_runs => -1,
    };

    bless $self, $class;
    my $err = $self->read_infofile($infofile) if -e $infofile;
    return $err if $err;

    return $self;
}

sub set {
    my $self = shift;
    my $command = shift;

    if (!defined $self->{'command'}) {
	$self->{'command'} = $command;
    } else {
	$self->{'command'} |= $command;
    }
}

sub isset {
    my $self = shift;
    my $command = shift;

    if (!defined $self->{'command'}) {
	return 0;
    } else {
	return $self->{'command'} & $command;
    }
}

sub clear {
    my $self = shift;
    my $command = shift;

    if (!defined $self->{'command'}) {
	$self->{'command'} = ~$command;
    } else {
	$self->{'command'} &= ~$command;
    }
}

sub get_dumpdate
{
    my ( $self, $level ) = @_;
    my $inf  = $self->{inf};
    my $date = 0;            # Ideally should be set to the epoch, but 0 is fine

    for ( my $l = 0 ; $l < $level ; $l++ ) {

        my $this_date = $inf->[$l]->{date};
        $date = $this_date if ( $this_date > $date );
    }

    my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) =
      gmtime $date;

    my $dumpdate = sprintf(
        '%d:%d:%d:%d:%d:%d',
        $year + 1900,
        $mon + 1, $mday, $hour, $min, $sec
    );

    return $dumpdate;
}

sub read_infofile
{
    my ( $self, $infofile ) = @_;
    my $err;

    open my $fh, "<", $infofile or
    return Amanda::Curinfo::Message->new(
			source_filename => __FILE__,
			source_line     => __LINE__,
			code        => 1300029,
			severity    => $Amanda::Message::ERROR,
			infofile    => $infofile,
			error       => $!);

    if (-z $infofile) {
	return;
    };

    ## read in the fixed-length data
    $err = $self->read_infofile_perfs($fh);
    if ($err) {
	close $fh;
	return $err
    }

    ## read in the stats data
    $err = $self->read_infofile_stats($fh);
    if ($err) {
	close $fh;
	return $err
    }

    ## read in the history data
    $err = $self->read_infofile_history($fh);
    if ($err) {
	close $fh;
	return $err
    }

    close $fh;

    return;
}

sub read_infofile_perfs
{
    my ($self, $fh) = @_;

    my $fail = sub {
        my ($line, $linenum) = @_;
	return Amanda::Curinfo::Message->new(
				source_filename => __FILE__,
				source_line     => $linenum,
				code     => 1300009,
				severity => $Amanda::Message::ERROR,
				infofile => $self->{'infofile'},
				line     => $line);
    };

    my $skip_blanks = sub {
	my $linenum = shift;
        my $line = "";
        while ($line eq "") {
	    if (eof($fh)) {
		return Amanda::Curinfo::Message->new(
				source_filename => __FILE__,
				source_line     => $linenum,
				code     => 1300010,
				severity => $Amanda::Message::ERROR,
				infofile => $self->{'infofile'},
				line     => $line);
	    }
            $line = <$fh>;
        }
        return $line;
    };

    # version not paid attention to right now
    my $line = $skip_blanks->(__LINE__);
    return $line if $line->isa("Amanda::Message");
    ($line =~ /^version: ($numdot+)/) ? 1 : return $fail->($line, __LINE__);

    $line = $skip_blanks->(__LINE__);
    return $line if $line->isa("Amanda::Message");
    ($line =~ /^command: ($numdot+)/)
      ? $self->{command} = $1
      : return $fail->($line, __LINE__);

    $line = $skip_blanks->(__LINE__);
    return $line if $line->isa("Amanda::Message");
    ($line =~ /^full-rate:(?: ($minusnumdot+))?(?: ($minusnumdot+))?(?: ($minusnumdot+))?/)
      ? $self->{full}->set_rate($1, $2, $3)
      : return $fail->($line, __LINE__);

    $line = $skip_blanks->(__LINE__);
    return $line if $line->isa("Amanda::Message");
    ($line =~ /^full-comp:(?: ($minusnumdot+))?(?: ($minusnumdot+))?(?: ($minusnumdot+))?/)
      ? $self->{full}->set_comp($1, $2, $3)
      : return $fail->($line, __LINE__);

    $line = $skip_blanks->(__LINE__);
    return $line if $line->isa("Amanda::Message");
    ($line =~ /^incr-rate:(?: ($minusnumdot+))?(?: ($minusnumdot+))?(?: ($minusnumdot+))?/)
      ? $self->{incr}->set_rate($1, $2, $3)
      : return $fail->($line, __LINE__);

    $line = $skip_blanks->(__LINE__);
    return $line if $line->isa("Amanda::Message");
    ($line =~ /^incr-comp:(?: ($minusnumdot+))?(?: ($minusnumdot+))?(?: ($minusnumdot+))?/)
      ? $self->{incr}->set_comp($1, $2, $3)
      : return $fail->($line, __LINE__);

    return;
}

sub read_infofile_stats
{
    my ( $self, $fh ) = @_;

    my $inf = $self->{inf};

    while ( my $line = <$fh> ) {

        ## try next line if blank
        if ( $line eq "" ) {
            next;

        } elsif ( $line =~ m{^//} ) {
	    return Amanda::Curinfo::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code     => 1300011,
				severity => $Amanda::Message::ERROR,
				infofile => $self->{'infofile'},
				line     => $line);

        } elsif ( $line =~ m{^history:} ) {
	    return Amanda::Curinfo::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code     => 1300012,
				severity => $Amanda::Message::ERROR,
				infofile => $self->{'infofile'},
				line     => $line);

        } elsif ( $line =~ m{^stats:} ) {

            ## make a new Stats object and push it on to the queue
            my $stats = Amanda::Curinfo::Stats->from_line($self, $line);
	    return $stats if $stats->isa("Amanda::Message");
            push @$inf, $stats;

        } elsif ( $line =~ m{^last_level:(?: ([\d\-]+))?(?: ([\d\-]+))?$} ) {

            $self->{last_level}       = $1;
            $self->{consecutive_runs} = $2;
            last;

        } else {
	    return Amanda::Curinfo::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code     => 1300013,
				severity => $Amanda::Message::ERROR,
				infofile => $self->{'infofile'},
				line     => $line);
        }
    }

    return;
}

sub read_infofile_history
{
    my ( $self, $fh ) = @_;

    my $history = $self->{history};

    while ( my $line = <$fh> ) {

        if ( $line =~ m{^//} ) {
            return;

        } elsif ( $line =~ m{^history:} ) {
            my $hist = Amanda::Curinfo::History->from_line($self, $line);
	    return $hist if $hist->isa("Amanda::Message");
            push @$history, $hist;

        } else {
	    return Amanda::Curinfo::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code     => 1300014,
				severity => $Amanda::Message::ERROR,
				infofile => $self->{'infofile'},
				line     => $line);
        }
    }

    #
    # TODO: make sure there were the right number of history lines
    #

    return;
}

sub write_to_file
{
    my ( $self, $infofile ) = @_;

    unlink $infofile if -f $infofile;

    open my $fh, ">", $infofile or
	return Amanda::Curinfo::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code     => 1300015,
				severity => $Amanda::Message::ERROR,
				infofile => $self->{'infofile'},
				error    => $!);

    ## print basics

    print $fh "version: 0\n";    # 0 for now, may change in future
    print $fh "command: $self->{command}\n";
    print $fh $self->{full}->to_line("full");
    print $fh $self->{incr}->to_line("incr");

    ## print stats

    foreach my $stat ( @{ $self->{inf} } ) {
        print $fh $stat->to_line();
    }
    print $fh "last_level: $self->{last_level} $self->{consecutive_runs}\n";

    foreach my $hist ( @{ $self->{history} } ) {
        print $fh $hist->to_line();
    }
    print $fh "//\n";

    return 1;
}

sub update_dumper {
    my $self = shift;
    my $orig_size = shift;
    my $dump_size = shift;
    my $dump_time = shift;
    my $level = shift;
    my $timestamp = shift;

    #$orig_size is already in kb.
    $dump_size /= 1024;

    # Clean up information about this and higher-level dumps. This
    # assumes that update_dumper is always run before update_taper.
    splice @{$self->{'inf'}}, $level;

    #now store information about this dump
    $self->{'inf'}[$level] = Amanda::Curinfo::Stats->new($level, $orig_size,
			$dump_size, $dump_time,
			Amanda::Util::get_time_from_timestamp($timestamp),
			undef, undef);

    my $perf;
    if ($level == 0) {
	$perf = $self->{'full'};
    } else {
	$perf = $self->{'incr'};
    }

    if ($orig_size != $dump_size and $orig_size != 0) {
	shift @{$perf->{'comp'}} if @{$perf->{'comp'}} > 2;
	my $idx = @{$perf->{'comp'}};
	$perf->{'comp'}[$idx] = "$dump_size." / $orig_size;
    }

    if ($dump_time > 0) {
	shift @{$perf->{'rate'}} if @{$perf->{'rate'}} > 2;
	my $idx = @{$perf->{'rate'}};
	if ($dump_time >= $dump_size) {
	    $perf->{'rate'}[$idx] = 1;
	} else {
	    $perf->{'rate'}[$idx] = "$dump_size.0" / $dump_time;
	}
    }

    if ($orig_size >= 0 and getconf($CNF_RESERVE) < 100) {
	$self->{'command'} = $NO_COMMAND;
    }

    if ($orig_size >= 0) {
	if ($level == $self->{'last_level'}) {
	    $self->{'consecutive_runs'}++;
	} else {
	    $self->{'last_level'} = $level;
	    $self->{'consecutive_runs'} = 1;
	}
    }

    if ($orig_size >= 0 and $dump_size >= 0) {
	pop @{$self->{'history'}} if @{$self->{'history'}} > 99;
	my $ctime;
	if ($timestamp == 0) {
	    $ctime = 0;
	} else {
	    $ctime = Amanda::Util::get_time_from_timestamp($timestamp),
	}
	unshift @{$self->{'history'}}, Amanda::Curinfo::History->new(
			$level, $orig_size, $dump_size, $ctime, $dump_time);
    }
}


#
#
#

package Amanda::Curinfo::History;

use strict;
use warnings;
use Carp;

sub new
{
    my $class = shift;
    my ( $level, $size, $csize, $date, $secs ) = @_;

    my $self = {
        level => $level,
        size  => $size,
        csize => $csize,
        date  => $date,
        secs  => $secs,
    };

    return bless $self, $class;
}

sub from_line
{
    my ( $class, $info, $line ) = @_;

    my $self = undef;

    if (
        $line =~ m{^history:    \s+
                     (\d+)      \s+  # level
                     ($numdot+) \s+  # size
                     ($numdot+) \s+  # csize
                     ($numdot+) \s+  # date
                     ($numdot+) $    # secs
                  }x
      ) {
        $self = {
            level => $1,
            size  => $2,
            csize => $3,
            date  => $4,
            secs  => $5,
        };
    } else {
	return Amanda::Curinfo::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code     => 1300016,
				severity => $Amanda::Message::ERROR,
				infofile => $info->{'infofile'},
				line     => $line);
    }

    return bless $self, $class;
}

sub to_line
{
    my ($self) = @_;
    return
"history: $self->{level} $self->{size} $self->{csize} $self->{date} $self->{secs}\n";
}

1;

#
#
#

package Amanda::Curinfo::Perf;

use strict;
use warnings;
use Carp;

use Amanda::Config;

sub new
{
    my ($class) = @_;

    my $self = {
        rate => [ -1.0, -1.0, -1.0 ],
        comp => [ -1.0, -1.0, -1.0 ],
    };

    return bless $self, $class;
}

sub set_rate
{
    my ( $self, @rate ) = @_;
    foreach my $rate (@rate) {
	$rate = -1 if !defined $rate;
    }
    $self->{rate} = \@rate;
}

sub set_comp
{
    my ( $self, @comp ) = @_;
    foreach my $comp (@comp) {
	$comp = -1 if !defined $comp;
    }
    $self->{comp} = \@comp;
}

sub set_rate_from_line
{
    my ( $self, $line ) = @_;
    return $self->set_field_from_line( $self, $line, "rate" );

}

sub set_comp_from_line
{
    my ( $self, $line ) = @_;
    return $self->set_field_from_line( $self, $line, "comp" );

}

sub set_field_from_line
{
    my ( $self, $line, $field ) = @_;

    if (
        $line =~ m{\w+-$field\: \s+
                      ($minusnumdot) \s+
                      ($minusnumdot) \s+
                      ($minusnumdot) $
                   }x
      ) {
        $self->{$field} = [ $1, $2, $3 ];

    } else {
	return Amanda::Curinfo::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code     => 1300017,
				severity => $Amanda::Message::ERROR,
				infofile => $self->{'infofile'},
				field    => $field,
				line     => $line);
    }

    return;
}

sub to_line
{
    my ( $self, $lvl ) = @_;

    my $result;
    if ($self->{rate}) {
	$result = "$lvl-rate: " . join( " ", @{ $self->{rate} } ) . "\n"
    } else {
	$result = "$lvl-rate: -1.0 -1.0 -1.0\n";
    }

    if ($self->{comp}) {
	$result .= "$lvl-comp: " . join( " ", @{ $self->{comp} } ) . "\n"
    } else {
	$result .= "$lvl-comp: -1.0 -1.0 -1.0\n";
    }

    return $result;
}


#
#
#

package Amanda::Curinfo::Stats;

use strict;
use warnings;
use Carp;

sub new
{
    my $class = shift;
    my ( $level, $size, $csize, $secs, $date, $filenum, $label ) = @_;

    my $self = {
        level   => $level,
        size    => $size,
        csize   => $csize,
        secs    => $secs,
        date    => $date,
        filenum => $filenum || '',
        label   => $label || '',
    };

    bless $self, $class;
    return $self;
}

sub from_line
{
    my ( $class, $info, $line ) = @_;

    my $self = undef;

			# level size csize sec date filenum label
    $line =~ m{^stats: (\d+) ($minusnumdot+) ($minusnumdot+) ($minusnumdot+) ($minusnumdot+) ($minusnumdot+) (.*)$}
			# level size csize sec date
      or $line =~ m{^stats: (\d+) ($minusnumdot+) ($minusnumdot+) ($minusnumdot+) ($minusnumdot+)}
      or return Amanda::Curinfo::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code     => 1300018,
				severity => $Amanda::Message::ERROR,
				infofile => $info->{'infofile'},
				line     => $line);

    $self = {
        level   => $1,
        size    => $2,
        csize   => $3,
        secs    => $4,
        date    => $5,
        filenum => $6 || "",
        label   => $7 || "",
    };
    return bless $self, $class;
}

sub to_line
{
    my ($self) = @_;
    if (defined $self->{filenum} && defined $self->{label}) {
	return join( " ",
            "stats:",      $self->{level}, $self->{size}, $self->{csize},
            int($self->{secs}), $self->{date},  $self->{filenum}, $self->{label})
	. "\n";
    } else {
	return join( " ",
            "stats:",      $self->{level}, $self->{size}, $self->{csize},
            int($self->{secs}), $self->{date})
	. "\n";
    }
}

1;
