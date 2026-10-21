#!/bin/sh
. "$(dirname "$0")/scratch-home.sh"
# The requester of an elevated program goes on when that program ends, not when
# everything it started has: sg-elevated-run tells the broker the program's own
# exit status at once (it stays, holding the display, for the rest), and the
# broker answers the requester with it. Told only at the end of the tree, an
# Inno Setup uninstaller (RawTherapee's, KeePass's) stayed at 100% for ever:
# its second phase, started by the elevated first phase, waits for the
# requester to end (/INITPROCWND), and the requester waited for the second
# phase. Drivers build the two halves from the sources:
#   sg-elevated-run: a program that exits 7 and leaves a child for 3 s -- the
#     code is told within 1.5 s, the wait for the tree ends after the child
#   sg-brokerd: a status told on the pipe is the answer at once; with nothing
#     told (no sg-elevated-run, or it could not start) the process's own exit
# Mutant: SG_MUTANT_EXIT_AT_TREE_END (both files) fails it.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
RC=0; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
cat > "$T/run.c" <<EOC
#define main elevated_run_main
#include "$HERE/broker/sg-elevated-run.c"
#undef main
#include <pthread.h>
static long ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000 + t.tv_nsec / 1000000; }
static int rfd; static long t0;
/* the broker's end, a thread: a reading process would be one of the children waited for */
static void *reader(void *arg)
{
    uint32_t code;
    (void)arg;
    if (read(rfd, &code, 4) == 4) { printf("told %u after %ld\n", code, ms() - t0); fflush(stdout); }
    return NULL;
}
int main(void)
{
    int p[2], fd; pid_t prog, xpid = -1; uint32_t code = 0; pthread_t th;
    t0 = ms();
    prctl(PR_SET_CHILD_SUBREAPER, 1);
    signal(SIGCHLD, SIG_DFL);
    if (pipe(p)) return 1;
    rfd = p[0]; fd = p[1];
    pthread_create(&th, NULL, reader, NULL);
    if (!(prog = fork())) { execl("/bin/sh", "sh", "-c", "sleep 3 & exit 7", (char *)NULL); _exit(127); }
    code = (uint32_t)wait_program(prog, &xpid, &fd);
    pthread_join(th, NULL);
    printf("tree %u after %ld fd %d\n", code, ms() - t0, fd);
    return 0;
}
EOC
cat > "$T/brk.c" <<EOC
#define main brokerd_main
#include "$HERE/broker/sg-brokerd.c"
#undef main
static long ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000 + t.tv_nsec / 1000000; }
int main(void)
{
    int p[2]; pid_t prog; long t0; uint32_t c = 9;
    signal(SIGCHLD, SIG_DFL);
    if (pipe(p)) return 1;
    t0 = ms();
    if (!(prog = fork())) { close(p[0]); if (write(p[1], &c, 4) != 4) _exit(1); close(p[1]); sleep(2); _exit(3); }
    close(p[1]);
    printf("told %u after %ld\n", program_code(p[0], prog), ms() - t0);
    waitpid(prog, NULL, 0);
    if (pipe(p)) return 1;
    if (!(prog = fork())) { close(p[0]); close(p[1]); _exit(4); }
    close(p[1]);
    printf("untold %u\n", program_code(p[0], prog));
    return 0;
}
EOC
build() { cc -O1 ${MUT:+-D$MUT} -o "$T/$1$2" "$T/$1.c" ${3:-} 2>"$T/cc.log" || { echo "SKIP: cannot build the $1 driver"; cat "$T/cc.log"; exit 77; }; }
build run "" -lpthread; build brk "" -lpam
MUT=SG_MUTANT_EXIT_AT_TREE_END build run -mut -lpthread; MUT=SG_MUTANT_EXIT_AT_TREE_END build brk -mut -lpam
check() { # suffix label
    out=$("$T/run$1"); b=$("$T/brk$1")
    printf "%s\n%s\n" "$out" "$b" | sed 's/^/      /'
    told=$(printf "%s\n" "$out" | sed -n 's/^told \([0-9]*\) after \([0-9]*\)$/\1 \2/p')
    tree=$(printf "%s\n" "$out" | sed -n 's/^tree \([0-9]*\) after \([0-9]*\) fd \(-*[0-9]*\)$/\1 \2 \3/p')
    set -- $told $tree
    ok1=0; [ $# -eq 5 ] && [ "$1" = 7 ] && [ "$2" -lt 1500 ] && [ "$3" = 7 ] && [ "$4" -ge 2500 ] && [ "$5" = -1 ] && ok1=1
    bt=$(printf "%s\n" "$b" | sed -n 's/^told \([0-9]*\) after \([0-9]*\)$/\1 \2/p'); set -- $bt
    ok2=0; [ $# -eq 2 ] && [ "$1" = 9 ] && [ "$2" -lt 1000 ] && printf "%s\n" "$b" | grep -qx 'untold 4' && ok2=1
}
check ""
[ $ok1 = 1 ] && pass "sg-elevated-run tells the program's exit (7) at once, and waits on for what it left running" || fail "sg-elevated-run: $out"
[ $ok2 = 1 ] && pass "the broker answers with the told status at once, else with the process's own exit" || fail "broker: $b"
check -mut
[ $ok1 = 0 ] && [ $ok2 = 0 ] && pass "MUTANT EXIT_AT_TREE_END: told only at the end (gate catches it)" || fail "mutant not caught: $out / $b"
[ $RC = 0 ] && echo "elevate-exit: all passed" || echo "elevate-exit: FAILED"
exit $RC
