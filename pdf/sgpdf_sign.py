# sgpdf_sign -- SG PDF's certificate signatures: signing with a digital ID
# (a .pfx/.p12 file: a private key and its certificate) and checking the
# signatures a document carries.
#
# A signature is the familiar standard one (ISO 32000 "adbe.pkcs7.detached"
# with PAdES's signed attributes): a CMS SignedData over the whole file but
# the signature's own value, appended as an incremental update -- the file
# as it was stays byte for byte, so signatures made before stay valid and a
# second person can sign after the first. The update holds the signature
# dictionary, the field (a new one where the person drew it, or an empty
# signature field of the form), its appearance ("Digitally signed by ...",
# the date, the reason; the person's drawn or typed signature beside it),
# the page's annotations and the form's /SigFlags.
#
# Checking: the signed bytes' digest against the signature's message digest,
# the signature against the signer's certificate, whether the signature
# covers the file to its end (changes after signing are reported), and the
# certificate path to the system's trusted roots (pyhanko-certvalidator when
# installed; a self-signed digital ID is valid but its signer unknown).
#
# Digital IDs: a self-signed one can be made here (RSA 2048, SHA-256), as
# the familiar editor offers, for people without one from a provider.
#
# Our own code on python3-cryptography and python3-asn1crypto.
#
# Copyright (C) 2026 Stained Glass OS contributors
# SPDX-License-Identifier: AGPL-3.0-or-later

import datetime
import hashlib
import os
import re

from asn1crypto import algos, cms, x509 as ax509
from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID

CONTENTS_BYTES = 16384          # room for the CMS: the signature and the certificates
TRUST_BUNDLE = "/etc/ssl/certs/ca-certificates.crt"


class SignError(Exception):
    pass


# ---- digital IDs ------------------------------------------------------------------------------------------

def load_id(path, password):
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        raise SignError("could not read the digital ID: %s" % (e.strerror or e))
    try:
        key, cert, extra = pkcs12.load_key_and_certificates(data, password.encode("utf-8") if password else None)
    except ValueError:
        raise SignError("the digital ID's password is not right, or the file is not a digital ID (.pfx, .p12)")
    if key is None or cert is None:
        raise SignError("the digital ID has no private key and certificate")
    if not isinstance(key, (rsa.RSAPrivateKey, ec.EllipticCurvePrivateKey)):
        raise SignError("the digital ID's key is of a kind this program cannot sign with")
    return key, cert, list(extra or [])


def id_name(cert):
    for oid in (NameOID.COMMON_NAME, NameOID.EMAIL_ADDRESS, NameOID.ORGANIZATION_NAME):
        v = cert.subject.get_attributes_for_oid(oid)
        if v:
            return str(v[0].value)
    return cert.subject.rfc4514_string()


def make_id(path, password, name, email="", org="", years=5):
    """a self-signed digital ID, written as a password-protected .pfx"""
    if not name.strip():
        raise SignError("a digital ID needs a name")
    if not password:
        raise SignError("a digital ID needs a password")
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    attrs = [x509.NameAttribute(NameOID.COMMON_NAME, name.strip())]
    if org.strip():
        attrs.append(x509.NameAttribute(NameOID.ORGANIZATION_NAME, org.strip()))
    if email.strip():
        attrs.append(x509.NameAttribute(NameOID.EMAIL_ADDRESS, email.strip()))
    subject = x509.Name(attrs)
    now = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=5)
    b = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject).public_key(key.public_key())
         .serial_number(x509.random_serial_number()).not_valid_before(now)
         .not_valid_after(now + datetime.timedelta(days=365 * years))
         .add_extension(x509.KeyUsage(digital_signature=True, content_commitment=True, key_encipherment=False,
                                      data_encipherment=False, key_agreement=False, key_cert_sign=False,
                                      crl_sign=False, encipher_only=False, decipher_only=False), critical=True)
         .add_extension(x509.ExtendedKeyUsage([x509.oid.ExtendedKeyUsageOID.EMAIL_PROTECTION,
                                               x509.ObjectIdentifier("1.2.840.113583.1.1.5")]), critical=False))
    if email.strip():
        b = b.add_extension(x509.SubjectAlternativeName([x509.RFC822Name(email.strip())]), critical=False)
    cert = b.sign(key, hashes.SHA256())
    data = pkcs12.serialize_key_and_certificates(
        name.strip().encode("utf-8"), key, cert, None,
        serialization.BestAvailableEncryption(password.encode("utf-8")))
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    os.replace(tmp, path)
    return cert


# ---- the CMS signature ------------------------------------------------------------------------------------------

