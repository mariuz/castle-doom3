#!/usr/bin/env python3
"""Generate data/base/castle_doom3_test.pk4: a small original test level in
genuine Doom 3 (idTech 4) formats, so Castle Doom 3 runs without the
(non-redistributable) Doom 3 game data.

Contents (all made here, MIT licensed like the rest of the project):
  maps/testmap.proc        render geometry of 2 areas, a portal, the area BSP,
                           brush entity models (door, crate, lift)
  maps/testmap.map         entities: player start, lights, door, crate,
                           monster, speaker
  materials/test.mtr       materials with diffuse / bump (local normal maps,
                           heightmap(), addnormals()) / specular maps, a glow
  textures/test/*.tga      procedurally generated textures
  models/md5/test/blob.*   a skinned creature: md5mesh + idle / walk md5anims
  def/test.def             model decl and entityDefs
  sound/test.sndshd        sound shaders, sound/test/*.wav
  script/doom_main.script  the scriptEvents and defines the test script uses
  maps/testmap.script      the map script: a lift, a turning bar, a trigger call
  models/md5/cameras/test_flyby.md5camera  a camera anim (two shots) for a cinematic
  efxs/testmap.efx         reverb (EAX) settings: room B by area number, room A
                           by location name, a default
  blob_ranged_1            a monster throwing homing balls when activated
  blob_flyer_1             a flying monster charging when activated
  blob_dodger_1            goes to combat_node_1 when activated, then dodges
  blob_thrower_1           throws moveable_barrel_1 at the player when activated
  test_stepper_1           a character stepping aside by its anim when activated
  item_* / weapon_*_1      items in room A's south (health, armor, ammo, a
                           weapon, a key), picked up by touching; player_test
                           is the player's inventory def (def_weaponN, max_ammo)
  models/items/test/*.lwo  small boxes for the items
  models/md5/weapons/test_*  the weapons' view models (md5) and their anims;
                           the weapons' scripts are in script/doom_main.script

Run from the project root:  python tools/make_test_pk4.py
"""

import io
import math
import os
import random
import struct
import wave
import zipfile

random.seed(1234)
OUT = os.path.join(os.path.dirname(__file__), '..', 'data', 'base', 'castle_doom3_test.pk4')

files = {}


def add(path, data):
    if isinstance(data, str):
        data = data.encode('ascii')
    files[path] = data


# --------------------------------------------------------------------------
# Images

def tga(width, height, pixels, alpha=False):
    """pixels[y][x] = (r, g, b[, a]) floats 0..1, row 0 = TOP of the image.
    Written top-to-bottom (origin bit set), as Doom 3's TGAs often are."""
    bpp = 4 if alpha else 3
    header = struct.pack('<BBBHHBHHHHBB', 0, 0, 2, 0, 0, 0, 0, 0,
                         width, height, bpp * 8, (8 if alpha else 0) | 0x20)
    out = bytearray(header)
    for y in range(height):
        for x in range(width):
            p = pixels[y][x]
            c = [max(0, min(255, int(round(v * 255)))) for v in p]
            out += bytes((c[2], c[1], c[0]))
            if alpha:
                out.append(c[3] if len(c) > 3 else 255)
    return bytes(out)


def noise_grid(n, cells, seed):
    rnd = random.Random(seed)
    g = [[rnd.random() for _ in range(cells + 1)] for _ in range(cells + 1)]
    for i in range(cells + 1):
        g[i][cells] = g[i][0]
        g[cells][i] = g[0][i]

    def smooth(t):
        return t * t * (3 - 2 * t)

    res = []
    for y in range(n):
        row = []
        fy = y / n * cells
        iy = int(fy)
        ty = smooth(fy - iy)
        for x in range(n):
            fx = x / n * cells
            ix = int(fx)
            tx = smooth(fx - ix)
            a = g[iy][ix] + (g[iy][ix + 1] - g[iy][ix]) * tx
            b = g[iy + 1][ix] + (g[iy + 1][ix + 1] - g[iy + 1][ix]) * tx
            row.append(a + (b - a) * ty)
        res.append(row)
    return res


def fbm(n, seed):
    layers = [(4, 0.5), (8, 0.25), (16, 0.15), (32, 0.1)]
    grids = [noise_grid(n, c, seed + i) for i, (c, _) in enumerate(layers)]
    return [[sum(grids[i][y][x] * w for i, (_, w) in enumerate(layers)) for x in range(n)]
            for y in range(n)]


def normal_from_height(h, scale):
    """Doom 3 convention: green = +t (down the image)."""
    n = len(h)
    out = []
    for y in range(n):
        row = []
        for x in range(n):
            dx = (h[y][(x + 1) % n] - h[y][(x - 1) % n]) * scale
            dy = (h[(y + 1) % n][x] - h[(y - 1) % n][x]) * scale
            vx, vy, vz = -dx, -dy, 1.0
            l = math.sqrt(vx * vx + vy * vy + vz * vz)
            row.append((vx / l * 0.5 + 0.5, vy / l * 0.5 + 0.5, vz / l * 0.5 + 0.5))
        out.append(row)
    return out


N = 128


