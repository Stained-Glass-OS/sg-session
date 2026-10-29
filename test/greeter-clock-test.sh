#!/bin/sh
. "$(dirname "$0")/scratch-home.sh"
# The sign-in and lock screens' clock (greeter/sg-greeter.c format_clock) in the region's
# own way: en-GB "Thursday 29 October" and a 24-hour time, en-US "Thursday, October 29".
# The region is the account's (sg-oobe-user --welcome gives the system accounts the
# first-run setup's). A probe built from the greeter's own source prints what it shows.
# Mutant SG_MUTANT_GREETER_US_DATE (the old fixed "dddd, MMMM d") must fail the en-GB case.
#   SG_WINE_DIR=/opt/wine-sg sh test/greeter-clock-test.sh
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WD="${SG_WINE_DIR:-/opt/wine-sg}"
WINE="$WD/bin/wine"; WINESERVER="$WD/bin/wineserver"
MINGW="${MINGW64:-x86_64-w64-mingw32-gcc}"
command -v "$MINGW" >/dev/null || { echo "SKIP: no mingw"; exit 77; }
[ -x "$WINE" ] || { echo "SKIP: no wine at $WINE"; exit 77; }
T=$(mktemp -d /var/tmp/sg-greeter-clock.XXXXXX)
unset DISPLAY WAYLAND_DISPLAY LANG LC_ALL LC_TIME
export HOME="$T/home" WINEPREFIX="$T/prefix" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=;winemenubuilder.exe=d" WINESERVER
mkdir -p "$HOME"
cleanup() { "$WINESERVER" -k 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT INT TERM
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
cat > "$T/probe.c" <<EOC
#define WinMain greeter_winmain
#include "$HERE/greeter/sg-greeter.c"
#undef WinMain
int main(void)
{
    char t[64], d[128];
    format_clock( t, sizeof(t), d, sizeof(d) );
    printf( "time %s\ndate %s\n", t, d );
    return 0;
}
EOC
L="-lole32 -luuid -lgdi32 -luser32"
"$MINGW" -O2 -o "$T/probe.exe" "$T/probe.c" $L 2>"$T/cc.log" || { echo "FAIL  probe build"; cat "$T/cc.log"; exit 1; }
"$MINGW" -O2 -DSG_MUTANT_GREETER_US_DATE -o "$T/mutant.exe" "$T/probe.c" $L 2>>"$T/cc.log" || { echo "FAIL  mutant build"; exit 1; }
timeout -s KILL 300 "$WINE" wineboot -i >/dev/null 2>&1
"$WINESERVER" -w
w() { timeout -s KILL 60 "$WINE" "$@" 2>/dev/null | tr -d '\r'; }
region() { w reg add 'HKCU\Control Panel\International' /v LocaleName /d "$1" /f >/dev/null; "$WINESERVER" -w; }
v() { printf '%s\n' "$1" | sed -n "s/^$2 //p" | head -1; }

region en-GB
out=$(w "$T/probe.exe")
echo "$(v "$out" date)" | grep -Eq '^[A-Z][a-z]+day [0-9]{1,2} [A-Z][a-z]+$' \
    && pass "en-GB: the weekday, then day and month ($(v "$out" date))" || fail "en-GB date: $out"
echo "$(v "$out" time)" | grep -Eq '^[0-2][0-9]:[0-5][0-9]$' \
    && pass "...and a 24-hour time ($(v "$out" time))" || fail "en-GB time: $out"
out=$(w "$T/mutant.exe")
echo "$(v "$out" date)" | grep -Eq '^[A-Z][a-z]+day [0-9]{1,2} [A-Z][a-z]+$' \
    && fail "mutant GREETER_US_DATE passed: $out" || pass "MUTANT GREETER_US_DATE: month first (gate catches it)"
region en-US
out=$(w "$T/probe.exe")
echo "$(v "$out" date)" | grep -Eq '^[A-Z][a-z]+day, [A-Z][a-z]+ [0-9]{1,2}$' \
    && pass "en-US: \"$(v "$out" date)\"" || fail "en-US date: $out"
[ $RC = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $RC
