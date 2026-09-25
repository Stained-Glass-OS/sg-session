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

# ---- other languages: German, French, Spanish -----------------------------------------
LANG_CASES = [
    # (language setting, what the model heard, what is typed)
    ("de-DE", "Hallo Welt Komma das ist ein Test Punkt", "Hallo Welt, das ist ein Test."),
    ("de-DE", "Wie geht es dir Fragezeichen neue Zeile gut Ausrufezeichen", "Wie geht es dir?\nGut!"),
    ("de-DE", "Äh, ich glaube, ähm, ja Punkt", "Ich glaube, ja."),
    ("de-DE", "Erstens neuer Absatz zweitens Doppelpunkt drei", "Erstens\n\nZweitens: drei"),
    ("de-DE", "Er sagte Anführungszeichen unten hallo Anführungszeichen oben und ging Punkt",
     "Er sagte „hallo“ und ging."),
    ("de-DE", "Hallo, Welt. Komma. Das ist ein Test. Punkt.", "Hallo, Welt, Das ist ein Test."),
    ("fr-FR", "Bonjour tout le monde virgule ceci est un test point", "Bonjour tout le monde, ceci est un test."),
    ("fr-FR", "Comment ça va point d'interrogation à la ligne très bien point d'exclamation",
     "Comment ça va ?\nTrès bien !"),
    ("fr-FR", "Euh je pense que oui point à la ligne à demain", "Je pense que oui.\nÀ demain"),
    ("fr-FR", "Il a dit ouvrez les guillemets bonjour fermez les guillemets point",
     "Il a dit « bonjour »."),
    ("fr-FR", "Trois choses deux-points une, deux point-virgule trois", "Trois choses : une, deux ; trois"),
    ("es-ES", "Hola a todos coma esto es una prueba punto", "Hola a todos, esto es una prueba."),
    ("es-ES", "Cómo estás signo de interrogación nueva línea muy bien signo de exclamación",
     "¿Cómo estás?\n¡Muy bien!"),
    ("es-ES", "Eh, creo que sí punto y aparte nos vemos", "Creo que sí.\nNos vemos"),
    ("es-ES", "Hola a todos. ¿Cómo estás? Signo de interrogación.", "Hola a todos. ¿Cómo estás?"),
    ("es-ES", "Primero nuevo parrafo segundo", "Primero\n\nSegundo"),  # no accent, as the model may write it
]
for lang, heard, typed in LANG_CASES:
    got = post(heard, language=lang)
    check("postprocess %s %r" % (lang, heard), got == typed, "got %r, want %r" % (got, typed))
check("English marks are not German ones", post("Hallo comma Welt", language="de-DE") == "Hallo comma Welt",
      repr(post("Hallo comma Welt", language="de-DE")))
got = post("Seite twenty three", language="de-DE")
check("numbers are English only", got == "Seite twenty three", repr(got))
check("German fillers only in German", post("Äh, hello.", language="en-US") == "Äh, hello.",
      repr(post("Äh, hello.", language="en-US")))

D = sgspeech.detect_language
for text, lang in [("Hallo Welt, das ist ein Test und ich bin hier.", "de"),
                   ("Bonjour, je pense que c'est une bonne idée pour nous.", "fr"),
                   ("Hola, creo que esto es una prueba muy buena.", "es"),
                   ("Hello, this is what we have for the test.", "en"),
                   ("Okay.", "en")]:
    check("detect_language %r is %s" % (text, lang), D(text) == lang, D(text))
got = post("Hallo Welt Komma das ist ein Test Punkt", language="auto")
check("auto: German marks in German speech", got == "Hallo Welt, das ist ein Test.", repr(got))
got = post("Comment ça va point d'interrogation", language="auto")
check("auto: French marks in French speech", got == "Comment ça va ?", repr(got))

C = sgspeech.command
for text, lang, what in [("Delete that.", "en-US", "delete"), ("Scratch that", "en-US", "delete"),
                         ("Undo that.", "en-US", "undo"), ("Stop listening.", "en-US", "stop"),
                         ("Das löschen.", "de-DE", "delete"), ("Rückgängig machen.", "de-DE", "undo"),
                         ("Diktat beenden.", "de-DE", "stop"),
                         ("Efface ça !", "fr-FR", "delete"), ("Annuler.", "fr-FR", "undo"),
                         ("Arrête d'écouter.", "fr-FR", "stop"),
                         ("Borra eso.", "es-ES", "delete"), ("Deshacer.", "es-ES", "undo"),
                         ("Deja de escuchar.", "es-ES", "stop"), ("Efface ça.", "auto", "delete"),
                         ("Delete that file.", "en-US", None), ("I said delete that", "en-US", None),
                         ("Das löschen.", "en-US", None)]:
    check("command %r (%s) is %s" % (text, lang, what), C(text, lang) == what, repr(C(text, lang)))

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
    # Root is an administrator (and CI builds the package as root): only an
    # unprivileged run can see these refusals.
    if os.getuid() != 0:
        lines = serve(["download"], env_no)
        check("sg-speechd: a user without a Windows session may not download",
              lines[-1:] and lines[-1].startswith("ERROR denied"), repr(lines))
        check("sg-speechd: ...and nothing was written", not os.path.exists(os.path.join(d, sgspeech.MODEL_NAME)))
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

