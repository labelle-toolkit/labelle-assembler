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
//! projects. Exclusion is a closed-form longest-match allow/deny
//! predicate over CANONICAL paths (`exclusionVerdict`) — `realpath` on
//! both sides, so it is symlink- and path-separator-robust (no raw
//! string comparison of joined paths with mixed separators): a walked
//! directory equal to or under an excluded root is skipped with its
//! whole subtree (a symlink can jump into the MIDDLE of an excluded
//! tree), UNLESS a deeper scan root re-allows it — the staged
//! `<target>/scripts` / `<target>/packs` roots live inside the excluded
//! output dir by design. Deliberate asymmetry: a local plugin's
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

/// One discovery entry's two search needles, precomputed once per
/// filter run.
const Needles = struct {
    qualified: []const u8, // box2d__collision_begin
    dotted: []const u8, // box2d.collision_begin
};

/// Shared state for one `filterConsumedEvents` walk, threaded through
/// `enterDir` / `scanDir` / `scanFile` instead of six positional params.
const Walk = struct {
    allocator: std.mem.Allocator,
    needles: []const Needles,
    consumed: []bool,
    /// Count of not-yet-consumed entries — the walk early-exits at 0.
    remaining: usize,
    excluded_canon: []const []const u8,
    /// Canonicalized SCAN roots — the allow half of the longest-match
    /// allow/deny predicate (`exclusionVerdict`). The explicit staged
    /// roots (`<target>/scripts`, `<target>/packs`) live INSIDE the
    /// excluded output dir; being deeper (more specific) than the
    /// output-dir deny rule, they and their subtrees stay scanned.
    allowed_canon: []const []const u8,
    /// Canonical path of every directory already entered. Cycle
    /// protection for FOLLOWED directory symlinks (#631 codex — a
    /// symlink loop must terminate), and a harmless dedupe of the POSIX
    /// `<target>/scripts`-symlink double-scan. Keys are walk-owned
    /// dupes, freed by `filterConsumedEvents`.
    visited: std.StringArrayHashMapUnmanaged(void) = .empty,
};

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

    // Canonicalize the scan roots the same way — they are the ALLOW half
    // of the longest-match predicate (see `exclusionVerdict`). A root
    // that doesn't resolve contributes nothing (it won't be walked
    // either — missing roots are skipped silently).
    const allowed = try allocator.alloc([]const u8, scan_roots.len);
    var allowed_len: usize = 0;
    defer {
        for (allowed[0..allowed_len]) |p| allocator.free(p);
        allocator.free(allowed);
    }
    for (scan_roots) |root| {
        const canon_z = std.Io.Dir.cwd().realPathFileAlloc(io, root, allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer allocator.free(canon_z);
        allowed[allowed_len] = try allocator.dupe(u8, canon_z);
        allowed_len += 1;
    }
    const allowed_canon = allowed[0..allowed_len];

    // Precompute both needles per entry once — the scan is
    // O(files × unconsumed entries).
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

    var walk: Walk = .{
        .allocator = allocator,
        .needles = needles,
        .consumed = consumed,
        .remaining = entries.len,
        .excluded_canon = excluded_canon,
        .allowed_canon = allowed_canon,
    };
    defer {
        for (walk.visited.keys()) |k| allocator.free(k);
        walk.visited.deinit(allocator);
    }
    for (scan_roots) |root| {
        if (walk.remaining == 0) break;
        try enterDir(&walk, root);
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

/// Gatekeeper for descending into a directory — a real one, a scan
/// root, or a FOLLOWED directory symlink. Canonicalizes the path once
/// and, against the RESOLVED path: applies the longest-match allow/deny
/// predicate (`exclusionVerdict` — a symlink pointing INTO an excluded
/// dependency dir, or at any CHILD of one, must not smuggle it back
/// into the corpus, while the staged scan roots INSIDE the excluded
/// output dir stay scanned), then the visited set
/// (symlink-cycle protection — and a harmless dedupe of the POSIX
/// `<target>/scripts` double-scan). A path that fails to canonicalize
/// because nothing is there (missing root, dangling link, loop) is
/// skipped silently — provably no content; other failures are loud per
/// the file-header error policy.
fn enterDir(walk: *Walk, dir_path: []const u8) anyerror!void {
    // `anyerror`: enterDir ⇄ scanDir are mutually recursive (a followed
    // dir symlink re-enters the gate), so one of the pair must break
    // the inferred-error-set dependency loop with an explicit set.
    const allocator = walk.allocator;
    const canon_z = std.Io.Dir.cwd().realPathFileAlloc(config.globalIo(), dir_path, allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound, error.NotDir, error.SymLinkLoop => return,
        else => return scanFailure(dir_path, err),
    };
    defer allocator.free(canon_z);

    if (exclusionVerdict(canon_z, walk.excluded_canon, walk.allowed_canon)) return;
    if (walk.visited.contains(canon_z)) return;
    {
        // The map owns its keys (freed by `filterConsumedEvents`) —
        // dupe to a plain []u8 so the free doesn't hit the [:0]
        // sentinel-byte size mismatch.
        const key = try allocator.dupe(u8, canon_z);
        errdefer allocator.free(key);
        try walk.visited.put(allocator, key, {});
    }
    try scanDir(walk, dir_path);
}

/// The closed-form exclusion predicate, longest-match allow/deny over
/// CANONICAL paths: `canon` is excluded when its most specific (longest)
/// matching EXCLUDED root is deeper than its most specific matching
/// SCAN root. "Matching" means equals-or-is-under with an explicit
/// path-separator boundary (`isOrUnder`), so `/a/libs/box2d2` does not
/// match an excluded `/a/libs/box2d`; both sides went through
/// `realpath`, so the compare — including the `std.fs.path.sep`
/// boundary byte — stays correct on Windows, where canonical paths use
/// backslashes.
///
/// Why descendants must be covered at all (#631 codex): the walk stops
/// AT an excluded root, so a descendant can only be reached by a
/// symlink jumping into the middle of the excluded tree (`vendored_src`
/// → `libs/box2d/src`, `generated` → `out/raylib`) — which
/// canonicalizes to the CHILD path and would match no root under exact
/// equality, re-admitting plugin emit sites or stale generated output.
///
/// Why the ALLOW half exists: the explicit staged scan roots
/// (`<target>/scripts`, `<target>/packs`) are themselves strict
/// descendants of the excluded OUTPUT dir — a plain is-or-under deny
/// would swallow the staged corpus (published packs' hooks live ONLY
/// there, and on Windows the copied plugin scripts do too). Deeper
/// rule wins, so the staged roots and their subtrees stay scanned
/// while the rest of the output dir (stale main.zig, deps/, stale
/// sibling targets) stays out; within the game dir, a dependency root
/// (deeper than the game-dir scan root) still denies its subtree.
fn exclusionVerdict(
    canon: []const u8,
    excluded_canon: []const []const u8,
    allowed_canon: []const []const u8,
) bool {
    const ex = longestMatch(canon, excluded_canon) orelse return false;
    const al = longestMatch(canon, allowed_canon) orelse return true;
    return ex > al;
}

/// Length of the longest root in `roots` that `canon` equals or sits
/// under (separator-boundary checked), or null when none matches.
fn longestMatch(canon: []const u8, roots: []const []const u8) ?usize {
    var best: ?usize = null;
    for (roots) |root| {
        if (!isOrUnder(canon, root)) continue;
        if (best == null or root.len > best.?) best = root.len;
    }
    return best;
}

/// Whether `canon` equals `root` or is a strict descendant of it. The
/// byte after the root prefix must be a separator (or the root itself
/// ends in one — the filesystem root), otherwise a sibling sharing the
/// name prefix would false-match.
fn isOrUnder(canon: []const u8, root: []const u8) bool {
    if (!std.mem.startsWith(u8, canon, root)) return false;
    if (canon.len == root.len) return true;
    if (root.len > 0 and root[root.len - 1] == std.fs.path.sep) return true;
    return canon[root.len] == std.fs.path.sep;
}

/// Recursive walk of one directory (callers go through `enterDir`,
/// which owns the canonical-path gating). Error policy (see file
/// header): a missing directory (dangling symlink, entry deleted
/// mid-walk) is skipped silently — nothing on disk means no consumer to
/// miss. Every OTHER I/O failure propagates loudly with a pointed
/// diagnostic: an incomplete scan silently treated as "no consumer"
/// would elide a live subscription and break event delivery.
fn scanDir(walk: *Walk, dir_path: []const u8) !void {
    const allocator = walk.allocator;
    const io = config.globalIo();
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        // Mid-walk deletion (`enterDir` already screened the path) — no
        // content, no possible false negative.
        error.FileNotFound, error.NotDir => return,
        else => return scanFailure(dir_path, err),
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch |err| return scanFailure(dir_path, err)) |entry| {
        if (walk.remaining == 0) return;
        switch (entry.kind) {
            .directory => {
                if (isSkippedDir(entry.name)) continue;
                const child = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
                defer allocator.free(child);
                try enterDir(walk, child);
            },
            .sym_link => {
                // A symlinked convention dir (`hooks/` → a real dir
                // elsewhere) is a fully compiled part of the build —
                // `scanner.linkAndScan` follows it — so the consumption
                // walk must follow it too (#631 codex): treating every
                // symlink as a FILE made such a dir's consumers
                // invisible and silently elided their events. Resolve
                // the target's kind and dispatch; `enterDir` re-applies
                // the excluded-roots check on the RESOLVED path and the
                // visited set breaks symlink cycles.
                if (isSkippedDir(entry.name)) continue;
                const child = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
                defer allocator.free(child);
                const st = std.Io.Dir.cwd().statFile(io, child, .{}) catch |err| switch (err) {
                    // Dangling or self-looping link — no reachable
                    // content, provably no consumer.
                    error.FileNotFound, error.NotDir, error.SymLinkLoop => continue,
                    else => return scanFailure(child, err),
                };
                switch (st.kind) {
                    .directory => try enterDir(walk, child),
                    .file => {
                        if (!hasScannedExtension(entry.name)) continue;
                        try scanFile(walk, child);
                    },
                    else => {},
                }
            },
            .file => {
                if (!hasScannedExtension(entry.name)) continue;
                const child = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
                defer allocator.free(child);
                try scanFile(walk, child);
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
/// longer exists (dangling symlink, deleted mid-walk) or self-loops is
/// skipped: provably no content to miss. Other open/read failures
/// propagate loudly via `scanFailure`.
fn scanFile(walk: *Walk, path: []const u8) !void {
    const allocator = walk.allocator;
    const io = config.globalIo();
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.SymLinkLoop => return,
        else => return scanFailure(path, err),
    };
    defer file.close(io);

    // Overlap = longest needle − 1: any needle crossing the junction
    // between two reads is fully contained in the window that holds the
    // carried tail plus the new bytes.
    var max_needle: usize = 0;
    for (walk.needles) |n| max_needle = @max(max_needle, @max(n.qualified.len, n.dotted.len));
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
        for (walk.needles, walk.consumed) |needle, *c| {
            if (c.*) continue;
            if (std.mem.indexOf(u8, window, needle.qualified) != null or
                std.mem.indexOf(u8, window, needle.dotted) != null)
            {
                c.* = true;
                walk.remaining -= 1;
            }
        }
        if (walk.remaining == 0) return;
        // Carry the tail into the next window. `copyForwards` is safe:
        // the destination starts at 0, at or before the source start.
        carry = @min(overlap, window.len);
        std.mem.copyForwards(u8, buf[0..carry], window[window.len - carry ..]);
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

test "filterConsumedEvents: a consumer inside a SYMLINKED convention dir is found (dir symlinks followed) (#631 codex)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The game keeps `hooks/` as a symlink to a real dir elsewhere —
    // `scanner.linkAndScan` follows it and compiles the hook, so the
    // consumption walk must see the consumer too. Pre-fix the `.sym_link`
    // entry was treated as a FILE and never descended into.
    try tmp.dir.createDirPath(io, "real_hooks");
    try tmp.dir.writeFile(io, .{
        .sub_path = "real_hooks/contact.zig",
        .data =
        \\pub fn onEvent(game: anytype, event: anytype) void {
        \\    switch (event) {
        \\        .box2d__collision_begin => |e| game.handle(e),
        \\        else => {},
        \\    }
        \\}
        ,
    });
    const real_abs = try tmp.dir.realPathFileAlloc(io, "real_hooks", allocator);
    defer allocator.free(real_abs);
    try tmp.dir.symLink(io, real_abs, "hooks", .{ .is_directory = true });

    var result = try filterTmp(&tmp, .consumed);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.kept.len);
    try testing.expectEqualStrings("collision_begin", result.kept[0].event_name);
}

test "filterConsumedEvents: a directory-symlink loop terminates (visited-set cycle protection) (#631 codex)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // a/loop → tmp root: following it revisits the root — without the
    // canonical-path visited set the walk would recurse forever.
    try tmp.dir.createDirPath(io, "a");
    const root_abs = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_abs);
    try tmp.dir.symLink(io, root_abs, "a/loop", .{ .is_directory = true });
    try tmp.dir.writeFile(io, .{
        .sub_path = "a/consumer.zig",
        .data = "// subscribes: box2d__collision_end\n",
    });

    var result = try filterTmp(&tmp, .consumed);
    defer result.deinit();
    // Terminates AND still finds the real consumer next to the loop.
    try testing.expectEqual(@as(usize, 1), result.kept.len);
    try testing.expectEqualStrings("collision_end", result.kept[0].event_name);
}

test "filterConsumedEvents: a symlink INTO an excluded dependency root cannot smuggle it back in (#631 codex)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // In-tree plugin source (excluded) with its emit-site tag; the game
    // also carries `vendored/` → that same plugin dir. The exclusion is
    // checked against the RESOLVED canonical path, so following the
    // symlink must not re-admit the dependency source.
    try tmp.dir.createDirPath(io, "libs/box2d/src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "libs/box2d/src/root.zig",
        .data = in_tree_plugin_src,
    });
    const dep_abs = try tmp.dir.realPathFileAlloc(io, "libs/box2d", allocator);
    defer allocator.free(dep_abs);
    try tmp.dir.symLink(io, dep_abs, "vendored", .{ .is_directory = true });

    var result = try filterTmpExcluding(&tmp, &.{"libs/box2d"});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.kept.len);
    try testing.expectEqual(@as(usize, 2), result.elided.len);
}

