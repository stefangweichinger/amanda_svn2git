# Copyright (c) 2012 Zmanda, Inc.  All Rights Reserved.
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

package Amanda::Rest::Configs;
use strict;
use warnings;

use Amanda::Config qw( :getconf config_dir_relative );
use Symbol;
use Data::Dumper;
use Scalar::Util;
use vars qw(@ISA);
use Amanda::Debug;
use Amanda::Util qw( :constants );

=head1 NAME

Amanda::Rest::Configs -- Rest interface to Amanda::Config

=head1 INTERFACE

=over

=item Get a list of config

 request:
  GET /amanda/v1.0/configs

 reply:
  HTTP status: 200 OK
  [
     {
        "code" : "1500003",
        "config" : [
	  "test",
        ],
        "message" : "config name",
        "severity" : "16",
        "source_filename" : "/usr/lib/amanda/perl/Amanda/Rest/Configs.pm",
        "source_line" : "187"
     }
  ]

 reply:
  HTTP status: 404 Not found
  [
     {
        "code" : "1500004",
        "message" : "no config",
        "severity" : "16",
        "source_filename" : "/usr/lib/amanda/perl/Amanda/Rest/Configs.pm",
        "source_line" : "193"
     }
  ]

 reply:
  HTTP status: 404 Not found
  [
     {
        "code" : "1500006",
        "dir" : "/etc/amanda",
        "errno" : "No such file or directory",
        "message" : "Can't open config directory '/etc/amanda': No such file or directory",
        "severity" : "16",
        "source_filename" : "/usr/lib/amanda/perl/Amanda/Rest/Configs.pm",
        "source_line" : "176"
     }
  ]

=item Get the values of all global parameters

 request:
  GET /amanda/v1.0/configs/:CONF

 result:
  [
     {
        "code" : "1500008",
        "message" : "Parameters values",
        "result" : {
           "RUNTAPES" : 3,
           "TAPECYCLE" : 50
	   ...
        },
        "severity" : "16",
        "source_filename" : "/usr/lib/amanda/perl/Amanda/Rest/Configs.pm",
        "source_line" : "151"
     }
  ]

=item Get the value of one or more global parameters

 request:
  GET /amanda/v1.0/configs/:CONF?fields=runtapes&fields=foo&fields=tapecycle&fields=bar

 result:
  [
     {
        "code" : "1500007",
        "message" : "Not existant parameters",
        "parameters" : [
           "foo",
           "bar"
        ],
        "severity" : "16",
        "source_filename" : "/usr/lib/amanda/perl/Amanda/Rest/Configs.pm",
        "source_line" : "144"
     },
     {
        "code" : "1500008",
        "message" : "Parameters values",
        "result" : {
           "RUNTAPES" : 3,
           "TAPECYCLE" : 50
        },
        "severity" : "16",
        "source_filename" : "/usr/lib/amanda/perl/Amanda/Rest/Configs.pm",
        "source_line" : "151"
     }
  ]

=item Get a list of all item in a section

 request:
  GET /amanda/v1.0/configs/:CONF/SECTION
  eg. /amanda/v1.0/configs/:CONF/dumptypes

 where SECTION is applications
                  changers
                  devices
                  dumptypes
                  holdingdisks
                  interfaces
                  interactivitys
                  policys
                  taperscans
                  tapetypes
                  scripts
                  storages

 reply:
  HTTP status: 200 OK
  [
     {
        "code" : "1500022", #code differ for each section
        "dumptypes_list" : [
	  "name1",
	  "name2",
	  ...
        ],
        "message" : "Dumptype list",
        "severity" : "success",
        "source_filename" : "/usr/lib/amanda/perl/Amanda/Rest/Configs.pm",
        "source_line" : "397"
     }
  ]


=item Get the values of all parameters of a section

 request:
  GET /amanda/v1.0/configs/:CONF/SECTION/:SECTION
  eg. /amanda/v1.0/configs/:CONF/dumptypes/global
 query arguments:
  expand_application=1
  expand_device=1
  expand_dumptype=1
  expand_changer=1
  expand_holdingdisk=1
  expand_interface=1
  expand_interactivity=1
  expand_policy=1
  expand_script=1
  expand_storage=1
  expand_taperscan=1
  expand_tapetype=1

 result:
  [
     {
        "code" : "1500037", #code differ for each section
        "message" : "Dumptype 'global' parameters values",
        "result" : {
           "RUNTAPES" : 3,
           "TAPECYCLE" : 50
	   ...
        },
        "severity" : "success",
        "source_filename" : "/usr/lib/amanda/perl/Amanda/Rest/Configs.pm",
        "source_line" : "271"
     }
  ]

