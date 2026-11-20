# usage: fromimg.py <image> <out.bin> <wobble px> <pct vfaint,faint,white> [seed]
# Still-water frames from one seamless grayscale caustics picture. The picture is shrunk to 4x4 tiles and
# gently bent by a smooth displacement that loops over the 128 frames, so the net flexes in place.
# Levels by brightness: 4 very faint halo, 1 line, 5 white knots.
import sys, numpy as np
from PIL import Image
from scipy import ndimage as nd
T, N, S = 128, 128, 4
src, out, amp = sys.argv[1], sys.argv[2], float(sys.argv[3])
pc = [float(v) for v in sys.argv[4].split(',')]; rng = np.random.default_rng(int(sys.argv[5]) if len(sys.argv) > 5 else 1)
M = N * S
g = np.asarray(Image.open(src).convert('L').resize((M, M), Image.LANCZOS), float)
g = g - nd.gaussian_filter(g, M / 40, mode='wrap')                # keep the lines, drop the soft glow between them
g = g / (np.sqrt(nd.gaussian_filter(g * g, M / 12, mode='wrap')) + 1e-6)   # dim lines count as much as bright ones
y, x = np.mgrid[0:M, 0:M].astype(float); q = 2 * np.pi / M
waves = [(rng.integers(-3, 4, 2), rng.uniform(0, 6.28, 2), rng.choice([-1, 1])) for _ in range(6)]
fr = np.zeros((T, N, N))
for t in range(T):
    dx = dy = 0
    for (k, ph, s) in waves:
        a = q * (k[0] * x + k[1] * y) + s * 2 * np.pi * t / T
        dx = dx + np.cos(a + ph[0]); dy = dy + np.cos(a + ph[1])
    c = [(y + amp * S * dy / 3) % M, (x + amp * S * dx / 3) % M]
    w = nd.map_coordinates(g, c, order=1, mode='grid-wrap')
    fr[t] = w.reshape(N, S, N, S).mean((1, 3))
th = np.percentile(fr, pc)
lv = np.zeros(fr.shape, np.uint8); lv[fr > th[0]] = 4; lv[fr > th[1]] = 1; lv[fr > th[2]] = 5
open(out, 'wb').write(lv.tobytes())
print('halo %.1f%% line %.1f%% white %.1f%%' % tuple(100 * (lv == k).mean() for k in (4, 1, 5)),
      '| changed per frame %.2f%% loop seam %.2f%%' % (100 * np.mean(lv[1:] != lv[:-1]), 100 * np.mean(lv[0] != lv[-1])))
