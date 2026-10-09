#!/bin/sh
# Gate for restore points, going back and converting the system drive, for
# real, on LOOP DEVICES ONLY: sparse files under /var/tmp attached with
# losetup. Never this machine's disks.
#
# btrfs (the layout sg-install makes, lib/sg-btrfs-layout.sh, with a small
# stand-in system in it):
#   - the APT hook takes a read-only restore point of @ (and its boot copy),
#     labelled with the update; the boot menu gets "Stained Glass OS -- before
#     the update of <date>" starting that copy (rootflags=subvol=..., the kernel
#     the restore point has);
#   - five restore points: three kept, the oldest gone; with the drive "low on
#     space" only the newest;
#   - going back: a restore point "before going back" first, the new @ is the
#     restore point's files and the default subvolume, the old one renamed
#     (deleted at the next start), homes and the Windows programs' prefix
#     untouched, the update's versions kept from apt, a kernel the restore
#     point lacks hidden from the boot menu; Settings is told a restart is
#     pending;
#   - at the next start (boot): the old @ gone, a started boot copy made again.
# ext4 -> btrfs (convert/sg-convert-root, as the initrd runs it): a stand-in
# system on ext4 converted: @ the default subvolume, the homes, logs, caches,
# temporary files and prefix in their subvolumes and gone from @, fstab naming
# them, only the subvolumes and ext2_saved left in the top level, the state
# recorded; then undone: ext4 again with the files as they were (e2fsck clean).
#
# Needs passwordless sudo, losetup, mkfs.btrfs, btrfs-convert, mkfs.ext4; skips
# (77) without them.
#
#   sh test/snapshot-test.sh [--mutant KEEP_ALL|CONVERT_NO_SAVED|CONVERT_KEEP_HOME]
# shellcheck disable=SC2015,SC2086,SC2317,SC2024,SC2013
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
MUT=""
[ "${1:-}" = --mutant ] && MUT="SG_MUTANT_SNAP_$2=1 SG_MUTANT_$2=1"
sudo -n true 2>/dev/null || { echo "SKIP: needs passwordless sudo"; exit 77; }
PATH="$PATH:/usr/sbin:/sbin"
for t in losetup mkfs.btrfs btrfs btrfs-convert mkfs.ext4 e2fsck blkid; do
    command -v "$t" >/dev/null || { echo "SKIP: $t missing"; exit 77; }
done

T=$(mktemp -d /var/tmp/sg-snapshot-test.XXXXXX); chmod 755 "$T"
LOOP="" LOOP2=""
cleanup() {
    for m in "$T/sys/var/lib/stained-glass/prefix" "$T/sys/var/tmp" "$T/sys/var/cache" "$T/sys/var/log" "$T/sys/home" "$T/sys" "$T/top" "$T/m"; do
        mountpoint -q "$m" 2>/dev/null && sudo -n umount "$m"
    done
    [ -n "$LOOP" ] && sudo -n losetup -d "$LOOP" 2>/dev/null
    [ -n "$LOOP2" ] && sudo -n losetup -d "$LOOP2" 2>/dev/null
    sudo -n rm -rf "$T"
}
trap cleanup EXIT INT TERM
attach() {   # FILE -> a loop device of exactly that file
    l=$(sudo -n losetup -f --show "$1") || { echo "FAIL: no loop device"; exit 1; }
    case "$l" in /dev/loop*) ;; *) echo "FAIL: $l is not a loop device"; exit 1 ;; esac
    [ "$(losetup -n -O BACK-FILE "$l")" = "$1" ] || { echo "FAIL: $l is not $1"; exit 1; }
    echo "$l"
}
truncate -s 6G "$T/btrfs.img"
LOOP=$(attach "$T/btrfs.img")
mkdir -p "$T/top" "$T/sys" "$T/entries" "$T/m"

# --- the layout, as sg-install makes it --------------------------------------------------
sudo -n sh -c ". '$HERE/lib/sg-btrfs-layout.sh'
    mkfs.btrfs -f -q -L StainedGlass $LOOP >/dev/null && mount $LOOP '$T/top' && sg_btrfs_create '$T/top' && umount '$T/top' \
    && sg_btrfs_mount $LOOP '$T/sys'" || { echo "FAIL: the layout could not be made"; exit 1; }
S="$T/sys"
sudo -n sh -c "mkdir -p '$S/etc/kernel' '$S/usr/lib/modules/6.12.1/kernel' '$S/home/alice' '$S/var/lib/stained-glass/prefix/drive_c/Program Files'
    echo 'root=PARTUUID=feed rootflags=subvol=@ rw quiet' > '$S/etc/kernel/cmdline'
    echo one > '$S/etc/version'; echo 'my letter' > '$S/home/alice/letter.txt'"
