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

# The primary monitor's size, WxH (xrandr --listmonitors: the one marked *,
# else the first), or $1 when there is no X server to ask: with several
# monitors the X root is all of them, and the display scale and the work area
# go by the primary one.
sg_primary_size() {
    _ps=$(xrandr --listmonitors 2>/dev/null | awk '
        /^ *[0-9]+:/ { g = $3; sub(/\/[0-9]+/, "", g); sub(/\/[0-9]+/, "", g); sub(/\+.*/, "", g)
                       if (!first) first = g; if ($2 ~ /\*/) prim = g }
        END { print (prim ? prim : first) }')
    case "$_ps" in [0-9]*x[0-9]*) echo "$_ps" ;; *) echo "$1" ;; esac
}

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
        # a monitor back (woken, plugged in again) or in another mode at the
        # same size: the mode, scale and place Settings kept for it, again --
        # David's 144 Hz monitor woke at its 165 Hz preferred mode and stayed
        # there (2026-11-16): the desktop's size had not changed, so nothing
        # below ran. Nothing when it already is, so this does not go round.
        if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wlr-randr >/dev/null 2>&1; then
            _df_out=$(wlr-randr 2>/dev/null)
            _df_sig=$(printf '%s\n' "$_df_out" | awk '/^[^ ]/ {o = $1} /current/ {print o, $1, $3}')
            # which monitors are on: a monitor plugged in or out, turned on or off, since the
            # layout was last put back (pending until the desktop's size follows it)
            _df_set=$(printf '%s\n' "$_df_out" | awk '/^[^ ]/ {o = $1} /^ *Enabled: yes/ {print o}' | sort | tr '\n' ' ')
            [ -n "${_df_set_last+x}" ] && [ "$_df_set" != "$_df_set_last" ] && _df_set_changed=1
            _df_set_last=$_df_set
            if [ -n "$_df_sig" ] && [ "$_df_sig" != "${_df_sig_last:-}" ] && [ -n "${_df_sig_seen:-}" ] \
                && [ -z "${SG_MUTANT_NO_MODE_RESTORE:-}" ] && command -v sg-settingsctl >/dev/null 2>&1; then
                _df_r=$(sg-settingsctl display restore 2>/dev/null | grep '^RESTORED' | tr '\t\n' '  ')
                [ -n "$_df_r" ] && sg_log "display restored: $_df_r"
            fi
            _df_sig_last=$_df_sig
            [ -n "$_df_sig" ] && _df_sig_seen=1
            # the main display, kept: Xwayland forgets the X primary whenever the
            # compositor takes an output away and gives it back (randr's
            # RROutputDestroy), and an output that came back at sign-in, after
            # the layout was put back and before the watch above began, left
            # the main taskbar on the left display (1 boot in 3, ledger i0655).
            # Windows never loses the main display: with several on and none
            # primary, the kept layout's main display again (once per loss --
            # with no layout kept there is nothing to put back)
            if [ -n "${DISPLAY:-}" ] && [ -z "${SG_MUTANT_PRIMARY_UNWATCHED:-}" ] && command -v xrandr >/dev/null 2>&1 \
                && command -v sg-settingsctl >/dev/null 2>&1; then
                _df_mons=$(xrandr --listmonitors 2>/dev/null)
                if [ "$(printf '%s\n' "$_df_mons" | grep -c '^ *[0-9][0-9]*: ')" -gt 1 ] \
                    && ! printf '%s\n' "$_df_mons" | grep -q '^ *[0-9][0-9]*: [+]*\*'; then
                    if [ -z "${_df_noprim:-}" ]; then
                        _df_noprim=1
                        _df_r=$(sg-settingsctl display restore 2>/dev/null | grep '^RESTORED' | tr '\t\n' '  ')
                        sg_log "the X screen lost its main display: ${_df_r:-no layout kept to put back}"
                    fi
                else
                    _df_noprim=
                fi
            fi
        fi
        _df_now=$(xwininfo -root 2>/dev/null | awk '/^ *Width:/ {w=$2} /^ *Height:/ {h=$2} END {if (w && h) print w "x" h}')
        if [ -z "$_df_now" ] || [ "$_df_now" = "$_df_last" ]; then continue; fi
        sg_log "the output is now $_df_now (was $_df_last): the desktop follows"
        # (sg-settings --set desktop also sets the recommended display scale
        # for the new size, unless the user picked one). Over every monitor
        # (HostMonitors, wine-sg 7749) Wine follows them itself: the desktop
        # given the size of all of them as one mode made the primary monitor
        # that wide; the scale goes by the primary one.
        if [ "$(sg_reg_string 'HKCU\Software\Wine\Explorer' HostMonitors)" = Y ]; then
            # a monitor plugged in or out: this set of monitors as Settings
            # kept it (where each is, the main display; sg-settingsctl);
            # nothing when it already is, so this does not go round again
            if command -v sg-settingsctl >/dev/null 2>&1 && [ -n "${WAYLAND_DISPLAY:-}" ]; then
                if [ -n "${_df_set_changed:-}" ] || [ -n "${SG_MUTANT_MOVE_UNDONE:-}" ]; then
                    _df_r=$(sg-settingsctl display restore 2>/dev/null | grep '^RESTORED' | tr '\t\n' '  ')
                    [ -n "$_df_r" ] && sg_log "display restored: $_df_r"
                else
                    # the same monitors, placed elsewhere by another tool (wlr-randr --pos, a
                    # Linux display tool): kept as this set's layout, as Windows keeps a layout
                    # however it was made -- putting the kept one back undid every such move
                    _df_pl=$(wlr-randr 2>/dev/null | awk '/^[^ ]/ {o = $1} /^ *Enabled: yes/ {on[o] = 1}
                        /^ *Position:/ {split($2, p, ","); pos[o] = p[1] " " p[2]}
                        END {for (o in on) if (o in pos) printf "%s %s ", o, pos[o]}')
                    # shellcheck disable=SC2086
                    [ -n "$_df_pl" ] && sg-settingsctl display layout $_df_pl >/dev/null 2>&1 &&
                        sg_log "display moved by another tool, kept: $_df_pl"
                fi
                _df_set_changed=
            fi
            _df_prim=$(sg_primary_size "$_df_now")
            sg_auto_scale "${_df_prim%x*}" "${_df_prim#*x}" >/dev/null
            [ -f "$_df_settings" ] && wine "$_df_settings" --set metrics >/dev/null 2>&1
        else
            [ -f "$_df_settings" ] && wine "$_df_settings" --set desktop "$_df_now" >/dev/null 2>&1
        fi
        _df_last=$_df_now
        # Linux programs (running ones too), and the work area above the
        # taskbar, at the scale now in use
        _df_lp=$(sg_reg_dword 'HKCU\Control Panel\Desktop' LogPixels)
        SG_SCALE=$(( ${_df_lp:-96} * 100 / 96 ))
        sg_linux_scale "$SG_SCALE"
        sg_x11_workarea "${_df_now%x*}" "${_df_now#*x}"
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
    # SG_SESSION_ENV: a gate's own file (test/run-session-test.sh), so a gate
    # never reads a stale one in the person's runtime directory, nor writes it
    if [ -n "${SG_SESSION_ENV:-}" ]; then echo "$SG_SESSION_ENV"; return; fi
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

# The person's own keyboard layouts, as Windows keeps them per user: Settings >
# Time & Language > Language writes them (sg-settingsctl keyboard set) and the
# session's compositor takes them from here at every sign-in (sg-session-start),
# in place of the machine's from Setup and the first-run setup, which the
# sign-in screen keeps. True if the user has their own.
sg_user_keyboard_env() {
    _ukbd="${XDG_CONFIG_HOME:-${HOME:-/nonexistent}/.config}/stained-glass/keyboard"
    [ -r "$_ukbd" ] && [ -z "${SG_MUTANT_KBD_MACHINE_ONLY:-}" ] || return 1
    _mkbd="${SG_KEYBOARD_FILE:-}"
    SG_KEYBOARD_FILE="$_ukbd"
    sg_keyboard_env
    if [ -n "$_mkbd" ]; then SG_KEYBOARD_FILE="$_mkbd"; else unset SG_KEYBOARD_FILE; fi
    return 0
}

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

# No GPU driver at all -- no DRM device once udev has handled every device
# (nomodeset, an NVIDIA card nouveau is kept off, a GPU newer than the
# kernel): the compositor goes to the Basic Display Adapter at once
# (SG_BASIC_DISPLAY=1). Asked first, wlroots waited ten seconds for a GPU to
# appear before each fallback: the first-run setup, the login screen and
# every sign-in each sat ten seconds on a blank screen. While udev still has
# events queued (a driver may be loading) or is not running, wlroots waits as
# before. Windows starts on its Basic Display Adapter with no wait.
# udev's queue is waited out first, up to SG_UDEV_WAIT seconds (default 5,
# polled every 0.2 s, a card that appears meanwhile ends it): a login screen
# started while udev still had boot events queued took wlroots' full ten
# seconds on a machine that never gets a card (next34 nouveau gate, the
# image's own initrd). SG_BASIC_DISPLAY set by hand still wins. Stand-ins:
# SG_DRM_SYSFS, SG_UDEV_RUN (/run/udev).
sg_drm_card_present() {
    for _c in "${SG_DRM_SYSFS:-/sys/class/drm}"/card*; do
        case "${_c##*/}" in *-*) continue ;; esac
        [ -e "$_c" ] && return 0
    done
    return 1
}
sg_basic_display_env() {
    [ -n "${SG_BASIC_DISPLAY:-}" ] && return 0
    sg_drm_card_present && return 0
    _ur=${SG_UDEV_RUN:-/run/udev}
    [ -e "$_ur/control" ] || return 0
    _n=$(( ${SG_UDEV_WAIT:-5} * 5 ))
    while [ -e "$_ur/queue" ]; do
        [ "$_n" -gt 0 ] || return 0
        sleep 0.2 2>/dev/null || sleep 1
        _n=$((_n - 1))
        sg_drm_card_present && return 0
    done
    sg_drm_card_present && return 0
    export SG_BASIC_DISPLAY=1
    return 0
}
sg_basic_display_env

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
    # (not the all-users Start menu: the administrators', sg_shared_shortcuts_protected)
    find "$_pd" -xdev -path "$_pd/Microsoft/Windows/Start Menu" -prune -o \
        -type d ! -type l -exec setfacl -m "g:$_grp:rwx" -m "d:g:$_grp:rwx" {} + 2>/dev/null || :
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
# XDG_SESSION_TYPE=x11 is what Electron 39 and later (and Chromium's own
# "auto") go by: they ignore ELECTRON_OZONE_PLATFORM_HINT and choose Wayland
# when the session type says wayland -- which wlroots sets in the compositor
# for everything it starts (the Claude desktop app, David 2026-10-06: no
# taskbar button, over the taskbar, lost after Alt+Tab). sg-run-explorer
# calls this again inside the compositor for that reason. Its programs do
# draw on X11 here; the compositor's own Wayland helpers go by
# WAYLAND_DISPLAY, which stays. SDL 3 reads SDL_VIDEO_DRIVER, SDL 2
# SDL_VIDEODRIVER.
#   sg_linux_app_env
# And Java loads no assistive technology from the home folder's
# .accessibility.properties: the folder is the Windows profile too, and a
# Windows Java with the Access Bridge on (NVDA's setup turns it on) names
# com.sun.java.accessibility.AccessBridge there -- every Linux Java program
# then failed to start, "Assistive Technology not found" (Arduino IDE, qa5
# 2026-10-21). wine-sg 5951 keeps JAVA_TOOL_OPTIONS from Windows programs,
# so a Windows Java still loads its Access Bridge.
SG_LINUX_APP_ENV="GDK_BACKEND=x11 QT_QPA_PLATFORM=xcb SDL_VIDEODRIVER=x11 SDL_VIDEO_DRIVER=x11 MOZ_ENABLE_WAYLAND=0 ELECTRON_OZONE_PLATFORM_HINT=x11 XDG_SESSION_TYPE=x11 JAVA_TOOL_OPTIONS=-Djavax.accessibility.assistive_technologies="
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

