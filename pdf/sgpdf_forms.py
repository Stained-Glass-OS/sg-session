# sgpdf_forms -- SG PDF's forms: making fillable forms (Prepare Form) and
# what filling them computes.
#
#   Prepare Form   new fields of each kind (text, date, number, check box,
#                  radio button, drop-down, list box, signature), their
#                  properties (name, tooltip, required, read-only, multi-line,
#                  length, font size, alignment, default, choices, format,
#                  calculation) and the fields a flat page suggests: blanks
#                  drawn as underscores or rules, empty boxes and table cells,
#                  small squares (check boxes), labels ending in a colon --
#                  named after their labels ("Date of birth" -> a date field).
#   Format         stored as the standard JavaScript actions (AFNumber_Format,
#                  AFPercent_Format, AFDate_FormatEx, AFSpecial_Format), so
#                  other readers format the same way; we evaluate them
#                  ourselves (MuPDF runs no form JavaScript): the field keeps
#                  the value typed, its appearance shows it formatted.
#   Calculation    AFSimple_Calculate (SUM, PRD, AVG, MIN, MAX of fields) and
#                  simplified field notation ("Qty * Price", stored between
#                  BVCALC and EVCALC as the familiar editor does, with its
#                  JavaScript); evaluated here in the document's calculation
#                  order (/CO) after every change to a field.
#
# Copyright (C) 2026 Stained Glass OS contributors
# SPDX-License-Identifier: AGPL-3.0-or-later

import datetime
import re

import pymupdf as fitz

KINDS = {
    "text": fitz.PDF_WIDGET_TYPE_TEXT, "date": fitz.PDF_WIDGET_TYPE_TEXT, "number": fitz.PDF_WIDGET_TYPE_TEXT,
    "checkbox": fitz.PDF_WIDGET_TYPE_CHECKBOX, "radio": fitz.PDF_WIDGET_TYPE_RADIOBUTTON,
    "combo": fitz.PDF_WIDGET_TYPE_COMBOBOX, "list": fitz.PDF_WIDGET_TYPE_LISTBOX,
    "signature": fitz.PDF_WIDGET_TYPE_SIGNATURE,
}
BASE_NAMES = {"text": "Text", "date": "Date", "number": "Number", "checkbox": "Check Box", "radio": "Group",
              "combo": "Dropdown", "list": "List Box", "signature": "Signature"}

FLAG_READONLY, FLAG_REQUIRED = 1, 2
FLAG_MULTILINE = 1 << 12
FLAG_COMB = 1 << 24


class FormError(Exception):
    pass


# ---- format and calculation specs <-> JavaScript ---------------------------------------------------

