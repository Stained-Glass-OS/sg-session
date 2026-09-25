/* Between the setup wizard and the installer service.
 *
 * The wizard (sg-setup.exe) is a Windows program, like the login screen it
 * replaces on a live boot, and it decides nothing: this passes what it asks
 * for to sg-installd, the root service that runs sg-install, and passes the
 * answers back. Wine has no AF_UNIX, so the wizard talks to this over a pair
 * of pipes created here before it is started, and this talks to the service's
 * socket.
 *
 *   sg-setup-bridge <wizard command>
 *   sg-setup-bridge --oobe <first-run setup command>
 *
 * With --oobe it serves the first-run setup (sg-oobe.exe) instead, in front
 * of sg-oobed, with that service's requests.
 *
 * Only the requests the service knows are passed on, one line each. Nothing
 * the wizard sends is logged except the fact that it is ready: one of the lines
 * carries the new owner's password.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#define LINE_MAX_LEN 2048

static void logmsg( const char *fmt, ... )
{
    va_list ap;
    va_start( ap, fmt );
    fputs( "[sg-setup-bridge] ", stderr );
    vfprintf( stderr, fmt, ap );
    fputc( '\n', stderr );
    va_end( ap );
}

static int write_all( int fd, const char *p, size_t len )
{
    while (len)
    {
        ssize_t n = send( fd, p, len, MSG_NOSIGNAL );
        if (n < 0 && errno == ENOTSOCK) n = write( fd, p, len );
        if (n < 0) { if (errno == EINTR) continue; return -1; }
        p += n; len -= n;
    }
    return 0;
}

static int oobe;     /* --oobe: the first-run setup and sg-oobed */

static int connect_service( void )
{
    const char *path = getenv( oobe ? "SG_OOBED_SOCK" : "SG_INSTALLD_SOCK" );
    struct sockaddr_un addr;
    int fd;

    if (!path) path = oobe ? "/run/stained-glass-oobe/oobed.sock" : "/run/stained-glass-setup/installd.sock";
    if ((fd = socket( AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0 )) < 0) return -1;
    memset( &addr, 0, sizeof(addr) );
    addr.sun_family = AF_UNIX;
    snprintf( addr.sun_path, sizeof(addr.sun_path), "%s", path );
    if (connect( fd, (struct sockaddr *)&addr, sizeof(addr) ) < 0) { close( fd ); return -1; }
    return fd;
}

/* A line buffer per direction: requests are passed on whole, or not at all. */
struct buf { char data[LINE_MAX_LEN]; size_t len; };

static int allowed( const char *line )
{
    static const char *const ok[] = { "LIST", "LAYOUT", "DRIVERS", "NEW ", "DELETE ", "FORMAT ", "INSTALL ",
                                      "PASSWORD ", "REBOOT", "POWEROFF", NULL };
    static const char *const ok_oobe[] = { "STATE", "NETWORKS", "CONNECT ", "KEY", "KEY ", "ACCOUNT ",
                                           "PASSWORD ", "FINISH ", NULL };
    const char *const *list = oobe ? ok_oobe : ok;
    size_t i;
    for (i = 0; list[i]; i++)
    {
        size_t n = strlen( list[i] );
        if (list[i][n - 1] == ' ' ? !strncmp( line, list[i], n ) : !strcmp( line, list[i] )) return 1;
    }
    return 0;
}

/* Reads what is available on fd into b and hands each complete line to fn.
 * Returns -1 at end of file. */
static int pump( int fd, struct buf *b, void (*fn)( char *line, void *ctx ), void *ctx )
{
    ssize_t n = read( fd, b->data + b->len, sizeof(b->data) - b->len );
    char *nl;

    if (n < 0 && errno == EINTR) return 0;
    if (n <= 0) return -1;
    b->len += n;
    while ((nl = memchr( b->data, '\n', b->len )))
    {
        size_t used = nl - b->data + 1;
        *nl = 0;
        if (nl > b->data && nl[-1] == '\r') nl[-1] = 0;
        fn( b->data, ctx );
        memmove( b->data, b->data + used, b->len - used );
        explicit_bzero( b->data + b->len - used, used );
        b->len -= used;
    }
    if (b->len == sizeof(b->data))
    {
        /* An overlong line is dropped whole, never passed on in pieces. */
        explicit_bzero( b->data, sizeof(b->data) );
        b->len = 0;
    }
    return 0;
}

static int to_ui = -1, service = -1;