=item Get the value of one or more parametes of a section

 request:
  GET /amanda/v1.0/configs/:CONF/SECTION/:SECTION?fields=index&fields=foo
  eg. /amanda/v1.0/configs/:CONF/dumptypes/global?fields=index&fields=foo'

 result:
  [
     {
        "code" : "1500058",
        "message" : "invalid 'FOO' field specified",
        "field" : "FOO",
        "severity" : "error",
        "source_filename" : "/usr/lib/amanda/perl/Amanda/Rest/Configs.pm",
        "source_line" : "263"
     },
     {
        "code" : "1500037", #code differ for each section
        "message" : "Dumptype 'global' parameters values",
        "result" : {
           "INDEX" : "YES",
        },
        "severity" : "success",
        "source_filename" : "/usr/lib/amanda/perl/Amanda/Rest/Configs.pm",
        "source_line" : "271"
     }
  ]

=item Configure overrides

 The way to add configuration overrides is by using %3D in the override

   config_overrides=ctimeout%3D1000

=back

=cut

sub config_init {
    my %params = @_;
    my $config_name      = $params{'CONF'};
    my $config_overrides = $params{'config_overrides'};
    my $failure          = $params{'FAILURE'};

    my $status = -1;
    my @result_messages;

    if (!defined $config_name) {
	$status = 404;
	push @result_messages, Amanda::Config::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code     => 1500002,
				severity => $Amanda::Message::ERROR);
    }

    Amanda::Config::config_uninit();
    if (defined $failure) {
	if ($Amanda::Constants::FAILURE_CODE eq "0") {
	    $status = 404;
	    push @result_messages, Amanda::Config::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code     => 1560000,
				severity => $Amanda::Message::ERROR);
	    return ($status, @result_messages);
	}
	$ENV{'FAILURE_CODE'} = '1';
	while (my ($key,$value) = each %{$failure}) {
	    $ENV{$key} = $value;
	}
    }

    if (defined $config_overrides) {
	my $g_config_overrides;
	if (ref $config_overrides eq 'ARRAY') {
	    $g_config_overrides = Amanda::Config::new_config_overrides(@{$config_overrides} + 1);
	    for my $co (@{$config_overrides}) {
		Amanda::Config::add_config_override_opt($g_config_overrides, $co);
	    }
	} else {
	    $g_config_overrides = Amanda::Config::new_config_overrides(2);
	    Amanda::Config::add_config_override_opt($g_config_overrides, $config_overrides);
	}
	if (defined $g_config_overrides) {
	    Amanda::Config::set_config_overrides($g_config_overrides);
	}
    }
    Amanda::Config::config_init($Amanda::Config::CONFIG_INIT_EXPLICIT_NAME, $config_name);

    my ($cfgerr_level, @cfgerr_errors) = Amanda::Config::config_errors();
    if ($cfgerr_level >= $Amanda::Config::CFGERR_WARNINGS) {
	for my $cfgerr (@cfgerr_errors) {
	    push @result_messages, Amanda::Config::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code     => $cfgerr_level == $Amanda::Config::CFGERR_WARNINGS
						? 1500000 : 1500001,
				severity => $cfgerr_level == $Amanda::Config::CFGERR_WARNINGS
						? $Amanda::Message::WARNING : $Amanda::Message::ERROR,
				cfgerror => $cfgerr);
	}
    }

    return ($status, @result_messages);
}

sub config_read_disklist {
    my %params = @_;

    my $status = -1;
    my @result_messages;

    my $diskfile = config_dir_relative(getconf($CNF_DISKFILE));
    Amanda::Disklist::unload_disklist();
    my $cfgerr_level = Amanda::Disklist::read_disklist('filename' => $diskfile);
    if ($cfgerr_level >= $Amanda::Config::CFGERR_WARNINGS) {
	push @result_messages, Amanda::Disklist::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code         => 1400006,
				severity     => $Amanda::Message::ERROR,
				diskfile     => $diskfile,
				cfgerr_level => $cfgerr_level);
    }
    return ($status, @result_messages);
}

