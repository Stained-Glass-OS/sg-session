# sgpdf_content -- a small PDF content-stream tokenizer, for the edits
# MuPDF has no call for: taking one image's "Do" out of a page (moving or
# deleting that image and nothing else) and taking the marked content of a
# hidden layer out of a page ("remove hidden information").
#
# Copyright (C) 2026 Stained Glass OS contributors
# SPDX-License-Identifier: AGPL-3.0-or-later

WS = b" \t\r\n\f\x00"
DELIM = b"()<>[]{}/%"


class Tok:
    __slots__ = ("start", "end", "kind", "value")

    def __init__(self, start, end, kind, value):
        self.start, self.end, self.kind, self.value = start, end, kind, value

    def __repr__(self):
        return "Tok(%d,%d,%s,%r)" % (self.start, self.end, self.kind, self.value)


def tokenize(data):
    """Every token of a content stream: kinds num, name, str, hex, [, ], <<,
    >>, op (value: the operator's bytes) and img (an inline image, BI..EI)."""
    out = []
    i, n = 0, len(data)
    while i < n:
        c = data[i:i + 1]
        if c in WS:
            i += 1
            continue
        if c == b"%":
            while i < n and data[i:i + 1] not in b"\r\n":
                i += 1
            continue
        s = i
        if c == b"(":
            depth, i = 1, i + 1
            while i < n and depth:
                ch = data[i:i + 1]
                if ch == b"\\":
                    i += 2
                    continue
                if ch == b"(":
                    depth += 1
                elif ch == b")":
                    depth -= 1
                i += 1
            out.append(Tok(s, i, "str", data[s:i]))
            continue
        if c == b"<":
            if data[i + 1:i + 2] == b"<":
                out.append(Tok(s, i + 2, "<<", b"<<"))
                i += 2
                continue
            e = data.find(b">", i)
            i = n if e < 0 else e + 1
            out.append(Tok(s, i, "hex", data[s:i]))
            continue
        if c == b">" and data[i + 1:i + 2] == b">":
            out.append(Tok(s, i + 2, ">>", b">>"))
            i += 2
            continue
        if c in (b"[", b"]", b"{", b"}"):
            out.append(Tok(s, i + 1, c.decode(), c))
            i += 1
            continue
        if c == b"/":
            i += 1
            while i < n and data[i:i + 1] not in WS and data[i:i + 1] not in DELIM:
                i += 1
            out.append(Tok(s, i, "name", data[s + 1:i]))
            continue
        while i < n and data[i:i + 1] not in WS and data[i:i + 1] not in DELIM:
            i += 1
        if i == s:          # a stray delimiter such as ')' or '>'
            i += 1
            continue
        word = data[s:i]
        if word[:1] in b"+-.0123456789" and all(ch in b"+-.0123456789" for ch in word):
            out.append(Tok(s, i, "num", word))
            continue
        if word == b"BI":
            # an inline image: its dictionary, ID, binary data, EI
            j = data.find(b"ID", i)
            if j < 0:
                out.append(Tok(s, n, "img", b""))
                i = n
                continue
            k = j + 3
            while True:
                e = data.find(b"EI", k)
                if e < 0:
                    e = n
                    break
                before = data[e - 1:e]
                after = data[e + 2:e + 3]
                if before in WS and (after == b"" or after in WS):
                    break
                k = e + 2
            i = min(n, e + 2)
            out.append(Tok(s, i, "img", b""))
            continue
        out.append(Tok(s, i, "op", word))
    return out


def operations(toks):
    """(operands, operator token) pairs, in order."""
    ops, args = [], []
    depth = 0
    for t in toks:
        if t.kind in ("[", "<<"):
            depth += 1
        elif t.kind in ("]", ">>"):
            depth -= 1
        if t.kind == "op" and depth <= 0:
            ops.append((args, t))
            args = []
            depth = 0
        elif t.kind == "img":
            ops.append(([], t))
            args = []
        else:
            args.append(t)
    return ops


def remove_do(data, name, occurrence):
    """The content without the occurrence-th (0-based) "/name Do"; None if
    there is no such occurrence."""
    k = 0
    for args, op in operations(tokenize(data)):
        if op.value == b"Do" and args and args[-1].kind == "name" and args[-1].value == name:
            if k == occurrence:
                return data[:args[-1].start] + data[op.end:]
            k += 1
    return None


def count_do(data, name):
    return sum(1 for args, op in operations(tokenize(data))
               if op.value == b"Do" and args and args[-1].kind == "name" and args[-1].value == name)


def remove_marked(data, hidden_props, hidden_xobjects=()):
    """The content without marked-content sections "/OC /Prop BDC ... EMC"
    whose Prop is in hidden_props, and without "/X Do" for X in
    hidden_xobjects. Returns (new data, sections removed)."""
    ops = operations(tokenize(data))
    cut = []            # (start, end) byte ranges to drop
    stack = []          # for each open BMC/BDC: its start if hidden else None
    removed = 0
    for args, op in ops:
        v = op.value
        if v in (b"BMC", b"BDC"):
            hidden = False
            if v == b"BDC" and len(args) >= 2 and args[0].kind == "name" and args[0].value == b"OC" \
                    and args[1].kind == "name" and args[1].value in hidden_props:
                hidden = True
            start = args[0].start if args else op.start
            stack.append(start if hidden else None)
        elif v == b"EMC":
            if stack:
                s = stack.pop()
                if s is not None and all(x is None for x in stack):
                    cut.append((s, op.end))
                    removed += 1
        elif v == b"Do" and args and args[-1].kind == "name" and args[-1].value in hidden_xobjects:
            if all(x is None for x in stack):
                cut.append((args[-1].start, op.end))
                removed += 1
    if not cut:
        return data, 0
    out, last = [], 0
    for s, e in sorted(cut):
        if s < last:
            continue
        out.append(data[last:s])
        last = e
    out.append(data[last:])
    return b" ".join(out), removed


def remove_invisible_text(data):
    """The content without text shown in render mode 3 (invisible: hidden
    text, as an OCR layer or a hidden note carries). ' and " keep their move
    to the next line. Returns (new data, text operators removed)."""
    ops = operations(tokenize(data))
    tr, stack, cut = 0, [], []
    for args, op in ops:
        v = op.value
        if v == b"q":
            stack.append(tr)
        elif v == b"Q":
            tr = stack.pop() if stack else 0
        elif v == b"Tr" and args and args[-1].kind == "num":
            try:
                tr = int(float(args[-1].value))
            except ValueError:
                pass
        elif v in (b"Tj", b"TJ", b"'", b'"') and tr == 3:
            start = args[0].start if args else op.start
            rep = b""
            if v == b"'":
                rep = b"T*"
            elif v == b'"' and len(args) >= 3:
                rep = args[0].value + b" Tw " + args[1].value + b" Tc T*"
            cut.append((start, op.end, rep))
    if not cut:
        return data, 0
    out, last = [], 0
    for s, e, rep in cut:
        out.append(data[last:s])
        out.append(rep)
        last = e
    out.append(data[last:])
    return b" ".join(out), len(cut)
