/*
 * Amanda, The Advanced Maryland Automatic Network Disk Archiver
 * Copyright (c) 2009-2012 Zmanda, Inc.  All Rights Reserved.
 * Copyright (c) 2013-2016 Carbonite, Inc.  All Rights Reserved.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
 * or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
 * for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, write to the Free Software Foundation, Inc.,
 * 59 Temple Place, Suite 330, Boston, MA  02111-1307 USA
 *
 * Contact information: Carbonite Inc., 756 N Pastoria Ave
 * Sunnyvale, CA 94085, or: http://www.zmanda.com
 */

#include "amanda.h"
#include "amxfer.h"
#include "device.h"
#include "property.h"
#include "xfer-device.h"
#include "conffile.h"

/*
 * Class declaration
 *
 * This declaration is entirely private; nothing but xfer_source_recovery() references
 * it directly.
 */

GType xfer_source_recovery_get_type(void);
#define XFER_SOURCE_RECOVERY_TYPE (xfer_source_recovery_get_type())
#define XFER_SOURCE_RECOVERY(obj) G_TYPE_CHECK_INSTANCE_CAST((obj), xfer_source_recovery_get_type(), XferSourceRecovery)
#define XFER_SOURCE_RECOVERY_CONST(obj) G_TYPE_CHECK_INSTANCE_CAST((obj), xfer_source_recovery_get_type(), XferSourceRecovery const)
#define XFER_SOURCE_RECOVERY_CLASS(klass) G_TYPE_CHECK_CLASS_CAST((klass), xfer_source_recovery_get_type(), XferSourceRecoveryClass)
#define IS_XFER_SOURCE_RECOVERY(obj) G_TYPE_CHECK_INSTANCE_TYPE((obj), xfer_source_recovery_get_type ())
#define XFER_SOURCE_RECOVERY_GET_CLASS(obj) G_TYPE_INSTANCE_GET_CLASS((obj), xfer_source_recovery_get_type(), XferSourceRecoveryClass)

static GObjectClass *parent_class = NULL;

/*
 * Main object structure
 */

typedef struct XferSourceRecovery {
    XferElement __parent__;

    /* thread for monitoring directtcp transfers */
    GThread *thread;

    /* this mutex in this condition variable governs all variables below */
    GCond  *start_part_cond;
    GMutex *start_part_mutex;

    /* is this device currently paused and awaiting a new part? */
    gboolean paused;

    /* device to read from (refcounted) */
    Device *device;

    /* TRUE if use_device found the device unsuitable; this makes start_part
     * a no-op, allowing the cancellation to be handled normally */
    gboolean device_bad;

    /* directtcp connection (only valid after XMSG_READY) */
    DirectTCPConnection *conn;
    gboolean listen_ok;

    /* and the block size for that device (reset to zero at the start of each
     * part) */
    size_t block_size;

    /* bytes read for this image */
    guint64 bytes_read;

    /* part size (potentially including any zero-padding from the
     * device) */
    guint64 part_size;

    /* timer for the duration; NULL while paused or cancelled */
    GTimer *part_timer;

    gboolean done;

    GCond *abort_cond; /* condition to trigger to abort ndmp command */
} XferSourceRecovery;

/*
 * Class definition
 */

typedef struct {
    XferElementClass __parent__;

    /* start reading the part at which DEVICE is positioned, sending an
     * XMSG_PART_DONE when the part has been read */
    void (*start_part)(XferSourceRecovery *self, Device *device);

    /* use the given device, much like the same method for xfer-dest-taper */
    void (*use_device)(XferSourceRecovery *self, Device *device);
} XferSourceRecoveryClass;

/*
 * Debug Logging
 */

#define DBG(LEVEL, ...) if (debug_recovery >= LEVEL) { _xsr_dbg(__VA_ARGS__); }
static void
_xsr_dbg(const char *fmt, ...)
{
    va_list argp;
    char msg[1024];

    arglist_start(argp, fmt);
    g_vsnprintf(msg, sizeof(msg), fmt, argp);
    arglist_end(argp);
    g_debug("XSR: %s", msg);
}

/*
 * Implementation
 */

