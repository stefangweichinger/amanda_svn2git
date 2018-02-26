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

/*
 * Utilities that aren't quite included in glib
 *
 * Author: Dustin J. Mitchell <dustin@zmanda.com>, Ian Turner <ian@zmanda.com>
 */

#include "amanda.h"
#include "glib-util.h"
#include "pthread.h"
#include "conffile.h" /* For find_multiplier. */
#include "shm-ring.h" /* For shm_ring_mutex */
#include "security.h"

#ifdef HAVE_LIBCURL
#include <curl/curl.h>
#endif

#if (defined HAVE_LIBCURL && defined LIBCURL_USE_OPENSSL) || defined SSL_SECURITY
#include <openssl/crypto.h>
#include <openssl/ssl.h>
#if (defined OPENSSL_VERSION_NUMBER && OPENSSL_VERSION_NUMBER < 0x10100000L) \
    || defined LIBRESSL_VERSION_NUMBER
static GMutex **openssl_mutex_array;
static void openssl_lock_callback(int mode, int type, const char *file, int line)
{
    (void)file;
    (void)line;
    if (mode & CRYPTO_LOCK) {
	g_mutex_lock(openssl_mutex_array[type]);
    }
    else {
	g_mutex_unlock(openssl_mutex_array[type]);
    }
}
#endif /* OPENSSL_VERSION_NUMBER */

static void
init_openssl(void)
{
#if (defined OPENSSL_VERSION_NUMBER && OPENSSL_VERSION_NUMBER < 0x10100000L) \
    || defined LIBRESSL_VERSION_NUMBER
    int i;
    openssl_mutex_array = g_new0(GMutex *, CRYPTO_num_locks());

    SSL_library_init();
    for (i=0; i<CRYPTO_num_locks(); i++) {
	openssl_mutex_array[i] = g_mutex_new();
    }
    CRYPTO_set_locking_callback(openssl_lock_callback);
#else
    OPENSSL_init_ssl(0, NULL);
#endif /* OPENSSL_VERSION_NUMBER */

}

#endif /* LIBCURL_USE_OPENSSL */

#if defined HAVE_LIBCURL && defined LIBCURL_USE_GNUTLS_GCRYPT

#include <gcrypt.h>
#include <errno.h>

GCRY_THREAD_OPTION_PTHREAD_IMPL;
static void
init_gnutls_gcrypt(void)
{
    gcry_control(GCRYCTL_SET_THREAD_CBS, &gcry_threads_pthread);

    if (!gcry_check_version (GCRYPT_VERSION)) {
	g_critical("libgcrypt version mismatch");
    }

    gcry_control (GCRYCTL_INITIALIZATION_FINISHED, 0);
}
#endif /* LIBCURL_USE_GNUTLS_GCRYPT */

static void
init_ssl(void)
{

#if (defined HAVE_LIBCURL && defined LIBCURL_USE_OPENSSL) || defined SSL_SECURITY
    init_openssl();
#endif
#if defined HAVE_LIBCURL && defined LIBCURL_USE_GNUTLS_GCRYPT
    init_gnutls_gcrypt();
#endif
}

extern GMutex *file_mutex;

