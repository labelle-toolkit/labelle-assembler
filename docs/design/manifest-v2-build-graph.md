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
`backends/<dir>/backend.manifest.zon` (v1 schema, `manifest_splice.zig:52`–`81`).
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
(`paramValue`, `manifest_splice.zig:208`).

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
   (`manifest_splice.zig:208`–`225`) knows exactly `with_imgui`, `gui_enabled`,
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
frameworks, platform matrix), and a **constrained, versioned build hook** for the
~5% that genuinely needs to run build-graph code (NDK/xcrun/emcc + pre-dependency
option flags). The assembler then does the wiring generically for every backend,
built-in or third-party, on every platform.

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
`.system_libs`/`.frameworks`/`.platforms`); **H-pre** = `pre_wire` (option flags,
before `b.dependency`); **H-post** = `post_wire` (supplements the graph after
generic wiring); **CORE** = the generic core-diamond walk (§5), not a per-backend
concern.

| Source | Concrete wiring | Disposition |
|---|---|---|
| `sokol/build_fragments/backend_dep.txt:5` | `b.dependency("labelle_sokol", .{… .with_imgui, .gamepad_enabled, .gamepad_hidapi})` | **H-pre** (option flags) + **D** (dep name from `.dep_name`) |
| `…backend_dep.txt:6`–`10` | `.module("gfx"/"input"/"audio"/"window")`, `.artifact("sokol_clib")` | **D** (`.modules`, `.artifacts`) |
| `…backend_dep.txt:19`–`21` | `overrideImport(sdl_gp_mod, "labelle_core", core_mod)` (if guard) | **CORE** |
| `…backend_dep.txt:29`–`31` | `overrideImport(backend_input, "labelle-core", core_mod)` (Linux, if guard) | **CORE** |
| `sokol/build_fragments/link.txt:1` | `exe.root_module.linkLibrary(sokol_clib)` | **D** (`.artifacts` → generic link) |
| `…link.txt:12`–`16` | `linkFramework("IOSurface"/"CoreFoundation")` on `.macos, .ios` | **D** (`.frameworks` per-OS) |
| `build_zig.txt:57` `.backend_raylib` | `b.dependency(… .gamepad_enabled, .gamepad_hidapi)` | **H-pre** + **D** |
| `build_zig.txt:71`,`:85` | raylib `input`←core, `sdl_gamepad`←core (if guard) | **CORE** |
| `build_zig.txt:233`–`246` `.link_raylib` | `linkLibrary(raylib_artifact)` + per-OS `linkFramework("OpenGL")`/`linkSystemLibrary("GL"/"opengl32")` | **D** (`.artifacts` + `.system_libs`/`.frameworks` per-OS) |
| `build_zig.txt:141` `.backend_sdl` | `overrideImport(backend_input, "labelle_core", core_mod)` | **CORE** |
| `build_zig.txt:393` `.link_sdl` | *(empty)* | **D** (nothing) |
| `build_zig.txt:144` `.backend_bgfx` | `b.dependency(… .gamepad_enabled, .gamepad_hidapi, .gui_enabled)` | **H-pre** + **D** |
| `build_zig.txt:149`–`150` | `.artifact("bgfx")`, `.artifact("glfw")` | **D** (`.artifacts`) |
| `build_zig.txt:396`–`397` `.link_bgfx` | `linkLibrary(bgfx_artifact)`, `linkLibrary(glfw_artifact)` | **D** |
| `build_zig.txt:167`–`172` `.backend_wgpu` | dep + modules + `.artifact("glfw")` | **D** |
| `build_zig.txt:400`–`414` `.link_wgpu` | `linkLibrary(glfw_artifact)` + per-OS `linkFramework("Foundation"/"QuartzCore"/"Metal")` | **D** (`.artifacts` + `.frameworks` per-OS) |
| `build_zig.txt:174`–`181` `.backend_null` | dep + modules, no artifact | **D** |
| `build_zig.txt:426`–`439` `.header_ios` `getIosSdkPath` | `xcrun --sdk … --show-sdk-path` shell-out | **H-post** (c: iOS xcrun) |
| `build_zig.txt:442`–`452` | `configureSdkPaths`/`addExeSdkPaths` (SDK include/lib/framework paths) | **H-post** (derived from xcrun result) |
| `build_zig.txt:455`–`470` `linkIosFrameworks` | `linkFramework("Foundation"/"UIKit"/"Metal"/"MetalKit"/"AudioToolbox"/"AVFoundation"/"QuartzCore"/"GameController")` | **D** (`.frameworks.ios`) |
| `build_zig.txt:481`–`498` | iOS target-triple resolution (device vs simulator, host-arch) | **D** (`.platforms.ios.target`) + **H-post** (device/simulator `-Ddevice` option) |
| `build_zig.txt:535`–`540` `.backend_sokol_ios` | `b.dependency(… .dont_link_system_libs = true, .with_imgui)` | **H-pre** |
| `build_zig.txt:632`–`686` `.header_android` `getAndroidNdkSysroot`/`ndkHostTag` | env lookup + FS probe for NDK sysroot | **H-post** (a: NDK sysroot) |
| `build_zig.txt:715`–`726` | android target-triple + `ndk_arch_triple` derivation | **D** (`.platforms.android.target`) + **H-post** (arch triple) |
| `build_zig.txt:776`–`783` `.backend_sokol_android` | `addSystemIncludePath(ndk_sysroot/usr/include[/triple])`, `sokol_clib.root_module.pic = true` | **H-post** (a) + **D** (`.artifacts.<n>.pic`) |
| `build_zig.txt:851`–`855` `.android_link` | `addLibraryPath(ndk_sysroot/…/{{target_sdk_version}})` + `linkSystemLibrary("android"/"log"/"GLESv3"/"EGL")` | **H-post** (a: lib path) + **D** (`.system_libs.android`) |
| `build_zig.txt:859`–`868` | libc.txt generation (`std.mem.concat` + `addWriteFiles` + `setLibCFile`) | **H-post** (a: libc.txt) |
| `build_zig.txt:891`–`903` `.android_link_bgfx` | `linkSystemLibrary("android"/"log"/"EGL"/"GLESv3"/"m"/"dl"/"mediandk"/"aaudio")` | **D** (`.system_libs.android`) |
| `build_zig.txt:918`–`921` `.android_link_gui_bridge` | `gui_bridge_artifact.root_module.pic = true` + link | **H-post** (bridge is GUI-plugin-owned, not backend; see note) |
| `build_zig.txt:923`–`979` `.android_package` | apk-staging copy + `zip` + `apksigner` shell-outs | **D** (`.platforms.android.package.apk`) → shared packager |
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
  `gamepad_enabled`, `gamepad_hidapi`, `dont_link_system_libs`. All **H-pre**,
  because they change how the dependency artifact is *built* and must be known
  before `b.dependency` is called.

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

