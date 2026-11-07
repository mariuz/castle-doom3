"""GPU time per draw of a RenderDoc capture of castle-doom3, grouped by
render state (to tell the stencil shadow passes, the light passes and the
plain scene apart).

Capture a frame with the game started by RenderDoc (OpenGL core profile:
--capabilities=force-modern) and the console command "renderdoc" (or
O:renderdoc in a demo script):

  renderdoccmd capture -w -c F:\\TMP\\rdc\\cap castle-doom3.exe --capabilities=force-modern
      -basepath <Doom 3> --autotest <map> <prefix> --demo "...,O:renderdoc,W:2,Q"

then run this inside RenderDoc's UI process (it has the replay module):

  qrenderdoc --python tools\\renderdoc_report.py

with the environment variables RDC_CAPTURE (the .rdc file) and RDC_REPORT
(the text file to write). It quits RenderDoc when done.
"""
import collections
import os
import traceback

CAPTURE = os.environ.get('RDC_CAPTURE', '')
REPORT = os.environ.get('RDC_REPORT', 'renderdoc_report.txt')

try:
    import renderdoc as rd
except Exception:
    with open(REPORT, 'w') as f:
        f.write('import renderdoc failed: ' + traceback.format_exc())
    os._exit(1)


def main(out):
    cap = rd.OpenCaptureFile()
    result = cap.OpenFile(CAPTURE, '', None)
    if result != rd.ResultCode.Succeeded:
        out.write('Cannot open %s: %s\n' % (CAPTURE, result))
        return
    result, ctrl = cap.OpenCapture(rd.ReplayOptions(), None)
    if result != rd.ResultCode.Succeeded:
        out.write('Cannot replay %s: %s\n' % (CAPTURE, result))
        return
    sfile = ctrl.GetStructuredFile()
    counters = ctrl.EnumerateCounters()
    if rd.GPUCounter.EventGPUDuration not in counters:
        out.write('No GPU duration counter on this replay\n')
        return
    durations = {r.eventId: r.value.d for r in ctrl.FetchCounters([rd.GPUCounter.EventGPUDuration])}

    draws = []

    def walk(actions):
        for a in actions:
            if a.children:
                walk(a.children)
            else:
                draws.append(a)

    walk(ctrl.GetRootActions())
    total = sum(durations.get(a.eventId, 0) for a in draws)
    out.write('Capture %s\n' % CAPTURE)
    out.write('%d actions, GPU time %.2f ms\n\n' % (len(draws), total * 1000))

    # the render state of each draw: blending, depth function and writes,
    # stencil, color writes (one replay step per draw)
    groups = collections.defaultdict(lambda: [0, 0.0, 0])
    programs = collections.defaultdict(lambda: [0, 0.0])
    top = []
    for a in draws:
        d = durations.get(a.eventId, 0)
        name = a.GetName(sfile)
        if not (a.flags & rd.ActionFlags.Drawcall):
            key = 'non-draw: ' + name.split('(')[0]
            g = groups[key]
            g[0] += 1
            g[1] += d
            continue
        ctrl.SetFrameEvent(a.eventId, False)
        gl = ctrl.GetGLPipelineState()
        blend = gl.framebuffer.blendState.blends[0] if len(gl.framebuffer.blendState.blends) else None
        blending = 'blend %s/%s' % (blend.colorBlend.source, blend.colorBlend.destination) if blend and blend.enabled else 'no blend'
        writes = 'color' if blend is None or blend.writeMask != 0 else 'no color'
        depth = 'depth %s%s' % (gl.depthState.depthFunction, ' write' if gl.depthState.depthWrites else '') \
            if gl.depthState.depthEnable else 'no depth'
        stencil = 'stencil' if gl.stencilState.stencilEnable else ''
        key = ', '.join(x for x in [writes, blending, depth, stencil] if x)
        g = groups[key]
        g[0] += 1
        g[1] += d
        g[2] += a.numIndices
        p = programs[str(gl.vertexShader.programResourceId)]
        p[0] += 1
        p[1] += d
        top.append((d, a.eventId, name, a.numIndices, key))

    out.write('By render state (draws, GPU ms, indices):\n')
    for key, (n, d, idx) in sorted(groups.items(), key=lambda kv: -kv[1][1]):
        out.write('%8.2f ms %6d draws %9d indices  %s\n' % (d * 1000, n, idx, key))
    out.write('\nBy shader program (draws, GPU ms), top 15:\n')
    for key, (n, d) in sorted(programs.items(), key=lambda kv: -kv[1][1])[:15]:
        out.write('%8.2f ms %6d draws  program %s\n' % (d * 1000, n, key))
    out.write('\nSlowest draws:\n')
    for d, eid, name, idx, key in sorted(top, reverse=True)[:25]:
        out.write('%8.3f ms  event %6d  %8d indices  %s  [%s]\n' % (d * 1000, eid, idx, name, key))
    # RDC_DUMP_DIR: the fragment shader source of the 3 slowest draws
    # (<dir>/event<id>.frag), to see what makes them slow (how many lights)
    dump_dir = os.environ.get('RDC_DUMP_DIR', '')
    if dump_dir:
        os.makedirs(dump_dir, exist_ok=True)
        for d, eid, name, idx, key in sorted(top, reverse=True)[:3]:
            ctrl.SetFrameEvent(eid, False)
            refl = ctrl.GetGLPipelineState().fragmentShader.reflection
            if refl is None:
                continue
            path = os.path.join(dump_dir, 'event%d.frag' % eid)
            with open(path, 'wb') as f:
                f.write(bytes(refl.rawBytes))
            out.write('Fragment shader of event %d: %s\n' % (eid, path))
    ctrl.Shutdown()
    cap.Shutdown()


with open(REPORT, 'w') as f:
    try:
        main(f)
    except Exception as e:
        f.write('Error: %s\n%s' % (e, traceback.format_exc()))
os._exit(0)
