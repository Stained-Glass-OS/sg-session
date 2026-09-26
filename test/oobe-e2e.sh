#!/bin/sh
# The first-run setup (OOBE), end to end on this machine: the real wizard
# under Wine on a private X server, the real bridge (--oobe), the real
# sg-oobed -- with stand-ins for what would change this machine: sg-netctl,
# nmcli, the account tools, systemctl, and the HKLM import (a recorder).
#
# Driven from the keyboard, as remote support and the image gate drive it.
#
# First run -- an owner exists (Setup made one), online:
#   - the region preselected from Setup's keyboard; United Kingdom chosen
#   - US keyboard, a second layout (German) added
#   - a Wi-Fi network joined with its key: the key on sg-netctl's stdin only
#   - no account page; Location switched on; Firefox chosen
#   - applied: the keyboard file (us,de, Start key + Space), the
#     choices record, HKLM's ConsentStore and no diagnostic data, the browser
#     service started, the pending marker gone, the window closed
# Second run -- no administrator, offline, no networks:
#   - the network page can be skipped, the account page appears; mismatched
#     passwords are refused; the account is made in the right groups with its
#     password on chpasswd's stdin
#   - offline, no browser can be chosen: none is installed
# And sg-oobed on its own: nothing once the first-run setup is done, and a
# value outside its lists is refused with nothing written.
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
if [ ! -f "$BUILD/sg-oobe64.exe" ] || [ ! -x "$BUILD/sg-setup-bridge" ]; then echo "SKIP: run 'make greeter' first"; exit 77; fi

T=$(mktemp -d /var/tmp/sg-oobe-e2e.XXXXXX)
export WINEPREFIX="$T/prefix" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml="
# shellcheck disable=SC2317  # invoked via trap
cleanup() {
    [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null
    wineserver -k 2>/dev/null
    rm -rf "$T"
}
trap cleanup EXIT INT TERM
mkdir -p "$T/bin" "$T/etc/default" "$T/etc/stained-glass"

# --- stand-ins -------------------------------------------------------------------
cat > "$T/bin/sg-netctl" <<'EOS'
#!/bin/sh
echo "$*" >> "$SG_T/netctl.log"
[ -f "$SG_T/offline" ] && { echo OK; exit 0; }
case "$1 $2" in
"adapters "*) printf 'ADAPTER eth0\nTYPE ethernet\nSTATE connected\nEND\nADAPTER wlan0\nTYPE wifi\nSTATE disconnected\nEND\nOK\n' ;;
"wifi scan")
    j=no; [ -f "$SG_T/joined" ] && j=yes
    printf 'WIFI 80\twpa-psk\t%s\tno\t486f6d654e6574\tHomeNet\n' "$j"
    printf 'WIFI 40\tenterprise\tno\tno\t436f7270\tCorp\n'
    printf 'WIFI 30\topen\tno\tno\t43616665\tCafe\n'
    echo OK ;;
"wifi connect")
    IFS= read -r key; printf '%s' "$key" > "$SG_T/wifi-key"; touch "$SG_T/joined"
    echo "CONNECTED wlan0"; echo OK ;;
