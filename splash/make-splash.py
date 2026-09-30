#!/usr/bin/env python3
# The Stained Glass boot splash's picture: the project's diamond -- four
# square tiles in a 2x2 grid, the grid turned 45 degrees, with a leaded gap
# between them -- in its four colours, on transparency. Our own drawing, made
# at build time (no artwork is committed). The same geometry as the taskbar's
# Start mark (wine-sg patch 0012, sg_draw_start_mark).
#
#   make-splash.py OUT.png [SIZE]
#   make-splash.py --bar OUT.png RRGGBB   a 1x1 pixel of that colour (the
#                                         update screen's progress bar, scaled)
#
# Pure Python (zlib, struct): the build needs no imaging library.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
import math
import struct
import sys
import zlib

TILES = [(0x8A, 0x2B, 0xE2), (0xC0, 0x2B, 0x8A), (0xE0, 0x9A, 0x1E), (0x1E, 0xC0, 0xB0)]
CELLS = [(-1, -1), (1, -1), (1, 1), (-1, 1)]      # purple top, magenta right, amber bottom, turquoise left
SS = 4                                             # supersampling per axis


def squares(size):
    """Each tile as a convex polygon (4 points) in pixel coordinates."""
    cx = cy = size / 2.0
    R = size / 2.0 - size * 0.04
    s = R * 0.32                    # half the side of a tile
    c = s + R * 0.07                # half the spacing between tile centres (the lead)
    rot = math.sqrt(0.5)
    out = []
    for gx, gy in CELLS:
        pts = []
        for kx, ky in [(-1, -1), (1, -1), (1, 1), (-1, 1)]:
            x = gx * c + kx * s
            y = gy * c + ky * s
            pts.append((cx + (x - y) * rot, cy + (x + y) * rot))
        out.append(pts)
    return out


def inside(poly, x, y):
    sign = 0
    for i in range(4):
        (x1, y1), (x2, y2) = poly[i], poly[(i + 1) % 4]
        cross = (x2 - x1) * (y - y1) - (y2 - y1) * (x - x1)
        if cross != 0:
            if sign == 0:
                sign = 1 if cross > 0 else -1
            elif (cross > 0) != (sign > 0):
                return False
    return True


def render(size):
    polys = squares(size)
    rows = []
    for py in range(size):
        row = bytearray()
        for px in range(size):
            acc = [0, 0, 0, 0]          # r, g, b (premultiplied sums) and coverage
            for sy in range(SS):
                for sx in range(SS):
                    x = px + (sx + 0.5) / SS
                    y = py + (sy + 0.5) / SS
                    for poly, col in zip(polys, TILES):
                        if inside(poly, x, y):
                            acc[0] += col[0]; acc[1] += col[1]; acc[2] += col[2]; acc[3] += 1
                            break
            n = acc[3]
            if n:
                row += bytes((acc[0] // n, acc[1] // n, acc[2] // n, n * 255 // (SS * SS)))
            else:
                row += b"\0\0\0\0"
        rows.append(bytes(row))
    return rows


def png(rows, size):
    raw = b"".join(b"\0" + r for r in rows)

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--bar":
        c = bytes.fromhex(sys.argv[3])
        with open(sys.argv[2], "wb") as f:
            f.write(png([c + b"\xff"], 1))
        sys.exit(0)
    if len(sys.argv) < 2:
        sys.exit("usage: make-splash.py OUT.png [SIZE]")
    size = int(sys.argv[2]) if len(sys.argv) > 2 else 192
    with open(sys.argv[1], "wb") as f:
        f.write(png(render(size), size))
