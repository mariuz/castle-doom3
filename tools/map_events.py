"""The scripted events of a route playthrough, per map, against a baseline.

A route playthrough (tools/tour_maps.ps1 -Route) logs what the maps' scripts
and entities do. This tool takes the events that tell a map was played as
intended out of the logs and compares a run with a baseline run, so a change
that breaks a map's script shows as missing events, not only as a map that
didn't reach the next one (roadmap "After the playthroughs", item 8).

Events (the log line's kind and name; numbers in names are kept):
  next        Loading map "<next map>"         the level's end
  objective   New objective / Objective complete: <title>
  cinematic   Cinematic camera <name>          a cinematic played (or skipped)
  elevator    Elevator <name> at floor <n>     an elevator arrived
  gui         GUI <file> (<entity>) triggered  a GUI's button or script ran
  camera      Security camera <name> alerts
  boss        Killed <name> (monster_boss_...)  a boss died (fighting runs)
  kill        Killed <name> (<class>, ...)      a monster died (fighting runs)
  trigger     Trigger <name> fired
  script      Script: <print>                  the map script's prints

next, objective, cinematic, elevator and boss are the "key" events: missing
ones are listed by name; the others are counted. Kills come from fighting
runs (tools/tour_maps.ps1 -Route -Fight); a god mode route kills nothing,
so check it against a baseline of its own kind.

  python tools/map_events.py baseline <run dir> <baseline.json>
  python tools/map_events.py check <run dir> <baseline.json> [<out.md>]
  python tools/map_events.py diff <run dir A> <run dir B>

<run dir> holds the tour's <map>.log files (game_mars_city1.log ...). The
baselines are in docs/baselines/ (the 2004 game, Resurrection of Evil and the
BFG edition); check prints a table and writes it as Markdown when asked.
"""

import json
import os
import re
import sys

KEY_KINDS = ['next', 'objective', 'cinematic', 'elevator', 'boss']
KINDS = KEY_KINDS + ['gui', 'camera', 'trigger', 'script', 'kill']

PATTERNS = [
    ('objective', re.compile(r'Doom3World: (?:New objective|Objective complete): ([^(]*?)\s*(?:\(|$)')),
    ('cinematic', re.compile(r'Doom3World: Cinematic camera (\S+)$')),
    ('elevator', re.compile(r'Doom3World: Elevator (\S+ at floor \S+)$')),
    ('gui', re.compile(r'Doom3World: GUI (\S+ \(\S+\)) triggered')),
    ('camera', re.compile(r'Doom3World: Security camera (\S+) alerts')),
    ('trigger', re.compile(r'Doom3World: Trigger (\S+) fired')),
    ('boss', re.compile(r'Doom3World: Killed (\S+) \(monster_boss_')),
    ('kill', re.compile(r'Doom3World: Killed (\S+) \(')),
    ('script', re.compile(r'^Script: (?!Not supported)(?!Event ")(.+)$')),
]
LOADING = re.compile(r'GameViewPlay: Loading map "([^"]+)"')


def map_name(log_name):
    """game_mars_city1.log -> game/mars_city1"""
    base = os.path.splitext(os.path.basename(log_name))[0]
    if '_' not in base:
        return base
    first, rest = base.split('_', 1)
    return first + '/' + rest


def events_of(path):
    """The events of one map's log: {kind: sorted names}."""
    found = {k: set() for k in KINDS}
    loads = []
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.rstrip('\r\n')
            m = LOADING.search(line)
            if m:
                loads.append(m.group(1))
                continue
            for kind, rx in PATTERNS:
                m = rx.search(line)
                if m:
                    found[kind].add(m.group(1).strip())
                    break
    # the first load is the map itself, the first other map its end (a
    # fighting run loads the same map again from a save after a death)
    for name in loads[1:]:
        if loads and name != loads[0]:
            found['next'].add(name)
            break
    return {k: sorted(v) for k, v in found.items()}


def run_events(run_dir):
    result = {}
    for name in sorted(os.listdir(run_dir)):
        if name.endswith('.log'):
            result[map_name(name)] = events_of(os.path.join(run_dir, name))
    return result


def compare(base, run):
    """Per kind: (baseline count, how many of them the run has, missing)."""
    out = {}
    for kind in KINDS:
        b = set(base.get(kind, []))
        r = set(run.get(kind, []))
        out[kind] = (len(b), len(b & r), sorted(b - r))
    return out


def check(run_dir, baseline_path, out_path=None):
    with open(baseline_path, encoding='utf-8') as f:
        baseline = json.load(f)
    run = run_events(run_dir)
    lines = ['| Map | Events | ' + ' | '.join(KINDS) + ' | Missing key events |',
             '|---|---|' + '---|' * len(KINDS) + '---|']
    total_b = total_r = 0
    failed = []
    for m in sorted(run):
        if m not in baseline:
            lines.append('| `%s` | no baseline |' % m + ' |' * (len(KINDS) + 1))
            continue
        c = compare(baseline[m], run[m])
        b = sum(v[0] for v in c.values())
        r = sum(v[1] for v in c.values())
        total_b += b
        total_r += r
        cells = ['%d/%d' % (c[k][1], c[k][0]) if c[k][0] else '-' for k in KINDS]
        missing = ['%s %s' % (k, n) for k in KEY_KINDS for n in c[k][2]]
        if missing:
            failed.append(m)
        lines.append('| `%s` | %d of %d | %s | %s |' % (
            m, r, b, ' | '.join(cells), '; '.join(missing) if missing else ''))
    lines.append('')
    lines.append('%d of %d baseline events in %d maps; %d maps miss key events%s' % (
        total_r, total_b, len(run), len(failed), (': ' + ', '.join(failed)) if failed else ''))
    text = '\n'.join(lines)
    print(text)
    if out_path:
        with open(out_path, 'w', encoding='utf-8') as f:
            f.write(text + '\n')
    return 1 if failed else 0


def diff(dir_a, dir_b):
    a = run_events(dir_a)
    b = run_events(dir_b)
    for m in sorted(set(a) & set(b)):
        for kind in KINDS:
            only_a = sorted(set(a[m][kind]) - set(b[m][kind]))
            only_b = sorted(set(b[m][kind]) - set(a[m][kind]))
            if only_a or only_b:
                print('%s %s: only in A %s; only in B %s' % (m, kind, only_a[:8], only_b[:8]))


def main(argv):
    if len(argv) >= 3 and argv[0] == 'baseline':
        events = run_events(argv[1])
        os.makedirs(os.path.dirname(os.path.abspath(argv[2])), exist_ok=True)
        with open(argv[2], 'w', encoding='utf-8') as f:
            json.dump(events, f, indent=1, sort_keys=True)
            f.write('\n')
        print('%d maps, %d events' % (len(events), sum(len(v) for e in events.values() for v in e.values())))
        return 0
    if len(argv) >= 3 and argv[0] == 'check':
        return check(argv[1], argv[2], argv[3] if len(argv) > 3 else None)
    if len(argv) >= 3 and argv[0] == 'diff':
        diff(argv[1], argv[2])
        return 0
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