void
glib_init(void) {
    static gboolean did_glib_init = FALSE;
    if (did_glib_init) return;
    did_glib_init = TRUE;

    /* set up libcurl (this must happen before threading 
     * is initialized) */
#ifdef HAVE_LIBCURL
# ifdef G_THREADS_ENABLED
    if (glib_major_version < 2 ||
	(glib_major_version == 2 && glib_minor_version < 31))
	g_assert(!g_thread_supported()); /* assert threads aren't initialized yet */
# endif
    g_assert(curl_global_init(CURL_GLOBAL_ALL) == 0);
#endif

    /* do a version check */
#if GLIB_CHECK_VERSION(2,6,0)
    {
	const char *glib_err = glib_check_version(GLIB_MAJOR_VERSION,
						  GLIB_MINOR_VERSION,
						  GLIB_MICRO_VERSION);
	if (glib_err) {
	    error(_("%s: Amanda was compiled with glib-%d.%d.%d, but linking with %d.%d.%d"), glib_err,
		    GLIB_MAJOR_VERSION, GLIB_MINOR_VERSION, GLIB_MICRO_VERSION,
		    glib_major_version, glib_minor_version, glib_micro_version);
	    exit(1); /* glib_init may be called before error handling is set up */
	}
    }
#endif

    /* Initialize glib's type system.  On glib >= 2.24, this will initialize
     * threads, so it must be done after curl is initialized. */
    g_type_init();

    /* And set up glib's threads */
#if defined(G_THREADS_ENABLED) && !defined(G_THREADS_IMPL_NONE)
    if (!g_thread_supported())
	g_thread_init(NULL);
#endif

    /* Initialize global mutex */
    file_mutex = g_mutex_new();
    shm_ring_mutex = g_mutex_new();
    priv_mutex = g_mutex_new();
    security_mutex = g_mutex_new();

    /* initialize ssl */
    init_ssl();

}

typedef enum {
    FLAG_STRING_NAME,
    FLAG_STRING_SHORT_NAME,
    FLAG_STRING_NICK
} FlagString;

static char ** g_flags_to_strv(int value, GType type, FlagString source);

void
_glib_util_foreach_glue(gpointer data, gpointer func)
{
    void (*one_arg_fn)(gpointer) = (void (*)(gpointer))func;
    one_arg_fn(data);
}

GValue* g_value_unset_init(GValue* value, GType type) {
    g_return_val_if_fail(value != NULL, NULL);

    if (G_IS_VALUE(value)) {
        g_value_unset(value);
    }
    g_value_init(value, type);
    return value;
}

GValue* g_value_unset_copy(const GValue * from, GValue * to) {
    g_return_val_if_fail(from != NULL, NULL);
    g_return_val_if_fail(to != NULL, NULL);

    g_value_unset_init(to, G_VALUE_TYPE(from));
    g_value_copy(from, to);
    return to;
}

#if (GLIB_MAJOR_VERSION < 2 || (GLIB_MAJOR_VERSION == 2 && GLIB_MINOR_VERSION < 28))
void slist_free_full(GSList * list, GDestroyNotify free_fn) {
    GSList * cur = list;

    while (cur != NULL) {
        gpointer data = cur->data;
        free_fn(data);
        cur = g_slist_next(cur);
    }

    g_slist_free(list);
}
#endif

void g_ptr_array_free_full(GPtrArray * array) {
    size_t i;

    for (i = 0; i < array->len; i ++) {
        amfree(g_ptr_array_index(array, i));
    }
    g_ptr_array_free(array, TRUE);
}

gboolean g_value_compare(GValue * a, GValue * b) {
    if (a == NULL && b == NULL)
        return TRUE;
    if (a == NULL || b == NULL)
        return FALSE;
    if (G_VALUE_TYPE(a) != G_VALUE_TYPE(b))
        return FALSE;
    if (g_value_fits_pointer(a) && g_value_fits_pointer(b)) {
        return g_value_peek_pointer(a) == g_value_peek_pointer(b);
    } else {
        /* Since there is no builtin comparison function, we resort to
           comparing serialized strings. Yuck. */
        char * a_str;
        char * b_str;
        gboolean rval;
        a_str = g_strdup_value_contents(a);
        b_str = g_strdup_value_contents(b);
        rval = (g_str_equal(a_str, b_str));
        amfree(a_str);
        amfree(b_str);
        return rval;
    }
    
    g_assert_not_reached();
}

static gboolean
g_value_set_boolean_from_string(
    GValue * val,
    char * str)
{
    int b = string_to_boolean(str);

    if (b == -1)
	return FALSE;

    g_value_set_boolean(val, b);
    return TRUE;
}

