#!/bin/sh
. "$(dirname "$0")/scratch-home.sh"
# Gate: every session has a keyring (gnome-keyring's Secret Service, which
# VPN clients such as Eddie, browsers, mail and chat programs keep their
# passwords in), opened by the sign-in password, and it keeps opening:
#
#   1. the first sign-in (sg-keyring-first, then pam_gnome_keyring opening
#      the user manager's daemon, in a session-like D-Bus bus): secret-tool
#      stores and returns a secret with no prompt, and the keyring file on
#      disk does not hold it in the clear;
#   2. the lock screen's PAM check (sg-rdp-pamcheck, sg-lockd's) opens a
#      locked keyring with the password typed -- through the real
#      stained-glass-lock PAM file, from a process without XDG_RUNTIME_DIR,
#      as sg-lockd is -- and a wrong password leaves it locked;
#   3. (root: run as root, or with sudo -n) sg-password-change, a person
#      changing their own password, re-encrypts the keyring through the real
#      stained-glass-password PAM file and the system's common-password: a
#      wrong current password is refused; signed out, the next session opens
#      the keyring with the new password and not the old; signed in, the
#      running session keeps its secrets and the next one opens with the new
#      password. A temporary account is made for it (homes under /var/tmp)
#      and removed. SG_KEYRING_NO_ROOT=1 skips this part.
#
# --mutant NAME builds the helpers with -DSG_MUTANT_NAME (LOCK_KEYRING,
# PWCHANGE_RUID, PWCHANGE_RUNTIME, KEYRING_FIRST); the gate must then fail.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
MUTANT=
[ "${1:-}" = --mutant ] && MUTANT=${2:?mutant name}
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
skip() { echo "SKIP: $*"; exit 77; }

for t in gnome-keyring-daemon secret-tool dbus-run-session gdbus cc; do
    command -v "$t" >/dev/null || skip "needs $t (gnome-keyring, libsecret-tools, dbus, libglib2.0-bin, a C compiler)"
done
ls /usr/lib/*/security/pam_gnome_keyring.so >/dev/null 2>&1 || skip "needs pam_gnome_keyring (libpam-gnome-keyring)"

T=$(mktemp -d /var/tmp/sg-keyring-gate.XXXXXX) || exit 1
chmod 755 "$T"
SUDO=
ROOTDIR=
TU=
cleanup() {
    [ -f "$T/stop" ] || : > "$T/stop"
    sleep 1
    if [ -n "$TU" ]; then
        $SUDO pkill -u "$TU" 2>/dev/null; sleep 1; $SUDO pkill -9 -u "$TU" 2>/dev/null
        $SUDO userdel -r "$TU" >/dev/null 2>&1
    fi
    [ -n "$ROOTDIR" ] && $SUDO rm -rf "$ROOTDIR"
    rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

DEF=
[ -n "$MUTANT" ] && DEF="-DSG_MUTANT_$MUTANT"
# shellcheck disable=SC2086
cc -O2 $DEF -o "$T/sg-rdp-pamcheck" "$HERE/greeter/sg-rdp-pamcheck.c" -lpam || skip "cannot build sg-rdp-pamcheck (libpam0g-dev)"
# shellcheck disable=SC2086
cc -O2 $DEF -o "$T/sg-password-change" "$HERE/greeter/sg-password-change.c" -lpam || skip "cannot build sg-password-change"
# shellcheck disable=SC2086
cc -O2 $DEF -o "$T/sg-keyring-first" "$HERE/greeter/sg-keyring-first.c" || skip "cannot build sg-keyring-first"

# session.sh PASSWORD STOPFILE BUSFILE: a session bus with a keyring daemon
# opened by PASSWORD at its start, until STOPFILE. PASSWORD "-": the daemon as
# the user manager starts it (its socket unit's command line), not opened --
# pam_gnome_keyring then opens it through its control socket, as at sign-in.
cat > "$T/session.sh" <<'EOF'
if [ "$1" = - ]; then
    gnome-keyring-daemon --foreground --components=pkcs11,secrets --control-directory="$XDG_RUNTIME_DIR/keyring" >/dev/null 2>&1 &
    _w=0; while [ ! -S "$XDG_RUNTIME_DIR/keyring/control" ] && [ $_w -lt 50 ]; do sleep 0.1; _w=$((_w + 1)); done
else
    printf '%s' "$1" | gnome-keyring-daemon --unlock --components=secrets >/dev/null 2>&1
fi
echo "$DBUS_SESSION_BUS_ADDRESS" > "$3.tmp" && mv "$3.tmp" "$3"
while [ ! -e "$2" ]; do sleep 0.3; done
# only this session's daemon (never another of the account's: a real session's)
for p in $(pgrep -u "$(id -u)" -x gnome-keyring-d); do
    tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -qx "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR" && kill "$p"
done
exit 0
EOF
# start_session RUNTIME_DIR PASSWORD NAME [sudo -u USER]: in the background
start_session() {
    _rd=$1 _pw=$2 _n=$3; shift 3
    rm -f "$T/$_n.stop" "$T/$_n.bus"
    "$@" env -i PATH=/usr/bin:/bin HOME="${SESSION_HOME:-$HOME}" XDG_RUNTIME_DIR="$_rd" \
        dbus-run-session -- sh "$T/session.sh" "$_pw" "$T/$_n.stop" "$T/$_n.bus" >/dev/null 2>&1 &
    _w=0
    while [ ! -s "$T/$_n.bus" ] && [ $_w -lt 100 ]; do sleep 0.1; _w=$((_w + 1)); done
    sleep 0.5
}
stop_session() {
    : > "$T/$1.stop"
    _w=0; while pgrep -f "$T/$1.stop" >/dev/null && [ $_w -lt 50 ]; do sleep 0.1; _w=$((_w + 1)); done
    sleep 0.3
}
# in_session NAME RUNTIME_DIR [sudo -u USER] -- CMD...: run CMD on that bus
in_session() {
    _n=$1 _rd=$2; shift 2
    _pre=""
    while [ "$1" != -- ]; do _pre="$_pre $1"; shift; done; shift
    # shellcheck disable=SC2086
    $_pre env -i PATH=/usr/bin:/bin HOME="${SESSION_HOME:-$HOME}" XDG_RUNTIME_DIR="$_rd" \
        DBUS_SESSION_BUS_ADDRESS="$(cat "$T/$_n.bus")" timeout 15 "$@"
}
locked() { # NAME RUNTIME [sudo -u USER] -> true / false / error
    in_session "$@" -- gdbus call --session --dest org.freedesktop.secrets \
        --object-path /org/freedesktop/secrets/collection/login --method org.freedesktop.DBus.Properties.Get \
        org.freedesktop.Secret.Collection Locked 2>&1 | sed -n 's/.*<\(true\|false\)>.*/\1/p'
}

