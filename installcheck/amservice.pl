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

use Test::More tests => 3;
use strict;
use warnings;

use lib '@amperldir@';
use Installcheck;
use Installcheck::Run qw( run run_get );
use Amanda::Debug;
use Amanda::Paths;
use Amanda::Constants;
use Amanda::Feature;

Amanda::Debug::dbopen("installcheck");
Installcheck::log_test_output();

my $input_filename = "$Installcheck::TMP/amservice_input.txt";
my $testconf = Installcheck::Run::setup();
$testconf->write();
my $input;

sub write_input_file {
    my ($contents) = @_;
    open my $fh, ">", $input_filename
	or die("Could not write to $input_filename");
    print $fh $contents;
    close $fh;
}

sub all_lines_ok {
    my ($output) = @_;
    my $ok = 1;

    return 0 if not $output;

    for (split /\n/, $output) {
	next if /^OPTIONS /;
	next if /^OK /;
	diag "Got unexpected line: $_";
	$ok = 0;
    }

    return $ok;
}

my $features = Amanda::Feature::Set->mine();
$features->remove($Amanda::Feature::fe_selfcheck_message);
my $features_str = $features->as_string();

# a simple run of amservice to begin with
like(run_get('amservice', '-f', '/dev/null', 'localhost', 'local', 'noop'),
    qr/^OPTIONS features=/,
    "amservice runs noop successfully");

$input = <<EOF;
<dle>
  <program>GNUTAR</program>
  <disk>$Installcheck::TMP</disk>
</dle>
EOF

SKIP: {
    skip "GNUTAR not installed", 1 unless $Amanda::Constants::GNUTAR;
    write_input_file($input);
    ok(all_lines_ok(
	run_get('amservice', '-f', $input_filename, '--features', $features_str, 'localhost', 'local', 'selfcheck')),
	"GNUTAR program selfchecks successfully");
}

# (can't test DUMP, since we don't have a device)

$input = <<EOF;
<dle>
  <program>APPLICATION</program>
  <backup-program>
    <plugin>amgtar</plugin>
  </backup-program>
  <disk>$Installcheck::TMP</disk>
</dle>
EOF

SKIP: {
    skip "GNUTAR not installed", 1 unless $Amanda::Constants::GNUTAR;
    write_input_file($input);
    ok(all_lines_ok(
	run_get('amservice', '-f', $input_filename, '--features', $features_str, 'localhost', 'local', 'selfcheck')),
	"amgtar application selfchecks successfully");
}

$input = <<EOF;
<dle>
  <program>APPLICATION</program>
  <backup-program>
    <plugin>amstar</plugin>
  </backup-program>
  <disk>$Installcheck::TMP</disk>
</dle>
EOF

Installcheck::Run::cleanup();
unlink($input_filename);
