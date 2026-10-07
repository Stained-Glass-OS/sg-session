#!/bin/sh
# Stained Glass Firewall in a real kernel: two network namespaces joined by
# a veth pair, sg-firewall's daemon in one, connections from the other.
#   - a system service with no rule is not reachable; SSH (built-in) is
#   - a port rule opens its port; a person's program listening is asked
#     about and unreachable until a rule allows it, reachable within
#     seconds after, and its port closes again when it stops listening
#   - a rule for Private does not open a Public network; making the network
#     Private does
#   - a Windows program (Wine's notice with its socket) is opened by the
#     rule its installer stored in the registry (system.reg)
#   - turning the firewall off for Public lets everything in
#   - another program's nftables table (a VPN's kill switch) is never
#     touched, and stopping the service removes only ours
# Needs root (sudo -n): exits 77 without it, or without nft/ip.
#
#   firewall-netns-test.sh [--mutant FW_ACCEPT_ALL|FW_FLUSH|FW_NO_LISTEN]
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
MUTANT=""
[ "${1:-}" = --mutant ] && MUTANT=${2:-}
if [ "$(id -u)" = 0 ]; then SUDO=""; else SUDO="sudo -n"; fi
$SUDO true 2>/dev/null || { echo "SKIP  needs root (sudo -n)"; exit 77; }
NFT=$(PATH=/usr/sbin:/sbin:$PATH command -v nft) || { echo "SKIP  no nft"; exit 77; }
IP=$(PATH=/usr/sbin:/sbin:$PATH command -v ip) || { echo "SKIP  no ip"; exit 77; }
PY=/usr/bin/python3
ME=$(id -u)
[ "$ME" = 0 ] && ME=1000

RC=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; RC=1; }

T=$(mktemp -d /var/tmp/sgfw-netns.XXXXXX)
chmod 755 "$T"
A=sgfwa$$
B=sgfwb$$
DPID=""
PIDS=""
# a background job is sudo, which does not pass on a signal from its own
# process group: its child (the program) is stopped directly
stop_bg() { $SUDO pkill -TERM -P "$1" 2>/dev/null; $SUDO kill "$1" 2>/dev/null; }
cleanup() {
    for p in $PIDS $DPID; do stop_bg "$p"; done
    sleep 0.3
    $SUDO "$IP" netns del "$A" 2>/dev/null
    $SUDO "$IP" netns del "$B" 2>/dev/null
    $SUDO rm -rf "$T"
}
trap cleanup EXIT INT TERM

FW="$HERE/bin/sg-firewall"
case "$MUTANT" in
    "") ;;
    FW_ACCEPT_ALL) sed 's/t.append("\\t\\tcounter drop")/t.append("\\t\\taccept")/' "$FW" > "$T/sg-firewall" ;;
    FW_FLUSH) sed 's/"table inet %s\\ndelete table inet %s\\n%s" % (TABLE, TABLE, text)/"flush ruleset\\n%s" % text/' "$FW" > "$T/sg-firewall" ;;
    FW_NO_LISTEN) sed 's/plan.open\[p\]\[l.proto\].add((l.port, l.port))/pass/' "$FW" > "$T/sg-firewall" ;;
    *) echo "unknown mutant $MUTANT"; exit 2 ;;
esac
if [ -n "$MUTANT" ]; then
    cmp -s "$FW" "$T/sg-firewall" && { echo "FAIL  mutant $MUTANT changed nothing"; exit 1; }
    FW="$T/sg-firewall"
fi

$SUDO "$IP" netns add "$A" && $SUDO "$IP" netns add "$B" || { echo "SKIP  cannot make network namespaces"; exit 77; }
$SUDO "$IP" link add "va$$" netns "$A" type veth peer name "vb$$" netns "$B" || { echo "SKIP  no veth"; exit 77; }
$SUDO "$IP" -n "$A" addr add 10.199.0.1/24 dev "va$$"
$SUDO "$IP" -n "$B" addr add 10.199.0.2/24 dev "vb$$"
for n in "$A" "$B"; do $SUDO "$IP" -n "$n" link set lo up; done
$SUDO "$IP" -n "$A" link set "va$$" up
$SUDO "$IP" -n "$B" link set "vb$$" up

