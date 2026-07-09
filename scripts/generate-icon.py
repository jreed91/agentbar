#!/usr/bin/env python3
"""Generate the AgentBar app icon — no third-party dependencies.

This script is the source of truth for the app icon. It rasterizes the design
(a graphite squircle with a white notification bell and a Claude-coral badge,
echoing the app's menu-bar `bell.badge.fill` glyph) at every size macOS needs
and packs them into a PNG-based `.icns`.

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

# ---- palette -------------------------------------------------------------
GRAD_TOP    = (0x3B, 0x3E, 0x46)   # graphite, light
GRAD_BOTTOM = (0x18, 0x19, 0x1D)   # graphite, dark
BELL        = (0xF6, 0xF6, 0xF8)   # near-white
BADGE       = (0xD9, 0x77, 0x57)   # Claude coral


def lerp(a, b, t):
    return a + (b - a) * t


def grad(ny):
    return tuple(lerp(GRAD_TOP[i], GRAD_BOTTOM[i], ny) / 255.0 for i in range(3))


# ---- geometry (normalized 0..1 canvas, y down) ---------------------------
MARGIN = 0.055
HW = 0.5 - MARGIN            # squircle half-width
SQ_N = 5.0                   # superellipse exponent (squircle)

DOME_C, DOME_R = (0.5, 0.435), 0.205
FLARE_Y0, FLARE_Y1 = 0.435, 0.665
FLARE_W0, FLARE_W1 = 0.205, 0.285
RIM_Y, RIM_HALF, RIM_R = 0.665, 0.285, 0.033
KNOB_C, KNOB_R = (0.5, 0.205), 0.05
CLAP_C, CLAP_R = (0.5, 0.745), 0.052
BADGE_C, BADGE_R, RING_R = (0.70, 0.305), 0.108, 0.150


def inside_circle(x, y, c, r):
    dx, dy = x - c[0], y - c[1]
    return dx * dx + dy * dy <= r * r


def inside_squircle(x, y):
    u = abs((x - 0.5) / HW)
    v = abs((y - 0.5) / HW)
    return (u ** SQ_N + v ** SQ_N) <= 1.0


def inside_bell(x, y):
    if inside_circle(x, y, DOME_C, DOME_R):
        return True
    if inside_circle(x, y, KNOB_C, KNOB_R):
        return True
    if inside_circle(x, y, CLAP_C, CLAP_R):
        return True
    if FLARE_Y0 <= y <= FLARE_Y1:
        t = (y - FLARE_Y0) / (FLARE_Y1 - FLARE_Y0)
        if abs(x - 0.5) <= lerp(FLARE_W0, FLARE_W1, t):
            return True
    dx = abs(x - 0.5)
    if dx <= RIM_HALF:
        if abs(y - RIM_Y) <= RIM_R:
            return True
    else:
        ex = 0.5 + (RIM_HALF if x > 0.5 else -RIM_HALF)
        if inside_circle(x, y, (ex, RIM_Y), RIM_R):
            return True
    return False


def color_at(x, y):
    """Return (r, g, b, a) floats in 0..1 for a normalized point."""
    if not inside_squircle(x, y):
        return (0.0, 0.0, 0.0, 0.0)
    r, g, b = grad(y)
    if inside_bell(x, y):
        r, g, b = (c / 255.0 for c in BELL)
    # Separation ring: recolor the gap around the badge back to the background.
    if inside_circle(x, y, BADGE_C, RING_R) and not inside_circle(x, y, BADGE_C, BADGE_R):
        r, g, b = grad(y)
    if inside_circle(x, y, BADGE_C, BADGE_R):
        r, g, b = (c / 255.0 for c in BADGE)
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
