#!/bin/sh
# ClamAV's directories are clamav's (tmpfiles/sg-session.conf): an image
# build leaves /var/lib/clamav and /var/log/clamav root's, as clamav-base's
# postinst chown fails in its user namespace, and freshclam then never
# writes a definition. The real tmpfiles lines run on a scratch root where
# the image's root-owned directories are, in a user namespace that maps
# clamav's ids (unshare --map-auto), as boot and sg-session's postinst run them.
# Mutant: SG_MUTANT_CLAMAV_ROOT=1 (the lines left out).
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
if ! unshare --map-auto --map-root-user true 2>/dev/null; then
    echo "SKIP  no subordinate ids for a user namespace"; exit 0
fi
T=$(mktemp -d); chmod 755 "$T"
trap 'unshare --map-auto --map-root-user rm -rf "$T"' EXIT
mkdir -p "$T/root/etc" "$T/root/var/lib/clamav" "$T/root/var/log/clamav"
chmod 755 "$T/root/var/lib/clamav" "$T/root/var/log/clamav"
echo 'clamav:x:101:106::/var/lib/clamav:/bin/false' > "$T/root/etc/passwd"
echo 'clamav:x:106:' > "$T/root/etc/group"
: > "$T/root/var/log/clamav/clamav.log"; chmod 640 "$T/root/var/log/clamav/clamav.log"
grep clamav "$HERE/tmpfiles/sg-session.conf" | grep -v '^#' > "$T/clamav.conf"
[ "${SG_MUTANT_CLAMAV_ROOT:-0}" = 1 ] && : > "$T/clamav.conf"
unshare --map-auto --map-root-user sh -c '
    systemd-tmpfiles --root="$1/root" --create "$1/clamav.conf" >"$1/log" 2>&1
    stat -c "%n %u:%g %a" "$1/root/var/lib/clamav" "$1/root/var/log/clamav" "$1/root/var/log/clamav/clamav.log" > "$1/stat"
    su_ok=1; for d in var/lib/clamav var/log/clamav; do
        setpriv --reuid=101 --regid=106 --clear-groups sh -c "mkdir \"$1/root/$d/tmp.x\" && rmdir \"$1/root/$d/tmp.x\"" 2>/dev/null || su_ok=0
    done; echo $su_ok > "$1/write"' sh "$T"
RC=0
grep -q "var/lib/clamav 101:106 755$" "$T/stat" && echo "PASS  /var/lib/clamav is clamav's" || { echo "FAIL  /var/lib/clamav: $(cat "$T/stat" "$T/log")"; RC=1; }
grep -q "var/log/clamav 101:106 755$" "$T/stat" && echo "PASS  /var/log/clamav is clamav's" || { echo "FAIL  /var/log/clamav: $(cat "$T/stat")"; RC=1; }
grep -q "clamav.log 101:106 640$" "$T/stat" && echo "PASS  clamd's log file is clamav's, still not world-readable" || { echo "FAIL  clamav.log: $(cat "$T/stat")"; RC=1; }
[ "$(cat "$T/write")" = 1 ] && echo "PASS  clamav can make freshclam's temporary directory in both" || { echo "FAIL  clamav cannot write there"; RC=1; }
exit $RC
