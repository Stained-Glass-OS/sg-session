/* A stand-in for greetd, so the bridge's protocol can be tested for real.
 *
 * The bridge sits in an authentication path, and the interesting failures are
 * in the wire format -- a length prefix in the wrong endianness, a password
 * that ends the JSON string early, a reply read in the wrong order. None of
 * those show up in a test that mocks at a higher level, and all of them are
 * caught by speaking the actual protocol back.
 *
 * It accepts one password, PASS, and rejects everything else. It is a test
 * fixture: it never touches PAM and must never be installed.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static int rd( int fd, void *b, size_t n )
{
    char *p = b;
    while (n) { ssize_t k = read( fd, p, n ); if (k <= 0) return -1; p += k; n -= (size_t)k; }
    return 0;
}
static int wr( int fd, const void *b, size_t n )
{
    const char *p = b;
    while (n) { ssize_t k = write( fd, p, n ); if (k <= 0) return -1; p += k; n -= (size_t)k; }
    return 0;
}
static int sendmsg_json( int fd, const char *json )
{
    uint32_t len = (uint32_t)strlen( json );
    if (wr( fd, &len, sizeof(len) ) < 0) return -1;
    return wr( fd, json, len );
}
static char *recvmsg_json( int fd )
{
    uint32_t len; char *b;
    if (rd( fd, &len, sizeof(len) ) < 0) return NULL;
    if (len > (1u << 20) || !(b = malloc( len + 1 ))) return NULL;
    if (rd( fd, b, len ) < 0) { free( b ); return NULL; }
    b[len] = 0;
    return b;
}

int main( int argc, char **argv )
{
    const char *path = (argc > 1) ? argv[1] : NULL;
    const char *want = (argc > 2) ? argv[2] : "PASS";
    struct sockaddr_un addr;
    int srv, fd;
    char *m;
    int asked = 0;

    if (!path) { fprintf( stderr, "usage: greetd-stub <socket> [password]\n" ); return 2; }
    unlink( path );
    if ((srv = socket( AF_UNIX, SOCK_STREAM, 0 )) < 0) return 1;
    memset( &addr, 0, sizeof(addr) );
    addr.sun_family = AF_UNIX;
    snprintf( addr.sun_path, sizeof(addr.sun_path), "%s", path );
    if (bind( srv, (struct sockaddr *)&addr, sizeof(addr) ) < 0) { perror( "bind" ); return 1; }
    if (listen( srv, 1 ) < 0) { perror( "listen" ); return 1; }
    fprintf( stderr, "stub: listening on %s\n", path );

    if ((fd = accept( srv, NULL, NULL )) < 0) return 1;

    while ((m = recvmsg_json( fd )))
    {
        if (strstr( m, "\"create_session\"" ))
        {
            fprintf( stderr, "stub: create_session %s\n", m );
            sendmsg_json( fd, "{\"type\":\"auth_message\",\"auth_message_type\":\"secret\","
                              "\"auth_message\":\"Password:\"}" );
            asked = 1;
        }
        else if (strstr( m, "\"post_auth_message_response\"" ))
        {
            char pat[256];
            snprintf( pat, sizeof(pat), "\"response\":\"%s\"", want );
            if (asked && strstr( m, pat ))
            {
                fprintf( stderr, "stub: correct password\n" );
                sendmsg_json( fd, "{\"type\":\"success\"}" );
            }
            else
            {
                fprintf( stderr, "stub: wrong password\n" );
                sendmsg_json( fd, "{\"type\":\"error\",\"error_type\":\"auth_error\","
                                  "\"description\":\"authentication failed\"}" );
            }
        }
        else if (strstr( m, "\"start_session\"" ))
        {
            fprintf( stderr, "stub: start_session %s\n", m );
            sendmsg_json( fd, "{\"type\":\"success\"}" );
            printf( "STARTED %s\n", m );
            fflush( stdout );
            free( m );
            break;
        }
        else if (strstr( m, "\"cancel_session\"" ))
        {
            sendmsg_json( fd, "{\"type\":\"success\"}" );
        }
        free( m );
    }
    close( fd );
    close( srv );
    unlink( path );
    return 0;
}
