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
# Sunnyvale, CA 94086, USA, or: http://www.zmanda.com

use Test::More tests => 41;
use strict;
use warnings;

use lib '@amperldir@';
use File::Find;
use Amanda::Config qw( :init :getconf config_dir_relative );
use Amanda::Device qw( :constants );
use Amanda::Paths;
use Amanda::Tapelist;
use Amanda::Util;
use Installcheck::Config;
use Installcheck::Run qw(run run_err $diskname);
use Installcheck::Dumpcache;

Amanda::Debug::dbopen("installcheck");
Installcheck::log_test_output();

sub proc_diag {
    diag(join("\n", $?,
        'stdout:', $Installcheck::Run::stdout, '',
        'stderr:', $Installcheck::Run::stderr));
}

# note: assumes the config is already loaded and takes a config param
# to get as a directory and then count all the files in
sub dir_file_count {
    my $conf_param = shift @_;
    my $dir_name = getconf($conf_param);

    my $num_files = 0;
    my $opts = {
        'wanted' => sub {
            # ignore directories
            return if -d $File::Find::name;
            $num_files++;
        },
    };

    find($opts, $dir_name);
    $num_files;
}

my $dev;
my ($idx_count_pre, $idx_count_post);


## test config overrides
Installcheck::Dumpcache::load("basic");

config_init($CONFIG_INIT_EXPLICIT_NAME, 'TESTCONF');

cmp_ok(
    run(qw(amrmtape -o tapelist=/this/is/a/fake/tapelist TESTCONF TESTCONF01)),
    "==", 1, "config override run"
) or proc_diag();

cmp_ok(
    $Installcheck::Run::stdout, "=~",
    qr/label 'TESTCONF01' not found in tapelist file '\/this\/is\/a\/fake\/tapelist'/,
    "config overrides handled correctly"
) or proc_diag();

## test

Installcheck::Dumpcache::load("basic");

config_init($CONFIG_INIT_EXPLICIT_NAME, 'TESTCONF');
my ($tapelist, $message) = Amanda::Tapelist->new(config_dir_relative("tapelist"));
ok($tapelist->lookup_tapelabel('TESTCONF01'), "looked up tape after dump");

$idx_count_pre = dir_file_count($CNF_INDEXDIR);

ok(run('amrmtape', 'TESTCONF', 'TESTCONF01'), "amrmtape runs successfully")
    or proc_diag();

$idx_count_post = dir_file_count($CNF_INDEXDIR);
is($idx_count_post, $idx_count_pre, "number of index files before and after is the same");

$tapelist->reload();
ok(!$tapelist->lookup_tapelabel('TESTCONF01'),
     "should fail to look up tape that should has been removed");

$dev = Amanda::Device->new('file:' . Installcheck::Run::vtape_dir());

ok($dev->start($ACCESS_READ, undef, undef),
    "start device in read mode")
    or diag($dev->error_or_status());

ok($dev->finish(),
   "finish device after starting")
    or diag($dev->error_or_status());

# test --cleanup

Installcheck::Dumpcache::load("basic");
my $diskpath = Amanda::Util::sanitise_filename($Installcheck::Run::diskname);
system ("touch -mt 201401020304.05 " . getconf($CNF_INDEXDIR) . "/localhost/$diskpath/*");

$idx_count_pre = dir_file_count($CNF_INDEXDIR);

ok(run('amrmtape', '--cleanup', 'TESTCONF', 'TESTCONF01'),
    "amrmtape runs successfully with --cleanup")
     or proc_diag();

$idx_count_post = dir_file_count($CNF_INDEXDIR);
isnt($idx_count_post, $idx_count_pre, "number of index files before ($idx_count_pre) and after ($idx_count_post) is different");

$tapelist->reload();
ok(!$tapelist->lookup_tapelabel('TESTCONF01'),
     "succesfully looked up tape that should have been removed after --cleanup");

$dev = Amanda::Device->new('file:' . Installcheck::Run::vtape_dir());

ok($dev->start($ACCESS_READ, undef, undef),
    "start device in read mode")
    or diag($dev->error_or_status());

ok($dev->finish(),
   "finish device after starting")
    or diag($dev->error_or_status());

# test --erase

Installcheck::Dumpcache::load("basic");

$idx_count_pre = dir_file_count($CNF_INDEXDIR);

ok(run('amrmtape', '--erase', 'TESTCONF', 'TESTCONF01'),
    "amrmtape runs successfully with --erase")
    or proc_diag();

$idx_count_post = dir_file_count($CNF_INDEXDIR);
is($idx_count_post, $idx_count_pre, "number of index files before and after is the same");

$tapelist->reload();
ok(!$tapelist->lookup_tapelabel('TESTCONF01'),
     "succesfully looked up tape that should have been removed after --erase");

