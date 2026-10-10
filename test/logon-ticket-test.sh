#!/bin/sh
# LogonUser's way in (wine-sg 1709): the broker's "@logon" request checks an
# account's password -- here against a stand-in for PAM that takes one
# made-up password -- and answers with a one-time ticket, a file in a
# directory only the broker's account may read, naming the account, the
# requester and a time limit; the wineserver takes it from there. A wrong
# password gets no ticket, nor does root or the SYSTEM account; the password
# is in no ticket and no log. The check runs under the PAM service
# stained-glass-logon (pam_faillock locks the account out); one requester
# that fails too often is refused for a while without PAM being asked; every
# success and failure goes to the Security log (4624, 4625: the account, the
# requesting user and program, never the password). A throwaway broker, as
# this user (no root).
# Mutants: SG_MUTANT_LOGON_NO_PASSWORD_CHECK, SG_MUTANT_LOGON_NO_RATE_LIMIT,
# SG_MUTANT_LOGON_NO_AUDIT (broker/sg-brokerd.c).
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
B=${SG_BROKER_BUILD:-$HERE/build}
[ -x "$B/sg-brokerd" ] || { echo "SKIP: build the broker first (make procagent)"; exit 77; }
command -v python3 >/dev/null || { echo "SKIP: no python3"; exit 77; }
RC=0; T=$(mktemp -d "${TMPDIR:-/var/tmp}/logon-ticket.XXXXXX"); trap 'kill "$BPID" 2>/dev/null; [ -n "${KEEP:-}" ] || rm -rf "$T"' EXIT INT TERM
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
me=$(id -un); grp=$(id -gn); uid=$(id -u)
PW="t$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
other=daemon; ouid=$(id -u "$other" 2>/dev/null) || { echo "SKIP: no account $other"; exit 77; }

cat > "$T/pamcheck" <<EOS
#!/bin/bash
IFS= read -r -d '' user; IFS= read -r -d '' pass
echo "\$SG_REMOTE_PAM_SERVICE \$user" >> "$T/pam-calls"
[ "\$pass" = "$PW" ] && echo OK && exit 0
echo FAIL; exit 1
EOS
chmod 755 "$T/pamcheck"
mkdir "$T/run" "$T/audit"
SG_BROKER_FOREGROUND=1 SG_BROKER_SOCK="$T/run/sock" SG_BROKERD_LOG="$T/brokerd.log" SG_SYSTEM_USER="$me" \
    SG_ADMIN_GROUP="$grp" SG_SEAT_DIR="$T/noseat" SG_BROKER_PAMCHECK="$T/pamcheck" SG_LOGON_TICKET_DIR="$T/run/tickets" \
    SG_AUDIT_SPOOL="$T/audit" SG_LOGON_FAILURES=4 "$B/sg-brokerd" >/dev/null 2>&1 </dev/null & BPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$T/run/sock" ] && break; sleep 0.3; done

# the request as wine-sg's advapi32 sends it; the password on standard input
cat > "$T/client.py" <<'PY'
import socket, struct, sys
pw = sys.stdin.readline().rstrip('\n')
blob = b'\0'.join([b'@logon', b'LOGON_USER=' + sys.argv[2].encode(), b'LOGON_PASSWORD=' + pw.encode(),
                   b'LOGON_TYPE=2', b'LOGON_PROGRAM=C:\\test\\checker.exe']) + b'\0\0'
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
s.sendall(struct.pack('=I', len(blob)) + blob)
st = s.recv(1)
rest = b''
while True:
    d = s.recv(256)
    if not d: break
    rest += d
print(("STATUS %d %s" % (st[0] if st else -1, rest.decode().strip())).strip())
PY
logon() { python3 "$T/client.py" "$T/run/sock" "$1"; }   # USER; the password on stdin

out=$(echo "$PW" | logon "$other")
t=$(printf '%s' "$out" | sed -n 's/^STATUS 0 TICKET \([0-9a-f]\{32\}\)$/\1/p')
[ -n "$t" ] && pass "the right password: a ticket ($t)" || fail "the right password: $out"
f="$T/run/tickets/$t"
if [ -n "$t" ] && [ -f "$f" ]; then
    [ "$(stat -c %a "$T/run/tickets")" = 700 ] && [ "$(stat -c %a "$f")" = 600 ] \
        && pass "...in a directory and a file only the broker's account may read" \
        || fail "modes: $(stat -c %a "$T/run/tickets") $(stat -c %a "$f")"
    grep -qx "uid=$ouid" "$f" && grep -qx "for=$uid" "$f" && grep -q '^expires=[0-9]*$' "$f" \
        && pass "...naming the account ($ouid), the requester ($uid) and a time limit" || fail "ticket: $(cat "$f")"
else fail "no ticket file"; fi
n=$(ls "$T/run/tickets" | wc -l)
out=$(echo "x$PW" | logon "$other")
[ "$out" = "STATUS 1" ] && [ "$(ls "$T/run/tickets" | wc -l)" = "$n" ] && pass "a wrong password: refused, no ticket" \
    || fail "a wrong password: $out"
for who in root "$me" "no-such-user" "../etc"; do
    out=$(echo "$PW" | logon "$who")
    [ "$out" = "STATUS 1" ] && pass "$who, with the password: refused" || fail "$who: $out"
done
grep -q "^stained-glass-logon $other$" "$T/pam-calls" && ! grep -qv "^stained-glass-logon " "$T/pam-calls" \
    && pass "PAM is asked under the service stained-glass-logon" || fail "PAM calls: $(cat "$T/pam-calls")"

# the Security log: 4624 for the success, 4625 for each failure, naming the
# account and the requester and its program
ok=$(grep -l '^ID 4624$' "$T"/audit/*.evt 2>/dev/null | head -1)
[ -n "$ok" ] && grep -qx "STRING $other" "$ok" && grep -q "^STRING LogonUser by $me, C:.test.checker.exe (pid [0-9]*)$" "$ok" \
    && pass "a success is in the Security log (4624: $other, by $me and its program)" || fail "4624: $(cat $ok 2>/dev/null)"
nf=$(grep -l '^ID 4625$' "$T"/audit/*.evt 2>/dev/null | wc -l)
[ "$nf" -ge 5 ] && pass "each failure is (4625, $nf of them)" || fail "4625 events: $nf"

# one requester that fails too often: refused for a while, PAM not asked
# (4 failures so far with SG_LOGON_FAILURES=4 -- the wrong password, root
# and two more -- then even the right password)
calls=$(wc -l < "$T/pam-calls")
out=$(echo "$PW" | logon "$other")
[ "$out" = "STATUS 1" ] && [ "$(wc -l < "$T/pam-calls")" = "$calls" ] \
    && pass "after too many failures the requester is refused, without asking PAM" \
    || fail "after too many failures: $out ($(wc -l < "$T/pam-calls") PAM calls, were $calls)"

if grep -rqF "$PW" "$T/brokerd.log" "$T/run/tickets" "$T/audit" 2>/dev/null; then fail "the password is in a log, a ticket or the Security log"
else pass "the password is in no ticket, no log and not in the Security log"; fi

echo
[ $RC = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $RC
