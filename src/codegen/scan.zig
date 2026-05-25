//! Discovery + scanning helpers extracted from `main_zig.zig`
//! (labelle-assembler#183, PoC slice).
//!
//! Owns the AST-walk that turns plugin / game-script source files into the
//! `PluginEvent` / `PluginFlowNode` / `PluginPinStyle` / `PluginCoercion`
//! data the orchestrator pours into the generated `main.zig` registries.
//! These functions are deliberately pure (allocator in / allocator-owned
//! data out) so they can be moved without touching the orchestrator's
//! template-slot wiring.
//!
//! ⚠️  Bit-identical contract: every string this module writes (the
//! sanitized plugin idents, the path-derived idents) feeds directly into
//! `main.zig` source. A typo here drifts the generated source for every
//! downstream backend. The orchestrator's tests already cover the
//! emission shape end-to-end; the helpers here also carry the
//! `pathToIdent` tests that were already in `main_zig.zig`.

const std = @import("std");
const config = @import("../config.zig");
const cache = @import("../cache.zig");
const script_scanner = @import("../script_scanner.zig");

const ProjectConfig = config.ProjectConfig;
const ScriptEntry = script_scanner.ScriptScanner.ScriptEntry;

/// A single discovered `pub const <event_name> = struct {...}` declaration
/// inside a plugin's `pub const Events = struct { ... }`. Owned by
/// `PluginEvents.deinit` — both strings are heap-allocated dupes so the
/// caller need not keep the plugin's source buffer alive.
pub const PluginEvent = struct {
    /// Plugin name as it appears in `project.labelle` (e.g. `box2d`,
    /// `labelle-physics`). Used for the `@import("<name>")` reference
    /// emitted into the union variant type.
    plugin_import_name: []const u8,
    /// Sanitized identifier form of `plugin_import_name` (e.g.
    /// `labelle-physics` → `labelle_physics`). Used as the prefix in
    /// the qualified variant tag.
    plugin_sanitized: []const u8,
    /// Bare event identifier (e.g. `collision_begin`).
    event_name: []const u8,
};

/// Collection of `PluginEvent`s with an allocator-aware `deinit`. The
/// list itself and every string inside it live in the same allocator.
pub const PluginEvents = struct {
    entries: []PluginEvent,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PluginEvents) void {
        for (self.entries) |e| {
            self.allocator.free(e.plugin_import_name);
            self.allocator.free(e.plugin_sanitized);
            self.allocator.free(e.event_name);
        }
        self.allocator.free(self.entries);
        self.entries = &.{};
    }
};

