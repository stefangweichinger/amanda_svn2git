/*
 * Amanda, The Advanced Maryland Automatic Network Disk Archiver
 * Copyright (c) 1991-1999 University of Maryland at College Park
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
 * Authors: the Amanda Development Team.  Its members are listed in a
 * file named AUTHORS, in the root directory of this distribution.
 */
/* $Id: dumper.c,v 1.190 2006/08/30 19:53:57 martinea Exp $
 *
 * requests remote amandad processes to dump filesystems
 */
#include "amanda.h"
#include "amindex.h"
#include "clock.h"
#include "conffile.h"
#include "event.h"
#include "logfile.h"
#include "packet.h"
#include "protocol.h"
#include "security.h"
#include "stream.h"
#include "fileheader.h"
#include "amfeatures.h"
#include "server_util.h"
#include "amutil.h"
#include "timestamp.h"
#include "amxml.h"

#ifdef FAILURE_CODE
static int dumper_try_again=0;
#endif

#define dumper_debug(i, ...) do {	\
	if ((i) <= debug_dumper) {	\
	    g_debug(__VA_ARGS__);	\
	}				\
} while (0)

#ifndef SEEK_SET
#define SEEK_SET 0
#endif

#ifndef SEEK_CUR
#define SEEK_CUR 1
#endif

#define CONNECT_TIMEOUT	5*60

#define STARTUP_TIMEOUT 60

struct databuf {
    int fd;			/* file to flush to */
    char *buf;
    char *datain;		/* data buffer markers */
    char *dataout;
    char *datalimit;
    pid_t compresspid;		/* valid if fd is pipe to compress */
    pid_t encryptpid;		/* valid if fd is pipe to encrypt */
    shm_ring_t *shm_ring_producer;
    shm_ring_t *shm_ring_consumer;
    shm_ring_t *shm_ring_direct;
    uint64_t    shm_readx;
    crc_t      *crc;
};
pid_t statepid = -1;

struct databuf *g_databuf = NULL;

typedef struct filter_s {
    int             fd;
    char           *name;
    char           *buffer;
    gint64          first;           /* first byte used */
    gint64          size;            /* number of byte use in the buffer */
    gint64          allocated_size ; /* allocated size of the buffer     */
    event_handle_t *event;
} filter_t;

static char *handle = NULL;

static char *errstr = NULL;
static off_t dumpbytes;
static off_t dumpsize, headersize, origsize;

static comp_t srvcompress = COMP_NONE;
char *srvcompprog = NULL;
char *clntcompprog = NULL;

static encrypt_t srvencrypt = ENCRYPT_NONE;
char *srv_encrypt = NULL;
char *clnt_encrypt = NULL;
char *srv_decrypt_opt = NULL;
char *clnt_decrypt_opt = NULL;
static kencrypt_type dumper_kencrypt;

static FILE *errf = NULL;
static char *src_ip = NULL;
static char *maxdumps = NULL;
static char *hostname = NULL;
am_feature_t *their_features = NULL;
static char *diskname = NULL;
static char *qdiskname = NULL, *b64disk;
static char *device = NULL, *b64device;
static char *options = NULL;
static char *progname = NULL;
static char *amandad_path=NULL;
static char *client_username=NULL;
static char *ssl_fingerprint_file=NULL;
static char *ssl_cert_file=NULL;
static char *ssl_key_file=NULL;
static char *ssl_ca_cert_file=NULL;
static char *ssl_cipher_list=NULL;
static char *ssl_check_certificate_host=NULL;
static char *client_port=NULL;
static char *ssh_keys=NULL;
static char *auth=NULL;
static data_path_t data_path=DATA_PATH_AMANDA;
static char *dataport_list = NULL;
static char *shm_name = NULL;
static int level;
static char *dumpdate = NULL;
static char *dumper_timestamp = NULL;
static time_t conf_dtimeout;
static int indexfderror;
static int set_datafd;
static char *dle_str = NULL;
static char *errfname = NULL;
static int   errf_lines = 0;
static int   max_warnings = 0;
static crc_t crc_data_in;
static crc_t crc_data_out;
static crc_t native_crc;
static crc_t client_crc;
static char *log_filename = NULL;
static char *state_filename = NULL;
static char *state_filename_gz = NULL;
static int   statefile_in_mesg = -1;
static gboolean broken_statefile_in_mesg = FALSE;
static int   statefile_in_stream = -1;
static int   retry_delay;
static int   retry_level;
static char *retry_message = NULL;
static GThread *shm_thread = NULL;
static GMutex  *shm_thread_mutex = NULL;
static GCond   *shm_thread_cond = NULL;
static shm_ring_t *shm_ring_consumer = NULL;
static shm_ring_t *shm_ring_direct = NULL;
static char *write_to = NULL;

static dumpfile_t file;

#ifdef FAILURE_CODE
static int disable_network_shm = -1;
#endif

static int dump_result;
static int status;
#define	GOT_INFO_ENDLINE	(1 << 0)
#define	GOT_SIZELINE		(1 << 1)
#define	GOT_ENDLINE		(1 << 2)
#define	HEADER_DONE		(1 << 3)
#define	HEADER_SENT		(1 << 4)
#define	GOT_RETRY		(1 << 5)

static struct {
    const char *name;
    security_stream_t *fd;
} streams[] = {
#define	DATAFD	0
    { "DATA", NULL },
#define	MESGFD	1
    { "MESG", NULL },
#define	INDEXFD	2
    { "INDEX", NULL },
#define	STATEFD	3
    { "STATE", NULL },
};
#define NSTREAMS G_N_ELEMENTS(streams)

static am_feature_t *our_features = NULL;
static char *our_feature_string = NULL;

/* buffer to keep partial line from the MESG stream */
static struct {
    char *buf;		/* buffer holding msg data */
    size_t size;	/* size of alloced buffer */
} msg = { NULL, 0 };


/* local functions */
int		main(int, char **);
static int	do_dump(struct databuf *);
static void	check_options(char *);
static void     xml_check_options(char *optionstr);
static void	finish_tapeheader(dumpfile_t *);
static ssize_t	write_tapeheader(int, dumpfile_t *);
static void	databuf_init(struct databuf *, int);
static int	databuf_write(struct databuf *, const void *, size_t);
static int	databuf_flush(struct databuf *);
static void	process_dumpeof(void);
static void	process_dumpline(const char *);
static void	add_msg_data(const char *, size_t);
static void	parse_info_line(char *);
static int	log_msgout(logtype_t);
static char *	dumper_get_security_conf (char *, void *);

static int	runcompress(int, pid_t *, comp_t, char *);
static int	runencrypt(int, pid_t *,  encrypt_t, char *);

static void	sendbackup_response(void *, pkt_t *, security_handle_t *);
static int	startup_dump(const char *, const char *, const char *, int,
			const char *, const char *, const char *,
			const char *, const char *, const char *,
			const char *, const char *, const char *,
			const char *, const char *, const char *,
			const char *, const char *);
static void	stop_dump(void);

static void	read_indexfd(void *, void *, ssize_t);
static void	read_datafd(void *, void *, ssize_t);
static void	read_statefd(void *, void *, ssize_t);
static void	read_mesgfd(void *, void *, ssize_t);
static gboolean header_sent(struct databuf *db);
static void	timeout(time_t);
static void	retimeout(time_t);
static void	timeout_callback(void *unused);
static gpointer handle_shm_ring_to_fd_thread(gpointer data);
static gpointer handle_shm_ring_direct(gpointer data);

static void
check_options(
    char *options)
{
  char *compmode = NULL;
  char *compend  = NULL;
  char *encryptmode = NULL;
  char *encryptend = NULL;
  char *decryptmode = NULL;
  char *decryptend = NULL;

    /* parse the compression option */
    if (strstr(options, "srvcomp-best;") != NULL) 
      srvcompress = COMP_BEST;
    else if (strstr(options, "srvcomp-fast;") != NULL)
      srvcompress = COMP_FAST;
    else if ((compmode = strstr(options, "srvcomp-cust=")) != NULL) {
	compend = strchr(compmode, ';');
	if (compend ) {
	    srvcompress = COMP_SERVER_CUST;
	    *compend = '\0';
	    srvcompprog = g_strdup(compmode + strlen("srvcomp-cust="));
	    *compend = ';';
	}
    } else if ((compmode = strstr(options, "comp-cust=")) != NULL) {
	compend = strchr(compmode, ';');
	if (compend) {
	    srvcompress = COMP_CUST;
	    *compend = '\0';
	    clntcompprog = g_strdup(compmode + strlen("comp-cust="));
	    *compend = ';';
	}
    }
    else {
      srvcompress = COMP_NONE;
    }
    

    /* now parse the encryption option */
    if ((encryptmode = strstr(options, "encrypt-serv-cust=")) != NULL) {
      encryptend = strchr(encryptmode, ';');
      if (encryptend) {
	    srvencrypt = ENCRYPT_SERV_CUST;
	    *encryptend = '\0';
	    srv_encrypt = g_strdup(encryptmode + strlen("encrypt-serv-cust="));
	    *encryptend = ';';
      }
    } else if ((encryptmode = strstr(options, "encrypt-cust=")) != NULL) {
      encryptend = strchr(encryptmode, ';');
      if (encryptend) {
	    srvencrypt = ENCRYPT_CUST;
	    *encryptend = '\0';
	    clnt_encrypt = g_strdup(encryptmode + strlen("encrypt-cust="));
	    *encryptend = ';';
      }
    } else {
      srvencrypt = ENCRYPT_NONE;
    }
    /* get the decryption option parameter */
    if ((decryptmode = strstr(options, "server-decrypt-option=")) != NULL) {
      decryptend = strchr(decryptmode, ';');
      if (decryptend) {
	*decryptend = '\0';
	srv_decrypt_opt = g_strdup(decryptmode + strlen("server-decrypt-option="));
	*decryptend = ';';
      }
    } else if ((decryptmode = strstr(options, "client-decrypt-option=")) != NULL) {
      decryptend = strchr(decryptmode, ';');
      if (decryptend) {
	*decryptend = '\0';
	clnt_decrypt_opt = g_strdup(decryptmode + strlen("client-decrypt-option="));
	*decryptend = ';';
      }
    }

    if (strstr(options, "kencrypt;") != NULL) {
	dumper_kencrypt = KENCRYPT_WILL_DO;
    } else {
	dumper_kencrypt = KENCRYPT_NONE;
    }
}


static void
xml_check_options(
    char *optionstr)
{
    char *o, *oo;
    char *errmsg = NULL;
    dle_t *dle;

    o = oo = g_strjoin(NULL, "<dle>", strchr(optionstr,'<'), "</dle>", NULL);

    dle = amxml_parse_node_CHAR(o, &errmsg);
    if (dle == NULL) {
	error("amxml_parse_node_CHAR failed: %s\n", errmsg);
    }

    if (dle->compress == COMP_SERVER_FAST) {
	srvcompress = COMP_FAST;
    } else if (dle->compress == COMP_SERVER_BEST) {
	srvcompress = COMP_BEST;
    } else if (dle->compress == COMP_SERVER_CUST) {
	srvcompress = COMP_SERVER_CUST;
	srvcompprog = g_strdup(dle->compprog);
    } else if (dle->compress == COMP_CUST) {
	srvcompress = COMP_CUST;
	clntcompprog = g_strdup(dle->compprog);
    } else {
	srvcompress = COMP_NONE;
    }

    if (dle->encrypt == ENCRYPT_CUST) {
	srvencrypt = ENCRYPT_CUST;
	clnt_encrypt = g_strdup(dle->clnt_encrypt);
	clnt_decrypt_opt = g_strdup(dle->clnt_decrypt_opt);
    } else if (dle->encrypt == ENCRYPT_SERV_CUST) {
	srvencrypt = ENCRYPT_SERV_CUST;
	srv_encrypt = g_strdup(dle->srv_encrypt);
	srv_decrypt_opt = g_strdup(dle->srv_decrypt_opt);
    } else {
	srvencrypt = ENCRYPT_NONE;
    }

    if (dle->kencrypt) {
	dumper_kencrypt = KENCRYPT_WILL_DO;
    } else {
	dumper_kencrypt = KENCRYPT_NONE;
    }

    free_dle(dle);
    amfree(o);
}


