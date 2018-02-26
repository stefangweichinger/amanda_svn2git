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

use Test::More tests => 31;
use strict;
use warnings;

# This test only puts the perl wrappers through their paces -- the underlying
# library is well-covered by amar-test.

use lib '@amperldir@';
use Installcheck;
use Amanda::Archive;
use Amanda::Paths;
use Amanda::MainLoop;
use Amanda::Debug;
use Data::Dumper;

Amanda::Debug::dbopen("installcheck");
Installcheck::log_test_output();

my $arch_filename = "$Installcheck::TMP/amanda_archive.bin";
my $data_filename = "$Installcheck::TMP/some_data.bin";
my ($fh, $dfh, $ar, $f1, $f2, $a1, $a2, @res, $posn);

# some versions of Test::More will fail tests if the identity
# relationships of the two objects passed to is_deeply do not
# match, so we use the same object for $user_data throughout.
my $user_data = [ "x", "y", "z" ];

# set up a large file full of data

open($dfh, ">", $data_filename);
my $onek = "abcd" x 256;
my $onemeg = $onek x 1024;
for (my $i = 0; $i < 5; $i++) {
    print $dfh $onemeg;
}
$onek = $onemeg = undef;
close($dfh);

# utility functions for creating a "fake" archive file

sub make_header {
    my ($fh, $version) = @_;
    my $hdr = "AMANDA ARCHIVE FORMAT $version";
    $hdr .= "\0" x (28 - length $hdr);
    print $fh $hdr;
}

sub make_record {
    my ($fh, $filenum, $attrid, $data, $eoa) = @_;
    my $size = length($data);
    if ($eoa) {
	$size |= 0x80000000;
    }
    print $fh pack("nnN", $filenum, $attrid, $size);
    print $fh $data;
}

####
## TEST WRITING

open($fh, ">", $arch_filename) or die("opening $arch_filename: $!");
$ar = Amanda::Archive->new(fileno($fh), ">");
pass("Create a new archive");

$f1 = $ar->new_file("filename1");
pass("Start an archive file");

$a1 = $f1->new_attr($Amanda::Archive::AMAR_ATTR_GENERIC_DATA);
$a1->add_data("foo!", 0);
$a2 = $f1->new_attr(19);
$a2->add_data("BAR!", 0);
$a1->add_data("FOO.", 1);
$a2->add_data("bar.", 0);
pass("Write some interleaved data");

$a1->close();
pass("Close an attribute with the close() method");

$a1 = Amanda::Archive::Attr->new($f1, 99);
pass("Create an attribute with its constructor");

open($dfh, "<", $data_filename);
$a1->add_data_fd(fileno($dfh), 1);
close($dfh);
pass("Add data from a file descriptor");
ok($a1->size() == 5242880, "size attribute A is " . $a1->size());
ok($f1->size() == 5242961, "size file A is " . $f1->size());
ok($ar->size() == 5242989, "Size A is " . $ar->size);

$a1 = undef;
pass("Close attribute when its refcount hits zero");
ok($ar->size() == 5242989, "Size B is " . $ar->size);

$f2 = Amanda::Archive::File->new($ar, "filename2");
pass("Add a new file (filename2)");

$a1 = $f2->new_attr(82);
$a1->add_data("word", 1);
pass("Add data to it");
ok($a1->size() == 4, "size attribute A1 is " . $a1->size());
ok($f2->size() == 29, "size file F2 is " . $f2->size());
ok($ar->size() == 5243018, "Size C is " . $ar->size);

$a2->add_data("barrrrr?", 0);	# note no EOA
pass("Add more data to first attribute");
ok($a2->size() == 16, "size attribute A2 is " . $a2->size());
ok($f1->size() == 5242977, "size file F1 is " . $f1->size());
ok($ar->size() == 5243034, "Size D is " . $ar->size);

($f1, $posn) = $ar->new_file("posititioned file", 1);
ok($posn > 0, "new_file returns a positive position");

$ar = undef;
pass("unref archive early");

