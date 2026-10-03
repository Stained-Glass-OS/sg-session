#!/bin/sh
. "$(dirname "$0")/scratch-home.sh"
# sg-wine-reload (Ctrl+Alt+Backspace): this account's Windows processes --
# those running Wine's programs -- end, and nothing else does (David
# 2026-10-03). Stand-ins: a copy of sleep under a fake Wine directory, and
# an ordinary sleep.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d)
RC=0
mkdir -p "$T/wine/lib/wine/x86_64-unix"
cp "$(command -v sleep)" "$T/wine/lib/wine/x86_64-unix/wine"
"$T/wine/lib/wine/x86_64-unix/wine" 300 & W=$!
sleep 300 & O=$!
trap 'kill $W $O 2>/dev/null; rm -rf "$T"' EXIT
sleep 0.3
SG_LIB="$HERE/lib" SG_WINE_DIR="$T/wine" sh "$HERE/lib/sg-wine-reload" >/dev/null 2>&1
sleep 0.5
alive() { [ -d "/proc/$1" ] && ! grep -q '^[0-9]* (.*) Z' "/proc/$1/stat" 2>/dev/null; }
! alive $W && echo "PASS  a Windows process of this account ends" || { echo "FAIL  the Windows process was left"; RC=1; }
alive $O && echo "PASS  nothing else does" || { echo "FAIL  another process ended"; RC=1; }
exit $RC
