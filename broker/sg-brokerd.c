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
#include <fcntl.h>
#include <grp.h>
#include <poll.h>
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

/* ---- the Security log ---------------------------------------------------- */
/* Elevation is privilege use: each decision goes to the Windows Security log
 * through the audit spool, a directory only root and the SYSTEM account (which
 * this process runs as) may write; the Event Log service imports it (wine-sg
 * 0187; the format is in sg-audit). */
static void audit(unsigned id, int success, unsigned category, const char *const *strings, int n)
{
    const char *dir = getenv("SG_AUDIT_SPOOL");
    char tmp[512], path[512];
    struct timespec ts;
    FILE *f;
    int i, fd;

    if (!dir) dir = "/var/lib/stained-glass-audit";
    clock_gettime(CLOCK_REALTIME, &ts);
    snprintf(tmp, sizeof(tmp), "%s/.%lld%09ld-%d.tmp", dir, (long long)ts.tv_sec, ts.tv_nsec, (int)getpid());
    snprintf(path, sizeof(path), "%s/%lld%09ld-%d.evt", dir, (long long)ts.tv_sec, ts.tv_nsec, (int)getpid());
    if ((fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600)) < 0 || !(f = fdopen(fd, "w"))) {
        if (fd >= 0) close(fd);
        logmsg("audit: cannot write to %s: %s", dir, strerror(errno));
        return;
    }
    fprintf(f, "ID %u\nTYPE %s\nCATEGORY %u\nTIME %lld\n", id, success ? "success" : "failure", category,
            (long long)ts.tv_sec);
    for (i = 0; i < n; i++) {
        const char *c;
        fputs("STRING ", f);
        for (c = strings[i] ? strings[i] : ""; *c; c++) fputc(*c == '\n' || *c == '\r' ? ' ' : *c, f);
        fputc('\n', f);
    }
    if (fclose(f) != 0 || rename(tmp, path) != 0) {
        logmsg("audit: cannot write %s: %s", path, strerror(errno));
        unlink(tmp);
    }
}

/* the computer's name, as Windows' local account domain */
static const char *computer_name(void)
{
    static char name[64];
    char *dot;
    int i;
    if (name[0]) return name;
    if (gethostname(name, sizeof(name) - 1) != 0) strcpy(name, "localhost");
    if ((dot = strchr(name, '.'))) *dot = 0;
    for (i = 0; name[i]; i++) if (name[i] >= 'a' && name[i] <= 'z') name[i] -= 32;
    return name;
}

#define ADMIN_PRIVILEGES "SeSecurityPrivilege, SeBackupPrivilege, SeRestorePrivilege, SeTakeOwnershipPrivilege, " \
                         "SeDebugPrivilege, SeSystemEnvironmentPrivilege, SeLoadDriverPrivilege, SeImpersonatePrivilege"
#define BROKER_PROCESS "sg-brokerd (Run as administrator)"

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
 * Consent runs on the compositor's secure surface -- the same isolation the
 * lock screen uses (ADR 0009): the compositor's SECURE mode shows and sends
 * input to privileged clients only, so nothing in the requester's session can
 * see the prompt, click it or type into it. The prompt is sg-consent.exe on its
 * own X server on the privileged socket, started by SG_CONSENT_UI
 * (lib/sg-consent-ui). An administrator gets Yes/No; anyone else must give an
 * administrator's name and password, which the monitor checks against PAM.
 *
 * Everything fails closed: no compositor, a compositor not run by the
 * requester, a locked machine, a UI that dies or says nothing in time -- all
 * deny. SG_BROKER_TEST substitutes a scripted decision so the trust logic can
 * be gated headlessly (sg-elevate-check).
 *
 * Returns 1 to allow, 0 to deny. Fills who[] with the human who authorised.
 */
static const char *g_seat_dir = "/run/stained-glass-seat/seat0";
static const char *g_consent_ui = "/usr/lib/stained-glass/sg-consent-ui";

struct surface { char control[256], priv[256]; };

static int surface_connect(const struct surface *sf)
{
    struct sockaddr_un addr;
    int fd;
    memset(&addr, 0, sizeof(addr)); addr.sun_family = AF_UNIX;
    if ((size_t)snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", sf->control) >= sizeof(addr.sun_path)) return -1;
    if ((fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0)) < 0) return -1;
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { close(fd); return -1; }
    return fd;
}

static int surface_command(const struct surface *sf, const char *cmd, char *reply, size_t max)
{
    int fd = surface_connect(sf);
    ssize_t n;
    if (fd < 0) return -1;
    write_full(fd, cmd, strlen(cmd));
    n = read(fd, reply, max - 1);
    close(fd);
    if (n <= 0) return -1;
    reply[n] = 0;
    reply[strcspn(reply, "\r\n")] = 0;
    return 0;
}

