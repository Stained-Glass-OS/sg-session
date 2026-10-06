#!/bin/sh
# Unit gate for sg-windows-printers and the sgwindrv CUPS backend (in make
# lint), with stand-ins for the Windows side (runuser running "splwow64"),
# lpadmin and lpstat:
#   - the Windows side (SYSTEM) first installs the makers' staged packages;
#   - a printer the Windows side lists ("DYMO LabelWriter 550/x"... with a
#     Windows driver) gets the queue <name>_MakersDriver on sgwindrv:/<name,
#     percent-encoded> with the PPD the Windows side made from its driver;
#   - a second run with nothing changed writes nothing (no lpadmin call: the
#     path unit watches CUPS's files, so a write would start it again);
#   - a queue on sgwindrv: whose printer the Windows side no longer lists goes;
#   - the backend draws the job's PDF pages (pdftoppm) and hands the Windows
#     side the printer's name (decoded), the page size, the copies, the title
#     and the pages as Z: paths, readable to the SYSTEM account.
#   sh test/windows-printers-test.sh [--mutant|--mutant-decode]
#     (--mutant: queues written again every run; --mutant-decode: the
#     backend's printer name left percent-encoded -- each must fail)
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
RC=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; RC=1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT INT TERM
TOOL="$HERE/../bin/sg-windows-printers"
BACKEND="$HERE/../bin/sgwindrv"
if [ "${1:-}" = --mutant ]; then
    sed 's|^        continue$|        :|' "$TOOL" > "$T/tool"; TOOL="$T/tool"
elif [ "${1:-}" = --mutant-decode ]; then
    sed 's|^printer=$(urldec "$enc")|printer=$enc|' "$BACKEND" > "$T/backend"; BACKEND="$T/backend"
fi
command -v pdftoppm >/dev/null || { echo "SKIP: no pdftoppm"; exit 77; }
mkdir -p "$T/lib" "$T/bin" "$T/prefix/drive_c" "$T/ppd"
STATE="$T"; export STATE
cat > "$T/lib/sg-common.sh" <<S
SG_PREFIX="$T/prefix"
SG_SYSTEM_USER=sgsystem
sg_wine_env() { :; }
S
# "runuser -u sgsystem -- sh -c SCRIPT LIB ARGS...": the Windows side's splwow64
cat > "$T/bin/runuser" <<'S'
#!/bin/sh
echo "runuser $*" >> "$STATE/calls"
while [ "$1" != "-c" ]; do shift; done
shift 2; shift   # the script, then $0 (the library)
unix() { printf '%s' "${1#Z:}" | tr '\\' '/'; }
case "$1" in
list) printf 'DYMO LabelWriter 550/x\tDYMO LabelWriter 550\n' > "$(unix "$2")" ;;
ppd) printf "*PPD-Adobe: \"4.3\"\n*NickName: \"%s (maker's driver)\"\n" "$2" > "$(unix "$3")" ;;
print) printf '%s\n' "$@" > "$STATE/print.args"
       shift 5; for p in "$@"; do f=$(unix "$p"); [ -r "$f" ] && head -c 2 "$f" >> "$STATE/print.pages"; echo >> "$STATE/print.pages"; done ;;
