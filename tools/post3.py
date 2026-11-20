# usage: post3.py <in.bin> <out.bin> <cut kmin> <cut kmax> <min piece px> [seed]
# For the sliding-web pattern: cut faint lines along a patchwork that slides with web A (so the
# gaps travel with the lines), remove 1-px spikes and tiny leftover pieces. Bright pixels stay.
import sys, numpy as np
from scipy import ndimage as nd
T = N = 128
lv = np.frombuffer(open(sys.argv[1],'rb').read(), np.uint8).reshape(T,N,N).copy()
k0, k1, minpx = float(sys.argv[3]), float(sys.argv[4]), int(sys.argv[5])
rng = np.random.default_rng(int(sys.argv[6]) if len(sys.argv) > 6 else 3)
g = np.arange(N); X, Y = np.meshgrid(g, g); q = 2*np.pi/N
f = 0
n = 0
while n < 10:
    kx, ky = rng.integers(-9, 10, 2)
    if k0 <= np.hypot(kx, ky) <= k1: f = f + np.cos(q*(kx*X + ky*Y) + rng.uniform(0, 6.28)); n += 1
f = f > 0
edge = (f != np.roll(f, 1, 0)) | (f != np.roll(f, 1, 1))
edge = nd.binary_dilation(np.tile(edge, (3, 3)), iterations=1)[N:2*N, N:2*N]
for t in range(T):
    a = lv[t]
    a[np.roll(edge, t, 1) & (a == 1)] = 0
    for _ in range(2):                                   # despike
        cnt = nd.convolve((a > 0).astype(int), np.ones((3, 3), int), mode='wrap') - 1
        a[(a == 1) & (cnt < 3)] = 0
    big, n = nd.label(np.tile(a > 0, (2, 2)), np.ones((3, 3)))
    if n:
        size = nd.sum(np.ones_like(big), big, np.arange(n + 1))
        hasb = nd.maximum(np.tile(a, (2, 2)), big, np.arange(n + 1))
        kill = (size < minpx) & (hasb < 2); kill[0] = False
        a[kill[big][:N, :N] & kill[big][N:, N:]] = 0
open(sys.argv[2],'wb').write(lv.tobytes())