# ---- the display scale (high-resolution screens) ------------------------------
# David 2026-10-05, a Surface Pro 7 (2736x1824, 12.3"): "everything is tiny";
# "the taskbar will take up the same % of screen as on a 1080p screen does".
# The scale (Windows' LogPixels, HKCU\Control Panel\Desktop) is the
# recommended one for the screen until the user picks one in Settings >
# Display: the shorter side over 1080, to the nearest of Windows' 25% steps,
# never below 100% (1080p and smaller stay exactly as they were), at most
# 400% -- 1440 lines 125%, 1824 175%, 2160 200%. Windows weighs the panel's
# physical size (EDID) too; here the screen's lines alone decide, so a
# picture takes the same share of every screen. The same rule is sg-shell's
# scale_for_screen (Settings, --set scale auto|metrics|desktop): keep them
# in step (test/display-scale-test.sh and sg-shell's test/hidpi-check.sh
# check the same table).
#   sg_scale_for W H   -> percent
sg_scale_for() {
    _ss=$1
    [ "$2" -lt "$_ss" ] 2>/dev/null && _ss=$2
    case "$_ss" in ''|*[!0-9]*) echo 100; return 0 ;; esac
    _sq=$(( (_ss * 4 + 540) / 1080 ))
    [ "$_sq" -lt 4 ] && _sq=4
    [ "$_sq" -gt 16 ] && _sq=16
    echo $(( _sq * 25 ))
}

# A REG_DWORD of the current account's (wine reg query), in decimal; empty
# when there is none.   sg_reg_dword KEY NAME
sg_reg_dword() {
    _rd=$(wine reg query "$1" /v "$2" 2>/dev/null | tr -d '\r' | awk -v n="$2" '$1 == n && $2 == "REG_DWORD" { print $3; exit }')
    [ -n "$_rd" ] && printf '%d\n' "$_rd"
    return 0
}

# A REG_SZ of the current account's, or empty.   sg_reg_string KEY NAME
sg_reg_string() {
    wine reg query "$1" /v "$2" 2>/dev/null | tr -d '\r' | awk -v n="$2" '$1 == n && $2 == "REG_SZ" { print $3; exit }'
    return 0
}

# The automatic scale for this account on a WxH screen, before its Windows
# programs start (they read LogPixels once, at their start): the
# recommended one, unless the user picked one -- sg-shell's scale_auto,
# whose registry values these are (Software\Stained Glass\Display:
# ScaleChosen, the pick sticks; AutoLogPixels, what this last wrote; a
# LogPixels other than that and 96 was picked before this existed, and is
# the user's). Prints the scale in use, in percent. Needs sg_wine_env.
#   sg_auto_scale W H
sg_auto_scale() {
    _as_want=$(( $(sg_scale_for "$1" "$2") * 96 / 100 ))
    _as_lp=$(sg_reg_dword 'HKCU\Control Panel\Desktop' LogPixels)
    _as_key='HKCU\Software\Stained Glass\Display'
    # both of the key's values in one wine start (sign-in waits on this)
    _as_vals=$(wine reg query "$_as_key" 2>/dev/null | tr -d '\r')
    _as_chosen=$(echo "$_as_vals" | awk '$1 == "ScaleChosen" && $2 == "REG_DWORD" { print $3 }')
    _as_auto=$(echo "$_as_vals" | awk '$1 == "AutoLogPixels" && $2 == "REG_DWORD" { print $3 }')
    [ -n "$_as_chosen" ] && _as_chosen=$(printf '%d' "$_as_chosen")
    [ -n "$_as_auto" ] && _as_auto=$(printf '%d' "$_as_auto")
    if [ "${_as_chosen:-0}" != 0 ]; then
        :
    elif [ -n "$_as_lp" ] && [ "$_as_lp" != 96 ] && [ "$_as_lp" != "${_as_auto:-}" ]; then
        wine reg add "$_as_key" /v ScaleChosen /t REG_DWORD /d 1 /f >/dev/null 2>&1
    elif [ "${_as_lp:-96}" != "$_as_want" ]; then
        if wine reg add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d "$_as_want" /f >/dev/null 2>&1; then
            wine reg add "$_as_key" /v AutoLogPixels /t REG_DWORD /d "$_as_want" /f >/dev/null 2>&1
            sg_log "display scale: $(( _as_want * 100 / 96 ))% for the ${1}x$2 screen (LogPixels $_as_want)"
            _as_lp=$_as_want
        fi
    fi
    echo $(( ${_as_lp:-96} * 100 / 96 ))
}

# The screen's size, from the X server ($DISPLAY): WxH, or nothing.
sg_x_size() {
    xwininfo -root 2>/dev/null | awk '/^ *Width:/ {w=$2} /^ *Height:/ {h=$2} END {if (w && h) print w "x" h}'
}

