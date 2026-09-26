#!/bin/sh
. "$(dirname "$0")/scratch-home.sh"
# The lock screen, end to end: compositor + sg-lockd + the Wine greeter in lock
# mode, with keys injected over the privileged virtual keyboard the way remote
# access types them.
#
# Checks, in order, each meaningful only after the one before it:
#   - teeth: while unlocked, keys reach the user session's key logger
#   - Win+L locks and the lock screen appears
#   - a wrong password is refused and the machine stays locked
#   - the right password unlocks, and the lock UI is torn down
#   - not one key typed at the lock screen reached the user session
#   - the user's lock-screen picture (published as Settings does) is staged
#     for the lock UI while locked, shown on its screen, and removed after
# PAM runs for real under pam_wrapper/pam_matrix: no real account is used.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
COMP="${SG_COMPOSITOR_BIN:-$HERE/../sg-compositor/build/sg-compositor}"
PFX="${SG_PREFIX:-$HERE/test/tmp/state/prefix}"
PW=/usr/lib/x86_64-linux-gnu/libpam_wrapper.so
PMDIR=/usr/lib/x86_64-linux-gnu/pam_wrapper
RC=0; T=$(mktemp -d); chmod 755 "$T"; CP=""; LP=""
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
LOCKN="${SG_LOCK_DISPLAY_NUM:-99}"

# shellcheck disable=SC2317  # invoked via trap
cleanup() {
    [ -n "$LP" ] && kill "$LP" 2>/dev/null
    [ -n "$CP" ] && kill "$CP" 2>/dev/null
    sleep 1
    WINEPREFIX="$PFX" "${SG_WINE_DIR:-/opt/wine-sg}/bin/wineserver" -k 2>/dev/null || true
    rm -rf "$T"
}
trap cleanup EXIT INT TERM
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }

for t in xev xdotool Xwayland python3; do command -v "$t" >/dev/null || { echo "SKIP: $t missing"; exit 77; }; done
for f in "$COMP" "$HERE/build/sg-vkbd" "$HERE/build/sg-lockd" "$HERE/build/sg-rdp-pamcheck" "$HERE/build/sg-greeter64.exe" "$PW"; do
    [ -e "$f" ] || { echo "SKIP: $f not built"; exit 77; }; done
[ -d "$PFX/drive_c" ] || { echo "SKIP: no prefix at $PFX (run make test first)"; exit 77; }

mkdir -p "$T/pam.d"
for svc in stained-glass-lock other; do
    printf 'auth required %s passdb=%s\naccount required %s passdb=%s\n' \
        "$PMDIR/pam_matrix.so" "$T/passdb" "$PMDIR/pam_matrix.so" "$T/passdb" > "$T/pam.d/$svc"
done
printf '%s:correct-horse:stained-glass-lock\n' "$(id -un)" > "$T/passdb"

# The user's lock-screen picture, published the way Settings does it.
mkdir -m 1733 "$T/drop"
python3 -c "from PIL import Image; Image.new('RGB', (800, 600), (0x10, 0xA0, 0x90)).save('$T/pic.png')" 2>/dev/null \
    && SG_LOCKSCREEN_DIR="$T/drop" "$HERE/bin/sg-settingsctl" lockscreen picture "$T/pic.png" >/dev/null 2>&1

ctl() { python3 -c "import socket;s=socket.socket(socket.AF_UNIX);s.connect('$T/ctl.sock');s.sendall(b'$1\n');print(s.recv(64).decode().strip())"; }
inj() { WAYLAND_DISPLAY="$T/priv.sock" "$HERE/build/sg-vkbd" "$@"; sleep 1; }
user_keys() { awk '/^KeyPress/{p=1;next} p&&match($0,/keysym 0x[0-9a-f]+, [A-Za-z_0-9]+\)/){s=substr($0,RSTART,RLENGTH); sub(/.*, /,"",s); sub(/\)/,"",s); print s; p=0}' "$T/user.txt"; }

WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman \
    "$COMP" -L "$T/priv.sock" -C "$T/ctl.sock" -U "$(id -u)" -- \
    sh -c "echo \$DISPLAY > $T/xd; exec xev -event keyboard" >"$T/user.txt" 2>"$T/comp.log" &
CP=$!
_w=0; while [ ! -s "$T/xd" ] && [ $_w -lt 50 ]; do sleep 0.2; _w=$((_w+1)); done
sleep 2
XD=$(cat "$T/xd")

PAM_WRAPPER=1 PAM_WRAPPER_SERVICE_DIR="$T/pam.d" LD_PRELOAD="$PW" \
SG_LOCK_PAMCHECK="$HERE/build/sg-rdp-pamcheck" SG_LOCK_CONTROL="$T/ctl.sock" SG_LOCK_PRIV="$T/priv.sock" \
SG_LOCK_UI="$HERE/lib/sg-lock-ui" SG_LIB="$HERE/lib" SG_LIBEXEC="$HERE/build" SG_LOG_DIR="$T" \
SG_PREFIX="$PFX" SG_LOCKD_LOG="$T/lockd.log" SG_LOCK_DISPLAY_NUM="$LOCKN" \
SG_LOCKSCREEN_DIR="$T/drop" TMPDIR="$T" \
    "$HERE/build/sg-lockd" >/dev/null 2>&1 &
LP=$!
_w=0; while ! grep -q watching "$T/lockd.log" 2>/dev/null && [ $_w -lt 50 ]; do sleep 0.2; _w=$((_w+1)); done

