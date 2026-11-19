import sys, numpy as np
for f in sys.argv[1:]:
    lv = np.frombuffer(open(f,'rb').read(), np.uint8).reshape(128,128,128) > 0
    far = np.mean([(lv[i] ^ lv[(i+64) % 128]).mean() for i in range(0,128,8)])
    lit = lv.mean()
    print(f, 'lit %.1f%% | pixels differing between opposite halves of the loop %.1f%% (%.0f%% of the lit pattern replaced)' % (lit*100, far*100, far/(2*lit)*100))
