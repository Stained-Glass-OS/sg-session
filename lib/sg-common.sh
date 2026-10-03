#!/bin/sh
# Shared settings and helpers for the Stained Glass session.
# POSIX sh: this runs early, before anything interesting is guaranteed present.

SG_ROOT="${SG_ROOT:-/var/lib/stained-glass}"
SG_PREFIX="${SG_PREFIX:-$SG_ROOT/prefix}"
SG_STATE="${SG_STATE:-$SG_ROOT/state}"
SG_LOG_DIR="${SG_LOG_DIR:-/var/log/stained-glass}"

# MULTIUSER-DEBT: one prefix, one owner. See docs/multiuser-debt.md (D1).
SG_USER="${SG_USER:-sguser}"

# The account that *is* SYSTEM: it owns the system prefix and runs the
# machine-level wineserver, so wine-sg maps it to the SYSTEM SID.
#
# Deliberately not root. Nothing about hosting the Windows system needs Unix
# root -- device access comes from udev rules and group membership, and the
# privilege that matters for installing a driver is NT administrator, which
# wine-sg decides from the prefix's ownership rather than from the kernel.
# Running it as root would put a root process on a socket every desktop user
# can reach, buying no capability an ordinary account lacks.
SG_SYSTEM_USER="${SG_SYSTEM_USER:-sgsystem}"

# The Unix group whose members may use the system prefix. wine-sg decides who
# may connect to a shared wineserver by membership of the group owning its
# server directory, which it takes from the prefix -- so this group *is* the
# access policy, expressed with ordinary Unix tools.
SG_WINE_GROUP="${SG_WINE_GROUP:-sgwine}"

# Administrators (ADR 0012). Membership of this local group is what makes a
# human an administrator: they may elevate a program to run as the SYSTEM
# account (through the broker) and, on the Unix side, use sudo. It is
# deliberately one group for both, so "is an administrator" has a single
# answer. Domain groups map onto it later (P2).
SG_ADMIN_GROUP="${SG_ADMIN_GROUP:-sg-admins}"

# The desktop follows the output. Settings resizes the shell when it changes the
# mode; a change made any other way -- a monitor plugged in or swapped, another
# tool, the compositor -- left the desktop at the old size and the taskbar off
# the screen (David 2026-09-29: the shell did not fill the space after a display
# resize). The X root is the output: when its size changes, Wine's desktop
# takes it (sg-settings --set desktop WxH, which sizes the title bars to it
# too). Runs until the session (PID $2) ends. $1 is the size the desktop was
# started at. First the title bars are sized to the screen (--set metrics).
sg_desktop_follow() {
    _df_last=$1 _df_session=$2
    _df_settings="${SG_SHELL_DIR:-/usr/libexec/stained-glass/shell}/sg-settings64.exe"
    # the title bars take their share of this screen (Settings > Colors > Size
    # title bars to the screen; David 2026-10-02: "kinda small on a 1080p
    # screen"), once the shell is up; a resize below rescales them too
    sleep "${SG_METRICS_DELAY:-4}"
    [ -f "$_df_settings" ] && wine "$_df_settings" --set metrics >/dev/null 2>&1
    while sleep "${SG_DESKTOP_WATCH_SECONDS:-2}" && kill -0 "$_df_session" 2>/dev/null; do
        _df_now=$(xwininfo -root 2>/dev/null | awk '/^ *Width:/ {w=$2} /^ *Height:/ {h=$2} END {if (w && h) print w "x" h}')
        if [ -z "$_df_now" ] || [ "$_df_now" = "$_df_last" ]; then continue; fi
        sg_log "the output is now $_df_now (was $_df_last): the desktop follows"
        [ -f "$_df_settings" ] && wine "$_df_settings" --set desktop "$_df_now" >/dev/null 2>&1
        _df_last=$_df_now
    done
}

# The Wine graphics driver the display path needs. A machine-level fact
# (multi-user debt D4): sg-prefix-init writes it to HKLM, as SYSTEM, and every
# user's explorer reads it from there (wine-sg patch 0023).
# Run the shell and keep it running (multi-user debt D7): restart it when it
# dies abnormally, end the session when it exits cleanly (sign-out), and give
# up if it keeps dying. See sg-run-explorer.  Usage: sg_supervise_shell WxH
sg_supervise_shell() {
    _geom=$1   # saved: the crash accounting below reuses the positional parameters
    _max=${SG_SHELL_MAX_RESTARTS:-5}
    _window=${SG_SHELL_RESTART_WINDOW:-60}
    _crashes=""
    while :; do
        _rc=0
        wine explorer "/desktop=shell,$_geom" || _rc=$?
        if [ "$_rc" -eq 0 ]; then
            sg_log "shell exited cleanly: ending the session"
            return 0
        fi
        _now=$(date +%s)
        _recent=""
        for _t in $_crashes; do
            [ $((_now - _t)) -lt "$_window" ] && _recent="$_recent $_t"
        done
        _crashes="$_recent $_now"
        # shellcheck disable=SC2086 # split the list of timestamps, deliberately
        set -- $_crashes
        if [ "$#" -gt "$_max" ]; then
            sg_log "shell exited abnormally $# times in ${_window}s (last rc=$_rc): giving up, ending the session"
            return "$_rc"
        fi
        sg_log "shell exited abnormally (rc=$_rc): restarting it ($# in ${_window}s)"
        sleep 1
    done
}

