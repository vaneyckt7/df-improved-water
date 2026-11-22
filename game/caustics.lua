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
local function build_still_frame(data, o, ox, oy)
    ox, oy = ox or 0, oy or 0
    local pix, base, col = {}, o * N * N, {[0] = 0, STILL_FAINT, HI, GLINT, STILL_VFAINT, STILL_CROSS, STILL_SHADOW, RING_COLS[1], RING_COLS[2], RING_COLS[3], RING_COLS[4], RING_COLS[5], RING_COLS[6]}
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
        if data then return build_still_frame(data, o) end
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
    state.cache, state.key, state.cache_at, state.z = list, key, now, z0
    return list
end

CausticsOverlay = defclass(CausticsOverlay, overlay.OverlayWidget)
CausticsOverlay.ATTRS{
    desc='Sliding Voronoi caustics on water tiles (prototype).',
    viewscreens='dwarfmode',
    default_enabled=true,
    fullscreen=true,
}

-- the overlay framework calls this unconditionally for some widget configs
function CausticsOverlay:overlay_onupdate() end

function CausticsOverlay:onRenderFrame()
    if not dfhack.isMapLoaded() then return end
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
        if key == 'sea' then key = 'none' end
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
                local still_pace = key == 'none'
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
