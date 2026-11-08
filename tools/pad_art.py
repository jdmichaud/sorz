# The controller overlay's pad (src/shared/pad_art.zig), made from a photo of the Mega
# Drive control pad: cut out of its white ground, shrunk to pixel size, its colours snapped to the
# console's 8 levels (greys for the plastic, reds for the marks), outlined in black as the game's
# sprites are; crisp red letters A, B, C drawn in its buttons; each pixel that a press lights
# marked with its button (a button, a D-pad arm, START), and each colour's pressed colour (a
# grey's yellow of its shade, a red's yellow of its light, a letter's dark red).
#
#     python3 pad_art.py PHOTO OUT.zig [PREVIEW_DIR]
#
# The look the user chose (2026-11-08) from the mockups made the same way. Needs Pillow. Not part
# of the build: its output is the art kept in the repository, which the photo is not.
from PIL import Image
from collections import deque
import math, sys

PHOTO, OUT = sys.argv[1], sys.argv[2]
PREVIEW = sys.argv[3] if len(sys.argv) > 3 else None
LV = [0, 52, 87, 116, 144, 172, 206, 255]
GAMMA = 0.8
BOX = (120, 468, 1804, 1456)
SIZES = [('large', 83), ('small', 61)]


def cut_out():
    src = Image.open(PHOTO).convert('RGB').crop(BOX)
    w, h = src.size
    # The ground: the near-white pixels joined to the border (a flood fill), so that the white of
    # START and of the letters, inside the pad, stays.
    small = src.resize((w // 2, h // 2))
    sp = small.load()
    sw, sh = small.size
    ground = [[False] * sw for _ in range(sh)]
    q = deque((x, y) for x in range(sw) for y in (0, sh - 1))
    q.extend((x, y) for y in range(sh) for x in (0, sw - 1))
    while q:
        x, y = q.popleft()
        if not (0 <= x < sw and 0 <= y < sh) or ground[y][x]:
            continue
        if sum(sp[x, y]) < 3 * 165:
            continue
        ground[y][x] = True
        q.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))
    mask = Image.new('L', (sw, sh), 0)
    mp = mask.load()
    for y in range(sh):
        for x in range(sw):
            mp[x, y] = 0 if ground[y][x] else 255
    mask = mask.resize((w, h))
    # Under the ground, the pad's own dark, so that shrinking brings no white halo in.
    dark = Image.new('RGB', (w, h), (18, 18, 20))
    return Image.composite(src, dark, mask), mask


def level(v):
    v = 255 * (v / 255) ** GAMMA
    return min(range(8), key=lambda i: abs(LV[i] - v))


# A colour is (r, g, b, role) in levels 0 to 7; role 'letter' is a button's letter.
FONT = {'A': ["010", "101", "111", "101", "101"], 'B': ["110", "101", "110", "101", "110"],
        'C': ["011", "100", "100", "100", "011"]}
RED = (7, 1, 0, 'letter')
DARK_RED = (4, 0, 0, '')
RAMP = [(4, 2, 0), (6, 3, 0), (7, 4, 0), (7, 5, 1), (7, 6, 1), (7, 6, 2), (7, 7, 4), (7, 7, 6)]


def yellow(k):
    return RAMP[min(7, k + 3)] + ('',)


def pressed(c):
    """A colour's look pressed: a grey's yellow of its shade, a red's of its light."""
    if c[3] == 'letter':
        return DARK_RED
    return yellow(max(c[0], c[1], c[2]))


def make(src, mask, width):
    w, h = src.size
    H = round(h * width / w)
    rgb = src.resize((width, H), Image.LANCZOS).load()
    alpha = mask.resize((width, H), Image.BOX).load()
    px = [[None] * width for _ in range(H)]
    for y in range(H):
        for x in range(width):
            if alpha[x, y] < 128:
                continue
            r, g, b = rgb[x, y]
            # The pad is grey but for its red marks and letters: a grey of the levels, or a red.
            if r - max(g, b) > 40:
                lv = level(r)
                px[y][x] = (lv, 1 if lv >= 6 else 0, 0, '')
            else:
                v = level(0.3 * r + 0.59 * g + 0.11 * b)
                px[y][x] = (v, v, v, '')

    def inside(x, y):
        return 0 <= x < width and 0 <= y < H and px[y][x] is not None

    # Near its silhouette the body is never pure black (the rim's dark plastic would read as a
    # stub): the outline alone is.
    def near_edge(x, y, n=3):
        return any(not inside(x + dx, y + dy) for dx in range(-n, n + 1) for dy in range(-n, n + 1))
    for y in range(H):
        for x in range(width):
            p = px[y][x]
            if p is not None and p[:3] == (0, 0, 0) and near_edge(x, y):
                px[y][x] = (1, 1, 1, '')
    # A black outline around it, as the game's sprites have.
    edge = [(x, y) for y in range(H) for x in range(width) if px[y][x] is not None and any(
        not inside(x + dx, y + dy) for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)))]
    for x, y in edge:
        px[y][x] = (0, 0, 0, '')

    scale = width / w

    def at(x, y):
        return ((x - BOX[0]) * scale, (y - BOX[1]) * scale)
    # The buttons' places in the photo (its own pixels), and their sizes.
    part = [['.'] * width for _ in range(H)]
    btn_r = 74 * scale
    for name, (bx, by) in (('a', at(1240, 1024)), ('b', at(1416, 930)), ('c', at(1594, 866))):
        for y in range(H):
            for x in range(width):
                if math.hypot(x + .5 - bx, y + .5 - by) <= btn_r and px[y][x] is not None:
                    part[y][x] = name
        x0, y0 = round(bx - 1.5), round(by - 2.5)
        for dy, row in enumerate(FONT[name.upper()]):
            for dx, bit in enumerate(row):
                if bit == '1':
                    px[y0 + dy][x0 + dx] = RED
                    part[y0 + dy][x0 + dx] = name
    # The D-pad's arms: its greys inside each arm light.
    k = width / 104
    dx0, dy0 = at(510, 924)
    for name, (ux, uy) in (('u', (0, -1)), ('d', (0, 1)), ('l', (-1, 0)), ('r', (1, 0))):
        for y in range(H):
            for x in range(width):
                ox, oy = x + .5 - dx0, y + .5 - dy0
                along = ox * ux + oy * uy
                side = abs(ox * uy - oy * ux)
                p = px[y][x]
                if 1.5 * k <= along <= 7.5 * k and side <= 2.0 * k and p is not None and p[0] == p[1]:
                    part[y][x] = name
    # START: its greys.
    sx, sy = at(1304, 690)
    for y in range(H):
        for x in range(width):
            p = px[y][x]
            if abs(x + .5 - sx) <= 3.2 * k and abs(y + .5 - sy) <= 1.4 * k and p is not None and p[0] == p[1]:
                part[y][x] = 's'
    return px, part


