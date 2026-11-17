#!/bin/sh
. "$(dirname "$0")/scratch-home.sh"
# The lock screen always comes back (sg-lockd, sg-lock-fallback). The machine
# stays locked whatever the lock UI does -- the compositor shows only privileged
# clients -- so a lock UI that dies, never starts or hangs left a blank screen
# and no way to sign in: after an upgrade Wine's client and server were at
# different versions ("version mismatch") and the lock UI died at every start,
# a purple screen with a pointer (David's machine, 2026-11-17). Now:
#   A. the lock UI killed while locked: the machine stays locked, the lock
#      screen comes back, and the password unlocks;
#   B. a lock UI that dies at every start: the machine stays locked, sg-lockd
#      backs off and after three starts brings up the stand-in (sg-lock-fallback,
#      no Wine): a wrong password is refused there, the right one unlocks;
#   C. a lock UI that never comes up (hangs): stopped after SG_LOCK_UI_HELLO_SECONDS,
#      started again, then the stand-in; the password unlocks.
# Nothing unlocks without the password: the stand-in speaks the same protocol
# and sg-lockd alone checks it (PAM, here pam_wrapper/pam_matrix) and sends UNLOCK.
# Mutants (sg-lockd.c): SG_MUTANT_LOCK_NO_FALLBACK (B, C), SG_MUTANT_LOCK_NO_WATCHDOG (C).
#
#   SG_COMPOSITOR_BIN=... SG_WINE_DIR=... sh test/lock-revive-test.sh
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
COMP="${SG_COMPOSITOR_BIN:-$HERE/../sg-compositor/build/sg-compositor}"
WINE_DIR="${SG_WINE_DIR:-/opt/wine-sg}"
PW=/usr/lib/x86_64-linux-gnu/libpam_wrapper.so
PMDIR=/usr/lib/x86_64-linux-gnu/pam_wrapper
for t in xdotool Xwayland python3; do command -v "$t" >/dev/null || { echo "SKIP: $t missing"; exit 77; }; done
for f in "$COMP" "$HERE/build/sg-vkbd" "$HERE/build/sg-lockd" "$HERE/build/sg-lock-fallback" "$HERE/build/sg-rdp-pamcheck" \
         "$HERE/build/sg-greeter64.exe" "$PW" "$WINE_DIR/bin/wine"; do
    [ -e "$f" ] || { echo "SKIP: $f not built"; exit 77; }; done
RC=0; T=$(mktemp -d /var/tmp/sg-lockrevive.XXXXXX); chmod 755 "$T"; CP=""; LP=""
# never the person's own desktop: a runtime directory and no display of the gate's own
mkdir -m 700 "$T/run"
export XDG_RUNTIME_DIR="$T/run" HOME="$T/home" WAYLAND_DISPLAY=sg-no-wayland
unset DISPLAY
mkdir -p "$HOME"
LOCKN=$((170 + $$ % 20))
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
# shellcheck disable=SC2317  # invoked via trap
cleanup() {
    [ -n "$LP" ] && kill "$LP" 2>/dev/null
    [ -n "$CP" ] && kill "$CP" 2>/dev/null
    sleep 1
    [ -n "$LP" ] && kill -9 "$LP" 2>/dev/null
    [ -n "$CP" ] && kill -9 "$CP" 2>/dev/null
    WINEPREFIX="$T/prefix" "$WINE_DIR/bin/wineserver" -k 2>/dev/null || true
    [ -n "${KEEP:-}" ] || rm -rf "$T"
}
trap cleanup EXIT INT TERM

WINEPREFIX="$T/prefix" WINEDEBUG=-all WINEDLLOVERRIDES="winemenubuilder.exe=d" \
    timeout -s KILL 300 "$WINE_DIR/bin/wine" wineboot -i >/dev/null 2>&1
WINEPREFIX="$T/prefix" "$WINE_DIR/bin/wineserver" -w

