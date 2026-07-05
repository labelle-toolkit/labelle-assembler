//! WASM manifest-v2 codegen (behavior-preserving split of `manifest_v2_splice.zig`,
//! PR 7, golden cell). wasm is the emcc residual (design §2 (c)). Unlike ios/android
//! it has NO `resolve_target`: its target is the STATIC `.triple`
//! "wasm32-emscripten" (design §3), resolved directly in the generated build.zig.
//! Its `post_wire` supplies residual (c) — the emcc `emLinkStep`, reconstructed
//! std-only in the hook — AND the install/run wiring (the enum `emcc_step` local
//! cannot escape a void hook to a packager footer). So the wasm v2 path does NOT
//! route packaging through `renderPackageV2(.web)`; post_wire owns it. The manifest
//! declares `.root_build_deps = emsdk`, which the assembler emits into the generated
//! build.zig.zon so the hook's `b.dependency("emsdk", .{})` resolves (design §3
//! `RootBuildDep`, review #459 finding 2). Like android/ios this is a GOLDEN cell
//! (§7): the residual moved into the imported hook and the unrolled core-diamond
//! overrides became the generic `unifyCoreDiamond` loop, so the text legitimately
//! DIFFERS from the enum
//! `header_wasm`/`backend_sokol_wasm`/`link_sokol_wasm`/`wasm_footer` path.

const std = @import("std");
const manifest_v2 = @import("../manifest_v2.zig");
const common = @import("common.zig");

const BackendManifestV2 = common.BackendManifestV2;
const ProjectConfig = common.ProjectConfig;
const hook_import_name = common.hook_import_name;