/* common code for both directtcp_listen_thread and directtcp_connect_thread;
 * this is called after self->conn is filled in and carries out the data
 * transfer over that connection.  NOTE: start_part_mutex is HELD when this
 * function begins */
static gpointer
directtcp_common_thread(
	XferSourceRecovery *self)
{
    XferElement *elt = XFER_ELEMENT(self);
    char *errmsg = NULL;
    int result;

    /* send XMSG_READY to indicate it's OK to call start_part now */
    DBG(2, "directtcp_common_thread sending XMSG_READY");
    xfer_queue_message(elt->xfer, xmsg_new(elt, XMSG_READY, 0));

    /* now we sit around waiting for signals to write a part */
    while (1) {
	guint64 actual_size;
	XMsg *msg;

	while (self->paused && !elt->cancelled) {
	    DBG(9, "directtcp_common_thread waiting to be un-paused");
	    g_cond_wait(self->start_part_cond, self->start_part_mutex);
	}
	DBG(9, "directtcp_common_thread done waiting");

	if (elt->cancelled) {
	    g_mutex_unlock(self->start_part_mutex);
	    goto close_conn_and_send_done;
	}

	/* if the device is NULL, we're done */
	if (!self->device)
	    break;

	/* read the part */
	self->part_timer = g_timer_new();

	while (1) {
	    DBG(2, "directtcp_common_thread reading part from %s", self->device->device_name);
	    result = device_read_to_connection(self->device, G_MAXUINT64,
			&actual_size, &elt->cancelled,
			self->start_part_mutex, self->abort_cond);
	    if (result == 1 && !elt->cancelled) {
		xfer_cancel_with_error(elt, _("error reading from device: %s"),
		    device_error_or_status(self->device));
		g_mutex_unlock(self->start_part_mutex);
		goto close_conn_and_send_done;
	    } else if (result == 2 || elt->cancelled) {
		g_mutex_unlock(self->start_part_mutex);
		goto close_conn_and_send_done;
	    }

	    /* break on EOF; otherwise do another read_to_connection */
	    if (self->device->is_eof) {
		break;
	    }
	}
	DBG(2, "done reading part; sending XMSG_PART_DONE");

	/* the device has signalled EOF (really end-of-part), so clean up instance
	 * variables and report the EOP to the caller in the form of an xmsg */
	msg = xmsg_new(XFER_ELEMENT(self), XMSG_PART_DONE, 0);
	msg->size = actual_size;
	msg->duration = g_timer_elapsed(self->part_timer, NULL);
	msg->partnum = 0;
	msg->fileno = self->device->file;
	msg->successful = TRUE;
	msg->eof = FALSE;

	self->paused = TRUE;
	g_object_unref(self->device);
	self->device = NULL;
	self->part_size = 0;
	self->block_size = 0;
	g_timer_destroy(self->part_timer);
	self->part_timer = NULL;

	xfer_queue_message(elt->xfer, msg);
    }
    g_mutex_unlock(self->start_part_mutex);

close_conn_and_send_done:
    if (self->conn) {
	errmsg = directtcp_connection_close(self->conn);
	g_object_unref(self->conn);
	self->conn = NULL;
	if (errmsg) {
	    xfer_cancel_with_error(elt, _("error closing DirectTCP connection: %s"), errmsg);
	    wait_until_xfer_cancelled(elt->xfer);
	}
    }

    xfer_queue_message(elt->xfer, xmsg_new(elt, XMSG_DONE, 0));

    return NULL;
}

