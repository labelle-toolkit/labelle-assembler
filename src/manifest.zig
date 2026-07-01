//! Pack/feature manifest emitter — labelle-assembler#442 (Packs
//! initiative; RFC Flying-Platform/flying-platform-labelle#561 §7;
//! umbrella labelle-engine#651).
//!
//! `flow_catalog.json` (RFC#178) already gives the *flow editor* its
//! palette (FlowNodes / PinStyles / Events / Coercions per plugin). The
//! **manifest** answers a different question — the one an *agent* (or a
//! human) asks before adding a feature: *which realm owns this · what
//! shapes do I touch · what already exists · what may I call across
//! packs · what's the recipe.* It's emitted alongside the flow catalog
//! as `<game>/.labelle/manifest.json`.
//!
//! ## Two-tier shape (RFC §7 — realm-structured + sliceable)
//!
//! ```jsonc
//! {
//!   "schema": "labelle.manifest/v1",
//!   "generated_at": "2026-...Z",
//!   "index": {                       // always loaded — the realm map
//!     "contracts": { "events": [...], "enums": [...], "registries": [] },
//!     "realms": [
//!       { "name": "game", "tier": "root",
//!         "owns": { "components": [...], "prefabs": [...], "scripts": [...],
//!                   "events": [...], "enums": [...], "hooks": [...] },
//!         "depends_on": ["box2d", ...],         // plugins the game pulls in
//!         "exposes": { "commands": [...], "queries": [...] },
//!         "recipes": [] },
//!       { "name": "box2d", "tier": "plugin", "version": "...",
//!         "owns": { "events": [...], "flow_nodes": [...] },
//!         "depends_on": [],
//!         "exposes": { "commands": [...], "queries": [...] },
//!         "recipes": [] }
//!     ]
//!   },
//!   "realms": [                      // per-realm detail — fetch the one in play
//!     { "name": "game", "tier": "root",
//!       "components": [ { "name": "Bed", "save": "saveable",
//!                         "fields": { "sleeper": "?u64", "x": "f32" } } ],
//!       "events":     [ { "name": "WorkerSleepStart",
//!                         "payload": { "worker_id": "u64", "bed_id": "u64" },
//!                         "emitted_by": [], "subscribed_by": [] } ],
//!       "scripts":    [ { "name": "00_spawn", "rel_path": "00_spawn.zig",
//!                         "order": 0, "states": [] } ],
//!       "enums": [...], "prefabs": [...], "recipes": [] },
//!     { "name": "box2d", "tier": "plugin",
//!       "events": [ { "name": "collision_begin" } ],   // payloads in flow_catalog.json
//!       "flow_nodes": [ { "name": "apply_impulse", "kind": "command" } ],
//!       "recipes": [] }
//!   ]
//! }
//! ```
//!
//! ## Derivation (RFC §7 — drift-free because generated)
//!
//! Everything except recipes is derived from the code the assembler has
//! already scanned, so the manifest can't drift from the source:
//!
//! - **Game realm** owns the project-root convention dirs. Component
//!   field schemas + save policy and event payloads are AST-parsed here
//!   (`parseStructFile`) from `<game>/components/*.zig` and
//!   `<game>/events/*.zig` — the realm an agent edits gets full detail.
//! - **Plugin / engine realms** surface names + the public verb surface
//!   (`exposes`) derived from the already-discovered FlowNodes
//!   (`PluginFlowNode`, command = void impl / query = reporter) and
//!   Events (`PluginEvent`). Plugin event *payloads* already live in
//!   `flow_catalog.json` per-plugin, so the manifest references plugins
//!   by name rather than re-walking them (minimality guardrail: read the
//!   realm you're changing, not every field of every dependency).
//! - `depends_on` for the game realm = the plugins declared in
//!   `project.labelle`.
//!
//! ## Deferred (called out, not silently dropped)
//!
//! - **`recipes`** — emitted as an empty array on every realm. The one
//!   *non-*derivable field; it shares the scaffold's template source
//!   (`labelle add <kind>`, cli #271/#scaffold) so recipe and scaffold
//!   stay a single definition. Forward-referenced here.
//! - **`emitted_by` / `subscribed_by`** event cross-refs — emitted as
//!   empty arrays. The AST emit/subscribe extraction across every script
//!   is a larger pass (the scanner doesn't track call sites yet); the
//!   shape is in place so a follow-up can fill it without a schema bump.
//! - **`visibility`** (pack vs public) — comes from `pack.labelle`,
//!   which doesn't exist until the pack-convention ticket lands; omitted
//!   for now rather than guessed.

const std = @import("std");
const config = @import("config.zig");
const script_scanner = @import("script_scanner.zig");
const scan = @import("codegen/scan.zig");
const jw = @import("flow_catalog/json_writer.zig");
const idents = @import("codegen/idents.zig");

const ProjectConfig = config.ProjectConfig;
const ScriptEntry = script_scanner.ScriptScanner.ScriptEntry;
const PluginFlowNode = scan.PluginFlowNode;
const PluginEvent = scan.PluginEvent;

/// Filename emitted next to `flow_catalog.json` in `<game>/.labelle/`.
pub const MANIFEST_FILENAME = "manifest.json";

/// Schema version stamped into the emitted JSON so consumers can gate.
pub const SCHEMA_VERSION = "labelle.manifest/v1";

// ── Derived data shapes ─────────────────────────────────────────────────

/// One struct field: identifier + verbatim Zig source text of its type.
const Field = struct {
    name: []const u8,
    zig_type: []const u8,
};

