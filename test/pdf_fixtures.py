# Test documents for SG PDF's gates, made here (never real documents).
#
# redaction_pdf: a page whose content streams are written by hand, so a raw
# search of the uncompressed file is meaningful (the secrets are literal
# strings in Tj operators -- found before redaction, the positive control):
# personal data, a secret word mid-line, a gray table background and grid
# lines through it, a curve, a picture with a red square, text inside a form
# XObject, a hidden layer's text, invisible text, a comment and a link over
# the secret, metadata, an attachment and document JavaScript.
#
# edit_pdf: paragraphs in Helvetica (not embedded) and in Liberation Sans
# (embedded whole), a picture, paths; form_pdf: an AcroForm with a text
# field, a check box, two radio buttons, a combo box and a list box.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
import os
import zlib

import pymupdf as fitz

SECRETS = ["TOPSECRET", "FORMSECRET", "123-45-6789", "john.public@example.com"]
HIDDEN = ["LAYERSECRET", "HIDDENTEXT", "SECRETMETA", "ATTACHSECRET", "JSSECRET", "COMMENTSECRET"]


def _png(w, h, pixel):
    """a PNG made by hand: pixel(x, y) -> (r, g, b)"""
    import struct
    rows = b"".join(b"\x00" + b"".join(bytes(pixel(x, y)) for x in range(w)) for y in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def red_square_png(path, w=100, h=100):
    def px(x, y):
        return (230, 20, 20) if 35 <= x < 65 and 35 <= y < 65 else (40, 120, 220)
    with open(path, "wb") as f:
        f.write(_png(w, h, px))
    return path


def green_png(path, w=40, h=30):
    with open(path, "wb") as f:
        f.write(_png(w, h, lambda x, y: (20, 180, 60)))
    return path


def redaction_pdf(path, tmpdir):
    doc = fitz.open()
    page = doc.new_page(width=612, height=792)
    # the picture (an XObject) and a form XObject with secret text, via MuPDF
    img = red_square_png(os.path.join(tmpdir, "redsq.png"))
    page.insert_image(fitz.Rect(400, 500, 500, 600), filename=img)
    src = fitz.open()
    sp = src.new_page(width=200, height=40)
    sp.insert_text((5, 25), "FORMSECRET", fontsize=14, fontname="helv")
    page.show_pdf_page(fitz.Rect(72, 640, 272, 680), src, 0)
    # a hidden layer
    ocg = doc.add_ocg("Hidden notes", on=False)
    # the rest by hand
    img_name = "/" + page.get_images(full=True)[0][7]
    form_name = "/" + [x[1] for x in page.get_xobjects() if x[2] == 0][0]
    content = """
0.85 0.85 0.85 rg 60 380 492 200 re f
0 0 0 RG 1 w 60 480 m 552 480 l S
60 440 m 552 440 l S
180 380 m 180 580 l S
0 0.5 0 RG 2 w 100 300 m 200 360 300 240 400 300 c S
BT 0 g /F1 12 Tf
1 0 0 1 72 720 Tm (Name: John Q Public) Tj
1 0 0 1 72 700 Tm (SSN: 123-45-6789) Tj
1 0 0 1 72 680 Tm (Phone: \\(555\\) 123-4567) Tj
1 0 0 1 72 660 Tm (Email: john.public@example.com) Tj
1 0 0 1 72 500 Tm (Keep this line TOPSECRET keep this too) Tj
1 0 0 1 72 460 Tm (A row of the table stays readable) Tj
3 Tr 1 0 0 1 72 420 Tm (HIDDENTEXT invisible) Tj 0 Tr
ET
/OC /L1 BDC BT 0 g /F1 12 Tf 1 0 0 1 72 400 Tm (LAYERSECRET on a layer that is off) Tj ET EMC
q 100 0 0 100 400 192 cm %s Do Q
q %s Do Q
""" % (img_name, form_name)
    # the insert_image/show_pdf_page streams are replaced: the picture is drawn
    # by hand (PDF space), the form keeps the matrix MuPDF gave it
    font = doc.get_new_xref()
    doc.update_object(font, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    t, res = doc.xref_get_key(page.xref, "Resources")
    res = int(res.split()[0]) if t == "xref" else page.xref
    pre = "" if t == "xref" else "Resources/"
    doc.xref_set_key(res, pre + "Font", "<< /F1 %d 0 R >>" % font)
    doc.xref_set_key(res, pre + "Properties", "<< /L1 %d 0 R >>" % ocg)
    contents = page.get_contents()
    doc.update_stream(contents[0], content.encode("latin-1"), compress=False)
    if len(contents) > 1:
        doc.xref_set_key(page.xref, "Contents", "%d 0 R" % contents[0])
    # a comment and a link over the secret word
    r = fitz.Rect(150, 280, 230, 296)
    a = page.add_text_annot(r.tl, "COMMENTSECRET: see the word here")
    a.update()
    page.insert_link({"kind": fitz.LINK_URI, "from": r, "uri": "https://example.com/TOPSECRET"})
    # a second page: plain, keeps its text
    p2 = doc.new_page(width=612, height=792)
    p2.insert_text((72, 100), "Second page text stays", fontname="helv", fontsize=12)
    p2.insert_text((72, 130), "TOPSECRET appears here too", fontname="helv", fontsize=12)
    doc.set_metadata({"title": "Confidential Title SECRETMETA", "author": "Gate Author", "subject": "SECRETMETA"})
    doc.embfile_add("secret.txt", b"ATTACHSECRET inside the attachment", filename="secret.txt")
    cat = doc.pdf_catalog()
    js = doc.get_new_xref()
    doc.update_object(js, "<< /S /JavaScript /JS (app.alert\\('JSSECRET'\\)) >>")
    doc.xref_set_key(cat, "OpenAction", "%d 0 R" % js)
    doc.save(path, garbage=3, deflate=False)
    return path


def edit_pdf(path, tmpdir):
    doc = fitz.open()
    p = doc.new_page(width=612, height=792)
    p.insert_textbox(fitz.Rect(72, 72, 400, 140),
                     "The quick brown fox jumps over the lazy dog. A paragraph in Helvetica that wraps.",
                     fontname="helv", fontsize=12)
    lib = "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf"
    if os.path.exists(lib):
        p.insert_font(fontname="LibSans", fontfile=lib)
        p.insert_text((72, 200), "Embedded font line", fontname="LibSans", fontsize=14, color=(0.1, 0.2, 0.6))
    else:
        p.insert_text((72, 200), "Embedded font line", fontname="helv", fontsize=14, color=(0.1, 0.2, 0.6))
    img = red_square_png(os.path.join(tmpdir, "pic.png"))
    p.insert_image(fitz.Rect(72, 300, 172, 400), filename=img)
    p.draw_rect(fitz.Rect(300, 300, 400, 350), color=(0, 0, 0), fill=(0.9, 0.8, 0.1), width=1)
    p.draw_line((300, 420), (500, 420), color=(0.8, 0, 0), width=2)
    for i in range(2, 5):
        pg = doc.new_page(width=612, height=792)
        pg.insert_text((72, 100), "Page %d marker" % i, fontname="helv", fontsize=18)
    doc.save(path, garbage=3, deflate=True)
    return path


def form_pdf(path):
    doc = fitz.open()
    p = doc.new_page(width=612, height=792)
    p.insert_text((72, 90), "Application form", fontname="helv", fontsize=16)

    def add(kind, name, rect, **kw):
        w = fitz.Widget()
        w.field_type = kind
        w.field_name = name
        w.rect = fitz.Rect(rect)
        for k, v in kw.items():
            setattr(w, k, v)
        p.add_widget(w)
    add(fitz.PDF_WIDGET_TYPE_TEXT, "fullname", (150, 110, 400, 130), field_value="", text_fontsize=11)
    add(fitz.PDF_WIDGET_TYPE_CHECKBOX, "agree", (150, 150, 166, 166), field_value=False)
    add(fitz.PDF_WIDGET_TYPE_RADIOBUTTON, "size", (150, 190, 166, 206), field_value=False)
    add(fitz.PDF_WIDGET_TYPE_RADIOBUTTON, "size", (200, 190, 216, 206), field_value=False)
    add(fitz.PDF_WIDGET_TYPE_COMBOBOX, "colour", (150, 230, 300, 250), choice_values=["Red", "Green", "Blue"],
        field_value="Red")
    add(fitz.PDF_WIDGET_TYPE_LISTBOX, "fruit", (150, 270, 300, 330), choice_values=["Apple", "Pear", "Plum"],
        field_value="Apple")
    doc.save(path, garbage=3, deflate=True)
    return path
