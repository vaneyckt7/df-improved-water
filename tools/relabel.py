# usage: relabel.py <in.bin> <out.bin>   - mark line overlaps (level 2) as level 5, which the
# overlay draws in its own colour (STILL_CROSS); ring clips keep levels 1-3.
import sys, numpy as np
a = np.frombuffer(open(sys.argv[1], 'rb').read(), np.uint8).copy(); a[a == 2] = 5
open(sys.argv[2], 'wb').write(a.tobytes())
