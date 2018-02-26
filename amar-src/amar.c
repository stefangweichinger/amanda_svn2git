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
 */

#include "amanda.h"
#include "amutil.h"
#include "amar.h"
#include "file.h"

/* Each block in an archive is made up of one or more records, where each
 * record is either a header record or a data record.  The two are
 * distinguished by the header magic string; the string 'AM' is
 * explicitly excluded as an allowed filenum to prevent ambiguity. */

#define HEADER_MAGIC "AMANDA ARCHIVE FORMAT"
#define MAGIC_FILENUM 0x414d
#define HEADER_VERSION 1
#define EOA_BIT 0x80000000

typedef struct header_s {
    /* magic is HEADER_MAGIC + ' ' + decimal version, NUL padded */
    char     magic[28];
} header_t;
#define HEADER_SIZE (sizeof(header_t))

typedef struct record_s {
    guint16  filenum;
    guint16  attrid;
    guint32  size;
} record_t;
#define RECORD_SIZE (sizeof(record_t))
#define MAX_RECORD_DATA_SIZE (4*1024*1024)

#define MKRECORD(ptr, f, a, s, eoa) do { \
    record_t r; \
    guint32  size = s; \
    if (eoa) size |= EOA_BIT; \
    r.filenum = htons(f); \
    r.attrid = htons(a); \
    r.size = htonl(size); \
    memcpy(ptr, &r, sizeof(record_t)); \
} while(0)

/* N.B. - f, a, s, and eoa must be simple lvalues */
#define GETRECORD(ptr, f, a, s, eoa) do { \
    record_t r; \
    memcpy(&r, ptr, sizeof(record_t)); \
    s = ntohl(r.size); \
    if (s & EOA_BIT) { \
	eoa = TRUE; \
	s &= ~EOA_BIT; \
    } else { \
	eoa = FALSE; \
    } \
    f = ntohs(r.filenum); \
    a = ntohs(r.attrid); \
} while(0)

/* performance knob: how much data will we buffer before just
 * writing straight out of the user's buffers? */
#define WRITE_BUFFER_SIZE (512*1024)

typedef struct amar_file_attr_handling_s {
    guint16  filenum;
    guint16  attrid;
    int      fd;
} amar_file_attr_handling_t;

typedef struct handling_params_s {
    /* parameters from the user */
    gpointer user_data;
    amar_attr_handling_t *handling_array;
    amar_file_attr_handling_t *handling_file_attr_array;
    amar_file_start_callback_t file_start_cb;
    amar_file_finish_callback_t file_finish_cb;
    amar_done_callback_t done_cb;
    GError **error;

    /* tracking for open files and attributes */
    GSList *file_states;

    /* read buffer */
    gchar *buf;
    gsize buf_size; /* allocated size */
    gsize buf_len; /* number of active bytes .. */
    gsize buf_offset; /* ..starting at buf + buf_offset */
    gboolean got_eof;
    gboolean just_lseeked; /* did we just call lseek? */
    event_handle_t *event_read_extract;
} handling_params_t;

struct amar_s {
    int       fd;		/* file descriptor			*/
    mode_t    mode;		/* mode O_RDONLY or O_WRONLY		*/
    guint16   maxfilenum;	/* Next file number to allocate		*/
    header_t  hdr;		/* pre-constructed header		*/
    off_t     position;		/* current position in the archive	*/
    off_t     record;		/* record number			*/
    GHashTable *files;		/* List of all amar_file_t		*/
    gboolean  seekable;		/* does lseek() work on this fd?	*/

    /* internal buffer; on writing, this is WRITE_BUFFER_SIZE bytes, and
     * always has at least RECORD_SIZE bytes free. */
    gchar *buf;
    size_t buf_len;
    size_t buf_size;
    handling_params_t *hp;
};

struct amar_file_s {
    amar_t     *archive;	/* archive for this file	*/
    off_t       size;		/* size of the file             */
    gint        filenum;	/* filenum of this file; gint is required by hash table */
    GHashTable  *attributes;	/* all attributes for this file */
};

struct amar_attr_s {
    amar_file_t *file;		/* file for this attribute	*/
    off_t        size;		/* size of the attribute        */
    gint         attrid;	/* id of this attribute		*/
    gboolean     wrote_eoa;	/* If the attribute is finished	*/
    GThread     *thread;
    int          fd;
    int          eoa;
    GError     **error;
};

/*
 * Internal functions
 */

static gboolean amar_attr_close_no_remove(amar_attr_t *attribute, GError **error);
static void amar_read_cb(void *cookie);

GQuark
amar_error_quark(void)
{
    static GQuark q;
    if (!q)
	q = g_quark_from_static_string("amar_error");
    return q;
}

static gboolean
flush_buffer(
	amar_t *archive,
	GError **error)
{
    if (archive->buf_len) {
	if (full_write(archive->fd, archive->buf, archive->buf_len) != archive->buf_len) {
	    g_set_error(error, amar_error_quark(), errno,
			"Error writing to amanda archive: %s", strerror(errno));
	    return FALSE;
	}
	archive->buf_len = 0;
    }

    return TRUE;
}

static gboolean
write_header(
	amar_t *archive,
	GError **error)
{
    /* if it won't fit in the buffer, take the easy way out and flush it */
    if (archive->buf_len + HEADER_SIZE >= WRITE_BUFFER_SIZE - RECORD_SIZE) {
	if (!flush_buffer(archive, error))
	    return FALSE;
    }

    memcpy(archive->buf + archive->buf_len, &archive->hdr, HEADER_SIZE);
    archive->buf_len += HEADER_SIZE;
    archive->position += HEADER_SIZE;

    return TRUE;
}

