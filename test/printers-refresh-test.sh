#!/bin/sh
# Unit gate for sg-printers-refresh (in make lint): with the machine's
# wineserver up, it loads winspool as SYSTEM (runuser -u sgsystem, wmic over
# Win32_Printer), which makes Windows' printers again from CUPS's (a standard
# user may not write them to HKLM); with it down it does nothing; and the
# path unit starts it when CUPS's ppd directory or printers.conf changes.
#   sh test/printers-refresh-test.sh [--mutant]   (--mutant: run as the
#     caller instead of SYSTEM -- must fail)
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
run() { env STATE="$T" SG_LIB="$T/lib" PATH="$T/bin:$PATH" /bin/sh "$TOOL" 2>&1; }

out=$(run)
[ ! -s "$T/calls" ] && pass "the Windows system not running: nothing done" || fail "ran without the wineserver: $(cat "$T/calls")"
touch "$T/up"
out=$(run)
case "$(cat "$T/calls" 2>/dev/null)" in
    "runuser -u sgsystem -- sh -c "*"sg_wine_env"*"wine wmic path Win32_Printer"*) pass "SYSTEM loads winspool (wmic Win32_Printer)" ;;
    *) fail "not as SYSTEM: $(cat "$T/calls" 2>/dev/null)" ;; esac
case "$out" in *"printers now: DYMO_LabelWriter_550,Print-to-PDF"*) pass "and it reports the Windows printers" ;; *) fail "output: $out" ;; esac
U="$HERE/../systemd/sg-printers-refresh.path"
grep -qx 'PathChanged=/etc/cups/ppd' "$U" && grep -qx 'PathChanged=/etc/cups/printers.conf' "$U" \
    && grep -qx 'enable sg-printers-refresh.path' "$HERE/../config/preset/50-stained-glass.preset" \
    && pass "the path unit watches CUPS's ppd directory and printers.conf, and is enabled" || fail "path unit: $(grep -v '^#' "$U")"
exit $RC
