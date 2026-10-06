#!/bin/sh
# The login screen's, Setup's and the first-run setup's drawn glyphs are
# smooth and Setup's icon has every size (David 2026-10-06: every icon we
# draw at a better resolution). GDI's Ellipse, RoundRect, Polygon, Polyline,
# Arc and slanted lines have stepped edges; greeter/sg-smooth.h (a copy of
# sg-shell's) draws them four times larger and averages them down.
#   1. no raw round or slanted GDI shape in greeter/*.c or setup/*.c: each
#      goes through sg-smooth.h, or is in a function drawn in a region
#      (a "sg-smooth:" comment above it), or is marked "sg-smooth:" with the
#      reason it stays hard-edged
#   2. Setup's icon (setup/make-icon.py) has 16, 20, 24, 32, 40, 48, 64,
#      96, 128 and 256 px frames
# Mutant: a raw call put back (SG_SMOOTH_EXTRA=FILE adds a file) fails 1;
# make-icon.py's old sizes fail 2.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
python3 - "$HERE" ${SG_SMOOTH_EXTRA:-} <<'PY' || RC=1
import glob, os, re, sys
here = sys.argv[1]
files = sorted(glob.glob(os.path.join(here, "greeter", "*.c")) + glob.glob(os.path.join(here, "setup", "*.c"))) + sys.argv[2:]
call = re.compile(r"(?<![\w.>])(Ellipse|RoundRect|Polygon|Polyline|PolyPolygon|Arc|ArcTo|AngleArc|Pie|Chord|PolyBezier)\s*\(")
head = re.compile(r"^[A-Za-z_][^;]*\(")
bad = []
for f in files:
    lines = open(f, errors="replace").read().split("\n")
    fn_ok = False
    for i, l in enumerate(lines):
        if head.match(l) and not l.rstrip().endswith(";"):
            fn_ok = "sg-smooth:" in (lines[i - 1] if i else "")
        if l.startswith("}"):
            fn_ok = False
        code = re.sub(r'"[^"]*"', '""', l)
        if code.lstrip().startswith(("*", "/*", "//")):
            continue
        if call.search(code) and not fn_ok and "sg-smooth:" not in l:
            bad.append("%s:%d: %s" % (os.path.relpath(f, here), i + 1, l.strip()[:90]))
if bad:
    print("FAIL  raw GDI shapes (stepped edges):\n      " + "\n      ".join(bad))
    sys.exit(1)
print("PASS  the greeter's, Setup's and the first-run setup's round and slanted shapes are drawn smooth (or marked)")
PY
T=$(mktemp -d /var/tmp/sg-smooth-glyphs.XXXXXX); trap 'rm -rf "$T"' EXIT INT TERM
python3 "$HERE/setup/make-icon.py" "$T/setup.ico" || fail "make-icon.py failed"
got=$(python3 - "$T/setup.ico" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
n = struct.unpack_from("<HHH", d)[2]
print(" ".join(str(d[6 + 16 * i] or 256) for i in range(n)))
PY
)
[ "$got" = "16 20 24 32 40 48 64 96 128 256" ] && pass "Setup's icon: $got px" || fail "Setup's icon has [$got] px"
exit $RC
