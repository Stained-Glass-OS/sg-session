#!/bin/sh
# sg_session_backdrop: "Getting things ready" (backdrop-first.sgbd) at a
# person's first sign-in only, "Welcome" (the default) after; someone who
# signed in before this came is not at their first (David 2026-10-02).
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RC=0
: > "$T/first.sgbd"
b() { ( HOME="$1"; unset XDG_STATE_HOME XDG_CONFIG_HOME SG_BACKDROP; export HOME SG_BACKDROP_FIRST="$T/first.sgbd"
        . "$2" >/dev/null 2>&1; sg_session_backdrop; printf '%s' "${SG_BACKDROP:-default}" ); }
mkdir -p "$T/new" "$T/old/.config/stained-glass"; : > "$T/old/.config/stained-glass/settings.json"
a=$(b "$T/new" "$HERE/lib/sg-common.sh"); c=$(b "$T/new" "$HERE/lib/sg-common.sh"); o=$(b "$T/old" "$HERE/lib/sg-common.sh")
[ "$a" = "$T/first.sgbd" ] && echo "PASS  first sign-in: getting things ready" || { echo "FAIL  first: $a"; RC=1; }
[ "$c" = default ] && echo "PASS  the next: welcome" || { echo "FAIL  second: $c"; RC=1; }
[ "$o" = default ] && echo "PASS  someone who signed in before (their settings there): welcome" || { echo "FAIL  existing user: $o"; RC=1; }
sed '/^sg_session_backdrop() {/,/^}/c\sg_session_backdrop() { SG_BACKDROP="$SG_BACKDROP_FIRST"; export SG_BACKDROP; }' "$HERE/lib/sg-common.sh" > "$T/mut.sh"
mkdir -p "$T/new2"; b "$T/new2" "$T/mut.sh" >/dev/null; m=$(b "$T/new2" "$T/mut.sh")
[ "$m" != default ] && echo "PASS  MUTANT ALWAYS_FIRST: the check catches it" || { echo "FAIL  mutant not caught"; RC=1; }
exit $RC
