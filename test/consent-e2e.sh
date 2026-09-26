#!/bin/sh
# Elevation consent, end to end (ADR 0012): sg-compositor's SECURE mode +
# sg-brokerd + the Wine consent prompt, with keys injected over the privileged
# virtual keyboard the way remote support types them.
#
# Checks, in order, each meaningful only after the one before it:
#   - teeth: while unlocked, keys reach the user session's key logger
#   administrator (Yes/No):
#   - a request puts the compositor in SECURE mode and the prompt appears on
#     its own X server, not the requester's
#   - Escape declines: nothing runs, and the machine returns to unlocked
#   - Y allows: the program runs, and the prompt is torn down
#   - no prompt over a locked machine: the request is refused
#   standard user (credentials):
#   - a non-administrator's valid password is refused
#   - a wrong administrator password is refused, the right one allows
#   - not one key typed at any prompt -- passwords included -- reached the
#     user session
# PAM runs for real under pam_wrapper/pam_matrix: no real account is used.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
COMP="${SG_COMPOSITOR_BIN:-$HERE/../sg-compositor/build/sg-compositor}"
PFX="${SG_PREFIX:-$HERE/test/tmp/state/prefix}"
PW=/usr/lib/x86_64-linux-gnu/libpam_wrapper.so
PMDIR=/usr/lib/x86_64-linux-gnu/pam_wrapper
RC=0; T=$(mktemp -d /var/tmp/sg-consent.XXXXXX); chmod 755 "$T"; CP=""; BP=""
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
ME=$(id -un)

# shellcheck disable=SC2317  # invoked via trap
cleanup() {
    [ -n "$BP" ] && kill "$BP" 2>/dev/null
    [ -n "$CP" ] && kill "$CP" 2>/dev/null
    sleep 1
    WINEPREFIX="$PFX" "${SG_WINE_DIR:-/opt/wine-sg}/bin/wineserver" -k 2>/dev/null || true
    [ -n "${SG_KEEP:-}" ] && echo "kept $T" || rm -rf "$T"
}
trap cleanup EXIT INT TERM
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }

for t in xev xdotool Xwayland python3; do command -v "$t" >/dev/null || { echo "SKIP: $t missing"; exit 77; }; done
for f in "$COMP" "$HERE/build/sg-vkbd" "$HERE/build/sg-brokerd" "$HERE/build/sg-elevate" "$HERE/build/sg-rdp-pamcheck" \
         "$HERE/build/sg-consent64.exe" "$PW"; do
    [ -e "$f" ] || { echo "SKIP: $f not built"; exit 77; }; done
[ -d "$PFX/drive_c" ] || { echo "SKIP: no prefix at $PFX (run make test first)"; exit 77; }
id -nG | tr ' ' '\n' | grep -qx root && { echo "SKIP: $ME is in group root, which the credential case uses as its administrators"; exit 77; }

mkdir -p "$T/pam.d"
for svc in stained-glass-elevate other; do
    printf 'auth required %s passdb=%s\naccount required %s passdb=%s\n' \
        "$PMDIR/pam_matrix.so" "$T/passdb" "$PMDIR/pam_matrix.so" "$T/passdb" > "$T/pam.d/$svc"
done
printf '%s:correct-horse:stained-glass-elevate\nroot:battery-staple:stained-glass-elevate\n' "$ME" > "$T/passdb"

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

