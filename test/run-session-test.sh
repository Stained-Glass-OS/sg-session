#!/bin/sh
# sg-session's own gate.
#
# Stands up a complete session on this machine -- headless compositor, system
# prefix, Wine explorer as the shell -- and lets sg-session-check judge it.
# No VM and no root required, so it runs in CI and on a developer box alike.
#
# This is deliberately the same check the image boot gate runs in the guest.
# If this passes and the boot gate fails, the fault is in the image, not here.
#
# That claim is only true if this harness stands up what the image does, and for
# a while it did not: the image runs a machine-level wineserver before greetd
# and this ran only the session. A bug that needs both -- two explorers sharing
# one prefix -- passed here and failed in the guest, and cost several 25-minute
# image rebuilds to find. So the machine-level server is started here too.
# SG_TEST_MACHINE_SERVER=0 turns it off to isolate a session-only fault.
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
    if [ -n "${MACHINE_PID:-}" ]; then
        kill "$MACHINE_PID" 2>/dev/null || true
    fi
    # The session user here is us, so this only ever reaps our own processes.
    # Named explicitly: a bare `wineserver` resolves to the distribution's, which
    # looks for the server where stock Wine puts it -- not where wine-sg puts a
    # system prefix's (/tmp/.wine-sg-*) -- finds nothing, and silently kills
    # nothing. That left seven Wine processes behind every run.
    WINEPREFIX="$SG_PREFIX" "${SG_WINE_DIR:-/opt/wine-sg}/bin/wineserver" -k 2>/dev/null || true
    # Then anything still standing, however it got reparented.
    if [ -n "${RUN:-}" ]; then
        systemctl --user kill --signal=SIGKILL "$SLICE" 2>/dev/null || true
        systemctl --user stop "$SLICE" 2>/dev/null || true
    fi
    reap_stale_wine "$SG_PREFIX" >/dev/null 2>&1 || true
    exit "$rc"
}

# Stale Wine processes from an earlier run are the single most misleading
# thing that can happen here. A persistent wineserver left over from a
# previous session keeps serving the old prefix, so a freshly built one is
# never used; and `wineserver -w`, which sg-prefix-init calls, waits for a
# server that is never going to exit. Both present as a hang with no error,
# and both have cost real debugging time.
#
# Only processes holding *this* prefix are killed, identified by their own
# environment rather than by name, so a developer's unrelated Wine session is
# left alone. Anything else still running is reported, because it is the first
# thing to suspect if this run then behaves strangely.
# Containment. The session and the machine-level server run inside one
# transient systemd slice, and cleanup stops the slice. On a real machine the
# session lives in a logind scope and systemd kills the whole cgroup at logout;
# without the equivalent here, every run leaked a process tree, because the
# compositor waits for its child on SIGTERM, the child (a Wine process) blocks
# on a server that is already gone, and everything is reparented to init where
# no PID the harness holds can reach it. cgroup membership survives
# reparenting, so a slice catches all of it.
#
# Where there is no user systemd (some CI containers), RUN is empty and the
# name-agnostic reaper below is the fallback.
SLICE="sg-gate-$$.slice"
if systemd-run --user --scope --quiet --slice="$SLICE" -- true 2>/dev/null; then
    RUN="systemd-run --user --scope --quiet --slice=$SLICE --"
else
    RUN=""
fi

reap_stale_wine() {
    _pfx=$1 _killed=0
    # Every process of ours, not a list of names: a list is always missing
    # something (plugplay.exe, svchost.exe, start.exe, the compositor...), and
    # the ones it misses are exactly the ones that then pile up.
    for _p in $(pgrep -u "$(id -u)" 2>/dev/null); do
        _env=$( { tr '\0' '\n' < "/proc/$_p/environ"; } 2>/dev/null | sed -n 's/^WINEPREFIX=//p')
        [ "$_env" = "$_pfx" ] || continue
        kill -9 "$_p" 2>/dev/null && _killed=$((_killed + 1))
    done
    [ "$_killed" -gt 0 ] && echo "== reaped $_killed stale Wine process(es) holding $_pfx"
    _other=$(pgrep -u "$(id -u)" -x wineserver 2>/dev/null | wc -l)
    [ "$_other" -gt 0 ] && echo "== note: $_other other wineserver(s) still running for this user"
    return 0
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
# Keep the session's output on this harness's log rather than the journal.
SG_LOG_TO_JOURNAL=0
export SG_LOG_TO_JOURNAL
mkdir -p "$SG_ROOT" "$SG_LOG_DIR"

: "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"
export XDG_RUNTIME_DIR
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true

# Headless wlroots, software rendering: no GPU, no seat, no DRM master needed.
WLR_BACKENDS=headless
WLR_LIBINPUT_NO_DEVICES=1
WLR_RENDERER=pixman
export WLR_BACKENDS WLR_LIBINPUT_NO_DEVICES WLR_RENDERER

# The compositor comes from sg-common.sh: SG_COMPOSITOR if set (sg-compositor's
# own gate sets it to its build tree), else sg-compositor, else cage.
. "$STAGE/usr/lib/stained-glass/sg-common.sh" 2>/dev/null || true
echo "== compositor: ${SG_COMPOSITOR:-cage}"
# Put wine-sg on PATH before looking for `wine`: it lives in /opt/wine-sg/bin,
# where only sg_wine_env adds it. Checked first, a machine with wine-sg and no
# distribution Wine -- CI, since it stopped installing stock Wine -- skipped the
# gate as "wine not installed".
command -v sg_wine_env >/dev/null 2>&1 && sg_wine_env
for tool in "${SG_COMPOSITOR:-cage}" Xwayland wine xwininfo; do
    command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool not installed"; exit 77; }
done

reap_stale_wine "$SG_PREFIX"

echo "== initializing prefix (this takes a minute on first run)"
"$SG_BIN/sg-prefix-init"

trap cleanup EXIT INT TERM

# The Windows system itself, before any login -- as the image does it. Two
# explorers in one prefix is a real configuration, so the gate has to see it.
if [ "${SG_TEST_MACHINE_SERVER:-1}" = "1" ]; then
    echo "== starting the machine-level wineserver"
    $RUN "$SG_BIN/sg-wineserver" >"$SG_LOG_DIR/machine.log" 2>&1 &
    MACHINE_PID=$!
    SG_SERVICES_TIMEOUT=60 $RUN "$SG_BIN/sg-services-start" >"$SG_LOG_DIR/services.log" 2>&1 \
        || echo "   (services.exe did not report ready; continuing)"
fi

echo "== starting session (display path: $SG_DISPLAY_PATH)"
$RUN "$SG_BIN/sg-session-start" >"$SG_LOG_DIR/session.log" 2>&1 &
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
    if [ -f "$SG_LOG_DIR/machine.log" ]; then
        echo
        echo "== machine-level server log =="
        sed 's/^/   /' "$SG_LOG_DIR/machine.log" 2>/dev/null | tail -20
    fi
    echo
    echo "== explorers running (more than one means the session shares with session 0) =="
    pgrep -u "$(id -u)" -a explorer.exe 2>/dev/null | sed 's/^/   /' || echo "   (none)"
fi

echo
echo "== sg-session gate: $([ "$RC" -eq 0 ] && echo PASS || echo FAIL) (rc=$RC)"
exit "$RC"
