#!/usr/bin/python3
# SG PDF: a signature whose last byte is zero still checks (pdf/sgpdf_sign.py
# check_signature). A PDF signature's /Contents is the CMS signature padded
# with zeros to the room saved for it; reading it, trailing zeros were cut off
# before parsing -- and a signature whose own last byte is 0x00 (one in 256:
# the CMS ends with the signature value) lost that byte and read as
# "invalid". The release's pdf-inkcrypt-test failed so, now and then.
#
# Signs made-up documents until a CMS ends with a zero byte, pads it as a PDF
# does, and asks check_signature: not "invalid", and the same of an ordinary
# one. Mutant: SG_MUTANT_SIGPAD=1 cuts the zeros again (must fail it).
#
# SPDX-License-Identifier: AGPL-3.0-or-later
import datetime
import hashlib
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "pdf"))
FAILS = 0

try:
    import sgpdf_sign
except ImportError as e:
    print("SKIP: %s" % e)
    sys.exit(77)


def check(cond, what):
    global FAILS
    print(("PASS " if cond else "FAIL ") + what)
    if not cond:
        FAILS += 1
    return cond


ROOM = 8192


def signed_doc(key, cert, n):
    """a made-up document signed as a PDF is: -> (data, byte_range, cms)"""
    head = b"%%PDF-1.7\n%% document %d\n<</Contents " % n
    tail = b" /ByteRange [...]>>\n%%EOF\n"
    b = len(head)
    c = b + 2 + ROOM * 2
    digest = hashlib.sha256(head + tail).digest()
    when = datetime.datetime.now(datetime.timezone.utc)
    der = sgpdf_sign._sign_cms(digest, key, cert, [], when)
    contents = b"<" + der.hex().encode() + b"00" * (ROOM - len(der)) + b">"
    return head + contents + tail, (0, b, c, len(tail)), der


if os.environ.get("SG_MUTANT_SIGPAD"):
    _load = sgpdf_sign.cms.ContentInfo.load
    sgpdf_sign.cms.ContentInfo.load = staticmethod(
        lambda raw, strict=False: _load(raw.rstrip(b"\x00"), strict=strict))

with tempfile.TemporaryDirectory() as tmp:
    path = os.path.join(tmp, "id.pfx")
    sgpdf_sign.make_id(path, "pw", "Jane Q Signer")
    key, cert, _ = sgpdf_sign.load_id(path, "pw")

    data, br, der = signed_doc(key, cert, 0)
    res = sgpdf_sign.check_signature(data, br)
    check(res["status"] != "invalid" and res["covers"] == "1",
          "an ordinary signature checks (%s, %s)" % (res["status"], res["detail"]))

    zero = None
    for n in range(1, 4000):
        data, br, der = signed_doc(key, cert, n)
        if der.endswith(b"\x00"):
            zero = (data, br, der)
            break
    if check(zero is not None, "a signature ending in a zero byte (tries: %d)" % n):
        res = sgpdf_sign.check_signature(zero[0], zero[1])
        check(res["status"] != "invalid" and res["covers"] == "1",
              "a signature ending in a zero byte checks (%s, %s)" % (res["status"], res["detail"]))

print("pdf-sigpad-test: %s" % ("PASS" if not FAILS else "FAIL (%d failed)" % FAILS))
sys.exit(1 if FAILS else 0)
