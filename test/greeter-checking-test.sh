#!/bin/sh
. "$(dirname "$0")/scratch-home.sh"
# The login screen while a password is checked (greeter/sg-greeter.c,
# checking()): the password box is greyed and takes no typing until the
# service asks again, as Windows' takes none while it checks one. David
# 2026-11-13: after a wrong password it let him type at once and cleared that
# a second or two later, when the refusal came -- and Enter then sent it too.
# The greeter alone under Xvfb, the bridge played by the test (as
# greeter-lastuser-ui-test.sh). SG_GREETER_EXE: another build (mutant
# TYPE_WHILE_CHECKING).
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WINE_DIR="${SG_WINE_DIR:-/opt/wine-sg}"
EXE="${SG_GREETER_EXE:-$HERE/build/sg-greeter64.exe}"
for t in Xvfb xdotool; do command -v $t >/dev/null || { echo "SKIP: $t missing"; exit 77; }; done
[ -x "$WINE_DIR/bin/wine" ] && [ -f "$EXE" ] || { echo "SKIP: wine or $EXE missing"; exit 77; }
T=$(mktemp -d /var/tmp/sg-greeter-checking.XXXXXX); XP=; RC=0
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
replies() { sent | grep '^REPLY ' | tr '\n' '|'; }
printf 'READY\nLASTUSER alex\n' >&3; sleep 1.5
printf 'PROMPT_SECRET Password:\n' >&3; sleep 1
xdotool key shift; sleep 0.3          # the curtain, if any
xdotool type --delay 60 wrong; xdotool key Return; sleep 1
# still being checked (PAM's delay after a wrong one): typing and Enter
xdotool type --delay 60 early; xdotool key Return; sleep 1
[ "$(replies)" = "REPLY wrong|" ] && pass "while a password is checked, typing and Enter send nothing" \
    || fail "while checked: $(replies)"
printf 'FAILURE The user name or password is incorrect. Try again.\n' >&3; sleep 1.5
# refused; the same account's sign-in begun again, its prompt not yet come
xdotool type --delay 60 soon; xdotool key Return; sleep 1
[ "$(sent | grep -cx 'USER alex')" = 2 ] && [ "$(replies)" = "REPLY wrong|" ] \
    && pass "refused, nothing taken until the password is asked again" || fail "after the refusal: $(sent | tr '\n' '|')"
printf 'PROMPT_SECRET Password:\n' >&3; sleep 1
xdotool type --delay 60 right; xdotool key Return; sleep 1.5
[ "$(replies)" = "REPLY wrong|REPLY right|" ] && pass "asked again, the box takes the password, nothing typed before in it" \
    || fail "asked again: $(replies)"
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
