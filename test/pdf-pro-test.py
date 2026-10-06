#!/usr/bin/python3
# Gate for SG PDF's professional tools in its engine (bin/sg-pdf + pdf/,
# MuPDF), through the real protocol (`sg-pdf --serve`), every result checked
# from outside the engine -- poppler's pdftotext and pdfsig, qpdf, and a
# fresh MuPDF open of the saved file:
#
#   Prepare Form  a flat form's blanks found (underscores, rules, boxes,
#                 table cells, check boxes; named after their labels; a date
#                 field and a signature field by their labels) and made into
#                 fields; fields of every kind added, renamed, moved,
#                 deleted; radio buttons of one name are one group
#   Fill          a number field refuses letters, a date field takes "oct 6
#                 2026" and keeps 10/06/2026; a total (Qty * Price + ...) and
#                 a SUM recompute after each change; the shown values are
#                 formatted ($1,234.50) while the stored value is the number;
#                 the formats and calculations are the standard JavaScript
#                 other readers run (AFNumber_Format, AFSimple_Calculate,
#                 /CO); reset; check marks anywhere
#   Sign          a self-signed digital ID made; signing an empty signature
#                 field and then a new one: pdfsig (poppler) says both are
#                 valid and the second covers the whole file; our check says
#                 valid-but-unknown (self-signed); a byte changed after
#                 signing makes both checks fail; a wrong password refused
#   Create        a blank document; one from a picture, a text file and a
#                 PDF; office documents when a converter is installed
#   Recognize     a scanned page gets a text layer pdftotext reads
#   Pages         header and footer, page numbers, Bates numbers, watermark
#                 (pdftotext reads them on every page, turned pages too);
#                 replace pages; optimize shrinks a big picture
#   Comments      a stamp, replies and a review status (IRT, /State)
#   Other         attachments added, saved out byte for byte, deleted;
#                 links; bookmarks written
#
# Skips (77) without python3-pymupdf, python3-asn1crypto, qpdf, pdftotext,
# pdfsig. OCR checks skip without ocrmypdf and the English language.
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
    importlib.import_module("asn1crypto")     # the signer needs it
except ImportError as e:
    print("SKIP: %s" % e)
    sys.exit(77)
