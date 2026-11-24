--@module = true
-- Prototype: "caustics" on water tiles. Two tileable 128px fields drift with the
-- river's flow while sliding sideways against each other; pixels are lit only where both
-- are bright, snapped to two levels.
local overlay = require('plugins.overlay')
local guidm = require('gui.dwarfmode')

local N, TP, STEPS = 128, 32, 128       -- pattern size, tile px, loop length (1px per step)
STEP_MS = 80
WIDTH = 7                                -- web line width in px
-- Packed 0xAABBGGRR. Measured blend (2026-11-18): out = colour*a^2 + background*(1-a),
-- so alpha below ~0.4 darkens dark water instead of lighting it. These lift river water
-- by roughly +25 (HI) and +14 (LO) per channel.
HI = 0x84FFFF50
LO = 0x76FFFF40
-- Glint: near-white speck in the very brightest strand cores (about 3-4 px per tile,
-- measured on the field file). Lifts water by roughly +50 per channel.
GLINT = 0xB0FFFFE0
-- Still water: a fuller, calmer net with no glints. STILL_GATE is how much of the web the
-- gate lets through (0 = river-like fragments, 120+ = the whole net).
STILL_GATE, STILL_SWAY, STILL_GATE_R = 115, 3, 20
-- Still water is mostly glints: the net is reduced to faint thin cores, and STILL_GLINTS
-- fixed points per 4x4 tiles each swell from a dot to a small cross and fade again,
-- 2 or 3 times per loop (about 5-7 s each), all out of step with one another.
STILL_GLINTS = 30
-- how bright a strand core must be to show at all on still water (175 = as on the river)
STILL_T = 180
GLINT_DIM = 0x94FFFFA8
-- Still water, simulated frames: level 1 is a faint net, levels 2-3 (HI, GLINT) are the bright
-- points where its lines meet.
STILL_FAINT = 0x64FFFF40
STILL_VFAINT = 0x57FFFF40   -- level 4: very faint long lines under the streaks
STILL_CROSS = 0x84FFFFFF    -- level 5: where two still-water lines overlap: white, same strength as HI (rings keep HI/GLINT)
STILL_SHADOW = 0x1C604000   -- level 6: trough inside a ring (deep water teal at 11%, only darkens the water a little)
-- levels 7-12: ring crest, brightest first. Colours of the source ripple animation (pale cyan fading into the
-- water colour), solved for this overlay's blend on in-game water of about RGB 1,78,90.
RING_COLS = {0x87FDEE3A, 0x80F9EB3B, 0x75FFF03C, 0x70F9E935, 0x69FDEA2E, 0x63FDE622}   -- 26% of the animation's lightening; brighter steps pulled up to 40% toward the water's teal hue
-- Rings: now and then a thin circle pops up in a still-water tile, widens and fades.
-- RING_CHANCE is the chance (per 1000) that a tile plays each ring slot it is offered; every
-- tile is offered 4 slots per loop, so 1000 tiles of pond show about 4 * RING_CHANCE rings a loop.
RING_CHANCE = 15
-- TRIAL: flowing water plays the still-water frames, carried along with the flow at this many px per step
-- (0 = the river's own generated pattern). Whole numbers only, so the 128-step loop closes without a jump.
FLOW_STILL = 1
-- TRIAL: on flowing water the pattern itself changes this many still-water frames per step (1 = as on the pond),
-- so its own shimmer is not drowned out by the drift. Whole numbers only.
FLOW_ANIM = 2
-- TRIAL: where two flow directions meet, the tiles on both sides of the border show both directions' patterns
-- together, each one step fainter, so lines fade across the border instead of being cut off at it.
FLOW_FADE = true
-- TRIAL: true = on those border tiles each pattern is one step fainter; false = both at full strength.
FLOW_FADE_DIM = false
-- true = the water stands still while the game is paused and carries on from the same frame after.
PAUSE_FREEZE = true
-- Sea water (salt, not flowing, on a map that has ocean waves) shows the still-water caustics without rings.
-- UNDER_LAYER: map viewport layer the caustics are written to, below the interface layer that overlays such as
-- Flowing Waves paint on, so their waves and foam show over the caustics. false = paint on the interface layer.
UNDER_LAYER = 'screentexpos_signpost'
-- SEA_WASH: also light the wave water that washes over the beach (OceanWave flows at least this dense; the
-- Flowing Waves mod draws thinner ones as foam). false = sea tiles only. Tiles holding an item, creature or
-- building are left alone.
SEA_WASH = 20
-- The wash is lighter than the sea (about RGB 20,114,127 with the recoloured Flowing Waves sheets), and by
-- the blend above the sea's line colours come out DARKER than it (measured: lines grey on the wash). These
-- stronger ones lift it instead: level 1 line, 2 bright, 3 glint, 4 very faint, 5 white.
-- The sea's own colours (ponds and rivers keep theirs): level 1 line, 2 bright, 3 glint, 4 very faint halo,
-- 5 crossing. Lines and halo as on a pond (30% fainter lines left little web between the crossings); crossings are aqua and
-- lighter than the lines, about 33,127,132 on sea of 1,82,92 (white there came out grey, about 69,110,113). false = as on ponds.
SEA_COLS = {STILL_FAINT, HI, GLINT, STILL_VFAINT, 0x9EFFFF58}
WASH_COLS = {0x91FFFF40, 0x9EFFFF50, 0xADFFFFA0, 0x85FFFF40, 0xB8FFFF70}   -- lifts of about +19, +28, +42, +10, +42; crossings aqua, not white (white came out grey)
-- WAVES: also draw the ocean's waves, wash, foam and spray (see the WAVES part below). false = caustics only.
WAVES = true
state = state or {}
state.sets = state.sets or {}            -- frame sets keyed by flow direction
state.stats = state.stats or {n=0, us=0}
state.clock = state.clock or dfhack.getTickCount()   -- ms of animation time

-- df.tile_liquid_flow_dir -> screen vector (north is y-1)
local DIRS = {
    south={0, 1}, east={1, 0}, northeast={1, -1}, west={-1, 0}, northwest={-1, -1},
    southeast={1, 1}, southwest={-1, 1}, north={0, -1},
}

local webs
local function web(seed)
    local rng = dfhack.random.new(seed)
    local px, py = {}, {}
    for i = 1, 14 do px[i] = rng:drandom() * N; py[i] = rng:drandom() * N end
    local w = {}
    for y = 0, N - 1 do
        for x = 0, N - 1 do
            local d1, d2 = 1e9, 1e9
            for i = 1, 14 do
                local dx = math.abs(x - px[i]); if dx > N / 2 then dx = N - dx end
                local dy = math.abs(y - py[i]); if dy > N / 2 then dy = N - dy end
                local d = math.sqrt(dx * dx + dy * dy)
                if d < d1 then d2 = d1; d1 = d elseif d < d2 then d2 = d end
            end
            w[y * N + x] = math.max(0, 1 - (d2 - d1) / WIDTH)
        end
    end
    return w
end

-- Bake the frame loop for one flow direction. Field A moves at 2*flow+side, field B at
-- 2*flow-side, so the lit overlap travels with the flow and still shimmers. Still water
-- (dir 'none') keeps the two sliding against each other with no net drift.
-- Old textures are never freed: deleteHandle crashed DF (access violation, 2026-11-18).
-- The two fields come from caustics_fields.bin (2 x 128x128 bytes, made offline: warped
-- Voronoi strands gated by broad soft bands). Without the file, fall back to plain webs.
local T_LO, T_HI = 136, 175
local T_GL = 215
local function load_fields()
    local f = io.open(dfhack.getDFPath() .. '/dfhack-config/scripts/caustics_fields.bin', 'rb')
    local data = f and f:read('a')
    if f then f:close() end
    if not data or #data ~= 2 * N * N then
        T_LO, T_HI, T_GL = 77, 153, 250
        local A, B = web(3), web(11)
        for k = 0, N * N - 1 do A[k] = A[k] * 255; B[k] = B[k] * 255 end
        return {A, B}
    end
    local out = {}
    for k = 0, 1 do
        local w = {}
        for i = 0, N * N - 1 do w[i] = data:byte(k * N * N + i + 1) end
        out[k + 1] = w
    end
    return out
end

local function wobble(amp, k, ko, o, phase_deg)
    local t = {}
    for i = 0, N - 1 do
        t[i] = math.floor(amp * math.sin(2 * math.pi * (k * i + ko * o) / N + math.rad(phase_deg)) + 0.5)
    end
    return t
end

-- Bake animation frame o (0-based) of one direction's loop.
-- Still water plays frames baked offline from a simulation of light refracted through a calm
-- surface (caustics_still.bin: STEPS frames of N x N bytes, 0 = unlit, 1-3 = brightness level).
-- If the file is missing or the wrong size, the procedural pattern below is used instead.
local still_data
local function load_still()
    if still_data == nil then
        still_data = false
        local f = io.open(dfhack.getDFPath() .. '/dfhack-config/scripts/caustics_still.bin', 'rb')
        if f then
            local s = f:read('a'); f:close()
            if #s == STEPS * N * N then still_data = s end
        end
    end
    return still_data
end
local function build_still_frame(data, o, ox, oy, wash)
    ox, oy = ox or 0, oy or 0
    local pix, base, col = {}, o * N * N, wash == 'wash' and {[0] = 0, WASH_COLS[1], WASH_COLS[2], WASH_COLS[3], WASH_COLS[4], WASH_COLS[5]} or wash == 'sea' and {[0] = 0, SEA_COLS[1], SEA_COLS[2], SEA_COLS[3], SEA_COLS[4], SEA_COLS[5]} or {[0] = 0, STILL_FAINT, HI, GLINT, STILL_VFAINT, STILL_CROSS, STILL_SHADOW, RING_COLS[1], RING_COLS[2], RING_COLS[3], RING_COLS[4], RING_COLS[5], RING_COLS[6]}
    for y = 0, N - 1 do
        local sy = (y - oy) % N
        local row = {data:byte(base + sy * N + 1, base + sy * N + N)}
        local at = y * N
        for x = 1, N do pix[at + x] = col[row[(x - 1 - ox) % N + 1]] or 0 end
    end
    return dfhack.textures.createTileset(pix, N, N, TP, TP)
end

-- Border between two flow directions: both patterns, each one step fainter (white -> line -> very faint -> off).
local DIMMED = FLOW_FADE_DIM and {[0] = 0, 4, 1, 1, 0, 1, 0} or {[0] = 0, 1, 2, 3, 4, 5, 6}
local RANK = {[0] = 0, 2, 3, 4, 1, 3, 0}
local function build_mix_frame(data, o, da, db, anim, drift)
    anim, drift = anim or FLOW_ANIM, drift or FLOW_STILL
    local pix, base = {}, (o * anim % STEPS) * N * N
    local col = {[0] = 0, STILL_FAINT, HI, GLINT, STILL_VFAINT, STILL_CROSS, STILL_SHADOW}
    local ax, ay, bx, by = da[1] * drift * o, da[2] * drift * o, db[1] * drift * o, db[2] * drift * o
    for y = 0, N - 1 do
        local sa, sb = (y - ay) % N, (y - by) % N
        local ra = {data:byte(base + sa * N + 1, base + sa * N + N)}
        local rb = {data:byte(base + sb * N + 1, base + sb * N + N)}
        local at = y * N
        for x = 1, N do
            local a, b = DIMMED[ra[(x - 1 - ax) % N + 1]] or 0, DIMMED[rb[(x - 1 - bx) % N + 1]] or 0
            pix[at + x] = col[RANK[a] >= RANK[b] and a or b]
        end
    end
    return dfhack.textures.createTileset(pix, N, N, TP, TP)
end

-- Ring events (caustics_rings.bin, made offline from the same frames): byte EV, byte LIFE,
-- EV x (tile position 0-15, start frame), then EV x LIFE x TP x TP level bytes. Each event is
-- one tile position's still-water pixels over LIFE frames with a ring drawn on top, so a map
-- tile can swap to it for the ring's life without a seam. Which tiles do so is decided per
-- tile and per occurrence by a hash, so rings do not repeat in a grid.
local ring_data
local function load_rings()
    if ring_data == nil then
        ring_data = false
        local f = io.open(dfhack.getDFPath() .. '/dfhack-config/scripts/caustics_rings.bin', 'rb')
        if f then
            local s = f:read('a'); f:close()
            local ev, life = s:byte(1, 2)
            if ev and life and ev > 0 and life > 0 and life <= STEPS and #s == 2 + 2 * ev + ev * life * TP * TP then
                ring_data = {s = s, ev = ev, life = life}
            end
        end
    end
    return ring_data
end
local function build_ring(rd, e)  -- e is 0-based
    local s, life = rd.s, rd.life
    local pos, start = s:byte(3 + 2 * e, 4 + 2 * e)
    if pos > 15 or start >= STEPS then return false end
    local base = 2 + 2 * rd.ev + e * life * TP * TP
    local col, pix, n = {[0] = 0, STILL_FAINT, HI, GLINT, STILL_VFAINT, STILL_CROSS, STILL_SHADOW, RING_COLS[1], RING_COLS[2], RING_COLS[3], RING_COLS[4], RING_COLS[5], RING_COLS[6]}, {}, 0
    for y = 0, TP - 1 do
        for a = 0, life - 1 do
            local at = base + (a * TP + y) * TP
            local row = {s:byte(at + 1, at + TP)}
            for x = 1, TP do n = n + 1; pix[n] = col[row[x]] or 0 end
        end
    end
    return {pos = pos, start = start, tiles = dfhack.textures.createTileset(pix, life * TP, TP, TP, TP)}
end
-- bake one ring event per call; state.rings.by_pos is only set once all are done
local function bake_ring()
    -- the ring clips are cut from the simulated frames, so without those there are no rings
    local rd = load_still() and load_rings()
    if not rd then state.rings = {done = true}; return end
    local r = state.rings or {n = 0, list = {}}
    state.rings = r
    local e = build_ring(rd, r.n)
    r.n = r.n + 1
    if e then r.list[#r.list + 1] = e end
    if r.n >= rd.ev then
        local by = {}
        for _, v in ipairs(r.list) do
            by[v.pos + 1] = by[v.pos + 1] or {}
            table.insert(by[v.pos + 1], v)
        end
        r.by_pos, r.life, r.done = by, rd.life, true
    end
end

local function build_frame(dir, o)
    local da, db = dir:match('^(%a+)%+(%a+)$')
    if da then
        local data = load_still()
        if data then return build_mix_frame(data, o, DIRS[da], DIRS[db]) end
        dir = da
    end
    if not DIRS[dir] then
        local data = load_still()
        if data then return build_still_frame(data, o, 0, 0, dir == 'wash' and 'wash' or dir == 'sea' and 'sea' or nil) end
    end
    if DIRS[dir] and FLOW_STILL > 0 then
        local data = load_still()
        if data then return build_still_frame(data, o * FLOW_ANIM % STEPS, DIRS[dir][1] * FLOW_STILL * o, DIRS[dir][2] * FLOW_STILL * o) end
    end
    webs = webs or load_fields()
    local A, B = webs[1], webs[2]
    local d = DIRS[dir]
    local ax, ay, bx, by
    if d then
        ax, ay, bx, by = 2 * d[1] - d[2], 2 * d[2] + d[1], 2 * d[1] + d[2], 2 * d[2] - d[1]
    else
        ax, ay, bx, by = 0, 0, 0, 0
    end
    -- per-frame offsets. Flowing water drifts steadily. Still water does not travel: the web
    -- sways on a small circle while its soft gate circles the other way, so parts of the net
    -- slowly light up and dim in place.
    local oxa, oya, oxb, oyb = ax * o, ay * o, bx * o, by * o
    local gate, glint_at, sway = 0, T_GL, 1
    local c_hi, c_lo, t_hi = HI, LO, T_HI
    if not d then
        local th = 2 * math.pi * o / STEPS
        oxa, oya = math.floor(STILL_SWAY * math.cos(th) + 0.5), math.floor(STILL_SWAY * math.sin(th) + 0.5)
        oxb, oyb = math.floor(STILL_GATE_R * math.cos(1 - th) + 0.5), math.floor(STILL_GATE_R * math.sin(1 - th) + 0.5)
        gate, glint_at, sway = STILL_GATE, 256, 0.5
        c_hi, c_lo, t_hi = HI, 0, STILL_T
    end
    do
        -- small two-axis sways so the strands bend as they travel
        local axw, ayw = wobble(2.0 * sway, 3, 3, o, 0), wobble(1.5 * sway, 2, -2, o, 90)      -- A: x by row, y by column
        local byw, bxw = wobble(2.0 * sway, 3, 2, o, 45), wobble(1.5 * sway, 2, -3, o, 200)   -- B: y by column, x by row
        local pix = {}
        for y = 0, N - 1 do
            local xa, xb = -oxa + axw[y], -oxb + bxw[y]
            local ya, yb = y - oya, y - oyb
            local row = y * N + 1
            for x = 0, N - 1 do
                local a = A[((ya + ayw[x]) % N) * N + (x + xa) % N]
                local b = B[((yb + byw[x]) % N) * N + (x + xb) % N] + gate
                local c = a < b and a or b
                pix[row + x] = c >= t_hi and (c >= glint_at and GLINT or c_hi) or (c >= T_LO and c_lo or 0)
            end
        end
        if not d then
            local function put(x, y, v) pix[(y % N) * N + x % N + 1] = v end
            local seed = 20261119
            local function rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648; return (seed >> 8) % n end
            for _ = 1, STILL_GLINTS do
                local gx, gy, ph, cyc = rnd(N), rnd(N), rnd(64) / 64, 2 + rnd(2)
                local s = math.sin(2 * math.pi * (cyc * o / STEPS + ph))
                if s > 0.2 then
                    put(gx, gy, s > 0.55 and GLINT or GLINT_DIM)
                    if s > 0.55 then
                        put(gx - 1, gy, GLINT_DIM); put(gx + 1, gy, GLINT_DIM)
                        put(gx, gy - 1, GLINT_DIM); put(gx, gy + 1, GLINT_DIM)
                    end
                    if s > 0.9 then
                        put(gx - 1, gy, GLINT); put(gx + 1, gy, GLINT)
                        put(gx - 2, gy, GLINT_DIM); put(gx + 2, gy, GLINT_DIM)
                    end
                end
            end
        end
        return dfhack.textures.createTileset(pix, N, N, TP, TP)
    end
end

-- Baking a whole loop takes ~0.7 s, so it is spread over render frames: bake_some() adds
-- up to BAKE_PER_FRAME frames per call, and a direction is only drawn once complete.
BAKE_PER_FRAME = 2
state.partial = state.partial or {}
local function bake_some(dir, budget)
    local part = state.partial[dir] or {}
    state.partial[dir] = part
    while budget > 0 and #part < STEPS do
        part[#part + 1] = build_frame(dir, #part)
        budget = budget - 1
    end
    if #part == STEPS then
        state.sets[dir], state.partial[dir] = part, nil
    end
    return budget
end

function build(dir)  -- bake a whole direction at once (blocks for ~0.7 s)
    bake_some(dir, STEPS)
    return state.sets[dir]
end

-- Which visible tiles show water (looking down through open space), each with a drift
-- direction. The game's per-tile flow directions point inward from the banks (NE on one
-- side, NW on the other, N mid-stream), so each tile uses the average direction of the
-- water within SMOOTH tiles of it. That depends only on the map, not on the view, so
-- scrolling never changes which way a tile drifts.
local SMOOTH = 4

-- The game stores no per-tile speed, only a direction. The world does record a flow amount
-- for each river where it crosses the fort's world tile (0..~2900 in a medium world,
-- median ~20), so the drift speed of flowing water follows that: a trickle steps every
-- SLOW_MS, a great river every FAST_MS. Still water shimmers in place at STILL_MS.
SLOW_MS, FAST_MS, STILL_MS = 120, 50, 80
local function river_step_ms()
    local site = dfhack.world.getCurrentSite()
    local id = site and site.id or -1
    if state.step_site == id and state.step_ms then return state.step_ms end
    local flow = 0
    if site then
        for _, r in ipairs(df.global.world.world_data.rivers) do
            local px, py = r.path.x, r.path.y
            for j = 0, #px - 1 do
                if px[j] == site.pos.x and py[j] == site.pos.y and r.flow[j] > flow then flow = r.flow[j] end
            end
        end
    end
    -- log scale between flow 10 and 1000
    local f = math.max(0, math.min(1, (math.log(math.max(flow, 1), 10) - 1) / 2))
    state.step_site, state.flow = id, flow
    state.step_ms = flow > 0 and math.floor(SLOW_MS + (FAST_MS - SLOW_MS) * f + 0.5) or STEP_MS
    return state.step_ms
end
local OCT = {[0]='east', 'southeast', 'south', 'southwest', 'west', 'northwest', 'north', 'northeast'}
-- 'sea' once this map has shown ocean waves (it then stays that way), else nil
local function sea_key()
    local site = dfhack.world.getCurrentSite()
    local id = dfhack.world.ReadWorldFolder() .. '/' .. (site and site.id or -1)
    local f = state.sea
    if not f or f.id ~= id then f = {id=id}; state.sea = f end
    if not f.waves and #df.global.world.event.ocean_waves > 0 then f.waves = true end
    return f.waves and 'sea'
end
local function water_map(vp)
    local z0 = df.global.window_z
    local key = ('%d,%d,%d,%d,%d'):format(vp.x1, vp.y1, vp.x2, vp.y2, z0)
    local now = dfhack.getTickCount()
    -- rescan at most every 500 ms for a still view, and every 100 ms while panning (the
    -- list holds map coordinates, so a slightly stale one only misses newly exposed tiles)
    if state.cache then
        local age = now - state.cache_at
        if age < 100 and state.z == z0 or age < 500 and state.key == key then return state.cache end
    end
    local getFlags, getType, getBlock = dfhack.maps.getTileFlags, dfhack.maps.getTileType, dfhack.maps.getTileBlock
    local attrs, OPEN, RAMP_TOP = df.tiletype.attrs, df.tiletype_shape.EMPTY, df.tiletype_shape.RAMP_TOP
    local names = df.tile_liquid_flow_dir
    local sea = sea_key()
    local M = SMOOTH + 1
    local W = vp.x2 - vp.x1 + 1 + 2 * M
    local fx, fy, water = {}, {}, {}
    for y = vp.y1 - M, vp.y2 + M do
        for x = vp.x1 - M, vp.x2 + M do
            for z = z0, math.max(0, z0 - 4), -1 do
                local d, occ = getFlags(x, y, z)
                if not d or d.hidden then break end
                -- a bridge or other building here covers whatever is below it
                if occ.building ~= 0 then break end
                if d.flow_size > 0 then
                    if not d.liquid_type then  -- false = water
                        local k = (y - vp.y1 + M) * W + (x - vp.x1 + M)
                        local b = getBlock(x, y, z)
                        local nm = b and names[b.liquid_flow[x % 16][y % 16].perm_flow_dir]
                        local v = DIRS[nm]
                        -- 'none' / 'down' = river water with no direction of its own (the column where
                        -- a river leaves the map): it takes the direction of the river water around
                        -- it. Ponds are 'inactive' and stay still.
                        local flowing = v or nm == 'none' or nm == 'down'
                        -- 1 = flowing, 2 = still, 3 = creature in the tile (leave it unlit), 4 = sea
                        water[k] = (occ.unit or occ.unit_grounded) and 3 or (flowing and 1 or (sea and d.water_salt) and 4 or 2)
                        if v then
                            local n = (v[1] ~= 0 and v[2] ~= 0) and 0.7071 or 1
                            fx[k], fy[k] = v[1] * n, v[2] * n
                        end
                    end
                    break
                end
                local tt = getType(x, y, z)
                if not tt then break end
                local sh = attrs[tt].shape
                if sh ~= OPEN and sh ~= RAMP_TOP then break end
            end
        end
    end
    local dm = {}
    for y = vp.y1 - 1, vp.y2 + 1 do
        for x = vp.x1 - 1, vp.x2 + 1 do
            local cy, cx = y - vp.y1 + M, x - vp.x1 + M
            local kind = water[cy * W + cx]
            if kind == 2 then
                -- still water (ponds, pools) never borrows a neighbouring river's drift
                dm[cy * W + cx] = 'none'
            elseif kind == 4 then
                dm[cy * W + cx] = sea
            elseif kind == 1 then
                local sx, sy = 0, 0
                for yy = cy - SMOOTH, cy + SMOOTH do
                    local base = yy * W
                    for xx = cx - SMOOTH, cx + SMOOTH do
                        local v = fx[base + xx]
                        if v then sx = sx + v; sy = sy + fy[base + xx] end
                    end
                end
                local dir = 'none'
                if sx * sx + sy * sy > 0.25 then
                    dir = OCT[math.floor(math.atan(sy, sx) / (math.pi / 4) + 0.5) % 8]
                end
                dm[cy * W + cx] = dir
            end
        end
    end
    local list = {}
    local fade = FLOW_FADE and FLOW_STILL > 0
    local NB = {-W - 1, -W, -W + 1, -1, 1, W - 1, W, W + 1}
    for y = vp.y1, vp.y2 do
        for x = vp.x1, vp.x2 do
            local at = (y - vp.y1 + M) * W + (x - vp.x1 + M)
            local d = dm[at]
            if d then
                if fade and DIRS[d] then
                    for i = 1, 8 do
                        local nd = dm[at + NB[i]]
                        if nd and nd ~= d and DIRS[nd] then d = d < nd and d .. '+' .. nd or nd .. '+' .. d; break end
                    end
                end
                list[#list + 1] = {x, y, d}
            end
        end
    end
    if sea and SEA_WASH then
        local WAVE = df.flow_type.OceanWave
        for by = vp.y1 - vp.y1 % 16, vp.y2, 16 do
            for bx = vp.x1 - vp.x1 % 16, vp.x2, 16 do
                local block = getBlock(bx, by, z0)
                for _, flow in ipairs(block and block.flows or {}) do
                    if flow.type == WAVE and flow.density >= SEA_WASH then
                        local pos = flow.pos
                        local x, y = pos.x, pos.y
                        if pos.z == z0 and x >= vp.x1 and x <= vp.x2 and y >= vp.y1 and y <= vp.y2 then
                            local at = (y - vp.y1 + M) * W + (x - vp.x1 + M)
                            if not dm[at] and not water[at] then
                                local d, occ = getFlags(x, y, z0)
                                if d and not d.hidden and occ.building == 0
                                    and not (occ.item or occ.unit or occ.unit_grounded) then
                                    dm[at] = 'wash'
                                    list[#list + 1] = {x, y, 'wash'}
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    state.cache, state.key, state.cache_at, state.z = list, key, now, z0
    return list
end

----------------------------------------------------------------------------------------------
-- WAVES: the game's own ocean waves, drawn in graphics mode.
--
-- This part is the script of the Flowing Waves mod 1.3 by Poss (Steam Workshop 3829998283,
-- scripts_modactive/flowing_waves.lua), copied in and changed here. Its art is in
-- dfhack-config/scripts/caustics_waves_art/. Keep that mod's own overlay (flowing_waves.waves) disabled,
-- or both draw.
--
-- The game simulates waves washing up beaches as OceanWave and SeaFoam flows. ASCII mode draws
-- them, but graphics mode has no FLOW_ token for them, so they're invisible there. This part
-- finds those flows on the visible z-level every RESCAN_MS and draws water where they are:
--   crests       on each incoming wave crossing the sea (the game keeps these apart from the flows)
--   wash         on every wave tile, with foam and rounded corners where it meets dry beach. A wave
--                that has thinned below WAVE_FOAM_BELOW is drawn as foam instead.
--   rock fringe  on rock beside the wash: the water laps onto the rock, with a foam rim
--   sea fringe   on sea beside the wash, so the wash runs into the sea without a seam
--   boulders     in or beside the wash: water swapped into the floor layer under the boulder
--   sea foam     on each SeaFoam tile: a still patch of bubbles that pop as the flow's density falls
--   spray        on each Steam flow over a wave or the sea, as whitecaps
-- The older 'side'/'up' styles draw the wave-crest sheets on each wave tile instead.
--
-- Every RESCAN_MS the flows are found and every tile planned (a "piece": sheet, row, layer, animation
-- offset); when the picture changes the pieces become a draw list; every frame the list is written.
--
--   caustics waves                  show status
--   caustics river|auto|side|up     wave style: river water (default), or the crest sheets
--   caustics reload                 reload the wave art, e.g. after rebuilding it
--   caustics timing                 time spent scanning, planning and drawing waves
----------------------------------------------------------------------------------------------
local wave_painter
local WAVE_FLOWS = {[df.flow_type.OceanWave] = true, [df.flow_type.SeaFoam] = true}
do
local FRAMES = 16             -- every animation is 16 frames
local TICKS_PER_FRAME = 10    -- the brook animation's pace: about 10 frames a second
local MS_PER_TICK = 10        -- normal speed: the game's 100 ticks a second
local RESCAN_MS = 100         -- how often to look for wave flows again
local FORGET_FOAM_MS = 1000   -- how often to drop foam that has gone
local TERRAIN_RECHECK_MS = 1000  -- how often to check known tiles for digging and building
local SHORE_RADIUS = 10       -- how far to look for the sea when working out which way a shore faces

local FOAM_STAGES = 8         -- stages of the foam's life: 0 (nearly gone) to 7 (fresh)
local FOAM_VARIANTS = 4       -- different patches, picked by tile position
local SPRAY_FULL = 100        -- spray density drawn as fresh foam
local WHITECAP_MAX_STAGE = 3  -- spray on the water is drawn no heavier than this foam stage (thin strands)
local WAVE_FOAM_BELOW = 20    -- wave density below which the wash has broken up into foam

local SWELL_WHITENESS = 4     -- swell sheet rows per heading: 0 far out to 3 about to break


style = style or 'river'

----------------------------------------------------------------------------------------------
-- Directions
----------------------------------------------------------------------------------------------

-- The four sides and four corners of a tile, with the bit each one has in the sheets' masks.
local N  = {dx =  0, dy = -1, bit = 1}
local E  = {dx =  1, dy =  0, bit = 2}
local S  = {dx =  0, dy =  1, bit = 4}
local W  = {dx = -1, dy =  0, bit = 8}
local NE = {dx =  1, dy = -1, bit = 16}
local NW = {dx = -1, dy = -1, bit = 32}
local SE = {dx =  1, dy =  1, bit = 64}
local SW = {dx = -1, dy =  1, bit = 128}
local HERE = {dx = 0, dy = 0}
local SIDES = {N, E, S, W}
local SIDES_AND_CORNERS = {N, E, S, W, NE, NW, SE, SW}
local HERE_AND_SIDES = {HERE, N, E, S, W}

-- The eight ways river water can flow, in the order vanilla's FLOWS page (and so the wash sheet)
-- stores them.
local FLOW_DIRECTIONS = {NW, NE, SE, SW, N, S, W, E}

local function add_bit(mask, bit)
    if (mask // bit) % 2 == 0 then return mask + bit end
    return mask
end

----------------------------------------------------------------------------------------------
-- Art
----------------------------------------------------------------------------------------------

local art_dir = dfhack.getDFPath() .. '/dfhack-config/scripts/caustics_waves_art/'

-- DFHack keeps every image it has loaded for the rest of the session, keyed by path, so loading
-- the same path again gives the old picture. To pick up rebuilt art, `caustics reload` loads
-- fresh copies from art/reloaded/ under new names.
reload_count = reload_count or 0

local function copy_file(from, to)
    local input = assert(io.open(from, 'rb'))
    local data = input:read('a')
    input:close()
    local output = assert(io.open(to, 'wb'))
    output:write(data)
    output:close()
end

local function art_path(name)
    if reload_count == 0 then return art_dir .. name end
    local copies = art_dir .. 'reloaded/'
    dfhack.filesystem.mkdir(copies)
    local copy = copies .. reload_count .. '-' .. name
    copy_file(art_dir .. name, copy)
    os.remove(copies .. (reload_count - 1) .. '-' .. name)   -- the previous reload's copy
    return copy
end

local function load_tiles(name)
    return dfhack.textures.loadTileset(art_path(name), 32, 32, true)
end

-- Loaded on first use; `caustics reload` clears this.
local function load_sheets()
    return {
        side_crests = load_tiles('sidesheet.png'),
        up_crests = load_tiles('upsheet.png'),
        wash = load_tiles('riversheet.png'),
        rock_fringe = load_tiles('riverfringe.png'),
        sea_fringe = load_tiles('riverseafringe.png'),
        under_boulder = load_tiles('riverbase.png'),
        sea_foam = load_tiles('seafoam.png'),
        swell = load_tiles('swell.png'),
    }
end

-- A tile's texture number can change when the game resets its textures, so DFHack says to ask
-- for it rather than keep it. Asking is a call into the game, though, and a busy beach asks
-- for the same few hundred tiles thousands of times a second. So the answers are kept until
-- the next scan, at most RESCAN_MS: after a reset, the waves are wrong for that long at worst.
local texpos_known = {}

local function forget_texposes()
    texpos_known = {}
end

local function texture(tiles, index)
    local known = texpos_known[tiles]
    if not known then
        known = {}
        texpos_known[tiles] = known
    end
    local texpos = known[index]
    if not texpos then
        texpos = dfhack.textures.getTexposByHandle(tiles[index])
        known[index] = texpos
    end
    return texpos
end

-- Each sheet holds rows of 16 frames, and the functions below give the tile number of a row's
-- first frame. A tile shows frame (step + frame_shift) % FRAMES of its row.

-- Wash sheet layout: for each (touches the sea?, sides where the water carries on, flow
-- direction) a row. Rows touching the sea are opaque on the sea side.
local function wash_row(touches_sea, wet_sides, direction_index)
    local row = ((touches_sea and 1 or 0) * 16 + wet_sides) * #FLOW_DIRECTIONS + (direction_index - 1)
    return row * FRAMES + 1
end

-- Fringe sheet layout (rock and sea alike): for each combination of sides and corners that face
-- the wash, a row.
local function fringe_row(sides_facing_water)
    return sides_facing_water * FRAMES + 1
end

-- Foam sheet layout: for each (stage, sides joined to more foam or a wave, variant) a row. The
-- foam lies still; the frames only add a little static.
local function foam_row(stage, joined_sides, x, y)
    local variant = (x * 7 + y * 13) % FOAM_VARIANTS
    local row = (stage * 16 + joined_sides) * FOAM_VARIANTS + variant
    return row * FRAMES + 1
end

-- Swell sheet layout: for each (heading, whiteness) a row.
local SWELL_HEADINGS = {north = 0, south = 1, east = 2, west = 3}
local function swell_row(heading, whiteness)
    return (SWELL_HEADINGS[heading] * SWELL_WHITENESS + whiteness) * FRAMES + 1
end

----------------------------------------------------------------------------------------------
-- Terrain
----------------------------------------------------------------------------------------------

-- Ground the wash thins out on, with foam at its edge. Rock and the sea don't stop the water.
local BEACH_MATERIALS = {
    [df.tiletype_material.SOIL] = true, [df.tiletype_material.DRIFTWOOD] = true,
    [df.tiletype_material.GRASS_LIGHT] = true, [df.tiletype_material.GRASS_DARK] = true,
    [df.tiletype_material.GRASS_DRY] = true, [df.tiletype_material.GRASS_DEAD] = true,
}

local function is_water(flags)
    return flags and flags.flow_size > 0 and not flags.liquid_type
end

local function classify(tiletype, x, y, z)
    if not tiletype then return 'other' end
    local attrs = df.tiletype.attrs[tiletype]
    local shape, material = attrs.shape, attrs.material
    -- The sea is water on this level, or open space with water just below it. That includes
    -- the tops of ramps sloping down into the sea, which vanilla draws as sand at the waterline.
    if is_water(dfhack.maps.getTileFlags(x, y, z)) then return 'sea' end
    if (shape == df.tiletype_shape.EMPTY or shape == df.tiletype_shape.RAMP_TOP)
            and is_water(dfhack.maps.getTileFlags(x, y, z - 1)) then
        return 'sea'
    end
    if shape == df.tiletype_shape.BOULDER then return 'boulder' end
    if shape == df.tiletype_shape.FLOOR and BEACH_MATERIALS[material] then return 'dry_beach' end
    -- shrubs and saplings count as beach: they get the rim beside the water like the sand around them
    if shape == df.tiletype_shape.SHRUB or shape == df.tiletype_shape.SAPLING then return 'dry_beach' end
    if (shape == df.tiletype_shape.FLOOR or shape == df.tiletype_shape.PEBBLES)
            and not BEACH_MATERIALS[material] then
        return 'rock'
    end
    return 'other'
end

local function is_driftwood(x, y, z)
    local tiletype = dfhack.maps.getTileType(x, y, z)
    return tiletype and df.tiletype.attrs[tiletype].material == df.tiletype_material.DRIFTWOOD
end

-- Shrubs and saplings: like driftwood, the game draws them above the first floor layer.
local function is_plant(x, y, z)
    local tiletype = dfhack.maps.getTileType(x, y, z)
    local shape = tiletype and df.tiletype.attrs[tiletype].shape
    return shape == df.tiletype_shape.SHRUB or shape == df.tiletype_shape.SAPLING
end

local function tile_key(x, y, z)
    return x + y * 4096 + z * 16777216
end

-- Classifying a tile takes a few lookups, so the answer is kept with the tile's type. The type
-- is checked again once per round of TERRAIN_RECHECK_MS (digging, building and channelling
-- change it, but not often), and if it has changed the tile is classified again. A change can also move the shoreline, so it clears the
-- shore directions worked out from that tile.
terrain_cache = terrain_cache or {}
shore_cache = shore_cache or {}
scan_number = scan_number or 0
terrain_round = terrain_round or 0

local function forget_shores_near(x, y, z)
    for dy = -SHORE_RADIUS, SHORE_RADIUS do
        for dx = -SHORE_RADIUS, SHORE_RADIUS do
            shore_cache[tile_key(x + dx, y + dy, z)] = nil
        end
    end
end

local function terrain_at(x, y, z)
    local key = tile_key(x, y, z)
    local known = terrain_cache[key]
    if known and known.checked == terrain_round then return known.kind end
    -- Classified afresh every round, not only when the tile type changes: whether a tile is sea
    -- depends on the water in it or just below it, which comes and goes without the type changing.
    local tiletype = dfhack.maps.getTileType(x, y, z)
    local kind = classify(tiletype, x, y, z)
    if known then
        if known.kind ~= kind or known.tiletype ~= tiletype then forget_shores_near(x, y, z) end
        known.tiletype, known.kind, known.checked = tiletype, kind, terrain_round
    else
        terrain_cache[key] = {tiletype = tiletype, kind = kind, checked = terrain_round}
    end
    return kind
end

-- Which way a shore faces, from the sea within SHORE_RADIUS (nearer sea counts for more):
--   flow:   index into FLOW_DIRECTIONS of the direction pointing away from the sea
--   crests: 'up' if the sea lies mostly north or south, 'side' if east or west
local function shore_facing(x, y, z)
    local key = tile_key(x, y, z)
    if shore_cache[key] then return shore_cache[key] end

    local toward_sea_x, toward_sea_y = 0, 0
    for dy = -SHORE_RADIUS, SHORE_RADIUS do
        for dx = -SHORE_RADIUS, SHORE_RADIUS do
            if (dx ~= 0 or dy ~= 0) and terrain_at(x + dx, y + dy, z) == 'sea' then
                local distance_squared = dx * dx + dy * dy
                toward_sea_x = toward_sea_x + dx / distance_squared
                toward_sea_y = toward_sea_y + dy / distance_squared
            end
        end
    end

    local best, best_score = 5, -math.huge
    for index, dir in ipairs(FLOW_DIRECTIONS) do
        local away_from_sea = -(dir.dx * toward_sea_x + dir.dy * toward_sea_y)
        local score = away_from_sea / math.sqrt(dir.dx * dir.dx + dir.dy * dir.dy)
        if score > best_score then best, best_score = index, score end
    end

    local facing = {
        flow = best,
        crests = math.abs(toward_sea_y) >= math.abs(toward_sea_x) and 'up' or 'side',
    }
    shore_cache[key] = facing
    return facing
end

----------------------------------------------------------------------------------------------
-- Finding waves
----------------------------------------------------------------------------------------------

-- Foam is born at density 47-95 and the game lowers it by 3 every hundred ticks or so. Its stage
-- is how far it has fallen from the density it was first seen at, so weak foam starts fresh too.
-- Foam that's gone is forgotten after a while.
foam_born = foam_born or {}
local function foam_stage(x, y, z, density)
    local key = tile_key(x, y, z)
    local born = foam_born[key]
    if not born or density > born.density then
        born = {density = density}
        foam_born[key] = born
    end
    born.seen = df.global.cur_year_tick
    local stage = math.floor(density / born.density * FOAM_STAGES)
    return math.max(0, math.min(stage, FOAM_STAGES - 1))
end

local function forget_old_foam()
    local now = df.global.cur_year_tick
    for key, born in pairs(foam_born) do
        if now - born.seen > 1000 or now < born.seen then foam_born[key] = nil end
    end
end

-- Wave and foam flows on level z inside the rectangle. Reads only the map blocks in view. Each
-- field read from a flow is a call into the game, so each is read once.
local function find_waves(x1, y1, x2, y2, z)
    local waves, foam, spray = {}, {}, {}
    local OceanWave, SeaFoam, Steam = df.flow_type.OceanWave, df.flow_type.SeaFoam, df.flow_type.Steam
    for block_y = y1 - y1 % 16, y2, 16 do
        for block_x = x1 - x1 % 16, x2, 16 do
            local block = dfhack.maps.getTileBlock(block_x, block_y, z)
            for _, flow in ipairs(block and block.flows or {}) do
                local density = flow.density
                local flow_type = density > 0 and flow.type
                if flow_type == OceanWave or flow_type == SeaFoam or flow_type == Steam then
                    local pos = flow.pos
                    local x, y = pos.x, pos.y
                    if pos.z == z then
                        if flow_type == OceanWave and density >= WAVE_FOAM_BELOW then
                            waves[#waves + 1] = {x = x, y = y}
                        elseif flow_type == OceanWave then
                            -- the wave's last thin water, broken up into foam
                            foam[#foam + 1] = {x = x, y = y, stage = density * FOAM_STAGES // WAVE_FOAM_BELOW}
                        elseif flow_type == SeaFoam then
                            foam[#foam + 1] = {x = x, y = y, stage = foam_stage(x, y, z, density)}
                        else
                            local stage = math.min(density * FOAM_STAGES // SPRAY_FULL, FOAM_STAGES - 1)
                            spray[#spray + 1] = {x = x, y = y, stage = stage}
                        end
                    end
                end
            end
        end
    end
    return waves, foam, spray
end

local function sign(n)
    return n > 0 and 1 or n < 0 and -1 or 0
end

-- The incoming crests on level z inside the rectangle: where each is, which way it's heading
-- (diagonals go by their north/south part), and how white it is, from how close it is to
-- breaking on the beach.
local function find_crests(x1, y1, x2, y2, z)
    local crests = {}
    for _, wave in ipairs(df.global.world.event.ocean_waves) do
        if wave.z == z then
            local cur, dest = wave.cur, wave.dest
            local x, y = cur.x, cur.y
            if x >= x1 and x <= x2 and y >= y1 and y <= y2 then
                local dest_x, dest_y = dest.x, dest.y
                local dx, dy = sign(dest_x - x), sign(dest_y - y)
                local heading = dy < 0 and 'north' or dy > 0 and 'south' or dx > 0 and 'east' or 'west'
                local tiles_to_go = math.max(math.abs(dest_x - x), math.abs(dest_y - y))
                crests[#crests + 1] = {
                    x = x, y = y,
                    heading = heading,
                    whiteness = tiles_to_go <= 1 and 3 or tiles_to_go <= 2 and 2 or tiles_to_go <= 4 and 1 or 0,
                }
            end
        end
    end
    return crests
end

----------------------------------------------------------------------------------------------
-- Planning what to draw
----------------------------------------------------------------------------------------------

-- A piece is one tile of art at one map tile, ready to animate:
--   x, y         the map tile
--   sheet        the sheet's key in `sheets`
--   first_tile   the tile number of frame 0 of its row
--   frame_shift  added to the animation step, so neighbours aren't in step
--   layer        'floor'     the map's second floor layer, under dwarves and items, or on top
--                            if that's taken
--                'top'       on top of the map
--                'under'     the map's first floor layer (under a boulder)
--   clears_floor_flag  also blank the map's floor_flag layer here (the sand edge on the sea)
local function piece(x, y, sheet, first_tile, frame_shift, layer)
    return {x = x, y = y, sheet = sheet, first_tile = first_tile, frame_shift = frame_shift, layer = layer}
end

-- Land beside the open sea (rock, sand, soil, grass): the same rim as rock beside the wash. The sea tiles come from the caustics'
-- own scan of the view (water_map), so this is worked out again only when that list or the terrain
-- changes. Returns a list of {x, y, mask}: the sides and corners of the rock tile that face the sea.
sea_rocks = sea_rocks or {}
-- Land that gets the rim: rock, sand, soil and grass floors, pebbles and boulders.
local SHORE_KINDS = {rock = true, dry_beach = true, boulder = true}
local function rocks_by_the_sea(z)
    local water = state.cache
    if not water or state.z ~= z then return {} end
    -- for a still view once per terrain round (a second), not at every water rescan
    if sea_rocks.view == state.key and sea_rocks.round == terrain_round then return sea_rocks.list, sea_rocks.sea end
    local list, seen, sea, land = {}, {}, {}, {}
    for i = 1, #water do
        local tile = water[i]
        -- (the caustics also light water seen through open space further down; that is not a shore)
        if tile[3] == 'sea' and terrain_at(tile[1], tile[2], z) == 'sea' then
            local touches_land = false
            for _, dir in ipairs(SIDES_AND_CORNERS) do
                local rx, ry = tile[1] - dir.dx, tile[2] - dir.dy
                local key = tile_key(rx, ry, 0)
                if land[key] then touches_land = true end
                if not seen[key] and SHORE_KINDS[terrain_at(rx, ry, z)] then
                    seen[key] = true
                    -- natural ground only: not built floors beside a salt-water moat
                    local tiletype = dfhack.maps.getTileType(rx, ry, z)
                    if tiletype and df.tiletype.attrs[tiletype].material ~= df.tiletype_material.CONSTRUCTION then
                        -- The mask comes from the terrain, not from the water list: that list stops at
                        -- the view's edge and leaves out tiles with a creature in them.
                        local mask = 0
                        for _, side in ipairs(SIDES_AND_CORNERS) do
                            if terrain_at(rx + side.dx, ry + side.dy, z) == 'sea' then mask = mask + side.bit end
                        end
                        list[#list + 1] = {x = rx, y = ry, mask = mask}
                        land[key] = true
                        touches_land = true
                    end
                end
            end
            -- the game draws the frayed edge of sand on the sea tile beside it; with the rim that
            -- edge would hang in the water, so it is switched off there
            if touches_land then sea[#sea + 1] = {x = tile[1], y = tile[2]} end
        end
    end
    sea_rocks = {view = state.key, round = terrain_round, list = list, sea = sea}
    return list, sea
end

-- Plans the river style, in drawing order:
--   wash         on each wave: wet_sides (sides where the water carries on: another wave, rock
--                or the sea; the other sides get foam) and touches_sea
--   foam         on each foam patch, joined to neighbouring foam and waves
--   fringes      rock and sea tiles beside the wash, with the sides and corners that face it
--   boulders     boulders in or beside the wash
--   whitecaps    the spray that's over a wave or the sea, last so it covers the rest
local ALL_SIDES_WET = 0
for _, side in ipairs(SIDES) do ALL_SIDES_WET = ALL_SIDES_WET | side.bit end

local function plan_river(waves, foam, spray, z)
    local pieces = {}

    local wave_at = {}
    for _, wave in ipairs(waves) do wave_at[tile_key(wave.x, wave.y, 0)] = true end
    local function has_wave(x, y) return wave_at[tile_key(x, y, 0)] end

    -- The wash. A boulder keeps its own tile; the water goes under it below.
    for _, wave in ipairs(waves) do
        local x, y = wave.x, wave.y
        if terrain_at(x, y, z) ~= 'boulder' then
            local wet_sides, touches_sea = 0, false
            for _, side in ipairs(SIDES) do
                local nx, ny = x + side.dx, y + side.dy
                local kind = terrain_at(nx, ny, z)
                -- Every side is drawn as open water: the foam edge is not drawn inside the wash tile
                -- (the mod's way, against sand) but as the rim on the dry tile beside it, the same
                -- rim as along the sea, so the foam line runs on unbroken.
                wet_sides = add_bit(wet_sides, side.bit)
                if kind == 'sea' then touches_sea = true end
            end
            local facing = shore_facing(x, y, z).flow
            local dir = FLOW_DIRECTIONS[facing]
            -- Like vanilla river tiles, each tile runs a frame behind the one upstream of it, so
            -- the caustics travel away from the sea.
            -- Driftwood: the game draws the log on the second floor layer, where the wash would go, and
            -- on top of the map the wash came out see-through, so the sand under the log looked dry.
            -- There the wash takes the place of the sand, on the first floor layer, under the log.
            pieces[#pieces + 1] = piece(x, y, 'wash', wash_row(touches_sea, wet_sides, facing),
                -(x * dir.dx + y * dir.dy), (is_driftwood(x, y, z) or is_plant(x, y, z)) and 'under' or 'floor')
        end
    end

    -- A foam patch runs into neighbouring foam and waves; towards bare ground it frays out.
    -- Foam is what the water leaves behind: none on a tile a wave is covering, none on the sea.
    local left_behind = {}
    for _, patch in ipairs(foam) do
        if not has_wave(patch.x, patch.y) and terrain_at(patch.x, patch.y, z) ~= 'sea' then
            left_behind[#left_behind + 1] = patch
        end
    end
    foam = left_behind
    local foam_at = {}
    for _, patch in ipairs(foam) do foam_at[tile_key(patch.x, patch.y, 0)] = true end
    for _, patch in ipairs(foam) do
        local x, y = patch.x, patch.y
        local joined_sides = 0
        for _, side in ipairs(SIDES) do
            local nx, ny = x + side.dx, y + side.dy
            if has_wave(nx, ny) or foam_at[tile_key(nx, ny, 0)] then
                joined_sides = add_bit(joined_sides, side.bit)
            end
        end
        -- out of step with its neighbours, so the static doesn't pulse across a patch
        pieces[#pieces + 1] = piece(x, y, 'sea_foam', foam_row(patch.stage, joined_sides, x, y),
            x * 3 + y * 5, 'floor')
    end

    -- Rock and sea around the waves, and boulders on or beside them.
    local fringe_list, fringe_at = {}, {}
    local boulder_list, boulder_at = {}, {}
    for _, wave in ipairs(waves) do
        local x, y = wave.x, wave.y

        for _, offset in ipairs(HERE_AND_SIDES) do
            local bx, by = x + offset.dx, y + offset.dy
            local key = tile_key(bx, by, 0)
            if not boulder_at[key] and terrain_at(bx, by, z) == 'boulder' then
                boulder_at[key] = true
                boulder_list[#boulder_list + 1] = {x = bx, y = by}
            end
        end

        -- Seen from the fringe tile, the wave lies in direction `dir`.
        for _, dir in ipairs(SIDES_AND_CORNERS) do
            local fx, fy = x - dir.dx, y - dir.dy
            if not has_wave(fx, fy) then
                local kind = terrain_at(fx, fy, z)
                if kind == 'rock' or kind == 'dry_beach' or kind == 'sea' then
                    local key = tile_key(fx, fy, 0)
                    local fringe = fringe_at[key]
                    if not fringe then
                        fringe = {x = fx, y = fy, sides_facing_water = 0, is_sea = kind == 'sea'}
                        fringe_at[key] = fringe
                        fringe_list[#fringe_list + 1] = fringe
                    end
                    fringe.sides_facing_water = add_bit(fringe.sides_facing_water, dir.bit)
                end
            end
        end
    end
    -- A boulder on or beside a wave gets water under it (below), so to the land next to it that
    -- boulder is water too: the rim also runs along the side facing the boulder.
    for _, boulder in ipairs(boulder_list) do
        for _, dir in ipairs(SIDES_AND_CORNERS) do
            local fx, fy = boulder.x - dir.dx, boulder.y - dir.dy
            if not has_wave(fx, fy) then
                local kind = terrain_at(fx, fy, z)
                if kind == 'rock' or kind == 'dry_beach' then
                    local key = tile_key(fx, fy, 0)
                    local fringe = fringe_at[key]
                    if not fringe then
                        fringe = {x = fx, y = fy, sides_facing_water = 0, is_sea = false}
                        fringe_at[key] = fringe
                        fringe_list[#fringe_list + 1] = fringe
                    end
                    fringe.sides_facing_water = add_bit(fringe.sides_facing_water, dir.bit)
                end
            end
        end
    end
    local shore, shore_sea = rocks_by_the_sea(z)
    for _, tile in ipairs(shore_sea or {}) do
        if not fringe_at[tile_key(tile.x, tile.y, 0)] then
            pieces[#pieces + 1] = piece(tile.x, tile.y, 'sea_foam', 1, 0, 'no_edge')
        end
    end
    for _, rock in ipairs(shore) do
        if not has_wave(rock.x, rock.y) then
            local key = tile_key(rock.x, rock.y, 0)
            local fringe = fringe_at[key]
            if not fringe then
                fringe = {x = rock.x, y = rock.y, sides_facing_water = 0, is_sea = false}
                fringe_at[key] = fringe
                fringe_list[#fringe_list + 1] = fringe
            end
            -- (a mask of bits, so OR-ing in sides a wave already set is harmless)
            fringe.sides_facing_water = fringe.sides_facing_water | rock.mask
        end
    end
    for _, fringe in ipairs(fringe_list) do
        local fringe_piece = piece(fringe.x, fringe.y, fringe.is_sea and 'sea_fringe' or 'rock_fringe',
            fringe_row(fringe.sides_facing_water), 0, fringe.is_sea and 'floor' or 'top')
        -- floor_flag draws the sand's edge on the sea; the sea fringe replaces it
        fringe_piece.clears_floor_flag = fringe.is_sea
        pieces[#pieces + 1] = fringe_piece
    end
    for _, boulder in ipairs(boulder_list) do
        -- The boulder is drawn on the second floor layer, over this one. Under it goes the same
        -- wash as on the tiles around it (same colour, same moving pattern), not a flat square.
        local x, y = boulder.x, boulder.y
        local touches_sea = false
        for _, side in ipairs(SIDES) do
            if terrain_at(x + side.dx, y + side.dy, z) == 'sea' then touches_sea = true end
        end
        local facing = shore_facing(x, y, z).flow
        local dir = FLOW_DIRECTIONS[facing]
        pieces[#pieces + 1] = piece(x, y, 'wash', wash_row(touches_sea, ALL_SIDES_WET, facing),
            -(x * dir.dx + y * dir.dy), 'under')
    end

    -- Spray shows as whitecaps only on the water: over a wave or the sea. Whitecaps join up
    -- with each other.
    local whitecaps, whitecap_at = {}, {}
    for _, patch in ipairs(spray) do
        if has_wave(patch.x, patch.y) or terrain_at(patch.x, patch.y, z) == 'sea' then
            whitecaps[#whitecaps + 1] = patch
            whitecap_at[tile_key(patch.x, patch.y, 0)] = true
        end
    end
    for _, patch in ipairs(whitecaps) do
        local x, y = patch.x, patch.y
        local joined_sides = 0
        for _, side in ipairs(SIDES) do
            if whitecap_at[tile_key(x + side.dx, y + side.dy, 0)] then
                joined_sides = add_bit(joined_sides, side.bit)
            end
        end
        -- never the solid patches of fresh beach foam: on the water those read as foam left on sand
        pieces[#pieces + 1] = piece(x, y, 'sea_foam',
            foam_row(math.min(patch.stage, WHITECAP_MAX_STAGE), joined_sides, x, y), x * 3 + y * 5, 'top')
    end

    return pieces
end

-- Plans the older crest styles: a crest sheet on each wave tile.
local function plan_crests(waves, z)
    local pieces = {}
    for _, wave in ipairs(waves) do
        local which = style == 'auto' and shore_facing(wave.x, wave.y, z).crests or style
        -- offset by position so neighbouring tiles aren't in step
        pieces[#pieces + 1] = piece(wave.x, wave.y, which == 'up' and 'up_crests' or 'side_crests',
            1, wave.x + wave.y, 'top')
    end
    return pieces
end

----------------------------------------------------------------------------------------------
-- Timing (`caustics timing`)
----------------------------------------------------------------------------------------------

-- Time spent in each part since timing was last shown, and how many times it ran. DFHack's
-- only clock counts whole milliseconds, coarser than one frame, but a part that takes 0.3 ms
-- straddles a tick about 3 times in 10, so over hundreds of runs the average comes out right.
timing = timing or {}
timing_since = timing_since or dfhack.getTickCount()

local function timed_since(part, started_ms)
    local entry = timing[part]
    if not entry then
        entry = {ms = 0, runs = 0}
        timing[part] = entry
    end
    entry.ms = entry.ms + (dfhack.getTickCount() - started_ms)
    entry.runs = entry.runs + 1
end

----------------------------------------------------------------------------------------------
-- The overlay
----------------------------------------------------------------------------------------------

-- One pen for every tile: the texture is passed alongside it, so no pen is made per tile.
local TILE_PEN = dfhack.pen.parse{ch = ' ', fg = COLOR_GREY}

-- (a plain object here: the caustics overlay below calls its onRenderFrame)
WavesOverlay = defclass(WavesOverlay)

function WavesOverlay:init()
    self.pieces = {}
    self.next_scan = 0
    self.next_foam_cleanup = 0
    self.next_terrain_round = 0
    self.draw_list, self.draw_list_key = {}, nil
    self.crest_list, self.crest_list_key = {}, nil
end

function WavesOverlay:rescan(viewport)
    local started = dfhack.getTickCount()
    scan_number = scan_number + 1
    forget_texposes()
    local z = viewport.z
    local waves, foam, spray = find_waves(viewport.x1, viewport.y1, viewport.x2, viewport.y2, z)
    local now = dfhack.getTickCount()
    timed_since('  finding flows', started)
    if now >= self.next_terrain_round then
        terrain_round = terrain_round + 1
        self.next_terrain_round = now + TERRAIN_RECHECK_MS
    end
    if now >= self.next_foam_cleanup then
        forget_old_foam()
        self.next_foam_cleanup = now + FORGET_FOAM_MS
    end
    local planning = dfhack.getTickCount()
    if style == 'river' then
        self.pieces = plan_river(waves, foam, spray, z)
    else
        self.pieces = plan_crests(waves, z)
    end
    self.draw_list_key = nil
    timed_since('  planning', planning)
    timed_since('scan and plan', started)
end

-- Turns the pieces into what to write for this step and view: for each piece in view, its
-- screen position, its index into the map's screen layers, and its texture.
function WavesOverlay:buildDrawList(viewport, port, step)
    local list = {}
    local x1, y1, x2, y2 = viewport.x1, viewport.y1, viewport.x2, viewport.y2
    local dim_y, layer_size = port.dim_y, port.dim_x * port.dim_y
    for _, p in ipairs(self.pieces) do
        local x, y = p.x, p.y
        if x >= x1 and x <= x2 and y >= y1 and y <= y2 then
            local sx, sy = x - x1, y - y1
            local index = sx * dim_y + sy
            if index < 0 or index >= layer_size then index = nil end
            local frame = (step + p.frame_shift) % FRAMES
            list[#list + 1] = {
                sx = sx, sy = sy, index = index, layer = p.layer,
                clears_floor_flag = p.clears_floor_flag,
                texpos = texture(sheets[p.sheet], p.first_tile + frame),
            }
        end
    end
    return list
end

-- Writes the draw list. The map's screen layers are rebuilt by the game every frame and drawn
-- after overlays render, so anything written to them lasts exactly one frame and has to be
-- written again each frame.
local function draw(list, port, screen_x, screen_y)
    local floor_two = port.screentexpos_background_two
    local floor_one = port.screentexpos_background
    local floor_flag = port.screentexpos_floor_flag
    local paint = dfhack.screen.paintTile
    for i = 1, #list do
        local item = list[i]
        local index, layer = item.index, item.layer
        if layer == 'no_edge' then
            if index then floor_flag[index] = 0 end
        elseif layer == 'under' then
            if index then floor_one[index] = item.texpos end
        elseif layer == 'floor' and index and floor_two[index] == 0 then
            -- under dwarves, items and driftwood
            floor_two[index] = item.texpos
            if item.clears_floor_flag then floor_flag[index] = 0 end
        else
            paint(TILE_PEN, screen_x + item.sx, screen_y + item.sy, ' ', item.texpos, true)
            if item.clears_floor_flag and index then floor_flag[index] = 0 end
        end
    end
end

-- Crests move every few ticks, so their draw list is made again whenever the game ticks (or
-- the view moves). Finding them means reading every incoming wave on the map, which on a big
-- sea is a hundred or more, so it isn't done more often than that: when the game ticks slower
-- than the screen redraws, or is paused, the last list is drawn again.
local function crest_draw_list(viewport, step)
    local list = {}
    local x1, y1 = viewport.x1, viewport.y1
    for _, crest in ipairs(find_crests(x1, y1, viewport.x2, viewport.y2, viewport.z)) do
        local frame = (step + crest.x + crest.y) % FRAMES
        list[#list + 1] = {
            sx = crest.x - x1, sy = crest.y - y1,
            texpos = texture(sheets.swell, swell_row(crest.heading, crest.whiteness) + frame),
        }
    end
    return list
end

local function draw_crests(list, screen_x, screen_y)
    local paint = dfhack.screen.paintTile
    for i = 1, #list do
        local crest = list[i]
        paint(TILE_PEN, screen_x + crest.sx, screen_y + crest.sy, ' ', crest.texpos, true)
    end
end

function WavesOverlay:onRenderFrame(dc)
    if not dfhack.screen.inGraphicsMode() or not dfhack.isMapLoaded() then return end
    local started = dfhack.getTickCount()
    local viewport = guidm.Viewport.get()

    -- (also reloads if this script gained a sheet since they were loaded)
    if not (sheets and sheets.swell) then
        sheets = load_sheets()
        forget_texposes()
    end

    local now = dfhack.getTickCount()
    if now >= self.next_scan then
        self:rescan(viewport)
        self.next_scan = now + RESCAN_MS
    end
    local any_crests = style == 'river' and #df.global.world.event.ocean_waves > 0
    if #self.pieces == 0 and not any_crests then return end

    -- animations run on game time, so they stop when the game is paused; but adventure mode's time
    -- only moves as the adventurer acts, so there they run on real time, at normal speed's pace
    -- (the waves themselves are the game's, and still move only as it runs)
    local step = dfhack.world.isAdventureMode() and now // (TICKS_PER_FRAME * MS_PER_TICK)
        or df.global.cur_year_tick // TICKS_PER_FRAME
    local port = df.global.gps.main_viewport
    local key = ('%d,%d,%d,%d,%d,%d,%d'):format(step, viewport.x1, viewport.y1, viewport.z,
        port.dim_x, port.dim_y, scan_number)
    if key ~= self.draw_list_key then
        self.draw_list = self:buildDrawList(viewport, port, step)
        self.draw_list_key = key
    end

    -- the same screen origin the painter would use for map tiles
    local screen_x, screen_y = dc.x1, dc.y1
    if any_crests then
        local tick = df.global.cur_year_tick
        local crest_key = ('%d,%d,%d,%d,%d,%d,%d'):format(tick, viewport.x1, viewport.y1, viewport.x2,
            viewport.y2, viewport.z, scan_number)
        if crest_key ~= self.crest_list_key then
            self.crest_list = crest_draw_list(viewport, step)
            self.crest_list_key = crest_key
        end
        draw_crests(self.crest_list, screen_x, screen_y)
    end
    draw(self.draw_list, port, screen_x, screen_y)
    timed_since('frame', started)
end

wave_painter = WavesOverlay{}
end

CausticsOverlay = defclass(CausticsOverlay, overlay.OverlayWidget)
CausticsOverlay.ATTRS{
    desc='Caustics on water, and the ocean waves and sea foam that graphics mode leaves out.',
    viewscreens='dwarfmode',
    default_enabled=true,
    fullscreen=true,
}

-- the overlay framework calls this unconditionally for some widget configs
function CausticsOverlay:overlay_onupdate() end

function CausticsOverlay:onRenderFrame(dc)
    if not dfhack.isMapLoaded() then return end
    if WAVES then wave_painter:onRenderFrame(dc) end
    local t_start = os.clock()
    local vp = guidm.Viewport.get()
    local list = water_map(vp)
    if #list == 0 then return end
    -- animation clock: real time, minus the time spent paused
    local real = dfhack.getTickCount()
    local paused = PAUSE_FREEZE and df.global.pause_state
    if state.real and not paused then
        local d = real - state.real
        if d > 0 and d < 1000 then state.clock = state.clock + d end   -- a long gap (load, hang) does not jump the water
    end
    state.real = real
    local now = state.clock
    local t_flow = math.floor(now / river_step_ms()) % STEPS
    local step_still = math.floor(now / STILL_MS)
    local t_still = step_still % STEPS
    local rings = state.rings
    local ring_by_pos, ring_life = rings and rings.by_pos, rings and rings.life
    local nrings = 0
    local getTexpos, paint = dfhack.textures.getTexposByHandle, dfhack.screen.paintTile
    local mvp = df.global.gps.main_viewport
    local under, dim_y, under_n = UNDER_LAYER and mvp[UNDER_LAYER], mvp.dim_y, mvp.dim_x * mvp.dim_y
    local texpos = {}  -- per direction, this frame's 16 tile textures
    local pen = {ch=0, fg=COLOR_WHITE}
    local x1, y1, x2, y2 = vp.x1, vp.y1, vp.x2, vp.y2
    local budget = BAKE_PER_FRAME
    for i = 1, #list do
        local p = list[i]
        local key = p[3]
        -- the sea: still-water pattern, no rings
        if key == 'sea' and not SEA_COLS then key = 'none' end
        local tp = texpos[key]
        if tp == nil then
            local set = state.sets[key]
            if not set and budget > 0 then
                budget = bake_some(key, budget)
                set = state.sets[key]
            end
            tp = false  -- not baked yet: leave these tiles plain for now
            if set then
                tp = {}
                local still_pace = key == 'none' or key == 'wash' or key == 'sea'
                local frame = set[(still_pace and t_still or t_flow) + 1]
                for k = 1, 16 do tp[k] = getTexpos(frame[k]) end
            end
            texpos[key] = tp
        end
        local x, y = p[1], p[2]
        if tp and x >= x1 and x <= x2 and y >= y1 and y <= y2 then
            local k = (y % 4) * 4 + (x % 4) + 1
            local tex = tp[k]
            local evs = ring_by_pos and p[3] == 'none' and ring_by_pos[k]
            if evs then
                for j = 1, #evs do
                    local e = evs[j]
                    local age = (step_still - e.start) % STEPS
                    if age < ring_life then
                        -- one decision per tile per occurrence (step_still - age is its birth step)
                        local h = (x * 73856093 ~ y * 19349663 ~ (step_still - age) * 83492791) & 0xffffffff
                        h = ((h ~ (h >> 15)) * 0x2c1b3c6d) & 0xffffffff
                        h = ((h ~ (h >> 12)) * 0x297a2d39) & 0xffffffff
                        h = h ~ (h >> 15)
                        if h % 1000 < RING_CHANCE then
                            tex = getTexpos(e.tiles[age + 1]); nrings = nrings + 1
                            break
                        end
                    end
                end
            end
            -- on the lower layer other overlays' pictures (waves, foam) show on top of the caustics
            local at = (x - x1) * dim_y + y - y1
            if under and at >= 0 and at < under_n then under[at] = tex
            else paint(pen, x - x1, y - y1, nil, tex, true) end
        end
    end
    -- ring textures are baked one event per frame, after the still frames are ready
    if budget == BAKE_PER_FRAME and state.sets.none and not (rings and rings.done) then bake_ring() end
    local s = state.stats
    local us = (os.clock() - t_start) * 1e6
    s.n = s.n + 1; s.us = s.us + us; s.tiles = #list; s.rings = (s.rings or 0) + nrings
    if us > (s.max or 0) then s.max = us end
end

OVERLAY_WIDGETS = {overlay=CausticsOverlay}

if dfhack_flags.module then return end
local cmd = ...
if cmd == 'stats' then
    local s = state.stats
    local dirs = {}
    for _, p in ipairs(state.cache or {}) do dirs[p[3]] = (dirs[p[3]] or 0) + 1 end
    local parts = {}
    for k, v in pairs(dirs) do parts[#parts + 1] = k .. '=' .. v end
    print(('river flow %s -> step %s ms (still water %d ms)'):format(tostring(state.flow), tostring(state.step_ms), STILL_MS))
    print(('frames %d, avg %.0f us/frame, max %.1f ms, water tiles %d, drift %s'):format(
        s.n, s.n > 0 and s.us / s.n or 0, (s.max or 0) / 1000, s.tiles or -1, table.concat(parts, ' ')))
    local r = state.rings
    print(('rings: %s, tile-frames with a ring since last stats %d'):format(
        r and (r.by_pos and 'ready' or r.done and 'no ring file' or 'baking ' .. tostring(r.n)) or 'not started', s.rings or 0))
    s.n, s.us, s.max, s.rings = 0, 0, 0, 0
end

-- The overlay runs from the module copy of this script, so change settings there.
local module = reqscript('caustics')
if cmd == 'river' or cmd == 'auto' or cmd == 'side' or cmd == 'up' then
    module.style = cmd
elseif cmd == 'reload' then
    module.reload_count = module.reload_count + 1
    module.sheets = nil
elseif cmd == 'timing' then
    local seconds = math.max(1, dfhack.getTickCount() - module.timing_since) / 1000
    print(('caustics waves: over the last %.1f s'):format(seconds))
    for part, entry in pairs(module.timing) do
        print(('  %-14s %6d runs  %7.3f ms each  %6.1f ms a second'):format(
            part, entry.runs, entry.ms / math.max(1, entry.runs), entry.ms / seconds))
    end
    module.timing = {}
    module.timing_since = dfhack.getTickCount()
    return
elseif cmd ~= 'waves' then
    return
end

local wave_count = 0
if dfhack.isMapLoaded() then
    for _, block in ipairs(df.global.world.map.map_blocks) do
        for _, flow in ipairs(block.flows) do
            if WAVE_FLOWS[flow.type] then wave_count = wave_count + 1 end
        end
    end
end
print(('caustics waves: style %s; %d wave and foam flows on the map'):format(module.style, wave_count))
