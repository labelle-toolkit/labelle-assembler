//! Pack manifest (`pack.labelle`) support, extracted from
//! `plugin_manifest.zig` (behavior-preserving split, mirrors #539).
//!
//! A *pack* (Packs RFC §4, labelle-assembler#439) is the author-facing,
//! light form of a plugin: a namespaced directory of game-convention files
//! (`components/ events/ prefabs/ hooks/`) scanned the same way the game
//! root is, rather than a decl-module plugin. It carries its own thin
//! descriptor, `pack.labelle`, whose distinguishing feature is a **scalar**
//! `.convention_dirs = .copy_and_scan` shorthand meaning "scan all my
//! convention dirs like the game root" (RFC §10 Q3). This is kept as a
//! SEPARATE file + schema from `plugin.labelle` (whose `convention_dirs` is
//! an array of per-dir `.{}` entries) so neither parser has to disambiguate
//! scalar-vs-array in one field — a pack uses `pack.labelle`, a
//! custom-scan plugin uses `plugin.labelle`, and both keep their simple
//! typed ZON parse.
//!
//! `exposes` / `depends_on` (the §6 isolation inputs) are PARSED here
//! (labelle-assembler#441) and fed to the generate-time validation pass
//! (`pack_validate.zig`) that rejects dependency cycles and unknown deps.
//! Their ENFORCEMENT shipped with #498: the restricted per-pack module
//! graph (PR 2), the `PackView` partition + `@import("pack").Registry`
//! bridge (PRs 1/3), and the `exposes` surface modules `depends_on` maps
//! onto (PR 4) — see `docs/packs.md`. The one-facet-one-owner duplicate
//! check is mooted by #440's `<pack>__` name prefix.
//!
//! Re-exported unchanged from the `plugin_manifest.zig` barrel.
const std = @import("std");
const config = @import("../config.zig");
const cache = @import("../cache.zig");
const common = @import("common.zig");

const SUPPORTED_MANIFEST_VERSION = common.SUPPORTED_MANIFEST_VERSION;

/// Scan mode a `pack.labelle` may declare. Today only the scalar
/// `copy_and_scan` shorthand exists — "scan every convention dir I own"
/// (`components/ events/ prefabs/ hooks/`).
pub const PackConventionMode = enum {
    copy_and_scan,
};

/// The public verb surface a pack exposes to packs that `depends_on` it
/// (RFC §6). Both lists are names of `pub fn`s in the pack's
/// `queries.zig` / `commands.zig`; both may be empty or omitted. These
/// are advisory/self-documenting for now (they feed the §7 manifest and,
/// later, the enforcement pass) — this ticket does not narrow imports by
/// them.
///
/// NOTE: the RFC also describes a scalar `.exposes = .all` shorthand for
/// the degenerate `contracts` pack. That form is NOT part of this typed
/// schema yet: `contracts` is injected implicitly as a dependency (see
/// `pack_validate.IMPLICIT_DEPS`) and exposes-narrowing is unenforced
/// this ticket, so packs use the explicit `.{ .queries, .commands }` form
/// for now. `.all` support lands with the enforcement work (#652).
pub const PackExposes = struct {
    queries: []const []const u8 = &.{},
    commands: []const []const u8 = &.{},
};

