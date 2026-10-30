#!/bin/sh
# sg-procagent's memory reads never leave the process they read stopped
# (test/procagent-stop-test.c says how Opera's window froze). Builds the agent
# and the test here; --mutant builds the agent that takes the first stop for
# its own (SG_MUTANT_FIRST_STOP), which must fail.
# SPDX-License-Identifier: AGPL-3.0-or-later
set -u
cd "$(dirname "$0")/.." || exit 1
command -v cc >/dev/null 2>&1 || { echo "SKIP: no cc"; exit 77; }
scope=$(cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null || echo 0)
[ "$scope" -lt 2 ] || { echo "SKIP: ptrace_scope $scope allows no tracing"; exit 77; }
D=$(mktemp -d /var/tmp/sg-pastop-build.XXXXXX)
trap 'rm -rf "$D"' EXIT INT TERM
M=
[ "${1:-}" = --mutant ] && M=-DSG_MUTANT_FIRST_STOP
cc -O2 $M -o "$D/agent" procagent/sg-procagent.c || { echo "FAIL  the agent did not build"; exit 1; }
cc -O2 -pthread -o "$D/test" test/procagent-stop-test.c || { echo "FAIL  the test did not build"; exit 1; }
timeout -s KILL 300 "$D/test" "$D/agent"
