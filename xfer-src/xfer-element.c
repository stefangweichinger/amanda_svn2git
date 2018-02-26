/*
 * Amanda, The Advanced Maryland Automatic Network Disk Archiver
 * Copyright (c) 2008-2012 Zmanda, Inc.  All Rights Reserved.
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

/* parent class for XferElement */
static GObjectClass *parent_class = NULL;

/* parent class for XferDest, XferFilter, and XferSource */
static XferElementClass *xfer_element_class = NULL;

/***********************
 * XferElement */

static void
xfer_element_init(
    XferElement *xe)
{
    xe->xfer = NULL;
    xe->output_mech = XFER_MECH_NONE;
    xe->input_mech = XFER_MECH_NONE;
    xe->upstream = xe->downstream = NULL;
    xe->_input_fd = xe->_output_fd = -1;
    xe->repr = NULL;
    xe->must_drain = FALSE;
    xe->cancel_on_success = FALSE;
    xe->ignore_broken_pipe = FALSE;
}

static gboolean
xfer_element_setup_impl(
    XferElement *elt G_GNUC_UNUSED)
{
    return TRUE; /* success */
}

static gboolean
xfer_element_set_offset_impl(
    XferElement *elt,
    gint64       offset)
{

    elt->offset = offset;

    return TRUE; /* success */
}

static gboolean
xfer_element_set_size_impl(
    XferElement *elt,
    gint64       size)
{
    elt->orig_size = size;
    elt->size = size;

    return TRUE; /* success */
}

static off_t
xfer_element_get_offset_impl(
    XferElement *elt)
{
    return elt->offset;
}

static off_t
xfer_element_get_orig_size_impl(
    XferElement *elt)
{
    return elt->orig_size;
}

static off_t
xfer_element_get_size_impl(
    XferElement *elt)
{
    return elt->size;
}

static size_t
xfer_element_get_block_size_impl(
    XferElement *elt)
{
    return elt->block_size;
}

static gboolean
xfer_element_start_impl(
    XferElement *elt G_GNUC_UNUSED)
{
    return FALSE; /* will not send XMSG_DONE */
}

static gboolean
xfer_element_cancel_impl(
    XferElement *elt,
    gboolean expect_eof)
{
    elt->cancelled = TRUE;
    elt->expect_eof = expect_eof;
    return elt->can_generate_eof;
}

static gpointer
xfer_element_pull_buffer_impl(
    XferElement *elt G_GNUC_UNUSED,
    size_t *size G_GNUC_UNUSED)
{
    *size = 0;
    return NULL;
}

static gpointer
xfer_element_pull_buffer_static_impl(
    XferElement *elt G_GNUC_UNUSED,
    gpointer buf G_GNUC_UNUSED,
    size_t block_size G_GNUC_UNUSED,
    size_t *size G_GNUC_UNUSED)
{
    *size = 0;
    return NULL;
}

static void
xfer_element_push_buffer_impl(
    XferElement *elt G_GNUC_UNUSED,
    gpointer buf G_GNUC_UNUSED,
    size_t size G_GNUC_UNUSED)
{
}

static void
xfer_element_push_buffer_static_impl(
    XferElement *elt G_GNUC_UNUSED,
    gpointer buf G_GNUC_UNUSED,
    size_t size G_GNUC_UNUSED)
{
}

static xfer_element_mech_pair_t *
xfer_element_get_mech_pairs_impl(
    XferElement *elt)
{
    return XFER_ELEMENT_GET_CLASS(elt)->mech_pairs;
}

static char *
xfer_element_repr_impl(
    XferElement *elt)
{
    if (!elt->repr) {
        g_free(elt->repr);
        elt->repr = g_strdup_printf("<%s@%p>",
                                    G_OBJECT_TYPE_NAME(G_OBJECT(elt)), elt);
    }

    return elt->repr;
}

