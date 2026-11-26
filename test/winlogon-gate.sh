#!/bin/sh
# A session's winlogon.exe (wine-sg 9657, sg-lockd; i0634): on Windows every
# session has one, running as SYSTEM, and remote-support services (UltraVNC,
# AnyDesk) start their per-session helper with a copy of its token. Here
# sg-lockd starts the stand-in for the session it watches. Proven:
#   - it runs, as the SYSTEM account, in the person's session, once;
#   - a service (SYSTEM, in the services' control group) finds it by name and
#     session, duplicates its token (SYSTEM's, the person's session) and starts
#     a program with it -- which runs in that session;
#   - the person's own program (an administrator's, not elevated) and a
#     standard user cannot open it at all (as on Windows: only SYSTEM and an
#     elevated administrator may), so nobody gains SYSTEM through it;
#   - it ends with the session's watch: restarting sg-lockd leaves one, not two.
#
# Runs INSIDE a QA VM, as root, with a person signed in at the console:
#   SG_WL_USER=sguser sh test/winlogon-gate.sh
# SG_WL_PROBE: winlogon-probe.exe (make winlogon-probe), default beside this
# script or build/. SG_WL_STD: a standard account to try (default: one made
# for the gate, sgwlgate, removed after). 77: not in a VM with a session.
# Mutant: sg-lockd SG_MUTANT_NO_WINLOGON.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
U=${SG_WL_USER:?SG_WL_USER}
SYS=${SG_SYSTEM_USER:-sgsystem}
PROBE=${SG_WL_PROBE:-$HERE/winlogon-probe.exe}
[ -f "$PROBE" ] || PROBE=$HERE/../build/winlogon-probe.exe
RC=0; MADE=""
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
nap() { python3 -c "import time; time.sleep($1)"; }
[ "$(id -u)" -eq 0 ] || { echo "SKIP: root only"; exit 77; }
systemd-detect-virt -q || { echo "SKIP: not in a VM"; exit 77; }
[ -f "$PROBE" ] || { echo "SKIP: no winlogon-probe.exe (make winlogon-probe)"; exit 77; }
id -u "$U" >/dev/null 2>&1 || { echo "SKIP: no $U"; exit 77; }
EXP=$(pgrep -u "$U" -f 'explorer.exe' | head -1)
[ -n "$EXP" ] || { echo "SKIP: $U has no session"; exit 77; }
T=$(mktemp -d /var/tmp/sg-wl-gate.XXXXXX); chmod 755 "$T"
cp "$PROBE" "$T/p.exe"; chmod 644 "$T/p.exe"
STD=${SG_WL_STD:-}
if [ -z "$STD" ]; then
    STD=sgwlgate
    id "$STD" >/dev/null 2>&1 || { useradd -M -d "$T/std" -G sgwine "$STD" && MADE=1; }
    mkdir -p "$T/std"; chown "$STD" "$T/std"
fi
cleanup() {
    [ -n "$MADE" ] && userdel "$STD" 2>/dev/null
    rm -rf "$T"
}
trap cleanup EXIT INT TERM

as_user() {
    # shellcheck disable=SC2046
    runuser -u "$U" -- env $(tr '\0' '\n' < /proc/"$EXP"/environ | grep -E '^(DISPLAY|WAYLAND_DISPLAY|XDG_RUNTIME_DIR|XAUTHORITY|HOME|USER|PATH|WINE[A-Z]*|SG_[A-Z_]*)=' | grep -v '^WINESERVERSOCKET=' | tr '\n' ' ') \
        WINEDEBUG=-all "$@"
}
# as a Windows service would run: SYSTEM, in the services' control group
as_service() {
    sh -c 'echo $$ > /sys/fs/cgroup/system.slice/sg-wineserver.service/cgroup.procs && exec runuser -u "$0" -- sh -c ". /usr/lib/stained-glass/sg-common.sh; sg_wine_env; export WINEDEBUG=-all; exec \"\$@\"" sh "$@"' "$SYS" "$@"
}
as_std() { (cd "$T/std" && runuser -u "$STD" -- env HOME="$T/std" sh -c '. /usr/lib/stained-glass/sg-common.sh; sg_wine_env 2>/dev/null; export WINEDEBUG=-all; exec "$@"' sh "$@"); }
v() { printf '%s\n' "$1" | tr -d '\r' | sed -n "s/^$2 //p" | head -1; }

