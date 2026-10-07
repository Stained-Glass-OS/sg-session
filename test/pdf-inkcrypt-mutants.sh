#!/bin/sh
. "$(dirname "$0")/scratch-home.sh"
# Mutation test for test/pdf-inkcrypt-test.py: each mutant breaks one thing
# the gate guards in a copy of the engine (SG_PDF_LIB points sg-pdf at it);
# the gate must fail for every one.
#
#   INK_EVEN      the pen's widths not drawn (the stroke one width)
#   INK_FORGET    a moved or recoloured stroke loses its widths
#   CRYPT_PLAIN   the update of an encrypted document written unencrypted
#   CRYPT_KEY     the per-object key without the object's number
#   CRYPT_CONTENTS the signature's /Contents encrypted too
#   CRYPT_REFUSE  encrypted documents refused (the old behaviour)
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
PY=/usr/bin/python3
$PY -c 'import pymupdf, asn1crypto' 2>/dev/null || { echo "SKIP: python3-pymupdf or python3-asn1crypto missing"; exit 77; }
T=$(mktemp -d /var/tmp/sg-pdf-inkcrypt-mut.XXXXXX)
trap 'rm -rf "$T"' EXIT INT TERM
RC=0
mutant() {   # NAME FILE OLD NEW
    rm -rf "$T/lib"; cp -r "$HERE/pdf" "$T/lib"
    $PY - "$T/lib/$2" "$3" "$4" <<'PYEOF' || { echo "FAIL  mutant $1: its text was not found (the engine changed?)"; RC=1; return; }
import sys
p, old, new = sys.argv[1], sys.argv[2].encode().decode("unicode_escape"), sys.argv[3].encode().decode("unicode_escape")
s = open(p).read()
if old not in s:
    sys.exit(1)
open(p, "w").write(s.replace(old, new, 1))
PYEOF
    if SG_PDF_LIB="$T/lib" timeout 600 $PY "$HERE/test/pdf-inkcrypt-test.py" > "$T/$1.log" 2>&1; then
        echo "FAIL  mutant $1 survived: the gate passed with it"; RC=1
    else
        echo "PASS  mutant $1 killed ($(grep -c '^FAIL' "$T/$1.log") checks failed)"
    fi
}
mutant INK_EVEN sgpdf.py '            self._ink_variable(p, a, widths)\n        xref = a.xref' '            pass\n        xref = a.xref'
mutant INK_FORGET sgpdf.py '        rows = re.findall(' '        return None\n        rows = re.findall('
mutant CRYPT_PLAIN sgpdf_sign.py '        if crypt:\n            body = crypt.encrypt_object(' '        if False:\n            body = crypt.encrypt_object('
mutant CRYPT_KEY sgpdf_sign.py '        h = hashlib.md5(self.key + num.to_bytes(4, "little")[:3]' '        h = hashlib.md5(self.key + (0).to_bytes(4, "little")[:3]'
mutant CRYPT_CONTENTS sgpdf_sign.py '                if keep_after and re.search(' '                if False and re.search('
mutant CRYPT_REFUSE sgpdf.py '        if self.security is not None:\n            # a new password' '        if self.encrypted or self.security is not None:\n            # a new password'
[ $RC = 0 ] && echo "pdf-inkcrypt-mutants: every mutant killed"
exit $RC
