//! Tests for the engine-side extension to `discoverPluginEvents`
//! (labelle-engine#578). The engine is a peer dependency (not a
//! plugin), so the discovery walk has a dedicated engine pass keyed
//! off `cfg.engine_version` — these tests stage a fake engine tree
//! and confirm:
//!
//!   1. `discoverPluginEvents` folds `engine.Events` into the union
//!      under the `engine` prefix.
//!   2. `writePluginEventsBlock` special-cases the prefix so the
//!      emitted union references `@import("labelle-engine")` (the
//!      actual Zig module name), not `@import("engine")` (the
//!      dotted-form prefix).
//!   3. Engine + plugin events coexist in one merged union.
//!
//! Kept in a separate file from `flow_scanner_tests.zig` so the
//! sibling work fixing test leaks in that file doesn't tangle with
//! these.

const std = @import("std");
const generator = @import("generator");

/// Lay down a fake engine tree at `<tmp>/labelle-engine/src/root.zig`
/// with the given source body. Returns the absolute engine path
/// (allocator-owned). `cfg.engine_version` is set to
/// `local:<abs-path>` so `cache.resolveFrameworkPackage("engine", ...)`
/// lands on this directory.
fn writeEngineRootZig(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, src: []const u8) ![]u8 {
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "labelle-engine/src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "labelle-engine/src/root.zig",
        .data = src,
    });
    const dir_z = try tmp.dir.realPathFileAlloc(io, "labelle-engine", allocator);
    defer allocator.free(dir_z);
    return allocator.dupe(u8, dir_z);
}

/// Same shape for a plugin's root.zig — used by the
/// engine-plus-plugin merge test below.
fn writePluginRootZig(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, plugin_name: []const u8, src: []const u8) ![]u8 {
    const io = std.testing.io;
    const src_sub = try std.fmt.allocPrint(allocator, "{s}/src", .{plugin_name});
    defer allocator.free(src_sub);
    try tmp.dir.createDirPath(io, src_sub);

    const root_sub = try std.fmt.allocPrint(allocator, "{s}/src/root.zig", .{plugin_name});
    defer allocator.free(root_sub);
    try tmp.dir.writeFile(io, .{ .sub_path = root_sub, .data = src });

    const plugin_dir_z = try tmp.dir.realPathFileAlloc(io, plugin_name, allocator);
    defer allocator.free(plugin_dir_z);
    return allocator.dupe(u8, plugin_dir_z);
}

test "discoverPluginEvents folds engine.Events under `engine` prefix" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path_z = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);
    const tmp_path = try allocator.dupe(u8, tmp_path_z);
    defer allocator.free(tmp_path);

    // Synthetic engine module with two Events decls — small surface
    // so the test doesn't have to mirror the real engine's full
    // variant list.
    const engine_src =
        \\const std = @import("std");
        \\
        \\pub const Events = struct {
        \\    pub const game_init = struct {};
        \\    pub const tick = struct { dt: f32 };
        \\};
        \\
    ;
    const engine_dir = try writeEngineRootZig(allocator, &tmp, engine_src);
    defer allocator.free(engine_dir);

    const engine_version = try std.fmt.allocPrint(allocator, "local:{s}", .{engine_dir});
    defer allocator.free(engine_version);

    // Project with no plugins — the engine must still be picked up.
    const cfg: generator.ProjectConfig = .{ .y_axis = .up,
        .name = "test-game",
        .backend = .raylib,
        .ecs = .mock,
        .engine_version = engine_version,
        .plugins = &.{},
    };

    var events = try generator.main_zig.discoverPluginEvents(allocator, cfg, tmp_path);
    defer events.deinit();

    try std.testing.expectEqual(@as(usize, 2), events.entries.len);
    try std.testing.expectEqualStrings("engine", events.entries[0].plugin_import_name);
    try std.testing.expectEqualStrings("engine", events.entries[0].plugin_sanitized);
    try std.testing.expectEqualStrings("game_init", events.entries[0].event_name);
    try std.testing.expectEqualStrings("tick", events.entries[1].event_name);
}

