#!/bin/sh
. "$(dirname "$0")/scratch-home.sh"
# The lock and sign-in screen's text boxes take Ctrl+A (greeter/sg-greeter.c):
# it selects what was typed, so typing replaces it -- a wrong password could
# only be cleared a character at a time (QA 2026-10-02). The greeter alone,
# under Xvfb: "abc", Ctrl+A, "alex", Return must send USER alex, not abcalex.
# Needs Xvfb, xdotool, a Wine (SG_WINE_DIR) and build/sg-greeter64.exe; skips
# (77) without. SG_GREETER_EXE tests another build.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WINE_DIR="${SG_WINE_DIR:-/opt/wine-sg}"
EXE="${SG_GREETER_EXE:-$HERE/build/sg-greeter64.exe}"
for t in Xvfb xdotool; do command -v $t >/dev/null || { echo "SKIP: $t missing"; exit 77; }; done
[ -x "$WINE_DIR/bin/wine" ] && [ -f "$EXE" ] || { echo "SKIP: wine or $EXE missing"; exit 77; }
T=$(mktemp -d /var/tmp/sg-greeter-selectall.XXXXXX); XP=; SP=
export HOME="$T/home" WINEPREFIX="$T/pfx" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=;winemenubuilder.exe=d" PATH="$WINE_DIR/bin:$PATH"
mkdir -p "$HOME"
trap 'wineserver -k 2>/dev/null; [ -n "$SP" ] && kill "$SP" 2>/dev/null; [ -n "$XP" ] && kill "$XP" 2>/dev/null; rm -rf "$T"' EXIT INT TERM
for n in $(seq 140 180); do [ -e "/tmp/.X11-unix/X$n" ] || break; done
Xvfb ":$n" -screen 0 1024x768x24 -nolisten tcp >/dev/null 2>&1 & XP=$!
export DISPLAY=":$n"
wine wineboot -i >/dev/null 2>&1; wineserver -w
mkfifo "$T/in"
wine "$EXE" < "$T/in" > "$T/out" 2>/dev/null &
sleep 600 > "$T/in" 2>/dev/null & SP=$!   # the bridge stays open, saying nothing
i=0; while [ $i -lt 60 ] && ! xdotool search --class sg-greeter64.exe >/dev/null 2>&1 && ! xdotool search --name 'Sign in' >/dev/null 2>&1; do sleep 0.5; i=$((i + 1)); done
sleep 2
xdotool type --delay 60 abc; sleep 0.3
xdotool key ctrl+a; sleep 0.3
xdotool type --delay 60 alex; sleep 0.3
xdotool key Return; sleep 2
got=$(tr -d '\r' < "$T/out" | grep '^USER' | head -1)
echo "      sent: $got"
if [ "$got" = "USER alex" ]; then echo "PASS  Ctrl+A selects the name typed; typing replaces it"; echo "greeter-selectall-test: PASS"; exit 0; fi
echo "FAIL  Ctrl+A did not select it: $got"; echo "greeter-selectall-test: FAIL"; exit 1
