"""WebGL2 runtime check of the game-owned shader materials (labelle-bgfx#100).

Requires a wasm build (`labelle build --platform=wasm` from the example
directory, with the `web` provider pinned). Serves `zig-out/web`, opens it in
headless Chromium (Playwright) on SwiftShader WebGL2 and proves, per scenario:

* the page really got a WebGL2 context;
* each of the four game-owned programs (water, fog, lamp, mist) compiled,
  LINKED and was used for draw calls: the WebGL API is instrumented, so this is
  the GL driver's own verdict, not a game-side flag;
* the engine reports `2/2 generic materials live` for every material component;
* the rendered pixels carry each effect (every effect-off control changes the
  frame), a repeated run is byte-identical, and the left-only control hook
  leaves the right unit byte-identical;
* a negative control (the harness corrupts the water shader source) is caught
  by the same instrumentation, so its silence elsewhere is meaningful.

The frame loop is stepped by hand (requestAnimationFrame is intercepted) with
`LABELLE_FIXED_DT`, so every capture is frame-exact and repeatable.
With `--native <png>` the default capture must also match a native desktop
capture of the same frame (tools/verify_runtime.py's `default.png`) within a
small tolerance: mean channel error < 1 and under 0.1 % of pixels off by > 32.

    pip install playwright==1.58.0 numpy pillow
    python -m playwright install chromium
    python tools/verify_webgl2.py [--native .test-output/runtime/default.png]
"""
from pathlib import Path
import argparse
import functools
import http.server
import io
import json
import sys
import threading

import numpy as np
from PIL import Image
from playwright.sync_api import Error as PlaywrightError, sync_playwright

ROOT = Path(__file__).resolve().parents[1]
WEB = ROOT / '.labelle/bgfx_wasm/zig-out/web'
OUT = ROOT / '.test-output/webgl2'
W, H = 1236, 330
CAPTURE_FRAME = 120  # two seconds at the fixed 1/60 s step, like verify_runtime.py
INSTANCES = 2  # two condenser units, one instance of each material per unit

# A uniform that only that material's fragment shader declares.
PROGRAM_MARKERS = {
    'water': 'u_water_head',
    'fog': 'u_fog_motion',
    'lamp': 's_lamp_mask',
    'mist': 'u_mist_bounds',
}
COMPONENTS = ['water_shader.WaterShader', 'fog_shader.FogShader',
              'lamp_shader.LampShader', 'mist_shader.MistShader']

MODES = {
    'default': {},
    'water_off': {'CONDENSER_WATER_OFF': '1', 'CONDENSER_MIST_OFF': '1'},
    'fog_off': {'CONDENSER_FOG_OFF': '1'},
    'lamp_off': {'CONDENSER_LAMP_OFF': '1'},
    # Fog and mist read the lamp state too (u_lamp); with both off, only the
    # lamp program itself can tell these two runs apart.
    'fog_mist_off': {'CONDENSER_FOG_OFF': '1', 'CONDENSER_MIST_OFF': '1'},
    'fog_mist_lamp_off': {'CONDENSER_FOG_OFF': '1', 'CONDENSER_MIST_OFF': '1',
                          'CONDENSER_LAMP_OFF': '1'},
    'mist_off': {'CONDENSER_MIST_OFF': '1'},
    'left_all': {'CONDENSER_TEST_LEFT': '1'},
    'default_again': {},
    # Negative control: the harness corrupts the water fragment shader before it
    # compiles. Proves the compile/link/draw instrumentation can see a failure,
    # so its silence in every other mode carries information.
    'sabotage_water': {'__SABOTAGE__': 'water'},
}