start_broker() {   # $1 = administrators group
    [ -n "$BP" ] && { kill "$BP" 2>/dev/null; sleep 1; }
    rm -f "$T/broker.sock"
    PAM_WRAPPER=1 PAM_WRAPPER_SERVICE_DIR="$T/pam.d" LD_PRELOAD="$PW" SG_BROKER_FOREGROUND=1 \
    SG_BROKER_SOCK="$T/broker.sock" SG_BROKER_PAMCHECK="$HERE/build/sg-rdp-pamcheck" \
    SG_BROKER_CONTROL="$T/ctl.sock" SG_BROKER_PRIV="$T/priv.sock" SG_ADMIN_GROUP="$1" \
    SG_CONSENT_UI="$HERE/lib/sg-consent-ui" SG_CONSENT_TIMEOUT=60 SG_SYSTEM_USER="$ME" \
    SG_LIB="$HERE/lib" SG_LIBEXEC="$HERE/build" SG_LOG_DIR="$T" SG_PREFIX="$PFX" \
    SG_BROKERD_LOG="$T/broker.log" \
        "$HERE/build/sg-brokerd" >/dev/null 2>&1 &
    BP=$!
    _w=0; while [ ! -S "$T/broker.sock" ] && [ $_w -lt 50 ]; do sleep 0.2; _w=$((_w+1)); done
}
request() {   # $1 = marker file the elevated program writes; result in $T/$1.rc
    rm -f "$T/$1" "$T/$1.rc"
    ( SG_BROKER_SOCK="$T/broker.sock" "$HERE/build/sg-elevate" -- /bin/sh -c "echo ran > $T/$1" \
        >/dev/null 2>&1; echo $? > "$T/$1.rc" ) &
}
wait_rc() {   # $1 = marker; waits for the request to finish
    _w=0; while [ ! -s "$T/$1.rc" ] && [ $_w -lt 90 ]; do sleep 1; _w=$((_w+1)); done
    sleep 1
    cat "$T/$1.rc" 2>/dev/null || echo timeout
}
PN=""
find_prompt() {   # sets PN to the display showing the prompt
    PN=""; _w=0
    while [ $_w -lt 60 ]; do
        for d in /tmp/.X11-unix/X*; do
            n=":${d##*/X}"; [ "$n" = "$XD" ] && continue
            DISPLAY="$n" xdotool search --name 'Permission required' >/dev/null 2>&1 && { PN="$n"; return 0; }
        done
        sleep 1; _w=$((_w+1))
    done
    return 1
}
prompt_gone() {
    sleep 2
    ! { [ -n "$PN" ] && DISPLAY="$PN" xdotool search --name 'Permission required' >/dev/null 2>&1; }
}

# Teeth.
UW=$(DISPLAY="$XD" xdotool search --name 'Event Tester' 2>/dev/null | head -1)
tries=0
until user_keys | grep -qx b; do
    tries=$((tries+1)); [ $tries -gt 8 ] && break
    DISPLAY="$XD" xdotool windowfocus "$UW" 2>/dev/null; sleep 1; inj b
done
user_keys | grep -qx b && pass "unlocked: keys reach the user session (the gate has teeth)" \
    || { fail "unlocked: the user session never received a key -- result meaningless"; echo "RESULT: FAIL"; exit 1; }
before=$(user_keys | wc -l)

# ---- an administrator: Yes / No -----------------------------------------
start_broker "$(id -gn)"

request a1
find_prompt && pass "the consent prompt appears (on its own X server, $PN)" || fail "no consent prompt appeared"
[ "$(ctl STATUS)" = "OK secure" ] && pass "the compositor is in SECURE mode while it asks" || fail "not in SECURE mode during the prompt"
DISPLAY="$XD" xdotool search --name 'Permission required' >/dev/null 2>&1 \
    && fail "the prompt is on the requester's own display" || pass "the prompt is not on the requester's display"
sleep 2
inj -k Shift_L; inj -k Escape
rc=$(wait_rc a1)
[ "$rc" = 1 ] && pass "Escape declines (sg-elevate: denied)" || fail "Escape: sg-elevate returned $rc"
[ -e "$T/a1" ] && fail "a declined program ran" || pass "a declined program did not run"
[ "$(ctl STATUS)" = "OK unlocked" ] && pass "declining returns the machine to unlocked" || fail "still $(ctl STATUS) after declining"
prompt_gone && pass "the prompt is torn down" || fail "the prompt is still up"