# Teeth. Focus the user session's logger and keep typing an ordinary key until
# it is seen -- the first keys can be lost while XWayland takes the keymap.
UW=$(DISPLAY="$XD" xdotool search --name 'Event Tester' 2>/dev/null | head -1)
tries=0
until user_keys | grep -qx b; do
    tries=$((tries+1)); [ $tries -gt 8 ] && break
    DISPLAY="$XD" xdotool windowfocus "$UW" 2>/dev/null; sleep 1; inj b
done
user_keys | grep -qx b && pass "unlocked: keys reach the user session (the gate has teeth)" \
    || { fail "unlocked: the user session never received a key -- result meaningless"; echo "RESULT: FAIL"; exit 1; }
before=$(user_keys | wc -l)

# Win+L with the L held on for 4 s, across the lock screen's appearance (a
# person holding it a moment too long): its auto-repeat must not type into
# the new lock screen's password box -- the first password tried below must
# work.
inj -M logo -D l -m logo -s 4 -U l
[ "$(ctl STATUS)" = "OK locked" ] && pass "Win+L locks" || fail "Win+L did not lock"
# The baseline is taken once locked: Win+L's Super key is pressed while the
# session is still unlocked, and legitimately reaches it.
sleep 1
before=$(user_keys | wc -l)
_w=0; LN=""
while [ $_w -lt 60 ]; do
    for d in /tmp/.X11-unix/X*; do
        n=":${d##*/X}"; [ "$n" = "$XD" ] && continue
        DISPLAY="$n" xdotool search --name 'Sign in' >/dev/null 2>&1 && { LN="$n"; break 2; }
    done
    sleep 1; _w=$((_w+1))
done
[ -n "$LN" ] && pass "the lock screen appears (on its own X server, $LN)" || fail "no lock screen appeared"
sleep 3
if [ -s "$T/drop/$(id -un)" ]; then
    staged=$(ls "$T"/sg-lockpic-* 2>/dev/null | head -1)
    [ -n "$staged" ] && cmp -s "$staged" "$T/pic.png" && pass "the user's lock-screen picture is staged for the lock UI" \
        || fail "the user's lock-screen picture was not staged"
    if [ -n "$LN" ] && command -v convert >/dev/null && xwd -display "$LN" -root -silent 2>/dev/null | convert xwd:- "$T/lock.png" 2>/dev/null; then
        v=$(convert "$T/lock.png" -format '%[fx:int(255*p{20,20}.r)] %[fx:int(255*p{20,20}.g)] %[fx:int(255*p{20,20}.b)]' info: 2>/dev/null)
        [ "$v" = "16 160 144" ] && pass "the lock screen shows the picture ($v)" || fail "the lock screen shows $v, not the picture"
        [ -n "${ARTIFACTS:-}" ] && mkdir -p "$ARTIFACTS" && cp "$T/lock.png" "$ARTIFACTS/lock-screen.png"
    fi
else echo "note: no picture published (python3-pil missing?); picture checks skipped"; fi

inj x; inj -k BackSpace   # warm up the lock server's keymap, then clear
# the box is empty: the L held across the lock typed nothing into it
inj 'correct-horse' -k Return
sleep 5
if [ "$(ctl STATUS)" = "OK unlocked" ]; then
    pass "a key held across the lock typed nothing: the first password unlocks"
else
    fail "the first password did not unlock -- the held key typed into the box"
    grep -q 'unlock refused' "$T/lockd.log" && echo "      (sg-lockd refused it)"
    inj -k Escape; inj -k BackSpace   # ... and carry on from where it is
fi
# lock again (a plain Win+L) for the refusal checks
relock_from=$(user_keys | wc -l); relock_to=$relock_from
[ "$(ctl STATUS)" = "OK unlocked" ] && { inj -M logo l -m logo; sleep 4; relock_to=$(user_keys | wc -l); }
inj x; inj -k BackSpace
inj 'wrongpass' -k Return
sleep 5
[ "$(ctl STATUS)" = "OK locked" ] && pass "a wrong password is refused; still locked" || fail "a wrong password unlocked"
grep -q 'unlock refused' "$T/lockd.log" && pass "the refusal is logged" || fail "refusal not logged"

inj 'correct-horse' -k Return
sleep 5
[ "$(ctl STATUS)" = "OK unlocked" ] && pass "the right password unlocks" || fail "the right password did not unlock"
sleep 2
if [ -n "$LN" ] && DISPLAY="$LN" xdotool search --name 'Sign in' >/dev/null 2>&1; then
    fail "the lock screen is still up after unlocking"
else pass "the lock screen is torn down after unlocking"; fi
if [ -s "$T/drop/$(id -un)" ]; then
    ls "$T"/sg-lockpic-* >/dev/null 2>&1 && fail "the staged picture outlived the lock screen" \
        || pass "the staged picture is removed after unlocking"
fi

# (the re-lock's Win+L was typed while unlocked and legitimately reached it)
after=$(user_keys | wc -l)
leaked=$(user_keys | awk -v b="$before" -v f="$relock_from" -v t="$relock_to" 'NR > b && (NR <= f || NR > t)' | tr '\n' ' ')
if [ -z "$leaked" ]; then pass "not one key typed at the lock screen reached the user session"
else fail "keys typed at the lock screen reached the user session: $leaked"; fi

echo
if [ "$RC" -eq 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; fi
exit "$RC"
