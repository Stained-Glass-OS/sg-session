#!/usr/bin/python3
# Gate for SG PDF's editor engine (bin/sg-pdf + pdf/sgpdf.py, MuPDF): every
# editing request the Windows program sends, through the real protocol
# (`sg-pdf --serve`), and every result checked from outside -- poppler's
# pdftotext, qpdf --check (every saved file), qpdf's uncompressed dump for a
# raw search of the file, and a fresh MuPDF open:
#
#   Redact   search, pattern and area marks; Apply; the secrets are gone from
#            pdftotext, from MuPDF's text and from every raw stream (literal,
#            hex and UTF-16 forms), the picture's pixels under the mark are
#            changed while the rest stays, the table's background and rules
#            are cut around the marks, a curve under a mark is removed, the
#            comment and link over the secret are gone, the other words stay;
#            "remove hidden information" takes the hidden layer, invisible
#            text, metadata, attachment, JavaScript and comments out
#   Edit     edit a paragraph in place (reflowed in its width, the font
#            matched: embedded font reused, Helvetica -> Liberation Sans),
#            add text, add/move/replace/delete a picture, delete and move a
#            path, move a text block; undo and redo
#   Comment  every kind saved as its standard annotation (checked with
#            poppler too), moved, edited, deleted
#   Fill     text, check box, radio, combo, list; flatten; signatures
#   Organize rotate, delete, move, insert blank and a file, extract, split,
#            combine
#   Protect  AES-256 with passwords and permissions (qpdf shows AESv3), a
#            restricted open refuses edits, the owner password unlocks,
#            removing security
#   Export   PNG, JPEG, text, HTML, .docx (a valid package with the text)
#
# Skips (77) without python3-pymupdf, qpdf or pdftotext.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
PDF = os.environ.get("SG_PDF_HELPER") or os.path.join(HERE, "..", "bin", "sg-pdf")
FAILS = 0

try:
    import pymupdf as fitz
except ImportError:
    print("SKIP: python3-pymupdf missing")
    sys.exit(77)
for tool in ("qpdf", "pdftotext"):
    if not shutil.which(tool):
        print("SKIP: %s missing" % tool)
        sys.exit(77)
sys.path.insert(0, HERE)
import pdf_fixtures as F  # noqa: E402


def check(cond, what):
    global FAILS
    print(("PASS " if cond else "FAIL ") + what)
    if not cond:
        FAILS += 1
    return cond


def esc(s):
    return s.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r")


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
        check(head.startswith("OK"), "%s (%s)" % (what, head[:150]))
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


def pdftotext(path, pw=None):
    cmd = ["pdftotext"] + (["-upw", pw] if pw else []) + [path, "-"]
    return subprocess.run(cmd, capture_output=True, text=True).stdout


def qpdf_ok(path, pw=None):
    r = subprocess.run(["qpdf", "--check"] + (["--password=" + pw] if pw else []) + [path], capture_output=True, text=True)
    return r.returncode == 0 and "No syntax or stream encoding errors" in r.stdout


def raw(path, pw=None):
    """the whole file, every stream uncompressed and decrypted"""
    out = path + ".qdf"
    subprocess.run(["qpdf", "--qdf", "--object-streams=disable", "--decode-level=all"] + (["--password=" + pw] if pw else [])
                   + [path, out], capture_output=True)
    with open(out, "rb") as f:
        data = f.read()
    os.unlink(out)
    return data


def raw_has(data, word):
    forms = [word.encode("latin-1"), word.encode("latin-1").hex().encode(), word.encode("latin-1").hex().upper().encode(),
             word.encode("utf-16-be"), word.encode("utf-16-be").hex().encode(), word.encode("utf-16-be").hex().upper().encode()]
    return any(f in data for f in forms)


def mupdf_text(path, pw=None):
    d = fitz.open(path)
    if pw:
        d.authenticate(pw)
    return "".join(p.get_text() for p in d)


def rects(*rs):
    return "rects=" + ";".join("%.2f %.2f %.2f %.2f" % r for r in rs)


T = tempfile.mkdtemp(prefix="sg-pdf-edit-", dir="/var/tmp")
c = Client()

# ============================================================================ Redact
red = F.redaction_pdf(os.path.join(T, "red.pdf"), T)
before = raw(red)
for w in F.SECRETS + F.HIDDEN:
    check(raw_has(before, w) or w in ("ATTACHSECRET",) and b"ATTACHSECRET" in before,
          "positive control: the unredacted file carries %s" % w)
