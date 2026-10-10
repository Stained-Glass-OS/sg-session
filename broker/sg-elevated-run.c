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
 * Usage:  sg-elevated-run --control SOCKET --uid UID [--as-uid TARGET] [--] PROGRAM [ARG...]
 *
 * --as-uid (wine-sg 1711, run as another account): started as root by the
 * broker's monitor, for a program of another account that has no session
 * display of its own. The display is the same -- an Xwayland of its own, run
 * as the SYSTEM account and handed to the requester's compositor -- and its
 * cookie is readable by the SYSTEM account and TARGET's group only; the
 * program runs as TARGET, in the environment the monitor made from TARGET's
 * account.
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
#include <pwd.h>
#include <grp.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
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

/* The requester's light or dark modes and accent colour (sg-elevate reads them
 * from the user's settings): on Windows an elevated program runs as the same
 * user and looks like the user's other programs; here it runs as the SYSTEM
 * account, so the choices are copied into that account's settings before it
 * starts. Only exact values are taken -- 0 or 1, eight hex digits -- and they
 * reach Wine through a file of this account's own, never a command line or a
 * shell. */
static int valid_bit(const char *v) { return v && (!strcmp(v, "0") || !strcmp(v, "1")); }
static int valid_hex8(const char *v)
{
    int i;
    if (!v || strlen(v) != 8) return 0;
    for (i = 0; i < 8; i++) if (!strchr("0123456789abcdefABCDEF", v[i])) return 0;
    return 1;
}

static void apply_user_look(void)
{
    const char *apps = getenv("SG_USER_APPS_LIGHT"), *sys = getenv("SG_USER_SYSTEM_LIGHT"), *accent = getenv("SG_USER_ACCENT");
    char path[] = "/tmp/sg-elevated-look-XXXXXX";
    FILE *f;
    int fd, st;
    pid_t pid;

    if ((fd = mkstemp(path)) < 0 || !(f = fdopen(fd, "w"))) { if (fd >= 0) { close(fd); unlink(path); } goto done; }
    fprintf(f, "Windows Registry Editor Version 5.00\r\n\r\n");
    /* This display has no taskbar: Wine's stand-in tray, a small untitled
     * window at the top left, appeared once the program added a notification
     * icon (Microsoft 365 setup's) -- no tray here, as on a secure desktop. */
    fprintf(f, "[HKEY_CURRENT_USER\\Software\\Wine\\Explorer]\r\n\"ShowSystray\"=dword:00000000\r\n\r\n");
    if (valid_bit(apps) || valid_bit(sys)) {
        fprintf(f, "[HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize]\r\n");
        if (valid_bit(apps)) fprintf(f, "\"AppsUseLightTheme\"=dword:0000000%s\r\n", apps);
        if (valid_bit(sys)) fprintf(f, "\"SystemUsesLightTheme\"=dword:0000000%s\r\n", sys);
        fprintf(f, "\r\n");
    }
    if (valid_hex8(accent))
        fprintf(f, "[HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\DWM]\r\n\"AccentColor\"=dword:%s\r\n\r\n", accent);
    fclose(f);
    if ((pid = fork()) == 0) {
        char unixpath[64];
        int nul = open("/dev/null", O_RDWR);
        if (nul >= 0) { dup2(nul, 1); dup2(nul, 2); }
        snprintf(unixpath, sizeof(unixpath), "Z:%s", path);
        execlp("wine", "wine", "reg", "import", unixpath, (char *)NULL);
        _exit(127);
    }
    if (pid > 0) waitpid(pid, &st, 0);
    unlink(path);
done:
    unsetenv("SG_USER_APPS_LIGHT");
    unsetenv("SG_USER_SYSTEM_LIGHT");
    unsetenv("SG_USER_ACCENT");
}

/* The prefix the program runs in: the broker's environment (sg_wine_env). */
static const char *prefix_dir(void)
{
    const char *p = getenv("WINEPREFIX");
    return p && *p ? p : "/var/lib/stained-glass/prefix";
}

/* A Windows path (C:\Program Files\x.exe, or a bare name in system32) as
 * the file in the prefix; Windows paths are case-insensitive, so each part is
 * looked up that way. */