# --- 1. the first sign-in: a session's keyring ---------------------------------
# What greetd's PAM stack does: the auth stack checks the password, then
# sg-keyring-first (pam_exec, stained-glass-keyring) makes the login keyring
# if there is none; the session stack's pam_gnome_keyring opens it in the
# daemon the user manager started on its socket. Without the first step
# gnome-keyring makes the keyring itself through the socket and never
# publishes it on D-Bus (the first store prompts for a new keyring password).
ME=$(id -un); MYUID=$(id -u)
RR="$T/rr"; mkdir -p "$RR/$MYUID"; chmod 755 "$RR"; chmod 700 "$RR/$MYUID"
PW='Gate#Pass1'
KR="$HOME/.local/share/keyrings/login.keyring"
first() { # SERVICE: sg-keyring-first as pam_exec runs it in the auth stack
    printf '%s\0' "$PW" | env PAM_USER="$ME" PAM_TYPE=auth PAM_SERVICE="$1" SG_KEYRING_FIRST_HOME="$HOME" "$T/sg-keyring-first"
}
first sudo
[ ! -e "$KR" ] && pass "sg-keyring-first leaves other services alone (sudo)" || fail "sg-keyring-first acted for sudo"
first greetd
[ -f "$KR" ] && pass "the first sign-in at the login screen makes the login keyring" || fail "no login keyring after the first sign-in"
leftover=$(find /tmp -maxdepth 1 -name 'sg-keyring-*' -user "$ME" 2>/dev/null)
[ -z "$leftover" ] && pass "... and leaves nothing in /tmp" || fail "left behind: $leftover"
before=$(stat -c %Y.%s "$KR" 2>/dev/null)
sleep 1.1; first greetd
[ "$(stat -c %Y.%s "$KR" 2>/dev/null)" = "$before" ] && pass "a later sign-in leaves the keyring alone" || fail "a later sign-in rewrote the keyring"
mkdir -p "$T/conf"
# The real lock file, its password check (common-auth: the account's real
# password) stood in for by pam_exec, which takes the password as pam_unix
# does (pam_gnome_keyring needs it) and accepts it -- PAM resolves @include
# in /etc/pam.d even with a configuration directory.
sed -e 's/^@include common-auth$/auth required pam_exec.so expose_authtok quiet \/bin\/true/' \
    -e 's/^@include common-account$/account required pam_permit.so/' \
    "$HERE/config/pam/stained-glass-lock" > "$T/conf/stained-glass-lock"