sub _object {
    my $DATA = shift;
    my $func_key_list = shift;
    my $func_key_to_name = shift;
    my $func_getconf_human = shift;
    my %params = @_;

    my %values;

    my %fields;
    if (defined $params{'fields'}) {
	my $type = Scalar::Util::reftype($params{'fields'});
	if (defined $type and $type eq "ARRAY") {
	    foreach my $name (@{$params{'fields'}}) {
		$name = uc($name);
		$name =~ s/_/-/g;
		$fields{$name} = 1;
	    }
	} elsif (!defined $type and defined $params{'fields'} and $params{'fields'} ne '') {
	    my $name = $params{'fields'};
	    $name = uc($name);
	    $name =~ s/_/-/g;
	    $fields{$name} = 1;
	}
    }
    my @keys = $func_key_list->();
    foreach my $key (@keys) {
	my $name = $func_key_to_name->($key);
	$name =~ s/_/-/g;
	if ((!defined $params{'fields'}) ||
	    ((defined $fields{$name}) && ($fields{$name} == 1))) {
	    my $data =  $func_getconf_human->($DATA, $key);
	    if ($name eq "APPLICATION") {
		if ($params{'expand_application'} && $data) {
		    my $application = lookup_application($data);
		    if ($application) {
			$values{'APPLICATION-DATA'} = Amanda::Rest::Configs::application_object($application, %params);
		    }
		}
	    } elsif ($name eq "TPCHANGER") {
		if ($params{'expand_changer'} && $data) {
		    my $changer = lookup_changer_config($data);
		    if ($changer) {
			$values{'CHANGER-DATA'} = Amanda::Rest::Configs::changer_object($changer, %params);
		    }
		}
	    } elsif ($name eq "TAPEDEV") {
		if ($params{'expand_device'} && $data) {
		    my $device = lookup_device_config($data);
		    if ($device) {
			$values{'DEVICE-DATA'} = Amanda::Rest::Configs::device_object($device, %params);
		    }
		}
	    } elsif ($name eq "DUMPTYPE") {
		if ($params{'expand_dumptype'} && $data) {
		    my $dumptype = lookup_dumptype($data);
		    if ($dumptype) {
			$values{'DUMPTYPE-DATA'} = Amanda::Rest::Configs::dumptype_object($dumptype, %params);
		    }
		}
	    } elsif ($name eq "HOLDINGDISK") {
		if ($params{'expand_holdingdisk'} && $data) {
		    my $holdingdisk = lookup_holdingdisk($data);
		    if ($holdingdisk) {
			$values{'HOLDINGDISK-DATA'} = Amanda::Rest::Configs::holdingdisk_object($holdingdisk, %params);
		    }
		}
	    } elsif ($name eq "INTERFACE") {
		if ($params{'expand_interface'} && $data) {
		    my $interface = lookup_interface($data);
		    if ($interface) {
			$values{'INTERFACE-DATA'} = Amanda::Rest::Configs::interface_object($interface, %params);
		    }
		}
	    } elsif ($name eq "INTERACTIVITY") {
		if ($params{'expand_interactivity'} && $data) {
		    my $interactivity = lookup_interactivity($data);
		    if ($interactivity) {
			$values{'INTERACTIVITY-DATA'} = Amanda::Rest::Configs::interactivity_object($interactivity, %params);
		    }
		}
	    } elsif ($name eq "POLICY") {
		if ($params{'expand_policy'} && $data) {
		    my $policy = lookup_policy($data);
		    if ($policy) {
			$values{'POLICY-DATA'} = Amanda::Rest::Configs::policy_object($policy, %params);
		    }
		}
	    } elsif ($name eq "TAPERSCAN") {
		if ($params{'expand_taperscan'} && $data) {
		    my $taperscan = lookup_taperscan($data);
		    if ($taperscan) {
			$values{'TAPERSCAN-DATA'} = Amanda::Rest::Configs::taperscan_object($taperscan, %params);
		    }
		}
	    } elsif ($name eq "TAPETYPE") {
		if ($params{'expand_tapetype'} && $data) {
		    my $tapetype = lookup_tapetype($data);
		    if ($tapetype) {
			$values{'TAPETYPE-DATA'} = Amanda::Rest::Configs::tapetype_object($tapetype, %params);
		    }
		}
	    } elsif ($name eq "SCRIPT") {
		if ($params{'expand_script'} && $data) {
		    my @script_data;
		    foreach my $script_name (@$data){
			my $script = lookup_pp_script($script_name);
			if ($script) {
			    push @script_data, Amanda::Rest::Configs::script_object($script, %params);
			}
		    }
		    if (@script_data) {
			$values{'SCRIPT-DATA'} = \@script_data;
		    }
		}
	    } elsif ($name eq "STORAGE") {
		if ($params{'expand_storage'} && $data) {
		    my $storage = lookup_storage($data);
		    if ($storage) {
			$values{'STORAGE-DATA'} = Amanda::Rest::Configs::storage_object($storage, %params);
		    }
		}
	    }
	    $values{$name} = $data;
	    delete $fields{$name};
	}
    }

    return \%values;
}