def _q(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def format_js(spec):
    """'number:2:$' 'percent:1' 'date:mm/dd/yyyy' 'zip' 'zip4' 'phone' 'ssn' 'none' ->
    (format script, keystroke script) -- the standard functions every reader knows"""
    spec = (spec or "none").strip()
    kind, _, rest = spec.partition(":")
    args = rest.split(":") if rest else []
    if kind in ("", "none"):
        return None, None
    if kind == "number":
        dec = _int(args[0] if args else "2", 0, 10)
        cur = args[1] if len(args) > 1 else ""
        sep = _int(args[2], 0, 4) if len(args) > 2 else 0
        a = "%d, %d, 0, 0, %s, true" % (dec, sep, _q(cur))
        return "AFNumber_Format(%s);" % a, "AFNumber_Keystroke(%s);" % a
    if kind == "percent":
        dec = _int(args[0] if args else "0", 0, 10)
        return "AFPercent_Format(%d, 0);" % dec, "AFPercent_Keystroke(%d, 0);" % dec
    if kind == "date":
        pat = rest or "mm/dd/yyyy"
        if not re.fullmatch(r"[dmyHhMstT /.,:-]+", pat):
            raise FormError("not a date pattern: " + pat)
        return "AFDate_FormatEx(%s);" % _q(pat), "AFDate_KeystrokeEx(%s);" % _q(pat)
    special = {"zip": 0, "zip4": 1, "phone": 2, "ssn": 3}
    if kind in special:
        return "AFSpecial_Format(%d);" % special[kind], "AFSpecial_Keystroke(%d);" % special[kind]
    raise FormError("unknown format " + kind)


def format_spec(fmt_js):
    """the format script back to its spec ('' when there is none or it is not one of ours)"""
    s = fmt_js or ""
    m = re.search(r"AFNumber_Format\(\s*(\d+)\s*,\s*(\d+)\s*,\s*\d+\s*,\s*\d+\s*,\s*\"((?:[^\"\\]|\\.)*)\"", s)
    if m:
        return "number:%s:%s:%s" % (m.group(1), m.group(3).replace("\\", ""), m.group(2))
    m = re.search(r"AFPercent_Format\(\s*(\d+)", s)
    if m:
        return "percent:" + m.group(1)
    m = re.search(r"AFDate_Format(?:Ex)?\(\s*\"([^\"]*)\"", s)
    if m:
        return "date:" + m.group(1)
    m = re.search(r"AFDate_Format\(\s*(\d+)", s)
    if m:
        old = ["m/d", "m/d/yy", "mm/dd/yy", "mm/yy", "d-mmm", "d-mmm-yy", "dd-mmm-yy", "yy-mm-dd", "mmm-yy",
               "mmmm-yy", "mmm d, yyyy", "mmmm d, yyyy", "m/d/yy h:MM tt", "m/d/yy HH:MM"]
        k = int(m.group(1))
        return "date:" + (old[k] if k < len(old) else "mm/dd/yyyy")
    m = re.search(r"AFSpecial_Format\(\s*(\d)", s)
    if m:
        return ["zip", "zip4", "phone", "ssn"][min(3, int(m.group(1)))]
    return ""


OPS = {"sum": "SUM", "product": "PRD", "avg": "AVG", "min": "MIN", "max": "MAX"}


def calc_js(spec):
    """'sum:a,b,c' 'product:..' 'avg:..' 'min:..' 'max:..' 'expr:Qty * Price' 'none' -> calculate script"""
    spec = (spec or "none").strip()
    kind, _, rest = spec.partition(":")
    if kind in ("", "none"):
        return None
    if kind in OPS:
        names = [n.strip() for n in rest.split(",") if n.strip()]
        if not names:
            raise FormError("no fields to calculate from")
        return "AFSimple_Calculate(%s, new Array(%s));" % (_q(OPS[kind]), ", ".join(_q(n) for n in names))
    if kind == "expr":
        tokens = tokenize(rest)          # refuses what it cannot evaluate
        js = []
        for t, v in tokens:
            js.append("AFMakeNumber(getField(%s).value)" % _q(v) if t == "name" else v)
        return "/** BVCALC %s EVCALC **/ event.value = %s;" % (rest.strip(), " ".join(js))
    raise FormError("unknown calculation " + kind)


def calc_spec(js):
    s = js or ""
    m = re.search(r"BVCALC(.*?)EVCALC", s, re.S)
    if m:
        return "expr:" + " ".join(m.group(1).split())
    m = re.search(r"AFSimple_Calculate\(\s*\"(\w+)\"\s*,\s*(?:new\s+Array\s*\(([^)]*)\)|\[([^\]]*)\]|\"([^\"]*)\")", s)
    if m:
        op = {v: k for k, v in OPS.items()}.get(m.group(1).upper())
        if not op:
            return ""
        raw = m.group(2) if m.group(2) is not None else m.group(3) if m.group(3) is not None else None
        if raw is not None:
            names = re.findall(r"\"((?:[^\"\\]|\\.)*)\"", raw)
        else:
            names = [n.strip() for n in (m.group(4) or "").split(",")]
        return "%s:%s" % (op, ",".join(n.replace("\\", "") for n in names if n))
    return ""


def _int(s, lo, hi):
    try:
        v = int(s)
    except (TypeError, ValueError):
        raise FormError("not a number: %s" % s)
    return max(lo, min(hi, v))


# ---- simplified field notation ----------------------------------------------------------------------

_TOKEN = re.compile(r"\s*(?:(\d+(?:\.\d*)?|\.\d+)|([-+*/()])|((?:[A-Za-z_][\w.]*|\\.)(?:[\w.]|\\.)*))")


def tokenize(expr):
    out, pos = [], 0
    expr = expr.strip()
    if not expr:
        raise FormError("the formula is empty")
    while pos < len(expr):
        m = _TOKEN.match(expr, pos)
        if not m or m.end() == pos:
            raise FormError("the formula has something it cannot use at: " + expr[pos:pos + 12])
        if m.group(1):
            out.append(("num", m.group(1)))
        elif m.group(2):
            out.append(("op", m.group(2)))
        else:
            out.append(("name", m.group(3).replace("\\", "")))
        pos = m.end()
        while pos < len(expr) and expr[pos].isspace():
            pos += 1
    _Parser(out, lambda n: 0.0).parse()   # syntax check
    return out


class _Parser:
    def __init__(self, tokens, value_of):
        self.t, self.i, self.value_of = tokens, 0, value_of

    def parse(self):
        v = self.expr()
        if self.i != len(self.t):
            raise FormError("the formula does not end where it should")
        return v

    def peek(self):
        return self.t[self.i] if self.i < len(self.t) else (None, None)

    def expr(self):
        v = self.term()
        while self.peek() in (("op", "+"), ("op", "-")):
            op = self.t[self.i][1]
            self.i += 1
            w = self.term()
            v = v + w if op == "+" else v - w
        return v

    def term(self):
        v = self.factor()
        while self.peek() in (("op", "*"), ("op", "/")):
            op = self.t[self.i][1]
            self.i += 1
            w = self.factor()
            if op == "*":
                v = v * w
            else:
                v = v / w if w else 0.0
        return v

    def factor(self):
        t, v = self.peek()
        if t is None:
            raise FormError("the formula ends too soon")
        self.i += 1
        if t == "num":
            return float(v)
        if t == "name":
            return self.value_of(v)
        if v == "-":
            return -self.factor()
        if v == "+":
            return self.factor()
        if v == "(":
            r = self.expr()
            if self.peek() != ("op", ")"):
                raise FormError("a bracket is not closed")
            self.i += 1
            return r
        raise FormError("the formula has an operator where a value belongs")


# ---- values ---------------------------------------------------------------------------------------------

def make_number(s):
    """AFMakeNumber: '$1,234.50' -> 1234.5; '' -> None"""
    if s is None:
        return None
    if isinstance(s, (int, float)):
        return float(s)
    t = str(s).strip()
    if not t:
        return None
    neg = t.startswith("(") and t.endswith(")")
    t = re.sub(r"[^\d.,\-]", "", t)
    if t.count(",") and t.count("."):
        t = t.replace(",", "")
    elif t.count(",") == 1 and len(t.split(",")[1]) != 3:
        t = t.replace(",", ".")
    else:
        t = t.replace(",", "")
    try:
        v = float(t)
    except ValueError:
        return None
    return -abs(v) if neg else v


def _group(intpart, sep):
    s = intpart
    groups = []
    while len(s) > 3:
        groups.insert(0, s[-3:])
        s = s[:-3]
    groups.insert(0, s)
    return sep.join(groups)


def number_text(v, dec, sep_style=0, cur="", prepend=True):
    seps = {0: (",", "."), 1: ("", "."), 2: (".", ","), 3: ("", ","), 4: ("'", ".")}
    th, dp = seps.get(sep_style, (",", "."))
    neg = v < 0
    s = "%.*f" % (dec, abs(v))
    ip, _, fp = s.partition(".")
    out = _group(ip, th) + ((dp + fp) if dec > 0 else "")
    if cur:
        out = cur + out if prepend else out + cur
    return "-" + out if neg else out


MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
          "November", "December"]


