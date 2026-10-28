#!/bin/sh
# The taskbar clock's calendar (sg-shell's sg-calendar, David 2026-10-28) is one of
# the shell's helpers kept running (lib/sg-run-explorer), hidden, so a click on the
# clock opens it at once. Not restarted with the shell: it keeps no state of it.
#   --mutant NOKEEP  the keeper without it (must FAIL)
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
F="$HERE/lib/sg-run-explorer"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
if [ "${1:-}" = --mutant ] && [ "${2:-}" = NOKEEP ]; then
    sed 's/sg_helper sg-calendar64.exe .*/:/' "$F" > "$T/f"; F="$T/f"
fi
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
grep -q 'sg_helper sg-calendar64.exe _n_cal wine "$_sgcalendar" --background' "$F" \
    && pass "the keeper runs the calendar, hidden (--background)" || fail "the keeper does not keep the calendar"
grep -q '^_sgcalendar="${SG_SHELL_DIR:-/usr/libexec/stained-glass/shell}/sg-calendar64.exe"' "$F" \
    && pass "...from sg-shell's folder" || fail "no path for it"
grep 'for _h in ' "$F" | grep -q 'sg-calendar' && fail "killed with the shell's helpers" || pass "not killed when the shell comes back"
sh -n "$F" && pass "sg-run-explorer parses" || fail "sg-run-explorer does not parse"
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
