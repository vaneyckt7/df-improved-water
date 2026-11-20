"""Bake a looping, tileable wave animation (one foam crest travelling down the picture) into swell frames.

    python -I wavegif.py <wave.gif> out.bin [preview.png]

Each frame is shrunk to 128x128 and turned so the crest travels west (the convention of caustics_swell.bin).
Levels: 5/6/7 = foam, faint to solid white (by how much brighter than the water the picture is),
8 = trough (darker than the water)."""
import sys
import numpy as np
from PIL import Image, ImageSequence

N = 128
src, out = sys.argv[1], sys.argv[2]
preview = sys.argv[3] if len(sys.argv) > 3 else None
im = Image.open(src)
frames = [np.asarray(f.convert('L').resize((N, N), Image.BOX), float) for f in ImageSequence.Iterator(im)]
assert len(frames) == 128, len(frames)
F = np.stack(frames)
water = np.median(F)
top = np.quantile(F, 0.999)
rel = (F - water) / (top - water)          # 0 = water, 1 = brightest foam
lev = np.zeros(F.shape, np.uint8)
lev[rel > 0.22] = 5
lev[rel > 0.45] = 6
lev[rel > 0.70] = 7
lev[rel < -0.10] = 8
# travels +y in the source -> -x in the file: new[y][x] = old[N-1-x][y]
lev = np.ascontiguousarray(np.transpose(lev[:, ::-1, :], (0, 2, 1)))
lev.tofile(out)
print('water', water, 'top', top, {int(k): round(float((lev == k).mean()), 4) for k in np.unique(lev)})
if preview:
    col = {0: (1, 78, 90), 5: (70, 130, 140), 6: (140, 180, 186), 7: (225, 235, 236), 8: (2, 70, 82)}
    rgb = np.zeros((N * 2, N * 2 * 3, 3), np.uint8)
    for i, t in enumerate((0, 8, 16)):
        tile = np.tile(lev[t], (2, 2))
        for k, c in col.items():
            rgb[:, i * 2 * N:(i + 1) * 2 * N][tile == k] = c
    Image.fromarray(rgb).resize((N * 12, N * 4), Image.NEAREST).save(preview)
