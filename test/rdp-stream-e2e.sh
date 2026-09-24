#!/bin/sh
# Remote Desktop into a session, end to end (ADR 0010 pattern B, E1).
#
# sg-rdp-authd with PAM under pam_wrapper, a real FreeRDP client on a private
# X server, and -- started by the daemon's monitor after the password is
# accepted -- a headless sg-compositor session running a Windows program that
# paints the screen one colour and logs what it receives. Checks:
#
#   - a wrong password starts no session
#   - the right one starts a session at the client's size, and the session's
#     frames arrive: the client's window shows the program's colour
#   - typing into the client reaches the Windows program as characters
#   - a click reaches it at the right place
#   - disconnecting leaves the session running; logging in again reconnects
#     to the same one, not a second
#   - when the session ends, the client is disconnected
#   - a user signed in at the console has that session taken over (E1b): the
#     client shows the console's program and types into it, no second
#     session starts, and disconnecting gives it back to the console locked
#   - no password appears in the log
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
BUILD="$HERE/build"
COMP="${SG_COMPOSITOR_BIN:-$HERE/../sg-compositor/build/sg-compositor}"
WINE_DIR="${SG_WINE_DIR:-/opt/wine-sg}"
PW=/usr/lib/x86_64-linux-gnu/libpam_wrapper.so
PMDIR=/usr/lib/x86_64-linux-gnu/pam_wrapper
PORT="${SG_RDP_TEST_PORT:-33900}"
DPY_N="${SG_RDP_TEST_DISPLAY:-96}"
RC=0
DPID=""; XPID=""; CPID=""; KPID=""

pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }

for t in xfreerdp3 Xvfb xdotool import convert openssl x86_64-w64-mingw32-gcc; do
    command -v "$t" >/dev/null 2>&1 || { echo "SKIP: $t not installed"; exit 77; }
done
for f in "$COMP" "$BUILD/sg-rdp-authd" "$BUILD/sg-rdp-pamcheck" "$PW" "$WINE_DIR/bin/wine"; do
    [ -e "$f" ] || { echo "SKIP: $f not built/installed"; exit 77; }
done

T=$(mktemp -d /var/tmp/sg-rdp-e2e.XXXXXX)
chmod 755 "$T"
export WINEPREFIX="$T/prefix" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml="
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
# shellcheck disable=SC2317  # invoked via trap
cleanup() {
    [ -n "$CPID" ] && kill "$CPID" 2>/dev/null
    [ -n "$KPID" ] && kill "$KPID" 2>/dev/null
    [ -n "$DPID" ] && kill "$DPID" 2>/dev/null
    [ -n "$XPID" ] && kill "$XPID" 2>/dev/null
    [ -f "$T/session.pid" ] && kill "$(cat "$T/session.pid")" 2>/dev/null
    "$WINE_DIR/bin/wineserver" -k 2>/dev/null
    rm -f "/tmp/.X${DPY_N}-lock"
    rm -rf "$T"
}
trap cleanup EXIT INT TERM

x86_64-w64-mingw32-gcc -O2 -mwindows -o "$T/rdp-target.exe" "$HERE/test/rdp-target.c" -lgdi32 -luser32 \
    || { fail "the target program did not build"; exit 1; }
"$WINE_DIR/bin/wineboot" -i >/dev/null 2>&1
"$WINE_DIR/bin/wineserver" -w

mkdir -p "$T/pam.d" "$T/seat"
for svc in stained-glass-remote other; do
    printf 'auth required %s passdb=%s\naccount required %s passdb=%s\n' \
        "$PMDIR/pam_matrix.so" "$T/passdb" "$PMDIR/pam_matrix.so" "$T/passdb" > "$T/pam.d/$svc"
done
printf 'alice:correct-horse:stained-glass-remote\n' > "$T/passdb"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/key.pem" -out "$T/cert.pem" \
    -days 1 -subj /CN=sg-rdp-stream-gate >/dev/null 2>&1

