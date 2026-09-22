/* The lock service (ADR 0009, ADR 0011).
 *
 * The compositor does the isolation: while locked, only privileged clients are
 * seen or sent input. This service supplies the lock screen and decides when
 * to unlock. It WATCHes the compositor's control socket; when the machine
 * locks -- Win+L, Ctrl+Alt+Del, LockWorkStation(), idle -- it starts the lock
 * UI on the privileged socket, checks what the UI collects against PAM, and
 * sends UNLOCK only when PAM says yes.
 *
 * Whose password? The session user's. That comes from SO_PEERCRED on the
 * connection to the compositor, which runs as the session user -- the kernel's
 * statement, not anybody's claim.
 *
 * Privilege separation as in sg-rdp-authd: a root monitor forked at startup
 * runs the PAM helper and nothing else; everything else, including the Wine
 * that draws the lock screen, runs as the machine session's account. A failed
 * guess costs 2s in the monitor.
 *
 * The UI speaks the greeter's line protocol on the pipes it is started with:
 *   <- HELLO                   -> PROMPT_SECRET <text>
 *   <- REPLY <password>        -> SUCCESS | FAILURE <text>
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#define _GNU_SOURCE
#include <errno.h>
#include <grp.h>
#include <poll.h>
#include <pwd.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <dirent.h>
#include <sys/wait.h>
#include <unistd.h>

#define MAXFIELD 512

static FILE *g_log;
static int g_monitor = -1;
static const char *g_control, *g_ui_cmd, *g_seat_dir;
static char g_control_buf[256], g_priv_buf[256];

static void logmsg( const char *fmt, ... )
{
    va_list ap;
    va_start( ap, fmt );
    fputs( "[sg-lockd] ", g_log );
    vfprintf( g_log, fmt, ap );
    fputc( '\n', g_log );
    fflush( g_log );
    va_end( ap );
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

/* ---- root monitor: PAM and nothing else -------------------------------- */

