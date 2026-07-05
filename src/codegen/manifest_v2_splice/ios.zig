//! IOS manifest-v2 codegen (behavior-preserving split of `manifest_v2_splice.zig`,
//! PR 6, golden cell). iOS is the second HOOK-BEARING conversion (design §8). Its
//! `resolve_target` is DISTINCT from android's: besides the `ResolvedTarget` it
//! also runs `xcrun` SDK discovery and returns the SDK PATH, because plugin
//! `b.dependency` calls consume it (`build_files.zig:341`) and it therefore must
//! be resolved BEFORE any dependency (design §4 review-correction #6). `post_wire`
//! then consumes that SDK path (residual (b): `configureSdkPaths` /
//! `addExeSdkPaths`); the iOS frameworks + `link_libc` are DECLARATIVE
//! (`.frameworks.ios`), emitted here. Like android this is a GOLDEN cell (§7): the
//! residual moved into the hook and the unrolled core-diamond overrides became the
//! generic `unifyCoreDiamond` loop, so the text legitimately DIFFERS from the enum
//! `header_ios`/`ios_deps`/`backend_sokol_ios`/`ios_link` path.

const std = @import("std");
const manifest_v2 = @import("../manifest_v2.zig");
const common = @import("common.zig");

const BackendManifestV2 = common.BackendManifestV2;
const ProjectConfig = common.ProjectConfig;
const hook_import_name = common.hook_import_name;