static gboolean
write_record(
	amar_t *archive,
	amar_file_t *file,
	guint16  attrid,
	gboolean eoa,
	gpointer data,
	gsize data_size,
	GError **error)
{
    /* the buffer always has room for a new record header */
    MKRECORD(archive->buf + archive->buf_len, file->filenum, attrid, data_size, eoa);
    archive->buf_len += RECORD_SIZE;

    /* is it worth copying this record into the buffer? */
    if (archive->buf_len + RECORD_SIZE + data_size < WRITE_BUFFER_SIZE - RECORD_SIZE) {
	/* yes, it is */
	if (data_size)
	    memcpy(archive->buf + archive->buf_len, data, data_size);
	archive->buf_len += data_size;
    } else {
	/* no, it's not */
	struct iovec iov[2];

	/* flush the buffer and write the new data, all in one syscall */
	iov[0].iov_base = archive->buf;
	iov[0].iov_len = archive->buf_len;
	iov[1].iov_base = data;
	iov[1].iov_len = data_size;
	if (full_writev(archive->fd, iov, 2) < 0) {
	    g_set_error(error, amar_error_quark(), errno,
			"Error writing to amanda archive: %s", strerror(errno));
	    return FALSE;
	}
	archive->buf_len = 0;
    }

    archive->position += data_size + RECORD_SIZE;
    file->size += data_size + RECORD_SIZE;
    return TRUE;
}

/*
 * Public functions
 */

amar_t *
amar_new(
    int       fd,
    mode_t mode,
    GError **error)
{
    amar_t *archive = malloc(sizeof(amar_t));
    assert(archive != NULL);

    /* make some sanity checks first */
    g_assert(fd >= 0);
    g_assert(mode == O_RDONLY || mode == O_WRONLY);

    archive->fd = fd;
    archive->mode = mode;
    archive->maxfilenum = 0;
    archive->position = 0;
    archive->seekable = TRUE; /* assume seekable until lseek() fails */
    archive->files = g_hash_table_new(g_int_hash, g_int_equal);
    archive->buf = NULL;

    if (mode == O_WRONLY) {
	archive->buf = g_malloc(WRITE_BUFFER_SIZE);
	archive->buf_size = WRITE_BUFFER_SIZE;
    }
    archive->buf_len = 0;

    if (mode == O_WRONLY) {
	/* preformat a header with our version number */
	bzero(archive->hdr.magic, HEADER_SIZE);
	snprintf(archive->hdr.magic, HEADER_SIZE,
	    HEADER_MAGIC " %d", HEADER_VERSION);

	/* and write it out to start the file */
	if (!write_header(archive, error)) {
	    amar_close(archive, NULL); /* flushing buffer won't fail */
	    return NULL;
	}
    }

    return archive;
}

gboolean
amar_close(
    amar_t *archive,
    GError **error)
{
    gboolean success = TRUE;

    /* verify all files are done */
    g_assert(g_hash_table_size(archive->files) == 0);

    if (archive->mode == O_WRONLY && !flush_buffer(archive, error))
	success = FALSE;

    g_hash_table_destroy(archive->files);
    if (archive->buf) g_free(archive->buf);
    amfree(archive);

    return success;
}

off_t
amar_size(
    amar_t *archive)
{
    return archive->position;
}

off_t
amar_record(
    amar_t *archive)
{
    return archive->record;
}

/*
 * Writing
 */

amar_file_t *
amar_new_file(
    amar_t *archive,
    char *filename_buf,
    gsize filename_len,
    off_t *header_offset,
    GError **error)
{
    amar_file_t *file = NULL;

    g_assert(archive->mode == O_WRONLY);
    g_assert(filename_buf != NULL);

    /* set filename_len if it wasn't specified */
    if (!filename_len)
	filename_len = strlen(filename_buf);
    g_assert(filename_len != 0);

    if (filename_len > MAX_RECORD_DATA_SIZE) {
	g_set_error(error, amar_error_quark(), ENOSPC,
		    "filename is too long for an amanda archive");
	return NULL;
    }

    /* pick a new, unused filenum */

    if (g_hash_table_size(archive->files) == 65535) {
	g_set_error(error, amar_error_quark(), ENOSPC,
		    "No more file numbers available");
	return NULL;
    }

    do {
	gint filenum;

	archive->maxfilenum++;

	/* MAGIC_FILENUM can't be used because it matches the header record text */
	if (archive->maxfilenum == MAGIC_FILENUM) {
	    continue;
	}

	/* see if this fileid is already in use */
	filenum = archive->maxfilenum;
	if (!g_hash_table_lookup(archive->files, &filenum))
	    break;

    } while (1);

    file = g_new0(amar_file_t, 1);
    if (!file) {
	g_set_error(error, amar_error_quark(), ENOSPC,
		    "No more memory");
	return NULL;
    }
    file->archive = archive;
    file->filenum = archive->maxfilenum;
    file->size = 0;
    file->attributes = g_hash_table_new_full(g_int_hash, g_int_equal, NULL, g_free);
    g_hash_table_insert(archive->files, &file->filenum, file);

    /* record the current position and write a header there, if desired */
    if (header_offset) {
	*header_offset = archive->position;
	if (!write_header(archive, error))
	    goto error_exit;
    }

    /* add a filename record */
    if (!write_record(archive, file, AMAR_ATTR_FILENAME,
		      1, filename_buf, filename_len, error))
	goto error_exit;

    return file;

error_exit:
    if (file) {
	g_hash_table_remove(archive->files, &file->filenum);
	g_hash_table_destroy(file->attributes);
	g_free(file);
    }
    return NULL;
}

off_t
amar_file_size(
    amar_file_t *file)
{
    return file->size;
}

static void
foreach_attr_close(
	gpointer key G_GNUC_UNUSED,
	gpointer value,
	gpointer user_data)
{
    amar_attr_t *attr = value;
    GError **error = user_data;

    if (attr->thread) {
	g_thread_join(attr->thread);
	attr->thread = NULL;
    }

    /* return immediately if we've already seen an error */
    if (*error)
	return;

    if (!attr->wrote_eoa) {
	(void)amar_attr_close_no_remove(attr, error);
    }
}

gboolean
amar_file_close(
    amar_file_t *file,
    GError **error)
{
    gboolean success = TRUE;
    amar_t *archive = file->archive;

    /* close all attributes that haven't already written EOA */
    g_hash_table_foreach(file->attributes, foreach_attr_close, error);
    if (*error)
	success = FALSE;

    /* write an EOF record */
    if (success) {
	if (!write_record(archive, file, AMAR_ATTR_EOF, 1,
			  NULL, 0, error))
	    success = FALSE;
    }

    /* remove from archive->file list */
    g_hash_table_remove(archive->files, &file->filenum);

    /* clean up */
    g_hash_table_destroy(file->attributes);
    amfree(file);

    return success;
}