text0 = pdftotext(red)
check("TOPSECRET" in text0 and "123-45-6789" in text0, "positive control: pdftotext reads the secrets before")
head, _ = c.ok("open the redaction document", "open", red)
check(field(head, "redactions") == "0", "no redaction marks yet")
head, data = c.ok("find TOPSECRET for redaction (preview, not marked)", "redactfind", "TOPSECRET", "", "0")
check(field(head, "n") == "2", "two TOPSECRET hits, one a page (%s)" % data.decode().strip().replace("\n", " | "))
head, _ = c.ok("mark every TOPSECRET", "redactfind", "TOPSECRET", "", "1")
check(field(head, "marked") == "2" and field(head, "redactions") == "2", "2 marks made (%s)" % head)
head, _ = c.ok("mark the SSN pattern", "redactfind", "pattern:ssn", "", "1")
check(field(head, "marked") == "1", "the SSN pattern found once")
head, _ = c.ok("mark the e-mail pattern", "redactfind", "pattern:email", "", "1")
check(field(head, "marked") == "1", "the e-mail pattern found once")
# areas: the picture's red square (part of the picture), FORMSECRET's form, a bit of the curve
head, _ = c.ok("mark three areas on page 1", "redactmark", "0",
               rects((430, 530, 470, 570), (70, 635, 280, 685), (240, 470, 262, 512)))
check(field(head, "redactions") == "7", "7 marks in all (%s)" % field(head, "redactions"))
head, data = c.ok("the marks render (red outlines) before applying", "render", "0", "1", "0")
drawings_before = len(fitz.open(red)[0].get_drawings())
head, _ = c.ok("apply the redactions", "redactapply")
check(field(head, "redactions") == "0", "no marks left once applied")
check(int(field(head, "cut") or 0) >= 2, "touched rectangles and lines were cut around the marks (cut=%s)" % field(head, "cut"))
check(int(field(head, "removed") or 0) >= 1, "the curve under a mark was removed whole (removed=%s)" % field(head, "removed"))
out = os.path.join(T, "redacted.pdf")
head, _ = c.ok("save the redacted document", "save", out)
check(field(head, "dirty") == "0", "saved: not dirty")
check(qpdf_ok(out), "qpdf --check: the redacted file is valid")
txt = pdftotext(out)
for w in F.SECRETS:
    check(w not in txt, "pdftotext cannot extract %s" % w)
mtxt = mupdf_text(out)
for w in F.SECRETS:
    check(w not in mtxt, "MuPDF cannot extract %s" % w)
after = raw(out)
for w in F.SECRETS:
    check(not raw_has(after, w), "no stream or object of the file holds %s (raw search)" % w)
check(not raw_has(after, "6789") and not raw_has(after, "john.public"), "no fragment of the SSN or the address either")
for w in ("Name: John Q Public", "Keep this line", "keep this too", "Second page text stays", "appears here too", "A row of the table"):
    check(w in txt, "the words around the marks stay: '%s'" % w)
rd = fitz.open(out)
p0 = rd[0]
imgs = p0.get_image_info(xrefs=True)
if check(len(imgs) == 1, "the picture is still there (only its pixels under the mark changed)"):
    pix = fitz.Pixmap(rd, imgs[0]["xref"])
    if pix.n > 3:
        pix = fitz.Pixmap(fitz.csRGB, pix)
    red_px = sum(1 for y in range(35, 65) for x in range(35, 65) if pix.pixel(x, y)[0] > 200 and pix.pixel(x, y)[1] < 60)
    blue = pix.pixel(10, 10)
    check(red_px < 30, "the red square's pixels are gone from the image itself (%d red left of 900)" % red_px)
    check(blue[2] > 180 and blue[0] < 80, "the picture's pixels outside the mark stay (%s)" % (blue,))
check(not any(a.type[0] == fitz.PDF_ANNOT_TEXT for a in p0.annots()), "the comment over the secret is gone")
check(not any("TOPSECRET" in (l.get("uri") or "") for l in p0.get_links()), "the link over the secret is gone")
dr = p0.get_drawings()
fills = [d for d in dr if d.get("fill") and abs(d["fill"][0] - 0.85) < 0.02]
check(len(fills) >= 1 and sum(fitz.Rect(d["rect"]).get_area() for d in fills) > 0.8 * 492 * 200,
      "the table's gray background is drawn again around the marks (%d pieces)" % len(fills))
greens = [d for d in dr if d.get("color") and d["color"][1] > 0.4 and d["color"][0] < 0.1]
check(not greens, "the green curve that touched a mark is not in the file")
verticals = [d for d in dr if d.get("color") == (0.0, 0.0, 0.0) and any(it[0] == "l" and abs(it[1].x - 180) < 0.5 and abs(it[2].x - 180) < 0.5 for it in d["items"])]
check(len(verticals) >= 1, "the table's vertical rule through TOPSECRET is kept outside the mark")
blackbox = [d for d in dr if d.get("fill") == (0.0, 0.0, 0.0)]
check(len(blackbox) >= 5, "black boxes are drawn where the marks were (%d)" % len(blackbox))
pix = p0.get_pixmap(dpi=72)
pix.save(os.path.join(T, "redacted-page1.png"))
shot = os.environ.get("SG_PDF_SHOTS")
if shot:
    pix.save(os.path.join(shot, "pdf-engine-redacted.png"))
    fitz.open(red)[0].get_pixmap(dpi=72).save(os.path.join(shot, "pdf-engine-before.png"))
