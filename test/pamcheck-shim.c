/* A stand-in for libpam, preloaded under sg-rdp-pamcheck by
 * test/pamcheck-test.sh: records the flags the checker authenticates with and
 * the remote host it names, and says yes. Never installed.
 * SPDX-License-Identifier: AGPL-3.0-or-later */
#include <security/pam_appl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static FILE *out( void )
{
    const char *p = getenv( "SG_PAMCHECK_SHIM_OUT" );
    return p ? fopen( p, "a" ) : stderr;
}

int pam_start( const char *service, const char *user, const struct pam_conv *conv, pam_handle_t **ph )
{
    FILE *f = out();
    fprintf( f, "service=%s\n", service );
    if (f != stderr) fclose( f );
    *ph = (pam_handle_t *)1;
    return PAM_SUCCESS;
}

int pam_set_item( pam_handle_t *ph, int type, const void *item )
{
    FILE *f = out();
    if (type == PAM_RHOST) fprintf( f, "rhost=%s\n", (const char *)item );
    if (f != stderr) fclose( f );
    return PAM_SUCCESS;
}

int pam_authenticate( pam_handle_t *ph, int flags )
{
    FILE *f = out();
    fprintf( f, "auth_null=%s\n", flags & PAM_DISALLOW_NULL_AUTHTOK ? "refused" : "allowed" );
    if (f != stderr) fclose( f );
    return PAM_SUCCESS;
}

int pam_acct_mgmt( pam_handle_t *ph, int flags ) { return PAM_SUCCESS; }
int pam_end( pam_handle_t *ph, int status ) { return PAM_SUCCESS; }
const char *pam_strerror( pam_handle_t *ph, int err ) { return "shim"; }