mkdir -p "$T/pam.d"
for svc in stained-glass-lock other; do
    printf 'auth required %s passdb=%s\naccount required %s passdb=%s\n' \
        "$PMDIR/pam_matrix.so" "$T/passdb" "$PMDIR/pam_matrix.so" "$T/passdb" > "$T/pam.d/$svc"
done
printf '%s:correct-horse:stained-glass-lock\n' "$(id -un)" > "$T/passdb"

ctl() { python3 -c "import socket;s=socket.socket(socket.AF_UNIX);s.connect('$T/ctl.sock');s.sendall(b'$1\n');print(s.recv(64).decode().strip())"; }
inj() { WAYLAND_DISPLAY="$T/priv.sock" "$HERE/build/sg-vkbd" "$@"; sleep 1; }

WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman \
    "$COMP" -L "$T/priv.sock" -C "$T/ctl.sock" -U "$(id -u)" -- sh -c "echo up > $T/up; exec sleep 3600" \
    >/dev/null 2>"$T/comp.log" &
CP=$!
_w=0; while [ ! -s "$T/up" ] && [ $_w -lt 50 ]; do sleep 0.2; _w=$((_w+1)); done
sleep 1

# the lock UIs of cases B and C: dying at every start / never coming up, until sg-lockd asks for
# the stand-in (SG_LOCK_FALLBACK=1), which is the real sg-lock-ui's
cat > "$T/ui-dies" <<EOF
#!/bin/sh
[ "\${SG_LOCK_FALLBACK:-}" = 1 ] && exec "$HERE/lib/sg-lock-ui" "\$@"
echo "wine client error:0: version mismatch 877/880" >&2
exit 1
EOF
cat > "$T/ui-hangs" <<EOF
#!/bin/sh
[ "\${SG_LOCK_FALLBACK:-}" = 1 ] && exec "$HERE/lib/sg-lock-ui" "\$@"
exec sleep 3600
EOF
chmod +x "$T/ui-dies" "$T/ui-hangs"

lockd() { # UI-COMMAND [ENV...]
    _ui=$1; shift
    [ -n "$LP" ] && { kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null; }
    : > "$T/lockd.log"
    env PAM_WRAPPER=1 PAM_WRAPPER_SERVICE_DIR="$T/pam.d" LD_PRELOAD="$PW" \
        SG_LOCK_PAMCHECK="$HERE/build/sg-rdp-pamcheck" SG_LOCK_CONTROL="$T/ctl.sock" SG_LOCK_PRIV="$T/priv.sock" \
        SG_LOCK_UI="$_ui" SG_LIB="$HERE/lib" SG_LIBEXEC="$HERE/build" SG_LOG_DIR="$T" SG_WINE_DIR="$WINE_DIR" \
        SG_PREFIX="$T/prefix" SG_LOCKD_LOG="$T/lockd.log" SG_LOCK_DISPLAY_NUM="$LOCKN" TMPDIR="$T" \
        WINEDLLOVERRIDES="winemenubuilder.exe=d" "$@" \
        "$HERE/build/sg-lockd" >/dev/null 2>&1 &
    LP=$!
    _w=0; while ! grep -q watching "$T/lockd.log" 2>/dev/null && [ $_w -lt 50 ]; do sleep 0.2; _w=$((_w+1)); done
}
# the lock screen's window on its own X server (its cookie: sg-lock-ui's, under TMPDIR)
lock_window() { # SECONDS -> its X display, or nothing
    _w=0
    while [ $_w -lt "$1" ]; do
        for a in "$T"/sg-lock-*/Xauthority; do
            [ -s "$a" ] || continue
            for d in /tmp/.X11-unix/X*; do
                n=":${d##*/X}"
                [ "${d##*/X}" -ge "$LOCKN" ] 2>/dev/null || continue
                DISPLAY="$n" XAUTHORITY="$a" xdotool search --name 'Sign in' >/dev/null 2>&1 && { echo "$n"; return 0; }
            done
        done
        sleep 1; _w=$((_w+1))
    done
    return 1
}
unlock_with() { # PASSWORD
    inj x; inj -k BackSpace
    inj "$1" -k Return
    sleep 5
}