int
main(
    int		argc,
    char **	argv)
{
    static struct databuf db;
    struct cmdargs *cmdargs = NULL;
    int outfd = -1;
    int rc;
    in_port_t header_port;
    char *q = NULL;
    int a;
    int res;
    config_overrides_t *cfg_ovr = NULL;
    char *cfg_opt = NULL;
    char *argv0;
    char *stream_msg = NULL;

    if (argc > 1 && argv && argv[1] && g_str_equal(argv[1], "--version")) {
	printf("dumper-%s\n", VERSION);
	return (0);
    }

    glib_init();

    /*
     * Configure program for internationalization:
     *   1) Only set the message locale for now.
     *   2) Set textdomain for all amanda related programs to "amanda"
     *      We don't want to be forced to support dozens of message catalogs.
     */
    setlocale(LC_MESSAGES, "C");
    textdomain("amanda");
    make_crc_table();

    if (geteuid() != getuid()) {
	error(_("dumper must not be setuid root"));
    }

    /* drop root privileges */
    set_root_privs(-1);

    safe_fd(-1, 0);

    set_pname("dumper");

    dbopen(DBG_SUBDIR_SERVER);

    /* Don't die when child closes pipe */
    signal(SIGPIPE, SIG_IGN);

    add_amanda_log_handler(amanda_log_stderr);
    add_amanda_log_handler(amanda_log_trace_log);

    cfg_ovr = extract_commandline_config_overrides(&argc, &argv);
    argv0 = argv[0];
    if (argc > 1)
	cfg_opt = argv[1];
    set_config_overrides(cfg_ovr);

    log_filename = NULL;
    if (argc > 3) {
	if (g_str_equal(argv[2], "--log-filename")) {
	    log_filename = g_strdup(argv[3]);
	    set_logname(log_filename);
	    argv += 2;
	    argc -= 2;
	}
    }

    config_init_with_global(CONFIG_INIT_EXPLICIT_NAME | CONFIG_INIT_USE_CWD, cfg_opt);

    if (config_errors(NULL) >= CFGERR_ERRORS) {
	g_critical(_("errors processing config file"));
    }

    safe_cd(); /* do this *after* config_init() */

    check_running_as(RUNNING_AS_UID_ONLY);

    dbrename(get_config_name(), DBG_SUBDIR_SERVER);

    our_features = am_init_feature_set();
    our_feature_string = am_feature_to_string(our_features);

    log_add(L_INFO, "%s pid %ld", get_pname(), (long)getpid());
    g_fprintf(stderr,
	    _("%s: pid %ld executable %s version %s\n"),
	    get_pname(), (long) getpid(),
	    argv0, VERSION);
    fflush(stderr);

    /* now, make sure we are a valid user */

    signal(SIGPIPE, SIG_IGN);

    conf_dtimeout = (time_t)getconf_int(CNF_DTIMEOUT);

    protocol_init();

    do {
	if (cmdargs)
	    free_cmdargs(cmdargs);
	cmdargs = getcmd();

	amfree(errstr);
	switch(cmdargs->cmd) {
	case START:
	    if(cmdargs->argc <  2)
		error(_("error [dumper START: not enough args: timestamp]"));
	    g_free(dumper_timestamp);
	    dumper_timestamp = g_strdup(cmdargs->argv[1]);
	    break;

	case ABORT:
	    break;

	case QUIT:
	    break;

	case PORT_DUMP:
	case SHM_DUMP:
	    /*
	     * PORT-DUMP or SHM-DUMP
	     *   handle
	     *   port
	     *   src_ip
	     *   host
	     *   features
	     *   disk
	     *   device
	     *   level
	     *   dumpdate
	     *   progname
	     *   amandad_path
	     *   client_username
	     *   ssl_fingerprint_file
	     *   ssl_cert_file
	     *   ssl_key_file
	     *   ssl_ca_cert_file
	     *   ssl_cipher_list
	     *   ssl_check_certificate_host
	     *   client_port
	     *   ssh_keys
	     *   security_driver
	     *   data_path
	     *   dataport_list (PORT-DUMP) or shm_name (SHM-DUMP)
	     *   options
	     */
	    a = 1; /* skip "PORT-DUMP" */

	    assert(!shm_thread);
	    assert(!shm_thread_mutex);
	    assert(!shm_thread_cond);
	    assert(!shm_ring_consumer);
	    assert(!shm_ring_direct);
	    write_to = "output";

	    if(a >= cmdargs->argc) {
		error(_("error [dumper PORT-DUMP: not enough args: handle]"));
		/*NOTREACHED*/
	    }
	    g_free(handle);
	    handle = g_strdup(cmdargs->argv[a++]);

	    if(a >= cmdargs->argc) {
		error(_("error [dumper PORT-DUMP: not enough args: port]"));
		/*NOTREACHED*/
	    }
	    header_port = (in_port_t)atoi(cmdargs->argv[a++]);

	    if(a >= cmdargs->argc) {
		error(_("error [dumper PORT-DUMP: not enough args: src_ip]"));
		/*NOTREACHED*/
	    }
	    g_free(src_ip);
	    src_ip = g_strdup(cmdargs->argv[a++]);

	    if(a >= cmdargs->argc) {
		error(_("error [dumper PORT-DUMP: not enough args: maxdumps]"));
		/*NOTREACHED*/
	    }
	    g_free(maxdumps);
	    maxdumps = g_strdup(cmdargs->argv[a++]);

	    if(a >= cmdargs->argc) {
		error(_("error [dumper PORT-DUMP: not enough args: hostname]"));
		/*NOTREACHED*/
	    }
	    g_free(hostname);
	    hostname = g_strdup(cmdargs->argv[a++]);

	    if(a >= cmdargs->argc) {
		error(_("error [dumper PORT-DUMP: not enough args: features]"));
		/*NOTREACHED*/
	    }
	    am_release_feature_set(their_features);
	    their_features = am_string_to_feature(cmdargs->argv[a++]);

	    if(a >= cmdargs->argc) {
		error(_("error [dumper PORT-DUMP: not enough args: diskname]"));
		/*NOTREACHED*/
	    }
	    g_free(diskname);
	    diskname = g_strdup(cmdargs->argv[a++]);
	    if (qdiskname != NULL)
		amfree(qdiskname);
	    qdiskname = quote_string(diskname);
	    b64disk = amxml_format_tag("disk", diskname);

	    if(a >= cmdargs->argc) {
		error(_("error [dumper PORT-DUMP: not enough args: device]"));
		/*NOTREACHED*/
	    }
	    g_free(device);
	    device = g_strdup(cmdargs->argv[a++]);
	    b64device = amxml_format_tag("diskdevice", device);
	    if(g_str_equal(device, "NODEVICE"))
		amfree(device);

	    if(a >= cmdargs->argc) {
		error(_("error [dumper PORT-DUMP: not enough args: level]"));
		/*NOTREACHED*/
	    }
	    level = atoi(cmdargs->argv[a++]);

	    if(a >= cmdargs->argc) {
		error(_("error [dumper PORT-DUMP: not enough args: dumpdate]"));
		/*NOTREACHED*/
	    }
	    g_free(dumpdate);
	    dumpdate = g_strdup(cmdargs->argv[a++]);

	    if(a >= cmdargs->argc) {
		error(_("error [dumper PORT-DUMP: not enough args: program]"));
		/*NOTREACHED*/
	    }
	    g_free(progname);
	    progname = g_strdup(cmdargs->argv[a++]);

	    if(a >= cmdargs->argc) {
		error(_("error [dumper PORT-DUMP: not enough args: amandad_path]"));
		/*NOTREACHED*/
	    }
	    g_free(amandad_path);
	    amandad_path = g_strdup(cmdargs->argv[a++]);

	    if(a >= cmdargs->argc) {
		error(_("error [dumper PORT-DUMP: not enough args: client_username]"));
	    }
	    g_free(client_username);
	    client_username = g_strdup(cmdargs->argv[a++]);

	    if(a >= cmdargs->argc) {
		error(_("error [dumper PORT-DUMP: not enough args: ssl_fingerprint_file]"));
	    }
	    g_free(ssl_fingerprint_file);
	    ssl_fingerprint_file = g_strdup(cmdargs->argv[a++]);

	    if(a >= cmdargs->argc) {
		error(_("error [dumper PORT-DUMP: not enough args: ssl_cert_file]"));
	    }
	    g_free(ssl_cert_file);
	    ssl_cert_file = g_strdup(cmdargs->argv[a++]);

	    if(a >= cmdargs->argc) {
		error(_("error [dumper PORT-DUMP: not enough args: ssl_key_file]"));
	    }
	    g_free(ssl_key_file);
	    ssl_key_file = g_strdup(cmdargs->argv[a++]);

	    if(a >= cmdargs->argc) {
		error(_("error [dumper PORT-DUMP: not enough args: ssl_ca_cert_file]"));
	    }
	    g_free(ssl_ca_cert_file);
	    ssl_ca_cert_file = g_strdup(cmdargs->argv[a++]);

	    if(a >= cmdargs->argc) {
		error(_("error [dumper PORT-DUMP: not enough args: ssl_cipher_list]"));
	    }
	    g_free(ssl_cipher_list);
	    ssl_cipher_list = g_strdup(cmdargs->argv[a++]);

	    if(a >= cmdargs->argc) {
		error(_("error [dumper PORT-DUMP: not enough args: ssl_check_certificate_host]"));
	    }
	    g_free(ssl_check_certificate_host);
	    ssl_check_certificate_host = g_strdup(cmdargs->argv[a++]);

	    if(a >= cmdargs->argc) {
		error(_("error [dumper PORT-DUMP: not enough args: client_port]"));
	    }
	    g_free(client_port);
	    client_port = g_strdup(cmdargs->argv[a++]);

	    if(a >= cmdargs->argc) {
		error(_("error [dumper PORT-DUMP: not enough args: ssh_keys]"));
	    }
	    g_free(ssh_keys);
	    ssh_keys = g_strdup(cmdargs->argv[a++]);

	    if(a >= cmdargs->argc) {
		error(_("error [dumper PORT-DUMP: not enough args: auth]"));
	    }
	    g_free(auth);
	    auth = g_strdup(cmdargs->argv[a++]);

	    if(a >= cmdargs->argc) {
		error(_("error [dumper PORT-DUMP: not enough args: data_path]"));
	    }
	    data_path = data_path_from_string(cmdargs->argv[a++]);

	    amfree(dataport_list);
	    amfree(shm_name);
	    if (cmdargs->cmd == PORT_DUMP) {
		if(a >= cmdargs->argc) {
		    error(_("error [dumper PORT-DUMP: not enough args: dataport_list]"));
		}
		dataport_list = g_strdup(cmdargs->argv[a++]);
		if (data_path == DATA_PATH_DIRECTTCP && *dataport_list == '\0') {
		    error(_("error [dumper PORT-DUMP: dataport_list empty for DIRECTTCP]"));
		}
	    } else { // SHM_DUMP
		if(a >= cmdargs->argc) {
		    error(_("error [dumper SHM-DUMP: not enough args: shm_name]"));
		    /*NOTREACHED*/
		}
		shm_name = g_strdup(cmdargs->argv[a++]);
	    }


	    if(a >= cmdargs->argc) {
		error(_("error [dumper PORT-DUMP: not enough args: max_warnings]"));
	    }
	    max_warnings = atoi(cmdargs->argv[a++]);

	    if(a >= cmdargs->argc) {
		error(_("error [dumper PORT-DUMP: not enough args: options]"));
	    }
	    g_free(options);
	    options = g_strdup(cmdargs->argv[a++]);

	    if(a != cmdargs->argc) {
		error(_("error [dumper PORT-DUMP: too many args: %d != %d]"),
		      cmdargs->argc, a);
	        /*NOTREACHED*/
	    }

	    /* Double-check that 'localhost' resolves properly */
	    if ((res = resolve_hostname("localhost", 0, NULL, NULL) != 0)) {
                g_free(errstr);
                errstr = g_strdup_printf(_("could not resolve localhost: %s"),
                                         gai_strerror(res));
		q = quote_string(errstr);
		putresult(FAILED, "%s %s\n", handle, q);
		log_add(L_FAIL, "%s %s %s %d [%s]", hostname, qdiskname,
			dumper_timestamp, level, errstr);
		amfree(q);
		break;
	    }

	    /* connect outf to chunker/taper port */

	    g_debug(_("Sending header to localhost:%d"), header_port);
	    outfd = stream_client(NULL, "localhost", header_port,
				  STREAM_BUFSIZE, 0, NULL, 0, &stream_msg);
	    if (outfd == -1 || stream_msg) {

		g_free(errstr);
		if (stream_msg) {
		    errstr = g_strdup_printf(_("port open: %s"), stream_msg);
		    g_free(stream_msg);
		} else {
		    errstr = g_strdup_printf(_("port open: %s"), strerror(errno));
		}
		q = quote_string(errstr);
		putresult(FAILED, "%s %s\n", handle, q);
		log_add(L_FAIL, "%s %s %s %d [%s]", hostname, qdiskname,
			dumper_timestamp, level, errstr);
		amfree(amandad_path);
		amfree(client_username);
		amfree(client_port);
		amfree(device);
		amfree(b64device);
		amfree(qdiskname);
		amfree(b64disk);
		amfree(q);
		break;
	    }
	    shm_ring_consumer = NULL;
	    shm_ring_direct = NULL;
	    databuf_init(&db, outfd);
	    g_databuf = &db;

	    if (am_has_feature(their_features, fe_req_xml))
		xml_check_options(options); /* note: modifies globals */
	    else
		check_options(options); /* note: modifies globals */

	    if (msg.buf) msg.buf[0] = '\0';	/* reset msg buffer */
	    status = 0;
	    dump_result = 0;
	    retry_delay = -1;
	    retry_level = -1;
	    amfree(retry_message);
	    dumpbytes = dumpsize = headersize = origsize = (off_t)0;

#ifdef FAILURE_CODE
	    {
		if (disable_network_shm == -1) {
		    char *A = getenv("DISABLE_NETWORK_SHM");
		    if (A)
			disable_network_shm = 1;
		    else
			disable_network_shm = 0;
		}
	    }
#endif

	    rc = startup_dump(hostname,
			      diskname,
			      device,
			      level,
			      dumpdate,
			      progname,
			      amandad_path,
			      client_username,
			      ssl_fingerprint_file,
			      ssl_cert_file,
			      ssl_key_file,
			      ssl_ca_cert_file,
			      ssl_cipher_list,
			      ssl_check_certificate_host,
			      client_port,
			      ssh_keys,
			      auth,
			      options);
#ifdef FAILURE_CODE
	    if (dumper_try_again==0) {
		char *A = getenv("DUMPER_TRY_AGAIN");
		if (A) {
		    rc=1;
		    errstr=g_strdup("DUMPER-TRY-AGAIN");
		    dumper_try_again=1;
		}
	    }
#endif
	    if (rc == 3) {
		log_add(L_RETRY, "%s %s %s %d delay %d level %d message %s",
			hostname, qdiskname, dumper_timestamp, level,
			retry_delay, retry_level, retry_message);
		putresult(RETRY, _("%s %d %d %s\n"), handle, retry_delay,
			  retry_level, retry_message);
	    } else if (rc != 0) {
		q = quote_string(errstr);
		putresult(rc == 2? FAILED : TRYAGAIN, "%s %s\n",
		    handle, q);
		log_add(L_FAIL, "%s %s %s %d [%s]", hostname, qdiskname,
			dumper_timestamp, level, errstr);
		amfree(q);
	    } else {
		do_dump(&db);
		/* try to clean up any defunct processes, since Amanda doesn't
		   wait() for them explicitly */
		while(waitpid(-1, NULL, WNOHANG)> 0);
	    }

	    if (db.shm_ring_producer) {
		close_producer_shm_ring(db.shm_ring_producer);
		db.shm_ring_producer = NULL;
	    }
	    if (db.shm_ring_consumer) {
		close_consumer_shm_ring(db.shm_ring_consumer);
		db.shm_ring_consumer = NULL;
	    }
	    if (db.shm_ring_direct) {
		close_producer_shm_ring(db.shm_ring_direct);
		db.shm_ring_direct = NULL;
	    }
	    shm_ring_consumer = NULL;
	    shm_ring_direct = NULL;
	    aclose(statefile_in_stream);
	    aclose(statefile_in_mesg);
	    //aclose(indexout);
	    if (g_databuf) aclose(g_databuf->fd);
	    amfree(shm_name);
	    amfree(amandad_path);
	    amfree(client_username);
	    amfree(ssl_fingerprint_file);
	    amfree(ssl_cert_file);
	    amfree(ssl_key_file);
	    amfree(ssl_ca_cert_file);
	    amfree(ssl_cipher_list);
	    amfree(client_port);
	    amfree(device);
	    amfree(b64device);
	    amfree(qdiskname);
	    amfree(b64disk);

	    break;

	default:
	    if(cmdargs->argc >= 1) {
		q = quote_string(cmdargs->argv[0]);
	    } else {
		q = g_strdup(_("(no input?)"));
	    }
	    putresult(BAD_COMMAND, "%s\n", q);
	    amfree(q);
	    break;
	}

	if (outfd != -1)
	    aclose(outfd);
    } while(cmdargs->cmd != QUIT);
    free_cmdargs(cmdargs);
    cmdargs = NULL;

    log_add(L_INFO, "pid-done %ld", (long)getpid());

    am_release_feature_set(our_features);
    amfree(our_feature_string);
    amfree(errstr);
    amfree(dumper_timestamp);
    amfree(handle);
    amfree(hostname);
    amfree(qdiskname);
    amfree(diskname);
    amfree(device);
    amfree(dumpdate);
    amfree(progname);
    amfree(srvcompprog);
    amfree(clntcompprog);
    amfree(srv_encrypt);
    amfree(clnt_encrypt);
    amfree(srv_decrypt_opt);
    amfree(clnt_decrypt_opt);
    amfree(options);
    amfree(log_filename);

    dbclose();
    return (0); /* exit */
}


/*
 * Initialize a databuf.  Takes a writeable file descriptor.
 */
static void
databuf_init(
    struct databuf *	db,
    int			fd)
{

    db->fd = fd;
    db->buf = NULL;
    db->datain = db->dataout = db->datalimit = NULL;
    db->compresspid = -1;
    db->encryptpid = -1;
    db->shm_ring_producer = NULL;
    db->shm_ring_consumer = NULL;
    db->shm_ring_direct = NULL;
    db->shm_readx = 0;
}


/*
 * Updates the buffer pointer for the input data buffer.  The buffer is
 * written regardless of how much data is present, since we know we
 * are writing to a socket (to chunker) and there is no need to maintain
 * any boundaries.
 */