($ar, $f1, $f2, $a1, $a2) = ();
pass("Close remaining objects");

close($fh);

####
## TEST READING

open($fh, ">", $arch_filename);
make_header($fh, 1);
make_record($fh, 16, 0, "/etc/passwd", 1);
make_record($fh, 16, 20, "root:foo", 1);
make_record($fh, 16, 21, "boot:foot", 0);
make_record($fh, 16, 22, "dustin:snazzy", 1);
make_record($fh, 16, 21, "..more-boot:foot", 1);
make_record($fh, 16, 1, "", 1);
close($fh);

open($fh, "<", $arch_filename);
$ar = Amanda::Archive->new(fileno($fh), "<");
pass("Create a new archive for reading");

@res = ();
$ar->read(
    file_start => sub {
	push @res, [ "file_start", @_ ];
	return "cows";
    },
    file_finish => sub {
	push @res, [ "file_finish", @_ ];
    },
    0 => sub {
	push @res, [ "frag", @_ ];
	return "ants";
    },
    user_data => $user_data,
);
is_deeply([@res], [
	[ 'file_start', $user_data, 16, '/etc/passwd' ],
        [ 'frag', $user_data, 16, "cows", 20, undef, 'root:foo', 1, 0 ],
        [ 'frag', $user_data, 16, "cows", 21, undef, 'boot:foot', 0, 0 ],
        [ 'frag', $user_data, 16, "cows", 22, undef, 'dustin:snazzy', 1, 0 ],
        [ 'frag', $user_data, 16, "cows", 21, "ants", '..more-boot:foot', 1, 0 ],
        [ 'file_finish', $user_data, 16, "cows", 0 ]
], "simple read callbacks called in the right order")
    or diag(Dumper(\@res));
$ar->close();
close($fh);


open($fh, "<", $arch_filename);
$ar = Amanda::Archive->new(fileno($fh), "<");
pass("Create a new archive for reading");

@res = ();
$ar->read(
    file_start => sub {
	push @res, [ "file_start", @_ ];
	return "IGNORE";
    },
    file_finish => sub {
	push @res, [ "file_finish", @_ ];
    },
    0 => sub {
	push @res, [ "frag", @_ ];
	return "ants";
    },
    user_data => $user_data,
);
is_deeply([@res], [
	[ 'file_start', $user_data, 16, '/etc/passwd' ],
], "'IGNORE' handled correctly")
    or diag(Dumper(\@res));
# TODO: check that file data gets dumped appropriately?


open($fh, "<", $arch_filename);
$ar = Amanda::Archive->new(fileno($fh), "<");

@res = ();
$ar->read(
    file_start => sub {
	push @res, [ "file_start", @_ ];
	return "dogs";
    },
    file_finish => sub {
	push @res, [ "file_finish", @_ ];
    },
    21 => [ 100, sub {
	push @res, [ "fragbuf", @_ ];
	return "pants";
    } ],
    0 => sub {
	push @res, [ "frag", @_ ];
	return "ants";
    },
    user_data => $user_data,
);
is_deeply([@res], [
	[ 'file_start', $user_data, 16, '/etc/passwd' ],
        [ 'frag', $user_data, 16, "dogs", 20, undef, 'root:foo', 1, 0 ],
        [ 'frag', $user_data, 16, "dogs", 22, undef, 'dustin:snazzy', 1, 0 ],
        [ 'fragbuf', $user_data, 16, "dogs", 21, undef, 'boot:foot..more-boot:foot', 1, 0 ],
        [ 'file_finish', $user_data, 16, "dogs", 0 ]
], "buffering parameters parsed correctly")
    or diag(Dumper(\@res));


open($fh, "<", $arch_filename);
$ar = Amanda::Archive->new(fileno($fh), "<");

