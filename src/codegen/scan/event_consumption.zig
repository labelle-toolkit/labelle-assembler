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
//!
//! Files of ANY size are scanned — large ones stream through a
//! fixed-size chunk buffer with a needle-length overlap so a tag
//! straddling a chunk boundary still matches (skipping oversized files
//! would turn a consumer living in a big generated `.json` into a
//! silent false negative, the one unacceptable failure mode).
//!
//! Error policy (CodeRabbit review on 6ed5fef): an incomplete scan must
//! never masquerade as "no consumer". A scan ROOT that doesn't exist is
//! skipped silently (the `<target>/packs` root is legitimately absent
//! for pack-less projects), and a dangling symlink / entry deleted
//! mid-walk is skipped because a nonexistent file provably contains no
//! consumer. Every OTHER I/O failure (permissions, hardware, iterator
//! errors) fails `generate` loudly — the same trees are read elsewhere
//! in the generate pass, so an unreadable file is a real problem, and
//! `.plugin_events = .all` covers pathological setups.
//!
//! ── Excluded dependency roots (#631 review) ──────────────────────────
//!
//! `excluded_roots` carries the resolved source dirs of IN-TREE
//! dependencies (`local:plugins/box2d`, `@libs/box2d`, a `local:`
//! engine/core/gfx override — the forms `cache/resolve.zig` keeps under
//! the project tree). A dependency's own source names its event tags at
//! the emit sites (`box2d__collision_begin` appears at every
//! `emitGameEvent` call), so scanning it would mark all its events
//! consumed and void the filter for exactly the local-plugin-heavy
//! projects. Exclusion is by CANONICAL path equality — `realpath` on
//! both sides, so it is symlink- and path-separator-robust (no raw
//! string comparison of joined paths with mixed separators): a walked
//! directory whose canonical path equals an excluded root is skipped
//! with its whole subtree. Deliberate asymmetry: a local plugin's
//! hooks/scripts STAGED into `<target>/scripts` / `<target>/packs` are
//! still scanned, so cross-plugin consumption via shipped scripts keeps
//! working — only the plugin's own module source is excluded, exactly
//! like a published plugin (whose cache dir was never a scan root).

const std = @import("std");
const config = @import("../../config.zig");
const language_policy = @import("../../language_policy.zig");
const plugin_events_mod = @import("plugin_events.zig");

pub const PluginEvent = plugin_events_mod.PluginEvent;

