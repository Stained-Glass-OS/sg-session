#!/bin/sh
# sg-xtype (greeter/sg-xtype.c) types into the X window that has the focus:
# the touch keyboard's keys for a Linux program (sg-shell's sg-touchkbd starts
# it when a Linux program's window is in front). Under Xvfb, xev has the
# focus; "h", Shift+i, BackSpace, Ctrl+a and an e with an accent (no key of
# Xvfb's layout gives it: a spare key code, mapped back after) must reach it.
# Needs Xvfb, xev, xmodmap and xdotool; skips (77) without. SG_XTYPE tests
# another build (mutant -DSG_MUTANT_XTYPE_NO_SPARE fails it).
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
XT="${SG_XTYPE:-$HERE/build/sg-xtype}"
for t in Xvfb xev xdotool xmodmap; do command -v $t >/dev/null || { echo "SKIP: $t missing"; exit 77; }; done
[ -x "$XT" ] || { echo "SKIP: $XT missing (make greeter)"; exit 77; }
RC=0; XP=; EP=
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
T=$(mktemp -d /var/tmp/sg-xtype.XXXXXX)
trap '[ -n "$EP" ] && kill "$EP" 2>/dev/null; [ -n "$XP" ] && kill "$XP" 2>/dev/null; rm -rf "$T"' EXIT INT TERM
unset DISPLAY XAUTHORITY WAYLAND_DISPLAY
for n in $(seq 181 220); do [ -e "/tmp/.X11-unix/X$n" ] || [ -e "/tmp/.X$n-lock" ] || break; done
Xvfb ":$n" -screen 0 800x600x24 -nolisten tcp >/dev/null 2>&1 & XP=$!
export DISPLAY=":$n" SG_XTYPE_TEST=1
sleep 1
xev -geometry 300x200+10+10 -event keyboard > "$T/xev.log" 2>&1 & EP=$!
i=0; while ! xdotool search --name 'Event Tester' >/dev/null 2>&1 && [ $i -lt 40 ]; do sleep 0.25; i=$((i + 1)); done
xdotool windowfocus --sync "$(xdotool search --name 'Event Tester' | head -1)" 2>/dev/null; sleep 0.5
xmodmap -pke > "$T/map.before"
"$XT" u:0068 u:0049 k:BackSpace ctrl+u:0061 u:00e9; sleep 1
xmodmap -pke > "$T/map.after"
keys=$(grep -o 'keysym 0x[0-9a-f]*, [A-Za-z_]*' "$T/xev.log" | sed 's/.*, //' | tr '\n' ' ')
echo "      xev saw: $keys"
case "$keys" in *"h h "*) pass "a character: h";; *) fail "no h";; esac
case "$keys" in *"Shift_L I I Shift_L "*) pass "a capital with Shift: I";; *) fail "no Shift+I";; esac
case "$keys" in *"BackSpace BackSpace "*) pass "a named key: BackSpace";; *) fail "no BackSpace";; esac
case "$keys" in *"Control_L a a Control_L "*) pass "with Ctrl: Ctrl+a";; *) fail "no Ctrl+a";; esac
case "$keys" in *"eacute eacute"*) pass "a character no key gives: eacute, through a spare key";; *) fail "no eacute";; esac
cmp -s "$T/map.before" "$T/map.after" && pass "and the keyboard's map is as it was" || fail "the key map changed: $(diff "$T/map.before" "$T/map.after" | head -3 | tr '\n' ' ')"
[ $RC = 0 ] && echo "xtype-test: PASS" || echo "xtype-test: FAIL"
exit $RC
