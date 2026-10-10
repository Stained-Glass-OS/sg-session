#!/bin/sh
# Running a program as another account (wine-sg 1711): the broker's
# "@launch" request names a launch ticket the wineserver made (the broker's
# own account's file, in its tickets directory: "kind=launch", the account,
# the requester, a time limit) and the program to start. The broker takes a
# ticket once, only from the requester it was made for, only before it
# expires, only a launch ticket; the root monitor never starts anything as a
# system account. Here, as this user (no root): the refusals. Starting a
# program as another account is wine-sg's test/runasuser-gate.sh (root).
# Mutant: SG_MUTANT_LAUNCH_ANY_REQUESTER (broker/sg-brokerd.c).
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
B=${SG_BROKER_BUILD:-$HERE/build}
[ -x "$B/sg-brokerd" ] || { echo "SKIP: build the broker first (make procagent)"; exit 77; }
command -v python3 >/dev/null || { echo "SKIP: no python3"; exit 77; }
RC=0; T=$(mktemp -d "${TMPDIR:-/var/tmp}/launch-ticket.XXXXXX"); trap 'kill "$BPID" 2>/dev/null; rm -rf "$T"' EXIT INT TERM
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
me=$(id -un); grp=$(id -gn); uid=$(id -u)
mkdir "$T/run"
SG_BROKER_FOREGROUND=1 SG_BROKER_SOCK="$T/run/sock" SG_BROKERD_LOG="$T/brokerd.log" SG_SYSTEM_USER="$me" \
    SG_ADMIN_GROUP="$grp" SG_SEAT_DIR="$T/noseat" SG_BROKER_PAMCHECK=/bin/false SG_LOGON_TICKET_DIR="$T/run/tickets" \
    SG_LAUNCH_WINE=/bin/true SG_AUDIT_SPOOL="$T/audit" "$B/sg-brokerd" >/dev/null 2>&1 </dev/null & BPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$T/run/sock" ] && break; sleep 0.3; done

cat > "$T/client.py" <<'PY'
import socket, struct, sys
blob = b'\0'.join([b'@launch', b'LAUNCH_TICKET=' + sys.argv[2].encode(), b'LAUNCH_CWD=/', b'', b'prog.exe']) + b'\0'
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall(struct.pack('=I', len(blob)) + blob)
print('STATUS', s.recv(1)[0])
PY
launch() { python3 "$T/client.py" "$T/run/sock" "$1"; }
plant() {   # NAME, then the ticket's lines
    n=$1; shift
    printf '%s\n' "$@" > "$T/run/tickets/$n"; chmod 600 "$T/run/tickets/$n"
}
later=$(( $(date +%s) + 60 ))
plant aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1 kind=launch uid=0 for=$((uid + 1)) expires=$later
[ "$(launch aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1)" = "STATUS 1" ] && [ -e "$T/run/tickets/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1" ] \
    && pass "a ticket made for another requester: refused, and left for it" || fail "another requester's ticket was taken"
plant aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa2 uid=0 for=$uid expires=$later
[ "$(launch aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa2)" = "STATUS 1" ] && pass "a logon ticket is not a launch ticket" || fail "a logon ticket launched"
plant aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa3 kind=launch uid=0 for=$uid expires=$(( $(date +%s) - 5 ))
[ "$(launch aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa3)" = "STATUS 1" ] && [ ! -e "$T/run/tickets/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa3" ] \
    && pass "an expired ticket: refused, and gone" || fail "an expired ticket"
plant aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa4 kind=launch uid=1 for=$uid expires=$later
[ "$(launch aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa4)" = "STATUS 1" ] && [ ! -e "$T/run/tickets/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa4" ] \
    && pass "a ticket for a system account: taken, and nothing started" || fail "a system account's ticket"
[ "$(launch aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa4)" = "STATUS 1" ] && pass "a ticket is taken once" || fail "a ticket taken twice"
[ "$(launch 'not-a-ticket')" = "STATUS 1" ] && pass "a name that is not a ticket: refused" || fail "a bad name"

echo
[ $RC = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $RC
