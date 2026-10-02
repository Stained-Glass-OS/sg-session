#!/bin/sh
# sg-firmware-retry (Latitude 3520: "Dummy Output") on a fake sysfs: a SOF
# device bound with no sound card is unbound and bound again; one with a card
# (its machine driver's platform child) is left alone. And the timesyncd
# drop-in that lets the clock be set (apt's "not live until" signing errors)
# removes the initrd's stale network state, privileged ("+"), unless
# networkd runs. --mutant: the rebind left out -- the test must fail.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
TOOL="$HERE/../bin/sg-firmware-retry"
if [ "${1:-}" = --mutant ]; then
    sed 's|echo "\$name" > "\$drv/bind"|true|' "$TOOL" > "$T/tool"; TOOL="$T/tool"
fi
D="$T/sys/bus/pci/drivers/sof-audio-pci-intel-tgl"
mkdir -p "$D" "$T/devices/0000:00:1f.3" "$T/devices/0000:00:1f.4/skl_hda_dsp_generic/sound/card0"
ln -s "$T/devices/0000:00:1f.3" "$D/0000:00:1f.3"
ln -s "$T/devices/0000:00:1f.4" "$D/0000:00:1f.4"
: > "$D/unbind"; : > "$D/bind"
SG_FIRMWARE_WAIT=1 sh "$TOOL" "$T/sys" > "$T/out" 2>&1
[ "$(cat "$D/unbind")" = 0000:00:1f.3 ] && [ "$(cat "$D/bind")" = 0000:00:1f.3 ] \
    && pass "the device without a sound card is bound again" \
    || fail "the device without a sound card was not bound again (unbind: $(cat "$D/unbind"), bind: $(cat "$D/bind"))"
grep -q 1f.4 "$D/unbind" "$D/bind" && fail "the device with a card was touched" \
    || pass "the device with a sound card is left alone"
DROP="$HERE/../systemd/systemd-timesyncd.service.d/50-sg-initrd-network.conf"
grep -q "^ExecStartPre=+-/bin/sh -c 'systemctl -q is-active systemd-networkd.service || rm -f /run/systemd/netif/state'" "$DROP" \
    && pass "timesyncd's drop-in removes the initrd's network state, privileged" \
    || fail "timesyncd's drop-in does not remove the initrd's network state"
if command -v systemd-analyze >/dev/null; then
    systemd-analyze verify --man=no "$HERE/../systemd/sg-firmware-retry.service" 2>&1 | grep -v "sg-firmware-retry: No such\|/usr/bin/sg-firmware-retry\|is not executable" | grep -q . \
        && fail "the unit does not verify: $(systemd-analyze verify --man=no "$HERE/../systemd/sg-firmware-retry.service" 2>&1 | head -2)" \
        || pass "the unit verifies"
fi
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
