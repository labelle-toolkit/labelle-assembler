# RFC: Surface-loss adapter slot cleanup

Status: round 2 author revision (November 7, 2026). Round 1
([#454 comment](https://github.com/labelle-toolkit/labelle-assembler/issues/454#issuecomment-6713505823))
reviewed a 176-line revision that was never committed to this branch; this
revision is authored directly on the branch, addresses that round's blocking
findings, and adds POC evidence for all six owner decisions. Recommendations
in "Alternatives and owner decisions" are **not decisions**. No implementation
approval.

Tracking issue: https://github.com/labelle-toolkit/labelle-assembler/issues/454

## Scope and source evidence

This RFC starts from the current Ready item. Historical statements below are evidence to verify against the pinned source snapshots, not established facts about current main. Items 1 and 2 are recorded as completed by PR #455; do not reopen them without new evidence. The remaining substantive scope is generated adapter slot cleanup on surface loss, potentially requiring an engine hook. Fixture slimming is optional and its inclusion remains a product decision.

The review input also includes `inputs/related-source/labelle-engine/`, pinned at be0991eabf5ff4bf75700ceab7bfc2365c7ce22b, and `inputs/related-sources.json`. Inspect the actual lifetime, ownership and recreation paths across both repositories. Do not execute repository scripts or tests during the RFC review.

## Problem and historical issue context

Small cleanups left behind by the backend-extraction work (epic #386, now complete). Low-risk, non-blocking.

### 1. Re-check the callback-external guard
`src/codegen/lifecycle/render.zig:195` raises `error.ExternalCallbackBackendUnsupported`. Now that **sokol (callback loop_style) works as an external backend via the manifest splice**, this guard may be dead code (removable) or need narrowing like the bgfx-android case (#416). Verify which and clean up.

### 2. Stale comment in `src/cache_cmd.zig:545`
Comment reads "…no-op when null is still bundled (effectivePkg == null)". `null` is no longer bundled (extracted to `labelle-null`). Update the comment (flagged as out-of-scope during the sokol flip).

### 3. Surface-loss leak-guard (from Phase-4 on-device validation)
Adapter `slots[]` accumulate across many surface destroy/recreate cycles (shared `asset_wiring.zig` codegen). Needs an engine-driven `clearSlots` on surface loss. GPU mem plateaued in the 9-cycle Tab A7 test, but the slot array itself grows unbounded over a long session.

### 4. (Cosmetic) sokol test fixture
`backends/sokol` (+ `backends/sdl_gamepad` / `backends/android_gamepad` sub-packages) is retained in-tree purely to give the generic codegen tests an offline manifest to read (pinned via `local:backends/sokol` + `project_dir`). Could eventually be slimmed to a minimal synthetic fixture instead of the full real backend. Purely cosmetic — production never bundles it.

Ref: epic #386.

---

## Cleanup audit — 2026-09-08

Items 1 and 2 were completed by #455, as established in the July 11 audit above. The remaining work is:

- [ ] Clear generated adapter slots on surface loss, with the required engine hook. No `clearSlots` seam was found in the current assembler/engine source; later direct-texture reupload support does not itself prove these arrays are cleared.
- [ ] Optionally slim the retained backend test fixtures.

The title now reflects the outstanding work; the original checklist and audit history are retained.


## Mechanism (verified)

Baseline: assembler `main` `5718043` (0.126.0, default engine pin 3.4.1),
engine `main` `be0991e` (4.1.1), labelle-gfx 2.2.0 (default pin) and 2.2.1.

- The generated `ImageBackendAdapter` (`src/codegen/blocks/asset_wiring.zig`)
  holds a fixed `slots` table (`MAX_IMAGE_ASSETS = 1024`, `:59`, `:73`).
  `upload` takes the lowest free index (`:123-130`, `ImageSlotsExhausted` when
  none is free), registers `CATALOG_ID_BASE + idx` with the renderer
  (`registerCatalogTexture`, `:155-156`) and returns that as the handle.
  `unload` destroys whatever currently occupies the index (`:172-188`); it has
  no generation check. Audio (`:242`) and font (`:397`) adapters have the same
  shape.
- On `Game.surfaceLost` (engine `lifecycle_mixin.zig:494-521`) the catalog's
  `invalidateGpuResources` (`catalog/engine.zig:710-725`) nulls `.ready` image
  resources **without** calling the loader's free, because the context is
  dead. On restore, `reenqueueGpuResident` (`:738-756`) uploads them again.
  Nothing reaches the generated adapter, so every pre-loss slot stays occupied
  and each restore takes N fresh slots.
- Result: occupancy grows by N (resident images) per cycle, and restore fails
  with `ImageSlotsExhausted` on cycle ⌊1024 / N⌋ (measured below). The 9-cycle
  Tab A7 run never approached that bound, which is why GPU memory looked flat.
- Fonts have the same defect. The catalog skips `.font` entries on loss
  (`engine.zig:714`) and only parks `.image` uploads while `gpu_alive` is false
  (`isGpuUploadResult`, `:683-690`), but every backend with catalog fonts
  creates a GPU texture for the atlas (sokol `sg.makeImage`, `font.zig:359`;
  bgfx `createTexture2D`; raylib `loadTextureFromImage`).

## Proposed contract

1. **Trigger.** The image adapter's slots are cleared exactly once per
   `Game.surfaceLost`, from inside the engine, **after**
   `invalidateGpuResources` has nulled every `.ready` image resource. The
   call site is `Game.surfaceLost`, immediately after that call; not inside
   `invalidateGpuResources`, and not in a backend template.
2. **Clear means forget, never destroy.** The clear frees CPU slot metadata
   only. It must not call any backend or renderer destroy on handles from the
   dead context.
3. **Idempotence.** A second loss without an intervening restore clears an
   already empty table; repeated loss/restore cycles keep occupancy bounded.
4. **Handle generations.** Handles encode a per-slot generation
   (`CATALOG_ID_BASE | gen << 10 | idx`, under `1 << 25`). The clear bumps the
   generation of every slot it frees; `unload` of a handle whose generation
   does not match is a no-op. This makes a stale unload safe both before and
   after index reuse.
5. **Caller contract.** Holders of pre-loss handles must re-resolve them after
   restore. The engine catalog does this for catalog entries; code holding a
   raw `FontId`/texture handle across a loss (for example one-shot
   `setTextFont`) must look it up again.
6. **Renderer registry.** Stale catalog-texture entries in the renderer's map
   stay resident until labelle-gfx can forget a catalog key without
   destroying it (see `renderer-registry-scope`). Generations stop them from
   being overwritten into a wrong-texture alias; they are a bounded leak, not a
   cross-wire.
7. **Fonts.** If `font-adapter-scope` (b) is chosen, items 1–5 apply equally to
   `FontBackendAdapter`, with the engine treating `.font` as GPU-resident
   (invalidate, park uploads while dead, re-enqueue on restore).
8. **Generated-code compatibility.** For projects whose engine pin is a
   release below `MIN_ENGINE_FOR_SLOT_CLEAR` (`engineFeatureSupport == .no`),
   generated bytes must not change. Release pins at or above the floor, and
   `.unverifiable` dev/local pins, receive the `@hasField`-guarded emission,
   which must compile, and act as a no-op, against an engine that lacks the
   seam. Changing default pins is out of scope for this RFC.
9. **Invariant.** Whenever the asset pump is idle, the set of occupied image
   slots equals the set of handles held by `.ready` image catalog entries, one
   to one. "Same occupancy after a cycle" holds only for a stable referenced
   asset set once restore uploads complete; the general guarantee is the
   absence of retained pre-loss occupancy.

Round 1's blocking finding that the old item 8 contradicted the version
decision is resolved by rewording item 8 around the version gate: under it,
option (c) satisfies the contract, (a) is excluded, and (b) is deferred.

## Alternatives and owner decisions

Six POCs on November 7 prototyped every option against the baseline above.
They are evidence only, on local `poc/454-*` branches (assembler) and
scratch engine/gfx clones; none is a proposed implementation. **Each
"Recommended" entry is a recommendation, not a decision.**

| Decision | Recommended | Deciding evidence |
| --- | --- | --- |
| `hook-mechanism` | A: optional `invalidate_all` on `engine.ImageBackend` | 22 engine lines; B fails to compile for event-less projects and breaks 10 tests |
| `engine-version-coordination` | (c) gate on `engineFeatureSupport` | All goldens byte-identical at the default pin; (a) changes 3 goldens |
| `renderer-registry-scope` | (a) slots only + handle generations; gfx ticket first | (b) is a no-op on gfx 2.2.0/2.2.1 |
| `font-adapter-scope` | (b) cover fonts now | Same defect; images-only leaves a cross-wire on bgfx, the backend that fires loss today |
| `fixture-slimming` | (b) split into its own issue | No coupling: adapter goldens byte-identical after slimming |
| `device-validation-gate` | (a) host tests close #454; device run as follow-up | Host harness reproduces ⌊1024/N⌋ exactly and holds 1,200 cycles flat |

### hook-mechanism

- **A (built).** Engine: `ImageBackend.invalidate_all: ?*const fn () void =
  null`, an `ImageLoader.invalidateAll()` forwarder, and the call in
  `Game.surfaceLost` right after `invalidateGpuResources` (22 lines).
  Assembler: `clearSlots()` plus an install guarded by
  `@hasField(engine.ImageBackend, "invalidate_all")` that re-calls
  `setBackend` on `currentBackend()` with the field set, so the existing
  `setBackend(.{…})` literal is untouched (+9 lines per generated main). Round
  1 said the loader's backend variable is private; `ImageLoader.currentBackend()`
  is already public, so the install needs no new engine accessor (the
  forwarder is still the cleaner engine-side call). Without the hook,
  occupancy grew by 4 per cycle; with it, 40 cycles (160 uploads into 64
  slots) stayed flat at 4, the hook ran exactly once per loss, synchronously,
  and never while a catalog image resource was still live. The emitted block
  compiles against both the POC engine and unmodified `main` (where it folds
  away).
- **B (built, reverted).** Worse than round 1 estimated. labelle-core
  `MergeHooks` rejects a two-parameter handler whose name is not in the
  payload union ("Handler 'engine__surface_lost' … doesn't match any event"),
  so every event-less project fails to compile unless the assembler
  synthesizes the variant. The variant has to go into `GameEvents` (because
  `emitEngineEventImpl` checks `GameEvents`), which turns on `has_events` and
  the event buffer for every game, and plugin-events would need deduplication
  against it. The adapter is declared inside `main()`/`init()`, so a
  module-level receiver needs an extra function-pointer global. 10 existing
  tests broke: 3 main goldens, a receiver-id table, 2 hook-route
  report-vs-tuple drift tests and 3 plugin-event/flow shape tests. Timing was
  not the problem: appended last, the receiver runs synchronously after
  nulling, and `surface_lost` is not consumable.
- **C.** The `surfaceLost` trampoline lives in a backend repo
  (`labelle-bgfx/templates/android.txt:450`); sokol templates do not wire
  `surfaceLost` at all, and the adapter is function-local there too.
- **D.** Still needs an engine change to `free`, and changes the meaning of
  `unload` for every backend. No advantage over A.

### engine-version-coordination

- **(c) (built).** `MIN_ENGINE_FOR_SLOT_CLEAR = "4.2.0"` (the first engine
  release that would carry the seam; adjust when it ships). `.no` emits the
  old bytes; `.yes` and `.unverifiable` emit the guarded block. Full suite
  green; all 3 main goldens and every `.build.zig` golden byte-identical at
  pin 3.4.1. 4.1.1 output equals 3.4.1 byte for byte; 4.2.0 differs only by
  the two inserted blocks; `local:`, `main` and branch pins emit (and compile
  either way thanks to `@hasField`).
- **(a).** Exactly the 3 main goldens change (+9 lines each).
- **(b), a default pin bump, is its own decision.** It needs engine 3.4.1 →
  ≥ 4.2.0 (`build.zig:90`) and core 2.1.0 → ≥ 2.2.0 (`build.zig:89`), because
  of the compile-break trio floor (`version_floors.zig:287`; gfx 2.2.0 still
  satisfies its floor), plus the hard-coded fixtures at `version_floors.zig:820`,
  `init_cmd.zig:983`, `upgrade_backend.zig:647/652/815`,
  `test/clean_home_install_e2e.py:52,57` and the `build.zig:78-88` comment.
  It is a major bump (3 → 4) under the major-only compatibility policy.

### renderer-registry-scope

labelle-gfx (same registry code in 2.2.0 and 2.2.1):

- Re-registering a live key overwrites the entry without destroying the old
  GPU handle (`retained_engine.zig:888-935`); shader materials bound to that
  key are destroyed with a warning.
- `invalidateTexture` returns early for every key below
  `TEXTURE_KEY_BASE = 1 << 31` (`:782-793`, `:138`), and catalog keys are
  `1 << 24 + idx`. A gfx test pins this (`test/root_test.zig:316`). Option (b)
  compiles (`@hasDecl` is true) but does nothing.
- gfx never drops catalog entries on surface loss; they stay
  `gpu_resident = true`, and `deinit` (`:391-400`) unloads every one, which on
  labelle-bgfx destroys whatever texture now sits in the recycled backend
  slot (`texture.zig:485-491`). No gfx call forgets a catalog key without
  destroying it.

Harness (generated adapter, real gfx `RetainedEngine`, core `MockBackend`):
4 images, loss, clear, only 2 restored, one unrelated direct upload.

| Variant | Restored keys | Stale entries (resident) | Pre-loss handle[2] samples | Entries aliasing another backend id |
| --- | --- | --- | --- | --- |
| today (no clear) | +4, +5 | 4 (4) | the unrelated upload | 5 |
| (a) slots only | +0, +1 | 2 (2) | the unrelated upload | 1 |
| (b) on stock gfx | as (a) | 2 (2) | the unrelated upload | 1 |
| (b) on patched gfx | +0, +1 | 2 (0) | nothing | 0 |

(a) introduces one new risk (astra, confirmed): after reuse, unloading a
pre-loss handle frees the live replacement; today that cannot happen because
restore never reuses an index. Handle generations (contract item 4; a 2 KiB
`u16` array and about 4 changed lines) make stale unloads a no-op before and
after reuse. With generations, new keys no longer overwrite old ones, so the
pre-loss keys stay in the registry, which is no worse than today. A `@hasDecl`
gate cannot tell whether gfx honors catalog keys, so (b) needs a gfx
capability marker. Recommended order: ship (a) + generations; open a gfx
ticket (a 7-line POC patch: mark catalog keys non-resident in
`invalidateTexture`, draw nothing for them, expose a marker; it intentionally
fails the pinning gfx test); add (b) gated on that marker afterwards.

Multi-world (gemini): catalog textures are only ever registered on
`renderer_ref`, so a single-renderer invalidate covers every catalog entry;
the per-world walk is not needed. Separate defect found by reading (not run
end to end): `renderer_ref` points at the first world's renderer, that world
is unnamed (`game.zig:639`), and the first `setActiveWorld` destroys it
(`world_mixin.zig:57-61`), leaving `renderer_ref` dangling and other worlds
without catalog entries. This should get its own issue.

### font-adapter-scope

Engine tests (mock font backend) on `be0991e` confirm both round-1 claims: a
`.ready` font keeps its pre-loss `FontId` across loss/restore and is never
re-uploaded, and its later `release` unloads the dead handle; and a font
decode landing during loss is drained by `pump()` into `backend.upload` while
`gpu_alive == false` (latent today, since bgfx stops ticking while the surface
is down).

| Backend | Font upload creates a GPU texture? | Fires surface loss? |
| --- | --- | --- |
| sokol | yes (`sg.makeImage`, `font.zig:359`) | declares `.surface_loss`, but no `surfaceLost` hook found in the repo |
| bgfx | yes (`createTexture2D`, `font.zig:729`) plus a backend font registry | yes, via Android glue |
| raylib | yes (`loadTextureFromImage`, `gfx.zig:729`) | no |
| sdl / wgpu | no catalog fonts | no |

Under (a), bgfx's teardown already wipes its font registry
(`releaseAllCatalogFonts`), so after resume all catalog text falls back to the
built-in face, and a later `release` destroys the dead atlas by its old index,
which bgfx reuses after re-init: the engine#821 cross-wire class. (b) as built:
engine `isGpuResidentKind` (image or font) for invalidate, re-enqueue and the
upload park, plus `FontBackend.invalidate_all` (+45 lines); assembler
`FontBackendAdapter.invalidateAll` that frees slots and unregisters registry
bindings without `unloadFontAtlas`, behind `@hasField` (+30 lines). No goldens
changed; one string-pin test line did. Risk: a raw `FontId` held across loss
can alias another font after slot reuse; the GUI re-resolves by name every
frame, one-shot callers need contract item 5, and generations (item 4) close
it. (b) depends on hook-mechanism A.

### fixture-slimming

The tests read only the manifests, `templates/desktop.txt`/`mobile.txt`, two
build fragments and `backend.hook.zig` from `backends/sokol`; only two tests
(`test/window_subfolders_imgui_tests.zig`) read real backend code, and nothing
reads `sdl_gamepad`/`android_gamepad` (their staging in `src/deps_linker.zig`
is already dead). A synthetic fixture (ABI-only hook, dependency-free
`build.zig.zon`) cuts 56 files / 24,028 lines to 8 / 447 with zero golden
changes; the only lost tests are those two plus 15 unit tests inside the real
hook, which belong in labelle-sokol. The in-tree copy has already drifted from
labelle-sokol (manifest fields, a `wasm.entry` pointing at a template the
fixture lacks, 688 hook lines), so it gives no real drift protection. There is
no coupling to the slot work: the three adapter goldens were byte-identical
after slimming. Draft issue: replace the fixture with a labelled synthetic
one, move the hook and `window.zig` tests to labelle-sokol, remove the dead
gamepad staging, update the 15 `local:backends/sokol` references across seven
files, and optionally add a CI diff against the pinned labelle-sokol manifest.

### device-validation-gate

Host harness: the assembler's own emitter generates the adapter (identical to
`test/goldens/sokol_ios_main.zig:450-522` apart from indentation), run against
the real engine `AssetCatalog` and image loader with a mock GPU that stamps
textures with a context epoch so dead-context destroys are counted.

| N | First failing cycle today | Occupancy entering it |
| --- | --- | --- |
| 4 | 256 | 1024 |
| 16 | 64 | 1024 |
| 64 | 16 | 1024 |
| 100 | 10 | 1000 |

With `clearSlots` after `invalidateGpuResources`, occupancy stayed at N with
N live textures and zero stale destroys for 1,200 cycles at N = 4, 16 and 64,
for 300 cycles with real worker threads at N = 64, and for 1,200 cycles at
`MAX = 32`. Invariant 9 held every cycle, including an asset released during
loss (today 28 occupied vs 12 ready; fixed 12 = 12), an enqueue overflow
during restore (200 images over a 3 × 64 request ring) and three injected
upload failures (197 = 197). After one cycle all 64 images had different
handles but equal handle sets, so tests must assert set and occupancy
equality, never per-image handles.

`MAX_IMAGE_ASSETS` can be shrunk for tests with an `ImageWiringOptions
{ max_image_assets, emit_clear_slots }` struct (~25 lines; defaults keep bytes
identical). Device-only residue: real EGL/GL context destruction and driver
handle recycling, GPU memory, `onAppCmd` TERM_WINDOW/INIT_WINDOW ordering and
threading, and external backend templates. None affects the slot arithmetic.

## Implementation plan and validation

Planned, not executed, unless stated as POC evidence above.

1. **Engine (minor release, e.g. 4.2.0).** `ImageBackend.invalidate_all` and
   `ImageLoader.invalidateAll`; call it in `Game.surfaceLost` after
   `invalidateGpuResources`. If fonts are in scope, `isGpuResidentKind` and
   `FontBackend.invalidate_all`. Tests: loss/restore with a mock backend
   (hook called once per loss, after nulling); font re-upload and upload
   parking.
2. **Assembler.** `clearSlots` / `invalidateAll` with handle generations in
   the image (and font) adapters; `@hasField`-guarded install; emission gated
   on `engineFeatureSupport(cfg.engine_version, MIN_ENGINE_FOR_SLOT_CLEAR)`;
   `ImageWiringOptions` for a test-sized table.
3. **Assembler tests.** Golden byte-identity below the floor; emission at and
   above it and for dev pins; a compile harness against engines with and
   without the seam; a host loss-cycle harness asserting invariant 9 beyond
   ⌊MAX / N⌋ cycles; a stale unload right after clear **before** any reuse
   (no-op), and a stale unload after reuse (no-op only because of
   generations); set equality instead of handle equality.
4. **In-tree call path.** Add a minimal fixture window stub (empty
   `surfaceLost`/`surfaceRestored` hooks plus a test-only cycle export) so the
   generated `Game.surfaceLost` path runs on desktop.
5. **Follow-ups (separate issues).** labelle-gfx catalog-key invalidation and
   capability marker, then `renderer-registry-scope` (b); the dangling
   `renderer_ref` after the first `setActiveWorld`; sokol declaring
   `.surface_loss` without wiring `surfaceLost`; fixture slimming; default pin
   bump; one bounded on-device Android loss/restore run past ⌊1024 / N⌋
   cycles.

## Review gate

Four independent reviewers must inspect one immutable document hash. Later document changes invalidate prior approvals. All findings and limitations remain visible. Readiness requires resolving blocking objections and owner decisions; implementation requires explicit approval of the resulting revision.
