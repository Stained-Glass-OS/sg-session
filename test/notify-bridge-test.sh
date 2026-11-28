#!/bin/sh
# notify-bridge-test.sh -- Linux programs' notifications as toasts (lib/sg-notify-bridge).
#
# On a private session bus: the bridge owns org.freedesktop.Notifications and hands each
# notification to the toast host (here a stand-in that records its input and answers what the
# gate tells it; the real one is wine-sg 9512's rundll32 windows.ui.dll,SgLinuxNotifications,
# gated in wine-sg's linuxnotify-gate.sh). Checked:
#   - Notify from a program with a .desktop file (desktop-entry hint): its toast is the app's,
#     SG.LinuxApp.<desktop id> and the app's name; summary and body as text (markup a program
#     sends anyway taken out, entities kept escaped); its icon a PNG the host reads (file: URL);
#     its actions buttons, "default" not a button but the toast's click;
#   - a button clicked (host: ACT n key): ActionInvoked n key, then NotificationClosed n 2;
#   - a program with no .desktop file: SG.LinuxNotify.<its name>;
#   - CloseNotification: the host hides it, NotificationClosed n 3;
#   - replaces_id: the same number, shown again (the host replaces it by tag);
#   - a toast whose time ran out stays (no NotificationClosed), a transient one is closed (1);
#   - GetCapabilities says actions, body, persistence;
#   - a launcher entry (com.canonical.Unity.LauncherEntry Update: count, progress, urgent, each
#     only when it changes) goes to the host whole, as LAUNCHER <the app's ID> count progress urgent.
# Mutants (environment): SG_MUTANT_NOTIFY_NO_APPID, SG_MUTANT_NOTIFY_NO_ACTIONS, SG_MUTANT_NOTIFY_NO_LAUNCHER.
# Its sockets are a private bus's: run it in a network namespace of its own (the Makefile does,
# through SG_NETNS when given).
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d /var/tmp/notify-bridge-test.XXXXXX)
fails=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails + 1)); }
command -v dbus-run-session >/dev/null && command -v gdbus >/dev/null || { echo "SKIP: needs dbus-run-session and gdbus"; exit 77; }
python3 -c 'import gi; gi.require_version("GdkPixbuf", "2.0"); from gi.repository import GdkPixbuf' 2>/dev/null || { echo "SKIP: needs python3-gi with GdkPixbuf"; exit 77; }
unset DISPLAY WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS
trap 'kill $(cat "$T/pids" 2>/dev/null) 2>/dev/null; rm -rf "$T"' EXIT INT TERM
export HOME="$T/home" XDG_DATA_HOME="$T/home/.local/share" XDG_DATA_DIRS="$T/share:/usr/share" SG_NOTIFY_CACHE="$T/cache"
export SG_NOTIFY_CACHE_WIN='C:\cache dir'
mkdir -p "$HOME" "$T/share/applications" "$T/share/icons/hicolor/48x48/apps"
printf '[Desktop Entry]\nType=Application\nName=Gate Mail\nIcon=gate-mail\nExec=gate-mail %%u\n' > "$T/share/applications/org.gate.Mail.desktop"
python3 - "$T/share/icons/hicolor/48x48/apps/gate-mail.png" <<'EOF'
import struct, sys, zlib
n = 48
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
raw = b"".join(b"\0" + b"\x20\x80\xe0\xff" * n for _ in range(n))
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", n, n, 8, 6, 0, 0, 0))
                              + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
EOF
# the stand-in host: its input to host.in; what the gate writes to inj is its output
cat > "$T/host.py" <<'EOF'
import os, select, sys
inj = os.open(sys.argv[2], os.O_RDWR)
out = open(sys.argv[1], "a", buffering=1)
sys.stdout.write("READY\n"); sys.stdout.flush()
while True:
    r, _, _ = select.select([0, inj], [], [])
    if 0 in r:
        line = sys.stdin.readline()
        if not line:
            break
        out.write(line)
    if inj in r:
        sys.stdout.write(os.read(inj, 4096).decode()); sys.stdout.flush()
