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
# a copy to a USB drive shows real progress, no long wait at eject (72-...):
# a USB disk or SD card holds at most 16 MB of writes not yet on it -- and
# not the machine's own disk (eMMC is type MMC, not SD)
W="$HERE/udev/72-stained-glass-usb-writes.rules"
if command -v udevadm >/dev/null && udevadm verify --help >/dev/null 2>&1; then
    udevadm verify --no-summary "$W" >/dev/null 2>&1 && pass "the write-back rule is well-formed" || fail "udevadm verify: $(udevadm verify "$W" 2>&1 | head -2)"
fi
grep -q '^ATTR{bdi/strict_limit}="1"' "$W" && grep -q '^ATTR{bdi/max_bytes}="16777216"' "$W" \
    && pass "USB disks and SD cards: at most 16 MB of unwritten data, at the drive's pace" || fail "write-back limits"
grep -q 'ENV{ID_BUS}=="usb", GOTO="sg_usb_writes"' "$W" && grep -q 'ATTRS{type}=="SD", GOTO="sg_usb_writes"' "$W" \
    && ! grep -q '^SUBSYSTEMS=="mmc"' "$W" && pass "USB and SD only, not the machine's eMMC" || fail "scope of the write-back rule"
grep -q 'udev/72-stained-glass-usb-writes.rules' "$HERE/Makefile" && pass "installed" || fail "not installed"

[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
