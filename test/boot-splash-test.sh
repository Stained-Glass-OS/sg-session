#!/bin/sh
# sg-boot-splash: an installed machine's boot becomes the quiet one (the
# splash, no Linux text) and each boot entry gets a "(recovery mode)" twin
# that shows it all; live entries are left alone; a twin whose kernel went
# goes; Plymouth's theme is ours, its other settings kept; twice is once; the
# kernel-install plugin makes a new kernel's twin. On a stand-in ESP.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
RC=0; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
E="$T/esp"; mkdir -p "$E/loader/entries" "$T/theme"
touch "$T/theme/stained-glass.plymouth" "$T/theme/stained-glass.script"
mkdir -p "$T/dri/0" "$T/dri/1"; echo 0 > "$T/dri/0/i915_edp_psr_debug"; echo 1 > "$T/dri/1/i915_edp_psr_debug"
export SG_ESP="$E" SG_KERNEL_CMDLINE="$T/cmdline" SG_PLYMOUTHD_CONF="$T/plymouthd.conf" SG_THEME_DIR="$T/theme" SG_NO_INITRD=1 SG_DRI_DEBUG="$T/dri"
OLD="root=PARTUUID=abc rw console=ttyS0 console=tty0 systemd.show_status=yes loglevel=7"
echo "$OLD" > "$T/cmdline"
printf '[Daemon]\nTheme=spinner\nDeviceTimeout=5\n' > "$T/plymouthd.conf"
cat > "$E/loader/entries/debian-6.12.1.conf" <<EOF
title      Stained Glass OS 0.1
version    6.12.1
sort-key   stained-glass
options    $OLD
linux      /debian/6.12.1/linux
initrd     /debian/6.12.1/initrd.img-6.12.1
EOF
printf 'title Stained Glass OS (live)\noptions %s systemd.volatile=overlay\nlinux /x\n' "$OLD" > "$E/loader/entries/sg-live.conf"
printf 'title Old (recovery mode)\noptions x\n' > "$E/loader/entries/debian-6.11.9-recovery.conf"

sh "$HERE/bin/sg-boot-splash" apply
c=$(cat "$T/cmdline")
{ echo " $c " | grep -q ' quiet splash ' && echo " $c " | grep -q ' loglevel=3 ' && ! echo " $c " | grep -q 'loglevel=7\|show_status=yes' \
  && echo " $c " | grep -q ' root=PARTUUID=abc rw console=ttyS0 console=tty0 '; } \
    && pass "kernels to come boot quietly (loud values replaced, the rest kept)" || fail "cmdline: $c"
o=$(sed -n 's/^options *//p' "$E/loader/entries/debian-6.12.1.conf")
[ "$o" = "$c" ] && pass "the boot entry too" || fail "entry options: $o"
r="$E/loader/entries/debian-6.12.1-recovery.conf"
ro=$(sed -n 's/^options *//p' "$r" 2>/dev/null)
{ grep -qx 'title      Stained Glass OS 0.1 (recovery mode)' "$r" && grep -q '^linux      /debian/6.12.1/linux$' "$r" \
  && grep -q '^initrd     /debian/6.12.1/initrd.img-6.12.1$' "$r" && ! echo " $ro " | grep -q ' quiet \| splash ' \
  && echo " $ro " | grep -q ' plymouth.enable=0 ' && echo " $ro " | grep -q ' root=PARTUUID=abc rw '; } \
    && pass "a recovery-mode twin shows Linux's messages (no quiet, no splash), same kernel" || fail "recovery: $(cat "$r" 2>&1)"
# Intel panels: PSR1 at most (PSR2's selective update flickered the X1)
{ [ "$(echo " $c " | grep -o ' i915.enable_psr=[^ ]*' | wc -l)" = 1 ] && echo " $c " | grep -q ' i915.enable_psr=1 ' \
  && echo " $ro " | grep -q ' i915.enable_psr=1 '; } \
    && pass "i915.enable_psr=1 on the command line, the entry and its recovery twin" || fail "psr: $c / $ro"
{ [ "$(cat "$T/dri/0/i915_edp_psr_debug")" = 0x3 ] && [ "$(cat "$T/dri/1/i915_edp_psr_debug")" = 1 ]; } \
    && pass "the running kernel: PSR1 forced where the default was on, a chosen mode kept" \
    || fail "debugfs: $(cat "$T/dri/0/i915_edp_psr_debug") $(cat "$T/dri/1/i915_edp_psr_debug")"