# Where this user's live session publishes its display (multi-user debt D9).
# Per user: /run/user/<uid> is the user's own 0700 runtime directory, so a second
# concurrent session neither overwrites nor reads another's. Where there is none
# (a CI runner), a per-uid file in the state directory.
sg_session_env() {
    _rt="/run/user/$(id -u)"
    if [ -d "$_rt" ] && [ -w "$_rt" ]; then
        echo "$_rt/sg-session.env"
    else
        echo "$SG_STATE/session-$(id -u).env"
    fi
}

# Apply machine Group Policy (ADR-less: policy is data, not a decision). An
# administrator drops .reg files under SG_POLICY_DIR; at boot, as the SYSTEM
# account, they are imported into the machine registry. Because they land in
# HKLM (administrator-owned, wine-sg 0024) and shell32's SHRestricted reads
# HKLM first (wine-sg 0025), the policy binds every user and no user can
# override it. Idempotent: importing the same policy twice is harmless.
SG_POLICY_DIR="${SG_POLICY_DIR:-/etc/stained-glass/policy.d}"
# The registry values a .reg sets, one "KEY<TAB>NAME" per line (NAME empty for
# the default value). Used to de-tattoo: a policy value removed from a GPO must
# stop applying, as Windows clears the managed policy branch each refresh.
sg_reg_values() {
    awk '
        /^\[/  { k = substr($0, 2, length($0) - 2); next }
        /^@=/  { if (k != "") print k "\t"; next }
        /^"/   { n = $0; sub(/"=.*/, "", n); sub(/^"/, "", n); gsub(/\\"/, "\"", n);
                 if (k != "") print k "\t" n; next }
    ' "$1"
}

