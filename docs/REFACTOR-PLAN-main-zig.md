# Refactor plan: split `src/main_zig.zig`

**Status:** RFC. One PoC submodule (`src/codegen/scan.zig`) is extracted in this
PR. The rest of the cuts below are proposals, not commitments — the point of
landing this draft is to vet the approach before touching the orchestrator any
further.

**Ticket:** labelle-toolkit/labelle-assembler#183.

---

## Why this file is hard

`src/main_zig.zig` is the single file every backend × platform combination
flows through. The orchestrator (`generateMainZigFromTemplate`) renders ~18
named template slots, each into its own `Allocating` writer, then hands the
filled scalars to `tpl.renderDynamic` against the backend's main.zig template.
Any reordering of slot emission, any change to a `try w.writeAll(...)` string
literal, any allocator-lifetime shuffle, and the generated `main.zig` diff
shifts — which means downstream backends recompile differently or, worse, behave
differently. The contract is **bit-identical generated output for every
backend × platform combo**.

## Sections found (top-to-bottom)

| Lines       | Section                                          | Kind                                  |
|-------------|--------------------------------------------------|---------------------------------------|
| 1–14        | Imports + type aliases                            | header                                |
| 16–184      | `PluginEvent` / `PluginEvents` + discovery       | **scan: plugin events**               |
| 186–649     | `PluginFlowNode` / `PluginPinStyle` / `PluginCoercion` + discovery / dedupe | **scan: plugin flow decls** |
| 651–676     | `checkBasenameCollisions`, `hasContextEntry`     | validation helpers                    |
| 678–1066    | `writeImageBackendWiring` / `writeAudioBackendWiring` / `writeFontBackendWiring` | **block: asset backend wiring** (long emit-strings, no global state) |
| 1067–1389   | `writePluginControllersBlock` / `writePluginEventsBlock` / `writePluginFlowNodesBlock` / `writePluginPinStylesBlock` / `writePluginCoercionsBlock` | **block writers: plugin registries** (all called by orchestrator, all `pub`) |
| 1390–1443   | `dedupePinStyles`, `sanitizePluginIdent`         | scan support                          |
| 1454–1564   | `LoadStyle`, `extWithoutDot`, `isValidZigIdentifier`, `emitResourceLoad` | **block: resource loader emit**       |
| 1567–1637   | `validateResources`                              | validation                            |
| 1639–1824   | `buildSetupCode`                                 | **lifecycle: loop-backend setup**     |
| 1826–3021   | `PREVIEW_*` constants + 3 wiring helpers          | **preview-mode codegen** (~1200 lines of inline string literals, three backend variants: raylib desktop, sokol GL, sokol D3D11, sokol Metal) |
| 3022–3041   | `buildGuiDrawCode`                               | small block                           |
| 3043–3246   | `buildCallbackInitCode`, `buildImmersiveEntryCode`, `buildCallbackCleanupCode` | **lifecycle: callback-backend setup** |
| 3247–3373   | `writeZigString`, `writeSceneAssetManifests`, `writeSceneInitialStateManifests` | **block: scene manifests**            |
| 3398–3458   | `pathToIdent`, `pathToPascal`                    | **identifier helpers** (with tests)   |
| 3466–4560   | `generateMainZigFromTemplate` (the orchestrator) | **orchestrator** — wires 18 named scalars to the template |
| 4562–4601   | `generateGameLayers`, `generateResourceRegistry` | tiny block writers (one called from orchestrator only) |
| 4603–4692   | `pathToIdent` tests                              | tests                                 |

## Proposed module layout

