//! Plugin-event CONSUMPTION filter (labelle-assembler#630).
//!
//! `discoverPluginEvents` finds every event a plugin (or the engine)
//! declares; this module decides which of those events something in the
//! project actually *consumes*, so `writePluginEventsBlock` can fold
//! only the consumed ones into the generated `PluginEvents` union.
//! Dropping unconsumed variants flips the plugins' existing comptime
//! `@hasField(GameEvents, tag)` emit gates to exactly the
//! zero-cost-when-unused semantics engine builtin events are designed
//! around — no engine runtime change, no plugin change, pure codegen.
//!
//! ── Match rule (deliberately conservative) ───────────────────────────
//!
//! An event is *consumed* when ANY scanned file contains, as a plain
//! substring, either:
//!
//!   - the qualified union tag `<plugin_sanitized>__<event_name>`
//!     (Zig hooks/scripts, generated flow sidecars, and scripting-
//!     language sources — Ruby/Lua/etc. — all reference the tag
//!     textually), or
//!   - the dotted form `<plugin_import_name>.<event_name>` (`.flow.jsonc`
//!     `OnEvent` references like `box2d.collision_begin`; engine-pass
//!     entries carry the import name `engine`, so `engine.tick` matches
//!     the same rule with no special case).
//!
//! Plain substring match is intentional: a match inside a comment merely
//! keeps the variant — a false positive preserves the pre-#630 behavior,
//! while a false negative would silently break event delivery, which is
//! the one unacceptable failure mode. No AST cleverness.
//!
//! ── Scan corpus ──────────────────────────────────────────────────────
//!
//! A recursive walk of each caller-supplied root (the game project dir
//! plus the staged `<target>/scripts` + `<target>/packs` trees, so
//! plugin-shipped scripts and staged pack hooks count as consumers).
//! Only files whose extension can plausibly reference an event tag are
//! read: `.zig`/`.zon`/`.jsonc`/`.json` plus every script-language
//! extension `language_policy.scriptExtensions` recognizes — that table
//! is the single source of truth for the language set. Directories are
//! skipped by basename (`.labelle` — the assembler output dir, whose
//! stale generated `main.zig` would otherwise keep every variant alive
//! forever — plus `.zig-cache`, `zig-out`, `.git`, `node_modules`).
//! Files above `max_file_size` are skipped (an event subscription lives
//! in source files, not megabyte blobs). Unreadable files/dirs are
//! skipped silently; only OOM propagates.

const std = @import("std");
const config = @import("../../config.zig");
const language_policy = @import("../../language_policy.zig");
const plugin_events_mod = @import("plugin_events.zig");

pub const PluginEvent = plugin_events_mod.PluginEvent;

/// Per-file read cap. Real consumers (hooks, scripts, flows) are small
/// source files; anything larger is almost certainly generated data or
/// an asset that wandered into the tree.
const max_file_size: usize = 2 * 1024 * 1024;

/// Directory basenames never descended into. Compared against the raw
/// directory entry name (never a joined path), so this is
/// path-separator agnostic by construction.
const skipped_dirs = [_][]const u8{
    ".labelle",
    ".zig-cache",
    "zig-out",
    ".git",
    "node_modules",
};

/// File extensions worth reading: Zig sources + data/flow formats, plus
/// every script-language extension the toolkit recognizes
/// (`language_policy.scriptExtensions` — the source of truth for the
/// language set, so a newly supported language is picked up here
/// automatically).
const scanned_extensions: []const []const u8 = blk: {
    var exts: []const []const u8 = &.{ ".zig", ".zon", ".jsonc", ".json" };
    for (language_policy.SUPPORTED_LANGUAGES) |lang| {
        for (language_policy.scriptExtensions(lang)) |ext| {
            exts = exts ++ &[_][]const u8{ext};
        }
    }
    break :blk exts;
};

fn hasScannedExtension(name: []const u8) bool {
    for (scanned_extensions) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    }
    return false;
}

fn isSkippedDir(name: []const u8) bool {
    for (skipped_dirs) |skip| {
        if (std.mem.eql(u8, name, skip)) return true;
    }
    return false;
}

/// Result of `filterConsumedEvents`. `kept` / `elided` are struct
/// copies of the caller's entries — the STRINGS inside are still owned
/// by the source `PluginEvents` list (which must outlive this struct
/// and is deinited exactly once by its owner); only the two arrays are
/// owned here.
pub const EventConsumption = struct {
    /// Entries with at least one consumer — fold these into
    /// `PluginEvents`. Discovery order is preserved.
    kept: []PluginEvent,
    /// Entries no scanned file references — elide these (each gets a
    /// `// elided (no consumer): <tag>` comment in the generated
    /// block). Discovery order is preserved.
    elided: []PluginEvent,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *EventConsumption) void {
        self.allocator.free(self.kept);
        self.allocator.free(self.elided);
        self.kept = &.{};
        self.elided = &.{};
    }
};