sub _fields {
    my $NAME = shift;
    my $key = shift;
    my $func_lookup = shift;
    my $func_key_list = shift;
    my $func_key_to_name = shift;
    my $func_getconf_human = shift;
    my $code_success = shift;
    my $code_no = shift;
    my %params = @_;

    my @result_messages;

    my $DATA = $func_lookup->($params{$NAME});
    if (!$DATA) {
	push @result_messages, Amanda::Config::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code         => $code_no,
				severity     => $Amanda::Message::ERROR,
				$key         => $params{$NAME});
	return (-1, \@result_messages);
    }
    my $values = _object($DATA,
			 $func_key_list,
			 $func_key_to_name,
			 $func_getconf_human,
			 %params);
    if (defined $values) {
	push @result_messages, Amanda::Config::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code      => $code_success,
				$key      => $params{$NAME},
				severity  => $Amanda::Message::SUCCESS,
				result    => $values);
    } else {
	push @result_messages, Amanda::Config::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code      => 1500009,
				$key      => $params{$NAME},
				severity => $Amanda::Message::WARNING);
    }
    return (-1, \@result_messages);
}

sub list {
    my %params = @_;
    my @result_messages;
    my $status = -1;

    Amanda::Util::set_pname("Amanda::Rest::Configs");
    if (!opendir(my $dh, $Amanda::Paths::CONFIG_DIR)) {
	push @result_messages, Amanda::Config::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code     => 1500006,
				severity => $Amanda::Message::ERROR,
				errno    => $!,
				dir      => $Amanda::Paths::CONFIG_DIR);
	$status = 404;
    } else {
	my @conf = grep { !/^\./ && -f "$Amanda::Paths::CONFIG_DIR/$_/amanda.conf" } readdir($dh);
	closedir($dh);
	if (@conf) {
	    push @result_messages, Amanda::Config::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code     => 1500003,
				severity => $Amanda::Message::SUCCESS,
				config   => \@conf);
	} else {
	    push @result_messages, Amanda::Config::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code     => 1500004,
				severity => $Amanda::Message::ERROR);
	    $status = 404;
	}
    }
    return ($status, \@result_messages);
}

sub fields {
    my %params = @_;

    Amanda::Util::set_pname("Amanda::Rest::Configs");
    my ($status, @result_messages) = Amanda::Rest::Configs::config_init(@_);
    return ($status, \@result_messages) if @result_messages;

    my %fields;
    my %values;
    if (defined $params{'fields'}) {
	my $type = Scalar::Util::reftype($params{'fields'});
	if (defined $type and $type eq "ARRAY") {
	    foreach my $name (@{$params{'fields'}}) {
		$name = uc($name);
		$name =~ s/_/-/g;
		$fields{$name} = 1;
	    }
	} elsif (!defined $type and defined $params{'fields'} and $params{'fields'} ne '') {
	    my $name = $params{'fields'};
	    $name = uc($name);
	    $name =~ s/_/-/g;
	    $fields{$name} = 1;
	}
    }
    my @keys = Amanda::Config::confparm_key_list();
    foreach my $key (@keys) {
	my $name = Amanda::Config::confparm_key_to_name($key);
	if ($name) {
	    $name =~ s/_/-/g;
	    if ((!defined $params{'fields'}) ||
		((defined $fields{$name}) && ($fields{$name} == 1))) {
		my $data = getconf_human($key);
		$values{$name} = $data;
		delete $fields{$name};
	    }
	}
    }

    for my $field (keys %fields) {
	push @result_messages, Amanda::Config::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code      => 1500058,
				severity => $Amanda::Message::ERROR,
				field => $field);
    }

    if (%values) {
	push @result_messages, Amanda::Config::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code      => 1500008,
				severity => $Amanda::Message::SUCCESS,
				result    => \%values);
    } else {
	push @result_messages, Amanda::Config::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code      => 1500009,
				severity => $Amanda::Message::WARNING);
    }
    return (-1, \@result_messages);
}

