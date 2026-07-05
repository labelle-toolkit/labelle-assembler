//! Generate-time pack dependency validation — labelle-assembler#441
//! (Packs RFC §6, "Generate-time validation (the gate)").
//!
//! A *pack* (`pack.labelle`, #439) declares `depends_on` — the packs it
//! may query (the downward edges of the pack dependency DAG, RFC §6).
//! Before `labelle generate` emits anything, this pass reads every
//! declared pack's `depends_on` and FAILS generation on:
//!
//!   1. **unknown dependency** — a `depends_on` naming a pack/plugin that
//!      isn't declared in `project.labelle` (and isn't the implicit
//!      `contracts` root). → `error.PackUnknownDependency`
//!   2. **dependency cycle** — `depends_on` across packs must form an
//!      acyclic graph. A proper DFS reports the offending cycle path.
//!      → `error.PackDependencyCycle`
//!
//! This is the "gate" layer of RFC §6's enforcement stack. It does NOT
//! implement the depends_on ENFORCEMENT (the restricted per-pack module
//! graph / `PackView` registry partition) — that is engine-side
//! #652-remainder. The "one-facet-one-owner" duplicate-component check
//! from the RFC is mooted by #440's `<pack>__` name prefix (registry
//! names become pack-unique) and is intentionally not implemented here.
//!
//! The core `validate` function is pure (data in, error out) so it can be
//! unit-tested without touching the filesystem; `root.zig` gathers the
//! `PackDep` view from the loaded `PackManifest`s and calls it.

const std = @import("std");
const scan = @import("codegen/scan.zig");
const idents = @import("codegen/idents.zig");

/// The dependency view of one pack: its name and the pack names it
/// declares depending on. Borrows its strings from the caller (typically
/// the live `PackManifest`s) — this struct owns nothing.
pub const PackDep = struct {
    name: []const u8,
    depends_on: []const []const u8,
};

/// Dependency targets every pack may name without declaring them —
/// `contracts` is the implicit shared-vocabulary root (RFC §6). Listing
/// it in `depends_on` is allowed but never required, and it is treated as
/// a leaf (no outgoing edges) for the cycle check.
pub const IMPLICIT_DEPS = [_][]const u8{"contracts"};

fn isImplicit(name: []const u8) bool {
    for (IMPLICIT_DEPS) |d| {
        if (std.mem.eql(u8, d, name)) return true;
    }
    return false;
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| {
        if (std.mem.eql(u8, h, needle)) return true;
    }
    return false;
}

/// Validate the pack dependency graph. `packs` is the `depends_on` view
/// of every declared pack; `declared_names` is the set of names that may
/// legally appear in a `depends_on` (in practice, every plugin/pack name
/// in `project.labelle`).
///
/// Returns:
///   - `error.PackUnknownDependency` if any `depends_on` names something
///     not in `declared_names` and not implicit (`contracts`).
///   - `error.PackDependencyCycle` if the `depends_on` edges among packs
///     contain a cycle.
pub fn validate(
    allocator: std.mem.Allocator,
    packs: []const PackDep,
    declared_names: []const []const u8,
) !void {
    try checkUnknownDeps(packs, declared_names);
    try checkAcyclic(allocator, packs);
}

// ── Sanitized-prefix collision check (#440 / CodeRabbit) ───────────

/// Reject two packs whose `name` sanitizes to the SAME `<pack>__` namespace
/// prefix. A pack's `name` feeds `scan.packNamespacePrefix` (codegen), which
/// sanitizes it into a Zig-ident fragment — so `my-pack` and `my_pack` both
/// namespace to `my_pack__…`. Left unchecked, two such packs would emit
/// duplicate `<pack>__…` symbols and break the generated imports, registries,
/// and hook tuples. This gate runs at generate time, before any target is
/// written, so a collision fails cheaply with a clear diagnostic.
///
/// `names` is the set of pack names AS FED TO `scanPack` (i.e. the pack's
/// plugin name in `project.labelle`, which becomes `PackScan.name` and drives
/// the codegen prefix) — pass the same value here so the check matches the
/// symbols actually emitted. Pure (data in, error out); the O(n²) compare is
/// fine for the handful of packs a project declares.
///
/// Returns `error.PackNamePrefixCollision` naming both offending packs.
pub fn checkPrefixCollisions(names: []const []const u8) !void {
    var buf_a: [128]u8 = undefined;
    var buf_b: [128]u8 = undefined;
    for (names, 0..) |name_a, i| {
        const prefix_a = scan.packNamespacePrefix(name_a, &buf_a);
        for (names[i + 1 ..]) |name_b| {
            const prefix_b = scan.packNamespacePrefix(name_b, &buf_b);
            if (std.mem.eql(u8, prefix_a, prefix_b)) {
                std.log.warn(
                    "labelle: pack name collision: '{s}' and '{s}' both namespace to '{s}__'.\n" ++
                        "  each pack's name must sanitize to a UNIQUE Zig-ident prefix — two packs\n" ++
                        "  sharing a prefix emit duplicate `<pack>__…` symbols and break the\n" ++
                        "  generated imports/registries/hook tuples. rename one of the packs.\n",
                    .{ name_a, name_b, prefix_a },
                );
                return error.PackNamePrefixCollision;
            }
        }
    }
}

