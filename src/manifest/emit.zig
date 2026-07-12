//! Manifest orchestration extracted from `manifest.zig`
//! (behavior-preserving split, labelle-assembler#442 follow-up).
//!
//! The public entry point (`emitManifestSidecar`): threads the already-scanned
//! assembler data through the AST parse pass (`parse`), builds the pre-parsed
//! pack realms, drives the JSON writer (`json`), and writes
//! `<labelle_dir>/manifest.json`. Re-exported via the `manifest.zig` barrel.

const std = @import("std");
const config = @import("../config.zig");
const script_scanner = @import("../script_scanner.zig");
const scan = @import("../codegen/scan.zig");
const plugin_manifest = @import("../plugin_manifest.zig");
const scripting_declare = @import("../scripting_declare.zig");
const idents = @import("../codegen/idents.zig");
const parse = @import("parse.zig");
const json = @import("json.zig");

const ProjectConfig = config.ProjectConfig;
const ScriptEntry = script_scanner.ScriptScanner.ScriptEntry;
const PluginFlowNode = scan.PluginFlowNode;
const PluginEvent = scan.PluginEvent;
const PackRealm = json.PackRealm;

/// Filename emitted next to `flow_catalog.json` in `<game>/.labelle/`.
pub const MANIFEST_FILENAME = "manifest.json";

/// One declared pack, threaded from the generate-time scan (#499). `scan`
/// points into the caller's `pack_scans` list (name + import prefix + the
/// scanned component/event/prefab/hook stems); `exposes` / `depends_on` come
/// from the already-parsed `pack.labelle` (`pack_entries`). All three borrow
/// the caller's memory — valid only for the synchronous `emitManifestSidecar`
/// call, never stored past it.
pub const PackInput = struct {
    scan: *const scan.PackScan,
    exposes: ?plugin_manifest.PackExposes,
    depends_on: []const []const u8,
};

