#!/bin/sh
# /boot on the root file system, the boot partitions at /efi and /xbootldr
# (sg-boot-layout). dpkg could not upgrade a kernel package on the FAT boot
# partition that was mounted at /boot.
#
#   1. --configure (sg-install): a disk of its own -- the ESP at /efi,
#      BOOT_ROOT=/efi; beside Windows -- /efi and /xbootldr,
#      BOOT_ROOT=/xbootldr and SYSTEMD_XBOOTLDR_PATH for services; fstab's
#      other lines kept, a second run adds nothing twice.
#   2. --migrate (an installed machine, in a user namespace: a tmpfs over the
#      root file system's /boot plays the FAT partition): Debian's files are
#      copied to the root file system's own /boot, byte for byte; fstab,
#      install.conf, the environment written, the old ones kept (.bak);
#      nothing on the partition changed; done once.
#   3. a copy that fails changes nothing; a live boot and a machine Setup did
#      not install are left alone; sg-install runs --configure.
#
# --mutant verify|live|bootroot|marker: must fail.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
BL="$HERE/bin/sg-boot-layout"
MUTANT=""; [ "${1:-}" = --mutant ] && MUTANT=${2:?}
T=$(mktemp -d /var/tmp/sg-bl-test.XXXXXX); trap 'rm -rf "$T"' EXIT INT TERM
RC=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; RC=1; }
case "$MUTANT" in
    verify) sed 's/rm -f "\$RV"\/boot\/\*.sg-new; cleanup$/:/; /die "copying \$n to the root file system failed/d' "$BL" > "$T/bl" ;;
    live) sed 's/\*" systemd.volatile="\*|\*" sg.live="\*) return 0 ;; esac/*" no-such-word "*) return 0 ;; esac/' "$BL" > "$T/bl" ;;
    bootroot) sed "/printf 'BOOT_ROOT=%s\\\\n' \"\$broot\" >> \"\$c.tmp\"/d" "$BL" > "$T/bl" ;;
    marker) sed '/# done$/d' "$BL" > "$T/bl" ;;
esac
if [ -n "$MUTANT" ]; then cmp -s "$T/bl" "$BL" && { echo "mutant $MUTANT changed nothing"; exit 2; }; BL="$T/bl"; fi

# --- 1. a new system -----------------------------------------------------------------
for k in own beside; do
    r="$T/new-$k"; mkdir -p "$r/etc/kernel"
    printf 'UUID=1234 / ext4 errors=remount-ro 0 1\n' > "$r/etc/fstab"; printf 'layout=bls\n' > "$r/etc/kernel/install.conf"
    if [ $k = own ]; then set -- --esp 11111111-aaaa; else set -- --esp 11111111-aaaa --xbootldr 22222222-bbbb; fi
    sh "$BL" --configure --root "$r" "$@"; sh "$BL" --configure --root "$r" "$@"
done
r="$T/new-own"
if grep -q '^PARTUUID=11111111-aaaa /efi vfat umask=0077,' "$r/etc/fstab" && ! grep -q xbootldr "$r/etc/fstab" \
    && grep -qx 'UUID=1234 / ext4 errors=remount-ro 0 1' "$r/etc/fstab" && [ "$(grep -c ' /efi ' "$r/etc/fstab")" = 1 ] \
    && grep -qx BOOT_ROOT=/efi "$r/etc/kernel/install.conf" && grep -qx layout=bls "$r/etc/kernel/install.conf" \
    && [ -d "$r/efi" ] && [ -s "$r/boot/README.stained-glass" ] && [ ! -e "$r/etc/systemd/system.conf.d/50-sg-xbootldr.conf" ]; then
    pass "a disk of its own: the ESP at /efi, kernels into it, /boot a directory (not empty); twice is once"