# What the monitor runs to start a session: the compositor, headless, at the
# size it is given, with its privileged socket in the seat directory the
# monitor prepared; the "desktop" is the target program.
cat > "$T/session.sh" <<EOF
#!/bin/sh
unset LD_PRELOAD PAM_WRAPPER PAM_WRAPPER_SERVICE_DIR
echo \$\$ > "$T/session.pid"
dir="\$SG_SEAT_DIR/\$(id -u)"
echo "\$SG_OUTPUT_SIZE" > "$T/session-size"
echo start >> "$T/session-starts"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman \\
exec "$COMP" -L "\$dir/priv.sock" -C "\$dir/control.sock" -U "\$(id -u)" -- \\
    env -u WAYLAND_DISPLAY "$WINE_DIR/bin/wine" "$T/rdp-target.exe" "$T/target.log" 2>"$T/session.log"
EOF
chmod +x "$T/session.sh"

PAM_WRAPPER=1 PAM_WRAPPER_SERVICE_DIR="$T/pam.d" LD_PRELOAD="$PW" \
SG_RDP_PAMCHECK="$BUILD/sg-rdp-pamcheck" SG_RDP_CERT="$T/cert.pem" SG_RDP_KEY="$T/key.pem" \
SG_RDP_FRAME_DUMP="$T/frame.ppm" SG_RDP_BIND=127.0.0.1 SG_RDP_LOG="$T/authd.log" SG_RDP_SEAT_ROOT="$T/seat" SG_RDP_SESSION_CMD="$T/session.sh" SG_RDP_CONSOLE_TEST=1 \
    "$BUILD/sg-rdp-authd" "$PORT" >"$T/authd.out" 2>&1 &
DPID=$!

rm -f "/tmp/.X${DPY_N}-lock"
Xvfb ":$DPY_N" -screen 0 1024x768x24 >/dev/null 2>&1 & XPID=$!
_w=0; until grep -q LISTENING "$T/authd.log" 2>/dev/null || [ $_w -gt 50 ]; do sleep 0.2; _w=$((_w + 1)); done
grep -q LISTENING "$T/authd.log" || { fail "the daemon did not start: $(cat "$T/authd.out")"; exit 1; }

client() {   # client USER PASSWORD: runs in the background, sets CPID
    DISPLAY=":$DPY_N" xfreerdp3 "/v:127.0.0.1:$PORT" "/u:$1" "/p:$2" /size:1024x768 \
        /sec:tls /cert:ignore /log-level:OFF </dev/null >"$T/client.log" 2>&1 &
    CPID=$!
}
wait_log() {   # wait_log PATTERN FILE SECONDS
    _w=0; until grep -q "$1" "$2" 2>/dev/null || [ $_w -ge $(($3 * 5)) ]; do sleep 0.2; _w=$((_w + 1)); done
    grep -q "$1" "$2" 2>/dev/null
}
colour_at() {   # colour_at X Y: the client's pixel there, as RRGGBB
    DISPLAY=":$DPY_N" import -window root "$T/shot.png" 2>/dev/null
    convert "$T/shot.png" -crop "1x1+$1+$2" -depth 8 txt:- 2>/dev/null | sed -n 's/.*#\([0-9A-Fa-f]\{6\}\).*/\1/p' | head -1
}

# ---- a wrong password -------------------------------------------------------
client alice wrong
sleep 6; kill "$CPID" 2>/dev/null; wait "$CPID" 2>/dev/null; CPID=""
if [ ! -e "$T/session-starts" ]; then pass "a wrong password starts no session"
else fail "a session was started for a wrong password"; fi

# ---- the right one ----------------------------------------------------------
client alice correct-horse
if wait_log 'SESSION attached' "$T/authd.log" 60; then pass "the right password attaches a session"
else fail "no session: $(tail -5 "$T/authd.log")"; fi
if [ "$(cat "$T/session-size" 2>/dev/null)" = 1024x768 ]; then pass "the session is started at the client's size (1024x768)"
else fail "session size: $(cat "$T/session-size" 2>/dev/null)"; fi
wait_log '^ready' "$T/target.log" 60
got=""; _w=0
while [ $_w -lt 30 ]; do
    got=$(colour_at 100 100)
    [ "$got" = 129A3C ] && break
    sleep 1; _w=$((_w + 1))
done
if [ "$got" = 129A3C ]; then pass "the session's frames reach the client (its window shows the program's colour)"
else fail "the client shows #$got at (100,100), not #129A3C"; cp "$T/shot.png" "$BUILD/rdp-stream-shot.png" 2>/dev/null; fi

