/* Remote login over RDP, pattern B of ADR 0010: the technician types the
 * username and password into the RDP client before connecting, and on success
 * lands in an unlocked desktop -- the way `mstsc` works against Windows.
 *
 * It accepts RDP connections with FreeRDP, takes the credential the client
 * sends, and asks PAM. On success the monitor (below) finds that user's remote
 * session -- or starts one: a headless sg-compositor at the client's screen
 * size, a seat of its own with its own lock screen -- connects to the
 * session's privileged socket, and passes the connection over. The RDP side
 * then streams it (sg-rdp-stream.c): frames by screencopy, input by virtual
 * keyboard and pointer. A client that disconnects leaves the session running,
 * and the next login for that user reconnects to it, as on Windows.
 *
 * A user already signed in at the console has that session taken over, as on
 * Windows: the monitor asks the console's compositor (REMOTE, on its control
 * socket) to move the user's windows to an output of their own, handing it
 * one end of a socketpair as the remote connection; the console goes dark and
 * ignores everything but Ctrl+Alt+Del, which takes the session back locked.
 * When the client disconnects, that connection closes and the session goes
 * back to the console, locked.
 *
 * Or the console session is *shadowed* (pattern A, Windows' "shadow"): asked
 * for with the alternate shell "shadow [user] [/control]" (xfreerdp /shell:,
 * an .rdp file's "alternate shell:s:"), the connection views -- with
 * /control, views and drives -- the session live at the console, whose user
 * stays there and keeps working. Your own session needs only your password;
 * another user's needs an administrator's, and the person at the console to
 * say yes on the secure surface (sg-brokerd's prompt). The compositor
 * (SHADOW) frames the screen while it lasts and withholds input from a view-
 * only viewer; disconnecting -- or Ctrl+Alt+Del at the console -- ends it and
 * changes nothing else.
 *
 * Privilege separation, as in sshd. The code that parses RDP from the network
 * is the most exposed code in the system, so it must not run as root -- but
 * checking an arbitrary user's password needs root. So at startup, while still
 * root, this forks a *monitor* that keeps root and does one thing: run
 * sg-rdp-pamcheck for a (user, password) it is handed over a socketpair, and
 * for a password PAM accepts, hand back a connection to that user's session.
 * The parent then drops to an unprivileged account before opening the
 * listener. A compromise of the RDP parser gets an unprivileged process whose
 * only privileged capability is "ask whether this password is right" --
 * slowly -- and, when it is, the session of the user it belongs to.
 *
 * Security layer: TLS, with the credential taken from the Client Info packet.
 * Not NLA, deliberately and for now: server-side NLA must verify the client's
 * NTLM exchange, which needs every user's NT hash (MD4) stored somewhere --
 * exactly what Windows' SAM keeps and what pass-the-hash attacks target. For
 * local accounts we store no such hash; PAM checks the password against the
 * normal store. Domain accounts get NLA via Kerberos in Phase 2, which needs
 * only the machine keytab. See ADR 0010.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <poll.h>
#include <pwd.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <winpr/ssl.h>
#include <winpr/string.h>
#include <winpr/synch.h>
#include <winpr/thread.h>
#include <freerdp/freerdp.h>
#include <freerdp/listener.h>
#include <freerdp/peer.h>
#include <freerdp/settings.h>
#include <freerdp/crypto/certificate.h>
#include <freerdp/crypto/privatekey.h>
#include <freerdp/input.h>
#include <freerdp/pointer.h>
#include <linux/input-event-codes.h>

#include "sg-rdp-stream.h"

#define MAXFIELD 512

static int g_monitor_fd = -1;          /* unprivileged side of the socketpair */

/* Per-connection state. `authenticated` starts FALSE and is set in exactly one
 * place: a PAM "OK". Every later stage of the connection checks it.
 *
 * This is not belt-and-braces. Returning FALSE from FreeRDP 3's Logon hook does
 * NOT abort the connection -- the first test of this daemon showed a refused
 * logon sail on into PostConnect. And Logon is not called at all if the client
 * sends no credential. So the verdict has to be enforced downstream, and the
 * default has to be "no". */
typedef struct
{
    rdpContext base;
    BOOL authenticated;
    BOOL activated;
    struct sg_stream *stream;
    HANDLE stream_event;
} sg_peer_context;

/* What the monitor answers after a PAM "OK". */
enum session_status
{
    SESSION_ATTACHED = 0,   /* a connection to the session comes with it */
    SESSION_AT_CONSOLE,     /* signed in at the console, and it could not be taken over */
    SESSION_NOT_ALLOWED,    /* no account, or not a Stained Glass user */
    SESSION_FAILED,         /* it could not be started */
    SESSION_NO_CONSOLE,     /* shadow: nobody of that name at the console */
    SESSION_DECLINED,       /* shadow: the person at the console said no (or nothing) */
};
/* The TLS certificate and key, read once at startup while still root -- the
 * sshd host-key model. After the privilege drop the listener holds them in
 * memory and cannot read the key file from disk, so the key file can be root
 * only. The key buffer is locked so it is never written to swap. */
static char *g_cert_pem, *g_key_pem;
static FILE *g_log;

static void logmsg( const char *fmt, ... )
{
    va_list ap;
    va_start( ap, fmt );
    vfprintf( g_log, fmt, ap );
    fputc( '\n', g_log );
    fflush( g_log );
    va_end( ap );
}

/* ---- the monitor: root, one job ---------------------------------------- */

static int read_full( int fd, void *buf, size_t len )
{
    char *p = buf;
    while (len)
    {
        ssize_t n = read( fd, p, len );
        if (n <= 0) { if (n < 0 && errno == EINTR) continue; return -1; }
        p += n; len -= (size_t)n;
    }
    return 0;
}

static int write_full( int fd, const void *buf, size_t len )
{
    const char *p = buf;
    while (len)
    {
        ssize_t n = write( fd, p, len );
        if (n <= 0) { if (n < 0 && errno == EINTR) continue; return -1; }
        p += n; len -= (size_t)n;
    }
    return 0;
}

/* Run the PAM helper for one credential. The request arrives as two
 * length-prefixed fields; the helper gets them NUL-separated on stdin. */
