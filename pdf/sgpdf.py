# sgpdf -- SG PDF's engine: one open document, read and edited through
# MuPDF (Debian's python3-pymupdf, AGPL like us). bin/sg-pdf speaks the
# line protocol and calls this; the Windows program (sg-shell's
# sg-pdf64.exe) draws and drives it.
#
# Coordinates on the protocol are points on the page as it is shown -- its
# /Rotate applied, origin top-left. MuPDF works on the unrotated page, so
# every rectangle and point is turned on the way in (ui_rect/ui_point) and
# on the way out (out_rect).
#
# What each edit does to the file:
#   Edit PDF    text: the block's glyphs are removed from the content stream
#               (a private redaction, text only) and the new text is set in
#               the block's rectangle -- reflowed within its width, growing
#               down -- in the block's font when it is embedded whole, else
#               the closest installed family (fontconfig: Arial -> Liberation
#               Sans ...), its size, colour and alignment. images: the one
#               "Do" that draws it is cut from the content stream (the image
#               object stays for any other use) and it is drawn again where it
#               goes. paths: removed by a private redaction and drawn again.
#   Comment     standard annotations (Highlight, Underline, StrikeOut, Text,
#               FreeText, Square, Circle, Line, Ink) other readers show.
#   Fill & Sign AcroForm field values with their appearances; flatten bakes
#               them into the page; a signature is drawn into the page.
#   Redact      marks are Redact annotations; Apply removes the text, the
#               image pixels and the vector paths under them from the content
#               streams (MuPDF's redaction, form XObjects included), then
#               draws again the parts of touched rectangles and straight lines
#               outside the marks (table rules, backgrounds); any other
#               touched path is removed whole. Annotations, links and fields
#               over a mark go too. Saving is always a full rewrite without
#               unreferenced objects, so nothing removed stays in the file.
#
# Copyright (C) 2026 Stained Glass OS contributors
# SPDX-License-Identifier: AGPL-3.0-or-later

import math
import os
import re
import struct
import subprocess
import tempfile

import pymupdf as fitz

from sgpdf_content import count_do, remove_do, remove_invisible_text, remove_marked
import sgpdf_docx

MAX_PIXELS = 60_000_000
UNDO_LEVELS = 40
UNDO_BYTES = 512 << 20
MAX_OBJECTS = 4000

PERM_ALL = 0xFFFFFFFF
PERM_NAMES = {
    "print": fitz.PDF_PERM_PRINT, "modify": fitz.PDF_PERM_MODIFY, "copy": fitz.PDF_PERM_COPY,
    "annotate": fitz.PDF_PERM_ANNOTATE, "form": fitz.PDF_PERM_FORM,
    "accessibility": fitz.PDF_PERM_ACCESSIBILITY, "assemble": fitz.PDF_PERM_ASSEMBLE,
    "print_hq": fitz.PDF_PERM_PRINT_HQ,
}

PATTERNS = {
    # what "Find text & redact" offers besides a phrase
    "phone": r"(?<!\d)(?:\+?1[ .-]?)?(?:\(\d{3}\)|\d{3})[ .-]?\d{3}[ .-]\d{4}(?!\d)",
    "email": r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}",
    "ssn": r"(?<!\d)\d{3}-\d{2}-\d{4}(?!\d)",
    "card": r"(?<!\d)(?:\d{4}[ -]?){3}\d{1,4}(?!\d)",
    "date": r"(?<!\d)(?:\d{1,2}[/.-]\d{1,2}[/.-]\d{2,4}|\d{4}-\d{2}-\d{2})(?!\d)",
}


class Refusal(Exception):
    def __init__(self, kind, message):
        super().__init__(message)
        self.kind = kind


def one_line(s):
    return " ".join((s or "").split())


def esc(s):
    return (s or "").replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r")


def unesc(s):
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            out.append({"t": "\t", "n": "\n", "r": "\r", "\\": "\\"}.get(n, n))
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def hexcolor(c):
    if c is None or (not isinstance(c, int) and len(c) not in (1, 3, 4)):
        return "-"
    if isinstance(c, int):
        return "%06X" % (c & 0xFFFFFF)
    if len(c) == 1:
        c = (c[0], c[0], c[0])
    if len(c) == 4:  # CMYK
        k = c[3]
        c = ((1 - c[0]) * (1 - k), (1 - c[1]) * (1 - k), (1 - c[2]) * (1 - k))
    return "%02X%02X%02X" % tuple(max(0, min(255, int(round(v * 255)))) for v in c[:3])


def rgb(s, default=(0, 0, 0)):
    if not s or s == "-":
        return default
    try:
        v = int(s, 16)
    except ValueError:
        raise Refusal("invalid", "not a colour: " + s)
    return ((v >> 16 & 255) / 255.0, (v >> 8 & 255) / 255.0, (v & 255) / 255.0)


def floats(s, n=None):
    try:
        v = [float(x) for x in s.replace(",", " ").split()]
    except ValueError:
        raise Refusal("invalid", "not numbers: " + s[:40])
    if any(math.isnan(x) or math.isinf(x) for x in v) or (n is not None and len(v) != n):
        raise Refusal("invalid", "expected %s numbers" % n)
    return v


def fmt_rect(r):
    return "%.2f %.2f %.2f %.2f" % (r.x0, r.y0, r.x1, r.y1)


def kv(args):
    out = {}
    for a in args:
        if "=" not in a:
            raise Refusal("invalid", "expected key=value: " + a[:40])
        k, v = a.split("=", 1)
        out[k] = unesc(v)
    return out


def parse_pages(spec, n):
    """'0,2,4-6' (0-based) -> sorted unique page numbers, each < n"""
    out = set()
    for part in (spec or "").split(","):
        part = part.strip()
        if not part:
            continue
        try:
            if "-" in part:
                a, b = part.split("-", 1)
                a, b = int(a), int(b)
                if a > b:
                    a, b = b, a
                out.update(range(a, b + 1))
            else:
                out.add(int(part))
        except ValueError:
            raise Refusal("invalid", "not a page list: " + spec[:40])
    if not out or min(out) < 0 or max(out) >= n:
        raise Refusal("range", "no such page")
    return sorted(out)


def rect_minus(r, holes):
    """r without the holes, as rectangles"""
    pieces = [fitz.Rect(r)]
    for h in holes:
        nxt = []
        for p in pieces:
            if not p.intersects(h):
                nxt.append(p)
                continue
            if h.y0 > p.y0:
                nxt.append(fitz.Rect(p.x0, p.y0, p.x1, h.y0))
            if h.y1 < p.y1:
                nxt.append(fitz.Rect(p.x0, h.y1, p.x1, p.y1))
            y0, y1 = max(p.y0, h.y0), min(p.y1, h.y1)
            if h.x0 > p.x0:
                nxt.append(fitz.Rect(p.x0, y0, h.x0, y1))
            if h.x1 < p.x1:
                nxt.append(fitz.Rect(h.x1, y0, p.x1, y1))
        pieces = [p for p in nxt if p.width > 0.01 and p.height > 0.01]
    return pieces


def segment_minus(a, b, holes):
    """the segment a-b without the parts inside the holes (Liang-Barsky)"""
    keep = [(0.0, 1.0)]
    dx, dy = b.x - a.x, b.y - a.y
    for h in holes:
        t0, t1 = 0.0, 1.0
        ok = True
        for p, q in ((-dx, a.x - h.x0), (dx, h.x1 - a.x), (-dy, a.y - h.y0), (dy, h.y1 - a.y)):
            if abs(p) < 1e-12:
                if q < 0:
                    ok = False
                    break
            else:
                t = q / p
                if p < 0:
                    t0 = max(t0, t)
                else:
                    t1 = min(t1, t)
        if not ok or t0 >= t1:
            continue
        nxt = []
        for s, e in keep:
            if e <= t0 or s >= t1:
                nxt.append((s, e))
                continue
            if s < t0:
                nxt.append((s, t0))
            if e > t1:
                nxt.append((t1, e))
        keep = nxt
    length = math.hypot(dx, dy)
    return [(fitz.Point(a.x + dx * s, a.y + dy * s), fitz.Point(a.x + dx * e, a.y + dy * e))
            for s, e in keep if (e - s) * length > 0.05]


def drawing_key(d):
    return (d.get("type"), tuple(round(v, 1) for v in d["rect"]), len(d.get("items", [])),
            hexcolor(d.get("color")), hexcolor(d.get("fill")))


def draw_paths(page, drawings, overlay=True):
    """draw MuPDF drawings (page.get_drawings() form) into the page again"""
    if not drawings:
        return
    shape = page.new_shape()
    for d in drawings:
        n = 0
        for it in d.get("items", []):
            op = it[0]
            if op == "l":
                shape.draw_line(it[1], it[2])
            elif op == "c":
                shape.draw_bezier(it[1], it[2], it[3], it[4])
            elif op == "re":
                shape.draw_rect(it[1])
            elif op == "qu":
                shape.draw_quad(it[1])
            else:
                continue
            n += 1
        if not n:
            continue
        kind = d.get("type") or "s"
        cap = d.get("lineCap")
        if isinstance(cap, (tuple, list)):
            cap = max(cap) if cap else 0
        dashes = d.get("dashes")
        if dashes in ("[] 0", "[] 0.0"):
            dashes = None
        shape.finish(color=d.get("color") if "s" in kind else None,
                     fill=d.get("fill") if "f" in kind else None,
                     width=d.get("width") or 1.0,
                     even_odd=bool(d.get("even_odd")),
                     closePath=bool(d.get("closePath")),
                     lineCap=int(cap or 0), lineJoin=int(d.get("lineJoin") or 0),
                     dashes=dashes,
                     fill_opacity=d.get("fill_opacity") if d.get("fill_opacity") is not None else 1,
                     stroke_opacity=d.get("stroke_opacity") if d.get("stroke_opacity") is not None else 1)
    shape.commit(overlay=overlay)


