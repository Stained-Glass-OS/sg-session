/* Between the Windows login screen and PAM.
 *
 * The greeter is a Windows program (ADR 0008) because remote-support tools can
 * only see a Windows login screen. It must not be the thing that decides
 * whether a login succeeds, so this sits between it and greetd: the greeter
 * collects, greetd's PAM stack decides.
 *
 * The transport is a pair of pipes created here, before forking the greeter.
 * Wine has no AF_UNIX, and a loopback port would be reachable by every local
 * user and need a shared secret to close that hole again; a pipe handed to a
 * child is reachable by nobody else, which is the kernel's guarantee rather
 * than ours.
 *
 * greetd's IPC is length-prefixed JSON on $GREETD_SOCK. The JSON here is
 * written and parsed by hand: the messages are four shapes, and a parser we
 * can read in full is worth more in an authentication path than a dependency.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

static int greetd_fd = -1;
static int to_greeter = -1;    /* we write, greeter reads  */
static int from_greeter = -1;  /* greeter writes, we read  */

static void logmsg( const char *fmt, ... )
{
    va_list ap;
    va_start( ap, fmt );
    fputs( "[sg-greet-bridge] ", stderr );
    vfprintf( stderr, fmt, ap );
    fputc( '\n', stderr );
    va_end( ap );
}

/* --- greetd IPC ---------------------------------------------------------- */

static int greetd_connect( void )
{
    const char *path = getenv( "GREETD_SOCK" );
    struct sockaddr_un addr;
    int fd;

    if (!path) { logmsg( "GREETD_SOCK is not set; not running under greetd" ); return -1; }
    if ((fd = socket( AF_UNIX, SOCK_STREAM, 0 )) < 0) return -1;
    memset( &addr, 0, sizeof(addr) );
    addr.sun_family = AF_UNIX;
    snprintf( addr.sun_path, sizeof(addr.sun_path), "%s", path );
    if (connect( fd, (struct sockaddr *)&addr, sizeof(addr) ) < 0)
    {
        logmsg( "connect %s: %s", path, strerror(errno) );
        close( fd );
        return -1;
    }
    return fd;
}

static int write_all( int fd, const void *buf, size_t len )
{
    const char *p = buf;
    while (len)
    {
        ssize_t n = write( fd, p, len );
        if (n <= 0) { if (errno == EINTR) continue; return -1; }
        p += n; len -= (size_t)n;
    }
    return 0;
}

static int read_all( int fd, void *buf, size_t len )
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

/* greetd frames every message with a native-endian uint32 length. */
static int greetd_send( const char *json )
{
    uint32_t len = (uint32_t)strlen( json );
    if (write_all( greetd_fd, &len, sizeof(len) ) < 0) return -1;
    return write_all( greetd_fd, json, len );
}

static char *greetd_recv( void )
{
    uint32_t len;
    char *buf;

    if (read_all( greetd_fd, &len, sizeof(len) ) < 0) return NULL;
    if (len > (1u << 20)) return NULL;
    if (!(buf = malloc( len + 1 ))) return NULL;
    if (read_all( greetd_fd, buf, len ) < 0) { free( buf ); return NULL; }
    buf[len] = 0;
    return buf;
}

/* Escape for a JSON string literal. Passwords reach greetd through here, so
 * every byte that could end the string early has to be handled. */
static void json_escape( const char *in, char *out, size_t max )
{
    size_t o = 0;
    for (; *in && o + 7 < max; in++)
    {
        unsigned char c = (unsigned char)*in;
        switch (c)
        {
        case '"':  memcpy( out + o, "\\\"", 2 ); o += 2; break;
        case '\\': memcpy( out + o, "\\\\", 2 ); o += 2; break;
        case '\n': memcpy( out + o, "\\n", 2 );  o += 2; break;
        case '\r': memcpy( out + o, "\\r", 2 );  o += 2; break;
        case '\t': memcpy( out + o, "\\t", 2 );  o += 2; break;
        default:
            if (c < 0x20) o += (size_t)snprintf( out + o, max - o, "\\u%04x", c );
            else out[o++] = (char)c;
        }
    }
    out[o] = 0;
}

