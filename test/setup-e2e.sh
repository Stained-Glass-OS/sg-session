#!/bin/sh
# The setup wizard, end to end on this machine: the real wizard under Wine on
# a private X server, the real bridge, the real sg-installd -- and a stand-in
# for sg-install that records what it was asked to do, since erasing a disk is
# the image gate's job (sg-image: make install-test).
#
# Driven from the keyboard, as remote support and the image gate drive it.
#
#   - a password typed twice differently is refused, and nothing is installed
#   - Enter on the "Ready to install" page presses Back, where the focus is
#   - the right disk, account, full name, PC name and password reach
#     sg-install, with the password on its stdin and nowhere on its command
#   - progress is shown, then "Restart now" asks for a restart
#
# Needs xvfb-run, xdotool, python3, wine and the built wizard and bridge.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
BUILD="$HERE/build"
RC=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; RC=1; }

for t in xvfb-run xdotool python3 wine; do
    command -v "$t" >/dev/null || { echo "SKIP: $t not installed"; exit 77; }
done
if [ ! -f "$BUILD/sg-setup64.exe" ] || [ ! -x "$BUILD/sg-setup-bridge" ]; then echo "SKIP: run 'make greeter' first"; exit 77; fi

T=$(mktemp -d /var/tmp/sg-setup-e2e.XXXXXX)
export WINEPREFIX="$T/prefix" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml="
# shellcheck disable=SC2317  # invoked via trap
cleanup() {
    [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null
    wineserver -k 2>/dev/null
    rm -rf "$T"
}
trap cleanup EXIT INT TERM

# The stand-in for sg-install, and for systemctl.
cat > "$T/sg-install" <<'EOS'
#!/bin/sh
if [ "$1" = --list ]; then printf '/dev/vdz\t25769803776\tQEMU HARDDISK\n'; exit 0; fi
printf '%s\n' "$@" > "$SG_T/install-args"
IFS= read -r pw; printf '%s' "$pw" > "$SG_T/install-password"
for p in 5 10 70 85 95; do echo "PROGRESS $p step $p"; sleep 0.3; done
echo "PROGRESS 100 Installed."
EOS
cat > "$T/systemctl" <<'EOS'
#!/bin/sh
echo "$@" >> "$SG_T/systemctl.log"
EOS
chmod +x "$T/sg-install" "$T/systemctl"

# sg-installd behind a socket, one instance per connection, as systemd would.
SOCK="$T/installd.sock"
SG_T=$T SG_INSTALL="$T/sg-install" SG_SYSTEMCTL="$T/systemctl" SG_INSTALLD_TEST=1 SG_INSTALLD_LOCK="$T/lock" \
python3 - "$SOCK" "$HERE/setup/sg-installd" 2>"$T/installd.log" <<'EOS' &
import os, socket, subprocess, sys
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(4)
while True:
    c, _ = s.accept()
    subprocess.Popen([sys.argv[2]], stdin=c.fileno(), stdout=c.fileno()); c.close()
EOS
SRV=$!
export SG_T="$T"

wineboot -i >/dev/null 2>&1
wineserver -w

cat > "$T/drive.sh" <<'EOS'
#!/bin/sh
# Runs inside xvfb-run.
set -u
SG_INSTALLD_SOCK="$SOCK" "$BRIDGE" "wine $EXE" 2>"$T/bridge.log" &
B=$!
w=0; until grep -q 'setup ready' "$T/bridge.log" 2>/dev/null; do
    sleep 0.5; w=$((w + 1)); [ "$w" -lt 120 ] || { echo "the wizard did not come up"; exit 1; }
done
sleep 1
k() { xdotool key --delay 80 "$@"; sleep 0.4; }
ty() { xdotool type --delay 60 "$1"; sleep 0.3; }
shot() { import -window root "$T/$1.png" 2>/dev/null; }
# Wait for the Nth time the wizard reports page $1.
page() {
    w=0; until [ "$(grep -c "page $1\$" "$T/bridge.log")" -ge "${2:-1}" ]; do
        sleep 0.3; w=$((w + 1)); [ "$w" -lt 100 ] || { echo "never reached page $1 (#${2:-1})"; shot "stuck-$1"; exit 1; }
    done
    sleep 0.5
}
page welcome; shot welcome
k Return                         # Install now
page disk
w=0; until grep -q . "$T/installd.log" 2>/dev/null || [ "$w" -gt 10 ]; do sleep 0.3; w=$((w + 1)); done
sleep 1; shot disk
k Return                         # Next, with the first disk chosen
page account
ty 'Alice Owner'; k Tab; ty alice; k Tab; ty 'right4pass'; k Tab; ty 'wrong4pass'; k Tab; ty sg-installed
k Return                         # the passwords differ: refused, focus on the cleared confirm field
sleep 1; shot mismatch
grep -c 'page ready$' "$T/bridge.log" > "$T/ready-after-mismatch"
ty 'right4pass'
k Return                         # Next
page ready; shot ready
k Return                         # focus is on Back
page account 2
echo "after-back $(test -e "$T/install-args" && echo installed || echo nothing)" > "$T/after-back"
k Return                         # Next again: the fields kept what was typed
page ready 2
k Tab; k Return                  # from Back to Install
page installing
page done; shot done
k Return                         # Restart now
sleep 2
kill $B 2>/dev/null
EOS
chmod +x "$T/drive.sh"
export T SOCK BRIDGE="$BUILD/sg-setup-bridge" EXE="$BUILD/sg-setup64.exe"
timeout 300 xvfb-run -a -s "-screen 0 1280x800x24" "$T/drive.sh"
mkdir -p "$BUILD/artifacts-setup"; cp "$T"/*.png "$BUILD/artifacts-setup/" 2>/dev/null

if [ "$(cat "$T/ready-after-mismatch" 2>/dev/null)" = 0 ]; then pass "a password typed twice differently is refused"
else fail "mismatched passwords reached the ready page"; fi
if grep -q '^after-back nothing' "$T/after-back" 2>/dev/null; then pass "Enter on 'Ready to install' presses Back and installs nothing"
else fail "the ready page installed on Enter: $(cat "$T/after-back" 2>/dev/null)"; fi
if [ -f "$T/install-args" ]; then
    args=$(tr '\n' ' ' < "$T/install-args")
    case "$args" in
        *"--disk /dev/vdz --user alice --hostname sg-installed --full-name Alice Owner --password-stdin --yes"*)
            pass "sg-install got the disk, account, PC name and full name" ;;
        *) fail "sg-install arguments: $args" ;;
    esac
    case "$args" in *right4pass*|*wrong4pass*) fail "the password is on sg-install's command line" ;;
        *) pass "the password is not on the command line" ;; esac
    if [ "$(cat "$T/install-password")" = right4pass ]; then pass "the password reached sg-install on stdin"
    else fail "password on stdin: '$(cat "$T/install-password")'"; fi
else
    fail "sg-install was never run"
fi
if grep -qx reboot "$T/systemctl.log" 2>/dev/null; then pass "'Restart now' restarts"
else fail "no restart: $(cat "$T/systemctl.log" 2>/dev/null)"; fi
if grep -q 'right4pass\|wrong4pass' "$T/bridge.log" "$T/installd.log"; then fail "a password was logged"
else pass "no password in the logs"; fi

echo
if [ "$RC" -eq 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; cat "$T/bridge.log" "$T/installd.log"; fi
exit "$RC"
