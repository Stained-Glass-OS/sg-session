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
#   - sets the queue's default page to the PPD's page of the roll the printer
#     reports (a stand-in sysfs and status: 30336 -> w72h154.1), again on the
#     next run when the roll changed, else the country's usual label (LANG),
#     and landscape;
# and the udev rule starts the service for vendor 0922 on add.
#   sh test/dymo-queue-test.sh [--mutant|--mutant-roll]   (--mutant: the PPD
#     picked without looking at the model; --mutant-roll: the roll not read --
#     each must fail)
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
elif [ "${1:-}" = --mutant-roll ]; then
    sed 's|^roll_sku() {|roll_sku() { return 1|' "$TOOL" > "$T/tool"; TOOL="$T/tool"
fi
mkdir -p "$T/ppd" "$T/state/qppd"
for m in "lw550:DYMO LabelWriter 550" "lw550t:DYMO LabelWriter 550 Turbo" "lw5xl:DYMO LabelWriter 5XL"; do
    printf '*PPD-Adobe: "4.3"\n*ModelName: "%s"\n*NickName: "%s"\n' "${m#*:}" "${m#*:}" > "$T/ppd/${m%%:*}.ppd"
    cat >> "$T/ppd/${m%%:*}.ppd" <<'P'
*DefaultPageSize: w167h288
*PageSize w72h154/11352 Return Address Int: "<</PageSize[72 154]>>setpagedevice"
*PageSize w167h288/30256 Shipping: "<</PageSize[167 288]>>setpagedevice"
*PageSize w72h154.1/30336 1 in x 2-1/8 in: "<</PageSize[72 154]>>setpagedevice"
*PageSize w79h252.2/99010 Standard Address: "<</PageSize[79 252]>>setpagedevice"
P
done
# the 550 (serial 0123456789) on usblp: /dev/usb/lp0, as sysfs shows it
mkdir -p "$T/sys/devices/1-2/1-2:1.0" "$T/sys/class/usbmisc/lp0"
echo 0922 > "$T/sys/devices/1-2/idVendor"; echo 0123456789 > "$T/sys/devices/1-2/serial"
ln -s ../../../devices/1-2/1-2:1.0 "$T/sys/class/usbmisc/lp0/device"
# its status: a roll in the main bay (byte 10 0x08), product number at 11-15
status() { printf "\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\0$1$2\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\051\\001\\000\\000\\000" > "$T/status.bin"; }
status 10 '\063\060\063\063\066'    # 30336
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
[ "$1" = -p ] && [ "$3" = -E ] && [ "$4" = -v ] && { echo "device for $2: $5" >> "$STATE/queues"; cp "$7" "$STATE/qppd/$2.ppd"; }
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
    SG_LPADMIN="$T/lpadmin" SG_DYMO_TRIES=1 SG_DYMO_SYSFS="$T/sys" SG_DYMO_DEVDIR="$T/dev" \
    SG_DYMO_STATUS_FILE="$T/status.bin" SG_DYMO_QUEUE_PPD_DIR="$T/state/qppd" SG_DYMO_LANG="${LANG_UNDER_TEST:-de_DE.UTF-8}" \
    sh "$TOOL" >/dev/null 2>&1; }
defaults() { grep -- "^-p $1 -o PageSize=" "$T/state/calls" | tail -1; }

run
calls=$(cat "$T/state/calls" 2>/dev/null)
case "$calls" in *"-p DYMO_LabelWriter_550 -E -v usb://DYMO/LabelWriter%20550?serial=0123456789 -P $T/ppd/lw550.ppd -D DYMO LabelWriter 550"*)
    pass "the 550 gets DYMO_LabelWriter_550 with the PPD for DYMO LabelWriter 550" ;; *) fail "550: $calls" ;; esac
case "$calls" in *"-p DYMO_LabelWriter_550_Turbo -E -v usb://DYMO/LabelWriter%20550%20Turbo?serial=111 -P $T/ppd/lw550t.ppd"*)
    pass "the 550 Turbo gets its own queue with the Turbo's PPD" ;; *) fail "Turbo: $calls" ;; esac
case "$calls" in *LabelWriter%20450*|*Brother*) fail "a printer without a 5xx PPD got a queue: $calls" ;;
    *) pass "the LabelWriter 450 and the other maker's printer are left alone" ;; esac
[ "$(defaults DYMO_LabelWriter_550)" = "-p DYMO_LabelWriter_550 -o PageSize=w72h154.1 -o orientation-requested-default=4" ] \
    && pass "the 550's queue prints on the roll it reports (30336: w72h154.1), landscape" \
    || fail "550 defaults: '$(defaults DYMO_LabelWriter_550)'"
[ "$(defaults DYMO_LabelWriter_550_Turbo)" = "-p DYMO_LabelWriter_550_Turbo -o PageSize=w79h252.2 -o orientation-requested-default=4" ] \
    && pass "the Turbo, whose roll is not read here (no usblp device of its serial), the country's label (de_DE: 99010)" \
    || fail "Turbo defaults: '$(defaults DYMO_LabelWriter_550_Turbo)'"
n=$(grep -c -- ' -E ' "$T/state/calls")
status 10 '\063\060\062\065\066'    # 30256 loaded since
run
[ "$(grep -c -- ' -E ' "$T/state/calls")" = "$n" ] && pass "a second run adds nothing" || fail "second run: $(tail -2 "$T/state/calls")"
[ "$(defaults DYMO_LabelWriter_550)" = "-p DYMO_LabelWriter_550 -o PageSize=w167h288 -o orientation-requested-default=4" ] \
    && pass "and takes the roll loaded since (30256: w167h288)" || fail "after the roll changed: '$(defaults DYMO_LabelWriter_550)'"
status 00 '\000\000\000\000\000'    # no roll
LANG_UNDER_TEST=en_US.UTF-8 run
[ "$(defaults DYMO_LabelWriter_550)" = "-p DYMO_LabelWriter_550 -o PageSize=w72h154.1 -o orientation-requested-default=4" ] \
    && pass "no roll reported: the country's usual label (en_US: 30336)" || fail "without a roll: '$(defaults DYMO_LabelWriter_550)'"
echo "direct usb://DYMO/LabelWriter%20550?serial=999" >> "$T/state/devices"
run
grep -q -- "^-p DYMO_LabelWriter_550_2 -E -v usb://DYMO/LabelWriter%20550?serial=999 " "$T/state/calls" \
    && pass "a second 550 gets a queue of its own" || fail "second 550: $(tail -1 "$T/state/calls")"
: > "$T/state/devices"; rm -f "$T/state/calls"
run
[ ! -s "$T/state/calls" ] && pass "no DYMO printer: nothing done" || fail "without a printer: $(cat "$T/state/calls")"

R="$HERE/../udev/73-stained-glass-dymo.rules"
grep -q '^ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="0922", TAG+="systemd", ENV{SYSTEMD_WANTS}+="sg-dymo-queue.service"$' "$R" \
    && pass "udev starts sg-dymo-queue.service for a DYMO device" || fail "udev rule: $(grep -v '^#' "$R")"
exit $RC