/* Enough JSON to read greetd's replies: find "key":"value" or "key":"..." and
 * copy the value out, undoing the escapes greetd may have put in. */
static int json_string( const char *json, const char *key, char *out, size_t max )
{
    char pat[64];
    const char *p;
    size_t o = 0;

    snprintf( pat, sizeof(pat), "\"%s\"", key );
    if (!(p = strstr( json, pat ))) return 0;
    p += strlen( pat );
    while (*p == ' ' || *p == ':') p++;
    if (*p != '"') return 0;
    p++;
    while (*p && *p != '"' && o + 1 < max)
    {
        if (*p == '\\' && p[1])
        {
            p++;
            switch (*p)
            {
            case 'n': out[o++] = '\n'; break;
            case 'r': out[o++] = '\r'; break;
            case 't': out[o++] = '\t'; break;
            default:  out[o++] = *p;   break;
            }
            p++;
        }
        else out[o++] = *p++;
    }
    out[o] = 0;
    return 1;
}

/* --- talking to the greeter ---------------------------------------------- */

static void to_ui( const char *fmt, ... )
{
    char buf[2048];
    va_list ap;
    int n;

    va_start( ap, fmt );
    n = vsnprintf( buf, sizeof(buf) - 2, fmt, ap );
    va_end( ap );
    if (n < 0) return;
    buf[n++] = '\n';
    write_all( to_greeter, buf, (size_t)n );
}

static int from_ui( char *buf, size_t max )
{
    size_t i = 0;
    while (i < max - 1)
    {
        char c;
        ssize_t n = read( from_greeter, &c, 1 );
        if (n <= 0) { if (n < 0 && errno == EINTR) continue; return 0; }
        if (c == '\n') break;
        if (c != '\r') buf[i++] = c;
    }
    buf[i] = 0;
    return 1;
}

/* --- the exchange -------------------------------------------------------- */

/* Drives one greetd message and tells the UI what happened. Returns 1 when the
 * session has started and we are done. */
static int handle_greetd_reply( const char *cmd_for_session )
{
    char *msg = greetd_recv();
    char type[64], text[1024], kind[32];
    int done = 0;

    if (!msg) { to_ui( "ERROR The login service closed the connection." ); return -1; }

    if (!json_string( msg, "type", type, sizeof(type) )) { free( msg ); return 0; }

    if (!strcmp( type, "auth_message" ))
    {
        json_string( msg, "auth_message", text, sizeof(text) );
        json_string( msg, "auth_message_type", kind, sizeof(kind) );
        if (!strcmp( kind, "secret" ))      to_ui( "PROMPT_SECRET %s", text );
        else if (!strcmp( kind, "visible" )) to_ui( "PROMPT_VISIBLE %s", text );
        else if (!strcmp( kind, "error" ))   to_ui( "ERROR %s", text );
        else                                 to_ui( "INFO %s", text );
    }
    else if (!strcmp( type, "success" ))
    {
        /* greetd answers "success" to each step; the session only starts once
         * we ask it to, which is what this second exchange is for. */
        if (cmd_for_session)
        {
            char buf[2048], esc[1024];
            json_escape( cmd_for_session, esc, sizeof(esc) );
            snprintf( buf, sizeof(buf),
                      "{\"type\":\"start_session\",\"cmd\":[\"%s\"],\"env\":[]}", esc );
            if (greetd_send( buf ) < 0) { to_ui( "ERROR Could not start the session." ); free( msg ); return -1; }
            free( msg );
            msg = greetd_recv();
            if (msg && json_string( msg, "type", type, sizeof(type) ) && !strcmp( type, "success" ))
            {
                to_ui( "SUCCESS" );
                done = 1;
            }
            else
            {
                if (msg && json_string( msg, "description", text, sizeof(text) ))
                    to_ui( "FAILURE %s", text );
                else to_ui( "FAILURE The session could not be started." );
            }
        }
        else done = 1;
    }
    else if (!strcmp( type, "error" ))
    {
        char etype[64];
        json_string( msg, "error_type", etype, sizeof(etype) );
        if (!json_string( msg, "description", text, sizeof(text) ))
            snprintf( text, sizeof(text), "Authentication failed." );
        /* An auth error means wrong credentials; anything else is the service
         * itself being unhappy, and saying so saves a lot of guessing. */
        to_ui( "FAILURE %s", !strcmp( etype, "auth_error" )
               ? "The user name or password is incorrect." : text );
        greetd_send( "{\"type\":\"cancel_session\"}" );
        free( greetd_recv() );
    }
    free( msg );
    return done;
}

