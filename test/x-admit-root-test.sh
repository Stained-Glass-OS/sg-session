#!/bin/sh
# root may draw on the session's X display (sg-common.sh sg_x_admit_root):
# GParted and Timeshift, started through pkexec, run as root, and Xwayland
# admits only the user who started it. A real X server with access control
# on (Xvfb with an auth file, as Xwayland is): root cannot connect before,
# can after; another user still cannot. Needs Xvfb, xdpyinfo and sudo -n;
# exit 77 otherwise.
#   test/x-admit-root-test.sh [--mutant NO_ROOT_X]
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
[ "${1:-}" = --mutant ] && export SG_MUTANT="$2"
for c in Xvfb xdpyinfo xhost xauth; do command -v $c >/dev/null || { echo "SKIP: no $c"; exit 77; }; done
sudo -n true 2>/dev/null || { echo "SKIP: needs sudo -n"; exit 77; }
T=$(mktemp -d); chmod 755 "$T"
D=:$(( 300 + $$ % 200 ))
xauth -q -f "$T/auth" add "$D" . "$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')" 2>/dev/null
Xvfb "$D" -auth "$T/auth" -nolisten tcp -noreset >/dev/null 2>&1 & X=$!
trap 'kill $X 2>/dev/null; rm -rf "$T"' EXIT
n=0; until XAUTHORITY="$T/auth" xdpyinfo -display "$D" >/dev/null 2>&1; do n=$((n+1)); [ $n -gt 50 ] && { echo "FAIL  Xvfb did not start"; exit 1; }; sleep 0.1; done
# the session's user reaches it by its cookie, as by SI:localuser on Xwayland
as_root() { sudo -n env -i PATH=/usr/bin:/bin DISPLAY="$D" xdpyinfo >/dev/null 2>&1; }
RC=0
if as_root; then echo "FAIL  root connects with no entry (the server lets everyone in)"; exit 1; fi
echo "PASS  before: root is refused, as by the session's Xwayland"
# shellcheck source=../lib/sg-common.sh
( DISPLAY=$D XAUTHORITY="$T/auth"; export DISPLAY XAUTHORITY; . "$HERE/lib/sg-common.sh"; sg_x_admit_root )
if as_root; then echo "PASS  after sg_x_admit_root: root (pkexec's GParted) opens the display"
else echo "FAIL  root still cannot open the display"; RC=1; fi
other=$(getent passwd nobody >/dev/null && echo nobody)
if [ -n "$other" ]; then
    if sudo -n -u "$other" env -i PATH=/usr/bin:/bin DISPLAY="$D" xdpyinfo >/dev/null 2>&1; then
        echo "FAIL  $other connects too"; RC=1
    else echo "PASS  ...and no one else ($other is still refused)"; fi
fi
grep -q '^sg_x_admit_root$' "$HERE/lib/sg-run-explorer" && echo "PASS  the session's start calls it" ||
    { echo "FAIL  sg-run-explorer does not call sg_x_admit_root"; RC=1; }
exit $RC