EOF
mkfifo "$T/inj"
cat > "$T/listen.py" <<'EOF'
import sys
from gi.repository import Gio, GLib
con = Gio.bus_get_sync(Gio.BusType.SESSION, None)
out = open(sys.argv[1], "a", buffering=1)
def got(c, sender, path, iface, signal, params):
    out.write("%s %s\n" % (signal, " ".join(str(v) for v in params.unpack())))
con.signal_subscribe(None, "org.freedesktop.Notifications", None, "/org/freedesktop/Notifications", None,
                     Gio.DBusSignalFlags.NONE, got)
GLib.MainLoop().run()
EOF
cat > "$T/inner.sh" <<EOF
python3 "$HERE/lib/sg-notify-bridge" python3 "$T/host.py" "$T/host.in" "$T/inj" > "$T/bridge.out" 2>&1 &
echo \$! >> "$T/pids"
python3 "$T/listen.py" "$T/signals" &
echo \$! >> "$T/pids"
i=0; while [ \$i -lt 40 ] && ! gdbus call --session -d org.freedesktop.Notifications -o /org/freedesktop/Notifications -m org.freedesktop.Notifications.GetServerInformation >/dev/null 2>&1; do sleep 0.25; i=\$((i + 1)); done
N() { gdbus call --session -d org.freedesktop.Notifications -o /org/freedesktop/Notifications -m org.freedesktop.Notifications.Notify "\$@"; }
gdbus call --session -d org.freedesktop.Notifications -o /org/freedesktop/Notifications -m org.freedesktop.Notifications.GetCapabilities > "$T/caps"
N 'Thunderbird' 0 '' 'New mail' 'From <b>Ann</b> &amp; Bob' "['default', 'Open', 'reply', 'Reply']" "{'desktop-entry': <'org.gate.Mail'>}" 'int32 -1' > "$T/n1"
sleep 1
printf 'ACT 1\treply\n' > "$T/inj"; sleep 1
N 'gate-tool' 0 '' 'Done' 'It finished' "[]" "{}" 'int32 -1' > "$T/n2"
sleep 0.5
gdbus call --session -d org.freedesktop.Notifications -o /org/freedesktop/Notifications -m org.freedesktop.Notifications.CloseNotification 2 >/dev/null
N 'gate-tool' 0 '' 'Copying' '10%' "[]" "{}" 'int32 -1' > "$T/n3"
N 'gate-tool' 3 '' 'Copying' '90%' "[]" "{}" 'int32 -1' > "$T/n3b"
sleep 0.5
printf 'EXPIRED 3\n' > "$T/inj"; sleep 0.5
N 'gate-tool' 0 '' 'Brief' 'gone soon' "[]" "{'transient': <true>}" 'int32 -1' > "$T/n4"
sleep 0.5
printf 'EXPIRED 4\n' > "$T/inj"; sleep 1
E() { gdbus emit --session -o /com/canonical/unity/launcherentry/1 -s com.canonical.Unity.LauncherEntry.Update "\$@"; }
E "'application://org.gate.Mail.desktop'" "{'count': <int64 3>, 'count-visible': <true>}"; sleep 0.5
E "'application://org.gate.Mail.desktop'" "{'progress': <0.42>, 'progress-visible': <true>, 'urgent': <true>}"; sleep 1
EOF
# a bus that starts nothing by itself: the machine's own notification daemon (one a package
# brought, D-Bus-activatable) must not answer in the bridge's place
cat > "$T/bus.conf" <<'EOF'
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:tmpdir=/tmp</listen>
  <policy context="default"><allow send_destination="*" eavesdrop="true"/><allow eavesdrop="true"/><allow own="*"/></policy>