static gpointer
directtcp_connect_thread(
	gpointer data)
{
    XferSourceRecovery *self = XFER_SOURCE_RECOVERY(data);
    XferElement *elt = XFER_ELEMENT(self);
    int result;

    DBG(1, "(this is directtcp_connect_thread)")

    /* first, we need to accept the incoming connection; we do this while
     * holding the start_part_mutex, so that a part doesn't get started until
     * we're finished with the device */
    g_mutex_lock(self->start_part_mutex);

    if (elt->cancelled) {
	g_mutex_unlock(self->start_part_mutex);
	goto send_done;
    }

    g_assert(self->device != NULL); /* have a device */
    g_assert(elt->output_listen_addrs != NULL); /* listening on it */
    g_assert(self->listen_ok);

    DBG(2, "accepting DirectTCP connection on device %s", self->device->device_name);
    result = device_accept(self->device, &self->conn, &elt->cancelled,
			   self->start_part_mutex, self->abort_cond);
    if (result == 1 && !elt->cancelled) {
	xfer_cancel_with_error(elt,
	    _("error accepting DirectTCP connection: %s"),
	    device_error_or_status(self->device));
	g_mutex_unlock(self->start_part_mutex);
	wait_until_xfer_cancelled(elt->xfer);
	goto send_done;
    } else if (result == 2 || elt->cancelled) {
	g_mutex_unlock(self->start_part_mutex);
	goto send_done;
    }
    DBG(2, "DirectTCP connection accepted");

    return directtcp_common_thread(self);

send_done:
    xfer_queue_message(elt->xfer, xmsg_new(elt, XMSG_DONE, 0));
    return NULL;
}

static gpointer
directtcp_listen_thread(
	gpointer data)
{
    XferSourceRecovery *self = XFER_SOURCE_RECOVERY(data);
    XferElement *elt = XFER_ELEMENT(self);
    int result;

    DBG(1, "(this is directtcp_listen_thread)");

    /* we need to make an outgoing connection to downstream; we do this while
     * holding the start_part_mutex, so that a part doesn't get started until
     * we're finished with the device */
    g_mutex_lock(self->start_part_mutex);

    if (elt->cancelled) {
	g_mutex_unlock(self->start_part_mutex);
	goto send_done;
    }

    g_assert(self->device != NULL); /* have a device */
    g_assert(elt->downstream->input_listen_addrs != NULL); /* downstream listening */

    DBG(2, "making DirectTCP connection on device %s", self->device->device_name);
    result = device_connect(self->device, FALSE,
			    elt->downstream->input_listen_addrs,
			    &self->conn, &elt->cancelled,
			    self->start_part_mutex, self->abort_cond);
    if (result == 1 && !elt->cancelled) {
	xfer_cancel_with_error(elt,
	    _("error making DirectTCP connection: %s"),
	    device_error_or_status(self->device));
	g_mutex_unlock(self->start_part_mutex);
	wait_until_xfer_cancelled(elt->xfer);
	goto send_done;
    } else if (result == 2 || elt->cancelled) {
	g_mutex_unlock(self->start_part_mutex);
	wait_until_xfer_cancelled(elt->xfer);
	goto send_done;
    }
    DBG(2, "DirectTCP connect succeeded");

    return directtcp_common_thread(self);

send_done:
    xfer_queue_message(elt->xfer, xmsg_new(elt, XMSG_DONE, 0));
    return NULL;
}

static gboolean
setup_impl(
    XferElement *elt)
{
    XferSourceRecovery *self = XFER_SOURCE_RECOVERY(elt);

    if (elt->output_mech == XFER_MECH_DIRECTTCP_CONNECT) {
	g_assert(self->device != NULL);
	DBG(2, "listening for DirectTCP connection on device %s", self->device->device_name);
	if (!device_listen(self->device, FALSE, &elt->output_listen_addrs)) {
	    xfer_cancel_with_error(elt,
		_("error listening for DirectTCP connection: %s"),
		device_error_or_status(self->device));
	    return FALSE;
	}
	self->listen_ok = TRUE;
    } else {
	/* no output_listen_addrs for either XFER_MECH_DIRECTTCP_LISTEN or
	 * XFER_MECH_PULL_BUFFER */
	elt->output_listen_addrs = NULL;
    }

    return TRUE;
}

static gboolean
start_impl(
    XferElement *elt)
{
    XferSourceRecovery *self = XFER_SOURCE_RECOVERY(elt);

    if (elt->output_mech == XFER_MECH_DIRECTTCP_CONNECT) {
	g_assert(elt->output_listen_addrs != NULL);
	self->thread = g_thread_create(directtcp_connect_thread, (gpointer)self, FALSE, NULL);
	return TRUE; /* we'll send XMSG_DONE */
    } else if (elt->output_mech == XFER_MECH_DIRECTTCP_LISTEN) {
	g_assert(elt->output_listen_addrs == NULL);
	self->thread = g_thread_create(directtcp_listen_thread, (gpointer)self, FALSE, NULL);
	return TRUE; /* we'll send XMSG_DONE */
    } else {
	/* nothing to prepare for - we're ready already! */
	DBG(2, "not using DirectTCP: sending XMSG_READY immediately");
	xfer_queue_message(elt->xfer, xmsg_new(elt, XMSG_READY, 0));

	return FALSE; /* we won't send XMSG_DONE */
    }
}