/// Parsed and validated `pack.labelle`. Every string field (`name`, each
/// `depends_on` entry, and each `exposes` list entry) is a heap dupe
/// owned by `allocator`; call `deinit` to release them all.
pub const PackManifest = struct {
    name: []const u8,
    manifest_version: u8,
    convention_dirs: PackConventionMode,
    /// Public surface (RFC §6). `null` when the manifest omits `exposes`.
    exposes: ?PackExposes = null,
    /// Packs this one may query — the downward DAG edges (RFC §6).
    /// `contracts` is implicit and need not be listed. Empty/absent =
    /// legacy loose mode (sees the global registry). Feeds the
    /// generate-time acyclic + unknown-dep checks.
    depends_on: []const []const u8 = &.{},
    /// Assets the pack ships (Asset-Plugins RFC Phase 1, labelle-assembler#573).
    /// Same `ResourceDef` shape as `project.labelle`'s `.resources`
    /// (`name`/`json`/`texture`/`sound`/`font`/`lazy`). Paths are relative to
    /// the pack root (e.g. `assets/tiles.json`). Empty/absent = a code-only
    /// pack (every pack before this ticket) — byte-identical output. The
    /// assembler merges these into the game resource list namespaced
    /// `<pack>__<name>`, repathed into the copied `packs/<pack>/…` dir.
    resources: []const config.ResourceDef = &.{},
    /// Game (or other unit) atlases this pack deliberately draws from
    /// (Asset-Plugins RFC Phase 1, labelle-assembler#575). Makes the previously
    /// hidden "the game must declare this atlas" contract explicit and
    /// checkable: a `sprite_name` the pack references is valid if it resolves
    /// in the pack's OWN shipped atlases ∪ the atlases named here. Every entry
    /// must exist in the merged resource list. Empty/absent = self-contained.
    depends_on_resources: []const []const u8 = &.{},
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PackManifest) void {
        std.zon.parse.free(self.allocator, self.name);
        // zon.parse.free walks optionals, slices and structs recursively,
        // so these free the nested query/command/dep strings too.
        std.zon.parse.free(self.allocator, self.exposes);
        std.zon.parse.free(self.allocator, self.depends_on);
        std.zon.parse.free(self.allocator, self.resources);
        std.zon.parse.free(self.allocator, self.depends_on_resources);
    }
};

// ZON-parseable shape for `pack.labelle`. `exposes` / `depends_on` mirror
// the public `PackManifest` fields; `ignore_unknown_fields` stays on for
// forward-compat with future optional fields.
const ZonPackManifest = struct {
    name: []const u8,
    manifest_version: u8,
    convention_dirs: PackConventionMode = .copy_and_scan,
    exposes: ?PackExposes = null,
    depends_on: []const []const u8 = &.{},
    resources: []const config.ResourceDef = &.{},
    depends_on_resources: []const []const u8 = &.{},
};

/// Read and parse `pack.labelle` for the given plugin if it exists.
/// Returns `null` when the plugin ships no `pack.labelle` (the common
/// case — most plugins are decl-module plugins, not packs).
pub fn loadPackOptional(
    allocator: std.mem.Allocator,
    plugin: config.PluginDep,
    project_dir: []const u8,
) !?PackManifest {
    const plugin_dir = try cache.resolvePlugin(allocator, plugin, project_dir);
    defer allocator.free(plugin_dir);
    return loadPackFromDir(allocator, plugin_dir, plugin.name);
}

