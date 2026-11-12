#!/bin/sh
. "$(dirname "$0")/scratch-home.sh"
# Remote control through the portal (xdg-desktop-portal-sg), end to end.
#
# A session (a headless sg-compositor running a Windows program that logs
# what it receives), sg-brokerd for the person's answer, a private PipeWire
# and D-Bus, the real portal frontend with our backend, and a client that does
# what remote support does: RemoteDesktop.CreateSession, SelectDevices,
# ScreenCast.SelectSources, Start, then clicks and types. The consent prompt is
# a stand-in that answers as told, run where the real one is: the gate checks
# the session was on its secure surface while the person was asked. Checks:
#
#   - the person says yes: Start answers with the keyboard and pointer and a
#     screen stream; a click and the typed text reach the program; a frame
#     shows round the screen while it lasts and goes when the session closes
#   - the person says no: Start is refused and nothing reaches the program
#   - Ctrl+Alt+Del at the console ends remote control: the portal closes the
#     session (Session.Closed) and the frame goes
#   - a program cannot type on its own: the compositor's public socket offers
#     it no virtual keyboard
#
# Mutant: SG_MUTANT_CAPTURE_NO_CONSENT (sg-brokerd: the person's answer
# ignored) fails the "no" case.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
BUILD="$HERE/build"
COMP="${SG_COMPOSITOR_BIN:-$HERE/../sg-compositor/build/sg-compositor}"
PORTAL="${SG_PORTAL_BIN:-$HERE/portal/xdg-desktop-portal-sg}"
BROKER="${SG_BROKERD_BIN:-$BUILD/sg-brokerd}"
FRONTEND=/usr/libexec/xdg-desktop-portal
WINE_DIR="${SG_WINE_DIR:-/opt/wine-sg}"
RC=0
KPID=""; BPID=""; PWPID=""; DBPID=""; FEPID=""; BEPID=""

pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }

for t in grim python3 pipewire dbus-daemon convert x86_64-w64-mingw32-gcc; do
    command -v "$t" >/dev/null 2>&1 || { echo "SKIP: $t not installed"; exit 77; }
done
PY="${SG_PYTHON:-/usr/bin/python3}"   # the system's, which has GObject's bindings
"$PY" -c 'from gi.repository import Gio' 2>/dev/null || { echo "SKIP: python3-gi not installed"; exit 77; }
for f in "$COMP" "$PORTAL" "$BROKER" "$BUILD/sg-vkbd" "$FRONTEND" "$WINE_DIR/bin/wine"; do
    [ -e "$f" ] || { echo "SKIP: $f not built/installed"; exit 77; }
done

T=$(mktemp -d /var/tmp/sg-portal-rd.XXXXXX)
chmod 755 "$T"
export WINEPREFIX="$T/prefix" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=,winemenubuilder.exe=d"
SEAT="$T/seat/seat0/$(id -u)"
RUN="$T/run"
# shellcheck disable=SC2317  # invoked via trap
cleanup() {
    for p in $BEPID $FEPID $DBPID $PWPID $BPID $KPID; do kill "$p" 2>/dev/null; done
    "$WINE_DIR/bin/wineserver" -k 2>/dev/null
    if [ -n "${SG_KEEP:-}" ]; then echo "kept $T"; else rm -rf "$T"; fi
}
trap cleanup EXIT INT TERM

x86_64-w64-mingw32-gcc -O2 -mwindows -o "$T/rdp-target.exe" "$HERE/test/rdp-target.c" -lgdi32 -luser32 \
    || { fail "the target program did not build"; exit 1; }
"$WINE_DIR/bin/wineboot" -i >/dev/null 2>&1
"$WINE_DIR/bin/wineserver" -w
mkdir -p "$SEAT" "$RUN" "$T/portals" "$T/config/xdg-desktop-portal" "$T/pw"
chmod 700 "$RUN"