static int
databuf_write(
    struct databuf *	db,
    const void *	buf,
    size_t		size)
{
    db->buf = (char *)buf;
    db->datain = db->datalimit = db->buf + size;
    db->dataout = db->buf;
    return databuf_flush(db);
}

/*
 * Write out the buffer to chunker.
 */
static int
databuf_flush(
    struct databuf *	db)
{
    size_t written;
    char *m;

    /*
     * If there's no data, do nothing.
     */
    if (db->dataout >= db->datain) {
	return 0;
    }

    /*
     * Write out the buffer
     */
    written = full_write(db->fd, db->dataout,
			(size_t)(db->datain - db->dataout));
    if (written > 0) {
	crc32_add((uint8_t *)db->dataout, written, &crc_data_out);
	db->dataout += written;
        dumpbytes += (off_t)written;
    }
    if (dumpbytes >= (off_t)1024) {
	dumpsize += (dumpbytes / (off_t)1024);
	dumpbytes %= (off_t)1024;
    }
    if (written == 0) {
	int save_errno = errno;
	m = g_strdup_printf(_("data write1: %s"), strerror(save_errno));
	amfree(errstr);
	errstr = quote_string(m);
	amfree(m);
	errno = save_errno;
	return -1;
    }
    db->datain = db->dataout = db->buf;
    return 0;
}

static void
process_dumpeof(void)
{
    /* process any partial line in msgbuf? !!! */
    add_msg_data(NULL, 0);
    if(!ISSET(status, GOT_SIZELINE) && dump_result < 2) {
	/* make a note if there isn't already a failure */
	g_fprintf(errf,
		_("? %s: strange [missing size line from sendbackup]\n"),
		get_pname());
	if(errstr == NULL) {
	    errstr = g_strdup(_("missing size line from sendbackup"));
	}
	dump_result = max(dump_result, 2);
    }

    if(!ISSET(status, GOT_ENDLINE) && dump_result < 2) {
	g_fprintf(errf,
		_("? %s: strange [missing end line from sendbackup]\n"),
		get_pname());
	if(errstr == NULL) {
	    errstr = g_strdup(_("missing end line from sendbackup"));
	}
	dump_result = max(dump_result, 2);
    }
}

/*
 * Parse an information line from the client.
 * We ignore unknown parameters and only remember the last
 * of any duplicates.
 */
static void
parse_info_line(
    char *str)
{
    static const struct {
	const char *name;
	char *value;
	size_t len;
    } fields[] = {
	{ "BACKUP", file.program, sizeof(file.program) },
	{ "APPLICATION", file.application, sizeof(file.application) },
	{ "RECOVER_CMD", file.recover_cmd, sizeof(file.recover_cmd) },
	{ "COMPRESS_SUFFIX", file.comp_suffix, sizeof(file.comp_suffix) },
	{ "SERVER_CUSTOM_COMPRESS", file.srvcompprog, sizeof(file.srvcompprog) },
	{ "CLIENT_CUSTOM_COMPRESS", file.clntcompprog, sizeof(file.clntcompprog) },
	{ "SERVER_ENCRYPT", file.srv_encrypt, sizeof(file.srv_encrypt) },
	{ "CLIENT_ENCRYPT", file.clnt_encrypt, sizeof(file.clnt_encrypt) },
	{ "SERVER_DECRYPT_OPTION", file.srv_decrypt_opt, sizeof(file.srv_decrypt_opt) },
	{ "CLIENT_DECRYPT_OPTION", file.clnt_decrypt_opt, sizeof(file.clnt_decrypt_opt) }
    };
    char *name, *value;
    size_t i;

    if (g_str_equal(str, "end")) {
	SET(status, GOT_INFO_ENDLINE);
	return;
    }

    name = strtok(str, "=");
    if (name == NULL)
	return;
    value = strtok(NULL, "");
    if (value == NULL)
	return;

    for (i = 0; i < sizeof(fields) / sizeof(fields[0]); i++) {
	if (g_str_equal(name, fields[i].name)) {
	    strncpy(fields[i].value, value, fields[i].len - 1);
	    fields[i].value[fields[i].len - 1] = '\0';
	    break;
	}
    }
}

static void
process_dumpline(
    const char *	str)
{
    char *buf, *tok;

    buf = g_strdup(str);

    dumper_debug(1, "process_dumpline: %s", str);
    switch (*buf) {
    case '|':
	/* normal backup output line */
	break;
    case '?':
	/* sendbackup detected something strange */
	dump_result = max(dump_result, 1);
	break;
    case 's':
	/* a sendbackup line, just check them all since there are only 5 */
	tok = strtok(buf, " ");
	if (tok == NULL || !g_str_equal(tok, "sendbackup:"))
	    goto bad_line;

	tok = strtok(NULL, " ");
	if (tok == NULL)
	    goto bad_line;

	if (g_str_equal(tok, "start")) {
	    break;
	}

	if (g_str_equal(tok, "size")) {
	    tok = strtok(NULL, "");
	    if (tok != NULL) {
		origsize = OFF_T_ATOI(tok);
		SET(status, GOT_SIZELINE);
	    }
	    break;
	}

	if (g_str_equal(tok, "no-op")) {
	    amfree(buf);
	    return;
	}

	if (g_str_equal(tok, "state")) {
	    if (statefile_in_stream != -1) {
		g_debug("state in mesg when state in stream already open");
	    } else {
		tok = strtok(NULL, "");
		if (tok) {
		    if (!broken_statefile_in_mesg) {
			if (statefile_in_mesg == -1) {
			    statefile_in_mesg = open(state_filename_gz,
					O_WRONLY | O_CREAT | O_TRUNC, 0600);
			    if (statefile_in_mesg == -1) {
				g_debug("Can't open statefile '%s': %s",
					state_filename_gz, strerror(errno));
				broken_statefile_in_mesg = TRUE;
			    } else {
				if (runcompress(statefile_in_mesg, &statepid, COMP_BEST, "state compress") < 0) {
				    aclose(statefile_in_mesg);
				    broken_statefile_in_mesg = TRUE;
				}
			    }
			}
			if (statefile_in_mesg != -1) {
			    size_t len = strlen(tok);
			    tok[len] = '\n';
			    if (full_write(statefile_in_mesg, tok, len+1) < len+1) {
				g_debug("Failed to write to state file: %s",
					strerror(errno));
				broken_statefile_in_mesg = TRUE;
			    }
			    tok[len] = '\0';
			}
		    }
		} else {
		    g_debug("Invalid state");
		}
	    }
	    amfree(buf);
	    return;
	}
	if (g_str_equal(tok, "statedone")) {
	    aclose(statefile_in_mesg);
	    amfree(buf);
	    return;
	}

	if (g_str_equal(tok, "native-CRC")) {
	    tok = strtok(NULL, "");
	    if (tok) {
		parse_crc(tok, &native_crc);
		g_debug("native-CRC: %08x:%lld", native_crc.crc,
			(long long)native_crc.size);
	    } else {
		g_debug("invalid native-CRC");
	    }
	    amfree(buf);
	    break;
	}

	if (g_str_equal(tok, "client-CRC")) {
	    tok = strtok(NULL, "");
	    if (tok) {
		parse_crc(tok, &client_crc);
		g_debug("client-CRC: %08x:%lld", client_crc.crc,
			(long long)client_crc.size);
	    } else {
		g_debug("invalid client-CRC");
	    }
	    amfree(buf);
	    break;
	}

	if (g_str_equal(tok, "retry")) {
	    tok = strtok(NULL, " ");
	    SET(status, GOT_RETRY);
	    if (tok && g_str_equal(tok, "delay")) {
		tok = strtok(NULL, " ");
		if (tok) {
		    retry_delay = atoi(tok);
		}
		tok = strtok(NULL, " ");
	    }
	    if (tok && g_str_equal(tok, "level")) {
		tok = strtok(NULL, " ");
		if (tok) {
		    retry_level = atoi(tok);
		}
		tok = strtok(NULL, " ");
	    }
	    if (tok && g_str_equal(tok, "message")) {
		tok = strtok(NULL, "");
		if (tok) {
		     retry_message = g_strdup(tok);
		} else {
		    retry_message = g_strdup("\"No message\"");
		}
	    } else {
		retry_message = g_strdup("\"No message\"");
	    }
            stop_dump();
	    break;
	}

	if (g_str_equal(tok, "end")) {
	    SET(status, GOT_ENDLINE);
	    break;
	}

	if (g_str_equal(tok, "warning")) {
	    dump_result = max(dump_result, 1);
	    break;
	}

	if (g_str_equal(tok, "error")) {
	    SET(status, GOT_ENDLINE);
	    dump_result = max(dump_result, 2);

	    tok = strtok(NULL, "");
	    if (!errstr) { /* report first error line */
		if (tok == NULL || *tok != '[') {
		    g_free(errstr);
		    errstr = g_strdup_printf(_("bad remote error: %s"), str);
		} else {
		    char *enderr;

		    tok++;	/* skip over '[' */
		    if ((enderr = strchr(tok, ']')) != NULL)
			*enderr = '\0';
		    g_free(errstr);
		    errstr = g_strdup(tok);
		}
	    }
	    break;
	}

	if (g_str_equal(tok, "info")) {
	    tok = strtok(NULL, "");
	    if (tok != NULL)
		parse_info_line(tok);
	    break;
	}
	/* else we fall through to bad line */
	// fallthrough
    default:
bad_line:
	/* prefix with ?? */
	g_fprintf(errf, "??");
	dump_result = max(dump_result, 1);
	break;
    }
    g_fprintf(errf, "%s\n", str);
    errf_lines++;
    amfree(buf);
}

static void
add_msg_data(
    const char *	str,
    size_t		len)
{
    char *line, *ch;
    size_t buflen;

    if (msg.buf != NULL)
	buflen = strlen(msg.buf);
    else
	buflen = 0;

    /*
     * If our argument is NULL, then we need to flush out any remaining
     * bits and return.
     */
    if (str == NULL) {
	if (buflen == 0)
	    return;
	g_fprintf(errf,_("? %s: error [partial line in msgbuf: %zu bytes]\n"),
	    get_pname(), buflen);
	g_fprintf(errf,_("? %s: error [partial line in msgbuf: \"%s\"]\n"),
	    get_pname(), msg.buf);
	msg.buf[0] = '\0';
	return;
    }

    /*
     * Expand the buffer if it can't hold the new contents.
     */
    if (!msg.buf || (buflen + len + 1) > msg.size) {
	char *newbuf;
	size_t newsize;

/* round up to next y, where y is a power of 2 */
#define	ROUND(x, y)	(((x) + (y) - 1) & ~((y) - 1))

	newsize = ROUND(buflen + (ssize_t)len + 1, 256);
	newbuf = g_malloc(newsize);

	if (msg.buf != NULL) {
	    strncpy(newbuf, msg.buf, newsize);
	    amfree(msg.buf);
	} else
	    newbuf[0] = '\0';
	msg.buf = newbuf;
	msg.size = newsize;
    }

    /*
     * If there was a partial line from the last call, then
     * append the new data to the end.
     */
    strncat(msg.buf, str, len);

    /*
     * Process all lines in the buffer
     * scanning line for unqouted newline.
     */
    for (ch = line = msg.buf; *ch != '\0'; ch++) {
	if (*ch == '\n') {
	    /*
	     * Found a newline.  Terminate and process line.
	     */
	    *ch = '\0';
	    process_dumpline(line);
	    line = ch + 1;
	}
    }

    /*
     * If we did not process all of the data, move it to the front
     * of the buffer so it is there next time.
     */
    if (*line != '\0') {
	buflen = strlen(line);
	memmove(msg.buf, line, (size_t)buflen + 1);
    } else {
	msg.buf[0] = '\0';
    }
}


static int
log_msgout(
    logtype_t	typ)
{
    char *line;
    int   count = 0;
    int   to_unlink = 1;

    fflush(errf);
    if (fseeko(errf, 0L, SEEK_SET) < 0) {
	dbprintf(_("log_msgout: warning - seek failed: %s\n"), strerror(errno));
    }
    while ((line = pgets(errf)) != NULL) {
	if (max_warnings > 0 && errf_lines >= max_warnings && count >= max_warnings) {
	    log_add(typ, "Look in the '%s' file for full error messages", errfname);
	    to_unlink = 0;
	    break;
	}
	if (line[0] != '\0') {
		log_add(typ, "%s", line);
	}
	amfree(line);
	count++;
    }
    amfree(line);

    return to_unlink;
}

/* ------------- */

/*
 * Fill in the rest of the tape header
 */
static void
finish_tapeheader(
    dumpfile_t *file)
{

    assert(ISSET(status, HEADER_DONE));

    file->type = F_DUMPFILE;
    strncpy(file->datestamp, dumper_timestamp, sizeof(file->datestamp) - 1);
    strncpy(file->name, hostname, sizeof(file->name) - 1);
    strncpy(file->disk, diskname, sizeof(file->disk) - 1);
    file->dumplevel = level;
    file->blocksize = DISK_BLOCK_BYTES;

    /*
     * If we're doing the compression here, we need to override what
     * sendbackup told us the compression was.
     */
    if (srvcompress != COMP_NONE) {
	file->compressed = 1;
#ifndef UNCOMPRESS_OPT
#define	UNCOMPRESS_OPT	""
#endif
	if (srvcompress == COMP_SERVER_CUST) {
	    g_snprintf(file->uncompress_cmd, sizeof(file->uncompress_cmd),
		     " %s %s |", srvcompprog, "-d");
	    strncpy(file->comp_suffix, "cust", sizeof(file->comp_suffix) - 1);
	    file->comp_suffix[sizeof(file->comp_suffix) - 1] = '\0';
	    strncpy(file->srvcompprog, srvcompprog, sizeof(file->srvcompprog) - 1);
	    file->srvcompprog[sizeof(file->srvcompprog) - 1] = '\0';
	} else if ( srvcompress == COMP_CUST ) {
	    g_snprintf(file->uncompress_cmd, sizeof(file->uncompress_cmd),
		     " %s %s |", clntcompprog, "-d");
	    strncpy(file->comp_suffix, "cust", sizeof(file->comp_suffix) - 1);
	    file->comp_suffix[sizeof(file->comp_suffix) - 1] = '\0';
	    strncpy(file->clntcompprog, clntcompprog, sizeof(file->clntcompprog));
	    file->clntcompprog[sizeof(file->clntcompprog) - 1] = '\0';
	} else {
	    g_snprintf(file->uncompress_cmd, sizeof(file->uncompress_cmd),
		" %s %s |", UNCOMPRESS_PATH, UNCOMPRESS_OPT);
	    strncpy(file->comp_suffix, COMPRESS_SUFFIX,sizeof(file->comp_suffix) - 1);
	    file->comp_suffix[sizeof(file->comp_suffix) - 1] = '\0';
	}
    } else {
	if (file->comp_suffix[0] == '\0') {
	    file->compressed = 0;
	    assert(sizeof(file->comp_suffix) >= 2);
	    strncpy(file->comp_suffix, "N", sizeof(file->comp_suffix) - 1);
	    file->comp_suffix[sizeof(file->comp_suffix) - 1] = '\0';
	} else {
	    file->compressed = 1;
	}
    }
    /* take care of the encryption header here */
    if (srvencrypt != ENCRYPT_NONE) {
      file->encrypted= 1;
      if (srvencrypt == ENCRYPT_SERV_CUST) {
	if (srv_decrypt_opt) {
	  g_snprintf(file->decrypt_cmd, sizeof(file->decrypt_cmd),
		   " %s %s |", srv_encrypt, srv_decrypt_opt); 
	  strncpy(file->srv_decrypt_opt, srv_decrypt_opt, sizeof(file->srv_decrypt_opt) - 1);
	  file->srv_decrypt_opt[sizeof(file->srv_decrypt_opt) - 1] = '\0';
	} else {
	  g_snprintf(file->decrypt_cmd, sizeof(file->decrypt_cmd),
		   " %s |", srv_encrypt); 
	  file->srv_decrypt_opt[0] = '\0';
	}
	strncpy(file->encrypt_suffix, "enc", sizeof(file->encrypt_suffix) - 1);
	file->encrypt_suffix[sizeof(file->encrypt_suffix) - 1] = '\0';
	strncpy(file->srv_encrypt, srv_encrypt, sizeof(file->srv_encrypt) - 1);
	file->srv_encrypt[sizeof(file->srv_encrypt) - 1] = '\0';
      } else if ( srvencrypt == ENCRYPT_CUST ) {
	if (clnt_decrypt_opt) {
	  g_snprintf(file->decrypt_cmd, sizeof(file->decrypt_cmd),
		   " %s %s |", clnt_encrypt, clnt_decrypt_opt);
	  strncpy(file->clnt_decrypt_opt, clnt_decrypt_opt,
		  sizeof(file->clnt_decrypt_opt));
	  file->clnt_decrypt_opt[sizeof(file->clnt_decrypt_opt) - 1] = '\0';
	} else {
	  g_snprintf(file->decrypt_cmd, sizeof(file->decrypt_cmd),
		   " %s |", clnt_encrypt);
	  file->clnt_decrypt_opt[0] = '\0';
 	}
	g_snprintf(file->decrypt_cmd, sizeof(file->decrypt_cmd),
		 " %s %s |", clnt_encrypt, clnt_decrypt_opt);
	strncpy(file->encrypt_suffix, "enc", sizeof(file->encrypt_suffix) - 1);
	file->encrypt_suffix[sizeof(file->encrypt_suffix) - 1] = '\0';
	strncpy(file->clnt_encrypt, clnt_encrypt, sizeof(file->clnt_encrypt) - 1);
	file->clnt_encrypt[sizeof(file->clnt_encrypt) - 1] = '\0';
      }
    } else {
      if (file->encrypt_suffix[0] == '\0') {
	file->encrypted = 0;
	assert(sizeof(file->encrypt_suffix) >= 2);
	strncpy(file->encrypt_suffix, "N", sizeof(file->encrypt_suffix) - 1);
	file->encrypt_suffix[sizeof(file->encrypt_suffix) - 1] = '\0';
      } else {
	file->encrypted= 1;
      }
    }
    if (dle_str)
	file->dle_str = g_strdup(dle_str);
    else
	file->dle_str = NULL;
}