int main( int argc, char **argv )
{
    const char *session_cmd = (argc > 1) ? argv[1] : "/usr/bin/sg-session-start";
    const char *greeter_cmd = (argc > 2) ? argv[2] : NULL;
    int up[2], down[2];
    pid_t child;
    char line[2048];

    if (!greeter_cmd) { logmsg( "usage: sg-greet-bridge <session-cmd> <greeter-cmd>" ); return 2; }
    if ((greetd_fd = greetd_connect()) < 0) return 1;
    if (pipe( up ) < 0 || pipe( down ) < 0) { logmsg( "pipe: %s", strerror(errno) ); return 1; }

    if ((child = fork()) < 0) { logmsg( "fork: %s", strerror(errno) ); return 1; }
    if (!child)
    {
        /* The greeter reads down[0] as stdin and writes up[1] as stdout. Its
         * stderr is left alone so Wine's own diagnostics still reach the
         * journal instead of being parsed as protocol. */
        dup2( down[0], STDIN_FILENO );
        dup2( up[1], STDOUT_FILENO );
        close( up[0] ); close( up[1] ); close( down[0] ); close( down[1] );
        execl( "/bin/sh", "sh", "-c", greeter_cmd, (char *)NULL );
        _exit( 127 );
    }
    close( up[1] ); close( down[0] );
    from_greeter = up[0];
    to_greeter   = down[1];

    while (from_ui( line, sizeof(line) ))
    {
        if (!strncmp( line, "HELLO", 5 ))
        {
            to_ui( "READY" );
        }
        else if (!strncmp( line, "USER ", 5 ))
        {
            char buf[1024], esc[512];
            json_escape( line + 5, esc, sizeof(esc) );
            snprintf( buf, sizeof(buf), "{\"type\":\"create_session\",\"username\":\"%s\"}", esc );
            if (greetd_send( buf ) < 0) { to_ui( "ERROR The login service is unavailable." ); break; }
            if (handle_greetd_reply( session_cmd ) > 0) break;
        }
        else if (!strncmp( line, "REPLY ", 6 ))
        {
            char buf[2048], esc[1024];
            json_escape( line + 6, esc, sizeof(esc) );
            snprintf( buf, sizeof(buf),
                      "{\"type\":\"post_auth_message_response\",\"response\":\"%s\"}", esc );
            /* The password is in these buffers and nowhere else; clear both as
             * soon as greetd has it. */
            if (greetd_send( buf ) < 0) { to_ui( "ERROR The login service is unavailable." ); break; }
            memset( buf, 0, sizeof(buf) );
            memset( esc, 0, sizeof(esc) );
            memset( line, 0, sizeof(line) );
            if (handle_greetd_reply( session_cmd ) > 0) break;
        }
        memset( line, 0, sizeof(line) );
    }

    /* greetd starts the session itself once start_session succeeds, so the
     * greeter's job is over; let it close before we go. */
    close( to_greeter );
    waitpid( child, NULL, 0 );
    return 0;
}
