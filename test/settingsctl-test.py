#!/usr/bin/python3
# Unit gate for sg-settingsctl, the native half of Settings: stand-in pactl,
# bluetoothctl, wlr-randr, wlsunset, swayidle and apt record what they are
# asked; the checks are the answers Settings parses, the exact commands run,
# and every refusal (bad names, out-of-range numbers, option smuggling).
#
# SPDX-License-Identifier: AGPL-3.0-or-later
import json
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
CTL = os.path.join(HERE, "..", "bin", "sg-settingsctl")
FAILS = 0


def check(what, ok, detail=""):
    global FAILS
    print("%s  %s%s" % ("PASS" if ok else "FAIL", what, "" if ok else ": " + str(detail)))
    if not ok:
        FAILS += 1


tmp = tempfile.mkdtemp(prefix="sg-settingsctl-")
tools = os.path.join(tmp, "tools")
os.makedirs(tools)
LOG = os.path.join(tmp, "calls.log")

SINKS = [
    {"name": "alsa_output.pci-0000_00_1f.3.analog-stereo", "description": "Speakers (Built-in Audio)", "mute": False,
     "volume": {"front-left": {"value_percent": "40%"}, "front-right": {"value_percent": "42%"}}},
    {"name": "bluez_output.AA_BB.1", "description": "Headphones", "mute": True,
     "volume": {"mono": {"value_percent": "100%"}}},
]
SOURCES = [
    {"name": "alsa_input.pci-0000_00_1f.3.analog-stereo", "description": "Microphone (Built-in Audio)", "mute": False,
     "volume": {"front-left": {"value_percent": "65%"}}},
    {"name": "alsa_output.pci-0000_00_1f.3.analog-stereo.monitor", "description": "Monitor of Speakers",
     "mute": False, "volume": {}, "properties": {"device.class": "monitor"}},
]
OUTPUTS = [{"name": "Virtual-1", "description": "QEMU Monitor", "scale": 1.0, "modes": [
    {"width": 1920, "height": 1080, "refresh": 60.0, "preferred": True, "current": True},
    {"width": 1280, "height": 720, "refresh": 59.94, "preferred": False, "current": False}]}]


def stand_in(name, body):
    path = os.path.join(tools, name)
    with open(path, "w") as f:
        f.write("#!/bin/sh\necho \"%s $*\" >> %s\n%s\n" % (name, LOG, body))
    os.chmod(path, 0o755)


with open(os.path.join(tmp, "sinks.json"), "w") as f:
    json.dump(SINKS, f)
with open(os.path.join(tmp, "sources.json"), "w") as f:
    json.dump(SOURCES, f)
with open(os.path.join(tmp, "outputs.json"), "w") as f:
    json.dump(OUTPUTS, f)
stand_in("pactl", """case "$*" in
  "--format=json list sinks") cat %(t)s/sinks.json ;;
  "--format=json list sources") cat %(t)s/sources.json ;;
  "get-default-sink") echo alsa_output.pci-0000_00_1f.3.analog-stereo ;;
  "get-default-source") echo alsa_input.pci-0000_00_1f.3.analog-stereo ;;
esac""" % {"t": tmp})
stand_in("bluetoothctl", """case "$1" in
  show) [ -f %(t)s/no-bt ] && echo "No default controller available" || printf 'Controller 00:11:22:33:44:55 (public)\\n\\tPowered: yes\\n' ;;
  devices) echo "Device AA:BB:CC:DD:EE:01 Travel Mouse"; echo "Device AA:BB:CC:DD:EE:02 Headphones" ;;
  info) [ "$2" = AA:BB:CC:DD:EE:02 ] && printf '\\tPaired: yes\\n\\tConnected: yes\\n' || printf '\\tPaired: yes\\n\\tConnected: no\\n' ;;
esac""" % {"t": tmp})
stand_in("wlr-randr", "[ \"$1\" = --json ] && cat %s/outputs.json; exit 0" % tmp)
stand_in("wlsunset", "exec sleep 300")
stand_in("swayidle", "exec sleep 300")
stand_in("wlopm", "")
stand_in("apt", """cat <<EOF
Listing...
libfoo1/stable-security 1.2-3+deb13u1 amd64 [upgradable from: 1.2-3]
wine-sg/trixie 10.0-38 amd64 [upgradable from: 10.0-37]
EOF""")

ENV = dict(os.environ, SG_SETTINGSCTL_TOOLS=tools, XDG_CONFIG_HOME=os.path.join(tmp, "config"),
           XDG_RUNTIME_DIR=os.path.join(tmp, "run"), WAYLAND_DISPLAY="wayland-test",
           SG_SYSTEM_UPDATE=os.path.join(tmp, "system-update"), PATH="/usr/bin:/bin")
