/* sg-elevate -- ask the broker to run a program as the administrator (SYSTEM).
 *
 * Stained Glass OS, ADR 0012. Runs as the ordinary session user. It connects
 * to sg-brokerd, sends the program and arguments and the Wine prefix, and
 * reports the outcome. The elevated program is shown on a display of its own,
 * which the broker sets up; nothing of the session's display is passed. It has no privilege of its own -- every decision is the broker's,
 * on the secure surface, and the program runs as SYSTEM only after consent.
 *
 * Usage:  sg-elevate [--] PROGRAM [ARG...]
 *
 * Copyright (C) 2026 Stained Glass OS contributors
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include <errno.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>

static int write_full(int fd, const void *buf, size_t len)
{
    const char *p = buf;
    while (len) { ssize_t n = write(fd, p, len); if (n <= 0) { if (n < 0 && errno == EINTR) continue; return -1; } p += n; len -= (size_t)n; }
    return 0;
}

/* append "s\0" to buf */
static size_t put(char *buf, size_t off, size_t cap, const char *s)
{
    size_t n = strlen(s) + 1;
    if (off + n > cap) return cap + 1;   /* overflow marker */
    memcpy(buf + off, s, n);
    return off + n;
}

int main(int argc, char **argv)
{
    const char *sockpath = getenv("SG_BROKER_SOCK");
    struct sockaddr_un addr;
    char blob[65536], cwd[4096];
    size_t off = 0;
    int fd, i, first = 1;
    unsigned char status = 2;

    if (!sockpath) sockpath = "/run/stained-glass-broker/broker.sock";
    int wine_mode = 0;
    first = 1;
    if (argc > first && !strcmp(argv[first], "--wine")) { wine_mode = 1; first++; }
    if (argc > first && !strcmp(argv[first], "--")) first++;
    if (argc <= first) { fprintf(stderr, "usage: sg-elevate [--wine] [--] PROGRAM [ARG...]\n"); return 2; }

    if (!getcwd(cwd, sizeof(cwd))) strcpy(cwd, "/");

    /* payload: cwd, then a few env vars as KEY=VALUE, then a NUL, then argv */
    off = put(blob, off, sizeof(blob), cwd);
    {
        /* Only the prefix: an elevated program gets a display of its own
         * (sg-elevated-run), never the session's. */
        static const char *pass[] = { "WINEPREFIX", NULL };
        for (i = 0; pass[i]; i++) {
            const char *v = getenv(pass[i]);
            if (v) { char kv[4200]; snprintf(kv, sizeof(kv), "%s=%s", pass[i], v); off = put(blob, off, sizeof(blob), kv); }
        }
    }
    off = put(blob, off, sizeof(blob), "");   /* empty string separates env from argv */
    if (wine_mode) off = put(blob, off, sizeof(blob), "wine");
    for (i = first; i < argc; i++) off = put(blob, off, sizeof(blob), argv[i]);
    if (off > sizeof(blob)) { fprintf(stderr, "sg-elevate: request too large\n"); return 2; }

    if ((fd = socket(AF_UNIX, SOCK_STREAM, 0)) < 0) { perror("socket"); return 2; }
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", sockpath);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "sg-elevate: no broker at %s: %s\n", sockpath, strerror(errno));
        return 2;
    }
    uint32_t len = (uint32_t)off;
    if (write_full(fd, &len, sizeof(len)) || write_full(fd, blob, off)) { close(fd); return 2; }

    if (read(fd, &status, 1) != 1) { fprintf(stderr, "sg-elevate: broker closed the connection\n"); close(fd); return 2; }
    close(fd);

    switch (status) {
    case 0: return 0;                                   /* launched */
    case 1: fprintf(stderr, "sg-elevate: elevation was denied\n"); return 1;
    default: fprintf(stderr, "sg-elevate: elevation failed\n"); return 2;
    }
}
