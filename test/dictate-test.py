#!/usr/bin/python3
# Unit gate for voice typing (sg-dictate, sgspeech.py), no model needed: the
# text rules (spoken punctuation, fillers, numbers, joining utterances), the
# mel filterbank's shape, and who sg-speechd lets install or remove the model
# (the peer's uid, over the real socket protocol).
#
# test/dictate-e2e.sh (make test-dictate) runs the real model on speech.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
import grp
import json
import os
import re
import socket
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SPEECH = os.path.join(HERE, "..", "speech")
sys.path.insert(0, SPEECH)
FAILS = 0


def check(what, ok, detail=""):
    global FAILS
    print("%s  %s%s" % ("PASS" if ok else "FAIL", what, "" if ok else ": " + detail))
    if not ok:
        FAILS += 1


try:
    import numpy  # noqa: F401
except ImportError:
    print("SKIP  dictate-test: python3-numpy is not installed")
    sys.exit(0)
import sgspeech  # noqa: E402

post = sgspeech.postprocess
CASES = [
    # (what the model heard, what is typed)
    ("Hello world, this is a test.", "Hello world, this is a test."),
    ("Um, I think so.", "I think so."),
    ("Uh, hello there, uh, friend.", "Hello there, friend."),
    ("Um.", ""),
    ("The umbrella is here.", "The umbrella is here."),
    ("Dear Sam comma new line thanks for the note period", "Dear Sam,\nThanks for the note."),
    ("Hello, period.", "Hello."),
    ("Is it done question mark.", "Is it done?"),
    ("Stop exclamation point", "Stop!"),
    ("First new paragraph second", "First\n\nSecond"),
    ("What time is it? question mark.", "What time is it?"),
    ("period", "."),
    ("new line", "\n"),
    ("He said open quote hi close quote.", "He said “hi”."),
    ("Buy twenty three apples and one pear.", "Buy 23 apples and one pear."),
    ("I have one hundred and five cats, and two dogs.", "I have 105 cats, and two dogs."),
    ("Ninety-nine problems.", "99 problems."),
    ("It costs five hundred dollars", "It costs 500 dollars"),
    ("Meet at 2300 hours comma then go home period", "Meet at 2300 hours, then go home."),
]
for heard, typed in CASES:
    got = post(heard)
    check("postprocess %r" % heard, got == typed, "got %r, want %r" % (got, typed))

got = post("Hello, world. Bye.", auto_punctuation=False)
check("auto-punctuation off keeps only dictated marks", got == "Hello world Bye", repr(got))
got = post("Hello comma world period", spoken_punctuation=False)
check("spoken punctuation off leaves the words", got == "Hello comma world period", repr(got))
got = post("Um, hello.", remove_fillers=False)
check("filler removal off keeps them", got.lower().startswith("um"), repr(got))
got = post("Twenty three.", numbers=False)
check("number formatting off keeps words", got == "Twenty three.", repr(got))

J = sgspeech.join
check("join: a space between sentences", J(".", "Next.") == " Next.")
check("join: none at the start", J("", "First.") == "First.")
check("join: none after a line break", J("\n", "Next.") == "Next.")
check("join: none before punctuation", J("d", ".") == ".")

m = sgspeech._mel_filters()
check("mel filterbank is 257x128 and non-negative", m.shape == (257, 128) and (m >= 0).all())
check("mel filterbank: every band has weight", bool((m.sum(axis=0) > 0).all()))
feats, n = sgspeech.features(numpy.zeros(16000, numpy.float32) + 0.01)
check("features: 100 frames a second, 128 bands", feats.shape[1] == 128 and int(n[0]) == 100,
      str(feats.shape))
check("level: silence is 0, full scale 100",
      sgspeech.level(numpy.zeros(512, numpy.float32)) == 0
      and sgspeech.level(numpy.ones(512, numpy.float32)) == 100)


# ---- sg-speechd: who may do what -------------------------------------------------------