grep -q 'loglevel=7$' "$E/loader/entries/sg-live.conf" || grep -q 'loglevel=7 systemd.volatile' "$E/loader/entries/sg-live.conf" \
    && [ ! -e "$E/loader/entries/sg-live-recovery.conf" ] && pass "live entries are left alone" || fail "live: $(ls "$E/loader/entries")"
[ ! -e "$E/loader/entries/debian-6.11.9-recovery.conf" ] && pass "a twin whose kernel is gone goes" || fail "orphan twin kept"
{ grep -qx 'Theme=stained-glass' "$T/plymouthd.conf" && grep -qx 'ShowDelay=0' "$T/plymouthd.conf" && grep -qx 'DeviceTimeout=8' "$T/plymouthd.conf" \
  && [ "$(grep -c '^Theme=' "$T/plymouthd.conf")" = 1 ]; } && pass "Plymouth's theme is ours, shown at once" || fail "conf: $(cat "$T/plymouthd.conf")"
before=$(cat "$T/cmdline" "$E"/loader/entries/*.conf "$T/plymouthd.conf" | md5sum)
sh "$HERE/bin/sg-boot-splash" apply
[ "$(cat "$T/cmdline" "$E"/loader/entries/*.conf "$T/plymouthd.conf" | md5sum)" = "$before" ] && pass "a second run changes nothing" || fail "not idempotent"

# someone's own PSR choice stays theirs
echo "$OLD i915.enable_psr=0" > "$T/c2"
SG_KERNEL_CMDLINE="$T/c2" SG_ESP="$T/none" sh "$HERE/bin/sg-boot-splash" apply
echo " $(cat "$T/c2") " | grep -q ' i915.enable_psr=0 ' && ! grep -q 'enable_psr=1' "$T/c2" \
    && pass "an i915.enable_psr someone set is kept" || fail "own psr: $(cat "$T/c2")"

# kernel-install: a new kernel's entry gets its twin; a removed one's goes
sed 's/6\.12\.1/6.12.2/g' "$E/loader/entries/debian-6.12.1.conf" > "$E/loader/entries/debian-6.12.2.conf"
mkdir -p "$T/bin"; ln -s "$HERE/bin/sg-boot-splash" "$T/bin/sg-boot-splash"
sed "s#/usr/bin/sg-boot-splash#$T/bin/sg-boot-splash#" "$HERE/kernel/91-sg-recovery.install" > "$T/plugin"
KERNEL_INSTALL_LAYOUT=bls KERNEL_INSTALL_BOOT_ROOT="$E" KERNEL_INSTALL_ENTRY_TOKEN=debian sh "$T/plugin" add 6.12.2 /x
grep -q '(recovery mode)' "$E/loader/entries/debian-6.12.2-recovery.conf" 2>/dev/null && pass "kernel-install: a new kernel gets its recovery twin" || fail "plugin add"
KERNEL_INSTALL_LAYOUT=bls KERNEL_INSTALL_BOOT_ROOT="$E" KERNEL_INSTALL_ENTRY_TOKEN=debian sh "$T/plugin" remove 6.12.2 /x
[ ! -e "$E/loader/entries/debian-6.12.2-recovery.conf" ] && pass "and loses it when the kernel goes" || fail "plugin remove"

# mutant: without the quiet arguments added, the gate must fail
sed 's/^        line="\$line \$a "$/        :/' "$HERE/bin/sg-boot-splash" > "$T/mut"
grep -q '^        :$' "$T/mut" || fail "the mutant did not apply"
echo "$OLD" > "$T/cmdline"; sh "$T/mut" apply
echo " $(cat "$T/cmdline") " | grep -q ' splash ' && fail "MUTANT NOQUIET not detected" || pass "MUTANT NOQUIET leaves the text boot (gate catches it)"
# mutant: without the panel argument, the X1's flicker comes back
sed 's/^        case "\$line" in \*" \${a%%=\*}="\*) ;; \*) line="\$line \$a " ;; esac$/        :/' "$HERE/bin/sg-boot-splash" > "$T/mut2"
grep -q '^        :$' "$T/mut2" || fail "the PSR mutant did not apply"
echo "$OLD" > "$T/cmdline"; sh "$T/mut2" apply
grep -q 'enable_psr=1' "$T/cmdline" && fail "MUTANT NOPSR not detected" || pass "MUTANT NOPSR leaves PSR2 (gate catches it)"
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