/*
 * Send an Amanda dump header to the output file.
 */
static ssize_t
write_tapeheader(
    int		outfd,
    dumpfile_t *file)
{
    char * buffer;
    size_t written;

    if (debug_dumper > 1)
	dump_dumpfile_t(file);
    buffer = build_header(file, NULL, DISK_BLOCK_BYTES);
    if (!buffer) /* this shouldn't happen */
	error(_("header does not fit in %zd bytes"), (size_t)DISK_BLOCK_BYTES);

    written = full_write(outfd, buffer, DISK_BLOCK_BYTES);
    amfree(buffer);
    if(written == DISK_BLOCK_BYTES)
        return 0;

    return -1;
}

int indexout = -1;

static int
do_dump(
    struct databuf *db)
{
    char *indexfile_tmp = NULL;
    char *indexfile_real = NULL;
    char level_str[NUM_STR_SIZE];
    char *time_str;
    char *fn;
    char *q;
    times_t runtime;
    double dumptime;	/* Time dump took in secs */
    pid_t indexpid = -1;
    char *m;
    int to_unlink = 1;

    startclock();

    if (msg.buf) msg.buf[0] = '\0';	/* reset msg buffer */
    fh_init(&file);

    g_snprintf(level_str, sizeof(level_str), "%d", level);
    time_str = get_timestamp_from_time(0);
    fn = sanitise_filename(diskname);
    errf_lines = 0;

    g_free(errfname);
    errfname = g_strconcat(AMANDA_DBGDIR, "/log.error", NULL);

    if (mkdir(errfname, 0700) == -1) {
	if (errno != EEXIST) {
	    g_free(errstr);
	    errstr = g_strdup_printf("Create directory \"%s\": %s",
				     errfname, strerror(errno));
	    amfree(errfname);
	    goto failed;
	}
    }

    g_free(errfname);
    errfname = g_strconcat(AMANDA_DBGDIR, "/log.error/", hostname, ".", fn, ".",
        level_str, ".", time_str, ".errout", NULL);

    amfree(fn);
    amfree(time_str);
    if((errf = fopen(errfname, "w+")) == NULL) {
	g_free(errstr);
	errstr = g_strdup_printf("errfile open \"%s\": %s",
                                 errfname, strerror(errno));
	amfree(errfname);
	goto failed;
    }

    state_filename = getstatefname(hostname, diskname, dumper_timestamp, level);
    state_filename_gz = g_strdup_printf("%s%s", state_filename,
						COMPRESS_SUFFIX);

    if (streams[INDEXFD].fd != NULL) {
	if (getconf_boolean(CNF_COMPRESS_INDEX)) {
	    indexfile_real = getindex_unsorted_gz_fname(hostname, diskname, dumper_timestamp, level);
	} else {
	    indexfile_real = getindex_unsorted_fname(hostname, diskname, dumper_timestamp, level);
	}
	indexfile_tmp = g_strconcat(indexfile_real, ".tmp", NULL);

	if (mkpdir(indexfile_tmp, 0755, (uid_t)-1, (gid_t)-1) == -1) {
            g_free(errstr);
            errstr = g_strdup_printf(_("err create %s: %s"),
                                     indexfile_tmp, strerror(errno));
            amfree(indexfile_real);
            amfree(indexfile_tmp);
            goto failed;
	}
	indexout = open(indexfile_tmp, O_WRONLY | O_CREAT | O_TRUNC, 0600);
	if (indexout == -1) {
	    g_free(errstr);
	    errstr = g_strdup_printf(_("err open %s: %s"),
                                     indexfile_tmp, strerror(errno));
	    goto failed;
	} else if (getconf_boolean(CNF_COMPRESS_INDEX)) {
	    if (runcompress(indexout, &indexpid, COMP_BEST, "index compress") < 0) {
		aclose(indexout);
		goto failed;
	    }
	}
	indexfderror = 0;
	/*
	 * Schedule the indexfd for relaying to the index file
	 */
	security_stream_read(streams[INDEXFD].fd, read_indexfd, &indexout);
    }

    /*
     * We only need to process messages initially.  Once we have done
     * the header, we will start processing data too.
     */
    security_stream_read(streams[MESGFD].fd, read_mesgfd, db);
    set_datafd = 0;

    if (data_path == DATA_PATH_AMANDA) {
	if (shm_name && !shm_ring_consumer) {
	    if (g_str_equal(auth, "local") &&
#ifdef FAILURE_CODE
		disable_network_shm < 1 &&
#endif
		am_has_feature(their_features, fe_sendbackup_req_options_data_shm_control_name)) {
		// shm_ring direct
		db->shm_ring_direct = shm_ring_direct;
		shm_ring_direct = NULL;
		shm_thread_mutex = g_mutex_new();
		shm_thread_cond  = g_cond_new();
		shm_thread = g_thread_create(handle_shm_ring_direct,
				(gpointer)db, TRUE, NULL);
	    } else {
		// stream to shm_ring
		db->shm_ring_producer = shm_ring_link(shm_name);
		//db->shm_ring_producer->mc->need_sem_ready++;
		security_stream_read_to_shm_ring(streams[DATAFD].fd, read_datafd,
						 db->shm_ring_producer, db);
		set_datafd = 1;
	    }
	} else if (shm_ring_consumer) {
	    if (g_str_equal(auth, "local") &&
#ifdef FAILURE_CODE
		disable_network_shm < 1 &&
#endif
		am_has_feature(their_features, fe_sendbackup_req_options_data_shm_control_name)) {
		// ring to fd (server filter)
		db->shm_ring_consumer = shm_ring_consumer;
		db->crc = &crc_data_in;
		shm_ring_consumer = NULL;
		shm_ring_consumer_set_size(db->shm_ring_consumer,
					   NETWORK_BLOCK_BYTES*4,
					   NETWORK_BLOCK_BYTES);
		shm_thread_mutex = g_mutex_new();
		shm_thread_cond  = g_cond_new();
		shm_thread = g_thread_create(handle_shm_ring_to_fd_thread,
				(gpointer)db, TRUE, NULL);
	    } else {
		// stream to fd
	    }
	}
    } else { // data_path == DATA_PATH_DIRECTTCP
	if (streams[DATAFD].fd) {
	    security_stream_close(streams[DATAFD].fd);
	    streams[DATAFD].fd = NULL;
	}
    }

    if (streams[STATEFD].fd != NULL) {
	security_stream_read(streams[STATEFD].fd, read_statefd, NULL);
    }

    /*
     * Setup a read timeout
     */
    if (shm_thread) {
	g_mutex_lock(shm_thread_mutex);
    }
    timeout(conf_dtimeout);
    if (shm_thread) {
	g_cond_broadcast(shm_thread_cond);
	g_mutex_unlock(shm_thread_mutex);
    }

    /*
     * Start the event loop.  This will exit when all five events
     * (read the mesgfd, read the datafd, read the indexfd, read the statefd,
     *  and timeout) are removed.
     */
    event_loop(0);

    if (shm_thread) {
	g_mutex_lock(shm_thread_mutex);
	g_cond_broadcast(shm_thread_cond);
	g_mutex_unlock(shm_thread_mutex);

	g_thread_join(shm_thread);
	shm_thread = NULL;

	g_mutex_free(shm_thread_mutex);
	shm_thread_mutex = NULL;
	g_cond_free(shm_thread_cond);
	shm_thread_cond  = NULL;
    }

    if (ISSET(status, GOT_RETRY)) {
	if (indexfile_tmp) {
	    unlink(indexfile_tmp);
	}
	log_add(L_RETRY, "%s %s %s %d delay %d level %d message %s",
			 hostname, qdiskname, dumper_timestamp, level,
			 retry_delay, retry_level, retry_message);
	putresult(RETRY, _("%s %d %d %s\n"), handle, retry_delay, retry_level,
					     retry_message);

	// should kill filter
	// should close all file descriptors
	return 1;
    }

    if (client_crc.crc == 0) {
	client_crc = crc_data_in;
    }

    if (!shm_name &&
	client_crc.crc != 0 &&
	(client_crc.crc  != crc_data_in.crc ||
	 client_crc.size != crc_data_in.size)) {
	dump_result = max(dump_result, 2);
	if (!errstr) errstr = g_strdup_printf(_("client CRC (%08x:%lld) do not match data-in CRC (%08x:%lld)"), client_crc.crc, (long long)client_crc.size, crc_data_in.crc, (long long)crc_data_in.size);
    }

    if (!shm_name &&
	(crc_data_in.crc  != crc_data_out.crc ||
	 crc_data_in.size != crc_data_out.size)) {
	dump_result = max(dump_result, 2);
	if (!errstr) errstr = g_strdup_printf(_("data-in CRC (%08x:%lld) do not match data-out CRC (%08x:%lld)"), crc_data_in.crc, (long long)crc_data_in.size, crc_data_out.crc, (long long)crc_data_out.size);
    }

    if (!ISSET(status, HEADER_DONE)) {
	dump_result = max(dump_result, 2);
	if (!errstr) errstr = g_strdup(_("got no header information"));
    }

    dumpsize -= headersize;		/* don't count the header */
    if (shm_name) {
	if (db->shm_ring_producer) {
	    if (db->shm_ring_producer->mc->written > 0 && db->shm_ring_producer->mc->written < 1024) {
		dumpsize = 1;
	    } else {
		dumpsize = (long long)db->shm_ring_producer->mc->written/1024;
	    }
	} else if (db->shm_ring_direct) {
	    if (db->shm_ring_direct->mc->written > 0 && db->shm_ring_direct->mc->written < 1024) {
		dumpsize = 1;
	    } else {
		dumpsize = (long long)db->shm_ring_direct->mc->written/1024;
	    }
	} else {
	    if (client_crc.size > 0 && client_crc.size < 1024) {
		dumpsize = 1;
	    } else {
		dumpsize = (long long)client_crc.size/1024;
	    }
	}
    } else if (db->shm_ring_consumer) {
	    if (db->shm_ring_consumer->mc->written > 0 && db->shm_ring_consumer->mc->written < 1024) {
		dumpsize = 1;
	    } else {
		dumpsize = (long long)db->shm_ring_consumer->mc->written/1024;
	    }
    }

    if (dumpsize <= (off_t)0 && (data_path == DATA_PATH_AMANDA)) {
	dumpsize = (off_t)0;
	dump_result = max(dump_result, 2);
	if (!errstr) errstr = g_strdup(_("got no data"));
    }

    if (data_path == DATA_PATH_DIRECTTCP) {
	dumpsize = origsize;
    }

    if (!ISSET(status, HEADER_DONE)) {
	dump_result = max(dump_result, 2);
	if (!errstr) errstr = g_strdup(_("got no header information"));
    }

    if (indexfile_tmp) {
	amwait_t index_status;

	/*@i@*/ aclose(indexout);
	if (indexpid > 0) {
	    waitpid(indexpid,&index_status,0);
	    log_add(L_INFO, "pid-done %ld", (long)indexpid);
	}
	if (rename(indexfile_tmp, indexfile_real) != 0) {
	    log_add(L_WARNING, _("could not rename \"%s\" to \"%s\": %s"),
		    indexfile_tmp, indexfile_real, strerror(errno));
	}
	amfree(indexfile_tmp);
	amfree(indexfile_real);
    }

    /* copy the header in a file on the index dir */
    if (ISSET(status, HEADER_SENT)) {
	FILE *a;
	char *s;
	char *f = getheaderfname(hostname, diskname, dumper_timestamp, level);
	a = fopen(f,"w");
	if (a) {
	    s = build_header(&file, NULL, DISK_BLOCK_BYTES);
	    fprintf(a,"%s", s);
	    g_free(s);
	    fclose(a);
	}
	g_free(f);
    }

    if (db->compresspid != -1) {
	amwait_t  wait_status;
	char *errmsg = NULL;

	waitpid(db->compresspid, &wait_status, 0);
	if (WIFSIGNALED(wait_status)) {
	    errmsg = g_strdup_printf(_("%s terminated with signal %d"),
				     "data compress:", WTERMSIG(wait_status));
	} else if (WIFEXITED(wait_status)) {
	    if (WEXITSTATUS(wait_status) != 0) {
		errmsg = g_strdup_printf(_("%s exited with status %d"),
					 "data compress:", WEXITSTATUS(wait_status));
	    }
	} else {
	    errmsg = g_strdup_printf(_("%s got bad exit"),
				     "data compress: ");
	}
	if (errmsg) {
	    g_fprintf(errf, _("? %s\n"), errmsg);
	    g_debug("%s", errmsg);
	    dump_result = max(dump_result, 2);
	    if (!errstr)
		errstr = errmsg;
	    else
		g_free(errmsg);
	}
	log_add(L_INFO, "pid-done %ld", (long)db->compresspid);
	db->compresspid = -1;
    }

