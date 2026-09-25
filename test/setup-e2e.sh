#!/bin/sh
# The setup wizard, end to end on this machine: the real wizard under Wine on
# a private X server, the real bridge, the real sg-installd -- and a stand-in
# for sg-install that records what it was asked to do, since erasing a disk is
# the image gate's job (sg-image: make install-test).
#
# Driven from the keyboard, as remote support and the image gate drive it.
#
#   - Next on the license page does nothing until the terms are accepted
#   - a password typed twice differently is refused, and nothing is installed
#   - the partitioner preselects the largest place Stained Glass OS fits; New
#     makes a partition of the size typed in the space chosen, and selects it;
#     Delete, confirmed, deletes the selected partition; nothing else is touched
#   - Enter on the "Ready to install" page presses Back, where the focus is
#   - the right place, account, full name, PC name, keyboard and password
#     reach sg-install, with the password on its stdin and nowhere on its
#     command line
#   - progress is shown, then "Restart now" asks for a restart
#   - "Try Stained Glass OS" closes Setup and leaves the answer for the
#     login screen
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

# The stand-in for sg-install, and for systemctl. It keeps a layout -- a
# "Windows" disk (system, MSR and data partitions, then unallocated space) and
# a blank one -- that New and Delete change, as the real one would.
printf 'DISK /dev/vdz\t26843545600\tQEMU HARDDISK\tgpt
PART /dev/vdz1\t/dev/vdz\t1\t104857600\t-\tsystem\tvfat\tSYSTEM
PART /dev/vdz2\t/dev/vdz\t2\t16777216\t-\tmsr\t-\t-
PART /dev/vdz3\t/dev/vdz\t3\t4294967296\t4000000000\tprimary\tntfs\tWindows
FREE /dev/vdz\t8628224\t43800576\t22425894912
DISK /dev/vdy\t32212254720\tQEMU HARDDISK\tnone
FREE /dev/vdy\t2048\t62910464\t32210157568
' > "$T/layout"
cat > "$T/sg-install" <<'EOS'
#!/bin/sh
case "$1" in
--list) printf '/dev/vdz\t26843545600\tQEMU HARDDISK\n'; exit 0 ;;
--layout) cat "$SG_T/layout"; exit 0 ;;
--new)   # --new DISK --start S --bytes B --yes
    echo "new $2 $4 $6" >> "$SG_T/ops"
    sectors=$(( $6 / 512 ))
    awk -F'\t' -v d="$2" -v s="$4" -v n="$sectors" -v b="$6" 'BEGIN { OFS = "\t" }
        $1 == "FREE " d && $2 == s {
            num = 0
            while ((getline l < ARGV[1]) > 0) if (l ~ "^PART " d) num++
            printf "PART %s%d\t%s\t%d\t%s\t-\tprimary\t-\t-\n", d, num + 1, d, num + 1, b
            if ($3 - n > 32768) printf "FREE %s\t%s\t%s\t%s\n", d, s + n, $3 - n, ($3 - n) * 512
            next
        }
        { print }' "$SG_T/layout" > "$SG_T/layout.new" && mv "$SG_T/layout.new" "$SG_T/layout"
    exit 0 ;;
--delete)
    echo "delete $2" >> "$SG_T/ops"
    awk -F'\t' -v p="$2" '$1 == "PART " p { printf "FREE %s\t1000000\t%d\t%s\n", $2, $4 / 512, $4; next } { print }' \
        "$SG_T/layout" > "$SG_T/layout.new" && mv "$SG_T/layout.new" "$SG_T/layout"
    exit 0 ;;
--format) echo "format $2" >> "$SG_T/ops"; exit 0 ;;
esac
printf '%s\n' "$@" > "$SG_T/install-args"
IFS= read -r pw; printf '%s' "$pw" > "$SG_T/install-password"
for p in 6 30 59 60 75; do echo "PROGRESS $p step $p"; sleep 0.3; done
case " $* " in *" --drivers "*) echo "MOKPASSWORD 12345678" ;; esac
for p in 85 95; do echo "PROGRESS $p step $p"; sleep 0.3; done
echo "PROGRESS 100 Installed."
EOS
cat > "$T/sg-drivers" <<'EOS'
#!/bin/sh
[ "$1" = --list ] && printf 'DEVICE 0000:01:00.0\t10de:1c82\tNVIDIA graphics\tnvidia-driver firmware-misc-nonfree\tNVIDIA driver\n'
exit 0
EOS
chmod +x "$T/sg-drivers"
cat > "$T/systemctl" <<'EOS'
#!/bin/sh
echo "$@" >> "$SG_T/systemctl.log"
EOS
chmod +x "$T/sg-install" "$T/systemctl"

