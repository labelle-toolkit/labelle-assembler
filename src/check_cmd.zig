//! `labelle-assembler check` — driver for the Packs enforcement lint
//! (labelle-cli#270). Discovers the game's packs, builds the cross-pack
//! `check.Context` from their `pack.labelle` manifests + scanned
//! convention dirs, runs the token scan (`check.zig`), prints a report,
//! and exits non-zero when any violation is found.
//!
//! The rule logic lives in `check.zig` (pure, unit-tested); this module
//! owns the filesystem/discovery glue: reading `project.labelle`,
//! resolving each pack's on-disk directory, and turning the parsed
//! `depends_on` DAG into the per-pack "who is higher than me" set the
//! event-direction rule needs.

const std = @import("std");
const config = @import("config.zig");
const cache = @import("cache.zig");
const plugin_manifest = @import("plugin_manifest.zig");
const plugin_params = @import("plugin_params.zig");
const scan = @import("codegen/scan.zig");
const idents = @import("codegen/idents.zig");
const check = @import("check.zig");
const scene_name_lint = @import("scene_name_lint.zig");

const ProjectConfig = config.ProjectConfig;

/// A discovered pack: its declaration, parsed manifest, and on-disk dir.
const Pack = struct {
    name: []const u8,
    prefix: []const u8,
    dir: []const u8,
    depends_on: []const []const u8,
    component_pascals: []const []const u8,
    event_qualified: []const []const u8,
};

/// Outcome of a lint pass — the collected findings plus how many packs were
/// scanned. Returned by `runLint` (which never exits) so both the CLI
/// driver and the tests can consume it.
pub const LintResult = struct {
    findings: []const check.Finding,
    pack_count: usize,
};

pub fn cmdCheck(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    var project_root: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--project-root")) {
            project_root = args.next() orelse {
                std.log.err("labelle-assembler check: --project-root requires a value", .{});
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, arg, "--project-root=")) {
            project_root = arg["--project-root=".len..];
        } else {
            std.log.err("labelle-assembler check: unknown flag '{s}'", .{arg});
            std.process.exit(2);
        }
    }

    const root = project_root orelse {
        std.log.err("labelle-assembler check: --project-root is required", .{});
        std.process.exit(2);
    };

    // Everything is scratch — one arena, freed on return.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = runLint(arena, io, root) catch |err| {
        std.log.err("labelle-assembler check: {s} (in '{s}')", .{ @errorName(err), root });
        std.process.exit(1);
    };

    if (result.pack_count == 0) {
        // No packs → nothing to enforce. A clean, explicit success so a CI
        // step that runs `labelle check` on a pack-free game stays green.
        writeStdout(io, "labelle check: no packs found — nothing to lint\n");
        return;
    }

    try report(arena, io, result);

    if (result.findings.len > 0) std.process.exit(1);
}

/// Run the lint over the project at `root` and return the findings without
/// exiting. Pure of side effects except reads; all allocation is on
/// `arena`. Fails only on unrecoverable I/O / config-parse errors — a
/// missing/malformed individual pack is skipped, not fatal.
pub fn runLint(arena: std.mem.Allocator, io: std.Io, root: []const u8) !LintResult {
    const cfg = try readProjectConfig(arena, io, root);
    const packs = try discoverPacks(arena, io, cfg, root);
    if (packs.len == 0) return .{ .findings = &.{}, .pack_count = 0 };

    // Build the shared owner/DAG data once, then scan each pack against it.
    const shared = try buildShared(arena, packs);

    var findings: std.ArrayList(check.Finding) = .empty;
    for (packs, 0..) |pack, i| {
        const foreign = try foreignPacksFor(arena, packs, i);
        const ctx = check.Context{
            .current_prefix = pack.prefix,
            .pack_prefixes = shared.pack_prefixes,
            .components = shared.components,
            .events = shared.events,
            .global_facets = shared.global_facets,
            .dependents_of_current = shared.dependents[i],
            .current_pack_dir = pack.dir,
            .foreign_packs = foreign,
        };
        try check.scanPackDir(arena, io, &findings, pack.dir, ctx);
    }

    // Game-root scene/prefab bare pack-component lint (#490). A game-root
    // scene must reference a pack component by its namespaced key
    // (`citizens__Worker`); a bare name (`Worker`) silently no-ops as an
    // unknown component (RFC #596). Build the pack component set (bare →
    // namespaced) from the shared owner map, and the game-owned name set
    // from the game root's own `components/`, then walk `scenes/` +
    // `prefabs/`.
    try scanSceneNames(arena, io, root, shared, &findings);

    return .{ .findings = try findings.toOwnedSlice(arena), .pack_count = packs.len };
}

