#!/usr/bin/python3
# Unit gate for sg-pdf, the PDF Viewer's Linux half (poppler). A PDF is
# written here by hand (two pages of Helvetica text, a link, an outline), and
# the checks are the protocol the Windows viewer speaks: page sizes, bitmaps
# of the right size and colour (turned for 90 degrees), each character's box
# where the text is, search hits in top-left coordinates, links and
# bookmarks, and the refusals -- a missing or damaged file, a request before
# a document, pages out of range, absurd scales, unknown requests -- then the
# bridge a Windows program talks through. Skips (77) without poppler's GI
# bindings (gir1.2-poppler-0.18), which the package depends on.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PDF = os.path.join(HERE, "..", "bin", "sg-pdf")
FAILS = 0


def check(cond, what):
    global FAILS
    print(("PASS " if cond else "FAIL ") + what)
    if not cond:
        FAILS += 1


def make_pdf(path):
    """Two Letter pages; page 1 links to page 2; an outline of two entries."""
    def text_page(lines):
        ops = ["BT /F1 24 Tf"]
        for x, y, s in lines:
            ops.append("1 0 0 1 %d %d Tm (%s) Tj" % (x, y, s))
        ops.append("ET 0.2 0.1 0.45 rg 72 400 200 50 re f")
        return "\n".join(ops).encode()

    c1 = text_page([(72, 700, "Hello poppler world"), (72, 600, "Next page link")])
    c2 = text_page([(72, 700, "Second sheet giraffe"), (300, 500, "giraffe again")])
    objs = [
        b"<< /Type /Catalog /Pages 2 0 R /Outlines 9 0 R /PageMode /UseOutlines >>",
        b"<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R "
        b"/Resources << /Font << /F1 7 0 R >> >> /Annots [8 0 R] >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R "
        b"/Resources << /Font << /F1 7 0 R >> >> >>",
        b"<< /Length %d >>\nstream\n" % len(c1) + c1 + b"\nendstream",
        b"<< /Length %d >>\nstream\n" % len(c2) + c2 + b"\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        b"<< /Type /Annot /Subtype /Link /Rect [72 590 260 620] /Border [0 0 0] /Dest [4 0 R /XYZ 0 792 0] >>",
        b"<< /Type /Outlines /First 10 0 R /Last 11 0 R /Count 2 >>",
        b"<< /Title (First part) /Parent 9 0 R /Next 11 0 R /Dest [3 0 R /XYZ 0 792 0] >>",
        b"<< /Title (Second part) /Parent 9 0 R /Prev 10 0 R /Dest [4 0 R /XYZ 0 792 0] >>",
    ]
    out = bytearray(b"%PDF-1.4\n")
    offs = []
    for i, o in enumerate(objs, 1):
        offs.append(len(out))
        out += b"%d 0 obj\n" % i + o + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    for o in offs:
        out += b"%010d 00000 n \n" % o
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
    with open(path, "wb") as f:
        f.write(out)


