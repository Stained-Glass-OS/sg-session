#!/bin/sh
# sg-session's own gate.
#
# Stands up a complete session on this machine -- headless compositor, system
# prefix, Wine explorer as the shell -- and lets sg-session-check judge it.
# No VM and no root required, so it runs in CI and on a developer box alike.
#
# This is deliberately the same check the image boot gate runs in the guest.
# If this passes and the boot gate fails, the fault is in the image, not here.
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP="$HERE/test/tmp"
STAGE="$TMP/root"

TIMEOUT_SESSION="${SG_TEST_TIMEOUT:-300}"

# shellcheck disable=SC2317  # invoked via trap
cleanup() {
    rc=$?
    if [ -n "${SESSION_PID:-}" ]; then
        kill "$SESSION_PID" 2>/dev/null || true
    fi
    # The session user here is us, so this only ever reaps our own processes.
    WINEPREFIX="$SG_PREFIX" wineserver -k 2>/dev/null || true
    pkill -f "cage -- $STAGE" 2>/dev/null || true
    exit "$rc"
}

echo "== staging sg-session into $STAGE"
rm -rf "$TMP"
mkdir -p "$STAGE"
make -C "$HERE" install DESTDIR="$STAGE" PREFIX=/usr >/dev/null

# Point every path at the scratch tree. SG_USER is left unset on purpose: the
# prefix init skips the chown when the user does not exist, which is what we
# want when running as an ordinary developer account.
SG_LIB="$STAGE/usr/lib/stained-glass"
SG_BIN="$STAGE/usr/bin"
SG_ROOT="$TMP/state"
SG_PREFIX="$SG_ROOT/prefix"
SG_STATE="$SG_ROOT/state"
SG_LOG_DIR="$TMP/log"
SG_DISPLAY_PATH="${SG_DISPLAY_PATH:-x11}"
SG_USER="__sg_no_such_user__"
export SG_LIB SG_BIN SG_ROOT SG_PREFIX SG_STATE SG_LOG_DIR SG_DISPLAY_PATH SG_USER
mkdir -p "$SG_ROOT" "$SG_LOG_DIR"

: "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"
export XDG_RUNTIME_DIR
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true

# Headless wlroots, software rendering: no GPU, no seat, no DRM master needed.
WLR_BACKENDS=headless
WLR_LIBINPUT_NO_DEVICES=1
WLR_RENDERER=pixman
export WLR_BACKENDS WLR_LIBINPUT_NO_DEVICES WLR_RENDERER

for tool in cage Xwayland wine xwininfo; do
    command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool not installed"; exit 77; }
done

echo "== initializing prefix (this takes a minute on first run)"
"$SG_BIN/sg-prefix-init"

trap cleanup EXIT INT TERM

echo "== starting session (display path: $SG_DISPLAY_PATH)"
"$SG_BIN/sg-session-start" >"$SG_LOG_DIR/session.log" 2>&1 &
SESSION_PID=$!

echo "== running sg-session-check"
set +e
SG_CHECK_TIMEOUT="$TIMEOUT_SESSION" "$SG_BIN/sg-session-check"
RC=$?
set -e

if [ "$RC" -ne 0 ]; then
    echo
    echo "== session log =="
    sed 's/^/   /' "$SG_LOG_DIR/session.log" 2>/dev/null | tail -40
fi

echo
echo "== sg-session gate: $([ "$RC" -eq 0 ] && echo PASS || echo FAIL) (rc=$RC)"
exit "$RC"