/* The requester's own compositor: <seat>/<uid>/control.sock, served -- by
 * SO_PEERCRED -- by the requester's uid. Anyone in sgwine can make a directory
 * in the seat dir, so the path alone proves nothing. The gate names the
 * sockets directly (SG_BROKER_CONTROL/SG_BROKER_PRIV); the peer check holds
 * either way. */
static int find_surface(uid_t uid, struct surface *sf)
{
    const char *c = getenv("SG_BROKER_CONTROL"), *pv = getenv("SG_BROKER_PRIV");
    struct ucred cred; socklen_t clen = sizeof(cred);
    int fd, ok;

    if (c && pv) {
        snprintf(sf->control, sizeof(sf->control), "%s", c);
        snprintf(sf->priv, sizeof(sf->priv), "%s", pv);
        fd = surface_connect(sf);
    } else {
        /* The console seat, then the user's Remote Desktop seat
         * (<seat root>/rdp-<uid>, made by sg-rdp-authd's monitor). */
        char root[200], seats[2][260];
        const char *slash = strrchr(g_seat_dir, '/');
        int i;
        snprintf(root, sizeof(root), "%.*s", slash ? (int)(slash - g_seat_dir) : 1, slash ? g_seat_dir : ".");
        snprintf(seats[0], sizeof(seats[0]), "%s", g_seat_dir);
        snprintf(seats[1], sizeof(seats[1]), "%s/rdp-%u", root, (unsigned)uid);
        for (fd = -1, i = 0; i < 2 && fd < 0; i++) {
            if ((size_t)snprintf(sf->control, sizeof(sf->control), "%s/%u/control.sock", seats[i], (unsigned)uid) >= sizeof(sf->control) ||
                (size_t)snprintf(sf->priv, sizeof(sf->priv), "%s/%u/priv.sock", seats[i], (unsigned)uid) >= sizeof(sf->priv))
                return 0;
            fd = surface_connect(sf);
        }
    }
    if (fd < 0) { logmsg("consent: no compositor for uid %u", (unsigned)uid); return 0; }
    ok = !getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &clen) && cred.uid == uid;
    {
        /* a well-behaved client: ask something, read the answer, then hang up */
        char r[64];
        if (write_full(fd, "STATUS\n", 7) || read(fd, r, sizeof(r)) <= 0) ok = 0;
    }
    close(fd);
    if (!ok) logmsg("consent: %s is not the requester's compositor", sf->control);
    return ok;
}

/* What the prompt shows as the program. The requester chose every byte of it,
 * so it is shown, never trusted: control characters and quotes are replaced,
 * and it is cut short rather than allowed to push the real text off the panel. */
static void describe_program(char **argv, char *out, size_t max)
{
    size_t n = 0;
    int i = (!strcmp(argv[0], "wine") && argv[1]) ? 1 : 0;
    out[0] = 0;
    for (; argv[i] && n + 1 < max; i++) {
        const char *p;
        if (n && n + 1 < max) out[n++] = ' ';
        for (p = argv[i]; *p && n + 1 < max; p++)
            out[n++] = ((unsigned char)*p < 0x20 || *p == 0x7f || *p == '"') ? '?' : *p;
    }
    out[n] = 0;
    if (n > 200) strcpy(out + 197, "...");
}

struct consent_ui { pid_t pid; int to, from; };

static int consent_ui_start(struct consent_ui *ui, const struct surface *sf, const char *mode,
                            const char *requester, const char *program)
{
    int up[2], down[2];
    if (pipe2(up, O_CLOEXEC) < 0) return -1;
    if (pipe2(down, O_CLOEXEC) < 0) { close(up[0]); close(up[1]); return -1; }
    if ((ui->pid = fork()) < 0) return -1;
    if (!ui->pid) {
        dup2(down[0], 0); dup2(up[1], 1);
        setsid();   /* its own process group, so teardown takes Xwayland too */
        signal(SIGCHLD, SIG_DFL);
        setenv("SG_LOCK_PRIV", sf->priv, 1);
        /* Arguments go as positional parameters, never into the command text:
         * the program name is the requester's. */
        {
            char cmd[1024];
            snprintf(cmd, sizeof(cmd), "exec %s \"$@\"", g_consent_ui);
            execl("/bin/sh", "sh", "-c", cmd, "sg-consent-ui", mode, requester, program, (char *)NULL);
        }
        _exit(127);
    }
    close(up[1]); close(down[0]);
    ui->from = up[0];
    ui->to = down[1];
    return 0;
}

