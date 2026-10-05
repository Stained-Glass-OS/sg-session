#!/bin/sh
# shellcheck disable=SC2015,SC2317  # pass/fail one-liners; cleanup runs from the trap
# A share's folder is read in one listing, not a listing plus a request per
# file (sg-netmountd mounts "nohandlecache"). With the kernel's directory
# handle cache, a folder listed again was answered from the cached listing,
# which carries no file details, so each file's stat became a request of its
# own: a folder of 2000 files took seven seconds over Wi-Fi while File
# Explorer stayed blank (David). Here the network is made slow (2 ms each
# way on lo, netem) and the share's folder is listed twice from a cold cache.
# Needs root, a running smbd, cifs-utils and tc: run it on a Stained Glass
# machine (or the QA VM); it makes a throwaway share and removes it.
# Mutant: build sg-netmountd with -DSG_MUTANT_HANDLECACHE.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
[ "$(id -u)" = 0 ] || { echo "SKIP: needs root"; exit 77; }
command -v smbd >/dev/null && [ -x /usr/sbin/mount.cifs ] && systemctl -q is-active smbd && command -v tc >/dev/null && command -v python3 >/dev/null \
    || { echo "SKIP: needs a running smbd, cifs-utils, tc and python3"; exit 77; }
ND="${SG_NETMOUNTD:-$HERE/build/sg-netmountd}"; [ -x "$ND" ] || ND=/usr/libexec/stained-glass/sg-netmountd
[ -x "$ND" ] || { echo "SKIP: no sg-netmountd"; exit 77; }
[ -f /etc/stained-glass/role ] && grep -q '^realm=.' /etc/stained-glass/role && { echo "SKIP: domain-joined (Kerberos path)"; exit 77; }
tc qdisc show dev lo | grep -q netem && { echo "SKIP: lo already has a netem qdisc"; exit 77; }

S=sglisttest$$; D=$(mktemp -d)
i=0; while [ $i -lt 2000 ]; do : > "$D/file$i.txt"; i=$((i + 1)); done
chmod -R a+rwX "$D"
C=/etc/samba/smb.conf; cp "$C" "$D.conf"
printf '\n[%s]\n   path = %s\n   guest ok = yes\n   read only = yes\n' "$S" "$D" >> "$C"
smbcontrol smbd reload-config >/dev/null 2>&1; sleep 1
M=/run/stained-glass-net/unc/localhost/$S
cleanup() {
    tc qdisc del dev lo root 2>/dev/null
    umount "$M" 2>/dev/null; rmdir "$M" 2>/dev/null
    cp "$D.conf" "$C"; smbcontrol smbd reload-config >/dev/null 2>&1; rm -rf "$D" "$D.conf"
}
trap cleanup EXIT INT TERM

out=$("$ND" --uid 65534 MOUNT localhost "$S" 2>&1)
case "$out" in "OK $M") pass "the share mounts ($out)" ;; *) fail "mount: $out"; exit 1 ;; esac
grep " $M cifs " /proc/mounts | grep -q nohandlecache && pass "without the directory handle cache (nohandlecache)" ||
    fail "mounted with the directory handle cache: $(grep " $M cifs " /proc/mounts | cut -d' ' -f4 | head -c 200)"
tc qdisc add dev lo root netem delay 2ms || { echo "SKIP: no netem"; exit 77; }
# a folder listed, then listed again a moment later, as programs do: each
# time the listing and every file's details (stat), from a cold cache
times=$(python3 - "$M" <<'PY'
import os, sys, time
d = sys.argv[1]
for _ in range(2):
    os.system("sync; echo 3 > /proc/sys/vm/drop_caches")
    t = time.time()
    names = os.listdir(d)
    for n in names:
        os.lstat(os.path.join(d, n))
    print("%d %d" % (len(names), (time.time() - t) * 1000))
    time.sleep(1.5)
PY
)
echo "      listings (files ms): $(echo "$times" | tr '\n' ' ')"
worst=0; for ms in $(echo "$times" | cut -d' ' -f2); do [ "$ms" -gt "$worst" ] && worst=$ms; done
[ "$(echo "$times" | head -1 | cut -d' ' -f1)" = 2000 ] && pass "the folder lists its 2000 files" || fail "files: $times"
[ "$worst" -lt 2000 ] && pass "each listing with the files' details in ${worst} ms at most (< 2000; ~8000 asked file by file)" ||
    fail "a listing took $worst ms: each file's details were asked for one by one"
[ $RC = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $RC
