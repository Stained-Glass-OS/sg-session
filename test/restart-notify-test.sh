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
echo "OK unlocked" > "$T/lockstate"
printf '#!/bin/sh\ncat "%s/lockstate"\n' "$T" > "$T/status"; chmod +x "$T/status"
run() {
    SG_REBOOT_REQUIRED="$T/reboot-required" SG_RESTART_SEEN="$T/state/seen" SG_BOOT_ID="$T/boot_id" \
        SG_RESTART_NOTICE_CMD="$T/show" SG_LOCK_STATUS_CMD="$T/status" sh "${1:-$HERE/lib/sg-restart-notify}"
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
# not while locked; after the unlock
echo boot-3 > "$T/boot_id"; echo "OK locked" > "$T/lockstate"; run; run
[ "$(n)" = 2 ] && pass "locked: not shown behind the lock screen" || fail "locked: shown ($(n))"
echo "OK unlocked" > "$T/lockstate"; run
[ "$(n)" = 3 ] && pass "...and shown once unlocked" || fail "after the unlock: shown $(n) times"
# a notice that ends while the session is locked (timed out behind the lock screen): again after the unlock
printf '#!/bin/sh\necho shown >> "%s/shown"\necho "OK locked" > "%s/lockstate"\n' "$T" "$T" > "$T/show"
echo boot-4 > "$T/boot_id"; run; sleep 0.5; run
[ "$(n)" = 4 ] && pass "a notice that ran out behind the lock screen is not shown again while locked" || fail "locked after: shown $(n) times"
printf '#!/bin/sh\necho shown >> "%s/shown"\n' "$T" > "$T/show"
echo "OK unlocked" > "$T/lockstate"; run
[ "$(n)" = 5 ] && pass "...and is shown again after the unlock" || fail "after the unlock: shown $(n) times"
# mutant: shown while locked
sed 's/^locked \&\& exit 0$/:/' "$HERE/lib/sg-restart-notify" > "$T/mutlock"
cmp -s "$T/mutlock" "$HERE/lib/sg-restart-notify" && fail "the lock mutant did not change anything"
echo boot-5 > "$T/boot_id"; echo "OK locked" > "$T/lockstate"; run "$T/mutlock"
[ "$(n)" = 6 ] && pass "MUTANT SHOWN-WHILE-LOCKED caught" || fail "MUTANT SHOWN-WHILE-LOCKED not caught"
echo "OK unlocked" > "$T/lockstate"
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