amar_attr_t *
amar_new_attr(
    amar_file_t *file,
    guint16  attrid,
    GError **error G_GNUC_UNUSED)
{
    amar_attr_t *attribute;
    gint attrid_gint = attrid;

    /* make sure this attrid isn't already present */
    g_assert(attrid >= AMAR_ATTR_APP_START);
    g_assert(g_hash_table_lookup(file->attributes, &attrid_gint) == NULL);

    attribute = malloc(sizeof(amar_attr_t));
    if (attribute == NULL) {
	g_set_error(error, amar_error_quark(), ENOSPC,
		    "No more memory");
	return NULL;
    }
    attribute->file = file;
    attribute->size = 0;
    attribute->attrid = attrid;
    attribute->wrote_eoa = FALSE;
    attribute->thread = NULL;
    attribute->fd = -1;
    attribute->eoa = 0;
    g_hash_table_replace(file->attributes, &attribute->attrid, attribute);

    /* (note this function cannot currently return an error) */

    return attribute;
}

off_t
amar_attr_size(
    amar_attr_t *attr)
{
    return attr->size;
}

static gboolean
amar_attr_close_no_remove(
    amar_attr_t *attribute,
    GError **error)
{
    amar_file_t   *file    = attribute->file;
    amar_t        *archive = file->archive;
    gboolean rv = TRUE;

    if (attribute->thread) {
	g_thread_join(attribute->thread);
	attribute->thread = NULL;
    }

    /* write an empty record with EOA_BIT set if we haven't ended
     * this attribute already */
    if (!attribute->wrote_eoa) {
	if (!write_record(archive, file, attribute->attrid,
			  1, NULL, 0, error))
	    rv = FALSE;
	attribute->wrote_eoa = TRUE;
    }

    return rv;
}

gboolean
amar_attr_close(
    amar_attr_t *attribute,
    GError **error)
{
    amar_file_t *file = attribute->file;
    gboolean     rv   = TRUE;
    gint  attrid_gint = attribute->attrid;

    rv = amar_attr_close_no_remove(attribute, error);
    g_hash_table_remove(file->attributes, &attrid_gint);

    return rv;
}

gboolean
amar_attr_add_data_buffer(
    amar_attr_t *attribute,
    gpointer data, gsize size,
    gboolean eoa,
    GError **error)
{
    amar_file_t *file = attribute->file;
    amar_t *archive = file->archive;

    g_assert(!attribute->wrote_eoa);

    /* write records until we've consumed all of the buffer */
    while (size) {
	gsize rec_data_size;
	gboolean rec_eoa = FALSE;

	if (size > MAX_RECORD_DATA_SIZE) {
	    rec_data_size = MAX_RECORD_DATA_SIZE;
	} else {
	    rec_data_size = size;
	    if (eoa)
		rec_eoa = TRUE;
	}

	if (!write_record(archive, file, attribute->attrid,
			  rec_eoa, data, rec_data_size, error))
	    return FALSE;

	data = (gchar *)data + rec_data_size;
	size -= rec_data_size;
	attribute->size += rec_data_size;
    }

    if (eoa) {
	attribute->wrote_eoa = TRUE;
    }

    return TRUE;
}

static gpointer amar_attr_add_data_fd_thread(gpointer data);
off_t
amar_attr_add_data_fd_in_thread(
    amar_attr_t *attribute,
    int fd,
    gboolean eoa,
    GError **error)
{
    attribute->fd = fd;
    attribute->eoa = eoa;
    attribute->error = error;
    attribute->thread = g_thread_create(amar_attr_add_data_fd_thread, attribute, TRUE, NULL);
    return 0;
}

static gpointer
amar_attr_add_data_fd_thread(
    gpointer data)
{
    amar_attr_t *attribute = (amar_attr_t *)data;

    amar_attr_add_data_fd(attribute, attribute->fd, attribute->eoa, attribute->error);
    close(attribute->fd);
    attribute->fd = -1;
    attribute->eoa = 0;
    attribute->error = NULL;
    return NULL;
}


off_t
amar_attr_add_data_fd(
    amar_attr_t *attribute,
    int fd,
    gboolean eoa,
    GError **error)
{
    amar_file_t *file = attribute->file;
    amar_t *archive = file->archive;
    gsize size;
    int read_error;
    gboolean short_read;
    off_t filesize = 0;
    gpointer buf = g_malloc(MAX_RECORD_DATA_SIZE);

    g_assert(!attribute->wrote_eoa);

    /* read and write until reaching EOF */
    while (1) {
	/*
	 * NOTE: we want to write everything we read, even if the last read
	 * returned an error. We check read_error only outside of the loop for
	 * this reason, and exit early only on EOF (read_fully() returns 0).
	 */

	size = read_fully(fd, buf, MAX_RECORD_DATA_SIZE, &read_error);

	if (size == 0) {
	    if (eoa && !attribute->wrote_eoa) {
		if (!write_record(archive, file, attribute->attrid,
				  1, buf, size, error)) {
		    filesize = -1;
		}
	    }
	    break;
	}

	short_read = (size < MAX_RECORD_DATA_SIZE);

	if (!write_record(archive, file, attribute->attrid,
	    eoa && short_read, buf, size, error)) {
	    filesize = -1;
	    break;
	}

	filesize += size;
	attribute->size += size;

	if (short_read)
	    break;
    }

    g_free(buf);

    if (read_error) {
	g_set_error(error, amar_error_quark(), read_error,
	    "Error reading from fd %d: %s", fd, strerror(read_error));
	filesize = -1;
    }

    if (filesize != -1)
	attribute->wrote_eoa = eoa;

    return filesize;
}

/*
 * Reading
 */

/* Note that this implementation assumes that an archive will have a "small"
 * number of open files at any time, and a limited number of attributes for
 * each file. */

typedef struct attr_state_s {
    guint16  attrid;
    amar_attr_handling_t *handling;
    int      fd;
    gchar *buf;
    gsize buf_len;
    gsize buf_size;
    gpointer attr_data;
    gboolean wrote_eoa;
} attr_state_t;

typedef struct file_state_s {
    guint16  filenum;
    gpointer file_data; /* user's data */
    gboolean ignore;

    GSList *attr_states;
} file_state_t;

/* buffer-handling macros and functions */

/* Ensure that the archive buffer contains at least ATLEAST bytes.  Returns
 * FALSE if that many bytes are not available due to EOF or another error. */