# The screen's size before anything is drawn, from the kernel: the
# preferred mode (the first of modes) of each connected output, the tallest
# -- what the compositor shows at the login screen; SG_OUTPUT_SIZE where
# the compositor is headless (a remote session). WxH, or nothing.
sg_drm_size() {
    case "${SG_OUTPUT_SIZE:-}" in [0-9]*x[0-9]*) echo "$SG_OUTPUT_SIZE"; return 0 ;; esac
    for _ds_c in "${SG_DRM_SYSFS:-/sys/class/drm}"/card*-*; do
        [ "$(cat "$_ds_c/status" 2>/dev/null)" = connected ] || continue
        head -n 1 "$_ds_c/modes" 2>/dev/null
    done | awk -F'x' '$1 > 0 && $2 + 0 > h { h = $2 + 0; s = $0 } END { if (s) print s }'
}

# The login screen, Setup, the first-run setup, the lock screen and the
# consent prompt are Windows programs that do not scale themselves: Wine
# draws them at the process's display scale. Their accounts (the greeter's,
# the machine's) never pick one, so it is the screen's recommended one,
# handed to the program in its environment (SG_LOGPIXELS, which wine-sg
# 0882 takes over the registry's). Nothing is written and no Wine or X
# program runs before it (2026-10-05, release s9's boot test: wine reg run
# as the greeter's account left the login screen without its window, and
# so did measuring the screen with xwininfo first -- it started the
# compositor's on-demand Xwayland, which went away again (-terminate 10)
# while Wine, slow at boot, was still starting). The size comes from the
# kernel (sg_drm_size); "x": from the X server, where it is already up and
# stays (the lock screen's and the consent prompt's own Xwayland). At 100%
# nothing is set.
#   sg_ui_scale [x]        (exports SG_LOGPIXELS)
sg_ui_scale() {
    _us_size=$(sg_drm_size)
    if [ -z "$_us_size" ] && [ "${1:-}" = x ]; then
        _us_size=$(sg_x_size)
    fi
    [ -n "$_us_size" ] || return 0
    _us_pc=$(sg_scale_for "${_us_size%x*}" "${_us_size#*x}")
    [ "$_us_pc" -gt 100 ] || return 0
    SG_LOGPIXELS=$(( _us_pc * 96 / 100 ))
    export SG_LOGPIXELS
    return 0
}

# The user's display scale, for the lock screen (David 2026-10-06: "lock
# screen honours the user's chosen scale"): published as <user>.scale in the
# lock screen's drop directory (mode 1733, as the picture: sg-settingsctl
# lockscreen), which sg-lockd reads -- only the user's own file, 100-500 --
# and hands the lock UI (SG_LOCK_SCALE). Only a person's session publishes
# (not the machine's or the greeter's accounts).   sg_publish_scale PERCENT
sg_publish_scale() {
    _ps_dir=${SG_LOCKSCREEN_DIR:-/var/lib/stained-glass/lockscreen}
    case "${1:-}" in ''|*[!0-9]*) return 0 ;; esac
    [ "$(id -u)" -ge 1000 ] 2>/dev/null || [ -n "${SG_LOCKSCREEN_DIR:-}" ] || return 0
    [ -d "$_ps_dir" ] && [ -w "$_ps_dir" ] || return 0
    _ps_user=$(id -un 2>/dev/null) || return 0
    _ps_tmp="$_ps_dir/.$_ps_user.scale.$$"
    if printf '%s\n' "$1" > "$_ps_tmp" 2>/dev/null && chmod 644 "$_ps_tmp" 2>/dev/null; then
        mv -f "$_ps_tmp" "$_ps_dir/$_ps_user.scale" 2>/dev/null || rm -f "$_ps_tmp" 2>/dev/null
    else
        rm -f "$_ps_tmp" 2>/dev/null
    fi
    return 0
}

# The lock screen's display scale: the user's (SG_LOCK_SCALE, from sg-lockd),
# else the screen's recommended one (sg_ui_scale). Exports SG_LOGPIXELS, or
# leaves it unset at 100%.   sg_lock_scale [x]
sg_lock_scale() {
    unset SG_LOGPIXELS
    case "${SG_LOCK_SCALE:-}" in
    ''|*[!0-9]*) sg_ui_scale "${1:-}" ;;
    *)
        if [ "$SG_LOCK_SCALE" -gt 100 ] && [ "$SG_LOCK_SCALE" -le 500 ]; then
            SG_LOGPIXELS=$(( SG_LOCK_SCALE * 96 / 100 ))
            export SG_LOGPIXELS
        fi ;;
    esac
    return 0
}

# The taskbar's height at a scale, as explorer sizes it (wine-sg 0832: 40 px
# at 100%, in eighths of the scale).   sg_taskbar_h PERCENT
sg_taskbar_h() {
    _tb_dpi=$(( $1 * 96 / 100 ))   # LogPixels, a whole number, as explorer reads it
    _tb8=$(( (_tb_dpi * 8 + 48) / 96 ))
    [ "$_tb8" -gt 24 ] && _tb8=24
    echo $(( (40 * _tb8 + 4) / 8 ))
}

# Linux programs at the display scale, and at a new one while they run
# (David 2026-10-05: "it'd be nice if we could do so while logged in
# without having to restart the session"). Xwayland draws them 1:1 (the
# compositor's outputs stay at scale 1, or Xwayland -- Wine -- would be
# stretched), so each toolkit scales itself, told by an XSETTINGS manager
# (xsettingsd) that the session runs on its X display, and by the X
# resources:
#   - GTK 3 and 4: Gdk/SgFractionalScale, the scale itself, which our GTK
#     packages (sg-image gtk-scale) draw at -- 175% exactly; Debian's
#     GTK takes Gdk/WindowScalingFactor (whole steps: 2 from 150%) and
#     Gdk/UnscaledDPI (the text's DPI at that step, so the text is exactly
#     the scale). They follow a change at once. No GDK_SCALE: GTK ignores
#     XSETTINGS' scale when it is set.
#   - Qt 5 and 6: Xft/DPI, with QT_ENABLE_HIGHDPI_SCALING=1 and
#     QT_SCALE_FACTOR_ROUNDING_POLICY=PassThrough -- the exact scale
#     (1.75, not 2), followed at once. No QT_SCALE_FACTOR: Qt multiplies
#     it with the one Xft/DPI gives (Qt 6 drew 175% at 306%; Qt 5's text
#     was 175% twice).
#   - Xft and Xlib programs (xterm), Chromium and Electron: Xft.dpi in the
#     X resources (read at their start); the X pointer: Xcursor.size there,
#     Gtk/CursorThemeSize for GTK (24 px at 100%).
# At 100% the values are 96 DPI and scale 1, which is what everything
# assumes without them (a 1080p session as before).
#   sg_linux_scale_env PERCENT     (the session's start: environment and all)
#   sg_linux_scale PERCENT         (a change while the session runs)
SG_SCALE_ENV_GONE="GDK_SCALE GDK_DPI_SCALE QT_SCALE_FACTOR QT_AUTO_SCREEN_SCALE_FACTOR XCURSOR_SIZE"
sg_linux_scale_env() {
    # (an older session, or the user's systemd manager, may still carry
    # the fixed values that kept toolkits from following a change)
    # shellcheck disable=SC2086  # the names, split
    unset $SG_SCALE_ENV_GONE
    # shellcheck disable=SC2086
    systemctl --user unset-environment $SG_SCALE_ENV_GONE >/dev/null 2>&1 || true
    QT_ENABLE_HIGHDPI_SCALING=1
    QT_SCALE_FACTOR_ROUNDING_POLICY=PassThrough
    export QT_ENABLE_HIGHDPI_SCALING QT_SCALE_FACTOR_ROUNDING_POLICY
    _ls_names="QT_ENABLE_HIGHDPI_SCALING QT_SCALE_FACTOR_ROUNDING_POLICY"
    # shellcheck disable=SC2086  # the names, split
    systemctl --user import-environment $_ls_names >/dev/null 2>&1 || true
    if command -v dbus-update-activation-environment >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        dbus-update-activation-environment $_ls_names >/dev/null 2>&1 || true
    fi
    sg_linux_scale "${1:-100}"
}

