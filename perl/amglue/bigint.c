/*
 * Copyright (c) 2007-2012 Zmanda, Inc.  All Rights Reserved.
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

#include "amglue.h"
#include "stdint.h"

/*
 * C -> Perl
 */

/* these functions are only needed if Perl has 32-bit IV's */
/* Make sure Math::BigInt is loaded
 */
static void
load_Math_BigInt(void)
{
    static int loaded = 0;

    if (loaded) return;

    eval_pv("use Math::BigInt; use Amanda::BigIntCompat;", 1);
    loaded = 1;
}

/* Given a string, create a Math::BigInt representing its value.
 *
 * @param num: string representation of a number
 * @returns: BigInt representation of the same number
 */
static SV *
str2bigint(char *num)
{
    int count;
    SV *rv;
    dSP;

    ENTER;
    SAVETMPS;

    load_Math_BigInt();
    SPAGAIN;

    EXTEND(SP, 2);
    PUSHMARK(SP);
    XPUSHs(sv_2mortal(newSVpv("Math::BigInt", 0)));
    XPUSHs(sv_2mortal(newSVpv(num, 0)));
    PUTBACK;

    count = call_method("new", G_SCALAR);

    SPAGAIN;

    if (count != 1)
	croak("Expected a result from Math::Bigint->new");

    rv = POPs;
    SvREFCNT_inc(rv);

    PUTBACK;
    FREETMPS;
    LEAVE;

    return rv;
}

SV *
amglue_newSVi64(gint64 v)
{
    char numstr[25];
    g_snprintf(numstr, sizeof(numstr), "%jd", (intmax_t)v);
    numstr[sizeof(numstr)-1] = '\0';
    return str2bigint(numstr);
}

SV *
amglue_newSVu64(guint64 v)
{
    char numstr[25];
    g_snprintf(numstr, sizeof(numstr), "%ju", (uintmax_t)v);
    numstr[sizeof(numstr)-1] = '\0';
    return str2bigint(numstr);
}

/*
 * Perl -> C
 */

/* Conversion from Perl values handles BigInts regardless of whether
 * Perl's IVs are 32- or 64-bit, for completeness' sake.
 */

/* Convert a bigint to a signed integer, or croak trying.
 *
 * @param bigint: the perl object to convert
 * @returns: signed integer
 */
static gint64
bigint2int64(SV *bigint, gchar **err)
{
    SV *sv;
    char *str;
    guint64 absval;
    gboolean negative = FALSE;
    int count;
    dSP;

    /* first, see if it's a BigInt */
    if (!sv_isobject(bigint) || !sv_derived_from(bigint, "Math::BigInt")) {
	*err = g_strdup("Expected an integer or a Math::BigInt; cannot convert");
	return 0;
    }

    ENTER;
    SAVETMPS;

    /* get the value:
     * strtoull($bigint->bstr()) */

    PUSHMARK(SP);
    XPUSHs(bigint);
    PUTBACK;

    count = call_method("Math::BigInt::bstr", G_SCALAR);

    SPAGAIN;

    if (count != 1)
	croak("Expected a result from Math::BigInt::bstr");

    sv = POPs;
    str = SvPV_nolen(sv);
    if (!str)
	croak("Math::BigInt::bstr did not return a string");

    if (str[0] == '-') {
	negative = TRUE;
	str++;
    }

    errno = 0;
    absval = g_ascii_strtoull(str, NULL, 0);
    /* (the last branch of this || depends on G_MININT64 = -G_MAXINT64-1) */
    if ((absval == G_MAXUINT64 && errno == ERANGE)
        || (!negative && absval > (guint64)(G_MAXINT64))
	|| (negative && absval > (guint64)(G_MAXINT64)+1))
	croak("Expected a signed 64-bit value or smaller; value '%s' out of range", str);
    if (errno)
	croak("Math::BigInt->bstr returned invalid number '%s'", str);

    PUTBACK;
    FREETMPS;
    LEAVE;

    if (negative) return -absval;
    return absval;
}

/* Convert bigint to an unsigned integer, or croak trying.
 *
 * @param bigint: the perl object to convert
 * @returns: unsigned integer
 */
