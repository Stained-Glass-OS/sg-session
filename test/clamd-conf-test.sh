#!/bin/sh
# lib/sg-clamd-conf: clamd starts from Debian's clamd.conf with
# ConcurrentDatabaseReload no (one line, whatever the original said), the
# rest kept; the clamav-daemon drop-in runs it and starts clamd with it.
# Mutant (--mutant): the original's own ConcurrentDatabaseReload kept.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
S="$HERE/lib/sg-clamd-conf"
[ "${1:-}" = --mutant ] && { sed 's/grep -iv .*"\$SRC"/cat "$SRC"/' "$S" > "$T/mut"; S="$T/mut"; }
printf 'LocalSocket /var/run/clamav/clamd.ctl\nUser clamav\n  concurrentdatabasereload yes\nMaxThreads 12\n' > "$T/clamd.conf"
SG_CLAMD_CONF_SRC="$T/clamd.conf" SG_CLAMD_CONF_DST="$T/out.conf" sh "$S"
[ "$(grep -ic 'ConcurrentDatabaseReload' "$T/out.conf")" = 1 ] && grep -qx 'ConcurrentDatabaseReload no' "$T/out.conf" \
    && pass "ConcurrentDatabaseReload no, once" || fail "reload lines: $(grep -i reload "$T/out.conf")"
grep -qx 'User clamav' "$T/out.conf" && grep -qx 'MaxThreads 12' "$T/out.conf" && grep -qx 'LocalSocket /var/run/clamav/clamd.ctl' "$T/out.conf" \
    && pass "the rest of clamd.conf is kept" || fail "lines lost"
[ "$(stat -c %a "$T/out.conf")" = 644 ] && pass "readable (clamd reads it after dropping to clamav)" || fail "mode $(stat -c %a "$T/out.conf")"
D="$HERE/systemd/clamav-daemon.service.d/60-sg-memory.conf"
grep -qx 'ExecStartPre=/usr/lib/stained-glass/sg-clamd-conf' "$D" && grep -qx 'ExecStart=' "$D" \
    && grep -qx 'ExecStart=/usr/sbin/clamd --foreground=true --config-file=/var/lib/clamav/sg-clamd.conf' "$D" \
    && grep -q 'clamav-daemon.service.d/60-sg-memory.conf' "$HERE/Makefile" && pass "clamd is started with it (drop-in installed)" || fail "drop-in"
exit $RC
