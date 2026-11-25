import sys, numpy as np
from PIL import Image
def strip(path, ev=5):
    b=np.frombuffer(open(path,'rb').read(),np.uint8); n,life=b[0],b[1]
    body=b[2+2*n:].reshape(n,life,32,32)
    cols={1:(0x64,(0x40,255,255)),2:(0x84,(0x50,255,255)),3:(0xB0,(0xE0,255,255)),4:(0x57,(0x40,255,255)),5:(0x84,(255,255,255)),6:(0x33,(0,0,0))}
    bg=np.array([40,80,150],float); fr=[int(round(x)) for x in np.linspace(0,life-1,10)]
    out=np.zeros((32,32*len(fr),3))
    for i,a in enumerate(fr):
        t=np.tile(bg,(32,32,1))
        for l,v in cols.items():
            al=v[0]/255; m=body[ev,a]==l; t[m]=np.array(v[1])*al*al+bg*(1-al)
        out[:,i*32:(i+1)*32]=t
    return Image.fromarray(out.astype(np.uint8)).resize((out.shape[1]*6,192),Image.NEAREST)
ims=[strip(p) for p in sys.argv[2:]]
im=Image.new('RGB',(ims[0].width,200*len(ims)-8))
for i,x in enumerate(ims): im.paste(x,(0,200*i))
im.save(sys.argv[1])
