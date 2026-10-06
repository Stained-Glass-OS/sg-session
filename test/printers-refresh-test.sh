#!/bin/sh
# Unit gate for sg-printers-refresh (in make lint): with the machine's
# wineserver up, it loads winspool as SYSTEM (runuser -u sgsystem, wmic over
# Win32_Printer), which makes Windows' printers again from CUPS's (a standard
# user may not write them to HKLM); with it down it does nothing; and the
# path unit starts it when CUPS's ppd directory or printers.conf changes.
# Then SYSTEM readies every printer's driver (splwow64 drivers): a standard
# user may not write a printer's driver.
#   sh test/printers-refresh-test.sh [--mutant|--mutant-session|--mutant-winsta|--mutant-drivers]
#     (--mutant: run as the caller instead of SYSTEM; --mutant-session: the
#     signed-in check left out; --mutant-winsta: on the interactive window
#     station -- each must fail)
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
RC=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; RC=1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT INT TERM
TOOL="$HERE/../bin/sg-printers-refresh"
if [ "${1:-}" = --mutant ]; then
    sed 's|runuser -u "\$SG_SYSTEM_USER" -- ||' "$TOOL" > "$T/tool"; TOOL="$T/tool"
elif [ "${1:-}" = --mutant-winsta ]; then
    sed '/SG_WINSTATION=/d' "$TOOL" > "$T/tool"; TOOL="$T/tool"
elif [ "${1:-}" = --mutant-drivers ]; then
    sed 's/wine splwow64.exe drivers/true/' "$TOOL" > "$T/tool"; TOOL="$T/tool"
elif [ "${1:-}" = --mutant-session ]; then
    sed '/sg-session.env/d; /oobe.pending.*exit/d; /live boot.*exit/d' "$TOOL" > "$T/tool"; TOOL="$T/tool"
fi
mkdir -p "$T/lib" "$T/bin"
cat > "$T/lib/sg-common.sh" <<'S'
SG_SYSTEM_USER=sgsystem
sg_machine_wineserver_up() { [ -f "$STATE/up" ]; }
S
cat > "$T/bin/runuser" <<'S'
#!/bin/sh
echo "runuser $*" >> "$STATE/calls"
printf 'Name\r\nDYMO_LabelWriter_550\r\nPrint-to-PDF\r\n'
S
cat > "$T/bin/sh" <<'S'
#!/bin/sh
echo "sh $*" >> "$STATE/calls"
S
chmod +x "$T/bin/runuser" "$T/bin/sh"
mkdir -p "$T/run/1000"
echo "BOOT_IMAGE=/vmlinuz root=/dev/sda2" > "$T/cmdline"
run() { env STATE="$T" SG_LIB="$T/lib" PATH="$T/bin:$PATH" SG_OOBE_PENDING="$T/oobe.pending" SG_PROC_CMDLINE="$T/cmdline" \
    SG_RUN_USER="$T/run" /bin/sh "$TOOL" 2>&1; }

touch "$T/up"
out=$(run)
[ ! -s "$T/calls" ] && pass "no one signed in (login screen): nothing done" || fail "ran with no session: $(cat "$T/calls")"
touch "$T/run/1000/sg-session.env" "$T/oobe.pending"
out=$(run)
[ ! -s "$T/calls" ] && pass "first-boot setup pending: nothing done" || fail "ran during first-boot setup: $(cat "$T/calls")"
rm -f "$T/oobe.pending"; echo "BOOT_IMAGE=/vmlinuz systemd.volatile=overlay" > "$T/cmdline"
out=$(run)
[ ! -s "$T/calls" ] && pass "live boot (Setup): nothing done" || fail "ran on a live boot: $(cat "$T/calls")"
echo "BOOT_IMAGE=/vmlinuz root=/dev/sda2" > "$T/cmdline"; rm -f "$T/up"
out=$(run)
[ ! -s "$T/calls" ] && pass "the Windows system not running: nothing done" || fail "ran without the wineserver: $(cat "$T/calls")"
touch "$T/up"
out=$(run)
case "$(cat "$T/calls" 2>/dev/null)" in
    "runuser -u sgsystem -- sh -c "*"sg_wine_env"*"wine wmic path Win32_Printer"*) pass "SYSTEM loads winspool (wmic Win32_Printer)" ;;
    *) fail "not as SYSTEM: $(cat "$T/calls" 2>/dev/null)" ;; esac
# in the services' window station: on the interactive one it took the login
# screen's desktop at first boot (release s9, 2026-10-05; --mutant-winsta)
case "$(cat "$T/calls" 2>/dev/null)" in
    *'SG_WINSTATION="__wineservice_winstation\Default"; export SG_WINSTATION'*"wine wmic"*)
        pass "in the services' window station, not the login screen's" ;;
    *) fail "not in the services' window station: $(cat "$T/calls" 2>/dev/null)" ;; esac
case "$out" in *"printers now: DYMO_LabelWriter_550,Print-to-PDF"*) pass "and it reports the Windows printers" ;; *) fail "output: $out" ;; esac
case "$(cat "$T/calls")" in
    *"wine wmic"*"wine splwow64.exe drivers"*) pass "SYSTEM readies every printer's driver for every user (splwow64 drivers)" ;;
    *) fail "the printers' drivers were not readied as SYSTEM" ;;
esac
U="$HERE/../systemd/sg-printers-refresh.path"
grep -qx 'PathChanged=/etc/cups/ppd' "$U" && grep -qx 'PathChanged=/etc/cups/printers.conf' "$U" \
    && grep -qx 'enable sg-printers-refresh.path' "$HERE/../config/preset/50-stained-glass.preset" \
    && pass "the path unit watches CUPS's ppd directory and printers.conf, and is enabled" || fail "path unit: $(grep -v '^#' "$U")"
S="$HERE/../systemd/sg-printers-refresh.service"
grep -qx 'ConditionKernelCommandLine=!systemd.volatile=overlay' "$S" && grep -qx 'ConditionPathExists=!/etc/stained-glass/oobe.pending' "$S" \
    && pass "the service never runs on a live boot or before the first-boot setup is done" || fail "service conditions"
exit $RC