/// Lower-level entry point: read + parse `pack.labelle` from a known pack
/// directory. `expected_name` is the `.plugins` entry name; the manifest's
/// `name` must match it (same contract as `plugin.labelle`).
///
/// Returns `null` if there is no `pack.labelle`. Errors on parse failure
/// (`PackManifestParseError`), name mismatch (`PackManifestNameMismatch`),
/// or an unsupported `manifest_version` (`PackManifestUnknownVersion`).
pub fn loadPackFromDir(
    allocator: std.mem.Allocator,
    pack_dir: []const u8,
    expected_name: []const u8,
) !?PackManifest {
    const manifest_path = try std.fs.path.join(allocator, &.{ pack_dir, "pack.labelle" });
    defer allocator.free(manifest_path);

    const cwd = std.Io.Dir.cwd();
    const raw_bytes = cwd.readFileAlloc(config.globalIo(), manifest_path, allocator, .limited(64 * 1024)) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer allocator.free(raw_bytes);

    const raw_z = try allocator.dupeZ(u8, raw_bytes);
    defer allocator.free(raw_z);

    const parsed = std.zon.parse.fromSliceAlloc(ZonPackManifest, allocator, raw_z, null, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        // Targeted diagnostic for the RFC's scalar shorthand (#498 PR 4):
        // `.exposes = .all` is deliberately unsupported — an unbounded
        // surface defeats the wall. The generic ZON error for it is
        // opaque ("expected struct"), so name the fix. Token-sequence
        // scan (`.exposes` ws `=` ws `.all`) rather than two independent
        // substring hits, so unrelated parse failures in manifests that
        // merely MENTION either token don't get the misleading hint.
        if (exposesAllShorthand(raw_bytes)) {
            std.log.warn(
                "labelle: pack '{s}': `.exposes = .all` is not supported — list queries/commands explicitly (`.exposes = .{{ .queries = .{{ \"...\" }} }}`). The shared `contracts` pack is implicit and needs no exposes.",
                .{expected_name},
            );
        }
        std.log.warn(
            "labelle: failed to parse pack.labelle for pack '{s}' at {s}\n  parser error: {any}\n  see docs/RFC-packs.md for the pack manifest schema\n",
            .{ expected_name, manifest_path, err },
        );
        return error.PackManifestParseError;
    };
    errdefer std.zon.parse.free(allocator, parsed);

    if (!std.mem.eql(u8, parsed.name, expected_name)) {
        std.log.warn(
            "labelle: pack.labelle name mismatch\n  project.labelle declares '{s}'\n  but its pack.labelle has name = '{s}'\n  at {s}\n",
            .{ expected_name, parsed.name, manifest_path },
        );
        return error.PackManifestNameMismatch;
    }

    if (parsed.manifest_version < 1 or parsed.manifest_version > SUPPORTED_MANIFEST_VERSION) {
        std.log.warn(
            "labelle: pack '{s}' has manifest_version {d}\n  but this labelle-cli release supports manifest_version 1..{d}\n",
            .{ expected_name, parsed.manifest_version, SUPPORTED_MANIFEST_VERSION },
        );
        return error.PackManifestUnknownVersion;
    }

    // ── Mutual-exclusivity guard: pack XOR decl-module plugin (CodeRabbit, #481) ─
    //
    // A `pack.labelle` marks a *light pack*: a module-less, directory-scanned
    // convention bundle whose entire contribution is its scanned/namespaced
    // registry entries. A *decl-module plugin* is the opposite: a real Zig
    // package that the generated build wires in as a module and `main.zig`
    // reaches via `@import("<name>")`. The `declModulePlugins` filter in
    // root.zig treats "carries pack.labelle" as the sole light-pack predicate
    // and DROPS every such plugin from the module wiring. If a plugin
    // erroneously carried BOTH a `pack.labelle` AND decl-module content, it
    // would be silently stripped of its module wiring — a confusing failure.
    //
    // The two forms are mutually exclusive by design (a pack is module-less),
    // so reject the conflict here, at load time, before `pack_entries` is even
    // built — that keeps `declModulePlugins` fed a clean either/or split.
    //
    // Detection basis: presence of ANY decl-module signal in the same dir —
    //   - `plugin.labelle` — the decl-module plugin manifest (the clearest
    //     signal; the two manifests must never coexist), OR
    //   - `build.zig`      — a decl-module plugin ships a build script; a light
    //     pack ships none, OR
    //   - `src/root.zig`   — the importable module's exports.
    // Any one is sufficient; a clean light pack has none of them.
    if (try packDirHasDeclModuleContent(allocator, pack_dir)) {
        std.log.warn(
            "labelle: pack '{s}' at {s} carries a pack.labelle but ALSO ships decl-module content\n" ++
                "  (a plugin.labelle, a build.zig, or a src/root.zig).\n" ++
                "  A light pack (pack.labelle) and a decl-module plugin are mutually exclusive:\n" ++
                "  a pack is module-less and contributes only its scanned convention dirs.\n" ++
                "  Use ONE form — either a pack.labelle OR a decl-module plugin, not both.\n",
            .{ expected_name, pack_dir },
        );
        return error.PackAndPluginManifestConflict;
    }

    return PackManifest{
        .name = parsed.name,
        .manifest_version = parsed.manifest_version,
        .convention_dirs = parsed.convention_dirs,
        .exposes = parsed.exposes,
        .depends_on = parsed.depends_on,
        .resources = parsed.resources,
        .depends_on_resources = parsed.depends_on_resources,
        .allocator = allocator,
    };
}

