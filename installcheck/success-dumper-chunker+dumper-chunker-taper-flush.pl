# Copyright (c) 2014-2016 Carbonite, Inc.  All Rights Reserved.
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

use Test::More;
use File::Path;
use strict;
use warnings;

use lib '@amperldir@';
use Installcheck;
use Installcheck::Dumpcache;
use Installcheck::Config;
use Installcheck::Run qw(run run_err $diskname amdump_diag check_amreport check_amstatus);
use Installcheck::Catalogs;
use Amanda::Paths;
use Amanda::Device qw( :constants );
use Amanda::Debug;
use Amanda::MainLoop;
use Amanda::Config qw( :init :getconf config_dir_relative );
use Amanda::Changer;

eval 'use Installcheck::Rest;';
if ($@) {
    plan skip_all => "Can't load Installcheck::Rest: $@";
    exit 1;
}

eval "require Time::HiRes;";

# set up debugging so debug output doesn't interfere with test results
Amanda::Debug::dbopen("installcheck");
Installcheck::log_test_output();

# and disable Debug's die() and warn() overrides
Amanda::Debug::disable_die_override();

my $rest = Installcheck::Rest->new();
if ($rest->{'error'}) {
   plan skip_all => "Can't start JSON Rest server: $rest->{'error'}: see " . Amanda::Debug::dbfn();
   exit 1;
}
plan tests => 96;

my $reply;

my $config_dir = $Amanda::Paths::CONFIG_DIR;
my $amperldir = $Amanda::Paths::amperldir;
my $testconf;
my $diskfile;
my $infodir;
my $timestamp;
my $tracefile;
my $logfile;
my $hostname = `hostname`;
chomp $hostname;

config_init($CONFIG_INIT_EXPLICIT_NAME, "TESTCONF");
$diskfile = Amanda::Config::config_dir_relative(getconf($CNF_DISKFILE));
$infodir = getconf($CNF_INFOFILE);


# dumper-chunker-success
$testconf = Installcheck::Run::setup();
$testconf->add_param('autolabel', '"TESTCONF%%" empty volume_error');
$testconf->add_param('columnspec', '"Dumprate=1:-8:1,TapeRate=1:-8:1"');
$testconf->add_param('reserve', '0');
$testconf->add_param('autoflush', 'yes');
$testconf->add_param('runtapes', '2');
$testconf->add_param('max-dle-by-volume', '1');
$testconf->add_param('report-use-media', 'yes');
$testconf->add_dle(<<EODLE);
localhost diskname2 $diskname {
    installcheck-test
    program "APPLICATION"
    application {
        plugin "amrandom"
        property "SIZE" "1075200"
        property "SIZE-LEVEL-1" "10240"
    }
}
EODLE
$testconf->write();

config_init($CONFIG_INIT_EXPLICIT_NAME, "TESTCONF");
$diskfile = Amanda::Config::config_dir_relative(getconf($CNF_DISKFILE));
$infodir = getconf($CNF_INFOFILE);

$reply = $rest->post("http://localhost:5001/amanda/v1.0/configs/TESTCONF/runs/amdump?no_taper=1", "");
foreach my $message (@{$reply->{'body'}}) {
    if (defined $message and defined $message->{'code'}) {
        if ($message->{'code'} == 2000003) {
            $timestamp = $message->{'timestamp'};
        }
        if ($message->{'code'} == 2000001) {
            $tracefile = $message->{'tracefile'};
        }
        if ($message->{'code'} == 2000000) {
            $logfile = $message->{'logfile'};
        }
    }
}

#wait until it is done
do {
    Time::HiRes::sleep(0.5);
    $reply = $rest->get("http://localhost:5001/amanda/v1.0/configs/TESTCONF/runs");
    } while ($reply->{'body'}[0]->{'code'} == 2000004 and
             $reply->{'body'}[0]->{'status'} ne 'done');

