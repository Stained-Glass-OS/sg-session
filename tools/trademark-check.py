#!/usr/bin/env python3
# trademark-check: no user-visible "Windows" in our own text.
#
# "Windows" is Microsoft's trademark; Stained Glass OS must never present
# itself as Windows. This scans the text a person can see -- string literals
# in C and resource scripts, the data of .reg files, .desktop Name/Comment,
# manifest descriptions, messages in Python and shell tools, and the lines
# wine-sg's patches ADD -- for the word "Windows" (capital W) and fails on any
# that is not a technical identifier or explicitly allowed -- and the same for
# Microsoft's feature names ("User Account Control", "SmartScreen", ...), and,
# with --brand, another word in the files it names ("Wine" in the dialogs the
# shell shows as its own: its Run dialog said "Wine will open it for you").
#
# Technical identifiers pass by themselves: a registry or file path (the word
# next to a backslash or slash: Software\Microsoft\Windows\..., C:\Windows,
# %windir%), a dotted name (Microsoft.Windows.Common-Controls,
# Windows.Foundation.Uri), and anything in comments, which are not scanned.
# Everything else needs an entry in the allowlist, one per line:
#
#     PATH-GLOB <TAB> PHRASE-REGEX <TAB> reason
#
# matched against the file (relative to the repository) and the string.
#
#   tools/trademark-check.py [--allow FILE] [--patches DIR] [--root DIR]
#                            [--brand GLOB WORD]... PATH...
#   (--root: paths are named, and matched, relative to DIR -- a Wine tree)
#   (directories are walked; test/ trees and generated build/ trees are skipped)
#
# Exit 0 clean, 1 with a line per finding: FILE:LINE: "string".
#
# SPDX-License-Identifier: AGPL-3.0-or-later OR LGPL-2.1-or-later
import fnmatch
import io
import os
import re
import sys
import tokenize

WORD = re.compile(r"(?<![A-Za-z0-9_])Windows(?![A-Za-z0-9_])")
# Microsoft's feature names: as much a slip as "Windows" when we use them
# for our own things (the consent prompt was titled "User Account Control")
FEATURES = re.compile(r"(?<![A-Za-z0-9_])(User Account Control|SmartScreen|Cortana|BitLocker|OneDrive)(?![A-Za-z0-9_])")


def technical(s, m):
    """The occurrence at m is part of a path or a dotted identifier."""
    before = s[m.start() - 1] if m.start() > 0 else ""
    after = s[m.end()] if m.end() < len(s) else ""
    after2 = s[m.end():m.end() + 2]
    if (before and before in "\\/") or (after and after in "\\/") or after2 == " \\" \
            or (after2 == " N" and "\\" in s):
        return True       # a path: ...\Windows\..., ...\Windows NT\..., C:/Windows
    if before == "." or (after == "." and m.end() + 1 < len(s) and s[m.end() + 1].isalpha()):
        return True       # Microsoft.Windows.Common-Controls, Windows.Foundation
    if before == "-" or after == "-":
        return True       # Microsoft-Windows-Security-Auditing (an event provider's name)
    if before == "_" or after == "_":
        return True
    return False


def findings_in(s, brand=None):
    """The occurrences of "Windows" and Microsoft's feature names -- and, with
    brand, that word too (Wine, in the dialogs our shell shows as its own) --
    that are not technical identifiers."""
    hits = [m for m in WORD.finditer(s) if not technical(s, m)]
    hits += [m for m in FEATURES.finditer(s) if not technical(s, m)]
    if brand:
        hits += [m for m in brand.finditer(s) if not technical(s, m)]
    return hits


# ---- extractors: (line, text) of what a person may see ---------------------------------

