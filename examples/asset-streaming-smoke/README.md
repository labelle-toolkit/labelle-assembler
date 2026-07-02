# asset-streaming-smoke

End-to-end smoke test for the Asset Streaming RFC
([labelle-engine#437](https://github.com/labelle-toolkit/labelle-engine/issues/437)).
Tracks [labelle-assembler#55](https://github.com/labelle-toolkit/labelle-assembler/issues/55).

## What it demonstrates

1. `project.labelle` declares two atlases (`sprites`, `jump`) with no
   explicit `lazy =` — the assembler's lazy-inference pass
   (`src/lazy_inference.zig`) flips them to lazy because they appear
   in `scenes/main.jsonc`'s `"assets":` block. The generated
   `main.zig` emits `registerAtlasFromMemory` for each (parse JSON,
   defer PNG decode) instead of `loadAtlasFromMemory`.
2. The assembler emits `SceneAssetManifests.entries` and a
   `setSceneAssets` loop so every scene's manifest is attached to its
   `SceneEntry.assets` at init time.
3. `scenes/loading.jsonc` has an empty `"assets": []` block — it
   loads instantly on `initial_prefab = "loading"`.
4. `scripts/loading/loading_controller.zig` reads
   `game.scenes.get("main").?.assets`, calls `loadAtlasIfNeeded` for
   one pending atlas per frame, draws a screen-space progress bar
   via gizmos, and `queueSceneChange("main")` once every atlas is
   ready.
5. After transition, `scenes/main.jsonc`'s sprite entities render
   against the newly-uploaded textures, proving the full register →
   decode → GPU-upload → atlas lookup → draw pipeline.

## Relationship to the RFC end-state

The RFC's target loading-controller body is two lines:

```zig
state.bar_scale = game.assets.progress(target.assets);
if (game.assets.allReady(target.assets)) game.setScene("main");
```

That API depends on:

- `game.assets` being wired as an `AssetCatalog` field on `Game`
  (not yet on `main` — see the comment in
  `labelle-engine/src/root.zig` around the `AssetCatalog` export).
- `labelle-engine` #444 (scene_assets acquire/release hook), which
  walks `SceneEntry.assets` on `setScene` and calls
  `catalog.acquire` per name.
- `labelle-assembler` #54 ("wire engine.ImageLoader.setBackend at
  Game.init"), which closes the `error.ImageBackendNotInitialized`
  gate on the image loader vtable.

As of the initial commit of this example:

- #54 is **open**, not merged — branching off `origin/main` means
  the smoke test deliberately avoids `AssetCatalog.acquire` on
  images and uses the legacy `loadAtlasIfNeeded` path that shipped
  with labelle-engine #434.
- #444 does not exist as a merged PR — scene changes do not
  auto-acquire assets, so the smoke test iterates the manifest
  manually from its loading controller.

When those land, the controller can collapse to the two-line RFC
form without changing `project.labelle`, `scenes/main.jsonc`, or
`SceneAssetManifests` — the codegen contract this example exercises
is identical to what the async path will consume.

## Backend: `.null` (headless)

This fixture tests the assembler's asset-streaming **codegen**
(lazy-inference → `registerAtlasFromMemory`, `SceneAssetManifests`), not
rendering, so it targets the backend-agnostic headless `.null` backend
(labelle-assembler#520). Generate + build + a frame-capped run all work
with no display / GPU. To see the sprites actually render, point
`project.labelle` at a windowed backend (`.raylib`) and run locally.

## Running locally (headless, null)

```sh
cd examples/asset-streaming-smoke
labelle-assembler generate --project-root .
cd .labelle/null_desktop
zig build
LABELLE_NULL_FRAMES=10 ./zig-out/bin/asset_streaming_smoke   # runs N frames, exits rc=0
```

The null backend has no GPU to upload textures to, so it exercises the
generated streaming main loop + `ImageBackendAdapter` wiring headless
rather than actually drawing the sprites. For the visual round-trip
(progress bar → two sprites in the top-right quadrant → `smoke-test.png`)
switch the backend to `.raylib` and run with a display.

## CI integration

Runs in the `Examples integration test` job. The step invokes the
assembler binary directly (labelle-cli is pinned to a release that
predates `.null`), asserts the streaming codegen is emitted
(`registerAtlasFromMemory` / `SceneAssetManifests`), builds
`.labelle/null_desktop`, and runs the binary frame-capped for a clean
headless exit — no display required. Real GPU texture upload / on-screen
render stays a local `.raylib` check.