# get REST report
$reply = $rest->get("http://localhost:5001/amanda/v1.0/configs/TESTCONF/report?logfile=$logfile");
is($reply->{'body'}->[0]->{'severity'}, 'success', 'severity is success');
is($reply->{'body'}->[0]->{'code'}, '1900001', 'code is 1900001');
is($reply->{'body'}->[0]->{'report'}->{'head'}->{'hostname'}, $hostname , 'hostname is correct');
is($reply->{'body'}->[0]->{'report'}->{'head'}->{'exit_status'}, '0' , 'exit_status is correct');
is($reply->{'body'}->[0]->{'report'}->{'head'}->{'status'}, 'done' , 'status is correct');
is($reply->{'body'}->[0]->{'report'}->{'head'}->{'org'}, 'DailySet1' , 'org is correct');
is($reply->{'body'}->[0]->{'report'}->{'head'}->{'config_name'}, 'TESTCONF' , 'config_name is correct');
is($reply->{'body'}->[0]->{'report'}->{'head'}->{'timestamp'}, $timestamp , 'timestamp is correct');
is($reply->{'body'}->[0]->{'report'}->{'notes'}->[0], '  planner: tapecycle (2) <= runspercycle (10)', 'notes[0] is correct');
is($reply->{'body'}->[0]->{'report'}->{'notes'}->[1], '  planner: Adding new disk localhost:diskname2.' , 'notes[1] is correct');
ok(!exists $reply->{'body'}->[0]->{'report'}->{'notes'}->[2], 'no notes[2]');
ok(!exists $reply->{'body'}->[0]->{'report'}->{'failure_summary'}, 'no failure_summary');
ok(!exists $reply->{'body'}->[0]->{'report'}->{'usage_by_tape'}->[0], 'no usgae_by_tape');
ok(!exists $reply->{'body'}->[0]->{'report'}->{'tapeinfo'}->{'storage'}->{'TESTCONF'}->{'use'}, 'use is not defined');
is_deeply($reply->{'body'}->[0]->{'report'}->{'statistic'}->{'tape_size'}, { 'full' => '0',
									     'total' => '0',
									     'incr' => '0' }, 'tape_size is correct');
is_deeply($reply->{'body'}->[0]->{'report'}->{'statistic'}->{'parts_taped'}, { 'full' => '0',
									       'total' => '0',
									       'incr' => '0' }, 'parts_taped is correct');
is_deeply($reply->{'body'}->[0]->{'report'}->{'statistic'}->{'dles_taped'}, { 'full' => '0',
									      'total' => '0',
									      'incr' => '0' }, 'dles_taped is correct');
is_deeply($reply->{'body'}->[0]->{'report'}->{'statistic'}->{'dles_dumped'}, { 'full' => '1',
									       'total' => '1',
									       'incr' => '0' }, 'dles_dumped is correct');
is_deeply($reply->{'body'}->[0]->{'report'}->{'statistic'}->{'original_size'}, { 'full' => '1050',
									         'total' => '1050',
									         'incr' => '0' }, 'original_size is correct');
is_deeply($reply->{'body'}->[0]->{'report'}->{'statistic'}->{'output_size'}, { 'full' => '1050',
									       'total' => '1050',
									       'incr' => '0' }, 'output_size is correct');
is($reply->{'body'}->[0]->{'report'}->{'statistic'}->{'dumpdisks'}, '', 'dumpdisks is correct');
is($reply->{'body'}->[0]->{'report'}->{'statistic'}->{'tapedisks'}, '', 'tapedisks is correct');
is($reply->{'body'}->[0]->{'report'}->{'statistic'}->{'tapeparts'}, '', 'tapeparts is correct');
is($reply->{'body'}->[0]->{'report'}->{'summary'}->[0]->{'backup_level'}, '0', 'backup_level is correct');
is($reply->{'body'}->[0]->{'report'}->{'summary'}->[0]->{'disk_name'}, 'diskname2', 'disk_name is correct');
is($reply->{'body'}->[0]->{'report'}->{'summary'}->[0]->{'hostname'}, 'localhost', 'hostname is correct');
is($reply->{'body'}->[0]->{'report'}->{'summary'}->[0]->{'dump_orig_kb'}, '1050', 'dump_orig_kb is correct');
is($reply->{'body'}->[0]->{'report'}->{'summary'}->[0]->{'dump_out_kb'}, '1050', 'dump_out_kb is correct');
is($reply->{'body'}->[0]->{'report'}->{'summary'}->[0]->{'dle_status'}, 'full', 'dle_status is correct');
ok(!exists $reply->{'body'}->[0]->{'report'}->{'summary'}->[1], 'Only one summary');