# NetworkManager's answer: one active connection, the veth
cat > "$T/nmcli" <<EOF
#!/bin/sh
case "\$*" in *--active*) printf 'u-test:vb$$:802-3-ethernet:Test network\\n' ;; esac
EOF
chmod 755 "$T/nmcli"
mkdir -p "$T/etc" "$T/state" "$T/run"
# Sonos's installer's rule, as wineserver writes it to the machine's registry
cat > "$T/system.reg" <<'EOF'
WINE REGISTRY Version 2

[System\\CurrentControlSet\\Services\\SharedAccess\\Parameters\\FirewallPolicy\\FirewallRules] 1759796000
"{SONOS-TCP}"="v2.30|Action=Allow|Active=TRUE|Dir=In|Protocol=6|LPort=3400|App=%ProgramFiles%\\Sonos\\Sonos.exe|Name=Sonos|"
EOF

# SG_FIREWALL_TEST: the stand-in for a Windows program below is python, not Wine
FWENV="SG_FIREWALL_TEST=1 SG_FIREWALL_CONF=$T/etc/firewall.conf SG_FIREWALL_STATE=$T/state SG_FIREWALL_RUN=$T/run SG_FIREWALL_SYSTEM_REG=$T/system.reg SG_FIREWALL_ROLE=$T/role SG_FIREWALL_NMCLI=$T/nmcli SG_FIREWALL_TABLE=sg_firewall"
inb() { $SUDO env $FWENV "$IP" netns exec "$B" "$@"; }
ina() { $SUDO "$IP" netns exec "$A" "$@"; }
fwcmd() { inb "$PY" "$FW" "$@" >/dev/null; }

# someone else's table: a VPN client's kill switch
inb "$NFT" -f - <<'EOF'
table inet sg_other_probe {
    chain output {
        type filter hook output priority 0; policy accept;
        counter accept
    }
}
EOF

# a listener: "listen PORT [tcp|udp]"; as root (a system service) or as a person
cat > "$T/listen.py" <<'EOF'
import socket, sys, time
port = int(sys.argv[1])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", port))
s.listen(8)
while True:
    c, _ = s.accept()
    c.sendall(b"hi\n")
    c.close()
EOF
cp "$T/listen.py" "$T/person.py"
# a Windows program under Wine: it listens, and Wine's hook (wine-sg 1500)
# tells the firewall which program it is, with the socket itself
cat > "$T/winprog.py" <<'EOF'
import array, socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", int(sys.argv[1])))
s.listen(8)
n = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
n.sendmsg([b"SGFW1\nC:\\Program Files\\Sonos\\Sonos.exe\n"],
          [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [s.fileno()]))], 0, sys.argv[2])
while True:
    c, _ = s.accept()
    c.sendall(b"hi\n")
    c.close()
