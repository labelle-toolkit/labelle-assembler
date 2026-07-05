//! Manifest JSON emission extracted from `manifest.zig`
//! (behavior-preserving split, labelle-assembler#442 follow-up).
//!
//! A pure hand-written pretty-printer over the pre-parsed manifest data
//! (`ManifestData` / `PackRealm`): the two-tier `index` + per-realm `realms`
//! shape, realm-qualified contract events, `exposes` verb surfaces, and the
//! pack `emitted_*` registry names. No filesystem access — the writer is a
//! pure function over data (the round-trip tests build the inputs as
//! literals). Re-exported (indirectly) via the `manifest.zig` barrel.

const std = @import("std");
const config = @import("../config.zig");
const script_scanner = @import("../script_scanner.zig");
const scan = @import("../codegen/scan.zig");
const plugin_manifest = @import("../plugin_manifest.zig");
const jw = @import("../flow_catalog/json_writer.zig");
const idents = @import("../codegen/idents.zig");
const parse = @import("parse.zig");

const ProjectConfig = config.ProjectConfig;
const ScriptEntry = script_scanner.ScriptScanner.ScriptEntry;
const PluginFlowNode = scan.PluginFlowNode;
const PluginEvent = scan.PluginEvent;
const Field = parse.Field;
const StructDecl = parse.StructDecl;

/// Schema version stamped into the emitted JSON so consumers can gate.
pub const SCHEMA_VERSION = "labelle.manifest/v1";

/// A fully pre-parsed pack realm — everything `writeManifestJson` needs to
/// emit a `tier:"pack"` realm without touching the filesystem, so the writer
/// stays a pure function over data (the round-trip tests build these as
/// literals). `component_stems` / `event_stems` are the raw file stems, kept
/// index-aligned with `components` / `events` (guaranteed by `parseStructDir`,
/// which emits one decl per stem in order) so the writer can derive each
/// `emitted_name` / `emitted_tag` through the same helpers codegen uses.
pub const PackRealm = struct {
    name: []const u8,
    prefix: []const u8,
    components: []const StructDecl,
    component_stems: []const []const u8,
    events: []const StructDecl,
    event_stems: []const []const u8,
    prefab_names: []const []const u8,
    hook_names: []const []const u8,
    scripts: []const ScriptEntry,
    depends_on: []const []const u8,
    exposes: ?plugin_manifest.PackExposes,
};

pub const ManifestData = struct {
    cfg: ProjectConfig,
    components: []const StructDecl,
    prefab_names: []const []const u8,
    enum_names: []const []const u8,
    hook_names: []const []const u8,
    game_events: []const StructDecl,
    game_scripts: []const ScriptEntry,
    flow_nodes: []const PluginFlowNode,
    plugin_events: []const PluginEvent,
    packs: []const PackRealm = &.{},
};

/// The sentinel game-realm name. Plugin realms use their `project.labelle`
/// name; the engine's lifecycle events / nodes group under `engine`.
const GAME_REALM = "game";
const ENGINE_REALM = "engine";

/// Hand-written pretty-printer — same rationale as the flow catalog:
/// small, stable, diffable, no schema needed to hand-read.
pub fn writeManifestJson(w: *std.Io.Writer, d: ManifestData) !void {
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
        // A declared plugin that carries a `pack.labelle` is a pack realm
        // (`tier:"pack"`, full owns + exposes); every other plugin keeps the
        // byte-identical names-only plugin entry.
        if (findPack(d, plugin.name)) |pack| {
            try writePackIndexRealm(w, pack);
        } else {
            try writeNonGameIndexRealm(w, d, plugin.name, "plugin", plugin.version);
        }
    }
    try w.writeAll("\n    ]\n  }");
}

