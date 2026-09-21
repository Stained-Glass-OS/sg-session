#!/bin/sh
# Shared settings and helpers for the Stained Glass session.
# POSIX sh: this runs early, before anything interesting is guaranteed present.

SG_ROOT="${SG_ROOT:-/var/lib/stained-glass}"
SG_PREFIX="${SG_PREFIX:-$SG_ROOT/prefix}"
SG_STATE="${SG_STATE:-$SG_ROOT/state}"
SG_LOG_DIR="${SG_LOG_DIR:-/var/log/stained-glass}"

# MULTIUSER-DEBT: one prefix, one owner. See docs/multiuser-debt.md (D1).
SG_USER="${SG_USER:-sguser}"

# Virtual desktop geometry. The compositor gives us a fixed-size output in
# Phase 0, so the Wine desktop matches it exactly and nothing has to resize.
SG_DESKTOP_W="${SG_DESKTOP_W:-1280}"
SG_DESKTOP_H="${SG_DESKTOP_H:-800}"

# Display path: x11 (cage + XWayland + winex11 virtual desktop) or wayland
# (winewayland). See docs/decisions/0003 in the stained-glass repo.
SG_DISPLAY_PATH="${SG_DISPLAY_PATH:-x11}"

# These are inherited by the compositor's child, so they must be exported: the
# session crosses a process boundary between sg-session-start and sg-run-explorer.
export SG_ROOT SG_PREFIX SG_STATE SG_LOG_DIR SG_USER
export SG_DESKTOP_W SG_DESKTOP_H SG_DISPLAY_PATH

sg_log() { echo "[sg-session] $*" >&2; }
sg_die() { echo "[sg-session] FATAL: $*" >&2; exit 1; }

# Wine, always pointed at the system prefix. Every caller goes through this so
# there is exactly one place that decides which prefix is "the" prefix.
sg_wine_env() {
    WINEPREFIX="$SG_PREFIX"
    export WINEPREFIX
    # Phase 0 is a 64-bit prefix. 32-bit apps need i386 multiarch in the image;
    # see ADR 0002 for why new-WoW64 is not available from packaged Wine.
    WINEARCH="${WINEARCH:-win64}"
    export WINEARCH
    # Keep Wine's own chatter out of the boot path unless someone asks for it.
    WINEDEBUG="${WINEDEBUG:--all}"
    export WINEDEBUG
    # Never let Wine pop the Mono/Gecko installer dialogs in an unattended boot.
    WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"
    export WINEDLLOVERRIDES
}