# ---- 1. it runs, as SYSTEM, once
n=$(pgrep -u "$SYS" -fc 'winlogon.exe')
[ "$n" -eq 1 ] && pass "one winlogon.exe runs, as the SYSTEM account ($SYS)" || fail "$n winlogon.exe processes of $SYS"

# ---- 2. the person's session, from their own program
o=$(cd "$T" && as_user timeout 120 wine "Z:$T/p.exe" winlogon.exe)
S=$(v "$o" ME); S=${S#session }
[ -n "$(v "$o" PROC)" ] && [ -n "$S" ] && [ "$S" != 0 ] && pass "$U's program sees it in the process list ($U's session: $S)" \
    || fail "$U's program: winlogon.exe '$(v "$o" PROC)', its own session '$S'"
[ "$(v "$o" OPEN_LIMITED)" = "0 5" ] && [ "$(v "$o" OPEN_MAX)" = "0 5" ] \
    && pass "$U's own program (an administrator's, not elevated) cannot open it: access denied" \
    || fail "$U's own program opened it (OPEN_LIMITED '$(v "$o" OPEN_LIMITED)' OPEN_MAX '$(v "$o" OPEN_MAX)')"
[ -z "$(v "$o" TOKEN_DUP)" ] || fail "$U's own program got at its token: $(v "$o" TOKEN_DUP)"

# ---- 3. a standard user
o=$(as_std timeout 120 wine "Z:$T/p.exe" winlogon.exe)
[ "$(v "$o" FOUND)" -ge 1 ] 2>/dev/null && [ "$(v "$o" OPEN_LIMITED)" = "0 5" ] && [ "$(v "$o" OPEN_MAX)" = "0 5" ] \
    && pass "a standard user ($STD) cannot open it either" \
    || fail "a standard user: FOUND '$(v "$o" FOUND)' OPEN_LIMITED '$(v "$o" OPEN_LIMITED)' OPEN_MAX '$(v "$o" OPEN_MAX)'"
[ -z "$(v "$o" TOKEN_DUP)" ] || fail "a standard user got at its token: $(v "$o" TOKEN_DUP)"

# ---- 4. a service: duplicates its token and starts a program in the session
o=$(cd "$T" && as_service timeout 180 wine "Z:$T/p.exe" winlogon.exe launch)
P=$(v "$o" PROC)
[ "${P#* }" = "$S" ] && pass "it is in $U's session ($S)" || fail "winlogon.exe (pid session) '$P', $U's session $S"
[ "$(v "$o" OPEN_MAX)" = "1 0" ] && [ "$(v "$o" TOKEN_DUP)" = "1 0" ] && [ "$(v "$o" DUP)" = "1 0" ] \
    && pass "a service opens it and duplicates its token" \
    || fail "a service: OPEN_MAX '$(v "$o" OPEN_MAX)' TOKEN_DUP '$(v "$o" TOKEN_DUP)' DUP '$(v "$o" DUP)'"
[ "$(v "$o" TOKUSER)" = S-1-5-18 ] && [ "$(v "$o" TOKSESSION)" = "$S" ] \
    && pass "...SYSTEM's token, in $U's session ($S)" || fail "its token: user '$(v "$o" TOKUSER)' session '$(v "$o" TOKSESSION)'"
[ "$(v "$o" LAUNCH)" = "1 0" ] && [ "$(v "$o" CHILD)" = "exit 7 session $S" ] \
    && pass "...and starts a program with it, which runs in that session" \
    || fail "a service's program with its token: LAUNCH '$(v "$o" LAUNCH)' CHILD '$(v "$o" CHILD)'"

# ---- 5. it ends with the watch: a restarted sg-lockd leaves one
systemctl restart sg-lockd
for i in $(seq 30); do [ "$(pgrep -u "$SYS" -fc 'winlogon.exe')" -eq 1 ] && break; nap 1; done
nap 3
n=$(pgrep -u "$SYS" -fc 'winlogon.exe')
[ "$n" -eq 1 ] && pass "sg-lockd restarted: still one winlogon.exe (the old one ended)" || fail "after restarting sg-lockd: $n"

echo
if [ "$RC" -eq 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; fi
exit "$RC"
