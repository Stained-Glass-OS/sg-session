#!/bin/sh
# The lock screen at the user's display scale (David 2026-10-06: "lock screen
# honours the user's chosen scale"). The session publishes its scale
# (sg-common.sh sg_publish_scale, run by sg_linux_scale at sign-in and on a
# change) as <user>.scale in the lock screen's drop directory, beside the
# lock picture; sg-lockd, as the machine account, trusts it no more than the
# picture and hands it to the lock UI (SG_LOCK_SCALE), which draws at it
# (sg_lock_scale; test/display-scale-test.sh checks that part):
#   - published 150: sg-lockd stages SCALE 150 for the user
#   - a symlink under the user's name, a number out of range, junk: SCALE 0
#     (the lock UI then takes the screen's recommended scale)
#   - none published: SCALE 0
# Mutant: SG_MUTANT_LOCK_SCALE_IGNORED (greeter/sg-lockd.c): SCALE 0 always.
# No Wine, no X: cc only.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
CC="${CC:-cc}"
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
command -v "$CC" >/dev/null || { echo "SKIP: no C compiler"; exit 77; }
T=$(mktemp -d "${TMPDIR:-/tmp}/sg-lockscale.XXXXXX")
trap 'rm -rf "$T"' EXIT INT TERM
"$CC" -O2 -o "$T/lockd" "$HERE/greeter/sg-lockd.c" 2>"$T/cc.log" || { echo "FAIL  sg-lockd did not build"; cat "$T/cc.log"; exit 1; }
"$CC" -O2 -DSG_MUTANT_LOCK_SCALE_IGNORED -o "$T/lockd-mut" "$HERE/greeter/sg-lockd.c" 2>/dev/null || { echo "FAIL  the mutant did not build"; exit 1; }
mkdir -m 1733 "$T/drop"
export SG_LOCKSCREEN_DIR="$T/drop" TMPDIR="$T"
USER_NAME=$(id -un)
scale() { "${1:-$T/lockd}" --stage-picture "$USER_NAME" 2>/dev/null | sed -n 's/^SCALE //p'; }

[ "$(scale)" = 0 ] && pass "nothing published: SCALE 0 (the screen's recommended scale)" || fail "nothing published: SCALE $(scale)"
# as the session publishes it (sg_linux_scale -> sg_publish_scale)
env -i PATH=/usr/bin:/bin HOME="$T" SG_LOCKSCREEN_DIR="$T/drop" sh -c ". \"$HERE/lib/sg-common.sh\" >/dev/null 2>&1; sg_publish_scale 150"
[ "$(stat -c %u "$T/drop/$USER_NAME.scale" 2>/dev/null)" = "$(id -u)" ] && [ "$(scale)" = 150 ] \
    && pass "the session's 150% published as the user's own file, staged: SCALE 150" \
    || fail "published 150: file owner $(stat -c %u "$T/drop/$USER_NAME.scale" 2>/dev/null), SCALE $(scale)"
[ "$(scale "$T/lockd-mut")" = 0 ] && pass "MUTANT LOCK_SCALE_IGNORED caught (SCALE 0)" || fail "MUTANT LOCK_SCALE_IGNORED not caught"
cp "$T/drop/$USER_NAME.scale" "$T/keep"
rm -f "$T/drop/$USER_NAME.scale"; ln -s "$T/keep" "$T/drop/$USER_NAME.scale"
[ "$(scale)" = 0 ] && pass "a symlink under the user's name is not followed" || fail "a symlink was followed: SCALE $(scale)"
rm -f "$T/drop/$USER_NAME.scale"; echo 900 > "$T/drop/$USER_NAME.scale"
[ "$(scale)" = 0 ] && pass "900% (out of range) is not taken" || fail "900: SCALE $(scale)"
echo "rm -rf /" > "$T/drop/$USER_NAME.scale"
[ "$(scale)" = 0 ] && pass "junk is not taken" || fail "junk: SCALE $(scale)"
env -i PATH=/usr/bin:/bin HOME="$T" SG_LOCKSCREEN_DIR="$T/drop" sh -c ". \"$HERE/lib/sg-common.sh\" >/dev/null 2>&1; sg_publish_scale 125"
[ "$(scale)" = 125 ] && pass "a new scale replaces it: SCALE 125" || fail "125: SCALE $(scale)"
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