sg_apply_policy() {
    [ "${SG_SYSTEM_PREFIX:-1}" = "1" ] || return 0
    [ -d "$SG_POLICY_DIR" ] || return 0
    _pi="${SG_LIBEXEC:-/usr/libexec/stained-glass}/sg-polimport"
    _state="${SG_STATE:-/var/lib/stained-glass/state}/policy-applied.list"
    _now=$(mktemp)
    for _p in "$SG_POLICY_DIR"/*.reg "$SG_POLICY_DIR"/*.pol; do
        [ -f "$_p" ] || continue
        case "$_p" in
        *.pol)
            # A Group Policy registry.pol (from the Group Policy editor, or a
            # domain): convert it to a .reg under HKLM and import that.
            if [ ! -x "$_pi" ]; then sg_log "WARNING: sg-polimport missing, skipping $(basename "$_p")"; continue; fi
            _reg=$(mktemp --suffix=.reg)
            if "$_pi" "$_p" > "$_reg" 2>/dev/null && \
               wine reg import "$(winepath -w "$_reg" 2>/dev/null)" >/dev/null 2>&1; then
                sg_log "applied policy: $(basename "$_p")"
                sg_reg_values "$_reg" >> "$_now"
            else
                sg_log "WARNING: could not apply policy $(basename "$_p")"
            fi
            rm -f "$_reg" ;;
        *.reg)
            if wine reg import "$(winepath -w "$_p" 2>/dev/null)" >/dev/null 2>&1; then
                sg_log "applied policy: $(basename "$_p")"
                sg_reg_values "$_p" >> "$_now"
            else
                sg_log "WARNING: could not apply policy $(basename "$_p")"
            fi ;;
        esac
    done

    # De-tattoo: a value this machine set last time that no policy sets now is
    # deleted, so a policy removed from a GPO (or a local .reg dropped) stops
    # applying. Only the exact values policy set are touched -- never a branch,
    # never a descriptor -- so a program's own state under those keys is left
    # alone. sgsystem is the machine's administrator, so it may write the
    # administrator-owned policy branches.
    sort -u "$_now" -o "$_now"
    if [ -f "$_state" ]; then
        comm -23 "$_state" "$_now" | while IFS="$(printf '\t')" read -r _k _v; do
            [ -n "$_k" ] || continue
            if [ -n "$_v" ]; then wine reg delete "$_k" /v "$_v" /f >/dev/null 2>&1 || :
            else wine reg delete "$_k" /ve /f >/dev/null 2>&1 || :; fi
            sg_log "removed stale policy value: ${_k}\\${_v}"
        done
    fi
    mkdir -p "$(dirname "$_state")" 2>/dev/null || :
    mv "$_now" "$_state" 2>/dev/null || rm -f "$_now"
}

# Apply a user's Group Policy registry file (HKCU) with de-tattoo, at login:
# a value the user's policy set last time and does not set now is deleted, so
# a policy removed from the user's GPOs lifts. State persists in the user's own
# home ($2), which outlives the login; HKCU is the user's own hive.
#   sg_apply_user_policy NEW_REG STATE_FILE
sg_apply_user_policy() {
    _new=$1 _ustate=$2 _cur=$(mktemp)
    [ -r "$_new" ] && sg_reg_values "$_new" | sort -u > "$_cur"
    if [ -f "$_ustate" ]; then
        comm -23 "$_ustate" "$_cur" | while IFS="$(printf '\t')" read -r _k _v; do
            [ -n "$_k" ] || continue
            if [ -n "$_v" ]; then wine reg delete "$_k" /v "$_v" /f >/dev/null 2>&1 || :
            else wine reg delete "$_k" /ve /f >/dev/null 2>&1 || :; fi
        done
    fi
    { [ -r "$_new" ] && wine reg import "$(winepath -w "$_new" 2>/dev/null)" >/dev/null 2>&1; } || :
    mkdir -p "$(dirname "$_ustate")" 2>/dev/null || :
    mv "$_cur" "$_ustate" 2>/dev/null || rm -f "$_cur"
}

# Protect the machine registry branches (multi-user debt / S2 clause 3). Run
# against the *machine* wineserver, every boot, as the SYSTEM account: creating
# these keys as the prefix owner gives them the HKLM descriptor (administrators
# write, everyone else reads -- wine-sg 0002/0024), and an ordinary user is
# then refused a write beneath them. It must run against the machine server,
# not a transient one, because security descriptors live in the running server
# and are not saved to system.reg; a boot-time re-stamp is what makes the
# protection survive the machine server reloading the hive.
sg_protect_machine_registry() {
    [ "${SG_SYSTEM_PREFIX:-1}" = "1" ] || return 0
    # Administrator-owned policy branches: users read, admins write.
    for _k in 'HKLM\Software\Policies' \
              'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies'; do
        wine reg add "$_k" /f >/dev/null 2>&1 || sg_log "WARNING: could not protect $_k"
    done
    # Per-session display-config containers: wine-sg gives keys under these a
    # DACL interactive users can write, but only if the container exists for
    # them to create under (a non-admin cannot create it beneath Control).
    for _k in 'HKLM\System\CurrentControlSet\Control\Video' \
              'HKLM\System\CurrentControlSet\Control\GraphicsDrivers'; do
        wine reg add "$_k" /f >/dev/null 2>&1 || sg_log "WARNING: could not create $_k"
    done
}

sg_graphics_driver() {
    case "${SG_DISPLAY_PATH:-x11}" in
        wayland) echo wayland ;;
        *)       echo x11 ;;
    esac
}

# Whether to mark the prefix as shared between Unix users (wine-sg's
# .sg-system-prefix). Requires a Wine with patches/sg applied; on a stock Wine
# the marker is simply ignored.
SG_SYSTEM_PREFIX="${SG_SYSTEM_PREFIX:-1}"

# Virtual desktop geometry. The compositor gives us a fixed-size output in
# Phase 0, so the Wine desktop matches it exactly and nothing has to resize.
SG_DESKTOP_W="${SG_DESKTOP_W:-1280}"
SG_DESKTOP_H="${SG_DESKTOP_H:-800}"

# Display path: x11 (compositor + XWayland + winex11 virtual desktop) or wayland
# (winewayland). See docs/decisions/0003 in the stained-glass repo.
SG_DISPLAY_PATH="${SG_DISPLAY_PATH:-x11}"

# Which Wine to use. The image ships wine-sg, built with
# --enable-archs=i386,x86_64, under /opt/wine-sg -- that is what lets a pure
# amd64 machine run 32-bit Windows applications. See ADR 0005.
#
# Empty means "whatever is on PATH", which is how a developer box with only a
# distribution Wine still works. Note that a distribution Wine cannot run
# 32-bit Windows binaries without i386 multiarch.
SG_WINE_DIR="${SG_WINE_DIR-/opt/wine-sg}"
# The compositor that hosts the session. sg-compositor (ADR 0011) when it is
# installed, cage otherwise -- the same "works on stock parts, better on ours"
# arrangement as the Wine prefix. Overridable so a gate can point at a build
# tree.
if [ -z "${SG_COMPOSITOR:-}" ]; then
    if command -v sg-compositor >/dev/null 2>&1; then SG_COMPOSITOR=sg-compositor
    else SG_COMPOSITOR=cage; fi
fi
export SG_COMPOSITOR

# The keyboard layouts chosen in Setup and the first-run setup, for every
# compositor started from here (xkbcommon reads XKB_DEFAULT_*), so the login
# screen, the session and the lock screen type what the keys say. Debian's
# /etc/default/keyboard, read and never sourced. Two layouts switch with
# Windows logo key + Space (XKBOPTIONS grp:win_space_toggle).
sg_keyboard_env() {
    _kf="${SG_KEYBOARD_FILE:-/etc/default/keyboard}"
    [ -r "$_kf" ] || return 0
    for _v in LAYOUT VARIANT OPTIONS MODEL; do
        _val=$(sed -n "s/^XKB$_v=\"\{0,1\}\([A-Za-z0-9_,:()+-]*\)\"\{0,1\}\$/\1/p" "$_kf" | tail -1)
        if [ -n "$_val" ]; then export "XKB_DEFAULT_$_v=$_val"; else unset "XKB_DEFAULT_$_v"; fi
    done
}
sg_keyboard_env

# wlroots' GL renderer on Mesa's software rasteriser -- what a display with
# no 3D driver gets (a VM's virtio-gpu without virgl, bochs, qxl, simpledrm,
# server graphics) -- presented stale frames: the first-run setup, Setup and
# the login screen stayed black, or showed the page before, until a key
# repainted them, while the X windows held the right pixels. pixman renders
# them correctly and is as fast as software GL. So every compositor started
# from here uses pixman unless a GPU with a 3D driver is present (a virtio
# GPU counts when the host offers virgl, its feature bit 0). WLR_RENDERER
# set by hand still wins.
sg_renderer_env() {
    [ -n "${WLR_RENDERER:-}" ] && return 0
    _soft=1
    for _c in "${SG_DRM_SYSFS:-/sys/class/drm}"/card*; do
        case "${_c##*/}" in *-*) continue ;; esac
        [ -e "$_c/device/driver" ] || continue
        _drv=$(readlink -f "$_c/device/driver"); _drv=${_drv##*/}
        case "$_drv" in
        i915|xe|amdgpu|radeon|nouveau|nvidia|vmwgfx) _soft=0 ;;
        virtio-pci|virtio_gpu)
            for _f in "$_c"/device/virtio*/features; do
                [ "$(cut -c1 "$_f" 2>/dev/null)" = 1 ] && _soft=0
            done ;;
        esac
    done
    if [ "$_soft" = 1 ]; then export WLR_RENDERER=pixman; fi
    return 0
}
sg_renderer_env