static gpointer
pull_buffer_impl(
    XferElement *elt,
    size_t *size)
{
    XferSourceRecovery *self = XFER_SOURCE_RECOVERY(elt);
    gpointer buf = NULL;
    int result;
    int devsize;
    XMsg *msg;

    g_assert(elt->output_mech == XFER_MECH_PULL_BUFFER);

    g_mutex_lock(self->start_part_mutex);

    if (elt->size == 0) {
	if (elt->offset == 0 && elt->orig_size == 0) {
	    self->paused = TRUE;
	} else {
	    DBG(2, "xfer-source-recovery sending XMSG_CRC message");
	    DBG(2, "xfer-source-recovery CRC: %08x     size %lld",
		crc32_finish(&elt->crc), (long long)elt->crc.size);
	    msg = xmsg_new(XFER_ELEMENT(self), XMSG_CRC, 0);
	    msg->crc = crc32_finish(&elt->crc);
	    msg->size = elt->crc.size;
	    xfer_queue_message(elt->xfer, msg);

	    /* the device has signalled EOF (really end-of-part), so clean up instance
	     * variables and report the EOP to the caller in the form of an xmsg */
	    DBG(2, "pull_buffer hit EOF; sending XMSG_SEGMENT_DONE");
	    msg = xmsg_new(XFER_ELEMENT(self), XMSG_SEGMENT_DONE, 0);
	    msg->size = self->part_size;
	    if (self->part_timer) {
		msg->duration = g_timer_elapsed(self->part_timer, NULL);
		g_timer_destroy(self->part_timer);
		self->part_timer = NULL;
	    }
	    msg->partnum = 0;
	    msg->fileno = self->device->file;
	    msg->successful = TRUE;
	    msg->eof = FALSE;

	    self->paused = TRUE;
	    device_clear_bytes_read(self->device);
	    self->bytes_read += self->part_size;
	    self->part_size = 0;
	    self->block_size = 0;

	    /* don't queue the XMSG_PART_DONE until we've adjusted all of our
	     * instance variables appropriately */
	    xfer_queue_message(elt->xfer, msg);

	    if (self->device->is_eof) {
		DBG(2, "pull_buffer hit EOF; sending XMSG_PART_DONE");
		msg = xmsg_new(XFER_ELEMENT(self), XMSG_PART_DONE, 0);
		msg->size = self->part_size;
		if (self->part_timer) {
		    msg->duration = g_timer_elapsed(self->part_timer, NULL);
		    g_timer_destroy(self->part_timer);
		    self->part_timer = NULL;
		}
		msg->partnum = 0;
		msg->fileno = self->device->file;
		msg->successful = TRUE;
		msg->eof = FALSE;

		xfer_queue_message(elt->xfer, msg);
	    }
	}
    }

    while (1) {
	/* make sure we have a device */
	while (self->paused && !elt->cancelled)
	    g_cond_wait(self->start_part_cond, self->start_part_mutex);

	/* indicate EOF on an cancel or when there are no more parts */
	if (elt->cancelled) {
            goto error;
	}
	if (self->done)
	    goto error;

	/* start the timer if this is the first pull_buffer of this part */
	if (!self->part_timer) {
	    DBG(2, "first pull_buffer of new part");
	    self->part_timer = g_timer_new();
	}
	if (elt->size == 0) {
	    result = -1;
	} else {
	    /* loop until we read a full block, in case the blocks are larger
	     * than  expected */
	    if (self->block_size == 0)
		self->block_size = (size_t)self->device->block_size;

	    do {
		int max_block;
		buf = g_malloc(self->block_size);
		if (buf == NULL) {
		    xfer_cancel_with_error(elt,
				_("%s: cannot allocate memory"),
				self->device->device_name);
		    g_mutex_unlock(self->start_part_mutex);
		    wait_until_xfer_cancelled(elt->xfer);
		    goto error_unlocked;
		}
		devsize = (int)self->block_size;
		if (elt->size < 0)
		    max_block = -1;
		else
		    max_block = (elt->size+self->block_size-1)/self->block_size;
		result = device_read_block(self->device, buf, &devsize, max_block);
		*size = devsize;

		if (result == 0) {
		    g_assert(*size > self->block_size);
		    self->block_size = devsize;
		    amfree(buf);
		}
	    } while (result == 0);

	    if (result > 0 &&
		(elt->offset ||
		 (elt->size > 0 && (long long unsigned)elt->size < *size))) {
		gpointer buf1 = g_malloc(self->block_size);
		if ((long long unsigned)elt->offset > *size) {
		    g_debug("offset > *size");
		} else if ((long long unsigned)elt->offset == *size) {
		    g_debug("offset == *size");
		}
		*size -= elt->offset;
		if (elt->size > 0 && (size_t)elt->size < *size)
		    *size = elt->size;
		memmove(buf1, buf + elt->offset, *size);
		elt->offset = 0;
		g_free(buf);
		buf = buf1;
	    }
	    if (result > 0)
		elt->size -= *size;

	}

	/* if this block was successful, return it */
	if (result > 0) {
	    self->part_size += *size;
	    break;
	}

	if (result < 0) {
	    amfree(buf);

	    /* if we're not at EOF, it's an error */
	    if (!self->device->is_eof && elt->size != 0) {
		g_mutex_unlock(self->start_part_mutex);
		xfer_cancel_with_error(elt,
		    _("error reading from %s: %s"),
		    self->device->device_name,
		    device_error_or_status(self->device));
		wait_until_xfer_cancelled(elt->xfer);
                goto error_unlocked;
	    }

	    DBG(2, "xfer-source-recovery sending XMSG_CRC message");
	    DBG(2, "xfer-source-recovery CRC: %08x     size %lld",
		crc32_finish(&elt->crc), (long long)elt->crc.size);
	    msg = xmsg_new(XFER_ELEMENT(self), XMSG_CRC, 0);
	    msg->crc = crc32_finish(&elt->crc);
	    msg->size = elt->crc.size;
	    xfer_queue_message(elt->xfer, msg);

	    /* the device has signalled EOF (really end-of-part), so clean up instance
	     * variables and report the EOP to the caller in the form of an xmsg */
	    DBG(2, "pull_buffer hit EOF; sending XMSG_PART_DONE");
	    msg = xmsg_new(XFER_ELEMENT(self), XMSG_PART_DONE, 0);
	    msg->size = self->part_size;
	    msg->duration = g_timer_elapsed(self->part_timer, NULL);
	    msg->partnum = 0;
	    msg->fileno = self->device->file;
	    msg->successful = TRUE;
	    msg->eof = FALSE;

	    self->paused = TRUE;
	    self->bytes_read += self->part_size;
	    device_clear_bytes_read(self->device);
	    self->part_size = 0;
	    self->block_size = 0;
	    if (self->part_timer) {
		g_timer_destroy(self->part_timer);
		self->part_timer = NULL;
	    }

	    /* don't queue the XMSG_PART_DONE until we've adjusted all of our
	     * instance variables appropriately */
	    xfer_queue_message(elt->xfer, msg);
	    if (elt->size == 0) {
		g_mutex_unlock(self->start_part_mutex);
		return NULL;
	    }
	}
    }

    g_mutex_unlock(self->start_part_mutex);

    if (buf) {
	crc32_add(buf, *size, &elt->crc);
    }

    return buf;
error:
    g_mutex_unlock(self->start_part_mutex);
error_unlocked:
    *size = 0;
    return NULL;
}