def parse_date(s, pattern="mm/dd/yyyy"):
    """what a person types -> a date: the field's own pattern first (its order of day and month),
    then ISO, then month names"""
    t = (s or "").strip()
    if not t:
        return None
    m = re.fullmatch(r"(\d{4})-(\d{1,2})-(\d{1,2})", t)
    if m:
        return _mkdate(int(m.group(1)), int(m.group(2)), int(m.group(3)))
    nums = re.findall(r"\d+", t)
    words = re.findall(r"[A-Za-z]+", t)
    month_word = None
    for w in words:
        for i, name in enumerate(MONTHS):
            if len(w) >= 3 and name.lower().startswith(w.lower()):
                month_word = i + 1
    order = [c for c in re.findall(r"y+|m+|d+", pattern.lower()) if c[0] in "ymd"]
    order = [c[0] for c in order]
    if month_word:
        rest = [int(n) for n in nums]
        if len(rest) >= 2:
            d, y = (rest[0], rest[1]) if rest[0] <= 31 and order.index("d") < order.index("y") else (rest[1], rest[0])
            if rest[0] > 31:
                y, d = rest[0], rest[1]
            return _mkdate(_year(y), month_word, d)
        if len(rest) == 1:
            return _mkdate(datetime.date.today().year, month_word, rest[0])
        return None
    if len(nums) == 1 and len(nums[0]) == 8:
        n = nums[0]
        parts = {}
        k = 0
        for c in order:
            w = 4 if c == "y" else 2
            parts[c] = int(n[k:k + w])
            k += w
        return _mkdate(parts.get("y", 0), parts.get("m", 0), parts.get("d", 0))
    if len(nums) == 3:
        if len(nums[0]) == 4:
            return _mkdate(int(nums[0]), int(nums[1]), int(nums[2]))
        if len(nums[2]) == 4 or (order and order[0] == "y" and len(nums[0]) <= 2):
            # the year last: day and month in the pattern's order, or month first when the pattern
            # starts with the year
            md = [c for c in order if c != "y"]
            if not md or md[0] == "y" or order[0] == "y":
                md = ["m", "d"]
            a, b = int(nums[0]), int(nums[1])
            m, d = (a, b) if md[0] == "m" else (b, a)
            if m > 12 >= d:
                m, d = d, m
            return _mkdate(_year(int(nums[2])), m, d)
        parts = dict(zip(order, (int(x) for x in nums)))
        if len(parts) == 3:
            return _mkdate(_year(parts["y"]), parts["m"], parts["d"])
    if len(nums) == 2 and "y" in order and "d" not in order:
        parts = dict(zip(order, (int(x) for x in nums)))
        return _mkdate(_year(parts.get("y", 0)), parts.get("m", 0), 1)
    if len(nums) == 2 and "y" in order:
        o = [c for c in order if c != "y"]
        parts = dict(zip(o, (int(x) for x in nums)))
        return _mkdate(datetime.date.today().year, parts.get("m", 0), parts.get("d", 0))
    return None


def _year(y):
    return y + (2000 if y < 50 else 1900) if y < 100 else y


def _mkdate(y, m, d):
    try:
        return datetime.date(y, m, d)
    except ValueError:
        return None


def date_text(d, pattern):
    out = []
    for tok in re.findall(r"yyyy|yy|mmmm|mmm|mm|m|dddd|ddd|dd|d|[^ymd]+", pattern):
        if tok == "yyyy":
            out.append("%04d" % d.year)
        elif tok == "yy":
            out.append("%02d" % (d.year % 100))
        elif tok == "mmmm":
            out.append(MONTHS[d.month - 1])
        elif tok == "mmm":
            out.append(MONTHS[d.month - 1][:3])
        elif tok == "mm":
            out.append("%02d" % d.month)
        elif tok == "m":
            out.append(str(d.month))
        elif tok == "dddd":
            out.append(d.strftime("%A"))
        elif tok == "ddd":
            out.append(d.strftime("%a"))
        elif tok == "dd":
            out.append("%02d" % d.day)
        elif tok == "d":
            out.append(str(d.day))
        else:
            out.append(tok)
    return "".join(out)


def keystroke(spec, value):
    """a value typed into a field with this format -> the value stored (or FormError, as the
    familiar editor refuses an entry that does not match the field's format)"""
    if not spec or not value.strip():
        return value
    kind, _, rest = spec.partition(":")
    if kind in ("number", "percent"):
        v = make_number(value.replace("%", ""))
        if v is None:
            raise FormError("The value entered does not match the format of the field: a number is expected.")
        if kind == "percent" and "%" in value:
            v = v / 100.0
        return ("%.10f" % v).rstrip("0").rstrip(".")
    if kind == "date":
        pat = rest or "mm/dd/yyyy"
        d = parse_date(value, pat)
        if d is None:
            raise FormError("The date does not match the field's format (%s)." % pat)
        return date_text(d, pat)
    digits = re.sub(r"\D", "", value)
    if kind == "zip" and len(digits) == 5:
        return digits
    if kind == "zip4" and len(digits) == 9:
        return digits
    if kind == "phone" and len(digits) in (7, 10):
        return digits
    if kind == "ssn" and len(digits) == 9:
        return digits
    if kind in ("zip", "zip4", "phone", "ssn"):
        raise FormError("The value entered does not match the format of the field (%s)." % {
            "zip": "a 5-digit ZIP code", "zip4": "ZIP+4", "phone": "a phone number",
            "ssn": "a social security number"}[kind])
    return value


