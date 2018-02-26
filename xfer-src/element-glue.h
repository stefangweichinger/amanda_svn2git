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

#ifndef ELEMENT_GLUE_H
#define ELEMENT_GLUE_H

#include <glib.h>
#include <glib-object.h>
#include "xfer-element.h"
#include "amsemaphore.h"

/*
 * Class declaration
 */

GType xfer_element_glue_get_type(void);
#define XFER_ELEMENT_GLUE_TYPE (xfer_element_glue_get_type())
#define XFER_ELEMENT_GLUE(obj) G_TYPE_CHECK_INSTANCE_CAST((obj), xfer_element_glue_get_type(), XferElementGlue)
#define XFER_ELEMENT_GLUE_CONST(obj) G_TYPE_CHECK_INSTANCE_CAST((obj), xfer_element_glue_get_type(), XferElementGlue const)
#define XFER_ELEMENT_GLUE_CLASS(klass) G_TYPE_CHECK_CLASS_CAST((klass), xfer_element_glue_get_type(), XferElementGlueClass)
#define IS_XFER_ELEMENT_GLUE(obj) G_TYPE_CHECK_INSTANCE_TYPE((obj), xfer_element_glue_get_type ())
#define XFER_ELEMENT_GLUE_GET_CLASS(obj) G_TYPE_INSTANCE_GET_CLASS((obj), xfer_element_glue_get_type(), XferElementGlueClass)

/* Constructor */

XferElement * xfer_element_glue(void);

/* the mech pairs supported by this object */

extern xfer_element_mech_pair_t *xfer_element_glue_mech_pairs;

#endif
