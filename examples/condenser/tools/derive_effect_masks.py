#!/usr/bin/env python3
"""Deterministic effect decomposition of the PR730 618x330 plate.

Only existing layers derived from the authorized condenser-detail crop are read.
This is an estimated clean plate, not a claim to recover unseen original art.
The inverse veil preserves full-resolution structure and reconstructs the input
within one byte when recomposited. No blur, resampling, or full-room reference.
"""
from pathlib import Path
import json
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'assets/effects'
FOG_COLOR = np.array([0.48, 0.65, 0.73])
LAMP_COLOR = np.array([0.64, 0.85, 0.94])


def load(name):
    a = np.asarray(Image.open(ROOT / 'assets/layers' / name).convert('RGBA'))
    assert a.shape == (330, 618, 4)
    return a.astype(np.float64) / 255


def write(name, array):
    Image.fromarray(np.rint(np.clip(array, 0, 1) * 255).astype(np.uint8)).save(OUT / name)


def derive():
    OUT.mkdir(exist_ok=True)
    interior = load('machine_interior.png')
    frame = load('frame_foreground.png')
    y, x = np.mgrid[:330, :618]
    # Masks are aligned to the six-screen-pixel EFFECT grid. Original artwork
    # stays at full density; no downsample/upsample of structural edges.
    cx = (x // 6 + .5) * 6
    cy = (y // 6 + .5) * 6
    horizontal = np.clip((348 / 2 - abs(cx - 309)) / 6, 0, 1)
    reach = np.where(cy < 12, 12, 132)
    light = horizontal * np.clip(1 - abs(cy - 12) / reach, 0, 1) ** 2
    # Detach the baked light from both static surfaces. A bounded attenuation
    # retains texture detail and keeps the inverse reconstruction in gamut.
    glow = light * .32
    lower = np.exp(-((cy - 258) / 30) ** 2)
    shoulders = .6 + .4 * np.cos((cx - 270) / 108) ** 2
    upper = .10 * np.exp(-((cy - 60) / 42) ** 2)
    veil = np.clip(.36 * lower * shoulders + upper, 0, .46)
    veil *= interior[:, :, 3]
    # Exact inverse of over: base=(art-color*a)/(1-a). Bound a against the
    # observed RGB so no black clipping destroys reconstruction details.
    veil = np.minimum(veil, np.min(interior[:, :, :3] / FOG_COLOR, axis=2) * .85)
    veil = np.minimum(veil, np.min((1-interior[:, :, :3]) / (1-FOG_COLOR), axis=2) * .85)
    fog_clean = (interior[:, :, :3] - FOG_COLOR * veil[:, :, None]) / (1 - veil[:, :, None])
    interior_glow = np.minimum(glow, np.min(fog_clean / LAMP_COLOR, axis=2) * .8)
    interior_glow = np.minimum(interior_glow, np.min((1-fog_clean) / (1-LAMP_COLOR), axis=2) * .8)
    clean = (fog_clean - LAMP_COLOR * interior_glow[:, :, None]) / (1 - interior_glow[:, :, None])
    frame_glow = np.minimum(glow, np.min(frame[:, :, :3] / LAMP_COLOR, axis=2) * .8)
    frame_glow = np.minimum(frame_glow, np.min((1-frame[:, :, :3]) / (1-LAMP_COLOR), axis=2) * .8)
    frame_clean = (frame[:, :, :3] - LAMP_COLOR * frame_glow[:, :, None]) / (1 - frame_glow[:, :, None])
    # The physical tube is baked into the top frame, not just its halo. Remove
    # it using the unlit casing immediately above; retain its exact artwork as
    # the sprite sampler's emissive source. The shader restores it ONLY where
    # G is set and the runtime width/intensity permit it.
    tube = (x >= 138) & (x < 480) & (y >= 6) & (y < 18)
    tube &= (np.max(frame[:, :, :3], axis=2) > .40) & (frame[:, :, 3] > 0)
    casing = np.median(frame[:6, :, :3], axis=0)
    frame_clean[tube] = np.broadcast_to(casing, frame_clean.shape)[tube]
    # The mask stores the reconstruction's response coefficient, independent
    # of the default lamp footprint. Width/reaches can therefore change live.
    response_i = np.divide(interior_glow, light, out=np.full_like(light, .32), where=light > 0)
    response_f = np.divide(frame_glow, light, out=np.full_like(light, .32), where=light > 0)
    write('interior_clean.png', np.dstack((clean, interior[:, :, 3])))
    write('frame_clean.png', np.dstack((frame_clean, frame[:, :, 3])))
    write('fog_mask.png', np.dstack((veil, response_i, np.zeros_like(veil), interior[:, :, 3])))
    write('lamp_mask.png', np.dstack((response_f, tube.astype(float), np.zeros_like(veil), frame[:, :, 3])))
    reconstructed_light = clean * (1 - interior_glow[:, :, None]) + LAMP_COLOR * interior_glow[:, :, None]
    reconstructed = reconstructed_light * (1 - veil[:, :, None]) + FOG_COLOR * veil[:, :, None]
    assert np.max(abs(reconstructed - interior[:, :, :3])) < 1e-12
    metadata = dict(size=[618, 330], effect_grid=6, source='PR730 full-resolution layers from condenser-detail.gif (620x330, crop left 2px)',
                    fog_color=FOG_COLOR.tolist(), lamp_color=LAMP_COLOR.tolist(),
                    fog_mask='R=estimated baked veil, G=lamp response, A=interior coverage',
                    lamp_mask='R=lamp response, G=physical emissive tube coverage, A=frame coverage',
                    method='bounded inverse-over decomposition; estimated clean background, full-resolution structure retained')
    (OUT / 'provenance.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print('Effect masks and clean plates: 618x330; inverse reconstruction verified')


if __name__ == '__main__':
    derive()