def _sign_cms(digest, key, cert, chain, when):
    acert = ax509.Certificate.load(cert.public_bytes(serialization.Encoding.DER))
    ess = _signing_certificate_v2(acert)
    attrs = cms.CMSAttributes([
        cms.CMSAttribute({"type": "content_type", "values": ["data"]}),
        cms.CMSAttribute({"type": "signing_time", "values": [cms.Time({"utc_time": when})]}),
        cms.CMSAttribute({"type": "message_digest", "values": [digest]}),
        cms.CMSAttribute({"type": "signing_certificate_v2", "values": [ess]}),
    ])
    to_sign = attrs.dump()
    if isinstance(key, rsa.RSAPrivateKey):
        sig = key.sign(to_sign, padding.PKCS1v15(), hashes.SHA256())
        sig_alg = {"algorithm": "sha256_rsa"}
    else:
        sig = key.sign(to_sign, ec.ECDSA(hashes.SHA256()))
        sig_alg = {"algorithm": "sha256_ecdsa"}
    certs = [acert] + [ax509.Certificate.load(c.public_bytes(serialization.Encoding.DER)) for c in chain]
    signer = cms.SignerInfo({
        "version": "v1",
        "sid": cms.SignerIdentifier({"issuer_and_serial_number": cms.IssuerAndSerialNumber({
            "issuer": acert.issuer, "serial_number": acert.serial_number})}),
        "digest_algorithm": algos.DigestAlgorithm({"algorithm": "sha256"}),
        "signed_attrs": attrs,
        "signature_algorithm": algos.SignedDigestAlgorithm(sig_alg),
        "signature": sig,
    })
    sd = cms.SignedData({
        "version": "v1",
        "digest_algorithms": [algos.DigestAlgorithm({"algorithm": "sha256"})],
        "encap_content_info": {"content_type": "data"},
        "certificates": certs,
        "signer_infos": [signer],
    })
    return cms.ContentInfo({"content_type": "signed_data", "content": sd}).dump()


def _signing_certificate_v2(acert):
    """ESS signing-certificate-v2 (RFC 5035): the signer's certificate's SHA-256 -- PAdES asks for it"""
    from asn1crypto import tsp
    return tsp.SigningCertificateV2({
        "certs": [tsp.ESSCertIDv2({
            "hash_algorithm": {"algorithm": "sha256"},
            "cert_hash": hashlib.sha256(acert.dump()).digest(),
            "issuer_serial": {"issuer": [ax509.GeneralName({"directory_name": acert.issuer})],
                              "serial_number": acert.serial_number},
        })]
    })


# ---- PDF objects and the incremental update ------------------------------------------------------------------

def _pdf_str(s):
    """a PDF text string: PDFDocEncoding-safe ASCII literal, else UTF-16BE hex"""
    if all(32 <= ord(c) < 127 for c in s):
        return "(" + s.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)") + ")"
    return "<FEFF" + s.encode("utf-16-be").hex().upper() + ">"