/// Walk each plugin's source tree and collect every `pub const <name> = struct`
/// declaration sitting inside the plugin's top-level `pub const Events = struct`.
/// Mirrors the on-disk convention RFC-PLUGIN-EVENTS phase 1 codified, but at
/// assembler time so the emitted `PluginEvents` union can be a written-out
/// `union(enum) { … }` literal — `@Union(.auto, …)` with zero fields produces
/// an uninstantiable type (rejected by `std.ArrayList`'s `@memset(undefined)`
/// in 0.16), which is the root cause of the plugin-controllers CI failure.
///
/// Plugins without `src/root.zig` or without a `Events` decl contribute zero
/// entries — that's the back-compat path every existing plugin (labelle-fsm,
/// labelle-pathfinding, the plugin-controllers demo plugin) takes.
pub fn discoverPluginEvents(
    allocator: std.mem.Allocator,
    cfg: ProjectConfig,
    project_dir: []const u8,
) !PluginEvents {
    var entries: std.ArrayList(PluginEvent) = .empty;
    errdefer {
        for (entries.items) |e| {
            allocator.free(e.plugin_import_name);
            allocator.free(e.plugin_sanitized);
            allocator.free(e.event_name);
        }
        entries.deinit(allocator);
    }

    // ── Engine pass (labelle-engine#578) ─────────────────────────────
    //
    // The engine is a peer dependency, not a plugin, so it doesn't
    // appear in `cfg.plugins` — but it does declare a `pub const
    // Events` block (`labelle-engine/src/root.zig`) that flows want to
    // listen to under the `engine.<event>` dotted form. Walk the
    // engine's `src/root.zig` here so the same `Events` discovery
    // pipeline that handles plugins folds in `engine__game_init` /
    // `engine__tick` / etc. without a separate code path.
    //
    // The "name" stored on each discovered `PluginEvent` is the
    // literal string `engine` — this matches the on-disk JSONC dot
    // form (`engine.tick`) and the qualified tag the engine's
    // `emitEngineEvent` helper passes to `@unionInit(GameEvents,
    // "engine__<event>", ...)`. The actual Zig module name is
    // `labelle-engine` (not `engine`) — `writePluginEventsBlock`
    // special-cases the `engine` prefix when emitting the `@import`
    // target.
    blk_engine: {
        const engine_dir = cache.resolveFrameworkPackage(
            allocator,
            "engine",
            cfg.engine_version,
            project_dir,
        ) catch break :blk_engine;
        defer allocator.free(engine_dir);
        try discoverEventsFromRoot(allocator, &entries, engine_dir, "engine");
    }

    // ── Plugin pass ─────────────────────────────────────────────────
    for (cfg.plugins) |plugin| {
        const plugin_dir = cache.resolvePlugin(allocator, plugin, project_dir) catch continue;
        defer allocator.free(plugin_dir);
        try discoverEventsFromRoot(allocator, &entries, plugin_dir, plugin.name);
    }

    return .{
        .entries = try entries.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Helper: load `<module_dir>/src/root.zig`, AST-walk it for a top-
/// level `pub const Events = struct { ... }` declaration, and append
/// every `pub const <event_name> = struct {...}` child as a
/// `PluginEvent` keyed by `module_name`. Used by both the engine pass
/// and the plugin loop in `discoverPluginEvents`.
///
/// Missing `src/root.zig` (or unreadable source / parse failure) is
/// silently tolerated — the same back-compat path every existing
/// plugin without an `Events` decl already takes.
fn discoverEventsFromRoot(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(PluginEvent),
    module_dir: []const u8,
    module_name: []const u8,
) !void {
    const root_path = try std.fs.path.join(allocator, &.{ module_dir, "src", "root.zig" });
    defer allocator.free(root_path);

    const io = config.globalIo();
    const src = std.Io.Dir.cwd().readFileAlloc(io, root_path, allocator, .limited(8 * 1024 * 1024)) catch return;
    defer allocator.free(src);

    const src_z = try allocator.dupeZ(u8, src);
    defer allocator.free(src_z);

    var ast = try std.zig.Ast.parse(allocator, src_z, .zig);
    defer ast.deinit(allocator);

    var name_buf: [128]u8 = undefined;
    const sanitized = sanitizePluginIdent(module_name, &name_buf);

    const root_decls = ast.rootDecls();
    for (root_decls) |decl_idx| {
        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const vd = ast.fullVarDecl(decl_idx) orelse continue;
        // Only `pub const Events = …` qualifies — non-pub or
        // non-`Events` declarations are skipped silently so
        // a module can have its own internal `const Events` helper
        // without leaking into the union.
        if (vd.visib_token == null) continue;
        const name_tok = vd.ast.mut_token + 1;
        const decl_name = ast.tokenSlice(name_tok);
        if (!std.mem.eql(u8, decl_name, "Events")) continue;

        const init_node = vd.ast.init_node.unwrap() orelse continue;
        const container = ast.fullContainerDecl(&buf, init_node) orelse continue;

        for (container.ast.members) |m| {
            const member_vd = ast.fullVarDecl(m) orelse continue;
            if (member_vd.visib_token == null) continue;
            // Skip non-type members — `pub const FOO = 42;` inside
            // `Events` is unusual but not a syntax error, and we
            // only care about struct/union type aliases.
            const event_init = member_vd.ast.init_node.unwrap() orelse continue;
            if (ast.fullContainerDecl(&buf, event_init) == null) continue;

            const event_name_tok = member_vd.ast.mut_token + 1;
            const event_name = ast.tokenSlice(event_name_tok);

            try entries.append(allocator, .{
                .plugin_import_name = try allocator.dupe(u8, module_name),
                .plugin_sanitized = try allocator.dupe(u8, sanitized),
                .event_name = try allocator.dupe(u8, event_name),
            });
        }
    }
}

// ── RFC-FLOW-VOCABULARY phase 2 — FlowNodes + PinStyles discovery ──────
//
// Walk each plugin's `src/root.zig` and each game-script `.zig` file for
// `pub const FlowNodes` and `pub const PinStyles` declarations. The
// convention parallels `Events` / `Components` / `Systems`:
//
//   pub const FlowNodes = struct {
//       pub const apply_impulse = labelle.FlowNode(.{ .impl = applyImpulseImpl });
//       pub const get_velocity  = labelle.FlowNode(.{ .impl = getVelocityImpl });
//   };
//
//   pub const PinStyles = struct {
//       pub const BodyId = labelle.PinStyle{ .label = "Body", .color = ... };
//   };
//
// Per RFC §5, any module under the project tree (plugins OR game
// scripts) that exports `FlowNodes` is a palette source. The
// emitted `PluginFlowNodes` registry the editor and flow-codegen
// (phase 3 `CustomNode` lowering) consume is keyed by a
// plugin-qualified identifier (`<module>__<name>`), same convention
// as `PluginEvents`, so a flow's on-disk dotted name
// (`box2d.apply_impulse`) maps to a Zig identifier
// (`box2d__apply_impulse`).
//
// Phase 5 (parallel ticket) adds the actual `FlowNodes` declarations
// to labelle-box2d; this discovery is the first real consumer.

/// One discovered `pub const <name> = labelle.FlowNode(...)` decl
/// inside a `pub const FlowNodes = struct { ... }` block. Both the
/// import path and the module-qualified identifier are kept so the
/// emitter can write the registry entry verbatim without re-deriving
/// either at codegen time.
pub const PluginFlowNode = struct {
    /// Identifier used by Zig's `@import(...)` for the source
    /// module. For plugins, this is the project.labelle `.name` (the
    /// same string `@import` resolves against in the generated
    /// main.zig). For game-script modules, this is the relative path
    /// under `scripts/` (e.g. `hits.zig` or `flows/hit_counter.zig`),
    /// emitted as `@import("scripts/<rel_path>")` to match how
    /// `all_scripts_block` already references game scripts.
    module_import_path: []const u8,
    /// Sanitized identifier form of the source module. For plugins
    /// this is the same `sanitizePluginIdent` output as
    /// `PluginEvent.plugin_sanitized` (e.g. `labelle-box2d` →
    /// `labelle_box2d`). For game-script modules this is
    /// `pathToIdent` of the rel_path (escaped per the standard
    /// path→ident mapping so `flows/hit_counter.zig` becomes
    /// `flows_s_hit_u_counter`). Used as the prefix in the qualified
    /// registry decl name `<module_sanitized>__<node_name>`.
    module_sanitized: []const u8,
    /// Bare node identifier as declared inside `FlowNodes` (e.g.
    /// `apply_impulse`).
    node_name: []const u8,
    /// `true` when the source is a game-script module; `false` for
    /// plugin modules. Drives which `@import` form the emitter
    /// writes — plugins resolve as `@import("<name>")`, scripts as
    /// `@import("scripts/<rel_path>")`.
    is_script: bool,
    /// Fully-qualified Zig type name the node constructs, captured
    /// from a `.constructs = "..."` field in the source `FlowNode`
    /// factory call, or `null` when the source omits it
    /// (RFC-FLOW-VOCABULARY §1, open question O5). The string is
    /// extracted textually from the init expression — the AST scan
    /// doesn't evaluate the factory call, so the source must spell
    /// the value as a literal `"..."` string. Threaded through to
    /// the editor (phase 4) so the palette can suggest constructor
    /// nodes for struct-typed `SetVariable` targets.
    constructs: ?[]const u8 = null,
};

/// One discovered `pub const <TypeName> = labelle.PinStyle{ ... }`
/// decl inside a `pub const PinStyles = struct { ... }` block. The
/// editor merges these on top of `default_pin_styles`; per RFC §1,
/// later declarations win for duplicate type keys, so the assembler
/// dedups by `type_name` (last-write-wins) before emitting.
pub const PluginPinStyle = struct {
    /// Same shape as `PluginFlowNode.module_import_path`.
    module_import_path: []const u8,
    /// Same shape as `PluginFlowNode.module_sanitized`.
    module_sanitized: []const u8,
    /// Zig type name (e.g. `BodyId`). The emitted registry uses this
    /// verbatim as the decl name — duplicates across modules collapse
    /// to last-write-wins.
    type_name: []const u8,
    /// Same meaning as `PluginFlowNode.is_script`.
    is_script: bool,
};

/// One discovered `pub const <name> = labelle.flow.Coercion(...)` decl
/// inside a `pub const Coercions = struct { ... }` block
/// (RFC-FLOW-VOCABULARY §2 / O4). Same ownership pattern as
/// `PluginFlowNode` / `PluginPinStyle` — every string is a
/// heap-allocated dupe owned by the enclosing `PluginFlowDecls`.
///
/// The qualified emitted decl name is `<module_sanitized>__<name>`
/// matching the FlowNodes / Events convention.
pub const PluginCoercion = struct {
    /// Same shape as `PluginFlowNode.module_import_path`.
    module_import_path: []const u8,
    /// Same shape as `PluginFlowNode.module_sanitized`. Used as the
    /// `<module>__<name>` prefix on the emitted registry decl.
    module_sanitized: []const u8,
    /// Bare coercion identifier as declared inside `Coercions` (e.g.
    /// `body_to_entity`).
    name: []const u8,
    /// Same meaning as `PluginFlowNode.is_script`.
    is_script: bool,
};

/// Collection of discovered FlowNodes + PinStyles + Coercions with an
/// allocator-aware `deinit`. Same ownership story as `PluginEvents`
/// — every string field on every entry is a heap-allocated dupe so
/// callers need not keep source buffers alive.
pub const PluginFlowDecls = struct {
    flow_nodes: []PluginFlowNode,
    pin_styles: []PluginPinStyle,
    /// RFC-FLOW-VOCABULARY §2 / O4 — plugin-declared coercions. Empty
    /// when no module declares a `pub const Coercions` block; the
    /// emitter still writes an empty `PluginCoercions = struct {}`
    /// shell so downstream reflection (flow-codegen edge wrap) is
    /// uniform.
    coercions: []PluginCoercion,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PluginFlowDecls) void {
        for (self.flow_nodes) |fn_| {
            self.allocator.free(fn_.module_import_path);
            self.allocator.free(fn_.module_sanitized);
            self.allocator.free(fn_.node_name);
            if (fn_.constructs) |c| self.allocator.free(c);
        }
        self.allocator.free(self.flow_nodes);
        self.flow_nodes = &.{};
        for (self.pin_styles) |ps| {
            self.allocator.free(ps.module_import_path);
            self.allocator.free(ps.module_sanitized);
            self.allocator.free(ps.type_name);
        }
        self.allocator.free(self.pin_styles);
        self.pin_styles = &.{};
        for (self.coercions) |co| {
            self.allocator.free(co.module_import_path);
            self.allocator.free(co.module_sanitized);
            self.allocator.free(co.name);
        }
        self.allocator.free(self.coercions);
        self.coercions = &.{};
    }
};

/// Extract the literal string value of a `.constructs = "..."` field
/// from the source text of a `FlowNode(.{...})` factory call
/// (RFC-FLOW-VOCABULARY §1 / O5). Returns an allocator-owned dupe of
/// the unescaped value, or `null` when the field is absent / not a
/// plain string literal.
///
/// Scan strategy is deliberately tolerant: walks the source byte by
/// byte while tracking whether we're inside a string or comment, so a
/// `.constructs` keyword appearing inside another string (e.g. as part
/// of `.docs`) doesn't trigger a false match. Stops at the first
/// match — multiple `.constructs` fields aren't valid Zig anyway, so
/// "last wins" never comes into play. A truly malformed factory call
/// surfaces as a Zig compile error at the consumer site, not here.
fn extractConstructsString(allocator: std.mem.Allocator, src: []const u8) ?[]u8 {
    const needle = ".constructs";
    var i: usize = 0;
    while (i + needle.len <= src.len) : (i += 1) {
        const c = src[i];
        // Skip over Zig string literals so a `.docs = ".constructs = ..."`
        // doesn't false-match. The scanner only handles the `"..."`
        // form (no `\\` multiline strings) — the factory's typical
        // usage stays well within that subset.
        if (c == '"') {
            i += 1;
            while (i < src.len) : (i += 1) {
                if (src[i] == '\\' and i + 1 < src.len) {
                    i += 1; // skip escaped char
                    continue;
                }
                if (src[i] == '"') break;
            }
            continue;
        }
        // Skip line comments.
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            while (i < src.len and src[i] != '\n') : (i += 1) {}
            continue;
        }
        if (!std.mem.startsWith(u8, src[i..], needle)) continue;
        // Verify the byte before isn't an identifier char — otherwise
        // we'd match `.subconstructs` or `.foo_constructs`.
        if (i > 0) {
            const prev = src[i - 1];
            if ((prev >= 'a' and prev <= 'z') or (prev >= 'A' and prev <= 'Z') or
                (prev >= '0' and prev <= '9') or prev == '_')
            {
                continue;
            }
        }
        // Verify the byte after the keyword isn't an identifier char
        // either (so `.constructs_x` is rejected).
        const after_kw = i + needle.len;
        if (after_kw < src.len) {
            const next = src[after_kw];
            if ((next >= 'a' and next <= 'z') or (next >= 'A' and next <= 'Z') or
                (next >= '0' and next <= '9') or next == '_')
            {
                continue;
            }
        }
        // Skip whitespace and the `=`, expect a `"..."` literal.
        var j = after_kw;
        while (j < src.len and (src[j] == ' ' or src[j] == '\t' or src[j] == '\n' or src[j] == '\r')) : (j += 1) {}
        if (j >= src.len or src[j] != '=') return null;
        j += 1;
        while (j < src.len and (src[j] == ' ' or src[j] == '\t' or src[j] == '\n' or src[j] == '\r')) : (j += 1) {}
        if (j >= src.len or src[j] != '"') return null;
        const start = j + 1;
        var k = start;
        while (k < src.len) : (k += 1) {
            if (src[k] == '\\' and k + 1 < src.len) {
                k += 1;
                continue;
            }
            if (src[k] == '"') break;
        }
        if (k >= src.len) return null;
        return allocator.dupe(u8, src[start..k]) catch null;
    }
    return null;
}