sudo -n mount -o subvolid=5 "$LOOP" "$T/top"
ATID=$(sudo -n btrfs inspect-internal rootid "$T/top/@")
printf 'title Stained Glass OS\nversion 6.12.1\nlinux /debian/6.12.1/linux\ninitrd /debian/6.12.1/initrd\noptions root=PARTUUID=feed rootflags=subvol=@ rw quiet\n' > "$T/entries/debian-6.12.1.conf"
echo "root=PARTUUID=feed rootflags=subvol=@ rw quiet" > "$T/cmdline"
NOW=1791500000
snap() {   # [VAR=VALUE...] -- sg-snapshot ARGS, as root, against the loop device
    sudo -n env $MUT SG_SNAP_FSTYPE=btrfs SG_SNAP_DEV="$LOOP" SG_SNAP_FSROOT=/@ SG_SNAP_TOP="$T/top" \
        SG_SNAP_ETC="$S/etc" SG_SNAP_ENTRIES="$T/entries" SG_SNAP_STATUS="$T/status" SG_SNAP_CMDLINE="$T/cmdline" \
        SG_SNAP_ROLLBACK="$S/var/lib/stained-glass-rollback" SG_SNAP_LOCK="$T/lock" SG_SNAP_ROOTID="$ATID" \
        SG_SNAP_CONVERT_STATE="$T/convert-state" SG_SNAP_NOW="$NOW" "$@"
}
hook() {
    printf 'VERSION 3\nAPT::Architecture=amd64\n\nsg-shell 0.1.0-%s amd64 same < 0.1.0-%s amd64 same /x/sg-shell.deb\n' "$1" "$2" \
        | snap python3 "$HERE/bin/sg-snapshot" apt-hook
}
id_at() { python3 -c "import time; print(time.strftime('%Y%m%d-%H%M%S', time.localtime($1)))"; }

hook 169 170 > "$T/hook1.out" 2>&1
ID1=$(id_at $NOW)
D1="$T/top/@snapshots/$ID1"
if [ "$(sudo -n btrfs property get -ts "$D1/snapshot" ro)" = "ro=true" ] && sudo -n test -f "$D1/boot/etc/version" \
        && sudo -n grep -q 'sg-shell 0.1.0-169 to 0.1.0-170' "$D1/info" && ! sudo -n test -e "$D1/snapshot/home/alice/letter.txt"; then
    pass "the APT hook took a read-only restore point of @ (no homes in it), labelled with the update, and its boot copy"
else fail "restore point: $(cat "$T/hook1.out"; sudo -n ls -la "$D1" 2>&1)"; fi
e="$T/entries/Sg-restore-$ID1.conf"
if grep -q "^title Stained Glass OS -- before the update of " "$e" && grep -q "^options root=PARTUUID=feed rootflags=subvol=@snapshots/$ID1/boot rw quiet sg.snapshot=$ID1\$" "$e" \
        && grep -q '^linux /debian/6.12.1/linux$' "$e"; then
    pass "the boot menu: 'Stained Glass OS -- before the update of <date>', starting the restore point's copy"
else fail "boot entry: $(cat "$e" 2>&1)"; fi
grep -q "^SNAPSHOT $ID1	.*	auto	yes	Updates: sg-shell" "$T/status" && pass "Settings is told of it (bootable)" || fail "status: $(cat "$T/status")"

# the system changes; four more updates
sudo -n sh -c "echo two > '$S/etc/version'; echo 'my letter, edited' > '$S/home/alice/letter.txt'; echo app > '$S/var/lib/stained-glass/prefix/drive_c/Program Files/app.exe'"
for n in 1 2 3 4; do
    NOW=$((1791500000 + n * 3600)); hook $((169 + n)) $((170 + n)) >/dev/null 2>&1
    if [ $n = 2 ]; then     # a new kernel after the second
        sudo -n mkdir -p "$S/usr/lib/modules/6.12.2/kernel"
        printf 'title Stained Glass OS\nversion 6.12.2\nlinux /debian/6.12.2/linux\noptions root=PARTUUID=feed rootflags=subvol=@ rw quiet\n' > "$T/entries/debian-6.12.2.conf"
    fi
done
NOW=1791500000
ids=$(sudo -n ls "$T/top/@snapshots")
if [ "$(echo "$ids" | wc -w)" = 3 ] && ! echo "$ids" | grep -q "$ID1" && [ ! -e "$e" ]; then
    pass "five restore points: the last three kept, the oldest gone (and its boot entry)"