def display(spec, value):
    """the stored value as the field shows it"""
    if not spec or value is None or not str(value).strip():
        return value or ""
    kind, _, rest = spec.partition(":")
    args = rest.split(":") if rest else []
    if kind == "number":
        v = make_number(value)
        if v is None:
            return value
        return number_text(v, _int(args[0] if args else 2, 0, 10), _int(args[2], 0, 4) if len(args) > 2 else 0,
                           args[1] if len(args) > 1 else "")
    if kind == "percent":
        v = make_number(value)
        return value if v is None else number_text(v * 100, _int(args[0] if args else 0, 0, 10)) + "%"
    if kind == "date":
        d = parse_date(value, rest or "mm/dd/yyyy")
        return date_text(d, rest or "mm/dd/yyyy") if d else value
    d = re.sub(r"\D", "", str(value))
    if kind == "zip4" and len(d) == 9:
        return d[:5] + "-" + d[5:]
    if kind == "phone" and len(d) == 10:
        return "(%s) %s-%s" % (d[:3], d[3:6], d[6:])
    if kind == "phone" and len(d) == 7:
        return d[:3] + "-" + d[3:]
    if kind == "ssn" and len(d) == 9:
        return "%s-%s-%s" % (d[:3], d[3:5], d[5:])
    return value


# ---- reading a field's scripts --------------------------------------------------------------------------

def _aa_js(doc, xref, key):
    """the JavaScript of the field's /AA /<key> action (F format, K keystroke, C calculate)"""
    t, v = doc.xref_get_key(xref, "AA/%s/JS" % key)
    if t == "null":
        par = doc.xref_get_key(xref, "Parent")
        if par[0] == "xref":
            t, v = doc.xref_get_key(int(par[1].split()[0]), "AA/%s/JS" % key)
    if t == "string":
        return v
    if t == "xref":
        try:
            return doc.xref_stream(int(v.split()[0])).decode("latin-1")
        except Exception:
            return ""
    return ""


def field_specs(doc, w):
    return format_spec(_aa_js(doc, w.xref, "F")), calc_spec(_aa_js(doc, w.xref, "C"))


def tooltip(doc, w):
    t, v = doc.xref_get_key(w.xref, "TU")
    if t == "null":
        par = doc.xref_get_key(w.xref, "Parent")
        if par[0] == "xref":
            t, v = doc.xref_get_key(int(par[1].split()[0]), "TU")
    return v if t == "string" else ""


# ---- appearances that show the formatted value --------------------------------------------------------

def clear_value(doc, w):
    """an empty value (PyMuPDF takes "" for no change): a blank appearance, then /V emptied"""
    w.field_value = " "
    w.update()
    doc.xref_set_key(w.xref, "V", "()")


def show_value(doc, w, spec):
    """update the widget's appearance; with a format, it shows the formatted text while /V keeps
    the value itself"""
    raw = w.field_value
    if w.field_type == fitz.PDF_WIDGET_TYPE_TEXT and (raw is None or raw == ""):
        clear_value(doc, w)
        return
    if w.field_type == fitz.PDF_WIDGET_TYPE_TEXT and spec and raw:
        shown = display(spec, raw)
        if shown != raw:
            w.field_value = shown
            w.update()
            doc.xref_set_key(w.xref, "V", fitz.get_pdf_str(raw))
            return
    w.update()


# ---- calculation ------------------------------------------------------------------------------------------

def all_widgets(doc):
    for p in doc:
        for w in p.widgets():
            yield p, w


def recalc(doc, limit=200):
    """evaluate every calculated field in calculation order; returns the names changed"""
    widgets = list(all_widgets(doc))
    by_name = {}
    for p, w in widgets:
        by_name.setdefault(w.field_name or "", []).append((p, w))
    order = []
    cat = doc.pdf_catalog()
    t, v = doc.xref_get_key(cat, "AcroForm/CO")
    if t == "array":
        order = [int(x) for x in re.findall(r"(\d+) 0 R", v)]
    calc = []
    seen = set()
    for x in order:
        for p, w in widgets:
            if w.xref == x and w.xref not in seen:
                calc.append((p, w))
                seen.add(w.xref)
    for p, w in widgets:
        if w.xref not in seen and _aa_js(doc, w.xref, "C"):
            calc.append((p, w))
            seen.add(w.xref)
    values = {}
    for name, lst in by_name.items():
        values[name] = lst[0][1].field_value

    def value_of(name):
        v = values.get(name)
        if v is None:
            # a parent name: the first kid's value
            for k in values:
                if k.startswith(name + "."):
                    v = values[k]
                    break
        n = make_number(v if not isinstance(v, bool) else (1 if v else 0))
        return n if n is not None else 0.0

    changed = []
    for p, w in calc[:limit]:
        spec = calc_spec(_aa_js(doc, w.xref, "C"))
        if not spec:
            continue
        kind, _, rest = spec.partition(":")
        try:
            if kind == "expr":
                result = _Parser(tokenize(rest), value_of).parse()
            else:
                nums = []
                for n in rest.split(","):
                    raw = values.get(n.strip())
                    if raw is None:
                        raw = next((values[k] for k in values if k.startswith(n.strip() + ".")), None)
                    num = make_number(raw)
                    if num is not None:
                        nums.append(num)
                if kind == "sum":
                    result = sum(nums)
                elif kind == "product":
                    result = 1.0
                    for x in nums:
                        result *= x
                    if not nums:
                        result = 0.0
                elif kind == "avg":
                    result = sum(nums) / len(nums) if nums else 0.0
                elif kind == "min":
                    result = min(nums) if nums else 0.0
                else:
                    result = max(nums) if nums else 0.0
        except (FormError, OverflowError, ZeroDivisionError):
            continue
        text = ("%.10f" % result).rstrip("0").rstrip(".")
        if text == "-0":
            text = "0"
        if (w.field_value or "") != text:
            w.field_value = text
            show_value(doc, w, format_spec(_aa_js(doc, w.xref, "F")))
            changed.append(w.field_name)
        values[w.field_name or ""] = text
    return changed


