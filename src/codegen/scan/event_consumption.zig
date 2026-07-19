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
//!
//! ── Ungated-emit force-keep (#630 follow-up) ─────────────────────────
//!
//! A provider that emits with raw union literals
//! (`game.emit(.{ .pathfinder__node_removed = ... })`) instead of a
//! `@hasField`-gated helper does not tolerate elision: its own source
//! stops compiling (`no field named ... in union`). `detectUngatedEmits`
//! scans each provider's own dir for its own tags in dot-prefixed form;
//! the caller feeds the matches into `force_consumed` so they are never
//! elided (see the fn docs for the discriminator + risk profile).

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
/// filter run. Either field may be EMPTY, meaning that form is skipped
/// (`scanFile` guards on `.len != 0` — `std.mem.indexOf` of "" would
/// match everywhere). The consumer pass fills both; the ungated-emit
/// provider pass (`detectUngatedEmits`) fills only `qualified` with the
/// dot-prefixed form (`.box2d__collision_begin`).
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

/// Whether `tag` spells exactly `e.plugin_sanitized ++ "__" ++
/// e.event_name` — slice-wise, no format buffer.
fn entryHasQualifiedTag(e: PluginEvent, tag: []const u8) bool {
    if (tag.len != e.plugin_sanitized.len + 2 + e.event_name.len) return false;
    if (!std.mem.startsWith(u8, tag, e.plugin_sanitized)) return false;
    if (tag[e.plugin_sanitized.len] != '_' or tag[e.plugin_sanitized.len + 1] != '_') return false;
    return std.mem.eql(u8, tag[e.plugin_sanitized.len + 2 ..], e.event_name);
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
/// `force_consumed`: qualified tags (`engine__editor_plugin_command`)
/// that are ALWAYS treated as consumed, regardless of what the text
/// scan finds. These are the RUNTIME-subscribed channels (#631 codex):
/// their handlers register at runtime (script-contract subscriptions,
/// plugin comptime hooks whose module source is deliberately excluded
/// as an emit-site), so no authored game text need ever name the tag —
/// the scan structurally cannot prove non-consumption for them. Each
/// entry in the caller's list documents where the runtime subscription
/// lives.
///
/// The returned struct borrows the entry STRINGS from `entries` (see
/// `EventConsumption`); the caller keeps ownership of the source list.
pub fn filterConsumedEvents(
    allocator: std.mem.Allocator,
    entries: []const PluginEvent,
    scan_roots: []const []const u8,
    excluded_roots: []const []const u8,
    force_consumed: []const []const u8,
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

    // Force-kept runtime channels are consumed before the walk starts —
    // and when they cover the whole discovery list the walk is skipped
    // entirely (`remaining == 0`).
    var remaining: usize = entries.len;
    for (entries, consumed) |e, *c| {
        for (force_consumed) |tag| {
            if (!entryHasQualifiedTag(e, tag)) continue;
            c.* = true;
            remaining -= 1;
            break;
        }
    }

    var walk: Walk = .{
        .allocator = allocator,
        .needles = needles,
        .consumed = consumed,
        .remaining = remaining,
        .excluded_canon = excluded_canon,
        .allowed_canon = allowed_canon,
    };
    defer {
        for (walk.visited.keys()) |k| allocator.free(k);
        walk.visited.deinit(allocator);
    }
    for (scan_roots) |root| {
        if (walk.remaining == 0) break;
        // Scan roots are never themselves `scripts/flows` (they are the
        // game dir and the staged `<target>/scripts` / `<target>/packs`).
        try enterDir(&walk, root, false);
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

/// One event PROVIDER's resolved module directory, input to
/// `detectUngatedEmits`. `import_name` is the key discovery stamped on
/// its entries (`PluginEvent.plugin_import_name` — the `project.labelle`
/// plugin name, or the literal `engine` for the engine pass); `dir` is
/// the resolved package/module root `discoverPluginEvents` walked.
pub const ProviderDir = struct {
    import_name: []const u8,
    dir: []const u8,
};

/// Detect which discovered events their own PROVIDER emits *ungated*
/// (labelle-assembler#630 follow-up — the flying-platform breakage on
/// v0.93.0).
///
/// #631's consumption filter assumed every plugin emits through a
/// comptime-gated helper (`@hasField(GameEvents, "<tag>")` — box2d's
/// `emitGameEvent`, the engine's `emitEngineEvent`) where an elided
/// variant folds the emit to a no-op. labelle-pathfinding instead
/// emits with raw anonymous union literals —
/// `game.emit(.{ .pathfinder__node_removed = .{ ... } })` — so eliding
/// the variant makes the PLUGIN SOURCE itself fail to compile
/// (`no field named 'pathfinder__node_removed' in union`) and breaks
/// `labelle build` for the whole game. Such tags must never be elided:
/// the caller feeds them into `filterConsumedEvents`'s
/// `force_consumed` set.
///
/// Discriminator: scan each provider's own resolved dir for the
/// provider's OWN qualified tags in DOT-PREFIXED form — the needle is
/// `"." ++ "<plugin>__<event>"`. The ungated union/enum-literal form
/// always spells that (`.pathfinder__node_removed`); the gated form
/// names the tag only inside string literals
/// (`"box2d__collision_begin"`), never with a leading dot.
///
/// Heuristic risk profile (a byte-before check, deliberately NOT a
/// tokenizer or AST walk):
///   - over-match (the tag written `.tag` in a doc comment) → the
///     event is force-kept → safe false positive: one extra kept
///     variant, i.e. the pre-#630 behavior for that event;
///   - over-match, GATED anonymous-literal style (PR #634 review):
///     `if (@hasField(GameEvents, "prov__ev")) {
///         game.emit(.{ .prov__ev = ... });
///     }` also matches — the dot-prefixed literal sits inside a
///     comptime-false branch Zig never analyzes when the variant is
///     absent, so this shape WOULD be safely elidable. Same safe
///     direction: force-kept, i.e. only the elision optimization is
///     lost for that event. Distinguishing it needs real comptime-flow
///     analysis (whether the guard's condition dominates the emit),
///     which is exactly the AST/semantic cleverness this scan
///     deliberately avoids; no shipped plugin uses the style (box2d
///     gates via string tags inside its `emitGameEvent` helper — the
///     dot form never appears). The `in_tree_plugin_src` test fixture
///     below spells this exact shape;
///   - under-match → the exact same loud "no field in union" compile
///     error the bug produces today — no NEW failure mode.
///
/// Per-provider scoping: provider A's dir is searched for A's tags
/// only. Another provider's tags appearing there (cross-plugin
/// consumers, docs) must NOT force-keep those — that would recreate
/// the emit-site false-consumption problem #631's dependency-root
/// exclusion fixed.
///
/// Same walk machinery, eligible-extension set, skipped-dir list, and
/// streamed chunk scan as the consumer pass; the needle carries its
/// leading dot, so the chunk-overlap math (longest needle − 1) covers
/// the dot-prefix check with no special case. Each provider dir is
/// walked once with only that provider's needles. A dir that doesn't
/// resolve/exist contributes nothing (same tolerance as discovery).
///
/// Returns a caller-owned bool slice parallel to `entries`: `true` =
/// the provider emits this tag ungated.
pub fn detectUngatedEmits(
    allocator: std.mem.Allocator,
    entries: []const PluginEvent,
    providers: []const ProviderDir,
) ![]bool {
    const ungated = try allocator.alloc(bool, entries.len);
    errdefer allocator.free(ungated);
    @memset(ungated, false);

    for (providers) |provider| {
        // This provider's own entries (usually all contiguous, but keep
        // it order-independent).
        var idxs: std.ArrayList(usize) = .empty;
        defer idxs.deinit(allocator);
        for (entries, 0..) |e, i| {
            if (std.mem.eql(u8, e.plugin_import_name, provider.import_name)) {
                try idxs.append(allocator, i);
            }
        }
        if (idxs.items.len == 0) continue;

        // One dot-prefixed needle per entry; `dotted` stays empty (the
        // consumer pass's dotted form has no meaning at an emit site).
        const needles = try allocator.alloc(Needles, idxs.items.len);
        var needles_built: usize = 0;
        defer {
            for (needles[0..needles_built]) |n| allocator.free(n.qualified);
            allocator.free(needles);
        }
        for (idxs.items, 0..) |entry_idx, j| {
            const e = entries[entry_idx];
            const dot_tag = try std.fmt.allocPrint(allocator, ".{s}__{s}", .{ e.plugin_sanitized, e.event_name });
            needles[j] = .{ .qualified = dot_tag, .dotted = "" };
            needles_built = j + 1;
        }

        const found = try allocator.alloc(bool, idxs.items.len);
        defer allocator.free(found);
        @memset(found, false);

        var walk: Walk = .{
            .allocator = allocator,
            .needles = needles,
            .consumed = found,
            .remaining = idxs.items.len,
            .excluded_canon = &.{},
            .allowed_canon = &.{},
        };
        defer {
            for (walk.visited.keys()) |k| allocator.free(k);
            walk.visited.deinit(allocator);
        }
        try enterDir(&walk, provider.dir, false);

        for (idxs.items, found) |entry_idx, f| {
            if (f) ungated[entry_idx] = true;
        }
    }
    return ungated;
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
fn enterDir(walk: *Walk, dir_path: []const u8, in_flows: bool) anyerror!void {
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
    try scanDir(walk, dir_path, in_flows);
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
fn scanDir(walk: *Walk, dir_path: []const u8, in_flows: bool) !void {
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
                try enterDir(walk, child, in_flows or isFlowsDir(dir_path, entry.name));
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
                    .directory => try enterDir(walk, child, in_flows or isFlowsDir(dir_path, entry.name)),
                    .file => {
                        if (!hasScannedExtension(entry.name)) continue;
                        if (in_flows and try isOrphanFlowSidecar(allocator, dir_path, entry.name)) continue;
                        try scanFile(walk, child);
                    },
                    else => {},
                }
            },
            .file => {
                if (!hasScannedExtension(entry.name)) continue;
                if (in_flows and try isOrphanFlowSidecar(allocator, dir_path, entry.name)) continue;
                const child = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
                defer allocator.free(child);
                try scanFile(walk, child);
            },
            else => {},
        }
    }
}

/// Whether descending from `parent_dir` into child dir `child_name`
/// enters the flow-sidecar convention dir — `scripts/flows` (RFC
/// FLOWS-JSONC §5). Basename comparisons only, so this is
/// path-separator agnostic; matches both the game dir's `scripts/flows`
/// and the staged `<target>/scripts` root's `flows` child (that root's
/// basename is `scripts`).
fn isFlowsDir(parent_dir: []const u8, child_name: []const u8) bool {
    return std.mem.eql(u8, child_name, "flows") and
        std.mem.eql(u8, std.fs.path.basename(parent_dir), "scripts");
}

/// Orphan-sidecar rule (#631 codex): inside `scripts/flows/**`, a
/// `<stem>.zig` is the GENERATED sidecar of `<stem>.flow.jsonc`
/// (`flow_scanner.scanAndEmit` writes `<rel_stem>.zig` next to its
/// source and never prunes) — so a `.zig` with NO sibling
/// `<stem>.flow.jsonc` is a stale leftover of a removed/renamed flow,
/// and its qualified tags would keep DEAD events alive forever. Skip
/// it. Paired sidecars stay in the corpus (harmless — their tags are
/// redundant with the source's dotted `OnEvent` refs). By the RFC
/// FLOWS-JSONC §5 convention `scripts/flows` holds only flow sources
/// and their emitted sidecars (authors .gitignore the emitted files),
/// so an unpaired `.zig` there is a stale sidecar, not a hand-authored
/// consumer. `flow_scanner.pruneStaleSidecars` (#632) deletes such
/// orphans at generate time using this same pairing rule (plus a
/// generated-header check); the skip here stays as defence in depth —
/// this scan can run against trees no flow scan has cleaned yet.
fn isOrphanFlowSidecar(allocator: std.mem.Allocator, dir_path: []const u8, file_name: []const u8) !bool {
    if (!std.mem.endsWith(u8, file_name, ".zig")) return false;
    const stem = file_name[0 .. file_name.len - ".zig".len];
    const source_name = try std.fmt.allocPrint(allocator, "{s}.flow.jsonc", .{stem});
    defer allocator.free(source_name);
    const source_path = try std.fs.path.join(allocator, &.{ dir_path, source_name });
    defer allocator.free(source_path);
    std.Io.Dir.cwd().access(config.globalIo(), source_path, .{}) catch return true;
    return false;
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
            // Empty needle = that form is unused for this entry (the
            // ungated-emit pass has no dotted form) — never a match.
            if ((needle.qualified.len != 0 and std.mem.indexOf(u8, window, needle.qualified) != null) or
                (needle.dotted.len != 0 and std.mem.indexOf(u8, window, needle.dotted) != null))
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
    return filterConsumedEvents(allocator, &test_entries, &.{root}, &.{}, &.{}, mode);
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
    return filterConsumedEvents(allocator, &test_entries, &.{root}, excluded_buf[0..n], &.{}, .consumed);
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
    var result = try filterConsumedEvents(allocator, &engine_entries, &.{root}, &.{}, &.{}, .consumed);
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
        &.{},
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

test "filterConsumedEvents: a force-kept runtime channel survives with NO textual mention anywhere (#631 codex)" {
    const io = testing.io;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Panel-bearing shape: nothing in the project names the tag — the
    // handler registers at RUNTIME (script-contract sub / plugin hook in
    // an excluded module source). The force list must keep it.
    try tmp.dir.createDirPath(io, "scripts");
    try tmp.dir.writeFile(io, .{
        .sub_path = "scripts/idle.zig",
        .data = "pub fn idle() void {}",
    });

    const entries = [_]PluginEvent{
        .{ .plugin_import_name = "engine", .plugin_sanitized = "engine", .event_name = "editor_plugin_command" },
        .{ .plugin_import_name = "engine", .plugin_sanitized = "engine", .event_name = "tick" },
    };
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var result = try filterConsumedEvents(
        allocator,
        &entries,
        &.{root},
        &.{},
        &.{"engine__editor_plugin_command"},
        .consumed,
    );
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.kept.len);
    try testing.expectEqualStrings("editor_plugin_command", result.kept[0].event_name);
    try testing.expectEqual(@as(usize, 1), result.elided.len);
    try testing.expectEqualStrings("tick", result.elided[0].event_name);
}

test "filterConsumedEvents: an ORPHANED flow sidecar (no sibling .flow.jsonc) cannot ratchet dead events (#631 codex)" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // `scripts/flows/dead.zig` is the stale generated sidecar of a
    // removed flow — no `dead.flow.jsonc` beside it. Its qualified tag
    // must not count as consumption.
    try tmp.dir.createDirPath(io, "scripts/flows");
    try tmp.dir.writeFile(io, .{
        .sub_path = "scripts/flows/dead.zig",
        .data = "// generated flow handler for box2d__collision_begin\n",
    });

    var result = try filterTmp(&tmp, .consumed);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.kept.len);
    try testing.expectEqual(@as(usize, 2), result.elided.len);
}

