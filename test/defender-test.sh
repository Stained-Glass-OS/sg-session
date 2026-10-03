#!/bin/sh
# SG Defender (bin/sg-defender): a downloaded program is scanned and, if
# ClamAV finds something, quarantined and its owner told (David 2026-10-03).
# A stand-in for clamdscan finds the EICAR test string; a home of the test's
# own is watched:
#   1. an infected .exe in Downloads: quarantined (gone from Downloads, kept
#      in the quarantine with its signature), a notice for its owner
#   2. a clean program: scanned, left where it is
#   3. a text file, even with the test string: not a program, not scanned
#   4. a download in progress (.part) is scanned once renamed, not before
#   5. a program in a new folder under Downloads, and one on the Desktop
#   6. turned off (enabled=0): nothing is scanned
# Mutants: NO_QUARANTINE, SCAN_EVERYTHING, NO_PARTIAL_WAIT.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d)
RC=0
trap 'kill $DP 2>/dev/null; rm -rf "$T"' EXIT
EICAR='X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*'
cat > "$T/clamdscan" <<'EOS'
#!/bin/sh
[ "$1" = --version ] && { echo "ClamAV 1.4.3/99999/test"; exit 0; }
for f; do :; done
echo "$f" >> "$(dirname "$0")/scanned"
if grep -q EICAR-STANDARD "$f" 2>/dev/null; then echo "$f: Eicar-Test-Signature FOUND"; exit 1; fi
exit 0
EOS
chmod +x "$T/clamdscan"
mkdir -p "$T/home/Downloads" "$T/home/Desktop"
start() {   # script
    SG_DEFENDER_CONF="$T/defender.conf" SG_DEFENDER_STATE="$T/state" SG_DEFENDER_NOTICES="$T/notices" \
    SG_DEFENDER_HOMES="$T/home" SG_DEFENDER_SCAN="$T/clamdscan" python3 "$1" 2>"$T/log" & DP=$!
    sleep 1.5
}
scanned() { n=$(grep -c "$1" "$T/scanned" 2>/dev/null); echo "${n:-0}"; }
start "$HERE/bin/sg-defender"
printf 'MZ%s' "$EICAR" > "$T/home/Downloads/setup.exe"
printf 'MZ clean program' > "$T/home/Downloads/clean.exe"
printf '%s' "$EICAR" > "$T/home/Downloads/notes.txt"
printf 'MZ%s' "$EICAR" > "$T/home/Downloads/later.exe.part"
sleep 3
[ "$(scanned later.exe.part)" = 0 ] && echo "PASS  a download in progress (.part) is not scanned yet" || { echo "FAIL  scanned while downloading"; RC=1; }
mv "$T/home/Downloads/later.exe.part" "$T/home/Downloads/later.exe"
mkdir "$T/home/Downloads/sub"; sleep 1.5
printf 'MZ%s' "$EICAR" > "$T/home/Downloads/sub/deep.exe"
printf '#!/bin/sh\n%s\n' "$EICAR" > "$T/home/Desktop/run.sh"
sleep 4
[ ! -e "$T/home/Downloads/setup.exe" ] && ls "$T/state/quarantine/"*.bin >/dev/null 2>&1 \
    && grep -q '"signature": "Eicar-Test-Signature"' "$T"/state/quarantine/*.json \
    && echo "PASS  an infected download is quarantined, with its signature" || { echo "FAIL  not quarantined: $(ls "$T/home/Downloads")"; RC=1; }
ls "$T"/notices/*/*.json >/dev/null 2>&1 && grep -q '"name": "setup.exe"' "$T"/notices/*/*.json \
    && echo "PASS  and its owner is told" || { echo "FAIL  no notice"; RC=1; }
[ -e "$T/home/Downloads/clean.exe" ] && [ "$(scanned clean.exe)" = 1 ] && echo "PASS  a clean program is scanned and left" || { echo "FAIL  clean: $(scanned clean.exe)"; RC=1; }
[ -e "$T/home/Downloads/notes.txt" ] && [ "$(scanned notes.txt)" = 0 ] && echo "PASS  a text file is not a program: not scanned" || { echo "FAIL  text scanned"; RC=1; }
[ ! -e "$T/home/Downloads/later.exe" ] && echo "PASS  ...and scanned once renamed (caught)" || { echo "FAIL  the renamed download was missed"; RC=1; }
[ ! -e "$T/home/Downloads/sub/deep.exe" ] && [ ! -e "$T/home/Desktop/run.sh" ] && echo "PASS  in a new folder under Downloads, and on the Desktop" || { echo "FAIL  deep/desktop: $(ls "$T/home/Downloads/sub" "$T/home/Desktop")"; RC=1; }
grep -q '"found": 4' "$T/state/status.json" && echo "PASS  Settings' status counts them (4 found)" || { echo "FAIL  status: $(cat "$T/state/status.json")"; RC=1; }
# restored by an administrator: that exact file is let be, another still caught
printf 'MZ%s trusted' "$EICAR" > "$T/ok.bin"; sha256sum "$T/ok.bin" | cut -d' ' -f1 > "$T/state/allowed"
cp "$T/ok.bin" "$T/home/Downloads/trusted.exe"; printf 'MZ%s other' "$EICAR" > "$T/home/Downloads/other.exe"; sleep 3
[ -e "$T/home/Downloads/trusted.exe" ] && [ ! -e "$T/home/Downloads/other.exe" ] \
    && echo "PASS  a file an administrator restored is not quarantined again; others still are" || { echo "FAIL  allowed: $(ls "$T/home/Downloads")"; RC=1; }
grep -q '"mode": ' "$T"/state/quarantine/*.json && echo "PASS  quarantine keeps the file's mode, for a restore" || { echo "FAIL  no mode kept"; RC=1; }
kill $DP; sleep 0.5; rm -f "$T/home/Downloads/trusted.exe"
sed 's/if verdict\[0\] and allowed(path):/if False:/' "$HERE/bin/sg-defender" > "$T/mut.py"; start "$T/mut.py"
cp "$T/ok.bin" "$T/home/Downloads/trusted.exe"; sleep 3
[ ! -e "$T/home/Downloads/trusted.exe" ] && echo "PASS  MUTANT IGNORE_ALLOWED caught" || { echo "FAIL  MUTANT IGNORE_ALLOWED not caught"; RC=1; }
kill $DP; sleep 0.5
echo "enabled=0" > "$T/defender.conf"; start "$HERE/bin/sg-defender"
printf 'MZ%s' "$EICAR" > "$T/home/Downloads/off.exe"; sleep 3
[ -e "$T/home/Downloads/off.exe" ] && echo "PASS  turned off: nothing scanned" || { echo "FAIL  scanned while off"; RC=1; }
kill $DP; sleep 0.5; rm -f "$T/defender.conf" "$T/home/Downloads/off.exe"
mutant() {   # name sed-expression check-description
    sed "$2" "$HERE/bin/sg-defender" > "$T/mut.py"; rm -rf "$T/state" "$T/notices" "$T/scanned"; start "$T/mut.py"
    printf 'MZ%s' "$EICAR" > "$T/home/Downloads/m.exe"; printf '%s' "$EICAR" > "$T/home/Downloads/m.txt"
    printf 'MZ%s' "$EICAR" > "$T/home/Downloads/m2.exe.part"; sleep 3
    if eval "$3"; then echo "PASS  MUTANT $1 caught"; else echo "FAIL  MUTANT $1 not caught"; RC=1; fi
    kill $DP; sleep 0.5; rm -f "$T"/home/Downloads/m*
}
mutant NO_QUARANTINE 's/qid = quarantine(path, uid, verdict\[1\])/qid = None/' '[ -e "$T/home/Downloads/m.exe" ]'
mutant SCAN_EVERYTHING 's/or not runnable(path):/:/' '[ "$(scanned m.txt)" != 0 ]'
mutant NO_PARTIAL_WAIT 's/    if name.endswith(PARTIAL):/    if False:/' '[ "$(scanned m2.exe.part)" != 0 ]'
# ClamAV runs as background work (its drop-ins): not ahead of the first-run setup
for u in clamav-daemon clamav-freshclam; do
    f="$HERE/systemd/$u.service.d/50-sg-background.conf"
    grep -qx 'Nice=15' "$f" 2>/dev/null && grep -qx 'IOSchedulingClass=idle' "$f" && grep -q "$u.service.d/50-sg-background.conf" "$HERE/Makefile" \
        && echo "PASS  $u runs at background priority" || { echo "FAIL  $u has no background-priority drop-in installed"; RC=1; }
done
exit $RC