# ---- the packaged model (sg-speech-model-parakeet) --------------------------------------
# /usr/share/stained-glass-speech/<model> is dpkg's: preferred when complete,
# reported as installed, never removed or downloaded over; build-deb.sh's own
# fetch still fetches.
with tempfile.TemporaryDirectory(dir="/var/tmp") as pkg, tempfile.TemporaryDirectory(dir="/var/tmp") as dl:
    penv = dict(os.environ, SG_SPEECH_LIB=SPEECH, SG_SPEECH_DIR=dl, SG_SPEECH_PACKAGED_DIR=pkg,
                https_proxy="http://127.0.0.1:9", HTTPS_PROXY="http://127.0.0.1:9", no_proxy="")
    dictate = [sys.executable, os.path.join(SPEECH, "sg-dictate")]

    def run(*args):
        r = subprocess.run(dictate + list(args), env=penv, capture_output=True, text=True, timeout=120)
        return r.returncode, r.stdout, r.stderr

    rc, out, _ = run("--status")
    check("no model anywhere: missing", out.startswith("MODEL missing"), out)
    mdir = os.path.join(pkg, sgspeech.MODEL_NAME)
    os.makedirs(mdir)
    open(os.path.join(mdir, "vocab.txt"), "w").write("x 0\n")
    rc, out, _ = run("--status")
    check("a packaged model without its stamp is not installed", out.startswith("MODEL missing"), out)
    open(os.path.join(mdir, ".verified"), "w").write("ok\n")
    rc, out, _ = run("--status")
    check("the packaged model is installed", out.startswith("MODEL installed"), out)
    check("...and --status says it is the package's", ("SOURCE packaged " + mdir) in out, out)
    got = subprocess.run([sys.executable, "-c", "import sys; sys.path.insert(0, sys.argv[1]); import sgspeech; "
                          "print(sgspeech.model_path())", SPEECH], env=penv, capture_output=True,
                         text=True).stdout.strip()
    check("model_path() prefers the package", got.rstrip("/") == mdir, got)
    rc, out, err = run("--remove")
    check("--remove refuses the packaged model, saying why",
          rc == 4 and "sg-speech-model-parakeet" in err and os.path.exists(os.path.join(mdir, ".verified")),
          "rc %d: %s" % (rc, err))
    lines = serve(["remove"], {"SG_SPEECH_DIR": dl, "SG_SPEECH_PACKAGED_DIR": pkg,
                               "SG_WINE_GROUP": mine})
    check("sg-speechd refuses to remove it too (or denies a non-administrator)",
          lines[-1:] and (lines[-1].startswith("ERROR unsupported") or lines[-1].startswith("ERROR denied"))
          and os.path.exists(os.path.join(mdir, ".verified")), repr(lines))
    rc, out, err = run("--download")
    check("--download with the package installed: nothing to fetch, no network",
          rc == 0 and not os.path.exists(os.path.join(dl, sgspeech.MODEL_NAME)), "rc %d %s %s" % (rc, out, err))
    lines = serve(["download"], {"SG_SPEECH_DIR": dl, "SG_SPEECH_PACKAGED_DIR": pkg, "SG_WINE_GROUP": mine})
    check("sg-speechd: download with the package installed is done at once", lines[-1:] == ["OK"], repr(lines))
    # build-deb.sh's call (runpy, fetch_model(progress)) must really fetch: an
    # empty mirror makes it fail rather than return as if done.
    code = ("import runpy, sys, time\n"
            "time.sleep = lambda s: None\n"
            "g = runpy.run_path(sys.argv[1], run_name='sg_image')\n"
            "try:\n    g['fetch_model'](lambda d, t: None)\nexcept OSError as e:\n    print('FETCHED-AND-FAILED', e)\n"
            "else:\n    print('RETURNED')\n")
    mirror = tempfile.mkdtemp(dir="/var/tmp")
    got = subprocess.run([sys.executable, "-c", code, os.path.join(SPEECH, "sg-dictate")],
                         env=dict(penv, SG_SPEECH_MIRROR=mirror), capture_output=True, text=True,
                         timeout=120).stdout
    os.rmdir(mirror)
    check("build-deb.sh's fetch_model still fetches with the package installed", "FETCHED-AND-FAILED" in got, got)
    os.unlink(os.path.join(mdir, ".verified"))
    got = subprocess.run([sys.executable, "-c", "import sys; sys.path.insert(0, sys.argv[1]); import sgspeech; "
                          "print(sgspeech.model_path())", SPEECH], env=penv, capture_output=True,
                         text=True).stdout.strip()
    check("without the package, the download is used", got.startswith(dl), got)

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

