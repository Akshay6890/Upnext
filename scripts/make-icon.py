#!/usr/bin/env python3
"""Renders Resources/AppIcon.png (1024x1024) from the design in
Design/AppIcon.svg, with no dependencies.

Same style as the Upkeep icon: a graphite tile with a hairline border and a
soft shadow, and a single line-art glyph with round caps. The geometry below
mirrors the SVG; change both together.
"""
import math, struct, sys, zlib

N = 1024

# Tile
X0, Y0, X1, Y1, R = 100.0, 100.0, 924.0, 924.0, 186.0
TOP, BOTTOM = (0x2C, 0x2C, 0x2E), (0x1F, 0x1F, 0x21)
BORDER_ALPHA, BORDER_W = 0.08, 3.0
SHADOW_ALPHA, SHADOW_SIGMA, SHADOW_DY = 0.35, 14.0, 10.0

# Glyph: stroked polylines with round caps and joins
GLYPH = (0x6F, 0xA8, 0xF5)
STROKE = 44.0
POLYLINES = [
    [(512, 648), (512, 312)],               # shaft
    [(370, 454), (512, 312), (654, 454)],   # arrow head
    [(364, 736), (660, 736)],               # baseline
]
SEGMENTS = [(a, b) for line in POLYLINES for a, b in zip(line, line[1:])]


def rounded_rect_sd(x, y):
    """Signed distance to the tile (negative inside)."""
    cx, cy = (X0 + X1) / 2, (Y0 + Y1) / 2
    hx, hy = (X1 - X0) / 2 - R, (Y1 - Y0) / 2 - R
    qx, qy = abs(x - cx) - hx, abs(y - cy) - hy
    outside = math.hypot(max(qx, 0.0), max(qy, 0.0))
    inside = min(max(qx, qy), 0.0)
    return outside + inside - R


def segment_distance(px, py, a, b):
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)
    t = min(max(t, 0.0), 1.0)
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def coverage(signed_distance):
    """Anti-aliased coverage from a signed distance (1px ramp)."""
    return min(max(0.5 - signed_distance, 0.0), 1.0)


def over(dst, src_rgb, src_a):
    """Composites src over dst (straight, non-premultiplied RGBA)."""
    r, g, b, a = dst
    out_a = src_a + a * (1 - src_a)
    if out_a <= 0:
        return (0.0, 0.0, 0.0, 0.0)
    mix = lambda s, d: (s * src_a + d * a * (1 - src_a)) / out_a
    return (mix(src_rgb[0], r), mix(src_rgb[1], g), mix(src_rgb[2], b), out_a)


rows = []
for py in range(N):
    y = py + 0.5
    row = bytearray([0])
    t = min(max((y - Y0) / (Y1 - Y0), 0.0), 1.0)
    tile_rgb = tuple((TOP[i] + (BOTTOM[i] - TOP[i]) * t) / 255 for i in range(3))
    for px in range(N):
        x = px + 0.5
        # Shadow: the tile's silhouette, blurred and offset down.
        sd_shadow = rounded_rect_sd(x, y - SHADOW_DY)
        shadow_a = SHADOW_ALPHA * 0.5 * math.erfc(sd_shadow / (SHADOW_SIGMA * math.sqrt(2)))
        pixel = (0.0, 0.0, 0.0, shadow_a)

        sd = rounded_rect_sd(x, y)
        tile_a = coverage(sd)
        if tile_a > 0:
            pixel = over(pixel, tile_rgb, tile_a)
            # Hairline border just inside the edge.
            border_a = BORDER_ALPHA * coverage(abs(sd + BORDER_W / 2) - BORDER_W / 2) * tile_a
            if border_a > 0:
                pixel = over(pixel, (1.0, 1.0, 1.0), border_a)
            # Glyph
            if 250 < x < 720 and 260 < y < 790:
                d = min(segment_distance(x, y, a, b) for a, b in SEGMENTS)
                glyph_a = coverage(d - STROKE / 2)
                if glyph_a > 0:
                    pixel = over(pixel, tuple(c / 255 for c in GLYPH), glyph_a)

        r, g, b, a = pixel
        row += bytes([round(r * 255), round(g * 255), round(b * 255), round(a * 255)])
    rows.append(bytes(row))
    if py % 256 == 0:
        print(f"{py}/{N}", file=sys.stderr)


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
