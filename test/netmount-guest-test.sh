#!/bin/sh
# shellcheck disable=SC2015,SC2317  # pass/fail one-liners; cleanup runs from the trap
# \\server\share off a domain (sg-netmountd): with no Kerberos ticket, a share
# is opened as a guest, as Windows opens an open share -- a NAS, a PC's Public
# share. Every UNC path failed with "Required key not available" (sec=krb5
# only). Needs root, a running smbd and cifs-utils: run it on a Stained Glass
# machine (or the QA VM); it makes a throwaway share and removes it.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
[ "$(id -u)" = 0 ] || { echo "SKIP: needs root"; exit 77; }
command -v smbd >/dev/null && [ -x /usr/sbin/mount.cifs ] && systemctl -q is-active smbd || { echo "SKIP: needs a running smbd and cifs-utils"; exit 77; }
ND="${SG_NETMOUNTD:-$HERE/build/sg-netmountd}"; [ -x "$ND" ] || ND=/usr/libexec/stained-glass/sg-netmountd
[ -x "$ND" ] || { echo "SKIP: no sg-netmountd"; exit 77; }
[ -f /etc/stained-glass/role ] && grep -q '^realm=.' /etc/stained-glass/role && { echo "SKIP: domain-joined (Kerberos path)"; exit 77; }

S=sgguesttest$$; D=$(mktemp -d); echo hello > "$D/readme.txt"; chmod -R a+rwX "$D"
C=/etc/samba/smb.conf; cp "$C" "$D.conf"
printf '\n[%s]\n   path = %s\n   guest ok = yes\n   read only = no\n' "$S" "$D" >> "$C"
smbcontrol smbd reload-config >/dev/null 2>&1; sleep 1
cleanup() { umount "/run/stained-glass-net/unc/localhost/$S" 2>/dev/null; cp "$D.conf" "$C"; smbcontrol smbd reload-config >/dev/null 2>&1; rm -rf "$D" "$D.conf"; }
trap cleanup EXIT INT TERM

out=$("$ND" --uid 65534 MOUNT localhost "$S" 2>&1)
echo "      $out"
case "$out" in "OK /run/stained-glass-net/unc/localhost/$S") pass "an open share mounts off a domain, as a guest" ;; *) fail "mount: $out" ;; esac
[ "$(cat "/run/stained-glass-net/unc/localhost/$S/readme.txt" 2>/dev/null)" = hello ] && pass "and its files are there" || fail "no files"
[ $RC = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $RC
