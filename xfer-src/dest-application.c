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
#include "event.h"
#include "amutil.h"

/*
 * Class declaration
 *
 * This declaration is entirely private; nothing but xfer_dest_application()
 * references it directly.
 */

GType xfer_dest_application_get_type(void);
#define XFER_DEST_APPLICATION_TYPE (xfer_dest_application_get_type())
#define XFER_DEST_APPLICATION(obj) G_TYPE_CHECK_INSTANCE_CAST((obj), xfer_dest_application_get_type(), XferDestApplication)
#define XFER_DEST_APPLICATION_CONST(obj) G_TYPE_CHECK_INSTANCE_CAST((obj), xfer_dest_application_get_type(), XferDestApplication const)
#define XFER_DEST_APPLICATION_CLASS(klass) G_TYPE_CHECK_CLASS_CAST((klass), xfer_dest_application_get_type(), XferDestApplicationClass)
#define IS_XFER_DEST_APPLICATION(obj) G_TYPE_CHECK_INSTANCE_TYPE((obj), xfer_dest_application_get_type ())
#define XFER_DEST_APPLICATION_GET_CLASS(obj) G_TYPE_INSTANCE_GET_CLASS((obj), xfer_dest_application_get_type(), XferDestApplicationClass)

static GObjectClass *parent_class = NULL;

/*
 * Main object structure
 */

typedef struct XferDestApplication {
    XferElement __parent__;

    gchar **argv;
    gboolean need_root;
    int pipe_dar[2];
    int pipe_err[2];
    int pipe_out[2];

    pid_t child_pid;
    GSource *child_watch;
    gboolean child_killed;
} XferDestApplication;

/*
 * Class definition
 */

typedef struct {
    XferElementClass __parent__;
    int (*get_dar_fd)(XferDestApplication *elt);
    int (*get_err_fd)(XferDestApplication *elt);
    int (*get_out_fd)(XferDestApplication *elt);

} XferDestApplicationClass;

/*
 * Implementation
 */

static void
child_watch_callback(
    pid_t pid,
    gint status,
    gpointer data)
{
    XferDestApplication *self = XFER_DEST_APPLICATION(data);
    XferElement *elt = (XferElement *)self;
    XMsg *msg;
    char *errmsg = NULL;

    g_assert(pid == self->child_pid);
    self->child_pid = -1; /* it's gone now.. */

    if (WIFEXITED(status)) {
	int exitcode = WEXITSTATUS(status);
	g_debug("%s: process exited with status %d", xfer_element_repr(elt), exitcode);
	if (exitcode != 0) {
	    errmsg = g_strdup_printf("%s exited with status %d",
		self->argv[0], exitcode);
	}
    } else if (WIFSIGNALED(status)) {
	int signal = WTERMSIG(status);
	if (signal != SIGKILL || !self->child_killed) {
	    errmsg = g_strdup_printf("%s died on signal %d", self->argv[0], signal);
	    g_debug("%s: %s", xfer_element_repr(elt), errmsg);
	}
    }

    if (errmsg) {
	msg = xmsg_new(XFER_ELEMENT(self), XMSG_INFO, 0);
	msg->message = g_strdup(errmsg);
	xfer_queue_message(XFER_ELEMENT(self)->xfer, msg);
    } else {
	msg = xmsg_new(XFER_ELEMENT(self), XMSG_INFO, 0);
	msg->message = g_strdup("SUCCESS");
	xfer_queue_message(XFER_ELEMENT(self)->xfer, msg);
    }

    /* if this is an error exit, send an XMSG_ERROR and cancel */
    if (!elt->cancelled) {
	if (errmsg) {
	    msg = xmsg_new(XFER_ELEMENT(self), XMSG_ERROR, 0);
	    msg->message = errmsg;
	    xfer_queue_message(XFER_ELEMENT(self)->xfer, msg);

	    xfer_cancel(elt->xfer);

	} else if (elt->cancel_on_success) {
	    xfer_cancel(elt->xfer);
	}
    }
    /* this element is as good as cancelled already, so fall through to XMSG_DONE */
    xfer_queue_message(XFER_ELEMENT(self)->xfer, xmsg_new(XFER_ELEMENT(self), XMSG_DONE, 0));
}

static int
get_dar_fd_impl(
    XferDestApplication *xfp)
{
    return xfp->pipe_dar[0];
}

static int
get_err_fd_impl(
    XferDestApplication *xfp)
{
    return xfp->pipe_err[0];
}

static int
get_out_fd_impl(
    XferDestApplication *xfp)
{
    return xfp->pipe_out[0];
}

