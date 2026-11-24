# usage: ringcols.py <improved-water.lua> <strength 0-1>   - rewrite RING_COLS: the ripple animation's lightening times
# <strength>, brighter steps pulled up to 40% toward the water's teal hue, solved for out = c*a^2 + water*(1-a).
import sys, re, numpy as np
W=np.array([1,78,90.]); D=np.array([100,84,58.]); ts=[1.0,0.8,0.62,0.46,0.32,0.2]; S=float(sys.argv[2])
lum=np.array([.299,.587,.114]); DT=W/(W@lum)*(D@lum)
cols=[]
for t in ts:
    m=0.4*t; tgt=W+S*t*((1-m)*D+m*DT)
    for a in np.arange(0.20,1.0,0.01):
        c=(tgt-W*(1-a))/(a*a)
        if c.max()<=255: break
    A=int(round(a*255)); c=np.clip(np.round(c),0,255).astype(int)
    print('t %.2f alpha %.2f -> on water %s'%(t,a,(c*(A/255)**2+W*(1-A/255)).round()))
    cols.append('0x%02X%02X%02X%02X'%(A,c[2],c[1],c[0]))
p=sys.argv[1]; s=open(p).read()
s,n=re.subn(r"^RING_COLS = \{.*$","RING_COLS = {"+', '.join(cols)+"}   -- %d%% of the animation's lightening; brighter steps pulled up to 40%% toward the water's teal hue"%round(S*100),s,flags=re.M); assert n==1
open(p,'w').write(s)
