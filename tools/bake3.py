# Like bake2, plus an optional slow patchy mask that fades stretches of the strands so lines stay short.
import numpy as np, sys
import watersim3 as w
from scipy import ndimage
def junctions(lv):
    # junction = a lit pixel of the thinned line whose 5x5 ring is crossed by 3 or more separate lit runs
    tot = 0; area = 0
    ring = [(-2,-2),(-2,-1),(-2,0),(-2,1),(-2,2),(-1,2),(0,2),(1,2),(2,2),(2,1),(2,0),(2,-1),(2,-2),(1,-2),(0,-2),(-1,-2)]
    for i in range(0, w.T, 8):
        b = lv[i] > 0
        r = np.stack([np.roll(b, (-dy, -dx), (0, 1)) for dy, dx in ring]).astype(np.int8)
        runs = ((r - np.roll(r, 1, 0)) == 1).sum(0)
        j = b & (runs >= 3)
        tot += ndimage.label(j, structure=np.ones((3, 3)))[1]; area += 1
    return tot / area / 16.0       # per map tile (the pattern covers 16 tiles)
def extents(lv):
    out = []
    for i in range(0, w.T, 2):
        lab, n = ndimage.label(np.tile(lv[i] > 0, (2, 2)), structure=np.ones((3, 3)))
        for sl in ndimage.find_objects(lab):
            out.append(max(sl[0].stop - sl[0].start, sl[1].stop - sl[1].start))
    e = np.array(out)
    return 'line length px (32 = one tile): median %d, 90th pct %d, max %d, share of pieces over 48 px %.0f%%' % (np.median(e), np.percentile(e, 90), e.max(), 100*(e > 48).mean())
if sys.argv[1] == 'measure':
    lv = np.frombuffer(open(sys.argv[2], 'rb').read(), np.uint8).reshape(w.T, w.N, w.N); print(sys.argv[2], 'junctions per tile %.2f |' % junctions(lv), extents(lv)); sys.exit()
out, seed, kmin, kmax, n, slope, focus, sun = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]), int(sys.argv[5]), float(sys.argv[6]), float(sys.argv[7]), float(sys.argv[8])
pct = tuple(float(v) for v in sys.argv[9].split(',')); mask_amt = float(sys.argv[10])
calm = float(sys.argv[11]) if len(sys.argv) > 11 else None
W = w.waves(seed, kmin, kmax, n, slope)
if calm is not None:      # each wave keeps `calm` of its height and only the rest swells and relaxes, once per loop
    W = [(kx, ky, a, ph, 1, tp, calm) for kx, ky, a, ph, m, tp, st in W]
fr = np.stack(w.frames(W, focus, range(w.T), sun))
if mask_amt > 0:
    rng = np.random.default_rng(seed + 100); g = np.arange(w.N); X, Y = np.meshgrid(g, g); q = 2*np.pi/w.N
    comps = [(rng.integers(-5, 6), rng.integers(-5, 6), rng.uniform(0, 6.28), rng.uniform(0, 6.28)) for _ in range(14)]
    comps = [c for c in comps if 3 <= np.hypot(c[0], c[1]) <= 5.5]
    for t in range(w.T):
        m = sum(np.cos(q*(kx*X + ky*Y) + ph) * ((calm or 0) + (1 - (calm or 0)) * np.cos(2*np.pi*t/w.T + tp)) for kx, ky, ph, tp in comps)
        m = m / (np.sqrt(len(comps)) * 0.5)                    # roughly unit variance
        fr[t] = 1 + (fr[t] - 1) * np.clip(1 - mask_amt * (m + 0.3), 0.0, 1.0)
th = np.percentile(fr, pct)
lv = sum((fr > v).astype(np.uint8) for v in th)
lit = (lv > 0).mean((1, 2))*100
d = [(lv[i] != lv[(i + 1) % w.T]).mean()*100 for i in range(w.T)]
print('lit per frame %.1f-%.1f%% | change per step mean %.2f%% max %.2f%% |' % (lit.min(), lit.max(), np.mean(d), np.max(d)), 'junctions per tile %.2f |' % junctions(lv), extents(lv))
open(out, 'wb').write(lv.tobytes())
