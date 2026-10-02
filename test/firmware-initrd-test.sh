#!/bin/sh
# sg-firmware-initrd on a fake boot partition and firmware tree, with a
# Latitude 3520's kernel log (SOF, Bluetooth, i915 DMC, regulatory.db failed
# from the initrd): the files there go into sg-firmware.initrd (a cpio the
# kernel unpacks over the others: usr/lib/firmware/NAME, links followed),
# each installed entry gets an initrd line for it once, a live entry none; a
# file missing from the tree is left out; the list keeps a file that the next
# boot no longer asks for. --mutant: no initrd line -- the test must fail.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
command -v cpio >/dev/null || { echo "SKIP: needs cpio to read the archive"; exit 77; }
TOOL="$HERE/../bin/sg-firmware-initrd"
if [ "${1:-}" = --mutant ]; then
    sed 's|lines.insert(last + 1, "initrd " + rel)|pass|' "$TOOL" > "$T/tool"; TOOL="$T/tool"
fi
FW="$T/fw"; mkdir -p "$FW/intel/sof/intel-signed" "$FW/i915"
printf 'SOF' > "$FW/intel/sof/intel-signed/sof-tgl.ri"; ln -s intel-signed/sof-tgl.ri "$FW/intel/sof/sof-tgl.ri"
printf 'IBT' > "$FW/intel/ibt-19-0-4.sfi"; printf 'DMC' > "$FW/i915/tgl_dmc_ver2_12.bin"
printf 'REG' > "$FW/regulatory.db"
ESP="$T/esp"; mkdir -p "$ESP/loader/entries" "$ESP/stained-glass"
cat > "$ESP/loader/entries/debian-stained-glass-6.12.conf" <<'E'
title Stained Glass OS
linux /stained-glass/6.12/vmlinuz
options root=PARTUUID=x rw quiet
initrd /stained-glass/initrd
initrd /stained-glass/6.12/kernel-modules.initrd
initrd /stained-glass/sg-theme.initrd
E
printf 'title live\ninitrd /live/initrd\n' > "$ESP/loader/entries/sg-live.conf"
cp "$ESP/loader/entries/sg-live.conf" "$ESP/loader/entries/sg-x-live.conf"
cat > "$T/klog" <<'E'
iwlwifi 0000:00:14.3: firmware: failed to load iwl-debug-yoyo.bin (-2)
platform regulatory.0: firmware: failed to load regulatory.db (-2)
bluetooth hci0: firmware: failed to load intel/ibt-19-0-4.sfi (-2)
i915 0000:00:02.0: [drm] Failed to load DMC firmware i915/tgl_dmc_ver2_12.bin (-ENOENT). Disabling runtime power management.
sof-audio-pci-intel-tgl 0000:00:1f.3: firmware: failed to load intel/sof/sof-tgl.ri (-2)
evil: firmware: failed to load ../../etc/shadow (-2)
E
export SG_ESP="$ESP" SG_FIRMWARE_DIR="$FW" SG_FIRMWARE_LIST="$T/list" SG_KERNEL_LOG="$T/klog"
python3 "$TOOL" update 2> "$T/err"
E="$ESP/loader/entries/debian-stained-glass-6.12.conf"
[ "$(grep -c '^initrd /stained-glass/sg-firmware.initrd$' "$E")" = 1 ] && [ "$(tail -1 "$E")" = "initrd /stained-glass/sg-firmware.initrd" ] \
    && pass "the entry gets the firmware initrd, last" || fail "the entry has no firmware initrd line: $(cat "$E")"
grep -q sg-firmware "$ESP/loader/entries/sg-x-live.conf" && fail "a live entry was changed" || pass "a live entry is left alone"
I="$ESP/stained-glass/sg-firmware.initrd"
if [ -f "$I" ]; then
    (cd "$T" && mkdir x && cd x && cpio -id --quiet < "$I")
    ok=1
    for f in intel/sof/sof-tgl.ri intel/ibt-19-0-4.sfi i915/tgl_dmc_ver2_12.bin regulatory.db; do
        [ -f "$T/x/usr/lib/firmware/$f" ] && [ ! -L "$T/x/usr/lib/firmware/$f" ] || { ok=0; fail "$f is not in the initrd as a file"; }
    done
    [ "$(cat "$T/x/usr/lib/firmware/intel/sof/sof-tgl.ri" 2>/dev/null)" = SOF ] || { ok=0; fail "the link's target's bytes are not there"; }
    [ "$ok" = 1 ] && pass "the four files are in the initrd, links followed"
    [ -e "$T/x/usr/lib/firmware/iwl-debug-yoyo.bin" ] && fail "a file the tree lacks is in it" || pass "a file the tree lacks is left out"
    find "$T/x" -name shadow | grep -q . && fail "a path outside the firmware tree was taken" || pass "a path outside the firmware tree is refused"
else
    fail "no sg-firmware.initrd was written: $(cat "$T/err")"
fi
: > "$T/klog"; python3 "$TOOL" update 2>/dev/null
[ "$(grep -c sg-firmware "$E")" = 1 ] && [ "$(wc -l < "$T/list")" = 4 ] \
    && pass "the next boot keeps the list and adds no second line" || fail "the next boot lost the list or doubled the line"
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
