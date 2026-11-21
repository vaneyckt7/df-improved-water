# Water caustics overlay for Dwarf Fortress (DFHack)

`game/` holds the files as installed in `<Dwarf Fortress>/dfhack-config/scripts/`:

- `caustics.lua` - the overlay script (river pattern is generated in Lua; still water plays baked frames)
- `caustics_still.bin` - 128 frames of 128x128 level bytes (0 off, 1 faint line, 2-3 bright, 4 very faint, 5 white, 6 shadow)
- `caustics_rings.bin` - 64 pre-composited ring clips (levels 7-12 = ring crest colours `RING_COLS`), generated from the still file (regenerate whenever it changes)
- `caustics_fields.bin` - data for the river pattern

Sea (`SEA_SWELL`, `SEA_FOLLOW`): salt water with no flow shows the still-water caustics (`SEA_CAUSTICS`, no
rings) and foam crests that follow the game's own waves (`world.event.ocean_waves`). Waves standing side by
side are joined into wavefronts (`SEA_ROWS`, `SEA_FRONT_*`) and each front is drawn as one continuous line:
every column along it gets foam at a smoothed position, columns without a wave are filled in, and a sloping
front uses foam leaning to match (`SEA_FRONT_SLANT`; thirds of a tile per column, baked when first needed).
Foam fades in as a wave nears its destination (`SEA_BUILD`). On a foam tile the caustics go to a lower
viewport layer (`SEA_UNDER`) so both show. `caustics_swell.bin` holds 128 frames of 128x128 level bytes,
crest travelling west; the script mirrors, turns and slants it. `wavetiles.lua` is a debug overlay that
marks the tile behind each game wave with an arrow (`overlay enable wavetiles.show`).

Shore surf (`SEA_SHORE`, on by default; overrides the wave-following foam above): every sea tile near land
knows its distance to the coast, and a band of white foam cut from the still-water pattern is drawn where
that distance equals a value shrinking over time. It appears faint `SHORE_MAX` tiles out, turns to full
foam `SHORE_MID` tiles out and runs up the land (`SHORE_BEACH`: two rows of floor or pebble tiles on the
viewed level). In the last land row the front stops part-way across the tile (`SHORE_RUN`) and the foam
behind it thins away where it lies (`_ebb` frame sets). From that moment the land row in front of it stops
sliding too and thins in place (`_wane` sets); both thin fastest at the stop line and slowest toward the
sea, so the sheet dries from its inland edge and the last foam lies at the water's edge. On land the dense foam reaches further back
(`_sand` sets) so the sheet on the sand stays wide. On land, and on sea tiles touching
land, the foam is drawn solid with the sea colour (`SHORE_WATER`) mixed in beforehand, so neither the ground
nor the game's ragged shoreline edge shows through it. Behind the front, where the foam has thinned, those
tiles are filled with the plain sea colour (fading out further back), so no bare sand shows on the seaward
side of the foam while the wave is on the beach. Before the distances are worked out the land is
grown and shrunk by `SHORE_CLOSE` tiles, so notches and narrow channels do not each bend the foam their own
way (they stay calm past two tiles in). A land tile's distance inland follows the coast's angle there, so
on a diagonal coast the foam on the sand ends in one slanted line. Still in the script but switched off or overridden: `SEA_ONTILE` (a crescent per
game wave, `caustics_wavetile.bin` from `tools/wavetile.py`) and `SEA_TILED` (`caustics_sea_crescent.bin` /
`caustics_sea_line.bin` from `tools/seagif.py`).

    python wavegif.py ...                                   # foam frames from a wave animation (see the script)
    python swell.py caustics_swell.bin 4 0.55 preview.png   # earlier drawn swell: crests per 128 px, share drawn

`tools/` rebuilds the still-water files (Python with numpy, scipy, Pillow).

Current still water: taken from a 128-frame looping grayscale caustics animation (not in this repo; the
bake used `~/Downloads/water_caustics_128_frames.gif`, 768x768, 80 ms per frame). Its frames are used one
for one. It loops in time but does not tile in space, so a 96 px band along two edges is cross-faded into
the opposite edges before each frame is shrunk to 128x128 px. Levels by brightness: 4 very faint halo,
1 line, 5 white knots. No shadow.

    python fromgif.py <animation.gif> caustics_still.bin 96 72,82,96.5   # blend band px, halo/line/white percentiles
    python ringgif.py <ripple.gif> caustics_still.bin caustics_rings.bin 4 7 28 0.72,0.54,0.40,0.28,0.17,0.08 0.5 0.6 7,8,9,10,11,12 1
    python ringcols.py caustics.lua 0.26

Current rings: shape taken from a 128-frame animation of one widening ripple (not in this repo; the build
used `~/Downloads/blue_bubble_ripple_128_frames.gif`, 768x768). `ringgif.py` reads its brightness profile
along the radius per frame and redraws it at tile size in six crest levels (7-12), 28 frames long, faint for
the first two frames, with a faint trough (level 6) for the first 60%. The last argument `1` keeps the
caustic lines on top of the ring. `ringcols.py` writes the six crest colours into the script: the
animation's lightening (crest minus its background) times a strength (0.26 chosen by eye in game), the
brighter steps pulled up to 40% toward the water's teal hue, solved for the overlay blend on in-game water
of about RGB 1,78,90. `ringstrip.py` draws a mock-up strip of one ring over its life.

Earlier rings (thin drawn circle in the caustic colours, 22 frames, up to commit b7c0aa5):

    python rings2.py caustics_still.bin caustics_rings.bin 4

Also tried: the tileable variant `water_caustics_tileable_128_frames.gif` (band 0; liked less), and a
single seamless picture bent by a looping 3 px wobble (commit 5dba3c2):

    python fromimg.py <picture> caustics_still.bin 3 72,82,96.5   # wobble px, halo/line/white percentiles

Trials kept as tools, not installed: `net2.py` (generated net of rounded pebbles with curved borders,
shadow as level 6 = `STILL_SHADOW` in the script, e.g. `net2.py out.bin 4 30 2.6 0.56 7 4 0.86`) and
`net.py` (first attempt, straight cell borders).

Straight-line still water (two sliding Voronoi webs, 20 dots each; level 5 = line overlap, commit 19eff4a):

    python voro.py tmp_X20.bin 5 20 7 90,97.5            # seed, dots, edge fade px, faint/overlap percentiles
    python post3.py tmp_X20.bin still_Y20.bin 3 4.5 12   # cut long lines, despike, drop crumbs
    python relabel.py still_Y20.bin caustics_still.bin   # overlaps: level 2 -> 5
    python rings2.py caustics_still.bin caustics_rings.bin 4

Earlier still water (curved lines from a simulated wave surface, commit 12e63f5):

    python bake3.py tmp_S3.bin 21 4 8.5 40 1.4 0.95 0.6 93.5,97.6,99.4 1.5      # short-line wave field
    python post2.py tmp_S3.bin still_V1.bin 3 4.5 10 1                           # cut, drop crumbs, tapered widening
    python bake3.py tmp_LA.bin 33 2.5 5.5 28 1.4 0.95 0.6 94,99.9,99.95 0.5      # long thin lines
    python compose.py still_V1.bin tmp_LA.bin caustics_still.bin
    python rings2.py caustics_still.bin caustics_rings.bin 4

`bake3.py measure <bin>`, `thick.py` and `halfdiff.py` print line length, thickness and turnover.
`apply_still.sh` and `bg.py` install into a running game over DFHack RPC (paths are machine-specific).

Never call `dfhack.textures.deleteHandle` when reloading (it crashed the game); old textures are leaked instead.