test "filterConsumedEvents: a PAIRED flow sidecar stays in the corpus (#631 codex)" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // `live.zig` has its `live.flow.jsonc` source beside it — a current
    // sidecar. The tag lives ONLY in the sidecar here (the source uses
    // no Event node reference) to isolate the pairing rule.
    try tmp.dir.createDirPath(io, "scripts/flows");
    try tmp.dir.writeFile(io, .{
        .sub_path = "scripts/flows/live.flow.jsonc",
        .data = "{ \"nodes\": [] }",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "scripts/flows/live.zig",
        .data = "// generated flow handler for box2d__collision_end\n",
    });

    var result = try filterTmp(&tmp, .consumed);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.kept.len);
    try testing.expectEqualStrings("collision_end", result.kept[0].event_name);
}

test "filterConsumedEvents: missing scan root is skipped silently" {
    const allocator = testing.allocator;
    var result = try filterConsumedEvents(
        allocator,
        &test_entries,
        &.{"/definitely/not/a/real/path/for/this/test"},
        &.{},
        &.{},
        .consumed,
    );
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.kept.len);
    try testing.expectEqual(@as(usize, 2), result.elided.len);
}

// ── Ungated-emit force-keep (#630 follow-up) ─────────────────────────

/// Two-event provider list for the `detectUngatedEmits` fixtures.
const ungated_test_entries = [_]PluginEvent{
    .{ .plugin_import_name = "prov", .plugin_sanitized = "prov", .event_name = "ev" },
    .{ .plugin_import_name = "prov", .plugin_sanitized = "prov", .event_name = "other" },
};

