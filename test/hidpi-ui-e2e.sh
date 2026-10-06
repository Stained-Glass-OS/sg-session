#!/bin/sh
. "$(dirname "$0")/scratch-home.sh"
# Install-time and Linux programs on a high-resolution screen (David
# 2026-10-05, a Surface Pro 7 at 2736x1824: "everything is tiny"; Setup on
# the live medium, the first-run setup and the login screen must be usable).
# Under Xvfb at 2736x1824, with a real Wine:
#   1. Setup, started as sg-login-ui starts it (lib/sg-ui-scale), is given
#      the recommended 175% in its environment (SG_LOGPIXELS, wine-sg 0882;
#      nothing written to its account's registry) and Wine draws it at that
#      scale: its window takes the share of the screen's height it takes at
#      1080p (600 of 1080 lines, within 8%), and the backdrop reaches the
#      screen's bottom (a 1042-line screen was left a black band)
#   2. the first-run setup (sg-oobe) likewise: its card 640/1080 of the height
#   3. a GTK 3 program, a GTK 4 one (zenity) and a Qt one (if the system's
#      Python has PyQt6 or PyQt5) started at 100% (sg_linux_scale_env)
#      follow Settings' change to 175% while they run (sg-display-scale,
#      the session's XSETTINGS manager): GTK 1.6 to 2.1 times their width,
#      Qt exactly 1.75 times
# Xvfb runs with -noreset, as Xwayland keeps its resources (its window
# manager stays connected). Needs Xvfb, xwininfo, ImageMagick (import), python3 with PIL, wine and
# 'make greeter'. SG_WINE_DIR: another Wine (its bin/ goes first in PATH).
# Mutants: sg-ui-scale doing nothing (a copy of the library whose
# sg_ui_scale returns at once), SG_MUTANT_BACKDROP_SHORT (Setup built with
# it: MUTANT_SETUP=<exe>), LINUX_NOT_LIVE (sg_linux_scale doing nothing).
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
BUILD="$HERE/build"
SETUP="${MUTANT_SETUP:-$BUILD/sg-setup64.exe}"
[ -n "${SG_WINE_DIR:-}" ] && PATH="$SG_WINE_DIR/bin:$PATH" && export PATH
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
for t in Xvfb xwininfo xrdb xsettingsd import wine python3 cc; do command -v "$t" >/dev/null || { echo "SKIP: $t missing"; exit 77; }; done
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
mkdir -p "$T/run" "$T/lib" "$T/drm/card0-eDP-1"
# the kernel's view of the screen (sg_drm_size reads the preferred mode): a
# Surface Pro 7's panel, as Xvfb is
echo connected > "$T/drm/card0-eDP-1/status"; printf '2736x1824\n1920x1080\n' > "$T/drm/card0-eDP-1/modes"
export SG_DRM_SYSFS="$T/drm"
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
share "$h" 1824 600 1080 && [ -z "$lp" ] \
    && pass "Setup at 2736x1824: at 175% (SG_LOGPIXELS, nothing written to its account), its window $h px tall, $(pct "$h" 1824) of the screen (1080p: 600 px, 55.6%)" \
    || fail "Setup at 2736x1824: LogPixels written '$lp', window $h px ($(pct "$h" 1824), want about 55.6%)"
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
# a Qt window of 400x300 (Qt 6, else 5, through the system's Python), if there is one
QTPY=""
for q in PyQt6 PyQt5; do
    /usr/bin/python3 -c "import $q.QtWidgets" 2>/dev/null && { QTPY=$q; break; }
