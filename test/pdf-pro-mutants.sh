#!/bin/sh
. "$(dirname "$0")/scratch-home.sh"
# Mutation test for test/pdf-pro-test.py: each mutant breaks one thing the
# gate guards in a copy of the engine (SG_PDF_LIB points sg-pdf at it); the
# gate must fail for every one.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
PY=/usr/bin/python3
$PY -c 'import pymupdf, asn1crypto' 2>/dev/null || { echo "SKIP: python3-pymupdf or python3-asn1crypto missing"; exit 77; }
T=$(mktemp -d /var/tmp/sg-pdf-pro-mut.XXXXXX)
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
    if SG_PDF_LIB="$T/lib" timeout 900 $PY "$HERE/test/pdf-pro-test.py" > "$T/$1.log" 2>&1; then
        echo "FAIL  mutant $1 survived: the gate passed with it"; RC=1
    else
        echo "PASS  mutant $1 killed ($(grep -c '^FAIL' "$T/$1.log") checks failed)"
    fi
}
mutant CALC sgpdf_forms.py '    changed = []\n    for p, w in calc[:limit]:' '    changed = []\n    calc = []\n    for p, w in calc[:limit]:'
mutant KEYSTROKE sgpdf_forms.py '    if not spec or not value.strip():\n        return value' '    if True:\n        return value'
mutant DETECT sgpdf_forms.py '    found.sort(key=lambda f: (round(f[1].y0 / 4), f[1].x0))\n    return found' '    return []'
mutant RADIO sgpdf_forms.py '    t, name = doc.xref_get_key(xref, "T")\n    if t != "string":' '    t, name = doc.xref_get_key(xref, "T")\n    if True:'
mutant DIGEST sgpdf_sign.py 'digest = hashlib.sha256(bytes(out[:i]) + bytes(out[j:])).digest()' 'digest = hashlib.sha256(bytes(out[:i - 1]) + bytes(out[j:])).digest()'
mutant APPEND sgpdf_sign.py '    prev = _last_xref(base)\n    out = bytearray(base)' '    prev = _last_xref(base)\n    base = fitz.open("pdf", base).tobytes()\n    prev = _last_xref(base)\n    out = bytearray(base)'
mutant CHECK sgpdf_sign.py '            if md != digest:' '            if False:'
mutant OCR sgpdf_create.py '    with open(out, "rb") as f:\n        return f.read()\n\n\n# ---- headers' '    return data\n\n\n# ---- headers'
mutant DECORATE sgpdf_create.py '    count = doc.page_count\n    size =' '    return 0\n    size ='
mutant ATTACH sgpdf.py '                f.write(data)\n        except OSError as e:\n            raise Refusal("failed", "could not save: "' '                f.write(data[:-1])\n        except OSError as e:\n            raise Refusal("failed", "could not save: "'
[ $RC = 0 ] && echo "pdf-pro-mutants: every mutant killed"
exit $RC
