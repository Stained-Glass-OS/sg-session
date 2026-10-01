#!/bin/sh
# sg_start_deskcomp (lib/sg-common.sh): the session starts sg-compositor's
# sg-deskcomp -- window shadows, real alpha, the window effects -- when it is
# installed, not when SG_DESKCOMP=0, and quietly not when it is missing.
#   sh test/deskcomp-start-test.sh [--mutant]   (--mutant: the launch line removed; must fail)
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
COMMON="$HERE/lib/sg-common.sh"
if [ "${1:-}" = --mutant ]; then
    sed '/^    "\$_dc" <\/dev\/null &$/d' "$COMMON" > "$T/common.sh"; COMMON="$T/common.sh"
fi
mkdir -p "$T/libexec" "$T/empty"
cat > "$T/libexec/sg-deskcomp" <<W
#!/bin/sh
echo started >> "$T/runs"
W
chmod +x "$T/libexec/sg-deskcomp"
RC=0
run() { ( . "$COMMON"; sg_start_deskcomp; wait ) 2>/dev/null; }
SG_LIBEXEC="$T/libexec" run
[ "$(cat "$T/runs" 2>/dev/null)" = started ] && echo "PASS  sg-deskcomp is started" || { echo "FAIL  not started"; RC=1; }
: > "$T/runs"
SG_LIBEXEC="$T/libexec" SG_DESKCOMP=0 run
[ ! -s "$T/runs" ] && echo "PASS  SG_DESKCOMP=0 leaves it out" || { echo "FAIL  started with SG_DESKCOMP=0"; RC=1; }
SG_LIBEXEC="$T/empty" run && echo "PASS  without it, nothing fails" || { echo "FAIL  a missing sg-deskcomp failed"; RC=1; }
exit $RC
