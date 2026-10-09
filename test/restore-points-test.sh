#!/bin/sh
# Gate for restore points' unprivileged parts (in make lint; no root, no disks):
#
#   - sg-snapshot keeps the same subvolumes as lib/sg-btrfs-layout.sh, and
#     sg-install makes the btrfs layout (mkfs.btrfs, rootflags=subvol=@);
#   - sg_btrfs_fstab writes our lines once and keeps the others;
#     sg_btrfs_cmdline puts rootflags=subvol=@ after root=;
#   - ext4: the APT hook (DPkg::Pre-Install-Pkgs, version 3) keeps the replaced
#     versions of OUR packages only (Maintainer "Stained Glass OS"), repacked;
#     the boot menu gets "undo the last update"; undo-update schedules it;
#     undo-apply reinstalls exactly that set with downgrades allowed and keeps
#     the undone versions from apt; the offline update's prepared list labels
#     the same way;
#   - converting: on a battery, not on mains, it is refused.
#
# Stand-ins: dpkg-query, dpkg-repack, apt-get (they record what they are asked).
#
#   sh test/restore-points-test.sh [--mutant NO_PIN|ANY_PACKAGE|UNDO_LOCKS|UNDO_ONLINE]   (a mutant must fail it)
# shellcheck disable=SC2015,SC2016
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
case "${1:-}" in
    --mutant) export "SG_MUTANT_SNAP_$2=1" ;;
esac
T=$(mktemp -d /var/tmp/sg-restore-points.XXXXXX)
trap 'rm -rf "$T"' EXIT INT TERM

# --- the layout, in both places ---------------------------------------------------
lib=$(sh -c ". '$HERE/lib/sg-btrfs-layout.sh'; echo \$SG_SUBVOLS")
py=$(python3 -c "
import importlib.machinery, importlib.util, sys
l = importlib.machinery.SourceFileLoader('s', '$HERE/bin/sg-snapshot')
s = importlib.util.module_from_spec(importlib.util.spec_from_loader('s', l)); l.exec_module(s)
print(' '.join('%s:%s' % x for x in s.SUBVOLS))")
[ "$lib" = "$py" ] && pass "sg-snapshot and sg-btrfs-layout.sh keep the same subvolumes ($lib)" \
    || fail "the subvolume lists differ: '$lib' / '$py'"
grep -q 'mkfs.btrfs -f -q -L StainedGlass "$ROOT_PART"' "$HERE/bin/sg-install" && grep -q '^sg_btrfs_create "$WORK/top"' "$HERE/bin/sg-install" \
    && grep -q 'rootflags=subvol=@ rw' "$HERE/bin/sg-install" && ! grep -q 'mkfs.ext4 -F -q -L StainedGlass' "$HERE/bin/sg-install" \
    && pass "sg-install makes btrfs with the subvolumes, the root by rootflags=subvol=@" || fail "sg-install's file system"

printf '# kept\nPARTUUID=1 /efi vfat umask=0077 0 2\nUUID=old /home btrfs subvol=@home 0 0\n' > "$T/fstab"
sh -c ". '$HERE/lib/sg-btrfs-layout.sh'; sg_btrfs_fstab '$T/fstab' abcd; sg_btrfs_fstab '$T/fstab' abcd"
if grep -q '^PARTUUID=1 /efi' "$T/fstab" && [ "$(grep -c ' /home btrfs' "$T/fstab")" = 1 ] \
        && grep -qx 'UUID=abcd /var/lib/stained-glass/prefix btrfs subvol=@prefix 0 0' "$T/fstab" \
        && [ "$(grep -c "^# Stained Glass OS: the system drive" "$T/fstab")" = 1 ]; then
    pass "fstab: the subvolumes once (written twice), other lines kept"
else fail "fstab: $(cat "$T/fstab")"; fi
c=$(sh -c ". '$HERE/lib/sg-btrfs-layout.sh'; sg_btrfs_cmdline 'root=PARTUUID=ab rootflags=x rw quiet'")
[ "$c" = "root=PARTUUID=ab rootflags=subvol=@ rw quiet" ] && pass "the command line: rootflags=subvol=@ after root=" || fail "cmdline: '$c'"

# --- ext4: the previous versions of our packages ----------------------------------
mkdir -p "$T/bin" "$T/etc/kernel" "$T/entries" "$T/rollback" "$T/power/BAT0" "$T/power/AC"
cat > "$T/bin/dpkg-query" <<'EOF'
#!/bin/sh
printf 'sg-shell\t0.1.0-169\tStained Glass OS <x@y>\tii \n'
printf 'wine-sg\t10.0-206\tStained Glass OS <x@y>\tii \n'
printf 'libfoo1\t1.0-1\tDebian Foo <foo@debian.org>\tii \n'
EOF
cat > "$T/bin/dpkg-repack" <<'EOF'
#!/bin/sh
for a; do case "$a" in -*) ;; *) p=$a ;; esac; done
echo "$p" >> "$SG_T/repacked"
v=$(printf 'sg-shell 0.1.0-169\nwine-sg 10.0-206\nlibfoo1 1.0-1\n' | awk -v p="$p" '$1 == p {print $2}')
echo "deb of $p" > "${p}_${v}_amd64.deb"
EOF
cat > "$T/bin/apt-get" <<'EOF'
#!/bin/sh
echo "SG_SNAP_UNDOING=$SG_SNAP_UNDOING $*" >> "$SG_T/apt"
# a maintainer script's systemctl must not reach PID 1 (it would wait for this start)
echo "offline ${SYSTEMD_OFFLINE:-0}" >> "$SG_T/apt"
# as apt does: its DPkg::Pre-Install-Pkgs hook, while undo-apply waits
printf 'VERSION 3\n\nsg-shell 0.1.0-170 amd64 same > 0.1.0-169 amd64 same /x.deb\n' \
    | timeout 20 python3 "$SG_SNAP_BIN" apt-hook >/dev/null 2>&1