# ---- the engine: partial results while speaking, commands -------------------------------
# A stand-in recogniser (text grows with the audio) and VAD (loud = speech)
# behind the real Dictation, Segmenter and microphone path (a WAV at real
# time): partials come while speaking, are never the final, and the final
# comes once, after them.
def engine_run(wav_segments, opts, words):
    import importlib.machinery
    import importlib.util
    import threading
    import wave
    import numpy as np
    loader = importlib.machinery.SourceFileLoader("sgdictate", os.path.join(SPEECH, "sg-dictate"))
    spec = importlib.util.spec_from_loader("sgdictate", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)

    class Rec:
        calls = 0

        def transcribe(self, audio):
            Rec.calls += 1
            if words is not None:
                return words(audio)
            n = int(len(audio) / 16000 / 0.25)
            return " ".join("word%d" % i for i in range(n)) + "."

    class Vad:
        def reset(self):
            pass

        def __call__(self, frame):
            return 0.9 if float(np.abs(frame).mean()) > 0.01 else 0.0

    d = tempfile.mkdtemp(dir="/var/tmp")
    path = os.path.join(d, "a.wav")
    pcm = b""
    for kind, secs in wav_segments:
        t = np.arange(int(16000 * secs)) / 16000
        a = 0.3 * np.sin(2 * np.pi * 220 * t) if kind == "speech" else np.zeros(len(t))
        pcm += (a * 32767).astype("<i2").tobytes()
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(pcm)
    os.environ["SG_DICTATE_AUDIO_FILE"] = path
    lines, done = [], threading.Event()

    def emit(line):
        lines.append((time.monotonic(), line))
        if line.startswith("STATE idle"):
            done.set()

    eng = mod.Dictation(emit)
    eng.rec, eng.vad = Rec(), Vad()
    eng.seg = sgspeech.Segmenter(eng.vad)
    eng.model_ready.set()
    eng.start(opts)
    done.wait(sum(s for _, s in wav_segments) + 15)
    eng.quit()
    del os.environ["SG_DICTATE_AUDIO_FILE"]
    import shutil
    shutil.rmtree(d, ignore_errors=True)
    return [line for _, line in lines], Rec.calls


import time  # noqa: E402

lines, calls = engine_run([("silence", 0.3), ("speech", 3.0), ("silence", 1.5)],
                          {"continuous": False, "partials": True, "language": "en-US"}, None)
kinds = [ln.split(" ", 1)[0] for ln in lines if not ln.startswith("LEVEL")]
partials = [json.loads(ln[8:]) for ln in lines if ln.startswith("PARTIAL ")]
texts = [json.loads(ln[5:]) for ln in lines if ln.startswith("TEXT ")]
check("engine: partial results while speaking (3 s: at least 4)", len([p for p in partials if p]) >= 4,
      repr(kinds))
check("engine: partials come before the final, never after it",
      "TEXT" in kinds and "PARTIAL" not in kinds[kinds.index("TEXT"):], repr(kinds))
check("engine: exactly one final", len(texts) == 1, repr(texts))
check("engine: partials grow towards the final",
      len(partials) >= 2 and len(partials[-1]) >= len(partials[0]) and texts and
      texts[0].startswith(partials[0].rstrip(".")), repr((partials, texts)))
check("engine: listening ends after the utterance (not continuous)", kinds[-1:] == ["STATE"], repr(kinds))

lines, _ = engine_run([("speech", 2.0), ("silence", 1.5)],
                      {"continuous": False, "partials": False}, None)
check("engine: no partials when the toolbar does not want them",
      not any(ln.startswith("PARTIAL") for ln in lines) and any(ln.startswith("TEXT") for ln in lines),
      repr(lines))

said = iter(["Hallo Welt Komma das ist gut Punkt", "Das löschen.", "Diktat beenden."])
lines, _ = engine_run([("speech", 1.0), ("silence", 1.2), ("speech", 0.8), ("silence", 1.2),
                       ("speech", 0.8), ("silence", 1.2), ("speech", 1.0), ("silence", 1.0)],
                      {"continuous": True, "partials": False, "language": "de-DE"},
                      lambda audio: next(said, "Noch mehr."))
got = [ln for ln in lines if ln.startswith(("TEXT", "CMD", "STATE idle"))]
check("engine: German marks, then \"Das löschen\" is a command, \"Diktat beenden\" stops",
      got == ['TEXT "Hallo Welt, das ist gut."', "CMD delete", "STATE idle stopped"], repr(got))

print("dictate-test: %s" % ("OK" if not FAILS else "%d FAILED" % FAILS))
sys.exit(1 if FAILS else 0)
