#!/bin/sh
# sg-boot-space (the kernel-install plugin 85-sg-boot-space): a kernel update
# never fills the boot partition. Offline, on a stand-in boot partition with
# the image's layout (an entry named after the image, shared initrds) and a
# fixed amount of room (SG_BS_FREE). SG_BS_MUTANT=NO_PRUNE / NO_CHECK / NO_BOOTED must
# fail it.
# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck disable=SC2015,SC2012
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
export SG_BOOT_SPACE="$HERE/bin/sg-boot-space"
PLUGIN="$HERE/kernel/85-sg-boot-space.install"
T=$(mktemp -d "${TMPDIR:-/tmp}/sg-bs-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
MB=$((1024 * 1024))
A=6.12.117+deb13-amd64 B=6.12.118+deb13-amd64 C=6.12.119+deb13-amd64
export SG_BS_REFRESH=0 KERNEL_INSTALL_ENTRY_TOKEN=tok KERNEL_INSTALL_LAYOUT=bls
# the boot loader's word on the entry it started: none, unless a case says
export SG_BS_CMDLINE="$T/cmdline" SG_BS_EFIVAR="$T/efivar"
echo "root=x" > "$T/cmdline"

mkfile() { mkdir -p "$(dirname "$1")"; truncate -s "$2" "$1"; }
# the boot partition as Setup leaves it: the image's kernel A
fresh() {
    rm -rf "$T/b" "$T/src" "$T/notice"; E="$T/b/loader/entries"; mkdir -p "$E" "$T/src"
    export KERNEL_INSTALL_BOOT_ROOT="$T/b" SG_BS_NOTICE="$T/notice"
    mkfile "$T/b/tok/$A/vmlinuz" $((12 * MB)); mkfile "$T/b/tok/$A/kernel-modules.initrd" $((171 * MB))
    mkfile "$T/b/tok/initrd" $((37 * MB)); mkfile "$T/b/tok/sg-theme.initrd" 16384
    printf 'title Stained Glass OS\nlinux /tok/%s/vmlinuz\ninitrd /tok/initrd\ninitrd /tok/%s/kernel-modules.initrd\ninitrd /tok/sg-theme.initrd\noptions root=x\n' "$A" "$A" > "$E/tok-tok-$A.conf"
    # a restore point (sg-snapshot's) and another system's entry: never ours to touch
    printf 'title restore\nlinux /tok/%s/vmlinuz\ninitrd /tok/initrd\noptions x\n' "$A" > "$E/Sg-restore-1.conf"
    mkfile "$T/b/other/vmlinuz" $MB
    printf 'title Other\nlinux /other/vmlinuz\n' > "$E/other.conf"
    mkfile "$T/b/EFI/BOOT/BOOTX64.EFI" $MB
}
# a Debian kernel V as kernel-install leaves it ($2: the entry's name suffix)
debian_kernel() {
    mkfile "$T/b/tok/$1/linux" $((12 * MB)); mkfile "$T/b/tok/$1/initrd.img-$1" $((76 * MB))
    printf 'title Stained Glass OS\nlinux /tok/%s/linux\ninitrd /tok/%s/initrd.img-%s\noptions root=x\n' "$1" "$1" "$1" > "$E/tok-$1${2:-}.conf"
    printf 'title recovery\nlinux /tok/%s/linux\ninitrd /tok/%s/initrd.img-%s\noptions root=x\n' "$1" "$1" "$1" > "$E/tok-$1-recovery.conf"
}
src_kernel() { mkfile "$T/src/vmlinuz-$1" $((12 * MB)); mkfile "$T/src/initrd.img-$1" $((76 * MB)); }
# the plugin as kernel-install runs it for "add V"
add() {
    src_kernel "$1"; mkdir -p "$T/b/tok/$1"
    "$PLUGIN" add "$1" "$T/b/tok/$1" "$T/src/vmlinuz-$1" "$T/src/initrd.img-$1" 2>>"$T/log"
}

# 1. the first update: the image's kernel runs; B fits beside it; nothing goes
fresh; export SG_BS_UNAME=$A SG_BS_FREE=$((512 * MB))
add "$B"; rc=$?
[ "$rc" = 0 ] && [ -f "$E/tok-tok-$A.conf" ] && [ -f "$T/b/tok/initrd" ] && [ -f "$T/b/tok/$A/kernel-modules.initrd" ] \
    && pass "first update: the running image kernel and its files stay (rc $rc)" || fail "first update touched the running kernel (rc $rc)"
[ ! -f "$T/notice" ] && pass "first update: no notice" || fail "a notice although B fits"

# 2. the next update, running B: the image's kernel goes, and with it the
# initrds only its entry named; restore point, other system, EFI untouched
debian_kernel "$B" ""
export SG_BS_UNAME=$B
add "$C"; rc=$?
[ "$rc" = 0 ] && pass "second update installs (rc $rc)" || fail "second update rc $rc"
[ ! -f "$E/tok-tok-$A.conf" ] && [ ! -d "$T/b/tok/$A" ] && pass "the image's kernel (neither running nor newest) went: entry and directory" \
    || fail "the image's kernel is still on the boot partition"
[ -f "$E/tok-$B.conf" ] && [ -f "$T/b/tok/$B/linux" ] && pass "the running kernel stays" || fail "the running kernel was removed"
[ ! -f "$T/b/tok/sg-theme.initrd" ] && pass "a shared initrd no entry names went" || fail "sg-theme.initrd left behind"
[ -f "$E/Sg-restore-1.conf" ] && [ -f "$E/other.conf" ] && [ -f "$T/b/other/vmlinuz" ] && [ -f "$T/b/EFI/BOOT/BOOTX64.EFI" ] \
    && pass "restore point entry, another system's entry and files, EFI: untouched" || fail "touched what is not ours"
[ -f "$T/b/tok/initrd" ] && pass "a file a restore point's entry still names stays (until sg-snapshot makes it again)" \
    || fail "removed a file a remaining entry names"

# 3. three kernels: running A, B (on trial, +3), adding C -- only the running
# and the newest stay, B's counted entry and recovery twin go
fresh; debian_kernel "$B" "+3"; export SG_BS_UNAME=$A SG_BS_FREE=$((1024 * MB))
add "$C"
[ ! -e "$E/tok-$B+3.conf" ] && [ ! -e "$E/tok-$B-recovery.conf" ] && [ ! -d "$T/b/tok/$B" ] \
    && pass "a kernel neither running nor newest goes, counted entry and twin too" || fail "B kept: $(ls "$E")"
[ -f "$E/tok-tok-$A.conf" ] && pass "...and the running one stays" || fail "running A removed"

# 4. a nearly full boot partition: the running kernel alone fills it; C does
# not fit: rc 77, nothing removed that boots, its empty directory gone, notice
fresh; export SG_BS_UNAME=$A SG_BS_FREE=$((300 * MB))
before=$(ls "$E" | sort)
add "$C"; rc=$?
[ "$rc" = 77 ] && pass "no room even with the others gone: stopped cleanly (77)" || fail "rc $rc (want 77)"
[ "$(ls "$E" | sort)" = "$before" ] && [ -f "$T/b/tok/$A/vmlinuz" ] && [ -f "$T/b/tok/initrd" ] \
    && pass "every existing entry and its files intact" || fail "entries changed: $(ls "$E")"
[ ! -d "$T/b/tok/$C" ] && pass "the new kernel's empty directory removed" || fail "empty $C directory left"
grep -q "^kernel=$C\$" "$T/notice" 2>/dev/null && grep -q "^running=$A\$" "$T/notice" \
    && pass "a notice names the kernel left out and the one still started" || fail "no notice"
ls "$(dirname "$T/notice")"/notice.tmp >/dev/null 2>&1 && fail "notice.tmp left" || pass "no notice.tmp"

# 4b. running A, B there too; C would not fit even with B gone: B is not
# removed for nothing
fresh; debian_kernel "$B" ""; export SG_BS_UNAME=$A SG_BS_FREE=$((315 * MB))
add "$C"; rc=$?
[ "$rc" = 77 ] && [ -f "$E/tok-$B.conf" ] && [ -f "$T/b/tok/$B/linux" ] && [ -f "$E/tok-$B-recovery.conf" ] \
    && pass "no room even with B gone: B is not taken off for nothing (rc $rc)" || fail "rc $rc; $(ls "$E")"

# 5. nearly full, but pruning makes room: running B, A (image) and C... add D
# with room only after A goes -- and a kernel that fits takes the notice away
fresh; debian_kernel "$B" ""; export SG_BS_UNAME=$B SG_BS_FREE=$((420 * MB))
printf 'kernel=%s\nrunning=%s\n' "$C" "$B" > "$T/notice"
add "$C"; rc=$?
[ "$rc" = 0 ] && [ -f "$E/tok-$B.conf" ] && [ ! -d "$T/b/tok/$A" ] && pass "room made by taking off the old kernel (rc $rc)" || fail "rc $rc"
[ ! -f "$T/notice" ] && pass "the kernel the notice names fits: the notice goes" || fail "stale notice kept"

# 5c. another kernel fitting (an older one's initrd made again) leaves the
# notice about a newer one alone
fresh; export SG_BS_UNAME=$A SG_BS_FREE=$((1024 * MB))
printf 'kernel=%s\nrunning=%s\n' "$C" "$A" > "$T/notice"
add "$B"
grep -q "^kernel=$C\$" "$T/notice" 2>/dev/null && pass "an older kernel fitting leaves the notice about $C" || fail "the notice went for another kernel"

# 5b. a newer kernel already there (installed, not started yet) and an older
# one being added again: both kept by the rule; no room -- the oldest that
# is neither running nor this one (the newer) goes to make it
D=6.12.120+deb13-amd64
fresh; debian_kernel "$D" ""; export SG_BS_UNAME=$A SG_BS_FREE=$((370 * MB))
add "$C"; rc=$?
[ "$rc" = 0 ] && [ ! -d "$T/b/tok/$D" ] && [ -f "$E/tok-tok-$A.conf" ] \
    && pass "short of room: the kept kernel that is neither running nor added went (rc $rc)" || fail "rc $rc; $(ls "$E")"

# 6. the same version again (initramfs remade): what it overwrites counts as room
fresh; rm -rf "$E/tok-tok-$A.conf" "$E/Sg-restore-1.conf" "$T/b/tok"; debian_kernel "$B" ""
export SG_BS_UNAME=$B SG_BS_FREE=$((120 * MB))
add "$B"; rc=$?
[ "$rc" = 0 ] && [ -f "$E/tok-$B.conf" ] && pass "the running kernel's initrd made again: fits in its own place (rc $rc)" || fail "rc $rc on a same-version add"

# 7. apt removes the image's kernel A (not running): kernel-install removes
# TOKEN-A*.conf and the directory; the image-named entry and the shared
# initrds only it named go too
fresh; debian_kernel "$B" ""; export SG_BS_UNAME=$B
rm -f "$E/Sg-restore-1.conf"
"$PLUGIN" remove "$A" "$T/b/tok/$A" 2>>"$T/log"
[ ! -f "$E/tok-tok-$A.conf" ] && pass "remove: the image-named entry of the removed kernel goes" || fail "dangling image entry left"
[ ! -f "$T/b/tok/initrd" ] && [ ! -f "$T/b/tok/sg-theme.initrd" ] && pass "remove: shared initrds no entry names go" || fail "shared initrds left"
[ -f "$T/b/tok/$A/vmlinuz" ] && pass "remove: the kernel's own directory is left to kernel-install" || fail "removed kernel-install's directory itself"
[ -f "$E/tok-$B.conf" ] && [ -f "$T/b/tok/$B/linux" ] && [ -f "$E/other.conf" ] && pass "remove: the others stay" || fail "remove took more"

# 8. not a boot partition we know: nothing happens
rm -rf "$T/x"; mkdir -p "$T/x"
KERNEL_INSTALL_BOOT_ROOT="$T/x" "$PLUGIN" add "$C" "$T/x/tok/$C" "$T/src/vmlinuz-$C" 2>>"$T/log"; rc=$?
[ "$rc" = 0 ] && pass "no loader/entries: left alone (rc 0)" || fail "rc $rc without entries"
KERNEL_INSTALL_LAYOUT=other "$PLUGIN" add "$C" "$T/b/tok/$C" 2>>"$T/log"; rc=$?
[ "$rc" = 0 ] && pass "another layout: left alone" || fail "rc $rc for another layout"

# 8b. uname -r names the image's kernel, but GRUB started another entry
# (sg.entry=; the same kernel image under B's directory): B is kept too
fresh; debian_kernel "$B" ""; export SG_BS_UNAME=$A SG_BS_FREE=$((1024 * MB))
echo "root=x sg.entry=tok-$B" > "$T/cmdline"
add "$C"
[ -f "$E/tok-$B.conf" ] && [ -d "$T/b/tok/$B" ] && pass "the entry GRUB started (sg.entry=) is kept, whatever uname -r says" || fail "booted entry $B removed"
echo "root=x" > "$T/cmdline"
# ...and the one systemd-boot started (LoaderEntrySelected, UTF-16)
fresh; debian_kernel "$B" "+2"; export SG_BS_UNAME=$A
{ printf '\006\000\000\000'; printf 'tok-%s+2.conf' "$B" | iconv -f UTF-8 -t UTF-16LE; printf '\000\000'; } > "$T/efivar"
add "$C"
[ -f "$E/tok-$B+2.conf" ] && pass "the entry systemd-boot started (LoaderEntrySelected) is kept" || fail "systemd-boot's booted entry removed"
rm -f "$T/efivar"

# 9. the real kernel-install (90-loaderentry copies), on a real full
# partition (a 6 MiB tmpfs in a user namespace): a kernel that fits gets its
# entry; one that does not: kernel-install succeeds, nothing copied, the
# existing entry intact
if command -v kernel-install >/dev/null 2>&1 && [ -x /usr/lib/kernel/install.d/90-loaderentry.install ] \
    && unshare -rm true 2>/dev/null; then
    mkdir -p "$T/esp" "$T/k"
    head -c $((2 * MB)) /dev/zero > "$T/k/vmlinuz-$B"; head -c $((1 * MB)) /dev/zero > "$T/k/initrd.img-$B"
    head -c $((2 * MB)) /dev/zero > "$T/k/vmlinuz-$C"; head -c $((3 * MB)) /dev/zero > "$T/k/initrd.img-$C"
    cat > "$T/real.sh" <<EOS
set -u
mount -t tmpfs -o size=6m tmpfs "$T/esp" || exit 3
mkdir -p "$T/esp/loader/entries" "$T/esp/tok/$A" "$T/kconf"
head -c $((2 * MB)) /dev/zero > "$T/esp/tok/$A/vmlinuz"
printf 'title SG\nlinux /tok/$A/vmlinuz\noptions root=x\n' > "$T/esp/loader/entries/tok-tok-$A.conf"
echo "root=x" > "$T/kconf/cmdline"
ki() {
    SYSTEMD_RELAX_ESP_CHECKS=1 KERNEL_INSTALL_CONF_ROOT="$T/kconf" SG_BS_UNAME=$A SG_BS_REFRESH=0 \
    SG_BS_NOTICE="$T/real-notice" SG_BS_MARGIN=65536 SG_BOOT_SPACE="$SG_BOOT_SPACE" SG_BS_FREE= \
    KERNEL_INSTALL_PLUGINS="$PLUGIN /usr/lib/kernel/install.d/90-loaderentry.install" \
    KERNEL_INSTALL_MACHINE_ID=0123456789abcdef0123456789abcdef \
        kernel-install --esp-path="$T/esp" --entry-token=literal:tok "\$@"
}
ki add $B "$T/k/vmlinuz-$B" "$T/k/initrd.img-$B" 2>>"$T/log"; echo "fits rc=\$?"
ls "$T/esp/loader/entries"
ki add $C "$T/k/vmlinuz-$C" "$T/k/initrd.img-$C" 2>>"$T/log"; echo "full rc=\$?"
ls "$T/esp/loader/entries" | sed 's/^/after: /'; ls "$T/esp/tok" | sed 's/^/dir: /'
EOS
    out=$(unshare -rm sh "$T/real.sh" 2>>"$T/log")
    echo "$out" | grep -q '^fits rc=0$' && echo "$out" | grep -qx "tok-$B.conf" \
        && pass "real kernel-install: a kernel that fits is installed with its entry" || fail "real fit: $out"
    echo "$out" | grep -q '^full rc=0$' && pass "real kernel-install on a full partition: succeeds (the package's postinst would too)" \
        || fail "real full: $out"
    [ "$(echo "$out" | grep -c "^after: tok-.*$C")" = 0 ] && echo "$out" | grep -qx "after: tok-tok-$A.conf" \
        && echo "$out" | grep -qx "after: tok-$B.conf" && echo "$out" | grep -qx "dir: $B" \
        && pass "...with no entry for the kernel that did not fit, and nothing removed (B would not have made room)" || fail "real full entries: $out"
    echo "$out" | grep -qx "dir: $C" && fail "real full: an empty $C directory left" || pass "...and no directory of it left"
    grep -q "^kernel=$C\$" "$T/real-notice" 2>/dev/null && pass "...and its notice" || fail "real full: no notice"
else
    echo "SKIP  kernel-install or a user namespace missing"
fi

[ "$RC" = 0 ] && echo "RESULT: PASS" || { echo "RESULT: FAIL"; sed 's/^/  log: /' "$T/log"; }
exit "$RC"
