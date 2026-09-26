#!/bin/sh
# lib/sg-oobe-user: what the first-run setup's choices put in a user's HKCU,
# with a stand-in `wine` that keeps the imported .reg -- no Wine needed.
# The microphone switch names voice typing, so On turns voice typing on
# (Speech\Enabled); Off leaves it off. Region, layouts, privacy, the stamp.
# shellcheck disable=SC2015,SC2016  # pass never fails; the stand-in prints its own $2
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
RC=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; RC=1; }
T=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-oobe-user.XXXXXX")
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin"
cat > "$T/bin/wine" <<EOS
#!/bin/sh
# reg query: nothing applied yet; reg import FILE: keep it
[ "\$1 \$2" = "reg import" ] && cp "\$3" "$T/imported.reg"
exit 0
EOS
printf '#!/bin/sh\necho "$2"\n' > "$T/bin/winepath"
chmod +x "$T/bin/wine" "$T/bin/winepath"
run() {
    rm -f "$T/imported.reg"
    printf 'STAMP=%s\nREGION_LOCALE=en-GB\nREGION_GEO=242\nKEYBOARD_IDS=00000809\nMICROPHONE=%s\nLOCATION=0\nADVERTISING=0\nTAILORED=0\n' "$1" "$2" > "$T/oobe.conf"
    env PATH="$T/bin:$PATH" SG_LIB="$HERE/lib" SG_WINE_DIR=/nonexistent SG_OOBE_CONF="$T/oobe.conf" \
        XDG_RUNTIME_DIR="$T" sh "$HERE/lib/sg-oobe-user" 2>/dev/null
    tr -d '\r' < "$T/imported.reg" 2>/dev/null
}
out=$(run 1 1)
printf '%s\n' "$out" | grep -A1 -F '[HKEY_CURRENT_USER\Software\Stained Glass\Speech]' | grep -qx '"Enabled"=dword:00000001' \
    && pass "microphone on: voice typing is turned on" || fail "microphone on: no Speech Enabled: $out"
printf '%s\n' "$out" | grep -q '"LocaleName"="en-GB"' && printf '%s\n' "$out" | grep -q '"Applied"="1"' \
    && pass "and the region and the stamp are applied" || fail "region/stamp: $out"
out=$(run 2 0)
printf '%s\n' "$out" | grep -q 'Stained Glass\\Speech' && fail "microphone off: voice typing was turned on" \
    || pass "microphone off: voice typing is left off"
printf '%s\n' "$out" | grep -A1 'ConsentStore\\microphone\]' | grep -q '"Value"="Deny"' \
    && pass "and the microphone is denied" || fail "microphone deny: $out"
echo
[ "$RC" -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