# Installed before any page script: WebGL instrumentation, a hand-stepped
# requestAnimationFrame and the emscripten environment for the game.
INIT_SCRIPT = r"""
(() => {
  const env = __ENV__;
  const sabotage = env.__SABOTAGE__ || null;
  delete env.__SABOTAGE__;
  const markers = __MARKERS__;
  const t = window.__labelleTest = {
    webgl2: false, compileErrors: [], linkErrors: [], linked: {}, draws: {}, frames: 0,
    perFrame: [],  // draws per material kind, one entry per rendered frame
  };
  let frameDraws = {};
  window.Module = {
    preRun: [() => { for (const [k, v] of Object.entries(env)) ENV[k] = v; }],
  };
  const origGetContext = HTMLCanvasElement.prototype.getContext;
  HTMLCanvasElement.prototype.getContext = function (kind, attrs) {
    const ctx = origGetContext.call(this, kind, attrs);
    if (ctx && kind === 'webgl2') t.webgl2 = true;
    return ctx;
  };
  const P = WebGL2RenderingContext.prototype;
  const srcOf = new WeakMap(), shadersOf = new WeakMap(), kindOf = new WeakMap();
  let current = null;
  const wrap = (name, fn) => { const orig = P[name]; P[name] = function (...a) { return fn.call(this, orig, ...a); }; };
  wrap('shaderSource', function (orig, sh, src) {
    if (sabotage && src.includes(markers[sabotage]))
      src = src.replace(/void\s+main\s*\(/, 'void main( sabotaged_by_test');
    srcOf.set(sh, src);
    return orig.call(this, sh, src);
  });
  wrap('compileShader', function (orig, sh) {
    orig.call(this, sh);
    if (!this.getShaderParameter(sh, this.COMPILE_STATUS))
      t.compileErrors.push(String(this.getShaderInfoLog(sh)).slice(0, 400));
  });
  wrap('attachShader', function (orig, prog, sh) {
    if (!shadersOf.has(prog)) shadersOf.set(prog, []);
    shadersOf.get(prog).push(sh);
    return orig.call(this, prog, sh);
  });
  wrap('linkProgram', function (orig, prog) {
    orig.call(this, prog);
    const src = (shadersOf.get(prog) || []).map((s) => srcOf.get(s) || '').join('\n');
    const kind = Object.keys(markers).find((k) => src.includes(markers[k])) || null;
    const ok = !!this.getProgramParameter(prog, this.LINK_STATUS);
    if (!ok) t.linkErrors.push((kind || '?') + ': ' + String(this.getProgramInfoLog(prog)).slice(0, 400));
    if (kind) { kindOf.set(prog, kind); t.linked[kind] = (t.linked[kind] || 0) + (ok ? 1 : 0); }
  });
  wrap('useProgram', function (orig, prog) { current = prog; return orig.call(this, prog); });
  const countDraw = function (orig, ...a) {
    const kind = current && kindOf.get(current);
    if (kind) {
      t.draws[kind] = (t.draws[kind] || 0) + 1;
      frameDraws[kind] = (frameDraws[kind] || 0) + 1;
    }
    return orig.apply(this, a);
  };
  for (const name of ['drawElements', 'drawArrays', 'drawElementsInstanced',
                      'drawArraysInstanced', 'drawRangeElements']) wrap(name, countDraw);
  // Hand-stepped animation frames: the test decides how many frames run.
  let queue = [], now = 0;
  window.requestAnimationFrame = (cb) => { queue.push(cb); return queue.length; };
  window.cancelAnimationFrame = () => {};
  window.__step = (n) => {
    for (let i = 0; i < n; i++) {
      const run = queue; queue = [];
      now += 1000 / 60;
      frameDraws = {};
      for (const cb of run) cb(now);
      if (run.length) {  // a step with no queued callback rendered nothing
        t.frames++;
        t.perFrame.push(frameDraws);
      }
    }
    return queue.length;
  };
})();
"""


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map,
                      '.wasm': 'application/wasm', '.js': 'text/javascript'}

    def log_message(self, *args):
        pass


def serve():
    handler = functools.partial(QuietHandler, directory=str(WEB))
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def run_mode(browser, url, mode, env):
    """One fresh page per scenario; returns (instrumentation, console, pixels, crash)."""
    env = {'LABELLE_FIXED_DT': '0.016666667', **env}
    script = (INIT_SCRIPT.replace('__ENV__', json.dumps(env))
              .replace('__MARKERS__', json.dumps(PROGRAM_MARKERS)))
    page = browser.new_page(viewport={'width': W, 'height': H}, device_scale_factor=1)
    logs = []
    page.on('console', lambda m: logs.append(m.text))
    page.on('pageerror', lambda e: logs.append(f'PAGEERROR {e}'))
    page.add_init_script(script)
    crash = None
    try:
        page.goto(url)
        # Wait for the game's first frame request, then step frame by frame.
        # polling= matters: the default rAF polling would wait on the stepped rAF.
        page.wait_for_function('() => window.__step(0) > 0', polling=50, timeout=60000)
        for _ in range(CAPTURE_FRAME):
            page.evaluate('() => window.__step(1)')
    except PlaywrightError as error:
        crash = str(error).splitlines()[0]
    state = page.evaluate('() => window.__labelleTest')
    png = page.locator('#canvas').screenshot()
    image = np.asarray(Image.open(io.BytesIO(png)).convert('RGB'))
    (OUT / f'{mode}.log').write_text('\n'.join(logs + [f'CRASH {crash}'] * bool(crash)), encoding='utf-8')
    Image.fromarray(image).save(OUT / f'{mode}.png')
    page.close()
    return state, logs, image, crash