The v2 `BackendManifest` supersedes the v1 struct in `manifest_splice.zig:52`–`81`.
It is a ZON file (`backend.manifest.zon`), parsed with `std.zon.parse.fromSliceAlloc`
exactly as `loadManifest` does today (`manifest_splice.zig:170`–`188`), and gated
on `.manifest_version` (§6).

### Concrete field surface

```zig
/// v2 build-graph manifest. Parsed from `backends/<dir>/backend.manifest.zon`.
/// Every field is DATA the assembler wires generically — no backend enum tag
/// appears, and no field is raw Zig source (that was the v1 fragment mistake).
pub const BackendManifestV2 = struct {
    /// Gate. v2 fields are only read when this is >= 2. v1 manifests
    /// (no field / == 1) stay on the v1 splice + enum path (§6).
    manifest_version: u8, // = 2

    /// Package identity — replaces v1 `dir_name`/`dep_name`. `id` is the
    /// canonical namespaced ID checked for collisions (RFC "Provider identity").
    dir_name: []const u8,
    dep_name: []const u8,
    id: []const u8, // e.g. "labelle.sokol"

    /// Run-loop style — retained from v1 (manifest_splice.zig:66). `.callback`
    /// = the windowing runtime owns the loop (sokol); `.loop` = generated main
    /// drives `while (!shouldQuit())` (raylib/bgfx-desktop).
    loop_style: enum { callback, loop },

    /// Named modules the provider exposes; the assembler imports each into the
    /// root module under its key. Replaces the four hand-written
    /// `.module("gfx"/"input"/"audio"/"window")` lines in every fragment.
    /// Optional platform-scoped modules (bgfx-Android's `android_app`) are
    /// declared under `.platforms.<p>.extra_modules`.
    modules: []const ModuleDecl, // { name, source }

    /// C archives the provider ships. Generic link pass calls
    /// `linkLibrary(backend_dep.artifact(name))` for each; applies `.pic`.
    artifacts: []const ArtifactDecl,

    /// Per-platform, per-OS system libraries → `linkSystemLibrary`.
    system_libs: SystemLibs,

    /// Per-platform Apple frameworks → `linkFramework` (Zig distinguishes
    /// these from system libs).
    frameworks: Frameworks,

    /// The (backend × platform) matrix. Absent platform = unsupported.
    platforms: Platforms,

    /// OPTIONAL. Relative path to the provider's build hook (§4). Absent =
    /// fully declarative backend, no hook compiled/called.
    build_hook: ?[]const u8 = null,

    pub const ModuleDecl = struct {
        name: []const u8, // import key, e.g. "gfx"
        source: []const u8, // e.g. "src/gfx.zig" (only used when the assembler
                            // builds the module directly; for b.dependency-
                            // sourced modules this is informational)
    };

    pub const ArtifactDecl = struct {
        name: []const u8, // b.dependency(...).artifact(name)
        pic: bool = false, // force -fPIC (Android .so requirement, #147)
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
        /// Cross-compile triple. `.native` for desktop; a triple string for
        /// mobile/wasm. Replaces the hand-written resolveTargetQuery blocks.
        target: Target, // .native | .{ .triple = "aarch64-linux-android" }
        /// Root-module PIC (Android .so). Static per-platform fact (§2 note 1).
        pic: bool = false,
        /// Extra platform-only modules (bgfx-Android `android_app`).
        extra_modules: []const ModuleDecl = &.{},
        /// Packaging recipe handed to the shared platform-packager.
        package: Package, // .binary | .{ .apk = … } | .{ .web = … }
    };
    pub const Platforms = struct {
        desktop: ?PlatformEntry = null,
        android: ?PlatformEntry = null,
        ios: ?PlatformEntry = null,
        wasm: ?PlatformEntry = null,
    };

    pub const Target = union(enum) { native, triple: []const u8 };
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
data; only the four residuals (§2 a–d) go to the hook.

```zig
.{
    .manifest_version = 2,
    .dir_name = "sokol",
    .dep_name = "labelle_sokol",
    .id = "labelle.sokol",
    .loop_style = .callback,

    .modules = .{
        .{ .name = "gfx",    .source = "src/gfx.zig" },
        .{ .name = "input",  .source = "src/input.zig" },
        .{ .name = "audio",  .source = "src/audio.zig" },
        .{ .name = "window", .source = "src/window.zig" },
    },
    .artifacts = .{
        // pic=true replaces the hand-written `sokol_clib.root_module.pic = true`
        // (build_zig.txt:783). Declarative per §2 note 1.
        .{ .name = "sokol_clib", .pic = true },
    },
    .system_libs = .{
        .android = .{ "android", "log", "GLESv3", "EGL" }, // .android_link:852-855
        // desktop/ios system libs: none — sokol links via frameworks.
    },
    .frameworks = .{
        // IOSurface/CoreFoundation on Darwin — replaces link.txt:12-16 switch.
        .desktop = .{ .macos = .{ "IOSurface", "CoreFoundation" } },
        .ios = .{ "Foundation", "UIKit", "Metal", "MetalKit", "AudioToolbox",
                  "AVFoundation", "QuartzCore", "GameController" }, // linkIosFrameworks
    },
    .platforms = .{
        .desktop = .{ .entry = "templates/desktop.txt", .target = .native, .package = .binary },
        .ios = .{ .entry = "templates/mobile.txt",
                  .target = .{ .triple = "aarch64-ios" }, // device; simulator via hook -Ddevice
                  .package = .binary },
        .android = .{ .entry = "templates/mobile.txt",
                      .target = .{ .triple = "aarch64-linux-android" },
                      .pic = true, // android_exe_start root module pic (build_zig.txt:824)
                      .package = .{ .apk = .{ .manifest = "AndroidManifest.xml.tmpl" } } },
        .wasm = .{ .entry = "templates/wasm.txt",
                   .target = .{ .triple = "wasm32-emscripten" },
                   .package = .{ .web = .{ .shell = null } } },
    },
    // sokol needs a hook for: (a) NDK sysroot+libc.txt, (b) xcrun+dont_link_system_libs,
    // (c) emcc emLinkStep, (d) with_imgui/gamepad_* option flags. See §4.
    .build_hook = "build.zig",
}
```

What the assembler now does generically for this manifest (the RFC's 7-step walk,
lines 1457–1493): resolve `labelle_sokol`, call the hook's `pre_wire` to compute
`b.dependency` options, emit `b.dependency`, pull `.modules`, run the generic
core-diamond walk (§5), `linkLibrary` each `.artifacts` entry applying `.pic`,
`linkSystemLibrary`/`linkFramework` from `.system_libs`/`.frameworks` for the
active platform+OS, splice the `.platforms[p].entry` template, call the hook's
`post_wire` for the residual, and delegate packaging to the shared packager per
`.platforms[p].package`.

---

## 4. The constrained `HookContext` / `DependencyOptions`

The hook is the escape hatch for the ~5% residual (§2 a–d). It is a `build.zig`
the provider ships, imported by the assembler and called at **two** injection
points. It is deliberately **constrained by contract** so it can never degrade
into an arbitrary backend build script (RFC lines 1530–1548).

### Type surface

```zig
/// Versioned with `manifest_version`: the hook declares which version it targets;
/// the assembler asserts compatibility before calling (same discipline as
/// plugin_manifest.zig's SUPPORTED_MANIFEST_VERSION gate, :13/:203-213).
pub const HOOK_ABI_VERSION: u8 = 2;