/// Partition `entries` into consumed / unconsumed by text-scanning every
/// eligible file under each of `scan_roots` (missing roots are skipped
/// silently). `mode == .all` short-circuits: everything is kept, nothing
/// is scanned — the pre-#630 unconditional folding.
///
/// The returned struct borrows the entry STRINGS from `entries` (see
/// `EventConsumption`); the caller keeps ownership of the source list.
pub fn filterConsumedEvents(
    allocator: std.mem.Allocator,
    entries: []const PluginEvent,
    scan_roots: []const []const u8,
    mode: config.PluginEventsMode,
) !EventConsumption {
    if (mode == .all or entries.len == 0) {
        const kept = try allocator.dupe(PluginEvent, entries);
        errdefer allocator.free(kept);
        const elided = try allocator.alloc(PluginEvent, 0);
        return .{ .kept = kept, .elided = elided, .allocator = allocator };
    }

    // Precompute both needles per entry once — the scan is
    // O(files × unconsumed entries).
    const Needles = struct {
        qualified: []const u8, // box2d__collision_begin
        dotted: []const u8, // box2d.collision_begin
    };
    const needles = try allocator.alloc(Needles, entries.len);
    var needles_built: usize = 0;
    defer {
        for (needles[0..needles_built]) |n| {
            allocator.free(n.qualified);
            allocator.free(n.dotted);
        }
        allocator.free(needles);
    }
    for (entries, 0..) |e, i| {
        const qualified = try std.fmt.allocPrint(allocator, "{s}__{s}", .{ e.plugin_sanitized, e.event_name });
        errdefer allocator.free(qualified);
        const dotted = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ e.plugin_import_name, e.event_name });
        needles[i] = .{ .qualified = qualified, .dotted = dotted };
        needles_built = i + 1;
    }

    const consumed = try allocator.alloc(bool, entries.len);
    defer allocator.free(consumed);
    @memset(consumed, false);

    var remaining: usize = entries.len;
    for (scan_roots) |root| {
        if (remaining == 0) break;
        try scanDir(allocator, root, needles, consumed, &remaining);
    }

    var kept: std.ArrayList(PluginEvent) = .empty;
    errdefer kept.deinit(allocator);
    var elided: std.ArrayList(PluginEvent) = .empty;
    errdefer elided.deinit(allocator);
    for (entries, consumed) |e, is_consumed| {
        if (is_consumed) {
            try kept.append(allocator, e);
        } else {
            try elided.append(allocator, e);
        }
    }

    const kept_slice = try kept.toOwnedSlice(allocator);
    errdefer allocator.free(kept_slice);
    const elided_slice = try elided.toOwnedSlice(allocator);
    return .{ .kept = kept_slice, .elided = elided_slice, .allocator = allocator };
}

/// Recursive walk of one root. Unreadable dirs/files are skipped
/// silently (conservative in the safe direction only for files that
/// don't exist — the roots we scan are the same trees the rest of the
/// generate pass reads, so a transiently unreadable file is the rare
/// case, and the escape hatch `.plugin_events = .all` covers pathological
/// setups). Only OOM propagates.
fn scanDir(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    needles: anytype,
    consumed: []bool,
    remaining: *usize,
) !void {
    const io = config.globalIo();
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch return) |entry| {
        if (remaining.* == 0) return;
        switch (entry.kind) {
            .directory => {
                if (isSkippedDir(entry.name)) continue;
                const child = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
                defer allocator.free(child);
                try scanDir(allocator, child, needles, consumed, remaining);
            },
            .file, .sym_link => {
                if (!hasScannedExtension(entry.name)) continue;
                const child = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
                defer allocator.free(child);
                const src = std.Io.Dir.cwd().readFileAlloc(io, child, allocator, .limited(max_file_size)) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    // Oversized or unreadable — skip (see fn doc).
                    else => continue,
                };
                defer allocator.free(src);
                for (needles, consumed) |n, *c| {
                    if (c.*) continue;
                    if (std.mem.indexOf(u8, src, n.qualified) != null or
                        std.mem.indexOf(u8, src, n.dotted) != null)
                    {
                        c.* = true;
                        remaining.* -= 1;
                    }
                }
            },
            else => {},
        }
    }
}

// ═════════════════════════════════════════════════════════════════════
// Tests
// ═════════════════════════════════════════════════════════════════════

const testing = std.testing;

/// The fixed two-entry discovery list the fixture tests filter.
const test_entries = [_]PluginEvent{
    .{
        .plugin_import_name = "box2d",
        .plugin_sanitized = "box2d",
        .event_name = "collision_begin",
    },
    .{
        .plugin_import_name = "box2d",
        .plugin_sanitized = "box2d",
        .event_name = "collision_end",
    },
};

fn filterTmp(tmp: *testing.TmpDir, mode: config.PluginEventsMode) !EventConsumption {
    const allocator = testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);
    return filterConsumedEvents(allocator, &test_entries, &.{root}, mode);
}

