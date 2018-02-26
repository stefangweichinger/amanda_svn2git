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
#include "xfer-device.h"

static GObjectClass *parent_class = NULL;

/*
 * Method implementation
 */

static void
cache_inform_impl(
    XferDestTaper *self G_GNUC_UNUSED,
    const char *filename G_GNUC_UNUSED,
    off_t offset G_GNUC_UNUSED,
    off_t length G_GNUC_UNUSED)
{
    /* do nothing */
}

static void
instance_init(
    XferElement *elt)
{
    elt->can_generate_eof = FALSE;
}

static void
class_init(
    XferDestTaperClass * selfc)
{
    XferElementClass *klass = XFER_ELEMENT_CLASS(selfc);

    selfc->cache_inform = cache_inform_impl;

    klass->perl_class = "Amanda::Xfer::Dest::Taper";

    parent_class = g_type_class_peek_parent(selfc);
}

GType
xfer_dest_taper_get_type (void)
{
    static GType type = 0;

    if (G_UNLIKELY(type == 0)) {
        static const GTypeInfo info = {
            sizeof (XferDestTaperClass),
            (GBaseInitFunc) NULL,
            (GBaseFinalizeFunc) NULL,
            (GClassInitFunc) class_init,
            (GClassFinalizeFunc) NULL,
            NULL /* class_data */,
            sizeof (XferDestTaper),
            0 /* n_preallocs */,
            (GInstanceInitFunc) instance_init,
            NULL
        };

        type = g_type_register_static (XFER_ELEMENT_TYPE, "XferDestTaper", &info, 0);
    }

    return type;
}

/*
 * Method stubs
 */

void
xfer_dest_taper_start_part(
    XferElement *elt,
    gboolean retry_part,
    dumpfile_t *header)
{
    XferDestTaperClass *klass;
    g_assert(IS_XFER_DEST_TAPER(elt));

    klass = XFER_DEST_TAPER_GET_CLASS(elt);
    klass->start_part(XFER_DEST_TAPER(elt), retry_part, header);
}

void
xfer_dest_taper_use_device(
    XferElement *elt,
    Device *device)
{
    XferDestTaperClass *klass;
    g_assert(IS_XFER_DEST_TAPER(elt));

    klass = XFER_DEST_TAPER_GET_CLASS(elt);
    klass->use_device(XFER_DEST_TAPER(elt), device);
}

void
xfer_dest_taper_cache_inform(
    XferElement *elt,
    const char *filename,
    off_t offset,
    off_t length)
{
    XferDestTaperClass *klass;
    g_assert(IS_XFER_DEST_TAPER(elt));

    klass = XFER_DEST_TAPER_GET_CLASS(elt);
    klass->cache_inform(XFER_DEST_TAPER(elt), filename, offset, length);
}

guint64
xfer_dest_taper_get_part_bytes_written(
    XferElement *elt G_GNUC_UNUSED)
{
    XferDestTaperClass *klass;
    g_assert(IS_XFER_DEST_TAPER(elt));

    klass = XFER_DEST_TAPER_GET_CLASS(elt);
    if (klass->get_part_bytes_written)
	return klass->get_part_bytes_written(XFER_DEST_TAPER(elt));
    else
	return 0;
}

void
xfer_dest_taper_new_space_available(
    XferElement *elt,
    int          made_space)
{
    XferDestTaperClass *klass;
    g_assert(IS_XFER_DEST_TAPER(elt));

    klass = XFER_DEST_TAPER_GET_CLASS(elt);
    if (klass->new_space_available)
	klass->new_space_available(XFER_DEST_TAPER(elt), made_space);
}
