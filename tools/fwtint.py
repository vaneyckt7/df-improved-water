"""Recolours the Flowing Waves mod's wash sheets and/or makes them more see-through: shallow water on the
beach should look lighter than the open sea, not darker.

    python -I fwtint.py <mod art_original dir> <mod art dir> [r,g,b | -] [opacity factor]

"-" keeps the colours; the opacity factor (default 1) multiplies every pixel's opacity.

Reads the mod's own riversheet.png, riverfringe.png and riverseafringe.png from the first
folder (a copy of the originals) and writes recoloured ones into the second. Each colour channel is scaled
toward white so that the sheets' base water colour BASE becomes the target colour.
The results are derived from the mod author's art, so they are not kept in this repo.
"""
import sys, os
import numpy as np
from PIL import Image

BASE = np.array([5.0, 81.0, 94.0])
NAMES = ('riversheet.png', 'riverfringe.png', 'riverseafringe.png')

if __name__ == '__main__':
    src, dst = sys.argv[1], sys.argv[2]
    colour = sys.argv[3] if len(sys.argv) > 3 else '-'
    opacity = float(sys.argv[4]) if len(sys.argv) > 4 else 1.0
    target = BASE if colour == '-' else np.array([float(v) for v in colour.split(',')])
    gain = (255 - target) / (255 - BASE)
    for name in NAMES:
        a = np.array(Image.open(os.path.join(src, name)).convert('RGBA'))
        rgb = 255 - (255 - a[..., :3].astype(float)) * gain
        alpha = np.clip(a[..., 3] * opacity, 0, 255)
        # In game a see-through pixel shows as colour x opacity x opacity over the ground (measured: at 70%
        # opacity the teal wash turned mud brown), so the colour is divided by the opacity to make up for it.
        rgb = rgb / np.clip(alpha[..., None] / 255.0, 0.2, 1)
        a[..., :3] = np.clip(rgb + 0.5, 0, 255).astype(np.uint8)
        a[..., 3] = (alpha + 0.5).astype(np.uint8)
        Image.fromarray(a).save(os.path.join(dst, name))
        print(name, a.shape)
