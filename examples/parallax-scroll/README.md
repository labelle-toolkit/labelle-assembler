# parallax-scroll — the camera-layer stack, as a small complete game

Showcase seed for [labelle-toolkit#607](https://github.com/labelle-toolkit/labelle-assembler/issues/607)
("curated example games across backends and features"). Unlike the other
directories here — which are focused *smoke fixtures* for one assembler
subsystem — this is a small **complete, backend-selectable game**: the
first candidate for the standalone showcase repo #607 envisions.

## What it demonstrates

A four-layer parallax side-scroller built entirely from `Shape`
rectangles (no atlas assets), so the whole game is one `project.labelle`,
one scene, one component, and one script:

| Layer    | `space`       | `order` | Role                                             |
|----------|---------------|---------|--------------------------------------------------|
| `sky`    | `screen_fill` | −20     | Static backdrop, stretches past the pillarbox.   |
| `far`    | `world`       | −10     | Distant ridge line — scrolls slowly (`speed=15`).|
| `ground` | `world`       | 0       | Near foreground — scrolls 3× faster (`speed=45`).|
| `hud`    | `screen`      | 10      | Fixed badge — never scrolls.                     |

The depth illusion comes purely from layer `order` plus a per-plane
`Parallax.speed`; the sky and HUD carry no `Parallax`, so contrasting
them against the two moving world planes *is* the demonstration.

- `components/parallax.zig` — the `Parallax { speed }` component,
  auto-discovered from `components/` (no explicit registration).
- `scripts/playing/10_parallax_scroll.zig` — per-frame driver: queries
  every `Parallax` entity via `view(.{Parallax})`, scrolls it left with
  the engine's `getPosition` / `setPosition` API, and wraps it by one
  authored span for a seamless infinite loop.

## Backend-selectable

Ships targeting the headless `.null` backend so it builds **and runs**
in CI with no window / GPU / display server — deterministic fixed `dt`,
frame-capped by `LABELLE_NULL_FRAMES`, clean exit. The scene, component,
and script are all renderer-agnostic, so to actually *see* the layers
scroll just flip one line in `project.labelle`:

```zig
.backend = .raylib,   // or .sokol, or the external .bgfx package
```

## Build & run (headless)

Invoke the assembler binary directly (same recipe as the `null` /
`flows-smoke` steps in `.github/workflows/ci.yml`):

```bash
ASM=../../zig-out/bin/labelle-assembler
$ASM install  --project-root .   # populate the .null package cache
$ASM generate --project-root .   # → .labelle/null_desktop/
cd .labelle/null_desktop && zig build
./zig-out/bin/parallax_scroll     # 6 entities scroll; sky + hud stay put
```

The transcript is deterministic — one line per frame — so a showcase-repo
CI step can pin it the same way `examples/null` asserts its
`[null] frame=N` sequence:

```text
[parallax] frame=1 scrolled=6
[parallax] frame=2 scrolled=6
… (LABELLE_NULL_FRAMES lines) …
```

`scrolled=6` = the three `far` ridges + three `ground` blocks; the `sky`
backdrop and `hud` badge are excluded because they carry no `Parallax`.