/// Everything the hook is ALLOWED to read. Constructed by the assembler; the
/// hook may not reach outside these fields (no ambient std.Build access beyond
/// `b`, no FS/network — see Constraints).
pub const HookContext = struct {
    manifest_version: u8, // asserted == HOOK_ABI_VERSION by the assembler

    /// The resolved dependency. NULL in pre_wire (the whole point of pre_wire
    /// is to run BEFORE b.dependency); non-null in post_wire.
    backend_dep: ?*std.Build.Dependency,

    /// The root module being assembled (exe/lib root). post_wire only.
    root_module: *std.Build.Module,

    /// The root compile artifact (exe or dynamic lib), so post_wire can call
    /// linkLibrary / setLibCFile / addLibraryPath. post_wire only.
    root_artifact: *std.Build.Step.Compile,

    /// Resolved target + optimize, so the hook can branch on os.tag / arch
    /// exactly as the current switch blocks do.
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,

    /// The active platform (desktop/android/ios/wasm) so the hook dispatches
    /// its residual without re-deriving it.
    platform: Platform,

    /// The read-only project facts the option flags depend on — computed by the
    /// assembler with the SAME predicates paramValue() uses today
    /// (manifest_splice.zig:208-225). The hook does NOT recompute them.
    gui_is_imgui: bool,   // cfg.resolved_gui.name == "imgui"
    gamepad_enabled: bool, // cfg.gamepad == .auto
    gamepad_hidapi: bool,  // cfg.gamepad_hidapi
    ios_device_mode: bool, // -Ddevice (simulator vs device)
};

