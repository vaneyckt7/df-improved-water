#!/bin/zsh
# usage: apply_still.sh <bin> <tag>   - install frames, rebuild the still set, capture a close-up
SP=/private/tmp/claude-501/-Users-tomvaneyck-claude/88a8e59b-fdad-44d3-90db-5452c30fe43a/scratchpad
DF="$HOME/Library/Containers/com.isaacmarovitz.Whisky/Bottles/BC48C107-7437-4AE0-85E0-15A7FAA5F17C/drive_c/Program Files (x86)/Steam/steamapps/common/Dwarf Fortress"; L="$DF/stderr.log"
cp "$1" "$DF/dfhack-config/scripts/caustics_still.bin"; [ -n "$3" ] && cp "$3" "$DF/dfhack-config/scripts/caustics_rings.bin"; a=$(wc -l < "$L"); cd $SP/df
$SP/vid/venv/bin/python - <<'PY'
import bg,time
bg.lua("dfhack.run_command('overlay','disable','caustics.overlay') require('plugins.overlay').rescan() local c=reqscript('caustics') c.state.cache=nil c.state.sets.none=nil c.state.sets.shallow=nil c.state.rings=nil c.state.partial={} c.state.stats={n=0,us=0} dfhack.run_command('overlay','enable','caustics.overlay')",timeout=120)
time.sleep(18)
bg.lua("local c=reqscript('caustics') c.state.stats={n=0,us=0}")
time.sleep(3)
print(bg.lua("local c=reqscript('caustics') local m=0 for k in pairs(c.state.partial) do m=m+1 end print('baking',m) dfhack.run_command('caustics','stats') print(df.global.pause_state, df.global.cur_year_tick)"))
PY
$SP/vid/venv/bin/python pondcap.py $2 > /dev/null
$SP/vid/venv/bin/python -c "
from PIL import Image
ims=[Image.open('$2%d.png'%i).convert('RGB') for i in (0,2,4,6)]
w,h=ims[0].size
s=Image.new('RGB',(1600,800))
for i,m in enumerate(ims): s.paste(m.crop((w//2-400,h//2-200,w//2+400,h//2+200)),((i%2)*800,(i//2)*400))
s.save('$2_zoom.png')"
echo "non-RPC log lines: $(tail -n +$((a+1)) "$L" | grep -vc 'lient connection')"
