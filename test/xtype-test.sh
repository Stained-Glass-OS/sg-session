#!/bin/sh
# sg-xtype (greeter/sg-xtype.c) types into the X window that has the focus:
# the touch keyboard's keys for a Linux program (sg-shell's sg-touchkbd starts
# it when a Linux program's window is in front). Under Xvfb, xev has the
# focus; "h", Shift+i, BackSpace, Ctrl+a and an e with an accent (no key of
# Xvfb's layout gives it: a spare key code, mapped back after) must reach it.
# Needs Xvfb, xev, xmodmap and xdotool; skips (77) without. SG_XTYPE tests
# another build (mutants -DSG_MUTANT_XTYPE_NO_SPARE and -DSG_MUTANT_XTYPE_REVERT_AT_ONCE fail it).
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
# A display of its own, named: no lock file and no socket of that number. Not -displayfd: in a
# private network namespace (netns-run.sh, as agents run gates) the abstract socket of :0 is free,
# Xvfb took :0 and unlinked the host's /tmp/.X11-unix/X0 -- the desktop's (2026-11-22).
n=${SG_XTYPE_DPY:-}
if [ -z "$n" ]; then
    n=500; while [ -e "/tmp/.X$n-lock" ] || [ -e "/tmp/.X11-unix/X$n" ]; do n=$((n + 1)); [ $n -lt 900 ] || { echo "SKIP: no free display"; exit 77; }; done
fi
case "$n" in ''|0) echo "FAIL  refusing display :$n"; exit 1 ;; esac
Xvfb ":$n" -screen 0 800x600x24 -nolisten tcp >/dev/null 2>&1 & XP=$!
_x=0; while [ ! -e "/tmp/.X11-unix/X$n" ] && [ $_x -lt 100 ]; do sleep 0.1; _x=$((_x + 1)); done
kill -0 "$XP" 2>/dev/null && [ -e "/tmp/.X11-unix/X$n" ] || { echo "FAIL  Xvfb did not start on :$n"; exit 1; }
export DISPLAY=":$n" SG_XTYPE_TEST=1
sleep 1
xev -geometry 300x200+10+10 -event keyboard > "$T/xev.log" 2>&1 & EP=$!
i=0; while ! xdotool search --name 'Event Tester' >/dev/null 2>&1 && [ $i -lt 40 ]; do sleep 0.25; i=$((i + 1)); done
xdotool windowfocus --sync "$(xdotool search --name 'Event Tester' | head -1)" 2>/dev/null; sleep 0.5
xmodmap -pke > "$T/map.before"
# xev stands still while the keys go in, and reads them a second later: a program busy elsewhere
# (any program, under load) reads a key press -- and the key map, which it fetches again after a
# change -- late. With the spare key emptied 150 ms after the press, xev under make lint's load
# found nothing on it ("no eacute" now and then); stopped, it never does.
kill -STOP "$EP"
"$XT" u:0068 u:0049 k:BackSpace ctrl+u:0061 u:00e9
sleep 1; kill -CONT "$EP"
i=0; while ! grep -q eacute "$T/xev.log" && [ $i -lt 20 ]; do sleep 0.25; i=$((i + 1)); done
# and the spare key is emptied again, a little later (sg-xtype's child, 2 s on)
i=0; while xmodmap -pke > "$T/map.after" && ! cmp -s "$T/map.before" "$T/map.after" && [ $i -lt 40 ]; do sleep 0.25; i=$((i + 1)); done
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
