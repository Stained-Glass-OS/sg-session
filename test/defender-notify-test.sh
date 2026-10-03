#!/bin/sh
. "$(dirname "$0")/scratch-home.sh"
# sg-defender-notify: each of this person's SG Defender notices is shown once
# (a stand-in for the popup records what it was asked to show); a second run
# shows nothing again, a new notice is shown; a notice older than a week is
# not brought up; names that are not notice ids are ignored.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
N="$T/notices"; D="$N/$(id -u)"; mkdir -p "$D"
printf '#!/bin/sh\necho "$1" >> "%s/shown"\n' "$T" > "$T/show"; chmod +x "$T/show"
run() {
    SG_DEFENDER_NOTICES="$N" SG_DEFENDER_SEEN="$T/state/seen" SG_DEFENDER_NOTICE_CMD="$T/show" sh "${1:-$HERE/lib/sg-defender-notify}"
    sleep 0.3
}
echo '{}' > "$D/20261003-160447-50f28b.json"
echo '{}' > "$D/20260901-100000-aaaaaa.json"; touch -d '2026-09-01' "$D/20260901-100000-aaaaaa.json"
echo '{}' > "$D/bad;id.json"
run
[ "$(cat "$T/shown" 2>/dev/null)" = 20261003-160447-50f28b ] && pass "a new notice is shown (not an old one, not a bad name)" \
    || fail "shown: $(cat "$T/shown" 2>/dev/null)"
run
[ "$(wc -l < "$T/shown")" = 1 ] && pass "...once" || fail "shown again: $(cat "$T/shown")"
echo '{}' > "$D/20261003-170000-bbbbbb.json"; run
[ "$(tail -1 "$T/shown")" = 20261003-170000-bbbbbb ] && [ "$(wc -l < "$T/shown")" = 2 ] && pass "a later one is shown too" \
    || fail "later: $(cat "$T/shown")"
# mutant: no memory of what was shown -- every run shows them all again
rm -f "$T/shown" "$T/state/seen"; sed 's/grep -qx "$id" "$SEEN" \&\& continue/:/' "$HERE/lib/sg-defender-notify" > "$T/mut"
run "$T/mut"; run "$T/mut"
[ "$(wc -l < "$T/shown")" -gt 2 ] && pass "MUTANT FORGETS caught" || fail "MUTANT FORGETS not caught"
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
