# Standing waves (morph in place, no travel), broad-to-medium sizes, weak focus. Levels set by percentile.
import numpy as np, sys
from PIL import Image, ImageDraw
N, T, SS = 128, 128, 6
g = (np.arange(N*SS) + 0.5) / SS
X, Y = np.meshgrid(g, g)
fk = np.fft.fftfreq(N); KX, KY = np.meshgrid(fk, fk)
def blur(img, s): return np.fft.ifft2(np.fft.fft2(img) * np.exp(-2*np.pi**2*s*s*(KX**2 + KY**2))).real
def waves(seed, kmin, kmax, n, slope):
    rng = np.random.default_rng(seed); out = []
    while len(out) < n:
        kx, ky = rng.integers(-kmax, kmax + 1, 2); k = np.hypot(kx, ky)
        if k < kmin or k > kmax: continue
        # (kx, ky, amp, spatial phase, cycles per loop, time phase, steady share)
        out.append((kx, ky, rng.uniform(0.6, 1.0) / k**slope, rng.uniform(0, 2*np.pi), int(rng.choice([1, 1, 2])), rng.uniform(0, 2*np.pi), rng.uniform(0.3, 0.6)))
    return out
def surf(W, t):
    gx = np.zeros_like(X); gy = np.zeros_like(X); lap = np.zeros_like(X); q = 2*np.pi/N
    for kx, ky, a, ph, m, tp, st in W:
        a = a * (st + (1 - st) * np.cos(2*np.pi*m*t/T + tp))      # each wave swells and relaxes in place
        arg = q*(kx*X + ky*Y) + ph
        s = -a*np.sin(arg)*q; gx += s*kx; gy += s*ky; lap += -a*np.cos(arg)*q*q*(kx*kx + ky*ky)
    return gx, gy, lap
def frames(W, focus, ts, sun=0.7):
    rms = np.sqrt(np.mean([(surf(W, t)[2]**2).mean() for t in range(0, T, 16)]))
    depth = focus / rms; out = []
    for t in ts:
        gx, gy, _ = surf(W, t)
        h, _, _ = np.histogram2d(((Y - depth*gy) % N).ravel(), ((X - depth*gx) % N).ravel(), bins=N, range=[[0, N], [0, N]])
        out.append(blur(h / SS**2, sun))
    return out
bgc = np.array([14, 78, 104.])
def paint(lv, scale=2, tile=2):
    add = np.array([0, 13, 23, 50])[lv]
    rgb = np.clip(bgc + add[..., None] * np.array([0.6, 1, 1]), 0, 255).astype(np.uint8)
    return Image.fromarray(np.tile(rgb, (tile, tile, 1))).resize((N*tile*scale,)*2, Image.NEAREST)
CANDS = {'E': ('broad+medium', waves(11, 1, 4, 22, 1.5), 0.75), 'F': ('medium', waves(12, 2, 5, 26, 1.5), 0.7),
         'G': ('broad, soft', waves(13, 1, 3.5, 18, 1.3), 0.7), 'H': ('broad+medium, weaker', waves(11, 1, 4, 22, 1.5), 0.55)}
PCT = (86, 93.5, 99.0)       # lit 14%, bright 6.5%, glint 1%
def levels(fr, th): return sum((fr > v).astype(np.uint8) for v in th)
if __name__ == '__main__':
    cell = 512; ts = (0, 16, 32, 48); sheet = Image.new('RGB', (cell*4, cell*4)); d = ImageDraw.Draw(sheet)
    for r, (key, (name, W, f)) in enumerate(CANDS.items()):
        fr = frames(W, f, ts); th = np.percentile(np.stack(fr), PCT)
        print(key, name, 'focus', f, 'thresholds %.2f %.2f %.2f' % tuple(th), 'frame-to-frame change over 16 steps: %.1f%% of pixels' % (100*(levels(fr[0], th) != levels(fr[1], th)).mean()))
        for c in range(4):
            sheet.paste(paint(levels(fr[c], th)), (c*cell, r*cell))
            d.rectangle((c*cell, r*cell, c*cell + 54, r*cell + 30), fill=(0, 0, 0)); d.text((c*cell + 8, r*cell + 8), '%s t%d' % (key, ts[c]), fill=(255, 255, 255))
    sheet.resize((1600, 1600), Image.LANCZOS).save('watersim3_sheet.png')
