#!/bin/sh
# sg-boot-space-notify: while sg-boot-space's notice is there, its popup is
# shown once a boot (a stand-in records it), with its own memory -- the
# restart notice shown this boot does not hide it, nor it the restart
# notice -- nothing without the file, and the session's helper loop runs it
# when sg-shell has the popup.
# shellcheck disable=SC2015,SC2016
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
printf '#!/bin/sh\necho shown >> "%s/shown"\n' "$T" > "$T/show"; chmod +x "$T/show"
echo boot-1 > "$T/boot_id"
printf '#!/bin/sh\necho "OK unlocked"\n' > "$T/status"; chmod +x "$T/status"
run() {
    SG_BOOTSPACE_FILE="$T/boot-space" SG_BOOTSPACE_SEEN="$T/state/bs-seen" SG_BOOTSPACE_NOTICE_CMD="$T/show" \
    SG_RESTART_SEEN="$T/state/restart-seen" SG_BOOT_ID="$T/boot_id" SG_LOCK_STATUS_CMD="$T/status" \
    SG_RESTART_NOTIFY="$HERE/lib/sg-restart-notify" sh "$HERE/lib/sg-boot-space-notify"
    sleep 0.3
}
n() { if [ -f "$T/shown" ]; then wc -l < "$T/shown"; else echo 0; fi; }
run
[ "$(n)" = 0 ] && pass "no notice: nothing shown" || fail "shown without the notice"
printf 'kernel=6.12.118+deb13-amd64\nrunning=6.12.117+deb13-amd64\n' > "$T/boot-space"
mkdir -p "$T/state"; echo boot-1 > "$T/state/restart-seen"
run; run
[ "$(n)" = 1 ] && pass "a notice: shown once this boot (the restart notice seen this boot does not hide it)" || fail "shown $(n) times"
[ "$(cat "$T/state/restart-seen")" = boot-1 ] && [ -f "$T/state/bs-seen" ] && pass "its own memory, apart from the restart notice's" \
    || fail "shares the restart notice's memory"
echo boot-2 > "$T/boot_id"; run
[ "$(n)" = 2 ] && pass "...and again the next boot while it is there" || fail "next boot: shown $(n) times"
rm -f "$T/boot-space"; echo boot-3 > "$T/boot_id"; run
[ "$(n)" = 2 ] && pass "the notice gone (a kernel fitted): not shown" || fail "shown after the notice went"
grep -q 'sg-bootspace-notice64.exe" \] && SG_SHELL_DIR="\$_sgshelldir" sh "\$SG_LIB/sg-boot-space-notify"' "$HERE/lib/sg-run-explorer" \
    && pass "the helper loop runs it when sg-shell has the popup" || fail "not in sg-run-explorer"
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
