#!/bin/sh
# Gate for Disk Management's partition changes (sg-sysinfo create, delete,
# resize, resize-info), for real, on a LOOP DEVICE ONLY: a 512 MB sparse file
# attached with losetup, named in SG_SYSINFO_DISKS -- the only disk sg-sysinfod
# will then change. Never this machine's disks.
#
# sg-sysinfod runs as root on a socket of the gate's own
# (systemd-socket-activate), and the requests come from this user through it,
# as Disk Management's do: first as a standard user (refused), then as an
# administrator (SG_ADMIN_GROUP = this user's group). Checked with lsblk,
# blkid, e2fsck and ntfsresize: a new ext4 and a new NTFS volume with their
# labels in unallocated space, both shrunk and extended with their file
# systems intact, a mounted volume refused, both deleted.
#
# Needs passwordless sudo, losetup, sfdisk, mkfs.ext4, mkfs.ntfs, resize2fs,
# ntfsresize, systemd-socket-activate; skips (77) without them.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SYSINFO=${SG_SYSINFO:-$HERE/bin/sg-sysinfo}
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
sudo -n true 2>/dev/null || { echo "SKIP: needs passwordless sudo"; exit 77; }
for t in losetup sfdisk mkfs.ext4 mkfs.ntfs resize2fs ntfsresize e2fsck blkid; do
    [ -x "/usr/sbin/$t" ] || [ -x "/sbin/$t" ] || command -v "$t" >/dev/null || { echo "SKIP: $t missing"; exit 77; }
done
command -v systemd-socket-activate >/dev/null || { echo "SKIP: systemd-socket-activate missing"; exit 77; }
PATH="$PATH:/usr/sbin:/sbin"

T=$(mktemp -d /var/tmp/sg-diskops.XXXXXX); chmod 755 "$T"
SOCK="$T/sysinfod.sock"; SP=""; LOOP=""
cleanup() {
    [ -n "$SP" ] && sudo -n kill "$SP" 2>/dev/null
    sudo -n umount "$T/mnt" 2>/dev/null
    [ -n "$LOOP" ] && sudo -n losetup -d "$LOOP" 2>/dev/null
    sudo -n rm -rf "$T"
}
trap cleanup EXIT INT TERM
truncate -s 512M "$T/disk.img"
LOOP=$(sudo -n losetup -f --show "$T/disk.img") || { echo "FAIL: no loop device"; exit 1; }
case "$LOOP" in /dev/loop[0-9]*) ;; *) echo "FAIL: losetup gave '$LOOP'"; exit 1 ;; esac
N=${LOOP#/dev/}
echo "      test disk: $LOOP ($T/disk.img)"

serve() {   # $1: the administrators' group
    [ -n "$SP" ] && sudo -n kill "$SP" 2>/dev/null; sleep 0.5; sudo -n rm -f "$SOCK"
    sudo -n env SG_ADMIN_GROUP="$1" SG_WINE_GROUP="$(id -gn)" SG_SYSINFO_DISKS="$LOOP" \
        systemd-socket-activate -l "$SOCK" --inetd -a -E SG_ADMIN_GROUP -E SG_WINE_GROUP -E SG_SYSINFO_DISKS -E PATH \
        "$SYSINFO" --serve >/dev/null 2>&1 &
    SP=$!
    i=0; while [ ! -S "$SOCK" ] && [ $i -lt 30 ]; do sleep 0.2; i=$((i + 1)); done
    sudo -n chmod 666 "$SOCK"
}
ask() { SG_SYSINFO_SOCKET="$SOCK" SG_SYSINFO_DISKS="$LOOP" "$SYSINFO" "$@" 2>&1; }
MIB=1048576

serve sg-nobody-here
out=$(ask create "$N" $MIB $((200 * MIB)) --fs ext4 --label gatevol)
case "$out" in *"ERROR denied"*administrator*) pass "a standard user may not create a volume" ;; *) fail "standard user: $out" ;; esac
[ -z "$(lsblk -n -r -o NAME "$LOOP" | sed 1d)" ] && pass "the disk is untouched" || fail "partitions appeared: $(lsblk "$LOOP")"

serve "$(id -gn)"
d=$(ask disks)
echo "$d" | grep -q "^DISK $N\$" && pass "the test disk is listed (SG_SYSINFO_DISKS)" || fail "no DISK $N"
out=$(ask create "$N" $MIB $((200 * MIB)) --fs ext4 --label gatevol)
p1="${N}p1"
case "$out" in *"CREATED $p1 ext4"*OK) pass "New Simple Volume: ext4 'gatevol' ($p1)" ;; *) fail "create ext4: $out" ;; esac
[ "$(lsblk -n -b -o SIZE "/dev/$p1" 2>/dev/null)" = $((200 * MIB)) ] && pass "$p1 is 200 MB" || fail "size: $(lsblk -b "/dev/$p1")"
[ "$(sudo -n blkid -o value -s LABEL "/dev/$p1")" = gatevol ] && [ "$(sudo -n blkid -o value -s TYPE "/dev/$p1")" = ext4 ] \
    && pass "blkid: ext4, gatevol" || fail "blkid: $(sudo -n blkid "/dev/$p1")"
[ "$(sudo -n sfdisk -J "$LOOP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["partitiontable"]["label"])')" = gpt ] \
    && pass "a blank disk is initialised as GPT" || fail "label"