test "filterConsumedEvents: qualified tag in a .zig hook keeps the event; unreferenced sibling is elided" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "hooks");
    try tmp.dir.writeFile(io, .{
        .sub_path = "hooks/contact.zig",
        .data =
        \\pub fn onEvent(game: anytype, event: anytype) void {
        \\    switch (event) {
        \\        .box2d__collision_begin => |e| game.handle(e),
        \\        else => {},
        \\    }
        \\}
        ,
    });

    var result = try filterTmp(&tmp, .consumed);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.kept.len);
    try testing.expectEqualStrings("collision_begin", result.kept[0].event_name);
    try testing.expectEqual(@as(usize, 1), result.elided.len);
    try testing.expectEqualStrings("collision_end", result.elided[0].event_name);
}

test "filterConsumedEvents: dotted OnEvent ref in a .flow.jsonc keeps the event" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "scripts/flows");
    try tmp.dir.writeFile(io, .{
        .sub_path = "scripts/flows/on_hit.flow.jsonc",
        .data =
        \\{ "nodes": [ { "type": "OnEvent", "name": "box2d.collision_end" } ] }
        ,
    });

    var result = try filterTmp(&tmp, .consumed);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.kept.len);
    try testing.expectEqualStrings("collision_end", result.kept[0].event_name);
    try testing.expectEqual(@as(usize, 1), result.elided.len);
    try testing.expectEqualStrings("collision_begin", result.elided[0].event_name);
}

test "filterConsumedEvents: qualified tag in a .rb script keeps the event" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "scripts");
    try tmp.dir.writeFile(io, .{
        .sub_path = "scripts/contact.rb",
        .data =
        \\on :box2d__collision_begin do |e|
        \\  puts e
        \\end
        ,
    });

    var result = try filterTmp(&tmp, .consumed);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.kept.len);
    try testing.expectEqualStrings("collision_begin", result.kept[0].event_name);
}

test "filterConsumedEvents: no reference anywhere drops every event" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "scripts");
    try tmp.dir.writeFile(io, .{
        .sub_path = "scripts/idle.zig",
        .data = "pub fn idle() void {}",
    });

    var result = try filterTmp(&tmp, .consumed);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.kept.len);
    try testing.expectEqual(@as(usize, 2), result.elided.len);
}

test "filterConsumedEvents: a reference only inside the .labelle output dir does not count (excluded dir)" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // A stale generated main.zig names every variant — if the walk
    // descended into `.labelle`, no event could ever be elided again.
    try tmp.dir.createDirPath(io, ".labelle/raylib");
    try tmp.dir.writeFile(io, .{
        .sub_path = ".labelle/raylib/main.zig",
        .data =
        \\pub const PluginEvents = union(enum) {
        \\    box2d__collision_begin: @import("box2d").Events.collision_begin,
        \\    box2d__collision_end: @import("box2d").Events.collision_end,
        \\};
        ,
    });

    var result = try filterTmp(&tmp, .consumed);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.kept.len);
    try testing.expectEqual(@as(usize, 2), result.elided.len);
}

test "filterConsumedEvents: mode .all keeps everything without scanning" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Empty project dir — nothing consumes anything, yet `.all` must
    // keep the full discovery list (the pre-#630 escape hatch).
    var result = try filterTmp(&tmp, .all);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.kept.len);
    try testing.expectEqual(@as(usize, 0), result.elided.len);
    try testing.expectEqualStrings("collision_begin", result.kept[0].event_name);
    try testing.expectEqualStrings("collision_end", result.kept[1].event_name);
}

test "filterConsumedEvents: engine-pass entry matches the dotted `engine.<event>` form" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const engine_entries = [_]PluginEvent{
        .{ .plugin_import_name = "engine", .plugin_sanitized = "engine", .event_name = "tick" },
        .{ .plugin_import_name = "engine", .plugin_sanitized = "engine", .event_name = "game_init" },
    };
    try tmp.dir.createDirPath(io, "scripts/flows");
    try tmp.dir.writeFile(io, .{
        .sub_path = "scripts/flows/pulse.flow.jsonc",
        .data =
        \\{ "nodes": [ { "type": "OnEvent", "name": "engine.tick" } ] }
        ,
    });

    const allocator = testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var result = try filterConsumedEvents(allocator, &engine_entries, &.{root}, .consumed);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.kept.len);
    try testing.expectEqualStrings("tick", result.kept[0].event_name);
    try testing.expectEqual(@as(usize, 1), result.elided.len);
    try testing.expectEqualStrings("game_init", result.elided[0].event_name);
}

test "filterConsumedEvents: missing scan root is skipped silently" {
    const allocator = testing.allocator;
    var result = try filterConsumedEvents(
        allocator,
        &test_entries,
        &.{"/definitely/not/a/real/path/for/this/test"},
        .consumed,
    );
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.kept.len);
    try testing.expectEqual(@as(usize, 2), result.elided.len);
}