static int monitor_check( const char *helper, const char *user, const char *pass, const char *rhost, int keyring )
{
    int in[2], out[2], status = 0;
    char reply[256] = "";
    ssize_t n;
    pid_t pid;

    if (pipe( in ) < 0 || pipe( out ) < 0) return 0;
    if ((pid = fork()) < 0) return 0;
    if (!pid)
    {
        dup2( in[0], STDIN_FILENO );
        dup2( out[1], STDOUT_FILENO );
        close( in[0] ); close( in[1] ); close( out[0] ); close( out[1] );
        /* the client's address as PAM's remote host: a number, which libpam's
         * audit record does not look up in DNS (the default "rdp" cost 8 s) */
        setenv( "SG_PAMCHECK_RHOST", rhost, 1 );
        /* the second check, once the session exists: pam_gnome_keyring in
         * the remote stack opens the session's keyring with the password */
        if (keyring) setenv( "SG_PAMCHECK_KEYRING", "1", 1 );
        else unsetenv( "SG_PAMCHECK_KEYRING" );
        execl( helper, helper, (char *)NULL );
        _exit( 127 );
    }
    close( in[0] ); close( out[1] );
    write_full( in[1], user, strlen( user ) + 1 );
    write_full( in[1], pass, strlen( pass ) + 1 );
    close( in[1] );
    n = read( out[0], reply, sizeof(reply) - 1 );
    close( out[0] );
    waitpid( pid, &status, 0 );
    if (n > 0) reply[n] = 0;
    return WIFEXITED( status ) && WEXITSTATUS( status ) == 0 && !strncmp( reply, "OK", 2 );
}

/* ---- the monitor's sessions ------------------------------------------- */

static const char *g_seat_root = "/run/stained-glass-seat";
static const char *g_broker_sock = "/run/stained-glass-broker/broker.sock";
static const char *g_admin_group = "sg-admins";

static int connect_unix( const char *path )
{
    struct sockaddr_un addr = { .sun_family = AF_UNIX };
    int fd;

    if (strlen( path ) >= sizeof(addr.sun_path)) return -1;
    strcpy( addr.sun_path, path );
    if ((fd = socket( AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0 )) < 0) return -1;
    if (connect( fd, (struct sockaddr *)&addr, sizeof(addr) ) < 0) { close( fd ); return -1; }
    return fd;
}

/* A compositor's socket, and it is served by `uid` (SO_PEERCRED): a directory
 * name proves nothing on its own. */
static int connect_session( const char *path, uid_t uid )
{
    struct ucred cred;
    socklen_t len = sizeof(cred);
    int fd = connect_unix( path );

    if (fd < 0) return -1;
    if (getsockopt( fd, SOL_SOCKET, SO_PEERCRED, &cred, &len ) < 0 || cred.uid != uid)
    {
        logmsg( "SESSION ignoring %s: not served by uid %d", path, (int)uid );
        close( fd );
        return -1;
    }
    return fd;
}

static int user_in_group( const struct passwd *pw, const char *group )
{
    struct group *gr = getgrnam( group );
    gid_t groups[256];
    int n = 256, i;

    if (!gr) return 0;
    if (pw->pw_gid == gr->gr_gid) return 1;
    if (getgrouplist( pw->pw_name, pw->pw_gid, groups, &n ) < 0) return 0;
    for (i = 0; i < n; i++) if (groups[i] == gr->gr_gid) return 1;
    return 0;
}

/* Run a command and wait for it; argv[0] is a full path. */
static int run_wait( char *const argv[] )
{
    int status = 0;
    pid_t pid = fork();

    if (pid < 0) return -1;
    if (!pid)
    {
        int null = open( "/dev/null", O_RDWR );
        if (null >= 0) { dup2( null, 0 ); dup2( null, 1 ); }
        execv( argv[0], argv );
        _exit( 127 );
    }
    while (waitpid( pid, &status, 0 ) < 0 && errno == EINTR) ;
    return WIFEXITED( status ) ? WEXITSTATUS( status ) : -1;
}

/* The seat directory of a remote session: made by the monitor (root), the session's own
 * directory inside it owned by the user -- never someone else's directory
 * reused. */
static int make_remote_seat( const struct passwd *pw, char *seat, size_t seatlen, char *dir, size_t dirlen )
{
    struct stat st;

    if ((size_t)snprintf( seat, seatlen, "%s/rdp-%u", g_seat_root, (unsigned)pw->pw_uid ) >= seatlen ||
        (size_t)snprintf( dir, dirlen, "%s/%u", seat, (unsigned)pw->pw_uid ) >= dirlen)
        return -1;
    if (mkdir( seat, 0755 ) < 0 && errno != EEXIST) return -1;
    if (lstat( seat, &st ) < 0 || !S_ISDIR( st.st_mode ) || st.st_uid != geteuid()) return -1;
    if (mkdir( dir, 0755 ) < 0 && errno != EEXIST) return -1;
    if (lstat( dir, &st ) < 0 || !S_ISDIR( st.st_mode )) return -1;
    if (st.st_uid != pw->pw_uid && lchown( dir, pw->pw_uid, pw->pw_gid ) < 0) return -1;
    return 0;
}

/* Take over the session a user is signed in to at the console: ask its
 * compositor (REMOTE, on the control socket, which it serves as that user)
 * to move the session to a new output, handing it one end of a socketpair as
 * the remote connection -- whose closing gives the session back to the
 * console, locked. Returns the other end, for the stream. */
static int take_over_console( const char *control, uid_t uid )
{
    char req[] = "REMOTE\n", reply[128] = "", cbuf[CMSG_SPACE(sizeof(int))];
    struct iovec iov = { .iov_base = req, .iov_len = sizeof(req) - 1 };
    struct msghdr mh = { .msg_iov = &iov, .msg_iovlen = 1, .msg_control = cbuf, .msg_controllen = sizeof(cbuf) };
    struct cmsghdr *cm;
    int sv[2], fd;
    ssize_t n;

    if ((fd = connect_session( control, uid )) < 0) return -1;
    if (socketpair( AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv ) < 0) { close( fd ); return -1; }
    memset( cbuf, 0, sizeof(cbuf) );
    cm = CMSG_FIRSTHDR( &mh );
    cm->cmsg_level = SOL_SOCKET;
    cm->cmsg_type = SCM_RIGHTS;
    cm->cmsg_len = CMSG_LEN( sizeof(int) );
    memcpy( CMSG_DATA( cm ), &sv[0], sizeof(int) );
    if (sendmsg( fd, &mh, MSG_NOSIGNAL ) < 0 || (n = read( fd, reply, sizeof(reply) - 1 )) <= 0 ||
        strncmp( reply, "OK remote ", 10 ))
    {
        reply[strcspn( reply, "\n" )] = 0;
        logmsg( "SESSION console take-over refused by the compositor: %s", reply[0] ? reply : "no answer" );
        close( fd ); close( sv[0] ); close( sv[1] );
        return -1;
    }
    reply[strcspn( reply, "\n" )] = 0;
    logmsg( "SESSION console session taken over: %s", reply + 3 );
    close( fd );
    close( sv[0] );   /* the compositor has its own copy */
    return sv[1];
}

