#!/bin/sh
# The login screen end to end, with the real Wine greeter.
#
# sg-compositor hosts sg-greet-bridge, which runs the real sg-greeter.exe and
# speaks greetd's wire protocol to a stub (greetd itself needs root and a seat).
# Keys go in over the privileged virtual keyboard. The login-screen gate that
# came before this stood a shell script in for the greeter, and so could not
# see that the real greeter never read its pipe.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
COMP="${SG_COMPOSITOR_BIN:-$HERE/../sg-compositor/build/sg-compositor}"
PFX="${SG_PREFIX:-$HERE/test/tmp/state/prefix}"
RC=0; T=$(mktemp -d); chmod 755 "$T"; CP=""; SP=""
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
# shellcheck disable=SC2317  # invoked via trap
cleanup() {
    [ -n "$CP" ] && kill "$CP" 2>/dev/null
    [ -n "$SP" ] && kill "$SP" 2>/dev/null
    sleep 1
    WINEPREFIX="$PFX" "${SG_WINE_DIR:-/opt/wine-sg}/bin/wineserver" -k 2>/dev/null || true
    rm -rf "$T"
}
trap cleanup EXIT INT TERM
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
for t in wtype xdotool python3; do command -v "$t" >/dev/null || { echo "SKIP: $t missing"; exit 77; }; done
for f in "$COMP" "$HERE/build/sg-greet-bridge" "$HERE/build/greetd-stub" "$HERE/build/sg-greeter64.exe"; do
    [ -e "$f" ] || { echo "SKIP: $f not built"; exit 77; }; done
[ -d "$PFX/drive_c" ] || { echo "SKIP: no prefix"; exit 77; }

inj() { WAYLAND_DISPLAY="$T/priv.sock" wtype "$@"; sleep 1; }

# One login attempt against a fresh stub; prints what the stub recorded.
attempt() {
    _user=$1 _pass=$2
    rm -f "$T/greetd.sock" "$T/stub.out"
    "$HERE/build/greetd-stub" "$T/greetd.sock" PASS >"$T/stub.out" 2>"$T/stub.err" &
    SP=$!
    _w=0; while [ ! -S "$T/greetd.sock" ] && [ $_w -lt 50 ]; do sleep 0.1; _w=$((_w+1)); done
    cat > "$T/greeter.sh" <<EOS
#!/bin/sh
export WINEPREFIX="$PFX" WINEARCH=win64 WINEDEBUG=-all PATH="${SG_WINE_DIR:-/opt/wine-sg}/bin:\$PATH"
exec wine "$HERE/build/sg-greeter64.exe"
EOS
    chmod +x "$T/greeter.sh"
    GREETD_SOCK="$T/greetd.sock" WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman \
        "$COMP" -L "$T/priv.sock" -C "$T/ctl.sock" -U "$(id -u)" -- \
        "$HERE/build/sg-greet-bridge" /usr/bin/sg-session-start "$T/greeter.sh" >"$T/comp.log" 2>&1 &
    CP=$!
    # Wait for the greeter window, then type.
    _w=0; _ok=""
    while [ $_w -lt 60 ]; do
        for d in /tmp/.X11-unix/X*; do
            DISPLAY=":${d##*/X}" xdotool search --name 'Sign in' >/dev/null 2>&1 && { _ok=1; break 2; }
        done; sleep 1; _w=$((_w+1))
    done
    [ -n "$_ok" ] || { echo "no-greeter"; return; }
    sleep 3
    inj x; inj -k BackSpace          # warm up the keymap, then clear
    inj "$_user" -k Return; sleep 3
    inj "$_pass" -k Return; sleep 4
    kill "$CP" 2>/dev/null; CP=""
    kill "$SP" 2>/dev/null; wait "$SP" 2>/dev/null; SP=""
    cat "$T/stub.out" "$T/stub.err" 2>/dev/null
}

out=$(attempt alice PASS)
case "$out" in no-greeter) fail "the greeter window never appeared" ;; esac
case "$out" in *'"username":"alice"'*) pass "the real greeter sent the user name to greetd" ;;
    *) fail "greetd never got the user name: $out" ;; esac
case "$out" in *"correct password"*) pass "the real greeter sent the password, and it was accepted" ;;
    *) fail "the password did not reach greetd correctly" ;; esac
case "$out" in *STARTED*sg-session-start*) pass "the session started with the configured command" ;;
    *) fail "the session did not start" ;; esac

out=$(attempt alice wrongpw)
case "$out" in *"wrong password"*) pass "a wrong password reaches greetd and is refused" ;;
    *) fail "wrong-password attempt: $out" ;; esac
case "$out" in *STARTED*) fail "a session started after a wrong password" ;;
    *) pass "no session starts after a wrong password" ;; esac

echo
if [ "$RC" -eq 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; fi
exit "$RC"