static void consent_ui_stop(struct consent_ui *ui)
{
    int i;
    if (ui->pid <= 0) return;
    write_full(ui->to, "DONE\n", 5);
    close(ui->to); close(ui->from);
    /* SIGCHLD is ignored, so children reap themselves: kill(pid, 0) failing
     * means it has gone. */
    for (i = 0; i < 20 && kill(ui->pid, 0) == 0; i++) usleep(100000);
    kill(-ui->pid, SIGTERM);
    usleep(200000);
    kill(-ui->pid, SIGKILL);
    ui->pid = 0;
}

/* One line from the UI, waiting no later than deadline. -1 on EOF/timeout. */
static int consent_read_line(int fd, char *buf, size_t max, time_t deadline)
{
    size_t i = 0;
    while (i < max - 1) {
        struct pollfd pfd = { fd, POLLIN, 0 };
        time_t left = deadline - time(NULL);
        char c; ssize_t n;
        if (left <= 0) return -1;
        if (poll(&pfd, 1, (int)(left * 1000)) <= 0) { if (errno == EINTR) continue; return -1; }
        n = read(fd, &c, 1);
        if (n <= 0) { if (n < 0 && errno == EINTR) continue; return -1; }
        if (c == '\n') break;
        if (c != '\r') buf[i++] = c;
    }
    buf[i] = 0;
    return 0;
}

static int obtain_consent(int requester_admin, const char *requester, uid_t uid, char **argv,
                          char *who, size_t wholen, struct surface *used)
{
    const char *test = getenv("SG_BROKER_TEST");
    const char *env;
    struct surface sf;
    struct consent_ui ui = { 0, -1, -1 };
    char reply[64], program[256], line[1024];
    int timeout = 120, attempts = 0, allowed = 0;
    time_t deadline;

    if (test) {
        if (requester_admin) {
            const char *d = getenv("SG_BROKER_TEST_CONSENT");
            snprintf(who, wholen, "%s", requester);
            return d && (!strcmp(d, "yes") || !strcmp(d, "y"));
        } else {
            const char *u = getenv("SG_BROKER_TEST_ADMIN_USER");
            const char *p = getenv("SG_BROKER_TEST_ADMIN_PASS");
            if (!u || !p) return 0;
            if (!is_admin_name(u) || !check_password(u, p)) {
                const char *st[6] = { u, computer_name(), "2 (Interactive)", "Unknown user name or bad password.",
                                      BROKER_PROCESS, "-" };
                logmsg("credential prompt: %s refused", u);
                audit(4625, 0, 12544, st, 6);
                return 0;
            }
            snprintf(who, wholen, "%s", u);
            return 1;
        }
    }

    if ((env = getenv("SG_CONSENT_TIMEOUT")) && atoi(env) > 0) timeout = atoi(env);
    if (!find_surface(uid, &sf)) { logmsg("consent: no secure surface for %s; refusing", requester); return 0; }
    *used = sf;   /* the elevated program's display goes to the same compositor */
    if (surface_command(&sf, "SECURE\n", reply, sizeof(reply)) || strcmp(reply, "OK secure")) {
        logmsg("consent: the compositor refused SECURE (%s); refusing", reply);
        return 0;
    }
    describe_program(argv, program, sizeof(program));
    if (consent_ui_start(&ui, &sf, requester_admin ? "admin" : "cred", requester, program) < 0) {
        logmsg("consent: cannot start the prompt; refusing");
        goto out;
    }

    deadline = time(NULL) + timeout;
    while (consent_read_line(ui.from, line, sizeof(line), deadline) == 0) {
        if (requester_admin && !strcmp(line, "ALLOW")) {
            snprintf(who, wholen, "%s", requester);
            allowed = 1;
            break;
        }
        if (!requester_admin && !strncmp(line, "CRED ", 5)) {
            char *user = line + 5, *pass = strchr(user, '\t');
            int ok = 0;
            if (pass && (size_t)(pass - user) < wholen) {
                *pass++ = 0;
                /* Both checks, whatever the first says: a quick "not an
                 * administrator" would tell a guesser which names to try. */
                ok = check_password(user, pass);
                ok = is_admin_name(user) && ok;
            }
            if (ok) memcpy(who, user, strlen(user) + 1);   /* fits: checked above */
            else {
                /* 4625: the typed account failed to log on (the password never leaves) */
                const char *st[6] = { pass ? user : "", computer_name(), "2 (Interactive)",
                                      "Unknown user name or bad password.", BROKER_PROCESS, "-" };
                audit(4625, 0, 12544, st, 6);
            }
            explicit_bzero(line, sizeof(line));
            if (ok) {
                allowed = 1;
                break;
            }
            logmsg("consent: credentials refused for %s (attempt %d)", requester, attempts + 1);
            if (++attempts >= 3) break;
            {
                static const char msg[] = "FAILURE The user name or password is incorrect.\n";
                write_full(ui.to, msg, sizeof(msg) - 1);
            }
            continue;
        }
        if (!strcmp(line, "DENY")) { logmsg("consent: declined"); break; }
        /* Anything else is a protocol violation: stop. */
        explicit_bzero(line, sizeof(line));
        logmsg("consent: unexpected reply from the prompt; refusing");
        break;
    }
    if (!allowed && time(NULL) >= deadline) logmsg("consent: no answer in %ds; refusing", timeout);
    explicit_bzero(line, sizeof(line));

out:
    consent_ui_stop(&ui);
    if (surface_command(&sf, "RELEASE\n", reply, sizeof(reply)))
        logmsg("consent: RELEASE failed; the compositor keeps its state");
    return allowed;
}

