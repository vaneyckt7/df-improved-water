"""compose.py <seq> <out.gif> mode ox oy [w h] : mode = wipe | after | split
ox,oy = crop origin in native pixels (window points) inside the map; output w x h native px."""
import sys, glob, math, os
from PIL import Image, ImageDraw, ImageFont
SP=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONT='/System/Library/Fonts/Supplemental/Arial Bold.ttf'
def load(p, ox, oy, w, h):
    im=Image.open(p).convert('RGB')
    # window capture is 2x; title bar 56 px
    z=float(os.environ.get('ZOOM','1')); cw,ch=int(w/z),int(h/z)
    return im.crop((2*ox, 56+2*oy, 2*(ox+cw), 56+2*(oy+ch))).resize((w,h), Image.BOX if z<2 else Image.NEAREST)
def pill(d, text, x, y, anchor, size=18):
    f=ImageFont.truetype(FONT,size)
    l,t,r,b=d.textbbox((0,0),text,font=f); tw,th=r-l,b-t
    px,py=10,7
    x0 = x if anchor=='l' else x-tw-2*px
    d.rounded_rectangle((x0,y-th-2*py,x0+tw+2*px,y),radius=7,fill=(18,22,28),outline=(235,235,235),width=1)
    d.text((x0+px-l,y-th-py-t),text,font=f,fill=(245,245,245))
def frame(a,b,pos,labels=('Before','After'),label_size=18):
    w,h=a.size
    out=a.copy()
    if b is not None:
        x=int(round(pos*w))
        out.paste(b.crop((0,0,x,h)),(0,0))
        d=ImageDraw.Draw(out)
        d.rectangle((x-1,0,x+1,h),fill=(245,245,245))
        d.rectangle((x-2,0,x-2,h),fill=(20,20,20)); d.rectangle((x+2,0,x+2,h),fill=(20,20,20))
        pill(d,labels[0],12,h-12,'l',label_size); pill(d,labels[1],w-12,h-12,'r',label_size)
        title=os.environ.get('TITLE')
        if title: pill(d,title,12,12+int(label_size*1.25)+22,'l',int(label_size*1.25))
    return out
def main():
    seq,outp,mode,ox,oy=sys.argv[1],sys.argv[2],sys.argv[3],int(sys.argv[4]),int(sys.argv[5])
    w=int(sys.argv[6]) if len(sys.argv)>6 else 640; h=int(sys.argv[7]) if len(sys.argv)>7 else 360
    A=sorted(glob.glob(f'{SP}/shots/{seq}/a*.png')); B=sorted(glob.glob(f'{SP}/shots/{seq}/b*.png'))
    st=int(os.environ.get('START','0')); step=int(os.environ.get('STEP','1'))
    A=A[st::step]; B=B[st::step]
    n=min(len(A),len(B),int(os.environ.get('FRAMES','9999'))); frames=[]
    for i in range(n):
        a=load(A[i],ox,oy,w,h)
        if mode=='after': frames.append(a); continue
        b=load(B[i],ox,oy,w,h)
        pos=0.5 if mode=='split' else 0.5-0.36*math.cos(2*math.pi*i/n)
        frames.append(frame(a,b,pos))
    if outp.endswith('.png'): frames[n//2].save(outp); return
    thr=int(os.environ.get('THR','0'))
    if thr:  # keep a pixel unchanged when it differs from the shown one by less than thr (summed RGB): smaller file
        import numpy as np
        prev=np.asarray(frames[0]).astype(np.int16)
        for i in range(1,n):
            cur=np.asarray(frames[i]).astype(np.int16)
            prev=np.where((np.abs(cur-prev).sum(2)<thr)[...,None],prev,cur)
            frames[i]=Image.fromarray(prev.astype(np.uint8))
    # one shared palette from a mosaic of sampled frames
    sample=Image.new('RGB',(w*4,h*2))
    for k in range(8): sample.paste(frames[(k*n)//8],((k%4)*w,(k//4)*h))
    pal=sample.quantize(255,method=Image.MEDIANCUT,dither=Image.NONE)
    q=[f.quantize(palette=pal,dither=Image.NONE) for f in frames]
    q[0].save(outp,save_all=True,append_images=q[1:],duration=int(os.environ.get('MS','80')),loop=0,optimize=True)
    print(outp, n, 'frames', os.path.getsize(outp)//1024, 'KB')
main()
