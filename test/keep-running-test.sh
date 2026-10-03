#!/bin/sh
# sg_keep_running: the shell's helpers come back after a crash or the shell's
# restart (an xkill'ed Linux window took explorer down; Start came back as
# Wine's own menu until a reboot, David 2026-10-02). A copy of sleep named as
# a helper stands in for one.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d)
cp "$(command -v sleep)" "$T/sg-gatehelper-long-name"
trap 'pkill -u "$(id -u)" -x sg-gatehelper-l 2>/dev/null; rm -rf "$T"' EXIT
RC=0
k() {   # the started one must not hold the caller's output open
    ( . "$1" >/dev/null 2>&1; sg_keep_running sg-gatehelper-long-name "$T/sg-gatehelper-long-name" 300 >/dev/null 2>&1; echo $? > "$T/rc" )
    cat "$T/rc"
}
n() { pgrep -u "$(id -u)" -x sg-gatehelper-l | wc -l; }
a=$(k "$HERE/lib/sg-common.sh"); sleep 0.5; c1=$(n)
b=$(k "$HERE/lib/sg-common.sh"); sleep 0.5; c2=$(n)
pkill -u "$(id -u)" -x sg-gatehelper-l; sleep 0.5
d=$(k "$HERE/lib/sg-common.sh"); sleep 0.5; c3=$(n)
[ "$a" = 1 ] && [ "$c1" = 1 ] && echo "PASS  not running: started (a name past 15 characters found by its first 15)" || { echo "FAIL  start: $a, $c1 running"; RC=1; }
[ "$b" = 0 ] && [ "$c2" = 1 ] && echo "PASS  running: left as it is, not a second one" || { echo "FAIL  running: $b, $c2 running"; RC=1; }
[ "$d" = 1 ] && [ "$c3" = 1 ] && echo "PASS  gone: started again" || { echo "FAIL  restart: $d, $c3 running"; RC=1; }
pkill -u "$(id -u)" -x sg-gatehelper-l; sleep 0.3
sed '/^sg_keep_running() {/,/^}/c\sg_keep_running() { return 0; }' "$HERE/lib/sg-common.sh" > "$T/mut.sh"
k "$T/mut.sh" >/dev/null; sleep 0.5
[ "$(n)" = 0 ] && echo "PASS  MUTANT NO_KEEP: nothing runs (the test catches it)" || { echo "FAIL  mutant"; RC=1; }
exit $RC
