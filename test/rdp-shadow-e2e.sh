#!/bin/sh
. "$(dirname "$0")/scratch-home.sh"
# Console shadow over Remote Desktop, end to end (E1 pattern A, ADR 0010).
#
# A session live at the console (a headless sg-compositor running a Windows
# program that paints the screen and logs what it receives), sg-rdp-authd
# with PAM under pam_wrapper, sg-brokerd for the console's consent, and a real
# FreeRDP client on a private X server asking for "shadow" as its alternate
# shell. The consent prompt is a stand-in that answers as told, but runs where
# the real one does: the gate checks that the console was on its secure
# surface while it was asked. Checks:
#
#   - the console's own user, view only: no prompt; the client shows the
#     console's screen pixel for pixel, with the frame that tells the console
#     it is being viewed; nothing typed or clicked in the client reaches the
#     session, while the console's own keyboard still does; the session is
#     neither taken over nor locked; disconnecting removes the frame and
#     changes nothing else
#   - a user who is not an administrator cannot view someone else's session,
#     and the console is not even asked
#   - an administrator asks: the console is asked on its secure surface; a
#     "no" refuses the connection and returns the console as it was
#   - a "yes" with /control: the client shows the session and types and
#     clicks into it; Ctrl+Alt+Del at the console ends the viewing
#   - nobody of that name at the console: refused
#   - with SG_PREFIX (a Wine prefix, as test-consent takes) and sg-consent.exe
#     built: the real prompt -- "Remote Desktop request" -- comes up on the
#     console's secure surface, and Yes there starts the viewing (its picture
#     is left in build/rdp-shadow-prompt.png)
#
# Mutants: SG_MUTANT_SHADOW_VIEW_INPUT (sg-compositor lock.c: a view-only
# viewer gets the virtual keyboard and pointer) fails the view-only checks;
# SG_MUTANT_SHADOW_NO_CONSENT (sg-rdp-authd: the console's answer ignored)
# fails the "no" case.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
BUILD="$HERE/build"
COMP="${SG_COMPOSITOR_BIN:-$HERE/../sg-compositor/build/sg-compositor}"
WINE_DIR="${SG_WINE_DIR:-/opt/wine-sg}"
PW=/usr/lib/x86_64-linux-gnu/libpam_wrapper.so
PMDIR=/usr/lib/x86_64-linux-gnu/pam_wrapper
PORT="${SG_RDP_TEST_PORT:-33901}"
DPY_N="${SG_RDP_TEST_DISPLAY:-97}"
RC=0
DPID=""; XPID=""; CPID=""; KPID=""; BPID=""

pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }

for t in xfreerdp3 Xvfb xdotool import convert openssl grim python3 x86_64-w64-mingw32-gcc; do
    command -v "$t" >/dev/null 2>&1 || { echo "SKIP: $t not installed"; exit 77; }
done
for f in "$COMP" "$BUILD/sg-rdp-authd" "$BUILD/sg-rdp-pamcheck" "$BUILD/sg-brokerd" "$BUILD/sg-vkbd" "$PW" \
         "$WINE_DIR/bin/wine"; do
    [ -e "$f" ] || { echo "SKIP: $f not built/installed"; exit 77; }
done

T=$(mktemp -d /var/tmp/sg-rdp-shadow.XXXXXX)
chmod 755 "$T"
export WINEPREFIX="$T/prefix" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=,winemenubuilder.exe=d"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
SEAT="$T/seat/seat0/$(id -u)"
# shellcheck disable=SC2317  # invoked via trap
cleanup() {
    [ -n "$CPID" ] && kill "$CPID" 2>/dev/null
    [ -n "$DPID" ] && kill "$DPID" 2>/dev/null
    [ -n "$BPID" ] && kill "$BPID" 2>/dev/null
    [ -n "$KPID" ] && kill "$KPID" 2>/dev/null
    [ -n "$XPID" ] && kill "$XPID" 2>/dev/null
    "$WINE_DIR/bin/wineserver" -k 2>/dev/null
    rm -f "/tmp/.X${DPY_N}-lock"
    if [ -n "${SG_KEEP:-}" ]; then echo "kept $T"; else rm -rf "$T"; fi
}
trap cleanup EXIT INT TERM

