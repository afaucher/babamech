"""Compose the adopted-enemy images from the raw shots of tools/enemy_detail/shots.gd.

usage: python make_adopted.py <raw dir> <out dir>
"""
import os
import sys
from PIL import Image, ImageDraw, ImageFont

raw, out = sys.argv[1], sys.argv[2]
BG = (24, 24, 28)


def font(sz, bold=False):
    for f in (("arialbd.ttf",) if bold else ()) + ("arial.ttf", "segoeui.ttf"):
        try:
            return ImageFont.truetype(f, sz)
        except OSError:
            pass
    return ImageFont.load_default()


def grid(items, cols, path, title, cw=960):
    pad, lab, head = 14, 34, 64
    ims = [(Image.open(os.path.join(raw, f)).convert("RGB"), l) for f, l in items if os.path.exists(os.path.join(raw, f))]
    if not ims:
        return
    ch = round(cw * ims[0][0].size[1] / ims[0][0].size[0])
    rows = -(-len(ims) // cols)
    g = Image.new("RGB", (cols * cw + (cols + 1) * pad, head + rows * (ch + lab + pad) + pad), BG)
    d = ImageDraw.Draw(g)
    d.text((pad, 18), title, fill=(240, 240, 240), font=font(30, True))
    for n, (im, label) in enumerate(ims):
        r, c = divmod(n, cols)
        x, y = pad + c * (cw + pad), head + pad + r * (ch + lab + pad)
        g.paste(im.resize((cw, ch), Image.LANCZOS), (x, y))
        d.text((x + 4, y + ch + 6), label, fill=(220, 220, 220), font=font(20))
    g.save(path)
    print(path)


grid([("adopted_lineup1.png", "Enforcer, Marksman and Salvo turrets"),
      ("adopted_lineup2.png", "Hound, Siege tank, Breacher"),
      ("adopted_lineup3.png", "Assault squad, Scout drone, Anti-armour squad"),
      ("adopted_lineup4.png", "Rocket gunship and Drop ship, hovering")], 2,
     os.path.join(out, "adopted_lineup.png"), "Enemies with the adopted detail pass, day city, three-quarter at ~20 m")
grid([("close_gunship_above.png", "above, front three-quarter"), ("close_gunship_below.png", "below, rear three-quarter")], 2,
     os.path.join(out, "adopted_gunship.png"), "Rocket gunship (gunship_hull / gunship_pods / gunship_thrusters)")
grid([("close_dropship_above.png", "above, front three-quarter"), ("close_dropship_below.png", "below, rear three-quarter")], 2,
     os.path.join(out, "adopted_dropship.png"), "Drop ship (dropship_hull / dropship_rotors / dropship_bay)")