/// Lint the game root's `scenes/` and `prefabs/` for bare pack-component
/// references (#490). See `scene_name_lint.zig`.
fn scanSceneNames(
    arena: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    shared: Shared,
    findings: *std.ArrayList(check.Finding),
) !void {
    // Pack components: bare un-prefixed Pascal → namespaced registry key.
    var pack_components: std.ArrayList(scene_name_lint.PackComponent) = .empty;
    for (shared.components) |c| {
        const namespaced = try std.fmt.allocPrint(arena, "{s}__{s}", .{ c.owner_prefix, c.pascal });
        try pack_components.append(arena, .{ .bare = c.pascal, .namespaced = namespaced });
    }
    // No pack components → nothing a bare name could collide with.
    if (pack_components.items.len == 0) return;

    // Game-owned bare component names: the game root's own `components/*.zig`
    // (registered under their bare Pascal name, so a bare reference to one is
    // legitimate). Engine/gfx built-ins (e.g. `VideoComponent`) the codegen
    // always registers are exempted inside `lintSource` itself via
    // `scene_name_lint.builtin_component_names`, so they need no enumeration
    // here (labelle-assembler#494, codex review).
    var game_owned: std.ArrayList([]const u8) = .empty;
    const own_stems = try collectStems(arena, io, root, "components");
    for (own_stems) |stem| {
        var pb: [128]u8 = undefined;
        try game_owned.append(arena, try arena.dupe(u8, idents.pathToPascal(stem, &pb)));
    }

    // Script-declared components (labelle-assembler#585, PR #598 finding 2):
    // the declare phase registers `labelle.component(...)` names into the
    // SAME bare game-root namespace as `components/*.zig`, so a bare scene
    // reference to one is legitimate — without them here, a declared name
    // that happens to match a pack component's bare name false-positives
    // as `scene-bare-pack-component`, suggesting a pack-prefixed rename of
    // a component the game genuinely owns.
    //
    // Source: the manifest sidecar the last `generate` emitted (which lists
    // declared components in the game realm) — NOT the declare tool itself.
    // Running the tool from a lint is a non-starter: it `zig build`s the
    // pinned plugin's runner (network lua fetch, seconds of compile), and
    // an old pin ships no tool at all (the generate-side phase gracefully
    // skips, yielding no names anyway). The sidecar is ADVISORY by design:
    // check reads no other generated artifact, so this is its one
    // deliberate source-vs-artifact seam — a missing or stale sidecar
    // degrades to the pre-#585 set (a declaration added since the last
    // generate may false-positive until the next generate; a removed one
    // may suppress a finding), both self-healing on regenerate, and the
    // lint stays fast, offline, and functional against ANY scripting pin.
    try appendSidecarGameComponents(arena, io, root, &game_owned);

    inline for (.{ "scenes", "prefabs" }) |subdir| {
        const dir = try std.fs.path.join(arena, &.{ root, subdir });
        try scene_name_lint.scanScenesDir(arena, io, findings, dir, pack_components.items, game_owned.items);
    }
}

/// Append the game realm's component names from `<root>/.labelle/
/// manifest.json` (the `index.realms[name=="game"].owns.components` string
/// array) to `game_owned`. See the call site for why the sidecar is the
/// chosen source for script-declared components and why it's advisory:
/// every non-OOM failure — no sidecar (never generated), unparseable JSON,
/// an unexpected shape — silently degrades to the disk-scanned set.
/// Duplicates with the `components/*.zig` pascals are harmless (the lint
/// does a linear membership check).
fn appendSidecarGameComponents(
    arena: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    game_owned: *std.ArrayList([]const u8),
) !void {
    const path = try std.fs.path.join(arena, &.{ root, ".labelle", "manifest.json" });
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };

    const root_obj = switch (parsed) {
        .object => |o| o,
        else => return,
    };
    const index_obj = switch (root_obj.get("index") orelse return) {
        .object => |o| o,
        else => return,
    };
    const realms = switch (index_obj.get("realms") orelse return) {
        .array => |a| a,
        else => return,
    };
    for (realms.items) |realm_val| {
        const realm = switch (realm_val) {
            .object => |o| o,
            else => continue,
        };
        const name = switch (realm.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, name, "game")) continue;
        const owns = switch (realm.get("owns") orelse return) {
            .object => |o| o,
            else => return,
        };
        const comps = switch (owns.get("components") orelse return) {
            .array => |a| a,
            else => return,
        };
        for (comps.items) |comp_val| {
            switch (comp_val) {
                .string => |s| try game_owned.append(arena, try arena.dupe(u8, s)),
                else => {},
            }
        }
        return;
    }
}

