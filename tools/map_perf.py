"""Per-map performance budgets: a tour's numbers against a baseline run.

tools/tour_maps.ps1 writes <OutDir>/summary.txt with, per map, the load
time, the screenshots' frame rates, the long frames, the stalls over 0.3 s
and the shader programs linked. This tool keeps them as a baseline and
flags a map whose numbers got worse by more than the margins (roadmap
"After the playthroughs", item 9), so a regression shows as a difference
between runs:

  load      the map's load (Map "...": N s) more than 30% and 2 s slower
  fps       the median FPS more than 15% lower
  stalls    more than 3 stalls over 0.3 s more, and more than twice as many
  programs  more than 25% and 50 more shader programs during the tour

Frame rates on this machine vary between runs (other programs on the GPU,
its clock) and are capped at 60 by vertical sync since playthrough12b; a
first play on a new exe name or after a driver update compiles every shader
(stalls): compare runs made the same way.

  python tools/map_perf.py baseline <run dir> <baseline.json>
  python tools/map_perf.py check <run dir> <baseline.json> [<out.md>]
"""

import json
import os
import re
import sys

LOAD = re.compile(r'^Map "([^"]+)": ([\d.]+) s')
FPS = re.compile(r'^FPS: min ([\d.]+), median ([\d.]+), max ([\d.]+) over (\d+) shots')
STALLS = re.compile(r'^Stalls over 0\.3 s: (\d+), ([\d.]+) s')
LONG = re.compile(r'^Long frames: (\d+), ([\d.]+) s in all')
PROGRAMS = re.compile(r'^Shader programs: (\d+) at the first screenshot, (-?\d+) more during the tour')
HEADER = re.compile(r'^== (\S+) \(([^)]*)\)')


def parse(summary_path):
    """{map: {load, fps_median, fps_min, shots, stalls, stall_s, long, programs_first, programs_tour, exit}}"""
    maps = {}
    cur = None
    with open(summary_path, encoding='utf-8-sig', errors='replace') as f:
        for line in f:
            line = line.rstrip('\r\n')
            m = HEADER.match(line)
            if m:
                cur = maps.setdefault(m.group(1), {'exit': m.group(2)})
                continue
            if cur is None:
                continue
            m = LOAD.match(line)
            if m and 'load' not in cur:
                cur['load'] = float(m.group(2))
            m = FPS.match(line)
            if m:
                cur['fps_min'] = float(m.group(1))
                cur['fps_median'] = float(m.group(2))
                cur['shots'] = int(m.group(4))
            m = STALLS.match(line)
            if m:
                cur['stalls'] = int(m.group(1))
                cur['stall_s'] = float(m.group(2))
            m = LONG.match(line)
            if m:
                cur['long'] = int(m.group(1))
            m = PROGRAMS.match(line)
            if m:
                cur['programs_first'] = int(m.group(1))
                cur['programs_tour'] = int(m.group(2))
    return maps


def regressions(base, run):
    """Reasons a map's run is worse than its baseline (empty: within budget)."""
    out = []
    if 'load' in base and 'load' in run and run['load'] > base['load'] * 1.3 and run['load'] - base['load'] > 2:
        out.append('load %.1f s (was %.1f)' % (run['load'], base['load']))
    # runs are capped at 60 FPS by vertical sync (older baselines weren't)
    if 'fps_median' in base and 'fps_median' in run and run['fps_median'] < min(60, base['fps_median']) * 0.85:
        out.append('median FPS %.1f (was %.1f)' % (run['fps_median'], base['fps_median']))
    if 'stalls' in base and 'stalls' in run and run['stalls'] > base['stalls'] + 3 and run['stalls'] > base['stalls'] * 2:
        out.append('%d stalls (was %d)' % (run['stalls'], base['stalls']))
    if 'programs_tour' in base and 'programs_tour' in run and \
            run['programs_tour'] > base['programs_tour'] * 1.25 and run['programs_tour'] - base['programs_tour'] > 50:
        out.append('%d programs during the tour (was %d)' % (run['programs_tour'], base['programs_tour']))
    if base.get('exit') == 'exit 0' and run.get('exit') not in (None, 'exit 0'):
        out.append('ended with %s (was exit 0)' % run.get('exit'))
    return out


def fmt(v, key, digits=1):
    if key not in v:
        return '-'
    x = v[key]
    return ('%.' + str(digits) + 'f') % x if isinstance(x, float) else str(x)


def check(run_dir, baseline_path, out_path=None):
    with open(baseline_path, encoding='utf-8') as f:
        baseline = json.load(f)
    run = parse(os.path.join(run_dir, 'summary.txt'))
    lines = ['| Map | Load s | Median FPS | Stalls | Programs (tour) | Over budget |', '|---|---|---|---|---|---|']
    over = []
    for m in sorted(run):
        r = run[m]
        b = baseline.get(m)
        if b is None:
            lines.append('| `%s` | %s | %s | %s | %s | no baseline |' % (
                m, fmt(r, 'load'), fmt(r, 'fps_median'), fmt(r, 'stalls', 0), fmt(r, 'programs_tour', 0)))
            continue
        reasons = regressions(b, r)
        if reasons:
            over.append(m)
        lines.append('| `%s` | %s (%s) | %s (%s) | %s (%s) | %s (%s) | %s |' % (
            m, fmt(r, 'load'), fmt(b, 'load'), fmt(r, 'fps_median'), fmt(b, 'fps_median'),
            fmt(r, 'stalls', 0), fmt(b, 'stalls', 0), fmt(r, 'programs_tour', 0), fmt(b, 'programs_tour', 0),
            '; '.join(reasons)))
    lines.append('')
    lines.append('%d maps, %d over budget%s (the baseline in parentheses)' % (
        len(run), len(over), (': ' + ', '.join(over)) if over else ''))
    text = '\n'.join(lines)
    print(text)
    if out_path:
        with open(out_path, 'w', encoding='utf-8') as f:
            f.write(text + '\n')
    return 1 if over else 0


def main(argv):
    if len(argv) >= 3 and argv[0] == 'baseline':
        maps = parse(os.path.join(argv[1], 'summary.txt'))
        os.makedirs(os.path.dirname(os.path.abspath(argv[2])), exist_ok=True)
        with open(argv[2], 'w', encoding='utf-8') as f:
            json.dump(maps, f, indent=1, sort_keys=True)
            f.write('\n')
        print('%d maps' % len(maps))
        return 0
    if len(argv) >= 3 and argv[0] == 'check':
        return check(argv[1], argv[2], argv[3] if len(argv) > 3 else None)
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