/// One `pub const <Name> = struct { ... }` parsed from a game-root
/// `components/*.zig` or `events/*.zig` file. `save` is the policy enum
/// literal (`saveable` / `transient` / …) pulled from a member
/// `pub const save = ...Saveable(.<policy>, ...)` decl, or null when the
/// struct declares no save policy (every event, most plain components).
const StructDecl = struct {
    name: []const u8,
    save: ?[]const u8,
    fields: []const Field,
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
    component_names: []const []const u8,
    prefab_names: []const []const u8,
    enum_names: []const []const u8,
    event_names: []const []const u8,
    hook_names: []const []const u8,
    script_entries: []const ScriptEntry,
    flow_nodes: []const PluginFlowNode,
    plugin_events: []const PluginEvent,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // ── Game-realm detail (AST-parsed from the realm we author) ──────
    const components = try parseStructDir(aa, game_dir, "components", component_names);
    const game_events = try parseStructDir(aa, game_dir, "events", event_names);

    // Game scripts only — plugin-shipped scripts belong to their plugin.
    var game_scripts: std.ArrayList(ScriptEntry) = .empty;
    for (script_entries) |e| {
        if (e.plugin_name != null) continue;
        try game_scripts.append(aa, e);
    }

    // ── Build the JSON in `allocator` so it survives arena teardown ──
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try writeManifestJson(&aw.writer, .{
        .cfg = cfg,
        .components = components,
        .prefab_names = prefab_names,
        .enum_names = enum_names,
        .hook_names = hook_names,
        .game_events = game_events,
        .game_scripts = game_scripts.items,
        .flow_nodes = flow_nodes,
        .plugin_events = plugin_events,
    });
    const json_bytes = try aw.toOwnedSlice();
    defer allocator.free(json_bytes);

    try writeSidecar(labelle_dir, json_bytes);
}

// ── Game-realm struct parsing (components + events) ──────────────────────

/// Parse every `<game_dir>/<folder>/<name>.zig` file (one struct per
/// file by convention) into `StructDecl`s.
///
/// The decl the assembler actually registers is the *file-stem Pascal*
/// decl (`components/<name>.zig` → `pub const <pathToPascal(name)> =
/// struct {...}`), so this emits exactly that one decl per file — a
/// component/event file may also declare helper containers (a private
/// `const Options = struct {}` / `pub const Clip = enum {}`), and those
/// must NOT leak into the manifest as phantom components/events.
///
/// Read / parse failures degrade to a **name-only** `StructDecl` (the
/// file-stem Pascal name, empty fields) rather than dropping the entry:
/// the generated registries still import that file-stem decl from
/// `component_names` / `event_names`, so omitting it would wrongly report
/// an existing component/event as absent. `OutOfMemory` is the one error
/// that propagates — a real allocation failure must not masquerade as
/// graceful degradation.
fn parseStructDir(
    aa: std.mem.Allocator,
    game_dir: []const u8,
    folder: []const u8,
    names: []const []const u8,
) ![]const StructDecl {
    const io = config.globalIo();
    var list: std.ArrayList(StructDecl) = .empty;
    for (names) |name| {
        // The registry-visible decl name, matching how `blocks/registries`
        // names components (`velocity` → `Velocity`).
        var pascal_buf: [128]u8 = undefined;
        const decl_name = idents.pathToPascal(name, &pascal_buf);

        const rel = try std.fmt.allocPrint(aa, "{s}.zig", .{name});
        const path = try std.fs.path.join(aa, &.{ game_dir, folder, rel });

        const src = std.Io.Dir.cwd().readFileAlloc(io, path, aa, .limited(2 * 1024 * 1024)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try list.append(aa, try nameOnlyDecl(aa, decl_name));
                continue;
            },
        };
        // `parseStructFile` only fails with `OutOfMemory` — `std.zig.Ast`
        // captures syntax errors in the tree rather than returning them,
        // so a garbled file parses to an AST with no matching decl and is
        // handled by the name-only fallback below, not by a caught error.
        const decls = try parseStructFile(aa, src);

        // Emit only the file-stem decl; ignore any helper containers.
        var matched = false;
        for (decls) |d| {
            if (std.mem.eql(u8, d.name, decl_name)) {
                try list.append(aa, d);
                matched = true;
                break;
            }
        }
        // No decl matched the file stem (empty / garbled source, or an
        // unconventional decl name) — degrade to name-only so the manifest
        // still lists what the registry imports.
        if (!matched) try list.append(aa, try nameOnlyDecl(aa, decl_name));
    }
    return list.toOwnedSlice(aa);
}

/// A `StructDecl` carrying only the registry name — the graceful-degradation
/// stand-in for a component/event file the AST pass couldn't read or match.
fn nameOnlyDecl(aa: std.mem.Allocator, name: []const u8) !StructDecl {
    return .{ .name = try aa.dupe(u8, name), .save = null, .fields = &.{} };
}

