#!/bin/sh
# shellcheck disable=SC2015  # pass/fail one-liners: both only print
# sg-common.sh's sg_programdata_repair: folders under the prefix's ProgramData
# that lost their setgid bit (wine-sg before 10.0-618; Epic's Data\Update as
# bob, so the elevated update could not overwrite it) get the shared group and
# setgid back; modes are kept (a private file stays private); nothing outside
# ProgramData is touched. SG_MUTANT=NOGROUP: setgid only.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
# a second group of the tester's stands in for sgwine
G=$(id -Gn | tr ' ' '\n' | grep -v -x "$(id -gn)" | head -1)
[ -n "$G" ] || { echo "SKIP: needs a second group"; exit 77; }
PD="$T/var/lib/stained-glass/prefix/drive_c/ProgramData"
mkdir -p "$PD/Epic/Data/Update/Meta" "$T/var/lib/stained-glass/prefix/drive_c/users/bob"
chgrp -R "$G" "$PD"; chmod 2775 "$PD" "$PD/Epic" "$PD/Epic/Data"
chgrp "$(id -gn)" "$PD/Epic/Data/Update/Meta"; chmod 775 "$PD/Epic/Data/Update" "$PD/Epic/Data/Update/Meta"   # lost setgid
echo x > "$PD/Epic/Data/Update/Meta/resume"; chgrp "$(id -gn)" "$PD/Epic/Data/Update/Meta/resume"; chmod 664 "$PD/Epic/Data/Update/Meta/resume"
echo s > "$PD/Epic/Data/Update/Meta/private"; chgrp "$(id -gn)" "$PD/Epic/Data/Update/Meta/private"; chmod 600 "$PD/Epic/Data/Update/Meta/private"
echo u > "$T/var/lib/stained-glass/prefix/drive_c/users/bob/own"; chmod 600 "$T/var/lib/stained-glass/prefix/drive_c/users/bob/own"
sh -c '. "$1/lib/sg-common.sh" >/dev/null 2>&1
       if [ "${SG_MUTANT:-}" = NOGROUP ]; then
           find "$2/var/lib/stained-glass/prefix/drive_c/ProgramData" -mindepth 1 -type d ! -perm -2000 -exec chmod g+s {} +
       else sg_programdata_repair "$2"; fi' sh "$HERE" "$T"
st() { stat -c '%G %a' "$1"; }
[ "$(st "$PD/Epic/Data/Update")" = "$G 2775" ] && [ "$(st "$PD/Epic/Data/Update/Meta")" = "$G 2775" ] \
    && pass "a folder that lost setgid gets the shared group and setgid back" || fail "folders: $(st "$PD/Epic/Data/Update") / $(st "$PD/Epic/Data/Update/Meta")"
[ "$(st "$PD/Epic/Data/Update/Meta/resume")" = "$G 664" ] && pass "a file in it gets the shared group (SYSTEM may overwrite it)" \
    || fail "file: $(st "$PD/Epic/Data/Update/Meta/resume")"
[ "$(st "$PD/Epic/Data/Update/Meta/private")" = "$G 600" ] && pass "a private file keeps its mode (600)" || fail "private: $(st "$PD/Epic/Data/Update/Meta/private")"
[ "$(stat -c %G "$T/var/lib/stained-glass/prefix/drive_c/users/bob/own")" = "$(id -gn)" ] && pass "nothing outside ProgramData is touched" || fail "outside touched"
sh -c '. "$1/lib/sg-common.sh" >/dev/null 2>&1; sg_programdata_repair "$2/nowhere"' sh "$HERE" "$T" && pass "no prefix: nothing to do" || fail "no prefix failed"
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