x86_64-w64-mingw32-gcc -O2 -mwindows -o "$T/rdp-target.exe" "$HERE/test/rdp-target.c" -lgdi32 -luser32 \
    || { fail "the target program did not build"; exit 1; }
"$WINE_DIR/bin/wineboot" -i >/dev/null 2>&1
"$WINE_DIR/bin/wineserver" -w

mkdir -p "$T/pam.d" "$SEAT"
for svc in stained-glass-remote other; do
    printf 'auth required %s passdb=%s\naccount required %s passdb=%s\n' \
        "$PMDIR/pam_matrix.so" "$T/passdb" "$PMDIR/pam_matrix.so" "$T/passdb" > "$T/pam.d/$svc"
done
# alice is at the console; bob is an administrator; carol is not
printf 'alice:alice-pw:stained-glass-remote\nbob:bob-pw:stained-glass-remote\ncarol:carol-pw:stained-glass-remote\n' > "$T/passdb"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/key.pem" -out "$T/cert.pem" \
    -days 1 -subj /CN=sg-rdp-shadow-gate >/dev/null 2>&1

# A remote session of its own must never start in this gate.
printf '#!/bin/sh\necho start >> "%s/session-starts"\n' "$T" > "$T/session.sh"
chmod +x "$T/session.sh"

# The consent prompt's stand-in: records what it was asked and whether the
# console was on its secure surface then, and answers as $T/answer says.
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

# The console session: the compositor as the session user, its sockets where
# sg-session-start puts them, the target program as the desktop.
(unset LD_PRELOAD PAM_WRAPPER PAM_WRAPPER_SERVICE_DIR
 SG_OUTPUT_SIZE=1024x768 WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman \
 exec "$COMP" -L "$SEAT/priv.sock" -C "$SEAT/control.sock" -U "$(id -u)" -- \
    env -u WAYLAND_DISPLAY "$WINE_DIR/bin/wine" "$T/rdp-target.exe" "$T/target.log" 2>"$T/console.log") &
KPID=$!

SG_BROKER_SOCK="$T/broker.sock" SG_BROKER_FOREGROUND=1 SG_BROKERD_LOG="$T/broker.log" SG_SEAT_DIR="$T/seat/seat0" \
SG_CONSENT_UI="$T/consent.sh" SG_SHADOW_CONSENT_TIMEOUT=10 SG_BROKER_PAMCHECK=/bin/false \
    "$BUILD/sg-brokerd" >"$T/broker.out" 2>&1 &
BPID=$!

PAM_WRAPPER=1 PAM_WRAPPER_SERVICE_DIR="$T/pam.d" LD_PRELOAD="$PW" \
SG_RDP_PAMCHECK="$BUILD/sg-rdp-pamcheck" SG_RDP_CERT="$T/cert.pem" SG_RDP_KEY="$T/key.pem" \
SG_RDP_FRAME_DUMP="$T/frame.ppm" SG_RDP_BIND=127.0.0.1 SG_RDP_LOG="$T/authd.log" SG_RDP_SEAT_ROOT="$T/seat" \
SG_RDP_SESSION_CMD="$T/session.sh" SG_RDP_TEST_CONSOLE_USER=alice SG_RDP_TEST_ADMINS=bob \
SG_RDP_BROKER_SOCK="$T/broker.sock" \
    "$BUILD/sg-rdp-authd" "$PORT" >"$T/authd.out" 2>&1 &
DPID=$!

rm -f "/tmp/.X${DPY_N}-lock"
Xvfb ":$DPY_N" -screen 0 1024x768x24 >/dev/null 2>&1 & XPID=$!