# the hidden information is still there until it is removed
check(raw_has(after, "LAYERSECRET") and raw_has(after, "JSSECRET"), "the hidden layer and JavaScript are still in the file before 'remove hidden information'")
head, _ = c.ok("remove hidden information", "sanitize")
out2 = os.path.join(T, "sanitized.pdf")
c.ok("save the sanitized document", "save", out2)
check(qpdf_ok(out2), "qpdf --check: the sanitized file is valid")
clean = raw(out2)
for w in F.HIDDEN:
    check(not raw_has(clean, w), "hidden information gone from the file: %s" % w)
sd = fitz.open(out2)
check(sd.embfile_count() == 0, "no attachments")
check(not (sd.metadata or {}).get("title"), "no metadata title")
check("Keep this line" in pdftotext(out2), "the visible text stays")
# an unapplied mark is kept through other edits, and saving can apply it
c.ok("open the original again", "open", red)
c.ok("mark TOPSECRET", "redactfind", "TOPSECRET", "", "1")
head, _ = c.ok("an edit elsewhere", "rotate", "1", "90")
check(field(head, "redactions") == "2", "the marks survive other edits")
out3 = os.path.join(T, "apply-on-save.pdf")
c.ok("save, applying the marks", "save", out3, "apply=1")
check("TOPSECRET" not in pdftotext(out3) and not raw_has(raw(out3), "TOPSECRET"), "save apply=1 removes the marked text")

# ============================================================================ Edit PDF
ed = F.edit_pdf(os.path.join(T, "edit.pdf"), T)
head, _ = c.ok("open the edit document", "open", ed)
head, data = c.ok("list page 1's objects", "objects", "0")
objs = [l.split("\t") for l in data.decode().splitlines()]
texts = [o for o in objs if o[0] == "text"]
images = [o for o in objs if o[0] == "image"]
paths = [o for o in objs if o[0] == "path"]
check(len(texts) >= 2 and len(images) == 1 and len(paths) >= 2, "text blocks, a picture and paths (%d/%d/%d)" % (len(texts), len(images), len(paths)))
para = next((o for o in texts if "quick brown fox" in o[9]), None)
if check(para is not None, "the Helvetica paragraph is one block: '%s'" % (para[9] if para else "")):
    check(para[3].replace("\\ ", " ") in ("Liberation Sans", "Helvetica") and abs(float(para[4]) - 12) < 0.1,
          "its font and size are reported (%s %s)" % (para[3], para[4]))
    x0, y0, x1, y1 = map(float, para[2].split())
    new = "Edited in place: this sentence is much longer than the one it replaces, so it has to wrap inside the block's width and grow downward."
    head, _ = c.ok("edit the paragraph's text", "edittext", "0", para[1], "-", esc(new))
    check("LiberationSans" in (field(head, "font") or ""), "Helvetica (not embedded) is set in Liberation Sans (%s)" % field(head, "font"))
    tmp = os.path.join(T, "edited.pdf")
    c.ok("save the edited document", "save", tmp)
    check(qpdf_ok(tmp), "qpdf --check: the edited file is valid")
    t = pdftotext(tmp)
    check("quick brown fox" not in t, "the old text is gone")
    tn = " ".join(t.split())
    check("Edited in place" in tn and "grow downward" in tn, "the new text is in the file")
    words = [w for w in fitz.open(tmp)[0].get_text("words") if w[4] in ("Edited", "sentence", "wrap", "downward.")]
    check(words and all(w[0] >= x0 - 1 and w[2] <= x1 + 2 for w in words), "the new text flows within the block's width (%.0f-%.0f)" % (x0, x1))
    ys = sorted({round(w[1]) for w in fitz.open(tmp)[0].get_text("words") if w[1] >= y0 - 2 and w[1] < y0 + 200 and w[0] < x1 + 2})
    check(len(ys) >= 3, "it wraps to more lines than before (%d lines)" % len(ys))
    check("Embedded font line" in t, "the other block is untouched")
    head, _ = c.ok("undo the edit", "undo")
    check(field(head, "redo") == "1", "undo: one redo")
    c.ok("save after undo", "save", tmp)
    check("quick brown fox" in pdftotext(tmp) and "Edited in place" not in pdftotext(tmp), "undo brings the old text back")
    head, _ = c.ok("redo the edit", "redo")
    c.ok("save after redo", "save", tmp)
    check("Edited in place" in pdftotext(tmp), "redo applies it again")
emb = next((o for o in texts if "Embedded font line" in o[9]), None)
if emb and os.path.exists("/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf"):
    c.ok("objects again", "objects", "0")
    head, data = c.ask("objects", "0")
    emb = next(l.split("\t") for l in data.decode().splitlines() if "Embedded font line" in l)
    check(emb[5] == "1A3399", "the block's colour is reported (%s)" % emb[5])
    head, _ = c.ok("edit the embedded-font line", "edittext", "0", emb[1], "-", "Embedded font edited")
    check("LibSans" in (field(head, "font") or "") or "LiberationSans" in (field(head, "font") or ""),
          "the document's own (whole) font is reused (%s)" % field(head, "font"))
    tmp = os.path.join(T, "edited2.pdf")
    c.ok("save", "save", tmp)
    sp = [s for b in fitz.open(tmp)[0].get_text("dict")["blocks"] if b["type"] == 0 for l in b["lines"] for s in l["spans"] if "edited" in s["text"]]
    check(sp and abs(sp[0]["size"] - 14) < 0.2 and sp[0]["color"] == 0x1A3399, "size 14 and the colour kept")