def drawing_minus(d, holes):
    """What of drawing d may be drawn again outside the holes, exactly:
    rectangles become the rectangles around the holes, straight lines the
    segments outside them. A path with curves is not cut (its shape could
    carry what was redacted -- lettering drawn as outlines): None."""
    items = d.get("items", [])
    kind = d.get("type") or "s"
    out = []
    rects, lines = [], []
    for it in items:
        if it[0] == "re":
            rects.append(fitz.Rect(it[1]))
        elif it[0] == "qu":
            q = it[1]
            if not q.is_rectangular:
                return None
            rects.append(q.rect)
        elif it[0] == "l":
            lines.append((fitz.Point(it[1]), fitz.Point(it[2])))
        else:
            return None
    if lines and "f" in kind:
        # a filled polygon of straight lines: only an axis-aligned rectangle is cut
        pts = [p for seg in lines for p in seg]
        xs = sorted({round(p.x, 2) for p in pts})
        ys = sorted({round(p.y, 2) for p in pts})
        if len(xs) != 2 or len(ys) != 2:
            return None
        rects.append(fitz.Rect(xs[0], ys[0], xs[1], ys[1]))
        lines = [] if "s" not in kind else lines
        if "s" in kind:
            kind_lines = "s"
        else:
            kind_lines = None
    else:
        kind_lines = "s" if lines else None
    base = {k: d.get(k) for k in ("color", "fill", "width", "lineCap", "lineJoin", "dashes",
                                  "fill_opacity", "stroke_opacity", "even_odd")}
    for r in rects:
        if "f" in kind:
            pieces = rect_minus(r, holes)
            if pieces:
                out.append(dict(base, type="f", items=[("re", p, 1) for p in pieces], closePath=False))
        if "s" in kind:
            edges = [(r.tl, r.tr), (r.tr, r.br), (r.br, r.bl), (r.bl, r.tl)]
            segs = [s for a, b in edges for s in segment_minus(a, b, holes)]
            if segs:
                out.append(dict(base, type="s", items=[("l", a, b) for a, b in segs], closePath=False))
    if kind_lines:
        segs = [s for a, b in lines for s in segment_minus(a, b, holes)]
        if segs:
            out.append(dict(base, type="s", items=[("l", a, b) for a, b in segs], closePath=False))
    return out


# ---- fonts ------------------------------------------------------------------------------------

_FONT_CACHE = {}