// ── Discovery ────────────────────────────────────────────────────────────

fn discoverPacks(arena: std.mem.Allocator, io: std.Io, cfg: ProjectConfig, root: []const u8) ![]const Pack {
    var list: std.ArrayList(Pack) = .empty;
    for (cfg.plugins) |plugin| {
        const pack_dir = cache.resolvePlugin(arena, plugin, root) catch continue;
        var manifest = (plugin_manifest.loadPackFromDir(arena, pack_dir, plugin.name) catch |err| {
            // A malformed pack.labelle is a real problem, but the DAG gate
            // (`pack_validate`) is where that's reported at generate time;
            // the lint should not hard-fail on it. Skip and continue.
            std.log.warn("labelle-assembler check: skipping pack '{s}': {s}", .{ plugin.name, @errorName(err) });
            continue;
        }) orelse continue; // not a pack (no pack.labelle)
        defer manifest.deinit();

        var prefix_buf: [128]u8 = undefined;
        const prefix = try arena.dupe(u8, scan.packNamespacePrefix(plugin.name, &prefix_buf));

        const component_stems = try collectStems(arena, io, pack_dir, "components");
        const event_stems = try collectStems(arena, io, pack_dir, "events");

        var pascals: std.ArrayList([]const u8) = .empty;
        for (component_stems) |stem| {
            var pb: [128]u8 = undefined;
            try pascals.append(arena, try arena.dupe(u8, idents.pathToPascal(stem, &pb)));
        }
        var quals: std.ArrayList([]const u8) = .empty;
        for (event_stems) |stem| {
            const variant = idents.eventVariantName(stem);
            try quals.append(arena, try std.fmt.allocPrint(arena, "{s}__{s}", .{ prefix, variant }));
        }

        try list.append(arena, .{
            .name = try arena.dupe(u8, plugin.name),
            .prefix = prefix,
            .dir = try arena.dupe(u8, pack_dir),
            .depends_on = try dupeStrings(arena, manifest.depends_on),
            .component_pascals = try pascals.toOwnedSlice(arena),
            .event_qualified = try quals.toOwnedSlice(arena),
        });
    }
    return list.toOwnedSlice(arena);
}

/// Collect `.zig` file stems (relative to `<base>/<subdir>`, without the
/// `.zig` extension) recursively. Returns an empty slice if the subdir is
/// absent. Mirrors the stems `scanPack` would register, so the derived
/// component/event names match the emitted registry keys (#440).
fn collectStems(arena: std.mem.Allocator, io: std.Io, base: []const u8, subdir: []const u8) ![]const []const u8 {
    const dir_path = try std.fs.path.join(arena, &.{ base, subdir });
    var out: std.ArrayList([]const u8) = .empty;
    try collectStemsRec(arena, io, dir_path, "", &out);
    return out.toOwnedSlice(arena);
}

fn collectStemsRec(
    arena: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    rel_prefix: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                const sub = try std.fs.path.join(arena, &.{ dir_path, entry.name });
                const next_prefix = if (rel_prefix.len == 0)
                    try arena.dupe(u8, entry.name)
                else
                    try std.fmt.allocPrint(arena, "{s}/{s}", .{ rel_prefix, entry.name });
                try collectStemsRec(arena, io, sub, next_prefix, out);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                const stem = entry.name[0 .. entry.name.len - ".zig".len];
                const full = if (rel_prefix.len == 0)
                    try arena.dupe(u8, stem)
                else
                    try std.fmt.allocPrint(arena, "{s}/{s}", .{ rel_prefix, stem });
                try out.append(arena, full);
            },
            else => {},
        }
    }
}