# ---- making fields ---------------------------------------------------------------------------------------------

def unique_name(doc, base):
    names = {w.field_name for _, w in all_widgets(doc)}
    if base not in names:
        return base
    k = 2
    while "%s_%d" % (base, k) in names:
        k += 1
    return "%s_%d" % (base, k)


def auto_name(doc, kind):
    names = {w.field_name for _, w in all_widgets(doc)}
    base = BASE_NAMES.get(kind, "Field")
    k = 1
    while "%s%d" % (base, k) in names:
        k += 1
    return "%s%d" % (base, k)


def _bool(o, k):
    return o.get(k) in ("1", "true", "yes")


def apply_props(doc, page, w, o, kind=None):
    """properties from key=value options onto a widget (before or after it is added)"""
    if "name" in o:
        name = o["name"].strip()
        if not name:
            raise FormError("a field needs a name")
        if "\t" in name or "\n" in name:
            raise FormError("a field name is one line")
        w.field_name = name
    if "label" in o:
        w.field_label = o["label"]
    flags = w.field_flags or 0
    for key, bit in (("readonly", FLAG_READONLY), ("required", FLAG_REQUIRED), ("multiline", FLAG_MULTILINE)):
        if key in o:
            flags = (flags | bit) if _bool(o, key) else (flags & ~bit)
    w.field_flags = flags
    if "fontsize" in o:
        try:
            w.text_fontsize = max(0.0, min(72.0, float(o["fontsize"] or 0)))
        except ValueError:
            raise FormError("not a font size")
    if "maxlen" in o and w.field_type == fitz.PDF_WIDGET_TYPE_TEXT:
        w.text_maxlen = _int(o["maxlen"] or "0", 0, 100000)
    if "options" in o and w.field_type in (fitz.PDF_WIDGET_TYPE_COMBOBOX, fitz.PDF_WIDGET_TYPE_LISTBOX):
        opts = [x for x in o["options"].split("\n") if x.strip()]
        if not opts:
            raise FormError("a list needs at least one choice")
        w.choice_values = opts
    if "align" in o and w.field_type == fitz.PDF_WIDGET_TYPE_TEXT:
        w.text_format = 0
    fmt = o.get("format")
    calc = o.get("calc")
    if kind == "date" and fmt is None:
        fmt = "date:mm/dd/yyyy"
    if kind == "number" and fmt is None:
        fmt = "number:2"
    if fmt is not None:
        f, k = format_js(fmt)
        w.script_format = f or ""
        w.script_stroke = k or ""
    if calc is not None:
        w.script_calc = calc_js(calc) or ""
    if "value" in o:
        w.field_value = o["value"]
    return w


def _set_tooltip_align(doc, xref, o):
    if "tooltip" in o:
        doc.xref_set_key(xref, "TU", fitz.get_pdf_str(o["tooltip"]) if o["tooltip"] else "null")
    if "align" in o:
        q = {"left": 0, "center": 1, "right": 2, "0": 0, "1": 1, "2": 2}.get(o["align"], 0)
        doc.xref_set_key(xref, "Q", str(q))
    if "default" in o:
        doc.xref_set_key(xref, "DV", fitz.get_pdf_str(o["default"]) if o["default"] else "null")


def add_field(doc, page, kind, rect, o):
    if kind not in KINDS:
        raise FormError("unknown kind of field " + kind)
    r = fitz.Rect(rect)
    if r.is_empty or r.width < 4 or r.height < 4:
        raise FormError("the field is too small")
    w = fitz.Widget()
    w.field_type = KINDS[kind]
    w.rect = r
    w.field_name = o.get("name") or auto_name(doc, kind)
    if w.field_name in {x.field_name for _, x in all_widgets(doc)} and kind != "radio":
        raise FormError("there is already a field called %s" % w.field_name)
    w.text_font = "Helv"
    w.text_fontsize = 0 if kind in ("text", "date", "number") and r.height > 30 else min(12, max(6, r.height * 0.6))
    w.border_color = (0.45, 0.5, 0.6)
    w.border_width = 1
    if kind in ("checkbox", "radio"):
        w.text_fontsize = 0
        w.button_caption = None
        w.field_value = False
        if kind == "radio":
            w.field_value = False
    if kind in ("combo", "list"):
        w.choice_values = [x for x in o.get("options", "").split("\n") if x.strip()] or ["Choice 1", "Choice 2"]
    if kind == "signature":
        w.border_color = (0.2, 0.3, 0.6)
    if o.get("border") == "0":
        # a field made over a blank the page draws itself (a rule, a box, a cell): no border of its own
        w.border_width = 0
        w.border_color = None
    o = dict(o)
    o.pop("border", None)
    o.pop("name", None)
    apply_props(doc, page, w, o, kind)
    annot = page.add_widget(w)
    xref = annot.xref
    if kind == "signature":
        # unsigned, the field shows nothing on the page (MuPDF draws "SIGN" in it)
        ap = doc.get_new_xref()
        doc.update_object(ap, "<</Type/XObject/Subtype/Form/BBox[0 0 %g %g]/Resources<<>>>>" % (r.width, r.height))
        doc.update_stream(ap, b" ")
        doc.xref_set_key(xref, "AP", "<</N %d 0 R>>" % ap)
    if kind == "radio" and o.get("export"):
        _set_export(doc, xref, o["export"])
    _set_tooltip_align(doc, xref, o)
    if kind == "radio":
        _join_radio_group(doc, page, xref)
    return xref