/// Walk one `.zig` source buffer for `pub const FlowNodes`,
/// `pub const PinStyles`, and `pub const Coercions` decls, appending
/// each discovered nested member to the corresponding output list.
/// The three outputs share the same `module_import_path` /
/// `module_sanitized` / `is_script` values (passed in by the caller),
/// so the per-module identification is decided once at the call site
/// rather than re-derived per entry.
///
/// Buffer is the file contents; the caller owns it. The parsed AST
/// is local to this function; only `allocator.dupe`d strings outlive
/// the call.
fn scanFlowDeclsInSource(
    allocator: std.mem.Allocator,
    src: []const u8,
    module_import_path: []const u8,
    module_sanitized: []const u8,
    is_script: bool,
    flow_nodes_out: *std.ArrayList(PluginFlowNode),
    pin_styles_out: *std.ArrayList(PluginPinStyle),
    coercions_out: *std.ArrayList(PluginCoercion),
) !void {
    const src_z = try allocator.dupeZ(u8, src);
    defer allocator.free(src_z);

    var ast = try std.zig.Ast.parse(allocator, src_z, .zig);
    defer ast.deinit(allocator);

    const root_decls = ast.rootDecls();
    for (root_decls) |decl_idx| {
        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const vd = ast.fullVarDecl(decl_idx) orelse continue;
        // Non-pub helpers (e.g. an internal `const FlowNodes` used by
        // the module itself) are skipped silently — same precedent
        // `discoverPluginEvents` follows.
        if (vd.visib_token == null) continue;
        const name_tok = vd.ast.mut_token + 1;
        const decl_name = ast.tokenSlice(name_tok);

        const is_flow_nodes = std.mem.eql(u8, decl_name, "FlowNodes");
        const is_pin_styles = std.mem.eql(u8, decl_name, "PinStyles");
        const is_coercions = std.mem.eql(u8, decl_name, "Coercions");
        if (!is_flow_nodes and !is_pin_styles and !is_coercions) continue;

        const init_node = vd.ast.init_node.unwrap() orelse continue;
        const container = ast.fullContainerDecl(&buf, init_node) orelse continue;

        for (container.ast.members) |m| {
            const member_vd = ast.fullVarDecl(m) orelse continue;
            if (member_vd.visib_token == null) continue;
            // Skip non-value members defensively. The init token for a
            // `pub const apply_impulse = labelle.FlowNode(.{...})` is
            // always present; a `pub const X: T = …` (typed) decl also
            // exposes init_node. The `unwrap()` filter just ensures we
            // never trip on a malformed entry.
            const member_init = member_vd.ast.init_node.unwrap() orelse continue;

            const member_name_tok = member_vd.ast.mut_token + 1;
            const member_name = ast.tokenSlice(member_name_tok);

            if (is_flow_nodes) {
                // RFC-FLOW-VOCABULARY §1 / O5 — capture an optional
                // `.constructs = "..."` field from the factory call's
                // source text. The scanner doesn't evaluate the
                // expression (would require a full compile), so it
                // extracts the literal string verbatim. A non-string
                // `.constructs` (e.g. a comptime expression) is
                // silently ignored — that's a forward-compatible
                // refinement, not a contract worth enforcing here.
                const init_src = ast.getNodeSource(member_init);
                const constructs_value = extractConstructsString(allocator, init_src);
                try flow_nodes_out.append(allocator, .{
                    .module_import_path = try allocator.dupe(u8, module_import_path),
                    .module_sanitized = try allocator.dupe(u8, module_sanitized),
                    .node_name = try allocator.dupe(u8, member_name),
                    .is_script = is_script,
                    .constructs = constructs_value,
                });
            } else if (is_pin_styles) {
                try pin_styles_out.append(allocator, .{
                    .module_import_path = try allocator.dupe(u8, module_import_path),
                    .module_sanitized = try allocator.dupe(u8, module_sanitized),
                    .type_name = try allocator.dupe(u8, member_name),
                    .is_script = is_script,
                });
            } else {
                // Coercions block (RFC-FLOW-VOCABULARY §2 / O4).
                // Same shape as FlowNodes — each member is a
                // `labelle.flow.Coercion(.{ .impl = ... })` factory
                // call; the assembler doesn't need to peer inside the
                // call because the From/To types are resolved at
                // comptime in the emitted alias and surfaced via
                // reflection (`PluginCoercions.<qualified>.From` etc.).
                // The flow_catalog sidecar (parallel walk in
                // `flow_catalog.zig`) extracts the textual types for
                // the editor's wire-fit check.
                try coercions_out.append(allocator, .{
                    .module_import_path = try allocator.dupe(u8, module_import_path),
                    .module_sanitized = try allocator.dupe(u8, module_sanitized),
                    .name = try allocator.dupe(u8, member_name),
                    .is_script = is_script,
                });
            }
        }
    }
}

