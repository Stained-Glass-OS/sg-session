#!/bin/sh
# The nouveau guard in an installed machine's initrds: nouveau starts in the
# initrd, where on an NVIDIA Ada card (10de:2680-28ff) without its GSP
# firmware it removed the firmware framebuffer and then failed -- a black
# screen from the boot logo on. sg-firmware-initrd puts sg-nouveau-guard and
# its modprobe.d line into sg-firmware.initrd, which every installed entry
# loads last (the image's initrd and Debian's alike), on such a PC only and
# only while NVIDIA's driver is not installed. Fake sysfs, boot partition,
# firmware tree and modprobe.d; touches nothing real.
#   1. Ada card, no driver: the guard and its line are in the initrd (the
#      script executable), every installed entry loads it, a live one not;
#      the guard taken from the initrd keeps nouveau out on that card.
#   2. A new kernel's entry (Debian's initrd, the kernel-install plugin's run):
#      it gets the initrd line too.
#   3. NVIDIA's driver installed (modprobe.blacklist=nouveau in
#      /etc/kernel/cmdline; or its modprobe.d blacklist): the guard is gone
#      from the initrd again.
#   4. No NVIDIA Ada card (an Ampere one): no guard, and an ESP that never
#      had the initrd gets no line.
#   --mutant: sg-firmware-initrd never wants the guard (must FAIL)
# shellcheck disable=SC2015  # pass || fail
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/sg-nouveau-initrd.XXXXXX"); trap 'rm -rf "$T"' EXIT
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
command -v cpio >/dev/null || { echo "SKIP: needs cpio to read the archive"; exit 77; }
TOOL="$HERE/bin/sg-firmware-initrd"
if [ "${1:-}" = --mutant ]; then
    sed 's/^    return ada and not nouveau_blacklisted()$/    return False/' "$TOOL" > "$T/tool"; TOOL="$T/tool"
    cmp -s "$TOOL" "$HERE/bin/sg-firmware-initrd" && { echo "mutant not applied"; exit 1; }
fi
gpu() { # DIR VENDOR CLASS DEVICE
    mkdir -p "$T/sys/$1"; echo "$2" > "$T/sys/$1/vendor"; echo "$3" > "$T/sys/$1/class"; echo "$4" > "$T/sys/$1/device"
}
mkdir -p "$T/fw" "$T/etc/modprobe.d" "$T/lib/modprobe.d" "$T/esp/loader/entries" "$T/esp/stained-glass" "$T/x"
cp "$HERE/modprobe/sg-nouveau-guard.conf" "$T/lib/modprobe.d/"
echo "root=PARTUUID=x rw quiet splash" > "$T/cmdline"
gpu 0000:00:02.0 0x8086 0x030000 0x46a6
gpu 0000:01:00.0 0x10de 0x030200 0x2860
E="$T/esp/loader/entries/stained-glass-6.12.48.conf"
cat > "$E" <<'EOF'
title Stained Glass OS
linux /stained-glass/6.12.48/vmlinuz
options root=PARTUUID=x rw quiet
initrd /stained-glass/initrd
initrd /stained-glass/6.12.48/kernel-modules.initrd
initrd /stained-glass/sg-theme.initrd
EOF
printf 'title live\ninitrd /live/initrd\n' > "$T/esp/loader/entries/sg-x-live.conf"
export SG_ESP="$T/esp" SG_FIRMWARE_DIR="$T/fw" SG_FIRMWARE_LIST="$T/list" SG_KERNEL_LOG="$T/klog" \
    SG_NOUVEAU_GUARD="$HERE/lib/sg-nouveau-guard" SG_NOUVEAU_GUARD_CONF="$HERE/modprobe/sg-nouveau-guard.conf" \
    SG_KERNEL_CMDLINE_FILE="$T/cmdline" SG_MODPROBE_DIRS="$T/etc/modprobe.d:$T/lib/modprobe.d" SG_GUARD_SYSFS="$T/sys"
: > "$T/klog"
run() { python3 "$TOOL" update 2> "$T/err"; }
unpack() { # INITRD -> $T/x
    rm -rf "$T/x"; mkdir "$T/x"; [ -f "$1" ] && (cd "$T/x" && cpio -id --quiet < "$1")
}
has_guard() {
    [ -f "$T/x/usr/lib/modprobe.d/sg-nouveau-guard.conf" ] && [ -x "$T/x/usr/lib/stained-glass/sg-nouveau-guard" ]
}
I="$T/esp/stained-glass/sg-firmware.initrd"

