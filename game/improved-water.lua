--@module = true
-- Caustics on water tiles, and the ocean's waves, wash, foam and spray (the WAVES part below).
-- Water plays 128 frames baked offline (improved-water-caustics.bin). Still water and the sea play them in place;
-- flowing water carries them along with the flow.
local overlay = require('plugins.overlay')
local guidm = require('gui.dwarfmode')

local N, TP, STEPS = 128, 32, 128       -- pattern size, tile px, loop length
STEP_MS = 80                             -- flowing water's pace on a map without a river
-- Packed 0xAABBGGRR. Measured blend (2026-11-18): out = colour*a^2 + background*(1-a),
-- so alpha below ~0.4 darkens dark water instead of lighting it.
HI = 0x84FFFF50
GLINT = 0xB0FFFFE0
-- Levels in the baked frames: 1 is a faint net, 2-3 (HI, GLINT) the bright points where its lines meet.
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
-- Flowing water: the frames are carried along with the flow at FLOW_STILL px per step, and the pattern itself
-- changes FLOW_ANIM frames per step, so its own shimmer is not drowned out by the drift. Whole numbers only,
-- so the 128-step loop closes without a jump.
FLOW_STILL = 1
FLOW_ANIM = 2
-- Where two flow directions meet, the tiles on both sides of the border show both directions' patterns
-- together, so lines fade across the border instead of being cut off at it.
-- true = the water stands still while the game is paused and carries on from the same frame after.
PAUSE_FREEZE = true
-- Sea water (salt, not flowing, on a map that has ocean waves) shows the still-water caustics without rings.
-- UNDER_LAYER: map viewport layer the caustics are written to, below the interface layer the waves and foam
-- are painted on, so those show over the caustics.
UNDER_LAYER = 'screentexpos_signpost'
-- SEA_WASH: also light the wave water that washes over the beach (OceanWave flows at least this dense; the
-- thinner ones are drawn as foam). false = sea tiles only. Tiles holding an item, creature or building are
-- left alone.
SEA_WASH = 20
-- The wash is lighter than the sea (about RGB 20,114,127), and by the blend above the sea's line colours come
-- out DARKER than it (measured: lines grey on the wash). These stronger ones lift it instead.
-- Both: level 1 line, 2 bright, 3 glint, 4 very faint halo, 5 crossing. On the sea the crossings are aqua and
-- lighter than the lines, about 33,127,132 on sea of 1,82,92 (white there came out grey, about 69,110,113).
SEA_COLS = {STILL_FAINT, HI, GLINT, STILL_VFAINT, 0x9EFFFF58}
WASH_COLS = {0x91FFFF40, 0x9EFFFF50, 0xADFFFFA0, 0x85FFFF40, 0xB8FFFF70}   -- lifts of about +19, +28, +42, +10, +42; crossings aqua, not white (white came out grey)
-- WAVES: also draw the ocean's waves, wash, foam and spray (see the WAVES part below). false = caustics only.
WAVES = true
state = state or {}

-- The data files and the art folder lie beside this script, wherever it was installed. If they are not
-- there, the place they were always copied to (dfhack-config/scripts) is tried.
local DATA_DIR = dfhack.getDFPath() .. '/dfhack-config/scripts/'
do
    local source = debug.getinfo(1, 'S').source
    local beside = source:sub(1, 1) == '@' and source:sub(2):match('^(.*[/\\])[^/\\]*$')
    local f = beside and io.open(beside .. 'improved-water-caustics.bin', 'rb')
    if f then
        f:close()
        DATA_DIR = beside
    end
end
state.sets = state.sets or {}            -- frame sets keyed by flow direction
state.stats = state.stats or {n=0, us=0}
state.clock = state.clock or dfhack.getTickCount()   -- ms of animation time
if state.layout ~= 2 then state.cache, state.layout = nil, 2 end   -- (older versions kept another water list)

-- df.tile_liquid_flow_dir -> screen vector (north is y-1)
local DIRS = {
    south={0, 1}, east={1, 0}, northeast={1, -1}, west={-1, 0}, northwest={-1, -1},
    southeast={1, 1}, southwest={-1, 1}, north={0, -1},
}

-- Reading one field of a game object costs about as much as ten Lua table lookups, so what can be worked
-- out once is: per flow direction and per tile type here, and a tile's flags are read whole and tested by bit.
local FLOW_FX, FLOW_FY, FLOWING = {}, {}, {}   -- by df.tile_liquid_flow_dir value
for value = df.tile_liquid_flow_dir._first_item, df.tile_liquid_flow_dir._last_item do
    local name = df.tile_liquid_flow_dir[value]
    local v = DIRS[name]
    if v then
        local n = (v[1] ~= 0 and v[2] ~= 0) and 0.7071 or 1
        FLOW_FX[value], FLOW_FY[value] = v[1] * n, v[2] * n
    end
    -- 'none' / 'down' = river water with no direction of its own (the column where a river leaves the
    -- map): it takes the direction of the river water around it. Ponds are 'inactive' and stay still.
    FLOWING[value] = (v or name == 'none' or name == 'down') and true or nil