static gboolean g_value_set_int_from_string(GValue * val, char * string) {
    long int strto_result;
    char * strto_end;
    gint64 multiplier;
    strto_result = strtol(string, &strto_end, 0);
    multiplier = find_multiplier(strto_end);
    if (multiplier == G_MAXINT64) {
        if (strto_result >= 0) {
            g_value_set_int(val, G_MAXINT);
        } else {
            g_value_set_int(val, G_MININT);
        }
        return TRUE;
    } else if (*string == '\0' || multiplier == 0
               || strto_result < G_MININT / multiplier
               || strto_result > G_MAXINT / multiplier) {
        return FALSE;
    } else { 
        g_value_set_int(val, (int)(strto_result * multiplier));
        return TRUE;
    }
}

static gboolean g_value_set_uint_from_string(GValue * val, char * string) {
    unsigned long int strto_result;
    char * strto_end;
    guint64 multiplier;
    strto_result = strtoul(string, &strto_end, 0);
    multiplier = find_multiplier(strto_end); /* casts */
    if (multiplier == G_MAXINT64) {
        g_value_set_uint(val, G_MAXUINT);
        return TRUE;
    } else if (multiplier == 0 || *string == '\0' ||
               strto_result > G_MAXUINT / multiplier) {
        return FALSE;
    } else {
        g_value_set_uint(val, (guint)(strto_result * multiplier));
        return TRUE;
    }
}

static gboolean g_value_set_uint64_from_string(GValue * val, char * string) {
    unsigned long long int strto_result;
    char * strto_end;
    guint64 multiplier;
    strto_result = strtoull(string, &strto_end, 0);
    multiplier = find_multiplier(strto_end); /* casts */
    if (multiplier == G_MAXINT64) {
        g_value_set_uint64(val, G_MAXUINT64);
        return TRUE;
    } else if (multiplier == 0 || *string == '\0' ||
        strto_result > G_MAXUINT64 / multiplier) {
        return FALSE;
    } else {
        g_value_set_uint64(val, (guint64)(strto_result * multiplier));
        return TRUE;
    }
}

/* Flags can contain multiple values. We assume here that values are like
 * C identifiers (that is, they match /[A-Za-z_][A-Za-z0-9_]+/), although
 * that doesn't seem to be a requirement of GLib. With that assumption in
 * mind, we look for the format "FLAG_1 | FLAG_2 | ... | FLAG_N". */
static gboolean g_value_set_flags_from_string(GValue * val, char * string) {
    guint value = 0;
    char * strtok_saveptr;
    char * string_copy;
    char * strtok_first_arg;
    const char delim[] = " \t,|";
    GFlagsClass * flags_class;
    
    flags_class = (GFlagsClass*) g_type_class_ref(G_VALUE_TYPE(val));
    g_return_val_if_fail(flags_class != NULL, FALSE);
    g_return_val_if_fail(G_IS_FLAGS_CLASS(flags_class), FALSE);

    /* Don't let strtok stop on original. */
    strtok_first_arg = string_copy = strdup(string);
    
    for (;;) {
        GFlagsValue * flag_value;
        char * token = strtok_r(strtok_first_arg, delim, &strtok_saveptr);
        strtok_first_arg = NULL;

        if (token == NULL) {
            break;
        }
        
        flag_value = g_flags_get_value_by_name(flags_class, token);
        if (flag_value == NULL) {
            flag_value = g_flags_get_value_by_nick(flags_class, token);
        }
        if (flag_value == NULL) {
            g_fprintf(stderr, _("Invalid flag %s for type %s\n"), token,
                    g_type_name(G_VALUE_TYPE(val)));
            continue;
        }

        value |= flag_value->value;
    }
    
    amfree(string_copy);
    
    if (value == 0) {
        g_fprintf(stderr, _("No valid flags for type %s in string %s\n"),
                g_type_name(G_VALUE_TYPE(val)), string);
        return FALSE;
    }
    
    g_value_set_flags(val, value);
    return TRUE;

}

