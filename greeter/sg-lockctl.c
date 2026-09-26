/* Send one command (LOCK, STATUS, WINDOWS, ACTIVATE) to the compositor's control socket.
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
    char cmd[48], reply[256] = "", first[3] = "";
    int got = 0;
    ssize_t n;
    int fd;

    /* ACTIVATE <display> <window>: bring an elevated program's window forward
     * (the taskbar; ADR 0012). Numbers only: nothing else reaches the socket. */
    if (argc == 4 && !strcmp( argv[1], "ACTIVATE" ) && strspn( argv[2], "0123456789" ) == strlen( argv[2] ) &&
        strspn( argv[3], "0123456789" ) == strlen( argv[3] ) && *argv[2] && *argv[3] &&
        strlen( argv[2] ) < 6 && strlen( argv[3] ) < 11)
        snprintf( cmd, sizeof(cmd), "ACTIVATE %s %s\n", argv[2], argv[3] );
    else if (argc != 2 || strlen( argv[1] ) > 16) { fprintf( stderr, "usage: sg-lockctl LOCK|STATUS|WINDOWS | ACTIVATE DISPLAY WINDOW\n" ); return 2; }
    else snprintf( cmd, sizeof(cmd), "%s\n", argv[1] );
    if (!path || strlen( path ) >= sizeof(addr.sun_path)) { fprintf( stderr, "SG_LOCK_CONTROL not set\n" ); return 2; }
    strcpy( addr.sun_path, path );
    if ((fd = socket( AF_UNIX, SOCK_STREAM, 0 )) < 0) return 1;
    if (connect( fd, (struct sockaddr *)&addr, sizeof(addr) ) < 0) { perror( path ); return 1; }
    if (write( fd, cmd, strlen( cmd ) ) < 0) return 1;
    /* WINDOWS answers with several lines: read until the compositor hangs up */
    for (;;)
    {
        n = read( fd, reply, sizeof(reply) - 1 );
        if (n <= 0) break;
        reply[n] = 0;
        fputs( reply, stdout );
        if (!got) memcpy( first, reply, 3 );
        got = 1;
    }
    close( fd );
    if (!got) return 1;
    if (argc == 2 && !strcmp( argv[1], "WINDOWS" )) return 0;   /* a list, ending in END */
    memcpy( reply, first, 3 );
    return strncmp( reply, "OK", 2 ) ? 1 : 0;
}