test "filterConsumedEvents: a symlink to a CHILD of an excluded root cannot smuggle it back in (ancestor-aware exclusion) (#631 codex)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The excluded root is `libs/box2d`; the game carries a symlink to
    // its CHILD `libs/box2d/src`. `realpath` resolves the link to the
    // child path, which matches no root under exact equality — the
    // ancestor-aware predicate must still keep the emit-site source out.
    try tmp.dir.createDirPath(io, "libs/box2d/src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "libs/box2d/src/root.zig",
        .data = in_tree_plugin_src,
    });
    const child_abs = try tmp.dir.realPathFileAlloc(io, "libs/box2d/src", allocator);
    defer allocator.free(child_abs);
    try tmp.dir.symLink(io, child_abs, "vendored_src", .{ .is_directory = true });

    var result = try filterTmpExcluding(&tmp, &.{"libs/box2d"});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.kept.len);
    try testing.expectEqual(@as(usize, 2), result.elided.len);
}

test "filterConsumedEvents: a sibling sharing the excluded root's name prefix is scanned normally (boundary check) (#631 codex)" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // `libs/box2d2` is NOT under excluded `libs/box2d` — a bare prefix
    // match without the separator-boundary check would false-exclude it
    // and elide its genuine consumer.
    try tmp.dir.createDirPath(io, "libs/box2d/src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "libs/box2d/src/root.zig",
        .data = in_tree_plugin_src,
    });
    try tmp.dir.createDirPath(io, "libs/box2d2");
    try tmp.dir.writeFile(io, .{
        .sub_path = "libs/box2d2/consumer.zig",
        .data = "// subscribes: box2d__collision_begin\n",
    });

    var result = try filterTmpExcluding(&tmp, &.{"libs/box2d"});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.kept.len);
    try testing.expectEqualStrings("collision_begin", result.kept[0].event_name);
    try testing.expectEqual(@as(usize, 1), result.elided.len);
}

