#!/bin/sh
# sg_apply_policy de-tattoos: a policy value removed from the policy set is
# deleted from the machine registry on the next apply, while values still in
# force stay. Only the values policy set are touched -- not the branch, not a
# program's own state. Needs wine-sg (skips otherwise).
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
WINE="${SG_WINE_DIR:-/opt/wine-sg}/bin/wine"
[ -x "$WINE" ] || { echo "SKIP: no wine at $WINE"; exit 0; }
[ -x "$HERE/build/sg-polimport" ] || { echo "SKIP: sg-polimport not built"; exit 0; }

T=$(mktemp -d /var/tmp/sg-detat.XXXXXX)
trap '"${SG_WINE_DIR:-/opt/wine-sg}/bin/wineserver" -k 2>/dev/null; rm -rf "$T"' EXIT INT TERM
export SG_WINE_DIR="${SG_WINE_DIR:-/opt/wine-sg}" SG_SYSTEM_PREFIX=1
export SG_PREFIX="$T/prefix" SG_STATE="$T/state" SG_POLICY_DIR="$T/policy.d" SG_ROOT="$T"
export SG_LIBEXEC="$HERE/build" WINEDEBUG=-all
mkdir -p "$SG_POLICY_DIR" "$SG_STATE"
# shellcheck source=lib/sg-common.sh
. "$HERE/lib/sg-common.sh"
sg_log() { :; }
sg_wine_env
wine wineboot -i >/dev/null 2>&1; wineserver -w

RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
val() { wine reg query "$1" /v "$2" 2>/dev/null | tr -d '\r' | grep -c "    $2    "; }

# A program's own (non-policy) value under the same tree, to prove it survives.
wine reg add 'HKLM\Software\Policies\SGDetat' /v Keep /t REG_SZ /d mine /f >/dev/null 2>&1

printf '%s\n' 'Windows Registry Editor Version 5.00' '' \
  '[HKEY_LOCAL_MACHINE\Software\Policies\SGDetat]' '"A"=dword:00000001' '"B"=dword:00000002' > "$SG_POLICY_DIR/10-t.reg"
sg_apply_policy
[ "$(val 'HKLM\Software\Policies\SGDetat' A)" = 1 ] && [ "$(val 'HKLM\Software\Policies\SGDetat' B)" = 1 ] \
    && pass "a policy's values are applied" || fail "policy values not applied"

# Drop B from the policy; A stays.
printf '%s\n' 'Windows Registry Editor Version 5.00' '' \
  '[HKEY_LOCAL_MACHINE\Software\Policies\SGDetat]' '"A"=dword:00000001' > "$SG_POLICY_DIR/10-t.reg"
sg_apply_policy
[ "$(val 'HKLM\Software\Policies\SGDetat' B)" = 0 ] && pass "a value removed from the policy is de-tattooed" \
    || fail "B still present after removal"
[ "$(val 'HKLM\Software\Policies\SGDetat' A)" = 1 ] && pass "a value still in force stays" || fail "A wrongly removed"
[ "$(val 'HKLM\Software\Policies\SGDetat' Keep)" = 1 ] && pass "a program's own value under the branch is untouched" \
    || fail "the non-policy value was removed"

# Remove the policy file entirely; A goes too.
rm -f "$SG_POLICY_DIR/10-t.reg"
sg_apply_policy
[ "$(val 'HKLM\Software\Policies\SGDetat' A)" = 0 ] && pass "dropping the policy file removes its last value" \
    || fail "A survived the policy file being removed"
[ "$(val 'HKLM\Software\Policies\SGDetat' Keep)" = 1 ] && pass "and still leaves the program's own value" \
    || fail "Keep removed"

echo
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
