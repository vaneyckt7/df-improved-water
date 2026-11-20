-- Debug view: marks each of the game's ocean waves (world.event.ocean_waves) with an arrow pointing the way
-- the wave is heading (toward its destination tile). BEHIND draws the arrow on the tile the wave just left,
-- so the wave's own tile stays free for the foam drawn by caustics.lua; otherwise the wave's tile is filled.
--@ module = true
local overlay = require('plugins.overlay')
local guidm = require('gui.dwarfmode')

COLOR = 0xC0FF40FF   -- 0xAABBGGRR: magenta, 75% solid
ARROW = 0xFFFFFFFF
BEHIND = true

state = state or {}

local function sign(n) return n > 0 and 1 or n < 0 and -1 or 0 end

-- one 32x32 tile per heading (dx, dy each -1, 0 or 1)
local function arrow_tile(dx, dy)
    local pix, len = {}, math.sqrt(dx * dx + dy * dy)
    for y = 0, 31 do
        for x = 0, 31 do
            local c = BEHIND and 0 or COLOR
            if len > 0 then
                local px, py = x - 15.5, y - 15.5
                local u, v = (px * dx + py * dy) / len, math.abs(px * dy - py * dx) / len
                if (u >= -12 and u <= 5 and v <= 1.6) or (u >= 3 and u <= 13 and v <= (13 - u) * 0.75) then
                    c = BEHIND and COLOR | 0xFF000000 or ARROW
                end
            end
            pix[y * 32 + x + 1] = c
        end
    end
    return dfhack.textures.createTileset(pix, 32, 32, 32, 32)[1]
end

WaveTiles = defclass(WaveTiles, overlay.OverlayWidget)
WaveTiles.ATTRS{
    desc='Marks every ocean wave with an arrow for its heading.',
    viewscreens='dwarfmode',
    default_enabled=false,
    fullscreen=true,
}
function WaveTiles:overlay_onupdate() end
function WaveTiles:onRenderFrame()
    if not dfhack.isMapLoaded() then return end
    state.seen = os.clock()
    if state.behind ~= BEHIND then state.behind, state.arrows = BEHIND, {} end
    local vp = guidm.Viewport.get()
    local z0 = df.global.window_z
    local pen, paint, getTexpos = {ch=0, fg=COLOR_WHITE}, dfhack.screen.paintTile, dfhack.textures.getTexposByHandle
    for _, w in ipairs(df.global.world.event.ocean_waves) do
        local dx, dy = sign(w.dest.x - w.cur.x), sign(w.dest.y - w.cur.y)
        local x, y = w.cur.x, w.cur.y
        if BEHIND then x, y = x - dx, y - dy end
        if w.z == z0 and x >= vp.x1 and x <= vp.x2 and y >= vp.y1 and y <= vp.y2 then
            local k = (dy + 1) * 3 + dx + 1
            local h = state.arrows[k]
            if not h then h = arrow_tile(dx, dy); state.arrows[k] = h end
            paint(pen, x - vp.x1, y - vp.y1, nil, getTexpos(h), true)
        end
    end
end
OVERLAY_WIDGETS = {show=WaveTiles}