$reply = $rest->get("http://localhost:5001/amanda/v1.0/configs/TESTCONF/status?tracefile=$tracefile");
is($reply->{'body'}->[0]->{'severity'}, 'info', 'severity is info');
is($reply->{'body'}->[0]->{'code'}, '1800000', 'code is 1800000');
is($reply->{'body'}->[0]->{'status'}->{'dead_run'}, '1', 'dead_run is correct');
is($reply->{'body'}->[0]->{'status'}->{'exit_status'}, '0', 'exit_status is correct');
$reply->{'body'}->[0]->{'status'}->{'dles'}->{'localhost'}->{'diskname2'}->{$timestamp}->{'chunk_time'} = undef;
$reply->{'body'}->[0]->{'status'}->{'dles'}->{'localhost'}->{'diskname2'}->{$timestamp}->{'dump_time'} = undef;
is_deeply($reply->{'body'}->[0]->{'status'}->{'dles'},
    {
	'localhost' => {
		'diskname2' => {
			$timestamp => {
				#'taped' => '1',
				'retry' => '0',
				'size' => '1075200',
				'esize' => '1075200',
				'retry_level' => '-1',
				'message' => 'dump done',
				'chunk_time' => undef,
				'dsize' => '1075200',
				'status' => '20',
				'partial' => '0',
				'level' => '0',
				'dump_time' => undef,
				'holding_file' => "$Installcheck::TMP/holding/$timestamp/localhost.diskname2.0",
				'degr_level' => '-1',
				'flush' => '0',
				'will_retry' => '0'
			}
		}
	}
    },
    'dles is correct');

is($reply->{'body'}->[0]->{'status'}->{'taper'}, undef, ' no taper');

is($reply->{'body'}->[0]->{'status'}->{'storage'}, undef, 'storage do not exists') || diag("storage: " . Data::Dumper::Dumper($reply->{'body'}->[0]->{'status'}->{'storage'}));
is_deeply($reply->{'body'}->[0]->{'status'}->{'stat'},
    {
	'flush' => {
		'name' => 'flush'
	},
	'writing_to_tape' => {
		'name' => 'writing to tape'
	},
	'wait_for_dumping' => {
		'name' => 'wait for dumping',
		'real_size' => undef,
		'estimated_stat' => '0',
		'nb' => '0',
		'estimated_size' => '0'
	},
	'failed_to_tape' => {
		'name' => 'failed to tape'
	},
	'dumping_to_tape' => {
		'name' => 'dumping to tape',
		'estimated_stat' => '0',
		'real_size' => '0',
		'real_stat' => '0',
		'estimated_size' => '0',
		'nb' => '0'
	},
	'wait_for_writing' => {
		'name' => 'wait for writing'
	},
	'wait_to_flush' => {
		'name' => 'wait_to_flush'
	},
	'dump_failed' => {
		'name' => 'dump failed',
		'estimated_stat' => '0',
		'real_size' => undef,
		'nb' => '0',
		'estimated_size' => '0'
	},
	'estimated' => {
		'name' => 'estimated',
		'real_size' => undef,
		'estimated_size' => '1075200',
		'nb' => '1'
	},
	'taped' => {
		'name' => 'taped',
	},
	'dumped' => {
		'name' => 'dumped',
		'estimated_stat' => '100',
		'real_size' => '1075200',
		'nb' => '1',
		'real_stat' => '100',
		'estimated_size' => '1075200'
	},
	'disk' => {
		'name' => 'disk',
		'nb' => '1',
		'estimated_size' => undef,
		'real_size' => undef
	},
	'dumping' => {
		'name' => 'dumping',
		'nb' => '0',
		'real_stat' => '0',
		'estimated_size' => '0',
		'real_size' => '0',
		'estimated_stat' => '0'
	},
	'wait_to_vault' => {
		'name' => 'wait_to_vault'
	},
	'vaulting' => {
		'name' => 'vaulting'
	},
	'vaulted' => {
		'name' => 'vaulted'
	}
    },
    'stat is correct');

#amreport

my $report = <<'END_REPORT';
Hostname: localhost.localdomain
Org     : DailySet1
Config  : TESTCONF
Date    : June 22, 2016

There are 1050K of dumps left in the holding disk.
They will be flushed on the next run.


STATISTICS:
                          Total       Full      Incr.   Level:#
                        --------   --------   --------  --------
Estimate Time (hrs:min)     0:00
Run Time (hrs:min)          0:00
Dump Time (hrs:min)         0:00       0:00       0:00
Output Size (meg)            1.0        1.0        0.0
Original Size (meg)          1.0        1.0        0.0
Avg Compressed Size (%)    100.0      100.0        --
DLEs Dumped                    1          1          0
Avg Dump Rate (k/s)     999999.9   999999.9        --

