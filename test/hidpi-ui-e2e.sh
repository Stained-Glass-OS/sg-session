#!/bin/sh
. "$(dirname "$0")/scratch-home.sh"
# Install-time and Linux programs on a high-resolution screen (David
# 2026-10-05, a Surface Pro 7 at 2736x1824: "everything is tiny"; Setup on
# the live medium, the first-run setup and the login screen must be usable).
# Under Xvfb at 2736x1824, with a real Wine:
#   1. Setup, started as sg-login-ui starts it (lib/sg-ui-scale), sets its
#      account's scale to the recommended 175% and Wine draws it at that
#      scale: its window takes the share of the screen's height it takes at
#      1080p (600 of 1080 lines, within 8%), and the backdrop reaches the
#      screen's bottom (a 1042-line screen was left a black band)
#   2. the first-run setup (sg-oobe) likewise: its card 640/1080 of the height
#   3. a GTK 3 program and a GTK 4 one (zenity) with the session's
#      environment at 175% (sg_linux_scale_env) are drawn larger: 1.6 to 2.1
#      times their size at 100%
# Xvfb runs with -noreset, as Xwayland keeps its resources (its window
# manager stays connected). Needs Xvfb, xwininfo, ImageMagick (import), python3 with PIL, wine and
# 'make greeter'. SG_WINE_DIR: another Wine (its bin/ goes first in PATH).
# Mutants: sg-ui-scale doing nothing (a copy of the library whose
# sg_ui_scale returns at once), SG_MUTANT_BACKDROP_SHORT (Setup built with
# it: MUTANT_SETUP=<exe>), LINUX_NO_SCALE (sg_linux_scale_env doing nothing).
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
BUILD="$HERE/build"
SETUP="${MUTANT_SETUP:-$BUILD/sg-setup64.exe}"
[ -n "${SG_WINE_DIR:-}" ] && PATH="$SG_WINE_DIR/bin:$PATH" && export PATH
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
for t in Xvfb xwininfo xrdb import wine python3 cc; do command -v "$t" >/dev/null || { echo "SKIP: $t missing"; exit 77; }; done
python3 -c 'import PIL' 2>/dev/null || { echo "SKIP: python3 PIL missing"; exit 77; }
[ -f "$SETUP" ] && [ -f "$BUILD/sg-oobe64.exe" ] || { echo "SKIP: run 'make greeter' first"; exit 77; }

T=$(mktemp -d /var/tmp/sg-hidpi-ui.XXXXXX); XP=""; P=""
# shellcheck disable=SC2317
cleanup() {
    [ -n "$P" ] && kill "$P" 2>/dev/null
    WINEPREFIX="$T/prefix" wineserver -k 2>/dev/null
    [ -n "$XP" ] && kill "$XP" 2>/dev/null
    [ -n "${KEEP:-}" ] && echo "kept $T" || rm -rf "$T"
}
trap cleanup EXIT INT TERM
export SG_PREFIX="$T/prefix" WINEPREFIX="$T/prefix" WINEDEBUG=-all XDG_RUNTIME_DIR="$T/run" SG_LOG_DIR="$T"
export WINEDLLOVERRIDES="mscoree,mshtml=;${WINEDLLOVERRIDES:-winemenubuilder.exe=d}"
mkdir -p "$T/run" "$T/lib"
cp "$HERE"/lib/sg-common.sh "$HERE"/lib/sg-ui-scale "$T/lib/"
cc -O2 -o "$T/gtk3probe" "$HERE/test/gtk3-scale-probe.c" -ldl || { fail "the GTK probe did not build"; exit 1; }

