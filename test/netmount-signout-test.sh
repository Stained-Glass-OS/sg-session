#!/bin/sh
# shellcheck disable=SC2015,SC2317  # pass/fail one-liners; cleanup runs from the trap
# A user's connections made with a name and password (sg-netmountd LOGON:
# net use /user:, "Enter network credentials") end with their last session,
# as their drive letters do (user-runtime-dir@.service.d/
# 50-stained-glass-drives.conf). They stayed mounted after sign-out, and the
# next sign-in used them without the password. Here a stand-in connection
# (tmpfs mounts, one with a space in the share's name) is made for uid 65534
# and that uid's user-runtime-dir@ is started and stopped, as at a sign-in
# and a sign-out. Needs root and systemd: run it on a Stained Glass machine
# (or the QA VM). SG_DROPIN names the drop-in to test (default: the
# repository's, installed in /run for the test and removed after).
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
RC=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; RC=1; }
[ "$(id -u)" = 0 ] || { echo "SKIP: needs root"; exit 77; }
command -v systemctl >/dev/null && [ -d /run/systemd/system ] || { echo "SKIP: needs systemd"; exit 77; }
U=65534
loginctl list-users --no-legend 2>/dev/null | awk '{print $1}' | grep -qx "$U" && { echo "SKIP: uid $U has a session"; exit 77; }
DROPIN="${SG_DROPIN:-$HERE/systemd/user-runtime-dir@.service.d/50-stained-glass-drives.conf}"
OVR=/run/systemd/system/user-runtime-dir@.service.d
B=/run/stained-glass-net/users/$U/unc/sgsignout
cleanup() {
    umount "$B/share" "$B/my share" 2>/dev/null
    rm -rf "/run/stained-glass-net/users/$U" "$OVR/60-sg-signout-test.conf"
    rmdir "$OVR" 2>/dev/null
    systemctl daemon-reload
}
trap cleanup EXIT INT TERM
mkdir -p "$OVR" && cp "$DROPIN" "$OVR/60-sg-signout-test.conf" && systemctl daemon-reload
mkdir -p "$B/share" "$B/my share"
mount -t tmpfs -o size=1m tmpfs "$B/share" && mount -t tmpfs -o size=1m tmpfs "$B/my share" || { echo "SKIP: cannot mount"; exit 77; }
# the stand-ins are tmpfs: the drop-in looks for the SMB mounts (cifs) it
# makes, so let it see these too while it runs
sed -i 's/ -t cifs / -t cifs,tmpfs /' "$OVR/60-sg-signout-test.conf" && systemctl daemon-reload
systemctl start "user-runtime-dir@$U.service" && systemctl stop "user-runtime-dir@$U.service"
if grep -q " /run/stained-glass-net/users/$U/" /proc/mounts; then
    fail "the connections are still mounted after the sign-out: $(grep " /run/stained-glass-net/users/$U/" /proc/mounts | cut -d' ' -f2 | tr '\n' ' ')"
else pass "the user's own connections end with their last session (a share named with a space too)"; fi
[ ! -e "/run/stained-glass-net/users/$U" ] && pass "and their folder goes" || fail "/run/stained-glass-net/users/$U is still there"
[ $RC = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $RC
