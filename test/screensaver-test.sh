#!/bin/sh
# shellcheck disable=SC2015,SC2086
# sg-screensaverd, the session's org.freedesktop.ScreenSaver service: on a
# private session bus (activated from its .service file, as in a session),
# against a stand-in for the compositor's control socket that records what
# it is asked.
#
#   1. Inhibit holds an INHIBIT connection to the compositor; a second
#      Inhibit shares it; UnInhibit of one keeps it, of both releases it
#   2. only the program that holds a cookie may give it back
#   3. a program that exits without UnInhibit loses its inhibitions
#   4. SimulateUserActivity is an INHIBIT let go at once; Lock is LOCK;
#      GetActive asks STATUS
#   5. a second provider of the name leaves the first alone
#
#   sh test/screensaver-test.sh [--mutant NO_HOLD]
# The real compositor's side (INHIBIT holds swayidle off) is sg-compositor's
# test-power; Wine's side is wine-sg's test-powerreq.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
MUTANT=""
[ "${1:-}" = --mutant ] && MUTANT="-DSG_MUTANT_${2:-NO_HOLD}"
for t in dbus-run-session dbus-daemon cc pkg-config python3; do
    command -v "$t" >/dev/null || { echo "SKIP: $t missing"; exit 77; }
done
pkg-config --exists dbus-1 || { echo "SKIP: no libdbus-1-dev"; exit 77; }
T=$(mktemp -d /var/tmp/sg-screensaver.XXXXXX)
RC=0; FP=""; CP=""
# shellcheck disable=SC2317  # invoked via trap
cleanup() { for p in $CP $FP; do kill "$p" 2>/dev/null; done; rm -rf "$T"; }
trap cleanup EXIT INT TERM
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }

# shellcheck disable=SC2046  # pkg-config's flags are words
cc -O1 -Wall $MUTANT $(pkg-config --cflags dbus-1) -o "$T/sg-screensaverd" "$HERE/power/sg-screensaverd.c" \
    $(pkg-config --libs dbus-1) || { echo "FAIL  the service did not build"; exit 1; }
# shellcheck disable=SC2046
cc -O1 $(pkg-config --cflags dbus-1) -o "$T/client" "$HERE/test/screensaver-client.c" $(pkg-config --libs dbus-1) \
    || { echo "FAIL  the client did not build"; exit 1; }

# the bus: the service activated from its file, with the path rewritten
mkdir -p "$T/services"
sed "s|^Exec=.*|Exec=$T/sg-screensaverd|" "$HERE/power/org.freedesktop.ScreenSaver.service" \
    > "$T/services/org.freedesktop.ScreenSaver.service"
cat > "$T/bus.conf" <<EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:tmpdir=$T</listen>
  <servicedir>$T/services</servicedir>
  <policy context="default"><allow send_destination="*" eavesdrop="true"/><allow eavesdrop="true"/><allow own="*"/></policy>
</busconfig>
EOF

# the stand-in control socket: counts open INHIBIT connections, logs the rest
cat > "$T/fake.py" <<'EOF'
import os, socket, sys, threading
path, state = sys.argv[1], sys.argv[2]
held = 0; activity = 0; locks = 0
lock = threading.Lock()
def write():
    with open(state + ".tmp", "w") as f:
        f.write("held %d\nactivity %d\nlock %d\n" % (held, activity, locks))
    os.replace(state + ".tmp", state)
def serve(conn):
    global held, activity, locks
    cmd = conn.recv(64).decode().strip()
    if cmd == "INHIBIT":
        with lock: held += 1; write()
        conn.sendall(b"OK inhibited\n")
        conn.recv(64)  # until it closes
        with lock:
            held -= 1; activity += 1; write()
    elif cmd == "LOCK":
        with lock: locks += 1; write()
        conn.sendall(b"OK locked\n")
    elif cmd == "STATUS":
        conn.sendall(b"OK locked\n" if locks else b"OK unlocked\n")
    else:
        conn.sendall(b"ERR unknown command\n")
    conn.close()
s = socket.socket(socket.AF_UNIX); s.bind(path); s.listen(16)
write()
while True:
    c, _ = s.accept()
    threading.Thread(target=serve, args=(c,), daemon=True).start()
EOF
python3 "$T/fake.py" "$T/control.sock" "$T/state" &
FP=$!
_w=0; while [ ! -S "$T/control.sock" ] && [ $_w -lt 50 ]; do sleep 0.1; _w=$((_w+1)); done

val() { awk -v k="$1" '$1==k{print $2}' "$T/state"; }
waitval() { _n=0; while [ $_n -lt 50 ]; do [ "$(val "$1")" = "$2" ] && return 0; sleep 0.1; _n=$((_n+1)); done; return 1; }