/* This function really ought not to be part of Amanda. In my (Ian's) opinion,
   serialization and deserialization should be a part of the GValue
   interface. But it's not, and here we are. */
gboolean g_value_set_from_string(GValue * val, char * string) {
    g_return_val_if_fail(val != NULL, FALSE);
    g_return_val_if_fail(G_IS_VALUE(val), FALSE);

    if (G_VALUE_HOLDS_BOOLEAN(val)) {
        return g_value_set_boolean_from_string(val, string);
    } else if (G_VALUE_HOLDS_INT(val)) {
        return g_value_set_int_from_string(val, string);
    } else if (G_VALUE_HOLDS_UINT(val)) {
        return g_value_set_uint_from_string(val, string);
    } else if (G_VALUE_HOLDS_UINT64(val)) {
        return g_value_set_uint64_from_string(val, string);
    } else if (G_VALUE_HOLDS_STRING(val)) {
        g_value_set_string(val, string);
        return TRUE;
    } else if (G_VALUE_HOLDS_FLAGS(val)) {
        return g_value_set_flags_from_string(val, string);
    }

    return TRUE;
}

gint
g_compare_strings(
    gconstpointer a,
    gconstpointer b)
{
    return strcmp((char *)a, (char *)b);
}

char * g_strjoinv_and_free(char ** strv, const char * seperator) {
    char * rval = g_strjoinv(seperator, strv);
    g_strfreev(strv);
    return rval;
}

char ** g_flags_name_to_strv(int value, GType type) {
    return g_flags_to_strv(value, type, FLAG_STRING_NAME);
}

char ** g_flags_short_name_to_strv(int value, GType type) {
    return g_flags_to_strv(value, type, FLAG_STRING_SHORT_NAME);
}

char ** g_flags_nick_to_strv(int value, GType type) {
    return g_flags_to_strv(value, type, FLAG_STRING_NICK);
}

static char * get_name_from_value(GFlagsValue * value, FlagString source) {
    switch (source) {
    case FLAG_STRING_NAME:
    case FLAG_STRING_SHORT_NAME:
        return strdup(value->value_name);
    case FLAG_STRING_NICK:
        return strdup(value->value_nick);
    default:
        return NULL;
    }
}

/* If freed and notfreed have a common prefix that is different from freed,
   then return that and free freed. Otherwise, return freed. */
static char * find_common_prefix(char * freed, const char * notfreed) {
    char * freed_ptr = freed;
    const char * notfreed_ptr = notfreed;

    if (freed == NULL) {
        if (notfreed == NULL) {
            return NULL;
        } else {
            return strdup(notfreed);
        }
    } else if (notfreed == NULL) {
        amfree(freed);
        return strdup("");
    }

    while (*freed_ptr == *notfreed_ptr) {
        freed_ptr ++;
        notfreed_ptr ++;
    }

    *freed_ptr = '\0';
    return freed;
}

static char ** g_flags_to_strv(int value, GType type,
                               FlagString source) {
    GPtrArray * rval;
    GFlagsValue * flagsvalue;
    char * common_prefix = NULL;
    int common_prefix_len;
    GFlagsClass * class;

    g_return_val_if_fail(G_TYPE_IS_FLAGS(type), NULL);
    g_return_val_if_fail((class = g_type_class_ref(type)) != NULL, NULL);
    g_return_val_if_fail(G_IS_FLAGS_CLASS(class), NULL);
        
    rval = g_ptr_array_new();
    for (flagsvalue = class->values;
         flagsvalue->value_name != NULL;
         flagsvalue ++) {
        if (source == FLAG_STRING_SHORT_NAME) {
            common_prefix = find_common_prefix(common_prefix,
                                               flagsvalue->value_name);
        }
                                               
        if ((flagsvalue->value == 0 && value == 0) ||
            (flagsvalue->value != 0 && (value & flagsvalue->value))) {
            g_ptr_array_add(rval, get_name_from_value(flagsvalue, source));
        }
    }

    if (source == FLAG_STRING_SHORT_NAME && common_prefix != NULL &&
        ((common_prefix_len = strlen(common_prefix))) > 0) {
        char * old;
        char * new;
        guint i;
        for (i = 0; i < rval->len; i ++) {
            old = g_ptr_array_index(rval, i);
            new = strdup(old + common_prefix_len);
            g_ptr_array_index(rval, i) = new;
            g_free(old);
        }
    }
    
    g_ptr_array_add(rval, NULL);

    amfree(common_prefix);
    return (char**)g_ptr_array_free(rval, FALSE);
}

