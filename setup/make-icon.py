#!/usr/bin/python3
# Draws Setup's icon -- the Stained Glass mark, four panes of coloured glass
# around a point -- as a Windows .ico (16, 24, 32, 48 and 256 pixels, 32-bit
# with alpha). Our own art, generated at build time; nothing is committed.
#
#   make-icon.py OUT.ico
#
# SPDX-License-Identifier: AGPL-3.0-or-later
import struct
import sys

PANES = [  # centre (in units of the pane's half-diagonal), colour
    ((0.0, -1.1), (0x7B, 0x3F, 0xD6)),
    ((1.1, 0.0), (0xE0, 0x3E, 0x8C)),
    ((0.0, 1.1), (0xF2, 0x9D, 0x2E)),
    ((-1.1, 0.0), (0x1F, 0xB5, 0xAD)),
]
SS = 4  # supersampling per axis


def render(size):
    h = size / 4.6  # half-diagonal of a pane
    c = size / 2.0
    px = []
    for y in range(size):
        row = []
        for x in range(size):
            acc = [0, 0, 0, 0]
            for sy in range(SS):
                for sx in range(SS):
                    fx = x + (sx + 0.5) / SS
                    fy = y + (sy + 0.5) / SS
                    for (ox, oy), col in PANES:
                        if abs(fx - (c + ox * h)) + abs(fy - (c + oy * h)) <= h:
                            acc[0] += col[0]; acc[1] += col[1]; acc[2] += col[2]; acc[3] += 255
                            break
            n = SS * SS
            a = acc[3] // n
            if a:
                cov = acc[3] / 255
                row.append((int(acc[2] / cov), int(acc[1] / cov), int(acc[0] / cov), a))  # BGRA
            else:
                row.append((0, 0, 0, 0))
        px.append(row)
    return px


def dib(size):
    px = render(size)
    header = struct.pack('<IiiHHIIiiII', 40, size, size * 2, 1, 32, 0, 0, 0, 0, 0, 0)
    body = b''.join(bytes(p) for row in reversed(px) for p in row)
    mask_row = ((size + 31) // 32) * 4
    mask = b''
    for row in reversed(px):
        bits = bytearray(mask_row)
        for x, p in enumerate(row):
            if p[3] == 0:
                bits[x // 8] |= 0x80 >> (x % 8)
        mask += bytes(bits)
    return header + body + mask


def main():
    sizes = [16, 24, 32, 48, 256]
    images = [dib(s) for s in sizes]
    out = struct.pack('<HHH', 0, 1, len(sizes))
    offset = 6 + 16 * len(sizes)
    for s, img in zip(sizes, images):
        out += struct.pack('<BBBBHHII', s % 256, s % 256, 0, 0, 1, 32, len(img), offset)
        offset += len(img)
    with open(sys.argv[1], 'wb') as f:
        f.write(out + b''.join(images))


if __name__ == '__main__':
    main()
