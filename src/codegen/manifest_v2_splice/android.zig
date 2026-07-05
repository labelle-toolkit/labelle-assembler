//! ANDROID manifest-v2 codegen (behavior-preserving split of
//! `manifest_v2_splice.zig`, PR 5, golden cell). Android is the first
//! HOOK-BEARING conversion: `resolve_target` picks the ABI before any
//! `b.dependency` and `post_wire` supplies the NDK-sysroot / addLibraryPath /
//! libc.txt residual (design §4). The generated build.zig `@import`s the backend
//! hook as a sibling `backend_build_hook.zig` and calls both phases. Unlike the
//! desktop byte anchor, this is a GOLDEN cell (§7): the generated text
//! legitimately DIFFERS from the enum
//! `header_android`/`android_deps`/`backend_sokol_android`/`android_link` path —
//! the residual moved into the imported hook and the unrolled core-diamond
//! overrides became the generic `unifyCoreDiamond` loop. See docs §7 for why the
//! text golden alone is blind to the hook body (hence the hook's own gates).

const std = @import("std");
const manifest_v2 = @import("../manifest_v2.zig");
const common = @import("common.zig");

const BackendManifestV2 = common.BackendManifestV2;
const ProjectConfig = common.ProjectConfig;
const hook_import_name = common.hook_import_name;