sub applications_list {
    Amanda::Util::set_pname("Amanda::Rest::Configs");
    my ($status, @result_messages) = Amanda::Rest::Configs::config_init(@_);
    return ($status, \@result_messages) if @result_messages;

    ($status, @result_messages) = Amanda::Rest::Configs::config_read_disklist(@_);
    return ($status, \@result_messages) if @result_messages;

    my @list = Amanda::Config::getconf_list("application");
    push @result_messages, Amanda::Config::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code     => 1500024,
				severity => $Amanda::Message::SUCCESS,
				applications_list   => \@list);

    return (-1, \@result_messages);
}

sub devices_list {
    Amanda::Util::set_pname("Amanda::Rest::Configs");
    my ($status, @result_messages) = Amanda::Rest::Configs::config_init(@_);
    return ($status, \@result_messages) if @result_messages;

    my @list = Amanda::Config::getconf_list("device");
    push @result_messages, Amanda::Config::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code     => 1500025,
				severity => $Amanda::Message::SUCCESS,
				devices_list   => \@list);

    return (-1, \@result_messages);
}

sub dumptypes_list {
    Amanda::Util::set_pname("Amanda::Rest::Configs");
    my ($status, @result_messages) = Amanda::Rest::Configs::config_init(@_);
    return ($status, \@result_messages) if @result_messages;

    ($status, @result_messages) = Amanda::Rest::Configs::config_read_disklist(@_);
    return ($status, \@result_messages) if @result_messages;

    my @list = Amanda::Config::getconf_list("dumptype");
    push @result_messages, Amanda::Config::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code     => 1500022,
				severity => $Amanda::Message::SUCCESS,
				dumptypes_list   => \@list);

    return (-1, \@result_messages);
}

sub changers_list {
    Amanda::Util::set_pname("Amanda::Rest::Configs");
    my ($status, @result_messages) = Amanda::Rest::Configs::config_init(@_);
    return ($status, \@result_messages) if @result_messages;

    my @list = Amanda::Config::getconf_list("changer");
    push @result_messages, Amanda::Config::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code     => 1500026,
				severity => $Amanda::Message::SUCCESS,
				changers_list   => \@list);

    return (-1, \@result_messages);
}

sub holdingdisks_list {
    Amanda::Util::set_pname("Amanda::Rest::Configs");
    my ($status, @result_messages) = Amanda::Rest::Configs::config_init(@_);
    return ($status, \@result_messages) if @result_messages;

    my @list = Amanda::Config::getconf_list("holdingdisk");
    push @result_messages, Amanda::Config::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code     => 1500029,
				severity => $Amanda::Message::SUCCESS,
				holdingdisks_list   => \@list);

    return (-1, \@result_messages);
}

sub interactivitys_list {
    Amanda::Util::set_pname("Amanda::Rest::Configs");
    my ($status, @result_messages) = Amanda::Rest::Configs::config_init(@_);
    return ($status, \@result_messages) if @result_messages;

    my @list = Amanda::Config::getconf_list("interactivity");
    push @result_messages, Amanda::Config::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code     => 1500031,
				severity => $Amanda::Message::SUCCESS,
				interactivitys_list   => \@list);

    return (-1, \@result_messages);
}

sub interfaces_list {
    Amanda::Util::set_pname("Amanda::Rest::Configs");
    my ($status, @result_messages) = Amanda::Rest::Configs::config_init(@_);
    return ($status, \@result_messages) if @result_messages;

    my @list = Amanda::Config::getconf_list("interface");
    push @result_messages, Amanda::Config::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code     => 1500030,
				severity => $Amanda::Message::SUCCESS,
				interfaces_list   => \@list);

    return (-1, \@result_messages);
}

sub policys_list {
    Amanda::Util::set_pname("Amanda::Rest::Configs");
    my ($status, @result_messages) = Amanda::Rest::Configs::config_init(@_);
    return ($status, \@result_messages) if @result_messages;

    my @list = Amanda::Config::getconf_list("policy");
    push @result_messages, Amanda::Config::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code     => 1500033,
				severity => $Amanda::Message::SUCCESS,
				policys_list   => \@list);

    return (-1, \@result_messages);
}

