#!@PERL@
#

use lib '@amperldir@';
use strict;
use warnings;

use Time::Local;
use Text::ParseWords;
use Amanda::Util qw( :constants match_labelstr );;
use Amanda::Process;
use Amanda::Status;
use Amanda::Config qw( :init :getconf config_dir_relative );
use Amanda::Debug qw( :logging );
use Getopt::Long;

delete @ENV{'IFS', 'CDPATH', 'ENV', 'BASH_ENV', 'PATH'};
$ENV{'PATH'} = "/bin:/usr/bin:/usr/sbin:/sbin";       # force known path

my $confdir="@CONFIG_DIR@";
my $prefix='@prefix@';
   $prefix=$prefix;		# avoid warnings about possible typo
my $exec_prefix="@exec_prefix@";
   $exec_prefix=$exec_prefix;	# ditto
my $sbindir="@sbindir@";

my $Amanda_process = Amanda::Process->new(0);
$Amanda_process->load_ps_table();

my $STATUS_STRANGE =  2;
my $STATUS_FAILED  =  4;
my $STATUS_MISSING =  8;
my $STATUS_TAPE    = 16;
my $exit_status    =  0;

my $opt_detail;
my $opt_summary;
my $opt_taped;
my $opt_stats;
my $opt_config;
my $opt_file;
my $opt_locale_independent_date_format = 0;

sub usage() {
	print "amstatus [--file amdump_file]\n";
	print "         [--[no]detail] [--[no]summary] [--[no]taped] [--[no]stats]\n";
	print "         [--[no]locale-independent-date-format]\n";
	print "         [--config] <config>\n";
	exit 0;
}

my $pwd = `pwd`;
chomp $pwd;

Amanda::Util::setup_application("amstatus", "server", $CONTEXT_CMDLINE, "amanda", "amanda");

