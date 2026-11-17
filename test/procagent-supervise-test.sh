#!/bin/sh
# The session's process agent comes back when it dies (sg_procagent_supervise):
# the machine's wineserver reaches the user's threads only through it, and
# without it a .NET program's garbage collections fail (wine-sg 7843).
# A stand-in agent writes its pid; the test kills it by that pid and wants a new
# one within a few seconds; then ends the stand-in session and wants the
# supervisor and its agent gone. --mutant: the agent is not restarted.
# SPDX-License-Identifier: AGPL-3.0-or-later
set -u
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d /var/tmp/sg-pasup.XXXXXX)
SESSION=""; SUP=""
cleanup() {
    for p in $(cat "$T"/pids 2>/dev/null) $SUP $SESSION; do kill "$p" 2>/dev/null; done
    rm -rf "$T"
}
trap cleanup EXIT INT TERM
[ "${1:-}" = --mutant ] && export SG_MUTANT_PROCAGENT_NO_RESTART=1
RC=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; RC=1; }
cat > "$T/agent" <<'A'
#!/bin/sh
echo $$ >> "$(dirname "$0")/pids"
echo "$1" > "$(dirname "$0")/prefix-arg"
exec sleep 600
A
chmod +x "$T/agent"
SG_LIB=$PWD/lib
# shellcheck source=lib/sg-common.sh
. "$SG_LIB/sg-common.sh"
sleep 600 &
SESSION=$!
sg_procagent_supervise "$T/agent" /the/prefix "$SESSION" 2>"$T/log" &
SUP=$!
first=""
for _ in $(seq 50); do first=$(head -1 "$T/pids" 2>/dev/null); [ -n "$first" ] && break; sleep 0.1; done
[ -n "$first" ] && [ "$(cat "$T/prefix-arg")" = /the/prefix ] && pass "the agent starts, for the session's prefix" \
    || fail "the agent did not start"
kill "$first" 2>/dev/null
second=""
for _ in $(seq 80); do second=$(sed -n 2p "$T/pids" 2>/dev/null); [ -n "$second" ] && break; sleep 0.1; done
if [ -n "$second" ] && kill -0 "$second" 2>/dev/null; then pass "killed, the agent comes back (pid $first, then $second)"
else fail "the killed agent did not come back"; fi
kill "$SESSION"; wait "$SESSION" 2>/dev/null; SESSION=""
gone=0
for _ in $(seq 60); do kill -0 "$SUP" 2>/dev/null || { gone=1; break; }; sleep 0.1; done
[ "$gone" = 1 ] && pass "the session gone, the supervisor ends" || fail "the supervisor outlived the session"
if [ -n "$second" ] && kill -0 "$second" 2>/dev/null; then fail "the agent outlived the session"
elif [ -n "$second" ]; then pass "and stops its agent"; fi
[ "$RC" = 0 ] && echo "RESULT: PASS" || { sed 's/^/      /' "$T/log"; echo "RESULT: FAIL"; }
exit "$RC"