/// The option struct the assembler forwards to b.dependency. A flat string-keyed
/// map so a third-party backend can introduce a new flag without patching the
/// assembler (fixes limit #2 in §1). Keys/values are appended to the generic
/// `.{ .target, .optimize }` base the assembler always passes.
pub const DependencyOptions = struct {
    /// Ordered (name, zig-literal-value) pairs, e.g. ("with_imgui","true").
    /// Rendered into the b.dependency options struct by the assembler.
    flags: []const Flag,
    pub const Flag = struct { name: []const u8, value: []const u8 };
};
```

### Entry points

```zig
/// Runs BEFORE `b.dependency`. Returns the option flags that must be known
/// before the dependency artifact is built (§2 residual d: with_imgui,
/// gamepad_enabled, gamepad_hidapi, dont_link_system_libs). Pure function of
/// ctx — constructs no graph nodes.
pub fn pre_wire(b: *std.Build, ctx: HookContext) DependencyOptions {
    var flags = std.ArrayList(DependencyOptions.Flag).init(b.allocator);
    flags.append(.{ .name = "with_imgui", .value = if (ctx.gui_is_imgui) "true" else "false" }) catch @panic("OOM");
    switch (ctx.platform) {
        .desktop => {
            flags.append(.{ .name = "gamepad_enabled", .value = if (ctx.gamepad_enabled) "true" else "false" }) catch @panic("OOM");
            flags.append(.{ .name = "gamepad_hidapi",  .value = if (ctx.gamepad_hidapi) "true" else "false" }) catch @panic("OOM");
        },
        .ios, .android => flags.append(.{ .name = "dont_link_system_libs", .value = "true" }) catch @panic("OOM"),
        .wasm => {}, // wasm passes only with_imgui (build_zig.txt:124)
    }
    return .{ .flags = flags.items };
}

