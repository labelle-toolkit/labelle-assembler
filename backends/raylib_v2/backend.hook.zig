//! raylib backend build hook (manifest-v2, epic #453 item 3, PR 9) — the
//! DEDICATED hook file the v2 manifest points at via
//! `.build_hook = "backend.hook.zig"` (design §3/§4). It is NOT raylib's own
//! `build.zig`: that file re-exports `pub const emsdk = @import("raylib-zig").emsdk;`
//! at top level, and `"raylib-zig"` is a name resolvable only inside the
//! labelle_raylib package build context — absent from the generated ROOT package
//! the assembler imports the hook into. So the hook makes NO package-local import
//! assumptions: it may `@import("std")` (and `@import("builtin")`) and take
//! everything else through the hook context.
//!
//! ## Scope — raylib is DESKTOP + WASM; only WASM is hook-bearing
//!
//! DESKTOP has no residual: it is fully declarative (the raylib artifact + the
//! per-OS OpenGL system-lib/framework switch are emitted by the assembler from the
//! manifest) and `.target = .native` resolves without a hook, so the assembler
//! never invokes this hook on a desktop build. raylib ships NO android/ios
//! templates, so this hook has NO `resolve_target` (no `.resolved` platform).
//!
//! WASM is the emcc residual (design §2 (c)). Its target is the STATIC `.triple`
//! "wasm32-emscripten" (design §3, resolved directly in the generated build.zig),
//! so there is no `resolve_target`. Its `post_wire` .wasm arm supplies the
//! Emscripten `emcc` link step (the enum `.link_raylib_wasm`, `build_zig.txt:285`-
//! `309`) plus the `wasm_footer` install/run wiring (`build_zig.txt:334`-`337`).
//! The enum path reaches emcc via `@import("labelle_raylib").emsdk.emccStep` — but
//! the hook is std-only and CANNOT import the provider package, so the link step
//! is reconstructed here (`emLinkStep` below) from ONLY `std.Build` + the emsdk
//! dependency, which the hook resolves via `b.dependency("emsdk", .{})`. That call
//! is why the manifest declares `.platforms.wasm.root_build_deps = emsdk` and the
//! assembler emits emsdk into the generated `build.zig.zon` (design §3
//! `RootBuildDep`). Because `post_wire` returns `void` it also owns the install/run
//! wiring (the enum `emcc_step` local cannot escape a void hook back to the build
//! fn), so the v2 wasm path does NOT emit the `.wasm_footer`/packager `.web` block
//! — see `manifest_v2_splice`'s wasm notes.
//!
//! The generated v2 build.zig `@import`s this file (as a sibling
//! `backend_build_hook.zig`) and calls `post_wire`; that import is the design's
//! "assembler imports the hook into the generated root package" (§3).

const std = @import("std");

/// Versioned with `manifest_v2.HOOK_ABI_VERSION`; the assembler asserts
/// compatibility before calling. Bumps only on a breaking ctx/ABI change.
pub const HOOK_ABI_VERSION: u8 = 2;

/// The platform the hook is invoked for. raylib supports only desktop + wasm; the
/// mobile arms exist for `HookContext` shape-compatibility with `manifest_v2` and
/// are never reached (raylib declares no android/ios platform entry).
pub const Platform = enum { desktop, ios, android, wasm };

// ── post_wire (design §4) — runs AFTER generic wiring ──────────────────────

/// `post_wire` context (design §4). Every field is valid because `post_wire` runs
/// strictly AFTER `b.dependency` and after the root exe/lib is created. Kept
/// structurally in sync with `manifest_v2.HookContext`.
pub const HookContext = struct {
    manifest_version: u8,
    backend_dep: *std.Build.Dependency,
    root_module: *std.Build.Module,
    root_artifact: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    platform: Platform,
    ios_sdk_path: ?[]const u8,
    android_target_sdk: ?u32,
};

// ── wasm emcc residual (design §2 (c)) — the emLinkStep reconstruction ──────
//
// The enum path links wasm via `@import("labelle_raylib").emsdk.emccStep`
// (`build_zig.txt:304`), which re-exports raylib-zig's emsdk helpers. The hook is
// std-only and cannot import the provider package, so the step is reconstructed
// here from ONLY `std.Build` + the emsdk dependency. Like sokol-zig's `emLinkStep`
// (which is itself pure `std.Build` — it locates `emcc` through `emsdk.path(...)`
// and shells out) this locates emcc under the resolved emsdk and shells out with
// the raylib web settings the enum path sets.

