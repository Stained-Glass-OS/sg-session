#!/bin/sh
# Remote support (ADR 0010 pattern A), end to end: a VNC server installed as a
# Windows service sees the console -- the lock screen included -- and the
# technician unlocks it by typing the password through the viewer, as on
# Windows. And nothing else gains that: a program in the person's session,
# or the SYSTEM account outside the Windows services (an elevated program),
# can neither capture the lock screen nor type into it; another account
# cannot reach the compositor's privileged socket at all.
#
# Runs INSIDE a QA VM, as root, with a person signed in at the console
# (sg-session-start, sg-compositor with -R, wine-sg 9624-9626):
#   SG_RS_USER=bob SG_RS_PASSWORD=... SG_RS_MSI=/root/tightvnc-2.8.90-gpl-setup-64bit.msi \
#       sh test/remote-support-gate.sh
# SG_RS_OTHER (default nobody): another account, for the socket check.
# The viewer is test/rfb-client.py on the VM's loopback (the VNC server is
# set to loopback only, no authentication), so no firewall rule is involved.
# Needs: rsprobe.exe beside it or build/rsprobe.exe (make remote-support-probe), grim.
# 77: not in a VM with a session. Never run it on a machine someone uses.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
U=${SG_RS_USER:?SG_RS_USER}
PW=${SG_RS_PASSWORD:?SG_RS_PASSWORD}
MSI=${SG_RS_MSI:-}
OTHER=${SG_RS_OTHER:-nobody}
SYS=${SG_SYSTEM_USER:-sgsystem}
PROBE=${SG_RS_PROBE:-$HERE/rsprobe.exe}
[ -f "$PROBE" ] || PROBE=$HERE/../build/rsprobe.exe
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
info() { echo "info  $*"; }
nap() { python3 -c "import time; time.sleep($1)"; }
[ "$(id -u)" -eq 0 ] || { echo "SKIP: root only"; exit 77; }
systemd-detect-virt -q || { echo "SKIP: not in a VM"; exit 77; }
UID_U=$(id -u "$U") || { echo "SKIP: no $U"; exit 77; }
SEAT=/run/stained-glass-seat/seat0/$UID_U
CTL=$SEAT/control.sock PRIV=$SEAT/priv.sock
[ -S "$CTL" ] && [ -S "$PRIV" ] || { echo "SKIP: $U has no session compositor"; exit 77; }
T=$(mktemp -d /var/tmp/sg-rs-gate.XXXXXX); chmod 755 "$T"
cp "$PROBE" "$T/rsprobe.exe"; chmod 644 "$T/rsprobe.exe"
cleanup() {
    systemctl stop sg-rsgate-elevated 2>/dev/null; systemctl reset-failed sg-rsgate-elevated 2>/dev/null
    rm -rf "$T"
}
trap cleanup EXIT INT TERM

