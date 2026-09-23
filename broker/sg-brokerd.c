/* sg-brokerd -- the elevation broker (Stained Glass OS, ADR 0012).
 *
 * "Run as administrator" on Stained Glass. An ordinary program cannot become
 * administrator by itself -- an elevated process must run as a *different*
 * Unix account, started by something trusted after consent, so the kernel
 * separates it from the session (ADR 0012, decision B+D). This daemon is that
 * trusted thing. sg-elevate (run by the user) asks it to run a program; the
 * broker decides on the secure surface and, only then, launches the program as
 * the SYSTEM account.
 *
 * Structure mirrors sg-lockd: a small root "monitor" does PAM and nothing
 * else; the main process drops to the SYSTEM account and handles requests.
 * Administrators (members of SG_ADMIN_GROUP) get a Yes/No consent; everyone
 * else must supply an administrator's credentials, which the monitor checks.
 *
 * Copyright (C) 2026 Stained Glass OS contributors
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#define _GNU_SOURCE
#include <errno.h>
#include <grp.h>
#include <pwd.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>

#define MAXFIELD 256
#define MAXBLOB  65536

static FILE *g_log;
static int   g_monitor = -1;
static const char *g_admin_group = "sg-admins";
static const char *g_system_user = "sgsystem";

static void logmsg(const char *fmt, ...)
{
    va_list ap; char ts[32]; time_t t = time(NULL); struct tm tm;
    localtime_r(&t, &tm); strftime(ts, sizeof(ts), "%Y-%m-%dT%H:%M:%S", &tm);
    fprintf(g_log, "[sg-brokerd] %s ", ts);
    va_start(ap, fmt); vfprintf(g_log, fmt, ap); va_end(ap);
    fputc('\n', g_log); fflush(g_log);
}

static int write_full(int fd, const void *buf, size_t len)
{
    const char *p = buf;
    while (len) { ssize_t n = write(fd, p, len); if (n <= 0) { if (n < 0 && errno == EINTR) continue; return -1; } p += n; len -= (size_t)n; }
    return 0;
}
static int read_full(int fd, void *buf, size_t len)
{
    char *p = buf;
    while (len) { ssize_t n = read(fd, p, len); if (n <= 0) { if (n < 0 && errno == EINTR) continue; return -1; } p += n; len -= (size_t)n; }
    return 0;
}

/* ---- root monitor: PAM only (identical contract to sg-lockd) ------------ */
static int run_pamcheck(const char *helper, const char *user, const char *pass)
{
    int in[2], out[2], status = 0; char reply[64] = ""; ssize_t n; pid_t pid;
    if (pipe(in) < 0 || pipe(out) < 0 || (pid = fork()) < 0) return 0;
    if (!pid) {
        dup2(in[0], 0); dup2(out[1], 1);
        close(in[0]); close(in[1]); close(out[0]); close(out[1]);
        execl(helper, helper, (char *)NULL); _exit(127);
    }
    close(in[0]); close(out[1]);
    write_full(in[1], user, strlen(user) + 1);
    write_full(in[1], pass, strlen(pass) + 1);
    close(in[1]);
    n = read(out[0], reply, sizeof(reply) - 1); close(out[0]);
    waitpid(pid, &status, 0);
    if (n > 0) reply[n] = 0;
    return WIFEXITED(status) && !WEXITSTATUS(status) && !strncmp(reply, "OK", 2);
}
static void monitor_loop(int fd, const char *helper)
{
    for (;;) {
        unsigned ulen, plen; char user[MAXFIELD], pass[MAXFIELD]; unsigned char ok;
        if (read_full(fd, &ulen, sizeof(ulen)) || read_full(fd, &plen, sizeof(plen))) _exit(0);
        if (ulen >= MAXFIELD || plen >= MAXFIELD) _exit(1);
        if (read_full(fd, user, ulen) || read_full(fd, pass, plen)) _exit(0);
        user[ulen] = 0; pass[plen] = 0;
        ok = (unsigned char)run_pamcheck(helper, user, pass);
        explicit_bzero(pass, sizeof(pass));
        if (!ok) sleep(2);
        if (write_full(fd, &ok, 1)) _exit(0);
    }
}
static int check_password(const char *user, const char *pass)
{
    unsigned ulen = (unsigned)strlen(user), plen = (unsigned)strlen(pass); unsigned char ok = 0;
    if (ulen >= MAXFIELD || plen >= MAXFIELD) return 0;
    if (write_full(g_monitor, &ulen, sizeof(ulen)) || write_full(g_monitor, &plen, sizeof(plen)) ||
        write_full(g_monitor, user, ulen) || write_full(g_monitor, pass, plen) || read_full(g_monitor, &ok, 1))
        return 0;
    return ok == 1;
}