// ── Emitted-name injectivity check (#440 / chatgpt-codex events L164) ──

/// One emitted registry identifier plus a human-readable origin, used by
/// `checkEmittedNameCollisions` to report which two sources collide.
const EmittedItem = struct { emitted: []const u8, origin: []const u8 };

/// Reject any two sources that fold to the SAME emitted registry identifier
/// after pack namespacing (#440). The `<pack>__<name>` scheme is not injective
/// on its own — pack `a` shipping `events/b__hit.zig` and pack `a__b` shipping
/// `events/hit.zig` both emit the event tag `a__b__hit`, and the
/// sanitized-prefix gate (`checkPrefixCollisions`) misses it because `a` and
/// `a__b` are distinct prefixes. Rather than escape the `__` delimiter (which
/// would change every on-disk save key and every emitted symbol), this validates
/// the FULLY-QUALIFIED emitted names directly — the most maintainable option,
/// and it also catches pack-internal basename clashes for subdir prefabs
/// (`enemies/goblin` + `allies/goblin` → `<pack>__goblin` twice).
///
/// Checks three independent registry namespaces (component fields, event
/// variant tags, prefab registration keys), each exactly as the block-writers
/// emit them. Runs at generate time, before any target is written. Returns
/// `error.PackEmittedNameCollision` naming both offending sources.
///
/// Plugin-declared events (`<plugin>__<event>`) are not folded in here — a
/// pack/plugin name overlap surfaces at compile time via `MergeHookPayloads`'
/// duplicate-field check; this gate covers the game-root + pack sources whose
/// collisions would otherwise slip past the prefix gate.
pub fn checkEmittedNameCollisions(
    gpa: std.mem.Allocator,
    component_names: []const []const u8,
    event_names: []const []const u8,
    prefab_names: []const []const u8,
    pack_scans: []const scan.PackScan,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var comps: std.ArrayList(EmittedItem) = .empty;
    var events: std.ArrayList(EmittedItem) = .empty;
    var prefabs: std.ArrayList(EmittedItem) = .empty;

    var pascal_buf: [128]u8 = undefined;
    var prefix_buf: [128]u8 = undefined;

    // Game-root sources — emitted bare (component `<Pascal>`, event
    // `<variant>`, prefab `<basename>`), matching the block-writers.
    for (component_names) |name| {
        const pascal = idents.pathToPascal(name, &pascal_buf);
        try comps.append(a, .{ .emitted = try a.dupe(u8, pascal), .origin = name });
    }
    for (event_names) |name| {
        try events.append(a, .{ .emitted = try a.dupe(u8, idents.eventVariantName(name)), .origin = name });
    }
    for (prefab_names) |name| {
        try prefabs.append(a, .{ .emitted = try a.dupe(u8, std.fs.path.basename(name)), .origin = name });
    }

    // Pack sources — emitted under the invisible `<prefix>__` namespace.
    for (pack_scans) |pack| {
        const prefix = scan.packNamespacePrefix(pack.name, &prefix_buf);
        for (pack.component_names) |name| {
            const pascal = idents.pathToPascal(name, &pascal_buf);
            try comps.append(a, .{
                .emitted = try std.fmt.allocPrint(a, "{s}__{s}", .{ prefix, pascal }),
                .origin = try std.fmt.allocPrint(a, "pack '{s}' component '{s}'", .{ pack.name, name }),
            });
        }
        for (pack.event_names) |name| {
            try events.append(a, .{
                .emitted = try std.fmt.allocPrint(a, "{s}__{s}", .{ prefix, idents.eventVariantName(name) }),
                .origin = try std.fmt.allocPrint(a, "pack '{s}' event '{s}'", .{ pack.name, name }),
            });
        }
        for (pack.prefab_names) |name| {
            try prefabs.append(a, .{
                .emitted = try std.fmt.allocPrint(a, "{s}__{s}", .{ prefix, std.fs.path.basename(name) }),
                .origin = try std.fmt.allocPrint(a, "pack '{s}' prefab '{s}'", .{ pack.name, name }),
            });
        }
    }

    try reportEmittedDup("component", comps.items);
    try reportEmittedDup("event", events.items);
    try reportEmittedDup("prefab", prefabs.items);
}