wait_log() {   # wait_log PATTERN FILE SECONDS
    _w=0; until grep -q "$1" "$2" 2>/dev/null || [ $_w -ge $(($3 * 5)) ]; do sleep 0.2; _w=$((_w + 1)); done
    grep -q "$1" "$2" 2>/dev/null
}
wait_log LISTENING "$T/authd.log" 10 || { fail "the daemon did not start: $(cat "$T/authd.out")"; exit 1; }
wait_log '^ready' "$T/target.log" 90 || { fail "the console session did not start: $(tail -5 "$T/console.log")"; exit 1; }
sleep 2

client() {   # client USER PASSWORD SHELL: runs in the background, sets CPID
    DISPLAY=":$DPY_N" xfreerdp3 "/v:127.0.0.1:$PORT" "/u:$1" "/p:$2" "/shell:$3" /size:1024x768 \
        /sec:tls /cert:ignore /log-level:OFF </dev/null >"$T/client.log" 2>&1 &
    CPID=$!
}
disconnect() { [ -n "$CPID" ] && kill "$CPID" 2>/dev/null; [ -n "$CPID" ] && wait "$CPID" 2>/dev/null; CPID=""; }
control() {   # control CMD: the console compositor's answer
    python3 -c 'import socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall(sys.argv[2].encode() + b"\n")
print(s.recv(128).decode().strip())' "$SEAT/control.sock" "$1" 2>/dev/null
}
colour_at() {   # colour_at X Y: the client's pixel there, as RRGGBB
    DISPLAY=":$DPY_N" import -window root "$T/shot.png" 2>/dev/null
    convert "$T/shot.png" -crop "1x1+$1+$2" -depth 8 txt:- 2>/dev/null | sed -n 's/.*#\([0-9A-Fa-f]\{6\}\).*/\1/p' | head -1
}
console_colour_at() {   # console_colour_at X Y: the console's own pixel there (a capture of its screen)
    WAYLAND_DISPLAY="$SEAT/priv.sock" grim -t ppm "$T/console.ppm" 2>/dev/null
    convert "$T/console.ppm" -crop "1x1+$1+$2" -depth 8 txt:- 2>/dev/null | sed -n 's/.*#\([0-9A-Fa-f]\{6\}\).*/\1/p' | head -1
}
is_frame() {   # is_frame RRGGBB: the viewing frame's amber (#FFB400, give or take rounding)
    python3 -c 'import sys; c = sys.argv[1]
r, g, b = int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16)
sys.exit(0 if r >= 0xf8 and 0xa8 <= g <= 0xc0 and b <= 8 else 1)' "${1:-000000}" 2>/dev/null
}
chars() { tr -d '\r' < "$T/target.log" | sed -n 's/^char //p' | tr -d '\n'; }
clicks() { tr -d '\r' < "$T/target.log" | grep -c '^click'; }
calls() { grep -c . "$T/consent-calls" 2>/dev/null || echo 0; }
wait_colour() {   # wait_colour X Y RRGGBB SECONDS: until the client shows it there
    _w=0; got=""
    while [ $_w -lt "$4" ]; do got=$(colour_at "$1" "$2"); [ "$got" = "$3" ] && return 0; sleep 1; _w=$((_w + 1)); done
    return 1
}
lossless() {   # lossless WHAT: the client's screen against the last captured frame
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
    if [ "$diff" = 0 ]; then pass "the client shows exactly the console's screen ($1)"
    else fail "the client differs from the console's screen ($1): $diff pixels"; fi
}
vkbd() { WAYLAND_DISPLAY="$SEAT/priv.sock" "$BUILD/sg-vkbd" "$@"; sleep 1; }