else fail "kept: $ids"; fi
ID2=$(id_at $((1791500000 + 2 * 3600)))
# going back to the oldest kept one (taken with version two)
NOW=$((1791500000 + 5 * 3600))
out=$(snap python3 "$HERE/bin/sg-snapshot" rollback "$ID2" 2>&1)
NEWID=$(sudo -n btrfs inspect-internal rootid "$T/top/@")
DEF=$(sudo -n btrfs subvolume get-default "$T/top" | awk '{print $2}')
if [ "$DEF" = "$NEWID" ] && [ "$NEWID" != "$ATID" ] && sudo -n ls "$T/top" | grep -q '^@old-' \
        && [ "$(sudo -n cat "$T/top/@/etc/version")" = two ]; then
    pass "going back: the restore point is the new @ and the default subvolume, the old @ kept aside until the next start"
else fail "rollback: $out; default $DEF new $NEWID"; fi
[ "$(sudo -n cat "$S/home/alice/letter.txt")" = "my letter, edited" ] && sudo -n test -f "$S/var/lib/stained-glass/prefix/drive_c/Program Files/app.exe" \
    && pass "homes and the Windows programs' prefix are not taken back" || fail "home or prefix changed"
sudo -n grep -q "Before going back" "$T/top/@snapshots/$(id_at $NOW)/info" 2>/dev/null \
    && pass "a restore point of the system as it was is taken first" || fail "no 'before going back' restore point: $(sudo -n ls "$T/top/@snapshots")"
n=$(sudo -n ls "$T/top/@snapshots" | wc -l)
[ "$n" = 3 ] && sudo -n test -d "$T/top/@snapshots/$ID2" && pass "...and still three kept, the one gone back to among them" || fail "after going back: $n kept"
grep -q '^title Stained Glass OS -- restore point of ' "$T/entries/Sg-restore-$(id_at $NOW).conf" \
    && pass "the restore point taken before going back is in the boot menu as a restore point (not an update)" || fail "its entry: $(cat "$T/entries/Sg-restore-$(id_at $NOW).conf" 2>&1)"
sudo -n grep -q '^Pin: version 0.1.0-172$' "$T/top/@/etc/apt/preferences.d/sg-went-back" \
    && pass "the update the restore point was taken before is kept from apt" || fail "pin: $(sudo -n cat "$T/top/@/etc/apt/preferences.d/sg-went-back" 2>&1)"
grep -q '^PENDING rollback' "$T/status" && pass "Settings is told: going back at the next restart" || fail "status: $(cat "$T/status")"
# a kernel installed after that restore point was taken: hidden
[ -f "$T/entries/debian-6.12.2.conf.sg-hidden" ] && [ -f "$T/entries/debian-6.12.1.conf" ] \
    && pass "a kernel installed after the restore point was taken is hidden from the boot menu" || fail "entries: $(ls "$T/entries")"

# the next start (the system now the new @): the old @ goes; a started boot copy is made again
for m in "$S/var/lib/stained-glass/prefix" "$S/var/tmp" "$S/var/cache" "$S/var/log" "$S/home" "$S"; do sudo -n umount "$m"; done
sudo -n sh -c ". '$HERE/lib/sg-btrfs-layout.sh'; sg_btrfs_mount $LOOP '$S'" || fail "the new @ does not mount"
ATID=$NEWID
D2="$T/top/@snapshots/$ID2"
sudo -n sh -c "mkdir -p '$D2/boot/var/lib/stained-glass-rollback'; echo $ID2 > '$D2/boot/var/lib/stained-glass-rollback/booted-snapshot'; echo dirty > '$D2/boot/etc/version'"
snap python3 "$HERE/bin/sg-snapshot" boot > "$T/boot.out" 2>&1
if ! sudo -n ls "$T/top" | grep -q '^@old-' && [ "$(sudo -n cat "$D2/boot/etc/version")" = two ] \
        && ! sudo -n test -e "$D2/boot/var/lib/stained-glass-rollback/booted-snapshot"; then
    pass "at the next start: the old system deleted, a restore point's started copy made again from its snapshot"
else fail "boot: $(cat "$T/boot.out"; sudo -n ls "$T/top")"; fi

# a drive low on space: only the newest
NOW=$((1791500000 + 9 * 3600))
snap env SG_SNAP_LOW=$((1 << 50)) python3 "$HERE/bin/sg-snapshot" create --label test >/dev/null 2>&1
[ "$(sudo -n ls "$T/top/@snapshots" | wc -l)" = 1 ] && pass "low on space: the oldest go first, the newest stays" \
    || fail "low space kept: $(sudo -n ls "$T/top/@snapshots")"