# The hardware cursor plane of a virtual machine's display (virtio-gpu, QXL,
# Bochs, Cirrus) comes out upside down when the compositor renders with GL
# (virgl: QEMU over VNC drew the pointer upside down and off target, David
# 2026-09-30); the compositor then draws the pointer itself. Rendered in
# software (pixman: a VM without 3D) the hardware cursor is right, and the
# VM's viewer shows that one pointer -- drawing our own as well gave two
# pointers (David 2026-10-01). WLR_NO_HARDWARE_CURSORS set by hand still wins.
sg_cursor_env() {
    [ -n "${WLR_NO_HARDWARE_CURSORS:-}" ] && return 0
    [ "${WLR_RENDERER:-}" = pixman ] && return 0
    for _c in "${SG_DRM_SYSFS:-/sys/class/drm}"/card*; do
        case "${_c##*/}" in *-*) continue ;; esac
        [ -e "$_c/device/driver" ] || continue
        _drv=$(readlink -f "$_c/device/driver"); _drv=${_drv##*/}
        case "$_drv" in
        virtio-pci|virtio_gpu|qxl|bochs|bochs-drm|cirrus|cirrus-qemu) export WLR_NO_HARDWARE_CURSORS=1 ;;
        esac
    done
    return 0
}
sg_cursor_env

# C:\ProgramData is shared the way Windows shares it: what anyone makes in it
# stays writable for the users of the machine (Windows' "Users: create" that
# its subfolders inherit). An elevated installer runs as the SYSTEM account and
# made its folder there 755 and its own group; the program, run by the user,
# could not write in it (Epic Games Launcher: "Self Update Failed", cannot
# create C:\ProgramData\Epic\...). The folder is the Wine group's, setgid,
# with a default ACL giving the group write; what is already there gets the
# same once (STATE stamp), later boots only the folder itself.
#   sg_programdata_shared PROGRAMDATA GROUP STATEDIR
sg_programdata_shared() {
    _pd=$1 _grp=$2 _st=$3
    [ -d "$_pd" ] || return 0
    chgrp "$_grp" "$_pd" 2>/dev/null || :
    chmod 2775 "$_pd" 2>/dev/null || :
    command -v setfacl >/dev/null 2>&1 || return 0
    if [ ! -e "$_st/programdata-shared-1" ]; then
        setfacl -R -P -m "g:$_grp:rwX" -m "d:g:$_grp:rwX" "$_pd" 2>/dev/null || :
        : > "$_st/programdata-shared-1" 2>/dev/null || :
    else
        setfacl -P -m "g:$_grp:rwX" -m "d:g:$_grp:rwX" "$_pd" 2>/dev/null || :
    fi
    # and its folders at every boot: one a SYSTEM service or an installer made
    # with its own security descriptor got 0755 and an ACL mask of r-x, so the
    # users could make nothing in it -- the Ambir scanner's calibration
    # folder in ProgramData\AmbirTechnology, "a read write error" (David
    # 2026-10-02; wine-sg 0769 keeps it from happening, this mends what was).
    # Folders only: what is in them stays its maker's, as on Windows.
    find "$_pd" -xdev -type d ! -type l -exec setfacl -m "g:$_grp:rwx" -m "d:g:$_grp:rwx" {} + 2>/dev/null || :
    return 0
}

# The SYSTEM account may write in the prefix's shared trees -- Program Files,
# Program Files (x86), ProgramData, users\Public -- as SYSTEM may anywhere on
# Windows: what a program installed or wrote there as the user (made by the
# user, 644) the elevated reinstall could not replace (Mp3tag: "Could not write
# file"). An ACL entry for the account, and a default one so later files get
# it too; the existing trees once (STATE stamp), the folders themselves at
# every boot. User profiles get the same from sg-profile-create.
#   sg_system_access DRIVE_C SYSTEM_USER STATEDIR
sg_system_access() {
    _c=$1 _su=$2 _st=$3
    command -v setfacl >/dev/null 2>&1 || return 0
    id "$_su" >/dev/null 2>&1 || return 0
    for _d in "Program Files" "Program Files (x86)" "ProgramData" "users/Public"; do
        [ -d "$_c/$_d" ] || continue
        if [ ! -e "$_st/system-access-1" ]; then
            setfacl -R -P -m "u:$_su:rwX" -m "d:u:$_su:rwX" "$_c/$_d" 2>/dev/null || :
        else
            setfacl -P -m "u:$_su:rwX" -m "d:u:$_su:rwX" "$_c/$_d" 2>/dev/null || :
        fi
    done
    : > "$_st/system-access-1" 2>/dev/null || :
    return 0
}

