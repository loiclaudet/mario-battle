#!/usr/bin/env python3
"""writes assets/music/battle_intro_fast.flac and battle_loop_fast.flac: the cut theme at 1.2x tempo (same
pitch), played when a player turns blue. the runtime has no playback speed, so the faster take is a file.
run after tools/cut_music.py: python3 tools/fast_music.py"""
import os, subprocess
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
music = os.path.join(root, 'assets/music')
for name in ('battle_intro', 'battle_loop'):
    src = os.path.join(music, name + '.flac')
    dst = os.path.join(music, name + '_fast.flac')
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', src, '-filter:a', 'atempo=1.2', dst], check=True)
    print('wrote', dst)
