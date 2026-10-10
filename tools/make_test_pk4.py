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
    rows = []
    for y in range(n):
        row = []
        for x in range(n):
            line = 0.55 if (y // 2) % 2 else 1.0
            bar = 1.0 if 20 < (x + y // 3) % 40 < 34 else 0.35
            row.append((0.2 * line * bar, 0.9 * line * bar, 0.5 * line * bar))
        rows.append(row)
    add('textures/test/screen.tga', tga(n, n, rows))


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


def wall_rect(model, mat, axis, coord, normal_sign, u0, u1, v0, v1):
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
    model.surf(mat).quad(pts, normal, uv)


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


FLOOR = 'textures/test/floor'
WALL = 'textures/test/wall'
CEIL = 'textures/test/ceiling'
METAL = 'textures/test/metal'
GLOW = 'textures/test/lightpanel'

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
box(area0, METAL, (-176, 136, 0), (-136, 176, 192))

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
for (cx, cy) in ((448, -192), (448, 192), (640, 250)):
    wall_rect(area1, GLOW, 'z', 287, -1, cx - 32, cx + 32, cy - 32, cy + 32)
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
box(door, METAL, (-4, -48, -56), (4, 48, 56))
crate = Model('crate_1')
box(crate, METAL, (-32, -32, -32), (32, 32, 32))
crate2 = Model('crate_2')
box(crate2, METAL, (-24, -24, -24), (24, 24, 24))
spinner = Model('spinner_1')
box(spinner, {'*': METAL}, (-64, -6, -6), (64, 6, 6))
box(spinner, {'*': METAL}, (-6, -64, -6), (6, 64, 6))


def fmt(v):
    s = '%.6f' % v
    s = s.rstrip('0').rstrip('.')
    return s if s not in ('-0', '') else '0'


def proc_text():
    out = ['mapProcFile003', '']
    for m in (area0, area1, door, crate, crate2, spinner):
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
    out = ['CM "1.00"', '', '1234567890', '']
    out.append(cm_model('worldMap', world, brushes))
    for m in (door, crate, crate2, spinner):
        out.append(cm_model(m.name, list(quads_of(m)), []))
    return '\n'.join(out) + '\n'


# --------------------------------------------------------------------------
# Entities (.map)

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
         'snd_open': 'test_door', 'snd_close': 'test_door'},
        {'classname': 'func_static', 'name': 'crate_1', 'model': 'crate_1',
         'origin': '128 -160 32', 'angle': '20'},
        {'classname': 'func_static', 'name': 'crate_2', 'model': 'crate_2',
         'origin': '136 -150 88', 'angle': '-15'},
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

DEFS = r'''
// Castle Doom 3 test entity definitions (generated by tools/make_test_pk4.py)

model test_blob {
	mesh					models/md5/test/blob.md5mesh
	channel torso			( *body )
	anim idle				models/md5/test/blob_idle.md5anim
	anim walk				models/md5/test/blob_walk.md5anim {
		frame 6				sound_body snd_footstep
	}
}

entityDef monster_default {
	"editor_color"			"1 .5 0"
	"spawnclass"			"idAI"
	"health"				"50"
	"size"					"32 32 72"
}

entityDef monster_test_blob {
	"inherit"				"monster_default"
	"editor_usage"			"A test creature for Castle Doom 3."
	"model"					"test_blob"
	"health"				"80"
	"snd_footstep"			"test_step"
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


def md5mesh_text():
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

    add_box(1, (-14, -18, 24), (14, 18, 66))      # body
    add_box(2, (-10, -10, 66), (12, 10, 88))      # head
    add_box(3, (-5, 18, 30), (5, 26, 64))         # left arm
    add_box(4, (-5, -26, 30), (5, -18, 64))       # right arm
    add_box(5, (-6, 4, 0), (6, 16, 26))           # left leg
    add_box(6, (-6, -16, 0), (6, -4, 26))         # right leg

    out = ['MD5Version 10', 'commandline "generated by tools/make_test_pk4.py"', '',
           'numJoints %d' % len(JOINTS), 'numMeshes 1', '', 'joints {']
    for name, parent, p in JOINTS:
        out.append('\t"%s"\t%d ( %s %s %s ) ( 0 0 0 )\t\t// %s' % (
            name, parent, fmt(p[0]), fmt(p[1]), fmt(p[2]), JOINTS[parent][0] if parent >= 0 else ''))
    out += ['}', '', 'mesh {', '\t// meshes: body', '\tshader "models/test/blob"', '',
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


def quat_xyz(axis, angle):
    """Doom 3 stores x y z of a unit quaternion whose w is negative."""
    s = math.sin(angle / 2)
    q = [axis[0] * s, axis[1] * s, axis[2] * s, math.cos(angle / 2)]
    if q[3] > 0:
        q = [-v for v in q]
    return q[:3]


def md5anim_text(kind):
    frames, rate = 48, 24
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
    the corners counter-clockwise seen from the front in Doom 3 space (which
    is LightWave's clockwise after the y/z swap); uvs: per point (u, v);
    vmad: (point, poly, (u, v)) overrides."""
    tags = b''.join(lwo_str(n) for n in surfaces)
    layr = struct.pack('>HH', 0, 0) + struct.pack('>fff', 0, 0, 0) + lwo_str('test')
    # Doom 3 reads LightWave points as (x, z, y)
    pnts = b''.join(struct.pack('>fff', p[0], p[2], p[1]) for p in points)
    vmap = b'TXUV' + struct.pack('>H', 2) + lwo_str('txuv') + b''.join(
        lwo_vx(i) + struct.pack('>ff', u, v) for i, (u, v) in enumerate(uvs))
    pols = b'FACE' + b''.join(struct.pack('>H', len(vs)) + b''.join(lwo_vx(v) for v in vs)
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


def main():
    floor_textures()
    wall_textures()
    metal_textures()
    ceiling_and_glow_textures()
    add('maps/testmap.proc', proc_text())
    add('maps/testmap.map', map_text())
    add('maps/testmap.cm', cm_text())
    add('materials/test.mtr', MATERIALS)
    add('def/test.def', DEFS)
    add('sound/test.sndshd', SOUNDS)
    add('models/md5/test/blob.md5mesh', md5mesh_text())
    barrel_texture()
    light_images()
    sky_and_screen_images()
    add('models/mapobjects/test/barrel.lwo', barrel_lwo())
    add('models/mapobjects/test/terminal.ase', terminal_ase())
    add('models/md5/test/blob_idle.md5anim', md5anim_text('idle'))
    add('models/md5/test/blob_walk.md5anim', md5anim_text('walk'))
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