else fail "own disk: $(cat "$r/etc/fstab" "$r/etc/kernel/install.conf")"; fi
r="$T/new-beside"
if grep -q '^PARTUUID=11111111-aaaa /efi vfat' "$r/etc/fstab" && grep -q '^PARTUUID=22222222-bbbb /xbootldr vfat' "$r/etc/fstab" \
    && grep -qx BOOT_ROOT=/xbootldr "$r/etc/kernel/install.conf" && [ "$(grep -c '^BOOT_ROOT=' "$r/etc/kernel/install.conf")" = 1 ] \
    && grep -q 'SYSTEMD_XBOOTLDR_PATH=/xbootldr' "$r/etc/systemd/system.conf.d/50-sg-xbootldr.conf" 2>/dev/null; then
    pass "beside Windows: /efi and /xbootldr, kernels into /xbootldr, services told where it is"
else fail "beside Windows: $(cat "$r/etc/fstab" "$r/etc/kernel/install.conf")"; fi
grep -q '^    sg-boot-layout --configure --root "\$R" --esp "\$ESP_PARTUUID" --xbootldr' "$HERE/bin/sg-install" \
    && grep -q '^    sg-boot-layout --configure --root "\$R" --esp "\$ESP_PARTUUID" ||' "$HERE/bin/sg-install" \
    && pass "sg-install configures every new system" || fail "sg-install does not run sg-boot-layout --configure"

# --- 2./3. an installed machine ----------------------------------------------------------
if unshare -rm true 2>/dev/null; then
    cat > "$T/run.sh" <<EOS
set -u
R="$T/root"; RV="$T/rv"
machine() {   # \$1: what to break
    umount "\$R/boot" 2>/dev/null; umount "\$RV" 2>/dev/null; rm -rf "\$R" "\$RV"
    mkdir -p "\$R/boot" "\$R/etc/kernel" "\$R/var/lib/stained-glass" "\$RV"
    printf 'UUID=1234 / ext4 errors=remount-ro 0 1\n' > "\$R/etc/fstab"
    printf 'layout=bls\n' > "\$R/etc/kernel/install.conf"
    echo "root=PARTUUID=33333333-cccc rw quiet" > "\$R/etc/kernel/cmdline"
    mount -t tmpfs fat "\$R/boot"                  # the boot partition, at /boot
    mkdir -p "\$R/boot/loader/entries" "\$R/boot/stained-glass/6.12.111+deb13-amd64"
    echo entry > "\$R/boot/loader/entries/debian-stained-glass-6.12.111+deb13-amd64.conf"
    for f in vmlinuz initrd.img config System.map; do head -c 3000 /dev/urandom > "\$R/boot/\$f-6.12.111+deb13-amd64"; done
    mount --bind "\$R" "\$RV"; mount --make-private "\$RV"   # the root file system's own /boot under it
    [ "\${1:-}" = copyfails ] && mkdir -p "\$RV/boot/vmlinuz-6.12.111+deb13-amd64.sg-new/x"
    (cd "\$R/boot" && find . -type f -exec md5sum {} + | sort) > "$T/part.before"
}
migrate() {
    SG_BL_ETC="\$R/etc" SG_BL_STATE="\$R/var/lib/stained-glass" SG_BL_CMDLINE="$T/cmdline" SG_BL_ROOTVIEW="\$RV" \\
    SG_BL_BOOT="\$R/boot" SG_BL_SOURCE=/dev/fake3 SG_BL_PARTINFO="$T/partinfo" SG_BL_ESP_UUID=11111111-aaaa SG_BL_SWITCH=0 \\
        sh "$BL" --migrate 2>>"$T/migrate.err"
}
printf '#!/bin/sh\necho "bc13c2ff-59e6-4262-a352-b275fd6f7172 22222222-bbbb"\n' > "$T/partinfo"; chmod +x "$T/partinfo"
echo "root=PARTUUID=33333333-cccc rw quiet" > "$T/cmdline"