static gboolean
cancel_impl(
    XferElement *elt,
    gboolean expect_eof G_GNUC_UNUSED)
{
    XferSourceRecovery *self = XFER_SOURCE_RECOVERY(elt);
    elt->cancelled = TRUE;

    /* trigger the condition variable, in case the thread is waiting on it */
    g_mutex_lock(self->start_part_mutex);
    g_cond_broadcast(self->start_part_cond);
    g_cond_broadcast(self->abort_cond);
    g_mutex_unlock(self->start_part_mutex);

    return TRUE;
}

static void
start_part_impl(
    XferSourceRecovery *self,
    Device *device)
{
    XferElement *elt = XFER_ELEMENT(self);

    g_assert(!device || device->in_file);

    DBG(2, "start_part called");

    if (self->device_bad) {
	/* use_device didn't like the device it got, but the xfer cancellation
	 * has not completed yet, so do nothing */
	return;
    }

    g_mutex_lock(self->start_part_mutex);

    /* make sure we're ready to go */
    g_assert(self->paused || self->done);
    self->done = FALSE;
    if (XFER_ELEMENT(self)->output_mech == XFER_MECH_DIRECTTCP_CONNECT
     || XFER_ELEMENT(self)->output_mech == XFER_MECH_DIRECTTCP_LISTEN) {
	g_assert(self->conn != NULL);
    }

    /* if we already have a device, it should have been given to use_device */
    if (device && self->device) {
	g_assert(self->device == device);
    } else if (device) {
	self->device = device;
	g_object_ref(device);
    }

    if (!device)
	self->done = TRUE;

    if (elt->offset == 0 && elt->orig_size == 0) {
	self->done = TRUE;
	g_mutex_unlock(self->start_part_mutex);
	return;
    }

    if (elt->size == 0) {
	self->done = TRUE;
	g_mutex_unlock(self->start_part_mutex);
	return;
    }

    self->paused = FALSE;

    DBG(2, "triggering condition variable");
    g_cond_broadcast(self->start_part_cond);
    g_mutex_unlock(self->start_part_mutex);
}

