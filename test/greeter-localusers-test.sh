#!/bin/sh
. "$(dirname "$0")/scratch-home.sh"
# The login screen lists this computer's accounts bottom left, above "Other
# user", as Windows does (greeter/sg-greeter.c, LOCALUSER; David 2026-11-13:
# local accounts could only be typed in): a click on one ends the sign-in
# begun for the last account (CANCEL) and begins its own (USER <name>).
# The greeter alone under Xvfb, the bridge played by the test.
# Needs Xvfb, xdotool, a Wine (SG_WINE_DIR) and build/sg-greeter64.exe; skips
# (77) without. SG_GREETER_EXE: another build (mutant LOCALUSER_IGNORED).
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WINE_DIR="${SG_WINE_DIR:-/opt/wine-sg}"
EXE="${SG_GREETER_EXE:-$HERE/build/sg-greeter64.exe}"
for t in Xvfb xdotool; do command -v $t >/dev/null || { echo "SKIP: $t missing"; exit 77; }; done
[ -x "$WINE_DIR/bin/wine" ] && [ -f "$EXE" ] || { echo "SKIP: wine or $EXE missing"; exit 77; }
T=$(mktemp -d /var/tmp/sg-greeter-localusers.XXXXXX); XP=; RC=0
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
printf 'READY\nLASTUSER alex\nLOCALUSER alex\nLOCALUSER bob\n' >&3; sleep 1.5
printf 'PROMPT_SECRET Password:\n' >&3; sleep 1
xdotool key shift; sleep 0.5          # the curtain, if any
xdotool mousemove 134 664; sleep 0.3; xdotool click 1; sleep 1.5
sent | tr '\n' '|' | grep -q 'USER alex|CANCEL|USER bob|' && pass "a click on an account listed bottom left (bob) ends alex's sign-in and begins bob's" \
    || fail "after clicking bob: $(sent | tr '\n' '|')"
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
