"""Callers of a function in samples.txt: the stacks (a few frames) leading
to samples whose frames contain PATTERN (a substring of a resolved name).

    python tools/sample_callers.py PATTERN [samples.txt] [linker map] [depth]
"""
import bisect
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import resolve_samples  # noqa: E402


def main():
    pattern = sys.argv[1]
    samples = sys.argv[2] if len(sys.argv) > 2 else 'samples.txt'
    map_path = sys.argv[3] if len(sys.argv) > 3 else 'castle-engine-output/standalone/castle_doom3_standalone.map'
    depth = int(sys.argv[4]) if len(sys.argv) > 4 else 6
    addrs, names = resolve_samples.load_map(map_path)

    def nm(t):
        if t.startswith('['):
            return t
        i = bisect.bisect_right(addrs, int(t, 16)) - 1
        return names[i] if i >= 0 else '?'

    stacks = collections.Counter()
    total = 0
    for line in open(samples):
        if line.startswith('#'):
            continue
        frames = [nm(t) for t in line.split()]
        hits = [i for i, f in enumerate(frames) if pattern in f]
        if not hits:
            continue
        total += 1
        i = hits[-1]
        stacks[' < '.join(frames[i:i + depth])] += 1
    print('%d samples with %s' % (total, pattern))
    for k, v in stacks.most_common(15):
        print('%6d  %s' % (v, k))


if __name__ == '__main__':
    main()
