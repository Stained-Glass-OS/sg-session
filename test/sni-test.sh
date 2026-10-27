#!/bin/sh
. "$(dirname "$0")/scratch-home.sh"
# sni-test.sh -- Linux programs' tray icons in the taskbar (sg-sni-bridge + sg-shell's sg-sni64.exe).
#
# On a private session bus, under Xvfb, with a scratch Wine prefix whose shell (explorer) owns the
# taskbar: the bridge is the session's StatusNotifierWatcher, a stand-in Linux program
# (test/sni-item.py) registers its item -- a red pixmap, a tooltip, a dbusmenu with a submenu and a
# disabled item -- and the icon program must show it in the notification area with that menu.
# Clicks given to the icon program (the bridge's SG_SNI_BRIDGE_INJECT) must reach the program as
# Activate and SecondaryActivate, a menu item as its dbusmenu "clicked" event; the program quitting
# takes its icon away.
#
#   SG_SNI_EXE    the icon program (default: sg-shell's installed sg-sni64.exe)
#   SG_SNI_MUT    a mutant icon program built with -DSG_MUTANT_SNI_NO_MENU: the gate must fail on it
#   SG_WINE_DIR   the Wine to run (default /opt/wine-sg)
# The bridge's mutant SG_MUTANT_SNI_NO_HOST (no host registered: Qt's X-tray fallback) is run as well.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
EXE=${SG_SNI_EXE:-/usr/libexec/stained-glass/shell/sg-sni64.exe}
W=${SG_WINE_DIR:-/opt/wine-sg}
T=$(mktemp -d /var/tmp/sni-test.XXXXXX)
fails=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails + 1)); }

[ -f "$EXE" ] || { echo "FAIL  no icon program at $EXE"; exit 1; }
command -v dbus-run-session >/dev/null || { echo "FAIL  dbus-run-session missing"; exit 1; }

unset DISPLAY WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS
D=:$((200 + $$ % 300))
Xvfb "$D" -screen 0 1024x768x24 -nolisten tcp >/dev/null 2>&1 &
XP=$!
export DISPLAY=$D HOME=$T/home WINEPREFIX=$T/pfx WINEDLLOVERRIDES="winemenubuilder.exe=d" WINEDEBUG=-all
export PATH="$W/bin:$PATH"
mkdir -p "$HOME"
sleep 1
wineboot -i >/dev/null 2>&1
wineserver -w
rm -f "$WINEPREFIX/dosdevices/z:" 2>/dev/null; ln -s / "$WINEPREFIX/dosdevices/z:"

run_case() { # LABEL EXE [ENV=VALUE] -> leaves $T/<label>.dump, $T/<label>.item, $T/<label>.bridge
    L=$1 X=$2 E=${3:-SG_SNI_NONE=1}
    rm -f "$WINEPREFIX/drive_c/sni.dump" "$T/$L.item" "$T/$L.bridge" "$T/inj"
    mkfifo "$T/inj"
    cp "$X" "$WINEPREFIX/drive_c/sg-sni64.exe"
    cat > "$T/inner.sh" <<EOF
wine explorer.exe /desktop=shell,1024x768 >/dev/null 2>&1 &
sleep 6
$E SG_SNI_DUMP='C:\\sni.dump' SG_SNI_BRIDGE_LOG="$T/$L.bridge" SG_SNI_BRIDGE_INJECT="$T/inj" \\
    /usr/bin/python3 "$HERE/lib/sg-sni-bridge" wine 'C:\\sg-sni64.exe' &
B=\$!
sleep 4
/usr/bin/python3 "$HERE/test/sni-item.py" "$T/$L.item" &
I=\$!
dump() { cat "$WINEPREFIX/drive_c/sni.dump" 2>/dev/null; }
i=0; while [ \$i -lt 60 ] && ! dump | grep -q '^item .* shown=1'; do sleep 0.5; i=\$((i + 1)); done
i=0; while [ \$i -lt 20 ] && ! dump | grep -q '^menu '; do sleep 0.5; i=\$((i + 1)); done
dump > "$T/$L.dump1"
gdbus call --session -d org.kde.StatusNotifierWatcher -o /StatusNotifierWatcher \\
    -m org.freedesktop.DBus.Properties.Get org.kde.StatusNotifierWatcher IsStatusNotifierHostRegistered > "$T/$L.host" 2>&1
K=\$(dump | sed -n 's/^item \\([^ ]*\\) .*/\\1/p' | head -1)
echo "CLICK \$K left" > "$T/inj"; sleep 2
echo "CLICK \$K middle" > "$T/inj"; sleep 2
echo "PICK \$K 3" > "$T/inj"; sleep 2
echo "PICK \$K 5" > "$T/inj"
i=0; while [ \$i -lt 20 ] && kill -0 \$I 2>/dev/null; do sleep 0.5; i=\$((i + 1)); done
i=0; while [ \$i -lt 20 ] && dump | grep -q '^item '; do sleep 0.5; i=\$((i + 1)); done
dump > "$T/$L.dump2"
kill \$I \$B 2>/dev/null
wineserver -k
EOF
    timeout 120 dbus-run-session -- sh "$T/inner.sh" >/dev/null 2>&1
}