/// Chunk size for the streaming file scan. Files are searched through a
/// buffer of `scan_chunk_size + overlap` bytes, where the overlap is one
/// byte short of the longest needle — so a tag straddling a chunk
/// boundary is always fully contained in some window. There is no file
/// size cap: capping would turn a consumer inside a big generated
/// `.json` into a silent false negative.
const scan_chunk_size: usize = 256 * 1024;

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
/// `excluded_roots`: resolved source dirs of in-tree dependencies
/// (`local:`/`@libs` plugins, local framework overrides) — see the file
/// header. Compared by canonical path (`realpath` both sides), so
/// symlinked layouts and Windows separators are handled; entries that
/// don't resolve (e.g. a dep outside the scanned trees that was already
/// unreachable) are ignored. The dependency's staged hooks/scripts under
/// `<target>/scripts` / `<target>/packs` are NOT excluded — cross-plugin
/// consumption via shipped scripts keeps working; only the module source
/// is skipped, same as a published plugin's cache dir.
///
/// The returned struct borrows the entry STRINGS from `entries` (see
/// `EventConsumption`); the caller keeps ownership of the source list.
pub fn filterConsumedEvents(
    allocator: std.mem.Allocator,
    entries: []const PluginEvent,
    scan_roots: []const []const u8,
    excluded_roots: []const []const u8,
    mode: config.PluginEventsMode,
) !EventConsumption {
    if (mode == .all or entries.len == 0) {
        const kept = try allocator.dupe(PluginEvent, entries);
        errdefer allocator.free(kept);
        const elided = try allocator.alloc(PluginEvent, 0);
        return .{ .kept = kept, .elided = elided, .allocator = allocator };
    }

    // Canonicalize the exclusion set once up front; the walk then
    // canonicalizes each visited directory and compares for equality.
    // Roots that don't resolve are dropped (nothing on disk to exclude).
    const io = config.globalIo();
    const excluded = try allocator.alloc([]const u8, excluded_roots.len);
    var excluded_len: usize = 0;
    defer {
        for (excluded[0..excluded_len]) |p| allocator.free(p);
        allocator.free(excluded);
    }
    for (excluded_roots) |root| {
        // Dupe the [:0]u8 realpath to a plain []u8 so the free above
        // doesn't hit the sentinel-byte size mismatch (same pattern as
        // `cache/resolve.zig`).
        const canon_z = std.Io.Dir.cwd().realPathFileAlloc(io, root, allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer allocator.free(canon_z);
        excluded[excluded_len] = try allocator.dupe(u8, canon_z);
        excluded_len += 1;
    }
    const excluded_canon = excluded[0..excluded_len];

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
        if (try isExcludedDir(allocator, root, excluded_canon)) continue;
        try scanDir(allocator, root, needles, consumed, &remaining, excluded_canon);
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

/// Recursive walk of one root. Error policy (see file header): a
/// missing directory (root that doesn't exist, dangling symlink, entry
/// deleted mid-walk) is skipped silently — nothing on disk means no
/// consumer to miss. Every OTHER I/O failure propagates loudly with a
/// pointed diagnostic: an incomplete scan silently treated as "no
/// consumer" would elide a live subscription and break event delivery.
fn scanDir(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    needles: anytype,
    consumed: []bool,
    remaining: *usize,
    excluded_canon: []const []const u8,
) !void {
    const io = config.globalIo();
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        // Missing root / dangling symlink / mid-walk deletion — no
        // content, no possible false negative. `NotDir` covers a root
        // path that names a file.
        error.FileNotFound, error.NotDir => return,
        else => return scanFailure(dir_path, err),
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch |err| return scanFailure(dir_path, err)) |entry| {
        if (remaining.* == 0) return;
        switch (entry.kind) {
            .directory => {
                if (isSkippedDir(entry.name)) continue;
                const child = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
                defer allocator.free(child);
                if (try isExcludedDir(allocator, child, excluded_canon)) continue;
                try scanDir(allocator, child, needles, consumed, remaining, excluded_canon);
            },
            .file, .sym_link => {
                if (!hasScannedExtension(entry.name)) continue;
                const child = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
                defer allocator.free(child);
                try scanFile(allocator, child, needles, consumed, remaining);
            },
            else => {},
        }
    }
}

/// Print the pointed loud-failure diagnostic and propagate `err`. The
/// message names the path and the escape hatch so a failing `generate`
/// is actionable without reading assembler source.
fn scanFailure(path: []const u8, err: anyerror) anyerror {
    std.debug.print(
        "labelle-assembler: plugin-event consumption scan failed on '{s}': {s}\n" ++
            "  an unreadable file cannot be proven consumer-free; fix it or set `.plugin_events = .all` in project.labelle\n",
        .{ path, @errorName(err) },
    );
    return err;
}

/// Stream-search one file for the not-yet-consumed needles. Chunked
/// (`scan_chunk_size`) with an overlap of (longest needle − 1) bytes
/// carried between windows, so a tag straddling a chunk boundary still
/// matches — no file size cap (see the file header). A file that no
/// longer exists (dangling symlink, deleted mid-walk) is skipped:
/// provably no content to miss. Other open/read failures propagate
/// loudly via `scanFailure`.
fn scanFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    needles: anytype,
    consumed: []bool,
    remaining: *usize,
) !void {
    const io = config.globalIo();
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return scanFailure(path, err),
    };
    defer file.close(io);

    // Overlap = longest needle − 1: any needle crossing the junction
    // between two reads is fully contained in the window that holds the
    // carried tail plus the new bytes.
    var max_needle: usize = 0;
    for (needles) |n| max_needle = @max(max_needle, @max(n.qualified.len, n.dotted.len));
    if (max_needle == 0) return;
    const overlap = max_needle - 1;

    const buf = try allocator.alloc(u8, scan_chunk_size + overlap);
    defer allocator.free(buf);

    var carry: usize = 0;
    while (true) {
        const n = file.readStreaming(io, &.{buf[carry..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return scanFailure(path, err),
        };
        // Blocking Io: 0 bytes without EndOfStream also means the
        // stream is drained.
        if (n == 0) break;
        const window = buf[0 .. carry + n];
        for (needles, consumed) |needle, *c| {
            if (c.*) continue;
            if (std.mem.indexOf(u8, window, needle.qualified) != null or
                std.mem.indexOf(u8, window, needle.dotted) != null)
            {
                c.* = true;
                remaining.* -= 1;
            }
        }
        if (remaining.* == 0) return;
        // Carry the tail into the next window. `copyForwards` is safe:
        // the destination starts at 0, at or before the source start.
        carry = @min(overlap, window.len);
        std.mem.copyForwards(u8, buf[0..carry], window[window.len - carry ..]);
    }
}

/// Whether `dir_path` names one of the canonicalized excluded roots.
/// Both sides go through `realpath` so a symlinked layout (or Windows
/// separators in the joined walk path) can't dodge the comparison. A
/// directory that fails to canonicalize is NOT excluded — `openDir`
/// will fail on it anyway, and treating it as excluded could silently
/// widen the exclusion. Only OOM propagates.
fn isExcludedDir(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    excluded_canon: []const []const u8,
) !bool {
    if (excluded_canon.len == 0) return false;
    const canon = std.Io.Dir.cwd().realPathFileAlloc(config.globalIo(), dir_path, allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer allocator.free(canon);
    for (excluded_canon) |ex| {
        if (std.mem.eql(u8, canon, ex)) return true;
    }
    return false;
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
    return filterConsumedEvents(allocator, &test_entries, &.{root}, &.{}, mode);
}

/// Same as `filterTmp` but with `sub_paths` (relative to the tmp root)
/// resolved and passed as excluded dependency roots — the in-tree
/// local-plugin shape (`@libs/box2d`) from the #631 review.
fn filterTmpExcluding(tmp: *testing.TmpDir, sub_paths: []const []const u8) !EventConsumption {
    const allocator = testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);

    var excluded_buf: [4][]const u8 = undefined;
    std.debug.assert(sub_paths.len <= excluded_buf.len);
    var n: usize = 0;
    defer for (excluded_buf[0..n]) |p| allocator.free(p);
    for (sub_paths) |sub| {
        excluded_buf[n] = try std.fs.path.join(allocator, &.{ root, sub });
        n += 1;
    }
    return filterConsumedEvents(allocator, &test_entries, &.{root}, excluded_buf[0..n], .consumed);
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
    var result = try filterConsumedEvents(allocator, &engine_entries, &.{root}, &.{}, .consumed);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.kept.len);
    try testing.expectEqualStrings("tick", result.kept[0].event_name);
    try testing.expectEqual(@as(usize, 1), result.elided.len);
    try testing.expectEqualStrings("game_init", result.elided[0].event_name);
}