def _set_export(doc, xref, value):
    """a check box's or radio button's on-state name"""
    name = re.sub(r"[^A-Za-z0-9_.-]", "_", value) or "On"
    for k in ("AP/N", "AP/D"):
        t, v = doc.xref_get_key(xref, k)
        if t == "dict":
            states = re.findall(r"/([^\s/<>\[\]()]+)\s", v)
            on = [s for s in states if s != "Off"]
            if on and on[0] != name:
                doc.xref_set_key(xref, k, v.replace("/" + on[0] + " ", "/" + name + " ", 1))


def _join_radio_group(doc, page, xref):
    """radio buttons with one name are one group: MuPDF makes each its own field, so they are
    made kids of one parent field"""
    t, name = doc.xref_get_key(xref, "T")
    if t != "string":
        return
    mates = []
    for p in doc:
        for w in p.widgets(types=[fitz.PDF_WIDGET_TYPE_RADIOBUTTON]):
            if w.xref != xref and w.field_name == name:
                mates.append(w.xref)
    if not mates:
        return
    other = mates[0]
    par = doc.xref_get_key(other, "Parent")
    cat = doc.pdf_catalog()
    if par[0] == "xref":
        parent = int(par[1].split()[0])
    else:
        parent = doc.get_new_xref()
        doc.update_object(parent, "<</FT/Btn/Ff %d/T %s/Kids[%d 0 R]/V/Off>>" % (
            (1 << 15) | (1 << 14), fitz.get_pdf_str(name), other))
        for k in ("T", "FT", "Ff", "V"):
            doc.xref_set_key(other, k, "null")
        doc.xref_set_key(other, "Parent", "%d 0 R" % parent)
        _replace_in_fields(doc, cat, other, parent)
    kids = doc.xref_get_key(parent, "Kids")[1]
    doc.xref_set_key(parent, "Kids", kids.rstrip("]") + " %d 0 R]" % xref)
    for k in ("T", "FT", "Ff", "V"):
        doc.xref_set_key(xref, k, "null")
    doc.xref_set_key(xref, "Parent", "%d 0 R" % parent)
    _replace_in_fields(doc, cat, xref, None)


def _replace_in_fields(doc, cat, old, new):
    t, v = doc.xref_get_key(cat, "AcroForm/Fields")
    if t != "array":
        return
    refs = re.findall(r"(\d+) 0 R", v)
    out = []
    for r in refs:
        r = int(r)
        if r == old:
            if new is not None and new not in out:
                out.append(new)
        elif r not in out:
            out.append(r)
    doc.xref_set_key(cat, "AcroForm/Fields", "[" + " ".join("%d 0 R" % r for r in out) + "]")


def delete_field(doc, page, xref):
    w = next((w for w in page.widgets() if w.xref == xref), None)
    if w is None:
        raise FormError("no such field")
    par = doc.xref_get_key(xref, "Parent")
    page.delete_widget(w)
    if par[0] == "xref":
        parent = int(par[1].split()[0])
        t, kids = doc.xref_get_key(parent, "Kids")
        refs = [int(r) for r in re.findall(r"(\d+) 0 R", kids) if int(r) != xref]
        doc.xref_set_key(parent, "Kids", "[" + " ".join("%d 0 R" % r for r in refs) + "]")
        if not refs:
            _replace_in_fields(doc, doc.pdf_catalog(), parent, None)
    # the calculation order no longer names it
    cat = doc.pdf_catalog()
    t, v = doc.xref_get_key(cat, "AcroForm/CO")
    if t == "array":
        refs = [int(r) for r in re.findall(r"(\d+) 0 R", v) if int(r) != xref]
        doc.xref_set_key(cat, "AcroForm/CO", "[" + " ".join("%d 0 R" % r for r in refs) + "]" if refs else "null")


def set_calc_order(doc):
    """every field with a calculation in /CO, in the order they were (new ones last)"""
    cat = doc.pdf_catalog()
    t, v = doc.xref_get_key(cat, "AcroForm/CO")
    old = [int(r) for r in re.findall(r"(\d+) 0 R", v)] if t == "array" else []
    has = [w.xref for _, w in all_widgets(doc) if _aa_js(doc, w.xref, "C")]
    order = [x for x in old if x in has] + [x for x in has if x not in old]
    doc.xref_set_key(cat, "AcroForm/CO", "[" + " ".join("%d 0 R" % r for r in order) + "]" if order else "null")