def c_strings(text):
    """String literals of C/C++/resource-script text, comments removed."""
    out, i, n, line = [], 0, len(text), 1
    while i < n:
        c = text[i]
        if c == "\n":
            line += 1; i += 1
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2); j = n if j < 0 else j + 2
            line += text.count("\n", i, j); i = j
        elif text.startswith("//", i):
            j = text.find("\n", i); i = n if j < 0 else j
        elif c == "'":
            j = i + 1
            while j < n and text[j] != "'" and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            i = j + 1
        elif c == '"':
            j, buf = i + 1, []
            while j < n and text[j] != '"' and text[j] != "\n":
                if text[j] == "\\" and j + 1 < n:
                    buf.append(text[j:j + 2]); j += 2
                else:
                    buf.append(text[j]); j += 1
            out.append((line, "".join(buf)))
            i = j + 1
        elif c == "#" and (i == 0 or text[i - 1] == "\n"):
            # preprocessor lines: #include "x" / #pragma -- but #define values are code
            j = text.find("\n", i); j = n if j < 0 else j
            directive = text[i:j]
            if directive.lstrip("# ").startswith("define"):
                i += 1
            else:
                i = j
        else:
            i += 1
    return out


def py_strings(text):
    out, prev = [], None
    try:
        toks = list(tokenize.generate_tokens(io.StringIO(text).readline))
    except (tokenize.TokenError, SyntaxError, IndentationError):
        return out
    for k, t in enumerate(toks):
        if t.type == tokenize.STRING:
            # a docstring: a string that is a statement of its own
            if prev in (None, tokenize.NEWLINE, tokenize.INDENT, tokenize.DEDENT, tokenize.NL) and \
                    k + 1 < len(toks) and toks[k + 1].type in (tokenize.NEWLINE, tokenize.ENDMARKER):
                prev = t.type
                continue
            body = t.string.lstrip("rRbBuUfF")
            q = body[:3] if body[:3] in ('"""', "'''") else body[:1]
            out.append((t.start[0], body[len(q):len(body) - len(q)] if body.endswith(q) else body))
        if t.type not in (tokenize.COMMENT, tokenize.NL):
            prev = t.type
    return out


def sh_strings(text):
    out = []
    for no, raw in enumerate(text.split("\n"), 1):
        line = raw.strip()
        if line.startswith("#"):
            continue
        for m in re.finditer(r'"((?:[^"\\]|\\.)*)"|\'([^\']*)\'', raw):
            out.append((no, m.group(1) if m.group(1) is not None else m.group(2)))
    return out


def reg_strings(text):
    out = []
    for no, raw in enumerate(text.split("\n"), 1):
        line = raw.strip()
        if not line or line.startswith(";") or line.startswith("["):
            continue
        m = re.match(r'("(?:[^"\\]|\\.)*"|@)\s*=\s*(.*)$', line)
        if m and m.group(2).startswith('"'):
            out.append((no, m.group(2)))
    return out


def desktop_strings(text):
    return [(no, l.split("=", 1)[1]) for no, l in enumerate(text.split("\n"), 1)
            if re.match(r"(Name|GenericName|Comment|Description)(\[[^]]*\])?=", l)]


def manifest_strings(text):
    out = []
    for no, l in enumerate(text.split("\n"), 1):
        for m in re.finditer(r"<description>([^<]*)</description>|description=\"([^\"]*)\"", l):
            out.append((no, m.group(1) or m.group(2)))
    return out


def patch_strings(text):
    """String literals on the lines a patch adds to C, resource and .inf files."""
    out, cur, added, start = [], None, [], {}
    lines = text.split("\n")

    def flush():
        if cur and added:
            body = "\n".join(a for _, a in added)
            for off, s in c_strings(body):
                out.append((added[off - 1][0], s, cur))

    for no, l in enumerate(lines, 1):
        if l.startswith("+++ "):
            flush(); added = []
            path = l[4:].split("\t")[0]
            path = path[2:] if path.startswith("b/") else path
            cur = path if re.search(r"\.(c|h|rc|inf\.in|inf|mc|idl)$", path) else None
        elif l.startswith("@@"):
            flush(); added = []
        elif l.startswith("+") and cur:
            added.append((no, l[1:]))
        elif not l.startswith("-"):
            flush(); added = []
    flush()
    return out


