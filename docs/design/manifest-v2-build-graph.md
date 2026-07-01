# Design: build-graph manifest v2 + constrained build hook

Status: **proposed** — pre-implementation review for issue #453 item 3, the
capstone of the backend-agnostic epic (#386). The shape is accepted in
`RFC-PLUGGABLE-BACKENDS.md` §"The manifest build-side schema" (lines 1388–1560);
this document pins the concrete field surface, the declarative-vs-hook split
(verified against the real fragments/sections), the migration ordering, and the
byte-equivalence test strategy so coding can start without re-litigating shape.

This is a **design document, not an implementation.** No code ships in this PR.

---

## 1. Problem — two codegen routes, neither scales to third-party backends

Today the assembler generates a project's `build.zig` through **two parallel
routes**, and the newer one is desktop-only.

### Route A — the enum path (all backends, all platforms)

`src/build_files.zig` selects named sections out of the single embedded template
`src/templates/build_zig.txt` with a `switch (cfg.backend)` and, inside several
arms, a nested `switch (cfg.platform)`:

- Backend-dep wiring: `src/build_files.zig:264` `switch (cfg.backend)` →
  `renderSection(build_zig_tmpl, "backend_raylib", …)` / `"backend_sokol"` /
  `"backend_sokol_wasm"` / `"backend_sokol_ios"` / `"backend_sokol_android"` /
  `"backend_sdl"` / `"backend_bgfx"` / `"backend_bgfx_android"` / `"backend_wgpu"` /
  `"backend_null"` (`src/build_files.zig:265`–`320`).
- Link wiring: `src/build_files.zig:598`–`602` `writeSection(…, "link_raylib")` …
  `"link_wgpu"`, plus the platform variants `"link_raylib_wasm"`/`"link_sokol_wasm"`
  (`:458`–`459`), `"ios_link"` (`:485`), `"android_link"`/`"android_link_bgfx"`
  (`:535`,`:537`).
- Per-platform scaffolding lives as its own sections: `.header_ios`/`.ios_deps`/
  `.backend_sokol_ios`/`.ios_link`/`.ios_footer`, `.header_android`/`.android_deps`/
  `.backend_sokol_android`/`.android_link`/`.android_package`/`.android_footer`,
  `.header_wasm`/`.wasm_target`/`.wasm_exe_start`/`.link_*_wasm`/`.wasm_footer`.

`src/deps_linker.zig` (`createDepsLinks`) is the staging half of this route: it
hardlinks resolved packages into `.labelle/deps/<name>/` and rewrites relative
`.path` deps so the generated `build.zig.zon` resolves.

The whole route is keyed on the **closed `Backend` enum**. A backend that is not
one of `raylib|sokol|sdl|bgfx|wgpu|null` has no arm, and (per the note at
`manifest_splice.zig:98`–`109`) would silently fall through to the `.raylib`
default — a raylib-shaped build for a non-raylib backend.

### Route B — the thin manifest splice (desktop only)

`src/codegen/manifest_splice.zig` is the productionized POC from
assembler#378 / epic#386 Phase 3. A backend opts in by shipping
`backends/<dir>/backend.manifest.zon` (v1 schema, `manifest_splice.zig:52`–`97`).
When the target is **desktop** AND the manifest exists
(`manifestPathEnabled`, `manifest_splice.zig:91`), `build_files.zig:254`–`262`
and `:588` splice in the backend's own **raw-Zig-text fragments** instead of the
embedded `backend_<tag>`/`link_<tag>` sections:

- `renderBackendDepSection` reads `build_fragments/backend_dep.txt` and renders
  it against a runtime string map of `{{placeholders}}` (`manifest_splice.zig:252`).
- `renderLinkSection` reads `build_fragments/link.txt`, verbatim when no params
  (`manifest_splice.zig:265`).

The fragments are **literal `build.zig` source** with `{{placeholder}}` holes —
see `backends/sokol/build_fragments/backend_dep.txt` and `link.txt`. The splice
computes placeholder values with the *same predicates* as the enum path
(`paramValue`, `manifest_splice.zig:272`).

### Why raw-text fragments don't scale

The v1 splice removed the *enum tag* from the codegen decision, but it did **not**
remove the assembler's dependence on hand-authored Zig. It has four structural
limits that block third-party backends:

1. **The fragment is opaque Zig source.** `link.txt` and `backend_dep.txt` are
   copied into the output almost verbatim. The assembler cannot reason about what
   they link, which modules they expose, or which platforms they cover — it can
   only string-substitute `{{placeholders}}`. There is no schema to validate, no
   capability to check, and a malformed fragment fails as a `zig build` compile
   error in the consumer, not as a readable assembler error.

2. **Placeholder names are hardcoded in the assembler.** `paramValue`
   (`manifest_splice.zig:272`–`289`) knows exactly `with_imgui`, `gui_enabled`,
   `gamepad_enabled`, `gamepad_hidapi`. A third-party backend cannot introduce a
   new option flag without patching the assembler — the escape hatch is closed to
   the very people it exists for.

3. **Desktop-only.** `manifestPathEnabled` returns false for any non-desktop
   target (`manifest_splice.zig:92`–`95`), so android/ios/wasm are permanently on
   the enum path. Yet those are exactly the platforms where the interesting,
   genuinely-non-declarative wiring lives (NDK sysroot, xcrun, emcc). The v1
   design punted on all of it.

4. **The core-diamond `overrideImport` calls are baked into the fragment text.**
   `sokol/build_fragments/backend_dep.txt:19`–`31` carries two hand-written
   `overrideImport(…, "labelle_core", core_mod)` calls with `if`-guards. Every
   backend re-authors these by hand, with subtly different key spellings
   (`labelle-core` vs `labelle_core`) and target modules (`input` vs the
   transitive `sdl_gamepad`). This is the single highest-regression-risk seam in
   the whole build (§5), and v1 leaves it as copy-paste Zig in every fragment.

The v2 manifest replaces raw-text fragments with **typed, declarative data** for
the ~95% that is pure build-graph structure (modules, artifacts, system libs,
frameworks, platform matrix, and the `b.dependency` option-flag *names* with values
drawn from a closed predicate set), and a **versioned, trusted build hook** for the
~5% that genuinely needs to run build-graph code (pre-dependency target/SDK
resolution + NDK/xcrun/emcc). The assembler then does the wiring generically for
every backend, built-in or third-party, on every platform.

---

## 2. Per-fragment declarative-vs-hook disposition

The RFC (line 1530) claims "the typed manifest covers ~95%; the build hook covers
~5%." This section **verifies that claim against the actual fragments and
template sections** and classifies each concrete piece of wiring. The genuinely-
code residual was predicted to be exactly (a) Android NDK sysroot + libc.txt,
(b) iOS xcrun SDK path, (c) Emscripten emcc shell-out, (d) `b.dependency` option
flags computed before the dependency is built. **The verification confirms this,
with one correction (see the note after the table).**

### Classification table

Legend: **D** = pure-declarative (expressible as `.modules`/`.artifacts`/
`.system_libs`/`.frameworks`/`.platforms`); **DECL-OPT** = a `b.dependency` option
whose *name* is declarative manifest data and whose *value* the assembler computes
from a closed predicate set (§4 — replaces the deleted `pre_wire`/`[]Flag`
mechanism); **RT** = the pre-dependency `resolve_target` phase (target-query + iOS
SDK resolution, before any `b.dependency`); **H-post** = `post_wire` (supplements
the graph after generic wiring); **CORE** = the generic core-diamond walk (§5),
not a per-backend concern.

| Source | Concrete wiring | Disposition |
|---|---|---|
| `sokol/build_fragments/backend_dep.txt:5` | `b.dependency("labelle_sokol", .{… .with_imgui, .gamepad_enabled, .gamepad_hidapi})` | **DECL-OPT** (option names from manifest, values from closed predicate set) + **D** (dep name from `.dep_name`) |
| `…backend_dep.txt:6`–`10` | `.module("gfx"/"input"/"audio"/"window")`, `.artifact("sokol_clib")` | **D** (`.modules`, `.artifacts`) |
| `…backend_dep.txt:19`–`21` | `overrideImport(sdl_gp_mod, "labelle_core", core_mod)` (if guard) | **CORE** |
| `…backend_dep.txt:29`–`31` | `overrideImport(backend_input, "labelle-core", core_mod)` (Linux, if guard) | **CORE** |
| `sokol/build_fragments/link.txt:1` | `exe.root_module.linkLibrary(sokol_clib)` | **D** (`.artifacts` → generic link) |
| `…link.txt:12`–`16` | `linkFramework("IOSurface"/"CoreFoundation")` on `.macos, .ios` | **D** (`.frameworks` per-OS) |
| `build_zig.txt:57` `.backend_raylib` | `b.dependency(… .gamepad_enabled, .gamepad_hidapi)` | **DECL-OPT** + **D** |
| `build_zig.txt:71`,`:85` | raylib `input`←core, `sdl_gamepad`←core (if guard) | **CORE** |
| `build_zig.txt:233`–`246` `.link_raylib` | `linkLibrary(raylib_artifact)` + per-OS `linkFramework("OpenGL")`/`linkSystemLibrary("GL"/"opengl32")` | **D** (`.artifacts` + `.system_libs`/`.frameworks` per-OS) |
| `build_zig.txt:141` `.backend_sdl` | `overrideImport(backend_input, "labelle_core", core_mod)` | **CORE** |
| `build_zig.txt:393` `.link_sdl` | *(empty)* | **D** (nothing) |
| `build_zig.txt:144` `.backend_bgfx` | `b.dependency(… .gamepad_enabled, .gamepad_hidapi, .gui_enabled)` | **DECL-OPT** + **D** |
| `build_zig.txt:149`–`150` | `.artifact("bgfx")`, `.artifact("glfw")` | **D** (`.artifacts`, desktop-scoped — Android exposes only `bgfx`, §3) |
| `build_zig.txt:396`–`397` `.link_bgfx` | `linkLibrary(bgfx_artifact)`, `linkLibrary(glfw_artifact)` | **D** |
| `build_zig.txt:167`–`172` `.backend_wgpu` | dep + modules + `.artifact("glfw")` | **D** |
| `build_zig.txt:400`–`414` `.link_wgpu` | `linkLibrary(glfw_artifact)` + per-OS `linkFramework("Foundation"/"QuartzCore"/"Metal")` | **D** (`.artifacts` + `.frameworks` per-OS) |
| `build_zig.txt:174`–`181` `.backend_null` | dep + modules, no artifact | **D** |
| `build_zig.txt:426`–`439` `.header_ios` `getIosSdkPath` | `xcrun --sdk … --show-sdk-path` shell-out | **RT** (c: iOS xcrun — must run BEFORE plugin `b.dependency`, §4) |
| `build_zig.txt:442`–`452` | `configureSdkPaths`/`addExeSdkPaths` (SDK include/lib/framework paths) | **H-post** (consumes the SDK path resolved in **RT**) |
| `build_zig.txt:455`–`470` `linkIosFrameworks` | `linkFramework("Foundation"/"UIKit"/"Metal"/"MetalKit"/"AudioToolbox"/"AVFoundation"/"QuartzCore"/"GameController")` | **D** (`.frameworks.ios`) |
| `build_zig.txt:474`–`498` | iOS target resolution — `-Ddevice` selects device (`aarch64-ios`) vs simulator, and the simulator arch depends on host (`x86_64-ios-simulator` on Intel, `aarch64-ios-simulator`+apple_a14 on Apple Silicon) | **RT** (dynamic; NOT a static `.triple`, §3) |
| `build_zig.txt:535`–`540` `.backend_sokol_ios` | `b.dependency(… .dont_link_system_libs = true, .with_imgui)` | **DECL-OPT** |
| `build_zig.txt:582` `.ios_link` | `exe.root_module.link_libc = true` | **D** (`.platforms.ios.link_libc`, §3) |
| `build_zig.txt:632`–`686` `.header_android` `getAndroidNdkSysroot`/`ndkHostTag` | env lookup + FS probe for NDK sysroot | **H-post** (a: NDK sysroot) |
| `build_zig.txt:690`–`726` | Android target resolution — `-Demulator`/`-Dandroid_arch`/host arch pick `aarch64`/`x86_64`; `ndk_arch_triple` derived from it | **RT** (dynamic; NOT a static `.triple`, §3) |
| `build_zig.txt:776`–`783` `.backend_sokol_android` | `addSystemIncludePath(ndk_sysroot/usr/include[/triple])`, `sokol_clib.root_module.pic = true` | **H-post** (a) + **D** (`.artifacts.<n>.pic`) |
| `build_zig.txt:850`–`855` `.android_link` | `link_libc = true` + `addLibraryPath(ndk_sysroot/…/<ndk_arch_triple>/<target_sdk_version>)` + `linkSystemLibrary("android"/"log"/"GLESv3"/"EGL")` | **H-post** (a: lib path, needs `ctx.android_target_sdk` §4) + **D** (`.platforms.android.link_libc` + `.system_libs.android`) |
| `build_zig.txt:859`–`868` | libc.txt generation (`std.mem.concat` + `addWriteFiles` + `setLibCFile`) | **H-post** (a: libc.txt, needs `ctx.android_target_sdk`) |
| `build_zig.txt:891`–`903` `.android_link_bgfx` | `linkSystemLibrary("android"/"log"/"EGL"/"GLESv3"/"m"/"dl"/"mediandk"/"aaudio")` | **D** (`.system_libs.android`) |
| `build_zig.txt:918`–`921` `.android_link_gui_bridge` | `gui_bridge_artifact.root_module.pic = true` + link | **H-post** (bridge is GUI-plugin-owned, not backend; see note) |
| `build_zig.txt:923`–`979` `.android_package` | apk-staging copy + `zip` + `apksigner` shell-outs | **D** (`.platforms.android.package.apk`) → shared packager |
| `build_zig.txt:248`–`253` `.wasm_emsdk_*` + `build.zig.zon` `dep_emsdk` (`build_files.zig:770`) | `b.dependency("emsdk", .{})` — the emcc hook's ROOT build.zig.zon dependency | **H-post** needs a declared root dep (§3 `.root_build_deps`, §4) |
| `build_zig.txt:286`–`309` `.link_raylib_wasm` | `emsdk.emccDefaultFlags/Settings` + `STACK_SIZE`/`ALLOW_MEMORY_GROWTH` + `emccStep` | **H-post** (c: emcc) |
| `build_zig.txt:311`–`332` `.link_sokol_wasm` | `emLinkStep(… shell_file_path, use_webgl2, -sSTACK_SIZE=512KB)` | **H-post** (c: emcc) |
| `build_zig.txt:334`–`337` `.wasm_footer` | `getInstallStep().dependOn(emcc_step)` + run step | **D** (`.platforms.wasm.package.web`) → shared packager |

### Verification result — the residual is exactly (a)–(d), with two clarifications

The prediction holds. Everything the manifest cannot express declaratively falls
into precisely:

- **(a) Android NDK sysroot detection + libc.txt gen** — `getAndroidNdkSysroot`
  (`build_zig.txt:632`), the `addSystemIncludePath`/`addLibraryPath` calls that
  consume `ndk_sysroot`, and the `libc.txt` `concat`+`setLibCFile` block. All
  **H-post**.
- **(b) iOS xcrun SDK path** — `getIosSdkPath` (`build_zig.txt:426`) and the
  `configureSdkPaths`/`addExeSdkPaths` that consume its result. **H-post**.
- **(c) Emscripten emcc shell-out** — `emccStep`/`emLinkStep`
  (`build_zig.txt:304`,`:313`). **H-post**.
- **(d) `b.dependency` option flags** — `with_imgui`, `gui_enabled`,
  `gamepad_enabled`, `gamepad_hidapi`, `dont_link_system_libs`. These change how
  the dependency artifact is *built* and must appear in the `b.dependency` options
  struct. **They are NOT a runtime hook return** (that was a rev-1 design error —
  see §4): a `b.dependency` options struct is an anonymous struct literal whose
  field *names* must exist in the generated `build.zig` source at compile time, so
  they cannot come from a runtime `[]Flag`. They are therefore **DECL-OPT**: the
  option *name* is declarative manifest data the assembler renders into source, and
  the option *value* comes from a closed predicate set the assembler computes (the
  exact `paramValue` predicates today, `manifest_splice.zig:272`–`289`).

There is also a **fifth residual the raw prediction missed** — the pre-dependency
**target + SDK resolution** (§4 `resolve_target`). iOS device/simulator and Android
ABI are resolved from `-Ddevice`/`-Demulator`/`-Dandroid_arch` + host arch
(`build_zig.txt:474`–`498`, `:690`–`726`), and the iOS SDK path is discovered via
`xcrun` and then passed into *plugin* `b.dependency` calls (`build_files.zig:212`,
`.ios_sdk_path = @as(?[]const u8, sdk_path)`) — all of it **before** any backend
dependency is resolved. This cannot be a static `.triple` and cannot live in
`post_wire`; it is its own phase (§4).

Two clarifications that the raw prediction glossed:

1. **`.pic` is declarative, not a hook.** `sokol_clib.root_module.pic = true`
   (`build_zig.txt:783`) and the `.android` root-module `.pic = true`
   (`build_zig.txt:824`) are static per-artifact/per-platform facts. They belong
   in the manifest (`.artifacts.<name>.pic`, and a `.platforms.android.pic` for
   the root module), NOT in a hook. This matches the RFC's `.pic` field
   (line 1424).

2. **Per-OS system-lib/framework gating is declarative.** The `switch
   (target.result.os.tag)` blocks in `.link_raylib` (OpenGL), `.link_sokol`
   (IOSurface/CoreFoundation), and `.link_wgpu` (Metal/Foundation/QuartzCore) look
   like code but are pure data: "on macos link X, on linux link Y." They move into
   `.system_libs`/`.frameworks` keyed **per-OS** (`.desktop.macos`, `.desktop.linux`,
   `.desktop.windows`), as the RFC's `.system_libs.desktop.macos` sketch shows
   (line 1430). No hook needed.

One item is out of the backend manifest's scope entirely: the **GUI bridge**
(`.link_gui_bridge`, `.android_link_gui_bridge`, `gui_bridge_artifact.pic`). That
is owned by the resolved *GUI plugin*, not the backend, and stays on its existing
manifest-driven path (`build_files.zig:341`–`367`). The backend manifest never
mentions it.

---

## 3. v2 manifest schema

The v2 `BackendManifest` supersedes the v1 struct in `manifest_splice.zig:52`–`97`.
It is a ZON file (`backend.manifest.zon`), parsed with `std.zon.parse.fromSliceAlloc`
exactly as `loadManifest` does today (`manifest_splice.zig:186`–`204`).

**Version parsing is a two-step, header-first process (fixes the critical
finding).** A v2 struct that makes `manifest_version` *mandatory* cannot be used to
route v1 manifests: the retained `backends/sokol/backend.manifest.zon` has **no
`manifest_version` field at all**, and `.ignore_unknown_fields = true` only skips
*extra* fields — it does not supply a *missing required* one, so a direct
`fromSliceAlloc(BackendManifestV2, …)` on a v1 manifest fails to parse *before* any
`>= 2` gate can run. The assembler therefore parses a tiny **version header first**,
then dispatches (§6):

```zig
/// Parsed FIRST, before the full schema. Defaulted so a v1 manifest (no field)
/// reads as version 1 instead of failing to parse. `ignore_unknown_fields`
/// makes this tolerate every other field the real manifest carries.
pub const ManifestHeader = struct { manifest_version: u8 = 1 };
```

Only when the header reports `2 <= v <= SUPPORTED_MANIFEST_VERSION` does the
assembler re-parse the bytes into the full `BackendManifestV2`. A v1 (or
field-less) manifest stays on the existing v1 splice + enum path; a version *above*
what this assembler supports is **rejected**, not silently accepted (§6).

### Concrete field surface

```zig
/// v2 build-graph manifest. Parsed from `backends/<dir>/backend.manifest.zon`
/// only after `ManifestHeader.manifest_version >= 2`. Every field is DATA the
/// assembler wires generically — no backend enum tag appears, and no field is
/// raw Zig source (that was the v1 fragment mistake).
pub const BackendManifestV2 = struct {
    /// Present + defaulted so the same struct round-trips through the header
    /// pre-pass. The full struct is only ever parsed when the header already
    /// proved this is >= 2.
    manifest_version: u8 = 1,

    /// Package identity — replaces v1 `dir_name`/`dep_name`. `id` is the
    /// canonical namespaced ID checked for collisions (RFC "Provider identity").
    dir_name: []const u8,
    dep_name: []const u8,
    id: []const u8, // e.g. "labelle.sokol"

    /// Named modules the provider exposes. Replaces the four hand-written
    /// `.module("gfx"/"input"/"audio"/"window")` lines in every fragment.
    /// Optional platform-scoped modules (bgfx-Android's `android_app`) are
    /// declared under `.platforms.<p>.extra_modules`.
    modules: []const ModuleDecl,

    /// b.dependency options common to every platform, name-declared here so the
    /// name is comptime-known in generated source; value from a closed predicate
    /// set (§4). Per-platform additions/overrides live in `PlatformEntry.dep_options`.
    dep_options: []const DepOption = &.{},

    /// Per-platform, per-OS system libraries → `linkSystemLibrary`.
    system_libs: SystemLibs = .{},

    /// Per-platform Apple frameworks → `linkFramework` (Zig distinguishes
    /// these from system libs).
    frameworks: Frameworks = .{},

    /// The (backend × platform) matrix. Absent platform = unsupported.
    platforms: Platforms,

    /// OPTIONAL. Relative path to the provider's build hook (§4). Absent =
    /// fully declarative backend, no hook compiled/called.
    build_hook: ?[]const u8 = null,

    pub const ModuleDecl = struct {
        name: []const u8, // provider module name, e.g. "gfx"
        /// Root import alias — the KEY the generated root imports this module
        /// under. The current templates import provider modules as
        /// `backend_gfx`/`backend_input`/`backend_audio`/`backend_window`
        /// (build_zig.txt:213-216, 561-564) and lifecycle code does
        /// `@import("backend_gfx")`; the assembler MUST preserve these aliases
        /// or v2 stops compiling at every `@import("backend_*")`. Defaults to
        /// `backend_<name>` so the common case needs no restatement.
        root_alias: ?[]const u8 = null,
        source: []const u8, // informational for b.dependency-sourced modules
    };

    pub const ArtifactDecl = struct {
        name: []const u8, // b.dependency(...).artifact(name)
        pic: bool = false, // force -fPIC (Android .so requirement, #147)
    };

    /// A b.dependency option. `name` is declarative (rendered into source, so
    /// comptime-known when build.zig compiles); `value` names ONE of a closed,
    /// assembler-known predicate set — never arbitrary runtime data (§4).
    pub const DepOption = struct {
        name: []const u8, // e.g. "with_imgui", "gamepad_hidapi", "dont_link_system_libs"
        value: ValueSource,
        pub const ValueSource = enum {
            gui_is_imgui,   // cfg.resolved_gui.name == "imgui" (with_imgui/gui_enabled)
            gamepad_enabled, // cfg.gamepad == .auto
            gamepad_hidapi,  // cfg.gamepad_hidapi
            true_literal,    // e.g. dont_link_system_libs = true on mobile
            false_literal,
        };
    };

    /// Per-OS lists so the `switch (target.result.os.tag)` blocks in
    /// .link_raylib/.link_sokol/.link_wgpu become data.
    pub const OsLibs = struct {
        macos: []const []const u8 = &.{},
        linux: []const []const u8 = &.{},
        windows: []const []const u8 = &.{},
    };
    pub const SystemLibs = struct {
        desktop: OsLibs = .{},
        android: []const []const u8 = &.{},
        ios: []const []const u8 = &.{},
        wasm: []const []const u8 = &.{}, // usually empty — emcc handles these
    };
    pub const Frameworks = struct {
        desktop: OsLibs = .{}, // OpenGL(macos)/Metal etc.
        ios: []const []const u8 = &.{},
    };

    pub const PlatformEntry = struct {
        /// Entry-point / main-loop template, replacing v1 `main_loop_template`
        /// (manifest_splice.zig) and root.zig's loadBackendTemplate mapping.
        entry: []const u8, // "templates/desktop.txt"

        /// Run-loop style — MUST be per-platform, not top-level: bgfx-desktop is
        /// `.loop` while bgfx-Android is `.callback` (NativeActivity), so a single
        /// top-level value would mis-generate main.zig for one of them
        /// (manifest_splice.zig:76-81 enumerates both). `.callback` = windowing
        /// runtime owns the loop; `.loop` = generated main drives `while (!quit)`.
        loop_style: enum { callback, loop },

        /// How the cross-compile target is chosen. `.native` for desktop; a fixed
        /// `.triple` for wasm (always wasm32-emscripten, build_zig.txt:194); and
        /// `.resolved` for iOS/Android, whose target is computed dynamically by the
        /// `resolve_target` phase (§4) from `-Ddevice`/`-Demulator`/`-Dandroid_arch`
        /// + host arch (build_zig.txt:474-498, :690-726). It is NOT a static triple.
        target: Target,

        /// Root-module PIC (Android .so). Static per-platform fact (§2 note 1).
        pic: bool = false,

        /// `root_module.link_libc = true`. Captured per-platform because mobile
        /// specs set it (ios_link:582, android_link:850, android_link_bgfx:881)
        /// and desktop does not; system_libs/frameworks alone cannot express it.
        link_libc: bool = false,

        /// Artifacts scoped to THIS platform — presence differs by platform:
        /// bgfx-desktop links both `bgfx` and `glfw` (build_zig.txt:149-150),
        /// bgfx-Android exposes only `bgfx` (no glfw artifact). A single top-level
        /// list would over/under-link, so artifacts (and their `.pic`) live here.
        artifacts: []const ArtifactDecl = &.{},

        /// Per-platform b.dependency option additions/overrides (iOS adds
        /// `dont_link_system_libs`; wasm passes only `with_imgui`). Merged over
        /// the top-level `dep_options` by name.
        dep_options: []const DepOption = &.{},

        /// Extra platform-only modules (bgfx-Android `android_app`).
        extra_modules: []const ModuleDecl = &.{},

        /// Root `build.zig.zon` build-time dependencies the hook needs to resolve
        /// via `b.dependency` at consumer build time — e.g. sokol/raylib wasm
        /// hooks call `b.dependency("emsdk", .{})` (build_zig.txt:253), which only
        /// works if the generated root build.zig.zon declares emsdk
        /// (build_files.zig:770 `dep_emsdk`). The v2 manifest otherwise describes
        /// only build.zig wiring, so the hook would generate fine then fail at
        /// `zig build`. The assembler emits a `build.zig.zon` entry per name.
        root_build_deps: []const RootBuildDep = &.{},

        /// Packaging recipe handed to the shared platform-packager.
        package: Package, // .binary | .{ .apk = … } | .{ .web = … }
    };
    pub const Platforms = struct {
        desktop: ?PlatformEntry = null,
        android: ?PlatformEntry = null,
        ios: ?PlatformEntry = null,
        wasm: ?PlatformEntry = null,
    };

    pub const RootBuildDep = struct {
        name: []const u8, // build.zig.zon key, e.g. "emsdk"
        // resolution (url+hash / path) is handled by the existing deps machinery;
        // this only declares that the hook REQUIRES the dep to exist at the root.
    };

    pub const Target = union(enum) {
        native,               // desktop: b.standardTargetOptions
        triple: []const u8,   // fixed cross target (wasm32-emscripten)
        resolved,             // computed by the resolve_target phase (§4): iOS/Android
    };
    pub const Package = union(enum) {
        binary,
        apk: struct { manifest: []const u8 },
        web: struct { shell: ?[]const u8 = null },
    };
};
```

### Worked example — sokol's current fragments rewritten as a v2 manifest

This is a faithful translation of `backends/sokol/backend.manifest.zon` (v1) +
`build_fragments/{backend_dep,link}.txt` + the sokol arms of `build_zig.txt`
(`.backend_sokol`, `.link_sokol`, `.backend_sokol_ios`, `.ios_link`,
`.backend_sokol_android`, `.android_link`, `.backend_sokol_wasm`,
`.link_sokol_wasm`). Everything that was raw Zig or a nested `switch` becomes
data; the `b.dependency` option flags become declarative `dep_options`; and only
the genuine code residual (target/SDK resolution + NDK/xcrun-consume/emcc) goes to
the hook (§4).

```zig
.{
    .manifest_version = 2,
    .dir_name = "sokol",
    .dep_name = "labelle_sokol",
    .id = "labelle.sokol",

    .modules = .{
        // root_alias defaults to `backend_<name>`, so the generated root imports
        // these as `backend_gfx`/`backend_input`/… exactly as today.
        .{ .name = "gfx",    .source = "src/gfx.zig" },
        .{ .name = "input",  .source = "src/input.zig" },
        .{ .name = "audio",  .source = "src/audio.zig" },
        .{ .name = "window", .source = "src/window.zig" },
    },

    // Common option NAMES are declarative (comptime-known in the generated
    // b.dependency literal); VALUES come from the closed predicate set (§4).
    .dep_options = .{
        .{ .name = "with_imgui",      .value = .gui_is_imgui },
        .{ .name = "gamepad_enabled", .value = .gamepad_enabled },
        .{ .name = "gamepad_hidapi",  .value = .gamepad_hidapi },
    },

    .system_libs = .{
        .android = .{ "android", "log", "GLESv3", "EGL" }, // .android_link:850-855
        // desktop/ios system libs: none — sokol links via frameworks.
    },
    .frameworks = .{
        // IOSurface/CoreFoundation on Darwin — replaces link.txt:12-16 switch.
        .desktop = .{ .macos = .{ "IOSurface", "CoreFoundation" } },
        .ios = .{ "Foundation", "UIKit", "Metal", "MetalKit", "AudioToolbox",
                  "AVFoundation", "QuartzCore", "GameController" }, // linkIosFrameworks
    },
    .platforms = .{
        .desktop = .{
            .entry = "templates/desktop.txt",
            .loop_style = .callback,
            .target = .native,
            .artifacts = .{ .{ .name = "sokol_clib" } },
            .package = .binary,
        },
        .ios = .{
            .entry = "templates/mobile.txt",
            .loop_style = .callback,
            .target = .resolved, // device vs simulator + host arch — resolve_target (§4)
            .link_libc = true,   // ios_link:582
            .artifacts = .{ .{ .name = "sokol_clib" } },
            // iOS links system libs manually → dont_link_system_libs (build_zig.txt:538)
            .dep_options = .{ .{ .name = "dont_link_system_libs", .value = .true_literal } },
            .package = .binary,
        },
        .android = .{
            .entry = "templates/mobile.txt",
            .loop_style = .callback,
            .target = .resolved, // arm64/x86_64 by -Demulator/-Dandroid_arch/host — §4
            .pic = true,         // android_exe_start root module pic (build_zig.txt:824)
            .link_libc = true,   // android_link:850
            .artifacts = .{ .{ .name = "sokol_clib", .pic = true } }, // build_zig.txt:783
            .package = .{ .apk = .{ .manifest = "AndroidManifest.xml.tmpl" } },
        },
        .wasm = .{
            .entry = "templates/wasm.txt",
            .loop_style = .callback,
            .target = .{ .triple = "wasm32-emscripten" }, // static (build_zig.txt:194)
            .artifacts = .{ .{ .name = "sokol_clib" } },
            .dep_options = .{}, // wasm passes only with_imgui — see note below
            .root_build_deps = .{ .{ .name = "emsdk" } }, // hook calls b.dependency("emsdk")
            .package = .{ .web = .{ .shell = null } },
        },
    },
    // sokol needs a hook for: resolve_target (iOS device/sim + SDK, Android ABI),
    // and post_wire residual (a) NDK sysroot+libc.txt, (b) iOS SDK path plumbing,
    // (c) emcc emLinkStep. The b.dependency option flags are NO LONGER a hook
    // concern — they are declarative `dep_options` above. See §4.
    .build_hook = "build.zig",
}
```

(wasm's `dep_options = .{}` means the assembler still passes the top-level
`with_imgui` but not the desktop `gamepad_*` — the per-platform list *replaces* the
gamepad entries rather than adding to them, matching `build_zig.txt:124`.)

What the assembler now does generically for this manifest: run the hook's
`resolve_target` phase to pin the `ResolvedTarget` (and, for iOS, the SDK path
passed into plugin `b.dependency` calls — before anything else), resolve
`labelle_sokol` with the declarative `dep_options` rendered into its options
literal, pull `.modules` under their `root_alias`, run the generic core-diamond
walk (§5), `linkLibrary` each active-platform `.artifacts` entry applying `.pic`,
`linkSystemLibrary`/`linkFramework` from `.system_libs`/`.frameworks` for the
active platform+OS, set `link_libc`, splice the `.platforms[p].entry` template,
call the hook's `post_wire` for the residual (NDK/xcrun-consume/emcc), and delegate
packaging to the shared packager per `.platforms[p].package`.

---

## 4. Dependency options (declarative) + the two hook phases

The escape hatch for the residual (§2) is a `build.zig` the provider ships,
imported by the assembler and invoked at build time. **Rev-1 of this design put
`b.dependency` option flags in a runtime `pre_wire` hook returning `[]Flag`. That
does not compile** and is the load-bearing correction below.

### Why `b.dependency` options are declarative, not a runtime hook return

`b.dependency(name, options)` takes an **anonymous struct literal** whose field
*names* must exist in the generated `build.zig` source when that `build.zig` is
compiled — `.{ .target = target, .optimize = optimize, .with_imgui = … }`. A hook
returning a runtime `[]Flag` (`[]struct{ name, value }`) cannot be splatted into
that literal: Zig has no way to turn runtime strings into struct field names. Any
third-party flag not already hard-coded would either fail to compile or force the
assembler back to raw string-generation of the `b.dependency` call — the exact v1
fragment problem this design exists to remove.

The v1 splice already gets this right: option names are `{{placeholders}}` in the
fragment *text* (`backend_dep.txt:5`), and `paramValue`
(`manifest_splice.zig:272`–`289`) computes only the *values*. v2 preserves that
split as **typed data**:

- **Option NAME → declarative manifest data** (`DepOption.name`, §3). The assembler
  renders it into the generated `b.dependency` literal, so it is comptime-known
  when `build.zig` compiles. A third-party backend introduces a new flag by naming
  it in the manifest — no assembler patch, no runtime struct-field synthesis.
- **Option VALUE → a closed, assembler-known predicate** (`DepOption.ValueSource`,
  §3). The assembler computes the boolean with the exact `paramValue` predicates
  today (`gui_is_imgui`, `gamepad_enabled`, `gamepad_hidapi`, or the `true/false`
  literals mobile needs), then emits the literal `true`/`false` into source.

So the sokol `.dep_options` in §3 generate, verbatim and byte-for-byte with the
enum path:

```zig
const backend_dep = b.dependency("labelle_sokol", .{
    .target = target, .optimize = optimize,
    .with_imgui = true, .gamepad_enabled = true, .gamepad_hidapi = false,
});
```

The closed `ValueSource` set is the only thing the assembler must know how to
compute. Extending it (a genuinely new predicate) is a manifest-schema + assembler
change — deliberately, because the *value* logic is trusted assembler code, while
the *name* is free. There is **no `pre_wire` hook and no `DependencyOptions`
type**; the rev-1 versions are deleted.

### The `resolve_target` phase (before any `b.dependency`)

iOS/Android target selection and the iOS SDK path are **not** static and **not**
`post_wire` — they must run *before* dependency resolution, because every
`b.dependency` call (backend AND plugins) takes the resolved target, and the iOS
SDK path is passed into *plugin* `b.dependency` calls (`build_files.zig:212`,
`.ios_sdk_path = @as(?[]const u8, sdk_path)`). This is a distinct first phase, run
only for `.target == .resolved` platforms:

```zig
/// Runs FIRST, before ANY b.dependency (backend or plugin). Produces the
/// ResolvedTarget for platforms whose target is `.resolved` (iOS/Android) and,
/// for iOS, the SDK path that plugin dependency calls consume. Pure resolution +
/// tool probes (xcrun) — constructs no graph nodes and resolves no dependencies.
pub fn resolve_target(b: *std.Build, ctx: ResolveContext) ResolvedTargetInfo {
    return switch (ctx.platform) {
        .ios => blk: {
            const device = b.option(bool, "device", "iOS device vs simulator") orelse false;
            const sdk_name = if (device) "iphoneos" else "iphonesimulator";
            const sdk_path = getIosSdkPath(b, sdk_name) orelse @panic("no iOS SDK");
            // device→aarch64-ios; simulator→host-dependent (build_zig.txt:474-498)
            break :blk .{ .target = resolveIosTarget(b, device), .ios_sdk_path = sdk_path };
        },
        .android => .{ // -Demulator/-Dandroid_arch/host → arm64|x86_64 (build_zig.txt:690-726)
            .target = resolveAndroidTarget(b),
        },
        else => unreachable, // desktop=.native, wasm=.triple resolve without a hook
    };
}
```

The assembler consumes `ResolvedTargetInfo.target` for every subsequent
`b.dependency` and threads `ios_sdk_path` into the plugin dependency calls, exactly
as the current generator does — the residual iOS SDK *consumption*
(`configureSdkPaths`/`addExeSdkPaths`) still happens later in `post_wire`, but the
*path itself is resolved here*, before plugins. Desktop (`.native`) and wasm
(fixed `.triple`) resolve their target without calling this hook.

### The `post_wire` phase (after generic wiring)

```zig
/// Versioned with `manifest_version`; the assembler asserts compatibility before
/// calling (same discipline as plugin_manifest.zig's SUPPORTED_MANIFEST_VERSION
/// gate, :13/:203-213). Bumps only on a breaking ctx/ABI change.
pub const HOOK_ABI_VERSION: u8 = 2;

/// post_wire context. Every field is valid because post_wire runs strictly AFTER
/// b.dependency and after the root exe/lib is created — there is no pre-wire phase
/// left to hand undefined post-only pointers into (rev-1's pre/post-field-mixing
/// hazard is gone by construction).
pub const HookContext = struct {
    manifest_version: u8, // asserted == HOOK_ABI_VERSION
    backend_dep: *std.Build.Dependency,      // resolved (non-optional here)
    root_module: *std.Build.Module,
    root_artifact: *std.Build.Step.Compile,  // linkLibrary/setLibCFile/addLibraryPath
    target: std.Build.ResolvedTarget,        // from resolve_target for iOS/Android
    optimize: std.builtin.OptimizeMode,
    platform: Platform,

    /// iOS SDK path resolved in resolve_target, so post_wire's
    /// configureSdkPaths/addExeSdkPaths consume it without re-shelling xcrun.
    ios_sdk_path: ?[]const u8,

    /// Android target SDK version — the current libc.txt / addLibraryPath paths
    /// embed `usr/lib/<triple>/<target_sdk_version>` (build_zig.txt:851,:862,
    /// sourced from cfg.android.target_sdk_version, config.zig:214, default 34).
    /// Without it the hook cannot build the correct API-level lib path and v2
    /// would drift from the enum path for any non-default target SDK.
    android_target_sdk: ?u32,
};

/// Runs AFTER generic module/artifact/system-lib/framework wiring. Supplements the
/// graph with the residual the manifest can't express statically (§2 a/b/c).
pub fn post_wire(b: *std.Build, ctx: HookContext) void {
    switch (ctx.platform) {
        .android => {
            const sysroot = getAndroidNdkSysroot(b) orelse @panic("NDK not found");
            const api = ctx.android_target_sdk orelse 34;
            // addSystemIncludePath / addLibraryPath(.../<triple>/<api>) /
            // setLibCFile(libc.txt built with <api>) …
        },
        .ios => configureAndAddSdkPaths(b, ctx.root_artifact, ctx.ios_sdk_path.?),
        .wasm => { /* emccStep / emLinkStep on ctx.root_artifact — needs the emsdk
                      root dep declared via .platforms.wasm.root_build_deps (§3) */ },
        .desktop => {}, // fully declarative — no residual
    }
}
```

### Hook isolation is NOT mechanically enforceable — treat the hook as trusted

Rev-1 claimed the hook is "constrained by contract + review" so it "can never
degrade into an arbitrary backend build script." **That guarantee is false for
third-party backends** and must not be stated as one: the hook is a real
`build.zig` handed the real `*std.Build`, so it can do arbitrary filesystem,
process, and network work regardless of any documented contract, and there is no
review boundary for a third-party package. Zig build scripts are not sandboxable.

The honest model: **the build hook is trusted build code, exactly like every other
`build.zig` in the resolved dependency graph** (a consumer already runs the
backend package's own `build.zig`, the engine's, gfx's, every plugin's). Resolving
a backend package *is* trusting its build code; the hook adds no new trust
boundary. The design therefore:

1. **Drops the "constrained so it cannot do X" claim.** The value of the two-phase
   split is *ergonomic and correctness* (right data at the right time), not
   security.
2. **Keeps the surface narrow by giving the hook only `HookContext`, not `cfg`** —
   so the *common* case needs nothing more and the manifest stays the extension
   point. A backend reaching past `ctx` is a smell that the manifest should grow a
   field, but that is guidance, not a sandbox.
3. **Versions the ABI** (`HOOK_ABI_VERSION`) so a mismatched hook fails with a
   readable early error rather than a segfault.
4. (Future, out of scope) If real isolation is ever required, it needs a
   mechanical facade — a limited wrapper type exposing only whitelisted `std.Build`
   methods — not a documented contract. Noted so the security posture is not
   silently assumed.

### Why the phase split is mandatory

Three distinct times, three concerns: (1) `resolve_target` must run *before* any
`b.dependency` because the target and iOS SDK path feed every dependency call
including plugins; (2) `b.dependency` options must be known *at* the dependency
call and are declarative source, not a hook return; (3) NDK/xcrun-consume/emcc
supplement the graph *after* wiring. sokol's `with_imgui` (`build_zig.txt:94`,
caching hazard at `backend_dep.txt:1`–`4`, assembler#140) is the textbook option
flag — now declarative — while the NDK/emcc residual is genuinely post-wire code.

---

## 5. The generic core-diamond graph walk (highest regression risk)

Today the "unify every `labelle-core` onto the app's single `core_mod`" invariant
is enforced by **hand-written `overrideImport` calls scattered across the
template**, with per-backend key spellings and `if`-guards. The concrete sites in
`src/templates/build_zig.txt` (excluding the `overrideImport`/`unifyGfxSubpackageCore`
helper bodies which are duplicated per footer):

| Line | Site | Notes |
|---|---|---|
| `:28`–`30` | `.deps`: `gfx_mod`←core, `engine_mod`←core, `engine_mod`←gfx | the fixed engine/gfx diamond; repeated verbatim in `.ios_deps` (`:513`–`515`) and `.android_deps` (`:741`–`743`) |
| `:41`,`:519`,`:747` | `unifyGfxSubpackageCore(gfx_mod, core_mod)` | walks the **hardcoded** list `{camera, spatial_grid, tilemap}` (`:356`) |
| `:71` | `.backend_raylib`: `backend_input`←`labelle-core` | direct import, hyphen key |
| `:85`–`87` | `.backend_raylib`: `sdl_gp_mod`←`labelle_core` (if guard) | transitive sub-package, underscore key |
| `:108`–`110` | `.backend_sokol`: `sdl_gp_mod`←`labelle_core` (if guard) | transitive |
| `:118`–`120` | `.backend_sokol`: `backend_input`←`labelle-core` (if guard) | Linux udev route, hyphen key |
| `:141` | `.backend_sdl`: `backend_input`←`labelle_core` | **underscore** key (SDL spells it differently, #258) |
| `:162`–`164` | `.backend_bgfx`: `sdl_gp_mod`←`labelle_core` (if guard) | transitive |
| `:812`–`814` | `.backend_bgfx_android`: `backend_input`←`labelle-core` (if guard) | Android context vtable, #310 |

That is **~8 backend-side override sites** on top of the 3-line engine/gfx diamond
(×3 platforms) and the hardcoded 3-element gfx sub-package list — each authored by
hand, each with a subtly different key spelling and target module, each a landmine
if a backend restructures its import table.

### The collapse

All of these are instances of **one rule with two singleton targets**: *for every
module the app imports from a resolved provider, walk its `import_table`; wherever a
key resolves to a `labelle-core`/`labelle_core` provider, override it onto the app's
single `core_mod`; wherever a key resolves to a `labelle-gfx` provider, override it
onto the app's single `gfx_mod`; recurse into sub-packages otherwise.* This
generalizes both `overrideImport` (`build_zig.txt:341`) + `unifyGfxSubpackageCore`
(`:355`).

**The gfx override must not be dropped.** The fixed diamond today is *three*
overrides, not one: `gfx_mod←core`, `engine_mod←core`, **and**
`engine_mod←gfx` (`build_zig.txt:29`–`30`, repeated at `:513`–`515`, `:741`–`743`).
A walk that rewrites only the two core spellings would recurse *into* engine's own
`labelle-gfx` sub-module and unify *its* core, but never replace engine's
`labelle-gfx` import with the app's `gfx_mod` — leaving **two `labelle-gfx`
instances** across the app/engine seam (the renderer's `gfx.Texture` ≠ engine's).
So the walk carries both singletons and rewrites both keys:

```zig
/// Generic core+gfx-diamond unification. Replaces every hand-written site above
/// AND the fixed `engine_mod←gfx` override. Walks the provider module graph;
/// overrides any core import onto core_mod and any gfx import onto gfx_mod;
/// recurses otherwise. Idempotent, bounded by a visited set.
fn unifyCoreDiamond(
    root: *std.Build.Module,
    core_mod: *std.Build.Module,
    gfx_mod: *std.Build.Module,
    visited: *ModuleSet,
) void {
    if (visited.contains(root)) return;
    visited.put(root, {});
    var it = root.import_table.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "labelle-core") or std.mem.eql(u8, key, "labelle_core")) {
            overrideImport(root, key, core_mod); // preserve the existing key spelling
        } else if (std.mem.eql(u8, key, "labelle-gfx") or std.mem.eql(u8, key, "labelle_gfx")) {
            overrideImport(root, key, gfx_mod);  // the engine→gfx edge the fixed diamond had
        } else {
            unifyCoreDiamond(entry.value_ptr.*, core_mod, gfx_mod, visited); // recurse
        }
    }
}
```

The assembler runs this once over each imported provider module (`gfx`, `engine`,
and every `.modules` entry — `input`/`audio`/`window`/`android_app`). The
`if`-guards vanish (an absent import is simply not visited), both key spellings are
handled for both singletons, the `engine→gfx` edge is preserved rather than
recursed-through, and the `{camera, spatial_grid, tilemap}` list becomes "every
transitive sub-import that names core" — resilient if gfx restructures. (Note: a
key matched as `labelle-gfx` is overridden, not recursed into; `unifyGfxSubpackageCore`'s
job — unifying core *inside* the app's own `gfx_mod` sub-packages — is a separate
call rooted at `gfx_mod` itself, which the walk still performs.)

### Why this is the highest regression risk

- **The bug it prevents is invisible to `zig build test`.** Module-unification
  failures (two distinct `GamepadEvent`/`YAxis` types across the engine↔backend
  seam) only surface as `@compileError`/type-mismatch during a **cross-compile
  link** in CI, not in the assembler's own unit tests. Every one of the sites
  above was added in response to a *shipped* mismatch (#258, #271, #310, gfx#276) —
  regressing the generic walk silently reintroduces those.
- **`overrideImport` mutates `import_table` in place** (`build_zig.txt:342`) and
  is order-sensitive relative to `b.dependency`. The walk must run after all
  provider modules are pulled but before the root module is finalized.
- **Over-application is also a bug.** The `if`-guards exist because overriding a
  module that does *not* import core injects a dead import (#258). The visited-set
  walk must override only keys that are actually present — which it does by
  construction (it only touches existing `import_table` entries), preserving the
  guard semantics without the hand-written `if`s.

Mitigation: land the generic walk behind the differential/golden gate (§7) — the
sokol-desktop byte anchor proves it reproduces the established per-site output, and
per-cell golden snapshots catch drift before it reaches a cross-compile.

---

## 6. Migration ordering (flag-day mitigation)

No flag day. Both existing routes stay alive; v2 is gated and rolled out one
backend × one platform at a time.

1. **Land the v2 types + generic wiring behind a gate, dark.** Add
   `BackendManifestV2`, `ManifestHeader`, and the generic walk/link/hook machinery.
   Gate on a **header-first, bounded version check** — the critical correction:
   `.ignore_unknown_fields = true` skips *extra* fields, but it does **not** supply
   a *missing required* one, so parsing a field-less v1 manifest directly as
   `BackendManifestV2` would fail before any `>= 2` gate could run. Instead:
   - Parse the tiny `ManifestHeader { manifest_version: u8 = 1 }` first (defaulted,
     `ignore_unknown_fields`), so a v1/field-less manifest reads as `1`.
   - Dispatch on a **bounded range**, mirroring `plugin_manifest.zig:208` (`< 1 or
     > SUPPORTED`): `v <= 1` → v1 splice + enum path; `2 <= v <=
     SUPPORTED_MANIFEST_VERSION` → re-parse into the full `BackendManifestV2`; `v >
     SUPPORTED` → **reject** with a readable error (an older assembler must NOT
     silently accept a future v3 manifest and skip its unknown fields — that would
     generate an incomplete build graph for a hookless future manifest).
   - A backend with no manifest keeps the enum path. **Zero behavior change** here.

2. **Convert the sokol in-tree fixture to v2, desktop only.** `backends/sokol` is
   the retained offline fixture the codegen tests resolve against
   (`manifest_splice.zig:415`–`430`). Bump its manifest to v2 with the desktop
   platform entry (declarative `dep_options` for with_imgui/gamepad) + a `build.zig`
   hook with an empty desktop `post_wire` (desktop has no residual and `.native`
   needs no `resolve_target`). The differential test (§7) gates this: v2 output for
   sokol-desktop must match the enum baseline.

3. **Add platforms to sokol one at a time**, each gated by its own differential
   test: **desktop → android → ios → wasm.** Android brings residual (a) into the
   hook; iOS brings `resolve_target` (device/simulator + SDK) and (b); wasm brings
   (c) plus the `emsdk` root-build-dep. Each platform is a separate PR with its own
   fixture, so an NDK/xcrun/emcc regression is isolated to one PR. **The shared
   packager (PR 7 below) lands before Android/wasm** so their `.package`
   delegation produces complete output (§8).

4. **Convert the remaining backends one at a time**, in ascending residual order:
   `null` (pure declarative, no hook, no artifact) → `wgpu` (declarative + glfw
   artifact + Metal frameworks) → `raylib` (adds emsdk wasm hook) → `sdl` → `bgfx`
   (most artifacts, per-platform `loop_style` — desktop `.loop`, Android
   `.callback` — + Android `android_app` extra module + bgfx-Android NDK). Each
   backend × platform is differential-gated.

5. **Delete the enum-path sections and the v1 splice only after all 6 backends are
   v2 on all their supported platforms.** At that point the `switch (cfg.backend)`
   in `build_files.zig` (`:264`, `:598`, `:414`, `:457`), the `backend_*`/`link_*`/
   `.header_ios`/`.header_android`/`.link_*_wasm` sections in `build_zig.txt`, and
   `manifest_splice.zig`'s v1 struct/renderers are dead code. Delete in one final
   PR whose only diff is deletions + the fixtures proving the enum path is
   unreachable.

This ordering means the enum path is the safety net the entire time: any v2 arm
can be reverted to its enum arm by dropping the `manifest_version` bump, with no
other change.

---

## 7. Differential + golden-snapshot test strategy

The invariant that guards the migration is **build-graph equivalence**, but — the
correction — it **cannot be expressed as byte-identity against the enum path** for
most cells. Replacing the hand-written per-site `overrideImport` calls with a
generic `unifyCoreDiamond` *loop* (§5) and manifest-driven link loops legitimately
**changes the generated `build.zig` text even when the graph is identical**: a
`for`-loop over `.artifacts` emits different source than three unrolled
`linkLibrary` lines. An enum-vs-v2 `expectEqualStrings` would fail on the very
first conversion purely because the source was refactored, not because anything is
wrong. So the strategy is two-tier:

### Tier 1 — one anchored byte-diff, then golden snapshots

- **The single desktop anchor (PR 3).** sokol-desktop is the one cell where the v1
  splice already ships **byte-identical to the enum path** ("verified vs a
  generated baseline", `backends/sokol/backend.manifest.zon` header). For this
  first conversion the v2 path can be emitted so it reproduces that exact text
  (unrolling the walk's output for the desktop case), giving one hard enum-vs-v2
  0-diff proof that the generic machinery reproduces the established baseline. This
  is the anchor that proves the walk is correct on a known-good cell.
- **Every other cell is a golden snapshot.** From PR 4 onward the gate is a
  committed golden `build.zig` per (backend, platform, representative cfg): the
  test generates v2 output and asserts it equals the checked-in golden with
  `expectEqualStrings`. The golden for each new cell is produced once, **reviewed
  by hand against the enum-path output** (diffing for graph equivalence, ignoring
  loop-vs-unrolled formatting), and committed in the same PR. Drift from the golden
  then fails as a readable line-level delta — the same regression-catching property,
  without pinning v2 to enum *formatting*.

### Fixture matrix

The representative `ProjectConfig`s per cell are the exact inputs the declarative
`dep_options` value predicates branch on (`paramValue`,
`manifest_splice.zig:272`–`289`): gui=imgui vs none; gamepad auto vs off; hidapi
on/off; plus, for mobile, `-Ddevice`/`-Demulator` and a non-default
`target_sdk_version` so the `resolve_target`/`android_target_sdk` paths are
exercised.

### Scope + limits

- The test compares **generated text**, not build behavior — it is fast (no
  `zig build`) and runs in the ordinary `zig build test` suite.
- It does **not** replace CI cross-compile smoke builds — those still catch
  toolchain/SDK issues the text diff can't (a wrong NDK path that is *spelled*
  identically but points nowhere). A **normalized-graph** comparison (parse both
  outputs, compare the module/artifact/link edges modulo formatting) is the ideal
  future gate; the golden snapshot is the pragmatic stand-in until that exists.
- After §6 step 5 deletes the enum arms, the desktop anchor's enum baseline is gone;
  it too becomes a golden snapshot, so all cells are uniformly golden-pinned.

---

## 8. Effort + PR breakdown

A suggested sequence. Each PR is independently reviewable and (from PR 3 onward)
differential/golden gated. **The shared packager (PR 7 in the rev-1 order) is
pulled forward to before the Android/wasm conversions** — those platforms delegate
`.platforms[p].package` to it (§3), so converting them first would either produce
incomplete output or force them to keep the enum `.android_package`/`.wasm_footer`
sections, defeating the conversion.

| PR | Scope | Risk | Est. |
|---|---|---|---|
| **1** | v2 types: `ManifestHeader`, `BackendManifestV2`, `HookContext`, `HOOK_ABI_VERSION`, `DepOption` (NO `DependencyOptions`/`pre_wire` — options are declarative, §4); header-first bounded version parse (reuse `plugin_manifest.zig` discipline). No wiring. Unit tests for parse + v1-passthrough + `> SUPPORTED` rejection. | Low | S |
| **2** | Generic core+gfx-diamond walk (`unifyCoreDiamond` carrying both `core_mod`+`gfx_mod` singletons + visited set) as a standalone helper + unit tests over synthetic module graphs (both key spellings, the engine→gfx edge, recursion, idempotence, absent-import no-op). Not yet wired. | **High** (§5) | M |
| **3** | Differential-test harness (§7): the sokol-desktop enum-vs-v2 byte anchor + golden-snapshot scaffold. Wire the generic path into `build_files` behind the version gate. Convert **sokol desktop** to v2 (declarative `dep_options`, empty `post_wire`, no `resolve_target`); prove the byte anchor. | High | M |
| **4** | **Shared platform-packager** for `.platforms[p].package` (apk/web) — factor `.android_package`/`.wasm_footer` out of the template into a packager the manifest references. Lands BEFORE Android/wasm so their `.package` delegation is complete. | Med | M |
| **5** | sokol **android** (residual a: NDK sysroot + libc.txt in `post_wire` using `ctx.android_target_sdk`; `resolve_target` for the ABI; packager apk); golden cell. | Med | M |
| **6** | sokol **ios** (`resolve_target`: xcrun SDK + device/simulator before plugin deps; residual b consume in `post_wire`); golden cell. | Med | S |
| **7** | sokol **wasm** (residual c: emcc `emLinkStep`; `.root_build_deps = emsdk` emitted into build.zig.zon); golden cell. | Med | M |
| **8** | Convert **null** + **wgpu** (pure declarative + frameworks); golden each. | Low | S |
| **9** | Convert **raylib** (emsdk wasm hook) + **sdl**; golden each. | Med | M |
| **10** | Convert **bgfx** all platforms (most artifacts, per-platform `loop_style` desktop `.loop`/Android `.callback`, Android `android_app` extra module + bgfx-Android NDK ordering — the piece `manifest_splice.zig:17`–`19` flagged as non-declarative); golden. | High | L |
| **11** | Open config to name+package third-party backends (remove the residual `@tagName` coupling noted at `manifest_splice.zig:34`–`39`); capability validation before wiring (RFC step 1). | Med | M |
| **12** | Delete enum-path sections + v1 splice (§6 step 5); convert the desktop anchor to a golden snapshot. | Low (mechanical, but large diff) | M |

Critical path: **PR 2 → PR 3** is the load-bearing pair (generic core+gfx walk +
proving it reproduces the byte anchor on the first backend). If PR 3's anchor can't
be driven to 0-diff, the generic walk (PR 2) is wrong and must be fixed before any
further backend converts. Everything after PR 3 is repetitive application of the
same gated pattern.

---

## Appendix — files this design touches

- `src/codegen/manifest_splice.zig` — v1 splice; superseded incrementally (§6).
- `src/build_files.zig` — the `switch (cfg.backend)`/`switch (cfg.platform)`
  dispatch (`:264`, `:414`, `:457`, `:598`) collapses to the generic walk.
- `src/templates/build_zig.txt` — the `backend_*`/`link_*`/`.header_ios`/
  `.header_android`/`.ios_*`/`.android_*`/`.link_*_wasm` sections; deleted in PR 12.
- `src/deps_linker.zig` — staging (`createDepsLinks`) unchanged in shape; still
  hardlinks resolved provider packages.
- `src/plugin_manifest.zig` — the versioned-manifest discipline
  (`SUPPORTED_MANIFEST_VERSION`, `:13`; bounded `< 1 or > SUPPORTED` reject at
  `:208`) reused for the header-first `manifest_version` gate and `HOOK_ABI_VERSION`.
- `src/config.zig` — `AndroidConfig.target_sdk_version` (`:214`, default 34) feeds
  `ctx.android_target_sdk` (§4); `build_files.zig:526`–`537` renders it today.
- `backends/<dir>/backend.manifest.zon` + `backends/<dir>/build.zig` — each backend
  ships a v2 manifest + optional hook; sokol fixture converts first.
- `backends/<dir>/build_fragments/*.txt` — v1 raw-text fragments; deleted per
  backend as it converts to v2.

---

## Review corrections (PR #456)

PR #456 merged this design with substantive bot review findings
(coderabbitai + chatgpt-codex) that were never folded in. This revision addresses
them. Each was re-verified against the real code before being accepted.

**Critical / P1 — accepted and folded in:**

1. **v1 manifests must parse before the version gate** (Critical). A mandatory
   `manifest_version` broke v1 routing: `.ignore_unknown_fields` skips extra fields
   but does not supply a missing required one, and the retained
   `backends/sokol/backend.manifest.zon` has no version field. Fixed with a
   header-first two-step parse (`ManifestHeader { manifest_version: u8 = 1 }`) and a
   bounded gate (§3, §6).
2. **Target selection is dynamic, not a static triple** (P1). iOS device/simulator
   (`build_zig.txt:474`–`498`) and Android ABI (`:690`–`726`) resolve from
   `-Ddevice`/`-Demulator`/`-Dandroid_arch` + host. Modeled as `Target.resolved` +
   a pre-dependency `resolve_target` phase (§3, §4).
3. **Dependency options cannot be a runtime `[]Flag`** (P1, load-bearing). A
   `b.dependency` options literal needs comptime-known field names, so a runtime
   hook return cannot expand into it. Redesigned: option *names* are declarative
   (`DepOption.name`), *values* come from a closed `ValueSource` predicate set;
   `pre_wire`/`DependencyOptions` deleted (§3, §4).
4. **Core-diamond walk must keep the engine→gfx override** (P1). The rev-1
   `unifyCoreDiamond` only rewrote core spellings, dropping `engine_mod←gfx`
   (`build_zig.txt:29`–`30`) and leaving two gfx instances. The walk now carries a
   `gfx_mod` singleton and rewrites `labelle-gfx` too (§5).
5. **`backend_*` import aliases must be preserved** (P1). Templates import provider
   modules as `backend_gfx`/`backend_input`/… (`build_zig.txt:213`–`216`,
   `561`–`564`). Added `ModuleDecl.root_alias` defaulting to `backend_<name>` (§3).
6. **iOS SDK must be computed before plugin dependencies** (P1). The generator
   passes `.ios_sdk_path` into plugin `b.dependency` calls (`build_files.zig:212`),
   so xcrun cannot live in `post_wire`. Moved to `resolve_target` (§4).
7. **`link_libc` in mobile specs** (P1). `ios_link:582`, `android_link:850`,
   `android_link_bgfx:881` set `link_libc = true`; no schema field captured it.
   Added `PlatformEntry.link_libc` (§3).
8. **WASM hooks need declared root deps** (P1). The emcc hook calls
   `b.dependency("emsdk")` (`build_zig.txt:253`), which needs the root build.zig.zon
   entry (`build_files.zig:770`). Added `PlatformEntry.root_build_deps` (§3).
9. **Byte-identical gate conflicts with the migration** (P1). The generic walk
   changes generated text even for equivalent graphs. Replaced the enum-vs-v2
   byte-identity invariant with one anchored byte-diff (sokol-desktop) plus
   per-cell golden snapshots (§7).

**P2 — accepted and folded in:**

- **`loop_style` platform-scoped** — bgfx desktop `.loop` vs Android `.callback`;
  moved from top-level into `PlatformEntry` (§3).
- **`.artifacts` platform-scoped** — bgfx desktop links `bgfx`+`glfw`, Android only
  `bgfx`; moved into `PlatformEntry` (§3).
- **Split pre/post context** — resolved by construction: deleting `pre_wire` leaves
  a single `post_wire` `HookContext` whose fields are all valid (no undefined
  post-only pointers). The pre-dependency work now lives in `resolve_target` with
  its own context (§4).
- **Enforce hook isolation in code, not docs** — accepted the critique; concluded a
  `build.zig` hook is not mechanically sandboxable, so the "constrained" claim was
  dropped and the hook is documented as **trusted build code** (same trust as any
  resolved dependency's `build.zig`), with a narrow-facade approach noted as future
  work (§4).
- **Reject unsupported manifest versions** — bounded gate rejects
  `> SUPPORTED_MANIFEST_VERSION` rather than accepting future versions (§3, §6).
- **Land packager before platform conversions** — reordered so the shared packager
  is PR 4, before Android/wasm (§8).
- **Pass Android target SDK into the hook** — added `HookContext.android_target_sdk`
  (from `config.zig:214`) so libc.txt / `addLibraryPath` build the correct
  `usr/lib/<triple>/<target_sdk_version>` (§4).

**Findings judged NOT valid / not separately actioned:** none were rejected as
wrong. The only finding not given a dedicated new mechanism is *"split pre-wire vs
post-wire context fields"*: it is a real hazard in the rev-1 shape, but the
`DependencyOptions` correction (deleting `pre_wire` entirely) dissolves it rather
than requiring separate pre/post context types — so it is resolved indirectly, not
ignored.
