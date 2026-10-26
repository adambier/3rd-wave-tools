#!/usr/bin/env python3
"""Draws the pgdata Packer app icon and writes Resources/AppIcon.png (1024 px) and
Resources/AppIcon.icns.

    python3 tools/make-icon.py                       # the icon: Resources/AppIcon.icns and AppIcon.png
    python3 tools/make-icon.py --png out.png         # one 1024 px render somewhere else, nothing in Resources
    python3 tools/make-icon.py --sheet sheet.png     # a contact sheet: 1024 to 16 px on light and dark

Needs cairosvg and Pillow (pip install cairosvg pillow). The icon is drawn as SVG, rasterized at
each size the .icns holds (16, 32, 64, 128, 256, 512, and 1024 px, each drawn at its own size, with
fewer and heavier shapes at 32 px and below), and the .icns is assembled here, with the entry types
iconutil writes (icp4, icp5, ic07–ic14), so no macOS tool is needed.

The glyph: three frames of a wavetable, cyan, white, and pink, rising out of an open box
(settled with Adam on 2026-10-26). At 64 px and above they are the oscillator's waveforms drawn
exactly, two cycles each: a sine, a triangle, and a sawtooth, back to front, in strokes heavier
at 64 px (Adam, 2026-10-26: accurate waveforms, not squiggles, wherever they stay legible, the
Dock included). At 32 px and below, where exact shapes would not survive, they are two heavier
single-cycle sines, the front one leaning toward a saw.

The tile follows Apple's macOS icon grid for a flattened icon: an 824-point rounded square
centered on a 1024-point canvas, with a soft shadow, as macOS 13 to 15 draw it. Its corners are a
superellipse (exponent 5), an approximation of the continuous curve of Apple's icons. The glyph is
a few filled, overlapping shapes with no thin lines, as the Human Interface Guidelines ask, so it
also holds up where macOS 26 and later mask or shrink an icon that ships without an Icon Composer
file.
"""
import argparse, io, math, os, struct, sys
import cairosvg
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Resources")
S = 1024
TILE = (100, 100, 824, 824)          # x, y, w, h

def lerp(a, b, t): return a + (b - a) * t

def squircle_path(x, y, w, h, n=5.0, steps=96):
    """A superellipse |X|^n + |Y|^n = 1 fitted to the rectangle, as an SVG path."""
    cx, cy, rx, ry = x + w / 2, y + h / 2, w / 2, h / 2
    pts = []
    for i in range(4 * steps):
        a = 2 * math.pi * i / (4 * steps)
        c, s = math.cos(a), math.sin(a)
        pts.append((cx + rx * math.copysign(abs(c) ** (2 / n), c),
                    cy + ry * math.copysign(abs(s) ** (2 / n), s)))
    return "M" + " L".join("%.2f,%.2f" % p for p in pts) + " Z"

def leaned_sine(a, x):
    """A sine leaned like a saw by phase distortion: the rise takes (1 + a) / 2 of the cycle and
    the fall the rest, with no corners. a = 0 is a sine; a = 0.55 is clearly saw-like. At 32 px
    and below the box icon's frames are a = 0 and 0.55, back and front, so the morph between
    them is visible where exact shapes would not be (Adam, 2026-10-26: highlight the morphing)."""
    p = (x / (2 * math.pi)) % 1.0
    r = 0.5 * (1 + a)
    u = (p / r) * 0.5 if p < r else 0.5 + (p - r) / (1 - r) * 0.5
    return math.sin(2 * math.pi * u)

def shape_points(fn, cx, base, width, amp, n=200, cycles=1):
    """The points of one frame, `fn` over `cycles` cycles, scaled so every frame has the same
    height."""
    raw = [fn(j / n * 2 * math.pi * cycles) for j in range(n + 1)]
    peak = max(abs(v) for v in raw) or 1
    return [(cx - width / 2 + j / n * width, base - amp * raw[j] / peak) for j in range(n + 1)]

def triangle_points(cx, base, width, amp, cycles):
    """A triangle wave as its corners, starting and ending at the midline."""
    pts, x0, q = [], cx - width / 2, width / cycles / 4
    for c in range(cycles):
        xa = x0 + c / cycles * width
        pts += [(xa, base), (xa + q, base - amp), (xa + 3 * q, base + amp)]
    return pts + [(x0 + width, base)]

def sawtooth_points(cx, base, width, amp, cycles):
    """A sawtooth as its corners: a rise over each cycle and a vertical drop."""
    pts, x0 = [], cx - width / 2
    for c in range(cycles):
        pts += [(x0 + c / cycles * width, base + amp), (x0 + (c + 1) / cycles * width, base - amp)]
    return pts + [(x0 + width, base + amp)]

