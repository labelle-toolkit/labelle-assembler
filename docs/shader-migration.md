# Migrating to game-owned effects

The shader implementation is a coordinated, unreleased change across core,
gfx, engine, bgfx, assembler and CLI. The condenser example uses explicit local
dependencies. Do not substitute published versions and expect the new API.

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
   core. `.backend = .bgfx` with no `.backend_package` resolves through that
   default, so a default-backend project otherwise compiles a backend that
   still names the removed water contract against the new core — the failure
   mode assembler#731 repaired in the other direction.
6. Replace the example's local dependency selections with those released
   versions (done: `examples/condenser` pins core 2.0.0, gfx 2.0.0, engine
   3.0.0 and bgfx 0.21.0), and add it to the examples-integration lane
   (assembler#732: that lane only GENERATES bgfx examples today, so a compile
   break in a pinned backend passes unnoticed — build it, do not only
   generate it).

Steps 1-4 and 6 have shipped (core v2.0.0, gfx v2.0.0, engine v3.0.0, bgfx
v0.21.0). Step 5 is pending on the assembler side and follows the core >= 2.0.0
floor change (assembler#736). To develop against unreleased sibling checkouts,
switch the example's four pins back to `local:../../../labelle-*`. Standalone
BGFX tests require `-Dcore-source=<core>/src/root.zig`.

## Validation limits

The condenser compiles water, fog and lamp to SPIR-V, GLSL, ESSL and Metal.
Windows/Vulkan execution covers ten deterministic scene scenarios, including
per-instance isolation and independent effect disabling. Its generated unit
suite passes 18 tests. See the example README for controls and reproduction.

Core, gfx, BGFX, assembler and CLI suites and engine's focused shader regression
suite pass. The broad engine suite encounters Windows preview/network and time
API failures; it is not reported as passing. Android, browser and Metal device
execution have not been verified here. Direct3D runtime materials are unsupported.