/// AST-walk one source buffer for top-level `pub const <Name> = struct
/// { ... }` declarations, pulling each struct's flat field list (name +
/// type source text) and — if present — its `save` policy.
fn parseStructFile(aa: std.mem.Allocator, src: []const u8) ![]const StructDecl {
    const src_z = try aa.dupeZ(u8, src);
    var ast = try std.zig.Ast.parse(aa, src_z, .zig);
    defer ast.deinit(aa);

    var decls: std.ArrayList(StructDecl) = .empty;
    for (ast.rootDecls()) |decl_idx| {
        const vd = ast.fullVarDecl(decl_idx) orelse continue;
        const init_node = vd.ast.init_node.unwrap() orelse continue;

        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const container = ast.fullContainerDecl(&buf, init_node) orelse continue;

        const name_tok = vd.ast.mut_token + 1;
        const name = ast.tokenSlice(name_tok);

        var fields: std.ArrayList(Field) = .empty;
        var save: ?[]const u8 = null;
        for (container.ast.members) |m| {
            if (ast.fullContainerField(m)) |fd| {
                const fname = ast.tokenSlice(fd.ast.main_token);
                const ftype_node = fd.ast.type_expr.unwrap() orelse continue;
                const ftype = ast.getNodeSource(ftype_node);
                try fields.append(aa, .{
                    .name = try aa.dupe(u8, fname),
                    .zig_type = try aa.dupe(u8, std.mem.trim(u8, ftype, " \t\r\n")),
                });
                continue;
            }
            // Not a field — look for the `pub const save = ...Saveable(.x, ...)`
            // decl so the manifest can surface the save policy.
            if (save == null) {
                if (ast.fullVarDecl(m)) |member_vd| {
                    const mname = ast.tokenSlice(member_vd.ast.mut_token + 1);
                    if (std.mem.eql(u8, mname, "save")) {
                        // `try` (not `catch null`): a null return means "no
                        // policy literal found" and is expected, but an
                        // `OutOfMemory` must propagate rather than be
                        // silently collapsed to "no save policy".
                        save = try extractSavePolicy(aa, ast.getNodeSource(m));
                    }
                }
            }
        }

        try decls.append(aa, .{
            .name = try aa.dupe(u8, name),
            .save = save,
            .fields = try fields.toOwnedSlice(aa),
        });
    }
    return decls.toOwnedSlice(aa);
}

/// Pull the policy enum literal out of a `save` decl's source, e.g.
/// `...Saveable(.saveable, @This(), .{...})` → `"saveable"`. Returns null
/// when the marker / literal isn't found.
fn extractSavePolicy(aa: std.mem.Allocator, decl_src: []const u8) !?[]const u8 {
    const marker = "Saveable(";
    const at = std.mem.indexOf(u8, decl_src, marker) orelse return null;
    var i = at + marker.len;
    while (i < decl_src.len and (decl_src[i] == ' ' or decl_src[i] == '\t' or decl_src[i] == '\n' or decl_src[i] == '\r')) i += 1;
    if (i >= decl_src.len or decl_src[i] != '.') return null;
    i += 1;
    const start = i;
    while (i < decl_src.len and (std.ascii.isAlphanumeric(decl_src[i]) or decl_src[i] == '_')) i += 1;
    if (i == start) return null;
    return try aa.dupe(u8, decl_src[start..i]);
}

// ── JSON emission ────────────────────────────────────────────────────────

const ManifestData = struct {
    cfg: ProjectConfig,
    components: []const StructDecl,
    prefab_names: []const []const u8,
    enum_names: []const []const u8,
    hook_names: []const []const u8,
    game_events: []const StructDecl,
    game_scripts: []const ScriptEntry,
    flow_nodes: []const PluginFlowNode,
    plugin_events: []const PluginEvent,
};

/// The sentinel game-realm name. Plugin realms use their `project.labelle`
/// name; the engine's lifecycle events / nodes group under `engine`.
const GAME_REALM = "game";
const ENGINE_REALM = "engine";

/// Hand-written pretty-printer — same rationale as the flow catalog:
/// small, stable, diffable, no schema needed to hand-read.
fn writeManifestJson(w: *std.Io.Writer, d: ManifestData) !void {
    var ts_buf: [32]u8 = undefined;
    const ts = jw.formatTimestamp(&ts_buf);

    try w.writeAll("{\n");
    try w.print("  \"schema\": \"{s}\",\n", .{SCHEMA_VERSION});
    try w.print("  \"generated_at\": \"{s}\",\n", .{ts});

    try writeIndex(w, d);
    try w.writeAll(",\n");
    try writeRealmDetail(w, d);

    try w.writeAll("\n}\n");
}

// ── index (always loaded) ────────────────────────────────────────────────

fn writeIndex(w: *std.Io.Writer, d: ManifestData) !void {
    try w.writeAll("  \"index\": {\n");

    // contracts — the shared cross-pack vocabulary (events + enums).
    try w.writeAll("    \"contracts\": {\n      \"events\": ");
    try writeContractEvents(w, d);
    try w.writeAll(",\n      \"enums\": ");
    try writeStringArray(w, d.enum_names);
    try w.writeAll(",\n      \"registries\": []\n    },\n");

    // realms — the realm map. Game first, then the engine realm (only
    // when engine lifecycle events were discovered — otherwise the
    // `engine.<event>` contract entries would reference a realm that
    // never appears here), then the declared plugins. A leading comma
    // before each subsequent realm keeps the separator logic uniform.
    try w.writeAll("    \"realms\": [\n");

    try writeGameIndexRealm(w, d);
    if (hasEngineEvents(d)) {
        try w.writeAll(",\n");
        try writeNonGameIndexRealm(w, d, ENGINE_REALM, "engine", null);
    }
    for (d.cfg.plugins) |plugin| {
        try w.writeAll(",\n");
        try writeNonGameIndexRealm(w, d, plugin.name, "plugin", plugin.version);
    }
    try w.writeAll("\n    ]\n  }");
}

/// True when `discoverPluginEvents` surfaced any engine lifecycle event
/// (stored under the literal `engine` realm label). Gates emission of the
/// dedicated engine realm so its `contracts.events` entries resolve.
fn hasEngineEvents(d: ManifestData) bool {
    for (d.plugin_events) |e| {
        if (std.mem.eql(u8, e.plugin_import_name, ENGINE_REALM)) return true;
    }
    return false;
}