end
-- df.tile_designation and df.tile_occupancy bits (measured in game)
local D_FLOW, D_HIDDEN, D_MAGMA, D_SALT = 0x7, 0x200, 0x200000, 0x80000000
local O_BUILDING, O_UNIT, O_TAKEN = 0x7, 0x18, 0x3F   -- unit: standing or lying; taken: building, creature or item
-- Tile kinds for the waves
local K_SEA, K_BOULDER, K_BEACH, K_ROCK, K_OTHER = 1, 2, 3, 4, 5
local OPEN = {}         -- tile type -> true: open space or the top of a ramp (what lies below shows through)
local LAND_KIND = {}    -- tile type -> its kind when there is no water in it
local WASH_UNDER = {}   -- tile type -> true: driftwood, shrub or sapling (the game draws it above the first floor layer)
local BUILT = {}        -- tile type -> true: a construction
local OPEN_TYPES, LAND_TYPES = {}, {}    -- the tile types in OPEN, and those whose LAND_KIND is not K_OTHER
do
    local attrs, shapes, materials = df.tiletype.attrs, df.tiletype_shape, df.tiletype_material
    -- Ground the wash thins out on. Rock and the sea don't stop the water.
    local beach = {
        [materials.SOIL] = true, [materials.DRIFTWOOD] = true,
        [materials.GRASS_LIGHT] = true, [materials.GRASS_DARK] = true,
        [materials.GRASS_DRY] = true, [materials.GRASS_DEAD] = true,
    }
    for tiletype = df.tiletype._first_item, df.tiletype._last_item do
        if df.tiletype[tiletype] then
            local shape, material = attrs[tiletype].shape, attrs[tiletype].material
            local plant = shape == shapes.SHRUB or shape == shapes.SAPLING
            OPEN[tiletype] = (shape == shapes.EMPTY or shape == shapes.RAMP_TOP) or nil
            WASH_UNDER[tiletype] = (material == materials.DRIFTWOOD or plant) or nil
            BUILT[tiletype] = material == materials.CONSTRUCTION or nil
            -- shrubs and saplings count as beach: they get the rim beside the water like the sand around them
            LAND_KIND[tiletype] = shape == shapes.BOULDER and K_BOULDER
                or (shape == shapes.FLOOR and beach[material] or plant) and K_BEACH
                or (shape == shapes.FLOOR or shape == shapes.PEBBLES) and K_ROCK
                or K_OTHER
            if OPEN[tiletype] then OPEN_TYPES[#OPEN_TYPES + 1] = tiletype end
            if LAND_KIND[tiletype] ~= K_OTHER then LAND_TYPES[#LAND_TYPES + 1] = tiletype end
        end
    end
end
local WAVE_FOAM_BELOW = 20    -- wave density below which the wash has broken up into foam
-- The wave flows found by the waves' last scan (see the WAVES part), shared with the caustics' wash.
local seen_waves = {n = 0, x = {}, y = {}, key = {}, density = {}}

-- Bake animation frame o (0-based) of one direction's loop from improved-water-caustics.bin: STEPS frames of
-- N x N bytes, 0 = unlit, 1-6 = level. Without that file there are no caustics.
-- Old textures are never freed: deleteHandle crashed DF (access violation, 2026-11-18).
local still_data
local function load_still()
    if still_data == nil then
        still_data = false
        local f = io.open(DATA_DIR .. 'improved-water-caustics.bin', 'rb')
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

-- Border between two flow directions: both patterns, the brighter one on top.
local RANK = {[0] = 0, 2, 3, 4, 1, 3, 0}
local function build_mix_frame(data, o, da, db)
    local pix, base = {}, (o * FLOW_ANIM % STEPS) * N * N
    local col = {[0] = 0, STILL_FAINT, HI, GLINT, STILL_VFAINT, STILL_CROSS, STILL_SHADOW}
    local ax, ay, bx, by = da[1] * FLOW_STILL * o, da[2] * FLOW_STILL * o, db[1] * FLOW_STILL * o, db[2] * FLOW_STILL * o
    for y = 0, N - 1 do
        local sa, sb = (y - ay) % N, (y - by) % N
        local ra = {data:byte(base + sa * N + 1, base + sa * N + N)}
        local rb = {data:byte(base + sb * N + 1, base + sb * N + N)}
        local at = y * N
        for x = 1, N do
            local a, b = ra[(x - 1 - ax) % N + 1], rb[(x - 1 - bx) % N + 1]
            if a > 6 then a = 0 end
            if b > 6 then b = 0 end
            pix[at + x] = col[RANK[a] >= RANK[b] and a or b]
        end
    end
    return dfhack.textures.createTileset(pix, N, N, TP, TP)
end

-- Ring events (improved-water-ripples.bin, made offline from the same frames): byte EV, byte LIFE,
-- EV x (tile position 0-15, start frame), then EV x LIFE x TP x TP level bytes. Each event is
-- one tile position's still-water pixels over LIFE frames with a ring drawn on top, so a map
-- tile can swap to it for the ring's life without a seam. Which tiles do so is decided per
-- tile and per occurrence by a hash, so rings do not repeat in a grid.
local ring_data
local function load_rings()
    if ring_data == nil then
        ring_data = false
        local f = io.open(DATA_DIR .. 'improved-water-ripples.bin', 'rb')
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
    if not rd then
        state.rings = {done = true}
        if load_still() then
            dfhack.printerr('improved-water: improved-water-ripples.bin is missing from ' .. DATA_DIR
                .. ' or the wrong size; no ripple rings are drawn')
        end
        return
    end
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

local function build_frame(data, dir, o)
    local da, db = dir:match('^(%a+)%+(%a+)$')
    if da then return build_mix_frame(data, o, DIRS[da], DIRS[db]) end
    local d = DIRS[dir]
    if d then return build_still_frame(data, o * FLOW_ANIM % STEPS, d[1] * FLOW_STILL * o, d[2] * FLOW_STILL * o) end
    return build_still_frame(data, o, 0, 0, dir)   -- 'none', 'sea' or 'wash'
end

-- Baking a whole loop takes ~0.7 s, so it is spread over render frames: bake_some() adds
-- up to BAKE_PER_FRAME frames per call, and a direction is only drawn once complete.
BAKE_PER_FRAME = 2
state.partial = state.partial or {}
local function bake_some(dir, budget)
    local data = load_still()
    if not data then
        if not state.warned then
            state.warned = true
            dfhack.printerr('improved-water: improved-water-caustics.bin is missing from ' .. DATA_DIR .. ' or the wrong size; no caustics are drawn')
        end
        return 0
    end
    local part = state.partial[dir] or {}
    state.partial[dir] = part
    while budget > 0 and #part < STEPS do
        part[#part + 1] = build_frame(data, dir, #part)
        budget = budget - 1
    end
    if #part == STEPS then
        state.sets[dir], state.partial[dir] = part, nil
    end
    return budget
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

-- df.prepare_read_fields sets up a read of chosen fields of everything in a list of game lists, done in
-- one call into the game. It is not in every DFHack: without it, or with one that answers differently
-- from the one this was written for, everything is read one field at a time, with the same result.
local prepareRead = df.prepare_read_fields
if prepareRead then
    local units = df.global.world.units.active
    local ok, read = pcall(prepareRead, units, {fields = {'_from', 'id'}})
    local out, count
    if ok and type(read) == 'function' then ok, out, count = pcall(read, {units, units}, {}) end
    if not (ok and type(out) == 'table' and type(count) == 'number' and type(out.id) == 'table'
            and type(out._from) == 'table' and count == 2 * #units) then
        prepareRead = nil
    end
end
-- Only the tiles that are seen and either hold liquid or let what lies below show through: their place in
-- the block (x * 16 + y), both flag words and the direction a river flows there. The list of open tile
-- types is filled in below. Many blocks are read in one call; _from is the block's place in that list.
local SEEN = {fields = {'_from', '_index', 'des', 'occ', 'flow.perm_flow_dir'}, where = {
    {'des.hidden', '==', false},
    {'or', {'des.flow_size', '>', 0}, {'and', {'tt', 'in', {}}, {'occ.building', '==', 0}}},
}}
do
    local open = SEEN.where[2][3][2][3]
    for tiletype in pairs(OPEN) do open[#open + 1] = tiletype end
end
-- the read itself, set up at the first scan (it needs a map block to see what it will be reading)
local read_seen
-- the blocks one call reads (each a table of its four grids), what the call returned, and for each
-- block its corner and the places in it where every level so far is open (false: all of them)
local seen_list, seen_sources, seen_read = {}, {}, {}
local scan_x, scan_y, scan_open, next_open = {}, {}, {}, {}
-- Whether a block's read can be limited to a rectangle of its tiles (a "_range" of x and y indexes
-- beside the grids): nil until tried on the first block. Tiles outside it are then never looked at.
local can_range
local function try_range(block)
    local ok, read = pcall(prepareRead, {des = block.designation}, {fields = {'_index'}})
    local out, count
    if ok and type(read) == 'function' then
        ok, out, count = pcall(read, {{des = block.designation, _range = {2, 3, 4, 5}}}, {})
    end
    local index = ok and type(out) == 'table' and out._index
    return type(index) == 'table' and count == 4
        and index[1] == 36 and index[2] == 37 and index[3] == 52 and index[4] == 53
end
-- the read of the dense waves for the wash (set up again when SEA_WASH changes), and its lists
local read_wash, wash_read_for
local wash_lists, wash_read = {}, {}

-- The visible water, grouped by what it plays: state.cache.groups[key] = {n, x, y, k, at}, with key a drift
-- direction ('north', 'east+north' on a border), 'none' (still), 'sea' or 'wash'; k is the tile's place in
-- the 4x4-tile pattern and at its index into the map's screen layers for the view it was scanned in.
local function water_map(vp)
    local z0 = vp.z
    local x1, y1, x2, y2 = vp.x1, vp.y1, vp.x2, vp.y2
    local now = dfhack.getTickCount()
    local same_view = state.vx1 == x1 and state.vy1 == y1 and state.vx2 == x2 and state.vy2 == y2 and state.z == z0
    -- rescan at most every 500 ms for a still view, and every 100 ms while panning (the
    -- list holds map coordinates, so a slightly stale one only misses newly exposed tiles)
    -- While the game is paused nothing on the map moves: a list made for this view at this game tick is
    -- kept until the view moves or the game runs again.
    if state.cache then
        local age = now - state.cache_at
        if age < 100 and state.z == z0 or age < 500 and same_view
                or same_view and state.cache_tick == df.global.cur_year_tick and df.global.pause_state then
            return state.cache
        end
    end
    local getFlags, getType, getBlock = dfhack.maps.getTileFlags, dfhack.maps.getTileType, dfhack.maps.getTileBlock
    local sea = sea_key()
    local M = SMOOTH + 1
    local W = x2 - x1 + 1 + 2 * M
    local zmin = math.max(0, z0 - 4)
    local fx, fy, water, flow_tables = {}, {}, {}, {}
    -- what shows at one tile, looking down through open space
    local function look(x, y)
        for z = z0, zmin, -1 do
            local d, occ = getFlags(x, y, z)
            if not d then return end
            local des = d.whole
            if des & D_HIDDEN ~= 0 then return end
            if des & D_FLOW ~= 0 then
                -- a bridge or other building here covers whatever is below it
                local taken = occ.whole
                if taken & O_BUILDING ~= 0 then return end
                if des & D_MAGMA == 0 then
                    local k = (y - y1 + M) * W + (x - x1 + M)
                    local block_key = (x >> 4) + (y >> 4) * 4096 + z * 16777216
                    local flows = flow_tables[block_key]
                    if flows == nil then
                        local b = getBlock(x, y, z)
                        flows = b and b.liquid_flow or false
                        flow_tables[block_key] = flows
                    end
                    local dir = flows and flows[x & 15][y & 15].perm_flow_dir
                    local flowing = dir and FLOWING[dir]
                    -- 1 = flowing, 2 = still, 3 = creature in the tile (leave it unlit), 4 = sea
                    water[k] = taken & O_UNIT ~= 0 and 3 or (flowing and 1 or (sea and des & D_SALT ~= 0) and 4 or 2)
                    if flowing and FLOW_FX[dir] then fx[k], fy[k] = FLOW_FX[dir], FLOW_FY[dir] end
                end
                return
            end
            -- (ground ends the look down, so only open space needs the building test)
            local tt = getType(x, y, z)
            if not tt or not OPEN[tt] or occ.whole & O_BUILDING ~= 0 then return end
        end
    end
    -- The view and one tile around it. Only flowing water needs the wider margin (its drift is averaged
    -- over the water within SMOOTH tiles), so that is looked at only when there is some.
    local any_flowing = false
    if prepareRead then
        -- The same result without walking every tile: df.prepare_read_fields' read hands back, for all the
        -- map blocks of one level at once, only the tiles that are seen and either hold liquid or are
        -- open with no building, which is all look() ever stops at or passes through. Below a block,
        -- the next level is read only if something in it is open.
        -- the rectangle ax1..ay2, leaving out the rectangle ix1..iy2 when given
        local function scan(ax1, ay1, ax2, ay2, ix1, iy1, ix2, iy2)
            local blocks = 0
            for block_y = ay1 - ay1 % 16, ay2, 16 do
                for block_x = ax1 - ax1 % 16, ax2, 16 do
                    blocks = blocks + 1
                    scan_x[blocks], scan_y[blocks], scan_open[blocks] = block_x, block_y, false
                end
            end
            for z = z0, zmin, -1 do
                -- the blocks still being looked down through that exist on this level
                local reading = 0
                for j = 1, blocks do
                    local b = getBlock(scan_x[j], scan_y[j], z)
                    if b then
                        reading = reading + 1
                        local source = seen_sources[reading]
                        if not source then
                            source = {}
                            seen_sources[reading] = source
                        end
                        source.des, source.occ, source.tt, source.flow =
                            b.designation, b.occupancy, b.tiletype, b.liquid_flow
                        if can_range == nil then can_range = try_range(b) end
                        if can_range then
                            -- only the part of the block inside the rectangle
                            local range = source._range
                            if not range then
                                range = {}
                                source._range = range
                            end
                            local block_x, block_y = scan_x[j], scan_y[j]
                            range[1] = ax1 > block_x and ax1 - block_x or 0
                            range[2] = ax2 < block_x + 15 and ax2 - block_x or 15
                            range[3] = ay1 > block_y and ay1 - block_y or 0
                            range[4] = ay2 < block_y + 15 and ay2 - block_y or 15
                        end
                        seen_list[reading] = source
                        scan_x[reading], scan_y[reading], scan_open[reading] = scan_x[j], scan_y[j], scan_open[j]
                        next_open[reading] = false
                    end
                end
                for j = #seen_list, reading + 1, -1 do seen_list[j] = nil end
                if reading == 0 then break end
                if not read_seen then read_seen = prepareRead(seen_list[1], SEEN) end
                local seen, count = read_seen(seen_list, seen_read)
                local from, index, deses, occs, dirs =
                    seen._from, seen._index, seen.des, seen.occ, seen['flow.perm_flow_dir']
                local at, block_x, block_y = 0
                local open          -- place in the block -> true: every level so far is open there
                local open_here
                for n = 1, count do
                    local block = from[n]
                    if block ~= at then
                        if at > 0 then next_open[at] = open_here end
                        at = block
                        block_x, block_y, open, open_here = scan_x[block], scan_y[block], scan_open[block], false
                    end
                    local i = index[n]
                    if not open or open[i] then
                        local des = deses[n]
                        if des & D_FLOW == 0 then
                            if not open_here then open_here = {} end
                            open_here[i] = true
                        else
                            local x, y = block_x + (i >> 4), block_y + (i & 15)
                            local taken = occs[n]
                            if x >= ax1 and x <= ax2 and y >= ay1 and y <= ay2
                                    and not (ix1 and x >= ix1 and x <= ix2 and y >= iy1 and y <= iy2)
                                    and taken & O_BUILDING == 0 and des & D_MAGMA == 0 then
                                local k = (y - y1 + M) * W + (x - x1 + M)
                                local dir = dirs[n]
                                local flowing = FLOWING[dir]
                                water[k] = taken & O_UNIT ~= 0 and 3
                                    or (flowing and 1 or (sea and des & D_SALT ~= 0) and 4 or 2)
                                if flowing then
                                    any_flowing = true
                                    if FLOW_FX[dir] then fx[k], fy[k] = FLOW_FX[dir], FLOW_FY[dir] end
                                end
                            end
                        end
                    end
                end
                if at > 0 then next_open[at] = open_here end
                -- carry on below the blocks that have something open
                blocks = 0
                for j = 1, reading do
                    local open_below = next_open[j]
                    if open_below then
                        blocks = blocks + 1
                        scan_x[blocks], scan_y[blocks], scan_open[blocks] = scan_x[j], scan_y[j], open_below
                    end
                end
                if blocks == 0 then break end
            end
        end
        scan(x1 - 1, y1 - 1, x2 + 1, y2 + 1)
        if any_flowing then scan(x1 - M, y1 - M, x2 + M, y2 + M, x1 - 1, y1 - 1, x2 + 1, y2 + 1) end
    else
        for y = y1 - 1, y2 + 1 do
            for x = x1 - 1, x2 + 1 do
                look(x, y)
                if water[(y - y1 + M) * W + (x - x1 + M)] == 1 then any_flowing = true end
            end
        end
        if any_flowing then
            for y = y1 - M, y2 + M do
                local inside = y >= y1 - 1 and y <= y2 + 1
                for x = x1 - M, x2 + M do
                    if not (inside and x >= x1 - 1 and x <= x2 + 1) then look(x, y) end
                end
            end
        end
    end
    local dm = {}
    for y = y1 - 1, y2 + 1 do
        for x = x1 - 1, x2 + 1 do
            local cy, cx = y - y1 + M, x - x1 + M
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
    local mvp = df.global.gps.main_viewport
    local dim_x, dim_y = mvp.dim_x, mvp.dim_y
    local cache = {n = 0, groups = {}, order = {}, x1 = x1, y1 = y1, dim_x = dim_x, dim_y = dim_y, fits = true}
    local groups, order = cache.groups, cache.order
    local function add(x, y, key)
        local g = groups[key]
        if not g then
            g = {n = 0, x = {}, y = {}, k = {}, at = {}}
            groups[key] = g
            order[#order + 1] = key
        end
        local n = g.n + 1
        local sx, sy = x - x1, y - y1
        if sx >= dim_x or sy >= dim_y then cache.fits = false end
        g.n, g.x[n], g.y[n], g.k[n], g.at[n] = n, x, y, (y % 4) * 4 + (x % 4) + 1, sx * dim_y + sy
        cache.n = cache.n + 1
    end
    local NB = {-W - 1, -W, -W + 1, -1, 1, W - 1, W, W + 1}
    for y = y1, y2 do
        for x = x1, x2 do
            local at = (y - y1 + M) * W + (x - x1 + M)
            local d = dm[at]
            if d then
                if DIRS[d] then
                    for i = 1, 8 do
                        local nd = dm[at + NB[i]]
                        if nd and nd ~= d and DIRS[nd] then d = d < nd and d .. '+' .. nd or nd .. '+' .. d; break end
                    end
                end
                add(x, y, d)
            end
        end
    end
    if sea and SEA_WASH then
        local function wash(x, y)
            if x >= x1 and x <= x2 and y >= y1 and y <= y2 then
                local at = (y - y1 + M) * W + (x - x1 + M)
                if not dm[at] and not water[at] then
                    local d, occ = getFlags(x, y, z0)
                    if d and d.whole & D_HIDDEN == 0 and occ.whole & O_TAKEN == 0 then
                        dm[at] = 'wash'
                        add(x, y, 'wash')
                    end
                end
            end
        end
        local sw = seen_waves
        if WAVES and SEA_WASH >= WAVE_FOAM_BELOW and sw.z == z0 and sw.tick == df.global.cur_year_tick
                and sw.x1 == x1 and sw.y1 == y1 and sw.x2 == x2 and sw.y2 == y2 then
            -- the waves' scan has read these flows on this very tick
            local wx, wy, density = sw.x, sw.y, sw.density
            for i = 1, sw.n do
                if density[i] >= SEA_WASH then wash(wx[i], wy[i]) end
            end
        elseif prepareRead then
            -- one call for the wave flows of every block: only the dense enough waves come back
            local lists = 0
            for by = y1 - y1 % 16, y2, 16 do
                for bx = x1 - x1 % 16, x2, 16 do
                    local block = getBlock(bx, by, z0)
                    if block then
                        lists = lists + 1
                        wash_lists[lists] = block.flows
                    end
                end
            end
            for i = #wash_lists, lists + 1, -1 do wash_lists[i] = nil end
            if lists > 0 then
                if wash_read_for ~= SEA_WASH then
                    read_wash = prepareRead(wash_lists[1], {fields = {'pos.x', 'pos.y', 'pos.z'}, where = {
                        {'type', '==', df.flow_type.OceanWave}, {'density', '>=', SEA_WASH}}})
                    wash_read_for = SEA_WASH
                end
                local read, count = read_wash(wash_lists, wash_read)
                local xs, ys, zs = read['pos.x'], read['pos.y'], read['pos.z']
                for i = 1, count do
                    if zs[i] == z0 then wash(xs[i], ys[i]) end
                end
            end
        else
            local WAVE = df.flow_type.OceanWave
            for by = y1 - y1 % 16, y2, 16 do
                for bx = x1 - x1 % 16, x2, 16 do
                    local block = getBlock(bx, by, z0)
                    local flows = block and block.flows
                    for i = 0, flows and #flows - 1 or -1 do
                        local flow = flows[i]
                        if flow.type == WAVE and flow.density >= SEA_WASH then
                            local pos = flow.pos
                            if pos.z == z0 then wash(pos.x, pos.y) end
                        end
                    end
                end
            end
        end
    end
    if not same_view then state.view_id = (state.view_id or 0) + 1 end   -- a number that changes with the view
    state.vx1, state.vy1, state.vx2, state.vy2 = x1, y1, x2, y2
    state.cache, state.cache_at, state.z = cache, now, z0
    state.cache_tick = df.global.cur_year_tick
    return cache
end

----------------------------------------------------------------------------------------------
-- WAVES: the game's own ocean waves, drawn in graphics mode.
--
-- This part is the script of the Flowing Waves mod 1.3 by Poss (Steam Workshop 3829998283,
-- scripts_modactive/flowing_waves.lua), copied in and changed here. Its art is in
-- dfhack-config/scripts/improved-water-art/. Keep that mod's own overlay (flowing_waves.waves) disabled,
-- or both draw.
--
-- The game simulates waves washing up beaches as OceanWave and SeaFoam flows. ASCII mode draws
-- them, but graphics mode has no FLOW_ token for them, so they're invisible there. This part
-- finds those flows on the visible z-level and draws water where they are:
--   crests       on each incoming wave crossing the sea (the game keeps these apart from the flows)
--   wash         on every wave tile. A wave that has thinned below WAVE_FOAM_BELOW is drawn as foam instead.
--   rock fringe  on land beside the wash or the sea: the water laps onto it, with a foam rim
--   sea fringe   on sea beside the wash, so the wash runs into the sea without a seam
--   boulders     in or beside the wash: water swapped into the floor layer under the boulder
--   sea foam     on each SeaFoam tile: a still patch of bubbles that pop as the flow's density falls
--   spray        on each Steam flow over a wave or the sea, as whitecaps
--
-- Every RESCAN_MS the flows are read. When they, the terrain or the view have changed, every tile is
-- planned again (a "piece": sheet, row, layer, animation offset); when the picture changes the pieces
-- become a draw list; every frame the list is written. All of these are kept as parallel arrays that are
-- filled again in place, not as a table per tile.
--
--   improved-water waves                  show status
--   improved-water reload                 reload the wave art, e.g. after rebuilding it
--   improved-water timing                 time spent scanning, planning and drawing waves
----------------------------------------------------------------------------------------------
do
local FRAMES = 16             -- every animation is 16 frames
local TICKS_PER_FRAME = 10    -- the brook animation's pace: about 10 frames a second
local RESCAN_MS = 100         -- how often to look for wave flows again, at most
-- The game moves and thins the flows on every 10th tick only. In between they change just when an incoming
-- wave ends and breaks into new ones (measured over 2,400 ticks: 240 changes on a 10th tick, 20 others, each
-- of those on a tick where the number of incoming waves fell). So they are read again only then.
local FLOW_TICKS = 10
-- All incoming waves are read at least this often, in ticks; in between only those near the view (see
-- findCrests).
local CREST_SKIP_MAX = 10
local FORGET_FOAM_MS = 1000   -- how often to drop foam that has gone
local TERRAIN_RECHECK_MS = 1000  -- how often to check known tiles for digging and building
local SHORE_RADIUS = 10       -- how far to look for the sea when working out which way a shore faces

local FOAM_STAGES = 8         -- stages of the foam's life: 0 (nearly gone) to 7 (fresh)
local FOAM_VARIANTS = 4       -- different patches, picked by tile position
local SPRAY_FULL = 100        -- spray density drawn as fresh foam
local WHITECAP_MAX_STAGE = 3  -- spray on the water is drawn no heavier than this foam stage (thin strands)

local SWELL_WHITENESS = 4     -- swell sheet rows per heading: 0 far out to 3 about to break

local getTileFlags, getTileType, getTileBlock = dfhack.maps.getTileFlags, dfhack.maps.getTileType, dfhack.maps.getTileBlock
local getTexposByHandle = dfhack.textures.getTexposByHandle
local sizeof = df.sizeof

----------------------------------------------------------------------------------------------
-- Directions
----------------------------------------------------------------------------------------------

-- A tile is known by x + y * 4096 (plus z * 16777216 where the level matters), so its neighbours' keys
-- are a fixed step away. The four sides and four corners of a tile, in the order N, E, S, W, NE, NW, SE,
-- SW, with the bit each one has in the sheets' masks:
local DX = {0, 1, 0, -1, 1, -1, 1, -1}
local DY = {-1, 0, 1, 0, -1, -1, 1, 1}
local DKEY = {-4096, 1, 4096, -1, -4095, -4097, 4097, 4095}
local BIT = {1, 2, 4, 8, 16, 32, 64, 128}

-- The eight ways river water can flow, in the order vanilla's FLOWS page stores them (the
-- Flowing Waves mod's sheets use the same order): NW, NE, SE, SW, N, S, W, E.
local FLOW_DX = {-1, 1, 1, -1, 0, 0, -1, 1}
local FLOW_DY = {-1, -1, 1, 1, -1, 1, 0, 0}

----------------------------------------------------------------------------------------------
-- Art
----------------------------------------------------------------------------------------------

local art_dir = DATA_DIR .. 'improved-water-art/'

-- DFHack keeps every image it has loaded for the rest of the session, keyed by path, so loading
-- the same path again gives the old picture. To pick up rebuilt art, `improved-water reload` loads
-- fresh copies from improved-water-art/reloaded/ under new names.
reload_count = reload_count or 0

local function copy_file(from, to)
    local input = io.open(from, 'rb')
    if not input then return false end
    local data = input:read('a')
    input:close()
    local output = io.open(to, 'wb')
    if not output then return false end
    output:write(data)
    output:close()
    return true
end

local function art_path(name)
    if reload_count == 0 then return art_dir .. name end
    local copies = art_dir .. 'reloaded/'
    dfhack.filesystem.mkdir(copies)
    local copy = copies .. reload_count .. '-' .. name
    if not copy_file(art_dir .. name, copy) then return art_dir .. name end
    os.remove(copies .. (reload_count - 1) .. '-' .. name)   -- the previous reload's copy
    return copy
end

-- Not from DFHack's reserved texture range: it has 10,000 places for all tools together, and this art
-- alone is 12,736 tiles.
--
-- A sheet may come with a .rows file (written by tools/pack_sheets.py): the PNG then holds each different
-- row once, and the file gives, for every row of the full layout, the packed row with its picture. The
-- list returned is in the full layout either way, repeated rows sharing their tiles, so the rest of the
-- script does not know the difference.
local function load_tiles(name)
    local tiles = dfhack.textures.loadTileset(art_path(name), 32, 32, false)
    local file = io.open(art_dir .. name:gsub('%.png$', '.rows'), 'r')
    if not file or not tiles then
        if file then file:close() end
        return tiles
    end
    local packed_row, packed_rows = {}, 0
    for number in file:read('a'):gmatch('%d+') do
        local row = tonumber(number)
        packed_row[#packed_row + 1] = row
        if row >= packed_rows then packed_rows = row + 1 end
    end
    file:close()
    if packed_rows * FRAMES ~= #tiles then
        dfhack.printerr(('improved-water: %s holds %d tiles but its .rows file expects %d. If the files were '
            .. 'updated in a running game, run: improved-water reload. If that does not help, the two files '
            .. 'do not belong together: copy both in again, or run tools/pack_sheets.py on the folder.')
            :format(name, #tiles, packed_rows * FRAMES))
        return {}
    end
    local full = {}
    for row = 1, #packed_row do
        local from, to = packed_row[row] * FRAMES, (row - 1) * FRAMES
        for frame = 1, FRAMES do full[to + frame] = tiles[from + frame] end
    end
    return full
end

local SHEET_NAMES = {'wash', 'rock_fringe', 'sea_fringe', 'sea_foam', 'swell'}

-- Loaded on first use; `improved-water reload` clears this. A file that is missing or unreadable gives an empty
-- sheet: then no waves are drawn (the caustics still are) and it is said once, until the next reload.
local function load_sheets()
    local loaded = {
        wash = load_tiles('wash.png'),
        rock_fringe = load_tiles('rock_fringe.png'),
        sea_fringe = load_tiles('sea_fringe.png'),
        sea_foam = load_tiles('sea_foam.png'),
        swell = load_tiles('swell.png'),
    }
    for _, name in ipairs(SHEET_NAMES) do
        if not (loaded[name] and loaded[name][1]) then
            loaded.missing = name
            dfhack.printerr('improved-water: wave art sheet "' .. name .. '" did not load from ' .. art_dir
                .. ' - no waves are drawn (improved-water reload tries again)')
            break
        end
    end
    return loaded
end

-- A tile's texture number can change when the game resets its textures, so DFHack says to ask
-- for it rather than keep it. Asking is a call into the game, though, and a busy beach asks
-- for the same few hundred tiles thousands of times a second. So the answers are kept, and dropped
-- (texture_epoch goes up, and the draw lists are made again) once a second and whenever the first
-- tile of any sheet is seen to have moved, which is checked every frame.
local texpos_known, first_texpos = {}, {}
texture_epoch = texture_epoch or 0

local function forget_texposes()
    texture_epoch = texture_epoch + 1
    for _, name in ipairs(SHEET_NAMES) do
        texpos_known[name] = {}
        first_texpos[name] = getTexposByHandle(sheets[name][1])
    end
end

local function textures_moved()
    for i = 1, #SHEET_NAMES do
        local name = SHEET_NAMES[i]
        if getTexposByHandle(sheets[name][1]) ~= first_texpos[name] then return true end
    end
    return false
end

-- Each sheet holds rows of 16 frames; a row is known by the tile number of its first frame. A tile
-- shows frame (step + frame_shift) % FRAMES of its row.
--   wash sheet    one row: open water on every side. (The Flowing Waves mod's sheet has 256 rows, for
--                 the sides where the water stops and for each flow direction; with every side drawn as
--                 open water they all come to this one picture, so only it is kept.) The flow direction
--                 sets the frame shift, not the picture.
--   fringe sheets (rock and sea alike) a row for each combination of sides and corners that face the wash
--   foam sheet    a row for each (stage, sides joined to more foam or a wave, variant). The foam lies
--                 still; the frames only add a little static.
--   swell sheet   a row for each (heading, whiteness)
local function foam_row(stage, joined_sides, x, y)
    return ((stage * 16 + joined_sides) * FOAM_VARIANTS + (x * 7 + y * 13) % FOAM_VARIANTS) * FRAMES + 1
end

local HEADING_NORTH, HEADING_SOUTH, HEADING_EAST, HEADING_WEST = 0, 1, 2, 3

----------------------------------------------------------------------------------------------
-- Terrain
----------------------------------------------------------------------------------------------

-- The sea is water on this level, or open space with water just below it. That includes
-- the tops of ramps sloping down into the sea, which vanilla draws as sand at the waterline.
local function classify(tiletype, x, y, z)
    if not tiletype then return K_OTHER end
    local d = getTileFlags(x, y, z)
    if d then
        local des = d.whole
        if des & D_FLOW ~= 0 and des & D_MAGMA == 0 then return K_SEA end
    end
    if OPEN[tiletype] then
        d = getTileFlags(x, y, z - 1)
        if d then
            local des = d.whole
            if des & D_FLOW ~= 0 and des & D_MAGMA == 0 then return K_SEA end
        end
    end
    return LAND_KIND[tiletype]
end

-- Classifying a tile takes a few calls into the game, so the answer is kept for one round of
-- TERRAIN_RECHECK_MS (kind_now, for the level being drawn). It is worked out afresh every round, not only
-- when the tile type changes: whether a tile is sea depends on the water in it or just below it, which
-- comes and goes without the type changing. If a tile's kind or type is not what it was last time
-- (known_kind, known_type), the shoreline may have moved, so the shore directions worked out from
-- around that tile are dropped.
kind_now = kind_now or {}
known_kind = known_kind or {}
known_type = known_type or {}
shore_flow = shore_flow or {}
-- known_kind, known_type and shore_flow hold every tile ever classified, on every level looked at
-- (measured: about 11,000 more per level when the view is swept over a whole 192x192 map). Past
-- KNOWN_MAX tiles they are emptied at the start of a round and fill again from what is in view.
local KNOWN_MAX = 200000
known_count = known_count or 0
terrain_round = terrain_round or 0
plan_number = plan_number or 0
local level, level_key = -1, 0        -- the level kind_now is for
local shores_moved = false
-- A wave tile's wash depends only on the ground around it, so it too is kept for the round: the first
-- tile of its row (0 on a boulder: no wash piece), its frame shift and its layer.
local wash_first, wash_shift, wash_layer = {}, {}, {}

-- With df.prepare_read_fields a tile is not asked for on its own, and its kind is not worked out here: the
-- first time a round needs a tile of a map block, the game is asked twice for that block, with the rules
-- of classify() as the read's filter. One read gives the places of the sea tiles, the other the places and
-- tile types of the boulders, beach and rock that are not sea; every other tile of the block is K_OTHER.
-- The whole block goes into kind_now at once (round_blocks: block -> true, false where the map has no
-- block).
-- What a block gave is kept (known_blocks, per level); when a later round gives something else, the
-- shoreline may have moved, and the shore directions kept for the block and SHORE_RADIUS around it go.
-- A new round does not throw kind_now away (start_terrain_round): the blocks in it that are still near
-- the view are read again there and then, and one that gives what it gave before keeps its tiles as they
-- are. Only a block that changed is filled in again, and one that is no longer near the view is taken out.
known_blocks = known_blocks or {}
local round_blocks, blocks_for = {}, nil
local read_terrain_block
do
local read_sea, read_land, read_sea_alone, read_land_alone
local block_source, block_list = {}, {}
local spare_block = {sea = {}, land = {}}
local INDEX_KEY = {}    -- a tile's place in its block (x * 16 + y) -> what that adds to the block's key
for index = 0, 255 do INDEX_KEY[index] = (index >> 4) + (index & 15) * 4096 end
local SEA_HERE = {'and', {'des.flow_size', '>', 0}, {'des.liquid_type', '==', false}}
local SEA_BELOW = {'and', {'tt', 'in', OPEN_TYPES}, {'below.flow_size', '>', 0}, {'below.liquid_type', '==', false}}
-- Drops the shore directions worked out for the block whose corner is given and for SHORE_RADIUS around it.
function forget_shores(corner)
    for dy = -SHORE_RADIUS, 15 + SHORE_RADIUS do
        local row = corner + dy * 4096
        for dx = -SHORE_RADIUS, 15 + SHORE_RADIUS do shore_flow[row + dx] = nil end
    end
end

-- What a kept block adds to known_count: about as much as the tiles asked for in it, one by one, would.
BLOCK_COUNTS_AS = 76
function read_terrain_block(x, y, block_key, filled)
    local block = getTileBlock(x, y, level)
    local base = (x & -16) + (y & -16) * 4096
    if not block then
        if filled then
            for index = 0, 255 do kind_now[base + INDEX_KEY[index]] = nil end
        end
        round_blocks[block_key] = false
        -- a block that is not there is remembered as one with no sea and no land, so that the shores
        -- around it are worked out again when it appears
        local full = block_key + level_key
        local was = known_blocks[full]
        if not was then
            known_blocks[full] = {sea = {}, land = {}, sea_n = 0, land_n = 0}
            known_count = known_count + BLOCK_COUNTS_AS
        elseif was.sea_n > 0 or was.land_n > 0 then
            was.sea_n, was.land_n = 0, 0
            shores_moved = true
            forget_shores(base + level_key)
        end
        return
    end
    round_blocks[block_key] = true
    local below = level > 0 and getTileBlock(x, y, level - 1)
    block_source.tt, block_source.des = block.tiletype, block.designation
    block_list[1] = block_source
    local now = spare_block
    local sea, land = now.sea, now.land
    local sea_n, land_n, _
    if below then
        block_source.below = below.designation
        if not read_sea then
            local is_sea = {'or', SEA_HERE, SEA_BELOW}
            read_sea = prepareRead(block_source, {fields = {'_index'}, where = {is_sea}})
            read_land = prepareRead(block_source,
                {fields = {'_index', 'tt'}, where = {{'tt', 'in', LAND_TYPES}, {'not', is_sea}}})
        end
        _, sea_n = read_sea(block_list, sea)
        _, land_n = read_land(block_list, land)
    else
        block_source.below = nil
        if not read_sea_alone then
            read_sea_alone = prepareRead(block_source, {fields = {'_index'}, where = {SEA_HERE}})
            read_land_alone = prepareRead(block_source,
                {fields = {'_index', 'tt'}, where = {{'tt', 'in', LAND_TYPES}, {'not', SEA_HERE}}})
        end
        _, sea_n = read_sea_alone(block_list, sea)
        _, land_n = read_land_alone(block_list, land)
    end
    local sea_index, land_index, land_type = sea._index, land._index, land.tt
    local full = block_key + level_key
    local was = known_blocks[full]
    local same = was and was.sea_n == sea_n and was.land_n == land_n
    if same then
        local was_index = was.sea._index
        for i = 1, sea_n do
            if was_index[i] ~= sea_index[i] then same = false break end
        end
    end
    if same then
        local was_index, was_type = was.land._index, was.land.tt
        for i = 1, land_n do
            if was_index[i] ~= land_index[i] or was_type[i] ~= land_type[i] then same = false break end
        end
    end
    if same and filled then return end
    if filled then
        for index = 0, 255 do kind_now[base + INDEX_KEY[index]] = nil end
    end
    for i = 1, sea_n do kind_now[base + INDEX_KEY[sea_index[i]]] = K_SEA end
    for i = 1, land_n do kind_now[base + INDEX_KEY[land_index[i]]] = LAND_KIND[land_type[i]] end
    if same then return end
    if was then
        shores_moved = true
        forget_shores(base + level_key)
        spare_block = was
    else
        known_count = known_count + BLOCK_COUNTS_AS
        spare_block = {sea = {}, land = {}}
    end
    now.sea_n, now.land_n = sea_n, land_n
    known_blocks[full] = now
end

-- How far outside the view a block is still worth keeping: the plan asks for tiles a few beside the view
-- (PLAN_MARGIN and a neighbour), and for the sea within SHORE_RADIUS of those.
local KEEP = SHORE_RADIUS + 4
function start_terrain_round(x1, y1, x2, y2)
    if not prepareRead or blocks_for ~= kind_now or known_count > KNOWN_MAX then
        kind_now = {}
        return
    end
    local bx1, by1, bx2, by2 = (x1 - KEEP) // 16, (y1 - KEEP) // 16, (x2 + KEEP) // 16, (y2 + KEEP) // 16
    for block_key, there in pairs(round_blocks) do
        if not there then
            -- (nothing of it is in kind_now; it is looked for again when a tile of it is asked for)
            round_blocks[block_key] = nil
        else
            local bx, by = block_key % 4096, block_key // 4096
            if bx >= bx1 and bx <= bx2 and by >= by1 and by <= by2 then
                read_terrain_block(bx * 16, by * 16, block_key, true)
            else
                local base = bx * 16 + by * 16 * 4096
                for index = 0, 255 do kind_now[base + INDEX_KEY[index]] = nil end
                round_blocks[block_key] = nil
            end
        end
    end
end
end

local function terrain_miss(x, y, key)
    if prepareRead then
        if blocks_for ~= kind_now then round_blocks, blocks_for = {}, kind_now end
        local block_key = x // 16 + (y // 16) * 4096
        if round_blocks[block_key] == nil then
            read_terrain_block(x, y, block_key)
            local kind = kind_now[key]
            if kind then return kind end
        end
        -- (not kept for a tile off the map: no block would take it out of kind_now again)
        if round_blocks[block_key] then kind_now[key] = K_OTHER end
        return K_OTHER
    end
    local tiletype = getTileType(x, y, level)
    local kind = classify(tiletype, x, y, level)
    local full = key + level_key
    local was = known_kind[full]
    if was and (was ~= kind or known_type[full] ~= tiletype) then
        shores_moved = true
        for dy = -SHORE_RADIUS, SHORE_RADIUS do
            local row = full + dy * 4096
            for dx = -SHORE_RADIUS, SHORE_RADIUS do shore_flow[row + dx] = nil end
        end
    end
    if not was then known_count = known_count + 1 end
    known_kind[full], known_type[full] = kind, tiletype
    kind_now[key] = kind
    return kind
end

-- Which way a shore faces, from the sea within SHORE_RADIUS (nearer sea counts for more): the index
-- into the flow directions of the one pointing away from the sea.
local function shore_miss(x, y, full)
    local toward_sea_x, toward_sea_y = 0, 0
    for dy = -SHORE_RADIUS, SHORE_RADIUS do
        local ny = y + dy
        local row = ny * 4096
        for dx = -SHORE_RADIUS, SHORE_RADIUS do
            if dx ~= 0 or dy ~= 0 then
                local nx = x + dx
                if (kind_now[row + nx] or terrain_miss(nx, ny, row + nx)) == K_SEA then
                    local distance_squared = dx * dx + dy * dy
                    toward_sea_x = toward_sea_x + dx / distance_squared
                    toward_sea_y = toward_sea_y + dy / distance_squared
                end
            end
        end
    end
    local best, best_score = 5, -math.huge
    for index = 1, 8 do
        local dx, dy = FLOW_DX[index], FLOW_DY[index]
        local away_from_sea = -(dx * toward_sea_x + dy * toward_sea_y)
        local score = away_from_sea / math.sqrt(dx * dx + dy * dy)
        if score > best_score then best, best_score = index, score end
    end
    shore_flow[full] = best
    return best
end

-- Layers a piece can go on (see the pieces below)
local FLOOR, TOP, UNDER, NO_EDGE = 1, 2, 3, 4

-- Like vanilla river tiles, each wash tile runs a frame behind the one upstream of it, so the pattern
-- travels away from the sea.
-- Driftwood, shrubs and saplings: the game draws them on the second floor layer, where the wash would
-- go, and on top of the map the wash came out see-through, so the sand under the log looked dry. There
-- the wash takes the place of the sand, on the first floor layer, under the log or plant.
-- Every side is drawn as open water: the foam edge is not drawn inside the wash tile (the mod's way,
-- against sand) but as the rim on the dry tile beside it, the same rim as along the sea.
local function wash_miss(x, y, key)
    if (kind_now[key] or terrain_miss(x, y, key)) == K_BOULDER then
        -- a boulder keeps its own tile; the water goes under it
        wash_first[key] = 0
        return 0
    end
    -- Classify the four neighbours first: if one has changed kind since the last round, that clears the
    -- kept shore directions around it, this tile's among them, so the direction read below is fresh.
    for side = 1, 4 do
        local near = key + DKEY[side]
        if not kind_now[near] then terrain_miss(x + DX[side], y + DY[side], near) end
    end
    local full = key + level_key
    local facing = shore_flow[full] or shore_miss(x, y, full)
    local tiletype = getTileType(x, y, level)
    wash_first[key] = 1
    wash_shift[key] = -(x * FLOW_DX[facing] + y * FLOW_DY[facing])
    wash_layer[key] = (tiletype and WASH_UNDER[tiletype]) and UNDER or FLOOR
    return 1
end

----------------------------------------------------------------------------------------------
-- Finding waves
----------------------------------------------------------------------------------------------

-- Foam is born at density 47-95 and the game lowers it by 3 every hundred ticks or so. Its stage
-- is how far it has fallen from the density it was first seen at, so weak foam starts fresh too.
-- Foam that's gone is forgotten after a while.
foam_density = foam_density or {}
foam_seen = foam_seen or {}

local function forget_old_foam()
    local now = df.global.cur_year_tick
    for key, seen in pairs(foam_seen) do
        if now - seen > 1000 or now < seen then foam_seen[key], foam_density[key] = nil, nil end
    end
end

-- The flows found by the last scan: waves (in seen_waves, shared with the caustics), foam and spray.
local wave_x, wave_y, wave_key, wave_density = seen_waves.x, seen_waves.y, seen_waves.key, seen_waves.density
local wave_count = 0
local foam_x, foam_y, foam_stage, foam_count = {}, {}, {}, 0
-- the sea foam tiles of the last scan (their keys in foam_seen), for a look that skips the scan
local foam_full, foam_full_count = {}, 0
-- all the flows in the scanned blocks at the last scan, alive or not: how many, their densities added up,
-- and the same sum with each density times its place in the lists
local flows_listed, flows_density, flows_weighted = 0, 0, 0
local spray_x, spray_y, spray_stage, spray_count = {}, {}, {}, 0
-- one number per flow found (what it is, where, its stage), to tell whether anything has changed
local found, found_count = {}, 0

-- The game keeps flows per map block, so a scan reads every block the view touches: up to 15 tiles past
-- each edge of it. Only the flows within PLAN_MARGIN tiles of the view are listed for planning. Nothing
-- farther away can change a piece inside the view: a rim comes from a wave beside it (1 tile), or from a
-- boulder beside it that has a wave beside that (2 tiles). Foam farther away is still remembered (its
-- stage counts from the density it was first seen at), and all the flows still count in the sums that
-- tell whether anything has changed.
local PLAN_MARGIN = 2

-- With df.prepare_read_fields (see above) the flows of all the blocks are read in one call. Each way has
-- its own scan and its own check below; both list the same flows in the same order.
local READ_SCAN = {'type', 'density', 'pos.x', 'pos.y'}
local READ_DENSITY = {'density'}
-- the two reads, set up when first used (that needs a map block's list of flows)
local read_scan, read_density
local flow_lists, flows_read = {}, {}
-- the rectangle the two reads were set up for
local read_x1, read_y1, read_x2, read_y2

-- Sets up the two reads for a view. The game hands back only the flows that can matter: waves and spray
-- within PLAN_MARGIN tiles of the view, and all the foam (a foam's stage counts from the density it was
-- first seen at, so it is followed before it comes into view). flow_lists[1] must be filled in.
local function prepare_flow_reads(x1, y1, x2, y2)
    if read_scan and read_x1 == x1 and read_y1 == y1 and read_x2 == x2 and read_y2 == y2 then return end
    local flow_type = df.flow_type
    local where = {
        {'density', '>', 0},
        {'or', {'type', '==', flow_type.SeaFoam},
            {'and', {'type', 'in', {flow_type.OceanWave, flow_type.Steam}},
                {'pos.x', '>=', x1 - PLAN_MARGIN}, {'pos.x', '<=', x2 + PLAN_MARGIN},
                {'pos.y', '>=', y1 - PLAN_MARGIN}, {'pos.y', '<=', y2 + PLAN_MARGIN}}},
    }
    read_scan = prepareRead(flow_lists[1], {fields = READ_SCAN, where = where})
    read_density = prepareRead(flow_lists[1], {fields = READ_DENSITY, where = where})
    read_x1, read_y1, read_x2, read_y2 = x1, y1, x2, y2
end

-- Lists the flows of the map blocks on level z that the rectangle touches, in flow_lists. Returns
-- how many blocks that is.
local function list_flows(x1, y1, x2, y2, z)
    local lists = 0
    for block_y = y1 - y1 % 16, y2, 16 do
        for block_x = x1 - x1 % 16, x2, 16 do
            local block = getTileBlock(block_x, block_y, z)
            if block then
                lists = lists + 1
                flow_lists[lists] = block.flows
            end
        end
    end
    for i = #flow_lists, lists + 1, -1 do flow_lists[i] = nil end
    return lists
end

-- Reads the wave, foam and spray flows on level z in the map blocks that the rectangle touches. Each
-- field read from a flow is a call into the game, so each is read once. Returns whether the flows are
-- the same as at the last scan.
local function find_flows(x1, y1, x2, y2, z, tick)
    local OceanWave, SeaFoam, Steam = df.flow_type.OceanWave, df.flow_type.SeaFoam, df.flow_type.Steam
    local zkey = z * 16777216
    local waves, foams, sprays, n, same = 0, 0, 0, 0, true
    local near_x1, near_y1, near_x2, near_y2 = x1 - PLAN_MARGIN, y1 - PLAN_MARGIN, x2 + PLAN_MARGIN, y2 + PLAN_MARGIN
    local remembered = 0
    local listed, density_sum, weighted = 0, 0, 0
    for block_y = y1 - y1 % 16, y2, 16 do
        for block_x = x1 - x1 % 16, x2, 16 do
            local block = getTileBlock(block_x, block_y, z)
            local flows = block and block.flows
            if flows then
                -- (indexed: ipairs over one of the game's lists takes four times as long per item)
                local count = #flows
                local place = listed + 1
                listed = listed + count
                for i = 0, count - 1 do
                    local flow = flows[i]
                    local density = flow.density
                    density_sum = density_sum + density
                    weighted = weighted + density * (place + i)
                    local flow_type = density > 0 and flow.type
                    if flow_type == OceanWave or flow_type == SeaFoam or flow_type == Steam then
                        -- (a block's flows are all on the block's own level)
                        local pos = flow.pos
                        local x, y = pos.x, pos.y
                        local key = x + y * 4096
                        -- (only what is near the view is planned; see PLAN_MARGIN)
                        local near = x >= near_x1 and x <= near_x2 and y >= near_y1 and y <= near_y2
                        local code
                        if flow_type == OceanWave and density >= WAVE_FOAM_BELOW then
                            if near then
                                waves = waves + 1
                                wave_x[waves], wave_y[waves], wave_key[waves], wave_density[waves] = x, y, key, density
                                code = key
                            end
                        elseif flow_type == Steam then
                            if near then
                                local stage = density * FOAM_STAGES // SPRAY_FULL
                                if stage > FOAM_STAGES - 1 then stage = FOAM_STAGES - 1 end
                                sprays = sprays + 1
                                spray_x[sprays], spray_y[sprays], spray_stage[sprays] = x, y, stage
                                code = key + 33554432 + stage * 67108864
                            end
                        else
                            local stage
                            if flow_type == OceanWave then
                                -- the wave's last thin water, broken up into foam
                                stage = density * FOAM_STAGES // WAVE_FOAM_BELOW
                            else
                                local full = key + zkey
                                local born = foam_density[full]
                                if not born or density > born then
                                    born = density
                                    foam_density[full] = born
                                end
                                foam_seen[full] = tick
                                remembered = remembered + 1
                                foam_full[remembered] = full
                                stage = math.floor(density / born * FOAM_STAGES)
                                if stage > FOAM_STAGES - 1 then stage = FOAM_STAGES - 1 end
                                if stage < 0 then stage = 0 end
                            end
                            if near then
                                foams = foams + 1
                                foam_x[foams], foam_y[foams], foam_stage[foams] = x, y, stage
                                code = key + 16777216 + stage * 67108864
                            end
                        end
                        if code then
                            n = n + 1
                            if found[n] ~= code then
                                found[n] = code
                                same = false
                            end
                        end
                    end
                end
            end
        end
    end
    if n ~= found_count then same = false end
    wave_count, foam_count, spray_count, found_count = waves, foams, sprays, n
    foam_full_count = remembered
    flows_listed, flows_density, flows_weighted = listed, density_sum, weighted
    seen_waves.n, seen_waves.z, seen_waves.tick = waves, z, tick
    seen_waves.x1, seen_waves.y1, seen_waves.x2, seen_waves.y2 = x1, y1, x2, y2
    return same
end

-- The same scan, reading the flows of every block in one call (see prepare_flow_reads for which).
local function find_flows_read(x1, y1, x2, y2, z, tick)
    local OceanWave, SeaFoam, Steam = df.flow_type.OceanWave, df.flow_type.SeaFoam, df.flow_type.Steam
    local zkey = z * 16777216
    local waves, foams, sprays, n, same = 0, 0, 0, 0, true
    local near_x1, near_y1, near_x2, near_y2 = x1 - PLAN_MARGIN, y1 - PLAN_MARGIN, x2 + PLAN_MARGIN, y2 + PLAN_MARGIN
    local remembered = 0
    local listed, density_sum, weighted = 0, 0, 0
    if list_flows(x1, y1, x2, y2, z) > 0 then
        prepare_flow_reads(x1, y1, x2, y2)
        local read, count = read_scan(flow_lists, flows_read)
        local types, densities, xs, ys = read.type, read.density, read['pos.x'], read['pos.y']
        local place = listed
        listed = listed + count
        for i = 1, count do
            local density = densities[i]
            density_sum = density_sum + density
            weighted = weighted + density * (place + i)
            local flow_type = density > 0 and types[i]
            if flow_type == OceanWave or flow_type == SeaFoam or flow_type == Steam then
                local x, y = xs[i], ys[i]
                local key = x + y * 4096
                -- (only what is near the view is planned; see PLAN_MARGIN)
                local near = x >= near_x1 and x <= near_x2 and y >= near_y1 and y <= near_y2
                local code
                if flow_type == OceanWave and density >= WAVE_FOAM_BELOW then
                    if near then
                        waves = waves + 1
                        wave_x[waves], wave_y[waves], wave_key[waves], wave_density[waves] = x, y, key, density
                        code = key
                    end
                elseif flow_type == Steam then
                    if near then
                        local stage = density * FOAM_STAGES // SPRAY_FULL
                        if stage > FOAM_STAGES - 1 then stage = FOAM_STAGES - 1 end
                        sprays = sprays + 1
                        spray_x[sprays], spray_y[sprays], spray_stage[sprays] = x, y, stage
                        code = key + 33554432 + stage * 67108864
                    end
                else
                    local stage
                    if flow_type == OceanWave then
                        -- the wave's last thin water, broken up into foam
                        stage = density * FOAM_STAGES // WAVE_FOAM_BELOW
                    else
                        local full = key + zkey
                        local born = foam_density[full]
                        if not born or density > born then
                            born = density
                            foam_density[full] = born
                        end
                        foam_seen[full] = tick
                        remembered = remembered + 1
                        foam_full[remembered] = full
                        stage = math.floor(density / born * FOAM_STAGES)
                        if stage > FOAM_STAGES - 1 then stage = FOAM_STAGES - 1 end
                        if stage < 0 then stage = 0 end
                    end
                    if near then
                        foams = foams + 1
                        foam_x[foams], foam_y[foams], foam_stage[foams] = x, y, stage
                        code = key + 16777216 + stage * 67108864
                    end
                end
                if code then
                    n = n + 1
                    if found[n] ~= code then
                        found[n] = code
                        same = false
                    end
                end
            end
        end
    end
    if n ~= found_count then same = false end
    wave_count, foam_count, spray_count, found_count = waves, foams, sprays, n
    foam_full_count = remembered
    flows_listed, flows_density, flows_weighted = listed, density_sum, weighted
    seen_waves.n, seen_waves.z, seen_waves.tick = waves, z, tick
    seen_waves.x1, seen_waves.y1, seen_waves.x2, seen_waves.y2 = x1, y1, x2, y2
    return same
end
if prepareRead then find_flows = find_flows_read end

-- Between the game's own flow updates (see FLOW_TICKS) a flow can still start: steam where magma meets
-- water, on any tick. The game then adds a flow, or brings a spent one back to full, or tops one up: each
-- raises the densities added up. Other kinds of flow (fire, dust, smoke) fade on any tick too, so a second
-- sum weighs each density by its place, lest a fade cancel a start. This reads the densities only.
-- Returns whether the blocks' flows are as the last scan found them.
local function flows_untouched(x1, y1, x2, y2, z)
    local listed, density_sum, weighted = 0, 0, 0
    for block_y = y1 - y1 % 16, y2, 16 do
        for block_x = x1 - x1 % 16, x2, 16 do
            local block = getTileBlock(block_x, block_y, z)
            local flows = block and block.flows
            if flows then
                local count = #flows
                local place = listed + 1
                listed = listed + count
                for i = 0, count - 1 do
                    local density = flows[i].density
                    density_sum = density_sum + density
                    weighted = weighted + density * (place + i)
                end
            end
        end
    end
    return listed == flows_listed and density_sum == flows_density and weighted == flows_weighted
end

-- The same check, reading the densities of the same flows as that scan in one call.
local function flows_untouched_read(x1, y1, x2, y2, z)
    local listed, density_sum, weighted = 0, 0, 0
    if list_flows(x1, y1, x2, y2, z) > 0 then
        prepare_flow_reads(x1, y1, x2, y2)
        local read, count = read_density(flow_lists, flows_read)
        local densities = read.density
        listed = count
        for i = 1, count do
            local density = densities[i]
            density_sum = density_sum + density
            weighted = weighted + density * i
        end
    end
    return listed == flows_listed and density_sum == flows_density and weighted == flows_weighted
end
if prepareRead then flows_untouched = flows_untouched_read end

----------------------------------------------------------------------------------------------
-- Planning what to draw
----------------------------------------------------------------------------------------------

-- A piece is one tile of art at one map tile, ready to animate:
--   x, y         the map tile
--   sheet        the sheet's name
--   first        the tile number of frame 0 of its row
--   shift        added to the animation step, so neighbours aren't in step
--   layer        FLOOR     the map's second floor layer, under dwarves and items, or on top
--                          if that's taken
--                TOP       on top of the map
--                UNDER     the map's first floor layer (under a boulder, log or plant)
--                NO_EDGE   no art: only blanks the map's floor_flag layer here
--   clears       also blank the map's floor_flag layer here (the sand edge on the sea)
local piece_x, piece_y, piece_sheet, piece_first, piece_shift, piece_layer, piece_clears = {}, {}, {}, {}, {}, {}, {}
local piece_count = 0

-- Land beside the open sea (rock, sand, soil, grass, boulders; natural ground only, not built floors
-- beside a salt-water moat): the same rim as rock beside the wash. The sea tiles come from the caustics'
-- own scan of the view, so this is worked out again only when the view or the terrain round changes.
-- sea_rocks: n, x, y, mask (the sides and corners of the land tile that face the sea), and sea_n, sea_x,
-- sea_y: the sea tiles beside that land. The game draws the frayed edge of sand on those; with the rim
-- that edge would hang in the water, so it is switched off there.
sea_rocks = sea_rocks or {n = 0, sea_n = 0}
local function rocks_by_the_sea(z)
    local water = state.cache
    if not water or state.z ~= z then return nil end
    -- for a still view once per terrain round (a second), not at every water rescan
    if sea_rocks.view == state.view_id and sea_rocks.round == terrain_round then return sea_rocks end
    local rocks = {view = state.view_id, round = terrain_round, n = 0, x = {}, y = {}, mask = {}, sea_n = 0, sea_x = {}, sea_y = {}}
    local seen, land = {}, {}
    local sea = water.groups.sea
    for i = 1, sea and sea.n or 0 do
        local x, y = sea.x[i], sea.y[i]
        local key = x + y * 4096
        -- (the caustics also light water seen through open space further down; that is not a shore)
        if (kind_now[key] or terrain_miss(x, y, key)) == K_SEA then
            -- Open sea, with sea on all eight sides, has no land to find. (Only what is already known is
            -- looked at here; a side not yet classified sends the tile through the full check below.)
            if not (kind_now[key - 4096] == K_SEA and kind_now[key + 1] == K_SEA and kind_now[key + 4096] == K_SEA
                    and kind_now[key - 1] == K_SEA and kind_now[key - 4095] == K_SEA and kind_now[key - 4097] == K_SEA
                    and kind_now[key + 4097] == K_SEA and kind_now[key + 4095] == K_SEA) then
                local touches_land = false
                for d = 1, 8 do
                    local rock_key = key - DKEY[d]
                    if land[rock_key] then touches_land = true end
                    if not seen[rock_key] then
                        local rx, ry = x - DX[d], y - DY[d]
                        local kind = kind_now[rock_key] or terrain_miss(rx, ry, rock_key)
                        if kind == K_ROCK or kind == K_BEACH or kind == K_BOULDER then
                            seen[rock_key] = true
                            local tiletype = getTileType(rx, ry, z)
                            if tiletype and not BUILT[tiletype] then
                                -- The mask comes from the terrain, not from the water list: that list stops at
                                -- the view's edge and leaves out tiles with a creature in them.
                                local mask = 0
                                for side = 1, 8 do
                                    local near = rock_key + DKEY[side]
                                    if (kind_now[near] or terrain_miss(rx + DX[side], ry + DY[side], near)) == K_SEA then
                                        mask = mask + BIT[side]
                                    end
                                end
                                local n = rocks.n + 1
                                rocks.n, rocks.x[n], rocks.y[n], rocks.mask[n] = n, rx, ry, mask
                                land[rock_key] = true
                                touches_land = true
                            end
                        end
                    end
                end
                if touches_land then
                    local n = rocks.sea_n + 1
                    rocks.sea_n, rocks.sea_x[n], rocks.sea_y[n] = n, x, y
                end
            end
        end
    end
    sea_rocks = rocks
    return rocks
end

-- Plans the pieces from the flows found, in drawing order:
--   wash         on each wave
--   foam         on each foam patch, joined to neighbouring foam and waves
--   fringes      land and sea tiles beside the wash, with the sides and corners that face it
--   boulders     boulders in or beside the wash
--   whitecaps    the spray that's over a wave or the sea, last so it covers the rest
-- The plan's own notes are kept from one plan to the next, so that it does not make and throw away a
-- dozen tables several times a second. A mark on a tile (a wave is here, a fringe is here...) holds the
-- number of the plan that made it, and counts only in that plan; the lists are overwritten from the start.
local plan_marks = 0
local wave_at, foam_at, boulder_at, cap_at, fringe_at, fringe_index = {}, {}, {}, {}, {}, {}
local left_x, left_y, left_stage, left_key = {}, {}, {}, {}
local fringe_x, fringe_y, fringe_mask, fringe_is_sea = {}, {}, {}, {}
local boulder_x, boulder_y, boulder_key = {}, {}, {}
local cap_x, cap_y, cap_stage, cap_key = {}, {}, {}, {}

local function plan(z)
    local n = 0
    plan_marks = plan_marks + 1
    local mark = plan_marks
    if mark % 4096 == 0 then
        -- (so the marks of places looked at long ago don't pile up)
        wave_at, foam_at, boulder_at, cap_at, fringe_at, fringe_index = {}, {}, {}, {}, {}, {}
    end
    local function piece(x, y, sheet, first, shift, layer, clears)
        n = n + 1
        piece_x[n], piece_y[n], piece_sheet[n], piece_first[n], piece_shift[n], piece_layer[n], piece_clears[n] =
            x, y, sheet, first, shift, layer, clears
    end

    for i = 1, wave_count do wave_at[wave_key[i]] = mark end

    for i = 1, wave_count do
        local key = wave_key[i]
        local first = wash_first[key] or wash_miss(wave_x[i], wave_y[i], key)
        if first ~= 0 then
            n = n + 1
            piece_x[n], piece_y[n], piece_sheet[n], piece_first[n], piece_shift[n], piece_layer[n], piece_clears[n] =
                wave_x[i], wave_y[i], 'wash', first, wash_shift[key], wash_layer[key], false
        end
    end

    -- A foam patch runs into neighbouring foam and waves; towards bare ground it frays out.
    -- Foam is what the water leaves behind: none on a tile a wave is covering, none on the sea.
    local left = 0
    for i = 1, foam_count do
        local x, y = foam_x[i], foam_y[i]
        local key = x + y * 4096
        if wave_at[key] ~= mark and (kind_now[key] or terrain_miss(x, y, key)) ~= K_SEA then
            left = left + 1
            left_x[left], left_y[left], left_stage[left], left_key[left] = x, y, foam_stage[i], key
            foam_at[key] = mark
        end
    end
    for i = 1, left do
        local x, y, key = left_x[i], left_y[i], left_key[i]
        local joined_sides = 0
        for side = 1, 4 do
            local near = key + DKEY[side]
            if wave_at[near] == mark or foam_at[near] == mark then joined_sides = joined_sides + BIT[side] end
        end
        -- out of step with its neighbours, so the static doesn't pulse across a patch
        piece(x, y, 'sea_foam', foam_row(left_stage[i], joined_sides, x, y), x * 3 + y * 5, FLOOR, false)
    end

    -- Land and sea around the waves, and boulders on or beside them.
    local fringes, boulders = 0, 0
    local function fringe(x, y, key, is_sea, mask)
        local f
        if fringe_at[key] == mark then
            f = fringe_index[key]
        else
            fringes = fringes + 1
            f = fringes
            fringe_at[key], fringe_index[key] = mark, f
            fringe_x[f], fringe_y[f], fringe_mask[f], fringe_is_sea[f] = x, y, 0, is_sea
        end
        -- (a mask of bits, so OR-ing in sides already set is harmless)
        fringe_mask[f] = fringe_mask[f] | mask
    end
    for i = 1, wave_count do
        local x, y, key = wave_x[i], wave_y[i], wave_key[i]
        if boulder_at[key] ~= mark and (kind_now[key] or terrain_miss(x, y, key)) == K_BOULDER then
            boulder_at[key] = mark
            boulders = boulders + 1
            boulder_x[boulders], boulder_y[boulders], boulder_key[boulders] = x, y, key
        end
        for side = 1, 4 do
            local near = key + DKEY[side]
            if boulder_at[near] ~= mark then
                local bx, by = x + DX[side], y + DY[side]
                if (kind_now[near] or terrain_miss(bx, by, near)) == K_BOULDER then
                    boulder_at[near] = mark
                    boulders = boulders + 1
                    boulder_x[boulders], boulder_y[boulders], boulder_key[boulders] = bx, by, near
                end
            end
        end
        -- Seen from the fringe tile, the wave lies in direction d.
        for d = 1, 8 do
            local near = key - DKEY[d]
            if wave_at[near] ~= mark then
                local fx, fy = x - DX[d], y - DY[d]
                local kind = kind_now[near] or terrain_miss(fx, fy, near)
                if kind == K_ROCK or kind == K_BEACH or kind == K_SEA then
                    fringe(fx, fy, near, kind == K_SEA, BIT[d])
                end
            end
        end
    end
    -- A boulder on or beside a wave gets water under it (below), so to the land next to it that
    -- boulder is water too: the rim also runs along the side facing the boulder.
    for i = 1, boulders do
        local x, y, key = boulder_x[i], boulder_y[i], boulder_key[i]
        for d = 1, 8 do
            local near = key - DKEY[d]
            if wave_at[near] ~= mark then
                local fx, fy = x - DX[d], y - DY[d]
                local kind = kind_now[near] or terrain_miss(fx, fy, near)
                if kind == K_ROCK or kind == K_BEACH then fringe(fx, fy, near, false, BIT[d]) end
            end
        end
    end
    local shore = rocks_by_the_sea(z)
    if shore then
        for i = 1, shore.sea_n do
            local x, y = shore.sea_x[i], shore.sea_y[i]
            if fringe_at[x + y * 4096] ~= mark then piece(x, y, 'sea_foam', 1, 0, NO_EDGE, false) end
        end
        for i = 1, shore.n do
            local x, y = shore.x[i], shore.y[i]
            local key = x + y * 4096
            if wave_at[key] ~= mark then fringe(x, y, key, false, shore.mask[i]) end
        end
    end
    for f = 1, fringes do
        -- floor_flag draws the sand's edge on the sea; the sea fringe replaces it
        local is_sea = fringe_is_sea[f]
        piece(fringe_x[f], fringe_y[f], is_sea and 'sea_fringe' or 'rock_fringe', fringe_mask[f] * FRAMES + 1, 0,
            is_sea and FLOOR or TOP, is_sea)
    end
    for i = 1, boulders do
        -- The boulder is drawn on the second floor layer, over this one. Under it goes the same
        -- wash as on the tiles around it (same colour, same moving pattern), not a flat square.
        local x, y, key = boulder_x[i], boulder_y[i], boulder_key[i]
        local full = key + level_key
        local facing = shore_flow[full] or shore_miss(x, y, full)
        piece(x, y, 'wash', 1, -(x * FLOW_DX[facing] + y * FLOW_DY[facing]), UNDER, false)
    end

    -- Spray shows as whitecaps only on the water: over a wave or the sea. Whitecaps join up
    -- with each other.
    local caps = 0
    for i = 1, spray_count do
        local x, y = spray_x[i], spray_y[i]
        local key = x + y * 4096
        if wave_at[key] == mark or (kind_now[key] or terrain_miss(x, y, key)) == K_SEA then
            caps = caps + 1
            cap_x[caps], cap_y[caps], cap_stage[caps], cap_key[caps] = x, y, spray_stage[i], key
            cap_at[key] = mark
        end
    end
    for i = 1, caps do
        local x, y, key = cap_x[i], cap_y[i], cap_key[i]
        local joined_sides = 0
        for side = 1, 4 do
            if cap_at[key + DKEY[side]] == mark then joined_sides = joined_sides + BIT[side] end
        end
        -- never the solid patches of fresh beach foam: on the water those read as foam left on sand
        local stage = cap_stage[i]
        if stage > WHITECAP_MAX_STAGE then stage = WHITECAP_MAX_STAGE end
        piece(x, y, 'sea_foam', foam_row(stage, joined_sides, x, y), x * 3 + y * 5, TOP, false)
    end

    piece_count = n
    plan_number = plan_number + 1
end

----------------------------------------------------------------------------------------------
-- Timing (`improved-water timing`)
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
    self.next_scan = 0
    self.next_foam_cleanup = 0
    self.next_terrain_round = 0
    self.replan = true
    -- the draw list: for each piece in view its layer, screen position, index into the map's screen
    -- layers (-1 if outside them), texture, and whether it clears the floor_flag layer
    self.draw_layer, self.draw_sx, self.draw_sy, self.draw_index, self.draw_texpos, self.draw_clears = {}, {}, {}, {}, {}, {}
    self.draw_count = 0
    self.crest_sx, self.crest_sy, self.crest_texpos, self.crest_count = {}, {}, {}, 0
    -- places in the game's list of the incoming waves near the view (see findCrests)
    self.crest_near, self.crest_near_count = {}, 0
end

function WavesOverlay:rescan(viewport, now, tick)
    local started = dfhack.getTickCount()
    local z = viewport.z
    if now >= self.next_terrain_round then
        terrain_round = terrain_round + 1
        self.next_terrain_round = now + TERRAIN_RECHECK_MS
        start_terrain_round(viewport.x1, viewport.y1, viewport.x2, viewport.y2)
        wash_first, wash_shift, wash_layer = {}, {}, {}
        if known_count > KNOWN_MAX then
            known_kind, known_type, known_blocks, shore_flow, known_count = {}, {}, {}, {}, 0
        end
        forget_texposes()
    end
    if z ~= level then
        level, level_key = z, z * 16777216
        kind_now, wash_first, wash_shift, wash_layer = {}, {}, {}, {}
    end
    local same_flows = find_flows(viewport.x1, viewport.y1, viewport.x2, viewport.y2, z, tick)
    timed_since('  finding flows', started)
    if now >= self.next_foam_cleanup then
        forget_old_foam()
        self.next_foam_cleanup = now + FORGET_FOAM_MS
    end
    self.scan_period, self.flows_stale, self.scan_water = tick // FLOW_TICKS, false, state.view_id
    self.scan_x1, self.scan_y1, self.scan_x2, self.scan_y2, self.scan_z = viewport.x1, viewport.y1, viewport.x2, viewport.y2, z
    -- The plan follows from the flows, the terrain (fixed for a round) and the caustics' water list (the
    -- rim along the sea, worked out once per view and round): if none of those has changed, it stands.
    local has_water = state.cache ~= nil and state.z == z
    if same_flows and not self.replan and self.plan_round == terrain_round and self.plan_z == z
            and self.plan_water == state.view_id and self.plan_has_water == has_water then
        timed_since('scan and plan', started)
        return
    end
    local planning = dfhack.getTickCount()
    plan(z)
    self.plan_round, self.plan_z, self.plan_water, self.plan_has_water = terrain_round, z, state.view_id, has_water
    -- If the shoreline moved while planning, some of this plan was made with the old shore directions:
    -- plan again in the next frame.
    self.replan = shores_moved
    if shores_moved then
        shores_moved = false
        wash_first, wash_shift, wash_layer = {}, {}, {}
    end
    timed_since('  planning', planning)
    timed_since('scan and plan', started)
end

-- Turns the pieces into what to write for this step and view.
function WavesOverlay:buildDrawList(viewport, port, step)
    local x1, y1, x2, y2 = viewport.x1, viewport.y1, viewport.x2, viewport.y2
    local dim_y, layer_size = port.dim_y, port.dim_x * port.dim_y
    local d_layer, d_sx, d_sy, d_index, d_texpos, d_clears =
        self.draw_layer, self.draw_sx, self.draw_sy, self.draw_index, self.draw_texpos, self.draw_clears
    local n = 0
    for i = 1, piece_count do
        local x, y = piece_x[i], piece_y[i]
        if x >= x1 and x <= x2 and y >= y1 and y <= y2 then
            local sx, sy = x - x1, y - y1
            local index = sx * dim_y + sy
            if index < 0 or index >= layer_size then index = -1 end
            local layer = piece_layer[i]
            if layer == NO_EDGE then
                if index >= 0 then
                    n = n + 1
                    d_layer[n], d_index[n] = NO_EDGE, index
                end
            elseif layer ~= UNDER or index >= 0 then
                local sheet = piece_sheet[i]
                local known = texpos_known[sheet]
                local tile = piece_first[i] + (step + piece_shift[i]) % FRAMES
                local texpos = known[tile]
                if not texpos then
                    texpos = getTexposByHandle(sheets[sheet][tile])
                    known[tile] = texpos
                end
                n = n + 1
                d_layer[n], d_sx[n], d_sy[n], d_index[n], d_texpos[n], d_clears[n] =
                    layer, sx, sy, index, texpos, piece_clears[i]
            end
        end
    end
    self.draw_count = n
end

-- Writes the draw list. The map's screen layers are rebuilt by the game every frame and drawn
-- after overlays render, so anything written to them lasts exactly one frame and has to be
-- written again each frame.
-- Fog and rain of the Detailed Weather mod. Its overlay (detailed_weather.map_drawn) draws haze and rain
-- pictures on the interface layer of the map tiles in view, after this overlay has painted (measured: 187
-- pieces painted, all 187 there right after, none left when the frame is shown; with that overlay off the
-- layer stays empty, also in thick fog). So a piece painted on top (foam rims, foam, spray, crests) is
-- lost wherever something else is drawn on top afterwards: everywhere in the mod's fog, and under one of
-- its rain pictures. The layer's copy of the last frame tells where that is: a cell that holds something
-- this script did not paint there. On those cells the piece goes to the layer just below instead, where
-- it shows through like the rest of the map. This is decided per cell, because a whole-view rule
-- misjudges: a foggy view can be 17% clear (rock wall), and rain alone covered 7.6% of a clear one (both
-- measured).
local FOG_LAYER = 'screentexpos_designation'

-- What this script painted on top, per cell of the view: top_last in the frame before (what the layer's
-- copy is compared with), top_mine in this one. Two tables, because a cell can get two pieces in one
-- frame (a rim and foam on driftwood, a crest and a whitecap): both must be judged by last frame's result.
-- They swap after each frame. Kept across a re-run of the script.
top_mine = top_mine or {}
top_last = top_last or {}

function WavesOverlay:draw(port, screen_x, screen_y)
    local under_fog, mine, last_mine, last_top = port[FOG_LAYER], top_mine, top_last, port.screentexpos_interface_old
    local floor_two = port.screentexpos_background_two
    local floor_one = port.screentexpos_background
    local floor_flag = port.screentexpos_floor_flag
    local paint = dfhack.screen.paintTile
    local d_layer, d_sx, d_sy, d_index, d_texpos, d_clears =
        self.draw_layer, self.draw_sx, self.draw_sy, self.draw_index, self.draw_texpos, self.draw_clears
    for i = 1, self.draw_count do
        local index, layer = d_index[i], d_layer[i]
        if layer == NO_EDGE then
            floor_flag[index] = 0
        elseif layer == UNDER then
            floor_one[index] = d_texpos[i]
        elseif layer == FLOOR and index >= 0 and floor_two[index] == 0 then
            -- under dwarves, items and driftwood
            floor_two[index] = d_texpos[i]
            if d_clears[i] then floor_flag[index] = 0 end
        else
            local theirs = index >= 0 and last_top[index] or 0
            if theirs ~= 0 and theirs ~= last_mine[index] then
                under_fog[index] = d_texpos[i]
            else
                paint(TILE_PEN, screen_x + d_sx[i], screen_y + d_sy[i], ' ', d_texpos[i], true)
                if index >= 0 then mine[index] = d_texpos[i] end
            end
            if index >= 0 and d_clears[i] then floor_flag[index] = 0 end
        end
    end
end

-- The incoming crests in view: where each is, which way it's heading (diagonals go by their
-- north/south part), and how white it is, from how close it is to breaking on the beach.
-- Crests move every few ticks, so their draw list is made again whenever the game ticks (or
-- the view moves). Reading every incoming wave on the map, on a big sea a hundred or more, is dear, and
-- a wave moves at most one tile a tick (measured: 218,000 wave moves of 0 or 1 tile). So all of them are
-- read only every CREST_SKIP_MAX ticks (full), or when the waves or the view have changed; that read
-- notes the ones less than that many tiles from the view, whatever their level, and in between only
-- those are read again, by their place in the game's list (which stays as it was while no wave starts
-- or ends: see onRenderFrame).
function WavesOverlay:findCrests(viewport, step, waves, full)
    local x1, y1, x2, y2, z = viewport.x1, viewport.y1, viewport.x2, viewport.y2, viewport.z
    local c_sx, c_sy, c_texpos = self.crest_sx, self.crest_sy, self.crest_texpos
    local swell, known = sheets.swell, texpos_known.swell
    local near = self.crest_near
    local count = full and #waves or self.crest_near_count
    local n, kept = 0, 0
    for j = 1, count do
        local i = full and j - 1 or near[j]
        local wave = waves[i]
        local cur = wave.cur
        local x = cur.x
        -- (most waves are out of view sideways, so that is tested first)
        local out_x = x < x1 and x1 - x or x > x2 and x - x2 or 0
        if out_x < CREST_SKIP_MAX then
            local y = cur.y
            local out_y = y < y1 and y1 - y or y > y2 and y - y2 or 0
            if out_y < CREST_SKIP_MAX then
                if full then
                    kept = kept + 1
                    near[kept] = i
                end
                if out_x == 0 and out_y == 0 and wave.z == z then
                    local dest = wave.dest
                    local dx, dy = dest.x - x, dest.y - y
                    local heading = dy < 0 and HEADING_NORTH or dy > 0 and HEADING_SOUTH or dx > 0 and HEADING_EAST or HEADING_WEST
                    local tiles_to_go = math.max(math.abs(dx), math.abs(dy))
                    local whiteness = tiles_to_go <= 1 and 3 or tiles_to_go <= 2 and 2 or tiles_to_go <= 4 and 1 or 0
                    local tile = (heading * SWELL_WHITENESS + whiteness) * FRAMES + 1 + (step + x + y) % FRAMES
                    local texpos = known[tile]
                    if not texpos then
                        texpos = getTexposByHandle(swell[tile])
                        known[tile] = texpos
                    end
                    n = n + 1
                    c_sx[n], c_sy[n], c_texpos[n] = x - x1, y - y1, texpos
                end
            end
        end
    end
    if full then self.crest_near_count = kept end
    self.crest_count = n
end

function WavesOverlay:onRenderFrame(dc, viewport)
    if not dfhack.screen.inGraphicsMode() then return end
    local now = dfhack.getTickCount()

    -- (also reloads if this script gained a sheet since they were loaded)
    if not (sheets and sheets.swell) then
        sheets = load_sheets()
        if sheets.missing then return end
        forget_texposes()
    elseif sheets.missing then
        return
    elseif textures_moved() then
        forget_texposes()
    end

    local x1, y1, z = viewport.x1, viewport.y1, viewport.z
    local tick = df.global.cur_year_tick
    -- Whether the incoming waves have changed is noted on every frame: their number, and the newest one
    -- (the game adds new waves at the end of its list; a new one can take the memory of one that just
    -- ended, so where it is counts too). Either may undo the other's change before the next look
    -- otherwise: a wave ending and another starting leaves the number as it was.
    local waves = df.global.world.event.ocean_waves
    local incoming = #waves
    local newest, newest_at
    if incoming > 0 then
        local wave = waves[incoming - 1]
        local cur = wave.cur
        local _
        _, newest = sizeof(wave)
        newest_at = cur.x + cur.y * 4096
    end
    if incoming ~= self.seen_incoming or newest ~= self.seen_newest or newest_at ~= self.seen_newest_at then
        self.seen_incoming, self.seen_newest, self.seen_newest_at = incoming, newest, newest_at
        self.flows_stale, self.crests_stale = true, true
    end
    -- A new view or a new water list from the caustics is planned for at once, without waiting for the
    -- next scan (measured: after a pan of one tile a rim piece came 70 ms late). The rim along the sea
    -- still follows the caustics' water list, which is made after this in the frame and kept for a while.
    local view_changed = state.view_id ~= self.scan_water or z ~= self.scan_z or x1 ~= self.scan_x1
        or y1 ~= self.scan_y1 or viewport.x2 ~= self.scan_x2 or viewport.y2 ~= self.scan_y2
        or (state.cache ~= nil and state.z == z) ~= self.plan_has_water
    -- Paused, with a finished plan for this view at this game tick: nothing can have changed, so nothing
    -- is looked at again (no flow check, no terrain round) until the view moves or the game runs again.
    local settled = df.global.pause_state and not view_changed and tick == self.settled_tick
        and not self.replan and not self.flows_stale
    if not settled and (view_changed or now >= self.next_scan) then
        -- The flows are read again when the game may have changed them (see FLOW_TICKS), when the view or
        -- the caustics' water list has changed, and once per terrain round.
        if view_changed or tick // FLOW_TICKS ~= self.scan_period or self.flows_stale
                or self.replan or now >= self.next_terrain_round
                or not flows_untouched(x1, y1, viewport.x2, viewport.y2, z) then
            self:rescan(viewport, now, tick)
        else
            -- a scan now would find the same flows: the foam it would have seen again stays remembered,
            -- and old foam is forgotten at the same times as with a scan
            for i = 1, foam_full_count do foam_seen[foam_full[i]] = tick end
            if now >= self.next_foam_cleanup then
                forget_old_foam()
                self.next_foam_cleanup = now + FORGET_FOAM_MS
            end
        end
        -- a plan that has to be made again (the shoreline moved while planning) is made in the next frame,
        -- not a scan later: measured, after a jump of the view some rims came up to 0.2 s late
        self.next_scan = self.replan and 0 or now + RESCAN_MS
        -- (only a look that came after the view last changed counts: the one in the frame of the change
        -- can still run on the water list of the view before)
        self.settled_tick = not view_changed and not self.replan and tick or nil
    end
    local any_crests = incoming > 0
    if piece_count == 0 and not any_crests then return end

    -- animations run on game time, so they stop when the game is paused
    local step = tick // TICKS_PER_FRAME
    local port = df.global.gps.main_viewport
    local dim_x, dim_y = port.dim_x, port.dim_y
    local view_moved = x1 ~= self.list_x1 or y1 ~= self.list_y1 or z ~= self.list_z
        or viewport.x2 ~= self.list_x2 or viewport.y2 ~= self.list_y2
        or dim_x ~= self.list_dim_x or dim_y ~= self.list_dim_y or texture_epoch ~= self.list_epoch
    if view_moved or step ~= self.list_step or plan_number ~= self.list_plan then
        self:buildDrawList(viewport, port, step)
        self.list_step, self.list_plan = step, plan_number
    end
    local crests_read = self.crest_tick
    if any_crests then
        local full = view_moved or self.crests_stale or not crests_read or tick < crests_read
            or tick >= self.crest_full_due
        if full or (tick ~= crests_read and self.crest_near_count > 0) then
            self:findCrests(viewport, step, waves, full)
            self.crest_tick = tick
            if full then self.crests_stale, self.crest_full_due = false, tick + CREST_SKIP_MAX end
        end
    end
    if view_moved then
        self.list_x1, self.list_y1, self.list_x2, self.list_y2, self.list_z = x1, y1, viewport.x2, viewport.y2, z
        self.list_dim_x, self.list_dim_y, self.list_epoch = dim_x, dim_y, texture_epoch
    end

    -- the same screen origin the painter would use for map tiles
    local screen_x, screen_y = dc.x1, dc.y1
    if any_crests then
        local paint = dfhack.screen.paintTile
        local c_sx, c_sy, c_texpos = self.crest_sx, self.crest_sy, self.crest_texpos
        local under_fog, view_dim_x, view_dim_y = port[FOG_LAYER], port.dim_x, port.dim_y
        local last_top, mine, last_mine = port.screentexpos_interface_old, top_mine, top_last
        for i = 1, self.crest_count do
            local sx, sy = c_sx[i], c_sy[i]
            local index = sx >= 0 and sy >= 0 and sx < view_dim_x and sy < view_dim_y and sx * view_dim_y + sy or -1
            local theirs = index >= 0 and last_top[index] or 0
            if theirs ~= 0 and theirs ~= last_mine[index] then
                under_fog[index] = c_texpos[i]
            else
                paint(TILE_PEN, screen_x + sx, screen_y + sy, ' ', c_texpos[i], true)
                if index >= 0 then mine[index] = c_texpos[i] end
            end
        end
    end
    self:draw(port, screen_x, screen_y)
    top_mine, top_last = top_last, top_mine
    timed_since('frame', now)
end

function WavesOverlay:status()
    return ('improved-water waves: %d wave, %d foam and %d spray flows in view, %d pieces planned, %d drawn, %d crests'):format(
        wave_count, foam_count, spray_count, piece_count, self.draw_count, self.crest_count)
end

wave_painter = WavesOverlay{}
-- Every "improved-water ..." command runs this file again in the same environment: the classes get the new run's
-- functions and the overlay goes on with the new run's painter and lists from its next frame. The lists of
-- the run that was drawing until then are out of reach of the new functions, so each painter carries a
-- status function of its own run, and the overlay notes the painter it draws with in state, which stays.
local status, this_painter = WavesOverlay.status, wave_painter
wave_painter.live_status = function() return status(this_painter) end
end
local painter = wave_painter

ImprovedWaterOverlay = defclass(ImprovedWaterOverlay, overlay.OverlayWidget)
ImprovedWaterOverlay.ATTRS{
    desc='Caustics on water, and the ocean waves and sea foam that graphics mode leaves out.',
    viewscreens='dwarfmode',
    default_enabled=true,
    fullscreen=true,
}

-- the overlay framework calls this unconditionally for some widget configs
function ImprovedWaterOverlay:overlay_onupdate() end

-- Which still-water tiles show a ring changes only with the still water's step (every STILL_MS), not every
-- frame. So what was worked out for a step is kept: per tile its place in the screen layer, its place in
-- the pattern, and the ring tile it shows (false: none). It holds for one water list, view and step.
local ring_at, ring_k, ring_tile = {}, {}, {}
local ring_kept = {n = 0}

local draw_frame

-- An error in here would come back every frame and would also stop the DFHack overlays drawn after this
-- one (a later version of the game renaming something this script reads would do it). So the first error
-- is reported once and the script then draws nothing until `improved-water retry` (or the next game start).
function ImprovedWaterOverlay:onRenderFrame(dc)
    if state.failed or not dfhack.isMapLoaded() or not dfhack.screen.inGraphicsMode() then return end
    local ok, err = xpcall(draw_frame, debug.traceback, self, dc)
    if not ok then
        state.failed = true
        dfhack.printerr('improved-water: stopped drawing after an error (this version of the script may not match '
            .. 'this version of the game). To try again: improved-water retry\n' .. tostring(err))
    end
end

function draw_frame(self, dc)
    local vp = guidm.Viewport.get()
    state.painter = painter
    if WAVES then painter:onRenderFrame(dc, vp) end
    local t_start = os.clock()
    local water = water_map(vp)
    if water.n == 0 then return end
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
    local getTexpos = dfhack.textures.getTexposByHandle
    local mvp = df.global.gps.main_viewport
    -- on this lower layer the waves and foam show on top of the caustics
    local under, dim_x, dim_y = mvp[UNDER_LAYER], mvp.dim_x, mvp.dim_y
    local x1, y1, x2, y2 = vp.x1, vp.y1, vp.x2, vp.y2
    -- the tiles' layer indexes worked out at the scan hold while the view is the one that was scanned
    local same_view = water.fits and water.x1 == x1 and water.y1 == y1 and water.dim_x == dim_x and water.dim_y == dim_y
    local tp = {}   -- this frame's 16 tile textures for the group being written
    local budget = BAKE_PER_FRAME
    local groups, order = water.groups, water.order
    for g = 1, #order do
        local key = order[g]
        local set = state.sets[key]
        if not set and budget > 0 then
            budget = bake_some(key, budget)
            set = state.sets[key]
        end
        -- (not baked yet: these tiles stay plain for now)
        if set then
            local group = groups[key]
            local still_pace = key == 'none' or key == 'wash' or key == 'sea'
            local frame = set[(still_pace and t_still or t_flow) + 1]
            for k = 1, 16 do tp[k] = getTexpos(frame[k]) end
            local gk = group.k
            -- still water: rings; the sea has none
            local evs_by_pos = key == 'none' and ring_by_pos
            local kept = ring_kept
            if same_view and not evs_by_pos then
                local at = group.at
                for i = 1, group.n do under[at[i]] = tp[gk[i]] end
            elseif evs_by_pos and kept.water == water and kept.step == step_still and kept.by_pos == evs_by_pos
                    and kept.x1 == x1 and kept.y1 == y1 and kept.x2 == x2 and kept.y2 == y2
                    and kept.dim_x == dim_x and kept.dim_y == dim_y then
                for i = 1, kept.n do
                    local tile = ring_tile[i]
                    under[ring_at[i]] = tile and getTexpos(tile) or tp[ring_k[i]]
                end
                nrings = nrings + kept.rings
            else
                local gx, gy = group.x, group.y
                local keep, rings_before = 0, nrings
                for i = 1, group.n do
                    local x, y = gx[i], gy[i]
                    local sx, sy = x - x1, y - y1
                    if x >= x1 and x <= x2 and y >= y1 and y <= y2 and sx < dim_x and sy < dim_y then
                        local k = gk[i]
                        local tex = tp[k]
                        local evs = evs_by_pos and evs_by_pos[k]
                        local tile = false
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
                                        tile = e.tiles[age + 1]
                                        tex = getTexpos(tile); nrings = nrings + 1
                                        break
                                    end
                                end
                            end
                        end
                        under[sx * dim_y + sy] = tex
                        if evs_by_pos then
                            keep = keep + 1
                            ring_at[keep], ring_k[keep], ring_tile[keep] = sx * dim_y + sy, k, tile
                        end
                    end
                end
                if evs_by_pos then
                    kept.n, kept.rings, kept.water, kept.step, kept.by_pos = keep, nrings - rings_before, water, step_still, evs_by_pos
                    kept.x1, kept.y1, kept.x2, kept.y2, kept.dim_x, kept.dim_y = x1, y1, x2, y2, dim_x, dim_y
                end
            end
        end
    end
    -- ring textures are baked one event per frame, after the still frames are ready
    if budget == BAKE_PER_FRAME and state.sets.none and not (rings and rings.done) then bake_ring() end
    local s = state.stats
    local us = (os.clock() - t_start) * 1e6
    s.n = s.n + 1; s.us = s.us + us; s.tiles = water.n; s.rings = (s.rings or 0) + nrings
    if us > (s.max or 0) then s.max = us end
end

OVERLAY_WIDGETS = {overlay=ImprovedWaterOverlay}

if dfhack_flags.module then return end
local cmd = ...
if cmd == 'stats' then
    local s = state.stats
    local parts = {}
    for key, group in pairs(state.cache and state.cache.groups or {}) do parts[#parts + 1] = key .. '=' .. group.n end
    print(('river flow %s -> step %s ms (still water %d ms)'):format(tostring(state.flow), tostring(state.step_ms), STILL_MS))
    print(('frames %d, avg %.0f us/frame, max %.1f ms, water tiles %d, drift %s'):format(
        s.n, s.n > 0 and s.us / s.n or 0, (s.max or 0) / 1000, s.tiles or -1, table.concat(parts, ' ')))
    local r = state.rings
    print(('rings: %s, tile-frames with a ring since last stats %d'):format(
        r and (r.by_pos and 'ready' or r.done and 'no ring file' or 'baking ' .. tostring(r.n)) or 'not started', s.rings or 0))
    s.n, s.us, s.max, s.rings = 0, 0, 0, 0
end

-- The overlay runs from the module copy of this script, so change settings there.
local module = reqscript('improved-water')
if cmd == 'reload' then
    module.reload_count = module.reload_count + 1
    module.sheets = nil
    module.state.failed = nil
elseif cmd == 'timing' then
    local seconds = math.max(1, dfhack.getTickCount() - module.timing_since) / 1000
    print(('improved-water waves: over the last %.1f s'):format(seconds))
    for part, entry in pairs(module.timing) do
        print(('  %-14s %6d runs  %7.3f ms each  %6.1f ms a second'):format(
            part, entry.runs, entry.ms / math.max(1, entry.runs), entry.ms / seconds))
    end
    module.timing = {}
    module.timing_since = dfhack.getTickCount()
elseif cmd == 'waves' then
    print((module.state.painter or module.wave_painter).live_status())
elseif cmd == 'retry' then
    module.state.failed = nil
elseif cmd ~= 'stats' then
    print([[improved-water draws moving light on water and the ocean's waves and foam. It only draws.
  overlay enable improved-water.overlay    switch it on (it is on by default)
  overlay disable improved-water.overlay   switch it off
  improved-water waves     what the waves are doing now
  improved-water stats     the caustics' numbers and time per frame
  improved-water timing    the waves' time per part
  improved-water reload    load the wave art again (each reload keeps the old art in memory)
  improved-water retry     draw again after it stopped on an error]])
    if module.state.failed then print('It has stopped drawing after an error; see the DFHack console.') end
end
