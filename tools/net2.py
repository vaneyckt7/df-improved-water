# usage: net2.py <out.bin> <seed> <cells> <round sigma> <gap thr> <warp px> <wander px> <core cut>
# Curved net: the light is what is left between rounded pebbles. Each cell of a strongly bent cell map is
# blurred and cut on its own, so every corner is rounded and every border is a curve; joins come out thick.
# Levels: 1 net, 5 white core at thick parts, 6 shadow (net shifted 2 px down), 4 faint larger second net.
import sys, numpy as np
from scipy import ndimage as nd
T = N = 128
out, seed, nc = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
sig, thr, warp, wan, core = [float(v) for v in sys.argv[4:9]]
rng = np.random.default_rng(seed)
g = np.arange(N) + 0.5; X, Y = np.meshgrid(g, g); q = 2 * np.pi / N
def noise(k):
    f = 0
    for _ in range(8):
        kx, ky = rng.integers(-k, k + 1, 2); f = f + np.cos(q * (kx * X + ky * Y) + rng.uniform(0, 6.28))
    return f / 4
def layer(n, sig, thr):
    P = rng.uniform(0, N, (n, 2)); R = rng.uniform(0.5, 1, n) * wan; PH = rng.uniform(0, 6.28, n); S = rng.choice([-1, 1], n)
    W = rng.uniform(0, 5, n)                                  # unequal cells -> borders are arcs, not straight
    TH = thr + rng.uniform(-0.05, 0.07, n)                    # uneven gap around each pebble
    wx = warp * (noise(3) + 0.5 * noise(6)); wy = warp * (noise(3) + 0.5 * noise(6))
    res = np.zeros((T, N, N), bool)
    for t in range(T):
        a = 2 * np.pi * t / T * S + PH; px = P[:, 0] + R * np.cos(a); py = P[:, 1] + R * np.sin(a)
        dx = (X + wx)[None] - px[:, None, None]; dx = (dx + N / 2) % N - N / 2
        dy = (Y + wy)[None] - py[:, None, None]; dy = (dy + N / 2) % N - N / 2
        lab = np.argmin(np.hypot(dx, dy) - W[:, None, None], 0)
        hole = np.zeros((N, N), bool)
        for i in range(n):
            bl = nd.gaussian_filter((lab == i).astype(float), sig, mode='wrap')
            hole |= bl > TH[i] * min(1.0, bl.max() / 0.95)        # small cells shrink instead of vanishing
        res[t] = ~hole
    return res
net = layer(nc, sig, thr); b = layer(max(8, nc // 2), sig * 1.3, thr - 0.03)
corev = np.stack([nd.gaussian_filter(f.astype(float), 1.3, mode='wrap') for f in net]); cores = net & (corev > core)
lv = np.zeros((T, N, N), np.uint8)
lv[b] = 4; lv[np.roll(net, 2, 1) & ~net] = 6; lv[net] = 1; lv[cores] = 5
open(out, 'wb').write(lv.tobytes())
print('net %.1f%%  white cores %.1f%%  shadow %.1f%%  faint second net %.1f%%' % tuple(100 * (lv == k).mean() for k in (1, 5, 6, 4)))