# everything below runs on the private bus
cat > "$T/run.sh" <<EOF
#!/bin/sh
export SG_LOCK_CONTROL="$T/control.sock"
dbus-update-activation-environment SG_LOCK_CONTROL >/dev/null 2>&1 || true
echo "\$DBUS_SESSION_BUS_ADDRESS" > "$T/address"
exec sleep 300
EOF
chmod +x "$T/run.sh"
dbus-run-session --config-file="$T/bus.conf" -- "$T/run.sh" >/dev/null 2>&1 &
CP=$!
_w=0; while [ ! -s "$T/address" ] && [ $_w -lt 50 ]; do sleep 0.1; _w=$((_w+1)); done
DBUS_SESSION_BUS_ADDRESS=$(cat "$T/address"); export DBUS_SESSION_BUS_ADDRESS
[ -n "$DBUS_SESSION_BUS_ADDRESS" ] || { echo "FAIL  no private bus"; exit 1; }

# a client driven through a fifo; its answers in a file
client() {
    rm -f "$T/in.$1" "$T/out.$1"; mkfifo "$T/in.$1"
    (tail -f "$T/in.$1" 2>/dev/null | "$T/client" > "$T/out.$1" 2>&1) &
    eval "CLIENT_$1=\$!"
    _n=0; while ! grep -q ready "$T/out.$1" 2>/dev/null && [ $_n -lt 50 ]; do sleep 0.1; _n=$((_n+1)); done
}
say() { _l=$(wc -l < "$T/out.$1"); echo "$2" > "$T/in.$1"; _n=0
        while [ "$(wc -l < "$T/out.$1")" -le "$_l" ] && [ $_n -lt 80 ]; do sleep 0.1; _n=$((_n+1)); done
        tail -1 "$T/out.$1"; }
# the fifo's writer is our echo; tail -f keeps reading it
client a
client b

# 1.
c1=$(say a "inhibit firefox" | awk '/^cookie/{print $2}')
[ -n "$c1" ] && [ "$c1" != 0 ] && pass "Inhibit gives a cookie ($c1), activating the service" || fail "Inhibit answered '$(tail -2 "$T/out.a")'"
waitval held 1 && pass "and holds the compositor's idle off (INHIBIT)" || fail "no INHIBIT held: $(cat "$T/state")"
c2=$(say a "inhibit wine" | awk '/^cookie/{print $2}')
[ -n "$c2" ] && [ "$c2" != "$c1" ] && pass "a second Inhibit, another cookie" || fail "second Inhibit: '$c2'"
sleep 0.3
[ "$(val held)" = 1 ] && pass "sharing the one hold" || fail "held is $(val held)"

# 2.
say b "uninhibit $c1" | grep -q "^error" && pass "another program cannot UnInhibit it" || fail "another program gave back $c1"
[ "$(say a "uninhibit $c1")" = ok ] && pass "UnInhibit of one" || fail "UnInhibit $c1 failed"
sleep 0.3
[ "$(val held)" = 1 ] && pass "keeps the hold for the other" || fail "held is $(val held) with one left"
[ "$(say a "uninhibit $c2")" = ok ] && waitval held 0 && pass "UnInhibit of both releases it" \
    || fail "after both UnInhibit held is $(val held)"

# 3.
say b "inhibit player" >/dev/null
waitval held 1 || fail "the second program's Inhibit held nothing"
echo quit > "$T/in.b"
waitval held 0 && pass "a program that exits loses its inhibitions" || fail "an exited program's hold stayed: $(cat "$T/state")"

# 4.
a0=$(val activity)
[ "$(say a activity)" = ok ] && waitval activity $((a0 + 1)) && [ "$(val held)" = 0 ] \
    && pass "SimulateUserActivity: an INHIBIT let go at once" || fail "SimulateUserActivity: $(cat "$T/state")"
[ "$(say a active)" = "active 0" ] && pass "GetActive: not locked" || fail "GetActive said '$(tail -1 "$T/out.a")'"
[ "$(say a lock)" = ok ] && waitval lock 1 && pass "Lock: LOCK on the control socket" || fail "Lock: $(cat "$T/state")"
[ "$(say a active)" = "active 1" ] && pass "GetActive: locked" || fail "GetActive said '$(tail -1 "$T/out.a")' after Lock"

# 5.
"$T/sg-screensaverd" > "$T/second" 2>&1; rc=$?
[ $rc = 0 ] && grep -q taken "$T/second" && pass "a second provider leaves the name to the first" \
    || fail "a second provider: rc $rc, $(cat "$T/second")"
c3=$(say a "inhibit after" | awk '/^cookie/{print $2}')
[ -n "$c3" ] && waitval held 1 && pass "and the first still answers" || fail "the first stopped answering"

echo quit > "$T/in.a"
[ $RC -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $RC