static int run_pamcheck( const char *helper, const char *user, const char *pass )
{
    int in[2], out[2], status = 0;
    char reply[64] = "";
    ssize_t n;
    pid_t pid;

    if (pipe( in ) < 0 || pipe( out ) < 0 || (pid = fork()) < 0) return 0;
    if (!pid)
    {
        dup2( in[0], 0 ); dup2( out[1], 1 );
        close( in[0] ); close( in[1] ); close( out[0] ); close( out[1] );
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
    return WIFEXITED( status ) && !WEXITSTATUS( status ) && !strncmp( reply, "OK", 2 );
}

static void monitor_loop( int fd, const char *helper )
{
    for (;;)
    {
        unsigned ulen, plen;
        char user[MAXFIELD], pass[MAXFIELD];
        unsigned char ok;

        if (read_full( fd, &ulen, sizeof(ulen) ) || read_full( fd, &plen, sizeof(plen) )) _exit( 0 );
        if (ulen >= MAXFIELD || plen >= MAXFIELD) _exit( 1 );
        if (read_full( fd, user, ulen ) || read_full( fd, pass, plen )) _exit( 0 );
        user[ulen] = 0; pass[plen] = 0;
        ok = (unsigned char)run_pamcheck( helper, user, pass );
        explicit_bzero( pass, sizeof(pass) );
        if (!ok) sleep( 2 );
        if (write_full( fd, &ok, 1 )) _exit( 0 );
    }
}

static int check_password( const char *user, const char *pass )
{
    unsigned ulen = (unsigned)strlen( user ), plen = (unsigned)strlen( pass );
    unsigned char ok = 0;
    if (ulen >= MAXFIELD || plen >= MAXFIELD) return 0;
    if (write_full( g_monitor, &ulen, sizeof(ulen) ) || write_full( g_monitor, &plen, sizeof(plen) ) ||
        write_full( g_monitor, user, ulen ) || write_full( g_monitor, pass, plen ) ||
        read_full( g_monitor, &ok, 1 ))
        return 0;
    return ok == 1;
}

/* ---- the compositor ---------------------------------------------------- */

static int control_connect( void )
{
    struct sockaddr_un addr = { .sun_family = AF_UNIX };
    int fd;
    if (strlen( g_control ) >= sizeof(addr.sun_path)) return -1;
    strcpy( addr.sun_path, g_control );
    if ((fd = socket( AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0 )) < 0) return -1;
    if (connect( fd, (struct sockaddr *)&addr, sizeof(addr) ) < 0) { close( fd ); return -1; }
    return fd;
}

static int control_command( const char *cmd, char *reply, size_t max )
{
    int fd = control_connect();
    ssize_t n;
    if (fd < 0) return -1;
    write_full( fd, cmd, strlen( cmd ) );
    n = read( fd, reply, max - 1 );
    close( fd );
    if (n <= 0) return -1;
    reply[n] = 0;
    return 0;
}

/* Find the session on this seat: a directory named by uid holding a control
 * socket whose compositor -- by SO_PEERCRED -- really runs as that uid. Anyone
 * in sgwine can make a directory there, so the name alone proves nothing; a
 * directory named for someone else, served by a different uid, is skipped.
 * Sets g_control, and SG_LOCK_PRIV for the lock UI. */
static int find_session( void )
{
    DIR *d = opendir( g_seat_dir );
    struct dirent *e;
    int found = 0;

    if (!d) return 0;
    while (!found && (e = readdir( d )))
    {
        char *end;
        long want = strtol( e->d_name, &end, 10 );
        struct ucred cred;
        socklen_t clen = sizeof(cred);
        int fd;

        if (!e->d_name[0] || *end || want < 0) continue;
        /* A truncated path could name a different socket: skip, never trim. */
        if ((size_t)snprintf( g_control_buf, sizeof(g_control_buf), "%s/%s/control.sock",
                              g_seat_dir, e->d_name ) >= sizeof(g_control_buf))
            continue;
        g_control = g_control_buf;
        if ((fd = control_connect()) < 0) continue;
        if (!getsockopt( fd, SOL_SOCKET, SO_PEERCRED, &cred, &clen ) && (long)cred.uid == want)
        {
            if ((size_t)snprintf( g_priv_buf, sizeof(g_priv_buf), "%s/%s/priv.sock",
                                  g_seat_dir, e->d_name ) < sizeof(g_priv_buf))
            {
                setenv( "SG_LOCK_PRIV", g_priv_buf, 1 );
                found = 1;
            }
        }
        else logmsg( "ignoring %s: not served by uid %ld", g_control_buf, want );
        close( fd );
    }
    closedir( d );
    return found;
}

/* ---- the lock UI ------------------------------------------------------- */

struct ui { pid_t pid; int to, from; };

static int ui_start( struct ui *ui, const char *user )
{
    int up[2], down[2];
    if (pipe( up ) < 0 || pipe( down ) < 0) return -1;
    if ((ui->pid = fork()) < 0) return -1;
    if (!ui->pid)
    {
        dup2( down[0], 0 ); dup2( up[1], 1 );
        close( up[0] ); close( up[1] ); close( down[0] ); close( down[1] );
        setsid();   /* its own process group, so teardown takes Xwayland too */
        {
            /* The command must hand the user on as "$1": `sh -c CMD NAME USER`
             * sets $1, but only a CMD that uses it passes it along -- the
             * first version did not, and the UI died on every start. */
            char cmd[1024];
            snprintf( cmd, sizeof(cmd), "exec %s \"$1\"", g_ui_cmd );
            execl( "/bin/sh", "sh", "-c", cmd, "sg-lock-ui", user, (char *)NULL );
        }
        _exit( 127 );
    }
    close( up[1] ); close( down[0] );
    ui->from = up[0];
    ui->to = down[1];
    return 0;
}

static void ui_stop( struct ui *ui )
{
    if (ui->pid <= 0) return;
    close( ui->to ); close( ui->from );
    kill( -ui->pid, SIGTERM );
    for (int i = 0; i < 20 && waitpid( ui->pid, NULL, WNOHANG ) == 0; i++) usleep( 100000 );
    kill( -ui->pid, SIGKILL );
    waitpid( ui->pid, NULL, 0 );
    ui->pid = 0;
}

static void ui_send( struct ui *ui, const char *fmt, ... )
{
    char buf[1024];
    va_list ap;
    int n;
    va_start( ap, fmt );
    n = vsnprintf( buf, sizeof(buf) - 2, fmt, ap );
    va_end( ap );
    if (n < 0) return;
    buf[n++] = '\n';
    write_full( ui->to, buf, (size_t)n );
}

static int read_line( int fd, char *buf, size_t max )
{
    size_t i = 0;
    while (i < max - 1)
    {
        char c;
        ssize_t n = read( fd, &c, 1 );
        if (n <= 0) { if (n < 0 && errno == EINTR) continue; return -1; }
        if (c == '\n') break;
        if (c != '\r') buf[i++] = c;
    }
    buf[i] = 0;
    return 0;
}

/* Handle one line from the lock UI. Returns 1 when unlocked. */
static int ui_line( struct ui *ui, const char *user, char *line )
{
    char reply[64];

    if (!strncmp( line, "HELLO", 5 ))
        ui_send( ui, "PROMPT_SECRET Password for %s:", user );
    else if (!strncmp( line, "REPLY ", 6 ))
    {
        int ok = check_password( user, line + 6 );
        explicit_bzero( line, strlen( line ) );
        if (!ok)
        {
            logmsg( "unlock refused for %s: wrong password", user );
            ui_send( ui, "FAILURE The password is incorrect." );
            ui_send( ui, "PROMPT_SECRET Password for %s:", user );
            return 0;
        }
        if (control_command( "UNLOCK\n", reply, sizeof(reply) ) || strncmp( reply, "OK unlocked", 11 ))
        {
            logmsg( "PAM accepted %s but the compositor refused UNLOCK: %s", user, reply );
            ui_send( ui, "FAILURE The session could not be unlocked." );
            return 0;
        }
        logmsg( "unlocked by %s", user );
        ui_send( ui, "SUCCESS" );
        return 1;
    }
    return 0;
}

static int drop_privileges( const char *account )
{
    struct passwd *pw = getpwnam( account );
    if (!pw) return -1;
    if (initgroups( pw->pw_name, pw->pw_gid ) < 0 || setgid( pw->pw_gid ) < 0 || setuid( pw->pw_uid ) < 0) return -1;
    if (setuid( 0 ) == 0) return -1;
    return 0;
}

int main( void )
{
    const char *helper = getenv( "SG_LOCK_PAMCHECK" );
    const char *account = getenv( "SG_SYSTEM_USER" );
    const char *logpath = getenv( "SG_LOCKD_LOG" );
    int sv[2];
    pid_t mon;

    /* A fixed control socket (the gate), or a seat directory to scan. */
    g_control = getenv( "SG_LOCK_CONTROL" );
    g_seat_dir = getenv( "SG_SEAT_DIR" );
    if (!g_seat_dir) g_seat_dir = "/run/stained-glass/seat0";
    g_ui_cmd = getenv( "SG_LOCK_UI" );
    if (!g_ui_cmd) g_ui_cmd = "/usr/lib/stained-glass/sg-lock-ui";
    if (!helper) helper = "/usr/libexec/stained-glass/sg-rdp-pamcheck";
    /* Its own PAM service, so an administrator can give unlocking a different
     * policy from remote login. The helper reads this. */
    setenv( "SG_REMOTE_PAM_SERVICE", "stained-glass-lock", 0 );
    if (!account) account = "sgsystem";
    g_log = logpath ? fopen( logpath, "a" ) : stderr;
    if (!g_log) g_log = stderr;
    int scan = !g_control;
    signal( SIGPIPE, SIG_IGN );

    if (socketpair( AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv ) < 0 || (mon = fork()) < 0) return 1;
    if (!mon) { close( sv[1] ); monitor_loop( sv[0], helper ); _exit( 0 ); }
    close( sv[0] );
    g_monitor = sv[1];
    /* initgroups keeps the machine account's groups (sgwine), which the
     * shared Wine prefix needs; the PAM helper is the monitor's alone. */
    if (geteuid() == 0 && drop_privileges( account ) < 0) { logmsg( "cannot drop to %s", account ); return 1; }

    for (;;)
    {
        struct ucred cred;
        socklen_t clen = sizeof(cred);
        struct passwd *pw;
        char user[MAXFIELD], ev[64];
        struct ui ui = { 0 };
        int w;

        if (scan && !find_session()) { sleep( 1 ); continue; }
        w = control_connect();

        if (w < 0) { sleep( 1 ); continue; }
        /* The compositor runs as the session user: whose session this is. */
        if (getsockopt( w, SOL_SOCKET, SO_PEERCRED, &cred, &clen ) < 0 || !(pw = getpwuid( cred.uid )))
        { close( w ); sleep( 1 ); continue; }
        snprintf( user, sizeof(user), "%s", pw->pw_name );
        write_full( w, "WATCH\n", 6 );
        logmsg( "watching the session of %s", user );

        for (;;)
        {
            struct pollfd pf[2] = { { w, POLLIN, 0 }, { ui.pid > 0 ? ui.from : -1, POLLIN, 0 } };
            if (poll( pf, 2, -1 ) < 0) { if (errno == EINTR) continue; break; }

            if (pf[0].revents)
            {
                if (read_line( w, ev, sizeof(ev) ) < 0) break;   /* compositor gone */
                if ((!strcmp( ev, "locked" ) || !strcmp( ev, "OK locked" )) && ui.pid <= 0)
                {
                    logmsg( "locked: starting the lock screen for %s", user );
                    if (ui_start( &ui, user ) < 0) logmsg( "could not start the lock UI" );
                }
                else if (!strcmp( ev, "unlocked" ) || !strcmp( ev, "OK unlocked" ))
                    ui_stop( &ui );
            }
            if (ui.pid > 0 && pf[1].revents)
            {
                char line[MAXFIELD + 16];
                if (read_line( ui.from, line, sizeof(line) ) < 0)
                {
                    /* The lock UI died. The machine stays locked -- the
                     * compositor shows nothing but privileged clients -- so
                     * put it back. */
                    logmsg( "lock UI exited while locked; restarting it" );
                    ui_stop( &ui );
                    sleep( 1 );   /* never a tight loop if it dies on start */
                    ui_start( &ui, user );
                    continue;
                }
                if (ui_line( &ui, user, line ) == 1) ui_stop( &ui );
            }
        }
        ui_stop( &ui );
        close( w );
        logmsg( "compositor went away; waiting for the next one" );
        sleep( 1 );
    }
}
