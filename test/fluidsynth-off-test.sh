#!/bin/sh
# Debian's per-person fluidsynth daemon (a network shell on TCP 9800) stays
# off under our drop-in, and starts when the administrator's file exists.
# The stand-in unit carries Debian's own conditions. --mutant: the drop-in
# left out -- the test must fail.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
command -v systemd-analyze >/dev/null || { echo "SKIP  no systemd-analyze"; exit 77; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# systemd-analyze --user needs a runtime directory; CI containers have none
mkdir -m 700 "$T/run"; export XDG_RUNTIME_DIR="$T/run"
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
DROP="$HERE/../systemd/fluidsynth.service.d/50-sg-off.conf"
mkdir -p "$T/off/fluidsynth.service.d" "$T/on/fluidsynth.service.d"
# Debian's ConditionUser=!@system holds for a person; run as root or another
# system user (CI builds as root) it fails whatever our drop-in says, so the
# stand-in leaves it out there: what is tested is our own condition
USERCOND='ConditionUser=!@system\n'
[ "$(id -u)" -lt 1000 ] && USERCOND=
for d in off on; do
    printf "[Unit]\nDescription=FluidSynth Daemon\n${USERCOND}[Service]\nType=notify\nExecStart=/usr/bin/fluidsynth -is\n[Install]\nWantedBy=default.target\n" \
        > "$T/$d/fluidsynth.service"
done
[ "${1:-}" = --mutant ] || cp "$DROP" "$T/off/fluidsynth.service.d/"
: > "$T/optin"
sed "s|^ConditionPathExists=.*|ConditionPathExists=$T/optin|" "$DROP" > "$T/on/fluidsynth.service.d/50-sg-off.conf"
SYSTEMD_UNIT_PATH="$T/off:" systemd-analyze --user condition --unit=fluidsynth.service > "$T/out" 2>&1 \
    && fail "the daemon would start: $(tail -1 "$T/out")" \
    || { grep -q "ConditionPathExists=/etc/stained-glass/fluidsynth-daemon failed" "$T/out" \
        && pass "the daemon stays off without the administrator's file" \
        || fail "the daemon is not held off by our condition: $(cat "$T/out")"; }
SYSTEMD_UNIT_PATH="$T/on:" systemd-analyze --user condition --unit=fluidsynth.service > "$T/out" 2>&1 \
    && pass "the daemon starts when the administrator's file exists" \
    || fail "the daemon stays off even with the file: $(cat "$T/out")"
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