def path_d(pts, close=False):
    return "M" + " L".join("%.1f,%.1f" % p for p in pts) + (" Z" if close else "")

# Colors. The tile's blue is the one the icon has always had.
BLUE_TOP, BLUE_BOTTOM = "#4b7ccf", "#2444a6"
AMBER_TOP, AMBER_BOTTOM = "#f7bd5c", "#d8862a"
# The box icon's frames, back to front: cyan, white, pink, so the three read as three even at
# 32 px, where their shapes no longer do.
FRAME_COLORS = ("#7fdcff", "#ffffff", "#ff5fae")
FRAME_LEANS = (0.0, 0.3, 0.55)        # the leaned sines of the small sizes
FRAME_CYCLES = 2                      # cycles per frame at 64 px and above

def glyph_box(detail):
    """Three frames rising out of an open box. detail: 2 (32 px and below), 3 (64 px: the exact
    waveforms in heavy strokes, and the flaps), 4 (128 px and above: the exact waveforms, two
    cycles each, in thinner strokes, and the box's details). The glyph is centered
    on the tile: about 85 points above the back frame's crest and below the box (Adam,
    2026-10-26: neither the box weighing the bottom half nor the back frame crowding the top);
    the front frame's troughs dip behind the box front, so it rises out of the box."""
    bx, bw = 252, 520                      # the box front: x and width
    bottom, front = 830, 660               # y of the box bottom and the opening's front edge
    back = front - 60                      # y of the opening's back edge
    inset = 50
    out = []
    # The box's inside, behind the frames.
    out.append(f'<path d="M{bx+inset},{back} L{bx+bw-inset},{back} L{bx+bw},{front} L{bx},{front} Z" fill="#6a3b0b"/>')
    # The frames, back to front; at the small sizes only the back and front ones, heavier.
    indices = [0, 2] if detail <= 2 else [0, 1, 2]
    for i in indices:
        depth = 1 - i / 2
        cx = S / 2 + lerp(0, 24, depth)
        base = lerp(588, 290, depth) if len(indices) == 3 else lerp(588, 370, depth)
        amp = lerp(100, 80, depth)
        width = (380, 420, 460)[i]
        opacity = (0.85, 0.95, 1.0)[i]
        if detail >= 3:
            stroke = (28, 32, 36)[i] if detail >= 4 else (44, 50, 56)[i]
            if i == 0: pts = shape_points(math.sin, cx, base, width, amp, cycles=FRAME_CYCLES)
            elif i == 1: pts = triangle_points(cx, base, width, amp, FRAME_CYCLES)
            else: pts = sawtooth_points(cx, base, width, amp, FRAME_CYCLES)
        else:
            stroke = (70, 0, 86)[i]
            pts = shape_points(lambda x, a=FRAME_LEANS[i]: leaned_sine(a, x), cx, base, width, amp)
        out.append(f'<path d="{path_d(pts)}" fill="none" stroke="{FRAME_COLORS[i]}" stroke-width="{stroke}" '
                   f'stroke-linecap="round" stroke-linejoin="round" opacity="{opacity:.2f}"/>')
    # Side flaps, hinged on the opening's front corners and folded outwards.
    if detail >= 3:
        out.append(f'<path d="M{bx},{front} L{bx+inset},{back} L{bx-40},{back-52} L{bx-96},{front-36} Z" fill="#f0b355"/>')
        out.append(f'<path d="M{bx+bw},{front} L{bx+bw-inset},{back} L{bx+bw+40},{back-52} L{bx+bw+96},{front-36} Z" fill="#e39a37"/>')
    # The front of the box, over the bottom of the frames.
    out.append(f'<rect x="{bx}" y="{front}" width="{bw}" height="{bottom-front}" rx="26" fill="url(#amber)"/>')
    if detail >= 4:
        out.append(f'<rect x="{bx}" y="{front}" width="{bw}" height="16" rx="8" fill="#ffe0a3" opacity="0.7"/>')
        out.append(f'<rect x="{S/2-38}" y="{front}" width="76" height="{bottom-front}" fill="#c97a22" opacity="0.55"/>')
    return "\n".join(out)


def svg(size=S):
    x, y, w, h = TILE
    detail = 4 if size >= 128 else 3 if size >= 64 else 2
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">
<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="{BLUE_TOP}"/><stop offset="1" stop-color="{BLUE_BOTTOM}"/>
  </linearGradient>
  <radialGradient id="glow" cx="0.5" cy="0.30" r="0.65">
    <stop offset="0" stop-color="#8fbcff" stop-opacity="0.30"/><stop offset="1" stop-color="#8fbcff" stop-opacity="0"/>
  </radialGradient>
  <linearGradient id="amber" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="{AMBER_TOP}"/><stop offset="1" stop-color="{AMBER_BOTTOM}"/>
  </linearGradient>
  <clipPath id="tile"><path d="{squircle_path(x, y, w, h)}"/></clipPath>