request a2
find_prompt || fail "no second prompt"
sleep 2
# Focus starts on No; Enter there would deny. Move to Yes, then press it.
inj -k Shift_L; inj -k Left; inj -k Return
rc=$(wait_rc a2)
[ "$rc" = 0 ] && pass "Yes allows (sg-elevate: launched)" || fail "Yes: sg-elevate returned $rc"
sleep 1
[ -e "$T/a2" ] && pass "the allowed program ran" || fail "the allowed program did not run"
[ "$(ctl STATUS)" = "OK unlocked" ] && pass "allowing returns the machine to unlocked" || fail "still $(ctl STATUS) after allowing"
prompt_gone && pass "the prompt is torn down" || fail "the prompt is still up"
grep -q "elevated for $ME, authorised by $ME" "$T/broker.log" && pass "the elevation is logged with who authorised it" \
    || fail "no authorisation record"

[ "$(ctl LOCK)" = "OK locked" ] || fail "could not lock for the locked-machine case"
request a3
rc=$(wait_rc a3)
[ "$rc" = 1 ] && pass "no prompt over a locked machine: refused" || fail "locked machine: sg-elevate returned $rc"
[ -e "$T/a3" ] && fail "a program ran while the machine was locked" || true
[ "$(ctl STATUS)" = "OK locked" ] && pass "the lock survives the refused request" || fail "the refused request changed the lock: $(ctl STATUS)"
ctl UNLOCK >/dev/null

# ---- a standard user: an administrator's credentials ---------------------
# The administrators here are group root, so $ME is a standard user and root
# is the administrator whose password is asked for.
start_broker root

request b1
find_prompt || fail "no credential prompt appeared"
sleep 2
inj x; inj -k BackSpace
inj "$ME" -k Tab
inj 'correct-horse' -k Return
sleep 5
grep -q 'credentials refused' "$T/broker.log" && pass "a standard user's own valid password is refused" \
    || fail "a non-administrator's credentials were not refused"
[ "$(ctl STATUS)" = "OK secure" ] && pass "still asking after a refusal" || fail "state after refusal: $(ctl STATUS)"
inj -k Escape
rc=$(wait_rc b1)
[ "$rc" = 1 ] && [ ! -e "$T/b1" ] && pass "declined: nothing ran" || fail "b1: rc=$rc, ran=$([ -e "$T/b1" ] && echo yes || echo no)"
prompt_gone || fail "the credential prompt is still up"

request b2
find_prompt || fail "no second credential prompt"
sleep 2
inj x; inj -k BackSpace
inj root -k Tab
inj 'wrong-staple' -k Return
sleep 5
[ "$(grep -c 'credentials refused' "$T/broker.log")" -ge 2 ] && pass "a wrong administrator password is refused" \
    || fail "a wrong administrator password was not refused"
[ -e "$T/b2" ] && fail "ran after a wrong password" || true
# After a refusal the prompt keeps the name and returns focus to the password.
inj 'battery-staple' -k Return
rc=$(wait_rc b2)
[ "$rc" = 0 ] && pass "the administrator's password allows" || fail "right password: sg-elevate returned $rc"
sleep 1
[ -e "$T/b2" ] && pass "the program ran after an administrator approved" || fail "the approved program did not run"
grep -q "elevated for $ME, authorised by root" "$T/broker.log" && pass "logged as authorised by root, requested by $ME" \
    || fail "no record naming the approving administrator"
[ "$(ctl STATUS)" = "OK unlocked" ] && pass "back to unlocked" || fail "still $(ctl STATUS)"

after=$(user_keys | wc -l)
leaked=$(user_keys | tail -n +$((before + 1)) | tr '\n' ' ')
if [ "$after" -eq "$before" ]; then pass "not one key typed at a prompt (passwords included) reached the user session"
else fail "keys typed at the prompt reached the user session: $leaked"; fi
grep -q 'audit: secure prompt engaged' "$T/comp.log" && pass "the compositor audited the secure prompts" || fail "no compositor audit record"

echo
if [ "$RC" -eq 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; cat "$T/broker.log"; fi
exit "$RC"
