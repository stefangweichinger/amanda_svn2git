/*
 * Amanda, The Advanced Maryland Automatic Network Disk Archiver
 * Copyright (c) 1991-1999 University of Maryland at College Park
 * Copyright (c) 2007-2012 Zmanda, Inc.  All Rights Reserved.
 * Copyright (c) 2013-2016 Carbonite, Inc.  All Rights Reserved.
 * All Rights Reserved.
 *
 * Permission to use, copy, modify, distribute, and sell this software and its
 * documentation for any purpose is hereby granted without fee, provided that
 * the above copyright notice appear in all copies and that both that
 * copyright notice and this permission notice appear in supporting
 * documentation, and that the name of U.M. not be used in advertising or
 * publicity pertaining to distribution of the software without specific,
 * written prior permission.  U.M. makes no representations about the
 * suitability of this software for any purpose.  It is provided "as is"
 * without express or implied warranty.
 *
 * U.M. DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE, INCLUDING ALL
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS, IN NO EVENT SHALL U.M.
 * BE LIABLE FOR ANY SPECIAL, INDIRECT OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION
 * OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
 * CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 * Authors: the Amanda Development Team.  Its members are listed in a
 * file named AUTHORS, in the root directory of this distribution.
 */
/*
 * $Id$
 *
 * Date and time utility functions
 */

#ifndef TIMESTAMP_H
#define TIMESTAMP_H

#include "amanda.h"

/* These functions do the opposite; they formats a time_t for
   network or media storage. The return value is allocated with
   malloc(). If time == 0, then these functions will use the current
   time. */
char * get_timestamp_from_time(time_t time);
char * get_datestamp_from_time(time_t time);
char * get_proper_stamp_from_time(time_t time);
time_t get_time_from_timestamp(char *timestamp);

typedef enum {
    TIME_STATE_REPLACE,
    TIME_STATE_UNDEF,
    TIME_STATE_SET
} time_state_t;

/* Returns the state of a timestamp. */
time_state_t get_timestamp_state(char * timestamp);

/* Returns a "X" timestamp. */
char * get_undef_timestamp(void);

#endif /* TIMESTAMP_H */

