# Water caustics overlay for Dwarf Fortress (DFHack)

`game/` holds the files as installed in `<Dwarf Fortress>/dfhack-config/scripts/`:

- `caustics.lua` - the overlay script: caustics and ocean waves (river pattern is generated in Lua; still water plays baked frames)
- `caustics_still.bin` - 128 frames of 128x128 level bytes (0 off, 1 faint line, 2-3 bright, 4 very faint, 5 white, 6 shadow)
- `caustics_rings.bin` - 64 pre-composited ring clips (levels 7-12 = ring crest colours `RING_COLS`), generated from the still file (regenerate whenever it changes)
- `caustics_fields.bin` - data for the river pattern

Sea: salt water with no flow, on a map where the game has ocean waves (`world.event.ocean_waves`), shows the
still-water caustics without rings. The foam and surf code (wave-following crests, shore surf, tiled sea) was
removed after commit c8352cc; its data files and tools (`caustics_swell.bin`, `caustics_wavetile.bin`,
`caustics_sea_*.bin`, `wavetiles.lua`, `tools/wavegif.py`, `swell.py`, `wavetile.py`, `seagif.py`) are still
in the repo but no longer used by the script.

The script also draws the ocean's waves (`WAVES = true` in the script; `false` = caustics only): the wash on
the beach, foam, crests out at sea and spray. That part is the script of the Flowing Waves mod 1.3 by Poss
(Steam Workshop 3829998283), copied into `caustics.lua` and changed. It is the mod author's work; ask them
before publishing this anywhere. With it in our script, keep the mod's own overlay off
(`overlay disable flowing_waves.waves`), or both draw. Commands: `caustics waves` (status),
`caustics river|auto|side|up` (style), `caustics reload` (reload the wave art), `caustics timing`.

Layers: the caustics are written to the map viewport layer `screentexpos_signpost` (`UNDER_LAYER`; `false`
paints on the interface layer instead). The waves use the layers the mod used: `screentexpos_background`
(water under boulders), `screentexpos_background_two` (wash and foam, where that slot is free) and the
interface layer (everything else), so waves and foam show over the caustics.

Added to the mod's logic: all natural ground that touches the open sea (rock, pebbles, sand, soil, grass,
boulders; not built floors) gets the rock rim, not only rock beside the wash. The game's own frayed sand
edge on the sea tiles beside it is switched off. The sea tiles come from the caustics' own scan of the view. The wash no longer draws the mod's
foam band inside the water tile against sand: sand beside the wash gets the same rim, so the foam line runs on
unbroken from the wash to the sea. On driftwood the game's log sits on the layer the wash uses, so there the wash replaces
the sand on the first floor layer and the log lies in the water.

`game/caustics_waves_art/` holds the wave art, installed as `dfhack-config/scripts/caustics_waves_art/`:

- ours, built by `tools/fwsheets.py`: `seafoam.png` (foam on the beach and spray), `swell.png` (crests out at
  sea) and `riverfringe.png` (rock and pebble tiles beside the water: the water laps a few px onto the rock,
  with a foam rim)
- the mod author's, recoloured with `tools/fwtint.py`: `riversheet.png`, `riverseafringe.png`, `riverbase.png`
- the mod author's, unchanged: `sidesheet.png`, `upsheet.png` (the older crest styles)

    python fwsheets.py ../game/caustics_waves_art preview.png

Sea and wash caustics: `SEA_WASH` (wave density from which a beach tile under a wave is lit), `SEA_COLS` and
`WASH_COLS` (the caustic colours on the sea and on the lighter wash) are in the script. Notes from testing in game:

- Only the two freshest foam stages are bright solid foam. The game leaves foam on the sand long after the
  water has pulled back, so older stages are thin strands that break into crumbs.
- Crests (`swell.png`): the line sways and swells where it bulges forward; a 1 px dark band of water in front of the line (the trough; it is opaque, so it also
  covers the caustic lines at the crest and the crest looks raised), and behind it a short trail of foam
  clumps in the line's own colour instead of single-pixel speckle. From two other models' advice; their
  further suggestions not done: uneven lumps instead of the regular sway, no white on the far-out stage.
- A see-through or dithered pale pixel came out darker than the sand under it in game, so the foam is fully
  opaque. (Cause not established; giving invisible pixels the foam colour did not change it.)

`tools/fwtint.py` lightens the water of the mod's wash sheets (`riversheet`, `riverfringe`, `riverseafringe`,
`riverbase`), so the thin water on the beach is lighter than the sea instead of darker. It reads a copy of
the mod's originals and writes into an output folder (the copies in `game/caustics_waves_art/` were made this way). It also writes a recoloured
`riverfringe.png`: do not copy that one over ours. The
wash colour is repeated in `fwsheets.py` (`WASH`).

    python -I fwtint.py <mod>/art_original <mod>/art 30,128,138   # colour the base water becomes
    python -I fwtint.py <mod>/art_original <mod>/art - 0.7        # keep the colours, 70% of the opacity
    python -I fwtint.py <mod>/art_original <mod>/art 20,114,127 1.2   # chosen: lighter than the sea, opaque

Measured in game: a see-through pixel shows as colour x opacity x opacity over the ground (at 70% opacity
the uncorrected teal wash turned mud brown), so the tool divides the colour by the opacity. With that
correction, 70% teal over red sand comes out grey.

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
