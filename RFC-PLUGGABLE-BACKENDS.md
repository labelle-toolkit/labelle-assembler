# RFC: Pluggable backends — make the assembler backend-agnostic

**Status:** Draft (revision 15 — **build-splice POC**: a throwaway manifest-driven generation path for sokol-desktop produced **byte-identical** `main.zig`+`build.zig` with **no `=> .sokol` branch** in the splice logic, builds + runs (headless screenshot). Verdict: **the build splice is VIABLE** — externalizing the embedded `build_zig.txt` sections was the *easy* part. Refines the model to **"manifest declarations + a fixed assembler-computed param set + a capability-flag-keyed lifecycle block library," NOT pure-data**; names the three things that stay code (per-placeholder param *value* computation, backend-specific *generated* lifecycle blocks, cross-compile link ordering) and the **name→package registry** that replaces `@tagName` as the pluggability seam (Phase 5). See *Build-splice POC verdict*. Rev 14 — **post-deployment**: Phases 1 & 2 SHIPPED (labelle-core #45 = the render contract in `backend_contract.zig`; labelle-audio v0.3.0 = shared `Mixer(Sink)` + `DeviceSink`, i16+f32; bgfx/wgpu/sokol collapsed, #388/#389/#390). Marks 1 & 2 DONE in the migration plan; **corrects the audio worked-example** — `raudio`/`sdl_audio` are *monolithic engines*, NOT shared-mixer device sinks (raylib/sdl delegate decode+mix wholesale, didn't collapse); adds the **composable-vs-monolithic provider** distinction to the resolver (Phase 5); flags the **WAV-shared/OGG-backend decode split** + the `writeAudioBackendWiring` codegen as **Phase-6 targets**; records that audio proved the *provider-composition* mechanic + no-codegen-change for a module dep, but **not** the run-loop splice — Phase 3 remains the gating crux. Rev 13 — addresses the rev-12 design review (7 points): names render's **draw vs loader sub-surfaces** (symmetric with the audio split); replaces the single under-specified `contextLost` with an explicit **`surfaceLost`/`surfaceRestored`** pair driving engine-side `gpuResourcesInvalidated` → `reuploadAssets` (no `deinit`/`init` overload); adds **provider identity** (canonical `<namespace>.<name>` IDs, `labelle.*` reserved, collision is a hard error), **capability negotiation** (declared `.capabilities` checked at resolve time → early project-level errors, not deep `@compileError`s), and **per-contract conformance suites** (behavior, not just `@hasDecl` shape) in a new "Opening the ecosystem" section; constrains the build hook to a versioned, documented `HookContext` (manifest ~95%, hook ~5%, no arbitrary work); migration pilots already split in rev 12 (audio=mechanics, sokol-desktop=full-stack, bgfx-Android=context gate). Rev 12 — addresses rev-11 review: distinguishes the runtime-playback `AudioInterface` (labelle-core, `playSound`/`stopSound`) from the separate audio *loader* contract (`Backend(Impl)` in labelle-engine/`audio_backend`, `decodeAudio`/`uploadSound`); fixes the versioning summary `N <= M` → `N == M` to match the strict-equality code sample; splits the pilot into step 3 (sokol-desktop, extraction mechanics) and a distinct step 4 (bgfx-Android GPU-context Accept gate); refreshes the build_zig.txt line count and the PR description; last "crate" → "package". Rev 11 — addresses rev-10 review: collapses `labelle-platform-abi` to `labelle-core` everywhere; splits the build hook into `pre_wire`/`post_wire` (sokol's `with_imgui` is a shipped consumer that needs `b.dependency`-time options); reframes the Accept gate to the bgfx-Android pilot (audio has zero GPU context, can't validate `contextLost`); fixes the `contract_version` check to gate on equality with direction-branched diagnostics (`t < p` catches new-core+old-backend, the dominant ecosystem failure). Rev 10 answered all six open questions. Rev 5: full render/audio contract surface incl. loaders/fonts; platform-qualified cascade `(platform, render)`; lazy-deps reframed as a requirement; Platform-packaging & manifest section; terminology + stale-wording fixes)

**All six open questions answered**, plus three ecosystem concerns added by the rev-12 review: Q#1 (lifecycle ABI), Q#2 (contract home + versioning), Q#3 (monorepo — resolved rev 3), Q#4 (gamepad as input-extension), Q#5 (build-graph manifest), Q#6 (GUI-bridge compatibility), and (rev 13) provider identity, capability negotiation, and conformance suites — see *Opening the ecosystem*. Residuals are migration-gated, not design-blockers — the RFC is ready to move from Draft to Accepted pending the **bgfx-Android pilot** (migration step 4) validating the `surfaceLost`/`surfaceRestored` re-upload story. The audio pilot (step 2) and sokol-desktop conversion (step 3) validate extraction mechanics but have zero surface-loss cycle to exercise.

**Tracking:** labelle-toolkit/labelle-assembler#377

**POC:** runnable Zig 0.16 prototypes on #377 — the runtime contracts (window / render / context handoff) and the codegen-splice (`Game`-lifecycle hooks vs entry-point shapes). Referenced throughout; together they de-risk both the runtime contract and the code-splice.

## Problem

labelle-assembler *is* the backend monorepo. It bundles every backend
(`raylib`, `sokol`, `bgfx`, `sdl`, `wgpu`, `null`) as `backends/<name>/`, each
carrying four runtime modules (`gfx.zig` / `window.zig` / `input.zig` /
`audio.zig`), codegen templates (`templates/{desktop,mobile}.txt`), a
`build.zig`, **and its native deps**. The native deps alone are ~4 GB (sokol
2.0 GB, bgfx 812 MB, wgpu 555 MB, raylib 335 MB) — carried by every clone of the
assembler, even though a project uses *one* backend.

Worse, the backend is a **closed enum** baked into the assembler
(`src/config.zig:50`):

```zig
pub const Backend = enum { raylib, sokol, sdl, bgfx, wgpu, null };
```

Adding a backend today means editing that enum, dropping a `backends/<name>/`
dir into the assembler, and extending the codegen switches. **A third party
cannot author and use their own backend without forking the assembler.**

This is in stark contrast to **plugins**, which are *open*: declared by name +
repo, resolved dynamically (`cache.resolvePlugin`), wired manifest-driven ("no
switch on type"). Backends are second-class citizens for no fundamental reason —
the goal of this RFC is to close that gap.

## Goals

- A backend is **authorable + droppable-in like a plugin**: a third party
  implements a contract and points `project.labelle` at their repo; the
  assembler never hears about it.
- The assembler becomes a **backend-agnostic generator** — no closed enum, no
  per-backend codegen switches, no bundled backend code or deps.
- A project fetches **only the one backend it uses** (the ~4 GB collapses to a
  single backend's deps).
- A clean, **versioned contract** boundary shared by gfx, engine, and backends.

## Non-goals

- No change to runtime rendering behaviour or performance — this is a refactor
  of *where code lives* and *how it's wired*, not what it does.
- No support for multiple simultaneous backends / GPU contexts in one process.
  These game backends are single-global-context (sokol/raylib/bgfx all are); the
  contract deliberately assumes one.
- Not rewriting gfx's renderer — only promoting its existing `Backend` contract
  to a public API.

## The runtime contract (the backend ABI)

A backend implements **four comptime contracts**, all mirroring gfx's existing
`Backend(comptime Impl)` pattern (validate the `Impl` at comptime, delegate to
it, gate optionals with `@hasDecl`):

1. **render** — gfx's existing `Backend(Impl)`, and like audio it is **two named
   sub-surfaces**, not one bag: (a) the **draw API** — `drawTriangle` /
   `drawTexturePro` / `drawPolygon` / the shape + camera calls — the per-frame
   render surface; and (b) the **asset-streaming/loader** sub-surface the
   generated game already depends on: `decodeImage` / `uploadTexture` /
   `unloadTexture`, the optional compressed-texture decls, and the font decls
   (`decodeFont` / `uploadFontAtlas` / `unloadFontAtlas`). This is the same
   runtime-vs-loader split audio has (playback vs `decodeAudio`/`uploadSound`);
   the difference is render keeps both halves in one `Backend(Impl)` today
   because the draw API and the GPU upload share the backend's render context.
   Naming the two sub-surfaces is what stops a backend from "conforming" to the
   draw bag yet failing the generated build because it skipped the loader half.
   The ABI must capture this **full surface** (see
   `src/codegen/blocks/asset_wiring.zig`). Most-ready of the four, but not as
   thin as a first read suggests.
2. **input** — `getMouseX/Y`, `isKeyDown`, `getTouchX/Y`, gamepad, wheel. A
   method-bag.
3. **audio** — two distinct surfaces, only one of which is contracted in core
   today. **Runtime playback** is `AudioInterface(Impl)` in **labelle-core**
   (`src/audio.zig`): it requires only `playSound` / `stopSound`, with
   `loadSound(path) → u32` / `unloadSound(id: u32)` / music / volume all
   `@hasDecl`-gated. The **asset-loader** surface — `decodeAudio` /
   `uploadSound` / `unloadSound(Sound)` — is a *separate* contract,
   `Backend(Impl)` in **labelle-engine/`audio_backend`** (its own doc comment:
   "Runtime audio playback (`AudioInterface`-style) lives in labelle-core and
   stays there — this repo is decoder/loader-side only"). The loader half is
   the worker-thread decode / main-thread upload split that mirrors gfx's
   `DecodedImage`/`DecodedFont`. So the "already contracted" claim holds only
   for playback; the ABI work's job is to give *both* halves one canonical
   import — the core-diamond in miniature.
4. **window** — the inversion-of-control crux. The window **owns the run loop**
   and the per-frame render target:
   ```zig
   // required: init(cfg) → deinit() → shouldQuit() → beginFrame() *Target → endFrame()
   // optional (@hasDecl-gated): takeScreenshot()
   ```

**Capability differences are optional `@hasDecl`-gated decls** — e.g. headless
screenshot support (sokol) vs not (raylib) — exactly how gfx already handles
optional draw methods. (This is the same split we lived through fixing sokol
headless screenshots; it falls straight out of the contract.) These optionals
get a **declarative mirror** — a `.capabilities` set in the provider manifest
that the resolver checks *before* the build (see *Opening the ecosystem —
capability negotiation*) — so a missing optional surfaces as an early,
project-level error instead of a deep `@compileError` in generated code.

### Context is package-private, at comptime — NOT in the contract

A backend's GPU context type is backend-specific (sokol = Metal device, GL =
`GLContext`, raylib ≈ none, bgfx = its own handle). Putting `Context` into the
*cross-backend* contract would force `*anyopaque` + unsafe casts — a
type-erasure hole through the very contract we're trying to make safe. Instead:
the window half **creates** its typed context and the render half **binds** it,
**entirely inside the package**. The contract's only obligation is **init
ordering** — window inits (creates context) before render inits (binds it). The
generic skeleton never names a context.

### POC validation (#377)

A runnable POC de-risks all of the above:
- **v1** — a backend-blind run-loop skeleton + a backend-blind engine drive two
  completely different window backends through the window contract.
- **v2** — render + window contracts compose; the engine talks *only* to the
  render contract; a backend is a `{ Window, Render }` package.
- **v3** — the context handoff: two packages with *different* context types both
  run through the **byte-identical** generic skeleton; the contract/skeleton/
  engine never name a context. The diff between v2 and v3 was confined entirely
  to the two packages.

## Backends compose independently-pluggable contracts

The four contracts are **independently pluggable, not bundled per lib** — and
audio is the proof. `AudioInterface` already lives in **labelle-core** (every
backend's `audio.zig` "satisfies the engine `AudioInterface(Impl)` contract"), so
audio was never coupled to rendering at the contract level. Yet bgfx and wgpu
*each reimplement* a WAV decoder + PCM mixer (bgfx 735 lines + a miniaudio
device, wgpu 296 lines, software-only) purely because their render lib has no
audio — exactly the duplication a "one backend = all four contracts" bundling
*forces*.

So a project's "backend" is a **composition** of per-contract providers. Some
libs supply several contracts (sokol = render + window + input + audio); some
supply one (bgfx = render only). The **canonical declaration is the per-contract
struct** — it's self-documenting (you see the slots) rather than relying on
knowing what `.sokol` secretly pulls in:

```zig
.backend = .{ .render = .sokol },
//          ⇒ window=.sokol_app, input=.sokol_app, audio=.sokol_audio  (sokol is full-stack)

.backend = .{ .render = .bgfx, .audio = .miniaudio },
//          ⇒ window=.glfw, input=.glfw  (bgfx has neither — cascade to the desktop default)
//          ⇒ audio=.miniaudio            (pinned)

.backend = .{ .render = .{ .repo = "github:someone/labelle-vulkan" } },  // a stranger's provider
```

(The bare `.backend = .sokol` is accepted only as sugar for `.{ .render = .sokol }`.)

**`render` is the anchor and the other slots cascade — *per platform*.** The
slots aren't equally independent, and the defaults are **platform-conditioned**:
the resolver is `(platform, render) → window/input/audio`, not `render → …`.
- **render → window** — a renderer needs a *compatible* window, and the default
  is **per platform**: `.bgfx` on desktop ⇒ `glfw`, but `.bgfx` on **Android** ⇒
  its own `NativeActivity`/app path (no GLFW); `.sokol` ⇒ `sokol_app` on every
  platform it supports. So the render provider declares a *table* of
  platform → default-window, not a single value.
- **window → input** — input comes *with* the window lib (GLFW and sokol_app both
  deliver it), so input defaults from the window, not render.
- **audio** — fully independent (its own device + thread); defaults to the render
  provider's own if it has one (`.sokol` ⇒ `sokol_audio`), else `miniaudio`.

You pin `render` plus any slot you want to differ from the cascade. The
defaulting is **principled** (the render⇄window coupling) and **platform-scoped**
— see *Platform packaging & the manifest* below for where these per-platform
defaults live. An *incompatible* override (e.g. `.render = .bgfx, .window =
.sokol_app`) is a resolve-time error, not a silent fallback.

### Audio — the worked example
Audio decomposes one level further, along the same **runtime-vs-loader** seam the
contract section drew. The duplicated work is backend-agnostic and splits in two:
**playback/mix** (the `AudioInterface` surface — `playSound`/`stopSound` + the PCM
mixer) and **decode** (WAV/OGG → PCM, the `decodeAudio`/`uploadSound` half that
belongs to the *separate* audio-loader contract, `Backend(Impl)` in
`labelle-engine/audio_backend`). Only the *output device* is platform-specific.
- a shared **`labelle-audio`** = the `AudioInterface` impl (playback + PCM mix),
  plus the backend-agnostic WAV decoder, written once, and
- a pluggable **audio-device** sink (the `DeviceSink` contract): providers
  `sokol_audio`, `miniaudio`, AAudio, `null`.

"sokol has its own, bgfx has none" maps cleanly: sokol's device = `sokol_audio`;
bgfx's device = `miniaudio`; the mixer above them is shared — deleting ~3
reimplementations.

> **Corrected by deployment (rev 14):** an earlier draft listed `sdl_audio` and
> `raudio` as device sinks under the shared mixer. They are **not** — raylib
> (raudio) and sdl (SDL_mixer) delegate *both* decode **and** mix to a full
> third-party engine, so there's no mixer to collapse and no device-sink to wrap.
> They are **monolithic providers**: a backend that supplies the *whole* audio
> contract from one engine and bypasses the shared mixer entirely. This is a
> distinct, generalizable category — see *Deployment notes* and the resolver
> section: a provider may own a contract **monolithically** (raylib = all four
> bundled; raudio = audio-as-one-engine) rather than **compose** from shared
> logic + a pluggable sub-provider (bgfx render + glfw window + miniaudio sink).
> The resolver and capability model must handle both.
>
> Also corrected: the shared decoder ships **WAV-only**; OGG decode stayed
> backend-side (dr_wav/stb_vorbis), so the "loader half is shared" claim is only
> half-true today. Unifying it (shared OGG, or a shared decoder package) is a
> Phase-6 cleanup, tracked with the `writeAudioBackendWiring` codegen that still
> assumes each backend provides `decodeAudio`. Audio is the **ideal first extraction**: its **playback half
is already contracted** in core (`core.AudioInterface`) and its **loader half**
has a ready home (the `audio_backend` `Backend(Impl)`), and it has **zero
GPU-context sharing** (its own device + thread), so the hardest part of this RFC
— the context handoff — simply does not apply to it.

### Packaging: one monorepo + lazy deps (not a repo explosion)
Contract granularity and repo count are **orthogonal** — per-contract composition
never required per-contract repos. The official providers live in a **single
`labelle-backends` monorepo** (one thing to maintain). Slim-fetch is then a
**packaging *requirement***, not an automatic property of a monorepo: it holds
only if (a) each provider's heavyweight native dep is a **lazy, external** Zig
dependency — *not* vendored into the fetched package — and (b) the root build
graph does **not** reference an unused provider's dep during construction. Meet
those and `render = bgfx` fetches bgfx's ~812 MB and *not* sokol's ~2 GB despite
the shared repo; violate either (e.g. vendored deps, an eager root reference) and
the monorepo re-introduces the ~4 GB. So this is a constraint the providers + the
root package must satisfy, stated explicitly here so it isn't assumed for free.
Third parties publish their own repo with their own provider and point a slot at
it — not the toolkit's burden.

The existing plugin rails (`resolvePlugin`, manifest-driven codegen,
`overrideImport`, the deps linker) are reused for resolution + wiring.

## Per-layer changes

### `labelle-core` (the existing leaf package — home of the ABI)
Houses the four comptime contracts + the shared value types; almost no deps.
gfx, engine, and every backend depend on it. A backend author opens exactly one
package to see "here's everything I must implement, here's the version I pin."
(See Q#2 for the full rationale of why the ABI package IS `labelle-core`, not
a new package — 7 of 8 contracts already live there.)

### labelle-gfx
- Code barely changes — concrete backends move *out*, not *in* (no bloat, no
  native deps pulled into gfx).
- Promote `Backend(Impl)` from implicit/duck-typed → a **versioned, documented
  public contract**: a written spec, a `comptime assertBackend(Impl)` that fails
  loudly, `mock_backend` as the reference impl, and a **shared conformance suite**
  parameterized over the provider `Impl` (see *Opening the ecosystem —
  conformance suites*) that checks *behavior*, not just shape. Semver discipline
  applies (adding a required `Impl` decl = breaking for every backend).
- Inherits the **core-diamond** as a first-class cross-repo concern: backends
  import labelle-core for shared types; composed builds must unify core across
  backend + gfx + engine (generalizing the `unifyGfxSubpackageCore` fix from the
  Y-axis epic).

### labelle-assembler
- **Delete the closed `Backend` enum.** Resolve backends by name/repo like
  plugins.
- **Emit a context-free skeleton** (the `main()` the POC's `run` models) and
  **splice** the backend's manifest-provided run-loop / build fragments *blind*.
  (The codegen-splice — the hard part, see below.)
- Drop the bundled `backends/` dir + ~4 GB of deps.
- Generalize the core-diamond unification.

### labelle-engine
- The window / input / audio contracts (today implicit in the engine + the
  generated game) get formalized and given a versioned home in the ABI package.

### The backends
- Extracted to a single `labelle-backends` monorepo (Q#3 resolved — see
  *Packaging* above). Each provider implements the ABI contracts + ships a
  manifest; third parties publish their own repo and point a slot at it.

## The codegen splice — a `Game`-lifecycle hook contract, not a text merge

The instinctive model — the assembler **splices the backend's run-loop text**
into a `main()` template — is not just fragile, it's **impossible**: the
entry-point *shape* is platform-specific. Desktop owns a `while` loop (a real
`pub fn main`); mobile and wasm do **not** — the OS / browser pumps callbacks
(sokol_app, `ANativeActivity`, the browser's rAF). No single `main()` text can
span them.

The real split (POC-validated, #377): the assembler emits **one backend-blind
`Game`** — `init` / `frame` / `deinit` lifecycle hooks that touch only the
contracts (the registries, scene/script setup, the `project_y_axis` const, the
per-frame work — i.e. everything `templates/desktop.txt` bakes today *minus* the
run-loop). The **backend ships its own entry point** — whatever shape its
platform requires — and drives those hooks, importing the generated `Game`
module. Composition is at the **module/type level (comptime), not a text
merge.** The POC drives the identical `Game` through a desktop `while`-loop *and*
an OS-callback pump → same output, the game never knowing which.

So the *code* splice is largely answered. The two genuinely hard residuals are:
- **The build splice** — generically wiring a resolved backend's native deps +
  module graph + the core-diamond from its manifest. The hook insight solves
  *code* composition, not `build.zig` composition. (This is where the
  core-diamond pain from the Y-axis epic lives — see open question #5.)
- **The full lifecycle ABI** — `frame` alone is too thin. The `Game` hook surface
  must carry input/resize events and, the gnarly part, mobile **suspend/resume +
  GPU context-loss**, delivered by the entry point to the game (see open
  question #1). That surface area is where the real design depth now sits.

### Build-splice POC verdict (rev 15) — VIABLE, with a refined model

A throwaway POC (epic #386, Phase-3 entry) attacked the **build splice** residual
head-on: a manifest-driven generation path for **sokol-desktop** that resolves
the run-loop style + the `build.zig` backend/link fragments from a
`backend.manifest.zon` in the backend package, with **no `switch(cfg.backend) =>
.sokol` branch in the splice logic**. Result: generated `main.zig` + `build.zig`
**byte-identical** to the enum path, builds, and runs (headless screenshot
byte-identical too; a negative-control sentinel proved the manifest path is
genuinely active, not a silent fallthrough). **So manifest-driven splicing is
viable** — and the feared part, externalizing the embedded `build_zig.txt`
sections to fragment files, was the *easiest* part (the template engine already
does runtime placeholder maps; the lifecycle template already loads from the
backend package).

The POC's real value is mapping what **resists the data model** — the model is
**"manifest declarations + a fixed set of assembler-computed params + a still-code
lifecycle block library keyed by capability flags," NOT a pure-data manifest**:
1. **Per-placeholder param *value* computation stays code.** A manifest can declare
   *which* `{{placeholders}}` a fragment consumes (`with_imgui`, `gamepad_enabled`),
   but the *value* derivation (`with_imgui` = imgui-gui-only; the gamepad rules) is
   backend-specific logic. Options: a fixed assembler-computed param vocabulary
   (what the POC did) or backend-shipped resolvers = sandboxed codegen-time
   execution (much harder). Pick the fixed vocabulary.
2. **Backend-specific *generated lifecycle logic* stays code.** `main_template.zig`
   emits sokol-specific readback / preview / allocator / platform-render blocks. For
   sokol-desktop they resolve identically (hence byte-identical), but a *new*
   callback-style backend would hit residual `cfg.backend == .sokol` checks. A
   manifest can *key* these by a capability flag ("wants the readback block") but
   can't carry the block's *content* — it's generated code, not data.
3. **Cross-compile link steps stay imperative.** wasm `emLinkStep`, iOS frameworks,
   Android NDK ordering (the emcc dep-snapshot timing) are sequencing logic, not
   declarative fragments — they don't fit the manifest at all.

And the **chicken-and-egg / pluggability seam**: you need the package dir to read
the manifest, but the dir name is *in* it. The POC resolves via `@tagName` once as
a gate; **production replaces that gate with a name→package registry** (the same
`@tagName(cfg.backend)` sites at `build_files.zig:745` / `deps_linker.zig:54` /
`root.zig`). That registry *is* the thing that makes backends pluggable — Phase 5.

Net for the phase plan: the build splice is **de-risked, not free**. Phase 6's
real cost is (a) the name→package registry, (b) externalizing ~40 sections (the
declarative ones are mechanical; the cross-compile link steps are not), and (c) a
capability-flag-keyed lifecycle block library decoupling `callback.zig`/`loop.zig`
+ the `main_template.zig` sub-branches from the backend enum.

## Platform packaging & the manifest

The contracts above are the *runtime* story. Orthogonal to them is the
**(backend × platform) matrix** — the most platform-specific, most-hardcoded
thing in the assembler today: every backend ships
`templates/{desktop,mobile,android,wasm,headless}.txt`, plus the APK packaging
(`package_apk.sh`, generated `AndroidManifest.xml`, the NDK build) and the
wasm/emscripten shell. A `Platform` enum (`desktop`/`android`/`ios`/`wasm`) and
per-platform asset compression already exist.

So a backend is not "four contracts" — it is **four contracts × the platforms it
supports**, where each platform needs its own **entry point**, **build target**,
**packaging recipe**, **platform-manifest**, and **per-platform deps**. The
per-platform entry points *are* the entry-shapes the codegen-splice identified
(desktop `main()`, Android `NativeActivity`, wasm exports + rAF) — the
`Game`-hook contract is shared across them; the manifest is what says "for *this*
platform, here is my entry + how to package it."

### The manifest is the linchpin
A provider ships a manifest declaring the contracts it fills *and* its platform
matrix:

```zig
.{
    .name = "sokol",
    .contracts = .{ .render, .window, .input, .audio },
    .platforms = .{
        .desktop = .{ .entry = "desktop.zig", .target = .native,                .package = .binary },
        .android = .{ .entry = "android.zig", .target = "aarch64-linux-android", .package = .{ .apk = .{ .manifest = "AndroidManifest.xml.tmpl" } }, .deps = .{ .ndk } },
        .wasm    = .{ .entry = "wasm.zig",    .target = .emscripten,             .package = .{ .web = .{ .shell = "index.html.tmpl" } } },
        // .ios = … — the provider declares it; the assembler never needs to know
    },
}
```

This is what lets the assembler stay blind to *both* the backend *and* the
platform. It is also where the platform-qualified cascade defaults live (the
`(platform, render) → window/input/audio` table from the declaration section).

### Packaging decomposes like audio did
The window provider's per-platform *entry / NDK glue* is backend-specific
(sokol_app's Android entry ≠ bgfx's hand-rolled `NativeActivity`). But the
*packaging itself* — `libgame.so` → APK, the `AndroidManifest` template, signing,
the wasm bundle + HTML shell — is **platform-specific but backend-agnostic.** So a
shared **platform-packager** (`android` / `ios` / `wasm`) becomes its own
pluggable layer the manifest *references*, distinct from the window provider's
entry — the same shape as `labelle-audio`'s shared mixer over pluggable devices.

## Migration plan (incremental, not a big bang)

> **Status (rev 14): Phases 1 & 2 are SHIPPED.** See *Deployment notes* below for
> what the rollout proved, corrected, and added to the later phases.

1. ✅ **DONE — Formalize `labelle-core` as the ABI home** (labelle-core
   #45/#387). The render `Backend(Impl)` + value types + `assertBackend` /
   `missingBackendDecls` + a mock reference now live in
   `labelle-core/src/backend_contract.zig`; gfx conforms. (No separate
   `labelle-platform-abi` — core is the home, as rev 11 settled.)
2. ✅ **DONE — Pilot with audio** (labelle-audio v0.3.0; #388/#389/#390). The
   shared `labelle-audio` = `Mixer(comptime Sink)` (the `AudioInterface` impl:
   decode + PCM mix, spinlock + UAF-safe unload) over a comptime `DeviceSink`
   contract (`ensureStarted/stop/framesMixed`), **i16 by default + an f32 path**
   (a sink declares `sample_format = .f32`). Collapsed **bgfx** (miniaudio+AAudio
   sinks), **wgpu** (NullSink, software), **sokol** (sokol_audio f32 sink) —
   ~1,900 lines of duplicated decode/mix deleted, public APIs byte-identical, and
   **no assembler-codegen change needed** (the backend `audio` module carries the
   dep transitively). **raylib + sdl did NOT collapse** — see the corrected worked
   example below. Two loose ends it surfaced (now Phase-6 targets): OGG decode is
   still backend-side (the shared decoder is WAV-only), and the assembler's
   `writeAudioBackendWiring` still assumes per-backend `decodeAudio`.
3. **Convert one full backend** (sokol — render+window+input; it's the
   headless-screenshot-verifiable one) to implement the contracts from a separate
   location, *while keeping the enum* as a resolver shorthand. Prove a generated
   game still builds + runs. This validates the **desktop** extraction mechanics
   for a render+window+input backend — but sokol-desktop has no surface-loss
   cycle to exercise, so it is *not* the GPU-context gate. **Still the gating
   crux:** audio (Phase 2) proved the *provider-composition* mechanic
   (`Mixer(Sink)` + a comptime device contract) and that a module dep needs no
   codegen change — but audio has no run loop, so it did **not** exercise the
   codegen-splice (Q#1) of a window provider's run-loop/build fragments. Phase 3
   is where that gets validated for the first time. (Sokol is already *half*
   converted — its audio is a clean `DeviceSink` consumer post-Phase-2.)
4. **GPU-context pilot — bgfx-Android.** Distinct from step 3: this is the only
   pilot that can exercise the `TERM_WINDOW`+`INIT_WINDOW` surface-recreation
   cycle (bgfx-Android already has the `init_done` one-shot guard for it). It is
   where the `surfaceLost`/`surfaceRestored` re-upload granularity gets decided
   in practice (vs overloading `deinit`+`init`)
   — **the Accept-readiness gate** for promoting this RFC out of Draft.
5. **Open the resolver** — `.backend` accepts a full-stack package *and*
   per-contract overrides (`.{ .render = .bgfx, .audio = .miniaudio }`); the
   closed enum values become **shorthands** resolving to the official providers.
   **Backward-compatible**: `.backend = .sokol` keeps working. **Must model two
   provider kinds** (deployment finding): *composable* (supplies one contract,
   composes with sub-providers — bgfx render + glfw + miniaudio) and *monolithic*
   (owns a contract from a bundled engine, bypasses the shared logic — raylib's
   raudio, sdl's SDL_mixer). The capability/conformance machinery must let a
   provider declare "I own this contract whole" so the resolver doesn't try to
   compose a shared mixer onto an engine that already mixes.
6. **Extract the remaining backends**; slim the assembler (lazy native deps per
   provider). **Scope shrank:** Phase 2 already extracted *audio* for every
   backend, so this is render/window/input only. **Concrete targets from the
   audio rollout:** (a) generalize/remove `writeAudioBackendWiring`
   (`src/codegen/blocks/asset_wiring.zig`), which still hard-codes per-backend
   `decodeAudio`/`uploadSound` calls; (b) unify the decoder — OGG is still
   backend-side while WAV is shared, so the "loader sub-surface is shared" goal is
   only half-met (mirror the gfx `DecodedImage`/`DecodedFont` split for a shared
   decoder).

## Q#1 answer — the `Game`-lifecycle ABI

> Resolves open question #1. The inventory below is grounded in the seven
> templates shipped today (`sokol/{desktop,mobile}`, `raylib/{desktop,wasm}`,
> `bgfx/{desktop,android}`, `sdl/desktop`, `wgpu/desktop`, `null/headless`)
> at `backends/<name>/templates/*.txt`, the codegen builders in
> `src/codegen/lifecycle/{loop,callback}.zig`, and the engine entry points
> on `AssembledGame` (`labelle-engine/src/game.zig`).

### Inventory — what the templates inject today

Every template, regardless of entry shape (`pub fn main` + `while` on desktop,
`init`/`frame`/`cleanup` C callbacks on sokol/wasm, `android_main` +
`setInitCallback`/`setTickCallback` on bgfx-Android), funnels the same six
categories of work into the generated game. The "code splice" each template
performs is really the composition of these six surfaces, in this order:

**1. Engine lifecycle (game-owned, backend-blind)**
- `AssembledGame.init(allocator)` → `g`
- `g.setHooks(&hooks)` (hooks struct emitted by `{{hooks_init_block}}`)
- `g.setScreenHeight(design_h)` (design canvas height — engine works in design coords)
- `g.getCamera().setPosition(0, design_h)` (raylib/null/sdl desktop — initial camera)
- `g.deinit()`
- `g.isRunning()` (engine's `running` flag — drained via `window.requestQuit()` on sokol/bgfx; `windowShouldClose()` on raylib desktop)

**2. Per-frame engine drive**
- `g.tick(dt)` — sim + script + hooks
- `g.render()` + `g.renderGizmos()` — after tick, before present

**3. Engine-owned state requests (backend drains, per-frame)**
- `g.takeFullscreenRequest()` → `?bool` → `window.setFullscreen(on)` (comptime-gated `@hasDecl` on both sides — folds away on backends/engines that predate the API)
- `g.takeVsyncRequest()` → `?bool` → `window.setVsync(on)` (same gating)
- `g.getCamera().setZoom(actual_h / design_h)` (sokol mobile only, first-frame)

**4. Backend-owned platform state fed TO engine (per-frame)**
- `BackendGfx.setScreenSize(physical_w, physical_h)` + `BackendGfx.setDesignSize(design_w, design_h)` — every backend except raylib-wasm/null
- `window.frameDuration()` (bgfx/sokol) / `window.getFrameTime()` (raylib) / fixed `0.016` (sdl/wgpu) / `1/60` (null) — the `dt` source
- `window.width()` / `window.height()` — physical framebuffer size

**5. Window/render frame bracketing (backend-owned)**
Three distinct bracket shapes exist today (this is *the* codegen-splice crux the `Game`-hook contract must absorb):
- **sokol** — `window.run(.{ init_cb, frame_cb, cleanup_cb, event_cb, ... })` owns the loop; inside `frame_cb`: `beginFrame() → pass_action`, `beginPass(pass_action)`, `g.render()`, `flushScene()` (sokol-gl primitive flush), `endFrame()`. `clearBackground` is baked into `pass_action`, not a separate call. On mobile, `sokol_main` returns `window.Desc` (does NOT call `sapp_run` — Android/iOS contract).
- **raylib/bgfx/wgpu/sdl desktop loop** — `window.initWindow` / `setTargetFPS`, `while (!windowShouldClose()) { beginDrawing(); clearBackground(); g.render(); endDrawing() }`, `defer closeWindow()`.
- **bgfx-Android** — `android_main(app)` registers `setInitCallback(&gameInit)` + `setTickCallback(&gameFrame)`, calls `android_app.run(app)`. The glue's `onAppCmd` handles `INIT_WINDOW`/`TERM_WINDOW`/`RESUME`/`PAUSE`/`STOP`/`DESTROY`; `is_resumed` + `bgfx_ready` gate the per-frame tick. `init_done` is a one-shot guard so engine state survives `TERM_WINDOW` + `INIT_WINDOW` cycles (surface teardown without re-init).
- **null** — no window, no render; fixed-frame counter loop.

**6. Input / screenshot / GUI / preview (cross-cutting)**
- **Input** — sokol: `sokolEvent` C callback → `backend_input.handleEvent(ev)` (keys/mouse/touch), `backend_input.newFrame()` at frame end. raylib desktop: `backend_input.initGamepad()` / `deinitGamepad()` (SDL gamepad source), `newFrame()` at loop top. sokol mobile: `initAndroidGamepad()`. bgfx-Android: input flows through `onInputEvent` in the glue (touch + gamepad key/motion).
- **Screenshot** — `engine.requestedScreenshot()` reads `LABELLE_SCREENSHOT_PATH`; `engine.nowNs()` is the wall clock for the `after_sec` delay; `window.takeScreenshot(path)` is the backend call. Template-owned state: `screenshot_req`, `loop_start_ns`/`screenshot_start_ns`, `screenshot_initialized` (sokol), `screenshot_flush_left`/`screenshot_flush_frames` (bgfx async capture needs ~8 extra frames to flush to disk). Post-shot exit: `break` (raylib) / `window.requestQuit()` (sokol) / no-break (bgfx, lets `--timeout` SIGTERM).
- **GUI** — `{{gui_event_extern}}` + `{{gui_event_forward}}` (sokol-only: imgui event hook inside `sokolEvent`). `{{gui_draw_code}}` splices `g.guiBegin()` / `g.renderAllViews(Views)` / `runner.drawGui(&g)` / `PluginSystems.drawGui(&g)` / `g.guiEnd()` between `g.renderGizmos()` and the present call.
- **Preview control plane** — `{{preview_setup}}`, `{{preview_heartbeat}}`, `{{preview_pre_render}}`, `{{preview_readback}}`, `{{preview_readback_post}}`, `{{preview_cleanup}}` — the `LABELLE_PREVIEW=host:port` editor protocol (hello/heartbeat/bye). GPU-independent but wired into every template.
- **Android immersive + backend-context** — `{{immersive_entry}}` (sokol mobile, in `sokol_main` before sokol registers its callbacks) registers `engine.core.registerAndroidBackend(...)` + `engine.android.enableImmersiveMode()`; must run on the UI thread before the first focus event. bgfx-Android: `{{android_backend_register}}` + `{{immersive_register}}` in `android_main`.

### The proposed hook surface

The `Game` the assembler emits becomes a struct the backend imports and drives.
The hook surface is **the minimal set that absorbs every category above**
without the backend reaching into engine internals or the assembler reaching
into backend entry shapes:

```zig
// labelle-core: the Game hook contract (versioned).
pub const GameHooks = struct {
    init:    *const fn (allocator: std.mem.Allocator, screen_w: u32, screen_h: u32) Game,
    deinit:  *const fn (*Game) void,
    frame:   *const fn (*Game, dt: f32) void,   // tick + render + gizmos + GUI + preview
    running: *const fn (*Game) bool,            // engine's `running` flag drain
    // event-driven (optional — @hasDecl-gated per provider)
    event:      ?*const fn (*Game, Event) void = null,         // input/resize/close
    suspend_:   ?*const fn (*Game) void = null,                 // mobile backgrounded
    resume_:    ?*const fn (*Game) void = null,                 // mobile foregrounded
    // GPU surface lifecycle — explicit pair, NOT overloaded onto deinit/init
    surfaceLost:     ?*const fn (*Game) void = null,           // surface gone (TERM_WINDOW); game state survives
    surfaceRestored: ?*const fn (*Game) void = null,           // surface re-created (INIT_WINDOW) → engine reuploadAssets
};
```

**Why these and only these:**

| Hook | Absorbs (from the inventory) |
|---|---|
| `init` | #1 (AssembledGame.init, setHooks, setScreenHeight, camera setup) |
| `deinit` | #1 (g.deinit) |
| `frame` | #2 (tick+render+gizmos) + #3 (drain fullscreen/vsync requests) + #4 (setScreenSize/setDesignSize — but see "the dt+size question" below) + #6 (GUI draw, preview heartbeat, screenshot fire check, `newFrame` for input edges) |
| `running` | #1 (isRunning → backend's requestQuit/windowShouldClose) |
| `event` | #6 (sokol `sokolEvent` forwarding; raylib desktop gamepad pump can stay inside `frame` since it's poll-shaped, not event-shaped) |
| `suspend_` / `resume_` | bgfx-Android `APP_CMD_PAUSE/STOP` / `RESUME/START` — today these gate `is_resumed` *inside* the backend's loop; promoting them to hooks lets the engine stop ticking scripts during background and re-init GPU state on resume |
| `surfaceLost` / `surfaceRestored` | bgfx-Android `APP_CMD_TERM_WINDOW` + `INIT_WINDOW` cycle — today the `init_done` one-shot guard keeps engine state alive across surface teardown. The pair is **explicit, not overloaded onto `deinit`/`init`**: `surfaceLost` = the GPU surface is gone but game state lives; `surfaceRestored` = surface re-created, at which point the engine runs `gpuResourcesInvalidated` → `reuploadAssets` (re-upload textures/atlases through the asset catalog) *without* a `deinit`+`init` cycle |

**Capability differences stay `@hasDecl`-gated** — a backend without
`suspend_`/`resume_` (desktop) simply leaves them `null`; the entry point's
drive loop never calls them. This mirrors how gfx already handles optional
draw methods and how the templates today use `@hasDecl(window, "setFullscreen")`.

### Two residuals the hook surface surfaces (but does not fully close)

**a) The dt + physical-size question.** `frame(dt)` carries the sim timestep,
but `BackendGfx.setScreenSize`/`setDesignSize` (category #4) is per-frame state
the engine reads during `render()`. Two options:
- **Frame carries a `FrameContext`** struct: `frame(*Game, ctx: FrameContext)` where `ctx = .{ .dt, .screen_w, .screen_h, .design_w, .design_h }`. Cleaner, but widens the hook signature and means every backend must populate it.
- **Backend calls engine setters directly** (today's model): `frame(*Game, dt)` and the backend calls `g.setScreenSize(...)` / `BackendGfx.setDesignSize(...)` before `frame`. Keeps the hook thin; the cost is the backend reaches across into gfx's setter, which the contracts already permit (render is a contract the backend implements).

Recommended: **keep today's model** (backend calls setters, `frame` takes only `dt`). It's the smaller hook surface, and the setters are already part of the render contract — no new coupling. The `FrameContext` widening is a fallback if a backend turns out to need engine state the setters don't cover.

**b) Screenshot + preview + GUI are not "lifecycle hooks" — they're codegen.**
The screenshot state machine (`screenshot_req`, `loop_start_ns`, the bgfx
async-flush frames), the preview control plane, and the GUI `guiBegin`/`guiEnd`
bracket are **not** entry-point-shaped — they're per-frame work that today's
templates splice via `{{...}}` holes. They stay in codegen: the assembler emits
them *into* the `Game.frame` body (or the backend's frame callback, which is
what the templates do today). The hook contract only pins the *envelope*
(init/deinit/frame/event/suspend/resume/surfaceLost/surfaceRestored); the per-frame *contents*
remain the assembler's codegen job. This is the split the POC validated — the
backend owns the entry-point *shape*, the assembler owns the per-frame *work*.

### What this closes (and what stays open)

**Closed by this section:**
- The full hook surface beyond `frame`: `event`, `suspend_`, `resume_`,
  `surfaceLost`/`surfaceRestored` are now pinned, each grounded in a concrete
  today-shipped template behavior (sokol `sokolEvent`, bgfx-Android `APP_CMD_*`).
- The screenshot/preview/GUI question: they stay codegen (per-frame *work*),
  not lifecycle hooks (the *envelope*). The hook contract is thinner than a
  first read of "the lifecycle ABI" suggested.
- Mobile suspend/resume + GPU context-loss: promoted from "the gnarly part"
  to four concrete optional hooks (`suspend_` / `resume_` / `surfaceLost` /
  `surfaceRestored`), each with a documented mapping to the Android `APP_CMD_*`
  events that already drive bgfx-Android today. The surface pair is explicit
  rather than an overloaded `contextLost` so `deinit`/`init` keep their meaning.

**Still open (deliberately):**
- **`surfaceRestored` re-upload granularity.** The hook *taxonomy* is now
  explicit — `surfaceLost`/`surfaceRestored` instead of one overloaded
  `contextLost`, and the engine-side response is `gpuResourcesInvalidated` →
  `reuploadAssets` rather than a `deinit`+`init` cycle (so `deinit`/`init` are
  not overloaded for mobile surface recreation). What the **bgfx-Android pilot**
  must still pin is the *granularity*: does `surfaceRestored` re-upload the whole
  asset catalog, or only GPU-resident resources (textures, atlases, render
  targets) while leaving CPU-side decoded payloads untouched — and does
  `reuploadAssets` reuse the asset catalog's existing `post_load_render_gate`
  path in `labelle-engine/src/game.zig` or need a dedicated re-upload pass?
  bgfx-Android today uses the `init_done` one-shot so game state survives
  `TERM_WINDOW`+`INIT_WINDOW`. The audio-extraction pilot (step 2) is structurally
  *incapable* of exercising this — audio has zero GPU context — and sokol-desktop
  (step 3) has no surface-loss cycle. **The GPU-context pilot is bgfx-Android**
  (migration step 4), which is where the granularity gets decided in practice.
  The Accept-readiness gate is on the bgfx-Android pilot, not the audio pilot.
- **The event type.** `Event` is a tagged union (input keys/mouse/touch/resize/close).
  Today sokol forwards the raw `sapp.Event` and the input module switches on it;
  raylib polls. The contract needs a backend-neutral `Event` enum + payload,
  or the input contract keeps owning event parsing and `event` takes the
  input module's parsed shape. The latter is less work and matches how
  `AudioInterface` already lives in core.
- **iOS.** Sokol mobile targets Android + iOS; bgfx-Android has no iOS sibling
  today. The `suspend_`/`resume_`/`surfaceLost`/`surfaceRestored` hooks are
  shaped to cover iOS too (UIKit's `applicationDidEnterBackground`/
  `willEnterForeground` + Metal device-loss), but no template exercises it yet.
  Pin when an iOS backend lands.

## Q#4 answer — gamepad as an input-extension

> Resolves open question #4. Grounded in `backends/sdl_gamepad/src/
> sdl_gamepad.zig` (809 lines, the shared desktop SDL source), `backends/
> android_gamepad/src/android_gamepad_state.zig` (741 lines, the shared
> Android state machine), `labelle-core/src/gamepad_source/root.zig`
> (the per-OS skeleton selector), `labelle-core/src/input.zig` (the
> `InputInterface` gamepad method bag), `labelle-engine/src/game.zig`
> (the `backend_polls_gamepads` / `uses_os_gamepad_source` routing), and
> `src/deps_linker.zig` (the staging + core-diamond wiring).

### Inventory — the three gamepad source paths today

The codebase already has **three distinct gamepad source paths**, each
a standalone package composed alongside the input provider — not part of
the render or window contract:

| Source | Home | Shared by | Wired via |
|---|---|---|---|
| **`sdl_gamepad`** | `backends/sdl_gamepad/` (809 LOC) | raylib + sokol + bgfx desktop | `deps_linker.zig:78-85` stages it gated on `cfg.gamepad == .auto`; backend `build.zig.zon` declares `.path = "../sdl_gamepad"`; `build_zig.txt` overrides core onto it (`overrideImport(sdl_gp_mod, "labelle_core", core_mod)`) |
| **`android_gamepad`** | `backends/android_gamepad/` (741 LOC) | sokol + bgfx Android | `deps_linker.zig:102-110` stages it unconditionally for sokol+bgfx; backend `build.zig.zon` declares `.path = "../android_gamepad"`; consumed via `@import("android_gamepad")` |
| **`core.gamepad_source`** | `labelle-core/src/gamepad_source/` (per-OS: `linux.zig`, `android.zig`, `ios.zig`, `wasm.zig`, `unsupported.zig`) | engine fallback when backend doesn't poll | engine's `Game.uses_os_gamepad_source` comptime flag (`game.zig:227`); `core.gamepad_source.init()` at `game.zig:687` |

### The engine's routing logic (already extension-shaped)

The engine's `Game` comptime block already treats gamepad as an
**extension of the input provider**, not a contract in its own right.
The routing is a two-way comptime switch:

```zig
// labelle-engine/src/game.zig:220-227
pub const backend_polls_gamepads = @hasDecl(InputImpl, "pollGamepadEvents");
pub const uses_os_gamepad_source = !backend_polls_gamepads and gamepad_events_wanted;
```

- **Backend declares `pollGamepadEvents`** → the engine drains
  `Input.pollGamepadEvents(out)` (the backend's own gamepad path). This
  is the `sdl_gamepad` path on desktop, `android_gamepad` on Android,
  and the SDL backend's own `SDL_PollEvent` path (which is why SDL
  doesn't use `sdl_gamepad` — it would steal events from its own queue).
- **Backend does NOT declare `pollGamepadEvents`** → the engine drains
  `core.gamepad_source.pollEvents(out)` (the per-OS fallback). This is
  the raylib-on-Linux path (udev/evdev via `core.gamepad_source.linux`)
  and the iOS path (GameController via `core.gamepad_source.ios`).

The state queries (`isGamepadButtonDown`, `isGamepadButtonPressed`,
`getGamepadAxisValue`) follow the same pattern: the input module
delegates to whichever source it was compiled with — `sdl_gamepad` on
desktop, `core.gamepad_source.Source` on Linux, raylib's own GLFW path
on non-Linux desktop, `android_gamepad` on Android.

### The answer: gamepad is already an input-extension — formalize it

The RFC asked whether `android_gamepad` / `sdl_gamepad` are "input
*extensions* composed alongside the window provider, not a fifth
top-level contract." The inventory confirms: **yes, they are, and the
engine already routes them as such.** No new contract is needed. The
formalization is:

**1. Gamepad extensions are build-graph compositions, not ABI contracts.**
A gamepad extension is a package that implements the `Source` namespace
shape (`pollEvents`/`isAvailable`/`isButtonDown`/`isButtonPressed`/
`axisValue`/`update` — the surface `sdl_gamepad.zig` and
`android_gamepad_state.zig` both mirror). The input provider's `Impl`
`@import`s it and delegates. The engine's `InputInterface(Impl)` wraps
the result — no fifth contract, no ABI change.

**2. The manifest declares input-extensions alongside the input provider.**
Extending the manifest from Q#5:

```zig
// backend.labelle — input-extensions field
.{
    .name = "sokol",
    // ...modules, artifacts, etc. from Q#5...
    .input_extensions = .{
        // Packages composed alongside the input provider on specific
        // platforms. The assembler stages + unifies core onto them
        // (same overrideImport path as today's sdl_gamepad wiring).
        .desktop = .{ .{ .name = "sdl_gamepad", .platforms = .{ .desktop } } },
        .android = .{ .{ .name = "android_gamepad", .platforms = .{ .android } } },
    },
}
```

The assembler stages each extension into `.labelle/deps/<name>/` (same
as `deps_linker.zig` does today), overrides core onto it (same as the
8 hand-coded sites Q#5 generalizes), and the input provider's `Impl`
`@import`s it. The per-platform gating (sdl_gamepad is desktop-only,
android_gamepad is Android-only) moves from `deps_linker.zig`'s
`switch (cfg.backend)` + `cfg.gamepad == .auto` into the manifest's
per-platform extension list.

**3. The opt-out (`gamepad = .none`) is a manifest-level toggle.**
Today `project.labelle` carries `gamepad = .auto | .none` (config.zig:480).
With per-contract providers, this becomes an input-extension toggle:
the manifest's `input_extensions` list is empty when the project opts
out, so no SDL is staged and no gamepad source is wired. The
`gamepad_hidapi` flag (config.zig:488) becomes a build-option the
extension's `build.zig` consumes — same as `with_imgui` today.

**4. `core.gamepad_source` stays as the zero-extension fallback.**
When no input-extension is wired (the backend doesn't declare
`pollGamepadEvents` and no extension is staged), the engine's
`uses_os_gamepad_source` flag stays true and drains
`core.gamepad_source` — the per-OS skeleton. This is the headless /
null / wasm path. No change to the contract; the fallback is already
the right design.

### Why not a fifth contract

A fifth "gamepad contract" would be wrong because:

1. **Gamepad state is consumed through `InputInterface`, not a separate
   surface.** The engine calls `Input.isGamepadButtonDown(gamepad,
   button)` — one method bag. A separate `GamepadInterface(Impl)` would
   duplicate this surface and force every backend to wire a fifth
   module, when today's backends simply `@import` the shared source
   into their `input.zig`.

2. **The gamepad source is platform-specific, not backend-specific.**
   `sdl_gamepad` works with raylib, sokol, and bgfx — the same code.
   `android_gamepad` works with sokol and bgfx — the same code. A
   fifth contract would force each backend to re-implement it, when
   the whole point of the extraction was to share it.

3. **The composition is build-graph-level, not comptime-contract-level.**
   The `@import("sdl_gamepad")` + `overrideImport(sdl_gp_mod,
   "labelle_core", core_mod)` wiring is exactly what Q#5's
   core-diamond generalization handles. Promoting it to a contract
   would add a contract boundary where none exists — the input module
   just calls `sdl_gp.isButtonDown(...)` directly, not through an
   `Interface(Impl)` wrapper.

### What this closes (and what stays open)

**Closed by this section:**
- Gamepad is an input-extension, not a fifth contract. The three
  existing sources (`sdl_gamepad`, `android_gamepad`,
  `core.gamepad_source`) are packages composed alongside the input
  provider, and the engine's `backend_polls_gamepads` /
  `uses_os_gamepad_source` routing already treats them as extensions.
- The manifest extension: `input_extensions` in the provider manifest,
  per-platform, with the same staging + core-diamond wiring Q#5
  generalizes. The opt-out (`gamepad = .none`) is a manifest-level
  toggle (empty extension list).
- The SDL backend's exception (it keeps its own `SDL_PollEvent` path,
  not `sdl_gamepad`) is correct and stays — two consumers on one SDL
  queue would steal events. The manifest's `input_extensions` for the
  SDL backend is simply empty on desktop.

**Still open (deliberately):**
- **The `Source` namespace shape.** `sdl_gamepad` and
  `android_gamepad_state` mirror the shape informally (`update`/
  `isAvailable`/`isButtonDown`/`isButtonPressed`/`axisValue`/
  `pollEvents`/`describe`), but there's no comptime validator (unlike
  `AudioInterface(Impl)` which `@compileError`s on missing decls). A
  `source_contract.zig` in core that validates the shape would help
  third-party extensions, but it's lower priority — the two existing
  sources are the only consumers today, and they're hand-verified.
- **Multiple extensions on one platform.** Today only one source is
  active per platform. If a future backend needs both a generic HID
  source and a platform-specific one (e.g. iOS GameController + a
  Bluetooth LE controller source), the composition mechanism needs a
  merge/priority story. Defer until a real second extension exists.

## Q#6 answer — GUI-bridge compatibility

> Resolves open question #6. Grounded in `src/gui_resolve.zig` (387 lines,
> the bridge resolver), `src/config.zig` (`RenderingMode`, `ResolvedGui`,
> `GuiPlugin`), `src/build_files.zig:222-264` (the `with_imgui`/
> `gui_enabled` build-flag wiring), `plugins/imgui/gui.labelle` +
> `plugins/nuklear/gui.labelle` (the two raw_backend manifests), and
> `plugins/imgui/bridges/raylib/` (the only shipped bridge today).

### Inventory — how GUI bridges work today

The GUI system has **two rendering modes** (`config.zig:435`):

| Mode | How it renders | Bridge needed? | Examples today |
|---|---|---|---|
| `render_interface` | The GUI plugin implements `GuiInterface(Impl)` directly — pure Zig, no C library | No | clay, simple-raylib, simple-sokol |
| `raw_backend` | The GUI plugin wraps an immediate-mode C library (imgui, nuklear) that draws through the render backend's native primitives | **Yes** — a per-backend C++ bridge | imgui, nuklear |

**The bridge resolution** (`gui_resolve.zig:43-77`): for `raw_backend` GUIs,
the resolver reads `gui.labelle`'s `bridges` struct and looks up the entry
matching the **closed `Backend` enum** via `getBridgeForBackend(bridges,
cfg.backend)` — a `switch (backend)` over `raylib`/`sokol`/`sdl`/`bgfx`/
`wgpu`/`null` (`gui_resolve.zig:222-234`). Each bridge entry carries an
`adapter` (the C++ static-lib artifact name, e.g. `rlimgui_bridge`) and a
`path` (the bridge directory). If no bridge matches the backend, it's a
hard error (`GuiMissingBridge`).

**The build wiring** (`build_files.zig:222-264`): two distinct mechanisms:

1. **Backend build flags** — sokol gets `with_imgui` (controls whether
   `sokol_imgui.c` is compiled into `sokol_clib`); bgfx gets `gui_enabled`
   (controls input-forwarding externs in `input.zig`). Both are set true
   **only when the GUI plugin is imgui** — a closed-enum + name predicate,
   not a bridge compatibility check. Other GUIs (nuklear) don't get these
   flags even though they have a bridge.

2. **Bridge artifact link** — the `.gui_bridge` template section stages the
   bridge as a `b.dependency("gui_bridge", ...)`, and `.link_gui_bridge`
   links its C++ static lib into the root artifact. This is
   backend-agnostic in the template (the same `.link_gui_bridge` section
   is used for every backend) — the per-backend specificity is entirely in
   the resolution step (which bridge dir was chosen).

**What ships today:** only imgui and nuklear are `raw_backend` GUIs, and
both ship **only a raylib bridge** (`bridges: .{ .raylib = ... }`). The
sokol/bgfx/sdl/wgpu fields exist in the `Bridges` struct but are `null`.
The in-tree `gui/sokol-imgui/` is a **separate adapter module** (not a
bridge declared in `gui.labelle`) — it's wired via the `with_imgui` build
flag, not a bridge artifact link. This is the one place where the
closed-enum coupling is genuinely load-bearing today: sokol+imgui works
without a bridge directory because `with_imgui` compiles `sokol_imgui.c`
*into* `sokol_clib` itself, and the adapter module handles the imgui
dispatch from inside the sokol backend's own module graph.

### The two GUI integration patterns

The inventory surfaces that "GUI bridge" is actually **two different
integration patterns**, and the per-contract-provider model must handle
both:

**Pattern A: external C++ bridge** (raylib + imgui/nuklear today). The
bridge is a standalone C++ static lib (`rlimgui_bridge`,
`nuklear_raylib_bridge`) that links against both the GUI library (cimgui/
nuklear) and the render backend's native lib (raylib). The assembler
stages it as a `b.dependency` and links it into the root artifact. The
bridge is **external to the backend** — it doesn't modify the backend's
build, it just calls the backend's draw primitives through the backend's
C API.

**Pattern B: in-backend adapter** (sokol + imgui today). The adapter is
compiled *into* the backend's own C archive (`sokol_imgui.c` into
`sokol_clib`), enabled by a build flag (`with_imgui`). The adapter module
(`gui/sokol-imgui/`) lives in the assembler tree and is wired into the
backend's module graph. The bridge is **internal to the backend** — it
modifies the backend's build and dispatches from inside the backend's
module.

### The compatibility rule

With per-contract providers, the closed-enum bridge lookup must be
replaced by a **render-provider-keyed** lookup. The rule:

**1. The GUI manifest declares bridges by render provider name, not by a
closed enum.** The `bridges` struct in `gui.labelle` changes from
per-backend fields to per-render-provider fields:

```zig
// gui.labelle — new bridge schema
.bridges = .{
    // Keyed by render provider name (matches the .render slot).
    // A bridge targets the RENDER provider specifically — it links
    // against the render backend's native draw API.
    .sokol = .{ .adapter = "sokol_imgui_adapter", .path = "./bridges/sokol" },
    .raylib = .{ .adapter = "rlimgui_bridge", .path = "./bridges/raylib" },
    // A third-party renderer:
    .my_vulkan = .{ .adapter = "vulkan_imgui_bridge", .path = "./bridges/vulkan" },
}
```

The resolver looks up `bridges.<render_provider_name>` instead of
`getBridgeForBackend(bridges, cfg.backend)`. A project using
`.render = .bgfx` looks up `.bridges(.bgfx`; a project using
`.render = .{ .repo = "github:someone/labelle-vulkan" }` looks up
`.bridges.my_vulkan` (the provider's manifest declares its name).

**2. Pattern A (external bridge) is the default.** The bridge is a
standalone C++ static lib the assembler stages + links, exactly as
today's `.gui_bridge` + `.link_gui_bridge` template sections do. The
render provider doesn't know about the bridge — the bridge calls the
provider's draw API through its native C interface.

**3. Pattern B (in-backend adapter) is declared in the provider's
manifest, not the GUI's.** When a render provider ships its own imgui
adapter compiled into its C archive (sokol's `with_imgui`), the provider's
manifest (from Q#5) declares it as a build option the GUI bridge triggers:

```zig
// backend.labelle (sokol) — the build-options the bridge sets
.build_options = .{
    .with_imgui = .{ .type = .bool, .default = false,
        .description = "Compile sokol_imgui.c into sokol_clib (set by the GUI resolver when the GUI plugin is imgui)" },
},
```

The GUI resolver reads the provider manifest, sees `with_imgui` is
declared, and sets it true when the GUI is imgui — replacing today's
hardcoded `with_imgui` computation in `build_files.zig:222-225`. The
rule is: **the bridge name + the GUI library name** must match the
provider's declared option. The manifest carries the mapping, not the
assembler's closed-enum switch.

**4. Compatibility is declared, not inferred.** A GUI plugin's
`gui.labelle` declares which render providers it has bridges for. A
render provider's `backend.labelle` declares which GUI adapters it ships
in-backend. The assembler checks: **does a bridge exist for the resolved
render provider?** If yes (either Pattern A external bridge or Pattern B
in-backend adapter), wire it. If no, hard error — same as today's
`GuiMissingBridge`, but keyed on the render provider name instead of the
closed enum.

**5. The `render_interface` path is unaffected.** GUIs that implement
`GuiInterface(Impl)` directly (clay, simple-raylib, simple-sokol) need
no bridge at all — they render through the engine's `GuiInterface`,
which talks to the render backend through `Backend(Impl)`'s draw methods.
This path is already provider-agnostic; the per-contract model changes
nothing here.

### What this closes (and what stays open)

**Closed by this section:**
- The bridge lookup is keyed by **render provider name**, not a closed
  enum. The `gui.labelle` bridges struct changes from per-backend fields
  to per-render-provider fields; the resolver looks up
  `bridges.<render_provider_name>`.
- The two integration patterns (external C++ bridge vs in-backend adapter)
  are both handled: Pattern A is the default (standalone artifact link),
  Pattern B is declared in the provider's manifest via `build_options`.
- The `with_imgui`/`gui_enabled` flags in `build_files.zig` are replaced
  by the provider manifest's `build_options` + the GUI resolver's
  name-match predicate. The closed-enum + name switch becomes a
  manifest-declared option the resolver sets.
- `render_interface` GUIs are unaffected — no bridge, no change.

**Still open (deliberately):**
- **The name-match predicate.** Today `with_imgui` is set true only when
  `gui.name == "imgui"`. With per-provider manifests, the provider
  declares a `build_options` entry, but the *rule* for when to set it
  true (GUI name == "imgui") still needs to live somewhere. Options: (a)
  the GUI manifest declares which build-options it triggers on which
  providers (a `gui.labelle` field: `triggers_build_options = .{ .sokol =
  .{ .with_imgui = true } }`); (b) the provider manifest declares which
  GUI names trigger which options. (a) is cleaner — the GUI plugin owns
  its compatibility declarations.
- **The sokol-imgui adapter module path.** Today `gui/sokol-imgui/` lives
  in the assembler tree and is wired via a separate module import (not
  a bridge artifact). With per-contract providers, this module moves to
  the sokol provider's package (it's part of the sokol+imgui integration,
  not the assembler). The provider's manifest declares it as a
  per-GUI-name module the assembler imports when the GUI matches.
- **Multiple GUI plugins.** Today only one GUI plugin is active per
  project (`cfg.gui` is `?GuiPlugin`, not a list). If a future project
  needs both imgui (for dev tools) and clay (for the game UI), the
  bridge resolution + build-option setting needs to handle multiple GUIs.
  Defer — no project needs this today.

## Q#2 answer — where the contracts live + versioning

> Resolves open question #2. Grounded in `labelle-core/src/root.zig`
> (the 8 comptime contracts + re-exports), `labelle-core/src/render.zig`
> (`RenderInterface` — the engine-side renderer contract), `labelle-gfx/
> src/backend.zig` (`Backend(Impl)` — the render backend contract), the
> backend `gfx.zig` files (6 backends, each a one-line "satisfies the
> Backend(Impl) contract" doc comment), and the `build.zig.zon` version
> pins across core (1.19.0) / gfx (1.16.1) / engine (1.63.0) / backends.

### Inventory — the eight contracts and where they live today

The codebase ships **eight comptime-validated `Interface(Impl)` contracts**.
Each is a `pub fn XxxInterface(comptime Impl: type) type` that validates
required decls via `@hasDecl` + `@compileError`, gates optional
capabilities via `@hasDecl`, and returns a zero-cost dispatch struct.
Here is the full map:

| Contract | Home file | Re-exported by engine | Consumed by |
|---|---|---|---|
| `AudioInterface` | `labelle-core/src/audio.zig` | `engine.AudioInterface = core.AudioInterface` (`root.zig:82`) | engine's `Game.Audio = AudioInterface(AudioImpl)` (`game.zig:229`) |
| `VideoInterface` | `labelle-core/src/video.zig` | `engine.VideoInterface = core.VideoInterface` (`root.zig:84`) | engine's `Game.Video = core.VideoInterface(VideoImpl)` (`game.zig:230`) |
| `InputInterface` | `labelle-core/src/input.zig` | `engine.InputInterface = input_mod.InputInterface` (`root.zig:61`) | engine's `Game.Input = InputInterface(InputImpl)` (`game.zig:208`) |
| `GuiInterface` | `labelle-core/src/gui.zig` | `engine.GuiInterface = gui_mod.GuiInterface` (`root.zig:114`) | engine's `Game.Gui = GuiInterface(GuiImpl)` (`game.zig:231`) |
| `GizmoInterface` | `labelle-core/src/gizmos.zig` | `engine.GizmoInterface = core.GizmoInterface` (`root.zig:586`) | engine's gizmo draw system |
| `RenderInterface` | `labelle-core/src/render.zig` | `engine.RenderInterface = core.RenderInterface` (`root.zig:582`) | engine's `Game` validates `RenderImpl` at `game.zig:134` |
| `LogSinkInterface` | `labelle-core/src/log.zig` | `engine.LogSinkInterface` | engine's `Game.Log` |
| **`Backend(Impl)`** | **`labelle-gfx/src/backend.zig`** | **(not re-exported by engine)** | **assembler-generated `BackendGfx` adapter** |

The first seven are **already in labelle-core** — the ABI package's job is
mostly to re-export them from one canonical import. The eighth — the render
backend contract — is the outlier: it lives in **labelle-gfx**, not core,
and is consumed differently (by the assembler's generated adapter, not by
the engine's `Game` struct directly).

### The two-contract split (the core insight)

The inventory surfaces a split the RFC glossed over: there are really
**two kinds of contract**, not four:

**Engine-facing contracts** (7 of 8): `AudioInterface`, `VideoInterface`,
`InputInterface`, `GuiInterface`, `GizmoInterface`, `RenderInterface`,
`LogSinkInterface`. These are instantiated by **engine** inside `Game`'s
comptime block (`game.zig:208-233`) — `Game.AudioInterface(AudioImpl)`,
`Game.InputInterface(InputImpl)`, etc. The engine owns the `Impl` slot;
the assembler fills it with the backend's module. These contracts live in
**labelle-core** today and stay there. They describe what the *engine*
needs from a backend.

**Backend-facing contract** (1 of 8): `Backend(Impl)` in
`labelle-gfx/src/backend.zig`. This is **not** instantiated by the engine —
the engine never calls `Backend(Impl)` directly. Instead, the
assembler-generated adapter (`asset_wiring.zig` emits `BackendGfx`) wraps
the backend's raw `gfx.zig` module in the `Backend(Impl)` validation +
dispatch wrapper. The backend's `gfx.zig` is the `Impl`; the generated
`BackendGfx = Backend(backend_gfx_module)` is the validated facade the
engine's asset catalog calls for **images and fonts**
(`decodeImage`/`uploadTexture`/`unloadTexture` + the `decodeFont`/
`uploadFontAtlas`/`unloadFontAtlas` decls). The parallel **audio**-loader
surface (`decodeAudio`/`uploadSound`/`unloadSound(Sound)`) is *not* part of
this gfx `Backend(Impl)` — it is a second, structurally-identical
backend-facing contract: `Backend(Impl)` in
`labelle-engine/audio_backend/src/backend.zig`, wrapped by its own generated
adapter. (Runtime playback — `playSound`/`stopSound` — stays in
`labelle-core`'s `AudioInterface`; see the contract inventory above.)

This is the "render is the anchor" framing from the main RFC, made
concrete: `Backend(Impl)` is the render contract that *wraps* the
backend's draw + asset-streaming surface; the other seven are
engine-side contracts that *consume* individual backend modules. The
ABI package houses both kinds, but they have different instantiation
sites.

### Where the contracts live — the answer

**The ABI package is `labelle-core` itself**, not a new package. The RFC
originally proposed a new `labelle-platform-abi` package (rev 1-5); the
inventory in this revision shows 7 of 8 contracts already live in core,
and the 8th (`Backend(Impl)`) relocates from gfx to core. The split:

- **Engine-facing contracts stay where they are** (`labelle-core/src/
  {audio,video,input,gui,gizmos,render,log}.zig`). Core already
  re-exports them via `root.zig`; engine re-exports core. The ABI package
  IS core — no new import path for engine consumers.
- **`Backend(Impl)` relocates from `labelle-gfx/src/backend.zig` to
  `labelle-core/src/backend_contract.zig`** (or stays in gfx and is
  re-exported by core — see "the relocation question" below).
- **The shared value types** (`DecodedImage`, `DecodedFont`, `Glyph`,
  `CodepointRange`, `CodepointEntry`, `KernPair`, `FontBakeParams`,
  `CompressedDims`) that `Backend(Impl)` returns today move with it —
  they're part of the render contract's surface, not gfx internals.

**The relocation question:** does `Backend(Impl)` move into core, or
stay in gfx and get re-exported? The inventory says **move it**:

1. **Backends depend on core, not gfx.** Today the backend `gfx.zig`
   files don't `@import("labelle-gfx")` — they're the *Impl* that gfx's
   `Backend(Impl)` validates. The validation happens at the assembler-
   generated adapter site, not in the backend. So a backend already
   depends only on core (for `GamepadEvent`, `AndroidBackendContext`,
   etc.) — moving `Backend(Impl)` into core doesn't add a gfx dep to
   backends.
2. **The contract describes what the *engine* needs**, not what gfx
   needs. `decodeImage`/`uploadTexture`/`unloadTexture` +
   `decodeFont`/`uploadFontAtlas`/`unloadFontAtlas` are the asset-
   streaming surface the *engine's* asset catalog calls. gfx's
   `Backend(Impl)` is the validator + dispatcher; the contract's
   *meaning* is engine-side.
3. **The core-diamond.** Today `Backend(Impl)`'s value types
   (`DecodedImage`, `Glyph`, etc.) are structurally identical to
   engine's `font_types.Glyph` / `DecodedPayload.font` — the comment
   at `backend.zig:48-54` says "three repos define structurally-
   identical-but-nominally-distinct `Glyph` types and rely on a
   zero-cost reinterpret at the codegen marshal boundary." Moving
   `Backend(Impl)` + its value types into core makes them
   *nominally* identical too — the `extern struct` reinterpret hack
   goes away.

gfx keeps its `renderer.zig` (the `GfxRendererWith(...)` that implements
`RenderInterface`) — that's gfx-internal, not a contract. Only the
`Backend(Impl)` validator + its value types move.

### Versioning — the `contract_version` field

Today there is **no contract versioning**. The 8 contracts are versioned
only transitively, via the package version pins in `build.zig.zon`:

- core 1.19.0 (ships `AudioInterface`, `RenderInterface`, etc.)
- gfx 1.16.1 (ships `Backend(Impl)` + value types)
- engine 1.63.0 (re-exports core's contracts)
- backends pin core individually (sokol pins core 1.16.1; engine pins
  core via `path = "../labelle-core"`)

The `@hasDecl`-gating pattern means **adding an optional method is
non-breaking** — a backend without the new decl still compiles (the
wrapper falls through to a no-op or `error.NotImplemented`). But **adding
a required decl IS breaking** — the `@compileError("Backend must define
'...'")` fires on every backend that hasn't implemented it yet, with no
diagnostic about *which contract version* the backend was written
against.

The versioning mechanism:

**1. A `contract_version` const on every contract.** Each
`XxxInterface(Impl)` returns a struct that carries the contract version
it validates against:

```zig
// labelle-core/src/backend_contract.zig
pub const BACKEND_CONTRACT_VERSION: u32 = 2;

pub fn Backend(comptime Impl: type) type {
    comptime {
        // ... existing @hasDecl/@compileError validation ...
    }
    return struct {
        pub const Implementation = Impl;
        pub const contract_version = BACKEND_CONTRACT_VERSION;
        // ... dispatch methods ...
    };
}
```

**2. A backend declares which version it targets.** The backend's
`gfx.zig` (the `Impl`) carries a comptime const:

```zig
// backends/sokol/src/gfx.zig
pub const targets_backend_contract: u32 = 2;
```

**3. The assembler-generated adapter asserts compatibility at comptime.**
The generated `BackendGfx = Backend(backend_gfx_module)` instantiation
already validates required decls; add a version check that catches both
directions of mismatch:

```zig
// generated by asset_wiring.zig
const BackendGfx = labelle_core.Backend(backend_gfx);
comptime {
    const t = backend_gfx.targets_backend_contract;
    const p = labelle_core.BACKEND_CONTRACT_VERSION;
    // Backend targets a NEWER contract than core provides — rare, but
    // diagnoses "old core + new backend" with a versioned message.
    if (t > p)
        @compileError(std.fmt.comptimePrint(
            "backend targets backend-contract v{d} but this labelle-core provides v{d} — upgrade labelle-core or use an older backend",
            .{ t, p }));
    // Core bumped a REQUIRED decl the backend hasn't implemented yet —
    // the DOMINANT ecosystem failure (new core + old third-party backend).
    // Gate on strict equality so a breaking bump surfaces a versioned
    // diagnostic instead of falling through to the raw
    // `@compileError("Backend must define 'foo'")` the validator emits.
    if (t < p)
        @compileError(std.fmt.comptimePrint(
            "backend targets backend-contract v{d} but this labelle-core is v{d} — a breaking contract change landed; upgrade the backend",
            .{ t, p }));
}
```

This is **not semver** — it's a contract-version integer that bumps only
when a *required* decl is added/removed/changed. Optional decls (added
behind `@hasDecl`) don't bump it. The rule:

| Change | Bumps `contract_version`? | Breaks backends? |
|---|---|---|
| Add optional method (`@hasDecl`-gated) | No | No |
| Add required method (`@compileError` if missing) | **Yes** (major) | Yes — backends must implement |
| Change a method signature | **Yes** (major) | Yes |
| Rename/remove a required method | **Yes** (major) | Yes |
| Add a value type field | **Yes** (major) | Yes (`extern struct` layout) |
| Relax a contract (make required → optional) | No (minor) | No |
| Tighten a contract (make optional → required) | **Yes** (major) | Yes |

The integer is monotonic but not semver-shaped (no major.minor) — a
contract is either at version N or N+1, and N+1 is a breaking change
for backends written against N. This mirrors how the `@compileError`
guards already work today; the version just makes the mismatch
*diagnosable* instead of a mysterious "Backend must define 'drawTexturePro'".

### The core-diamond version matrix

The "core-diamond" — the same `labelle-core` instance must unify across
gfx + engine + every backend — is already solved at the build-graph
level (Q#5's `overrideImport` + `unifyGfxSubpackageCore`). The
versioning question is: **what happens when core bumps a contract and
the pinned versions disagree?**

Today the pins are:
- engine pins core via `path = "../labelle-core"` (always latest in dev)
  or a URL+hash pin (released).
- gfx pins core via URL+hash (`v1.18.0` in gfx 1.16.1's zon).
- each backend pins core individually (sokol pins `v1.16.1`; bgfx, sdl,
  wgpu, raylib each pin their own).

The assembler's `overrideImport(backend_input, "labelle-core", core_mod)`
unifies them at the module level — but if the backend was *written
against* core 1.16.1 and the project pins core 1.19.0, the backend's
`@hasDecl`-gated calls may reference decls that moved or were renamed.
The version check surfaces this: if `targets_backend_contract` says v1
and the resolved core's `BACKEND_CONTRACT_VERSION` is v2, the comptime
error points at the exact version mismatch rather than a downstream
type-unification failure.

**The matrix collapses to one number per contract** — not "N backends
× contracts × core diamond." Each backend declares one
`targets_backend_contract = N`; core carries one `BACKEND_CONTRACT_VERSION
= M`; the assembler asserts `N == M` at the adapter site (the generated
check `@compileError`s on both `N > M` and `N < M` — see the code sample
above). The
core-diamond unification (Q#5) ensures there's one core module; the
contract version (Q#2) ensures the backend's expectations match that
module's contract surface.

### What this closes (and what stays open)

**Closed by this section:**
- The contract home: the ABI package IS `labelle-core` (7 of 8 contracts
  already live there). `Backend(Impl)` + its value types relocate from
  gfx to core — no new package, no new import path for engine consumers.
- The two-contract split: engine-facing (7 contracts, instantiated by
  `Game`) vs backend-facing (`Backend(Impl)`, instantiated by the
  assembler-generated adapter). Different instantiation sites, same home.
- The versioning mechanism: a `contract_version` integer on each
  contract + a `targets_<contract>_version` on each backend, asserted at
  the adapter's comptime block. Bumps only on breaking changes (required
  decl added/removed/changed); optional `@hasDecl`-gated methods don't
  bump it.
- The core-diamond version matrix: one number per contract, not N×M.
  The build-graph unification (Q#5) ensures one core module; the
  contract version ensures the backend's expectations match.

**Still open (deliberately):**
- **The `extern struct` reinterpret elimination.** Moving `Backend(Impl)`'s
  value types (`Glyph`, `CodepointEntry`, `KernPair`, `DecodedFont`,
  `DecodedImage`) into core makes them nominally identical across
  gfx/engine/backends — the `extern struct` + `@ptrCast` hack at
  `backend.zig:48-54` goes away. But the migration is breaking for every
  backend's `gfx.zig` (they import these types from gfx's `backend.zig`
  today). Defer to the audio-extraction pilot + sokol migration (step 3
  of the plan) — those are the first backends to adopt the new import
  path, and the `extern` hack can be removed once all official backends
  migrate.
- **Contract versioning for engine-facing contracts.** The 7
  engine-facing contracts (`AudioInterface`, etc.) already live in core
  and are versioned by core's package version. Adding a
  `contract_version` to them is mechanically the same as `Backend(Impl)`,
  but the mismatch surface is smaller (engine + backend both pin core;
  the contract is consumed in one place). Lower priority — land
  `Backend(Impl)` versioning first (it's the one with the most backends
  and the thickest surface).
- **Third-party contract pinning.** A third-party backend declares
  `targets_backend_contract = 2` and depends on core via URL+hash. If
  core bumps to v3, the third-party backend's `@hasDecl`-gated calls
  still compile (optional methods don't bump the version), but its
  required-decl set may be stale. The `t < p` branch of the version
  check catches this — surfacing a versioned diagnostic ("backend targets
  v2 but this labelle-core is v3 — a breaking contract change landed;
  upgrade the backend") instead of falling through to the raw
  `@compileError("Backend must define 'foo'")` the validator emits. The
  optional-decl drift is silent by design (`@hasDecl`-gating is the
  back-compat mechanism): a third-party backend targeting v2 against a v3
  core either works (if no required decls changed) or fails with a clear
  version error (if they did).

## Q#5 answer — the build-graph manifest

> Resolves open question #5. Grounded in `src/templates/build_zig.txt`
> (1142 lines, 5 platform variants), `src/build_files.zig` (790 lines,
> the generator that emits it), `src/deps_linker.zig` (673 lines, the
> hardlink + zon-rewrite pass), `src/plugin_manifest.zig` (799 lines,
> the existing manifest schema), and `src/cache/resolve.zig` (653 lines,
> path resolution).

### Inventory — what the build graph wires today

The generated `build.zig` is a **5-way switch on backend × platform**,
emitted by `build_files.zig`'s `generateBuildZig`. Each cell in the
matrix is a hand-written template section (`backends/<name>/templates/
{desktop,mobile,android,wasm,headless}.txt`) plus a matching
`.backend_<name>[_<platform>]` section in `src/templates/build_zig.txt`.
Today's 5×N matrix:

| | desktop | wasm | android | ios | headless |
|---|---|---|---|---|---|
| **raylib** | `backend_raylib` + `link_raylib` | `backend_sokol_wasm`-shaped + `wasm_emsdk_raylib` + `link_raylib_wasm` | — | — | — |
| **sokol** | `backend_sokol` + `link_sokol` | `backend_sokol_wasm` + `wasm_emsdk_sokol` + `link_sokol_wasm` | `backend_sokol_android` + `android_link` | `backend_sokol_ios` + `ios_link` | — |
| **bgfx** | `backend_bgfx` + `link_bgfx` | — | `backend_bgfx_android` + `android_link_bgfx` | — | — |
| **sdl** | `backend_sdl` + `link_sdl` | — | — | — | — |
| **wgpu** | `backend_wgpu` + `link_wgpu` | — | — | — | — |
| **null** | `backend_null` (no link step) | — | — | — | `headless.txt` template |

Each cell wires **four orthogonal things** that the manifest must
decompose:

**1. Module graph (the `b.dependency` + `overrideImport` web).**
Today this is a per-backend switch (`build_files.zig:212-269`) emitting
`.backend_<name>` sections, each pulling `backend_gfx` / `backend_input`
/ `backend_audio` / `backend_window` (and bgfx-Android adds `backend_app`).
The assembler then injects shared modules into every plugin
(`build_files.zig:298-339`) — core/gfx/engine/ecs/backend-×-4/gui — and
runs **the core-diamond unification** (`overrideImport` + `unifyGfxSubpackageCore`).

**2. Native artifacts (the `linkLibrary` calls).**
Each backend's `.link_<name>` section links its native C archive:
raylib → `raylib_artifact`, sokol → `sokol_clib`, bgfx → `bgfx_artifact`
+ `glfw_artifact`, wgpu → `glfw_artifact`, sdl → (none, SDL is
system-linked), null → (none). These are backend-specific and have
**no generic interface** today — the template hardcodes the artifact
name + any per-OS framework supplements (`.link_sokol` adds
IOSurface/CoreFoundation on Darwin; `.link_wgpu` adds Metal/Foundation/
QuartzCore; `.link_raylib` adds OpenGL/GL/opengl32 by OS).

**3. Platform system libraries + NDK/Emscripten/iOS-SDK wiring.**
This is the most platform-specific layer:
- **Android** (`.android_link` / `.android_link_bgfx`) — links `android`
  /`log`/`GLESv3`/`EGL`/`m`/`dl`, generates a `libc.txt` pointing at the
  NDK sysroot, and bgfx-Android differs from sokol-Android (bgfx links its
  own `bgfx_artifact` + omits the sokol `sokol_clib`; the system-lib set
  is otherwise identical).
- **iOS** (`.ios_link`) — `linkIosFrameworks(exe)` links Foundation/UIKit/
  Metal/MetalKit/AudioToolbox/AVFoundation/QuartzCore/GameController +
  `configureSdkPaths` for the C headers.
- **WASM** (`.link_*_wasm`) — the Emscripten `emccStep` / `emLinkStep`
  shell-out, with `STACK_SIZE=512KB`, `ALLOW_MEMORY_GROWTH=1`, and
  backend-specific emsdk dep (`wasm_emsdk_raylib` vs `wasm_emsdk_sokol`).
- **Desktop** — per-OS framework links inline in each `.link_*` section.

**4. Packaging (the post-link artifact bundle).**
Only Android (`.android_package`) ships a packaging step today —
`apk-staging/` copy + `zip` + `apksigner` shell-out, with ABI directory
derived from the build target. iOS installs the exe directly; WASM
installs the `web/` dir via emcc; desktop installs the exe. The RFC's
*Platform packaging* section already proposes this decomposes like audio
did — a shared platform-packager layer.

### The core-diamond generalization

Today's `unifyGfxSubpackageCore` (`build_zig.txt:355-363`, duplicated
**5 times** — once per platform header) does three overrides:

1. `overrideImport(gfx_mod, "labelle-core", core_mod)` — dedupe core
   across gfx/engine.
2. `overrideImport(engine_mod, "labelle-core", core_mod)` — dedupe core
   across engine/gfx.
3. `unifyGfxSubpackageCore(gfx_mod, core_mod)` — recurse into gfx's
   sub-packages (`camera`, `spatial_grid`, `tilemap`) and override their
   pinned core.

Plus **per-backend core unification** (the `if (backend_input.import_table.
get("labelle-core"))` / `sdl_gamepad` guards in `.backend_raylib` /
`.backend_sokol` / `.backend_bgfx`). These are **8 distinct override
sites** across the 5 backends, each with a different shape:

| Backend | What gets unified onto app core |
|---|---|
| raylib | `backend_input` (core) + `sdl_gamepad` transitive (underscore key) |
| sokol desktop | `sdl_gamepad` transitive + `backend_input` on Linux (direct core import) |
| sokol wasm | (none — no gamepad, no core import) |
| sokol android | (none — android_gamepad is a no-op off-Android, no core import on `input`) |
| bgfx desktop | `sdl_gamepad` transitive |
| bgfx android | `backend_input` (core, for `AndroidBackendContext`) |
| sdl | `backend_input` (underscore key `labelle_core`) |
| wgpu / null | (none) |

**The generalization:** every provider that imports `labelle-core`
(transitively or directly, under either the hyphenated or underscore
key) must be unified onto the app's single `core_mod`. Today this is
hand-coded per backend; the manifest must let the assembler do it
**generically** — walk the resolved provider's module graph and override
every `labelle-core` / `labelle_core` import onto `core_mod`. The
`unifyGfxSubpackageCore` recursion generalizes the same way: any
sub-package that imports core gets the override (the hardcoded `camera`
/ `spatial_grid` / `tilemap` list becomes "every transitive sub-import
of gfx that names core").

### The manifest build-side schema

A provider's manifest extends the existing `plugin.labelle` schema
(`plugin_manifest.zig`) with build-side declarations. The runtime
manifest (from rev 5's *Platform packaging* section) already sketches
the contracts + platform matrix; the build side adds what the assembler
needs to wire the build graph generically:

```zig
// backend.labelle — the build-side manifest (extends plugin.labelle)
.{
    .name = "sokol",
    .id = "labelle.sokol",  // canonical namespaced ID (see "Provider identity")
    .manifest_version = 2,  // v2 adds the build-side fields
    .convention_dirs = &.{},  // back-compat with v1 (unused by backends)
    .capabilities = &.{       // declared up front; resolver checks before build
        .screenshots, .compressed_textures, .fonts, .gamepad_polling,
        .raw_gui_adapter, .headless, .surface_loss,
    },

    // ── Build-side ──
    .modules = .{
        // Named modules the provider exposes. The assembler imports
        // these into the root module by these names.
        .gfx    = "src/gfx.zig",
        .input  = "src/input.zig",
        .audio  = "src/audio.zig",
        .window = "src/window.zig",
        // Optional platform-specific module (bgfx-Android's android_app):
        .android_app = "src/android_app.zig",  // only on .android
    },
    .artifacts = .{
        // C archives the provider ships, keyed by name. The assembler
        // links these into the root artifact.
        .sokol_clib = .{
            .source = "src/sokol_clib.c",  // or a build.zig hook (see below)
            .pic = true,  // force -fPIC (Android .so requirement)
        },
    },
    .system_libs = .{
        // Per-platform system libraries. Keyed by platform; merged into
        // the root module's link line by the assembler.
        .desktop = .{ .macos = &.{ "IOSurface", "CoreFoundation" } },
        .android = &.{ "android", "log", "GLESv3", "EGL" },
        .wasm    = &.{},  // emcc handles system libs
    },
    .frameworks = .{
        // Apple frameworks, separately from system_libs (Zig distinguishes
        // linkFramework from linkSystemLibrary).
        .ios = &.{ "Foundation", "UIKit", "Metal", "MetalKit",
                   "AudioToolbox", "AVFoundation", "QuartzCore",
                   "GameController" },
    },
    .platforms = .{
        // The (backend × platform) matrix from rev 5's runtime manifest.
        // `entry` is the entry-point source; `target` is the cross-compile
        // triple; `package` is the packaging recipe reference.
        .desktop = .{ .entry = "templates/desktop.txt", .target = .native, .package = .binary },
        .android = .{ .entry = "templates/mobile.txt",
                      .target = "aarch64-linux-android",
                      .package = .{ .apk = .{ .manifest = "AndroidManifest.xml.tmpl" } } },
        .wasm    = .{ .entry = "templates/wasm.txt", .target = "wasm32-emscripten",
                      .package = .{ .web = .{ .shell = "index.html.tmpl" } } },
        // .ios = … — provider declares what it supports
    },
    .build_hook = "build.zig",  // OPTIONAL: see "the build hook" below
}
```

### What the assembler does generically

With the manifest, `build_files.zig`'s 5-way `switch (cfg.backend)`
collapses to a single generic path:

1. **Resolve** the provider(s) via the existing `cache.resolvePlugin`
   rail (name → repo → cached path). The closed `Backend` enum becomes
   shorthand for official providers (`.sokol` → the `labelle-backends`
   monorepo's sokol provider, canonical ID `labelle.sokol`). **Validate
   identity + capabilities before wiring**: error on canonical-ID collision
   (or a third party claiming `labelle.*`), and check each resolved provider's
   declared `.capabilities` against the project's required set (explicit
   `.requires` + capabilities derived from platform/target/GUI) — a missing
   capability is an early, readable error here, not a deep `@compileError`
   later (see *Opening the ecosystem*).
2. **Emit `b.dependency`** for each resolved provider module the project
   declared (`.render`, `.window`, `.audio`, `.input`), pulling the
   modules named in `.modules`.
3. **Run core-diamond unification generically** — walk every imported
   provider module's `import_table`, override any `labelle-core` /
   `labelle_core` key onto `core_mod`, and recurse into sub-packages
   that import core (generalizing the hardcoded `camera`/`spatial_grid`
   /`tilemap` list).
4. **Link artifacts** — for each `.artifacts` entry, call
   `linkLibrary(backend_dep.artifact(name))`; apply `.pic` if set.
5. **Link system libs + frameworks** — iterate `.system_libs[platform]`
   and `.frameworks[platform]`, calling `linkSystemLibrary` /
   `linkFramework` on the root module. Per-OS gating (the `switch
   (target.result.os.tag)` blocks) moves into the manifest's per-OS
   keys rather than inline template conditionals.
6. **Emit the entry point** — splice the provider's `templates/
   <platform>.txt` (the `Game`-hook driver from Q#1) into the generated
   `main.zig`. The entry-point shape is the provider's, not the
   assembler's.
7. **Delegate packaging** — hand the built artifact to the shared
   platform-packager (APK/wasm/iOS) referenced by `.platforms[platform].
   package`.

### The build hook — when the manifest isn't enough

Some build wiring is too dynamic for a static manifest (sokol's
`with_imgui` option, which must match the GUI bridge's option set to
avoid double-caching `sokol_clib`; bgfx's NDK-sysroot path computation;
the Emscripten `emccStep` shell-out). Today these live as hardcoded
`.backend_sokol` / `.link_sokol_wasm` template sections.

The manifest's `.build_hook = "build.zig"` field lets a provider ship a
**`build.zig` fragment** the assembler imports via `@import("provider")`
and calls at **two** injection points — before and after the generic
wiring. The contract:

```zig
// Provider's build.zig — the hooks the assembler calls.
// HookContext carries the build, the target, the project config, and
// (for post_wire) the resolved modules + root artifact.

/// Called BEFORE `b.dependency` — the provider can set build options
/// that affect how the dependency's artifact is built (sokol's
/// `with_imgui`, gamepad flags). Returns an options struct the
/// assembler passes to `b.dependency(name, options)`.
pub fn preWire(b: *std.Build, ctx: HookContext) DependencyOptions {
    return .{ .with_imgui = ctx.gui_is_imgui, .gamepad_enabled = ctx.gamepad };
}

/// Called AFTER generic module/artifact/system-lib wiring — the provider
/// can supplement the graph (NDK sysroot, emcc shell-out, extra links).
pub fn postWire(b: *std.Build, ctx: HookContext) void {
    const clib = ctx.backend_dep.artifact("sokol_clib");
    ctx.exe.root_module.linkLibrary(clib);
    // ... provider-specific wiring the manifest can't express statically
}
```

This is the escape hatch — the **typed manifest covers ~95%** (modules +
artifacts + system libs + frameworks + capabilities + platform matrix); the
build hook covers the ~5% that needs to run build-graph logic. To keep the hook
from degrading into an *arbitrary backend build script*, it is **constrained by
contract**: `HookContext` and `DependencyOptions` are **versioned** types (they
bump with `manifest_version`, and the assembler asserts the provider targets a
compatible version — same discipline as the runtime contracts); the hook may
read only the **documented** `ctx` fields and may only construct build-graph
nodes (`b.dependency`, `linkLibrary`, module wiring). No filesystem access
outside the provider's own package, no network, and shell-outs limited to the
platform-packager steps the manifest already models (emcc). A provider that
needs more than the documented surface is a signal to **extend the manifest**,
not the hook. The `pre_wire`/`post_wire`
split is necessary because some dynamic wiring (sokol's `with_imgui`,
bgfx's `gui_enabled`) must affect `b.dependency`'s options struct *before*
the artifact is built, while other wiring (NDK sysroot paths, emcc
shell-out, extra `linkLibrary` calls) supplements the graph *after*
generic wiring. A single `wire`-after-generic hook (the rev 7-9 design)
is known-insufficient — sokol's `with_imgui` is a shipped consumer today.

### Lazy native deps — the slim-fetch requirement

Rev 5 reframed slim-fetch as a **packaging requirement**, not a
guarantee. The build-graph manifest makes this concrete: each provider's
heavyweight native dep (sokol's C source, bgfx's C++ TUs, raylib's C
archive) must be a **lazy, external Zig dependency** in the provider's
`build.zig.zon` — *not* vendored into the fetched package, *not*
referenced eagerly by the root build graph. The manifest's `.artifacts`
entries point at C source the provider's own `build.zig` compiles; the
assembler never sees the native source unless the provider is resolved.

The existing `deps_linker.zig` hardlink pass (`createDepsLinks`) already
stages resolved packages into `.labelle/deps/<name>/` and rewrites
relative `.path` deps — the lazy-dep requirement is that a provider's
zon declares its native dep as a URL-pinned `lazy = true` dependency
(Zig 0.16 feature), so `b.dependency("labelle_sokol", .{...})` only
fetches sokol's C source when a project actually resolves `.render =
.sokol`. A project using `.render = .bgfx` never triggers sokol's fetch.

### What this closes (and what stays open)

**Closed by this section:**
- The manifest build-side schema: `.modules` / `.artifacts` /
  `.system_libs` / `.frameworks` / `.platforms` / `.build_hook`.
  Grounded in every concrete wiring the 5 backend templates ship today.
- The core-diamond generalization: walk the provider module graph and
  override every core import (8 hand-coded sites → 1 generic pass).
- The build hook as the escape hatch for dynamic wiring (`with_imgui`
- The build hook split: `pre_wire` (before `b.dependency`, returns options)
  + `post_wire` (after generic wiring, supplements the graph). Sokol's
  `with_imgui` is a shipped consumer today — the split is necessary, not
  optional.
- Lazy native deps as a concrete zon-level requirement (`lazy = true`
  per provider), not an abstract claim.

**Still open (deliberately):**
- ~~**Hook injection ordering.**~~ **Resolved**: the `pre_wire`/`post_wire`
  split (above) handles both the `b.dependency`-time option case and the
  post-generic-wiring supplement case.
- **GUI bridge wiring.** Today the GUI bridge (imgui) is resolved by
  the closed enum (`gui_resolve.zig`) and linked via a separate
  `.gui_bridge` template section + `with_imgui`/`gui_enabled` flags
  passed to the backend. With per-contract providers, the bridge needs
  its own manifest entry declaring which provider(s) it's compatible
  with — this is open question #6, not answered here.
- **The tests target.** `build_files.zig` emits a separate `.tests_*`
  shape (null backend, no exe, no link) via `generateTestsTarget`. The
  manifest must declare how a provider participates in the test target
  (likely: the null provider is the test-target provider, and the
  manifest's `.platforms` matrix includes a `.test` entry).
- **Migration sequencing.** The 5-way switch can't be deleted until
  every official backend ships a manifest + build hook. The incremental
  path: land the manifest schema + generic wiring alongside the existing
  switch, migrate one backend at a time (sokol first — it's the
  headless-screenshot-verifiable one, same as Q#1's pilot), then delete
  the switch.

## Opening the ecosystem — identity, capabilities, conformance

Closing the backend enum turns three things that were implicit (safe only
*because* the provider set was closed and toolkit-owned) into explicit contracts
the moment a stranger can publish a provider. The review's framing — *a typed
provider graph + capabilities + conformance, with hooks as a minimal escape
hatch* — is the spine here. None of this blocks the pilots; all of it is
required before the resolver opens to third parties (migration step 5).

### Provider identity & collision rules

Today `.sokol` / `.bgfx` are enum tags — globally unique by construction. Once
`.render = .{ .repo = "github:someone/labelle-vulkan" }` is legal, **bare names
collide**: two vendors can each ship a `vulkan` provider.

Each provider declares a **canonical ID** in its manifest — a reverse-namespaced
`<namespace>.<name>`:
- **Official** providers live under the reserved `labelle.` namespace:
  `labelle.sokol`, `labelle.bgfx`, `labelle.miniaudio` (the `labelle-backends`
  monorepo owns it).
- **Third-party**: `<vendor>.<name>` — `someone.vulkan`, `acme.sokol-fork`.

Resolution rules:
- The closed enum tags are **shorthands for `labelle.*` IDs only**
  (`.render = .sokol` ⇒ `labelle.sokol`). A third-party provider is never
  reachable by a bare tag — it is named by repo (which carries its ID) or by
  full canonical ID once installed.
- The assembler **errors on collision at resolve time**: two resolved providers
  claiming the same canonical ID, or a third-party manifest claiming a
  `labelle.*` ID, is a hard error — not a silent last-wins. This is the
  provider-graph analog of the core-diamond unification check.
- The **ID is the stable identity** (not the repo URL or cache path) used by the
  GUI-bridge name-match (Q#6) and the capability table below, so a provider can
  move repos without breaking bridges that target it.

This reuses the plugin system's resolve-by-name rail (`resolvePlugin`); identity
just makes the key explicit and namespaced instead of assuming a closed set.

### Capability negotiation

`@hasDecl`-gating answers "*can the backend's code call this?*" at comptime — but
a project author hits that as a deep compile error in generated code, long after
the wrong provider was chosen. **Capabilities** move the check **forward**, to
resolve time, with a project-level diagnostic.

Each provider declares a `.capabilities` set in its manifest; the assembler
checks the project's *required* capabilities against the *resolved* providers'
*declared* capabilities **before emitting the build graph**:

```zig
.capabilities = &.{
    .screenshots,          // takeScreenshot() — headless CI, preview
    .compressed_textures,  // KTX2/Basis decode path
    .fonts,                // decodeFont / uploadFontAtlas
    .gamepad_polling,      // input provides a gamepad source
    .raw_gui_adapter,      // in-backend imgui adapter (Q#6), not just the C++ bridge
    .headless,             // can run with no window surface
    .surface_loss,         // implements surfaceLost / surfaceRestored (mobile)
},
```

The project's required set is **explicit** (`.requires = &.{ .screenshots }` for
a CI screenshot target) *or* **derived** by the assembler: a `.platform =
.android` build requires `.surface_loss`; a GUI plugin needing an in-backend
adapter requires `.raw_gui_adapter` from the render provider; a `--screenshot`
target requires `.screenshots`. The error is the payoff:

```
error: render provider 'labelle.bgfx' does not support capability 'screenshots'
       required by the headless screenshot target.
       providers with 'screenshots': labelle.sokol, labelle.null
```

instead of a `@compileError("window has no takeScreenshot")` from deep inside
generated `main.zig`. Capabilities are the **declarative mirror** of the
`@hasDecl` optionals: the optional decl is the *mechanism*, the capability flag
is the *advertisement* the resolver reads without compiling the provider.

### Conformance suites — behavior, not just shape

`assertBackend(Impl)` + `@hasDecl` check a provider has the *right shape* (decls
exist, signatures match). They do **not** check it *behaves* correctly — that
`uploadTexture` round-trips an image, that the input event mapping is consistent,
that `surfaceRestored` actually re-uploads. With the provider set opening to
authors the toolkit doesn't control, behavior matters more than shape.

Each contract ships a **shared conformance suite** in `labelle-core` (next to the
contract + its `mock_backend` reference impl), parameterized over the provider
`Impl`:

| Contract | Conformance suite checks |
|---|---|
| render — draw | the `mock_backend` records draw calls; the suite asserts the call sequence for a known scene matches a golden trace |
| render — loader | decode→upload→render round-trips a known image to a known framebuffer; the compressed-texture path matches the uncompressed reference within tolerance; font atlas bakes the expected glyph metrics |
| audio — loader | `decodeAudio` of a known WAV yields the expected sample count / rate / channels; `uploadSound`→`unloadSound` is leak-free under the test allocator |
| input | a scripted event stream maps to the expected engine-level input state (key down/up edges, mouse/touch coords, gamepad axes) |
| window lifecycle | `init`→`frame`*→`deinit` ordering; on a `surface_loss`-capable provider, `surfaceLost`→`surfaceRestored` preserves game state and re-uploads GPU resources |

A provider's CI runs `zig build conformance` (a generated test target that
instantiates the suites over its `Impl`); the `labelle-backends` monorepo runs
all of them. A provider is **conformant iff it passes the suite for every
capability it advertises** — which is what makes the capability table
*trustworthy*: `.screenshots` then means "passed the screenshot conformance
test", not merely "has a `takeScreenshot` decl".

### Why this keeps hooks minimal

These three together are what let the build hook stay a **~5% escape hatch**
(above) rather than the integration surface: identity + the typed manifest
describe *what* a provider is and *what* it can do, declaratively; conformance
*proves* it; the hook only runs the residual build-graph logic the manifest
can't express statically — with a versioned, documented `HookContext` and no
licence for arbitrary work. That is the "typed provider graph + capabilities +
conformance + minimal escape hatches" shape the review asks for.

## Open questions

1. ~~**The `Game`-lifecycle ABI**~~ — **answered above**. The hook surface is
   `init` / `deinit` / `frame(dt)` / `running` / `event` / `suspend_` /
   `resume_` / `surfaceLost` / `surfaceRestored` (last five `@hasDecl`/null-gated).
   The surface pair is explicit (not an overloaded `contextLost`), so
   `deinit`/`init` aren't reused for mobile surface recreation; the engine
   responds via `gpuResourcesInvalidated` → `reuploadAssets`. Per-frame work
   (screenshot, preview, GUI, `setScreenSize`/`setDesignSize`) stays codegen,
   not lifecycle. Residual: the `surfaceRestored` re-upload *granularity* + the
   `Event` type shape — gated on the **bgfx-Android pilot** (migration step 4),
   which exercises the `TERM_WINDOW`+`INIT_WINDOW` surface-recreation cycle. The
   audio pilot (step 2) and sokol-desktop conversion (step 3) validate extraction
   mechanics but have no surface-loss cycle to exercise.
2. ~~**Where the contracts live + versioning**~~ — **answered above**. The
   ABI package IS `labelle-core` (7 of 8 contracts already live there).
   `Backend(Impl)` + its value types relocate from gfx to core. Versioning:
   a `contract_version` integer on each contract + a
   `targets_<contract>_version` on each backend, asserted at the
   assembler-generated adapter's comptime block. Bumps only on breaking
   changes (required decl added/removed/changed); optional `@hasDecl`-
   gated methods don't bump it. Residual: the `extern struct` reinterpret
   elimination (defer to migration), engine-facing contract versioning
   (lower priority).
3. ~~One monorepo vs per-backend repos~~ — **resolved**: one `labelle-backends`
   monorepo for the official providers (one thing to maintain), with slim-fetch
   preserved by Zig **lazy deps** per provider; third parties publish their own
   repo. Contract granularity and repo count are orthogonal, so per-contract
   composition costs no extra repos.
4. ~~**Gamepad as an input-extension**~~ — **answered above**. Gamepad is
   an input-extension, not a fifth contract. The three existing sources
   (`sdl_gamepad`, `android_gamepad`, `core.gamepad_source`) are packages
   composed alongside the input provider; the engine's
   `backend_polls_gamepads` / `uses_os_gamepad_source` routing already
   treats them as extensions. The manifest's `input_extensions` field
   (per-platform) replaces today's `deps_linker.zig` staging switches.
   Residual: the `Source` namespace shape (informal today), multiple
   extensions on one platform (defer until needed).
5. ~~**The build-graph generalization**~~ — **answered above**. The manifest
   build-side schema (`.modules` / `.artifacts` / `.system_libs` /
   `.frameworks` / `.platforms` / `.build_hook`), the core-diamond
   generalization (8 hand-coded override sites → 1 generic graph walk),
   the build-hook escape hatch (`pre_wire`/`post_wire` split) for dynamic
   wiring, and lazy native deps as a concrete zon-level requirement.
   Residual: GUI bridge wiring (defers to #6), tests-target manifest,
   migration sequencing.
6. ~~**GUI-bridge compatibility**~~ — **answered above**. The bridge lookup
   is keyed by **render provider name** (not a closed enum). Two integration
   patterns: external C++ bridge (default — standalone artifact link) and
   in-backend adapter (declared in the provider manifest's `build_options`,
   triggered by the GUI resolver on a name match). The `with_imgui`/
   `gui_enabled` flags in `build_files.zig` are replaced by the provider
   manifest's `build_options` + the GUI resolver's name-match predicate.
   `render_interface` GUIs (clay, simple-*) are unaffected — no bridge, no
   change. Residual: the name-match predicate home (GUI manifest vs provider
   manifest), the sokol-imgui adapter module relocation, multiple GUI plugins.
7. **Provider identity & collisions** *(added rev 13)* — **answered above**.
   Each provider declares a canonical `<namespace>.<name>` ID; `labelle.*` is
   reserved for the official monorepo and is what the enum shorthands resolve to;
   the assembler errors on ID collision and on a third party claiming `labelle.*`.
   The ID is the stable key for GUI bridges + capabilities. Residual: the on-disk
   install registry for resolving a bare canonical ID (vs a repo URL).
8. **Capability negotiation** *(added rev 13)* — **answered above**. Providers
   declare a `.capabilities` set; the assembler checks project-required
   capabilities (explicit `.requires` + derived from platform/target/GUI) against
   the resolved providers *before* emitting the build graph, erroring with a
   project-level message instead of a deep `@compileError`. Capabilities are the
   declarative mirror of the `@hasDecl` optionals. Residual: the full
   derived-requirement table (which platforms/targets imply which capabilities).
9. **Conformance suites** *(added rev 13)* — **answered above**. Each contract
   ships a shared conformance suite in `labelle-core` (next to its `mock_backend`),
   parameterized over the provider `Impl`; a provider is "conformant" iff it
   passes the suite for every capability it advertises — which is what makes the
   capability table trustworthy. Residual: the golden-trace fixtures for the
   draw-call and input-mapping suites.
