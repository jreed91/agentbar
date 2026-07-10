#!/usr/bin/env python3
"""Generate the AgentBar app icon — no third-party dependencies.

This script is the source of truth for the app icon. It rasterizes the design
(a dark-green phosphor-terminal squircle with a glowing green mascot face and
faint CRT scanlines, echoing the "Live feed" popover) at every size macOS
needs and packs them into a PNG-based `.icns`.

Usage:
    python3 scripts/generate-icon.py [OUT_ICNS] [--png OUT_1024_PNG]

Defaults to writing app/Support/AppIcon.icns. Rendering is pure Python
(stdlib zlib only), so it runs anywhere — the committed .icns can be
regenerated on Linux or macOS without ImageMagick/rsvg/iconutil.
"""
import math
import os
import struct
import sys
import zlib

# ---- palette (the phosphor terminal from design 2a) ----------------------
WALL_TOP = (0x12, 0x30, 0x24)   # #123024 terminal green, top
WALL_MID = (0x0c, 0x22, 0x1a)   # #0c221a mid stop (~60%)
WALL_BOT = (0x08, 0x16, 0x0f)   # #08160f terminal green, bottom
FACE     = (0x46, 0xe0, 0x7f)   # #46e07f bright phosphor green (eyes + smile)
GLOW     = (0x8a, 0xff, 0xb0)   # #8affb0 lighter phosphor, used for the bloom


def lerp(a, b, t):
    return a + (b - a) * t


def grad(ny):
    """Three-stop vertical terminal gradient (top → mid@0.6 → bottom)."""
    if ny < 0.6:
        t = ny / 0.6
        c = tuple(lerp(WALL_TOP[i], WALL_MID[i], t) for i in range(3))
    else:
        t = (ny - 0.6) / 0.4
        c = tuple(lerp(WALL_MID[i], WALL_BOT[i], t) for i in range(3))
    return tuple(v / 255.0 for v in c)


# ---- geometry (normalized 0..1 canvas, y down) ---------------------------
MARGIN = 0.06
HW = 0.5 - MARGIN            # squircle half-width
SQ_N = 5.0                   # superellipse exponent (squircle)

# Mascot face — two round eyes over a U-shaped (bottom-arc) smile.
EYE_L, EYE_R_C = (0.375, 0.42), (0.625, 0.42)
EYE_R = 0.052
MOUTH_C = (0.5, 0.40)       # smile is the lower arc of a ring centered here
MOUTH_R_IN, MOUTH_R_OUT = 0.17, 0.216
MOUTH_DROP = 0.055          # how far below center the smile begins (trims the sides)

FACE_CENTER = (0.5, 0.46)   # source of the phosphor bloom
RIM_START = 0.86            # squircle "s" value where the edge glow ramps in


def inside_circle(x, y, c, r):
    dx, dy = x - c[0], y - c[1]
    return dx * dx + dy * dy <= r * r


def squircle_s(x, y):
    u = abs((x - 0.5) / HW)
    v = abs((y - 0.5) / HW)
    return u ** SQ_N + v ** SQ_N


def inside_smile(x, y):
    dx, dy = x - MOUTH_C[0], y - MOUTH_C[1]
    if dy <= MOUTH_DROP:            # keep only the lower arc → a smile, not a ring
        return False
    d = math.hypot(dx, dy)
    return MOUTH_R_IN <= d <= MOUTH_R_OUT


def inside_face(x, y):
    return (inside_circle(x, y, EYE_L, EYE_R)
            or inside_circle(x, y, EYE_R_C, EYE_R)
            or inside_smile(x, y))


def color_at(x, y):
    """Return (r, g, b, a) floats in 0..1 for a normalized point."""
    s = squircle_s(x, y)
    if s > 1.0:
        return (0.0, 0.0, 0.0, 0.0)

    r, g, b = grad(y)

    # Faint CRT scanlines: darken in a fine horizontal band pattern.
    scan = 1.0 - 0.05 * (0.5 + 0.5 * math.cos(y * 2.0 * math.pi * 20.0))
    r, g, b = r * scan, g * scan, b * scan

    # Phosphor bloom: a soft green glow radiating from the face center.
    dfc = math.hypot(x - FACE_CENTER[0], y - FACE_CENTER[1])
    bloom = max(0.0, 1.0 - dfc / 0.46) ** 2 * 0.16
    r = min(1.0, r + GLOW[0] / 255.0 * bloom)
    g = min(1.0, g + GLOW[1] / 255.0 * bloom)
    b = min(1.0, b + GLOW[2] / 255.0 * bloom)

    # Edge glow: a bright green rim hugging the squircle border.
    if s >= RIM_START:
        t = min(1.0, (s - RIM_START) / (1.0 - RIM_START))
        r = lerp(r, FACE[0] / 255.0, t * 0.7)
        g = lerp(g, FACE[1] / 255.0, t * 0.7)
        b = lerp(b, FACE[2] / 255.0, t * 0.7)

    # The mascot face, on top of everything.
    if inside_face(x, y):
        r, g, b = (c / 255.0 for c in FACE)

    return (r, g, b, 1.0)