static gboolean
buf_atleast_(
    amar_t *archive,
    handling_params_t *hp,
    gsize atleast)
{
    gsize to_read;
    gsize bytes_read;

    /* easy case of hp->buf_len >= atleast is taken care of by the macro, below */

    if (hp->got_eof)
	return FALSE;

    /* If we just don't have space for this much data yet, then we'll have to reallocate
     * the buffer */
    if (hp->buf_size < atleast) {
	if (hp->buf_offset == 0) {
	    hp->buf = g_realloc(hp->buf, atleast);
	} else {
	    gpointer newbuf = g_malloc(atleast);
	    if (hp->buf) {
		memcpy(newbuf, hp->buf+hp->buf_offset, hp->buf_len);
		g_free(hp->buf);
	    }
	    hp->buf = newbuf;
	    hp->buf_offset = 0;
	}
	hp->buf_size = atleast;
    }

    /* if we have space in this buffer to satisfy the request, but not without moving
     * the existing data around, then move the data around */
    else if (hp->buf_size - hp->buf_offset < atleast) {
	memmove(hp->buf, hp->buf+hp->buf_offset, hp->buf_len);
	hp->buf_offset = 0;
    }

    /* as an optimization, if we just called lseek, then only read the requested
     * bytes in case we're going to lseek again. */
    if (hp->just_lseeked)
	to_read = atleast - hp->buf_len;
    else
	to_read = hp->buf_size - hp->buf_offset - hp->buf_len;

    bytes_read = read_fully(archive->fd,
			   hp->buf+hp->buf_offset+hp->buf_len,
			   to_read, NULL);
    if (bytes_read < to_read)
	hp->got_eof = TRUE;
    hp->just_lseeked = FALSE;

    hp->buf_len += bytes_read;

    return hp->buf_len >= atleast;
}

#define buf_atleast(archive, hp, atleast) \
    (((hp)->buf_len >= (atleast))? TRUE : buf_atleast_((archive), (hp), (atleast)))

/* Skip the buffer ahead by SKIPBYTES bytes.  This will discard data from the
 * buffer, and may call lseek() if some of the skipped bytes have not yet been
 * read.  Returns FALSE if the requisite bytes cannot be skipped due to EOF or
 * another error. */
static gboolean
buf_skip_(
    amar_t *archive,
    handling_params_t *hp,
    gsize skipbytes)
{
    /* easy case of buf_len > skipbytes is taken care of by the macro, below,
     * so we know we're clearing out the entire buffer here */

    archive->position += hp->buf_len;
    skipbytes -= hp->buf_len;
    hp->buf_len = 0;

    hp->buf_offset = 0;

retry:
    if (archive->seekable) {
	if (lseek(archive->fd, skipbytes, SEEK_CUR) < 0) {
	    /* did we fail because archive->fd is a pipe or something? */
	    if (errno == ESPIPE) {
		archive->seekable = FALSE;
		goto retry;
	    }
	    hp->got_eof = TRUE;
	    return FALSE;
	}
	archive->position += skipbytes;
    } else {
	while (skipbytes) {
	    gsize toread = MIN(skipbytes, hp->buf_size);
	    gsize bytes_read = read_fully(archive->fd, hp->buf, toread, NULL);

	    if (bytes_read < toread) {
		hp->got_eof = TRUE;
		return FALSE;
	    }

	    archive->position += bytes_read;
	    skipbytes -= bytes_read;
	}
    }

    return TRUE;
}

#define buf_skip(archive, hp, skipbytes) \
    (((skipbytes) <= (hp)->buf_len) ? \
	((hp)->buf_len -= (skipbytes), \
	 (hp)->buf_offset += (skipbytes), \
	 archive->position += (skipbytes), \
	 TRUE) \
      : buf_skip_((archive), (hp), (skipbytes)))

/* Get a pointer to the current position in the buffer */
#define buf_ptr(hp) ((gchar *)(hp)->buf + (hp)->buf_offset)

/* Get the amount of data currently available in the buffer */
#define buf_avail(hp) ((hp)->buf_len)

static gboolean
finish_attr(
    handling_params_t *hp,
    file_state_t *fs,
    attr_state_t *as,
    gboolean truncated)
{
    gboolean success = TRUE;
    if (!as->wrote_eoa && as->handling && as->handling->callback) {
	success = as->handling->callback(hp->user_data, fs->filenum,
			fs->file_data, as->attrid, as->handling->attrid_data,
			&as->attr_data, as->buf, as->buf_len, TRUE, truncated);
    }
    amfree(as->buf);

    return success;
}

static gboolean
finish_file(
    handling_params_t *hp,
    file_state_t *fs,
    gboolean truncated)
{
    GSList *iter;
    gboolean success = TRUE;

    /* free up any attributes not yet ended */
    for (iter = fs->attr_states; iter; iter = iter->next) {
	attr_state_t *as = (attr_state_t *)iter->data;
	success = success && finish_attr(hp, fs, as, TRUE);
    }
    slist_free_full(fs->attr_states, g_free);
    fs->attr_states = NULL;

    if (hp->file_finish_cb && !fs->ignore)
	success = success && hp->file_finish_cb(hp->user_data, fs->filenum,
					        &fs->file_data, truncated);

    return success;
}

static gboolean
read_done(
    handling_params_t *hp)
{
    if (hp->done_cb) {
	return hp->done_cb(hp->user_data, *hp->error);
    }
    return TRUE;
}

/* buffer the data and/or call the callback for this attribute */
static gboolean
handle_hunk(
    handling_params_t *hp,
    file_state_t *fs,
    attr_state_t *as,
    amar_attr_handling_t *hdl,
    gpointer buf,
    gsize len,
    gboolean eoa)
{
    gboolean success = TRUE;

    /* capture any conditions where we don't have to copy into the buffer */
    if (hdl->min_size == 0 || (as->buf_len == 0 && len >= hdl->min_size)) {
	success = success && hdl->callback(hp->user_data, fs->filenum,
		fs->file_data, as->attrid, hdl->attrid_data, &as->attr_data,
		buf, len, eoa, FALSE);
	as->wrote_eoa = eoa;
    } else {
	/* ok, copy into the buffer */
	if (as->buf_len + len > as->buf_size) {
	    gpointer newbuf = g_malloc(as->buf_len + len);
	    if (as->buf) {
		memcpy(newbuf, as->buf, as->buf_len);
		g_free(as->buf);
	    }
	    as->buf = newbuf;
	    as->buf_size = as->buf_len + len;
	}
	memcpy(as->buf + as->buf_len, buf, len);
	as->buf_len += len;

	/* and call the callback if we have enough data or if this is the last attr */
	if (as->buf_len >= hdl->min_size || eoa) {
	    success = success && hdl->callback(hp->user_data, fs->filenum,
		    fs->file_data, as->attrid, hdl->attrid_data, &as->attr_data,
		    as->buf, as->buf_len, eoa, FALSE);
	    as->buf_len = 0;
	    as->wrote_eoa = eoa;
	}
    }

    return success;
}

