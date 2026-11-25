"""Assemble the Steam Workshop mod folder.

    python tools/build_mod.py [output folder]        (default: dist/improved_water)

The result holds info.txt, preview.png and scripts_modinstalled/ with the script, its two data
files and its art. DFHack adds scripts_modinstalled/ of every installed mod to its script path,
so the overlay works in any fort without the mod being part of the world. To publish, copy the
folder into Dwarf Fortress's mods/ folder and upload it from the game's Mods screen.
"""
import os
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GAME = os.path.join(ROOT, 'game')


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'dist', 'improved_water')
    if os.path.exists(out):
        if not os.path.isfile(os.path.join(out, 'info.txt')):
            sys.exit('%s exists and is not a mod folder; not touching it' % out)
        shutil.rmtree(out)
    scripts = os.path.join(out, 'scripts_modinstalled')
    os.makedirs(scripts)
    for name in ('info.txt', 'preview.png'):
        shutil.copy2(os.path.join(ROOT, 'steam', name), out)
    count = 2
    for name in sorted(os.listdir(GAME)):
        source = os.path.join(GAME, name)
        if os.path.isdir(source):
            # art sheets and their .rows files only; not copies the running game made
            os.makedirs(os.path.join(scripts, name))
            for art in sorted(os.listdir(source)):
                if art.endswith(('.png', '.rows')):
                    shutil.copy2(os.path.join(source, art), os.path.join(scripts, name))
                    count += 1
        elif name.endswith(('.lua', '.bin')):
            shutil.copy2(source, scripts)
            count += 1
    print('%d files in %s' % (count, out))


if __name__ == '__main__':
    main()
