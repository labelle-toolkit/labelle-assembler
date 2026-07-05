//! Cross-platform helpers shared by the manifest-v2 codegen sub-modules
//! (behavior-preserving split of `manifest_v2_splice.zig`, mirrors #539).
//!
//! Owns the pieces every platform emitter needs — the closed dep-option value
//! predicate set, the base↔per-platform `dep_options` merge, the module/artifact
//! ident helpers, the generic core-diamond walk splice, the byte-anchor
//! discriminator, plus the platform-agnostic hook staging / packaging / root
//! build-dep emitters. The per-platform renderers (desktop/android/ios/wasm) and
//! the section dispatchers (dispatch.zig) build on these. Every string these
//! helpers write feeds directly into generated `build.zig`/`build.zig.zon`
//! source — a byte-identical contract; the tests below (and the golden suite)
//! cover the emission shape.

const std = @import("std");
const config = @import("../../config.zig");
const manifest_v2 = @import("../manifest_v2.zig");
const core_diamond = @import("../core_diamond.zig");
const packager = @import("../packager.zig");
const backend_registry = @import("../../backend_registry.zig");
const scan = @import("../scan.zig");

pub const BackendManifestV2 = manifest_v2.BackendManifestV2;
pub const DepOption = BackendManifestV2.DepOption;
pub const ProjectConfig = config.ProjectConfig;

// ── Closed dependency-option value predicate set (design §4) ──────────────
// Names are declarative manifest data; VALUES come from this closed predicate
// set the assembler computes — the EXACT `paramValue` predicates the v1 splice
// uses today (`manifest_splice.zig:272`-`289`), plus the literal true/false the
// mobile `dont_link_system_libs` flag needs. The result is the literal `"true"`/
// `"false"` rendered into the generated `b.dependency` options struct.
pub fn depOptionValue(vs: DepOption.ValueSource, cfg: ProjectConfig) []const u8 {
    return switch (vs) {
        // with_imgui / gui_enabled: true iff the resolved gui plugin is imgui.
        .gui_is_imgui => if (cfg.resolved_gui) |gui|
            (if (std.mem.eql(u8, gui.name, "imgui")) "true" else "false")
        else
            "false",
        // Route through the resolver (never read `cfg.gamepad` directly) so the
        // codegen flag and `deps_linker.stagesSdlGamepad` can't disagree: a bgfx
        // project with an absent `.gamepad` resolves to `.none` → "false"
        // (assembler#533); raylib/sokol keep the `.auto` default → "true".
        .gamepad_enabled => if (cfg.effectiveGamepad() == .auto) "true" else "false",
        .gamepad_hidapi => if (cfg.gamepad_hidapi) "true" else "false",
        .true_literal => "true",
        .false_literal => "false",
    };
}

/// The base↔per-platform `dep_options` merge (design §3/§4 merge contract): start
/// from the base list, then for each per-platform entry OVERRIDE a base entry of
/// the same `name` (per-platform value wins) or APPEND it. No subtractive form.
/// Returns an allocator-owned slice the caller frees. Order is base entries first
/// (in declaration order), then per-platform appends — matching the enum-path
/// `b.dependency` literal order.
pub fn mergeDepOptions(
    allocator: std.mem.Allocator,
    base: []const DepOption,
    per_platform: []const DepOption,
) ![]DepOption {
    var out: std.ArrayList(DepOption) = .empty;
    errdefer out.deinit(allocator);
    for (base) |b| try out.append(allocator, b);
    for (per_platform) |p| {
        var overridden = false;
        for (out.items) |*existing| {
            if (std.mem.eql(u8, existing.name, p.name)) {
                existing.value = p.value; // override-by-name
                overridden = true;
                break;
            }
        }
        if (!overridden) try out.append(allocator, p); // append
    }
    return out.toOwnedSlice(allocator);
}

/// Root import alias for a provider module: `root_alias` if declared, else the
/// default `backend_<name>` (design §3 `ModuleDecl.root_alias`). Caller owns the
/// returned slice.
pub fn moduleAlias(allocator: std.mem.Allocator, mod: BackendManifestV2.ModuleDecl) ![]const u8 {
    if (mod.root_alias) |a| return allocator.dupe(u8, a);
    return std.fmt.allocPrint(allocator, "backend_{s}", .{mod.name});
}

