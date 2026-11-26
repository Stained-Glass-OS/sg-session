#!/bin/sh
. "$(dirname "$0")/scratch-home.sh"
# sg-session-check's 32-bit Notepad check finds the 32-bit Notepad's own
# window, and returns only once it is up (i0637). In next33's install gate the
# check took the closing 64-bit Notepad's window -- it outlives its process
# for a moment -- for the 32-bit one, passed and returned; the 32-bit Notepad's
# window came up seconds later, over the Setup the gate had opened meanwhile,
# and took the keys meant for Setup.
#
# No session, no Wine, no X: wine, pgrep, pkill, xwininfo and xprop are stand-ins
# on PATH, over a clock. The 64-bit Notepad's window appears 1 s after its
# start and stays 1.5 s after it is killed; the 32-bit one's appears 3 s after
# its start. When the check returns, the 32-bit window must be up.
#
#   test/session-check-np32-test.sh [--mutant ANY_NOTEPAD]
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
MUTANT=""
[ "${1:-}" = --mutant ] && MUTANT=${2:-}
T=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-npcheck.XXXXXX") || exit 1
S=$T/state; B=$T/bin; mkdir -p "$S" "$B" "$T/prefix/drive_c/windows/syswow64"
cleanup() {
    for f in "$S"/*.pid "$T/explorer.pid"; do
        [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null
    done
    rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# a 32-bit PE header: the offset at 0x3c, then "PE\0\0" and machine 0x014c
python3 - "$T/prefix/drive_c/windows/syswow64/notepad.exe" <<'EOF'
import struct, sys
b = bytearray(0x100); b[0:2] = b"MZ"; struct.pack_into("<I", b, 0x3c, 0x80)
b[0x80:0x84] = b"PE\0\0"; struct.pack_into("<H", b, 0x84, 0x014c)
open(sys.argv[1], "wb").write(b)
EOF

# the stand-in explorer: a process whose command line names explorer.exe and
# whose environment says x11
cp "$(command -v sleep)" "$T/explorer.exe"
env XDG_SESSION_TYPE=x11 "$T/explorer.exe" 600 &
echo $! > "$T/explorer.pid"

now='$(python3 -c "import time; print(int(time.time() * 1000))")'
cat > "$B/wine" <<EOF
#!/bin/sh
case "\$*" in
    *syswow64*) n=np32 ;;
    *notepad*) n=np64 ;;
    *) exit 0 ;;
esac
echo \$\$ > "$S/\$n.pid"; echo $now > "$S/\$n.start"
exec sleep 600
EOF
cat > "$B/pkill" <<EOF
#!/bin/sh
case "\$*" in *notepad*) ;; *) exit 1 ;; esac
for n in np64 np32; do
    [ -f "$S/\$n.pid" ] && [ ! -f "$S/\$n.killed" ] && { kill "\$(cat "$S/\$n.pid")" 2>/dev/null; echo $now > "$S/\$n.killed"; }
done
exit 0
EOF
cat > "$B/pgrep" <<EOF
#!/bin/sh
case "\$*" in
    *"-u "[a-z]*) exit 1 ;;            # another account's processes: none
    *wineserver*) echo 1 ;;
    *explorer*) cat "$T/explorer.pid" ;;
    *syswow64*) [ -f "$S/np32.pid" ] && [ ! -f "$S/np32.killed" ] && cat "$S/np32.pid" ;;
    *notepad*) for n in np64 np32; do [ -f "$S/\$n.pid" ] && [ ! -f "$S/\$n.killed" ] && cat "$S/\$n.pid"; done ;;
    *) exit 1 ;;
esac | grep . || exit 1
EOF
# up NAME SHOWN_AFTER_MS LINGER_MS: is the window of NAME on the screen now
cat > "$B/sg-np-up" <<EOF
#!/bin/sh
[ -f "$S/\$1.start" ] || exit 1
t=$now
[ "\$t" -ge \$(( \$(cat "$S/\$1.start") + \$2 )) ] || exit 1
[ ! -f "$S/\$1.killed" ] || [ "\$t" -lt \$(( \$(cat "$S/\$1.killed") + \$3 )) ]
EOF
cat > "$B/xwininfo" <<EOF
#!/bin/sh
case "\$*" in
    *-root*) echo '     0x100 "shell - Wine Desktop": ("explorer.exe" "explorer.exe")  1280x800+0+0  +0+0' ;;
    *)
        sg-np-up np32 3000 0 && echo '     0x400 "Notepad": ("notepad.exe" "notepad.exe")  900x640+0+0  +0+0'
        sg-np-up np64 1000 1500 && echo '     0x300 "Notepad": ("notepad.exe" "notepad.exe")  900x640+0+0  +0+0'
        echo '     0x200 (has no name): ("explorer.exe" "explorer.exe")  1280x40+0+760  +0+760' ;;
esac
EOF
cat > "$B/xprop" <<EOF
#!/bin/sh
case "\$*" in
    *0x300*) echo "_NET_WM_PID(CARDINAL) = \$(cat "$S/np64.pid")" ;;
    *0x400*) echo "_NET_WM_PID(CARDINAL) = \$(cat "$S/np32.pid")" ;;
    *) exit 1 ;;
esac
EOF
chmod 755 "$B"/*
printf 'DISPLAY=:97\nSG_DISPLAY_PATH=x11\n' > "$T/session.env"

out=$(env PATH="$B:$PATH" SG_LIB="$HERE/lib" SG_SESSION_ENV="$T/session.env" SG_PREFIX="$T/prefix" \
    SG_WINE_DIR=/nonexistent SG_SYSTEM_USER=sg-nobody-here SG_CHECK_TIMEOUT=20 SG_CHECK_MUTANT="$MUTANT" \
    sh "$HERE/bin/sg-session-check" 2>&1)
rc=$?
if env PATH="$B:$PATH" sg-np-up np32 3000 0; then up=1; else up=0; fi
RC=0
if [ $rc -eq 0 ] && echo "$out" | grep -q '^PASS  32-bit app runs in the shell'; then
    echo "PASS  the check passes the 32-bit Notepad"
else echo "FAIL  the check (exit $rc):"; echo "$out" | sed 's/^/      /'; RC=1; fi
if [ $up = 1 ]; then echo "PASS  ...and returns with the 32-bit Notepad's window up, none still to come"
else echo "FAIL  the check returned before the 32-bit Notepad's window was up: it took another window for it"
    echo "$out" | grep -i notepad | sed 's/^/      /'; RC=1; fi
exit $RC