```
src/codegen/
  scan.zig            # PluginEvent[s], PluginFlowDecls, PluginPinStyle, PluginCoercion,
                      # discoverPluginEvents, discoverPluginFlowDecls,
                      # discoverEventsFromRoot, scanFlowDeclsInSource,
                      # extractConstructsString, sanitizePluginIdent, dedupePinStyles
                      #   (~620 lines moved from main_zig.zig:16-649 + 1390-1443)
                      #   THIS IS THE PoC EXTRACTION IN THIS PR.
  idents.zig          # pathToIdent, pathToPascal, writeZigString, isValidZigIdentifier,
                      # extWithoutDot, + their tests (~150 lines)
  validate.zig        # checkBasenameCollisions, hasContextEntry, validateResources
  blocks/
    asset_wiring.zig  # writeImageBackendWiring, writeAudioBackendWiring,
                      # writeFontBackendWiring (~370 lines of pure emit)
    plugin_registries.zig  # writePluginControllersBlock, writePluginEventsBlock,
                           # writePluginFlowNodesBlock, writePluginPinStylesBlock,
                           # writePluginCoercionsBlock (~320 lines)
    resource_loader.zig    # LoadStyle, emitResourceLoad (~60 lines)
    scene_manifests.zig    # writeSceneAssetManifests, writeSceneInitialStateManifests
    layers_registry.zig    # generateGameLayers, generateResourceRegistry
  lifecycle/
    loop.zig          # buildSetupCode + buildGuiDrawCode (raylib desktop / sdl / bgfx / wgpu)
    callback.zig      # buildCallbackInitCode, buildImmersiveEntryCode,
                      # buildCallbackCleanupCode (sokol / wasm)
  preview.zig         # All PREVIEW_* string constants + the helper-selection logic.
                      # The biggest single cut (~1200 lines of inline templates)
                      # but it's also the most self-contained — every const is
                      # a pure string literal with no incoming references besides
                      # the orchestrator's `try std.mem.concat` calls.
  main_template.zig   # `generateMainZigFromTemplate` — the orchestrator, reduced to
                      # ~600-800 lines of "build N scalars, call tpl.renderDynamic"
src/main_zig.zig      # Reduced to a thin re-export shim for back-compat
                      # (so `root.zig` and `test/tests.zig` don't have to move).
```

**Target main_zig.zig size: < 200 lines** (a re-export shim).  
**Target main_template.zig size: 600–800 lines** (orchestrator only).

## Dependencies between sections

The dependency graph is mostly clean:

| Module                | Depends on                                     |
|-----------------------|------------------------------------------------|
| `idents.zig`          | std only                                        |
| `scan.zig`            | std, config, cache, script_scanner, `idents.sanitizePluginIdent` (currently in main_zig but trivially moves) |
| `validate.zig`        | std, config                                     |
| `blocks/asset_wiring.zig` | std only (pure string emit)                |
| `blocks/plugin_registries.zig` | std, scan types (PluginEvent etc.), config, `idents.pathToIdent` |
| `blocks/resource_loader.zig` | std, config, `idents.{isValidZigIdentifier, extWithoutDot}` |
| `blocks/scene_manifests.zig` | std, scene_manifest, `idents.{writeZigString, pathToIdent}` |
| `preview.zig`         | std only (all string constants)                 |
| `lifecycle/loop.zig`  | std, config, `blocks/*`, `idents.*`             |
| `lifecycle/callback.zig` | std, config, `blocks/*`, `idents.*`          |
| `main_template.zig`   | every module above + tpl + template strings     |

No cycles. `idents` is the leaf everyone reuses. `scan` and `preview` are
independently extractable.

## Risk assessment