/// Runs AFTER generic module/artifact/system-lib/framework wiring. Supplements
/// the graph with the residual the manifest can't express statically (§2
/// residual a/b/c). Constructs build-graph nodes + manifest-modeled shell-outs
/// only.
pub fn post_wire(b: *std.Build, ctx: HookContext) void {
    switch (ctx.platform) {
        .android => {
            const sysroot = getAndroidNdkSysroot(b) orelse @panic("NDK not found");
            // addSystemIncludePath / addLibraryPath / setLibCFile(libc.txt) …
        },
        .ios => {
            const sdk = getIosSdkPath(b, if (ctx.ios_device_mode) "iphoneos" else "iphonesimulator") orelse @panic("no iOS SDK");
            // configureSdkPaths / addExeSdkPaths …
        },
        .wasm => { /* emccStep / emLinkStep on ctx.root_artifact */ },
        .desktop => {}, // fully declarative — no residual
    }
}
```

### Constraints (enforced by contract + review, documented in the manifest schema)

1. **Versioned.** `HOOK_ABI_VERSION` bumps with `manifest_version`. The assembler
   asserts `ctx.manifest_version == HOOK_ABI_VERSION` before calling, mirroring
   `plugin_manifest.zig`'s `SUPPORTED_MANIFEST_VERSION` gate (`:13`, `:203`–`213`).
   A hook built against v3 types cannot be called by a v2 assembler and vice
   versa — a readable early error, not a segfault.

2. **May only read documented `ctx` fields.** No ambient `std.Build` access
   beyond `b`; no reaching into `cfg` (the hook gets pre-digested booleans, not
   the config).

3. **May only construct build-graph nodes** (`b.dependency`, `linkLibrary`,
   `linkSystemLibrary`, `linkFramework`, `addSystemIncludePath`, `addLibraryPath`,
   `setLibCFile`, `addWriteFiles`, module wiring) **and manifest-modeled
   shell-outs** (emcc/xcrun/NDK probe). **No arbitrary filesystem access outside
   the provider's own package, no network.** A backend that needs more than the
   documented surface is a signal to **extend the manifest**, not the hook
   (RFC line 1541).

4. **`pre_wire` constructs no graph nodes** — it runs before `b.dependency`
   exists, so `ctx.backend_dep` is null and it returns pure data.

### Why the split is mandatory

A single after-generic `wire` hook (the rev 7-9 design) is known-insufficient:
sokol's `with_imgui` (`build_zig.txt:94`, and the caching hazard documented at
`build_fragments/backend_dep.txt:1`–`4`, assembler#140) changes how `sokol_clib`
is *compiled* and must reach `b.dependency`'s options struct *before* the artifact
is built. NDK/xcrun/emcc supplement the graph *after*. Two phases, two hooks.

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

All of these are instances of **one rule**: *for every module the app imports from
a resolved provider, walk its `import_table`; wherever a key resolves to a
`labelle-core`/`labelle_core` provider, override it onto the app's single
`core_mod`; recurse into sub-packages that themselves import core.* This is
exactly what `overrideImport` (`build_zig.txt:341`) + `unifyGfxSubpackageCore`
(`:355`) already do, but generalized from a hardcoded name list to a graph walk:

```zig
/// Generic core-diamond unification. Replaces every hand-written site above.
/// Walks the provider module graph; overrides any core import (either spelling)
/// onto core_mod; recurses. Idempotent, bounded by a visited set.
fn unifyCoreDiamond(root: *std.Build.Module, core_mod: *std.Build.Module, visited: *ModuleSet) void {
    if (visited.contains(root)) return;
    visited.put(root, {});
    var it = root.import_table.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "labelle-core") or std.mem.eql(u8, key, "labelle_core")) {
            overrideImport(root, key, core_mod); // preserve the existing key spelling
        } else {
            unifyCoreDiamond(entry.value_ptr.*, core_mod, visited); // recurse into sub-packages
        }
    }
}
```

The assembler runs this once over each imported provider module (`gfx`, `engine`,
and every `.modules` entry — `input`/`audio`/`window`/`android_app`). The
`if`-guards vanish (an absent import is simply not visited), both key spellings are
handled by the walk, and the `{camera, spatial_grid, tilemap}` list becomes "every
transitive sub-import that names core" — resilient if gfx restructures.

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

Mitigation: land the generic walk behind the byte-equivalence differential test
(§7) so any drift from the current per-site output is caught as a non-zero diff
before it reaches a cross-compile.

---

## 6. Migration ordering (flag-day mitigation)

No flag day. Both existing routes stay alive; v2 is gated and rolled out one
backend × one platform at a time.

1. **Land the v2 types + generic wiring behind a gate, dark.** Add
   `BackendManifestV2` and the generic walk/link/hook machinery. Gate strictly on
   `manifest_version >= 2` (parsed first, before any v2 field is read — the parser
   already tolerates this via `.ignore_unknown_fields = true`,
   `manifest_splice.zig:183`). A v1 manifest (`backends/sokol/backend.manifest.zon`
   as it stands, no `manifest_version` field / implicitly 1) keeps the v1 splice.
   A backend with no manifest keeps the enum path. **Zero behavior change** at this
   step — nothing declares v2 yet.

2. **Convert the sokol in-tree fixture to v2, desktop only.** `backends/sokol` is
   the retained offline fixture the codegen tests resolve against
   (`manifest_splice.zig:351`–`366`). Bump its manifest to v2 with the desktop
   platform entry + a `build.zig` hook implementing `pre_wire` (with_imgui/gamepad)
   and an empty desktop `post_wire`. The byte-equivalence test (§7) gates this: v2
   output for sokol-desktop must be 0-diff against the v1 splice output, which is
   already 0-diff against the enum path.

3. **Add platforms to sokol one at a time**, each gated by its own 0-diff test:
   **desktop → android → ios → wasm.** Android brings residual (a) into the hook;
   iOS brings (b); wasm brings (c). Each platform is a separate PR with its own
   differential fixture, so an NDK/xcrun/emcc regression is isolated to one PR.

4. **Convert the remaining backends one at a time**, in ascending residual order:
   `null` (pure declarative, no hook, no artifact) → `wgpu` (declarative + glfw
   artifact + Metal frameworks) → `raylib` (adds emsdk wasm hook) → `sdl` → `bgfx`
   (most artifacts + Android `android_app` extra module + bgfx-Android NDK). Each
   backend × platform is 0-diff gated.

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

## 7. Byte-equivalence differential test

The invariant that guards the whole migration: **for every (backend, platform,
representative cfg), the v2-generated `build.zig` must be byte-identical to the
enum-path output** (which is the established-correct baseline that ships today).

Rationale, restated from §5: module-unification and link-ordering bugs do **not**
show up in `zig build test`. They surface only in a CI cross-compile link. A
0-diff gate on the *generated source text* catches the regression at generation
time — before it ever reaches a cross-compile — because if the bytes match, the
build graph the two routes construct is identical by construction.

### Mechanism

The v1 splice already asserts byte-identity informally ("verified vs a generated
baseline", `backends/sokol/backend.manifest.zon:4`). v2 makes it a first-class,
automated gate:

1. A test harness enumerates a fixture matrix: each backend × each supported
   platform × a small set of representative `ProjectConfig`s (gui=imgui vs none;
   gamepad auto vs off; hidapi on/off — the exact inputs `paramValue`
   (`manifest_splice.zig:208`) and `pre_wire` branch on).
2. For each cell it runs the build-file generator twice into two buffers: once
   forcing the **enum path** (v2 gate off) and once forcing the **v2 path** (v2
   gate on), against the same cfg + the `backends/sokol` fixture.
3. It asserts the two buffers are **exactly equal** (`std.testing.expectEqualStrings`).
   A non-zero diff fails the test with a readable line-level delta.
4. The cell is added to the matrix in the *same PR* that converts that
   backend × platform to v2 (§6). A conversion PR cannot merge unless its cell is
   0-diff.

### Scope + limits

- The test compares **generated text**, not build behavior — it is fast (no
  `zig build`) and runs in the ordinary `zig build test` suite.
- It does **not** replace CI cross-compile smoke builds — those still catch
  toolchain/SDK issues the text diff can't (a wrong NDK path that is *spelled*
  identically but points nowhere). But the text diff catches the entire class of
  "v2 wired a different graph than the enum path" regressions, which is the
  migration's dominant risk.
- Once a backend × platform is fully migrated and its enum arm deleted (§6 step 5),
  its differential cell is retired (there is no enum baseline left to diff
  against); it is replaced by a golden-file snapshot test so the v2 output stays
  pinned.

---

## 8. Effort + PR breakdown

A suggested sequence. Each PR is independently reviewable and (from PR 3 onward)
0-diff gated.

| PR | Scope | Risk | Est. |
|---|---|---|---|
| **1** | v2 types: `BackendManifestV2`, `HookContext`, `DependencyOptions`, `HOOK_ABI_VERSION`; version gate parsing (reuse `plugin_manifest.zig` discipline). No wiring, no consumer. Unit tests for parse + version rejection. | Low | S |
| **2** | Generic core-diamond walk (`unifyCoreDiamond` + visited set) as a standalone helper + unit tests over synthetic module graphs (both key spellings, recursion, idempotence, absent-import no-op). Not yet wired into generation. | **High** (§5) | M |
| **3** | Differential-test harness (§7): enum-vs-v2 buffer diff, fixture matrix scaffold. Wire the generic path into `build_files` behind the `manifest_version >= 2` gate. Convert **sokol desktop** to v2; prove 0-diff. | High | M |
| **4** | sokol **android** (residual a: NDK sysroot + libc.txt in `post_wire`); add cell; 0-diff. | Med | M |
| **5** | sokol **ios** (residual b: xcrun in `post_wire`, `-Ddevice`); 0-diff. | Med | S |
| **6** | sokol **wasm** (residual c: emcc `emLinkStep`); 0-diff. | Med | M |
| **7** | Shared platform-packager delegation for `.platforms[p].package` (apk/web) — factor `.android_package`/`.wasm_footer` out of the template into a packager the manifest references. | Med | M |
| **8** | Convert **null** + **wgpu** (pure declarative + frameworks); 0-diff each. | Low | S |
| **9** | Convert **raylib** (emsdk wasm hook) + **sdl**; 0-diff each. | Med | M |
| **10** | Convert **bgfx** all platforms (most artifacts, Android `android_app` extra module + bgfx-Android NDK ordering — the piece `manifest_splice.zig:17`–`19` flagged as non-declarative); 0-diff. | High | L |
| **11** | Open config to name+package third-party backends (remove the residual `@tagName` coupling noted at `manifest_splice.zig:34`–`39`); capability validation before wiring (RFC step 1). | Med | M |
| **12** | Delete enum-path sections + v1 splice (§6 step 5); convert differential cells to golden snapshots. | Low (mechanical, but large diff) | M |

Critical path: **PR 2 → PR 3** is the load-bearing pair (generic core walk +
proving it 0-diff on the first backend). If PR 3's differential test can't be
driven to 0-diff, the generic walk (PR 2) is wrong and must be fixed before any
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
- `src/plugin_manifest.zig` — the versioned-manifest discipline (`SUPPORTED_MANIFEST_VERSION`,
  `:13`/`:203`–`213`) reused for `manifest_version >= 2` gating and `HOOK_ABI_VERSION`.
- `backends/<dir>/backend.manifest.zon` + `backends/<dir>/build.zig` — each backend
  ships a v2 manifest + optional hook; sokol fixture converts first.
- `backends/<dir>/build_fragments/*.txt` — v1 raw-text fragments; deleted per
  backend as it converts to v2.