# Linux programs draw through Xwayland, where the session's windows are
# managed: title bars, the taskbar, placement. A native Wayland toplevel is
# shown full screen over everything, taskbar included (GNOME Calculator from
# SG Store's Open, D-Bus-activated). So GTK, Qt, SDL, Firefox and Electron
# are told to use X11 -- in this environment, the user's systemd manager and
# D-Bus activation, which start most desktop programs.
#   sg_linux_app_env
SG_LINUX_APP_ENV="GDK_BACKEND=x11 QT_QPA_PLATFORM=xcb SDL_VIDEODRIVER=x11 MOZ_ENABLE_WAYLAND=0 ELECTRON_OZONE_PLATFORM_HINT=x11"
sg_linux_app_env() {
    _names=""
    for _kv in $SG_LINUX_APP_ENV; do
        export "${_kv?}"
        _names="$_names ${_kv%%=*}"
    done
    # shellcheck disable=SC2086  # the names, split
    systemctl --user import-environment $_names >/dev/null 2>&1 || true
    if command -v dbus-update-activation-environment >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        dbus-update-activation-environment $_names >/dev/null 2>&1 || true
    fi
}

# SSH is on for everyone now (sg-session's sshd_config.d/05-stained-glass.conf).
# Images before 2026-10-02 carried a lab-only setup in /etc, outside any
# package: sshd started only when root had keys (the gates'), and passwords
# were refused -- "start condition unmet" for David. Those files go, only
# where they are still exactly what the image put there (an administrator's
# own edits stay).
#   sg_ssh_migrate ROOT     (/ on a machine)
sg_ssh_migrate() {
    _r=${1%/}
    for _f in "$_r/etc/systemd/system/ssh.service.d/10-stained-glass-lab.conf" \
              "$_r/etc/systemd/system/ssh.socket.d/10-stained-glass-lab.conf"; do
        [ -f "$_f" ] && [ "$(md5sum < "$_f" | cut -d' ' -f1)" = c7e7281344a9d9bdca5cc286e22acbf8 ] && rm -f "$_f"
        rmdir "${_f%/*}" 2>/dev/null || :
    done
    _f="$_r/etc/ssh/sshd_config.d/10-stained-glass.conf"
    [ -f "$_f" ] && [ "$(md5sum < "$_f" | cut -d' ' -f1)" = f1b19281bb64b15e61e39f27e1d999bc ] && rm -f "$_f"
    return 0
}

# The SYSTEM account's temporary folder, %SystemRoot%\SystemTemp, as Windows
# has it: only SYSTEM may enter (wine-sg 0638 gives it to SYSTEM processes
# from GetTempPath2; elevated installers unpack there). Made at every boot.
#   sg_systemroot_temp DRIVE_C SYSTEM_USER
sg_systemroot_temp() {
    _st="$1/windows/SystemTemp"
    mkdir -p "$_st" || return 0
    # not fatal: the image build's user namespace maps no other uid (and a
    # failing last command of an && list ends a set -e caller: it ended
    # sg-prefix-init in the image build); sg-prefix-init at boot runs as root
    if [ "$(id -u)" = 0 ]; then chown "$2" "$_st" 2>/dev/null || :; fi
    chmod 0700 "$_st"
    # not the shared folders' inherited entries: nobody else reads in here
    command -v setfacl >/dev/null 2>&1 && setfacl -b "$_st" 2>/dev/null
    return 0
}

# The words while a session starts (sg-compositor's backdrop, sg-shell's
# gen-backdrop.py): "Getting things ready" at a person's first sign-in, when
# the profile is being made, "Welcome" after (the default file) -- as Windows
# says them. The first-sign-in words showed at every sign-in (David
# 2026-10-02). A person who signed in before this came (their settings are
# there) is not at their first. Sets SG_BACKDROP for the compositor.
#   sg_session_backdrop
sg_session_backdrop() {
    _st="${XDG_STATE_HOME:-$HOME/.local/state}/stained-glass"
    _first="${SG_BACKDROP_FIRST:-/usr/share/stained-glass/backdrop-first.sgbd}"
    [ -e "$_st/signed-in" ] && return 0
    if mkdir -p "$_st" 2>/dev/null; then : > "$_st/signed-in" 2>/dev/null || :; fi
    [ -e "${XDG_CONFIG_HOME:-$HOME/.config}/stained-glass/settings.json" ] && return 0
    if [ -f "$_first" ]; then
        SG_BACKDROP=$_first
        export SG_BACKDROP
    fi
    return 0
}

# C:\ as Windows has it: what anyone makes there -- a folder an administrator
# or an elevated installer made, C:\test -- the users may change and add to
# (Authenticated Users' inheritable Modify, (OI)(CI)(IO)(M), on Windows' C:\).
# The folder an elevated program made was SYSTEM's, umask 022: a user could
# not make C:\test\test (David 2026-10-02). A default ACL on C:\ gives what is
# made in it the users' group's write, and passes itself on below. The roots
# of Windows' own trees (windows, Program Files, ProgramData, users) are not
# touched; the other folders already there get it once (STATE stamp).
#   sg_c_root_users DRIVE_C GROUP STATEDIR
sg_c_root_users() {
    _c=$1 _grp=$2 _st=$3
    command -v setfacl >/dev/null 2>&1 || return 0
    [ -d "$_c" ] || return 0
    setfacl -m d:u::rwx -m d:g::rwx -m d:o::r-x "$_c" 2>/dev/null || :
    [ -e "$_st/c-root-users-1" ] && return 0
    for _d in "$_c"/* "$_c"/.[!.]*; do
        if [ ! -d "$_d" ] || [ -L "$_d" ]; then continue; fi
        case "${_d##*/}" in
            windows|"Program Files"|"Program Files (x86)"|ProgramData|users) continue ;;
        esac
        chgrp -R -P "$_grp" "$_d" 2>/dev/null || :
        setfacl -R -P -m g::rwX -m d:g::rwX -m m::rwX "$_d" 2>/dev/null || :
        find "$_d" -type d -exec chmod g+s {} + 2>/dev/null || :
    done
    : > "$_st/c-root-users-1" 2>/dev/null || :
    return 0
}

