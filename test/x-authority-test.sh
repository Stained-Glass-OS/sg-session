#!/bin/sh
# XAUTHORITY names a file in the session (sg-common.sh sg_x_authority):
# Xwayland admits the user by who they are, with no cookie, so XAUTHORITY was
# unset -- and Warzone 2100's launcher (bwrap --ro-bind-try $XAUTHORITY
# $XAUTHORITY, unquoted) lost two arguments and ran "/sys". Checks: with none
# set, the function exports an empty file of the user's own (0600) under
# XDG_RUNTIME_DIR; one already set is kept; such a launcher's arguments stay
# whole; and on a real X server with access control (the user admitted as
# SI:localuser, as by Xwayland) an X program connects with the empty file.
# Needs Xvfb, xauth, xhost, xdpyinfo for the last; exit 77 for none.
#   test/x-authority-test.sh [--mutant NO_XAUTHORITY]
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
[ "${1:-}" = --mutant ] && export SG_MUTANT="$2"
T=$(mktemp -d); chmod 700 "$T"
mkdir -p "$T/run" "$T/bin"
for c in systemctl dbus-update-activation-environment; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n' "$c" "$T" > "$T/bin/$c"; chmod +x "$T/bin/$c"
done
X=
trap 'kill $X 2>/dev/null; rm -rf "$T"' EXIT
RC=0
xa=$(env -i SG_MUTANT="${SG_MUTANT:-}" PATH="$T/bin:/usr/bin:/bin" XDG_RUNTIME_DIR="$T/run" sh -c '. "$1"; sg_x_authority; echo "$XAUTHORITY"' sh "$HERE/lib/sg-common.sh" 2>/dev/null)
if [ "$xa" = "$T/run/sg-xauthority" ] && [ -f "$xa" ] && [ "$(stat -c %a "$xa")" = 600 ]; then
    echo "PASS  with none set, XAUTHORITY names an empty file of the user's own (0600)"
else echo "FAIL  XAUTHORITY '$xa'"; RC=1; fi
grep -q "^systemctl --user import-environment XAUTHORITY" "$T/calls" 2>/dev/null &&
    grep -q "^dbus-update-activation-environment XAUTHORITY" "$T/calls" &&
    echo "PASS  ...for the user's systemd manager and D-Bus activation too" || { echo "FAIL  calls: $(cat "$T/calls" 2>/dev/null)"; RC=1; }
kept=$(env -i SG_MUTANT="${SG_MUTANT:-}" PATH="$T/bin:/usr/bin:/bin" XDG_RUNTIME_DIR="$T/run" XAUTHORITY=/x/own sh -c '. "$1"; sg_x_authority; echo "$XAUTHORITY"' sh "$HERE/lib/sg-common.sh" 2>/dev/null)
[ "$kept" = /x/own ] && echo "PASS  one the session has is kept" || { echo "FAIL  replaced: $kept"; RC=1; }
# Warzone 2100's launcher: its arguments with the session's XAUTHORITY
n=$(env -i SG_MUTANT="${SG_MUTANT:-}" PATH="$T/bin:/usr/bin:/bin" XDG_RUNTIME_DIR="$T/run" sh -c '. "$1"; sg_x_authority; set -- --ro-bind-try $XAUTHORITY $XAUTHORITY --dev /dev; echo $#' sh "$HERE/lib/sg-common.sh" 2>/dev/null)
[ "$n" = 5 ] && echo "PASS  an unquoted launcher (Warzone 2100's bwrap) keeps its arguments" || { echo "FAIL  the launcher got $n arguments (want 5)"; RC=1; }
grep -q '^sg_x_authority$' "$HERE/lib/sg-run-explorer" && echo "PASS  the session's start calls it" ||
    { echo "FAIL  sg-run-explorer does not call sg_x_authority"; RC=1; }
if command -v Xvfb >/dev/null && command -v xauth >/dev/null && command -v xhost >/dev/null && command -v xdpyinfo >/dev/null; then
    D=:$(( 500 + $$ % 100 ))
    xauth -q -f "$T/cookie" add "$D" . "$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')" 2>/dev/null
    Xvfb "$D" -auth "$T/cookie" -nolisten tcp -noreset >/dev/null 2>&1 & X=$!
    n=0; until XAUTHORITY="$T/cookie" xdpyinfo -display "$D" >/dev/null 2>&1; do n=$((n+1)); [ $n -gt 50 ] && break; sleep 0.1; done
    XAUTHORITY="$T/cookie" DISPLAY="$D" xhost "+SI:localuser:$(id -un)" >/dev/null 2>&1
    if [ -n "$xa" ] && XAUTHORITY="$xa" xdpyinfo -display "$D" >/dev/null 2>&1; then
        echo "PASS  an X program connects with the empty file (admitted as the user, as by Xwayland)"
    else echo "FAIL  no connection with XAUTHORITY='$xa'"; RC=1; fi
else echo "SKIP  the X check: needs Xvfb, xauth, xhost, xdpyinfo"; fi
exit $RC