/* ---- launching the elevated program as SYSTEM --------------------------
 * On a display of its own (ADR 0012, B56): sg-elevated-run starts an X server
 * as this account, hands it to the requester's compositor -- the one the
 * consent prompt was shown on -- and runs the program there. Never on the
 * session's display: any program in the session could type into it or read
 * it there. Without a compositor (the headless trust gate, SG_BROKER_TEST)
 * the program runs with no display at all. */
static const char *g_elevated_run = "/usr/libexec/stained-glass/sg-elevated-run";

static void launch(char **argv, char **envp, const char *cwd, const char *system_user,
                   const struct surface *sf, uid_t requester_uid)
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
    /* Fixed, never the requester's: root-owned directories only, Wine's included
     * (an elevated Windows program is started as "wine ...": B56 VM gate, exit 127). */
    setenv("PATH", "/opt/wine-sg/bin:/usr/local/bin:/usr/bin:/bin", 1);
    setenv("SG_IN_BROKER", "1", 1);   /* the elevated program must not re-broker */
    /* Only a fixed set of environment variables from the requester are honoured.
     * The requester is not trusted: a hostile client could otherwise send
     * LD_PRELOAD, PATH or WINEDLLOVERRIDES and run its own code as the SYSTEM
     * account. Everything else is dropped. */
    /* Not the requester's DISPLAY, WAYLAND_DISPLAY, XAUTHORITY or runtime
     * directory: those are the session's, which an elevated program must not
     * use (and cannot: they are the requester's). */
    for (; *envp; envp++) {
        static const char *ok[] = { "WINEPREFIX=", NULL };
        int i;
        for (i = 0; ok[i]; i++)
            if (!strncmp(*envp, ok[i], strlen(ok[i]))) { putenv(*envp); break; }
    }
    if (cwd && cwd[0] && chdir(cwd) != 0) { if (chdir("/") != 0) {} }
    if (sf && sf->control[0]) {
        char uidbuf[16], *xargv[260];
        int i, n = 0;
        snprintf(uidbuf, sizeof(uidbuf), "%u", (unsigned)requester_uid);
        xargv[n++] = (char *)g_elevated_run;
        xargv[n++] = "--control"; xargv[n++] = (char *)sf->control;
        xargv[n++] = "--uid"; xargv[n++] = uidbuf;
        xargv[n++] = "--";
        for (i = 0; argv[i] && n < 259; i++) xargv[n++] = argv[i];
        xargv[n] = NULL;
        execv(g_elevated_run, xargv);
        _exit(127);
    }
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
    if ((env = getenv("SG_SEAT_DIR"))) g_seat_dir = env;
    if ((env = getenv("SG_CONSENT_UI"))) g_consent_ui = env;
    if ((env = getenv("SG_ELEVATED_RUN"))) g_elevated_run = env;
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

        struct surface used;
        memset(&used, 0, sizeof(used));
        if (obtain_consent(admin, rpw->pw_name, cred.uid, argv, who, sizeof(who), &used)) {
            const char *by = who[0] ? who : rpw->pw_name;
            if (strcmp(by, rpw->pw_name)) {
                /* 4648: a standard user's program ran on an administrator's credentials */
                const char *st[5] = { rpw->pw_name, computer_name(), by, computer_name(), argv[0] };
                audit(4648, 1, 12544, st, 5);
            }
            {
                /* 4672: the elevated program has an administrator's privileges */
                const char *st[4] = { by, computer_name(), ADMIN_PRIVILEGES, argv[0] };
                audit(4672, 1, 12548, st, 4);
            }
            launch(argv, envp, cwd, g_system_user, &used, cred.uid);
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