fn detectTmp(tmp: *testing.TmpDir, providers: []const struct { name: []const u8, sub: []const u8 }, entries: []const PluginEvent) ![]bool {
    const allocator = testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);

    var dirs_buf: [4]ProviderDir = undefined;
    std.debug.assert(providers.len <= dirs_buf.len);
    var n: usize = 0;
    defer for (dirs_buf[0..n]) |p| allocator.free(p.dir);
    for (providers) |p| {
        dirs_buf[n] = .{
            .import_name = p.name,
            .dir = try std.fs.path.join(allocator, &.{ root, p.sub }),
        };
        n += 1;
    }
    return detectUngatedEmits(allocator, entries, dirs_buf[0..n]);
}

test "detectUngatedEmits: dot-prefixed union-literal emit in the provider's own source flags the tag (#630 follow-up)" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // The pathfinder shape: a raw anonymous union literal, no
    // `@hasField` gate — eliding `prov__ev` would break this compile.
    try tmp.dir.createDirPath(io, "prov/src/nav");
    try tmp.dir.writeFile(io, .{
        .sub_path = "prov/src/nav/controller.zig",
        .data =
        \\pub fn removeNode(game: anytype, node_id: u32) void {
        \\    game.emit(.{ .prov__ev = .{ .node_id = node_id } });
        \\}
        ,
    });

    const flags = try detectTmp(&tmp, &.{.{ .name = "prov", .sub = "prov" }}, &ungated_test_entries);
    defer testing.allocator.free(flags);
    try testing.expectEqual(true, flags[0]);
    try testing.expectEqual(false, flags[1]);
}

