#!/usr/bin/env python3
"""writes assets/sprites/wario_*.png and waluigi_*.png as palette swaps of the mario and luigi frames:
wario keeps mario's shapes in yellow and purple, waluigi keeps luigi's in purple and near black (nes colours).
the skin tone is shared. then every character's blue take (<name>_blue_<pose>.png) in the last enemy's three
blues, worn by a player who became the target. run: python3 tools/recolor_sprites.py"""
import os, glob
from PIL import Image
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sprites = os.path.join(root, 'assets/sprites')
SWAPS = {
    ('mario', 'wario'): { (181, 49, 32, 255): (248, 184, 0, 255), (66, 64, 255, 255): (136, 20, 176, 255) },
    ('luigi', 'waluigi'): { (13, 147, 0, 255): (136, 20, 176, 255), (0, 64, 77, 255): (28, 16, 48, 255) },
}
BLUE = { 'main': (100, 176, 255, 255), 'dark': (66, 64, 255, 255), 'light': (192, 223, 255, 255) }
# each character's two cloth colours (cap and shirt, overalls) and the shared skin
CLOTHES = {
    'mario': ((181, 49, 32, 255), (66, 64, 255, 255)),
    'luigi': ((13, 147, 0, 255), (0, 64, 77, 255)),
    'wario': ((248, 184, 0, 255), (136, 20, 176, 255)),
    'waluigi': ((136, 20, 176, 255), (28, 16, 48, 255)),
}
SKIN = (255, 204, 197, 255)
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
for name, (top, bottom) in CLOTHES.items():
    table = { top: BLUE['main'], bottom: BLUE['dark'], SKIN: BLUE['light'] }
    for path in sorted(glob.glob(os.path.join(sprites, f'{name}_*.png'))):
        base = os.path.basename(path)
        if '_blue_' in base:
            continue
        im = Image.open(path).convert('RGBA')
        px = im.load()
        for y in range(im.size[1]):
            for x in range(im.size[0]):
                px[x, y] = table.get(px[x, y], px[x, y])
        out = os.path.join(sprites, base.replace(name + '_', name + '_blue_', 1))
        im.save(out)
        print('wrote', os.path.basename(out))
