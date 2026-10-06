#!/bin/sh
# sg-restart-notify: while /run/reboot-required is there, its notice is shown
# once a boot (a stand-in for the popup records it): a second run in the same
# boot shows nothing, a new boot shows it again, no file shows nothing. The
# kernel-install plugin 93-sg-reboot-required writes the file for a kernel
# newer than the running one, not for the running one or an older one.
# Mutant: no memory of the boot -- every run shows it again.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
printf '#!/bin/sh\necho shown >> "%s/shown"\n' "$T" > "$T/show"; chmod +x "$T/show"
echo boot-1 > "$T/boot_id"
run() {
    SG_REBOOT_REQUIRED="$T/reboot-required" SG_RESTART_SEEN="$T/state/seen" SG_BOOT_ID="$T/boot_id" \
        SG_RESTART_NOTICE_CMD="$T/show" sh "${1:-$HERE/lib/sg-restart-notify}"
    sleep 0.3
}
n() { if [ -f "$T/shown" ]; then wc -l < "$T/shown"; else echo 0; fi; }
run
[ "$(n)" = 0 ] && pass "nothing to restart for: nothing shown" || fail "shown without reboot-required"
echo '*** System restart required: a new Linux kernel (6.12.112+deb13-amd64) ***' > "$T/reboot-required"
run; run
[ "$(n)" = 1 ] && pass "a restart is needed: shown, once this boot" || fail "shown $(n) times"
echo boot-2 > "$T/boot_id"; run
[ "$(n)" = 2 ] && pass "...and again the next boot, if it is still needed" || fail "next boot: shown $(n) times"
# the kernel-install plugin
P="$HERE/kernel/93-sg-reboot-required.install"
rm -f "$T/rr"
SG_UNAME=6.12.111+deb13-amd64 SG_REBOOT_REQUIRED="$T/rr" sh "$P" add 6.12.111+deb13-amd64
SG_UNAME=6.12.111+deb13-amd64 SG_REBOOT_REQUIRED="$T/rr" sh "$P" add 6.12.100+deb13-amd64
[ ! -e "$T/rr" ] && pass "the running or an older kernel: no restart needed" || fail "reboot-required for an old kernel"
SG_UNAME=6.12.111+deb13-amd64 SG_REBOOT_REQUIRED="$T/rr" sh "$P" add 6.12.112+deb13-amd64
grep -q 'a new Linux kernel (6.12.112+deb13-amd64)' "$T/rr" 2>/dev/null && pass "a newer kernel: reboot-required" || fail "no reboot-required for a new kernel"
# mutant: no memory of the boot
rm -f "$T/shown" "$T/state/seen"; sed 's/^\[ "$(cat "$SEEN" 2>\/dev\/null)" = "$boot" \] \&\& exit 0$/:/' "$HERE/lib/sg-restart-notify" > "$T/mut"
cmp -s "$T/mut" "$HERE/lib/sg-restart-notify" && fail "the mutant did not change anything"
run "$T/mut"; run "$T/mut"
[ "$(n)" -gt 1 ] && pass "MUTANT FORGETS caught" || fail "MUTANT FORGETS not caught"
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