ctl() { python3 -c 'import socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall(sys.argv[2].encode() + b"\n"); print(s.recv(128).decode().strip())' "$CTL" "$1"; }
# as the person, with their session's environment (from their shell's explorer)
EXP=$(pgrep -u "$U" -f 'explorer.exe' | head -1)
[ -n "$EXP" ] || { echo "SKIP: $U has no explorer"; exit 77; }
as_user() {
    # shellcheck disable=SC2046
    runuser -u "$U" -- env $(tr '\0' '\n' < /proc/"$EXP"/environ | grep -E '^(DISPLAY|WAYLAND_DISPLAY|XDG_RUNTIME_DIR|XAUTHORITY|HOME|USER|PATH|WINE[A-Z]*|SG_[A-Z_]*)=' | grep -v '^WINESERVERSOCKET=' | tr '\n' ' ') \
        WINEDEBUG=-all "$@"
}
sys_wine() { runuser -u "$SYS" -- sh -c '. /usr/lib/stained-glass/sg-common.sh; sg_wine_env; export WINEDEBUG=-all; exec "$@"' sh "$@"; }
# the screen as root sees it (the privileged capture): pixel (2,2), the frame's corner
corner() { WAYLAND_DISPLAY="$PRIV" XDG_RUNTIME_DIR=/tmp grim -t ppm - 2>/dev/null | python3 -c 'import sys,re
d=sys.stdin.buffer.read(); m=re.match(rb"P6\s+(\d+)\s+(\d+)\s+(\d+)\s", d)
if not m: print("none"); sys.exit()
w=int(m.group(1)); p=d[m.end():]; o=(2*w+2)*3; print("%02x%02x%02x" % (p[o],p[o+1],p[o+2]))'; }
# a PPM's share of pixels that are not black, in per mille
lit() { python3 -c 'import sys,re
d=open(sys.argv[1],"rb").read(); m=re.match(rb"P6\s+(\d+)\s+(\d+)\s+(\d+)\s", d)
if not m: print(-1); sys.exit()
p=d[m.end():]; n=len(p)//3; lit=sum(1 for i in range(0, n*3, 3*97) if p[i] or p[i+1] or p[i+2])
print(lit*1000//len(range(0, n*3, 3*97)))' "$1" 2>/dev/null || echo -1; }
VIEW="python3 $HERE/rfb-client.py 127.0.0.1:5900"

[ "$(ctl STATUS)" = "OK unlocked" ] || { ctl UNLOCK >/dev/null 2>&1; }

# ---- 1. the VNC server, installed as a service by an administrator (SYSTEM)
if [ -n "$MSI" ] && ! sys_wine wine sc query tvnserver 2>/dev/null | grep -q SERVICE_NAME; then
    cp "$MSI" "$T/tvn.msi"; chmod 644 "$T/tvn.msi"
    sys_wine wine msiexec /i "Z:$T/tvn.msi" /quiet /norestart ADDLOCAL=Server \
        SET_USEVNCAUTHENTICATION=1 VALUE_OF_USEVNCAUTHENTICATION=0 \
        SET_ALLOWLOOPBACK=1 VALUE_OF_ALLOWLOOPBACK=1 SET_LOOPBACKONLY=1 VALUE_OF_LOOPBACKONLY=1 \
        SET_RUNCONTROLINTERFACE=1 VALUE_OF_RUNCONTROLINTERFACE=0 \
        SERVER_REGISTER_AS_SERVICE=1 SERVER_ADD_FIREWALL_EXCEPTION=0 >"$T/msi.log" 2>&1
    info "msiexec: $?"
fi
# TightVNC's defaults, its Desktop Duplication capture (UseD3D) and
# RemoveWallpaper included: wine-sg 9655 (its helper's 32-bit hook loader no
# longer ends the machine's wineserver when it goes, which took the sign-in
# screen and the helpers' displays with it) and sg-d3d's DXVK 0016 / wine-sg
# 9656 (a duplicated frame says it has a dirty rectangle: TightVNC copied
# nothing, its viewers saw black). Settings an earlier run left are removed.
for v in UseD3D RemoveWallpaper; do
    sys_wine wine reg delete 'HKLM\Software\TightVNC\Server' /v $v /f >/dev/null 2>&1
done
SINCE=$(date '+%Y-%m-%d %H:%M:%S')
sys_wine wine sc stop tvnserver >/dev/null 2>&1; nap 4
sys_wine wine sc start tvnserver >/dev/null 2>&1
nap 5
# the desktop helper starts when a viewer connects (TightVNC starts it per connection)
$VIEW hold 25 >/dev/null 2>&1 &
HOLD=$!
for i in $(seq 40); do pgrep -f '^C:.*tvnserver.exe.*-desktopserver' >/dev/null && break; nap 0.5; done
nap 2
H=$(pgrep -f '^C:.*tvnserver.exe.*-desktopserver' | head -1)
if [ -n "$H" ]; then
    pass "the service started its desktop helper for the viewer (pid $H)"
    [ "$(ps -o user= -p "$H")" = "$SYS" ] && pass "...as SYSTEM" || fail "the helper runs as $(ps -o user= -p "$H")"
    grep -q '^0::/system.slice/sg-wineserver.service' /proc/"$H"/cgroup && pass "...in the Windows services' control group" \
        || fail "the helper's cgroup: $(cat /proc/"$H"/cgroup)"
    tr '\0' '\n' < /proc/"$H"/environ | grep -qx "SG_COMPOSITOR_PRIV=$PRIV" && pass "...for $U's compositor (sg-elevated-run --system)" \
        || fail "the helper's SG_COMPOSITOR_PRIV is not $PRIV"
else
    fail "no desktop helper (tvnserver.exe -desktopserver)"
fi
wait "$HOLD" 2>/dev/null
for i in $(seq 30); do $VIEW shot "$T/v0.ppm" 2>"$T/v0.err" && break; nap 2; done
[ -s "$T/v0.ppm" ] && pass "the viewer connects ($(cat "$T/v0.err"))" || fail "the viewer: $(cat "$T/v0.err" 2>/dev/null)"
l=$(lit "$T/v0.ppm")
[ "$l" -gt 300 ] && pass "...and sees the desktop ($l/1000 lit)" || fail "the viewer's picture is $l/1000 lit"
c=$(corner)
[ "$c" = ffb400 ] && pass "the person sees the frame while the screen is captured" || fail "no frame on the screen while captured ($c)"

# ---- 2. locked: the viewer sees the lock screen and unlocks it with the password
ctl LOCK >/dev/null
for i in $(seq 60); do pgrep -f 'sg-greeter64.exe.*/lock' >/dev/null && break; nap 1; done
nap 6
[ "$(ctl STATUS)" = "OK locked" ] && pass "the session is locked" || fail "lock: $(ctl STATUS)"
$VIEW shot "$T/v1.ppm" 2>/dev/null
l=$(lit "$T/v1.ppm")
[ "$l" -gt 300 ] && pass "the viewer sees the lock screen ($l/1000 lit, not black)" || fail "the viewer's lock screen is $l/1000 lit"
cmp -s "$T/v0.ppm" "$T/v1.ppm" && fail "the viewer's picture did not change at the lock" || pass "...a different picture from the desktop"

# the person's own program, now: it must see black and type into nothing
as_user wine "Z:$T/rsprobe.exe" grab >"$T/u.grab" 2>/dev/null
g=$(tr -d '\r' < "$T/u.grab")
case "$g" in "GRAB "*" 0 0") pass "a program in $U's session captures black ($g)";; *) fail "a program in $U's session captured: $g";; esac
as_user wine "Z:$T/rsprobe.exe" type "$PW" >/dev/null 2>&1; nap 4
[ "$(ctl STATUS)" = "OK locked" ] && pass "...and its SendInput of the right password does not unlock" || fail "a session program unlocked the lock screen"
# SYSTEM outside the services (as an elevated program is): the privileged socket, no capture, no input
systemd-run -q --wait --pipe --collect --unit=sg-rsgate-elevated -p User="$SYS" \
    /usr/libexec/stained-glass/sg-elevated-run --system --control "$CTL" --uid "$UID_U" -- \
    sh -c '. /usr/lib/stained-glass/sg-common.sh; sg_wine_env; WINEDEBUG=-all wine "Z:'"$T"'/rsprobe.exe" grab; WINEDEBUG=-all wine "Z:'"$T"'/rsprobe.exe" type "'"$PW"'"' \
    >"$T/e.out" 2>/dev/null
g=$(tr -d '\r' < "$T/e.out" | grep '^GRAB' | head -1)
case "$g" in "GRAB "*" 0 "*) pass "SYSTEM outside the services' group (an elevated program) captures black ($g)";;
    *) fail "SYSTEM outside the services' group captured: '$g'";; esac