/* ---- console shadow (pattern A) ---------------------------------------- */

/* Ask the broker to put the question to the person at the console, on the
 * secure surface: "<requester> wants to view (and control) your session".
 * The broker's socket is in its own root-made runtime directory; it answers
 * one byte, 0 for yes. Anything else, or no answer, is no. */
static int ask_console_consent( const char *requester, uid_t target, int control )
{
    char blob[600], uidenv[64];
    uint32_t len;
    unsigned char verdict = 1;
    int fd, n;
    struct pollfd p;

    snprintf( uidenv, sizeof(uidenv), "SHADOW_UID=%u", (unsigned)target );
    n = snprintf( blob, sizeof(blob), "@shadow%cSHADOW_REQUESTER=%s%cSHADOW_MODE=%s%c%s%c%cRemote Desktop%c", 0,
                  requester, 0, control ? "control" : "view", 0, uidenv, 0, 0, 0 );
    if (n <= 0 || n >= (int)sizeof(blob)) return 0;
    len = (uint32_t)n;
    if ((fd = connect_unix( g_broker_sock )) < 0)
    {
        logmsg( "SESSION shadow: no broker to ask the console (%s)", g_broker_sock );
        return 0;
    }
    if (write_full( fd, &len, sizeof(len) ) || write_full( fd, blob, len )) { close( fd ); return 0; }
    /* the broker's own timeout is shorter; this only guards against a hang */
    p.fd = fd; p.events = POLLIN; p.revents = 0;
    if (poll( &p, 1, 150 * 1000 ) != 1 || read( fd, &verdict, 1 ) != 1) verdict = 1;
    close( fd );
#ifdef SG_MUTANT_SHADOW_NO_CONSENT
    verdict = 0;
#endif
    return verdict == 0;
}

/* Ask the console compositor (SHADOW, on its control socket, which it
 * serves as that user) to take one end of a socketpair as a viewer. Returns
 * the other end, for the stream. */
static int start_shadow( const char *control, uid_t uid, int control_input )
{
    char req[32], reply[128] = "", cbuf[CMSG_SPACE(sizeof(int))];
    struct iovec iov = { .iov_base = req };
    struct msghdr mh = { .msg_iov = &iov, .msg_iovlen = 1, .msg_control = cbuf, .msg_controllen = sizeof(cbuf) };
    struct cmsghdr *cm;
    int sv[2], fd;
    ssize_t n;

    iov.iov_len = (size_t)snprintf( req, sizeof(req), "SHADOW %s\n", control_input ? "control" : "view" );
    if ((fd = connect_session( control, uid )) < 0) return -1;
    if (socketpair( AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv ) < 0) { close( fd ); return -1; }
    memset( cbuf, 0, sizeof(cbuf) );
    cm = CMSG_FIRSTHDR( &mh );
    cm->cmsg_level = SOL_SOCKET;
    cm->cmsg_type = SCM_RIGHTS;
    cm->cmsg_len = CMSG_LEN( sizeof(int) );
    memcpy( CMSG_DATA( cm ), &sv[0], sizeof(int) );
    if (sendmsg( fd, &mh, MSG_NOSIGNAL ) < 0 || (n = read( fd, reply, sizeof(reply) - 1 )) <= 0 ||
        strncmp( reply, "OK shadow ", 10 ))
    {
        reply[strcspn( reply, "\n" )] = 0;
        logmsg( "SESSION shadow refused by the compositor: %s", reply[0] ? reply : "no answer" );
        close( fd ); close( sv[0] ); close( sv[1] );
        return -1;
    }
    reply[strcspn( reply, "\n" )] = 0;
    logmsg( "SESSION console session shadowed: %s", reply + 3 );
    close( fd );
    close( sv[0] );
    return sv[1];
}

/* In the gate (SG_RDP_SESSION_CMD) every session is the daemon's own
 * account's; SG_RDP_TEST_CONSOLE_USER names the account the console session
 * stands for, SG_RDP_TEST_ADMINS the requesters who count as administrators.
 * Never set in a unit file. */
static int test_listed( const char *var, const char *user )
{
    const char *list = getenv( var ), *p;
    size_t n = strlen( user );
    if (!list) return 0;
    for (p = list; *p; )
    {
        size_t k = strcspn( p, ", " );
        if (k == n && !strncmp( p, user, n )) return 1;
        p += k;
        while (*p == ',' || *p == ' ') p++;
    }
    return 0;
}

/* "shadow [user] [/control]": view (or control) the console session of
 * `user`, the requester's own by default. */
static int shadow_for( const char *user, const char *spec, int *status )
{
    int test = getenv( "SG_RDP_SESSION_CMD" ) != NULL, control = 0, same, admin, fd;
    char target[MAXFIELD] = "", buf[MAXFIELD], console[700], *tok, *save = NULL;
    struct passwd *tpw, *rpw;
    uid_t tuid;

    *status = SESSION_NOT_ALLOWED;
    snprintf( buf, sizeof(buf), "%s", spec );
    for (tok = strtok_r( buf, " \t", &save ); tok; tok = strtok_r( NULL, " \t", &save ))
    {
        if (!strcasecmp( tok, "shadow" )) continue;
        if (!strcasecmp( tok, "/control" )) control = 1;
        else if (tok[0] != '/' && !target[0]) snprintf( target, sizeof(target), "%s", tok );
    }
    if (!target[0]) snprintf( target, sizeof(target), "%s", user );
    same = !strcmp( target, user );

    if (test)
    {
        const char *cu = getenv( "SG_RDP_TEST_CONSOLE_USER" );
        if (!cu || strcmp( target, cu ) || !(tpw = getpwuid( getuid() )))
        {
            *status = SESSION_NO_CONSOLE;
            return -1;
        }
        tuid = tpw->pw_uid;
        admin = test_listed( "SG_RDP_TEST_ADMINS", user );
    }
    else
    {
        if (!(rpw = getpwnam( user )) || rpw->pw_uid == 0 || !user_in_group( rpw, "sgwine" )) return -1;
        admin = user_in_group( rpw, g_admin_group );
        if (!(tpw = getpwnam( target )))
        {
            *status = SESSION_NO_CONSOLE;
            return -1;
        }
        tuid = tpw->pw_uid;
    }
    /* Someone else's session: administrators only, as on Windows. */
    if (!same && !admin)
    {
        logmsg( "SESSION shadow refused: %s is not an administrator (asked for %s)", user, target );
        return -1;
    }
    snprintf( console, sizeof(console), "%s/seat0/%u/control.sock", g_seat_root, (unsigned)tuid );
    if ((fd = connect_session( console, tuid )) < 0)
    {
        logmsg( "SESSION shadow: %s is not signed in at the console", target );
        *status = SESSION_NO_CONSOLE;
        return -1;
    }
    close( fd );
    /* and the person at the console agrees -- on the secure surface, where
     * nothing in their session can answer for them */
    if (!same && !ask_console_consent( user, tuid, control ))
    {
        logmsg( "SESSION shadow of %s declined at the console (asked by %s)", target, user );
        *status = SESSION_DECLINED;
        return -1;
    }
    if ((fd = start_shadow( console, tuid, control )) < 0)
    {
        *status = SESSION_FAILED;
        return -1;
    }
    logmsg( "SESSION shadow user=%s of=%s mode=%s", user, target, control ? "control" : "view" );
    *status = SESSION_ATTACHED;
    return fd;
}

