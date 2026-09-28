#!/bin/sh
# shellcheck disable=SC2015,SC2317  # pass/fail one-liners; cleanup runs from the trap
# A share that refuses a guest (a Windows PC's shares, as Windows 10 and 11
# set them) opens with a name and password (sg-netmountd LOGON: Windows'
# "Enter network credentials", net use /user:). File Explorer listed such a
# PC's shares but showed no files in them: only the guest mount was tried.
# The connection is the requester's alone -- another user cannot read
# through it -- and MOUNT then finds it. Needs root, a running smbd and
# cifs-utils: run it on a Stained Glass machine (or the QA VM); it makes a
# throwaway account and share and removes them.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
[ "$(id -u)" = 0 ] || { echo "SKIP: needs root"; exit 77; }
command -v smbd >/dev/null && command -v smbpasswd >/dev/null && [ -x /usr/sbin/mount.cifs ] && systemctl -q is-active smbd \
    || { echo "SKIP: needs a running smbd, smbpasswd and cifs-utils"; exit 77; }
ND="${SG_NETMOUNTD:-$HERE/build/sg-netmountd}"; [ -x "$ND" ] || ND=/usr/libexec/stained-glass/sg-netmountd
[ -x "$ND" ] || { echo "SKIP: no sg-netmountd"; exit 77; }
[ -f /etc/stained-glass/role ] && grep -q '^realm=.' /etc/stained-glass/role && { echo "SKIP: domain-joined (Kerberos path)"; exit 77; }
ME=$(awk -F: '$3 >= 1000 && $3 < 60000 { print $3; exit }' /etc/passwd)
[ -n "$ME" ] || { echo "SKIP: no ordinary user to act for"; exit 77; }

S=sglogontest$$; A=sgsmb$$; PW='Pw 1,2=3!'
D=$(mktemp -d); echo secret > "$D/readme.txt"
useradd -M -s /usr/sbin/nologin "$A" || { echo "SKIP: cannot add an account"; exit 77; }
chown -R "$A" "$D"
printf '%s\n%s\n' "$PW" "$PW" | smbpasswd -a -s "$A" >/dev/null
C=/etc/samba/smb.conf; cp "$C" "$D.conf"
printf '\n[%s]\n   path = %s\n   guest ok = no\n   valid users = %s\n   read only = no\n' "$S" "$D" "$A" >> "$C"
smbcontrol smbd reload-config >/dev/null 2>&1; sleep 1
U=/run/stained-glass-net/users/$ME/unc/localhost/$S
cleanup() {
    umount "$U" "/run/stained-glass-net/unc/localhost/$S" 2>/dev/null
    cp "$D.conf" "$C"; smbcontrol smbd reload-config >/dev/null 2>&1
    smbpasswd -x "$A" >/dev/null 2>&1; userdel "$A" 2>/dev/null; rm -rf "$D" "$D.conf"
}
trap cleanup EXIT INT TERM

out=$("$ND" --uid "$ME" MOUNT localhost "$S" 2>&1)
case "$out" in ERR*) pass "as a guest the share is refused ($out)" ;; *) fail "a guest got in: $out" ;; esac
out=$("$ND" --uid "$ME" LOGON localhost "$S" "$A" "wrong" 2>&1)
case "$out" in "ERR 13 "*) pass "a wrong password is refused: access denied" ;; *) fail "wrong password: $out" ;; esac
out=$("$ND" --uid "$ME" LOGON localhost "$S" "LOCALHOST\\$A" "$PW" 2>&1)
echo "      $out"
[ "$out" = "OK $U" ] && pass "the right name and password connect (DOMAIN\\user; a password with spaces, commas and =)" || fail "logon: $out"
[ "$(setpriv --reuid "$ME" --regid "$(id -g "$ME")" --clear-groups cat "$U/readme.txt" 2>/dev/null)" = secret ] \
    && pass "the user who connected reads the files" || fail "the user cannot read the files"
setpriv --reuid 65534 --regid 65534 --clear-groups cat "$U/readme.txt" >/dev/null 2>&1 \
    && fail "another user read through someone else's connection" || pass "another user cannot read through it"
grep -rq "$PW" /run/stained-glass-net 2>/dev/null && fail "the password was left on disk" || pass "no password is left in a file"
out=$("$ND" --uid "$ME" MOUNT localhost "$S" 2>&1)
[ "$out" = "OK $U" ] && pass "MOUNT then finds the user's connection" || fail "MOUNT after LOGON: $out"
out=$("$ND" --uid "$ME" LOGOFF localhost "$S" 2>&1)
[ "$out" = OK ] && ! mountpoint -q "$U" && pass "LOGOFF disconnects it" || fail "logoff: $out"
[ $RC = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $RC
