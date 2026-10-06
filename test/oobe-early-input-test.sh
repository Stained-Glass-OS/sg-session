#!/bin/sh
. "$(dirname "$0")/scratch-home.sh"
# The first-run setup takes input only once its first page is on the screen
# and it has the keyboard ("sg-oobe: ready"). On a slow first boot keys came
# before it was shown (s14 regression walk, 2026-10-06) and went nowhere or
# to a page not yet seen. The wizard alone under Wine on a private X server
# (no bridge: its stdin held open), with SG_OOBE_READY_DELAY_MS holding it
# not ready for 4 s, as a slow first boot does:
#   1. keys pressed before "ready" change nothing (the region stays)
#   2. "ready" comes, and a key after it moves the region list
# Mutant: built with -DSG_MUTANT_OOBE_EARLY_INPUT (test/oobe-early-input-test.sh --mutant).
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
EXE="$HERE/build/sg-oobe64.exe"
RC=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; RC=1; }
for t in xvfb-run xdotool wine x86_64-w64-mingw32-gcc; do command -v "$t" >/dev/null || { echo "SKIP: $t not installed"; exit 77; }; done
T=$(mktemp -d /var/tmp/sg-oobe-early.XXXXXX)
export WINEPREFIX="$T/prefix" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=;winemenubuilder.exe=d"
trap 'wineserver -k 2>/dev/null; rm -rf "$T"' EXIT INT TERM
if [ "${1:-}" = --mutant ]; then
    x86_64-w64-mingw32-gcc -O2 -mwindows -DSG_MUTANT_OOBE_EARLY_INPUT -o "$T/oobe.exe" "$HERE/setup/sg-oobe.c" -lgdi32 -luser32 || exit 1
    EXE="$T/oobe.exe"
fi
[ -f "$EXE" ] || { echo "SKIP: run 'make greeter' first"; exit 77; }
wineboot -i >/dev/null 2>&1; wineserver -w
cat > "$T/drive.sh" <<'EOS'
#!/bin/sh
set -u
LOG="$T/oobe.log"
sleep 600 | SG_OOBE_READY_DELAY_MS=4000 wine "$EXE" 2>"$LOG" >/dev/null &
w=0; until grep -q 'page region' "$LOG" 2>/dev/null; do sleep 0.1; w=$((w + 1)); [ $w -lt 600 ] || exit 1; done
w=0; until xdotool search --name 'Stained Glass OS setup' >/dev/null 2>&1; do sleep 0.1; w=$((w + 1)); [ $w -lt 100 ] || break; done
xdotool search --name 'Stained Glass OS setup' windowactivate 2>/dev/null
sleep 0.5
grep -c 'sg-oobe: selected' "$LOG" > "$T/sel-before"
for i in 1 2 3 4 5 6; do xdotool key u; sleep 0.15; done
grep -q 'sg-oobe: ready' "$LOG" && echo early > "$T/ready-too-soon"
sed -n '/sg-oobe: ready/q;p' "$LOG" | grep -c 'sg-oobe: selected' > "$T/sel-early"
w=0; until grep -q 'sg-oobe: ready' "$LOG"; do sleep 0.2; w=$((w + 1)); [ $w -lt 100 ] || break; done
grep -q 'sg-oobe: ready' "$LOG" && echo yes > "$T/ready"
n=$(grep -c 'sg-oobe: selected' "$LOG"); xdotool key u; sleep 1
[ "$(grep -c 'sg-oobe: selected' "$LOG")" -gt "$n" ] && echo yes > "$T/after"
EOS
chmod +x "$T/drive.sh"
export T EXE
timeout 200 xvfb-run -a -s "-screen 0 1280x800x24" "$T/drive.sh"
[ -f "$T/ready-too-soon" ] && echo "      (ready before the keys: the hold did not work)"
if [ "$(cat "$T/sel-early" 2>/dev/null)" = "$(cat "$T/sel-before" 2>/dev/null)" ] && [ -n "$(cat "$T/sel-before" 2>/dev/null)" ] && [ ! -f "$T/ready-too-soon" ]; then
    pass "keys before the wizard is ready change nothing"
else fail "keys before ready moved the list (selected lines $(cat "$T/sel-before" 2>/dev/null) -> $(cat "$T/sel-early" 2>/dev/null))"; fi
if [ -f "$T/ready" ]; then pass "it says when it is ready (sg-oobe: ready)"; else fail "never ready"; fi
if [ -f "$T/after" ]; then pass "and a key after that moves the list"; else fail "a key after ready did nothing"; fi
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
