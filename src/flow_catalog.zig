//! Flow catalog sidecar emitter — labelle-assembler#178 (deferred polish for
//! labelle-gui#170 phase 4).
//!
//! The static `flow_node_catalog.zig` in `labelle-gui` mirrors box2d's 14
//! FlowNodes by hand. That breaks for any other plugin a project pulls in,
//! and requires a labelle-gui release every time a plugin changes its
//! `FlowNodes` block.
//!
//! This module extends the existing phase 2 discovery (`PluginFlowDecls` in
//! `main_zig.zig`) with the additional reflection needed by the editor —
//! `display_name`, `docs`, `kind`, per-pin name/type/label/default, return
//! type, and pin-style color — then writes the result to
//! `<target_dir>/flow_catalog.json` so the editor can pick it up at
//! project-open time.
//!
//! ## What's emitted
//!
//! ```jsonc
//! {
//!   "generated_at": "2026-05-23T...",
//!   "plugins": [
//!     {
//!       "name": "box2d",
//!       "flow_nodes": [
//!         {
//!           "qualified": "box2d.apply_impulse",
//!           "display_name": "Apply Impulse",
//!           "category": "box2d",
//!           "docs": "...",
//!           "kind": "command",
//!           "pins": [
//!             { "name": "entity", "label": "Entity", "zig_type": "u32", "dir": "input" },
//!             { "name": "ix",     "label": "Impulse X", "zig_type": "f32", "dir": "input" },
//!             ...
//!           ],
//!           "return_type": null
//!         }
//!       ],
//!       "pin_styles": [
//!         { "zig_type": "BodyId", "label": "Body", "color": [80, 200, 200] }
//!       ]
//!     }
//!   ]
//! }
//! ```
//!
//! ## How discovery works
//!
//! For each plugin and game-script module we already parse with
//! `std.zig.Ast` in `discoverPluginFlowDecls`. Here we re-walk the same
//! sources and pull more out of each `FlowNodes` / `PinStyles` decl:
//!
//! - For a FlowNode (`pub const apply_impulse = labelle.FlowNode(.{ ... })`):
//!     1. `ast.getNodeSource(init_node)` gives the call's source text.
//!     2. Lightweight text scans pick out `.impl = <ident>`,
//!        `.docs = "..."`, `.kind = .command|.reporter`, and the
//!        `.pins = .{ .<name> = .{ .label = "..." } ... }` map of
//!        per-pin label overrides.
//!     3. The impl function (`<ident>`) is then resolved against the
//!        same source's root decls — `fullFnProto` gives the param
//!        names and types, the return-type source range gives the
//!        single output pin's type (if non-void).
//! - For a PinStyle (`pub const BodyId = labelle.PinStyle{ ... }`):
//!     just text-scan the init source for `.label = "..."` and
//!     `.color = .{ .r = N, .g = N, .b = N, ... }`.
//!
//! Anything we can't parse degrades to a default (pin label = titlecased
//! name, kind = command if no return type, etc.). The editor's existing
//! static catalog is the safety net — projects that haven't regenerated
//! since this lands still work.
//!
//! ## Layout
//!
//! Pure file split (labelle-assembler#186) — implementation lives in
//! per-concern submodules; this file is a thin façade that re-exports
//! the public surface and hosts the top-level `emitFlowCatalogSidecar`
//! orchestrator plus the module's tests:
//!
//! - `flow_catalog/types.zig` — on-disk data shape (PinDetail,
//!   FlowNodeEntry, ModuleGroup, Catalog, …).
//! - `flow_catalog/scanners.zig` — low-level AST + source-text scanners
//!   (innerCallArg, scanField*, titlecaseFromIdent, …).
//! - `flow_catalog/discovery.zig` — walks one source buffer for
//!   FlowNodes / PinStyles / Events / Coercions blocks
//!   (discoverInSource + extract*Entry).
//! - `flow_catalog/json_writer.zig` — pretty-prints the catalog to JSON
//!   and writes the sidecar file.

const std = @import("std");
const config = @import("config.zig");
const cache = @import("cache.zig");
const script_scanner = @import("script_scanner.zig");
const main_zig = @import("main_zig.zig");

