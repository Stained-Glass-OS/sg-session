#!/bin/sh
# udev/70-stained-glass-devices.rules: valid udev syntax, and Ambir's
# scanners (USB vendor 1dcc, which SANE does not know: the 490i) given to the
# Windows side's group -- AmbirScan found no scanner on David's Latitude
# (2026-10-02), where only the VM had a hand-made rule.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
R="$HERE/udev/70-stained-glass-devices.rules"
RC=0
if command -v udevadm >/dev/null && udevadm verify --help >/dev/null 2>&1; then
    udevadm verify --no-style --resolve-names=never "$R" >/dev/null 2>&1 && echo "PASS  the rules are valid (udevadm verify)" || { echo "FAIL  udevadm verify: $(udevadm verify --no-style --resolve-names=never "$R" 2>&1 | head -3)"; RC=1; }
else
    echo "      (no udevadm verify here)"
fi
grep -Eq '^SUBSYSTEM=="usb", ATTRS\{idVendor\}=="1dcc", MODE="0660", GROUP="sgwine"$' "$R" \
    && echo "PASS  Ambir's scanners (1dcc) are the sgwine group's" || { echo "FAIL  no rule for Ambir (1dcc)"; RC=1; }
grep -q 'idVendor=1dcc' "$HERE/debian/sg-session.postinst" \
    && echo "PASS  and one plugged in already takes the rule at the upgrade" || { echo "FAIL  no udevadm trigger in postinst"; RC=1; }
exit $RC