| Section                      | Risk    | Why                                                  |
|------------------------------|---------|------------------------------------------------------|
| `scan.zig`                   | **low**  | Pure data collection, no template state, already has dedicated tests in `test/tests.zig`. **PoC choice.** |
| `idents.zig`                 | low     | Pure functions, exhaustive existing tests in main_zig.zig:4605-4691, but small enough that the move-cost / proof-value ratio is poor for a PoC. |
| `validate.zig`               | low     | Pure functions that write to stderr; no codegen output coupling. |
| `blocks/asset_wiring.zig`    | **low** | 370 lines of pure `try w.print(...)` with no state. Risk is purely textual — easy to verify with byte-identical diff. |
| `blocks/scene_manifests.zig` | low     | Pure functions over `SceneManifest` + writer. |
| `blocks/resource_loader.zig` | low-med | `emitResourceLoad` is called from BOTH lifecycle paths; needs both to come along simultaneously. |
| `blocks/plugin_registries.zig` | med  | 5 public functions called from multiple sites; depends on scan types. Move scan first, then this. |
| `preview.zig`                | med     | Huge string literals — high chance of accidental whitespace edit. Mitigated by `diff -q` against pre-/post-extraction generation. |
| `lifecycle/loop.zig`         | **high** | `buildSetupCode` orchestrates many `writeXxxWiring` calls + conditional logic on `cfg.resolved_gui` / `cfg.resources` / `cfg.plugins`. Moving it disrupts the assumed call-order with `writeImageBackendWiring`, `writeAudioBackendWiring`, `writeFontBackendWiring`, `emitResourceLoad`, etc. |
| `lifecycle/callback.zig`     | **high** | Same as loop, plus the sokol/wasm/Android branches. |
| `main_template.zig`          | **highest** | The orchestrator: 18 scalar slots, 3 lifecycle branches, ~1100 lines of carefully ordered scalar emission. Moving last, and only after every called helper is already extracted. |

## Proposed ordering

1. **`scan.zig`** — this PR (PoC).
2. `idents.zig` — small, mechanical, low value as a separate step but useful as a leaf everyone else depends on.
3. `validate.zig` — small + pure.
4. `blocks/asset_wiring.zig` — pure emit, large enough to be a meaningful demo of the block-extraction pattern.
5. `blocks/scene_manifests.zig` + `blocks/resource_loader.zig` — once `idents.zig` is in place.
6. `blocks/plugin_registries.zig` — depends on scan types + idents.
7. `preview.zig` — needs careful diff verification because of the 1200-line literal blob.
8. `lifecycle/loop.zig` then `lifecycle/callback.zig`.
9. `main_template.zig` — last; this is where the residual orchestrator lives.
10. Convert `main_zig.zig` to a thin re-export shim.

Each step ships as its own PR with the same bit-identical-output guarantee.

## Bit-identical verification approach

`scripts/gen_all_examples.sh` (added in this PR) regenerates every bundled
example (raylib, sokol, sokol_imgui, null, plugin-controllers, flows-smoke,
asset-streaming-smoke, bgfx, wgpu) and stages the output under `$OUT/<example>/`.

The before/after comparison is:

```bash
zig build
bash scripts/gen_all_examples.sh /tmp/asm-before    # on origin/main
git switch refactor/183-...
zig build
bash scripts/gen_all_examples.sh /tmp/asm-after
diff -r /tmp/asm-before /tmp/asm-after              # MUST be empty
```

`sokol_imgui` requires the `labelle-imgui` sibling repo to be present;
the script soft-fails for any example whose `install` step can't resolve
plugins.

**Note on `flow_catalog.json`.** The catalog file embeds a
`generated_at` ISO-8601 timestamp, so a naive `diff -r` shows a
1-line drift for it on every example. Every other generated artifact
(every `main.zig`, every `build.zig`, the entire `tests/` tree, etc.)
must be byte-identical — verified in this PR with:

```bash
find /tmp/asm-before -name "main.zig" -not -path "*/deps/*" | while read f; do
  after=${f/asm-before/asm-after}
  cmp -s "$f" "$after" || echo "DIFF: $f"
done
```

For this PoC the loop printed zero diffs across all 9 examples.

## What this PR does

1. Adds this plan doc.
2. Extracts `src/codegen/scan.zig` (~620 lines moved).
3. Leaves `main_zig.zig` with `pub` re-exports so `root.zig` + `test/tests.zig`
   keep their existing imports unchanged.
4. Adds `scripts/gen_all_examples.sh` for the bit-identical verification loop.
5. Verifies the generated output diff is empty for every bundled example.

## What this PR explicitly does NOT do

- Move any block writer.
- Move any lifecycle builder.
- Move the `PREVIEW_*` constants.
- Touch `generateMainZigFromTemplate`.
- Refactor any logic. Pure move + re-export.

Land this first, get review on the cut plan, then iterate.