fn writeGameIndexRealm(w: *std.Io.Writer, d: ManifestData) !void {
    try w.writeAll("      {\n        \"name\": \"" ++ GAME_REALM ++ "\",\n        \"tier\": \"root\",\n");
    try w.writeAll("        \"owns\": {\n          \"components\": ");
    try writeStructNameArray(w, d.components);
    try w.writeAll(",\n          \"prefabs\": ");
    try writeStringArray(w, d.prefab_names);
    try w.writeAll(",\n          \"scripts\": ");
    try writeScriptNameArray(w, d.game_scripts);
    try w.writeAll(",\n          \"events\": ");
    try writeStructNameArray(w, d.game_events);
    try w.writeAll(",\n          \"enums\": ");
    try writeStringArray(w, d.enum_names);
    try w.writeAll(",\n          \"hooks\": ");
    try writeStringArray(w, d.hook_names);
    try w.writeAll("\n        },\n");
    // depends_on — the plugins the game pulls in.
    try w.writeAll("        \"depends_on\": ");
    try writePluginNameArray(w, d.cfg);
    try w.writeAll(",\n");
    try writeExposes(w, d, GAME_REALM, true);
    try w.writeAll(",\n        \"recipes\": []\n      }");
}

/// Index entry for a non-game realm — a plugin (`tier = "plugin"`, with a
/// `version`) or the engine peer (`tier = "engine"`, no version). Both
/// own only events + flow_nodes and expose the same verb surface, so they
/// share this writer.
fn writeNonGameIndexRealm(
    w: *std.Io.Writer,
    d: ManifestData,
    name: []const u8,
    tier: []const u8,
    version: ?[]const u8,
) !void {
    try w.writeAll("      {\n        \"name\": ");
    try jw.writeJsonString(w, name);
    try w.writeAll(",\n        \"tier\": ");
    try jw.writeJsonString(w, tier);
    if (version) |v| {
        try w.writeAll(",\n        \"version\": ");
        try jw.writeJsonString(w, v);
    }
    try w.writeAll(",\n        \"owns\": {\n          \"events\": ");
    try writePluginEventNameArray(w, d.plugin_events, name);
    try w.writeAll(",\n          \"flow_nodes\": ");
    try writeFlowNodeNameArray(w, d.flow_nodes, name);
    try w.writeAll("\n        },\n        \"depends_on\": [],\n");
    try writeExposes(w, d, name, false);
    try w.writeAll(",\n        \"recipes\": []\n      }");
}

/// `exposes` — the public verb surface: FlowNode commands (void impl)
/// vs queries (reporters). For the game realm we pick script-declared
/// nodes; for a plugin realm we pick nodes whose module is that plugin.
fn writeExposes(w: *std.Io.Writer, d: ManifestData, realm: []const u8, is_game: bool) !void {
    try w.writeAll("        \"exposes\": {\n          \"commands\": ");
    try writeExposeKind(w, d.flow_nodes, realm, is_game, true);
    try w.writeAll(",\n          \"queries\": ");
    try writeExposeKind(w, d.flow_nodes, realm, is_game, false);
    try w.writeAll("\n        }");
}

fn writeExposeKind(
    w: *std.Io.Writer,
    flow_nodes: []const PluginFlowNode,
    realm: []const u8,
    is_game: bool,
    commands: bool,
) !void {
    try w.writeAll("[");
    var first = true;
    for (flow_nodes) |n| {
        if (!nodeBelongsToRealm(n, realm, is_game)) continue;
        // command == void impl; query == reporter (non-void).
        if (n.is_void != commands) continue;
        if (!first) try w.writeAll(", ");
        if (is_game) {
            // The game realm aggregates every game script, so a bare
            // `spawn` from two scripts would collide. Qualify with the
            // script module label (part of the public registry name).
            try writeScriptQualifiedJsonString(w, n.module_import_path, n.node_name);
        } else {
            // A plugin realm scopes its own nodes; `owns.flow_nodes` lists
            // them bare too, and node names are unique within a plugin.
            try jw.writeJsonString(w, n.node_name);
        }
        first = false;
    }
    try w.writeAll("]");
}

fn nodeBelongsToRealm(n: PluginFlowNode, realm: []const u8, is_game: bool) bool {
    if (is_game) return n.is_script;
    if (n.is_script) return false;
    return std.mem.eql(u8, n.module_import_path, realm);
}

// ── per-realm detail (fetched for the realm in play) ─────────────────────

fn writeRealmDetail(w: *std.Io.Writer, d: ManifestData) !void {
    try w.writeAll("  \"realms\": [\n");

    // Same realm ordering as the index: game, engine (when it has
    // events), then plugins.
    try writeGameRealmDetail(w, d);
    if (hasEngineEvents(d)) {
        try w.writeAll(",\n");
        try writeNonGameRealmDetail(w, d, ENGINE_REALM, "engine");
    }
    for (d.cfg.plugins) |plugin| {
        try w.writeAll(",\n");
        try writeNonGameRealmDetail(w, d, plugin.name, "plugin");
    }
    try w.writeAll("\n  ]");
}

