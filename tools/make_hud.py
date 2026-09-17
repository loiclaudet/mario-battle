#!/usr/bin/env python3
"""writes assets/stage/hud_{m,l,w,wl}.png, the 60x17 hud boxes for four players: the 65 px ripped box with
the five empty columns between the letter and the coin slots removed, and W / an upside down L (waluigi)
pixelled in the same style as the ripped M and L (light strokes, orange shadow right and below).
run: python3 tools/make_hud.py"""
import os
from PIL import Image
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
stage = os.path.join(root, 'assets/stage')
LIGHT = (255, 204, 197, 255)
SHADOW = (234, 158, 34, 255)
CLEAR = (0, 0, 0, 0)
CELL = (4, 4)  # the letter cell's top left in the box, 7 x 8
LETTERS = {
    'w': ['b.....b', 'b.....b', 'b..b..b', 'b..b..b', 'b.b.b.b', 'b.b.b.b', 'bb...bb', '.......'],
    'wl': ['bbbbbbb', 'b......', 'b......', 'b......', 'b......', 'b......', 'b......', '.......'],
}

def narrow(src):
    """drop columns 11..15 (empty) so the box is 60 wide; a box already 60 wide is left as it is"""
    im = Image.open(src).convert('RGBA')
    if im.size[0] == 60:
        return im
    out = Image.new('RGBA', (60, 17), CLEAR)
    out.paste(im.crop((0, 0, 11, 17)), (0, 0))
    out.paste(im.crop((16, 0, 65, 17)), (11, 0))
    return out

def clear_cell(im):
    for y in range(8):
        for x in range(7):
            im.putpixel((CELL[0] + x, CELL[1] + y), CLEAR)

def draw_letter(im, rows):
    clear_cell(im)
    for y, row in enumerate(rows):
        for x, c in enumerate(row):
            if c == 'b':
                im.putpixel((CELL[0] + x, CELL[1] + y), LIGHT)
    for y, row in enumerate(rows):
        for x, c in enumerate(row):
            if c != 'b':
                continue
            for dx, dy in ((1, 0), (0, 1)):
                nx, ny = x + dx, y + dy
                if nx < 7 and ny < 8 and rows[ny][nx] != 'b':
                    im.putpixel((CELL[0] + nx, CELL[1] + ny), SHADOW)

m = narrow(os.path.join(stage, 'hud_m.png'))
l = narrow(os.path.join(stage, 'hud_l.png'))
m.save(os.path.join(stage, 'hud_m.png'))
l.save(os.path.join(stage, 'hud_l.png'))
for name, rows in LETTERS.items():
    im = l.copy()
    draw_letter(im, rows)
    im.save(os.path.join(stage, f'hud_{name}.png'))
print('hud boxes written: m l w wl (60x17)')

# the coin fill in the target's blue, for a blue player's hud
coin = Image.open(os.path.join(stage, 'hud_coin.png')).convert('RGBA')
BLUES = { (234, 158, 34, 255): (66, 64, 255, 255), (255, 204, 197, 255): (192, 223, 255, 255), (255, 255, 255, 255): (192, 223, 255, 255) }
px = coin.load()
for y in range(coin.size[1]):
    for x in range(coin.size[0]):
        c = px[x, y]
        if c[3] > 0:
            px[x, y] = BLUES.get(c, (100, 176, 255, 255))
coin.save(os.path.join(stage, 'hud_coin_blue.png'))
print('hud_coin_blue written')

# each character's letter alone (the 7x8 cell of its box) for the initial drawn over a target's head
for name in ('m', 'l', 'w', 'wl'):
    box = Image.open(os.path.join(stage, f'hud_{name}.png')).convert('RGBA')
    letter = box.crop((CELL[0], CELL[1], CELL[0] + 7, CELL[1] + 8))
    letter.save(os.path.join(stage, f'letter_{name}.png'))
print('letters written: m l w wl (7x8)')
