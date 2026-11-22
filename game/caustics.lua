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
-- SEA_TILED: the whole sea plays one tiling animation of a foam wave passing over caustics
-- (SEA_FILE, made by tools/seagif.py), one wave every 4 tiles, rolling the way the game's waves
-- head on this map. It does not follow the individual waves. false = the wave-following foam below.
SEA_TILED = false
-- SEA_ONTILE: each of the game's waves gets a foam crescent (caustics_wavetile.bin, made by
-- tools/wavetile.py) on the tile the game has it on, turned to its heading. The crescent crosses that
-- tile from back to front as the game's move timer for the wave runs down, then the wave is on the next
-- tile. Waves are not joined. Overrides SEA_TILED and the foam below.
SEA_ONTILE = true
-- SEA_SHORE: surf driven by distance to the coast instead of by the game's wave objects. Every sea tile near
-- land knows its distance to the nearest land tile. A wave is a band of foam SHORE_BAND tiles deep - bright
-- front edge, dense foam behind it, a lacy tail (the still-water pattern in white) - drawn so its front is
-- where that distance equals a value shrinking at SHORE_SPEED tiles per second; one wave every SHORE_GAP
-- tiles. It appears SHORE_MAX tiles out (front edge to land) as a thin streak with a little lace, turns to full foam SHORE_MID
-- tiles out, runs up onto the land tiles at the water's edge (SHORE_BEACH; floors on the viewed level), stops
-- there and thins away where it lies. The band is one texture sliding over the tiles, so nothing switches tile by
-- tile. Overrides SEA_ONTILE, SEA_TILED and the wave-following foam.
SEA_SHORE = true
SHORE_MAX, SHORE_MID, SHORE_GAP, SHORE_SPEED, SHORE_BAND = 2, 1, 6, 0.6, 3.3
SHORE_BEACH = true
-- at most this many foam frame sets (about 8 MB each; a thinning set counts as 1/EBB_DIV); past it, coasts
-- at new angles use the straight set
SHORE_SETS = 56
-- how far the wave front runs into the last land tile before it stops and the foam thins away in place,
-- as tiles past the water's edge plus 0.5 (1 = half a tile onto the land, 2 = a tile and a half). The stop line
-- keeps that distance from the smoothed coast everywhere, so it rounds corners and steps instead of following tiles.
SHORE_RUN = 1
-- Tiles the land is grown and shrunk by before the wave's path is worked out, so that small notches and
-- channels in the coast do not each bend the foam their own way (0 = follow every tile).
SHORE_CLOSE = 2
SHORE_WATER = {1, 78, 90}   -- the sea's colour (R, G, B) under the foam drawn on land
LACE_COLS = {full = {[0] = 0xD8FFFFFF, 0x48FFFFF0, 0, 0, 0x98FFFFF8, 0},
             hi = {[0] = 0, 0xA0FFFFF0, 0, 0, 0x58FFFFD8, 0xE0FFFFFF},
             mid = {[0] = 0, 0x70FFFFF0, 0, 0, 0x28FFFFD8, 0xB0FFFFFF},
             lo = {[0] = 0, 0x38FFFFE8, 0, 0, 0, 0x70FFFFFF}}