# The consent prompt's stand-in: records what it was asked and whether the
# session was on its secure surface then, and answers as $T/answer says.
cat > "$T/consent.sh" <<EOF
#!/bin/sh
st=\$(python3 -c 'import socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall(b"STATUS\n")
print(s.recv(64).decode().strip())' "\$(dirname "\$SG_LOCK_PRIV")/control.sock" 2>/dev/null)
echo "\$* status=\$st" >> "$T/consent-calls"
cat "$T/answer"
read -r _done
EOF
chmod +x "$T/consent.sh"

# The session: the compositor as the session user, its sockets where
# sg-session-start puts them, the target program as the desktop.
(XDG_RUNTIME_DIR="$RUN" SG_OUTPUT_SIZE=1024x768 WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman \
 exec "$COMP" -L "$SEAT/priv.sock" -C "$SEAT/control.sock" -U "$(id -u)" -- \
    env -u WAYLAND_DISPLAY "$WINE_DIR/bin/wine" "$T/rdp-target.exe" "$T/target.log" 2>"$T/console.log") &
KPID=$!

SG_BROKER_SOCK="$T/broker.sock" SG_BROKER_FOREGROUND=1 SG_BROKERD_LOG="$T/broker.log" SG_SEAT_DIR="$T/seat/seat0" \
SG_CONSENT_UI="$T/consent.sh" SG_CAPTURE_CONSENT_TIMEOUT=10 SG_BROKER_PAMCHECK=/bin/false \
    "$BROKER" >"$T/broker.out" 2>&1 &
BPID=$!

wait_log() {   # wait_log PATTERN FILE SECONDS
    _w=0; until grep -q "$1" "$2" 2>/dev/null || [ $_w -ge $(($3 * 5)) ]; do sleep 0.2; _w=$((_w + 1)); done
    grep -q "$1" "$2" 2>/dev/null
}
wait_log '^ready' "$T/target.log" 90 || { fail "the session did not start: $(tail -5 "$T/console.log")"; exit 1; }
WL=$(ls "$RUN" | grep -E '^wayland-[0-9]+$' | head -1)
[ -n "$WL" ] || { fail "the compositor made no Wayland socket in $RUN"; exit 1; }

# PipeWire and D-Bus of the gate's own; the portal's frontend with only our
# backend to choose from
PIPEWIRE_RUNTIME_DIR="$T/pw" XDG_RUNTIME_DIR="$RUN" pipewire >"$T/pipewire.log" 2>&1 &
PWPID=$!
dbus-daemon --session --nofork --print-address=3 3>"$T/bus" >/dev/null 2>&1 &
DBPID=$!
_w=0; until [ -s "$T/bus" ] || [ $_w -ge 50 ]; do sleep 0.1; _w=$((_w + 1)); done
BUS=$(head -1 "$T/bus")
cp "$HERE/portal/data/sg.portal" "$T/portals/"
printf '[preferred]\ndefault=none\norg.freedesktop.impl.portal.ScreenCast=sg\norg.freedesktop.impl.portal.RemoteDesktop=sg\n' \
    > "$T/portals/portals.conf"   # beside the .portal files, where XDG_DESKTOP_PORTAL_DIR has it looked for
export DBUS_SESSION_BUS_ADDRESS="$BUS"
WAYLAND_DISPLAY="$RUN/$WL" PIPEWIRE_RUNTIME_DIR="$T/pw" XDG_RUNTIME_DIR="$RUN" SG_PORTAL_BROKER_SOCK="$T/broker.sock" \
    "$PORTAL" -l INFO >"$T/backend.log" 2>&1 &
BEPID=$!
sleep 1
XDG_DESKTOP_PORTAL_DIR="$T/portals" XDG_CONFIG_HOME="$T/config" XDG_CURRENT_DESKTOP=SGGate XDG_RUNTIME_DIR="$RUN" \
    "$FRONTEND" -r -v >"$T/frontend.log" 2>&1 &
FEPID=$!
sleep 2

control() {   # control CMD: the compositor's answer
    python3 -c 'import socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall(sys.argv[2].encode() + b"\n")
print(s.recv(128).decode().strip())' "$SEAT/control.sock" "$1" 2>/dev/null
}
edge() {   # the session's own pixel at its left edge, as RRGGBB
    WAYLAND_DISPLAY="$SEAT/priv.sock" grim -t ppm "$T/screen.ppm" 2>/dev/null
    convert "$T/screen.ppm" -crop "1x1+1+384" -depth 8 txt:- 2>/dev/null | sed -n 's/.*#\([0-9A-Fa-f]\{6\}\).*/\1/p' | head -1
}
is_frame() {   # the remote-control frame's amber (#FFB400, give or take rounding)
    python3 -c 'import sys; c = sys.argv[1]
r, g, b = int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16)
sys.exit(0 if r >= 0xf8 and 0xa8 <= g <= 0xc0 and b <= 8 else 1)' "${1:-000000}" 2>/dev/null
}
chars() { tr -d '\r' < "$T/target.log" | sed -n 's/^char //p' | tr -d '\n'; }
clicks() { tr -d '\r' < "$T/target.log" | grep -c '^click'; }
calls() { grep -c . "$T/consent-calls" 2>/dev/null || echo 0; }
client() { "$PY" "$HERE/test/portal-rd-client.py" "$@" > "$T/client.out" 2>&1; }
vkbd() { WAYLAND_DISPLAY="$SEAT/priv.sock" "$BUILD/sg-vkbd" "$@"; sleep 1; }

# Teeth: the console's own keyboard reaches the program (twice: a new virtual
# keyboard's first press can be lost to Xwayland's keymap change).
vkbd "aa"
case "$(chars)" in *a*) ;; *) fail "the console's keyboard does not reach the program: '$(chars)'"; exit 1 ;; esac
before=$(chars)

