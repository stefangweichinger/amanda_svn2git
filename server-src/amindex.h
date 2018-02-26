/*
 * Amanda, The Advanced Maryland Automatic Network Disk Archiver
 * Copyright (c) 1991-1998 University of Maryland at College Park
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
 * Author: James da Silva, Systems Design and Analysis Group
 *			   Computer Science Department
 *			   University of Maryland at College Park
 */
/*
 * $Id: amindex.h,v 1.8 2006/05/25 01:47:19 johnfranks Exp $
 *
 * headers for index control
 */
#ifndef AMINDEX_H
#define AMINDEX_H

#include "amanda.h"
#include "conffile.h"

char *getstatefname(char *host, char *disk, char *date, int level);
char *getindexfname(char *host, char *disk, char *date, int level);
char *getindex_unsorted_fname(char *host, char *disk, char *date, int level);
char *getindex_unsorted_gz_fname(char *host, char *disk, char *date, int level);
char *getindex_sorted_fname(char *host, char *disk, char *date, int level);
char *getindex_sorted_gz_fname(char *host, char *disk, char *date, int level);
char *getheaderfname(char *host, char *disk, char *date, int level);
char *getoldindexfname(char *host, char *disk, char *date, int level);

#endif /* AMINDEX_H */