# Teeth: the console's own keyboard reaches the program. (A new virtual
# keyboard's very first press can be lost to Xwayland's keymap change, as in
# every gate that types this way: type twice.)
vkbd "aa"
case "$(chars)" in *a*) ;; *) fail "the console's keyboard does not reach the program: '$(chars)'"; exit 1 ;; esac
[ "$(control STATUS)" = "OK unlocked" ] || fail "the console session is not unlocked to start with"

# ---- the console's own user, view only ---------------------------------------
client alice alice-pw shadow
if wait_log 'SESSION shadow user=alice of=alice mode=view' "$T/authd.log" 30; then
    pass "the console's user can view their own session over RDP (no prompt)"
else fail "own-session shadow: $(tail -3 "$T/authd.log")"; fi
if [ "$(calls)" = 0 ]; then pass "... without asking the console"; else fail "the console was asked about its own user"; fi
if grep -q 'SESSION attached user=alice.*(view only)' "$T/authd.log" && [ "$(control SHADOWSTATUS)" = "OK view" ]; then
    pass "it is view only (no virtual keyboard or pointer granted)"
else fail "view only: $(grep 'SESSION attached' "$T/authd.log" | tail -1); $(control SHADOWSTATUS)"; fi
if wait_colour 100 100 129A3C 30; then pass "the client shows the console session's program"
else fail "the client shows #$got at (100,100), not #129A3C"; fi
got=$(colour_at 2 300)
if is_frame "$got"; then pass "the console's screen has the viewing frame, and the client sees it too (#$got)"
else fail "no viewing frame at (2,300): #$got"; fi
got=$(console_colour_at 2 300)
if is_frame "$got"; then pass "the console itself shows the frame (#$got)"
else fail "the console's own screen has no frame at (2,300): #$got"; fi
if [ "$(control STATUS)" = "OK unlocked" ] && ! grep -q 'remote desktop took the session' "$T/console.log" && \
   [ ! -e "$T/session-starts" ]; then
    pass "the session stays at the console, unlocked: not taken over, no second session"
else fail "status '$(control STATUS)'; $(grep -c 'took the session' "$T/console.log") take-over(s)"; fi
lossless "view only"
before_chars=$(chars); before_clicks=$(clicks)
WIN=$(DISPLAY=":$DPY_N" xdotool search --class freerdp 2>/dev/null | head -1)
DISPLAY=":$DPY_N" xdotool windowfocus "$WIN" mousemove 300 200 click 1 2>/dev/null
sleep 1
DISPLAY=":$DPY_N" xdotool type --delay 120 "peek" 2>/dev/null
sleep 3
if [ "$(chars)" = "$before_chars" ] && [ "$(clicks)" = "$before_clicks" ]; then
    pass "nothing typed or clicked in a view-only client reaches the session"
else fail "a view-only client's input arrived: chars '$(chars)' (was '$before_chars'), clicks $(clicks) (was $before_clicks)"; fi
vkbd "llocal"
case "$(chars)" in *local) pass "the console's own keyboard still works while viewed" ;;
    *) fail "the console's keyboard: '$(chars)'" ;; esac
disconnect
_w=0; until [ "$(control SHADOWSTATUS)" = "OK none" ] || [ $_w -ge 20 ]; do sleep 0.5; _w=$((_w + 1)); done
sleep 1
got=$(console_colour_at 2 300)
if [ "$(control SHADOWSTATUS)" = "OK none" ] && [ "$(control STATUS)" = "OK unlocked" ] && [ "$got" = 129A3C ]; then
    pass "disconnecting ends the viewing: the frame goes, the session stays unlocked"
else fail "after disconnect: $(control SHADOWSTATUS), $(control STATUS), (2,300) #$got"; fi

# ---- someone else's session, not an administrator -----------------------------
client carol carol-pw "shadow alice"
wait_log 'SESSION refused user=carol' "$T/authd.log" 30
if grep -q 'SESSION refused user=carol: not allowed' "$T/authd.log" && [ "$(calls)" = 0 ] && \
   [ "$(control SHADOWSTATUS)" = "OK none" ]; then
    pass "a user who is not an administrator cannot view someone else's session (the console is not asked)"
