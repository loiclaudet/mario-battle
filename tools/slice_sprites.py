#!/usr/bin/env python3
"""slice sprite sheets into one png per frame, driven by tools/frames.json.

sheet: { file, transparent: [r,g,b] | null, originX, originY }
frame: { name, out, sheet, x, y, w, h,
         gifFrame?: n,            -- pick a frame of an animated gif
         pad?: [w, h],            -- centre (or anchor) the crop in a transparent canvas
         anchor?: "center"|"bottom",
         flipX?, flipY?,
         palette?: { from, to }   -- recolour with the map learned from two same-shaped images }
run from the project root: python3 tools/slice_sprites.py
"""
import json, os
from PIL import Image

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = json.load(open(os.path.join(root, "tools", "frames.json")))


def load(path, gif_frame=0):
    im = Image.open(os.path.join(root, path))
    if getattr(im, "n_frames", 1) > 1:
        im.seek(gif_frame)
    return im.convert("RGBA")


def key_out(im, rgb):
    px = im.load()
    for j in range(im.size[1]):
        for i in range(im.size[0]):
            r, g, b, a = px[i, j]
            if (r, g, b) == tuple(rgb):
                px[i, j] = (0, 0, 0, 0)
    return im


palette_cache = {}


def palette_map(src, dst):
    key = (src, dst)
    if key in palette_cache:
        return palette_cache[key]
    a = load(src)
    b = load(dst)
    assert a.size == b.size, f"palette pair sizes differ: {src} {dst}"
    pa, pb = a.load(), b.load()
    m = {}
    for j in range(a.size[1]):
        for i in range(a.size[0]):
            ca, cb = pa[i, j], pb[i, j]
            if ca[3] == 0 and cb[3] == 0:
                continue
            if ca[:3] != (0, 0, 0) or ca[3] != 0:
                m.setdefault(ca[:3], cb[:3])
    palette_cache[key] = m
    return m


count = 0
for f in spec["frames"]:
    s = spec["sheets"][f["sheet"]]
    im = load(s["file"], f.get("gifFrame", 0))
    x = s["originX"] + f["x"]
    y = s["originY"] + f["y"]
    crop = im.crop((x, y, x + f["w"], y + f["h"]))
    if s.get("transparent"):
        crop = key_out(crop, s["transparent"])
    if "palette" in f:
        m = palette_map(f["palette"]["from"], f["palette"]["to"])
        px = crop.load()
        for j in range(crop.size[1]):
            for i in range(crop.size[0]):
                r, g, b, a = px[i, j]
                if a and (r, g, b) in m:
                    px[i, j] = m[(r, g, b)] + (a,)
    if f.get("flipX"):
        crop = crop.transpose(Image.FLIP_LEFT_RIGHT)
    if f.get("flipY"):
        crop = crop.transpose(Image.FLIP_TOP_BOTTOM)
    if "pad" in f:
        pw, ph = f["pad"]
        canvas = Image.new("RGBA", (pw, ph), (0, 0, 0, 0))
        ox = (pw - crop.size[0]) // 2
        oy = ph - crop.size[1] if f.get("anchor") == "bottom" else (ph - crop.size[1]) // 2
        canvas.paste(crop, (ox, oy), crop)
        crop = canvas
    out_dir = os.path.join(root, f["out"])
    os.makedirs(out_dir, exist_ok=True)
    crop.save(os.path.join(out_dir, f["name"] + ".png"))
    count += 1
print(f"sliced {count} frames")