/// Returns true iff `pack_dir` contains any decl-module-plugin signal,
/// i.e. content that only a real Zig-package plugin (not a light pack)
/// would ship. Used by the pack/plugin mutual-exclusivity guard.
///
/// Signals (any one is sufficient):
///   - `plugin.labelle` — the decl-module plugin manifest
///   - `build.zig`      — a plugin's build script
///   - `src/root.zig`   — the importable module's exports
///
/// A clean light pack has none of these; it ships only convention dirs
/// (`components/ events/ prefabs/ hooks/`) and its `pack.labelle`.
pub fn packDirHasDeclModuleContent(allocator: std.mem.Allocator, pack_dir: []const u8) !bool {
    const cwd = std.Io.Dir.cwd();
    const io = config.globalIo();
    const signals = [_][]const u8{
        "plugin.labelle",
        "build.zig",
        "src" ++ std.fs.path.sep_str ++ "root.zig",
    };
    for (signals) |rel| {
        const path = try std.fs.path.join(allocator, &.{ pack_dir, rel });
        defer allocator.free(path);
        if (cwd.access(io, path, .{})) |_| {
            return true;
        } else |err| switch (err) {
            error.FileNotFound => {},
            // Any other access error (permissions, etc.) is treated as
            // "no reliable signal" rather than failing the whole generate.
            else => {},
        }
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const plugin_mod = @import("plugin.zig");

// ── Pack manifest (`pack.labelle`) tests ───────────────────────────

fn writePackManifestFile(tmp_dir: std.Io.Dir, body: []const u8) !void {
    var f = try tmp_dir.createFile(testing.io, "pack.labelle", .{});
    defer f.close(testing.io);
    try f.writeStreamingAll(testing.io, body);
}

test "loadPackFromDir: returns null when pack.labelle is missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const result = try loadPackFromDir(testing.allocator, tmp_path, "citizens");
    try testing.expect(result == null);
}

test "loadPackFromDir: parses the scalar copy_and_scan shorthand" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writePackManifestFile(tmp.dir,
        \\.{
        \\    .name = "citizens",
        \\    .manifest_version = 1,
        \\    .convention_dirs = .copy_and_scan,
        \\}
    );

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var manifest = (try loadPackFromDir(testing.allocator, tmp_path, "citizens")).?;
    defer manifest.deinit();

    try testing.expectEqualStrings("citizens", manifest.name);
    try testing.expectEqual(@as(u8, 1), manifest.manifest_version);
    try testing.expectEqual(PackConventionMode.copy_and_scan, manifest.convention_dirs);
}

test "loadPackFromDir: convention_dirs defaults to copy_and_scan when omitted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writePackManifestFile(tmp.dir,
        \\.{
        \\    .name = "citizens",
        \\    .manifest_version = 1,
        \\}
    );

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var manifest = (try loadPackFromDir(testing.allocator, tmp_path, "citizens")).?;
    defer manifest.deinit();

    try testing.expectEqual(PackConventionMode.copy_and_scan, manifest.convention_dirs);
}

test "loadPackFromDir: parses exposes/depends_on round-trip (#441)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // RFC §4/§6: the pack.labelle carries the public surface (exposes) and
    // the downward DAG edges (depends_on). #441 parses both into the typed
    // PackManifest and hands them to the generate-time validation pass.
    try writePackManifestFile(tmp.dir,
        \\.{
        \\    .name = "citizens",
        \\    .manifest_version = 1,
        \\    .convention_dirs = .copy_and_scan,
        \\    .exposes = .{ .queries = .{ "idleWorkers", "population" }, .commands = .{ "spawnArrival" } },
        \\    .depends_on = .{ "rooms", "pathfinder" },
        \\}
    );

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var manifest = (try loadPackFromDir(testing.allocator, tmp_path, "citizens")).?;
    defer manifest.deinit();

    try testing.expectEqualStrings("citizens", manifest.name);
    try testing.expectEqual(PackConventionMode.copy_and_scan, manifest.convention_dirs);

    // exposes round-trips as two name lists.
    try testing.expect(manifest.exposes != null);
    try testing.expectEqual(@as(usize, 2), manifest.exposes.?.queries.len);
    try testing.expectEqualStrings("idleWorkers", manifest.exposes.?.queries[0]);
    try testing.expectEqualStrings("population", manifest.exposes.?.queries[1]);
    try testing.expectEqual(@as(usize, 1), manifest.exposes.?.commands.len);
    try testing.expectEqualStrings("spawnArrival", manifest.exposes.?.commands[0]);

    // depends_on round-trips as a name list.
    try testing.expectEqual(@as(usize, 2), manifest.depends_on.len);
    try testing.expectEqualStrings("rooms", manifest.depends_on[0]);
    try testing.expectEqualStrings("pathfinder", manifest.depends_on[1]);
}

