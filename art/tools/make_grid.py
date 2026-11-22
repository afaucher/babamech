"""Assemble a labeled grid (default 3x3) from images.

usage: python make_grid.py [--cols N] out.png "title" img1.png|label1 ...
"""
import sys
from PIL import Image, ImageDraw, ImageFont

args = sys.argv[1:]
cols = 3
if args[0] == "--cols":
    cols, args = int(args[1]), args[2:]
out, title, items = args[0], args[1], args[2:]
rows = -(-len(items) // cols)
cell, pad, lab, head = 512, 12, 40, 60
_w, _h = Image.open(items[0].rsplit("|", 1)[0]).size
cell_h = round(cell * _h / _w)  # keep the source aspect ratio

def font(sz):
    for f in ("arialbd.ttf", "arial.ttf", "segoeui.ttf"):
        try:
            return ImageFont.truetype(f, sz)
        except OSError:
            pass
    return ImageFont.load_default()

W = cols * cell + (cols + 1) * pad
H = head + rows * (cell_h + lab) + (rows + 1) * pad
g = Image.new("RGB", (W, H), (24, 24, 28))
d = ImageDraw.Draw(g)
d.text((pad, 14), title, fill=(240, 240, 240), font=font(32))
for n, it in enumerate(items):
    path, label = it.rsplit("|", 1) if "|" in it else (it, "")
    r, c = divmod(n, cols)
    x = pad + c * (cell + pad)
    y = head + pad + r * (cell_h + lab + pad)
    im = Image.open(path).convert("RGB").resize((cell, cell_h), Image.LANCZOS)
    g.paste(im, (x, y))
    d.text((x + 4, y + cell_h + 6), f"{n + 1}. {label}", fill=(230, 230, 230), font=font(24))
g.save(out)
print(out)
