"""Bake open-sea swell: 128 looping frames of 128x128 level bytes, crests travelling west (-x).

    python swell.py out.bin [spacing_cycles=2] [coverage=0.45] [preview.png]

Crest lines sit on the peaks of one travelling wave (spacing_cycles per 128 px, 1 px per frame), bent by
two slow sways so they arc, and cut into short strokes by a drifting envelope (coverage = share of crest
length drawn). Every term uses whole cycles over the 128 px tile and the 128-frame loop, so the result
tiles and loops. Levels: 4 very faint, 1 faint, 2 bright (same meaning as in caustics_still.bin)."""
import sys
import numpy as np

N = STEPS = 128
out = sys.argv[1]
M = int(sys.argv[2]) if len(sys.argv) > 2 else 2
COVER = float(sys.argv[3]) if len(sys.argv) > 3 else 0.45
preview = sys.argv[4] if len(sys.argv) > 4 else None
W = 2 * np.pi / N
y, x = np.mgrid[0:N, 0:N].astype(float)
L = N / M   # crest spacing in px


def env(t):
    # which stretches of crest show: moves along with the waves (west) and slides slowly along them
    return (np.sin(W * (x + y + t) + 0.3) + np.sin(W * (x - 2 * y + t) + 2.0)
            + 0.7 * np.sin(W * (2 * x + 3 * y + 2 * t) + 4.0) + 0.5 * np.sin(W * (3 * x - y + 3 * t) + 1.0))


thr = np.quantile(np.stack([env(t) for t in range(0, STEPS, 8)]), 1 - COVER)
frames = np.zeros((STEPS, N, N), np.uint8)
for t in range(STEPS):
    sway = 4 * np.sin(W * (y + t) + 1.0) + 2.5 * np.sin(W * (2 * y - t) + 2.5) + 1.5 * np.sin(W * (3 * y + x + 2 * t))
    # d = px east of the nearest crest (negative = ahead of it, to the west)
    d = (x + t + sway + L / 2) % L - L / 2
    e = env(t) - thr
    f = frames[t]
    core = np.abs(d) < 0.75
    f[(e > 0) & (d >= 0.75) & (d < 2.5)] = 4            # thin wake behind the crest
    f[(e > 0) & core] = 1
    f[(e > 0.5) & (d >= 0.75) & (d < 1.75)] = 1         # stronger strokes are 2 px thick
    f[(e > 0.5) & (d >= 1.75) & (d < 3.5)] = 4
    f[(e > 1.1) & core] = 2
frames.tofile(out)
print('coverage of pixels by level', {int(k): round(float((frames == k).mean()), 4) for k in np.unique(frames)})
if preview:
    from PIL import Image
    col = {0: (1, 78, 90), 4: (20, 108, 118), 1: (42, 130, 138), 2: (150, 215, 220)}
    rgb = np.zeros((N * 2, N * 2 * 3, 3), np.uint8)
    for i, t in enumerate((0, 8, 16)):
        tile = np.tile(frames[t], (2, 2))
        for k, c in col.items():
            rgb[:, i * 2 * N:(i + 1) * 2 * N][tile == k] = c
    Image.fromarray(rgb).resize((N * 6 * 2, N * 2 * 2), Image.NEAREST).save(preview)
