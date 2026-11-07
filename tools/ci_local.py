"""Run CI's autotest step (.github/workflows/build.yml, "Run autotest
scripts") here on Windows: the same run_test calls and log checks, with the
game's log file (%LOCALAPPDATA%/castle-doom3/castle-doom3.log) copied to
test_output/<name>.log after each run (on Windows the game doesn't write
its log to stdout).

    python tools/ci_local.py [name ...]

With names, only those run_test calls run (and the checks after them).
Set CD3_LIMIT_FPS=3 for CI's software rendering speed.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def step_script():
    lines = open(os.path.join(ROOT, '.github/workflows/build.yml'), encoding='utf-8').read().splitlines()
    start = next(i for i, l in enumerate(lines) if 'name: Run autotest scripts' in l)
    # the run: | block, up to the next step
    body = []
    indent = None
    for l in lines[start + 2:]:
        if l.strip().startswith('- name:') and indent is not None and len(l) - len(l.lstrip()) < indent:
            break
        if l.strip() == '':
            body.append('')
            continue
        if indent is None:
            indent = len(l) - len(l.lstrip())
        if len(l) - len(l.lstrip()) < indent:
            break
        body.append(l[indent:])
    return body


def main():
    only = set(sys.argv[1:])
    log = os.path.join(os.environ['LOCALAPPDATA'], 'castle-doom3', 'castle-doom3.log').replace('\\', '/')
    out = []
    skipping = False
    for l in step_script():
        m = re.match(r'\s*run_test (\S+) ', l)
        if m:
            skipping = bool(only) and m.group(1) not in only
        if skipping and not l.lstrip().startswith('run_test() {'):
            continue
        if 'xvfb-run' in l:
            l = ('            timeout 600 ./castle-doom3.exe --autotest "$map" "test_output/$name" --demo "$demo" || status=$?\n'
                 '            cp "%s" "test_output/$name.log"' % log)
        out.append(l)
    script = '\n'.join(out) + '\necho "CI autotests passed"\n'
    path = os.path.join(ROOT, 'test_output', 'ci_local.sh')
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', newline='\n') as f:
        f.write(script)
    # Git Bash (a plain "bash" from Python on Windows may be WSL's)
    bash = os.environ.get('CD3_BASH', r'C:\Program Files\Git\bin\bash.exe')
    if not os.path.exists(bash):
        bash = 'bash'
    sys.exit(subprocess.call([bash, 'test_output/ci_local.sh'], cwd=ROOT))


if __name__ == '__main__':
    main()