    if (db->encryptpid != -1) {
	amwait_t  wait_status;
	char *errmsg = NULL;

	waitpid(db->encryptpid, &wait_status, 0);
	if (WIFSIGNALED(wait_status)) {
	    errmsg = g_strdup_printf(_("%s terminated with signal %d"),
				     "data encrypt:", WTERMSIG(wait_status));
	} else if (WIFEXITED(wait_status)) {
	    if (WEXITSTATUS(wait_status) != 0) {
		errmsg = g_strdup_printf(_("%s exited with status %d"),
					 "data encrypt:", WEXITSTATUS(wait_status));
	    }
	} else {
	    errmsg = g_strdup_printf(_("%s got bad exit"),
				     "data encrypt:");
	}
	if (errmsg) {
	    g_fprintf(errf, _("? %s\n"), errmsg);
	    g_debug("%s", errmsg);
	    dump_result = max(dump_result, 2);
	    if (!errstr)
		errstr = errmsg;
	    else
		g_free(errmsg);
	}
	log_add(L_INFO, "pid-done %ld", (long)db->encryptpid);
	db->encryptpid  = -1;
    }

    if (dump_result > 1)
	goto failed;

    runtime = stopclock();
    dumptime = g_timeval_to_double(runtime);

    amfree(errstr);
    errstr = g_malloc(128);
    g_snprintf(errstr, 128, _("sec %s kb %lld kps %3.1lf orig-kb %lld"),
	walltime_str(runtime),
	(long long)dumpsize,
	(isnormal(dumptime) ? ((double)dumpsize / (double)dumptime) : 0.0),
	(long long)origsize);
    m = g_strdup_printf("[%s]", errstr);
    q = quote_string(m);
    amfree(m);
    putresult(DONE, _("%s %lld %lld %lu %08x:%lld %08x:%lld %s\n"), handle,
		(long long)origsize,
		(long long)dumpsize,
	        (unsigned long)((double)dumptime+0.5),
		native_crc.crc, (long long)native_crc.size,
		client_crc.crc, (long long)client_crc.size, q);
    amfree(q);

    switch(dump_result) {
    case 0:
	log_add(L_SUCCESS, "%s %s %s %d %08x:%lld %08x:%lld [%s]",
		hostname, qdiskname, dumper_timestamp, level,
		native_crc.crc, (long long)native_crc.size,
		client_crc.crc, (long long) client_crc.size, errstr);

	break;

    case 1:
	log_start_multiline();
	log_add(L_STRANGE, "%s %s %d %08x:%lld %08x:%lld [%s]",
		hostname, qdiskname, level,
		native_crc.crc, (long long)native_crc.size,
		client_crc.crc, (long long)client_crc.size, errstr);
	to_unlink = log_msgout(L_STRANGE);
	log_end_multiline();

	break;
    }

    if (errf)
	afclose(errf);
    if (errfname) {
	if (to_unlink)
	    unlink(errfname);
	amfree(errfname);
    }

    if (data_path == DATA_PATH_AMANDA)
	aclose(db->fd);

    amfree(state_filename);
    amfree(state_filename_gz);
    amfree(errstr);
    dumpfile_free_data(&file);

    return 1;

failed:
    m = g_strdup_printf("[%s]", errstr);
    q = quote_string(m);
    putresult(FAILED, "%s %s\n", handle, q);
    amfree(q);
    amfree(m);

    aclose(db->fd);
    /* kill all child process */
    if (db->compresspid != -1) {
	g_fprintf(stderr,_("%s: kill compress command\n"),get_pname());
	if (kill(db->compresspid, SIGTERM) < 0) {
	    if (errno != ESRCH) {
		g_fprintf(stderr,_("%s: can't kill compress command: %s\n"), 
		    get_pname(), strerror(errno));
	    } else {
		log_add(L_INFO, "pid-done %ld", (long)db->compresspid);
	    }
	}
	else {
	    waitpid(db->compresspid,NULL,0);
	    log_add(L_INFO, "pid-done %ld", (long)db->compresspid);
	}
    }

    if (db->encryptpid != -1) {
	g_fprintf(stderr,_("%s: kill encrypt command\n"),get_pname());
	if (kill(db->encryptpid, SIGTERM) < 0) {
	    if (errno != ESRCH) {
		g_fprintf(stderr,_("%s: can't kill encrypt command: %s\n"), 
		    get_pname(), strerror(errno));
	    } else {
		log_add(L_INFO, "pid-done %ld", (long)db->encryptpid);
	    }
	}
	else {
	    waitpid(db->encryptpid,NULL,0);
	    log_add(L_INFO, "pid-done %ld", (long)db->encryptpid);
	}
    }

    if (indexpid != -1) {
	g_fprintf(stderr,_("%s: kill index command\n"),get_pname());
	if (kill(indexpid, SIGTERM) < 0) {
	    if (errno != ESRCH) {
		g_fprintf(stderr,_("%s: can't kill index command: %s\n"), 
		    get_pname(),strerror(errno));
	    } else {
		log_add(L_INFO, "pid-done %ld", (long)indexpid);
	    }
	}
	else {
	    waitpid(indexpid,NULL,0);
	    log_add(L_INFO, "pid-done %ld", (long)indexpid);
	}
    }

    log_start_multiline();
    log_add(L_FAIL, _("%s %s %s %d [%s]"), hostname, qdiskname, dumper_timestamp,
	    level, errstr);
    if (errf) {
	to_unlink = log_msgout(L_FAIL);
    }
    log_end_multiline();

    if (errf)
	afclose(errf);
    if (errfname) {
	if (to_unlink)
	    unlink(errfname);
	amfree(errfname);
    }

    if (indexfile_tmp) {
	unlink(indexfile_tmp);
	amfree(indexfile_tmp);
	amfree(indexfile_real);
    }

    amfree(errstr);
    dumpfile_free_data(&file);

    return 0;
}

static gpointer
handle_shm_ring_to_fd_thread(
    gpointer data)
{
    struct databuf *db = (struct databuf *)data;
    uint64_t     read_offset;
    uint64_t     shm_ring_size;
    gsize        usable = 0;
    gboolean     eof_flag = FALSE;
    shm_ring_size = db->shm_ring_consumer->mc->ring_size;

    sem_post(db->shm_ring_consumer->sem_write);
    while (!db->shm_ring_consumer->mc->cancelled) {
	do {
	    if (shm_ring_sem_wait(db->shm_ring_consumer, db->shm_ring_consumer->sem_read) != 0)
		break;
	    usable = db->shm_ring_consumer->mc->written - db->shm_ring_consumer->mc->readx;
	    eof_flag = db->shm_ring_consumer->mc->eof_flag;
	} while (!db->shm_ring_consumer->mc->cancelled &&
		 usable < db->shm_ring_consumer->block_size && !eof_flag);
	read_offset = db->shm_ring_consumer->mc->read_offset;

	/* write the header on the first bytes */
	if (usable > 0 && db->shm_ring_consumer->mc->readx == 0 && !ISSET(status, HEADER_SENT)) {
	    in_port_t data_port;
	    char *data_host = g_strdup(dataport_list);
	    char *s;
	    char *stream_msg = NULL;

	    g_mutex_lock(shm_thread_mutex);
	    while (!ISSET(status, GOT_INFO_ENDLINE) || !ISSET(status, HEADER_DONE)) {
		g_debug("D sleep while waiting for HEADER_DONE");
		g_cond_wait(shm_thread_cond, shm_thread_mutex);
	    }
	    if (dump_result > 0) {
		g_cond_broadcast(shm_thread_cond);
		g_mutex_unlock(shm_thread_mutex);
		return NULL;
	    }

	    s = strchr(data_host, ',');
	    if (s) *s = '\0';  /* use first data_port */
	    s = strrchr(data_host, ':');
	    if (!s) {
		g_free(errstr);
		errstr = g_strdup("write_tapeheader: no dataport_list");
		dump_result = 2;
		amfree(data_host);
		stop_dump();
		g_cond_broadcast(shm_thread_cond);
		g_mutex_unlock(shm_thread_mutex);
		return NULL;
	    }
	    *s = '\0';
	    s++;
	    data_port = atoi(s);

	    if (!header_sent(db)) {
		g_cond_broadcast(shm_thread_cond);
		g_mutex_unlock(shm_thread_mutex);
		return NULL;
	    }

	    if (g_str_equal(data_host,"255.255.255.255")) {
	    }
	    g_debug(_("Sending data to %s:%d\n"), data_host, data_port);
	    db->fd = stream_client(NULL, data_host, data_port,
				   STREAM_BUFSIZE, 0, NULL, 0, &stream_msg);
	    if (db->fd == -1 || stream_msg) {
		g_free(errstr);
		if (stream_msg) {
		    errstr = g_strdup_printf("Can't open data output stream: %s",
					 stream_msg);
		    g_free(stream_msg);
		} else {
		    errstr = g_strdup_printf("Can't open data output stream: %s",
					 strerror(errno));
		}
		dump_result = 2;
		amfree(data_host);
		stop_dump();
		g_cond_broadcast(shm_thread_cond);
		g_mutex_unlock(shm_thread_mutex);
		return NULL;
	    }
	    amfree(data_host);
	    dumpsize += (off_t)DISK_BLOCK_KB;
	    headersize += (off_t)DISK_BLOCK_KB;

	    if (srvencrypt == ENCRYPT_SERV_CUST) {
		write_to = "encryption program";
		if (runencrypt(db->fd, &db->encryptpid, srvencrypt, "data encrypt") < 0) {
		    dump_result = 2;
		    aclose(db->fd);
		    stop_dump();
		    g_cond_broadcast(shm_thread_cond);
		    g_mutex_unlock(shm_thread_mutex);
		    return NULL;
		}
	    }
	    /*
	     * Now, setup the compress for the data output, and start
	     * reading the datafd.
	     */
	    if ((srvcompress != COMP_NONE) && (srvcompress != COMP_CUST)) {
		write_to = "compression program";
		if (runcompress(db->fd, &db->compresspid, srvcompress, "data compress") < 0) {
		    dump_result = 2;
		    aclose(db->fd);
		    stop_dump();
		    g_cond_broadcast(shm_thread_cond);
		    g_mutex_unlock(shm_thread_mutex);
		    return NULL;
		}
	    }
	    g_cond_broadcast(shm_thread_cond);
	    g_mutex_unlock(shm_thread_mutex);
	}

	while (usable >= db->shm_ring_consumer->block_size || eof_flag) {
	    gsize to_write = usable;
	    if (to_write > db->shm_ring_consumer->block_size)
		to_write = db->shm_ring_consumer->block_size;

	    if (to_write + read_offset <= shm_ring_size) {
		if (full_write(db->fd, db->shm_ring_consumer->data + read_offset, to_write) != to_write) {
		    errstr = g_strdup_printf("write to %s failed: %s", write_to, strerror(errno));
		    g_debug("%s", errstr);
		    g_mutex_lock(shm_thread_mutex);
		    db->shm_ring_consumer->mc->cancelled = TRUE;
		    sem_post(db->shm_ring_consumer->sem_write);
		    dump_result = 2;
		    aclose(db->fd);
		    stop_dump();
		    g_cond_broadcast(shm_thread_cond);
		    g_mutex_unlock(shm_thread_mutex);
		    return NULL;
		}
		if (db->crc) {
		    crc32_add((uint8_t *)db->shm_ring_consumer->data + read_offset, to_write,
			      db->crc);
		}
	    } else {
		if (full_write(db->fd, db->shm_ring_consumer->data + read_offset,
			   shm_ring_size - read_offset) != shm_ring_size - read_offset) {
		    errstr = g_strdup_printf("write to %s failed: %s", write_to, strerror(errno));
		    g_debug("%s", errstr);
		    g_mutex_lock(shm_thread_mutex);
		    db->shm_ring_consumer->mc->cancelled = TRUE;
		    sem_post(db->shm_ring_consumer->sem_write);
		    dump_result = 2;
		    aclose(db->fd);
		    stop_dump();
		    g_cond_broadcast(shm_thread_cond);
		    g_mutex_unlock(shm_thread_mutex);
		    return NULL;
		}
		if (full_write(db->fd, db->shm_ring_consumer->data,
			   to_write - shm_ring_size + read_offset) != to_write - shm_ring_size + read_offset) {
		    errstr = g_strdup_printf("write to %s failed: %s", write_to, strerror(errno));
		    g_debug("%s", errstr);
		    g_mutex_lock(shm_thread_mutex);
		    db->shm_ring_consumer->mc->cancelled = TRUE;
		    sem_post(db->shm_ring_consumer->sem_write);
		    dump_result = 2;
		    aclose(db->fd);
		    stop_dump();
		    g_cond_broadcast(shm_thread_cond);
		    g_mutex_unlock(shm_thread_mutex);
		    return NULL;
		}
		if (db->crc) {
		    crc32_add((uint8_t *)db->shm_ring_consumer->data + read_offset, shm_ring_size - read_offset, db->crc);
		    crc32_add((uint8_t *)db->shm_ring_consumer->data, usable - shm_ring_size + read_offset, db->crc);
		}
	    }
	    if (usable) {
		read_offset += to_write;
		if (read_offset >= shm_ring_size)
		    read_offset -= shm_ring_size;
		db->shm_ring_consumer->mc->read_offset = read_offset;
		db->shm_ring_consumer->mc->readx += to_write;
		sem_post(db->shm_ring_consumer->sem_write);
		usable -= to_write;
	    }
	    if (db->shm_ring_consumer->mc->write_offset == db->shm_ring_consumer->mc->read_offset &&
		db->shm_ring_consumer->mc->eof_flag) {
		// notify the producer that everythinng is read
		sem_post(db->shm_ring_consumer->sem_write);
		goto shm_done;
	    }
	}
    }

shm_done:
    g_mutex_lock(shm_thread_mutex);
    aclose(db->fd);
    g_cond_broadcast(shm_thread_cond);
    g_mutex_unlock(shm_thread_mutex);

    return NULL;
}

static gpointer
handle_shm_ring_direct(
    gpointer data)
{
    struct databuf *db = (struct databuf *)data;

    if (shm_ring_sem_wait(db->shm_ring_direct, db->shm_ring_direct->sem_ready) != 0) {
	g_mutex_lock(shm_thread_mutex);
	dump_result = 2;
        stop_dump();
        goto shm_done;
    }
    g_mutex_lock(shm_thread_mutex);

//    s = strchr(data_host, ',');
//    if (s) *s = '\0';  /* use first data_port */
//    s = strrchr(data_host, ':');
//    if (!s) {
//	g_free(errstr);
//	errstr = g_strdup("write_tapeheader: no dataport_list");
//	dump_result = 2;
//	amfree(data_host);
//	stop_dump();
//	goto shm_done;
//    }
//    *s = '\0';
//    s++;
//    data_port = atoi(s);

    while (dump_result == 0 &&
	   (!ISSET(status, GOT_INFO_ENDLINE) || !ISSET(status, HEADER_DONE))) {
	g_debug("D sleep while waiting for HEADER_DONE");
	g_cond_wait(shm_thread_cond, shm_thread_mutex);
    }
    if (dump_result > 0) {
	goto shm_done;
    }

    if (!header_sent(db)) {
	goto shm_done;
    }

//    if (g_str_equal(data_host,"255.255.255.255")) {
//    }
//    g_debug(_("Sending data to %s:%d\n"), data_host, data_port);
//    db->fd = stream_client(NULL, data_host, data_port,
//				   STREAM_BUFSIZE, 0, NULL, 0);
//    if (db->fd == -1) {
//	g_free(errstr);
//	errstr = g_strdup_printf("Can't open data output stream: %s",
//				 strerror(errno));
//	dump_result = 2;
//	amfree(data_host);
//	stop_dump();
//	goto shm_done;
//    }
//    amfree(data_host);
    dumpsize += (off_t)DISK_BLOCK_KB;
    headersize += (off_t)DISK_BLOCK_KB;

shm_done:
    db->shm_ring_direct->mc->need_sem_ready--;
    if (db->shm_ring_direct->mc->need_sem_ready == 0) {
	sem_post(db->shm_ring_direct->sem_start);
    } else {
	sem_post(db->shm_ring_direct->sem_ready);
    }
    g_cond_broadcast(shm_thread_cond);
    g_mutex_unlock(shm_thread_mutex);
    return NULL;
}