sub taperscans_list {
    Amanda::Util::set_pname("Amanda::Rest::Configs");
    my ($status, @result_messages) = Amanda::Rest::Configs::config_init(@_);
    return ($status, \@result_messages) if @result_messages;

    my @list = Amanda::Config::getconf_list("taperscan");
    push @result_messages, Amanda::Config::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code     => 1500032,
				severity => $Amanda::Message::SUCCESS,
				taperscans_list   => \@list);

    return (-1, \@result_messages);
}

sub tapetypes_list {
    Amanda::Util::set_pname("Amanda::Rest::Configs");
    my ($status, @result_messages) = Amanda::Rest::Configs::config_init(@_);
    return ($status, \@result_messages) if @result_messages;

    my @list = Amanda::Config::getconf_list("tapetype");
    push @result_messages, Amanda::Config::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code     => 1500023,
				severity => $Amanda::Message::SUCCESS,
				tapetypes_list   => \@list);

    return (-1, \@result_messages);
}

sub scripts_list {
    Amanda::Util::set_pname("Amanda::Rest::Configs");
    my ($status, @result_messages) = Amanda::Rest::Configs::config_init(@_);
    return ($status, \@result_messages) if @result_messages;

    ($status, @result_messages) = Amanda::Rest::Configs::config_read_disklist(@_);
    return ($status, \@result_messages) if @result_messages;

    my @list = Amanda::Config::getconf_list("script");
    push @result_messages, Amanda::Config::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code     => 1500028,
				severity => $Amanda::Message::SUCCESS,
				scripts_list   => \@list);

    return (-1, \@result_messages);
}

sub storages_list {
    Amanda::Util::set_pname("Amanda::Rest::Configs");
    my ($status, @result_messages) = Amanda::Rest::Configs::config_init(@_);
    return ($status, \@result_messages) if @result_messages;

    my @list = Amanda::Config::getconf_list("storage");
    push @result_messages, Amanda::Config::Message->new(
				source_filename => __FILE__,
				source_line     => __LINE__,
				code     => 1500027,
				severity => $Amanda::Message::SUCCESS,
				storages_list   => \@list);

    return (-1, \@result_messages);
}

sub application_fields {
    my %params = @_;

    Amanda::Util::set_pname("Amanda::Rest::Configs");
    my ($status, @result_messages) = Amanda::Rest::Configs::config_init(@_);
    return ($status, \@result_messages) if @result_messages;

    ($status, @result_messages) = Amanda::Rest::Configs::config_read_disklist(@_);
    return ($status, \@result_messages) if @result_messages;

    return _fields("APPLICATION", "application",
		   \&Amanda::Config::lookup_application,
		   \&Amanda::Config::application_key_list,
		   \&Amanda::Config::application_key_to_name,
		   \&Amanda::Config::application_getconf_human,
		   1500039, 1500049, @_);
}

sub changer_fields {
    my %params = @_;

    Amanda::Util::set_pname("Amanda::Rest::Configs");
    my ($status, @result_messages) = Amanda::Rest::Configs::config_init(@_);
    return ($status, \@result_messages) if @result_messages;

    return _fields("CHANGER", "changer",
		   \&Amanda::Config::lookup_changer_config,
		   \&Amanda::Config::changer_config_key_list,
		   \&Amanda::Config::changer_config_key_to_name,
		   \&Amanda::Config::changer_config_getconf_human,
		   1500041, 1500051, @_);
}

sub device_fields {
    my %params = @_;

    Amanda::Util::set_pname("Amanda::Rest::Configs");
    my ($status, @result_messages) = Amanda::Rest::Configs::config_init(@_);
    return ($status, \@result_messages) if @result_messages;

    return _fields("DEVICE", "device",
		   \&Amanda::Config::lookup_device_config,
		   \&Amanda::Config::device_config_key_list,
		   \&Amanda::Config::device_config_key_to_name,
		   \&Amanda::Config::device_config_getconf_human,
		   1500040, 1500050, @_);
}

