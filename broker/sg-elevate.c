/* sg-elevate -- ask the broker to run a program as the administrator (SYSTEM).
 *
 * Stained Glass OS, ADR 0012. Runs as the ordinary session user. It connects
 * to sg-brokerd, sends the program and arguments and the Wine prefix, and
 * reports the outcome. The elevated program is shown on a display of its own,
 * which the broker sets up; nothing of the session's display is passed. It has no privilege of its own -- every decision is the broker's,
 * on the secure surface, and the program runs as SYSTEM only after consent.
 *
 * Usage:  sg-elevate [--ready FILE] [--wine] [--] PROGRAM [ARG...]
 *
 * --ready FILE: the broker's answer goes into FILE as soon as it comes --
 * "0" launched, "1" declined, "2" failed -- while this waits on for the
 * program to end. Wine's ShellExecuteEx returns then, as Windows' does once
 * the elevated program has started (an installer that then connects to its
 * elevated copy -- Total Commander's -- gave up during the consent prompt).
 * Supported when /usr/share/stained-glass/sg-elevate.features says "ready".
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
#include <sys/wait.h>
#include <fcntl.h>

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

/* A REG_DWORD of the user's, through Wine's reg (this runs in the user's
 * session, with its prefix and server). */
static int reg_dword(const char *key, const char *value, unsigned long *out)
{
    int p[2], found = 0;
    pid_t pid;
    FILE *f;
    char line[512];

    if (pipe(p) < 0) return 0;
    if ((pid = fork()) == 0) {
        int nul = open("/dev/null", O_RDWR);
        dup2(p[1], 1);
        if (nul >= 0) dup2(nul, 2);
        close(p[0]); close(p[1]);
        execlp("wine", "wine", "reg", "query", key, "/v", value, (char *)NULL);
        _exit(127);
    }
    close(p[1]);
    if (pid < 0 || !(f = fdopen(p[0], "r"))) { close(p[0]); return 0; }
    while (fgets(line, sizeof(line), f)) {
        char *t = strstr(line, "REG_DWORD");
        if (t && strstr(line, value) && sscanf(t + 9, " %lx", out) == 1) found = 1;
    }
    fclose(f);
    waitpid(pid, NULL, 0);
    return found;
}