/// The pack realm declared under `name`, or null when `name` is a plain
/// decl-module plugin. Packs are a subset of `cfg.plugins`.
fn findPack(d: ManifestData, name: []const u8) ?PackRealm {
    for (d.packs) |p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
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
        if (findPack(d, plugin.name)) |pack| {
            try writePackRealmDetail(w, pack);
        } else {
            try writeNonGameRealmDetail(w, d, plugin.name, "plugin");
        }
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
            try w.writeAll(", \"visibility\": ");
            try jw.writeJsonString(w, c.visibility orelse "pack");
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

// ── pack realms (#499) ───────────────────────────────────────────────────

/// Index entry for a pack realm — mirrors the game realm's `owns` (five
/// local-name lists) plus the pack `depends_on` + `exposes` surface.
fn writePackIndexRealm(w: *std.Io.Writer, pack: PackRealm) !void {
    try w.writeAll("      {\n        \"name\": ");
    try jw.writeJsonString(w, pack.name);
    try w.writeAll(",\n        \"tier\": \"pack\",\n        \"namespace_prefix\": ");
    try jw.writeJsonString(w, pack.prefix);
    try w.writeAll(",\n        \"owns\": {\n          \"components\": ");
    try writeStructNameArray(w, pack.components);
    try w.writeAll(",\n          \"prefabs\": ");
    try writeStringArray(w, pack.prefab_names);
    try w.writeAll(",\n          \"scripts\": ");
    try writeScriptNameArray(w, pack.scripts);
    try w.writeAll(",\n          \"events\": ");
    try writeStructNameArray(w, pack.events);
    try w.writeAll(",\n          \"hooks\": ");
    try writeStringArray(w, pack.hook_names);
    try w.writeAll("\n        },\n        \"depends_on\": ");
    try writeStringArray(w, pack.depends_on);
    try w.writeAll(",\n");
    try writePackExposes(w, pack.exposes, "        ");
    try w.writeAll(",\n        \"recipes\": []\n      }");
}

/// Per-realm detail for a pack — the SAME full shape the game root gets
/// (component field schemas + save + visibility, event payloads, prefabs,
/// hooks, scripts), plus the pack-only `namespace_prefix` / `emitted_*` /
/// `exposes` / `depends_on`.
fn writePackRealmDetail(w: *std.Io.Writer, pack: PackRealm) !void {
    try w.writeAll("    {\n      \"name\": ");
    try jw.writeJsonString(w, pack.name);
    try w.writeAll(",\n      \"tier\": \"pack\",\n      \"namespace_prefix\": ");
    try jw.writeJsonString(w, pack.prefix);
    try w.writeAll(",\n");

    // components — name + emitted registry name + save + visibility + fields.
    try w.writeAll("      \"components\": [");
    if (pack.components.len == 0) {
        try w.writeAll("],\n");
    } else {
        try w.writeAll("\n");
        for (pack.components, pack.component_stems, 0..) |c, stem, ci| {
            var pascal_buf: [128]u8 = undefined;
            try w.writeAll("        { \"name\": ");
            try jw.writeJsonString(w, c.name);
            try w.writeAll(", \"emitted_name\": ");
            try writeEmittedName(w, pack.prefix, idents.pathToPascal(stem, &pascal_buf));
            try w.writeAll(", \"save\": ");
            if (c.save) |s| try jw.writeJsonString(w, s) else try w.writeAll("null");
            try w.writeAll(", \"visibility\": ");
            try jw.writeJsonString(w, c.visibility orelse "pack");
            try w.writeAll(", \"fields\": ");
            try writeFieldObject(w, c.fields);
            try w.writeAll(" }");
            if (ci + 1 < pack.components.len) try w.writeAll(",");
            try w.writeAll("\n");
        }
        try w.writeAll("      ],\n");
    }

    // events — name + emitted registry tag + payload + (deferred) cross-refs.
    try w.writeAll("      \"events\": [");
    if (pack.events.len == 0) {
        try w.writeAll("],\n");
    } else {
        try w.writeAll("\n");
        for (pack.events, pack.event_stems, 0..) |e, stem, ei| {
            try w.writeAll("        { \"name\": ");
            try jw.writeJsonString(w, e.name);
            try w.writeAll(", \"emitted_tag\": ");
            try writeEmittedName(w, pack.prefix, idents.eventVariantName(stem));
            try w.writeAll(", \"payload\": ");
            try writeFieldObject(w, e.fields);
            try w.writeAll(", \"emitted_by\": [], \"subscribed_by\": [] }");
            if (ei + 1 < pack.events.len) try w.writeAll(",");
            try w.writeAll("\n");
        }
        try w.writeAll("      ],\n");
    }

    // prefabs — local name + emitted registration key.
    try w.writeAll("      \"prefabs\": [");
    if (pack.prefab_names.len == 0) {
        try w.writeAll("],\n");
    } else {
        try w.writeAll("\n");
        for (pack.prefab_names, 0..) |name, pi| {
            try w.writeAll("        { \"name\": ");
            try jw.writeJsonString(w, name);
            try w.writeAll(", \"emitted_name\": ");
            try writeEmittedName(w, pack.prefix, std.fs.path.basename(name));
            try w.writeAll(" }");
            if (pi + 1 < pack.prefab_names.len) try w.writeAll(",");
            try w.writeAll("\n");
        }
        try w.writeAll("      ],\n");
    }

    // hooks — local stems (registered under `<pfx>__` idents).
    try w.writeAll("      \"hooks\": ");
    try writeStringArray(w, pack.hook_names);
    try w.writeAll(",\n");

    // scripts — same shape as the game realm.
    try w.writeAll("      \"scripts\": [");
    if (pack.scripts.len == 0) {
        try w.writeAll("],\n");
    } else {
        try w.writeAll("\n");
        for (pack.scripts, 0..) |s, si| {
            try w.writeAll("        { \"name\": ");
            try jw.writeJsonString(w, s.name);
            try w.writeAll(", \"rel_path\": ");
            try jw.writeJsonString(w, s.rel_path);
            try w.writeAll(", \"order\": ");
            if (s.sort_order) |o| try w.print("{d}", .{o}) else try w.writeAll("null");
            try w.writeAll(", \"states\": ");
            try writeStringArray(w, s.states);
            try w.writeAll(" }");
            if (si + 1 < pack.scripts.len) try w.writeAll(",");
            try w.writeAll("\n");
        }
        try w.writeAll("      ],\n");
    }

    try w.writeAll("      \"depends_on\": ");
    try writeStringArray(w, pack.depends_on);
    try w.writeAll(",\n");
    try writePackExposes(w, pack.exposes, "      ");
    try w.writeAll(",\n      \"recipes\": []\n    }");
}

/// `exposes` split into `commands`/`queries` — sourced from `pack.labelle`
/// (`PackExposes`), not FlowNodes (packs ship none). `indent` is the base
/// indent of the `"exposes"` key so both the 8-space index entry and the
/// 6-space detail entry reuse one writer.
fn writePackExposes(w: *std.Io.Writer, exposes: ?plugin_manifest.PackExposes, indent: []const u8) !void {
    try w.writeAll(indent);
    try w.writeAll("\"exposes\": {\n");
    try w.writeAll(indent);
    try w.writeAll("  \"commands\": ");
    try writeStringArray(w, if (exposes) |e| e.commands else &.{});
    try w.writeAll(",\n");
    try w.writeAll(indent);
    try w.writeAll("  \"queries\": ");
    try writeStringArray(w, if (exposes) |e| e.queries else &.{});
    try w.writeAll("\n");
    try w.writeAll(indent);
    try w.writeAll("}");
}

/// Write a `"<prefix>__<local>"` JSON string — the registry-emitted form —
/// without allocating the join. `local` is the already-derived local part
/// (Pascal decl name, event variant, or prefab basename).
fn writeEmittedName(w: *std.Io.Writer, prefix: []const u8, local: []const u8) !void {
    try w.writeByte('"');
    try writeJsonStringBody(w, prefix);
    try w.writeAll("__");
    try writeJsonStringBody(w, local);
    try w.writeByte('"');
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
    // Pack events are AST-parsed (packs have no flow-catalog module entry),
    // so they're added here rather than via `plugin_events` — realm-qualified
    // by the pack name (`citizens.Hit`) like every other contract event.
    for (d.packs) |pack| {
        for (pack.events) |e| {
            if (!first) try w.writeAll(", ");
            try writeQualifiedJsonString(w, pack.name, e.name);
            first = false;
        }
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

// ─── Tests ──────────────────────────────────────────────────────────────

/// Find the realm object named `name` in a `[{ "name": ... }, ...]` array.
/// Test helper shared with the orchestrator's sidecar round-trip tests.
pub fn findRealm(arr: std.json.Array, name: []const u8) ?std.json.ObjectMap {
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

test "writeManifestJson: round-trips through std.json with index + realms" {
    const aa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(aa);
    defer arena.deinit();
    const ag = arena.allocator();

    var comp_fields: std.ArrayList(Field) = .empty;
    try comp_fields.append(ag, .{ .name = "sleeper", .zig_type = "?u64" });
    const components = [_]StructDecl{.{ .name = "Bed", .save = "saveable", .visibility = null, .fields = comp_fields.items }};

    var ev_fields: std.ArrayList(Field) = .empty;
    try ev_fields.append(ag, .{ .name = "worker_id", .zig_type = "u64" });
    const events = [_]StructDecl{.{ .name = "WorkerSleepStart", .save = null, .visibility = null, .fields = ev_fields.items }};

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
    const game_events = [_]StructDecl{.{ .name = "WorkerSleepStart", .save = null, .visibility = null, .fields = &.{} }};

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

test "writeManifestJson: pack realm — tier, emitted names, visibility, exposes, contracts" {
    const aa = std.testing.allocator;

    const worker_fields = [_]Field{.{ .name = "hunger", .zig_type = "f32" }};
    const pack_components = [_]StructDecl{.{ .name = "Worker", .save = "saveable", .visibility = "pack", .fields = &worker_fields }};
    const hit_fields = [_]Field{.{ .name = "attacker", .zig_type = "u64" }};
    const pack_events = [_]StructDecl{.{ .name = "Hit", .save = null, .visibility = null, .fields = &hit_fields }};

    const pack = PackRealm{
        .name = "citizens",
        .prefix = "citizens",
        .components = &pack_components,
        .component_stems = &.{"worker"},
        .events = &pack_events,
        .event_stems = &.{"hit"},
        .prefab_names = &.{"worker"},
        .hook_names = &.{"overlay"},
        .scripts = &.{},
        .depends_on = &.{"contracts"},
        .exposes = .{ .queries = &.{"worker_count"}, .commands = &.{"assign_home"} },
    };

    // A plain decl-module plugin alongside the pack — regression that plugin
    // realms keep their old names-only shape when packs are present.
    const flow_nodes = [_]PluginFlowNode{
        .{ .module_import_path = "box2d", .module_sanitized = "box2d", .node_name = "apply_impulse", .is_script = false, .is_void = true },
    };
    const plugin_events = [_]PluginEvent{
        .{ .plugin_import_name = "box2d", .plugin_sanitized = "box2d", .event_name = "collision_begin" },
    };

    const cfg = ProjectConfig{
        .name = "demo",
        .plugins = &.{
            .{ .name = "citizens", .version = "0.1.0" },
            .{ .name = "box2d", .version = "1.2.3" },
        },
    };

    var aw: std.Io.Writer.Allocating = .init(aa);
    defer aw.deinit();
    try writeManifestJson(&aw.writer, .{
        .cfg = cfg,
        .components = &.{},
        .prefab_names = &.{},
        .enum_names = &.{},
        .hook_names = &.{},
        .game_events = &.{},
        .game_scripts = &.{},
        .flow_nodes = &flow_nodes,
        .plugin_events = &plugin_events,
        .packs = &.{pack},
    });
    const out = aw.writer.buffer[0..aw.writer.end];

    var parsed = try std.json.parseFromSlice(std.json.Value, aa, out, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    // contracts.events — pack event realm-qualified by pack name.
    const contract_events = root.get("index").?.object.get("contracts").?.object.get("events").?.array;
    try std.testing.expect(jsonArrayHas(contract_events, "citizens.Hit"));

    // index realm: game + citizens (pack) + box2d (plugin).
    const realms_idx = root.get("index").?.object.get("realms").?.array;
    try std.testing.expectEqual(@as(usize, 3), realms_idx.items.len);
    const citizens_idx = findRealm(realms_idx, "citizens").?;
    try std.testing.expectEqualStrings("pack", citizens_idx.get("tier").?.string);
    try std.testing.expectEqualStrings("citizens", citizens_idx.get("namespace_prefix").?.string);
    try std.testing.expect(jsonArrayHas(citizens_idx.get("owns").?.object.get("components").?.array, "Worker"));
    try std.testing.expect(jsonArrayHas(citizens_idx.get("depends_on").?.array, "contracts"));
    try std.testing.expect(jsonArrayHas(citizens_idx.get("exposes").?.object.get("commands").?.array, "assign_home"));
    try std.testing.expect(jsonArrayHas(citizens_idx.get("exposes").?.object.get("queries").?.array, "worker_count"));
    // Plain plugin realm untouched.
    const box2d_idx = findRealm(realms_idx, "box2d").?;
    try std.testing.expectEqualStrings("plugin", box2d_idx.get("tier").?.string);

    // detail realm: pack carries full component/event/prefab detail.
    const realms = root.get("realms").?.array;
    const citizens = findRealm(realms, "citizens").?;
    try std.testing.expectEqualStrings("pack", citizens.get("tier").?.string);
    const comp0 = citizens.get("components").?.array.items[0].object;
    try std.testing.expectEqualStrings("Worker", comp0.get("name").?.string);
    try std.testing.expectEqualStrings("citizens__Worker", comp0.get("emitted_name").?.string);
    try std.testing.expectEqualStrings("saveable", comp0.get("save").?.string);
    try std.testing.expectEqualStrings("pack", comp0.get("visibility").?.string);
    try std.testing.expectEqualStrings("f32", comp0.get("fields").?.object.get("hunger").?.string);
    const ev0 = citizens.get("events").?.array.items[0].object;
    try std.testing.expectEqualStrings("Hit", ev0.get("name").?.string);
    try std.testing.expectEqualStrings("citizens__hit", ev0.get("emitted_tag").?.string);
    try std.testing.expectEqualStrings("u64", ev0.get("payload").?.object.get("attacker").?.string);
    const pf0 = citizens.get("prefabs").?.array.items[0].object;
    try std.testing.expectEqualStrings("worker", pf0.get("name").?.string);
    try std.testing.expectEqualStrings("citizens__worker", pf0.get("emitted_name").?.string);
    try std.testing.expect(jsonArrayHas(citizens.get("hooks").?.array, "overlay"));

    // Regression: game realm still present with its old keys; plain plugin too.
    try std.testing.expect(findRealm(realms, "game") != null);
    const box2d = findRealm(realms, "box2d").?;
    try std.testing.expectEqualStrings("plugin", box2d.get("tier").?.string);
    try std.testing.expectEqualStrings("collision_begin", box2d.get("events").?.array.items[0].object.get("name").?.string);
}