lockcheck() { # PASSWORD -> the checker's reply; as sg-lockd runs it, without XDG_RUNTIME_DIR
    printf '%s\0%s\0' "$ME" "$1" | env -u XDG_RUNTIME_DIR SG_PAMCHECK_CONSOLE=1 SG_REMOTE_PAM_SERVICE=stained-glass-lock \
        SG_PAM_CONFDIR="$T/conf" SG_RUNTIME_ROOT="$RR" "$T/sg-rdp-pamcheck" 2>/dev/null
}
start_session "$RR/$MYUID" - s1
[ -s "$T/s1.bus" ] || { fail "no session bus came up"; exit 1; }
# pam_gnome_keyring's open (the session's, here through the lock stack's auth:
# the same control-socket unlock)
lockcheck "$PW" >/dev/null
printf 'eddie-vpn-secret' | in_session s1 "$RR/$MYUID" -- secret-tool store --label='Eddie VPN' app eddie user gate
got=$(in_session s1 "$RR/$MYUID" -- secret-tool lookup app eddie user gate 2>/dev/null)
[ "$got" = eddie-vpn-secret ] && pass "secret-tool stores a secret and finds it again, with no prompt" \
    || fail "secret-tool lookup gave '$got'"
[ "$(locked s1 "$RR/$MYUID")" = false ] && pass "the login keyring is open" || fail "the login keyring is not open"
if [ -f "$KR" ] && ! grep -q eddie-vpn-secret "$KR"; then
    pass "the keyring file on disk does not hold the secret in the clear"
else fail "no login.keyring, or the secret is in it in the clear"; fi

# --- 2. the lock screen opens it -------------------------------------------------
lock_keyring() {
    in_session s1 "$RR/$MYUID" -- gdbus call --session --dest org.freedesktop.secrets --object-path /org/freedesktop/secrets \
        --method org.freedesktop.Secret.Service.Lock "['/org/freedesktop/secrets/collection/login']" >/dev/null 2>&1
}
lock_keyring
[ "$(locked s1 "$RR/$MYUID")" = true ] && pass "(the keyring locked for the test)" || fail "could not lock the keyring"
r=$(lockcheck 'not-the-password')
[ "$(locked s1 "$RR/$MYUID")" = true ] && pass "a wrong password at the lock screen leaves the keyring locked ($r)" \
    || fail "a wrong password opened the keyring"
r=$(lockcheck "$PW")
if [ "$r" = OK ] && [ "$(locked s1 "$RR/$MYUID")" = false ]; then
    pass "unlocking the screen opens the keyring with the password typed"
else fail "after unlocking the screen ($r) the keyring is locked: $(locked s1 "$RR/$MYUID")"; fi
got=$(in_session s1 "$RR/$MYUID" -- secret-tool lookup app eddie user gate 2>/dev/null)
[ "$got" = eddie-vpn-secret ] && pass "... and the secret is there" || fail "after unlock: '$got'"
stop_session s1

# a fresh session (the next sign-in) opens it with the password, not without
start_session "$RR/$MYUID" "$PW" s2
got=$(in_session s2 "$RR/$MYUID" -- secret-tool lookup app eddie user gate 2>/dev/null)
[ "$got" = eddie-vpn-secret ] && pass "the next session opens the same keyring with the password" || fail "next session: '$got'"
stop_session s2
start_session "$RR/$MYUID" 'wrong-password' s3
[ "$(locked s3 "$RR/$MYUID")" = true ] && pass "... and a wrong password does not open it" || fail "a wrong password opened the keyring"
stop_session s3

# --- 3. changing one's own password re-encrypts the keyring -----------------------------
if [ "${SG_KEYRING_NO_ROOT:-0}" = 1 ]; then
    echo "SKIP  (root part: SG_KEYRING_NO_ROOT=1)"
elif [ "$(id -u)" != 0 ] && ! sudo -n true 2>/dev/null; then
    echo "SKIP  (root part: not root and no sudo -n): sg-password-change untested here"
elif ! grep -qs '^[^#]*pam_gnome_keyring' /etc/pam.d/common-password; then
    echo "SKIP  (root part: this machine's common-password has no pam_gnome_keyring -- pam-auth-update)"
