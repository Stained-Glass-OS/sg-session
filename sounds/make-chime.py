#!/usr/bin/python3
# The volume chime: a short, soft bell of our own (no recording, no licence
# to keep) -- two partials a fifth apart, a quick attack and a decay, as the
# feedback the volume keys and sliders give (David 2026-10-02).
#   make-chime.py OUT.wav
# SPDX-License-Identifier: AGPL-3.0-or-later
import math
import struct
import sys
import wave

RATE = 48000
LENGTH = 0.32          # seconds
PARTIALS = ((987.77, 1.0, 9.0), (1479.98, 0.45, 12.0), (2959.96, 0.12, 20.0))  # B5, F#6, F#7: Hz, gain, decay /s
PEAK = 0.30            # of full scale: a soft chime, not a beep

frames = bytearray()
n = int(RATE * LENGTH)
for i in range(n):
    t = i / RATE
    attack = min(1.0, t / 0.004)
    tail = min(1.0, (LENGTH - t) / 0.02)          # no click at the end
    s = sum(g * math.exp(-d * t) * math.sin(2 * math.pi * f * t) for f, g, d in PARTIALS)
    v = PEAK * attack * tail * s / sum(g for _, g, _ in PARTIALS)
    frames += struct.pack("<h", int(max(-1.0, min(1.0, v)) * 32767))
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(RATE)
    w.writeframes(bytes(frames))