/*
 * Callback for reads on the statefile stream
 */
static void
read_statefd(
    void *	cookie G_GNUC_UNUSED,
    void *	buf,
    ssize_t     size)
{
    assert(cookie == NULL);

    switch (size) {
    case -1:
	if (shm_thread) {
	    g_mutex_lock(shm_thread_mutex);
	}
	if (statefile_in_stream != -1) {
	    aclose(statefile_in_stream);
	}

	if (streams[STATEFD].fd) {
	    g_free(errstr);
	    errstr = g_strdup_printf("state read: %s",
                                     security_stream_geterror(streams[STATEFD].fd));
	}
	dump_result = 2;
	stop_dump();
	if (shm_thread) {
	    g_cond_broadcast(shm_thread_cond);
	    g_mutex_unlock(shm_thread_mutex);
	}
	return;

    case 0:
	/*
	 * EOF.  Just shut down the state stream.
	 */
	if (shm_thread) {
	    g_mutex_lock(shm_thread_mutex);
	}
	if (statefile_in_stream != -1) {
	    aclose(statefile_in_stream);
	}
	if (streams[STATEFD].fd) {
	    security_stream_close(streams[STATEFD].fd);
	}
	streams[STATEFD].fd = NULL;

	/*
	 * If the data fd and index fd has also shut down, then we're done.
	 */
	if ((set_datafd == 0 || streams[DATAFD].fd == NULL) &&
	    streams[INDEXFD].fd == NULL &&
	    streams[MESGFD].fd == NULL) {
	    stop_dump();
	}
	if (shm_thread) {
	    g_cond_broadcast(shm_thread_cond);
	    g_mutex_unlock(shm_thread_mutex);
	}
	return;

    default:
	assert(buf != NULL);
	if (statefile_in_stream == -1) {
	    statefile_in_stream = open(state_filename_gz,
				       O_WRONLY | O_CREAT | O_TRUNC, 0600);
	    if (statefile_in_stream == -1) {
		g_debug("Can't open statefile '%s': %s", state_filename_gz,
					       strerror(errno));
	    } else {
		if (runcompress(statefile_in_stream, &statepid, COMP_BEST, "state compress") < 0) {
		    aclose(statefile_in_stream);
		}
	    }
	}
	if (statefile_in_stream != -1) {
	    full_write(statefile_in_stream, buf, size);
	}
	break;
    }

    if (shm_thread) {
	g_mutex_lock(shm_thread_mutex);
    }
    retimeout(conf_dtimeout);
    if (shm_thread) {
	g_cond_broadcast(shm_thread_cond);
	g_mutex_unlock(shm_thread_mutex);
    }
}

/*
 * Callback for reads on the mesgfd stream
 */
static void
read_mesgfd(
    void *	cookie,
    void *	buf,
    ssize_t	size)
{
    struct databuf *db = cookie;

    assert(db != NULL);
    if (shm_thread) {
	g_mutex_lock(shm_thread_mutex);
    }

    switch (size) {
    case -1:
	if (streams[MESGFD].fd) {
	    g_free(errstr);
	    errstr = g_strdup_printf("mesg read: %s",
                                     security_stream_geterror(streams[MESGFD].fd));
	}
	dump_result = 2;
	stop_dump();
	if (shm_thread) {
	    g_cond_broadcast(shm_thread_cond);
	    g_mutex_unlock(shm_thread_mutex);
	}
	return;

    case 0:
	/*
	 * EOF.  Just shut down the mesg stream.
	 */
	process_dumpeof();
	if (streams[MESGFD].fd) {
	    security_stream_close(streams[MESGFD].fd);
	}
	streams[MESGFD].fd = NULL;
	if (statefile_in_mesg != -1) {
	    aclose(statefile_in_mesg);
	}
	/*
	 * If the data fd and index fd has also shut down, then we're done.
	 */
	if ((set_datafd == 0 || streams[DATAFD].fd == NULL) &&
	    streams[INDEXFD].fd == NULL &&
	    streams[STATEFD].fd == NULL) {
	    stop_dump();
	}
	if (!ISSET(status, GOT_INFO_ENDLINE)) {
	    stop_dump();
	}
	if (shm_thread) {
	    g_cond_broadcast(shm_thread_cond);
	    g_mutex_unlock(shm_thread_mutex);
	}
	return;

    default:
	assert(buf != NULL);
	add_msg_data(buf, (size_t)size);
	break;
    }

    if (ISSET(status, GOT_INFO_ENDLINE) && !ISSET(status, HEADER_DONE)) {
	SET(status, HEADER_DONE);
	if (data_path == DATA_PATH_AMANDA && set_datafd == 0) {
	    security_stream_read(streams[DATAFD].fd, read_datafd, db);
	    set_datafd = 1;
	} else if (data_path == DATA_PATH_DIRECTTCP) {
	    if (!header_sent(db)) {
		g_cond_broadcast(shm_thread_cond);
		g_mutex_unlock(shm_thread_mutex);
		return;
	    }
	}
    }

    /*
     * Reset the timeout for future reads
     */
    if (!ISSET(status, GOT_RETRY)) {
	retimeout(conf_dtimeout);
    }
    if (shm_thread) {
	g_cond_broadcast(shm_thread_cond);
	g_mutex_unlock(shm_thread_mutex);
    }
}

static gboolean
header_sent(
    struct databuf *db)
{
    assert(!ISSET(status, HEADER_SENT));
    SET(status, HEADER_SENT);
    finish_tapeheader(&file);
    if (write_tapeheader(db->fd, &file)) {
	g_free(errstr);
	errstr = g_strdup_printf("write_tapeheader: %s", strerror(errno));
	dump_result = 2;
	aclose(db->fd);
	stop_dump();
	return FALSE;
    }
    aclose(db->fd);
    return TRUE;
}

/*
 * Callback for reads on the datafd stream
 */
static void
read_datafd(
    void *	cookie,
    void *	buf,
    ssize_t	size)
{
    struct databuf *db = cookie;

    assert(db != NULL);
    if (shm_thread) {
	g_mutex_lock(shm_thread_mutex);
    }

    /*
     * The read failed.  Error out
     */
    if (size < 0) {
	if (streams[DATAFD].fd) {
	    g_free(errstr);
	    errstr = g_strdup_printf("data read: %s",
                                     security_stream_geterror(streams[DATAFD].fd));
	}
	dump_result = 2;
	aclose(db->fd);
	stop_dump();
	if (shm_thread) {
	    g_cond_broadcast(shm_thread_cond);
	    g_mutex_unlock(shm_thread_mutex);
	}
	return;
    }

    if (!ISSET(status, HEADER_DONE)) {
	g_critical("HEADER_DONE not set");
    }

    /* write the header on the first bytes */
    if (ISSET(status, HEADER_DONE) && !ISSET(status, HEADER_SENT) && size > 0) {
	/* Use the first in the dataport_list */
	in_port_t data_port = 0;
	char *data_host = g_strdup(dataport_list);
	char *s;

	if (data_host) {
	    s = strchr(data_host, ',');
	    if (s) *s = '\0';  /* use first data_port */
	    s = strrchr(data_host, ':');
	    if (!s) {
		g_free(errstr);
		errstr = g_strdup("write_tapeheader: no dataport_list");
		dump_result = 2;
		amfree(data_host);
		stop_dump();
		if (shm_thread) {
		    g_cond_broadcast(shm_thread_cond);
		    g_mutex_unlock(shm_thread_mutex);
		}
		return;
	    }
	    *s = '\0';
	    s++;
	    data_port = atoi(s);
	}

	if (!header_sent(db)) {
	    g_cond_broadcast(shm_thread_cond);
	    g_mutex_unlock(shm_thread_mutex);
	    return;
	}
	if (data_host) {
	if (data_path == DATA_PATH_AMANDA) {
	    char *stream_msg = NULL;
	    /* do indirecttcp */
	    if (g_str_equal(data_host,"255.255.255.255")) {
		char buffer[32770];
		char *s;
		int size;

		g_debug(_("Sending indirect data output stream: %s:%d\n"), data_host, data_port);
		db->fd = stream_client(NULL, "localhost", data_port,
				       STREAM_BUFSIZE, 0, NULL, 0, &stream_msg);
		if (db->fd == -1 || stream_msg) {
                    g_free(errstr);
		    if (stream_msg) {
			errstr = g_strdup_printf(_("Can't open indirect data output stream: %s"),
                                         stream_msg);
		    } else {
			errstr = g_strdup_printf(_("Can't open indirect data output stream: %s"),
                                         strerror(errno));
		    }
		    dump_result = 2;
		    amfree(data_host);
		    stop_dump();
		    g_cond_broadcast(shm_thread_cond);
		    g_mutex_unlock(shm_thread_mutex);
		    return;
		}
	        size = full_read(db->fd, buffer, 32768);
		if (size <= 0) {
		    g_debug("Failed to read from indirect-direct-tcp port: %s",
			    strerror(errno));
		    close(db->fd);
		    dump_result = 2;
		    amfree(data_host);
		    stop_dump();
		    if (shm_thread) {
			g_cond_broadcast(shm_thread_cond);
			g_mutex_unlock(shm_thread_mutex);
		    }
		    return;
		}
		aclose(db->fd);
		buffer[size++] = ' ';
                buffer[size] = '\0';
                if ((s = strchr(buffer, ':')) == NULL) {
		    g_debug("Failed to parse indirect data output stream: %s", buffer);
		    dump_result = 2;
		    amfree(data_host);
		    stop_dump();
		    if (shm_thread) {
			g_cond_broadcast(shm_thread_cond);
			g_mutex_unlock(shm_thread_mutex);
		    }
		    return;
                }
		*s++ = '\0';
		amfree(data_host);
		data_host = g_strdup(buffer);
		data_port = atoi(s);
	    }

	    g_debug(_("Sending data to %s:%d\n"), data_host, data_port);
	    db->fd = stream_client(NULL, data_host, data_port,
				   STREAM_BUFSIZE, 0, NULL, 0, &stream_msg);
	    if (db->fd == -1 || stream_msg) {
                g_free(errstr);
		if (stream_msg) {
                    errstr = g_strdup_printf("Can't open data output stream: %s",
                                             stream_msg);
		} else {
                    errstr = g_strdup_printf("Can't open data output stream: %s",
                                             strerror(errno));
		}
		dump_result = 2;
		amfree(data_host);
		stop_dump();
		if (shm_thread) {
		    g_cond_broadcast(shm_thread_cond);
		    g_mutex_unlock(shm_thread_mutex);
		}
		return;
	    }
	}
	amfree(data_host);

	if (srvencrypt == ENCRYPT_SERV_CUST) {
	    write_to = "encryption program";
	    if (runencrypt(db->fd, &db->encryptpid, srvencrypt, "data encrypt") < 0) {
		dump_result = 2;
		aclose(db->fd);
		stop_dump();
		if (shm_thread) {
		    g_cond_broadcast(shm_thread_cond);
		    g_mutex_unlock(shm_thread_mutex);
		}
		return;
	    }
	}
	/*
	 * Now, setup the compress for the data output, and start
	 * reading the datafd.
	 */
	if ((srvcompress != COMP_NONE) && (srvcompress != COMP_CUST)) {
	    write_to = "compression program";
	    if (runcompress(db->fd, &db->compresspid, srvcompress, "data compress") < 0) {
		dump_result = 2;
		aclose(db->fd);
		stop_dump();
		if (shm_thread) {
		    g_cond_broadcast(shm_thread_cond);
		    g_mutex_unlock(shm_thread_mutex);
		}
		return;
	    }
	}
	}

	dumpsize += (off_t)DISK_BLOCK_KB;
	headersize += (off_t)DISK_BLOCK_KB;
    }

    /*
     * EOF.  Stop and return.
     */
    if (size == 0) {
	databuf_flush(db);
	if (dumpbytes != (off_t)0) {
	    dumpsize += (off_t)1;
	}
	if (streams[DATAFD].fd) {
	    security_stream_close(streams[DATAFD].fd);
	}
	streams[DATAFD].fd = NULL;
	aclose(db->fd);
	crc_data_in.crc  = crc32_finish(&crc_data_in);
	crc_data_out.crc = crc32_finish(&crc_data_out);
	g_debug("data in  CRC: %08x:%lld",
		crc_data_in.crc, (long long)crc_data_in.size);
	g_debug("data out CRC: %08x:%lld",
		crc_data_out.crc, (long long)crc_data_out.size);
	/*
	 * If the mesg fd and index fd has also shut down, then we're done.
	 */
	if (streams[MESGFD].fd == NULL && streams[INDEXFD].fd == NULL &&
	    streams[STATEFD].fd == NULL) {
	    stop_dump();
	}
	if (shm_thread) {
	    g_cond_broadcast(shm_thread_cond);
	    g_mutex_unlock(shm_thread_mutex);
	}
	return;
    }

    if (!shm_name) {
	crc32_add(buf, size, &crc_data_in);
    }
    if (debug_auth >= 3) {
	crc_data_in.crc  = crc32_finish(&crc_data_in);
	g_debug("data in sum CRC: %08x:%lld",
		crc_data_in.crc, (long long)crc_data_in.size);
	crc_data_in.crc  = crc32_finish(&crc_data_in);
    }

    /*
     * We read something.  Add it to the databuf and reschedule for
     * more data.
     */
    if (!shm_name) {
	assert(buf != NULL);
	if (databuf_write(db, buf, (size_t)size) < 0) {
	    int save_errno = errno;
	    g_free(errstr);
	    errstr = g_strdup_printf("write to %s failed: %s", write_to, strerror(save_errno));
	    dump_result = 2;
	    stop_dump();
	    if (shm_thread) {
		g_cond_broadcast(shm_thread_cond);
		g_mutex_unlock(shm_thread_mutex);
	    }
	    return;
	}
    }

    /*
     * Reset the timeout for future reads
     */
    retimeout(conf_dtimeout);
    if (shm_thread) {
	g_cond_broadcast(shm_thread_cond);
	g_mutex_unlock(shm_thread_mutex);
    }
}

/*
 * Callback for reads on the index stream
 */
