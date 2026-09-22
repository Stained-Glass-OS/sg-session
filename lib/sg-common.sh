#!/bin/sh
# Shared settings and helpers for the Stained Glass session.
# POSIX sh: this runs early, before anything interesting is guaranteed present.

SG_ROOT="${SG_ROOT:-/var/lib/stained-glass}"
SG_PREFIX="${SG_PREFIX:-$SG_ROOT/prefix}"
SG_STATE="${SG_STATE:-$SG_ROOT/state}"
SG_LOG_DIR="${SG_LOG_DIR:-/var/log/stained-glass}"

# MULTIUSER-DEBT: one prefix, one owner. See docs/multiuser-debt.md (D1).
SG_USER="${SG_USER:-sguser}"

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

# Display path: x11 (cage + XWayland + winex11 virtual desktop) or wayland
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

# These are inherited by the compositor's child, so they must be exported: the
# session crosses a process boundary between sg-session-start and sg-run-explorer.
export SG_ROOT SG_PREFIX SG_STATE SG_LOG_DIR SG_USER
export SG_DESKTOP_W SG_DESKTOP_H SG_DISPLAY_PATH SG_WINE_DIR
export SG_WINE_GROUP SG_SYSTEM_PREFIX

sg_log() { echo "[sg-session] $*" >&2; }
sg_die() { echo "[sg-session] FATAL: $*" >&2; exit 1; }

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
    # Never let Wine pop the Mono/Gecko installer dialogs in an unattended boot.
    WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"
    export WINEDLLOVERRIDES
}
