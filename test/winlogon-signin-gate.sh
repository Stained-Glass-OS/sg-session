#!/bin/sh
# The sign-in screen's winlogon.exe (sg-lockd; i0644): on Windows winlogon.exe
# runs as SYSTEM in every session, the console's before anyone signs in too,
# and a remote-support service (UltraVNC, AnyDesk) at a machine nobody is
# signed in to starts its helper there with a copy of its token. sg-lockd
# keeps the stand-in (wine-sg 9657) in the sign-in screen's session for as
# long as the sign-in screen's compositor is up. Proven:
#   - one winlogon.exe runs, as the SYSTEM account, while nobody is signed in;
#   - it is in the sign-in screen's own session (seen from the sign-in
#     screen's account), and that account cannot open it;
#   - a standard user cannot open it;
#   - a service (SYSTEM, the services' control group) opens it, duplicates its
#     token (SYSTEM's, that session) and starts a program in that session;
#   - a look-alike sign-in screen of another account (anyone in sgwine can make
#     a directory beside the real one) gets none;
#   - restarting sg-lockd leaves one; a sign-in screen that ends takes its
#     winlogon.exe with it, and the next one gets its own.
#
# Runs INSIDE a QA VM, as root, at the sign-in screen (nobody signed in):
#   sh test/winlogon-signin-gate.sh
# SG_WL_PROBE: winlogon-probe.exe (make winlogon-probe), default beside this
# script or build/. SG_WL_STD: a standard account to try (default: one made
# for the gate, sgwlgate, removed after). SG_WL_NO_RESTART=1 skips restarting
# the sign-in screen. 77: not in a VM at the sign-in screen.
# Mutant: sg-lockd SG_MUTANT_NO_GREETER_WINLOGON.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
SYS=${SG_SYSTEM_USER:-sgsystem}
GR=${SG_GREETER_USER:-sggreet}
GDIR=/run/stained-glass-seat/greeter
PROBE=${SG_WL_PROBE:-$HERE/winlogon-probe.exe}
[ -f "$PROBE" ] || PROBE=$HERE/../build/winlogon-probe.exe
RC=0; MADE=""; FAKEPID=""
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
nap() { python3 -c "import time; time.sleep($1)"; }
[ "$(id -u)" -eq 0 ] || { echo "SKIP: root only"; exit 77; }
systemd-detect-virt -q || { echo "SKIP: not in a VM"; exit 77; }
[ -f "$PROBE" ] || { echo "SKIP: no winlogon-probe.exe (make winlogon-probe)"; exit 77; }
GUID=$(id -u "$GR" 2>/dev/null) || { echo "SKIP: no $GR"; exit 77; }
GRP=$(pgrep -u "$GR" -f 'sg-greeter64.exe' | head -1)
[ -n "$GRP" ] || { echo "SKIP: not at the sign-in screen"; exit 77; }
# (the sign-in screen has an explorer.exe of its own: the desktop window)
pgrep -f 'explorer.exe' | while read -r p; do [ "$(stat -c %U /proc/"$p")" = "$GR" ] || echo "$p"; done | grep -q . \
    && { echo "SKIP: someone is signed in"; exit 77; }
T=$(mktemp -d /var/tmp/sg-wls-gate.XXXXXX); chmod 755 "$T"
cp "$PROBE" "$T/p.exe"; chmod 644 "$T/p.exe"
STD=${SG_WL_STD:-}
if [ -z "$STD" ]; then
    STD=sgwlgate
    id "$STD" >/dev/null 2>&1 || { useradd -M -d "$T/std" -G sgwine "$STD" && MADE=1; }
    mkdir -p "$T/std"; chown "$STD" "$T/std"
fi
SUID=$(id -u "$STD")
cleanup() {
    [ -n "$FAKEPID" ] && kill "$FAKEPID" 2>/dev/null
    rm -rf "${GDIR:?}/$SUID"
    [ -n "$MADE" ] && userdel "$STD" 2>/dev/null
    rm -rf "$T"
}
trap cleanup EXIT INT TERM

count() { pgrep -u "$SYS" -fc 'winlogon.exe'; }
# the sign-in screen's own account, with its program's environment
as_greeter() {
    # shellcheck disable=SC2046
    runuser -u "$GR" -- env $(tr '\0' '\n' < /proc/"$GRP"/environ | grep -E '^(DISPLAY|XDG_RUNTIME_DIR|XAUTHORITY|HOME|USER|PATH|WINE[A-Z]*|SG_[A-Z_]*)=' | grep -v '^WINESERVERSOCKET=' | tr '\n' ' ') \
        WINEDEBUG=-all "$@"
}
as_service() {
    sh -c 'echo $$ > /sys/fs/cgroup/system.slice/sg-wineserver.service/cgroup.procs && exec runuser -u "$0" -- sh -c ". /usr/lib/stained-glass/sg-common.sh; sg_wine_env; export WINEDEBUG=-all; exec \"\$@\"" sh "$@"' "$SYS" "$@"
}
as_std() { (cd "$T/std" && runuser -u "$STD" -- env HOME="$T/std" sh -c '. /usr/lib/stained-glass/sg-common.sh; sg_wine_env 2>/dev/null; export WINEDEBUG=-all; exec "$@"' sh "$@"); }
v() { printf '%s\n' "$1" | tr -d '\r' | sed -n "s/^$2 //p" | head -1; }