/* Find or start the user's remote session; returns a connection to its
 * privileged socket, or -1 with *status saying why not. */
static int session_for( const char *user, unsigned width, unsigned height, int *status )
{
    const char *test_cmd = getenv( "SG_RDP_SESSION_CMD" );
    struct passwd *pw;
    char seat[512], dir[600], priv[700], console[700], unit[64], lockunit[64], size[32];
    char seatenv[600], sizeenv[64], lockenv[256], pam[64];
    int fd, i;

    *status = SESSION_FAILED;
    width &= ~3u; height &= ~3u;
    if (width < 640 || width > 8192) width = 1280;
    if (height < 480 || height > 8192) height = 800;
    snprintf( size, sizeof(size), "%ux%u", width, height );

    if (test_cmd)
    {
        /* The gate: sessions are the daemon's own account's, started by a
         * command of the gate's choosing. Never set in a unit file. */
        pw = getpwuid( getuid() );
    }
    else
    {
        pw = getpwnam( user );
        if (!pw || pw->pw_uid == 0 || !user_in_group( pw, "sgwine" ))
        {
            *status = SESSION_NOT_ALLOWED;
            return -1;
        }
    }
    if (!pw) return -1;

    snprintf( console, sizeof(console), "%s/seat0/%u/control.sock", g_seat_root, (unsigned)pw->pw_uid );
    if ((!test_cmd || getenv( "SG_RDP_CONSOLE_TEST" )) && (fd = connect_session( console, pw->pw_uid )) >= 0)
    {
        close( fd );
        if ((fd = take_over_console( console, pw->pw_uid )) >= 0)
        {
            *status = SESSION_ATTACHED;
            return fd;
        }
        *status = SESSION_AT_CONSOLE;
        return -1;
    }
    if (make_remote_seat( pw, seat, sizeof(seat), dir, sizeof(dir) ) < 0)
    {
        logmsg( "SESSION cannot prepare a seat for uid %u", (unsigned)pw->pw_uid );
        return -1;
    }
    snprintf( priv, sizeof(priv), "%s/priv.sock", dir );
    if ((fd = connect_session( priv, pw->pw_uid )) >= 0)
    {
        logmsg( "SESSION reconnect user=%s", user );
        *status = SESSION_ATTACHED;
        return fd;
    }

    /* None running: start one. Its own seat, so its own lock screen. */
    unlink( priv );
    snprintf( seatenv, sizeof(seatenv), "SG_SEAT_DIR=%s", seat );
    snprintf( sizeenv, sizeof(sizeenv), "SG_OUTPUT_SIZE=%s", size );
    if (test_cmd)
    {
        char *argv[] = { "/bin/sh", "-c", (char *)test_cmd, NULL };
        pid_t pid = fork();
        if (pid < 0) return -1;
        if (!pid)
        {
            setsid();
            putenv( seatenv );
            putenv( sizeenv );
            execv( argv[0], argv );
            _exit( 127 );
        }
    }
    else
    {
        char uidarg[64];
        snprintf( unit, sizeof(unit), "--unit=sg-rdp-session-%u", (unsigned)pw->pw_uid );
        snprintf( lockunit, sizeof(lockunit), "--unit=sg-rdp-lockd-%u", (unsigned)pw->pw_uid );
        snprintf( uidarg, sizeof(uidarg), "--uid=%u", (unsigned)pw->pw_uid );
        snprintf( lockenv, sizeof(lockenv), "--setenv=SG_LOCKD_LOG=/var/log/stained-glass/lockd-rdp-%u.log",
                  (unsigned)pw->pw_uid );
        snprintf( pam, sizeof(pam), "--property=PAMName=stained-glass-remote" );
        {
            char seatarg[640], sizearg[80];
            char *session[] = { "/usr/bin/systemd-run", "--quiet", "--collect", unit, uidarg, pam,
                                "--property=Type=exec", "--setenv=SG_REMOTE=1", seatarg, sizearg,
                                "/usr/bin/sg-session-start", NULL };
            char lockseat[640], bind[96];
            char *lockd[] = { "/usr/bin/systemd-run", "--quiet", "--collect", lockunit, bind,
                              "--property=Restart=always", "--property=RestartSec=1", lockseat, lockenv,
                              "/usr/libexec/stained-glass/sg-lockd", NULL };
            snprintf( seatarg, sizeof(seatarg), "--setenv=%s", seatenv );
            snprintf( sizearg, sizeof(sizearg), "--setenv=%s", sizeenv );
            snprintf( lockseat, sizeof(lockseat), "--setenv=%s", seatenv );
            snprintf( bind, sizeof(bind), "--property=BindsTo=sg-rdp-session-%u.service", (unsigned)pw->pw_uid );
            if (run_wait( session ) != 0)
            {
                logmsg( "SESSION systemd-run failed for user=%s", user );
                return -1;
            }
            if (run_wait( lockd ) != 0) logmsg( "SESSION no lock service for user=%s", user );
        }
    }
    logmsg( "SESSION starting user=%s size=%s", user, size );
    /* The compositor makes the socket as soon as it is up; Wine's desktop
     * follows, and the client sees it arrive. */
    for (i = 0; i < 600; i++)
    {
        struct timespec ts = { 0, 100 * 1000 * 1000 };
        if ((fd = connect_session( priv, pw->pw_uid )) >= 0)
        {
            *status = SESSION_ATTACHED;
            return fd;
        }
        nanosleep( &ts, NULL );
    }
    logmsg( "SESSION did not start for user=%s", user );
    return -1;
}