def main():
    src, mask = cut_out()
    arts = [(name, *make(src, mask, width)) for name, width in SIZES]
    # The palette: index 0 none; the colours used, then their pressed colours.
    colours = []
    for _, px, part in arts:
        for row in px:
            for c in row:
                if c is not None and c not in colours:
                    colours.append(c)
    colours.sort(key=lambda c: (c[3], c[0] != c[1], c[0], c[1], c[2]))
    used = list(colours)
    for c in used:
        p = pressed(c)
        if p not in colours:
            colours.append(p)
    CHARS = '.123456789abcdefghijklmnopqrstuvwxyz'
    assert len(colours) < len(CHARS)
    index = {c: i + 1 for i, c in enumerate(colours)}
    out = []
    out.append('//! The controller overlay\'s pad (DESIGN.md 10.8): pixel art the port made from a photo of the Mega\n')
    out.append('//! Drive control pad, not from the game\'s data. The photo cut out of its white ground, shrunk to\n')
    out.append('//! pixel size, its colours snapped to the console\'s 8 levels (greys for the plastic, reds for its\n')
    out.append('//! marks), outlined in black as the game\'s sprites are; crisp red letters A, B, C drawn in its\n')
    out.append('//! buttons (the photo\'s shrink to dots). Each pixel a press lights is marked with its button, and\n')
    out.append('//! each colour has its pressed colour: a grey the yellow of its shade, a red the yellow of its\n')
    out.append('//! light, a letter dark red (the look the user chose, 2026-11-08). Made by tools/pad_art.py from\n')
    out.append('//! the photo (which the repository does not keep), and kept here as the port\'s own art: `large`\n')
    out.append('//! for one or two players, `small` (made the same way, narrower) for three or four.\n')
    out.append('//!\n')
    out.append('//! A pixel\'s character in `*_rows`: `.` none, else its colour\'s index in `palette`, `1` to `9`\n')
    out.append('//! then `a` to `z` (10 to 35). In `*_parts`: `.` none, else the button whose press lights it\n')
    out.append('//! (`u`, `d`, `l`, `r` the D-pad\'s arms, `a`, `b`, `c`, `s` START).\n')
    out.append('const art = @import("content/art.zig");\n\n')
    out.append('/// The pad\'s colours, in levels from 0 to 7 a channel (index 0: none).\n')
    out.append('pub const palette = [_]art.Colour{\n    .{ .r = 0, .g = 0, .b = 0 },\n')
    for c in colours:
        out.append('    .{ .r = %d, .g = %d, .b = %d },\n' % c[:3])
    out.append('};\n\n')
    out.append('/// Each colour\'s pressed colour (an index in `palette`).\n')
    out.append('pub const pressed = [palette.len]u8{ 0, %s };\n\n' % ', '.join(str(index[pressed(c)]) if c in used else str(index[c]) for c in colours))
    for name, px, part in arts:
        width = len(px[0])
        out.append('pub const %s_rows = [_][]const u8{\n' % name)
        for row in px:
            out.append('    "%s",\n' % ''.join('.' if c is None else CHARS[index[c]] for c in row))
        out.append('};\n\n')
        out.append('pub const %s_parts = [_][]const u8{\n' % name)
        for row in part:
            out.append('    "%s",\n' % ''.join(row))
        out.append('};\n\n')
    open(OUT, 'w').write(''.join(out).rstrip('\n') + '\n')
    if PREVIEW:
        for name, px, part in arts:
            H, W = len(px), len(px[0])
            for state, lit in (('idle', ''), ('lit', 'bus'), ('lit2', 'acrd')):
                im = Image.new('RGBA', (W, H), (40, 40, 52, 255))
                ip = im.load()
                for y in range(H):
                    for x in range(W):
                        c = px[y][x]
                        if c is None:
                            continue
                        if part[y][x] in lit:
                            c = pressed(c)
                        ip[x, y] = (LV[c[0]], LV[c[1]], LV[c[2]], 255)
                im.resize((W * 6, H * 6), Image.NEAREST).save('%s/%s_%s.png' % (PREVIEW, name, state))
    for name, px, part in arts:
        print(name, len(px[0]), len(px), 'colours', len(colours))


main()
