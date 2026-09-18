#!/usr/bin/env python3
"""Rebuild at reference pixel density (Pillow + numpy), without spatial filtering.

Temporal median removes animated drops. Only two left border columns are
cropped to retain the existing 618x330 scene geometry. Mist remains static.
"""
from pathlib import Path
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
LAYERS = ROOT / 'assets/layers'
with Image.open(ROOT / 'assets/reference/condenser-detail.gif') as gif:
    assert gif.size == (620, 330)
    frames = []
    for i in range(gif.n_frames):
        gif.seek(i)
        frames.append(np.asarray(gif.convert('RGB'))[:, 2:620])
plate = np.median(np.stack(frames), axis=0).astype(np.uint8)
y, x = np.mgrid[:330, :618]
window = (x >= 24) & (x < 582) & (y >= 18) & (y < 324)
basin = (x >= 24) & (x < 582) & (y >= 288) & (y < 324)
cooler = (x >= 102) & (x < 186) & (y >= 192) & window

def layer(name, rgb, mask):
    rgba = np.zeros((330, 618, 4), dtype=np.uint8)
    rgba[:, :, :3] = rgb
    rgba[:, :, 3] = mask.astype(np.uint8) * 255
    Image.fromarray(rgba).save(LAYERS / name)
    return rgba

parts = [layer('frame_foreground.png', plate, ~window),
         layer('cooler_foreground.png', plate, cooler),
         layer('machine_interior.png', plate, window & ~basin & ~cooler)]
reservoir = plate.copy()
# Reconstructed hidden water, covered by the cooler in the final composition.
for column in range(114, 180):
    reservoir[288:324, column] = plate[288:324, min(180 + 179 - column, 581)]
parts.append(layer('reservoir_static.png', reservoir, basin))
layer('reservoir_mask.png', np.full_like(plate, 255), basin)
reflection = plate[108:144, 24:582][::-1].astype(np.float32)
reflection = (reflection * 0.8 + np.array([23, 45, 54]) * 0.2).astype(np.uint8)
Image.fromarray(reflection).convert('RGBA').save(LAYERS / 'reflection.png')
# The animated overlay does use six-pixel-wide drops, unlike the static plate.
ramp = [(82,117,135,170), (82,117,135,205), (82,117,135,215),
        (127,171,195,235), (173,202,198,255)]
drop = np.repeat(np.repeat(np.array(ramp, dtype=np.uint8)[:, None], 6, axis=0), 6, axis=1)
Image.fromarray(drop).save(LAYERS / 'drop.png')
composite = np.zeros_like(plate)
for index in [2, 3, 1, 0]:
    rgba = parts[index]
    opaque = rgba[:, :, 3] == 255
    composite[opaque] = rgba[:, :, :3][opaque]
assert np.array_equal(composite, plate), 'static layers must preserve every plate pixel'
print('618x330 layers; exact full-resolution static-plate reconstruction verified')