/// Build the `ForeignPack` view for the pack at `current_idx`: every OTHER
/// discovered pack, tagged `allowed` when the current pack declares it in
/// `depends_on` (or it is the implicit `contracts` root). Drives the
/// cross-pack-import rule (rule 4) — an import into an `allowed == false`
/// pack's tree is the flagged reach-around.
fn foreignPacksFor(arena: std.mem.Allocator, packs: []const Pack, current_idx: usize) ![]const check.ForeignPack {
    const cur = packs[current_idx];
    var list: std.ArrayList(check.ForeignPack) = .empty;
    for (packs, 0..) |other, j| {
        if (j == current_idx) continue;
        const allowed = std.mem.eql(u8, other.name, "contracts") or
            containsStr(cur.depends_on, other.name);
        try list.append(arena, .{ .name = other.name, .dir = other.dir, .allowed = allowed });
    }
    return list.toOwnedSlice(arena);
}

fn containsStr(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| {
        if (std.mem.eql(u8, h, needle)) return true;
    }
    return false;
}

// ── Shared context (owner maps + DAG) ────────────────────────────────────

const Shared = struct {
    pack_prefixes: []const []const u8,
    components: []const check.ComponentOwner,
    events: []const check.EventOwner,
    global_facets: []const check.GlobalFacet,
    /// `dependents[i]` = prefixes of packs (transitively) depending on
    /// `packs[i]` — the packs *higher* than it in the DAG.
    dependents: []const []const []const u8,
};

fn buildShared(arena: std.mem.Allocator, packs: []const Pack) !Shared {
    // Prefixes.
    var prefixes: std.ArrayList([]const u8) = .empty;
    for (packs) |p| try prefixes.append(arena, p.prefix);

    // Component + event owner maps.
    var comps: std.ArrayList(check.ComponentOwner) = .empty;
    var events: std.ArrayList(check.EventOwner) = .empty;
    for (packs) |p| {
        for (p.component_pascals) |pascal| {
            try comps.append(arena, .{ .pascal = pascal, .owner_prefix = p.prefix });
        }
        for (p.event_qualified) |q| {
            try events.append(arena, .{ .qualified = q, .owner_prefix = p.prefix });
        }
    }

    // Global facets: the canonical `Locked`, owned by a `contracts` pack
    // when one is present, plus every component a `contracts` pack defines
    // (its shared facets). When there is no contracts pack, `Locked` has no
    // in-project owner, so a raw construction in any pack is flagged.
    var facets: std.ArrayList(check.GlobalFacet) = .empty;
    var contracts_prefix: ?[]const u8 = null;
    for (packs) |p| {
        if (std.mem.eql(u8, p.name, "contracts")) contracts_prefix = p.prefix;
    }
    try facets.append(arena, .{ .name = "Locked", .owner_prefix = contracts_prefix });
    if (contracts_prefix) |cp| {
        for (packs) |p| {
            if (!std.mem.eql(u8, p.name, "contracts")) continue;
            for (p.component_pascals) |pascal| {
                if (std.mem.eql(u8, pascal, "Locked")) continue; // already added
                try facets.append(arena, .{ .name = pascal, .owner_prefix = cp });
            }
        }
    }

    // Dependents (reverse transitive closure of depends_on, over packs).
    const dependents = try computeDependents(arena, packs);

    return .{
        .pack_prefixes = try prefixes.toOwnedSlice(arena),
        .components = try comps.toOwnedSlice(arena),
        .events = try events.toOwnedSlice(arena),
        .global_facets = try facets.toOwnedSlice(arena),
        .dependents = dependents,
    };
}

/// For each pack, the set of pack *prefixes* that transitively depend on it
/// (its DAG dependents / the packs higher than it). `depends_on` entries
/// that don't name a pack (leaf plugins, `contracts`) are ignored.
fn computeDependents(arena: std.mem.Allocator, packs: []const Pack) ![]const []const []const u8 {
    const n = packs.len;
    // name → index for pack resolution.
    var index_of = std.StringHashMap(usize).init(arena);
    for (packs, 0..) |p, i| _ = try index_of.getOrPutValue(p.name, i);

    var result = try arena.alloc([]const []const u8, n);
    for (result) |*r| r.* = &.{};

    // For each source pack X, DFS its depends_on closure; every reached
    // pack R gains X as a dependent.
    var accum = try arena.alloc(std.ArrayList([]const u8), n);
    for (accum) |*a| a.* = .empty;

    for (packs, 0..) |_, x| {
        const visited = try arena.alloc(bool, n);
        @memset(visited, false);
        try dfsReach(arena, packs, &index_of, x, visited);
        for (0..n) |r| {
            if (r == x) continue;
            if (visited[r]) try accum[r].append(arena, packs[x].prefix);
        }
    }

    for (0..n) |i| result[i] = try accum[i].toOwnedSlice(arena);
    return result;
}