run_case real "$EXE"
d1=$(cat "$T/real.dump1" 2>/dev/null)
grep -q '^item .* shown=1 icon=[1-9][0-9]*x[1-9][0-9]* tip=Gate Item: all is well' "$T/real.dump1" \
    && pass "a Linux program's tray icon is in the notification area, with its own picture and tooltip" \
    || fail "no icon: $(echo "$d1" | head -3) / $(tail -3 "$T/real.bridge" 2>/dev/null)"
grep -q '^menu .* 0 1 \[-\] &Open$' "$T/real.dump1" && grep -q '^menu .* 0 2 \[s\] ' "$T/real.dump1" \
    && grep -q '^menu .* 0 4 \[m\] More$' "$T/real.dump1" && grep -q '^menu .* 1 5 \[-\] Sub$' "$T/real.dump1" \
    && grep -q '^menu .* 0 6 \[d\] Disabled$' "$T/real.dump1" \
    && pass "...with its menu: mnemonics, a separator, a submenu, a disabled item" \
    || fail "menu: $(grep '^menu' "$T/real.dump1" | tr '\n' '|')"
grep -q 'true' "$T/real.host" && pass "the watcher says a host is registered (Qt and Electron use it, not the X tray)" \
    || fail "watcher host property: $(cat "$T/real.host")"
grep -q '^Activate ' "$T/real.item" && pass "a left click is the program's Activate" || fail "Activate: $(cat "$T/real.item" | tr '\n' '|')"
grep -q '^SecondaryActivate ' "$T/real.item" && pass "a middle click its SecondaryActivate" || fail "SecondaryActivate: $(cat "$T/real.item" | tr '\n' '|')"
grep -q '^Event 5 clicked' "$T/real.item" && pass "a submenu's item chosen is its dbusmenu clicked event" || fail "Event 5: $(cat "$T/real.item" | tr '\n' '|')"
grep -q '^Event 3 clicked' "$T/real.item" && grep -q '^exit' "$T/real.item" && ! grep -q '^item ' "$T/real.dump2" 2>/dev/null \
    && pass "Quit from the menu ends the program, and its icon goes" \
    || fail "quit: item=$(tail -2 "$T/real.item" | tr '\n' '|') dump2=$(cat "$T/real.dump2" 2>/dev/null | head -2)"

if [ -n "${SG_SNI_MUT:-}" ]; then
    run_case mut "$SG_SNI_MUT"
    grep -q '^menu ' "$T/mut.dump1" 2>/dev/null \
        && fail "MUTANT SNI_NO_MENU not detected" || pass "MUTANT SNI_NO_MENU loses the menu (gate catches it)"
fi

run_case nohost "$EXE" SG_MUTANT_SNI_NO_HOST=1
grep -q 'true' "$T/nohost.host" 2>/dev/null \
    && fail "MUTANT SNI_NO_HOST not detected" || pass "MUTANT SNI_NO_HOST says no host (gate catches it)"

kill $XP 2>/dev/null
[ $fails -eq 0 ] && { rm -rf "$T"; echo "sni-test: all passed"; exit 0; }
echo "sni-test: $fails failed (kept $T)"; exit 1