static void to_wizard( const char *fmt, ... )
{
    char line[LINE_MAX_LEN];
    va_list ap;
    int n;

    va_start( ap, fmt );
    n = vsnprintf( line, sizeof(line) - 1, fmt, ap );
    va_end( ap );
    if (n < 0) return;
    if (n > (int)sizeof(line) - 2) n = sizeof(line) - 2;
    line[n++] = '\n';
    write_all( to_ui, line, n );
}

static void from_wizard( char *line, void *ctx )
{
    char out[LINE_MAX_LEN + 1];
    size_t n;

    (void)ctx;
    if (!strcmp( line, "HELLO" ))
    {
        /* The window exists and takes input: a real readiness signal for
         * anything waiting on it -- the install gate, remote support. */
        logmsg( oobe ? "oobe ready" : "setup ready" );
        /* The login screen script waits on this to know the first-run
         * setup is really up (and falls back to the login screen if not). */
        if (oobe && getenv( "SG_OOBE_READY" ))
        {
            FILE *f = fopen( getenv( "SG_OOBE_READY" ), "w" );
            if (f) fclose( f );
        }
        return;
    }
    if (!oobe && !strcmp( line, "TRY" ))
    {
        /* "Try Stained Glass OS": not the installer service's business. The
         * login screen script reads the answer when the wizard has closed,
         * and signs in the live session. */
        const char *result = getenv( "SG_SETUP_RESULT" );
        FILE *f = result ? fopen( result, "w" ) : NULL;
        if (f) { fputs( "try\n", f ); fclose( f ); }
        logmsg( "try the live system" );
        return;
    }
    if (!allowed( line )) return;
    if (service < 0)
    {
        to_wizard( oobe ? "FAILED The setup service is not available." : "FAILED The installer service is not available." );
        return;
    }
    n = strlen( line );
    memcpy( out, line, n );
    out[n++] = '\n';
    if (write_all( service, out, n ) < 0) to_wizard( "FAILED The installer service stopped." );
    explicit_bzero( out, sizeof(out) );
}

static void from_service( char *line, void *ctx )
{
    (void)ctx;
    to_wizard( "%s", line );
}

int main( int argc, char **argv )
{
    int up[2], down[2];
    struct buf ui_buf = {0}, svc_buf = {0};
    int from_ui;
    pid_t child;

    if (argc > 2 && !strcmp( argv[1], "--oobe" )) { oobe = 1; argv++; argc--; }
    if (argc < 2) { logmsg( "usage: sg-setup-bridge [--oobe] <wizard command>" ); return 2; }
    signal( SIGPIPE, SIG_IGN );
    if (pipe( up ) < 0 || pipe( down ) < 0) { logmsg( "pipe: %s", strerror( errno ) ); return 1; }
    if ((child = fork()) < 0) { logmsg( "fork: %s", strerror( errno ) ); return 1; }
    if (!child)
    {
        /* stdin and stdout are the protocol; stderr stays Wine's. */
        dup2( down[0], STDIN_FILENO );
        dup2( up[1], STDOUT_FILENO );
        close( up[0] ); close( up[1] ); close( down[0] ); close( down[1] );
        /* Tells the wizard it has its bridge (without it, it starts one). */
        setenv( "SG_SETUP_BRIDGED", "1", 1 );
        execl( "/bin/sh", "sh", "-c", argv[1], (char *)NULL );
        _exit( 127 );
    }
    close( up[1] ); close( down[0] );
    from_ui = up[0];
    to_ui = down[1];

    if ((service = connect_service()) < 0) logmsg( "cannot reach the installer service: %s", strerror( errno ) );

    for (;;)
    {
        struct pollfd p[2] = { { from_ui, POLLIN, 0 }, { service, POLLIN, 0 } };
        int nfds = service >= 0 ? 2 : 1;

        if (poll( p, nfds, -1 ) < 0) { if (errno == EINTR) continue; break; }
        if (p[0].revents && pump( from_ui, &ui_buf, from_wizard, NULL ) < 0) break;
        if (nfds == 2 && p[1].revents && pump( service, &svc_buf, from_service, NULL ) < 0)
        {
            logmsg( "the installer service closed the connection" );
            close( service );
            service = -1;
            to_wizard( "FAILED The installer service stopped." );
        }
    }
    explicit_bzero( &ui_buf, sizeof(ui_buf) );
    close( to_ui );
    if (service >= 0) close( service );
    waitpid( child, NULL, 0 );
    return 0;
}