fn dfsReach(
    arena: std.mem.Allocator,
    packs: []const Pack,
    index_of: *std.StringHashMap(usize),
    idx: usize,
    visited: []bool,
) !void {
    for (packs[idx].depends_on) |dep| {
        const j = index_of.get(dep) orelse continue; // non-pack leaf
        if (visited[j]) continue;
        visited[j] = true;
        try dfsReach(arena, packs, index_of, j, visited);
    }
}

// ── Reporting ────────────────────────────────────────────────────────────

fn report(arena: std.mem.Allocator, io: std.Io, result: LintResult) !void {
    const findings = result.findings;
    if (findings.len == 0) {
        const msg = try std.fmt.allocPrint(arena, "labelle check: {d} pack(s) scanned, no violations found\n", .{result.pack_count});
        writeStdout(io, msg);
        return;
    }

    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.print("labelle check: {d} violation(s) found:\n\n", .{findings.len});
    for (findings) |f| {
        try w.print("  {s}:{d}:{d}: [{s}] {s}\n", .{ f.file, f.line, f.col, f.rule.slug(), f.message });
    }
    try w.print("\n{d} violation(s) across {d} pack(s). See docs/RFC-packs.md §6.\n", .{ findings.len, result.pack_count });
    writeStderr(io, aw.written());
}

fn writeStdout(io: std.Io, msg: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, msg) catch {};
}

fn writeStderr(io: std.Io, msg: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
}

// ── Small helpers ────────────────────────────────────────────────────────

fn dupeStrings(arena: std.mem.Allocator, in: []const []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, in.len);
    for (in, 0..) |s, i| out[i] = try arena.dupe(u8, s);
    return out;
}

/// Inline copy of the project.labelle reader (mirrors `main.zig`'s private
/// helper) so the check driver doesn't depend on it being exported.
fn readProjectConfig(allocator: std.mem.Allocator, io: std.Io, project_dir: []const u8) !ProjectConfig {
    @setEvalBranchQuota(10000);
    const labelle_path = try std.fs.path.join(allocator, &.{ project_dir, "project.labelle" });
    const source_raw = try std.Io.Dir.cwd().readFileAlloc(io, labelle_path, allocator, .limited(1024 * 1024));
    const source = try allocator.dupeZ(u8, source_raw);
    // #591: route through the params-aware parse (see plugin_params.zig).
    return try plugin_params.parseProjectConfig(allocator, source);
}

// ════════════════════════════════════════════════════════════════════════
// Fixture-based end-to-end tests
//
// These build a temp game with three packs (`contracts`, `citizens`,
// `production` where `production depends_on citizens`) and drive the full
// discovery → DAG → owner-map → scan pipeline via `runLint`, asserting that
// a rule-violating tree is flagged and a clean tree is not.
// ════════════════════════════════════════════════════════════════════════

const testing = std.testing;

fn writeFile(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |parent| try dir.createDirPath(io, parent);
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
}

/// Scaffold the three-pack skeleton shared by both fixture tests. Callers
/// then drop in the pack scripts that carry (or don't carry) violations.
fn scaffoldFixture(io: std.Io, dir: std.Io.Dir) !void {
    try writeFile(io, dir, "project.labelle",
        \\.{
        \\    .name = "fixture",
        \\    .plugins = .{
        \\        .{ .name = "contracts", .repo = "@packs/contracts" },
        \\        .{ .name = "citizens", .repo = "@packs/citizens" },
        \\        .{ .name = "production", .repo = "@packs/production" },
        \\    },
        \\}
    );
    try writeFile(io, dir, "packs/contracts/pack.labelle",
        \\.{ .name = "contracts", .manifest_version = 1, .convention_dirs = .copy_and_scan }
    );
    try writeFile(io, dir, "packs/contracts/components/locked.zig",
        \\pub const Locked = struct { owner: u64 = 0 };
    );
    try writeFile(io, dir, "packs/citizens/pack.labelle",
        \\.{ .name = "citizens", .manifest_version = 1, .convention_dirs = .copy_and_scan, .depends_on = .{ "contracts" } }
    );
    try writeFile(io, dir, "packs/citizens/components/worker.zig",
        \\pub const Worker = struct { hunger: f32 = 0 };
    );
    try writeFile(io, dir, "packs/production/pack.labelle",
        \\.{ .name = "production", .manifest_version = 1, .convention_dirs = .copy_and_scan, .depends_on = .{ "citizens", "contracts" } }
    );
    try writeFile(io, dir, "packs/production/events/item_produced.zig",
        \\pub const ItemProduced = struct { workstation: u64 = 0 };
    );
}

