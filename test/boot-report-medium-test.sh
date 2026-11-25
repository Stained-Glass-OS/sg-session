#!/bin/sh
# sg-boot-report finds where to save next to the .iso on a multiboot stick
# (Ventoy): after the switch to the real root, the loop device's backing file
# reads relative to the partition's own mount ("/isos/sg-live.iso", seen on a
# live boot from an exFAT stick, 2026-11-25), not as the full path. Stand-ins
# for /proc/mounts and losetup; nothing real is touched.
#   --mutant: the backing file taken as a full path (must FAIL)
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/sg-bootreport.XXXXXX")
trap 'rm -rf "$T"' EXIT
RC=0
[ "${1:-}" = --mutant ] && export SG_MUTANT_BOOTREPORT_ABSOLUTE=1
mkdir -p "$T/host/sda/isos"
: > "$T/host/sda/isos/sg-live.iso"
printf '/dev/sda %s exfat ro 0 0\n/dev/loop0 /run/initramfs/sg-iso iso9660 ro 0 0\n' "$T/host/sda" > "$T/mounts"
check() { # LOSETUP-OUTPUT what
    printf '%s\n' "$1" > "$T/losetup.out"
    got=$(SG_BOOTREPORT_MOUNTS="$T/mounts" SG_BOOTREPORT_LOSETUP="cat $T/losetup.out" SG_BOOTREPORT_HOSTS="$T/host/[^/]+\$" \
        python3 -c 'import importlib.machinery, sys
m = importlib.machinery.SourceFileLoader("sgbr", sys.argv[1]).load_module()
print(m.medium_dir())' "$HERE/bin/sg-boot-report")
    if [ "$got" = "('$T/host/sda', '$T/host/sda/isos')" ]; then echo "PASS  $2"
    else echo "FAIL  $2: $got"; RC=1; fi
}
check "/isos/sg-live.iso" "the backing file relative to its partition's mount (after the switch to the real root)"
check "$T/host/sda/isos/sg-live.iso" "the backing file as a full path"
exit $RC