static void
use_device_impl(
    XferSourceRecovery *xdtself,
    Device *device)
{
    XferSourceRecovery *self = XFER_SOURCE_RECOVERY(xdtself);

    g_assert(self->paused);

    /* short-circuit if nothing is changing */
    if (self->device == device)
	return;

    if (self->device)
	g_object_unref(self->device);
    self->device = NULL;

    /* if we already have a connection, then make this device use it */
    if (self->conn) {
	if (!device_use_connection(device, self->conn)) {
	    /* queue up an error for later, and set device_bad.
	     * start_part will see this and fail silently */
	    self->device_bad = TRUE;
	    xfer_cancel_with_error(XFER_ELEMENT(self),
		_("Cannot continue onto new volume: %s"),
		device_error_or_status(device));
	    return;
	}
    }

    self->device = device;
    g_object_ref(device);
}

static xfer_element_mech_pair_t *
get_mech_pairs_impl(
    XferElement *elt)
{
    XferSourceRecovery *self = XFER_SOURCE_RECOVERY(elt);
    static xfer_element_mech_pair_t basic_mech_pairs[] = {
	{ XFER_MECH_NONE, XFER_MECH_PULL_BUFFER, XFER_NROPS(1), XFER_NTHREADS(0), XFER_NALLOC(0) },
	{ XFER_MECH_NONE, XFER_MECH_NONE, XFER_NROPS(0), XFER_NTHREADS(0), XFER_NALLOC(0) }
    };
    static xfer_element_mech_pair_t directtcp_mech_pairs[] = {
	{ XFER_MECH_NONE, XFER_MECH_DIRECTTCP_CONNECT, XFER_NROPS(0), XFER_NTHREADS(1), XFER_NALLOC(0) },
	{ XFER_MECH_NONE, XFER_MECH_DIRECTTCP_LISTEN, XFER_NROPS(0), XFER_NTHREADS(1), XFER_NALLOC(0) },
	/* devices which support DirectTCP are usually not very efficient
	 * at delivering data via device_read_block, so this counts an extra
	 * byte operation in the cost metrics (2 here vs. 1 in basic_mech_pairs).
	 * This is a hack, but it will do for now. */
	{ XFER_MECH_NONE, XFER_MECH_PULL_BUFFER, XFER_NROPS(2), XFER_NTHREADS(0), XFER_NALLOC(0) },
	{ XFER_MECH_NONE, XFER_MECH_NONE, XFER_NROPS(0), XFER_NTHREADS(0), XFER_NALLOC(0) },
    };

    return device_directtcp_supported(self->device)?
	directtcp_mech_pairs : basic_mech_pairs;
}

