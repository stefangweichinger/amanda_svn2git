# Copyright (c) 2009-2012 Zmanda, Inc.  All Rights Reserved.
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

use Test::More tests => 42;
use strict;
use warnings;

use lib '@amperldir@';
use Installcheck::Config;
use Installcheck::Run qw(run run_err run_get load_vtape vtape_dir);
use Amanda::Device qw( :constants );
use Amanda::Config qw( :init :getconf );
use Amanda::Paths;
use Amanda::Debug;
use Amanda::Tapelist;
use Amanda::Changer;
use Amanda::MainLoop;

my $testconf;

Amanda::Debug::dbopen("installcheck");
Installcheck::log_test_output();

$testconf = Installcheck::Run::setup();
$testconf->write();

config_init($CONFIG_INIT_EXPLICIT_NAME, "TESTCONF");
my ($cfgerr_level, @cfgerr_errors) = config_errors();
if ($cfgerr_level >= $CFGERR_WARNINGS) {
    config_print_errors();
    BAIL_OUT("config errors");
}

# label slot 2 with "MyTape", slot 3 with "TESTCONF13", and add
# the latter to the tapelist
sub setup_vtapes {
    my ($chg, $dev);

    $chg = Amanda::Changer->new();
    $chg->load(slot => 2,
	res_cb => sub {
	    my ($err, $reservation) = @_;
	    if ($err) {
		BAIL_OUT("device error 1");
	    }
	    $dev = $reservation->{'device'};

	    ($dev && ($dev->status == $DEVICE_STATUS_SUCCESS ||
		      $dev->status == $DEVICE_STATUS_VOLUME_UNLABELED))
	        or BAIL_OUT("device error 2");

	    $dev->start($ACCESS_WRITE, "MyTape", undef)
	        or BAIL_OUT("device error 3");
	    $dev->finish()
	        or BAIL_OUT("device error 4");
	    $reservation->release(
		finished_cb => sub {
		    $chg->load(slot => 3,
			res_cb => sub {
			    my ($err, $reservation) = @_;
			    if ($err) {
				BAIL_OUT("device error 5");
			    }
			    $dev = $reservation->{'device'};
		
			    ($dev && ($dev->status == $DEVICE_STATUS_SUCCESS ||
				      $dev->status == $DEVICE_STATUS_VOLUME_UNLABELED))
			        or BAIL_OUT("device error 6");
		
			    $dev->start($ACCESS_WRITE, "TESTCONF13", undef)
			        or BAIL_OUT("device error 7");
			    $dev->finish()
			        or BAIL_OUT("device error 8");
			    $reservation->release(finished_cb => sub {
				    Amanda::MainLoop::quit();
				});
		        });
		});
        });

    Amanda::MainLoop::run();

    $chg->quit();
    my $tlf = Amanda::Config::config_dir_relative(getconf($CNF_TAPELIST));
    my ($tl, $message) = Amanda::Tapelist->new($tlf, 1);
    $tl->add_tapelabel("0", "TESTCONF13", "test tape");
    $tl->write($tlf);
}

like(run_err('amtape'),
    qr/^Usage:/,
    "bare 'amtape' gives usage message");

# in general, output goes to stderr, so we can't use run_get.  These checks
# accomplish two things: ensure that amtape can invoke the changer functions
# correctly (and not generate an error), and ensure that it gives the
# appropriate responses.  It does not exercise the changer itself -- most
# of these operations are meaningless for vtapes, anyway.

setup_vtapes();

ok(run('amtape', 'TESTCONF', 'reset'),
    "'amtape TESTCONF reset'");
like($Installcheck::Run::stderr,
    qr/changer is reset/,
    "..result correct");

# TODO: chg-disk doesn't support "eject"
#ok(run('amtape', 'TESTCONF', 'eject'),
#    "'amtape TESTCONF eject'");
#like($Installcheck::Run::stderr,
#    qr/drive ejected/,
#    "..result correct");

# TODO: chg-disk doesn't support "clean"

ok(run('amtape', 'TESTCONF', 'slot', '2'),
    "'amtape TESTCONF slot 2'");
like($Installcheck::Run::stderr,
    qr/changed to slot 2/,
    "..result correct");

ok(run('amtape', 'TESTCONF', 'slot', 'current'),
    "'amtape TESTCONF slot current'");
like($Installcheck::Run::stderr,
    qr/changed to slot 2/,
    "..result correct");

ok(run('amtape', 'TESTCONF', 'slot', 'next'),
    "'amtape TESTCONF slot next'");
like($Installcheck::Run::stderr,
    qr/changed to slot 3/,
    "..result correct");

ok(run('amtape', 'TESTCONF', 'slot', 'next'),
    "'amtape TESTCONF slot next'");
