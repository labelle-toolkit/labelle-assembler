"""Water edge cases at the brim and at an empty ripple window (issue #734).

Native headless captures of the real shader, fixed step, deterministic times.
Fog, lamp and mist are off in every run so only the water can move the band.
Sample times are deliberately NOT a multiple of any wave period apart.
"""
from pathlib import Path
import os
import subprocess
import sys
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / '.test-output/water-edges'
OUT.mkdir(parents=True, exist_ok=True)
EXE = ROOT / '.labelle/bgfx_desktop/zig-out/bin' / ('condenser.exe' if sys.platform == 'win32' else 'condenser')
assert EXE.exists(), f'build the example first: no {EXE}'

# Reservoir art: 558x36 screen px at (24, 288) per unit; 93x6 logical cells.
BAND = (slice(288, 324), slice(24, 582))
CELL = 6
QUIET = {'CONDENSER_FOG_OFF': '1', 'CONDENSER_LAMP_OFF': '1', 'CONDENSER_MIST_OFF': '1'}


def capture(name, seconds, changes=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith('CONDENSER_')}
    env.update(LABELLE_HEADLESS='1', LABELLE_HEADLESS_SURFACELESS='0',
               LABELLE_HEADLESS_TICKS=str(int(seconds * 60) + 40), LABELLE_HEADLESS_UNCAPPED='1',
               LABELLE_FIXED_DT='0.016666667', LABELLE_SCREENSHOT_PATH=str(OUT / f'{name}.tga'),
               LABELLE_SCREENSHOT_AFTER_SEC=str(seconds))
    env.update(QUIET)
    env.update(changes or {})
    result = subprocess.run([str(EXE)], cwd=ROOT, env=env, capture_output=True, timeout=120,
                            creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    log = (result.stdout + result.stderr).decode('utf-8', errors='replace')
    (OUT / f'{name}.log').write_text(log, encoding='utf-8')
    assert result.returncode == 0, (name, result.returncode, log[-3000:])
    for component in ['water_shader.WaterShader', 'fog_shader.FogShader',
                      'lamp_shader.LampShader', 'mist_shader.MistShader']:
        assert f'{component}: 2/2 generic materials live' in log, (name, component, log[-3000:])
    image = Image.open(OUT / f'{name}.tga').convert('RGB')
    image.save(OUT / f'{name}.png')
    return np.asarray(image).astype(int)


report = []
TIMES = (2.0, 3.3, 4.7)

# The guarantee the old surface clamp existed for: the mask covers the top row.
mask = np.asarray(Image.open(ROOT / 'assets/reservoir_mask_rect.png').convert('RGBA'))
assert (mask[0, :, 3] == 255).all(), 'reservoir mask must reach the top row for this check'

full = {t: capture(f'full_{int(t * 1000)}', t, {'CONDENSER_WATER_LEVEL': '1'}) for t in TIMES}
empty = capture('empty', 2.0, {'CONDENSER_WATER_OFF': '1'})

# (1) Full fill still moves: the displacement is clamped, not the surface.
for a, b in ((2.0, 3.3), (2.0, 4.7), (3.3, 4.7)):
    changed = np.any(full[a][BAND] != full[b][BAND], axis=2)
    assert changed.any(), (a, b, 'water is static at water_level = 1.0')
    rows = [int(changed[r * CELL:(r + 1) * CELL, :558].sum()) for r in range(6)]
    # The surface itself travels: motion reaches every cell row, instead of
    # being confined to the brim row the way a clamped SURFACE leaves it.
    assert min(rows) * 4 >= max(rows), (a, b, 'motion confined to the top cell row', rows)
    report.append(f'level=1.0 {a}s vs {b}s: {int(changed.sum())} band px differ; '
                  f'unit A per cell row {rows}')

# (1b) and it still fills to the brim: no dry hole anywhere, at any sample time.
for t, image in full.items():
    covered = np.any(image[BAND] != empty[BAND], axis=2)
    assert covered.all(), (t, 'dry holes at full fill', int((~covered).sum()))
    report.append(f'level=1.0 {t}s: all {covered.size} band px covered (no dry holes)')

# (2) A zero-duration ripple is an EMPTY window on every frame, including the
# one where start_time == time. The hook uploads exactly that frame.
none = {t: capture(f'nostrength_{int(t * 1000)}', t, {'CONDENSER_WATER_RIPPLE_STRENGTH': '0'}) for t in TIMES}
zero = {t: capture(f'zeroduration_{int(t * 1000)}', t, {'CONDENSER_WATER_SHADER_RIPPLE_DURATION': '0'}) for t in TIMES}
live = {t: capture(f'liveduration_{int(t * 1000)}', t, {'CONDENSER_WATER_SHADER_RIPPLE_DURATION': '0.9'}) for t in TIMES}
for t in TIMES:
    # Mechanism first: the same hook with a POSITIVE duration does disturb the
    # band, so an equal picture below means the gate ran, not that nothing was
    # uploaded.
    assert not np.array_equal(live[t][BAND], none[t][BAND]), (t, 'hook never reached the shader')
    assert np.array_equal(zero[t][BAND], none[t][BAND]), (
        t, 'zero-duration ripple rendered', int(np.any(zero[t][BAND] != none[t][BAND], axis=2).sum()))
    report.append(f'age-zero impacts at {t}s: duration 0 identical to no impacts; '
                  f'duration 0.9 differs in {int(np.any(live[t][BAND] != none[t][BAND], axis=2).sum())} px')

(OUT / 'results.txt').write_text('\n'.join(report) + '\n')
print('\n'.join(report))
print(f'{len(TIMES) * 4 + 1} native runs: all water edge-case checks passed.')