const types = @import("flow_catalog/types.zig");
const scanners = @import("flow_catalog/scanners.zig");
const discovery = @import("flow_catalog/discovery.zig");
const json_writer = @import("flow_catalog/json_writer.zig");

const ProjectConfig = config.ProjectConfig;
const ScriptEntry = script_scanner.ScriptScanner.ScriptEntry;

// ── Public surface (re-exported from `types.zig`) ──────────────────────
//
// `src/root.zig` exposes the whole `flow_catalog` namespace, so anything
// downstream might reach for these names needs to be visible here. The
// submodules are accessible too, but the historical shape is flat —
// keep that.
pub const SIDECAR_FILENAME = types.SIDECAR_FILENAME;
pub const PinDetail = types.PinDetail;
pub const FlowNodeEntry = types.FlowNodeEntry;
pub const PinStyleEntry = types.PinStyleEntry;
pub const CoercionEntry = types.CoercionEntry;
pub const EventEntry = types.EventEntry;
pub const ModuleGroup = types.ModuleGroup;
pub const Catalog = types.Catalog;

/// Public entry point: discover every FlowNode + PinStyle in the
/// project's plugins and game scripts, then write
/// `<target_dir>/flow_catalog.json`.
///
/// Returns the number of FlowNode entries emitted. A return of 0
/// means no plugin or script declared any FlowNodes — the sidecar is
/// still written (with an empty `plugins` array) so the editor sees
/// "this project regenerated, just has nothing in its palette".
///
/// The caller is responsible for `target_dir` already existing.
pub fn emitFlowCatalogSidecar(
    allocator: std.mem.Allocator,
    cfg: ProjectConfig,
    project_dir: []const u8,
    target_dir: []const u8,
    scripts_root: []const u8,
    script_entries: []const ScriptEntry,
) !usize {
    // Build everything into one arena so the discovery + emission
    // ownership story is "free the arena, drop everything". The
    // emitted JSON itself comes back as a heap slice via the
    // top-level `allocator` so we can write it out and free it
    // without ripping the arena out from under in-flight strings.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var groups: std.ArrayList(ModuleGroup) = .empty;

    // ── Engine pass (labelle-engine#578) ────────────────────────
    // The engine declares `pub const Events` for lifecycle hooks
    // (game_init, tick, entity_created, …). Walk the engine's
    // `src/root.zig` the same way the plugin loop walks each plugin
    // so the sidecar has an `engine` palette section alongside
    // `box2d`, `pathfinder`, etc. Unresolvable engine paths (older
    // cached versions without an `Events` decl) silently no-op —
    // back-compat with projects pinned to pre-578 engine releases.
    blk_engine: {
        const engine_dir = cache.resolveFrameworkPackage(
            aa,
            "engine",
            cfg.engine_version,
            project_dir,
        ) catch break :blk_engine;
        const root_path = std.fs.path.join(aa, &.{ engine_dir, "src", "root.zig" }) catch break :blk_engine;
        const io = config.globalIo();
        const src = std.Io.Dir.cwd().readFileAlloc(io, root_path, aa, .limited(8 * 1024 * 1024)) catch break :blk_engine;
        if (try discovery.discoverInSource(aa, src, "engine")) |group| {
            try groups.append(aa, group);
        }
    }

    // ── Plugin pass ─────────────────────────────────────────────
    for (cfg.plugins) |plugin| {
        const plugin_dir = cache.resolvePlugin(aa, plugin, project_dir) catch continue;
        const root_path = try std.fs.path.join(aa, &.{ plugin_dir, "src", "root.zig" });

        const io = config.globalIo();
        const src = std.Io.Dir.cwd().readFileAlloc(io, root_path, aa, .limited(8 * 1024 * 1024)) catch continue;

        const group = try discovery.discoverInSource(aa, src, plugin.name) orelse continue;
        try groups.append(aa, group);
    }

    // ── Game-script pass ────────────────────────────────────────
    // Plugin-shipped scripts (entries with a non-null plugin_name) are
    // skipped here — they're already covered by their containing
    // plugin's `src/root.zig` walk above. Re-walking them as game
    // scripts would emit duplicate entries with mismatched qualified
    // names (the script's rel_path vs. the plugin's name) and confuse
    // the editor's palette.
    for (script_entries) |entry| {
        if (entry.plugin_name != null) continue;
        const script_path = try std.fs.path.join(aa, &.{ scripts_root, entry.rel_path });

        const io = config.globalIo();
        const src = std.Io.Dir.cwd().readFileAlloc(io, script_path, aa, .limited(8 * 1024 * 1024)) catch continue;

        // Game scripts are surfaced under a derived module name. The
        // rel_path (e.g. `flows/hit_counter.zig`) is what `@import`
        // sees; we strip the `.zig` suffix and the path separators get
        // joined with `.` so the editor's palette reads
        // `flows.hit_counter` not `flows/hit_counter`.
        const module_label = try discovery.scriptModuleLabel(aa, entry.rel_path);

        const group = try discovery.discoverInSource(aa, src, module_label) orelse continue;
        try groups.append(aa, group);
    }

    // ── Total node count (return value) ─────────────────────────
    var total: usize = 0;
    for (groups.items) |g| total += g.flow_nodes.len;

    // ── Build the JSON in `allocator` so it survives arena teardown ──
    // `Writer.Allocating.deinit` frees the writer's internal buffer
    // when called (and is a no-op once `toOwnedSlice` has cleared it).
    // We hold one function-wide `errdefer alloc_writer.deinit()` so
    // the writer's growable buffer is freed on every error path —
    // including failures inside `writeCatalogJson` *and* inside
    // `toOwnedSlice` itself (which can fail; it remaps / shrinks the
    // buffer and propagates `Allocator.Error`). The earlier narrower
    // errdefer (scoped inside an inner block over `writeCatalogJson`
    // only) plus an unconditional `deinit` placed *after*
    // `toOwnedSlice` left a leak window — an OOM during the
    // `toOwnedSlice` shrink leaked the writer's buffer. The
    // regression test below pins the new contract.
    var alloc_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer alloc_writer.deinit();
    try json_writer.writeCatalogJson(&alloc_writer.writer, groups.items);
    const json_bytes = try alloc_writer.toOwnedSlice();
    // `toOwnedSlice` cleared the writer's buffer; the outer errdefer
    // is now harmless (deinit early-returns on empty). Free the
    // transferred bytes when we leave the function — `writeSidecar`
    // consumes them via a borrow.
    defer allocator.free(json_bytes);

    // ── Write the sidecar ───────────────────────────────────────
    try json_writer.writeSidecar(target_dir, json_bytes);

    return total;
}

