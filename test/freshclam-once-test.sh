#!/bin/sh
# freshclam's daily one-shot stands aside while the freshclam daemon runs
# (systemd/clamav-freshclam-once.service.d): beside it, the two raced for
# freshclam.log's lock at boot and the daemon exited. The drop-in's own
# ExecCondition runs against a systemctl that reports the daemon running
# or not; the daemon's drop-in retries a failed start.
# Mutant: SG_MUTANT_FRESHCLAM_RACE=1 (the one-shot's drop-in left out).
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RC=0
f="$HERE/systemd/clamav-freshclam-once.service.d/50-sg-daemon.conf"
[ "${SG_MUTANT_FRESHCLAM_RACE:-}" = 1 ] && { : > "$T/empty.conf"; f="$T/empty.conf"; }
cond=$(sed -n 's/^ExecCondition=//p' "$f")
cat > "$T/systemctl" <<'STUB'
#!/bin/sh
[ "$*" = "is-active -q clamav-freshclam.service" ] && exit "$DAEMON_RC"
exit 3
STUB
chmod 755 "$T/systemctl"
# ExecCondition: 0 runs the unit, 1-254 skips it. No line runs it always.
run() { [ -n "$cond" ] || return 0; eval "DAEMON_RC=$1 PATH=\"$T:\$PATH\" $cond"; }
export DAEMON_RC
run 0; r=$?
[ "$r" -ge 1 ] && [ "$r" -le 254 ] && echo "PASS  the one-shot is skipped while the daemon runs" \
    || { echo "FAIL  the one-shot runs beside the daemon (condition rc=$r)"; RC=1; }
run 3; r=$?
[ "$r" = 0 ] && echo "PASS  the one-shot runs when the daemon is not running" \
    || { echo "FAIL  the one-shot is skipped with no daemon (condition rc=$r)"; RC=1; }
grep -qx 'After=clamav-freshclam.service' "$f" && echo "PASS  the one-shot is ordered after the daemon" \
    || { echo "FAIL  the one-shot is not ordered after the daemon"; RC=1; }
grep -q 'clamav-freshclam-once.service.d/50-sg-daemon.conf' "$HERE/Makefile" && echo "PASS  the one-shot's drop-in is installed" \
    || { echo "FAIL  the one-shot's drop-in is not installed"; RC=1; }
d="$HERE/systemd/clamav-freshclam.service.d/50-sg-background.conf"
grep -qx 'Restart=on-failure' "$d" && grep -q '^RestartSec=' "$d" && echo "PASS  a failed daemon start is retried" \
    || { echo "FAIL  a failed daemon start is not retried"; RC=1; }
exit $RC
