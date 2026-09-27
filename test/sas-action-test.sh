#!/bin/sh
# sg-sas-action: the Ctrl+Alt+Del screen's Task Manager and Sign out, run in
# the session by sg-compositor. A stand-in wine records what it was asked.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
RC=0; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
mkdir -p "$T/wine/bin"
printf '#!/bin/sh\necho "$*" >> %s/asked\n' "$T" > "$T/wine/bin/wine"; chmod 755 "$T/wine/bin/wine"
run() { : > "$T/asked"; SG_LIB="$HERE/lib" SG_WINE_DIR="$T/wine" sh "$HERE/lib/sg-sas-action" "$@" 2>/dev/null; echo "rc=$? $(cat "$T/asked")"; }
[ "$(run taskmgr)" = "rc=0 taskmgr.exe" ] && pass "Task Manager starts taskmgr.exe" || fail "taskmgr: $(run taskmgr)"
[ "$(run signout)" = "rc=0 shutdown.exe /l" ] && pass "Sign out runs shutdown.exe /l (wine-sg 0438, 0439)" || fail "signout: $(run signout)"
[ "$(run 'rm -rf /')" = "rc=2 " ] && pass "anything else is refused, and nothing runs" || fail "other: $(run 'rm -rf /')"
[ "$(run)" = "rc=2 " ] && pass "no choice: refused" || fail "none: $(run)"
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
