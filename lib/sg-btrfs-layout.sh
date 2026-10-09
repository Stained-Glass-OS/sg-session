#!/bin/sh
# The system drive's layout on btrfs: one partition, one pool of free space,
# subvolumes for what a restore point must never take back.
#
#   @            the system: /. What a restore point (sg-snapshot) is a
#                snapshot of, and what going back replaces.
#   @home        /home: people's files. Never in a restore point.
#   @var-log     /var/log, @var-cache /var/cache, @var-tmp /var/tmp: logs,
#                caches, temporary files -- not worth keeping, and a log of
#                what went wrong must survive going back.
#   @prefix      /var/lib/stained-glass/prefix: the machine's Windows side
#                (C:\, its Program Files and the users' Windows profiles). Going
#                back to before an update of Stained Glass OS does not
#                uninstall the Windows programs installed since.
#   @snapshots/  a plain directory of the top level: the restore points
#                (sg-snapshot), never mounted in the running system.
#
# The top level's default subvolume is @, so a boot entry without
# rootflags=subvol=@ still starts the system.
#
# Sourced by sg-install (new installs), the conversion of an ext4 system drive
# (sg-convert-root, in the initrd) and the gates; sg-snapshot (Python) keeps the
# same list (its gate checks they agree).
#
# SPDX-License-Identifier: AGPL-3.0-or-later

SG_SUBVOLS="@home:/home @var-log:/var/log @var-cache:/var/cache @var-tmp:/var/tmp @prefix:/var/lib/stained-glass/prefix"
SG_SNAPDIR="@snapshots"
SG_FSTAB_MARK="# Stained Glass OS: the system drive's subvolumes (restore points leave them alone)"

# sg_btrfs_create TOP: @, the other subvolumes and @snapshots in the mounted top
# level (those already there are kept); @ the default subvolume.
sg_btrfs_create() {
    _top=$1
    [ -d "$_top/@" ] || btrfs -q subvolume create "$_top/@" >/dev/null || return 1
    for _s in $SG_SUBVOLS; do
        [ -d "$_top/${_s%%:*}" ] || btrfs -q subvolume create "$_top/${_s%%:*}" >/dev/null || return 1
    done
    mkdir -p "$_top/$SG_SNAPDIR" && chmod 0700 "$_top/$SG_SNAPDIR" || return 1
    _id=$(btrfs inspect-internal rootid "$_top/@") || return 1
    btrfs -q subvolume set-default "$_id" "$_top" >/dev/null
}

# sg_btrfs_mount DEV ROOT: @ at ROOT, the others under it (mount points made)
sg_btrfs_mount() {
    mount -o subvol=@ "$1" "$2" || return 1
    for _s in $SG_SUBVOLS; do
        mkdir -p "$2${_s#*:}" && mount -o "subvol=${_s%%:*}" "$1" "$2${_s#*:}" || return 1
    done
}

# sg_btrfs_umount ROOT: the others, then ROOT (innermost first)
sg_btrfs_umount() {
    for _m in $(for _s in $SG_SUBVOLS; do echo "${_s#*:}"; done | sort -r); do
        mountpoint -q "$1$_m" 2>/dev/null && umount "$1$_m"
    done
    mountpoint -q "$1" 2>/dev/null && umount "$1"
    return 0
}

# sg_btrfs_fstab FSTAB UUID: our lines in FSTAB (replaced, everything else kept)
sg_btrfs_fstab() {
    _f=$1
    touch "$_f" || return 1
    _mps=$(for _s in $SG_SUBVOLS; do printf '%s ' "${_s#*:}"; done)
    awk -v mps=" $_mps" -v mark="$SG_FSTAB_MARK" '
        $0 == mark { next }
        $1 !~ /^#/ && index(mps, " " $2 " ") && $3 == "btrfs" { next }
        { print }' "$_f" > "$_f.sg-tmp" || return 1
    {
        echo "$SG_FSTAB_MARK"
        for _s in $SG_SUBVOLS; do
            printf 'UUID=%s %s btrfs subvol=%s 0 0\n' "$2" "${_s#*:}" "${_s%%:*}"
        done
    } >> "$_f.sg-tmp"
    mv -f "$_f.sg-tmp" "$_f"
}

# sg_btrfs_cmdline LINE: the kernel command line with rootflags=subvol=@ (any
# other rootflags= replaced)
sg_btrfs_cmdline() {
    printf '%s\n' "$1" | sed -e 's/\(^\| \)rootflags=[^ ]*//g' -e 's/\(root=[^ ]*\)/\1 rootflags=subvol=@/' -e 's/^ *//'
}
