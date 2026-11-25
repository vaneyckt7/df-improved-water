# Workshop page pictures

Records of how the pictures in `steam/gallery/` and `steam/preview.png` were made. These two scripts
were run from a working folder with session-specific helpers (a DFHack RPC client and a window
screenshot helper), so they do not run as they are; they are kept to show the method.

- `stopmo.py` pauses the game and steps it a few ticks per frame. For each frame it photographs the
  game window twice: once with the overlay drawn, once with the overlay widget hidden. That gives
  exact before/after pairs of the same game moment.
- `compose.py` crops the pairs, puts "before" left and "after" right of a fixed divider, adds the
  labels and writes an optimised GIF.

Steam limits: gallery pictures sent through the Steam API (`upload_workshop.py ... images`) are
refused above roughly 1 MB (result 25). The "Add / Edit Images & Videos" page on the Workshop site
took files up to 1.9 MB; files of 3 MB and more stalled there. Measured 2026-11-25.