static void
read_indexfd(
    void *	cookie,
    void *	buf,
    ssize_t	size)
{
    int fd;

    assert(cookie != NULL);
    fd = *(int *)cookie;

    if (size < 0) {
	if (shm_thread) {
	    g_mutex_lock(shm_thread_mutex);
	}
	if (streams[INDEXFD].fd) {
	    g_free(errstr);
	    errstr = g_strdup_printf("index read: %s",
                                     security_stream_geterror(streams[INDEXFD].fd));
	}
	dump_result = 2;
	stop_dump();
	if (shm_thread) {
	    g_cond_broadcast(shm_thread_cond);
	    g_mutex_unlock(shm_thread_mutex);
	}
	return;
    }

    /*
     * EOF.  Stop and return.
     */
    if (size == 0) {
	if (shm_thread) {
	    g_mutex_lock(shm_thread_mutex);
	}
	if (streams[INDEXFD].fd) {
	    security_stream_close(streams[INDEXFD].fd);
	}
	streams[INDEXFD].fd = NULL;
	/*
	 * If the mesg fd has also shut down, then we're done.
	 */
	if ((set_datafd == 0 || streams[DATAFD].fd == NULL) &&
	     streams[MESGFD].fd == NULL &&
	     streams[STATEFD].fd == NULL) {
	    stop_dump();
	}
	aclose(indexout);
	if (shm_thread) {
	    g_cond_broadcast(shm_thread_cond);
	    g_mutex_unlock(shm_thread_mutex);
	}
	return;
    }

    assert(buf != NULL);

    /*
     * We ignore error while writing to the index file.
     */
    if (full_write(fd, buf, (size_t)size) < (size_t)size) {
	/* Ignore error, but schedule another read. */
	if(indexfderror == 0) {
	    indexfderror = 1;
	    log_add(L_INFO, _("Index corrupted for %s:%s"), hostname, qdiskname);
	}
    }
}

static void
handle_filter_stderr(
    void *cookie)
{
    filter_t *filter = cookie;
    ssize_t   nread;
    char     *b, *p;
    gint64    len;

    if (filter->buffer == NULL) {
	/* allocate initial buffer */
	filter->buffer = g_malloc(2048);
	filter->first = 0;
	filter->size = 0;
	filter->allocated_size = 2048;
    } else if (filter->first > 0) {
	if (filter->allocated_size - filter->size - filter->first < 1024) {
	    memmove(filter->buffer, filter->buffer + filter->first,
				    filter->size);
	    filter->first = 0;
	}
    } else if (filter->allocated_size - filter->size < 1024) {
	/* double the size of the buffer */
	filter->allocated_size *= 2;
	filter->buffer = g_realloc(filter->buffer, filter->allocated_size);
    }

    nread = read(filter->fd, filter->buffer + filter->first + filter->size,
			     filter->allocated_size - filter->first - filter->size - 2);

    if (nread <= 0) {
	event_release(filter->event);
	filter->event = NULL;
	aclose(filter->fd);
	if (filter->size > 0 && filter->buffer[filter->first + filter->size - 1] != '\n') {
	    /* Add a '\n' at end of buffer */
	    filter->buffer[filter->first + filter->size] = '\n';
	    filter->size++;
	}
    } else {
	filter->size += nread;
    }

    /* process all complete lines */
    b = filter->buffer + filter->first;
    b[filter->size] = '\0';
    while (b < filter->buffer + filter->first + filter->size &&
	   (p = strchr(b, '\n')) != NULL) {
	*p = '\0';
	if (p != b) {
	    g_fprintf(errf, _("? %s: %s\n"), filter->name, b);
	    if (errstr == NULL) {
	        errstr = g_strdup(b);
	    }
	}
	len = p - b + 1;
	filter->first += len;
	filter->size -= len;
	b = p + 1;
	dump_result = max(dump_result, 1);
    }

    if (nread <= 0) {
	g_free(filter->name);
	g_free(filter->buffer);
	g_free(filter);
    }
}

/*
 * Startup a timeout in the event handler.  If the arg is 0,
 * then remove the timeout.
 */
static event_handle_t *ev_timeout = NULL;
static time_t timeout_time;

static void
timeout(
    time_t seconds)
{
    timeout_time = time(NULL) + seconds;

    /*
     * remove a timeout if seconds is 0
     */
    if (seconds == 0) {
	if (ev_timeout != NULL) {
	    event_release(ev_timeout);
	    ev_timeout = NULL;
	}
	return;
    }

    /*
     * schedule a timeout if it not already scheduled
     */
    if (ev_timeout == NULL) {
	ev_timeout = event_create((event_id_t)seconds+1, EV_TIME,
				  timeout_callback, NULL);
	event_activate(ev_timeout);
    }
}

/*
 * Change the timeout_time, but do not set a timeout event
 */
static void
retimeout(
    time_t seconds)
{
    timeout_time = time(NULL) + seconds;

    /*
     * remove a timeout if seconds is 0
     */
    if (seconds == 0) {
	if (ev_timeout != NULL) {
	    event_release(ev_timeout);
	    ev_timeout = NULL;
	}
	return;
    }
}

/*
 * This is the callback for timeout().  If this is reached, then we
 * have a data timeout.
 */

static void
timeout_callback(
    void *	unused)
{
    time_t now = time(NULL);
    (void)unused;	/* Quiet unused parameter warning */

    if (ev_timeout != NULL) {
	event_release(ev_timeout);
	ev_timeout = NULL;
    }

    if (g_databuf->shm_ring_direct &&
	!g_databuf->shm_ring_direct->mc->cancelled &&
	!g_databuf->shm_ring_direct->mc->eof_flag) {
	if (g_databuf->shm_readx != g_databuf->shm_ring_direct->mc->readx) {
	    g_databuf->shm_readx = g_databuf->shm_ring_direct->mc->readx;
	    timeout_time = time(NULL) + conf_dtimeout;
	}
    }

    if (g_databuf->shm_ring_consumer &&
	!g_databuf->shm_ring_consumer->mc->cancelled &&
	!g_databuf->shm_ring_consumer->mc->eof_flag) {
	if (g_databuf->shm_readx != g_databuf->shm_ring_consumer->mc->readx) {
	    g_databuf->shm_readx = g_databuf->shm_ring_consumer->mc->readx;
	    timeout_time = time(NULL) + conf_dtimeout;
	}
    }

    if (timeout_time > now) { /* not a data timeout yet */
	ev_timeout = event_create((event_id_t)(timeout_time-now+1), EV_TIME,
				  timeout_callback, NULL);
	event_activate(ev_timeout);
	return;
    }

    assert(unused == NULL);
    g_free(errstr);
    errstr = g_strdup(_("data timeout"));
    dump_result = 2;
    stop_dump();
}

/*
 * This is called when everything needs to shut down so event_loop()
 * will exit.
 */
static void
stop_dump(void)
{
    guint i;
    struct cmdargs *cmdargs = NULL;

    /* Check if I have a pending ABORT command */
    cmdargs = get_pending_cmd();
    if (cmdargs) {
	if (cmdargs->cmd == QUIT) {
	    g_debug("Got unexpected QUIT");
	    log_add(L_FAIL, "%s %s %s %d [Killed while dumping]",
		    hostname, qdiskname, dumper_timestamp, level);
	    exit(1);
	}
	if (cmdargs->cmd != ABORT) {
	    g_debug("Expected an ABORT command, got '%d': %s", cmdargs->cmd, cmdstr[cmdargs->cmd]);
	    exit(1);
	}
	amfree(errstr);
	errstr = g_strdup("Aborted by driver");
	free_cmdargs(cmdargs);
    }

    for (i = 0; i < NSTREAMS; i++) {
	if (streams[i].fd != NULL) {
	    security_stream_read_cancel(streams[i].fd);
	    security_stream_close(streams[i].fd);
	    streams[i].fd = NULL;
	}
    }

    if (dump_result > 1) {
	if (g_databuf->shm_ring_producer) {
	    g_debug("stop_dump: cancelling shm-ring-producer");
	    g_databuf->shm_ring_producer->mc->cancelled = TRUE;
	    if (g_databuf->shm_ring_producer->mc->need_sem_ready) {
		g_databuf->shm_ring_producer->mc->need_sem_ready--;
		sem_post(g_databuf->shm_ring_producer->sem_ready);
	    }
	    sem_post(g_databuf->shm_ring_producer->sem_read);
	    sem_post(g_databuf->shm_ring_producer->sem_write);
	}
	if (g_databuf->shm_ring_consumer) {
	    g_debug("stop_dump: cancelling shm-ring-consumer");
	    g_databuf->shm_ring_consumer->mc->cancelled = TRUE;
	    if (g_databuf->shm_ring_consumer->mc->need_sem_ready) {
		g_databuf->shm_ring_consumer->mc->need_sem_ready--;
		sem_post(g_databuf->shm_ring_consumer->sem_ready);
	    }
	    sem_post(g_databuf->shm_ring_consumer->sem_read);
	    sem_post(g_databuf->shm_ring_consumer->sem_write);
	    g_debug("stop_dump done: cancelling shm-ring-consumer");
	}
	if (g_databuf->shm_ring_direct) {
	    g_debug("stop_dump: cancelling shm-ring-direct");
	    g_databuf->shm_ring_direct->mc->cancelled = TRUE;
	    if (g_databuf->shm_ring_direct->mc->need_sem_ready) {
		g_databuf->shm_ring_direct->mc->need_sem_ready--;
		sem_post(g_databuf->shm_ring_direct->sem_ready);
	    }
	    sem_post(g_databuf->shm_ring_direct->sem_read);
	    sem_post(g_databuf->shm_ring_direct->sem_write);
	}
    }
    aclose(statefile_in_stream);
    aclose(statefile_in_mesg);
    aclose(indexout);
    aclose(g_databuf->fd);
    timeout(0);
}


/*
 * Runs compress with the first arg as its stdout.  Returns
 * 0 on success or negative if error, and it's pid via the second
 * argument.  The outfd arg is dup2'd to the pipe to the compress
 * process.
 */
static int
runcompress(
    int		outfd,
    pid_t *	pid,
    comp_t	comptype,
    char       *name)
{
    int outpipe[2], rval;
    int errpipe[2];
    filter_t *filter;

    assert(outfd >= 0);
    assert(pid != NULL);

    /* outpipe[0] is pipe's stdin, outpipe[1] is stdout. */
    if (pipe(outpipe) < 0) {
	g_free(errstr);
	errstr = g_strdup_printf(_("pipe: %s"), strerror(errno));
	return (-1);
    }

    /* errpipe[0] is pipe's output, outpipe[1] is input. */
    if (pipe(errpipe) < 0) {
	g_free(errstr);
	errstr = g_strdup_printf(_("pipe: %s"), strerror(errno));
	return (-1);
    }

    if (comptype != COMP_SERVER_CUST) {
	g_debug("execute: %s %s", COMPRESS_PATH,
		comptype == COMP_BEST ? COMPRESS_BEST_OPT : COMPRESS_FAST_OPT);
    } else {
	g_debug("execute: %s", srvcompprog);
    }
    switch (*pid = fork()) {
    case -1:
	g_free(errstr);
	errstr = g_strdup_printf(_("couldn't fork: %s"), strerror(errno));
	aclose(outpipe[0]);
	aclose(outpipe[1]);
	aclose(errpipe[0]);
	aclose(errpipe[1]);
	return (-1);
    default:
	rval = dup2(outpipe[1], outfd);
	if (rval < 0) {
	    g_free(errstr);
	    errstr = g_strdup_printf(_("couldn't dup2: %s"), strerror(errno));
	}
	aclose(outpipe[1]);
	aclose(outpipe[0]);
	aclose(errpipe[1]);
	filter = g_new0(filter_t, 1);
	filter->fd = errpipe[0];
	filter->name = g_strdup(name);
	filter->buffer = NULL;
	filter->size = 0;
	filter->allocated_size = 0;
	filter->event = event_create((event_id_t)filter->fd, EV_READFD,
				     handle_filter_stderr, filter);
	event_activate(filter->event);
	return (rval);
    case 0:
	close(outpipe[1]);
	close(errpipe[0]);
	if (dup2(outpipe[0], 0) < 0) {
	    error(_("err dup2 in: %s"), strerror(errno));
	    /*NOTREACHED*/
	}
	if (dup2(outfd, 1) == -1) {
	    error(_("err dup2 out: %s"), strerror(errno));
	    /*NOTREACHED*/
	}
	if (dup2(errpipe[1], 2) == -1) {
	    error(_("err dup2 err: %s"), strerror(errno));
	    /*NOTREACHED*/
	}
	if (comptype != COMP_SERVER_CUST) {
	    char *base = g_strdup(COMPRESS_PATH);
	    log_add(L_INFO, "%s pid %ld", basename(base), (long)getpid());
	    amfree(base);
	    safe_fd(-1, 0);
	    set_root_privs(-1);
	    execlp(COMPRESS_PATH, COMPRESS_PATH, (  comptype == COMP_BEST ?
		COMPRESS_BEST_OPT : COMPRESS_FAST_OPT), (char *)NULL);
	    g_fprintf(stderr,"error: couldn't exec server compression '%s': %s.\n", COMPRESS_PATH, strerror(errno));
	    exit(1);
	    /*NOTREACHED*/
	} else if (*srvcompprog) {
	    char *base = g_strdup(srvcompprog);
	    log_add(L_INFO, "%s pid %ld", basename(base), (long)getpid());
	    amfree(base);
	    safe_fd(-1, 0);
	    set_root_privs(-1);
	    execlp(srvcompprog, srvcompprog, (char *)0);
	    g_fprintf(stderr,"error: couldn't exec server custom compression '%s': %s.\n", srvcompprog, strerror(errno));
	    exit(1);
	    /*NOTREACHED*/
	}
    }
    /*NOTREACHED*/
    return (-1);
}

/*
 * Runs encrypt with the first arg as its stdout.  Returns
 * 0 on success or negative if error, and it's pid via the second
 * argument.  The outfd arg is dup2'd to the pipe to the encrypt
 * process.
 */
static int
runencrypt(
    int		outfd,
    pid_t *	pid,
    encrypt_t	encrypttype,
    char       *name)
{
    int outpipe[2], rval;
    int errpipe[2];
    filter_t *filter;

    assert(outfd >= 0);
    assert(pid != NULL);

    /* outpipe[0] is pipe's stdin, outpipe[1] is stdout. */
    if (pipe(outpipe) < 0) {
	g_free(errstr);
	errstr = g_strdup_printf(_("pipe: %s"), strerror(errno));
	return (-1);
    }

    /* errpipe[0] is pipe's output, outpipe[1] is input. */
    if (pipe(errpipe) < 0) {
	g_free(errstr);
	errstr = g_strdup_printf(_("pipe: %s"), strerror(errno));
	return (-1);
    }

    g_debug("execute: %s", srv_encrypt);
    switch (*pid = fork()) {
    case -1:
	g_free(errstr);
	errstr = g_strdup_printf(_("couldn't fork: %s"), strerror(errno));
	aclose(outpipe[0]);
	aclose(outpipe[1]);
	aclose(errpipe[0]);
	aclose(errpipe[1]);
	return (-1);
    default: {
	char *base;
	rval = dup2(outpipe[1], outfd);
	if (rval < 0) {
	    g_free(errstr);
	    errstr = g_strdup_printf(_("couldn't dup2: %s"), strerror(errno));
	}
	aclose(outpipe[1]);
	aclose(outpipe[0]);
	aclose(errpipe[1]);
	filter = g_new0(filter_t, 1);
	filter->fd = errpipe[0];
	base = g_strdup(srv_encrypt);
	filter->name = g_strdup(name);
	amfree(base);
	filter->buffer = NULL;
	filter->size = 0;
	filter->allocated_size = 0;
	filter->event = event_create((event_id_t)filter->fd, EV_READFD,
				     handle_filter_stderr, filter);
	event_activate(filter->event);
	return (rval);
	}
    case 0: {
	char *base;
	if (dup2(outpipe[0], 0) < 0) {
	    error(_("err dup2 in: %s"), strerror(errno));
	    /*NOTREACHED*/
	}
	if (dup2(outfd, 1) < 0 ) {
	    error(_("err dup2 out: %s"), strerror(errno));
	    /*NOTREACHED*/
	}
	if (dup2(errpipe[1], 2) == -1) {
	    error(_("err dup2 err: %s"), strerror(errno));
	    /*NOTREACHED*/
	}
	close(errpipe[0]);
	base = g_strdup(srv_encrypt);
	log_add(L_INFO, "%s pid %ld", basename(base), (long)getpid());
	amfree(base);
	safe_fd(-1, 0);
	if ((encrypttype == ENCRYPT_SERV_CUST) && *srv_encrypt) {
	    set_root_privs(-1);
	    execlp(srv_encrypt, srv_encrypt, (char *)0);
	    g_fprintf(stderr,"error: couldn't exec server encryption '%s': %s.\n", srv_encrypt, strerror(errno));
	    exit(1);
	    /*NOTREACHED*/
	}
	}
    }
    /*NOTREACHED*/
    return (-1);
}