int main(int argc, char **argv)
{
    const char *sockpath = getenv("SG_BROKER_SOCK");
    struct sockaddr_un addr;
    char blob[65536], cwd[4096];
    size_t off = 0;
    int fd, i, first = 1;
    unsigned char status = 2;
    const char *debug;

    if (!sockpath) sockpath = "/run/stained-glass-broker/broker.sock";
    int wine_mode = 0;
    const char *ready = NULL;
    first = 1;
    if (argc > first + 1 && !strcmp(argv[first], "--ready")) { ready = argv[first + 1]; first += 2; }
    if (argc > first && !strcmp(argv[first], "--wine")) { wine_mode = 1; first++; }
    if (argc > first && !strcmp(argv[first], "--")) first++;
    if (argc <= first) { fprintf(stderr, "usage: sg-elevate [--wine] [--] PROGRAM [ARG...]\n"); return 2; }

    if (!getcwd(cwd, sizeof(cwd))) strcpy(cwd, "/");

    /* payload: cwd, then a few env vars as KEY=VALUE, then a NUL, then argv */
    off = put(blob, off, sizeof(blob), cwd);
    {
        /* Only the prefix and the language: an elevated program gets a
         * display of its own (sg-elevated-run), never the session's. */
        static const char *pass[] = { "WINEPREFIX", "LANG", NULL };
        for (i = 0; pass[i]; i++) {
            const char *v = getenv(pass[i]);
            if (v) { char kv[4200]; snprintf(kv, sizeof(kv), "%s=%s", pass[i], v); off = put(blob, off, sizeof(blob), kv); }
        }
    }
    /* "Run with debugging" (sg-debug-run): the elevated program logs too, into
     * this program's standard error -- the report's log -- which goes to the
     * broker with the request. Nothing is sent without WINEDEBUG. */
    if ((debug = getenv("WINEDEBUG")) && *debug) {
        char kv[600];
        snprintf(kv, sizeof(kv), "WINEDEBUG=%s", debug);
        off = put(blob, off, sizeof(blob), kv);
    } else debug = NULL;
    if (wine_mode) {
        /* The user's light or dark modes and accent colour, for the elevated
         * program to look like the user's others (sg-elevated-run). */
        static const struct { const char *key, *value, *env; int hex; } look[] = {
            { "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize", "AppsUseLightTheme", "SG_USER_APPS_LIGHT", 0 },
            { "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize", "SystemUsesLightTheme", "SG_USER_SYSTEM_LIGHT", 0 },
            { "HKCU\\Software\\Microsoft\\Windows\\DWM", "AccentColor", "SG_USER_ACCENT", 1 },
        };
        for (i = 0; i < (int)(sizeof(look) / sizeof(look[0])); i++) {
            unsigned long v;
            if (reg_dword(look[i].key, look[i].value, &v)) {
                char kv[64];
                if (look[i].hex) snprintf(kv, sizeof(kv), "%s=%08lx", look[i].env, v & 0xffffffffUL);
                else snprintf(kv, sizeof(kv), "%s=%d", look[i].env, v ? 1 : 0);
                off = put(blob, off, sizeof(blob), kv);
            }
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
    if (debug && fcntl(2, F_GETFD) >= 0) {
        /* the length, with standard error attached */
        struct iovec iov = { &len, sizeof(len) };
        union { struct cmsghdr h; char buf[CMSG_SPACE(sizeof(int))]; } c;
        struct msghdr msg;
        int err = 2;
        memset(&msg, 0, sizeof(msg)); memset(&c, 0, sizeof(c));
        msg.msg_iov = &iov; msg.msg_iovlen = 1;
        msg.msg_control = c.buf; msg.msg_controllen = sizeof(c.buf);
        CMSG_FIRSTHDR(&msg)->cmsg_level = SOL_SOCKET;
        CMSG_FIRSTHDR(&msg)->cmsg_type = SCM_RIGHTS;
        CMSG_FIRSTHDR(&msg)->cmsg_len = CMSG_LEN(sizeof(int));
        memcpy(CMSG_DATA(CMSG_FIRSTHDR(&msg)), &err, sizeof(int));
        if (sendmsg(fd, &msg, 0) != (ssize_t)sizeof(len)) { close(fd); return 2; }
        if (write_full(fd, blob, off)) { close(fd); return 2; }
    } else if (write_full(fd, &len, sizeof(len)) || write_full(fd, blob, off)) { close(fd); return 2; }

    {
        int got = read(fd, &status, 1) == 1;
        if (!got) status = 2;
        if (ready) {
            /* the answer, for the one waiting for it (ShellExecuteEx) */
            char c = (char)('0' + (status > 2 ? 2 : status));
            int rf = open(ready, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
            if (rf >= 0) { if (write(rf, &c, 1) != 1) { /* the waiter times out */ } close(rf); }
        }
        if (!got) { fprintf(stderr, "sg-elevate: broker closed the connection\n"); close(fd); return 2; }
    }
    if (status == 0) {
        /* launched: wait for it to end, and end with its code, so the
         * caller's handle to this process behaves as one to the elevated
         * program would (an installer's caller waits for the install). A
         * Unix exit status has eight bits: a Windows code above 255 keeps
         * its meaning as well as it can -- the success-with-restart codes
         * (3010, 1641) are success, the rest failure. A broker that sends no
         * code (an older one) leaves the old answer, 0. */
        uint32_t code = 0;
        size_t got = 0;
        ssize_t r;
        while (got < sizeof(code) && ((r = read(fd, (char *)&code + got, sizeof(code) - got)) > 0 || (r < 0 && errno == EINTR)))
            if (r > 0) got += (size_t)r;
        close(fd);
        if (got != sizeof(code)) return 0;
        if (code == 3010 || code == 1641) return 0;
        return code > 255 ? 255 : (int)code;
    }
    close(fd);

    switch (status) {
    case 0: return 0;                                   /* launched */
    case 1: fprintf(stderr, "sg-elevate: elevation was denied\n"); return 1;
    default: fprintf(stderr, "sg-elevate: elevation failed\n"); return 2;
    }
}
