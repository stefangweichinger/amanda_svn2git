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
 * $Id: stream.h,v 1.12 2006/06/01 14:44:05 martinea Exp $
 *
 * interface to stream module
 */
#ifndef STREAM_H
#define STREAM_H

#include "amanda.h"

#define NETWORK_BLOCK_BYTES	DISK_BLOCK_BYTES
#define STREAM_BUFSIZE		(NETWORK_BLOCK_BYTES * 4)

int stream_server(int family, in_port_t *port, size_t sendsize,
		  size_t recvsize, int priv);
int stream_accept(int sock, int timeout, size_t sendsize, size_t recvsize);
int stream_client_addr(const char *src_ip,
		       struct addrinfo *res,
		       in_port_t port,
		       size_t sendsize,
		       size_t recvsize,
		       in_port_t *localport,
		       int nonblock,
		       int priv,
		       char **stream_msg);
int stream_client_privileged(const char *src_ip,
				const char *hostname,
				in_port_t port,
				size_t sendsize,
				size_t recvsize,
				in_port_t *localport,
				int nonblock,
				char **stream_msg);
int stream_client(const char *src_ip,
		     const char *hostname,
		     in_port_t port,
		     size_t sendsize,
		     size_t recvsize,
		     in_port_t *localport,
		     int nonblock,
		     char **stream_msg);

#endif