# --- 1 -------------------------------------------------------------------------
run
if [ "$(grep -c '^initrd /stained-glass/sg-firmware.initrd$' "$E")" = 1 ] && [ "$(tail -1 "$E")" = "initrd /stained-glass/sg-firmware.initrd" ]; then
    pass "Ada card, no driver: the entry loads sg-firmware.initrd, last (it overlays the image's initrd)"
else fail "Ada card: the entry has no sg-firmware.initrd line: $(cat "$E"; cat "$T/err")"; fi
grep -q sg-firmware "$T/esp/loader/entries/sg-x-live.conf" && fail "a live entry was changed" || pass "a live entry is left alone"
unpack "$I"
if has_guard && cmp -s "$T/x/usr/lib/stained-glass/sg-nouveau-guard" "$HERE/lib/sg-nouveau-guard" \
        && grep -q '^install nouveau /usr/lib/stained-glass/sg-nouveau-guard' "$T/x/usr/lib/modprobe.d/sg-nouveau-guard.conf"; then
    pass "...it carries the guard (executable) and its modprobe.d install line"
else fail "the initrd has no guard: $(cd "$T/x" 2>/dev/null && find . | tr '\n' ' ')"; fi
# what the initrd's modprobe runs for nouveau: the guard from the archive,
# with the initrd's (empty) firmware tree
if [ -x "$T/x/usr/lib/stained-glass/sg-nouveau-guard" ]; then
    printf '#!/bin/sh\necho "$*" >> "%s/loaded"\n' "$T" > "$T/modprobe"; chmod +x "$T/modprobe"
    rm -f "$T/loaded"
    SG_GUARD_FIRMWARE="$T/x/usr/lib/firmware" SG_GUARD_MODPROBE="$T/modprobe" SG_GUARD_KMSG="$T/kmsg" \
        sh "$T/x/usr/lib/stained-glass/sg-nouveau-guard" modeset=1
    [ ! -e "$T/loaded" ] && grep -q 'not loading nouveau' "$T/kmsg" 2>/dev/null \
        && pass "...and the guard from the initrd keeps nouveau out on that card (the kernel log says why)" \
        || fail "the initrd's guard let nouveau load"
fi

# --- 2 -------------------------------------------------------------------------
E2="$T/esp/loader/entries/stained-glass-6.12.57+3.conf"
mkdir -p "$T/esp/stained-glass/6.12.57"
cat > "$E2" <<'EOF'
title Stained Glass OS
linux /stained-glass/6.12.57/linux
options root=PARTUUID=x rw quiet
initrd /stained-glass/6.12.57/initrd.img-6.12.57-amd64
EOF
run
unpack "$T/esp/stained-glass/6.12.57/sg-firmware.initrd"
if [ "$(tail -1 "$E2")" = "initrd /stained-glass/6.12.57/sg-firmware.initrd" ] && has_guard; then
    pass "a new kernel's entry (Debian's initrd) gets the guard's initrd too"
else fail "the new kernel's entry: $(cat "$E2")"; fi

# --- 3 -------------------------------------------------------------------------
echo "root=PARTUUID=x rw quiet splash modprobe.blacklist=nouveau" > "$T/cmdline"
run
unpack "$I"
if ! has_guard && [ -f "$I" ]; then pass "NVIDIA's driver installed (nouveau blacklisted on the command line): the guard is gone from the initrd"
else fail "the guard stayed with NVIDIA's driver installed"; fi
echo "root=PARTUUID=x rw quiet splash" > "$T/cmdline"
run; unpack "$I"; has_guard || fail "the guard did not come back without the driver"
echo "blacklist nouveau" > "$T/etc/modprobe.d/nvidia-blacklists-nouveau.conf"
run; unpack "$I"
! has_guard && pass "...and with the driver package's own modprobe.d blacklist" || fail "the guard stayed with a modprobe.d blacklist"
rm "$T/etc/modprobe.d/nvidia-blacklists-nouveau.conf"

# --- 4 -------------------------------------------------------------------------
echo 0x2520 > "$T/sys/0000:01:00.0/device"
run; unpack "$I"
! has_guard && pass "an NVIDIA Ampere card (nouveau runs it): no guard" || fail "the guard is there for a card that needs none"
rm -rf "$T/esp2"; mkdir -p "$T/esp2/loader/entries"; cp "$E2" "$T/esp2/loader/entries/a.conf"; sed -i '/sg-firmware/d' "$T/esp2/loader/entries/a.conf"
SG_ESP="$T/esp2" python3 "$TOOL" update 2>/dev/null
grep -q sg-firmware "$T/esp2/loader/entries/a.conf" && fail "an entry got an initrd line with nothing to carry" \
    || pass "nothing to carry: no initrd line is added"
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
