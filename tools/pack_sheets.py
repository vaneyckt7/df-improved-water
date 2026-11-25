"""Drops repeated rows from the art sheets, so fewer tiles are loaded into the game.

    python pack_sheets.py <art dir>

A sheet is rows of 16 frames of 32x32 px, and the script finds a picture by its row number. Many rows are
pixel for pixel the same as another (all the empty ones, for a start). For every sheet where that is so,
this keeps one copy of each different row and writes <sheet>.rows beside the PNG: one number per row of the
full layout, the row of the packed sheet that holds its picture. The script reads that file and looks the
pictures up through it, so what is drawn does not change.

Run it after make_art_sheets.py or recolour_wash.py, which write full-layout sheets (they remove the .rows
file of a sheet they rewrite). A sheet that already has a .rows file is left alone.
"""
import os, sys
from PIL import Image

ROW_PX, FRAMES = 32, 16


def pack(png):
    rows_file = os.path.splitext(png)[0] + '.rows'
    name = os.path.basename(png)
    if os.path.exists(rows_file):
        print(name, 'already packed')
        return
    sheet = Image.open(png).convert('RGBA')
    assert sheet.width == ROW_PX * FRAMES and sheet.height % ROW_PX == 0, (name, sheet.size)
    count = sheet.height // ROW_PX
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
    packed.save(png, optimize=True)
    with open(rows_file, 'w') as f:
        f.write(' '.join(str(n) for n in lookup) + '\n')
    print(name, count, 'rows ->', len(kept))


if __name__ == '__main__':
    folder = sys.argv[1]
    for file in sorted(os.listdir(folder)):
        if file.endswith('.png'):
            pack(os.path.join(folder, file))
