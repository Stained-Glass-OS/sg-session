#!/usr/bin/python3
# Gate for two of SG PDF's engine features (bin/sg-pdf + pdf/), through the
# real protocol (`sg-pdf --serve`), every result read back from outside the
# engine (a fresh MuPDF open, poppler's pdftoppm, pdfsig and pdftotext, qpdf):
#
#   ink    a pen's stroke with its pressure (Comment > Draw with a pen):
#          saved as a standard Ink annotation (InkList; /BS /W the mean
#          width) whose appearance is thin where the pen pressed lightly and
#          thick where it pressed hard -- MuPDF and poppler both draw it so;
#          moving it and changing its colour keep the widths; a stroke
#          without pressure (the mouse) stays one width
#   crypt  certificate-signing a document with a password: AES-256 (R6),
#          AES-128 (R4) and RC4-128 (R3), opened with the user's password
#          and with the owner's: the signed file still needs the password,
#          appends to the file byte for byte, pdfsig says the signature is
#          valid, qpdf checks it with the password, the update's text
#          (the reason, the field's name) is encrypted in the file and reads
#          right once decrypted; a changed document (unsaved edit) is signed
#          encrypted too; a pending security change is refused
#
# Mutants: test/pdf-inkcrypt-mutants.sh. Skips (77) without python3-pymupdf,
# python3-asn1crypto, qpdf, pdfsig, pdftotext, pdftoppm.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PDF = os.environ.get("SG_PDF_HELPER") or os.path.join(HERE, "..", "bin", "sg-pdf")
FAILS = 0

try:
    import importlib
    import pymupdf as fitz
    importlib.import_module("asn1crypto")
except ImportError as e:
    print("SKIP: %s" % e)
    sys.exit(77)
for tool in ("qpdf", "pdfsig", "pdftotext", "pdftoppm"):
    if not shutil.which(tool):
        print("SKIP: %s missing" % tool)
        sys.exit(77)


def check(cond, what):
    global FAILS
    print(("PASS " if cond else "FAIL ") + what)
    if not cond:
        FAILS += 1
    return cond