nap 3
[ "$(ctl STATUS)" = "OK locked" ] && pass "...and its SendInput does not unlock either" || fail "SYSTEM outside the services' group unlocked the lock screen"
grep -q "without capture or input injection" "$T/e.out" 2>/dev/null || :
# another account: not even the socket
r=$(runuser -u "$OTHER" -- python3 -c 'import socket, struct, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(3)
try:
    s.connect(sys.argv[1]); s.sendall(struct.pack("<IHHI", 1, 1, 12, 2) + struct.pack("<IHHI", 1, 0, 12, 3))
    print("accepted" if s.recv(4096) else "refused")
except (ConnectionResetError, BrokenPipeError, PermissionError): print("refused")
except socket.timeout: print("timeout")' "$PRIV" 2>/dev/null)
[ "$r" = refused ] && pass "another account ($OTHER) cannot connect to $U's privileged socket" || fail "$OTHER on $U's privileged socket: $r"

# the technician: a wrong password first, then the right one
$VIEW key space 2>/dev/null; nap 2
$VIEW type "wrong-$PW" 2>/dev/null; $VIEW key Return 2>/dev/null; nap 6
[ "$(ctl STATUS)" = "OK locked" ] && pass "a wrong password typed through the viewer is refused" || fail "a wrong password unlocked"
$VIEW shot "$T/v2.ppm" 2>/dev/null
$VIEW key Return 2>/dev/null; nap 3
$VIEW type "$PW" 2>/dev/null; $VIEW key Return 2>/dev/null
for i in $(seq 20); do [ "$(ctl STATUS)" = "OK unlocked" ] && break; nap 1; done
[ "$(ctl STATUS)" = "OK unlocked" ] && pass "the password typed through the viewer unlocks the session" || fail "not unlocked: $(ctl STATUS)"
$VIEW shot "$T/v3.ppm" 2>/dev/null
[ "$(lit "$T/v3.ppm")" -gt 300 ] && pass "the viewer sees the desktop again" || fail "the viewer after unlocking: $(lit "$T/v3.ppm")/1000"
journalctl -b --no-pager -o cat 2>/dev/null | grep -q "remote support is capturing the screen" && pass "the capture is in the journal (audit)" \
    || info "no audit line in the journal (compositor log elsewhere?)"
# the viewers are gone: each connection's helper went with its own display and
# its 32-bit hook loader (i0631), the person's shell is still there, and the
# machine's wineserver never counted a hook below zero (9655, i0630)
nap 15
left=$(pgrep -f 'sg-elevated-run --system|hookldr.exe|tvnserver.exe -desktopserver' | wc -l)
[ "$left" -eq 0 ] && pass "no helper, hook loader or helper display is left after the viewers went" \
    || fail "$left helper processes left: $(pgrep -af 'sg-elevated-run --system|hookldr.exe|tvnserver.exe -desktopserver' | cut -c1-80 | tr '\n' ';')"
pgrep -u "$U" -f 'explorer.exe' >/dev/null && pass "$U's shell is still running" || fail "$U's shell is gone"
journalctl -u sg-wineserver --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -q 'below zero\|Assertion' \
    && fail "the machine's wineserver counted a hook below zero: $(journalctl -u sg-wineserver --since "$SINCE" --no-pager -o cat | grep -m1 'below zero\|Assertion')" \
    || pass "the machine's wineserver kept every hook count balanced"
[ -n "${SG_RS_KEEP:-}" ] && cp "$T"/*.ppm /var/tmp/ 2>/dev/null

echo
if [ "$RC" -eq 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; fi
exit "$RC"