static int send_verdict( int sock, unsigned char ok, unsigned char status, int fd )
{
    unsigned char msg[2] = { ok, status };
    struct iovec iov = { msg, sizeof(msg) };
    char control[CMSG_SPACE(sizeof(int))];
    struct msghdr mh = { .msg_iov = &iov, .msg_iovlen = 1 };

    if (fd >= 0)
    {
        struct cmsghdr *cm;
        memset( control, 0, sizeof(control) );
        mh.msg_control = control;
        mh.msg_controllen = sizeof(control);
        cm = CMSG_FIRSTHDR( &mh );
        cm->cmsg_level = SOL_SOCKET;
        cm->cmsg_type = SCM_RIGHTS;
        cm->cmsg_len = CMSG_LEN(sizeof(int));
        memcpy( CMSG_DATA(cm), &fd, sizeof(int) );
    }
    return sendmsg( sock, &mh, MSG_NOSIGNAL ) == (ssize_t)sizeof(msg) ? 0 : -1;
}

static void monitor_loop( int fd, const char *helper )
{
    for (;;)
    {
        unsigned ulen, plen, hlen, slen, size[2];
        char user[MAXFIELD], pass[MAXFIELD], rhost[INET6_ADDRSTRLEN] = "", spec[MAXFIELD] = "";
        unsigned char addr[sizeof(struct in6_addr)];
        unsigned char ok;
        int status = SESSION_FAILED, session = -1;

        /* Reap sessions the gate's command started (systemd owns real ones). */
        while (waitpid( -1, NULL, WNOHANG ) > 0) ;
        if (read_full( fd, &ulen, sizeof(ulen) ) < 0) _exit( 0 );
        if (read_full( fd, &plen, sizeof(plen) ) < 0) _exit( 0 );
        if (ulen >= MAXFIELD || plen >= MAXFIELD) _exit( 1 );
        if (read_full( fd, user, ulen ) < 0 || read_full( fd, pass, plen ) < 0) _exit( 0 );
        if (read_full( fd, size, sizeof(size) ) < 0) _exit( 0 );
        if (read_full( fd, &hlen, sizeof(hlen) ) < 0) _exit( 0 );
        if (hlen >= sizeof(rhost)) _exit( 1 );
        if (read_full( fd, rhost, hlen ) < 0) _exit( 0 );
        if (read_full( fd, &slen, sizeof(slen) ) < 0) _exit( 0 );
        if (slen >= sizeof(spec)) _exit( 1 );
        if (read_full( fd, spec, slen ) < 0) _exit( 0 );
        user[ulen] = 0; pass[plen] = 0; rhost[hlen] = 0; spec[slen] = 0;
        /* only an address, never a name to look up */
        if (inet_pton( AF_INET, rhost, addr ) != 1 && inet_pton( AF_INET6, rhost, addr ) != 1) rhost[0] = 0;

        ok = (unsigned char)monitor_check( helper, user, pass, rhost, 0 );
        /* A failed guess costs the guesser time here, in the one process the
         * network cannot reach, so it cannot be skipped by reconnecting. */
        if (!ok) sleep( 2 );
        /* Only for a password PAM accepted, and only that user's session. */
        else if (spec[0]) session = shadow_for( user, spec, &status );
        else session = session_for( user, size[0], size[1], &status );
        /* The session's keyring opens with the password, as a sign-in at the
         * console opens it (greetd's pam_gnome_keyring). The password check
         * and the session are separate processes here -- the session is
         * systemd-run's, with no password -- so the password goes to the
         * session's keyring daemon now that it exists: the same PAM check
         * again, told where the person's runtime directory is, and
         * pam_gnome_keyring in the remote stack hands it over through the
         * daemon's control socket, as the lock screen's does. */
#ifndef SG_MUTANT_RDP_KEYRING
        if (session >= 0 && !spec[0] && !monitor_check( helper, user, pass, rhost, 1 ))
            logmsg( "SESSION keyring not opened for user=%s", user );
#endif
        explicit_bzero( pass, sizeof(pass) );
        if (send_verdict( fd, ok, (unsigned char)status, session ) < 0) _exit( 0 );
        if (session >= 0) close( session );
    }
}

/* Unprivileged side: ask the monitor. Serialised, because one socketpair is
 * shared by every peer thread. */
static CRITICAL_SECTION g_monitor_lock;

static int recv_verdict( int sock, unsigned char msg[2], int *fd )
{
    struct iovec iov = { msg, 2 };
    char control[CMSG_SPACE(sizeof(int))];
    struct msghdr mh = { .msg_iov = &iov, .msg_iovlen = 1, .msg_control = control,
                         .msg_controllen = sizeof(control) };
    struct cmsghdr *cm;
    ssize_t n;

    *fd = -1;
    while ((n = recvmsg( sock, &mh, MSG_CMSG_CLOEXEC )) < 0 && errno == EINTR) ;
    if (n != 2) return -1;
    for (cm = CMSG_FIRSTHDR( &mh ); cm; cm = CMSG_NXTHDR( &mh, cm ))
        if (cm->cmsg_level == SOL_SOCKET && cm->cmsg_type == SCM_RIGHTS)
            memcpy( fd, CMSG_DATA(cm), sizeof(int) );
    return 0;
}

/* Returns 1 if the password is right; then *session is a connection to the
 * user's session, or -1 with *status saying why there is none. */
static int ask_monitor( const char *user, const char *pass, const char *rhost, unsigned width, unsigned height,
                        const char *spec, int *session, int *status )
{
    unsigned ulen = (unsigned)strlen( user ), plen = (unsigned)strlen( pass ), size[2] = { width, height };
    unsigned hlen = rhost ? (unsigned)strlen( rhost ) : 0, slen = (unsigned)strlen( spec );
    unsigned char msg[2] = { 0, SESSION_FAILED };
    int res = -1;

    *session = -1;
    *status = SESSION_FAILED;
    if (ulen >= MAXFIELD || plen >= MAXFIELD || slen >= MAXFIELD) return 0;
    if (hlen >= INET6_ADDRSTRLEN) hlen = 0;
    EnterCriticalSection( &g_monitor_lock );
    if (!write_full( g_monitor_fd, &ulen, sizeof(ulen) ) &&
        !write_full( g_monitor_fd, &plen, sizeof(plen) ) &&
        !write_full( g_monitor_fd, user, ulen ) &&
        !write_full( g_monitor_fd, pass, plen ) &&
        !write_full( g_monitor_fd, size, sizeof(size) ) &&
        !write_full( g_monitor_fd, &hlen, sizeof(hlen) ) &&
        !write_full( g_monitor_fd, hlen ? rhost : "", hlen ) &&
        !write_full( g_monitor_fd, &slen, sizeof(slen) ) &&
        !write_full( g_monitor_fd, spec, slen ) &&
        !recv_verdict( g_monitor_fd, msg, session ))
        res = msg[0];
    LeaveCriticalSection( &g_monitor_lock );
    *status = msg[1];
    if (res != 1 && *session >= 0) { close( *session ); *session = -1; }
    return res == 1;
}

