# SYNOPSIS
#
#   AMANDA_WITH_ASSERTIONS
#
# OVERVIEW
#
#   Handles the --with-assertions flag.  Defines and substitutes ASSERTIONS
#   if the flag is given.
#
AC_DEFUN([AMANDA_WITH_ASSERTIONS],
[
    ASSERTIONS=
    AC_ARG_WITH(assertions,
        AS_HELP_STRING([--with-assertions],
            [compile assertions into code]),
        [
            case "$withval" in
                n | no) : ;;
                y |  ye | yes)
		    ASSERTIONS=1
                    AC_DEFINE(ASSERTIONS,1,
                        [Define if you want assertion checking. ])
                  ;;
                *) AC_MSG_ERROR([*** You must not supply an argument to --with-assertions option.])
                  ;;
            esac
        ]
    )
    AC_SUBST(ASSERTIONS)
])

# SYNOPSIS
#
#   AMANDA_WITH_DEBUGGING
#
# OVERVIEW
#
#   Handles the --with[out]-debugging flag.  If debugging is not disabled, then define
#   DEBUG_CODE, and define and substitute AMANDA_DBGDIR to either the location the
#   user gave, or AMANDA_TMPDIR.
#
AC_DEFUN([AMANDA_WITH_DEBUGGING],
[
    AC_REQUIRE([AMANDA_WITH_TMPDIR])
    AC_ARG_WITH(debugging,
        AS_HELP_STRING([--with-debugging=DIR]
            [put debug logs in DIR (default same as --with-tmpdir)]), 
        [ debugging="$withval" ],
	[ debugging="yes" ]
    )

    case "$debugging" in
        n | no) AC_MSG_ERROR([Amanda no longer supports building with debugging disabled]);;
        y | ye | yes) AMANDA_DBGDIR="$AMANDA_TMPDIR";;
        *) AMANDA_DBGDIR="$debugging";;
    esac

    # evaluate any extra variables in the directory
    AC_DEFINE_DIR([AMANDA_DBGDIR], [AMANDA_DBGDIR],
	[Location of Amanda directories and files. ])
])

# SYNOPSIS
#
#   AMANDA_GLIBC_BACKTRACE
#
# OVERVIEW
#
#   Check for glibc's backtrace support, and define HAVE_GLIBC_BACKTRACE if it is present.
AC_DEFUN([AMANDA_GLIBC_BACKTRACE],
[
    AC_CHECK_HEADER([execinfo.h], [
	AC_CHECK_FUNC([backtrace_symbols_fd], [
	    AC_DEFINE(HAVE_GLIBC_BACKTRACE, 1,
		[Define this if glibc's backtrace functionality (execinfo.h) is present])
	])
    ])
])

# SYNOPSIS
#
#   AMANDA_WITH_DEBUG_DAYS
#
# OVERVIEW
#
#   Handles the --with-debug-days flag.  Defines and substitutes AMANDA_DEBUG_DAYS.
#
AC_DEFUN([AMANDA_WITH_DEBUG_DAYS],
[
    AC_ARG_WITH(debug_days,
        AS_HELP_STRING([--with-debug-days=NN],
            [number of days to keep debugging files (default: 4)]),
        [
            debug_days="$withval"
        ], [
            debug_days="yes"
        ]
    )
    case "$debug_days" in
        n | no) 
            AMANDA_DEBUG_DAYS=0 ;;
        y |  ye | yes) 
            AMANDA_DEBUG_DAYS=4 ;;
        [[0-9]] | [[0-9]][[0-9]] | [[0-9]][[0-9]][[0-9]]) 
            AMANDA_DEBUG_DAYS="$debug_days" ;;
        *) AC_MSG_ERROR([*** --with-debug-days value not numeric or out of range.])
          ;;
    esac
    AC_DEFINE_UNQUOTED(AMANDA_DEBUG_DAYS,$AMANDA_DEBUG_DAYS,
        [Number of days to keep debugging files. ])
    AC_SUBST(AMANDA_DEBUG_DAYS)
])

# SYNOPSIS
#
#   AMANDA_ENABLE_SYNTAX_CHECKS
#
# OVERVIEW
#
#   Handles the --enable-syntax-checks flag, which triggers syntax checks
#   for most 'make' targets, but causes spurious errors in all but the most
#   carefully-constructed build environments.

AC_DEFUN([AMANDA_DISABLE_SYNTAX_CHECKS],
[
    AC_ARG_ENABLE(syntax-checks,
	AS_HELP_STRING([--enable-syntax-checks],
	    [Perform syntax checks when installing - developers only]),
	[
	    case "$enableval" in
		no) SYNTAX_CHECKS=false;;
		*)
		    SYNTAX_CHECKS=true
		    AMANDA_MSG_WARN([--enable-syntax-checks can cause build failures and should only be used by developers])
		    ;;
	    esac
	], [
	    SYNTAX_CHECKS=false
	])

    AM_CONDITIONAL(SYNTAX_CHECKS, $SYNTAX_CHECKS)
])