fn writeGameRealmDetail(w: *std.Io.Writer, d: ManifestData) !void {
    try w.writeAll("    {\n      \"name\": \"" ++ GAME_REALM ++ "\",\n      \"tier\": \"root\",\n");

    // components — name + save policy + field schema.
    try w.writeAll("      \"components\": [");
    if (d.components.len == 0) {
        try w.writeAll("],\n");
    } else {
        try w.writeAll("\n");
        for (d.components, 0..) |c, ci| {
            try w.writeAll("        { \"name\": ");
            try jw.writeJsonString(w, c.name);
            try w.writeAll(", \"save\": ");
            if (c.save) |s| try jw.writeJsonString(w, s) else try w.writeAll("null");
            try w.writeAll(", \"fields\": ");
            try writeFieldObject(w, c.fields);
            try w.writeAll(" }");
            if (ci + 1 < d.components.len) try w.writeAll(",");
            try w.writeAll("\n");
        }
        try w.writeAll("      ],\n");
    }

    // events — name + payload + (deferred) cross-refs.
    try w.writeAll("      \"events\": [");
    if (d.game_events.len == 0) {
        try w.writeAll("],\n");
    } else {
        try w.writeAll("\n");
        for (d.game_events, 0..) |e, ei| {
            try w.writeAll("        { \"name\": ");
            try jw.writeJsonString(w, e.name);
            try w.writeAll(", \"payload\": ");
            try writeFieldObject(w, e.fields);
            try w.writeAll(", \"emitted_by\": [], \"subscribed_by\": [] }");
            if (ei + 1 < d.game_events.len) try w.writeAll(",");
            try w.writeAll("\n");
        }
        try w.writeAll("      ],\n");
    }

    // scripts — name + rel_path + execution order + state scope.
    try w.writeAll("      \"scripts\": [");
    if (d.game_scripts.len == 0) {
        try w.writeAll("],\n");
    } else {
        try w.writeAll("\n");
        for (d.game_scripts, 0..) |s, si| {
            try w.writeAll("        { \"name\": ");
            try jw.writeJsonString(w, s.name);
            try w.writeAll(", \"rel_path\": ");
            try jw.writeJsonString(w, s.rel_path);
            try w.writeAll(", \"order\": ");
            if (s.sort_order) |o| try w.print("{d}", .{o}) else try w.writeAll("null");
            try w.writeAll(", \"states\": ");
            try writeStringArray(w, s.states);
            try w.writeAll(" }");
            if (si + 1 < d.game_scripts.len) try w.writeAll(",");
            try w.writeAll("\n");
        }
        try w.writeAll("      ],\n");
    }

    try w.writeAll("      \"enums\": ");
    try writeStringArray(w, d.enum_names);
    try w.writeAll(",\n      \"prefabs\": ");
    try writeStringArray(w, d.prefab_names);
    try w.writeAll(",\n      \"recipes\": []\n    }");
}

/// Per-realm detail for a non-game realm (plugin or engine peer). Events
/// are names-only (payloads live in `flow_catalog.json` per module);
/// flow_nodes carry their command/query kind.
fn writeNonGameRealmDetail(w: *std.Io.Writer, d: ManifestData, name: []const u8, tier: []const u8) !void {
    try w.writeAll("    {\n      \"name\": ");
    try jw.writeJsonString(w, name);
    try w.writeAll(",\n      \"tier\": ");
    try jw.writeJsonString(w, tier);
    try w.writeAll(",\n");

    // events — names only; payloads live in flow_catalog.json per-plugin.
    try w.writeAll("      \"events\": [");
    var first = true;
    for (d.plugin_events) |e| {
        if (!std.mem.eql(u8, e.plugin_import_name, name)) continue;
        if (!first) try w.writeAll(",");
        try w.writeAll("\n        { \"name\": ");
        try jw.writeJsonString(w, e.event_name);
        try w.writeAll(" }");
        first = false;
    }
    if (first) try w.writeAll("],\n") else try w.writeAll("\n      ],\n");

    // flow_nodes — name + kind (command/query).
    try w.writeAll("      \"flow_nodes\": [");
    first = true;
    for (d.flow_nodes) |n| {
        if (n.is_script or !std.mem.eql(u8, n.module_import_path, name)) continue;
        if (!first) try w.writeAll(",");
        try w.writeAll("\n        { \"name\": ");
        try jw.writeJsonString(w, n.node_name);
        try w.writeAll(", \"kind\": ");
        try jw.writeJsonString(w, if (n.is_void) "command" else "query");
        try w.writeAll(" }");
        first = false;
    }
    if (first) try w.writeAll("],\n") else try w.writeAll("\n      ],\n");

    try w.writeAll("      \"recipes\": []\n    }");
}

// ── small array / object writers ─────────────────────────────────────────

fn writeStringArray(w: *std.Io.Writer, items: []const []const u8) !void {
    try w.writeAll("[");
    for (items, 0..) |s, i| {
        if (i > 0) try w.writeAll(", ");
        try jw.writeJsonString(w, s);
    }
    try w.writeAll("]");
}

fn writeStructNameArray(w: *std.Io.Writer, items: []const StructDecl) !void {
    try w.writeAll("[");
    for (items, 0..) |s, i| {
        if (i > 0) try w.writeAll(", ");
        try jw.writeJsonString(w, s.name);
    }
    try w.writeAll("]");
}

fn writeScriptNameArray(w: *std.Io.Writer, items: []const ScriptEntry) !void {
    try w.writeAll("[");
    for (items, 0..) |s, i| {
        if (i > 0) try w.writeAll(", ");
        try jw.writeJsonString(w, s.name);
    }
    try w.writeAll("]");
}

fn writePluginNameArray(w: *std.Io.Writer, cfg: ProjectConfig) !void {
    try w.writeAll("[");
    for (cfg.plugins, 0..) |p, i| {
        if (i > 0) try w.writeAll(", ");
        try jw.writeJsonString(w, p.name);
    }
    try w.writeAll("]");
}

