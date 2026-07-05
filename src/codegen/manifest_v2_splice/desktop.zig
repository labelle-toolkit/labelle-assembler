//! DESKTOP manifest-v2 codegen (behavior-preserving split of
//! `manifest_v2_splice.zig`). Desktop has TWO shapes: the sokol BYTE-ANCHOR form
//! (`renderDesktopBackendDepV2`/`renderDesktopLinkV2`, unrolled sokol residual so
//! it hits 0-diff against the enum/v1 path — see the byte-anchor constants at the
//! tail) vs the fully-declarative GENERIC path
//! (`renderDesktopBackendDepGenericV2`/`renderDesktopLinkGenericV2`, loop-form
//! walk, golden cells like null/wgpu). The dispatcher in `dispatch.zig` picks
//! between them via `common.isDesktopByteAnchor`.

const std = @import("std");
const config = @import("../../config.zig");
const common = @import("common.zig");

const BackendManifestV2 = common.BackendManifestV2;
const ProjectConfig = common.ProjectConfig;

/// v2 GENERIC desktop core/gfx/engine dep decls (design §7 golden path) — the
/// declarative half of the enum `deps` section, WITHOUT the unrolled
/// `overrideImport` diamond + `unifyGfxSubpackageCore` (those are replaced by the
/// generic `unifyCoreDiamond` walk emitted after the backend-dep section, §5).
/// Uses the plain `target` alias the desktop `header` declares.
pub fn renderDesktopDepsDeclsV2(w: anytype) !void {
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

/// v2 GENERIC desktop backend-dep (design §7 golden path, e.g. null/wgpu, PR 8) —
/// the generic `b.dependency` literal (`.target = target`) + `.module(...)` decls
/// (honoring `root_alias`) + `.artifact` decls, then the generic core-diamond walk
/// CALLS (§5) rooted at gfx/engine + each backend module. This is the desktop
/// analogue of the android/ios/wasm generic backend-dep emitters — fully
/// declarative, NO backend-specific prose and NO hardcoded `overrideImport`
/// `if`-blocks (that is the sokol byte-anchor path only, `renderDesktopBackendDepV2`).
pub fn renderDesktopBackendDepGenericV2(
    allocator: std.mem.Allocator,
    m: BackendManifestV2,
    cfg: ProjectConfig,
    w: anytype,
) !void {
    const desktop = m.platforms.desktop orelse return error.V2PlatformUnsupported;

    // GENERATED: `const backend_dep = b.dependency("<dep_name>", .{ .target =
    // target, .optimize = optimize, <merged dep_options> });`
    const opts = try common.mergeDepOptions(allocator, m.dep_options, desktop.dep_options);
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

    // GENERATED: artifact decls for this platform (the var name is the SANITIZED
    // artifact name — the raw name stays inside the `artifact("...")` string).
    // null has none; wgpu has `glfw`. See `artifactIdent` (review #469 f1+2).
    for (desktop.artifacts) |art| {
        var ident_buf: [128]u8 = undefined;
        const ident = common.artifactIdent(art.name, &ident_buf);
        try w.print("    const {s} = backend_dep.artifact(\"{s}\");\n", .{ ident, art.name });
        if (art.pic) try w.print("    {s}.root_module.pic = true;\n", .{ident});
    }

    // GENERATED: the generic core+gfx-diamond walk CALLS (design §5) — the loop
    // form of the per-site overrideImport diamond, replacing the enum `deps`
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

/// DESKTOP backend-dep (PR 3 byte anchor). Generated from the manifest: the
/// `b.dependency` literal (dep name + merged `dep_options`), the `.module(...)`
/// decls (honoring `root_alias`), and the `.artifact(...)` decls. The surrounding
/// prose + unrolled core-diamond overrides are the anchor residual (module doc).
pub fn renderDesktopBackendDepV2(
    allocator: std.mem.Allocator,
    m: BackendManifestV2,
    cfg: ProjectConfig,
    w: anytype,
) !void {
    const desktop = m.platforms.desktop orelse return error.V2PlatformUnsupported;

    // HEAD: backend-specific provenance prose (not declarative). Anchor residual.
    try w.writeAll(anchor_head_comment);
    try w.writeByte('\n');

    // GENERATED: `const backend_dep = b.dependency("<dep_name>", .{ .target =
    // target, .optimize = optimize, <merged dep_options> });`
    const opts = try common.mergeDepOptions(allocator, m.dep_options, desktop.dep_options);
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

    // GENERATED: artifact decls for this platform (the var name IS the artifact
    // name, matching the enum path: `const sokol_clib = backend_dep.artifact(...)`).
    for (desktop.artifacts) |art| {
        try w.print("    const {s} = backend_dep.artifact(\"{s}\");\n", .{ art.name, art.name });
    }

    // TAIL: the two unrolled core-diamond `overrideImport` `if`-blocks + prose.
    // Anchor residual — §7 "unrolling the walk's output for the desktop case".
    try w.writeAll(anchor_tail_overrides);
}

/// v2 GENERIC desktop link (design §7 golden path, e.g. null/wgpu, PR 8) — the
/// fully DECLARATIVE link graph (design §2 **D**): link each platform artifact,
/// `link_libc` if set, and the per-OS `.system_libs.desktop`/`.frameworks.desktop`
/// entries as a `switch (target.result.os.tag)` block. NO `post_wire` (hookless),
/// NO backend-specific prose (that is the sokol byte-anchor path only). null emits
/// nothing (no artifact, no frameworks); wgpu links `glfw` + the macOS Metal/
/// Foundation/QuartzCore frameworks.
pub fn renderDesktopLinkGenericV2(m: BackendManifestV2, w: anytype) !void {
    try emitDesktopLinkForTarget(m, w, "exe");
}

/// v2 GENERIC desktop link mirrored onto `test_root` (review #469, coderabbit).
/// `test_root` imports the backend modules (backend_gfx/input/audio/window), so a
/// wgpu-backed project's `zig build test` links against symbols in `glfw` + the
/// macOS Metal/Foundation/QuartzCore frameworks. The exe-only link left `test_root`
/// unresolved → link failure. The enum path already links only `exe`; the generic
/// desktop path attaches the SAME native linkage to `test_root` too. Emitted AFTER
/// the test step declares `test_root` (see `build_files.zig`). null has no artifact
/// and no frameworks, so this emits nothing for the null backend.
pub fn renderDesktopTestLinkGenericV2(m: BackendManifestV2, w: anytype) !void {
    try emitDesktopLinkForTarget(m, w, "test_root");
}

/// Emit the generic desktop native linkage (artifact `linkLibrary` + optional
/// `link_libc` + the per-OS system-lib/framework switch) onto a given target
/// module variable (`exe` or `test_root`). Factored out so the exe and the test
/// root receive byte-identical linkage.
fn emitDesktopLinkForTarget(m: BackendManifestV2, w: anytype, target_var: []const u8) !void {
    const desktop = m.platforms.desktop orelse return error.V2PlatformUnsupported;

    // GENERATED (D): link each platform artifact (var name is the SANITIZED
    // ident, matching the decl site — review #469 findings 1+2).
    for (desktop.artifacts) |art| {
        var ident_buf: [128]u8 = undefined;
        const ident = common.artifactIdent(art.name, &ident_buf);
        try w.print("    {s}.root_module.linkLibrary({s});\n", .{ target_var, ident });
    }
    // GENERATED (D): libc, if the platform entry requests it (desktop usually not).
    if (desktop.link_libc) try w.print("    {s}.root_module.link_libc = true;\n", .{target_var});

    // GENERATED (D): the per-OS system-lib/framework switch (`.system_libs.desktop`
    // + `.frameworks.desktop`) — replaces the enum `switch (target.result.os.tag)`
    // block. Emitted only when at least one OS has an entry (null → nothing).
    try emitDesktopOsLinks(m, w, target_var);
}

/// Emit the desktop per-OS `switch (target.result.os.tag)` link block from
/// `.system_libs.desktop` (`linkSystemLibrary`) + `.frameworks.desktop`
/// (`linkFramework`). An OS arm is emitted only when that OS has ≥1 entry; the
/// whole switch is omitted when every OS is empty (design §2 note 2: per-OS gating
/// is declarative). Order: system libs before frameworks, macos → linux → windows,
/// then `else => {}`.
fn emitDesktopOsLinks(m: BackendManifestV2, w: anytype, target_var: []const u8) !void {
    const sl = m.system_libs.desktop;
    const fw = m.frameworks.desktop;
    const any = sl.macos.len + sl.linux.len + sl.windows.len +
        fw.macos.len + fw.linux.len + fw.windows.len > 0;
    if (!any) return;

    try w.writeAll("\n    switch (target.result.os.tag) {\n");
    try emitDesktopOsArm(w, target_var, "macos", sl.macos, fw.macos);
    try emitDesktopOsArm(w, target_var, "linux", sl.linux, fw.linux);
    try emitDesktopOsArm(w, target_var, "windows", sl.windows, fw.windows);
    try w.writeAll("        else => {},\n    }\n");
}

fn emitDesktopOsArm(
    w: anytype,
    target_var: []const u8,
    os_tag: []const u8,
    libs: []const []const u8,
    fws: []const []const u8,
) !void {
    if (libs.len == 0 and fws.len == 0) return;
    try w.print("        .{s} => {{\n", .{os_tag});
    for (libs) |lib_name| {
        try w.print("            {s}.root_module.linkSystemLibrary(\"{s}\", .{{}});\n", .{ target_var, lib_name });
    }
    for (fws) |fw_name| {
        try w.print("            {s}.root_module.linkFramework(\"{s}\", .{{}});\n", .{ target_var, fw_name });
    }
    try w.writeAll("        },\n");
}

/// DESKTOP link (PR 3 byte anchor). Generated from the manifest: the
/// `linkLibrary(<artifact>)` line(s). The per-OS framework switch + its prose is
/// anchor residual (its `.macos, .ios =>` combined arm + libudev NOTE are
/// idiosyncratic formatting, not declarative graph data).
pub fn renderDesktopLinkV2(m: BackendManifestV2, w: anytype) !void {
    const desktop = m.platforms.desktop orelse return error.V2PlatformUnsupported;

    // GENERATED: link each platform artifact.
    for (desktop.artifacts) |art| {
        try w.print("    exe.root_module.linkLibrary({s});\n", .{art.name});
    }

    // Anchor residual: the framework switch (from `.frameworks.desktop`) + prose.
    try w.writeAll(anchor_link_body);
}

// ──────────────────────────────────────────────────────────────────────────
// sokol-desktop byte-anchor VERBATIM RESIDUAL (§7).
//
// The non-declarative text the v2 model does not carry, reproduced byte-exactly
// from `backends/sokol/build_fragments/{backend_dep,link}.txt` so the desktop
// anchor hits 0-diff against the enum/v1 path. This is the desktop "unroll" of the
// core-diamond walk + the backend-specific prose; it is deleted with the enum
// path + v1 fragments in PR 12, at which point the desktop cell becomes a golden
// snapshot like every other. See the module doc for why the generic walk is NOT
// spliced on this path.
// ──────────────────────────────────────────────────────────────────────────

const anchor_head_comment =
    "    // `with_imgui` flips sokol_imgui.c compilation on. MUST match the\n    // imgui bridge's option set when the project includes imgui, or\n    // Zig caches two `sokol_clib` artifacts (and two `_sg` states) —\n    // see comment in `backends/sokol/build.zig` (labelle-assembler#140).";

const anchor_tail_overrides =
    "\n    // Unify the app core onto the transitive `sdl_gamepad` desktop gamepad\n    // source — same diamond as `.backend_raylib` (see the note there). The\n    // sokol `input` module reaches `GamepadEvent` through `sdl_gamepad`\n    // (imported under the `labelle_core` underscore key) rather than a direct\n    // core import, so the override target is the sdl_gamepad module, not\n    // `input`. `if` guard: only desktop sokol wires sdl_gamepad in (Android/iOS\n    // use their own gamepad paths; wasm has none). See labelle-assembler#271.\n    if (backend_input.import_table.get(\"sdl_gamepad\")) |sdl_gp_mod| {\n        overrideImport(sdl_gp_mod, \"labelle_core\", core_mod);\n    }\n\n    // Linux desktop core gamepad route (core#33 scope 2): there the sokol\n    // backend wires a DIRECT `labelle-core` import on `input` (reaching the\n    // udev/evdev gamepad source) instead of `sdl_gamepad`. Unify the app\n    // core onto it so gamepad state/event types match the engine's. `if`\n    // guard: the import only exists on Linux desktop builds — adding the\n    // override unconditionally would inject a dead import elsewhere (#258).\n    if (backend_input.import_table.get(\"labelle-core\")) |_| {\n        overrideImport(backend_input, \"labelle-core\", core_mod);\n    }\n\n";

const anchor_link_body =
    "\n    // IOSurface + CoreFoundation are needed for the macOS preview-mode\n    // IOSurface producer (labelle-assembler#121 + #125, labelle-\n    // engine#547). The engine references `IOSurfaceCreate`,\n    // `IOSurfaceLock`, `CFNumberCreate`, etc. via `@extern \"c\"` —\n    // these symbols live in IOSurface.framework + CoreFoundation\n    // .framework, and sokol's upstream linker line does not propagate\n    // them. Same on iOS (the framework path is identical). Linux /\n    // Windows / web have no macOS-specific symbols to resolve here,\n    // so the framework links are gated on the Darwin target tags.\n    switch (target.result.os.tag) {\n        .macos, .ios => {\n            exe.root_module.linkFramework(\"IOSurface\", .{});\n            exe.root_module.linkFramework(\"CoreFoundation\", .{});\n        },\n        // NOTE: labelle-core's Linux gamepad-detection source\n        // (gamepad_source/linux.zig, labelle-assembler#249) does NOT need a\n        // build-time libudev link. As of labelle-core#20 it loads libudev at\n        // RUNTIME via std.DynLib (dlopen of `libudev.so.1`) and degrades\n        // gracefully when the library is absent — so the generated build must\n        // not link `-ludev`, which would reintroduce a hard build/runtime\n        // dependency. Runtime device-access setup (input group / udev\n        // `uaccess` rule, Flatpak `--device=input`) is in docs/gamepad-linux.md.\n        else => {},\n    }\n\n";

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "emitDesktopOsLinks: per-OS frameworks + syslibs, omitted when all empty" {
    // wgpu-shape: macOS frameworks only → one .macos arm + else, no linux/windows.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const m: BackendManifestV2 = .{
        .manifest_version = 2,
        .dir_name = "wgpu",
        .dep_name = "labelle_wgpu",
        .modules = &.{},
        .frameworks = .{ .desktop = .{ .macos = &.{ "Foundation", "Metal" } } },
        .platforms = .{},
    };
    try emitDesktopOsLinks(m, &aw.writer, "exe");
    try testing.expectEqualStrings(
        "\n    switch (target.result.os.tag) {\n" ++
            "        .macos => {\n" ++
            "            exe.root_module.linkFramework(\"Foundation\", .{});\n" ++
            "            exe.root_module.linkFramework(\"Metal\", .{});\n" ++
            "        },\n" ++
            "        else => {},\n    }\n",
        aw.written(),
    );

    // Same switch, mirrored onto `test_root` (review #469): identical block with
    // the target variable swapped.
    var aw_test: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw_test.deinit();
    try emitDesktopOsLinks(m, &aw_test.writer, "test_root");
    try testing.expectEqualStrings(
        "\n    switch (target.result.os.tag) {\n" ++
            "        .macos => {\n" ++
            "            test_root.root_module.linkFramework(\"Foundation\", .{});\n" ++
            "            test_root.root_module.linkFramework(\"Metal\", .{});\n" ++
            "        },\n" ++
            "        else => {},\n    }\n",
        aw_test.written(),
    );

    // null-shape: nothing declared → no switch emitted at all.
    var aw2: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw2.deinit();
    const empty: BackendManifestV2 = .{ .manifest_version = 2, .dir_name = "null", .dep_name = "labelle_null", .modules = &.{}, .platforms = .{} };
    try emitDesktopOsLinks(empty, &aw2.writer, "exe");
    try testing.expectEqual(@as(usize, 0), aw2.written().len);
}

test "artifactIdent: sanitizes decl + link sites to matching valid Zig identifiers" {
    // A manifest artifact name is free-form; `glfw-native` (hyphen) and `123lib`
    // (leading digit) are NOT valid Zig identifiers, so the emitted variable name
    // must be sanitized — and the decl site + every link site must agree on it,
    // or the generated build.zig won't compile (review #469 findings 1+2).
    const cases = [_]struct { raw: []const u8, ident: []const u8 }{
        .{ .raw = "glfw-native", .ident = "glfw_native" },
        .{ .raw = "123lib", .ident = "_123lib" },
    };
    const cfg = ProjectConfig{ .name = "g" };

    for (cases) |c| {
        const artifacts = [_]BackendManifestV2.ArtifactDecl{.{ .name = c.raw }};
        const m: BackendManifestV2 = .{
            .manifest_version = 2,
            .dir_name = "x",
            .dep_name = "labelle_x",
            .modules = &.{},
            .platforms = .{ .desktop = .{
                .entry = "main.zig",
                .loop_style = .loop,
                .target = .native,
                .artifacts = &artifacts,
                .package = .binary,
            } },
        };

        // Decl site: `const <ident> = backend_dep.artifact("<raw>");`
        var decl: std.Io.Writer.Allocating = .init(testing.allocator);
        defer decl.deinit();
        try renderDesktopBackendDepGenericV2(testing.allocator, m, cfg, &decl.writer);
        const decl_line = try std.fmt.allocPrint(
            testing.allocator,
            "    const {s} = backend_dep.artifact(\"{s}\");\n",
            .{ c.ident, c.raw },
        );
        defer testing.allocator.free(decl_line);
        try testing.expect(std.mem.indexOf(u8, decl.written(), decl_line) != null);

        // Link site (exe): must reference the SAME sanitized identifier.
        var link_exe: std.Io.Writer.Allocating = .init(testing.allocator);
        defer link_exe.deinit();
        try renderDesktopLinkGenericV2(m, &link_exe.writer);
        const exe_line = try std.fmt.allocPrint(
            testing.allocator,
            "    exe.root_module.linkLibrary({s});\n",
            .{c.ident},
        );
        defer testing.allocator.free(exe_line);
        try testing.expectEqualStrings(exe_line, link_exe.written());

        // Link site (test_root): identical linkage mirrored onto the test root.
        var link_test: std.Io.Writer.Allocating = .init(testing.allocator);
        defer link_test.deinit();
        try renderDesktopTestLinkGenericV2(m, &link_test.writer);
        const test_line = try std.fmt.allocPrint(
            testing.allocator,
            "    test_root.root_module.linkLibrary({s});\n",
            .{c.ident},
        );
        defer testing.allocator.free(test_line);
        try testing.expectEqualStrings(test_line, link_test.written());

        // The sanitized identifier is a VALID Zig identifier (no invalid bytes,
        // no leading digit) — the whole point of the sanitizer.
        try testing.expect(c.ident.len > 0);
        try testing.expect(!std.ascii.isDigit(c.ident[0]));
        for (c.ident) |ch| {
            try testing.expect(std.ascii.isAlphanumeric(ch) or ch == '_');
        }
    }
}