# The values Linux programs are told at PERCENT, one per line, as
# xsettingsd reads them (DPI in 1024ths).   sg_xsettings_conf PERCENT
sg_xsettings_conf() {
    _xc_p=${1:-100}
    case "$_xc_p" in ''|*[!0-9]*) _xc_p=100 ;; esac
    [ "$_xc_p" -lt 100 ] && _xc_p=100
    _xc_dpi=$(( 96 * _xc_p / 100 ))           # LogPixels: 168 at 175%
    _xc_g=$(( (_xc_p + 50) / 100 ))           # GTK's whole step: 2 from 150%
    printf 'Xft/DPI %d\n' $(( _xc_dpi * 1024 ))
    printf 'Gdk/WindowScalingFactor %d\n' "$_xc_g"
    printf 'Gdk/UnscaledDPI %d\n' $(( _xc_dpi * 1024 / _xc_g ))
    printf 'Gtk/CursorThemeSize %d\n' $(( 24 * _xc_p / 100 ))
    # the scale as it is, for our GTK (sg-image gtk-scale: libgtk-3-0t64 and
    # libgtk-4-1 +sg): 1.75, not 2 -- in 1024ths; other GTKs ignore it
    [ "$_xc_p" -gt 100 ] && printf 'Gdk/SgFractionalScale %d\n' $(( 1024 * _xc_p / 100 ))
    return 0
}

# Linux programs at PERCENT, at once: the XSETTINGS manager of this X
# display ($DISPLAY) started or told (SIGHUP: it reads its file again and
# tells every program), and the X resources.   sg_linux_scale PERCENT
sg_linux_scale() {
    sg_publish_scale "${1:-100}"
    sg_x_resources "${1:-100}"
    command -v xsettingsd >/dev/null 2>&1 || return 0
    [ -n "${DISPLAY:-}" ] || return 0
    _xs_dir="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
    _xs_d=$(echo "$DISPLAY" | tr -c 'A-Za-z0-9.\n' '_')
    _xs_conf="$_xs_dir/sg-xsettings$_xs_d.conf"
    _xs_pid="$_xs_dir/sg-xsettings$_xs_d.pid"
    sg_xsettings_conf "${1:-100}" > "$_xs_conf.new" 2>/dev/null && mv -f "$_xs_conf.new" "$_xs_conf" || return 0
    _xs_p=$(cat "$_xs_pid" 2>/dev/null || :)   # (none yet: set -e callers go on)
    if [ -n "$_xs_p" ] && kill -0 "$_xs_p" 2>/dev/null && grep -q xsettingsd "/proc/$_xs_p/cmdline" 2>/dev/null; then
        kill -HUP "$_xs_p" 2>/dev/null && return 0
    fi
    # its own: ends with the X server; quiet (it logs every reload)
    xsettingsd -c "$_xs_conf" </dev/null >/dev/null 2>&1 &
    echo $! > "$_xs_pid" 2>/dev/null || :
    return 0
}

# The scale this X display's Linux programs were last told (the XSETTINGS
# manager's file), in percent; nothing when there is none.
sg_linux_scale_now() {
    _xn_d=$(echo "${DISPLAY:-}" | tr -c 'A-Za-z0-9.\n' '_')
    awk '$1 == "Xft/DPI" { printf "%d\n", $2 / 1024 * 100 / 96 + 0.5 }' \
        "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/sg-xsettings$_xn_d.conf" 2>/dev/null || :
}

# Qt windows at a new scale: Qt (5 and 6) takes a new Xft/DPI at once but
# leaves its windows their old size in pixels -- at 175% from 100% a
# 400x300 window stayed 400x300 pixels with 700x525 of contents. Each
# visible window of a Qt program on this display ($DISPLAY) is given its
# size times NEW/OLD (its frame follows, as for a program that resizes
# itself). GTK resizes its own; others (Xlib, Electron) take the new scale
# at their next start.
#   sg_qt_windows_rescale OLD NEW   (percent)
sg_qt_windows_rescale() {
    command -v xdotool >/dev/null 2>&1 || return 0
    [ "$1" -gt 0 ] 2>/dev/null && [ "$2" -gt 0 ] 2>/dev/null || return 0
    sleep "${SG_QT_RESCALE_WAIT:-1}"   # Qt's own change first
    for _qw in $(xdotool search --onlyvisible --name '' 2>/dev/null); do
        _qp=$(xdotool getwindowpid "$_qw" 2>/dev/null) || continue
        grep -q -E 'libQt[56]Gui\.so' "/proc/$_qp/maps" 2>/dev/null || continue
        _qg=$(xdotool getwindowgeometry "$_qw" 2>/dev/null | awk '/Geometry:/ { print $2 }')
        _qx=${_qg%x*} _qy=${_qg#*x}
        case "$_qx$_qy" in ''|*[!0-9]*) continue ;; esac
        if [ "$_qx" -le 20 ] || [ "$_qy" -le 20 ]; then continue; fi
        xdotool windowsize "$_qw" $(( (_qx * $2 + $1 / 2) / $1 )) $(( (_qy * $2 + $1 / 2) / $1 )) 2>/dev/null || :
    done
    return 0
}

# Xft.dpi and Xcursor.size in the X server's resources (xrdb): read by Xft
# and Xlib programs, Chromium and Electron, libXcursor, at their start;
# set while the session runs too (a new scale, the screen changed). Always
# set, 96 and 24 at 100%: Qt, told to scale (above), would otherwise take
# the panel's own DPI.
#   sg_x_resources PERCENT
sg_x_resources() {
    command -v xrdb >/dev/null 2>&1 || return 0
    _xr_p=${1:-100}
    case "$_xr_p" in ''|*[!0-9]*) _xr_p=100 ;; esac
    [ "$_xr_p" -lt 100 ] && _xr_p=100
    printf 'Xft.dpi: %s\nXcursor.size: %s\n' $(( 96 * _xr_p / 100 )) $(( 24 * _xr_p / 100 )) | xrdb -nocpp -merge 2>/dev/null || :
}

# root may draw on the session's X display: a Linux admin tool the user
# started through pkexec (GParted, Timeshift; polkit asked first) runs as
# root, and Xwayland admits only the user who started it -- "Authorization
# required ... cannot open display", and the tool never showed (qa5
# 2026-10-21). Root can read the session's memory and files anyway; this
# lets in no one else.   sg_x_admit_root
sg_x_admit_root() {
    [ -n "${DISPLAY:-}" ] || return 0
    command -v xhost >/dev/null 2>&1 || return 0
    [ "${SG_MUTANT:-}" = NO_ROOT_X ] && return 0
    xhost +SI:localuser:root >/dev/null 2>&1 || :
}

# XAUTHORITY names a file, as on every X desktop: Xwayland admits the
# session's user by who they are (SI:localuser), so there was no cookie and
# no XAUTHORITY -- and launchers that pass it on unquoted broke: Warzone
# 2100's (bwrap --ro-bind-try $XAUTHORITY $XAUTHORITY) ran "/sys" and the
# game never started (qa5 2026-10-21). An empty file holds no cookie; X
# programs still connect as the user. Kept when the session has one.
#   sg_x_authority
sg_x_authority() {
    [ -z "${XAUTHORITY:-}" ] || return 0
    [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ] || return 0
    [ "${SG_MUTANT:-}" = NO_XAUTHORITY ] && return 0
    _xa="$XDG_RUNTIME_DIR/sg-xauthority"
    [ -f "$_xa" ] || ( umask 077; : > "$_xa" ) 2>/dev/null || return 0
    XAUTHORITY=$_xa
    export XAUTHORITY
    systemctl --user import-environment XAUTHORITY >/dev/null 2>&1 || true
    if command -v dbus-update-activation-environment >/dev/null 2>&1; then
        dbus-update-activation-environment XAUTHORITY >/dev/null 2>&1 || true
    fi
}

# Folders a person's program made under the system prefix's ProgramData
# before wine-sg 10.0-618 lost the setgid bit they inherited (Wine's chmod
# after the create), so everything below them got that person's own group:
# Epic's launcher made Data\Update as bob, the elevated (SYSTEM) update could
# overwrite nothing there and stopped on EC-PRM, again on every try (qa4).
# They get ProgramData's group and setgid back -- what a folder made now
# gets. Modes are left alone: a file only its owner may read stays so.
#   sg_programdata_repair ROOT     (/ on a machine)
sg_programdata_repair() {
    _pd="${1%/}${SG_PROGRAMDATA:-/var/lib/stained-glass/prefix/drive_c/ProgramData}"
    [ -d "$_pd" ] && [ -g "$_pd" ] || return 0      # only a shared ProgramData
    _g=$(stat -c %G "$_pd") || return 0
    find "$_pd" -xdev -mindepth 1 ! -type l ! -group "$_g" -exec chgrp "$_g" {} + 2>/dev/null || :
    find "$_pd" -xdev -mindepth 1 -type d ! -perm -2000 -exec chmod g+s {} + 2>/dev/null || :
}