like($Installcheck::Run::stderr,
    qr/changed to slot 1/, # loop around to slot 1
    "..result correct");

ok(run('amtape', 'TESTCONF', 'label', 'MyTape'),
    "'amtape TESTCONF label MyTape'");
like($Installcheck::Run::stderr,
    qr/slot +2:.*label MyTape/,
    "..result correct");

ok(run('amtape', 'TESTCONF', 'current'),
    "'amtape TESTCONF current'");
like($Installcheck::Run::stderr,
    qr/slot +2:.*label MyTape/,
    "..result correct");

# TODO: chg-disk doesn't support "update"
#ok(run('amtape', 'TESTCONF', 'update'),
#    "'amtape TESTCONF update'");
#like($Installcheck::Run::stderr,
#    qr/update complete/,
#    "..result correct");

ok(run('amtape', 'TESTCONF', 'show'),
    "'amtape TESTCONF show'");
like($Installcheck::Run::stderr,
    qr/slot +2:.*label MyTape \(label do not match labelstr\)\nslot +3/,
    "'amtape TESTCONF show' ..result correct");

ok(run('amtape', 'TESTCONF', 'show', '2'),
    "'amtape TESTCONF show'");
like($Installcheck::Run::stderr,
    qr/^slot +2:.*label MyTape \(label do not match labelstr\)$/,
    "'amtape TESTCONF show 2' ..result correct");

ok(run('amtape', 'TESTCONF', 'show', '1,3'),
    "'amtape TESTCONF show'");
like($Installcheck::Run::stderr,
    qr/^slot +1: unlabeled volume\nslot +3: date \d{14} label TESTCONF13$/,
#    qr/slot +1: unlabeled volume\nslot +3: date 20111121133419 label TESTCONF13/,
    "'amtape TESTCONF show 1,3' ..result correct");

ok(run('amtape', 'TESTCONF', 'taper'),
    "'amtape TESTCONF taper'");
like($Installcheck::Run::stderr,
    qr/Will write to volume 'TESTCONF13' in slot 3/,
    "'amtape TESTCONF taper' ..result correct");

###
## shift to using the new Amanda::Changer::disk

$testconf->remove_param("tapedev");
$testconf->remove_param("tpchanger");
$testconf->add_param("tpchanger", "\"chg-disk:" . vtape_dir(). "\"");
$testconf->write();

setup_vtapes();

ok(run('amtape', 'TESTCONF', 'reset'),
    "'amtape TESTCONF reset'");
like($Installcheck::Run::stderr,
    qr/changer is reset/,
    "..result correct");

ok(run('amtape', 'TESTCONF', 'slot', '2'),
    "'amtape TESTCONF slot 2'");
like($Installcheck::Run::stderr,
    qr/changed to slot 2/,
    "..result correct");

ok(run('amtape', 'TESTCONF', 'slot', 'current'),
    "'amtape TESTCONF slot current'");
like($Installcheck::Run::stderr,
    qr/changed to slot 2/,
    "..result correct");

ok(run('amtape', 'TESTCONF', 'slot', 'next'),
    "'amtape TESTCONF slot next'");
like($Installcheck::Run::stderr,
    qr/changed to slot 3/,
    "..result correct");

ok(run('amtape', 'TESTCONF', 'label', 'MyTape'),
    "'amtape TESTCONF label MyTape'");
like($Installcheck::Run::stderr,
    qr/label MyTape is now loaded from slot 2/,
    "..result correct");

ok(run('amtape', 'TESTCONF', 'current'),
    "'amtape TESTCONF current'");
like($Installcheck::Run::stderr,
    qr/slot +2:.*label MyTape/,
    "..result correct");

like(run_err('amtape', 'TESTCONF', 'update'),
    qr/does not support update/,
    "'amtape TESTCONF update' fails gracefully");

ok(run('amtape', 'TESTCONF', 'show'),
    "'amtape TESTCONF show'");
like($Installcheck::Run::stderr,
    qr/slot +2:.*label MyTape \(label do not match labelstr\)\nslot +3/,
    "..result correct");

ok(run('amtape', 'TESTCONF', 'inventory'),
    "'amtape TESTCONF inventory'");
like($Installcheck::Run::stdout,
    qr/slot +1: blank\nslot +2: label MyTape \(current\) \(label do not match labelstr\)\nslot +3/,
    "..result correct");

ok(run('amtape', 'TESTCONF', 'taper'),
    "'amtape TESTCONF taper'");
like($Installcheck::Run::stderr,
    qr/Will write to volume 'TESTCONF13' in slot 3/,
    "'amtape TESTCONF taper' ..result correct");

Installcheck::Run::cleanup();
