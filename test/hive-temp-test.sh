#!/bin/sh
# sg_hive_temp_repair (lib/sg-common.sh, sg-prefix-init at boot): a user's TEMP and TMP name the
# user's own profile (multi-user debt D15, security). Images from 2026-11-16 seeded userdef.reg
# with the SYSTEM account's literal C:\users\sgsystem\AppData\Local\Temp, so every account and
# every elevated program shared one group-writable temporary folder (qa4, 2026-11-22).
# Checks: the Default User template's and a user's TEMP/TMP that name another account become
# %USERPROFILE%\AppData\Local\Temp; the user's own literal path stays; values outside
# [Environment] stay; a hive with nothing to repair is not rewritten (same bytes, same mtime);
# the file keeps its mode. And sg-prefix-init's seed replaces paths under USER as well as id -un.
#   sh test/hive-temp-test.sh            SG_MUTANT_TEMP_REPAIR_OFF=1: the mutant (must FAIL)
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/sg-hivetemp.XXXXXX")
trap 'rm -rf "$T"' EXIT INT TERM
ME=$(id -un); UID_=$(id -u)
# user-0.reg below is the hive with nothing to repair. Run as root (the package build in CI), the
# user's own hive would be user-0.reg too and one overwrote the other: the user's hive is then
# another account's that exists (any non-root one: the function looks the owner up by uid).
if [ "$UID_" = 0 ]; then
    UID_=$(getent passwd | awk -F: '$3 > 0 { print $3; exit }')
    ME=$(getent passwd "$UID_" | cut -d: -f1)
fi
cat > "$T/userdef.reg" <<'R'
WINE REGISTRY Version 2

[Environment] 1794899258
#time=1dd7662547f0a9c
"TEMP"="C:\\users\\sgsystem\\AppData\\Local\\Temp"
"TMP"="C:\\users\\sgsystem\\AppData\\Local\\Temp"

[Software\\Some App] 1794899258
"TEMP"="C:\\users\\sgsystem\\cache"
R
printf 'WINE REGISTRY Version 2\n\n[Environment] 1\n"OneDrive"=str(2):"C:\\\\users\\\\%s\\\\OneDrive"\n"TEMP"="C:\\\\users\\\\%s\\\\AppData\\\\Local\\\\Temp"\n"TMP"=str(2):"C:\\\\users\\\\sgsystem\\\\AppData\\\\Local\\\\Temp"\n' "$ME" "$ME" > "$T/user-$UID_.reg"
# a hive that is already right: untouched
printf 'WINE REGISTRY Version 2\n\n[Environment] 1\n"TEMP"=str(2):"%%USERPROFILE%%\\\\AppData\\\\Local\\\\Temp"\n' > "$T/user-0.reg"
chmod 0644 "$T"/*.reg
touch -d '2020-01-01' "$T/user-0.reg"
before0=$(cksum < "$T/user-0.reg"); m0=$(stat -c %Y "$T/user-0.reg")
# set -e, as sg-prefix-init runs it: a hive with nothing to repair (user-0, first in the list)
# must not end the loop before the others
out=$(sh -ec '. "$1/lib/sg-common.sh"; sg_hive_temp_repair "$2"' x "$HERE" "$T" 2>&1)
want='"TEMP"=str(2):"%USERPROFILE%\\AppData\\Local\\Temp"'
wtmp='"TMP"=str(2):"%USERPROFILE%\\AppData\\Local\\Temp"'
grep -qxF "$want" "$T/userdef.reg" && grep -qxF "$wtmp" "$T/userdef.reg" \
    && pass "the Default User template's TEMP and TMP name %USERPROFILE%" || fail "userdef.reg: $(grep -E '^"(TEMP|TMP)"' "$T/userdef.reg" | tr '\n' ' ')"
grep -qF '"TEMP"="C:\\users\\sgsystem\\cache"' "$T/userdef.reg" && pass "a TEMP outside [Environment] is left alone" \
    || fail "a value outside [Environment] changed"
grep -qF "\"TEMP\"=\"C:\\\\users\\\\$ME\\\\AppData\\\\Local\\\\Temp\"" "$T/user-$UID_.reg" && pass "a user's own literal TEMP is kept" \
    || fail "the user's own TEMP changed: $(grep '^"TEMP"' "$T/user-$UID_.reg")"
grep -qxF "$wtmp" "$T/user-$UID_.reg" && pass "a user's TMP that named sgsystem's profile is the user's own" \
    || fail "user TMP: $(grep '^"TMP"' "$T/user-$UID_.reg")"
grep -qF 'OneDrive' "$T/user-$UID_.reg" && pass "the rest of the user's Environment is kept" || fail "OneDrive value lost"
[ "$(cksum < "$T/user-0.reg")" = "$before0" ] && [ "$(stat -c %Y "$T/user-0.reg")" = "$m0" ] \
    && pass "a hive with nothing to repair is not rewritten" || fail "user-0.reg was rewritten"
[ "$(stat -c %a "$T/userdef.reg")" = 644 ] && pass "the repaired file keeps its mode" || fail "mode now $(stat -c %a "$T/userdef.reg")"
case "$out" in *userdef.reg*) pass "it names the files it changed" ;; *) fail "output: '$out'" ;; esac
# idempotent
out2=$(sh -c '. "$1/lib/sg-common.sh"; sg_hive_temp_repair "$2"' x "$HERE" "$T" 2>&1)
[ -z "$out2" ] && pass "a second run changes nothing" || fail "second run: '$out2'"
# the seed step replaces USER's profile too (the image build: root with USER=sgsystem)
grep -q '_me=${USER:-$(id -un)}' "$HERE/bin/sg-prefix-init" && pass "sg-prefix-init's seed names the profile after USER" \
    || fail "sg-prefix-init's seed still replaces only id -un"
grep -q 'sg_hive_temp_repair "$SG_PREFIX"' "$HERE/bin/sg-prefix-init" && pass "sg-prefix-init repairs the hives at boot" \
    || fail "sg-prefix-init does not call sg_hive_temp_repair"
exit $RC