sub dumptype_fields {
    my %params = @_;

    Amanda::Util::set_pname("Amanda::Rest::Configs");
    my ($status, @result_messages) = Amanda::Rest::Configs::config_init(@_);
    return ($status, \@result_messages) if @result_messages;

    ($status, @result_messages) = Amanda::Rest::Configs::config_read_disklist(@_);
    return ($status, \@result_messages) if @result_messages;

    return _fields("DUMPTYPE", "dumptype",
		   \&Amanda::Config::lookup_dumptype,
		   \&Amanda::Config::dumptype_key_list,
		   \&Amanda::Config::dumptype_key_to_name,
		   \&Amanda::Config::dumptype_getconf_human,
		   1500037, 1500034, @_);
}

sub holdingdisk_fields {
    my %params = @_;

    Amanda::Util::set_pname("Amanda::Rest::Configs");
    my ($status, @result_messages) = Amanda::Rest::Configs::config_init(@_);
    return ($status, \@result_messages) if @result_messages;

    return _fields("HOLDINGDISK", "holdingdisk",
		   \&Amanda::Config::lookup_holdingdisk,
		   \&Amanda::Config::holdingdisk_key_list,
		   \&Amanda::Config::holdingdisk_key_to_name,
		   \&Amanda::Config::holdingdisk_getconf_human,
		   1500043, 1500053, @_);
}

sub interactivity_fields {
    my %params = @_;

    Amanda::Util::set_pname("Amanda::Rest::Configs");
    my ($status, @result_messages) = Amanda::Rest::Configs::config_init(@_);
    return ($status, \@result_messages) if @result_messages;

    return _fields("INTERACTIVITY", "interactivity",
		   \&Amanda::Config::lookup_interactivity,
		   \&Amanda::Config::interactivity_key_list,
		   \&Amanda::Config::interactivity_key_to_name,
		   \&Amanda::Config::interactivity_getconf_human,
		   1500045, 1500055, @_);
}

sub interface_fields {
    my %params = @_;

    Amanda::Util::set_pname("Amanda::Rest::Configs");
    my ($status, @result_messages) = Amanda::Rest::Configs::config_init(@_);
    return ($status, \@result_messages) if @result_messages;

    return _fields("INTERFACE", "interface",
		   \&Amanda::Config::lookup_interface,
		   \&Amanda::Config::interface_key_list,
		   \&Amanda::Config::interface_key_to_name,
		   \&Amanda::Config::interface_getconf_human,
		   1500044, 1500054, @_);
}

sub policy_fields {
    my %params = @_;

    Amanda::Util::set_pname("Amanda::Rest::Configs");
    my ($status, @result_messages) = Amanda::Rest::Configs::config_init(@_);
    return ($status, \@result_messages) if @result_messages;

    return _fields("POLICY", "policy",
		   \&Amanda::Config::lookup_policy,
		   \&Amanda::Config::policy_key_list,
		   \&Amanda::Config::policy_key_to_name,
		   \&Amanda::Config::policy_getconf_human,
		   1500047, 1500057, @_);
}

sub script_fields {
    my %params = @_;

    Amanda::Util::set_pname("Amanda::Rest::Configs");
    my ($status, @result_messages) = Amanda::Rest::Configs::config_init(@_);
    return ($status, \@result_messages) if @result_messages;

    ($status, @result_messages) = Amanda::Rest::Configs::config_read_disklist(@_);
    return ($status, \@result_messages) if @result_messages;

    return _fields("SCRIPT", "script",
		   \&Amanda::Config::lookup_pp_script,
		   \&Amanda::Config::pp_script_key_list,
		   \&Amanda::Config::pp_script_key_to_name,
		   \&Amanda::Config::pp_script_getconf_human,
		   1500042, 1500052, @_);
}

sub storage_fields {
    my %params = @_;

    Amanda::Util::set_pname("Amanda::Rest::Configs");
    my ($status, @result_messages) = Amanda::Rest::Configs::config_init(@_);
    return ($status, \@result_messages) if @result_messages;

    ($status, @result_messages) = Amanda::Rest::Configs::config_read_disklist(@_);
    return ($status, \@result_messages) if @result_messages;

    return _fields("STORAGE", "storage",
		   \&Amanda::Config::lookup_storage,
		   \&Amanda::Config::storage_key_list,
		   \&Amanda::Config::storage_key_to_name,
		   \&Amanda::Config::storage_getconf_human,
		   1500036, 1500048, @_);
}

