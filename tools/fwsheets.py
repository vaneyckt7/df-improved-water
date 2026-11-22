"""Foam and crest sheets for the Flowing Waves mod (art/seafoam.png, art/swell.png), in its layout.

    python fwsheets.py <out dir> [preview.png]

seafoam.png: 16 frames across; row = (stage * 16 + joined_sides) * 4 + variant, stage 0 (nearly gone) .. 7
(fresh), joined_sides bits N=1 E=2 S=4 W=8 (that neighbour has foam or a wave too), variant by tile position.
swell.png: 16 frames across; row = heading * 4 + whiteness, heading north, south, east, west (the way the
crest travels), whiteness 0 (far out) .. 3 (about to break). A tile shows frame (step + shift) % 16 and
neighbouring tiles are a frame or more apart, so nothing here relies on neighbours sharing a frame.

Foam: what lies between round bubbles of mixed sizes, enough when fresh
to leave only small round holes, the holes growing until a net is left, then crumbs. The points near the tile border are the
same for every variant and the pattern repeats every 32 px, so foam carries on across a joined side; toward
a side with no foam the patch ends in a wobbly rounded outline.
"""
import sys, os
import numpy as np
from PIL import Image

T, FR = 32, 16
WHITE, LIGHT, HALO = (238, 249, 247, 236), (188, 226, 226, 196), (112, 182, 188, 112)
yy, xx = np.mgrid[0:T, 0:T].astype(float)


def points(variant):
    r = np.random.RandomState(7)
    common = r.rand(80, 2) * T
    edge = np.minimum(np.minimum(common[:, 0], T - common[:, 0]), np.minimum(common[:, 1], T - common[:, 1]))
    keep = common[edge < 9][:20]
    rv = np.random.RandomState(100 + variant)
    inner = 9 + rv.rand(5, 2) * (T - 18)
    pts = np.vstack([keep, inner])
    rad = 2.2 + 2.6 * np.random.RandomState(8).rand(len(pts)) ** 1.5
    phase = np.random.RandomState(55).rand(len(pts)) * 2 * np.pi
    return pts, rad, phase


def lace(variant, frame):
    """how far outside the nearest bubble, in bubble radii: bubbles are the holes, foam lies between them"""
    pts, rad, phase = points(variant)
    a = 2 * np.pi * frame / FR + phase
    p = pts + 0.5 * np.stack([np.cos(a), np.sin(a)], 1)
    dx = np.abs(xx[..., None] + 0.5 - p[:, 0]); dx = np.minimum(dx, T - dx)
    dy = np.abs(yy[..., None] + 0.5 - p[:, 1]); dy = np.minimum(dy, T - dy)
    return (np.hypot(dx, dy) / rad).min(axis=2)


def breakup():
    r = np.random.RandomState(3)
    f = np.zeros((T, T))
    for _ in range(6):
        kx, ky = r.randint(-2, 3, 2)
        f += np.cos(2 * np.pi * (kx * xx + ky * yy) / T + r.rand() * 6.3)
    f += 1.5 * (np.random.RandomState(4).rand(T, T) - 0.5)
    return (f - f.min()) / (f.max() - f.min())


def outline(joined, variant):
    """px inside the patch outline (<= 0 outside); large where every side is joined"""
    r = np.random.RandomState(900 + variant * 16 + joined)
    R = 9.0
    arms = []
    for bit, d, t in ((1, yy + 0.5, xx), (4, T - yy - 0.5, xx), (8, xx + 0.5, yy), (2, T - xx - 0.5, yy)):
        if joined & bit:
            continue
        ph = r.rand(3) * 6.3
        wob = sum(np.sin((k + 1) * np.pi * t / T + ph[k]) * a for k, a in enumerate((3.0, 1.8, 0.9)))
        arms.append(d - 4.5 - (2.5 + wob) * np.sin(np.pi * (t + 0.5) / T))   # same inset where a side ends
    if not arms:
        return np.full((T, T), 99.0)
    q = sum(np.clip(R - a, 0, None) ** 2 for a in arms)
    return R - np.sqrt(q)


STAGE = [  # bubble size (share of full radius), share broken away
    (1.42, 0.84), (1.34, 0.62), (1.26, 0.36), (1.16, 0.12), (1.06, 0.0), (0.96, 0.0), (0.86, 0.0), (0.74, 0.0)]


def foam_tile(e, brk, m, stage, joined=0):
    size, gone = STAGE[stage]
    size = size + 0.5 * (1 - np.clip(m / 6.0, 0, 1))   # bubbles open up toward the patch's rim
    # toward a joined side the foam opens into lace too: the neighbour may be foam (the lace carries on) or
    # a wave's water (a solid edge there would show the tile's square)
    for bit, d in ((1, yy + 0.5), (4, T - yy - 0.5), (8, xx + 0.5), (2, T - xx - 0.5)):
        if joined & bit:
            size = size + 0.22 * (1 - np.clip(d / 8.0, 0, 1))
    alive = (m > 0) & (brk >= gone)
    out = np.zeros((T, T, 4), np.uint8)
    out[alive & (e > size)] = LIGHT
    out[alive & (e > size + 0.16)] = WHITE
    return out