/* ---- the RDP side: unprivileged ---------------------------------------- */

/* FreeRDP calls Logon during protocol negotiation. Under TLS that is *before*
 * the client has sent any credential -- the identity is empty and `automatic`
 * is FALSE -- and whatever this returns, the connection continues (libfreerdp
 * core/peer.c, CONNECTION_STATE_NEGO). It is therefore useless as the
 * authentication point for TLS and is only logged. Authentication happens in
 * PostConnect, once the Client Info packet has delivered the credential. */
static BOOL on_logon( freerdp_peer *peer, const SEC_WINNT_AUTH_IDENTITY *id, BOOL automatic )
{
    (void)id;
    if (getenv( "SG_RDP_DEBUG" ))
        logmsg( "DEBUG nego-stage Logon automatic=%d from=%s", (int)automatic, peer->hostname );
    return TRUE;
}

/* Check the credential from the Client Info packet. Runs after it has arrived
 * and before activation, so nothing of a session exists yet. */
static BOOL authenticate( freerdp_peer *peer )
{
    rdpSettings *settings = peer->context->settings;
    const char *user = freerdp_settings_get_string( settings, FreeRDP_Username );
    const char *domain = freerdp_settings_get_string( settings, FreeRDP_Domain );
    char *pass = (char *)freerdp_settings_get_string( settings, FreeRDP_Password );
    BOOL ok = FALSE;

    if (!freerdp_settings_get_bool( settings, FreeRDP_AutoLogonEnabled ) || !user || !user[0] || !pass)
    {
        /* Pattern B needs the credential up front. A client that sends none is
         * refused here; showing it the on-screen login instead, as Windows RDP
         * does, is the compositor's half of ADR 0010. */
        logmsg( "LOGON REFUSED no credential supplied from=%s", peer->hostname );
    }
    else if (domain && domain[0] && strcmp( domain, "." ))
    {
        /* CORP\alice must never be mistaken for the local alice. Domain logins
         * arrive with Phase 2 (Kerberos NLA); until then, refuse them. */
        logmsg( "LOGON REFUSED domain account %s\\%s not supported yet from=%s",
                domain, user, peer->hostname );
    }
    else
    {
        sg_peer_context *ctx = (sg_peer_context *)peer->context;
        const char *shell = freerdp_settings_get_string( settings, FreeRDP_AlternateShell );
        int session = -1, status = SESSION_FAILED;
        char err[256], spec[MAXFIELD] = "";

        /* "shadow ...": the console session, viewed where it is (pattern
         * A). Anything else in the alternate shell is not ours to run. */
        if (shell && !strncasecmp( shell, "shadow", 6 ) && (!shell[6] || shell[6] == ' ') &&
            strlen( shell ) < sizeof(spec))
        {
            const char *c;
            for (c = shell; *c && (unsigned char)*c >= 0x20 && *c != 0x7f; c++) ;
            if (!*c) snprintf( spec, sizeof(spec), "%s", shell );
        }
        ok = ask_monitor( user, pass, peer->hostname, freerdp_settings_get_uint32( settings, FreeRDP_DesktopWidth ),
                          freerdp_settings_get_uint32( settings, FreeRDP_DesktopHeight ), spec, &session, &status );
        logmsg( "LOGON %s user=%s from=%s", ok ? "OK" : "FAIL", user, peer->hostname );
        if (ok)
        {
            if (session < 0)
            {
                logmsg( "SESSION refused user=%s: %s", user,
                        status == SESSION_AT_CONSOLE ? "signed in at the console" :
                        status == SESSION_NOT_ALLOWED ? (spec[0] ? "not allowed to view that session"
                                                                 : "not a Stained Glass user") :
                        status == SESSION_NO_CONSOLE ? "nobody of that name at the console" :
                        status == SESSION_DECLINED ? "the person at the console did not accept" :
                        "it could not be started" );
                ok = FALSE;
            }
            else if (!(ctx->stream = sg_stream_new( session, err, sizeof(err) )))
            {
                logmsg( "SESSION refused user=%s: %s", user, err );
                ok = FALSE;
            }
            else logmsg( "SESSION attached user=%s from=%s%s", user, peer->hostname,
                         sg_stream_view_only( ctx->stream ) ? " (view only)" : "" );
        }
    }

    /* The password has done its job; do not leave it in the settings for the
     * rest of the connection's life. */
    if (pass)
    {
        explicit_bzero( pass, strlen( pass ) );
        freerdp_settings_set_string( settings, FreeRDP_Password, NULL );
    }
    ((sg_peer_context *)peer->context)->authenticated = ok;
    return ok;
}

static BOOL require_auth( freerdp_peer *peer, const char *stage )
{
    if (((sg_peer_context *)peer->context)->authenticated) return TRUE;
    logmsg( "DENIED at %s: not authenticated, from=%s", stage, peer->hostname );
    return FALSE;
}

static BOOL on_activate( freerdp_peer *peer )
{
    sg_peer_context *ctx = (sg_peer_context *)peer->context;
    POINTER_SYSTEM_UPDATE hide = { .type = SYSPTR_NULL };

    if (!require_auth( peer, "Activate" ) || !ctx->stream) return FALSE;
    /* The pointer is drawn into the frames, so the client's own is hidden. */
    peer->context->update->pointer->PointerSystem( peer->context, &hide );
    ctx->activated = TRUE;
    sg_stream_start( ctx->stream, peer->context );
    logmsg( "CODEC %s from=%s", sg_stream_codec( ctx->stream ), peer->hostname );
    return TRUE;
}