-- caustics_sea_crescent.bin: crescent-shaped waves; caustics_sea_line.bin: one unbroken wavy foam line
SEA_FILE = 'caustics_sea_crescent.bin'
-- caustics as in still water (1 line, 4 very faint, 5 white knot); foam 9 faint, 10 half, 11 solid white
SEA_COLS = {[0] = 0, [1] = STILL_FAINT, [4] = STILL_VFAINT, [5] = STILL_CROSS, [9] = 0x48FFFFD0, [10] = 0x90FFFFF0, [11] = 0xD8FFFFFF}
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
-- waves further out than that show faint foam too (false: no foam in open water)
SEA_OPEN = true
-- sea tiles without foam show the still-water caustics (no rings); false leaves them plain
-- waves standing side by side are joined into wavefronts, each drawn as one continuous line (false: each
-- wave on its own). SEA_FRONT_LINK: how far apart (tiles along travel) neighbours may be to count as one
-- front; SEA_FRONT_SMOOTH: columns to either side that shape the line at a column; SEA_FRONT_GAP: a column
-- further than this from any wave of the front gets no foam (a real gap in the game's row stays a gap)
SEA_ROWS = true
SEA_FRONT_LINK = 2.6
SEA_FRONT_SMOOTH = 4
SEA_FRONT_GAP = 2
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
local sea_data
local function load_sea()
    if sea_data == nil then
        sea_data = false
        local f = io.open(dfhack.getDFPath() .. '/dfhack-config/scripts/' .. SEA_FILE, 'rb')
        if f then
            local s = f:read('a'); f:close()
            if #s == STEPS * N * N then sea_data = s end
        end
    end
    return sea_data
end
-- 4x4 ordered-dither thresholds, for thinning foam out toward the end of a stretch
local BAYER = {[0] = 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5}
-- slant: the crest leans by slant/3 pixels of travel per pixel across, turning about the middle of each
-- tile-wide strip, so a strip still shows its crest where the unslanted set does and neighbouring strips
-- placed a slant apart join up (used for wavefronts that are neither straight nor at 45 degrees)
local function build_swell_frame(data, o, heading, fade, slant, cols)
    local lean = slant and slant / 3
    local pix, base, col = {}, o * N * N, cols or SWELL_COLS
    local turned, flipped = heading == 'north' or heading == 'south', heading == 'east' or heading == 'south'
    -- diagonal headings: the crest lies along a diagonal; (x + y, x - y) both wrap at N, so the tiles still join
    local diag = #heading == 2 and ((heading == 'nw' or heading == 'se') and 1 or -1)
    if diag then flipped = heading == 'se' or heading == 'ne' end
    -- 'faint' and 'mid': foam still building, thinned all over and (faint) one step dimmer
    local thin = fade == 'faint' and 0.4 or fade == 'mid' and 0.75 or fade == 'thin' and 0.6
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

-- SEA_SHORE: one frame of the surf band, travelling west with its front at column (SHORE_X0 - o); turned,
-- mirrored and leaned like the swell. The band is cut out of the still-water pattern, which stays where it
-- is on the map, so sets for different headings and leans join up.
local SHORE_X0 = 100
local function build_shore_frame(data, o, heading, lean, far, beach, sand, ebb)
    local pix = {}
    -- sand: for land tiles; the dense foam reaches further back, so the sheet on the sand stays wide.
    -- ebb: for the tile where the wave stops. The front stays put inside the tile and o is how many px the
    -- wave would have travelled past it: the foam behind the front thins as if the band had moved on.
    -- ebb is a number: how many px the stop line lies landward of the tile's centre (negative: seaward; a
    -- whole tile or more: the line is in a tile further in and this one is covered). The foam thins
    -- fastest at the stop line and slowest toward the sea, so the sheet dries from its inland edge and the
    -- last foam lies at the water's edge, not stranded behind a strip of bare sand.
    beach = beach or sand or ebb
    local z1, z2, z3, z4 = 22, 34, 62, 86
    if sand or ebb then z1, z2, z3, z4 = 32, 48, 72, 92 end
    local stop = TP / 2 - (ebb or 0)
    -- beach: for land tiles. Every drawn pixel is mixed with the water colour beforehand and made solid, so
    -- the foam looks the same on sand as on the sea instead of letting the ground tint it.
    local function solid(c)
        if c == 0 then return 0 end
        local a = (c >> 24) / 255
        local r, g, b = c & 0xff, (c >> 8) & 0xff, (c >> 16) & 0xff
        r = math.floor(r * a + SHORE_WATER[1] * (1 - a) + 0.5)
        g = math.floor(g * a + SHORE_WATER[2] * (1 - a) + 0.5)
        b = math.floor(b * a + SHORE_WATER[3] * (1 - a) + 0.5)
        return 0xFF000000 | b << 16 | g << 8 | r
    end
    local wet = 0xFF000000 | SHORE_WATER[3] << 16 | SHORE_WATER[2] << 8 | SHORE_WATER[1]
    local turned, flipped = heading == 'north' or heading == 'south', heading == 'east' or heading == 'south'
    local rows = {}
    for r = 0, N - 1 do rows[r] = {data:byte(r * N + 1, r * N + N)} end
    local wob = {}
    for a = 0, N - 1 do
        local t = a * 2 * math.pi / N
        wob[a] = 3.5 * math.sin(2 * t) + 2.5 * math.sin(5 * t + 1) + 1.5 * math.sin(11 * t + 2)
    end
    local front = SHORE_X0 - o
    if ebb and (heading == 'east' or heading == 'south') then stop = stop - 1 end
    for y = 0, N - 1 do
        local at = y * N
        for x = 0, N - 1 do
            local along, across = x, y
            if turned then along, across = y, x end
            -- (af: the same position before leaning, which says which tile the pixel is in)
            local af = flipped and N - 1 - along or along
            if lean then along = along - math.floor(lean * (across % TP - (TP - 1) / 2) + 0.5) end
            if flipped then along = N - 1 - along end
            -- u: px behind the front, with a little grain so the zones do not end on a ruled line
            local u = (along - front - wob[across]) % N
            if ebb then
                u = along - (af - af % TP) - stop - wob[across]
                u = u < 0 and N or u + o * math.max(0.4, 1.6 - u / 45)
            end
            local v = rows[y][x + 1]
            local line = v == 1 or v == 5
            local g = u + (BAYER[(y % 4) * 4 + x % 4] - 7.5) * 0.9
            local c = 0
            if far then
                if u < 2.5 then c = 0x90FFFFF8
                elseif g < 34 then c = line and 0x78FFFFF0 or 0
                elseif g < 60 then c = line and 0x40FFFFE8 or 0 end
            elseif u >= N then c = 0
            elseif u < 4 then c = 0xF0FFFFFF
            elseif g < z1 then c = line and 0x30FFFFF0 or v == 4 and 0xA0FFFFF8 or 0xD8FFFFFF
            elseif g < z2 then c = line and 0xE0FFFFFF or v == 4 and 0x90FFFFF8 or (g < (z1 + z2) / 2 and 0x70FFFFF8 or 0x38FFFFF0)
            elseif g < z3 then c = v == 5 and 0xE0FFFFFF or v == 1 and 0xA8FFFFF8 or v == 4 and 0x50FFFFE8 or 0
            elseif g < z4 then c = v == 5 and 0xB0FFFFFF or v == 1 and 0x70FFFFF0 or 0
            elseif g < 104 then c = v == 5 and 0x70FFFFFF or v == 1 and 0x38FFFFE8 or 0 end
            -- on land the wave's water still lies behind the front where the foam has thinned: sea colour
            -- there instead of bare sand, fading out further back (and on the sea tiles beside land, where it
            -- hides the ragged edge of the ground that the game draws into them)
            if beach and c == 0 and u < 84 and (u < 60 or (84 - u) / 24 * 16 > BAYER[(y % 4) * 4 + x % 4] + 0.5) then
                c = wet
            else
                c = beach and solid(c) or c
            end
            pix[at + x + 1] = c
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
    local tiled = dir:match('^sea_(%a+)$')
    if tiled then
        local data = load_sea()
        if not data then return build_frame('none', o) end
        return build_swell_frame(data, o, tiled, nil, nil, SEA_COLS)
    end
    local lace = dir:match('^lace_(%a+)$')
    if lace then
        local data = load_still()
        if not data then return build_frame('none', o) end
        local pix, base, col = {}, o * N * N, LACE_COLS[lace]
        for y = 0, N - 1 do
            local row = {data:byte(base + y * N + 1, base + y * N + N)}
            for x = 1, N do pix[y * N + x] = col[row[x]] or 0 end
        end
        return dfhack.textures.createTileset(pix, N, N, TP, TP)
    end
    local sh, far, lean = dir:match('^shore_(%a+)_?(%a*)([+-]?%d*)$')
    if sh then
        local data = load_still()
        if not data then return build_frame('none', o) end
        return build_shore_frame(data, o, sh, lean ~= '' and tonumber(lean) / 2 or nil, far == 'far', far == 'beach', far == 'sand', far:match('^ebb%a$') and (far:byte(4) - 100) * 8)
    end
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
EBB_DIV = 4
state.partial = state.partial or {}
local function bake_some(dir, budget)
    local part = state.partial[dir] or {}
    state.partial[dir] = part
    -- (the thinning sets of the shore surf keep every EBB_DIV-th frame only: there are many of them)
    local div = dir:find('_ebb', 1, true) and EBB_DIV or 1
    local want = STEPS // div
    while budget > 0 and #part < want do
        part[#part + 1] = build_frame(dir, #part * div)
        budget = budget - 1
    end
    if #part == want then
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
-- The tiled sea's heading: the game's waves' headings added up, nearest of the eight compass directions,
-- fixed once per map (nil until the map has shown waves).
local function sea_heading()
    local site = dfhack.world.getCurrentSite()
    local id = dfhack.world.ReadWorldFolder() .. '/' .. (site and site.id or -1)
    local f = state.sea_head
    if f and f.id == id then return f.key end
    local gx, gy = 0, 0
    for _, w in ipairs(df.global.world.event.ocean_waves) do
        local dx, dy = w.dest.x - w.cur.x, w.dest.y - w.cur.y
        local n = math.sqrt(dx * dx + dy * dy)
        if n > 0 then gx, gy = gx + dx / n, gy + dy / n end
    end
    if gx * gx + gy * gy < 1 then return nil end
    local oct = math.floor(math.atan(gy, gx) / (math.pi / 4) + 0.5) % 8
    local names = {[0] = 'east', 'se', 'south', 'sw', 'west', 'nw', 'north', 'ne'}
    state.sea_head = {id = id, key = 'sea_' .. names[oct]}
    return state.sea_head.key
end
-- SEA_ONTILE: the foam crescent, one texture per frame per heading.
local wavetile_data
local function load_wavetile()
    if wavetile_data == nil then
        wavetile_data = false
        local f = io.open(dfhack.getDFPath() .. '/dfhack-config/scripts/caustics_wavetile.bin', 'rb')
        if f then
            local s = f:read('a'); f:close()
            if #s == STEPS * TP * TP then wavetile_data = s end
        end
    end
    return wavetile_data
end
local WAVE_DIR = {west = {-1, 0}, east = {1, 0}, north = {0, -1}, south = {0, 1},
                  nw = {-1, -1}, ne = {1, -1}, sw = {-1, 1}, se = {1, 1}}
state.wsets, state.wpart = state.wsets or {}, state.wpart or {}
-- bakes up to `budget` frames of a heading's crescent; returns what is left of the budget
local function bake_wave(heading, budget)
    local data = load_wavetile()
    if not data then return budget end
    local part = state.wpart[heading] or {}
    state.wpart[heading] = part
    local d = WAVE_DIR[heading]
    local n = math.sqrt(d[1] * d[1] + d[2] * d[2])
    local hx, hy, c = d[1] / n, d[2] / n, (TP - 1) / 2
    while budget > 0 and #part < STEPS do
        local base, pix = #part * TP * TP, {}
        for y = 0, TP - 1 do
            for x = 0, TP - 1 do
                -- the file's crescent travels west: forward is -x there
                local dx, dy = x - c, y - c
                local sx = math.floor(c - (dx * hx + dy * hy) + 0.5)
                local sy = math.floor(c + (dx * hy - dy * hx) + 0.5)
                local v = 0
                if sx >= 0 and sx < TP and sy >= 0 and sy < TP then v = data:byte(base + sy * TP + sx + 1) end
                pix[y * TP + x + 1] = SEA_COLS[v] or 0
            end
        end
        part[#part + 1] = dfhack.textures.createTileset(pix, TP, TP, TP, TP)[1]
        budget = budget - 1
    end
    if #part == STEPS then state.wsets[heading], state.wpart[heading] = part, nil end
    return budget
end
local HEADING8 = {[-1] = {[-1] = 'nw', [0] = 'west', [1] = 'sw'}, [0] = {[-1] = 'north', [1] = 'south'},
                  [1] = {[-1] = 'ne', [0] = 'east', [1] = 'se'}}
-- {[y * 8192 + x] = {heading, frame}} for the game's waves on the viewed level or up to 4 below it
local function wave_tiles(z0)
    local out = {}
    for _, w in ipairs(df.global.world.event.ocean_waves) do
        local x, y, z = w.cur.x, w.cur.y, w.z
        if z <= z0 and z >= z0 - 4 then
            local dx, dy = w.dest.x - x, w.dest.y - y
            local h = HEADING8[dx > 0 and 1 or dx < 0 and -1 or 0][dy > 0 and 1 or dy < 0 and -1 or 0]
            if h then
                local f = 1 - w.move_timer / WAVE_TICKS
                f = f < 0 and 0 or f > 1 and 1 or f
                out[y * 8192 + x] = {h, math.floor(f * (STEPS - 1) + 0.5)}
            end
        end
    end
    return out
end
-- SEA_SHORE: distance to the coast for the sea tiles in view. Looks at the view plus a margin, so every
-- tile in view within SHORE_MAX of land finds that land. Returns {t = {[y * 8192 + x] = entry}}, entry =
-- {distance in tiles (to the land tile's edge, smoothed), frame set, tile middle on the travel axis in px,
--  px along that axis per tile of distance, mirrored set?, tiles along the axis per tile of distance}.
local function shore_field(vp, z0)
    local key = ('%d,%d,%d,%d,%d'):format(vp.x1, vp.y1, vp.x2, vp.y2, z0)
    local now = dfhack.getTickCount()
    local c = state.shore
    -- while the view is moving, the field of a moment ago still covers most of it
    if c and (c.key == key and now - c.at < 5000 or now - c.at < 300) then return c end
    c = {key = key, at = now, t = {}}
    state.shore = c
    local getFlags, getType = dfhack.maps.getTileFlags, dfhack.maps.getTileType
    local attrs, OPEN, RAMP_TOP = df.tiletype.attrs, df.tiletype_shape.EMPTY, df.tiletype_shape.RAMP_TOP
    local M = math.ceil(SHORE_MAX + SHORE_BAND) + 3 + 2 * SHORE_CLOSE
    local W, H = vp.x2 - vp.x1 + 1 + 2 * M, vp.y2 - vp.y1 + 1 + 2 * M
    local xo, yo, zl = vp.x1 - M, vp.y1 - M, math.max(0, z0 - 4)
    -- 1 = sea, 0 = land, nil = unknown (off the map, hidden, fresh water, nothing within 5 levels)
    local kind, BIG = {}, 1e9
    local floor, FLOOR, PEBBLES = {}, df.tiletype_shape.FLOOR, df.tiletype_shape.PEBBLES
    local any = false
    for cy = 0, H - 1 do
        for cx = 0, W - 1 do
            local x, y, v = xo + cx, yo + cy, nil
            for z = z0, zl, -1 do
                local d = getFlags(x, y, z)
                if not d or d.hidden then break end
                if d.flow_size > 0 then
                    if d.liquid_type then v = 0 elseif d.water_salt then v = 1 end
                    break
                end
                local tt = getType(x, y, z)
                if not tt then break end
                local sh = attrs[tt].shape
                if sh ~= OPEN and sh ~= RAMP_TOP then
                    v = 0
                    floor[cy * W + cx] = z == z0 and (sh == FLOOR or sh == PEBBLES) or nil
                    break
                end
            end
            local k = cy * W + cx
            kind[k] = v
            if v == 0 then any = true end
        end
    end
    if not any then return c end
    -- The wave follows a simplified coast: notches and channels up to 2 * SHORE_CLOSE tiles wide (about
    -- twice that when they run diagonally) are closed
    -- (land grown by SHORE_CLOSE tiles, then shrunk again). Their water (fill) counts as beach.
    local fill = {}
    if SHORE_CLOSE > 0 then
        local R = SHORE_CLOSE
        local function pass(src, all, edge)
            -- per cell: is any (all = false) or every (all = true) cell within R along rows, then columns, set?
            local a, b = {}, {}
            for cy = 0, H - 1 do
                for cx = 0, W - 1 do
                    local v = all
                    for xx = cx - R, cx + R do
                        local q = edge
                        if xx >= 0 and xx < W then q = src[cy * W + xx] end
                        if all then v = v and q else v = v or q end
                    end
                    a[cy * W + cx] = v or false
                end
            end
            for cy = 0, H - 1 do
                for cx = 0, W - 1 do
                    local v = all
                    for yy = cy - R, cy + R do
                        local q = edge
                        if yy >= 0 and yy < H then q = a[yy * W + cx] end
                        if all then v = v and q else v = v or q end
                    end
                    b[cy * W + cx] = v or false
                end
            end
            return b
        end
        local land = {}
        for k = 0, W * H - 1 do land[k] = kind[k] == 0 end
        local closed = pass(pass(land, false, false), true, true)
        for k = 0, W * H - 1 do
            if closed[k] and kind[k] == 1 then
                fill[k], kind[k] = true, 0
            end
        end
    end
    -- squared distance to the nearest seed cell for every cell: two sweeps passing the offset to it along (8SSEDT)
    local function edt(seed)
        local ox, oy, d2 = {}, {}, {}
        for k = 0, W * H - 1 do
            if seed(k) then ox[k], oy[k], d2[k] = 0, 0, 0 else d2[k] = BIG end
        end
        local function try(k, cx, cy, nx, ny)
            local ncx, ncy = cx + nx, cy + ny
            if ncx < 0 or ncx >= W or ncy < 0 or ncy >= H then return end
            local nk = ncy * W + ncx
            if d2[nk] >= BIG then return end
            local ax, ay = ox[nk] + nx, oy[nk] + ny
            local dd = ax * ax + ay * ay
            if dd < d2[k] then ox[k], oy[k], d2[k] = ax, ay, dd end
        end
        for cy = 0, H - 1 do
            for cx = 0, W - 1 do
                local k = cy * W + cx
                try(k, cx, cy, -1, 0); try(k, cx, cy, 0, -1); try(k, cx, cy, -1, -1); try(k, cx, cy, 1, -1)
            end
            for cx = W - 1, 0, -1 do try(cy * W + cx, cx, cy, 1, 0) end
        end
        for cy = H - 1, 0, -1 do
            for cx = W - 1, 0, -1 do
                local k = cy * W + cx
                try(k, cx, cy, 1, 0); try(k, cx, cy, 0, 1); try(k, cx, cy, 1, 1); try(k, cx, cy, -1, 1)
            end
            for cx = 0, W - 1 do try(cy * W + cx, cx, cy, -1, 0) end
        end
        return d2
    end
    -- distance to the coast in tiles, 0 on the line between a land tile and a sea tile: positive at sea,
    -- negative on land (to 4 tiles in), so the field runs on evenly across the water's edge
    local d2 = edt(function(k) return kind[k] == 0 end)
    local l2 = edt(function(k) return kind[k] == 1 end)
    local dist = {}
    for k = 0, W * H - 1 do
        -- (a cell that is neither, fresh water or off the map, goes with whichever is nearer, so a pond
        -- behind the beach is not taken for sea)
        if kind[k] == 0 or kind[k] == nil and d2[k] < l2[k] then
            dist[k] = l2[k] < BIG and -math.min(4, math.sqrt(l2[k]) - 0.5) or -4
        else
            dist[k] = d2[k] < BIG and math.max(0, math.sqrt(d2[k]) - 0.5) or false
        end
    end
    -- smoothed over 3x3 so a jagged beach does not put a jag in every line
    local sm = {}
    for cy = 1, H - 2 do
        for cx = 1, W - 2 do
            local s, n = 0, 0
            for yy = cy - 1, cy + 1 do
                for xx = cx - 1, cx + 1 do
                    local v = dist[yy * W + xx]
                    if v then s, n = s + v, n + 1 end
                end
            end
            sm[cy * W + cx] = n > 0 and s / n or false
        end
    end
    local t, beach = c.t, {}
    local run = SHORE_RUN - 0.5
    c.beach = beach
    local function entry(x, y, k, b, least)
        local l, r, u, dn = sm[k - 1], sm[k + 1], sm[k - W], sm[k + W]
        if not (l and r and u and dn) then return end
        -- (ux, uy): toward the coast
        local ux, uy = (l - r) / 2, (u - dn) / 2
        local n = math.sqrt(ux * ux + uy * uy)
        if n <= least then return end
        ux, uy = ux / n, uy / n
        local heading, mid, along, across
        if math.abs(ux) >= math.abs(uy) then
            heading, mid, along, across = ux < 0 and 'west' or 'east', (x + 0.5) * TP, ux, uy
        else
            heading, mid, along, across = uy < 0 and 'north' or 'south', (y + 0.5) * TP, uy, ux
        end
        -- the line lies across the travel direction: it leans -across/along px per px
        local slant = math.floor(-2 * across / along + 0.5)
        slant = slant > 2 and 2 or slant < -2 and -2 or slant
        local inv = 1 / math.abs(along)
        local sl = slant ~= 0 and ('%+d'):format(slant) or ''
        return {b, 'shore_' .. heading .. sl, mid, (along > 0 and 1 or -1) * TP * inv, along > 0, inv,
                'shore_' .. heading .. '_far' .. sl, 'shore_' .. heading, 'shore_' .. heading .. '_far',
                'shore_' .. heading .. '_beach' .. sl, 'shore_' .. heading .. '_beach', heading == 'west' or heading == 'east', 1,
                false, 'shore_' .. heading .. '_sand' .. sl, 'shore_' .. heading .. '_sand',
                false, false, 0, false, heading, sl}
    end
    for y = vp.y1, vp.y2 do
        for x = vp.x1, vp.x2 do
            local cx, cy = x - xo, y - yo
            local k = cy * W + cx
            local b = sm[k]
            if kind[k] == 1 and b and b <= SHORE_MAX + SHORE_BAND + 2 then
                local e = entry(x, y, k, b, 0.3)
                -- beside land the game draws the ragged edge of the ground into the sea tile, and see-through
                -- foam lets it show as a sand-coloured line: these tiles take the solid foam of the beach
                if e and SHORE_BEACH and (kind[k - 1] == 0 or kind[k + 1] == 0 or kind[k - W] == 0 or kind[k + W] == 0
                        or kind[k - W - 1] == 0 or kind[k - W + 1] == 0 or kind[k + W - 1] == 0 or kind[k + W + 1] == 0) then
                    e[14] = true
                end
                t[y * 8192 + x] = e
            elseif SHORE_BEACH and (floor[k] or fill[k]) and b and b > -(run + 1.6) and l2[k] <= (run + 1.6) ^ 2 then
                -- land: the wave stops where the field equals -run. q: how many px along the wave's path
                -- that line lies landward of this tile's centre, in steps of 8 (one thinning set per step;
                -- the tile's distance is rounded to match, so the sliding front arrives exactly there)
                local e = entry(x, y, k, b, 0.3)
                local q = e and math.floor((b + run) * TP * e[6] / 8 + 0.5) * 8
                if e and q >= -24 then
                    e[1], e[19] = q / (TP * e[6]) - run, q
                    local code = string.char(100 + math.min(6, q // 8))
                    e[17], e[18] = 'shore_' .. e[21] .. '_ebb' .. code .. e[22], 'shore_' .. e[21] .. '_ebb' .. code
                    beach[#beach + 1] = {x, y, e, fill[k]}
                    if fill[k] then e[20] = true; t[y * 8192 + x] = e end
                end
            end
        end
    end
    return c
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
        return left <= SEA_BUILD[3] and '' or left <= SEA_BUILD[2] and '_mid' or (SEA_OPEN or left <= SEA_BUILD[1]) and '_faint'
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
        if heading and z <= z0 and z >= z0 - 4 then at[y * 8192 + x] = true end
        if heading and x >= xa - RM and x <= xb + RM and y >= ya - RM and y <= yb + RM and z <= z0 and z >= z0 - 4 then
            local f = 1 - w.move_timer / WAVE_TICKS
            f = f < 0 and 0 or f > 1 and 1 or f
            local e = {x = x, y = y, dx = dx, dy = dy, f = f, heading = heading, tx = w.dest.x, ty = w.dest.y}
            ws[#ws + 1] = e
        end
    end
    -- Which way the line of waves runs at a wave: the game's waves stand in one long line that follows the
    -- coast, so the same heading (say north-west) stands in an east-west line in one place and a north-south
    -- line in another. Compare how far the waves within two tiles lie to the side and above/below. A line
    -- running mostly north-south is drawn as crest travelling along x, one running east-west along y.
    local function line_axis(e)
        if e.dy == 0 then return 'x' elseif e.dx == 0 then return 'y' end
        local h, v = 0, 0
        for oy = -2, 2 do
            for ox = -2, 2 do
                if (ox ~= 0 or oy ~= 0) and at[(e.y + oy) * 8192 + e.x + ox] then
                    h, v = h + math.abs(ox), v + math.abs(oy)
                end
            end
        end
        if h == 0 and v == 0 then return nil end
        return v > h and 'x' or 'y'
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
        else axis = line_axis(e) end
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
                            -- two waves in one column are one front only when they are the same row caught
                            -- mid-step, not one wave behind another
                            if o ~= e and math.abs(o.s - e.s) <= (cc == c and 0.6 or SEA_FRONT_LINK) then
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
            local pos, left, own = {}, {}, {}
            for q = q1, q2 do
                local sw, ss, sl, near, ne = 0, 0, 0, math.huge, nil
                for i = 1, #fr do
                    local e = fr[i]
                    local off = math.abs(e.p - q)
                    if off < near then near, ne = off, e end
                    local w = 1 - off / SEA_FRONT_SMOOTH
                    if w > 0 then sw, ss, sl = sw + w, ss + w * e.s, sl + w * e.left end
                end
                if sw > 0 and near <= SEA_FRONT_GAP then
                    pos[q], left[q] = ss / sw, sl / sw
                    own[q] = ne.dx ~= 0 and ne.dy ~= 0 and ne.heading or nil
                end
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
                        local cand = axis == 'x' and HEADING[dir][turn] or HEADING[turn][dir]
                        if own[q] and own[q] ~= cand then
                            -- the line here runs along the waves' own travel (a kink in the coast): no crest
                            -- travels that way, so lean as far as the straight foam goes
                            third = 2
                        else
                            need(cand)
                            -- still baking: straight for now
                            if state.sets['swell_' .. cand .. build] then diag, set = cand, 'swell_' .. cand .. build end
                            third = 0
                        end
                    end
                    if third > 0 then
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
    local has_sea = false
    for i = 1, #list do if list[i][3] == 'sea' then has_sea = true break end end
    local shore = SEA_SWELL and SEA_SHORE and has_sea and load_still() and shore_field(vp, df.global.window_z).t
    local shore_p = -now / 1000 * SHORE_SPEED
    local wtiles = not shore and SEA_SWELL and SEA_ONTILE and load_wavetile() and wave_tiles(df.global.window_z)
    local tiled = not shore and not wtiles and SEA_SWELL and SEA_TILED and load_sea() and sea_heading()
    local crests = not shore and not tiled and not wtiles and SEA_SWELL and SEA_FOLLOW and sea_crests(vp, df.global.window_z)
    -- foam texture for a tile of the shore field, or nil; on = true for a land tile at the water's edge
    local function shore_tex(e, x, y, on)
        -- rb: how far this tile is behind (seaward of) the front that last passed it, in tiles of distance
        -- to the coast; slightly negative when the next front is about to reach it
        local rb = (e[1] - shore_p) % SHORE_GAP
        if rb > SHORE_GAP - (on and 1 or 0.4) then rb = rb - SHORE_GAP end
        local early = rb < -0.4
        local la = e[1] - rb
        -- (the band texture repeats every 4 tiles along its travel axis: stay clear of the next copy)
        if la > SHORE_MAX then return end
        local name, alt, slide = nil, nil, true
        -- a land tile shows the thinning foam from the moment the front reaches the stop line (e[19] px
        -- landward of the tile's centre)
        local ebb = on and math.floor(TP * e[6] * rb + 0.5) - e[19]
        local halt, halt_alt = e[17], e[18]
        if ebb and ebb >= 0 then
            if ebb >= STEPS then return end
            name, alt, slide = halt, halt_alt, false
        elseif early then
            -- (the sliding set repeats: this early its far end would show ahead of the front)
            return
        elseif rb >= SHORE_BAND or rb * e[6] >= 2.9 then
            return
        elseif la > SHORE_MID then
            name, alt = e[7], e[9]
        elseif on then
            name, alt = e[15], e[16]
        elseif e[14] then
            name, alt = e[10], e[11]
        else
            name, alt = e[2], e[8]
        end
        local function have(k) return state.sets[k] or state.partial[k] end
        -- (a land tile needs its sliding set and its thinning set at the same lean, or the front would kink)
        if not have(name) or on and la <= SHORE_MID and not (have(e[15]) and have(halt)) then
            local n = 0
            for _, t in ipairs{state.sets, state.partial} do
                for k in pairs(t) do
                    if k:byte(1) == 115 and k:byte(2) == 104 then n = n + (k:find('_ebb', 1, true) and 1 / EBB_DIV or 1) end
                end
            end
            if n >= SHORE_SETS then name = alt end
        end
        if not name then return end
        local set = state.sets[name]
        if not set and budget > 0 then
            budget = bake_some(name, budget)
            set = state.sets[name]
        end
        if on and budget > 0 and not state.sets[halt] and name == e[15] then budget = bake_some(halt, budget) end
        if not set then return end
        local f = ebb and ebb // EBB_DIV
        if slide then
            local a = e[3] + e[4] * rb
            f = math.floor((e[5] and SHORE_X0 - (N - 1) + a or SHORE_X0 - a) + 0.5) % STEPS
        end
        return getTexpos(set[f + 1][(y % 4) * 4 + (x % 4) + 1])
    end
    local gaps = SEA_COVER < 1
    local mvp = df.global.gps.main_viewport
    local under, dim_y, foam = SEA_UNDER and mvp[SEA_UNDER], mvp.dim_y, nil
    for i = 1, #list do
        local p = list[i]
        local key = p[3]
        foam = nil
        if key == 'sea' and tiled then
            key = tiled
        elseif key == 'sea' then
            local x, y = p[1], p[2]
            local e = shore and shore[y * 8192 + x]
            local ft = e and shore_tex(e, x, y, e[20])
            if ft then
                foam = ft
                if not (under and SEA_CAUSTICS) then
                    paint(pen, x - x1, y - y1, nil, foam, true)
                    goto next
                end
            end
            local h = wtiles and wtiles[y * 8192 + x]
            if h and x >= x1 and x <= x2 and y >= y1 and y <= y2 then
                local set = state.wsets[h[1]]
                if not set and budget > 0 then
                    budget = bake_wave(h[1], budget * 8) // 8
                    set = state.wsets[h[1]]
                end
                if set then
                    foam = getTexpos(set[h[2] + 1])
                    if not (under and SEA_CAUSTICS) then
                        paint(pen, x - x1, y - y1, nil, foam, true)
                        goto next
                    end
                end
            end
            local c = crests and crests[y * 8192 + x]
            if c == false and not wtiles and not shore then goto next end
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
                local still_pace = key == 'none' or key:sub(1, 6) == 'swell_' or key:sub(1, 4) == 'sea_'
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
    local beach = shore and state.shore and state.shore.beach
    if beach then
        for i = 1, #beach do
            local b = beach[i]
            local tex = not b[4] and shore_tex(b[3], b[1], b[2], true)
            if tex then paint(pen, b[1] - x1, b[2] - y1, nil, tex, true) end
        end
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