else
    [ "$(id -u)" = 0 ] || SUDO="sudo -n"
    ROOTDIR=$($SUDO mktemp -d /var/tmp/sg-keyring-root.XXXXXX) && $SUDO chmod 755 "$ROOTDIR"
    TU="sgkr$(date +%s | tail -c 6)"
    $SUDO useradd -m -b "$ROOTDIR" -s /bin/sh "$TU" || { fail "cannot make the test account"; exit 1; }
    TUID=$(id -u "$TU")
    OLD='Old#Pass1234' NEW='New#Pass5678' THIRD='Third#Pass9012'
    printf '%s:%s\n' "$TU" "$OLD" | $SUDO chpasswd
    $SUDO install -d -m 755 "$ROOTDIR/conf" "$ROOTDIR/rr"
    $SUDO install -d -m 700 -o "$TU" -g "$TU" "$ROOTDIR/rr/$TUID" "$ROOTDIR/rr2"
    # (its @include resolves in /etc/pam.d: the system's own common-password)
    $SUDO cp "$HERE/config/pam/stained-glass-password" "$ROOTDIR/conf/"
    SESSION_HOME="$ROOTDIR/$TU"
    export SESSION_HOME
    # the test account's sessions write to this file
    chmod 777 "$T"
    as_tu="$SUDO -u $TU"
    [ "$(id -u)" = 0 ] && as_tu="runuser -u $TU --"
    change() { # CURRENT NEW RUNTIME_ROOT -> the helper's reply
        printf '%s\0%s\0%s\0' "$TU" "$1" "$2" | $SUDO env SG_PAM_CONFDIR="$ROOTDIR/conf" SG_RUNTIME_ROOT="$3" "$T/sg-password-change"
    }
    # The keyring is made at the account's first session, with its password.
    # shellcheck disable=SC2086
    start_session "$ROOTDIR/rr2" "$OLD" t1 $as_tu
    # shellcheck disable=SC2086
    printf 'eddie-vpn-secret' | in_session t1 "$ROOTDIR/rr2" $as_tu -- secret-tool store --label='Eddie VPN' app eddie
    stop_session t1

    r=$(change 'Wrong#Pass000' "$NEW" "$ROOTDIR/none")
    [ "$r" = "FAIL current" ] && pass "a wrong current password is refused ($r)" || fail "wrong current password: '$r'"

    # signed out: no daemon is running
    r=$(change "$OLD" "$NEW" "$ROOTDIR/none")
    [ "$r" = OK ] && pass "a signed-out person's password changes ($r)" || fail "signed-out change: '$r'"
    # shellcheck disable=SC2086
    start_session "$ROOTDIR/rr2" "$NEW" t2 $as_tu
    # shellcheck disable=SC2086
    got=$(in_session t2 "$ROOTDIR/rr2" $as_tu -- secret-tool lookup app eddie 2>/dev/null)
    [ "$got" = eddie-vpn-secret ] && pass "... and the next sign-in opens the keyring with the new password" \
        || fail "after a signed-out change the new password does not open the keyring ('$got')"
    stop_session t2
    # shellcheck disable=SC2086
    start_session "$ROOTDIR/rr2" "$OLD" t3 $as_tu
    # shellcheck disable=SC2086
    [ "$(locked t3 "$ROOTDIR/rr2" $as_tu)" = true ] && pass "... and the old password no longer does" \
        || fail "the old password still opens the keyring"
    stop_session t3
    left=$($SUDO find /tmp -maxdepth 1 -name 'sg-keyring-*' -user "$TU" 2>/dev/null)
    [ -z "$left" ] && pass "... and nothing is left in /tmp" || fail "left behind: $left"

    # signed in: the session's daemon, in the person's runtime directory
    # shellcheck disable=SC2086
    start_session "$ROOTDIR/rr/$TUID" "$NEW" t4 $as_tu
    r=$(change "$NEW" "$THIRD" "$ROOTDIR/rr")
    [ "$r" = OK ] && pass "a signed-in person's password changes ($r)" || fail "signed-in change: '$r'"
    # shellcheck disable=SC2086
    got=$(in_session t4 "$ROOTDIR/rr/$TUID" $as_tu -- secret-tool lookup app eddie 2>/dev/null)
    [ "$got" = eddie-vpn-secret ] && pass "... the running session keeps its secrets" || fail "running session after change: '$got'"
    stop_session t4
    # shellcheck disable=SC2086
    start_session "$ROOTDIR/rr2" "$THIRD" t5 $as_tu
    # shellcheck disable=SC2086
    got=$(in_session t5 "$ROOTDIR/rr2" $as_tu -- secret-tool lookup app eddie 2>/dev/null)
    [ "$got" = eddie-vpn-secret ] && pass "... and after signing out and in, the new password opens the keyring" \
        || fail "after a signed-in change the new password does not open the keyring ('$got')"
    stop_session t5
fi

[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
