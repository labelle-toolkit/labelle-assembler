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
| `parallax-scroll` *(new)*     | `.null`        | **showcase seed** — camera layers + parallax scroll |

Grounded feature surfaces available today (from these fixtures + the
sibling packages): sprites + `AnimationDef` cycling, camera-layer stack
(`labelle-gfx/src/layer.zig`: `world` / `screen` / `screen_fill`), packs
(`docs/packs.md`), flows, asset streaming, tilemaps (`.tmx` embedding,
T2 Phase 4 / #560), and scripting languages via `labelle-scripting`
(lua, ruby). Materials are gated on gfx#305 and are therefore a
*deferred* showcase entry, not a launch one.

## Proposed showcase games

Ordered by readiness. Each is a complete game, each pins a distinct
feature × backend cell so the set doubles as a cross-backend conformance
grid. Backend column = the backend the game *ships on* (all remain
backend-selectable; the headless ones also run in CI).

| # | Game                | Primary feature                          | Ships on   | CI assertion            | Status / seed candidate            |
|---|---------------------|------------------------------------------|------------|-------------------------|------------------------------------|
| 1 | **parallax-scroll** | camera layers + parallax (`screen_fill` / `world` / `screen`) | `.null` (→ raylib/bgfx) | transcript (`scrolled=N`) | **scaffolded + verified** (this repo) |
| 2 | **scripting-smoke** | Lua gameplay script via `labelle-scripting` | raylib     | transcript              | ticket seed — lua game             |
| 3 | **ruby-arena**      | Ruby gameplay script (shape ports from labelle-scripting's ruby example) | raylib | transcript              | ticket seed — ruby example         |
| 4 | **pack-city**       | packs wall as a real game (bgfx-wasm)    | bgfx-wasm  | build + screenshot      | ticket seed — packs validation game|
| 5 | **sprite-runner**   | sprite atlas + `AnimationDef` animation  | sokol      | screenshot              | derives from asset-streaming-smoke |
| 6 | **tile-explorer**   | `.tmx` tilemap + camera follow           | raylib     | screenshot              | uses T2 Phase 4 tilemap embedding  |
| 7 | **material-demo**   | materials / shaders                      | bgfx/wgpu  | screenshot              | **deferred** — blocked on gfx#305  |

Games 2–4 are the ticket's explicit seed candidates. 5–6 round out the
sprite/animation and tilemap surfaces. 7 is deferred until gfx#305 lands.

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

## Seed delivered in this PR

`examples/parallax-scroll/` is game #1, scaffolded and verified end to
end in this repo:

```
$ assembler install  --project-root examples/parallax-scroll
$ assembler generate --project-root examples/parallax-scroll   # → .labelle/null_desktop/
$ cd examples/parallax-scroll/.labelle/null_desktop && zig build
$ ./zig-out/bin/parallax_scroll
[parallax] frame=1 scrolled=6
… deterministic, clean exit after LABELLE_NULL_FRAMES frames …
```

It is the concrete template the remaining games follow, and it can be
lifted into the showcase repo's `games/parallax-scroll/` with only the
version-pin edit described above.
