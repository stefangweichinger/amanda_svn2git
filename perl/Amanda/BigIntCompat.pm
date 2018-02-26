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
# Sunnyvale, CA 94085, or: http://www.zmanda.com

package Amanda::BigIntCompat;

use strict;
use warnings;
use overload;
use Math::BigInt;

=head1 NAME

Amanda::BigIntCompat -- make C<Math::BigInt> behave consistently

=head1 SYNOPSIS

  use Amanda::BigIntCompat;
  use Math::BigInt;

  my $bn = Math::BigInt->new(1);
  print "okay\n" if $bn eq "1";

=head1 INTERFACE

This module will modify C<Math::BigInt> to hide inconsistent behaviors across
Perl versions. Specifically, it handles the following.

=over

=item stringification

Older versions of C<Math::BigInt>, like the one shipped with Perl 5.6.1,
stringify positive numbers with a leading C<+> (e.g. C<+1> instead of C<1>).

=back

=cut

my $test_num = Math::BigInt->new(1);

our $stringify = overload::Method($test_num, '""');
# convince older perls that $stringify really is used
$stringify = $stringify;

if ($test_num =~ /^\+/) {
    eval <<'EVAL';
        package Math::BigInt;
        use overload 'eq' => sub {
	    my ($self, $other) = @_;
	    return "$self" eq "$other";
        };

	# stringify is already overloaded; seems to be no good way to
	# re-overload it without triggering a warning
	no warnings 'redefine';
	sub stringify {
            my $str = $Amanda::BigIntCompat::stringify->(@_);
            $str =~ s/^\+//;
	    return $str;
	}
EVAL
    die $@ if $@;
}

# the "sign" method does not exist in older versions, either, but is used
# by bigint2uint64().
if (!$test_num->can("sign")) {
    eval <<'EVAL';
	package Math::BigInt;
	sub sign { ($_[0] =~ /^-/)? "-" : "+"; }
EVAL
    die $@ if $@;
}

# similarly for bstr
if (!$test_num->can("bstr")) {
    eval <<'EVAL';
	package Math::BigInt;
	sub bstr { "$_[0]"; }
EVAL
    die $@ if $@;
}

eval <<'EVAL';
	package Math::BigInt;
	sub TO_JSON { "$_[0]"+0; }
EVAL
die $@ if $@;
1;
