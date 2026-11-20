#!/bin/sh
. "$(dirname "$0")/scratch-home.sh"
# The login and lock screens fill the screen again when it changes size
# (greeter/sg-greeter.c fit_screen). David 2026-11-20: after the monitor slept,
# the lock screen often covered only the top-left quarter. A DisplayPort monitor
# that sleeps leaves the system, the lock screen's X server came up at a stand-in
# size, and the greeter measured the screen once.
# The greeter runs in a Wine virtual desktop on Xvfb. A probe changes the
# desktop's resolution (ChangeDisplaySettings: the same WM_DISPLAYCHANGE a
# monitor coming back sends), then reads the greeter window and its power button.
# Mutant SG_MUTANT_GREETER_FIXED_SIZE (measured once) must fail.
#   SG_WINE_DIR=/opt/wine-sg sh test/greeter-fit-test.sh
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WINE_DIR="${SG_WINE_DIR:-/opt/wine-sg}"
MINGW="${MINGW64:-x86_64-w64-mingw32-gcc}"
command -v Xvfb >/dev/null || { echo "SKIP: Xvfb missing"; exit 77; }
command -v "$MINGW" >/dev/null || { echo "SKIP: no mingw"; exit 77; }
[ -x "$WINE_DIR/bin/wine" ] || { echo "SKIP: no wine at $WINE_DIR"; exit 77; }
T=$(mktemp -d /var/tmp/sg-greeter-fit.XXXXXX); XP=; RC=0
unset DISPLAY WAYLAND_DISPLAY
export HOME="$T/home" WINEPREFIX="$T/pfx" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=;winemenubuilder.exe=d" PATH="$WINE_DIR/bin:$PATH"
mkdir -p "$HOME"
trap 'exec 3>&- 2>/dev/null; wineserver -k 2>/dev/null; [ -n "$XP" ] && kill "$XP" 2>/dev/null; rm -rf "$T"' EXIT INT TERM
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }

L="-lole32 -luuid -lgdi32 -luser32"
"$MINGW" -O2 -mwindows -o "$T/greeter.exe" "$HERE/greeter/sg-greeter.c" $L 2>"$T/cc.log" \
    && "$MINGW" -O2 -mwindows -DSG_MUTANT_GREETER_FIXED_SIZE -o "$T/mutant.exe" "$HERE/greeter/sg-greeter.c" $L 2>>"$T/cc.log" \
    || { echo "FAIL  build"; cat "$T/cc.log"; exit 1; }
cat > "$T/probe.c" <<'EOC'
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main( int argc, char **argv )
{
    if (argc > 3 && !strcmp( argv[1], "set" ))
    {
        DEVMODEA dm = { .dmSize = sizeof(dm) };
        dm.dmPelsWidth = atoi( argv[2] ); dm.dmPelsHeight = atoi( argv[3] );
        dm.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT;
        printf( "set %ld\n", ChangeDisplaySettingsExA( NULL, &dm, NULL, 0, NULL ) );
        return 0;
    }
    HWND h = FindWindowA( "SgGreeter", NULL ), p = h ? GetDlgItem( h, 106 ) : NULL;
    RECT r = {0}, b = {0};
    if (h) GetWindowRect( h, &r );
    if (p) GetWindowRect( p, &b );
    printf( "screen %dx%d window %ldx%ld power %ld,%ld\n", GetSystemMetrics( SM_CXSCREEN ),
            GetSystemMetrics( SM_CYSCREEN ), r.right - r.left, r.bottom - r.top, b.left, b.top );
    return 0;
}
EOC
"$MINGW" -O2 -o "$T/probe.exe" "$T/probe.c" -luser32 2>>"$T/cc.log" || { echo "FAIL  probe build"; cat "$T/cc.log"; exit 1; }

Xvfb -displayfd 3 -screen 0 1920x1080x24 -nolisten tcp 3>"$T/xvfb.display" >/dev/null 2>&1 & XP=$!
_x=0; while [ ! -s "$T/xvfb.display" ] && [ $_x -lt 100 ]; do sleep 0.1; _x=$((_x + 1)); done
[ -s "$T/xvfb.display" ] || { echo "FAIL  Xvfb did not start"; exit 1; }
export DISPLAY=":$(cat "$T/xvfb.display")"
timeout -s KILL 300 wine wineboot -i >/dev/null 2>&1; wineserver -w
# every program in a 1024x768 virtual desktop: the stand-in size
wine reg add 'HKCU\Software\Wine\Explorer' /v Desktop /d Default /f >/dev/null 2>&1
wine reg add 'HKCU\Software\Wine\Explorer\Desktops' /v Default /d 1024x768 /f >/dev/null 2>&1
wineserver -w
probe() { timeout -s KILL 60 wine "$T/probe.exe" "$@" 2>/dev/null | tr -d '\r'; }

run() {   # exe label
    mkfifo "$T/in.$2"
    wine "$1" /lock someone < "$T/in.$2" > /dev/null 2>&1 &
    exec 3> "$T/in.$2"
    i=0; while [ $i -lt 60 ] && ! probe | grep -q 'window [1-9]'; do sleep 0.5; i=$((i + 1)); done
    printf 'READY\n' >&3
    before=$(probe)
    probe set 1600 900 >/dev/null
    sleep 3
    after=$(probe)
    exec 3>&-
    wineserver -k 2>/dev/null; wineserver -w 2>/dev/null
    probe set 1024 768 >/dev/null 2>&1; wineserver -k 2>/dev/null; wineserver -w 2>/dev/null
}

run "$T/greeter.exe" fix
case "$before" in *"screen 1024x768 window 1024x768 "*) pass "starts filling the stand-in screen ($before)";;
    *) fail "at start: $before";; esac
case "$after" in *"screen 1600x900 window 1600x900 power 1528,828"*)
        pass "the screen grew: the lock screen fills it, the power button at its corner ($after)";;
    *) fail "after the screen grew: $after";; esac

run "$T/mutant.exe" mutant
case "$after" in *"screen 1600x900 window 1600x900 "*) fail "mutant GREETER_FIXED_SIZE passed: $after";;
    *"screen 1600x900 "*) pass "MUTANT GREETER_FIXED_SIZE: stays in the corner (gate catches it: $after)";;
    *) fail "mutant run never changed the screen: $after";; esac

[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
