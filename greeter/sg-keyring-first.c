/* sg-keyring-first: make a person's login keyring at their first sign-in,
 * before their session's keyring daemon opens it.
 *
 * Signing in opens the keyring (gnome-keyring's Secret Service) with the
 * password: pam_gnome_keyring, in greetd's PAM file, sends it to the daemon
 * the user manager starts on its socket ($XDG_RUNTIME_DIR/keyring/control).
 * At the very first sign-in there is no login keyring yet, and the daemon
 * makes one -- but gnome-keyring (48) does not publish a keyring made through
 * that socket on D-Bus: org.freedesktop.secrets lists it and then answers
 * "Object does not exist" for it, so the first secret a program stores
 * raises a "choose a password for the new keyring" prompt instead, until the
 * daemon restarts (and then it is locked). A keyring that already exists when
 * the daemon starts is published normally.
 *
 * So, run by pam_exec in the auth stack (pam-configs/stained-glass-keyring,
 * expose_authtok: the password on stdin) after the password has been
 * accepted, for the login screen only: if the person has no login keyring,
 * start a keyring daemon of theirs, in a private runtime directory, with
 * --unlock and the password -- it makes the login keyring, encrypted with the
 * password -- and stop it again. The session's daemon then finds an existing
 * keyring and opens it.
 *
 * Environment from pam_exec: PAM_USER, PAM_SERVICE, PAM_TYPE. Always exits
 * 0: sign-in never depends on it. SG_KEYRING_FIRST_SERVICES (the gate) is a
 * space-separated list of services to act for instead of "greetd"; run
 * unprivileged (the gate) it acts only on SG_KEYRING_FIRST_HOME, a home of
 * the gate's, never on the account's own.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <ftw.h>
#include <grp.h>
#include <pwd.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MAXPW 512

static int remove_one( const char *path, const struct stat *st, int type, struct FTW *ftw )
{
    (void)st; (void)ftw;
    return type == FTW_DP ? rmdir( path ) : unlink( path );
}

static int become( const struct passwd *pw )
{
    if (geteuid() != 0) return getuid() == pw->pw_uid ? 0 : -1;
    if (setresgid( pw->pw_gid, pw->pw_gid, pw->pw_gid ) < 0 || initgroups( pw->pw_name, pw->pw_gid ) < 0
        || setresuid( pw->pw_uid, pw->pw_uid, pw->pw_uid ) < 0) return -1;
    return 0;
}

static int wanted_service( const char *service )
{
    const char *list = getenv( "SG_KEYRING_FIRST_SERVICES" );
    char buf[256], *tok, *save;
    if (!service) return 0;
    if (!list || !list[0]) list = "greetd";
    snprintf( buf, sizeof(buf), "%s", list );
    for (tok = strtok_r( buf, " ", &save ); tok; tok = strtok_r( NULL, " ", &save ))
        if (!strcmp( tok, service )) return 1;
    return 0;
}

int main( void )
{
    const char *user = getenv( "PAM_USER" ), *type = getenv( "PAM_TYPE" );
    char pwbuf[MAXPW], keyring[1024], rt[64], envhome[1100], envrt[100];
    struct passwd *pw;
    struct stat st;
    size_t n = 0;
    int in[2], i;
    pid_t pid;

    if (!user || !type || strcmp( type, "auth" ) || !wanted_service( getenv( "PAM_SERVICE" ) )) return 0;
    if (!(pw = getpwnam( user )) || !pw->pw_uid || !pw->pw_dir || pw->pw_dir[0] != '/') return 0;
    if (geteuid() != 0)
    {
        /* Unprivileged, only the gate runs it, and only on a home of its
         * own: never the account's real one. */
        const char *home = getenv( "SG_KEYRING_FIRST_HOME" );
        if (!home || home[0] != '/' || getuid() != pw->pw_uid) return 0;
        pw->pw_dir = (char *)home;
    }
    snprintf( keyring, sizeof(keyring), "%s/.local/share/keyrings/login.keyring", pw->pw_dir );
    if (!lstat( keyring, &st )) return 0;   /* not the first sign-in */

    /* the password, up to its NUL or the end */
    for (;;)
    {
        char c;
        if (read( STDIN_FILENO, &c, 1 ) != 1 || !c) break;
        if (n + 1 >= sizeof(pwbuf)) { explicit_bzero( pwbuf, sizeof(pwbuf) ); return 0; }
        pwbuf[n++] = c;
    }
    pwbuf[n] = 0;
    if (!n) return 0;   /* no password: nothing to encrypt the keyring with */

#ifndef SG_MUTANT_KEYRING_FIRST
    snprintf( rt, sizeof(rt), "/tmp/sg-keyring-XXXXXX" );
    if (!mkdtemp( rt )) { explicit_bzero( pwbuf, sizeof(pwbuf) ); return 0; }
    if (geteuid() == 0 && chown( rt, pw->pw_uid, pw->pw_gid ) < 0) { rmdir( rt ); explicit_bzero( pwbuf, sizeof(pwbuf) ); return 0; }
    if (pipe( in ) < 0) { rmdir( rt ); explicit_bzero( pwbuf, sizeof(pwbuf) ); return 0; }
    snprintf( envhome, sizeof(envhome), "HOME=%s", pw->pw_dir );
    snprintf( envrt, sizeof(envrt), "XDG_RUNTIME_DIR=%s", rt );
    if (!(pid = fork()))
    {
        char *argv[] = { (char *)"gnome-keyring-daemon", (char *)"--foreground", (char *)"--unlock",
                         (char *)"--components=secrets", NULL };
        char *envp[] = { envhome, envrt, (char *)"PATH=/usr/bin:/bin", NULL };
        int fd = open( "/dev/null", O_RDWR );
        explicit_bzero( pwbuf, sizeof(pwbuf) );
        dup2( in[0], 0 );
        if (fd >= 0) { dup2( fd, 1 ); dup2( fd, 2 ); if (fd > 2) close( fd ); }
        close( in[0] ); close( in[1] );
        if (become( pw ) < 0) _exit( 127 );
        execve( "/usr/bin/gnome-keyring-daemon", argv, envp );
        _exit( 127 );
    }
    close( in[0] );
    if (pid > 0)
    {
        signal( SIGPIPE, SIG_IGN );
        if (write( in[1], pwbuf, n ) < 0) { /* the daemon is gone: the wait below says so */ }
    }
    close( in[1] );
    explicit_bzero( pwbuf, sizeof(pwbuf) );
    if (pid > 0)
    {
        /* up to 10 s for the keyring to be written */
        for (i = 0; i < 100 && lstat( keyring, &st ); i++)
        {
            struct timespec ts = { 0, 100000000 };
            if (waitpid( pid, NULL, WNOHANG ) == pid) { pid = -1; break; }
            nanosleep( &ts, NULL );
        }
        if (pid > 0) { kill( pid, SIGTERM ); waitpid( pid, NULL, 0 ); }
    }
    /* the private directory is the person's now: removed as them */
    if (!(pid = fork())) _exit( become( pw ) < 0 ? 1 : nftw( rt, remove_one, 8, FTW_DEPTH | FTW_PHYS ) ? 1 : 0 );
    if (pid > 0) waitpid( pid, NULL, 0 );
#else
    (void)rt; (void)envhome; (void)envrt; (void)in; (void)i; (void)pid; (void)remove_one; (void)become;
    explicit_bzero( pwbuf, sizeof(pwbuf) );
#endif
    return 0;
}