class Client:
    """Speaks the protocol to `sg-pdf --serve`."""

    def __init__(self, argv=None):
        self.p = subprocess.Popen(argv or [PDF, "--serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)

    def ask(self, *fields):
        self.p.stdin.write(("\t".join(str(f) for f in fields) + "\n").encode())
        self.p.stdin.flush()
        head = self.p.stdout.readline().decode().rstrip("\n")
        n = 0
        for kv in head.split()[1:]:
            if kv.startswith("bytes="):
                n = int(kv[6:])
        data = self.p.stdout.read(n) if n else b""
        return head, data

    def close(self):
        try:
            self.p.stdin.write(b"quit\n")
            self.p.stdin.close()
        except BrokenPipeError:
            pass
        return self.p.wait(timeout=10)


def field(head, key):
    for kv in head.split()[1:]:
        if kv.startswith(key + "="):
            return kv[len(key) + 1:]
    return None


def main():
    tmp = tempfile.mkdtemp(prefix="sg-pdf-test.")
    doc = os.path.join(tmp, "two pages.pdf")
    make_pdf(doc)
    bad = os.path.join(tmp, "bad.pdf")
    with open(bad, "w") as f:
        f.write("not a pdf\n")

    probe = subprocess.run([PDF, "--info", doc], capture_output=True, text=True)
    if "poppler is not installed" in probe.stdout:
        print("SKIP: poppler's GI bindings (gir1.2-poppler-0.18) are not installed")
        return 77

    c = Client()
    h, _ = c.ask("text", 0)
    check(h.startswith("ERR notopen"), "a request before a document is refused (%s)" % h)
    h, _ = c.ask("open", os.path.join(tmp, "missing.pdf"))
    check(h.startswith("ERR open"), "a missing file: ERR open")
    h, _ = c.ask("open", bad)
    check(h.startswith("ERR open"), "a damaged file: ERR open (%s)" % h)
    h, data = c.ask("open", doc)
    check(h.startswith("OK") and field(h, "pages") == "2", "the document opens: 2 pages (%s)" % h)
    check(data.decode().splitlines()[:2] == ["size 612.000 792.000"] * 2, "both pages are 612x792 points")

    h, px = c.ask("render", 0, "0.5", 0)
    w, hh = int(field(h, "w") or 0), int(field(h, "h") or 0)
    check((w, hh) == (306, 396) and len(px) == w * hh * 4, "render at 0.5: 306x396 BGRA (%s)" % h)
    if len(px) == w * hh * 4 and w:
        def at(x, y):
            b, g, r, a = px[(y * w + x) * 4:(y * w + x) * 4 + 4]
            return r, g, b
        # the purple box: 72..272 x 400..450 PDF points -> top-left y 342..392, at 0.5
        r, g, b = at(86, 183)
        check(abs(r - 51) < 12 and abs(g - 26) < 12 and abs(b - 115) < 12, "the box is purple where the page puts it (%d,%d,%d)" % (r, g, b))
        check(at(300, 10) == (255, 255, 255), "the paper is white")
    h, px = c.ask("render", 0, "0.5", 90)
    check(field(h, "w") == "396" and field(h, "h") == "306", "turned 90 degrees: 396x306 (%s)" % h)
    if field(h, "w") == "396":
        w = 396
        # turned clockwise: the box (left of the page, low) is near the top, at the left
        # (x, y) -> (396 - y, x): the box's 36..136 x 171..196 becomes 200..225 x 36..136
        b, g, r, a = px[(86 * w + 212) * 4:(86 * w + 212) * 4 + 4]
        check(abs(r - 51) < 12 and abs(b - 115) < 12, "the turned box is where a clockwise turn puts it (%d,%d,%d)" % (r, g, b))

    h, data = c.ask("text", 0)
    n = int(field(h, "n") or 0)
    txt = data[:n * 2].decode("utf-16-le") if n else ""
    boxes = [struct.unpack("<4f", data[n * 2 + i * 16:n * 2 + i * 16 + 16]) for i in range(n)]
    check(txt.startswith("Hello poppler world"), "page 1's text: %r" % txt[:40])
    check(len(boxes) == n == len(txt), "a box for every character (%d)" % n)
    if boxes:
        x1, y1, x2, y2 = boxes[0]
        # "H" at x 72, baseline 700 from the bottom: top-left y ~ 92 minus the ascent
        check(71 <= x1 <= 74 and 60 <= y1 <= 92 and 88 <= y2 <= 100 and x2 > x1, "the H's box is at the top left (%s)" % (boxes[0],))

    h, data = c.ask("find", "GIRAFFE")
    hits = [l.split() for l in data.decode().splitlines()]
    check(field(h, "n") == "2" and all(hh[0] == "1" for hh in hits), "find GIRAFFE (any case): 2 hits on page 2 (%s)" % hits)
    if len(hits) == 2:
        check(float(hits[0][2]) < float(hits[1][2]), "hits are in reading order, top first")
        check(60 < float(hits[0][2]) < 100, "hit boxes are top-left based (y %s)" % hits[0][2])
    h, data = c.ask("find", "GIRAFFE", "c")
    check(field(h, "n") == "0", "find with match case: none")
    h, data = c.ask("find", "giraffe", "c")
    check(field(h, "n") == "2", "find 'giraffe' with match case: 2")

    h, data = c.ask("links", 0)
    ls = data.decode().splitlines()
    check(len(ls) == 1 and ls[0].split("\t")[1:3] == ["goto", "1"], "page 1 links to page 2 (%s)" % ls)
    if ls:
        x1, y1, x2, y2 = map(float, ls[0].split("\t")[0].split())
        check((x1, y1, x2, y2) == (72, 172, 260, 202), "the link's box is top-left based (%s)" % ls[0])
    h, data = c.ask("outline")
    ol = [l.split("\t") for l in data.decode().splitlines()]
    check([(o[0], o[1], o[4]) for o in ol] == [("0", "0", "First part"), ("0", "1", "Second part")], "the outline: %s" % ol)

    for req, kind in (((("render", 7, 1, 0)), "range"), (("render", 0, 1, 45), "invalid"), (("render", 0, 1000, 0), "invalid"),
                      (("render", 0, 60, 0), "toolarge"), (("render", "x", 1, 0), "invalid"), (("text", -1), "range"),
                      (("frobnicate",), "invalid"), (("find", ""), "invalid")):
        h, _ = c.ask(*req)
        check(h.startswith("ERR " + kind), "%s refused: %s" % (" ".join(map(str, req)), h))
    h, _ = c.ask("text", 1)
    check(h.startswith("OK"), "it still answers after refusals")
    check(c.close() == 0, "quit ends it")

    # the bridge: a program with our pipes as its stdin/stdout
    prog = os.path.join(tmp, "viewer.py")
    with open(prog, "w") as f:
        f.write("import sys\n"
                "sys.stdout.write('open\\t%s\\n'); sys.stdout.flush()\n"
                "head = sys.stdin.buffer.readline().decode()\n"
                "n = int([kv for kv in head.split() if kv.startswith('bytes=')][0][6:])\n"
                "sys.stdin.buffer.read(n)\n"
                "sys.stdout.write('render\\t1\\t0.25\\t0\\n'); sys.stdout.flush()\n"
                "head = sys.stdin.buffer.readline().decode()\n"
                "open(%r, 'w').write(head)\n" % (doc, os.path.join(tmp, "bridge.out")))
    r = subprocess.run([PDF, "--bridge", sys.executable, prog], timeout=30)
    out = open(os.path.join(tmp, "bridge.out")).read() if os.path.exists(os.path.join(tmp, "bridge.out")) else ""
    check(r.returncode == 0 and out.startswith("OK w=153 h=198"), "the bridge serves its program: %r" % out.strip())
    print("pdf-test: %s" % ("all passed" if not FAILS else "%d FAILED" % FAILS))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
