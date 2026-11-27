#!/bin/sh
. "$(dirname "$0")/scratch-home.sh"
# Windowed Setup fits the screen (i0555). Setup started from the live desktop
# is a framed window of 800x568 client; on an 800x600 screen the taskbar
# leaves less than that and Setup's bottom row -- the status line, the
# buttons' lower edge -- sat under the taskbar. As on Windows when Setup's
# window is larger than the work area, it is laid out full screen: in the
# foreground filling the monitor, the taskbar goes behind it. It stays
# windowed Setup: its own caption's Close, no Shut down.
#
# Under Xvfb, a scratch prefix whose shell (explorer) owns the taskbar:
#   - 800x600: the taskbar takes part of the screen (the case is real); what
#     is at Setup's bottom edge and at its Next button is Setup, not the
#     taskbar; its window lies on the screen; Close, no Shut down;
#   - 1280x800: as before, a framed window inside the work area.
#
#   SG_SETUP_EXE  the wizard (default build/sg-setup64.exe; a mutant built
#                 with -DSG_MUTANT_SETUP_ALWAYS_FRAMED must fail)
#   SG_WINE_DIR   the Wine to run (default /opt/wine-sg)
# Runs on the host inside /var/tmp/sgwork/netns-run.sh (Xvfb listens).
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
EXE=${SG_SETUP_EXE:-$HERE/build/sg-setup64.exe}
PROBE=$HERE/build/setup-fit-probe.exe
W=${SG_WINE_DIR:-/opt/wine-sg}
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
for t in Xvfb python3; do command -v "$t" >/dev/null || { echo "SKIP: $t not installed"; exit 77; }; done
[ -x "$W/bin/wine" ] || { echo "SKIP: no Wine at $W"; exit 77; }
[ -f "$EXE" ] || { echo "SKIP: no $EXE (make greeter)"; exit 77; }
[ -f "$PROBE" ] || { echo "SKIP: no $PROBE (make setup-fit-probe)"; exit 77; }

T=$(mktemp -d /var/tmp/sg-setupfit.XXXXXX)
export WINEPREFIX="$T/pfx" WINEDEBUG=-all PATH="$W/bin:$PATH"
XP=""
cleanup() {
    wineserver -k 2>/dev/null
    [ -n "$XP" ] && kill "$XP" 2>/dev/null
    if [ -n "${SG_KEEP:-}" ]; then echo "kept $T"; else rm -rf "$T"; fi
}
trap cleanup EXIT INT TERM
nap() { python3 -c "import time; time.sleep($1)"; }
v() { sed -n "s/^$2 //p" "$1" | head -1; }

D=:$((300 + $$ % 300))
Xvfb "$D" -screen 0 1280x800x24 -nolisten tcp >/dev/null 2>&1 &
XP=$!
export DISPLAY=$D
nap 1
wineboot -i >/dev/null 2>&1
wineserver -w
cp "$EXE" "$WINEPREFIX/drive_c/sg-setup64.exe"
cp "$PROBE" "$WINEPREFIX/drive_c/probe.exe"

# run_case SIZE: Setup, windowed, in a shell desktop of SIZE; the probe's answers in $T/SIZE.txt
run_case() {
    S=$1
    mkfifo "$T/in.$S"
    wine explorer.exe /desktop=shell,"$S" >/dev/null 2>&1 &
    for i in $(seq 40); do wine cmd /c 'echo up' >/dev/null 2>&1 && break; nap 0.5; done
    nap 6
    python3 -c 'import sys, time; f = open(sys.argv[1], "w"); time.sleep(120)' "$T/in.$S" &
    H=$!
    SG_SETUP_BRIDGED=1 wine 'C:\sg-setup64.exe' --windowed < "$T/in.$S" > "$T/out.$S" 2> "$T/err.$S" &
    timeout 90 wine 'C:\probe.exe' > "$T/$S.txt" 2>/dev/null
    tr -d '\r' < "$T/$S.txt" > "$T/$S.t" && mv "$T/$S.t" "$T/$S.txt"
    kill "$H" 2>/dev/null
    wineserver -k; wineserver -w
}

run_case 800x600
F=$T/800x600.txt
set -- $(v "$F" SETUP); SL=${1:-0} ST=${2:-0} SR=${3:-0} SB=${4:-0} CAP=${5:-0}
set -- $(v "$F" WORK); WB=${4:-0}
set -- $(v "$F" MONITOR); MR=${3:-0} MB=${4:-0}
if [ "$(v "$F" TRAY | cut -d" " -f1)" = 1 ] && [ "$WB" -gt 0 ] && [ "$WB" -lt "$MB" ]; then
    pass "800x600: the taskbar takes part of the screen (work area to $WB of $MB)"
else
    fail "800x600: no taskbar or no smaller work area ($(tr '\n' ' ' < "$F"))"
fi
[ "$(v "$F" 'HIT bottom' | awk '{print $3}')" = setup ] && [ "$(v "$F" 'HIT next' | awk '{print $3}')" = setup ] \
    && pass "800x600: Setup's bottom row and its Next button are Setup's, not under the taskbar" \
    || fail "800x600: at Setup's bottom '$(v "$F" 'HIT bottom')', at Next '$(v "$F" 'HIT next')' (window $SL $ST $SR $SB)"
# inside the work area, or full screen (exactly the monitor, no caption: the taskbar goes behind it)
if { [ "$SL" -ge 0 ] && [ "$ST" -ge 0 ] && [ "$SR" -le "$MR" ] && [ "$SB" -le "$WB" ]; } ||
   { [ "$SL $ST $SR $SB $CAP" = "0 0 $MR $MB 0" ]; }; then
    pass "800x600: its window fits: $SL,$ST-$SR,$SB (caption $CAP; work area to $WB)"
else
    fail "800x600: its window $SL,$ST-$SR,$SB (caption $CAP) neither in the work area (to $WB) nor full screen (${MR}x$MB)"
fi
[ "$(v "$F" BUTTONS)" = "close 1 power 0" ] && pass "800x600: still windowed Setup: Close, no Shut down" \
    || fail "800x600: its buttons: $(v "$F" BUTTONS)"

run_case 1280x800
F=$T/1280x800.txt
set -- $(v "$F" SETUP); SL=${1:-0} ST=${2:-0} SR=${3:-0} SB=${4:-0} CAP=${5:-0}
set -- $(v "$F" WORK); WL=${1:-0} WT=${2:-0} WR=${3:-0} WB=${4:-0}
[ "$CAP" = 1 ] && [ "$SL" -ge "$WL" ] && [ "$ST" -ge "$WT" ] && [ "$SR" -le "$WR" ] && [ "$SB" -le "$WB" ] \
    && [ "$(v "$F" BUTTONS)" = "close 0 power 0" ] \
    && pass "1280x800: a framed window inside the work area, as before" \
    || fail "1280x800: window $SL,$ST-$SR,$SB caption $CAP, work area $WL,$WT-$WR,$WB, $(v "$F" BUTTONS)"
[ "$(v "$F" 'HIT next' | awk '{print $3}')" = setup ] && pass "1280x800: its Next button is Setup's" \
    || fail "1280x800: at Next '$(v "$F" 'HIT next')'"

echo
if [ "$RC" -eq 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; fi
exit "$RC"
