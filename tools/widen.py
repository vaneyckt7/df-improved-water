# usage: widen.py <in.bin> <out.bin>  - make the faint lines one pixel wider; bright levels untouched
import sys, numpy as np
lv = np.frombuffer(open(sys.argv[1],'rb').read(), np.uint8).reshape(128,128,128).copy()
b = lv > 0
grow = b | np.roll(b, 1, 2) | np.roll(b, 1, 1) | np.roll(np.roll(b, 1, 1), 1, 2)
lv[grow & ~b] = 1
open(sys.argv[2],'wb').write(lv.tobytes())