# A. the lock UI killed while locked
lockd "$HERE/lib/sg-lock-ui"
ctl LOCK >/dev/null
[ "$(ctl STATUS)" = "OK locked" ] && pass "A: locked" || fail "A: did not lock"
LN=$(lock_window 90) && pass "A: the lock screen is up ($LN)" || fail "A: no lock screen"
G=""
for p in $(pgrep -f 'sg-greeter64.exe /lock'); do
    case "$(cat /proc/"$p"/comm 2>/dev/null)" in sg-greeter64*) G="$G $p" ;; esac
done
[ -n "$G" ] && kill -9 $G 2>/dev/null
sleep 3
[ "$(ctl STATUS)" = "OK locked" ] && pass "A: the lock UI killed: still locked" || fail "A: the lock UI killed: no longer locked"
grep -q "exited while locked" "$T/lockd.log" && pass "A: sg-lockd noticed and logged it" || fail "A: not logged: $(tail -2 "$T/lockd.log" | tr '\n' ' ')"
LN=$(lock_window 90) && pass "A: the lock screen came back ($LN)" || fail "A: the lock screen did not come back"
sleep 3
unlock_with correct-horse
[ "$(ctl STATUS)" = "OK unlocked" ] && pass "A: the password unlocks at the lock screen that came back" || fail "A: not unlocked: $(ctl STATUS)"

# B. a lock UI that dies at every start ("version mismatch")
lockd "$T/ui-dies"
ctl LOCK >/dev/null
sleep 4
[ "$(ctl STATUS)" = "OK locked" ] && pass "B: the lock UI dying at every start: still locked" || fail "B: no longer locked"
LN=$(lock_window 60) && pass "B: the stand-in lock screen is up ($LN)" || fail "B: no lock screen: $(tail -3 "$T/lockd.log" | tr '\n' ' ')"
grep -q "stand-in" "$T/lockd.log" && pass "B: sg-lockd logged the failed starts and the stand-in ($(grep -c 'never came up' "$T/lockd.log") failed)" \
    || fail "B: not logged: $(tail -3 "$T/lockd.log" | tr '\n' ' ')"
pgrep -f "sg-lock-fallback /lock" >/dev/null && pass "B: it is sg-lock-fallback" || fail "B: not sg-lock-fallback"
sleep 2
unlock_with wrongpass
[ "$(ctl STATUS)" = "OK locked" ] && pass "B: a wrong password at the stand-in is refused" || fail "B: a wrong password unlocked"
unlock_with correct-horse
[ "$(ctl STATUS)" = "OK unlocked" ] && pass "B: the right password at the stand-in unlocks" || fail "B: not unlocked: $(tail -2 "$T/lockd.log" | tr '\n' ' ')"

# C. a lock UI that never comes up
lockd "$T/ui-hangs" SG_LOCK_UI_HELLO_SECONDS=4
ctl LOCK >/dev/null
sleep 3
[ "$(ctl STATUS)" = "OK locked" ] && pass "C: a hung lock UI: still locked" || fail "C: no longer locked"
LN=$(lock_window 90) && pass "C: the stand-in lock screen is up ($LN)" || fail "C: no lock screen: $(tail -3 "$T/lockd.log" | tr '\n' ' ')"
grep -q "did not come up" "$T/lockd.log" && pass "C: the hung lock UI was stopped and logged" || fail "C: not stopped: $(tail -3 "$T/lockd.log" | tr '\n' ' ')"
sleep 2
unlock_with correct-horse
[ "$(ctl STATUS)" = "OK unlocked" ] && pass "C: the password at the stand-in unlocks" || fail "C: not unlocked"

echo
[ "$RC" -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