def floor_textures():
    """Metal floor plates with rivets and grime."""
    noise = fbm(N, 10)
    height, diff, spec = [], [], []
    for y in range(N):
        hr, dr, sr = [], [], []
        for x in range(N):
            px, py = x % 64, y % 64
            seam = px < 2 or py < 2
            rivet = any(math.hypot(px - cx, py - cy) < 2.5 for cx in (8, 56) for cy in (8, 56))
            tread = ((px + py) // 6) % 2 == 0 and not seam
            h = 0.0 if seam else (0.5 + (0.12 if tread else 0.0))
            if rivet:
                h = 0.85
            hr.append(h)
            g = noise[y][x]
            base = 0.30 + 0.25 * g
            if seam:
                base *= 0.35
            dr.append((base * 0.95, base * 0.92, base * 0.85))
            s = 0.55 * (1 - g) + (0.3 if rivet else 0) + (0.15 if tread else 0)
            sr.append((s, s, s))
        height.append(hr)
        diff.append(dr)
        spec.append(sr)
    gray = [[(v, v, v) for v in row] for row in height]
    add('textures/test/floor_d.tga', tga(N, N, diff))
    add('textures/test/floor_bmp.tga', tga(N, N, gray))
    add('textures/test/floor_s.tga', tga(N, N, spec))


def wall_textures():
    """Sci-fi wall panels: a local normal map plus a small heightmap detail."""
    noise = fbm(N, 20)
    height, diff, spec, detail = [], [], [], []
    for y in range(N):
        hr, dr, sr, de = [], [], [], []
        for x in range(N):
            px, py = x % 128, y % 64
            border = min(px, 127 - px, py, 63 - py)
            bevel = min(1.0, border / 6.0)
            vent = 40 <= px <= 88 and 22 <= py <= 42 and (py // 3) % 2 == 0
            h = bevel * 0.7 - (0.4 if vent else 0)
            hr.append(h)
            g = noise[y][x]
            c = 0.42 + 0.2 * g
            if border < 2:
                c *= 0.4
            stripe = 50 <= py <= 54
            if stripe:
                dr.append((0.55 + 0.2 * g, 0.38, 0.12))
            else:
                dr.append((c * 0.85, c * 0.9, c))
            s = 0.25 + 0.4 * g + (0.2 if stripe else 0)
            sr.append((s, s, s))
            d = 0.5 + 0.5 * (noise[(y * 3) % N][(x * 3) % N] - 0.5)
            de.append((d, d, d))
        height.append(hr)
        diff.append(dr)
        spec.append(sr)
        detail.append(de)
    add('textures/test/wall_d.tga', tga(N, N, diff))
    add('textures/test/wall_local.tga', tga(N, N, normal_from_height(height, 4.0)))
    add('textures/test/wall_bmp.tga', tga(N, N, detail))
    add('textures/test/wall_s.tga', tga(N, N, spec))


def metal_textures():
    """Hazard-striped metal for the door, crate and lift."""
    noise = fbm(N, 30)
    height, diff, spec = [], [], []
    for y in range(N):
        hr, dr, sr = [], [], []
        for x in range(N):
            border = min(x, 127 - x, y, 127 - y)
            frame = border < 10
            stripe = ((x + y) // 16) % 2 == 0
            g = noise[y][x]
            if frame:
                c = (0.8 * (0.8 + 0.2 * g), 0.62 * (0.8 + 0.2 * g), 0.1) if stripe else (0.12, 0.12, 0.12)
                h = 0.8
            else:
                v = 0.35 + 0.3 * g
                c = (v * 0.9, v * 0.95, v)
                h = 0.5 + 0.1 * (1 if (x // 8 + y // 8) % 2 else 0)
            hr.append(h)
            dr.append(c)
            s = 0.6 * (1 - g) + 0.2
            sr.append((s, s, s))
        height.append(hr)
        diff.append(dr)
        spec.append(sr)
    add('textures/test/metal_d.tga', tga(N, N, diff))
    add('textures/test/metal_local.tga', tga(N, N, normal_from_height(height, 3.0)))
    add('textures/test/metal_s.tga', tga(N, N, spec))
    # waves for the heat haze pane's distortion
    haze = [[0.5 + 0.5 * math.sin(x * 2 * math.pi / 32) * math.sin(y * 2 * math.pi / 21)
             for x in range(N)] for y in range(N)]
    add('textures/test/haze_local.tga', tga(N, N, normal_from_height(haze, 8.0)))


def ceiling_and_glow_textures():
    noise = fbm(64, 40)
    diff = [[(0.2 + 0.15 * noise[y][x],) * 3 for x in range(64)] for y in range(64)]
    add('textures/test/ceiling_d.tga', tga(64, 64, diff))
    glow = []
    for y in range(64):
        row = []
        for x in range(64):
            d = min(x, 63 - x, y, 63 - y)
            v = 1.0 if d > 6 else 0.25 + d / 8.0
            row.append((0.75 * v, 0.9 * v, 1.0 * v))
        glow.append(row)
    add('textures/test/lightpanel.tga', tga(64, 64, glow))
    # blob creature skin
    skin = []
    sn = fbm(64, 50)
    for y in range(64):
        row = []
        for x in range(64):
            g = sn[y][x]
            vein = abs(math.sin((x + 20 * g) * 0.4)) < 0.15
            row.append((0.55 + 0.3 * g, 0.18 + 0.1 * g, 0.12) if not vein else (0.85, 0.35, 0.2))
        skin.append(row)
    add('models/test/blob_d.tga', tga(64, 64, skin))
    add('models/test/blob_bmp.tga', tga(64, 64, [[(v,) * 3 for v in r] for r in sn]))
    # the player's skins: green armor plates, the same tinted red (berserk),
    # a cold glow (invisibility, added over the scene)
    armor, berserk, invis = [], [], []
    for y in range(64):
        ra, rb, ri = [], [], []
        for x in range(64):
            g = sn[y][x]
            seam = x % 16 in (0, 15) or y % 16 in (0, 15)
            v = 0.45 + 0.25 * g if not seam else 0.2
            ra.append((0.35 * v, 0.6 * v, 0.3 * v))
            rb.append((0.9 * v + 0.1, 0.12 * v, 0.08 * v))
            e = 0.35 if seam else 0.12 + 0.1 * g
            ri.append((0.3 * e, 0.55 * e, e))
        armor.append(ra)
        berserk.append(rb)
        invis.append(ri)
    add('models/test/player_d.tga', tga(64, 64, armor))
    add('models/test/player_berserk_d.tga', tga(64, 64, berserk))
    add('models/test/player_invis.tga', tga(64, 64, invis))


def stage_images():
    """A glow strip for the door's second stage, a round flare."""
    n = 64
    rows = []
    for y in range(n):
        row = []
        for x in range(n):
            # two horizontal light strips, black elsewhere (blend add)
            d = min(abs(y - 14), abs(y - 49))
            v = max(0.0, 1.0 - d / 3.0) if 6 <= x < 58 else 0.0
            row.append((1.0 * v, 0.45 * v, 0.1 * v))
        rows.append(row)
    add('textures/test/doorlights.tga', tga(n, n, rows))
    rows = []
    for y in range(n):
        row = []
        for x in range(n):
            r = math.hypot(x - 31.5, y - 31.5) / 31.5
            v = max(0.0, 1.0 - r) ** 2
            row.append((0.9 * v, 0.95 * v, 1.0 * v))
        rows.append(row)
    add('textures/test/flare.tga', tga(n, n, rows))
    rows = []
    for y in range(n):
        row = []
        for x in range(n):
            # a bullet hole: a black center, a grey rim, transparent outside
            r = math.hypot(x - 31.5, y - 31.5) / 31.5
            a = max(0.0, min(1.0, (0.9 - r) / 0.2))
            v = 0.05 + 0.3 * max(0.0, min(1.0, (r - 0.45) / 0.1))
            row.append((v, v, v, a))
        rows.append(row)
    add('textures/test/decal_hole.tga', tga(n, n, rows, alpha=True))


def sky_and_screen_images():
    """A cube map sky (Doom 3 cameraCubeMap names) and a scanline screen."""
    n = 64
    rnd = random.Random(99)
    stars = [(rnd.randrange(n), rnd.randrange(n)) for _ in range(40)]
    faces = {'forward': 0.0, 'back': 0.0, 'left': 0.0, 'right': 0.0, 'up': 1.0, 'down': -1.0}
    for name, up in faces.items():
        rows = []
        for y in range(n):
            row = []
            for x in range(n):
                # a reddish Mars-like horizon glow, darker upwards
                h = 1 - y / (n - 1)          # 1 at the top row of the image
                if up > 0:
                    k = 0.0
                elif up < 0:
                    k = 1.0
                else:
                    k = max(0.0, 1 - h * 1.6)
                r, g, b = 0.05 + 0.55 * k, 0.03 + 0.18 * k, 0.06 + 0.05 * k
                if (x, y) in stars and k < 0.4:
                    r = g = b = 0.9
                row.append((r, g, b))
            rows.append(row)
        add('env/testsky_%s.tga' % name, tga(n, n, rows))
    # an environment cube map for reflections (Doom 3 cubeMap names):
    # a color per direction, with a lighter band, so the reflection shows
    env = {'px': (0.9, 0.5, 0.2), 'nx': (0.2, 0.4, 0.9), 'py': (0.3, 0.8, 0.3),
           'ny': (0.7, 0.3, 0.8), 'pz': (0.9, 0.9, 0.9), 'nz': (0.15, 0.15, 0.15)}
    for name, (r, g, b) in env.items():
        rows = []
        for y in range(n):
            k = 1.0 if 24 <= y < 40 else 0.6
            rows.append([(r * k, g * k, b * k)] * n)
        add('env/testenv_%s.tga' % name, tga(n, n, rows))
    rows = []
    for y in range(n):
        row = []
        for x in range(n):
            line = 0.55 if (y // 2) % 2 else 1.0
            bar = 1.0 if 20 < (x + y // 3) % 40 < 34 else 0.35
            row.append((0.2 * line * bar, 0.9 * line * bar, 0.5 * line * bar))
        rows.append(row)
    add('textures/test/screen.tga', tga(n, n, rows))


PANEL_GUI = """// Castle Doom 3 test GUI (generated by tools/make_test_pk4.py)
// An interactive panel: a blinking light (its own time line), a button
// with mouse enter / exit colors whose click activates the entity's
// targets and runs a map script function, a transition at the start.
windowDef Desktop
{
	rect	0, 0, 640, 480
	backcolor	0.02, 0.06, 0.1, 1
	font	"fonts/test"
	definevec4 "$gui::hilite" 1, 1, 1, 1
	definevec4 "buttoncolor" 0.1, 0.3, 0.5, 1

	windowDef bg
	{
		rect	0, 0, 640, 480
		background	"guis/assets/test/panelbg"
		matcolor	1, 1, 1, 0.6
		noevents	1
	}
	windowDef header
	{
		rect	0, 0, 640, 110
		backcolor	0.55, 0.08, 0.04, 0.85
		text	"gui::gui_parm1"
		textscale	1.2
		textalign	1
		forecolor	1, 0.9, 0.8, 1
		textaligny	10
		noevents	1
	}
	windowDef body
	{
		rect	30, 150, 580, 230
		text	"gui::gui_parm2"
		textscale	0.6
		forecolor	0.6, 0.9, 1, 1
		bordersize	3
		bordercolor	0.6, 0.9, 1, 0.6
		textalignx	14
		textaligny	10
		noevents	1
	}
	windowDef hidden
	{
		rect	0, 0, 640, 480
		visible	0
		backcolor	1, 0, 0, 1
	}
	windowDef blink
	{
		rect	580, 20, 40, 40
		backcolor	1, 0.8, 0.2, 1
		noevents	1
		onTime 0 {
			set "visible" "1" ;
		}
		onTime 500 {
			set "visible" "0" ;
		}
		onTime 1000 {
			resetTime "0" ;
		}
	}
	windowDef button
	{
		rect	200, 400, 240, 60
		backcolor	"$buttoncolor"
		bordersize	2
		bordercolor	0.6, 0.9, 1, 1
		text	"ACTIVATE"
		textscale	0.5
		textalign	1
		textaligny	16
		forecolor	1, 1, 1, 1
		onMouseEnter {
			set "backcolor" "0.2 0.5 0.8 1" ;
		}
		onMouseExit {
			set "backcolor" "$buttoncolor" ;
		}
		onAction {
			set "cmd" "activate" ;
			set "gui::gui_clicked" "CLICKED" ;
			transition "header::backcolor" "1 1 0.2 1" "0.55 0.08 0.04 0.85" "800" ;
			runScript "test_gui_clicked" ;
		}
	}
	windowDef status
	{
		rect	30, 440, 160, 30
		text	"gui::gui_clicked"
		textscale	0.3
		forecolor	1, 1, 0.6, 1
		noevents	1
	}
	onTime 0 {
		transition "body::forecolor" "0 0 0 1" "0.6 0.9 1 1" "500" ;
	}
	onAction {
		set "cmd" "activate" ;
	}
}
"""

STATUS_GUI = """// Castle Doom 3 test status screen (generated by tools/make_test_pk4.py)
windowDef Desktop
{
	rect	0, 0, 640, 480
	backcolor	0, 0.08, 0.04, 1
	windowDef title
	{
		rect	20, 20, 600, 80
		text	"ENVIRONMENT STATUS"
		textscale	0.8
		forecolor	0.3, 1, 0.5, 1
	}
	windowDef bar1 { rect 40, 150, 480, 40  backcolor 0.2, 0.8, 0.3, 1 }
	windowDef bar2 { rect 40, 220, 300, 40  backcolor 0.9, 0.7, 0.1, 1 }
	windowDef bar3 { rect 40, 290, 120, 40  backcolor 0.9, 0.2, 0.1, 1 }
	windowDef footer
	{
		rect	20, 380, 600, 80
		text	"O2  PRESSURE  RADIATION"
		textscale	0.5
		textalign	2
		forecolor	0.6, 1, 0.7, 1
	}
}
"""


def font_assets():
    """A Doom 3 font (fonts/<lang>/test/fontImage_12|24|48.dat and their
    glyph pages), rendered with a TrueType font through PIL: 256
    glyphInfo_t records (7 ints, 4 floats, 1 int, char[32]), glyphScale,
    char[64]; the glyph pages are RGBA TGAs with the glyph in the alpha."""
    from PIL import Image, ImageDraw, ImageFont
    import struct
    for point_size in (12, 24, 48):
        try:
            font = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf', point_size)
        except OSError:
            font = ImageFont.load_default(size=point_size)
        ascent, descent = font.getmetrics()
        cell_h = ascent + descent
        cells = []
        for code in range(32, 127):
            ch = chr(code)
            advance = font.getlength(ch)
            x0, y0, x1, y1 = font.getbbox(ch)
            cw = max(1, int(round(max(advance, x1))) + 1)
            cell = Image.new('L', (cw, cell_h), 0)
            ImageDraw.Draw(cell).text((0, 0), ch, font=font, fill=255)
            cells.append((code, cell, advance))
        # pack the cells into one page, left to right, rows of cell_h
        page_size = 256
        while True:
            x = y = 0
            ok = True
            for code, cell, advance in cells:
                if x + cell.width > page_size:
                    x = 0
                    y += cell_h + 1
                if y + cell_h > page_size:
                    ok = False
                    break
                x += cell.width + 1
            if ok:
                break
            page_size *= 2
        page = Image.new('RGBA', (page_size, page_size), (255, 255, 255, 0))
        x = y = 0
        records = {}
        for code, cell, advance in cells:
            if x + cell.width > page_size:
                x = 0
                y += cell_h + 1
            page.paste((255, 255, 255, 255), (x, y, x + cell.width, y + cell_h), cell)
            records[code] = (x, y, cell.width, advance)
            x += cell.width + 1
        shader = 'fonts/test_0_%d' % point_size
        data = bytearray()
        for code in range(256):
            if code in records:
                x, y, w, advance = records[code]
                data += struct.pack('<7i', cell_h, ascent, descent, w, int(round(advance)), w, cell_h)
                data += struct.pack('<4f', x / page_size, y / page_size,
                                    (x + w) / page_size, (y + cell_h) / page_size)
                data += struct.pack('<i', 0)
                data += shader.encode('ascii').ljust(32, b'\0')
            else:
                data += bytes(80)
        data += struct.pack('<f', 48.0 / point_size)
        data += b'fonts/test'.ljust(64, b'\0')
        add('fonts/english/test/fontImage_%d.dat' % point_size, bytes(data))
        rows = []
        px = page.load()
        for py in range(page_size):
            rows.append([tuple(c / 255.0 for c in px[qx, py]) for qx in range(page_size)])
        add('fonts/english/test/test_0_%d.tga' % point_size, tga(page_size, page_size, rows, alpha=True))


def cursor_assets():
    """ui/assets/guicursor_arrow.tga: a white arrow with a dark outline,
    32 x 32, its tip at the top left (drawn 64 units big in entity GUIs)."""
    n = 32
    arrow = [(0, 0), (0, 22), (6, 17), (10, 27), (14, 25), (10, 15), (17, 15)]

    def inside(px, py, pts):
        crossings = 0
        j = len(pts) - 1
        for i in range(len(pts)):
            (xi, yi), (xj, yj) = pts[i], pts[j]
            if (yi > py) != (yj > py) and px < (xj - xi) * (py - yi) / (yj - yi) + xi:
                crossings += 1
            j = i
        return crossings % 2 == 1

    outer = [(x * 1.3, y * 1.3) for (x, y) in arrow]
    inner = [(x * 1.0 + 1.5, y * 1.0 + 1.5) for (x, y) in arrow]
    rows = []
    for y in range(n):
        row = []
        for x in range(n):
            if inside(x + 0.5, y + 0.5, inner):
                row.append((1.0, 1.0, 1.0, 1.0))
            elif inside(x + 0.5, y + 0.5, outer):
                row.append((0.05, 0.05, 0.1, 1.0))
            else:
                row.append((0.0, 0.0, 0.0, 0.0))
        rows.append(row)
    add('ui/assets/guicursor_arrow.tga', tga(n, n, rows, alpha=True))


def gui_assets():
    font_assets()
    cursor_assets()
    n = 64
    rows = []
    for y in range(n):
        row = []
        for x in range(n):
            grid = (x % 16 == 0) or (y % 16 == 0)
            v = 0.35 if grid else 0.08
            row.append((v * 0.5, v * 0.9, v, 1.0))
        rows.append(row)
    add('guis/assets/test/panelbg.tga', tga(n, n, rows, alpha=True))
    add('guis/test_panel.gui', PANEL_GUI)
    add('guis/test_status.gui', STATUS_GUI)


def particle_textures():
    """Particle images: a soft smoke puff (alpha), an additive spark and a
    4-frame strip of growing rings (animationFrames 4)."""
    n = 64
    rows = []
    rnd = random.Random(5)
    for y in range(n):
        row = []
        for x in range(n):
            r = math.hypot(x - 31.5, y - 31.5) / 31.5
            a = max(0.0, 1.0 - r) ** 1.5 * (0.85 + 0.15 * rnd.random())
            row.append((1.0, 1.0, 1.0, a))
        rows.append(row)
    add('textures/particles/test_smoke.tga', tga(n, n, rows, alpha=True))
    n = 32
    rows = []
    for y in range(n):
        row = []
        for x in range(n):
            r = math.hypot(x - 15.5, y - 15.5) / 15.5
            v = max(0.0, 1.0 - r) ** 3
            row.append((1.0 * v, 0.9 * v, 0.6 * v))
        rows.append(row)
    add('textures/particles/test_spark.tga', tga(n, n, rows))
    rows = []
    for y in range(n):
        row = []
        for frame in range(4):
            for x in range(n):
                r = math.hypot(x - 15.5, y - 15.5) / 15.5
                ring = 0.25 + 0.2 * frame
                v = max(0.0, 1.0 - abs(r - ring) / 0.12)
                row.append((1.0 * v, 0.7 * v, 0.3 * v))
        rows.append(row)
    add('textures/particles/test_flash.tga', tga(4 * n, n, rows))


def light_images():
    """Light projection and falloff images, like Doom 3's lights/ folder."""
    def smooth(e0, e1, x):
        t = max(0.0, min(1.0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)

    n = 64
    rows = []
    for y in range(n):
        row = []
        for x in range(n):
            r = math.hypot((x + 0.5) / n * 2 - 1, (y + 0.5) / n * 2 - 1)
            v = 1 - smooth(0.75, 1.0, r)
            row.append((v, v, v))
        rows.append(row)
    add('lights/round.tga', tga(n, n, rows))
    rows = []
    for y in range(n):
        row = []
        for x in range(n):
            ex = min((x + 0.5) / n, 1 - (x + 0.5) / n) * 2
            ey = min((y + 0.5) / n, 1 - (y + 0.5) / n) * 2
            v = smooth(0.0, 0.25, ex) * smooth(0.0, 0.25, ey)
            row.append((v, v, v))
        rows.append(row)
    add('lights/squarelight1.tga', tga(n, n, rows))
    # falloff along the light box's z: 1 in the middle, 0 at the ends
    row = []
    for x in range(n):
        d = abs((x + 0.5) / n * 2 - 1)
        v = 1 - smooth(0.3, 1.0, d)
        row.append((v, v, v))
    add('lights/squarelight1a.tga', tga(n, 4, [row] * 4))
    # projected lights: bright near the light, fading to the end
    row = []
    for x in range(n):
        q = (x + 0.5) / n
        v = (1 - smooth(0.85, 1.0, q)) * smooth(0.0, 0.05, q)
        row.append((v, v, v))
    add('lights/projfalloff.tga', tga(n, 4, [row] * 4))
    # a projected pattern: a soft disc with a cross (stained glass style)
    rows = []
    for y in range(n):
        row = []
        for x in range(n):
            u, v = (x + 0.5) / n * 2 - 1, (y + 0.5) / n * 2 - 1
            disc = 1 - smooth(0.8, 1.0, math.hypot(u, v))
            cross = 0.35 if (abs(u) < 0.06 or abs(v) < 0.06) else 1.0
            row.append((disc * cross, disc * cross * 0.95, disc * cross * 0.8))
        rows.append(row)
    add('lights/window.tga', tga(n, n, rows))


# --------------------------------------------------------------------------
# Geometry (.proc)

class Surface:
    def __init__(self, material):
        self.material = material
        self.verts = []
        self.indexes = []

    def quad(self, corners, normal, uv_axes, uv_scale=1 / 128.0):
        """corners counter-clockwise seen from the front (normal side);
        written clockwise, as Doom 3 expects."""
        base = len(self.verts)
        (sa, ta) = uv_axes
        for p in corners:
            s = sum(p[i] * sa[i] for i in range(3)) * uv_scale
            t = sum(p[i] * ta[i] for i in range(3)) * uv_scale
            self.verts.append((p, (s, t), normal))
        self.indexes += [base, base + 2, base + 1, base, base + 3, base + 2]


class Model:
    def __init__(self, name):
        self.name = name
        self.surfaces = {}

    def surf(self, material):
        if material not in self.surfaces:
            self.surfaces[material] = Surface(material)
        return self.surfaces[material]


# UV axes: (s axis, t axis); t goes "down" on walls
UV_FLOOR = ((1, 0, 0), (0, -1, 0))
UV_X_WALL = ((0, 1, 0), (0, 0, -1))   # wall facing +X or -X
UV_Y_WALL = ((1, 0, 0), (0, 0, -1))


def wall_rect(model, mat, axis, coord, normal_sign, u0, u1, v0, v1, uv_scale=1 / 128.0):
    """An axis-aligned rectangle on plane <axis> = coord, facing normal_sign
    along the axis. (u, v) are the other two axes in (x, y, z) order, v = z
    for walls, y for floors."""
    if axis == 'x':
        pts = [(coord, u0, v0), (coord, u1, v0), (coord, u1, v1), (coord, u0, v1)]
        normal = (normal_sign, 0, 0)
        uv = UV_X_WALL
    elif axis == 'y':
        pts = [(u0, coord, v0), (u1, coord, v0), (u1, coord, v1), (u0, coord, v1)]
        normal = (0, normal_sign, 0)
        uv = UV_Y_WALL
    else:
        pts = [(u0, v0, coord), (u1, v0, coord), (u1, v1, coord), (u0, v1, coord)]
        normal = (0, 0, normal_sign)
        uv = UV_FLOOR
    # make the corner order counter-clockwise around the normal
    a, b, c = pts[0], pts[1], pts[2]
    e1 = [b[i] - a[i] for i in range(3)]
    e2 = [c[i] - a[i] for i in range(3)]
    cr = (e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0])
    if sum(cr[i] * normal[i] for i in range(3)) < 0:
        pts.reverse()
    model.surf(mat).quad(pts, normal, uv, uv_scale)


def box(model, mat, mins, maxs, inward=False, skip=()):
    """Six faces of a box, facing out (solid object) or in (a room)."""
    s = -1 if inward else 1
    (x0, y0, z0), (x1, y1, z1) = mins, maxs
    faces = {
        '+x': ('x', x1, s, y0, y1, z0, z1),
        '-x': ('x', x0, -s, y0, y1, z0, z1),
        '+y': ('y', y1, s, x0, x1, z0, z1),
        '-y': ('y', y0, -s, x0, x1, z0, z1),
        '+z': ('z', z1, s, x0, x1, y0, y1),
        '-z': ('z', z0, -s, x0, x1, y0, y1),
    }
    for key, (axis, c, ns, u0, u1, v0, v1) in faces.items():
        if key in skip:
            continue
        m = mat
        if isinstance(mat, dict):
            m = mat.get(key, mat.get('*'))
        wall_rect(model, m, axis, c, ns, u0, u1, v0, v1)


GUISCREEN = 'textures/test/guiscreen'
STATUSSCREEN = 'textures/test/statusscreen'


def gui_quad(model, mat, corners, normal):
    """A GUI surface: corners counter-clockwise from the front starting at
    the bottom left; texture coordinates cover the GUI (Doom 3 t goes down)."""
    surf = model.surf(mat)
    base = len(surf.verts)
    for p, st in zip(corners, ((0, 1), (1, 1), (1, 0), (0, 0))):
        surf.verts.append((p, st, normal))
    surf.indexes += [base, base + 2, base + 1, base, base + 3, base + 2]


FLOOR = 'textures/test/floor'
WALL = 'textures/test/wall'
CEIL = 'textures/test/ceiling'
METAL = 'textures/test/metal'
GLOW = 'textures/test/lightpanel'
TRIGONCE = 'textures/common/trigonce'
DOOR = 'textures/test/door'
GLASS = 'textures/test/glass'
HAZE = 'textures/test/hazeglass'
SHINY = 'textures/test/shinymetal'
FLARE = 'textures/test/flare'
DECAL = 'textures/test/decal_hole'
POOL = 'textures/test/pool'
HAZEWALL = 'textures/test/hazewall'
FLARE2 = 'textures/test/flare2'
CRATEGLOW = 'textures/test/crateglow'

# Room A: x -256..256, y -256..256, z 0..192
# Doorway tunnel (area 1): x 256..272, y -48..48, z 0..112
# Room B: x 272..912, y -384..384, z 0..288, steps up to a balcony at x > 720

area0 = Model('_area0')
area1 = Model('_area1')

# Room A
room_a = {'*': WALL, '+z': CEIL, '-z': FLOOR}
box(area0, room_a, (-256, -256, 0), (256, 256, 192), inward=True, skip=('+x',))
# east wall with the doorway hole (facing -X, into the room)
wall_rect(area0, WALL, 'x', 256, -1, -256, -48, 0, 192)
wall_rect(area0, WALL, 'x', 256, -1, 48, 256, 0, 192)
wall_rect(area0, WALL, 'x', 256, -1, -48, 48, 112, 192)
# glowing light panels on the ceiling
for (cx, cy) in ((-128, -128), (128, 128), (-128, 128), (128, -128)):
    wall_rect(area0, GLOW, 'z', 191, -1, cx - 24, cx + 24, cy - 24, cy + 24)
# pillars
box(area0, SHINY, (-176, 136, 0), (-136, 176, 192))
# a free standing glass pane (two sided, not in the .cm)
wall_rect(area0, GLASS, 'y', -220, 1, -40, 60, 16, 144)
# a flare (deform sprite) under light_1
wall_rect(area0, FLARE, 'z', 176, -1, -12, 12, -12, 12)
# a decal (polygonOffset) in the floor's plane, west of the start: one
# whole texture over the 32 x 32 rectangle
wall_rect(area0, DECAL, 'z', 0, 1, -128, -96, -128, -96, uv_scale=1 / 32.0)

# doorway tunnel
wall_rect(area1, FLOOR, 'z', 0, 1, 256, 272, -48, 48)
wall_rect(area1, CEIL, 'z', 112, -1, 256, 272, -48, 48)
wall_rect(area1, WALL, 'y', -48, 1, 256, 272, 0, 112)
wall_rect(area1, WALL, 'y', 48, -1, 256, 272, 0, 112)

# Room B
room_b = {'*': WALL, '+z': CEIL, '-z': FLOOR}
box(area1, room_b, (272, -384, 0), (912, 384, 288), inward=True, skip=('-x', '+z'))
# the ceiling around the skylight hole (facing down)
for (x0, x1, y0, y1) in ((272, 560, -384, 384), (720, 912, -384, 384),
                         (560, 720, -384, -96), (560, 720, 96, 384)):
    wall_rect(area1, CEIL, 'z', 288, -1, x0, x1, y0, y1)
# the skylight shaft and its sky
wall_rect(area1, WALL, 'x', 560, 1, -96, 96, 288, 352)
wall_rect(area1, WALL, 'x', 720, -1, -96, 96, 288, 352)
wall_rect(area1, WALL, 'y', -96, 1, 560, 720, 288, 352)
wall_rect(area1, WALL, 'y', 96, -1, 560, 720, 288, 352)
wall_rect(area1, 'textures/test/sky', 'z', 352, -1, 560, 720, -96, 96)
wall_rect(area1, WALL, 'x', 272, 1, -384, -48, 0, 288)
wall_rect(area1, WALL, 'x', 272, 1, 48, 384, 0, 288)
wall_rect(area1, WALL, 'x', 272, 1, -48, 48, 112, 288)
# a free standing heat haze pane (two sided, not in the .cm)
wall_rect(area1, HAZE, 'y', -300, 1, 330, 450, 8, 136)
# a lit wall panel with a heat haze stage (not glass), on the west wall
wall_rect(area1, HAZEWALL, 'x', 273, 1, 200, 300, 8, 100)
# a rippling pool (deform turbulent) on the floor
wall_rect(area1, POOL, 'z', 0.5, 1, 300, 380, 120, 200)
# a flare (deform flare 24) under light_5
wall_rect(area1, FLARE2, 'z', 196, -1, 816, 824, -4, 4)
for (cx, cy) in ((448, -192), (448, 192), (640, 250)):
    wall_rect(area1, GLOW, 'z', 287, -1, cx - 32, cx + 32, cy - 32, cy + 32)
# a status screen on the north wall of room B (y = 384, facing -Y: right is +X)
gui_quad(area1, STATUSSCREEN, [(330, 383, 110), (440, 383, 110), (440, 383, 192), (330, 383, 192)], (0, -1, 0))
# stairs: 6 steps of 16 up to a balcony 96 high at x 720..912
for i in range(6):
    x0 = 624 + i * 16
    box(area1, {'*': METAL, '+z': FLOOR}, (x0, -128, 0), (x0 + 16, 128, 16 * (i + 1)),
        skip=('-z', '+x'))
box(area1, {'*': METAL, '+z': FLOOR}, (720, -384, 0), (912, 384, 96), skip=('-z', '+x', '+y', '-y'))
# pillars in room B
for cy in (-256, 256):
    box(area1, METAL, (480, cy - 24, 0), (528, cy + 24, 288), skip=('-z', '+z'))

# Brush entity models, in entity-local coordinates
door = Model('door_1')
box(door, {'*': METAL, '+x': DOOR, '-x': DOOR}, (-4, -48, -56), (4, 48, 56))
crate = Model('crate_1')
box(crate, METAL, (-32, -32, -32), (32, 32, 32))
crate2 = Model('crate_2')
box(crate2, CRATEGLOW, (-24, -24, -24), (24, 24, 24))
panel = Model('panel_1')
box(panel, METAL, (-2, -32, -24), (2, 32, 24), skip=('+x',))
gui_quad(panel, GUISCREEN, [(2, -32, -24), (2, 32, -24), (2, 32, 24), (2, -32, 24)], (1, 0, 0))
# a second door of door_1's team: a bar over the doorway on room B's side,
# rotated 90 degrees (its local y is world x), sliding +x
door2 = Model('door_2')
box(door2, METAL, (-4, -24, -8), (4, 24, 8))
# a small light panel bound to door_1 (it rides up with the door)
doorlight = Model('door_light_1')
box(doorlight, GLOW, (-1, -8, -8), (1, 8, 8))
# a lift in room B moved by the map script (func_mover)
lift = Model('lift_1')
box(lift, {'*': METAL, '+z': FLOOR}, (-32, -32, -4), (32, 32, 4))
# a bar the map script turns by 90 degrees (it reaches along local +x)
bar = Model('bar_1')
box(bar, {'*': METAL, '+x': FLOOR}, (0, -4, -4), (48, 4, 4))
# a bar to crouch under in room A: its bottom at 52, so a standing player
# (74 high) can't pass, a crouching one (38) can
crawl = Model('crawl_bar_1')
box(crawl, {'*': METAL}, (-8, -40, -6), (8, 40, 6))
spinner = Model('spinner_1')
box(spinner, {'*': METAL}, (-64, -6, -6), (64, 6, 6))
box(spinner, {'*': METAL}, (-6, -64, -6), (6, 64, 6))


def fmt(v):
    s = '%.6f' % v
    s = s.rstrip('0').rstrip('.')
    return s if s not in ('-0', '') else '0'


def box_shadow_volume(mn, mx, light, scale=4.0):
    """The closed shadow volume of a box from a point light, like dmap's
    prelight shadow models: the lit faces (near caps), the same faces moved
    away from the light (far caps), and quads on their outline edges.
    Triangles clockwise seen from outside (Doom 3 front faces).
    Returns (vertexes, indexes, noCaps, noFrontCaps)."""
    x0, y0, z0 = mn
    x1, y1, z1 = mx
    corner = lambda i: (x1 if i & 1 else x0, y1 if i & 2 else y0, z1 if i & 4 else z0)
    # faces counter-clockwise from outside, with their outward normal
    faces = [((0, 2, 6, 4), (-1, 0, 0)), ((1, 5, 7, 3), (1, 0, 0)),
             ((0, 4, 5, 1), (0, -1, 0)), ((2, 3, 7, 6), (0, 1, 0)),
             ((0, 1, 3, 2), (0, 0, -1)), ((4, 6, 7, 5), (0, 0, 1))]
    def lit(face):
        quad, n = face
        p = corner(quad[0])
        return sum(n[k] * (light[k] - p[k]) for k in range(3)) > 0
    far = lambda p: tuple(p[k] + (p[k] - light[k]) * scale for k in range(3))
    verts = [corner(i) for i in range(8)] + [far(corner(i)) for i in range(8)]
    sides, back, front = [], [], []
    lit_faces = [f for f in faces if lit(f)]
    for quad, n in lit_faces:
        a, b, c, d = quad
        # near cap (outward = towards the light) and far cap (reversed)
        front += [a, b, c, a, c, d]
        back += [8 + a, 8 + c, 8 + b, 8 + a, 8 + d, 8 + c]
    # outline edges: edges of lit faces not shared with another lit face
    edges = {}
    for quad, n in lit_faces:
        for k in range(4):
            e = (quad[k], quad[(k + 1) % 4])
            edges[e] = edges.get(e, 0) + 1
    for (a, b) in list(edges):
        if (b, a) in edges:
            continue
        sides += [b, a, 8 + a, b, 8 + a, 8 + b]
    ccw = sides + back + front
    # Doom 3 front faces are clockwise: reverse every triangle
    cw = []
    for i in range(0, len(ccw), 3):
        cw += [ccw[i], ccw[i + 2], ccw[i + 1]]
    return verts, cw, len(sides), len(sides) + len(back)


def proc_text():
    out = ['mapProcFile003', '']
    for m in (area0, area1, door, crate, crate2, spinner, panel, door2, doorlight, lift, bar, crawl):
        surfs = list(m.surfaces.values())
        out.append('model { /* name = */ "%s" /* numSurfaces = */ %d' % (m.name, len(surfs)))
        out.append('')
        for i, s in enumerate(surfs):
            out.append('/* surface %d */ { "%s" /* numVerts = */ %d /* numIndexes = */ %d'
                       % (i, s.material, len(s.verts), len(s.indexes)))
            line = []
            for (p, st, n) in s.verts:
                line.append('( %s %s %s %s %s %s %s %s )' % tuple(
                    fmt(v) for v in (p[0], p[1], p[2], st[0], st[1], n[0], n[1], n[2])))
                if len(line) == 3:
                    out.append(' '.join(line))
                    line = []
            if line:
                out.append(' '.join(line))
            idx = [str(i) for i in s.indexes]
            for k in range(0, len(idx), 18):
                out.append(' '.join(idx[k:k + 18]) + ' ')
            out.append('}')
            out.append('')
        out.append('}')
        out.append('')
    # light_1's precomputed shadow volume of the room A pillar
    verts, idx, no_caps, no_front_caps = box_shadow_volume((-176, 136, 0), (-136, 176, 192), (0, 0, 160))
    out.append('shadowModel { /* name = */ "_prelight_light_1"')
    out.append('')
    out.append('/* numVerts = */ %d /* noCaps = */ %d /* noFrontCaps = */ %d /* numIndexes = */ %d /* planeBits = */ 0'
               % (len(verts), no_caps, no_front_caps, len(idx)))
    out.append(' '.join('( %s %s %s )' % tuple(fmt(c) for c in v) for v in verts))
    out.append(' '.join(str(i) for i in idx) + ' ')
    out.append('}')
    out.append('')
    # one portal: the doorway at x = 256 between area 0 (-x side) and area 1
    out.append('interAreaPortals { /* numAreas = */ 2 /* numIAP = */ 1')
    out.append('')
    out.append('/* interAreaPortal format is: numPoints positiveSideArea negativeSideArea ( point) ... */')
    out.append('/* iap 0 */ 4 1 0 ( 256 -48 0 ) ( 256 48 0 ) ( 256 48 112 ) ( 256 -48 112 ) ')
    out.append('}')
    out.append('')
    out.append('nodes { /* numNodes = */ 1')
    out.append('')
    out.append('/* node format is: ( planeVector ) positiveChild negativeChild */')
    out.append('/* a child number of 0 is an opaque, solid area */')
    out.append('/* negative child numbers are areas: (-1-child) */')
    out.append('/* node 0 */ ( 1 0 0 -256 ) -2 -1 ')
    out.append('}')
    out.append('')
    return '\n'.join(out)


# --------------------------------------------------------------------------
# Collision model (.cm)

CLIP = 'textures/common/clip'
MONSTER_CLIP = 'textures/common/monster_clip'


def quads_of(model, skip=()):
    """The polygons (4 corners, counter-clockwise from the front) and
    materials of a Model's surfaces; Surface.quad always adds 4 vertexes."""
    for surf in model.surfaces.values():
        if surf.material in skip:
            continue
        for k in range(0, len(surf.verts), 4):
            yield [surf.verts[k + c][0] for c in range(4)], surf.material


def box_quads(mins, maxs, material):
    m = Model('tmp')
    box(m, material, mins, maxs)
    return list(quads_of(m))


def cm_model(name, polygons, brushes=()):
    """polygons: (corners, material); brushes: (mins, maxs, contents)."""
    verts, vindex = [], {}
    edges, eindex = [(0, 0)], {}

    def vi(p):
        key = tuple(round(c, 4) for c in p)
        if key not in vindex:
            vindex[key] = len(verts)
            verts.append(key)
        return vindex[key]

    polys = []
    for corners, material in polygons:
        ids = [vi(c) for c in corners]
        pedges = []
        for k in range(len(ids)):
            a, b = ids[k], ids[(k + 1) % len(ids)]
            if (a, b) in eindex:
                pedges.append(eindex[(a, b)])
            elif (b, a) in eindex:
                pedges.append(-eindex[(b, a)])
            else:
                eindex[(a, b)] = len(edges)
                edges.append((a, b))
                pedges.append(eindex[(a, b)])
        p0, p1, p2 = corners[0], corners[1], corners[2]
        e1 = [p1[i] - p0[i] for i in range(3)]
        e2 = [p2[i] - p0[i] for i in range(3)]
        n = (e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0])
        ln = math.sqrt(sum(c * c for c in n)) or 1
        n = tuple(c / ln for c in n)
        dist = sum(n[i] * p0[i] for i in range(3))
        mins = [min(c[i] for c in corners) for i in range(3)]
        maxs = [max(c[i] for c in corners) for i in range(3)]
        polys.append((pedges, n, dist, mins, maxs, material))

    out = ['collisionModel "%s" {' % name, '\tvertices { /* numVertices = */ %d' % len(verts)]
    for i, v in enumerate(verts):
        out.append('\t/* %d */ ( %s %s %s )' % (i, fmt(v[0]), fmt(v[1]), fmt(v[2])))
    out += ['\t}', '\tedges { /* numEdges = */ %d' % len(edges)]
    for i, (a, b) in enumerate(edges):
        out.append('\t/* %d */ ( %d %d ) 0 %d' % (i, a, b, 0 if i == 0 else 2))
    out += ['\t}', '\tnodes {', '\t( -1 0 )', '\t}',
            '\tpolygons /* numPolygons = */ %d /* numPolygonEdges = */ %d {'
            % (len(polys), sum(len(pp[0]) for pp in polys))]
    for (pedges, n, dist, mins, maxs, material) in polys:
        out.append('\t%d ( %s ) ( %s %s %s ) %s ( %s %s %s ) ( %s %s %s ) "%s"' % (
            len(pedges), ' '.join(str(e) for e in pedges), fmt(n[0]), fmt(n[1]), fmt(n[2]), fmt(dist),
            fmt(mins[0]), fmt(mins[1]), fmt(mins[2]), fmt(maxs[0]), fmt(maxs[1]), fmt(maxs[2]), material))
    out += ['\t}', '\tbrushes /* numBrushes = */ %d /* numBrushSides = */ %d {'
            % (len(brushes), 6 * len(brushes))]
    for (mins, maxs, contents) in brushes:
        out.append('\t6 {')
        for axis in range(3):
            n = [0, 0, 0]
            n[axis] = 1
            out.append('\t\t( %d %d %d ) %s' % (n[0], n[1], n[2], fmt(maxs[axis])))
            n[axis] = -1
            out.append('\t\t( %d %d %d ) %s' % (n[0], n[1], n[2], fmt(-mins[axis])))
        out.append('\t} ( %s %s %s ) ( %s %s %s ) "%s"' % (
            fmt(mins[0]), fmt(mins[1]), fmt(mins[2]), fmt(maxs[0]), fmt(maxs[1]), fmt(maxs[2]), contents))
    out += ['\t}', '}']
    return '\n'.join(out)


def cm_text():
    world = list(quads_of(area0, skip=(GLOW,))) + list(quads_of(area1, skip=(GLOW,)))
    # an invisible playerclip wall across the west of room A (y = 0, x -256..-120)
    clip_box = ((-256, -4, 0), (-120, 4, 192))
    world += box_quads(clip_box[0], clip_box[1], CLIP)
    # a monster clip strip the player walks through (x = -40, y -256..-80)
    world += box_quads((-44, -256, 0), (-36, -80, 192), MONSTER_CLIP)
    brushes = [(clip_box[0], clip_box[1], 'playerclip')]
    # the solid brushes of the level (like dmap writes them): 16 unit walls
    # around both rooms, floors, ceilings, pillars and the balcony
    solids = [
        # room A
        ((-272, -272, -16), (-256, 272, 208)),        # west wall
        ((-256, -272, -16), (256, -256, 208)),        # south wall
        ((-256, 256, -16), (256, 272, 208)),          # north wall
        ((-256, -256, -16), (256, 256, 0)),           # floor
        ((-256, -256, 192), (256, 256, 208)),         # ceiling
        ((-176, 136, 0), (-136, 176, 192)),           # pillar
        # the wall between the rooms, with the doorway
        ((256, -400, -16), (272, -48, 304)),
        ((256, 48, -16), (272, 400, 304)),
        ((256, -48, 112), (272, 48, 304)),
        # room B
        ((912, -400, -16), (928, 400, 304)),          # east wall
        ((272, -400, -16), (912, -384, 304)),         # south wall
        ((272, 384, -16), (912, 400, 304)),           # north wall
        ((272, -384, -16), (912, 384, 0)),            # floor
        ((272, -384, 288), (560, 384, 304)),          # ceiling around the skylight
        ((720, -384, 288), (912, 384, 304)),
        ((560, -384, 288), (720, -96, 304)),
        ((560, 96, 288), (720, 384, 304)),
        ((480, -280, 0), (528, -232, 288)),           # pillars
        ((480, 232, 0), (528, 280, 288)),
        ((720, -384, 0), (912, 384, 96)),             # balcony
    ]
    brushes += [(mins, maxs, 'solid,opaque') for mins, maxs in solids]
    out = ['CM "1.00"', '', '1234567890', '']
    out.append(cm_model('worldMap', world, brushes))
    for m in (door, crate, crate2, spinner, panel, door2, doorlight, lift, bar, crawl):
        out.append(cm_model(m.name, list(quads_of(m)), []))
    # the volume of trigger_once_1 (entity-local, like dmap writes it)
    out.append(cm_model('trigger_once_1', box_quads((-24, -80, -56), (24, 80, 56), TRIGONCE), []))
    # the volume of trigger_once_cin, which starts the cinematic
    out.append(cm_model('trigger_once_cin', box_quads((-24, -24, -56), (24, 24, 56), TRIGONCE), []))
    # the volume of trigger_hurt_1
    out.append(cm_model('trigger_hurt_1', box_quads((-24, -24, -56), (24, 24, 56), TRIGONCE), []))
    return '\n'.join(out) + '\n'


# --------------------------------------------------------------------------
# Entities (.map)

# AAS areas of the test map for a 48 unit wide monster (the walls inset by
# 24): (area, mins, maxs), Doom 3 coordinates; the pillars are left out
AAS_AREAS = [
    (1, (-232, -232, 0), (232, 232, 192)),     # room A
    (2, (232, -24, 0), (296, 24, 112)),        # the doorway
    (3, (296, -360, 0), (696, 360, 288)),      # room B's floor and stairs
    (4, (696, -360, 80), (888, 360, 288)),     # the balcony
]
# reachabilities: (from area, travel type, to area, start, end, travel time)
AAS_REACH = [
    (1, 2, 2, (232, 0, 0), (232.5, 0, 0), 10),
    (2, 2, 1, (232, 0, 0), (231.5, 0, 0), 10),
    (2, 2, 3, (296, 0, 0), (296.5, 0, 0), 10),
    (3, 2, 2, (296, 0, 0), (295.5, 0, 0), 10),
    (3, 2, 4, (696, 0, 96), (696.5, 0, 96), 30),   # up the stairs
    (4, 2, 3, (696, 0, 96), (695.5, 0, 96), 30),   # down the stairs
    (4, 4, 3, (696, 250, 96), (695.5, 250, 0), 40),  # off the balcony's edge
]


def aas_text():
    """An AAS file ("DewmAAS", like dmap writes for monsters 48 units wide)
    of the test map: box areas, a BSP of axis planes splitting them, and
    the reachabilities between them. The geometry sections are empty."""
    planes = []
    plane_index = {}
    nodes = [(0, 0, 0)]

    def plane(axis, v):
        if (axis, v) not in plane_index:
            plane_index[(axis, v)] = len(planes)
            planes.append((axis, v))
        return plane_index[(axis, v)]

    def build(rmin, rmax, items):
        # items: (area, mins, maxs) inside the region rmin..rmax
        if not items:
            return 0
        if len(items) == 1 and items[0][1] == rmin and items[0][2] == rmax:
            return -items[0][0]
        for area, mn, mx in items:
            for axis in range(3):
                for v in (mn[axis], mx[axis]):
                    if rmin[axis] < v < rmax[axis]:
                        index = len(nodes)
                        nodes.append(None)
                        front, back = [], []
                        for a2, mn2, mx2 in items:
                            if mx2[axis] > v:
                                lo = list(mn2)
                                lo[axis] = max(lo[axis], v)
                                front.append((a2, tuple(lo), mx2))
                            if mn2[axis] < v:
                                hi = list(mx2)
                                hi[axis] = min(hi[axis], v)
                                back.append((a2, mn2, tuple(hi)))
                        fmin = list(rmin)
                        fmin[axis] = v
                        bmax = list(rmax)
                        bmax[axis] = v
                        f = build(tuple(fmin), rmax, front)
                        b = build(rmin, tuple(bmax), back)
                        # children[0]: in front (a point's distance >= 0)
                        nodes[index] = (plane(axis, v), f, b)
                        return index
        raise ValueError('cannot split the AAS boxes')

    root = build((-4096, -4096, -4096), (4096, 4096, 4096),
                 [(a, tuple(map(float, mn)), tuple(map(float, mx))) for a, mn, mx in AAS_AREAS])
    assert root == 1

    def num(v):
        return ('%g' % v)

    out = ['DewmAAS "1.07"', '', '1234567890', '', 'settings', '{', '	bboxes', '	{',
           '		(-24 -24 0)-(24 24 82)', '	}', '	fileExtension = "aas48"', '}']
    out.append('planes %d {' % len(planes))
    for i, (axis, v) in enumerate(planes):
        n = [0, 0, 0]
        n[axis] = 1
        out.append('	%d ( %d %d %d %s )' % (i, n[0], n[1], n[2], num(v)))
    out.append('}')
    for section in ('vertices', 'edges', 'edgeIndex', 'faces', 'faceIndex'):
        out.append('%s 0 {' % section)
        out.append('}')
    out.append('areas %d {' % (len(AAS_AREAS) + 1))
    out.append('	0 ( 0 0 0 0 0 0 ) 0 {')
    out.append('	}')
    for area, mn, mx in AAS_AREAS:
        reach = [r for r in AAS_REACH if r[0] == area]
        out.append('	%d ( 193 0 0 0 1 %d ) %d {' % (area, area, len(reach)))
        for _, ttype, to, start, end, ttime in reach:
            out.append('		%d %d (%s) (%s) 0 %d' % (ttype, to, ' '.join(num(c) for c in start),
                                                   ' '.join(num(c) for c in end), ttime))
        out.append('	}')
    out.append('}')
    out.append('nodes %d {' % len(nodes))
    for i, (pl, f, b) in enumerate(nodes):
        out.append('	%d ( %d %d %d )' % (i, pl, f, b))
    out.append('}')
    for section in ('portals', 'portalIndex', 'clusters'):
        out.append('%s 0 {' % section)
        out.append('}')
    return '\n'.join(out) + '\n'


def map_text():
    ents = [
        {'classname': 'worldspawn'},
        {'classname': 'info_player_start', 'name': 'info_player_start_1',
         'origin': '-160 -160 0', 'angle': '45'},
        # Room A lights
        {'classname': 'light', 'name': 'light_1', 'origin': '0 0 160',
         'light_radius': '320 320 200', '_color': '0.85 0.88 1'},
        {'classname': 'light', 'name': 'light_2', 'origin': '-200 200 64',
         'light_radius': '200 200 160', '_color': '1 0.35 0.15',
         'texture': 'lights/test_flicker'},
        {'classname': 'light', 'name': 'light_ambient', 'origin': '0 0 96',
         'light_radius': '700 700 400', '_color': '0.12 0.12 0.14',
         'texture': 'lights/test_ambient'},
        # Room B lights
        {'classname': 'light', 'name': 'light_3', 'origin': '448 -192 240',
         'light_radius': '360 360 300', '_color': '0.4 0.6 1'},
        {'classname': 'light', 'name': 'light_4', 'origin': '448 192 240',
         'light_radius': '360 360 300', '_color': '1 0.75 0.5',
         'texture': 'lights/test_pulse'},
        {'classname': 'light', 'name': 'light_5', 'origin': '820 0 200',
         'light_radius': '200 260 180', '_color': '0.25 0.8 0.35',
         'texture': 'lights/test_strobe'},
        {'classname': 'light', 'name': 'light_spot', 'origin': '880 -300 260',
         'light_target': '-200 220 -260', 'light_up': '0 0 120', 'light_right': '120 0 0',
         '_color': '1 1 0.8'},
        # a projected pattern on the floor of room A
        {'classname': 'light', 'name': 'light_window', 'origin': '0 -150 190',
         'light_target': '0 0 -190', 'light_up': '0 90 0', 'light_right': '90 0 0',
         'light_end': '0 0 -240', 'light_start': '0 0 -10',
         '_color': '0.9 0.85 0.6', 'texture': 'lights/test_window'},
        {'classname': 'light', 'name': 'light_ambient_b', 'origin': '590 0 140',
         'light_radius': '900 900 500', '_color': '0.1 0.1 0.12',
         'texture': 'lights/test_ambient'},
        # brush entities
        {'classname': 'func_door', 'name': 'door_1', 'model': 'door_1',
         'origin': '264 0 56', 'movedir': '-1', 'speed': '160', 'lip': '8', 'wait': '3',
         'snd_open': 'test_door', 'snd_close': 'test_door', 'team': 'tunnel'},
        {'classname': 'func_door', 'name': 'door_2', 'model': 'door_2',
         'origin': '300 0 124', 'angle': '90', 'movedir': '0', 'speed': '160',
         'lip': '8', 'team': 'tunnel'},
        {'classname': 'func_static', 'name': 'door_light_1', 'model': 'door_light_1',
         'origin': '259 0 80', 'bind': 'door_1'},
        {'classname': 'func_static', 'name': 'crate_1', 'model': 'crate_1',
         'origin': '128 -160 32', 'angle': '20'},
        {'classname': 'func_static', 'name': 'crawl_bar_1', 'model': 'crawl_bar_1',
         'origin': '120 80 58'},
        {'classname': 'func_static', 'name': 'crate_2', 'model': 'crate_2',
         'origin': '136 -150 88', 'angle': '-15', 'shaderParm7': '1', '_color': '1 0.6 0.2'},
        {'classname': 'func_static', 'name': 'panel_1', 'model': 'panel_1',
         'origin': '-252 -60 100', 'gui': 'guis/test_panel.gui',
         'gui_parm1': 'AREA A', 'gui_parm2': 'Welcome to the Castle Doom 3 test level.\\nRoom B is through the door. Mind the creatures.',
         'target': 'light_panel_1'},
        # switched by the panel's GUI (its button's "activate" command)
        {'classname': 'light', 'name': 'light_panel_1', 'origin': '-200 -60 150',
         'light_radius': '120 120 120', '_color': '0.3 0.6 1', 'start_off': '1'},
        {'classname': 'func_rotating', 'name': 'spinner_1', 'model': 'spinner_1',
         'origin': '590 0 220', 'speed': '45'},
        # static models
        {'classname': 'func_static', 'name': 'barrel_1',
         'model': 'models/mapobjects/test/barrel.lwo', 'origin': '-60 190 0'},
        {'classname': 'func_static', 'name': 'barrel_2',
         'model': 'models/mapobjects/test/barrel.lwo', 'origin': '-12 206 0', 'angle': '40'},
        {'classname': 'func_static', 'name': 'terminal_1',
         'model': 'models/mapobjects/test/terminal.ase', 'origin': '820 -280 96', 'angle': '135'},
        {'classname': 'func_static', 'name': 'terminal_2', 'noclipmodel': '1',
         'model': 'models/mapobjects/test/terminal.ase', 'origin': '200 200 0', 'angle': '-135'},
        # a creature
        {'classname': 'monster_test_blob', 'name': 'blob_1', 'origin': '600 -40 0',
         'angle': '180'},
        {'classname': 'monster_test_blob', 'name': 'blob_2', 'origin': '820 160 96',
         'angle': '200', 'anim': 'walk'},
        # sounds
        {'classname': 'speaker', 'name': 'speaker_1', 'origin': '590 0 200',
         's_shader': 'test_hum', 's_looping': '1'},
        # entity activation: walking into room B fires trigger_once_1, which
        # fires trigger_relay_1, which switches light_trig on 0.5 s later
        {'classname': 'trigger_once', 'name': 'trigger_once_1', 'model': 'trigger_once_1',
         'origin': '330 0 56', 'target': 'trigger_relay_1', 'call': 'test_trigger_called'},
        # a cinematic: fade out, a camera anim (test_cam_1), fade in, then the
        # player is teleported to info_player_teleport_1
        {'classname': 'trigger_once', 'name': 'trigger_once_cin', 'model': 'trigger_once_cin',
         'origin': '340 -340 56', 'target': 'trigger_fade_out', 'target1': 'trigger_relay_cin'},
        # a hurting volume (trigger_hurt: damage_test_hurt every 0.5 s to
        # whoever stands in it, the player or monsters)
        {'classname': 'trigger_hurt', 'name': 'trigger_hurt_1', 'model': 'trigger_hurt_1',
         'origin': '640 -260 56', 'def_damage': 'damage_test_hurt', 'delay': '0.5'},
        {'classname': 'trigger_fade', 'name': 'trigger_fade_out', 'origin': '340 -340 150',
         'fadeColor': '0 0 0 1', 'fadeTime': '0.3'},
        {'classname': 'trigger_relay', 'name': 'trigger_relay_cin', 'origin': '360 -340 150',
         'delay': '0.3', 'target': 'trigger_fade_in', 'target1': 'test_cam_1',
         'target2': 'animated_blob_1'},
        # an idAnimated model of the cinematic: appears, walks twice, then
        # switches light_5 (its target) and is removed
        {'classname': 'test_animated_blob', 'name': 'animated_blob_1', 'origin': '650 150 0',
         'angle': '90', 'hide': '1', 'target': 'light_5'},
        {'classname': 'trigger_fade', 'name': 'trigger_fade_in', 'origin': '380 -340 150',
         'fadeColor': '0 0 0 0', 'fadeTime': '0.5'},
        {'classname': 'test_cinematic_cam', 'name': 'test_cam_1', 'origin': '600 0 100',
         'anim': 'flyby', 'target': 'info_player_teleport_1'},
        {'classname': 'info_player_teleport', 'name': 'info_player_teleport_1',
         'origin': '500 200 0', 'angle': '180'},
        # locations (they spread through portals, not through the closed door)
        {'classname': 'info_location', 'name': 'info_location_1',
         'origin': '-100 -100 64', 'location': 'Room_A'},
        {'classname': 'info_location', 'name': 'info_location_2',
         'origin': '448 0 64', 'location': 'room_b'},
        # a monster running its AI script, on the balcony
        {'classname': 'monster_test_scripted', 'name': 'blob_scripted_1', 'origin': '840 300 96',
         'angle': '180'},
        # a character (AI script): walks to path_corner_1 when triggered
        {'classname': 'char_test_walker', 'name': 'test_walker_1', 'origin': '-200 60 0',
         'angle': '0', 'target': 'path_corner_1'},
        {'classname': 'path_corner', 'name': 'path_corner_1', 'origin': '-80 60 0'},
        # moved by maps/testmap.script
        {'classname': 'func_mover', 'name': 'lift_1', 'model': 'lift_1', 'origin': '380 300 4'},
        {'classname': 'func_mover', 'name': 'bar_1', 'model': 'bar_1', 'origin': '600 -300 150'},
        # a curve for bar_1 (func_splinemover: the points of a NURBS curve)
        {'classname': 'func_splinemover', 'name': 'spline_1', 'origin': '600 -300 150',
         'curve_Nurbs': '4 ( 600 -300 150 650 -250 150 700 -300 150 750 -250 150 )'},
        {'classname': 'trigger_relay', 'name': 'trigger_relay_1', 'origin': '330 0 150',
         'target': 'light_trig', 'target1': 'emitter_ring_1', 'delay': '0.5'},
        # particles: a steam vent in room A (always on), a glowing ring in
        # room B switched on by trigger_relay_1, an FX (activate fx_test_1)
        {'classname': 'func_emitter', 'name': 'emitter_steam_1', 'origin': '-180 -20 4',
         'model': 'test_steam.prt'},
        {'classname': 'func_emitter', 'name': 'emitter_ring_1', 'origin': '560 -300 2',
         'model': 'test_ring.prt', 'start_off': '1'},
        {'classname': 'func_fx', 'name': 'fx_test_1', 'origin': '400 -60 40',
         'fx': 'fx/test_blast'},
        {'classname': 'light', 'name': 'light_trig', 'origin': '840 300 180',
         'light_radius': '180 180 160', '_color': '1 0.2 0.2', 'start_off': '1'},
        # waits until activated, then throws homing balls (create_missile /
        # launch_missile frame commands and the attackMissile event)
        {'classname': 'monster_test_ranged', 'name': 'blob_ranged_1', 'origin': '500 -150 0',
         'angle': '90'},
        # flies once activated (MOVETYPE_FLY): up to the player's eyes,
        # chasing, charging like a lost soul
        {'classname': 'monster_test_flyer', 'name': 'blob_flyer_1', 'origin': '620 -100 0',
         'angle': '180'},
        # goes to its combat node once activated (the player in the node's
        # cone), marks it used, then dodges (evade_left) every second
        {'classname': 'monster_test_dodger', 'name': 'blob_dodger_1', 'origin': '420 200 0',
         'angle': '-90', 'target': 'combat_node_1'},
        {'classname': 'ai_attackcone', 'name': 'combat_node_1', 'origin': '600 200 0',
         'angle': '180', 'max': '600', 'fov': '150', 'use_once': '1'},
        # a moveable barrel, and a monster that throws it at the player once
        # activated (the vagary's chooseObjectToThrow / throwObjectAtEnemy)
        {'classname': 'moveable_test_barrel', 'name': 'moveable_barrel_1', 'origin': '470 40 0'},
        {'classname': 'monster_test_thrower', 'name': 'blob_thrower_1', 'origin': '420 80 0',
         'angle': '-90'},
        # a character that sidesteps with its evade_left anim when activated
        # (characters move by their animations, like their path anims)
        {'classname': 'char_test_stepper', 'name': 'test_stepper_1', 'origin': '60 -100 0',
         'angle': '0'},
        # items along room A's south wall, picked up by touching (idItem):
        # health (the player has full health: left), armor, ammo, a weapon
        # (spinning), a key (carried, fires its target), and armor that can
        # only be picked up once triggered (triggerFirst)
        {'classname': 'item_test_medkit', 'name': 'item_medkit_1', 'origin': '-40 -210 0'},
        {'classname': 'item_test_armor', 'name': 'item_armor_1', 'origin': '0 -210 0'},
        {'classname': 'item_test_clip', 'name': 'item_clip_1', 'origin': '40 -210 0'},
        {'classname': 'weapon_test_shotgun', 'name': 'weapon_shotgun_1', 'origin': '-80 -210 0',
         'spin': '1'},
        {'classname': 'item_test_keycard', 'name': 'item_keycard_1', 'origin': '-140 -210 0',
         'target': 'trigger_relay_key'},
        {'classname': 'trigger_relay', 'name': 'trigger_relay_key', 'origin': '-140 -210 100',
         'target': 'item_armor_2'},
        {'classname': 'item_test_armor', 'name': 'item_armor_2', 'origin': '80 -210 0',
         'triggerFirst': '1'},
        # powerups (idItemPowerup) in room A's north-west corner
        {'classname': 'item_test_berserk', 'name': 'item_berserk_1', 'origin': '-220 120 0', 'spin': '1'},
        {'classname': 'item_test_invisibility', 'name': 'item_invisibility_1', 'origin': '-220 200 0',
         'spin': '1'},
    ]
    out = ['Version 2']
    for i, e in enumerate(ents):
        out.append('// entity %d' % i)
        out.append('{')
        for k, v in e.items():
            out.append('"%s" "%s"' % (k, v))
        out.append('}')
    return '\n'.join(out) + '\n'


MATERIALS = r'''
// Castle Doom 3 test materials (generated by tools/make_test_pk4.py)

table testStrobeTable { { 1, 1, 0.2, 1, 1, 1, 0.1, 1 } }
table sinTable { { 0, 0.7071, 1, 0.7071, 0, -0.7071, -1, -0.7071 } }
table testFlickerTable { snap { 1, 0.9, 1, 0.3, 1, 1, 0.8, 0.1, 1, 0.95 } }

textures/test/floor
{
	qer_editorimage textures/test/floor_d.tga
	metal
	diffusemap	textures/test/floor_d.tga
	bumpmap		heightmap(textures/test/floor_bmp.tga, 6)
	specularmap	textures/test/floor_s.tga
}

textures/test/wall
{
	qer_editorimage textures/test/wall_d.tga
	diffusemap	textures/test/wall_d.tga
	bumpmap		addnormals(textures/test/wall_local.tga, heightmap(textures/test/wall_bmp.tga, 2))
	specularmap	textures/test/wall_s.tga
}

textures/test/metal
{
	qer_editorimage textures/test/metal_d.tga
	{
		blend diffusemap
		map textures/test/metal_d.tga
	}
	{
		blend bumpmap
		map textures/test/metal_local.tga
	}
	{
		blend specularmap
		map textures/test/metal_s.tga
	}
}

/* a lit surface with a glowing second stage (drawn as an overlay) */
textures/test/door
{
	qer_editorimage textures/test/metal_d.tga
	diffusemap	textures/test/metal_d.tga
	bumpmap		textures/test/metal_local.tga
	specularmap	textures/test/metal_s.tga
	{
		blend add
		map textures/test/doorlights.tga
		rgb 0.6 + 0.4 * sinTable[ time ]
	}
}

/* only a reflection stage: drawn as the reflection (glass) */
textures/test/glass
{
	qer_editorimage textures/test/metal_d.tga
	noshadows
	nonsolid
	translucent
	twosided
	{
		blend add
		cubeMap env/testenv
		texgen reflect
		rgb 0.3
	}
}

/* glass distorting what is behind it (Doom 3's heatHaze program) */
textures/test/hazeglass
{
	qer_editorimage textures/test/haze_local.tga
	noshadows
	nonsolid
	translucent
	twosided
	{
		program heatHaze.vfp
		vertexParm 0 time * 0.1 , time * 0.05
		vertexParm 1 1.5
		fragmentMap 0 _currentRender
		fragmentMap 1 textures/test/haze_local.tga
	}
}

/* lit metal reflecting a cube map */
textures/test/shinymetal
{
	qer_editorimage textures/test/metal_d.tga
	diffusemap	textures/test/metal_d.tga
	bumpmap		textures/test/metal_local.tga
	specularmap	textures/test/metal_s.tga
	{
		blend add
		cubeMap env/testenv
		texgen reflect
		rgb 0.2
	}
}

/* a camera facing glow */
textures/test/flare
{
	qer_editorimage textures/test/flare.tga
	deform sprite
	noshadows
	nonsolid
	translucent
	{
		blend add
		map textures/test/flare.tga
	}
}

/* a decal: a bullet hole, stuck on surfaces with polygonOffset, fading
   after 3 s over 1 s (decalInfo) */
textures/test/decal_hole
{
	qer_editorimage textures/test/decal_hole.tga
	noshadows
	nonsolid
	translucent
	polygonOffset
	decalInfo 3 1 ( 1 1 1 1 ) ( 0 0 0 0 )
	{
		blend blend
		map textures/test/decal_hole.tga
	}
}

/* a lit surface whose texture coordinates ripple (deform turbulent) */
textures/test/pool
{
	qer_editorimage textures/test/metal_d.tga
	deform turbulent sinTable 0.04 time * 0.2 0.02
	diffusemap	textures/test/metal_d.tga
	bumpmap		textures/test/metal_local.tga
	specularmap	textures/test/metal_s.tga
}

/* a lit surface with a heat haze stage over it */
textures/test/hazewall
{
	qer_editorimage textures/test/metal_d.tga
	noshadows
	nonsolid
	diffusemap	textures/test/metal_d.tga
	bumpmap		textures/test/metal_local.tga
	{
		program heatHaze.vfp
		vertexParm 0 time * 0.1 , time * 0.05
		vertexParm 1 1.5
		fragmentMap 0 _currentRender
		fragmentMap 1 textures/test/haze_local.tga
	}
}

/* a flare of a fixed size (deform flare) */
textures/test/flare2
{
	qer_editorimage textures/test/flare.tga
	deform flare 24
	noshadows
	nonsolid
	translucent
	{
		blend add
		map textures/test/flare.tga
	}
}

/* a lit crate with a glow stage drawn only when the entity's
   shaderParm7 is set, tinted by its _color (vertexColor is a no-op
   without vertex colors) */
textures/test/crateglow
{
	qer_editorimage textures/test/metal_d.tga
	diffusemap	textures/test/metal_d.tga
	bumpmap		textures/test/metal_local.tga
	specularmap	textures/test/metal_s.tga
	{
		if ( parm7 > 0 )
		blend add
		map textures/test/doorlights.tga
		vertexColor
		rgb 0.5 + 0.5 * sinTable[ time ]
		red parm0 * 0.5 + 0.5 * sinTable[ time ]
	}
}

/* no specular map: uses the default */
textures/test/ceiling
{
	diffusemap	textures/test/ceiling_d.tga
	bumpmap		_flat
}

textures/test/lightpanel
{
	qer_editorimage textures/test/lightpanel.tga
	noshadows
	{
		blend add
		map textures/test/lightpanel.tga
		rgb 0.75 + 0.25 * sinTable[ time * 0.5 ]	// a slow pulse
	}
}

textures/test/screen
{
	qer_editorimage textures/test/screen.tga
	noshadows
	{
		blend add
		map textures/test/screen.tga
		scroll 0, time * -0.25
		scale 2, 2
	}
}

textures/test/sky
{
	qer_editorimage textures/test/metal_d.tga
	noshadows
	nonsolid
	{
		cameraCubeMap env/testsky
		texgen skybox
		texgen wobblesky .0 .0 .0
	}
}

// particle materials (particles/test.prt): the smoke blends with its
// vertex colors (the particles' fades), the spark and the flash add
textures/particles/test_smoke
{
	noshadows
	translucent
	{
		blend blend
		map textures/particles/test_smoke.tga
		vertexColor
	}
}

textures/particles/test_spark
{
	noshadows
	translucent
	{
		blend add
		map textures/particles/test_spark.tga
		vertexColor
	}
}

textures/particles/test_flash
{
	noshadows
	translucent
	{
		blend add
		map textures/particles/test_flash.tga
		vertexColor
	}
}

// a damage blob on the screen (the test damage defs' mtr_blob)
textures/test/blood_blob
{
	translucent
	{
		blend blend
		map textures/test/blood_blob.tga
	}
}

// the weapons' muzzle flash: shows for 1/12 s after a shot (parm4 is minus
// the time of the shot, like Doom 3's SHADERPARM_TIMEOFFSET)
models/weapons/test/muzzleflash
{
	noshadows
	twosided
	translucent
	{
		if ( ( time + parm4 ) * 12 ) < 1.0
		blend add
		map models/weapons/test/muzzleflash.tga
	}
}

models/mapobjects/test/barrel
{
	diffusemap	models/mapobjects/test/barrel_d.tga
	bumpmap		heightmap(models/mapobjects/test/barrel_d.tga, 3)
	specularmap	models/mapobjects/test/barrel_s.tga
}

models/test/blob
{
	diffusemap	models/test/blob_d.tga
	bumpmap		heightmap(models/test/blob_bmp.tga, 4)
	specularmap	makeIntensity(models/test/blob_d.tga)
}

/* the test guns' casings (debris_test_brass) */
models/weapons/test/brass
{
	noshadows
	diffusemap	models/weapons/test/brass_d.tga
	specularmap	models/weapons/test/brass_d.tga
}

/* the player's body without a skin (player_test's skins replace it) */
models/test/player
{
	diffusemap	textures/test/metal_d.tga
}

/* skins/test/player: green armor */
models/test/player_armor
{
	diffusemap	models/test/player_d.tga
	bumpmap		heightmap(models/test/blob_bmp.tga, 3)
	specularmap	makeIntensity(models/test/player_d.tga)
}

/* skins/test/player_berserk: red armor */
models/test/player_berserk
{
	diffusemap	models/test/player_berserk_d.tga
	bumpmap		heightmap(models/test/blob_bmp.tga, 3)
	specularmap	makeIntensity(models/test/player_berserk_d.tga)
}

/* skins/test/player_invis: a faint glow added over what is behind */
models/test/player_invis
{
	noshadows
	translucent
	{
		blend add
		map models/test/player_invis.tga
	}
}

textures/common/trigonce
{
	qer_editorimage textures/test/metal_d.tga
	noshadows
	trigger
}

textures/common/clip
{
	qer_editorimage textures/test/metal_d.tga
	noshadows
	playerclip
}

textures/common/monster_clip
{
	qer_editorimage textures/test/metal_d.tga
	noshadows
	monsterclip
}

// like Doom 3's lights.mtr defaults, used by lights without a "texture"
lights/defaultPointLight
{
	lightFalloffImage	makeintensity( lights/squarelight1a.tga )
	{
		map lights/squarelight1.tga
		colored
		zeroClamp
	}
}

lights/defaultProjectedLight
{
	lightFalloffImage	lights/projfalloff.tga
	{
		map lights/round.tga
		colored
		zeroClamp
	}
}

lights/test_window
{
	lightFalloffImage	lights/projfalloff.tga
	{
		map lights/window.tga
		colored
		zeroClamp
	}
}

textures/test/guiscreen
{
	qer_editorimage textures/test/screen.tga
	guisurf entity
	discrete
	playerclip
}

textures/test/statusscreen
{
	qer_editorimage textures/test/screen.tga
	guisurf guis/test_status.gui
	discrete
}

lights/test_ambient
{
	ambientLight
	lightFalloffImage	makeintensity( lights/squarelight1a.tga )
	{
		map lights/squarelight1.tga
		colored
		zeroClamp
	}
}

lights/test_pulse
{
	{
		map lights/round.tga
		red		( 0.7 + 0.3 * sinTable[ time * 0.5 ] ) * Parm0
		green	( 0.7 + 0.3 * sinTable[ time * 0.5 ] ) * Parm1
		blue	( 0.7 + 0.3 * sinTable[ time * 0.5 ] ) * Parm2	// a comment after an expression
		zeroClamp
	}
}

lights/test_flicker
{
	{
		map lights/round.tga
		colored
		red		testFlickerTable[ time * 4 ] * parm0
		green	testFlickerTable[time*4]*parm1
		blue	testFlickerTable[ time * 4 ] * parm2
	}
}

lights/test_white
{
	{
		map lights/round.tga
	}
}

lights/test_strobe
{
	{
		map lights/round.tga
		red 	testStrobeTable[ time * 2 ] * parm0
		green 	testStrobeTable[ time * 2 ] * parm1
		blue 	testStrobeTable[ time * 2 ] * parm2
		zeroClamp
	}
}
'''

# the player's skins: the def's "skin", "skin" + "_berserk" under berserk
# (idPlayer's powerUpSkin), "skin_invisibility"
SKINS = r'''
// Castle Doom 3 test skins (generated by tools/make_test_pk4.py)

skin skins/test/player {
	models/test/player		models/test/player_armor
}

skin skins/test/player_berserk {
	models/test/player		models/test/player_berserk
}

skin skins/test/player_invis {
	models/test/player		models/test/player_invis
}
'''

DEFS = r'''
// Castle Doom 3 test entity definitions (generated by tools/make_test_pk4.py)

model test_blob {
	mesh					models/md5/test/blob.md5mesh
	channel torso			( *body )
	anim idle				models/md5/test/blob_idle.md5anim
	anim walk				models/md5/test/blob_walk.md5anim {
		frame 6				sound_body snd_footstep
	}
	anim melee				models/md5/test/blob_walk.md5anim {
		frame 4				melee damage_test_melee
	}
	anim range				models/md5/test/blob_walk.md5anim {
		frame 3				launch_missile body
	}
	anim evade_left			models/md5/test/blob_evade.md5anim
	anim pain				models/md5/test/blob_pain.md5anim
	anim throw				models/md5/test/blob_walk.md5anim {
		frame 1				create_missile body
		frame 6				launch_missile body
	}
}

// the weapons' view models (models/md5/weapons/test_*): at the player's eye,
// x forward, y left
model viewmodel_test_pistol {
	mesh					models/md5/weapons/test_pistol/viewpistol.md5mesh
	anim idle				models/md5/weapons/test_pistol/idle.md5anim
	anim fire				models/md5/weapons/test_pistol/fire.md5anim {
		frame 1				sound_weapon snd_fire
	}
	anim raise				models/md5/weapons/test_pistol/raise.md5anim
	anim putaway			models/md5/weapons/test_pistol/putaway.md5anim
	anim reload				models/md5/weapons/test_pistol/reload.md5anim
}

model viewmodel_test_shotgun {
	inherit					viewmodel_test_pistol
	mesh					models/md5/weapons/test_shotgun/viewshotgun.md5mesh
}

model viewmodel_test_fists {
	mesh					models/md5/weapons/test_fists/viewfists.md5mesh
	anim idle				models/md5/weapons/test_pistol/idle.md5anim
	anim fire				models/md5/weapons/test_fists/punch.md5anim
	anim raise				models/md5/weapons/test_pistol/raise.md5anim
	anim putaway			models/md5/weapons/test_pistol/putaway.md5anim
}

entityDef monster_default {
	"editor_color"			"1 .5 0"
	"spawnclass"			"idAI"
	"health"				"50"
	"size"					"32 32 72"
}

// game classes: spawnclass is what the game code looks at
entityDef test_cinematic_cam {
	"editor_usage"			"Plays a camera anim (.md5camera) when triggered, then fires its targets."
	"spawnclass"			"idCameraAnim"
	"anim flyby"			"models/md5/cameras/test_flyby.camera"
}

entityDef trigger_fade {
	"editor_usage"			"Fades the screen to fadeColor over fadeTime seconds."
	"spawnclass"			"idTrigger_Fade"
	"fadeColor"				"0 0 0 1"
	"fadeTime"				"1"
}

entityDef info_location {
	"editor_usage"			"Names the areas it spreads to (the HUD location, the reverb)."
	"spawnclass"			"idLocationEntity"
}

entityDef info_player_teleport {
	"editor_usage"			"Moves the player here when triggered."
	"spawnclass"			"idPlayerStart"
}

model test_blob_head {
	mesh					models/md5/test/blob.md5mesh
	anim idle				models/md5/test/blob_idle.md5anim
	anim talk_primary		models/md5/test/blob_walk.md5anim {
		frame 1				sound_voice snd_talk_primary
	}
}

entityDef test_animated_blob {
	"editor_usage"			"Plays its anim (walk, twice) when triggered, fires its targets and goes."
	"spawnclass"			"idAnimated"
	"model"					"test_blob"
	"anim"					"walk"
	"cycle"					"2"
	"remove"				"1"
	"def_head"				"test_blob_head"
	"head_joint"			"head"
}

entityDef char_test_walker {
	"editor_usage"			"A character walking to its path_corner when triggered (script object character)."
	"spawnclass"			"idAI"
	"scriptobject"			"character"
	"model"					"test_blob"
	"turn_rate"				"180"
	"def_head"				"test_blob_head"
	"head_joint"			"head"
	"snd_talk_primary"		"test_door"
	"look_joint head"		"1 1 0"
	"look_min"				"-45 -90 0"
	"look_max"				"30 90 0"
}

entityDef char_test_stepper {
	"inherit"				"char_test_walker"
	"editor_usage"			"A character moving by its animation when activated (script object character_stepper)."
	"scriptobject"			"character_stepper"
}

entityDef damage_test_melee {
	"damage"				"7"
	"kick_time"				"400"
	"kick_amplitude"		"1"
	"blob_time"				"500"
	"mtr_blob"				"textures/test/blood_blob"
	"blob_x"				"220"
	"blob_y"				"140"
	"blob_width"			"200"
	"blob_height"			"200"
}

entityDef damage_test_projectile {
	"damage"				"5"
	"kick_time"				"400"
	"kick_amplitude"		"1"
	"blob_time"				"500"
	"mtr_blob"				"textures/test/blood_blob"
	"blob_x"				"220"
	"blob_y"				"140"
	"blob_width"			"200"
	"blob_height"			"200"
	"dv_time"				"500"
	"knockback"				"40"
}

// a gibbing hit (like the chainsaw's): the victim goes to pieces
entityDef damage_test_gib {
	"damage"				"200"
	"gib"					"1"
	"kick_time"				"400"
	"kick_amplitude"		"1"
	"knockback"				"60"
}

// trigger_hurt_1's damage: a burn every half second
entityDef damage_test_hurt {
	"damage"				"5"
	"kick_time"				"300"
	"kick_amplitude"		"1"
	"blob_time"				"300"
	"mtr_blob"				"textures/test/blood_blob"
	"blob_x"				"220"
	"blob_y"				"140"
	"blob_width"			"200"
	"blob_height"			"200"
	"dv_time"				"200"
}

// a gib (def_dropGibItem of the blob and the player): a chunk flying
// off, gone in 4 seconds
entityDef item_test_gib {
	"spawnclass"			"idMoveableItem"
	"model"					"models/items/test/gib.lwo"
	"bouncyness"			"0.3"
	"fuse"					"4"
}

entityDef damage_test_splash {
	"damage"				"6"
	"radius"				"80"
}

entityDef projectile_test {
	"editor_usage"			"A glowing ball thrown by blob_scripted_1."
	"spawnclass"			"idProjectile"
	"mins"					"-3 -3 -3"
	"maxs"					"3 3 3"
	"velocity"				"500 0 0"
	"gravity"				"0"
	"fuse"					"4"
	"def_damage"			"damage_test_projectile"
	"def_splash_damage"		"damage_test_splash"
	"detonate_on_world"		"1"
	"detonate_on_actor"		"1"
	"light_color"			"0.2 0.8 1"
	"light_radius"			"100"
	// particles: the trail it leaves, the explosion
	"smoke_fly"				"test_trail.prt"
	"model_detonate"		"test_explosion.prt"
}

entityDef projectile_test_guided {
	"editor_usage"			"A homing ball (like the revenant's rockets) thrown by blob_ranged_1."
	"spawnclass"			"idGuidedProjectile"
	"mins"					"-3 -3 -3"
	"maxs"					"3 3 3"
	"velocity"				"300 0 0"
	"gravity"				"0"
	"fuse"					"5"
	"turn_max"				"240"
	"clamp_dist"			"256"
	"random"				"0 0 0"
	"def_damage"			"damage_test_projectile"
	"detonate_on_world"		"1"
	"detonate_on_actor"		"1"
	"light_color"			"1 0.5 0.1"
	"light_radius"			"100"
}

entityDef projectile_test_grenade {
	"editor_usage"			"A bouncing grenade that explodes when its fuse ends (unit tests)."
	"spawnclass"			"idProjectile"
	"mins"					"-2 -2 -2"
	"maxs"					"2 2 2"
	"velocity"				"400 0 0"
	"gravity"				"800"
	"bounce"				"0.5"
	"fuse"					"1.5"
	"detonate_on_fuse"		"1"
	"detonate_on_world"		"0"
	"detonate_on_actor"		"0"
	"def_splash_damage"		"damage_test_splash"
}

entityDef damage_test_charge {
	"damage"				"9"
}

entityDef monster_test_scripted {
	"inherit"				"monster_default"
	"editor_usage"			"A test creature running an AI script (script object monster_test)."
	"model"					"test_blob"
	"ragdoll"				"test_blob"
	"scriptobject"			"monster_test"
	"def_projectile"		"projectile_test"
	"attack_accuracy"		"0"
	"health"				"40"
	"melee_range"			"40"
	"turn_rate"				"360"
}

entityDef monster_test_ranged {
	"inherit"				"monster_test_scripted"
	"editor_usage"			"A test creature throwing homing balls once activated (script object monster_test_ranged)."
	"scriptobject"			"monster_test_ranged"
	"def_projectile"		"projectile_test_guided"
	"attack_accuracy"		"0"
	"attack_cone"			"70"
}

entityDef monster_test_flyer {
	"inherit"				"monster_test_scripted"
	"editor_usage"			"A flying test creature charging at the player once activated (script object monster_test_flyer)."
	"scriptobject"			"monster_test_flyer"
	"fly_speed"				"150"
	"fly_offset"			"10"
	"melee_range"			"40"
}

entityDef monster_test_dodger {
	"inherit"				"monster_test_scripted"
	"editor_usage"			"A test creature going to its combat node, then dodging (script object monster_test_dodger)."
	"scriptobject"			"monster_test_dodger"
}

entityDef ai_attackcone {
	"editor_usage"			"A combat node: monsters targeting it attack from here when their enemy is in its cone."
	"spawnclass"			"idCombatNode"
	"min"					"0"
	"max"					"256"
	"fov"					"60"
	"height"				"256"
	"use_once"				"0"
}

entityDef moveable_test_barrel {
	"editor_usage"			"A barrel that falls, bounces and can be thrown (idMoveable)."
	"spawnclass"			"idMoveable"
	"model"					"models/mapobjects/test/barrel.lwo"
	"bouncyness"			"0.4"
	"def_damage"			"damage_test_moveable"
	"damageWhenActive"		"1"
}

entityDef damage_test_moveable {
	"damage"				"12"
}

// the player's inventory (like player_doommarine: the full game's is used
// when there is one): weapon slots, the weapons and ammo to start with,
// the most ammo of each kind
entityDef player_test {
	"smoke_wound_flesh"		"test_blood.prt"
	"gib"					"1"
	"snd_gibbed"			"test_death"
	"def_dropGibItem1"		"item_test_gib"
	"def_dropGibItem2"		"item_test_gib"
	"maxhealth"				"100"
	"armor"					"0"
	"maxarmor"				"100"
	"def_weapon0"			"weapon_test_fists"
	"def_weapon1"			"weapon_test_pistol"
	"def_weapon2"			"weapon_test_shotgun"
	"weapon"				"weapon_test_fists,weapon_test_pistol"
	"ammo_test_bullets"		"24"
	"max_ammo_test_bullets"	"60"
	"max_ammo_test_shells"	"24"
	"pain_delay"			"0.5"
	"snd_pain_small"		"test_pain"
	"snd_pain_medium"		"test_pain"
	"snd_pain_large"		"test_pain_large"
	"snd_pain_huge"			"test_pain_large"
	"snd_death"				"test_death"
	"snd_land_hard"			"test_land"
	"snd_hitArmor"			"test_step"
	"snd_berserk_third"		"test_berserk"
	"snd_invisibility"		"test_invisibility"
	"model"					"model_test_player"
	"skin"					"skins/test/player"
	"skin_invisibility"		"skins/test/player_invis"
	// dead, the body falls as a ragdoll: the articulated figure test_player
	// (af/test_creatures.af)
	"ragdoll"				"test_player"
}

// a spent casing (idDebris), from the test guns' "eject" joints
entityDef debris_test_brass {
	"spawnclass"			"idDebris"
	"model"					"models/weapons/test/brass.lwo"
	"fuse"					"4"
	"bouncyness"			"0.4"
	"snd_bounce"			"test_brass"
}

// the player's body (seen in third person, pm_thirdPerson 1)
model model_test_player {
	mesh					models/md5/test/player.md5mesh
	anim idle				models/md5/test/blob_idle.md5anim
	anim walk				models/md5/test/blob_walk.md5anim
	anim run				models/md5/test/blob_walk.md5anim
	anim crouch				models/md5/test/player_crouch.md5anim
	anim crouch_walk		models/md5/test/player_crouch_walk.md5anim
	anim crouch_down		models/md5/test/player_crouch_down.md5anim
	anim crouch_up			models/md5/test/player_crouch_up.md5anim
	anim death				models/md5/test/player_death.md5anim
}

// the guns in the body's right hand (third person): the weapon defs'
// model_world, bound to their joint_attach (the body's arm_r joint, the
// shoulder; the gun is at the hand, 26 below, pointing forward)
model worldmodel_test_pistol {
	mesh					models/md5/weapons/test_pistol/worldpistol.md5mesh
}

model worldmodel_test_shotgun {
	mesh					models/md5/weapons/test_shotgun/worldshotgun.md5mesh
}

entityDef weapon_test_fists {
	"inv_name"				"Fists"
	"inv_weapon"			"weapon_test_fists"
	"scriptobject"			"weapon_test_fists"
	"model_view"			"viewmodel_test_fists"
	"def_melee"				"damage_test_fists"
	"melee_distance"		"64"
	"ammoType"				""
	"clipSize"				"0"
}

entityDef weapon_test_pistol {
	"spawnclass"			"idItem"
	"model"					"models/items/test/weapon.lwo"
	"inv_name"				"Test Pistol"
	"inv_weapon"			"weapon_test_pistol"
	"inv_ammo_test_bullets"	"12"
	"scriptobject"			"weapon_test_gun"
	"model_view"			"viewmodel_test_pistol"
	"model_world"			"worldmodel_test_pistol"
	"def_ejectBrass"		"debris_test_brass"
	"ejectBrassDelay"		"0"
	"joint_attach"			"arm_r"
	"snd_fire"				"test_shot"
	"flashColor"			"1 0.8 0.4"
	"flashRadius"			"160"
	"flashTime"				"0.12"
	"muzzle_kick_time"		"0.15"
	"muzzle_kick_maxtime"	"0.3"
	"muzzle_kick_angles"	"-6 0 0"
	"muzzle_kick_offset"	"3 0 0"
	"def_projectile"		"projectile_test_bullet"
	"ammoType"				"ammo_test_bullets"
	"ammoRequired"			"1"
	"clipSize"				"12"
	"spread"				"0"
	"test_firerate"			"0.35"
	"test_projectiles"		"1"
	"smoke_muzzle"			"test_muzzle.prt"
}

// the player's bullets: fast projectiles hitting monsters
entityDef projectile_test_bullet {
	"spawnclass"			"idProjectile"
	"velocity"				"7200 0 0"
	"fuse"					"1"
	"def_damage"			"damage_test_bullet"
	"detonate_on_world"		"1"
	"detonate_on_actor"		"1"
	"smoke_detonate"		"test_sparks.prt"
	"mtr_detonate"			"textures/test/decal_hole"
	"decal_size"			"8"
}

entityDef damage_test_bullet {
	"damage"				"14"
}

entityDef projectile_test_pellet {
	"inherit"				"projectile_test_bullet"
	"def_damage"			"damage_test_pellet"
}

entityDef damage_test_pellet {
	"damage"				"5"
}

entityDef damage_test_fists {
	"damage"				"20"
	"snd_flesh"				"test_step"
}

// as in Doom 3, the weapon's def is also its pickup item
entityDef weapon_test_shotgun {
	"spawnclass"			"idItem"
	"model"					"models/items/test/weapon.lwo"
	"snd_acquire"			"test_door"
	"inv_name"				"Test Shotgun"
	"inv_weapon"			"weapon_test_shotgun"
	"inv_ammo_test_shells"	"8"
	"inv_inclip_ammo_test_shells" "4"
	"scriptobject"			"weapon_test_gun"
	"model_view"			"viewmodel_test_shotgun"
	"model_world"			"worldmodel_test_shotgun"
	"def_ejectBrass"		"debris_test_brass"
	"ejectBrassDelay"		"300"
	"joint_attach"			"arm_r"
	"snd_fire"				"test_shotgun"
	"flashColor"			"1 0.7 0.3"
	"flashRadius"			"240"
	"flashTime"				"0.15"
	"muzzle_kick_time"		"0.3"
	"muzzle_kick_maxtime"	"0.4"
	"muzzle_kick_angles"	"-12 0 3"
	"muzzle_kick_offset"	"6 0 1"
	"def_projectile"		"projectile_test_pellet"
	"ammoType"				"ammo_test_shells"
	"ammoRequired"			"1"
	"clipSize"				"8"
	"spread"				"6"
	"test_firerate"			"0.9"
	"test_projectiles"		"8"
}

entityDef item_test_medkit {
	"spawnclass"			"idItem"
	"model"					"models/items/test/box.lwo"
	"inv_name"				"Test Medkit"
	"inv_health"			"25"
}

entityDef item_test_armor {
	"spawnclass"			"idItem"
	"model"					"models/items/test/box.lwo"
	"inv_name"				"Test Armor"
	"inv_armor"				"25"
}

entityDef item_test_clip {
	"spawnclass"			"idItem"
	"model"					"models/items/test/box.lwo"
	"inv_name"				"Test Clip"
	"inv_ammo_test_bullets"	"20"
}

// powerups (Doom 3's are powerup_berserk... : not defined here, the
// retail ones would lose to them)
entityDef item_test_berserk {
	"spawnclass"			"idItemPowerup"
	"model"					"models/items/test/box.lwo"
	"inv_name"				"Test Berserk"
	"type"					"0"
	"time"					"20"
}

entityDef item_test_invisibility {
	"spawnclass"			"idItemPowerup"
	"model"					"models/items/test/box.lwo"
	"inv_name"				"Test Invisibility"
	"type"					"1"
	"time"					"20"
}

entityDef item_test_keycard {
	"spawnclass"			"idItem"
	"model"					"models/items/test/box.lwo"
	"inv_name"				"Test Keycard"
	"inv_carry"				"1"
	"triggersize"			"24"
}

entityDef monster_test_thrower {
	"inherit"				"monster_test_scripted"
	"editor_usage"			"A test creature throwing a moveable at the player once activated, like the vagary (script object monster_test_thrower)."
	"scriptobject"			"monster_test_thrower"
}

entityDef monster_test_blob {
	"inherit"				"monster_default"
	"editor_usage"			"A test creature for Castle Doom 3."
	"model"					"test_blob"
	"ragdoll"				"test_blob"
	"health"				"80"
	"snd_footstep"			"test_step"
	"smoke_wound_flesh"		"test_blood.prt"
	// pain and death: cries by the health left (pain_delay apart), the
	// pain anim; gibbed past -20 health or by a gibbing damage def
	"pain_delay"			"0.3"
	"snd_pain_small"		"test_pain"
	"snd_pain_medium"		"test_pain"
	"snd_pain_large"		"test_pain_large"
	"snd_pain_huge"			"test_pain_large"
	"snd_death"				"test_death"
	"gib"					"1"
	"snd_gibbed"			"test_death"
	"def_dropGibItem1"		"item_test_gib"
	"def_dropGibItem2"		"item_test_gib"
	"def_dropGibItem3"		"item_test_gib"
}
'''

PARTICLES = r'''// Castle Doom 3 test particle systems (generated by tools/make_test_pk4.py)

// a steam vent: a rising cone of puffs, and sparks aimed along their flight
particle test_steam {
	depthHack	0
	{
		count				20
		material			"textures/particles/test_smoke"
		time				1.5
		cycles				0
		bunching			1.0
		distribution		cylinder 4 4 0
		direction			cone 20
		orientation			view
		speed				"50" to "20"
		size				"6" to "16"
		aspect				"1"
		rotation			"30" to "60"
		randomDistribution	1
		fadeIn				0.2
		fadeOut				0.5
		color				0.8 0.85 0.9 0.6
		fadeColor			0 0 0 0
		offset				0 0 2
		gravity				-12
	}
	{
		count				6
		material			"textures/particles/test_spark"
		time				0.6
		cycles				0
		bunching			1.0
		distribution		rect 1 1 1
		direction			cone 35
		orientation			aimed 1 0.1
		speed				"160" to "60"
		size				"1.5"
		fadeIn				0.05
		fadeOut				0.5
		color				1 0.8 0.4 1
		gravity				world 200
	}
}

// the pistol's muzzle smoke (one cycle: a smoke system)
particle test_muzzle {
	{
		count				6
		material			"textures/particles/test_smoke"
		time				0.8
		cycles				1
		bunching			0.5
		distribution		rect 1 1 1
		direction			cone 15
		orientation			view
		speed				"40" to "8"
		size				"2" to "8"
		fadeIn				0.1
		fadeOut				0.5
		color				0.7 0.7 0.7 0.4
		gravity				-8
	}
}

// a projectile's trail (smoke_fly): puffs left behind
particle test_trail {
	{
		count				24
		material			"textures/particles/test_smoke"
		time				0.5
		cycles				0
		bunching			1.0
		distribution		rect 1 1 1
		direction			cone 90
		orientation			view
		speed				"10" to "0"
		size				"3" to "7"
		fadeIn				0.05
		fadeOut				0.6
		color				0.3 0.7 1 0.5
	}
}

// an explosion (model_detonate): an animated flash and sparks flying
// outward, pulled down by gravity, stretched along their flight
particle test_explosion {
	{
		count				1
		material			"textures/particles/test_flash"
		time				0.4
		cycles				1
		bunching			0
		distribution		rect 0 0 0
		direction			cone 0
		orientation			view
		speed				"0"
		size				"16" to "48"
		fadeIn				0
		fadeOut				0.5
		animationFrames		4
		color				1 0.8 0.5 1
	}
	{
		count				16
		material			"textures/particles/test_spark"
		time				0.7
		cycles				1
		bunching			0.2
		distribution		sphere 2 2 2 0.5
		direction			outward 1
		orientation			aimed 2 0.1
		speed				"220" to "60"
		size				"1.5"
		fadeIn				0
		fadeOut				0.4
		color				1 0.8 0.4 1
		gravity				world 300
	}
}

// bullet sparks on walls (smoke_detonate of the player's bullets)
particle test_sparks {
	{
		count				8
		material			"textures/particles/test_spark"
		time				0.4
		cycles				1
		bunching			0.2
		distribution		rect 0 0 0
		direction			cone 50
		orientation			aimed 1 0.05
		speed				"180" to "40"
		size				"1"
		fadeIn				0
		fadeOut				0.5
		color				1 0.9 0.6 1
		gravity				world 300
	}
}

// blood (smoke_wound_flesh): dark red puffs falling from the hit
particle test_blood {
	{
		count				10
		material			"textures/particles/test_smoke"
		time				0.45
		cycles				1
		bunching			0.3
		distribution		rect 1 1 1
		direction			cone 30
		orientation			view
		speed				"70" to "20"
		size				"2" to "5"
		fadeIn				0
		fadeOut				0.5
		color				0.55 0.02 0.02 1
		gravity				world 120
	}
}

// a glowing ring on the floor (orientation z, the animated flash
// cycling by its rate), the triggered emitter of room B
particle test_ring {
	{
		count				1
		material			"textures/particles/test_flash"
		time				1
		cycles				0
		bunching			0
		distribution		rect 0 0 0
		direction			cone 0
		orientation			z
		speed				"0"
		size				"12" to "32"
		fadeIn				0.1
		fadeOut				0.3
		animationFrames		4
		animationRate		8
		initialAngle		90
		color				0.4 1 0.5 1
		offset				0 0 2
	}
}
'''

FX = r'''// Castle Doom 3 test FX (generated by tools/make_test_pk4.py)

// a blast: a flash of light fading out, the explosion particles, a bang,
// then steam for 2 seconds
fx fx/test_blast {
	{
		delay		0
		duration	1.2
		light		"lights/test_flash", 1, 0.7, 0.3, 200
		fadeIn		0.05
		fadeOut		0.8
	}
	{
		delay		0
		particle	"test_explosion.prt"
	}
	{
		delay		0.05
		sound		"test_shotgun"
	}
	{
		delay		0.3
		duration	2
		model		"test_steam.prt"
		offset		0 0 8
	}
	{
		delay		0
		decal		"textures/test/decal_hole"
		size		32
	}
}
'''

SOUNDS = r'''
// Castle Doom 3 test sound shaders (generated by tools/make_test_pk4.py)
// Distances are in meters, like Doom 3's.

test_hum {
	minDistance	1
	maxDistance	15
	volume		-6
	looping
	sound/test/hum.wav
}

test_door {
	minDistance	2
	maxDistance	20
	sound/test/door.wav
}

test_step {
	minDistance	1
	maxDistance	10
	sound/test/step.wav
}

test_pain {
	minDistance	1
	maxDistance	20
	sound/test/pain.wav
}

test_pain_large {
	minDistance	1
	maxDistance	20
	sound/test/pain_large.wav
}

test_death {
	minDistance	1
	maxDistance	30
	sound/test/death.wav
}

test_berserk {
	minDistance	1
	maxDistance	30
	sound/test/berserk.wav
}

test_invisibility {
	minDistance	1
	maxDistance	30
	sound/test/invisibility.wav
}

test_land {
	minDistance	1
	maxDistance	15
	sound/test/land.wav
}

test_brass {
	minDistance	1
	maxDistance	15
	sound/test/brass.wav
}

test_shot {
	minDistance	2
	maxDistance	40
	sound/test/shot.wav
}

test_shotgun {
	minDistance	2
	maxDistance	50
	sound/test/shotgun.wav
}
'''


# --------------------------------------------------------------------------
# md5 creature

JOINTS = [  # name, parent, absolute bind position
    ('origin', -1, (0, 0, 0)),
    ('body', 0, (0, 0, 40)),
    ('head', 1, (0, 0, 76)),
    ('arm_l', 1, (0, 22, 60)),
    ('arm_r', 1, (0, -22, 60)),
    ('leg_l', 1, (0, 10, 24)),
    ('leg_r', 1, (0, -10, 24)),
]


BLOB_BOXES = [
    (1, (-14, -18, 24), (14, 18, 66)),      # body
    (2, (-10, -10, 66), (12, 10, 88)),      # head
    (3, (-5, 18, 30), (5, 26, 64)),         # left arm
    (4, (-5, -26, 30), (5, -18, 64)),       # right arm
    (5, (-6, 4, 0), (6, 16, 26)),           # left leg
    (6, (-6, -16, 0), (6, -4, 26)),         # right leg
]

# the player's body (player_test's model): the blob's skeleton and anims,
# a marine's proportions (74 high, the eye at 68)
PLAYER_BOXES = [
    (1, (-8, -13, 32), (8, 13, 60)),        # body
    (2, (-6, -6, 60), (8, 6, 74)),          # head
    (3, (-4, 13, 34), (4, 19, 58)),         # left arm
    (4, (-4, -19, 34), (4, -13, 58)),       # right arm
    (5, (-5, 2, 0), (5, 12, 32)),           # left leg
    (6, (-5, -12, 0), (5, -2, 32)),         # right leg
]


def af_text(name, model, boxes):
    """An articulated figure (Doom 3's af decl) for the creature skeleton:
    a body per box (torso, head, arms, legs) on its joint, the head on a
    ball and socket joint (40 degree cone), the arms on universal joints
    at the shoulders, the legs on hinges at the hips."""
    def v(p):
        return '( %s, %s, %s )' % tuple(fmt(c) for c in p)
    def center(mn, mx):
        return tuple((a + b) / 2.0 for a, b in zip(mn, mx))
    names = {1: 'torso', 2: 'head', 3: 'arm_l', 4: 'arm_r', 5: 'leg_l', 6: 'leg_r'}
    out = ['articulatedFigure %s {' % name, '\tsettings {', '\t\tmodel "%s"' % model,
           '\t\tfriction 0.01, 0.01, 0.8, 0.5', '\t\tsuspendSpeed 20, 30, 40, 60',
           '\t\tnoMoveTime 1', '\t\tcontents corpse', '\t\tclipMask solid, corpse',
           '\t\tselfCollision 1', '\t}', '']
    box = {}
    for joint_index, mn, mx in boxes:
        c = center(mn, mx)
        box[joint_index] = (mn, mx, c)
        joint = JOINTS[joint_index][0]
        contained = '*%s' % joint
        if joint_index == 1:
            contained = '*body -*head -*arm_l -*arm_r -*leg_l -*leg_r'
        out += ['\tbody "%s" {' % names[joint_index], '\t\tjoint "%s"' % joint, '\t\tmod orientation',
                '\t\tmodel box( %s, %s )' % (v([a - b for a, b in zip(mn, c)]), v([a - b for a, b in zip(mx, c)])),
                '\t\torigin %s' % v(c), '\t\tdensity 0.2', '\t\tfriction 0.01, 0.01, 0.8',
                '\t\tcontents corpse', '\t\tclipMask solid, corpse', '\t\tselfCollision 1',
                '\t\tcontainedJoints "%s"' % contained, '\t}', '']
    hmn, hmx, hc = box[2]
    out += ['\tballAndSocketJoint "neck" {', '\t\tbody1 "torso"', '\t\tbody2 "head"',
            '\t\tposition %s' % v((hc[0], hc[1], hmn[2])), '\t\tcone ( 0, 0, 1 ), 40', '\t\tfriction 0.5', '\t}', '']
    for j, side in ((3, 'l'), (4, 'r')):
        out += ['\tuniversalJoint "shoulder_%s" {' % side, '\t\tbody1 "torso"', '\t\tbody2 "%s"' % names[j],
                '\t\tposition joint( "%s" )' % JOINTS[j][0], '\t\tshafts ( 0, 0, 1 ), ( 0, 0, -1 )',
                '\t\tcone ( 0, 0, -1 ), 100', '\t\tfriction 0.5', '\t}', '']
    for j, side in ((5, 'l'), (6, 'r')):
        mn, mx, c = box[j]
        out += ['\thinge "hip_%s" {' % side, '\t\tbody1 "torso"', '\t\tbody2 "%s"' % names[j],
                '\t\tposition %s' % v((c[0], c[1], mx[2])), '\t\taxis ( 0, 1, 0 )',
                '\t\tlimit 0, 90, 0', '\t\tfriction 0.5', '\t}', '']
    out += ['}', '']
    return '\n'.join(out)


def md5mesh_text(shader='models/test/blob', boxes=BLOB_BOXES):
    verts, tris, weights = [], [], []

    def add_box(joint_index, mins, maxs):
        jx, jy, jz = JOINTS[joint_index][2]
        (x0, y0, z0), (x1, y1, z1) = mins, maxs
        corners = [(x, y, z) for z in (z0, z1) for y in (y0, y1) for x in (x0, x1)]
        # faces as corner indices, counter-clockwise from outside
        faces = [(0, 2, 3, 1), (4, 5, 7, 6), (0, 1, 5, 4), (2, 6, 7, 3), (0, 4, 6, 2), (1, 3, 7, 5)]
        for f in faces:
            base = len(verts)
            for k, ci in enumerate(f):
                c = corners[ci]
                st = ((0, 0), (1, 0), (1, 1), (0, 1))[k]
                weights.append((joint_index, 1.0, (c[0] - jx, c[1] - jy, c[2] - jz)))
                verts.append((st, len(weights) - 1, 1))
            # clockwise from outside, as Doom 3 expects
            tris.append((base, base + 2, base + 1))
            tris.append((base, base + 3, base + 2))

    for joint_index, mins, maxs in boxes:
        add_box(joint_index, mins, maxs)

    out = ['MD5Version 10', 'commandline "generated by tools/make_test_pk4.py"', '',
           'numJoints %d' % len(JOINTS), 'numMeshes 1', '', 'joints {']
    for name, parent, p in JOINTS:
        out.append('\t"%s"\t%d ( %s %s %s ) ( 0 0 0 )\t\t// %s' % (
            name, parent, fmt(p[0]), fmt(p[1]), fmt(p[2]), JOINTS[parent][0] if parent >= 0 else ''))
    out += ['}', '', 'mesh {', '\t// meshes: body', '\tshader "%s"' % shader, '',
            '\tnumverts %d' % len(verts)]
    for i, (st, sw, cw) in enumerate(verts):
        out.append('\tvert %d ( %s %s ) %d %d' % (i, fmt(st[0]), fmt(st[1]), sw, cw))
    out += ['', '\tnumtris %d' % len(tris)]
    for i, t in enumerate(tris):
        out.append('\ttri %d %d %d %d' % (i, t[0], t[1], t[2]))
    out += ['', '\tnumweights %d' % len(weights)]
    for i, (j, b, p) in enumerate(weights):
        out.append('\tweight %d %d %s ( %s %s %s )' % (i, j, fmt(b), fmt(p[0]), fmt(p[1]), fmt(p[2])))
    out += ['}', '']
    return '\n'.join(out)


# The weapons' view models: 3 joints (origin at the eye, the gun, its
# barrel), boxes on the gun and barrel joints.
VIEW_JOINTS = [('origin', -1, (0, 0, 0)), ('gun', 0, (22, -9, -11)), ('barrel', 1, (34, -9, -9)),
               ('flash', 2, (42, -9, -9)), ('eject', 1, (28, -7, -6))]


def flash_quads(x, size):
    """The muzzle flash on the flash joint: a quad facing the view and two
    crossed ones along the barrel (the material is two-sided)."""
    s = size
    return [((x, -s, -s), (x, s, -s), (x, s, s), (x, -s, s)),
            ((x - s, -s, 0), (x + 2 * s, -s, 0), (x + 2 * s, s, 0), (x - s, s, 0)),
            ((x - s, 0, -s), (x + 2 * s, 0, -s), (x + 2 * s, 0, s), (x - s, 0, s))]


def viewmodel_md5mesh(boxes, flash=None):
    """boxes: (joint index, mins, maxs) relative to the joint, in the
    metal mesh; flash: quads (4 corners each) on the flash joint, a second
    mesh with the muzzle flash material."""
    meshes = [('textures/test/metal', viewmodel_box_mesh(boxes))]
    if flash:
        meshes.append(('models/weapons/test/muzzleflash', viewmodel_quad_mesh(3, flash)))
    out = ['MD5Version 10', 'commandline "generated by tools/make_test_pk4.py"', '',
           'numJoints %d' % len(VIEW_JOINTS), 'numMeshes %d' % len(meshes), '', 'joints {']
    for name, parent, p in VIEW_JOINTS:
        out.append('\t"%s"\t%d ( %s %s %s ) ( 0 0 0 )' % (name, parent, fmt(p[0]), fmt(p[1]), fmt(p[2])))
    out += ['}', '']
    for shader, (verts, tris, weights) in meshes:
        out += ['mesh {', '\tshader "%s"' % shader, '', '\tnumverts %d' % len(verts)]
        for i, (st, sw, cw) in enumerate(verts):
            out.append('\tvert %d ( %s %s ) %d %d' % (i, fmt(st[0]), fmt(st[1]), sw, cw))
        out += ['', '\tnumtris %d' % len(tris)]
        for i, t in enumerate(tris):
            out.append('\ttri %d %d %d %d' % (i, t[0], t[1], t[2]))
        out += ['', '\tnumweights %d' % len(weights)]
        for i, (j, b, p) in enumerate(weights):
            out.append('\tweight %d %d %s ( %s %s %s )' % (i, j, fmt(b), fmt(p[0]), fmt(p[1]), fmt(p[2])))
        out += ['}', '']
    return '\n'.join(out)


def viewmodel_quad_mesh(joint_index, quads):
    verts, tris, weights = [], [], []
    for quad in quads:
        base = len(verts)
        for k, c in enumerate(quad):
            weights.append((joint_index, 1.0, c))
            verts.append((((0, 1), (1, 1), (1, 0), (0, 0))[k], len(weights) - 1, 1))
        tris.append((base, base + 2, base + 1))
        tris.append((base, base + 3, base + 2))
    return verts, tris, weights


def viewmodel_box_mesh(boxes):
    verts, tris, weights = [], [], []
    for joint_index, (x0, y0, z0), (x1, y1, z1) in boxes:
        corners = [(x, y, z) for z in (z0, z1) for y in (y0, y1) for x in (x0, x1)]
        faces = [(0, 2, 3, 1), (4, 5, 7, 6), (0, 1, 5, 4), (2, 6, 7, 3), (0, 4, 6, 2), (1, 3, 7, 5)]
        for f in faces:
            base = len(verts)
            for k, ci in enumerate(f):
                weights.append((joint_index, 1.0, corners[ci]))
                verts.append((((0, 0), (1, 0), (1, 1), (0, 1))[k], len(weights) - 1, 1))
            tris.append((base, base + 2, base + 1))
            tris.append((base, base + 3, base + 2))
    return verts, tris, weights


def viewmodel_md5anim(frames, gun_pose):
    """gun_pose(u) -> ((dx, dy, dz), (pitch, roll)) of the gun joint, u from
    0 to 1 over the anim (24 frames a second)."""
    rel = []
    for name, parent, p in VIEW_JOINTS:
        pp = VIEW_JOINTS[parent][2] if parent >= 0 else (0, 0, 0)
        rel.append((p[0] - pp[0], p[1] - pp[1], p[2] - pp[2]))
    out = ['MD5Version 10', 'commandline "generated by tools/make_test_pk4.py"', '',
           'numFrames %d' % frames, 'numJoints %d' % len(VIEW_JOINTS), 'frameRate 24',
           'numAnimatedComponents %d' % (len(VIEW_JOINTS) * 6), '', 'hierarchy {']
    for j, (name, parent, p) in enumerate(VIEW_JOINTS):
        out.append('\t"%s"\t%d 63 %d' % (name, parent, j * 6))
    out += ['}', '', 'bounds {']
    for f in range(frames):
        out.append('\t( -10 -20 -30 ) ( 50 10 10 )')
    out += ['}', '', 'baseframe {']
    for r in rel:
        out.append('\t( %s %s %s ) ( 0 0 0 )' % (fmt(r[0]), fmt(r[1]), fmt(r[2])))
    out += ['}', '']
    for f in range(frames):
        u = f / max(1, frames - 1)
        (dx, dy, dz), (pitch, roll) = gun_pose(u)
        out.append('frame %d {' % f)
        for j, r in enumerate(rel):
            if j == 1:
                q = quat_mul_xyz(quat_full((0, 1, 0), pitch), quat_full((1, 0, 0), roll))
                vals = [r[0] + dx, r[1] + dy, r[2] + dz] + q
            else:
                vals = [r[0], r[1], r[2], 0, 0, 0]
            out.append('\t ' + ' '.join(fmt(v) for v in vals))
        out += ['}', '']
    return '\n'.join(out)


def muzzleflash_texture():
    """A muzzle flash for additive blending: a hot core with 6 rays,
    black (nothing added) at the edges."""
    n = 64
    rows = []
    for y in range(n):
        row = []
        for x in range(n):
            dx, dy = (x + 0.5) / n * 2 - 1, (y + 0.5) / n * 2 - 1
            r = math.hypot(dx, dy)
            a = math.atan2(dy, dx)
            rays = 0.5 + 0.5 * math.cos(6 * a)
            v = max(0.0, 1 - r / (0.35 + 0.6 * rays ** 3))
            core = max(0.0, 1 - r / 0.3)
            i = min(1.0, v * 1.2 + core)
            row.append((i, i * (0.55 + 0.4 * core), i * (0.15 + 0.6 * core)))
        rows.append(row)
    return tga(n, n, rows)


def blood_blob_texture():
    """A dark red splat with soft, lumpy edges (alpha)."""
    n = 64
    rnd = random.Random(21)
    lobes = [(rnd.uniform(0, 2 * math.pi), rnd.uniform(0.08, 0.2)) for _ in range(7)]
    rows = []
    for y in range(n):
        row = []
        for x in range(n):
            dx, dy = (x + 0.5) / n * 2 - 1, (y + 0.5) / n * 2 - 1
            r = math.hypot(dx, dy)
            a = math.atan2(dy, dx)
            edge = 0.55 + sum(h * max(0, math.cos(a - p)) ** 6 for p, h in lobes)
            alpha = max(0.0, min(1.0, (edge - r) / 0.12))
            shade = 0.45 + 0.25 * (1 - r)
            row.append((shade, 0.02, 0.02, alpha * 0.85))
        rows.append(row)
    return tga(n, n, rows, alpha=True)


def quat_full(axis, angle):
    s = math.sin(angle / 2)
    return [axis[0] * s, axis[1] * s, axis[2] * s, math.cos(angle / 2)]


def quat_mul_xyz(a, b):
    """a * b, as Doom 3's x y z (w negative)."""
    x = a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1]
    y = a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0]
    z = a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3]
    w = a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2]
    q = [x, y, z, w]
    if q[3] > 0:
        q = [-v for v in q]
    return q[:3]


def worldmodel_md5mesh(boxes, flash_at, flash_size):
    """A gun in the player body's hand: the origin joint (bound to the
    body's joint_attach), boxes relative to it in the metal mesh, and a
    "flash" joint at the muzzle (flash_at, relative to the origin) with the
    muzzle flash quads (Doom 3's world muzzle flash: its light and
    surfaces show from there in third person)."""
    meshes = [('textures/test/metal', viewmodel_box_mesh([(0, mn, mx) for mn, mx in boxes]))]
    # the flash quads are relative to the flash joint (weights are offsets)
    meshes.append(('models/weapons/test/muzzleflash', viewmodel_quad_mesh(1, flash_quads(1, flash_size))))
    out = ['MD5Version 10', 'commandline "generated by tools/make_test_pk4.py"', '',
           'numJoints 3', 'numMeshes %d' % len(meshes), '', 'joints {',
           '\t"origin"\t-1 ( 0 0 0 ) ( 0 0 0 )',
           '\t"flash"\t0 ( %s %s %s ) ( 0 0 0 )' % tuple(fmt(v) for v in flash_at),
           # where the brass comes out: above the grip, right of the slide
           '\t"eject"\t0 ( 6 -3 -19 ) ( 0 0 0 )', '}', '']
    for shader, (verts, tris, weights) in meshes:
        out += ['mesh {', '\tshader "%s"' % shader, '', '\tnumverts %d' % len(verts)]
        for i, (st, sw, cw) in enumerate(verts):
            out.append('\tvert %d ( %s %s ) %d %d' % (i, fmt(st[0]), fmt(st[1]), sw, cw))
        out += ['', '\tnumtris %d' % len(tris)]
        for i, t in enumerate(tris):
            out.append('\ttri %d %d %d %d' % (i, t[0], t[1], t[2]))
        out += ['', '\tnumweights %d' % len(weights)]
        for i, (j, b, p) in enumerate(weights):
            out.append('\tweight %d %d %s ( %s %s %s )' % (i, j, fmt(b), fmt(p[0]), fmt(p[1]), fmt(p[2])))
        out += ['}', '']
    return '\n'.join(out)


def weapon_models():
    gun = [(1, (-3, -1.5, -7), (3, 1.5, 0)), (1, (-4, -2, 0), (12, 2, 4)), (2, (-2, -1, -1), (6, 1, 1))]
    shotgun = [(1, (-3, -1.5, -7), (3, 1.5, 0)), (1, (-8, -2.5, 0), (14, 2.5, 5)),
               (2, (-4, -1.5, -1.5), (14, 1.5, 1.5))]
    fists = [(1, (-4, -3, -3), (4, 3, 3))]
    add('models/md5/weapons/test_pistol/viewpistol.md5mesh', viewmodel_md5mesh(gun, flash_quads(1, 5)))
    add('models/md5/weapons/test_shotgun/viewshotgun.md5mesh', viewmodel_md5mesh(shotgun, flash_quads(7, 8)))
    add('models/weapons/test/muzzleflash.tga', muzzleflash_texture())
    add('textures/test/blood_blob.tga', blood_blob_texture())
    add('models/md5/weapons/test_fists/viewfists.md5mesh', viewmodel_md5mesh(fists))
    # the world models: from the shoulder joint down to the hand (26 below),
    # a grip and a barrel pointing forward (+x)
    add('models/md5/weapons/test_pistol/worldpistol.md5mesh', worldmodel_md5mesh(
        [((-2, -1.5, -32), (2, 1.5, -24)), ((-2, -2, -26), (14, 2, -21))], (14, 0, -23.5), 4))
    add('models/md5/weapons/test_shotgun/worldshotgun.md5mesh', worldmodel_md5mesh(
        [((-2, -1.5, -32), (2, 1.5, -24)), ((-10, -2.5, -27), (26, 2.5, -21))], (26, 0, -24), 6))
    s = math.sin
    add('models/md5/weapons/test_pistol/idle.md5anim', viewmodel_md5anim(
        24, lambda u: ((0, 0, 0.3 * s(2 * math.pi * u)), (0, 0))))
    add('models/md5/weapons/test_pistol/fire.md5anim', viewmodel_md5anim(
        6, lambda u: ((-2 * s(math.pi * u), 0, 0), (-0.25 * s(math.pi * u), 0))))
    add('models/md5/weapons/test_pistol/raise.md5anim', viewmodel_md5anim(
        8, lambda u: ((0, 0, -20 * (1 - u) ** 2), (0.5 * (1 - u), 0))))
    add('models/md5/weapons/test_pistol/putaway.md5anim', viewmodel_md5anim(
        8, lambda u: ((0, 0, -20 * u * u), (0.5 * u, 0))))
    add('models/md5/weapons/test_pistol/reload.md5anim', viewmodel_md5anim(
        24, lambda u: ((0, 0, -6 * s(math.pi * u)), (0, 0.6 * s(math.pi * u)))))
    add('models/md5/weapons/test_fists/punch.md5anim', viewmodel_md5anim(
        8, lambda u: ((12 * s(math.pi * u), 3 * s(math.pi * u), 2 * s(math.pi * u)), (0, 0))))


def quat_xyz(axis, angle):
    """Doom 3 stores x y z of a unit quaternion whose w is negative."""
    s = math.sin(angle / 2)
    q = [axis[0] * s, axis[1] * s, axis[2] * s, math.cos(angle / 2)]
    if q[3] > 0:
        q = [-v for v in q]
    return q[:3]


def md5anim_text(kind):
    frames, rate = {'evade': 25, 'death': 24, 'crouch_down': 8, 'crouch_up': 8, 'pain': 8}.get(kind, 48), 24
    rel = []
    for name, parent, p in JOINTS:
        pp = JOINTS[parent][2] if parent >= 0 else (0, 0, 0)
        rel.append((p[0] - pp[0], p[1] - pp[1], p[2] - pp[2]))
    data = []
    for f in range(frames):
        t = f / frames * 2 * math.pi
        comps = []
        for j, (name, parent, p) in enumerate(JOINTS):
            pos = list(rel[j])
            q = (0, 0, 0)
            if kind == 'idle':
                if name == 'body':
                    pos[2] += 2.0 * math.sin(t)
                    q = quat_xyz((1, 0, 0), 0.05 * math.sin(t))
                elif name == 'head':
                    q = quat_xyz((0, 0, 1), 0.35 * math.sin(t))
                elif name in ('arm_l', 'arm_r'):
                    sign = 1 if name == 'arm_l' else -1
                    q = quat_xyz((1, 0, 0), sign * (0.25 + 0.2 * math.sin(t * 2)))
            elif kind in ('crouch', 'crouch_walk', 'crouch_down', 'crouch_up'):
                # down by 22, the legs forward (kneeling); walking, they swing;
                # crouch_down / crouch_up go there from standing and back
                # (played once: Doom 3's Legs_Crouch / Legs_Uncrouch)
                k = 1.0
                if kind in ('crouch_down', 'crouch_up'):
                    u = f / (frames - 1)
                    k = 3 * u * u - 2 * u * u * u
                    if kind == 'crouch_up':
                        k = 1 - k
                if name == 'body':
                    pos[2] -= 22.0 * k
                    if kind == 'crouch_walk':
                        pos[2] += 1.5 * abs(math.sin(t * 2))
                elif name in ('leg_l', 'leg_r'):
                    swing = 0
                    if kind == 'crouch_walk':
                        swing = (1 if name == 'leg_r' else -1) * 0.3 * math.sin(t * 2)
                    q = quat_xyz((0, 1, 0), -1.4 * k + swing)
                elif name in ('arm_l', 'arm_r'):
                    q = quat_xyz((0, 1, 0), -0.5 * k)
            elif kind == 'death':
                # falls on its back in a second (played once, it holds the
                # last frame): the body turns 86 degrees back and down to
                # the floor
                u = f / (frames - 1)
                e = 3 * u * u - 2 * u * u * u
                if name == 'body':
                    pos[2] -= 30.0 * e
                    q = quat_xyz((0, 1, 0), -1.5 * e)
                elif name in ('arm_l', 'arm_r'):
                    sign = 1 if name == 'arm_l' else -1
                    q = quat_xyz((1, 0, 0), sign * 0.8 * e)
            elif kind == 'pain':
                # a flinch (played once): the body jerks back and down, the
                # arms fly up
                u = math.sin(math.pi * f / (frames - 1))
                if name == 'body':
                    pos[2] -= 4.0 * u
                    q = quat_xyz((0, 1, 0), 0.5 * u)
                elif name in ('arm_l', 'arm_r'):
                    sign = 1 if name == 'arm_l' else -1
                    q = quat_xyz((1, 0, 0), sign * 1.2 * u)
            elif kind == 'evade':
                # a sidestep: the origin moves 64 to the left (+y in model
                # space), easing in and out; the body leans into it
                u = f / (frames - 1)
                if name == 'origin':
                    pos[1] += 64.0 * (3 * u * u - 2 * u * u * u)
                elif name == 'body':
                    q = quat_xyz((1, 0, 0), -0.3 * math.sin(u * math.pi))
            else:  # walk
                if name == 'origin':
                    pass
                elif name == 'body':
                    pos[2] += 3.0 * abs(math.sin(t * 2))
                elif name in ('arm_l', 'arm_r', 'leg_l', 'leg_r'):
                    sign = 1 if name in ('arm_l', 'leg_r') else -1
                    q = quat_xyz((0, 1, 0), sign * 0.6 * math.sin(t * 2))
                elif name == 'head':
                    q = quat_xyz((0, 1, 0), 0.1)
            comps += [pos[0], pos[1], pos[2], q[0], q[1], q[2]]
        data.append(comps)
    out = ['MD5Version 10', 'commandline "generated by tools/make_test_pk4.py"', '',
           'numFrames %d' % frames, 'numJoints %d' % len(JOINTS), 'frameRate %d' % rate,
           'numAnimatedComponents %d' % (len(JOINTS) * 6), '', 'hierarchy {']
    for j, (name, parent, p) in enumerate(JOINTS):
        out.append('\t"%s"\t%d 63 %d\t// %s' % (name, parent, j * 6,
                                                  JOINTS[parent][0] if parent >= 0 else ''))
    out += ['}', '', 'bounds {']
    for f in range(frames):
        out.append('\t( -28 -30 0 ) ( 28 30 92 )')
    out += ['}', '', 'baseframe {']
    for j in range(len(JOINTS)):
        r = rel[j]
        out.append('\t( %s %s %s ) ( 0 0 0 )' % (fmt(r[0]), fmt(r[1]), fmt(r[2])))
    out += ['}', '']
    for f in range(frames):
        out.append('frame %d {' % f)
        c = data[f]
        for j in range(len(JOINTS)):
            out.append('\t ' + ' '.join(fmt(v) for v in c[j * 6:j * 6 + 6]))
        out += ['}', '']
    return '\n'.join(out)


# --------------------------------------------------------------------------
# Static models: LWO2 (LightWave) and ASE (3ds Max ASCII)

def lwo_chunk(cid, data):
    out = cid.encode('ascii') + struct.pack('>I', len(data)) + data
    if len(data) % 2:
        out += b'\0'
    return out


def lwo_str(s):
    b = s.encode('ascii') + b'\0'
    if len(b) % 2:
        b += b'\0'
    return b


def lwo_vx(i):
    return struct.pack('>H', i) if i < 0xFF00 else struct.pack('>I', 0xFF000000 | i)


def make_lwo(points, polys, uvs, vmad, surfaces):
    """points: Doom 3 coordinates; polys: (surface index, [point indexes]) with
    the corners counter-clockwise seen from the front in Doom 3 space; they
    are written reversed, clockwise from the front, as LightWave stores them
    (its y/z swap with Doom 3 only relabels the axes, it isn't a mirror);
    uvs: per point (u, v); vmad: (point, poly, (u, v)) overrides."""
    tags = b''.join(lwo_str(n) for n in surfaces)
    layr = struct.pack('>HH', 0, 0) + struct.pack('>fff', 0, 0, 0) + lwo_str('test')
    # Doom 3 reads LightWave points as (x, z, y)
    pnts = b''.join(struct.pack('>fff', p[0], p[2], p[1]) for p in points)
    vmap = b'TXUV' + struct.pack('>H', 2) + lwo_str('txuv') + b''.join(
        lwo_vx(i) + struct.pack('>ff', u, v) for i, (u, v) in enumerate(uvs))
    pols = b'FACE' + b''.join(struct.pack('>H', len(vs)) + b''.join(lwo_vx(v) for v in reversed(vs))
                              for _, vs in polys)
    ptag = b'SURF' + b''.join(lwo_vx(i) + struct.pack('>H', srf) for i, (srf, _) in enumerate(polys))
    vmad_data = b'TXUV' + struct.pack('>H', 2) + lwo_str('txuv') + b''.join(
        lwo_vx(pt) + lwo_vx(pl) + struct.pack('>ff', u, v) for pt, pl, (u, v) in vmad)
    body = b'LWO2' + lwo_chunk('TAGS', tags) + lwo_chunk('LAYR', layr) + lwo_chunk('PNTS', pnts)
    body += lwo_chunk('VMAP', vmap) + lwo_chunk('POLS', pols) + lwo_chunk('PTAG', ptag)
    body += lwo_chunk('VMAD', vmad_data)
    for name in surfaces:
        body += lwo_chunk('SURF', lwo_str(name) + lwo_str(''))
    return b'FORM' + struct.pack('>I', len(body)) + body


def barrel_lwo():
    """A 16-sided barrel, radius 18, height 44: sides with a texture seam
    (VMAD), n-gon caps with the metal material."""
    n, r, h = 16, 18.0, 44.0
    points, uvs = [], []
    for ring, z in ((0, 0.0), (1, h)):
        for i in range(n):
            a = 2 * math.pi * i / n
            points.append((r * math.cos(a), r * math.sin(a), z))
            uvs.append((i / n, z / h))
    polys, vmad = [], []
    for i in range(n):
        j = (i + 1) % n
        # outward side quad, counter-clockwise from outside (Doom 3 space)
        polys.append((0, [i, j, n + j, n + i]))
        if j == 0:
            # the seam: this quad's second column uses u = 1, not 0
            vmad.append((j, len(polys) - 1, (1.0, 0.0)))
            vmad.append((n + j, len(polys) - 1, (1.0, 1.0)))
    polys.append((1, [n + i for i in range(n)]))             # top, facing +Z
    polys.append((1, [i for i in reversed(range(n))]))       # bottom, facing -Z
    return make_lwo(points, polys, uvs, vmad,
                    ['models/mapobjects/test/barrel', 'textures/test/metal', 'unused_surface'])


def brass_lwo():
    """A spent casing: 4 long (x), 1.6 thick, around its center."""
    x, y, z = 2.0, 0.8, 0.8
    points = [(-x, -y, -z), (x, -y, -z), (x, y, -z), (-x, y, -z),
              (-x, -y, z), (x, -y, z), (x, y, z), (-x, y, z)]
    uvs = [(0, 0), (1, 0), (1, 1), (0, 1), (0, 0), (1, 0), (1, 1), (0, 1)]
    polys = [(0, [4, 5, 6, 7]), (0, [3, 2, 1, 0]), (0, [0, 1, 5, 4]),
             (0, [1, 2, 6, 5]), (0, [2, 3, 7, 6]), (0, [3, 0, 4, 7])]
    return make_lwo(points, polys, uvs, [], ['models/weapons/test/brass'])


def box_lwo(w, d, h):
    """A box w x d x h on the floor: metal sides, a glowing (screen) top."""
    x, y = w / 2.0, d / 2.0
    points = [(-x, -y, 0), (x, -y, 0), (x, y, 0), (-x, y, 0),
              (-x, -y, h), (x, -y, h), (x, y, h), (-x, y, h)]
    uvs = [(0, 0), (1, 0), (1, 1), (0, 1), (0, 0), (1, 0), (1, 1), (0, 1)]
    polys = [
        (1, [4, 5, 6, 7]),      # top, facing +Z
        (0, [3, 2, 1, 0]),      # bottom, facing -Z
        (0, [0, 1, 5, 4]),      # -Y
        (0, [1, 2, 6, 5]),      # +X
        (0, [2, 3, 7, 6]),      # +Y
        (0, [3, 0, 4, 7]),      # -X
    ]
    return make_lwo(points, polys, uvs, [], ['textures/test/metal', 'textures/test/screen'])


def terminal_ase():
    """A computer terminal: a base box (metal) and a tilted glowing screen,
    one GEOMOBJECT with a multi/sub-object material."""
    verts, faces = [], []

    def quad(corners, mtl):
        # corners counter-clockwise from the front, Doom 3 space
        b = len(verts)
        verts.extend(corners)
        faces.append(((b, b + 1, b + 2), mtl, ((0, 0), (1, 0), (1, 1))))
        faces.append(((b, b + 2, b + 3), mtl, ((0, 0), (1, 1), (0, 1))))

    x0, x1, y0, y1, z0, z1 = -16, 16, -24, 24, 0, 40
    quad([(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)], 0)   # front +X
    quad([(x0, y1, z0), (x0, y0, z0), (x0, y0, z1), (x0, y1, z1)], 0)   # back -X
    quad([(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)], 0)   # -Y
    quad([(x1, y1, z0), (x0, y1, z0), (x0, y1, z1), (x1, y1, z1)], 0)   # +Y
    quad([(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)], 0)   # top
    # tilted screen above the base, facing +X and a little up
    quad([(6, -20, 44), (6, 20, 44), (-4, 20, 74), (-4, -20, 74)], 1)
    quad([(-4, -20, 74), (-4, 20, 74), (6, 20, 44), (6, -20, 44)], 0)   # its back

    tverts, tfaces = [], []
    for (_, _, uv) in faces:
        idx = []
        for u, v in uv:
            idx.append(len(tverts))
            tverts.append((u, v))
        tfaces.append(idx)

    out = ['*3DSMAX_ASCIIEXPORT\t200', '*COMMENT "generated by tools/make_test_pk4.py"',
           '*SCENE {', '\t*SCENE_FILENAME "terminal.max"', '}',
           '*MATERIAL_LIST {', '\t*MATERIAL_COUNT 1', '\t*MATERIAL 0 {',
           '\t\t*MATERIAL_NAME "terminal"', '\t\t*MATERIAL_CLASS "Multi/Sub-Object"',
           '\t\t*NUMSUBMTLS 2']
    for i, bitmap in enumerate(('\\\\purgatory\\purgatory\\doom\\base\\textures\\test\\metal.tga',
                                'C:\\Doom3\\base\\textures\\test\\screen.tga')):
        out += ['\t\t*SUBMATERIAL %d {' % i, '\t\t\t*MATERIAL_NAME "sub%d"' % i,
                '\t\t\t*MAP_DIFFUSE {', '\t\t\t\t*MAP_NAME "Map #%d"' % i,
                '\t\t\t\t*BITMAP "%s"' % bitmap,
                '\t\t\t\t*UVW_U_OFFSET 0.0000', '\t\t\t\t*UVW_V_OFFSET 0.0000',
                '\t\t\t\t*UVW_U_TILING 1.0000', '\t\t\t\t*UVW_V_TILING 1.0000',
                '\t\t\t}', '\t\t}']
    out += ['\t}', '}', '*GEOMOBJECT {', '\t*NODE_NAME "terminal"', '\t*NODE_TM {',
            '\t\t*NODE_NAME "terminal"', '\t\t*TM_ROW0 1.0000 0.0000 0.0000', '\t}',
            '\t*MESH {', '\t\t*TIMEVALUE 0',
            '\t\t*MESH_NUMVERTEX %d' % len(verts), '\t\t*MESH_NUMFACES %d' % len(faces),
            '\t\t*MESH_VERTEX_LIST {']
    for i, v in enumerate(verts):
        out.append('\t\t\t*MESH_VERTEX %5d\t%.4f\t%.4f\t%.4f' % (i, v[0], v[1], v[2]))
    out += ['\t\t}', '\t\t*MESH_FACE_LIST {']
    for i, ((a, b, c), mtl, _) in enumerate(faces):
        out.append('\t\t\t*MESH_FACE %5d:    A: %5d B: %5d C: %5d AB:    1 BC:    1 CA:    0'
                   '\t *MESH_SMOOTHING 1 \t*MESH_MTLID %d' % (i, a, b, c, mtl))
    out += ['\t\t}', '\t\t*MESH_NUMTVERTEX %d' % len(tverts), '\t\t*MESH_TVERTLIST {']
    for i, (u, v) in enumerate(tverts):
        out.append('\t\t\t*MESH_TVERT %d\t%.4f\t%.4f\t0.0000' % (i, u, v))
    out += ['\t\t}', '\t\t*MESH_NUMTVFACES %d' % len(tfaces), '\t\t*MESH_TFACELIST {']
    for i, t in enumerate(tfaces):
        out.append('\t\t\t*MESH_TFACE %d\t%d\t%d\t%d' % (i, t[0], t[1], t[2]))
    out += ['\t\t}', '\t}', '\t*PROP_MOTIONBLUR 0', '\t*MATERIAL_REF 0', '}', '']
    return '\r\n'.join(out)


def barrel_texture():
    noise = fbm(N, 60)
    diff, spec = [], []
    for y in range(N):
        dr, sr = [], []
        for x in range(N):
            g = noise[y][x]
            band = (y % 64) < 6
            rust = g > 0.62
            if band:
                c = (0.25, 0.25, 0.25)
            elif rust:
                c = (0.45 + 0.2 * g, 0.25, 0.1)
            else:
                c = (0.15 + 0.1 * g, 0.32 + 0.12 * g, 0.18)
            dr.append(c)
            sp = 0.1 if rust else 0.5
            sr.append((sp, sp, sp))
        diff.append(dr)
        spec.append(sr)
    add('models/mapobjects/test/barrel_d.tga', tga(N, N, diff))
    add('models/mapobjects/test/barrel_s.tga', tga(N, N, spec))


# --------------------------------------------------------------------------
# Sounds

def wav(samples, rate=22050):
    buf = io.BytesIO()
    w = wave.open(buf, 'wb')
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(rate)
    w.writeframes(b''.join(struct.pack('<h', int(max(-1, min(1, s)) * 32000)) for s in samples))
    w.close()
    return buf.getvalue()


def sounds():
    rate = 22050
    # 2 second seamless machine hum (whole periods of 55, 110 and 165 Hz)
    n = rate * 2
    hum = [0.35 * math.sin(2 * math.pi * 55 * i / rate) + 0.2 * math.sin(2 * math.pi * 110 * i / rate)
           + 0.08 * math.sin(2 * math.pi * 165 * i / rate) for i in range(n)]
    add('sound/test/hum.wav', wav(hum, rate))
    # door: a pneumatic hiss with a falling clank
    n = int(rate * 0.9)
    rnd = random.Random(7)
    door = []
    for i in range(n):
        t = i / rate
        env = min(1, t * 20) * math.exp(-t * 3)
        door.append(0.5 * env * (rnd.random() * 2 - 1) + 0.4 * math.exp(-t * 8) *
                    math.sin(2 * math.pi * (180 - 80 * t) * t))
    add('sound/test/door.wav', wav(door, rate))
    n = int(rate * 0.15)
    step = [0.6 * math.exp(-i / rate * 40) * math.sin(2 * math.pi * 90 * i / rate) for i in range(n)]
    add('sound/test/step.wav', wav(step, rate))
    # gunshots: a noise crack with a low thump, the shotgun's longer and lower
    for name, length, decay, thump in (('shot', 0.3, 18, 70), ('shotgun', 0.6, 9, 45)):
        n = int(rate * length)
        rnd = random.Random(11)
        shot, lp = [], 0.0
        for i in range(n):
            t = i / rate
            lp += 0.35 * (rnd.random() * 2 - 1 - lp)
            shot.append(0.8 * math.exp(-t * decay) * lp * 2 + 0.5 * math.exp(-t * decay * 0.6) *
                        math.sin(2 * math.pi * thump * t))
        add('sound/test/%s.wav' % name, wav([max(-1, min(1, v)) for v in shot], rate))
    # a casing bouncing: a short high ring
    tink = [0.6 * math.exp(-i / rate * 60) * math.sin(2 * math.pi * 3800 * i / rate) for i in range(int(rate * 0.08))]
    add('sound/test/brass.wav', wav(tink, rate))
    # the player's cries: a voiced grunt (a low buzz through two vowel
    # formants), longer and lower for big pain and death; a landing thud
    for name, length, f0, f1, f2 in (('pain', 0.3, 140, 600, 1100), ('pain_large', 0.45, 115, 650, 1000),
                                     ('death', 1.0, 95, 500, 850)):
        n = int(rate * length)
        out = []
        for i in range(n):
            t = i / rate
            env = min(1, t * 40) * max(0.0, 1 - t / length) ** 1.5
            pitch = f0 * (1 - 0.25 * t / length)
            buzz = sum(math.sin(2 * math.pi * pitch * k * t) / k for k in range(1, 12))
            form = 0.6 * math.sin(2 * math.pi * f1 * t) + 0.4 * math.sin(2 * math.pi * f2 * t)
            out.append(0.35 * env * buzz * (0.6 + 0.4 * form))
        add('sound/test/%s.wav' % name, wav([max(-1, min(1, v)) for v in out], rate))
    # berserk: a rising growl; invisibility: a shimmering sweep
    n = int(rate * 1.2)
    growl = []
    for i in range(n):
        t = i / rate
        env = min(1, t * 6) * max(0.0, 1 - t / 1.2)
        f = 70 + 60 * t
        growl.append(0.4 * env * sum(math.sin(2 * math.pi * f * k * t + k) / k for k in range(1, 8)))
    add('sound/test/berserk.wav', wav([max(-1, min(1, v)) for v in growl], rate))
    n = int(rate * 1.0)
    sweep = []
    for i in range(n):
        t = i / rate
        env = math.sin(math.pi * t)
        f = 400 + 1600 * t
        sweep.append(0.3 * env * math.sin(2 * math.pi * f * t) * (0.6 + 0.4 * math.sin(2 * math.pi * 9 * t)))
    add('sound/test/invisibility.wav', wav(sweep, rate))
    n = int(rate * 0.25)
    rnd = random.Random(5)
    land = [0.7 * math.exp(-i / rate * 25) * (math.sin(2 * math.pi * 60 * i / rate) + 0.3 * (rnd.random() * 2 - 1))
            for i in range(n)]
    add('sound/test/land.wav', wav([max(-1, min(1, v)) for v in land], rate))


# Scripts. The event declarations are the engine's interface (written here,
# like the rest of the test data); a Doom 3 install has its own
# script/doom_events.script.
DOOM_MAIN_SCRIPT = """// Castle Doom 3 test level: the events and defines testmap.script uses.
#ifndef __TEST_DEFS__
#define __TEST_DEFS__

#define UP      -1
#define DOWN    -2
#define YAW     1

#define ANIMCHANNEL_ALL     0
#define ANIMCHANNEL_TORSO   1
#define ANIMCHANNEL_LEGS    2
#define ANIMCHANNEL_HEAD    3

#define TALK_OK             2

#define MOVETYPE_ANIM       1
#define MOVETYPE_FLY        3

#define eachFrame       for( 0; 1; waitFrame() )
#define waitUntil( x )  while( !( x ) ) { waitFrame(); }

// sys events
scriptEvent void    wait( float time );
scriptEvent void    waitFor( entity mover );
scriptEvent void    waitFrame();
scriptEvent void    print( string text );
scriptEvent void    trigger( entity ent );
scriptEvent float   getTime();

// entity events
scriptEvent string  getName();
scriptEvent void    setColor( float red, float green, float blue );
scriptEvent void    time( float time );
scriptEvent void    accelTime( float time );
scriptEvent void    decelTime( float time );
scriptEvent void    move( float angle, float distance );
scriptEvent void    rotateOnce( vector angles );
scriptEvent float   startSoundShader( string shaderName, float channel );
scriptEvent void    fadeOutLight( float time );
scriptEvent void    setGuiParm( string key, string value );
scriptEvent void    startSpline( entity spline );

// AI events (idAI)
scriptEvent void    setState( string name );
scriptEvent void    setNextState( string name );
scriptEvent void    animState( float channel, string stateFunction, float blendFrames );
scriptEvent float   inAnimState( float channel, string stateFunc );
scriptEvent float   idleAnim( float channel, string animName );
scriptEvent float   playCycle( float channel, string animName );
scriptEvent float   playAnim( float channel, string animName );
scriptEvent float   animDone( float channel, float blendOutFrames );
scriptEvent void    moveToEntity( entity destination );
scriptEvent void    turnTo( float yaw );
scriptEvent float   facingIdeal();
scriptEvent entity  getEntityKey( string key );
scriptEvent entity  checkForEnemy( float useFOV );
scriptEvent void    faceEnemy();
scriptEvent void    moveToEnemy();
scriptEvent float   testMeleeAttack();
scriptEvent void    waitAction( string name );
scriptEvent void    finishAction( string name );
scriptEvent void    stopMove();
scriptEvent void    stopThinking();
scriptEvent float   enemyRange();
scriptEvent float   canHitEnemyFromAnim( string anim );
scriptEvent void    locateEnemy();
scriptEvent void    setMoveType( float movetype );
scriptEvent void    chargeAttack( string damageDef );
scriptEvent void    waitMove();
scriptEvent entity  getCombatNode();
scriptEvent void    markUsed();
scriptEvent float   testAnimMove( string anim );
scriptEvent entity  chooseObjectToThrow( vector mins, vector maxs, float speed, float minDist, float offset );
scriptEvent void    throwObjectAtEnemy( entity ent, float speed );
scriptEvent float   canHitEnemyFromJoint( string jointname );
scriptEvent entity  attackMissile( string jointname );
scriptEvent void    setTalkState( float state );
scriptEvent void    setTalkTarget( entity target );
scriptEvent void    lookAt( entity focusEntity, float duration );

// weapon events (idWeapon)
scriptEvent entity  getOwner();
scriptEvent void    nextWeapon();
scriptEvent void    weaponState( string stateFunction, float blendFrames );
scriptEvent void    useAmmo( float amount );
scriptEvent void    addToClip( float amount );
scriptEvent float   ammoInClip();
scriptEvent float   ammoAvailable();
scriptEvent float   totalAmmoCount();
scriptEvent float   clipSize();
scriptEvent void    weaponOutOfAmmo();
scriptEvent void    weaponReady();
scriptEvent void    weaponReloading();
scriptEvent void    weaponHolstered();
scriptEvent void    weaponRising();
scriptEvent void    weaponLowering();
scriptEvent void    launchProjectiles( float num_projectiles, float spread, float fuseOffset, float launchPower, float dmgPower );
scriptEvent float   melee();
scriptEvent float   autoReload();
scriptEvent float   getFloatKey( string key );

// The test weapons, in the way of Doom 3's script/weapon_*.script: a state
// function at a time in the weapon's thread (weaponState), the player's
// buttons in the WEAPON_ flags.
object weapon_test_base {
    boolean WEAPON_ATTACK;
    boolean WEAPON_RELOAD;
    boolean WEAPON_NETRELOAD;
    boolean WEAPON_NETENDRELOAD;
    boolean WEAPON_NETFIRING;
    boolean WEAPON_RAISEWEAPON;
    boolean WEAPON_LOWERWEAPON;
    boolean WEAPON_START_FIRING;
    float   next_attack;
    void    init();
    void    Raise();
    void    Lower();
};

void weapon_test_base::init() {
    next_attack = 0;
    weaponState( "Raise", 0 );
}

void weapon_test_base::Raise() {
    weaponRising();
    playAnim( ANIMCHANNEL_ALL, "raise" );
    waitUntil( animDone( ANIMCHANNEL_ALL, 0 ) );
    weaponState( "Idle", 0 );
}

void weapon_test_base::Lower() {
    weaponLowering();
    playAnim( ANIMCHANNEL_ALL, "putaway" );
    waitUntil( animDone( ANIMCHANNEL_ALL, 0 ) );
    weaponHolstered();
    waitUntil( WEAPON_RAISEWEAPON );
    weaponState( "Raise", 0 );
}

// the pistol and the shotgun: test_projectiles per shot every test_firerate
// seconds, spread, a clip to reload
object weapon_test_gun : weapon_test_base {
    float   spread;
    float   fire_rate;
    float   projectiles;
    void    init();
    void    Idle();
    void    Fire();
    void    Reload();
};

void weapon_test_gun::init() {
    next_attack = 0;
    spread = getFloatKey( "spread" );
    fire_rate = getFloatKey( "test_firerate" );
    projectiles = getFloatKey( "test_projectiles" );
    weaponState( "Raise", 0 );
}

void weapon_test_gun::Idle() {
    if ( !ammoInClip() ) {
        weaponOutOfAmmo();
    } else {
        weaponReady();
    }
    playCycle( ANIMCHANNEL_ALL, "idle" );
    while ( 1 ) {
        if ( WEAPON_LOWERWEAPON ) {
            weaponState( "Lower", 0 );
        }
        if ( ( sys.getTime() >= next_attack ) && WEAPON_ATTACK ) {
            if ( ammoInClip() > 0 ) {
                weaponState( "Fire", 0 );
            } else if ( ammoAvailable() > 0 ) {
                if ( autoReload() ) {
                    weaponState( "Reload", 0 );
                }
            }
        }
        if ( WEAPON_RELOAD && ( ammoAvailable() > ammoInClip() ) && ( ammoInClip() < clipSize() ) ) {
            weaponState( "Reload", 0 );
        }
        waitFrame();
    }
}

void weapon_test_gun::Fire() {
    next_attack = sys.getTime() + fire_rate;
    launchProjectiles( projectiles, spread, 0, 1.0, 1.0 );
    playAnim( ANIMCHANNEL_ALL, "fire" );
    waitUntil( animDone( ANIMCHANNEL_ALL, 0 ) );
    weaponState( "Idle", 0 );
}

void weapon_test_gun::Reload() {
    weaponReloading();
    playAnim( ANIMCHANNEL_ALL, "reload" );
    waitUntil( animDone( ANIMCHANNEL_ALL, 0 ) );
    addToClip( clipSize() );
    weaponState( "Idle", 0 );
}

// the fists: a punch (melee) every half second
float fists_hits;

object weapon_test_fists : weapon_test_base {
    void    Idle();
    void    Punch();
};

void weapon_test_fists::Idle() {
    weaponReady();
    playCycle( ANIMCHANNEL_ALL, "idle" );
    while ( 1 ) {
        if ( WEAPON_LOWERWEAPON ) {
            weaponState( "Lower", 0 );
        }
        if ( ( sys.getTime() >= next_attack ) && WEAPON_ATTACK ) {
            weaponState( "Punch", 0 );
        }
        waitFrame();
    }
}

void weapon_test_fists::Punch() {
    next_attack = sys.getTime() + 0.5;
    playAnim( ANIMCHANNEL_ALL, "fire" );
    sys.wait( 0.1 );
    if ( melee() ) {
        fists_hits++;
    }
    waitUntil( animDone( ANIMCHANNEL_ALL, 0 ) );
    weaponState( "Idle", 0 );
}

#endif
"""

MAP_SCRIPT = """// Castle Doom 3 test level script: compiled after script/doom_main.script,
// main() runs on the first frame.

float lift_trips;
float trigger_calls;
float bar_turned;
float bar_splined;

// the lift in room B goes up and down forever
void lift_loop() {
    $lift_1.time( 2 );
    $lift_1.accelTime( 0.5 );
    $lift_1.decelTime( 0.5 );
    while ( 1 ) {
        $lift_1.startSoundShader( "test_door", 1 );
        $lift_1.move( UP, 64 );
        sys.waitFor( $lift_1 );
        sys.wait( 1 );
        $lift_1.move( DOWN, 64 );
        sys.waitFor( $lift_1 );
        lift_trips++;
        sys.wait( 1 );
    }
}

// trigger_once_1's "call" key
// the test panel GUI's button (runScript "test_gui_clicked")
void test_gui_clicked() {
	sys.print( "GUI clicked\\n" );
}

void test_trigger_called() {
    trigger_calls++;
    // the character in room A walks to its path_corner
    sys.trigger( $test_walker_1 );
    // the panel in room A shows it
    $panel_1.setGuiParm( "gui_parm1", "TRIGGERED" );
    sys.print( "test_trigger_called by " + $trigger_once_1.getName() + "\n" );
    sys.wait( 1 );
    // the relay switched the light on 0.5 s after the trigger: make it green
    $light_trig.setColor( 0, 1, 0 );
    // and fade it out a second later
    sys.wait( 1 );
    $light_trig.fadeOutLight( 1 );
}

// A character's AI, in the way of Doom 3's script/ai_character.script:
// a state machine in the main thread, an animation state for the legs.
float walker_done;
float walker_talks;

object character {
    boolean AI_TALK;
    boolean AI_FORWARD;
    boolean AI_MOVE_DONE;
    boolean AI_ACTIVATED;
    boolean AI_ONGROUND;
    boolean AI_DEST_UNREACHABLE;
    void    init();
    void    state_Begin();
    void    state_Walk();
    void    state_Done();
    void    Legs_Idle();
    void    Legs_Walk();
};

void character::init() {
    setNextState( "state_Begin" );
}

void character::state_Begin() {
    animState( ANIMCHANNEL_LEGS, "Legs_Idle", 0 );
    // until triggered
    waitUntil( AI_ACTIVATED );
    setState( "state_Walk" );
}

void character::state_Walk() {
    // to its path_corner, then face north
    moveToEntity( getEntityKey( "target" ) );
    waitFrame();
    waitUntil( AI_MOVE_DONE );
    turnTo( 90 );
    waitUntil( facingIdeal() );
    setState( "state_Done" );
}

void character::state_Done() {
    walker_done = 1;
    // the player can talk to it now (the use key)
    setTalkState( TALK_OK );
    eachFrame {
        if ( AI_TALK ) {
            // it looks at the player while the head's lip sync anim says
            // the line (its sound_voice frame command)
            lookAt( $player1, 2.5 );
            playAnim( ANIMCHANNEL_HEAD, "talk_primary" );
            waitUntil( animDone( ANIMCHANNEL_HEAD, 0 ) );
            walker_talks++;
            setTalkTarget( $null_entity );
        }
    }
}

void character::Legs_Idle() {
    idleAnim( ANIMCHANNEL_LEGS, "idle" );
    eachFrame {
        if ( AI_FORWARD ) {
            animState( ANIMCHANNEL_LEGS, "Legs_Walk", 4 );
        }
    }
}

void character::Legs_Walk() {
    playCycle( ANIMCHANNEL_LEGS, "walk" );
    while( AI_FORWARD ) {
        waitFrame();
    }
    animState( ANIMCHANNEL_LEGS, "Legs_Idle", 4 );
}

// A character moving by its animation (like the path_anim commands of
// Doom 3's characters): activated, it plays evade_left, whose origin moves
// 64 to its left, and the character moves with it.
object character_stepper : character {
    void    state_Begin();
};

void character_stepper::state_Begin() {
    animState( ANIMCHANNEL_LEGS, "Legs_Idle", 0 );
    waitUntil( AI_ACTIVATED );
    playAnim( ANIMCHANNEL_LEGS, "evade_left" );
    waitUntil( animDone( ANIMCHANNEL_LEGS, 0 ) );
    idleAnim( ANIMCHANNEL_LEGS, "idle" );
    sys.print( "test_stepper_1 stepped\n" );
    eachFrame {
    }
}

// A monster's AI, in the way of Doom 3's monster scripts: wait for the
// enemy, chase it, melee attacks (the anim's melee frame command hits),
// state_Killed when it dies.
float monster_killed;
float next_range_attack;

object monster_test {
    boolean AI_FORWARD;
    boolean AI_MOVE_DONE;
    boolean AI_ACTIVATED;
    boolean AI_ONGROUND;
    boolean AI_DEST_UNREACHABLE;
    boolean AI_PAIN;
    boolean AI_DEAD;
    boolean AI_ENEMY_VISIBLE;
    boolean AI_ENEMY_IN_FOV;
    boolean AI_ENEMY_DEAD;
    void    init();
    void    state_Begin();
    void    state_Combat();
    void    state_Killed();
    void    Torso_Idle();
    void    Torso_Melee();
    void    Torso_Range();
    void    Legs_Idle();
    void    Legs_Walk();
};

void monster_test::init() {
    setState( "state_Begin" );
}

void monster_test::state_Begin() {
    animState( ANIMCHANNEL_TORSO, "Torso_Idle", 0 );
    animState( ANIMCHANNEL_LEGS, "Legs_Idle", 0 );
    while( !AI_PAIN ) {
        if ( checkForEnemy( 1 ) ) {
            break;
        }
        waitFrame();
    }
    setState( "state_Combat" );
}

void monster_test::state_Combat() {
    eachFrame {
        faceEnemy();
        if ( testMeleeAttack() ) {
            animState( ANIMCHANNEL_TORSO, "Torso_Melee", 4 );
            waitAction( "melee" );
            continue;
        }
        // from afar: throw something (the range anim launches it)
        if ( ( enemyRange() > 150 ) && ( sys.getTime() > next_range_attack ) && canHitEnemyFromAnim( "range" ) ) {
            stopMove();
            animState( ANIMCHANNEL_TORSO, "Torso_Range", 4 );
            waitAction( "range" );
            next_range_attack = sys.getTime() + 1.5;
            continue;
        }
        moveToEnemy();
    }
}

void monster_test::state_Killed() {
    stopMove();
    monster_killed = 1;
    stopThinking();
}

void monster_test::Torso_Idle() {
    idleAnim( ANIMCHANNEL_TORSO, "idle" );
}

void monster_test::Torso_Melee() {
    playAnim( ANIMCHANNEL_TORSO, "melee" );
    waitUntil( animDone( ANIMCHANNEL_TORSO, 0 ) );
    finishAction( "melee" );
    animState( ANIMCHANNEL_TORSO, "Torso_Idle", 4 );
}

void monster_test::Torso_Range() {
    playAnim( ANIMCHANNEL_TORSO, "range" );
    waitUntil( animDone( ANIMCHANNEL_TORSO, 0 ) );
    finishAction( "range" );
    animState( ANIMCHANNEL_TORSO, "Torso_Idle", 4 );
}

void monster_test::Legs_Idle() {
    idleAnim( ANIMCHANNEL_LEGS, "idle" );
    eachFrame {
        if ( AI_FORWARD ) {
            animState( ANIMCHANNEL_LEGS, "Legs_Walk", 4 );
        }
    }
}

void monster_test::Legs_Walk() {
    playCycle( ANIMCHANNEL_LEGS, "walk" );
    while( AI_FORWARD ) {
        waitFrame();
    }
    animState( ANIMCHANNEL_LEGS, "Legs_Idle", 4 );
}

// A monster with ranged attacks, waiting until it is activated: every
// second it throws a homing ball (projectile_test_guided), the first time
// with its "throw" anim (create_missile puts the ball in its hand,
// launch_missile throws it), the second time with attackMissile.
float ranged_shots;
float next_ranged_shot;

object monster_test_ranged : monster_test {
    void    state_Begin();
    void    state_Combat();
    void    Torso_Throw();
};

void monster_test_ranged::state_Begin() {
    animState( ANIMCHANNEL_TORSO, "Torso_Idle", 0 );
    animState( ANIMCHANNEL_LEGS, "Legs_Idle", 0 );
    while( !AI_ACTIVATED ) {
        waitFrame();
    }
    locateEnemy();
    setState( "state_Combat" );
}

void monster_test_ranged::state_Combat() {
    eachFrame {
        faceEnemy();
        if ( ( sys.getTime() > next_ranged_shot ) && canHitEnemyFromJoint( "body" ) ) {
            if ( ranged_shots == 1 ) {
                attackMissile( "body" );
            } else {
                animState( ANIMCHANNEL_TORSO, "Torso_Throw", 4 );
                waitAction( "throw" );
            }
            ranged_shots = ranged_shots + 1;
            next_ranged_shot = sys.getTime() + 1;
        }
    }
}

void monster_test_ranged::Torso_Throw() {
    playAnim( ANIMCHANNEL_TORSO, "throw" );
    waitUntil( animDone( ANIMCHANNEL_TORSO, 0 ) );
    finishAction( "throw" );
    animState( ANIMCHANNEL_TORSO, "Torso_Idle", 4 );
}

// A flying monster (like the cacodemon and the lost soul): it flies once
// activated, up to the player's eyes (plus fly_offset), chases it and,
// near it, charges (chargeAttack: straight on, hurting once on touch)
// every 2 seconds.
float next_charge;

object monster_test_flyer : monster_test {
    void    init();
    void    state_Begin();
    void    state_Combat();
};

void monster_test_flyer::init() {
    setMoveType( MOVETYPE_FLY );
    setState( "state_Begin" );
}

void monster_test_flyer::state_Begin() {
    animState( ANIMCHANNEL_TORSO, "Torso_Idle", 0 );
    animState( ANIMCHANNEL_LEGS, "Legs_Idle", 0 );
    while( !AI_ACTIVATED ) {
        waitFrame();
    }
    locateEnemy();
    setState( "state_Combat" );
}

void monster_test_flyer::state_Combat() {
    eachFrame {
        if ( ( sys.getTime() > next_charge ) && ( enemyRange() < 160 ) ) {
            chargeAttack( "damage_test_charge" );
            next_charge = sys.getTime() + 2;
            waitMove();
        } else {
            moveToEnemy();
        }
    }
}

// A monster using a combat node and dodging: once activated it goes to
// the closest combat node among its targets that has the player in its
// cone (getCombatNode), marks it used, then sidesteps (its evade_left anim
// moves it) every second while there's room (testAnimMove).
float dodges;

object monster_test_dodger : monster_test {
    void    state_Begin();
    void    state_Combat();
    void    Torso_Evade();
};

void monster_test_dodger::state_Begin() {
    animState( ANIMCHANNEL_TORSO, "Torso_Idle", 0 );
    animState( ANIMCHANNEL_LEGS, "Legs_Idle", 0 );
    while( !AI_ACTIVATED ) {
        waitFrame();
    }
    locateEnemy();
    setState( "state_Combat" );
}

void monster_test_dodger::state_Combat() {
    entity node;
    node = getCombatNode();
    if ( node ) {
        moveToEntity( node );
        waitMove();
        node.markUsed();
        sys.print( "blob_dodger_1 at its combat node\n" );
    }
    eachFrame {
        faceEnemy();
        sys.wait( 1 );
        if ( testAnimMove( "evade_left" ) ) {
            animState( ANIMCHANNEL_TORSO, "Torso_Evade", 0 );
            waitAction( "evade" );
            dodges = dodges + 1;
            sys.print( "blob_dodger_1 dodged\n" );
        }
    }
}

void monster_test_dodger::Torso_Evade() {
    playAnim( ANIMCHANNEL_TORSO, "evade_left" );
    waitUntil( animDone( ANIMCHANNEL_TORSO, 0 ) );
    finishAction( "evade" );
    animState( ANIMCHANNEL_TORSO, "Torso_Idle", 0 );
}

// A monster throwing things like the vagary: once activated, it picks a
// moveable around it that it can throw at the player and throws it.
object monster_test_thrower : monster_test {
    void    state_Begin();
    void    state_Combat();
};

void monster_test_thrower::state_Begin() {
    animState( ANIMCHANNEL_TORSO, "Torso_Idle", 0 );
    animState( ANIMCHANNEL_LEGS, "Legs_Idle", 0 );
    while( !AI_ACTIVATED ) {
        waitFrame();
    }
    locateEnemy();
    setState( "state_Combat" );
}

void monster_test_thrower::state_Combat() {
    entity obj;
    obj = chooseObjectToThrow( '-200 -200 -16', '200 200 128', 700, 64, 32 );
    if ( obj ) {
        sys.print( "blob_thrower_1 throws " + obj.getName() + "\n" );
        throwObjectAtEnemy( obj, 700 );
    }
    eachFrame {
        faceEnemy();
    }
}

void main() {
    sys.print( "testmap main\n" );
    thread lift_loop();
    // turn the bar to point along +y (yaw +90 is counter-clockwise from above)
    $bar_1.time( 1 );
    $bar_1.rotateOnce( '0 90 0' );
    sys.waitFor( $bar_1 );
    bar_turned = 1;
    // then along a curve (spline_1) in 2 s
    sys.wait( 2 );
    $bar_1.time( 2 );
    $bar_1.startSpline( $spline_1 );
    sys.waitFor( $bar_1 );
    bar_splined = 1;
}
"""


def quat_from_axes(f, u):
    """Doom 3 md5 quaternion x y z (w = -sqrt(...)) turning +X to f and +Z to u."""
    l = (u[1] * f[2] - u[2] * f[1], u[2] * f[0] - u[0] * f[2], u[0] * f[1] - u[1] * f[0])
    # rotation matrix with columns f, l, u
    m = [[f[0], l[0], u[0]], [f[1], l[1], u[1]], [f[2], l[2], u[2]]]
    tr = m[0][0] + m[1][1] + m[2][2]
    if tr > 0:
        w = math.sqrt(1 + tr) / 2
        x = (m[2][1] - m[1][2]) / (4 * w)
        y = (m[0][2] - m[2][0]) / (4 * w)
        z = (m[1][0] - m[0][1]) / (4 * w)
    else:
        i = max(range(3), key=lambda k: m[k][k])
        j, k = (i + 1) % 3, (i + 2) % 3
        r = math.sqrt(1 + m[i][i] - m[j][j] - m[k][k])
        q = [0, 0, 0]
        q[i] = r / 2
        q[j] = (m[j][i] + m[i][j]) / (2 * r)
        q[k] = (m[k][i] + m[i][k]) / (2 * r)
        w = (m[k][j] - m[j][k]) / (2 * r)
        x, y, z = q
    if w > 0:
        # stored with a negative w: the same rotation is -q
        x, y, z = -x, -y, -z
    return x, y, z


def normalize(v):
    n = math.sqrt(sum(c * c for c in v))
    return tuple(c / n for c in v)


def md5camera_text():
    """3 s at 24 frames per second: a dolly along room B's south side
    looking north, then (a cut) a shot from the balcony down at the door."""
    frames = []
    for i in range(37):
        t = i / 36
        frames.append(((380 + 320 * t, -300, 120), (0, 1, 0), 90))
    for i in range(36):
        t = i / 35
        pos = (800, 300, 200 - 40 * t)
        frames.append((pos, normalize((450 - pos[0], 0 - pos[1], 40 - pos[2])), 70))
    out = ['MD5Version 10', 'commandline "generated by tools/make_test_pk4.py"', '',
           'numFrames %d' % len(frames), 'frameRate 24', 'numCuts 1', '', 'cuts {', '\t37', '}', '',
           'camera {']
    for pos, fwd, fov in frames:
        # up: world up made perpendicular to the view direction
        up = (0, 0, 1)
        d = sum(a * b for a, b in zip(up, fwd))
        up = normalize(tuple(a - d * b for a, b in zip(up, fwd)))
        q = quat_from_axes(fwd, up)
        out.append('\t( %s ) ( %s ) %s' % (' '.join(fmt(c) for c in pos),
                                           ' '.join('%.9f' % c for c in q), fmt(fov)))
    out.append('}')
    return '\n'.join(out) + '\n'


# Reverb settings like the full game's efxs/*.efx (dhewm3's idEFXFile):
# effects named by a portal area number, a location or "default"; gains in
# millibels. Room B (area 1) is a big hall, room A (location room_a) small.
EFX = '''Version 1

reverb "default" {
	"environment" 0
	"environment size" 7.5
	"environment diffusion" 1.0
	"room" -1000
	"room hf" -100
	"room lf" 0
	"decay time" 1.49
	"decay hf ratio" 0.83
	"decay lf ratio" 1.0
	"reflections" -2602
	"reflections delay" 0.007
	"reflections pan" 0 0 0
	"reverb" 200
	"reverb delay" 0.011
	"reverb pan" 0 0 0
	"echo time" 0.25
	"echo depth" 0
	"modulation time" 0.25
	"modulation depth" 0
	"air absorption hf" -5
	"hf reference" 5000
	"lf reference" 250
	"room rolloff factor" 0
	"flags" 0x3f
}

reverb "room_a" {
	"environment" 2
	"environment size" 1.9
	"environment diffusion" 1.0
	"room" -1000
	"room hf" -454
	"decay time" 0.4
	"decay hf ratio" 0.83
	"reflections" -1646
	"reflections delay" 0.002
	"reverb" 53
	"reverb delay" 0.003
	"flags" 0x1f
}

reverb "1" {
	"environment" 26
	"environment size" 100
	"environment diffusion" 0.5
	"room" -1000
	"room hf" -500
	"decay time" 10.05
	"decay hf ratio" 0.23
	"reflections" -1200
	"reflections delay" 0.02
	"reflections pan" 0 0 -1
	"reverb" -1000
	"reverb delay" 0.03
	"reverb pan" 0 1 0
	"air absorption hf" -5
	"flags" 0x3f
}
'''


def main():
    add('script/doom_main.script', DOOM_MAIN_SCRIPT)
    add('models/md5/cameras/test_flyby.md5camera', md5camera_text())
    add('maps/testmap.script', MAP_SCRIPT)
    floor_textures()
    wall_textures()
    metal_textures()
    ceiling_and_glow_textures()
    stage_images()
    add('maps/testmap.proc', proc_text())
    add('maps/testmap.map', map_text())
    add('maps/testmap.cm', cm_text())
    add('maps/testmap.aas48', aas_text())
    add('efxs/testmap.efx', EFX)
    add('materials/test.mtr', MATERIALS)
    add('def/test.def', DEFS)
    add('sound/test.sndshd', SOUNDS)
    add('particles/test.prt', PARTICLES)
    add('fx/test.fx', FX)
    particle_textures()
    add('models/md5/test/blob.md5mesh', md5mesh_text())
    add('models/md5/test/player.md5mesh', md5mesh_text('models/test/player', PLAYER_BOXES))
    add('af/test_creatures.af', '// Castle Doom 3 test articulated figures (generated by tools/make_test_pk4.py)\n\n' +
        af_text('test_blob', 'test_blob', BLOB_BOXES) + '\n' + af_text('test_player', 'model_test_player', PLAYER_BOXES))
    add('skins/test_player.skin', SKINS)
    barrel_texture()
    light_images()
    sky_and_screen_images()
    gui_assets()
    add('models/mapobjects/test/barrel.lwo', barrel_lwo())
    add('models/mapobjects/test/terminal.ase', terminal_ase())
    add('models/items/test/box.lwo', box_lwo(16, 16, 10))
    add('models/weapons/test/brass.lwo', brass_lwo())
    add('models/weapons/test/brass_d.tga', tga(8, 8, [[(0.85, 0.65 - 0.05 * (x % 2), 0.25)] * 8 for x in range(8)]))
    add('models/items/test/weapon.lwo', box_lwo(32, 8, 8))
    add('models/md5/test/blob_idle.md5anim', md5anim_text('idle'))
    add('models/md5/test/blob_walk.md5anim', md5anim_text('walk'))
    add('models/md5/test/blob_evade.md5anim', md5anim_text('evade'))
    add('models/md5/test/blob_pain.md5anim', md5anim_text('pain'))
    add('models/items/test/gib.lwo', box_lwo(6, 6, 6))
    for kind in ('crouch', 'crouch_walk', 'crouch_down', 'crouch_up', 'death'):
        add('models/md5/test/player_%s.md5anim' % kind, md5anim_text(kind))
    weapon_models()
    sounds()
    add('readme_castle_doom3_test.txt',
        'Castle Doom 3 test data, generated by tools/make_test_pk4.py. MIT license.\n')
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with zipfile.ZipFile(OUT, 'w', zipfile.ZIP_DEFLATED) as z:
        for path in sorted(files):
            info = zipfile.ZipInfo(path, date_time=(2026, 10, 10, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, files[path])
    print('Wrote %s (%d files, %d bytes)' % (os.path.normpath(OUT), len(files), os.path.getsize(OUT)))


if __name__ == '__main__':
    main()