/// The C-stack bump the raylib wasm build needs. Emscripten defaults to a 64 KB
/// stack, which the engine's scene-load + atlas-decode path overflows into the
/// WASM `.data` segment (labelle-cli#201 / assembler#100); the enum
/// `.link_raylib_wasm` sets `STACK_SIZE=524288` (`build_zig.txt:302`). Kept a
/// named constant so the residual decision is unit-testable without a live
/// `*std.Build`.
pub const wasm_stack_size_arg = "-sSTACK_SIZE=524288";

/// Allow the WASM heap to grow at runtime (enum `.link_raylib_wasm`
/// `emcc_settings.put("ALLOW_MEMORY_GROWTH", "1")`, `build_zig.txt:293`).
pub const wasm_allow_memory_growth_arg = "-sALLOW_MEMORY_GROWTH=1";

/// raylib's web build uses Emscripten's GLFW3 emulation for windowing/input, and
/// asyncify so the emscripten main-loop callback can yield (enum
/// `emccDefaultFlags(.{ .asyncify = true })`, `build_zig.txt:288`).
pub const wasm_use_glfw_arg = "-sUSE_GLFW=3";
pub const wasm_asyncify_arg = "-sASYNCIFY";

// ── WASM link optimization, independent of Zig's optimize mode ─────────────
//
// Same setting as labelle-bgfx's hook (labelle-bgfx#208). The emcc `-O` level
// used to follow `-Doptimize` alone; `LABELLE_WASM_LINK_OPT` (or
// `-Dwasm_link_opt`, which wins) picks it independently, so CI/preview builds
// can link at `-O1`. Only the `-O` flag changes: assertions, SAFE_HEAP/stack
// checks and every backend setting still follow the Zig mode. Unset or
// `default` keeps the previous link line byte for byte.

/// The emcc link optimization level. `default` is the Zig-mode mapping.
pub const WasmLinkOpt = enum { default, O0, O1, O2, O3, Os, Oz };
pub const wasm_link_opt_env = "LABELLE_WASM_LINK_OPT";
pub const wasm_link_opt_option = "wasm_link_opt";

/// Null/empty/whitespace is `default`; otherwise an exact `WasmLinkOpt` tag.
pub fn parseWasmLinkOpt(value: ?[]const u8) error{InvalidWasmLinkOpt}!WasmLinkOpt {
    const raw = value orelse return .default;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return .default;
    return std.meta.stringToEnum(WasmLinkOpt, trimmed) orelse error.InvalidWasmLinkOpt;
}

/// The emcc `-O` flag: `link_opt` verbatim, or the Zig-mode mapping (Debug
/// `-Og`, ReleaseSmall `-Oz`, ReleaseSafe/ReleaseFast `-O3`).
pub fn emccOptArg(optimize: std.builtin.OptimizeMode, link_opt: WasmLinkOpt) []const u8 {
    return switch (link_opt) {
        .default => switch (optimize) {
            .Debug => "-Og",
            .ReleaseSmall => "-Oz",
            .ReleaseSafe, .ReleaseFast => "-O3",
        },
        .O0 => "-O0",
        .O1 => "-O1",
        .O2 => "-O2",
        .O3 => "-O3",
        .Os => "-Os",
        .Oz => "-Oz",
    };
}

/// The optimization + safety args, in the pre-#208 link-line order. Debug:
/// `<-O> -sSAFE_HEAP=1 -sSTACK_OVERFLOW_CHECK=1`; otherwise
/// `-sASSERTIONS=<1 ReleaseSafe | 0> <-O>` (Emscripten defaults assertions
/// off at -O1+, so ReleaseSafe sets them explicitly).
pub fn emccOptimizeArgs(optimize: std.builtin.OptimizeMode, link_opt: WasmLinkOpt) EmccOptimizeArgs {
    const o = emccOptArg(optimize, link_opt);
    return switch (optimize) {
        .Debug => .{ .buf = .{ o, "-sSAFE_HEAP=1", "-sSTACK_OVERFLOW_CHECK=1" }, .len = 3 },
        .ReleaseSafe => .{ .buf = .{ "-sASSERTIONS=1", o, "" }, .len = 2 },
        .ReleaseFast, .ReleaseSmall => .{ .buf = .{ "-sASSERTIONS=0", o, "" }, .len = 2 },
    };
}

pub const EmccOptimizeArgs = struct {
    buf: [3][]const u8,
    len: usize,
    pub fn slice(self: *const EmccOptimizeArgs) []const []const u8 {
        return self.buf[0..self.len];
    }
};