/// The `emitGameEvent` call-site shape an in-tree plugin's own source
/// carries — it names the qualified tag textually, which is exactly why
/// dependency sources must be excluded from the consumer scan.
const in_tree_plugin_src =
    \\pub const Events = struct {
    \\    pub const collision_begin = struct { a: u32, b: u32 };
    \\    pub const collision_end = struct { a: u32, b: u32 };
    \\};
    \\pub fn emitContacts(game: anytype) void {
    \\    if (@hasField(@TypeOf(game.*).GameEvents, "box2d__collision_begin")) {
    \\        game.emit(.{ .box2d__collision_begin = .{ .a = 1, .b = 2 } });
    \\    }
    \\}
;

test "filterConsumedEvents: an in-tree plugin's own emit site does not count as consumption (#631 review)" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // `@libs/box2d`-shaped layout: the plugin source lives UNDER the
    // game dir and names its own tag at the emit site. With the resolved
    // dir excluded, no event may survive on the emit site's account.
    try tmp.dir.createDirPath(io, "libs/box2d/src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "libs/box2d/src/root.zig",
        .data = in_tree_plugin_src,
    });

    var result = try filterTmpExcluding(&tmp, &.{"libs/box2d"});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.kept.len);
    try testing.expectEqual(@as(usize, 2), result.elided.len);
}

test "filterConsumedEvents: a real consumer outside the excluded in-tree plugin still keeps the event (#631 review)" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "libs/box2d/src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "libs/box2d/src/root.zig",
        .data = in_tree_plugin_src,
    });
    // A genuine consumer in the game's own scripts.
    try tmp.dir.createDirPath(io, "scripts");
    try tmp.dir.writeFile(io, .{
        .sub_path = "scripts/contact.zig",
        .data =
        \\pub fn onEvent(game: anytype, event: anytype) void {
        \\    switch (event) {
        \\        .box2d__collision_begin => |e| game.handle(e),
        \\        else => {},
        \\    }
        \\}
        ,
    });

    var result = try filterTmpExcluding(&tmp, &.{"libs/box2d"});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.kept.len);
    try testing.expectEqualStrings("collision_begin", result.kept[0].event_name);
    try testing.expectEqual(@as(usize, 1), result.elided.len);
    try testing.expectEqualStrings("collision_end", result.elided[0].event_name);
}

