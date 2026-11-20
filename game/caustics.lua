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
-- The sea has no flow direction, but the game simulates waves crossing it toward the beaches. With SEA_SWELL
-- on, sea water (salt, not flowing) shows foam crests (caustics_swell.bin, made by tools/wavegif.py)
-- instead of caustics. false = the sea looks like a pond.
SEA_SWELL = true
-- The crests are drawn where the game's own waves are (world.event.ocean_waves): one piece of crest per
-- wave, gliding from its tile toward the next as the wave's move timer runs down, so they keep the game's
-- pace and stop when it is paused. A wave waits 40-47 ticks between moves; WAVE_TICKS is the middle of that.
WAVE_TICKS = 44
-- false = don't place crests on the game's waves: an even train of crests (one per 4 tiles) rolls the way
-- the game's waves head instead, one px per still-water step, each crest shown along SEA_COVER of its
-- length in stretches a few tiles long.
SEA_FOLLOW = true
SEA_COVER = 0.6
-- Following the game's waves: a wave shows no foam in open water; the foam builds as the wave nears the
-- beach tile it is heading for. Tiles left to go at which it turns faint, half and full.
SEA_BUILD = {8, 5.5, 3}
-- sea tiles without foam show the still-water caustics (no rings); false leaves them plain
-- waves standing side by side are joined into wavefronts, each drawn as one continuous line (false: each
-- wave on its own). SEA_FRONT_LINK: how far apart (tiles along travel) neighbours may be to count as one
-- front; SEA_FRONT_SMOOTH: columns to either side that shape the line at a column; SEA_FRONT_GAP: a column
-- further than this from any wave of the front gets no foam (a real gap in the game's row stays a gap)
SEA_ROWS = true
SEA_FRONT_LINK = 1.3
SEA_FRONT_SMOOTH = 3
SEA_FRONT_GAP = 1.5
-- a sloping front is drawn with foam leaning to match, in steps of a third of a tile per column (the
-- diagonal foam at a full tile per column); each lean in use is one more baked frame set (false: never)
SEA_FRONT_SLANT = true
SEA_CAUSTICS = true
-- map viewport layer that carries the caustics under a foam tile (foam itself goes on the interface layer)
SEA_UNDER = 'screentexpos_signpost'
-- levels 1 crest, 2 bright crest, 4 faint wake (tools/swell.py); 5-7 foam, faint to solid, 8 trough (tools/wavegif.py)
SWELL_COLS = {[0] = 0, 0x58FFFF40, 0xA0FFFFC0, 0, 0x2CFFFF40, 0x48FFFFD0, 0x90FFFFF0, 0xD8FFFFFF, 0x28604000}
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

-- Swell: the file holds crests travelling west; other headings are the same frames mirrored or turned.
local swell_data
local function load_swell()
    if swell_data == nil then
        swell_data = false
        local f = io.open(dfhack.getDFPath() .. '/dfhack-config/scripts/caustics_swell.bin', 'rb')
        if f then
            local s = f:read('a'); f:close()
            if #s == STEPS * N * N then
                swell_data = s
                -- where the crest is in frame 0: the column with the most lit pixels
                local count, best = {}, 0
                for r = 0, N - 1 do
                    local row = {s:byte(r * N + 1, r * N + N)}
                    for c = 1, N do if row[c] ~= 0 then count[c] = (count[c] or 0) + 1 end end
                end
                for c = 1, N do if (count[c] or 0) > (count[best] or 0) then best = c end end
                state.swell_x0 = best - 1
                -- and how far from that column its foam reaches (wiggle included), all but stray specks
                local far = {}
                for c = 1, N do
                    local d = math.abs((c - best + N // 2) % N - N // 2)
                    far[d] = (far[d] or 0) + (count[c] or 0)
                end
                local reach = 0
                for d = 0, N // 2 do if (far[d] or 0) >= 4 then reach = d end end
                state.swell_reach = reach
            end
        end
    end
    return swell_data
end
-- 4x4 ordered-dither thresholds, for thinning foam out toward the end of a stretch
local BAYER = {[0] = 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5}
-- slant: the crest leans by slant/3 pixels of travel per pixel across, turning about the middle of each
-- tile-wide strip, so a strip still shows its crest where the unslanted set does and neighbouring strips
-- placed a slant apart join up (used for wavefronts that are neither straight nor at 45 degrees)
local function build_swell_frame(data, o, heading, fade, slant)
    local lean = slant and slant / 3
    local pix, base, col = {}, o * N * N, SWELL_COLS
    local turned, flipped = heading == 'north' or heading == 'south', heading == 'east' or heading == 'south'
    -- diagonal headings: the crest lies along a diagonal; (x + y, x - y) both wrap at N, so the tiles still join
    local diag = #heading == 2 and ((heading == 'nw' or heading == 'se') and 1 or -1)
    if diag then flipped = heading == 'se' or heading == 'ne' end
    -- 'faint' and 'mid': foam still building, thinned all over and (faint) one step dimmer
    local thin = fade == 'faint' and 0.4 or fade == 'mid' and 0.75
    local dim = fade == 'faint'
    if thin or diag then fade = nil end
    local rows = {}
    for r = 0, N - 1 do rows[r] = {data:byte(base + r * N + 1, base + r * N + N)} end
    for y = 0, N - 1 do
        local at = y * N
        for x = 0, N - 1 do
            -- (along, across) = position along the travel axis and across it
            local along, across = x, y
            if turned then along, across = y, x end
            if diag then along, across = (x + diag * y) % N, (x - diag * y) % N end
            if lean then along = (along - math.floor(lean * (across % TP - (TP - 1) / 2) + 0.5)) % N end
            if flipped then along = N - 1 - along end
            local v = rows[across][along + 1]
            if v ~= 0 and fade then
                -- share of foam kept at this point of the tile: 0 at the faded end(s), 1 at the other
                local a = (across % TP + 0.5) / TP
                local keep = fade == 'lo' and a or fade == 'hi' and 1 - a or 2 * math.min(a, 1 - a)
                if keep * 16 <= BAYER[(y % 4) * 4 + x % 4] + 0.5 then v = 0 end
            end
            if thin and v ~= 0 then
                if thin * 16 <= BAYER[(y % 4) * 4 + x % 4] + 0.5 then v = 0
                elseif dim and v > 5 and v <= 7 then v = v - 1 end
            end
            pix[at + x + 1] = col[v] or 0
        end
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
    local sw, fade, slant = dir:match('^swell_(%a+)_?(%a*)([+-]?%d*)$')
    if sw then
        local data = load_swell()
        if not data then return build_frame('none', o) end
        return build_swell_frame(data, o, sw, fade ~= '' and fade or nil, slant ~= '' and tonumber(slant) or nil)
    end
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
-- The sea is drawn with crests only on a map that has ocean waves; once any are seen it stays that way.
local function sea_key()
    local site = dfhack.world.getCurrentSite()
    local id = dfhack.world.ReadWorldFolder() .. '/' .. (site and site.id or -1)
    local f = state.sea
    if not f or f.id ~= id then f = {id=id}; state.sea = f end
    if SEA_FOLLOW then
        if not f.waves and #df.global.world.event.ocean_waves > 0 then f.waves = true end
        return f.waves and 'sea'
    end
    -- the train's heading: the waves' headings added up, nearest compass direction, fixed once per map
    if f.key then return f.key end
    local gx, gy = 0, 0
    for _, w in ipairs(df.global.world.event.ocean_waves) do
        local dx, dy = w.dest.x - w.cur.x, w.dest.y - w.cur.y
        local n = math.sqrt(dx * dx + dy * dy)
        if n > 0 then gx, gy = gx + dx / n, gy + dy / n end
    end
    if gx * gx + gy * gy < 1 then return nil end
    if math.abs(gx) >= math.abs(gy) then f.key = gx < 0 and 'swell_west' or 'swell_east'
    else f.key = gy < 0 and 'swell_north' or 'swell_south' end
    return f.key
end
-- The train: which stretch of which crest a sea tile shows at this step, as the frame set to draw it with
-- (plain, or thinning toward a gap), or false in a gap. Crests are numbered as they travel.
local SWELL_AXIS = {swell_west={1, 0, 1}, swell_east={1, 0, -1}, swell_north={0, 1, 1}, swell_south={0, 1, -1}}
local SWELL_SET = {}
for k in pairs(SWELL_AXIS) do SWELL_SET[k] = {[0] = k, k .. '_lo', k .. '_hi', k .. '_both'} end
local function crest_shown(c, a)
    local h = (c * 2654435761) & 0xffffffff
    h = ((h ~ (h >> 15)) * 0x2c1b3c6d) & 0xffffffff
    h = h ~ (h >> 13)
    local p1, p2 = (h & 0xffff) / 65536 * 6.2832, (h >> 16) / 65536 * 6.2832
    local n = math.sin(a * 0.61 + p1) + 0.6 * math.sin(a * 0.23 + p2)
    return n > (0.5 - SEA_COVER) * 2.3
end
local function swell_variant(key, x, y, step)
    local ax = SWELL_AXIS[key]
    local along, a = (x * ax[1] + y * ax[2]) * ax[3], x * ax[2] + y * ax[1]
    local c = (along * TP + TP // 2 * ax[3] + step - (state.swell_x0 or 0) + N // 2) // N
    if not crest_shown(c, a) then return false end
    return SWELL_SET[key][(crest_shown(c, a - 1) and 0 or 1) + (crest_shown(c, a + 1) and 0 or 2)]
end
-- Where to draw crest this tick: {[y * 8192 + x] = {frame set, frame, distance}} for the view plus a margin.
-- Each of the game's waves gets a piece of crest turned to its own heading (one of the eight compass
-- directions, from its tile toward its destination), placed between its tile and the next by how far its
-- timer has run. The frame is the one whose crest sits at that pixel. Where pieces share a tile, the one
-- whose crest is nearest the tile's middle is drawn.
local HEADING = {[-1] = {[-1] = 'nw', [0] = 'west', [1] = 'sw'}, [0] = {[-1] = 'north', [1] = 'south'},
                 [1] = {[-1] = 'ne', [0] = 'east', [1] = 'se'}}
local function sign(n) return n > 0 and 1 or n < 0 and -1 or 0 end
local function sea_crests(vp, z0)
    local tick = df.global.cur_year_tick
    local key = ('%d,%d,%d,%d,%d,%d'):format(tick, vp.x1, vp.y1, vp.x2, vp.y2, z0)
    if state.crest_key == key then return state.crests end
    local out = {}
    state.crest_key, state.crests = key, out
    if not load_swell() then return out end
    local x0, reach = state.swell_x0, state.swell_reach
    local xa, ya, xb, yb = vp.x1 - 2, vp.y1 - 2, vp.x2 + 2, vp.y2 + 2
    state.sea_want = state.sea_want or {}
    -- the debug arrows (wavetiles.lua) sit on the tile behind each wave: leave those tiles to them
    local arrows, behind = false, {}
    if dfhack.findScript('wavetiles') then
        local wt = reqscript('wavetiles')
        arrows = wt.BEHIND and wt.state.seen and os.clock() - wt.state.seen < 0.5
    end
    local want = state.sea_want
    local function need(heading)
        -- every heading in use on the map gets its frame sets baked ahead (see the end of onRenderFrame):
        -- a wave is near the beach for a few seconds only, too short to bake its set when first needed
        if heading and not want[heading] then
            want[heading] = true
            for _, b in ipairs{'_faint', '_mid', ''} do want[#want + 1] = 'swell_' .. heading .. b end
        end
    end
    local function stage(left)
        return left <= SEA_BUILD[3] and '' or left <= SEA_BUILD[2] and '_mid' or left <= SEA_BUILD[1] and '_faint'
    end
    local function put(tx, ty, set, frame, d)
        local k = ty * 8192 + tx
        local o = out[k]
        if not o or d < o[3] then out[k] = {set, frame, d} end
    end
    -- one wave drawn on its own, turned to its own heading
    local function piece(x, y, dx, dy, f, heading, build)
        -- ux, uy: the axis the crest position is measured on (px = ux * x + uy * y), running forward
        -- for the mirrored sets; span: how far a tile reaches from its middle on that axis
        local ux, uy, span = 0, 0, TP // 2
        if dy == 0 then ux = 1 elseif dx == 0 then uy = 1
        else ux, uy, span = 1, dx * dy, TP end
        local fwd = ux * dx + uy * dy            -- -1 or -2: toward lower positions, 1 or 2: mirrored set
        local a = (ux * (x + 0.5) + uy * (y + 0.5)) * TP + fwd * f * TP
        local frame = math.floor((fwd > 0 and x0 - (N - 1) + a or x0 - a) + 0.5) % STEPS
        local set = 'swell_' .. heading .. build
        for ty = y, y + dy, dy == 0 and 1 or dy do
            for tx = x, x + dx, dx == 0 and 1 or dx do
                local d = math.abs((ux * (tx + 0.5) + uy * (ty + 0.5)) * TP - a)
                if d < span + reach then put(tx, ty, set, frame, d) end
            end
        end
    end
    local ws, at = {}, {}
    local RM = 8  -- waves this far outside the view still count toward a row
    for _, w in ipairs(df.global.world.event.ocean_waves) do
        local x, y, z = w.cur.x, w.cur.y, w.z
        local dx, dy = sign(w.dest.x - x), sign(w.dest.y - y)
        local heading = HEADING[dx][dy]
        need(heading)
        if heading and dx ~= 0 and dy ~= 0 and SEA_ROWS then
            need(HEADING[dx][0]); need(HEADING[0][dy])
        end
        if arrows and z == z0 then behind[#behind + 1] = (y - dy) * 8192 + x - dx end
        if heading and dx ~= 0 and dy ~= 0 then
            local m = at[heading]
            if not m then m = {}; at[heading] = m end
            m[y * 8192 + x] = true
        end
        if heading and x >= xa - RM and x <= xb + RM and y >= ya - RM and y <= yb + RM and z <= z0 and z >= z0 - 4 then
            local f = 1 - w.move_timer / WAVE_TICKS
            f = f < 0 and 0 or f > 1 and 1 or f
            local e = {x = x, y = y, dx = dx, dy = dy, f = f, heading = heading, tx = w.dest.x, ty = w.dest.y}
            ws[#ws + 1] = e
        end
    end
    -- which way the rows of each diagonal heading run: one answer per heading from all its waves on the map
    -- (deciding per wave gave mixed orientations inside one row); kept until the count clearly reverses
    state.sea_axis = state.sea_axis or {}
    local row_axis = state.sea_axis
    for heading, m in pairs(at) do
        local h, v = 0, 0
        for k in pairs(m) do
            if m[k + 1] then h = h + 1 end
            if m[k + 8192] then v = v + 1 end
        end
        local cur = row_axis[heading]
        if h > 2 * v + 2 or not cur and h > v then row_axis[heading] = 'y'
        elseif v > 2 * h + 2 or not cur and v > h then row_axis[heading] = 'x' end
    end
    -- Rows: the game moves every wave on its own timer, so a row of them is ragged. Waves standing side by
    -- side (a row across their travel) are drawn as one straight crest at the row's average position, which
    -- can put a wave's foam in the tile next to the one the game has it in. Diagonal waves standing in an
    -- east-west or north-south row are drawn as a crest along that row.
    local groups = {}  -- per crest heading: columns of entries
    for i = 1, #ws do
        local e = ws[i]
        local x, y, dx, dy = e.x, e.y, e.dx, e.dy
        local axis  -- 'x': crest runs north-south and travels along x; 'y': the other way round
        if not SEA_ROWS then axis = nil
        elseif dy == 0 then axis = 'x' elseif dx == 0 then axis = 'y'
        else axis = row_axis[e.heading] end
        if not axis then
            if x >= xa and x <= xb and y >= ya and y <= yb then
                local build = stage(math.max(math.abs(e.tx - x), math.abs(e.ty - y)) - e.f)
                if build then piece(x, y, dx, dy, e.f, e.heading, build) end
            end
        else
            -- side: a diagonal wave also slides along its row, one column per step. Waves step at different
            -- moments, so for a while a column holds two waves and its neighbour none; each diagonal wave
            -- therefore covers the column it is in and the one it is sliding into.
            if axis == 'x' then e.dir, e.c, e.s, e.goal, e.side = dx, y, x + dx * e.f, e.tx, dy
            else e.dir, e.c, e.s, e.goal, e.side = dy, x, y + dy * e.f, e.ty, dx end
            e.axis, e.root = axis, e
            local name = axis == 'x' and (dx < 0 and 'west' or 'east') or (dy < 0 and 'north' or 'south')
            local g = groups[name]
            if not g then g = {}; groups[name] = g end
            local col = g[e.c]
            if not col then col = {}; g[e.c] = col end
            col[#col + 1] = e
        end
    end
    local function find(e)
        while e.root ~= e do e.root = e.root.root; e = e.root end
        return e
    end
    for name, g in pairs(groups) do
        -- Wavefronts: waves in neighbouring columns whose positions differ by no more than SEA_FRONT_LINK
        -- tiles belong to one front. A front is drawn as one line: every column from its first wave to its
        -- last gets foam at the weighted average position of the waves within SEA_FRONT_SMOOTH columns, so
        -- the game's ragged row becomes a smooth curve, columns without a wave are filled in, and the
        -- build-up stage changes along the front instead of per wave.
        for c, col in pairs(g) do
            for _, e in ipairs(col) do
                for cc = c - 2, c do
                    local other = g[cc]
                    if other then
                        for _, o in ipairs(other) do
                            if o ~= e and math.abs(o.s - e.s) <= SEA_FRONT_LINK then
                                local ra, rb = find(e), find(o)
                                if ra ~= rb then ra.root = rb end
                            end
                        end
                    end
                end
            end
        end
        local fronts = {}
        for _, col in pairs(g) do
            for _, e in ipairs(col) do
                local r = find(e)
                local fr = fronts[r]
                if not fr then fr = {lo = math.huge, hi = -math.huge}; fronts[r] = fr end
                -- p: where the wave is along the front; a diagonal wave is part-way into the next column
                e.p, e.left = e.c + e.side * e.f, math.abs(e.goal - e.s)
                fr[#fr + 1] = e
                if e.p < fr.lo then fr.lo = e.p end
                if e.p > fr.hi then fr.hi = e.p end
            end
        end
        for _, fr in pairs(fronts) do
            local dir, axis = fr[1].dir, fr[1].axis
            local q1, q2 = math.floor(fr.lo), math.ceil(fr.hi)
            local pos, left = {}, {}
            for q = q1, q2 do
                local sw, ss, sl, near = 0, 0, 0, math.huge
                for i = 1, #fr do
                    local e = fr[i]
                    local off = math.abs(e.p - q)
                    if off < near then near = off end
                    local w = 1 - off / SEA_FRONT_SMOOTH
                    if w > 0 then sw, ss, sl = sw + w, ss + w * e.s, sl + w * e.left end
                end
                if sw > 0 and near <= SEA_FRONT_GAP then pos[q], left[q] = ss / sw, sl / sw end
            end
            for q = q1, q2 do
                local s, build = pos[q], pos[q] and stage(left[q])
                if build then
                    -- slope of the front here, tiles of travel per column, to the nearest third: the foam
                    -- drawn leans by that much, so the line carries on from column to column instead of
                    -- stepping down
                    local sa, sb = pos[q - 1], pos[q + 1]
                    local m = sa and sb and (sb - sa) / 2 or sa and s - sa or sb and sb - s or 0
                    local diag, set, lean = nil, nil, 0
                    local third = SEA_FRONT_SLANT and math.floor(math.abs(m) * 3 + 0.5) or 0
                    if third >= 3 then
                        -- the diagonal heading that travels the front's way with its crest along the slope
                        local turn = m > 0 and -dir or dir
                        diag = axis == 'x' and HEADING[dir][turn] or HEADING[turn][dir]
                        need(diag)
                        set = 'swell_' .. diag .. build
                        if not state.sets[set] then diag, set = nil, nil end  -- still baking: straight for now
                    elseif third > 0 then
                        -- in between: the straight foam leaning a third or two thirds of a tile per column
                        set = ('swell_%s%s%+d'):format(name, build, m > 0 and third or -third)
                        if not want[set] then want[set] = true; want[#want + 1] = set end
                        if state.sets[set] then lean = third / 3 else set = nil end
                    end
                    if diag then
                        local uy = m > 0 and -1 or 1
                        local fwd = axis == 'x' and 2 * dir or 2 * (m > 0 and -dir or dir)
                        local a = axis == 'x' and ((s + 0.5) + uy * (q + 0.5)) * TP or ((q + 0.5) + uy * (s + 0.5)) * TP
                        local frame = math.floor((fwd > 0 and x0 - (N - 1) + a or x0 - a) + 0.5) % STEPS
                        local t0 = math.floor(s + 0.5)
                        for t = t0 - 1, t0 + 1 do
                            local c = axis == 'x' and ((t + 0.5) + uy * (q + 0.5)) * TP or ((q + 0.5) + uy * (t + 0.5)) * TP
                            local d = math.abs(c - a)
                            if d < TP + reach then
                                if axis == 'x' then put(t, q, set, frame, d) else put(q, t, set, frame, d) end
                            end
                        end
                    else
                        local a = (s + 0.5) * TP
                        local frame = math.floor((dir > 0 and x0 - (N - 1) + a or x0 - a) + 0.5) % STEPS
                        set = set or 'swell_' .. name .. build
                        local t0 = math.floor(s + 0.5)
                        for t = t0 - 1, t0 + 1 do
                            local d = math.abs((t + 0.5) * TP - a)
                            if d < TP // 2 + reach + lean * TP / 2 then
                                if axis == 'x' then put(t, q, set, frame, d) else put(q, t, set, frame, d) end
                            end
                        end
                    end
                end
            end
        end
    end
    for i = 1, #behind do out[behind[i]] = false end
    return out
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
    local sea = SEA_SWELL and sea_key()
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
    local texpos = {}  -- per direction, this frame's 16 tile textures
    local pen = {ch=0, fg=COLOR_WHITE}
    local x1, y1, x2, y2 = vp.x1, vp.y1, vp.x2, vp.y2
    local budget = BAKE_PER_FRAME
    local crests = SEA_SWELL and SEA_FOLLOW and sea_crests(vp, df.global.window_z)
    local gaps = SEA_COVER < 1
    local mvp = df.global.gps.main_viewport
    local under, dim_y, foam = SEA_UNDER and mvp[SEA_UNDER], mvp.dim_y, nil
    for i = 1, #list do
        local p = list[i]
        local key = p[3]
        foam = nil
        if key == 'sea' then
            local x, y = p[1], p[2]
            local c = crests and crests[y * 8192 + x]
            if c == false then goto next end
            if c and x >= x1 and x <= x2 and y >= y1 and y <= y2 then
                local set = state.sets[c[1]]
                if not set and budget > 0 then
                    budget = bake_some(c[1], budget)
                    set = state.sets[c[1]]
                end
                if set then
                    foam = getTexpos(set[c[2] + 1][(y % 4) * 4 + (x % 4) + 1])
                    if not (under and SEA_CAUSTICS) then
                        paint(pen, x - x1, y - y1, nil, foam, true)
                        goto next
                    end
                end
            end
            if not SEA_CAUSTICS then goto next end
            key = 'none'
        end
        if gaps and SWELL_AXIS[key] then
            key = swell_variant(key, p[1], p[2], step_still)
            if not key then goto next end
        end
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
                local still_pace = key == 'none' or key:sub(1, 6) == 'swell_'
                local frame = set[(still_pace and t_still or t_flow) + 1]
                for k = 1, 16 do tp[k] = getTexpos(frame[k]) end
            end
            texpos[key] = tp
        end
        do local x, y = p[1], p[2]
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
            if foam then
                under[(x - x1) * dim_y + y - y1] = tex
                tex = foam
            end
            paint(pen, x - x1, y - y1, nil, tex, true)
        end end
        ::next::
    end
    if crests and state.sea_want then
        for _, k in ipairs(state.sea_want) do
            if budget <= 0 then break end
            if not state.sets[k] then budget = bake_some(k, budget) end
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