static int unix_path(const char *win, char *out, size_t n)
{
    char rest[4096], *part, *save = NULL;
    size_t len;

    if (strlen(win) >= sizeof(rest)) return 0;
    if (((win[0] | 0x20) >= 'a' && (win[0] | 0x20) <= 'z') && win[1] == ':') {
        snprintf(out, n, "%s/dosdevices/%c:", prefix_dir(), win[0] | 0x20);
        strcpy(rest, win + 2);
    } else if (!strchr(win, '\\') && !strchr(win, '/')) {
        snprintf(out, n, "%s/drive_c", prefix_dir());
        snprintf(rest, sizeof(rest), "windows\\system32\\%s%s", win,
                 strlen(win) > 4 && !strcasecmp(win + strlen(win) - 4, ".exe") ? "" : ".exe");
    } else return 0;
    for (part = strtok_r(rest, "\\/", &save); part; part = strtok_r(NULL, "\\/", &save)) {
        DIR *d = opendir(out);
        struct dirent *e;
        const char *found = NULL;
        if (!d) return 0;
        while ((e = readdir(d))) if (!strcasecmp(e->d_name, part)) { found = e->d_name; break; }
        len = strlen(out);
        if (found) snprintf(out + len, n - len, "/%s", found);
        closedir(d);
        if (!found) return 0;
    }
    return 1;
}

/* Whether the program is a console one (PE subsystem IMAGE_SUBSYSTEM_WINDOWS_CUI).
 * Started by `wine` with no console to inherit, it got none: an elevated
 * PowerShell or cmd ran with nowhere to show and read end-of-file at once.
 * wineconsole gives it a console window, as Windows gives a console program
 * started from the shell. */
static int is_console_program(const char *win)
{
    unsigned char hdr[0x40], pe[0x60];
    char path[4096];
    uint32_t off;
    int fd, ok = 0;

    if (!unix_path(win, path, sizeof(path))) return 0;
    if ((fd = open(path, O_RDONLY | O_CLOEXEC)) < 0) return 0;
    if (pread(fd, hdr, sizeof(hdr), 0) == sizeof(hdr) && hdr[0] == 'M' && hdr[1] == 'Z') {
        off = hdr[0x3c] | hdr[0x3d] << 8 | hdr[0x3e] << 16 | (uint32_t)hdr[0x3f] << 24;
        /* "PE\0\0", the file header (20 bytes), then the optional header,
         * whose Subsystem is at 68 in both PE32 and PE32+ */
        if (off < (1u << 20) && pread(fd, pe, sizeof(pe), off) == sizeof(pe) && !memcmp(pe, "PE\0\0", 4))
            ok = (pe[24 + 68] | pe[24 + 69] << 8) == 3;
    }
    close(fd);
    return ok;
}

