#!/bin/sh
# sg-wineserver stops a server left on the prefix (sg-prefix-init's) and waits until it is
# gone before it starts the machine's: started at once, the new server found the old one
# still there and exited, and the login screen came up with no machine server (release 612).
# A stand-in wineserver records what it is asked, in order.
#   --mutant NOWAIT  without the wait (must FAIL)
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
F="$HERE/bin/sg-wineserver"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
if [ "${1:-}" = --mutant ] && [ "${2:-}" = NOWAIT ]; then sed '/wineserver -w/d' "$F" > "$T/f"; F="$T/f"; fi
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
mkdir -p "$T/bin" "$T/lib"
printf '#!/bin/sh\necho "$*" >> "%s/calls"\n' "$T" > "$T/bin/wineserver"; chmod 755 "$T/bin/wineserver"
cat > "$T/lib/sg-common.sh" <<EOC
sg_log() { :; }
sg_die() { echo "DIE \$*"; exit 1; }
sg_wine_env() { :; }
SG_PREFIX=$T/prefix
SG_ROOT=$T
EOC
mkdir -p "$T/prefix" && : > "$T/prefix/.sg-initialized"
env PATH="$T/bin:$PATH" SG_LIB="$T/lib" XDG_RUNTIME_DIR="$T/run" sh "$F" >/dev/null 2>&1
calls=$(tr '\n' '|' < "$T/calls" 2>/dev/null)
case "$calls" in "-k|-w|-p -f|") pass "the old server stopped, waited for, then the machine's started ($calls)" ;;
  *) fail "calls: $calls" ;; esac
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
