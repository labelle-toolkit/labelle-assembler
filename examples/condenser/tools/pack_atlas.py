#!/usr/bin/env python3
"""Pack the COND-07 condenser layers into the single `condenser` atlas.

The layer PNGs in `assets/layers/` are vendored verbatim from labelle-bgfx
PR #106 (`docs/issue-references/condenser-100/layers/`). Two of them are
also cropped here to the measured reservoir rect (x 4, y 48, w 93, h 6):

  * `reservoir_mask_rect.png` — the pixel-water silhouette MASK. The shader
    samples it in reservoir-LOCAL uv, so it must span exactly the logical
    rectangle, not the 103x55 canvas.
  * `reservoir_art.png`       — the authored static reservoir, which is the
    water sprite's own texture (`s_tex`) and the degrade fallback.

Run from the example root:  python3 tools/pack_atlas.py
"""
import json, os
from PIL import Image

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(HERE, "assets", "layers")
DST = os.path.join(HERE, "assets")

# Measured reservoir rect on the 103x55 native canvas (README on the assets branch).
RESERVOIR = (4, 48, 4 + 93, 48 + 6)
PAD = 4

def crop(name, out):
    Image.open(os.path.join(SRC, name)).convert("RGBA").crop(RESERVOIR).save(os.path.join(DST, out))

crop("reservoir_mask.png", "reservoir_mask_rect.png")
crop("reservoir_static.png", "reservoir_art.png")

frames = ["machine_interior.png", "mist.png", "cooler_foreground.png",
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
with open(os.path.join(DST, "condenser.json"), "w") as f:
    json.dump(manifest, f, indent=1)
print("packed", width, "x", height, "->", list(manifest["frames"]))
