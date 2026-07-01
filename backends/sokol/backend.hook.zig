//! sokol backend build hook (manifest-v2, epic #453 item 3) — the DEDICATED
//! hook file the v2 manifest points at via `.build_hook = "backend.hook.zig"`
//! (design §3/§4). It is NOT sokol's own `build.zig`: that file re-exports
//! `pub const emLinkStep = @import("sokol").emLinkStep;` at top level, and
//! `"sokol"` is a name resolvable only inside the labelle_sokol package build
//! context — absent from the generated ROOT package the assembler imports the
//! hook into. So the hook makes NO package-local import assumptions: it may
//! `@import("std")` and take everything else through the hook context.
//!
//! ## PR 3 scope
//!
//! DESKTOP has no residual: it is fully declarative (modules/artifacts/frameworks
//! come from the manifest) and `.target = .native` resolves without a hook, so the
//! assembler NEVER invokes this hook on a desktop build. `post_wire(.desktop)` is
//! therefore empty. The android/ios/wasm arms are stubs here; their residual
//! (NDK sysroot + libc.txt, iOS xcrun SDK consume, emcc emLinkStep) lands in
//! PRs 5/6/7 alongside the shared packager. Until then this hook is inert for the
//! only platform PR 3 wires (desktop).

const std = @import("std");

/// Versioned with the hook ABI (design §4). Asserted `== HOOK_ABI_VERSION` by the
/// assembler before the hook is ever called; matches
/// `manifest_v2.HOOK_ABI_VERSION`.
pub const HOOK_ABI_VERSION: u8 = 2;

/// The platform tag the hook branches on. Mirrors `config.Platform` structurally
/// so the hook needs no assembler import.
pub const Platform = enum { desktop, ios, android, wasm };

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

/// Runs AFTER generic module/artifact/system-lib/framework wiring, to supplement
/// the graph with the residual the manifest cannot express statically. DESKTOP is
/// empty (no residual). The other arms are PR-5/6/7 stubs.
pub fn post_wire(b: *std.Build, ctx: HookContext) void {
    switch (ctx.platform) {
        // Fully declarative — no residual. This is the only arm PR 3 exercises,
        // and the assembler does not even call the hook for it.
        .desktop => {},
        // PR 5: NDK sysroot detection + addLibraryPath(.../<triple>/<api>) +
        // setLibCFile(libc.txt) using ctx.android_target_sdk (which must be
        // populated — panic on null rather than a silent `orelse 34`).
        .android => {},
        // PR 6: configureSdkPaths / addExeSdkPaths consuming ctx.ios_sdk_path.
        .ios => {},
        // PR 7: emccStep / emLinkStep on ctx.root_artifact (needs the emsdk root
        // dep declared via .platforms.wasm.root_build_deps).
        .wasm => {},
    }
    _ = b;
}
