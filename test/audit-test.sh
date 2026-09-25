#!/bin/sh
# Gate for the Security log's Linux side: sg-audit (pam_exec at session open
# and close) and sg-brokerd (elevation) write audit events into the audit
# spool, which wine-sg's Event Log service imports (0187); the event log files
# are the SYSTEM account's alone at the Linux level (sg-services-start).
#
#   1. sg-audit pam, as root, as pam_exec runs it: a session opening is 4624
#      with Windows' logon type for the PAM service (greetd 2, the lock screen
#      7, Remote Desktop 10) and, for an administrator, 4672; closing is 4634;
#      files are complete (renamed from a dot-name), 0600 and owned by the
#      spool's owner; nothing for a PAM_TYPE other than a session; a spool it
#      cannot write never fails the login (exit 0).
#   2. sg-brokerd (built here, test mode, as root, dropping to this user as
#      its "SYSTEM"): an administrator's consent is 4672; a standard user
#      (SG_OTHER) elevating with an administrator's credentials is 4648 and
#      4672; wrong credentials are 4625, an audit failure -- and the password
#      is never in the spool.
#   3. sg-services-start's protection: winevt/Logs 0700, the files in it 0600.
#   4. End to end (a wine-sg with 0187, SG_WINE): sg-audit's events are in
#      the Security log, worded by wevtsvc.dll.
#
# Needs passwordless sudo, gcc; SG_OTHER (default sgconf). Skips (77) without.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
AUDIT="$HERE/bin/sg-audit"
SG_OTHER=${SG_OTHER:-sgconf}
WINE=${SG_WINE:-/opt/wine-sg/bin/wine}
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
sudo -n true 2>/dev/null || { echo "SKIP: needs passwordless sudo"; exit 77; }
command -v gcc >/dev/null || { echo "SKIP: gcc missing"; exit 77; }
id "$SG_OTHER" >/dev/null 2>&1 || { echo "SKIP: no $SG_OTHER account"; exit 77; }
ME=$(id -un); MYGROUP=$(id -gn)
T=$(mktemp -d /var/tmp/sg-audit.XXXXXX); chmod 755 "$T"
BP=""
cleanup() { [ -n "$BP" ] && sudo -n kill "$BP" 2>/dev/null; sudo -n rm -rf "$T"; [ -n "${WS:-}" ] && WINEPREFIX="$T/pfx" "$WS" -k 2>/dev/null; }
trap cleanup EXIT INT TERM
SPOOL="$T/spool"; mkdir -m 0700 "$SPOOL"
HOSTU=$(hostname | cut -d. -f1 | tr '[:lower:]' '[:upper:]' | cut -c1-15)