/// Public entry point: build the pack/feature manifest from the data the
/// assembler has already scanned and write `<labelle_dir>/manifest.json`.
///
/// Additive and best-effort — the caller treats a failure the same way it
/// treats a `flow_catalog.json` failure (log + continue). The whole build
/// happens in one arena; the final JSON is copied into `allocator` so it
/// survives arena teardown for the write.
pub fn emitManifestSidecar(
    allocator: std.mem.Allocator,
    cfg: ProjectConfig,
    game_dir: []const u8,
    labelle_dir: []const u8,
    target_dir: []const u8,
    component_names: []const []const u8,
    declared_components: []const scripting_declare.DeclaredComponent,
    declared_events: []const scripting_declare.DeclaredEvent,
    prefab_names: []const []const u8,
    enum_names: []const []const u8,
    event_names: []const []const u8,
    hook_names: []const []const u8,
    script_entries: []const ScriptEntry,
    flow_nodes: []const PluginFlowNode,
    plugin_events: []const PluginEvent,
    packs: []const PackInput,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // ── Game-realm detail (AST-parsed from the realm we author) ──────
    var components = try parse.parseStructDir(aa, game_dir, "components", component_names);
    var game_events = try parse.parseStructDir(aa, game_dir, "events", event_names);

    // ── Script-declared events (labelle-engine#772) ──────────────────
    // One GameEvents union variant each, exactly like `events/*.zig`, so
    // the game realm lists them too. Converted straight from the typed
    // schema (the same no-drift rationale as declared components below):
    // struct name = the Pascal transform codegen emits
    // (`idents.pathToPascal`), fields through `zigFieldTypeName`, no save
    // policy (events are never saved — the same null an AST-parsed
    // events/*.zig yields). Appended AFTER the events/ entries, mirroring
    // the union block's emission order.
    if (declared_events.len > 0) {
        var list: std.ArrayList(parse.StructDecl) = .empty;
        try list.ensureTotalCapacity(aa, game_events.len + declared_events.len);
        list.appendSliceAssumeCapacity(game_events);
        var pascal_buf: [128]u8 = undefined;
        for (declared_events) |de| {
            const fields = try aa.alloc(parse.Field, de.fields.len);
            for (de.fields, fields) |df, *out| out.* = .{
                .name = df.name,
                .zig_type = scripting_declare.zigFieldTypeName(df.default),
            };
            list.appendAssumeCapacity(.{
                .name = try aa.dupe(u8, idents.pathToPascal(de.name, &pascal_buf)),
                .save = null,
                .visibility = null,
                .fields = fields,
            });
        }
        game_events = try list.toOwnedSlice(aa);
    }

    // ── Script-declared components (labelle-assembler#585) ───────────
    // The declare phase registers these into the SAME game-root registry
    // namespace as `components/*.zig` (un-namespaced, via the generated
    // `scripting_components.zig`), so the game realm must list them too —
    // same name/save/visibility/fields shape as the AST-parsed entries.
    // Converted straight from the typed schema rather than re-parsing the
    // generated file: `savePolicyName`/`zigFieldTypeName` are the exact
    // mappings `renderComponentsFile` writes, so the sidecar can't drift
    // from codegen. Appended AFTER the components/ entries, mirroring the
    // registry block's emission order.
    if (declared_components.len > 0) {
        var list: std.ArrayList(parse.StructDecl) = .empty;
        try list.ensureTotalCapacity(aa, components.len + declared_components.len);
        list.appendSliceAssumeCapacity(components);
        for (declared_components) |dc| {
            const fields = try aa.alloc(parse.Field, dc.fields.len);
            for (dc.fields, fields) |df, *out| out.* = .{
                .name = df.name,
                .zig_type = scripting_declare.zigFieldTypeName(df.default),
            };
            list.appendAssumeCapacity(.{
                .name = dc.name,
                .save = scripting_declare.savePolicyName(dc.persist),
                // No visibility decl is rendered — the writer resolves null
                // to the engine default, exactly like a plain components/
                // file that declares none.
                .visibility = null,
                .fields = fields,
            });
        }
        components = try list.toOwnedSlice(aa);
    }

    // Game scripts only — plugin-shipped scripts belong to their plugin.
    var game_scripts: std.ArrayList(ScriptEntry) = .empty;
    for (script_entries) |e| {
        if (e.plugin_name != null) continue;
        try game_scripts.append(aa, e);
    }

    // ── Pack realms (#499): full detail, AST-parsed from the STAGED copies
    // under `<target>/packs/<name>/`. Same graceful degradation as the game
    // realm — an unreadable pack file becomes a name-only decl, never fatal.
    var pack_realms: std.ArrayList(PackRealm) = .empty;
    for (packs) |p| {
        const pack_root = try std.fs.path.join(aa, &.{ target_dir, p.scan.import_prefix });
        const pack_components = try parse.parseStructDir(aa, pack_root, "components", p.scan.component_names);
        const pack_events = try parse.parseStructDir(aa, pack_root, "events", p.scan.event_names);

        // The invisible `<pfx>__` namespace — the SINGLE source of truth
        // (`scan.packNamespacePrefix`) codegen registers under. It writes into
        // a stack buffer, so dupe into the arena before storing.
        var prefix_buf: [128]u8 = undefined;
        const prefix = try aa.dupe(u8, scan.packNamespacePrefix(p.scan.name, &prefix_buf));

        // This pack's scripts — already in `script_entries` tagged with the
        // pack name (`script_scanner` sets `plugin_name` = pack name).
        var pack_scripts: std.ArrayList(ScriptEntry) = .empty;
        for (script_entries) |e| {
            const pn = e.plugin_name orelse continue;
            if (std.mem.eql(u8, pn, p.scan.name)) try pack_scripts.append(aa, e);
        }

        try pack_realms.append(aa, .{
            .name = p.scan.name,
            .prefix = prefix,
            .components = pack_components,
            .component_stems = p.scan.component_names,
            .events = pack_events,
            .event_stems = p.scan.event_names,
            .prefab_names = p.scan.prefab_names,
            .hook_names = p.scan.hook_names,
            .scripts = try pack_scripts.toOwnedSlice(aa),
            .depends_on = p.depends_on,
            .exposes = p.exposes,
        });
    }

    // ── Build the JSON in `allocator` so it survives arena teardown ──
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try json.writeManifestJson(&aw.writer, .{
        .cfg = cfg,
        .components = components,
        .prefab_names = prefab_names,
        .enum_names = enum_names,
        .hook_names = hook_names,
        .game_events = game_events,
        .game_scripts = game_scripts.items,
        .flow_nodes = flow_nodes,
        .plugin_events = plugin_events,
        .packs = pack_realms.items,
    });
    const json_bytes = try aw.toOwnedSlice();
    defer allocator.free(json_bytes);

    try writeSidecar(labelle_dir, json_bytes);
}

fn writeSidecar(labelle_dir: []const u8, bytes: []const u8) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, labelle_dir);
    var dir = try cwd.openDir(io, labelle_dir, .{});
    defer dir.close(io);
    const file = try dir.createFile(io, MANIFEST_FILENAME, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

// ─── Tests ──────────────────────────────────────────────────────────────

test "emitManifestSidecar: writes a parseable sidecar for an empty project" {
    const aa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = config.globalIo();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", aa);
    defer aa.free(dir);

    const cfg = ProjectConfig{ .name = "tmp" };
    try emitManifestSidecar(aa, cfg, dir, dir, dir, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{});

    const path = try std.fs.path.join(aa, &.{ dir, MANIFEST_FILENAME });
    defer aa.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, aa, .limited(1 << 20));
    defer aa.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, aa, bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.contains("index"));
    try std.testing.expect(root.contains("realms"));
    try std.testing.expectEqual(@as(usize, 1), root.get("realms").?.array.items.len); // game only
}