sub taperscan_fields {
    my %params = @_;

    Amanda::Util::set_pname("Amanda::Rest::Configs");
    my ($status, @result_messages) = Amanda::Rest::Configs::config_init(@_);
    return ($status, \@result_messages) if @result_messages;

    return _fields("TAPERSCAN", "taperscan",
		   \&Amanda::Config::lookup_taperscan,
		   \&Amanda::Config::taperscan_key_list,
		   \&Amanda::Config::taperscan_key_to_name,
		   \&Amanda::Config::taperscan_getconf_human,
		   1500046, 1500056, @_);
}

sub tapetype_fields {
    my %params = @_;

    Amanda::Util::set_pname("Amanda::Rest::Configs");
    my ($status, @result_messages) = Amanda::Rest::Configs::config_init(@_);
    return ($status, \@result_messages) if @result_messages;

    ($status, @result_messages) = Amanda::Rest::Configs::config_read_disklist(@_);
    return ($status, \@result_messages) if @result_messages;

    return _fields("TAPETYPE", "tapetype",
		   \&Amanda::Config::lookup_tapetype,
		   \&Amanda::Config::tapetype_key_list,
		   \&Amanda::Config::tapetype_key_to_name,
		   \&Amanda::Config::tapetype_getconf_human,
		   1500038, 1500035, @_);
}

sub application_object {
    my $application = shift;

    return _object($application,
		   \&Amanda::Config::application_key_list,
		   \&Amanda::Config::application_key_to_name,
		   \&Amanda::Config::application_getconf_human, @_);

}

sub device_object {
    my $device = shift;

    return _object($device,
		   \&Amanda::Config::device_config_key_list,
		   \&Amanda::Config::device_config_key_to_name,
		   \&Amanda::Config::device_config_getconf_human, @_);

}

sub dumptype_object {
    my $dumptype = shift;

    return _object($dumptype,
		   \&Amanda::Config::dumptype_key_list,
		   \&Amanda::Config::dumptype_key_to_name,
		   \&Amanda::Config::dumptype_getconf_human, @_);

}

sub changer_object {
    my $changer = shift;

    return _object($changer,
		   \&Amanda::Config::changer_config_key_list,
		   \&Amanda::Config::changer_config_key_to_name,
		   \&Amanda::Config::changer_config_getconf_human, @_);

}

sub holdingdisk_object {
    my $holdingdisk = shift;

    return _object($holdingdisk,
		   \&Amanda::Config::holdingdisk_key_list,
		   \&Amanda::Config::holdingdisk_key_to_name,
		   \&Amanda::Config::holdingdisk_getconf_human, @_);

}

sub interactivity_object {
    my $interactivity = shift;

    return _object($interactivity,
		   \&Amanda::Config::interactivity_key_list,
		   \&Amanda::Config::interactivity_key_to_name,
		   \&Amanda::Config::interactivity_getconf_human, @_);

}

sub interface_object {
    my $interface = shift;

    return _object($interface,
		   \&Amanda::Config::interface_key_list,
		   \&Amanda::Config::interface_key_to_name,
		   \&Amanda::Config::interface_getconf_human, @_);

}

sub policy_object {
    my $policy = shift;

    return _object($policy,
		   \&Amanda::Config::policy_key_list,
		   \&Amanda::Config::policy_key_to_name,
		   \&Amanda::Config::policy_getconf_human, @_);

}

sub script_object {
    my $script = shift;

    return _object($script,
		   \&Amanda::Config::pp_script_key_list,
		   \&Amanda::Config::pp_script_key_to_name,
		   \&Amanda::Config::pp_script_getconf_human, @_);

}

sub storage_object {
    my $storage = shift;

    return _object($storage,
		   \&Amanda::Config::storage_key_list,
		   \&Amanda::Config::storage_key_to_name,
		   \&Amanda::Config::storage_getconf_human, @_);

}

sub taperscan_object {
    my $taperscan = shift;

    return _object($taperscan,
		   \&Amanda::Config::taperscan_key_list,
		   \&Amanda::Config::taperscan_key_to_name,
		   \&Amanda::Config::taperscan_getconf_human, @_);

}

sub tapetype_object {
    my $tapetype = shift;

    return _object($tapetype,
		   \&Amanda::Config::tapetype_key_list,
		   \&Amanda::Config::tapetype_key_to_name,
		   \&Amanda::Config::tapetype_getconf_human, @_);

}

1;