Xvfb -displayfd 3 -screen 0 2736x1824x24 -noreset -nolisten tcp 3>"$T/display" >/dev/null 2>&1 & XP=$!
i=0; while [ ! -s "$T/display" ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
DISPLAY=":$(cat "$T/display")"; export DISPLAY
timeout -s KILL 300 wine wineboot -i >/dev/null 2>&1; wineserver -w

# the box of the colour R,G,B in a screenshot: left top right bottom
box() {
    python3 - "$1" "$2" <<'EOS'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert('RGB')
want = tuple(int(x) for x in sys.argv[2].split(','))
w, h = im.size
px = im.load()
xs = [x for x in range(0, w, 2) if px[x, h // 2] == want]
ys = [y for y in range(0, h, 2) if px[w // 2, y] == want]
print(min(xs), min(ys), max(xs), max(ys)) if xs and ys else print("none")
EOS
}
# PART/WHOLE within 8% of REF/REFWHOLE
share() { awk -v p="$1" -v w="$2" -v r="$3" -v rw="$4" 'BEGIN { q = (p / w) / (r / rw); exit !(q > 0.92 && q < 1.08) }'; }
pct() { awk -v p="$1" -v w="$2" 'BEGIN { printf "%.1f%%", p / w * 100 }'; }
logpixels() {
    v=$(wine reg query 'HKCU\Control Panel\Desktop' /v LogPixels 2>/dev/null | tr -d '\r' | awk '$1 == "LogPixels" { print $3 }')
    [ -n "$v" ] && printf '%d\n' "$v"
}
reset() { wine reg delete 'HKCU\Control Panel\Desktop' /v LogPixels /f >/dev/null 2>&1; rm -f "$T"/run/sg-ui-scale.*; wineserver -w; }

# Setup's window, as sg-login-ui starts it on the live medium: LIB EXE -> its height
setup_h() {
    reset
    rm -f "$T/setup.log"
    sleep 300 | env SG_LIB="$1" SG_SETUP_BRIDGED=1 sh "$1/sg-ui-scale" wine "$2" >/dev/null 2>"$T/setup.log" & P=$!
    i=0; until grep -q 'page welcome' "$T/setup.log" 2>/dev/null; do sleep 0.5; i=$((i + 1)); [ $i -lt 120 ] || break; done
    sleep 3
    import -window root "$T/setup.png" 2>/dev/null
    kill "$P" 2>/dev/null; P=""; wineserver -k 2>/dev/null; sleep 1
    b=$(box "$T/setup.png" 255,255,255)
    set -- $b
    [ $# = 4 ] && echo $(( $4 - $2 )) || echo 0
}
h=$(setup_h "$T/lib" "$SETUP")
lp=$(logpixels)
share "$h" 1824 600 1080 && [ "$lp" = 168 ] \
    && pass "Setup at 2736x1824: its account at 175% (LogPixels $lp), its window $h px tall, $(pct "$h" 1824) of the screen (1080p: 600 px, 55.6%)" \
    || fail "Setup at 2736x1824: LogPixels '$lp', window $h px ($(pct "$h" 1824), want about 55.6%)"
cp "$T/setup.png" "$T/setup-scaled.png"
python3 - "$T/setup-scaled.png" <<'EOS' && pass "Setup's backdrop reaches the screen's bottom (no black band)" || fail "Setup's backdrop leaves black at the bottom"
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert('RGB'); w, h = im.size
black = sum(1 for x in range(0, w - 100, 8) if im.getpixel((x, h - 20)) == (0, 0, 0))
sys.exit(1 if black > 20 else 0)
EOS

# the first-run setup: its card
reset
sleep 300 | env SG_LIB="$T/lib" sh "$T/lib/sg-ui-scale" wine "$BUILD/sg-oobe64.exe" >/dev/null 2>&1 & P=$!
i=0; until xwininfo -root -tree 2>/dev/null | grep -q 'Stained Glass OS setup'; do sleep 0.5; i=$((i + 1)); [ $i -lt 120 ] || break; done
sleep 4
import -window root "$T/oobe.png" 2>/dev/null
kill "$P" 2>/dev/null; P=""; wineserver -k 2>/dev/null; sleep 1
set -- $(box "$T/oobe.png" 34,16,66)
h=$(( ${4:-0} - ${2:-0} ))
share "$h" 1824 640 1080 && pass "the first-run setup at 2736x1824: its card $h px tall, $(pct "$h" 1824) of the screen (1080p: 640 px, 59.3%)" \
    || fail "the first-run setup: card $h px ($(pct "$h" 1824), want about 59.3%)"

# --- Linux programs ----------------------------------------------------------------------
size() {   # NAME: WIDTHxHEIGHT of the window called NAME
    xwininfo -name "$1" 2>/dev/null | awk '/Width:/ {w=$2} /Height:/ {h=$2} END {print w "x" h}'
}
linux_ratio() {   # LIB PERCENT: the GTK 3 and GTK 4 windows' widths at PERCENT over theirs at 100%
    for pc in 100 "$2"; do
        xrdb -remove 2>/dev/null
        env -i PATH="$PATH" HOME="$HOME" DISPLAY="$DISPLAY" XDG_RUNTIME_DIR="$T/run" GDK_BACKEND=x11 SG_LIB="$1" \
            sh -c '. "$SG_LIB/sg-common.sh" >/dev/null 2>&1; sg_linux_scale_env "$1"; exec "$2"' sh "$pc" "$T/gtk3probe" >/dev/null 2>&1 &
        q=$!; sleep 3; s3=$(size sg-gtk3-probe); kill $q 2>/dev/null
        s4=""
        if command -v zenity >/dev/null 2>&1; then
            env -i PATH="$PATH" HOME="$HOME" DISPLAY="$DISPLAY" XDG_RUNTIME_DIR="$T/run" GDK_BACKEND=x11 SG_LIB="$1" \
                sh -c '. "$SG_LIB/sg-common.sh" >/dev/null 2>&1; sg_linux_scale_env "$1"; exec zenity --info --title=sg-zen --text="Stained Glass OS"' sh "$pc" >/dev/null 2>&1 &
            q=$!; sleep 4; s4=$(size sg-zen); kill $q 2>/dev/null
        fi
        eval "g3_$pc=\${s3%x*} g4_$pc=\${s4%x*}"
    done
    eval "echo \$g3_100 \$g3_$2 \${g4_100:-0} \${g4_$2:-0}"
}
ratio_ok() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > 0 && b / a >= 1.6 && b / a <= 2.1) }'; }
set -- $(linux_ratio "$HERE/lib" 175)
if ratio_ok "${1:-0}" "${2:-0}" && { [ "${3:-0}" = 0 ] || ratio_ok "$3" "$4"; }; then
    pass "Linux programs at 175%: GTK 3 ${1} -> ${2} px wide, GTK 4 (zenity) ${3} -> ${4}"
else
    fail "Linux programs at 175%: GTK 3 ${1:-?} -> ${2:-?}, GTK 4 ${3:-?} -> ${4:-?} (want 1.6 to 2.1 times)"
fi

# --- mutants: each must fail what it breaks ------------------------------------------------
mkdir -p "$T/mut"
cp "$T/lib/sg-ui-scale" "$T/mut/"
sed 's/^sg_ui_scale() {$/sg_ui_scale() { return 0/' "$T/lib/sg-common.sh" > "$T/mut/sg-common.sh"
h=$(setup_h "$T/mut" "$SETUP")
share "$h" 1824 600 1080 && fail "MUTANT UI_NO_SCALE not caught ($h px)" || pass "MUTANT UI_NO_SCALE caught: Setup $h px tall ($(pct "$h" 1824))"
sed 's/^sg_linux_scale_env() {$/sg_linux_scale_env() { return 0/' "$T/lib/sg-common.sh" > "$T/mut/sg-common.sh"
set -- $(linux_ratio "$T/mut" 175)
ratio_ok "${1:-0}" "${2:-0}" && fail "MUTANT LINUX_NO_SCALE not caught" || pass "MUTANT LINUX_NO_SCALE caught: GTK 3 ${1:-?} -> ${2:-?}"

[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