test "filterConsumedEvents: an explicit scan root INSIDE the excluded output dir is still scanned (staged corpus) (#631 regression)" {
    const io = testing.io;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The staged-pack shape: the output dir `out` is excluded (stale
    // generated files), but `out/target/packs` is an explicit scan root
    // — for published packs it is the ONLY place their hooks exist. The
    // longest-match predicate must let the deeper scan root win over
    // the shallower output-dir deny.
    try tmp.dir.createDirPath(io, "out/target/packs/fakepack/hooks");
    try tmp.dir.writeFile(io, .{
        .sub_path = "out/target/packs/fakepack/hooks/contact.zig",
        .data = "// subscribes: box2d__collision_begin\n",
    });
    // Stale generated output BESIDE the staged root stays excluded.
    try tmp.dir.writeFile(io, .{
        .sub_path = "out/target/main.zig",
        .data = "// elided (no consumer): box2d__collision_end\n",
    });

    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const out_dir = try std.fs.path.join(allocator, &.{ root, "out" });
    defer allocator.free(out_dir);
    const packs_root = try std.fs.path.join(allocator, &.{ root, "out", "target", "packs" });
    defer allocator.free(packs_root);

    var result = try filterConsumedEvents(
        allocator,
        &test_entries,
        &.{ root, packs_root },
        &.{out_dir},
        .consumed,
    );
    defer result.deinit();
    // The staged hook keeps collision_begin; the stale main.zig outside
    // the allowed root cannot ratchet collision_end back.
    try testing.expectEqual(@as(usize, 1), result.kept.len);
    try testing.expectEqualStrings("collision_begin", result.kept[0].event_name);
    try testing.expectEqual(@as(usize, 1), result.elided.len);
    try testing.expectEqualStrings("collision_end", result.elided[0].event_name);
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
