"""Poster for the README: a still of the brand scene + a 'play' pill."""
import os, sys
from PIL import Image, ImageDraw, ImageFont

src, out, label = sys.argv[1], sys.argv[2], sys.argv[3]
im = Image.open(src).convert("RGB")
W, H = im.size
S = 3  # supersample the overlay for smooth edges
ov = Image.new("RGBA", (W * S, H * S), (0, 0, 0, 0))
d = ImageDraw.Draw(ov)
font = ImageFont.truetype(os.path.expanduser("~/Library/Fonts/NotoSansKR-Bold.otf"), 34 * S)
tw = d.textlength(label, font=font)
ph, circ, gap, padl, padr = 84 * S, 60 * S, 20 * S, 12 * S, 38 * S
pw = padl + circ + gap + tw + padr
x0, y0 = (W * S - pw) / 2, 930 * S
d.rounded_rectangle([x0, y0, x0 + pw, y0 + ph], radius=ph / 2, fill=(255, 255, 255, 235))
cx, cy = x0 + padl + circ / 2, y0 + ph / 2
d.ellipse([cx - circ / 2, cy - circ / 2, cx + circ / 2, cy + circ / 2], fill=(139, 63, 234, 255))
r = 15 * S
d.polygon([(cx - r * 0.7, cy - r), (cx - r * 0.7, cy + r), (cx + r * 1.05, cy)], fill=(255, 255, 255, 255))
d.text((x0 + padl + circ + gap, cy), label, font=font, fill=(20, 20, 30, 255), anchor="lm")
ov = ov.resize((W, H), Image.LANCZOS)
im.paste(ov, (0, 0), ov)
im.resize((1280, 720), Image.LANCZOS).save(out, quality=88, optimize=True, progressive=True)
print("wrote", out)