esac
S
cat > "$T/bin/lpadmin" <<'S'
#!/bin/sh
echo "lpadmin $*" >> "$STATE/lpadmin"
if [ "$1" = -p ]; then
    q=$2; shift 2
    while [ $# -gt 0 ]; do case $1 in -v) echo "device for $q: $2" >> "$STATE/queues"; shift ;; -P) cp "$2" "$STATE/ppd/$q.ppd"; shift ;; esac; shift; done
fi
S
cat > "$T/bin/lpstat" <<'S'
#!/bin/sh
cat "$STATE/queues" 2>/dev/null
S
chmod +x "$T/bin/"*
run() { SG_LIB="$T/lib" SG_RUNUSER="$T/bin/runuser" SG_LPADMIN="$T/bin/lpadmin" SG_LPSTAT="$T/bin/lpstat" \
        SG_CUPS_PPD_DIR="$T/ppd" sh "$TOOL"; }

echo "device for Old_MakersDriver: sgwindrv:/Old" > "$T/queues"
run > "$T/out1" 2>&1
q='DYMO_LabelWriter_550_x_MakersDriver'
if grep -q "^lpadmin -p $q -E -v sgwindrv:/DYMO%20LabelWriter%20550%2Fx -P .* -D DYMO LabelWriter 550/x (maker's driver)" "$T/lpadmin" &&
   grep -q "NickName: \"DYMO LabelWriter 550/x (maker's driver)\"" "$T/ppd/$q.ppd"; then
    pass "a printer with a Windows driver gets its queue, with the driver's PPD"
else
    fail "the queue was not made:"; cat "$T/lpadmin" "$T/out1" 2>/dev/null | sed 's/^/      /'
fi
grep -q '^lpadmin -x Old_MakersDriver$' "$T/lpadmin" && pass "a queue whose Windows printer is gone goes" ||
    fail "the stale queue stayed"
: > "$T/lpadmin"
run > "$T/out2" 2>&1
grep -q "^lpadmin -p" "$T/lpadmin" 2>/dev/null && fail "a second run wrote the queue again" ||
    pass "a second run with nothing changed writes nothing"
grep -q "runuser -u sgsystem" "$T/calls" && pass "the Windows side runs as the SYSTEM account" ||
    fail "the Windows side did not run as SYSTEM"
[ "$(sed -n 's/.* \(drivers\|list\) .*/\1/p; s/.* \(drivers\)$/\1/p' "$T/calls" | head -2 | tr '\n' ' ')" = "drivers list " ] &&
    pass "the makers' staged packages are installed (by SYSTEM) before the printers are listed" ||
    fail "the staged packages were not installed first"

# the backend
python3 - "$T/job.pdf" <<'P'
import sys
c = b"0 g 10 10 50 20 re f\n"
objs = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 72 36] /Contents 4 0 R >>",
        b"<< /Length %d >>\nstream\n" % len(c) + c + b"endstream",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 72 36] /Contents 4 0 R >>"]
out = b"%PDF-1.4\n"; offs = []
for i, o in enumerate(objs):
    offs.append(len(out)); out += b"%d 0 obj\n" % (i + 1) + o + b"\nendobj\n"
x = len(out)
out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1) + b"".join(b"%010d 00000 n \n" % o for o in offs)
out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, x)
open(sys.argv[1], "wb").write(out)
P
DEVICE_URI='sgwindrv:/DYMO%20LabelWriter%20550%2Fx' SG_LIB="$T/lib" SG_RUNUSER="$T/bin/runuser" TMPDIR="$T" \
    sh "$BACKEND" 7 alex "Shipping label" 2 "PageSize=P295 Resolution=100x100dpi" "$T/job.pdf" > "$T/bout" 2>&1
rc=$?
args=$(head -4 "$T/print.args" 2>/dev/null | tr '\n' '|')
pages=$(tr '\n' ' ' < "$T/print.pages" 2>/dev/null)
if [ $rc = 0 ] && [ "$args" = "print|DYMO LabelWriter 550/x|P295:72x36|2|" ] && [ "$pages" = "P6 P6 " ] &&
   sed -n 6p "$T/print.args" | grep -q '^Z:\\.*\\page-1\.ppm$'; then
    pass "the backend prints the PDF's pages (with their size) through the Windows driver of the device URI's printer"
else
    fail "the backend: rc $rc, args '$args', pages '$pages'"; cat "$T/bout" | sed 's/^/      /'
fi
[ $RC = 0 ] && echo "windows-printers test: PASS" || echo "windows-printers test: FAIL"
exit $RC