esac
EOS
cat > "$T/bin/nmcli" <<'EOS'
#!/bin/sh
if [ -f "$SG_T/offline" ]; then echo none; else echo full; fi
EOS
cat > "$T/bin/getent" <<'EOS'
#!/bin/sh
case "$1 $2" in
"group sg-admins") if [ -f "$SG_T/no-admin" ]; then echo 'sg-admins:x:990:'; else echo 'sg-admins:x:990:alice'; fi ;;
"group sgwine") echo 'sgwine:x:991:' ;;
"group sudo") echo 'sudo:x:27:' ;;
"passwd alice") [ -f "$SG_T/no-admin" ] || echo 'alice:x:1000:1000:Alice:/home/alice:/bin/bash' ;;
"passwd "*) exit 2 ;;
*) exit 2 ;;
esac
EOS
cat > "$T/bin/useradd" <<'EOS'
#!/bin/sh
printf '%s\n' "$@" > "$SG_T/useradd-args"
EOS
cat > "$T/bin/chpasswd" <<'EOS'
#!/bin/sh
cat > "$SG_T/chpasswd-in"
EOS
cat > "$T/bin/userdel" <<'EOS'
#!/bin/sh
echo "$*" >> "$SG_T/userdel.log"
EOS
cat > "$T/bin/systemctl" <<'EOS'
#!/bin/sh
echo "$*" >> "$SG_T/systemctl.log"
EOS
cat > "$T/bin/hklm" <<'EOS'
#!/bin/sh
cp "$1" "$SG_T/hklm.reg"
EOS
chmod +x "$T"/bin/*
printf 'XKBMODEL="pc105"\nXKBLAYOUT="us"\nXKBVARIANT=""\nXKBOPTIONS=""\nBACKSPACE="guess"\n' > "$T/etc/default/keyboard"
# As on Debian: vconsole.conf is a link to the keyboard file (the first image
# run found sg-oobed writing KEYMAP= through it over the layouts).
ln -s default/keyboard "$T/etc/vconsole.conf"

# sg-oobed behind a socket, one instance per connection, as systemd would.
SOCK="$T/oobed.sock"
PATH="$T/bin:$PATH" SG_T=$T SG_NETCTL="$T/bin/sg-netctl" SG_SYSTEMCTL="$T/bin/systemctl" \
SG_GETENT="$T/bin/getent" SG_USERADD="$T/bin/useradd" SG_USERDEL="$T/bin/userdel" SG_CHPASSWD="$T/bin/chpasswd" \
SG_OOBE_HKLM_IMPORT="$T/bin/hklm" SG_OOBE_PENDING="$T/etc/stained-glass/oobe.pending" \
SG_OOBE_CONF="$T/etc/stained-glass/oobe.conf" SG_OOBE_ETC="$T/etc" SG_OOBE_BROWSER_REQ="$T/oobe-browser" \
python3 - "$SOCK" "$HERE/setup/sg-oobed" 2>"$T/oobed.log" <<'EOS' &
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
# Runs inside xvfb-run. $1: which run.
set -u
LOG="$T/bridge-$1.log"
SG_OOBED_SOCK="$SOCK" "$BRIDGE" --oobe "wine $EXE" 2>"$LOG" &
B=$!
w=0; until grep -q 'oobe ready' "$LOG" 2>/dev/null; do
    sleep 0.5; w=$((w + 1)); [ "$w" -lt 120 ] || { echo "the first-run setup did not come up"; exit 1; }
done
sleep 1
k() { xdotool key --delay 80 "$@"; sleep 0.4; }
ty() { xdotool type --delay 60 "$1"; sleep 0.3; }
shot() { import -window root "$T/$1-$2.png" 2>/dev/null; }
page() {
    w=0; until [ "$(grep -c "page $1\$" "$LOG")" -ge "${2:-1}" ]; do
        sleep 0.3; w=$((w + 1)); [ "$w" -lt 100 ] || { echo "never reached page $1"; shot "$RUN" "stuck-$1"; exit 1; }
    done
    sleep 0.6
}
# Press key $1 until the wizard logs "selected $2".
choose() {
    n=0; until grep 'sg-oobe: selected' "$LOG" | tail -1 | grep -q "selected $2\$"; do
        k "$1"; n=$((n + 1)); [ "$n" -lt 40 ] || { echo "could not select $2"; return 1; }
    done
}
RUN=$1
if [ "$1" = first ]; then
    page region; w=0; until grep -q 'sg-oobe: state' "$LOG" || [ "$w" -gt 30 ]; do sleep 0.3; w=$((w + 1)); done
    sleep 0.5; shot first region
    grep 'selected' "$LOG" | tail -1 > "$T/region-default"
    choose u 'United Kingdom'
    k Return
    page keyboard; shot first keyboard
    k Return                           # Yes: US
    page second-keyboard; shot first second-keyboard
    k Return                           # Add layout
    page second-keyboard-pick
    choose g German; shot first second-pick
    k Return
    page network
    w=0; until grep -q 'sg-oobe: networks' "$LOG" || [ "$w" -gt 40 ]; do sleep 0.3; w=$((w + 1)); done
    sleep 0.5; shot first network
    choose Down HomeNet
    sleep 0.5; shot first network-key
    k Tab; ty 'wifikey4321'           # the key field
    k Return                           # Connect
    w=0; until grep -q 'sg-oobe: connected' "$LOG" || [ "$w" -gt 40 ]; do sleep 0.3; w=$((w + 1)); done
    w=0; until [ "$(grep -c 'sg-oobe: networks' "$LOG")" -ge 2 ] || [ "$w" -gt 40 ]; do sleep 0.3; w=$((w + 1)); done
    sleep 0.5; shot first network-joined
    k Return                           # Next
    page privacy; shot first privacy
    k space                            # Location on
    sleep 0.3; shot first privacy-location
    k Return                           # Accept
    page browser; shot first browser
    k Return                           # Next, with Firefox
    page applying
    w=0; until grep -q 'page done$' "$LOG" || [ "$w" -gt 60 ]; do sleep 0.3; w=$((w + 1)); done
    shot first done
else
    page region
    w=0; until grep -q 'sg-oobe: state' "$LOG" || [ "$w" -gt 30 ]; do sleep 0.3; w=$((w + 1)); done
    k Return; page keyboard
    k Return; page second-keyboard
    k Tab; k Tab; sleep 0.3; shot second skip-focus
    grep -q 'page network$' "$LOG" || k Return
    page network
    w=0; until grep -q 'sg-oobe: networks' "$LOG" || [ "$w" -gt 40 ]; do sleep 0.3; w=$((w + 1)); done
    sleep 0.5; shot second network-offline
    k Return                           # Next is off while offline: nothing
    sleep 1; grep -c 'page account$' "$LOG" > "$T/account-before-skip"
    k Tab; k Return                    # Skip for now
    page account; shot second account
    ty 'Bob Owner'; k Tab; ty 'right4pass'; k Tab; ty 'wrong4pass'
    k Return
    sleep 1.5; shot second mismatch
    grep -c 'page privacy$' "$LOG" > "$T/privacy-after-mismatch"
    ty 'right4pass'; k Return
    page privacy; shot second privacy
    k Return                           # Accept as they are
    page browser; shot second browser-offline
    k Return
    page applying
    w=0; until grep -q 'page done$' "$LOG" || [ "$w" -gt 60 ]; do sleep 0.3; w=$((w + 1)); done
fi
# The window closes by itself after "All set."
w=0; while kill -0 $B 2>/dev/null && [ "$w" -lt 40 ]; do sleep 0.5; w=$((w + 1)); done
if kill -0 $B 2>/dev/null; then echo "still open" > "$T/closed-$1"; kill $B; else echo closed > "$T/closed-$1"; fi
EOS
chmod +x "$T/drive.sh"
export T SOCK BRIDGE="$BUILD/sg-setup-bridge" EXE="$BUILD/sg-oobe64.exe"

# --- first run ---------------------------------------------------------------------
: > "$T/etc/stained-glass/oobe.pending"
timeout 300 xvfb-run -a -s "-screen 0 1280x800x24" "$T/drive.sh" first
L="$T/bridge-first.log"
conf="$T/etc/stained-glass/oobe.conf"
if grep -q 'selected United States$' "$T/region-default" 2>/dev/null; then pass "the region is preselected from Setup's keyboard (US: United States)"
else fail "region preselection: $(cat "$T/region-default" 2>/dev/null)"; fi
get() { sed -n "s/^$1=//p" "$conf" 2>/dev/null; }
if [ "$(get REGION_LOCALE) $(get REGION_GEO)" = "en-GB 242" ]; then pass "the region chosen is recorded: en-GB, country 242"
else fail "region: '$(get REGION_LOCALE) $(get REGION_GEO)'"; fi
if grep -qx 'XKBLAYOUT="us,de"' "$T/etc/default/keyboard" && grep -qx 'XKBOPTIONS="grp:win_space_toggle"' "$T/etc/default/keyboard" \
        && [ -L "$T/etc/vconsole.conf" ]; then
    pass "the keyboard: US and German, switched with Start key + Space; Debian's vconsole.conf link kept"
else fail "keyboard: $(cat "$T/etc/default/keyboard" 2>/dev/null)"; fi
if grep -q 'wifi connect --ssid-hex 486f6d654e6574 --security wpa-psk --password-stdin' "$T/netctl.log" \
        && [ "$(cat "$T/wifi-key" 2>/dev/null)" = wifikey4321 ]; then
    pass "the Wi-Fi network was joined through sg-netctl with its key on stdin"
else fail "Wi-Fi join: $(grep connect "$T/netctl.log" 2>/dev/null) key='$(cat "$T/wifi-key" 2>/dev/null)'"; fi
if grep -q wifikey4321 "$T/netctl.log" "$L" "$T/oobed.log"; then fail "the Wi-Fi key is on a command line or in a log"
else pass "the Wi-Fi key is in no log and on no command line"; fi
if ! grep -q 'page account$' "$L"; then pass "with an owner already made by Setup, there is no account page"
else fail "the account page appeared although there is an administrator"; fi
if [ "$(get LOCATION)$(get MICROPHONE)$(get TAILORED)$(get ADVERTISING)" = 1100 ] && [ "$(get DIAGNOSTICS)" = none ]; then
    pass "privacy: location on (switched), microphone on, tailored experiences and advertising ID off, no diagnostic data"
else fail "privacy: $(grep -E 'LOCATION|MICRO|TAILOR|ADVERT|DIAG' "$conf" 2>/dev/null | paste -sd' ')"; fi
if grep -q 'microphone\]' "$T/hklm.reg" 2>/dev/null && grep -A1 'microphone\]' "$T/hklm.reg" | grep -q '"Value"="Allow"' \
        && grep -A1 'location\]' "$T/hklm.reg" | grep -q '"Value"="Allow"' && grep -q '"AllowTelemetry"=dword:00000000' "$T/hklm.reg"; then
    pass "HKLM gets the device's microphone and location switches and AllowTelemetry 0"
else fail "HKLM: $(cat "$T/hklm.reg" 2>/dev/null)"; fi
if [ "$(get BROWSER)" = Mozilla.Firefox ] && [ "$(cat "$T/oobe-browser" 2>/dev/null)" = Mozilla.Firefox ] \
        && grep -qx 'start --no-block sg-oobe-browser.service' "$T/systemctl.log" 2>/dev/null; then
    pass "Firefox, chosen, is handed to the browser installation service"
else fail "browser: conf '$(get BROWSER)' request '$(cat "$T/oobe-browser" 2>/dev/null)' systemctl '$(cat "$T/systemctl.log" 2>/dev/null)'"; fi
if [ ! -e "$T/etc/stained-glass/oobe.pending" ] && [ "$(cat "$T/closed-first" 2>/dev/null)" = closed ]; then
    pass "done: the pending marker is gone and the first-run setup closed itself"
else fail "after finishing: pending $(test -e "$T/etc/stained-glass/oobe.pending" && echo still there) window $(cat "$T/closed-first" 2>/dev/null)"; fi

# --- second run: no administrator, offline -----------------------------------------------
: > "$T/etc/stained-glass/oobe.pending"; : > "$T/no-admin"; : > "$T/offline"; rm -f "$T/systemctl.log" "$T/oobe-browser"
timeout 300 xvfb-run -a -s "-screen 0 1280x800x24" "$T/drive.sh" second
L="$T/bridge-second.log"
if [ "$(cat "$T/account-before-skip" 2>/dev/null)" = 0 ] && grep -q 'page account$' "$L"; then
    pass "offline, Next does nothing on the network page and 'Skip for now' goes on; with no administrator the account page appears"
else fail "network skip / account page: before-skip '$(cat "$T/account-before-skip" 2>/dev/null)'"; fi
if [ "$(cat "$T/privacy-after-mismatch" 2>/dev/null)" = 0 ]; then pass "passwords typed differently are refused"
else fail "a password mismatch was accepted"; fi
args=$(tr '\n' ' ' < "$T/useradd-args" 2>/dev/null)
case "$args" in
    "-m -s /bin/bash -c Bob Owner -G sgwine,sg-admins,sudo bob ") pass "the owner's account is made: bob, 'Bob Owner', an administrator" ;;
    *) fail "useradd: '$args'" ;;
esac
if [ "$(cat "$T/chpasswd-in" 2>/dev/null)" = "bob:right4pass" ]; then pass "its password reached chpasswd on stdin"
else fail "chpasswd got '$(cat "$T/chpasswd-in" 2>/dev/null)'"; fi
if grep -q 'right4pass\|wrong4pass' "$L" "$T/oobed.log" "$T/useradd-args"; then fail "a password was logged"
else pass "no password in the logs or on a command line"; fi
if [ "$(get BROWSER)" = none ] && [ ! -e "$T/oobe-browser" ] && ! grep -q sg-oobe-browser "$T/systemctl.log" 2>/dev/null \
        && [ "$(get LOCATION)$(get MICROPHONE)" = 01 ]; then
    pass "offline, no browser is installed; privacy accepted as offered (location off, microphone on)"
else fail "second run: browser '$(get BROWSER)' location/mic '$(get LOCATION)$(get MICROPHONE)'"; fi
if grep -qx 'XKBLAYOUT="us"' "$T/etc/default/keyboard" && grep -qx 'XKBOPTIONS=""' "$T/etc/default/keyboard"; then
    pass "one layout: no switching option"
else fail "keyboard: $(cat "$T/etc/default/keyboard")"; fi

# --- sg-oobed on its own -----------------------------------------------------------------
oobed() {
    PATH="$T/bin:$PATH" SG_T=$T SG_NETCTL="$T/bin/sg-netctl" SG_SYSTEMCTL="$T/bin/systemctl" SG_GETENT="$T/bin/getent" \
    SG_OOBE_HKLM_IMPORT="$T/bin/hklm" SG_OOBE_PENDING="$T/etc/stained-glass/oobe.pending" \
    SG_OOBE_CONF="$T/etc/stained-glass/oobe.conf" SG_OOBE_ETC="$T/etc" SG_OOBE_BROWSER_REQ="$T/oobe-browser" \
    "$HERE/setup/sg-oobed" 2>/dev/null
}
out=$(printf 'STATE\n' | oobed | head -1)
case "$out" in "FAILED The first-run setup is already done.") pass "once done, sg-oobed does nothing" ;;
    *) fail "sg-oobed after done: $out" ;; esac
: > "$T/etc/stained-glass/oobe.pending"
cp "$T/etc/default/keyboard" "$T/kbd-before"
out=$(printf 'FINISH en-US\t244\tus;touch /tmp/x\t0\t1\t0\t0\tnone\nFINISH en-US\t244\tus\t0\t1\t0\t0\tEvil.Browser\nFINISH en-US\t244\tzz\t0\t1\t0\t0\tnone\n' | oobed | paste -sd'|')
case "$out" in "HELLO|FAILED That keyboard layout is not known.|FAILED That browser is not offered.|FAILED That keyboard layout is not known.")
    pass "sg-oobed refuses a layout or browser outside its lists" ;; *) fail "sg-oobed validation: $out" ;; esac
if cmp -s "$T/kbd-before" "$T/etc/default/keyboard" && [ -e "$T/etc/stained-glass/oobe.pending" ]; then pass "and writes nothing then"
else fail "a refused request changed something"; fi

rm -rf "$BUILD/artifacts-oobe"; mkdir -p "$BUILD/artifacts-oobe"; cp "$T"/*.png "$BUILD/artifacts-oobe/" 2>/dev/null
echo
if [ "$RC" -eq 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; cat "$T"/bridge-*.log "$T/oobed.log"; fi
exit "$RC"
