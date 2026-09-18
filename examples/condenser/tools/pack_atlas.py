#!/usr/bin/env python3
"""Pack the COND-07 condenser layers into the single `condenser` atlas.

The layer PNGs in `assets/layers/` are rebuilt by `derive_layers.py` from
the cropped reference at full resolution. Two are cropped to the basin
rectangle (x 24, y 288, w 558, h 36):

  * `reservoir_mask_rect.png` — the pixel-water silhouette MASK. The shader
    samples it in reservoir-LOCAL uv, so it must span exactly the logical
    rectangle, not the full 618x330 canvas.
  * `reservoir_art.png`       — the authored static reservoir, which is the
    water sprite's own texture (`s_tex`) and the degrade fallback.

Run from the example root:  python3 tools/pack_atlas.py
"""
import json, os
from PIL import Image

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(HERE, "assets", "layers")
DST = os.path.join(HERE, "assets")

# Reference-resolution reservoir; shader logical coordinates remain 93x6.
RESERVOIR = (24, 288, 582, 324)
PAD = 4

def crop(name, out):
    Image.open(os.path.join(SRC, name)).convert("RGBA").crop(RESERVOIR).save(os.path.join(DST, out))

crop("reservoir_mask.png", "reservoir_mask_rect.png")
crop("reservoir_static.png", "reservoir_art.png")

frames = ["machine_interior.png", "cooler_foreground.png",
          "frame_foreground.png", "drop.png"]
images = [(n, Image.open(os.path.join(SRC, n)).convert("RGBA")) for n in frames]
images.append(("reservoir_art.png", Image.open(os.path.join(DST, "reservoir_art.png"))))

width = max(im.width for _, im in images)
height = sum(im.height + PAD for _, im in images) - PAD
sheet = Image.new("RGBA", (width, height), (0, 0, 0, 0))

manifest = {"frames": {}}
y = 0
for name, im in images:
    sheet.paste(im, (0, y))
    manifest["frames"][name] = {
        "frame": {"x": 0, "y": y, "w": im.width, "h": im.height},
        "rotated": False, "trimmed": False,
        "spriteSourceSize": {"x": 0, "y": 0, "w": im.width, "h": im.height},
        "sourceSize": {"w": im.width, "h": im.height},
    }
    y += im.height + PAD

sheet.save(os.path.join(DST, "condenser.png"))
with open(os.path.join(DST, "condenser.json"), "w", encoding="utf-8", newline="\n") as f:
    json.dump(manifest, f, indent=1)
print("packed", width, "x", height, "->", list(manifest["frames"]))
