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
    for _d in "${SG_WINE_DIR:-/opt/wine-sg}/share/wine/$1" "/usr/share/wine/$1"; do
        for _f in "$_d"/*.msi; do [ -f "$_f" ] && return 0; done
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
