"""Voice typing: speech recognition for sg-dictate.

NVIDIA's Parakeet TDT 0.6B v3 (CC-BY-4.0), int8 ONNX, on the CPU through
onnxruntime; Silero VAD v5 (MIT) to find where speech starts and ends. Both are
downloaded once per machine by sg-speechd and never shipped in a package.

Nothing heard is written anywhere: audio lives in memory for as long as it
takes to recognise it, and transcripts go only to whoever asked.

Copyright (C) 2026 Stained Glass OS contributors
SPDX-License-Identifier: AGPL-3.0-or-later
"""

import os
import re
import sys

import numpy as np

SAMPLE_RATE = 16000
MODEL_DIR = os.environ.get("SG_SPEECH_DIR", "/var/lib/stained-glass-speech")
# The model as a Debian package (sg-speech-model-parakeet, built by sg-image's
# speech-model/build-deb.sh): read-only, dpkg's. Preferred when complete.
PACKAGED_DIR = os.environ.get("SG_SPEECH_PACKAGED_DIR", "/usr/share/stained-glass-speech")
MODEL_NAME = "parakeet-tdt-0.6b-v3-int8"

# What sg-speechd downloads: pinned revisions, checked by SHA-256. The weights
# are never in git or in a package.
_HF = ("https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx/resolve/"
       "8f23f0c03c8761650bdb5b40aaf3e40d2c15f1ce/")
_SILERO = ("https://raw.githubusercontent.com/snakers4/silero-vad/"
           "6478567951ae5c9979ad7b234185b5515f4be7a1/src/silero_vad/data/")
FILES = [
    # (name, url, bytes, sha256)
    ("config.json", _HF + "config.json", 97,
     "666903c76b9798caf2c210afd4f6cd60b08a8dbf9800ec8d7a3bc0d2148ac466"),
    ("vocab.txt", _HF + "vocab.txt", 93939,
     "d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d"),
    ("decoder_joint-model.int8.onnx", _HF + "decoder_joint-model.int8.onnx", 18202004,
     "eea7483ee3d1a30375daedc8ed83e3960c91b098812127a0d99d1c8977667a70"),
    ("encoder-model.int8.onnx", _HF + "encoder-model.int8.onnx", 652183999,
     "6139d2fa7e1b086097b277c7149725edbab89cc7c7ae64b23c741be4055aff09"),
    ("silero_vad.onnx", _SILERO + "silero_vad.onnx", 2327524,
     "2623a2953f6ff3d2c1e61740c6cdb7168133479b267dfef114a4a3cc5bdd788f"),
]
TOTAL_BYTES = sum(f[2] for f in FILES)


def download_path(name=""):
    """Where sg-speechd downloads the model to (and removes it from)."""
    return os.path.join(MODEL_DIR, MODEL_NAME, name)


def packaged_path(name=""):
    """Where the sg-speech-model-parakeet package puts it."""
    return os.path.join(PACKAGED_DIR, MODEL_NAME, name)


def model_packaged():
    """The packaged model is there and complete (its stamp is packaged too)."""
    return os.path.exists(packaged_path(".verified"))


def model_downloaded():
    """sg-speechd has verified every file and written the stamp; a
    half-downloaded model is not installed."""
    return os.path.exists(download_path(".verified"))


def model_path(name=""):
    """The model to load: the package's when it is installed, else the
    download."""
    return packaged_path(name) if model_packaged() else download_path(name)


def model_installed():
    return model_packaged() or model_downloaded()


class _Quiet:
    """Debian's onnxruntime prints a few hundred lines of "Schema error" when
    it makes its first session (its onnx schemas are registered twice).
    Harmless; keep them off stderr, which the Windows side and the journal
    both see."""

    def __enter__(self):
        sys.stderr.flush()
        self.saved = os.dup(2)
        null = os.open(os.devnull, os.O_WRONLY)
        os.dup2(null, 2)
        os.close(null)

    def __exit__(self, *exc):
        os.dup2(self.saved, 2)
        os.close(self.saved)


def _import_onnxruntime():
    with _Quiet():
        import onnxruntime
    onnxruntime.set_default_logger_severity(3)
    return onnxruntime


def _session(ort, path, threads):
    opts = ort.SessionOptions()
    opts.intra_op_num_threads = threads
    opts.inter_op_num_threads = 1
    opts.log_severity_level = 3
    # Pre-packed weights are a second copy of the int8 encoder: a quarter of
    # a gigabyte more, for no speed this model shows.
    opts.add_session_config_entry("session.disable_prepacking", "1")
    with _Quiet():
        return ort.InferenceSession(path, sess_options=opts, providers=["CPUExecutionProvider"])


