#!/bin/sh
# At boot sg-services-start has sg-shell's sg-roots put Windows' code signing and time
# stamping roots into the machine's Root store (David 2026-10-28: "like Windows"), in the
# background, when the tool and the bundle are installed -- and does nothing without them.
# The block runs with a stand-in wine that records its arguments.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SRC="${SG_SERVICES_START:-$HERE/bin/sg-services-start}"
RC=0; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
sed -n '/^_roots_tool=/,/^fi$/p' "$SRC" > "$T/block.sh"
[ -s "$T/block.sh" ] || { fail "no code signing roots step in sg-services-start"; echo "RESULT: FAIL"; exit 1; }
mkdir -p "$T/bin" "$T/libexec/shell"
cat > "$T/bin/wine" <<EOW
#!/bin/sh
echo "\$*" >> "$T/wine.log"
echo "sg-roots: 3 added, 0 kept, 0 removed, 0 left as they were (not ours), 0 failed"
EOW
chmod 755 "$T/bin/wine"
run() { env PATH="$T/bin:$PATH" SG_LIBEXEC="$T/libexec" SG_CODESIGN_ROOTS="$T/roots.pem" LOGF="$T/x.log" \
        sh -c 'sg_log() { echo "LOG $*" >> "$LOGF"; }; . "$1"; wait' sh "$T/block.sh"; }
run
[ ! -e "$T/wine.log" ] && pass "nothing installed: no sync" || fail "ran without the tool: $(cat "$T/wine.log")"
: > "$T/libexec/shell/sg-roots64.exe"; echo "# uses: 1.3.6.1.5.5.7.3.3" > "$T/roots.pem"
run
grep -qx "$T/libexec/shell/sg-roots64.exe --sync Z:$T/roots.pem" "$T/wine.log" 2>/dev/null \
    && pass "with sg-roots and its bundle: the machine's roots synced from the bundle" || fail "wine: $(cat "$T/wine.log" 2>&1)"
grep -q 'LOG sg-roots: 3 added' "$T/x.log" 2>/dev/null && pass "...and what it did is in the log" || fail "log: $(cat "$T/x.log" 2>&1)"
# mutant: the step taken out -- the gate must notice
sed '/^_roots_tool=/,/^fi$/d' "$SRC" > "$T/mut"
if SG_SERVICES_START="$T/mut" sh "$0" >/dev/null 2>&1; then fail "MUTANT NOROOTS passed"; else pass "MUTANT NOROOTS (step removed) caught"; fi
[ $RC = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $RC