def check_mode(mode, state, logs, image, crash):
    text = '\n'.join(logs)
    assert state['webgl2'], (mode, 'no WebGL2 context')
    assert image.shape == (H, W, 3), (mode, image.shape)
    if mode == 'sabotage_water':
        return  # judged in main()
    assert crash is None, (mode, crash, chr(10).join(logs)[-3000:])
    # Every step ran a queued frame: a loop that stopped early cannot pass off a
    # stale capture as frame CAPTURE_FRAME.
    assert state['frames'] == CAPTURE_FRAME, (mode, state['frames'])
    assert not state['compileErrors'], (mode, state['compileErrors'])
    assert not state['linkErrors'], (mode, state['linkErrors'])
    assert 'PAGEERROR' not in text, (mode, text[-3000:])
    for component in COMPONENTS:
        assert f'{component}: 2/2 generic materials live' in text, (mode, component, text[-3000:])
    for kind in PROGRAM_MARKERS:
        assert state['linked'].get(kind, 0) >= 1, (mode, kind, 'program never linked', state['linked'])
        # Effect-off controls zero uniforms, so the program still draws BOTH
        # units: from the first frame both instances draw (by frame 30, when
        # the probe reports them live) to the capture, every frame has both.
        per_frame = [f.get(kind, 0) for f in state['perFrame']]
        first = next((i for i, n in enumerate(per_frame) if n >= INSTANCES), None)
        assert first is not None and first < 30, (mode, kind, 'both instances never drew', per_frame[:40])
        assert all(n >= INSTANCES for n in per_frame[first:]), (mode, kind, 'an instance stopped drawing', per_frame)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--native', type=Path, help='native capture of the default mode')
    parser.add_argument('--headed', action='store_true')
    args = parser.parse_args()
    assert (WEB / 'index.html').exists(), f'build the wasm target first: no {WEB}/index.html'
    OUT.mkdir(parents=True, exist_ok=True)
    server = serve()
    url = f'http://127.0.0.1:{server.server_address[1]}/index.html'
    results = {}
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=not args.headed, args=[
            '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'])
        for mode, env in MODES.items():
            state, logs, image, crash = run_mode(browser, url, mode, env)
            check_mode(mode, state, logs, image, crash)
            results[mode] = (state, image, crash)
            print(mode, 'linked', state['linked'], 'draws', state['draws'], flush=True)
        browser.close()
    server.shutdown()

    report = []
    base_state, base, _ = results['default']
    # Each effect-off control changes pixels (the controls zero the effect's
    # uniforms, so its program keeps drawing: pixels, not draw counts, differ).
    # Empty water also emits no mist, so water is judged against mist_off: the
    # only difference left between those two runs is the water itself.
    for mode, reference in [('water_off', 'mist_off'), ('fog_off', 'default'),
                            ('lamp_off', 'default'), ('fog_mist_lamp_off', 'fog_mist_off'),
                            ('mist_off', 'default')]:
        state, image, _ = results[mode]
        changed = np.any(results[reference][1] != image, axis=2)
        assert changed.any(), (mode, f'turning the effect off changed no pixel vs {reference}')
        report.append(f'{mode}: {int(changed.sum())} pixels differ from {reference}; draws {state["draws"]}')
    # Determinism: a second default run is pixel-identical (fixed dt, stepped frames).
    assert np.array_equal(base, results['default_again'][1]), 'default capture is not repeatable'
    report.append('default_again: byte-identical to default (frame-exact stepping)')
    # Negative control: the corrupted water shader is reported by the driver and
    # never links or draws. (bgfx currently treats a GL shader compile failure
    # as fatal, so the game stops there; the check does not depend on that.)
    state, image, crash = results['sabotage_water']
    assert state['compileErrors'] or state['linkErrors'], 'sabotage went unnoticed'
    assert state['linked'].get('water', 0) == 0 and state['draws'].get('water', 0) == 0, state
    report.append(f'sabotage_water: driver reported {len(state["compileErrors"])} compile error(s), '
                  f'water never linked or drew; game outcome: {crash or "kept running"}')
    # Left-only control: right unit byte-identical.
    _, left, _ = results['left_all']
    assert np.array_equal(base[:, 618:], left[:, 618:]), 'left_all changed the right unit'
    left_changed = int(np.any(base[:, :618] != left[:, :618], axis=2).sum())
    assert left_changed > 0, 'left_all control had no effect'
    report.append(f'left_all: {left_changed} left pixels changed; right half byte-identical')
    if args.native:
        native = np.asarray(Image.open(args.native).convert('RGB'))
        assert native.shape == base.shape, (native.shape, base.shape)
        channels = np.abs(native.astype(int) - base.astype(int))
        diff = channels.max(axis=2)  # worst channel per pixel, for the outlier counts
        report.append(f'vs native {args.native.name}: mean channel error {channels.mean():.3f}, '
                      f'{int((diff > 8).sum())} px differ by >8, {int((diff > 32).sum())} by >32')
        assert channels.mean() < 1.0 and (diff > 32).sum() < diff.size // 1000, report[-1]
        Image.fromarray((np.minimum(diff * 4, 255)).astype(np.uint8)).save(OUT / 'native_diff.png')
    (OUT / 'results.txt').write_text('\n'.join(report) + '\n', encoding='utf-8')
    print('\n'.join(report))
    return 0


if __name__ == '__main__':
    sys.exit(main())
