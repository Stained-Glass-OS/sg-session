#!/bin/sh
. "$(dirname "$0")/scratch-home.sh"
# Gate: sg-keyring, behind the sign-in notice "Your saved passwords are
# locked" -- a keyring an administrator's password reset left on the old
# password (chpasswd cannot re-encrypt it: there is no current password).
#
#   1. a keyring made with the old password, a session signed in with the
#      new one: status says "locked"
#   2. recover: a wrong current password is refused (PAM decides; a typing
#      slip must not lock the keyring away again), a wrong old one too; the
#      right pair opens it in the running session, the secret is there, and
#      the next sign-in opens it with the new password (not the old)
#   3. reset: after another reset, a new empty login keyring with the current
#      password -- programs store and find secrets in it at once and the next
#      sign-in opens it; the old file kept aside, no secret in the clear
#   4. status: "none" with no keyring, "unavailable" with no session bus
#
# PAM: a stand-in for common-auth (the password in a file of the gate's), the
# real stained-glass-keyring file otherwise. --mutant NAME builds sg-keyring
# with -DSG_MUTANT_NAME (KEYRING_NOCHECK); the gate must then fail.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
MUTANT=
[ "${1:-}" = --mutant ] && MUTANT=${2:?mutant name}
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
skip() { echo "SKIP: $*"; exit 77; }

for t in gnome-keyring-daemon secret-tool dbus-run-session cc pkg-config; do
    command -v "$t" >/dev/null || skip "needs $t"
done
pkg-config --exists gio-2.0 || skip "needs libglib2.0-dev"