my $config_overrides = new_config_overrides($#ARGV+1);

debug("Arguments: " . join(' ', @ARGV));

Getopt::Long::Configure(qw{ bundling });
GetOptions(
    'detail!'                         => \$opt_detail,
    'summary!'                        => \$opt_summary,
    'taped!'                          => \$opt_taped,
    'stats|statistics!'               => \$opt_stats,
#    'dumping|d!'                      => \$opt_dumping,
#    'waitdumping|wdumping!'           => \$opt_waitdumping,
#    'waittaper|wtaper!'               => \$opt_waittaper,
#    'dumpingtape|dtape!'              => \$opt_dumpingtape,
#    'writingtape|wtape!'              => \$opt_writingtape,
#    'finished!'                       => \$opt_finished,
#    'failed|error!'                   => \$opt_failed,
#    'estimate!'                       => \$opt_estimate,
#    'gestimate|gettingestimate!'      => \$opt_gestimate,
    'config|c:s'                      => \$opt_config,
    'file:s'                          => \$opt_file,
    'locale-independent-date-format!' => \$opt_locale_independent_date_format,
    'o=s'  => sub { add_config_override_opt($config_overrides, $_[1]); },
    ) or usage();


my $conf;
if( defined $opt_config ) {
	$conf = $opt_config;
}
else {
	if($#ARGV == 0 ) {
		$conf=$ARGV[0];
	}
	else {
		&usage();
	}
}

set_config_overrides($config_overrides);
config_init_with_global($CONFIG_INIT_EXPLICIT_NAME, $conf);
my ($cfgerr_level, @cfgerr_errors) = config_errors();
if ($cfgerr_level >= $CFGERR_WARNINGS) {
    config_print_errors();
    if ($cfgerr_level >= $CFGERR_ERRORS) {
        print STDERR "errors processing config file";
        exit 1;
    }
}

#untaint user input $ARGV[0]

if ($conf =~ /^([\w.-]+)$/) {          # $1 is untainted
   $conf = $1;
} else {
    die "filename '$conf' has invalid characters.\n";
}

if ( ! -e "$confdir/$conf" ) {
    print "Configuration directory '$confdir/$conf' doesn't exist\n";
    exit 1;
}
if ( ! -d "$confdir/$conf" ) {
    print "Configuration directory '$confdir/$conf' is not a directory\n";
    exit 1;
 }


my $logdir = config_dir_relative(getconf($CNF_LOGDIR));
chomp $logdir;
my $errfile="$logdir/amdump";

my $nb_options = defined($opt_detail) +
		 defined($opt_summary) +
		 defined($opt_stats);
my $set_options = (defined($opt_detail) ? $opt_detail : 0 ) +
		  (defined($opt_summary) ? $opt_summary : 0 )  +
		  (defined($opt_stats) ? $opt_stats : 0 );

Amanda::Util::finish_setup($RUNNING_AS_DUMPUSER);

if ($nb_options == 0) {
	$opt_detail      = 1;
	$opt_summary     = 1;
	$opt_taped       = 1 if !defined $opt_taped;
	$opt_stats       = 1;
} elsif ($set_options > 0) {
	$opt_detail  = 0 if !defined $opt_detail;
	$opt_summary = 0 if !defined $opt_summary;
	$opt_taped   = $opt_summary if !defined $opt_taped;
	$opt_stats   = 0 if !defined $opt_stats;
} else {
	$opt_detail  = 1 if !defined $opt_detail;
	$opt_summary = 1 if !defined $opt_summary;
	$opt_taped   = $opt_summary if !defined $opt_taped;
	$opt_stats   = 1 if !defined $opt_stats;
}

my $unit = getconf($CNF_DISPLAYUNIT);
$unit =~ tr/A-Z/a-z/;
my $unitdivisor=1;
if($unit eq 'k') {
  $unitdivisor = 1*1024;
}
elsif($unit eq 'm') {
  $unitdivisor = 1024*1024;
}
elsif($unit eq 'g') {
  $unitdivisor = 1024*1024*1024;
}
elsif($unit eq 't') {
  $unitdivisor = 1024*1024*1024*1024;
}
else {
  $unit = 'k';
  $unitdivisor = 1024;
}

sub dn {
    my $number = shift;
    return int($number/$unitdivisor);
}

my $dead_run = 0;
if( defined $opt_file) {
	if( $opt_file =~ m,^/, ) {
		$errfile = $opt_file;
	} else {
		$errfile = "$pwd/$opt_file";
		$errfile = "$logdir/$opt_file" if ( ! (-f $errfile ));
	}
}
else {
	$errfile="$logdir/amflush" if(! (-f $errfile));
	if (! -f $errfile) {
		if (-f "$logdir/amflush.1" && -f "$logdir/amdump.1" &&
		    -M "$logdir/amflush.1"  < -M "$logdir/amdump.1") {
			$errfile="$logdir/amflush.1";
		} else {
			$errfile="$logdir/amdump.1";
		}
		$dead_run = 1;
	}
}

print "Using: $errfile\n";
debug("Using: $errfile");
my $status = Amanda::Status->new(filename => $errfile);
if ($status->isa("Amanda::Message")) {
    print $status, "\n";
    exit 1;
}
my $message = $status->current(user_msg => sub {});
if ($message->{'code'} != 1800000) {
    print $message, "\n";
    exit 1;
}
if ($opt_locale_independent_date_format) {
    print "From $status->{'starttime-locale-independent'}\n";
} else {
    print "From $status->{'datestr'}\n";
}
print "\n";

#print Data::Dumper::Dumper($status);

my $maxnamelength = 10;
my $maxlevellength = 1;
foreach my $host (keys %{$status->{'dles'}}) {
    foreach my $disk (keys %{$status->{'dles'}->{$host}}) {
	my $qdisk = Amanda::Util::quote_string($disk);
	if (length("$host:$qdisk") > $maxnamelength) {
	    $maxnamelength = length("$host:$qdisk");
	}
	foreach my $datestamp (keys %{$status->{'dles'}->{$host}->{$disk}}) {
	    my $dle = $status->{'dles'}->{$host}->{$disk}->{$datestamp};
	    if (length("$dle->{'level'}") > $maxlevellength) {
		$maxlevellength = length("$dle->{'level'}");
	    }
	}
    }
}

my $nb_storage = 0;
if (defined $status->{'storage'}) {
    $nb_storage = keys %{$status->{'storage'}};
}

if ($opt_detail) {
  foreach my $host (sort keys %{$status->{'dles'}}) {
    foreach my $disk (sort keys %{$status->{'dles'}->{$host}}) {
	foreach my $datestamp (sort keys %{$status->{'dles'}->{$host}->{$disk}}) {
	    my $dle = $status->{'dles'}->{$host}->{$disk}->{$datestamp};
	    my $taper_status;
	    if ($nb_storage == 1) {
		if (defined $dle->{'storage'}) {
		    my @storage = keys %{$dle->{'storage'}};
		    my $storage = $storage[0];
		    my $dlet = $dle->{'storage'}->{$storage};
		    $taper_status = $dlet->{'message'};
		    $taper_status .= ", taping delayed because of config: $dlet->{'error'}" if defined $dlet->{'tape_config'};
		}
	    }
	    my $qdisk = Amanda::Util::quote_string($disk);
	    printf "%-${maxnamelength}s $datestamp %-${maxlevellength}s ","$host:$qdisk", $dle->{'level'};
	    if (defined $dle->{'dsize'}) {
		printf "%9s$unit ", dn($dle->{'dsize'});
	    } elsif (defined $dle->{'esize'}) {
		printf "%9s$unit ", dn($dle->{'esize'});
	    } else {
		printf "%9s  ", "";
	    }
	    my $dump_status = $dle->{'message'};

	    if ($nb_storage == 0) {
		print $dump_status;
		if (defined $dle->{'wsize'} && defined $dle->{'esize'} && $dle->{'esize'} != 0) {
		    printf " (%s$unit done (%0.2f%%))", dn($dle->{'wsize'}),
			     100.0 * $dle->{'wsize'} / $dle->{'esize'};
		}
		if (defined $dle->{'dump_time'}) {
		    print " (",  $status->show_time($dle->{'dump_time'}), ")";
		}
	    } elsif ($nb_storage == 1) {
		if ($dump_status and $taper_status and $dump_status ne $taper_status) {
		    print "$dump_status, $taper_status";
		} elsif ($dump_status) {
		    print $dump_status;
		} else {
		    print $taper_status;
		}
		if ($taper_status) {
		    my @storage = keys %{$dle->{'storage'}};
		    my $storage = $storage[0];
		    my $dlet = $dle->{'storage'}->{$storage};
		    if (defined $dlet->{'wsize'} && defined $dle->{'dsize'} && $dle->{'dsize'} != 0) {
			printf " (%s$unit done (%0.2f%%))", dn($dlet->{'wsize'}),
				 100.0 * $dlet->{'wsize'} / $dle->{'dsize'};
		    } elsif (defined $dlet->{'wsize'} && defined $dle->{'esize'} && $dle->{'esize'} != 0) {
			printf " (%s$unit done (%0.2f%%))", dn($dlet->{'wsize'}),
				 100.0 * $dlet->{'wsize'} / $dle->{'esize'};
		    }
		    if (defined $dlet->{'taper_time'}) {
			print " (",  $status->show_time($dlet->{'taper_time'}), ")";
		    }
		} else {
		    if (defined $dle->{'wsize'} && defined $dle->{'esize'} && $dle->{'esize'} != 0) {
			printf " (%s$unit done (%0.2f%%))", dn($dle->{'wsize'}),
				 100.0 * $dle->{'wsize'} / $dle->{'esize'};
		    }
		    if (defined $dle->{'dump_time'}) {
			print " (",  $status->show_time($dle->{'dump_time'}), ")";
		    }
		}
	    } elsif (defined $dle->{'storage'}) {
		my $first = 0;
		my $dump_status_length = 0;
		for my $storage (sort keys %{$dle->{'storage'}}) {
		    my $dlet = $dle->{'storage'}->{$storage};
		    my $taper_status;
		    $taper_status = $dlet->{'message'};
		    $taper_status .= ", taping delayed because of config: $dlet->{'tape_config'}" if defined $dlet->{'tape_config'};
		    $taper_status .= ", tape error: $dlet->{'tape_error'}" if defined $dlet->{'tape_error'};
		    if ($first == 0) {
			if ($dump_status) {
			    my $time = "(" .  $status->show_time($dle->{'dump_time'}) . ")";

			    print "$dump_status $time, ";
			    $dump_status_length = length($dump_status) + length($time) + 3;

			}
			print "($storage) $taper_status";
		    } else {
			print "\n";
			printf "%s", ' ' x ($maxnamelength + 1 + 14 + 1 + $maxlevellength + 1 + 10 + 1 + $dump_status_length);
			print "($storage) $taper_status";
		    }
		    $first++;
		    if (defined $dlet->{'wsize'} && defined $dle->{'esize'} && $dle->{'esize'} != 0) {
			printf " (%s$unit done (%0.2f%%))", dn($dlet->{'wsize'}),
				 100.0 * $dlet->{'wsize'} / $dle->{'esize'};
		    }
		    if (defined $dlet->{'taper_time'}) {
			print " (",  $status->show_time($dlet->{'taper_time'}), ")";
		    }
		}
	    } else {
		print $dump_status;
		if (defined $dle->{'wsize'} && defined $dle->{'esize'} && $dle->{'esize'} != 0) {
		    printf " (%s$unit done (%0.2f%%))", dn($dle->{'wsize'}),
				 100.0 * $dle->{'wsize'} / $dle->{'esize'};
		}
		if (defined $dle->{'dump_time'}) {
		    print " (",  $status->show_time($dle->{'dump_time'}), ")";
		}
	    }
	    print "\n";
	}
    }
  }
  print "\n";
}

if ($opt_summary) {
    printf "%-16s %4s %10s %10s\n", "SUMMARY", "dle", "real", "estimated";
    printf "%-16s %4s %10s %10s\n", "", "", "size", "size";
    printf "%-16s %4s %10s %10s\n", "----------------", "----", "---------", "---------";
    summary($status, 'disk', 'disk', 0, 0, 0, 0);
    summary($status, 'estimated', 'estimated', 0, 1, 0, 0);
    summary_storage($status, 'flush', 'flush', 1, 0, 0, 0, 1);
    summary($status, 'dump_failed', 'dump failed', 1, 1, 1, 1);
    summary($status, 'wait_for_dumping', 'wait for dumping', 0, 1, 0, 1);
    summary($status, 'dumping_to_tape', 'dumping to tape', 1, 1, 1, 1);
    summary($status, 'dumping', 'dumping', 1, 1, 1, 1);
    summary($status, 'dumped', 'dumped', 1, 1, 1, 1);
    summary_storage($status, 'wait_for_writing', 'wait for writing', 1, 1, 1, 1, 1);
    summary_storage($status, 'wait_to_flush'   , 'wait to flush'   , 1, 1, 1, 1, 1);
    summary_storage($status, 'wait_to_vault'   , 'wait to vault'   , 1, 1, 1, 1, 0);
    summary_storage($status, 'writing_to_tape' , 'writing to tape' , 1, 1, 1, 1, 1);
    summary_storage($status, 'dumping_to_tape' , 'dumping to tape' , 1, 1, 1, 1, 1);
    summary_storage($status, 'failed_to_tape'  , 'failed to tape'  , 1, 1, 1, 1, 1);
    summary_storage($status, 'vaulting'        , 'vaulting'        , 1, 1, 1, 1, 0);
    summary_storage($status, 'taped'           , 'taped'           , 1, 1, 1, 1, 1);

    print "\n";
    if ($status->{'idle_dumpers'} == 0) {
	printf "all dumpers active\n";
    } else {
	my $c1 = ($status->{'idle_dumpers'} == 1) ? "" : "s";
	my $c2 = ($status->{'idle_dumpers'} < 10) ? " " : "";
	my $c3 = ($status->{'idle_dumpers'} == 1) ? " " : "";
	printf "%d dumper%s idle%s %s: %s\n", $status->{'idle_dumpers'},
					      $c1, $c2, $c3,
					      $status->{'status_driver'};
    }

    if (defined $status->{'storage'}) {
	for my $storage (sort keys %{$status->{'storage'}}) {
	    next if !$storage;
	    my $taper = $status->{'storage'}->{$storage}->{'taper'};
	    next if !$taper;

	    if ($status->{'taper'}->{$taper}->{'error'}) {
		printf "%-11s qlen: %d   (%s)\n", "$storage",
					   $status->{'qlen'}->{'tapeq'}->{$taper} || 0,
					   $status->{'taper'}->{$taper}->{'error'};
		next;
	    }
	    printf "%-11s qlen: %d\n", "$storage",
				       $status->{'qlen'}->{'tapeq'}->{$taper} || 0;

	    if (defined $status->{'taper'}->{$taper}->{'worker'}) {
		my @worker_status;
		for my $worker (sort keys %{$status->{'taper'}->{$taper}->{'worker'}}) {
		    my $wworker = $status->{'taper'}->{$taper}->{'worker'}->{$worker};
		    my $wstatus = $wworker->{'status'};
		    my $wmessage = $wworker->{'message'};
		    my $whost = $wworker->{'host'};
		    my $wdisk = $wworker->{'disk'};
		    $worker =~ /worker\d*-(\d*)/;
		    my $wname = $1;
		    printf "%16s:", $wname;
		    if (defined ($wmessage)) {
			if (defined $whost and defined $wdisk) {
			    print " $wmessage ($whost:$wdisk)\n";
			} else {
			    print " $wmessage\n";
			}
		    } else {
			if (defined $whost and defined $wdisk) {
			    print " ($whost:$wdisk)\n";
			} else {
			    print "\n";
			}
		    }
		}
	    } else {
		print "Idle";
	    }
	    print "\n";
	}
    }

    printf "%-16s: %d\n", "network free kps", $status->{'network_free_kps'};

    if (defined $status->{'holding_free_space'}) {
	my $hs;
	if ($status->{'holding_free_space'}) {
	    $hs = ($status->{'holding_free_space'} * 1.0 / $status->{'holding_free_space'}) *100;
	} else {
	    $hs = 0.0;
	}
	printf "%-16s: %s$unit (%0.2f%%)\n", "holding space", dn($status->{'holding_free_space'}), $hs;
    }
}

my $len_storage = 0;
if (defined $status->{'taper'}) {
    foreach my $taper (keys %{$status->{'taper'}}) {
	my $len = length($status->{'taper'}->{$taper}->{'storage'});
	if ($len > $len_storage) {
	    $len_storage = $len;
	}
    }
}

my $r;
if ($opt_stats) {
    if (defined $status->{'current_time'} and
	$status->{'current_time'} != $status->{'start_time'}) {
	my $total_time = $status->{'current_time'} - $status->{'start_time'};
	foreach my $key (sort byprocess keys %{$status->{'busy'}}) {
	    my $name = $key;
	    if ($status->{'busy'}->{$key}->{'type'} eq "taper") {
		$name = $status->{'busy'}->{$key}->{'storage'};
	    }
	    $name = sprintf "%*s", $len_storage, $name;
	    printf "%-16s: %8s  (%6.2f%%)\n",
		   "$name busy", &busytime($status->{'busy'}->{$key}->{'time'}),
		   $status->{'busy'}->{$key}->{'percent'};
	}

	if (defined $status->{'dumpers_actives'}) {
	    for (my $d = 0; $d < @{$status->{'dumpers_actives'}}; $d++) {
		my $l = sprintf "%2d dumper%s busy%s : %8s  (%6.2f%%)", $d,
			($d == 1) ? "" : "s",
			($d == 1) ? " " : "",
			&busytime($status->{'busy_dumper'}->{$d}->{'time'}),
			$status->{'busy_dumper'}->{$d}->{'percent'};
		print "$l";
		my $s1 = "";
		my $s2 = " " x length($l);

		if (defined $status->{'busy_dumper'}->{$d}->{'status'}) {
		    foreach my $key (sort keys %{$status->{'busy_dumper'}->{$d}->{'status'}}) {
			printf "%s%20s: %8s  (%6.2f%%)\n",
			    $s1,
			    $key,
			    &busytime($status->{'busy_dumper'}->{$d}->{'status'}->{$key}->{'time'}),
			    $status->{'busy_dumper'}->{$d}->{'status'}->{$key}->{'percent'};
			$s1 = $s2;
		    }
		}
		if ($s1 eq "") {
		    print "\n";
		}
	    }
	}
    }
}

exit $status->{'exit_status'};

sub busytime() {
    my $busy = shift;
    my $oneday = 24*60*60;
    my $result;

    if ($busy > $oneday) {
	my $days = int($busy/$oneday);
	$result = sprintf "%d+", $busy/$oneday;
	$busy -= $days*$oneday;
    } else {
	$result = "";
    }
    my $hours = int($busy / (60*60));
    $busy -= $hours * 60 * 60;
    my $minutes = int($busy/60);
    $busy -= $minutes * 60;
    my $seconds = $busy;
    $result .= sprintf("%2d:%02d:%02d", $hours, $minutes, $seconds);

    return $result;
}

sub byprocess() {
    my(@tmp_a) = split(/(\d*)$/, $a, 2);
    my(@tmp_b) = split(/(\d*)$/, $b, 2);
    return ($tmp_a[0] cmp $tmp_b[0]) || ($tmp_a[1] <=> $tmp_b[1]);
}


#sub valuesort() {
#    $r->{$b} <=> $r->{$a};
#}

sub summary {
    my $status = shift;
    my $key = shift;
    my $name = shift;
    my $print_rsize = defined $status->{'stat'}->{$key}->{'real_size'};
    my $print_esize = defined $status->{'stat'}->{$key}->{'estimated_size'};
    my $print_rstat = defined $status->{'stat'}->{$key}->{'real_stat'};
    my $print_estat = defined $status->{'stat'}->{$key}->{'estimated_stat'};

    my $nb = $status->{'stat'}->{$key}->{'nb'};
    my $rsize = "";
       $rsize = sprintf "%8s$unit", dn($status->{'stat'}->{$key}->{'real_size'}) if defined $status->{'stat'}->{$key}->{'real_size'};
    my $esize = "";
       $esize = sprintf "%8s$unit", dn($status->{'stat'}->{$key}->{'estimated_size'}) if defined $status->{'stat'}->{$key}->{'estimated_size'};

    my $rstat = "";
       $rstat = sprintf "(%6.2f%%)", $status->{'stat'}->{$key}->{'real_stat'} if defined $status->{'stat'}->{$key}->{'real_stat'};
    my $estat = "";
       $estat = sprintf "(%6.2f%%)", $status->{'stat'}->{$key}->{'estimated_stat'} if defined $status->{'stat'}->{$key}->{'estimated_stat'};

    my $line = sprintf "%-16s:%4d  %9s  %9s %9s %9s",
		$status->{'stat'}->{$key}->{'name'},
		$status->{'stat'}->{$key}->{'nb'},
		$rsize, $esize, $rstat, $estat;
    $line =~ s/ *$//g; #remove trailing space
    print "$line\n";
}

sub summary_storage {
    my $status = shift;
    my $key = shift;
    my $name = shift;
    my $print_rsize = shift;
    my $print_esize = shift;
    my $print_rstat = shift;
    my $print_estat = shift;
    my $print_if_empty = shift;

    if (!$status->{'stat'}->{$key}->{'storage'} ||
	keys %{$status->{'stat'}->{$key}->{'storage'}} == 0) {
	if ($print_if_empty) {
	    printf "$name\n";
	}
	return;
    }
    if ($nb_storage > 1) {
	printf "$name\n";
    };

    for my $storage (sort keys %{$status->{'stat'}->{$key}->{'storage'}}) {
	if ($nb_storage > 1) {
	    $name = sprintf "%-16s", "  $storage";
	}
	my $nb = $status->{'stat'}->{$key}->{'storage'}->{$storage}->{'nb'};
	my $rsize = "";
	$rsize = sprintf "%8s$unit", dn($status->{'stat'}->{$key}->{'storage'}->{$storage}->{'real_size'}) if defined $status->{'stat'}->{$key}->{'storage'}->{$storage}->{'real_size'};
	my $esize = "";
	$esize = sprintf "%8s$unit", dn($status->{'stat'}->{$key}->{'storage'}->{$storage}->{'estimated_size'}) if defined $status->{'stat'}->{$key}->{'storage'}->{$storage}->{'estimated_size'};

	my $rstat = "";
	    $rstat = sprintf "(%6.2f%%)", $status->{'stat'}->{$key}->{'storage'}->{$storage}->{'real_stat'} if defined $status->{'stat'}->{$key}->{'storage'}->{$storage}->{'real_stat'};
	my $estat = "";
	    $estat = sprintf "(%6.2f%%)", $status->{'stat'}->{$key}->{'storage'}->{$storage}->{'estimated_stat'} if defined $status->{'stat'}->{$key}->{'storage'}->{$storage}->{'estimated_stat'};

	my $line = sprintf "%-16s:%4d  %9s  %9s %9s %9s",
			$name,
			$nb,
			$rsize, $esize, $rstat, $estat;
	$line =~ s/ *$//g; #remove trailing space
	print "$line\n";

	if ($key eq 'taped' && $opt_taped) {
	    my $taper = $status->{'storage'}->{$storage}->{'taper'};
	    summary_taped($status, $taper);
	}
    }
}

sub summary_taped {
    my $status = shift;
    my $taper = shift;

    my $i = 0;
    while ($i < $status->{'taper'}->{$taper}->{'nb_tape'}) {
	my $nb = $status->{'taper'}->{$taper}->{'stat'}[$i]->{'nb_dle'};
	my $real_size = $status->{'taper'}->{$taper}->{'stat'}[$i]->{'size'};
	my $estimated_size = $status->{'taper'}->{$taper}->{'stat'}[$i]->{'esize'};
	my $percent = $status->{'taper'}->{$taper}->{'stat'}[$i]->{'percent'};
	my $label = $status->{'taper'}->{$taper}->{'stat'}[$i]->{'label'};
	my $nb_part = $status->{'taper'}->{$taper}->{'stat'}[$i]->{'nb_part'};
	my $tape = "tape " . ($i+1);
	printf "    %-12s:%4d %9s$unit %9s$unit (%6.2f%%) %s (%d parts)\n", $tape, $nb, dn($real_size), dn($estimated_size), $percent, $label, $nb_part;
	$i++;
    }
}
