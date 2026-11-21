"""Cut the foam crescent out of a looping wave animation as one-tile foam frames.

    python -I wavetile.py <crescent.gif> caustics_wavetile.bin [crop width px 336] [crop depth px 240] [margin px 36] [preview.png]

128 frames of 32x32 level bytes: 0 nothing, 9 faint, 10 half, 11 solid foam. Frame k is the crescent of
source frame k, placed k/127 of the way from the back of the tile to the front (its middle runs from
`margin` source px inside the back edge to `margin` inside the front edge), travelling west (bulge
toward -x). The script picks the frame by how far the game's wave is through its move.
The crop is squeezed to a square tile, so depth is stretched by width/depth."""
import sys
import numpy as np
from PIL import Image

TP = 32
src, out = sys.argv[1], sys.argv[2]
cw = int(sys.argv[3]) if len(sys.argv) > 3 else 336
cd = int(sys.argv[4]) if len(sys.argv) > 4 else 240
margin = int(sys.argv[5]) if len(sys.argv) > 5 else 36
preview = sys.argv[6] if len(sys.argv) > 6 else None
im = Image.open(src)
T, S = im.n_frames, im.size[0]
assert T == 128, T
ws = []
for t in range(T):
    im.seek(t)
    ws.append(np.asarray(im.convert('RGB'), float).min(axis=2))   # foam is bright in every channel
ws = np.array(ws)
base, top = np.median(ws), np.quantile(ws, 0.999)
rel = np.clip((ws - base) / (top - base), 0, None)
ang = np.arange(S) * 2 * np.pi / S
lev = np.zeros((T, TP, TP), np.uint8)
for t in range(T):
    m = rel[t] * (rel[t] > 0.3)
    def centre(p):   # circular mean, the picture wraps
        return int(round(np.angle((p * np.exp(1j * ang)).sum()) % (2 * np.pi) / (2 * np.pi) * S))
    cy, cx = centre(m.sum(axis=1)), centre(m.sum(axis=0))
    pos = margin + (cd - 2 * margin) * t / (T - 1)          # crescent's row inside the crop
    r = np.roll(np.roll(rel[t], S // 2 - cy + int(round(pos - cd / 2)), axis=0), S // 2 - cx, axis=1)
    crop = r[S // 2 - cd // 2:S // 2 + cd // 2, S // 2 - cw // 2:S // 2 + cw // 2]
    small = np.asarray(Image.fromarray(crop.astype(np.float32)).resize((TP, TP), Image.BOX))
    lev[t][small > 0.30] = 9
    lev[t][small > 0.50] = 10
    lev[t][small > 0.72] = 11
print('share per level', {int(k): round(float((lev == k).mean()), 4) for k in np.unique(lev)})
print('foam touching the tile edge (share of frames): along %.2f, across %.2f' % (
    np.mean([(f[0] > 0).any() or (f[-1] > 0).any() for f in lev]), np.mean([(f[:, 0] > 0).any() or (f[:, -1] > 0).any() for f in lev])))
print('changed per frame %.3f, loop seam %.3f' % (np.mean(lev[1:] != lev[:-1]), np.mean(lev[0] != lev[-1])))
if preview:
    col = {0: (1, 78, 90), 9: (90, 150, 158), 10: (160, 200, 204), 11: (232, 240, 240)}
    rgb = np.zeros((TP, TP * 8, 3), np.uint8)
    for i in range(8):
        for k, c in col.items():
            rgb[:, i * TP:(i + 1) * TP][lev[i * 16] == k] = c
    Image.fromarray(rgb).resize((TP * 8 * 6, TP * 6), Image.NEAREST).save(preview)
# travels +y in the source -> -x in the file: new[y][x] = old[TP-1-x][y]
np.ascontiguousarray(np.transpose(lev[:, ::-1, :], (0, 2, 1))).tofile(out)
