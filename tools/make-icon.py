#!/usr/bin/env python3
"""Draws the pgdata Packer app icon and writes Resources/AppIcon.png (1024 px) and
Resources/AppIcon.icns.

    python3 tools/make-icon.py                       # the icon: Resources/AppIcon.icns and AppIcon.png
    python3 tools/make-icon.py --variant stack       # the other candidate instead
    python3 tools/make-icon.py --png out.png         # one 1024 px render somewhere else, nothing in Resources
    python3 tools/make-icon.py --sheet sheet.png     # a contact sheet: 1024 to 16 px on light and dark

Needs cairosvg and Pillow (pip install cairosvg pillow). The icon is drawn as SVG, rasterized at
each size the .icns holds (16, 32, 64, 128, 256, 512, and 1024 px, each drawn at its own size, with
fewer and heavier shapes at 32 px and below), and the .icns is assembled here, with the entry types
iconutil writes (icp4, icp5, ic07–ic14), so no macOS tool is needed.

Two candidates share the tile and differ in the glyph:

- box (the icon): a stack of three morphing frames rising out of an open box.
- stack: the frames alone, as filled sheets stacked in perspective.

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

def wave(t, x):
    """One frame of the table: a sine at t = 0 morphing towards a saw at t = 1 (five
    harmonics with Lanczos smoothing, so the shape stays clean at small sizes)."""
    v = 0.0
    for k in range(1, 6):
        sigma = 1.0 if k == 1 else math.sin(math.pi * k / 6) / (math.pi * k / 6)
        weight = 1.0 if k == 1 else t ** 1.3
        v += weight * sigma * math.sin(k * x) / k
    return v / (1 + 0.55 * t)

def wave_points(cx, base, width, amp, t, n=120):
    pts = []
    for j in range(n + 1):
        x = j / n
        pts.append((cx - width / 2 + x * width, base - amp * wave(t, x * 2 * math.pi)))
    return pts

def path_d(pts, close=False):
    return "M" + " L".join("%.1f,%.1f" % p for p in pts) + (" Z" if close else "")

# Colors. The tile's blue is the one the icon has always had.
BLUE_TOP, BLUE_BOTTOM = "#4b7ccf", "#2444a6"
AMBER_TOP, AMBER_BOTTOM = "#f7bd5c", "#d8862a"
FRAME_COLORS = ("#9fc4ff", "#d6e7ff", "#ffffff")      # back to front

def glyph_box(detail):
    """A stack of frames rising out of an open box. detail: 2 (small sizes), 3 (64 px), 4 (full)."""
    bx, bw = 252, 520                      # the box front: x and width
    back, front, bottom = 556, 616, 832    # y of the opening's back edge, its front edge, the box bottom
    inset = 50
    out = []
    # The box's inside, behind the frames.
    out.append(f'<path d="M{bx+inset},{back} L{bx+bw-inset},{back} L{bx+bw},{front} L{bx},{front} Z" fill="#6a3b0b"/>')
    # The frames, back to front, evenly stacked; the front one's trough dips into the box.
    count = 2 if detail <= 2 else 3
    for i in range(count):
        t = i / (count - 1)
        depth = 1 - t
        width = lerp(450, 370, depth)
        cx = S / 2 + lerp(0, 26, depth)
        base = lerp(538, 318, depth) if count == 3 else lerp(538, 390, depth)
        amp = lerp(96, 78, depth)
        stroke = lerp(66, 46, depth) if detail >= 3 else lerp(86, 66, depth)
        color = FRAME_COLORS[i + (3 - count)]
        opacity = lerp(1.0, 0.68, depth)
        shape = 0.6 * depth                 # a clean sine in front, sharper frames behind
        out.append(f'<path d="{path_d(wave_points(cx, base, width, amp, shape))}" fill="none" stroke="{color}" '
                   f'stroke-width="{stroke:.0f}" stroke-linecap="round" stroke-linejoin="round" opacity="{opacity:.2f}"/>')
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

def glyph_stack(detail):
    """The frames alone: filled ribbons stacked in perspective, back to front, as a wavetable
    is usually pictured."""
    count = 3 if detail <= 2 else 4
    out = []
    for i in range(count):
        t = i / (count - 1)
        depth = 1 - t
        width = lerp(540, 420, depth)
        cx = S / 2 + lerp(0, 30, depth)
        base = lerp(690, 330, depth) if count == 4 else lerp(690, 400, depth)
        amp = lerp(120, 84, depth)
        thickness = lerp(88, 64, depth) if detail >= 3 else lerp(110, 90, depth)
        top = wave_points(cx, base, width, amp, 0.6 * depth)   # a clean sine in front, sharper frames behind
        ribbon = top + [(x, y + thickness) for x, y in reversed(top)]
        shade = ("#8fb9ff", "#b9d5ff", "#dfecff", "#ffffff")[i + (4 - count)]
        opacity = lerp(1.0, 0.66, depth)
        out.append(f'<path d="{path_d(ribbon, close=True)}" fill="{shade}" opacity="{opacity:.2f}" '
                   f'stroke="{shade}" stroke-width="12" stroke-linejoin="round"/>')
    return "\n".join(out)

GLYPHS = {"box": glyph_box, "stack": glyph_stack}

def svg(variant, size=S):
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
  {GLYPHS[variant](detail)}
</g>
</svg>'''

def render(variant, size=S):
    png = cairosvg.svg2png(bytestring=svg(variant, size).encode(), output_width=size, output_height=size)
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

def contact_sheet(variants, path):
    """Each variant at 1024 (shown at 512), 512 (at 256), 128, 64, 32, and 16 px, on light and dark."""
    sizes = [(1024, 512), (512, 256), (128, 128), (64, 64), (32, 32), (16, 16)]
    gap, pad = 36, 40
    row_w = pad + sum(shown + gap for _, shown in sizes) + pad
    row_h = 512 + 2 * pad
    sheet = Image.new("RGBA", (row_w, row_h * 2 * len(variants)), (0, 0, 0, 0))
    for v, variant in enumerate(variants):
        renders = {px: render(variant, px) for px, _ in sizes}
        for b, bgcolor in enumerate(((238, 238, 240, 255), (30, 30, 34, 255))):
            top = (2 * v + b) * row_h
            sheet.paste(Image.new("RGBA", (row_w, row_h), bgcolor), (0, top))
            xo = pad
            for px, shown in sizes:
                im = renders[px] if shown == px else renders[px].resize((shown, shown), Image.LANCZOS)
                sheet.alpha_composite(im, (xo, top + pad + (512 - shown) // 2))
                xo += shown + gap
    sheet.save(path)

if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Draws the pgdata Packer app icon.")
    ap.add_argument("--variant", choices=sorted(GLYPHS), default="box")
    ap.add_argument("--png", metavar="FILE", help="write one 1024 px render here and nothing to Resources")
    ap.add_argument("--sheet", metavar="FILE", help="write a contact sheet of every variant here and nothing to Resources")
    args = ap.parse_args()
    if args.sheet:
        contact_sheet(sorted(GLYPHS), args.sheet); print("wrote", args.sheet); sys.exit()
    if args.png:
        render(args.variant).save(args.png); print("wrote", args.png); sys.exit()
    os.makedirs(OUT, exist_ok=True)
    images = {px: render(args.variant, px) for px in (16, 32, 64, 128, 256, 512, 1024)}
    images[1024].save(os.path.join(OUT, "AppIcon.png"))
    icns = os.path.join(OUT, "AppIcon.icns")
    write_icns(images, icns)
    print("wrote", icns, "with", ", ".join(f"{k} {n}" for k, n in read_icns(icns)))