static BOOL on_post_connect( freerdp_peer *peer )
{
    sg_peer_context *ctx = (sg_peer_context *)peer->context;
    rdpSettings *settings = peer->context->settings;
    uint32_t w, h;

    if (!authenticate( peer )) return FALSE;
    if (!require_auth( peer, "PostConnect" ) || !ctx->stream) return FALSE;
    /* The session's size is the desktop's: the server's Demand Active, sent
     * after this, is what the client sizes its window by. */
    sg_stream_size( ctx->stream, &w, &h );
    freerdp_settings_set_uint32( settings, FreeRDP_DesktopWidth, w );
    freerdp_settings_set_uint32( settings, FreeRDP_DesktopHeight, h );
    freerdp_settings_set_uint32( settings, FreeRDP_ColorDepth, 32 );
    ctx->stream_event = CreateFileDescriptorEvent( NULL, FALSE, FALSE, sg_stream_fd( ctx->stream ), WINPR_FD_READ );
    return ctx->stream_event != NULL;
}

/* ---- input from the client --------------------------------------------- */

static struct sg_stream *input_stream( rdpInput *input )
{
    sg_peer_context *ctx = (sg_peer_context *)input->context;
    return ctx->authenticated && ctx->activated ? ctx->stream : NULL;
}

static BOOL on_key( rdpInput *input, UINT16 flags, UINT8 code )
{
    struct sg_stream *s = input_stream( input );
    DWORD scancode = code, vk, evdev;

    if (!s) return TRUE;
    if (flags & KBD_FLAGS_EXTENDED) scancode |= KBDEXT;
    vk = GetVirtualKeyCodeFromVirtualScanCode( scancode, WINPR_KBD_TYPE_IBM_ENHANCED );
    if (flags & KBD_FLAGS_EXTENDED) vk |= KBDEXT;
    evdev = GetKeycodeFromVirtualKeyCode( vk, WINPR_KEYCODE_TYPE_EVDEV );
    sg_stream_key( s, evdev, !(flags & KBD_FLAGS_RELEASE) );
    return TRUE;
}

static BOOL on_unicode( rdpInput *input, UINT16 flags, UINT16 code )
{
    struct sg_stream *s = input_stream( input );
    if (s && !(flags & KBD_FLAGS_RELEASE)) sg_stream_unicode( s, code );
    return TRUE;
}

static BOOL on_sync( rdpInput *input, UINT32 flags )
{
    (void)input; (void)flags;
    return TRUE;
}

static BOOL on_mouse( rdpInput *input, UINT16 flags, UINT16 x, UINT16 y )
{
    struct sg_stream *s = input_stream( input );
    int down = (flags & PTR_FLAGS_DOWN) != 0;

    if (!s) return TRUE;
    if (flags & (PTR_FLAGS_WHEEL | PTR_FLAGS_HWHEEL))
    {
        int rot = flags & WheelRotationMask;
        if (flags & PTR_FLAGS_WHEEL_NEGATIVE) rot -= 0x200;
        /* RDP: positive is away from the user, 120 a notch. Wayland: negative
         * is up. At least one step for any movement. */
        rot = rot / 120 ? rot / 120 : (rot > 0 ? 1 : -1);
        sg_stream_wheel( s, (flags & PTR_FLAGS_HWHEEL) != 0, (flags & PTR_FLAGS_HWHEEL) ? rot : -rot );
        return TRUE;
    }
    sg_stream_motion( s, x, y );
    if (flags & PTR_FLAGS_BUTTON1) sg_stream_button( s, BTN_LEFT, down );
    if (flags & PTR_FLAGS_BUTTON2) sg_stream_button( s, BTN_RIGHT, down );
    if (flags & PTR_FLAGS_BUTTON3) sg_stream_button( s, BTN_MIDDLE, down );
    return TRUE;
}

static BOOL on_xmouse( rdpInput *input, UINT16 flags, UINT16 x, UINT16 y )
{
    struct sg_stream *s = input_stream( input );
    int down = (flags & PTR_XFLAGS_DOWN) != 0;

    if (!s) return TRUE;
    sg_stream_motion( s, x, y );
    if (flags & PTR_XFLAGS_BUTTON1) sg_stream_button( s, BTN_SIDE, down );
    if (flags & PTR_XFLAGS_BUTTON2) sg_stream_button( s, BTN_EXTRA, down );
    return TRUE;
}

static DWORD WINAPI peer_thread( LPVOID arg )
{
    freerdp_peer *peer = arg;
    rdpSettings *settings;
    rdpCertificate *cert = NULL;
    rdpPrivateKey *key = NULL;

    peer->ContextSize = sizeof(sg_peer_context);
    if (!freerdp_peer_context_new( peer )) goto out;
    ((sg_peer_context *)peer->context)->authenticated = FALSE;
    settings = peer->context->settings;

    cert = freerdp_certificate_new_from_pem( g_cert_pem );
    key  = freerdp_key_new_from_pem( g_key_pem );
    if (!cert || !key ||
        !freerdp_settings_set_pointer_len( settings, FreeRDP_RdpServerCertificate, cert, 1 ) ||
        !freerdp_settings_set_pointer_len( settings, FreeRDP_RdpServerRsaKey, key, 1 ))
    {
        logmsg( "ERROR cannot build the TLS certificate/key for a connection" );
        goto out;
    }
    /* TLS only. Legacy RDP security is unencrypted in practice and never
     * offered; NLA is not offered for local accounts -- see the header. */
    freerdp_settings_set_bool( settings, FreeRDP_RdpSecurity, FALSE );
    freerdp_settings_set_bool( settings, FreeRDP_TlsSecurity, TRUE );
    freerdp_settings_set_bool( settings, FreeRDP_NlaSecurity, FALSE );

    /* Bitmap updates -- planar for a client that takes it without an alpha
     * plane (DrawAllowSkipAlpha, kept only if the client advertises it too),
     * else uncompressed -- and nothing this server does not implement. */
    freerdp_settings_set_bool( settings, FreeRDP_SupportGraphicsPipeline, FALSE );
    freerdp_settings_set_bool( settings, FreeRDP_RemoteFxCodec, FALSE );
    freerdp_settings_set_bool( settings, FreeRDP_NSCodec, FALSE );
    freerdp_settings_set_bool( settings, FreeRDP_DrawAllowSkipAlpha, TRUE );
    freerdp_settings_set_uint32( settings, FreeRDP_ColorDepth, 32 );

    peer->Logon = on_logon;
    peer->PostConnect = on_post_connect;
    peer->Activate = on_activate;
    peer->context->input->KeyboardEvent = on_key;
    peer->context->input->UnicodeKeyboardEvent = on_unicode;
    peer->context->input->SynchronizeEvent = on_sync;
    peer->context->input->MouseEvent = on_mouse;
    peer->context->input->ExtendedMouseEvent = on_xmouse;

    if (!peer->Initialize( peer )) goto out;
    for (;;)
    {
        sg_peer_context *ctx = (sg_peer_context *)peer->context;
        HANDLE handles[MAXIMUM_WAIT_OBJECTS];
        DWORD count = peer->GetEventHandles( peer, handles, ARRAYSIZE(handles) - 1 );
        if (!count) break;
        if (ctx->stream && ctx->stream_event)
        {
            sg_stream_prepare( ctx->stream );
            handles[count++] = ctx->stream_event;
        }
        if (WaitForMultipleObjects( count, handles, FALSE, INFINITE ) == WAIT_FAILED) break;
        if (ctx->stream && ctx->stream_event && sg_stream_after_wait( ctx->stream ) < 0)
        {
            /* The user signed out, or the session died: nothing left to show. */
            logmsg( "SESSION ended from=%s", peer->hostname );
            break;
        }
        if (!peer->CheckFileDescriptor( peer )) break;
    }
    peer->Disconnect( peer );
out:
    if (peer->context)
    {
        sg_peer_context *ctx = (sg_peer_context *)peer->context;
        /* The session keeps running: the next login for this user reconnects. */
        if (ctx->stream) logmsg( "SESSION detached from=%s", peer->hostname );
        sg_stream_free( ctx->stream );
        ctx->stream = NULL;
        if (ctx->stream_event) CloseHandle( ctx->stream_event );
    }
    freerdp_peer_context_free( peer );
    freerdp_peer_free( peer );
    return 0;
}

