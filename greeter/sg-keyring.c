/* sg-keyring: a person's own keyring, from their session -- for the notice
 * shown at sign-in when it did not open.
 *
 * Signing in opens the login keyring (gnome-keyring's Secret Service) with
 * the password typed. After an administrator's reset (chpasswd: no current
 * password to re-encrypt it with) it stays encrypted with the old password
 * and does not open: programs that keep passwords there (browsers, mail, VPN
 * clients, Windows programs' Credential Manager) find nothing, or ask. On
 * Windows a reset loses what DPAPI protected with the old password; here the
 * person is told why, and chooses:
 *
 *   status          prints "open", "locked", "none" (no login keyring) or
 *                   "unavailable" (no Secret Service on the session bus)
 *   recover         stdin: OLD NUL CURRENT NUL. Re-encrypts the login keyring
 *                   with the current sign-in password (checked by PAM, so a
 *                   typing slip cannot lock it away again) and opens it:
 *                   "OK", "FAIL current" or "FAIL old"
 *   reset           stdin: CURRENT NUL. A new, empty login keyring with the
 *                   current password; the old file is kept beside it as
 *                   login.keyring.before-reset-DATE (never loaded, never
 *                   deleted by us): "OK", "FAIL current" or "FAIL <why>"
 *
 * Run as the person, in their session (the session bus); passwords only on
 * standard input, never on a command line or in a log. gnome-keyring's
 * internal D-Bus interface (ChangeWithMasterPassword and friends, which
 * seahorse-like tools use) does the work, through a "plain" session: the
 * secret crosses the person's own session bus, as secret-tool's does.
 *
 * SG_PAM_CONFDIR (the gate's PAM configuration directory) and
 * SG_KEYRING_PAM_SERVICE (default stained-glass-keyring) are for testing.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#define _GNU_SOURCE
#include <gio/gio.h>
#include <security/pam_appl.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define MAXPW 512
#define SECRETS "org.freedesktop.secrets"
#define SERVICE_PATH "/org/freedesktop/secrets"
#define LOGIN_PATH "/org/freedesktop/secrets/collection/login"
#define INTERNAL "org.gnome.keyring.InternalUnsupportedGuiltRiddenInterface"

static char g_pw[MAXPW];   /* the password PAM's conversation answers with */

static int conv( int n, const struct pam_message **msg, struct pam_response **resp, void *data )
{
    struct pam_response *r;
    int i;

    (void)data;
    if (n <= 0 || n > PAM_MAX_NUM_MSG) return PAM_CONV_ERR;
    if (!(r = calloc( (size_t)n, sizeof(*r) ))) return PAM_BUF_ERR;
    for (i = 0; i < n; i++)
    {
        if (msg[i]->msg_style == PAM_PROMPT_ECHO_OFF && (r[i].resp = strdup( g_pw ))) continue;
        if (msg[i]->msg_style == PAM_PROMPT_ECHO_OFF || msg[i]->msg_style == PAM_PROMPT_ECHO_ON)
        {
            for (i = 0; i < n; i++)
                if (r[i].resp) { explicit_bzero( r[i].resp, strlen( r[i].resp ) ); free( r[i].resp ); }
            free( r );
            return PAM_CONV_ERR;
        }
    }
    *resp = r;
    return PAM_SUCCESS;
}

/* Is this the person's sign-in password? PAM decides (pam_unix, unprivileged,
 * asks unix_chkpwd, which answers for one's own account only). */
static int password_is_current( const char *pw )
{
    const char *service = getenv( "SG_KEYRING_PAM_SERVICE" ), *confdir = getenv( "SG_PAM_CONFDIR" );
    struct pam_conv pc = { conv, NULL };
    struct passwd *p = getpwuid( getuid() );
    pam_handle_t *ph = NULL;
    int rc;

    if (!p || !pw[0]) return 0;
    if (!service || !service[0]) service = "stained-glass-keyring";
    snprintf( g_pw, sizeof(g_pw), "%s", pw );
    rc = confdir && confdir[0] ? pam_start_confdir( service, p->pw_name, &pc, confdir, &ph )
                               : pam_start( service, p->pw_name, &pc, &ph );
    if (rc == PAM_SUCCESS) rc = pam_authenticate( ph, PAM_DISALLOW_NULL_AUTHTOK );
    explicit_bzero( g_pw, sizeof(g_pw) );
    if (ph) pam_end( ph, rc );
    return rc == PAM_SUCCESS;
}

static int read_field( char *buf, size_t max )
{
    size_t i = 0;
    for (;;)
    {
        char c;
        if (read( STDIN_FILENO, &c, 1 ) != 1) return -1;
        if (!c) { buf[i] = 0; return 0; }
        if (i + 1 >= max) return -1;
        buf[i++] = c;
    }
}