test "writePluginEventsBlock special-cases `engine` prefix to @import(\"labelle-engine\")" {
    const allocator = std.testing.allocator;

    // One synthetic engine entry — the emitter's special-case for
    // `engine` rewrites the @import target to `labelle-engine` (the
    // actual Zig module name) so the generated `PluginEvents` union
    // compiles against the engine's `pub const Events` declarations.
    const engine_event = generator.main_zig.PluginEvent{
        .plugin_import_name = "engine",
        .plugin_sanitized = "engine",
        .event_name = "game_init",
    };

    var alloc_writer: std.Io.Writer.Allocating = .init(allocator);
    defer alloc_writer.deinit();
    var ctx: generator.main_zig.Codegen = .{
        .allocator = allocator,
        .cfg = .{ .name = "test-game", .ecs = .mock, .y_axis = .up },
        .script_entries = &.{},
        .prefab_names = &.{},
        .jsonc_scene_names = &.{},
        .scene_manifests = &.{},
        .component_names = &.{},
        .hook_names = &.{},
        .event_names = &.{},
        .enum_names = &.{},
        .view_names = &.{},
        .gizmo_names = &.{},
        .animation_names = &.{},
        .plugin_events = &.{engine_event},
        .plugin_flow_nodes = &.{},
        .plugin_pin_styles = &.{},
        .plugin_coercions = &.{},
    };
    try ctx.writePluginEventsBlock(&alloc_writer.writer);

    const out = alloc_writer.writer.buffer[0..alloc_writer.writer.end];

    // The generated variant resolves to `labelle-engine`, not `engine`.
    try std.testing.expect(std.mem.indexOf(u8, out, "@import(\"labelle-engine\").Events.game_init") != null);
    // And the qualified tag form sticks to `engine__<event>`.
    try std.testing.expect(std.mem.indexOf(u8, out, "engine__game_init") != null);
}

test "engine + plugin events merge under their respective prefixes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path_z = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);
    const tmp_path = try allocator.dupe(u8, tmp_path_z);
    defer allocator.free(tmp_path);

    const engine_src =
        \\pub const Events = struct {
        \\    pub const tick = struct { dt: f32 };
        \\};
        \\
    ;
    const engine_dir = try writeEngineRootZig(allocator, &tmp, engine_src);
    defer allocator.free(engine_dir);

    const plugin_src =
        \\pub const Events = struct {
        \\    pub const collision_begin = struct { a: u32, b: u32 };
        \\};
        \\
    ;
    const plugin_dir_z = try writePluginRootZig(allocator, &tmp, "fake_box2d", plugin_src);
    defer allocator.free(plugin_dir_z);

    const engine_version = try std.fmt.allocPrint(allocator, "local:{s}", .{engine_dir});
    defer allocator.free(engine_version);
    const plugin_repo = try std.fmt.allocPrint(allocator, "local:{s}", .{plugin_dir_z});
    defer allocator.free(plugin_repo);

    const cfg: generator.ProjectConfig = .{ .y_axis = .up,
        .name = "test-game",
        .backend = .raylib,
        .ecs = .mock,
        .engine_version = engine_version,
        .plugins = &.{.{ .name = "fake_box2d", .repo = plugin_repo }},
    };

    var events = try generator.main_zig.discoverPluginEvents(allocator, cfg, tmp_path);
    defer events.deinit();

    // Engine entries come first (engine pass runs before the plugin
    // loop in `discoverPluginEvents`), then plugin entries.
    try std.testing.expectEqual(@as(usize, 2), events.entries.len);
    try std.testing.expectEqualStrings("engine", events.entries[0].plugin_import_name);
    try std.testing.expectEqualStrings("tick", events.entries[0].event_name);
    try std.testing.expectEqualStrings("fake_box2d", events.entries[1].plugin_import_name);
    try std.testing.expectEqualStrings("collision_begin", events.entries[1].event_name);
}

// ── Consumption filter emission (labelle-assembler#630) ──────────────
//
// `writePluginEventsBlock` folds only the CONSUMED entries
// (`ctx.plugin_events`) into the union and emits one
// `// elided (no consumer): <tag>` comment per dropped entry
// (`ctx.plugin_events_elided`) so a missing variant is diagnosable from
// the generated file.

