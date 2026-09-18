//! Registration keys must have one owner; do not silently shadow plugin types.
const std = @import("std");
const idents = @import("codegen/idents.zig");
const scan = @import("codegen/scan.zig");
const declare = @import("scripting_declare.zig");
pub fn check(a: std.mem.Allocator, game: []const []const u8, packs: []const scan.PackScan, scripts: []const declare.DeclaredComponent) !void {
    var seen: std.StringHashMap([]const u8) = .init(a);
    defer {
        var it = seen.iterator();
        while (it.next()) |entry| {
            a.free(entry.key_ptr.*);
            a.free(entry.value_ptr.*);
        }
        seen.deinit();
    }
    try insert(a, &seen, "VideoComponent", "engine VideoComponent");
    var buf: [128]u8 = undefined;
    for (game) |stem| try insert(a, &seen, idents.pathToPascal(stem, &buf), stem);
    var prefix: [128]u8 = undefined;
    for (packs) |pack| for (pack.component_names) |stem| {
        const key = try std.fmt.allocPrint(a, "{s}__{s}", .{ scan.packNamespacePrefix(pack.name, &prefix), idents.pathToPascal(stem, &buf) });
        defer a.free(key);
        const owner = try std.fmt.allocPrint(a, "pack {s}/{s}", .{ pack.name, stem });
        defer a.free(owner);
        try insert(a, &seen, key, owner);
    };
    for (scripts) |c| try insert(a, &seen, c.name, "script declaration");
}
fn insert(a: std.mem.Allocator, map: *std.StringHashMap([]const u8), key: []const u8, owner: []const u8) !void {
    if (map.get(key)) |prior| {
        if (!@import("builtin").is_test) std.log.err("component registration '{s}' collides: {s} and {s}", .{ key, prior, owner });
        return error.DuplicateComponentRegistration;
    }
    const k = try a.dupe(u8, key);
    errdefer a.free(k);
    const v = try a.dupe(u8, owner);
    errdefer a.free(v);
    try map.put(k, v);
}
// This check is emitted into generated main.zig. Zig reflection is authoritative
// for plugin exports (AST scanning cannot see re-exports or computed declarations).
pub const plugin_guard =
    \\fn rejectComponentCollisions(comptime local_names: []const []const u8, comptime plugins: anytype) void {
    \\    @setEvalBranchQuota(1000000);
    \\    for (plugins, 0..) |plugin, i| {
    \\        if (@hasDecl(plugin, "Components")) {
    \\            for (@typeInfo(plugin.Components).@"struct".decls) |decl| {
    \\                for (local_names) |name| {
    \\                    if (std.mem.eql(u8, name, decl.name)) @compileError("duplicate component registration '" ++ name ++ "': game and " ++ @typeName(plugin));
    \\                }
    \\                for (plugins, 0..) |previous, j| {
    \\                    if (j >= i) break;
    \\                    if (@hasDecl(previous, "Components") and @hasDecl(previous.Components, decl.name)) @compileError("duplicate component registration '" ++ decl.name ++ "': " ++ @typeName(previous) ++ " and " ++ @typeName(plugin));
    \\                }
    \\            }
    \\        }
    \\    }
    \\}
    \\
;
test "component registration rejects folded names and built-in collision" {
    // Disable error logs for negative cases through the test runner's log hook.
    try std.testing.expectError(error.DuplicateComponentRegistration, check(std.testing.allocator, &.{ "water_flow", "water/flow" }, &.{}, &.{}));
    try std.testing.expectError(error.DuplicateComponentRegistration, check(std.testing.allocator, &.{"video_component"}, &.{}, &.{}));
    try check(std.testing.allocator, &.{ "water", "fog", "lamp" }, &.{}, &.{});
    const pack = scan.PackScan{ .name = "effects", .import_prefix = "packs/effects", .component_names = &.{"water"}, .event_names = &.{}, .prefab_names = &.{} };
    try check(std.testing.allocator, &.{"water"}, &.{pack}, &.{});
    try std.testing.expectError(error.DuplicateComponentRegistration, check(std.testing.allocator, &.{}, &.{ pack, pack }, &.{}));
    try std.testing.expectError(error.DuplicateComponentRegistration, check(std.testing.allocator, &.{"water"}, &.{}, &.{.{ .name = "Water", .persist = .persistent, .fields = &.{} }}));
}