static GVariant *call( GDBusConnection *bus, const char *path, const char *iface, const char *method,
                       GVariant *args, const char *reply_type, GError **err )
{
    return g_dbus_connection_call_sync( bus, SECRETS, path, iface, method, args,
                                        reply_type ? G_VARIANT_TYPE( reply_type ) : NULL,
                                        G_DBUS_CALL_FLAGS_NONE, 30000, NULL, err );
}

/* 1 locked, 0 open, -1 no login keyring, -2 no Secret Service */
static int login_locked( GDBusConnection *bus )
{
    GError *err = NULL;
    GVariant *v = call( bus, LOGIN_PATH, "org.freedesktop.DBus.Properties", "Get",
                        g_variant_new( "(ss)", "org.freedesktop.Secret.Collection", "Locked" ), "(v)", &err );
    int ret;

    if (!v)
    {
        ret = err && (g_error_matches( err, G_DBUS_ERROR, G_DBUS_ERROR_SERVICE_UNKNOWN ) ||
                      g_error_matches( err, G_DBUS_ERROR, G_DBUS_ERROR_NAME_HAS_NO_OWNER ) ||
                      g_error_matches( err, G_DBUS_ERROR, G_DBUS_ERROR_SPAWN_FAILED )) ? -2 : -1;
        g_clear_error( &err );
        return ret;
    }
    {
        GVariant *inner;
        g_variant_get( v, "(v)", &inner );
        ret = g_variant_get_boolean( inner ) ? 1 : 0;
        g_variant_unref( inner );
    }
    g_variant_unref( v );
    return ret;
}

static char *open_session( GDBusConnection *bus )
{
    GError *err = NULL;
    GVariant *v = call( bus, SERVICE_PATH, "org.freedesktop.Secret.Service", "OpenSession",
                        g_variant_new( "(sv)", "plain", g_variant_new_string( "" ) ), "(vo)", &err );
    char *path = NULL;
    GVariant *out;

    if (!v) { g_clear_error( &err ); return NULL; }
    g_variant_get( v, "(vo)", &out, &path );
    g_variant_unref( out );
    g_variant_unref( v );
    return path;
}

static GVariant *secret( const char *session, const char *pw )
{
    return g_variant_new( "(o@ay@ays)", session,
                          g_variant_new_fixed_array( G_VARIANT_TYPE_BYTE, "", 0, 1 ),
                          g_variant_new_fixed_array( G_VARIANT_TYPE_BYTE, pw, strlen( pw ), 1 ),
                          "text/plain" );
}

static char *keyring_file( void )
{
    const char *data = getenv( "XDG_DATA_HOME" ), *home = getenv( "HOME" );
    if (data && data[0] == '/') return g_strdup_printf( "%s/keyrings/login.keyring", data );
    if (!home || home[0] != '/') { struct passwd *p = getpwuid( getuid() ); home = p ? p->pw_dir : "/"; }
    return g_strdup_printf( "%s/.local/share/keyrings/login.keyring", home );
}

static int do_recover( GDBusConnection *bus )
{
    char old[MAXPW], cur[MAXPW];
    GError *err = NULL;
    GVariant *v;
    char *session;
    int ok = 0;

    if (read_field( old, sizeof(old) ) < 0 || read_field( cur, sizeof(cur) ) < 0)
    {
        explicit_bzero( old, sizeof(old) ); explicit_bzero( cur, sizeof(cur) );
        puts( "FAIL malformed request" );
        return 1;
    }
#ifndef SG_MUTANT_KEYRING_NOCHECK
    if (!password_is_current( cur ))
    {
        explicit_bzero( old, sizeof(old) ); explicit_bzero( cur, sizeof(cur) );
        puts( "FAIL current" );
        return 1;
    }
#endif
    if (!(session = open_session( bus )))
    {
        explicit_bzero( old, sizeof(old) ); explicit_bzero( cur, sizeof(cur) );
        puts( "FAIL the keyring service did not answer" );
        return 1;
    }
    /* the keyring's own password from now on is the sign-in password */
    v = call( bus, SERVICE_PATH, INTERNAL, "ChangeWithMasterPassword",
              g_variant_new( "(o@(oayays)@(oayays))", LOGIN_PATH, secret( session, old ), secret( session, cur ) ),
              NULL, &err );
    if (v)
    {
        g_variant_unref( v );
        v = call( bus, SERVICE_PATH, INTERNAL, "UnlockWithMasterPassword",
                  g_variant_new( "(o@(oayays))", LOGIN_PATH, secret( session, cur ) ), NULL, &err );
        if (v) { g_variant_unref( v ); ok = 1; }
    }
    explicit_bzero( old, sizeof(old) ); explicit_bzero( cur, sizeof(cur) );
    g_free( session );
    if (ok) { puts( "OK" ); return 0; }
    /* The daemon says only "Couldn't change collection password": with the
     * current password already checked, the old one is what was wrong. */
    g_clear_error( &err );
    puts( "FAIL old" );
    return 1;
}

