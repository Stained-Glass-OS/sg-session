# sgpdf_create -- SG PDF's documents from elsewhere and whole-document tools:
#
#   Create PDF     a blank document; from pictures (each its own page, at its
#                  resolution's size), text files, other PDFs, office
#                  documents (SG Office's converter, else LibreOffice), and
#                  the scanner (SANE's scanimage, a page each scan)
#   Recognize text OCRmyPDF and Tesseract: an invisible text layer under each
#                  scanned page, so it can be searched, selected and copied
#                  (pages that have text already are left alone)
#   Headers & footers, watermark, Bates numbering, page numbers
#                  drawn into the pages (text: the page number, the page
#                  count, the date, the Bates number; a picture watermark)
#   Optimize       pictures above the resolution chosen are scaled down and
#                  stored as JPEG, fonts subset, unused objects dropped
#
# Copyright (C) 2026 Stained Glass OS contributors
# SPDX-License-Identifier: AGPL-3.0-or-later

import datetime
import glob
import io
import os
import re
import shutil
import subprocess
import tempfile

import pymupdf as fitz

IMAGE_EXT = (".png", ".jpg", ".jpeg", ".gif", ".bmp", ".tif", ".tiff", ".webp", ".pnm", ".ppm", ".pgm", ".jxr",
             ".jpx", ".jp2")
TEXT_EXT = (".txt", ".text", ".log", ".csv", ".md", ".ini", ".cfg", ".json", ".xml", ".py", ".c", ".h", ".sh")
OFFICE_EXT = (".doc", ".docx", ".odt", ".rtf", ".xls", ".xlsx", ".ods", ".csv", ".ppt", ".pptx", ".odp", ".wpd",
              ".docm", ".dotx", ".xlsm", ".pptm", ".pages", ".epub", ".htm", ".html")
X2T = tuple(p for p in (os.environ.get("SG_PDF_X2T"), "/usr/lib/sg-office/engine/x2t") if p)
X2T_FORMATS = {".docx": 65, ".doc": 69, ".odt": 67, ".rtf": 68, ".xlsx": 257, ".xls": 259, ".ods": 258,
               ".pptx": 129, ".ppt": 130, ".odp": 131, ".txt": 69, ".htm": 70, ".html": 70, ".docm": 65,
               ".xlsm": 257, ".pptm": 129, ".dotx": 65, ".epub": 72}


class CreateError(Exception):
    pass


# ---- pictures, text, office documents ----------------------------------------------------------------

def image_pages(path):
    """a picture file -> a one-page (or, for a multi-page TIFF, many-page) PDF document"""
    try:
        img = fitz.open(path)
    except Exception:
        raise CreateError("%s is not a picture this program can read" % os.path.basename(path))
    try:
        data = img.convert_to_pdf()
    except Exception as e:
        raise CreateError("%s could not be converted: %s" % (os.path.basename(path), " ".join(str(e).split())))
    return fitz.open("pdf", data)


def text_pages(path, fontsize=10.5):
    """a plain text file set in a monospaced font on letter pages"""
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError as e:
        raise CreateError("could not read %s: %s" % (os.path.basename(path), e.strerror))
    for enc in ("utf-8-sig", "utf-16", "cp1252", "latin-1"):
        try:
            text = raw.decode(enc)
            break
        except UnicodeDecodeError:
            continue
    text = text.replace("\r\n", "\n").replace("\r", "\n").expandtabs(8)
    doc = fitz.open()
    w, h, m = 612, 792, 54
    lh = fontsize * 1.25
    per_page = int((h - 2 * m) / lh)
    cols = int((w - 2 * m) / (fontsize * 0.6))
    lines = []
    for ln in text.split("\n"):
        while len(ln) > cols:
            lines.append(ln[:cols])
            ln = ln[cols:]
        lines.append(ln)
    font = fitz.Font("cour")
    mono = _font_file("DejaVu Sans Mono") or _font_file("Liberation Mono")
    if mono:
        font = fitz.Font(fontfile=mono)
    for k in range(0, max(1, len(lines)), per_page):
        page = doc.new_page(width=w, height=h)
        tw = fitz.TextWriter(page.rect)
        y = m + fontsize
        for ln in lines[k:k + per_page]:
            if ln:
                tw.append((m, y), ln, font=font, fontsize=fontsize)
            y += lh
        tw.write_text(page)
    return doc