out=$(ask create "$N" $((201 * MIB)) $((150 * MIB)) --fs ntfs --label NTFSVOL)
p2="${N}p2"
case "$out" in *"CREATED $p2 ntfs"*OK) pass "New Simple Volume: NTFS 'NTFSVOL' ($p2)" ;; *) fail "create ntfs: $out" ;; esac
[ "$(sudo -n blkid -o value -s TYPE "/dev/$p2")" = ntfs ] && pass "blkid: ntfs" || fail "blkid p2: $(sudo -n blkid "/dev/$p2")"
t=$(sudo -n sfdisk -J "$LOOP" | python3 -c 'import json,sys; print(" ".join(p["type"].lower() for p in json.load(sys.stdin)["partitiontable"]["partitions"]))')
[ "$t" = "0fc63daf-8483-4772-8e79-3d69d8477de4 ebd0a0a2-b9e5-4433-87c0-68b6b72699c7" ] \
    && pass "partition types: Linux file system (ext4), Microsoft basic data (NTFS)" || fail "types: $t"
out=$(ask create "$N" $((100 * MIB)) $((50 * MIB)))
case "$out" in *"ERROR invalid"*) pass "no volume over another" ;; *) fail "overlap: $out" ;; esac

# shrink both, then extend both
info=$(ask resize-info "$p1")
min=$(echo "$info" | sed -n 's/^MIN-SIZE //p'); max=$(echo "$info" | sed -n 's/^MAX-SIZE //p')
[ -n "$min" ] && [ "$min" -lt $((100 * MIB)) ] && [ "$max" = $((200 * MIB)) ] \
    && pass "resize-info: ext4 can shrink to $min bytes, cannot grow (NTFS follows)" || fail "resize-info: $info"
out=$(ask resize "$p1" $((100 * MIB)))
case "$out" in *"RESIZED $p1 $((100 * MIB))"*OK) pass "Shrink Volume: $p1 to 100 MB" ;; *) fail "shrink ext4: $out" ;; esac
out=$(ask resize "$p2" $((80 * MIB)))
case "$out" in *"RESIZED $p2 $((80 * MIB))"*OK) pass "Shrink Volume: $p2 (NTFS) to 80 MB" ;; *) fail "shrink ntfs: $out" ;; esac
sudo -n e2fsck -fn "/dev/$p1" >/dev/null 2>&1 && pass "e2fsck: the shrunk ext4 is clean" || fail "e2fsck after shrink"
out=$(ask resize "$p1" $((300 * MIB)))
case "$out" in *"ERROR invalid"*) pass "Extend Volume: no further than the unallocated space after it" ;; *) fail "over-extend: $out" ;; esac
out=$(ask resize "$p1" $((200 * MIB)))
case "$out" in *"RESIZED $p1 $((200 * MIB))"*OK) pass "Extend Volume: $p1 back to 200 MB" ;; *) fail "extend ext4: $out" ;; esac
bc=$(sudo -n dumpe2fs -h "/dev/$p1" 2>/dev/null | sed -n 's/^Block count: *//p'); bs=$(sudo -n dumpe2fs -h "/dev/$p1" 2>/dev/null | sed -n 's/^Block size: *//p')
[ -n "$bc" ] && [ $((bc * bs)) = $((200 * MIB)) ] && pass "the file system grew with it ($((bc * bs)) bytes)" || fail "fs size $bc x $bs"
out=$(ask resize "$p2" $((250 * MIB)))
case "$out" in *"RESIZED $p2 $((250 * MIB))"*OK) pass "Extend Volume: $p2 (NTFS) to 250 MB" ;; *) fail "extend ntfs: $out" ;; esac
vs=$(sudo -n ntfsresize --info --force "/dev/$p2" 2>/dev/null | sed -n 's/^Current volume size: \([0-9]*\) bytes.*/\1/p')
[ -n "$vs" ] && [ "$vs" -gt $((245 * MIB)) ] && pass "NTFS grew with it ($vs bytes)" || fail "ntfs size: $vs"
sudo -n e2fsck -fn "/dev/$p1" >/dev/null 2>&1 && pass "e2fsck: clean after extending" || fail "e2fsck after extend"

# a mounted volume is refused
mkdir -p "$T/mnt"; sudo -n mount "/dev/$p1" "$T/mnt"
out=$(ask delete "$p1")
case "$out" in *"ERROR denied"*"in use"*) pass "Delete Volume: refused while mounted" ;; *) fail "mounted delete: $out" ;; esac
out=$(ask resize "$p1" $((150 * MIB)))
case "$out" in *"ERROR denied"*) pass "Shrink Volume: refused while mounted" ;; *) fail "mounted resize: $out" ;; esac
sudo -n umount "$T/mnt"

out=$(ask delete "$p2"); out1=$(ask delete "$p1")
case "$out$out1" in *"DELETED $p2"*OK*"DELETED $p1"*OK) pass "Delete Volume: both" ;; *) fail "delete: $out $out1" ;; esac
n=$(sudo -n sfdisk -J "$LOOP" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["partitiontable"].get("partitions", [])))')
[ "$n" = 0 ] && [ ! -e "/dev/$p1" ] && pass "no partitions left, and no stale nodes" || fail "left: $n, $(ls /dev/$N* | tr '\n' ' ')"

[ $RC = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $RC
