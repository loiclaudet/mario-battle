#!/usr/bin/env python3
"""slice sprite sheets into one png per frame, driven by tools/frames.json.

frame coordinates are relative to the sheet's origin (originX/originY), so the
stage strips use nes framebuffer coordinates directly. the sheet's `transparent`
colour becomes alpha 0. run from the project root: python3 tools/slice_sprites.py
"""
import json, os, sys
from PIL import Image

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = json.load(open(os.path.join(root, "tools", "frames.json")))
sheets = {}
for key, s in spec["sheets"].items():
    im = Image.open(os.path.join(root, s["file"])).convert("RGBA")
    sheets[key] = (im, s)

count = 0
for f in spec["frames"]:
    im, s = sheets[f["sheet"]]
    x = s["originX"] + f["x"]
    y = s["originY"] + f["y"]
    box = (x, y, x + f["w"], y + f["h"])
    crop = im.crop(box)
    tr = tuple(s["transparent"])
    px = crop.load()
    for j in range(crop.size[1]):
        for i in range(crop.size[0]):
            r, g, b, a = px[i, j]
            if (r, g, b) == tr:
                px[i, j] = (0, 0, 0, 0)
    if f.get("flipX"):
        crop = crop.transpose(Image.FLIP_LEFT_RIGHT)
    if f.get("flipY"):
        crop = crop.transpose(Image.FLIP_TOP_BOTTOM)
    out_dir = os.path.join(root, f["out"])
    os.makedirs(out_dir, exist_ok=True)
    crop.save(os.path.join(out_dir, f["name"] + ".png"))
    count += 1
print(f"sliced {count} frames")