static BOOL on_accepted( freerdp_listener *listener, freerdp_peer *peer )
{
    HANDLE t;
    (void)listener;
    if (!(t = CreateThread( NULL, 0, peer_thread, peer, 0, NULL ))) return FALSE;
    CloseHandle( t );
    return TRUE;
}

static char *read_file( const char *path )
{
    FILE *f = fopen( path, "r" );
    char *buf = NULL;
    long len;

    if (!f) return NULL;
    if (fseek( f, 0, SEEK_END ) == 0 && (len = ftell( f )) > 0 && len < (1 << 20) &&
        fseek( f, 0, SEEK_SET ) == 0 && (buf = calloc( 1, (size_t)len + 1 )))
    {
        if (fread( buf, 1, (size_t)len, f ) != (size_t)len) { free( buf ); buf = NULL; }
    }
    fclose( f );
    return buf;
}

/* Give up root for good: supplementary groups, then gid, then uid, in that
 * order, and check it stuck. */
static int drop_privileges( const char *account )
{
    struct passwd *pw = getpwnam( account );
    if (!pw) { fprintf( stderr, "no account %s to drop to\n", account ); return -1; }
    if (setgroups( 0, NULL ) < 0 || setgid( pw->pw_gid ) < 0 || setuid( pw->pw_uid ) < 0) return -1;
    /* FreeRDP makes each connection's settings under $HOME and fails every
     * connection without one; a service has none unless given it. */
    setenv( "HOME", pw->pw_dir, 0 );
    if (setuid( 0 ) == 0) { fprintf( stderr, "privilege drop did not stick\n" ); return -1; }
    return 0;
}

int main( int argc, char **argv )
{
    const char *bind = getenv( "SG_RDP_BIND" );
    const char *helper = getenv( "SG_RDP_PAMCHECK" );
    const char *account = getenv( "SG_RDP_USER" );
    const char *logpath = getenv( "SG_RDP_LOG" );
    const char *seat_root = getenv( "SG_RDP_SEAT_ROOT" );
    int port = argc > 1 ? atoi( argv[1] ) : 3389;
    int sv[2];
    pid_t mon;
    freerdp_listener *listener;

    const char *cert_path = getenv( "SG_RDP_CERT" );
    const char *key_path  = getenv( "SG_RDP_KEY" );
    if (!bind) bind = "0.0.0.0";
    if (!helper) helper = "/usr/libexec/stained-glass/sg-rdp-pamcheck";
    /* Remote sign-in never accepts a blank password (the lock screen's
     * console exception is not for the network). */
    unsetenv( "SG_PAMCHECK_CONSOLE" );
    if (!account) account = "sgrdp";
    if (seat_root) g_seat_root = seat_root;
    if (getenv( "SG_RDP_BROKER_SOCK" )) g_broker_sock = getenv( "SG_RDP_BROKER_SOCK" );
    if (getenv( "SG_ADMIN_GROUP" )) g_admin_group = getenv( "SG_ADMIN_GROUP" );
    if (!cert_path || !key_path) { fprintf( stderr, "SG_RDP_CERT and SG_RDP_KEY are required\n" ); return 2; }
    if (!(g_cert_pem = read_file( cert_path )) || !(g_key_pem = read_file( key_path )))
    {
        fprintf( stderr, "cannot read %s / %s\n", cert_path, key_path );
        return 2;
    }
    mlock( g_key_pem, strlen( g_key_pem ) + 1 );
    g_log = logpath ? fopen( logpath, "a" ) : stderr;
    if (!g_log) g_log = stderr;

    if (socketpair( AF_UNIX, SOCK_STREAM, 0, sv ) < 0) return 1;
    if ((mon = fork()) < 0) return 1;
    if (!mon)
    {
        close( sv[1] );
        monitor_loop( sv[0], helper );
        _exit( 0 );
    }
    close( sv[0] );
    g_monitor_fd = sv[1];

    /* From here on nothing needs root. Drop before the listener exists. When
     * not started as root (the gate), there is nothing to drop. */
    if (geteuid() == 0 && drop_privileges( account ) < 0) { kill( mon, SIGTERM ); return 1; }

    InitializeCriticalSection( &g_monitor_lock );
    winpr_InitializeSSL( WINPR_SSL_INIT_DEFAULT );
    if (!(listener = freerdp_listener_new())) return 1;
    listener->PeerAccepted = on_accepted;
    if (!listener->Open( listener, bind, (UINT16)port ))
    {
        logmsg( "ERROR cannot listen on %s:%d", bind, port );
        return 1;
    }
    logmsg( "LISTENING %s:%d uid=%d", bind, port, (int)geteuid() );

    for (;;)
    {
        HANDLE handles[32];
        DWORD count = listener->GetEventHandles( listener, handles, ARRAYSIZE(handles) );
        if (!count) break;
        if (WaitForMultipleObjects( count, handles, FALSE, INFINITE ) == WAIT_FAILED) break;
        if (!listener->CheckFileDescriptor( listener )) break;
    }
    listener->Close( listener );
    freerdp_listener_free( listener );
    kill( mon, SIGTERM );
    return 0;
}
