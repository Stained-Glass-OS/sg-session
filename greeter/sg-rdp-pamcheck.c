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
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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

int main( void )
{
    const char *service = getenv( "SG_REMOTE_PAM_SERVICE" );
    char user[MAXFIELD];
    struct pam_conv pc = { conv, NULL };
    pam_handle_t *ph = NULL;
    int rc;

    if (!service) service = "stained-glass-remote";

    if (read_field( user, sizeof(user) ) < 0 || read_field( g_password, sizeof(g_password) ) < 0)
    {
        explicit_bzero( g_password, sizeof(g_password) );
        puts( "FAIL malformed request" );
        return 1;
    }
    if (!user[0]) { puts( "FAIL empty user" ); return 1; }

    rc = pam_start( service, user, &pc, &ph );
    if (rc == PAM_SUCCESS) rc = pam_set_item( ph, PAM_RHOST, "rdp" );
    if (rc == PAM_SUCCESS) rc = pam_authenticate( ph, PAM_DISALLOW_NULL_AUTHTOK );
    /* Authentication is not authorisation: an expired or locked account has a
     * correct password and must still be refused. */
    if (rc == PAM_SUCCESS) rc = pam_acct_mgmt( ph, PAM_DISALLOW_NULL_AUTHTOK );

    explicit_bzero( g_password, sizeof(g_password) );

    if (rc == PAM_SUCCESS) puts( "OK" );
    else printf( "FAIL %s\n", pam_strerror( ph, rc ) );
    if (ph) pam_end( ph, rc );
    fflush( stdout );
    return rc == PAM_SUCCESS ? 0 : 1;
}
