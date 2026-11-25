#!/bin/sh
# sg-nouveau-guard: nouveau is not loaded on an NVIDIA Ada card (10de:2680-28ff)
# whose GSP firmware is missing -- it would remove the firmware framebuffer
# and then fail, leaving no display (user report 2026-11-25) -- and is loaded
# everywhere else (older cards, Ada with the firmware, no NVIDIA card).
# Fake sysfs, firmware directory and modprobe; touches nothing real.
#   --mutant: the guard lets nouveau load regardless (must FAIL)
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
GUARD="$HERE/lib/sg-nouveau-guard"
T=$(mktemp -d "${TMPDIR:-/tmp}/sg-nouveau-guard.XXXXXX")
trap 'rm -rf "$T"' EXIT
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
if [ "${1:-}" = --mutant ]; then
    sed 's/^            exit 0$/            :/' "$GUARD" > "$T/guard"; GUARD="$T/guard"
fi
cat > "$T/modprobe" <<'EOS'
#!/bin/sh
echo "modprobe $*" >> "$SG_T/loaded"
EOS
chmod +x "$T/modprobe"
gpu() { # DIR VENDOR CLASS DEVICE
    mkdir -p "$T/sys/$1"; echo "$2" > "$T/sys/$1/vendor"; echo "$3" > "$T/sys/$1/class"; echo "$4" > "$T/sys/$1/device"
}
try() { # expect(load|skip) what
    rm -f "$T/loaded" "$T/kmsg"
    SG_T=$T SG_GUARD_SYSFS="$T/sys" SG_GUARD_FIRMWARE="$T/fw" SG_GUARD_MODPROBE="$T/modprobe" SG_GUARD_KMSG="$T/kmsg" \
        sh "$GUARD" modeset=1
    if [ "$1" = load ]; then
        grep -qx 'modprobe --ignore-install nouveau modeset=1' "$T/loaded" 2>/dev/null && pass "$2: nouveau loads" || fail "$2: nouveau was not loaded"
    else
        if [ ! -e "$T/loaded" ] && grep -q 'not loading nouveau' "$T/kmsg" 2>/dev/null; then pass "$2: nouveau is not loaded, and the kernel log says why"
        else fail "$2: nouveau loaded (or no message)"; fi
    fi
}
mkdir -p "$T/fw"
gpu 0000:00:02.0 0x8086 0x030000 0x46a6
try load "no NVIDIA card (Intel)"
gpu 0000:01:00.0 0x10de 0x030200 0x2860
try skip "NVIDIA Ada laptop (10de:2860), no GSP firmware"
mkdir -p "$T/fw/nvidia/ad102/gsp"; : > "$T/fw/nvidia/ad102/gsp/gsp-535.113.01.bin"
try load "NVIDIA Ada with its GSP firmware installed"
rm -rf "$T/fw/nvidia" "$T/sys/0000:01:00.0"
gpu 0000:01:00.0 0x10de 0x030000 0x2520
try load "NVIDIA Ampere (10de:2520), nouveau runs it without GSP"
gpu 0000:01:00.0 0x10de 0x040300 0x2860
try load "an NVIDIA audio function (not a display controller)"
exit $RC
