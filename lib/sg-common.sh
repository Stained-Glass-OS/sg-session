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