int main(int argc, char **argv)
{
    const char *control = getenv("SG_ELEVATED_CONTROL"), *xwayland = getenv("SG_XWAYLAND");
    long uid_arg = -1, as_uid = -1;
    struct passwd *as_pw = NULL, *sys_pw = NULL;
    int first = 1, wl[2], wm[2], ready[2], dfd[2], status = 0, program_status = 125, display = -1;
    char dir[] = "/tmp/sg-elevated-XXXXXX", cookie[64], buf[32], desk[64], dpy[32];
    size_t got = 0;
    pid_t xpid, ppid;
    time_t deadline;

    while (first < argc) {
        if (!strcmp(argv[first], "--control") && first + 1 < argc) { control = argv[first + 1]; first += 2; }
        else if (!strcmp(argv[first], "--uid") && first + 1 < argc) { uid_arg = strtol(argv[first + 1], NULL, 10); first += 2; }
        else if (!strcmp(argv[first], "--as-uid") && first + 1 < argc) { as_uid = strtol(argv[first + 1], NULL, 10); first += 2; }
        else if (!strcmp(argv[first], "--")) { first++; break; }
        else break;
    }
    if (!control || uid_arg < 0 || first >= argc) {
        fprintf(stderr, "usage: sg-elevated-run --control SOCKET --uid UID [--] PROGRAM [ARG...]\n");
        return 125;
    }
    if (!xwayland) xwayland = "Xwayland";
    if (as_uid >= 0) {
        const char *sys = getenv("SG_SYSTEM_USER");
        /* only root starts a program as another account, and never as root,
         * the SYSTEM account or another system account */
        if (geteuid() != 0 || as_uid < 1000 || !(as_pw = getpwuid((uid_t)as_uid)) ||
            !(sys_pw = getpwnam(sys && *sys ? sys : "sgsystem")) || (uid_t)as_uid == sys_pw->pw_uid) {
            logmsg("--as-uid %ld refused", as_uid);
            return 125;
        }
    }

    /* Everything the program starts, however it detaches, stays ours to wait
     * for: the display lives as long as any of it. */
    prctl(PR_SET_CHILD_SUBREAPER, 1);
    signal(SIGPIPE, SIG_IGN);
    /* The broker ignores SIGCHLD, and an ignored disposition survives exec:
     * without this the kernel reaps our children itself and waitpid never
     * sees the program's exit status. */
    signal(SIGCHLD, SIG_DFL);

    if (!mkdtemp(dir)) { logmsg("mkdtemp: %s", strerror(errno)); return 125; }
    snprintf(cookie, sizeof(cookie), "%s/Xauthority", dir);
    if (write_cookie(cookie)) { logmsg("cannot write the display's cookie"); rmdir(dir); return 125; }
    if (as_pw && (chown(dir, sys_pw->pw_uid, as_pw->pw_gid) || chmod(dir, 0750) ||
                  chown(cookie, sys_pw->pw_uid, as_pw->pw_gid) || chmod(cookie, 0640))) {
        logmsg("cannot give the cookie to uid %ld: %s", as_uid, strerror(errno));
        rm_dir(dir, cookie); return 125;
    }

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
        /* the X server as the SYSTEM account, never root */
        if (sys_pw && (initgroups(sys_pw->pw_name, sys_pw->pw_gid) || setgid(sys_pw->pw_gid) ||
                       setuid(sys_pw->pw_uid) || setuid(0) == 0))
            _exit(127);
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
    /* ... in the requester's session (wine-sg 1706: each user has one, with
     * its own WinSta0, Local\ namespace and clipboard), where its windows,
     * tray icons and messages belong; wine-sg honours it for the SYSTEM
     * account only, and Wine's processes started from it stay there. */
    if (!as_pw) {
        char sess[24];
        snprintf(sess, sizeof(sess), "%ld", uid_arg);
        setenv("SG_SESSION_UID", sess, 1);
        apply_user_look();
    }

    {
        char **args = argv + first, sys32[4096];
        pid_t pid;

        if (!strcmp(args[0], "wine") && args[1] && is_console_program(args[1])) {
            char **c = calloc(argc - first + 2, sizeof(*c));
            int i;
            if (c) {
                c[0] = args[0];
                c[1] = "wineconsole";
                for (i = 1; args[i]; i++) c[i + 1] = args[i];
                logmsg("%s is a console program: in a console window", args[1]);
                args = c;
            }
        }
        /* An elevated program started with no directory of its own starts in
         * the system directory, as on Windows (elevated cmd opens in
         * C:\Windows\system32), not at Z:\. One started in a folder stays
         * there: Firefox's installer runs setup.exe where it unpacked it, and
         * moved to system32 it installed nothing. */
        snprintf(sys32, sizeof(sys32), "%s/drive_c/windows/system32", prefix_dir());
        pid = fork();
        if (pid < 0) { kill(xpid, SIGTERM); rm_dir(dir, cookie); return 125; }
        if (!pid) {
            signal(SIGPIPE, SIG_DFL);
            /* another account's program: as that account (the monitor made
             * its environment) */
            if (as_pw && (initgroups(as_pw->pw_name, as_pw->pw_gid) || setgid(as_pw->pw_gid) ||
                          setuid(as_pw->pw_uid) || setuid(0) == 0))
                _exit(126);
            {
                char here[16];
                if (getcwd(here, sizeof(here)) && !strcmp(here, "/") && chdir(sys32) < 0) { /* stays */ }
            }
            execvp(args[0], args);
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