/* ---- the principal model ------------------------------------------------ */
/* is this user a member of the administrators group (primary or supplementary)? */
static int is_admin_name(const char *name)
{
    struct group *gr = getgrnam(g_admin_group);
    struct passwd *pw = getpwnam(name);
    int i;
    if (!gr || !pw) return 0;
    if (pw->pw_gid == gr->gr_gid) return 1;
    for (i = 0; gr->gr_mem && gr->gr_mem[i]; i++)
        if (!strcmp(gr->gr_mem[i], name)) return 1;
    return 0;
}

static int drop_privileges(const char *account)
{
    struct passwd *pw = getpwnam(account);
    if (!pw) return -1;
    if (initgroups(pw->pw_name, pw->pw_gid) < 0 || setgid(pw->pw_gid) < 0 || setuid(pw->pw_uid) < 0) return -1;
    if (setuid(0) == 0) return -1;
    return 0;
}

/* ---- consent -----------------------------------------------------------
 * The real consent runs on the compositor's secure surface (the same isolated
 * display the lock screen uses -- ADR 0009): a Yes/No dialog for an
 * administrator, an administrator credential prompt for anyone else, exactly
 * as Windows' secure desktop does. That graphical prompt (a mode of
 * sg-greeter, driven like sg-lock-ui) is not wired yet, so without it the
 * broker denies -- fail closed. SG_BROKER_TEST substitutes a scripted decision
 * so the trust logic can be gated headlessly.
 *
 * Returns 1 to allow, 0 to deny. Fills who[] with the human who authorised.
 */
static int obtain_consent(int requester_admin, const char *requester, char *who, size_t wholen)
{
    const char *test = getenv("SG_BROKER_TEST");

    if (test) {
        if (requester_admin) {
            const char *d = getenv("SG_BROKER_TEST_CONSENT");
            snprintf(who, wholen, "%s", requester);
            return d && (!strcmp(d, "yes") || !strcmp(d, "y"));
        } else {
            const char *u = getenv("SG_BROKER_TEST_ADMIN_USER");
            const char *p = getenv("SG_BROKER_TEST_ADMIN_PASS");
            if (!u || !p) return 0;
            if (!is_admin_name(u)) { logmsg("credential prompt: %s is not an administrator", u); return 0; }
            if (!check_password(u, p)) { logmsg("credential prompt: wrong password for %s", u); return 0; }
            snprintf(who, wholen, "%s", u);
            return 1;
        }
    }

    /* TODO: engage the secure surface and run the consent UI (reuses the lock
     * mechanism). Until then, refuse rather than elevate without consent. */
    logmsg("no secure-surface consent UI available; refusing (fail-closed)");
    return 0;
}

/* ---- launching the elevated program as SYSTEM -------------------------- */
static void launch(char **argv, char **envp, const char *cwd, const char *system_user)
{
    struct passwd *pw = getpwnam(system_user);
    pid_t pid = fork();
    if (pid < 0) return;
    if (pid) return;               /* parent: fire and forget (the broker keeps serving) */

    setsid();
    /* a clean environment: only what the client passed, plus the SYSTEM
     * account's own identity */
    clearenv();
    if (pw) {
        setenv("USER", pw->pw_name, 1);
        setenv("LOGNAME", pw->pw_name, 1);
        setenv("HOME", pw->pw_dir && pw->pw_dir[0] ? pw->pw_dir : "/var/lib/stained-glass", 1);
    }
    setenv("PATH", "/usr/local/bin:/usr/bin:/bin", 1);
    setenv("SG_IN_BROKER", "1", 1);   /* the elevated program must not re-broker */
    /* Only a fixed set of environment variables from the requester are honoured.
     * The requester is not trusted: a hostile client could otherwise send
     * LD_PRELOAD, PATH or WINEDLLOVERRIDES and run its own code as the SYSTEM
     * account. Everything else is dropped. */
    for (; *envp; envp++) {
        static const char *ok[] = { "DISPLAY=", "WAYLAND_DISPLAY=", "XAUTHORITY=",
                                    "WINEPREFIX=", "XDG_RUNTIME_DIR=", NULL };
        int i;
        for (i = 0; ok[i]; i++)
            if (!strncmp(*envp, ok[i], strlen(ok[i]))) { putenv(*envp); break; }
    }
    if (cwd && cwd[0] && chdir(cwd) != 0) { if (chdir("/") != 0) {} }
    execvp(argv[0], argv);
    _exit(127);
}