def props_of(doc, page, w):
    fmt, calc = field_specs(doc, w)
    kind = {fitz.PDF_WIDGET_TYPE_TEXT: "text", fitz.PDF_WIDGET_TYPE_CHECKBOX: "checkbox",
            fitz.PDF_WIDGET_TYPE_RADIOBUTTON: "radio", fitz.PDF_WIDGET_TYPE_COMBOBOX: "combo",
            fitz.PDF_WIDGET_TYPE_LISTBOX: "list", fitz.PDF_WIDGET_TYPE_SIGNATURE: "signature",
            fitz.PDF_WIDGET_TYPE_BUTTON: "button"}.get(w.field_type, "other")
    if kind == "text" and fmt.startswith("date"):
        kind = "date"
    elif kind == "text" and fmt.startswith("number"):
        kind = "number"
    flags = w.field_flags or 0
    t, q = doc.xref_get_key(w.xref, "Q")
    t2, dv = doc.xref_get_key(w.xref, "DV")
    opts = w.choice_values or []
    opts = [x if isinstance(x, str) else (x[1] if len(x) > 1 else x[0]) for x in opts]
    export = ""
    if w.field_type in (fitz.PDF_WIDGET_TYPE_CHECKBOX, fitz.PDF_WIDGET_TYPE_RADIOBUTTON):
        try:
            export = str(w.on_state() or "")
        except Exception:
            export = ""
    return {
        "kind": kind, "name": w.field_name or "", "tooltip": tooltip(doc, w),
        "required": "1" if flags & FLAG_REQUIRED else "0", "readonly": "1" if flags & FLAG_READONLY else "0",
        "multiline": "1" if flags & FLAG_MULTILINE else "0", "maxlen": str(w.text_maxlen or 0),
        "fontsize": "%g" % (w.text_fontsize or 0), "align": q if t == "int" else "0",
        "default": dv if t2 == "string" else "", "options": "\n".join(opts),
        "format": fmt, "calc": calc, "export": export,
        "value": "" if w.field_value in (None, False) else str(w.field_value),
    }


# ---- finding the fields a flat page suggests ----------------------------------------------------------------

DATE_WORDS = re.compile(r"\b(date|dob|birth|d\.o\.b|dated|expir|issued)\b", re.I)
SIGN_WORDS = re.compile(r"\b(signature|signed|sign here|sign)\b", re.I)
NUMBER_WORDS = re.compile(r"\b(amount|total|price|cost|qty|quantity|sum|fee|subtotal|tax|balance|\$)\b", re.I)


def _name_from(label):
    lab = re.sub(r"[_.:…]+$", "", " ".join((label or "").split())).strip(" :*#()[]")
    lab = re.sub(r"[^\w /&'-]", "", lab).strip()
    if len(lab) > 40:
        lab = lab[:40].rsplit(" ", 1)[0]
    return lab


def _kind_for(label):
    if SIGN_WORDS.search(label or ""):
        return "signature"
    if DATE_WORDS.search(label or ""):
        return "date"
    return "text"


def _overlaps(r, rects, frac=0.3):
    for o in rects:
        i = fitz.Rect(r) & o
        if not i.is_empty and i.get_area() > frac * min(r.get_area(), o.get_area()):
            return True
    return False


