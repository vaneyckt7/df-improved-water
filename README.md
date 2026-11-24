# Improved water for Dwarf Fortress (DFHack)

A DFHack overlay that makes the water of Dwarf Fortress's graphics mode look alive. It only shows what the game
itself has (its waves, flows and water tiles) and changes nothing in the fort:

- ocean waves: the game tracks waves on the sea but graphics mode does not draw them. Here they wash up the
  beach and pull back, leave foam on the sand, and show as crests out at sea and as spray
- rock, pebbles, sand and grass beside the sea get a wet rim with a foam line
- boulders, driftwood, shrubs and saplings under a wave stand in the water
- light patterns (caustics) move over all water, and run along with the flow in rivers
- ripple rings widen on still fresh water

`game/` holds the files as installed in `<Dwarf Fortress>/dfhack-config/scripts/`:

- `improved-water.lua` - the overlay script (DFHack overlay `improved-water.overlay`, command
  `improved-water`). All water plays the baked caustic frames of `caustics_still.bin`; flowing water carries them along with the flow.
  Without that file no caustics are drawn.
- `caustics_still.bin` - 128 frames of 128x128 level bytes (0 off, 1 faint line, 2-3 bright, 4 very faint, 5 white, 6 shadow)
- `caustics_rings.bin` - 64 pre-composited ring clips (levels 7-12 = ring crest colours `RING_COLS`), generated from the still file (regenerate whenever it changes)

Sea: salt water with no flow, on a map where the game has ocean waves (`world.event.ocean_waves`), shows the
still-water caustics without rings.

Everything not used by the script was removed after the tag `locked-art-features` (commit 9a9ef2e) and can be
found there: the generated river pattern (`caustics_fields.bin`), the old foam and surf data and tools
(`caustics_swell.bin`, `caustics_wavetile.bin`, `caustics_sea_*.bin`, `wavetiles.lua`, `tools/wavegif.py`,
`swell.py`, `wavetile.py`, `seagif.py`), the mod's older crest styles (`caustics side|up|auto`, `sidesheet.png`,
`upsheet.png`, `riverbase.png`) and the trial tools for earlier still water and rings (`voro.py`, `post*.py`,
`relabel.py`, `rings2.py`, `bake3.py`, `watersim3.py`, `compose.py`, `net.py`, `net2.py`, `fromimg.py`,
`thick.py`, `halfdiff.py`, `straight.py`, `widen.py`, `pondcap.py`).

The script also draws the ocean's waves (`WAVES = true` in the script; `false` = caustics only): the wash on
the beach, foam, crests out at sea and spray. That part is the script of the Flowing Waves mod 1.3 by Poss
(Steam Workshop 3829998283), copied into `improved-water.lua` and changed. It is the mod author's work; ask them
before publishing this anywhere. With it in our script, keep the mod's own overlay off
(`overlay disable flowing_waves.waves`), or both draw. Commands: `improved-water stats`, `improved-water waves` (status),
`improved-water reload` (reload the wave art), `improved-water timing`.

Layers: the caustics are written to the map viewport layer `screentexpos_signpost` (`UNDER_LAYER`). The waves use the layers the mod used: `screentexpos_background`
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
- the mod author's, recoloured with `tools/fwtint.py`: `riversheet.png`, `riverseafringe.png`

    python fwsheets.py ../game/caustics_waves_art preview.png

Sea and wash caustics: `SEA_WASH` (wave density from which a beach tile under a wave is lit), `SEA_COLS` and
`WASH_COLS` (the caustic colours on the sea and on the lighter wash) are in the script. Notes from testing in game:

- Only the two freshest foam stages are bright solid foam. The game leaves foam on the sand long after the
  water has pulled back, so older stages are thin strands that break into crumbs.
- Crests (`swell.png`): the line sways and swells where it bulges forward; a 1 px dark band of water in front of the line (the trough; it is opaque, so it also
  covers the caustic lines at the crest and the crest looks raised), and behind it a short trail of foam
  clumps in the line's own colour instead of single-pixel speckle. From two other models' advice; their
  further suggestions not done: uneven lumps instead of the regular sway, no white on the far-out stage.
- Boulders on or beside a wave: the first floor layer under the boulder gets the same animated wash tile as
  the tiles around it. The wash
  caustics run over a boulder under a wave like over any other wave tile, so it reads as under water. The olive square under a dry boulder is the
  game's own floor for that stone (still there with `WAVES = false`).
- The game puts almost no wave flows on bare stone floor (2 of 35 such tiles in one high-tide view), only
  spray, which the game itself draws as blue streaks. Those tiles stay rock with a rim, as islands in the wash.
- The lip of wash on the sea tiles (`riverseafringe.png`) goes on the second floor layer, under the caustics,
  so the caustic lines cross it. (On the interface layer it covered them; `screentexpos_floor_flag` is a
  flag, not a picture slot: writing a picture there brought the game's frayed edge back.)
- Shrubs and saplings under a wave: the wash goes on the first floor layer, like under driftwood, and the
  plant stands in the water. Dry, they count as beach and get the rim beside the water.
- Dry squares in the wash are the game's: the script draws water only where the game has a wave. A rule
  that guessed "under water" from the neighbours (`flood_islands`, commit ec2fd21) was taken out again.
- A see-through or dithered pale pixel came out darker than the sand under it in game, so the foam is fully
  opaque. (Cause not established; giving invisible pixels the foam colour did not change it.)

`tools/fwtint.py` lightens the water of the mod's wash sheets (`riversheet`, `riverfringe`, `riverseafringe`), so the thin water on the beach is lighter than the sea instead of darker. It reads a copy of
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
    python ringcols.py ../game/improved-water.lua 0.26

Current rings: shape taken from a 128-frame animation of one widening ripple (not in this repo; the build
used `~/Downloads/blue_bubble_ripple_128_frames.gif`, 768x768). `ringgif.py` reads its brightness profile
along the radius per frame and redraws it at tile size in six crest levels (7-12), 28 frames long, faint for
the first two frames, with a faint trough (level 6) for the first 60%. The last argument `1` keeps the
caustic lines on top of the ring. `ringcols.py` writes the six crest colours into the script: the
animation's lightening (crest minus its background) times a strength (0.26 chosen by eye in game), the
brighter steps pulled up to 40% toward the water's teal hue, solved for the overlay blend on in-game water
of about RGB 1,78,90. `ringstrip.py` draws a mock-up strip of one ring over its life.

Earlier still water and rings (drawn circles, a wobbling single picture, generated pebble nets, sliding Voronoi
webs, a simulated wave surface) are in the history up to the tag `locked-art-features`, with their tools and the
commands that built them in that version of this file.

`apply_still.sh` and `bg.py` install into a running game over DFHack RPC (paths are machine-specific).

Speed (measured in game on a beach view of 38x25 tiles, 30 frames a second): the script reads the game's flags
whole and tests bits, reads each tile type's properties once, keeps the water, the wave pieces and the draw
list as parallel arrays, and plans the waves again only when the flows, the terrain or the view changed.
It was checked against the version at the tag `locked-art-features`: both loaded side by side in the running
game, each drawing the same frame into the map's screen layers, compared cell by cell.

Never call `dfhack.textures.deleteHandle` when reloading (it crashed the game); old textures are leaked instead.
