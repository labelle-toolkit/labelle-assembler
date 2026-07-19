# Showcase repo plan — curated example games across backends & features

Tracking: [labelle-toolkit#607](https://github.com/labelle-toolkit/labelle-assembler/issues/607)
· parent epic [#520 (examples agnosticism)](https://github.com/labelle-toolkit/labelle-assembler/issues/520)

## Why a separate repo

The #520 epic moved the pure-backend examples out of this assembler and
into the `labelle-<backend>` repos, leaving the assembler's `examples/`
holding only **backend-agnostic smoke fixtures** (see the table below).
The acknowledged remainder of that epic is a *showcase*: a curated
`labelle-toolkit` repo of small, **complete** games — not one-subsystem
fixtures — that demonstrate features working together, each CI-built
against a pinned assembler release with transcript/screenshot assertions
where the backend is headless-able.

It is greenfield (new repo). This document is the proposal; the first
game is already scaffolded and verified in this repo as the seed —
`examples/parallax-scroll/` (see "Seed" below).

## What already exists here (the fixtures the showcase is NOT)

The assembler's own `examples/` are focused fixtures, each pinning one
codegen/runtime subsystem. They are the raw material the showcase games
draw features from, but they are deliberately minimal, not "games":

| Fixture                       | Backend        | Subsystem it pins                                   |
|-------------------------------|----------------|-----------------------------------------------------|
| `null`                        | `.null`        | headless generate→build→run, frame-cap, clean exit  |
| `external-null`               | `nullfixture`  | out-of-tree `.backend_package` fetch→stage→build     |
| `asset-streaming-smoke`       | `.null`        | lazy atlas inference, `SceneAssetManifests`         |
| `flows-smoke`                 | `.null`        | `.flow.jsonc` → flow_codegen → generated scripts    |
| `packs-demo`                  | `.null`        | pack module wall (isolation, Registry, exposes)     |
| `plugin-controllers`          | `.null`        | plugin `Controller` setup/tick/deinit lifecycle     |
| `camera-builtin`              | `.null`        | engine built-in `Camera` component pass-through     |
| `fantasy-dungeon`             | `.null`        | asset-plugin: bundled packs + atlases, zero config  |
| `scripting-smoke`             | `.null`+null-sib | Lua scripting via `labelle-scripting` (declare mode) |

Grounded feature surfaces available today (from these fixtures + the
sibling packages): sprites + `AnimationDef` cycling, camera-layer stack
(`labelle-gfx/src/layer.zig`: `world` / `screen` / `screen_fill`), packs
(`docs/packs.md`), flows, asset streaming, tilemaps (`.tmx` embedding,
T2 Phase 4 / #560), and scripting languages via `labelle-scripting`
(lua, ruby). Materials are gated on gfx#305 and are therefore a
*deferred* showcase entry, not a launch one.

### Scene format note (engine v2.0, #592)

Scene `.jsonc` files use the **unified format**: file-level entities live
under `"children"` (not the pre-#560 top-level `"entities"` array, which
engine v2.0 now *rejects* with `error.InvalidFormat`), and asset lists
are inferred from sprite references (no top-level `"assets"`). Inline
entities keep their `"components": { … }` wrapper (or flat PascalCase
keys); only prefab *references* must use `"overrides"`. All showcase
games below follow this.

## Proposed showcase games

Ordered by readiness. Each is a complete game, each pins a distinct
feature × backend cell so the set doubles as a cross-backend conformance
grid. Backend column = the backend the game *ships on* (all remain
backend-selectable; the headless ones also run in CI).

| # | Game                | Primary feature                          | Ships on   | CI assertion            | Status / seed candidate            |
|---|---------------------|------------------------------------------|------------|-------------------------|------------------------------------|
| 1 | **parallax-scroll** | camera layers + parallax (`screen_fill` / `world` / `screen`) | `.null` (→ raylib/bgfx) | transcript (`scrolled=N`) | **scaffolded + verified** (this repo) |
| 2 | **scripting-smoke** | Lua gameplay script via `labelle-scripting` | `.null`+null-sib | transcript (`LUA_*`) | **scaffolded + verified** (this repo, ticket seed) |
| 3 | **ruby-orbit**      | Ruby gameplay script via `labelle-scripting` | `.null`+null-sib | transcript (`RUBY_*`) | **scaffolded + verified** (this repo, ticket seed) |
| 4 | **coin-collector**  | full gameplay loop: queries, homing, collision, `destroyEntity`, win | `.null` (→ raylib/bgfx) | transcript (`score`/`cleared`) | **scaffolded + verified** (this repo) |
| 5 | **event-relay**     | game event bus + game-root `events/`+`hooks/` (pure Zig) | `.null` (→ any) | transcript (`emit`/`pulse`) | **scaffolded + verified** (this repo) |
| 6 | **pack-city**       | packs wall as a real game                | bgfx       | generate + build (+ screenshot) | **scaffolded + verified** (#611)   |
| 7 | **sprite-runner**   | sprite atlas + `AnimationDef` + `SpriteAnimation` | sokol | generate + build (+ screenshot) | **scaffolded + verified** (#611)   |
| 8 | **tile-explorer**   | `.tmx` tilemap + camera follow           | raylib     | generate + build (+ screenshot) | **scaffolded + verified** (#611)   |
| 9 | **material-demo**   | post-fx set (bloom/vignette/color_grade/crt) | bgfx   | generate + build (+ screenshot) | **scaffolded + verified** (#611)   |

Games 1–5 are scaffolded + verified end-to-end in this repo (generate →
`zig build` → deterministic headless run). 2 and 3 are the ticket's
explicit scripting seed candidates (Lua + Ruby). 6 is the ticket's packs
seed. 7–8 round out the sprite/animation and tilemap surfaces; 9 landed
once gfx#305 shipped (post-fx half — see below).

### Games 6–9 (labelle-assembler#611) — the RELEASED-pin cohort

Unlike games 1–5 (which pin `local:` siblings to gate assembler HEAD),
games 6–9 pin the **released** package set (core 1.26.0 / engine 2.6.0 /
gfx 1.28.1 / cli 1.58.0 / assembler 0.94.0) to prove the released path.
All four `generate` + `zig build` green; the raylib + sokol builds run in
CI (`examples-integration`), the two bgfx builds are covered locally.

Two precise findings surfaced by proving the released path:

- **sokol-desktop material-seam fix (fixed in #611).** The gfx#305
  material seam gave the sokol backend's gfx module a direct
  `labelle-core` import; assembler 0.94.0's sokol-desktop *byte-anchor*
  codegen never unified it onto the app core, so a distinct
  `MaterialEffect` type failed sema. #611 unrolls the `backend_gfx`
  core-diamond edge into the anchor (matching the generic desktop path
  bgfx/raylib already used). Released 0.94.0 cannot build a sokol-desktop
  game against any gfx#305-era backend until the next assembler release
  carries this fix; bgfx/raylib were never affected.
- **per-entity materials have no game authoring surface yet (engine
  2.6.0).** gfx#305's post-fx half is game-wired (`.post_fx` seed →
  `setPostFx`); its per-entity material half (`palette_swap`/`flash`/
  `dissolve`/`outline`) is plumbed in core+gfx (`SpriteVisual.material`)
  but the engine exposes no `Sprite.material`/`setMaterial`. `material-demo`
  therefore exercises the post-fx half; the material half is a tracked
  engine follow-up.

> **`+null-sib`** = the scripting games pin the backend to a
> `labelle-null` SIBLING checkout (not the registry `.null` shorthand),
> because the generated main's `script_contract.bind` touchpoint lives in
> labelle-null's `templates/headless.txt` and the registry release
> predates it. CI clones labelle-null beside the repo (branch fallback,
> same pattern as core/engine). Switch to a registry pin once labelle-null
> cuts a release carrying the touchpoint.

## Proposed showcase-repo layout

```
labelle-showcase/
├── README.md                     # the grid above + per-game GIFs/screens
├── .github/workflows/ci.yml      # matrix job: one entry per game
├── games/
│   ├── parallax-scroll/          # lifted from this repo's examples/
│   │   ├── project.labelle
│   │   ├── scenes/main.jsonc
│   │   ├── components/parallax.zig
│   │   └── scripts/playing/10_parallax_scroll.zig
│   ├── scripting-smoke/
│   ├── ruby-arena/
│   └── …
└── docs/
    └── adding-a-game.md          # the conventions below
```

Each `games/<name>/` is a standard labelle project (identical layout to
this repo's `examples/*`): `project.labelle` + `scenes/` + optional
`components/`, `scripts/<state>/`, `packs/`, `plugin/`.

### The one delta when lifting a game from here → the showcase repo

In-repo examples resolve the runtime packages through `local:` sibling
paths:

```zig
.core_version      = "local:../../../labelle-core",
.engine_version    = "local:../../../labelle-engine",
.gfx_version       = "local:../../../labelle-gfx",
.labelle_version   = "local:../../../labelle-cli",
.assembler_version = "local:../../",
```

The showcase repo has no sibling checkouts, so these become a **pinned
assembler release** + published package versions (the same pins the
former in-backend examples used before #520 moved them out). That is the
*only* edit needed — everything else lifts verbatim.

## CI model (mirrors this repo's `examples-integration` job)

For each game, per its "CI assertion" column:

1. Check out the pinned assembler release (or build it from a pinned SHA).
2. `assembler install --project-root games/<name>` — populate the backend
   package cache (external/extracted backends like `.null` / bgfx need
   their `backend.manifest.zon` cached before `generate`).
3. `assembler generate --project-root games/<name>`.
4. `cd .labelle/<backend>_<platform> && zig build` (apply the
   `fixFingerprint` rewrite the CLI runner normally does — see this
   repo's null step).
5. **Headless-able backends** (`.null`, and bgfx/sokol offscreen once
   PR #37's true-headless init lands): run the binary, `diff` the
   transcript against a checked-in expected file.
   **Windowed backends**: `labelle run --timeout=Ns` + `takeScreenshot`
   into a PNG artifact (raylib desktop exposes `takeScreenshot`; see
   `asset-streaming-smoke`'s `main_scene.zig`).

## Games delivered in this repo

Five games (#1–#5) are scaffolded and verified end to end
(`assembler install` → `generate` → `zig build` → deterministic headless
run on `.null`):

| Game            | Verified transcript (headless)                                   |
|-----------------|------------------------------------------------------------------|
| parallax-scroll | `[parallax] frame=N scrolled=6` — sky + hud stay fixed           |
| scripting-smoke | ordered `LUA_*` milestone sequence (declare-mode round-trip)     |
| ruby-orbit      | ordered `RUBY_*` sequence (`RUBY_INIT … RUBY_MOVED_X_50.0 … RUBY_DONE`) |
| coin-collector  | `score`/`coins_left` per frame, `[collector] cleared` on frame 87 |
| event-relay     | `[relay] emit n=N` paired with the hook's `[relay] pulse n=N`     |

Each is the concrete template its grid row follows, and each lifts into
the showcase repo's `games/<name>/` with only the version-pin edit
described above (plus, for the scripting games, swapping the two `local:`
deps — the plugin and labelle-null — for registry pins once a
touchpoint-carrying labelle-null release exists).