static void
xfer_element_finalize(
    GObject * obj_self)
{
    XferElement *elt = XFER_ELEMENT(obj_self);
    gint fd;

    /* free the repr cache */
    if (elt->repr) g_free(elt->repr);

    /* close up the input/output file descriptors, being careful to do so
     * atomically, and making any errors doing so into mere warnings */
    fd = xfer_element_swap_input_fd(elt, -1);
    if (fd != -1 && close(fd) != 0)
	g_warning("error closing fd %d: %s", fd, strerror(errno));
    fd = xfer_element_swap_output_fd(elt, -1);
    if (fd != -1 && close(fd) != 0)
	g_warning("error closing fd %d: %s", fd, strerror(errno));

    /* chain up */
    G_OBJECT_CLASS(parent_class)->finalize(obj_self);
}

static void
xfer_element_class_init(
    XferElementClass * klass)
{
    GObjectClass *goc = (GObjectClass*) klass;

    klass->repr = xfer_element_repr_impl;
    klass->setup = xfer_element_setup_impl;
    klass->set_offset = xfer_element_set_offset_impl;
    klass->set_size = xfer_element_set_size_impl;
    klass->get_offset = xfer_element_get_offset_impl;
    klass->get_orig_size = xfer_element_get_orig_size_impl;
    klass->get_size = xfer_element_get_size_impl;
    klass->get_block_size = xfer_element_get_block_size_impl;
    klass->start = xfer_element_start_impl;
    klass->cancel = xfer_element_cancel_impl;
    klass->pull_buffer = xfer_element_pull_buffer_impl;
    klass->pull_buffer_static = xfer_element_pull_buffer_static_impl;
    klass->push_buffer = xfer_element_push_buffer_impl;
    klass->push_buffer_static = xfer_element_push_buffer_static_impl;
    klass->get_mech_pairs = xfer_element_get_mech_pairs_impl;

    goc->finalize = xfer_element_finalize;

    klass->perl_class = NULL;

    parent_class = g_type_class_peek_parent(klass);
    xfer_element_class = klass;
}

GType
xfer_element_get_type(void)
{
    static GType type = 0;

    if (G_UNLIKELY(type == 0)) {
        static const GTypeInfo info = {
            sizeof (XferElementClass),
            (GBaseInitFunc) NULL,
            (GBaseFinalizeFunc) NULL,
            (GClassInitFunc) xfer_element_class_init,
            (GClassFinalizeFunc) NULL,
            NULL /* class_data */,
            sizeof (XferElement),
            0 /* n_preallocs */,
            (GInstanceInitFunc) xfer_element_init,
            NULL
        };

        type = g_type_register_static (G_TYPE_OBJECT, "XferElement", &info,
                                       (GTypeFlags)G_TYPE_FLAG_ABSTRACT);
    }

    return type;
}

/*
 * Method stubs
 */

void
xfer_element_unref(
    XferElement *elt)
{
    if (elt) g_object_unref(elt);
}

char *
xfer_element_repr(
    XferElement *elt)
{
    return XFER_ELEMENT_GET_CLASS(elt)->repr(elt);
}

gboolean
xfer_element_setup(
    XferElement *elt)
{
    return XFER_ELEMENT_GET_CLASS(elt)->setup(elt);
}

gboolean
xfer_element_set_offset(
    XferElement *elt,
    gint64       offset)
{
    return XFER_ELEMENT_GET_CLASS(elt)->set_offset(elt, offset);
}

gboolean
xfer_element_set_size(
    XferElement *elt,
    gint64       size)
{
    return XFER_ELEMENT_GET_CLASS(elt)->set_size(elt, size);
}

off_t
xfer_element_get_offset(
    XferElement *elt)
{
    return XFER_ELEMENT_GET_CLASS(elt)->get_offset(elt);
}

off_t
xfer_element_get_orig_size(
    XferElement *elt)
{
    return XFER_ELEMENT_GET_CLASS(elt)->get_orig_size(elt);
}