/// Minimal `Codegen` over a kept/elided pair — the same shape
/// `root.zig` threads after `filterConsumedEvents` partitions the
/// discovery list.
fn eventsCtx(
    allocator: std.mem.Allocator,
    kept: []const generator.main_zig.PluginEvent,
    elided: []const generator.main_zig.PluginEvent,
) generator.main_zig.Codegen {
    return .{
        .allocator = allocator,
        .cfg = .{ .name = "test-game", .ecs = .mock, .y_axis = .up },
        .script_entries = &.{},
        .prefab_names = &.{},
        .jsonc_scene_names = &.{},
        .scene_manifests = &.{},
        .component_names = &.{},
        .hook_names = &.{},
        .event_names = &.{},
        .enum_names = &.{},
        .view_names = &.{},
        .gizmo_names = &.{},
        .animation_names = &.{},
        .plugin_events = kept,
        .plugin_flow_nodes = &.{},
        .plugin_pin_styles = &.{},
        .plugin_coercions = &.{},
        .plugin_events_elided = elided,
    };
}

test "writePluginEventsBlock emits an elided comment for dropped events and omits their variants (#630)" {
    const allocator = std.testing.allocator;

    const kept = [_]generator.main_zig.PluginEvent{
        .{ .plugin_import_name = "box2d", .plugin_sanitized = "box2d", .event_name = "collision_begin" },
    };
    const elided = [_]generator.main_zig.PluginEvent{
        .{ .plugin_import_name = "box2d", .plugin_sanitized = "box2d", .event_name = "collision_end" },
    };

    var alloc_writer: std.Io.Writer.Allocating = .init(allocator);
    defer alloc_writer.deinit();
    var ctx = eventsCtx(allocator, &kept, &elided);
    try ctx.writePluginEventsBlock(&alloc_writer.writer);
    const out = alloc_writer.writer.buffer[0..alloc_writer.writer.end];

    // Kept variant folded as before.
    try std.testing.expect(std.mem.indexOf(u8, out, "box2d__collision_begin: @import(\"box2d\").Events.collision_begin,") != null);
    // Elided variant: comment line present, union variant absent.
    try std.testing.expect(std.mem.indexOf(u8, out, "// elided (no consumer): box2d__collision_end") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "box2d__collision_end:") == null);
}

test "writePluginEventsBlock with everything elided emits PluginEvents = void plus the comments (#630)" {
    const allocator = std.testing.allocator;

    const elided = [_]generator.main_zig.PluginEvent{
        .{ .plugin_import_name = "box2d", .plugin_sanitized = "box2d", .event_name = "collision_begin" },
        .{ .plugin_import_name = "engine", .plugin_sanitized = "engine", .event_name = "tick" },
    };

    var alloc_writer: std.Io.Writer.Allocating = .init(allocator);
    defer alloc_writer.deinit();
    var ctx = eventsCtx(allocator, &.{}, &elided);
    try ctx.writePluginEventsBlock(&alloc_writer.writer);
    const out = alloc_writer.writer.buffer[0..alloc_writer.writer.end];

    // The empty-discovery path kicks in: `void`, no union literal — the
    // engine's `has_events = GameEvents != void` gate elides the event
    // buffer entirely.
    try std.testing.expect(std.mem.indexOf(u8, out, "pub const PluginEvents = void;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "union(enum)") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "// elided (no consumer): box2d__collision_begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "// elided (no consumer): engine__tick") != null);
}

test "writePluginEventsBlock with no elided entries emits no elision comments (byte-identical default)" {
    const allocator = std.testing.allocator;

    const kept = [_]generator.main_zig.PluginEvent{
        .{ .plugin_import_name = "box2d", .plugin_sanitized = "box2d", .event_name = "collision_begin" },
    };

    var alloc_writer: std.Io.Writer.Allocating = .init(allocator);
    defer alloc_writer.deinit();
    var ctx = eventsCtx(allocator, &kept, &.{});
    try ctx.writePluginEventsBlock(&alloc_writer.writer);
    const out = alloc_writer.writer.buffer[0..alloc_writer.writer.end];

    try std.testing.expect(std.mem.indexOf(u8, out, "elided (no consumer)") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "box2d__collision_begin") != null);
}