EXTRACT = [
    (re.compile(r"\.(c|h|rc|cpp)$"), c_strings),
    (re.compile(r"\.py$"), py_strings),
    (re.compile(r"\.reg$"), reg_strings),
    (re.compile(r"\.desktop(\.in)?$"), desktop_strings),
    (re.compile(r"\.manifest$"), manifest_strings),
]


def sh_like(path):
    if re.search(r"\.sh$", path):
        return True
    try:
        with open(path, "rb") as f:
            head = f.read(64)
    except OSError:
        return False
    return head.startswith(b"#!") and (b"sh" in head.split(b"\n")[0]) and b"python" not in head.split(b"\n")[0]


def py_like(path):
    try:
        with open(path, "rb") as f:
            first = f.readline()
    except OSError:
        return False
    return first.startswith(b"#!") and b"python" in first


SKIP_DIRS = {".git", "build", "test", "tests", "debian", "obj", "node_modules"}


def walk(paths):
    for p in paths:
        if os.path.isfile(p):
            yield p
            continue
        for root, dirs, files in os.walk(p):
            dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS and not d.startswith("."))
            for f in sorted(files):
                yield os.path.join(root, f)


def load_allow(path):
    allow = []
    if not path or not os.path.exists(path):
        return allow
    for no, l in enumerate(open(path, encoding="utf-8"), 1):
        l = l.rstrip("\n")
        if not l.strip() or l.lstrip().startswith("#"):
            continue
        parts = l.split("\t")
        if len(parts) < 3 or not parts[2].strip():
            sys.exit("%s:%d: an entry is GLOB<TAB>REGEX<TAB>reason (the reason is required)" % (path, no))
        allow.append((parts[0], re.compile(parts[1]), no))
    return allow


def allowed(allow, path, s, used):
    for glob, rx, no in allow:
        if fnmatch.fnmatch(path, glob) and rx.search(s):
            used.add(no)
            return True
    return False


def main(argv):
    allow_path, patches, root, paths, brands = None, None, None, [], []
    it = iter(argv)
    for a in it:
        if a == "--allow":
            allow_path = next(it)
        elif a == "--patches":
            patches = next(it)
        elif a == "--root":
            root = next(it)
        elif a == "--brand":
            # --brand GLOB WORD: WORD is a slip too in the files GLOB names
            brands.append((next(it), re.compile(r"(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % re.escape(next(it)))))
        else:
            paths.append(a)
    allow, used, bad = load_allow(allow_path), set(), []

    for path in walk(paths):
        rel = os.path.relpath(path, root) if root else os.path.normpath(path)
        fn = None
        for rx, f in EXTRACT:
            if rx.search(path):
                fn = f
                break
        if fn is None:
            if py_like(path):
                fn = py_strings
            elif sh_like(path):
                fn = sh_strings
            else:
                continue
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        brand = None
        for glob, rx in brands:
            if fnmatch.fnmatch(rel, glob):
                brand = rx
        for no, s in fn(text):
            if findings_in(s, brand) and not allowed(allow, rel, s, used):
                bad.append("%s:%d: %s" % (rel, no, s.strip()[:160]))

    if patches:
        for f in sorted(os.listdir(patches)):
            if not f.endswith(".patch"):
                continue
            p = os.path.join(patches, f)
            for no, s, target in patch_strings(open(p, encoding="utf-8", errors="replace").read()):
                key = "%s:%s" % (os.path.normpath(p), target)
                if findings_in(s) and not allowed(allow, key, s, used):
                    bad.append("%s:%d (%s): %s" % (os.path.normpath(p), no, target, s.strip()[:160]))

    for line in bad:
        print("trademark: " + line)
    stale = [no for _, _, no in allow if no not in used]
    for no in stale:
        print("trademark: %s:%d: allowlist entry matches nothing (remove it)" % (allow_path, no))
    if bad or stale:
        print("trademark-check: FAIL -- %d user-visible \"Windows\" or another name that is not ours%s" % (len(bad), " and stale allowlist entries" if stale else ""))
        return 1
    print("trademark-check: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
