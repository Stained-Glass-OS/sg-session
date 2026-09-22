/* Send one command (LOCK, STATUS) to the compositor's control socket.
 *
 * This is what Wine's LockWorkStation() runs (wine-sg patch 0010): Windows
 * code cannot open a Unix socket -- Wine has no AF_UNIX -- but it can start a
 * native program. The socket path comes from SG_LOCK_CONTROL, which the session
 * exports; the compositor decides from SO_PEERCRED whether to obey, so this
 * program carries no authority of its own. Exit status 0 means "OK".
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

int main( int argc, char **argv )
{
    const char *path = getenv( "SG_LOCK_CONTROL" );
    struct sockaddr_un addr = { .sun_family = AF_UNIX };
    char cmd[32], reply[64] = "";
    ssize_t n;
    int fd;

    if (argc != 2 || strlen( argv[1] ) > 16) { fprintf( stderr, "usage: sg-lockctl LOCK|STATUS\n" ); return 2; }
    if (!path || strlen( path ) >= sizeof(addr.sun_path)) { fprintf( stderr, "SG_LOCK_CONTROL not set\n" ); return 2; }
    strcpy( addr.sun_path, path );
    if ((fd = socket( AF_UNIX, SOCK_STREAM, 0 )) < 0) return 1;
    if (connect( fd, (struct sockaddr *)&addr, sizeof(addr) ) < 0) { perror( path ); return 1; }
    snprintf( cmd, sizeof(cmd), "%s\n", argv[1] );
    if (write( fd, cmd, strlen( cmd ) ) < 0) return 1;
    n = read( fd, reply, sizeof(reply) - 1 );
    close( fd );
    if (n <= 0) return 1;
    reply[n] = 0;
    fputs( reply, stdout );
    return strncmp( reply, "OK", 2 ) ? 1 : 0;
}