test "runLint: a fixture violating all three rules is flagged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try scaffoldFixture(io, tmp.dir);

    // production reads a foreign registry name (rule 1) + constructs the
    // shared `.global` facet directly (rule 2).
    try writeFile(io, tmp.dir, "packs/production/scripts/00_work.zig",
        \\pub fn work(game: anytype, e: u64) void {
        \\    _ = game.getType("citizens__Worker");
        \\    game.addComponent(e, Locked{ .owner = 1 });
        \\}
    );
    // citizens (lower) reacts to production's (higher) event (rule 3).
    try writeFile(io, tmp.dir, "packs/citizens/scripts/00_decay.zig",
        \\pub fn on_event(ev: anytype) void {
        \\    switch (ev) { .production__item_produced => {}, else => {} }
        \\}
    );

    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const result = try runLint(arena, io, root);

    try testing.expectEqual(@as(usize, 3), result.pack_count);
    var saw_reg = false;
    var saw_facet = false;
    var saw_evt = false;
    for (result.findings) |f| switch (f.rule) {
        .cross_pack_registry_access => saw_reg = true,
        .raw_global_facet_write => saw_facet = true,
        .event_direction_inversion => saw_evt = true,
        .scene_bare_pack_component => {},
        .cross_pack_import => {},
    };
    try testing.expect(saw_reg);
    try testing.expect(saw_facet);
    try testing.expect(saw_evt);
    try testing.expectEqual(@as(usize, 3), result.findings.len);
}

test "runLint: a clean fixture passes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try scaffoldFixture(io, tmp.dir);

    // production reads via a query + the sanctioned facet API; views its
    // own (absent) types only.
    try writeFile(io, tmp.dir, "packs/production/scripts/00_work.zig",
        \\pub fn work(game: anytype, e: u64) void {
        \\    _ = game.citizens_idleWorkers();
        \\    _ = Locked.tryAcquire(game, e);
        \\}
    );
    // citizens reacts to its OWN event — events point up, so a lower pack
    // consuming its own event is fine.
    try writeFile(io, tmp.dir, "packs/citizens/scripts/00_decay.zig",
        \\pub fn tick(game: anytype) void {
        \\    var it = game.view(.{Worker});
        \\    _ = it;
        \\}
    );

    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const result = try runLint(arena, io, root);

    try testing.expectEqual(@as(usize, 3), result.pack_count);
    try testing.expectEqual(@as(usize, 0), result.findings.len);
}

test "runLint: a pack @importing a non-dependency pack's file is flagged (rule 4)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try scaffoldFixture(io, tmp.dir);

    // citizens depends_on {contracts} only — it does NOT declare production.
    // Reaching into production's source tree by file import is the #656
    // reach-around: caught textually even though no registry/view is used.
    try writeFile(io, tmp.dir, "packs/citizens/scripts/00_peek.zig",
        \\const Produced = @import("../../production/events/item_produced.zig").ItemProduced;
        \\pub fn tick() void { _ = Produced; }
    );
    // A clean production file (imports only its declared contracts dep — allowed).
    try writeFile(io, tmp.dir, "packs/production/scripts/00_work.zig",
        \\const Locked = @import("../../contracts/components/locked.zig").Locked;
        \\pub fn work() void { _ = Locked; }
    );

    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const result = try runLint(arena, io, root);

    try testing.expectEqual(@as(usize, 3), result.pack_count);
    var saw_import = false;
    for (result.findings) |f| {
        if (f.rule == .cross_pack_import) {
            saw_import = true;
            try testing.expect(std.mem.indexOf(u8, f.message, "production") != null);
            try testing.expect(std.mem.endsWith(u8, f.file, "00_peek.zig"));
        }
    }
    try testing.expect(saw_import);
}

