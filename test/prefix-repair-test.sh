#!/bin/sh
# Unit test: Windows system files left empty by a first boot cut short (the
# regression walk's 581 zero-length .exe/.dll, explorer.exe among them) are
# found at boot and put back -- from the prefix seed when it has them, and
# otherwise deleted so Wine's prefix update makes them again. A healthy prefix
# is left alone (no update started). Stand-in wine/wineserver record calls.
# The 4th case cuts the seed short.
#   sh test/prefix-repair-test.sh [--mutant]   (--mutant: repair turned off; must FAIL)
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
MUT=; [ "${1:-}" = --mutant ] && MUT=1
mkdir -p "$T/wine/bin" "$T/wine/share/wine" "$T/empty"
for b in wine wineserver; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\nexit 0\n' "$b" "$T" > "$T/wine/bin/$b"; chmod +x "$T/wine/bin/$b"
done
: > "$T/wine/share/wine/wine.inf"; touch -d @1790725500 "$T/wine/share/wine/wine.inf"
W="$T/root/prefix/drive_c/windows"
mkdir -p "$W/system32" "$W/syswow64"
for f in explorer.exe notepad.exe system32/kernel32.dll syswow64/user32.dll; do
    printf 'MZ this is %s\n' "$f" > "$W/$f"
done
: > "$W/system32/empty-by-design.log"
: > "$T/root/prefix/.sg-initialized"
printf '1790725500\r\n' > "$T/root/prefix/.update-timestamp"
tar -C "$T/root" -c . | zstd -q -o "$T/seed.tar.zst"
run() {
    : > "$T/calls"
    SG_MUTANT_NO_EMPTY_REPAIR=$MUT SG_PREFIX_SEED="$T/seed.tar.zst" \
    SG_LIB="$HERE/lib" SG_WINE_DIR="$T/wine" SG_ROOT="$T/root" SG_PREFIX="$T/root/prefix" SG_STATE="$T/root/state" \
        SG_DEFAULTS_DIR="$T/empty" SG_BIN="$T/empty" PATH="$T/wine/bin:/usr/bin:/bin" \
        sh "$HERE/bin/sg-prefix-init" > "$T/log" 2>&1
}
RC=0
ok()   { echo "PASS  $1"; }
bad()  { echo "FAIL  $1"; RC=1; }

# 1. healthy prefix: nothing touched, no prefix update
run
grep -q '^wine cmd /c exit' "$T/calls" && bad "a healthy prefix was updated" || ok "a healthy prefix: no repair, no update"

# 2. the cut-short first boot: names there, data gone
for f in explorer.exe notepad.exe system32/kernel32.dll syswow64/user32.dll; do : > "$W/$f"; done
run
n=0; for f in explorer.exe notepad.exe system32/kernel32.dll syswow64/user32.dll; do
    grep -q "MZ this is $f" "$W/$f" 2>/dev/null && n=$((n + 1)); done
[ $n = 4 ] && ok "4 empty system files restored from the seed" || bad "only $n of 4 empty system files restored"
grep -q '^wine cmd /c exit' "$T/calls" && bad "restored from the seed, yet the prefix was updated" || ok "all from the seed: no update needed"
[ -f "$W/system32/empty-by-design.log" ] && ok "other empty files left alone" || bad "an empty non-binary was removed"

# 3. an empty binary the seed does not have (Wine upgraded since): deleted,
#    Wine's prefix update makes it
: > "$W/system32/newer.dll"; : > "$W/notepad.exe"
run
grep -q "MZ this is notepad.exe" "$W/notepad.exe" && ok "the one the seed has: restored" || bad "notepad.exe not restored"
[ -e "$W/system32/newer.dll" ] && bad "an empty newer.dll stayed (Wine's update would not replace it)" || ok "the one the seed lacks: removed for Wine to remake"
grep -q '^wine cmd /c exit' "$T/calls" && ok "the prefix update ran to remake it" || bad "no prefix update to remake it"

# 4. a truncated seed (its end cut off): what it still has is restored, the
#    rest removed for Wine's update -- never left empty
printf '1790725500\r\n' > "$T/root/prefix/.update-timestamp"
head -c $(( $(wc -c < "$T/seed.tar.zst") / 2 )) "$T/seed.tar.zst" > "$T/seed.cut"; mv "$T/seed.cut" "$T/seed.tar.zst"
for f in explorer.exe notepad.exe system32/kernel32.dll syswow64/user32.dll; do : > "$W/$f"; done
run
left=$(find "$W" -type f -size 0 -name '*.exe' -o -type f -size 0 -name '*.dll' | wc -l)
[ "$left" = 0 ] && ok "truncated seed: no empty system file left" || bad "truncated seed: $left empty system files left"
grep -q '^wine cmd /c exit' "$T/calls" && ok "truncated seed: the prefix update ran" || bad "truncated seed: no prefix update"
exit $RC