def serve(argv, env_extra):
    a, b = socket.socketpair()
    # A request that should be refused must never reach the network, even
    # from a mutant: point HTTPS at a closed port.
    env = dict(os.environ, SG_SPEECH_LIB=SPEECH, https_proxy="http://127.0.0.1:9",
               HTTPS_PROXY="http://127.0.0.1:9", no_proxy="", **env_extra)
    p = subprocess.Popen([sys.executable, os.path.join(SPEECH, "sg-dictate"), "--serve"],
                         stdin=b, stdout=b, stderr=subprocess.PIPE, env=env)
    b.close()
    a.sendall((json.dumps({"argv": argv}) + "\n").encode())
    out = b""
    while True:
        chunk = a.recv(65536)
        if not chunk:
            break
        out += chunk
    p.wait(timeout=30)
    return out.decode().splitlines()


with tempfile.TemporaryDirectory(dir="/var/tmp") as d:
    mine = grp.getgrgid(os.getgid()).gr_name
    env_no = {"SG_SPEECH_DIR": d, "SG_WINE_GROUP": "sg-no-such-group"}
    env_yes = {"SG_SPEECH_DIR": d, "SG_WINE_GROUP": mine}
    lines = serve(["status"], env_no)
    check("sg-speechd: status for anyone", lines == ["MODEL missing", "OK"], repr(lines))
    lines = serve(["download"], env_no)
    check("sg-speechd: a user without a Windows session may not download",
          lines[-1:] and lines[-1].startswith("ERROR denied"), repr(lines))
    check("sg-speechd: ...and nothing was written", not os.path.exists(os.path.join(d, sgspeech.MODEL_NAME)))
    if os.getuid() != 0:
        is_admin = "sg-admins" in {grp.getgrgid(g).gr_name for g in os.getgroups()}
        lines = serve(["remove"], env_yes)
        check("sg-speechd: only an administrator may remove the model",
              is_admin or (lines[-1:] and lines[-1].startswith("ERROR denied")), repr(lines))
    lines = serve(["rm", "-rf", "/"], env_yes)
    check("sg-speechd: unknown requests are refused", lines == ["ERROR invalid unknown request"], repr(lines))
    a, b = socket.socketpair()
    p = subprocess.Popen([sys.executable, os.path.join(SPEECH, "sg-dictate"), "--serve"], stdin=b, stdout=b,
                         stderr=subprocess.DEVNULL, env=dict(os.environ, SG_SPEECH_LIB=SPEECH, SG_SPEECH_DIR=d))
    b.close()
    a.sendall(b"not json\n")
    reply = a.makefile().read().splitlines()
    p.wait(timeout=30)
    check("sg-speechd: malformed requests are refused", reply == ["ERROR invalid malformed request"], repr(reply))

# A model file list that does not pin every file would let a download be
# anything: each must have a size and a SHA-256.
check("every model file is pinned by size and SHA-256",
      all(size > 0 and len(sha) == 64 for _, _, size, sha in sgspeech.FILES))
check("model files come from pinned revisions",
      all("/resolve/main/" not in url and "/master/" not in url for _, url, _, _ in sgspeech.FILES))

# sg-speechd may write only its StateDirectory (ProtectSystem=strict): the
# model directory the code defaults to must be that one, or the service
# cannot write a byte on a real machine (every other check here overrides it).
_here = os.path.dirname(os.path.abspath(__file__))
_unit = open(os.path.join(_here, "..", "systemd", "sg-speechd@.service")).read()
_state = re.search(r"^StateDirectory=(\S+)", _unit, re.M).group(1)
_code = open(os.path.join(_here, "..", "speech", "sgspeech.py")).read()
_default = re.search(r'MODEL_DIR = os.environ.get\("SG_SPEECH_DIR", "([^"]+)"\)', _code).group(1)
check("the model directory is sg-speechd's StateDirectory", _default == "/var/lib/" + _state,
      "%s vs /var/lib/%s" % (_default, _state))

print("dictate-test: %s" % ("OK" if not FAILS else "%d FAILED" % FAILS))
sys.exit(1 if FAILS else 0)