@res = ();
eval {
    $ar->read(
	file_start => sub {
	    push @res, [ "file_start", @_ ];
	    die "uh oh";
	},
	user_data => $user_data,
    );
};
like($@, qr/uh oh at .*/, "exception propagated correctly");
is_deeply([@res], [
	[ 'file_start', $user_data, 16, '/etc/passwd' ],
], "file_start called before exception was rasied")
    or diag(Dumper(\@res));
$ar->close();

unlink($arch_filename);

open($fh, ">", $arch_filename);
$ar = Amanda::Archive->new(fileno($fh), ">");
$f1 = $ar->new_file("filename1");
$a1 = $f1->new_attr($Amanda::Archive::AMAR_ATTR_GENERIC_DATA);

open($dfh, "<", $data_filename);
$a1->add_data_fd(fileno($dfh), 1);
close($dfh);

$a1->close();
$f1->close();

$f1 = $ar->new_file("filename2");
$a1 = $f1->new_attr($Amanda::Archive::AMAR_ATTR_GENERIC_DATA);
$a1->add_data("abcdefgh" x 16384);
$a1->close();
$f1->close();

$f1 = $ar->new_file("filename3");
$a1 = $f1->new_attr($Amanda::Archive::AMAR_ATTR_GENERIC_DATA);
$a1->add_data("abcdefgh" x 16384);
$a1->close();
$f1->close();

$ar->close();
close($fh);

open($fh, "<", $arch_filename);
$ar = Amanda::Archive->new(fileno($fh), "<");
@res = ();
my $fh1;
open $fh1, ">/dev/null" || die("/dev/null");
$ar->set_read_cb(
    file_start => sub {
	my ($user_data, $filenum, $filename) = @_;
	push @res, ["file_start", @_ ];
	if ($filename eq "filename1") {
	    my $time_str = Amanda::MainLoop::timeout_source(500);
	    $time_str->set_callback(sub {
		$ar->read_to($filenum, $Amanda::Archive::AMAR_ATTR_GENERIC_DATA, fileno($fh1));
		$ar->start_read();
		$time_str->remove();
	    });
	    $ar->stop_read();
	}
	return "dog $filenum $filename";
    },
    file_finish => sub {
	my ($user_data, $filenum, $filedata) = @_;
	push @res, [ "file_finish", @_ ];
    },
    16 => sub {
	my ($user_data, $filenum, $file_data, $attrid,
	    $attr_data, $data, $eoa, $truncated) = @_;
	push @res, [ "frag", $user_data, $filenum, $file_data, $attrid, $attr_data, $eoa, $truncated ];
    },
    0 => sub {
	my ($user_data, $filenum, $file_data, $attrid,
	    $attr_data, $data, $eoa, $truncated) = @_;
	push @res, [ "16", $user_data, $filenum, $file_data, $attrid, $attr_data, $eoa, $truncated ];
    },
    user_data => $user_data,
    done => sub {
	my ($error) = @_;
	push @res, [ "done" , @_ ];
	Amanda::MainLoop::quit();
    }
);
Amanda::MainLoop::run();
close $fh1;
$ar->close();

is_deeply([@res], [
	[ 'file_start', $user_data, 1, 'filename1' ],
	[ 'file_finish', $user_data, 1, 'dog 1 filename1', 0 ],
	[ 'file_start', $user_data, 2, 'filename2' ],
	[ 'frag', $user_data, 2, "dog 2 filename2", 16, undef, 0, 0 ],
	[ 'frag', $user_data, 2, "dog 2 filename2", 16, 4, 1, 0 ],
	[ 'file_finish', $user_data, 2, 'dog 2 filename2', 0 ],
	[ 'file_start', $user_data, 3, 'filename3' ],
	[ 'frag', $user_data, 3, "dog 3 filename3", 16, undef, 0, 0 ],
	[ 'frag', $user_data, 3, "dog 3 filename3", 16, 8, 1, 0 ],
	[ 'file_finish', $user_data, 3, "dog 3 filename3", 0 ],
	[ 'done' ]
], "buffering parameters parsed correctly")
    or diag(Dumper(\@res));
unlink($data_filename);
unlink($arch_filename);