static guint64
bigint2uint64(SV *bigint, gchar **err)
{
    SV *sv;
    char *str;
    guint64 rv;
    int count;
    dSP;

    /* first, see if it's a BigInt */
    if (!sv_isobject(bigint) || !sv_derived_from(bigint, "Math::BigInt")) {
	*err = g_strdup("Expected an integer or a Math::BigInt; cannot convert");
	return 0;
    }

    ENTER;
    SAVETMPS;

    /* make sure the bigint is positive:
     * croak(..) unless $bigint->sign() eq "+"; */

    PUSHMARK(SP);
    XPUSHs(bigint);
    PUTBACK;

    count = call_method("Math::BigInt::sign", G_SCALAR);

    SPAGAIN;

    if (count != 1)
	croak("Expected a result from Math::BigInt::sign");

    sv = POPs;
    str = SvPV_nolen(sv);
    if (!str)
	croak("Math::BigInt::sign did not return a string");

    if (strcmp(str, "+") != 0)
	croak("Expected a positive number; value out of range");

    /* get the value:
     * strtoull($bigint->bstr()) */

    PUSHMARK(SP);
    XPUSHs(bigint);
    PUTBACK;

    count = call_method("Math::BigInt::bstr", G_SCALAR);

    SPAGAIN;

    if (count != 1)
	croak("Expected a result from Math::BigInt::bstr");

    sv = POPs;
    str = SvPV_nolen(sv);
    if (!str)
	croak("Math::BigInt::bstr did not return a string");

    errno = 0;
    rv = g_ascii_strtoull(str, NULL, 0);
    if (rv == G_MAXUINT64 && errno == ERANGE)
	croak("Expected an unsigned 64-bit value or smaller; value '%s' out of range", str);
    if (errno)
	croak("Math::BigInt->bstr returned invalid number '%s'", str);

    PUTBACK;
    FREETMPS;
    LEAVE;

    return rv;
}

gint64 amglue_SvI64(SV *sv, gchar **err)
{
    if (SvIOK(sv)) {
	if (SvIsUV(sv)) {
	    return SvUV(sv);
	} else {
	    return SvIV(sv);
	}
    } else if (SvNOK(sv)) {
	double dv = SvNV(sv);

	/* preprocessor constants seem to have trouble here, so we convert to gint64 and
	 * back, and if the result differs, then we have lost something.  Note that this will
	 * also error out on integer truncation .. which is probably OK */
	gint64 iv = (gint64)dv;
	if (dv != (double)iv) {
	    *err = g_strdup_printf("Expected a signed 64-bit value or smaller; value '%.0f' out of range", (float)dv);
	    return 0;
	} else {
	    return iv;
	}
    } else {
	return bigint2int64(sv, err);
    }
}

guint64 amglue_SvU64(SV *sv, gchar **err)
{
    if (SvIOK(sv)) {
	if (SvIsUV(sv)) {
	    return SvUV(sv);
	} else if (SvIV(sv) < 0) {
	    *err = g_strdup("Expected an unsigned value, got a negative integer");
	    return 0;
	} else {
	    return (guint64)SvIV(sv);
	}
    } else if (SvNOK(sv)) {
	double dv = SvNV(sv);
	if (dv < 0.0) {
	    *err = g_strdup("Expected an unsigned value, got a negative integer");
	    return 0;
	} else if (dv > (double)G_MAXUINT64) {
	    *err = g_strdup("Expected an unsigned 64-bit value or smaller; value out of range");
	    return 0;
	} else {
	    return (guint64)dv;
	}
    } else {
	return bigint2uint64(sv, err);
    }
}

gint32 amglue_SvI32(SV *sv, gchar **err)
{
    gint64 v64 = amglue_SvI64(sv, err);
    if (v64 < G_MININT32 || v64 > G_MAXINT32) {
	*err = g_strdup("Expected a 32-bit integer; value out of range");
	return 0;
    } else {
	return (gint32)v64;
    }
}

guint32 amglue_SvU32(SV *sv, gchar **err)
{
    guint64 v64 = amglue_SvU64(sv, err);
    if (v64 > G_MAXUINT32) {
	*err = g_strdup("Expected a 32-bit unsigned integer; value out of range");
	return 0;
    } else {
	return (guint32)v64;
    }
}

gint16 amglue_SvI16(SV *sv, gchar **err)
{
    gint64 v64 = amglue_SvI64(sv, err);
    if (v64 < G_MININT16 || v64 > G_MAXINT16) {
	*err = g_strdup("Expected a 16-bit integer; value out of range");
	return 0;
    } else {
	return (gint16)v64;
    }
}

guint16 amglue_SvU16(SV *sv, gchar **err)
{
    guint64 v64 = amglue_SvU64(sv, err);
    if (v64 > G_MAXUINT16) {
	*err = g_strdup("Expected a 16-bit unsigned integer; value out of range");
	return 0;
    } else {
	return (guint16)v64;
    }
}

gint8 amglue_SvI8(SV *sv, gchar **err)
{
    gint64 v64 = amglue_SvI64(sv, err);
    if (v64 < G_MININT8 || v64 > G_MAXINT8) {
	*err = g_strdup("Expected a 8-bit integer; value out of range");
	return 0;
    } else {
	return (gint8)v64;
    }
}

guint8 amglue_SvU8(SV *sv, gchar **err)
{
    guint64 v64 = amglue_SvU64(sv, err);
    if (v64 > G_MAXUINT8) {
	*err = g_strdup("Expected a 8-bit unsigned integer; value out of range");
	return 0;
    } else {
	return (guint8)v64;
    }
}