test "detectUngatedEmits: string-literal (gated) reference does not flag — box2d-style elision benefit preserved" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // The gated shape: the tag appears only inside string literals
    // (`@hasField` / `@unionInit`), never dot-prefixed. Elision stays
    // available for it.
    try tmp.dir.createDirPath(io, "prov/src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "prov/src/root.zig",
        .data =
        \\pub fn emitEv(game: anytype, payload: anytype) void {
        \\    if (@hasField(@TypeOf(game.*).GameEvents, "prov__ev")) {
        \\        game.emit(@unionInit(@TypeOf(game.*).GameEvents, "prov__ev", payload));
        \\    }
        \\}
        ,
    });

    const flags = try detectTmp(&tmp, &.{.{ .name = "prov", .sub = "prov" }}, &ungated_test_entries);
    defer testing.allocator.free(flags);
    try testing.expectEqual(false, flags[0]);
    try testing.expectEqual(false, flags[1]);
}

test "detectUngatedEmits: dot-prefixed occurrence inside a doc comment flags (documented safe over-match)" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Byte-before-is-'.' is deliberately not a tokenizer: a doc comment
    // spelling `.prov__ev` over-matches, which force-KEEPS the variant —
    // the safe direction (pre-#630 behavior for that one event).
    try tmp.dir.createDirPath(io, "prov/src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "prov/src/root.zig",
        .data =
        \\/// Fires `.prov__ev` when a node vanishes.
        \\pub fn removeNode() void {}
        ,
    });

    const flags = try detectTmp(&tmp, &.{.{ .name = "prov", .sub = "prov" }}, &ungated_test_entries);
    defer testing.allocator.free(flags);
    try testing.expectEqual(true, flags[0]);
    try testing.expectEqual(false, flags[1]);
}