os.makedirs(ENV["XDG_RUNTIME_DIR"])


def ctl(*args, env=None):
    """(exit code, lines) through --out, as the Windows side reads it."""
    out = os.path.join(tmp, "answer.txt")
    if os.path.exists(out):
        os.unlink(out)
    r = subprocess.run([sys.executable, CTL] + list(args) + ["--out", out], env=env or ENV,
                       capture_output=True, text=True, timeout=60)
    try:
        with open(out, encoding="utf-8") as f:
            return r.returncode, f.read().splitlines()
    except OSError:
        return r.returncode, ["(no answer file) " + r.stderr]


def calls():
    try:
        with open(LOG) as f:
            text = f.read()
        os.unlink(LOG)
        return text.splitlines()
    except OSError:
        return []


# ---- sound
code, lines = ctl("sound")
check("sound: OK", code == 0 and lines[-1] == "OK", lines)
check("sound: default speakers at 42%, not muted",
      "SINK alsa_output.pci-0000_00_1f.3.analog-stereo\tyes\t42\tno\tSpeakers (Built-in Audio)" in lines, lines)
check("sound: headphones muted, not default", "SINK bluez_output.AA_BB.1\tno\t100\tyes\tHeadphones" in lines, lines)
check("sound: the microphone is listed",
      "SOURCE alsa_input.pci-0000_00_1f.3.analog-stereo\tyes\t65\tno\tMicrophone (Built-in Audio)" in lines, lines)
check("sound: an output's monitor is not a microphone", not any(".monitor" in line for line in lines), lines)
calls()
code, lines = ctl("sound", "volume", "sink", "bluez_output.AA_BB.1", "75")
check("sound volume: runs pactl set-sink-volume",
      code == 0 and "pactl set-sink-volume bluez_output.AA_BB.1 75%" in calls(), lines)
code, lines = ctl("sound", "default", "source", "alsa_input.pci-0000_00_1f.3.analog-stereo")
check("sound default: runs pactl set-default-source",
      code == 0 and "pactl set-default-source alsa_input.pci-0000_00_1f.3.analog-stereo" in calls(), lines)
code, lines = ctl("sound", "mute", "sink", "bluez_output.AA_BB.1", "no")
check("sound mute: runs pactl set-sink-mute 0", code == 0 and "pactl set-sink-mute bluez_output.AA_BB.1 0" in calls(), lines)
for bad in (["volume", "sink", "x", "151"], ["volume", "sink", "x", "-5"], ["volume", "sink", "--help", "5"],
            ["volume", "sink", "a b", "5"], ["default", "both", "x"], ["mute", "sink", "x", "maybe"]):
    code, lines = ctl("sound", *bad)
    check("sound refuses %s" % " ".join(bad), code == 2 and lines[-1].startswith("ERROR invalid") and not calls(), lines)

# ---- bluetooth
code, lines = ctl("bluetooth")
check("bluetooth: present and powered", lines[:2] == ["BLUETOOTH yes", "POWERED yes"], lines)
check("bluetooth: devices with state", "DEVICE AA:BB:CC:DD:EE:02\tyes\tyes\tHeadphones" in lines and
      "DEVICE AA:BB:CC:DD:EE:01\tno\tyes\tTravel Mouse" in lines, lines)
calls()
code, lines = ctl("bluetooth", "power", "off")
check("bluetooth power off", code == 0 and "bluetoothctl power off" in calls(), lines)
code, lines = ctl("bluetooth", "connect", "AA:BB:CC:DD:EE:01")
check("bluetooth connect", code == 0 and "bluetoothctl connect AA:BB:CC:DD:EE:01" in calls(), lines)
code, lines = ctl("bluetooth", "scan", "3")
c = calls()
check("bluetooth scan: bluetoothctl scans for that long, then lists", code == 0 and "bluetoothctl --timeout 3 scan on" in c
      and "DEVICE AA:BB:CC:DD:EE:01\tno\tyes\tTravel Mouse" in lines, c)
code, lines = ctl("bluetooth", "pair", "AA:BB:CC:DD:EE:02")
c = calls()
check("bluetooth pair: pair, trust, connect", code == 0 and c[:3] == ["bluetoothctl pair AA:BB:CC:DD:EE:02",
      "bluetoothctl trust AA:BB:CC:DD:EE:02", "bluetoothctl connect AA:BB:CC:DD:EE:02"], c)