EOF
chmod 644 "$T"/*.py

reach() {   # PORT -> prints open / closed
    ina "$PY" -c '
import socket, sys
s = socket.socket(); s.settimeout(1.2)
try:
    s.connect(("10.199.0.2", int(sys.argv[1]))); print("open")
except (socket.timeout, TimeoutError): print("dropped")
except OSError: print("refused")' "$1"
}
wait_for() {   # PORT WANT SECONDS
    i=0
    while [ $i -lt $(($3 * 2)) ]; do
        [ "$(reach "$1")" = "$2" ] && return 0
        sleep 0.5; i=$((i + 1))
    done
    return 1
}

bg_root() { inb "$PY" "$@" & PIDS="$PIDS $!"; }

bg_root "$T/listen.py" 22          # sshd's place
bg_root "$T/listen.py" 8080        # a system service nobody allowed
bg_root "$T/listen.py" 8081        # a port rule will open this
sleep 0.5
[ "$(reach 8080)" = open ] && pass "before the firewall: open" || fail "the test network does not work ($(reach 8080))"

inb "$PY" "$FW" --daemon 2>"$T/daemon.err" &
DPID=$!
i=0; while [ $i -lt 20 ] && ! inb "$NFT" list table inet sg_firewall >/dev/null 2>&1; do sleep 0.3; i=$((i + 1)); done
inb "$NFT" list table inet sg_firewall >/dev/null 2>&1 && pass "the daemon loaded its table" || { fail "no table"; cat "$T/daemon.err"; }
sleep 2.5

[ "$(reach 22)" = open ] && pass "SSH reachable (built-in group, a system service listening)" || fail "SSH not reachable"
[ "$(reach 8080)" = dropped ] && pass "a system service without a rule is dropped" || fail "8080: $(reach 8080)"
[ "$(reach 8090)" = dropped ] && pass "a port nothing listens on is dropped (no refusal to tell)" || fail "8090: $(reach 8090)"

fwcmd rule-add allow public tcp 8081 '*' 'Port 8081'
wait_for 8081 open 6 && pass "a port rule opens its port" || fail "8081: $(reach 8081)"

# a person's program, listening
inb setpriv --reuid="$ME" --regid="$ME" --clear-groups "$PY" "$T/person.py" 9000 >/dev/null 2>&1 &
PP=$!; PIDS="$PIDS $PP"
sleep 3
ASK=$(ls "$T/run/ask/$ME/" 2>/dev/null | grep '\.ask$' | head -1)
[ -n "$ASK" ] && grep -q "program=$T/person.py" "$T/run/ask/$ME/$ASK" && pass "a person's program listening: they are asked" \
    || fail "no question ($(ls -la "$T/run/ask/$ME/" 2>&1 | tr '\n' ' '))"
[ "$(reach 9000)" = dropped ] && pass "and it is unreachable until allowed" || fail "9000 before the rule: $(reach 9000)"
fwcmd rule-add allow private any '*' "$T/person.py" 'Person'
sleep 3
[ "$(reach 9000)" = dropped ] && pass "allowed on Private only: still closed on this Public network" || fail "9000 on Public: $(reach 9000)"
[ ! -e "$T/run/ask/$ME/$ASK" ] && pass "the question goes once a rule names the program" || fail "the question stayed"
fwcmd network u-test private 'Test network'
wait_for 9000 open 8 && pass "the network made Private: the program is reachable" || fail "9000 on Private: $(reach 9000)"
grep -q '^current	private' "$T/run/status" && pass "the status says Private" || fail "status: $(grep '^current' "$T/run/status")"
stop_bg "$PP"
sleep 3
if inb "$NFT" list set inet sg_firewall private_allow_tcp 2>/dev/null | grep -q '9000'; then
    fail "its port stayed open after it stopped listening"
else pass "its port closes when it stops listening"; fi

# a Windows program, by the rule its installer stored
bg_root "$T/winprog.py" 3400 "$T/run/notify"
wait_for 3400 open 8 && pass "a Windows program (Wine's notice) is let in by its installer's registry rule" || fail "3400: $(reach 3400)"

# the firewall off for Private (this network now)
fwcmd profile private off
wait_for 8080 open 8 && pass "firewall off for Private: everything in" || fail "8080 with the firewall off: $(reach 8080)"
fwcmd profile private on
wait_for 8080 dropped 8 && pass "and on again" || fail "8080 after on: $(reach 8080)"

inb "$NFT" list table inet sg_other_probe >/dev/null 2>&1 && pass "another program's table is untouched" || fail "another program's table is gone"
stop_bg "$DPID"; wait "$DPID" 2>/dev/null; DPID=""
inb "$PY" "$FW" --stop
inb "$NFT" list table inet sg_firewall >/dev/null 2>&1 && fail "the table stayed after stop" || pass "stopping removes our table"
inb "$NFT" list table inet sg_other_probe >/dev/null 2>&1 && pass "and only ours" || fail "stop removed another table"
[ "$(reach 8080)" = open ] && pass "stopped: open again" || fail "8080 after stop: $(reach 8080)"

[ $RC = 0 ] && echo "all passed" || echo "FAILED"
exit $RC
