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
/// file by convention) into `StructDecl`s. Unreadable / unparsable files
/// degrade to an empty result for that file rather than failing the whole
/// manifest — same graceful-degradation contract `flow_catalog` follows.
fn parseStructDir(
    aa: std.mem.Allocator,
    game_dir: []const u8,
    folder: []const u8,
    names: []const []const u8,
) ![]const StructDecl {
    const io = config.globalIo();
    var list: std.ArrayList(StructDecl) = .empty;
    for (names) |name| {
        const rel = try std.fmt.allocPrint(aa, "{s}.zig", .{name});
        const path = try std.fs.path.join(aa, &.{ game_dir, folder, rel });
        const src = std.Io.Dir.cwd().readFileAlloc(io, path, aa, .limited(2 * 1024 * 1024)) catch continue;
        const decls = parseStructFile(aa, src) catch continue;
        for (decls) |d| try list.append(aa, d);
    }
    return list.toOwnedSlice(aa);
}

/// AST-walk one source buffer for top-level `pub const <Name> = struct
/// { ... }` declarations, pulling each struct's flat field list (name +
/// type source text) and — if present — its `save` policy.
fn parseStructFile(aa: std.mem.Allocator, src: []const u8) ![]const StructDecl {
    const src_z = try aa.dupeZ(u8, src);
    var ast = try std.zig.Ast.parse(aa, src_z, .zig);

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
                        save = extractSavePolicy(aa, ast.getNodeSource(m)) catch null;
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

    // realms — the realm map.
    try w.writeAll("    \"realms\": [\n");

    // Game realm first.
    try writeGameIndexRealm(w, d);
    if (d.cfg.plugins.len > 0) try w.writeAll(",");
    try w.writeAll("\n");

    for (d.cfg.plugins, 0..) |plugin, pi| {
        try writePluginIndexRealm(w, d, plugin.name, plugin.version);
        if (pi + 1 < d.cfg.plugins.len) try w.writeAll(",");
        try w.writeAll("\n");
    }

    try w.writeAll("    ]\n  }");
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

fn writePluginIndexRealm(w: *std.Io.Writer, d: ManifestData, name: []const u8, version: []const u8) !void {
    try w.writeAll("      {\n        \"name\": ");
    try jw.writeJsonString(w, name);
    try w.writeAll(",\n        \"tier\": \"plugin\",\n        \"version\": ");
    try jw.writeJsonString(w, version);
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
        try jw.writeJsonString(w, n.node_name);
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

    try writeGameRealmDetail(w, d);
    if (d.cfg.plugins.len > 0) try w.writeAll(",");
    try w.writeAll("\n");

    for (d.cfg.plugins, 0..) |plugin, pi| {
        try writePluginRealmDetail(w, d, plugin.name);
        if (pi + 1 < d.cfg.plugins.len) try w.writeAll(",");
        try w.writeAll("\n");
    }

    try w.writeAll("  ]");
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

fn writePluginRealmDetail(w: *std.Io.Writer, d: ManifestData, name: []const u8) !void {
    try w.writeAll("    {\n      \"name\": ");
    try jw.writeJsonString(w, name);
    try w.writeAll(",\n      \"tier\": \"plugin\",\n");

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

/// Every game event name plus engine/plugin event names — the shared
/// event vocabulary an agent can subscribe to across realms.
fn writeContractEvents(w: *std.Io.Writer, d: ManifestData) !void {
    try w.writeAll("[");
    var first = true;
    for (d.game_events) |e| {
        if (!first) try w.writeAll(", ");
        try jw.writeJsonString(w, e.name);
        first = false;
    }
    for (d.plugin_events) |e| {
        if (!first) try w.writeAll(", ");
        try jw.writeJsonString(w, e.event_name);
        first = false;
    }
    try w.writeAll("]");
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
