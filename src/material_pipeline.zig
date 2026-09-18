//! Discover game-owned materials, validate before emission, stage build support.
const std = @import("std");
const config = @import("config.zig");
const scanner = @import("scanner.zig");
pub const schema = @import("material_schema.zig");
/// Whether the selected backend can consume game-owned `.sc` materials.
///
/// Keyed off the `.bgfx` ENUM TAG, never `backendName()` (PR #733 review,
/// same reasoning as `ProjectConfig.effectiveGamepad`): the name is the
/// resolved PACKAGE name, which a `.backend = .bgfx` project can override to
/// anything (`.backend_package = .{ .name = "bgfx_v2", .. }` — the in-tree v2
/// fixture — or a fork named `labelle-bgfx`). A literal `"bgfx"` string match
/// rejected every such compatible provider with `UnsupportedMaterialBackend`.
/// The tag survives the enum-as-shorthand resolution, so it is the reliable
/// "is bgfx" signal. `.null` is accepted because the tests target
/// (`testsTargetConfig`) force-substitutes it while the game still ships the
/// materials module.
///
/// LIMITATION (documented, like `effectiveGamepad`): a third-party bgfx-shaped
/// provider selected purely via `.backend_package` with `.backend` left at its
/// `.raylib` default is rejected; declare `.backend = .bgfx` alongside the
/// package. There is no material capability in the provider manifest yet.
pub fn requireBackend(cfg: config.ProjectConfig) error{UnsupportedMaterialBackend}!void {
    switch (cfg.backend) {
        .bgfx, .null => {},
        else => return error.UnsupportedMaterialBackend,
    }
}
pub fn stage(a: std.mem.Allocator, game_dir: []const u8, target_dir: []const u8, cfg: config.ProjectConfig) ![][]const u8 {
    const io = config.globalIo();
    const root = try std.fs.path.join(a, &.{ game_dir, "materials" });
    defer a.free(root);
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return a.alloc([]const u8, 0),
        else => return err,
    };
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |n| a.free(n);
        names.deinit(a);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory or entry.name[0] == '.') continue;
        const rel = try std.fs.path.join(a, &.{ entry.name, "material.json" });
        defer a.free(rel);
        const bytes = dir.readFileAlloc(io, rel, a, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer a.free(bytes);
        if (!schema.materialName(entry.name)) {
            std.log.err("materials/{s}: expected identifier directory name (max 63 bytes; generated-symbol names are reserved)", .{entry.name});
            return error.InvalidMaterialName;
        }
        for (names.items) |n| if (std.ascii.eqlIgnoreCase(n, entry.name)) {
            // Case-insensitive: the generated module exports one Zig decl per
            // folder, and a case-only difference collides on the many hosts
            // whose filesystems fold case.
            std.log.err("materials/{s}: collides with materials/{s} (material folder names must be unique ignoring case)", .{ entry.name, n });
            return error.DuplicateMaterialName;
        };
        const parsed = schema.parse(a, bytes) catch |err| {
            std.log.err("materials/{s}: {s}", .{ rel, @errorName(err) });
            return err;
        };
        defer parsed.deinit();
        const fragment = try std.fs.path.join(a, &.{ entry.name, parsed.value.fragment });
        defer a.free(fragment);
        dir.access(io, fragment, .{}) catch |err| {
            std.log.err("materials/{s}: fragment '{s}' unavailable ({s})", .{ rel, parsed.value.fragment, @errorName(err) });
            return error.MissingMaterialFragment;
        };
        const name = try a.dupe(u8, entry.name);
        errdefer a.free(name);
        try names.append(a, name);
    }
    if (names.items.len != 0) {
        requireBackend(cfg) catch |err| {
            std.log.err("game-owned .sc materials require bgfx (selected backend: {s})", .{cfg.backendName()});
            return err;
        };
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.less);
        try scanner.linkDir(a, game_dir, target_dir, "materials");
        try scanner.writeFile(target_dir, "material_build.zig", @embedFile("material_build.zig"));
        try scanner.writeFile(target_dir, "material_schema.zig", @embedFile("material_schema.zig"));
    }
    return names.toOwnedSlice(a);
}
pub fn emit(w: *std.Io.Writer, names: []const []const u8, platform: []const u8) !void {
    if (names.len == 0) return;
    try w.writeAll("    const materials_mod = @import(\"material_build.zig\").create(b, target, optimize, core_mod, &.{\n");
    for (names) |name| try w.print("        .{{ .name = \"{s}\", .json = @embedFile(\"materials/{s}/material.json\") }},\n", .{ name, name });
    try w.print("    }}, \"{s}\");\n    overrideImport(game_mod, \"materials\", materials_mod);\n", .{platform});
}
pub fn emitImport(w: *std.Io.Writer, names: []const []const u8, artifact: []const u8) !void {
    if (names.len != 0) try w.print("    {s}.root_module.addImport(\"materials\", materials_mod);\n", .{artifact});
}

test "materials build emission has explicit embedded descriptors and empty no-op" {
    _ = schema;
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try emit(&out.writer, &.{}, "desktop");
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
    try emit(&out.writer, &.{ "fog", "lamp" }, "desktop");
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "materials/fog/material.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "materials/lamp/material.json") != null);
}

test "requireBackend: keyed off the .bgfx enum tag, not the resolved package name (#733 P2)" {
    // A `.backend = .bgfx` project whose provider package is NOT literally named
    // "bgfx" — the in-tree v2 fixture spelling this repo itself uses — must be
    // accepted: the tag is the identity, the name is configurable.
    try requireBackend(.{
        .name = "g",
        .backend = .bgfx,
        .backend_package = .{ .name = "bgfx_v2", .repo = "local:backends/bgfx_v2" },
    });
    // Plain enum-as-shorthand default and the tests-target `.null` substitution.
    try requireBackend(.{ .name = "g", .backend = .bgfx });
    try requireBackend(.{ .name = "g", .backend = .null });
    // A non-bgfx backend is still rejected — including one whose PACKAGE is
    // named "bgfx" (the name must not be the signal in either direction).
    try std.testing.expectError(error.UnsupportedMaterialBackend, requireBackend(.{ .name = "g", .backend = .sokol }));
    try std.testing.expectError(error.UnsupportedMaterialBackend, requireBackend(.{
        .name = "g",
        .backend = .sokol,
        .backend_package = .{ .name = "bgfx", .repo = "local:backends/bgfx_v2" },
    }));
}