test "runLint: a pack @importing its DECLARED dependency's file is clean (rule 4)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try scaffoldFixture(io, tmp.dir);

    // production depends_on {citizens, contracts}; importing citizens' and
    // contracts' files is permitted (no module wall yet, RFC §6).
    try writeFile(io, tmp.dir, "packs/production/scripts/00_work.zig",
        \\const Worker = @import("../../citizens/components/worker.zig").Worker;
        \\const Locked = @import("../../contracts/components/locked.zig").Locked;
        \\pub fn work() void { _ = Worker; _ = Locked; }
    );

    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const result = try runLint(arena, io, root);

    for (result.findings) |f| {
        try testing.expect(f.rule != .cross_pack_import);
    }
}

test "runLint: a game-root scene using a bare pack-component name is flagged (#490)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try scaffoldFixture(io, tmp.dir);

    // Clean pack sources so the only finding is the scene one.
    try writeFile(io, tmp.dir, "packs/production/scripts/00_work.zig",
        \\pub fn work() void {}
    );

    // A game-root scene references citizens' `Worker` by its BARE name —
    // the trap. citizens registers it only as `citizens__Worker`.
    try writeFile(io, tmp.dir, "scenes/main.jsonc",
        \\{ "components": { "Worker": { "hunger": 0 } } }
    );

    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const result = try runLint(arena, io, root);

    try testing.expectEqual(@as(usize, 3), result.pack_count);
    var saw_scene = false;
    for (result.findings) |f| {
        if (f.rule == .scene_bare_pack_component) {
            saw_scene = true;
            try testing.expect(std.mem.indexOf(u8, f.message, "citizens__Worker") != null);
            try testing.expect(std.mem.endsWith(u8, f.file, "main.jsonc"));
        }
    }
    try testing.expect(saw_scene);
}

test "runLint: a SCRIPT-DECLARED game component listed by the manifest sidecar is game-owned (#598)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try scaffoldFixture(io, tmp.dir);
    try writeFile(io, tmp.dir, "packs/production/scripts/00_work.zig",
        \\pub fn work() void {}
    );

    // The game's scripts declared a game-global `Worker`
    // (`labelle.component("Worker", ...)`) whose bare name collides with
    // citizens' pack component. A game-root scene referencing it bare is
    // LEGITIMATE — the declared component registers under exactly that key.
    try writeFile(io, tmp.dir, "scenes/main.jsonc",
        \\{ "components": { "Worker": { "hunger": 0 } } }
    );

    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);

    // Phase 1 — no manifest sidecar (never generated): the lint cannot see
    // the declaration, so this is the pre-#598 false positive. Pinning it
    // here proves the suppression below comes from the sidecar, not from
    // the collision being unreal.
    {
        const result = try runLint(arena, io, root);
        var saw_scene = false;
        for (result.findings) |f| {
            if (f.rule == .scene_bare_pack_component) saw_scene = true;
        }
        try testing.expect(saw_scene);
    }

    // Phase 2 — the sidecar the last `generate` emitted lists the declared
    // component in the game realm (labelle-assembler#585): the bare
    // reference is now recognized as game-owned and the finding is gone.
    try writeFile(io, tmp.dir, ".labelle/manifest.json",
        \\{
        \\  "schema": "labelle.manifest/v1",
        \\  "index": {
        \\    "realms": [
        \\      { "name": "game", "tier": "root",
        \\        "owns": { "components": ["Worker"] } }
        \\    ]
        \\  }
        \\}
    );
    {
        const result = try runLint(arena, io, root);
        for (result.findings) |f| {
            try testing.expect(f.rule != .scene_bare_pack_component);
        }
    }
}

test "runLint: a game-root scene using the namespaced key is silent (#490)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try scaffoldFixture(io, tmp.dir);

    try writeFile(io, tmp.dir, "packs/production/scripts/00_work.zig",
        \\pub fn work() void {}
    );
    // Correct namespaced key → no scene finding.
    try writeFile(io, tmp.dir, "scenes/main.jsonc",
        \\{ "components": { "citizens__Worker": { "hunger": 0 } } }
    );

    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const result = try runLint(arena, io, root);

    for (result.findings) |f| {
        try testing.expect(f.rule != .scene_bare_pack_component);
    }
}