int main(void)
{
    const char *sockpath = getenv("SG_BROKER_SOCK");
    const char *helper = getenv("SG_BROKER_PAMCHECK");
    const char *logpath = getenv("SG_BROKERD_LOG");
    const char *env;
    int sv[2], lfd; pid_t mon;
    struct sockaddr_un addr;

    if (!sockpath) sockpath = "/run/stained-glass-broker/broker.sock";
    if (!helper) helper = "/usr/libexec/stained-glass/sg-rdp-pamcheck";

    /* Daemonise unless asked to stay in the foreground (systemd Type=simple,
     * and the gate, set SG_BROKER_FOREGROUND). Like wineserver, the parent
     * returns at once and the session continues without a held process. */
    if (!getenv("SG_BROKER_FOREGROUND")) {
        pid_t d = fork();
        if (d < 0) return 1;
        if (d) return 0;
        setsid();
    }
    if ((env = getenv("SG_ADMIN_GROUP"))) g_admin_group = env;
    if ((env = getenv("SG_SYSTEM_USER"))) g_system_user = env;
    /* PAM policy for elevation credential prompts */
    setenv("SG_REMOTE_PAM_SERVICE", "stained-glass-elevate", 0);
    g_log = logpath ? fopen(logpath, "a") : stderr;
    if (!g_log) g_log = stderr;
    signal(SIGPIPE, SIG_IGN);
    signal(SIGCHLD, SIG_IGN);       /* reap fire-and-forget launches */

    /* the listening socket is created while still root, in a root-owned dir,
     * then opened to all (SO_PEERCRED is how we know who really connected) */
    unlink(sockpath);
    if ((lfd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0)) < 0) { logmsg("socket: %s", strerror(errno)); return 1; }
    memset(&addr, 0, sizeof(addr)); addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", sockpath);
    if (bind(lfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { logmsg("bind %s: %s", sockpath, strerror(errno)); return 1; }
    chmod(sockpath, 0666);
    if (listen(lfd, 16) < 0) { logmsg("listen: %s", strerror(errno)); return 1; }

    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv) < 0 || (mon = fork()) < 0) return 1;
    if (!mon) { close(sv[1]); close(lfd); monitor_loop(sv[0], helper); _exit(0); }
    close(sv[0]); g_monitor = sv[1];

    if (geteuid() == 0 && drop_privileges(g_system_user) < 0) { logmsg("cannot drop to %s", g_system_user); return 1; }
    logmsg("ready as %s, admins=%s, socket=%s", g_system_user, g_admin_group, sockpath);

    for (;;) {
        struct ucred cred; socklen_t clen = sizeof(cred);
        struct passwd *rpw;
        char blob[MAXBLOB]; uint32_t len;
        int conn = accept(lfd, NULL, NULL);
        unsigned char status = 2;
        char who[MAXFIELD] = "";
        char *cwd, *p, *end, *argv[256], *envp[64];
        int argc = 0, envc = 0, admin;

        if (conn < 0) { if (errno == EINTR) continue; break; }
        if (getsockopt(conn, SOL_SOCKET, SO_PEERCRED, &cred, &clen) < 0 || !(rpw = getpwuid(cred.uid))) {
            close(conn); continue;
        }
        if (read_full(conn, &len, sizeof(len)) || len == 0 || len > sizeof(blob)) { close(conn); continue; }
        if (read_full(conn, blob, len)) { close(conn); continue; }
        blob[len - 1] = 0;   /* ensure the last string is terminated */

        /* parse: cwd, env KV..., empty, argv... */
        p = blob; end = blob + len;
        cwd = p; p += strlen(p) + 1;
        while (p < end && *p) { if (envc < (int)(sizeof(envp)/sizeof(envp[0])) - 1) envp[envc++] = p; p += strlen(p) + 1; }
        if (p < end) p += 1;   /* skip the empty separator */
        while (p < end && *p) { if (argc < (int)(sizeof(argv)/sizeof(argv[0])) - 1) argv[argc++] = p; p += strlen(p) + 1; }
        envp[envc] = NULL; argv[argc] = NULL;
        if (argc == 0) { write_full(conn, &status, 1); close(conn); continue; }

        admin = is_admin_name(rpw->pw_name);
        logmsg("request from %s (%s): %s", rpw->pw_name, admin ? "administrator" : "standard user", argv[0]);

        if (obtain_consent(admin, rpw->pw_name, who, sizeof(who))) {
            launch(argv, envp, cwd, g_system_user);
            status = 0;
            logmsg("elevated for %s, authorised by %s: %s", rpw->pw_name, who[0] ? who : rpw->pw_name, argv[0]);
        } else {
            status = 1;
            logmsg("denied for %s: %s", rpw->pw_name, argv[0]);
        }
        write_full(conn, &status, 1);
        close(conn);
        if (getenv("SG_BROKER_ONCE")) break;   /* one request, for the gate */
    }
    return 0;
}