code, lines = ctl("bluetooth", "scan", "999")
check("bluetooth scan refuses 999 seconds", code == 2 and not calls(), lines)
code, lines = ctl("bluetooth", "remove", "AA:BB:CC:DD:EE:0;reboot")
check("bluetooth refuses a bad address", code == 2 and not calls(), lines)
open(os.path.join(tmp, "no-bt"), "w").close()
code, lines = ctl("bluetooth")
check("bluetooth: no controller", code == 0 and lines[:2] == ["BLUETOOTH no", "POWERED no"], lines)
calls()

# ---- display
code, lines = ctl("display")
check("display: the output and its current mode", "OUTPUT Virtual-1\t1920x1080@60\t1.0\tQEMU Monitor" in lines, lines)
check("display: its modes", "MODE Virtual-1\t1280x720@59.94\tno\tno" in lines and
      "MODE Virtual-1\t1920x1080@60\tyes\tyes" in lines, lines)
calls()
code, lines = ctl("display", "mode", "Virtual-1", "1280x720@59.94")
check("display mode: wlr-randr --mode", code == 0 and "wlr-randr --output Virtual-1 --mode 1280x720@59.94" in calls(), lines)
code, lines = ctl("display", "mode", "Virtual-9", "1280x720")
check("display mode: an unknown output is refused", code == 5, lines)
calls()
for bad in (["mode", "Virtual-1", "big"], ["mode", "Virtual-1", "1280x720 --off"], ["scale", "Virtual-1", "7"]):
    code, lines = ctl("display", *bad)
    check("display refuses %s" % " ".join(bad), code == 2 and not [c for c in calls() if "--json" not in c], lines)
code, lines = ctl("display", env=dict(ENV, WAYLAND_DISPLAY=""))
check("display: unsupported off the compositor", code == 4 and lines[-1].startswith("ERROR unsupported"), lines)

# ---- night light
code, lines = ctl("nightlight")
check("nightlight: off by default", lines[0].startswith("NIGHTLIGHT off\t4000\tyes"), lines)
code, lines = ctl("nightlight", "on", "--temp", "3400")
time.sleep(0.3)
check("nightlight on: wlsunset at a fixed 3400 K", code == 0 and "wlsunset -t 3400 -T 3401" in calls() and
      lines[0] == "NIGHTLIGHT on\t3400\tyes\tyes", lines)
code, lines = ctl("nightlight", "--temp", "99999")
check("nightlight refuses 99999 K", code == 2, lines)
code, lines = ctl("nightlight", "off")
check("nightlight off: stopped", code == 0 and lines[0].endswith("\tno"), lines)
with open(os.path.join(ENV["XDG_CONFIG_HOME"], "stained-glass", "settings.json")) as f:
    check("nightlight: remembered", json.load(f)["nightlight"] == {"on": False, "temp": 3400})

# ---- power
calls()
code, lines = ctl("power", "--screen", "5", "--sleep", "30")
time.sleep(0.3)
c = calls()
check("power: swayidle with both timeouts", code == 0 and any(x.startswith("swayidle -w timeout 300") and
      "timeout 1800 systemctl suspend" in x for x in c), c)
check("power: reported", lines[0] == "POWER 5\t30\tyes\tyes", lines)
code, lines = ctl("power", "--screen", "0", "--sleep", "0")
check("power: never and never stops the timers", lines[0] == "POWER 0\t0\tyes\tno", lines)
code, lines = ctl("power", "--sleep", "99999")
check("power refuses 99999 minutes", code == 2, lines)
code, lines = ctl("power", "--sleep", "30")
code, lines = ctl("session-start")
time.sleep(0.3)
check("session-start: the idle timers again", code == 0 and any(x.startswith("swayidle") for x in calls()), lines)

# ---- updates
code, lines = ctl("updates")
check("updates: apt's upgradable list", "UPDATE libfoo1\t1.2-3\t1.2-3+deb13u1" in lines and
      "UPDATE wine-sg\t10.0-37\t10.0-38" in lines, lines)
check("updates: nothing staged", "STAGED no" in lines, lines)

# ---- usage
code, lines = ctl("reboot")
check("an unknown command is refused", code == 2 and lines[-1].startswith("ERROR invalid"), lines)

# stop what the test started
for name in ("sg-nightlight", "sg-idle"):
    try:
        with open(os.path.join(ENV["XDG_RUNTIME_DIR"], name + ".pid")) as f:
            os.kill(int(f.read()), 15)
    except (OSError, ValueError):
        pass
print("settingsctl-test: %s" % ("FAIL (%d)" % FAILS if FAILS else "PASS"))
sys.exit(1 if FAILS else 0)