/// Emit the generic core+gfx-diamond walk helper (`core_diamond.generated_walk_zig`)
/// into the generated build.zig. NOT used on the desktop byte-anchor path (which
/// unrolls — see the module doc); this is the spliceable mechanism for the
/// golden-snapshot cells (PR 5+) and a compile/drift guard that keeps this module
/// referencing the PR-2 walk source.
pub fn emitCoreDiamondWalk(w: anytype) !void {
    try w.writeAll(core_diamond.generated_walk_zig);
}

/// Whether a v2 manifest's DESKTOP cell is emitted in the sokol BYTE-ANCHOR form
/// (design §7): its output is unrolled to hit a 0-diff against the enum/v1 path,
/// keeping the backend-specific prose + the hand-written core-diamond
/// `overrideImport` `if`-blocks. EVERY OTHER v2 backend's desktop cell uses the
/// GENERIC declarative path (loop-form `unifyCoreDiamond` walk + manifest-driven
/// artifact/framework link), gated as a reviewed golden — because a loop emits
/// different source than the unrolled form (§7 tier-1).
///
/// Keyed on the retained sokol fixture's `dep_name`: the anchor residual constants
/// (`anchor_head_comment`/`anchor_tail_overrides`/`anchor_link_body`) are literally
/// sokol's own fragments, so only the sokol byte-anchor backend can use them. This
/// discriminator (and the anchor residual it selects) is deleted with the enum path
/// in PR 12, at which point the sokol-desktop cell becomes a golden snapshot too.
pub fn isDesktopByteAnchor(m: BackendManifestV2) bool {
    return std.mem.eql(u8, m.dep_name, "labelle_sokol");
}

/// Sanitize a manifest artifact NAME into a valid Zig identifier for use as the
/// generated variable name. Manifest artifact names are free-form strings, but
/// they are emitted BOTH as a `const <id> = backend_dep.artifact("<raw>")` decl
/// and referenced at the link site (`<target>.root_module.linkLibrary(<id>)`),
/// so an artifact named `glfw-native` (hyphen) or `123lib` (leading digit) would
/// emit invalid Zig unless both sites sanitize to the SAME identifier. Reuses the
/// repo's `scan.sanitizePluginIdent` (invalid bytes → `_`, leading digit → `_`
/// prefix); the raw name is still used verbatim inside the `artifact("...")`
/// string literal. Review #469 findings 1+2.
pub fn artifactIdent(name: []const u8, buf: *[128]u8) []const u8 {
    return scan.sanitizePluginIdent(name, buf);
}

/// The root-import alias the generated build.zig references the backend hook by.
/// The assembler stages the manifest's `build_hook` file next to the generated
/// `build.zig` under this name (see `stageBackendBuildHook`) so the generated
/// `@import("backend_build_hook.zig")` resolves at build time.
pub const hook_import_name = "backend_build_hook.zig";

