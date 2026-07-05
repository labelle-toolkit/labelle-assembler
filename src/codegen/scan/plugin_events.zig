//! Plugin / engine `Events` discovery extracted from `codegen/scan.zig`
//! (behavior-preserving split, labelle-assembler#534 follow-up).
//!
//! Walks each plugin's (and the engine's) `src/root.zig` for the
//! top-level `pub const Events = struct { ... }` block and collects every
//! nested `pub const <event> = struct` as a `PluginEvent`, feeding the
//! generated `GameEvents` union. Re-exported from the `scan.zig` barrel.

const std = @import("std");
const config = @import("../../config.zig");
const cache = @import("../../cache.zig");
const sanitize = @import("sanitize.zig");
const sanitizePluginIdent = sanitize.sanitizePluginIdent;

const ProjectConfig = config.ProjectConfig;

/// A single discovered `pub const <event_name> = struct {...}` declaration
/// inside a plugin's `pub const Events = struct { ... }`. Owned by
/// `PluginEvents.deinit` — all three strings (`plugin_import_name`,
/// `plugin_sanitized`, `event_name`) are heap-allocated dupes so the
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
    // Tolerate any non-OOM read failure (missing root.zig, parse errors,
    // permission issues) — same back-compat path every existing plugin
    // without an `Events` decl takes. OOM is *not* swallowed: it
    // propagates so the caller's allocator sees a clean failure path
    // instead of an empty-discovery false negative under memory pressure.
    const src = std.Io.Dir.cwd().readFileAlloc(io, root_path, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
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

            // Errdefer-per-dupe so a mid-chain OOM (or the final
            // `append`) can't strand the already-duped strings. Each
            // errdefer is cancelled once `append` succeeds and the
            // entry takes ownership of all three slices.
            const duped_import_name = try allocator.dupe(u8, module_name);
            errdefer allocator.free(duped_import_name);
            const duped_sanitized = try allocator.dupe(u8, sanitized);
            errdefer allocator.free(duped_sanitized);
            const duped_event_name = try allocator.dupe(u8, event_name);
            errdefer allocator.free(duped_event_name);

            try entries.append(allocator, .{
                .plugin_import_name = duped_import_name,
                .plugin_sanitized = duped_sanitized,
                .event_name = duped_event_name,
            });
        }
    }
}