// Re-export the module-level types in case downstream tests want to
// reach them without going through `emitFlowCatalogSidecar`'s public
// surface.
pub const _testing = struct {
    pub const innerCallArg_ = scanners.innerCallArg;
    pub const scanFieldIdent_ = scanners.scanFieldIdent;
    pub const scanFieldStringDup_ = scanners.scanFieldStringDup;
    pub const scanFieldEnumLit_ = scanners.scanFieldEnumLit;
    pub const scanColorTriple_ = scanners.scanColorTriple;
    pub const titlecaseFromIdent_ = scanners.titlecaseFromIdent;
    pub const discoverInSource_ = discovery.discoverInSource;
    pub const writeCatalogJson_ = json_writer.writeCatalogJson;
};

// ─── Tests ──────────────────────────────────────────────────────────────
//
// Tests retain their original location (file split is pure — no
// behavior change) and exercise the public façade for the orchestrator
// + leak-injection tests, plus the re-exported `_testing` aliases for
// the scanner / discovery / json-writer surface.

const innerCallArg = scanners.innerCallArg;
const scanFieldIdent = scanners.scanFieldIdent;
const scanFieldEnumLit = scanners.scanFieldEnumLit;
const scanFieldStringDup = scanners.scanFieldStringDup;
const scanColorTriple = scanners.scanColorTriple;
const titlecaseFromIdent = scanners.titlecaseFromIdent;
const discoverInSource = discovery.discoverInSource;
const writeCatalogJson = json_writer.writeCatalogJson;

test "innerCallArg returns the content between outer parens" {
    try std.testing.expectEqualStrings(".{ .impl = foo }", innerCallArg("Foo(.{ .impl = foo })"));
    try std.testing.expectEqualStrings("no parens at all", innerCallArg("no parens at all"));
}