def _threads():
    try:
        n = len(os.sched_getaffinity(0))
    except OSError:
        n = os.cpu_count() or 2
    # Leave the desktop some room: recognition is bursty, the session is not.
    return max(1, min(8, n - 1 if n > 2 else n))


# ---- audio ------------------------------------------------------------------

def read_wav(path):
    """A WAV file as float32 mono at 16 kHz (PCM 8/16/24/32-bit or float)."""
    import wave
    try:
        with wave.open(path, "rb") as w:
            rate, ch, width = w.getframerate(), w.getnchannels(), w.getsampwidth()
            raw = w.readframes(w.getnframes())
        if width == 1:
            a = (np.frombuffer(raw, np.uint8).astype(np.float32) - 128) / 128
        elif width == 2:
            a = np.frombuffer(raw, "<i2").astype(np.float32) / 32768
        elif width == 3:
            b = np.frombuffer(raw, np.uint8).reshape(-1, 3)
            a = (b[:, 0].astype(np.int32) | b[:, 1].astype(np.int32) << 8
                 | b[:, 2].astype(np.int8).astype(np.int32) << 16).astype(np.float32) / 8388608
        else:
            a = np.frombuffer(raw, "<i4").astype(np.float32) / 2147483648
    except wave.Error:
        import soundfile  # float WAVs (WAVE_FORMAT_IEEE_FLOAT), if installed
        a, rate = soundfile.read(path, dtype="float32", always_2d=True)
        ch = a.shape[1]
        a = a.reshape(-1)
    if ch > 1:
        a = a.reshape(-1, ch).mean(axis=1)
    return resample(a, rate)


def resample(a, rate):
    if rate == SAMPLE_RATE or not len(a):
        return a.astype(np.float32)
    n = int(round(len(a) * SAMPLE_RATE / rate))
    x = np.arange(n) * (rate / SAMPLE_RATE)
    return np.interp(x, np.arange(len(a)), a).astype(np.float32)


def level(a):
    """0-100, roughly what a Windows level meter shows: dBFS from -60 to 0."""
    if not len(a):
        return 0
    rms = float(np.sqrt(np.mean(np.square(a, dtype=np.float64))))
    if rms <= 1e-6:
        return 0
    return int(max(0, min(100, (20 * np.log10(rms) + 60) * 100 / 60)))


# ---- features: NeMo's 128-band log-mel, in numpy ------------------------------

