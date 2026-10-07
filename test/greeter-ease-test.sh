#!/bin/sh
. "$(dirname "$0")/scratch-home.sh"
# A computer without a keyboard can sign in (greeter/sg-ease.h): the login
# and lock screens have an Ease of Access button beside the power button,
# whose menu brings up the On-Screen Keyboard and the touch keyboard
# (sg-shell's sg-osk and sg-touchkbd), and the touch keyboard runs from the
# start to show itself for a touched text box with no keyboard attached.
# The keyboards run in the screen's own Wine and end with it.
#
#   - the login screen: the touch keyboard starts in the background; the
#     menu's On-Screen Keyboard opens it and closes it again; its Touch
#     keyboard shows that one, and its keys type the user name: "ab", Enter
#     sends USER ab -- the user name box has the focus again after the menu
#   - the screen ends: no keyboard of it is left running
#   - the lock screen (/lock user): the same button, the On-Screen Keyboard
#   - the consent prompt asking for credentials (in a desktop of its own),
#     Setup and the first-run setup: their Ease of Access, the On-Screen
#     Keyboard
#
# Needs Xvfb, xdotool, a Wine (SG_WINE_DIR), build/sg-greeter64.exe and
# sg-shell's sg-osk64.exe and sg-touchkbd64.exe (SG_SHELL_BUILD, default
# ../sg-shell/build); skips (77) without. SG_GREETER_EXE tests another build
# (mutants -DSG_MUTANT_NO_EASE, -DSG_MUTANT_EASE_OUTLIVES).
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WINE_DIR="${SG_WINE_DIR:-/opt/wine-sg}"
EXE="${SG_GREETER_EXE:-$HERE/build/sg-greeter64.exe}"
SHELL_BUILD="${SG_SHELL_BUILD:-$HERE/../sg-shell/build}"
for t in Xvfb xdotool; do command -v $t >/dev/null || { echo "SKIP: $t missing"; exit 77; }; done
if [ -x "$WINE_DIR/bin/wine" ]; then WBIN="$WINE_DIR/bin"
elif [ -x "$WINE_DIR/wine" ]; then WBIN="$WINE_DIR"
else echo "SKIP: no wine in $WINE_DIR"; exit 77; fi
[ -f "$EXE" ] && [ -f "$HERE/build/sg-consent64.exe" ] && [ -f "$HERE/build/sg-setup64.exe" ] && [ -f "$HERE/build/sg-oobe64.exe" ] \
    || { echo "SKIP: $EXE or the other screens' builds missing (make greeter)"; exit 77; }
