# usage: voro.py <out.bin> <seed> <dots> <glow px> <pct faint,pct bright>
# Two wrapping Voronoi edge webs sliding in different directions; light only where both webs
# have an edge (min of the two), snapped to two levels (1 faint, 2 bright). 128 frames, 128x128.
import sys, numpy as np
T = N = 128
out, seed, nd, glow = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])
p1, p2 = [float(v) for v in sys.argv[5].split(',')]
rng = np.random.default_rng(seed)
g = np.arange(N) + 0.5; X, Y = np.meshgrid(g, g)
def web(pts, ox, oy):
    d = []
    for px, py in pts:
        dx = np.abs(X - (px + ox) % N); dx = np.minimum(dx, N - dx)
        dy = np.abs(Y - (py + oy) % N); dy = np.minimum(dy, N - dy)
        d.append(np.hypot(dx, dy))
    d = np.sort(np.stack(d), 0)
    return np.clip(1 - (d[1] - d[0]) / glow, 0, 1)       # 1 on an edge, fading over `glow` px
A, B = rng.uniform(0, N, (nd, 2)), rng.uniform(0, N, (nd, 2))
c = np.stack([np.minimum(web(A, t, 0), web(B, 0, -t)) for t in range(T)])   # one full wrap each per loop
t1, t2 = np.percentile(c, [p1, p2])
lv = (c > t1).astype(np.uint8) + (c > t2)
open(out, 'wb').write(lv.tobytes())
