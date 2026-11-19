# Water caustics overlay for Dwarf Fortress (DFHack)

`game/` holds the files as installed in `<Dwarf Fortress>/dfhack-config/scripts/`:

- `caustics.lua` - the overlay script (river pattern is generated in Lua; still water plays baked frames)
- `caustics_still.bin` - 128 frames of 128x128 level bytes (0 off, 1 faint streak, 2-3 bright points, 4 very faint long line)
- `caustics_rings.bin` - 64 pre-composited ring clips, generated from the still file (regenerate whenever it changes)
- `caustics_fields.bin` - data for the river pattern

`tools/` rebuilds the still-water files (Python with numpy, scipy, Pillow):

    python bake3.py tmp_S3.bin 21 4 8.5 40 1.4 0.95 0.6 93.5,97.6,99.4 1.5      # short-line wave field
    python post2.py tmp_S3.bin still_V1.bin 3 4.5 10 1                           # cut, drop crumbs, tapered widening
    python bake3.py tmp_LA.bin 33 2.5 5.5 28 1.4 0.95 0.6 94,99.9,99.95 0.5      # long thin lines
    python compose.py still_V1.bin tmp_LA.bin caustics_still.bin
    python rings2.py caustics_still.bin caustics_rings.bin 4

`bake3.py measure <bin>`, `thick.py` and `halfdiff.py` print line length, thickness and turnover.
`apply_still.sh` and `bg.py` install into a running game over DFHack RPC (paths are machine-specific).

Never call `dfhack.textures.deleteHandle` when reloading (it crashed the game); old textures are leaked instead.
