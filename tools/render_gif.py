#!/usr/bin/env python3
"""renders docs/gameplay.gif headlessly: mario walks under the pow, hits it, every spiny flips, he kicks one.
each frame is a full `rive --screenshot` run driven by the synthetic gamepad, so it takes about a minute.
run from the project root: python3 tools/render_gif.py"""
import os, subprocess
from PIL import Image

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(root)
frames = []
START = 1230
END = 1560
STEP = 4
for f in range(START, END, STEP):
    args = ['rive', '.', f'--screenshot=build/gif_frame.png', '--gamepad=button@east:down', '--gamepad=button@east:up',
            '--advance=1250', '--gamepad=button@dpadRight:down', '--advance=70', '--gamepad=button@dpadRight:up',
            '--gamepad=button@east:down', '--gamepad=button@east:up', '--advance=75', '--gamepad=button@dpadRight:down',
            '--advance=95', '--gamepad=button@dpadRight:up']
    # rebuild the timeline so the capture lands at frame f: the scenario above spans 1250+70+75+95 = 1490 frames,
    # so trim or extend the last advance
    total = 1250 + 70 + 75 + 95
    if f <= 1250:
        args = args[:5] + [f'--advance={f}']
    elif f <= 1320:
        args = args[:8] + [f'--advance={f - 1250}']
    elif f <= 1395:
        args = args[:12] + [f'--advance={f - 1320}']
    else:
        args = args[:14] + [f'--advance={f - 1395}']
    subprocess.run(args, check=True, capture_output=True)
    im = Image.open('build/gif_frame.png').convert('RGB').resize((512, 480), Image.NEAREST)
    frames.append(im)
os.makedirs('docs', exist_ok=True)
frames[0].save('docs/gameplay.gif', save_all=True, append_images=frames[1:], duration=int(1000 * STEP / 60), loop=0, optimize=False)
print(f'wrote docs/gameplay.gif with {len(frames)} frames')
