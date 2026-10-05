#!/bin/sh
# The shell's helpers include the notification centre's icon (sg-shell's
# sg-notify, 0.1.0-115): started with the desktop when sg-shell has it,
# kept running, and started again for a shell that came back (its icon sat
# in the dead shell's tray). lib/sg-run-explorer.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
F="$HERE/lib/sg-run-explorer"
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
grep -q '^_sgnotify=.*/sg-notify64.exe"$' "$F" && pass "it knows where sg-notify is" || fail "no _sgnotify"
grep -q '\[ -f "\$_sgnotify" \] && sg_helper sg-notify64.exe _n_ntf wine "\$_sgnotify"' "$F" \
    && pass "the keeper starts it when sg-shell has it, and keeps it running" || fail "the keeper does not start sg-notify"
grep 'for _h in ' "$F" | grep -q 'sg-notify64.exe' \
    && pass "and starts it again for a shell that came back" || fail "not restarted with the shell"
[ "$(printf '%.15s' sg-notify64.exe)" = sg-notify64.exe ] && pass "its name fits pkill -x's 15 characters" || fail "name too long for pkill -x"
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