else fail "carol: $(grep carol "$T/authd.log" | tail -2); $(calls) prompt(s)"; fi
disconnect

# ---- an administrator; the console says no -----------------------------------
echo DENY > "$T/answer"
client bob bob-pw "shadow alice /control"
wait_log 'SESSION refused user=bob' "$T/authd.log" 40
if grep -q 'shadow bob control status=OK secure' "$T/consent-calls" 2>/dev/null; then
    pass "an administrator's request asks the console, on its secure surface"
else fail "the console was not asked on the secure surface: $(cat "$T/consent-calls" 2>/dev/null)"; fi
if grep -q 'SESSION refused user=bob: the person at the console did not accept' "$T/authd.log" && \
   [ "$(control SHADOWSTATUS)" = "OK none" ]; then
    pass "a \"no\" at the console refuses the connection"
else fail "after a no: $(grep 'user=bob' "$T/authd.log" | tail -2); $(control SHADOWSTATUS)"; fi
sleep 1
if [ "$(control STATUS)" = "OK unlocked" ]; then pass "... and the console is as it was (unlocked, prompt gone)"
else fail "after a no the console is '$(control STATUS)'"; fi
disconnect

# ---- the console says yes, with control --------------------------------------
echo ALLOW > "$T/answer"
client bob bob-pw "shadow alice /control"
if wait_log 'SESSION shadow user=bob of=alice mode=control' "$T/authd.log" 40 && \
   [ "$(control SHADOWSTATUS)" = "OK control" ]; then
    pass "a \"yes\" at the console lets the administrator view and control it"
else fail "after a yes: $(tail -3 "$T/authd.log"); $(control SHADOWSTATUS)"; fi
if wait_colour 100 100 129A3C 30; then pass "the administrator's client shows the console session"
else fail "the administrator's client shows #$got"; fi
lossless "control"
before_clicks=$(clicks)
WIN=$(DISPLAY=":$DPY_N" xdotool search --class freerdp 2>/dev/null | head -1)
DISPLAY=":$DPY_N" xdotool windowfocus "$WIN" mousemove 300 200 click 1 2>/dev/null
sleep 2
typed=""; _w=0
while [ $_w -lt 4 ]; do
    DISPLAY=":$DPY_N" xdotool type --delay 120 "ctl" 2>/dev/null
    sleep 2
    case "$(chars)" in *ctl*) typed=1; break ;; esac
    _w=$((_w + 1))
done
if [ -n "$typed" ] && [ "$(clicks)" -gt "$before_clicks" ]; then
    pass "typing and clicks from the client reach the console session"
else fail "control: chars '$(chars)', clicks $(clicks) (was $before_clicks)"; fi
vkbd -M ctrl -M alt -k Delete -m alt -m ctrl
_w=0; until [ "$(control SHADOWSTATUS)" = "OK none" ] || [ $_w -ge 20 ]; do sleep 0.5; _w=$((_w + 1)); done
if [ "$(control SHADOWSTATUS)" = "OK none" ] && wait_log 'SESSION ended' "$T/authd.log" 20; then
    pass "Ctrl+Alt+Del at the console ends the viewing, and the client is disconnected"
else fail "Ctrl+Alt+Del: $(control SHADOWSTATUS); $(tail -2 "$T/authd.log")"; fi
_w=0; while kill -0 "$CPID" 2>/dev/null && [ $_w -lt 20 ]; do sleep 0.5; _w=$((_w + 1)); done
disconnect
control UNLOCK >/dev/null   # no lock service here: Ctrl+Alt+Del locked

