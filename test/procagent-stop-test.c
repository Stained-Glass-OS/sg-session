/* procagent-stop-test: sg-procagent's memory reads must never leave the
 * process they read stopped.
 *
 * Found on qa5 (2026-10-29): Opera's browser process sat in state T (stopped)
 * with every thread in do_signal_stop -- a window that took no input, pages that
 * never loaded. The agent reads a user's process memory for the machine's
 * wineserver (ReadProcessMemory, a process's command line) under
 * PTRACE_ATTACH, which stops the thread with a SIGSTOP; it took the first stop
 * waitpid reported for that one. When another signal reached the thread first
 * (Wine signals its threads all the time), that was a signal-delivery stop:
 * PTRACE_DETACH then dropped that signal, and the attach's SIGSTOP, still
 * pending, stopped the whole process once the agent let go.
 *
 * Here: a target whose second thread signals the first every few
 * microseconds, the real agent on its own socket, and 3000 reads of a word
 * in the target. Every read must return the word, and the target must never
 * be left stopped; its signals must keep arriving.
 *
 *   procagent-stop-test AGENT
 * SPDX-License-Identifier: AGPL-3.0-or-later */
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <sys/wait.h>

struct sg_proc_req { int32_t op, sig; uint32_t pid, tid; uint64_t addr; uint32_t len; };
struct sg_proc_reply { int32_t status; uint32_t len; };

static volatile uint64_t marker = 0x5347535447505354ull;
static volatile uint64_t *counter;     /* shared: signals the target took */
static pid_t main_tid;

static void on_usr2(int sig) { (void)sig; __atomic_add_fetch(counter, 1, __ATOMIC_RELAXED); }

static void *pester(void *arg)
{
    struct timespec ts = { 0, 20000 };
    (void)arg;
    for (;;) { syscall(SYS_tgkill, getpid(), main_tid, SIGUSR2); nanosleep(&ts, NULL); }
    return NULL;
}

static char state_of(pid_t pid)
{
    char path[64], buf[512], *p;
    FILE *f;
    size_t n;
    snprintf(path, sizeof(path), "/proc/%d/stat", (int)pid);
    if (!(f = fopen(path, "r"))) return '?';
    n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = 0;
    if (!(p = strrchr(buf, ')')) || !p[1] || !p[2]) return '?';
    return p[2];
}

static int io_all(int fd, void *buf, size_t len, int writing)
{
    char *p = buf;
    while (len) {
        ssize_t r = writing ? write(fd, p, len) : read(fd, p, len);
        if (r > 0) { p += r; len -= (size_t)r; continue; }
        if (r < 0 && errno == EINTR) continue;
        return 0;
    }
    return 1;
}

int main(int argc, char **argv)
{
    char dir[] = "/var/tmp/sg-pastop.XXXXXX", sock[200];
    struct sockaddr_un addr = { .sun_family = AF_UNIX };
    pid_t target, agent;
    int fd = -1, i, n = argc > 2 ? atoi(argv[2]) : 3000, bad = 0, stopped = -1;
    uint64_t before, after;

    if (argc < 2) { fprintf(stderr, "usage: %s AGENT [N]\n", argv[0]); return 2; }
    counter = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (counter == MAP_FAILED) { perror("mmap"); return 2; }
    if (!mkdtemp(dir)) { perror("mkdtemp"); return 2; }

    if (!(target = fork())) {
        pthread_t t;
        prctl(PR_SET_PTRACER, PR_SET_PTRACER_ANY, 0, 0, 0);   /* yama scope 1: the agent is a sibling */
        main_tid = (pid_t)syscall(SYS_gettid);
        signal(SIGUSR2, on_usr2);
        pthread_create(&t, NULL, pester, NULL);
        for (;;) pause();
    }
    if (!(agent = fork())) {
        execl(argv[1], argv[1], dir, (char *)NULL);
        _exit(127);
    }
    snprintf(sock, sizeof(sock), "%s/.sg-procagent.%u", dir, (unsigned)getuid());
    strcpy(addr.sun_path, sock);
    for (i = 0; i < 100; i++) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) break;
        close(fd); fd = -1;
        usleep(50000);
    }
    if (fd < 0) { printf("FAIL  the agent did not listen\n"); bad = 1; goto out; }
    usleep(100000);

    for (i = 0; i < n && stopped < 0; i++) {
        struct sg_proc_req req = { .op = 1, .pid = (uint32_t)target, .addr = (uint64_t)(uintptr_t)&marker, .len = 8 };
        struct sg_proc_reply rep;
        uint64_t got = 0;
        if (!io_all(fd, &req, sizeof(req), 1) || !io_all(fd, &rep, sizeof(rep), 0)) { bad = 1; break; }
        if (rep.status && rep.len == 8 && !io_all(fd, &got, 8, 0)) { bad = 1; break; }
        if (!rep.status || got != marker) bad++;
        usleep(300);
        if (state_of(target) == 'T') {
            usleep(50000);
            if (state_of(target) == 'T') stopped = i + 1;
        }
    }
    before = *counter; usleep(200000); after = *counter;

    if (stopped < 0) printf("PASS  %d reads, the target never left stopped\n", i);
    else printf("FAIL  the target was left stopped (state T) after read %d\n", stopped);
    if (!bad) printf("PASS  every read returned the word\n");
    else printf("FAIL  %d reads failed or returned something else\n", bad);
    if (after > before) printf("PASS  the target still takes its signals (%llu)\n", (unsigned long long)after);
    else printf("FAIL  the target's signals stopped arriving\n");
    if (stopped >= 0 || after <= before) bad = 1;
out:
    if (fd >= 0) close(fd);
    kill(target, SIGKILL); kill(agent, SIGTERM);
    kill(target, SIGCONT);
    waitpid(target, NULL, 0); waitpid(agent, NULL, 0);
    unlink(sock); rmdir(dir);
    return bad ? 1 : 0;
}