test "detectUngatedEmits: another provider's tag in the dir does not flag it (per-provider scoping)" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Provider A's source references provider B's tag dot-prefixed (a
    // cross-plugin consumer/emit site). B's dir has no such reference.
    // Only A's OWN tags may be flagged from A's dir — anything else
    // recreates the #631 emit-site false-consumption problem.
    try tmp.dir.createDirPath(io, "prova/src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "prova/src/root.zig",
        .data =
        \\pub fn onEvent(game: anytype, event: anytype) void {
        \\    switch (event) {
        \\        .provb__ev => |e| game.handle(e),
        \\        else => {},
        \\    }
        \\}
        ,
    });
    try tmp.dir.createDirPath(io, "provb/src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "provb/src/root.zig",
        .data = "pub const Events = struct { pub const ev = struct {} };",
    });

    const entries = [_]PluginEvent{
        .{ .plugin_import_name = "prova", .plugin_sanitized = "prova", .event_name = "ev" },
        .{ .plugin_import_name = "provb", .plugin_sanitized = "provb", .event_name = "ev" },
    };
    const flags = try detectTmp(&tmp, &.{
        .{ .name = "prova", .sub = "prova" },
        .{ .name = "provb", .sub = "provb" },
    }, &entries);
    defer testing.allocator.free(flags);
    try testing.expectEqual(false, flags[0]);
    try testing.expectEqual(false, flags[1]);
}