class Client:
    def __init__(self):
        self.p = subprocess.Popen([PDF, "--serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)

    def ask(self, *fields):
        self.p.stdin.write(("\t".join(str(f) for f in fields) + "\n").encode("utf-8"))
        self.p.stdin.flush()
        head = self.p.stdout.readline().decode("utf-8").rstrip("\n")
        m = re.search(r"(?:^| )bytes=(\d+)", head)
        data = self.p.stdout.read(int(m.group(1))) if m else b""
        return head, data

    def ok(self, what, *fields):
        head, data = self.ask(*fields)
        check(head.startswith("OK"), "%s (%s)" % (what, head[:140]))
        return head, data

    def close(self):
        try:
            self.ask("quit")
        except (BrokenPipeError, ValueError):
            pass
        self.p.wait(10)


def field(head, key):
    m = re.search(r"(?:^| )%s=(\S+)" % key, head)
    return m.group(1) if m else None


T = tempfile.mkdtemp(prefix="sg-pdf-inkcrypt.", dir="/var/tmp")
c = Client()
try:
    # ======================================================================== ink
    blank = os.path.join(T, "blank.pdf")
    d = fitz.open()
    d.new_page(width=612, height=792)
    d.save(blank)
    c.ok("open a blank page", "open", blank)
    # left to right along y=400, pressure rising from 0.05 to 1.0
    pts = " ".join("%d 400" % x for x in range(100, 501, 20))
    pr = " ".join("%.3f" % (0.05 + 0.95 * i / 20) for i in range(21))
    head, _ = c.ok("a pen stroke with its pressure", "annot", "0", "ink", "ink=" + pts, "pressure=" + pr,
                   "color=1f4fd0", "width=4")
    # and a mouse stroke (no pressure) below it
    c.ok("a mouse stroke", "annot", "0", "ink", "ink=" + " ".join("%d 600" % x for x in range(100, 501, 20)),
         "color=1f4fd0", "width=4")
    ink = os.path.join(T, "ink.pdf")
    c.ok("save", "save", ink)
    e = fitz.open(ink)
    pg = e[0]
    annots = []
    a = pg.first_annot
    while a:
        annots.append(a)
        a = a.next
    check(len(annots) == 2 and all(x.type[0] == fitz.PDF_ANNOT_INK for x in annots), "two Ink annotations")
    pen = min(annots, key=lambda x: x.rect.y0)
    t, inklist = e.xref_get_key(pen.xref, "InkList")
    check(t == "array" and inklist.count(" ") > 30, "the pen's stroke is an InkList other readers draw")
    bw = (pen.border or {}).get("width") or 0
    check(3.0 < bw < 5.0, "its /BS /W is the mean width (%.2f)" % bw)

    def rows_at(pix, x_pt, y0_pt, y1_pt, scale):
        """the stroke's thickness in pixels at x (blue-ish pixels in a column)"""
        X = int(x_pt * scale)
        n = 0
        for y in range(int(y0_pt * scale), int(y1_pt * scale)):
            r, g, b = pix.pixel(X, y)[:3]
            if b > 120 and r < 120:
                n += 1
        return n
    pix = pg.get_pixmap(dpi=144)
    thin, thick = rows_at(pix, 110, 380, 420, 2), rows_at(pix, 490, 380, 420, 2)
    check(thin >= 1 and thick >= 3 * thin, "MuPDF draws it thin where the pen pressed lightly, thick where hard "
          "(%d px, %d px)" % (thin, thick))
    m1, m2 = rows_at(pix, 110, 580, 620, 2), rows_at(pix, 490, 580, 620, 2)
    check(m1 > 0 and abs(m1 - m2) <= 1, "the mouse's stroke is one width (%d px, %d px)" % (m1, m2))
    subprocess.run(["pdftoppm", "-r", "144", "-png", "-singlefile", ink, os.path.join(T, "pop")], check=True)
    pp = fitz.Pixmap(os.path.join(T, "pop.png"))
    pthin, pthick = rows_at(pp, 110, 380, 420, 2), rows_at(pp, 490, 380, 420, 2)
    check(pthin >= 1 and pthick >= 3 * pthin, "poppler draws the same variation (%d px, %d px)" % (pthin, pthick))

    c.ok("open it in the engine again", "open", ink)
    c.ok("move the pen's stroke down 50 points", "moveannot", "0", str(pen.xref), "%.2f %.2f %.2f %.2f" % (
        pen.rect.x0, pen.rect.y0 + 50, pen.rect.x1, pen.rect.y1 + 50))
    moved = os.path.join(T, "moved.pdf")
    c.ok("save", "save", moved)
    e2 = fitz.open(moved)
    p2 = e2[0]
    pix = p2.get_pixmap(dpi=144)
    thin, thick = rows_at(pix, 110, 430, 470, 2), rows_at(pix, 490, 430, 470, 2)
    check(thin >= 1 and thick >= 3 * thin, "moved, it keeps its widths (%d px, %d px)" % (thin, thick))
    a = p2.first_annot
    pen2 = min([a, a.next], key=lambda x: x.rect.y0)
    c.ok("open it again", "open", moved)
    c.ok("change its colour", "setannot", "0", str(pen2.xref), "color=d01f1f")
    rec = os.path.join(T, "recolored.pdf")
    c.ok("save", "save", rec)
    p3 = fitz.open(rec)[0]
    pix = p3.get_pixmap(dpi=144)

    def red_rows(x_pt):
        X = int(x_pt * 2)
        return sum(1 for y in range(860, 940) if pix.pixel(X, y)[0] > 150 and pix.pixel(X, y)[2] < 120)
    check(red_rows(110) >= 1 and red_rows(490) >= 3 * red_rows(110),
          "recoloured, it keeps its widths (%d px, %d px)" % (red_rows(110), red_rows(490)))

    # ======================================================================== crypt
    pfx = os.path.join(T, "jane.pfx")
    c.ok("make a digital ID", "makeid", pfx, "s3cret", "name=Jane Q Signer")
    src = fitz.open()
    sp = src.new_page(width=612, height=792)
    sp.insert_text((72, 100), "A confidential contract", fontsize=16)
    methods = (("AES-256", fitz.PDF_ENCRYPT_AES_256), ("AES-128", fitz.PDF_ENCRYPT_AES_128),
               ("RC4-128", fitz.PDF_ENCRYPT_RC4_128))
    for name, method in methods:
        enc = os.path.join(T, "enc-%s.pdf" % name)
        src.save(enc, encryption=method, user_pw="userpw", owner_pw="ownerpw",
                 permissions=fitz.PDF_PERM_PRINT | fitz.PDF_PERM_FORM | fitz.PDF_PERM_ANNOTATE)
        with open(enc, "rb") as fh:
            before = fh.read()
        for who, pw in (("user", "userpw"), ("owner", "ownerpw")):
            what = "%s, the %s's password" % (name, who)
            head, _ = c.ok("open %s" % what, "open", enc, pw)
            check(field(head, "encrypted") == "1", "%s: the engine knows it is encrypted" % what)
            out = os.path.join(T, "signed-%s-%s.pdf" % (name, who))
            head, _ = c.ask("certsign", out, pfx, "s3cret", "page=0", "rect=300 600 560 680",
                            "reason=Agreed in full", "name=Contract signature")
            if not check(head.startswith("OK"), "%s: signed (%s)" % (what, head[:120])):
                continue
            with open(out, "rb") as fh:
                after = fh.read()
            check(after.startswith(before), "%s: the signature is appended; the file before stays byte for byte" % what)
            fd = fitz.open(out)
            check(fd.needs_pass, "%s: the signed file still needs a password" % what)
            check(fd.authenticate("userpw") > 0, "%s: the user's password opens it" % what)
            names = [w.field_name for w in fd[0].widgets()]
            check("Contract signature" in names, "%s: the new field's name reads right decrypted (%s)" % (what, names))
            check(b"Agreed in full" not in after and b"Contract signature" not in after,
                  "%s: the update's text is encrypted in the file" % what)
            r = subprocess.run(["pdfsig", "-upw", "userpw", out], capture_output=True, text=True)
            check("Signature is Valid" in r.stdout and "Total document signed" in r.stdout,
                  "%s: pdfsig: valid, covering the whole file" % what)
            check("Signature Field Name: Contract signature" in r.stdout,
                  "%s: pdfsig reads the field's name (decrypted)" % what)
            r = subprocess.run(["qpdf", "--password=userpw", "--qdf", "--object-streams=disable", "--decrypt", out,
                                os.path.join(T, "plain.pdf")], capture_output=True, text=True)
            with open(os.path.join(T, "plain.pdf"), "rb") as fh:
                plain = fh.read()
            check(b"/Reason (Agreed in full)" in plain or b"/Reason(Agreed in full)" in plain,
                  "%s: qpdf decrypts the signature's reason" % what)
            r = subprocess.run(["qpdf", "--password=userpw", "--check", out], capture_output=True, text=True)
            check(r.returncode in (0, 3) and "No syntax or stream encoding errors" in r.stdout,
                  "%s: qpdf --check with the password (%s)" % (what, " ".join((r.stdout + r.stderr).split())[-90:]))
            r = subprocess.run(["pdftotext", "-upw", "userpw", out, "-"], capture_output=True, text=True)
            check("Digitally signed by Jane Q Signer" in r.stdout, "%s: the appearance (a stream) decrypts" % what)
            head, data = c.ok("%s: check the signatures" % what, "signatures")
            st = [ln.split("\t") for ln in data.decode().splitlines()]
            check(any(s[2] == "Contract signature" and s[3] in ("valid", "unknown") and s[4] == "1" for s in st),
                  "%s: our check: valid, the whole file (%s)" % (what, [(s[2], s[3], s[4]) for s in st]))
    # an unsaved change, then signing: the document as it is now, still encrypted
    enc = os.path.join(T, "enc-AES-256.pdf")
    c.ok("open the AES-256 document again", "open", enc, "userpw")
    c.ok("an unsaved comment", "annot", "0", "note", "point=72 200", "text=see clause 4")
    out = os.path.join(T, "signed-dirty.pdf")
    head, _ = c.ok("sign with the change unsaved", "certsign", out, pfx, "s3cret", "page=0", "rect=300 600 560 680")
    fd = fitz.open(out)
    check(fd.needs_pass and fd.authenticate("userpw") > 0, "the changed document is signed still encrypted")
    r = subprocess.run(["pdfsig", "-upw", "userpw", out], capture_output=True, text=True)
    check("Signature is Valid" in r.stdout, "pdfsig: valid")
    # a pending security change: refused (sign what is saved)
    c.ok("open the AES-128 document", "open", os.path.join(T, "enc-AES-128.pdf"), "ownerpw")
    c.ok("ask to remove its security on save", "protect", "mode=none")
    head, _ = c.ask("certsign", os.path.join(T, "pending.pdf"), pfx, "s3cret", "page=0", "rect=300 600 560 680")
    check(head.startswith("ERR") and "save" in head, "signing with a security change pending asks to save first (%s)"
          % head[:100])
finally:
    c.close()
    shutil.rmtree(T, ignore_errors=True)

print("pdf-inkcrypt-test: %s (%d failed)" % ("PASS" if FAILS == 0 else "FAIL", FAILS))
sys.exit(1 if FAILS else 0)