test "filterConsumedEvents: tags in a file larger than the scan chunk are found (window-boundary straddle + tail) (#631 CodeRabbit)" {
    const io = testing.io;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "scripts");

    // ~600 KB file — more than two scan chunks. One tag placed to
    // straddle the first full-read window boundary (window 0 ends at
    // `scan_chunk_size + overlap` when reads fill the buffer; any
    // shorter read pattern is covered by the same overlap carry), one
    // tag at the very end of the file. The old 2 MB-skip behavior (or a
    // dropped overlap carry) would elide these — a silent
    // event-delivery break.
    const tag_straddle = "box2d__collision_begin"; // the longest needle
    const tag_tail = "box2d.collision_end";
    const overlap = tag_straddle.len - 1;
    const content = try allocator.alloc(u8, 600 * 1024);
    defer allocator.free(content);
    @memset(content, 'A');
    const straddle_pos = scan_chunk_size + overlap - 7; // 7 bytes before the window edge
    @memcpy(content[straddle_pos..][0..tag_straddle.len], tag_straddle);
    @memcpy(content[content.len - tag_tail.len ..], tag_tail);
    try tmp.dir.writeFile(io, .{ .sub_path = "scripts/huge_generated.json", .data = content });

    var result = try filterTmp(&tmp, .consumed);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.kept.len);
    try testing.expectEqual(@as(usize, 0), result.elided.len);
}

test "filterConsumedEvents: a stale generated file in a non-default output dir cannot ratchet events back (#631 CodeRabbit)" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Output dir named `out` — NOT `.labelle`, so the basename skip
    // doesn't catch it. Its stale generated main.zig names one tag as a
    // kept variant and one inside an elision comment; with the output
    // dir in the exclusion set (root.zig always adds it now), neither
    // may count as consumption — otherwise every once-discovered event
    // is retained forever (self-perpetuating ratchet).
    try tmp.dir.createDirPath(io, "out/null_desktop");
    try tmp.dir.writeFile(io, .{
        .sub_path = "out/null_desktop/main.zig",
        .data =
        \\pub const PluginEvents = union(enum) {
        \\    box2d__collision_begin: @import("box2d").Events.collision_begin,
        \\};
        \\// elided (no consumer): box2d__collision_end
        ,
    });

    var result = try filterTmpExcluding(&tmp, &.{"out"});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.kept.len);
    try testing.expectEqual(@as(usize, 2), result.elided.len);
}

test "filterConsumedEvents: a tag referenced only in tests/ is elided for the production target (tests/ excluded) (#631 codex)" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // tests/ feeds the separate `__tests_root.zig` target only — a
    // production build has no consumer here. root.zig excludes
    // `<game_dir>/tests` for non-tests targets.
    try tmp.dir.createDirPath(io, "tests");
    try tmp.dir.writeFile(io, .{
        .sub_path = "tests/contact_test.zig",
        .data =
        \\test "contact" {
        \\    const e = .{ .box2d__collision_begin = .{ .a = 1, .b = 2 } };
        \\    _ = e;
        \\}
        ,
    });

    var result = try filterTmpExcluding(&tmp, &.{"tests"});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.kept.len);
    try testing.expectEqual(@as(usize, 2), result.elided.len);
}

test "filterConsumedEvents: the TESTS-target pass keeps scanning tests/ so the referenced variant survives (#631 codex)" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Same fixture, no tests/ exclusion (root.zig only adds it when
    // `!is_tests_target`): the tests target must keep the variant so
    // the test file's reference compiles against its own GameEvents.
    try tmp.dir.createDirPath(io, "tests");
    try tmp.dir.writeFile(io, .{
        .sub_path = "tests/contact_test.zig",
        .data =
        \\test "contact" {
        \\    const e = .{ .box2d__collision_begin = .{ .a = 1, .b = 2 } };
        \\    _ = e;
        \\}
        ,
    });

    var result = try filterTmp(&tmp, .consumed);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.kept.len);
    try testing.expectEqualStrings("collision_begin", result.kept[0].event_name);
    try testing.expectEqual(@as(usize, 1), result.elided.len);
}

test "filterConsumedEvents: missing scan root is skipped silently" {
    const allocator = testing.allocator;
    var result = try filterConsumedEvents(
        allocator,
        &test_entries,
        &.{"/definitely/not/a/real/path/for/this/test"},
        &.{},
        .consumed,
    );
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.kept.len);
    try testing.expectEqual(@as(usize, 2), result.elided.len);
}