/// `-Dwasm_link_opt` if given, else `LABELLE_WASM_LINK_OPT`, else `default`.
/// Declares the build option on `b`: call once per builder (`post_wire`).
pub fn resolveWasmLinkOpt(b: *std.Build) WasmLinkOpt {
    const from_option = b.option(
        WasmLinkOpt,
        wasm_link_opt_option,
        "emcc link optimization, independent of -Doptimize (default: the -Doptimize mapping; O1 = fast CI/preview link). Overrides " ++ wasm_link_opt_env,
    );
    if (from_option) |v| return v;
    return parseWasmLinkOpt(b.graph.environ_map.get(wasm_link_opt_env)) catch std.debug.panic(
        "{s}='{s}' is not a WASM link level; use one of default, O0, O1, O2, O3, Os, Oz",
        .{ wasm_link_opt_env, b.graph.environ_map.get(wasm_link_opt_env).? },
    );
}

/// Options for `emLinkStep` — the subset of raylib-zig's emcc options the wasm
/// residual sets. Uses only `std.Build`/`std.builtin` types so the hook stays
/// provider-import-free.
pub const EmLinkOptions = struct {
    optimize: std.builtin.OptimizeMode,
    /// emcc link optimization (`WasmLinkOpt`, labelle-bgfx#208). `default`
    /// keeps the `-Doptimize` mapping; `post_wire` resolves it.
    link_opt: WasmLinkOpt = .default,
    /// The Zig code compiled to a static lib that emcc links into the module.
    lib_main: *std.Build.Step.Compile,
    /// The raylib C archive (`backend_dep.artifact("raylib")`) — passed to emcc
    /// explicitly, mirroring the enum `emsdk.emccStep(b, raylib_artifact, wasm, …)`.
    lib_backend: *std.Build.Step.Compile,
    /// The emsdk dependency, resolved by the caller via `b.dependency("emsdk", .{})`.
    emsdk: *std.Build.Dependency,
};

/// Path to an emscripten tool (e.g. `emcc`) inside the resolved emsdk dependency.
fn emTool(b: *std.Build, emsdk: *std.Build.Dependency, tool: []const u8) std.Build.LazyPath {
    return emsdk.path(b.fmt("upstream/emscripten/{s}", .{tool}));
}

/// Reconstruction of raylib-zig's emcc link step using only `std.Build` + the
/// emsdk dependency. Builds the `emcc` shell-out that links `lib_main` + the
/// `raylib` C archive into the `.html`/`.wasm`/`.js` module and installs them
/// under `web/`. Returns the install step so the caller can wire it into
/// `b.getInstallStep()` + the run step.
pub fn emLinkStep(b: *std.Build, options: EmLinkOptions) *std.Build.Step.InstallDir {
    // Pass emcc as a LazyPath via addFileArg so the emsdk path resolves lazily at
    // step-execution time — NOT eagerly at build-configuration time. Calling
    // `.getPath(b)` here would force resolution during configure and break lazy
    // evaluation (PR #470 gemini finding). `Run.create` + `addFileArg` is the
    // lazy-safe form; the step name "emcc" also hides the resolved path in the log.
    const emcc = std.Build.Step.Run.create(b, "emcc");
    emcc.addFileArg(emTool(b, options.emsdk, "emcc"));
    // Optimization + safety flags. The `-O` level follows `link_opt`
    // (LABELLE_WASM_LINK_OPT, labelle-bgfx#208) when set; the safety flags
    // always follow the Zig mode.
    const opt_args = emccOptimizeArgs(options.optimize, options.link_opt);
    emcc.addArgs(opt_args.slice());
    // raylib web settings (enum `.link_raylib_wasm`): GLFW3 emulation, asyncify,
    // memory growth, and the 512 KB stack bump.
    emcc.addArg(wasm_use_glfw_arg);
    emcc.addArg(wasm_asyncify_arg);
    emcc.addArg(wasm_allow_memory_growth_arg);
    emcc.addArg(wasm_stack_size_arg);

    // The main lib + the raylib C archive, then every remaining static-lib dep.
    emcc.addArtifactArg(options.lib_main);
    emcc.addArtifactArg(options.lib_backend);
    emcc.addArg("-o");
    const out_file = emcc.addOutputFileArg(b.fmt("{s}.html", .{options.lib_main.name}));

    // emcc emits 3 files (.html/.wasm/.js) into out_file's dir → install to web/.
    const install = b.addInstallDirectory(.{
        .source_dir = out_file.dirname(),
        .install_dir = .prefix,
        .install_subdir = "web",
    });
    install.step.dependOn(&emcc.step);
    return install;
}