[ -f "$SHELL_BUILD/sg-osk64.exe" ] && [ -f "$SHELL_BUILD/sg-touchkbd64.exe" ] || { echo "SKIP: no sg-shell build at $SHELL_BUILD"; exit 77; }
RC=0; XP=; SP=
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
T=$(mktemp -d /var/tmp/sg-greeter-ease.XXXXXX)
unset DISPLAY XAUTHORITY WAYLAND_DISPLAY
export WINEPREFIX="$T/pfx" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=;winemenubuilder.exe=d" PATH="$WBIN:$PATH"
WSERVER="$WBIN/wineserver"; [ -x "$WSERVER" ] || WSERVER="$WBIN/server/wineserver"
cleanup() { "$WSERVER" -k 2>/dev/null; [ -n "$SP" ] && kill "$SP" 2>/dev/null; [ -n "$XP" ] && kill "$XP" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT INT TERM
for n in $(seq 140 180); do [ -e "/tmp/.X11-unix/X$n" ] || [ -e "/tmp/.X$n-lock" ] || break; done
Xvfb ":$n" -screen 0 1024x768x24 -nolisten tcp >/dev/null 2>&1 & XP=$!
export DISPLAY=":$n"
sleep 1
wine wineboot -i >/dev/null 2>&1; "$WSERVER" -w
C="$WINEPREFIX/drive_c"
mkdir -p "$T/shell"
cp "$SHELL_BUILD/sg-osk64.exe" "$SHELL_BUILD/sg-touchkbd64.exe" "$T/shell/"
printf 'I: Bus=0019\nN: Name="Power Button"\nB: EV=3\nB: KEY=10000000000000 0\n\n' > "$C/devices.txt"
# the screens' environment: sg-shell's programs there; a touch screen (Xvfb
# has none) and no keyboard attached; where the keyboards say their keys are
export SG_SHELL_DIR="$T/shell" SG_GREETER_CURTAIN=0 SG_TOUCHKBD_TOUCH=1 SG_TOUCHKBD_DEVICES='C:\devices.txt' \
    SG_TOUCHKBD_DUMP='C:\touchkbd.txt' SG_OSK_DUMP='C:\osk.txt'

running() { ps -eo args | grep "sg-$1" | grep -c "$(basename "$T")"; }   # this test's own
osk() { sed -n 's/^VISIBLE //p' "$C/osk.txt" 2>/dev/null | tr -d '\r' | head -1; }
tip() { sed -n 's/^WINDOW \([01]\).*/\1/p' "$C/touchkbd.txt" 2>/dev/null | tr -d '\r' | head -1; }
key() { sed -n "s/^KEY $1 //p" "$C/touchkbd.txt" 2>/dev/null | tr -d '\r' | head -1; }
tap() { for k in "$@"; do set -- $(key "$k"); [ -n "${1:-}" ] && xdotool mousemove "$1" "$2" click 1; sleep 0.4; done; }
# the Ease of Access button, beside the power button (bottom right), and an item of its menu
ease() { xdotool mousemove $((1024 - 108)) $((768 - 48)) click 1; sleep 1.5; xdotool key "$1"; sleep 2.5; }
greeter() {
    rm -f "$T/in"; mkfifo "$T/in"
    wine "$EXE" "$@" < "$T/in" > "$T/out" 2>/dev/null &
    sleep 900 > "$T/in" 2>/dev/null & SP=$!   # the bridge stays open, saying nothing
    i=0; while [ $i -lt 60 ] && ! xdotool search --name 'Sign in' >/dev/null 2>&1; do sleep 0.5; i=$((i + 1)); done
    sleep 3
}
end_greeter() {   # the bridge goes away: the screen ends
    kill "$SP" 2>/dev/null; SP=
    i=0; while [ $i -lt 30 ] && ps -eo args | grep -v grep | grep -q "$EXE"; do sleep 0.5; i=$((i + 1)); done
    sleep 2
}

# --- the login screen ---
greeter
[ -s "$C/touchkbd.txt" ] && [ "$(tip)" = 0 ] && pass "the touch keyboard runs in the background from the start, hidden" \
    || fail "no touch keyboard in the background: $(head -2 "$C/touchkbd.txt" 2>/dev/null | tr '\n' ' ')"
# no taskbar here: no button (/notray) -- Wine stood it in an empty tray
# window of its own, a white box on the Surface's sign-in screen
grep -q 'tray=0' "$C/touchkbd.txt" && pass "and with no button in a notification area the sign-in screen has not got" \
    || fail "the touch keyboard's button on the sign-in screen: $(grep -o 'tray=[01]' "$C/touchkbd.txt" | head -1)"
ease o
[ "$(osk)" = 1 ] && pass "Ease of Access > On-Screen Keyboard opens it" || fail "no On-Screen Keyboard: $(head -3 "$C/osk.txt" 2>/dev/null | tr '\n' ' ')"
ease o
{ grep -q CLOSED "$C/osk.txt" 2>/dev/null || [ "$(osk)" = 0 ]; } && pass "and chosen again closes it" \
    || fail "the On-Screen Keyboard stayed: $(head -3 "$C/osk.txt" 2>/dev/null | tr '\n' ' ')"
ease t
[ "$(tip)" = 1 ] && pass "Ease of Access > Touch keyboard shows the touch keyboard" || fail "the touch keyboard: $(head -1 "$C/touchkbd.txt" 2>/dev/null)"
tap a b enter
sleep 1
got=$(tr -d '\r' < "$T/out" | grep '^USER' | head -1)
[ "$got" = "USER ab" ] && pass "its keys type into the user name box (the focus back there after the menu): $got" \
    || fail "typed with the touch keyboard: '$got'"
end_greeter
[ "$(running touchkbd64)" = 0 ] && [ "$(running osk64)" = 0 ] && pass "the screen ended: no keyboard of it left running" \
    || fail "keyboards left running: touch $(running touchkbd64), on-screen $(running osk64)"

# --- the lock screen ---
rm -f "$C/osk.txt"
greeter /lock someone
ease o
[ "$(osk)" = 1 ] && pass "the lock screen: Ease of Access > On-Screen Keyboard" || fail "no On-Screen Keyboard on the lock screen"
end_greeter
[ "$(running osk64)" = 0 ] && pass "gone with the lock screen" || fail "the lock screen's On-Screen Keyboard outlived it"

# --- the consent prompt (credentials), Setup and the first-run setup ---
other() {   # NAME X Y EXE ARGS...: the screen, its Ease of Access at X,Y, the On-Screen Keyboard from it
    name=$1 x=$2 y=$3; shift 3
    rm -f "$C/osk.txt" "$T/in"; mkfifo "$T/in"
    wine "$@" < "$T/in" > "$T/out" 2>/dev/null &
    sleep 900 > "$T/in" 2>/dev/null & SP=$!
    sleep 9
    xdotool mousemove "$x" "$y" click 1; sleep 1.5; xdotool key o; sleep 3
    [ "$(osk)" = 1 ] && pass "$name: Ease of Access > On-Screen Keyboard" || fail "$name: no On-Screen Keyboard from its Ease of Access"
    kill "$SP" 2>/dev/null; SP=
    "$WSERVER" -k 2>/dev/null; "$WSERVER" -w 2>/dev/null
}
# the consent prompt's panel: 560 x 420 in the middle, the button at its bottom left
other "the consent prompt" $(( (1024 - 560) / 2 + 40 )) $(( (768 - 420) / 2 + 420 - 32 )) \
    "$HERE/build/sg-consent64.exe" /consent cred someone 'C:\x.exe'
SG_SETUP_BRIDGED=1 other "Setup" $((1024 - 108)) $((768 - 48)) "$HERE/build/sg-setup64.exe"
other "the first-run setup" $((1024 - 48)) $((768 - 48)) "$HERE/build/sg-oobe64.exe"

[ $RC = 0 ] && echo "greeter-ease-test: PASS" || echo "greeter-ease-test: FAIL"
exit $RC