off_t
xfer_element_get_size(
    XferElement *elt)
{
    return XFER_ELEMENT_GET_CLASS(elt)->get_size(elt);
}

size_t
xfer_element_get_block_size(
    XferElement *elt)
{
    return XFER_ELEMENT_GET_CLASS(elt)->get_block_size(elt);
}

gboolean
xfer_element_start(
    XferElement *elt)
{
    return XFER_ELEMENT_GET_CLASS(elt)->start(elt);
}

gboolean
xfer_element_cancel(
    XferElement *elt,
    gboolean expect_eof)
{
    return XFER_ELEMENT_GET_CLASS(elt)->cancel(elt, expect_eof);
}

gpointer
xfer_element_pull_buffer(
    XferElement *elt,
    size_t *size)
{
    xfer_status status;
    /* Make sure that the xfer is running before calling upstream's
     * pull_buffer method; this avoids a race condition where upstream
     * hasn't finished its xfer_element_start yet, and isn't ready for
     * a pull */
    g_mutex_lock(elt->xfer->status_mutex);
    status = elt->xfer->status;
    g_mutex_unlock(elt->xfer->status_mutex);
    if (status == XFER_START)
	wait_until_xfer_running(elt->xfer);

    return XFER_ELEMENT_GET_CLASS(elt)->pull_buffer(elt, size);
}

gpointer
xfer_element_pull_buffer_static(
    XferElement *elt,
    gpointer buf,
    size_t block_size,
    size_t *size)
{
    xfer_status status;
    /* Make sure that the xfer is running before calling upstream's
     * pull_bufferi_static method; this avoids a race condition where upstream
     * hasn't finished its xfer_element_start yet, and isn't ready for
     * a pull */
    g_mutex_lock(elt->xfer->status_mutex);
    status = elt->xfer->status;
    g_mutex_unlock(elt->xfer->status_mutex);
    if (status == XFER_START)
	wait_until_xfer_running(elt->xfer);

    return XFER_ELEMENT_GET_CLASS(elt)->pull_buffer_static(elt, buf, block_size, size);
}

void
xfer_element_push_buffer(
    XferElement *elt,
    gpointer buf,
    size_t size)
{
    /* There is no race condition with push_buffer, because downstream
     * elements are started first. */
    XFER_ELEMENT_GET_CLASS(elt)->push_buffer(elt, buf, size);
}

void
xfer_element_push_buffer_static(
    XferElement *elt,
    gpointer buf,
    size_t size)
{
    /* There is no race condition with push_buffer, because downstream
     * elements are started first. */
    XFER_ELEMENT_GET_CLASS(elt)->push_buffer_static(elt, buf, size);
}

xfer_element_mech_pair_t *
xfer_element_get_mech_pairs(
	XferElement *elt)
{
    return XFER_ELEMENT_GET_CLASS(elt)->get_mech_pairs(elt);
}

/****
 * Utilities
 */

void
xfer_element_drain_buffers(
    XferElement *upstream)
{
    gpointer buf;
    size_t size;

    while ((buf =xfer_element_pull_buffer(upstream, &size))) {
	amfree(buf);
    }
}

void
xfer_element_drain_fd(
    int fd)
{
    size_t len;
    char buf[1024];

    while (1) {
	len = read_fully(fd, buf, sizeof(buf), NULL);
	if (len < sizeof(buf))
	    return;
    }
}

mem_ring_t *
xfer_element_get_mem_ring(
    XferElement *elt)
{
    return XFER_ELEMENT_GET_CLASS(elt)->get_mem_ring(elt);
}

shm_ring_t *
xfer_element_get_shm_ring(
    XferElement *elt)
{
    if (elt->shm_ring) {
	return elt->shm_ring;
    } else if (elt->downstream) {
	return xfer_element_get_shm_ring(elt->downstream);
    } else {
	return NULL;
    }
}

