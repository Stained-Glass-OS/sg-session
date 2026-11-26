#!/bin/sh
# sg-common.sh's sg_basic_display_env: with no DRM device once udev has
# handled every device, every compositor started from here goes to the Basic
# Display Adapter at once (SG_BASIC_DISPLAY=1) -- asked first, wlroots waited
# ten seconds for a GPU before each fallback: the first-run setup, the login
# screen and every sign-in sat ten seconds on a blank screen (boot2,
# 2026-11-25, install on OVMF + ramfb). While udev has events queued, or is
# not running, wlroots asks as before (udev's queue is waited out first, up
# to SG_UDEV_WAIT seconds: next34's 10 s wait was a login screen started
# while the queue drained); a GPU's card never gets it; a value
# set by hand wins. Stand-in sysfs and /run/udev.
#   --mutant: the helper never sets it (must FAIL)
# shellcheck disable=SC2015  # pass || fail
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RC=0
COMMON="$HERE/lib/sg-common.sh"
if [ "${1:-}" = --mutant ]; then
    sed 's/^    export SG_BASIC_DISPLAY=1$/    :/' "$COMMON" > "$T/common.sh"; COMMON="$T/common.sh"
    cmp -s "$COMMON" "$HERE/lib/sg-common.sh" && { echo "mutant not applied"; exit 1; }
fi
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
value() {   # DRM UDEV [preset]: what the compositor would get
    env -i PATH="$PATH" SG_UDEV_WAIT="${WAIT:-1}" SG_DRM_SYSFS="$T/$1" SG_UDEV_RUN="$T/$2" ${3:+SG_BASIC_DISPLAY=$3} \
        sh -c ". \"$COMMON\" >/dev/null 2>&1; echo \"\${SG_BASIC_DISPLAY:-unset}\""
}
mkdir -p "$T/nodrm/card0-Virtual-1" "$T/gpu/card0" "$T/gpu/card0-DP-1" "$T/settled" "$T/busy" "$T/noudev"
: > "$T/nodrm/version"; : > "$T/settled/control"; : > "$T/busy/control"; : > "$T/busy/queue"
[ "$(value nodrm settled)" = 1 ] && pass "no DRM device, udev settled: the Basic Display Adapter at once" || fail "no DRM device, udev settled: $(value nodrm settled)"
[ "$(value nodrm busy)" = unset ] && pass "udev still has events queued (a driver may be loading): wlroots waits for a GPU" || fail "udev busy: $(value nodrm busy)"
mkdir -p "$T/drain" "$T/late/card0-Virtual-1" "$T/lateudev"; : > "$T/drain/control"; : > "$T/drain/queue"
( sleep 0.6; rm -f "$T/drain/queue" ) &
[ "$(WAIT=5 value nodrm drain)" = 1 ] && pass "udev's queue drains within the wait, still no DRM device: the Basic Display Adapter at once (next34)" || fail "queue drained: $(WAIT=5 value nodrm drain)"
wait
: > "$T/lateudev/control"; : > "$T/lateudev/queue"
( sleep 0.6; mkdir -p "$T/late/card0"; rm -f "$T/lateudev/queue" ) &
[ "$(WAIT=5 value late lateudev)" = unset ] && pass "a card that appears while udev drains: the GPU is used" || fail "late card: $(WAIT=5 value late lateudev)"
wait
[ "$(value nodrm noudev)" = unset ] && pass "udev not running: wlroots decides" || fail "no udev: $(value nodrm noudev)"
[ "$(value gpu settled)" = unset ] && pass "a GPU's card (card0): the GPU is used" || fail "with a card: $(value gpu settled)"
[ "$(value nodrm settled 0)" = 0 ] && pass "a value set by hand wins" || fail "preset: $(value nodrm settled 0)"
exit $RC