# sg-installd behind a socket, one instance per connection, as systemd would.
SOCK="$T/installd.sock"
SG_T=$T SG_INSTALL="$T/sg-install" SG_DRIVERS="$T/sg-drivers" SG_SYSTEMCTL="$T/systemctl" SG_INSTALLD_TEST=1 SG_INSTALLD_LOCK="$T/lock" \
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
k Return                         # Next
page start; shot start
k Return                         # Install now
page license; shot license
k Return                         # not accepted: Next is disabled, nothing happens
sleep 1
grep -c 'page type$' "$T/bridge.log" > "$T/type-before-accept"
k space; k Return                # accept, Next
page type
w=0; until grep -q 'sg-setup: drivers' "$T/bridge.log" || [ "$w" -gt 30 ]; do sleep 0.3; w=$((w + 1)); done
sleep 0.5; shot type
k Return                         # Custom
page account
ty 'Alice Owner'; k Tab; ty alice; k Tab; ty 'right4pass'; k Tab; ty 'wrong4pass'; k Tab; ty sg-installed
k Return                         # the passwords differ: refused, focus on the cleared confirm field
sleep 1; shot mismatch
grep -c 'page disk$' "$T/bridge.log" > "$T/disk-after-mismatch"
ty 'right4pass'; shot account
k Return                         # Next
page disk
w=0; until grep -q 'sg-setup: selected' "$T/bridge.log" || [ "$w" -gt 40 ]; do sleep 0.3; w=$((w + 1)); done
sleep 1; shot disk
# The largest place is preselected: the blank drive. Up to the Windows drive's
# unallocated space, then New, 15000 MB, Apply.
k Up; sleep 0.5
k Tab; k Tab                     # Refresh, New (Delete and Format are off for unallocated space)
k Return; sleep 0.5; shot new-size
k ctrl+a; ty 15000
k Return                         # Apply
w=0; until grep -q 'selected Drive 0 Partition 4' "$T/bridge.log" || [ "$w" -gt 40 ]; do sleep 0.3; w=$((w + 1)); done
sleep 1; shot after-new
k Return                         # Next, with the new partition
page ready; shot ready-partition
k Return                         # focus is on Back
page disk 2
echo "after-back $(test -e "$T/install-args" && echo installed || echo nothing)" > "$T/after-back"
w=0; until [ "$(grep -c 'sg-setup: layout' "$T/bridge.log")" -ge 3 ] || [ "$w" -gt 40 ]; do sleep 0.3; w=$((w + 1)); done
sleep 1
# Delete the new partition: Home, Down to Partition 4, Tab to Delete, and the
# warning's OK (it opens on Cancel).
k Home; k Down; k Down; k Down; sleep 0.5
k Tab; k Tab                     # Refresh, Delete
k Return; sleep 1; shot delete-warning
k Tab; k Return                  # OK
w=0; until grep -q '^delete' "$T/ops" 2>/dev/null || [ "$w" -gt 40 ]; do sleep 0.3; w=$((w + 1)); done
w=0; until [ "$(grep -c 'sg-setup: layout' "$T/bridge.log")" -ge 4 ] || [ "$w" -gt 40 ]; do sleep 0.3; w=$((w + 1)); done
sleep 1; shot after-delete
k Return                         # Next, with the preselected blank drive
page ready 2; shot ready-free
k Tab; k Return                  # from Back to Install
page installing; sleep 1; shot installing
page done; shot done
sleep 17                         # a Secure Boot password is on the page: no countdown
cp "$T/systemctl.log" "$T/systemctl-before" 2>/dev/null || : > "$T/systemctl-before"
k Return                         # Restart now
sleep 2
kill $B 2>/dev/null
wait $B 2>/dev/null
# "Try Stained Glass OS": the wizard closes and the bridge leaves the answer
# for the login screen, which signs in the live session.
mv "$T/bridge.log" "$T/bridge-install.log"
SG_SETUP_RESULT="$T/result" SG_INSTALLD_SOCK="$SOCK" "$BRIDGE" "wine $EXE" 2>"$T/bridge.log" &
B=$!
page welcome
k Return; page start
k Tab; sleep 0.5; shot try
k Return                         # Try Stained Glass OS without installing it
w=0; while kill -0 $B 2>/dev/null && [ "$w" -lt 60 ]; do sleep 0.5; w=$((w + 1)); done
kill -0 $B 2>/dev/null && { echo "the wizard did not close for Try"; kill $B; }
EOS
chmod +x "$T/drive.sh"
export T SOCK BRIDGE="$BUILD/sg-setup-bridge" EXE="$BUILD/sg-setup64.exe"
timeout 300 xvfb-run -a -s "-screen 0 1280x800x24" "$T/drive.sh"
rm -rf "$BUILD/artifacts-setup"; mkdir -p "$BUILD/artifacts-setup"; cp "$T"/*.png "$BUILD/artifacts-setup/" 2>/dev/null

if [ "$(cat "$T/type-before-accept" 2>/dev/null)" = 0 ]; then pass "the license terms must be accepted before Next"
else fail "Next worked without accepting the license terms"; fi
if [ "$(cat "$T/disk-after-mismatch" 2>/dev/null)" = 0 ]; then pass "a password typed twice differently is refused"
else fail "mismatched passwords reached the disk page"; fi
if grep -m1 'sg-setup: selected' "$T/bridge-install.log" | grep -q 'selected Drive 1 Unallocated Space$'; then
    pass "the largest place Stained Glass OS fits is preselected"
else fail "preselection: $(grep 'selected' "$T/bridge-install.log" | head -1)"; fi
if grep -qx 'new /dev/vdz 8628224 15728640000' "$T/ops" 2>/dev/null; then pass "New made a 15000 MB partition in the unallocated space it was given"
else fail "New: $(cat "$T/ops" 2>/dev/null)"; fi
if grep -q 'selected Drive 0 Partition 4$' "$T/bridge-install.log"; then pass "the new partition is selected after New"
else fail "the new partition was not selected"; fi
if grep -qx 'delete /dev/vdz4' "$T/ops" 2>/dev/null; then pass "Delete, confirmed, deleted the selected partition"
else fail "Delete: $(cat "$T/ops" 2>/dev/null)"; fi
if ! grep -q 'vdz[123]' "$T/ops" 2>/dev/null; then pass "nothing was done to the partitions that were not chosen"
else fail "other partitions touched: $(cat "$T/ops")"; fi
if grep -q '^after-back nothing' "$T/after-back" 2>/dev/null; then pass "Enter on 'Ready to install' presses Back and installs nothing"
else fail "the ready page installed on Enter: $(cat "$T/after-back" 2>/dev/null)"; fi
if [ -f "$T/install-args" ]; then
    args=$(tr '\n' ' ' < "$T/install-args")
    case "$args" in
        *"--free /dev/vdy:2048:62910464 --user alice --hostname sg-installed --full-name Alice Owner --keyboard us --drivers --password-stdin --yes"*)
            pass "sg-install got the place, account, PC name, full name, keyboard and third-party drivers" ;;
        *) fail "sg-install arguments: $args" ;;
    esac
    case "$args" in *right4pass*|*wrong4pass*) fail "the password is on sg-install's command line" ;;
        *) pass "the password is not on the command line" ;; esac
    if [ "$(cat "$T/install-password")" = right4pass ]; then pass "the password reached sg-install on stdin"
    else fail "password on stdin: '$(cat "$T/install-password")'"; fi
else
    fail "sg-install was never run"
fi
if [ "$(cat "$T/result" 2>/dev/null)" = try ]; then pass "'Try Stained Glass OS' closes Setup and asks for the live session"
else fail "Try: '$(cat "$T/result" 2>/dev/null)'"; fi
if grep -q 'sg-setup: drivers NVIDIA graphics (the manufacturer.s driver)' "$T/bridge-install.log"; then
    pass "the installation type page shows what the drivers survey found"
else fail "drivers survey: $(grep 'sg-setup: drivers' "$T/bridge-install.log")"; fi
if ! grep -q reboot "$T/systemctl-before" 2>/dev/null; then pass "with a Secure Boot password to note, Setup does not restart by itself"
else fail "Setup restarted by itself while showing the Secure Boot password"; fi
if grep -q 12345678 "$T/bridge-install.log" "$T/installd.log"; then fail "the Secure Boot password was logged"
else pass "the Secure Boot password is not logged"; fi
if grep -qx reboot "$T/systemctl.log" 2>/dev/null; then pass "'Restart now' restarts"
else fail "no restart: $(cat "$T/systemctl.log" 2>/dev/null)"; fi
if grep -q 'right4pass\|wrong4pass' "$T/bridge-install.log" "$T/bridge.log" "$T/installd.log"; then fail "a password was logged"
else pass "no password in the logs"; fi

echo
if [ "$RC" -eq 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; cat "$T/bridge.log" "$T/installd.log"; fi
exit "$RC"