head, data = c.ask("objects", "0")
objs = [l.split("\t") for l in data.decode().splitlines()]
head, _ = c.ok("add a text box", "addtext", "0", "320 500 520 540", esc("Added text box"), "size=16", "color=CC0000", "bold=1")
head, _ = c.ok("add a picture", "addimage", "0", "400 600 480 660", esc(F.green_png(os.path.join(T, "green.png"))))
tmp = os.path.join(T, "added.pdf")
c.ok("save", "save", tmp)
check("Added text box" in pdftotext(tmp), "the added text is in the file")
aw = [w for w in fitz.open(tmp)[0].get_text("words") if w[4] == "Added"]
check(aw and 318 <= aw[0][0] <= 330 and 495 <= aw[0][1] <= 520, "where it was put (%s)" % (aw[0][:4] if aw else None,))
ii = fitz.open(tmp)[0].get_image_info(xrefs=True)
check(len(ii) == 2 and any(abs(i["bbox"][0] - 400) < 1 and abs(i["bbox"][1] - 600) < 16 for i in ii), "the added picture is there (%s)" % [tuple(round(v) for v in i["bbox"]) for i in ii])
head, data = c.ask("objects", "0")
objs = [l.split("\t") for l in data.decode().splitlines()]
pic = next(o for o in objs if o[0] == "image" and o[2].startswith("72.00 300.00"))
xref = pic[3]
c.ok("move and resize the red picture", "moveobj", "0", pic[1], "200 650 300 750")
tmp = os.path.join(T, "moved.pdf")
c.ok("save", "save", tmp)
ii = fitz.open(tmp)[0].get_image_info(xrefs=True)
check(any(abs(i["bbox"][0] - 200) < 1 and abs(i["bbox"][1] - 650) < 1 and str(i["xref"]) == xref for i in ii), "the picture is at its new place, the same image object")
check(not any(abs(i["bbox"][0] - 72) < 1 and abs(i["bbox"][1] - 300) < 1 for i in ii), "and no longer at its old one")
head, data = c.ask("objects", "0")
objs = [l.split("\t") for l in data.decode().splitlines()]
pic = next(o for o in objs if o[0] == "image" and o[2].startswith("200.00 650.00"))
c.ok("replace the picture", "replaceimage", "0", pic[1], esc(os.path.join(T, "green.png")))
c.ok("save", "save", tmp)
ii = fitz.open(tmp)[0].get_image_info(xrefs=True)
check(len(ii) == 2 and not any(str(i["xref"]) == xref for i in ii), "the red picture was replaced by the green one")
head, data = c.ask("objects", "0")
objs = [l.split("\t") for l in data.decode().splitlines()]
for o in [o for o in objs if o[0] == "image"][:1]:
    c.ok("delete a picture", "delobj", "0", o[1])
c.ok("save", "save", tmp)
check(len(fitz.open(tmp)[0].get_image_info()) == 1, "one picture left after deleting one")
before_dr = fitz.open(tmp)[0].get_drawings()
head, data = c.ask("objects", "0")
objs = [l.split("\t") for l in data.decode().splitlines()]
redline = next((o for o in objs if o[0] == "path" and o[2].startswith("300.00 420.00")), None)
yellow = next((o for o in objs if o[0] == "path" and o[2].startswith("300.00 300.00")), None)
if check(redline and yellow, "the line and the yellow box are objects"):
    c.ok("delete the red line", "delobj", "0", redline[1])
    c.ok("save", "save", tmp)
    after_dr = fitz.open(tmp)[0].get_drawings()
    check(len(after_dr) == len(before_dr) - 1 and not any(d.get("color") and d["color"][0] > 0.7 and d["color"][1] < 0.1 for d in after_dr),
          "the red line is gone, the other paths stay (%d -> %d)" % (len(before_dr), len(after_dr)))
    head, data = c.ask("objects", "0")
    yellow = next(l.split("\t") for l in data.decode().splitlines() if l.startswith("path") and l.split("\t")[2].startswith("300.00 300.00"))
    c.ok("move the yellow box", "moveobj", "0", yellow[1], "450 300 550 350")
    c.ok("save", "save", tmp)
    ys = [d for d in fitz.open(tmp)[0].get_drawings() if d.get("fill") and d["fill"][0] > 0.8 and d["fill"][2] < 0.3]
    check(len(ys) == 1 and abs(ys[0]["rect"].x0 - 450) < 1.5, "the yellow box moved (%s)" % [tuple(round(v) for v in d["rect"]) for d in ys])