def _font_file(family):
    try:
        out = subprocess.run(["fc-match", "-f", "%{file}", family], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    return out if out and os.path.isfile(out) else None


def office_to_pdf(path, workdir, timeout=300):
    """an office document -> PDF bytes: SG Office's converter (x2t), else LibreOffice"""
    ext = os.path.splitext(path)[1].lower()
    out = os.path.join(workdir, "converted.pdf")
    for x2t in X2T:
        if os.path.isfile(x2t) and ext in X2T_FORMATS:
            if _x2t(x2t, path, out, workdir, timeout) and os.path.isfile(out) and os.path.getsize(out) > 0:
                with open(out, "rb") as f:
                    return f.read()
    soffice = shutil.which("soffice") or shutil.which("libreoffice")
    if soffice:
        prof = os.path.join(workdir, "lo-profile")
        try:
            subprocess.run([soffice, "-env:UserInstallation=file://" + prof, "--headless", "--norestore",
                            "--convert-to", "pdf", "--outdir", workdir, path],
                           capture_output=True, timeout=timeout, cwd=workdir)
        except (OSError, subprocess.TimeoutExpired):
            pass
        cand = os.path.join(workdir, os.path.splitext(os.path.basename(path))[0] + ".pdf")
        if os.path.isfile(cand) and os.path.getsize(cand) > 0:
            with open(cand, "rb") as f:
                return f.read()
    raise CreateError("%s could not be converted: no office converter (SG Office or LibreOffice) could open it"
                      % os.path.basename(path))


def _xml(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def _x2t(x2t, src, out, workdir, timeout):
    """SG Office's engine: the document to PDF (format 513), its fonts found by fontconfig"""
    engine = os.path.dirname(x2t)
    share = os.path.normpath(os.path.join(engine, "..", "..", "..", "share", "sg-office"))
    fonts = os.path.join(workdir, "fonts")
    os.makedirs(fonts, exist_ok=True)
    gen = os.path.join(engine, "allfontsgen")
    if os.path.isfile(gen):
        try:
            subprocess.run([gen, "--input=/usr/share/fonts", "--allfonts=" + os.path.join(fonts, "AllFonts.js"),
                            "--selection=" + os.path.join(fonts, "font_selection.bin")],
                           capture_output=True, timeout=timeout, cwd=engine,
                           env=dict(os.environ, LD_LIBRARY_PATH=engine))
        except (OSError, subprocess.TimeoutExpired):
            return False
    tmp = os.path.join(workdir, "x2t-tmp")
    os.makedirs(tmp, exist_ok=True)
    params = os.path.join(workdir, "params.xml")
    with open(params, "w", encoding="utf-8") as f:
        f.write('<?xml version="1.0" encoding="utf-8"?><TaskQueueDataConvert>'
                "<m_sFileFrom>%s</m_sFileFrom><m_sFileTo>%s</m_sFileTo><m_nFormatTo>513</m_nFormatTo>"
                "<m_sThemeDir>%s</m_sThemeDir><m_sFontDir>%s</m_sFontDir>"
                "<m_sAllFontsPath>%s</m_sAllFontsPath><m_bDontSaveAdditional>true</m_bDontSaveAdditional>"
                "<m_sTempDir>%s</m_sTempDir></TaskQueueDataConvert>" % (
                    _xml(src), _xml(out), _xml(share + "/sdkjs/slide/themes"), _xml(fonts),
                    _xml(os.path.join(fonts, "AllFonts.js")), _xml(tmp)))
    try:
        r = subprocess.run([x2t, params], capture_output=True, timeout=timeout, cwd=engine,
                           env=dict(os.environ, LD_LIBRARY_PATH=engine))
    except (OSError, subprocess.TimeoutExpired):
        return False
    return r.returncode == 0


def document_from(paths, workdir, password_of=None):
    """files of any kind we read -> one new document, in order"""
    if not paths:
        raise CreateError("no files")
    new = fitz.open()
    for p in paths:
        ext = os.path.splitext(p)[1].lower()
        if not os.path.isfile(p):
            raise CreateError("%s was not found" % os.path.basename(p))
        src = None
        with open(p, "rb") as f:
            head = f.read(8)
        if head.startswith(b"%PDF") or ext == ".pdf":
            try:
                src = fitz.open(p)
            except Exception:
                raise CreateError("%s is not a PDF this program can read" % os.path.basename(p))
            if src.needs_pass:
                pw = password_of(p) if password_of else None
                if not pw or not src.authenticate(pw):
                    raise CreateError("%s needs a password" % os.path.basename(p))
        elif ext in IMAGE_EXT:
            src = image_pages(p)
        elif ext in TEXT_EXT and ext not in (".csv",):
            src = text_pages(p)
        elif ext in OFFICE_EXT:
            sub = tempfile.mkdtemp(prefix="conv-", dir=workdir)
            src = fitz.open("pdf", office_to_pdf(p, sub))
        else:
            try:
                src = image_pages(p)
            except CreateError:
                raise CreateError("%s is not a kind of file that can be made into a PDF" % os.path.basename(p))
        new.insert_pdf(src)
    if not new.page_count:
        raise CreateError("the files have no pages")
    return new


# ---- the scanner ---------------------------------------------------------------------------------------------

def scanners(timeout=40):
    exe = shutil.which("scanimage")
    if not exe:
        return []
    try:
        out = subprocess.run([exe, "-f", "%d\t%v %m (%t)%n"], capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    found = []
    for ln in out.splitlines():
        if "\t" in ln:
            dev, label = ln.split("\t", 1)
            found.append((dev.strip(), " ".join(label.split())))
    return found


def scan(device, workdir, dpi=300, mode="Color", source="", pages=1, timeout=300):
    """scanned pages -> a document (each scan a page at its true size)"""
    exe = shutil.which("scanimage")
    if not exe:
        raise CreateError("scanning needs SANE's scanimage (package sane-utils)")
    new = fitz.open()
    batch = source and "adf" in source.lower() or "feeder" in (source or "").lower()
    base = os.path.join(workdir, "scan")
    cmd = [exe, "--format=png", "--resolution", str(int(dpi)), "--mode", mode]
    if device:
        cmd[1:1] = ["-d", device]
    if source:
        cmd += ["--source", source]
    try:
        if batch:
            subprocess.run(cmd + ["--batch=" + base + "%03d.png"], capture_output=True, timeout=timeout, check=False)
            files = sorted(glob.glob(base + "*.png"))
        else:
            files = []
            for k in range(max(1, int(pages))):
                out = "%s%03d.png" % (base, k)
                with open(out, "wb") as f:
                    r = subprocess.run(cmd, stdout=f, stderr=subprocess.PIPE, timeout=timeout)
                if r.returncode != 0 or os.path.getsize(out) == 0:
                    msg = r.stderr.decode("utf-8", "replace").strip().splitlines()
                    raise CreateError("the scanner did not scan: %s" % (msg[-1] if msg else "no answer"))
                files.append(out)
    except subprocess.TimeoutExpired:
        raise CreateError("the scanner did not answer in time")
    except OSError as e:
        raise CreateError("could not run the scanner: %s" % (e.strerror or e))
    if not files:
        raise CreateError("the scanner gave no pages")
    for fpath in files:
        img = fitz.open(fpath)
        pdf = fitz.open("pdf", img.convert_to_pdf())
        # convert_to_pdf sizes the page from the picture's resolution
        new.insert_pdf(pdf)
    return new


# ---- recognize text ------------------------------------------------------------------------------------------

def ocr_languages():
    exe = shutil.which("tesseract")
    if not exe:
        return []
    try:
        out = subprocess.run([exe, "--list-langs"], capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    return [ln.strip() for ln in out.splitlines()[1:] if ln.strip() and ln.strip() != "osd"]


def ocr(data, workdir, lang="eng", pages=None, deskew=False, timeout=3600, progress=None):
    """PDF bytes -> PDF bytes with a text layer on its scanned pages"""
    if not shutil.which("ocrmypdf"):
        raise CreateError("recognizing text needs OCRmyPDF (package ocrmypdf)")
    have = ocr_languages()
    for lg in lang.split("+"):
        if lg not in have:
            raise CreateError("the language %s is not installed for text recognition (package tesseract-ocr-%s)"
                              % (lg, lg.replace("_", "-").lower()))
    src = os.path.join(workdir, "in.pdf")
    out = os.path.join(workdir, "out.pdf")
    with open(src, "wb") as f:
        f.write(data)
    cmd = ["ocrmypdf", "--skip-text", "-l", lang, "--output-type", "pdf", "--optimize", "0", "--jobs", "2",
           "--quiet"]
    if deskew:
        cmd = ["ocrmypdf", "--force-ocr", "--deskew", "-l", lang, "--output-type", "pdf", "--optimize", "0",
               "--jobs", "2", "--quiet"]
    if pages:
        cmd += ["--pages", pages]
    cmd += [src, out]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                           env=dict(os.environ, OMP_THREAD_LIMIT="1"))
    except subprocess.TimeoutExpired:
        raise CreateError("recognizing text took too long")
    except OSError as e:
        raise CreateError("could not run OCRmyPDF: %s" % (e.strerror or e))
    # 0 done; 6 the document has text already (with --skip-text it is not an error)
    if r.returncode not in (0,) or not os.path.isfile(out):
        msg = [ln for ln in (r.stderr or "").splitlines() if ln.strip()]
        if r.returncode == 6:
            raise CreateError("the pages have text already")
        if r.returncode == 8:
            raise CreateError("the document is encrypted; remove its security first")
        raise CreateError("text recognition failed: %s" % (msg[-1][:200] if msg else "exit %d" % r.returncode))
    with open(out, "rb") as f:
        return f.read()


# ---- headers, footers, watermarks, Bates numbers ---------------------------------------------------------------

def expand(template, page_no, count, bates=None, when=None):
    when = when or datetime.date.today()
    t = template.replace("<<page>>", str(page_no)).replace("<<pages>>", str(count))
    t = t.replace("<<date>>", when.strftime("%m/%d/%Y")).replace("<<isodate>>", when.isoformat())
    if bates is not None:
        t = t.replace("<<bates>>", bates)
    return t


def bates_number(prefix, start, digits, suffix, k):
    return "%s%0*d%s" % (prefix, digits, start + k, suffix)


def _font(name):
    name = (name or "helv").lower()
    if name in ("helv", "tiro", "cour", "hebo", "tibo", "cobo", "heit", "tiit", "coit"):
        return fitz.Font(name)
    path = _font_file(name)
    return fitz.Font(fontfile=path) if path else fitz.Font("helv")


def decorate(doc, pages, kind, o, rgb):
    """headers and footers (left, center, right of each), Bates numbers, page numbers, watermarks"""
    count = doc.page_count
    size = float(o.get("size") or (60 if kind == "watermark" else 10))
    color = rgb(o.get("color"), (0, 0, 0) if kind != "watermark" else (0.75, 0.1, 0.1))
    opacity = max(0.02, min(1.0, float(o.get("opacity") or (0.3 if kind == "watermark" else 1))))
    font = _font(o.get("font"))
    margin = float(o.get("margin") or 36)
    start = int(o.get("start") or 1)
    digits = int(o.get("digits") or 6)
    prefix, suffix = o.get("prefix", ""), o.get("suffix", "")
    for k, i in enumerate(pages):
        page = doc[i]
        r = page.rect
        bates = bates_number(prefix, start, digits, suffix, k) if kind == "bates" else None
        if kind == "watermark":
            _watermark(page, o, font, size, color, opacity, i + 1, count)
            continue
        slots = {}
        if kind in ("header", "footer"):
            for pos in ("left", "center", "right"):
                if o.get(pos):
                    slots[pos] = expand(o[pos], i + 1 + int(o.get("offset") or 0), count, None)
            where = kind
        elif kind == "pagenumbers":
            fmt = o.get("format") or "Page <<page>> of <<pages>>"
            slots[o.get("align") or "center"] = expand(fmt, start + k, count + start - 1)
            where = o.get("where") or "footer"
        elif kind == "bates":
            slots[o.get("align") or "right"] = bates
            where = o.get("where") or "footer"
        else:
            raise CreateError("unknown kind " + kind)
        tw = fitz.TextWriter(r, opacity=opacity, color=color)
        for pos, text in slots.items():
            if not text:
                continue
            width = font.text_length(text, size)
            x = {"left": margin, "center": (r.width - width) / 2, "right": r.width - margin - width}[pos]
            y = margin * 0.5 + size if where == "header" else r.height - margin * 0.5
            tw.append((x, y), text, font=font, fontsize=size)
        _write_upright(tw, page)
    return len(pages)


def _upright(page, tw, pre=None):
    """the matrix that writes a TextWriter laid out in shown-page coordinates upright on the
    page (its /Rotate undone), with `pre` (a turn about a point, in shown coordinates) first"""
    cb, mb = page.cropbox_position, page.mediabox
    delta = page.rect.height - page.rect.width if page.rotation in (90, 270) else 0
    t = fitz.Matrix(1, 0, 0, 1, cb.x, cb.y + mb.y0 - delta)
    m = ~tw.ictm
    if pre is not None:
        m = m * pre
    return m * page.derotation_matrix * ~page.transformation_matrix * ~t


def _write_upright(tw, page, overlay=True, pre=None):
    if not page.rotation and pre is None:
        tw.write_text(page, overlay=overlay)
    else:
        tw.write_text(page, overlay=overlay, matrix=_upright(page, tw, pre))


def _watermark(page, o, font, size, color, opacity, page_no, count):
    r = page.rect
    behind = o.get("behind") == "1"
    angle = float(o.get("rotate") or 45)
    img = o.get("image")
    if img:
        try:
            pix = fitz.Pixmap(img)
        except Exception:
            raise CreateError("that file is not a picture this program can read")
        scale = float(o.get("scale") or 0.5)
        w = r.width * scale
        h = w * pix.height / max(1, pix.width)
        box = fitz.Rect((r.width - w) / 2, (r.height - h) / 2, (r.width + w) / 2, (r.height + h) / 2)
        if opacity < 1:
            if pix.alpha:
                pix = fitz.Pixmap(pix, 0)
            if pix.n != 3:
                pix = fitz.Pixmap(fitz.csRGB, pix)
            pix = fitz.Pixmap(pix, 1)
            pix.set_alpha(bytes([int(255 * opacity)]) * (pix.width * pix.height))
        page.insert_image((box * page.derotation_matrix).normalize() if page.rotation else box, pixmap=pix,
                          overlay=not behind, rotate=page.rotation)
        return
    text = expand(o.get("text") or "DRAFT", page_no, count)
    lines = text.split("\n")
    tw = fitz.TextWriter(r, opacity=opacity, color=color)
    lh = size * 1.2
    total = lh * len(lines)
    cx, cy = r.width / 2, r.height / 2
    for k, ln in enumerate(lines):
        width = font.text_length(ln, size)
        tw.append((cx - width / 2, cy - total / 2 + size * 0.8 + k * lh), ln, font=font, fontsize=size)
    turn = fitz.Matrix(1, 0, 0, 1, -cx, -cy) * fitz.Matrix(-angle) * fitz.Matrix(1, 0, 0, 1, cx, cy)
    _write_upright(tw, page, overlay=not behind, pre=turn)


# ---- optimize ------------------------------------------------------------------------------------------------------

def optimize(doc, dpi=150, quality=75, threshold=1.5):
    """pictures drawn above dpi*threshold scaled down to dpi and stored as JPEG; returns the count"""
    done = set()
    count = 0
    for page in doc:
        for info in page.get_image_info(xrefs=True):
            xref = info.get("xref")
            if not xref or xref in done:
                continue
            done.add(xref)
            bbox = fitz.Rect(info["bbox"])
            if bbox.is_empty or bbox.width < 1:
                continue
            w = info["width"]
            eff = w / (bbox.width / 72.0)
            if eff <= dpi * threshold:
                continue
            try:
                if doc.xref_get_key(xref, "SMask")[0] != "null" or doc.xref_get_key(xref, "ImageMask")[1] == "true":
                    continue
                pix = fitz.Pixmap(doc, xref)
                if pix.alpha:
                    continue
                if pix.colorspace is None or pix.colorspace.n not in (1, 3):
                    pix = fitz.Pixmap(fitz.csRGB, pix)
                f = dpi / eff
                nw, nh = max(1, int(pix.width * f)), max(1, int(pix.height * f))
                small = fitz.Pixmap(pix, nw, nh, None)
                jpg = small.tobytes("jpeg", jpg_quality=int(quality))
                page.replace_image(xref, stream=jpg)
                count += 1
            except Exception:
                continue
    try:
        doc.subset_fonts()
    except Exception:
        pass
    return count


def pdf_size(doc):
    buf = io.BytesIO()
    doc.save(buf, garbage=3, deflate=True, use_objstms=1)
    return buf.getbuffer().nbytes


def isodate():
    return datetime.date.today().isoformat()


def safe_name(s):
    return re.sub(r"[^\w.-]+", "_", s)[:80]
