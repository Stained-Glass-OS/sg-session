/* Send one command (LOCK, STATUS, WINDOWS, ACTIVATE, XWINDOWS, XACTIVATE, XMINIMIZE, XCLOSE, XKILL)
 * to the compositor's control socket.
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
    const char *path = getenv( "SG_LOCK_CONTROL" ), *out_path = NULL;
    char out_part[4200];
    FILE *out = stdout;
    struct sockaddr_un addr = { .sun_family = AF_UNIX };
    char cmd[48], reply[256] = "", first[3] = "";
    int got = 0;
    ssize_t n;
    int fd;

    /* a list (WINDOWS, XWINDOWS) goes to --out FILE when asked: Wine hands a
     * native program no pipe for its output, so the taskbar reads a file */
    if (argc == 4 && !strcmp( argv[2], "--out" ) && (!strcmp( argv[1], "WINDOWS" ) || !strcmp( argv[1], "XWINDOWS" )) &&
        argv[3][0] == '/' && strlen( argv[3] ) < 4096)
    {
        out_path = argv[3];
        argc = 2;
    }
    /* ACTIVATE|MINIMIZE <display> <window>: bring an elevated program's window
     * forward, or minimize it
     * (the taskbar; ADR 0012). Numbers only: nothing else reaches the socket. */
    if (argc == 4 && (!strcmp( argv[1], "ACTIVATE" ) || !strcmp( argv[1], "MINIMIZE" )) && strspn( argv[2], "0123456789" ) == strlen( argv[2] ) &&
        strspn( argv[3], "0123456789" ) == strlen( argv[3] ) && *argv[2] && *argv[3] &&
        strlen( argv[2] ) < 6 && strlen( argv[3] ) < 11)
        snprintf( cmd, sizeof(cmd), "%s %s %s\n", argv[1], argv[2], argv[3] );
    /* XACTIVATE|XMINIMIZE|XCLOSE|XKILL <window>: a Linux program's window in
     * the session (the taskbar; XKILL: Task Manager's End task on a program
     * that did not close), by its X window id; numbers only */
    else if (argc == 3 && (!strcmp( argv[1], "XACTIVATE" ) || !strcmp( argv[1], "XMINIMIZE" ) || !strcmp( argv[1], "XCLOSE" ) ||
                           !strcmp( argv[1], "XKILL" )) &&
             *argv[2] && strspn( argv[2], "0123456789" ) == strlen( argv[2] ) && strlen( argv[2] ) < 11)
        snprintf( cmd, sizeof(cmd), "%s %s\n", argv[1], argv[2] );
    else if (argc != 2 || strlen( argv[1] ) > 16) { fprintf( stderr, "usage: sg-lockctl LOCK|STATUS|WINDOWS|XWINDOWS [--out FILE] | ACTIVATE|MINIMIZE DISPLAY WINDOW | XACTIVATE|XMINIMIZE|XCLOSE|XKILL WINDOW\n" ); return 2; }
    else snprintf( cmd, sizeof(cmd), "%s\n", argv[1] );
    if (!path || strlen( path ) >= sizeof(addr.sun_path)) { fprintf( stderr, "SG_LOCK_CONTROL not set\n" ); return 2; }
    strcpy( addr.sun_path, path );
    if ((fd = socket( AF_UNIX, SOCK_STREAM, 0 )) < 0) return 1;
    if (connect( fd, (struct sockaddr *)&addr, sizeof(addr) ) < 0) { perror( path ); return 1; }
    if (write( fd, cmd, strlen( cmd ) ) < 0) return 1;
    if (out_path)
    {
        snprintf( out_part, sizeof(out_part), "%s.part", out_path );
        if (!(out = fopen( out_part, "w" ))) return 1;
    }
    /* WINDOWS answers with several lines: read until the compositor hangs up */
    for (;;)
    {
        n = read( fd, reply, sizeof(reply) - 1 );
        if (n <= 0) break;
        reply[n] = 0;
        fputs( reply, out );
        if (!got) memcpy( first, reply, 3 );
        got = 1;
    }
    close( fd );
    if (out_path)
    {
        if (fclose( out ) || !got || rename( out_part, out_path )) { unlink( out_part ); return 1; }
    }
    if (!got) return 1;
    if (argc == 2 && (!strcmp( argv[1], "WINDOWS" ) || !strcmp( argv[1], "XWINDOWS" ))) return 0;   /* a list, ending in END */
    memcpy( reply, first, 3 );
    return strncmp( reply, "OK", 2 ) ? 1 : 0;
}