echo "hook $?" >> "$SG_T/apt"
# and, as sg-session's postinst does, sg-snapshot status
timeout 20 python3 "$SG_SNAP_BIN" status >/dev/null 2>&1
echo "postinst $?" >> "$SG_T/apt"
EOF
chmod 755 "$T/bin/"*
echo "root=PARTUUID=feed rw quiet" > "$T/etc/kernel/cmdline"
printf 'title Stained Glass OS\nversion 6.12.1\nlinux /debian/6.12.1/linux\ninitrd /debian/6.12.1/initrd\noptions root=PARTUUID=feed rw quiet\n' > "$T/entries/debian-6.12.1+3.conf"
printf 'title Other\nversion 6.1\nlinux /other\noptions root=PARTUUID=0ther rw\n' > "$T/entries/other-6.1.conf"
echo Battery > "$T/power/BAT0/type"; echo 1 > "$T/power/BAT0/present"; echo Mains > "$T/power/AC/type"; echo 0 > "$T/power/AC/online"
echo "BOOT_IMAGE=x root=PARTUUID=feed rw" > "$T/cmdline"
export SG_T="$T" SG_SNAP_FSTYPE=ext4 SG_SNAP_ETC="$T/etc" SG_SNAP_ENTRIES="$T/entries" SG_SNAP_STATUS="$T/status" \
    SG_SNAP_ROLLBACK="$T/rollback" SG_SNAP_DPKGQ="$T/bin/dpkg-query" SG_SNAP_REPACK="$T/bin/dpkg-repack" \
    SG_SNAP_APT="$T/bin/apt-get" SG_SNAP_DPKG=true SG_SNAP_SYSTEMCTL=true SG_SNAP_CMDLINE="$T/cmdline" SG_SNAP_LOCK="$T/lock" SG_SNAP_POWER="$T/power" \
    SG_SNAP_CONVERT_STATE="$T/convert-state" SG_SNAP_NOW=1791500000