static gboolean
start_impl(
    XferElement *elt)
{
    char *tmpbuf;
    XferDestApplication *self = (XferDestApplication *)elt;
    char *cmd_str;
    char **argv;
    char *errmsg;
    char **env;
    int rfd;

    /* first build up a log message of what we're going to do, properly shell quoted */
    argv = self->argv;
    cmd_str = g_shell_quote(*(argv++));
    while (*argv) {
	char *qarg = g_shell_quote(*(argv++));
	tmpbuf = g_strconcat(cmd_str, " ", qarg, NULL);
	g_free(cmd_str);
	cmd_str = tmpbuf;
	g_free(qarg);
    }
    g_debug("%s spawning: %s", xfer_element_repr(elt), cmd_str);

    rfd = xfer_element_swap_output_fd(elt->upstream, -1);

    /* now fork off the child and connect the pipes */
    switch (self->child_pid = fork()) {
	case -1:
	    error("cannot fork: %s", strerror(errno));
	    /* NOTREACHED */

	case 0: /* child */
	    /* first, copy our fd's out of the needed range */
	    while (rfd >= 0 && rfd <= 3)
		rfd = dup(rfd);
	    while (self->pipe_out[1] >= 0 && self->pipe_out[1] <= 3)
		self->pipe_out[1] = dup(self->pipe_out[1]);
	    while (self->pipe_err[1] >= 0 && self->pipe_err[1] <= 3)
		self->pipe_err[1] = dup(self->pipe_err[1]);
	    while (self->pipe_dar[1] >= 0 && self->pipe_dar[1] <= 3)
		self->pipe_dar[1] = dup(self->pipe_dar[1]);

	    /* set up stdin, stdout, stderr and dar, overwriting anything already open
	     * on those fd's */
	    if (rfd > 0)
		dup2(rfd, STDIN_FILENO);
	    dup2(self->pipe_out[1], STDOUT_FILENO);
	    dup2(self->pipe_err[1], STDERR_FILENO);
	    dup2(self->pipe_dar[1], 3);

	    /* and close everything else */
	    safe_fd(3, 1);
	    env = safe_env();

	    if (self->need_root && !become_root()) {
		errmsg = g_strdup_printf("could not become root: %s\n", strerror(errno));
		full_write(STDERR_FILENO, errmsg, strlen(errmsg));
		exit(1);
	    }

	    execve(self->argv[0], self->argv, env);
	    errmsg = g_strdup_printf("exec of '%s' failed: %s\n", self->argv[0], strerror(errno));
	    full_write(STDERR_FILENO, errmsg, strlen(errmsg));
	    exit(1);

	default: /* parent */
	    break;
    }
    g_free(cmd_str);

    /* close the pipe fd's */
    close(rfd);
    close(self->pipe_dar[1]);
    close(self->pipe_err[1]);
    close(self->pipe_out[1]);

    /* watch for child death */
    self->child_watch = new_child_watch_source(self->child_pid);
    g_source_set_callback(self->child_watch,
	    (GSourceFunc)child_watch_callback, self, NULL);
    g_source_attach(self->child_watch, NULL);
    g_source_unref(self->child_watch);

    return TRUE;
}

static gboolean
cancel_impl(
    XferElement *elt,
    gboolean expect_eof)
{
    XferDestApplication *self = (XferDestApplication *)elt;

    /* chain up first */
    XFER_ELEMENT_CLASS(parent_class)->cancel(elt, expect_eof);

    /* if the process is running as root, we can't do anything but wait until
     * we get an upstream EOF, or downstream does something to trigger a
     * SIGPIPE */
    if (self->need_root)
	return expect_eof;

    /* avoid the risk of SIGPIPEs by not killing the process if it is already
     * expecting an EOF */
    if (expect_eof) {
	return expect_eof;
    }

    /* and kill the process, if it's not already dead; this will likely send
     * SIGPIPE to anything upstream. */
    if (self->child_pid != -1) {
	g_debug("%s: killing child process", xfer_element_repr(elt));
	if (kill(self->child_pid, SIGKILL) < 0) {
	    /* log but ignore */
	    g_debug("while killing child process: %s", strerror(errno));
	    return FALSE; /* downstream should not expect EOF */
	}

	/* make sure we don't send an XMSG_ERROR about this */
	self->child_killed = 1;
    }

    return TRUE; /* downstream should expect an EOF */
}

static void
instance_init(
    XferElement *elt)
{
    XferDestApplication *self = (XferDestApplication *)elt;

    /* we can generate an EOF *unless* the process is running as root */
    elt->can_generate_eof = !self->need_root;

    self->argv = NULL;
    self->child_pid = -1;
    self->child_killed = FALSE;
}