</defs>
<g clip-path="url(#tile)">
  <rect x="{x}" y="{y}" width="{w}" height="{h}" fill="url(#bg)"/>
  <rect x="{x}" y="{y}" width="{w}" height="{h}" fill="url(#glow)"/>
  {glyph_box(detail)}
</g>
</svg>'''

def render(size=S):
    png = cairosvg.svg2png(bytestring=svg(size).encode(), output_width=size, output_height=size)
    art = Image.open(io.BytesIO(png)).convert("RGBA")
    # The soft shadow under the tile that macOS 13 to 15 expect in the icon itself.
    scale = size / S
    x, y, w, h = [v * scale for v in TILE]
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([x, y + 10 * scale, x + w, y + h + 10 * scale], 185 * scale, fill=80)
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 255))
    shadow.putalpha(mask.filter(ImageFilter.GaussianBlur(14 * scale)))
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.alpha_composite(shadow)
    out.alpha_composite(art)
    return out

# The entries iconutil writes for an iconset: (type, pixels).
ICNS_ENTRIES = [(b"icp4", 16), (b"ic11", 32), (b"icp5", 32), (b"ic12", 64), (b"ic07", 128),
                (b"ic13", 256), (b"ic08", 256), (b"ic14", 512), (b"ic09", 512), (b"ic10", 1024)]

def write_icns(images, path):
    """images: {pixels: Image}. Writes the icns container: header, TOC, then one PNG per entry."""
    entries = []
    for kind, px in ICNS_ENTRIES:
        buf = io.BytesIO(); images[px].save(buf, "PNG"); entries.append((kind, buf.getvalue()))
    toc = b"TOC " + struct.pack(">I", 8 + 8 * len(entries)) + b"".join(k + struct.pack(">I", 8 + len(d)) for k, d in entries)
    body = b"".join(k + struct.pack(">I", 8 + len(d)) + d for k, d in entries)
    with open(path, "wb") as f:
        f.write(b"icns" + struct.pack(">I", 8 + len(toc) + len(body)) + toc + body)

def read_icns(path):
    """Returns [(type, length)] from the file's headers; raises if the container is malformed."""
    data = open(path, "rb").read()
    assert data[:4] == b"icns" and struct.unpack(">I", data[4:8])[0] == len(data), "bad icns header"
    out, o = [], 8
    while o < len(data):
        kind, length = data[o:o+4], struct.unpack(">I", data[o+4:o+8])[0]
        assert 8 <= length <= len(data) - o, "bad entry length"
        out.append((kind.decode("latin-1"), length)); o += length
    return out

def contact_sheet(path):
    """The icon at 1024 (shown at 512), 512 (at 256), 128, 64, 32, and 16 px, on light and dark."""
    sizes = [(1024, 512), (512, 256), (128, 128), (64, 64), (32, 32), (16, 16)]
    gap, pad = 36, 40
    row_w = pad + sum(shown + gap for _, shown in sizes) + pad
    row_h = 512 + 2 * pad
    sheet = Image.new("RGBA", (row_w, row_h * 2), (0, 0, 0, 0))
    renders = {px: render(px) for px, _ in sizes}
    for b, bgcolor in enumerate(((238, 238, 240, 255), (30, 30, 34, 255))):
            top = b * row_h
            sheet.paste(Image.new("RGBA", (row_w, row_h), bgcolor), (0, top))
            xo = pad
            for px, shown in sizes:
                im = renders[px] if shown == px else renders[px].resize((shown, shown), Image.LANCZOS)
                sheet.alpha_composite(im, (xo, top + pad + (512 - shown) // 2))
                xo += shown + gap
    sheet.save(path)

if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Draws the pgdata Packer app icon.")
    ap.add_argument("--png", metavar="FILE", help="write one 1024 px render here and nothing to Resources")
    ap.add_argument("--sheet", metavar="FILE", help="write a contact sheet of the icon at every size here and nothing to Resources")
    args = ap.parse_args()
    if args.sheet:
        contact_sheet(args.sheet); print("wrote", args.sheet); sys.exit()
    if args.png:
        render().save(args.png); print("wrote", args.png); sys.exit()
    os.makedirs(OUT, exist_ok=True)
    images = {px: render(px) for px in (16, 32, 64, 128, 256, 512, 1024)}
    images[1024].save(os.path.join(OUT, "AppIcon.png"))
    icns = os.path.join(OUT, "AppIcon.icns")
    write_icns(images, icns)
    print("wrote", icns, "with", ", ".join(f"{k} {n}" for k, n in read_icns(icns)))