T=$(mktemp -d /var/tmp/sg-keyring-recover.XXXXXX) || exit 1
cleanup() { for n in "$T"/*.stop.want; do [ -e "$n" ] && : > "${n%.want}"; done; sleep 1; rm -rf "$T"; }
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

DEF=
[ -n "$MUTANT" ] && DEF="-DSG_MUTANT_$MUTANT"
# shellcheck disable=SC2086
cc -O2 $DEF -o "$T/sg-keyring" "$HERE/greeter/sg-keyring.c" $(pkg-config --cflags --libs gio-2.0) -lpam \
    || skip "cannot build sg-keyring (libpam0g-dev)"

# PAM: the real file, its common-auth stood in for by a check of the
# password against $T/current
mkdir -p "$T/conf"
cat > "$T/check.sh" <<EOF
#!/bin/sh
p=\$(tr -d '\\0'); [ "\$p" = "\$(cat "$T/current")" ]
EOF
chmod +x "$T/check.sh"
sed "s|^@include common-auth\$|auth required pam_exec.so expose_authtok quiet $T/check.sh|" \
    "$HERE/config/pam/stained-glass-keyring" > "$T/conf/stained-glass-keyring"
grep -q "pam_exec" "$T/conf/stained-glass-keyring" || { fail "stained-glass-keyring has no common-auth"; exit 1; }

RT="$T/run"; mkdir -p "$RT"; chmod 700 "$RT"
KDIR="$HOME/.local/share/keyrings"
OLD='Old#Pass1234' NEW='New#Pass5678' THIRD='Third#Pass9012'

# a session: its bus, and a keyring daemon opened (or not) with PASSWORD at
# its start, as the sign-in's pam_gnome_keyring opens it; until NAME.stop
cat > "$T/session.sh" <<'EOF'
printf '%s' "$1" | gnome-keyring-daemon --unlock --components=secrets >/dev/null 2>&1
echo "$DBUS_SESSION_BUS_ADDRESS" > "$3.tmp" && mv "$3.tmp" "$3"
while [ ! -e "$2" ]; do sleep 0.3; done
for p in $(pgrep -u "$(id -u)" -x gnome-keyring-d); do
    tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -qx "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR" && kill "$p"
done
exit 0
EOF
start() { # PASSWORD NAME
    rm -f "$T/$2.stop" "$T/$2.bus"; : > "$T/$2.stop.want"
    env -i PATH=/usr/bin:/bin HOME="$HOME" XDG_RUNTIME_DIR="$RT" \
        dbus-run-session -- sh "$T/session.sh" "$1" "$T/$2.stop" "$T/$2.bus" >/dev/null 2>&1 &
    _w=0; while [ ! -s "$T/$2.bus" ] && [ $_w -lt 100 ]; do sleep 0.1; _w=$((_w + 1)); done
    sleep 0.5
}
stop() { : > "$T/$1.stop"; rm -f "$T/$1.stop.want"; sleep 1.5; }
in_s() { # NAME CMD...
    _n=$1; shift
    env -i PATH=/usr/bin:/bin HOME="$HOME" XDG_RUNTIME_DIR="$RT" DBUS_SESSION_BUS_ADDRESS="$(cat "$T/$_n.bus")" \
        SG_PAM_CONFDIR="$T/conf" timeout 30 "$@"
}
kr() { # NAME VERB [FIELDS...]: sg-keyring, the fields NUL-terminated on stdin
    _n=$1 _v=$2; shift 2
    if [ $# -gt 0 ]; then printf '%s\0' "$@" | in_s "$_n" "$T/sg-keyring" "$_v"
    else in_s "$_n" "$T/sg-keyring" "$_v" </dev/null; fi
}

# --- 4 (first): no keyring yet -----------------------------------------------
echo "$NEW" > "$T/current"
start '' s0
r=$(kr s0 status)
[ "$r" = none ] && pass "no login keyring: status says none" || fail "status with no keyring: '$r'"
stop s0
r=$(env -i PATH=/usr/bin:/bin HOME="$HOME" DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent "$T/sg-keyring" status)
[ "$r" = unavailable ] && pass "no session bus: status says unavailable" || fail "status with no bus: '$r'"
rm -rf "$KDIR"

# --- 1. made with the old password, signed in with the new -------------------
start "$OLD" s1
printf 'mail-secret' | in_s s1 secret-tool store --label='Mail' app sg-mail
stop s1
start "$NEW" s2
r=$(kr s2 status)
[ "$r" = locked ] && pass "after a reset the sign-in leaves the keyring locked: status says locked" \
    || fail "status after a reset: '$r'"

# --- 2. recover -------------------------------------------------------------------
r=$(kr s2 recover "$OLD" 'Not#Current1')
[ "$r" = "FAIL current" ] && pass "recover: a wrong current password is refused ($r)" || fail "wrong current: '$r'"
r=$(kr s2 recover 'Not#TheOld1' "$NEW")
[ "$r" = "FAIL old" ] && pass "recover: a wrong old password is refused ($r)" || fail "wrong old: '$r'"
[ "$(kr s2 status)" = locked ] && pass "... and both leave it locked" || fail "a refused recover changed the keyring"
r=$(kr s2 recover "$OLD" "$NEW")
[ "$r" = OK ] && [ "$(kr s2 status)" = open ] && pass "recover with the old and the current password opens it ($r)" \
    || fail "recover: '$r', status $(kr s2 status)"
got=$(in_s s2 secret-tool lookup app sg-mail 2>/dev/null)
[ "$got" = mail-secret ] && pass "... the saved password is there" || fail "after recover: '$got'"
stop s2
start "$NEW" s3
[ "$(kr s3 status)" = open ] && [ "$(in_s s3 secret-tool lookup app sg-mail 2>/dev/null)" = mail-secret ] \
    && pass "... and the next sign-in opens it with the current password" || fail "next sign-in after recover: $(kr s3 status)"
stop s3
start "$OLD" s4
[ "$(kr s4 status)" = locked ] && pass "... and no longer with the old one" || fail "the old password still opens it"
stop s4

# --- 3. reset ---------------------------------------------------------------------
echo "$THIRD" > "$T/current"
start "$THIRD" s5
[ "$(kr s5 status)" = locked ] || fail "(another reset: not locked)"
r=$(kr s5 reset 'Not#Current1')
[ "$r" = "FAIL current" ] && pass "reset: a wrong current password is refused" || fail "reset with a wrong password: '$r'"
r=$(kr s5 reset "$THIRD")
[ "$r" = OK ] && [ "$(kr s5 status)" = open ] && pass "reset makes a new, open login keyring ($r)" \
    || fail "reset: '$r', status $(kr s5 status)"
[ -z "$(in_s s5 secret-tool lookup app sg-mail 2>/dev/null)" ] && pass "... without the old saved passwords" \
    || fail "the new keyring has the old secret"
printf 'vpn-secret' | in_s s5 secret-tool store --label='VPN' app sg-vpn
[ "$(in_s s5 secret-tool lookup app sg-vpn 2>/dev/null)" = vpn-secret ] && pass "... programs store and find secrets in it, no prompt" \
    || fail "storing in the new keyring"
stop s5
kept=$(find "$KDIR" -name 'login.keyring.before-reset-*' | head -1)
[ -n "$kept" ] && [ -f "$KDIR/login.keyring" ] && pass "the old keyring is kept aside ($(basename "$kept"))" \
    || fail "keyrings: $(ls "$KDIR" 2>&1 | tr '\n' ' ')"
if ! grep -q vpn-secret "$KDIR/login.keyring" && ! grep -q mail-secret "$KDIR"/login.keyring*; then
    pass "no secret in the clear on disk"
else fail "a secret is in the clear on disk"; fi
start "$THIRD" s6
[ "$(kr s6 status)" = open ] && [ "$(in_s s6 secret-tool lookup app sg-vpn 2>/dev/null)" = vpn-secret ] \
    && pass "the next sign-in opens the new keyring" || fail "next sign-in after reset: $(kr s6 status)"
stop s6

[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
