"""Bake a looping, tileable animation of a foam wave passing over water caustics into sea frames.

    python -I seagif.py <sea.gif> caustics_sea.bin [caustic percentiles 72,82,96.5] [preview.png]

128 frames, each shrunk to 128x128 and turned so the wave travels west (as in caustics_swell.bin).
Levels: caustics 4 very faint halo, 1 line, 5 white knot (as in caustics_still.bin);
foam 9 faint, 10 half, 11 solid white (by how white the picture is). Foam covers caustics."""
import sys
import numpy as np
from PIL import Image
from scipy import ndimage as nd

N = 128
src, out = sys.argv[1], sys.argv[2]
pc = [float(v) for v in (sys.argv[3] if len(sys.argv) > 3 else '72,82,96.5').split(',')]
preview = sys.argv[4] if len(sys.argv) > 4 else None
im = Image.open(src)
T = im.n_frames
assert T == 128, T
S = im.size[0]
lines = np.zeros((T, N, N))
white = np.zeros((T, N, N))
for t in range(T):
    im.seek(t)
    a = np.asarray(im.convert('RGB'), float)
    w = a.min(axis=2)                       # white foam is bright in every channel, the water is not in red
    g = a.mean(axis=2)
    g = np.minimum(g, np.percentile(g, 97))  # foam must not swamp the caustic lines around it
    g = g - nd.gaussian_filter(g, S / 40, mode='wrap')
    g = g / (np.sqrt(nd.gaussian_filter(g * g, S / 12, mode='wrap')) + 1e-6)
    lines[t] = np.asarray(Image.fromarray(g.astype(np.float32)).resize((N, N), Image.BOX))
    white[t] = np.asarray(Image.fromarray(w.astype(np.float32)).resize((N, N), Image.BOX))
th = np.percentile(lines, pc)
lev = np.zeros(lines.shape, np.uint8)
lev[lines > th[0]] = 4
lev[lines > th[1]] = 1
lev[lines > th[2]] = 5
base = np.median(white)
top = np.quantile(white, 0.999)
rel = (white - base) / (top - base)
lev[rel > 0.30] = 9
lev[rel > 0.50] = 10
lev[rel > 0.72] = 11
seam_y = np.mean((lev[:, 0, :] > 0) != (lev[:, -1, :] > 0)); in_y = np.mean((lev[:, 1:, :] > 0) != (lev[:, :-1, :] > 0))
seam_x = np.mean((lev[:, :, 0] > 0) != (lev[:, :, -1] > 0)); in_x = np.mean((lev[:, :, 1:] > 0) != (lev[:, :, :-1] > 0))
print('share per level', {int(k): round(float((lev == k).mean()), 4) for k in np.unique(lev)})
print('mismatch across wrap vs ordinary neighbours: top/bottom %.3f vs %.3f, left/right %.3f vs %.3f' % (seam_y, in_y, seam_x, in_x))
print('changed per frame %.3f, loop seam %.3f' % (np.mean(lev[1:] != lev[:-1]), np.mean(lev[0] != lev[-1])))
if preview:
    col = {0: (1, 78, 90), 4: (20, 96, 106), 1: (40, 118, 126), 5: (120, 180, 186),
           9: (90, 150, 158), 10: (160, 200, 204), 11: (232, 240, 240)}
    rgb = np.zeros((N * 2, N * 2 * 3, 3), np.uint8)
    for i, t in enumerate((0, 16, 32)):
        tile = np.tile(lev[t], (2, 2))
        for k, c in col.items():
            rgb[:, i * 2 * N:(i + 1) * 2 * N][tile == k] = c
    Image.fromarray(rgb).resize((N * 12, N * 4), Image.NEAREST).save(preview)
# travels +y in the source -> -x in the file: new[y][x] = old[N-1-x][y]
lev = np.ascontiguousarray(np.transpose(lev[:, ::-1, :], (0, 2, 1)))
lev.tofile(out)
