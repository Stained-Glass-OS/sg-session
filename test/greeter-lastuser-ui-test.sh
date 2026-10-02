#!/bin/sh
. "$(dirname "$0")/scratch-home.sh"
# The login screen with the last account (greeter/sg-greeter.c, LASTUSER):
# its sign-in starts at once (USER <name>, no name typed), the password goes
# straight in, and "Other user" (bottom left) ends it (CANCEL) and asks for a
# name again. The greeter alone under Xvfb, the bridge played by the test.
# Needs Xvfb, xdotool, a Wine (SG_WINE_DIR) and build/sg-greeter64.exe; skips
# (77) without. SG_GREETER_EXE: another build (mutant IGNORE_LAST_USER).
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WINE_DIR="${SG_WINE_DIR:-/opt/wine-sg}"
EXE="${SG_GREETER_EXE:-$HERE/build/sg-greeter64.exe}"
for t in Xvfb xdotool; do command -v $t >/dev/null || { echo "SKIP: $t missing"; exit 77; }; done
[ -x "$WINE_DIR/bin/wine" ] && [ -f "$EXE" ] || { echo "SKIP: wine or $EXE missing"; exit 77; }
T=$(mktemp -d /var/tmp/sg-greeter-lastuser.XXXXXX); XP=; RC=0
export HOME="$T/home" WINEPREFIX="$T/pfx" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=;winemenubuilder.exe=d" PATH="$WINE_DIR/bin:$PATH"
mkdir -p "$HOME"
trap 'exec 3>&- 2>/dev/null; wineserver -k 2>/dev/null; [ -n "$XP" ] && kill "$XP" 2>/dev/null; rm -rf "$T"' EXIT INT TERM
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
for n in $(seq 140 180); do [ -e "/tmp/.X11-unix/X$n" ] || break; done
Xvfb ":$n" -screen 0 1024x768x24 -nolisten tcp >/dev/null 2>&1 & XP=$!
export DISPLAY=":$n"
wine wineboot -i >/dev/null 2>&1; wineserver -w
mkfifo "$T/in"
wine "$EXE" < "$T/in" > "$T/out" 2>/dev/null &
exec 3> "$T/in"   # the bridge, played here
i=0; while [ $i -lt 60 ] && ! xdotool search --name 'Sign in' >/dev/null 2>&1; do sleep 0.5; i=$((i + 1)); done
sleep 2
sent() { tr -d '\r' < "$T/out"; }
printf 'READY\nLASTUSER alex\n' >&3; sleep 1.5
sent | grep -qx 'USER alex' && pass "the last account's sign-in starts by itself" || fail "no USER alex: $(sent | tr '\n' '|')"
printf 'PROMPT_SECRET Password:\n' >&3; sleep 1
xdotool key shift; sleep 0.3          # the curtain, if any
xdotool type --delay 60 pw; xdotool key Return; sleep 1.5
sent | grep -qx 'REPLY pw' && pass "its password goes straight in" || fail "no REPLY pw: $(sent | tr '\n' '|')"
printf 'FAILURE The user name or password is incorrect. Try again.\n' >&3; sleep 1.5
[ "$(sent | grep -cx 'USER alex')" = 2 ] && pass "a wrong password asks again for the same account" || fail "after a failure: $(sent | tr '\n' '|')"
xdotool mousemove 90 718; sleep 0.3; xdotool click 1; sleep 1
sent | grep -qx 'CANCEL' && pass "Other user ends that sign-in" || fail "no CANCEL: $(sent | tr '\n' '|')"
xdotool type --delay 60 bob; xdotool key Return; sleep 1.5
sent | grep -qx 'USER bob' && pass "...and asks for a name" || fail "no USER bob: $(sent | tr '\n' '|')"
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