# Program folders whose installer set a DACL giving Users read and execute
# (CCleaner 7's Piriform folders) were left closed to everyone but their
# owner before wine-sg 10.0-640: such an ACE set only the group bits, and the
# group was the installer's own. People could not run the program or its
# uninstaller (qa4). Folders under Program Files that keep others out get
# read and traverse back -- what Windows gives Users there; write stays as it
# was, and nothing outside Program Files is touched.
#   sg_programfiles_repair ROOT     (/ on a machine)
sg_programfiles_repair() {
    _c="${1%/}${SG_PREFIX_C:-/var/lib/stained-glass/prefix/drive_c}"
    for _pf in "$_c/Program Files" "$_c/Program Files (x86)"; do
        [ -d "$_pf" ] || continue
        find "$_pf" -xdev -mindepth 1 -type d ! -perm -o=rx -exec chmod o+rx {} + 2>/dev/null || :
    done
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

# A person's registry hive file is closed to every other account, as
# Windows' NTUSER.DAT is (David 2026-11-23). The machine's server writes each
# user-<uid>.reg (and the prefix owner's user.reg) into the shared prefix; it
# made them with its umask, 0644, so anyone in the Wine group could read
# another person's HKCU. wine-sg 9100 makes them 0600 and closes an open one
# when it loads it; this closes them at every boot (and on an update, which
# runs sg-prefix-init) whatever server wrote them -- with the server's
# temporary copies of a hive (reg*.tmp, left by a crash) and the TEMP
# repair's. Only the machine account's (or root's) own regular files with a
# single link: never through a link, never a file a person planted (wine-sg
# 1475 moves those aside). Nothing else reads them: people reach their HKCU
# through the server. Safe while the server runs (a mode, not the content).
# The machine's hive, system.reg, too (wine-sg 9101): on Windows the
# SOFTWARE and SYSTEM hive files are SYSTEM's and Administrators', and people
# read HKLM through the registry, key by key as each key's descriptor
# allows. Root's readers (sg-firewall's daemon, sg-location, run by
# sg-admind and the package scripts) keep reading it; userdef.reg, the
# Default User template, stays readable (Windows' Default profile is).
# Echoes the files it closed.
#   sg_hive_private PREFIX
sg_hive_private() {
    [ "${SG_MUTANT_HIVE_OPEN:-}" = 1 ] && return 0
    _hp=$1
    [ -d "$_hp" ] || return 0
    _ho=$(stat -c %u "$_hp" 2>/dev/null) || return 0
    _hm=system.reg
    [ "${SG_MUTANT_SYSTEM_HIVE_OPEN:-}" = 1 ] && _hm=user-none.reg
    find "$_hp" -mindepth 1 -maxdepth 1 -type f -links 1 \( -uid "$_ho" -o -uid 0 \) -perm /077 \
        \( -name 'user-*.reg' -o -name user.reg -o -name 'reg*.tmp' -o -name '*.reg.sg-temp-repair' -o -name "$_hm" \) \
        -print -exec chmod go= {} + 2>/dev/null || :
    return 0
}

# The SYSTEM account's profile, C:\users\<system>, is SYSTEM's alone, as
# Windows' %SystemRoot%\System32\config\systemprofile is (David 2026-11-23).
# It was 2775 in the Wine group: every person could read SYSTEM's settings
# and files and put their own among them -- in AppData, which programs run as
# SYSTEM (services, the Store's and the first-run setup's installs) read and
# load from. Nothing of a person's needs it: an elevated program is the
# elevating person, with their profile (wine-sg 7601), runs as the SYSTEM
# account on disk and keeps its access; people's own hives name only their
# own profile; the one machine-wide setting that named it, Common Favorites,
# is each person's own Favorites (wine-sg 9102, as on Windows). The profile
# root is closed to group and others (no ACL entries), which closes all of
# it; SYSTEM's Temp is made so too (sg_system_temp_private). What another
# account put anywhere in it is moved aside where it is
# (.untrusted.<time>.<name>, said in the log), so no SYSTEM program finds it
# by its name; never removed. C:\users\SYSTEM, Wine's own empty cache
# folders for the SYSTEM name, likewise.
#   sg_system_profile_private DRIVE_C SYSTEM_USER
sg_system_profile_private() {
    [ "${SG_MUTANT_SYSTEM_PROFILE_OPEN:-}" = 1 ] && { sg_system_temp_private "$@"; return 0; }
    _pp="$1/users/$2"
    if [ ! -d "$_pp" ] || [ -L "$_pp" ]; then return 0; fi
    _pu=$(id -u "$2" 2>/dev/null) || return 0
    case "$(stat -c %u "$_pp" 2>/dev/null)" in "$_pu"|0) ;; *) return 0 ;; esac
    chmod go= "$_pp" 2>/dev/null || :
    command -v setfacl >/dev/null 2>&1 && setfacl -b "$_pp" 2>/dev/null
    if [ -d "$1/users/SYSTEM" ] && [ ! -L "$1/users/SYSTEM" ] && [ "$(stat -c %u "$1/users/SYSTEM")" = "$_pu" ]; then
        chmod go= "$1/users/SYSTEM" 2>/dev/null || :
        command -v setfacl >/dev/null 2>&1 && setfacl -b "$1/users/SYSTEM" 2>/dev/null
    fi
    # what other accounts put there: the top-most of theirs, wherever it is
    find "$_pp" -xdev -mindepth 1 -name '.untrusted.*' -prune -o \( ! -uid "$_pu" ! -uid 0 \) -prune -print 2>/dev/null |
    while IFS= read -r _px; do
        _pn=${_px##*/} _pw=$(stat -c %U "$_px" 2>/dev/null)
        if mv -f -- "$_px" "${_px%/*}/.untrusted.$(date +%s).$_pn" 2>/dev/null; then
            sg_log "moved aside '$_px' ($_pw's), another account's file in SYSTEM's profile"
        fi
    done
    sg_system_temp_private "$@"
    return 0
}

