# usage: rings2.py <still.bin> <out rings.bin> [slots per tile position] [seed] [life frames] [core half-width px] [fringe half-width px] [gentle start 0/1] [white core 0/1]
# Ring events for the overlay to play at random map tiles. Each event belongs to one of the 16
# tile positions of the 4x4-tile pattern and starts at a fixed loop frame; its LIFE frames are
# that tile's still-water pixels with a widening, fading ring drawn on top (ring stays inside the tile).
# File: byte EV, byte LIFE, EV x (position 0-15, start frame), then EV x LIFE x 32x32 level bytes.
import sys, numpy as np
T, N, TP, LIFE = 128, 128, 32, 22
lv = np.frombuffer(open(sys.argv[1], 'rb').read(), np.uint8).reshape(T, N, N)
slots = int(sys.argv[3]) if len(sys.argv) > 3 else 2
rng = np.random.default_rng(int(sys.argv[4]) if len(sys.argv) > 4 else 7)
if len(sys.argv) > 5: LIFE = int(sys.argv[5])        # frames a ring takes to widen and fade (default 22)
CORE = float(sys.argv[6]) if len(sys.argv) > 6 else 0.62    # ring line half-width (0.62 = the thin 1 px ring)
FRINGE = float(sys.argv[7]) if len(sys.argv) > 7 else 0.0   # soft edge: one step fainter out to this half-width (0 = none)
GENTLE = len(sys.argv) > 8 and sys.argv[8] == '1'            # 1 = fade in faint and grow at a steady pace (no white flash at birth)
WHITE = len(sys.argv) > 9 and sys.argv[9] == '1'             # 1 = the middle of the line goes white (3 then 5) with the tinted levels as its soft edge
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
            u = a / (LIFE - 1); EXP = 1.0 if GENTLE else 0.7; r = 2.0 + (rmax - 2.0) * u ** EXP
            f = lv[(start + a) % T, ty:ty + TP, tx:tx + TP].copy()
            if FRINGE: r = 2.0 + (min(rmax, cx - FRINGE, cy - FRINGE, 31 - cx - FRINGE, 31 - cy - FRINGE) - 2.0) * u ** EXP   # keep the soft edge inside the tile
            dist = np.abs(np.hypot(X - cx, Y - cy) - r); ring = dist < CORE
            level = 3 if a < 2 else 2 if u < 0.5 else 1
            if GENTLE: level = 1 if u < 0.1 else 2 if u < 0.55 else 1
            if WHITE: level = 1 if u < 0.08 else 3 if u < 0.4 else 5 if u < 0.72 else 1
            if u > 0.8: ring &= ((X + Y + a) % 2 == 0)
            if FRINGE:
                soft = (dist < FRINGE) & ~ring; lo = {3: 2, 5: 1, 2: 1, 1: 4}[level]
                if u > 0.8: soft &= ((X + Y + a) % 2 == 1)
                if lo == 4: f[soft & ((f == 0) | (f == 6))] = 4      # very faint edge only on empty water
                else: f[soft] = np.maximum(np.where((f[soft] == 4) | (f[soft] == 6), 0, f[soft]), lo)
            f[ring] = np.maximum(np.where((f[ring] == 4) | (f[ring] == 6), 0, f[ring]), level)   # 4 very faint and 6 shadow sit below a ring
            body.append(f)
ev = slots * 16
open(sys.argv[2], 'wb').write(bytes([ev, LIFE] + head) + np.stack(body).tobytes())
print('ring events', ev, 'life', LIFE, 'bytes', 2 + 2 * ev + ev * LIFE * TP * TP)