void amar_read_to(
    amar_t   *archive,
    guint16   filenum,
    guint16   attrid,
    int       fd)
{
    file_state_t *fs = NULL;
    attr_state_t *as = NULL;
    GSList *iter;

    /* find the file_state_t, if it exists */
    for (iter = archive->hp->file_states; iter; iter = iter->next) {
	if (((file_state_t *)iter->data)->filenum == filenum) {
	    fs = (file_state_t *)iter->data;
	    break;
	}
    }

    if (!fs) {
	fs = g_new0(file_state_t, 1);
	fs->filenum = filenum;
	archive->hp->file_states = g_slist_prepend(archive->hp->file_states, fs);
    }

    /* find the attr_state_t, if it exists */
    for (iter = fs->attr_states; iter; iter = iter->next) {
	if (((attr_state_t *)(iter->data))->attrid == attrid) {
	    as = (attr_state_t *)(iter->data);
	    break;
	}
    }

    if (!as) {
	amar_attr_handling_t *hdl = archive->hp->handling_array;
	for (hdl = archive->hp->handling_array; hdl->attrid != 0; hdl++) {
	    if (hdl->attrid == attrid)
		break;
	}
	as = g_new0(attr_state_t, 1);
        as->attrid = attrid;
        as->handling = hdl;
        fs->attr_states = g_slist_prepend(fs->attr_states, as);
    }

    as->fd = fd;
}

void amar_stop_read(
    amar_t   *archive)
{
    if (archive->hp->event_read_extract) {
	event_release(archive->hp->event_read_extract);
	archive->hp->event_read_extract = NULL;
    }
}

void amar_start_read(
    amar_t   *archive)
{
    if (!archive->hp->event_read_extract) {
	archive->hp->event_read_extract = event_create(archive->fd, EV_READFD,
						       amar_read_cb, archive);
	event_activate(archive->hp->event_read_extract);
    }
}