fn writePluginEventNameArray(w: *std.Io.Writer, events: []const PluginEvent, plugin: []const u8) !void {
    try w.writeAll("[");
    var first = true;
    for (events) |e| {
        if (!std.mem.eql(u8, e.plugin_import_name, plugin)) continue;
        if (!first) try w.writeAll(", ");
        try jw.writeJsonString(w, e.event_name);
        first = false;
    }
    try w.writeAll("]");
}

fn writeFlowNodeNameArray(w: *std.Io.Writer, nodes: []const PluginFlowNode, plugin: []const u8) !void {
    try w.writeAll("[");
    var first = true;
    for (nodes) |n| {
        if (n.is_script or !std.mem.eql(u8, n.module_import_path, plugin)) continue;
        if (!first) try w.writeAll(", ");
        try jw.writeJsonString(w, n.node_name);
        first = false;
    }
    try w.writeAll("]");
}

/// Every game event plus engine/plugin events — the shared event
/// vocabulary an agent can subscribe to across realms. Each entry is
/// **realm-qualified** in the dotted `<realm>.<event>` form the rest of
/// the toolchain uses (`engine.tick`, `box2d.collision_begin`; see the
/// flow catalog's `qualified` field). Without the realm prefix two realms
/// exposing the same bare event name (`engine.tick` vs a plugin `tick`,
/// or two plugins' `collision_begin`) would collide into one ambiguous
/// entry.
fn writeContractEvents(w: *std.Io.Writer, d: ManifestData) !void {
    try w.writeAll("[");
    var first = true;
    for (d.game_events) |e| {
        if (!first) try w.writeAll(", ");
        try writeQualifiedJsonString(w, GAME_REALM, e.name);
        first = false;
    }
    for (d.plugin_events) |e| {
        if (!first) try w.writeAll(", ");
        // `plugin_import_name` is the realm label — the plugin's
        // `project.labelle` name, or the literal `engine` for engine
        // lifecycle events (`discoverPluginEvents`).
        try writeQualifiedJsonString(w, e.plugin_import_name, e.event_name);
        first = false;
    }
    try w.writeAll("]");
}

/// Write a `"<realm>.<name>"` JSON string — the dotted realm-qualified
/// form — without allocating an intermediate join. Both halves are
/// escaped identically to `jw.writeJsonString`.
fn writeQualifiedJsonString(w: *std.Io.Writer, realm: []const u8, name: []const u8) !void {
    try w.writeByte('"');
    try writeJsonStringBody(w, realm);
    try w.writeByte('.');
    try writeJsonStringBody(w, name);
    try w.writeByte('"');
}

/// Write a script FlowNode's qualified `"<module_label>.<node>"` name,
/// where `<module_label>` is the script `rel_path` with its `.zig`
/// stripped and path separators mapped to dots (`flows/hit_counter.zig`
/// → `flows.hit_counter`) — the same dotted module label the flow
/// catalog builds via `scriptModuleLabel`. The script module path is
/// part of the public registry name, so two scripts both exposing
/// `spawn` stay distinct (`flows.hit_counter.spawn` vs `combat.spawn`).
fn writeScriptQualifiedJsonString(w: *std.Io.Writer, rel_path: []const u8, node: []const u8) !void {
    const stem = if (std.mem.endsWith(u8, rel_path, ".zig"))
        rel_path[0 .. rel_path.len - ".zig".len]
    else
        rel_path;
    try w.writeByte('"');
    for (stem) |c| {
        try writeJsonStringChar(w, if (c == '/' or c == '\\') '.' else c);
    }
    try w.writeByte('.');
    try writeJsonStringBody(w, node);
    try w.writeByte('"');
}

/// Escape+emit a string's *body* (no surrounding quotes) — the shared
/// inner loop of `jw.writeJsonString`, reused so qualified names build
/// one JSON string from several pieces.
fn writeJsonStringBody(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| try writeJsonStringChar(w, c);
}

fn writeJsonStringChar(w: *std.Io.Writer, c: u8) !void {
    switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    }
}

/// `{ "field": "Type", ... }` — a flat field/type map.
fn writeFieldObject(w: *std.Io.Writer, fields: []const Field) !void {
    if (fields.len == 0) {
        try w.writeAll("{}");
        return;
    }
    try w.writeAll("{ ");
    for (fields, 0..) |f, i| {
        if (i > 0) try w.writeAll(", ");
        try jw.writeJsonString(w, f.name);
        try w.writeAll(": ");
        try jw.writeJsonString(w, f.zig_type);
    }
    try w.writeAll(" }");
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

test "parseStructFile: component fields + save policy" {
    const src =
        \\pub const Bed = struct {
        \\    pub const save = @import("labelle-core").Saveable(.saveable, @This(), .{
        \\        .entity_refs = &.{"sleeper"},
        \\    });
        \\    sleeper: ?u64 = null,
        \\    x: f32 = 0,
        \\    y: f32 = 0,
        \\};
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const decls = try parseStructFile(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 1), decls.len);
    try std.testing.expectEqualStrings("Bed", decls[0].name);
    try std.testing.expectEqualStrings("saveable", decls[0].save.?);
    try std.testing.expectEqual(@as(usize, 3), decls[0].fields.len);
    try std.testing.expectEqualStrings("sleeper", decls[0].fields[0].name);
    try std.testing.expectEqualStrings("?u64", decls[0].fields[0].zig_type);
    try std.testing.expectEqualStrings("x", decls[0].fields[1].name);
    try std.testing.expectEqualStrings("f32", decls[0].fields[1].zig_type);
}

