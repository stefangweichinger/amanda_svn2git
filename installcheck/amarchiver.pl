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

use Test::More tests => 18;
use strict;
use warnings;

use lib '@amperldir@';
use Installcheck;
use Installcheck::Run qw( run run_get );
use Amanda::Paths;
use Amanda::Constants;
use File::Path qw( mkpath rmtree );
use Amanda::Debug;

Amanda::Debug::dbopen("installcheck");
Installcheck::log_test_output();

my $tmpdir = "$Installcheck::TMP/amarchiver-installcheck";
my $archfile = "$tmpdir/test.amar";
my $data = "abcd" x 500;
my $fh;

rmtree($tmpdir);
mkpath($tmpdir);
chdir($tmpdir);

open($fh, ">", "test.tmp-1");
print $fh $data;
close($fh);

open($fh, ">", "test.tmp-2");
print $fh $data;
close($fh);

ok(run('amarchiver', '--version'),
    "amarchiver --version OK");
like($Installcheck::Run::stdout,
    qr{^amarchiver },
    "..and output is reasonable");

# test creating archives

ok(run('amarchiver', '--create', "test.tmp-1"),
    "archive creation without --file succeeds");
like($Installcheck::Run::stdout, qr{^AMANDA ARCHIVE FORMAT },
    "..and produces something that looks like an archive");

unlink($archfile);
ok(run('amarchiver', '--create', '--file', $archfile,
	"$sbindir/amarchiver", "$sbindir/amgetconf"),
    "archive creation succeeds");
ok(-f $archfile, "..and target file exists");

unlink($archfile);
ok(run('amarchiver', '--create', '--verbose', '--file', $archfile,
	"$sbindir/amarchiver", "$sbindir/amgetconf"),
    "archive creation with --verbose succeeds");
like($Installcheck::Run::stdout,
    qr{^\Q$sbindir\E/amarchiver\n\Q$sbindir\E/amgetconf$},
    "..and output is correct");

ok(run('amarchiver', '--create', '--verbose', $archfile),
    "archive creation with --verbose and without --file succeeds");
like($Installcheck::Run::stderr,
    qr{\Q$archfile\E},
    "..and output goes to stderr");

unlink($archfile);
ok(run('amarchiver', '--create', '--verbose', '--verbose', '--file', $archfile,
	"$sbindir/amarchiver", "$sbindir/amgetconf", "test.tmp-1"),
    "archive creation with two --verbose args succeeds");
like($Installcheck::Run::stdout,
    qr{^[[:digit:]]+ \Q$sbindir\E/amarchiver\n[[:digit:]]+ \Q$sbindir\E/amgetconf\n2000 test.tmp-1$},
    "..and output is correct");

# test listing archives

run('amarchiver', '--create', '--file', $archfile, "test.tmp-1", "test.tmp-2")
    or BAIL_OUT("could not create an archive to test listing/extracting");

ok(run('amarchiver', '--list', '--file', $archfile),
    "archive listing succeeds");
is($Installcheck::Run::stdout, "test.tmp-1\ntest.tmp-2\nsize: 4096\n",
    "..and output is correct");

# test extracting archives

unlink("test.tmp-1");
unlink("test.tmp-2");
ok(run('amarchiver', '--extract', '--file', $archfile),
    "archive extraction succeeds");
ok((-f "test.tmp-1" && -f "test.tmp-2"), "..and the files reappear")
    or diag(`find .`);

unlink("test.tmp-1");
unlink("test.tmp-2");
ok(run('amarchiver', '--extract', '--file', $archfile, "test.tmp-2"),
    "archive extraction of only one file succeeds");
ok((! -f "test.tmp-1" && -f "test.tmp-2"), "..and the file reappears")
    or diag(`find .`);

END {
    chdir("$tmpdir/..");
    rmtree($tmpdir);
}
