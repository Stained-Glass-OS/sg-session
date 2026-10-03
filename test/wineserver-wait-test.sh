#!/bin/sh
# sg_wineserver_stale: whether an update must restart the machine's wineserver
# -- only when the installed Wine cannot talk to it (a stand-in runuser says
# what the Wine client would).
# sg-prefix-init's exit stops its transient wineserver -- never the machine's
# running one (it stopped that at every update, ending every Windows program).
# sg_wineserver_clear_strays: a wineserver of another account in the prefix's
# server directory is ended before the machine's starts (a renamed sleep
# stands in; the machine's account here is one that is not this one).
# sg_wineserver_wait: no wait on the machine's persistent wineserver
# (sg-wineserver.service), which never exits -- waiting hung every update that
# brought new defaults for systemd's 10 minutes (David 2026-10-03) -- and a
# bounded one on a prefix's own. Stand-ins: a wineserver whose -w never
# returns, a systemctl that says the service is (or is not) active.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
RC=0
mkdir -p "$T/bin"
printf '#!/bin/sh\n[ "$1" = -w ] && exec sleep 600\n' > "$T/bin/wineserver"
printf '#!/bin/sh\n[ -e "%s/active" ]\n' "$T" > "$T/bin/systemctl"
chmod +x "$T/bin/wineserver" "$T/bin/systemctl"
w() {   # lib seconds -> how long sg_wineserver_wait took, in whole seconds
    s=$(date +%s)
    PATH="$T/bin:$PATH" sh -c '. "$1" >/dev/null 2>&1; sg_wineserver_wait "$2"' x "$1" "$2"
    echo $(( $(date +%s) - s ))
}
touch "$T/active"
a=$(w "$HERE/lib/sg-common.sh" 20)
[ "$a" -le 1 ] && echo "PASS  the machine's wineserver running: no wait ($a s)" || { echo "FAIL  waited $a s on the persistent wineserver"; RC=1; }
rm -f "$T/active"
b=$(w "$HERE/lib/sg-common.sh" 3)
[ "$b" -ge 2 ] && [ "$b" -le 5 ] && echo "PASS  a prefix's own wineserver: waited for, but bounded ($b s of 3)" || { echo "FAIL  own wineserver: $b s"; RC=1; }
# mutant: always wait (the hang)
sed '/^sg_wineserver_wait() {/,/^}/c\sg_wineserver_wait() { timeout "${1:-120}" wineserver -w 2>/dev/null || true; }' "$HERE/lib/sg-common.sh" > "$T/mut.sh"
touch "$T/active"
m=$(w "$T/mut.sh" 4)
[ "$m" -ge 3 ] && echo "PASS  MUTANT ALWAYS_WAIT waits on the persistent one (the test catches it)" || { echo "FAIL  mutant not caught ($m s)"; RC=1; }
# sg_wineserver_stale
st() { PATH="$T/bin:$PATH" sh -c '. "$1" >/dev/null 2>&1; sg_wineserver_stale && echo stale || echo fine' x "$HERE/lib/sg-common.sh"; }
touch "$T/active"
printf '#!/bin/sh\necho "wine client error:0: version mismatch 863/864.  Your wineserver binary was not upgraded correctly"\nexit 1\n' > "$T/bin/runuser"; chmod +x "$T/bin/runuser"
[ "$(st)" = stale ] && echo "PASS  the new Wine cannot talk to the running server: restart it" || { echo "FAIL  mismatch not seen: $(st)"; RC=1; }
printf '#!/bin/sh\nexit 0\n' > "$T/bin/runuser"
[ "$(st)" = fine ] && echo "PASS  it can: the server (and every Windows program) is left running" || { echo "FAIL  restart without need: $(st)"; RC=1; }
rm -f "$T/active"
printf '#!/bin/sh\necho "version mismatch"\n' > "$T/bin/runuser"
[ "$(st)" = fine ] && echo "PASS  no machine server running: nothing to restart" || { echo "FAIL  not running: $(st)"; RC=1; }
# sg-prefix-init's stop_transient_server, run with a wineserver that records -k
printf '#!/bin/sh\n[ "$1" = -k ] && echo killed >> "%s/kills"\nexit 0\n' "$T" > "$T/bin/wineserver"; chmod +x "$T/bin/wineserver"
sed -n '/^stop_transient_server() {/,/^}/p' "$HERE/bin/sg-prefix-init" > "$T/stop.sh"
stop() { rm -f "$T/kills"; PATH="$T/bin:$PATH" sh -c '. "$1" >/dev/null 2>&1; . "$2"; stop_transient_server' x "$HERE/lib/sg-common.sh" "$1"; [ -e "$T/kills" ] && echo killed || echo left; }
touch "$T/active"
[ "$(stop "$T/stop.sh")" = left ] && echo "PASS  sg-prefix-init's exit leaves the machine's running wineserver" || { echo "FAIL  it stopped the machine's wineserver"; RC=1; }
rm -f "$T/active"
[ "$(stop "$T/stop.sh")" = killed ] && echo "PASS  and stops its own transient one (at boot)" || { echo "FAIL  the transient server was left"; RC=1; }
printf 'stop_transient_server() { timeout 30 wineserver -k 2>/dev/null || true; }\n' > "$T/stop-mut.sh"
touch "$T/active"
[ "$(stop "$T/stop-mut.sh")" = killed ] && echo "PASS  MUTANT ALWAYS_STOP stops it (the test catches it)" || { echo "FAIL  mutant not caught"; RC=1; }
# sg_wineserver_clear_strays
mkdir -p "$T/prefix"
dir="/tmp/.wine-sg-$(stat -c %D "$T/prefix")-$(printf %x "$(stat -c %i "$T/prefix")")"
mkdir -p "$dir/server-x" "$T/elsewhere"
cp "$(command -v sleep)" "$T/wineserver"
( cd "$dir/server-x" && exec "$T/wineserver" 300 ) & S1=$!
( cd "$T/elsewhere" && exec "$T/wineserver" 300 ) & S2=$!
sleep 0.5
SG_PREFIX="$T/prefix" SG_SYSTEM_USER=nobody-here sh -c '. "$1" >/dev/null 2>&1; sg_wineserver_clear_strays' x "$HERE/lib/sg-common.sh" >/dev/null 2>&1
sleep 0.5
alive() { [ -d "/proc/$1" ] && ! grep -q '^[0-9]* (.*) Z' "/proc/$1/stat" 2>/dev/null; }
! alive $S1 && echo "PASS  a stray wineserver on the machine's prefix is ended" || { echo "FAIL  the stray was left"; RC=1; }
alive $S2 && echo "PASS  one on another prefix is left alone" || { echo "FAIL  another prefix's server was ended"; RC=1; }
kill $S1 $S2 2>/dev/null; wait 2>/dev/null; rm -rf "$dir"
exit $RC
