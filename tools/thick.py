import sys, numpy as np
from scipy import ndimage
for f in sys.argv[1:]:
    lv = np.frombuffer(open(f,'rb').read(), np.uint8).reshape(128,128,128)
    w = []; 
    for i in range(0,128,16):
        b = np.tile(lv[i] > 0, (2,2)); d = ndimage.distance_transform_edt(b)
        ridge = b & (d >= ndimage.maximum_filter(d, 3))
        w.append(2*d[ridge]-1)
    w = np.concatenate(w)
    print(f, 'line thickness px: median %.1f, mean %.1f | bright (levels 2-3) %.2f%% of pixels' % (np.median(w), w.mean(), (lv>=2).mean()*100))