def _pdf_date(when):
    off = when.utcoffset() or datetime.timedelta(0)
    mins = int(off.total_seconds() // 60)
    sign = "+" if mins >= 0 else "-"
    mins = abs(mins)
    return "D:%s%s%02d'%02d'" % (when.strftime("%Y%m%d%H%M%S"), sign, mins // 60, mins % 60) if off else \
        "D:%sZ" % when.strftime("%Y%m%d%H%M%S")


def _last_xref(data):
    m = list(re.finditer(rb"startxref\s+(\d+)", data))
    if not m:
        raise SignError("the file has no cross-reference to append to")
    return int(m[-1].group(1))


def _ap_escape(s):
    return s.encode("latin-1", "replace").replace(b"\\", b"\\\\").replace(b"(", b"\\(").replace(b")", b"\\)")


def _wrap(text, size, width):
    """break text into lines no wider than width (Helvetica's average advance ~0.52 em)"""
    out = []
    for para in text.split("\n"):
        line = ""
        for word in para.split(" "):
            t = (line + " " + word).strip()
            if len(t) * size * 0.52 <= width or not line:
                line = t
            else:
                out.append(line)
                line = word
        out.append(line)
    return out


def appearance(w, h, lines, picture=None):
    """the field's appearance: the text on the right (or alone), a picture (the person's signature,
    an image XObject name) on the left"""
    ops = [b"q"]
    tx = 2.0
    if picture:
        pw = w * 0.45
        ops.append(b"q %.2f 0 0 %.2f 2 2 cm /Sig Do Q" % (pw - 4, h - 4))
        tx = pw + 2
    tw = w - tx - 2
    size = 10.0
    while size > 4:
        wrapped = []
        for ln in lines:
            wrapped += _wrap(ln, size, tw)
        if len(wrapped) * size * 1.15 <= h - 2:
            break
        size -= 0.5
    y = h - 1 - size
    ops.append(b"BT /SgHelv %.2f Tf 0 0 0 rg" % size)
    for ln in wrapped:
        ops.append(b"1 0 0 1 %.2f %.2f Tm (%s) Tj" % (tx, y, _ap_escape(ln)))
        y -= size * 1.15
    ops.append(b"ET Q")
    return b"\n".join(ops)


def sign_file(base, out_path, fitz, field_xref=None, page_no=None, rect=None, field_name=None,
              pfx=None, password=None, reason="", location="", contact="", picture_png=None, when=None,
              doc_password=None):
    """append a signature to the PDF bytes `base`, write the signed file to out_path.
    Either field_xref (an empty signature field) or page_no + rect (points, unrotated page) +
    field_name for a new field. picture_png: the person's signature drawn beside the text.
    doc_password: an encrypted document's password (the update is encrypted with its key)."""
    key, cert, chain = load_id(pfx, password)
    doc = fitz.open("pdf", base)
    if doc.needs_pass and not doc.authenticate(doc_password or ""):
        raise SignError("the document's password is needed to sign it")
    crypt, encrypt_ref = _crypt_of(doc, base, doc_password)
    when = when or datetime.datetime.now().astimezone().replace(microsecond=0)
    signer = id_name(cert)
    size = doc.xref_length()
    next_obj = [size]

    def new_obj():
        n = next_obj[0]
        next_obj[0] += 1
        return n
    objs = {}
    cat = doc.pdf_catalog()

    # the field
    if field_xref:
        w_xref = int(field_xref)
        t, _ = doc.xref_get_key(w_xref, "FT")
        par = doc.xref_get_key(w_xref, "Parent")
        if t == "null" and par[0] != "xref":
            raise SignError("that is not a signature field")
        if doc.xref_get_key(w_xref, "V")[0] != "null":
            raise SignError("that field is signed already")
        page = None
        for p in doc:
            if any(a == w_xref for a in [x[0] for x in p.annot_xrefs()]):
                page = p
                break
        if page is None:
            raise SignError("the field is not on a page")
        r = fitz.Rect([float(x) for x in re.findall(r"[-\d.]+", doc.xref_get_key(w_xref, "Rect")[1])])
        new_field = False
    else:
        page = doc[int(page_no)]
        r = fitz.Rect(rect)
        if r.is_empty or r.width < 8 or r.height < 8:
            raise SignError("the signature's box is too small")
        w_xref = new_obj()
        new_field = True
    r = r.normalize()
    sig_xref, ap_xref, font_xref = new_obj(), new_obj(), new_obj()
    pic_xref = new_obj() if picture_png else None

    lines = ["Digitally signed by %s" % signer, "Date: %s" % when.strftime("%Y.%m.%d %H:%M:%S %z")]
    if reason:
        lines.append("Reason: %s" % reason)
    if location:
        lines.append("Location: %s" % location)
    # the appearance's box follows the page's rotation, as the field shows upright
    rot = page.rotation % 360
    bw, bh = (r.height, r.width) if rot in (90, 270) else (r.width, r.height)
    stream = appearance(bw, bh, lines, "Sig" if picture_png else None)
    matrix = {0: "", 90: "/Matrix[0 1 -1 0 0 0]", 180: "/Matrix[-1 0 0 -1 0 0]", 270: "/Matrix[0 -1 1 0 0 0]"}[rot]
    res = "/Font<</SgHelv %d 0 R>>" % font_xref
    if pic_xref:
        res += "/XObject<</Sig %d 0 R>>" % pic_xref
    objs[ap_xref] = (b"<</Type/XObject/Subtype/Form/BBox[0 0 %.2f %.2f]%s/Resources<<%s>>/Length %d>>\nstream\n" % (
        bw, bh, matrix.encode(), res.encode(), len(stream))) + stream + b"\nendstream"
    objs[font_xref] = b"<</Type/Font/Subtype/Type1/BaseFont/Helvetica/Encoding/WinAnsiEncoding>>"
    if pic_xref:
        objs[pic_xref] = _image_xobject(picture_png, fitz)

    placeholder = b"0" * (CONTENTS_BYTES * 2)
    br_placeholder = b"[0 0000000000 0000000000 0000000000]"
    sigdict = (b"<</Type/Sig/Filter/Adobe.PPKLite/SubFilter/adbe.pkcs7.detached/ByteRange" + br_placeholder +
               b"/Contents<" + placeholder + b">/M" + _pdf_str(_pdf_date(when)).encode() +
               b"/Name" + _pdf_str(signer).encode())
    if reason:
        sigdict += b"/Reason" + _pdf_str(reason).encode()
    if location:
        sigdict += b"/Location" + _pdf_str(location).encode()
    if contact:
        sigdict += b"/ContactInfo" + _pdf_str(contact).encode()
    sigdict += b"/Prop_Build<</App<</Name/SG#20PDF>>>>>>"
    objs[sig_xref] = sigdict

    if new_field:
        name = field_name or "Signature"
        existing = set()
        for p in doc:
            for wd in p.widgets():
                existing.add(wd.field_name)
        base_name, k = name, 2
        while name in existing:
            name = "%s_%d" % (base_name, k)
            k += 1
        pr = (r * ~page.transformation_matrix).normalize()     # MuPDF's top-down box -> PDF space
        objs[w_xref] = ("<</Type/Annot/Subtype/Widget/FT/Sig/T%s/Rect[%.3f %.3f %.3f %.3f]/F 132/P %d 0 R"
                        "/V %d 0 R/AP<</N %d 0 R>>>>" % (
                            _pdf_str(name), pr.x0, pr.y0, pr.x1, pr.y1, page.xref, sig_xref, ap_xref)).encode()
        # the page's annotations
        t, annots = doc.xref_get_key(page.xref, "Annots")
        if t == "array":
            new_annots = annots.rstrip().rstrip("]") + " %d 0 R]" % w_xref
            objs[page.xref] = _with_key(doc, page.xref, "Annots", new_annots)
        elif t == "xref":
            ax = int(annots.split()[0])
            arr = doc.xref_object(ax, compressed=True)
            objs[ax] = (arr.rstrip().rstrip("]") + " %d 0 R]" % w_xref).encode()
        else:
            objs[page.xref] = _with_key(doc, page.xref, "Annots", "[%d 0 R]" % w_xref)
    else:
        objs[w_xref] = _with_keys(doc, w_xref, {"V": "%d 0 R" % sig_xref, "AP": "<</N %d 0 R>>" % ap_xref})

    # the form: the new field among its fields, /SigFlags 3
    t, af = doc.xref_get_key(cat, "AcroForm")
    if t == "xref":
        af_xref = int(af.split()[0])
        af_obj = doc.xref_object(af_xref, compressed=True)
        objs[af_xref] = _form_dict(af_obj, w_xref if new_field else None).encode()
    else:
        af_obj = af if t == "dict" else "<<>>"
        objs[cat] = _with_key(doc, cat, "AcroForm", _form_dict(af_obj, w_xref if new_field else None))

    # the update: objects, a cross-reference section, a trailer
    prev = _last_xref(base)
    out = bytearray(base)
    if not out.endswith(b"\n"):
        out += b"\n"
    offsets = {}
    for num in sorted(objs):
        offsets[num] = len(out)
        body = objs[num]
        if crypt:
            body = crypt.encrypt_object(num, body, keep_after="Contents" if num == sig_xref else None)
        out += b"%d 0 obj\n" % num + body + b"\nendobj\n"
    trailer_keys = _trailer(doc) + encrypt_ref
    xref_pos = len(out)
    size_new = max(next_obj[0], size)
    if _is_xref_stream(base, prev):
        xs_num = size_new
        size_new += 1
        offsets[xs_num] = xref_pos
        rows, index = b"", []
        for num in sorted(offsets):
            rows += bytes([1]) + offsets[num].to_bytes(4, "big") + (0).to_bytes(2, "big")
            index += [num, 1]
        out += (b"%d 0 obj\n<</Type/XRef/Size %d/W[1 4 2]/Index[%s]/Prev %d%s/Length %d>>\nstream\n" % (
            xs_num, size_new, " ".join(str(i) for i in index).encode(), prev, trailer_keys.encode(), len(rows)))
        out += rows + b"\nendstream\nendobj\n"
    else:
        out += b"xref\n"
        for num in sorted(offsets):
            out += b"%d 1\n%010d 00000 n \n" % (num, offsets[num])
        out += b"trailer\n<</Size %d/Prev %d%s>>\n" % (size_new, prev, trailer_keys.encode())
    out += b"startxref\n%d\n%%%%EOF\n" % xref_pos

    # the byte range: everything but the hex string of /Contents
    i = out.index(b"/Contents<" + placeholder[:64], offsets[sig_xref]) + len(b"/Contents")
    j = i + 2 + len(placeholder)
    br = b"[0 %d %d %d]" % (i, j, len(out) - j)
    k = out.index(br_placeholder, offsets[sig_xref])
    out[k:k + len(br_placeholder)] = br.ljust(len(br_placeholder), b" ")
    digest = hashlib.sha256(bytes(out[:i]) + bytes(out[j:])).digest()
    der = _sign_cms(digest, key, cert, chain, when.astimezone(datetime.timezone.utc))
    if len(der) > CONTENTS_BYTES:
        raise SignError("the signature is too large (too many certificates)")
    hexsig = der.hex().upper().encode().ljust(len(placeholder), b"0")
    out[i + 1:j - 1] = hexsig
    tmp = out_path + ".sgsign.tmp"
    with open(tmp, "wb") as f:
        f.write(bytes(out))
    os.replace(tmp, out_path)
    return signer


def _image_xobject(png, fitz):
    pix = fitz.Pixmap(png)
    alpha = None
    if pix.alpha:
        alpha = fitz.Pixmap(None, pix)        # the alpha channel alone
        pix = fitz.Pixmap(pix, 0)
    if pix.n != 3:
        pix = fitz.Pixmap(fitz.csRGB, pix)
    import zlib
    data = zlib.compress(pix.samples)
    head = b"<</Type/XObject/Subtype/Image/Width %d/Height %d/ColorSpace/DeviceRGB/BitsPerComponent 8" \
           b"/Filter/FlateDecode/Length %d" % (pix.width, pix.height, len(data))
    if alpha is not None:
        # an inline soft mask is not allowed: the mask goes as /SMask of a stream the caller cannot
        # number, so the alpha is applied onto white instead
        rgb = bytearray(pix.samples)
        a = alpha.samples
        for k in range(len(a)):
            f = a[k] / 255.0
            for c in range(3):
                rgb[3 * k + c] = int(rgb[3 * k + c] * f + 255 * (1 - f))
        data = zlib.compress(bytes(rgb))
        head = b"<</Type/XObject/Subtype/Image/Width %d/Height %d/ColorSpace/DeviceRGB/BitsPerComponent 8" \
               b"/Filter/FlateDecode/Length %d" % (pix.width, pix.height, len(data))
    return head + b">>\nstream\n" + data + b"\nendstream"


def _with_key(doc, xref, key, value):
    return _with_keys(doc, xref, {key: value})


def _with_keys(doc, xref, kv):
    """the object's dictionary with keys set, written as MuPDF reads it"""
    obj = doc.xref_object(xref, compressed=True)
    if doc.xref_is_stream(xref):
        raise SignError("cannot rewrite a stream object")
    obj = obj.strip()
    if not obj.startswith("<<"):
        raise SignError("not a dictionary")
    for k, v in kv.items():
        obj = _set_in_dict(obj, k, v)
    return obj.encode("latin-1")


def _set_in_dict(d, key, value):
    """set /key in a dictionary's text (the top level only)"""
    body = d[2:-2]
    found = False
    tokens = _top_level_entries(body)
    parts = []
    for k, v in tokens:
        if k == key:
            parts.append("/%s %s" % (k, value))
            found = True
        else:
            parts.append("/%s %s" % (k, v))
    if not found:
        parts.append("/%s %s" % (key, value))
    return "<<" + "".join(parts) + ">>"


def _top_level_entries(body):
    """[(key, value text)] of a dictionary body"""
    entries = []
    i, n = 0, len(body)
    while i < n:
        while i < n and body[i] in " \r\n\t":
            i += 1
        if i >= n:
            break
        if body[i] != "/":
            raise SignError("unexpected dictionary text")
        j = i + 1
        while j < n and body[j] not in " \r\n\t/<>[]()":
            j += 1
        key = body[i + 1:j]
        k = _skip_value(body, j)
        entries.append((key, body[j:k].strip()))
        i = k
    return entries


def _skip_value(s, i):
    n = len(s)
    while i < n and s[i] in " \r\n\t":
        i += 1
    if i >= n:
        return i
    c = s[i]
    if s.startswith("<<", i):
        depth, i = 0, i
        while i < n:
            if s.startswith("<<", i):
                depth += 1
                i += 2
            elif s.startswith(">>", i):
                depth -= 1
                i += 2
                if depth == 0:
                    return i
            elif s[i] == "(":
                i = _skip_string(s, i)
            else:
                i += 1
        return i
    if c == "[":
        depth = 0
        while i < n:
            if s[i] == "[":
                depth += 1
            elif s[i] == "]":
                depth -= 1
                if depth == 0:
                    return i + 1
            elif s[i] == "(":
                i = _skip_string(s, i) - 1
            i += 1
        return i
    if c == "(":
        return _skip_string(s, i)
    if c == "<":
        return s.index(">", i) + 1
    if c == "/":
        i += 1
        while i < n and s[i] not in " \r\n\t/<>[]()":
            i += 1
        return i
    # number, ref ("12 0 R"), boolean, null
    m = re.match(r"\s*(\d+\s+\d+\s+R|[-+.\w]+)", s[i:])
    return i + (m.end() if m else 1)


def _skip_string(s, i):
    depth, i = 0, i
    while i < len(s):
        if s[i] == "\\":
            i += 2
            continue
        if s[i] == "(":
            depth += 1
        elif s[i] == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return i


def _form_dict(af, new_field):
    entries = dict(_top_level_entries(af.strip()[2:-2])) if af.strip().startswith("<<") else {}
    fields = entries.get("Fields", "[]")
    if new_field is not None:
        fields = fields.rstrip().rstrip("]") + " %d 0 R]" % new_field
    entries["Fields"] = fields
    entries["SigFlags"] = "3"
    return "<<" + "".join("/%s %s" % (k, v) for k, v in entries.items()) + ">>"


def _trailer(doc):
    out = "/Root %d 0 R" % doc.pdf_catalog()
    t, v = doc.xref_get_key(-1, "Info")
    if t == "xref":
        out += "/Info " + v
    t, v = doc.xref_get_key(-1, "ID")
    if t == "array":
        out += "/ID" + v
    return out


def _is_xref_stream(data, pos):
    return not data[pos:pos + 4] == b"xref"


# ---- encrypted documents --------------------------------------------------------------------------------
#
# A document with a password is signed as it is: the update's objects are
# encrypted with the document's own key (ISO 32000's standard security
# handler: RC4 or AES-128 per object, AES-256 for revision 5/6), so it keeps
# its password and its permissions, and the person's password opens the new
# revision as it opened the old. The key is derived here from the password
# the document was opened with, in memory only. As the standard says, the
# signature's /Contents is not encrypted (it is signed bytes, not text), the
# cross-reference stream is not, and nothing else in the update is left
# plain.

_PAD = bytes.fromhex("28BF4E5E4E758A4164004E56FFFA01082E2E00B6D0683E802F0CA9FE6453697A")


def _rc4(key, data):
    s = list(range(256))
    j = 0
    for i in range(256):
        j = (j + s[i] + key[i % len(key)]) & 255
        s[i], s[j] = s[j], s[i]
    out = bytearray(len(data))
    i = j = 0
    for k, b in enumerate(data):
        i = (i + 1) & 255
        j = (j + s[i]) & 255
        s[i], s[j] = s[j], s[i]
        out[k] = b ^ s[(s[i] + s[j]) & 255]
    return bytes(out)


def _aes_cbc(key, iv, data, encrypt=True):
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    c = Cipher(algorithms.AES(key), modes.CBC(iv))
    x = c.encryptor() if encrypt else c.decryptor()
    return x.update(data) + x.finalize()


def _pdf_string_bytes(tok):
    """the bytes of a PDF string token, (literal) or <hex>"""
    tok = tok.strip()
    if tok.startswith("<"):
        h = re.sub(r"\s", "", tok[1:-1])
        if len(h) % 2:
            h += "0"
        return bytes.fromhex(h)
    out, i, body = bytearray(), 0, tok[1:-1]
    esc = {"n": 10, "r": 13, "t": 9, "b": 8, "f": 12, "(": 40, ")": 41, "\\": 92}
    while i < len(body):
        c = body[i]
        if c == "\\" and i + 1 < len(body):
            d = body[i + 1]
            if d in esc:
                out.append(esc[d])
                i += 2
            elif d in "01234567":
                m = re.match(r"[0-7]{1,3}", body[i + 1:])
                out.append(int(m.group(0), 8) & 255)
                i += 1 + len(m.group(0))
            elif d in "\r\n":
                i += 2
                if d == "\r" and i < len(body) and body[i] == "\n":
                    i += 1
            else:
                out.append(ord(d) & 255)
                i += 2
        else:
            out.append(ord(c) & 255)
            i += 1
    return bytes(out)


def _hash_r6(pw, salt, udata, r):
    if r == 5:
        return hashlib.sha256(pw + salt + udata).digest()
    k = hashlib.sha256(pw + salt + udata).digest()
    i = 0
    while True:
        k1 = (pw + k + udata) * 64
        e = _aes_cbc(k[:16], k[16:32], k1)
        h = {0: hashlib.sha256, 1: hashlib.sha384, 2: hashlib.sha512}[sum(e[:16]) % 3]
        k = h(e).digest()
        i += 1
        if i >= 64 and e[-1] <= i - 32:
            break
    return k[:32]


class _Crypt:
    """the document's file key and how it encrypts strings and streams"""

    def __init__(self, enc, id0, password):
        def get(key, default=None):
            v = dict(enc).get(key)
            return default if v is None else v
        if get("Filter", "").strip() != "/Standard":
            raise SignError("the document is encrypted with a security handler other than the standard one")
        self.v = int(get("V", "0"))
        self.r = int(get("R", "2"))
        o, u = _pdf_string_bytes(get("O", "<>")), _pdf_string_bytes(get("U", "<>"))
        self.length = int(get("Length", "40")) // 8 if self.v > 1 else 5
        self.stm = self.strm = "rc4"
        if self.v >= 4:
            cfs = dict(_top_level_entries(get("CF", "<<>>").strip()[2:-2]))

            def method(name):
                name = name.strip().lstrip("/")
                if name in ("", "Identity"):
                    return "none"
                cfm = dict(_top_level_entries(cfs.get(name, "<<>>").strip()[2:-2])).get("CFM", "/None").strip()
                return {"/V2": "rc4", "/AESV2": "aes128", "/AESV3": "aes256", "/None": "none"}.get(cfm, "unknown")
            self.stm, self.strm = method(get("StmF", "/Identity")), method(get("StrF", "/Identity"))
            if "unknown" in (self.stm, self.strm):
                raise SignError("the document's encryption method is not one this program writes")
            if self.v == 4:
                self.length = 16
        pw = (password or "").encode("utf-8")
        if self.r >= 5:
            pw = pw[:127]
            oe, ue = _pdf_string_bytes(get("OE", "<>")), _pdf_string_bytes(get("UE", "<>"))
            if _hash_r6(pw, u[32:40], b"", self.r) == u[:32]:
                self.key = _aes_cbc(_hash_r6(pw, u[40:48], b"", self.r), b"\0" * 16, ue, False)
            elif _hash_r6(pw, o[32:40], u[:48], self.r) == o[:32]:
                self.key = _aes_cbc(_hash_r6(pw, o[40:48], u[:48], self.r), b"\0" * 16, oe, False)
            else:
                raise SignError("the document's password is not right")
            return
        p = int(get("P", "0")) & 0xFFFFFFFF
        meta = get("EncryptMetadata", "true").strip() != "false"
        n = self.length

        def user_key(upw):
            h = hashlib.md5((upw + _PAD)[:32] + o[:32] + p.to_bytes(4, "little") + id0 +
                            (b"\xff\xff\xff\xff" if self.r >= 4 and not meta else b"")).digest()
            if self.r >= 3:
                for _ in range(50):
                    h = hashlib.md5(h[:n]).digest()
            return h[:n]

        def user_ok(key):
            if self.r == 2:
                return _rc4(key, _PAD) == u[:32]
            x = hashlib.md5(_PAD + id0).digest()
            for i in range(20):
                x = _rc4(bytes(b ^ i for b in key), x)
            return x == u[:16]
        k = user_key(pw[:32])
        if not user_ok(k):
            # the owner's password: it unlocks the user's (Algorithm 7)
            h = hashlib.md5((pw[:32] + _PAD)[:32]).digest()
            if self.r >= 3:
                for _ in range(50):
                    h = hashlib.md5(h).digest()
            okey = h[:n]
            x = o[:32]
            if self.r == 2:
                x = _rc4(okey, x)
            else:
                for i in range(19, -1, -1):
                    x = _rc4(bytes(b ^ i for b in okey), x)
            k = user_key(x)
            if not user_ok(k):
                raise SignError("the document's password is not right")
        self.key = k

    def _obj_key(self, num, gen, aes):
        if self.r >= 5:
            return self.key
        h = hashlib.md5(self.key + num.to_bytes(4, "little")[:3] + gen.to_bytes(2, "little") +
                        (b"sAlT" if aes else b"")).digest()
        return h[:min(len(self.key) + 5, 16)]

    def encrypt(self, data, num, gen=0, stream=False):
        method = self.stm if stream else self.strm
        if method == "none":
            return data
        if method == "rc4":
            return _rc4(self._obj_key(num, gen, False), data)
        iv = os.urandom(16)
        padn = 16 - len(data) % 16
        return iv + _aes_cbc(self._obj_key(num, gen, True), iv, data + bytes([padn]) * padn)

    def encrypt_strings(self, text, num, keep_after=None):
        """the object's text with every string encrypted (written as hex); a string right after
        the key keep_after (the signature's /Contents) is left as it is"""
        out, i, n = [], 0, len(text)
        while i < n:
            c = text[i]
            if c == "(" or (c == "<" and not text.startswith("<<", i)):
                j = _skip_string(text, i) if c == "(" else text.index(">", i) + 1
                tok = text[i:j]
                if keep_after and re.search(r"/%s\s*$" % keep_after, text[:i]):
                    out.append(tok)
                else:
                    out.append("<" + self.encrypt(_pdf_string_bytes(tok), num).hex().upper() + ">")
                i = j
            elif c == "<":
                out.append("<<")
                i += 2
            else:
                out.append(c)
                i += 1
        return "".join(out)

    def encrypt_object(self, num, obj, keep_after=None):
        """an object as written in the update (bytes), encrypted: its strings, and its stream's data
        with /Length made the encrypted length"""
        k = obj.find(b">>\nstream\n")
        if k < 0:
            return self.encrypt_strings(obj.decode("latin-1"), num, keep_after).encode("latin-1")
        head = obj[:k + 2].decode("latin-1")
        data = obj[k + len(b">>\nstream\n"):obj.rindex(b"\nendstream")]
        enc = self.encrypt(data, num, stream=True)
        head = re.sub(r"/Length \d+", "/Length %d" % len(enc), self.encrypt_strings(head, num))
        return head.encode("latin-1") + b"\nstream\n" + enc + b"\nendstream"


def _crypt_of(doc, base, password):
    """(the document's _Crypt, its trailer's /Encrypt entry), or (None, "") for a plain document"""
    t, v = doc.xref_get_key(-1, "Encrypt")
    if t in ("null", "") or not v or v == "null":
        return None, ""
    m = list(re.finditer(rb"/Encrypt\s*(\d+)\s+(\d+)\s+R", base))
    if m:
        ref = "/Encrypt %d %d R" % (int(m[-1].group(1)), int(m[-1].group(2)))
        enc_text = doc.xref_object(int(m[-1].group(1)), compressed=True)
    else:
        enc_text = v if t == "dict" else doc.xref_get_key(-1, "Encrypt")[1]
        enc_text = re.sub(r"\s+", " ", enc_text)
        ref = "/Encrypt" + enc_text
    enc = _top_level_entries(enc_text.strip()[2:-2])
    t, ids = doc.xref_get_key(-1, "ID")
    toks = re.findall(r"<[0-9A-Fa-f\s]*>|\((?:\\.|[^\\)])*\)", ids or "")
    id0 = _pdf_string_bytes(toks[0]) if toks else b""
    return _Crypt(enc, id0, password), ref


# ---- checking signatures -------------------------------------------------------------------------------------

def _trust_store():
    certs = []
    try:
        with open(TRUST_BUNDLE, "rb") as f:
            pem = f.read()
        for m in re.finditer(rb"-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----", pem, re.S):
            try:
                certs.append(x509.load_pem_x509_certificate(m.group(0)))
            except ValueError:
                pass
    except OSError:
        pass
    return certs


def _verify_raw(pubkey, sig, data, hash_name, sig_alg):
    h = {"sha1": hashes.SHA1(), "sha256": hashes.SHA256(), "sha384": hashes.SHA384(),
         "sha512": hashes.SHA512()}.get(hash_name, hashes.SHA256())
    if isinstance(pubkey, rsa.RSAPublicKey):
        if "pss" in sig_alg:
            pubkey.verify(sig, data, padding.PSS(mgf=padding.MGF1(h), salt_length=padding.PSS.AUTO), h)
        else:
            pubkey.verify(sig, data, padding.PKCS1v15(), h)
    elif isinstance(pubkey, ec.EllipticCurvePublicKey):
        pubkey.verify(sig, data, ec.ECDSA(h))
    else:
        raise InvalidSignature()


def check_signature(data, byte_range, contents_hex=None):
    """one signature: -> dict(status, signer, time, covers, detail)
    status: valid (and trusted), unknown (valid, the signer's identity not confirmed),
    invalid (the document changed or the signature does not match)"""
    res = {"status": "invalid", "signer": "", "time": "", "covers": "0", "detail": ""}
    try:
        a, b, c, d = byte_range
        if a != 0 or b < 0 or c < b or d < 0 or c + d > len(data):
            res["detail"] = "the signature's byte range is not right"
            return res
        hexs = data[b:c].strip()
        if not (hexs.startswith(b"<") and hexs.endswith(b">")):
            res["detail"] = "the signature's value is not where its byte range says"
            return res
        raw = bytes.fromhex(hexs[1:-1].decode("ascii").strip())
        ci = cms.ContentInfo.load(raw.rstrip(b"\x00") if raw.endswith(b"\x00\x00") else raw, strict=False)
        sd = ci["content"]
        si = sd["signer_infos"][0]
        hash_name = si["digest_algorithm"]["algorithm"].native
        hfun = {"sha1": hashlib.sha1, "sha256": hashlib.sha256, "sha384": hashlib.sha384,
                "sha512": hashlib.sha512}.get(hash_name)
        if hfun is None:
            res["detail"] = "the signature uses a digest this program does not know (%s)" % hash_name
            return res
        signed = data[a:a + b] + data[c:c + d]
        digest = hfun(signed).digest()
        # the signer's certificate
        sid = si["sid"]
        certs = [cc.chosen for cc in sd["certificates"]] if sd["certificates"] else []
        signer_cert = None
        for ac in certs:
            if sid.name == "issuer_and_serial_number":
                if ac.serial_number == sid.chosen["serial_number"].native and ac.issuer == sid.chosen["issuer"]:
                    signer_cert = ac
            elif ac.key_identifier == sid.chosen.native:
                signer_cert = ac
        if signer_cert is None:
            res["detail"] = "the signer's certificate is not in the signature"
            return res
        cert = x509.load_der_x509_certificate(signer_cert.dump())
        res["signer"] = id_name(cert)
        sattrs = si["signed_attrs"]
        sig_alg = si["signature_algorithm"]["algorithm"].native
        if sattrs:
            md = None
            for at in sattrs:
                if at["type"].native == "message_digest":
                    md = at["values"][0].native
                elif at["type"].native == "signing_time":
                    res["time"] = at["values"][0].native.astimezone().strftime("%Y-%m-%d %H:%M:%S %z")
            if md != digest:
                res["detail"] = "the document has been changed since it was signed"
                return res
            to_verify = b"\x31" + sattrs.dump()[1:]     # signed as a SET OF, carried [0] IMPLICIT
        else:
            to_verify = signed
        try:
            _verify_raw(cert.public_key(), si["signature"].native, to_verify, hash_name, sig_alg)
        except (InvalidSignature, ValueError, TypeError):
            res["detail"] = "the signature does not match the signer's certificate"
            return res
        res["covers"] = "1" if c + d == len(data) else "0"
        # the signer's identity
        trusted, why = _path_trusted(cert, [x509.load_der_x509_certificate(cc.dump()) for cc in certs])
        res["status"] = "valid" if trusted else "unknown"
        res["detail"] = why
        return res
    except Exception as e:  # a damaged signature is reported, never raised
        res["detail"] = "the signature cannot be read (%s)" % " ".join(str(e).split())[:120]
        return res


def _path_trusted(cert, others):
    now = datetime.datetime.now(datetime.timezone.utc)
    try:
        nb, na = cert.not_valid_before_utc, cert.not_valid_after_utc
    except AttributeError:
        nb = cert.not_valid_before.replace(tzinfo=datetime.timezone.utc)
        na = cert.not_valid_after.replace(tzinfo=datetime.timezone.utc)
    if not (nb <= now <= na):
        return False, "the signer's certificate has expired or is not yet valid"
    try:
        from pyhanko_certvalidator import CertificateValidator, ValidationContext
        roots = [ax509.Certificate.load(c.public_bytes(serialization.Encoding.DER)) for c in _trust_store()]
        roots += [ax509.Certificate.load(c.public_bytes(serialization.Encoding.DER)) for c in _user_trusted()]
        ctx = ValidationContext(trust_roots=roots, allow_fetching=False, revocation_mode="soft-fail")
        inter = [ax509.Certificate.load(c.public_bytes(serialization.Encoding.DER)) for c in others]
        v = CertificateValidator(ax509.Certificate.load(cert.public_bytes(serialization.Encoding.DER)),
                                 intermediate_certs=inter, validation_context=ctx)
        v.validate_usage(set())
        return True, "the signer's certificate is trusted"
    except ImportError:
        pass
    except Exception:
        if cert.issuer == cert.subject:
            return False, "the signer's identity is unknown: the digital ID is self-signed and not in trusted certificates"
        return False, "the signer's identity is unknown: the certificate does not lead to a trusted authority"
    # without pyhanko-certvalidator: a direct issuer among the trusted roots
    fp = {c.fingerprint(hashes.SHA256()) for c in _trust_store() + _user_trusted()}
    if cert.fingerprint(hashes.SHA256()) in fp:
        return True, "the signer's certificate is trusted"
    for root in _trust_store():
        if root.subject == cert.issuer:
            try:
                cert.verify_directly_issued_by(root)
                return True, "the signer's certificate is trusted"
            except Exception:
                pass
    if cert.issuer == cert.subject:
        return False, "the signer's identity is unknown: the digital ID is self-signed and not in trusted certificates"
    return False, "the signer's identity is unknown: the certificate does not lead to a trusted authority"


def _user_trusted():
    """certificates the person chose to trust (~/.config/sg-pdf/trusted/*.pem|.cer|.crt)"""
    d = os.path.join(os.path.expanduser("~"), ".config", "sg-pdf", "trusted")
    out = []
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return out
    for n in names:
        try:
            with open(os.path.join(d, n), "rb") as f:
                raw = f.read()
            out.append(x509.load_pem_x509_certificate(raw) if b"BEGIN" in raw else x509.load_der_x509_certificate(raw))
        except (OSError, ValueError):
            pass
    return out


def trust_cert_of(data, byte_range, name):
    """add a signature's signer certificate to the person's trusted certificates"""
    a, b, c, d = byte_range
    raw = bytes.fromhex(data[b:c].strip()[1:-1].decode("ascii"))
    sd = cms.ContentInfo.load(raw, strict=False)["content"]
    si = sd["signer_infos"][0]
    sid = si["sid"]
    for cc in sd["certificates"]:
        ac = cc.chosen
        if sid.name == "issuer_and_serial_number" and ac.serial_number == sid.chosen["serial_number"].native:
            d_ = os.path.join(os.path.expanduser("~"), ".config", "sg-pdf", "trusted")
            os.makedirs(d_, exist_ok=True)
            fn = os.path.join(d_, re.sub(r"[^\w.-]", "_", name or "signer")[:60] + "-%x.cer" % ac.serial_number)
            with open(fn, "wb") as f:
                f.write(ac.dump())
            return fn
    raise SignError("the signer's certificate is not in the signature")