static int do_reset( GDBusConnection *bus )
{
    char cur[MAXPW], *file, *kept, *session = NULL, *path = NULL;
    GError *err = NULL;
    GVariant *v = NULL;
    GVariantBuilder props;
    struct stat st;
    char stamp[32];
    time_t now = time( NULL );
    int i;

    if (read_field( cur, sizeof(cur) ) < 0)
    {
        explicit_bzero( cur, sizeof(cur) );
        puts( "FAIL malformed request" );
        return 1;
    }
    if (!password_is_current( cur ))
    {
        explicit_bzero( cur, sizeof(cur) );
        puts( "FAIL current" );
        return 1;
    }
    /* The old keyring is kept, under a name gnome-keyring does not load: what
     * it holds can still be had with its password, by hand. */
    file = keyring_file();
    strftime( stamp, sizeof(stamp), "%Y%m%d-%H%M%S", localtime( &now ) );
    kept = g_strdup_printf( "%s.before-reset-%s", file, stamp );
    if (!lstat( file, &st ) && rename( file, kept ) < 0)
    {
        explicit_bzero( cur, sizeof(cur) );
        puts( "FAIL the old keyring could not be moved aside" );
        g_free( file ); g_free( kept );
        return 1;
    }
    /* gnome-keyring watches the directory: wait for the old one to go */
    for (i = 0; i < 50 && login_locked( bus ) >= 0; i++) g_usleep( 100000 );

    if ((session = open_session( bus )))
    {
        g_variant_builder_init( &props, G_VARIANT_TYPE( "a{sv}" ) );
        /* the label names the file and the object: "login", as the keyring
         * made at sign-in is (login.keyring, collection/login); then the
         * name shown, "Login", as that one has */
        g_variant_builder_add( &props, "{sv}", "org.freedesktop.Secret.Collection.Label", g_variant_new_string( "login" ) );
        v = call( bus, SERVICE_PATH, INTERNAL, "CreateWithMasterPassword",
                  g_variant_new( "(a{sv}@(oayays))", &props, secret( session, cur ) ), "(o)", &err );
    }
    explicit_bzero( cur, sizeof(cur) );
    if (v)
    {
        g_variant_get( v, "(o)", &path );
        g_variant_unref( v );
        v = call( bus, path, "org.freedesktop.DBus.Properties", "Set",
                  g_variant_new( "(ssv)", "org.freedesktop.Secret.Collection", "Label", g_variant_new_string( "Login" ) ),
                  NULL, NULL );
        if (v) g_variant_unref( v );
        v = call( bus, SERVICE_PATH, "org.freedesktop.Secret.Service", "SetAlias",
                  g_variant_new( "(so)", "default", path ), NULL, &err );
        if (v) g_variant_unref( v );
    }
    g_free( session ); g_free( file ); g_free( kept );
    if (path && v) { g_free( path ); puts( "OK" ); return 0; }
    g_free( path );
    printf( "FAIL %s\n", err ? err->message : "the keyring service did not answer" );
    g_clear_error( &err );
    return 1;
}

int main( int argc, char **argv )
{
    GDBusConnection *bus;
    GError *err = NULL;
    const char *cmd = argc > 1 ? argv[1] : "";
    int rc;

    if (strcmp( cmd, "status" ) && strcmp( cmd, "recover" ) && strcmp( cmd, "reset" ))
    {
        fprintf( stderr, "usage: sg-keyring status | recover | reset (passwords on standard input)\n" );
        return 2;
    }
    if (!(bus = g_bus_get_sync( G_BUS_TYPE_SESSION, NULL, &err )))
    {
        g_clear_error( &err );
        puts( strcmp( cmd, "status" ) ? "FAIL no session bus" : "unavailable" );
        return 1;
    }
    if (!strcmp( cmd, "status" ))
    {
        switch (login_locked( bus ))
        {
        case 1: puts( "locked" ); break;
        case 0: puts( "open" ); break;
        case -1: puts( "none" ); break;
        default: puts( "unavailable" ); break;
        }
        rc = 0;
    }
    else rc = !strcmp( cmd, "recover" ) ? do_recover( bus ) : do_reset( bus );
    fflush( stdout );
    g_object_unref( bus );
    return rc;
}
