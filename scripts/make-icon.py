#!/usr/bin/env python3
"""Renders Resources/AppIcon.png (1024x1024) with no dependencies.

A rounded "squircle" with a teal→indigo gradient and a white up-arrow over a
stacked bar, i.e. "what's up next". Re-run to tweak; build-app.sh turns the
PNG into AppIcon.icns.
"""
import math, struct, zlib, sys

N = 1024
SS = 3  # supersampling per axis

def lerp(a, b, t): return a + (b - a) * t

TOP = (38, 198, 218)     # teal
BOTTOM = (79, 70, 229)   # indigo

# Icon grid per Apple's template: 824px body centred in 1024 canvas.
MARGIN = 100
R = 185  # corner radius

def in_squircle(x, y):
    x0, y0, x1, y1 = MARGIN, MARGIN, N - MARGIN, N - MARGIN
    if x < x0 or x > x1 or y < y0 or y > y1: return False
    cx = min(max(x, x0 + R), x1 - R)
    cy = min(max(y, y0 + R), y1 - R)
    return (x - cx) ** 2 + (y - cy) ** 2 <= R * R

def in_poly(x, y, pts):
    inside = False
    j = len(pts) - 1
    for i in range(len(pts)):
        xi, yi = pts[i]; xj, yj = pts[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
            inside = not inside
        j = i
    return inside

def rounded_rect(x, y, x0, y0, x1, y1, r):
    if x < x0 or x > x1 or y < y0 or y > y1: return False
    cx = min(max(x, x0 + r), x1 - r)
    cy = min(max(y, y0 + r), y1 - r)
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r

C = N / 2
ARROW = [(C, 250), (C + 190, 470), (C + 80, 470), (C + 80, 640),
         (C - 80, 640), (C - 80, 470), (C - 190, 470)]
BAR = (C - 210, 700, C + 210, 770, 35)

def sample(x, y):
    """Returns (r, g, b, a) in 0..1 for one sub-pixel."""
    if not in_squircle(x, y): return (0, 0, 0, 0)
    t = (y - MARGIN) / (N - 2 * MARGIN)
    col = tuple(lerp(TOP[i], BOTTOM[i], t) / 255 for i in range(3))
    # Soft highlight towards the top-left.
    glow = max(0.0, 1 - math.hypot(x - 300, y - 250) / 700) * 0.18
    col = tuple(min(1.0, c + glow) for c in col)
    if in_poly(x, y, ARROW) or rounded_rect(x, y, *BAR):
        return (1, 1, 1, 1)
    return (*col, 1)

rows = []
for py in range(N):
    row = bytearray([0])
    for px in range(N):
        acc = [0.0, 0.0, 0.0, 0.0]
        for sy in range(SS):
            for sx in range(SS):
                r, g, b, a = sample(px + (sx + 0.5) / SS, py + (sy + 0.5) / SS)
                acc[0] += r * a; acc[1] += g * a; acc[2] += b * a; acc[3] += a
        n = SS * SS
        a = acc[3] / n
        if a > 0:
            row += bytes([round(acc[0] / acc[3] * 255), round(acc[1] / acc[3] * 255),
                          round(acc[2] / acc[3] * 255), round(a * 255)])
        else:
            row += b"\0\0\0\0"
    rows.append(bytes(row))
    if py % 128 == 0: print(f"{py}/{N}", file=sys.stderr)

def chunk(kind, data):
    c = struct.pack(">I", len(data)) + kind + data
    return c + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", N, N, 8, 6, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(b"".join(rows), 9))
png += chunk(b"IEND", b"")
out = sys.argv[1] if len(sys.argv) > 1 else "Resources/AppIcon.png"
open(out, "wb").write(png)
print("wrote", out)