# ---- a program cannot type on its own -------------------------------------
offered=$(WAYLAND_DISPLAY="$RUN/$WL" python3 - <<'EOS'
import ctypes, ctypes.util, os, socket, struct, sys
# wl_display.get_registry, sync; read the globals the public socket offers
s = socket.socket(socket.AF_UNIX); s.connect(os.environ['WAYLAND_DISPLAY'])
def msg(obj, op, payload): s.sendall(struct.pack('<IHH', obj, op, 8 + len(payload)) + payload)
msg(1, 1, struct.pack('<I', 2)); msg(1, 0, struct.pack('<I', 3))
buf = b''; names = []
s.settimeout(3)
try:
    while True:
        d = s.recv(65536)
        if not d: break
        buf += d
        while len(buf) >= 8:
            obj, op, size = struct.unpack('<IHH', buf[:8])
            if len(buf) < size: break
            body, buf = buf[8:size], buf[size:]
            if obj == 2 and op == 0:
                n = struct.unpack('<I', body[4:8])[0]
                names.append(body[8:8 + n - 1].decode())
            if obj == 3: raise StopIteration
except (StopIteration, socket.timeout):
    pass
print(' '.join(names))
EOS
)
case "$offered" in
    *wl_compositor*)
        case "$offered" in
            *zwp_virtual_keyboard_manager_v1*|*zwlr_virtual_pointer_manager_v1*)
                fail "the public socket offers a program the virtual keyboard or pointer" ;;
            *) pass "a program on its own is offered no virtual keyboard or pointer" ;;
        esac ;;
    *) fail "could not read the public socket's globals: '$offered'" ;;
esac

# ---- the person says yes ----------------------------------------------------
echo ALLOW > "$T/answer"
"$PY" "$HERE/test/portal-rd-client.py" --click 500 400 --type "hi portal" --hold 6 > "$T/client.out" 2>&1 &
CL=$!
sleep 4
during=$(edge)
wait "$CL"
start=$(grep '^start' "$T/client.out")
case "$start" in
    "start 0 devices=3 streams="[0-9]*) pass "yes: Start answers with the keyboard and pointer and a screen stream ($start)" ;;
    *) fail "yes: Start did not succeed: $(cat "$T/client.out"); $(tail -3 "$T/backend.log")" ;;
esac
grep -q 'capture status=OK secure\|capture .* status=OK secure' "$T/consent-calls" 2>/dev/null &&
    pass "the person was asked on the secure surface ($(tail -1 "$T/consent-calls"))" ||
    fail "the person was not asked on the secure surface: $(cat "$T/consent-calls" 2>/dev/null)"
case "$(chars)" in *"hi portal"*) pass "yes: the typed text reaches the program ('$(chars)')" ;;
    *) fail "yes: the typed text did not reach the program: '$(chars)'" ;; esac
[ "$(clicks)" -ge 1 ] && pass "yes: the click reaches the program ($(tr -d '\r' < "$T/target.log" | grep '^click' | tail -1))" ||
    fail "yes: no click reached the program"
is_frame "$during" && pass "a frame shows round the screen while it lasts (#$during)" || fail "no frame while it lasts: #$during"
sleep 1
after=$(edge)
is_frame "$after" && fail "the frame stays after the session closed (#$after)" || pass "the frame goes when the session closes (#$after)"

# ---- the person says no -----------------------------------------------------
echo DENY > "$T/answer"
n0=$(chars)
client --type "NO NO" --hold 1
case "$(grep '^start' "$T/client.out")" in
    "start 0"*) fail "no: Start succeeded" ;;
    "start "[1-9]*) pass "no: Start is refused ($(grep '^start' "$T/client.out"))" ;;
    *) fail "no: the client did not get to Start: $(cat "$T/client.out")" ;;
esac
[ "$(chars)" = "$n0" ] && pass "no: nothing reaches the program" || fail "no: the program got '$(chars)' (was '$n0')"

# ---- Ctrl+Alt+Del at the console ends it --------------------------------------
echo ALLOW > "$T/answer"
"$PY" "$HERE/test/portal-rd-client.py" --hold 20 > "$T/client.out" 2>&1 &
CL=$!
sleep 4
vkbd -M ctrl -M alt -k Delete -m alt -m ctrl
wait "$CL"
grep -q '^closed-by-portal' "$T/client.out" && pass "Ctrl+Alt+Del ends remote control: the portal closes the session" ||
    fail "Ctrl+Alt+Del: $(cat "$T/client.out"); $(control SHADOWSTATUS)"
control UNLOCK >/dev/null   # no lock service here
sleep 1
is_frame "$(edge)" && fail "the frame stays after Ctrl+Alt+Del" || pass "and the frame goes"

[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