static void
finalize_impl(
    GObject * obj_self)
{
    XferDestApplication *self = XFER_DEST_APPLICATION(obj_self);

    if (self->argv)
	g_strfreev(self->argv);

    /* chain up */
    G_OBJECT_CLASS(parent_class)->finalize(obj_self);
}

static void
class_init(
    XferDestApplicationClass * selfc)
{
    XferElementClass *klass = XFER_ELEMENT_CLASS(selfc);
    GObjectClass *goc = (GObjectClass*) klass;
    static xfer_element_mech_pair_t mech_pairs[] = {
	{ XFER_MECH_READFD, XFER_MECH_NONE, XFER_NROPS(1), XFER_NTHREADS(0), XFER_NALLOC(0) },
	{ XFER_MECH_NONE, XFER_MECH_NONE, XFER_NROPS(0), XFER_NTHREADS(0), XFER_NALLOC(0) },
    };

    klass->start = start_impl;
    klass->cancel = cancel_impl;

    klass->perl_class = "Amanda::Xfer::Dest::Application";
    klass->mech_pairs = mech_pairs;
    selfc->get_dar_fd = get_dar_fd_impl;
    selfc->get_err_fd = get_err_fd_impl;
    selfc->get_out_fd = get_out_fd_impl;

    goc->finalize = finalize_impl;

    parent_class = g_type_class_peek_parent(selfc);
}

GType
xfer_dest_application_get_type (void)
{
    static GType type = 0;

    if (G_UNLIKELY(type == 0)) {
        static const GTypeInfo info = {
            sizeof (XferDestApplicationClass),
            (GBaseInitFunc) NULL,
            (GBaseFinalizeFunc) NULL,
            (GClassInitFunc) class_init,
            (GClassFinalizeFunc) NULL,
            NULL /* class_data */,
            sizeof (XferDestApplication),
            0 /* n_preallocs */,
            (GInstanceInitFunc) instance_init,
            NULL
        };

        type = g_type_register_static (XFER_ELEMENT_TYPE, "XferDestApplication", &info, 0);
    }

    return type;
}

/* create an element of this class; prototype is in xfer-element.h */
XferElement *
xfer_dest_application(
    gchar **argv,
    gboolean need_root,
    gboolean must_drain,
    gboolean cancel_on_success,
    gboolean ignore_broken_pipe)
{
    XferDestApplication *xfp = (XferDestApplication *)g_object_new(XFER_DEST_APPLICATION_TYPE, NULL);
    XferElement *elt = XFER_ELEMENT(xfp);

    if (!argv || !*argv)
	error("xfer_dest_application got a NULL or empty argv");

    xfp->argv = argv;
    xfp->need_root = need_root;
    if (pipe(xfp->pipe_dar) < 0) {
	g_critical(_("Can't create pipe: %s"), strerror(errno));
    }
    if (pipe(xfp->pipe_err) < 0) {
	g_critical(_("Can't create pipe: %s"), strerror(errno));
    }
    if (pipe(xfp->pipe_out) < 0) {
	g_critical(_("Can't create pipe: %s"), strerror(errno));
    }
    elt->must_drain = must_drain;
    elt->cancel_on_success = cancel_on_success;
    elt->ignore_broken_pipe = ignore_broken_pipe;
    return elt;
}

int dest_application_get_err_fd(
    XferElement *elt)
{
    XferDestApplicationClass *klass;
    g_assert(IS_XFER_DEST_APPLICATION(elt));

    klass = XFER_DEST_APPLICATION_GET_CLASS(elt);
    if (klass->get_err_fd)
	return klass->get_err_fd(XFER_DEST_APPLICATION(elt));
    else
        return 0;
}

int dest_application_get_out_fd(
    XferElement *elt)
{
    XferDestApplicationClass *klass;
    g_assert(IS_XFER_DEST_APPLICATION(elt));

    klass = XFER_DEST_APPLICATION_GET_CLASS(elt);
    if (klass->get_out_fd)
	return klass->get_out_fd(XFER_DEST_APPLICATION(elt));
    else
        return 0;
}

int dest_application_get_dar_fd(
    XferElement *elt)
{
    XferDestApplicationClass *klass;
    g_assert(IS_XFER_DEST_APPLICATION(elt));

    klass = XFER_DEST_APPLICATION_GET_CLASS(elt);
    if (klass->get_dar_fd)
	return klass->get_dar_fd(XFER_DEST_APPLICATION(elt));
    else
        return 0;
}
