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
const scanners = @import("../flow_catalog/scanners.zig");

const ProjectConfig = config.ProjectConfig;
const ScriptEntry = script_scanner.ScriptScanner.ScriptEntry;

/// Write a formatted message directly to stderr without a log-level prefix.
///
/// `std.log.err` is deliberately avoided here for the same reason as in
/// `src/scene_manifest.zig`: the assembler's test suite has negative-path
/// tests that `expectError(...)` from these emitters, and the test runner's
/// log interceptor would flag any `std.log.err` call as a hard failure even
/// when the surrounding test is *expecting* the error. Writing to stderr
/// directly (via the process-wide Io from `config.globalIo()`) keeps the
/// human-readable diagnostic in front of the user without tripping that
/// trap. Mirrors the `writeStderr` helpers in `main.zig` / `cache_cmd.zig`,
/// just with `bufPrint` for the `{d}` substitution; the format string is
/// printed verbatim on bufPrint overflow so the user still sees *something*.
fn stderrPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    std.Io.File.stderr().writeStreamingAll(config.globalIo(), msg) catch {};
}

/// Scan result for one **pack** (Packs RFC §4, labelle-assembler#439).
///
/// A *pack* is a light, directory-scanned plugin: instead of contributing
/// components/events/prefabs through decl-modules (`pub const Components`),
/// it drops game-convention files into `components/ events/ prefabs/ hooks/`
/// subdirs — scanned the same way the game root is. `generate` copies each
/// subdir into `<target>/packs/<name>/<subdir>/` and records the scanned
/// stems here so the codegen block-writers can register them into the SAME
/// registries the game root feeds (the "unified set", RFC §4 / §6-1b).
///
/// `import_prefix` is the path the generated `main.zig` imports through,
/// e.g. `"packs/citizens"` — files live at
/// `<import_prefix>/{components,events,prefabs}/<name>.<ext>`.
///
/// Namespacing (#440): a pack's contributed component / prefab / pack-local
/// event names are registered in the generated global registry under the
/// invisible `<pack>__<Name>` prefix (see `packNamespacePrefix`) — authors
/// write local names (`.Worker`) and the assembler namespaces them so a pack
/// and the game root that both define `Worker` never collide. The physical
/// path is already pack-namespaced (`import_prefix`), so files never collide
/// on disk either.
///
/// Owned by `deinit` — `name`, `import_prefix`, and every string in the
/// four name slices are heap dupes made by the scan/copy pass.
pub const PackScan = struct {
    name: []const u8,
    import_prefix: []const u8,
    component_names: []const []const u8,
    event_names: []const []const u8,
    prefab_names: []const []const u8,
    /// Pack `hooks/*.zig` stems (#440). Registered into the SAME `GameHooks`
    /// receiver tuple as the game root's `hooks/`, under the `<pack>__` ident
    /// prefix so two packs shipping `overlay.zig` don't collide on the import
    /// alias / receiver-instance identifier.
    hook_names: []const []const u8 = &.{},

    pub fn deinit(self: *PackScan, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.import_prefix);
        freeNameSlice(allocator, self.component_names);
        freeNameSlice(allocator, self.event_names);
        freeNameSlice(allocator, self.prefab_names);
        freeNameSlice(allocator, self.hook_names);
    }

    fn freeNameSlice(allocator: std.mem.Allocator, names: []const []const u8) void {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }
};

/// Derive a pack's invisible namespace ident from its manifest `name`
/// (Packs RFC §4, #440). Every registry ident a pack contributes — the
/// component registry field (`<pfx>__<Pascal>`), the pack-local event
/// variant + its import alias, the prefab registration key, and the hook
/// import alias / receiver-instance ident — is prefixed `<pfx>__`, mirroring
/// the existing `<plugin>__<event>` convention (`plugin_registries.zig`).
/// The name is sanitized to a valid Zig identifier fragment the same way
/// plugin idents are, so a pack named `my-pack` namespaces as `my_pack__…`.
///
/// SAVE-STABILITY: the prefixed component name is the on-disk save key
/// (`serde.componentName`, engine-side), so a pack's `name` is **save-stable**
/// — renaming a shipped pack changes every component's save key and is
/// therefore a save migration, not a cosmetic rename. Treat a pack `name`
/// like a serialized schema field once the pack has shipped.
pub fn packNamespacePrefix(pack_name: []const u8, buf: *[128]u8) []const u8 {
    return sanitizePluginIdent(pack_name, buf);
}

