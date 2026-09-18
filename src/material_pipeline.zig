//! Discover game-owned materials, validate before emission, stage build support.
const std = @import("std");
const config = @import("config.zig");
const scanner = @import("scanner.zig");
pub const schema = @import("material_schema.zig");
pub fn stage(a: std.mem.Allocator, game_dir: []const u8, target_dir: []const u8, backend: []const u8) ![][]const u8 {
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
        if (!std.mem.eql(u8, backend, "bgfx") and !std.mem.eql(u8, backend, "null")) {
            std.log.err("game-owned .sc materials require bgfx (selected backend: {s})", .{backend});
            return error.UnsupportedMaterialBackend;
        }
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
