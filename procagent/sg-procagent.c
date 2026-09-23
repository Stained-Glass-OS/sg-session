/* sg-procagent -- per-user process-operations agent for the shared wineserver.
 *
 * Stained Glass OS, ADR 0014 (multi-user debt D16/D19). The machine-level
 * wineserver runs as the SYSTEM account, so the kernel refuses it
 * ptrace/tgkill on an ordinary user's processes. This agent runs as the
 * session user and performs those operations on that user's own processes --
 * where the kernel allows it because the uid matches. It gains no privilege:
 * the kernel still refuses it any process outside its own uid, exactly as it
 * would refuse the user. The wineserver connects to the socket this binds and
 * delegates read/write-process-memory and thread signals; the agent replies.
 *
 * The wire protocol must match server/ptrace.c in wine-sg.
 *
 * Copyright (C) 2026 Stained Glass OS contributors
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ptrace.h>
#include <sched.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <sys/wait.h>

enum { SG_PROC_READ = 1, SG_PROC_WRITE, SG_PROC_SIGNAL, SG_PROC_GETDR, SG_PROC_SETDR, SG_PROC_SETAFF };

struct sg_proc_req {
    int32_t  op;
    int32_t  sig;
    uint32_t pid;
    uint32_t tid;
    uint64_t addr;
    uint32_t len;
};
struct sg_proc_reply {
    int32_t  status;
    uint32_t len;
};

static const char *sockpath;

static void cleanup(int sig) { if (sockpath) unlink(sockpath); _exit(sig ? 128 + sig : 0); }

static int io_all(int fd, void *buf, size_t len, int writing)
{
    char *p = buf;
    while (len) {
        ssize_t r = writing ? write(fd, p, len) : read(fd, p, len);
        if (r > 0) { p += r; len -= (size_t)r; continue; }
        if (r == 0) return 0;
        if (errno == EINTR) continue;
        return 0;
    }
    return 1;
}

/* stop the target with ptrace so /proc/pid/mem is coherent; returns 1 if attached */
static int attach(pid_t pid)
{
    int st;
    if (ptrace(PTRACE_ATTACH, pid, 0, 0) == -1) return 0;
    while (waitpid(pid, &st, __WALL) == -1 && errno == EINTR) {}
    return 1;
}
static void detach(pid_t pid) { ptrace(PTRACE_DETACH, pid, 0, 0); }

/* read/write the target's memory via /proc/pid/mem while ptrace-stopped */
static int do_mem(uint32_t pid, uint64_t addr, uint32_t len, void *buf, int writing)
{
    char path[64];
    int fd, ok = 0;
    if (!attach((pid_t)pid)) return 0;
    snprintf(path, sizeof(path), "/proc/%u/mem", pid);
    if ((fd = open(path, writing ? O_WRONLY : O_RDONLY)) != -1) {
        ssize_t r = writing ? pwrite(fd, buf, len, (off_t)addr)
                            : pread(fd, buf, len, (off_t)addr);
        ok = (r == (ssize_t)len);
        close(fd);
    }
    detach((pid_t)pid);
    return ok;
}

static int do_signal(uint32_t pid, uint32_t tid, int sig)
{
    if (tid && syscall(SYS_tgkill, (pid_t)pid, (pid_t)tid, sig) == 0) return 1;
    return kill((pid_t)pid, sig) == 0;
}

static void serve(int conn)
{
    struct sg_proc_req req;

    while (io_all(conn, &req, sizeof(req), 0)) {
        struct sg_proc_reply rep = { 0, 0 };
        char *payload = NULL;

        if (req.len > 64 * 1024 * 1024) return;            /* sanity bound */

        if (req.op == SG_PROC_READ) {
            if (req.len && (payload = malloc(req.len)) &&
                do_mem(req.pid, req.addr, req.len, payload, 0)) {
                rep.status = 1;
                rep.len = req.len;
            }
        } else if (req.op == SG_PROC_WRITE) {
            /* the write payload always follows the request; it must be drained
             * even on failure or the stream desyncs */
            if (!req.len || !(payload = malloc(req.len)) || !io_all(conn, payload, req.len, 0)) {
                free(payload);
                return;
            }
            rep.status = do_mem(req.pid, req.addr, req.len, payload, 1);
            free(payload);
            payload = NULL;
        } else if (req.op == SG_PROC_SIGNAL) {
            rep.status = do_signal(req.pid, req.tid, req.sig);
        } else if (req.op == SG_PROC_SETAFF) {
            cpu_set_t set;
            int i;
            CPU_ZERO(&set);
            for (i = 0; i < 64 && i < CPU_SETSIZE; i++)
                if (req.addr & ((uint64_t)1 << i)) CPU_SET(i, &set);
            rep.status = (sched_setaffinity((pid_t)req.tid, sizeof(set), &set) == 0);
        }

        if (!io_all(conn, &rep, sizeof(rep), 1) ||
            (rep.len && !io_all(conn, payload, rep.len, 1))) {
            free(payload);
            return;
        }
        free(payload);
    }
}

int main(int argc, char **argv)
{
    const char *prefix = getenv("WINEPREFIX");
    char path[108];
    struct sockaddr_un addr;
    int lfd, n;

    if (argc > 1) prefix = argv[1];
    if (!prefix || prefix[0] != '/') { fprintf(stderr, "sg-procagent: need WINEPREFIX\n"); return 2; }

    n = snprintf(path, sizeof(path), "%s/.sg-procagent.%u", prefix, (unsigned)getuid());
    if (n < 0 || n >= (int)sizeof(path)) { fprintf(stderr, "sg-procagent: path too long\n"); return 2; }

    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if ((size_t)n >= sizeof(addr.sun_path)) { fprintf(stderr, "sg-procagent: path too long\n"); return 2; }
    strcpy(addr.sun_path, path);

    unlink(path);
    if ((lfd = socket(AF_UNIX, SOCK_STREAM, 0)) == -1) { perror("socket"); return 1; }
    if (bind(lfd, (struct sockaddr *)&addr, sizeof(addr)) == -1) { perror("bind"); return 1; }
    sockpath = path;
    /* the server runs as another user (SYSTEM) but shares the prefix group, so
     * the socket is reachable by that group and no wider */
    chmod(path, 0660);
    signal(SIGTERM, cleanup);
    signal(SIGINT, cleanup);
    signal(SIGHUP, cleanup);
    signal(SIGPIPE, SIG_IGN);
    if (listen(lfd, 8) == -1) { perror("listen"); cleanup(0); }

    for (;;) {
        int conn = accept(lfd, NULL, NULL);
        if (conn == -1) { if (errno == EINTR) continue; break; }
        serve(conn);
        close(conn);
    }
    cleanup(0);
    return 0;
}
