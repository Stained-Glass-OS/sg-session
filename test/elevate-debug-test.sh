#!/bin/sh
# "Run with debugging" follows a program when it elevates: sg-elevate sends
# WINEDEBUG and its own standard error (the report's log) with the request, and
# the broker gives both to the elevated program. Without WINEDEBUG nothing is
# passed; a channel list with anything but letters, digits and + - _ , is
# dropped (and so is the log); other variables still never pass. A throwaway
# broker in test mode, as this user (no root, no display).
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
B=${SG_BROKER_BUILD:-$HERE/build}
[ -x "$B/sg-brokerd" ] && [ -x "$B/sg-elevate" ] || { echo "SKIP: build the broker first (make procagent)"; exit 77; }
RC=0; T=$(mktemp -d); trap 'pkill -f "[s]g-brokerd.*$T" 2>/dev/null; rm -rf "$T"' EXIT INT TERM
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
me=$(id -un); grp=$(id -gn)

# the "program": what it saw, written to its standard error and to a file
cat > "$T/prog" <<EOP
#!/bin/sh
echo "prog-stderr WINEDEBUG=\${WINEDEBUG:-none} LD_PRELOAD=\${LD_PRELOAD:-none}" >&2
echo "\${WINEDEBUG:-none}" > "$T/seen"
EOP
chmod 755 "$T/prog"

elevate() {   # $1 = the log; then env for sg-elevate
    log=$1; shift
    rm -f "$T/seen" "$T/sock"
    SG_BROKER_TEST=1 SG_BROKER_TEST_CONSENT=yes SG_BROKER_FOREGROUND=1 SG_BROKER_ONCE=1 \
        SG_BROKER_SOCK="$T/sock" SG_BROKERD_LOG="$T/brokerd.log" SG_SYSTEM_USER="$me" SG_ADMIN_GROUP="$grp" \
        SG_SEAT_DIR="$T/noseat" "$B/sg-brokerd" "$T" >/dev/null 2>&1 </dev/null &
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$T/sock" ] && break; sleep 0.3; done
    env SG_BROKER_SOCK="$T/sock" "$@" "$B/sg-elevate" -- "$T/prog" 2>"$log"
    echo "exit $?" >> "$T/exits"
    wait
}

elevate "$T/log1" WINEDEBUG=+seh,err+all LD_PRELOAD=/nonexistent.so
grep -q 'prog-stderr WINEDEBUG=+seh,err+all' "$T/log1" && pass "the elevated program logs into the requester's log, with its channels" \
    || fail "log1: $(cat "$T/log1") seen: $(cat "$T/seen" 2>/dev/null)"
grep -q 'LD_PRELOAD=none' "$T/log1" && pass "and nothing else of the requester's environment passes" || fail "LD_PRELOAD passed: $(cat "$T/log1")"

elevate "$T/log2"
[ "$(cat "$T/seen" 2>/dev/null)" = none ] && ! grep -q prog-stderr "$T/log2" \
    && pass "no debugging asked for: no channels, no log (the program's output stays the broker's)" \
    || fail "without WINEDEBUG: seen $(cat "$T/seen" 2>/dev/null), log2: $(cat "$T/log2")"

elevate "$T/log3" 'WINEDEBUG=+seh;touch /tmp/x'
[ "$(cat "$T/seen" 2>/dev/null)" = none ] && ! grep -q prog-stderr "$T/log3" \
    && pass "a hostile channel list is dropped, and the log with it" \
    || fail "hostile WINEDEBUG: seen $(cat "$T/seen" 2>/dev/null), log3: $(cat "$T/log3")"

[ "$(grep -c 'exit 0' "$T/exits")" = 3 ] && pass "every request was answered and run" || fail "exits: $(cat "$T/exits")"
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