def _mel_filters(n_fft=512, n_mels=128, fmax=8000.0):
    """Slaney-scale triangular filters with Slaney area normalisation, as
    librosa and NeMo make them."""
    def hz_to_mel(f):
        f = np.asarray(f, np.float64)
        lin = f / (200.0 / 3)
        log = 15.0 + np.log(np.maximum(f, 1e-10) / 1000.0) / (np.log(6.4) / 27.0)
        return np.where(f >= 1000.0, log, lin)

    def mel_to_hz(m):
        m = np.asarray(m, np.float64)
        lin = m * (200.0 / 3)
        log = 1000.0 * np.exp((np.log(6.4) / 27.0) * (m - 15.0))
        return np.where(m >= 15.0, log, lin)

    fft_hz = np.linspace(0, SAMPLE_RATE / 2, n_fft // 2 + 1)
    mel_hz = mel_to_hz(np.linspace(hz_to_mel(0.0), hz_to_mel(fmax), n_mels + 2))
    fdiff = np.diff(mel_hz)
    ramps = mel_hz[:, None] - fft_hz[None, :]
    lower = -ramps[:-2] / fdiff[:-1, None]
    upper = ramps[2:] / fdiff[1:, None]
    w = np.maximum(0, np.minimum(lower, upper))
    w *= (2.0 / (mel_hz[2:n_mels + 2] - mel_hz[:n_mels]))[:, None]
    return w.T.astype(np.float32)  # (257, 128)


_MEL = None
_WINDOW = None


def features(audio):
    """(1, 128, T) normalised log-mel features and their length."""
    global _MEL, _WINDOW
    if _MEL is None:
        _MEL = _mel_filters()
        w = np.hanning(400)
        _WINDOW = np.pad(w, (56, 56)).astype(np.float32)
    n = len(audio)
    x = audio.astype(np.float32)
    x = x - 0.97 * np.concatenate([[0.0], x[:-1]]).astype(np.float32)
    x = np.pad(x, (256, 256))
    frames = np.lib.stride_tricks.sliding_window_view(x, 512)[::160] * _WINDOW
    spec = np.abs(np.fft.rfft(frames, 512)).astype(np.float32) ** 2
    logmel = np.log(spec @ _MEL + 2.0 ** -24)
    t = n // 160
    valid = logmel[:t]
    mean = valid.mean(axis=0, keepdims=True)
    std = np.sqrt(((valid - mean) ** 2).sum(axis=0, keepdims=True) / max(1, t - 1))
    feats = np.zeros_like(logmel)
    feats[:t] = (valid - mean) / (std + 1e-5)
    return feats.T[None].astype(np.float32), np.array([t], np.int64)


# ---- the recogniser -----------------------------------------------------------

class Recognizer:
    """Parakeet TDT: a FastConformer encoder, then greedy token-and-duration
    decoding with the prediction/joint network."""

    MAX_TOKENS_PER_STEP = 10

    def __init__(self, directory=None, threads=None):
        d = directory or model_path()
        ort = _import_onnxruntime()
        threads = threads or _threads()
        self.encoder = _session(ort, os.path.join(d, "encoder-model.int8.onnx"), threads)
        self.decoder = _session(ort, os.path.join(d, "decoder_joint-model.int8.onnx"), 1)
        self.vocab = {}
        with open(os.path.join(d, "vocab.txt"), encoding="utf-8") as f:
            for line in f:
                tok, _, idx = line.rstrip("\n").rpartition(" ")
                self.vocab[int(idx)] = tok.replace("▁", " ")
        self.blank = next(i for i, t in self.vocab.items() if t == "<blk>")
        shapes = {i.name: i.shape for i in self.decoder.get_inputs()}
        s1, s2 = shapes["input_states_1"], shapes["input_states_2"]
        self._state0 = (np.zeros((s1[0], 1, s1[2]), np.float32),
                        np.zeros((s2[0], 1, s2[2]), np.float32))

    def transcribe(self, audio):
        """Text for float32 16 kHz mono audio, with the model's own
        punctuation and capitals."""
        if len(audio) < SAMPLE_RATE // 10:
            return ""
        feats, lens = features(audio)
        enc, enc_lens = self.encoder.run(["outputs", "encoded_lengths"],
                                         {"audio_signal": feats, "length": lens})
        enc = enc[0].T  # (T, 1024)
        n = int(min(enc_lens[0], enc.shape[0]))
        vocab_size = len(self.vocab)
        state = self._state0
        tokens = []
        t = emitted = 0
        while t < n:
            out, st1, st2 = self.decoder.run(
                ["outputs", "output_states_1", "output_states_2"],
                {"encoder_outputs": enc[t][None, :, None],
                 "targets": np.array([[tokens[-1] if tokens else self.blank]], np.int32),
                 "target_length": np.array([1], np.int32),
                 "input_states_1": state[0], "input_states_2": state[1]})
            out = np.squeeze(out)
            token = int(out[:vocab_size].argmax())
            step = int(out[vocab_size:].argmax())
            if token != self.blank:
                state = (st1, st2)
                tokens.append(token)
                emitted += 1
            if step > 0:
                t += step
                emitted = 0
            elif token == self.blank or emitted == self.MAX_TOKENS_PER_STEP:
                t += 1
                emitted = 0
        text = "".join(self.vocab[i] for i in tokens if not self.vocab[i].startswith("<"))
        return re.sub(r"\s+", " ", text).strip()


# ---- voice activity -------------------------------------------------------------

class SileroVAD:
    """Silero VAD v5: speech probability for each 512-sample (32 ms) frame."""

    FRAME = 512
    CONTEXT = 64

    def __init__(self, path=None):
        ort = _import_onnxruntime()
        self.session = _session(ort, path or model_path("silero_vad.onnx"), 1)
        self.reset()

    def reset(self):
        self.state = np.zeros((2, 1, 128), np.float32)
        self.context = np.zeros(self.CONTEXT, np.float32)

    def __call__(self, frame):
        x = np.concatenate([self.context, frame])[None].astype(np.float32)
        out, self.state = self.session.run(
            ["output", "stateN"], {"input": x, "state": self.state, "sr": np.array(SAMPLE_RATE, np.int64)})
        self.context = frame[-self.CONTEXT:]
        return float(out[0][0])


class Segmenter:
    """Cuts a stream of frames into utterances. Speech starts above
    `threshold`; it ends after `min_silence_ms` below a lower threshold
    (hysteresis, so a soft syllable does not end it). Each utterance keeps
    `pad_ms` either side and is cut at `max_ms` at the quietest recent frame."""

    def __init__(self, vad, threshold=0.5, min_silence_ms=700, pad_ms=200, max_ms=20000):
        self.vad = vad
        self.on = threshold
        self.off = max(0.15, threshold - 0.15)
        f = SileroVAD.FRAME * 1000 / SAMPLE_RATE
        self.min_silence = int(min_silence_ms / f)
        self.pad = int(pad_ms / f)
        self.max = int(max_ms / f)
        self.reset()

    def reset(self):
        self.vad.reset()
        self.pending = np.zeros(0, np.float32)
        self.history = []   # frames before speech, for the leading pad
        self.speech = []    # frames of the current utterance
        self.probs = []
        self.silence = 0
        self.last_speech = 0.0  # frames since speech was last heard

    @property
    def in_speech(self):
        return bool(self.speech)

    def push(self, audio):
        """Feed audio; returns a list of finished utterances."""
        done = []
        self.pending = np.concatenate([self.pending, audio])
        F = SileroVAD.FRAME
        while len(self.pending) >= F:
            frame, self.pending = self.pending[:F], self.pending[F:]
            p = self.vad(frame)
            if not self.speech:
                self.history = (self.history + [frame])[-(self.pad + 1):]
                if p >= self.on:
                    self.speech = self.history[:]
                    self.probs = [0.0] * (len(self.speech) - 1) + [p]
                    self.history = []
                    self.silence = 0
                continue
            self.speech.append(frame)
            self.probs.append(p)
            if p < self.off:
                self.silence += 1
            elif p >= self.on:
                self.silence = 0
            if self.silence >= self.min_silence:
                keep = len(self.speech) - self.silence + self.pad
                done.append(np.concatenate(self.speech[:keep]))
                self.history = self.speech[keep:][-(self.pad + 1):]
                self.speech, self.probs, self.silence = [], [], 0
            elif len(self.speech) >= self.max:
                # Too long without a pause: cut at the least speech-like frame
                # of the last third, and carry on from there.
                start = len(self.speech) * 2 // 3
                cut = start + int(np.argmin(self.probs[start:])) + 1
                done.append(np.concatenate(self.speech[:cut]))
                self.speech, self.probs = self.speech[cut:], self.probs[cut:]
        return done

    def flush(self):
        """What is left when listening stops: the utterance in progress."""
        out = None
        if self.speech:
            frames = self.speech + ([self.pending] if len(self.pending) else [])
            out = np.concatenate(frames)
        self.reset()
        return out


# ---- turning what was said into what to type -------------------------------------

FILLERS = ["um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "hmm", "hm", "mm", "mhm"]

# Longest first. "new line" and "new paragraph" become line breaks.
SPOKEN_PUNCTUATION = [
    ("new paragraph", "\n\n"), ("next paragraph", "\n\n"),
    ("new line", "\n"), ("next line", "\n"),
    ("question mark", "?"), ("exclamation mark", "!"), ("exclamation point", "!"),
    ("full stop", "."), ("period", "."), ("comma", ","),
    ("semicolon", ";"), ("semi colon", ";"), ("colon", ":"),
    ("open parenthesis", "("), ("close parenthesis", ")"),
    ("open parentheses", "("), ("close parentheses", ")"),
    ("open quote", "“"), ("close quote", "”"),
    ("ellipsis", "…"), ("hyphen", "-"), ("dash", " – "),
]

_UNITS = {w: i for i, w in enumerate(
    "zero one two three four five six seven eight nine ten eleven twelve thirteen "
    "fourteen fifteen sixteen seventeen eighteen nineteen".split())}
_TENS = {w: 10 * (i + 2) for i, w in enumerate(
    "twenty thirty forty fifty sixty seventy eighty ninety".split())}
_SCALES = {"hundred": 100, "thousand": 1000, "million": 10 ** 6, "billion": 10 ** 9}
_NUMWORD = set(_UNITS) | set(_TENS) | set(_SCALES)


def _words_to_number(words):
    total = current = 0
    for w in words:
        if w in _UNITS:
            current += _UNITS[w]
        elif w in _TENS:
            current += _TENS[w]
        elif w == "hundred":
            current = max(current, 1) * 100
        else:
            total += max(current, 1) * _SCALES[w]
            current = 0
    return total + current


def _numbers(text):
    """Spoken numbers as digits: "twenty three" -> 23, "one hundred and five"
    -> 105. A lone small number stays a word ("one of them", "two cats"), as
    style guides write it."""
    tokens = re.split(r"(\s+)", text)
    out = []
    i = 0
    while i < len(tokens):
        if not tokens[i] or tokens[i].isspace():
            out.append(tokens[i])
            i += 1
            continue
        run, j = [], i
        while j < len(tokens):
            tok = tokens[j]
            if tok.isspace():
                j += 1
                continue
            m = re.fullmatch(r"([A-Za-z]+(?:-[A-Za-z]+)?)([.,!?;:]?)", tok)
            if not m:
                break
            parts = m.group(1).lower().split("-")
            if all(p in _NUMWORD for p in parts):
                run.append((j, parts, m.group(2)))
                j += 1
                if m.group(2):
                    break
            elif m.group(1).lower() == "and" and run and run[-1][1][-1] == "hundred" and not run[-1][2]:
                run.append((j, [], ""))
                j += 1
            else:
                break
        while run and not run[-1][1]:
            run.pop()  # a trailing "and" is just "and"
        words = [w for _, p, _ in run for w in p]
        if run and (len(words) > 1 or (words[0] not in _UNITS or _UNITS[words[0]] >= 10)):
            out.append(str(_words_to_number(words)) + run[-1][2])
            i = run[-1][0] + 1
        else:
            out.append(tokens[i])
            i += 1
    return "".join(out)


def postprocess(text, spoken_punctuation=True, auto_punctuation=True,
                remove_fillers=True, numbers=True):
    """The recogniser's text as it should be typed. Empty when there is
    nothing worth typing (only a filler, say)."""
    t = " " + text.strip() + " "
    if remove_fillers:
        pat = r"(?i)(?<![\w'])(?:" + "|".join(FILLERS) + r")(?![\w'])[,.]?"
        t = re.sub(pat, " ", t)
        t = re.sub(r"^\s*[,.;:]+", " ", t)  # "Um, so" left ", so"
    if not auto_punctuation:
        # The model punctuates by itself; without that, keep only what was
        # dictated (and apostrophes, which belong to the words).
        t = re.sub(r"[.,!?;:](?=\s|$)", "", t)
    dictated = False  # a mark said aloud is worth typing on its own
    if spoken_punctuation:
        for phrase, sym in SPOKEN_PUNCTUATION:
            words = r"\s+".join(phrase.split())
            # The model often punctuates around a spoken mark ("Hello, period."):
            # the dictated mark replaces what it put either side.
            pat = r"[,.;:]?\s*(?<![\w'])" + words + r"(?![\w'])"
            if "\n" in sym or sym in ".,?!;:\u2026":
                # ...including a "?" or "!" it guessed for a mark said aloud.
                t, n = re.subn(r"[?!]?" + pat + r"[.,!?;:]?", lambda m, s=sym: s, t, flags=re.I)
            elif sym in "(\u201c":
                t, n = re.subn(pat, " " + sym, t, flags=re.I)
            else:
                t, n = re.subn(pat, sym, t, flags=re.I)
            dictated = dictated or n > 0
    if numbers:
        t = _numbers(t)
    # Tidy: no space before closing marks, one space between words, none
    # around line breaks, a capital after the end of a sentence.
    t = re.sub(r"[ \t]+([.,!?;:)”…])", r"\1", t)
    t = re.sub(r"([(“])[ \t]+", r"\1", t)
    t = re.sub(r"([.,!?;:])(?=[A-Za-z])", r"\1 ", t)
    t = re.sub(r"[ \t]*\n[ \t]*", "\n", t)
    t = re.sub(r"[ \t]{2,}", " ", t)
    t = re.sub(r"([.,!?;:])(?:[.,;:])+", r"\1", t)
    t = t.strip(" \t")
    if auto_punctuation or spoken_punctuation:
        t = re.sub(r"(^|[.!?]\s+|\n)([a-z])", lambda m: m.group(1) + m.group(2).upper(), t)
    if not re.search(r"[\w\n]", t) and not dictated:
        return ""
    return t


def join(previous_tail, text):
    """The text to type after `previous_tail` (the last character typed this
    session, or "" at the start): a space between words, none after a line
    break or before closing punctuation."""
    if not text or not previous_tail or previous_tail in "\n \t(“":
        return text
    if text[0] in "\n.,!?;:)”… ":
        return text
    return " " + text


if __name__ == "__main__":
    print("run sg-dictate", file=sys.stderr)
    sys.exit(2)