test "scanFieldIdent: bare identifier RHS" {
    try std.testing.expectEqualStrings("foo", scanFieldIdent(".{ .impl = foo, .docs = \"x\" }", ".impl").?);
    try std.testing.expect(scanFieldIdent(".{ .docs = \"x\" }", ".impl") == null);
}

test "scanFieldIdent: respects token boundaries" {
    // `.imply` should not match `.impl`.
    try std.testing.expect(scanFieldIdent(".{ .imply = 1 }", ".impl") == null);
}

test "scanFieldEnumLit: leading dot is required" {
    try std.testing.expectEqualStrings("command", scanFieldEnumLit(".{ .kind = .command }", ".kind").?);
    // No leading dot → not an enum literal.
    try std.testing.expect(scanFieldEnumLit(".{ .kind = command }", ".kind") == null);
}

test "scanFieldStringDup: standard escape sequences" {
    const aa = std.testing.allocator;
    const a = (try scanFieldStringDup(aa, ".{ .docs = \"hello\\nworld\" }", ".docs")).?;
    defer aa.free(a);
    try std.testing.expectEqualStrings("hello\nworld", a);
}

test "scanColorTriple: parses an explicit Color{} literal" {
    const c = scanColorTriple(".{ .label = \"X\", .color = .{ .r = 12, .g = 34, .b = 56, .a = 255 } }").?;
    try std.testing.expectEqual(@as(u8, 12), c[0]);
    try std.testing.expectEqual(@as(u8, 34), c[1]);
    try std.testing.expectEqual(@as(u8, 56), c[2]);
}

test "titlecaseFromIdent: snake_case to Title Case" {
    const aa = std.testing.allocator;
    const s = try titlecaseFromIdent(aa, "apply_impulse");
    defer aa.free(s);
    try std.testing.expectEqualStrings("Apply Impulse", s);
}

test "discoverInSource: finds box2d-shaped FlowNodes + PinStyles" {
    // A small synthetic source that mimics labelle-box2d's shape.
    // Single FlowNode with an impl in the same source so the pin walk
    // resolves; one PinStyle with a color triple.
    const src =
        \\const flow = @import("flow");
        \\
        \\pub const FlowNodes = struct {
        \\    pub const apply_impulse = flow.FlowNode(.{
        \\        .impl = applyImpulseImpl,
        \\        .docs = "Apply a linear impulse.",
        \\        .pins = .{
        \\            .ix = .{ .label = "Impulse X" },
        \\            .iy = .{ .label = "Impulse Y" },
        \\        },
        \\    });
        \\};
        \\
        \\pub const PinStyles = struct {
        \\    pub const BodyId = flow.PinStyle{
        \\        .label = "Body",
        \\        .color = .{ .r = 80, .g = 200, .b = 200, .a = 255 },
        \\    };
        \\};
        \\
        \\fn applyImpulseImpl(game: anytype, entity: u32, ix: f32, iy: f32) void {
        \\    _ = game; _ = entity; _ = ix; _ = iy;
        \\}
        \\
    ;
    const aa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(aa);
    defer arena.deinit();
    const group = (try discoverInSource(arena.allocator(), src, "box2d")) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqualStrings("box2d", group.name);
    try std.testing.expectEqual(@as(usize, 1), group.flow_nodes.len);
    try std.testing.expectEqualStrings("box2d.apply_impulse", group.flow_nodes[0].qualified);
    try std.testing.expectEqualStrings("Apply Impulse", group.flow_nodes[0].display_name);
    try std.testing.expectEqualStrings("Apply a linear impulse.", group.flow_nodes[0].docs);
    try std.testing.expectEqualStrings("command", group.flow_nodes[0].kind);
    // Pin walk skipped `game: anytype` (first param) and surfaced 3 inputs.
    try std.testing.expectEqual(@as(usize, 3), group.flow_nodes[0].pins.len);
    try std.testing.expectEqualStrings("entity", group.flow_nodes[0].pins[0].name);
    try std.testing.expectEqualStrings("u32", group.flow_nodes[0].pins[0].zig_type);
    // Pin label override picked up from `.pins.ix = .{ .label = "Impulse X" }`.
    try std.testing.expectEqualStrings("ix", group.flow_nodes[0].pins[1].name);
    try std.testing.expectEqualStrings("Impulse X", group.flow_nodes[0].pins[1].label);
    try std.testing.expectEqualStrings("f32", group.flow_nodes[0].pins[1].zig_type);

    try std.testing.expectEqual(@as(usize, 1), group.pin_styles.len);
    try std.testing.expectEqualStrings("BodyId", group.pin_styles[0].zig_type);
    try std.testing.expectEqualStrings("Body", group.pin_styles[0].label);
    try std.testing.expectEqual(@as(u8, 80), group.pin_styles[0].color[0]);
    try std.testing.expectEqual(@as(u8, 200), group.pin_styles[0].color[1]);
    try std.testing.expectEqual(@as(u8, 200), group.pin_styles[0].color[2]);
}