# Wine Mono's .NET support files in the system prefix (fusion.dll, ngen.exe
# and the rest, in windows\Microsoft.NET\Framework*): Wine leaves them to the
# Wine Mono package (wine.inf skips them), which installs them with its MSI
# -- never run for the image's prefix. Without fusion.dll no .NET program
# found anything in the Windows GAC: AmbirScan took its own private copy of
# SQL Server Compact's provider, which then never found its native DLLs; its
# settings were lost and it did not start minimized (David 2026-10-02).
# Installed from Wine Mono's dotnetfakedlls.inf, 64-bit and 32-bit halves,
# when fusion.dll is missing; nothing otherwise.
#   sg_dotnet_support DRIVE_C [INF]
sg_dotnet_support() {
    _c=$1
    _inf=${2:-}
    if [ -z "$_inf" ]; then
        for _i in /usr/share/wine/mono/wine-mono-*/support/dotnetfakedlls.inf; do
            [ -f "$_i" ] && _inf=$_i
        done
    fi
    [ -n "$_inf" ] && [ -f "$_inf" ] || return 0
    _fw="$_c/windows/Microsoft.NET"
    if [ -f "$_fw/Framework/v4.0.30319/fusion.dll" ] &&
       { [ ! -d "$_c/windows/syswow64" ] || [ -f "$_fw/Framework64/v4.0.30319/fusion.dll" ]; }; then
        return 0
    fi
    _winf="Z:$(printf '%s' "$_inf" | tr '/' '\134')"
    wine rundll32 setupapi.dll,InstallHinfSection DefaultInstall 128 "$_winf" >/dev/null 2>&1 || :
    if [ -d "$_c/windows/syswow64" ]; then
        # shellcheck disable=SC1003  # a Windows path, its backslashes literal
        wine 'C:\windows\syswow64\rundll32.exe' setupapi.dll,InstallHinfSection DefaultInstall 128 "$_winf" >/dev/null 2>&1 || :
    fi
    return 0
}

# Program Files is the administrators': users may read and run what is there,
# not change it -- as on Windows, where Users have read and execute only. The
# prefix is made by SYSTEM with the Wine group's write (umask 002), so every
# user could replace a program or a DLL in Common Files that an administrator
# or SYSTEM later runs. The owning group loses write (setfacl g::, so the ACL
# mask and SYSTEM's own entry stay); SYSTEM still writes there by its entry
# (sg_system_access). A folder an installer shared with the users (setgid, the
# server's sg_users_group: Steam's) keeps its sharing. The whole trees once
# (STATE stamp, cleared when Wine updates the prefix), the roots at every boot.
#   sg_program_files_protected DRIVE_C GROUP STATEDIR
sg_program_files_protected() {
    _c=$1 _grp=$2 _st=$3
    command -v setfacl >/dev/null 2>&1 || return 0
    for _d in "Program Files" "Program Files (x86)"; do
        [ -d "$_c/$_d" ] || continue
        setfacl -m g::r-x "$_c/$_d" 2>/dev/null || :
        [ -e "$_st/program-files-protected-1" ] && continue
        find "$_c/$_d" -mindepth 1 -type d -perm -2000 -group "$_grp" -prune -o \
            ! -type l -group "$_grp" -perm -g=w -print0 2>/dev/null |
            xargs -0 -r setfacl -m g::r-X 2>/dev/null || :
    done
    : > "$_st/program-files-protected-1" 2>/dev/null || :
    return 0
}

# The work area for Linux programs on X11: the screen (W H) less the taskbar.
# Without _NET_WORKAREA, Qt and GTK take the whole screen as theirs, and a
# program that sizes itself to it (SG Office's editors) covered the taskbar.
# The compositor's window manager (wlroots') says what it supports first; the
# work area goes beside that. The bar's height is the one the compositor
# keeps maximized windows above (DECOR_TASKBAR_H, 40). Needs DISPLAY.
#
# _NET_SUPPORTED is a list of atoms, and xprop -set cannot write one: it made
# the whole list ONE atom named "_NET_WM_STATE, ..., _NET_WORKAREA", so Qt and
# GTK saw a window manager supporting nothing -- no _NET_WM_MOVERESIZE (SG
# Office's title bar could not be dragged), no _NET_WM_STATE, no
# _NET_ACTIVE_WINDOW. sg_x11_add_supported appends one atom to the list with
# Xlib (python3's ctypes); without python3 the list is left as it is.
sg_x11_add_supported() {
    command -v python3 >/dev/null 2>&1 || return 2
    python3 - "$1" <<'PY'
import ctypes, ctypes.util, sys
x = ctypes.CDLL(ctypes.util.find_library("X11") or "libX11.so.6")
x.XOpenDisplay.restype = ctypes.c_void_p
x.XOpenDisplay.argtypes = [ctypes.c_char_p]
x.XDefaultRootWindow.restype = ctypes.c_ulong
x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
x.XInternAtom.restype = ctypes.c_ulong
x.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
x.XGetWindowProperty.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_long, ctypes.c_long,
                                 ctypes.c_int, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong),
                                 ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_ulong),
                                 ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.POINTER(ctypes.c_ulong))]