Tape Time (hrs:min)         0:00       0:00       0:00
Tape Size (meg)              0.0        0.0        0.0
Tape Used (%)                0.0        0.0        0.0
DLEs Taped                     0          0          0
Parts Taped                    0          0          0
Avg Tp Write Rate (k/s)      --         --         --


NOTES:
  planner: tapecycle (2) <= runspercycle (10)
  planner: Adding new disk localhost:diskname2.


DUMP SUMMARY:
                                                    DUMPER STATS     TAPER STATS
HOSTNAME     DISK        L ORIG-KB  OUT-KB  COMP%  MMM:SS     KB/s MMM:SS     KB/s
-------------------------- ---------------------- ---------------- ---------------
localhost    diskname2   0    1050    1050    --     0:00 999999.9                

(brought to you by Amanda version 4.0.0alpha.git.00388ecf)
END_REPORT

check_amreport($report, $timestamp, "amreport first amdump");

#amstatus

my $status = <<"END_STATUS";
Using: /amanda/h1/etc/amanda/TESTCONF/log/amdump.1
From Wed Jun 22 08:26:30 EDT 2016

localhost:diskname2 $timestamp 0      1050k dump done (00:00:00)

SUMMARY           dle       real  estimated
                            size       size
---------------- ----  ---------  ---------
disk            :   1
estimated       :   1                 1050k
flush
dump failed     :   0                    0k           (  0.00%)
wait for dumping:   0                    0k           (  0.00%)
dumping to tape :   0         0k         0k (  0.00%) (  0.00%)
dumping         :   0         0k         0k (  0.00%) (  0.00%)
dumped          :   1      1050k      1050k (100.00%) (100.00%)
wait for writing
wait to flush
writing to tape
dumping to tape
failed to tape
taped

2 dumpers idle  : no-dumpers
network free kps: 80000
holding space   : 23k (100.00%)
chunker0 busy   : 00:00:00  ( 86.55%)
dumper0 busy    : 00:00:00  ( 12.11%)
 0 dumpers busy : 00:00:00  ( 99.55%)
 1 dumper busy  : 00:00:00  (  0.45%)
END_STATUS

check_amstatus($status, $tracefile, "amstatus first amdump");

# dumper-chunker-taper+flush

config_init($CONFIG_INIT_EXPLICIT_NAME, "TESTCONF");
$diskfile = Amanda::Config::config_dir_relative(getconf($CNF_DISKFILE));
$infodir = getconf($CNF_INFOFILE);

my $dump_timestamp = $timestamp;
$reply = $rest->post("http://localhost:5001/amanda/v1.0/configs/TESTCONF/runs/amdump","");
foreach my $message (@{$reply->{'body'}}) {
    #diag("message: " . Data::Dumper::Dumper($message));
    if (defined $message and defined $message->{'code'}) {
        if ($message->{'code'} == 2000003) {
            $timestamp = $message->{'timestamp'};
        }
        if ($message->{'code'} == 2000001) {
            $tracefile = $message->{'tracefile'};
        }
        if ($message->{'code'} == 2000000) {
            $logfile = $message->{'logfile'};
        }
    }
}
#wait until it is done
my $found = 0;
do {
    Time::HiRes::sleep(0.5);
    $reply = $rest->get("http://localhost:5001/amanda/v1.0/configs/TESTCONF/runs");
    foreach my $message (@{$reply->{'body'}}) {
	if ($message->{'logfile'} eq $logfile &&
	    $message->{'code'} == 2000004 &&
	    $message->{'status'} eq 'done') {
	    $found = 1;
	    last;
	}
    }
} while (!$found);

