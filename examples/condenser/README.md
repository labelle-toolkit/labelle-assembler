# condenser — the built-in `PixelWater` reservoir on real COND-07 artwork

A runnable Labelle game for [labelle-bgfx#100](https://github.com/labelle-toolkit/labelle-bgfx/issues/100)'s
acceptance criterion — *"a runnable Labelle example using this condenser's
artwork"* — exercising the engine's built-in `PixelWater` component and
bgfx's `fs_pixel_water` program through the ordinary `labelle` CLI path.

Two COND-07 condenser units stand side by side. Each has a reactive water
reservoir in its basin, stationary mist artwork, and condensation drops that fall from
the coils, contact the *current* water surface and put one ripple into it.

## What it demonstrates

1. **`PixelWater` authored in a PREFAB's JSON config.** The whole block —
   mask, reflection, `logical_size`, `grid_pixels`, `water_level`, the sRGB
   hex palette, the wave and ripple parameters — lives in
   `prefabs/reservoir.jsonc`, not inline in the scene. The JSONC apply path
   routes the built-in through `game.addPixelWater`, which validates it,
   pins the mask/reflection in the `AssetCatalog` and creates the gfx water
   instance.
2. **Per-instance override of a built-in component.** `scenes/main.jsonc`
   instantiates that prefab twice and patches only `water_level` (and the
   `Reservoir.unit` marker) at the instance site with flat PascalCase keys.
   Everything else is inherited — the deep merge of
   `RFC-OVERRIDES-MERGE-RULES`, on a built-in, which is a different code
   path from a plain scene component.
3. **Two independent reservoirs.** Unit A runs at level `0.8333`, unit B at
   `0.5`, from one prefab. Each gets its own gfx water instance, and a
   ripple in one never shows in the other.
4. **Drop → ripple, through the engine API.** `scripts/playing/10_drops.zig`
   computes the live surface from `PixelWater.water_level` every frame and
   calls `game.addWaterRipple(reservoir, local_x, strength)` exactly once
   per fall. It animates nothing about the water itself.
5. **Foreground occlusion / draw order**, as layer order:
   `machine_interior → water → mist → drops → cooler → frame`. Emitter A
   sits behind the cooler, so its drop is occluded on the way down and only
   its ripple shows.
6. **Screen-space layers.** The composition is fixed and pixel-exact, so a
   scene coordinate must be a window coordinate — all five layers are
   `.space = .screen`. On a `.world` layer the default camera centres the
   world origin in the window, which puts these measured native-px
   coordinates half a screen off.
7. **Stationary mist artwork.** The reconstructed mist stays aligned with the
   machine interior. Animation is limited to the water shader and falling drops.

## The measurements (do not re-derive them)

All from the assets branch's own investigation — see
`docs/issue-references/condenser-100/README.md` on labelle-bgfx branch
`feat/condenser-assets` ([PR #106](https://github.com/labelle-toolkit/labelle-bgfx/pull/106)),
which is the credit for every number and every layer here.

| Quantity | Value |
|---|---|
| Native canvas | **103 x 55**, enlarged x6 (so one unit is 618 x 330) |
| Reservoir rect | **x 4, y 48, w 93, h 6** — anchor (4, 48) |
| Surface | `surface_y = 6 * (1 - level)`, from the rect's top |
| Drop emitters (reservoir-local x) | **21, 28, 43, 51, 65** |
| `grid_pixels` | **1** — a native art px *is* an effect cell; the "6x6" in #100 is the x6 screen enlargement |
| Water palette | `deep #0F1719`, `surface #7AA5BB`, `highlight #425F6C` |

The source art has **no true pixel grid** — 103x55 is anchored to the
animated drop columns, not to a grid in the painting. That is a measured
conclusion, not an approximation to fix.

### The 6-level quantisation caveat

The basin is **6 native rows tall**, so `water_level` has exactly **6
usable steps**. Unit A is authored at **`0.8333` (5/6)**: it reads as a
nearly-full reservoir — matching the reference, where the observed fill is
the only fill — while leaving one dry row of headroom. That headroom
matters mechanically: at `level = 1.0` the shader clamps the displaced
surface to the top edge, so waves and ripples become invisible. Unit B is
authored at `0.5` purely to show two independent levels from one prefab.

If 6 steps is too coarse for a future effect, the assets README gives the
alternative: halve the cell to 3 px (canvas 206x110, reservoir 93x12 at
x 8, y 96). That is a working-resolution choice, not a new measurement.

### There is no splash art

The reference has no splash or impact frames, and none are authored here.
The impact is entirely shader-driven: one `addWaterRipple` per drop, and
`fs_pixel_water` does the rest. Nothing in this example fakes water with a
sprite animation.

## The art

`assets/layers/` is vendored **verbatim** from labelle-bgfx PR #106 (that
branch is unmerged, which is why the files are copied in rather than
referenced). Several layers are **reconstructed**, not extracted — the
assets README marks each one, and the honest summary is:

* `machine_interior.png` — extracted, with the mist algebraically un-mixed
  out (the *envelope* is measured, the haze/behind split is a model).
* `reservoir_mask.png` — the surface is occluded for native x 19..29 by the
  cooler; the mask is a plain rectangle across that gap, on the assumption
  the basin is continuous behind it. Nothing in the image confirms it.
* `reservoir_static.png` — extracted for x >= 30, mirrored filler for
  x 19..29.
* `reflection.png` — **authored**, not extractable.
* `mist.png` — a reconstructed separation of an extracted signal.
* `cooler_foreground.png` / `frame_foreground.png` — extracted pixels, but
  **reconstructed** (axis-aligned) silhouettes.
* `drop.png` — extracted, colour ramp measured from the reference trail.

`tools/pack_atlas.py` crops the two reservoir-local textures and packs the
drawn layers into `assets/condenser.{png,json}`. Re-run it after touching
`assets/layers/`.

Note the split: the atlas carries the **drawn sprites**, while
`PixelWater.mask` / `.reflection` must be standalone `.image` resources —
the engine's `catalogTexture` only accepts `loader_kind == .image`, and the
shader samples both in reservoir-local UV, so each spans exactly the 93x6
logical rectangle.

## Version pins

```zig
.core_version = "1.32.0", .engine_version = "2.22.0", .gfx_version = "1.36.0",
.labelle_version = "1.67.0", .assembler_version = "local:../../",
.backend_package = .{ .name = "bgfx", … .version = "0.20.0" },
```

`PixelWater` is a built-in as of **engine 2.22.0**; the water program ships
in **bgfx 0.20.0**; the gfx-owned water-instance store is **gfx 1.36.0**.
The assembler is `local:../../` (in-tree source, the examples convention).

## Build & run

```bash
labelle run --timeout=20s
```

Use `labelle --timeout`, never the OS `timeout` — a SIGTERM produces false
leak errors.

## Verifying the effect actually ran

The pixel-water fallback draws the authored static reservoir sprite, so a
screenshot that "looks like water" proves nothing. Two checks do.

**1. The mechanism, from the log.** A good run prints:

```
info: bgfx: pixel-water program initialized (renderer: .Metal)
INFO [condenser] unit 0: water instance … LIVE — level=0.8333 mask='reservoir_mask' … logical=93x6 grid=1
INFO [condenser] unit 1: water instance … LIVE — level=0.5000 …
```

and **none** of the degrade lines:

```
bgfx: fs_pixel_water failed to link on this renderer …        (programs.zig)
bgfx: failed to create pixel-water uniforms …                 (programs.zig)
labelle-gfx: material effect 'pixel_water' not supported …    (retained_engine/draw.zig)
labelle-gfx: a pixel_water sprite has no resolvable water instance …
```

The two `LIVE` lines also *are* the override evidence: one prefab, two
instances, two different levels.

**2. The pixels, across time and against a control.** Capture the same
scene at two simulation times and diff the reservoir band; then repeat with
`CONDENSER_WATER_OFF=1`, which sets both levels to 0 — the shader's
explicit "render no water" gate — and diff the same band again. Water on
must move; water off must not.

```bash
labelle run --timeout=8s --screenshot=/tmp/on_t2.png  --after=2s
labelle run --timeout=8s --screenshot=/tmp/on_t5.png  --after=5s
CONDENSER_WATER_OFF=1 labelle run --timeout=8s --screenshot=/tmp/off_t2.png --after=2s
CONDENSER_WATER_OFF=1 labelle run --timeout=8s --screenshot=/tmp/off_t5.png --after=5s
```

`scripts/playing/30_water_probe.zig` owns both the reporting and the
control switch.

## Measured results from the verification above

Sampling the reservoir band at native-cell centres, **excluding the drop
columns and the cooler/frame columns** so a difference can only be the
shader (mean |delta| out of 765, share of cells that changed):

| reservoir | water ON, 2000ms vs 3300ms | control (level 0), same pair | ON vs control, 3300ms |
|---|---|---|---|
| unit A (0.8333) | **26.9 — 66.1% of cells** | **0.000 — 0.0%** | 30.0 — 67.7% |
| unit B (0.5)    | **16.5 — 39.2% of cells** | **0.000 — 0.0%** | 18.6 — 42.3% |

The control is *bit-identical* across all three capture times; with water on,
two thirds of the band moves. One caveat worth repeating: do not sample two
times exactly `wave_period_seconds` apart — at 2s and 5s the wave is in the
same phase and only live ripples show, which understates the effect badly.

## Files

- `project.labelle` — window, layers, the atlas + the two standalone
  `.image` resources, pins.
- `prefabs/reservoir.jsonc` — **the `PixelWater` block**.
- `scenes/main.jsonc` — two units; two prefab instances with overrides.
- `components/reservoir.zig` — unit marker.
- `components/drop.zig` — one drop's fall + impact bookkeeping.
- `scripts/playing/10_drops.zig` — fall, contact, one `addWaterRipple`.
- `scripts/playing/30_water_probe.zig` — verification + control switch.
- `tools/pack_atlas.py` — crops + packs `assets/`.
