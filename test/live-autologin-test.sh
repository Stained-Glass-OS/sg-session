#!/bin/sh
# "Try Stained Glass OS" signs in the live account (greeter/sg-greet-bridge.c,
# SG_GREET_AUTOLOGIN=live on a live boot). The account has no password;
# since sg-session 0.1.0-148 a PAM module after pam_unix (the keyring's
# pam_exec expose_authtok) asks for it anyway, and the bridge gave up at the
# question: the live session never started, Setup came back (release s20's
# install-test). Against greetd-stub expecting an empty password: the
# session starts. Not on a non-live boot, not for another account.
# A test build reads its "kernel command line" from a file
# (-DSG_TEST_CMDLINE). Mutant: -DSG_MUTANT_AUTOLOGIN_NO_ANSWER.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
CC="${CC:-cc}"
[ -x "$HERE/build/greetd-stub" ] || { echo "SKIP: build/greetd-stub not built"; exit 77; }
T=$(mktemp -d); SP=; RC=0
trap '[ -n "$SP" ] && kill "$SP" 2>/dev/null; rm -rf "$T"' EXIT INT TERM
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
"$CC" -O2 -DSG_TEST_CMDLINE="\"$T/cmdline\"" ${SG_BRIDGE_CFLAGS:-} -o "$T/bridge" "$HERE/greeter/sg-greet-bridge.c" \
    || { fail "the test build of the bridge"; exit 1; }
run() {   # USER CMDLINE -> stub output in $T/stub.out, bridge's exit in $T/rc
    rm -f "$T/greetd.sock"; echo "$2" > "$T/cmdline"
    "$HERE/build/greetd-stub" "$T/greetd.sock" "" >"$T/stub.out" 2>&1 & SP=$!
    i=0; while [ ! -S "$T/greetd.sock" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    GREETD_SOCK="$T/greetd.sock" SG_GREET_AUTOLOGIN="$1" timeout 20 "$T/bridge" /bin/true > "$T/bridge.out" 2>&1
    echo $? > "$T/rc"
    kill "$SP" 2>/dev/null; wait "$SP" 2>/dev/null; SP=
}
run live "BOOT_IMAGE=/vmlinuz root=LABEL=SGLIVEROOT systemd.volatile=overlay quiet"
grep -q '^STARTED' "$T/stub.out" && [ "$(cat "$T/rc")" = 0 ] \
    && pass "the live account, asked for a password after pam_unix, answers none and its session starts" \
    || fail "the live session did not start: $(tr '\n' ' ' < "$T/bridge.out" | cut -c1-300)"
run live "BOOT_IMAGE=/vmlinuz root=/dev/vda2 quiet"
grep -q '^STARTED' "$T/stub.out" && fail "a non-live boot signed the live account in" || pass "not on a boot that is not live"
run someone "BOOT_IMAGE=/vmlinuz systemd.volatile=overlay"
grep -q '^STARTED' "$T/stub.out" && fail "another account was signed in" || pass "not for another account"
[ $RC = 0 ] && echo "live-autologin-test: PASS" || echo "live-autologin-test: FAIL"
exit $RC