fn reportEmittedDup(comptime kind: []const u8, items: []const EmittedItem) !void {
    for (items, 0..) |x, i| {
        for (items[i + 1 ..]) |y| {
            if (std.mem.eql(u8, x.emitted, y.emitted)) {
                std.log.warn(
                    "labelle: duplicate emitted " ++ kind ++ " identifier '{s}':\n" ++
                        "  {s}\n  {s}\n" ++
                        "  pack namespacing folds these to the SAME generated symbol, which would\n" ++
                        "  emit duplicate " ++ kind ++ "s in main.zig. rename one source (or its pack).\n",
                    .{ x.emitted, x.origin, y.origin },
                );
                return error.PackEmittedNameCollision;
            }
        }
    }
}

// ── Unknown-dependency check ───────────────────────────────────────

fn checkUnknownDeps(packs: []const PackDep, declared_names: []const []const u8) !void {
    for (packs) |pack| {
        for (pack.depends_on) |dep| {
            if (isImplicit(dep)) continue;
            if (contains(declared_names, dep)) continue;
            std.log.warn(
                "labelle: pack '{s}' depends_on '{s}', which is not a declared pack/plugin.\n" ++
                    "  every name in a pack's depends_on must be a plugin/pack declared in project.labelle\n" ++
                    "  (or the implicit 'contracts' root). fix the name, or add the dependency to .plugins.\n",
                .{ pack.name, dep },
            );
            return error.PackUnknownDependency;
        }
    }
}

// ── Acyclic (DAG) check ────────────────────────────────────────────

const Color = enum { white, gray, black };

/// Depth-first-search cycle detection over the pack `depends_on` edges.
/// Only edges whose target is itself a pack are graph edges; a dependency
/// on a non-pack plugin (e.g. `pathfinder`) or on `contracts` is a leaf
/// and cannot be part of a cycle. On the first back-edge to a `gray`
/// node, reports the full cycle path and returns `PackDependencyCycle`.
fn checkAcyclic(allocator: std.mem.Allocator, packs: []const PackDep) !void {
    // name → index, so a depends_on entry can be resolved to a pack node.
    var index_of = std.StringHashMap(usize).init(allocator);
    defer index_of.deinit();
    for (packs, 0..) |pack, i| {
        // If two packs share a name, keep the first — a duplicate-name
        // collision is a separate concern (and #440's prefixing); here we
        // only need a consistent name→node mapping for the walk.
        _ = try index_of.getOrPutValue(pack.name, i);
    }

    const colors = try allocator.alloc(Color, packs.len);
    defer allocator.free(colors);
    @memset(colors, .white);

    // Explicit recursion-stack of node indices, doubling as the current
    // DFS path for cycle reporting.
    var path: std.ArrayList(usize) = .empty;
    defer path.deinit(allocator);

    for (packs, 0..) |_, i| {
        if (colors[i] == .white) {
            try visit(allocator, packs, &index_of, i, colors, &path);
        }
    }
}

fn visit(
    allocator: std.mem.Allocator,
    packs: []const PackDep,
    index_of: *std.StringHashMap(usize),
    idx: usize,
    colors: []Color,
    path: *std.ArrayList(usize),
) !void {
    colors[idx] = .gray;
    try path.append(allocator, idx);

    for (packs[idx].depends_on) |dep| {
        const j = index_of.get(dep) orelse continue; // dep is a leaf (non-pack)
        switch (colors[j]) {
            .gray => {
                reportCycle(packs, path.items, j);
                return error.PackDependencyCycle;
            },
            .white => try visit(allocator, packs, index_of, j, colors, path),
            .black => {}, // fully explored, no cycle through it
        }
    }

    path.items.len -= 1; // pop
    colors[idx] = .black;
}