x.XChangeProperty.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_int,
                              ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
x.XFree.argtypes = [ctypes.c_void_p]
x.XCloseDisplay.argtypes = [ctypes.c_void_p]
XA_ATOM, PROP_MODE_REPLACE = 4, 0
d = x.XOpenDisplay(None)
if not d:
    sys.exit(1)
root = x.XDefaultRootWindow(d)
supported = x.XInternAtom(d, b"_NET_SUPPORTED", 0)
want = x.XInternAtom(d, sys.argv[1].encode(), 0)
kind, fmt, n, after = ctypes.c_ulong(), ctypes.c_int(), ctypes.c_ulong(), ctypes.c_ulong()
data = ctypes.POINTER(ctypes.c_ulong)()
if (x.XGetWindowProperty(d, root, supported, 0, 4096, 0, XA_ATOM, ctypes.byref(kind), ctypes.byref(fmt),
                         ctypes.byref(n), ctypes.byref(after), ctypes.byref(data)) != 0
        or kind.value != XA_ATOM or fmt.value != 32 or n.value == 0):
    sys.exit(1)                     # no window manager's list (yet)
atoms = [data[i] for i in range(n.value)]
x.XFree(data)
if want not in atoms:
    atoms.append(want)
    x.XChangeProperty(d, root, supported, XA_ATOM, 32, PROP_MODE_REPLACE,
                      (ctypes.c_ulong * len(atoms))(*atoms), len(atoms))
x.XCloseDisplay(d)
PY
}

sg_x11_workarea() {
    _w=$1 _h=$2 _tries=0
    command -v xprop >/dev/null 2>&1 || return 0
    case "$_w$_h" in *[!0-9]*|"") return 0 ;; esac
    # the window manager's list first (it may not be there yet), then ours beside it
    while [ "$_tries" -lt "${SG_WORKAREA_TRIES:-20}" ]; do
        sg_x11_add_supported _NET_WORKAREA 2>/dev/null; _rc=$?
        [ "$_rc" -ne 1 ] && break
        sleep 0.5; _tries=$((_tries + 1))
    done
    xprop -root -f _NET_WORKAREA 32c -set _NET_WORKAREA "0, 0, $_w, $((_h - ${SG_TASKBAR_H:-40}))" 2>/dev/null &&
        sg_log "work area for Linux programs: ${_w}x$((_h - ${SG_TASKBAR_H:-40}))"
    return 0
}

# Where a session's compositor puts its privileged and control sockets: one
# directory per session user, named by uid, under a seat directory that
# tmpfiles creates 1770 root:sgwine. Per-uid because the sticky bit would stop
# a later user removing an earlier user's stale socket, and the compositor
# refuses to start without its sockets. sg-lockd trusts a directory only if
# its name matches the compositor's peer uid.
# Deliberately NOT under /run/stained-glass: that is sg-wineserver.service's
# RuntimeDirectory, which systemd deletes whenever the service stops -- taking
# the lock sockets with it and leaving the next session unlockable. Its own
# runtime path is independent of any service's lifecycle.
SG_SEAT_DIR="${SG_SEAT_DIR:-/run/stained-glass-seat/seat0}"

# Where the image stages the Direct3D translation layers (DXVK, VKD3D-Proton)
# as PE DLLs. Absent on a machine that did not install them, which is a
# supported configuration: the prefix simply keeps Wine's own D3D.
SG_D3D_DIR="${SG_D3D_DIR:-/opt/sg-d3d}"

# Registry defaults other packages contribute to every new prefix: *.reg files,
# imported in name order by sg-prefix-init before it takes the Default User
# profile, so their HKCU values reach every user. sg-shell ships the window
# colours here. Absent is fine -- nothing is imported.
SG_DEFAULTS_DIR="${SG_DEFAULTS_DIR:-/usr/share/stained-glass/defaults.d}"

# Windows applications the image bundles (PowerShell 7, CPython), staged as
# upstream Windows builds. sg-install-apps links them into the prefix. Absent
# is fine -- nothing is installed.
SG_APPS_DIR="${SG_APPS_DIR:-/opt/sg-apps}"


# The desktop's compositor (sg-compositor's sg-deskcomp): drop shadows, real
# alpha and the window effects for the Windows programs' windows, which are
# all children of Wine's desktop window. It waits for the desktop's picture
# (wine-sg 0744) and, if it ends, X draws the desktop as before; so it is
# started once and not supervised. SG_DESKCOMP=0 leaves it out.
sg_start_deskcomp() {
    _dc="${SG_LIBEXEC:-/usr/libexec/stained-glass}/sg-deskcomp"
    [ "${SG_DESKCOMP:-1}" != 0 ] && [ -x "$_dc" ] || return 0
    sg_log "starting the desktop's compositor (sg-deskcomp)"
    "$_dc" </dev/null &
}

# sg_keep_running NAME CMD... -- start CMD in the background unless one of
# this user's processes is named NAME (its first 15 characters, as the kernel
# keeps it); 0: it runs, 1: it was (re)started. The shell's helpers -- Start,
# the taskbar's icons, the desktop's compositor -- come back after a crash or
# the shell's restart: one xkill'ed Linux window took explorer with it, the
# shell came back with Wine's own Start menu, ours never again (David
# 2026-10-02).
sg_keep_running() {
    _kname=$(printf '%.15s' "$1")
    shift
    pgrep -u "$(id -u)" -x "$_kname" >/dev/null 2>&1 && return 0
    "$@" </dev/null &
    return 1
}

