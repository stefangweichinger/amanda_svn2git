# Copyright (c) 2007-2012 Zmanda, Inc.  All Rights Reserved.
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

use Test::More tests => 4;
use strict;
use warnings;

use lib '@amperldir@';
use Installcheck::Config;
use Installcheck::Dumpcache;
use Installcheck::Catalogs;
use Installcheck::Run qw(run run_get run_err $diskname);
use Amanda::Paths;
use Amanda::Debug;

Amanda::Debug::dbopen("installcheck");
Installcheck::log_test_output();

##
# First, try amoverview without a config

ok(!run('amoverview'),
    "amoverview with no arguments returns an error exit status");
like($Installcheck::Run::stderr, qr/\AUSAGE:/i,
    ".. and gives usage message on stderr");

##
# Now try it against a cached dump

Installcheck::Dumpcache::load("multi");

like(run_get('amoverview', 'TESTCONF', '--diskwidth=200'),
    # this pattern is pretty loose, but that's OK
    qr{
	\s+date\s+\d\d\s+
	host\s+disk\s+\d\d\s+
	localhos\s+/.*/installchecks/backmeup\s+00\s+
	localhos\s+/.*/installchecks/backmeup/dir\s+01
    }mxs,
    "amoverview of the 'multi' dump looks good");
Installcheck::Run::cleanup();

##
# And some cached catalogs

my $testconf = Installcheck::Run::setup();
$testconf->write();

my $cat = Installcheck::Catalogs::load("bigdb");
$cat->install();

like(run_get('amoverview', 'TESTCONF', '--skipmissed'),
    qr{
\s*              date      \s+ 01\s+02\s+03\s+03\s+04\s+05\s+05\s+06\s+07 \s+
\s*  host \s+    disk      \s+ 11\s+22\s+11\s+13\s+14\s+11\s+15\s+16\s+22 \s+
\s*
\s*  lovelace\s+ /home/ada \s+  -\s+ -\s+ -\s+ -\s+ -\s+ -\s+ -\s+ -\s+ 3 \s+
\s*  otherbox\s+ /direct   \s+  -\s+ -\s+ -\s+ -\s+ -\s+ -\s+ 0\s+ -\s+ - \s+
\s*  otherbox\s+ /lib      \s+  -\s+ -\s+ -\s+ 0\s+1E\s+ 0\s+ -\s+ -\s+ - \s+
\s*  otherbox\s+ /usr/bin  \s+  -\s+ -\s+00\s+ -\s+ -\s+ 0\s+ -\s+ -\s+ - \s+
\s*  somebox \s+ /lib      \s+  0\s+ 0\s+ -\s+ 0\s+ -\s+ -\s+ 0\s+ E\s+ - \s+
\s*  somebox \s+ /usr/bin  \s+  -\s+ -\s+ -\s+ 1\s+ -\s+ -\s+ 1\s+ 1\s+ -
    }mxs,
    "amoverview of the bigdb catalog looks right");
