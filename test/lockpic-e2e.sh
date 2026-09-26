#!/bin/sh
. "$(dirname "$0")/scratch-home.sh"
# The lock screen's picture, end to end (Settings > Personalization > Lock
# screen): sg-settingsctl publishes the user's choice, sg-lockd stages it with
# its checks, and the real greeter shows it under Xvfb with the time and date
# over it; a key lifts it to the sign-in pane (the picture blurred and dimmed,
# or the plain colour when "show on the sign-in screen" is off) and still
# reaches the user-name box.
#
#   - the drop: a non-picture is refused; a picture and the sign-in switch are
#     published; a symlink planted under the user's name is not staged
#   - curtain: the picture's two colours where they belong, the clock's white
#     text at the bottom left, no sign-in form over the picture
#   - a key lifts it: dimmed picture, form visible, the key typed ("USER alice")
#   - ShowOnSignIn off: the sign-in pane is the plain colour
#   - lock mode: the account picture (the accent circle)
#   - no picture at all: the plain colour with the clock
# ARTIFACTS=DIR keeps the screenshots. SG_GREETER=<exe> tests another build.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WINE_DIR="${SG_WINE_DIR:-/opt/wine-sg}"
GREETER="${SG_GREETER:-$HERE/build/sg-greeter64.exe}"
LOCKD="${SG_LOCKD:-$HERE/build/sg-lockd}"
RC=0; T=$(mktemp -d); XP=""; GP=""
DN="${SG_LOCKPIC_DISPLAY:-:137}"
W=1024; H=768
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
# shellcheck disable=SC2317
cleanup() {
    [ -n "$GP" ] && kill "$GP" 2>/dev/null
    WINEPREFIX="$T/prefix" "$WINE_DIR/bin/wineserver" -k 2>/dev/null
    [ -n "$XP" ] && kill "$XP" 2>/dev/null
    [ -n "${ARTIFACTS:-}" ] && { mkdir -p "$ARTIFACTS"; cp "$T"/*.png "$ARTIFACTS"/ 2>/dev/null; }
    rm -rf "$T"
}
trap cleanup EXIT INT TERM

for t in Xvfb xdotool import convert python3; do command -v "$t" >/dev/null || { echo "SKIP: $t missing"; exit 77; }; done
for f in "$GREETER" "$LOCKD" "$WINE_DIR/bin/wine"; do [ -e "$f" ] || { echo "SKIP: $f missing"; exit 77; }; done
python3 -c 'import PIL' 2>/dev/null || { echo "SKIP: python3-pil missing"; exit 77; }

export WINEPREFIX="$T/prefix" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml="
export SG_LOCKSCREEN_DIR="$T/drop" TMPDIR="$T"
mkdir -m 1733 "$T/drop"
USER_NAME=$(id -un)

# A picture no screen could show by accident: teal above, orange below.
python3 - "$T" <<'PY'
import sys
from PIL import Image
t = sys.argv[1]
im = Image.new("RGB", (1600, 1000), (0x10, 0xA0, 0x90))
im.paste((0xE0, 0x70, 0x10), (0, 500, 1600, 1000))
im.save(t + "/chosen.png")
im.save(t + "/chosen.jpg", quality=95)
im.save(t + "/chosen.bmp")
PY
echo "not a picture" > "$T/fake.png"

# ---- the drop ----------------------------------------------------------------------------
CTL="$HERE/bin/sg-settingsctl"
"$CTL" lockscreen picture "$T/fake.png" >/dev/null 2>&1 && fail "a non-picture was published" \
    || pass "a non-picture is refused"
"$CTL" lockscreen picture "$T/chosen.png" | grep -q '^LOCKSCREEN yes' && pass "the picture is published" \
    || fail "the picture was not published"
[ "$(stat -c %u "$T/drop/$USER_NAME" 2>/dev/null)" = "$(id -u)" ] && pass "published as the user's own file" \
    || fail "published file missing or not the user's"
out=$("$LOCKD" --stage-picture "$USER_NAME" 2>/dev/null)
STAGED=$(echo "$out" | sed -n 's/^PICTURE //p')
[ -n "$STAGED" ] && [ "$STAGED" != - ] && cmp -s "$STAGED" "$T/chosen.png" && pass "sg-lockd stages the user's picture" \
    || fail "sg-lockd did not stage it ($out)"
mv "$T/drop/$USER_NAME" "$T/keep.png"
ln -s "$T/chosen.png" "$T/drop/$USER_NAME"
"$LOCKD" --stage-picture "$USER_NAME" 2>/dev/null | grep -q '^PICTURE -$' \
    && pass "a symlink under the user's name is not followed" || fail "sg-lockd followed a symlink"
rm -f "$T/drop/$USER_NAME"; cp "$T/keep.png" "$T/drop/$USER_NAME"
echo "junk" > "$T/drop/$USER_NAME.x"; cp "$T/fake.png" "$T/drop/$USER_NAME"
"$LOCKD" --stage-picture "$USER_NAME" 2>/dev/null | grep -q '^PICTURE -$' \
    && pass "a published non-picture is not staged" || fail "sg-lockd staged a non-picture"
cp "$T/keep.png" "$T/drop/$USER_NAME"
"$CTL" lockscreen signin no | grep -q "	no$" && "$LOCKD" --stage-picture "$USER_NAME" 2>/dev/null | grep -q '^SIGNIN 0' \
    && pass "the sign-in switch reaches sg-lockd" || fail "the sign-in switch did not reach sg-lockd"
"$CTL" lockscreen signin yes >/dev/null
rm -f "$T"/sg-lockpic-*

# ---- the screen ---------------------------------------------------------------------------
Xvfb "$DN" -screen 0 "${W}x${H}x24" -nolisten tcp >/dev/null 2>&1 &
XP=$!
sleep 1
export DISPLAY="$DN"
"$WINE_DIR/bin/wineboot" -i >/dev/null 2>&1

shot() { import -display "$DN" -window root "$T/$1.png" 2>/dev/null; }
px() { convert "$T/$1.png" -format "%[fx:int(255*p{$2,$3}.r)] %[fx:int(255*p{$2,$3}.g)] %[fx:int(255*p{$2,$3}.b)]" info: 2>/dev/null; }
near() {   # near "R G B" R G B TOL
    set -- $1 "$2" "$3" "$4" "$5"
    [ $(( ($1-$4)*($1-$4) + ($2-$5)*($2-$5) + ($3-$6)*($3-$6) )) -le $(( $7 * $7 )) ]
}
# The share of near-white pixels in a region: the clock's text.
white_in() { convert "$T/$1.png" -crop "$2" +repage -fx '(r>0.9&&g>0.9&&b>0.9)?1:0' -format '%[fx:mean]' info: 2>/dev/null | tail -n1; }

start_greeter() {   # start_greeter NAME [greeter args...]; env decides the rest
    name=$1; shift
    rm -f "$T/out.txt" "$T/in.fifo"; mkfifo "$T/in.fifo"
    # The fifo stays open for writing so the greeter's reader never sees EOF.
    sleep 600 > "$T/in.fifo" &
    FH=$!
    "$WINE_DIR/bin/wine" "$GREETER" "$@" < "$T/in.fifo" > "$T/out.txt" 2>/dev/null &
    GP=$!
    _w=0; until grep -q HELLO "$T/out.txt" 2>/dev/null || [ $_w -ge 60 ]; do sleep 0.5; _w=$((_w+1)); done
    sleep 3
}
stop_greeter() { kill "$GP" "$FH" 2>/dev/null; GP=""; WINEPREFIX="$T/prefix" "$WINE_DIR/bin/wineserver" -w 2>/dev/null & sleep 2; }

CLOCK="$((W/3))x$((H*24/100))+$((H/16))+$((H - H/16 - H*23/100))"
TEAL="16 160 144"; ORANGE="224 112 16"; BG="31 78 121"

# 1. The login screen with the staged picture.
SG_LOCK_PICTURE="$T/keep.png" SG_LOCK_SIGNIN=1 start_greeter login
shot curtain
v=$(px curtain $((W*3/4)) $((H/5))); near "$v" $TEAL 12 && pass "curtain: the picture's top colour ($v)" || fail "curtain: top is $v, not the picture's teal"
v=$(px curtain $((W*3/4)) $((H*4/5))); near "$v" $ORANGE 12 && pass "curtain: the picture's bottom colour ($v)" || fail "curtain: bottom is $v, not the picture's orange"
wf=$(white_in curtain "$CLOCK")
awk "BEGIN{exit !($wf > 0.03)}" && pass "curtain: the clock is drawn at the bottom left (white $wf)" || fail "curtain: no clock text at the bottom left (white $wf)"
v=$(px curtain $((W/2)) $((H/2 - 60 + 110))); near "$v" $ORANGE 12 && pass "curtain: no sign-in form over the picture" || fail "curtain: something covers the picture where the form sits ($v)"

DISPLAY="$DN" xdotool type --delay 120 alice; sleep 1; DISPLAY="$DN" xdotool key Return; sleep 3
shot signin
v=$(px signin $((W*3/4)) $((H/5)))
set -- $v
{ near "$v" 9 94 84 14; } && pass "sign-in pane: the picture blurred and dimmed ($v)" || fail "sign-in pane: top is $v, not the dimmed teal"
wf=$(white_in signin "$CLOCK")
awk "BEGIN{exit !($wf < 0.01)}" && pass "sign-in pane: the clock is gone" || fail "sign-in pane: the clock is still drawn ($wf)"
grep -q "^USER alice" "$T/out.txt" && pass "the key that lifted the curtain was typed (USER alice)" \
    || fail "typing through the curtain lost keys: $(grep USER "$T/out.txt" || echo 'no USER line')"
stop_greeter

# 2. ShowOnSignIn off: the plain colour behind the form (and a JPEG).
SG_LOCK_PICTURE="$T/chosen.jpg" SG_LOCK_SIGNIN=0 start_greeter nosignin
shot nosignin-curtain
v=$(px nosignin-curtain $((W*3/4)) $((H/5))); near "$v" $TEAL 12 && pass "ShowOnSignIn off: the curtain still shows the picture" || fail "ShowOnSignIn off: curtain is $v"
DISPLAY="$DN" xdotool key space; sleep 2
shot nosignin
v=$(px nosignin $((W*3/4)) $((H/5))); near "$v" $BG 6 && pass "ShowOnSignIn off: the sign-in pane is the plain colour ($v)" || fail "ShowOnSignIn off: sign-in pane is $v"
stop_greeter

# 3. The lock screen: the account picture over the blurred picture (a BMP).
SG_LOCK_PICTURE="$T/chosen.bmp" start_greeter lock /lock "$USER_NAME"
printf 'PROMPT_SECRET Password:\n' > "$T/in.fifo" &
sleep 2
DISPLAY="$DN" xdotool click 1; sleep 2
shot lock
r=$((H/13)); cy=$((H/2 - 60 - 130 - r - 16))
v=$(px lock $((W/2 - r/2)) $((cy + r/2))); near "$v" 123 47 190 10 && pass "lock: the account picture ($v)" || fail "lock: no account picture at the centre ($v)"
v=$(px lock $((W*3/4)) $((H*4/5))); near "$v" 131 65 9 14 && pass "lock: a BMP picture, blurred and dimmed ($v)" || fail "lock: bottom is $v, not the dimmed orange"
stop_greeter

# 4. Nothing chosen and no system picture: the plain colour, with the clock.
SG_LOCK_DEFAULT_PICTURE=/nonexistent.jpg start_greeter plain
shot plain
v=$(px plain $((W*3/4)) $((H/5))); near "$v" $BG 6 && pass "no picture: the plain colour ($v)" || fail "no picture: $v"
wf=$(white_in plain "$CLOCK")
awk "BEGIN{exit !($wf > 0.03)}" && pass "no picture: the clock is still drawn" || fail "no picture: no clock ($wf)"
stop_greeter

echo
if [ "$RC" -eq 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; fi
exit "$RC"