# get REST report
$reply = $rest->get("http://localhost:5001/amanda/v1.0/configs/TESTCONF/report?logfile=$logfile");
is($reply->{'body'}->[0]->{'severity'}, 'success', 'severity is success');
is($reply->{'body'}->[0]->{'code'}, '1900001', 'code is 1900001');
is($reply->{'body'}->[0]->{'report'}->{'head'}->{'hostname'}, $hostname , 'hostname is correct');
is($reply->{'body'}->[0]->{'report'}->{'head'}->{'exit_status'}, '0' , 'exit_status is correct');
is($reply->{'body'}->[0]->{'report'}->{'head'}->{'status'}, 'done' , 'status is correct');
is($reply->{'body'}->[0]->{'report'}->{'head'}->{'org'}, 'DailySet1' , 'org is correct');
is($reply->{'body'}->[0]->{'report'}->{'head'}->{'config_name'}, 'TESTCONF' , 'config_name is correct');
is($reply->{'body'}->[0]->{'report'}->{'head'}->{'timestamp'}, $timestamp , 'timestamp is correct');
is($reply->{'body'}->[0]->{'report'}->{'notes'}->[0], '  planner: tapecycle (2) <= runspercycle (10)', 'notes[0] is correct');
is($reply->{'body'}->[0]->{'report'}->{'notes'}->[1], '  taper: Slot 1 without label can be labeled' , 'notes[1] is correct');
is($reply->{'body'}->[0]->{'report'}->{'notes'}->[2], '  taper: tape TESTCONF01 kb 1050 fm 1 [OK]' , 'notes[2] is correct');
is($reply->{'body'}->[0]->{'report'}->{'notes'}->[3], '  taper: Slot 2 without label can be labeled' , 'notes[3] is correct');
is($reply->{'body'}->[0]->{'report'}->{'notes'}->[4], '  taper: tape TESTCONF02 kb 10 fm 1 [OK]' , 'notes[4] is correct');
ok(!exists $reply->{'body'}->[0]->{'report'}->{'notes'}->[5], 'no notes[5]');
is($reply->{'body'}->[0]->{'report'}->{'usage_by_tape'}->[0]->{'nb'}, '1' , 'one dle on tape 0');
is($reply->{'body'}->[0]->{'report'}->{'usage_by_tape'}->[0]->{'nc'}, '1' , 'one part on tape 0');
is($reply->{'body'}->[0]->{'report'}->{'usage_by_tape'}->[0]->{'tape_label'}, 'TESTCONF01' , 'label tape_label on tape 0');
is($reply->{'body'}->[0]->{'report'}->{'usage_by_tape'}->[0]->{'size'}, '1050' , 'size 1050  on tape 0');
is($reply->{'body'}->[0]->{'report'}->{'usage_by_tape'}->[1]->{'nb'}, '1' , 'one dle on tape 1');
is($reply->{'body'}->[0]->{'report'}->{'usage_by_tape'}->[1]->{'nc'}, '1' , 'one part on tape 1');
is($reply->{'body'}->[0]->{'report'}->{'usage_by_tape'}->[1]->{'tape_label'}, 'TESTCONF02' , 'label tape_label on tape 1');
is($reply->{'body'}->[0]->{'report'}->{'usage_by_tape'}->[1]->{'size'}, '10' , 'size 10  on tape 1');
ok(!exists $reply->{'body'}->[0]->{'report'}->{'usage_by_tape'}->[2], 'only 2 tape');
is_deeply($reply->{'body'}->[0]->{'report'}->{'tapeinfo'}->{'storage'}->{'TESTCONF'}->{'use'}, [ 'TESTCONF01', 'TESTCONF02' ], 'use TESTCONF');
is_deeply($reply->{'body'}->[0]->{'report'}->{'statistic'}->{'tape_size'}, { 'full' => '1050',
									     'total' => '1060',
									     'incr' => '10' }, 'tape_size is correct');
is_deeply($reply->{'body'}->[0]->{'report'}->{'statistic'}->{'parts_taped'}, { 'full' => '1',
									       'total' => '2',
									       'incr' => '1' }, 'parts_taped is correct');
is_deeply($reply->{'body'}->[0]->{'report'}->{'statistic'}->{'dles_taped'}, { 'full' => '1',
									      'total' => '2',
									      'incr' => '1' }, 'dles_taped is correct');
is_deeply($reply->{'body'}->[0]->{'report'}->{'statistic'}->{'dles_dumped'}, { 'full' => '0',
									       'total' => '1',
									       'incr' => '1' }, 'dles_dumped is correct');
is_deeply($reply->{'body'}->[0]->{'report'}->{'statistic'}->{'original_size'}, { 'full' => '0',
									         'total' => '10',
									         'incr' => '10' }, 'original_size is correct');
is_deeply($reply->{'body'}->[0]->{'report'}->{'statistic'}->{'output_size'}, { 'full' => '0',
									       'total' => '10',
									       'incr' => '10' }, 'output_size is correct');