static void
amar_read_cb(
    void *cookie)
{
    amar_t *archive = cookie;
    ssize_t count;
    size_t  need_bytes = 0;
    guint16  filenum;
    guint16  attrid;
    guint32  datasize;
    gboolean eoa;
    gboolean record_processed = FALSE;
    file_state_t *fs = NULL;
    attr_state_t *as = NULL;
    GSList *iter;
    amar_attr_handling_t *hdl;
    gboolean success = TRUE;
    handling_params_t *hp = archive->hp;

    hp = archive->hp;

    count = read(archive->fd, hp->buf + hp->buf_offset + hp->buf_len,
			      hp->buf_size - hp->buf_len - hp->buf_offset);
    if (count == -1) {
	int save_errno = errno;
	g_debug("failed to read archive: %s", strerror(save_errno));
	g_set_error(hp->error, amar_error_quark(), save_errno,
			"failed to read archive, position = %lld: %s",
			(long long)archive->position, strerror(save_errno));
    }
    hp->buf_len += count;

    /* process all complete records */
    while (hp->buf_len >= RECORD_SIZE && hp->event_read_extract) {
	as = NULL;
	fs = NULL;
	GETRECORD(buf_ptr(hp), filenum, attrid, datasize, eoa);
	if (filenum == MAGIC_FILENUM) {
	    int vers;

	    /* HEADER_RECORD */
	    if (hp->buf_len < HEADER_SIZE) {
		/* not a complete header */
		need_bytes = HEADER_SIZE;
		break;
	    }

	    if (sscanf(buf_ptr(hp), HEADER_MAGIC " %d", &vers) != 1) {
		g_set_error(hp->error, amar_error_quark(), EINVAL,
			    "Invalid archive header, position = %lld",
			    (long long)archive->position);
		read_done(archive->hp);
		return;
	    }

	    if (vers > HEADER_VERSION) {
		g_set_error(hp->error, amar_error_quark(), EINVAL,
			    "Archive version %d is not supported, position = %lld",
			    vers, (long long)archive->position);
		read_done(archive->hp);
		return;
	    }

	    /* skip the header block */
	    hp->buf_offset += HEADER_SIZE;
	    hp->buf_len    -= HEADER_SIZE;
	    record_processed = TRUE;
	    continue; /* go to next record */

	} else if (datasize > MAX_RECORD_DATA_SIZE) {
	    g_set_error(hp->error, amar_error_quark(), EINVAL,
			"Invalid record: data size must be less than %d, position = %lld",
			MAX_RECORD_DATA_SIZE, (long long)archive->position);
	    read_done(archive->hp);
	    return;

	} else if (hp->buf_len < RECORD_SIZE + datasize) {
	    /* not a complete record */
	    need_bytes = RECORD_SIZE + datasize;
	    break;
	}

	record_processed = TRUE;
	/* find the file_state_t, if it exists */
	for (iter = hp->file_states; iter; iter = iter->next) {
	    if (((file_state_t *)iter->data)->filenum == filenum) {
		fs = (file_state_t *)iter->data;
		break;
	    }
	}

	/* get the "special" attributes out of the way */
        if (G_UNLIKELY(attrid < AMAR_ATTR_APP_START)) {
	    if (attrid == AMAR_ATTR_EOF) {
		if (datasize != 0) {
		    g_set_error(hp->error, amar_error_quark(), EINVAL,
				"Archive contains an EOF record with nonzero size, position = %lld",
				(long long)archive->position);
		    read_done(archive->hp);
		    return;
		}
		hp->buf_offset += RECORD_SIZE;
		hp->buf_len    -= RECORD_SIZE;
		if (fs) {
		    hp->file_states = g_slist_remove(hp->file_states, fs);
		    success = finish_file(hp, fs, FALSE);
		    g_free(fs);
		    fs = NULL;
		    if (!success)
			break;
		}
		continue;
	    } else if (attrid == AMAR_ATTR_FILENAME) {
		if (fs) {
		    /* TODO: warn - previous file did not end correctly */
		    hp->file_states = g_slist_remove(hp->file_states, fs);
		    success = finish_file(hp, fs, TRUE);
		    g_free(fs);
		    fs = NULL;
		    if (!success)
			break;
		}

		if (datasize == 0) {
		    unsigned int i, nul_padding = 1;
		    char *bb;
		    /* try to detect NULL padding bytes */
		    if (hp->buf_len < 512 - RECORD_SIZE) {
			/* close to end of file */
			break;
		    }
		    hp->buf_offset += RECORD_SIZE;
		    hp->buf_len    -= RECORD_SIZE;
		    bb = buf_ptr(hp);
		    /* check all byte == 0 */
		    for (i=0; i<512 - RECORD_SIZE; i++) {
			if (*bb++ != 0)
			    nul_padding = 0;
		    }
		    hp->buf_offset += datasize;
		    hp->buf_len    -= datasize;
		    if (nul_padding) {
			break;
		    }
		    g_set_error(hp->error, amar_error_quark(), EINVAL,
				"Archive file %d has an empty filename, position = %lld",
				(int)filenum, (long long)archive->position);
		    read_done(archive->hp);
		    return;
		}

		if (!eoa) {
		    g_set_error(hp->error, amar_error_quark(), EINVAL,
				"Filename record for fileid %d does "
				"not have its EOA bit set, position = %lld",
				(int)filenum, (long long)archive->position);
		    hp->buf_offset += (RECORD_SIZE + datasize);
		    hp->buf_len    -= (RECORD_SIZE + datasize);
		    read_done(archive->hp);
		    return;
		}

		fs = g_new0(file_state_t, 1);
		fs->filenum = filenum;
		hp->file_states = g_slist_prepend(hp->file_states, fs);

		if (hp->file_start_cb) {
		    hp->buf_offset += RECORD_SIZE;
		    hp->buf_len    -= RECORD_SIZE;
		    success = hp->file_start_cb(hp->user_data, filenum,
				buf_ptr(hp), datasize,
				&fs->ignore, &fs->file_data);
		    hp->buf_offset += datasize;
		    hp->buf_len    -= datasize;
		    if (!success)
			break;
		}
		continue;

	    } else {
		g_set_error(hp->error, amar_error_quark(), EINVAL,
			    "Unknown attribute id %d in archive file %d, position = %lld",
			    (int)attrid, (int)filenum, (long long)archive->position);
		read_done(archive->hp);
		return;
	    }
	}

	/* if this is an unrecognized file or a known file that's being
	 * ignored, then skip it. */
	if (!fs || fs->ignore) {
	    hp->buf_offset += (RECORD_SIZE + datasize);
	    hp->buf_len    -= (RECORD_SIZE + datasize);
	    continue;
	}

	/* ok, this is an application attribute.  Look up its as, if it exists. */
	for (iter = fs->attr_states; iter; iter = iter->next) {
	    if (((attr_state_t *)(iter->data))->attrid == attrid) {
		as = (attr_state_t *)(iter->data);
		break;
	    }
	}

	/* and get the proper handling for that attribute */
	if (as) {
	    hdl = as->handling;
	} else {
	    hdl = hp->handling_array;
	    for (hdl = hp->handling_array; hdl->attrid != 0; hdl++) {
		if (hdl->attrid == attrid)
		    break;
	    }
	}

	/* As a shortcut, if this is a one-record attribute, handle it without
	 * creating a new attribute_state_t. */
	if (eoa && !as) {
	    gpointer tmp = NULL;
	    if (hdl->callback) {
		hp->buf_offset += RECORD_SIZE;
		hp->buf_len    -= RECORD_SIZE;
		success = hdl->callback(hp->user_data, filenum, fs->file_data, attrid,
					hdl->attrid_data, &tmp, buf_ptr(hp), datasize, eoa, FALSE);
		hp->buf_offset += datasize;
		hp->buf_len    -= datasize;
		if (!success)
		    break;
		continue;
	    } else {
		/* no callback -> just skip it */
		hp->buf_offset += (RECORD_SIZE + datasize);
		hp->buf_len    -= (RECORD_SIZE + datasize);
		continue;
	    }

	}

	/* ok, set up a new attribute state */
	if (!as) {
	    as = g_new0(attr_state_t, 1);
	    as->fd = -1;
	    as->attrid = attrid;
	    as->handling = hdl;
	    fs->attr_states = g_slist_prepend(fs->attr_states, as);
	}

	hp->buf_offset += RECORD_SIZE;
	hp->buf_len    -= RECORD_SIZE;
	if (as->fd != -1) {
	    int count = full_write(as->fd, buf_ptr(hp), datasize);
	    hp->buf_offset += datasize;
	    hp->buf_len    -= datasize;
	    if (count != (gint32)datasize)
		break;
	    if (eoa) {
		as->wrote_eoa = eoa;
	    }
	} else if (hdl->callback) {
	    success = handle_hunk(hp, fs, as, hdl, buf_ptr(hp), datasize, eoa);
	    hp->buf_offset += datasize;
	    hp->buf_len    -= datasize;
	    if (!success)
		break;
	} else {
	    hp->buf_offset += datasize;
	    hp->buf_len    -= datasize;
	}

	/* finish the attribute if this is its last record */
	if (eoa) {
	    success = finish_attr(hp, fs, as, FALSE);
	    fs->attr_states = g_slist_remove(fs->attr_states, as);
	    g_free(as);
	    as = NULL;
	    if (!success)
		break;
        }
    }

    /* increase buffer if needed */
    if (need_bytes > hp->buf_size) {
	char *new_buf = g_malloc(need_bytes);
	memcpy(new_buf, hp->buf + hp->buf_offset, hp->buf_len);
	g_free(hp->buf);
	hp->buf = new_buf;
	hp->buf_offset = 0;
	hp->buf_size = need_bytes;
    } else if (hp->buf_offset > 0) {
	/* move data at begining of buffer */
	memmove(hp->buf, hp->buf + hp->buf_offset, hp->buf_len);
	hp->buf_offset = 0;
    }

    if (count == -1 || (count == 0 && (hp->buf_len == 0 || !record_processed))) {
	if (count == 0 && hp->buf_len != 0) {
	    g_set_error(hp->error, amar_error_quark(), EINVAL,
			    "Archive ended with a partial record, position = %lld, buf_len = %zu",
			(long long)archive->position, hp->buf_len );
	}
	hp->got_eof = TRUE;
	amar_stop_read(archive);

	/* close any open files, assuming that they have been truncated */
	for (iter = hp->file_states; iter; iter = iter->next) {
	    file_state_t *fs = (file_state_t *)iter->data;
	    finish_file(hp, fs, TRUE);
	}
	slist_free_full(hp->file_states, g_free);
	read_done(hp);
	g_free(hp->buf);
	g_free(hp);
	archive->hp = NULL;
    }
}