/* -------------------- */

static void
sendbackup_response(
    void *		datap,
    pkt_t *		pkt,
    security_handle_t *	sech)
{
    int ports[NSTREAMS], *response_error = datap;
    guint i;
    char *p;
    char *tok;
    char *extra;

    assert(response_error != NULL);
    assert(sech != NULL);

    security_close_connection(sech, hostname);

    if (pkt == NULL) {
	g_free(errstr);
	errstr = g_strdup_printf(_("[request failed: %s]"),
                                 security_geterror(sech));
	*response_error = 1;
	return;
    }

    extra = NULL;
    memset(ports, 0, sizeof(ports));
    if (pkt->type == P_NAK) {
#if defined(PACKET_DEBUG)
	g_fprintf(stderr, _("got nak response:\n----\n%s\n----\n\n"), pkt->body);
#endif

	tok = strtok(pkt->body, " ");
	if (tok == NULL || !g_str_equal(tok, "ERROR"))
	    goto bad_nak;

	tok = strtok(NULL, "\n");
	if (tok != NULL) {
	    g_free(errstr);
	    errstr = g_strdup_printf("NAK: %s", tok);
	    *response_error = 1;
	} else {
bad_nak:
	    g_free(errstr);
	    errstr = g_strdup("request NAK");
	    *response_error = 2;
	}
	return;
    }

    if (pkt->type != P_REP) {
	g_free(errstr);
	errstr = g_strdup_printf(_("received strange packet type %s: %s"),
                                 pkt_type2str(pkt->type), pkt->body);
	*response_error = 1;
	return;
    }

    dbprintf(_("got response:\n----\n%s\n----\n\n"), pkt->body);

    for(i = 0; i < NSTREAMS; i++) {
	ports[i] = -1;
	streams[i].fd = NULL;
    }

    p = pkt->body;
    while((tok = strtok(p, " \n")) != NULL) {
	p = NULL;

	/*
	 * Error response packets have "ERROR" followed by the error message
	 * followed by a newline.
	 */
	if (g_str_equal(tok, "ERROR")) {
	    tok = strtok(NULL, "\n");
	    if (tok == NULL)
		tok = _("[bogus error packet]");
	    g_free(errstr);
	    errstr = g_strdup_printf("%s", tok);
	    *response_error = 2;
	    return;
	}

	/*
	 * Regular packets have CONNECT followed by three streams
	 */
	if (g_str_equal(tok, "CONNECT")) {
	    guint nstreams;

	    if (am_has_feature(their_features, fe_sendbackup_stream_state)) {
		nstreams = NSTREAMS;
	    } else {
		nstreams = NSTREAMS - 1;
	    }
	    /*
	     * Parse the three or four stream specifiers out of the packet.
	     */
	    for (i = 0; i < nstreams; i++) {
		tok = strtok(NULL, " ");
		if (tok == NULL || !g_str_equal(tok, streams[i].name)) {
		    extra = g_strdup_printf(
				_("CONNECT token is \"%s\": expected \"%s\""),
				tok ? tok : "(null)",
				streams[i].name);
		    goto parse_error;
		}
		tok = strtok(NULL, " \n");
		if (tok == NULL || sscanf(tok, "%d", &ports[i]) != 1) {
		    extra = g_strdup_printf(
			_("CONNECT %s token is \"%s\": expected a port number"),
			streams[i].name, tok ? tok : "(null)");
		    goto parse_error;
		}
	    }
	    continue;
	}

	/*
	 * RETRY
	 */
	if (g_str_equal(tok, "RETRY")) {

	    tok = strtok(NULL, " ");
	    SET(status, GOT_RETRY);
	    if (tok && g_str_equal(tok, "delay")) {
		tok = strtok(NULL, " ");
		if (tok) {
		    retry_delay = atoi(tok);
		}
		tok = strtok(NULL, " ");
	    }
	    if (tok && g_str_equal(tok, "level")) {
		tok = strtok(NULL, " ");
		if (tok) {
		    retry_level = atoi(tok);
		}
		tok = strtok(NULL, " ");
	    }
	    if (tok && g_str_equal(tok, "message")) {
		tok = strtok(NULL, "\n");
		if (tok) {
		     retry_message = g_strdup(tok);
		} else {
		    retry_message = g_strdup("\"No message\"");
		}
	    } else {
		retry_message = g_strdup("\"No message\"");
	    }
	    *response_error = 3;
	    continue;
	}

	/*
	 * OPTIONS [options string] '\n'
	 */
	if (g_str_equal(tok, "OPTIONS")) {
	    tok = strtok(NULL, "\n");
	    if (tok == NULL) {
		extra = g_strdup(_("OPTIONS token is missing"));
		goto parse_error;
	    }

	    while((p = strchr(tok, ';')) != NULL) {
		*p++ = '\0';
		if(strncmp_const_skip_no_var(tok, "features=", tok) == 0) {
		    char *u = strchr(tok, ';');
		    if (u)
		       *u = '\0';
		    am_release_feature_set(their_features);
		    if((their_features = am_string_to_feature(tok)) == NULL) {
                        g_free(errstr);
                        errstr = g_strdup_printf(_("OPTIONS: bad features value: %s"),
                                                 tok);
			goto parse_error;
		    }
		    if (u)
		       *u = ';';
		}
		tok = p;
	    }
	    continue;
	}

	extra = g_strdup_printf(_("next token is \"%s\": expected \"CONNECT\", \"ERROR\" or \"OPTIONS\""),
			  tok);
	goto parse_error;
    }

    if (ISSET(status, GOT_RETRY)) {
	return;
    }

    if (dumper_kencrypt == KENCRYPT_WILL_DO)
	dumper_kencrypt = KENCRYPT_YES;

    /*
     * Connect the streams to their remote ports
     */
    for (i = 0; i < NSTREAMS; i++) {
	if (ports[i] == -1)
	    continue;
	streams[i].fd = security_stream_client(sech, ports[i]);
	if (streams[i].fd == NULL) {
            g_free(errstr);
            errstr = g_strdup_printf(_("[could not connect %s stream: %s]"),
                                     streams[i].name, security_geterror(sech));
	    goto connect_error;
	}
    }

    /*
     * Authenticate the streams
     */
    for (i = 0; i < NSTREAMS; i++) {
	if (streams[i].fd == NULL)
	    continue;
	if (security_stream_auth(streams[i].fd) < 0) {
            g_free(errstr);
            errstr = g_strdup_printf(_("[could not authenticate %s stream: %s]"),
                                     streams[i].name, security_stream_geterror(streams[i].fd));
	    goto connect_error;
	}
    }

    /*
     * The MESGFD and DATAFD streams are mandatory.  If we didn't get
     * them, complain.
     */
    if (streams[MESGFD].fd == NULL || streams[DATAFD].fd == NULL) {
	g_free(errstr);
	errstr = g_strdup("[couldn't open MESG or INDEX streams]");
	goto connect_error;
    }

    /* everything worked */
    *response_error = 0;
    return;

parse_error:
    g_free(errstr);
    errstr = g_strdup_printf(_("[parse of reply message failed: %s]"),
                             extra ? extra : _("(no additional information)"));
    amfree(extra);
    *response_error = 2;
    return;

connect_error:
    stop_dump();
    *response_error = 1;
}

static char *
dumper_get_security_conf(
    char *string,
    void *arg G_GNUC_UNUSED)
{
	char *result = NULL;

        if(!string || !*string)
                return(NULL);

        if (g_str_equal(string, "krb5principal")) {
                result = getconf_str(CNF_KRB5PRINCIPAL);
        } else if (g_str_equal(string, "krb5keytab")) {
                result = getconf_str(CNF_KRB5KEYTAB);
        } else if (g_str_equal(string, "amandad_path")) {
                result = amandad_path;
        } else if (g_str_equal(string, "client_username")) {
                result = client_username;
        } else if (g_str_equal(string, "client_port")) {
                result = client_port;
        } else if (g_str_equal(string, "src_ip")) {
		if (!g_str_equal(src_ip, "NULL"))
		    result = src_ip;
        } else if(g_str_equal(string, "ssh_keys")) {
                result = ssh_keys;
        } else if(g_str_equal(string, "kencrypt")) {
		if (dumper_kencrypt == KENCRYPT_YES)
                    result = "yes";
        } else if(strcmp(string, "ssl_fingerprint_file")==0) {
                result = ssl_fingerprint_file;
        } else if(strcmp(string, "ssl_cert_file")==0) {
                result = ssl_cert_file;
        } else if(strcmp(string, "ssl_key_file")==0) {
                result = ssl_key_file;
        } else if(strcmp(string, "ssl_ca_cert_file")==0) {
                result = ssl_ca_cert_file;
        } else if(strcmp(string, "ssl_cipher_list")==0) {
                result = ssl_cipher_list;
        } else if(strcmp(string, "ssl_check_certificate_host")==0) {
                result = ssl_check_certificate_host;
        }

	if (result && strlen(result) == 0)
		result = NULL;

        return(result);
}

static int
startup_dump(
    const char *hostname,
    const char *disk,
    const char *device,
    int		level,
    const char *dumpdate,
    const char *progname,
    const char *amandad_path,
    const char *client_username,
    const char *ssl_fingerprint_file,
    const char *ssl_cert_file,
    const char *ssl_key_file,
    const char *ssl_ca_cert_file,
    const char *ssl_cipher_list,
    const char *ssl_check_certificate_host,
    const char *client_port,
    const char *ssh_keys,
    const char *auth,
    const char *options)
{
    char *req;
    int response_error = 1;
    const security_driver_t *secdrv;
    int has_features;
    int has_maxdumps;
    int has_hostname;
    int has_device;
    int has_config;
    int has_timestamp;
    int has_data_shm_control_name;
    GString *reqbuf;
    gboolean legacy_api;

    (void)disk;			/* Quiet unused parameter warning */
    (void)amandad_path;		/* Quiet unused parameter warning */
    (void)client_username;	/* Quiet unused parameter warning */
    (void)ssl_fingerprint_file;	/* Quiet unused parameter warning */
    (void)ssl_cert_file;	/* Quiet unused parameter warning */
    (void)ssl_key_file;		/* Quiet unused parameter warning */
    (void)ssl_ca_cert_file;	/* Quiet unused parameter warning */
    (void)ssl_cipher_list;	/* Quiet unused parameter warning */
    (void)ssl_check_certificate_host;	/* Quiet unused parameter warning */
    (void)client_port;		/* Quiet unused parameter warning */
    (void)ssh_keys;		/* Quiet unused parameter warning */
    (void)auth;			/* Quiet unused parameter warning */

    has_features  = am_has_feature(their_features, fe_req_options_features);
    has_maxdumps  = am_has_feature(their_features, fe_req_options_maxdumps);
    has_hostname  = am_has_feature(their_features, fe_req_options_hostname);
    has_config    = am_has_feature(their_features, fe_req_options_config);
    has_timestamp = am_has_feature(their_features, fe_req_options_timestamp);
    has_device    = am_has_feature(their_features, fe_sendbackup_req_device);
    has_data_shm_control_name = am_has_feature(their_features, fe_sendbackup_req_options_data_shm_control_name);
    crc32_init(&crc_data_in);
    crc32_init(&crc_data_out);
    crc32_init(&native_crc);
    crc32_init(&client_crc);
    native_crc.crc = 0;
    client_crc.crc = 0;

    legacy_api = (g_str_equal(progname, "DUMP") || g_str_equal(progname, "GNUTAR"));

    /*
     * Default to bsd authentication if none specified.  This is gross.
     *
     * Options really need to be pre-parsed into some sort of structure
     * much earlier, and then flattened out again before transmission.
     */


    reqbuf = g_string_new("SERVICE sendbackup\nOPTIONS ");

    if (has_features)
        g_string_append_printf(reqbuf, "features=%s;", our_feature_string);

    if (has_maxdumps)
        g_string_append_printf(reqbuf, "maxdumps=%s;", maxdumps);

    if (has_hostname)
        g_string_append_printf(reqbuf, "hostname=%s;", hostname);

    if (has_config)
        g_string_append_printf(reqbuf, "config=%s;", get_config_name());

    if (has_timestamp)
	g_string_append_printf(reqbuf, "timestamp=%s;", dumper_timestamp);

    if (has_data_shm_control_name &&
#ifdef FAILURE_CODE
	disable_network_shm < 1 &&
#endif
	g_str_equal(auth,"local") &&
	data_path == DATA_PATH_AMANDA) {
	if (!shm_name) {
	    shm_ring_consumer = shm_ring_create(NULL);
	    shm_name = g_strdup(shm_ring_consumer->shm_control_name);
	} else if (am_has_feature(their_features, fe_sendbackup_req_options_data_shm_control_name)) {
	    // shm_ring direct
	    shm_ring_direct = shm_ring_link(shm_name);
	    shm_ring_direct->mc->need_sem_ready++;
	}
        g_string_append_printf(reqbuf, "data-shm-control-name=%s;", shm_name);
    }

    g_string_append_c(reqbuf, '\n');

    amfree(dle_str);
    if (am_has_feature(their_features, fe_req_xml)) {
        GString *strbuf = g_string_new("<dle>\n");
	char *p, *pclean;

        g_string_append_printf(strbuf, "  <program>%s</program>\n  %s\n",
            (!legacy_api) ? "APPLICATION" : progname, b64disk);

        if (device && has_device)
            g_string_append_printf(strbuf, "  %s\n", b64device);

        g_string_append_printf(strbuf, "  <level>%d</level>\n%s</dle>\n",
            level, options + 1);

        p = g_string_free(strbuf, FALSE);
	pclean = clean_dle_str_for_client(p, their_features);
        g_string_append(reqbuf, pclean);
	g_free(pclean);
	dle_str = p;
    } else if (!legacy_api) {
	g_free(errstr);
	errstr = g_strdup("[does not support application-api]");
        g_string_free(reqbuf, TRUE);
	return 2;
    } else {
	if (auth == NULL)
	    auth = "BSDTCP";

        g_string_append_printf(reqbuf, "%s %s %s %d %s OPTIONS %s\n", progname,
            qdiskname, (device && has_device) ? device : "", level,
            dumpdate, options);

    }

    req = g_string_free(reqbuf, FALSE);

    dbprintf("send request:\n----\n%s\n----\n\n", req);

    secdrv = security_getdriver(auth);
    if (secdrv == NULL) {
	g_free(errstr);
	errstr = g_strdup_printf(_("[could not find security driver '%s']"),
                                 auth);
        g_free(req);
	return 2;
    }

    protocol_sendreq(hostname, secdrv, dumper_get_security_conf, req,
	STARTUP_TIMEOUT, sendbackup_response, &response_error);

    g_free(req);

    protocol_run();
    return response_error;
}