done
cat > "$T/qtprobe.py" <<EOS
import sys
from $QTPY import QtWidgets, QtCore
app = QtWidgets.QApplication(sys.argv)
w = QtWidgets.QWidget(); w.resize(400, 300); w.setWindowTitle("sg-qt-probe"); w.show()
QtCore.QTimer.singleShot(30000, app.quit)
(app.exec if hasattr(app, "exec") else app.exec_)()
EOS
# LIB PERCENT: the session started at 100% (sg_linux_scale_env), the GTK 3,
# GTK 4 (zenity) and Qt windows measured; then Settings' change to PERCENT
# while they run (sg-display-scale) and the same windows measured again.
# Prints: gtk3 before after, gtk4 before after, qt before after (widths; 0: none)
linux_live() {
    xrdb -remove 2>/dev/null
    rm -f "$T/run"/sg-xsettings*
    E="env -i PATH=$PATH HOME=$HOME DISPLAY=$DISPLAY XDG_RUNTIME_DIR=$T/run GDK_BACKEND=x11 QT_QPA_PLATFORM=xcb SG_LIB=$1 SG_LOG_DIR=$T"
    $E sh -c '. "$SG_LIB/sg-common.sh" >/dev/null 2>&1; sg_linux_scale_env 100' >/dev/null 2>&1
    sleep 1
    pids=""
    $E sh -c '. "$SG_LIB/sg-common.sh" >/dev/null 2>&1; sg_linux_scale_env 100; exec "$1"' sh "$T/gtk3probe" >/dev/null 2>&1 & pids="$pids $!"
    command -v zenity >/dev/null 2>&1 && { $E sh -c '. "$SG_LIB/sg-common.sh" >/dev/null 2>&1; sg_linux_scale_env 100; exec zenity --info --title=sg-zen --text="Stained Glass OS"' >/dev/null 2>&1 & pids="$pids $!"; }
    [ -n "$QTPY" ] && { $E sh -c '. "$SG_LIB/sg-common.sh" >/dev/null 2>&1; sg_linux_scale_env 100; exec /usr/bin/python3 "$1"' sh "$T/qtprobe.py" >/dev/null 2>&1 & pids="$pids $!"; }
    sleep 5
    a3=$(size sg-gtk3-probe); a4=$(size sg-zen); aq=$(size sg-qt-probe)
    $E sh "$1/sg-display-scale" "$2" >/dev/null 2>&1
    sleep 4
    b3=$(size sg-gtk3-probe); b4=$(size sg-zen); bq=$(size sg-qt-probe)
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null
    pkill -P $$ zenity 2>/dev/null
    k=$(cat "$T"/run/sg-xsettings*.pid 2>/dev/null); [ -n "$k" ] && kill "$k" 2>/dev/null
    echo "${a3%x*} ${b3%x*} ${a4%x*} ${b4%x*} ${aq%x*} ${bq%x*}" | sed 's/  */ /g; s/^ //' | awk '{for (i = 1; i <= 6; i++) printf "%s ", ($i == "" ? 0 : $i); print ""}'
}
ratio_in() { awk -v a="$1" -v b="$2" -v lo="$3" -v hi="$4" 'BEGIN { exit !(a > 0 && b / a >= lo && b / a <= hi) }'; }
# our GTK (sg-image gtk-scale, version +sg...) draws at the scale itself:
# 1.75 times; Debian's at the next whole step, 2
g3lo=1.6 g3hi=2.1 g4lo=1.6 g4hi=2.1
case "$(dpkg-query -W -f='${Version}' libgtk-3-0t64 2>/dev/null)" in *+sg*) g3lo=1.73 g3hi=1.77 ;; esac
case "$(dpkg-query -W -f='${Version}' libgtk-4-1 2>/dev/null)" in *+sg*) g4lo=1.73 g4hi=1.77 ;; esac
set -- $(linux_live "$HERE/lib" 175)
ok=1
ratio_in "$1" "$2" $g3lo $g3hi || ok=0
[ "$3" = 0 ] || ratio_in "$3" "$4" $g4lo $g4hi || ok=0
[ "$5" = 0 ] || ratio_in "$5" "$6" 1.73 1.77 || ok=0
if [ $ok = 1 ]; then
    pass "Linux programs follow 100% -> 175% while they run: GTK 3 $1 -> $2 px wide ($g3lo-$g3hi times), GTK 4 (zenity) $3 -> $4 ($g4lo-$g4hi), Qt ($QTPY) $5 -> $6 (exactly 1.75 times)"
else
    fail "Linux programs, 100% -> 175% while they run: GTK 3 $1 -> $2 (want $g3lo-$g3hi times), GTK 4 $3 -> $4 (want $g4lo-$g4hi), Qt $5 -> $6 (want 1.75 times)"
fi

# --- mutants: each must fail what it breaks ------------------------------------------------
mkdir -p "$T/mut"
cp "$T/lib/sg-ui-scale" "$T/mut/"
sed 's/^sg_ui_scale() {$/sg_ui_scale() { return 0/' "$T/lib/sg-common.sh" > "$T/mut/sg-common.sh"
h=$(setup_h "$T/mut" "$SETUP")
share "$h" 1824 600 1080 && fail "MUTANT UI_NO_SCALE not caught ($h px)" || pass "MUTANT UI_NO_SCALE caught: Setup $h px tall ($(pct "$h" 1824))"
sed 's/^sg_linux_scale() {$/sg_linux_scale() { return 0/' "$T/lib/sg-common.sh" > "$T/mut/sg-common.sh"
cp "$HERE/lib/sg-display-scale" "$T/mut/"
set -- $(linux_live "$T/mut" 175)
ratio_in "${1:-0}" "${2:-0}" 1.6 2.1 && fail "MUTANT LINUX_NOT_LIVE not caught" || pass "MUTANT LINUX_NOT_LIVE caught: GTK 3 ${1:-?} -> ${2:-?}"

[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