/// Back-compat shim (#440). Rewrites only pack-owned component KEYS —
/// delegates to `rewritePackLocalRefs` with an empty prefab-name set so no
/// `"prefab"` values are touched. Kept because the unit tests below (and any
/// external caller) reference this narrower entry point directly. New call
/// sites should prefer `rewritePackLocalRefs`, which also rewrites pack-local
/// prefab references (chatgpt-codex finding #1).
pub fn rewritePackComponentKeys(
    allocator: std.mem.Allocator,
    src: []const u8,
    local_keys: []const []const u8,
    prefix: []const u8,
) ![]u8 {
    return rewritePackLocalRefs(allocator, src, local_keys, &.{}, prefix);
}

/// Rewrite a pack's own prefab/scene JSONC so **local references to the
/// pack's OWN components and prefabs** resolve in the unified registry
/// (Packs RFC §4, #440). Two kinds of reference are rewritten, both keeping
/// the `<pack>__` prefix invisible to the author:
///
///   1. **Component keys** — a component-declaration key whose content
///      exactly equals one of `component_keys` becomes `<prefix>__<Name>`
///      (`"Worker"` → `"citizens__Worker"`), byte-matching the field the
///      component registry emits.
///   2. **Prefab references** — a `"prefab"` string *value* whose content
///      exactly equals one of `prefab_names` becomes `<prefix>__<name>`
///      (`"prefab": "worker"` → `"prefab": "citizens__worker"`), matching the
///      `addEmbeddedPrefab(&g, "citizens__worker", …)` registration key. A
///      composing prefab (`{ "prefab": "worker" }`) would otherwise reference
///      the bare `worker`, which is never registered (chatgpt-codex #1).
///
/// **Context-awareness (chatgpt-codex #2).** Component-key rewriting is scoped
/// to genuine component-declaration positions — a key is only rewritten when
/// it is a direct member of an object reached through a `"components"` or
/// `"overrides"` key (the wrapped shape the engine's `entityPatch` /
/// `prefabComponents` treat as the component map). A key of the SAME text that
/// appears as *payload data* nested inside a component's value (e.g.
/// `{ "Spawner": { "counts": { "Worker": 3 } } }`) is left untouched, so the
/// payload never gets corrupted before deserialization.
///
/// Prefab-reference rewriting is scoped to the *value* of a `"prefab"` key,
/// and only when that value names one of the pack's OWN prefabs — a reference
/// to a non-pack (game-root / built-in) prefab is left alone.
///
/// **Boundary (documented):** the engine also accepts a *flat* shape (RFC
/// #596) where PascalCase component keys sit directly on an entity object with
/// no `"components"`/`"overrides"` wrapper. Detecting that shape reliably at
/// the byte level requires full structural entity-vs-payload disambiguation;
/// the pack authoring convention (and every pack fixture) uses the wrapped
/// shape, so flat-form component keys are intentionally NOT rewritten here.
/// This is the conservative-but-correct scope the ticket calls for: it never
/// corrupts payload data, at the cost of not namespacing the flat shape.
///
/// String *values* (other than `"prefab"`) and JSONC comment text are never
/// rewritten. Returns an allocator-owned buffer; when nothing matches it is
/// still a fresh dupe of the input, so the caller frees unconditionally.
pub fn rewritePackLocalRefs(
    allocator: std.mem.Allocator,
    src: []const u8,
    component_keys: []const []const u8,
    prefab_names: []const []const u8,
    prefix: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // Object-nesting context. `component_map_stack` records, per open `{`,
    // whether that object is a component map (its direct keys are component
    // names) — true only when the object is the value of a `"components"` or
    // `"overrides"` key. Array frames push `false` (an array is never a
    // component map, and objects nested in an array — entity list entries —
    // start a fresh non-component-map scope).
    var component_map_stack: std.ArrayList(bool) = .empty;
    defer component_map_stack.deinit(allocator);

    // The most-recent object key at the current level, awaiting its value.
    // Drives both "is the next `{` a component map?" and "is this string the
    // value of a `prefab` key?". Reset whenever the pending key's value is
    // consumed (a value string, a container open/close, or a `,`).
    var pending_key: ?[]const u8 = null;

    const in_component_map = struct {
        fn f(stack: []const bool) bool {
            return stack.len > 0 and stack[stack.len - 1];
        }
    }.f;

    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];

        // JSONC line comment — copy verbatim to end of line.
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            const nl = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
            try out.appendSlice(allocator, src[i..nl]);
            i = nl;
            continue;
        }
        // JSONC block comment — copy verbatim to the closing `*/`.
        if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            const close = std.mem.indexOfPos(u8, src, i + 2, "*/");
            const end = if (close) |p| p + 2 else src.len;
            try out.appendSlice(allocator, src[i..end]);
            i = end;
            continue;
        }
        // Container open — the object/array is the value of `pending_key`.
        if (c == '{') {
            const is_comp_map = if (pending_key) |k|
                (std.mem.eql(u8, k, "components") or std.mem.eql(u8, k, "overrides"))
            else
                false;
            try component_map_stack.append(allocator, is_comp_map);
            pending_key = null;
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        if (c == '[') {
            try component_map_stack.append(allocator, false);
            pending_key = null;
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        if (c == '}' or c == ']') {
            if (component_map_stack.items.len > 0) _ = component_map_stack.pop();
            pending_key = null;
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        // A comma ends the current key/value pair — clear any pending key so
        // a primitive value (number/bool/null) can't leak into the next pair.
        if (c == ',') {
            pending_key = null;
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        // String literal — capture its inner content, then decide whether it
        // is a component-declaration key, a `"prefab"` value, or neither.
        if (c == '"') {
            const content_start = i + 1;
            var j = content_start;
            while (j < src.len) : (j += 1) {
                if (src[j] == '\\' and j + 1 < src.len) {
                    j += 1; // skip the escaped char
                    continue;
                }
                if (src[j] == '"') break;
            }
            // `j` is the closing quote (or src.len for an unterminated
            // string — pass it through untouched rather than guessing).
            if (j >= src.len) {
                try out.appendSlice(allocator, src[i..]);
                i = src.len;
                continue;
            }
            const content = src[content_start..j];
            const is_key = nextSignificantIsColon(src, j + 1);

            var rewrite = false;
            if (is_key) {
                // Component-declaration key: only inside a component map.
                if (in_component_map(component_map_stack.items) and
                    containsKey(component_keys, content))
                {
                    rewrite = true;
                }
            } else {
                // Value position: rewrite a pack-owned prefab reference
                // (`"prefab": "worker"` → `"prefab": "citizens__worker"`).
                if (pending_key) |k| {
                    if (std.mem.eql(u8, k, "prefab") and containsKey(prefab_names, content)) {
                        rewrite = true;
                    }
                }
            }

            if (rewrite) {
                try out.append(allocator, '"');
                try out.appendSlice(allocator, prefix);
                try out.appendSlice(allocator, "__");
                try out.appendSlice(allocator, content);
                try out.append(allocator, '"');
            } else {
                try out.appendSlice(allocator, src[i .. j + 1]);
            }

            // Track the pending key for the container-type / prefab-value
            // lookups above; a value string closes the pending pair.
            if (is_key) {
                pending_key = content;
            } else {
                pending_key = null;
            }
            i = j + 1;
            continue;
        }

        try out.append(allocator, c);
        i += 1;
    }

    return out.toOwnedSlice(allocator);
}

/// True iff the next significant byte at/after `from` (skipping whitespace
/// and JSONC comments) is a `:` — i.e. the preceding string literal was an
/// object key rather than a value. Pure lookahead; consumes nothing.
fn nextSignificantIsColon(src: []const u8, from: usize) bool {
    var i = from;
    while (i < src.len) {
        const c = src[i];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            i = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            const close = std.mem.indexOfPos(u8, src, i + 2, "*/");
            i = if (close) |p| p + 2 else src.len;
            continue;
        }
        return c == ':';
    }
    return false;
}

fn containsKey(keys: []const []const u8, needle: []const u8) bool {
    for (keys) |k| {
        if (std.mem.eql(u8, k, needle)) return true;
    }
    return false;
}

/// Rewrite a pack's copied `hooks/*.zig` source so a handler written with the
/// pack's BARE local event name receives its `<pack>__`-prefixed event
/// (chatgpt-codex finding #3).
///
/// The engine's hook dispatcher (`labelle-core/src/dispatcher.zig`) matches a
/// receiver's handler-fn NAME against the `GameEvents` variant tag. Pack
/// events are folded into `GameEvents` under the invisible `<pack>__<event>`
/// tag, so a pack hook's natural `pub fn worker_died(self, data)` would (a)
/// never receive `citizens__worker_died`, and worse (b) trip the dispatcher's
/// comptime guard — a 2-param handler whose name matches no variant is a hard
/// `@compileError`. To keep the prefix invisible, this renames each qualifying
/// handler's DECL to the prefixed tag (`worker_died` → `citizens__worker_died`)
/// in the copied source, exactly mirroring the JSONC key/prefab rewrite.
///
/// A handler qualifies only when it is a `pub fn`, takes exactly two
/// parameters (the `(self, data)` shape the dispatcher treats as a handler),
/// and its name EXACTLY equals one of the pack's own `event_names`. Handlers
/// for engine / plugin / game events (bare names that are already valid
/// variant tags — e.g. `tick`, `game_init`) are left untouched, so a pack
/// hook keeps receiving those. Only the declaration site is renamed; a pack
/// that also calls its handler internally by the bare name would surface a
/// clean compile error rather than a silent mis-dispatch.
///
/// Returns an allocator-owned buffer; a content-preserving dupe when nothing
/// matches, so the caller frees unconditionally.
pub fn rewritePackHookHandlerNames(
    allocator: std.mem.Allocator,
    src: []const u8,
    event_names: []const []const u8,
    prefix: []const u8,
) ![]u8 {
    if (event_names.len == 0) return allocator.dupe(u8, src);

    const src_z = try allocator.dupeZ(u8, src);
    defer allocator.free(src_z);

    var ast = try std.zig.Ast.parse(allocator, src_z, .zig);
    defer ast.deinit(allocator);

    // Collect the byte offsets of every handler-fn name token to rename.
    var sites: std.ArrayList(usize) = .empty;
    defer sites.deinit(allocator);
    try collectHookHandlerNameOffsets(allocator, &ast, ast.rootDecls(), event_names, &sites);

    if (sites.items.len == 0) return allocator.dupe(u8, src);
    std.mem.sort(usize, sites.items, {}, std.sort.asc(usize));

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var cursor: usize = 0;
    for (sites.items) |off| {
        // Each recorded offset is the start of a bare event-name token. Emit
        // everything up to it, then the `<prefix>__` insertion; the original
        // name bytes follow untouched (cursor advances past the prefix only).
        try out.appendSlice(allocator, src[cursor..off]);
        try out.appendSlice(allocator, prefix);
        try out.appendSlice(allocator, "__");
        cursor = off;
    }
    try out.appendSlice(allocator, src[cursor..]);
    return out.toOwnedSlice(allocator);
}

/// Walk `members` (a decl list) for `pub fn <event>` handlers, recording the
/// source byte offset of each qualifying name token into `sites`, and recurse
/// into nested container decls (the `pub const Overlay = struct { … }` that
/// holds the handlers). See `rewritePackHookHandlerNames` for the match rule.
fn collectHookHandlerNameOffsets(
    allocator: std.mem.Allocator,
    ast: *std.zig.Ast,
    members: []const std.zig.Ast.Node.Index,
    event_names: []const []const u8,
    sites: *std.ArrayList(usize),
) !void {
    for (members) |m| {
        // Handler fn? (pub, 2 params, name matches a pack event.)
        var fn_buf: [1]std.zig.Ast.Node.Index = undefined;
        if (ast.fullFnProto(&fn_buf, m)) |fp| {
            if (fp.visib_token != null) {
                if (fp.name_token) |nt| {
                    const name = ast.tokenSlice(nt);
                    if (containsKey(event_names, name) and fnProtoParamCount(ast, fp) == 2) {
                        // `tokenSlice` returns a sub-slice of `ast.source`;
                        // its pointer offset is the byte position we splice at.
                        const off = @intFromPtr(name.ptr) - @intFromPtr(ast.source.ptr);
                        try sites.append(allocator, off);
                    }
                }
            }
        }
        // Recurse into a `const X = struct/union/enum { … }` member so nested
        // handler methods (the common `pub const Hook = struct { … }` shape)
        // are reached.
        if (ast.fullVarDecl(m)) |vd| {
            if (vd.ast.init_node.unwrap()) |init_node| {
                var buf: [2]std.zig.Ast.Node.Index = undefined;
                if (ast.fullContainerDecl(&buf, init_node)) |container| {
                    try collectHookHandlerNameOffsets(allocator, ast, container.ast.members, event_names, sites);
                }
            }
        }
    }
}

fn fnProtoParamCount(ast: *std.zig.Ast, fp: std.zig.Ast.full.FnProto) usize {
    var count: usize = 0;
    var it = fp.iterate(ast);
    while (it.next()) |_| count += 1;
    return count;
}

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
    /// `true` when the node's `impl` fn returns `void` — a **command**
    /// (RFC-FLOW-VOCABULARY §6). flow-codegen's `CustomNode` lowering
    /// emits a bare statement for commands and binds the result to
    /// `n<id>_value` for reporters (non-void). The assembler computes
    /// this once at discovery time so flow-codegen consumes the
    /// precomputed flag rather than re-reflecting the impl. An explicit
    /// `.kind = .command` / `.kind = .reporter` in the FlowNode factory
    /// call overrides the inferred return-type default — same rule the
    /// editor catalog applies in `flow_catalog/discovery.zig`.
    is_void: bool = true,
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

/// Resolve a FlowNode's command-vs-reporter shape — `true` for a
/// `void`-returning (command) impl, `false` for a value-returning
/// (reporter) one. Mirrors the editor-catalog rule in
/// `flow_catalog/discovery.zig` so the two discovery paths agree:
///
///   1. An explicit `.kind = .command` / `.kind = .reporter` in the
///      `labelle.FlowNode(.{...})` factory call always wins.
///   2. Otherwise the impl's declared return type decides: `void` (or
///      an impl we can't resolve / that omits a return type) is a
///      command; anything else is a reporter.
///
/// `init_src` is the FlowNode factory call's source text; `ast` is the
/// already-parsed module AST so we can walk back to the impl fn's
/// prototype. A non-resolvable `impl` (defined in a sibling file)
/// degrades to `is_void = true` — the command shape — matching the
/// catalog's "no pin info" fallback, since we have no return type to
/// promote it to a reporter.
fn flowNodeIsVoid(ast: *std.zig.Ast, init_src: []const u8) bool {
    const cfg_src = scanners.innerCallArg(init_src);

    // Explicit `.kind` override — same precedence as the catalog.
    if (scanners.scanFieldEnumLit(cfg_src, ".kind")) |ek| {
        if (std.mem.eql(u8, ek, "command")) return true;
        if (std.mem.eql(u8, ek, "reporter")) return false;
    }

    // Infer from the impl's return type. Skip the implicit
    // `game: anytype` — we only care about the return, not the params.
    const impl_name = scanners.scanFieldIdent(cfg_src, ".impl") orelse return true;
    if (impl_name.len == 0) return true;
    const fn_node = scanners.findFnByName(ast, impl_name) orelse return true;
    var fn_buf: [1]std.zig.Ast.Node.Index = undefined;
    const fp = ast.fullFnProto(&fn_buf, fn_node) orelse return true;
    const rt_node = fp.ast.return_type.unwrap() orelse return true;
    const rt = std.mem.trim(u8, ast.getNodeSource(rt_node), " \t\r\n");
    // A fallible command (`!void` / `anyerror!void`) is still a command —
    // the error union adds no output pin. Kept in lock-step with the
    // editor-catalog inference in `flow_catalog/discovery.zig`.
    return std.mem.eql(u8, rt, "void") or std.mem.endsWith(u8, rt, "!void");
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
                // Errdefer-per-allocation: `constructs_value` is an
                // optional dupe owned by `extractConstructsString`;
                // it leaks if any subsequent dupe or the `append`
                // fails. Each errdefer is cancelled once `append`
                // moves ownership into the entry.
                const constructs_value = extractConstructsString(allocator, init_src);
                errdefer if (constructs_value) |c| allocator.free(c);

                // Command-vs-reporter shape (RFC-FLOW-VOCABULARY §6).
                // Resolved once here so flow-codegen's `CustomNode`
                // lowering consumes the precomputed flag — no allocation,
                // borrows nothing past this loop iteration.
                const is_void = flowNodeIsVoid(&ast, init_src);

                const duped_path = try allocator.dupe(u8, module_import_path);
                errdefer allocator.free(duped_path);
                const duped_sanitized = try allocator.dupe(u8, module_sanitized);
                errdefer allocator.free(duped_sanitized);
                const duped_name = try allocator.dupe(u8, member_name);
                errdefer allocator.free(duped_name);

                try flow_nodes_out.append(allocator, .{
                    .module_import_path = duped_path,
                    .module_sanitized = duped_sanitized,
                    .node_name = duped_name,
                    .is_script = is_script,
                    .is_void = is_void,
                    .constructs = constructs_value,
                });
            } else if (is_pin_styles) {
                const duped_path = try allocator.dupe(u8, module_import_path);
                errdefer allocator.free(duped_path);
                const duped_sanitized = try allocator.dupe(u8, module_sanitized);
                errdefer allocator.free(duped_sanitized);
                const duped_name = try allocator.dupe(u8, member_name);
                errdefer allocator.free(duped_name);

                try pin_styles_out.append(allocator, .{
                    .module_import_path = duped_path,
                    .module_sanitized = duped_sanitized,
                    .type_name = duped_name,
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
                const duped_path = try allocator.dupe(u8, module_import_path);
                errdefer allocator.free(duped_path);
                const duped_sanitized = try allocator.dupe(u8, module_sanitized);
                errdefer allocator.free(duped_sanitized);
                const duped_name = try allocator.dupe(u8, member_name);
                errdefer allocator.free(duped_name);

                try coercions_out.append(allocator, .{
                    .module_import_path = duped_path,
                    .module_sanitized = duped_sanitized,
                    .name = duped_name,
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
        // Plugins without a `src/root.zig` (or with an unreadable one) are
        // skipped per the back-compat policy. OOM is propagated rather
        // than masked as "this plugin contributes nothing" — same
        // rationale as `discoverEventsFromRoot`.
        const src = std.Io.Dir.cwd().readFileAlloc(io, root_path, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
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
        // Unreadable / missing script source is treated as "contributes
        // nothing" — the generated `main.zig` will surface a clearer
        // error when it tries to compile the script. OOM stays a hard
        // failure rather than silently swallowing memory pressure.
        const src = std.Io.Dir.cwd().readFileAlloc(io, script_path, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
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

    // Each `toOwnedSlice` resets its source ArrayList to empty, so the
    // top-level errdefer chains above stop covering already-detached
    // slices the moment a *later* `toOwnedSlice` fails. Stage each
    // owned slice into a local first and guard it with a slice-shaped
    // errdefer so a mid-sequence OOM still frees everything cleanly
    // before the struct-return packages them up.
    const flow_nodes_slice = try flow_nodes.toOwnedSlice(allocator);
    errdefer {
        for (flow_nodes_slice) |e| {
            allocator.free(e.module_import_path);
            allocator.free(e.module_sanitized);
            allocator.free(e.node_name);
            if (e.constructs) |c| allocator.free(c);
        }
        allocator.free(flow_nodes_slice);
    }

    const pin_styles_slice = try pin_styles.toOwnedSlice(allocator);
    errdefer {
        for (pin_styles_slice) |e| {
            allocator.free(e.module_import_path);
            allocator.free(e.module_sanitized);
            allocator.free(e.type_name);
        }
        allocator.free(pin_styles_slice);
    }

    const coercions_slice = try coercions.toOwnedSlice(allocator);

    return .{
        .flow_nodes = flow_nodes_slice,
        .pin_styles = pin_styles_slice,
        .coercions = coercions_slice,
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

/// One game-script module that exports `pub const FlowNodes` and is
/// therefore promoted to a NAMED build-system module
/// (labelle-assembler#240, Gap 2). A game script reached by both the
/// **root** module (path-imported by `AllScripts` in main.zig for hook
/// registration) and the **game** module (the shim's `PluginFlowNodes`)
/// would be a member of two modules — which Zig forbids. Promotion to a
/// named module sidesteps the conflict: the file is the root of its own
/// module, and both the exe/root module and the `game` module add it as
/// an `@import("<named>")` import.
///
/// `module_name` is the build-system module name (also the string every
/// `@import("<named>")` consumer uses). `rel_path` is the script's path
/// under `scripts/` (so build.zig can `b.path("scripts/<rel>")` the
/// root source file).
pub const PromotedScript = struct {
    /// Named build-system module name, e.g. `script__bouncing_u_ball`.
    /// Built by `promotedScriptModuleName` from `module_sanitized` so it
    /// matches the `<module_sanitized>__<node>` decl prefix used in the
    /// `PluginFlowNodes` block. Caller owns the bytes.
    module_name: []const u8,
    /// Script path under `scripts/`, e.g. `bouncing_ball.zig`. Caller
    /// owns the bytes.
    rel_path: []const u8,
};

/// Build the named-module name for a FlowNodes-bearing game script from
/// its `module_sanitized` form (the `pathToIdent` of its rel_path). The
/// `script__` prefix namespaces it away from plugin module names (which
/// are the project.labelle `.name` verbatim) so a game script and a
/// plugin can never collide on the module-name string. Reusing
/// `module_sanitized` keeps the name byte-identical to the
/// `<module_sanitized>__<node>` decl prefix in `PluginFlowNodes`, which
/// is the invariant the three emission sites (build.zig wiring,
/// main.zig `PluginFlowNodes` + `AllScripts`, and the shim) all depend
/// on. Caller owns the returned bytes.
pub fn promotedScriptModuleName(
    allocator: std.mem.Allocator,
    module_sanitized: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "script__{s}", .{module_sanitized});
}

/// Collect the deduplicated set of game scripts that must be promoted to
/// named modules — every `is_script` FlowNode's source module, keyed by
/// `module_sanitized` so a script declaring N FlowNodes yields ONE
/// promoted module. Plugin-contributed nodes (`is_script == false`) are
/// skipped: plugins are already named modules (Gap 2 doesn't apply).
///
/// Caller owns the returned slice and each `PromotedScript`'s
/// `module_name` / `rel_path` bytes — free via `freePromotedScripts`.
pub fn collectPromotedScripts(
    allocator: std.mem.Allocator,
    flow_nodes: []const PluginFlowNode,
) ![]PromotedScript {
    var out: std.ArrayList(PromotedScript) = .empty;
    errdefer {
        for (out.items) |p| {
            allocator.free(p.module_name);
            allocator.free(p.rel_path);
        }
        out.deinit(allocator);
    }
    for (flow_nodes) |fn_| {
        if (!fn_.is_script) continue;
        // Dedupe by sanitized module — one named module per script file.
        var seen = false;
        for (out.items) |p| {
            if (std.mem.eql(u8, p.module_name[("script__".len)..], fn_.module_sanitized)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        const module_name = try promotedScriptModuleName(allocator, fn_.module_sanitized);
        errdefer allocator.free(module_name);
        const rel_path = try allocator.dupe(u8, fn_.module_import_path);
        try out.append(allocator, .{ .module_name = module_name, .rel_path = rel_path });
    }
    return out.toOwnedSlice(allocator);
}

/// Free a slice returned by `collectPromotedScripts`.
pub fn freePromotedScripts(allocator: std.mem.Allocator, scripts: []const PromotedScript) void {
    for (scripts) |p| {
        allocator.free(p.module_name);
        allocator.free(p.rel_path);
    }
    allocator.free(scripts);
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
                stderrPrint("labelle: path too long for identifier (max {d} chars): too many escaped chars\n", .{b.len});
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

test "packNamespacePrefix: sanitizes the pack name into a Zig ident fragment" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("citizens", packNamespacePrefix("citizens", &buf));
    // Non-identifier bytes collapse to `_`, same as plugin idents.
    try std.testing.expectEqualStrings("my_pack", packNamespacePrefix("my-pack", &buf));
}

test "rewritePackComponentKeys: rewrites only pack-owned component KEYS" {
    const allocator = std.testing.allocator;
    const src =
        \\{
        \\    "components": {
        \\        "Worker": { "hp": 3, "label": "Worker" },
        \\        "Position": { "x": 0 }
        \\    }
        \\}
    ;
    const out = try rewritePackComponentKeys(allocator, src, &.{"Worker"}, "citizens");
    defer allocator.free(out);

    // Pack-owned key rewritten …
    try std.testing.expect(std.mem.indexOf(u8, out, "\"citizens__Worker\":") != null);
    // … built-in `Position` untouched …
    try std.testing.expect(std.mem.indexOf(u8, out, "\"Position\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "citizens__Position") == null);
    // … and the VALUE `"Worker"` (not a key) left alone.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"label\": \"Worker\"") != null);
}

test "rewritePackComponentKeys: leaves a matching name in a comment alone" {
    const allocator = std.testing.allocator;
    const src =
        \\{
        \\    // "Worker": legacy note, not a real key
        \\    "components": { "Worker": {} }
        \\}
    ;
    const out = try rewritePackComponentKeys(allocator, src, &.{"Worker"}, "citizens");
    defer allocator.free(out);

    // The real key was rewritten …
    try std.testing.expect(std.mem.indexOf(u8, out, "{ \"citizens__Worker\": {} }") != null);
    // … but the comment text is preserved verbatim.
    try std.testing.expect(std.mem.indexOf(u8, out, "// \"Worker\": legacy note") != null);
}

test "rewritePackComponentKeys: no matches yields a content-preserving dupe" {
    const allocator = std.testing.allocator;
    const src = "{ \"Position\": { \"x\": 0 } }";
    const out = try rewritePackComponentKeys(allocator, src, &.{"Worker"}, "citizens");
    defer allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "rewritePackLocalRefs: payload data key matching a component name is NOT rewritten (chatgpt-codex #2)" {
    const allocator = std.testing.allocator;
    // `Worker` is a pack-owned component. It appears BOTH as a real component
    // declaration key (must be rewritten) AND as a nested payload-data key
    // inside `Spawner.counts` (must be left alone — rewriting it corrupts the
    // payload before deserialization).
    const src =
        \\{
        \\    "components": {
        \\        "Worker": { "hp": 3 },
        \\        "Spawner": { "counts": { "Worker": 3 } }
        \\    }
        \\}
    ;
    const out = try rewritePackLocalRefs(allocator, src, &.{"Worker"}, &.{}, "citizens");
    defer allocator.free(out);

    // The real component-declaration key IS rewritten …
    try std.testing.expect(std.mem.indexOf(u8, out, "\"citizens__Worker\": { \"hp\": 3 }") != null);
    // … the `Spawner` declaration key is also under `components` (not a pack
    // component, so untouched) …
    try std.testing.expect(std.mem.indexOf(u8, out, "\"Spawner\":") != null);
    // … but the nested payload key `"Worker"` inside `counts` is NOT rewritten.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"counts\": { \"Worker\": 3 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "citizens__Worker\": 3") == null);
}

test "rewritePackLocalRefs: keys inside an overrides wrapper are rewritten" {
    const allocator = std.testing.allocator;
    const src =
        \\{ "prefab": "base", "overrides": { "Worker": { "hp": 9 } } }
    ;
    // `base` is not a pack prefab here, so the ref is left alone; the override
    // component key IS a pack component, so it is namespaced.
    const out = try rewritePackLocalRefs(allocator, src, &.{"Worker"}, &.{}, "citizens");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"prefab\": \"base\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"citizens__Worker\":") != null);
}

test "rewritePackLocalRefs: a pack-local prefab reference value is rewritten (chatgpt-codex #1)" {
    const allocator = std.testing.allocator;
    // A pack prefab composing another SAME-pack prefab by local name. The
    // `"prefab"` value must resolve to the namespaced registration key.
    const src =
        \\{
        \\    "children": [
        \\        { "prefab": "worker", "components": { "Position": { "x": 1 } } },
        \\        { "prefab": "external" }
        \\    ]
        \\}
    ;
    // `worker` is pack-owned; `external` is NOT (a game-root/foreign prefab).
    const out = try rewritePackLocalRefs(allocator, src, &.{}, &.{"worker"}, "citizens");
    defer allocator.free(out);

    // The same-pack reference is namespaced …
    try std.testing.expect(std.mem.indexOf(u8, out, "\"prefab\": \"citizens__worker\"") != null);
    // … the foreign reference is left bare …
    try std.testing.expect(std.mem.indexOf(u8, out, "\"prefab\": \"external\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "citizens__external") == null);
    // … and `Position` (built-in, not pack-owned) is untouched.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"Position\":") != null);
}

test "rewritePackHookHandlerNames: bare pack-event handler is renamed to the prefixed tag (chatgpt-codex #3)" {
    const allocator = std.testing.allocator;
    // A pack hook: a handler for the pack's OWN event (`worker_died`, bare),
    // plus a handler for a built-in engine event (`tick`, must stay bare so it
    // keeps matching the un-prefixed engine variant), plus a private helper
    // that happens to share the event name (must NOT be renamed).
    const src =
        \\const std = @import("std");
        \\pub const Overlay = struct {
        \\    pub fn worker_died(self: *Overlay, data: anytype) void {
        \\        _ = self;
        \\        _ = data;
        \\    }
        \\    pub fn tick(self: *Overlay, data: anytype) void {
        \\        _ = self;
        \\        _ = data;
        \\    }
        \\    fn helper(self: *Overlay) void {
        \\        _ = self;
        \\    }
        \\};
    ;
    const out = try rewritePackHookHandlerNames(allocator, src, &.{"worker_died"}, "citizens");
    defer allocator.free(out);

    // The pack-event handler DECL is renamed to the prefixed tag …
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn citizens__worker_died(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn worker_died(") == null);
    // … the engine-event handler keeps its bare name …
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn tick(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "citizens__tick") == null);
    // … the private helper (not a pack event) is untouched.
    try std.testing.expect(std.mem.indexOf(u8, out, "fn helper(") != null);
}

test "rewritePackHookHandlerNames: no pack events is a content-preserving dupe" {
    const allocator = std.testing.allocator;
    const src = "pub const H = struct { pub fn tick(self: *H, d: anytype) void { _ = self; _ = d; } };";
    const out = try rewritePackHookHandlerNames(allocator, src, &.{}, "citizens");
    defer allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

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
