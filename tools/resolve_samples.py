"""Resolve the sampling profiler's samples.txt into function names.

The game writes samples.txt next to the executable when run with the
environment variable CD3_SAMPLE set (see code/doom3sampler.pas): one line per
sample, the innermost address first, as hex offsets in the executable or
[module] names. This maps the offsets to functions with the linker map
(build with: castle-engine compile --mode=release --compiler-option=-Xm) and
prints where the samples are, exclusive (innermost) and inclusive (anywhere
on the stack).

    python tools/resolve_samples.py [samples.txt] [linker map] [count]
"""
import bisect
import collections
import re
import sys

IMAGE_BASE = 0x100000000  # FPC's default for Win64


def pretty(sym):
    # UNIT$_$CLASS_$__$$_METHOD$ARGS -> CLASS.METHOD, UNIT_$$_PROC$ARGS -> UNIT.PROC
    m = re.match(r'([^$]+)\$_\$(.+?)_\$__\$\$_([^$]+)', sym)
    if m:
        return '%s.%s' % (m.group(2).replace('_$_', '.'), m.group(3))
    m = re.match(r'([^$]+)_\$\$_([^$]+)', sym)
    if m:
        return '%s.%s' % (m.group(1), m.group(2))
    return sym


def load_map(path):
    text_start = text_end = None
    addrs, names = [], []
    sym = re.compile(r'^\s+0x([0-9a-fA-F]{16})\s+([^\s].*)$')
    with open(path, encoding='latin1') as f:
        for line in f:
            if text_start is None and line.startswith('.text '):
                parts = line.split()
                text_start = int(parts[1], 16)
                text_end = text_start + int(parts[2], 16)
                continue
            m = sym.match(line)
            if not m:
                continue
            a = int(m.group(1), 16)
            name = m.group(2).strip()
            if name.startswith('$') or (text_start is not None and not (text_start <= a < text_end)):
                continue
            addrs.append(a - IMAGE_BASE)
            names.append(pretty(name))
    order = sorted(range(len(addrs)), key=addrs.__getitem__)
    return [addrs[i] for i in order], [names[i] for i in order]


def main():
    samples_path = sys.argv[1] if len(sys.argv) > 1 else 'samples.txt'
    map_path = sys.argv[2] if len(sys.argv) > 2 else 'castle-engine-output/standalone/castle_doom3_standalone.map'
    top = int(sys.argv[3]) if len(sys.argv) > 3 else 50
    addrs, names = load_map(map_path)
    cache = {}

    def name_of(token):
        if token.startswith('['):
            return token
        if token not in cache:
            off = int(token, 16)
            i = bisect.bisect_right(addrs, off) - 1
            cache[token] = names[i] if i >= 0 else '?'
        return cache[token]

    exclusive, inclusive = collections.Counter(), collections.Counter()
    total = 0
    with open(samples_path) as f:
        for line in f:
            if line.startswith('#'):
                print(line.strip())
                continue
            tokens = line.split()
            if not tokens:
                continue
            total += 1
            frames = [name_of(t) for t in tokens]
            exclusive[frames[0]] += 1
            for n in set(frames):
                inclusive[n] += 1
    for title, counter in (('Exclusive (innermost)', exclusive), ('Inclusive', inclusive)):
        print('\n%s:' % title)
        for n, c in counter.most_common(top):
            print('%7d %5.1f%%  %s' % (c, 100.0 * c / max(1, total), n))


if __name__ == '__main__':
    main()
