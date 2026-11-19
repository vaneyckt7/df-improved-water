# usage: post2.py <in.bin> <out.bin> <cut kmin> <cut kmax> <min piece px> <extra widen 0/1> [seed]
# Cut the THIN lines along a shifting patchwork, drop tiny leftover pieces (they read as blobs),
# then widen so each piece is thickest mid-length and tapers to a thin point at its ends.
import sys, numpy as np
from scipy import ndimage as nd
T = N = 128
lv = np.frombuffer(open(sys.argv[1],'rb').read(), np.uint8).reshape(T,N,N).copy()
k0, k1, minpx, extra = float(sys.argv[3]), float(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
rng = np.random.default_rng(int(sys.argv[7]) if len(sys.argv) > 7 else 3)
g = np.arange(N); X, Y = np.meshgrid(g, g); q = 2*np.pi/N
comps = []
while len(comps) < 10:
    kx, ky = rng.integers(-9, 10, 2)
    if k0 <= np.hypot(kx, ky) <= k1: comps.append((kx, ky, rng.uniform(0, 6.28), rng.uniform(0, 6.28)))
def wlabel(m):                      # connected pieces with wrap-around
    big, n = nd.label(np.tile(m, (2, 2)), np.ones((3, 3)))
    return big, n
out = np.zeros_like(lv)
for t in range(T):
    a = lv[t].copy()
    f = sum(np.cos(q*(kx*X + ky*Y) + ph) * (0.75 + 0.25*np.cos(2*np.pi*t/T + tp)) for kx, ky, ph, tp in comps) > 0
    edge = (f != np.roll(f, 1, 0)) | (f != np.roll(f, 1, 1))
    edge = nd.binary_dilation(np.tile(edge, (3, 3)), iterations=2)[N:2*N, N:2*N]   # ~5 px gap
    a[edge & (a == 1)] = 0
    m = a > 0
    big, n = wlabel(m)
    if n:
        size = nd.sum(np.ones_like(big), big, np.arange(n + 1))
        hasb = nd.maximum(np.tile(a, (2, 2)), big, np.arange(n + 1))
        kill = (size < minpx) & (hasb < 2); kill[0] = False
        a[kill[big][:N, :N] & kill[big][N:, N:]] = 0
        m = a > 0
    # how much line is nearby: high mid-piece, low at the ends
    cnt = nd.uniform_filter(m.astype(float), 11, mode='wrap') * 121
    r1 = m & (cnt >= 12); r2 = m & (cnt >= 20)
    w = m.copy()
    w |= np.roll(r1, 1, 1) | np.roll(r1, 1, 0) | np.roll(np.roll(r1, 1, 0), 1, 1)
    if extra:
        w |= np.roll(r2, -1, 1) | np.roll(r2, -1, 0) | np.roll(np.roll(r2, -1, 0), -1, 1)
    a[w & (a == 0)] = 1
    out[t] = a
open(sys.argv[2],'wb').write(out.tobytes())
