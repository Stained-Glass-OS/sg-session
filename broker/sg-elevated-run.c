/* sg-elevated-run -- run an elevated program on a display of its own.
 *
 * Stained Glass OS, ADR 0012 (bug B56). sg-brokerd execs this, as the SYSTEM
 * account, after consent. An elevated program must not use the session's X
 * server: every program in the session could type into it (XTEST,
 * XSendEvent) or photograph it (XGetImage) -- the hole UIPI closes on
 * Windows. So it gets one of its own:
 *
 *   1. an Xwayland, run here as the SYSTEM account and admitting only
 *      clients holding a cookie that only the SYSTEM account can read;
 *   2. handed to the requester's compositor (ELEVATED on its control socket,
 *      which the compositor accepts only from the SYSTEM account or root):
 *      the compositor becomes its window manager and shows its windows in the
 *      user's desktop as ordinary windows, and the user's keyboard and pointer
 *      reach them through the compositor alone;
 *   3. the program, with DISPLAY and XAUTHORITY pointing at it, and -- for
 *      Wine -- a desktop of its own (SG_WINSTATION WinSta0\sg-elevated-N), so
 *      Wine's desktop process for it lives and dies with this display;
 *   4. the display stays while the program or anything it started runs (this
 *      process is their subreaper), then goes.
 *
 * Usage:  sg-elevated-run --control SOCKET --uid UID [--] PROGRAM [ARG...]
 *
 * SOCKET is the requester's compositor control socket, and it must be served
 * by UID (SO_PEERCRED) -- the broker found and checked it for the consent
 * prompt already; this checks again rather than trust a path.
 *
 * Exit status: the program's; 125 if the display could not be set up (the
 * program is then not run at all: an elevated program never falls back to the
 * session's display).
 *
 * Copyright (C) 2026 Stained Glass OS contributors
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/prctl.h>
#include <sys/random.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>

static void logmsg(const char *fmt, ...)
{
    va_list ap;
    fputs("sg-elevated-run: ", stderr);
    va_start(ap, fmt); vfprintf(stderr, fmt, ap); va_end(ap);
    fputc('\n', stderr);
}

static int write_full(int fd, const void *buf, size_t len)
{
    const char *p = buf;
    while (len) { ssize_t n = write(fd, p, len); if (n <= 0) { if (n < 0 && errno == EINTR) continue; return -1; } p += n; len -= (size_t)n; }
    return 0;
}

/* An Xauthority file with one FamilyWild MIT-MAGIC-COOKIE-1 entry: it matches
 * any display, so it can be written before Xwayland picks its number. */
static int write_cookie(const char *path)
{
    static const char name[] = "MIT-MAGIC-COOKIE-1";
    unsigned char cookie[16], rec[64], *p = rec;
    int fd;
    if (getrandom(cookie, sizeof(cookie), 0) != (ssize_t)sizeof(cookie)) return -1;
    *p++ = 0xff; *p++ = 0xff;                   /* FamilyWild */
    *p++ = 0; *p++ = 0;                         /* address: empty */
    *p++ = 0; *p++ = 0;                         /* display number: empty */
    *p++ = 0; *p++ = sizeof(name) - 1; memcpy(p, name, sizeof(name) - 1); p += sizeof(name) - 1;
    *p++ = 0; *p++ = sizeof(cookie); memcpy(p, cookie, sizeof(cookie)); p += sizeof(cookie);
    if ((fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600)) < 0) return -1;
    if (write_full(fd, rec, (size_t)(p - rec))) { close(fd); return -1; }
    explicit_bzero(cookie, sizeof(cookie));
    return close(fd);
}

/* ELEVATED with the compositor's three ends: the X server's Wayland
 * connection, its window manager's connection, and the readiness pipe. */
