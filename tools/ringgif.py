# usage: ringgif.py <ripple.gif> <still.bin> <out rings.bin> [slots] [seed] [life frames] [light thresholds a,b,c,d] [shadow threshold] [shadow ends at this fraction of the life] [levels for the 4 light bands, default 3,2,1,4]
# Ring clips taken from an animation of ONE ripple on a flat grey background (centred, radially symmetric).
# Each animation frame is reduced to a profile "lighter/darker than the background by distance from the
# centre"; a clip redraws that profile at a random centre and size inside a 32 px tile. Lighter parts become
# levels 3/2/1/4 (fractions of the brightest crest), darker parts the shadow level 6.
# Same file layout as rings2.py: byte EV, byte LIFE, EV x (position, start frame), EV x LIFE x 32x32 levels.
import sys, numpy as np
from PIL import Image
T, N, TP, SS = 128, 128, 32, 4
lv = np.frombuffer(open(sys.argv[2], 'rb').read(), np.uint8).reshape(T, N, N)
slots = int(sys.argv[4]) if len(sys.argv) > 4 else 4
rng = np.random.default_rng(int(sys.argv[5]) if len(sys.argv) > 5 else 7)
LIFE = int(sys.argv[6]) if len(sys.argv) > 6 else 26
TH = [float(v) for v in (sys.argv[7] if len(sys.argv) > 7 else '0.45,0.26,0.13,0.06').split(',')]   # one per light band, brightest first
SH = float(sys.argv[8]) if len(sys.argv) > 8 else 0.10
SHEND = float(sys.argv[9]) if len(sys.argv) > 9 else 1.0
LV = [int(v) for v in (sys.argv[10] if len(sys.argv) > 10 else '3,2,1,4').split(',')]
im = Image.open(sys.argv[1]); nf = im.n_frames; W = im.size[0]
fr = []
for i in range(nf): im.seek(i); fr.append(np.asarray(im.convert('L'), float))
fr = np.stack(fr); fr -= np.median(fr[0])
yy, xx = np.mgrid[:W, :W]; rad = np.hypot(xx - W / 2 + 0.5, yy - W / 2 + 0.5).astype(int).ravel()
cnt = np.maximum(np.bincount(rad), 1)
prof = np.stack([np.bincount(rad, f.ravel()) / cnt for f in fr])[:, :W // 2]       # frame x radius (source px)
live = np.where(np.abs(prof).max(1) > 1.5)[0]; f0, f1 = live[0], live[-1]
rsrc = max(np.where(np.abs(prof[f]) > 1.5)[0].max() for f in live)                  # largest radius reached
print('ripple frames %d..%d of %d, largest radius %d px of %d' % (f0, f1, nf, rsrc, W // 2))
g = (np.arange(TP * SS) + 0.5) / SS - 0.5; X, Y = np.meshgrid(g, g)
assert T // slots >= LIFE
offs = rng.permutation(16) * (T // slots) // 16
head, body = [], []
for s in range(slots):
    for p in range(16):
        start = int(s * (T // slots) + offs[p] + rng.integers(0, max(1, T // slots // 16))) % T
        cx, cy = rng.uniform(13, 18, 2); rmax = min(rng.uniform(9, 12.5), cx, cy, 31 - cx, 31 - cy)
        k = rsrc / rmax                                                              # source px per tile px
        d = np.hypot(X - cx, Y - cy) * k
        ty, tx = (p // 4) * TP, (p % 4) * TP
        head += [p, start]
        for a in range(LIFE):
            src = f0 + (f1 - f0) * a / (LIFE - 1); i0 = int(src); w = src - i0; i1 = min(i0 + 1, nf - 1)
            pr = prof[i0] * (1 - w) + prof[i1] * w
            v = np.interp(d, np.arange(len(pr)), pr, right=0).reshape(TP, SS, TP, SS)
            hi = np.maximum(v, 0).mean((1, 3)); lo = np.maximum(-v, 0).mean((1, 3))
            f = lv[(start + a) % T, ty:ty + TP, tx:tx + TP].copy()
            body.append((f, hi, lo))
pk = max(h.max() for _, h, _ in body); pl = max(l.max() for _, _, l in body)
out = []
for j, (f, hi, lo) in enumerate(body):
    a = j % LIFE; h = hi / pk
    nb = len(TH); K = np.select([h >= t for t in TH], list(range(nb)), nb)      # band index, nb = none
    if a == 0: K = np.where(K < nb, nb - 1, nb)          # fade in: no bright flash at birth
    elif a == 1: K = np.where(K < nb, np.maximum(K, nb // 2), nb)
    L = np.array(LV + [0])[K]
    sh = (lo / pl >= SH) & (L == 0); u = a / (LIFE - 1)
    if u >= SHEND: sh[:] = False
    elif u >= SHEND - 0.15: sh &= (np.add.outer(np.arange(TP), np.arange(TP)) + a) % 2 == 0   # break up before it ends
    f[sh & ((f == 0) | (f == 4))] = 6                    # trough darkens empty water only
    if max(LV) > 6:                                      # own ring colours: faint half only on empty water, bright half over everything
        m = (K >= nb // 2) & (K < nb) & ((f == 0) | (f == 4) | (f == 6)); f[m] = L[m]
        m = K < nb // 2
        if len(sys.argv) > 11 and sys.argv[11] == '1': m &= (f == 0) | (f == 4) | (f == 6)   # see-through: caustic lines stay on top of the ring
        f[m] = L[m]
    else:
        m = L == 4; f[m & ((f == 0) | (f == 6))] = 4
        m = (L > 0) & (L != 4); f[m] = np.maximum(np.where((f[m] == 4) | (f[m] == 6), 0, f[m]), L[m])
    out.append(f)
ev = slots * 16
open(sys.argv[3], 'wb').write(bytes([ev, LIFE] + head) + np.stack(out).tobytes())
print('ring events', ev, 'life', LIFE, 'bytes', 2 + 2 * ev + ev * LIFE * TP * TP)
