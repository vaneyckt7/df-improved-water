# usage: compose.py <streaks.bin> <long_lines.bin> <out.bin>
# Put the long-line layer under the streaks as level 4 (very faint), only on pixels the streaks leave empty.
import sys, numpy as np
v = np.frombuffer(open(sys.argv[1], 'rb').read(), np.uint8).copy()
l = np.frombuffer(open(sys.argv[2], 'rb').read(), np.uint8)
v[(l > 0) & (v == 0)] = 4
open(sys.argv[3], 'wb').write(v.tobytes())
