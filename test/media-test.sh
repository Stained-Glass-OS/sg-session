#!/bin/sh
# shellcheck disable=SC2015  # pass/fail one-liners: both only print
# Removable media for File Explorer: the udev rule (71-stained-glass-media)
# mounts what arrives, shared, and not on every "change" -- unmounting is one,
# and remounting undid File Explorer's Eject; the automount unit runs as the
# Windows system; the polkit rule stops at removable drives.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
R="$HERE/udev/71-stained-glass-media.rules"
if command -v udevadm >/dev/null && udevadm verify --help >/dev/null 2>&1; then
    udevadm verify --no-summary "$R" >/dev/null 2>&1 && pass "the udev rule is well-formed" || fail "udevadm verify: $(udevadm verify "$R" 2>&1 | head -2)"
fi
grep -q '^ENV{UDISKS_FILESYSTEM_SHARED}="1"' "$R" && pass "media mount under /media/<label>, open to every account" || fail "not shared"
grep -q '^ACTION=="change", ENV{DISK_MEDIA_CHANGE}=="1", RUN' "$R" && pass "a disc put in mounts (DISK_MEDIA_CHANGE)" || fail "media change"
grep -E '^ACTION=="change"' "$R" | grep -vq 'DISK_MEDIA_CHANGE' && fail "a plain change (an unmount) remounts" || pass "an unmount does not remount"
grep -q '^User=sgsystem' "$HERE/systemd/sg-automount@.service" && pass "automount runs as the Windows system" || fail "automount user"
P="$HERE/config/polkit/50-stained-glass-media.rules"
grep -q 'action.lookup("drive.removable") != "true"' "$P" && pass "polkit grants only for removable drives" || fail "polkit scope"
if command -v node >/dev/null; then
    node -e "global.polkit={addRule:function(f){},Result:{}}; require('$P')" 2>/dev/null && pass "the polkit rule parses" || fail "polkit rule syntax"
fi
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