test "parseStructFile: event payload (no save policy)" {
    const src =
        \\pub const WorkerSleepStart = struct {
        \\    worker_id: u64,
        \\    bed_id: u64,
        \\};
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const decls = try parseStructFile(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 1), decls.len);
    try std.testing.expectEqualStrings("WorkerSleepStart", decls[0].name);
    try std.testing.expect(decls[0].save == null);
    try std.testing.expectEqual(@as(usize, 2), decls[0].fields.len);
    try std.testing.expectEqualStrings("worker_id", decls[0].fields[0].name);
    try std.testing.expectEqualStrings("u64", decls[0].fields[0].zig_type);
}

test "extractSavePolicy: pulls the policy enum literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = (try extractSavePolicy(arena.allocator(),
        \\pub const save = @import("labelle-core").Saveable(.transient, @This(), .{});
    )).?;
    try std.testing.expectEqualStrings("transient", p);
    try std.testing.expect((try extractSavePolicy(arena.allocator(), "pub const save = something_else;")) == null);
}

test "writeManifestJson: round-trips through std.json with index + realms" {
    const aa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(aa);
    defer arena.deinit();
    const ag = arena.allocator();

    var comp_fields: std.ArrayList(Field) = .empty;
    try comp_fields.append(ag, .{ .name = "sleeper", .zig_type = "?u64" });
    const components = [_]StructDecl{.{ .name = "Bed", .save = "saveable", .fields = comp_fields.items }};

    var ev_fields: std.ArrayList(Field) = .empty;
    try ev_fields.append(ag, .{ .name = "worker_id", .zig_type = "u64" });
    const events = [_]StructDecl{.{ .name = "WorkerSleepStart", .save = null, .fields = ev_fields.items }};

    const flow_nodes = [_]PluginFlowNode{
        .{ .module_import_path = "box2d", .module_sanitized = "box2d", .node_name = "apply_impulse", .is_script = false, .is_void = true },
        .{ .module_import_path = "box2d", .module_sanitized = "box2d", .node_name = "get_mass", .is_script = false, .is_void = false },
    };
    const plugin_events = [_]PluginEvent{
        .{ .plugin_import_name = "box2d", .plugin_sanitized = "box2d", .event_name = "collision_begin" },
    };

    const cfg = ProjectConfig{
        .name = "demo",
        .plugins = &.{.{ .name = "box2d", .version = "1.2.3" }},
    };

    var aw: std.Io.Writer.Allocating = .init(aa);
    defer aw.deinit();
    try writeManifestJson(&aw.writer, .{
        .cfg = cfg,
        .components = &components,
        .prefab_names = &.{"worker"},
        .enum_names = &.{"NeedId"},
        .hook_names = &.{},
        .game_events = &events,
        .game_scripts = &.{},
        .flow_nodes = &flow_nodes,
        .plugin_events = &plugin_events,
    });
    const out = aw.writer.buffer[0..aw.writer.end];

    var parsed = try std.json.parseFromSlice(std.json.Value, aa, out, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings(SCHEMA_VERSION, root.get("schema").?.string);

    // index
    const index = root.get("index").?.object;
    const contracts = index.get("contracts").?.object;
    try std.testing.expectEqual(@as(usize, 2), contracts.get("events").?.array.items.len); // game + plugin
    const realms_idx = index.get("realms").?.array;
    try std.testing.expectEqual(@as(usize, 2), realms_idx.items.len); // game + box2d
    const game_idx = realms_idx.items[0].object;
    try std.testing.expectEqualStrings("game", game_idx.get("name").?.string);
    try std.testing.expectEqualStrings("box2d", game_idx.get("depends_on").?.array.items[0].string);
    // exposes split by kind
    const box2d_idx = realms_idx.items[1].object;
    const exposes = box2d_idx.get("exposes").?.object;
    try std.testing.expectEqualStrings("apply_impulse", exposes.get("commands").?.array.items[0].string);
    try std.testing.expectEqualStrings("get_mass", exposes.get("queries").?.array.items[0].string);

    // detail
    const realms = root.get("realms").?.array;
    try std.testing.expectEqual(@as(usize, 2), realms.items.len);
    const game = realms.items[0].object;
    const comp0 = game.get("components").?.array.items[0].object;
    try std.testing.expectEqualStrings("Bed", comp0.get("name").?.string);
    try std.testing.expectEqualStrings("saveable", comp0.get("save").?.string);
    try std.testing.expectEqualStrings("?u64", comp0.get("fields").?.object.get("sleeper").?.string);
    const ev0 = game.get("events").?.array.items[0].object;
    try std.testing.expectEqualStrings("u64", ev0.get("payload").?.object.get("worker_id").?.string);
    try std.testing.expect(ev0.get("emitted_by").?.array.items.len == 0);
    // plugin detail
    const box2d = realms.items[1].object;
    try std.testing.expectEqualStrings("collision_begin", box2d.get("events").?.array.items[0].object.get("name").?.string);
    try std.testing.expectEqual(@as(usize, 2), box2d.get("flow_nodes").?.array.items.len);
    try std.testing.expect(box2d.get("recipes").?.array.items.len == 0);
}

test "emitManifestSidecar: writes a parseable sidecar for an empty project" {
    const aa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = config.globalIo();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", aa);
    defer aa.free(dir);

    const cfg = ProjectConfig{ .name = "tmp" };
    try emitManifestSidecar(aa, cfg, dir, dir, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{});

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

/// Find the realm object named `name` in a `[{ "name": ... }, ...]` array.
fn findRealm(arr: std.json.Array, name: []const u8) ?std.json.ObjectMap {
    for (arr.items) |item| {
        const obj = item.object;
        if (std.mem.eql(u8, obj.get("name").?.string, name)) return obj;
    }
    return null;
}

/// True when `arr` (a JSON string array) contains `needle`.
fn jsonArrayHas(arr: std.json.Array, needle: []const u8) bool {
    for (arr.items) |item| {
        if (std.mem.eql(u8, item.string, needle)) return true;
    }
    return false;
}

test "parseStructDir: name-only fallback for a missing file, helper decls excluded" {
    const aa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = config.globalIo();

    // `components/velocity.zig` declares the file-stem decl `Velocity`
    // plus a helper container that must NOT surface as its own component.
    try tmp.dir.createDirPath(io, "components");
    {
        var cdir = try tmp.dir.openDir(io, "components", .{});
        defer cdir.close(io);
        var f = try cdir.createFile(io, "velocity.zig", .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\pub const Velocity = struct {
            \\    dx: f32 = 0,
            \\    dy: f32 = 0,
            \\};
            \\pub const Helper = struct { z: u8 = 0 };
            \\
        );
    }

    const dir = try tmp.dir.realPathFileAlloc(io, ".", aa);
    defer aa.free(dir);

    var arena = std.heap.ArenaAllocator.init(aa);
    defer arena.deinit();

    // `missing` has no backing file → name-only fallback (`Missing`).
    const decls = try parseStructDir(arena.allocator(), dir, "components", &.{ "velocity", "missing" });

    // Exactly two decls: the file-stem `Velocity` and the fallback
    // `Missing` — the `Helper` container is dropped.
    try std.testing.expectEqual(@as(usize, 2), decls.len);
    try std.testing.expectEqualStrings("Velocity", decls[0].name);
    try std.testing.expectEqual(@as(usize, 2), decls[0].fields.len);
    try std.testing.expectEqualStrings("dx", decls[0].fields[0].name);
    // Name-only fallback: registry name present, empty field set.
    try std.testing.expectEqualStrings("Missing", decls[1].name);
    try std.testing.expectEqual(@as(usize, 0), decls[1].fields.len);
    try std.testing.expect(decls[1].save == null);
}

test "writeManifestJson: engine realm emitted + realm-qualified contracts + script-qualified exposes" {
    const aa = std.testing.allocator;

    // One game-script FlowNode (command) + engine & plugin events.
    const flow_nodes = [_]PluginFlowNode{
        .{ .module_import_path = "flows/hit_counter.zig", .module_sanitized = "flows_s_hit_u_counter", .node_name = "spawn", .is_script = true, .is_void = true },
        .{ .module_import_path = "box2d", .module_sanitized = "box2d", .node_name = "apply_impulse", .is_script = false, .is_void = true },
    };
    const plugin_events = [_]PluginEvent{
        .{ .plugin_import_name = "engine", .plugin_sanitized = "engine", .event_name = "tick" },
        .{ .plugin_import_name = "box2d", .plugin_sanitized = "box2d", .event_name = "collision_begin" },
    };
    const game_events = [_]StructDecl{.{ .name = "WorkerSleepStart", .save = null, .fields = &.{} }};

    const cfg = ProjectConfig{
        .name = "demo",
        .plugins = &.{.{ .name = "box2d", .version = "1.2.3" }},
    };

    var aw: std.Io.Writer.Allocating = .init(aa);
    defer aw.deinit();
    try writeManifestJson(&aw.writer, .{
        .cfg = cfg,
        .components = &.{},
        .prefab_names = &.{},
        .enum_names = &.{},
        .hook_names = &.{},
        .game_events = &game_events,
        .game_scripts = &.{},
        .flow_nodes = &flow_nodes,
        .plugin_events = &plugin_events,
    });
    const out = aw.writer.buffer[0..aw.writer.end];

    var parsed = try std.json.parseFromSlice(std.json.Value, aa, out, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    // contracts.events — realm-qualified, no bare collisions.
    const index = root.get("index").?.object;
    const contract_events = index.get("contracts").?.object.get("events").?.array;
    try std.testing.expect(jsonArrayHas(contract_events, "game.WorkerSleepStart"));
    try std.testing.expect(jsonArrayHas(contract_events, "engine.tick"));
    try std.testing.expect(jsonArrayHas(contract_events, "box2d.collision_begin"));

    // index.realms — game + engine + box2d, all reachable by name.
    const realms_idx = index.get("realms").?.array;
    try std.testing.expectEqual(@as(usize, 3), realms_idx.items.len);
    const game_idx = findRealm(realms_idx, "game").?;
    // Game exposes are script-qualified so two scripts' `spawn` stay apart.
    const game_cmds = game_idx.get("exposes").?.object.get("commands").?.array;
    try std.testing.expect(jsonArrayHas(game_cmds, "flows.hit_counter.spawn"));

    // Engine realm exists, tier "engine", owns `tick`, and carries no version.
    const engine_idx = findRealm(realms_idx, "engine").?;
    try std.testing.expectEqualStrings("engine", engine_idx.get("tier").?.string);
    try std.testing.expect(!engine_idx.contains("version"));
    try std.testing.expect(jsonArrayHas(engine_idx.get("owns").?.object.get("events").?.array, "tick"));

    // detail — engine realm present with its event list.
    const realms = root.get("realms").?.array;
    try std.testing.expectEqual(@as(usize, 3), realms.items.len);
    const engine_detail = findRealm(realms, "engine").?;
    try std.testing.expectEqualStrings("engine", engine_detail.get("tier").?.string);
    try std.testing.expectEqualStrings("tick", engine_detail.get("events").?.array.items[0].object.get("name").?.string);
}
