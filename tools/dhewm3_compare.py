"""Compare castle-doom3 screenshots with dhewm3's of the same views.

  python tools/dhewm3_compare.py cfg <our map log> <out.cfg> [--wait N] [--every K]
      writes a dhewm3 console script that puts the eye where each of our
      screenshots was taken ("Screenshot ... eye x y z, yaw a" log lines),
      waits and takes a screenshot there, then quits. Copy it to
      <fs_savepath>\\base and run dhewm3 with +map <map> +exec <out.cfg>.
  python tools/dhewm3_compare.py compare <our map log> <dhewm3 screenshot dir> <out.jpg>
      pairs our screenshots with dhewm3's (in order, the same --every),
      prints each pair's mean luma and writes a sheet: ours left, dhewm3 right.

dhewm3's "wait" counts frames; "setviewpos x y z yaw" takes the eye height.
God mode, noclip and notarget keep the reference views still.
"""
import re
import sys
import os
import glob

SHOT = re.compile(r'Screenshot "([^"]+)" \(([\d.]+) FPS, eye (\S+) (\S+) (\S+), yaw (\S+),')


def shots(log, every):
    result = []
    with open(log, encoding='utf-8', errors='replace') as f:
        for line in f:
            m = SHOT.search(line)
            if m:
                result.append((m.group(1), float(m.group(2)), float(m.group(3)), float(m.group(4)),
                               float(m.group(5)), float(m.group(6))))
    return result[::every]


def option(args, name, default):
    if name in args:
        i = args.index(name)
        value = args[i + 1]
        del args[i:i + 2]
        return int(value)
    return default


def write_cfg(args):
    wait = option(args, '--wait', 600)
    every = option(args, '--every', 1)
    log, out = args
    lines = ['// reference views for castle-doom3 (tools/dhewm3_compare.py)',
             'wait %d' % wait, 'god', 'notarget', 'noclip', 'g_showHud 0', 'r_screenshotFormat 2']
    for path, fps, x, y, z, yaw in shots(log, every):
        lines += ['setviewpos %.1f %.1f %.1f %.0f' % (x, y, z, yaw), 'wait 90', 'screenshot']
    lines += ['quit', '']
    with open(out, 'w', newline='\n') as f:
        f.write('\n'.join(lines))
    print('%s: %d views' % (out, (len(lines) - 8) // 3))


def luma(im):
    g = im.convert('L')
    h = g.histogram()
    return sum(i * n for i, n in enumerate(h)) / max(1, sum(h))


def compare(args):
    from PIL import Image, ImageDraw
    every = option(args, '--every', 1)
    log, refdir, out = args
    ours = shots(log, every)
    refs = sorted(glob.glob(os.path.join(refdir, 'shot*.png')) + glob.glob(os.path.join(refdir, 'shot*.tga')))
    n = min(len(ours), len(refs))
    w, h = 400, 225
    sheet = Image.new('RGB', (2 * w, n * h), (0, 0, 0))
    draw = ImageDraw.Draw(sheet)
    for i in range(n):
        path, fps, x, y, z, yaw = ours[i]
        a = Image.open(path).convert('RGB')
        b = Image.open(refs[i]).convert('RGB')
        la, lb = luma(a), luma(b)
        print('%2d  ours %5.1f  dhewm3 %5.1f  (%+5.1f%%)  eye %.0f %.0f %.0f yaw %.0f  %s' % (
            i + 1, la, lb, 100 * (la - lb) / max(1, lb), x, y, z, yaw, os.path.basename(path)))
        sheet.paste(a.resize((w, h)), (0, i * h))
        sheet.paste(b.resize((w, h)), (w, i * h))
        draw.text((4, i * h + 4), '%d ours %.0f' % (i + 1, la), fill=(255, 255, 0))
        draw.text((w + 4, i * h + 4), 'dhewm3 %.0f' % lb, fill=(255, 255, 0))
    sheet.save(out, quality=85)
    print('%s: %d pairs' % (out, n))


if __name__ == '__main__':
    if len(sys.argv) < 2 or sys.argv[1] not in ('cfg', 'compare'):
        print(__doc__)
        sys.exit(1)
    (write_cfg if sys.argv[1] == 'cfg' else compare)(sys.argv[2:])