/// v2 wasm HEADER — replaces the enum `header_wasm` + `wasm_target` blocks.
/// Imports the backend hook and resolves the STATIC wasm32-emscripten target
/// inline (no `resolve_target` hook — the triple is fixed, design §3). The build
/// fn is `void` (not the enum `!void`): the emcc `try` moved into the hook's
/// `post_wire`, which panics on failure.
pub fn renderWasmHeaderV2(m: BackendManifestV2, w: anytype) !void {
    _ = m.platforms.wasm orelse return error.V2PlatformUnsupported;
    try w.print(
        \\const std = @import("std");
        \\
        \\const backend_build_hook = @import("{s}");
        \\
        \\pub fn build(b: *std.Build) void {{
        \\    const optimize = b.standardOptimizeOption(.{{}});
        \\
        \\    // WASM/Emscripten: a STATIC wasm32-emscripten target (design §3 — a
        \\    // fixed .triple, so NO resolve_target hook; the target resolves here).
        \\    const target = b.resolveTargetQuery(.{{
        \\        .cpu_arch = .wasm32,
        \\        .os_tag = .emscripten,
        \\    }});
        \\
        \\
    , .{hook_import_name});
}

/// v2 wasm core/gfx/engine dep decls — the declarative half of the enum `deps`
/// section, WITHOUT the unrolled `overrideImport` diamond + `unifyGfxSubpackageCore`
/// (those are replaced by the generic `unifyCoreDiamond` walk emitted after the
/// backend-dep section, design §5). Uses the plain `target` alias (wasm resolves
/// its target directly, like desktop).
pub fn renderWasmDepsDeclsV2(w: anytype) !void {
    try w.writeAll(
        \\    const core_dep = b.dependency("labelle_core", .{ .target = target, .optimize = optimize });
        \\    const core_mod = core_dep.module("labelle-core");
        \\
        \\    const gfx_dep = b.dependency("labelle_gfx", .{ .target = target, .optimize = optimize });
        \\    const gfx_mod = gfx_dep.module("labelle-gfx");
        \\
        \\    const engine_dep = b.dependency("engine", .{ .target = target, .optimize = optimize });
        \\    const engine_mod = engine_dep.module("engine");
        \\
        \\
    );
}

/// v2 wasm backend-dep — the generic `b.dependency` literal (`.target = target`) +
/// `.module(...)` decls (honoring `root_alias`) + `.artifact` decls. Then the
/// generic core-diamond walk CALLS (design §5) rooted at gfx/engine + each backend
/// module — replacing the enum `deps` unrolled overrides. The emcc residual is NOT
/// here; it is `post_wire`'s job (emitted in the link section).
pub fn renderWasmBackendDepV2(
    allocator: std.mem.Allocator,
    m: BackendManifestV2,
    cfg: ProjectConfig,
    w: anytype,
) !void {
    const wasm = m.platforms.wasm orelse return error.V2PlatformUnsupported;

    // GENERATED: `const backend_dep = b.dependency("<dep_name>", .{ .target =
    // target, .optimize = optimize, <merged dep_options> });` — wasm's empty
    // per-platform list inherits only the base `with_imgui` (design §3).
    const opts = try common.mergeDepOptions(allocator, m.dep_options, wasm.dep_options);
    defer allocator.free(opts);
    try w.print("    const backend_dep = b.dependency(\"{s}\", .{{ .target = target, .optimize = optimize", .{m.dep_name});
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

    // GENERATED: artifact decls (wasm has no `.pic`).
    for (wasm.artifacts) |art| {
        try w.print("    const {s} = backend_dep.artifact(\"{s}\");\n", .{ art.name, art.name });
        if (art.pic) try w.print("    {s}.root_module.pic = true;\n", .{art.name});
    }

    // GENERATED: the generic core+gfx-diamond walk CALLS (design §5).
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

/// v2 wasm LINK — the DECLARATIVE link graph (design §2: **D**): link each
/// platform artifact into the `wasm` lib — plus the `post_wire` hook CALL for the
/// residual (**H-post**, design §2 (c)): the emcc `emLinkStep` + install/run
/// wiring. The wasm root artifact is `wasm` (a static lib emcc links). NO
/// `resolve_target` (static triple); NO `renderPackageV2(.web)` (post_wire owns
/// packaging — see the section note).
pub fn renderWasmLinkV2(m: BackendManifestV2, cfg: ProjectConfig, w: anytype) !void {
    const wasm = m.platforms.wasm orelse return error.V2PlatformUnsupported;

    // GENERATED (D): link the platform artifact(s) into the wasm lib. emcc scans
    // the lib's transitive static deps, so this must run BEFORE post_wire.
    for (wasm.artifacts) |art| {
        try w.print("    wasm.root_module.linkLibrary({s});\n", .{art.name});
    }

    // GENERATED (H-post): the emcc residual (design §2 (c)) — delegated to the
    // backend hook's `post_wire`. wasm carries no SDK context (`ios_sdk_path` /
    // `android_target_sdk` are null); the hook resolves emsdk via
    // `b.dependency("emsdk", .{})`, declared by the manifest's `.root_build_deps`.
    try w.print(
        \\
        \\    // post_wire (design §4) — emcc link residual (c) + web install/run.
        \\    backend_build_hook.post_wire(b, .{{
        \\        .manifest_version = {d},
        \\        .backend_dep = backend_dep,
        \\        .root_module = wasm.root_module,
        \\        .root_artifact = wasm,
        \\        .target = target,
        \\        .optimize = optimize,
        \\        .platform = .wasm,
        \\        .ios_sdk_path = null,
        \\        .android_target_sdk = null,
        \\
    , .{manifest_v2.HOOK_ABI_VERSION});
    // Editor preview (labelle-studio Play mode): tell the hook's emcc arm to
    // keep the `editor_*` exports alive (-sEXPORTED_FUNCTIONS / _RUNTIME_
    // METHODS). Emitted ONLY on an editor-preview generation so a normal
    // build's post_wire call stays byte-identical AND keeps compiling against
    // older hooks whose HookContext predates the field (the field defaults to
    // false in the hook). A preview build against a too-old hook fails with a
    // "no field named 'editor_preview'" error naming this line — the intended
    // upgrade signal (labelle-bgfx >= 0.6.1).
    if (cfg.editor_preview) {
        try w.writeAll(
            \\        // Editor preview (labelle-studio Play mode): keep the `_editor_*`
            \\        // exports alive in the emcc link. Requires a backend hook whose
            \\        // HookContext declares `editor_preview` (labelle-bgfx >= 0.6.1).
            \\        .editor_preview = true,
            \\
        );
    }
    try w.writeAll(
        \\    });
        \\
    );
}

/// v2 wasm FOOTER — the build-fn close + the `overrideImport`/`unifyGfxSubpackageCore`
/// helper defs (byte-identical to the enum `wasm_footer`/`android_footer` tails),
/// WITHOUT the enum `wasm_footer`'s install/run block (post_wire owns install/run
/// on the wasm v2 path). The generic `unifyCoreDiamond` def is appended after this
/// by `emitCoreDiamondWalk`, exactly as on the android/ios paths.
pub fn renderWasmFooterV2(w: anytype) !void {
    try w.writeAll(wasm_footer_helpers);
}

// ──────────────────────────────────────────────────────────────────────────
// wasm v2 footer helpers (PR 7). The build-fn close + the `overrideImport` /
// `unifyGfxSubpackageCore` helper defs — byte-identical to the enum
// `wasm_footer`/`android_footer` tails, but WITHOUT the install/run block (the
// wasm v2 path's `post_wire` owns install/run; the enum `wasm_footer`'s
// `emcc_step` local cannot escape a void hook). Ends with a trailing blank line
// so the appended `emitCoreDiamondWalk` sits two blank lines below, matching the
// android/ios footer→walk spacing. The drift-guard test below locks this to the
// live `android_footer` section (its tail) so an edit to one representation but
// not the other fails loudly. Deleted with the enum sections in PR 12.
// ──────────────────────────────────────────────────────────────────────────
const wasm_footer_helpers =
    \\}
    \\
    \\/// Override a module import without leaking memory.
    \\/// NOTE: Duplicated from .footer — each generated build.zig is standalone and
    \\/// needs its own copy of this helper.
    \\fn overrideImport(m: *std.Build.Module, name: []const u8, module: *std.Build.Module) void {
    \\    const gop = m.import_table.getOrPut(m.owner.allocator, name) catch @panic("OOM");
    \\    if (!gop.found_existing) {
    \\        gop.key_ptr.* = name;
    \\    }
    \\    gop.value_ptr.* = module;
    \\}
    \\
    \\/// Unify `labelle-core` onto gfx's sub-packages (`camera`, `spatial_grid`,
    \\/// `tilemap`) so a `core.YAxis` (and any other core type) produced inside the
    \\/// `labelle-gfx` module unifies with the type the sub-package expects. gfx#276
    \\/// crosses this boundary by passing the project `y_axis` into
    \\/// `camera.CameraWith(...)`. Only override sub-packages that actually import
    \\/// core (a no-op otherwise — keeps this resilient if gfx restructures).
    \\fn unifyGfxSubpackageCore(gfx_mod: *std.Build.Module, core_mod: *std.Build.Module) void {
    \\    const sub_names = [_][]const u8{ "camera", "spatial_grid", "tilemap" };
    \\    for (sub_names) |sub_name| {
    \\        const sub = gfx_mod.import_table.get(sub_name) orelse continue;
    \\        if (sub.import_table.get("labelle-core") != null) {
    \\            overrideImport(sub, "labelle-core", core_mod);
    \\        }
    \\    }
    \\}
    \\
    \\
;

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "wasm_footer_helpers is the android_footer tail (drift guard)" {
    // The wasm v2 footer reuses the enum footer's build-fn close + helper defs but
    // drops the install/run block (post_wire owns install/run on wasm). Lock it to
    // the live `android_footer` section tail so an edit to one representation but
    // not the other fails loudly.
    const tpl = @import("../../template.zig");
    const build_zig_tmpl = @embedFile("../../templates/build_zig.txt");
    const android_footer = tpl.getSection(build_zig_tmpl, "android_footer").?;
    // Everything from the build-fn-closing `}` (col 0) onward is the shared tail.
    const close = std.mem.indexOf(u8, android_footer, "\n}\n").?;
    try testing.expectEqualStrings(android_footer[close + 1 ..], wasm_footer_helpers);
}
