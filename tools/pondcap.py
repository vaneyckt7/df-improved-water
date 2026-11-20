import bg,time,sys
from PIL import Image
tag=sys.argv[1]
r=bg.lua('''local c=reqscript("caustics") local vp=require("gui.dwarfmode").Viewport.get()
local x0,y0,x1,y1=1e9,1e9,-1,-1 local n=0
for _,p in ipairs(c.state.cache) do if (p[3]=="none" or p[3]=="shallow") and p[1]>=vp.x1 and p[1]<=vp.x2 and p[2]>=vp.y1 and p[2]<=vp.y2 then n=n+1 x0=math.min(x0,p[1]) x1=math.max(x1,p[1]) y0=math.min(y0,p[2]) y1=math.max(y1,p[2]) end end
print(vp.x1,vp.y1,vp.x2,vp.y2,df.global.gps.viewport_zoom_factor,n,x0,y0,x1,y1)''')
print(r)
vx1,vy1,vx2,vy2,zoom,n,x0,y0,x1,y1=[int(float(v)) for v in r.split()[:10]]
tp=109.0*zoom/224
box=(max(0,int((x0-vx1)*tp)-20),max(0,int(112+(y0-vy1)*tp)-20),min(2400,int((x1-vx1+1)*tp)+20),min(1656,int(112+(y1-vy1+1)*tp)+20))
print("box",box)
fr=[]
for i in range(8):
    bg.shot("%s%d.png"%(tag,i)); fr.append(Image.open("%s%d.png"%(tag,i)).convert("RGB").crop(box)); time.sleep(2.0)
fr[0].save(tag+".gif",save_all=True,append_images=fr[1:],duration=350,loop=0)
w,h=fr[0].size
sheet=Image.new("RGB",(w*2,h*2))
for i,f in enumerate(fr[:4]): sheet.paste(f,((i%2)*w,(i//2)*h))
sheet.save(tag+"_sheet.png"); print(sheet.size)