test "discoverInSource: reporter (non-void return) gets an output pin and reporter kind" {
    const src =
        \\const flow = @import("flow");
        \\pub const FlowNodes = struct {
        \\    pub const get_mass = flow.FlowNode(.{
        \\        .impl = getMassImpl,
        \\    });
        \\};
        \\fn getMassImpl(game: anytype, entity: u32) f32 {
        \\    _ = game; _ = entity;
        \\    return 0;
        \\}
        \\
    ;
    const aa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(aa);
    defer arena.deinit();
    const group = (try discoverInSource(arena.allocator(), src, "box2d")).?;
    try std.testing.expectEqualStrings("reporter", group.flow_nodes[0].kind);
    // 1 input (entity) + 1 output (return type).
    try std.testing.expectEqual(@as(usize, 2), group.flow_nodes[0].pins.len);
    try std.testing.expectEqualStrings("input", group.flow_nodes[0].pins[0].dir);
    try std.testing.expectEqualStrings("output", group.flow_nodes[0].pins[1].dir);
    try std.testing.expectEqualStrings("f32", group.flow_nodes[0].pins[1].zig_type);
    try std.testing.expectEqualStrings("f32", group.flow_nodes[0].return_type.?);
}

test "discoverInSource: returns null when neither block is declared" {
    const src =
        \\pub fn helper() void {}
        \\
    ;
    const aa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(aa);
    defer arena.deinit();
    const result = try discoverInSource(arena.allocator(), src, "noop");
    try std.testing.expect(result == null);
}

test "discoverInSource: folds Coercions block into catalog with from/to types" {
    // RFC-FLOW-VOCABULARY §2 / O4 — a module-level `pub const
    // Coercions = struct { ... }` produces one `CoercionEntry` per
    // factory call. From/To types resolve through the impl function's
    // single-param + return-type source.
    const src =
        \\const flow = @import("flow");
        \\pub const BodyId = enum(u32) { _ };
        \\
        \\pub const Coercions = struct {
        \\    pub const body_to_entity = flow.Coercion(.{
        \\        .impl = bodyToEntityImpl,
        \\        .docs = "Reinterpret a BodyId as an EntityId.",
        \\    });
        \\};
        \\
        \\fn bodyToEntityImpl(b: BodyId) u32 { return @intFromEnum(b); }
        \\
    ;
    const aa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(aa);
    defer arena.deinit();
    const group = (try discoverInSource(arena.allocator(), src, "box2d")) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqualStrings("box2d", group.name);
    try std.testing.expectEqual(@as(usize, 1), group.coercions.len);
    try std.testing.expectEqualStrings("box2d.body_to_entity", group.coercions[0].qualified);
    try std.testing.expectEqualStrings("body_to_entity", group.coercions[0].name);
    try std.testing.expectEqualStrings("BodyId", group.coercions[0].from_zig_type);
    try std.testing.expectEqualStrings("u32", group.coercions[0].to_zig_type);
    try std.testing.expectEqualStrings("Reinterpret a BodyId as an EntityId.", group.coercions[0].docs);
}

