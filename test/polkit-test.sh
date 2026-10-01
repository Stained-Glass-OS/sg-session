#!/bin/sh
# The session's polkit agent (sg-polkit-agent) and the broker's polkit path,
# on a private bus with a stand-in polkitd (test/polkit-fixture.c): pkexec's
# request goes to the broker's consent, and only after a Yes from someone
# polkit asked for does polkitd hear who authenticated (from the broker's
# monitor, through sg-polkit-respond). A throwaway broker in test mode, as
# this user (no root, no display):
#   1. Yes: polkitd gets the answer (this user, the cookie), the agent says ok
#   2. No: no answer, the agent says Cancelled
#   3. Yes from someone polkit did not ask for: no answer, Failed
#   4. the agent is the SYSTEM account's: the monitor gives no answer
#   and the prompt names the program from pkexec's message.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
B=${SG_BROKER_BUILD:-$HERE/build}
for f in sg-brokerd sg-polkit-agent sg-polkit-respond; do
    [ -x "$B/$f" ] || { echo "SKIP: build $f first (make procagent polkitagent)"; exit 77; }
done
command -v dbus-daemon >/dev/null || { echo "SKIP: dbus-daemon missing"; exit 77; }
pkg-config --exists gio-2.0 || { echo "SKIP: gio-2.0 development files missing"; exit 77; }
RC=0; T=$(mktemp -d)
BUSPID=""
cleanup() {
    [ -n "$BUSPID" ] && kill "$BUSPID" 2>/dev/null
    for p in $(cat "$T/pids" 2>/dev/null); do kill "$p" 2>/dev/null; done
    rm -rf "$T"
}
trap cleanup EXIT INT TERM
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
me=$(id -un); grp=$(id -gn); uid=$(id -u)

cc -O2 -o "$T/fixture" "$HERE/test/polkit-fixture.c" $(pkg-config --cflags --libs gio-2.0) ||
    { echo "SKIP: cannot build the fixture"; exit 77; }
dbus-daemon --session --nofork --print-address=3 3>"$T/addr" >/dev/null 2>&1 &
BUSPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T/addr" ] && break; sleep 0.3; done
DBUS_SYSTEM_BUS_ADDRESS=$(head -1 "$T/addr")
export DBUS_SYSTEM_BUS_ADDRESS
[ -n "$DBUS_SYSTEM_BUS_ADDRESS" ] || { fail "no private bus"; exit 1; }

# one pkexec-like request: $1 case name, $2 consent (yes/no), $3 the uids
# polkit asks for, $4 the SYSTEM account
ask() {
    log="$T/$1.log"; rm -f "$T/sock"
    "$T/fixture" "$log" "cookie-$1" "$3" "Authentication is needed to run \`/usr/sbin/gparted' as the super user" &
    echo $! >> "$T/pids"
    for _ in $(seq 20); do grep -q READY "$log" 2>/dev/null && break; sleep 0.2; done
    SG_BROKER_TEST=1 SG_BROKER_TEST_CONSENT="$2" SG_BROKER_FOREGROUND=1 SG_BROKER_ONCE=1 \
        SG_BROKER_SOCK="$T/sock" SG_BROKERD_LOG="$T/brokerd.log" SG_SYSTEM_USER="$4" SG_ADMIN_GROUP="$grp" \
        SG_SEAT_DIR="$T/noseat" SG_POLKIT_RESPOND="$B/sg-polkit-respond" "$B/sg-brokerd" >/dev/null 2>&1 </dev/null &
    echo $! >> "$T/pids"
    for _ in $(seq 20); do [ -S "$T/sock" ] && break; sleep 0.2; done
    SG_BROKER_SOCK="$T/sock" "$B/sg-polkit-agent" 2>>"$T/agent.log" &
    apid=$!; echo $apid >> "$T/pids"
    for _ in $(seq 50); do grep -q '^BEGIN' "$log" 2>/dev/null && break; sleep 0.2; done
    kill "$apid" 2>/dev/null
}

ask yes yes "$uid" nobody
grep -qx "RESPONSE $uid cookie-yes unix-user:$uid" "$T/yes.log" && grep -qx 'BEGIN ok' "$T/yes.log" \
    && pass "Yes: polkitd hears who authenticated (the cookie, this user), and the agent finishes" \
    || fail "Yes: $(tr '\n' ' ' < "$T/yes.log")"
grep -q 'polkit request from .*(/usr/sbin/gparted)' "$T/brokerd.log" \
    && pass "the prompt names the program, from pkexec's message" || fail "program: $(grep polkit "$T/brokerd.log" | head -2)"

ask no no "$uid" nobody
! grep -q '^RESPONSE' "$T/no.log" && grep -qx 'BEGIN org.freedesktop.PolicyKit1.Error.Cancelled' "$T/no.log" \
    && pass "No: polkitd hears nothing, the agent says Cancelled" || fail "No: $(tr '\n' ' ' < "$T/no.log")"

ask other yes 0 nobody
! grep -q '^RESPONSE' "$T/other.log" && grep -qx 'BEGIN org.freedesktop.PolicyKit1.Error.Failed' "$T/other.log" \
    && pass "Yes from someone polkit did not ask for: no answer" || fail "other: $(tr '\n' ' ' < "$T/other.log")"

ask system yes "$uid" "$me"
! grep -q '^RESPONSE' "$T/system.log" && grep -qx 'BEGIN org.freedesktop.PolicyKit1.Error.Failed' "$T/system.log" \
    && pass "an agent of the SYSTEM account's: the monitor gives polkitd no answer" || fail "system: $(tr '\n' ' ' < "$T/system.log")"

grep -q '^REGISTERED' "$T/yes.log" && pass "the agent registers with polkit" || fail "no registration"
exit $RC