/// Runs AFTER the generic module/artifact/system-lib/framework wiring. DESKTOP is
/// empty (fully declarative — no residual). WASM does the Emscripten emcc link
/// step + install/run wiring (design §2 (c)). raylib declares no android/ios
/// platform, so those arms are unreachable.
pub fn post_wire(b: *std.Build, ctx: HookContext) void {
    switch (ctx.platform) {
        .desktop => {}, // fully declarative — no residual
        .wasm => {
            // Residual (c): the Emscripten emcc link step + install/run wiring
            // (enum `.link_raylib_wasm` + `.wasm_footer`). emsdk is resolved via
            // `b.dependency` — declared as a root build dep by the manifest's
            // `.root_build_deps` and emitted into the generated build.zig.zon. The
            // declarative `linkLibrary(raylib)` is emitted by the assembler BEFORE
            // this call, so the raylib archive is reachable here via the backend dep.
            const emsdk = b.dependency("emsdk", .{});
            const raylib_artifact = ctx.backend_dep.artifact("raylib");
            const install = emLinkStep(b, .{
                .optimize = ctx.optimize,
                .link_opt = resolveWasmLinkOpt(b),
                .lib_main = ctx.root_artifact,
                .lib_backend = raylib_artifact,
                .emsdk = emsdk,
            });
            // `post_wire` is void, so the enum `emcc_step` local cannot escape to
            // the build fn for a packager footer — the hook wires install/run
            // itself (enum `.wasm_footer`, `build_zig.txt:335`-`337`).
            b.getInstallStep().dependOn(&install.step);
            const run_step = b.step("run", "Serve WASM build");
            run_step.dependOn(&install.step);
        },
        .ios, .android => @panic("raylib backend has no android/ios platform"),
    }
}

// ============================================================================
// Tests — the PURE residual/decision helpers (design §7 "run the hook").
//
// This file is compiled as a test target in the assembler's `build.zig`, which
// ALSO typechecks `post_wire`/`emLinkStep` against the real `std.Build` API — a
// compile-level gate that a residual API call (addSystemCommand/addArtifactArg/
// addInstallDirectory/…) stays valid. The pure tests below assert the residual
// DECISIONS (the raylib web emcc args) without a live `*std.Build`.
// ============================================================================

const testing = std.testing;

test "HOOK_ABI_VERSION is 2 (matches manifest_v2)" {
    try testing.expectEqual(@as(u8, 2), HOOK_ABI_VERSION);
}

test "wasm emcc args reproduce the enum .link_raylib_wasm settings" {
    // The wasm emcc residual (design §2 (c)) must reproduce the enum path's
    // GLFW3 emulation + asyncify + memory-growth + 512 KB stack
    // (build_zig.txt:288/:293/:302). The `emLinkStep` reconstruction itself is
    // typechecked against std.Build by compiling this file as a test target; this
    // pins the pure decisions it carries.
    try testing.expectEqualStrings("-sSTACK_SIZE=524288", wasm_stack_size_arg);
    try testing.expectEqualStrings("-sALLOW_MEMORY_GROWTH=1", wasm_allow_memory_growth_arg);
    try testing.expectEqualStrings("-sUSE_GLFW=3", wasm_use_glfw_arg);
    try testing.expectEqualStrings("-sASYNCIFY", wasm_asyncify_arg);
}

test "wasm link opt: default keeps the pre-#208 link args, in order" {
    const Case = struct { mode: std.builtin.OptimizeMode, want: []const []const u8 };
    const cases = [_]Case{
        .{ .mode = .Debug, .want = &.{ "-Og", "-sSAFE_HEAP=1", "-sSTACK_OVERFLOW_CHECK=1" } },
        .{ .mode = .ReleaseSafe, .want = &.{ "-sASSERTIONS=1", "-O3" } },
        .{ .mode = .ReleaseFast, .want = &.{ "-sASSERTIONS=0", "-O3" } },
        .{ .mode = .ReleaseSmall, .want = &.{ "-sASSERTIONS=0", "-Oz" } },
    };
    for (cases) |c| {
        const got = emccOptimizeArgs(c.mode, .default);
        try std.testing.expectEqualDeep(c.want, got.slice());
    }
}

test "wasm link opt: an explicit level changes only -O" {
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "-sASSERTIONS=1", "-O1" }), emccOptimizeArgs(.ReleaseSafe, .O1).slice());
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "-sASSERTIONS=0", "-O3" }), emccOptimizeArgs(.ReleaseSmall, .O3).slice());
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "-O1", "-sSAFE_HEAP=1", "-sSTACK_OVERFLOW_CHECK=1" }), emccOptimizeArgs(.Debug, .O1).slice());
}

test "wasm link opt: parse LABELLE_WASM_LINK_OPT" {
    try std.testing.expectEqual(WasmLinkOpt.default, try parseWasmLinkOpt(null));
    try std.testing.expectEqual(WasmLinkOpt.default, try parseWasmLinkOpt(" "));
    try std.testing.expectEqual(WasmLinkOpt.O1, try parseWasmLinkOpt("O1"));
    try std.testing.expectError(error.InvalidWasmLinkOpt, parseWasmLinkOpt("-O1"));
    try std.testing.expectError(error.InvalidWasmLinkOpt, parseWasmLinkOpt("o1"));
}
