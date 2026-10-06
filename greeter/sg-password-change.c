/* sg-password-change: a person changes their own password, and the keyring
 * that holds their saved passwords follows.
 *
 * Each session has a keyring (gnome-keyring's Secret Service: VPN clients,
 * browsers, mail and chat programs keep their passwords there), encrypted
 * with the sign-in password and opened by it when the person signs in. An
 * administrator's reset (chpasswd) changes only the sign-in password -- the
 * keyring cannot be re-encrypted without the old one, so at the next sign-in
 * it stays locked. When a person changes their own password (Settings,
 * Control Panel: they type the current one, as on Windows) this program
 * changes both, through PAM's password stack exactly as passwd(1) does when
 * the person runs it: pam_unix checks the current password and writes the
 * new one, and pam_gnome_keyring (in common-password, from its pam-auth-update
 * profile) re-encrypts the login keyring -- in the running session's keyring
 * daemon if the person is signed in, or in one it starts for the purpose if
 * not.
 *
 * Runs as root (sg-admind starts it). passwd is set-uid root: its real uid is
 * the person's, and that is what tells pam_unix to ask for and check the
 * current password and pam_gnome_keyring to have the old password to hand.
 * This program takes the same identity: real uid the person's, effective
 * uid root.
 *
 * Protocol on stdin: <user> NUL <current password> NUL <new password> NUL.
 * Reply on stdout: "OK\n", "FAIL current\n" (the current password is
 * wrong), or "FAIL <reason>\n". Nothing else.
 *
 * Test hooks (for the gate, which runs it unprivileged): SG_PAM_CONFDIR, a
 * PAM configuration directory to use instead of /etc/pam.d; SG_RUNTIME_ROOT,
 * where the per-user runtime directories are (default /run/user).
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#define _GNU_SOURCE
#include <security/pam_appl.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <ftw.h>
#include <grp.h>
#include <signal.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#define MAXFIELD 512

static char g_current[MAXFIELD], g_new[MAXFIELD], g_msg[256];
static int g_secret_prompts;

static void wipe( void )
{
    explicit_bzero( g_current, sizeof(g_current) );
    explicit_bzero( g_new, sizeof(g_new) );
}

/* pam_unix asks, in order: the current password, the new one, the new one
 * again. The first hidden prompt gets the current password, every later one
 * the new. Messages are kept: the last one says why a change was refused
 * ("You must choose a longer password"). */