/// Discover `pub const FlowNodes` and `pub const PinStyles` decls
/// across both plugin modules and game-script modules.
///
/// **Plugins** are walked via `<plugin>/src/root.zig` (same convention
/// as `discoverPluginEvents`). Plugins without a `FlowNodes` or
/// `PinStyles` decl contribute zero entries — the back-compat path
/// every existing plugin takes today.
///
/// **Game scripts** are walked from `scripts_root`. Each
/// `ScriptEntry` whose `plugin_name == null` (i.e. game-owned, not a
/// plugin-shipped script) is parsed from
/// `<scripts_root>/<entry.rel_path>`. Per RFC §5, any module in the
/// project tree that exports `FlowNodes` is a palette source — the
/// canonical example is `bouncing-ball/scripts/hits.zig`.
///
/// Plugin-shipped scripts (those with `entry.plugin_name != null`,
/// which live under `<scripts_root>/.plugin_<name>/...`) are skipped
/// here: their containing plugin already gets walked at its
/// `src/root.zig` root decl level. Re-walking them as game scripts
/// would double-count entries and break the qualified-name
/// convention.
///
/// Missing source files / parse errors on individual modules are
/// skipped silently rather than failing the whole `generate` —
/// matches the `discoverPluginEvents` tolerance for plugins without
/// a `src/root.zig`. A genuinely broken script will surface its
/// error later when the generated `main.zig` tries to compile it.
pub fn discoverPluginFlowDecls(
    allocator: std.mem.Allocator,
    cfg: ProjectConfig,
    project_dir: []const u8,
    scripts_root: []const u8,
    script_entries: []const ScriptEntry,
) !PluginFlowDecls {
    var flow_nodes: std.ArrayList(PluginFlowNode) = .empty;
    errdefer {
        for (flow_nodes.items) |e| {
            allocator.free(e.module_import_path);
            allocator.free(e.module_sanitized);
            allocator.free(e.node_name);
            if (e.constructs) |c| allocator.free(c);
        }
        flow_nodes.deinit(allocator);
    }
    var pin_styles: std.ArrayList(PluginPinStyle) = .empty;
    errdefer {
        for (pin_styles.items) |e| {
            allocator.free(e.module_import_path);
            allocator.free(e.module_sanitized);
            allocator.free(e.type_name);
        }
        pin_styles.deinit(allocator);
    }
    var coercions: std.ArrayList(PluginCoercion) = .empty;
    errdefer {
        for (coercions.items) |e| {
            allocator.free(e.module_import_path);
            allocator.free(e.module_sanitized);
            allocator.free(e.name);
        }
        coercions.deinit(allocator);
    }

    // ── Plugin pass ─────────────────────────────────────────────
    for (cfg.plugins) |plugin| {
        const plugin_dir = cache.resolvePlugin(allocator, plugin, project_dir) catch continue;
        defer allocator.free(plugin_dir);

        const root_path = try std.fs.path.join(allocator, &.{ plugin_dir, "src", "root.zig" });
        defer allocator.free(root_path);

        const io = config.globalIo();
        const src = std.Io.Dir.cwd().readFileAlloc(io, root_path, allocator, .limited(8 * 1024 * 1024)) catch continue;
        defer allocator.free(src);

        var name_buf: [128]u8 = undefined;
        const sanitized = sanitizePluginIdent(plugin.name, &name_buf);

        scanFlowDeclsInSource(
            allocator,
            src,
            plugin.name,
            sanitized,
            false, // is_script
            &flow_nodes,
            &pin_styles,
            &coercions,
        ) catch continue; // tolerate per-plugin parse failures
    }

    // ── Game-script pass (RFC §5) ───────────────────────────────
    // Only walks game-owned entries — plugin-shipped scripts are
    // already covered by their plugin's root.zig pass above. See
    // the function's doc-comment for the rationale.
    var ident_buf: [256]u8 = undefined;
    for (script_entries) |entry| {
        if (entry.plugin_name != null) continue;

        const script_path = try std.fs.path.join(allocator, &.{ scripts_root, entry.rel_path });
        defer allocator.free(script_path);

        const io = config.globalIo();
        const src = std.Io.Dir.cwd().readFileAlloc(io, script_path, allocator, .limited(8 * 1024 * 1024)) catch continue;
        defer allocator.free(src);

        const sanitized = pathToIdent(entry.rel_path, &ident_buf);

        scanFlowDeclsInSource(
            allocator,
            src,
            entry.rel_path,
            sanitized,
            true, // is_script
            &flow_nodes,
            &pin_styles,
            &coercions,
        ) catch continue;
    }

    return .{
        .flow_nodes = try flow_nodes.toOwnedSlice(allocator),
        .pin_styles = try pin_styles.toOwnedSlice(allocator),
        .coercions = try coercions.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Deduplicate `PluginPinStyle` entries by `type_name`, keeping the
/// last occurrence (RFC §1: "later declarations win for any
/// duplicate type key"). Allocates a new slice owned by the caller;
/// strings inside are still borrowed from the input entries' lifetime
/// (the caller's `PluginFlowDecls`). Iteration over the input is
/// reverse: the first time we see a type name, we keep it (which
/// corresponds to the last-write in the input order); a second sight
/// is dropped.
///
/// Quadratic over the entry count — fine for the small registry
/// sizes (≤ a few dozen per typical project); a HashMap would be
/// overkill and would force a string allocation for every key.
pub fn dedupePinStyles(
    allocator: std.mem.Allocator,
    pin_styles: []const PluginPinStyle,
) ![]PluginPinStyle {
    var kept: std.ArrayList(PluginPinStyle) = .empty;
    errdefer kept.deinit(allocator);
    // Walk in reverse so the first time we see a name corresponds to
    // the last declaration in input order; later passes that already
    // recorded the name skip the entry.
    var i: usize = pin_styles.len;
    while (i > 0) {
        i -= 1;
        const ps = pin_styles[i];
        var already = false;
        for (kept.items) |k| {
            if (std.mem.eql(u8, k.type_name, ps.type_name)) {
                already = true;
                break;
            }
        }
        if (!already) try kept.append(allocator, ps);
    }
    // Reverse `kept` to restore source order (filtered).
    const out = try kept.toOwnedSlice(allocator);
    std.mem.reverse(PluginPinStyle, out);
    return out;
}

/// Sanitize a plugin name (e.g. `labelle-box2d`) into a Zig identifier
/// fragment safe for embedding in a union variant tag. Non-identifier
/// bytes (`-`, `.`, `/`, …) collapse to `_`. The output is written
/// into the caller's buffer and returned as a sub-slice. The mapping
/// is collapsing rather than escaping, so two plugin names that
/// sanitize to the same identifier (e.g. `foo-bar` and `foo_bar`)
/// would collide — but the resulting duplicate variant name is
/// rejected by `MergeHookPayloads`' duplicate-field check at
/// comptime, surfacing the conflict immediately rather than silently.
pub fn sanitizePluginIdent(name: []const u8, buf: *[128]u8) []const u8 {
    var i: usize = 0;
    // A leading digit is invalid in a Zig identifier — prefix `_`.
    if (name.len > 0 and std.ascii.isDigit(name[0])) {
        buf[i] = '_';
        i += 1;
    }
    for (name) |c| {
        if (i >= buf.len) break;
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '_' => buf[i] = c,
            else => buf[i] = '_',
        }
        i += 1;
    }
    return buf[0..i];
}

/// Convert a path-style name to a valid Zig identifier: "enemies/goblin" -> "enemies_s_goblin".
/// Strips the `.zig` extension first, then escapes every character that is not
/// a valid identifier character into a distinct `_<tag>_` sequence.
///
/// The mapping is **injective**: distinct input paths always produce distinct
/// identifiers. Naively replacing `/`, `+`, and `.` all with `_` would collapse
/// e.g. `enemy/patrol` and `enemy_patrol` (or `a/b/c` and `a/b_c`) onto the same
/// identifier, emitting duplicate `pub const` lines in the generated `main.zig`.
/// To stay injective we must also escape literal `_` in the input — otherwise a
/// path containing `_` could alias an escaped separator.
///
/// Escape table (each maps to a sequence Zig accepts in an identifier):
///   `_` (literal) -> `_u_`   (`u`nderscore)
///   `/`           -> `_s_`   (`s`lash)
///   `.`           -> `_d_`   (`d`ot)
///   `+`           -> `_p_`   (`p`lus)
/// Any other non-`[A-Za-z0-9]` byte -> `_x<2-hex>_`.
///
/// Because every `_` in the output is the start of one of these escapes, no two
/// distinct inputs can decode to the same identifier. The `.` escape covers
/// plugin-shipped scripts that land under `.plugin_<name>/…`, whose leading dot
/// would otherwise produce an identifier that Zig rejects.
pub fn pathToIdent(name: []const u8, buf: *[256]u8) []const u8 {
    // Strip .zig extension
    const end = if (std.mem.endsWith(u8, name, ".zig")) name.len - 4 else name.len;
    var i: usize = 0;
    const append = struct {
        fn f(b: *[256]u8, idx: *usize, bytes: []const u8) void {
            if (idx.* + bytes.len > b.len) {
                std.debug.print("labelle: path too long for identifier (max {d} chars): too many escaped chars\n", .{b.len});
                @panic("path exceeds identifier buffer size");
            }
            @memcpy(b[idx.*..][0..bytes.len], bytes);
            idx.* += bytes.len;
        }
    }.f;
    // A leading digit makes the result invalid as a Zig identifier
    // (`pub const 2x2_tile = ...` won't compile). Prefix a `_`. It
    // can't alias an escape sequence — every escape is `_` followed
    // by a letter (`u`/`s`/`d`/`p`/`x`), never a digit — so the
    // mapping stays injective.
    if (end > 0 and name[0] >= '0' and name[0] <= '9') append(buf, &i, "_");
    for (name[0..end]) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9' => append(buf, &i, &.{c}),
            '_' => append(buf, &i, "_u_"),
            '/' => append(buf, &i, "_s_"),
            '.' => append(buf, &i, "_d_"),
            '+' => append(buf, &i, "_p_"),
            else => {
                const hex = "0123456789abcdef";
                append(buf, &i, &.{ '_', 'x', hex[c >> 4], hex[c & 0x0f], '_' });
            },
        }
    }
    return buf[0..i];
}

