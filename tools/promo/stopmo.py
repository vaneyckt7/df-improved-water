"""stop-motion capture: python stopmo.py name x y frames [ticks_per_frame] [ms_per_frame]"""
import bg, sh, sys, time, os, subprocess
name=sys.argv[1]; x,y=int(sys.argv[2]),int(sys.argv[3]); N=int(sys.argv[4])
K=int(sys.argv[5]) if len(sys.argv)>5 else 8; DT=int(sys.argv[6]) if len(sys.argv)>6 else 80
z=int(sys.argv[7]) if len(sys.argv)>7 else 128
out=f'{sh.SP}/shots/{name}'; os.makedirs(out,exist_ok=True)
W="require('plugins.overlay').get_state().db['improved-water.overlay'].widget"
print(bg.lua(f'df.global.pause_state=true df.global.window_x={x} df.global.window_y={y} df.global.window_z={z} {W}.visible=true print(reqscript("improved-water").state.clock)'))
base=int(float(bg.lua('print(reqscript("improved-water").state.clock)').split()[-1]))
def grab(p):
    subprocess.run(['caffeinate','-u','-t','1'])
    subprocess.run(['screencapture','-x','-o','-l','38307',p],check=True)
for i in range(N):
    bg.lua(f'df.global.pause_state=false dfhack.timeout({K},"ticks",function() df.global.pause_state=true end)')
    for t in range(40):
        time.sleep(0.15)
        r=bg.lua(f'if df.global.pause_state then reqscript("improved-water").state.clock={base+i*DT} {W}.visible=true end print(df.global.pause_state, df.global.cur_year_tick, #df.global.world.status.popups, df.global.window_x, df.global.window_y)').split()
        if r[2]!='0': print('popup', sh.popups())
        if r[0]=='true': break
    else:
        print('step did not finish', r); break
    time.sleep(0.15); grab(f'{out}/a{i:03d}.png')
    bg.lua(f'{W}.visible=false'); time.sleep(0.15); grab(f'{out}/b{i:03d}.png')
    bg.lua(f'{W}.visible=true')
    if i%8==0: print(i, r, flush=True)
print('done', bg.lua(f'{W}.visible=true print(df.global.pause_state)'))