test "emitManifestSidecar: AST-parses a staged pack's components" {
    const aa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = config.globalIo();

    // Stage `packs/citizens/components/worker.zig` under the target dir —
    // the same layout `scanPack` writes before the manifest runs.
    try tmp.dir.createDirPath(io, "packs/citizens/components");
    {
        var cdir = try tmp.dir.openDir(io, "packs/citizens/components", .{});
        defer cdir.close(io);
        var f = try cdir.createFile(io, "worker.zig", .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\pub const Worker = struct {
            \\    pub const visibility = .pack;
            \\    hunger: f32 = 0,
            \\    home: ?u64 = null,
            \\};
            \\
        );
    }

    const dir = try tmp.dir.realPathFileAlloc(io, ".", aa);
    defer aa.free(dir);

    var pack_scan = scan.PackScan{
        .name = "citizens",
        .import_prefix = "packs/citizens",
        .component_names = &.{"worker"},
        .event_names = &.{},
        .prefab_names = &.{},
        .hook_names = &.{},
    };
    const packs = [_]PackInput{.{ .scan = &pack_scan, .exposes = null, .depends_on = &.{} }};

    const cfg = ProjectConfig{ .name = "tmp", .plugins = &.{.{ .name = "citizens" }} };
    // game_dir and target_dir both point at the tmp dir; the pack files live
    // under `<target>/packs/citizens/`.
    try emitManifestSidecar(aa, cfg, dir, dir, dir, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &packs);

    const path = try std.fs.path.join(aa, &.{ dir, MANIFEST_FILENAME });
    defer aa.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, aa, .limited(1 << 20));
    defer aa.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, aa, bytes, .{});
    defer parsed.deinit();
    const realms = parsed.value.object.get("realms").?.array;
    const citizens = json.findRealm(realms, "citizens").?;
    try std.testing.expectEqualStrings("pack", citizens.get("tier").?.string);
    const comp0 = citizens.get("components").?.array.items[0].object;
    try std.testing.expectEqualStrings("Worker", comp0.get("name").?.string);
    try std.testing.expectEqualStrings("citizens__Worker", comp0.get("emitted_name").?.string);
    try std.testing.expectEqualStrings("pack", comp0.get("visibility").?.string);
    try std.testing.expectEqualStrings("?u64", comp0.get("fields").?.object.get("home").?.string);
}

test "emitManifestSidecar: lists script-declared components in the game realm (#585)" {
    const aa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = config.globalIo();

    // One hand-written game component beside the declaration, proving the
    // declared entry is APPENDED to (not replacing) the components/ scan.
    try tmp.dir.createDirPath(io, "components");
    {
        var cdir = try tmp.dir.openDir(io, "components", .{});
        defer cdir.close(io);
        var f = try cdir.createFile(io, "bed.zig", .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\pub const Bed = struct { sleeper: ?u64 = null };
            \\
        );
    }

    const dir = try tmp.dir.realPathFileAlloc(io, ".", aa);
    defer aa.free(dir);

    // The schema the declare phase extracted — every mapping-relevant field
    // type (persist policy, entity→u64, str→[]const u8).
    const declared_fields = [_]scripting_declare.DeclaredField{
        .{ .name = "level", .default = .{ .f32 = 1.0 } },
        .{ .name = "owner", .default = .{ .entity = 0 } },
        .{ .name = "label", .default = .{ .str = "x" } },
    };
    const declared = [_]scripting_declare.DeclaredComponent{
        .{ .name = "Hunger", .persist = .transient, .fields = &declared_fields },
    };

    const cfg = ProjectConfig{ .name = "tmp" };
    try emitManifestSidecar(aa, cfg, dir, dir, dir, &.{"bed"}, &declared, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{});

    const path = try std.fs.path.join(aa, &.{ dir, MANIFEST_FILENAME });
    defer aa.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, aa, .limited(1 << 20));
    defer aa.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, aa, bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    // Detail realm: components/ entry first, declared entry appended with
    // the codegen-exact save policy + field types.
    const realms = root.get("realms").?.array;
    const game = json.findRealm(realms, "game").?;
    const comps = game.get("components").?.array;
    try std.testing.expectEqual(@as(usize, 2), comps.items.len);
    try std.testing.expectEqualStrings("Bed", comps.items[0].object.get("name").?.string);
    const hunger = comps.items[1].object;
    try std.testing.expectEqualStrings("Hunger", hunger.get("name").?.string);
    try std.testing.expectEqualStrings("transient", hunger.get("save").?.string);
    const fields = hunger.get("fields").?.object;
    try std.testing.expectEqualStrings("f32", fields.get("level").?.string);
    try std.testing.expectEqualStrings("u64", fields.get("owner").?.string);
    try std.testing.expectEqualStrings("[]const u8", fields.get("label").?.string);

    // Index realm: `owns.components` carries the declared name too.
    const realms_idx = root.get("index").?.object.get("realms").?.array;
    const game_idx = json.findRealm(realms_idx, "game").?;
    const owned = game_idx.get("owns").?.object.get("components").?.array;
    try std.testing.expectEqual(@as(usize, 2), owned.items.len);
    try std.testing.expectEqualStrings("Hunger", owned.items[1].string);
}