head, data = c.ask("objects", "0")
blk = next(l.split("\t") for l in data.decode().splitlines() if "Added text box" in l)
c.ok("move the added text block", "moveobj", "0", blk[1], "72 700 272 740")
c.ok("save", "save", tmp)
aw = [w for w in fitz.open(tmp)[0].get_text("words") if w[4] == "Added"]
check(len(aw) == 1 and abs(aw[0][0] - 72) < 4 and 695 < aw[0][1] < 720, "the text block moved (%s)" % (aw[0][:2] if aw else None,))
check(qpdf_ok(tmp), "qpdf --check: still valid after every edit")
head, _ = c.ask("objects", "9")
check(head.startswith("ERR range"), "objects of a page that does not exist refused")
head, _ = c.ask("delobj", "0", "999")
check(head.startswith("ERR range"), "an object that does not exist refused")

# a turned page (/Rotate 90): coordinates are the page as shown, new text reads upright
c.ok("open the edit document", "open", ed)
c.ok("turn page 2", "rotate", "1", "90")
c.ok("add text on the turned page", "addtext", "1", "100 100 400 140", esc("Upright words here"), "size=20")
head, data = c.ok("find it", "find", "Upright")
hb = data.decode().split()
check(len(hb) == 5 and hb[0] == "1" and abs(float(hb[1]) - 100) < 8 and abs(float(hb[2]) - 100) < 8,
      "the new text is where it was put on the shown page (%s)" % hb)
tr = os.path.join(T, "turned.pdf")
c.ok("save", "save", tr)
td = fitz.open(tr)
dirs = [l["dir"] for b in td[1].get_text("dict")["blocks"] if b["type"] == 0 for l in b["lines"]
        if "Upright" in "".join(s["text"] for s in l["spans"])]
check(dirs and abs(dirs[0][0]) < 0.01 and abs(abs(dirs[0][1]) - 1) < 0.01, "on the unturned page it runs at a quarter turn, so it reads upright shown (%s)" % dirs)
c.ok("add a picture on the turned page", "addimage", "1", "450 100 550 175", esc(os.path.join(T, "green.png")))
head, data = c.ok("its objects", "objects", "1")
im = [l.split("\t") for l in data.decode().splitlines() if l.startswith("image")]
check(im and [round(float(v)) for v in im[0][2].split()] == [450, 100, 550, 175], "the picture is where it was put (%s)" % (im[0][2] if im else None))
head, _ = c.ok("mark an area on the turned page", "redactmark", "1", rects((100, 100, 200, 140)))
c.ok("apply", "redactapply")
c.ok("save", "save", tr)
check("Upright" not in pdftotext(tr), "a mark on the turned page removes the text under it as shown")

# ============================================================================ Comment
c.ok("open the edit document", "open", ed)
kinds = [
    ("highlight", ["color=FFE500", rects((72, 72, 200, 86))], "Highlight"),
    ("underline", ["color=0000FF", rects((72, 86, 200, 100))], "Underline"),
    ("strikeout", ["color=FF0000", rects((200, 72, 300, 86))], "StrikeOut"),
    ("note", ["point=450 80", "text=" + esc("A sticky note")], "Text"),
    ("freetext", ["rect=300 500 500 540", "text=" + esc("Typed comment"), "fontsize=12", "color=000080"], "FreeText"),
    ("rect", ["rect=300 600 400 650", "color=FF0000", "width=2"], "Square"),
    ("ellipse", ["rect=420 600 520 650", "color=00AA00"], "Circle"),
    ("arrow", ["line=100 700 250 760", "color=0000FF"], "Line"),
    ("ink", ["ink=100 450 120 460 140 455 160 470;100 480 150 490", "color=000000", "width=1.5"], "Ink"),
]
for kind, opts, _ in kinds:
    head, _ = c.ok("add a %s comment" % kind, "annot", "0", kind, "author=Gate", *opts)
    check((field(head, "xref") or "0").isdigit() and int(field(head, "xref")) > 0, "  it has an object number")
head, data = c.ok("list the comments", "annots")
lines = [l.split("\t") for l in data.decode().splitlines()]
check(sorted(l[2] for l in lines) == sorted(k[2] for k in kinds), "every kind listed: %s" % sorted(l[2] for l in lines))
check(any(l[6] == "A sticky note" and l[5] == "Gate" for l in lines), "the note's text and author")
cm = os.path.join(T, "comments.pdf")
c.ok("save the comments", "save", cm)
check(qpdf_ok(cm), "qpdf --check: the commented file is valid")
got = sorted(a.type[1] for a in fitz.open(cm)[0].annots())
check(got == sorted(k[2] for k in kinds), "a fresh MuPDF reads every annotation back: %s" % got)
try:
    import gi
    gi.require_version("Poppler", "0.18")
    from gi.repository import Poppler
    pd = Poppler.Document.new_from_file("file://" + cm, None)
    ptypes = sorted(m.annot.get_annot_type().value_nick for m in pd.get_page(0).get_annot_mapping())
    check(len(ptypes) == len(kinds) and "highlight" in ptypes and "ink" in ptypes and "free-text" in ptypes,
          "another reader (poppler) shows them too: %s" % ptypes)
