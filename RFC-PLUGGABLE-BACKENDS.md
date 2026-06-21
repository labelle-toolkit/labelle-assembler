# RFC: Pluggable backends — make the assembler backend-agnostic

**Status:** Draft (revision 1)

**Tracking:** labelle-toolkit/labelle-assembler#377

**POC:** runnable Zig 0.16 prototype on #377 (window / render / context contracts) — referenced throughout; it de-risks the runtime side of this RFC.

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

1. **render** — gfx's existing `Backend(Impl)` (`drawTriangle`,
   `drawTexturePro`, `loadTexture`, …). The most-ready of the four.
2. **input** — `getMouseX/Y`, `isKeyDown`, `getTouchX/Y`, gamepad, wheel. A
   method-bag.
3. **audio** — `playSound`, `loadSound`, slots. A method-bag.
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

## The backend as a package

A backend becomes a resolved-by-name dependency, declared like a plugin:

```zig
.backend = .{ .name = "my-vulkan-thing", .repo = "github:someone/labelle-vulkan" },
```

Each backend package provides: the four runtime impls + their private context
wiring + a **manifest** declaring its codegen contribution, build deps, supported
platforms, and which contract versions it implements. The existing plugin rails
(`resolvePlugin`, manifest-driven codegen, `overrideImport`, the deps linker)
are reused.

## Per-layer changes

### NEW — `labelle-platform-abi` (a thin leaf crate)
Houses the four comptime contracts + the shared value types; almost no deps.
gfx, engine, and every backend depend on it. A backend author opens exactly one
crate to see "here's everything I must implement, here's the version I pin."

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
  generated game) get formalized and given a versioned home in the ABI crate.

### The backends
- Extracted to their own repo(s) — one `labelle-backends` monorepo, or
  per-backend repos. Each implements the ABI contracts + ships a manifest.

## The codegen splice (the hard assembler-side problem)

Today `templates/desktop.txt` bakes the backend's window + run-loop *together*
with the assembler's engine wiring (registries, scene/script setup, the
`project_y_axis` const, hooks). Pluggability requires **splitting that seam**: an
assembler-owned **generic skeleton** (backend-blind — the POC's `run`) into which
the backend **splices** its run-loop fragment via defined hook points, plus a
build fragment the assembler composes. Designing this manifest/fragment contract
is the core remaining work — the runtime contract is proven; this is where "can a
stranger really plug in" gets decided.

## Migration plan (incremental, not a big bang)

1. **Stand up `labelle-platform-abi`** with the four contracts + `assertBackend`;
   make gfx's existing `Backend` conform (no behaviour change).
2. **Convert ONE backend** (sokol — it's the headless-validatable one, so we can
   screenshot-verify) to implement the contracts from a separate location, *while
   keeping the enum* as a resolver shorthand. Prove a generated game still builds
   + runs.
3. **Open the resolver** — `.backend` accepts `.{ .name, .repo }`; the closed
   enum values become **shorthands** that resolve to the official backend
   packages. **Backward-compatible**: existing `.backend = .sokol` keeps working,
   resolving to `labelle-toolkit/labelle-sokol@<ver>`.
4. **Extract the remaining backends**; slim the assembler.

## Open questions

1. **The codegen-splice / manifest contract** — the hook points + build
   fragments a backend ships, and how the assembler composes them blind. *The
   crux*, and the next thing to POC (one layer up from where the runtime POC
   stopped).
2. **Where the contracts live + versioning** — gfx owns `render`; does it
   relocate into the ABI crate, or stay in gfx and be re-exported? How does a
   backend pin "I implement contract vN"? The version matrix (N backends ×
   contracts × the core diamond) needs a story.
3. **One `labelle-backends` monorepo vs per-backend repos** — independent release
   cadence + slim fetch (per-repo) vs less coordination (monorepo).
4. **Mobile/android + gamepad** (`android_gamepad`, `sdl_gamepad`, the
   `templates/mobile.txt` path) — extra contract surface beyond the desktop four.
5. **The build-graph generalization** — the core-diamond unification + the
   per-backend native-dep wiring, done generically rather than per-backend.