test "loadPackFromDir: parses .resources + depends_on_resources (#573/#575)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Asset-Plugins Phase 1: a pack declares the atlases it ships (same
    // ResourceDef shape as project.labelle) plus the game atlases it overlays.
    try writePackManifestFile(tmp.dir,
        \\.{
        \\    .name = "sky",
        \\    .manifest_version = 1,
        \\    .resources = .{
        \\        .{ .name = "background", .json = "assets/bg.json", .texture = "assets/bg.png" },
        \\        .{ .name = "cloud", .json = "assets/cloud.json", .texture = "assets/cloud.png", .lazy = true },
        \\    },
        \\    .depends_on_resources = .{ "characters" },
        \\}
    );

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var manifest = (try loadPackFromDir(testing.allocator, tmp_path, "sky")).?;
    defer manifest.deinit();

    try testing.expectEqual(@as(usize, 2), manifest.resources.len);
    try testing.expectEqualStrings("background", manifest.resources[0].name);
    try testing.expectEqualStrings("assets/bg.json", manifest.resources[0].json);
    try testing.expectEqualStrings("assets/bg.png", manifest.resources[0].texture);
    try testing.expectEqualStrings("cloud", manifest.resources[1].name);
    try testing.expectEqual(true, manifest.resources[1].lazy.?);

    try testing.expectEqual(@as(usize, 1), manifest.depends_on_resources.len);
    try testing.expectEqualStrings("characters", manifest.depends_on_resources[0]);
}

test "loadPackFromDir: .resources absent → empty (byte-identity default)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writePackManifestFile(tmp.dir,
        \\.{
        \\    .name = "citizens",
        \\    .manifest_version = 1,
        \\}
    );

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var manifest = (try loadPackFromDir(testing.allocator, tmp_path, "citizens")).?;
    defer manifest.deinit();

    try testing.expectEqual(@as(usize, 0), manifest.resources.len);
    try testing.expectEqual(@as(usize, 0), manifest.depends_on_resources.len);
}

test "loadPackFromDir: exposes/depends_on absent → null/empty (#441)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Legacy loose mode: a pack that omits both fields still loads; exposes
    // is null and depends_on is empty.
    try writePackManifestFile(tmp.dir,
        \\.{
        \\    .name = "citizens",
        \\    .manifest_version = 1,
        \\    .convention_dirs = .copy_and_scan,
        \\}
    );

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var manifest = (try loadPackFromDir(testing.allocator, tmp_path, "citizens")).?;
    defer manifest.deinit();

    try testing.expect(manifest.exposes == null);
    try testing.expectEqual(@as(usize, 0), manifest.depends_on.len);
}

test "loadPackFromDir: errors on name mismatch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writePackManifestFile(tmp.dir,
        \\.{
        \\    .name = "citizens",
        \\    .manifest_version = 1,
        \\    .convention_dirs = .copy_and_scan,
        \\}
    );

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const result = loadPackFromDir(testing.allocator, tmp_path, "different");
    try testing.expectError(error.PackManifestNameMismatch, result);
}

test "loadPackFromDir: errors on unsupported manifest_version" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writePackManifestFile(tmp.dir,
        \\.{
        \\    .name = "citizens",
        \\    .manifest_version = 99,
        \\    .convention_dirs = .copy_and_scan,
        \\}
    );

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const result = loadPackFromDir(testing.allocator, tmp_path, "citizens");
    try testing.expectError(error.PackManifestUnknownVersion, result);
}

// ── pack XOR decl-module plugin mutual-exclusivity guard (#481) ─────

fn writeFileIn(tmp_dir: std.Io.Dir, name: []const u8, body: []const u8) !void {
    var f = try tmp_dir.createFile(testing.io, name, .{});
    defer f.close(testing.io);
    try f.writeStreamingAll(testing.io, body);
}

test "loadPackFromDir: rejects a pack.labelle dir that also has plugin.labelle" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writePackManifestFile(tmp.dir,
        \\.{
        \\    .name = "citizens",
        \\    .manifest_version = 1,
        \\    .convention_dirs = .copy_and_scan,
        \\}
    );
    // Decl-module signal: a plugin.labelle alongside the pack.labelle.
    try writeFileIn(tmp.dir, "plugin.labelle",
        \\.{ .name = "citizens", .manifest_version = 1 }
    );

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const result = loadPackFromDir(testing.allocator, tmp_path, "citizens");
    try testing.expectError(error.PackAndPluginManifestConflict, result);
}