// ── Tests (moved verbatim from main_zig.zig) ─────────────────────────

test "pathToIdent: plain name is unchanged" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("health", pathToIdent("health", &buf));
}

test "pathToIdent: strips the .zig extension" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("patrol", pathToIdent("patrol.zig", &buf));
}

test "pathToIdent: distinct separators do not collide (issue #172)" {
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    // The classic collision: a slash-separated path vs the same text with a
    // literal underscore. Pre-fix both became `enemy_patrol`.
    const slash = pathToIdent("enemy/patrol", &a);
    const under = pathToIdent("enemy_patrol", &b);
    try std.testing.expect(!std.mem.eql(u8, slash, under));
    try std.testing.expectEqualStrings("enemy_s_patrol", slash);
    try std.testing.expectEqualStrings("enemy_u_patrol", under);
}

test "pathToIdent: nested path vs underscore variant do not collide" {
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    // `a/b/c` vs `a/b_c` — pre-fix both became `a_b_c`.
    try std.testing.expect(!std.mem.eql(
        u8,
        pathToIdent("a/b/c", &a),
        pathToIdent("a/b_c", &b),
    ));
}

test "pathToIdent: dot and plus map to distinct escapes" {
    var d: [256]u8 = undefined;
    var p: [256]u8 = undefined;
    var s: [256]u8 = undefined;
    try std.testing.expectEqualStrings("a_d_b", pathToIdent("a.b", &d));
    try std.testing.expectEqualStrings("a_p_b", pathToIdent("a+b", &p));
    try std.testing.expectEqualStrings("a_s_b", pathToIdent("a/b", &s));
    // ...and none of them collide with each other.
    try std.testing.expect(!std.mem.eql(u8, pathToIdent("a.b", &d), pathToIdent("a+b", &p)));
}

