# usage: make_caustics.py <animation.gif> <out.bin> <blend band px> <pct vfaint,faint,white>
# Still-water frames from a 128-frame looping grayscale caustics animation. The animation loops in time but
# does not tile in space, so a band along the right and bottom edges is cross-faded into the opposite edge
# (variance-preserving) before each frame is shrunk to 128x128. Levels: 4 very faint halo, 1 line, 5 white.
import sys, numpy as np
from PIL import Image
from scipy import ndimage as nd
N = 128
src, out, w = sys.argv[1], sys.argv[2], int(sys.argv[3]); pc = [float(v) for v in sys.argv[4].split(',')]
im = Image.open(src); T = im.n_frames; assert T == 128, T
S = im.size[0]; L = S - w
a = np.linspace(0, 1, w); nrm = np.sqrt(a * a + (1 - a) ** 2)
def tile(g):
    m = g.mean(); g = g - m
    g = np.concatenate([(a * g[:, :w] + (1 - a) * g[:, L:]) / nrm, g[:, w:L]], 1)
    g = np.concatenate([(a[:, None] * g[:w] + (1 - a)[:, None] * g[L:]) / nrm[:, None], g[w:L]], 0)
    return g
fr = np.zeros((T, N, N))
for t in range(T):
    im.seek(t); g = tile(np.asarray(im.convert('L'), float))
    g = g - nd.gaussian_filter(g, L / 40, mode='wrap')                          # keep lines, drop the soft glow
    g = g / (np.sqrt(nd.gaussian_filter(g * g, L / 12, mode='wrap')) + 1e-6)    # dim lines count like bright ones
    fr[t] = np.asarray(Image.fromarray(g.astype(np.float32)).resize((N, N), Image.BOX))
th = np.percentile(fr, pc)
lv = np.zeros(fr.shape, np.uint8); lv[fr > th[0]] = 4; lv[fr > th[1]] = 1; lv[fr > th[2]] = 5
open(out, 'wb').write(lv.tobytes())
lit = lv > 0
print('halo %.1f%% line %.1f%% white %.1f%%' % tuple(100 * (lv == k).mean() for k in (4, 1, 5)),
      '| changed per frame %.2f%% loop seam %.2f%%' % (100 * np.mean(lv[1:] != lv[:-1]), 100 * np.mean(lv[0] != lv[-1])))
print('lit share: blended band %.1f%%, rest %.1f%%' % (100 * lit[:, :, :N * w // L].mean(), 100 * lit[:, :, N * w // L:].mean()),
      '| mismatch across wrap: columns %.1f%% vs ordinary neighbours %.1f%%' % (100 * np.mean(lit[:, :, 0] != lit[:, :, -1]), 100 * np.mean(lit[:, :, 1:] != lit[:, :, :-1])))
