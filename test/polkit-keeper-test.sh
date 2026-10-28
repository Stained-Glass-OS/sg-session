#!/bin/sh
# The session's polkit agent is one of the helpers kept running
# (lib/sg-run-explorer): it is started by sg-session-start, and when it died
# nothing started it again, so a Linux program asking for an administrator
# (GSmartControl, GParted) was refused without a prompt until the next
# sign-in. Not restarted with the shell: it does not talk to the shell.
#   --mutant NOKEEP  the keeper without it (must FAIL)
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
F="$HERE/lib/sg-run-explorer"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
if [ "${1:-}" = --mutant ] && [ "${2:-}" = NOKEEP ]; then
    sed 's/sg_helper sg-polkit-agent .*/:/' "$F" > "$T/f"; F="$T/f"
fi
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
grep -q 'sg_helper sg-polkit-agent _n_pk "${SG_LIBEXEC:-/usr/libexec/stained-glass}/sg-polkit-agent"' "$F" \
    && pass "the keeper starts the polkit agent again when it is gone" || fail "the keeper does not keep the polkit agent"
grep 'for _h in ' "$F" | grep -q 'sg-polkit-agent' \
    && fail "killed with the shell's helpers" || pass "not killed when the shell comes back"
grep -q '"$SG_LIBEXEC/sg-polkit-agent" &' "$HERE/bin/sg-session-start" \
    && pass "sg-session-start still starts it before the desktop" || fail "sg-session-start does not start it"
[ "$(printf '%.15s' sg-polkit-agent)" = sg-polkit-agent ] && pass "its name fits pkill -x's 15 characters" || fail "name too long"
sh -n "$F" && pass "sg-run-explorer parses" || fail "sg-run-explorer does not parse"
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