except (ImportError, ValueError):
    print("NOTE  poppler's GI bindings missing: the second reader is not checked")
head, data = c.ok("list the comments again (a save renumbers objects)", "annots")
lines = [l.split("\t") for l in data.decode().splitlines()]
note = next(l for l in lines if l[2] == "Text")
c.ok("edit the note's text", "setannot", "0", note[1], "text=" + esc("Edited note"))
sq = next(l for l in lines if l[2] == "Square")
c.ok("move the rectangle", "moveannot", "0", sq[1], "100 100 200 150")
hl = next(l for l in lines if l[2] == "Highlight")
c.ok("move the highlight", "moveannot", "0", hl[1], "72 150 200 164")
ink = next(l for l in lines if l[2] == "Ink")
c.ok("delete the ink", "delannot", "0", ink[1])
c.ok("save", "save", cm)
cmdoc = fitz.open(cm)
an = {a.type[1]: (fitz.Rect(a.rect), dict(a.info)) for a in cmdoc[0].annots()}
check(an.get("Text") and an["Text"][1]["content"] == "Edited note", "the note's new text is saved")
check(an.get("Square") and abs(an["Square"][0].x0 - 100) < 3 and abs(an["Square"][0].y0 - 100) < 3, "the rectangle moved")
check(an.get("Highlight") and abs(an["Highlight"][0].y0 - 150) < 3, "the highlight moved")
check("Ink" not in an, "the ink comment deleted")

# ============================================================================ Fill & Sign
fm = F.form_pdf(os.path.join(T, "form.pdf"))
head, _ = c.ok("open the form", "open", fm)
check(field(head, "form") == "1", "it is a form")
head, data = c.ok("list the fields", "fields")
flds = [l.split("\t") for l in data.decode().splitlines()]
check(sorted(f[2] for f in flds) == ["checkbox", "combo", "list", "radio", "radio", "text"], "six fields of five kinds (%s)" % [f[2] for f in flds])
byname = {}
for f in flds:
    byname.setdefault(f[5], []).append(f)
c.ok("fill the text field", "setfield", "0", byname["fullname"][0][1], esc("Jane Q Tester"))
c.ok("tick the check box", "setfield", "0", byname["agree"][0][1], "1")
c.ok("choose the second radio button", "setfield", "0", byname["size"][1][1], "1")
c.ok("choose Blue", "setfield", "0", byname["colour"][0][1], "Blue")
c.ok("choose Plum", "setfield", "0", byname["fruit"][0][1], "Plum")
ff = os.path.join(T, "filled.pdf")
c.ok("save the filled form", "save", ff)
check(qpdf_ok(ff), "qpdf --check: the filled form is valid")
vals = {}
for w in fitz.open(ff)[0].widgets():
    vals.setdefault(w.field_name, []).append(w.field_value)
check(vals.get("fullname") == ["Jane Q Tester"], "text field value saved (%s)" % vals.get("fullname"))
check(vals.get("agree") not in ([False], ["Off"], None), "check box saved ticked (%s)" % vals.get("agree"))
check(vals.get("size", [None, None])[1] not in (False, "Off", None) and vals.get("size", [None])[0] in (False, "Off"),
      "the second radio button is the one on (%s)" % vals.get("size"))
check(vals.get("colour") == ["Blue"] and vals.get("fruit") == ["Plum"], "choices saved (%s %s)" % (vals.get("colour"), vals.get("fruit")))
try:
    pd = Poppler.Document.new_from_file("file://" + ff, None)
    ptext = [m.field.text_get_text() for m in pd.get_page(0).get_form_field_mapping() if m.field.get_field_type() == Poppler.FormFieldType.TEXT]
    check(ptext == ["Jane Q Tester"], "poppler reads the text field's value (%s)" % ptext)
except NameError:
    pass
head, _ = c.ask("setfield", "0", "999", "x")
check(head.startswith("ERR"), "a field that does not exist refused")
c.ok("place a drawn signature", "signature", "0", "350 400 550 460", "ink", "0.05 0.6 0.2 0.2 0.35 0.7 0.5 0.3 0.7 0.8 0.95 0.4")
c.ok("place a typed signature", "signature", "0", "350 470 550 510", "text", esc("Jane Tester"))
c.ok("place a picture signature", "signature", "0", "350 520 450 560", "image", esc(os.path.join(T, "green.png")))
c.ok("flatten the form", "flatten", "forms=1")
fl = os.path.join(T, "flat.pdf")
head, _ = c.ok("save the flattened form", "save", fl)
check(qpdf_ok(fl), "qpdf --check: the flattened file is valid")
fd = fitz.open(fl)
check(not list(fd[0].widgets()), "no fields left once flattened")
check("Jane Q Tester" in pdftotext(fl), "the filled value is now page text (pdftotext reads it)")
check("Jane Tester" in pdftotext(fl), "the typed signature is on the page")
check(any(d.get("color") and abs(d["color"][2] - 0.4) < 0.05 and len(d["items"]) >= 3 for d in fd[0].get_drawings()), "the drawn signature's strokes are on the page")
check(len(fd[0].get_image_info()) == 1, "the picture signature is on the page")

