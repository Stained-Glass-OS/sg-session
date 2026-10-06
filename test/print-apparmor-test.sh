#!/bin/sh
# Unit gate (make lint): the Print to PDF printer may write its PDF where
# sg-print-setup tells cups-pdf to (C:\users\NAME\Documents) under Debian's
# AppArmor profile for cups-pdf. With AppArmor enforcing (a kernel update
# brings it: Debian's kernels recommend apparmor) cups-pdf's ghostscript was
# denied creating the PDF there: the job ended "successfully" and nothing
# was saved (regression walk 2026-10-06). Our local include
# (config/apparmor/usr.lib.cups.backend.cups-pdf) is put into a copy of the
# system's cupsd profile: the profile still compiles, and the cups-pdf
# profile then has a rule letting the owner create and write
# .../users/alice/Documents/report.pdf -- and nothing outside Documents.
#   test/print-apparmor-test.sh [--mutant]   (77: no apparmor_parser or no
#   cupsd profile on this machine)
# SPDX-License-Identifier: AGPL-3.0-or-later
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
AA=${SG_AA_DIR:-/etc/apparmor.d}
PARSER=$(command -v apparmor_parser || ls /usr/sbin/apparmor_parser /sbin/apparmor_parser 2>/dev/null | head -1)
[ -n "$PARSER" ] && [ -f "$AA/usr.sbin.cupsd" ] && [ -d "$AA/tunables" ] || { echo "SKIP  no apparmor_parser or no cupsd profile"; exit 77; }
RC=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; RC=1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/local"
cp -r "$AA/tunables" "$AA/abstractions" "$T/"
[ -d "$AA/abi" ] && cp -r "$AA/abi" "$T/"
cp "$AA/usr.sbin.cupsd" "$T/"
SNIP="$HERE/../config/apparmor/usr.lib.cups.backend.cups-pdf"
if [ "${1:-}" = --mutant ]; then grep -v 'Documents/\*\*' "$SNIP" > "$T/local/usr.lib.cups.backend.cups-pdf"
else cp "$SNIP" "$T/local/usr.lib.cups.backend.cups-pdf"; fi
"$PARSER" -Q -K -I "$T" "$T/usr.sbin.cupsd" >"$T/err" 2>&1 && pass "the cupsd profile compiles with our include" || fail "the profile does not compile: $(head -3 "$T/err")"
"$PARSER" -Q -K -I "$T" -p "$T/usr.sbin.cupsd" > "$T/pre" 2>/dev/null
python3 - "$T/pre" <<'PY' || RC=1
import re, sys
text = open(sys.argv[1]).read()
# the cups-pdf profile's body, as preprocessed
m = re.search(r'^\s*/usr/lib/cups/backend/cups-pdf\s*\{(.*?)^\}', text, re.S | re.M)
if not m:
    print("FAIL  no cups-pdf profile in the preprocessed cupsd profile"); sys.exit(1)
rules = []
for line in m.group(1).splitlines():
    line = line.split('#', 1)[0].strip().rstrip(',')
    mm = re.match(r'^(owner\s+)?(/\S+)\s+([rwklmixaPUC]+)$', line)
    if mm:
        rules.append((mm.group(2), mm.group(3)))
def glob(p):
    out, i = '', 0
    while i < len(p):
        if p.startswith('**', i): out += '.*'; i += 2
        elif p[i] == '*': out += '[^/]*'; i += 1
        elif p[i] == '@': return None
        else: out += re.escape(p[i]); i += 1
    return re.compile(out + '$')
def allowed(path, perm):
    return any(g and g.match(path) and all(c in perms for c in perm)
               for g, perms in ((glob(p), q) for p, q in rules))
ok = True
pdf = '/var/lib/stained-glass/prefix/drive_c/users/alice/Documents/report.pdf'
if allowed(pdf, 'w'):
    print("PASS  cups-pdf may write " + pdf)
else:
    print("FAIL  cups-pdf may not write " + pdf); ok = False
other = '/var/lib/stained-glass/prefix/drive_c/windows/system32/x.pdf'
if allowed(other, 'w'):
    print("FAIL  cups-pdf may write outside Documents: " + other); ok = False
else:
    print("PASS  and nothing outside Documents (" + other + ")")
sys.exit(0 if ok else 1)
PY
[ $RC = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $RC
