"""Compare castle-doom3 screenshots with dhewm3's of the same views.

  python tools/dhewm3_compare.py cfg <our map log> <out.cfg> [--wait N] [--every K]
      writes a dhewm3 console script that puts the eye where each of our
      screenshots was taken ("Screenshot ... eye x y z, yaw a" log lines),
      waits and takes a screenshot there, then quits. Copy it to
      <fs_savepath>\\base and run dhewm3 with +map <map> +exec <out.cfg>.
  python tools/dhewm3_compare.py compare <our map log> <dhewm3 screenshot dir> <out.jpg>
      pairs our screenshots with dhewm3's (in order, the same --every),
      prints each pair's mean luma and image difference (the mean absolute
      difference of the two views in gray, shrunk to 160 x 90, in percent of
      white; under 5 is the same view) and writes a sheet: ours left,
      dhewm3 right.
  python tools/dhewm3_compare.py table <dir with *_compare.txt> <out.md>
      one row per map from those files: the pairs, the median lumas, the
      median luma difference, the pairs within 15% of dhewm3's luma, the
      median image difference and the pairs under 5.

dhewm3's "wait" counts frames; "setviewpos x y z yaw" takes the eye height.
God mode, noclip and notarget keep the reference views still. The bottom 18% of
both views (our HUD and weapon) is left out of the numbers and the sheet.
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
             'wait %d' % wait, 'god', 'notarget', 'noclip', 'g_showHud 0', 'ui_showGun 0', 'r_screenshotFormat 2']
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


def image_diff(a, b):
    from PIL import ImageChops, ImageFilter
    ga = a.convert('L').resize((160, 90)).filter(ImageFilter.GaussianBlur(1))
    gb = b.convert('L').resize((160, 90)).filter(ImageFilter.GaussianBlur(1))
    h = ImageChops.difference(ga, gb).histogram()
    return 100.0 * sum(i * n for i, n in enumerate(h)) / max(1, sum(h)) / 255


def median(values):
    v = sorted(values)
    if not v:
        return 0.0
    m = len(v) // 2
    return v[m] if len(v) % 2 else (v[m - 1] + v[m]) / 2


PAIR = re.compile(r'^\s*\d+\s+ours\s+([\d.]+)\s+dhewm3\s+([\d.]+)\s+\(\s*([-+\d.]+)%\)\s+diff\s+([\d.]+)')


def table(args):
    folder, out = args
    rows = []
    for path in sorted(glob.glob(os.path.join(folder, '*_compare.txt'))):
        ours, refs, rel, diffs = [], [], [], []
        with open(path, encoding='utf-8-sig', errors='replace') as f:
            for line in f:
                m = PAIR.match(line)
                if m:
                    ours.append(float(m.group(1)))
                    refs.append(float(m.group(2)))
                    rel.append(abs(float(m.group(3))))
                    diffs.append(float(m.group(4)))
        if ours:
            rows.append((os.path.basename(path)[:-len('_compare.txt')], ours, refs, rel, diffs))
    lines = ['| Map | Views | Luma here | Luma dhewm3 | Median luma difference | Views within 15% | Median image difference | Views under 5 |',
             '|---|---|---|---|---|---|---|---|']
    all_rel, all_diffs = [], []
    for name, ours, refs, rel, diffs in rows:
        all_rel += rel
        all_diffs += diffs
        lines.append('| %s | %d | %.1f | %.1f | %.0f%% | %d | %.1f | %d |' % (
            name, len(ours), median(ours), median(refs), median(rel),
            sum(1 for r in rel if r <= 15), median(diffs), sum(1 for d in diffs if d < 5)))
    lines.append('| **all** | %d | | | %.0f%% | %d | %.1f | %d |' % (
        len(all_rel), median(all_rel), sum(1 for r in all_rel if r <= 15),
        median(all_diffs), sum(1 for d in all_diffs if d < 5)))
    with open(out, 'w', newline='\n') as f:
        f.write('\n'.join(lines) + '\n')
    print('\n'.join(lines))


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
        # without the bottom 18%: our HUD and weapon (dhewm3's are hidden)
        a = a.crop((0, 0, a.size[0], int(a.size[1] * 0.82)))
        b = b.resize((a.size[0], int(a.size[1] / 0.82 + 0.5))).crop((0, 0, a.size[0], a.size[1]))
        la, lb = luma(a), luma(b)
        print('%2d  ours %5.1f  dhewm3 %5.1f  (%+5.1f%%)  diff %4.1f  eye %.0f %.0f %.0f yaw %.0f  %s' % (
            i + 1, la, lb, 100 * (la - lb) / max(1, lb), image_diff(a, b), x, y, z, yaw, os.path.basename(path)))
        sheet.paste(a.resize((w, h)), (0, i * h))
        sheet.paste(b.resize((w, h)), (w, i * h))
        draw.text((4, i * h + 4), '%d ours %.0f' % (i + 1, la), fill=(255, 255, 0))
        draw.text((w + 4, i * h + 4), 'dhewm3 %.0f' % lb, fill=(255, 255, 0))
    sheet.save(out, quality=85)
    print('%s: %d pairs' % (out, n))


if __name__ == '__main__':
    if len(sys.argv) < 2 or sys.argv[1] not in ('cfg', 'compare', 'table'):
        print(__doc__)
        sys.exit(1)
    {'cfg': write_cfg, 'compare': compare, 'table': table}[sys.argv[1]](sys.argv[2:])
