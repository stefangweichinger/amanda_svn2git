# OVERVIEW
#

# SYNOPSIS
#
#   AMANDA_PROG_GNUTAR
#
# OVERVIEW
#
#   Search for a GNU 'tar' binary, placing the result in the precious 
#   variable GNUTAR.  The discovered binary is tested to ensure it's really
#   GNU tar.
#
#   Also handle --with-gnutar
#
AC_DEFUN([AMANDA_PROG_GNUTAR],
[
    AC_REQUIRE([AMANDA_INIT_PROGS])

    # call with
    AC_ARG_WITH(gnutar,
	AS_HELP_STRING([--with-gnutar=PROG],
		       [use PROG as GNU 'tar']),
	[
	    # check withval
	    case "$withval" in
		/*) GNUTAR="$withval";;
		y|ye|yes) :;;
		n|no) GNUTAR=no ;;
		*)  AC_MSG_ERROR([*** You must supply a full pathname to --with-gnutar]);;
	    esac
	    # done
	]
    )

    if test "x$GNUTAR" = "xno"; then
	GNUTAR=
    else
        if test "x$GNUTAR" != "x"; then
	    case `"$GNUTAR" --version 2>&1` in
	      *GNU*tar* | *Free*paxutils* )
			    # OK, it is GNU tar
			    break
			    ;;
	       *)
			    AMANDA_MSG_WARN([$GNUTAR is not GNU tar, it will be used.])
			    ;;
	    esac
        else
	    OLD_GNUTAR=$GNUTAR
	    for gnutar_name in gtar gnutar tar; do
	        AC_PATH_PROGS(GNUTAR, $gnutar_name, , $LOCSYSPATH)
	        if test -n "$GNUTAR"; then
	            case `"$GNUTAR" --version 2>&1` in
	              *GNU*tar* | *Free*paxutils* )
			    # OK, it is GNU tar
			    break
			    ;;
	              *)
			    # warning..
			    AMANDA_MSG_WARN([$GNUTAR is not GNU tar, so it will not be used.])
			    # reset the cache for GNUTAR so AC_PATH_PROGS will search again
			    GNUTAR=''
			    unset ac_cv_path_GNUTAR
			    ;;
	            esac
	        fi
	    done
        fi
    fi

    if test "x$GNUTAR" = "x"; then
	GNUTAR='/usr/bin/tar'
    fi
    if test "x$GNUTAR" != "x"; then
	# find the realpath
	if test "x$REALPATH" != "x"; then
	    GNUTAR=`$REALPATH $GNUTAR 2>&1`
	else if test "x$AM_READLINK" != "x"; then
	    GNUTAR=`$AM_READLINK -e $GNUTAR 2>&1`
	fi
	fi
	# define unquoted
	AC_DEFINE_UNQUOTED(GNUTAR, "$GNUTAR", [Location of the GNU 'tar' binary])
    fi
    AC_ARG_VAR(GNUTAR, [Location of the GNU 'tar' binary])
    AC_SUBST(GNUTAR)
])

# SYNOPSIS
#
#   AMANDA_PROG_STAR
#
# OVERVIEW
#
#   Search for a 'star' binary, placing the result in the precious 
#   variable STAR.  The discovered binary is tested to ensure it's really
#   star.
#
#   Also handle --with-star
#
AC_DEFUN([AMANDA_PROG_STAR],
[
    AC_REQUIRE([AMANDA_INIT_PROGS])

    # call with
    AC_ARG_WITH(star,
	AS_HELP_STRING([--with-star=PROG],
		       [use PROG as 'star']),
	[
	    # check withval
	    case "$withval" in
		/*) STAR="$withval";;
		y|ye|yes) :;;
		n|no) STAR=no ;;
		*)  AC_MSG_ERROR([*** You must supply a full pathname to --with-star]);;
	    esac
	    # done
	]
    )

    if test "x$STAR" = "xno"; then
	STAR=
    else
	OLD_STAR=$STAR
	AC_PATH_PROGS(STAR, star, , $LOCSYSPATH)
	if test -n "$STAR"; then
	    case `"$STAR" --version 2>/dev/null` in
	     *star*)
		    # OK, it is star
		    break
		    ;;
	     *)
		    if test -n "$OLD_STAR"; then
			AMANDA_MSG_WARN([$STAR is not star, it will be used.])
		    else
			# warning..
			AMANDA_MSG_WARN([$STAR is not star, so it will not be used.])
			# reset the cache for STAR so AC_PATH_PROGS will search again
			STAR=''
			unset ac_cv_path_STAR
		    fi
		    ;;
	    esac
	fi
    fi

    if test "x$STAR" = "x"; then
	STAR='/usr/bin/star'
    fi
    if test "x$STAR" != "x"; then
	# find the realpath
	if test "x$REALPATH" != "x"; then
	    STAR=`$REALPATH $STAR 2>&1`
	else if test "x$AM_READLINK" != "x"; then
	    GNUTAR=`$AM_READLINK -e $GNUTAR 2>&1`
	fi
	fi
	# define unquoted
	AC_DEFINE_UNQUOTED(STAR, "$STAR", [Location of the 'star' binary])
    fi
    AC_ARG_VAR(STAR, [Location of the 'star' binary])
    AC_SUBST(STAR)
])

# SYNOPSIS
#
#   AMANDA_PROG_BSDTAR
#
# OVERVIEW
#
#   Search for a 'bsdtar' or 'tar' binary, placing the result in the precious
#   variable BSDTAR.  The discovered binary is tested to ensure it's really
#   bsdtar.
#
#   Also handle --with-bsdtar
#
AC_DEFUN([AMANDA_PROG_BSDTAR],
[
    AC_REQUIRE([AMANDA_INIT_PROGS])

    # call with
    AC_ARG_WITH(bsdtar,
	AS_HELP_STRING([--with-bsdtar=PROG],
		       [use PROG as 'bsdtar']),
	[
	    # check withval
	    case "$withval" in
		/*) BSDTAR="$withval";;
		y|ye|yes) :;;
		n|no) BSDTAR=no ;;
		*)  AC_MSG_ERROR([*** You must supply a full pathname to --with-bsdtar]);;
	    esac
	    # done
	]
    )

    if test "x$BSDTAR" = "xno"; then
	BSDTAR=
    else
	OLD_BSDTAR=$BSDTAR
	if test "x$BSDTAR" = "x"; then
	    AC_PATH_PROGS(BSDTAR, bsdtar, , $LOCSYSPATH)
	fi
	if test -n "$BSDTAR"; then
	    case `"$BSDTAR" --version 2>/dev/null` in
	     *bsdtar*)
		    # OK, it is bsdtar
		    break
		    ;;
	     *)
		    if test "x$OLD_BSDTAR" != "x"; then
		        AMANDA_MSG_WARN([using $OLDBSDTAR for the ambsdtar application even if it is not bsdtar.])
			BSDTAR=$OLD_BSDTAR
		    else
			AMANDA_MSG_WARN([Not using $BSDTAR for the ambsdtar application as it is not bsdtar.])
			BSDTAR=
		    fi
		    ;;
	    esac
	fi
	if test "x$BSDTAR" = "x"; then
	    AC_PATH_PROGS(BSDTAR, tar, , $LOCSYSPATH)
	    if test -n "$BSDTAR"; then
		case `"$BSDTAR" --version 2>/dev/null` in
		 *bsdtar*)
			# OK, it is bsdtar
			break;
			;;
		 *)	BSDTAR=
			;;
		esac
	    fi
	fi
    fi

    if test "x$BSDTAR" = "x"; then
	BSDTAR='/usr/bin/bsdtar'
    fi
    if test "x$BSDTAR" != "x"; then
	# find the realpath
	if test "x$REALPATH" != "x"; then
	    BSDTAR=`$REALPATH $BSDTAR 2>&1`
	else if test "x$AM_READLINK" != "x"; then
	    GNUTAR=`$AM_READLINK -e $GNUTAR 2>&1`
	fi
	fi
	# define unquoted
	AC_DEFINE_UNQUOTED(BSDTAR, "$BSDTAR", [Location of the 'bsdtar' binary])
    fi
    AC_ARG_VAR(BSDTAR, [Location of the 'bsdtar' binary])
    AC_SUBST(BSDTAR)
])

# SYNOPSIS
#
#   AMANDA_PROG_SUNTAR
#
# OVERVIEW
#
#   Use the value given with the option --with-suntar= or the value of the 
#   precious variable SUNTAR to define the location of Sun's version of tar.
#   Otherwise set the value to /usr/sbin/tar.  Value is not checked.
#
#   Also handle --with-suntar
#
AC_DEFUN([AMANDA_PROG_SUNTAR],
[
    AC_REQUIRE([AMANDA_INIT_PROGS])

    # call with
    AC_ARG_WITH(suntar,
	AS_HELP_STRING([--with-suntar=PROG],
		       [use PROG as 'suntar']),
	[
	    # check withval
	    case "$withval" in
		/*) SUNTAR="$withval";;
		y|ye|yes) :;;
		n|no) SUNTAR=no ;;
		*)  AC_MSG_ERROR([*** You must supply a full pathname to --with-suntar]);;
	    esac
	    # done
	],
	[
	    if test "x$SUNTAR" = "x"; then
		SUNTAR="/usr/sbin/tar"
	    fi
	]
    )

    if test "x$SUNTAR" = "xno"; then
	SUNTAR=
    fi

    if test "x$SUNTAR" != "x"; then
	# find the realpath
	if test "x$REALPATH" != "x"; then
	    SUNTAR=`$REALPATH $SUNTAR 2>&1`
	else if test "x$AM_READLINK" != "x"; then
	    GNUTAR=`$AM_READLINK -e $GNUTAR 2>&1`
	fi
	fi
	# define unquoted
	AC_DEFINE_UNQUOTED(SUNTAR, "$SUNTAR", [Location of the 'suntar' binary])
    fi
    AC_ARG_VAR(SUNTAR, [Location of the 'suntar' binary])
    AC_SUBST(SUNTAR)
])

# SYNOPSIS
#
#   AMANDA_PROG_SAMBA_CLIENT
#
# OVERVIEW
#
#   Search for a samba client (smbclient) binary, placing the result in
#   the variable SAMBA_CLIENT.  The discovered binary is tested to determine an
#   internally significant version number, stored in SAMBA_VERSION.  The version
#   serves only to differentiate versions of Samba which Amanada must treat 
#   differently, and has no relation to the actual Samba version number.
#
#   Automake conditional 'WANT_SAMBA' is set if a samba client is discovered.
#
#   Also handles --with-smbclient and (deprecated) --with-samba-user
#
AC_DEFUN([AMANDA_PROG_SAMBA_CLIENT],
[
    AC_REQUIRE([AMANDA_INIT_PROGS])

    AC_ARG_WITH(smbclient,
	AS_HELP_STRING([--with-smbclient=PROG],
		       [use PROG as 'smbclient']),
	[
	    case "$withval" in
		/*) SAMBA_CLIENT="$withval";;
		y|ye|yes) :;;
		n|no) SAMBA_CLIENT=no ;;
		*)  AC_MSG_ERROR([*** You must supply a full pathname to --with-smbclient]);;
	    esac
	]
    )

    AC_ARG_WITH(samba-user,
	AS_HELP_STRING([--with-samba-user],
		       [deprecated; place username in 'amandapass']),
       [ AC_MSG_ERROR([--with-samba-user is no longer supported; place username in 'amandapass']) ]
    )

    if test "x$SAMBA_CLIENT" != "xno"; then
      AC_PATH_PROG(SAMBA_CLIENT,smbclient,,$LOCSYSPATH)
      smbversion=0
      if test ! -z "$SAMBA_CLIENT"; then
        case `"$SAMBA_CLIENT" '\\\\nosuchhost.amanda.org\\notashare' -U nosuchuser -N -Tx /dev/null 2>&1` in
        *"Unknown host"*)
		      smbversion=1
		      ;;
        *"Connection to nosuchhost.amanda.org failed"*)
		      smbversion=2
		      ;;
        *)
		      AMANDA_MSG_WARN([$SAMBA_CLIENT does not seem to be smbclient.])
		      smbversion=2
		      ;;
        esac
      else
	  SAMBA_CLIENT='/usr/bin/smbclient'
	  smbversion=2
      fi
      if test -n "$SAMBA_CLIENT"; then
	AC_DEFINE_UNQUOTED(SAMBA_CLIENT,"$SAMBA_CLIENT",
		[Define the location of smbclient for backing up Samba PC clients. ])
	AC_DEFINE_UNQUOTED(SAMBA_VERSION, $smbversion,
		[Not the actual samba version, just a number that should be increased whenever we start to rely on a new samba feature. ])
      fi
    fi

    AM_CONDITIONAL(WANT_SAMBA, test -n "$SAMBA_CLIENT")
])

# SYNOPSIS
#
#   AMANDA_PROG_VDUMP_VRESTORE
#
# DESCRIPTION
#
#   Search for 'vdump' and 'vrestore', setting and AC_DEFINE-ing VDUMP and 
#   VRESTORE if they are found.
#
AC_DEFUN([AMANDA_PROG_VDUMP_VRESTORE],
[
    AC_REQUIRE([AMANDA_INIT_PROGS])

    AC_PATH_PROG(VDUMP,vdump,,$SYSLOCPATH)
    AC_PATH_PROG(VRESTORE,vrestore,,$SYSLOCPATH)
    if test "$VDUMP" -a "$VRESTORE"; then
	AC_DEFINE_UNQUOTED(VDUMP,"$VDUMP",[Define the location of the vdump program. ])
	AC_DEFINE_UNQUOTED(VRESTORE,"$VRESTORE",[Define the location of the vrestore program. ])
    fi
])

# SYNOPSIS
#
#   AMANDA_PROG_VXDUMP_VXRESTORE
#
# DESCRIPTION
#
#   Search for 'vxdump' and 'vxrestore', setting and AC_DEFINE-ing VXDUMP
#   and VXRESTORE if they are found.
#
#   In addition to the standard paths, this macro will search in
#   /usr/lib/fs/vxfs.
#
AC_DEFUN([AMANDA_PROG_VXDUMP_VXRESTORE],
[
    AC_REQUIRE([AMANDA_INIT_PROGS])

    AC_PATH_PROG(VXDUMP,vxdump,,$SYSLOCPATH:/usr/lib/fs/vxfs)
    AC_PATH_PROG(VXRESTORE,vxrestore,,$SYSLOCPATH:/usr/lib/fs/vxfs)
    if test "$VXDUMP" -a "$VXRESTORE"; then
	AC_DEFINE_UNQUOTED(VXDUMP,"$VXDUMP",
[Define the location of the vxdump program on HPUX and SINIX hosts or on
 * other hosts where the Veritas filesystem (vxfs) has been installed. ])
	AC_DEFINE_UNQUOTED(VXRESTORE,"$VXRESTORE",
[Define the location of the vxrestore program on HPUX and SINIX hosts or on
 * other hosts where the Veritas filesystem (vxfs) has been installed. ])
    fi
])

# SYNOPSIS
#
#   AMANDA_PROG_XFSDUMP_XFSRESTORE
#
# DESCRIPTION
#
#   Search for 'xfsdump' and 'xfsrestore', setting and AC_DEFINE-ing XFSDUMP
#   and XFSRESTORE if they are found.
#
AC_DEFUN([AMANDA_PROG_XFSDUMP_XFSRESTORE],
[
    AC_REQUIRE([AMANDA_INIT_PROGS])

    AC_PATH_PROGS(XFSDUMP,xfsdump,,$SYSLOCPATH)
    AC_PATH_PROGS(XFSRESTORE,xfsrestore,,$SYSLOCPATH)
    if test "$XFSDUMP" -a "$XFSRESTORE"; then
	AC_DEFINE_UNQUOTED(XFSDUMP,"$XFSDUMP",
		[Define the location of the xfsdump program on Irix hosts. ])
	AC_DEFINE_UNQUOTED(XFSRESTORE,"$XFSRESTORE",
		[Define the location of the xfsrestore program on Irix hosts. ])
	AMANDA_MSG_WARN([[xfsdump causes the setuid-root rundump program to be enabled.  To disable it, just #undef XFSDUMP in config/config.h]])
    fi
])

# SYNOPSIS
#
#   AMANDA_PROG_DUMP_RESTORE
#
# DESCRIPTION
#
#   Search for compatible dump and restore binaries.  The exact name of
#   the binaries we search for depends on the target system.  If working
#   binaries are found, DUMP and RESTORE are defined to their full paths.
#
#   DUMP_RETURNS_1 is defined and substituted if the system's 'dump'
#   returns 1 on success.
#
#   HAVE_DUMP_ESTIMATE is defined to the dump flag which enables estimates.
#
#   The --with-honor-nodump flag is processed, and the result of the test is
#   positive, then HAVE_HONOR_NODUMP is defined.
#
AC_DEFUN([AMANDA_PROG_DUMP_RESTORE],
[
    AC_REQUIRE([AMANDA_INIT_PROGS])
    AC_REQUIRE([AMANDA_PROG_GREP])

    # Set the order of dump programs to look for.  Finding the proper file
    # system dumping program is problematic.  Some systems, notably HP-UX
    # and AIX, have both the backup and dump programs.  HP-UX can't use the
    # the backup program while AIX systems can't use the dump program.  So
    # a variable is set up here to specify the order of dump programs to
    # search for on the system.
    DUMP_PROGRAMS="ufsdump dump backup"
    DUMP_RETURNS_1=
    AIX_BACKUP=
    case "$host" in
	*-dg-*)
	    DUMP_PROGRAMS="dump "$DUMP_PROGRAMS
	    DUMP_RETURNS_1=1
	    ;;
      *-ibm-aix*)
	    DUMP_PROGRAMS="backup "$DUMP_PROGRAMS
	    AIX_BACKUP=1
	    AC_DEFINE(AIX_BACKUP,1,
		[Is DUMP the AIX program 'backup'?])
	    ;;
      *-ultrix*)
	    DUMP_RETURNS_1=1
	    ;;
    esac

    if test -n "$DUMP_RETURNS_1"; then
      AC_DEFINE(DUMP_RETURNS_1,1,
	[Define this if this system's dump exits with 1 as a success code. ])
    fi

    AC_PATH_PROGS(DUMP,$DUMP_PROGRAMS,,$SYSLOCPATH)
    AC_PATH_PROGS(RESTORE,ufsrestore restore,,$SYSLOCPATH)
    
    # newer versions of GNU tar include a program named 'backup' which
    # does *not* implement the expected 'dump' interface.  Detect that here
    # and pretend we never saw it.
    if test -n "$DUMP"; then
      if test "`basename $DUMP`" = "backup"; then
        backup_gnutar=`$DUMP --version | $GREP "GNU tar"`
        if test $? -eq 0; then
          DUMP=
        fi
      fi
    fi
    
    if test "$DUMP" -a "$RESTORE"; then
	AC_DEFINE_UNQUOTED(DUMP,"$DUMP",
	    [Define the location of the ufsdump, backup, or dump program. ])
	AC_DEFINE_UNQUOTED(RESTORE,"$RESTORE",
	    [Define the location of the ufsrestore or restore program. ])

	# check for an estimate flag
	if test -x $DUMP; then
	    AC_CACHE_CHECK(
		[whether $DUMP supports -E or -S for estimates],
		amanda_cv_dump_estimate,
		[
		    case "$DUMP" in
		    *dump)
			AC_TRY_COMMAND($DUMP 9Ef /dev/null /dev/null/invalid/fs 2>&1
			    | $GREP -v Dumping
			    | $GREP -v Date
			    | $GREP -v Label >conftest.d-E 2>&1)
			cat conftest.d-E >&AS_MESSAGE_LOG_FD()
			AC_TRY_COMMAND($DUMP 9Sf /dev/null /dev/null/invalid/fs 2>&1
			    | $GREP -v Dumping
			    | $GREP -v Date
			    | $GREP -v Label >conftest.d-S 2>&1)
			cat conftest.d-S >&AS_MESSAGE_LOG_FD()
			AC_TRY_COMMAND($DUMP 9f /dev/null /dev/null/invalid/fs 2>&1
			    | $GREP -v Dumping
			    | $GREP -v Date
			    | $GREP -v Label >conftest.d 2>&1)
			cat conftest.d >&AS_MESSAGE_LOG_FD()
			if AC_TRY_COMMAND(cmp conftest.d-E conftest.d 1>&2); then
			    amanda_cv_dump_estimate=E
			elif AC_TRY_COMMAND(cmp conftest.d-S conftest.d 1>&2); then
			    amanda_cv_dump_estimate=S
			else
			    amanda_cv_dump_estimate=no
			fi
			rm -f conftest.d conftest.d-E conftest.d-S
		      ;;
		    *) amanda_cv_dump_estimate=no
		      ;;
		    esac
		])
	else
	    AMANDA_MSG_WARN([$DUMP is not executable, cannot run -E/-S test])
	    amanda_cv_dump_estimate=no
	fi
	if test "x$amanda_cv_dump_estimate" != xno; then
	    AC_DEFINE_UNQUOTED(HAVE_DUMP_ESTIMATE, "$amanda_cv_dump_estimate",
		[Define to the string that enables dump estimates. ])
	fi

	AC_ARG_WITH(dump-honor-nodump,
	    AS_HELP_STRING([--with-dump-honor-nodump],
		[if dump supports -h, use it for level0s too]),
	[
	    if test -x $DUMP; then
		AC_CACHE_CHECK(
		  [whether $DUMP supports -h (honor nodump flag)],
		  amanda_cv_honor_nodump,
		  [
		    case "$DUMP" in
		    *dump)
			AC_TRY_COMMAND($DUMP 9hf 0 /dev/null /dev/null/invalid/fs 2>&1
			    | $GREP -v Dumping
			    | $GREP -v Date
			    | $GREP -v Label >conftest.d-h 2>&1)
			cat conftest.d-h >&AS_MESSAGE_LOG_FD()
			AC_TRY_COMMAND($DUMP 9f /dev/null /dev/null/invalid/fs 2>&1
			    | $GREP -v Dumping
			    | $GREP -v Date
			    | $GREP -v Label >conftest.d 2>&1)
			cat conftest.d >&AS_MESSAGE_LOG_FD()
			if AC_TRY_COMMAND(diff conftest.d-h conftest.d 1>&2); then
			    amanda_cv_honor_nodump=yes
			else
			    amanda_cv_honor_nodump=no
			fi
			rm -f conftest.d conftest.d-h
		      ;;
		    *) amanda_cv_honor_nodump=no
		      ;;
		    esac
		  ])
	    else
		AMANDA_MSG_WARN([$DUMP is not executable, cannot run -h test])
		amanda_cv_honor_nodump=no
	    fi
	    if test "x$amanda_cv_honor_nodump" = xyes; then
		AC_DEFINE(HAVE_HONOR_NODUMP,1,
		    [Define this if dump accepts -h for honoring nodump. ])
	    fi
	])
    fi

    AC_SUBST(AIX_BACKUP)
    AC_SUBST(DUMP_RETURNS_1)
])

# SYNOPSIS
#
#   AMANDA_CHECK_USE_RUNDUMP
#
# DESCRIPTION
#
#   Decide if the 'rundump' setuid-root wrapper should be used to invoke
#   dump.  If so, USE_RUNDUMP is defined and substituted.
#
AC_DEFUN([AMANDA_CHECK_USE_RUNDUMP], [
    USE_RUNDUMP=no

    # some systems require rundump unconditionally
    case "$host" in
        *-ultrix*) USE_RUNDUMP=yes ;;
        *-dg-*) USE_RUNDUMP=yes ;;
    esac

    AC_ARG_WITH(rundump,
        AS_HELP_STRING([--with-rundump], [use rundump, a setuid-root wrapper, to invoke dump]), [
        case "$withval" in
            n | no) USE_RUNDUMP=no ;;
            y | ye | yes) USE_RUNDUMP=yes ;;
            *) AC_MSG_ERROR([You must not supply an argument to --with-rundump option.]);;
        esac
        ])

    if test x"$USE_RUNDUMP" = x"yes"; then
	USE_RUNDUMP=1
        AC_DEFINE(USE_RUNDUMP,1,
            [Define to invoke rundump (setuid-root) instead of DUMP program directly. ])
    else
	USE_RUNDUMP=
    fi

    AC_SUBST(USE_RUNDUMP)
])
