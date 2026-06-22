# RFC: Pluggable backends — make the assembler backend-agnostic

**Status:** Draft (revision 5 — folds in the rev-4 review: full render/audio contract surface incl. loaders/fonts; platform-qualified cascade `(platform, render)`; lazy-deps reframed as a requirement; new Platform-packaging & manifest section; GUI-bridge open question; terminology + stale-wording fixes)

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

1. **render** — gfx's existing `Backend(Impl)`, and it is **more than draw
   calls**. Alongside `drawTriangle`/`drawTexturePro`/`loadTexture` it carries the
   *asset-streaming surface* the generated game already depends on:
   `decodeImage` / `uploadTexture` / `unloadTexture`, the optional
   compressed-texture decls, and the font decls. The ABI must capture this **full
   surface** (see `src/codegen/blocks/asset_wiring.zig`) — otherwise a backend
   could "conform" to the draw bag and still fail the generated build. Most-ready
   of the four, but not as thin as a first read suggests.
2. **input** — `getMouseX/Y`, `isKeyDown`, `getTouchX/Y`, gamepad, wheel. A
   method-bag.
3. **audio** — the engine's `AudioInterface(Impl)` — not just `playSound` /
   `loadSound` but the loader surface too: `decodeAudio` / `uploadSound` /
   `unloadSound`. The contract already lives in **labelle-core** (engine
   re-exports it); the ABI package becomes the single canonical import — the
   core-diamond in miniature.
4. **window** — the inversion-of-control crux. The window **owns the run loop**
   and the per-frame render target:
   ```zig
   // required: init(cfg) → deinit() → shouldQuit() → beginFrame() *Target → endFrame()
   // optional (@hasDecl-gated): takeScreenshot()
   ```

**Capability differences are optional `@hasDecl`-gated decls** — e.g. headless
screenshot support (sokol) vs not (raylib) — exactly how gfx already handles
optional draw methods. (This is the same split we lived through fixing sokol
headless screenshots; it falls straight out of the contract.)

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
Audio decomposes one level further: the duplicated part (WAV/OGG decode + PCM
mixer) is backend-agnostic; only the *output device* is platform-specific.
- a shared **`labelle-audio`** = the `AudioInterface` impl (decode + mix), written
  once, and
- a pluggable **audio-device** sink: providers `sokol_audio`, `miniaudio`,
  `sdl_audio`, `raudio`, `null`.

"sokol has its own, bgfx has none" maps cleanly: sokol's device = `sokol_audio`;
bgfx's device = `miniaudio`; the mixer above them is shared — deleting ~3
reimplementations. Audio is the **ideal first extraction**: already contracted
(`core.AudioInterface`), and with **zero GPU-context sharing** (its own device +
thread), so the hardest part of this RFC — the context handoff — simply does not
apply to it.

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

### NEW — `labelle-platform-abi` (a thin leaf package)
Houses the four comptime contracts + the shared value types; almost no deps.
gfx, engine, and every backend depend on it. A backend author opens exactly one
package to see "here's everything I must implement, here's the version I pin."

### labelle-gfx
- Code barely changes — concrete backends move *out*, not *in* (no bloat, no
  native deps pulled into gfx).
- Promote `Backend(Impl)` from implicit/duck-typed → a **versioned, documented
  public contract**: a written spec, a `comptime assertBackend(Impl)` that fails
  loudly, `mock_backend` as the reference/conformance impl, semver discipline
  (adding a required `Impl` decl = breaking for every backend).
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

1. **Stand up `labelle-platform-abi`** with the four contracts + `assertBackend`;
   make gfx's existing `Backend` conform (no behaviour change). (`AudioInterface`
   already lives in labelle-core — it just moves/re-exports.)
2. **Pilot with audio** — the lowest-risk slot (already contracted, *zero*
   context-sharing). Extract the shared `labelle-audio` mixer + the device
   providers (`sokol_audio`/`miniaudio`/…) and collapse the per-backend mixer
   duplication. Immediate, measurable payoff with no entry-point or context work.
3. **Convert one full backend** (sokol — render+window+input; it's the
   headless-screenshot-verifiable one) to implement the contracts from a separate
   location, *while keeping the enum* as a resolver shorthand. Prove a generated
   game still builds + runs.
4. **Open the resolver** — `.backend` accepts a full-stack package *and*
   per-contract overrides (`.{ .render = .bgfx, .audio = .miniaudio }`); the
   closed enum values become **shorthands** resolving to the official providers.
   **Backward-compatible**: `.backend = .sokol` keeps working.
5. **Extract the remaining backends**; slim the assembler (lazy native deps per
   provider).

## Open questions

1. **The `Game`-lifecycle ABI** — the run-loop splice itself is now answered (a
   hook contract, see above), but the full hook *surface* is not: beyond
   `frame`, the entry point must deliver input/resize events and especially
   mobile **suspend/resume + GPU context-loss** to the game. Pin it by
   **inventorying what `templates/{desktop,mobile}.txt` inject today** (event
   forwarding à la `sokolEvent`, screenshot state, GUI event hooks) so nothing
   regresses. The direct successor to the codegen-splice crux.
2. **Where the contracts live + versioning** — gfx owns `render`; does it
   relocate into the ABI package, or stay in gfx and be re-exported? How does a
   backend pin "I implement contract vN"? The version matrix (N backends ×
   contracts × the core diamond) needs a story.
3. ~~One monorepo vs per-backend repos~~ — **resolved**: one `labelle-backends`
   monorepo for the official providers (one thing to maintain), with slim-fetch
   preserved by Zig **lazy deps** per provider; third parties publish their own
   repo. Contract granularity and repo count are orthogonal, so per-contract
   composition costs no extra repos.
4. **Gamepad as an input-extension** — `android_gamepad` / `sdl_gamepad` look
   like input *extensions* composed alongside the window provider, not a fifth
   top-level contract. State this explicitly so the ABI doesn't sprawl. (The
   mobile/platform side moved to *Platform packaging & the manifest*.)
5. **The build-graph generalization** — the core-diamond unification + the
   per-provider native-dep wiring, done generically. This is the *build side* of
   the manifest (see *Platform packaging*); with #1 it's the hardest remaining
   work, so a minimal "what a provider's manifest ships" sketch would let it be
   designed in parallel with the runtime ABI.
6. **GUI-bridge compatibility** — raw backend GUIs (imgui bridges) are resolved
   by the *closed enum* today (`gui_resolve.zig`) and gated by backend-specific
   build flags (sokol `with_imgui`, bgfx `gui_enabled`). With per-contract
   providers it is unspecified whether a GUI bridge targets render / window /
   input / a full-stack composition — a project using `.render = .bgfx,
   .window = .glfw` (or a third-party renderer) has no defined bridge lookup.
   Needs a compatibility rule.
