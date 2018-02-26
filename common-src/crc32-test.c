/*
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
 *
 * Author: Dustin J. Mitchell <dustin@zmanda.com>
 */

#include "amanda.h"
#include "testutils.h"
#include "amutil.h"
#include "amcrc32chw.h"

/* Utilities */

#define SIZE_BUF 33819
static uint8_t test_buf[SIZE_BUF];
static size_t size_of_test[] = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 15, 16, 17, 63, 64, 65, 255, 256, 257, 258, 767, 768, 769, 1023, 1024, 1027, 32767, 32768, 32769, 33791, 33792, 33793, 33794, 33795, 33796, 33797, 33798, 33799, 33800, 33801, 33802, 33803, 33804, 33805, 33806, 33807, 33808, 33809, 33810, 33811, 33812, 33813, 33814, 33815, 33816, 33817, 33818, 0 };

static void
init_test_buf(void)
{
    int i;

    for(i=0; i<SIZE_BUF; i++) {
	test_buf[i] = rand();
    }
}

static int
test_size(
    size_t size)
{
    crc_t crc1;
    crc_t crc16;
#ifdef __SSE4_2__
    crc_t crchw;
#endif

    crc32_init(&crc1);
    crc32_init(&crc16);
#ifdef __SSE4_2__
    crc32_init(&crchw);
#endif

    crc32_add_1byte(test_buf, size, &crc1);
    crc32_add_16bytes(test_buf, size, &crc16);
#ifdef __SSE4_2__
    if (have_sse42) {
	crc32c_add_hw(test_buf, size, &crchw);
    }
#endif

#ifdef __SSE4_2__
    g_fprintf(stderr, " %08x:%lld  %08x:%lld  %08x:%lld\n", crc32_finish(&crc1), (long long)crc1.size, crc32_finish(&crc16), (long long)crc16.size, crc32_finish(&crchw), (long long)crchw.size);
#else
    g_fprintf(stderr, " %08x:%lld  %08x:%lld\n", crc32_finish(&crc1), (long long)crc1.size, crc32_finish(&crc16), (long long)crc16.size);
#endif

    if (crc1.crc != crc16.crc ||
	crc1.size != crc16.size) {
	g_fprintf(stderr, " CRC16 %zu %08x:%lld != %08x:%lld\n", size, crc32_finish(&crc1), (long long)crc1.size, crc32_finish(&crc16), (long long)crc16.size);
	return FALSE;
    }
#ifdef __SSE4_2__
    if (have_sse42) {
	if (crc1.crc != crchw.crc ||
	    crc1.size != crchw.size) {
	    g_fprintf(stderr, " CRChw %zu %08x:%lld != %08x:%lld\n", size, crc32_finish(&crc1), (long long)crc1.size, crc32_finish(&crchw), (long long)crchw.size);
	    return FALSE;
	}
    }
#endif
    return TRUE;
}


/*
 * Main driver
 */

int
main(
    int    argc G_GNUC_UNUSED,
    char **argv G_GNUC_UNUSED)
{
    int i;
    int nb_error = 0;

    make_crc_table();
    init_test_buf();

    for (i=0; size_of_test[i] != 0; i++) {
	if (!test_size(size_of_test[i])) {
	    nb_error++;
	}
    }
    if (nb_error) {
	g_fprintf(stderr, " FAIL CRC \n");
    } else {
	g_fprintf(stderr, " PASS CRC\n");
    }
    return nb_error;
}