is($reply->{'body'}->[0]->{'report'}->{'statistic'}->{'dumpdisks'}, '1:1', 'dumpdisks is correct');
is($reply->{'body'}->[0]->{'report'}->{'statistic'}->{'tapedisks'}, '1:1', 'tapedisks is correct');
is($reply->{'body'}->[0]->{'report'}->{'statistic'}->{'tapeparts'}, '1:1', 'tapeparts is correct');
is($reply->{'body'}->[0]->{'report'}->{'summary'}->[0]->{'backup_level'}, '0', 'backup_level is correct');
is($reply->{'body'}->[0]->{'report'}->{'summary'}->[0]->{'disk_name'}, 'diskname2', 'disk_name is correct');
is($reply->{'body'}->[0]->{'report'}->{'summary'}->[0]->{'hostname'}, 'localhost', 'hostname is correct');
is($reply->{'body'}->[0]->{'report'}->{'summary'}->[0]->{'dump_orig_kb'}, '1050', 'dump_orig_kb is correct');
is($reply->{'body'}->[0]->{'report'}->{'summary'}->[0]->{'dump_out_kb'}, '1050', 'dump_out_kb is correct');
is($reply->{'body'}->[0]->{'report'}->{'summary'}->[0]->{'dle_status'}, 'nodump-FLUSH', 'dle_status is correct');
is($reply->{'body'}->[0]->{'report'}->{'summary'}->[1]->{'backup_level'}, '1', 'backup_level is correct');
is($reply->{'body'}->[0]->{'report'}->{'summary'}->[1]->{'disk_name'}, 'diskname2', 'disk_name is correct');
is($reply->{'body'}->[0]->{'report'}->{'summary'}->[1]->{'hostname'}, 'localhost', 'hostname is correct');
is($reply->{'body'}->[0]->{'report'}->{'summary'}->[1]->{'dump_orig_kb'}, '10', 'dump_orig_kb is correct');
is($reply->{'body'}->[0]->{'report'}->{'summary'}->[1]->{'dump_out_kb'}, '10', 'dump_out_kb is correct');
is($reply->{'body'}->[0]->{'report'}->{'summary'}->[1]->{'dle_status'}, 'full', 'dle_status is correct');
ok(!exists $reply->{'body'}->[0]->{'report'}->{'summary'}->[2], 'Only one summary');

$reply = $rest->get("http://localhost:5001/amanda/v1.0/configs/TESTCONF/status?tracefile=$tracefile");
is($reply->{'body'}->[0]->{'severity'}, 'info', 'severity is info');
is($reply->{'body'}->[0]->{'code'}, '1800000', 'code is 1800000');
is($reply->{'body'}->[0]->{'status'}->{'dead_run'}, '1', 'dead_run is correct');
is($reply->{'body'}->[0]->{'status'}->{'exit_status'}, '0', 'exit_status is correct');
$reply->{'body'}->[0]->{'status'}->{'dles'}->{'localhost'}->{'diskname2'}->{$dump_timestamp}->{'storage'}->{'TESTCONF'}->{'taper_time'} = undef;
$reply->{'body'}->[0]->{'status'}->{'dles'}->{'localhost'}->{'diskname2'}->{$timestamp}->{'storage'}->{'TESTCONF'}->{'taper_time'} = undef;
$reply->{'body'}->[0]->{'status'}->{'dles'}->{'localhost'}->{'diskname2'}->{$timestamp}->{'chunk_time'} = undef;
$reply->{'body'}->[0]->{'status'}->{'dles'}->{'localhost'}->{'diskname2'}->{$timestamp}->{'dump_time'} = undef;
is_deeply($reply->{'body'}->[0]->{'status'}->{'dles'},
    {
	'localhost' => {
		'diskname2' => {
			$dump_timestamp => {
				#'taped' => '1',
				'size' => '1075200',
				'esize' => '0',
				#'message' => '',
				'dsize' => '1075200',
				'status' => '0',
				#'partial' => '0',
				'level' => '0',
				'holding_file' => "$Installcheck::TMP/holding/$dump_timestamp/localhost.diskname2.0",
				'storage' => {
					'TESTCONF' => {
						'will_retry' => '0',
						'status' => '23',
						'dsize' => '1075200',
						'taper_time' => undef,
						'taped_size' => '1075200',
						'message' => 'flushed',
						'size' => '1075200',
						'partial' => '0',
						'flushing' => 1
					}
				},
				'flush' => '0'
			},
			$timestamp => {
				'will_retry' => '0',
				'taped' => '1',
				'size' => '10240',
				'esize' => '32768',
				'retry_level' => '-1',
				'message' => 'dump done',
				'dsize' => '10240',
				'status' => '20',
				'partial' => '0',
				'retry' => '0',
				'level' => '1',
				'dump_time' => undef,
				'chunk_time' => undef,
				'degr_level' => '-1',
				'holding_file' => "$Installcheck::TMP/holding/$timestamp/localhost.diskname2.1",
				'storage' => {
					'TESTCONF' => {
						'will_retry' => '0',
						'status' => '22',
						'dsize' => '10240',
						'taper_time' => undef,
						'taped_size' => '10240',
						'message' => 'written',
						'size' => '10240',
						'partial' => '0',
					}
				},
				'flush' => '0'
			}
		}
	}
    },
    'dles is correct') || diag("dles: ". Data::Dumper::Dumper($reply->{'body'}->[0]->{'status'}->{'dles'}));