fn reportCycle(packs: []const PackDep, path: []const usize, back_to: usize) void {
    // The cycle is the suffix of `path` starting at `back_to`, closed by
    // the edge back to `back_to`. Find where `back_to` first appears.
    var start: usize = 0;
    for (path, 0..) |node, i| {
        if (node == back_to) {
            start = i;
            break;
        }
    }
    // Build "a -> b -> c -> a".
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.heap.page_allocator);
    for (path[start..]) |node| {
        buf.appendSlice(std.heap.page_allocator, packs[node].name) catch {};
        buf.appendSlice(std.heap.page_allocator, " -> ") catch {};
    }
    buf.appendSlice(std.heap.page_allocator, packs[back_to].name) catch {};

    std.log.warn(
        "labelle: pack dependency cycle detected: {s}\n" ++
            "  packs' depends_on edges must form an acyclic graph (RFC §6).\n" ++
            "  reads/writes point DOWN the DAG; use events (which point up) to break the cycle.\n",
        .{buf.items},
    );
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "validate: accepts a valid DAG" {
    const packs = [_]PackDep{
        .{ .name = "production", .depends_on = &.{ "citizens", "rooms" } },
        .{ .name = "citizens", .depends_on = &.{"rooms"} },
        .{ .name = "rooms", .depends_on = &.{} },
    };
    const declared = [_][]const u8{ "production", "citizens", "rooms" };
    try validate(testing.allocator, &packs, &declared);
}

test "validate: accepts a dep on a non-pack plugin (leaf)" {
    // `pathfinder` is declared as a plugin but ships no pack.labelle, so it
    // isn't in the pack list — it's a leaf and must not trip the cycle check.
    const packs = [_]PackDep{
        .{ .name = "citizens", .depends_on = &.{"pathfinder"} },
    };
    const declared = [_][]const u8{ "citizens", "pathfinder" };
    try validate(testing.allocator, &packs, &declared);
}

test "validate: accepts the implicit contracts dependency" {
    const packs = [_]PackDep{
        .{ .name = "citizens", .depends_on = &.{"contracts"} },
    };
    // Note: `contracts` is NOT in declared_names — it is implicit.
    const declared = [_][]const u8{"citizens"};
    try validate(testing.allocator, &packs, &declared);
}

test "validate: rejects a two-pack cycle" {
    const packs = [_]PackDep{
        .{ .name = "citizens", .depends_on = &.{"production"} },
        .{ .name = "production", .depends_on = &.{"citizens"} },
    };
    const declared = [_][]const u8{ "citizens", "production" };
    try testing.expectError(error.PackDependencyCycle, validate(testing.allocator, &packs, &declared));
}

test "validate: rejects a self-loop" {
    const packs = [_]PackDep{
        .{ .name = "citizens", .depends_on = &.{"citizens"} },
    };
    const declared = [_][]const u8{"citizens"};
    try testing.expectError(error.PackDependencyCycle, validate(testing.allocator, &packs, &declared));
}

test "validate: rejects a three-pack cycle" {
    const packs = [_]PackDep{
        .{ .name = "a", .depends_on = &.{"b"} },
        .{ .name = "b", .depends_on = &.{"c"} },
        .{ .name = "c", .depends_on = &.{"a"} },
    };
    const declared = [_][]const u8{ "a", "b", "c" };
    try testing.expectError(error.PackDependencyCycle, validate(testing.allocator, &packs, &declared));
}

test "validate: rejects an unknown dependency" {
    const packs = [_]PackDep{
        .{ .name = "citizens", .depends_on = &.{"nonexistent"} },
    };
    const declared = [_][]const u8{"citizens"};
    try testing.expectError(error.PackUnknownDependency, validate(testing.allocator, &packs, &declared));
}

test "validate: unknown-dep check runs before cycle check" {
    // Even inside a would-be cycle, an unknown name is reported as the
    // unknown-dependency error (the clearer, more actionable diagnostic).
    const packs = [_]PackDep{
        .{ .name = "a", .depends_on = &.{"b"} },
        .{ .name = "b", .depends_on = &.{ "a", "ghost" } },
    };
    const declared = [_][]const u8{ "a", "b" };
    try testing.expectError(error.PackUnknownDependency, validate(testing.allocator, &packs, &declared));
}

test "validate: empty pack list is trivially valid" {
    const packs = [_]PackDep{};
    const declared = [_][]const u8{};
    try validate(testing.allocator, &packs, &declared);
}

test "checkPrefixCollisions: rejects names that sanitize to the same prefix" {
    // `my-pack` and `my_pack` both sanitize to the Zig-ident `my_pack`.
    const names = [_][]const u8{ "my-pack", "my_pack" };
    try testing.expectError(error.PackNamePrefixCollision, checkPrefixCollisions(&names));
}

