#!/bin/sh
# sg_start_vdagent (lib/sg-common.sh): in a virtual machine with SPICE's port
# the session starts spice-vdagent (copy and paste with the host; David
# 2026-10-01 could not paste into the VM), without it nothing; and sg-session
# depends on spice-vdagent, so machines get it with apt.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
RC=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; RC=1; }
T=$(mktemp -d /var/tmp/sg-vdagent-test.XXXXXX)
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin"
printf '#!/bin/sh\necho "$*" >> "%s/calls"\n' "$T" > "$T/bin/spice-vdagent"
chmod +x "$T/bin/spice-vdagent"
run() {   # $1: the port file
    PATH="$T/bin:$PATH" SG_VDAGENT_PORT="$1" sh -c '. "$0/lib/sg-common.sh"; sg_start_vdagent; wait' "$HERE" 2>/dev/null
}
: > "$T/port"
run "$T/port"
[ "$(cat "$T/calls" 2>/dev/null)" = "-x" ] && pass "with SPICE's port: spice-vdagent starts (-x, in the foreground of its own process)" \
    || fail "with the port: $(cat "$T/calls" 2>/dev/null)"
rm -f "$T/calls"
run "$T/no-such-port"
[ ! -e "$T/calls" ] && pass "without it (not a SPICE virtual machine): not started" || fail "started without the port"
grep -q '^    sg_start_vdagent$' "$HERE/lib/sg-run-explorer" && pass "the session starts it" || fail "sg-run-explorer does not call it"
sed -n '/^Package: sg-session$/,/^$/p' "$HERE/debian/control" | grep -q 'spice-vdagent' \
    && pass "sg-session depends on spice-vdagent (installed machines get it with apt)" || fail "no spice-vdagent dependency"
[ "$RC" = 0 ] && echo "vdagent-test: PASS" || echo "vdagent-test: FAIL"
exit "$RC"