event_fn_t
set_amar_read_cb(
	amar_t *archive,
	gpointer user_data,
	amar_attr_handling_t *handling_array,
	amar_file_start_callback_t file_start_cb,
	amar_file_finish_callback_t file_finish_cb,
	amar_done_callback_t done_cb,
	GError **error)
{
    handling_params_t *hp = g_new0(handling_params_t, 1);

    g_assert(archive->mode == O_RDONLY);

    hp->user_data = user_data;
    hp->handling_array = handling_array;
    hp->file_start_cb = file_start_cb;
    hp->file_finish_cb = file_finish_cb;
    hp->done_cb = done_cb;
    hp->error = error;
    hp->file_states = NULL;
    hp->buf_len = 0;
    hp->buf_offset = 0;
    hp->buf_size = 65536; /* use a 64K buffer to start */
    hp->buf = g_malloc(hp->buf_size);
    hp->got_eof = FALSE;
    hp->just_lseeked = FALSE;
    archive->hp = hp;

    amar_start_read(archive);
    return amar_read_cb;
}

gboolean
amar_read(
	amar_t *archive,
	gpointer user_data,
	amar_attr_handling_t *handling_array,
	amar_file_start_callback_t file_start_cb,
	amar_file_finish_callback_t file_finish_cb,
	amar_done_callback_t done_cb,
	GError **error)
{
    file_state_t *fs = NULL;
    attr_state_t *as = NULL;
    GSList *iter;
    handling_params_t hp;
    guint16  filenum;
    guint16  attrid;
    guint32  datasize;
    gboolean eoa;
    amar_attr_handling_t *hdl;
    gboolean success = TRUE;

    g_assert(archive->mode == O_RDONLY);

    hp.user_data = user_data;
    hp.handling_array = handling_array;
    hp.file_start_cb = file_start_cb;
    hp.file_finish_cb = file_finish_cb;
    hp.done_cb = done_cb;
    hp.file_states = NULL;
    hp.buf_len = 0;
    hp.buf_offset = 0;
    hp.buf_size = 1024; /* use a 1K buffer to start */
    hp.buf = g_malloc(hp.buf_size);
    hp.got_eof = FALSE;
    hp.just_lseeked = FALSE;

    /* check that we are starting at a header record, but don't advance
     * the buffer past it */
    if (buf_atleast(archive, &hp, RECORD_SIZE)) {
	GETRECORD(buf_ptr(&hp), filenum, attrid, datasize, eoa);
	if (filenum != MAGIC_FILENUM) {
	    g_set_error(error, amar_error_quark(), EINVAL,
			"Archive read does not begin at a header record, position = %lld",
			(long long)archive->position);
	    return FALSE;
	}
    }

    while (1) {
	if (!buf_atleast(archive, &hp, RECORD_SIZE))
	    break;

	GETRECORD(buf_ptr(&hp), filenum, attrid, datasize, eoa);

	archive->record++;
	/* handle headers specially */
	if (G_UNLIKELY(filenum == MAGIC_FILENUM)) {
	    int vers;

	    /* bail if an EOF occurred in the middle of the header */
	    if (!buf_atleast(archive, &hp, HEADER_SIZE))
		break;

	    if (sscanf(buf_ptr(&hp), HEADER_MAGIC " %d", &vers) != 1) {
		g_set_error(error, amar_error_quark(), EINVAL,
			    "Invalid archive header, position = %lld",
			    (long long)archive->position);
		return FALSE;
	    }

	    if (vers > HEADER_VERSION) {
		g_set_error(error, amar_error_quark(), EINVAL,
			    "Archive version %d is not supported, position = %lld", vers,
			    (long long)archive->position);
		return FALSE;
	    }

	    buf_skip(archive, &hp, HEADER_SIZE);

	    continue;
	}

	buf_skip(archive, &hp, RECORD_SIZE);

	if (datasize > MAX_RECORD_DATA_SIZE) {
	    g_set_error(error, amar_error_quark(), EINVAL,
			"Invalid record: data size must be less than %d, position = %lld",
			MAX_RECORD_DATA_SIZE, (long long)archive->position);
	    return FALSE;
	}

	/* find the file_state_t, if it exists */
	if (!fs || fs->filenum != filenum) {
	    fs = NULL;
	    for (iter = hp.file_states; iter; iter = iter->next) {
		if (((file_state_t *)iter->data)->filenum == filenum) {
		    fs = (file_state_t *)iter->data;
		    break;
		}
	    }
	}

	/* get the "special" attributes out of the way */
	if (G_UNLIKELY(attrid < AMAR_ATTR_APP_START)) {
	    if (attrid == AMAR_ATTR_EOF) {
		if (datasize != 0) {
		    g_set_error(error, amar_error_quark(), EINVAL,
				"Archive contains an EOF record with nonzero size, position = %lld",
				(long long)archive->position);
		    return FALSE;
		}
		if (fs) {
		    hp.file_states = g_slist_remove(hp.file_states, fs);
		    success = finish_file(&hp, fs, FALSE);
		    as = NULL;
		    g_free(fs);
		    fs = NULL;
		    if (!success)
			break;
		}
		continue;
	    } else if (attrid == AMAR_ATTR_FILENAME) {
		/* for filenames, we need the whole filename in the buffer */
		if (!buf_atleast(archive, &hp, datasize))
		    break;

		if (fs) {
		    /* TODO: warn - previous file did not end correctly */
		    hp.file_states = g_slist_remove(hp.file_states, fs);
		    success = finish_file(&hp, fs, TRUE);
		    as = NULL;
		    g_free(fs);
		    fs = NULL;
		    if (!success)
			break;
		}

		if (!datasize) {
		    unsigned int i, nul_padding = 1;
		    char *bb;
		    /* try to detect NULL padding bytes */
		    if (!buf_atleast(archive, &hp, 512 - RECORD_SIZE)) {
			/* close to end of file */
			break;
		    }
		    bb = buf_ptr(&hp);
		    /* check all byte == 0 */
		    for (i=0; i<512 - RECORD_SIZE; i++) {
			if (*bb++ != 0)
			    nul_padding = 0;
		    }
		    if (nul_padding) {
			break;
		    }
		    g_set_error(error, amar_error_quark(), EINVAL,
				"Archive file %d has an empty filename, position = %lld",
				(int)filenum, (long long)archive->position);
		    return FALSE;
		}

		if (!eoa) {
		    g_set_error(error, amar_error_quark(), EINVAL,
				"Filename record for fileid %d does "
				"not have its EOA bit set, position = %lld",
				(int)filenum, (long long)archive->position);
		    return FALSE;
		}

		fs = g_new0(file_state_t, 1);
		fs->filenum = filenum;
		hp.file_states = g_slist_prepend(hp.file_states, fs);

		if (hp.file_start_cb) {
		    success = hp.file_start_cb(hp.user_data, filenum,
			    buf_ptr(&hp), datasize,
			    &fs->ignore, &fs->file_data);
		    if (!success)
			break;
		}

		buf_skip(archive, &hp, datasize);

		continue;
	    } else {
		g_set_error(error, amar_error_quark(), EINVAL,
			    "Unknown attribute id %d in archive file %d, position = %lld",
			    (int)attrid, (int)filenum, (long long)archive->position);
		return FALSE;
	    }
	}

	/* if this is an unrecognized file or a known file that's being
	 * ignored, then skip it. */
	if (!fs || fs->ignore) {
	    buf_skip(archive, &hp, datasize);
	    continue;
	}

	/* ok, this is an application attribute.  Look up its as, if it exists. */
	if (!as || as->attrid != attrid) {
	    as = NULL;
	    for (iter = fs->attr_states; iter; iter = iter->next) {
		if (((attr_state_t *)(iter->data))->attrid == attrid) {
		    as = (attr_state_t *)(iter->data);
		    break;
		}
	    }
	}

	/* and get the proper handling for that attribute */
	if (as) {
	    hdl = as->handling;
	} else {
	    hdl = hp.handling_array;
	    for (hdl = hp.handling_array; hdl->attrid != 0; hdl++) {
		if (hdl->attrid == attrid)
		    break;
	    }
	}

	/* As a shortcut, if this is a one-record attribute, handle it without
	 * creating a new attribute_state_t. */
	if (eoa && !as) {
	    gpointer tmp = NULL;
	    if (hdl->callback) {
		/* a simple single-part callback */
		if (buf_avail(&hp) >= datasize) {
		    success = hdl->callback(hp.user_data, filenum, fs->file_data, attrid,
			    hdl->attrid_data, &tmp, buf_ptr(&hp), datasize, eoa, FALSE);
		    if (!success)
			break;
		    buf_skip(archive, &hp, datasize);
		    continue;
		}

		/* we only have part of the data, but if it's big enough to exceed
		 * the attribute's min_size, then just call the callback for each
		 * part of the data */
		else if (buf_avail(&hp) >= hdl->min_size) {
		    gsize firstpart = buf_avail(&hp);
		    gsize lastpart = datasize - firstpart;

		    success = hdl->callback(hp.user_data, filenum, fs->file_data, attrid,
			    hdl->attrid_data, &tmp, buf_ptr(&hp), firstpart, FALSE, FALSE);
		    if (!success)
			break;
		    buf_skip(archive, &hp, firstpart);

		    if (!buf_atleast(archive, &hp, lastpart))
			break;

		    success = hdl->callback(hp.user_data, filenum, fs->file_data, attrid,
			    hdl->attrid_data, &tmp, buf_ptr(&hp), lastpart, eoa, FALSE);
		    if (!success)
			break;
		    buf_skip(archive, &hp, lastpart);
		    continue;
		}
	    } else {
		/* no callback -> just skip it */
		buf_skip(archive, &hp, datasize);
		continue;
	    }
	}

	/* ok, set up a new attribute state */
	if (!as) {
	    as = g_new0(attr_state_t, 1);
	    as->attrid = attrid;
	    as->handling = hdl;
	    fs->attr_states = g_slist_prepend(fs->attr_states, as);
	}

	if (hdl->callback) {
	    /* handle the data as one or two hunks, depending on whether it's
	     * all in the buffer right now */
	    if (buf_avail(&hp) >= datasize) {
		success = handle_hunk(&hp, fs, as, hdl, buf_ptr(&hp), datasize, eoa);
		if (!success)
		    break;
		buf_skip(archive, &hp, datasize);
	    } else {
		gsize hunksize = buf_avail(&hp);
		success = handle_hunk(&hp, fs, as, hdl, buf_ptr(&hp), hunksize, FALSE);
		if (!success)
		    break;
		buf_skip(archive, &hp, hunksize);

		hunksize = datasize - hunksize;
		if (!buf_atleast(archive, &hp, hunksize))
		    break;

		handle_hunk(&hp, fs, as, hdl, buf_ptr(&hp), hunksize, eoa);
		buf_skip(archive, &hp, hunksize);
	    }
	} else {
	    buf_skip(archive, &hp, datasize);
	}

	/* finish the attribute if this is its last record */
	if (eoa) {
	    success = finish_attr(&hp, fs, as, FALSE);
	    fs->attr_states = g_slist_remove(fs->attr_states, as);
	    g_free(as);
	    as = NULL;
	    if (!success)
		break;
	}
    }

    /* close any open files, assuming that they have been truncated */

    for (iter = hp.file_states; iter; iter = iter->next) {
	file_state_t *fs = (file_state_t *)iter->data;
	finish_file(&hp, fs, TRUE);
    }
    slist_free_full(hp.file_states, g_free);
    g_free(hp.buf);

    return success;
}

void amar_set_error(
    amar_t *archive,
    char *msg)
{
    g_set_error(archive->hp->error, amar_error_quark(), EINVAL, "%s",
		g_strdup(msg));
    amar_stop_read(archive);
    read_done(archive->hp);
}