# The SYSTEM account's temporary folder in its profile,
# C:\users\<system>\AppData\Local\Temp -- the TEMP of what runs as SYSTEM
# (services, the Store's and the first-run setup's installs) -- is SYSTEM's
# alone, as Windows' is (David 2026-11-23). It was 2775 in the Wine group:
# every person could read what an installer unpacked there and put files
# where an installer was about to unpack and run them. An elevated program
# uses the elevating person's own TEMP (wine-sg 7601, as on Windows), so
# nothing hands files over through this folder. What other accounts put
# there before -- people's TEMP named it until sg-session 278 -- is moved
# aside (.untrusted.<time>.<name>, said in the log), so no SYSTEM program
# finds it by its name; never removed.
#   sg_system_temp_private DRIVE_C SYSTEM_USER
sg_system_temp_private() {
    [ "${SG_MUTANT_SYSTEM_TEMP_OPEN:-}" = 1 ] && return 0
    _tt="$1/users/$2/AppData/Local/Temp"
    if [ ! -d "$_tt" ] || [ -L "$_tt" ]; then return 0; fi
    chmod 0700 "$_tt" 2>/dev/null || :
    command -v setfacl >/dev/null 2>&1 && setfacl -b "$_tt" 2>/dev/null
    _tu=$(id -u "$2" 2>/dev/null) || return 0
    find "$_tt" -mindepth 1 -maxdepth 1 ! -uid "$_tu" ! -uid 0 ! -name '.untrusted.*' -print 2>/dev/null |
    while IFS= read -r _tx; do
        _tn=${_tx##*/} _tw=$(stat -c %U "$_tx" 2>/dev/null)
        if mv -f -- "$_tx" "$_tt/.untrusted.$(date +%s).$_tn" 2>/dev/null; then
            sg_log "moved aside '$_tx' ($_tw's), another account's file in SYSTEM's Temp"
        fi
    done
    return 0
}

# A user's TEMP and TMP name the user's own profile (multi-user debt D15,
# security). Images built from 2026-11-16 (sg-image 54d96f0, the seed prefix
# built as root with USER=sgsystem) seeded userdef.reg with the SYSTEM
# account's literal C:\users\sgsystem\AppData\Local\Temp: sg-prefix-init
# turned only paths under "id -un" (root) into %USERPROFILE%. Every account
# made since inherited it, so the users and elevated (SYSTEM) programs shared
# one group-writable temporary folder -- another user could put files where an
# elevated installer was about to unpack and run them, and read each other's
# temporary files. In the Default User template (userdef.reg) and each user's
# hive (user-<uid>.reg), a TEMP or TMP in [Environment] that names another
# account's profile becomes %USERPROFILE%\AppData\Local\Temp, as Windows' own
# default is; a user's own literal path is kept (Windows writes those too),
# and so is anything that is not a profile path. Only while no wineserver has
# the hives (sg-prefix-init, before it starts Wine): the server writes its own
# copy back over an edited file. Echoes the files it changed.
#   sg_hive_temp_repair PREFIX
sg_hive_temp_repair() {
    for _h in "$1"/userdef.reg "$1"/user-*.reg; do
        [ -f "$_h" ] || continue
        case "$_h" in
        */userdef.reg) _owner= ;;
        *)  _uid=${_h##*/user-}; _uid=${_uid%.reg}
            case "$_uid" in ''|*[!0-9]*) continue ;; esac
            _owner=$(getent passwd "$_uid" 2>/dev/null | cut -d: -f1)
            # an account that no longer exists: its hive is nobody's to repair
            [ -n "$_owner" ] || continue ;;
        esac
        _new="$_h.sg-temp-repair"
        # the hive's content: nobody else's to read, even for a moment (9100)
        ( umask 077
        awk -v owner="$_owner" '
            /^\[/ { env = ($0 ~ /^\[Environment\]( |$)/) }
            env && /^"(TEMP|TMP)"=(str\(2\):)?"[Cc]:\\\\[Uu][Ss][Ee][Rr][Ss]\\\\/ {
                name = $0
                sub(/^"(TEMP|TMP)"=(str\(2\):)?"[Cc]:\\\\[Uu][Ss][Ee][Rr][Ss]\\\\/, "", name)
                sub(/[\\"].*$/, "", name)
                # SG_MUTANT_TEMP_REPAIR_OFF (the gate mutant): nothing is repaired
                if (ENVIRON["SG_MUTANT_TEMP_REPAIR_OFF"] == "" && (owner == "" || tolower(name) != tolower(owner))) {
                    v = $0; sub(/=.*$/, "", v)
                    print v "=str(2):\"%USERPROFILE%\\\\AppData\\\\Local\\\\Temp\""
                    changed = 1
                    next
                }
            }
            { print }
            END { exit changed ? 0 : 3 }' "$_h" > "$_new" ) && _rc=0 || _rc=$?
        # (set -e callers: a hive with nothing to repair, awk's 3, ended the loop)
        if [ "$_rc" = 0 ]; then
            # the same file (owner, mode, ACL): its content replaced
            cat "$_new" > "$_h" && echo "$_h"
        fi
        rm -f "$_new"
    done
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

# Wine Mono's support MSI (winemono-support.msi: the .NET Framework's
# registry -- NDP\v2.0/v3.0/v3.5/v4, .NETFramework\AssemblyFolders -- and its
# files in windows\Microsoft.NET) is installed into a prefix once: Wine runs
# it again only when Wine Mono's version number grows, and our builds of it
# (sg1, sg2...) keep 9.4.0. So what a newer build's MSI adds never reached a
# prefix made before it: machines installed before Mono sg9 had no
# AssemblyFolders\v3.5, and Meedio's and MeediOS's installers took .NET 3.5
# for missing and ran Microsoft's 3.5 setup, which only says to use "Turn
# Windows features on or off" (David 2026-10-05). Re-applied from the
# package's MSI (REINSTALL=ALL; REINSTALLMODE v: from this package, not the
# cached copy) when it differs from the one applied last (its SHA-256 in
# STATEDIR); nothing otherwise.
#   sg_mono_support_refresh STATEDIR [MSI]
sg_mono_support_refresh() {
    _st=$1
    _msi=${2:-}
    if [ -z "$_msi" ]; then
        for _m in "${SG_WINE_DIR:-/opt/wine-sg}"/share/wine/mono/wine-mono-*/support/winemono-support.msi \
                  /usr/share/wine/mono/wine-mono-*/support/winemono-support.msi; do
            [ -f "$_m" ] && _msi=$_m
        done
    fi
    [ -n "$_msi" ] && [ -f "$_msi" ] || return 0
    _sum=$(sha256sum < "$_msi" | cut -d' ' -f1)
    [ "$(cat "$_st/mono-support.sha256" 2>/dev/null)" != "$_sum" ] || return 0
    _wmsi="Z:$(printf '%s' "$_msi" | tr '/' '\134')"
    if wine msiexec /i "$_wmsi" REINSTALL=ALL REINSTALLMODE=vomus /qn >/dev/null 2>&1; then
        mkdir -p "$_st"
        printf '%s\n' "$_sum" > "$_st/mono-support.sha256"
        sg_log "Wine Mono's support package applied ($_msi)"
    else
        sg_log "WARNING: could not apply Wine Mono's support package $_msi"
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
# And no one but the owner and the group may write there ("others"), once.
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
    # what elevated installers put there before wine-sg 10.0-488 (5956) was
    # 0777/0666: every account's to change, as "others" (it is SYSTEM's
    # group's, not the Wine group's). Others lose write, once.
    [ -e "$_st/program-files-others-1" ] && return 0
    if [ "${SG_MUTANT_PF_OTHERS:-}" != 1 ]; then
        for _d in "Program Files" "Program Files (x86)"; do
            [ -d "$_c/$_d" ] || continue
            find "$_c/$_d" ! -type l -perm -o=w -print0 2>/dev/null | xargs -0 -r chmod o-w 2>/dev/null || :
        done
    fi
    : > "$_st/program-files-others-1" 2>/dev/null || :
    return 0
}

# The all-users Start menu (ProgramData\Microsoft\Windows\Start Menu, its
# StartUp folder too) and the Public Desktop are the administrators': on
# Windows the users may open them, not change them. ProgramData is shared with
# the users (sg_programdata_shared) and Public is the Wine group's, so every
# account could rewrite a shortcut another account opens, or put a program in
# everyone's StartUp (qa4 2026-10-22: NVDA's and OneDrive's shortcuts, 0777
# from before wine-sg 10.0-488, and the group's anyway). The group loses write
# there -- its entries and the defaults, so what an installer makes later too;
# SYSTEM keeps its own entry (sg_system_access) -- and so do others. Every
# boot: the trees are small.
#   sg_shared_shortcuts_protected DRIVE_C GROUP
sg_shared_shortcuts_protected() {
    _c=$1 _grp=$2
    command -v setfacl >/dev/null 2>&1 || return 0
    [ "${SG_MUTANT_SHORTCUTS_SHARED:-}" = 1 ] && return 0
    for _d in "ProgramData/Microsoft/Windows/Start Menu" "users/Public/Desktop"; do
        [ -d "$_c/$_d" ] || continue
        find "$_c/$_d" -type d ! -type l -exec setfacl -m g::r-x -m d:g::r-x -m "g:$_grp:r-x" -m "d:g:$_grp:r-x" {} + 2>/dev/null || :
        find "$_c/$_d" -type f -exec setfacl -m g::r-X -m "g:$_grp:r-X" {} + 2>/dev/null || :
        find "$_c/$_d" ! -type l -perm -o=w -print0 2>/dev/null | xargs -0 -r chmod o-w 2>/dev/null || :
    done
    return 0
}

# The Public folders keep a hidden, system desktop.ini, as Windows' do, so an
# installer's delete-at-reboot of its own shortcut's folder never takes the
# folder itself: wineboot's PendingFileRenameOperations removes a directory
# that is empty, and ours were (Foxit's uninstall queued users\Public\Desktop,
# qa5 2026-10-22). Wine reads the attributes from user.DOSATTRIB. Every boot;
# one already there is left as it is.
#   sg_public_desktop_ini DRIVE_C
sg_public_desktop_ini() {
    [ "${SG_MUTANT_PUBLIC_NO_INI:-}" = 1 ] && return 0
    for _d in Desktop Documents Downloads Music Pictures Videos; do
        _f="$1/users/Public/$_d/desktop.ini"
        if [ ! -d "$1/users/Public/$_d" ] || [ -L "$1/users/Public/$_d" ]; then continue; fi
        if [ -e "$_f" ] || [ -L "$_f" ]; then continue; fi
        printf '[.ShellClassInfo]\r\n' > "$_f" 2>/dev/null || continue
        chmod 644 "$_f" 2>/dev/null || :
        # not hidden (no user xattrs there) it would show on every desktop
        python3 -c 'import os,sys; os.setxattr(sys.argv[1], "user.DOSATTRIB", b"0x6")' "$_f" 2>/dev/null || rm -f "$_f"
    done
    return 0
}

# The shared folders' own entries are the system's (2026-10-07, found
# looking at debt D13). Every person is in the Wine group, and the folders were
# group-writable without the sticky bit: anyone could rename the prefix
# away and put their own in its place, replace dosdevices\c: (the SYSTEM
# account's services would then load "C:\windows" from a folder of theirs),
# delete or replace the registry files and markers, or plant a stamp that
# skips a protection, or another person's user-<uid>.reg before that person
# first signs in. Now, at every boot as the machine account:
#  - ROOT, the prefix, the state folder and .local/.local/share are sticky:
#    people keep making their own files there (Wine's clients need to write
#    in the prefix), none renames or deletes what is not theirs;
#  - dosdevices is the system's alone (people's network drives are their own,
#    under /run/stained-glass-net, not here);
#  - what a person (uid >= 1000) put among the system's files there is moved
#    aside (never the folder owner's own), said in the log -- except their own Wine process agent socket
#    (.sg-procagent.<uid>) and their own session-<uid>.env in the state folder;
#  - the system's own files there, and its desktop entries and settings under
#    .local and .config, are not the group's to change.
# wine-sg 1475 also refuses a registry file the server did not write.
# sg_shared_state_hardened ROOT PREFIX STATE
sg_shared_state_hardened() {
    [ "${SG_MUTANT_SHARED_STATE_OPEN:-}" = 1 ] && return 0
    _hr=$1 _hp=$2 _hs=$3
    _ho=$(stat -c %u "$_hr" 2>/dev/null) || return 0
    for _hd in "$_hr" "$_hp" "$_hs" "$_hr/.local" "$_hr/.local/share"; do
        if [ -d "$_hd" ] && [ ! -L "$_hd" ]; then chmod +t,o-w "$_hd" 2>/dev/null || :; fi
    done
    if [ -d "$_hp/dosdevices" ] && [ ! -L "$_hp/dosdevices" ]; then
        chmod g-w,o-w "$_hp/dosdevices" 2>/dev/null || :
    fi
    # what people put there: top level of ROOT and the prefix, the drive
    # letters, and anywhere in the state folder (stamps live in subfolders)
    {
        find "$_hr" "$_hp" -mindepth 1 -maxdepth 1 -uid +999 ! -user "$_ho" -print 2>/dev/null
        [ -d "$_hp/dosdevices" ] && find "$_hp/dosdevices" -mindepth 1 -maxdepth 1 -uid +999 ! -user "$_ho" -print 2>/dev/null
        [ -d "$_hs" ] && find "$_hs" -mindepth 1 -uid +999 ! -user "$_ho" -print 2>/dev/null
    } | while IFS= read -r _hx; do
        _hn=${_hx##*/} _hu=$(stat -c %u "$_hx" 2>/dev/null) || continue
        case "$_hn" in
        .untrusted.*) continue ;;
        ".sg-procagent.$_hu") if [ "${_hx%/*}" = "$_hp" ] && [ -S "$_hx" ]; then continue; fi ;;
        "session-$_hu.env") if [ "${_hx%/*}" = "$_hs" ] && [ -f "$_hx" ] && [ ! -L "$_hx" ]; then continue; fi ;;
        esac
        # moved, not removed: a folder of theirs may not be ours to empty
        if mv -f -- "$_hx" "${_hx%/*}/.untrusted.$(date +%s).$_hn" 2>/dev/null; then
            sg_log "WARNING: moved aside '$_hx' (uid $_hu), which a person put among the system's files"
        else
            sg_log "WARNING: could not move aside '$_hx' (uid $_hu)"
        fi
    done
    for _hd in "$_hr" "$_hp" "$_hs"; do
        if [ -d "$_hd" ]; then
            find "$_hd" -mindepth 1 -maxdepth 1 -user "$_ho" -type f -perm -g=w -exec chmod g-w {} + 2>/dev/null || :
        fi
    done
    if [ -d "$_hs" ]; then
        find "$_hs" -mindepth 1 -user "$_ho" ! -type l -perm -g=w -exec chmod g-w {} + 2>/dev/null || :
    fi
    for _hd in "$_hr/.local/share" "$_hr/.config"; do
        if [ -d "$_hd" ]; then
            find "$_hd" -mindepth 1 -user "$_ho" ! -type l -perm -g=w ! -path "$_hr/.local/share/keyrings*" \
                -exec chmod g-w {} + 2>/dev/null || :
        fi
    done
    return 0
}

# C:\windows is the system's, as on Windows, where Users may read and run
# what is there and change none of it. The prefix is made and updated by the
# SYSTEM account with the Wine group's write (umask 002), so every user could
# replace a DLL in system32 -- one that SYSTEM's services, the elevated
# programs and every other user's programs then load -- or put one beside
# explorer.exe or regedit.exe in C:\windows itself. The group loses write in
# the whole tree: everything there now, and (a default ACL on its folders)
# what the system makes there later. Users still write where Windows lets
# them: Temp, Tasks (AT jobs written by the programs that make them),
# Installer (Wine's msiexec runs in the user's own process: a per-user
# install caches its package there), Logs, and system32\catroot and
# catroot2 (Wine's crypt32 adds an installer's catalogs in the user's
# process) -- sticky, so each user's files are their own, what a user makes
# there not the group's to change, and the system's files there not theirs
# to change. The print spool is left as it is: Wine's winspool adds the
# CUPS printers, PPDs into spool\drivers, in each user's session, and the
# spool files are the user's (set_machine_settings). SystemTemp is SYSTEM's
# alone. Wine's record of the
# prefix's version (.update-timestamp) is the system's too: a person's process
# must not take a prefix update for done. Every boot (a cheap find: what a
# Wine update or an elevated installer made group-writable since); the
# folders' default ACLs once (STATE stamp).
#   sg_windows_protected DRIVE_C GROUP STATEDIR
sg_windows_protected() {
    _c=$1 _grp=$2 _st=$3
    _w="$_c/windows"
    [ -d "$_w" ] || return 0
    [ "${SG_MUTANT_WINDOWS_WRITABLE:-}" = 1 ] && return 0
    for _d in temp tasks Installer logs system32/catroot system32/catroot2; do
        [ -d "$_w/$_d" ] || mkdir -p "$_w/$_d" 2>/dev/null || continue
        chgrp "$_grp" "$_w/$_d" 2>/dev/null || :
        chmod 3775 "$_w/$_d" 2>/dev/null || :
        if command -v setfacl >/dev/null 2>&1; then setfacl -m g::rwx -m d:g::r-x "$_w/$_d" 2>/dev/null || :; fi
    done
    find "$_w" -xdev \( -path "$_w/temp" -o -path "$_w/tasks" -o -path "$_w/Installer" -o -path "$_w/logs" \
        -o -path "$_w/system32/catroot" -o -path "$_w/system32/catroot2" \
        -o -path "$_w/SystemTemp" -o -path "$_w/system32/spool" \) -prune -o \
        ! -type l -perm -g=w -print0 2>/dev/null | xargs -0 -r chmod g-w 2>/dev/null || :
    _ts="${_c%/*}/.update-timestamp"
    if [ -f "$_ts" ]; then chmod g-w "$_ts" 2>/dev/null || :; fi
    [ -e "$_st/windows-protected-1" ] && return 0
    if command -v setfacl >/dev/null 2>&1; then
        find "$_w" -xdev \( -path "$_w/temp" -o -path "$_w/tasks" -o -path "$_w/Installer" -o -path "$_w/logs" \
            -o -path "$_w/system32/catroot" -o -path "$_w/system32/catroot2" \
            -o -path "$_w/SystemTemp" -o -path "$_w/system32/spool" \) -prune -o \
            -type d -print0 2>/dev/null | xargs -0 -r setfacl -m d:g::r-x 2>/dev/null || :
    fi
    _owner=$(stat -c %u "$_w" 2>/dev/null)
    # what a person put in C:\windows before this (theirs to change still):
    # said once, for an administrator to look at -- not removed
    _alien=$(find "$_w" -xdev \( -path "$_w/temp" -o -path "$_w/tasks" -o -path "$_w/Installer" -o -path "$_w/logs" \
        -o -path "$_w/system32/catroot" -o -path "$_w/system32/catroot2" -o -path "$_w/SystemTemp" \
        -o -path "$_w/system32/spool" \) -prune -o ! -user "${_owner:-0}" ! -user 0 -print 2>/dev/null | head -5 | tr '\n' ' ')
    [ -z "$_alien" ] || sg_log "WARNING: files in C:\\windows that a person owns (they can still change them): $_alien"
    for _d in temp tasks Installer logs system32/catroot system32/catroot2; do
        if [ ! -d "$_w/$_d" ] || [ -z "$_owner" ]; then continue; fi
        find "$_w/$_d" -xdev -mindepth 1 -user "$_owner" ! -type l -perm -g=w -print0 2>/dev/null |
            xargs -0 -r chmod g-w 2>/dev/null || :
    done
    : > "$_st/windows-protected-1" 2>/dev/null || :
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
    # GTK programs that draw their own title bar (GNOME apps) name the shadow
    # around their window in _GTK_FRAME_EXTENTS only for a window manager
    # listing it -- without it GTK 3 drew the shadow's room as a blank margin
    # inside the frame, and neither GTK 3 nor 4 had edges to size the window
    # by. Their Wine frame keeps the shadow outside itself and sizes them by
    # its own edge (wine-sg 0813, 0842).
    [ "$_rc" -eq 0 ] && sg_x11_add_supported _GTK_FRAME_EXTENTS 2>/dev/null
    # the taskbar's height at the display scale (SG_SCALE, sg-run-explorer's)
    _bar=${SG_TASKBAR_H:-$(sg_taskbar_h "${SG_SCALE:-100}")}
    xprop -root -f _NET_WORKAREA 32c -set _NET_WORKAREA "0, 0, $_w, $((_h - _bar))" 2>/dev/null &&
        sg_log "work area for Linux programs: ${_w}x$((_h - _bar))"
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

# Remote support (ADR 0010 pattern A): a remote-support tool installed as a
# Windows service -- a VNC server, AnyDesk -- sees the console, the lock and
# sign-in screens included, and types into them, as on Windows. sg-compositor
# grants that capture and input injection on its privileged socket to root and
# to the SYSTEM account's processes in these control groups only (-R): the
# Windows services and the per-session helpers they start
# (CreateProcessAsUser, wine-sg 9625). Not to the lock screen, a consent
# prompt or an elevated program, though they are the SYSTEM account too.
SG_SUPPORT_CGROUPS="${SG_SUPPORT_CGROUPS:-/system.slice/sg-wineserver.service}"
# Does $SG_COMPOSITOR take -R? One from before it would refuse to start.
sg_compositor_takes_support() {
    "$SG_COMPOSITOR" -h 2>/dev/null | grep -q -- ' -R '
}
# Elevated programs run as the SYSTEM account too, in sg-brokerd's control
# group of their own (i0635): sg-compositor refuses them the privileged
# socket -- nothing of theirs shows while the session is locked -- and the
# lock's commands (-E). On Windows an elevated program never reaches the
# secure desktop either.
SG_ELEVATED_CGROUPS="${SG_ELEVATED_CGROUPS:-/system.slice/sg-brokerd.service/elevated}"
sg_compositor_takes_elevated() {
    "$SG_COMPOSITOR" -h 2>/dev/null | grep -q -- ' -E '
}

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
# Is the machine's own wineserver (sg-wineserver.service) running? Then the
# prefix's server is that one, for good: never waited for, never stopped by a
# prefix tool (sg-prefix-init's exit stopped it -- every Windows program in
# every session ended at each update)
sg_machine_wineserver_up() {
    command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet sg-wineserver.service 2>/dev/null
}

# Wait for the prefix's wineserver to be done -- unless it is the machine's
# own, sg-wineserver.service, which runs for good: what it was given is live
# in it already, and waiting for it to exit hung every update that brought
# new defaults (sg-prefix-init, run again by a package, waited the 10 minutes
# systemd gives it -- David 2026-10-03, "I think your build is hung"). Its
# own: bounded (a service that never ends keeps any other one up too).
#   sg_wineserver_wait [SECONDS]
sg_wineserver_wait() {
    sg_machine_wineserver_up && return 0
    timeout "${1:-120}" wineserver -w 2>/dev/null || true
}

# Can the installed Wine still talk to the running machine wineserver? Not
# after an update that changed the server's protocol: every Windows program
# started then fails ("version mismatch") until the server is restarted. Only
# then must an update restart it -- restarting it ends every Windows program
# in every session. 0: it must be restarted; 1: it is fine (or none runs).
#   sg_wineserver_stale
sg_wineserver_stale() {
    sg_machine_wineserver_up || return 1
    _out=$(timeout 60 runuser -u "${SG_SYSTEM_USER:-sgsystem}" -- sh -c \
        '. /usr/lib/stained-glass/sg-common.sh; sg_wine_env; WINEDEBUG=-all wine cmd /c exit' 2>&1)
    case "$_out" in *"version mismatch"*) return 0 ;; esac
    return 1
}

# A wineserver another account started for the shared prefix while the
# machine's was down (an update stopped it; a running program reconnected in
# that moment) holds the prefix's server directory: the machine's could not
# start beside it -- "status 2" for good -- and that session was left on a
# server without the Windows system's services. Ended here (as root, before
# the machine's starts): its programs were on it alone.
#   sg_wineserver_clear_strays
sg_wineserver_clear_strays() {
    _px=${SG_PREFIX:-/var/lib/stained-glass/prefix}
    [ -d "$_px" ] || return 0
    _dir="/tmp/.wine-sg-$(stat -c %D "$_px")-$(printf %x "$(stat -c %i "$_px")")"
    for _sig in TERM KILL; do
        _found=0
        for _p in $(pgrep -x wineserver); do
            [ "$(stat -c %U "/proc/$_p" 2>/dev/null)" = "${SG_SYSTEM_USER:-sgsystem}" ] && continue
            case "$(readlink "/proc/$_p/cwd" 2>/dev/null)" in
                "$_dir"/*) kill "-$_sig" "$_p" 2>/dev/null && _found=1
                           sg_log "ended a stray wineserver of $(stat -c %U "/proc/$_p" 2>/dev/null) on the machine's prefix ($_p)" ;;
            esac
        done
        [ "$_found" = 1 ] || return 0
        sleep 2
    done
}

sg_keep_running() {
    _kname=$(printf '%.15s' "$1")
    shift
    # a zombie (dead, not yet reaped) is not running: CI's containers reap late
    pgrep -r R,S,D,T,t,I,P,W -u "$(id -u)" -x "$_kname" >/dev/null 2>&1 && return 0
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

# Voice typing's hold-to-talk listener is wanted unless it marked itself idle:
# with hold-to-talk off "sg-dictate64.exe /background" ends at once and leaves
# $XDG_RUNTIME_DIR/sg-dictate-idle (sg-shell 0.1.0-113) -- the helper keeper
# started it again ten times at every sign-in, as if it had crashed. The
# listener deletes the mark when it runs (Speech Recognition starts it when
# hold-to-talk is turned on).
sg_dictate_wanted() {
    [ ! -e "${XDG_RUNTIME_DIR:-/nonexistent}/sg-dictate-idle" ]
}


# sg_procagent_supervise AGENT PREFIX SESSION_PID: keep the user's process agent
# (sg-procagent, ADR 0014) running for as long as the session's process lives.
# The machine's wineserver (SYSTEM) reaches this user's threads only through it:
# with the agent gone a .NET program's next garbage collection could not stop its
# threads (wine-sg 7843 now fails that instead of waiting forever, but the program
# is still better served by an agent that comes back). Restarted after a second;
# one that keeps dying at once is retried less and less often (up to a minute)
# rather than in a tight loop. Run it in the background; it ends, and stops the
# agent, when SESSION_PID is gone (greetd's teardown of the process group ends
# both sooner).
sg_procagent_supervise() {
    _pa_agent=$1; _pa_prefix=$2; _pa_session=$3; _pa_delay=1
    while kill -0 "$_pa_session" 2>/dev/null; do
        _pa_start=$(date +%s)
        "$_pa_agent" "$_pa_prefix" </dev/null &
        _pa_pid=$!
        sg_log "sg-procagent running (pid $_pa_pid) for $(id -un)"
        while kill -0 "$_pa_pid" 2>/dev/null && kill -0 "$_pa_session" 2>/dev/null; do sleep 2; done
        if ! kill -0 "$_pa_session" 2>/dev/null; then
            kill "$_pa_pid" 2>/dev/null || true
            wait "$_pa_pid" 2>/dev/null || true
            break
        fi
        _pa_rc=0; wait "$_pa_pid" 2>/dev/null || _pa_rc=$?
        [ "${SG_MUTANT_PROCAGENT_NO_RESTART:-}" = 1 ] && break
        if [ $(($(date +%s) - _pa_start)) -lt 10 ]; then
            _pa_delay=$((_pa_delay * 2)); [ "$_pa_delay" -le 60 ] || _pa_delay=60
        else _pa_delay=1; fi
        sg_log "sg-procagent (pid $_pa_pid) ended with $_pa_rc; restarting in ${_pa_delay}s"
        sleep "$_pa_delay"
    done
}
