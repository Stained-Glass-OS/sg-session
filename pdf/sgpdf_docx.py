# sgpdf_docx -- "Export to Word": a PDF's text and pictures as a .docx.
#
# PDF has no paragraphs, only glyphs at positions; this writer rebuilds a
# reflowable document from MuPDF's text blocks: a paragraph a block, a run a
# span (its font, size, bold, italic and colour), a picture where the page
# has one (at its size), a page break between pages, and the first page's
# size and margins. It does not rebuild tables, columns, text boxes or exact
# positions -- nothing open source in Debian does that reliably; the text,
# its styling and the pictures are what carry over. Our own writer: only the
# standard library.
#
# Copyright (C) 2026 Stained Glass OS contributors
# SPDX-License-Identifier: AGPL-3.0-or-later

import re
import zipfile
from xml.sax.saxutils import escape

W_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
R_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
EMU = 12700             # EMUs a point

CONTENT_TYPES = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Default Extension="png" ContentType="image/png"/>
<Default Extension="jpeg" ContentType="image/jpeg"/>
<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
</Types>"""

ROOT_RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
</Relationships>"""

STYLES = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="%s">
<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Liberation Serif" w:hAnsi="Liberation Serif" w:cs="Liberation Serif"/>
<w:sz w:val="22"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="120"/></w:pPr></w:pPrDefault></w:docDefaults>
<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
</w:styles>""" % W_NS

# characters XML 1.0 cannot carry
BAD_XML = re.compile("[\x00-\x08\x0b\x0c\x0e-\x1f￾￿]")


def clean_font(name):
    name = name.split("+", 1)[1] if re.match(r"^[A-Z]{6}\+", name or "") else (name or "")
    name = re.sub(r"(PS|MT|PSMT)$", "", name.split(",")[0])
    base = re.split(r"[-,]", name)[0]
    base = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", base).strip()
    return base or "Liberation Serif"


def run_xml(text, span):
    font = escape(clean_font(span.get("font", "")))
    flags = span.get("flags", 0)
    bold = flags & 16 or "bold" in span.get("font", "").lower()
    italic = flags & 2 or "italic" in span.get("font", "").lower() or "oblique" in span.get("font", "").lower()
    size = max(2, int(round(span.get("size", 11) * 2)))
    color = "%06X" % (span.get("color", 0) & 0xFFFFFF)
    rpr = '<w:rFonts w:ascii="%s" w:hAnsi="%s" w:cs="%s"/>' % (font, font, font)
    if bold:
        rpr += "<w:b/>"
    if italic:
        rpr += "<w:i/>"
    if color != "000000":
        rpr += '<w:color w:val="%s"/>' % color
    rpr += '<w:sz w:val="%d"/><w:szCs w:val="%d"/>' % (size, size)
    text = BAD_XML.sub("", text)
    return '<w:r><w:rPr>%s</w:rPr><w:t xml:space="preserve">%s</w:t></w:r>' % (rpr, escape(text))


def picture_xml(rid, n, w_pt, h_pt):
    cx, cy = int(w_pt * EMU), int(h_pt * EMU)
    return (
        '<w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0" '
        'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">'
        '<wp:extent cx="%d" cy="%d"/><wp:docPr id="%d" name="Picture %d"/>'
        '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">'
        '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
        '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">'
        '<pic:nvPicPr><pic:cNvPr id="%d" name="image%d"/><pic:cNvPicPr/></pic:nvPicPr>'
        '<pic:blipFill><a:blip r:embed="%s"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
        '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="%d" cy="%d"/></a:xfrm>'
        '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>'
        '</a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>'
        % (cx, cy, n, n, n, n, rid, cx, cy))


def block_paragraph(block):
    """one text block -> a paragraph's runs (lines joined: a short line is a
    line break, a full one flows on)"""
    x0, _, x1, _ = block["bbox"]
    width = max(1.0, x1 - x0)
    runs = []
    lines = block.get("lines", [])
    for li, line in enumerate(lines):
        spans = [s for s in line.get("spans", []) if s.get("text")]
        for s in spans:
            runs.append(run_xml(s["text"], s))
        if li + 1 < len(lines) and spans:
            lx1 = line["bbox"][2]
            if (lx1 - x0) < 0.7 * width:
                runs.append("<w:r><w:br/></w:r>")
            elif not spans[-1]["text"].endswith((" ", "-")):
                runs.append(run_xml(" ", spans[-1]))
    return runs


def write_docx(doc, path, pages, pixmap_png):
    """doc: an open pymupdf Document; pages: 0-based page numbers;
    pixmap_png(bytes, ext) -> PNG/JPEG bytes and extension for an image."""
    import pymupdf as fitz
    body = []
    media = []
    first = doc[pages[0]] if pages else None
    for pi, pno in enumerate(pages):
        page = doc[pno]
        d = page.get_text("dict", flags=fitz.TEXTFLAGS_DICT | fitz.TEXT_PRESERVE_IMAGES)
        blocks = sorted(d.get("blocks", []), key=lambda b: (round(b["bbox"][1] / 4), b["bbox"][0]))
        for b in blocks:
            if b.get("type") == 1 and b.get("image"):
                data, ext = pixmap_png(b["image"], b.get("ext", "png"))
                if not data:
                    continue
                n = len(media) + 1
                name = "image%d.%s" % (n, ext)
                media.append((name, data))
                x0, y0, x1, y1 = b["bbox"]
                w, h = max(1, x1 - x0), max(1, y1 - y0)
                maxw = page.rect.width - 144
                if w > maxw:
                    w, h = maxw, h * maxw / w
                body.append(picture_xml("rIdImg%d" % n, n, w, h))
            elif b.get("type") == 0:
                runs = block_paragraph(b)
                if runs:
                    body.append("<w:p>%s</w:p>" % "".join(runs))
        if pi + 1 < len(pages):
            body.append('<w:p><w:r><w:br w:type="page"/></w:r></w:p>')
    if first is not None:
        pw, ph = first.rect.width, first.rect.height
    else:
        pw, ph = 612, 792
    sect = ('<w:sectPr><w:pgSz w:w="%d" w:h="%d"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" '
            'w:left="1440" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>' % (int(pw * 20), int(ph * 20)))
    document = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
                '<w:document xmlns:w="%s" xmlns:r="%s"><w:body>%s%s</w:body></w:document>'
                % (W_NS, R_NS, "".join(body) or "<w:p/>", sect))
    rels = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" '
            'Target="styles.xml"/>']
    for i, (name, _) in enumerate(media, 1):
        rels.append('<Relationship Id="rIdImg%d" Type="http://schemas.openxmlformats.org/officeDocument/2006/'
                    'relationships/image" Target="media/%s"/>' % (i, name))
    rels.append("</Relationships>")
    title = escape(BAD_XML.sub("", (doc.metadata or {}).get("title") or ""))
    core = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
            'xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>%s</dc:title></cp:coreProperties>' % title)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", CONTENT_TYPES)
        z.writestr("_rels/.rels", ROOT_RELS)
        z.writestr("docProps/core.xml", core)
        z.writestr("word/document.xml", document)
        z.writestr("word/styles.xml", STYLES)
        z.writestr("word/_rels/document.xml.rels", "".join(rels))
        for name, data in media:
            z.writestr("word/media/" + name, data)
    return len(media)