test "discoverInSource: JSON output includes coercions array per module" {
    // Pin that the sidecar JSON carries a `coercions: [...]` field
    // alongside `events: [...]` for each module group, even when the
    // module declares no coercions. flow-codegen / editor parse
    // assuming both keys are present.
    const aa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(aa);
    defer arena.deinit();
    const ag = arena.allocator();

    var groups: std.ArrayList(ModuleGroup) = .empty;
    var coercions: std.ArrayList(CoercionEntry) = .empty;
    try coercions.append(ag, .{
        .qualified = "box2d.body_to_entity",
        .name = "body_to_entity",
        .from_zig_type = "BodyId",
        .to_zig_type = "u32",
        .docs = "doc",
    });
    try groups.append(ag, .{
        .name = "box2d",
        .flow_nodes = &.{},
        .pin_styles = &.{},
        .events = &.{},
        .coercions = try coercions.toOwnedSlice(ag),
    });
    // Empty module — only the default empty `coercions` slice.
    try groups.append(ag, .{
        .name = "empty",
        .flow_nodes = &.{},
        .pin_styles = &.{},
    });

    var aw: std.Io.Writer.Allocating = .init(aa);
    defer aw.deinit();
    try writeCatalogJson(&aw.writer, groups.items);
    const out = aw.writer.buffer[0..aw.writer.end];

    var parsed = try std.json.parseFromSlice(std.json.Value, aa, out, .{});
    defer parsed.deinit();
    const plugins = parsed.value.object.get("plugins").?.array;
    try std.testing.expectEqual(@as(usize, 2), plugins.items.len);
    const box2d = plugins.items[0].object;
    const co_arr = box2d.get("coercions").?.array;
    try std.testing.expectEqual(@as(usize, 1), co_arr.items.len);
    const co0 = co_arr.items[0].object;
    try std.testing.expectEqualStrings("box2d.body_to_entity", co0.get("qualified").?.string);
    try std.testing.expectEqualStrings("BodyId", co0.get("from_zig_type").?.string);
    try std.testing.expectEqualStrings("u32", co0.get("to_zig_type").?.string);
    // Empty module's coercions array is present and empty — keeps the
    // shape uniform for downstream consumers.
    const empty = plugins.items[1].object;
    try std.testing.expect(empty.contains("coercions"));
    try std.testing.expectEqual(@as(usize, 0), empty.get("coercions").?.array.items.len);
}

test "JSON output round-trips through std.json.parse" {
    const aa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(aa);
    defer arena.deinit();
    const ag = arena.allocator();

    var pins: std.ArrayList(PinDetail) = .empty;
    try pins.append(ag, .{ .name = "entity", .label = "Entity", .zig_type = "u32", .dir = "input", .default = null });
    try pins.append(ag, .{ .name = "result", .label = "Result", .zig_type = "f32", .dir = "output", .default = null });

    var nodes: std.ArrayList(FlowNodeEntry) = .empty;
    try nodes.append(ag, .{
        .qualified = "box2d.get_mass",
        .category = "box2d",
        .display_name = "Get Mass",
        .docs = "Read the body's mass (kg).",
        .kind = "reporter",
        .pins = try pins.toOwnedSlice(ag),
        .return_type = "f32",
    });

    var styles: std.ArrayList(PinStyleEntry) = .empty;
    try styles.append(ag, .{ .zig_type = "BodyId", .label = "Body", .color = .{ 80, 200, 200 } });

    var groups: std.ArrayList(ModuleGroup) = .empty;
    try groups.append(ag, .{
        .name = "box2d",
        .flow_nodes = try nodes.toOwnedSlice(ag),
        .pin_styles = try styles.toOwnedSlice(ag),
    });

    var alloc_writer: std.Io.Writer.Allocating = .init(aa);
    defer alloc_writer.deinit();
    try writeCatalogJson(&alloc_writer.writer, groups.items);

    // Borrow the writer's internal buffer; `alloc_writer.deinit()`
    // above frees the storage at end-of-test so we don't need to
    // round-trip through `toArrayList` / `toOwnedSlice`.
    const json_bytes = alloc_writer.writer.buffer[0..alloc_writer.writer.end];

    // Round-trip — assert we get valid JSON back with the expected
    // shape. We only check a few load-bearing fields; the rest is
    // visually verified.
    var parsed = try std.json.parseFromSlice(std.json.Value, aa, json_bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.contains("generated_at"));
    const plugins_arr = root.get("plugins").?.array;
    try std.testing.expectEqual(@as(usize, 1), plugins_arr.items.len);
    const plugin0 = plugins_arr.items[0].object;
    try std.testing.expectEqualStrings("box2d", plugin0.get("name").?.string);
    const flow_nodes_arr = plugin0.get("flow_nodes").?.array;
    try std.testing.expectEqual(@as(usize, 1), flow_nodes_arr.items.len);
    const node0 = flow_nodes_arr.items[0].object;
    try std.testing.expectEqualStrings("box2d.get_mass", node0.get("qualified").?.string);
    try std.testing.expectEqualStrings("reporter", node0.get("kind").?.string);
    try std.testing.expectEqualStrings("f32", node0.get("return_type").?.string);
    const pins_arr = node0.get("pins").?.array;
    try std.testing.expectEqual(@as(usize, 2), pins_arr.items.len);
}

