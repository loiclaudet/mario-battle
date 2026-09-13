#!/usr/bin/env python3
"""cuts the battle theme into an intro and a gapless loop.
input: tools/sheets/battle_theme.mp3 (the 30 s wiki transcode of the all-stars smb3 enemy battle theme).
method: the repeat period is found by correlating the rms envelope with itself; the loop start is the onset,
between 2.4 s and 3.2 s, whose following period best matches the period after it; the length is refined to
the sample on the raw waveform. writes assets/music/battle_intro.flac, battle_loop.flac and tools/music_cuts.json.
run from the project root: python3 tools/cut_music.py"""
import json, os, subprocess, wave
import numpy as np

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = os.path.join(root, 'tools/sheets/battle_theme.mp3')
mono = os.path.join(root, 'build/battle_theme_mono.wav')
os.makedirs(os.path.join(root, 'build'), exist_ok=True)
subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', src, '-ac', '1', '-ar', '44100', mono], check=True)
w = wave.open(mono)
sr, n = w.getframerate(), w.getnframes()
x = np.frombuffer(w.readframes(n), dtype=np.int16).astype(np.float64) / 32768.0

def env(a, b, hop):
    return np.array([np.sqrt(np.mean(x[i:i + hop] ** 2)) for i in range(a, b - hop, hop)])

# 1. period: best envelope self-similarity for a loop between 8 and 20 s
e10 = env(0, len(x), 441)
best = (0, 0)
for L in np.arange(8.0, 20.0, 0.01):
    ia, iL, W = int(8.0 / 0.01), int(L / 0.01), int(8.0 / 0.01)
    if ia + iL + W > len(e10):
        continue
    c = np.corrcoef(e10[ia:ia + W], e10[ia + iL:ia + iL + W])[0, 1]
    if c > best[0]:
        best = (c, L)
L = int(round(best[1] * sr))

# 2. refine the period on the raw waveform
a0, W = int(8.0 * sr), int(6.0 * sr)
seg = x[a0:a0 + W]
bc, bL = -1, L
for Ls in range(L - 2000, L + 2000, 10):
    seg2 = x[a0 + Ls:a0 + Ls + W]
    c = np.dot(seg, seg2) / (np.linalg.norm(seg) * np.linalg.norm(seg2))
    if c > bc:
        bc, bL = c, Ls
for Ls in range(bL - 12, bL + 12):
    seg2 = x[a0 + Ls:a0 + Ls + W]
    c = np.dot(seg, seg2) / (np.linalg.norm(seg) * np.linalg.norm(seg2))
    if c > bc:
        bc, bL = c, Ls
L = bL

# 3. loop start: the onset whose period repeats best
e1 = env(0, len(x), 44)
onset = np.maximum(np.diff(e1), 0)
cands = [i for i in range(int(2.4 / 0.001), int(3.2 / 0.001)) if onset[i] == onset[i - 8:i + 8].max() and onset[i] > 0.02]
scored = []
for i in cands:
    S = i * 44
    if S + 2 * L > len(x):
        continue
    c = np.corrcoef(env(S, S + L, 441), env(S + L, S + 2 * L, 441))[0, 1]
    scored.append((c, S))
scored.sort(reverse=True)
S = scored[0][1]
print(f'period {L} samples ({L / sr:.5f} s), loop start {S} samples ({S / sr:.4f} s), repeat corr {scored[0][0]:.3f}')

out = os.path.join(root, 'assets/music')
os.makedirs(out, exist_ok=True)
subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', mono, '-af', f'atrim=start_sample=0:end_sample={S}', '-c:a', 'flac', f'{out}/battle_intro.flac'], check=True)
subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', mono, '-af', f'atrim=start_sample={S}:end_sample={S + L}', '-c:a', 'flac', f'{out}/battle_loop.flac'], check=True)
json.dump({'sampleRate': sr, 'introSamples': S, 'loopSamples': L, 'introSeconds': S / sr, 'loopSeconds': L / sr}, open(os.path.join(root, 'tools/music_cuts.json'), 'w'), indent=1)
print('wrote assets/music/battle_intro.flac and battle_loop.flac')