$dev = Amanda::Device->new('file:' . Installcheck::Run::vtape_dir());

ok(!$dev->start($ACCESS_READ, undef, undef),
    "start device in read mode fails")
    or diag($dev->error_or_status());

# just in case the above does start the device
ok($dev->finish(),
   "finish device (just in case)")
    or diag($dev->error_or_status());

# test --keep-label

Installcheck::Dumpcache::load("basic");

$idx_count_pre = dir_file_count($CNF_INDEXDIR);

ok(run('amrmtape', '--keep-label', 'TESTCONF', 'TESTCONF01'),
   "amrmtape runs successfully with --keep-label")
    or proc_diag();

$idx_count_post = dir_file_count($CNF_INDEXDIR);
is($idx_count_post, $idx_count_pre, "number of index files before and after is the same");

$tapelist->reload();
my $tape = $tapelist->lookup_tapelabel('TESTCONF01');
ok($tape, "succesfully looked up tape that should still be there");
is($tape->{'datestamp'}, "0", "datestamp was zeroed");

$dev = Amanda::Device->new('file:' . Installcheck::Run::vtape_dir());

ok($dev->start($ACCESS_READ, undef, undef),
    "start device in read mode")
    or diag($dev->error_or_status());

ok($dev->finish(),
   "finish device after starting")
    or diag($dev->error_or_status());

# test --keep-label --erase

Installcheck::Dumpcache::load("basic");

$idx_count_pre = dir_file_count($CNF_INDEXDIR);

ok(run('amrmtape', '--keep-label', '--erase', 'TESTCONF', 'TESTCONF01'),
   "amrmtape runs successfully with --keep-label")
    or proc_diag();

$idx_count_post = dir_file_count($CNF_INDEXDIR);
is($idx_count_post, $idx_count_pre, "number of index files before and after is the same");

$tapelist->reload();
$tape = $tapelist->lookup_tapelabel('TESTCONF01');
ok($tape, "succesfully looked up tape that should still be there");
is($tape->{'datestamp'}, "0", "datestamp was zeroed");

$dev = Amanda::Device->new('file:' . Installcheck::Run::vtape_dir());

$dev->read_label();
ok(!($dev->status() & $DEVICE_STATUS_VOLUME_UNLABELED),
    "tape still has label")
    or diag($dev->error_or_status());
is($dev->volume_label, 'TESTCONF01', "label is correct");

# test --keep-label --erase

Installcheck::Dumpcache::load("basic");

$idx_count_pre = dir_file_count($CNF_INDEXDIR);

ok(run('amrmtape', '--keep-label', '--erase', 'TESTCONF', 'TESTCONF01'),
   "amrmtape runs successfully with --keep-label")
    or proc_diag();

$idx_count_post = dir_file_count($CNF_INDEXDIR);
is($idx_count_post, $idx_count_pre, "number of index files before and after is the same");

$tapelist->reload();
$tape = $tapelist->lookup_tapelabel('TESTCONF01');
ok($tape, "succesfully looked up tape that should still be there");
is($tape->{'datestamp'}, "0", "datestamp was zeroed");

$dev = Amanda::Device->new('file:' . Installcheck::Run::vtape_dir());

$dev->read_label();
ok(!($dev->status() & $DEVICE_STATUS_VOLUME_UNLABELED),
    "tape still has label")
    or diag($dev->error_or_status());
is($dev->volume_label, 'TESTCONF01', "label is correct");

# test --dryrun --erase --cleanup

Installcheck::Dumpcache::load("basic");
$diskpath = Amanda::Util::sanitise_filename($Installcheck::Run::diskname);
system ("touch -mt 201401020304.05 " . getconf($CNF_INDEXDIR) . "/localhost/$diskpath/*");

$idx_count_pre = dir_file_count($CNF_INDEXDIR);

ok(run('amrmtape', '--dryrun', '--erase', '--cleanup', 'TESTCONF', 'TESTCONF01'),
    "amrmtape runs successfully with --dryrun --erase --cleanup")
    or proc_diag();

$idx_count_post = dir_file_count($CNF_INDEXDIR);
is($idx_count_post, $idx_count_pre, "number of index files before and after is the same");

$tapelist->reload();
ok($tapelist->lookup_tapelabel('TESTCONF01'),
     "succesfully looked up tape that should still be there");

$dev = Amanda::Device->new('file:' . Installcheck::Run::vtape_dir());

ok($dev->start($ACCESS_READ, undef, undef),
    "start device in read mode")
    or diag($dev->error_or_status());

ok($dev->finish(),
   "finish device after starting")
    or diag($dev->error_or_status());

Installcheck::Run::cleanup();