for tool in ("qpdf", "pdftotext", "pdfsig"):
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
        env = dict(os.environ)
        self.p = subprocess.Popen([PDF, "--serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)

    def ask(self, *fields):
        self.p.stdin.write(("\t".join(str(f) for f in fields) + "\n").encode("utf-8"))
        self.p.stdin.flush()
        head = self.p.stdout.readline().decode("utf-8").rstrip("\n")
        m = re.search(r"(?:^| )bytes=(\d+)", head)
        data = self.p.stdout.read(int(m.group(1))) if m else b""
        return head, data

    def ok(self, what, *fields):
        head, data = self.ask(*fields)
        check(head.startswith("OK"), "%s (%s)" % (what, head[:160]))
        return head, data

    def fields(self):
        _, d = self.ask("fields")
        out = {}
        for ln in d.decode("utf-8").splitlines():
            f = ln.split("\t")
            out.setdefault(f[5], []).append(f)
        return out

    def xref(self, name, i=0):
        f = self.fields().get(name)
        return f[i][1] if f and len(f) > i else "0"

    def close(self):
        try:
            self.ask("quit")
        except (BrokenPipeError, ValueError):
            pass
        self.p.wait(10)


def field(head, key):
    m = re.search(r"(?:^| )%s=(\S+)" % key, head)
    return m.group(1) if m else None


def pdftotext(path, layout=False):
    return subprocess.run(["pdftotext"] + (["-layout"] if layout else []) + [path, "-"],
                          capture_output=True, text=True).stdout


def qpdf_ok(path):
    r = subprocess.run(["qpdf", "--check", path], capture_output=True, text=True)
    return r.returncode in (0, 3) and "No syntax or stream encoding errors" in r.stdout


def widgets(path):
    d = fitz.open(path)
    out = {}
    for p in d:
        for w in p.widgets():
            out.setdefault(w.field_name, []).append(w)
    return d, out


T = tempfile.mkdtemp(prefix="sg-pdf-pro-", dir="/var/tmp")
c = Client()

# ============================================================================ Prepare Form
flat = os.path.join(T, "flat.pdf")
doc = fitz.open()
p = doc.new_page(width=612, height=792)
p.insert_text((72, 72), "Membership Application", fontsize=18, fontname="hebo")
p.insert_text((72, 110), "Full name: ______________________________", fontsize=11)
p.insert_text((72, 140), "Date of birth:", fontsize=11)
p.draw_line((160, 142), (320, 142), width=0.7)
p.insert_text((72, 170), "Email:", fontsize=11)
p.draw_line((120, 172), (400, 172), width=0.7)
p.draw_rect(fitz.Rect(72, 190, 82, 200), width=0.8)
p.insert_text((88, 199), "Student", fontsize=10)
p.draw_rect(fitz.Rect(172, 190, 182, 200), width=0.8)
p.insert_text((188, 199), "Senior", fontsize=10)
p.insert_text((72, 240), "Item", fontsize=10)
p.insert_text((272, 240), "Qty", fontsize=10)
p.insert_text((372, 240), "Price", fontsize=10)
for row in range(2):
    y = 246 + row * 22
    for x0, x1 in ((72, 270), (270, 370), (370, 470)):
        p.draw_rect(fitz.Rect(x0, y, x1, y + 22), width=0.6)
p.insert_text((72, 330), "Signature:", fontsize=11)
p.draw_line((130, 332), (330, 332), width=0.7)
p.insert_text((72, 380), "This line is not a blank and has no field.", fontsize=11)
doc.save(flat)

c.ok("open the flat form", "open", flat)
head, data = c.ok("find the blanks the page suggests", "formdetect")
found = [ln.split("\t") for ln in data.decode().splitlines()]
names = {f[3]: f[1] for f in found}
check(len(found) == 12, "12 blanks found (%d: %s)" % (len(found), ", ".join("%s:%s" % (f[1], f[3]) for f in found)))
check(names.get("Full name") == "text", "the underscores after 'Full name:' are a text field")
check(names.get("Date of birth") == "date", "the rule after 'Date of birth:' is a date field")
check(names.get("Email") == "text", "the rule after 'Email:' is a text field")
check(names.get("Student") == "checkbox" and names.get("Senior") == "checkbox", "the small squares are check boxes, named by their labels")
check(names.get("Qty") == "number" and names.get("Price") == "number", "the table's Qty and Price cells are number fields")
check(names.get("Signature") == "signature", "the rule after 'Signature:' is a signature field")
check(not any(f[3].startswith("This line") for f in found), "a plain line of text is not taken for a blank")
r = [float(x) for x in [f for f in found if f[3] == "Full name"][0][2].split()]
check(r[0] > 120 and r[2] > 300 and 95 < r[3] < 116, "the name field lies over the underscores (%s)" % r)
head, _ = c.ok("make them fields", "formdetect", "", "add=1")
check(field(head, "form") == "1", "the document is a form now")
fl = c.fields()
check(len(fl) == 12 and "Item_2" in fl and "Price_2" in fl, "12 fields, the second row numbered (%s)" % ", ".join(sorted(fl)))

# fields of every kind by hand
head, _ = c.ok("add a total: Qty * Price + Qty_2 * Price_2, currency", "addfield", "0", "number", "380 400 470 420",
               "name=Total", "calc=expr:Qty * Price + Qty_2 * Price_2", "format=number:2:$", "readonly=1",
               "tooltip=The order's total")
head, _ = c.ok("add a sum of the prices", "addfield", "0", "number", "380 430 470 450", "name=Sum", "calc=sum:Price,Price_2")
c.ok("add radio button Basic", "addfield", "0", "radio", "72 460 84 472", "name=Plan", "export=Basic")
c.ok("add radio button Pro (same group)", "addfield", "0", "radio", "172 460 184 472", "name=Plan", "export=Pro")
c.ok("add a drop-down", "addfield", "0", "combo", "300 460 400 478", "name=Colour", "options=Red\\nGreen\\nBlue")
c.ok("add a list box", "addfield", "0", "list", "300 490 400 540", "name=Fruit", "options=Apple\\nPear")
c.ok("add a multi-line text field", "addfield", "0", "text", "72 560 300 620", "name=Comments", "multiline=1", "required=1")
c.ok("add a date field (yyyy-mm-dd)", "addfield", "0", "date", "320 560 450 580", "name=Start", "format=date:yyyy-mm-dd")
c.ok("add a check box", "addfield", "0", "checkbox", "72 640 84 652", "name=Agree")
head, _ = c.ask("addfield", "0", "text", "72 660 200 680", "name=Comments")
check(head.startswith("ERR"), "a second field of the same name is refused (%s)" % head[:80])
head, _ = c.ask("addfield", "0", "text", "72 660 74 662", "name=Tiny")
check(head.startswith("ERR"), "a field too small to use is refused")
c.ok("add a field to rename, move and delete", "addfield", "0", "text", "72 700 200 720", "name=Scratch")
c.ok("rename it", "setfieldprops", "0", c.xref("Scratch"), "name=Scratch2", "tooltip=renamed")
check("Scratch2" in c.fields() and "Scratch" not in c.fields(), "renamed")
c.ok("move it", "movefield", "0", c.xref("Scratch2"), "300 700 450 722")
f = c.fields()["Scratch2"][0]
check(f[3].startswith("300.00 700.00"), "moved (%s)" % f[3])
head, data = c.ok("read its properties", "fieldprops", "0", c.xref("Scratch2"))
props = dict(ln.split("=", 1) for ln in data.decode().splitlines())
check(props.get("tooltip") == "renamed" and props.get("kind") == "text", "properties read back (%s)" % props)
c.ok("delete it", "delfield", "0", c.xref("Scratch2"))
check("Scratch2" not in c.fields(), "deleted")
c.ok("give Price a currency format", "setfieldprops", "0", c.xref("Price"), "format=number:2:$")

# ============================================================================ Fill
c.ok("Qty = 3", "setfield", "0", c.xref("Qty"), "3")
c.ok("Price = $1,234.5", "setfield", "0", c.xref("Price"), "$1,234.5")
c.ok("Qty_2 = 2", "setfield", "0", c.xref("Qty_2"), "2")
c.ok("Price_2 = 10", "setfield", "0", c.xref("Price_2"), "10")
head, _ = c.ask("setfield", "0", c.xref("Qty"), "abc")
check(head.startswith("ERR invalid"), "letters in a number field are refused (%s)" % head[:90])
c.ok("a date typed as words", "setfield", "0", c.xref("Date of birth"), "oct 6 2026")
head, _ = c.ask("setfield", "0", c.xref("Date of birth"), "not a date")
check(head.startswith("ERR invalid"), "a date field refuses what is not a date")
c.ok("a date in the other pattern", "setfield", "0", c.xref("Start"), "10/06/2026")
c.ok("choose Pro", "setfield", "0", c.xref("Plan", 1), "1")
c.ok("choose Green", "setfield", "0", c.xref("Colour"), "Green")
c.ok("tick Agree", "setfield", "0", c.xref("Agree"), "1")
c.ok("type comments", "setfield", "0", c.xref("Comments"), "line one\\nline two")
fl = c.fields()
check(fl["Total"][0][6] == "3723.5", "the total is computed: 3*1234.5 + 2*10 = 3723.5 (%s)" % fl["Total"][0][6])
check(fl["Sum"][0][6] == "1244.5", "the sum is computed: 1244.5 (%s)" % fl["Sum"][0][6])
check(fl["Price"][0][6] == "1234.5", "the stored value is the number typed (%s)" % fl["Price"][0][6])
check(fl["Date of birth"][0][6] == "10/06/2026", "the date is kept in the field's pattern (%s)" % fl["Date of birth"][0][6])
check(fl["Start"][0][6] == "2026-10-06", "the yyyy-mm-dd field keeps 2026-10-06 (%s)" % fl["Start"][0][6])
check(fl["Total"][0][9] == "number:2:$:0" and fl["Total"][0][10].startswith("expr:Qty * Price"),
      "the fields list reports the format and the calculation")
c.ok("put a check mark where there is no field", "fillmark", "0", "check", "300 190 312 202")
c.ok("and a cross", "fillmark", "0", "cross", "330 190 342 202")
filled = os.path.join(T, "filled.pdf")
c.ok("save the filled form", "save", filled)
check(qpdf_ok(filled), "qpdf --check: the form is valid")
lay = pdftotext(filled, layout=True)
check("$1,234.50" in lay and "$3,723.50" in lay, "other readers see the values formatted ($1,234.50, $3,723.50)")
check("1,244.50" in lay and "10/06/2026" in lay and "2026-10-06" in lay, "and the sum and the dates")
d2, w2 = widgets(filled)
tot = w2["Total"][0]
check("AFSimple_Calculate" in (w2["Sum"][0].script_calc or "") and "BVCALC" in (tot.script_calc or ""),
      "the calculations are the standard scripts other readers run")
check("AFNumber_Format(2" in (tot.script_format or "") and "AFDate_FormatEx" in (w2["Date of birth"][0].script_format or ""),
      "the formats are AFNumber_Format and AFDate_FormatEx")
co = d2.xref_get_key(d2.pdf_catalog(), "AcroForm/CO")
check(co[0] == "array" and len(re.findall(r"\d+ 0 R", co[1])) == 2, "the calculation order (/CO) names both (%s)" % (co,))
plan = w2["Plan"]
check(len(plan) == 2 and plan[1].field_value == "Pro" and plan[0].field_value in ("Off", False),
      "the radio buttons are one group, Pro chosen (%s)" % [x.field_value for x in plan])
par = [d2.xref_get_key(x.xref, "Parent")[0] for x in plan]
check(par == ["xref", "xref"], "both radio buttons are kids of one field")
check(tot.field_flags & 1, "the total is read-only")
check(w2["Comments"][0].field_flags & (1 << 12) and w2["Comments"][0].field_flags & 2, "Comments is multi-line and required")
check(d2.xref_get_key(tot.xref, "TU")[1] == "The order's total", "the tooltip is saved (/TU)")
drawn = [dd for dd in d2[0].get_drawings() if 290 < dd["rect"].x0 < 345 and 185 < dd["rect"].y0 < 205]
check(len(drawn) >= 2, "the check mark and the cross are drawn on the page")
c.ok("reset the form", "resetform")
check(c.fields()["Qty"][0][6] == "" and c.fields()["Total"][0][6] == "0", "reset: values cleared, total recomputed to 0")
c.ok("undo the reset", "undo")
check(c.fields()["Qty"][0][6] == "3", "undo brings the values back")

# ============================================================================ Sign
pfx = os.path.join(T, "jane.pfx")
head, _ = c.ok("make a self-signed digital ID", "makeid", pfx, "s3cret", "name=Jane Q Signer", "email=jane@example.org")
check(os.path.isfile(pfx) and (os.stat(pfx).st_mode & 0o077) == 0, "the digital ID is saved, readable only by its owner")
head, data = c.ok("read the ID with its password", "idinfo", pfx, "s3cret")
check(b"name Jane Q Signer" in data and b"selfsigned 1" in data, "its owner and kind")
head, _ = c.ask("idinfo", pfx, "wrong")
check(head.startswith("ERR password"), "a wrong password is refused")
c.ok("open the filled form again", "open", filled)
s1 = os.path.join(T, "signed1.pdf")
head, _ = c.ask("certsign", s1, pfx, "wrong", "field=" + c.xref("Signature"), "page=0")
check(head.startswith("ERR") and not os.path.exists(s1), "signing with a wrong password does nothing")
head, _ = c.ok("sign the form's signature field", "certsign", s1, pfx, "s3cret", "field=" + c.xref("Signature"),
               "page=0", "reason=I agree", "location=Portland")
s2 = os.path.join(T, "signed2.pdf")
head, _ = c.ok("a second signature in a new box", "certsign", s2, pfx, "s3cret", "page=0", "rect=320 620 560 680",
               "name=Witness")
out = subprocess.run(["pdfsig", s2], capture_output=True, text=True).stdout
check(out.count("Signature is Valid") == 2, "pdfsig: both signatures are valid (%d)" % out.count("Signature is Valid"))
check("Total document signed" in out and "Signature Field Name: Witness" in out, "pdfsig: the second covers the whole file")
check("Signer Certificate Common Name: Jane Q Signer" in out, "pdfsig: the signer's name")
check(qpdf_ok(s2), "qpdf --check: the signed file is valid")
with open(s1, "rb") as fh:
    b1 = fh.read()
with open(s2, "rb") as fh:
    b2 = fh.read()
check(b2.startswith(b1), "signing appends: the first signed file is the second's beginning, byte for byte")
check(b"/SubFilter/adbe.pkcs7.detached" in b2 and b"/Reason(I agree)" in b2, "the standard signature dictionary")
check("Digitally signed by Jane Q Signer" in pdftotext(s2), "the signature's appearance names the signer")
head, data = c.ok("check the signatures", "signatures")
sig = [ln.split("\t") for ln in data.decode().splitlines()]
st = {s[2]: s for s in sig}
check(st.get("Signature", [""] * 4)[3] == "unknown" and st.get("Witness", [""] * 4)[3] == "unknown",
      "both valid, the signer unknown (self-signed) (%s)" % [(s[2], s[3]) for s in sig])
check(st.get("Witness", [""] * 5)[4] == "1" and st.get("Signature", [""] * 5)[4] == "0",
      "the last covers the whole file, the first a revision")
check("self-signed" in st.get("Witness", [""] * 10)[9], "and says why the signer is unknown")
# tamper: one byte of the signed content
bad = bytearray(b2)
k = 300                       # in the document both signatures cover
bad[k] ^= 1
tam = os.path.join(T, "tampered.pdf")
with open(tam, "wb") as fh:
    fh.write(bad)
out = subprocess.run(["pdfsig", tam], capture_output=True, text=True).stdout
check("Signature is Valid" not in out, "pdfsig: a changed byte invalidates the signatures (positive control)")
c.ok("open the tampered copy", "open", tam)
head, data = c.ok("check it", "signatures")
check(all(ln.split("\t")[3] == "invalid" for ln in data.decode().splitlines()), "our check: invalid, changed since signing")

# ============================================================================ Create, OCR
head, _ = c.ok("a blank document of two pages", "new", "612", "792", "2")
check(field(head, "untitled") == "1" and field(head, "pages") == "2", "untitled, 2 pages")
png = os.path.join(T, "scan.png")
d = fitz.open()
sp = d.new_page()
sp.insert_text((72, 100), "The quick brown fox jumps over the lazy dog", fontsize=16)
sp.insert_text((72, 140), "Invoice number 48213 due October 2026", fontsize=16)
sp.get_pixmap(dpi=200).save(png)
txt = os.path.join(T, "notes.txt")
with open(txt, "w") as fh:
    fh.write("Plain text notes\nsecond line\n" * 3)
head, _ = c.ok("create from a picture, a text file and a PDF", "create", png, txt, flat)
check(field(head, "pages") == "3", "three pages (%s)" % field(head, "pages"))
created = os.path.join(T, "created.pdf")
c.ok("save it", "save", created)
t = pdftotext(created)
check("Plain text notes" in t and "Membership Application" in t, "the text file and the PDF are in it")
check("Invoice" not in t, "positive control: the scanned page has no text yet")
if shutil.which("ocrmypdf") and "eng" in subprocess.run(["tesseract", "--list-langs"], capture_output=True, text=True).stdout:
    c.ok("recognize text", "ocr", "lang=eng")
    ocred = os.path.join(T, "ocr.pdf")
    c.ok("save", "save", ocred)
    t = pdftotext(ocred)
    check("Invoice number 48213" in t and "quick brown fox" in t, "pdftotext reads the scanned page's words now")
    check("Plain text notes" in t, "pages that had text are kept")
    head, data = c.ok("search the recognized text", "find", "48213")
    check(field(head, "n") == "1", "found on the scanned page")
else:
    print("SKIP OCR: ocrmypdf or the English language missing")
head, _ = c.ask("create", os.path.join(T, "nothing.pdf"))
check(head.startswith("ERR"), "a missing file is refused")
conv = shutil.which("soffice") or os.path.isfile("/usr/lib/sg-office/engine/x2t")
if conv:
    odt = os.path.join(T, "letter.html")
    with open(odt, "w") as fh:
        fh.write("<html><body><h1>Office letter</h1><p>Dear reader, this came from an office document.</p></body></html>")
    head, _ = c.ask("create", odt)
    if check(head.startswith("OK"), "an office document converts (%s)" % head[:120]):
        c.ok("save", "save", os.path.join(T, "office.pdf"))
        check("came from an office document" in pdftotext(os.path.join(T, "office.pdf")), "its text is in the PDF")
else:
    print("SKIP office conversion: no converter installed")

# ============================================================================ Pages
d = fitz.open()
for rot in (0, 90):
    pg = d.new_page(width=612, height=792)
    pg.insert_text((72, 100), "Body of page", fontsize=12)
    pg.set_rotation(rot)
big = fitz.Pixmap(fitz.csRGB, fitz.IRect(0, 0, 2400, 2400), False)
big.set_rect(big.irect, (40, 120, 200))
d[0].insert_image(fitz.Rect(72, 200, 272, 400), pixmap=big)
deco = os.path.join(T, "deco.pdf")
d.save(deco)
c.ok("open a two-page document (one turned)", "open", deco)
c.ok("header and footer", "decorate", "header", "left=Confidential report", "right=<<date>>")
c.ok("page numbers", "decorate", "pagenumbers", "format=Page <<page>> of <<pages>>")
c.ok("Bates numbers", "decorate", "bates", "prefix=ACME-", "start=7", "digits=5")
c.ok("a watermark", "decorate", "watermark", "text=SAMPLE", "opacity=0.2")
head, _ = c.ok("optimize", "optimize", "dpi=100")
check(int(field(head, "images") or 0) == 1 and int(field(head, "after")) < int(field(head, "before")),
      "the big picture is scaled down and the file is smaller (%s -> %s)" % (field(head, "before"), field(head, "after")))
dec = os.path.join(T, "decorated.pdf")
c.ok("save", "save", dec)
pages = [fitz.open(dec)[i].get_text() for i in range(2)]
for i, pt in enumerate(pages):
    check("Confidential report" in pt and "Page %d of 2" % (i + 1) in pt and "ACME-%05d" % (7 + i) in pt,
          "page %d has its header, number and Bates number" % (i + 1))
    check("SAMPLE" in pt.replace("\n", ""), "page %d has the watermark" % (i + 1))
dd = fitz.open(dec)
info = dd[0].get_image_info()
check(info and info[0]["width"] <= 400, "the picture is at 100 dpi now (%s px)" % (info[0]["width"] if info else None))
words = dd[1].get_text("words")
hdr = [w for w in words if w[4] == "Confidential"]
shown = (fitz.Rect(hdr[0][:4]) * dd[1].rotation_matrix).normalize() if hdr else None
check(hdr and dd[1].rotation == 90 and shown.width > shown.height and shown.y0 < 60,
      "on the turned page the header reads upright as shown")
c.ok("replace page 2 with page 1 of the flat form", "replacepages", "1", flat, "1")
rep = os.path.join(T, "replaced.pdf")
c.ok("save", "save", rep)
check("Membership Application" in fitz.open(rep)[1].get_text() and fitz.open(rep).page_count == 2, "page 2 replaced")

# ============================================================================ Comments, attachments, links, bookmarks
c.ok("a blank document", "new")
c.ok("an Approved stamp", "annot", "0", "stamp", "rect=100 100 300 160", "stamp=Approved")
head, _ = c.ok("a sticky note", "annot", "0", "note", "point=50 50", "text=Please check")
nx = field(head, "xref")
c.ok("a reply", "reply", "0", nx, "Checked it")
c.ok("status Accepted", "setstatus", "0", nx, "Accepted")
head, data = c.ok("the comments list", "annots")
rows = [ln.split("\t") for ln in data.decode().splitlines()]
note = [r for r in rows if r[2] == "Text"]
check(len(rows) == 2 and note and note[0][8] == "1" and note[0][9] == "Accepted",
      "two comments; the note has 1 reply and the status Accepted (%s)" % rows)
head, data = c.ok("the thread", "thread", "0", nx)
check(b"Checked it" in data and b"Accepted" in data, "the thread holds the reply and the status")
att = os.path.join(T, "data.bin")
with open(att, "wb") as fh:
    fh.write(os.urandom(5000))
c.ok("attach a file", "addattachment", att, "description=raw data")
head, data = c.ok("list attachments", "attachments")
check(data.startswith(b"data.bin\tdata.bin\t5000"), "the attachment is listed (%s)" % data[:60])
c.ok("a web link", "addlink", "0", "72 700 200 720", "uri=https://example.org/")
c.ok("bookmarks", "setoutline", "toc=0\\tIntroduction\\t0\\n1\\tDetails\\t0\\t300")
misc = os.path.join(T, "misc.pdf")
c.ok("save", "save", misc)
md = fitz.open(misc)
check(md.embfile_names() == ["data.bin"], "the saved file carries the attachment")
c.ok("open it", "open", misc)
out_att = os.path.join(T, "data.out")
c.ok("save the attachment out", "getattachment", "data.bin", out_att)
with open(att, "rb") as a1, open(out_att, "rb") as a2:
    check(a1.read() == a2.read(), "the attachment comes back byte for byte")
check(any(ln.get("uri") == "https://example.org/" for ln in md[0].get_links()), "the link is saved")
check([t[1] for t in md.get_toc()] == ["Introduction", "Details"] and md.get_toc()[1][0] == 2, "the bookmarks are saved")
mp = md[0]
ann = [a for a in mp.annots()]
irt = [a for a in ann if a.irt_xref]
check(len(irt) == 2 and any(md.xref_get_key(a.xref, "StateModel")[1] == "Review" for a in irt),
      "the reply and the status are standard replies (/IRT, /State, /StateModel)")
check(any(a.type[1] == "Stamp" for a in ann), "the stamp is a Stamp annotation")
c.ok("delete the attachment", "delattachment", "data.bin")
head, data = c.ok("list", "attachments")
check(field(head, "n") == "0", "no attachments left")

# ============================================================================ one engine a document
head, _ = c.ok("document 1 in its own engine", "@1\topen", flat)
check(field(head, "pages") == "1", "engine 1 has the form (1 page)")
head, _ = c.ok("document 2 in another", "@2\topen", deco)
check(field(head, "pages") == "2", "engine 2 has the two-page document")
c.ok("change document 1 only", "@1\tinsertblank", "1")
head, _ = c.ok("document 1's state", "@1\tstate")
check(field(head, "pages") == "2" and field(head, "dirty") == "1", "document 1 has the new page, unsaved (%s)" % head[:60])
head, _ = c.ok("document 2's state", "@2\tstate")
check(field(head, "pages") == "2" and field(head, "dirty") == "0", "document 2 is untouched (%s)" % head[:60])
procs = subprocess.run(["pgrep", "-f", "-c", "sg-pdf --serve"], capture_output=True, text=True).stdout.strip()
check(int(procs or 0) >= 3, "each document has an engine process of its own (%s sg-pdf processes)" % procs)
c.ok("close document 1's engine", "@1\tquit")
head, _ = c.ask("@1\tstate")
check(head.startswith("ERR notopen"), "document 1's engine is gone (a fresh one has nothing open)")
head, _ = c.ok("document 2 is still open", "@2\tstate")
check(field(head, "pages") == "2", "closing one document leaves the other")
c.ask("@1\tquit")
c.ask("@2\tquit")

c.close()
shutil.rmtree(T, ignore_errors=True)
print("pdf-pro-test: all passed" if not FAILS else "pdf-pro-test: %d failure(s)" % FAILS)
sys.exit(1 if FAILS else 0)
