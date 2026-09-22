/* Remote login over RDP, pattern B of ADR 0010: the technician types the
 * username and password into the RDP client before connecting, and on success
 * lands in an unlocked desktop -- the way `mstsc` works against Windows.
 *
 * This is the credential half. It accepts RDP connections with FreeRDP, takes
 * the credential the client sends, and asks PAM. Streaming the session that
 * follows needs sg-compositor and is not here yet.
 *
 * Privilege separation, as in sshd. The code that parses RDP from the network
 * is the most exposed code in the system, so it must not run as root -- but
 * checking an arbitrary user's password needs root. So at startup, while still
 * root, this forks a *monitor* that keeps root and does one thing: run
 * sg-rdp-pamcheck for a (user, password) it is handed over a socketpair. The
 * parent then drops to an unprivileged account before opening the listener.
 * A compromise of the RDP parser gets an unprivileged process whose only
 * privileged capability is "ask whether this password is right" -- slowly.
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
#include <grp.h>
#include <pwd.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/wait.h>
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
} sg_peer_context;
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
static int monitor_check( const char *helper, const char *user, const char *pass )
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

static void monitor_loop( int fd, const char *helper )
{
    for (;;)
    {
        unsigned ulen, plen;
        char user[MAXFIELD], pass[MAXFIELD];
        unsigned char ok;

        if (read_full( fd, &ulen, sizeof(ulen) ) < 0) _exit( 0 );
        if (read_full( fd, &plen, sizeof(plen) ) < 0) _exit( 0 );
        if (ulen >= MAXFIELD || plen >= MAXFIELD) _exit( 1 );
        if (read_full( fd, user, ulen ) < 0 || read_full( fd, pass, plen ) < 0) _exit( 0 );
        user[ulen] = 0; pass[plen] = 0;

        ok = (unsigned char)monitor_check( helper, user, pass );
        explicit_bzero( pass, sizeof(pass) );
        /* A failed guess costs the guesser time here, in the one process the
         * network cannot reach, so it cannot be skipped by reconnecting. */
        if (!ok) sleep( 2 );
        if (write_full( fd, &ok, 1 ) < 0) _exit( 0 );
    }
}

/* Unprivileged side: ask the monitor. Serialised, because one socketpair is
 * shared by every peer thread. */
static CRITICAL_SECTION g_monitor_lock;

static int ask_monitor( const char *user, const char *pass )
{
    unsigned ulen = (unsigned)strlen( user ), plen = (unsigned)strlen( pass );
    unsigned char ok = 0;
    int res = -1;

    if (ulen >= MAXFIELD || plen >= MAXFIELD) return 0;
    EnterCriticalSection( &g_monitor_lock );
    if (!write_full( g_monitor_fd, &ulen, sizeof(ulen) ) &&
        !write_full( g_monitor_fd, &plen, sizeof(plen) ) &&
        !write_full( g_monitor_fd, user, ulen ) &&
        !write_full( g_monitor_fd, pass, plen ) &&
        !read_full( g_monitor_fd, &ok, 1 ))
        res = ok;
    LeaveCriticalSection( &g_monitor_lock );
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
        ok = ask_monitor( user, pass );
        logmsg( "LOGON %s user=%s from=%s", ok ? "OK" : "FAIL", user, peer->hostname );
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
    return require_auth( peer, "Activate" );
}

static BOOL on_post_connect( freerdp_peer *peer )
{
    if (!authenticate( peer )) return FALSE;
    if (!require_auth( peer, "PostConnect" )) return FALSE;
    /* Authenticated. Starting and streaming the user's session is the
     * compositor's half of ADR 0010; until it exists, say so and close
     * rather than leave a connected client staring at nothing. */
    logmsg( "SESSION pending (needs sg-compositor) from=%s", peer->hostname );
    return FALSE;
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

    peer->Logon = on_logon;
    peer->PostConnect = on_post_connect;
    peer->Activate = on_activate;

    if (!peer->Initialize( peer )) goto out;
    for (;;)
    {
        HANDLE handles[MAXIMUM_WAIT_OBJECTS];
        DWORD count = peer->GetEventHandles( peer, handles, ARRAYSIZE(handles) );
        if (!count) break;
        if (WaitForMultipleObjects( count, handles, FALSE, INFINITE ) == WAIT_FAILED) break;
        if (!peer->CheckFileDescriptor( peer )) break;
    }
    peer->Disconnect( peer );
out:
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
    if (setuid( 0 ) == 0) { fprintf( stderr, "privilege drop did not stick\n" ); return -1; }
    return 0;
}

int main( int argc, char **argv )
{
    const char *bind = getenv( "SG_RDP_BIND" );
    const char *helper = getenv( "SG_RDP_PAMCHECK" );
    const char *account = getenv( "SG_RDP_USER" );
    const char *logpath = getenv( "SG_RDP_LOG" );
    int port = argc > 1 ? atoi( argv[1] ) : 3389;
    int sv[2];
    pid_t mon;
    freerdp_listener *listener;

    const char *cert_path = getenv( "SG_RDP_CERT" );
    const char *key_path  = getenv( "SG_RDP_KEY" );
    if (!bind) bind = "0.0.0.0";
    if (!helper) helper = "/usr/libexec/stained-glass/sg-rdp-pamcheck";
    if (!account) account = "sgrdp";
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