# ---- nobody of that name at the console ---------------------------------------
client bob bob-pw "shadow dave"
wait_log 'SESSION refused user=bob: nobody' "$T/authd.log" 30
if grep -q 'SESSION refused user=bob: nobody of that name at the console' "$T/authd.log"; then
    pass "asking for someone not at the console is refused"
else fail "shadow dave: $(tail -2 "$T/authd.log")"; fi
disconnect

# ---- the real prompt -----------------------------------------------------------
if [ -n "${SG_PREFIX:-}" ] && [ -d "$SG_PREFIX/drive_c" ] && [ -e "$BUILD/sg-consent64.exe" ]; then
    kill "$BPID" 2>/dev/null; wait "$BPID" 2>/dev/null
    rm -f "$T/broker.sock"
    SG_BROKER_SOCK="$T/broker.sock" SG_BROKER_FOREGROUND=1 SG_BROKERD_LOG="$T/broker.log" SG_SEAT_DIR="$T/seat/seat0" \
    SG_CONSENT_UI="$HERE/lib/sg-consent-ui" SG_LIB="$HERE/lib" SG_LIBEXEC="$BUILD" SG_LOG_DIR="$T" \
    SG_PREFIX="$SG_PREFIX" SG_SHADOW_CONSENT_TIMEOUT=60 SG_BROKER_PAMCHECK=/bin/false \
        "$BUILD/sg-brokerd" >"$T/broker.out" 2>&1 &
    BPID=$!
    _w=0; while [ ! -S "$T/broker.sock" ] && [ $_w -lt 50 ]; do sleep 0.2; _w=$((_w + 1)); done
    client bob bob-pw "shadow alice"
    PN=""; _w=0
    while [ -z "$PN" ] && [ $_w -lt 60 ]; do
        for a in "${TMPDIR:-/tmp}"/sg-consent-*/Xauthority; do
            [ -r "$a" ] || continue
            for d in /tmp/.X11-unix/X*; do
                n=":${d##*/X}"; [ "$n" = ":0" ] || [ "$n" = ":$DPY_N" ] && continue
                XAUTHORITY="$a" DISPLAY="$n" xdotool search --name 'Remote Desktop request' >/dev/null 2>&1 \
                    && { PN="$n"; PA="$a"; break 2; }
            done
        done
        sleep 1; _w=$((_w + 1))
    done
    if [ -n "$PN" ] && [ "$(control STATUS)" = "OK secure" ]; then
        pass "the real prompt asks the console, on its secure surface ($PN)"
        sleep 3
        XAUTHORITY="$PA" DISPLAY="$PN" import -window root "$BUILD/rdp-shadow-prompt.png" 2>/dev/null
        # focus starts on No: Left to Yes, then Enter
        vkbd -k Shift_L; vkbd -k Left; vkbd -k Return
        if wait_log 'SESSION shadow user=bob of=alice mode=view' "$T/authd.log" 30; then
            pass "Yes at the real prompt starts the viewing"
        else fail "Yes at the real prompt: $(tail -3 "$T/broker.log")"; fi
    else fail "no real prompt (display '$PN', console $(control STATUS)): $(tail -3 "$T/broker.log")"; fi
    disconnect
    _w=0; until [ "$(control SHADOWSTATUS)" = "OK none" ] || [ $_w -ge 20 ]; do sleep 0.5; _w=$((_w + 1)); done
else
    echo "SKIP  the real prompt (set SG_PREFIX to a Wine prefix, and build sg-consent64.exe)"
fi

case "$(cat "$T/authd.log" "$T/broker.log" 2>/dev/null)" in *alice-pw*|*bob-pw*|*carol-pw*) fail "a password appeared in a log" ;;
    *) pass "no password appears in the logs" ;; esac

echo
if [ "$RC" -eq 0 ]; then echo "RESULT: PASS"
else echo "RESULT: FAIL"; cat "$T/authd.log"; echo "--- broker"; cat "$T/broker.log" 2>/dev/null; grep audit "$T/console.log"; fi
exit "$RC"