def seafoam():
    sheet = np.zeros((8 * 16 * 4 * T, FR * T, 4), np.uint8)
    brk = breakup()
    laces = [[lace(v, f) for f in range(FR)] for v in range(4)]
    for stage in range(8):
        for joined in range(16):
            for v in range(4):
                m = outline(joined, v)
                row = (stage * 16 + joined) * 4 + v
                for f in range(FR):
                    sheet[row * T:(row + 1) * T, f * T:(f + 1) * T] = foam_tile(laces[v][f], brk, m, stage, joined)
    return sheet


CREST = [  # thickness px, colour of the line, trailing speckle depth px, share of the line drawn
    (1.3, (96, 176, 186, 150), 0, 0.72), (1.9, (150, 208, 212, 190), 0, 0.88),
    (2.7, LIGHT, 4, 1.0), (3.6, WHITE, 7, 1.0)]


def crest_tile(white, frame):
    """heading north: crisp leading edge on the north side, ragged trail to the south"""
    th, col, trail, share = CREST[white]
    r = np.random.RandomState(40 + white)
    x = np.arange(T) + 0.5
    a = 2 * np.pi * frame / FR
    # the line passes through the same height at both tile edges in every frame, and sways in between
    y0 = 15.5 + 2.6 * np.sin(a) * np.sin(np.pi * x / T) + 1.2 * np.sin(a + 1.9) * np.sin(2 * np.pi * x / T)
    grain = r.rand(T)
    thick = th * (0.62 + 0.38 * np.sin(np.pi * x / T)) * (0.8 + 0.4 * grain)
    drawn = np.cos(2 * np.pi * (x / T * 3 + r.rand()) + 0.6 * np.sin(a)) < 2 * share - 1 + 0.001
    out = np.zeros((T, T, 4), np.uint8)
    speck = np.random.RandomState(70 + white).rand(T, T)
    for xi in range(T):
        if not drawn[xi]:
            continue
        top = y0[xi] - thick[xi] / 2
        for yi in range(T):
            d = yi + 0.5 - top
            if 0 <= d < thick[xi]:
                out[yi, xi] = col if d < thick[xi] * 0.75 or white < 2 else LIGHT
            elif trail and thick[xi] <= d < thick[xi] + trail:
                fade = (d - thick[xi]) / trail
                if speck[(yi + frame // 4) % T, xi] > 0.45 + 0.5 * fade:
                    out[yi, xi] = LIGHT if fade < 0.4 else HALO
    return out


def swell():
    sheet = np.zeros((16 * T, FR * T, 4), np.uint8)
    for white in range(4):
        for f in range(FR):
            n = crest_tile(white, f)
            for h, t in enumerate((n, n[::-1], np.rot90(n, 3), np.rot90(n, 1))):   # north, south, east, west
                row = h * 4 + white
                sheet[row * T:(row + 1) * T, f * T:(f + 1) * T] = t
    return sheet


def preview(foam, crest, path):
    """a mock beach: foam patches with their real joined sides over sand and sea, and rows of crests"""
    W, H = 22, 14
    r = np.random.RandomState(5)
    img = Image.new('RGBA', (W * T, H * T), (176, 80, 60, 255))
    sea = Image.new('RGBA', (W * T, 5 * T), (1, 78, 90, 255))
    img.paste(sea, (0, 0))
    blob = np.zeros((H, W), bool)
    for _ in range(9):
        cx, cy, rad = r.randint(1, W - 1), r.randint(5, H - 1), r.rand() * 2.2 + 0.4
        for y in range(H):
            for x in range(W):
                if (x - cx) ** 2 + (y - cy) ** 2 <= rad * rad and y >= 4:
                    blob[y, x] = True
    step = 3
    for y in range(H):
        for x in range(W):
            if not blob[y, x]:
                continue
            j = 0
            for bit, dx, dy in ((1, 0, -1), (2, 1, 0), (4, 0, 1), (8, -1, 0)):
                if 0 <= x + dx < W and 0 <= y + dy < H and blob[y + dy, x + dx]:
                    j |= bit
            stage = int(np.clip(7 - (x // 3) % 8, 0, 7))
            row = (stage * 16 + j) * 4 + (x * 7 + y * 13) % 4
            f = (step + x * 3 + y * 5) % FR
            tile = Image.fromarray(foam[row * T:(row + 1) * T, f * T:(f + 1) * T])
            img.alpha_composite(tile, (x * T, y * T))
    for y, white, xs in ((0, 0, range(2, 9)), (1, 1, range(10, 20)), (2, 2, range(1, 12)), (3, 3, range(6, 21)), (1, 3, (3,)), (2, 1, (16, 17))):
        for x in xs:
            f = (step + x + y) % FR
            row = 0 * 4 + white
            img.alpha_composite(Image.fromarray(crest[row * T:(row + 1) * T, f * T:(f + 1) * T]), (x * T, y * T))
    img.resize((W * T * 2, H * T * 2), Image.NEAREST).save(path)


if __name__ == '__main__':
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    foam, crest = seafoam(), swell()
    Image.fromarray(foam).save(os.path.join(out, 'seafoam.png'))
    Image.fromarray(crest).save(os.path.join(out, 'swell.png'))
    if len(sys.argv) > 2:
        preview(foam, crest, sys.argv[2])
