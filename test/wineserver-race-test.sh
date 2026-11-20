#!/bin/sh
# sg-services-start runs no Wine command before the unit's own wineserver holds the prefix
# (release next15: the unit is Type=exec, so ExecStartPost ran while sg-wineserver was still
# stopping an old server; its first "wine reg" started a transient server, the machine's
# exited with status 2, and the restart 35 s later cut off the first-run setup).
# A stand-in main process ($MAINPID) is slow to become the server: a shell that sleeps, then
# execs a stand-in wineserver that holds <dir>/server-*/lock and makes the socket. A stand-in
# wine records whether the server was up at each call.
#   - the first Wine command comes after the server is up
#   - a main process that ends first (status 2): services-start gives up at once, says so,
#     and runs no Wine command
#   --mutant NOWAIT  without the wait (must FAIL)
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
F="$HERE/bin/sg-services-start"
T=$(mktemp -d); trap 'kill $SRV 2>/dev/null; rm -rf "$T"' EXIT
SRV=
if [ "${1:-}" = --mutant ] && [ "${2:-}" = NOWAIT ]; then sed 's/^sg_wait_machine_server || exit 1$/:/' "$F" > "$T/f"; F="$T/f"; fi
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
command -v python3 >/dev/null || { echo "SKIP: python3 missing"; exit 77; }
mkdir -p "$T/bin" "$T/lib" "$T/prefix" "$T/tmp/server-1-2"
# the stand-in server: lock first, then the socket, as wineserver does; then it serves forever
cat > "$T/wineserver" <<EOP
#!/usr/bin/python3
import os, socket, time
d = "$T/tmp/server-1-2"
lock = open(d + "/lock", "w")
time.sleep(0.3)
s = socket.socket(socket.AF_UNIX); s.bind(d + "/socket"); s.listen(1)
open("$T/up", "w").close()
time.sleep(600)
EOP
chmod 755 "$T/wineserver"
cat > "$T/bin/wine" <<EOW
#!/bin/sh
if [ -e "$T/up" ]; then echo "up \$*" >> "$T/calls"; else echo "early \$*" >> "$T/calls"; fi
exit 0
EOW
chmod 755 "$T/bin/wine"
cat > "$T/lib/sg-common.sh" <<EOC
sg_log() { echo "\$*" >> "$T/log"; }
sg_wine_env() { :; }
sg_protect_machine_registry() { wine reg add 'HKLM\\Software' >/dev/null; }
sg_apply_policy() { :; }
SG_PREFIX=$T/prefix
SG_ROOT=$T
SG_LIB=$T/lib
SG_SYSTEM_USER=nobody-sg
EOC
run() {   # the stand-in main process, as systemd would have it: "sleep S; exec CMD"
    rm -f "$T/calls" "$T/log" "$T/up" "$T/tmp/server-1-2/socket"
    sh -c "sleep $1; exec $2" & SRV=$!
    env PATH="$T/bin:$PATH" SG_LIB="$T/lib" MAINPID=$SRV SG_SERVER_WAIT=20 SG_SERVICES_TIMEOUT=5 \
        SG_LIBEXEC="$T/none" SG_OOBE_CONF="$T/none" XDG_RUNTIME_DIR="$T/run" HOME="$T" \
        timeout 60 sh "$F" >/dev/null 2>&1
    echo $? > "$T/rc"
    kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; SRV=
}
run 2 "$T/wineserver"
first=$(head -n 1 "$T/calls" 2>/dev/null)
case "$first" in up\ *) pass "the first Wine command came after the server was up ($first)" ;;
    *) fail "the first Wine command: '$first' (all: $(tr '\n' '|' < "$T/calls" 2>/dev/null))" ;; esac
grep -q '^early' "$T/calls" 2>/dev/null && fail "a Wine command ran before the server was up" || pass "no Wine command before the server was up"
grep -q "the machine's wineserver is up after" "$T/log" && pass "it says when the server is up" || fail "log: $(tr '\n' '|' < "$T/log")"
s=$(date +%s)
run 1 "sh -c 'exit 2'"
took=$(( $(date +%s) - s ))
if [ ! -s "$T/calls" ] && [ "$(cat "$T/rc")" != 0 ] && grep -q 'ended before it was up' "$T/log" && [ "$took" -le 8 ]; then
    pass "the server ended first: no Wine command, a failure, a clear line, at once (${took}s)"
else fail "server ended first: calls '$(tr '\n' '|' < "$T/calls" 2>/dev/null)' rc $(cat "$T/rc") ${took}s log $(tr '\n' '|' < "$T/log")"; fi
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
