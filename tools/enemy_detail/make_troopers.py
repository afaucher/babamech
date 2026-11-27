"""Compose the trooper look-variant images from the raw shots of tools/enemy_detail/trooper_shots.gd.

usage: python make_troopers.py <raw dir> <out dir>
The variant choices mirror EnemyMeshes.trooper_look (scripts/enemy/looks/enemy_meshes.gd).
"""
import os
import sys
from PIL import Image, ImageDraw, ImageFont

raw, out = sys.argv[1], sys.argv[2]
BG = (24, 24, 28)
BUILDS = ["slim", "standard", "heavy"]
HELMETS = ["dome + visor", "angular crest", "flat-top + comm box"]
GEAR = ["jump pack", "radio pack + whip", "pouch belt + low pack"]
MARKS = ["chest band", "chevron", "sash"]
N = 12


def look(n):
    q = n // 3
    return {"build": (n + 1) % 3, "helmet": q % 3, "gear": (n % 3 + q + n // 9) % 3, "mark": (n // 2) % 3,
            "leader": n % 4 == 0}


def font(sz, bold=False):
    for f in (("arialbd.ttf",) if bold else ()) + ("arial.ttf", "segoeui.ttf"):
        try:
            return ImageFont.truetype(f, sz)
        except OSError:
            pass
    return ImageFont.load_default()


def cell(n, h=470):
    """Front and rear three-quarter crops of rifle variant n side by side."""
    ims = []
    for view in ("front", "rear"):
        p = os.path.join(raw, "var_trooper_rifle_%d_%s.png" % (n, view))
        im = Image.open(p).convert("RGB")
        w, hh = im.size
        cw = round(hh * 0.62)
        im = im.crop(((w - cw) // 2, 0, (w + cw) // 2, hh)).resize((round(h * 0.62), h), Image.LANCZOS)
        ims.append(im)
    c = Image.new("RGB", (ims[0].width * 2 + 4, h), BG)
    c.paste(ims[0], (0, 0))
    c.paste(ims[1], (ims[0].width + 4, 0))
    return c


def label(n):
    lk = look(n)
    s = "trooper_rifle_%d" % n
    sub = "%s, %s%s" % (GEAR[lk["gear"]], MARKS[lk["mark"]], ", LEADER" if lk["leader"] else "")
    return s, sub


def sheet(rows, row_names, col_names, path, title):
    pad, head, rowlab, lab = 14, 100, 150, 56
    c0 = cell(rows[0][0])
    cw, ch = c0.size
    cols = len(rows[0])
    g = Image.new("RGB", (rowlab + cols * (cw + pad) + pad, head + len(rows) * (ch + lab + pad) + pad), BG)
    d = ImageDraw.Draw(g)
    d.text((pad, 14), title, fill=(240, 240, 240), font=font(30, True))
    for c, name in enumerate(col_names):
        d.text((rowlab + pad + c * (cw + pad), 62), name, fill=(235, 210, 160), font=font(24, True))
    for r, row in enumerate(rows):
        y = head + pad + r * (ch + lab + pad)
        d.text((pad, y + ch // 2 - 14), row_names[r], fill=(235, 210, 160), font=font(26, True))
        for c, n in enumerate(row):
            x = rowlab + pad + c * (cw + pad)
            g.paste(cell(n), (x, y))
            s, sub = label(n)
            d.text((x + 4, y + ch + 4), s, fill=(240, 240, 240), font=font(22, True))
            d.text((x + 4, y + ch + 30), sub, fill=(200, 200, 200), font=font(19))
    g.save(path)
    print(path)


# 3x3: rows = build, columns = helmet (variants 0..8 are a Latin square: each row and column also has every gear).
grid = [[next(n for n in range(9) if look(n)["build"] == b and look(n)["helmet"] == h) for h in range(3)] for b in range(3)]
sheet(grid, BUILDS, HELMETS, os.path.join(out, "trooper_variants_grid.png"),
      "Trooper look variants (rifle kit), L1 livery, day city: rows build, columns helmet (front | rear 3/4)")
# All 12 (9..11 repeat the dome with a new gear per build).
sheet([[0, 1, 2, 3], [4, 5, 6, 7], [8, 9, 10, 11]], ["0-3", "4-7", "8-11"], ["", "", "", ""],
      os.path.join(out, "trooper_variants_all.png"), "All 12 trooper look variants (rifle kit; the AT kit shares bodies)")

# Squads: 20 m and 40 m chase-cam frames, each with a 2x crop around the squads.
s20 = os.path.join(raw, "squads_20.png")
s40 = os.path.join(raw, "squads_40.png")
if os.path.exists(s20) and os.path.exists(s40):
    pad, lab, head = 14, 40, 64
    shots = []
    for path, t in ((s20, "~20 m"), (s40, "~40 m")):
        im = Image.open(path).convert("RGB")
        w, h = im.size
        cy = round(h * 0.6)
        crop = im.crop((w // 4, cy - h // 4, w // 4 + w // 2, cy + h // 4)).resize((w, h), Image.LANCZOS)
        shots.append((im, t + ", full chase-cam frame"))
        shots.append((crop, t + ", centre 2x crop"))
    w, h = shots[0][0].size
    g = Image.new("RGB", (2 * w + 3 * pad, head + 2 * (h + lab + pad) + pad), BG)
    d = ImageDraw.Draw(g)
    d.text((pad, 16), "Two mixed squads of 5 (rifle + AT, slot 0 = leader, one crouched each), day city, chase cam (fov 70, eye 9.5 m up)",
           fill=(240, 240, 240), font=font(28, True))
    for i, (im, t) in enumerate(shots):
        r, c = divmod(i, 2)
        x, y = pad + c * (w + pad), head + r * (h + lab + pad)
        g.paste(im, (x, y))
        d.text((x + 4, y + h + 6), t, fill=(220, 220, 220), font=font(24))
    p = os.path.join(out, "trooper_squads.png")
    g.save(p)
    print(p)