/// v2 ios HEADER — replaces the enum `header_ios` block. Instead of inlining
/// `getIosSdkPath`/`configureSdkPaths`/`addExeSdkPaths`/`linkIosFrameworks` + the
/// device/simulator target block, it imports the backend hook and resolves BOTH
/// the ios target AND the SDK path via `resolve_target` (design §4, runs BEFORE
/// any `b.dependency`). `sdk_path` is captured at the build-fn top because the
/// plugin dep loop threads it into each plugin `b.dependency` call, and the
/// `post_wire` context consumes it for the SDK include/lib/framework paths.
pub fn renderIosHeaderV2(m: BackendManifestV2, w: anytype) !void {
    _ = m.platforms.ios orelse return error.V2PlatformUnsupported;
    try w.print(
        \\const std = @import("std");
        \\
        \\const backend_build_hook = @import("{s}");
        \\
        \\pub fn build(b: *std.Build) void {{
        \\    const optimize = b.standardOptimizeOption(.{{}});
        \\
        \\    // resolve_target (design §4) — the backend hook runs xcrun SDK discovery
        \\    // + device/simulator selection, producing BOTH the ios target and the
        \\    // SDK path plugin b.dependency calls consume, BEFORE any b.dependency.
        \\    const ios_resolved = backend_build_hook.resolve_target(b, .{{ .platform = .ios }});
        \\    const ios_target = ios_resolved.target;
        \\    const sdk_path = ios_resolved.ios_sdk_path.?;
        \\
        \\
    , .{hook_import_name});
}

/// v2 ios core/gfx/engine dep decls — the declarative half of the enum `ios_deps`
/// section, WITHOUT the unrolled `overrideImport` diamond + `unifyGfxSubpackageCore`
/// (those are replaced by the generic `unifyCoreDiamond` walk emitted after the
/// backend-dep section, design §5).
pub fn renderIosDepsDeclsV2(w: anytype) !void {
    try w.writeAll(
        \\    const core_dep = b.dependency("labelle_core", .{ .target = ios_target, .optimize = optimize });
        \\    const core_mod = core_dep.module("labelle-core");
        \\
        \\    const gfx_dep = b.dependency("labelle_gfx", .{ .target = ios_target, .optimize = optimize });
        \\    const gfx_mod = gfx_dep.module("labelle-gfx");
        \\
        \\    const engine_dep = b.dependency("engine", .{ .target = ios_target, .optimize = optimize });
        \\    const engine_mod = engine_dep.module("engine");
        \\
        \\
    );
}

/// v2 ios backend-dep — the generic `b.dependency` literal (`.target = ios_target`)
/// + `.module(...)` decls (honoring `root_alias`) + `.artifact` decls. Then the
/// generic core-diamond walk CALLS (design §5) rooted at gfx/engine + each backend
/// module — replacing the enum `ios_deps` unrolled overrides. The SDK-path
/// `configureSdkPaths(sokol_clib, sdk_path)` the enum path calls here is NOT
/// emitted; it is `post_wire`'s job (emitted in the link section).
pub fn renderIosBackendDepV2(
    allocator: std.mem.Allocator,
    m: BackendManifestV2,
    cfg: ProjectConfig,
    w: anytype,
) !void {
    const ios = m.platforms.ios orelse return error.V2PlatformUnsupported;

    // GENERATED: `const backend_dep = b.dependency("<dep_name>", .{ .target =
    // ios_target, .optimize = optimize, <merged dep_options> });`
    const opts = try common.mergeDepOptions(allocator, m.dep_options, ios.dep_options);
    defer allocator.free(opts);
    try w.print("    const backend_dep = b.dependency(\"{s}\", .{{ .target = ios_target, .optimize = optimize", .{m.dep_name});
    for (opts) |opt| {
        try w.print(", .{s} = {s}", .{ opt.name, common.depOptionValue(opt.value, cfg) });
    }
    try w.writeAll(" });\n");

    // GENERATED: provider module decls under their root alias.
    for (m.modules) |mod| {
        const alias = try common.moduleAlias(allocator, mod);
        defer allocator.free(alias);
        try w.print("    const {s} = backend_dep.module(\"{s}\");\n", .{ alias, mod.name });
    }

    // GENERATED: artifact decls + declarative `.pic` (ios has none; design §2 note 1).
    for (ios.artifacts) |art| {
        try w.print("    const {s} = backend_dep.artifact(\"{s}\");\n", .{ art.name, art.name });
        if (art.pic) try w.print("    {s}.root_module.pic = true;\n", .{art.name});
    }

    // GENERATED: the generic core+gfx-diamond walk CALLS (design §5) — the loop
    // form of the per-site overrideImport diamond, replacing the enum `ios_deps`
    // unrolled overrides + `unifyGfxSubpackageCore`. The `unifyCoreDiamond` def is
    // emitted as a top-level helper after the build fn (see `emitCoreDiamondWalk`).
    try w.writeAll(
        \\
        \\    // Generic core+gfx-diamond unification (design §5) — the loop form of
        \\    // the per-site overrideImport diamond (golden cell, not the desktop
        \\    // byte-anchor's unrolled form). Rooted at each imported provider.
        \\    var core_diamond_visited: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
        \\    unifyCoreDiamond(b.allocator, gfx_mod, core_mod, gfx_mod, &core_diamond_visited);
        \\    unifyCoreDiamond(b.allocator, engine_mod, core_mod, gfx_mod, &core_diamond_visited);
        \\
    );
    for (m.modules) |mod| {
        const alias = try common.moduleAlias(allocator, mod);
        defer allocator.free(alias);
        try w.print("    unifyCoreDiamond(b.allocator, {s}, core_mod, gfx_mod, &core_diamond_visited);\n", .{alias});
    }
}

/// v2 ios LINK — the DECLARATIVE link graph (design §2: **D**): link each platform
/// artifact, `link_libc`, and each `.frameworks.ios` entry → `linkFramework` — plus
/// the `post_wire` hook CALL for the residual (**H-post**): the SDK include/lib/
/// framework paths (`configureSdkPaths`/`addExeSdkPaths`) that consume the SDK path
/// resolved in `resolve_target`. The ios root artifact is `exe` (an executable).
pub fn renderIosLinkV2(m: BackendManifestV2, w: anytype) !void {
    const ios = m.platforms.ios orelse return error.V2PlatformUnsupported;

    // GENERATED (D): link the platform artifact(s) into the exe.
    for (ios.artifacts) |art| {
        try w.print("    exe.root_module.linkLibrary({s});\n", .{art.name});
    }
    // GENERATED (D): libc for the ios build (`ios_link:582`).
    if (ios.link_libc) try w.writeAll("    exe.root_module.link_libc = true;\n");
    // GENERATED (D): the ios system frameworks (`.frameworks.ios`) — replaces the
    // enum `linkIosFrameworks` helper call.
    for (m.frameworks.ios) |fw| {
        try w.print("    exe.root_module.linkFramework(\"{s}\", .{{}});\n", .{fw});
    }

    // GENERATED (H-post): the residual the manifest cannot express statically —
    // the SDK include/lib/framework paths — delegated to the backend hook's
    // `post_wire` (design §4). `ios_sdk_path` is REQUIRED (resolved in
    // `resolve_target`); `android_target_sdk` is null on ios.
    try w.print(
        \\
        \\    // post_wire (design §4) — iOS SDK include/lib/framework paths.
        \\    backend_build_hook.post_wire(b, .{{
        \\        .manifest_version = {d},
        \\        .backend_dep = backend_dep,
        \\        .root_module = exe.root_module,
        \\        .root_artifact = exe,
        \\        .target = ios_target,
        \\        .optimize = optimize,
        \\        .platform = .ios,
        \\        .ios_sdk_path = sdk_path,
        \\        .android_target_sdk = null,
        \\    }});
        \\
    , .{manifest_v2.HOOK_ABI_VERSION});
}
