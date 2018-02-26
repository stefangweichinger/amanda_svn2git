# Copyright (c) 2009-2012 Zmanda Inc.  All Rights Reserved.
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

=head1 NAME

Amanda::Taper::Protocol

=head1 DESCRIPTION

This package is a component of the Amanda taper, and is not intended for use by
other scripts or applications.

This package define the protocol between the taper and the driver, it is
used by L<Amanda::Taper::Controller> and L<Amanda::Taper::Worker>

=cut

use strict;
use warnings;

package Amanda::Taper::Protocol;

use Amanda::IPC::LineProtocol;
use base "Amanda::IPC::LineProtocol";

use constant START_TAPER => message("START-TAPER",
    format => [ qw( taper_name worker_name storage timestamp ) ],
);

use constant PORT_WRITE => message("PORT-WRITE",
    format => [ qw( worker_name handle hostname diskname level datestamp
	    dle_tape_splitsize dle_split_diskbuffer dle_fallback_splitsize dle_allow_split
	    part_size part_cache_type part_cache_dir part_cache_max_size
	    data_path ) ],
);

use constant SHM_WRITE => message("SHM-WRITE",
    format => [ qw( worker_name handle hostname diskname level datestamp
	    dle_tape_splitsize dle_split_diskbuffer dle_fallback_splitsize dle_allow_split
	    part_size part_cache_type part_cache_dir part_cache_max_size
	    data_path ) ],
);

use constant FILE_WRITE => message("FILE-WRITE",
    format => [ qw( worker_name handle filename hostname diskname level datestamp
	    dle_tape_splitsize dle_split_diskbuffer dle_fallback_splitsize dle_allow_split
	    part_size part_cache_type part_cache_dir part_cache_max_size
	    orig_kb) ],
);

use constant VAULT_WRITE => message("VAULT-WRITE",
    format => [ qw( worker_name handle src_storage src_pool src_label
		    hostname diskname level datestamp
		    dle_tape_splitsize dle_split_diskbuffer
		    dle_fallback_splitsize dle_allow_split
		    part_size part_cache_type part_cache_dir part_cache_max_size
		    orig_kb) ],
);

use constant START_SCAN => message("START-SCAN",
    format => [ qw( worker_name handle ) ],
);

use constant NEW_TAPE => message("NEW-TAPE",
    format => {
	in => [ qw( worker_name handle ) ],
	out => [ qw( worker_name handle label ) ],
    },
);

use constant NO_NEW_TAPE => message("NO-NEW-TAPE",
    format => {
	in => [ qw( worker_name handle reason ) ],
	out => [ qw( worker_name handle ) ],
    }
);

use constant FAILED => message("FAILED",
    format => {
	in => [ qw( worker_name handle ) ],
	out => [ qw( worker_name handle input taper inputerr tapererr ) ],
    },
);

use constant DONE => message("DONE",
    format => {
	in => [ qw( worker_name handle orig_kb native_crc client_crc server_crc) ],
	out => [ qw( worker_name handle input taper server_crc stats inputerr tapererr ) ],
    },
);

use constant QUIT => message("QUIT",
    on_eof => 1,
);

use constant TAPER_OK => message("TAPER-OK",
    format => [ qw( worker_name allow_take_scribe_from ) ],
);

use constant TAPE_ERROR => message("TAPE-ERROR",
    format => [ qw( worker_name message ) ],
);

use constant PARTIAL => message("PARTIAL",
    format => [ qw( worker_name handle input taper server_crc stats inputerr tapererr ) ],
);

use constant PARTDONE => message("PARTDONE",
    format => [ qw( worker_name handle label fileno kb stats ) ],
);

use constant REQUEST_NEW_TAPE => message("REQUEST-NEW-TAPE",
    format => [ qw( worker_name handle ) ],
);

use constant PORT => message("PORT",
    format => [ qw( worker_name handle port ipports ) ],
);

use constant SHM_NAME => message("SHM-NAME",
    format => [ qw( worker_name handle port shm_name ) ],
);

use constant BAD_COMMAND => message("BAD-COMMAND",
    format => [ qw( message ) ],
);

use constant TAKE_SCRIBE_FROM => message("TAKE-SCRIBE-FROM",
    format => [ qw( worker_name handle from_worker_name) ],
);

use constant DUMPER_STATUS => message("DUMPER-STATUS",
    format => [ qw( worker_name handle ) ],
);

use constant CLOSE_VOLUME => message("CLOSE-VOLUME",
    format => [ qw( worker_name ) ],
);

use constant CLOSED_VOLUME => message("CLOSED-VOLUME",
    format => [ qw( worker_name ) ],
);

use constant OPENED_SOURCE_VOLUME => message("OPENED-SOURCE-VOLUME",
    format => [ qw( worker_name handle label ) ],
);

use constant CLOSE_SOURCE_VOLUME => message("CLOSE-SOURCE-VOLUME",
    format => [ qw( worker_name ) ],
);

use constant CLOSED_SOURCE_VOLUME => message("CLOSED-SOURCE-VOLUME",
    format => [ qw( worker_name ) ],
);

use constant READY => message("READY",
    format => [ qw( worker_name handle ) ],
);

1;