# Keyboard and mouse, through the client, over RDP, into the Windows program.
WIN=$(DISPLAY=":$DPY_N" xdotool search --class freerdp 2>/dev/null | head -1)
[ -n "$WIN" ] || WIN=$(DISPLAY=":$DPY_N" xdotool search --name 'FreeRDP' 2>/dev/null | head -1)
DISPLAY=":$DPY_N" xdotool windowfocus "$WIN" 2>/dev/null
DISPLAY=":$DPY_N" xdotool mousemove 300 200 click 1 2>/dev/null
sleep 2
typed=""; _w=0
while [ $_w -lt 4 ]; do
    DISPLAY=":$DPY_N" xdotool type --delay 120 "stained" 2>/dev/null
    sleep 2
    typed=$(tr -d '\r' < "$T/target.log" | sed -n 's/^char //p' | tr -d '\n')
    case "$typed" in *stained*) break ;; esac
    _w=$((_w + 1))
done
case "$typed" in *stained*) pass "typing into the client reaches the Windows program ('stained')" ;;
    *) fail "the program received '$typed'" ;; esac
click=$(tr -d '\r' < "$T/target.log" | grep '^click' | tail -1)
# shellcheck disable=SC2086  # split "click X Y" into its fields
set -- $click
if [ $# -eq 3 ] && [ "$2" -ge 290 ] && [ "$2" -le 310 ] && [ "$3" -ge 190 ] && [ "$3" -le 210 ]; then
    pass "a click reaches it at the right place ($2,$3)"
else fail "click: '$click'"; fi

# The path is lossless: once the screen is still, what the client shows must
# be, pixel for pixel, the frame the compositor gave -- pointer included.
sleep 3
DISPLAY=":$DPY_N" import -window root "$T/client.png" 2>/dev/null
diff=$(python3 - "$T/frame.ppm" "$T/client.png" <<'EOS'
import subprocess, sys
def rgb(path):
    out = subprocess.run(["convert", path, "-depth", "8", "rgb:-"], capture_output=True).stdout
    w, h = map(int, subprocess.run(["identify", "-format", "%w %h", path], capture_output=True, text=True).stdout.split())
    return w, h, out
w1, h1, a = rgb(sys.argv[1]); w2, h2, b = rgb(sys.argv[2])
if (w1, h1) != (w2, h2): print(f"size {w1}x{h1} vs {w2}x{h2}"); sys.exit()
print(sum(1 for i in range(0, len(a), 3) if a[i:i+3] != b[i:i+3]))
EOS
)
if [ "$diff" = 0 ]; then pass "the client shows exactly the session's frame, pointer included (lossless)"
else fail "the client differs from the session's frame: $diff pixels"; cp "$T/client.png" "$BUILD/rdp-client.png"; cp "$T/frame.ppm" "$BUILD/rdp-frame.ppm"; fi

# ---- disconnect, reconnect --------------------------------------------------
kill "$CPID" 2>/dev/null; wait "$CPID" 2>/dev/null; CPID=""
wait_log 'SESSION detached' "$T/authd.log" 20
sleep 1
if [ -f "$T/session.pid" ] && kill -0 "$(cat "$T/session.pid")" 2>/dev/null; then
    pass "disconnecting leaves the session running"
else fail "the session ended with the connection"; fi
client alice correct-horse
if wait_log 'SESSION reconnect' "$T/authd.log" 30 && [ "$(grep -c . "$T/session-starts")" = 1 ]; then
    pass "logging in again reconnects to the same session"
else fail "reconnect: $(grep -c . "$T/session-starts") session(s) started; $(tail -3 "$T/authd.log")"; fi
got=""; _w=0
while [ $_w -lt 20 ]; do got=$(colour_at 100 100); [ "$got" = 129A3C ] && break; sleep 1; _w=$((_w + 1)); done
if [ "$got" = 129A3C ]; then pass "and shows it"; else fail "after reconnecting the client shows #$got"; fi

# ---- the session ends -------------------------------------------------------
kill "$(cat "$T/session.pid")" 2>/dev/null
if wait_log 'SESSION ended' "$T/authd.log" 20; then
    _w=0; while kill -0 "$CPID" 2>/dev/null && [ $_w -lt 20 ]; do sleep 0.5; _w=$((_w + 1)); done
    if kill -0 "$CPID" 2>/dev/null; then fail "the client stayed connected to an ended session"
    else pass "when the session ends, the client is disconnected"; fi
else fail "the daemon did not notice the session end"; fi
CPID=""

# ---- a session at the console is taken over (E1b) ----------------------------
control() {   # control CMD: the console compositor's answer
    python3 -c 'import socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall(sys.argv[2].encode() + b"\n")
print(s.recv(128).decode().strip())' "$T/seat/seat0/$(id -u)/control.sock" "$1" 2>/dev/null
}
mkdir -p "$T/seat/seat0/$(id -u)"
# A fresh Windows system: the remote session's desktop belonged to an X
# server that has gone, and a new Wine process on another one would trip
# over its windows.
"$WINE_DIR/bin/wineserver" -k 2>/dev/null; sleep 1
(unset LD_PRELOAD PAM_WRAPPER PAM_WRAPPER_SERVICE_DIR
 SG_OUTPUT_SIZE=1024x768 WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman \
 exec "$COMP" -L "$T/seat/seat0/$(id -u)/priv.sock" -C "$T/seat/seat0/$(id -u)/control.sock" -U "$(id -u)" -- \
    env -u WAYLAND_DISPLAY "$WINE_DIR/bin/wine" "$T/rdp-target.exe" "$T/console-target.log" 2>"$T/console.log") &
KPID=$!
wait_log '^ready' "$T/console-target.log" 60 || fail "the console session did not start: $(tail -5 "$T/console.log" 2>/dev/null)"
starts_before=$(grep -c . "$T/session-starts")
client alice correct-horse
if wait_log 'console session taken over' "$T/authd.log" 30; then
    pass "a login for a user signed in at the console takes that session over"
else fail "console take-over: $(tail -3 "$T/authd.log"); console: $(tail -3 "$T/console.log" 2>/dev/null | tr '\n' ' ')"; fi
if [ "$(control STATUS)" = "OK unlocked" ] && [ "$(grep -c . "$T/session-starts")" = "$starts_before" ]; then
    pass "no second session: the console's own, unlocked for the remote user"
else fail "after take-over: status '$(control STATUS)', $(grep -c . "$T/session-starts") session(s) started"; fi
got=""; _w=0
while [ $_w -lt 30 ]; do got=$(colour_at 100 100); [ "$got" = 129A3C ] && break; sleep 1; _w=$((_w + 1)); done
if [ "$got" = 129A3C ]; then pass "the client shows the console session's program"
else fail "take-over: the client shows #$got"; fi
WIN=$(DISPLAY=":$DPY_N" xdotool search --class freerdp 2>/dev/null | head -1)
DISPLAY=":$DPY_N" xdotool windowfocus "$WIN" mousemove 300 200 click 1 2>/dev/null
sleep 2
typed=""; _w=0
while [ $_w -lt 4 ]; do
    DISPLAY=":$DPY_N" xdotool type --delay 120 "glass" 2>/dev/null
    sleep 2
    typed=$(tr -d '\r' < "$T/console-target.log" | sed -n 's/^char //p' | tr -d '\n')
    case "$typed" in *glass*) break ;; esac
    _w=$((_w + 1))
done
case "$typed" in *glass*) pass "typing reaches the console session's program remotely ('glass')" ;;
    *) fail "the console's program received '$typed'" ;; esac
kill "$CPID" 2>/dev/null; wait "$CPID" 2>/dev/null; CPID=""
_w=0; until [ "$(control STATUS)" = "OK locked" ] || [ $_w -ge 40 ]; do sleep 0.5; _w=$((_w + 1)); done
if [ "$(control STATUS)" = "OK locked" ] && kill -0 "$KPID" 2>/dev/null; then
    pass "disconnecting gives the session back to the console, locked"
else fail "after disconnect: status '$(control STATUS)'"; fi
kill "$KPID" 2>/dev/null; KPID=""

case "$(cat "$T/authd.log")" in *correct-horse*) fail "a password appeared in the log" ;;
    *) pass "no password appears in the log" ;; esac

echo
if [ "$RC" -eq 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; cat "$T/authd.log"; fi
exit "$RC"