machine; migrate
(cd "\$RV/boot" && ls) > "$T/rootboot.2"
ok=1; for f in vmlinuz initrd.img config System.map; do cmp -s "\$R/boot/\$f-6.12.111+deb13-amd64" "\$RV/boot/\$f-6.12.111+deb13-amd64" || ok=0; done
echo \$ok > "$T/same.2"
(cd "\$R/boot" && find . -type f -exec md5sum {} + | sort) > "$T/part.after"; cp "$T/part.before" "$T/part.before.2"
cp "\$R/etc/fstab" "$T/fstab.2"; cp "\$R/etc/kernel/install.conf" "$T/conf.2"
ls "\$R/etc" "\$R/etc/kernel" "\$R/var/lib/stained-glass" > "$T/etc.2"; cat "\$R/etc/systemd/system.conf.d/50-sg-xbootldr.conf" > "$T/env.2" 2>/dev/null
# once: a second run changes nothing (the root's /boot emptied: not filled again)
rm -f "\$RV"/boot/vmlinuz-*; migrate; ls "\$RV/boot" > "$T/rootboot.2b"

machine copyfails; migrate
cp "\$R/etc/fstab" "$T/fstab.3"; ls "\$R/var/lib/stained-glass" > "$T/state.3"; ls "\$RV/boot" > "$T/rootboot.3"

machine; echo "root=LABEL=SGLIVEROOT systemd.volatile=overlay" > "$T/cmdline"; migrate
cp "\$R/etc/fstab" "$T/fstab.4"; ls "\$RV/boot" > "$T/rootboot.4"
echo "root=PARTUUID=33333333-cccc rw quiet" > "$T/cmdline"
machine; rm "\$R/etc/kernel/cmdline"; migrate
cp "\$R/etc/fstab" "$T/fstab.5"
umount "\$R/boot"; umount "\$RV"
exit 0
EOS
    if unshare -rm sh "$T/run.sh"; then
        orig='UUID=1234 / ext4 errors=remount-ro 0 1'
        [ "$(cat "$T/same.2")" = 1 ] && grep -qx README.stained-glass "$T/rootboot.2" \
            && pass "Debian's files copied to the root file system's /boot, byte for byte" || fail "the root's /boot: $(tr '\n' ' ' < "$T/rootboot.2") $(cat "$T/migrate.err")"
        cmp -s "$T/part.before.2" "$T/part.after" && pass "nothing on the boot partition changed (every entry as it was)" || fail "the partition changed"
        grep -q '^PARTUUID=22222222-bbbb /xbootldr' "$T/fstab.2" && grep -q '^PARTUUID=11111111-aaaa /efi' "$T/fstab.2" && grep -qx "$orig" "$T/fstab.2" \
            && grep -qx BOOT_ROOT=/xbootldr "$T/conf.2" && grep -q SYSTEMD_XBOOTLDR_PATH=/xbootldr "$T/env.2" \
            && pass "fstab, install.conf and the environment name the new places" || fail "the new layout: $(cat "$T/fstab.2" "$T/conf.2")"
        grep -qx fstab.sg-boot-layout.bak "$T/etc.2" && grep -qx install.conf.sg-boot-layout.bak "$T/etc.2" && grep -qx boot-layout "$T/etc.2" \
            && pass "the old fstab and install.conf kept (.bak); done once (boot-layout)" || fail "no backups or marker: $(tr '\n' ' ' < "$T/etc.2")"
        grep -q vmlinuz "$T/rootboot.2b" && fail "a second run did it again" || pass "a second run does nothing"
        [ "$(cat "$T/fstab.3")" = "$orig" ] && [ ! -s "$T/state.3" ] && ! grep -q 'vmlinuz-6.12.111+deb13-amd64$' "$T/rootboot.3" \
            && pass "a copy that fails: nothing switched, nothing left half-done" || fail "after a failed copy: $(cat "$T/fstab.3") / $(cat "$T/state.3")"
        [ "$(cat "$T/fstab.4")" = "$orig" ] && [ ! -s "$T/rootboot.4" ] && pass "a live boot is left alone" || fail "the live boot was changed"
        [ "$(cat "$T/fstab.5")" = "$orig" ] && pass "a machine Setup did not install is left alone" || fail "a machine without Setup's cmdline was changed"
    else fail "the user namespace could not be used"; fi
else
    echo "SKIP  no user namespace: the migration not tried"; [ -z "$MUTANT" ] || exit 77
fi
exit "$RC"
