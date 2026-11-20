# usage: net.py <out.bin> <seed> <cells> <band px> <round sigma> <core cut> <wander px>
# Painted-ripple method: the light is the net left between rounded holes ("pebbles").
# Levels: 1 net, 5 white core in the thick parts/joins, 6 shadow (net copy shifted down, drawn dark),
# 4 a second, very faint, larger net underneath. 128 frames 128x128; cells wander on small loops.
import sys, numpy as np
from scipy import ndimage as nd
T = N = 128
out, seed, nc, band, sig, core, wan = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), *[float(v) for v in sys.argv[4:8]]
rng = np.random.default_rng(seed)
g = np.arange(N) + 0.5; X, Y = np.meshgrid(g, g); q = 2 * np.pi / N
def noise(k):
    f = 0
    for _ in range(6):
        kx, ky = rng.integers(-k, k + 1, 2); f = f + np.cos(q * (kx * X + ky * Y) + rng.uniform(0, 6.28))
    return f / 3.5
def layer(n, band, sig, wan):
    P = rng.uniform(0, N, (n, 2)); R = rng.uniform(0.5, 1, n) * wan; PH = rng.uniform(0, 6.28, n); S = rng.choice([-1, 1], n)
    w = band * (1 + 0.45 * noise(3)); wx, wy = 2.5 * noise(4), 2.5 * noise(4)      # uneven band width, bent edges
    res = []
    for t in range(T):
        a = 2 * np.pi * t / T * S + PH; px = P[:, 0] + R * np.cos(a); py = P[:, 1] + R * np.sin(a)
        dx = (X + wx)[None] - px[:, None, None]; dx = (dx + N / 2) % N - N / 2      # wrapped offsets to every cell centre
        dy = (Y + wy)[None] - py[:, None, None]; dy = (dy + N / 2) % N - N / 2
        d2 = dx * dx + dy * dy; o = np.argsort(d2, 0)[:2]
        t1 = lambda v, k: np.take_along_axis(v, o[k][None], 0)[0]
        sep = np.hypot(t1(dx, 0) - t1(dx, 1), t1(dy, 0) - t1(dy, 1)) + 1e-6
        e = (t1(d2, 1) - t1(d2, 0)) / (2 * sep)                                   # true distance to the cell border
        hole = nd.gaussian_filter((e > w / 2).astype(float), sig, mode='wrap')   # blur + cut = rounded pebbles
        res.append(1 - hole)
    return np.stack(res)
a = layer(nc, band, sig, wan); b = layer(max(8, nc // 2), band * 0.6, sig, wan)
net = a > 0.5
corev = np.stack([nd.gaussian_filter(f.astype(float), 1.3, mode='wrap') for f in net]); cores = net & (corev > core)
shadow = np.roll(net, 2, 1) & ~net
lv = np.zeros((T, N, N), np.uint8)
lv[b > 0.5] = 4; lv[shadow] = 6; lv[net] = 1; lv[cores] = 5
open(out, 'wb').write(lv.tobytes())
print('net %.1f%%  white cores %.1f%%  shadow %.1f%%  faint second net %.1f%%' % tuple(100 * (lv == k).mean() for k in (1, 5, 6, 4)))