/// v2 android HEADER — replaces the enum `header_android` block. Instead of
/// inlining `getAndroidNdkSysroot`/`ndkHostTag` + the target-resolution block, it
/// imports the backend hook and resolves the android target via `resolve_target`
/// (design §4, runs BEFORE any `b.dependency`). The NDK sysroot is detected later,
/// inside `post_wire`.
pub fn renderAndroidHeaderV2(m: BackendManifestV2, w: anytype) !void {
    _ = m.platforms.android orelse return error.V2PlatformUnsupported;
    try w.print(
        \\const std = @import("std");
        \\
        \\const backend_build_hook = @import("{s}");
        \\
        \\pub fn build(b: *std.Build) void {{
        \\    const optimize = b.standardOptimizeOption(.{{}});
        \\
        \\    // resolve_target (design §4) — the backend hook picks the android ABI
        \\    // from -Demulator/-Dandroid_arch + host arch, BEFORE any b.dependency.
        \\    const android_target = backend_build_hook.resolve_target(b, .{{ .platform = .android }}).target;
        \\
        \\
    , .{hook_import_name});
}

/// v2 android core/gfx/engine dep decls — the declarative half of the enum
/// `android_deps` section, WITHOUT the unrolled `overrideImport` diamond +
/// `unifyGfxSubpackageCore` (those are replaced by the generic `unifyCoreDiamond`
/// walk emitted after the backend-dep section, design §5).
pub fn renderAndroidDepsDeclsV2(w: anytype) !void {
    try w.writeAll(
        \\    const core_dep = b.dependency("labelle_core", .{ .target = android_target, .optimize = optimize });
        \\    const core_mod = core_dep.module("labelle-core");
        \\
        \\    const gfx_dep = b.dependency("labelle_gfx", .{ .target = android_target, .optimize = optimize });
        \\    const gfx_mod = gfx_dep.module("labelle-gfx");
        \\
        \\    const engine_dep = b.dependency("engine", .{ .target = android_target, .optimize = optimize });
        \\    const engine_mod = engine_dep.module("engine");
        \\
        \\
    );
}

/// v2 android backend-dep — the generic `b.dependency` literal (`.target =
/// android_target`) + `.module(...)` decls (honoring `root_alias`) + `.artifact`
/// decls (with declarative `.pic`). Then the generic core-diamond walk CALLS
/// (design §5) rooted at gfx/engine + each backend module — replacing the enum
/// `android_deps` unrolled overrides. The NDK `addSystemIncludePath` residual is
/// NOT here; it is `post_wire`'s job (emitted in the link section).
pub fn renderAndroidBackendDepV2(
    allocator: std.mem.Allocator,
    m: BackendManifestV2,
    cfg: ProjectConfig,
    w: anytype,
) !void {
    const android = m.platforms.android orelse return error.V2PlatformUnsupported;

    // GENERATED: `const backend_dep = b.dependency("<dep_name>", .{ .target =
    // android_target, .optimize = optimize, <merged dep_options> });`
    const opts = try common.mergeDepOptions(allocator, m.dep_options, android.dep_options);
    defer allocator.free(opts);
    try w.print("    const backend_dep = b.dependency(\"{s}\", .{{ .target = android_target, .optimize = optimize", .{m.dep_name});
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

    // GENERATED: platform-only EXTRA module decls under their root alias (design §3
    // `PlatformEntry.extra_modules`). bgfx-Android's NativeActivity shell
    // `android_app` is pulled as `backend_dep.module("android_app")` and published
    // to the generated root under the alias `backend_app` (its declared
    // `root_alias`) — the generated `main.zig` imports it as `@import("backend_app")`
    // (enum `backend_bgfx_android` :799 / `android_exe_app_import` :871). The default
    // `backend_<name>` alias would be `backend_android_app` and break that import, so
    // the manifest declares the explicit alias (design §3 review-correction #3).
    // sokol android has no extra modules, so this is a no-op there.
    for (android.extra_modules) |mod| {
        const alias = try common.moduleAlias(allocator, mod);
        defer allocator.free(alias);
        try w.print("    const {s} = backend_dep.module(\"{s}\");\n", .{ alias, mod.name });
    }

    // GENERATED: artifact decls + declarative `.pic` (design §2 note 1).
    for (android.artifacts) |art| {
        try w.print("    const {s} = backend_dep.artifact(\"{s}\");\n", .{ art.name, art.name });
        if (art.pic) try w.print("    {s}.root_module.pic = true;\n", .{art.name});
    }

    // GENERATED: the generic core+gfx-diamond walk CALLS (design §5). Rooted at
    // gfx/engine (the fixed diamond) + each backend module (a no-op for sokol
    // android, whose modules do not import core — but design-faithful and
    // resilient). For bgfx-Android the walk over `backend_input` covers the direct
    // `labelle-core` import (the #310 vtable override) generically, and the walk
    // over `backend_app` covers the NativeActivity shell. Replaces the enum
    // `android_deps` unrolled overrides + `unifyGfxSubpackageCore`. The
    // `unifyCoreDiamond` def itself is emitted as a top-level helper after the build
    // fn (see `emitCoreDiamondWalk`).
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
    // The platform-only extra modules are walked too (design §5 lists android_app
    // among the walked providers).
    for (android.extra_modules) |mod| {
        const alias = try common.moduleAlias(allocator, mod);
        defer allocator.free(alias);
        try w.print("    unifyCoreDiamond(b.allocator, {s}, core_mod, gfx_mod, &core_diamond_visited);\n", .{alias});
    }
}

/// v2 android LINK — the DECLARATIVE link graph (design §2: **D**): link each
/// platform artifact, `link_libc`, and each `.system_libs.android` entry — plus
/// the `post_wire` hook CALL for the residual (**H-post**): NDK sysroot include
/// paths, `addLibraryPath(usr/lib/<triple>/<api>)`, and libc.txt. The android root
/// artifact is `lib` (a dynamic library), not `exe`.
pub fn renderAndroidLinkV2(m: BackendManifestV2, cfg: ProjectConfig, w: anytype) !void {
    const android = m.platforms.android orelse return error.V2PlatformUnsupported;

    // GENERATED (D): link the platform artifact(s) into the .so.
    for (android.artifacts) |art| {
        try w.print("    lib.root_module.linkLibrary({s});\n", .{art.name});
    }
    // GENERATED (D): libc for the NDK build.
    if (android.link_libc) try w.writeAll("    lib.root_module.link_libc = true;\n");
    // GENERATED (D): the Android NDK system libs (`.system_libs.android`).
    for (m.system_libs.android) |lib_name| {
        try w.print("    lib.root_module.linkSystemLibrary(\"{s}\", .{{}});\n", .{lib_name});
    }

    // GENERATED (H-post): the residual the manifest cannot express statically —
    // NDK sysroot include/lib paths + libc.txt — delegated to the backend hook's
    // `post_wire` (design §4). `android_target_sdk` is REQUIRED (never a silent 34
    // default): it comes from `cfg.android.target_sdk_version`, which always has a
    // concrete value, and the hook PANICS on null.
    const android_sdk: u32 = if (cfg.android) |a| a.target_sdk_version else 34;
    try w.print(
        \\
        \\    // post_wire (design §4) — NDK sysroot include/lib paths + libc.txt.
        \\    backend_build_hook.post_wire(b, .{{
        \\        .manifest_version = {d},
        \\        .backend_dep = backend_dep,
        \\        .root_module = lib.root_module,
        \\        .root_artifact = lib,
        \\        .target = android_target,
        \\        .optimize = optimize,
        \\        .platform = .android,
        \\        .ios_sdk_path = null,
        \\        .android_target_sdk = {d},
        \\    }});
        \\
    , .{ manifest_v2.HOOK_ABI_VERSION, android_sdk });
}
