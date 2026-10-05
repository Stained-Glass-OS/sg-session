#!/bin/sh
. "$(dirname "$0")/scratch-home.sh"
# sg-common.sh's sg_mono_support_refresh: Wine Mono's support MSI (.NET's
# NDP and AssemblyFolders keys) is applied again to an existing prefix when
# the package's MSI changed -- Wine itself never re-runs it while Wine Mono's
# version stays 9.4.0, so machines installed before Mono sg9 lacked
# AssemblyFolders\v3.5 and Meedio's/MeediOS's installers ran Microsoft's .NET
# 3.5 setup ("Turn Windows features on or off", David 2026-10-05).
#
# Part 1 (always): a fake wine records the calls -- msiexec runs once for a
# new MSI, not again for the same one, again for a changed one.
# Part 2 (with SG_TEST_WINE=<wine> SG_TEST_MONO_OLD=<old wine-mono dir>
# SG_TEST_MONO_NEW=<new wine-mono dir>): a real scratch prefix with the old
# support MSI gets the new one's AssemblyFolders\v3.5 (both views).
# Each part has a mutant: the function doing nothing.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RC=0
mkdir -p "$T/bin" "$T/state"
printf 'one' > "$T/support.msi"
cat > "$T/bin/wine" <<EOF2
#!/bin/sh
printf "%s\\n" "\$*" >> "$T/calls"
EOF2
chmod +x "$T/bin/wine"
run() { ( PATH="$T/bin:$PATH"; . "$1" >/dev/null 2>&1; sg_mono_support_refresh "$T/state" "$T/support.msi" ) 2>/dev/null; }
run "$HERE/lib/sg-common.sh"
grep -q '^msiexec /i Z:.*support.msi REINSTALL=ALL REINSTALLMODE=vomus /qn$' "$T/calls" 2>/dev/null &&
[ "$(wc -l < "$T/calls")" -eq 1 ] && echo "PASS  a new support MSI is applied (REINSTALL=ALL from the package)" \
    || { echo "FAIL  first run: $(tr '\n' '|' < "$T/calls" 2>/dev/null)"; RC=1; }
rm -f "$T/calls"
run "$HERE/lib/sg-common.sh"
[ ! -s "$T/calls" ] && echo "PASS  the same MSI is not applied again" || { echo "FAIL  re-applied the same MSI"; RC=1; }
printf 'two' > "$T/support.msi"
run "$HERE/lib/sg-common.sh"
[ -s "$T/calls" ] && echo "PASS  a changed MSI (a newer Wine Mono package) is applied" || { echo "FAIL  changed MSI not applied"; RC=1; }
# mutant: the function does nothing
rm -f "$T/calls" "$T/state/mono-support.sha256"
sed '/^sg_mono_support_refresh() {/,/^}/c\sg_mono_support_refresh() { :; }' "$HERE/lib/sg-common.sh" > "$T/mut.sh"
run "$T/mut.sh"
[ ! -s "$T/calls" ] && echo "PASS  MUTANT NO_MONO_REFRESH applies nothing (part 1 catches it)" || { echo "FAIL  mutant"; RC=1; }

# Part 2: real Wine.
if [ -z "${SG_TEST_WINE:-}" ] || [ ! -f "${SG_TEST_MONO_OLD:-/nonexistent}/support/winemono-support.msi" ] ||
   [ ! -f "${SG_TEST_MONO_NEW:-/nonexistent}/support/winemono-support.msi" ]; then
    echo "SKIP  part 2 (set SG_TEST_WINE, SG_TEST_MONO_OLD, SG_TEST_MONO_NEW)"
    exit $RC
fi
mkdir -p "$T/wbin"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$SG_TEST_WINE" > "$T/wbin/wine"; chmod +x "$T/wbin/wine"
WS=${SG_TEST_WINESERVER:-$(dirname "$SG_TEST_WINE")/server/wineserver}
real() {   # real PREFIX LIB: old MSI in, then the refresh with the new one
    export WINEPREFIX="$1" WINEDEBUG=-all
    export WINEDLLOVERRIDES="mscoree=;mshtml=;winemenubuilder.exe=d"
    "$SG_TEST_WINE" wineboot -i >/dev/null 2>&1
    "$SG_TEST_WINE" msiexec /i "$("$SG_TEST_WINE" winepath -w "$SG_TEST_MONO_OLD/support/winemono-support.msi" | tr -d '\r')" /qn >/dev/null 2>&1
    ( PATH="$T/wbin:$PATH"; . "$2" >/dev/null 2>&1; sg_mono_support_refresh "$1/state" "$SG_TEST_MONO_NEW/support/winemono-support.msi" ) 2>/dev/null
    "$WS" -w 2>/dev/null
}
q() { "$SG_TEST_WINE" reg query 'HKLM\Software\Microsoft\.NETFramework\AssemblyFolders\v3.5' "/reg:$1" 2>/dev/null | grep -c 'Reference Assemblies'; }
real "$T/pfx" "$HERE/lib/sg-common.sh"
old=$(WINEPREFIX="$T/pfx" "$SG_TEST_WINE" reg query 'HKLM\Software\Microsoft\.NETFramework\AssemblyFolders' /reg:32 2>/dev/null | grep -c . )
a32=$(WINEPREFIX="$T/pfx" q 32); a64=$(WINEPREFIX="$T/pfx" q 64)
[ "$a32" -ge 1 ] && [ "$a64" -ge 1 ] && echo "PASS  real prefix with the old MSI: AssemblyFolders v3.5 after the refresh (32 and 64-bit views)" \
    || { echo "FAIL  real prefix: AssemblyFolders v3.5 32=$a32 64=$a64 (old keys $old)"; RC=1; }
"$WS" -k 2>/dev/null
real "$T/pfxm" "$T/mut.sh"
m32=$(WINEPREFIX="$T/pfxm" q 32)
[ "$m32" -eq 0 ] && echo "PASS  MUTANT NO_MONO_REFRESH: real prefix keeps the old MSI's keys (part 2 catches it)" \
    || { echo "FAIL  mutant real prefix has AssemblyFolders v3.5 anyway: is SG_TEST_MONO_OLD older than sg9?"; RC=1; }
WINEPREFIX="$T/pfxm" "$WS" -k 2>/dev/null
exit $RC
