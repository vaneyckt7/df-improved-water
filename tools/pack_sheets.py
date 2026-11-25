"""Drops repeated rows from the art sheets, so fewer tiles are loaded into the game.

    python pack_sheets.py <art dir>

A sheet is rows of 16 frames of 32x32 px, and the script finds a picture by its row number. Many rows are
pixel for pixel the same as another (all the empty ones, for a start). For every sheet where that is so,
this keeps one copy of each different row and writes <sheet>.rows beside the PNG: one number per row of the
full layout, the row of the packed sheet that holds its picture. The script reads that file and looks the
pictures up through it, so what is drawn does not change.

Run it after make_art_sheets.py or recolour_wash.py, which write full-layout sheets (they remove the .rows
file of a sheet they rewrite). A sheet that is already packed is left alone; a .rows file that does not fit
its sheet is replaced.
"""
import os, sys
from PIL import Image

ROW_PX, FRAMES = 32, 16


def pack(png):
    rows_file = os.path.splitext(png)[0] + '.rows'
    name = os.path.basename(png)
    sheet = Image.open(png).convert('RGBA')
    if sheet.width != ROW_PX * FRAMES or sheet.height % ROW_PX:
        print(name, 'is not a sheet of 16 frames of 32x32 px a row; left alone')
        return
    count = sheet.height // ROW_PX
    if os.path.exists(rows_file):
        with open(rows_file) as f:
            listed = [int(n) for n in f.read().split()]
        if listed and max(listed) + 1 == count:
            print(name, 'already packed')
            return
        # a full-layout sheet was written over a packed one and the old .rows file was left behind
        print(name, 'does not fit its .rows file; packing it again')
        os.remove(rows_file)
    place, kept, lookup = {}, [], []
    for row in range(count):
        strip = sheet.crop((0, row * ROW_PX, sheet.width, (row + 1) * ROW_PX))
        pixels = strip.tobytes()
        if pixels not in place:
            place[pixels] = len(kept)
            kept.append(strip)
        lookup.append(place[pixels])
    if len(kept) == count:
        print(name, 'has no repeated rows')
        return
    packed = Image.new('RGBA', (sheet.width, len(kept) * ROW_PX))
    for i, strip in enumerate(kept):
        packed.paste(strip, (0, i * ROW_PX))
    # The .rows file first: if this stops halfway, the game refuses the pair (full sheet, packed lookup)
    # and the next run here packs it again. The other order would leave a packed sheet read as a full one.
    with open(rows_file, 'w') as f:
        f.write(' '.join(str(n) for n in lookup) + '\n')
    packed.save(png + '.tmp', format='PNG', optimize=True)
    os.replace(png + '.tmp', png)
    print(name, count, 'rows ->', len(kept))


if __name__ == '__main__':
    folder = sys.argv[1]
    for file in sorted(os.listdir(folder)):
        if file.endswith('.png'):
            pack(os.path.join(folder, file))
