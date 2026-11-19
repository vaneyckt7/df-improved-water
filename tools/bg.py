import subprocess, time
RUN="/Users/tomvaneyck/claude/tiling/out/dfrun.py"
def lua(code, timeout=60):
    o=subprocess.run(["python3",RUN,"lua",code],capture_output=True,text=True,timeout=timeout)
    return (o.stdout+o.stderr).strip()
VT='print(dfhack.gui.getCurViewscreen()._type)'
def click(wx,wy):
    """wx,wy: window points as used by the old cliclick scripts (1200x828 incl. 28pt title bar)."""
    return lua(f'''
local gps,en=df.global.gps,df.global.enabler
local fx,fy=({wx})/1200,({wy}-28)/800
local px,py=math.floor(fx*gps.screen_pixel_x),math.floor(fy*gps.screen_pixel_y)
gps.precise_mouse_x=px gps.precise_mouse_y=py
gps.mouse_x=math.floor(px/gps.tile_pixel_x) gps.mouse_y=math.floor(py/gps.tile_pixel_y)
en.tracking_on=1 en.mouse_lbut=1 en.mouse_lbut_down=1
require("gui").simulateInput(dfhack.gui.getCurViewscreen(true),"_MOUSE_L")
print(gps.mouse_x,gps.mouse_y,gps.screen_pixel_x,gps.screen_pixel_y,gps.tile_pixel_x,gps.tile_pixel_y)
''')
def hover(wx,wy):
    return lua(f'''
local gps,en=df.global.gps,df.global.enabler
local px,py=math.floor(({wx})/1200*gps.screen_pixel_x),math.floor(({wy}-28)/800*gps.screen_pixel_y)
gps.precise_mouse_x=px gps.precise_mouse_y=py
gps.mouse_x=math.floor(px/gps.tile_pixel_x) gps.mouse_y=math.floor(py/gps.tile_pixel_y)
en.tracking_on=1''')
def winid():
    return subprocess.run(["/private/tmp/claude-501/-Users-tomvaneyck-claude/88a8e59b-fdad-44d3-90db-5452c30fe43a/scratchpad/df/winid"],capture_output=True,text=True).stdout.strip()
def shot(path):
    subprocess.run(["screencapture","-x","-o","-l",winid(),path],check=True)
    subprocess.run(["sips","-z","828","1200",path,"--out",path.replace(".png","_small.png")],capture_output=True)
    return path.replace(".png","_small.png")