/// Stage (copy) the backend package's `build_hook` file next to the generated
/// build.zig, under `hook_import_name`. The generated v2 (android, PR 5) build.zig
/// `@import`s the hook by that sibling name and calls `resolve_target`/`post_wire`;
/// without this copy a real v2 build fails at import resolution (PR #466 Finding 3).
/// Mirrors how the orchestrator writes the other generated siblings (build.zig,
/// game.zig, main.zig) into `target_dir`.
///
/// No-op (returns false) when the v2 manifest carries no `build_hook`; returns true
/// when a hook was staged. `backend_manifest_name` is the SAME name the caller
/// passed to `generateBuildZig`.
pub fn stageBackendBuildHook(
    allocator: std.mem.Allocator,
    cfg: ProjectConfig,
    project_dir: []const u8,
    backend_manifest_name: []const u8,
    target_dir: []const u8,
) !bool {
    const m = try manifest_v2.loadNamedManifest(allocator, cfg, project_dir, backend_manifest_name);
    defer std.zon.parse.free(allocator, m);
    const hook_rel = m.build_hook orelse return false;

    const pkg_dir = try backend_registry.resolveBackendPackage(allocator, cfg, project_dir);
    defer allocator.free(pkg_dir);
    const src_path = try std.fs.path.join(allocator, &.{ pkg_dir, hook_rel });
    defer allocator.free(src_path);

    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const content = try cwd.readFileAlloc(io, src_path, allocator, .limited(256 * 1024));
    defer allocator.free(content);

    var dir = try cwd.openDir(io, target_dir, .{});
    defer dir.close(io);
    const file = try dir.createFile(io, hook_import_name, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
    return true;
}

/// Look up the `PlatformEntry` for a `config.Platform` on a v2 manifest. Absent
/// platform = unsupported by this backend.
pub fn platformEntry(
    m: BackendManifestV2,
    platform: config.Platform,
) ?BackendManifestV2.PlatformEntry {
    return switch (platform) {
        .desktop => m.platforms.desktop,
        .android => m.platforms.android,
        .ios => m.platforms.ios,
        .wasm => m.platforms.wasm,
    };
}

/// v2 packaging seam (design §3/§6): delegate a platform's packaging to the
/// shared packager, driven by the typed `PlatformEntry.package` recipe. The v2
/// codegen has no `switch (cfg.platform)` — it drives packaging off manifest
/// data — so this is the single entry point every v2 platform path calls.
///
/// Desktop's `.binary` recipe is a NO-OP, so this is safe to call
/// unconditionally on the PR-3 desktop path without disturbing its byte anchor.
/// Android/wasm entries (PRs 5/7) carry `.apk`/`.web` recipes that emit the
/// apk-staging / emcc packaging block here, byte-identical to the enum path's
/// `.android_package` / `.wasm_footer` sections (design §7).
pub fn renderPackageV2(
    m: BackendManifestV2,
    platform: config.Platform,
    w: anytype,
) !void {
    const entry = platformEntry(m, platform) orelse return error.V2PlatformUnsupported;
    try packager.emitPackage(entry.package, w);
}

/// Emit a v2 manifest's `.platforms[p].root_build_deps` as generated
/// `build.zig.zon` dependency entries (design §3 `RootBuildDep`, review #459
/// finding 2). A hook's build-time `b.dependency(name, .{})` (e.g. the wasm
/// emcc residual's `b.dependency("emsdk", .{})`) only resolves if the root zon
/// declares that dep — the v2 manifest otherwise describes only build.zig wiring.
/// Each entry carries its own resolution because the emitter cannot synthesize a
/// url+hash from a bare name:
///   - `.builtin` → a resolution the assembler already knows how to emit. emsdk
///     is the only builtin today; it reuses the pinned `dep_emsdk` section so the
///     v2 zon stays byte-identical to the enum path (`build_zig_zon.txt:71`).
///   - `.remote`  → the given url+hash, emitted verbatim.
///   - `.path`    → a relative/absolute path dependency.
/// `dep_emsdk_section` is the caller-supplied pinned emsdk zon text (from
/// `build_zig_zon.txt`) so this module needn't embed that template.
pub fn emitRootBuildDepsV2(
    m: BackendManifestV2,
    platform: config.Platform,
    dep_emsdk_section: []const u8,
    w: anytype,
) !void {
    const entry = platformEntry(m, platform) orelse return;
    for (entry.root_build_deps) |dep| {
        switch (dep.resolution) {
            .builtin => {
                if (!std.mem.eql(u8, dep.name, "emsdk")) return error.UnknownBuiltinRootDep;
                try w.writeAll(dep_emsdk_section);
            },
            // url/hash/path are emitted as ZON string literals: escape their
            // contents (`"` → `\"`, `\` → `\\`) via std.zig.fmtString so a value
            // containing a quote/backslash can't produce malformed ZON. hash is
            // hex (low-risk) but escaped for consistency. #468 finding 2.
            .remote => |r| try w.print(
                "        .{s} = .{{\n            .url = \"{f}\",\n            .hash = \"{f}\",\n        }},\n",
                .{ dep.name, std.zig.fmtString(r.url), std.zig.fmtString(r.hash) },
            ),
            .path => |p| try w.print(
                "        .{s} = .{{\n            .path = \"{f}\",\n        }},\n",
                .{ dep.name, std.zig.fmtString(p) },
            ),
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "isDesktopByteAnchor: only the sokol fixture uses the unrolled anchor path" {
    const mk = struct {
        fn m(dep_name: []const u8) BackendManifestV2 {
            return .{ .manifest_version = 2, .dir_name = "x", .dep_name = dep_name, .modules = &.{}, .platforms = .{} };
        }
    }.m;
    try testing.expect(isDesktopByteAnchor(mk("labelle_sokol")));
    try testing.expect(!isDesktopByteAnchor(mk("labelle_null")));
    try testing.expect(!isDesktopByteAnchor(mk("labelle_wgpu")));
}

test "mergeDepOptions: base first, then per-platform appends (sokol desktop order)" {
    const base = [_]DepOption{.{ .name = "with_imgui", .value = .gui_is_imgui }};
    const per = [_]DepOption{
        .{ .name = "gamepad_enabled", .value = .gamepad_enabled },
        .{ .name = "gamepad_hidapi", .value = .gamepad_hidapi },
    };
    const merged = try mergeDepOptions(testing.allocator, &base, &per);
    defer testing.allocator.free(merged);
    try testing.expectEqual(@as(usize, 3), merged.len);
    try testing.expectEqualStrings("with_imgui", merged[0].name);
    try testing.expectEqualStrings("gamepad_enabled", merged[1].name);
    try testing.expectEqualStrings("gamepad_hidapi", merged[2].name);
}

test "mergeDepOptions: per-platform overrides a base entry by name, no duplicate" {
    const base = [_]DepOption{.{ .name = "with_imgui", .value = .gui_is_imgui }};
    const per = [_]DepOption{.{ .name = "with_imgui", .value = .true_literal }};
    const merged = try mergeDepOptions(testing.allocator, &base, &per);
    defer testing.allocator.free(merged);
    try testing.expectEqual(@as(usize, 1), merged.len);
    try testing.expectEqual(DepOption.ValueSource.true_literal, merged[0].value);
}

test "depOptionValue: gamepad_enabled routes through effectiveGamepad (assembler#533)" {
    // bgfx with an ABSENT `.gamepad` resolves to `.none` → "false" (the default
    // now differs from raylib/sokol). An explicit `.auto` on bgfx opts back in.
    try testing.expectEqualStrings("false", depOptionValue(.gamepad_enabled, .{ .name = "g", .backend = .bgfx }));
    try testing.expectEqualStrings("true", depOptionValue(.gamepad_enabled, .{ .name = "g", .backend = .bgfx, .gamepad = .auto }));
    // raylib/sokol keep the historical `.auto` default when `.gamepad` is absent.
    try testing.expectEqualStrings("true", depOptionValue(.gamepad_enabled, .{ .name = "g", .backend = .raylib }));
    try testing.expectEqualStrings("true", depOptionValue(.gamepad_enabled, .{ .name = "g", .backend = .sokol }));
    // Explicit `.none` opts out everywhere.
    try testing.expectEqualStrings("false", depOptionValue(.gamepad_enabled, .{ .name = "g", .backend = .raylib, .gamepad = .none }));
}

test "depOptionValue: closed predicate set matches the v1 paramValue predicates" {
    const base_cfg = ProjectConfig{ .name = "g" };
    // Default backend is raylib; absent `.gamepad` resolves to .auto →
    // gamepad_enabled true; hidapi false; no gui → false.
    try testing.expectEqualStrings("true", depOptionValue(.gamepad_enabled, base_cfg));
    try testing.expectEqualStrings("false", depOptionValue(.gamepad_hidapi, base_cfg));
    try testing.expectEqualStrings("false", depOptionValue(.gui_is_imgui, base_cfg));
    try testing.expectEqualStrings("true", depOptionValue(.true_literal, base_cfg));
    try testing.expectEqualStrings("false", depOptionValue(.false_literal, base_cfg));
}

test "moduleAlias: default is backend_<name>, explicit alias preserved" {
    const a = try moduleAlias(testing.allocator, .{ .name = "gfx", .source = "x" });
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("backend_gfx", a);

    const b = try moduleAlias(testing.allocator, .{ .name = "android_app", .root_alias = "backend_app", .source = "x" });
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("backend_app", b);
}

test "emitRootBuildDepsV2: builtin emsdk emits the pinned dep_emsdk section" {
    const e = struct {
        fn make(deps: []const BackendManifestV2.RootBuildDep) BackendManifestV2.PlatformEntry {
            return .{ .entry = "t.txt", .loop_style = .callback, .target = .{ .triple = "wasm32-emscripten" }, .root_build_deps = deps, .package = .{ .web = .{} } };
        }
    }.make;
    const m: BackendManifestV2 = .{
        .manifest_version = 2,
        .dir_name = "sokol",
        .dep_name = "labelle_sokol",
        .modules = &.{},
        .platforms = .{ .wasm = e(&.{.{ .name = "emsdk", .resolution = .builtin }}) },
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitRootBuildDepsV2(m, .wasm, "PINNED_EMSDK\n", &aw.writer);
    try testing.expectEqualStrings("PINNED_EMSDK\n", aw.written());

    // remote resolution emits url+hash verbatim.
    var aw2: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw2.deinit();
    const m2: BackendManifestV2 = .{
        .manifest_version = 2,
        .dir_name = "x",
        .dep_name = "x",
        .modules = &.{},
        .platforms = .{ .wasm = e(&.{.{ .name = "foo", .resolution = .{ .remote = .{ .url = "git+u", .hash = "hh" } } }}) },
    };
    try emitRootBuildDepsV2(m2, .wasm, "", &aw2.writer);
    try testing.expectEqualStrings(
        "        .foo = .{\n            .url = \"git+u\",\n            .hash = \"hh\",\n        },\n",
        aw2.written(),
    );

    // an unknown builtin name is a hard error (no url to synthesize).
    var aw3: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw3.deinit();
    const m3: BackendManifestV2 = .{
        .manifest_version = 2,
        .dir_name = "x",
        .dep_name = "x",
        .modules = &.{},
        .platforms = .{ .wasm = e(&.{.{ .name = "mystery", .resolution = .builtin }}) },
    };
    try testing.expectError(error.UnknownBuiltinRootDep, emitRootBuildDepsV2(m3, .wasm, "", &aw3.writer));
}

test "emitRootBuildDepsV2: url/path with quote+backslash are escaped into valid ZON" {
    const e = struct {
        fn make(deps: []const BackendManifestV2.RootBuildDep) BackendManifestV2.PlatformEntry {
            return .{ .entry = "t.txt", .loop_style = .callback, .target = .{ .triple = "wasm32-emscripten" }, .root_build_deps = deps, .package = .{ .web = .{} } };
        }
    }.make;

    // remote: a url/hash carrying a `"` and a `\` must be emitted as escaped
    // ZON string content, not interpolated raw (which would break the literal).
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const m: BackendManifestV2 = .{
        .manifest_version = 2,
        .dir_name = "x",
        .dep_name = "x",
        .modules = &.{},
        .platforms = .{ .wasm = e(&.{.{ .name = "foo", .resolution = .{ .remote = .{ .url = "git+u\"x\\y", .hash = "h\"h" } } }}) },
    };
    try emitRootBuildDepsV2(m, .wasm, "", &aw.writer);
    try testing.expectEqualStrings(
        "        .foo = .{\n            .url = \"git+u\\\"x\\\\y\",\n            .hash = \"h\\\"h\",\n        },\n",
        aw.written(),
    );

    // path: same escaping.
    var aw2: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw2.deinit();
    const m2: BackendManifestV2 = .{
        .manifest_version = 2,
        .dir_name = "x",
        .dep_name = "x",
        .modules = &.{},
        .platforms = .{ .wasm = e(&.{.{ .name = "bar", .resolution = .{ .path = "a\"b\\c" } }}) },
    };
    try emitRootBuildDepsV2(m2, .wasm, "", &aw2.writer);
    try testing.expectEqualStrings(
        "        .bar = .{\n            .path = \"a\\\"b\\\\c\",\n        },\n",
        aw2.written(),
    );
}

test "emitCoreDiamondWalk emits the PR-2 generic walk source (drift guard)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitCoreDiamondWalk(&aw.writer);
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "fn unifyCoreDiamond(") != null);
    try testing.expect(std.mem.indexOf(u8, out, "labelle-gfx") != null);
}

// A minimal v2 manifest exercising all four platform packaging recipes: desktop
// `.binary` (no-op), android `.apk`, wasm `.web`; ios absent (unsupported).
fn packagingManifest() BackendManifestV2 {
    const entry = struct {
        fn e(pkg: BackendManifestV2.Package) BackendManifestV2.PlatformEntry {
            return .{ .entry = "t.txt", .loop_style = .callback, .target = .native, .package = pkg };
        }
    }.e;
    return .{
        .manifest_version = 2,
        .dir_name = "sokol",
        .dep_name = "labelle_sokol",
        .modules = &.{},
        .platforms = .{
            .desktop = entry(.binary),
            .android = entry(.{ .apk = .{ .manifest = "AndroidManifest.xml.tmpl" } }),
            .wasm = entry(.{ .web = .{ .shell = null } }),
        },
    };
}

fn renderPackageToOwned(m: BackendManifestV2, platform: config.Platform) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try renderPackageV2(m, platform, &aw.writer);
    return aw.toOwnedSlice();
}

test "renderPackageV2: desktop .binary is a no-op (preserves the byte anchor)" {
    const out = try renderPackageToOwned(packagingManifest(), .desktop);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "renderPackageV2: android delegates to the packager apk recipe" {
    const out = try renderPackageToOwned(packagingManifest(), .android);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(packager.apk_package_zig, out);
}

test "renderPackageV2: wasm delegates to the packager web recipe" {
    const out = try renderPackageToOwned(packagingManifest(), .wasm);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(packager.web_package_zig, out);
}

test "renderPackageV2: an absent platform is unsupported" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try testing.expectError(
        error.V2PlatformUnsupported,
        renderPackageV2(packagingManifest(), .ios, &aw.writer),
    );
}