is_deeply($reply->{'body'}->[0]->{'status'}->{'taper'},
    {
	'taper0' => {
		'worker' => {
			'worker0-0' => {
				'status' => '0',
				'no_tape' => '1',
			}
		},
		'tape_size' => '31457280',
		'storage' => 'TESTCONF',
		'nb_tape' => '2',
		'stat' => [
			{
				'size' => '1075200',
				'esize' => '1075200',
				'nb_dle' => '1',
				'nb_part' => '1',
				'label' => 'TESTCONF01',
				'percent' => '3.41796875'
			},
			{
				'size' => '10240',
				'esize' => '10240',
				'nb_dle' => '1',
				'nb_part' => '1',
				'label' => 'TESTCONF02',
				'percent' => '0.0325520833333333'
			}
		]
	}
    },
    'taper is correct') || diag("taper ". Data::Dumper::Dumper($reply->{'body'}->[0]->{'status'}->{'taper'}));

is($reply->{'body'}->[0]->{'status'}->{'storage'}->{'TESTCONF'}->{'taper'}, 'taper0', 'taper is correct');
is_deeply($reply->{'body'}->[0]->{'status'}->{'stat'},
    {
	'flush' => {
		'name' => 'flush',
		'storage' => {
			'TESTCONF' => {
				'estimated_size' => undef,
				'real_size' => '1075200',
				'nb' => '1'
			}
		}
	},
	'writing_to_tape' => {
		'name' => 'writing to tape'
	},
	'wait_for_dumping' => {
		'name' => 'wait for dumping',
		'real_size' => undef,
		'estimated_stat' => '0',
		'nb' => '0',
		'estimated_size' => '0'
	},
	'failed_to_tape' => {
		'name' => 'failed to tape'
	},
	'dumping_to_tape' => {
		'name' => 'dumping to tape',
		'estimated_stat' => '0',
		'real_size' => '0',
		'real_stat' => '0',
		'estimated_size' => '0',
		'nb' => '0'
	},
	'wait_for_writing' => {
		'name' => 'wait for writing'
	},
	'wait_to_flush' => {
		'name' => 'wait_to_flush'
	},
	'dump_failed' => {
		'name' => 'dump failed',
		'estimated_stat' => '0',
		'real_size' => undef,
		'nb' => '0',
		'estimated_size' => '0'
	},
	'estimated' => {
		'name' => 'estimated',
		'real_size' => undef,
		'estimated_size' => '32768',
		'nb' => '1'
	},
	'taped' => {
		'name' => 'taped',
		'estimated_size' => '32768',
		'storage' => {
			'TESTCONF' => {
				'estimated_stat' => '3312.5',
				'real_size' => '1085440',
				'nb' => '2',
				'real_stat' => '3312.5',
				'estimated_size' => '32768'
			}
		},
	},
	'dumped' => {
		'name' => 'dumped',
		'estimated_stat' => '31.25',
		'real_size' => '10240',
		'nb' => '1',
		'real_stat' => '31.25',
		'estimated_size' => '32768'
	},
	'disk' => {
		'name' => 'disk',
		'nb' => '1',
		'estimated_size' => undef,
		'real_size' => undef
	},
	'dumping' => {
		'name' => 'dumping',
		'nb' => '0',
		'real_stat' => '0',
		'estimated_size' => '0',
		'real_size' => '0',
		'estimated_stat' => '0'
	},
	'wait_to_vault' => {
		'name' => 'wait_to_vault'
	},
	'vaulting' => {
		'name' => 'vaulting'
	},
	'vaulted' => {
		'name' => 'vaulted'
	}
    },
    'stat is correct') || diag("stat ". Data::Dumper::Dumper($reply->{'body'}->[0]->{'status'}->{'stat'}));