static int hand_over(const char *control, uid_t uid, int wl, int wm, int ready)
{
    struct sockaddr_un addr;
    struct ucred cred; socklen_t clen = sizeof(cred);
    char reply[64] = "";
    int fd, fds[3] = { wl, wm, ready };
    char cbuf[CMSG_SPACE(sizeof(fds))];
    struct iovec iov = { .iov_base = "ELEVATED\n", .iov_len = 9 };
    struct msghdr mh = { .msg_iov = &iov, .msg_iovlen = 1, .msg_control = cbuf, .msg_controllen = sizeof(cbuf) };
    struct cmsghdr *cm;
    ssize_t n;

    memset(&addr, 0, sizeof(addr)); addr.sun_family = AF_UNIX;
    if ((size_t)snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", control) >= sizeof(addr.sun_path)) return -1;
    if ((fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0)) < 0) return -1;
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { logmsg("no compositor at %s: %s", control, strerror(errno)); close(fd); return -1; }
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &clen) < 0 || cred.uid != uid) {
        logmsg("%s is not served by uid %u; refusing", control, (unsigned)uid);
        close(fd); return -1;
    }
    memset(cbuf, 0, sizeof(cbuf));
    cm = CMSG_FIRSTHDR(&mh);
    cm->cmsg_level = SOL_SOCKET; cm->cmsg_type = SCM_RIGHTS; cm->cmsg_len = CMSG_LEN(sizeof(fds));
    memcpy(CMSG_DATA(cm), fds, sizeof(fds));
    if (sendmsg(fd, &mh, MSG_NOSIGNAL) != 9) { close(fd); return -1; }
    n = read(fd, reply, sizeof(reply) - 1);
    close(fd);
    if (n <= 0 || strncmp(reply, "OK elevated", 11)) {
        reply[n > 0 ? n : 0] = 0;
        reply[strcspn(reply, "\r\n")] = 0;
        logmsg("the compositor refused the display (%s)", n > 0 ? reply : "no reply");
        return -1;
    }
    return 0;
}

/* Our children, as the kernel lists them (subreaper: Wine's double-forked
 * processes land here too). Returns how many are not `except`. */
static int other_children(pid_t except)
{
    char path[64], buf[4096];
    int fd, count = 0;
    ssize_t n;
    char *p, *end;
    snprintf(path, sizeof(path), "/proc/self/task/%d/children", (int)getpid());
    if ((fd = open(path, O_RDONLY | O_CLOEXEC)) < 0) return -1;
    n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n < 0) return -1;
    buf[n] = 0;
    for (p = buf; *p; p = end) {
        long pid = strtol(p, &end, 10);
        if (end == p) break;
        if (pid != except) count++;
    }
    return count;
}

static void rm_dir(const char *dir, const char *cookie)
{
    unlink(cookie);
    rmdir(dir);
}