test "detectUngatedEmits: missing provider dir contributes nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const flags = try detectTmp(&tmp, &.{.{ .name = "prov", .sub = "does_not_exist" }}, &ungated_test_entries);
    defer testing.allocator.free(flags);
    try testing.expectEqual(false, flags[0]);
    try testing.expectEqual(false, flags[1]);
}

test "detectUngatedEmits + filterConsumedEvents: ungated tag with no consumer anywhere is force-kept end-to-end (#630 follow-up)" {
    const io = testing.io;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // In-tree provider emitting `prov__ev` ungated; the game itself
    // never names either tag. `prov__ev` must survive via the force
    // set; `prov__other` (declared, never referenced) is still elided —
    // the box2d-style benefit is preserved for gated/unused tags.
    try tmp.dir.createDirPath(io, "libs/prov/src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "libs/prov/src/root.zig",
        .data =
        \\pub fn removeNode(game: anytype, node_id: u32) void {
        \\    game.emit(.{ .prov__ev = .{ .node_id = node_id } });
        \\}
        ,
    });
    try tmp.dir.createDirPath(io, "scripts");
    try tmp.dir.writeFile(io, .{
        .sub_path = "scripts/idle.zig",
        .data = "pub fn idle() void {}",
    });

    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const prov_dir = try std.fs.path.join(allocator, &.{ root, "libs", "prov" });
    defer allocator.free(prov_dir);

    const flags = try detectUngatedEmits(
        allocator,
        &ungated_test_entries,
        &.{.{ .import_name = "prov", .dir = prov_dir }},
    );
    defer allocator.free(flags);

    var force_tags: std.ArrayList([]const u8) = .empty;
    defer {
        for (force_tags.items) |t| allocator.free(t);
        force_tags.deinit(allocator);
    }
    for (ungated_test_entries, flags) |e, is_ungated| {
        if (!is_ungated) continue;
        const tag = try std.fmt.allocPrint(allocator, "{s}__{s}", .{ e.plugin_sanitized, e.event_name });
        errdefer allocator.free(tag);
        try force_tags.append(allocator, tag);
    }

    // The provider dir is an excluded dependency root, exactly like the
    // real wiring — the force set, not the text scan, must carry it.
    var result = try filterConsumedEvents(
        allocator,
        &ungated_test_entries,
        &.{root},
        &.{prov_dir},
        force_tags.items,
        .consumed,
    );
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.kept.len);
    try testing.expectEqualStrings("ev", result.kept[0].event_name);
    try testing.expectEqual(@as(usize, 1), result.elided.len);
    try testing.expectEqualStrings("other", result.elided[0].event_name);
}