SNAP="$HERE/bin/sg-snapshot"
export SG_SNAP_BIN="$SNAP"
hook() {
    printf 'VERSION 3\nAPT::Architecture=amd64\n\n'
    printf 'sg-shell 0.1.0-169 amd64 same < 0.1.0-170 amd64 same /var/cache/apt/archives/sg-shell.deb\n'
    printf 'wine-sg 10.0-206 amd64 same < 10.0-207 amd64 same /var/cache/apt/archives/wine-sg.deb\n'
    printf 'libfoo1 1.0-1 amd64 same < 1.0-2 amd64 same /var/cache/apt/archives/libfoo1.deb\n'
    printf 'newpkg - - none < 2.0 amd64 none /var/cache/apt/archives/newpkg.deb\n'
    printf 'sg-shell 0.1.0-169 amd64 same < 0.1.0-170 amd64 same **CONFIGURE**\n'
}
hook | python3 "$SNAP" apt-hook > "$T/hook.out" 2>&1
m="$T/rollback/set/manifest.json"
if [ -f "$m" ] && python3 -c "
import json, sys; s = json.load(open('$m'))
p = sorted((x['name'], x['version'], x['new']) for x in s['packages'])
assert p == [('sg-shell', '0.1.0-169', '0.1.0-170'), ('wine-sg', '10.0-206', '10.0-207')], p
assert 'sg-shell 0.1.0-169 to 0.1.0-170' in s['label'], s['label']
" && [ -f "$T/rollback/set/sg-shell_0.1.0-169_amd64.deb" ] && ! grep -q libfoo1 "$T/repacked"; then
    pass "the APT hook kept the replaced versions of our packages only (sg-shell, wine-sg; not Debian's libfoo1), repacked"
else fail "the kept set: $(cat "$m" "$T/hook.out" "$T/repacked" 2>&1)"; fi
grep -q '^UNDO 20261008-' "$T/status" && grep -q '^FS ext4' "$T/status" \
    && pass "Settings is told an update can be undone" || fail "status: $(cat "$T/status")"
e="$T/entries/Sg-undo-update.conf"
if grep -q '^title Stained Glass OS -- undo the last update (2026-10-08 ' "$e" && grep -q '^options root=PARTUUID=feed rw quiet sg.undo-update=1$' "$e" \
        && grep -q '^linux /debian/6.12.1/linux$' "$e"; then
    pass "the boot menu has 'Stained Glass OS -- undo the last update', on this system's kernel"
else fail "undo entry: $(cat "$e" 2>&1)"; fi
hook | python3 "$SNAP" apt-hook >/dev/null 2>&1
[ "$(grep -c sg-shell "$T/repacked")" = 1 ] && pass "the same update a moment later (the offline update, then its APT hook): kept once" \
    || fail "repacked again: $(cat "$T/repacked")"
python3 "$SNAP" undo-update >/dev/null 2>&1 && [ -f "$T/rollback/pending" ] && grep -q '^PENDING undo' "$T/status" \
    && pass "undo-update: at the next start" || fail "undo-update"
python3 "$SNAP" undo-apply > "$T/undo.out" 2>&1
if grep -q '^SG_SNAP_UNDOING=1 install -y --allow-downgrades -o' "$T/apt" && grep -q "$T/rollback/set/sg-shell_0.1.0-169_amd64.deb" "$T/apt" \
        && grep -q "$T/rollback/set/wine-sg_10.0-206_amd64.deb" "$T/apt" && [ ! -e "$T/rollback/pending" ] && grep -qx 'hook 0' "$T/apt" && grep -qx 'postinst 0' "$T/apt" && grep -qx 'offline 1' "$T/apt"; then
    pass "undo-apply reinstalls exactly the kept set, downgrades allowed, without the APT hook keeping it again"
else fail "undo-apply: $(cat "$T/apt" "$T/undo.out" 2>&1)"; fi
pin="$T/etc/apt/preferences.d/sg-went-back"
if grep -q '^Package: sg-shell$' "$pin" && grep -q '^Pin: version 0.1.0-170$' "$pin" && grep -q '^Pin-Priority: -1$' "$pin"; then
    pass "the undone versions are kept from apt (a later version installs as usual)"