def detect(page):
    """candidate fields on a page: [(kind, rect, name)] in reading order, on the unrotated page"""
    words = page.get_text("words")   # x0 y0 x1 y1 word block line wno
    wrects = [fitz.Rect(w[:4]) for w in words]
    found = []
    taken = [fitz.Rect(w.rect) for w in page.widgets()]

    def label_left(r, maxgap=220):
        """the words just left of r on its line, read as a label"""
        cands = [w for w in words if w[2] <= r.x0 + 2 and r.x0 - w[2] < maxgap and
                 abs((w[1] + w[3]) / 2 - (r.y0 + r.y1) / 2) < max(8, r.height * 0.8) and "___" not in w[4]]
        if not cands:
            return ""
        cands.sort(key=lambda w: w[0])
        # the run of words ending nearest r
        run = [cands[-1]]
        for w in reversed(cands[:-1]):
            if run[0][0] - w[2] < 12:
                run.insert(0, w)
            else:
                break
        return " ".join(w[4] for w in run)

    def label_above(r, maxgap=16):
        cands = [w for w in words if w[3] <= r.y0 + 2 and r.y0 - w[3] < maxgap and w[0] < r.x1 and w[2] > r.x0]
        if not cands:
            return ""
        y = max(w[3] for w in cands)
        return " ".join(w[4] for w in sorted(cands, key=lambda w: w[0]) if abs(w[3] - y) < 3)

    def label_below(r):
        cands = [w for w in words if w[1] >= r.y1 - 1 and w[1] - r.y1 < 12 and w[0] < r.x1 and w[2] > r.x0]
        if not cands:
            return ""
        y = min(w[1] for w in cands)
        return " ".join(w[4] for w in sorted(cands, key=lambda w: w[0]) if abs(w[1] - y) < 3)

    def add(kind, r, label):
        r = fitz.Rect(r)
        if r.width < 6 or r.height < 6 or _overlaps(r, taken):
            return
        if kind not in ("checkbox",):
            kind = kind if kind != "text" else _kind_for(label)
            if kind == "text" and NUMBER_WORDS.search(label or ""):
                kind = "number:0" if re.search(r"\b(qty|quantity)\b", label, re.I) else "number"
        found.append((kind, r, _name_from(label)))
        taken.append(r)

    # 1. blanks typed as underscores: "Name: ________"
    chars_done = False
    for b in page.get_text("rawdict")["blocks"]:
        for ln in b.get("lines", []):
            for sp in ln.get("spans", []):
                chars = sp.get("chars", [])
                i = 0
                while i < len(chars):
                    if chars[i]["c"] == "_":
                        j = i
                        while j + 1 < len(chars) and chars[j + 1]["c"] == "_":
                            j += 1
                        if j - i >= 2:
                            x0, x1 = chars[i]["bbox"][0], chars[j]["bbox"][2]
                            base = sp["bbox"][3]
                            h = max(12.0, min(22.0, sp["size"] * 1.4))
                            r = fitz.Rect(x0, base - h, x1, base + 1)
                            lab = "".join(c["c"] for c in chars[:i]).strip()
                            if not lab.strip("_ "):
                                lab = label_left(r)
                            add("text", r, lab.split("  ")[-1] if lab else label_below(r))
                        i = j + 1
                    else:
                        i += 1
        chars_done = True
    del chars_done

    # 2. rules and boxes drawn as vector art
    hlines, boxes = [], []
    for d in page.get_drawings():
        for it in d.get("items", []):
            if it[0] == "l":
                a, b2 = it[1], it[2]
                if abs(a.y - b2.y) < 1.0 and abs(a.x - b2.x) >= 36:
                    hlines.append(fitz.Rect(min(a.x, b2.x), a.y, max(a.x, b2.x), a.y))
            elif it[0] == "re":
                r = fitz.Rect(it[1])
                if r.height <= 1.6 and r.width >= 36:
                    hlines.append(fitz.Rect(r.x0, r.y1, r.x1, r.y1))
                elif r.width >= 5 and r.height >= 5:
                    boxes.append(r)
            elif it[0] == "qu":
                r = it[1].rect
                if r.width >= 5 and r.height >= 5:
                    boxes.append(r)
    # small squares: check boxes
    page_area = page.rect.get_area()
    for r in boxes:
        if 6 <= r.width <= 20 and 6 <= r.height <= 20 and 0.75 <= r.width / r.height <= 1.33:
            if not any(fitz.Rect(w) in r for w in wrects):
                lab = label_left(fitz.Rect(r.x0, r.y0, r.x0, r.y1), 0)
                right = [w for w in words if w[0] >= r.x1 - 1 and w[0] - r.x1 < 14 and
                         abs((w[1] + w[3]) / 2 - (r.y0 + r.y1) / 2) < 8]
                if right:
                    right.sort(key=lambda w: w[0])
                    run = [right[0]]
                    for w in words:
                        if w not in run and w[1] == right[0][1] and 0 <= w[0] - run[-1][2] < 8:
                            run.append(w)
                    lab = " ".join(w[4] for w in run)
                add("checkbox", r, lab or "Check Box")
    # box glyphs typed as text
    for w in words:
        if w[4] in ("☐", "□", "❏", "❑", "▢"):
            r = fitz.Rect(w[:4])
            nxt = [x for x in words if x[0] >= r.x1 and x[0] - r.x1 < 12 and abs(x[1] - w[1]) < 3]
            add("checkbox", r, nxt[0][4] if nxt else "Check Box")
    # rules: a blank to write on, unless text sits on it (an underline)
    for r in hlines:
        on = [w for w in wrects if abs(w.y1 - r.y0) < 4 and min(w.x1, r.x1) - max(w.x0, r.x0) > 0.3 * r.width]
        if on:
            continue
        h = 16.0
        above = [w for w in wrects if w.y1 <= r.y0 - 1 and r.y0 - w.y1 < h and w.x0 < r.x1 and w.x1 > r.x0]
        if above:
            h = max(10.0, r.y0 - max(w.y1 for w in above) - 1)
        fr = fitz.Rect(r.x0, r.y0 - h, r.x1, r.y0 + 0.5)
        lab = label_left(fr) or label_below(fitz.Rect(r.x0, r.y0, r.x1, r.y0 + 1))
        add("text", fr, lab)
    # empty boxes and table cells: text fields (a short label inside on the left or top keeps its place)
    for r in boxes:
        if r.width < 40 or not (12 <= r.height <= 120) or r.get_area() > 0.25 * page_area:
            continue
        inside = [w for w in words if fitz.Rect(w[:4]).intersects(r) and fitz.Rect(w[:4]).get_area() > 0]
        if any(b2 != r and b2 in r and b2.get_area() < r.get_area() * 0.9 and b2.width > 5 for b2 in boxes):
            continue   # a box holding other boxes is a frame
        if not inside:
            add("text", fitz.Rect(r.x0 + 1, r.y0 + 1, r.x1 - 1, r.y1 - 1),
                label_above(r) or label_left(r, 40) or label_above(r, 160))
        else:
            ys = {round(w[1]) for w in inside}
            right = max(w[2] for w in inside)
            if len(ys) == 1 and r.x1 - right > 60 and len(inside) <= 6:
                add("text", fitz.Rect(right + 4, r.y0 + 1, r.x1 - 1, r.y1 - 1), " ".join(w[4] for w in inside))
            elif len(ys) == 1 and min(w[1] for w in inside) - r.y0 < 6 and r.y1 - max(w[3] for w in inside) > 12 \
                    and len(inside) <= 6:
                top = max(w[3] for w in inside)
                add("text", fitz.Rect(r.x0 + 1, top + 1, r.x1 - 1, r.y1 - 1), " ".join(w[4] for w in inside))
    # labels ending in a colon with room after them on their line
    for k, w in enumerate(words):
        if not w[4].endswith(":") or len(w[4]) < 3:
            continue
        line = [x for x in words if x[5] == w[5] and x[6] == w[6]]
        after = [x for x in line if x[0] > w[2]]
        limit = min((x[0] for x in after), default=page.rect.x1 - 36)
        if limit - w[2] < 90:
            continue
        lab_words = [x for x in line if x[0] <= w[0] and w[0] - x[2] < 60]
        r = fitz.Rect(w[2] + 4, w[1] - 2, limit - 6, w[3] + 3)
        add("text", r, " ".join(x[4] for x in sorted(lab_words, key=lambda x: x[0])))
    found.sort(key=lambda f: (round(f[1].y0 / 4), f[1].x0))
    return found
