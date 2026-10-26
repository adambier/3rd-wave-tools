#!/usr/bin/env python3
"""Draws the pgdata Packer app icon: a wavetable (a stack of morphing waveforms seen in
perspective) rising out of an open box, on a blue rounded-square tile.

    python3 tools/make-icon.py            # writes Resources/AppIcon.icns and Resources/AppIcon.png

Needs cairosvg and Pillow (pip install cairosvg pillow). The tile follows the macOS icon grid:
an 824-point rounded square centered on a 1024-point canvas, with a soft shadow.
"""
import io, math, os, sys
import cairosvg
from PIL import Image, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Resources")
S = 1024
TILE = (100, 100, 824, 824)          # x, y, w, h
RADIUS = 185

def lerp(a, b, t): return a + (b - a) * t
def mix(c1, c2, t):
    return "#%02x%02x%02x" % tuple(round(lerp(int(c1[i:i+2], 16), int(c2[i:i+2], 16), t)) for i in (1, 3, 5))

def wave(t, x):
    """One frame of the table: a sine at t = 0 morphing smoothly toward a saw at t = 1
    (five harmonics with Lanczos smoothing, so the lines stay clean at small sizes)."""
    v = 0.0
    for k in range(1, 6):
        sigma = 1.0 if k == 1 else math.sin(math.pi * k / 6) / (math.pi * k / 6)
        weight = 1.0 if k == 1 else t ** 1.3
        v += weight * sigma * math.sin(k * x) / k
    return v / (1 + 0.55 * t)

BOX_X, BOX_W = S / 2 - 240, 480
BOX_BACK, BOX_FRONT, BOX_BOTTOM = 585, 640, 832    # y of the back edge, front edge and bottom

def frames():
    n = 6
    paths = []
    for i in range(n):                      # back (i = 0) to front
        t = i / (n - 1)
        depth = 1 - t                       # 1 at the back
        width = lerp(380, 300, depth)       # nearer frames are wider
        cx = S / 2 + lerp(-6, 46, depth)    # receding up and to the right
        base = lerp(612, 330, depth)        # baseline y; the front ones sink into the box
        amp = lerp(108, 78, depth)
        pts = []
        for j in range(161):
            x = j / 160
            y = base - amp * wave(t, x * 2 * math.pi)
            pts.append((cx - width / 2 + x * width, y))
        d = "M" + " L".join("%.1f,%.1f" % p for p in pts)
        color = mix("#eaf6ff", "#ff5fd2", t)
        opacity = lerp(0.6, 1.0, t)
        stroke = lerp(12, 17, t)
        paths.append(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{stroke:.1f}" '
                     f'stroke-linecap="round" stroke-linejoin="round" opacity="{opacity:.2f}"/>')
    return "\n".join(paths)

def svg():
    x, y, w, h = TILE
    bx, bw, back, front, bottom = BOX_X, BOX_W, BOX_BACK, BOX_FRONT, BOX_BOTTOM
    inset = 44                               # how far the back edge sits inside the front corners
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">
<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#4674c2"/><stop offset="1" stop-color="#2243a3"/>
  </linearGradient>
  <radialGradient id="glow" cx="0.5" cy="0.40" r="0.55">
    <stop offset="0" stop-color="#7fb0ff" stop-opacity="0.35"/><stop offset="1" stop-color="#7fb0ff" stop-opacity="0"/>
  </radialGradient>
  <linearGradient id="boxFront" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#f4b552"/><stop offset="1" stop-color="#c97a1c"/>
  </linearGradient>
  <linearGradient id="boxInside" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#6e420f"/><stop offset="1" stop-color="#9c5d18"/>
  </linearGradient>
  <linearGradient id="flapBack" x1="0" y1="1" x2="0" y2="0">
    <stop offset="0" stop-color="#b36d1c"/><stop offset="1" stop-color="#d9913a"/>
  </linearGradient>
  <clipPath id="tile"><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{RADIUS}"/></clipPath>
</defs>
<g clip-path="url(#tile)">
  <rect x="{x}" y="{y}" width="{w}" height="{h}" fill="url(#bg)"/>
  <rect x="{x}" y="{y}" width="{w}" height="{h}" fill="url(#glow)"/>
  <!-- back flap, then the inside of the box, both behind the waves -->
  <path d="M{bx+inset},{back} L{bx+bw-inset},{back} L{bx+bw-inset-24},{back-92} L{bx+inset+24},{back-92} Z" fill="url(#flapBack)" opacity="0.9"/>
  <path d="M{bx+inset},{back} L{bx+bw-inset},{back} L{bx+bw},{front} L{bx},{front} Z" fill="url(#boxInside)"/>
  {frames()}
  <!-- side flaps, hinged on the box's top side edges and folded outwards -->
  <path d="M{bx},{front} L{bx+inset},{back} L{bx-38},{back-58} L{bx-92},{front-34} Z" fill="#e8a443"/>
  <path d="M{bx+bw},{front} L{bx+bw-inset},{back} L{bx+bw+38},{back-58} L{bx+bw+92},{front-34} Z" fill="#d38a2c"/>
  <!-- front of the box, over the bottom of the waves, with a strip of tape -->
  <rect x="{bx}" y="{front}" width="{bw}" height="{bottom-front}" rx="16" fill="url(#boxFront)"/>
  <rect x="{bx}" y="{front}" width="{bw}" height="14" fill="#ffd683" opacity="0.65"/>
  <rect x="{S/2-34}" y="{front}" width="68" height="{bottom-front}" fill="#e39d36"/>
</g>
<rect x="{x+1}" y="{y+1}" width="{w-2}" height="{h-2}" rx="{RADIUS}" fill="none" stroke="#ffffff" stroke-opacity="0.10" stroke-width="2"/>
</svg>'''

def render(size=S):
    png = cairosvg.svg2png(bytestring=svg().encode(), output_width=size, output_height=size)
    art = Image.open(io.BytesIO(png)).convert("RGBA")
    # Soft shadow under the tile, as macOS icons have.
    scale = size / S
    x, y, w, h = [v * scale for v in TILE]
    mask = Image.new("L", (size, size), 0)
    from PIL import ImageDraw
    ImageDraw.Draw(mask).rounded_rectangle([x, y + 12 * scale, x + w, y + h + 12 * scale], RADIUS * scale, fill=110)
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 255))
    shadow.putalpha(mask.filter(ImageFilter.GaussianBlur(14 * scale)))
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.alpha_composite(shadow)
    out.alpha_composite(art)
    return out

if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    master = render(S)
    master.save(os.path.join(OUT, "AppIcon.png"))
    smaller = [render(s) for s in (16, 32, 64, 128, 256, 512)]   # each drawn at its own size, not downscaled
    master.save(os.path.join(OUT, "AppIcon.icns"), append_images=smaller)
    if len(sys.argv) > 1:   # preview sheet: the icon at several sizes on light and dark
        sheet = Image.new("RGBA", (1500, 620), (236, 236, 236, 255))
        dark = Image.new("RGBA", (750, 310), (40, 40, 44, 255)); sheet.paste(dark, (750, 310))
        sheet.alpha_composite(master.resize((512, 512), Image.LANCZOS), (40, 54))
        xo = 600
        for s in (256, 128, 64, 32, 16):
            im = render(s)
            sheet.alpha_composite(im, (xo, 40)); sheet.alpha_composite(im, (xo + 150, 330)) if xo + 150 + s < 1500 else None
            xo += s + 30
        sheet.save(sys.argv[1])
    print("wrote", os.path.join(OUT, "AppIcon.icns"))
