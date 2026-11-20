# usage: rings2.py <still.bin> <out rings.bin> [slots per tile position] [seed]
# Ring events for the overlay to play at random map tiles. Each event belongs to one of the 16
# tile positions of the 4x4-tile pattern and starts at a fixed loop frame; its LIFE frames are
# that tile's still-water pixels with a widening, fading ring drawn on top (ring stays inside the tile).
# File: byte EV, byte LIFE, EV x (position 0-15, start frame), then EV x LIFE x 32x32 level bytes.
import sys, numpy as np
T, N, TP, LIFE = 128, 128, 32, 22
lv = np.frombuffer(open(sys.argv[1], 'rb').read(), np.uint8).reshape(T, N, N)
slots = int(sys.argv[3]) if len(sys.argv) > 3 else 2
rng = np.random.default_rng(int(sys.argv[4]) if len(sys.argv) > 4 else 7)
g = np.arange(TP); X, Y = np.meshgrid(g, g)
head, body = [], []
# Start frames are spread evenly over the loop (every event its own moment), and the slots of one
# tile position are T/slots frames apart so two rings can never overlap on the same tile.
assert T // slots >= LIFE
offs = rng.permutation(16) * (T // slots) // 16
for s in range(slots):
    for p in range(16):
        start = int(s * (T // slots) + offs[p] + rng.integers(0, max(1, T // slots // 16))) % T; cx, cy = rng.uniform(13, 18, 2); rmax = rng.uniform(8, 12)
        ty, tx = (p // 4) * TP, (p % 4) * TP
        head += [p, start]
        for a in range(LIFE):
            u = a / (LIFE - 1); r = 2.0 + (rmax - 2.0) * u ** 0.7
            f = lv[(start + a) % T, ty:ty + TP, tx:tx + TP].copy()
            ring = np.abs(np.hypot(X - cx, Y - cy) - r) < 0.62
            level = 3 if a < 2 else 2 if u < 0.5 else 1
            if u > 0.8: ring &= ((X + Y + a) % 2 == 0)
            f[ring] = np.maximum(np.where((f[ring] == 4) | (f[ring] == 6), 0, f[ring]), level)   # 4 very faint and 6 shadow sit below a ring
            body.append(f)
ev = slots * 16
open(sys.argv[2], 'wb').write(bytes([ev, LIFE] + head) + np.stack(body).tobytes())
print('ring events', ev, 'life', LIFE, 'bytes', 2 + 2 * ev + ev * LIFE * TP * TP)