# --- the conversion's initrd, as convert-schedule makes it (mkinitramfs -d) -------------------
K=$(uname -r)
if command -v mkinitramfs >/dev/null && [ -d "/lib/modules/$K" ]; then
    C="$T/convconf"; mkdir -p "$C" "$T/csrc"
    cp -r "$HERE/convert/hooks" "$HERE/convert/scripts" "$HERE/convert/initramfs.conf" "$HERE/convert/modules" "$C/"
    echo MODULES=dep >> "$C/initramfs.conf"
    cp "$HERE/convert/sg-convert-root" "$HERE/lib/sg-btrfs-layout.sh" "$T/csrc/"
    sudo -n env $MUT SG_CONVERT_SRC="$T/csrc" mkinitramfs -d "$C" -o "$T/conv.img" "$K" > "$T/mkinitramfs.log" 2>&1
    l=$(lsinitramfs "$T/conv.img" 2>/dev/null)
    miss=""
    for f in usr/lib/sg-convert/sg-convert-root usr/lib/sg-convert/sg-btrfs-layout.sh scripts/local-premount/sg-convert; do
        printf '%s\n' "$l" | grep -qx "$f" || miss="$miss $f"
    done
    # every command sg-convert-root (and the sg-btrfs-layout.sh functions it
    # calls) runs: the initrd's own klibc has no mv or touch
    for c in btrfs btrfs-convert e2fsck dumpe2fs blkid mount umount cp mv rm mkdir chmod touch sed awk grep cat sync date find sleep; do
        printf '%s\n' "$l" | grep -qx "usr/lib/sg-convert/bin/$c" || miss="$miss $c"
    done
    printf '%s\n' "$l" | grep -q '/libgcc_s\.so\.1$' || miss="$miss libgcc_s.so.1"
    printf '%s\n' "$l" | grep -q '/btrfs\.ko' || miss="$miss btrfs.ko"
    [ -z "$miss" ] && pass "the conversion's initrd carries sg-convert-root, btrfs-convert and its tools, libgcc_s (pthread_cancel) and btrfs.ko" \
        || fail "the conversion's initrd lacks:$miss ($(tail -3 "$T/mkinitramfs.log"))"
else echo "SKIP  mkinitramfs or this kernel's modules missing: the conversion's initrd not built"; fi

# --- converting an ext4 system drive ------------------------------------------------------
for m in "$S/var/lib/stained-glass/prefix" "$S/var/tmp" "$S/var/cache" "$S/var/log" "$S/home" "$S" "$T/top"; do sudo -n umount "$m"; done
truncate -s 8G "$T/ext4.img"
LOOP2=$(attach "$T/ext4.img")
sudo -n mkfs.ext4 -q -F -L StainedGlass "$LOOP2" >/dev/null
UUID4=$(sudo -n blkid -p -o value -s UUID "$LOOP2")
sudo -n mount "$LOOP2" "$T/m"
sudo -n sh -c "mkdir -p '$T/m/etc' '$T/m/home/bob/.config' '$T/m/var/log/x' '$T/m/var/cache/apt' '$T/m/var/tmp' '$T/m/usr/bin' \
        '$T/m/var/lib/stained-glass/prefix/drive_c/users/bob' '$T/m/var/lib/stained-glass/state'
    echo 'PARTUUID=1 /efi vfat umask=0077 0 2' > '$T/m/etc/fstab'
    echo 'photo' > '$T/m/home/bob/photo.jpg'; echo dot > '$T/m/home/bob/.config/x'; echo log > '$T/m/var/log/x/l'
    echo win > '$T/m/var/lib/stained-glass/prefix/drive_c/users/bob/doc.txt'; echo sys > '$T/m/usr/bin/tool'
    chmod 1777 '$T/m/var/tmp'"
sudo -n umount "$T/m"
SUM_BEFORE=$(sudo -n sh -c "mount -o ro $LOOP2 '$T/m' && cd '$T/m' && find . -path ./lost+found -prune -o -type f -print | sort | xargs sha256sum; cd /; umount '$T/m'")
mkdir -p "$T/power/AC"; echo Mains > "$T/power/AC/type"; echo 1 > "$T/power/AC/online"
# only the commands the initramfs hook copies (its list), nothing else on PATH:
# a command the conversion needs and the initrd lacks fails here as there
mkdir -p "$T/clib/bin" "$T/empty"; cp "$HERE/lib/sg-btrfs-layout.sh" "$T/clib/"
for t in $(sed -n 's/^for t in \(.*\); do$/\1/p' "$HERE/convert/hooks/sg-convert"); do
    p=$(PATH=/usr/sbin:/usr/bin:/sbin:/bin command -v "$t") && ln -s "$p" "$T/clib/bin/$t"