char * g_english_strjoinv(char ** strv, const char * conjunction) {
    int length;
    char * last;
    char * joined;
    char * rval;

    length = g_strv_length(strv);

    if (length == 1)
	return g_strdup(strv[0]);

    strv = g_strdupv(strv);

    last = strv[length - 1];
    strv[length - 1] = NULL;

    joined = g_strjoinv(", ", strv);
    rval = g_strdup_printf("%s, %s %s", joined, conjunction, last);

    g_free(joined);
    g_free(last);
    g_strfreev(strv);
    return rval;
}

char * g_english_strjoinv_and_free(char ** strv, const char * conjunction) {
    char * rval = g_english_strjoinv(strv, conjunction);
    g_strfreev(strv);
    return rval;
}

#if !(GLIB_CHECK_VERSION(2,6,0))
guint g_strv_length(gchar ** strv) {
    int rval = 0;

    if (G_UNLIKELY(strv == NULL))
        return 0;

    while (*strv != NULL) {
        rval ++;
        strv ++;
    }
    return rval;
}
#endif /* GLIB_CHECK_VERSION(2.6.0) */

#if !GLIB_CHECK_VERSION(2,4,0)
void
g_ptr_array_foreach (GPtrArray *array,
                     GFunc      func,
                     gpointer   user_data)
{
  guint i;

  g_return_if_fail (array);

  for (i = 0; i < array->len; i++)
    (*func) (array->pdata[i], user_data);
}
#endif

guint
g_str_amanda_hash(
	gconstpointer key)
{
    /* modified version of glib's hash function, copyright
     * GLib Team and others 1997-2000. */
    const char *p;
    guint h = 0;

    for (p = key; *p != '\0'; p++)
        h = (h << 5) - h + (('_' == *p) ? '-' : g_ascii_tolower(*p));

    return h;
}

gboolean
g_str_amanda_equal(
	gconstpointer v1,
	gconstpointer v2)
{
    const gchar *p1 = v1, *p2 = v2;
    while (*p1) {
        /* letting '-' == '_' */
        if (!('-' == *p1 || '_' == *p1) || !('-' == *p2 || '_' == *p2))
            if (g_ascii_tolower(*p1) != g_ascii_tolower(*p2))
                return FALSE;

        p1++;
        p2++;
    }

    /* p1 is at '\0' is p2 too? */
    return *p2? FALSE : TRUE;
}

/**
 * g_list_insert_after:
 * @list: a pointer to a #GList
 * @sibling: the list element after which the new element
 *     is inserted or %NULL to insert at the begining of the list
 * @data: the data for the new element
 *
 * Inserts a new element into the list after the given position.
 *
 * Returns: the new start of the #GList
 */
GList *
g_am_list_insert_after(
    GList   *list,
    GList   *sibling,
    gpointer data)
{
  if (!list)
    {
      list = g_list_alloc ();
      list->data = data;
      g_return_val_if_fail (sibling == NULL, list);
      return list;
    }
  else if (sibling)
    {
      GList *node;

      node = g_list_alloc ();
      node->data = data;
      node->prev = sibling;
      node->next = sibling->next;
      sibling->next = node;
      if (node->next)
	{
	  node->next->prev = node;
	}
      return list;
    }
  else
    {
      GList *first;

      first = g_list_alloc ();
      first->data = data;
      first->prev = NULL;
      first->next = list;
      list->prev = first;

      return first;
    }
}