static void
finalize_impl(
    GObject * obj_self)
{
    XferSourceRecovery *self = XFER_SOURCE_RECOVERY(obj_self);

    if (self->conn)
	g_object_unref(self->conn);
    if (self->device)
	g_object_unref(self->device);

    g_cond_free(self->start_part_cond);
    g_cond_free(self->abort_cond);
    g_mutex_free(self->start_part_mutex);
}

static void
instance_init(
    XferElement *elt)
{
    XferSourceRecovery *self = XFER_SOURCE_RECOVERY(elt);

    self->paused = TRUE;
    self->start_part_cond = g_cond_new();
    self->abort_cond = g_cond_new();
    self->start_part_mutex = g_mutex_new();
    crc32_init(&elt->crc);
}

static void
class_init(
    XferSourceRecoveryClass * xsr_klass)
{
    XferElementClass *klass = XFER_ELEMENT_CLASS(xsr_klass);
    GObjectClass *gobject_klass = G_OBJECT_CLASS(xsr_klass);

    klass->pull_buffer = pull_buffer_impl;
    klass->cancel = cancel_impl;
    klass->start = start_impl;
    klass->setup = setup_impl;
    klass->get_mech_pairs = get_mech_pairs_impl;

    klass->perl_class = "Amanda::Xfer::Source::Recovery";
    klass->mech_pairs = NULL; /* see get_mech_pairs_impl, above */

    xsr_klass->start_part = start_part_impl;
    xsr_klass->use_device = use_device_impl;

    gobject_klass->finalize = finalize_impl;

    parent_class = g_type_class_peek_parent(xsr_klass);
}

GType
xfer_source_recovery_get_type (void)
{
    static GType type = 0;

    if (G_UNLIKELY(type == 0)) {
        static const GTypeInfo info = {
            sizeof (XferSourceRecoveryClass),
            (GBaseInitFunc) NULL,
            (GBaseFinalizeFunc) NULL,
            (GClassInitFunc) class_init,
            (GClassFinalizeFunc) NULL,
            NULL /* class_data */,
            sizeof (XferSourceRecovery),
            0 /* n_preallocs */,
            (GInstanceInitFunc) instance_init,
            NULL
        };

        type = g_type_register_static (XFER_ELEMENT_TYPE, "XferSourceRecovery", &info, 0);
    }

    return type;
}

/*
 * Public methods and stubs
 */

void
xfer_source_recovery_start_part(
    XferElement *elt,
    Device *device)
{
    XferSourceRecoveryClass *klass;
    g_assert(IS_XFER_SOURCE_RECOVERY(elt));

    klass = XFER_SOURCE_RECOVERY_GET_CLASS(elt);
    klass->start_part(XFER_SOURCE_RECOVERY(elt), device);
}

gboolean
xfer_source_recovery_cancel(
    XferElement *elt,
    gboolean expect_eof G_GNUC_UNUSED)
{
    XferElementClass *klass;
    g_assert(IS_XFER_SOURCE_RECOVERY(elt));

    klass = XFER_ELEMENT_GET_CLASS(elt);
    return klass->cancel(XFER_ELEMENT(elt), 0);
}

/* create an element of this class; prototype is in xfer-device.h */
XferElement *
xfer_source_recovery(Device *first_device)
{
    XferSourceRecovery *self = (XferSourceRecovery *)g_object_new(XFER_SOURCE_RECOVERY_TYPE, NULL);
    XferElement *elt = XFER_ELEMENT(self);

    g_assert(first_device != NULL);
    g_object_ref(first_device);
    self->device = first_device;

    return elt;
}

void
xfer_source_recovery_use_device(
    XferElement *elt,
    Device *device)
{
    XferSourceRecoveryClass *klass;
    g_assert(IS_XFER_SOURCE_RECOVERY(elt));

    klass = XFER_SOURCE_RECOVERY_GET_CLASS(elt);
    klass->use_device(XFER_SOURCE_RECOVERY(elt), device);
}

guint64
xfer_source_recovery_get_bytes_read(
    XferElement *elt)
{
    XferSourceRecovery *self = XFER_SOURCE_RECOVERY(elt);
    guint64 bytes_read = self->bytes_read;

    if (self->device)
	bytes_read += device_get_bytes_read(self->device);

    return bytes_read;
}

