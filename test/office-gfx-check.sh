#!/bin/sh
. "$(dirname "$0")/scratch-home.sh"
# sg-run-explorer turns Microsoft Office's hardware drawing off for an
# account that has no choice recorded (Office windows stayed empty with it
# on), and leaves a value the user set alone. Runs the script's own lines
# against a scratch prefix.
#
#   WINE=/opt/wine-sg/bin/wine test/office-gfx-check.sh
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
WINE="${WINE:-/opt/wine-sg/bin/wine}"
WINESERVER="${WINESERVER:-$(dirname "$WINE")/wineserver}"
[ -x "$WINE" ] || { echo "SKIP: no wine at $WINE"; exit 77; }
RC=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; RC=1; }
T=$(mktemp -d /var/tmp/sg-offgfx.XXXXXX)
export HOME="$T" WINEPREFIX="$T/prefix" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=;winemenubuilder.exe=d" WINESERVER
trap '"$WINESERVER" -k 2>/dev/null; rm -rf "$T"' EXIT INT TERM
timeout -s KILL 300 env DISPLAY= "$WINE" wineboot -i >/dev/null 2>&1
# the lines between the Office comment and the next blank line
awk '/^# Microsoft Office draws in software/ { on = 1 } on && /^$/ { exit } on' "$HERE/../lib/sg-run-explorer" > "$T/snippet.sh"
[ -s "$T/snippet.sh" ] || { fail "the Office lines are not in sg-run-explorer"; exit 1; }
run() { ( wine() { "$WINE" "$@"; }; sg_log() { echo "log: $*"; }; . "$T/snippet.sh" ); }
val() { "$WINE" reg query 'HKCU\Software\Microsoft\Office\16.0\Common\Graphics' /v DisableHardwareAcceleration 2>/dev/null | tr -d '\r' | awk '/DisableHardwareAcceleration/ { print $3 }'; }
run
[ "$(val)" = 0x1 ] && pass "no choice recorded: Office draws in software (DisableHardwareAcceleration 1)" || fail "after first login: '$(val)'"
"$WINE" reg add 'HKCU\Software\Microsoft\Office\16.0\Common\Graphics' /v DisableHardwareAcceleration /t REG_DWORD /d 0 /f >/dev/null 2>&1
run
[ "$(val)" = 0x0 ] && pass "the user turned it back on: left alone" || fail "user's value overwritten: '$(val)'"
echo
[ "$RC" -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
