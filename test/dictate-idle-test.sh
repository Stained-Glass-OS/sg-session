#!/bin/sh
# The helper keeper leaves voice typing's listener alone while it marked
# itself idle (hold-to-talk off: $XDG_RUNTIME_DIR/sg-dictate-idle, sg-shell
# 0.1.0-113) -- it was started again ten times at every sign-in -- and keeps
# it running otherwise. lib/sg-common.sh's sg_dictate_wanted, and the keeper
# calling it.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
RC=0; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
# shellcheck source=/dev/null
. "$HERE/lib/sg-common.sh"
export XDG_RUNTIME_DIR="$T"
sg_dictate_wanted && pass "no mark: the listener is kept running" || fail "no mark, yet not wanted"
: > "$T/sg-dictate-idle"
sg_dictate_wanted && fail "marked idle, yet started again" || pass "marked idle (hold-to-talk off): left alone"
rm -f "$T/sg-dictate-idle"
sg_dictate_wanted && pass "mark taken away (the listener runs): kept running again" || fail "not wanted after the mark went"
grep -q 'sg_helper sg-dictate64.exe' "$HERE/lib/sg-run-explorer" && \
    grep -B1 'sg_helper sg-dictate64.exe' "$HERE/lib/sg-run-explorer" | grep -q 'sg_dictate_wanted' \
    && pass "the keeper asks before starting it" || fail "the keeper starts the listener without asking"
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
