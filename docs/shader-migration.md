# Migrating to game-owned effects

The shader implementation is a coordinated change across core, gfx, engine,
bgfx, assembler and CLI. The toolkit side has shipped: core 2.0.0, gfx 2.0.0,
engine 3.0.0 and bgfx 0.21.0 are released, and `examples/condenser` pins those
releases (no local sibling checkouts). Older releases do not carry the generic
material contract (v2); a game that adds `materials/` must resolve those
versions or newer.

## Ownership

- Core defines the typed material contract and opaque runtime handles.
- Gfx resolves texture IDs and dispatches generic material draws.
- Engine owns entity bindings, catalog pins and cleanup across scene/GPU lifetimes.
- BGFX owns GPU programs, uniforms, instance values and resource validation.
- Assembler discovers material definitions, compiles variants and generates imports.
- CLI validates an explicitly configured host shader compiler.
- The game owns shader sources, components, prefabs, simulation and effect controls.

After this shared infrastructure is released, adding another sprite effect is a
game change: add its material definition/source, component and binding system.
No water, fog or lamp effect registration is required in the toolkit repositories.

## Breaking changes

The specialized PixelWater contract, facade, engine simulation/authoring and
BGFX implementation have been removed. Existing games must migrate their water
state and update logic into game components, as demonstrated by `WaterShader`
in `examples/condenser`. The generic material ABI is version 2; rebuild the
coordinated packages together. Do not mix old compiled material layouts.

`WaterShader`, `FogShader` and `LampShader` are ordinary game component names.
Their shader descriptors live separately under `materials/<name>/material.json`.
Shader source is BGFX shader language; JSON specifies its interface and targets.
Runtime handles must not be authored in prefabs or serialized as durable state.

## Release sequence

1. Release the new core contract.
2. Update the BGFX core dependency pin and release the generic backend and gfx.
3. Release engine's generic entity material API.
4. Release assembler's shader pipeline and CLI integration.
5. Bump the bgfx entry of `ProjectConfig.builtinProvider` (`src/config.zig`) to
   the released contract-v2 backend, in the SAME change that adopts the new
   core (done: bgfx 0.21.0 with the core 2.0.0 / gfx 2.0.0 / engine 3.0.0
   scaffold trio in `build.zig`). `.backend = .bgfx` with no
   `.backend_package` resolves through that default, so bumping either side
   alone ships a default that fails at the first `labelle build` — the
   failure mode assembler#731 repaired in the other direction.
   `src/init_cmd.zig`'s `bgfx_core_floors` carries the bgfx >= 0.21.0 →
   core >= 2.0.0 hard floor, and `material_pipeline` rejects an explicit
   pre-contract-v2 `.backend_package` / `.core_version` pin at generate time
   for a project that owns `materials/`.
6. Replace the example's local dependency selections with those released
   versions (done: `examples/condenser` pins core 2.0.0, gfx 2.0.0, engine
   3.0.0 and bgfx 0.21.0), and add it to the examples-integration lane
   (assembler#732: that lane only GENERATES bgfx examples today, so a compile
   break in a pinned backend passes unnoticed — build it, do not only
   generate it).

All six steps have shipped (core v2.0.0, gfx v2.0.0, engine v3.0.0, bgfx
v0.21.0; assembler defaults in PR #733). A fresh `labelle init --backend=bgfx`
resolves the contract-v2 stack and can own `materials/` with no explicit pins.
To develop against unreleased sibling checkouts, switch the example's four pins
back to `local:../../../labelle-*`. Standalone BGFX tests require
`-Dcore-source=<core>/src/root.zig`.

## Validation

The condenser compiles water, fog, lamp and mist to SPIR-V, GLSL, ESSL and
Metal. Windows/Vulkan execution covers the deterministic scene scenarios in the
example README (16 native scenarios, including per-instance isolation and
independent effect disabling). Its generated unit suite passes 20 tests. See the
example README for controls and reproduction.

Verified live against the released pins:

- macOS/Metal: standalone `labelle run` of the condenser, four materials live
  (2/2 instances each), no degrade lines.
- Android/OpenGL ES: Galaxy Tab A7 (Adreno 610) through the CLI path, all eight
  material instances live at 62 fps.

Core, gfx, BGFX, assembler and CLI suites and engine's focused shader regression
suite pass. The broad engine suite encounters Windows preview/network and time
API failures; it is not reported as passing. Browser (wasm) execution has not
been verified. Direct3D runtime materials are unsupported.
