#!/usr/bin/python3
# The device sounds: a device connected (two soft notes rising, a fourth) and
# disconnected (the same, falling) -- our own, made here (no recording, no
# licence to keep), as the feedback Windows gives when a USB device is plugged
# in or taken out (David 2026-10-07).
#   make-device-sounds.py OUTDIR    (device-connect.wav, device-disconnect.wav)
# SPDX-License-Identifier: AGPL-3.0-or-later
import math
import os
import struct
import sys
import wave

RATE = 48000
NOTE = 0.13            # seconds each, the second rings on
PEAK = 0.28            # of full scale: soft
G5, C6 = 783.99, 1046.50


def bell(f, t):
    """One note: the fundamental and a soft octave, a quick attack, a decay."""
    if t < 0:
        return 0.0
    attack = min(1.0, t / 0.005)
    return attack * (math.exp(-7.0 * t) * math.sin(2 * math.pi * f * t)
                     + 0.25 * math.exp(-11.0 * t) * math.sin(4 * math.pi * f * t)) / 1.25


def write(path, first, second):
    length = NOTE + 0.42
    frames = bytearray()
    for i in range(int(RATE * length)):
        t = i / RATE
        tail = min(1.0, (length - t) / 0.03)       # no click at the end
        v = PEAK * tail * (0.8 * bell(first, t) * (1.0 if t < NOTE + 0.05 else 0.4) + bell(second, t - NOTE))
        frames += struct.pack("<h", int(max(-1.0, min(1.0, v)) * 32767))
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(bytes(frames))


out = sys.argv[1]
os.makedirs(out, exist_ok=True)
write(os.path.join(out, "device-connect.wav"), G5, C6)
write(os.path.join(out, "device-disconnect.wav"), C6, G5)
