#!/bin/sh
# shellcheck disable=SC2015  # pass/fail one-liners: both only print
# sg-common.sh's sg_programfiles_repair: a program folder closed to everyone
# but its owner (CCleaner 7's Piriform, before wine-sg 10.0-640) gets others'
# read and traverse back; files and write bits are left alone, and nothing
# outside Program Files changes. SG_MUTANT=NOX86: Program Files (x86) skipped.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
C="$T/var/lib/stained-glass/prefix/drive_c"
mkdir -p "$C/Program Files/Piriform/CCleaner 7" "$C/Program Files (x86)/Shut/In" "$C/users/bob/Private"
echo x > "$C/Program Files/Piriform/CCleaner 7/secret.ini"; chmod 600 "$C/Program Files/Piriform/CCleaner 7/secret.ini"
chmod 770 "$C/Program Files/Piriform" "$C/Program Files/Piriform/CCleaner 7" "$C/Program Files (x86)/Shut" "$C/Program Files (x86)/Shut/In"
chmod 700 "$C/users/bob/Private"
sh -c '. "$1/lib/sg-common.sh" >/dev/null 2>&1
       if [ "${SG_MUTANT:-}" = NOX86 ]; then
           find "$2/var/lib/stained-glass/prefix/drive_c/Program Files" -mindepth 1 -type d ! -perm -o=rx -exec chmod o+rx {} +
       else sg_programfiles_repair "$2"; fi' sh "$HERE" "$T"
m() { stat -c %a "$1"; }
[ "$(m "$C/Program Files/Piriform")" = 775 ] && [ "$(m "$C/Program Files/Piriform/CCleaner 7")" = 775 ] \
    && pass "a program folder closed to others is readable and traversable again (CCleaner 7)" || fail "Program Files: $(m "$C/Program Files/Piriform") $(m "$C/Program Files/Piriform/CCleaner 7")"
[ "$(m "$C/Program Files (x86)/Shut")" = 775 ] && [ "$(m "$C/Program Files (x86)/Shut/In")" = 775 ] \
    && pass "and under Program Files (x86)" || fail "x86: $(m "$C/Program Files (x86)/Shut") $(m "$C/Program Files (x86)/Shut/In")"
[ "$(m "$C/Program Files/Piriform/CCleaner 7/secret.ini")" = 600 ] && pass "files keep their modes" || fail "file: $(m "$C/Program Files/Piriform/CCleaner 7/secret.ini")"
[ "$(m "$C/users/bob/Private")" = 700 ] && pass "nothing outside Program Files changes" || fail "outside: $(m "$C/users/bob/Private")"
sh -c '. "$1/lib/sg-common.sh" >/dev/null 2>&1; sg_programfiles_repair "$2/nowhere"' sh "$HERE" "$T" && pass "no prefix: nothing to do" || fail "no prefix failed"
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