# ---- rendering -----------------------------------------------------------
def render(size, ss=3):
    """Return an RGBA8 bytearray of side `size`, supersampled ss x ss."""
    buf = bytearray(size * size * 4)
    inv = 1.0 / (size * ss)
    samples = ss * ss
    for py in range(size):
        row = py * size * 4
        for px in range(size):
            ar = ag = ab = aa = 0.0
            for sy in range(ss):
                ny = (py * ss + sy + 0.5) * inv
                for sx in range(ss):
                    nx = (px * ss + sx + 0.5) * inv
                    cr, cg, cb, ca = color_at(nx, ny)
                    ar += cr * ca
                    ag += cg * ca
                    ab += cb * ca
                    aa += ca
            o = row + px * 4
            if aa > 0:
                buf[o] = min(255, int(ar / aa * 255 + 0.5))
                buf[o + 1] = min(255, int(ag / aa * 255 + 0.5))
                buf[o + 2] = min(255, int(ab / aa * 255 + 0.5))
            buf[o + 3] = min(255, int(aa / samples * 255 + 0.5))
    return buf


def downsample(src, size, factor):
    """Box-downsample RGBA8 `src` of side `size` by integer `factor`."""
    out = size // factor
    dst = bytearray(out * out * 4)
    f2 = factor * factor
    for oy in range(out):
        for ox in range(out):
            ar = ag = ab = aa = 0
            for dy in range(factor):
                sy = oy * factor + dy
                base = (sy * size + ox * factor) * 4
                for dx in range(factor):
                    o = base + dx * 4
                    a = src[o + 3]
                    ar += src[o] * a
                    ag += src[o + 1] * a
                    ab += src[o + 2] * a
                    aa += a
            o = (oy * out + ox) * 4
            if aa > 0:
                dst[o] = int(ar / aa + 0.5)
                dst[o + 1] = int(ag / aa + 0.5)
                dst[o + 2] = int(ab / aa + 0.5)
            dst[o + 3] = int(aa / f2 + 0.5)
    return dst


# ---- PNG / ICNS encoders -------------------------------------------------
def png_bytes(buf, size):
    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data +
                struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))

    stride = size * 4
    raw = bytearray()
    for y in range(size):
        raw.append(0)  # filter: none
        raw += buf[y * stride:(y + 1) * stride]
    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" +
            chunk(b"IHDR", ihdr) +
            chunk(b"IDAT", zlib.compress(bytes(raw), 9)) +
            chunk(b"IEND", b""))


# ICNS OSType -> (pixel size). PNG payloads are valid for all of these.
ICNS_TYPES = [
    (b"icp4", 16), (b"icp5", 32),
    (b"ic07", 128), (b"ic08", 256), (b"ic09", 512), (b"ic10", 1024),
    (b"ic11", 32), (b"ic12", 64), (b"ic13", 256), (b"ic14", 512),
]


def icns_bytes(pngs_by_size):
    body = bytearray()
    for ostype, sz in ICNS_TYPES:
        data = pngs_by_size[sz]
        body += ostype + struct.pack(">I", len(data) + 8) + data
    return b"icns" + struct.pack(">I", len(body) + 8) + bytes(body)


def main():
    args = [a for a in sys.argv[1:]]
    png_out = None
    if "--png" in args:
        i = args.index("--png")
        png_out = args[i + 1]
        del args[i:i + 2]
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    icns_out = args[0] if args else os.path.join(repo_root, "app", "Support", "AppIcon.icns")

    print("==> Rendering master (1024, ss=3)…")
    master = render(1024, ss=3)

    needed = sorted({sz for _, sz in ICNS_TYPES}, reverse=True)
    pngs = {}
    cache = {1024: master}
    for sz in needed:
        if sz not in cache:
            cache[sz] = downsample(master, 1024, 1024 // sz)
        pngs[sz] = png_bytes(cache[sz], sz)
        print(f"    rendered {sz}x{sz}")

    os.makedirs(os.path.dirname(icns_out), exist_ok=True)
    with open(icns_out, "wb") as f:
        f.write(icns_bytes(pngs))
    print(f"==> Wrote {icns_out} ({os.path.getsize(icns_out)} bytes)")

    if png_out:
        with open(png_out, "wb") as f:
            f.write(pngs[1024])
        print(f"==> Wrote {png_out}")


if __name__ == "__main__":
    main()