# Copy and paste with the computer a virtual machine runs on (David
# 2026-10-01: he could not paste into the VM): SPICE's guest agent, for this
# session's X display, when the machine has SPICE's port (virt-manager,
# GNOME Boxes, QEMU with a spice-vdagent channel). The system half
# (spice-vdagentd) starts on its own when the port is there. Not supervised:
# without it, only copy and paste across the VM's edge are missing.
sg_start_vdagent() {
    _port="${SG_VDAGENT_PORT:-/dev/virtio-ports/com.redhat.spice.0}"
    [ -e "$_port" ] && command -v spice-vdagent >/dev/null 2>&1 || return 0
    sg_log "starting the virtual machine's clipboard agent (spice-vdagent)"
    spice-vdagent -x </dev/null >/dev/null 2>&1 &
}

# These are inherited by the compositor's child, so they must be exported: the
# session crosses a process boundary between sg-session-start and sg-run-explorer.
export SG_ROOT SG_PREFIX SG_STATE SG_LOG_DIR SG_USER
export SG_DESKTOP_W SG_DESKTOP_H SG_DISPLAY_PATH SG_WINE_DIR
export SG_WINE_GROUP SG_SYSTEM_PREFIX SG_SYSTEM_USER

# printf, not echo: dash's echo interprets backslash escapes, and these lines
# carry Windows paths -- "PythonCore\3.14" logged with echo prints \3 as an
# octal control character.
sg_log() { printf '[sg-session] %s\n' "$*" >&2; }
sg_die() { printf '[sg-session] FATAL: %s\n' "$*" >&2; exit 1; }

# Wine, always pointed at the system prefix. Every caller goes through this so
# there is exactly one place that decides which prefix is "the" prefix.
sg_wine_env() {
    # Put our Wine ahead of any distribution one. Every caller goes through
    # here, so there is exactly one place that decides which Wine is "the" Wine.
    if [ -n "${SG_WINE_DIR:-}" ] && [ -x "$SG_WINE_DIR/bin/wine" ]; then
        case ":$PATH:" in
            *":$SG_WINE_DIR/bin:"*) ;;
            *) PATH="$SG_WINE_DIR/bin:$PATH"; export PATH ;;
        esac
    fi

    WINEPREFIX="$SG_PREFIX"
    export WINEPREFIX
    # A win64 prefix. With wine-sg that still runs 32-bit Windows applications,
    # via new WoW64 and a populated syswow64 -- see ADR 0005.
    WINEARCH="${WINEARCH:-win64}"
    export WINEARCH
    # Keep Wine's own chatter out of the boot path unless someone asks for it.
    WINEDEBUG="${WINEDEBUG:--all}"
    export WINEDEBUG
    # Deliberately NOT disabling mscoree/mshtml here. This used to, to stop
    # Wine popping its Mono and Gecko installer dialogs, but everything inherits
    # this environment -- the desktop, every program a user starts from it, and
    # the machine's Windows services. With mscoree disabled Wine cannot load a
    # .NET assembly, so PowerShell 7 and every other .NET program failed
    # ("Could not load file or assembly System.Runtime.dll"). The override
    # belongs only on the unattended prefix builds and updates: sg_wine_unattended.
}

# Run one command for the unattended prefix build and update paths. Wine
# installs Mono (.NET Framework) and Gecko (the HTML engine) silently when their
# MSIs are on disk (/usr/share/wine or wine-sg's own share/wine), and otherwise
# pops a download dialog that would wait forever for a click. So suppress each
# only when it is not staged: suppressing a staged one would skip installing it.
sg_addon_staged() {
    # Either form Wine accepts: an MSI it installs into the prefix, or the
    # unpacked directory (wine-mono-<ver>, wine-gecko-<ver>-<arch>) it runs in
    # place -- which is how the image ships them.
    for _d in "${SG_WINE_DIR:-/opt/wine-sg}/share/wine/$1" "/usr/share/wine/$1"; do
        for _f in "$_d"/*.msi "$_d"/wine-"$1"-*; do [ -e "$_f" ] && return 0; done
    done
    return 1
}
sg_wine_unattended() {
    _off=""
    sg_addon_staged mono  || _off="mscoree"
    sg_addon_staged gecko || _off="${_off:+$_off,}mshtml"
    if [ -n "$_off" ]; then
        WINEDLLOVERRIDES="${WINEDLLOVERRIDES:+$WINEDLLOVERRIDES;}$_off=" "$@"
    else
        "$@"
    fi
}

# sg_x_cookie FILE -- write an Xauthority file holding one random
# MIT-MAGIC-COOKIE-1 for any display (FamilyWild), readable by this account
# only. An X server started with "-auth FILE" then admits only clients that can
# read FILE. Without -auth, Xwayland admits every local account -- any program
# in any session could type into (XTEST) or read (XGetImage) a lock screen or a
# consent prompt drawn on it. (Measured, ADR 0012 / B56.)
sg_x_cookie() {
    ( umask 077
      _esc=''
      for _b in $(od -An -to1 -N16 /dev/urandom); do _esc="$_esc\\$_b"; done
      # family 0xffff, empty address and display, name, 16-byte data
      # shellcheck disable=SC2059  # the format is built from octal escapes on purpose
      printf "\\377\\377\\000\\000\\000\\000\\000\\022MIT-MAGIC-COOKIE-1\\000\\020$_esc" > "$1" )
    [ "$(wc -c < "$1")" -eq 44 ]
}