test "emitFlowCatalogSidecar: writes a sidecar that round-trips to a parseable file" {
    const aa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = config.globalIo();
    const target_dir = try tmp.dir.realPathFileAlloc(io, ".", aa);
    defer aa.free(target_dir);

    // Empty cfg, no plugins, no scripts → empty `plugins` array.
    const cfg = ProjectConfig{ .name = "tmp" };
    const total = try emitFlowCatalogSidecar(aa, cfg, target_dir, target_dir, target_dir, &.{});
    try std.testing.expectEqual(@as(usize, 0), total);

    const path = try std.fs.path.join(aa, &.{ target_dir, SIDECAR_FILENAME });
    defer aa.free(path);

    const cwd = std.Io.Dir.cwd();
    const bytes = try cwd.readFileAlloc(io, path, aa, .limited(1 << 20));
    defer aa.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, aa, bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.contains("generated_at"));
    try std.testing.expectEqual(@as(usize, 0), root.get("plugins").?.array.items.len);
}

// ─── Allocator-failure leak regression ─────────────────────────────────
//
// Pre-fix, `emitFlowCatalogSidecar` leaked the
// `std.Io.Writer.Allocating` internal buffer if `toOwnedSlice` itself
// failed: the `errdefer alloc_writer.deinit()` sat inside a narrow
// inner block scoped to the `writeCatalogJson` call, and the
// unconditional `deinit` followed the failure-prone `toOwnedSlice`.
// Wave 4 review (labelle-gui#170 phase 4 follow-up) flagged the
// pattern. The fix promotes the errdefer to function scope so it
// covers `toOwnedSlice` as well.
//
// This test drives `emitFlowCatalogSidecar` through every allocation
// index with a `FailingAllocator` and asserts the bookkeeping
// balances after each forced failure. We can't use
// `std.testing.checkAllAllocationFailures` directly — the underlying
// `std.Io.Writer` translates allocator failures into
// `error.WriteFailed`, which the helper treats as a non-OOM bug and
// aborts on. We tolerate every error the impl propagates
// (OutOfMemory, WriteFailed, …) — only the FailingAllocator's
// freed-vs-allocated tally matters for the leak invariant.

test "emitFlowCatalogSidecar: no allocator leak at any failure point" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = config.globalIo();
    const target_dir_z = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(target_dir_z);
    const target_dir = target_dir_z[0..target_dir_z.len];

    const cfg = ProjectConfig{ .name = "tmp" };

    // Count the success-path allocations.
    const total_allocs = blk: {
        var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        _ = try emitFlowCatalogSidecar(fa.allocator(), cfg, target_dir, target_dir, target_dir, &.{});
        break :blk fa.alloc_index;
    };

    // Force-fail each allocation index in turn and assert the
    // FailingAllocator's freed/allocated tally balances.
    var i: usize = 0;
    while (i < total_allocs) : (i += 1) {
        var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = i });
        _ = emitFlowCatalogSidecar(fa.allocator(), cfg, target_dir, target_dir, target_dir, &.{}) catch {};
        try std.testing.expectEqual(fa.allocated_bytes, fa.freed_bytes);
    }
}

// Ensure submodule tests are discovered even when the public façade
// doesn't transitively reach the submodules through a compiled path
// during `addTest` runs.
test {
    _ = types;
    _ = scanners;
    _ = discovery;
    _ = json_writer;
}
