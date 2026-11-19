# usage: post.py <in.bin> <out.bin> <widen px> <cut kmin> <cut kmax> [seed]
# Widen the faint lines, then cut them along the boundaries of a slowly shifting patchwork so no
# line can run on: a faint line pixel on a patch boundary (2 px wide) is removed. Bright levels stay.
import sys, numpy as np
T = N = 128
lv = np.frombuffer(open(sys.argv[1],'rb').read(), np.uint8).reshape(T,N,N).copy()
wid, k0, k1 = int(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])
rng = np.random.default_rng(int(sys.argv[6]) if len(sys.argv) > 6 else 3)
b = lv > 0
for i in range(wid):
    s = 1 if i % 2 == 0 else -1          # alternate sides so the line stays centred
    b = b | np.roll(b, s, 2) | np.roll(b, s, 1) | np.roll(np.roll(b, s, 1), s, 2)
lv[b & (lv == 0)] = 1
if k1 > 0:
    g = np.arange(N); X, Y = np.meshgrid(g, g); q = 2*np.pi/N
    comps = []
    while len(comps) < 10:
        kx, ky = rng.integers(-9, 10, 2)
        if k0 <= np.hypot(kx, ky) <= k1: comps.append((kx, ky, rng.uniform(0, 6.28), rng.uniform(0, 6.28)))
    for t in range(T):
        f = sum(np.cos(q*(kx*X + ky*Y) + ph) * (0.75 + 0.25*np.cos(2*np.pi*t/T + tp)) for kx, ky, ph, tp in comps) > 0
        edge = (f != np.roll(f, 1, 0)) | (f != np.roll(f, 1, 1)) | (f != np.roll(f, -1, 0)) | (f != np.roll(f, -1, 1))
        lv[t][edge & (lv[t] == 1)] = 0
open(sys.argv[2],'wb').write(lv.tobytes())
