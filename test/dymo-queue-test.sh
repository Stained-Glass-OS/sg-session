#!/bin/sh
# Unit gate for sg-dymo-queue (in make lint): with a stand-in lpinfo that
# lists a LabelWriter 550, a 550 Turbo, a LabelWriter 450 and another
# maker's printer on USB, and stand-in lpstat/lpadmin, the helper
#   - adds DYMO_LabelWriter_550 on the 550's usb:// URI with the PPD whose
#     model is "DYMO LabelWriter 550" (the queue's make and model, which
#     wine-sg names the Windows driver after: DYMO Connect's name for it),
#   - and DYMO_LabelWriter_550_Turbo with the Turbo's PPD,
#   - leaves the 450 (no 5xx PPD) and the other printer alone,
#   - adds nothing on a second run, and a second 550 gets a queue of its own;
# and the udev rule starts the service for vendor 0922 on add.
#   sh test/dymo-queue-test.sh [--mutant]   (--mutant: the PPD picked without
#     looking at the model -- must fail)
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
RC=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; RC=1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT INT TERM
TOOL="$HERE/../bin/sg-dymo-queue"
if [ "${1:-}" = --mutant ]; then
    sed 's|\[ "\$m" = "\$1" \] && {|{|' "$TOOL" > "$T/tool"; TOOL="$T/tool"
fi
mkdir -p "$T/ppd" "$T/state"
for m in "lw550:DYMO LabelWriter 550" "lw550t:DYMO LabelWriter 550 Turbo" "lw5xl:DYMO LabelWriter 5XL"; do
    printf '*PPD-Adobe: "4.3"\n*ModelName: "%s"\n*NickName: "%s"\n' "${m#*:}" "${m#*:}" > "$T/ppd/${m%%:*}.ppd"
done
cat > "$T/lpinfo" <<'S'
#!/bin/sh
cat "$STATE/devices"
S
cat > "$T/lpstat" <<'S'
#!/bin/sh
[ "$1" = -v ] && cat "$STATE/queues" 2>/dev/null
exit 0
S
cat > "$T/lpadmin" <<'S'
#!/bin/sh
echo "$*" >> "$STATE/calls"
[ "$1" = -p ] && [ "$3" = -E ] && [ "$4" = -v ] && echo "device for $2: $5" >> "$STATE/queues"
exit 0
S
chmod +x "$T/lpinfo" "$T/lpstat" "$T/lpadmin"
cat > "$T/state/devices" <<'S'
network beh
direct usb://DYMO/LabelWriter%20550?serial=0123456789
direct usb://DYMO/LabelWriter%20550%20Turbo?serial=111
direct usb://DYMO/LabelWriter%20450?serial=222
direct usb://Brother/QL-800?serial=333
network ipp
S
run() { env STATE="$T/state" SG_DYMO_PPD_DIR="$T/ppd" SG_LPINFO="$T/lpinfo" SG_LPSTAT="$T/lpstat" \
    SG_LPADMIN="$T/lpadmin" SG_DYMO_TRIES=1 sh "$TOOL" >/dev/null 2>&1; }

run
calls=$(cat "$T/state/calls" 2>/dev/null)
case "$calls" in *"-p DYMO_LabelWriter_550 -E -v usb://DYMO/LabelWriter%20550?serial=0123456789 -P $T/ppd/lw550.ppd -D DYMO LabelWriter 550"*)
    pass "the 550 gets DYMO_LabelWriter_550 with the PPD for DYMO LabelWriter 550" ;; *) fail "550: $calls" ;; esac
case "$calls" in *"-p DYMO_LabelWriter_550_Turbo -E -v usb://DYMO/LabelWriter%20550%20Turbo?serial=111 -P $T/ppd/lw550t.ppd"*)
    pass "the 550 Turbo gets its own queue with the Turbo's PPD" ;; *) fail "Turbo: $calls" ;; esac
case "$calls" in *LabelWriter%20450*|*Brother*) fail "a printer without a 5xx PPD got a queue: $calls" ;;
    *) pass "the LabelWriter 450 and the other maker's printer are left alone" ;; esac
n=$(wc -l < "$T/state/calls")
run
[ "$(wc -l < "$T/state/calls")" = "$n" ] && pass "a second run adds nothing" || fail "second run: $(tail -2 "$T/state/calls")"
echo "direct usb://DYMO/LabelWriter%20550?serial=999" >> "$T/state/devices"
run
tail -1 "$T/state/calls" | grep -q -- "-p DYMO_LabelWriter_550_2 -E -v usb://DYMO/LabelWriter%20550?serial=999 " \
    && pass "a second 550 gets a queue of its own" || fail "second 550: $(tail -1 "$T/state/calls")"
: > "$T/state/devices"; rm -f "$T/state/calls"
run
[ ! -s "$T/state/calls" ] && pass "no DYMO printer: nothing done" || fail "without a printer: $(cat "$T/state/calls")"

R="$HERE/../udev/73-stained-glass-dymo.rules"
grep -q '^ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="0922", TAG+="systemd", ENV{SYSTEMD_WANTS}+="sg-dymo-queue.service"$' "$R" \
    && pass "udev starts sg-dymo-queue.service for a DYMO device" || fail "udev rule: $(grep -v '^#' "$R")"
exit $RC