# amreport

$report = <<'END_REPORT';
Hostname: localhost.localdomain
Org     : DailySet1
Config  : TESTCONF
Date    : June 22, 2016

These dumps were to tapes TESTCONF01, TESTCONF02.


STATISTICS:
                          Total       Full      Incr.   Level:#
                        --------   --------   --------  --------
Estimate Time (hrs:min)     0:00
Run Time (hrs:min)          0:00
Dump Time (hrs:min)         0:00       0:00       0:00
Output Size (meg)            0.0        0.0        0.0
Original Size (meg)          0.0        0.0        0.0
Avg Compressed Size (%)    100.0        --       100.0
DLEs Dumped                    1          0          1  1:1
Avg Dump Rate (k/s) 999999.9        -- 999999.9

Tape Time (hrs:min)         0:00       0:00       0:00
Tape Size (meg)              1.0        1.0        0.0
Tape Used (%)                3.5        3.4        0.1
DLEs Taped                     2          1          1  1:1
Parts Taped                    2          1          1  1:1
Avg Tp Write Rate (k/s) 999999.9 999999.9 999999.9


USAGE BY TAPE:
  Label                 Time         Size      %  DLEs Parts
  TESTCONF01            0:00        1050K    3.4     1     1
  TESTCONF02            0:00          10K    0.1     1     1


NOTES:
  planner: tapecycle (2) <= runspercycle (10)
  taper: Slot 1 without label can be labeled
  taper: tape TESTCONF01 kb 1050 fm 1 [OK]
  taper: Slot 2 without label can be labeled
  taper: tape TESTCONF02 kb 10 fm 1 [OK]


DUMP SUMMARY:
                                                    DUMPER STATS     TAPER STATS
HOSTNAME     DISK        L ORIG-KB  OUT-KB  COMP%  MMM:SS     KB/s MMM:SS     KB/s
-------------------------- ---------------------- ---------------- ---------------
localhost    diskname2   0    1050    1050    --       FLUSH         0:00 999999.9
localhost    diskname2   1      10      10    --     0:00 999999.9   0:00 999999.9

(brought to you by Amanda version 4.0.0alpha.git.00388ecf)
END_REPORT

check_amreport($report, $timestamp, "amreport second amdump");

# amstatus

$status = <<"END_STATUS";
Using: /amanda/h1/etc/amanda/TESTCONF/log/amdump.1
From Wed Jun 22 08:32:02 EDT 2016

localhost:diskname2 $dump_timestamp 0      1050k flushed (00:00:00)
localhost:diskname2 $timestamp 1        10k dump done, written (00:00:00)

SUMMARY           dle       real  estimated
                            size       size
---------------- ----  ---------  ---------
disk            :   1
estimated       :   1                   32k
flush           :   1      1050k
dump failed     :   0                    0k           (  0.00%)
wait for dumping:   0                    0k           (  0.00%)
dumping to tape :   0         0k         0k (  0.00%) (  0.00%)
dumping         :   0         0k         0k (  0.00%) (  0.00%)
dumped          :   1        10k        32k (  0.00%) (  0.00%)
wait for writing
wait to flush
writing to tape
dumping to tape
failed to tape
taped           :   2      1060k        32k (  0.00%) (  0.00%)
    tape 1      :   1      1050k      1050k (  3.42%) TESTCONF01 (1 parts)
    tape 2      :   1        10k        10k (  3.42%) TESTCONF02 (1 parts)

2 dumpers idle  : no-dumpers
TESTCONF    qlen: 0
               0:

network free kps: 80000
holding space   : 26k (100.00%)
chunker0 busy   : 00:00:00  ( 44.52%)
 dumper0 busy   : 00:00:00  (  5.94%)
TESTCONF busy   : 00:00:00  (  3.43%)
 0 dumpers busy : 00:00:00  (100.00%)
 1 dumper busy  : 00:00:00  (  0.00%)
END_STATUS

check_amstatus($status, $tracefile, "amstatus second amdump");

#diag("reply: " . Data::Dumper::Dumper($reply));
#$rest->stop();
#exit;

$rest->stop();

Installcheck::Run::cleanup();