</busconfig>
EOF
timeout -s KILL 60 dbus-run-session --config-file="$T/bus.conf" -- sh "$T/inner.sh"
sed 's/^/      /' "$T/host.in" 2>/dev/null; sed 's/^/      sig: /' "$T/signals" 2>/dev/null

line() { grep "^SHOW $1	" "$T/host.in" | sed -n "${2:-1}p"; }
L1=$(line 1)
case "$L1" in "SHOW 1	SG.LinuxApp.org.gate.Mail	Gate Mail	<toast launch=\"default\">"*) pass "a notification from an app with a .desktop file is a toast of the app's (SG.LinuxApp.<id>, its name)" ;;
    *) fail "first notification: $L1" ;; esac
case "$L1" in *"<text>New mail</text><text>From Ann &amp; Bob</text>"*) pass "summary and body as text, markup taken out, entities read" ;; *) fail "text: $L1" ;; esac
case "$L1" in *'<action content="Reply" arguments="reply"/>'*) pass "its actions are buttons" ;; *) fail "actions: $L1" ;; esac
case "$L1" in *'content="Open"'*|*'arguments="default"'*) fail "\"default\" made a button" ;; *) pass "\"default\" is the toast's click, not a button" ;; esac
case "$L1" in *'<image placement="appLogoOverride" src="file:///C:/cache%20dir/1.png"/>'*) [ -s "$T/cache/1.png" ] && pass "its picture: the app's icon, a PNG Wine reads (file: URL)" || fail "no PNG" ;;
    *) fail "picture: $L1" ;; esac
grep -qx 'ActionInvoked 1 reply' "$T/signals" && grep -qx 'NotificationClosed 1 2' "$T/signals" && pass "a button clicked: ActionInvoked, then NotificationClosed (2)" || fail "signals after the click: $(tr '\n' '|' < "$T/signals" 2>/dev/null)"
case "$(line 2)" in "SHOW 2	SG.LinuxNotify.gate-tool	gate-tool	"*) pass "a program with no .desktop file: SG.LinuxNotify.<its name>" ;; *) fail "second: $(line 2)" ;; esac
grep -qx 'HIDE 2' "$T/host.in" && grep -qx 'NotificationClosed 2 3' "$T/signals" && pass "CloseNotification: hidden, NotificationClosed (3)" || fail "close: $(grep HIDE "$T/host.in")"
grep -q '(uint32 3,)' "$T/n3b" && [ "$(grep -c '^SHOW 3	' "$T/host.in")" = 2 ] && pass "replaces_id: the same number, shown again" || fail "replace: $(cat "$T/n3b")"
grep -q '^NotificationClosed 3 ' "$T/signals" && fail "a toast whose time ran out was closed" || pass "a toast whose time ran out stays (in the notification centre)"
grep -qx 'NotificationClosed 4 1' "$T/signals" && grep -qx 'HIDE 4' "$T/host.in" && pass "a transient one is closed when its time runs out (1)" || fail "transient: $(tr '\n' '|' < "$T/signals")"
grep -qx 'LAUNCHER SG.LinuxApp.org.gate.Mail	3	-1	0' "$T/host.in" && pass "a launcher entry's count goes to the host (LAUNCHER, the app's ID)" || fail "launcher count: $(grep LAUNCHER "$T/host.in" | head -1)"
grep -qx 'LAUNCHER SG.LinuxApp.org.gate.Mail	3	42	1' "$T/host.in" && pass "its progress and urgency, the count kept" || fail "launcher progress: $(grep LAUNCHER "$T/host.in" | tail -1)"
grep -q "'actions'" "$T/caps" && grep -q "'body'" "$T/caps" && grep -q "'persistence'" "$T/caps" && pass "GetCapabilities: actions, body, persistence" || fail "caps: $(cat "$T/caps")"

echo
[ "$fails" -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL ($fails)"
[ "$fails" -eq 0 ]