# ============================================================================ Organize
org = F.edit_pdf(os.path.join(T, "org.pdf"), T)


def page_markers(path):
    d = fitz.open(path)
    out = []
    for p in d:
        m = re.search(r"Page (\d) marker", p.get_text())
        out.append(m.group(1) if m else ("1" if "quick brown" in p.get_text() else "blank"))
    return out


c.ok("open for organizing", "open", org)
head, _ = c.ok("rotate pages 2-3", "rotate", "1-2", "90")
head, _ = c.ok("move page 4 to the front", "move", "3", "0")
head, _ = c.ok("delete the (now) third page", "delete", "2")
check(head.startswith("OK pages=3"), "three pages left (%s)" % head[:20])
head, _ = c.ok("insert a blank page at the end", "insertblank", "3")
check(head.startswith("OK pages=4"), "four pages")
g = os.path.join(T, "green.png")
head, _ = c.ok("insert a picture file as page 2", "insertfile", "1", esc(g))
head, _ = c.ok("insert another PDF at the end", "insertfile", "5", esc(fm))
check(head.startswith("OK pages=6"), "six pages (%s)" % head[:20])
og = os.path.join(T, "organized.pdf")
c.ok("save", "save", og)
check(qpdf_ok(og), "qpdf --check: the organized file is valid")
mk = page_markers(og)
check(mk[0] == "4" and mk[2] == "1" and mk[3] == "3" and mk[4] == "blank", "page order is 4, picture, 1, 3, blank, form (%s)" % mk)
rots = [p.rotation for p in fitz.open(og)]
check(rots[3] == 90 and rots[2] == 0, "page 3 of old kept its quarter turn (%s)" % rots)
ex = os.path.join(T, "extract.pdf")
head, _ = c.ok("extract pages 1 and 3", "extract", "0,2", esc(ex))
check(page_markers(ex) == ["4", "1"] and qpdf_ok(ex), "the extracted file has those pages (%s)" % page_markers(ex))
os.makedirs(os.path.join(T, "split"))
head, data = c.ok("split every 2 pages", "split", "2", esc(os.path.join(T, "split")), "part")
parts = data.decode().split()
check(len(parts) == 3 and all(fitz.open(p).page_count == 2 and qpdf_ok(p) for p in parts), "3 files of 2 pages (%s)" % [os.path.basename(p) for p in parts])
cb = os.path.join(T, "combined.pdf")
head, _ = c.ok("combine three files", "combine", esc(cb), esc(ed), esc(fm), esc(g))
check(fitz.open(cb).page_count == 6 and qpdf_ok(cb), "the combined file has 4 + 1 + 1 pages")
head, _ = c.ask("delete", "0-5")
check(head.startswith("ERR"), "deleting every page is refused")
c.ok("undo the last insert", "undo")
head, _ = c.ok("state", "state")
check(head.startswith("OK pages=5"), "undo takes the inserted file out again")

# ============================================================================ Protect
c.ok("open to protect", "open", ed)
c.ok("encrypt with passwords", "protect", "mode=aes256", "user=" + esc("open sesame"), "owner=" + esc("own3r"), "perms=print,copy")
head, _ = c.ok("state", "state")
check(field(head, "protect") == "aes256" and field(head, "dirty") == "1", "the new security waits for the save")
pr = os.path.join(T, "protected.pdf")
c.ok("save encrypted", "save", pr)
enc = subprocess.run(["qpdf", "--show-encryption", "--password=own3r", pr], capture_output=True, text=True).stdout
check("AESv3" in enc and "R = 6" in enc, "AES-256 (qpdf: AESv3, R6)")
check("modify document: not allowed" in enc and "print high resolution: allowed" in enc or "print low resolution: allowed" in enc,
      "permissions: printing allowed, changing not")
check(qpdf_ok(pr, "open sesame"), "qpdf --check with the user password")
check(pdftotext(pr) == "" or "quick" not in pdftotext(pr), "without the password the text cannot be read")
check("quick brown fox" in pdftotext(pr, "open sesame"), "with it, it can")
check(not raw_has(open(pr, "rb").read(), "quick brown"), "the file's bytes do not carry the text")
head, _ = c.ask("open", pr)
check(head.startswith("ERR password"), "opening asks for the password")
head, _ = c.ask("open", pr, "wrong")
check(head.startswith("ERR password"), "a wrong password is refused")
head, _ = c.ok("open with the user password", "open", pr, "open sesame")
check(field(head, "encrypted") == "1" and int(field(head, "perms")) & 8 == 0, "restricted: no right to change it (perms=%s)" % field(head, "perms"))
head, _ = c.ask("addtext", "0", "72 600 300 640", "x")
check(head.startswith("ERR secured"), "an edit is refused (%s)" % head)
head, _ = c.ask("unlock", "nope")
check(head.startswith("ERR password"), "a wrong permissions password is refused")
head, _ = c.ok("unlock with the owner password", "unlock", esc("own3r"))
check(int(field(head, "perms")) & 8 == 8, "every right after the owner password")
c.ok("an edit now works", "addtext", "0", "72 600 300 640", "Unlocked edit")
pr2 = os.path.join(T, "protected2.pdf")
c.ok("save keeping the security", "save", pr2)
check("AESv3" in subprocess.run(["qpdf", "--show-encryption", "--password=own3r", pr2], capture_output=True, text=True).stdout
      and "Unlocked edit" in pdftotext(pr2, "open sesame"), "saved again, still AES-256, with the edit")