test "checkPrefixCollisions: rejects exact duplicate names" {
    const names = [_][]const u8{ "citizens", "rooms", "citizens" };
    try testing.expectError(error.PackNamePrefixCollision, checkPrefixCollisions(&names));
}

test "checkPrefixCollisions: accepts distinct sanitized prefixes" {
    const names = [_][]const u8{ "citizens", "rooms", "production" };
    try checkPrefixCollisions(&names);
}

test "checkPrefixCollisions: empty and single sets are trivially valid" {
    try checkPrefixCollisions(&[_][]const u8{});
    try checkPrefixCollisions(&[_][]const u8{"solo"});
}

test "checkEmittedNameCollisions: pack 'a'+'b__hit' and pack 'a__b'+'hit' both fold to 'a__b__hit'" {
    // The delimiter is not injective on its own: distinct (pack, event) pairs
    // fold to the same emitted tag, which the prefix gate ('a' ≠ 'a__b') misses.
    const packs = [_]scan.PackScan{
        .{ .name = "a", .import_prefix = "packs/a", .component_names = &.{}, .event_names = &.{"b__hit"}, .prefab_names = &.{}, .hook_names = &.{} },
        .{ .name = "a__b", .import_prefix = "packs/a__b", .component_names = &.{}, .event_names = &.{"hit"}, .prefab_names = &.{}, .hook_names = &.{} },
    };
    try testing.expectError(
        error.PackEmittedNameCollision,
        checkEmittedNameCollisions(testing.allocator, &.{}, &.{}, &.{}, &packs),
    );
}

test "checkEmittedNameCollisions: two subdir pack prefabs sharing a basename collide" {
    // `enemies/goblin` and `allies/goblin` both register as `pack__goblin`.
    const packs = [_]scan.PackScan{
        .{ .name = "pack", .import_prefix = "packs/pack", .component_names = &.{}, .event_names = &.{}, .prefab_names = &.{ "enemies/goblin", "allies/goblin" }, .hook_names = &.{} },
    };
    try testing.expectError(
        error.PackEmittedNameCollision,
        checkEmittedNameCollisions(testing.allocator, &.{}, &.{}, &.{}, &packs),
    );
}

test "checkEmittedNameCollisions: distinct emitted names pass" {
    const packs = [_]scan.PackScan{
        .{ .name = "a", .import_prefix = "packs/a", .component_names = &.{"worker"}, .event_names = &.{"hit"}, .prefab_names = &.{"boss"}, .hook_names = &.{} },
        .{ .name = "b", .import_prefix = "packs/b", .component_names = &.{"worker"}, .event_names = &.{"hit"}, .prefab_names = &.{"boss"}, .hook_names = &.{} },
    };
    // Game root also defines a `hit` event + `Worker` component — bare vs
    // `<pack>__`-prefixed, so no clash.
    try checkEmittedNameCollisions(testing.allocator, &.{"worker"}, &.{"hit"}, &.{"level"}, &packs);
}

test "validate: diamond DAG (shared lower dep) is acyclic" {
    //   a → b → d
    //   a → c → d
    const packs = [_]PackDep{
        .{ .name = "a", .depends_on = &.{ "b", "c" } },
        .{ .name = "b", .depends_on = &.{"d"} },
        .{ .name = "c", .depends_on = &.{"d"} },
        .{ .name = "d", .depends_on = &.{} },
    };
    const declared = [_][]const u8{ "a", "b", "c", "d" };
    try validate(testing.allocator, &packs, &declared);
}

/// #498 PR 4: a manifest exposing verbs from a file the pack doesn't
/// ship fails at GENERATE time with the manifest named — otherwise the
/// dependent's eventual compile error points at generated code instead
/// of the author's mistake. Called per pack from `generate()`; split
/// out for direct unit testing.
pub fn checkExposesFiles(
    pack_name: []const u8,
    exposes_queries: usize,
    exposes_commands: usize,
    has_queries: bool,
    has_commands: bool,
) error{PackExposesMissingFile}!void {
    if (exposes_queries > 0 and !has_queries) {
        std.log.warn(
            "labelle: pack '{s}' exposes queries but ships no queries.zig — add packs/{s}/queries.zig or drop the exposes.queries list",
            .{ pack_name, pack_name },
        );
        return error.PackExposesMissingFile;
    }
    if (exposes_commands > 0 and !has_commands) {
        std.log.warn(
            "labelle: pack '{s}' exposes commands but ships no commands.zig — add packs/{s}/commands.zig or drop the exposes.commands list",
            .{ pack_name, pack_name },
        );
        return error.PackExposesMissingFile;
    }
}
