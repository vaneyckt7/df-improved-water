# usage: straight.py <bin>...  how straight the pieces are: sideways spread / length (0 = ruler straight)
import sys, numpy as np
from scipy import ndimage as nd
for f in sys.argv[1:]:
    lv = np.frombuffer(open(f,'rb').read(), np.uint8).reshape(128,128,128); r = []
    for t in range(0, 128, 4):
        m = (lv[t] > 0) & (lv[t] < 4); big, n = nd.label(m, np.ones((3,3)))
        for i in range(1, n + 1):
            ys, xs = np.nonzero(big == i)
            if len(ys) < 15 or ys.min() == 0 or xs.min() == 0 or ys.max() == 127 or xs.max() == 127: continue
            ev = np.sqrt(np.maximum(np.linalg.eigvalsh(np.cov(np.stack([xs, ys]))), 1e-9))
            if ev[1] * 3.46 >= 14: r.append(ev[0] / ev[1])
    print(f, 'pieces %d | sideways spread / length: median %.2f, 75th pct %.2f' % (len(r), np.median(r), np.percentile(r, 75)))