static int conv( int n, const struct pam_message **msg, struct pam_response **resp, void *data )
{
    struct pam_response *r;
    int i;

    (void)data;
    if (n <= 0 || n > PAM_MAX_NUM_MSG) return PAM_CONV_ERR;
    if (!(r = calloc( (size_t)n, sizeof(*r) ))) return PAM_BUF_ERR;
    for (i = 0; i < n; i++)
    {
        switch (msg[i]->msg_style)
        {
        case PAM_PROMPT_ECHO_OFF:
            if (!(r[i].resp = strdup( g_secret_prompts++ ? g_new : g_current ))) goto fail;
            break;
        case PAM_ERROR_MSG:
        case PAM_TEXT_INFO:
            if (msg[i]->msg && msg[i]->msg[0])
            {
                char *nl;
                snprintf( g_msg, sizeof(g_msg), "%s", msg[i]->msg );
                while ((nl = strpbrk( g_msg, "\r\n" ))) *nl = ' ';   /* one reply line */
            }
            break;
        default:
            goto fail;   /* nothing to answer a visible prompt with */
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

static int remove_one( const char *path, const struct stat *st, int type, struct FTW *ftw )
{
    (void)st; (void)ftw;
    return type == FTW_DP ? rmdir( path ) : unlink( path );
}

/* Removes the runtime directory made for a signed-out person's change, as
 * that person: it is theirs (the keyring daemon wrote into it), and root must
 * not walk a tree its owner can rearrange underneath it. */
static void remove_runtime( const char *dir, const struct passwd *pw )
{
    pid_t pid = fork();
    if (pid == 0)
    {
        if (geteuid() == 0 && (setgid( pw->pw_gid ) < 0 || setuid( pw->pw_uid ) < 0)) _exit( 1 );
        _exit( nftw( dir, remove_one, 8, FTW_DEPTH | FTW_PHYS ) ? 1 : 0 );
    }
    if (pid > 0) waitpid( pid, NULL, 0 );
}

/* A keyring daemon for a signed-out person, in the private runtime directory,
 * started here because pam_gnome_keyring cannot start one itself under
 * passwd's identity (it drops to the real uid, then cannot set the group).
 * The keyring stays locked: the change opens it with the current password.
 * Returns its pid once its control socket is there, or -1. */
static pid_t start_daemon( const struct passwd *pw, const char *runtime )
{
    char sock[512], home[600], rt[600];
    struct stat st;
    pid_t pid;
    int i;

    snprintf( sock, sizeof(sock), "%s/keyring/control", runtime );
    if ((pid = fork()) < 0) return -1;
    if (!pid)
    {
        char *argv[] = { (char *)"gnome-keyring-daemon", (char *)"--foreground", (char *)"--components=secrets", NULL };
        char *envp[] = { home, rt, (char *)"PATH=/usr/bin:/bin", NULL };
        int fd = open( "/dev/null", O_RDWR );
        if (fd >= 0) { dup2( fd, 0 ); dup2( fd, 1 ); dup2( fd, 2 ); if (fd > 2) close( fd ); }
        if (geteuid() == 0 && (setresgid( pw->pw_gid, pw->pw_gid, pw->pw_gid ) < 0
                               || initgroups( pw->pw_name, pw->pw_gid ) < 0
                               || setresuid( pw->pw_uid, pw->pw_uid, pw->pw_uid ) < 0)) _exit( 127 );
        snprintf( home, sizeof(home), "HOME=%s", pw->pw_dir );
        snprintf( rt, sizeof(rt), "XDG_RUNTIME_DIR=%s", runtime );
        execve( "/usr/bin/gnome-keyring-daemon", argv, envp );
        _exit( 127 );
    }
    for (i = 0; i < 100; i++)   /* up to 10 s */
    {
        struct timespec ts = { 0, 100000000 };
        if (!lstat( sock, &st ) && S_ISSOCK( st.st_mode )) return pid;
        if (waitpid( pid, NULL, WNOHANG ) == pid) return -1;
        nanosleep( &ts, NULL );
    }
    kill( pid, SIGTERM );
    waitpid( pid, NULL, 0 );
    return -1;
}

/* Refuses anything that does not fit rather than truncating it. */
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

static void reply( const char *what )
{
    puts( what );
    fflush( stdout );
}

int main( void )
{
    const char *confdir = getenv( "SG_PAM_CONFDIR" ), *runroot = getenv( "SG_RUNTIME_ROOT" );
    char user[MAXFIELD], runtime[400], line[440], made[64] = "";
    pid_t daemon = -1;
    struct pam_conv pc = { conv, NULL };
    pam_handle_t *ph = NULL;
    struct passwd *pw;
    struct stat st;
    int rc;

    if (read_field( user, sizeof(user) ) < 0 || read_field( g_current, sizeof(g_current) ) < 0
        || read_field( g_new, sizeof(g_new) ) < 0)
    {
        wipe();
        reply( "FAIL malformed request" );
        return 1;
    }
    if (!user[0] || !g_new[0]) { wipe(); reply( "FAIL empty user or password" ); return 1; }
    if (!(pw = getpwnam( user ))) { wipe(); reply( "FAIL no such account" ); return 1; }
    /* root's real uid would tell pam_unix not to check the current password */
    if (!pw->pw_uid) { wipe(); reply( "FAIL not for the root account" ); return 1; }
    if (!confdir || !confdir[0]) confdir = NULL;
    if (!runroot || !runroot[0]) runroot = "/run/user";

#ifndef SG_MUTANT_PWCHANGE_RUID
    /* passwd's identity: real uid the person's, effective uid root */
    if (geteuid() == 0 && setresuid( pw->pw_uid, 0, 0 ) < 0)
    {
        wipe();
        reply( "FAIL cannot take the account's identity" );
        return 1;
    }
#endif

    rc = pam_start_confdir( "stained-glass-password", user, &pc, confdir, &ph );
#ifndef SG_MUTANT_PWCHANGE_RUNTIME
    /* pam_gnome_keyring finds the keyring daemon in the runtime directory.
     * A signed-in person's daemon listens in theirs (keyring/control, the
     * systemd user socket) and holds the keyring open: it re-encrypts it.
     * Signed out there is none, and without a directory the module does
     * nothing at all -- so make a private one and run a daemon there for
     * the change. */
    snprintf( runtime, sizeof(runtime), "%s/%u", runroot, (unsigned)pw->pw_uid );
    snprintf( line, sizeof(line), "%s/keyring/control", runtime );
    if (lstat( line, &st ) || !S_ISSOCK( st.st_mode ) || st.st_uid != pw->pw_uid)
    {
        char tmpl[] = "/tmp/sg-keyring-XXXXXX";
        if (mkdtemp( tmpl ))
        {
            if (geteuid() != 0 || !chown( tmpl, pw->pw_uid, pw->pw_gid ))
            {
                snprintf( made, sizeof(made), "%s", tmpl );
                snprintf( runtime, sizeof(runtime), "%s", tmpl );
                daemon = start_daemon( pw, runtime );
            }
            else rmdir( tmpl );
        }
    }
    if (rc == PAM_SUCCESS)
    {
        snprintf( line, sizeof(line), "XDG_RUNTIME_DIR=%s", runtime );
        rc = pam_putenv( ph, line );
    }
#else
    (void)runtime; (void)line; (void)st; (void)remove_runtime; (void)start_daemon;
#endif
    if (rc == PAM_SUCCESS) rc = pam_chauthtok( ph, 0 );
    wipe();

    if (rc == PAM_SUCCESS) reply( "OK" );
    else if (g_secret_prompts <= 1 && (rc == PAM_AUTH_ERR || rc == PAM_AUTHTOK_ERR || rc == PAM_AUTHTOK_RECOVERY_ERR
                                       || rc == PAM_PERM_DENIED))
        reply( "FAIL current" );   /* refused at the first question: the current password */
    else
    {
        char out[400];
        snprintf( out, sizeof(out), "FAIL %s", g_msg[0] ? g_msg : pam_strerror( ph, rc ) );
        reply( out );
    }
    if (ph) pam_end( ph, rc );
    if (daemon > 0) { kill( daemon, SIGTERM ); waitpid( daemon, NULL, 0 ); }
    if (made[0]) remove_runtime( made, pw );
    return rc == PAM_SUCCESS ? 0 : 1;
}
