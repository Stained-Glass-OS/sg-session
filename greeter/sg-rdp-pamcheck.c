/* The privileged half of remote login: check one credential against PAM.
 *
 * Remote login (ADR 0010, pattern B) receives a username and password from the
 * network. The code that parses the RDP protocol is the part most exposed to
 * hostile input, so it runs unprivileged; checking an arbitrary user's password
 * needs root. This program is the only thing that holds both the credential and
 * root at once, so it does one thing and is short enough to read in full --
 * the same separation sshd uses.
 *
 * Protocol on stdin: <user> NUL <password> NUL. Reply on stdout: "OK\n" or
 * "FAIL <reason>\n". Nothing else. PAM is the only authority on the answer, so
 * account expiry, lockout (pam_faillock) and domain modules apply unchanged.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#define _GNU_SOURCE
#include <security/pam_appl.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define MAXFIELD 512

static char g_password[MAXFIELD];

/* Answers PAM's prompts: the password for anything echo-off, nothing else.
 * PAM modules that want more than a password (an OTP, a second factor) get a
 * refusal, not a guess -- the remote client has only sent one secret. */
static int conv( int n, const struct pam_message **msg, struct pam_response **resp, void *data )
{
    struct pam_response *r;
    int i;

    (void)data;
    if (n <= 0 || n > PAM_MAX_NUM_MSG) return PAM_CONV_ERR;
    if (!(r = calloc( (size_t)n, sizeof(*r) ))) return PAM_BUF_ERR;
    for (i = 0; i < n; i++)
    {
        if (msg[i]->msg_style == PAM_PROMPT_ECHO_OFF)
        {
            if (!(r[i].resp = strdup( g_password ))) goto fail;
        }
        else if (msg[i]->msg_style == PAM_PROMPT_ECHO_ON)
        {
            goto fail;
        }
    }
    *resp = r;
    return PAM_SUCCESS;
fail:
    for (i = 0; i < n; i++)
        if (r[i].resp) { explicit_bzero( r[i].resp, strlen( r[i].resp ) ); free( r[i].resp ); }
    free( r );
    return PAM_CONV_ERR;
}

/* Read a NUL-terminated field. Refuses anything that does not fit rather than
 * truncating: a truncated password could match a different password. */
static int read_field( char *buf, size_t max )
{
    size_t i = 0;
    for (;;)
    {
        char c;
        ssize_t n = read( STDIN_FILENO, &c, 1 );
        if (n != 1) return -1;
        if (!c) { buf[i] = 0; return 0; }
        if (i + 1 >= max) return -1;
        buf[i++] = c;
    }
}

/* The lock screen opens the session's keyring if it was closed (its daemon
 * restarted, or a program locked it): pam_gnome_keyring, in the lock
 * screen's PAM stack, unlocks it with the password just typed. It finds the
 * person's keyring daemon through XDG_RUNTIME_DIR, which sg-lockd -- a
 * system service -- does not have: name the person's runtime directory, if
 * it is theirs. SG_RUNTIME_ROOT (default /run/user) is the gate's. */
static int set_runtime_dir( pam_handle_t *ph, const char *user )
{
    const char *root = getenv( "SG_RUNTIME_ROOT" );
    char dir[400], line[440];
    struct passwd *pw = getpwnam( user );
    struct stat st;

    if (!pw) return PAM_SUCCESS;
    if (!root || !root[0]) root = "/run/user";
    snprintf( dir, sizeof(dir), "%s/%u", root, (unsigned)pw->pw_uid );
    if (lstat( dir, &st ) || !S_ISDIR( st.st_mode ) || st.st_uid != pw->pw_uid) return PAM_SUCCESS;
    snprintf( line, sizeof(line), "XDG_RUNTIME_DIR=%s", dir );
    return pam_putenv( ph, line );
}

int main( void )
{
    const char *service = getenv( "SG_REMOTE_PAM_SERVICE" ), *confdir = getenv( "SG_PAM_CONFDIR" );
    char user[MAXFIELD];
    struct pam_conv pc = { conv, NULL };
    pam_handle_t *ph = NULL;
    const char *s, *rhost;
    int rc, console, keyring, flags;

    if (!service) service = "stained-glass-remote";

    if (read_field( user, sizeof(user) ) < 0 || read_field( g_password, sizeof(g_password) ) < 0)
    {
        explicit_bzero( g_password, sizeof(g_password) );
        puts( "FAIL malformed request" );
        return 1;
    }
    if (!user[0]) { puts( "FAIL empty user" ); return 1; }

    /* SG_PAM_CONFDIR: the gate's PAM configuration instead of /etc/pam.d */
    rc = confdir && confdir[0] ? pam_start_confdir( service, user, &pc, confdir, &ph ) : pam_start( service, user, &pc, &ph );
    /* A blank password is refused -- unless the caller is the lock screen,
     * at the console: as Windows' "limit local account use of blank
     * passwords to console logon only". The live system's account has none. */
    console = (s = getenv( "SG_PAMCHECK_CONSOLE" )) && !strcmp( s, "1" );
    flags = console ? 0 : PAM_DISALLOW_NULL_AUTHTOK;
    /* The remote host: SG_PAMCHECK_RHOST when the caller gives one (empty:
     * none, as for elevation at this machine), else "rdp" off the console.
     * libpam's audit record looks a host name up in DNS -- "rdp" cost two
     * 4 s timeouts, and elevation took 8 s to check a password (field
     * report 2) */
    if (!(rhost = getenv( "SG_PAMCHECK_RHOST" ))) rhost = console ? "" : "rdp";
    if (rc == PAM_SUCCESS && *rhost) rc = pam_set_item( ph, PAM_RHOST, rhost );
    /* SG_PAMCHECK_KEYRING=1: sg-rdp-authd's second check, once a remote
     * session exists -- its keyring opens with the password, as the lock
     * screen's does (pam_gnome_keyring in stained-glass-remote). */
    keyring = (s = getenv( "SG_PAMCHECK_KEYRING" )) && !strcmp( s, "1" );
#ifndef SG_MUTANT_LOCK_KEYRING
    if (rc == PAM_SUCCESS && console) rc = set_runtime_dir( ph, user );
#endif
#ifndef SG_MUTANT_RDP_KEYRING
    if (rc == PAM_SUCCESS && keyring && !console) rc = set_runtime_dir( ph, user );
#else
    (void)keyring;
#endif
    if (rc == PAM_SUCCESS) rc = pam_authenticate( ph, flags );
    /* Authentication is not authorisation: an expired or locked account has a
     * correct password and must still be refused. */
    if (rc == PAM_SUCCESS) rc = pam_acct_mgmt( ph, flags );

    explicit_bzero( g_password, sizeof(g_password) );

    if (rc == PAM_SUCCESS) puts( "OK" );
    else printf( "FAIL %s\n", pam_strerror( ph, rc ) );
    if (ph) pam_end( ph, rc );
    fflush( stdout );
    return rc == PAM_SUCCESS ? 0 : 1;
}