def fc_match(query):
    try:
        out = subprocess.run(["fc-match", "-f", "%{file}", query], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    out = out.strip()
    if out and out.lower().endswith((".ttf", ".otf", ".ttc")) and os.path.isfile(out):
        return out
    return None


def family_of(fontname):
    """PDF font name -> a family name to ask fontconfig for"""
    name = fontname or ""
    if re.match(r"^[A-Z]{6}\+", name):
        name = name[7:]
    name = name.split(",")[0].split("-")[0]
    name = re.sub(r"(PSMT|PS|MT)$", "", name)
    low = name.lower()
    for key, fam in (("helvetica", "Liberation Sans"), ("arial", "Arial"), ("times", "Times New Roman"),
                     ("courier", "Courier New"), ("calibri", "Calibri"), ("cambria", "Cambria"),
                     ("verdana", "DejaVu Sans"), ("georgia", "Liberation Serif"),
                     ("helv", "Liberation Sans"), ("tiro", "Liberation Serif"),
                     ("cour", "Liberation Mono")):
        if low.startswith(key):
            return fam
    return re.sub(r"(?<=[a-z])(?=[A-Z])", " ", name).replace("Deja Vu", "DejaVu") or "Liberation Sans"


def style_of(fontname, flags):
    low = (fontname or "").lower()
    bold = bool(flags & 16) or "bold" in low or "black" in low or "heavy" in low or "semibold" in low
    italic = bool(flags & 2) or "italic" in low or "oblique" in low
    return bold, italic


def system_font(family, bold, italic, serif=False, mono=False):
    key = ("sys", family, bold, italic, serif, mono)
    if key in _FONT_CACHE:
        return _FONT_CACHE[key]
    q = family + (":weight=bold" if bold else "") + (":slant=italic" if italic else "")
    path = fc_match(q)
    font = None
    if path:
        try:
            font = (fitz.Font(fontfile=path), os.path.basename(path))
        except Exception:
            font = None
    if font is None:
        base = "cour" if mono else ("tiro" if serif else "helv")
        code = {"helv": ["helv", "hebo", "heit", "hebi"], "tiro": ["tiro", "tibo", "tiit", "tibi"],
                "cour": ["cour", "cobo", "coit", "cobi"]}[base][(1 if bold else 0) + (2 if italic else 0)]
        font = (fitz.Font(code), code)
    _FONT_CACHE[key] = font
    return font


def write_upright(tw, p):
    """write a TextWriter laid out in shown-page coordinates so that it
    reads upright on a turned (/Rotate) page"""
    if not p.rotation:
        tw.write_text(p)
        return
    cb, mb = p.cropbox_position, p.mediabox
    delta = p.rect.height - p.rect.width if p.rotation in (90, 270) else 0
    # write_text puts this translation first; the matrix goes after it
    t = fitz.Matrix(1, 0, 0, 1, cb.x, cb.y + mb.y0 - delta)
    m = ~tw.ictm * p.derotation_matrix * ~p.transformation_matrix * ~t
    tw.write_text(p, matrix=m)


def covers(font, text):
    return all(font.has_glyph(ord(ch)) for ch in text if not ch.isspace())


# ---- the engine -------------------------------------------------------------------------------

class Engine:
    def __init__(self):
        self.doc = None
        self.path = None
        self.password = None
        self.perms = PERM_ALL
        self.encrypted = False
        self.security = None         # None: as it was; ("none",); ("aes256", user, owner, perms)
        self.undo = []
        self.redo = []
        self.dirty = False
        self.objcache = {}
        self.author = os.environ.get("USER", "") or "User"

    # ---- basics -------------------------------------------------------------------------

    def need_doc(self):
        if not self.doc:
            raise Refusal("notopen", "no document is open")

    def page(self, n):
        self.need_doc()
        try:
            n = int(n)
        except (TypeError, ValueError):
            raise Refusal("invalid", "page is not a number")
        if not 0 <= n < self.doc.page_count:
            raise Refusal("range", "no such page")
        return self.doc[n]

    @staticmethod
    def ui_rect(page, r):
        r = fitz.Rect(r)
        return (r * page.derotation_matrix).normalize() if page.rotation else r

    @staticmethod
    def ui_point(page, p):
        p = fitz.Point(p)
        return p * page.derotation_matrix if page.rotation else p

    @staticmethod
    def out_rect(page, r):
        r = fitz.Rect(r)
        return (r * page.rotation_matrix).normalize() if page.rotation else r

    def info_payload(self):
        out = []
        for p in self.doc:
            r = p.rect
            out.append("size %.3f %.3f" % (r.width, r.height))
        md = self.doc.metadata or {}
        out.append("title " + one_line(md.get("title")))
        out.append("author " + one_line(md.get("author")))
        out.append("subject " + one_line(md.get("subject")))
        out.append("keywords " + one_line(md.get("keywords")))
        out.append("creator " + one_line(md.get("creator")))
        out.append("producer " + one_line(md.get("producer")))
        return ("\n".join(out) + "\n").encode("utf-8")

    def state_fields(self):
        prot = "keep" if self.security is None else self.security[0]
        nred = 0
        for p in self.doc:
            nred += sum(1 for _ in p.annots(types=[fitz.PDF_ANNOT_REDACT]))
        return ("undo=%d redo=%d dirty=%d perms=%d encrypted=%d protect=%s form=%d redactions=%d"
                % (len(self.undo), len(self.redo), 1 if self.dirty else 0, self.perms & 0xFFFF,
                   1 if self.encrypted else 0, prot, 1 if self.doc.is_form_pdf else 0, nred))

    def state(self, extra=""):
        self.need_doc()
        data = self.info_payload()
        head = "OK pages=%d %s%s bytes=%d" % (self.doc.page_count, self.state_fields(), (" " + extra) if extra else "", len(data))
        return head, data

    def allowed(self, perm):
        return bool(self.perms & perm)

    def begin(self, perm=fitz.PDF_PERM_MODIFY):
        """before a change: permission, then an undo point"""
        self.need_doc()
        if not self.allowed(perm):
            raise Refusal("secured", "the document's security does not allow this change")
        snap = self.doc.tobytes(encryption=fitz.PDF_ENCRYPT_KEEP)
        self.undo.append(snap)
        while len(self.undo) > UNDO_LEVELS or (len(self.undo) > 1 and sum(map(len, self.undo)) > UNDO_BYTES):
            self.undo.pop(0)
        self.redo = []

    def changed(self):
        self.dirty = True
        self.objcache = {}

    def reopen(self, data):
        doc = fitz.open("pdf", data)
        if doc.needs_pass:
            doc.authenticate(self.password or "")
        self.doc = doc
        self.objcache = {}

    # ---- the viewer's requests -------------------------------------------------------------

    def open(self, path, password=None):
        if not os.path.isfile(path):
            return "ERR open no such file", b""
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError as e:
            return "ERR open " + one_line(e.strerror or str(e)), b""
        try:
            doc = fitz.open("pdf", data)
        except Exception as e:
            return "ERR open " + one_line(str(e)), b""
        perms = PERM_ALL
        encrypted = doc.needs_pass or bool((doc.metadata or {}).get("encryption"))
        if doc.needs_pass:
            if not password:
                return "ERR password the document needs a password", b""
            rc = doc.authenticate(password)
            if not rc:
                return "ERR password the password is not right", b""
            if not rc & 4:
                perms = doc.permissions
        elif encrypted:
            # no password to open, but an owner password restricts it
            perms = doc.permissions
            if password and doc.authenticate(password) & 4:
                perms = PERM_ALL
        self.doc = doc
        self.path = path
        self.password = password
        self.perms = perms
        self.encrypted = encrypted
        self.security = None
        self.undo, self.redo = [], []
        self.dirty = False
        self.objcache = {}
        return self.state()

    def render(self, n, scale, rot):
        p = self.page(n)
        try:
            scale = float(scale)
            rot = int(rot) % 360
        except ValueError:
            raise Refusal("invalid", "scale or rotation is not a number")
        if not (0.01 <= scale <= 64) or math.isnan(scale) or rot not in (0, 90, 180, 270):
            raise Refusal("invalid", "scale or rotation out of range")
        r = p.rect
        if math.ceil(r.width * scale) * math.ceil(r.height * scale) > MAX_PIXELS:
            raise Refusal("toolarge", "the page would be too large a bitmap")
        pix = p.get_pixmap(matrix=fitz.Matrix(scale, scale).prerotate(rot), alpha=False, annots=True)
        w, h = pix.width, pix.height
        s = pix.samples
        if pix.stride != w * 3:
            s = b"".join(s[y * pix.stride:y * pix.stride + w * 3] for y in range(h))
        buf = bytearray(w * h * 4)
        buf[0::4] = s[2::3]
        buf[1::4] = s[1::3]
        buf[2::4] = s[0::3]
        buf[3::4] = b"\xff" * (w * h)
        return "OK w=%d h=%d bytes=%d" % (w, h, len(buf)), bytes(buf)

    def chars(self, p):
        """the page's characters in reading order: (text, [boxes]) -- a "\n"
        (box of zeros) after each line; boxes in shown-page coordinates"""
        text, boxes = [], []
        d = p.get_text("rawdict", flags=fitz.TEXT_PRESERVE_WHITESPACE | fitz.TEXT_PRESERVE_LIGATURES | fitz.TEXT_MEDIABOX_CLIP)
        for b in d.get("blocks", []):
            if b.get("type") != 0:
                continue
            for line in b.get("lines", []):
                n0 = len(text)
                for span in line.get("spans", []):
                    for ch in span.get("chars", []):
                        c = ch.get("c", "")
                        if not c:
                            continue
                        r = self.out_rect(p, ch["bbox"])
                        text.append(c)
                        boxes.append((r.x0, r.y0, r.x1, r.y1))
                if len(text) > n0:
                    text.append("\n")
                    boxes.append((0.0, 0.0, 0.0, 0.0))
        return "".join(text), boxes

    def text(self, n):
        p = self.page(n)
        text, boxes = self.chars(p)
        units, out_boxes = [], []
        for ch, box in zip(text, boxes):
            u = ch.encode("utf-16-le", "surrogatepass")
            units.append(u)
            for _ in range(len(u) // 2):
                out_boxes.append(box)
        data = b"".join(units) + b"".join(struct.pack("<4f", *b) for b in out_boxes)
        return "OK n=%d bytes=%d" % (len(out_boxes), len(data)), data

    def search_page(self, p, needle, flags="", regex=None):
        """hits on one page: a list of rectangle lists (one rectangle a line
        of the hit), shown-page coordinates"""
        text, boxes = self.chars(p)
        flat = text.replace("\n", " ")
        if regex is None:
            pat = re.escape(needle)
            pat = re.sub(r"\\ ", r"\\s+", pat)
            if "w" in flags:
                pat = r"(?<!\w)" + pat + r"(?!\w)"
            regex = re.compile(pat, 0 if "c" in flags else re.IGNORECASE)
        hits = []
        for m in regex.finditer(flat):
            rects, cur = [], None
            for i in range(m.start(), m.end()):
                b = boxes[i]
                if b[2] <= b[0]:
                    if cur is not None:
                        rects.append(cur)
                        cur = None
                    continue
                r = fitz.Rect(b)
                if cur is not None and abs(r.y0 - cur.y0) < 0.5 * max(1, cur.height) and r.x0 >= cur.x0 - 1:
                    cur |= r
                else:
                    if cur is not None:
                        rects.append(cur)
                    cur = r
            if cur is not None:
                rects.append(cur)
            if rects:
                hits.append(rects)
        return hits

    def find(self, needle, flags=""):
        self.need_doc()
        if not needle:
            raise Refusal("invalid", "nothing to find")
        out = []
        for i, p in enumerate(self.doc):
            boxes = []
            for rects in self.search_page(p, needle, flags):
                u = rects[0]
                for r in rects[1:]:
                    u = u | r if abs(r.y0 - u.y0) < 1 else u
                boxes.append((u.x0, u.y0, u.x1, u.y1))
            boxes.sort(key=lambda b: (round(b[1]), b[0]))
            out += ["%d %.3f %.3f %.3f %.3f" % ((i,) + b) for b in boxes]
        data = ("\n".join(out) + "\n").encode("utf-8") if out else b""
        return "OK n=%d bytes=%d" % (len(out), len(data)), data

    def links(self, n):
        p = self.page(n)
        out = []
        for l in p.get_links():
            box = fmt_rect(self.out_rect(p, l["from"]))
            kind = l.get("kind")
            if kind in (fitz.LINK_GOTO, fitz.LINK_NAMED) and l.get("page", -1) is not None and l.get("page", -1) >= 0:
                tgt = l["page"]
                if tgt >= self.doc.page_count:
                    continue
                to = l.get("to")
                top = 0.0
                if to is not None:
                    top = max(0.0, self.out_rect(self.doc[tgt], fitz.Rect(to, to)).y0)
                out.append("%s\tgoto\t%d\t%.3f" % (box, tgt, top))
            elif kind == fitz.LINK_URI and l.get("uri"):
                out.append("%s\turi\t%s" % (box, one_line(l["uri"])))
        data = ("\n".join(out) + "\n").encode("utf-8") if out else b""
        return "OK n=%d bytes=%d" % (len(out), len(data)), data

    def outline(self):
        self.need_doc()
        out = []
        for lvl, title, page, dest in self.doc.get_toc(simple=False)[:20000]:
            pg = page - 1 if page and 0 < page <= self.doc.page_count else -1
            top = 0.0
            to = dest.get("to") if isinstance(dest, dict) else None
            if pg >= 0 and to is not None:
                top = max(0.0, self.out_rect(self.doc[pg], fitz.Rect(to, to)).y0)
            opened = 0 if (isinstance(dest, dict) and dest.get("collapse")) else 1
            out.append("%d\t%d\t%.3f\t%d\t%s" % (min(lvl - 1, 32), pg, top, opened, one_line(title)))
        data = ("\n".join(out) + "\n").encode("utf-8") if out else b""
        return "OK n=%d bytes=%d" % (len(out), len(data)), data

    # ---- saving, undo -------------------------------------------------------------------------

    def save(self, path, *opts):
        self.need_doc()
        o = kv(opts)
        if not path or "\x00" in path:
            raise Refusal("invalid", "no file name")
        if o.get("apply") == "1":
            self.redact_apply_all()
        kw = dict(garbage=3, deflate=True, deflate_images=True, deflate_fonts=True, use_objstms=1)
        if self.security is None:
            kw["encryption"] = fitz.PDF_ENCRYPT_KEEP
        elif self.security[0] == "none":
            kw["encryption"] = fitz.PDF_ENCRYPT_NONE
        else:
            _, user, owner, perms = self.security
            kw.update(encryption=fitz.PDF_ENCRYPT_AES_256, user_pw=user or "", owner_pw=owner or user or "",
                      permissions=perms)
        d = os.path.dirname(os.path.abspath(path)) or "."
        try:
            fd, tmp = tempfile.mkstemp(prefix=".sgpdf-", suffix=".pdf", dir=d)
        except OSError as e:
            raise Refusal("failed", "could not save: " + one_line(e.strerror or str(e)))
        os.close(fd)
        try:
            self.doc.save(tmp, **kw)
            try:
                if os.path.exists(path):
                    os.chmod(tmp, os.stat(path).st_mode & 0o7777)
                else:
                    os.chmod(tmp, 0o644 & ~_umask())
            except OSError:
                pass
            os.replace(tmp, path)
        except Exception as e:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise Refusal("failed", "could not save: " + one_line(str(e)))
        # the saved file is the document from now on (new passwords included;
        # and a garbage-collecting save renumbers objects under MuPDF's caches)
        if self.security is not None:
            if self.security[0] == "none":
                self.encrypted, self.password = False, None
            else:
                self.encrypted, self.password = True, self.security[2] or self.security[1]
            self.security = None
        with open(path, "rb") as f:
            self.reopen(f.read())
        self.path = path
        self.dirty = False
        return self.state()

    def undo_(self):
        self.need_doc()
        if not self.undo:
            raise Refusal("invalid", "nothing to undo")
        self.redo.append(self.doc.tobytes(encryption=fitz.PDF_ENCRYPT_KEEP))
        self.reopen(self.undo.pop())
        self.dirty = True
        return self.state()

    def redo_(self):
        self.need_doc()
        if not self.redo:
            raise Refusal("invalid", "nothing to redo")
        self.undo.append(self.doc.tobytes(encryption=fitz.PDF_ENCRYPT_KEEP))
        self.reopen(self.redo.pop())
        self.dirty = True
        return self.state()

    def properties(self, *opts):
        """document properties: title, author, subject, keywords"""
        o = kv(opts)
        self.begin()
        md = dict(self.doc.metadata or {})
        for k in ("title", "author", "subject", "keywords"):
            if k in o:
                md[k] = o[k]
        self.doc.set_metadata({k: v for k, v in md.items() if k in
                               ("title", "author", "subject", "keywords", "creator", "producer",
                                "creationDate", "modDate", "trapped")})
        self.changed()
        return self.state()

    # ---- private redactions (edits that must not apply the user's marks) ---------------------

    def _marks(self, page):
        saved = []
        for a in list(page.annots(types=[fitz.PDF_ANNOT_REDACT])):
            saved.append((fitz.Rect(a.rect), a.info.get("title", ""), a.info.get("content", ""),
                          [fitz.Quad(q) for q in _quads(a)]))
            page.delete_annot(a)
        return saved

    def _restore_marks(self, page, saved):
        for rect, title, content, quads in saved:
            for q in (quads or [rect.quad]):
                a = page.add_redact_annot(q, fill=(0, 0, 0))
                a.set_info(title=title, content=content)
                a.update()

    def _private_redact(self, page, rects, images=fitz.PDF_REDACT_IMAGE_NONE,
                        graphics=fitz.PDF_REDACT_LINE_ART_NONE, text=fitz.PDF_REDACT_TEXT_NONE):
        saved = self._marks(page)
        for r in rects:
            page.add_redact_annot(r, fill=False, cross_out=False)
        page.apply_redactions(images=images, graphics=graphics, text=text)
        self._restore_marks(page, saved)

    def content_drawings(self, page):
        """the page's own paths -- get_drawings() also reports what its
        annotations draw (a note's icon, a redaction mark's outline)"""
        if not page.first_annot and not page.first_widget:
            return page.get_drawings()
        tmp = fitz.open()
        tmp.insert_pdf(self.doc, from_page=page.number, to_page=page.number, annots=False, links=False)
        return tmp[0].get_drawings()

    def _set_contents(self, page, data):
        xrefs = page.get_contents()
        if not xrefs:
            return
        self.doc.update_stream(xrefs[0], data)
        if len(xrefs) > 1:
            self.doc.xref_set_key(page.xref, "Contents", "%d 0 R" % xrefs[0])

    # ---- Edit PDF: the page's objects -----------------------------------------------------------

    def _objects(self, pno):
        if pno in self.objcache:
            return self.objcache[pno]
        p = self.doc[pno]
        objs = []
        d = p.get_text("dict", flags=fitz.TEXTFLAGS_DICT & ~fitz.TEXT_PRESERVE_IMAGES)
        for b in d.get("blocks", []):
            if b.get("type") != 0:
                continue
            lines = [ln for ln in b.get("lines", []) if any(s.get("text", "").strip() for s in ln.get("spans", []))]
            if not lines:
                continue
            spans = [s for ln in lines for s in ln["spans"] if s.get("text")]
            dom = max(spans, key=lambda s: len(s["text"].strip()))
            bb = fitz.Rect(b["bbox"])
            width = max(1.0, bb.width)
            parts = []
            for i, ln in enumerate(lines):
                t = "".join(s["text"] for s in ln["spans"])
                parts.append(t.rstrip() if i + 1 < len(lines) else t.strip())
                if i + 1 < len(lines):
                    lx1 = ln["bbox"][2]
                    if lx1 - bb.x0 < 0.7 * width:
                        parts.append("\n")
                    elif not t.rstrip().endswith("-"):
                        parts.append(" ")
            text = "".join(parts).strip()
            pitch = 0.0
            if len(lines) > 1:
                pitch = (lines[-1]["bbox"][1] - lines[0]["bbox"][1]) / (len(lines) - 1)
            size = dom.get("size", 11) or 11
            lh = pitch / size if pitch > 0.5 * size else 0
            lefts = [ln["bbox"][0] for ln in lines]
            rights = [ln["bbox"][2] for ln in lines]
            align = 0
            if len(lines) > 1:
                if max(lefts) - min(lefts) > 2 and max(rights) - min(rights) <= 2:
                    align = 2
                elif max(lefts) - min(lefts) > 2 and abs((max(lefts) - min(lefts)) - (max(rights) - min(rights))) < 4:
                    centres = [(a + b) / 2 for a, b in zip(lefts, rights)]
                    if max(centres) - min(centres) <= 2:
                        align = 1
            objs.append({"kind": "text", "bbox": bb, "lines": [fitz.Rect(ln["bbox"]) for ln in lines],
                         "font": dom.get("font", ""), "size": size, "color": dom.get("color", 0),
                         "flags": dom.get("flags", 0), "align": align, "lh": lh, "text": text})
        for info in p.get_image_info(xrefs=True):
            bb = fitz.Rect(info["bbox"])
            if bb.is_empty or bb.is_infinite:
                continue
            objs.append({"kind": "image", "bbox": bb, "xref": info.get("xref", 0), "number": info.get("number", 0),
                         "info": info})
        drawings = self.content_drawings(p)
        for dr in drawings[:MAX_OBJECTS]:
            bb = fitz.Rect(dr["rect"])
            if bb.is_infinite or (bb.width > p.rect.width * 2):
                continue
            objs.append({"kind": "path", "bbox": bb, "drawing": dr})
        self.objcache[pno] = objs
        return objs

    def objects(self, n):
        p = self.page(n)
        out = []
        for i, o in enumerate(self._objects(p.number)):
            r = fmt_rect(self.out_rect(p, o["bbox"]))
            if o["kind"] == "text":
                bold, italic = style_of(o["font"], o["flags"])
                fam = family_of(o["font"])
                out.append("text\t%d\t%s\t%s\t%.2f\t%s\t%d\t%d\t%.3f\t%s" % (
                    i, r, esc(fam), o["size"], hexcolor(o["color"]), (1 if bold else 0) | (2 if italic else 0),
                    o["align"], o["lh"], esc(o["text"])))
            elif o["kind"] == "image":
                out.append("image\t%d\t%s\t%d" % (i, r, o["xref"]))
            else:
                out.append("path\t%d\t%s\t-" % (i, r))
        data = ("\n".join(out) + "\n").encode("utf-8") if out else b""
        return "OK n=%d bytes=%d" % (len(out), len(data)), data

    def _obj(self, p, oid):
        objs = self._objects(p.number)
        try:
            i = int(oid)
        except ValueError:
            raise Refusal("invalid", "not an object")
        if not 0 <= i < len(objs):
            raise Refusal("range", "no such object")
        return objs[i]

    # choosing the font new text is set in

    def _font_for(self, p, fontname, bold, italic, text):
        """(fitz.Font, name used). The document's own font when it is
        embedded whole and has every character; else the installed family
        fontconfig matches (metric-compatible substitutes first)."""
        clean = fontname or ""
        if clean and not re.match(r"^[A-Z]{6}\+", clean):
            for f in p.get_fonts(full=True):
                base = f[3] or ""
                if base == clean or base.split("+")[-1] == clean:
                    if re.match(r"^[A-Z]{6}\+", base):
                        break           # a subset: its missing glyphs would vanish
                    key = ("doc", id(self.doc), f[0])
                    if key not in _FONT_CACHE:
                        try:
                            _, ext, _, buf = self.doc.extract_font(f[0])
                            _FONT_CACHE[key] = (fitz.Font(fontbuffer=buf), base) if buf and ext in ("ttf", "otf", "cff") else None
                        except Exception:
                            _FONT_CACHE[key] = None
                    if _FONT_CACHE[key] and covers(_FONT_CACHE[key][0], text):
                        return _FONT_CACHE[key]
                    break
        fam = family_of(fontname)
        low = (fontname or "").lower()
        serif = any(k in low for k in ("times", "serif", "roman", "georgia", "cambria", "garamond", "tiro", "book"))
        mono = any(k in low for k in ("courier", "mono", "consol", "cour"))
        font = system_font(fam, bold, italic, serif, mono)
        if covers(font[0], text):
            return font
        for alt in ("DejaVu Sans", "Noto Sans CJK SC", "Symbola"):
            f2 = system_font(alt, bold, italic)
            if covers(f2[0], text):
                return f2
        return font

    def _set_text(self, p, rect_ui, text, fontname, size, color, bold, italic, align, lh):
        """text set in rect_ui (shown-page coordinates), reflowed within its
        width, the rectangle growing down when the text needs it; returns
        the rectangle used (shown-page coordinates)"""
        size = max(1.0, min(float(size), 500.0))
        font, used = self._font_for(p, fontname, bold, italic, text)
        lh = lh if lh and lh > 0.5 else None
        rect = fitz.Rect(rect_ui)
        if rect.width < size:
            rect.x1 = rect.x0 + max(size * 4, font.text_length(text.split("\n")[0], size) + 2)
        # how tall the text is, set in this width
        probe = fitz.TextWriter(p.rect)
        tall = fitz.Rect(rect.x0, rect.y0, rect.x1, rect.y0 + 1e5 / 2)
        probe.fill_textbox(tall, text, font=font, fontsize=size, lineheight=lh, align=align)
        need = probe.text_rect.y1 - rect.y0 + size * 0.35 if text.strip() else size
        if rect.height < need:
            rect.y1 = rect.y0 + need
        tw = fitz.TextWriter(p.rect, color=color)
        tw.fill_textbox(rect, text, font=font, fontsize=size, lineheight=lh, align=align)
        write_upright(tw, p)
        return rect, used

    def _remove_text_obj(self, p, o):
        rects = []
        for lr in o["lines"]:
            h = lr.height
            rects.append(fitz.Rect(lr.x0 - 0.5, lr.y0 + h * 0.2, lr.x1 + 0.5, lr.y1 - h * 0.2))
        self._private_redact(p, rects, text=fitz.PDF_REDACT_TEXT_REMOVE)

    def _remove_image_obj(self, p, o):
        """cut the one "Do" that draws this image; True when done exactly"""
        xref = o["xref"]
        if xref:
            refs = [img for img in p.get_images(full=True) if img[0] == xref]
            if len(refs) == 1 and refs[0][9] == 0:
                name = refs[0][7].encode("latin-1")
                infos = [i for i in p.get_image_info(xrefs=True) if i.get("xref") == xref]
                k = next((j for j, i in enumerate(infos) if i.get("number") == o["number"]), None)
                content = p.read_contents()
                if k is not None and count_do(content, name) == len(infos):
                    new = remove_do(content, name, k)
                    if new is not None:
                        self._set_contents(p, new)
                        return True
        # an inline image, or one drawn from inside a form: redact its area's images
        bb = fitz.Rect(o["bbox"])
        inner = fitz.Rect(bb.x0 + bb.width * 0.25, bb.y0 + bb.height * 0.25, bb.x1 - bb.width * 0.25, bb.y1 - bb.height * 0.25)
        self._private_redact(p, [inner], images=fitz.PDF_REDACT_IMAGE_REMOVE)
        return False

    def _remove_path_obj(self, p, o):
        before = self.content_drawings(p)
        target = drawing_key(o["drawing"])
        bb = fitz.Rect(o["bbox"])
        area = fitz.Rect(bb.x0 - 0.5, bb.y0 - 0.5, bb.x1 + 0.5, bb.y1 + 0.5)
        # MuPDF's "covered" misses stroked paths; every path touching the
        # area goes, and the others are drawn again below
        self._private_redact(p, [area], graphics=fitz.PDF_REDACT_LINE_ART_REMOVE_IF_TOUCHED)
        after = {}
        for d in self.content_drawings(p):
            after[drawing_key(d)] = after.get(drawing_key(d), 0) + 1
        again, skipped = [], False
        for d in before:
            k = drawing_key(d)
            if after.get(k):
                after[k] -= 1
                continue
            if k == target and not skipped:
                skipped = True
                continue
            again.append(d)
        draw_paths(p, again)

    def edittext(self, n, oid, rect, text, *style):
        p = self.page(n)
        o = self._obj(p, oid)
        if o["kind"] != "text":
            raise Refusal("invalid", "not a text block")
        st = kv(style)
        self.begin()
        text = unesc(text)
        bold, italic = style_of(o["font"], o["flags"])
        fontname = st.get("font") or o["font"]
        if "font" in st:
            bold = italic = False
        if "bold" in st:
            bold = st["bold"] == "1"
        if "italic" in st:
            italic = st["italic"] == "1"
        size = float(st.get("size") or o["size"])
        color = rgb(st.get("color")) if st.get("color") else rgb(hexcolor(o["color"]))
        align = int(st.get("align", o["align"]))
        r = fitz.Rect(floats(rect, 4)) if rect and rect != "-" else self.out_rect(p, o["bbox"])
        self._remove_text_obj(p, o)
        used = "-"
        if text.strip():
            _, used = self._set_text(p, r, text, fontname, size, color, bold, italic, align, o["lh"])
        self.changed()
        return self.state("font=" + esc(used).replace(" ", "_"))

    def addtext(self, n, rect, text, *style):
        p = self.page(n)
        st = kv(style)
        text = unesc(text)
        if not text.strip():
            raise Refusal("invalid", "no text")
        self.begin()
        r = fitz.Rect(floats(rect, 4))
        _, used = self._set_text(p, r, text, st.get("font") or "Helvetica", float(st.get("size") or 12),
                                 rgb(st.get("color")), st.get("bold") == "1", st.get("italic") == "1",
                                 int(st.get("align") or 0), 0)
        self.changed()
        return self.state("font=" + esc(used).replace(" ", "_"))

    def _image_rotate(self, p):
        return (-p.rotation) % 360

    def addimage(self, n, rect, path):
        p = self.page(n)
        path = unesc(path)
        try:
            fitz.Pixmap(path)
        except Exception:
            raise Refusal("invalid", "that file is not a picture this program can read")
        self.begin()
        r = self.ui_rect(p, floats(rect, 4))
        p.insert_image(r, filename=path, keep_proportion=True, rotate=self._image_rotate(p))
        self.changed()
        return self.state()

    def moveobj(self, n, oid, rect):
        p = self.page(n)
        o = self._obj(p, oid)
        nr = fitz.Rect(floats(rect, 4))
        if nr.is_empty:
            raise Refusal("invalid", "empty rectangle")
        if o["kind"] == "text":
            bold, italic = style_of(o["font"], o["flags"])
            self.begin()
            self._remove_text_obj(p, o)
            self._set_text(p, nr, o["text"], o["font"], o["size"], rgb(hexcolor(o["color"])), bold, italic,
                           o["align"], o["lh"])
        elif o["kind"] == "image":
            if not o["xref"]:
                raise Refusal("invalid", "this picture is part of the page's drawing and cannot be moved; delete it and add it again")
            self.begin()
            self._remove_image_obj(p, o)
            p.insert_image(self.ui_rect(p, nr), xref=o["xref"], keep_proportion=False, rotate=self._image_rotate(p))
        else:
            self.begin()
            old = fitz.Rect(o["bbox"])
            new = self.ui_rect(p, nr)
            sx = new.width / old.width if old.width > 0.01 else 1.0
            sy = new.height / old.height if old.height > 0.01 else 1.0
            m = fitz.Matrix(sx, 0, 0, sy, new.x0 - old.x0 * sx, new.y0 - old.y0 * sy)
            d = dict(o["drawing"])
            items = []
            for it in d.get("items", []):
                if it[0] == "l":
                    items.append(("l", fitz.Point(it[1]) * m, fitz.Point(it[2]) * m))
                elif it[0] == "c":
                    items.append(("c",) + tuple(fitz.Point(q) * m for q in it[1:5]))
                elif it[0] == "re":
                    items.append(("re", fitz.Rect(it[1]) * m, it[2] if len(it) > 2 else 1))
                elif it[0] == "qu":
                    items.append(("qu", fitz.Quad(it[1]) * m))
            d["items"] = items
            self._remove_path_obj(p, o)
            draw_paths(p, [d])
        self.changed()
        return self.state()

    def delobj(self, n, oid):
        p = self.page(n)
        o = self._obj(p, oid)
        self.begin()
        if o["kind"] == "text":
            self._remove_text_obj(p, o)
        elif o["kind"] == "image":
            self._remove_image_obj(p, o)
        else:
            self._remove_path_obj(p, o)
        self.changed()
        return self.state()

    def replaceimage(self, n, oid, path):
        p = self.page(n)
        o = self._obj(p, oid)
        path = unesc(path)
        if o["kind"] != "image":
            raise Refusal("invalid", "not a picture")
        try:
            fitz.Pixmap(path)
        except Exception:
            raise Refusal("invalid", "that file is not a picture this program can read")
        self.begin()
        self._remove_image_obj(p, o)
        p.insert_image(fitz.Rect(o["bbox"]), filename=path, keep_proportion=True, rotate=self._image_rotate(p))
        self.changed()
        return self.state()

    # ---- Comment ------------------------------------------------------------------------------

    def annot(self, n, kind, *opts):
        p = self.page(n)
        o = kv(opts)
        self.begin(fitz.PDF_PERM_ANNOTATE)
        color = rgb(o.get("color"), (1, 0.85, 0) if kind == "highlight" else (0.85, 0.1, 0.1))
        text = o.get("text", "")
        a = None
        if kind in ("highlight", "underline", "strikeout", "squiggly"):
            rects = [self.ui_rect(p, floats(r, 4)) for r in o.get("rects", "").split(";") if r.strip()]
            if not rects:
                raise Refusal("invalid", "no text marked")
            quads = [r.quad for r in rects]
            a = {"highlight": p.add_highlight_annot, "underline": p.add_underline_annot,
                 "strikeout": p.add_strikeout_annot, "squiggly": p.add_squiggly_annot}[kind](quads=quads)
        elif kind == "note":
            pt = self.ui_point(p, floats(o.get("point", ""), 2))
            a = p.add_text_annot(pt, text, icon="Comment")
        elif kind == "freetext":
            r = self.ui_rect(p, floats(o.get("rect", ""), 4))
            a = p.add_freetext_annot(r, text, fontsize=float(o.get("fontsize") or 12), fontname="helv",
                                     text_color=color, fill_color=rgb(o["fill"]) if o.get("fill") else None,
                                     border_color=None, rotate=p.rotation)
        elif kind in ("rect", "ellipse"):
            r = self.ui_rect(p, floats(o.get("rect", ""), 4))
            a = p.add_rect_annot(r) if kind == "rect" else p.add_circle_annot(r)
        elif kind in ("line", "arrow"):
            v = floats(o.get("line", ""), 4)
            a = p.add_line_annot(self.ui_point(p, v[:2]), self.ui_point(p, v[2:]))
            if kind == "arrow":
                a.set_line_ends(fitz.PDF_ANNOT_LE_NONE, fitz.PDF_ANNOT_LE_OPEN_ARROW)
        elif kind == "ink":
            strokes = []
            for s in o.get("ink", "").split(";"):
                v = floats(s)
                pts = [tuple(self.ui_point(p, (v[i], v[i + 1]))) for i in range(0, len(v) - 1, 2)]
                if len(pts) >= 2:
                    strokes.append(pts)
            if not strokes:
                raise Refusal("invalid", "no strokes")
            a = p.add_ink_annot(strokes)
        else:
            raise Refusal("invalid", "unknown comment kind")
        if kind not in ("freetext",):
            if kind in ("rect", "ellipse") and o.get("fill"):
                a.set_colors(stroke=color, fill=rgb(o["fill"]))
            else:
                a.set_colors(stroke=color)
        if kind in ("rect", "ellipse", "line", "arrow", "ink"):
            a.set_border(width=float(o.get("width") or 2))
        if o.get("opacity"):
            a.set_opacity(max(0.05, min(1.0, float(o["opacity"]))))
        a.set_info(title=o.get("author") or self.author, content=text)
        a.update()
        xref = a.xref
        self.changed()
        return self.state("xref=%d" % xref)

    def _annot_line(self, p, a):
        t = a.type[1]
        return "%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s" % (
            p.number, a.xref, t, fmt_rect(self.out_rect(p, a.rect)), hexcolor((a.colors or {}).get("stroke")),
            esc(a.info.get("title", "")), esc(a.info.get("content", "")), esc(a.info.get("modDate", "")))

    def annots(self, n=None):
        self.need_doc()
        pages = [self.page(n)] if n not in (None, "", "all") else list(self.doc)
        out = []
        for p in pages:
            for a in p.annots():
                if a.type[0] in (fitz.PDF_ANNOT_POPUP, fitz.PDF_ANNOT_LINK, fitz.PDF_ANNOT_WIDGET):
                    continue
                out.append(self._annot_line(p, a))
        data = ("\n".join(out) + "\n").encode("utf-8") if out else b""
        return "OK n=%d bytes=%d" % (len(out), len(data)), data

    def _load_annot(self, p, xref):
        try:
            x = int(xref)
        except ValueError:
            raise Refusal("invalid", "not an annotation")
        for a in p.annots():
            if a.xref == x:
                return a
        raise Refusal("range", "no such annotation")

    def delannot(self, n, xref):
        p = self.page(n)
        a = self._load_annot(p, xref)
        self.begin(fitz.PDF_PERM_ANNOTATE)
        p.delete_annot(a)
        self.changed()
        return self.state()

    def moveannot(self, n, xref, rect):
        p = self.page(n)
        a = self._load_annot(p, xref)
        nr = self.ui_rect(p, floats(rect, 4))
        old = fitz.Rect(a.rect)
        self.begin(fitz.PDF_PERM_ANNOTATE)
        t = a.type[0]
        if t in (fitz.PDF_ANNOT_TEXT, fitz.PDF_ANNOT_FREE_TEXT, fitz.PDF_ANNOT_SQUARE, fitz.PDF_ANNOT_CIRCLE,
                 fitz.PDF_ANNOT_STAMP, fitz.PDF_ANNOT_REDACT, fitz.PDF_ANNOT_FILE_ATTACHMENT):
            if t == fitz.PDF_ANNOT_REDACT:
                info = a.info
                p.delete_annot(a)
                na = p.add_redact_annot(nr, fill=(0, 0, 0))
                na.set_info(title=info.get("title", ""), content=info.get("content", ""))
                na.update()
            else:
                if t == fitz.PDF_ANNOT_TEXT:
                    nr = fitz.Rect(nr.x0, nr.y0, nr.x0 + old.width, nr.y0 + old.height)
                a.set_rect(nr)
                a.update()
        else:
            dx, dy = nr.x0 - old.x0, nr.y0 - old.y0
            self._recreate_moved(p, a, dx, dy)
        self.changed()
        return self.state()

    def _recreate_moved(self, p, a, dx, dy):
        t = a.type[0]
        colors = a.colors or {}
        info = a.info
        opacity = a.opacity
        border = (a.border or {}).get("width")
        m = fitz.Matrix(1, 0, 0, 1, dx, dy)
        verts = a.vertices or []
        if t in (fitz.PDF_ANNOT_HIGHLIGHT, fitz.PDF_ANNOT_UNDERLINE, fitz.PDF_ANNOT_STRIKE_OUT, fitz.PDF_ANNOT_SQUIGGLY):
            quads = [fitz.Quad(*[fitz.Point(v) * m for v in verts[i:i + 4]]) for i in range(0, len(verts) - 3, 4)]
            add = {fitz.PDF_ANNOT_HIGHLIGHT: p.add_highlight_annot, fitz.PDF_ANNOT_UNDERLINE: p.add_underline_annot,
                   fitz.PDF_ANNOT_STRIKE_OUT: p.add_strikeout_annot, fitz.PDF_ANNOT_SQUIGGLY: p.add_squiggly_annot}[t]
            p.delete_annot(a)
            na = add(quads=quads)
        elif t == fitz.PDF_ANNOT_INK:
            strokes = [[tuple(fitz.Point(v) * m) for v in s] for s in verts]
            p.delete_annot(a)
            na = p.add_ink_annot(strokes)
        elif t == fitz.PDF_ANNOT_LINE:
            ends = a.line_ends
            p.delete_annot(a)
            na = p.add_line_annot(fitz.Point(verts[0]) * m, fitz.Point(verts[1]) * m)
            if ends:
                na.set_line_ends(*ends)
        else:
            raise Refusal("invalid", "this comment cannot be moved")
        na.set_colors(stroke=colors.get("stroke"), fill=colors.get("fill"))
        if border:
            na.set_border(width=border)
        if opacity is not None and opacity >= 0:
            na.set_opacity(opacity)
        na.set_info(title=info.get("title", ""), content=info.get("content", ""))
        na.update()

    def setannot(self, n, xref, *opts):
        p = self.page(n)
        a = self._load_annot(p, xref)
        o = kv(opts)
        self.begin(fitz.PDF_PERM_ANNOTATE)
        if "text" in o:
            a.set_info(content=o["text"])
        if "color" in o:
            if a.type[0] == fitz.PDF_ANNOT_FREE_TEXT:
                a.update(text_color=rgb(o["color"]))
            else:
                a.set_colors(stroke=rgb(o["color"]))
        a.update()
        self.changed()
        return self.state()

    # ---- forms and signatures ------------------------------------------------------------------

    def fields(self):
        self.need_doc()
        out = []
        for p in self.doc:
            for w in p.widgets():
                t = {fitz.PDF_WIDGET_TYPE_TEXT: "text", fitz.PDF_WIDGET_TYPE_CHECKBOX: "checkbox",
                     fitz.PDF_WIDGET_TYPE_RADIOBUTTON: "radio", fitz.PDF_WIDGET_TYPE_COMBOBOX: "combo",
                     fitz.PDF_WIDGET_TYPE_LISTBOX: "list", fitz.PDF_WIDGET_TYPE_BUTTON: "button",
                     fitz.PDF_WIDGET_TYPE_SIGNATURE: "signature"}.get(w.field_type, "other")
                val = w.field_value
                if t in ("checkbox", "radio"):
                    val = "1" if val not in (None, False, "Off", "", "0") else "0"
                elif isinstance(val, (list, tuple)):
                    val = "\n".join(str(v) for v in val)
                opts = w.choice_values or []
                opts = [o if isinstance(o, str) else (o[1] if len(o) > 1 else o[0]) for o in opts]
                out.append("%d\t%d\t%s\t%s\t%d\t%s\t%s\t%s\t%.2f" % (
                    p.number, w.xref, t, fmt_rect(self.out_rect(p, w.rect)), w.field_flags or 0,
                    esc(w.field_name or ""), esc(str(val if val is not None else "")),
                    esc("\n".join(opts)), w.text_fontsize or 0))
        data = ("\n".join(out) + "\n").encode("utf-8") if out else b""
        return "OK n=%d bytes=%d" % (len(out), len(data)), data

    def setfield(self, n, xref, value):
        p = self.page(n)
        value = unesc(value)
        try:
            x = int(xref)
        except ValueError:
            raise Refusal("invalid", "not a field")
        w = next((w for w in p.widgets() if w.xref == x), None)
        if w is None:
            raise Refusal("range", "no such field")
        if (w.field_flags or 0) & fitz.PDF_FIELD_IS_READ_ONLY:
            raise Refusal("invalid", "the field is read-only")
        self.begin(fitz.PDF_PERM_FORM)
        if w.field_type == fitz.PDF_WIDGET_TYPE_CHECKBOX:
            w.field_value = w.on_state() if value == "1" else "Off"
        elif w.field_type == fitz.PDF_WIDGET_TYPE_RADIOBUTTON:
            w.field_value = w.on_state() if value == "1" else "Off"
        else:
            w.field_value = value
        w.update()
        self.changed()
        return self.state()

    def flatten(self, *opts):
        o = kv(opts)
        self.begin()
        marks = {p.number: self._marks(p) for p in self.doc}
        self.doc.bake(annots=o.get("annots") == "1", widgets=o.get("forms", "1") == "1")
        for p in self.doc:
            self._restore_marks(p, marks.get(p.number, []))
        self.changed()
        return self.state()

    def signature(self, n, rect, kind, data):
        p = self.page(n)
        r = fitz.Rect(floats(rect, 4))
        if r.is_empty:
            raise Refusal("invalid", "empty rectangle")
        data = unesc(data)
        ink = (0.05, 0.1, 0.4)
        self.begin()
        if kind == "ink":
            shape = p.new_shape()
            any_stroke = False
            for s in data.split(";"):
                v = floats(s)
                pts = [self.ui_point(p, (r.x0 + v[i] * r.width, r.y0 + v[i + 1] * r.height)) for i in range(0, len(v) - 1, 2)]
                if len(pts) >= 2:
                    shape.draw_polyline(pts)
                    any_stroke = True
            if not any_stroke:
                self.undo.pop()
                raise Refusal("invalid", "no strokes")
            shape.finish(color=ink, width=max(0.8, r.height / 40), closePath=False, lineCap=1, lineJoin=1)
            shape.commit()
        elif kind == "text":
            if not data.strip():
                self.undo.pop()
                raise Refusal("invalid", "no name")
            font = None
            for q in ("Z003", "URW Chancery L", "DejaVu Serif:slant=italic"):
                path = fc_match(q)
                if path and ("z003" in path.lower() or "chancery" in path.lower() or "Italic" in path):
                    font = fitz.Font(fontfile=path)
                    break
            if font is None:
                font = fitz.Font("tiit")
            size = min(r.height * 0.8, r.width / max(1e-3, font.text_length(data, 1)) * 0.95)
            tw = fitz.TextWriter(p.rect, color=ink)
            base = r.y1 - (r.height - size) / 2 - size * 0.2
            tw.append((r.x0 + (r.width - font.text_length(data, size)) / 2, base), data, font=font, fontsize=size)
            write_upright(tw, p)
        elif kind == "image":
            try:
                fitz.Pixmap(data)
            except Exception:
                self.undo.pop()
                raise Refusal("invalid", "that file is not a picture this program can read")
            p.insert_image(self.ui_rect(p, r), filename=data, keep_proportion=True, rotate=self._image_rotate(p))
        else:
            self.undo.pop()
            raise Refusal("invalid", "unknown signature kind")
        self.changed()
        return self.state()

    # ---- Redact -------------------------------------------------------------------------------

    def redactmark(self, n, *opts):
        p = self.page(n)
        o = kv(opts)
        rects = [self.ui_rect(p, floats(r, 4)) for r in o.get("rects", "").split(";") if r.strip()]
        if not rects:
            raise Refusal("invalid", "nothing marked")
        self.begin()
        for r in rects:
            a = p.add_redact_annot(r, fill=(0, 0, 0))
            a.set_info(title=o.get("author") or self.author, content=o.get("text", ""))
            a.update()
        self.changed()
        return self.state("marked=%d" % len(rects))

    def _pattern(self, what, flags):
        if what.startswith("pattern:"):
            name = what[8:]
            if name not in PATTERNS:
                raise Refusal("invalid", "unknown pattern")
            return re.compile(PATTERNS[name])
        if not what:
            raise Refusal("invalid", "nothing to find")
        return None

    def redactfind(self, what, flags="", mark="0"):
        self.need_doc()
        what = unesc(what)
        regex = self._pattern(what, flags)
        hits = []
        for p in self.doc:
            for rects in self.search_page(p, what, flags, regex):
                hits.append((p, rects))
        if mark == "1" and hits:
            self.begin()
            for p, rects in hits:
                for r in rects:
                    a = p.add_redact_annot(self.ui_rect(p, r), fill=(0, 0, 0))
                    a.set_info(title=self.author, content="")
                    a.update()
            self.changed()
        if mark == "1":
            return self.state("marked=%d" % sum(len(r) for _, r in hits))
        out = ["%d %s" % (p.number, ";".join(fmt_rect(r) for r in rects)) for p, rects in hits]
        data = ("\n".join(out) + "\n").encode("utf-8") if out else b""
        return "OK n=%d bytes=%d" % (len(out), len(data)), data

    def redact_apply_page(self, p):
        """apply the page's redaction marks: (marks, drawings cut, removed)"""
        marks = [fitz.Rect(a.rect) for a in p.annots(types=[fitz.PDF_ANNOT_REDACT])]
        if not marks:
            return 0, 0, 0
        # what else is on the marks: comments, fields, links
        for a in list(p.annots()):
            if a.type[0] in (fitz.PDF_ANNOT_REDACT, fitz.PDF_ANNOT_POPUP):
                continue
            if any(fitz.Rect(a.rect).intersects(m) for m in marks):
                p.delete_annot(a)
        for w in list(p.widgets()):
            if any(fitz.Rect(w.rect).intersects(m) for m in marks):
                p.delete_widget(w)
        for link in p.get_links():
            if any(fitz.Rect(link["from"]).intersects(m) for m in marks):
                p.delete_link(link)
        before = self.content_drawings(p)
        p.apply_redactions(images=fitz.PDF_REDACT_IMAGE_PIXELS,
                           graphics=fitz.PDF_REDACT_LINE_ART_REMOVE_IF_TOUCHED,
                           text=fitz.PDF_REDACT_TEXT_REMOVE)
        after = {}
        for d in self.content_drawings(p):
            after[drawing_key(d)] = after.get(drawing_key(d), 0) + 1
        fills, strokes, cut, removed = [], [], 0, 0
        for d in before:
            k = drawing_key(d)
            if after.get(k):
                after[k] -= 1
                continue
            # the black boxes the redaction drew are new, not in `before`
            pieces = drawing_minus(d, marks)
            if pieces is None:
                removed += 1
                continue
            cut += 1
            for piece in pieces:
                (fills if piece["type"] == "f" else strokes).append(piece)
        # under everything, as they were under the page's text and the black
        # boxes: each commit goes first, so the rules go in before the fills
        # that end up beneath them
        draw_paths(p, strokes, overlay=False)
        draw_paths(p, fills, overlay=False)
        return len(marks), cut, removed

    def redact_apply_all(self):
        total = [0, 0, 0]
        for p in self.doc:
            r = self.redact_apply_page(p)
            total = [a + b for a, b in zip(total, r)]
        return total

    def redactapply(self, *opts):
        self.need_doc()
        if not any(True for p in self.doc for _ in p.annots(types=[fitz.PDF_ANNOT_REDACT])):
            raise Refusal("invalid", "there is nothing marked for redaction")
        self.begin()
        marks, cut, removed = self.redact_apply_all()
        self.changed()
        return self.state("applied=%d cut=%d removed=%d" % (marks, cut, removed))

    def sanitize(self, *opts):
        o = kv(opts)
        on = lambda k: o.get(k, "1") == "1"  # noqa: E731
        self.begin()
        marks = {p.number: self._marks(p) for p in self.doc}
        done = []
        if on("layers"):
            n = self._remove_hidden_layers()
            done.append("layers=%d" % n)
        if on("comments"):
            k = 0
            for p in self.doc:
                for a in list(p.annots()):
                    if a.type[0] not in (fitz.PDF_ANNOT_LINK, fitz.PDF_ANNOT_WIDGET, fitz.PDF_ANNOT_POPUP):
                        p.delete_annot(a)
                        k += 1
            done.append("comments=%d" % k)
        if on("forms"):
            self.doc.bake(annots=False, widgets=True)
            done.append("forms=1")
        if on("hidden_text"):
            done.append("hidden_text=%d" % self._remove_invisible_text())
        if on("bookmarks") and self.doc.get_toc():
            self.doc.set_toc([])
            done.append("bookmarks=1")
        self.doc.scrub(attached_files=on("attachments"), clean_pages=False, embedded_files=on("attachments"),
                       hidden_text=False, javascript=on("links"), metadata=on("metadata"),
                       redactions=False, redact_images=0, remove_links=on("links"), reset_fields=False,
                       reset_responses=on("comments"), thumbnails=on("thumbnails"), xml_metadata=on("metadata"))
        if on("links"):
            self._remove_actions()
        if on("attachments"):
            for p in self.doc:
                for a in list(p.annots(types=[fitz.PDF_ANNOT_FILE_ATTACHMENT])):
                    p.delete_annot(a)
        for p in self.doc:
            self._restore_marks(p, marks.get(p.number, []))
        self.changed()
        return self.state(" ".join(done) if done else "")

    def _remove_invisible_text(self):
        """invisible text (render mode 3) out of every page and form"""
        removed, seen = 0, set()
        for p in self.doc:
            data, k = remove_invisible_text(p.read_contents())
            if k:
                self._set_contents(p, data)
                removed += k
            for x in p.get_xobjects():
                xref = x[0]
                if xref in seen or self.doc.xref_get_key(xref, "Subtype")[1] != "/Form":
                    continue
                seen.add(xref)
                data, k = remove_invisible_text(self.doc.xref_stream(xref) or b"")
                if k:
                    self.doc.update_stream(xref, data)
                    removed += k
        return removed

    def _remove_actions(self):
        """document-level JavaScript and actions: OpenAction, AA, Names/JavaScript"""
        cat = self.doc.pdf_catalog()
        for key in ("OpenAction", "AA"):
            if self.doc.xref_get_key(cat, key)[0] != "null":
                self.doc.xref_set_key(cat, key, "null")
        t, v = self.doc.xref_get_key(cat, "Names/JavaScript")
        if t != "null":
            self.doc.xref_set_key(cat, "Names/JavaScript", "null")
        for p in self.doc:
            if self.doc.xref_get_key(p.xref, "AA")[0] != "null":
                self.doc.xref_set_key(p.xref, "AA", "null")

    def _remove_hidden_layers(self):
        """content of layers (optional content groups) that are off: cut from
        the pages and forms, their annotations deleted; then the layers go"""
        try:
            ocgs = self.doc.get_ocgs()
        except Exception:
            ocgs = {}
        hidden = {x for x, v in (ocgs or {}).items() if not v.get("on", True)}
        removed = 0
        if hidden:
            for p in self.doc:
                props, xobjs = set(), set()
                for key in ("Properties", "XObject"):
                    t, v = self.doc.xref_get_key(p.xref, "Resources/" + key)
                    if t == "null":
                        continue
                    for m in re.finditer(r"/([^\s/<>\[\]()]+)\s+(\d+)\s+0\s+R", v):
                        x = int(m.group(2))
                        if key == "Properties" and x in hidden:
                            props.add(m.group(1).encode("latin-1"))
                        if key == "XObject":
                            t2, oc = self.doc.xref_get_key(x, "OC")
                            if t2 == "xref" and int(oc.split()[0]) in hidden:
                                xobjs.add(m.group(1).encode("latin-1"))
                if props or xobjs:
                    data, k = remove_marked(p.read_contents(), props, xobjs)
                    if k:
                        self._set_contents(p, data)
                        removed += k
                for a in list(p.annots()):
                    t, oc = self.doc.xref_get_key(a.xref, "OC")
                    if t == "xref" and int(oc.split()[0]) in hidden:
                        p.delete_annot(a)
                        removed += 1
        cat = self.doc.pdf_catalog()
        if self.doc.xref_get_key(cat, "OCProperties")[0] != "null":
            if hidden or ocgs:
                self.doc.xref_set_key(cat, "OCProperties", "null")
        return removed

    # ---- Organize pages ------------------------------------------------------------------------

    def rotate(self, pages, deg):
        self.need_doc()
        sel = parse_pages(pages, self.doc.page_count)
        try:
            deg = int(deg)
        except ValueError:
            raise Refusal("invalid", "not an angle")
        if deg % 90:
            raise Refusal("invalid", "not a quarter turn")
        self.begin(fitz.PDF_PERM_ASSEMBLE)
        for i in sel:
            p = self.doc[i]
            p.set_rotation((p.rotation + deg) % 360)
        self.changed()
        return self.state()

    def delete(self, pages):
        self.need_doc()
        sel = parse_pages(pages, self.doc.page_count)
        if len(sel) >= self.doc.page_count:
            raise Refusal("invalid", "a document keeps at least one page")
        self.begin(fitz.PDF_PERM_ASSEMBLE)
        self.doc.delete_pages(sel)
        self.changed()
        return self.state()

    def move(self, pages, to):
        self.need_doc()
        n = self.doc.page_count
        sel = parse_pages(pages, n)
        to = int(to)
        if not 0 <= to <= n:
            raise Refusal("range", "no such place")
        rest = [i for i in range(n) if i not in sel]
        before = sum(1 for i in rest if i < to)
        order = rest[:before] + sel + rest[before:]
        if order == list(range(n)):
            return self.state()
        self.begin(fitz.PDF_PERM_ASSEMBLE)
        self.doc.select(order)
        self.changed()
        return self.state()

    def insertblank(self, at, w="", h=""):
        self.need_doc()
        at = int(at)
        if not 0 <= at <= self.doc.page_count:
            raise Refusal("range", "no such place")
        ref = self.doc[min(at, self.doc.page_count - 1)].rect if self.doc.page_count else fitz.paper_rect("letter")
        w = float(w) if w else ref.width
        h = float(h) if h else ref.height
        self.begin(fitz.PDF_PERM_ASSEMBLE)
        self.doc.new_page(pno=at if at < self.doc.page_count else -1, width=w, height=h)
        self.changed()
        return self.state()

    def _open_other(self, path, pw=""):
        try:
            src = fitz.open(path)
        except Exception as e:
            raise Refusal("open", one_line(str(e)))
        if not src.is_pdf:
            # a picture: a page of its own
            try:
                pdfbytes = src.convert_to_pdf()
                src = fitz.open("pdf", pdfbytes)
            except Exception:
                raise Refusal("open", "not a PDF or a picture")
        if src.needs_pass and not src.authenticate(pw or ""):
            raise Refusal("password", "the other document needs a password")
        return src

    def insertfile(self, at, path, pw=""):
        self.need_doc()
        at = int(at)
        if not 0 <= at <= self.doc.page_count:
            raise Refusal("range", "no such place")
        src = self._open_other(unesc(path), unesc(pw))
        self.begin(fitz.PDF_PERM_ASSEMBLE)
        self.doc.insert_pdf(src, start_at=at if at < self.doc.page_count else -1)
        self.changed()
        return self.state("inserted=%d" % src.page_count)

    def _write_new(self, doc, path):
        d = os.path.dirname(os.path.abspath(path)) or "."
        try:
            fd, tmp = tempfile.mkstemp(prefix=".sgpdf-", suffix=".pdf", dir=d)
        except OSError as e:
            raise Refusal("failed", "could not save: " + one_line(e.strerror or str(e)))
        os.close(fd)
        try:
            doc.save(tmp, garbage=3, deflate=True, use_objstms=1)
            os.chmod(tmp, 0o644 & ~_umask())
            os.replace(tmp, path)
        except Exception as e:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise Refusal("failed", "could not save: " + one_line(str(e)))

    def extract(self, pages, path, delete="0"):
        self.need_doc()
        if not self.allowed(fitz.PDF_PERM_COPY) and not self.allowed(fitz.PDF_PERM_ASSEMBLE):
            raise Refusal("secured", "the document's security does not allow this")
        sel = parse_pages(pages, self.doc.page_count)
        new = fitz.open()
        for i in sel:
            new.insert_pdf(self.doc, from_page=i, to_page=i)
        self._write_new(new, unesc(path))
        if delete == "1":
            if len(sel) >= self.doc.page_count:
                raise Refusal("invalid", "a document keeps at least one page")
            self.begin(fitz.PDF_PERM_ASSEMBLE)
            self.doc.delete_pages(sel)
            self.changed()
        return self.state("extracted=%d" % len(sel))

    def split(self, every, folder, base):
        self.need_doc()
        try:
            every = int(every)
        except ValueError:
            raise Refusal("invalid", "not a number")
        if every < 1:
            raise Refusal("invalid", "not a number")
        folder, base = unesc(folder), unesc(base)
        if not os.path.isdir(folder):
            raise Refusal("invalid", "no such folder")
        names = []
        n = self.doc.page_count
        for k, start in enumerate(range(0, n, every), 1):
            new = fitz.open()
            new.insert_pdf(self.doc, from_page=start, to_page=min(n, start + every) - 1)
            name = os.path.join(folder, "%s_Part%d.pdf" % (base, k))
            self._write_new(new, name)
            names.append(name)
        data = ("\n".join(names) + "\n").encode("utf-8")
        return "OK n=%d bytes=%d" % (len(names), len(data)), data

    def combine(self, out, *paths):
        new = fitz.open()
        if not paths:
            raise Refusal("invalid", "no files")
        for pth in paths:
            src = self._open_other(unesc(pth))
            new.insert_pdf(src)
        self._write_new(new, unesc(out))
        return "OK pages=%d" % new.page_count, b""

    # ---- Protect --------------------------------------------------------------------------------

    def protect(self, *opts):
        self.need_doc()
        o = kv(opts)
        if self.perms != PERM_ALL:
            raise Refusal("secured", "enter the permissions password to change the document's security")
        mode = o.get("mode", "")
        if mode == "none":
            self.security = ("none",)
        elif mode == "aes256":
            user, owner = o.get("user", ""), o.get("owner", "")
            if not user and not owner:
                raise Refusal("invalid", "no password")
            perms = 0
            for name in (o.get("perms") or "").split(","):
                if name.strip():
                    if name.strip() not in PERM_NAMES:
                        raise Refusal("invalid", "unknown permission " + name)
                    perms |= PERM_NAMES[name.strip()]
            if not owner:
                perms = sum(PERM_NAMES.values())
            self.security = ("aes256", user, owner or user, perms)
        else:
            raise Refusal("invalid", "unknown mode")
        self.dirty = True
        return self.state()

    def unlock(self, password):
        """the permissions (owner) password: every right"""
        self.need_doc()
        with open(self.path, "rb") as f:
            test = fitz.open("pdf", f.read())
        if not (test.authenticate(unesc(password)) & 4):
            raise Refusal("password", "that is not the permissions password")
        self.perms = PERM_ALL
        return self.state()

    # ---- Export ---------------------------------------------------------------------------------

    def export(self, kind, path, *opts):
        self.need_doc()
        o = kv(opts)
        path = unesc(path)
        if not self.allowed(fitz.PDF_PERM_COPY):
            raise Refusal("secured", "the document's security does not allow copying its content")
        pages = parse_pages(o["pages"], self.doc.page_count) if o.get("pages") else list(range(self.doc.page_count))
        files = []
        if kind in ("png", "jpeg"):
            dpi = max(36, min(600, int(float(o.get("dpi") or 150))))
            root, ext = os.path.splitext(path)
            ext = ext or (".png" if kind == "png" else ".jpg")
            for i in pages:
                pix = self.doc[i].get_pixmap(dpi=dpi, alpha=False, annots=True)
                name = path if len(pages) == 1 else "%s_Page_%d%s" % (root, i + 1, ext)
                if kind == "png":
                    pix.save(name, output="png")
                else:
                    pix.save(name, output="jpeg", jpg_quality=int(o.get("quality") or 90))
                files.append(name)
        elif kind == "txt":
            with open(path, "w", encoding="utf-8", newline="\r\n") as f:
                for k, i in enumerate(pages):
                    f.write(self.doc[i].get_text("text", sort=True))
                    if k + 1 < len(pages):
                        f.write("\f")
            files.append(path)
        elif kind == "html":
            with open(path, "w", encoding="utf-8") as f:
                f.write("<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>%s</title></head><body>\n" %
                        _html(os.path.basename(path)))
                for i in pages:
                    f.write(self.doc[i].get_text("xhtml"))
                f.write("</body></html>\n")
            files.append(path)
        elif kind == "docx":
            def picture(data, ext):
                try:
                    pix = fitz.Pixmap(data)
                    if pix.alpha or pix.n - pix.alpha != 3:
                        pix = fitz.Pixmap(fitz.csRGB, pix) if pix.colorspace and pix.colorspace.n != 3 else pix
                    return pix.tobytes("png"), "png"
                except Exception:
                    return None, None
            sgpdf_docx.write_docx(self.doc, path, pages, picture)
            files.append(path)
        else:
            raise Refusal("invalid", "unknown format")
        data = ("\n".join(files) + "\n").encode("utf-8")
        return "OK n=%d bytes=%d" % (len(files), len(data)), data


def _quads(a):
    v = a.vertices or []
    return [v[i:i + 4] for i in range(0, len(v) - 3, 4)]


def _umask():
    m = os.umask(0)
    os.umask(m)
    return m


def _html(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


# the protocol: request -> (method, least, most fields)
COMMANDS = {
    "open": ("open", 1, 2), "render": ("render", 3, 3), "text": ("text", 1, 1), "find": ("find", 1, 2),
    "links": ("links", 1, 1), "outline": ("outline", 0, 0),
    "state": ("state", 0, 0), "save": ("save", 1, 9), "undo": ("undo_", 0, 0), "redo": ("redo_", 0, 0),
    "properties": ("properties", 0, 9),
    "objects": ("objects", 1, 1), "edittext": ("edittext", 4, 16), "addtext": ("addtext", 3, 16),
    "addimage": ("addimage", 3, 3), "moveobj": ("moveobj", 3, 3), "delobj": ("delobj", 2, 2),
    "replaceimage": ("replaceimage", 3, 3),
    "annot": ("annot", 2, 16), "annots": ("annots", 0, 1), "delannot": ("delannot", 2, 2),
    "moveannot": ("moveannot", 3, 3), "setannot": ("setannot", 2, 8),
    "fields": ("fields", 0, 0), "setfield": ("setfield", 3, 3), "flatten": ("flatten", 0, 4),
    "signature": ("signature", 4, 4),
    "redactmark": ("redactmark", 1, 4), "redactfind": ("redactfind", 1, 3), "redactapply": ("redactapply", 0, 4),
    "sanitize": ("sanitize", 0, 16),
    "rotate": ("rotate", 2, 2), "delete": ("delete", 1, 1), "move": ("move", 2, 2),
    "insertblank": ("insertblank", 1, 3), "insertfile": ("insertfile", 2, 3), "extract": ("extract", 2, 3),
    "split": ("split", 3, 3), "combine": ("combine", 2, 200),
    "protect": ("protect", 1, 6), "unlock": ("unlock", 1, 1),
    "export": ("export", 2, 6),
}


def handle(engine, line):
    """one request line -> (header, payload), or None to stop"""
    f = line.split("\t")
    cmd, args = f[0], f[1:]
    if cmd == "quit":
        return None
    spec = COMMANDS.get(cmd)
    if not spec or not spec[1] <= len(args) <= spec[2]:
        return "ERR invalid unknown request", b""
    try:
        return getattr(engine, spec[0])(*args)
    except Refusal as e:
        return "ERR %s %s" % (e.kind, one_line(str(e))), b""
    except MemoryError:
        return "ERR failed out of memory", b""
    except Exception as e:  # never let one request take the program's bridge down
        import sys
        print("sg-pdf: %s failed: %s: %s" % (cmd, type(e).__name__, e), file=sys.stderr)
        return "ERR failed " + one_line("%s: %s" % (type(e).__name__, e)), b""
