#!/bin/sh
# Unit gate for sg-print-setup (in make lint): with stand-in lpstat/lpadmin
# and a copy of cups-pdf.conf, the Print-to-PDF queue is added on cups-pdf
# with its PPD, made the default only when there is none, and cups-pdf
# writes into the user's Windows Documents; a second run changes nothing.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
RC=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; RC=1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT INT TERM
printf '#!/bin/sh\nexit 0\n' > "$T/cups-pdf"; chmod +x "$T/cups-pdf"
printf '### Key: Out\n#Out ${HOME}/PDF\n### Key: Label\n#Label 0\n' > "$T/cups-pdf.conf"
cat > "$T/lpstat" <<'S'
#!/bin/sh
case "$1" in
-p) [ -f "$STATE/queue" ] ;;
-d) if [ -f "$STATE/default" ]; then echo "system default destination: $(cat "$STATE/default")"; else echo "no system default destination"; fi ;;
esac
S
cat > "$T/lpadmin" <<'S'
#!/bin/sh
echo "$*" >> "$STATE/calls"
case "$1" in -p) touch "$STATE/queue" ;; -d) echo "$2" > "$STATE/default" ;; esac
S
chmod +x "$T/lpstat" "$T/lpadmin"
mkdir -p "$T/state"
run() { env STATE="$T/state" SG_PREFIX=/var/lib/stained-glass/prefix SG_CUPS_PDF_BACKEND="$T/cups-pdf" \
    SG_CUPS_PDF_CONF="$T/cups-pdf.conf" SG_LPADMIN="$T/lpadmin" SG_LPSTAT="$T/lpstat" sh "$HERE/../bin/sg-print-setup" >/dev/null; }

run
calls=$(cat "$T/state/calls" 2>/dev/null)
case "$calls" in *"-p Print-to-PDF -E -v cups-pdf:/ -P /usr/share/ppd/cups-pdf/CUPS-PDF_opt.ppd -D Print to PDF"*) pass "adds the Print-to-PDF queue on cups-pdf" ;; *) fail "lpadmin: $calls" ;; esac
case "$calls" in *"-d Print-to-PDF"*) pass "and makes it the default when there is none" ;; *) fail "default: $calls" ;; esac
grep -qx 'Out /var/lib/stained-glass/prefix/drive_c/users/${USER}/Documents' "$T/cups-pdf.conf" \
    && grep -qx 'Label 1' "$T/cups-pdf.conf" && pass "cups-pdf writes into the user's Windows Documents, never over a PDF" \
    || fail "cups-pdf.conf: $(cat "$T/cups-pdf.conf")"
rm -f "$T/state/calls"; echo "Office-Laser" > "$T/state/default"
run
[ ! -s "$T/state/calls" ] && pass "a second run changes nothing; an administrator's default stays" || fail "second run: $(cat "$T/state/calls")"
rm -f "$T/cups-pdf"; rm -rf "$T/state"; mkdir -p "$T/state"
run
[ ! -e "$T/state/calls" ] && pass "without cups-pdf it does nothing" || fail "without cups-pdf"
exit $RC