else fail "no pin: $(cat "$pin" 2>&1)"; fi
[ ! -e "$e" ] && ! grep -q '^UNDO ' "$T/status" && grep -q '^UNDONE .*yes$' "$T/status" \
    && pass "after the undo: no undo entry, Settings told it was undone" || fail "after undo: $(ls "$T/entries"; cat "$T/status")"

# the offline update's prepared list
printf '[update]\nprepared_ids=sg-shell;0.1.0-171;amd64;stained-glass,libfoo1;1.0-2;amd64;debian\n' > "$T/prepared"
rm -f "$T/repacked"
SG_SNAP_PREPARED="$T/prepared" SG_SNAP_NOW=1791600000 python3 "$SNAP" pre-offline-update >/dev/null 2>&1
python3 -c "
import json; s = json.load(open('$m'))
assert [(x['name'], x['version'], x['new']) for x in s['packages']] == [('sg-shell', '0.1.0-169', '0.1.0-171')]
" 2>/dev/null && pass "before the offline update: its prepared list is what is kept and named" || fail "pre-offline-update: $(cat "$m" 2>&1)"

# undo-apply downgrades this very package from inside sg-undo-update.service:
# an upgrade must never stop that unit (the preinst's stop killed it half way)
grep -q '^	dh_installsystemd --no-start --no-stop-on-upgrade --no-restart-after-upgrade sg-undo-update.service$' "$HERE/debian/rules" \
    && grep -q '^	dh_installsystemd --no-start --no-stop-on-upgrade --no-restart-after-upgrade sg-snapshot.service$' "$HERE/debian/rules" \
    && pass "an upgrade or the undo itself never stops sg-undo-update or sg-snapshot (debian/rules)" || fail "debian/rules lets an upgrade stop sg-undo-update"

# --- converting -----------------------------------------------------------------------
out=$(python3 "$SNAP" convert-check 2>&1)
printf '%s\n' "$out" | grep -q '^PROBLEM Connect your PC to power first.$' && printf '%s\n' "$out" | grep -q '^READY no' \
    && pass "converting on a battery, not on mains: refused" || fail "convert-check on battery: $out"
echo 1 > "$T/power/AC/online"
out=$(python3 "$SNAP" convert-check 2>&1)
! printf '%s\n' "$out" | grep -q 'power' && pass "on mains: power is no objection" || fail "convert-check on mains: $out"
SG_SNAP_FSTYPE=btrfs out=$(python3 "$SNAP" convert-check 2>&1)
printf '%s\n' "$out" | grep -q 'not ext4' && pass "a system drive that is not ext4 is not converted" || fail "convert-check on btrfs: $out"

# --- the boot entries of kernels a restore point lacks ---------------------------------
python3 - "$SNAP" "$T" <<'EOF' && pass "going back hides the entries of kernels the restore point lacks, and shows them again" || fail "match_kernels"
import importlib.machinery, importlib.util, os, sys
snap, t = sys.argv[1], sys.argv[2]
l = importlib.machinery.SourceFileLoader('s', snap)
s = importlib.util.module_from_spec(importlib.util.spec_from_loader('s', l)); l.exec_module(s)
d = os.path.join(t, "entries")
open(os.path.join(d, "debian-6.12.2.conf"), "w").write("title x\nversion 6.12.2\nlinux /a\noptions root=PARTUUID=feed rw\n")
s.match_kernels(d, ["6.12.1"])
names = sorted(os.listdir(d))
assert "debian-6.12.2.conf.sg-hidden" in names and "debian-6.12.1+3.conf" in names and "other-6.1.conf" in names, names
s.match_kernels(d, ["6.12.1", "6.12.2"])
assert "debian-6.12.2.conf" in os.listdir(d)
EOF

[ $RC = 0 ] && echo "restore-points-test: PASS" || echo "restore-points-test: FAIL"
exit $RC