c.ok("remove the security", "protect", "mode=none")
pr3 = os.path.join(T, "unprotected.pdf")
c.ok("save without security", "save", pr3)
check("not encrypted" in subprocess.run(["qpdf", "--show-encryption", pr3], capture_output=True, text=True).stdout
      and "Unlocked edit" in pdftotext(pr3), "the saved file has no security")
head, _ = c.ok("reopen it", "open", pr3)
check(field(head, "encrypted") == "0", "it opens with no password")

# ============================================================================ Export
c.ok("open to export", "open", ed)
head, data = c.ok("export PNG", "export", "png", esc(os.path.join(T, "exp.png")), "dpi=72")
files = data.decode().split("\n")[:-1]
check(len(files) == 4 and all(os.path.getsize(f) > 100 for f in files), "one PNG a page (%s)" % [os.path.basename(f) for f in files])
check(fitz.Pixmap(files[0]).width == 612, "72 dpi: 612 pixels wide")
head, data = c.ok("export JPEG of page 2", "export", "jpeg", esc(os.path.join(T, "exp.jpg")), "pages=1", "dpi=100")
jf = data.decode().split()[0]
check(open(jf, "rb").read(2) == b"\xff\xd8" and fitz.Pixmap(jf).width == 850, "a JPEG at 100 dpi (850 wide)")
head, _ = c.ok("export text", "export", "txt", esc(os.path.join(T, "exp.txt")))
t = open(os.path.join(T, "exp.txt"), encoding="utf-8").read()
check("quick brown fox" in t and "Page 4 marker" in t, "the text file has every page's text")
head, _ = c.ok("export HTML", "export", "html", esc(os.path.join(T, "exp.html")))
check("Page 3 marker" in open(os.path.join(T, "exp.html"), encoding="utf-8").read(), "the HTML has the text")
dx = os.path.join(T, "exp.docx")
head, _ = c.ok("export Word", "export", "docx", esc(dx))
try:
    z = zipfile.ZipFile(dx)
    names = z.namelist()
    docxml = z.read("word/document.xml").decode("utf-8")
    import xml.dom.minidom
    xml.dom.minidom.parseString(docxml)
    xml.dom.minidom.parseString(z.read("[Content_Types].xml"))
    check(z.testzip() is None and "word/document.xml" in names, "the .docx is a valid package")
    check("quick brown fox" in docxml and "Page 4 marker" in docxml, "its paragraphs have the text")
    check(any(n.startswith("word/media/") for n in names) and "r:embed" in docxml, "the picture is in it")
    check(docxml.count('w:type="page"') == 3, "a page break between pages")
    check('w:sz w:val="36"' in docxml, "18 pt text kept its size")
except (zipfile.BadZipFile, KeyError, Exception) as e:  # noqa: B014
    check(False, "the .docx: %s" % e)
if shutil.which("soffice") and os.environ.get("SG_PDF_SOFFICE") == "1":
    r = subprocess.run(["soffice", "--headless", "--convert-to", "txt:Text", "--outdir", T, dx], capture_output=True, text=True, timeout=120)
    check("quick brown fox" in open(os.path.join(T, "exp.txt"), encoding="utf-8", errors="replace").read(), "LibreOffice reads the .docx")

# ============================================================================ Refusals
head, _ = c.ask("annot", "0", "bogus")
check(head.startswith("ERR invalid"), "an unknown comment kind refused")
head, _ = c.ask("rotate", "0", "45")
check(head.startswith("ERR invalid"), "a rotation that is not a quarter turn refused")
head, _ = c.ask("redactapply")
check(head.startswith("ERR invalid"), "applying with nothing marked refused")
head, _ = c.ask("undo")
check(head.startswith("ERR invalid") or head.startswith("OK"), "undo with nothing to undo refused (or harmless)")
head, _ = c.ask("save", "/nonexistent/dir/x.pdf")
check(head.startswith("ERR failed"), "saving where it cannot refused")
head, _ = c.ok("state after refusals", "state")
c.close()
if not FAILS:
    shutil.rmtree(T, ignore_errors=True)
else:
    print("left in " + T)
print("pdf-edit-test: all passed" if not FAILS else "pdf-edit-test: %d FAILED" % FAILS)
sys.exit(1 if FAILS else 0)