pam() {   # PAM_TYPE PAM_SERVICE [admin group]
    sudo -n env PAM_TYPE="$1" PAM_USER="$ME" PAM_SERVICE="$2" PAM_TTY=tty1 SG_AUDIT_SPOOL="$SPOOL" \
        SG_ADMIN_GROUP="${3:-sg-nobody-here}" "$AUDIT" pam
}
events() { for f in "$SPOOL"/*.evt; do [ -f "$f" ] && { cat "$f"; echo "--"; }; done; }
drain() { rm -f "$SPOOL"/*.evt; }

# ---- 1. sg-audit pam ------------------------------------------------------------
pam open_session greetd "$MYGROUP"
e=$(events)
echo "$e" | tr '\n' '|' | grep -q "ID 4624|TYPE success|CATEGORY 12544|TIME [0-9]*|STRING $ME|STRING $HOSTU|STRING 2 (Interactive)|STRING greetd (sign-in screen)|STRING tty1|" \
    && pass "sign-in (greetd): 4624, $ME on $HOSTU, logon type 2 (Interactive)" || fail "4624: $e"
echo "$e" | tr '\n' '|' | grep -q "ID 4672|TYPE success|CATEGORY 12548|.*STRING $ME|.*SeDebugPrivilege" \
    && pass "an administrator's sign-in: 4672 special privileges" || fail "4672: $e"
st=$(stat -c '%a %U' "$SPOOL"/*.evt | sort -u)
[ "$st" = "600 $ME" ] && pass "the files are 0600 and the spool owner's (the service must read and remove them)" || fail "modes: $st"
[ -z "$(ls -A "$SPOOL" | grep -v '\.evt$')" ] && pass "no half-written files left" || fail "left: $(ls -A "$SPOOL")"
drain
pam open_session greetd
[ "$(events | grep -c '^ID 4672')" = 0 ] && pass "a standard user's sign-in: no 4672" || fail "4672 for a standard user"
drain
pam open_session stained-glass-lock
events | grep -q '^STRING 7 (Unlock)$' && pass "unlocking (the lock screen's PAM service): logon type 7" || fail "unlock: $(events)"
drain
pam open_session stained-glass-remote
events | grep -q '^STRING 10 (RemoteInteractive)$' && pass "Remote Desktop: logon type 10" || fail "rdp: $(events)"
drain
pam close_session greetd
events | tr '\n' '|' | grep -q "ID 4634|TYPE success|CATEGORY 12545|.*STRING $ME|" && pass "sign-out: 4634" || fail "4634: $(events)"
drain
sudo -n env PAM_TYPE=auth PAM_USER="$ME" PAM_SERVICE=greetd SG_AUDIT_SPOOL="$SPOOL" "$AUDIT" pam
[ -z "$(ls -A "$SPOOL")" ] && pass "nothing for PAM_TYPE=auth" || fail "auth wrote: $(ls "$SPOOL")"
sudo -n env PAM_TYPE=open_session PAM_USER="$ME" PAM_SERVICE=greetd SG_AUDIT_SPOOL="$T/missing" "$AUDIT" pam 2>/dev/null
[ $? = 0 ] && pass "a spool it cannot write never fails the login (exit 0)" || fail "exit status with no spool"

# ---- 2. sg-brokerd ------------------------------------------------------------------
gcc -O2 -Wall -o "$T/sg-brokerd" "$HERE/broker/sg-brokerd.c" && gcc -O2 -Wall -o "$T/sg-elevate" "$HERE/broker/sg-elevate.c" \
    || { fail "the broker did not build"; exit 1; }
chmod 755 "$T/sg-brokerd" "$T/sg-elevate"
printf '#!/bin/sh\ncat >/dev/null\necho OK\n' > "$T/pam-yes"; printf '#!/bin/sh\ncat >/dev/null\nexit 1\n' > "$T/pam-no"
chmod 755 "$T/pam-yes" "$T/pam-no"
SOCK="$T/broker.sock"
broker() {   # consent pamcheck
    [ -n "$BP" ] && sudo -n kill "$BP" 2>/dev/null; sleep 0.5; sudo -n rm -f "$SOCK"
    sudo -n env SG_BROKER_TEST=1 SG_BROKER_TEST_CONSENT="$1" SG_BROKER_TEST_ADMIN_USER="$ME" \
        SG_BROKER_TEST_ADMIN_PASS=not-in-the-spool SG_BROKER_PAMCHECK="$2" SG_BROKER_SOCK="$SOCK" \
        SG_BROKER_FOREGROUND=1 SG_BROKERD_LOG="$T/broker.log" SG_SYSTEM_USER="$ME" SG_ADMIN_GROUP="$MYGROUP" \
        SG_AUDIT_SPOOL="$SPOOL" "$T/sg-brokerd" >/dev/null 2>&1 &
    BP=$!
    i=0; while [ ! -S "$SOCK" ] && [ $i -lt 30 ]; do sleep 0.2; i=$((i + 1)); done
}
broker yes "$T/pam-no"
SG_BROKER_SOCK="$SOCK" "$T/sg-elevate" -- /bin/true >/dev/null 2>&1; sleep 1
events | tr '\n' '|' | grep -q "ID 4672|TYPE success|CATEGORY 12548|.*STRING $ME|.*SeDebugPrivilege.*|STRING /bin/true|" \
    && pass "an administrator's elevation (consent): 4672 for $ME, the program named" || fail "admin elevation: $(events)"
drain
broker no "$T/pam-yes"
sudo -n -u "$SG_OTHER" env SG_BROKER_SOCK="$SOCK" "$T/sg-elevate" -- /bin/true >/dev/null 2>&1; sleep 1
e=$(events | tr '\n' '|')
echo "$e" | grep -q "ID 4648|TYPE success|.*STRING $SG_OTHER|STRING $HOSTU|STRING $ME|STRING $HOSTU|STRING /bin/true|" \
    && echo "$e" | grep -q "ID 4672|" && pass "a standard user elevating with $ME's credentials: 4648 and 4672" || fail "cred elevation: $e"
drain
broker no "$T/pam-no"
sudo -n -u "$SG_OTHER" env SG_BROKER_SOCK="$SOCK" "$T/sg-elevate" -- /bin/true >/dev/null 2>&1; sleep 3
e=$(events | tr '\n' '|')
echo "$e" | grep -q "ID 4625|TYPE failure|CATEGORY 12544|TIME [0-9]*|STRING $ME|.*Unknown user name or bad password" \
    && pass "wrong credentials: 4625, an audit failure" || fail "4625: $e"
grep -rq not-in-the-spool "$SPOOL" && fail "the password is in the spool" || pass "the password is never in the spool"
drain

# ---- 3. the event logs at the Linux level ------------------------------------------------
P="$T/prefix"; L="$P/drive_c/windows/system32/winevt/Logs"
mkdir -p "$L"; chmod 0775 "$L"; : > "$L/Security.sgevt"; chmod 0660 "$L/Security.sgevt"
sed -n '/^sg_protect_event_logs() {/,/^}/p' "$HERE/bin/sg-services-start" > "$T/fn.sh"
SG_PREFIX="$P" sh -c ". '$T/fn.sh'; sg_protect_event_logs"
[ "$(stat -c %a "$L")" = 700 ] && [ "$(stat -c %a "$L/Security.sgevt")" = 600 ] \
    && pass "sg-services-start: winevt/Logs 0700, Security.sgevt 0600" || fail "modes: $(stat -c '%a %n' "$L" "$L/Security.sgevt")"
sudo -n -u "$SG_OTHER" cat "$L/Security.sgevt" >/dev/null 2>&1 && fail "another user can read the Security log's file" \
    || pass "another user cannot read the Security log's file"

# ---- 4. end to end: into Wine's Security log ------------------------------------------------
WS=$(dirname "$WINE")/wineserver; [ -x "$WS" ] || WS=$(dirname "$WINE")/server/wineserver
PROBE_SRC="$HERE/../wine-sg/test/audit-probe.c"
WEVT=$(dirname "$WINE")/../lib/wine/x86_64-windows/wevtsvc.dll
[ -f "$WEVT" ] || WEVT=$(dirname "$WINE")/dlls/wevtsvc/x86_64-windows/wevtsvc.dll
if [ -x "$WINE" ] && [ -f "$PROBE_SRC" ] && [ -f "$WEVT" ] && grep -qa 'A.u.d.i.t.S.p.o.o.l' "$WEVT" && command -v x86_64-w64-mingw32-gcc >/dev/null; then
    x86_64-w64-mingw32-gcc -O2 -municode -o "$T/audit-probe.exe" "$PROBE_SRC" -ladvapi32
    export WINEPREFIX="$T/pfx" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml="
    "$WINE" wineboot -i >/dev/null 2>&1
    "$WINE" reg add 'HKLM\System\CurrentControlSet\Services\EventLog\Security' /v AuditSpool /d "$SPOOL" /f >/dev/null 2>&1
    "$WINE" net stop eventlog >/dev/null 2>&1
    pam open_session greetd "$MYGROUP"
    "$WINE" net start eventlog >/dev/null 2>&1
    i=0; while ls "$SPOOL"/*.evt >/dev/null 2>&1 && [ $i -lt 30 ]; do sleep 0.5; i=$((i + 1)); done
    "$WINE" "$T/audit-probe.exe" dump 2>/dev/null | tr -d '\r' > "$T/dump.txt"
    grep -q "^MSG An account was successfully logged on\..*Account Name: *$ME.*Logon Type: *2 (Interactive)" "$T/dump.txt" \
        && grep -q '^MSG Special privileges assigned to new logon' "$T/dump.txt" \
        && pass "end to end: the sign-in is in Wine's Security log, worded (4624, 4672)" || fail "end to end: $(cat "$T/dump.txt")"
    "$WS" -k 2>/dev/null
else
    echo "NOTE  end to end skipped: no wine-sg with 0187 at $WINE (SG_WINE)"
fi

[ $RC = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $RC