int main(int argc, char **argv)
{
    const char *control = getenv("SG_ELEVATED_CONTROL"), *xwayland = getenv("SG_XWAYLAND");
    long uid_arg = -1;
    int first = 1, wl[2], wm[2], ready[2], dfd[2], status = 0, program_status = 125, display = -1;
    char dir[] = "/tmp/sg-elevated-XXXXXX", cookie[64], buf[32], desk[64], dpy[32];
    size_t got = 0;
    pid_t xpid, ppid;
    time_t deadline;

    while (first < argc) {
        if (!strcmp(argv[first], "--control") && first + 1 < argc) { control = argv[first + 1]; first += 2; }
        else if (!strcmp(argv[first], "--uid") && first + 1 < argc) { uid_arg = strtol(argv[first + 1], NULL, 10); first += 2; }
        else if (!strcmp(argv[first], "--")) { first++; break; }
        else break;
    }
    if (!control || uid_arg < 0 || first >= argc) {
        fprintf(stderr, "usage: sg-elevated-run --control SOCKET --uid UID [--] PROGRAM [ARG...]\n");
        return 125;
    }
    if (!xwayland) xwayland = "Xwayland";

    /* Everything the program starts, however it detaches, stays ours to wait
     * for: the display lives as long as any of it. */
    prctl(PR_SET_CHILD_SUBREAPER, 1);
    signal(SIGPIPE, SIG_IGN);

    if (!mkdtemp(dir)) { logmsg("mkdtemp: %s", strerror(errno)); return 125; }
    snprintf(cookie, sizeof(cookie), "%s/Xauthority", dir);
    if (write_cookie(cookie)) { logmsg("cannot write the display's cookie"); rmdir(dir); return 125; }

    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, wl) || socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, wm) ||
        pipe2(ready, O_CLOEXEC) || pipe2(dfd, O_CLOEXEC)) {
        logmsg("cannot make the display's connections: %s", strerror(errno));
        rm_dir(dir, cookie); return 125;
    }
    if (hand_over(control, (uid_t)uid_arg, wl[0], wm[0], ready[0])) { rm_dir(dir, cookie); return 125; }
    close(wl[0]); close(wm[0]); close(ready[0]);

    ppid = getpid();
    if ((xpid = fork()) < 0) { rm_dir(dir, cookie); return 125; }
    if (!xpid) {
        char wls[16], wms[16], dfs[16];
        prctl(PR_SET_PDEATHSIG, SIGTERM);
        if (getppid() != ppid) _exit(127);
        /* the three inherited descriptors, and nothing else of ours */
        fcntl(wl[1], F_SETFD, 0); fcntl(wm[1], F_SETFD, 0); fcntl(dfd[1], F_SETFD, 0);
        snprintf(wls, sizeof(wls), "%d", wl[1]); snprintf(wms, sizeof(wms), "%d", wm[1]); snprintf(dfs, sizeof(dfs), "%d", dfd[1]);
        setenv("WAYLAND_SOCKET", wls, 1);
        unsetenv("WAYLAND_DISPLAY"); unsetenv("DISPLAY");
        { int nul = open("/dev/null", O_RDWR); if (nul >= 0) { dup2(nul, 0); dup2(nul, 1); if (!getenv("SG_ELEVATED_XLOG")) dup2(nul, 2); } }
        execlp(xwayland, xwayland, "-rootless", "-wm", wms, "-displayfd", dfs, "-auth", cookie,
               "-nolisten", "tcp", "-noreset", (char *)NULL);
        _exit(127);
    }
    close(wl[1]); close(wm[1]); close(dfd[1]);

    /* The display number, once Xwayland is ready; then tell the compositor,
     * which may only connect its window manager after that. */
    deadline = time(NULL) + 30;
    while (got < sizeof(buf) - 1 && !memchr(buf, '\n', got)) {
        struct pollfd pfd = { dfd[0], POLLIN, 0 };
        int left = (int)(deadline - time(NULL));
        ssize_t n;
        if (left <= 0 || poll(&pfd, 1, left * 1000) <= 0) break;
        if ((n = read(dfd[0], buf + got, sizeof(buf) - 1 - got)) <= 0) break;
        got += (size_t)n;
    }
    close(dfd[0]);
    buf[got] = 0;
    if (!memchr(buf, '\n', got) || (display = atoi(buf)) < 0 || buf[0] < '0' || buf[0] > '9') {
        logmsg("Xwayland did not start");
        kill(xpid, SIGTERM); waitpid(xpid, NULL, 0);
        close(ready[1]); rm_dir(dir, cookie); return 125;
    }
    { char line[16]; int k = snprintf(line, sizeof(line), "%d\n", display); write_full(ready[1], line, (size_t)k); }
    close(ready[1]);
    logmsg("display :%d for %s", display, argv[first]);

    snprintf(dpy, sizeof(dpy), ":%d", display);
    snprintf(desk, sizeof(desk), "WinSta0\\sg-elevated-%d", display);
    setenv("DISPLAY", dpy, 1);
    setenv("XAUTHORITY", cookie, 1);
    unsetenv("WAYLAND_DISPLAY");
    /* Wine: a desktop of this display's own, so the desktop process Wine
     * starts for it runs on this display and ends with it. */
    setenv("SG_WINSTATION", desk, 1);

    {
        pid_t pid = fork();
        if (pid < 0) { kill(xpid, SIGTERM); rm_dir(dir, cookie); return 125; }
        if (!pid) {
            signal(SIGPIPE, SIG_DFL);
            execvp(argv[first], argv + first);
            _exit(127);
        }
        /* Wait for the program, then for everything it left running. */
        for (;;) {
            int others;
            pid_t w;
            while ((w = waitpid(-1, &status, WNOHANG)) > 0) {
                if (w == pid) program_status = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
                if (w == xpid) { xpid = -1; logmsg("display :%d: Xwayland ended", display); }
            }
            others = other_children(xpid);
            if (others == 0 || (others < 0 && w < 0 && errno == ECHILD)) break;
            if (xpid < 0 && others > 0) {
                /* the display is gone; what is left cannot show anything */
            }
            {
                struct timespec ts = { 0, 250 * 1000 * 1000 };
                nanosleep(&ts, NULL);
            }
        }
    }
    if (xpid > 0) {
        kill(xpid, SIGTERM);
        waitpid(xpid, NULL, 0);
    }
    rm_dir(dir, cookie);
    logmsg("display :%d closed (exit %d)", display, program_status);
    return program_status;
}