test "loadPackFromDir: rejects a pack.labelle dir that also has build.zig" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writePackManifestFile(tmp.dir,
        \\.{
        \\    .name = "citizens",
        \\    .manifest_version = 1,
        \\    .convention_dirs = .copy_and_scan,
        \\}
    );
    // Decl-module signal: a build.zig means a real Zig package, not a pack.
    try writeFileIn(tmp.dir, "build.zig",
        \\pub fn build(b: *@import("std").Build) void { _ = b; }
    );

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const result = loadPackFromDir(testing.allocator, tmp_path, "citizens");
    try testing.expectError(error.PackAndPluginManifestConflict, result);
}

test "loadPackFromDir: rejects a pack.labelle dir that also has src/root.zig" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writePackManifestFile(tmp.dir,
        \\.{
        \\    .name = "citizens",
        \\    .manifest_version = 1,
        \\    .convention_dirs = .copy_and_scan,
        \\}
    );
    // Decl-module signal: an importable src/root.zig.
    try tmp.dir.createDirPath(testing.io, "src");
    var src_dir = try tmp.dir.openDir(testing.io, "src", .{});
    defer src_dir.close(testing.io);
    try writeFileIn(src_dir, "root.zig",
        \\pub const marker = 1;
    );

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const result = loadPackFromDir(testing.allocator, tmp_path, "citizens");
    try testing.expectError(error.PackAndPluginManifestConflict, result);
}

test "loadPackFromDir: a clean light pack (no decl-module content) still loads" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Only a pack.labelle + a convention dir — the genuine light-pack shape.
    try writePackManifestFile(tmp.dir,
        \\.{
        \\    .name = "citizens",
        \\    .manifest_version = 1,
        \\    .convention_dirs = .copy_and_scan,
        \\}
    );
    try tmp.dir.createDirPath(testing.io, "components");

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var manifest = (try loadPackFromDir(testing.allocator, tmp_path, "citizens")).?;
    defer manifest.deinit();

    try testing.expectEqualStrings("citizens", manifest.name);
}

test "loadFromDir: a clean decl-module plugin (no pack.labelle) still loads" {
    // The mutual-exclusivity guard lives on the pack path; a decl-module
    // plugin with a build.zig + src/root.zig but NO pack.labelle loads fine
    // through the plugin.labelle path.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeManifestFile(tmp.dir,
        \\.{ .name = "fsm", .manifest_version = 1 }
    );
    try writeFileIn(tmp.dir, "build.zig",
        \\pub fn build(b: *@import("std").Build) void { _ = b; }
    );

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var manifest = (try plugin_mod.loadFromDir(testing.allocator, tmp_path, "fsm")).?;
    defer manifest.deinit();
    try testing.expectEqualStrings("fsm", manifest.name);

    // And it must NOT parse as a pack (no pack.labelle present).
    try testing.expect((try loadPackFromDir(testing.allocator, tmp_path, "fsm")) == null);
}

// Local mirror of the plugin-path test helper (writes `plugin.labelle`),
// used by the cross-cutting decl-module-plugin test above. Kept here rather
// than reaching across modules for a 3-line createFile helper.
fn writeManifestFile(tmp_dir: std.Io.Dir, body: []const u8) !void {
    var f = try tmp_dir.createFile(testing.io, "plugin.labelle", .{});
    defer f.close(testing.io);
    try f.writeStreamingAll(testing.io, body);
}

/// True when `bytes` contains the literal token sequence
/// `.exposes = .all` (arbitrary whitespace around `=`). Deliberately
/// simple — commented-out occurrences can still match, but the hint is
/// only ever printed AFTER a real parse failure, so the worst case is a
/// redundant-but-related line above the real error.
fn exposesAllShorthand(bytes: []const u8) bool {
    var search: []const u8 = bytes;
    while (std.mem.indexOf(u8, search, ".exposes")) |i| {
        var rest = search[i + ".exposes".len ..];
        rest = std.mem.trimStart(u8, rest, " \t\r\n");
        if (rest.len > 0 and rest[0] == '=') {
            rest = std.mem.trimStart(u8, rest[1..], " \t\r\n");
            if (std.mem.startsWith(u8, rest, ".all")) return true;
        }
        search = search[i + 1 ..];
    }
    return false;
}
