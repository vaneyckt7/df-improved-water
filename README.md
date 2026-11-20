# Water caustics overlay for Dwarf Fortress (DFHack)

`game/` holds the files as installed in `<Dwarf Fortress>/dfhack-config/scripts/`:

- `caustics.lua` - the overlay script (river pattern is generated in Lua; still water plays baked frames)
- `caustics_still.bin` - 128 frames of 128x128 level bytes (0 off, 1 faint line, 2-3 bright, 4 very faint, 5 white, 6 shadow)
- `caustics_rings.bin` - 64 pre-composited ring clips, generated from the still file (regenerate whenever it changes)
- `caustics_fields.bin` - data for the river pattern

`tools/` rebuilds the still-water files (Python with numpy, scipy, Pillow).

Current still water: taken from a seamless grayscale caustics picture (not in this repo; the bake used
`~/Downloads/Milky grayscale water caustics texture.png`). The picture is shrunk to 128x128 px, its lines
are sharpened, and a smooth 3 px displacement that loops over the 128 frames makes the net flex in place.
Levels by brightness: 4 very faint halo, 1 line, 5 white knots. No shadow in this version.

    python fromimg.py <picture> caustics_still.bin 3 72,82,96.5   # wobble px, halo/line/white percentiles
    python rings2.py caustics_still.bin caustics_rings.bin 4

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