done
conv() {
    sudo -n env $MUT SG_CONVERT_LIB="$T/clib" SG_CONVERT_PATH_TAIL="$T/empty" SG_CONVERT_NOREBOOT=1 SG_CONVERT_POWER="$T/power" SG_CONVERT_MNT="$T/m" \
        SG_CONVERT_LOG="$T/convert.log" SG_CONVERT_NOW=20261008-120000 sh "$HERE/convert/sg-convert-root" "$1" "$LOOP2"
}
conv btrfs > "$T/conv.out" 2>&1
if [ "$(sudo -n blkid -p -o value -s TYPE "$LOOP2")" = btrfs ] && [ "$(sudo -n blkid -p -o value -s UUID "$LOOP2")" = "$UUID4" ]; then
    pass "converted to btrfs, keeping the file system's UUID"
else fail "conversion: $(cat "$T/conv.out" "$T/convert.log" 2>&1 | tail -20)"; fi
sudo -n mount -o subvolid=5 "$LOOP2" "$T/top"
top=$(sudo -n ls -A "$T/top" | LC_ALL=C sort | tr '\n' ' ')
[ "$top" = "@ @home @prefix @snapshots @var-cache @var-log @var-tmp ext2_saved " ] \
    && pass "the top level: the subvolumes and ext2_saved only (the old copy removed)" || fail "top level: $top"
DEF=$(sudo -n btrfs subvolume get-default "$T/top" | awk '{print $NF}')
[ "$DEF" = "@" ] && pass "@ is the default subvolume (the boot entries need no rootflags)" || fail "default: $DEF"
if sudo -n test -f "$T/top/@home/bob/photo.jpg" && sudo -n test -f "$T/top/@home/bob/.config/x" && [ -z "$(sudo -n ls -A "$T/top/@/home")" ] \
        && sudo -n test -f "$T/top/@prefix/drive_c/users/bob/doc.txt" && [ -z "$(sudo -n ls -A "$T/top/@/var/lib/stained-glass/prefix")" ] \
        && sudo -n test -f "$T/top/@var-log/x/l" && sudo -n test -f "$T/top/@/usr/bin/tool" \
        && [ "$(sudo -n stat -c %a "$T/top/@var-tmp")" = 1777 ]; then
    pass "homes, logs and the prefix moved into their subvolumes and gone from @; the system in @"
else fail "subvolume contents"; fi
f="$T/top/@/etc/fstab"
sudo -n grep -q "^UUID=$UUID4 /home btrfs subvol=@home 0 0" "$f" && sudo -n grep -q '^PARTUUID=1 /efi' "$f" \
    && pass "@'s fstab names the subvolumes and keeps its other lines" || fail "fstab: $(sudo -n cat "$f")"
[ "$(sudo -n cat "$T/top/@/var/lib/stained-glass-convert/state")" = "converted 20261008-120000" ] \
    && pass "the conversion is recorded for the Control Panel" || fail "state: $(sudo -n cat "$T/top/@/var/lib/stained-glass-convert/state" 2>&1)"
sudo -n umount "$T/top"
conv undo > "$T/undo.out" 2>&1
SUM_AFTER=$(sudo -n sh -c "mount -o ro $LOOP2 '$T/m' && cd '$T/m' && find . -path ./lost+found -prune -o -type f -print | sort | xargs sha256sum; cd /; umount '$T/m'")
if [ "$(sudo -n blkid -p -o value -s TYPE "$LOOP2")" = ext4 ] && sudo -n e2fsck -fn "$LOOP2" >/dev/null 2>&1 \
        && [ "$(printf '%s\n' "$SUM_AFTER" | grep -v stained-glass-convert)" = "$SUM_BEFORE" ]; then
    pass "undone: ext4 again, clean, every file as it was"
else fail "undo: $(tail -5 "$T/undo.out" "$T/convert.log"; echo "$SUM_AFTER" | head -5)"; fi
sudo -n mount -o ro "$LOOP2" "$T/m" && st=$(sudo -n cat "$T/m/var/lib/stained-glass-convert/state" 2>&1); sudo -n umount "$T/m"
[ "$st" = "undone 20261008-120000" ] && pass "the undo is recorded" || fail "undo state: $st"

[ $RC = 0 ] && echo "snapshot-test: PASS" || echo "snapshot-test: FAIL"
exit $RC