# ---- 1. it runs, as SYSTEM, once
for i in $(seq 30); do [ "$(count)" -ge 1 ] && break; nap 1; done
n=$(count)
[ "$n" -eq 1 ] && pass "nobody signed in: one winlogon.exe runs, as the SYSTEM account ($SYS)" || fail "$n winlogon.exe processes of $SYS at the sign-in screen"

# ---- 2. the sign-in screen's session, from its own account
o=$(cd "$T" && as_greeter timeout 120 wine "Z:$T/p.exe" winlogon.exe)
S=$(v "$o" ME); S=${S#session }
[ -n "$(v "$o" PROC)" ] && [ -n "$S" ] && [ "$S" != 0 ] && pass "the sign-in screen's account sees it (its own session: $S)" \
    || fail "the sign-in screen's account: winlogon.exe '$(v "$o" PROC)', its own session '$S'"
[ "$(v "$o" OPEN_LIMITED)" = "0 5" ] && [ "$(v "$o" OPEN_MAX)" = "0 5" ] \
    && pass "the sign-in screen's account ($GR) cannot open it: access denied" \
    || fail "$GR opened it (OPEN_LIMITED '$(v "$o" OPEN_LIMITED)' OPEN_MAX '$(v "$o" OPEN_MAX)')"
[ -z "$(v "$o" TOKEN_DUP)" ] || fail "$GR got at its token: $(v "$o" TOKEN_DUP)"

# ---- 3. a standard user
o=$(as_std timeout 120 wine "Z:$T/p.exe" winlogon.exe)
[ "$(v "$o" FOUND)" -ge 1 ] 2>/dev/null && [ "$(v "$o" OPEN_LIMITED)" = "0 5" ] && [ "$(v "$o" OPEN_MAX)" = "0 5" ] \
    && pass "a standard user ($STD) cannot open it" \
    || fail "a standard user: FOUND '$(v "$o" FOUND)' OPEN_LIMITED '$(v "$o" OPEN_LIMITED)' OPEN_MAX '$(v "$o" OPEN_MAX)'"
[ -z "$(v "$o" TOKEN_DUP)" ] || fail "a standard user got at its token: $(v "$o" TOKEN_DUP)"

# ---- 4. a service: duplicates its token and starts a program in that session
o=$(cd "$T" && as_service timeout 180 wine "Z:$T/p.exe" winlogon.exe launch)
P=$(v "$o" PROC)
[ "${P#* }" = "$S" ] && pass "it is in the sign-in screen's session ($S)" || fail "winlogon.exe (pid session) '$P', the sign-in screen's session $S"
[ "$(v "$o" OPEN_MAX)" = "1 0" ] && [ "$(v "$o" TOKEN_DUP)" = "1 0" ] && [ "$(v "$o" DUP)" = "1 0" ] \
    && pass "a service opens it and duplicates its token" \
    || fail "a service: OPEN_MAX '$(v "$o" OPEN_MAX)' TOKEN_DUP '$(v "$o" TOKEN_DUP)' DUP '$(v "$o" DUP)'"
[ "$(v "$o" TOKUSER)" = S-1-5-18 ] && [ "$(v "$o" TOKSESSION)" = "$S" ] \
    && pass "...SYSTEM's token, in the sign-in screen's session ($S)" || fail "its token: user '$(v "$o" TOKUSER)' session '$(v "$o" TOKSESSION)'"
[ "$(v "$o" LAUNCH)" = "1 0" ] && [ "$(v "$o" CHILD)" = "exit 7 session $S" ] \
    && pass "...and starts a program with it, which runs in that session" \
    || fail "a service's program with its token: LAUNCH '$(v "$o" LAUNCH)' CHILD '$(v "$o" CHILD)'"

# ---- 5. a look-alike sign-in screen of another account gets none
runuser -u "$STD" -- mkdir -m 0755 "$GDIR/$SUID"
runuser -u "$STD" -- python3 -c '
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(8)
while True:
    c, _ = s.accept(); c.settimeout(2)
    try: c.recv(64); c.send(b"OK session locked=0 remote=0 shadow=0\n")
    except Exception: pass
' "$GDIR/$SUID/control.sock" &
FAKEPID=$!
systemctl restart sg-lockd
for i in $(seq 30); do [ "$(count)" -ge 1 ] && break; nap 1; done
nap 8
n=$(count)
[ "$n" -eq 1 ] && pass "a look-alike sign-in screen of $STD ($GDIR/$SUID) gets no winlogon.exe; sg-lockd restarted: one" \
    || fail "with a look-alike sign-in screen of $STD, after restarting sg-lockd: $n winlogon.exe"
kill "$FAKEPID" 2>/dev/null; FAKEPID=""; rm -rf "${GDIR:?}/$SUID"

# ---- 6. it ends with the sign-in screen; the next one gets its own
if [ -z "${SG_WL_NO_RESTART:-}" ]; then
    OLD=$(pgrep -u "$SYS" -f 'winlogon.exe' | head -1)
    systemctl restart greetd
    for i in $(seq 60); do
        NEW=$(pgrep -u "$SYS" -f 'winlogon.exe' | head -1)
        [ -n "$NEW" ] && [ "$NEW" != "$OLD" ] && break; nap 2
    done
    nap 5
    n=$(count)
    [ -n "$NEW" ] && [ "$NEW" != "$OLD" ] && ! kill -0 "$OLD" 2>/dev/null && [ "$n" -eq 1 ] \
        && pass "the sign-in screen restarted: its winlogon.exe ended, the new one has its own (one)" \
        || fail "after restarting the sign-in screen: old $OLD new '${NEW:-}' count $n"
fi

echo
if [ "$RC" -eq 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; fi
exit "$RC"
