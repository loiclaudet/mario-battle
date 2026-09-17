#!/usr/bin/env python3
"""writes assets/sprites/wario_*.png and waluigi_*.png as palette swaps of the mario and luigi frames:
wario keeps mario's shapes in yellow and purple, waluigi keeps luigi's in purple and near black (nes colours).
the skin tone is shared. run: python3 tools/recolor_sprites.py"""
import os, glob
from PIL import Image
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sprites = os.path.join(root, 'assets/sprites')
SWAPS = {
    ('mario', 'wario'): { (181, 49, 32, 255): (248, 184, 0, 255), (66, 64, 255, 255): (136, 20, 176, 255) },
    ('luigi', 'waluigi'): { (13, 147, 0, 255): (136, 20, 176, 255), (0, 64, 77, 255): (28, 16, 48, 255) },
}
for (src, dst), table in SWAPS.items():
    for path in sorted(glob.glob(os.path.join(sprites, f'{src}_*.png'))):
        im = Image.open(path).convert('RGBA')
        px = im.load()
        for y in range(im.size[1]):
            for x in range(im.size[0]):
                px[x, y] = table.get(px[x, y], px[x, y])
        out = os.path.join(sprites, os.path.basename(path).replace(src + '_', dst + '_', 1))
        im.save(out)
        print('wrote', os.path.basename(out))
