# COND-07 condenser — contained water on reference-resolution artwork

Two condenser units show the engine's built-in `PixelWater` component, using one
reservoir prefab with independent fill levels. Drops create localized fading
ripples. Continuous waves and reflection drift are disabled. Mist is stationary
and baked into the machine artwork.

![Windows/Vulkan capture](preview.png)

## Run

Use CLI 1.67.0 or newer:

```sh
labelle run
```

The example uses the in-tree assembler from this branch, core 1.32.0, engine
2.22.0, gfx 1.36.0 and BGFX 0.20.0. A monorepo assembler can discover sibling
package checkouts instead of these pins; read its package-resolution output.

## Pixel density

The original 620x330 cropped reference is kept in
`assets/reference/condenser-detail.gif`. The wider room image is not included.
Source: https://raw.githubusercontent.com/labelle-toolkit/labelle-bgfx/6a1ce3a24f42adf75b41dec81ec33921b6a27918/docs/issue-references/condenser-100/condenser-detail.gif

The old asset pipeline reduced the art to 103x55 and enlarged it sixfold. This
lost grain and irregular small edges because the painting has no uniform native
pixel grid. The new pipeline preserves source-resolution pixels and renders
sprites at scale 1. Two left border columns are cropped to keep the existing
618x330 unit layout and drop alignment; the two-unit window is 1236x330.

A temporal median across the reference's 72 frames removes moving drops without
spatial downsampling. Static mist remains in this plate. The derivation asserts
that the layered composition reconstructs the median plate pixel-for-pixel.
This is preservation of the static plate, not an assertion that the reference's
animation or inferred occluder silhouettes were recovered exactly.

## Artwork versus water grid

Artwork resolution and effect resolution are independent:

| Quantity | Texture/screen pixels | Water/effect coordinates |
|---|---|---|
| Unit canvas | 618x330 | 103x55 |
| Basin origin | 24, 288 | 4, 48 |
| Basin size | 558x36 | 93x6 |
| Drop sprite | 6x30 at scale 1 | 1x5 |
| Impact X positions within basin | 126/168/258/306/390 | 21/28/43/51/65 |

The shader still uses `logical_size: [93, 6]`, `grid_pixels: 1`. Its impacts remain
six screen pixels per effect cell while the underlying artwork keeps its finer
detail. Both the drawn reservoir texture and its standalone mask cover the same
558x36 rectangle. Mask and reflection are standalone `.image` resources; drawn
sprites use an atlas.

Unit A is 5/6 full; unit B is half full. The six-row effect grid has limited fill
resolution. Drops use the live fill level to find the contact plane and call
`game.addWaterRipple` once per impact. The foreground cooler and frame cover
water and drops in front-to-back layer order.

## Rebuild assets

Install Pillow and numpy, then from this example directory:

```sh
python3 tools/derive_layers.py
python3 tools/pack_atlas.py
```

`derive_layers.py` creates the full-resolution layers and verifies their static
composition. `pack_atlas.py` crops the basin textures and rebuilds the atlas.
The reflection is authored from the coil band; hidden water under the cooler is
reconstructed. Rectangular occlusion boundaries are inherited from the asset
investigation in labelle-bgfx#106. They are assumptions, not original layered art.

## Validation

The updated example builds and runs on Windows/Vulkan. Logs confirm both live
water instances at 0.8333 and 0.5, the water program initializes, and drops emit
ripples. `preview.png` is an engine screenshot of this full-resolution revision.
The earlier branch's Metal verification used the older downsampled assets.

`CONDENSER_WATER_OFF=1` disables water shading for a static-art control. Example:

```sh
labelle run --timeout=5s --screenshot=condenser.png --after=2s
```

The main authoring files are `prefabs/reservoir.jsonc`, `scenes/main.jsonc`,
`scripts/playing/10_drops.zig` and `scripts/playing/30_water_probe.zig`.