test "pathToIdent: a leading digit is prefixed to stay a valid identifier" {
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    // `2x2_tile` would otherwise emit `2x2_u_tile`, which Zig rejects
    // as an identifier. The `_` prefix keeps it valid.
    try std.testing.expectEqualStrings("_2x2_u_tile", pathToIdent("2x2_tile", &a));
    // The prefix must not collapse two distinct digit-leading paths.
    try std.testing.expect(!std.mem.eql(
        u8,
        pathToIdent("0a", &a),
        pathToIdent("1a", &b),
    ));
}

test "pathToIdent: every distinct path yields a distinct identifier" {
    const cases = [_][]const u8{
        "enemy/patrol",
        "enemy_patrol",
        "enemy.patrol",
        "enemy+patrol",
        "a/b/c",
        "a/b_c",
        "a_b/c",
        "a/b.c",
        ".plugin_core/script",
        "plugin_core/script",
    };
    var bufs: [cases.len][256]u8 = undefined;
    var idents: [cases.len][]const u8 = undefined;
    for (cases, 0..) |c, i| idents[i] = pathToIdent(c, &bufs[i]);
    for (idents, 0..) |x, i| {
        for (idents[i + 1 ..]) |y| {
            try std.testing.expect(!std.mem.eql(u8, x, y));
        }
    }
}

test "pathToIdent: leading dot from plugin scripts stays a valid identifier" {
    var buf: [256]u8 = undefined;
    const ident = pathToIdent(".plugin_core/patrol", &buf);
    // Must not begin with `.` and the first byte must be a valid identifier start.
    try std.testing.expect(ident[0] == '_');
    try std.testing.expectEqualStrings("_d_plugin_u_core_s_patrol", ident);
}
