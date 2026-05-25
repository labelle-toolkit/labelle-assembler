//! Integration tests for `flow_scanner` — the `.flow.jsonc` discovery
//! and codegen pass that Part B of labelle-gui#94 wires into the
//! assembler. Discovery is a recursive `scripts/flows/**` scan
//! (RFC FLOWS-JSONC §5).
//!
//! Layout exercised per test:
//!
//! ```
//! <tmp>/game/scripts/flows/**/<stem>.flow.jsonc ← author-edited source
//! <tmp>/game/.labelle/target/scripts/      ← symlink → ../../scripts
//! <tmp>/game/.labelle/target/scripts/flows/**/<stem>.zig
//! ```
//!
//! Tests run the scanner in-process against a real filesystem (not a
//! subprocess) and assert:
//!   - the emitted `.zig` exists,
//!   - it parses as valid Zig via `std.zig.Ast.parse`,
//!   - the synthetic `ScriptEntry` flows through
//!     `generateMainZigFromTemplate` into the existing AllScripts
//!     block as `@import("scripts/flows/<stem>.zig")`.
//!
//! Deliberately stops short of `zig build`-ing the fixture — that
//! costs seconds per case and the AST parse is the right depth for
//! verifying codegen produces syntactically valid Zig.

const std = @import("std");
const zspec = @import("zspec");
const generator = @import("generator");

const flow_scanner = generator.flow_scanner;
const scanner = generator.scanner;

/// 3-node fixture matching the spec's "GetComponent + BinOp + SetField"
/// recipe. OnCreate (not OnUpdate) keeps it clear of the `// TODO(#42)`
/// stub the codegen emits for OnUpdate entity selection.
///
/// The body is the flow graph as `flow_codegen`'s parser consumes it —
/// `.flow.jsonc` is JSONC (flat nodes, `edges` list) per RFC
/// FLOWS-JSONC. The `.flow.jsonc` extension is what assembler discovery
/// keys on (RFC FLOWS-JSONC §1).
const move_flow_body =
    \\{
    \\  "nodes": [
    \\    { "id": 5, "type": "Event", "name": "engine.entity_created", "pos": [0, -120] },
    \\    { "id": 6, "type": "Identifier", "name": "payload.entity", "pos": [0, -40] },
    \\    { "id": 1, "type": "GetComponent", "pos": [0, 0], "component": "Position" },
    \\    { "id": 2, "type": "Literal", "pos": [0, 0], "value": "1.0" },
    \\    { "id": 3, "type": "BinOp", "pos": [0, 0], "op": "add" },
    \\    { "id": 4, "type": "SetField", "pos": [0, 0], "target": "Position.x" }
    \\  ],
    \\  "edges": [
    \\    { "from": { "node": 6, "pin": "value" }, "to": { "node": 1, "pin": "entity" } },
    \\    { "from": { "node": 6, "pin": "value" }, "to": { "node": 4, "pin": "entity" } },
    \\    { "from": { "node": 1, "pin": "x" }, "to": { "node": 3, "pin": "a" } },
    \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "b" } },
    \\    { "from": { "node": 3, "pin": "result" }, "to": { "node": 4, "pin": "value" } }
    \\  ]
    \\}
    \\
;

fn writeSample(dir: std.Io.Dir, rel: []const u8, content: []const u8) !void {
    const io = std.testing.io;
    if (std.fs.path.dirname(rel)) |parent| try dir.createDirPath(io, parent);
    try dir.writeFile(io, .{ .sub_path = rel, .data = content });
}

/// Build the canonical `<game>/.labelle/target/` shape: a real
/// `scripts/` dir on the game side, a symlinked `scripts/` on the
/// target side. Mirrors what `generate()` lays down by the time
/// `flow_scanner.scanAndEmit` is called.
fn setupFixture(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) !struct { game_dir: []const u8, target_dir: []const u8 } {
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "game/scripts/flows");
    try tmp.dir.createDirPath(io, "game/.labelle/target");

    // realPathFileAlloc returns [:0]u8 — dupe to plain []u8 so the
    // caller can free with the matching size hint (DebugAllocator
    // panics on `[:0]u8`-as-`[]u8` size mismatches).
    const game_dir_z = try tmp.dir.realPathFileAlloc(io, "game", allocator);
    defer allocator.free(game_dir_z);
    const game_dir = try allocator.dupe(u8, game_dir_z);
    const target_dir_z = try tmp.dir.realPathFileAlloc(io, "game/.labelle/target", allocator);
    defer allocator.free(target_dir_z);
    const target_dir = try allocator.dupe(u8, target_dir_z);

    // Plant the .flow.jsonc fixture.
    try writeSample(tmp.dir, "game/scripts/flows/move.flow.jsonc", move_flow_body);

    // Symlink target/scripts → ../../scripts (matches scanner.linkDir).
    try scanner.linkDir(allocator, game_dir, target_dir, "scripts");

    return .{ .game_dir = game_dir, .target_dir = target_dir };
}


// ── Shared between section-split files (was inline between sections in the original) ──

// Minimal stub template wired with just the {{all_scripts_block}}
// expansion — enough to assert the import line emits without dragging
// in every other registry block's contents. Real generates use the
// engine's full main.zig.template (loaded from the engine cache).
const tiny_engine_template =
    \\const std = @import("std");
    \\{{all_scripts_block}}
    \\const Scripts = engine.ScriptRegistry(AllScripts);
    \\{{lifecycle}}
;

const tiny_lifecycle =
    \\pub fn main() !void {}
    \\
;

// ── RFC-PLUGIN-EVENTS phase 1 (labelle-assembler#174) ───────────────────
//
// Verify the assembler's `GameEvents` / `AllHookPayloads` codegen blocks
// folded `PluginEvents` into the same merged payload union. The
// assertions check the *emitted Zig source* — the comptime walk on
// `@hasDecl(plugin, "Events")` only fires when the generated main.zig
// is compiled with a plugin module in scope, which is end-to-end
// covered by `bouncing-ball` building (verified manually). Here we
// pin the codegen shape so a future template churn cannot silently
// drop the discovery scaffolding.

const tiny_template_with_events =
    \\const std = @import("std");
    \\const engine = @import("labelle-engine");
    \\{{game_events_block}}{{all_hook_payloads_block}}{{lifecycle}}
;

const tiny_lifecycle_events =
    \\pub fn main() !void {}
    \\
;


// ── RFC-PLUGIN-EVENTS phase 4 (labelle-assembler#175) ───────────────────
//
// `flow_scanner` flips `ScriptEntry.has_event_handler` on Event-driven
// flows (every flow whose resolved `Flow.event` is `.OnEvent` —
// synthesized by `flow_codegen` from an in-graph `Event` node) so the
// assembler's `game_hooks_block` / `hooks_init_block` emit knows which
// entries own a `pub const FlowEventHandler = struct { ... };` decl
// (flow-codegen `codegen.zig` `renderNewFormEventEntry`). `OnCall`
// subgraph entry points keep the default `false` and stay out of the
// receiver tuple. These tests pin the marker behaviour so phase 4's
// `GameHooks` wiring picks up the right entries.

const new_form_on_event_flow_body =
    \\{
    \\  "name": "hit_counter",
    \\  "nodes": [
    \\    { "id": 99, "type": "Event", "name": "box2d.collision_begin", "pos": [0, 0] },
    \\    { "id": 1, "type": "Literal", "pos": [0, 0], "value": "1.0" },
    \\    { "id": 2, "type": "Output", "pos": [0, 0], "name": "out", "value_type": "f32" }
    \\  ],
    \\  "edges": [
    \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "value" } }
    \\  ]
    \\}
    \\
;

// An `OnCall` subgraph entry — referenced by `Subflow` nodes, not
// dispatched by an event. Its `FlowEventHandler` marker stays `false`
// even after Phase 6 retires lifecycle headers, so it makes a good
// negative case alongside the new-form event flow.
const oncall_subgraph_flow_body =
    \\{
    \\  "name": "compute",
    \\  "event": { "type": "OnCall" },
    \\  "params": [ { "name": "x", "type": "f32" } ],
    \\  "nodes": [
    \\    { "id": 1, "type": "Param", "pos": [0, 0], "param": "x" },
    \\    { "id": 2, "type": "Output", "pos": [0, 0], "name": "out", "value_type": "f32" }
    \\  ],
    \\  "edges": [
    \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "value" } }
    \\  ]
    \\}
    \\
;



// ── RFC-PLUGIN-EVENTS phase 4: `GameHooks` receiver-tuple wiring ────
//
// Verifies the assembler threads flow handler structs through both
// `game_hooks_block` (the type-level tuple in `MergeHooks(...)`) and
// `hooks_init_block` (the runtime `var <ident>_flow_handler` decls +
// `&<ident>_flow_handler` entries in the receivers tuple). The
// engine's `setHooks` walks the latter tuple and injects `*Game`
// into each receiver's `game_ptr` field (`labelle-engine/src/game.zig:419-429`),
// so threading correctly is the contract that makes the runtime
// dispatch fire (the integration test in
// `bouncing-ball/tests/runtime_dispatch_test.zig` exercises that
// end-to-end).

const tiny_template_with_hooks =
    \\const std = @import("std");
    \\const engine = @import("labelle-engine");
    \\{{game_events_block}}{{all_hook_payloads_block}}{{game_hooks_block}}{{all_scripts_block}}const lifecycle_marker = struct {
    \\    pub fn main() !void {
    \\{{hooks_init_block}}
    \\    }
    \\};
    \\{{lifecycle}}
;

const tiny_lifecycle_hooks =
    \\// trailing — body is the embedded `lifecycle_marker.main`.
    \\
;



// ── RFC-FLOW-VOCABULARY phase 2 (labelle-assembler#177) ─────────────────
//
// Verify the assembler's `PluginFlowNodes` / `PluginPinStyles`
// registry codegen — the discovery walk extends the
// `Events`/`Components`/`Systems` convention to `FlowNodes`/`PinStyles`,
// scoped to both plugin modules and game-script modules per RFC §5.
//
// The discovery walk runs against real `.zig` source on disk (same
// as `discoverPluginEvents` for events) — these tests drive it
// with both an in-process `discoverPluginFlowDecls` call against a
// fixture project AND with a pre-built decl slice fed directly to
// `generateMainZigFromTemplate` so codegen-shape regressions and
// discovery-shape regressions surface in distinct test cases.

const PluginFlowNode = generator.main_zig.PluginFlowNode;
const PluginPinStyle = generator.main_zig.PluginPinStyle;
const PluginCoercion = generator.main_zig.PluginCoercion;

const tiny_template_phase2 =
    \\const std = @import("std");
    \\const engine = @import("labelle-engine");
    \\{{game_events_block}}{{lifecycle}}
;

const tiny_lifecycle_phase2 =
    \\pub fn main() !void {}
    \\
;

pub const FlowDeclsDiscovery = struct {
    /// Lay down a fake plugin tree inside the test tmp dir: a
    /// `<plugin_name>/src/root.zig` with the given source body.
    /// Returns the absolute plugin directory path (allocator-owned)
    /// — `discoverPluginFlowDecls` resolves `local:<path>` against
    /// `project_dir` to find the same dir.
    fn writePluginRootZig(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, plugin_name: []const u8, src: []const u8) ![]u8 {
        const io = std.testing.io;
        const src_sub = try std.fmt.allocPrint(allocator, "{s}/src", .{plugin_name});
        defer allocator.free(src_sub);
        try tmp.dir.createDirPath(io, src_sub);

        const root_sub = try std.fmt.allocPrint(allocator, "{s}/src/root.zig", .{plugin_name});
        defer allocator.free(root_sub);
        try tmp.dir.writeFile(io, .{ .sub_path = root_sub, .data = src });

        const plugin_dir_z = try tmp.dir.realPathFileAlloc(io, plugin_name, allocator);
        defer allocator.free(plugin_dir_z);
        return allocator.dupe(u8, plugin_dir_z);
    }

    /// Plant a game-script file at `<scripts_sub>/<rel_path>` inside
    /// the tmp dir. `scripts_sub` is the path of the scripts root
    /// relative to `tmp.dir` (e.g. `game/scripts`).
    fn writeScript(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, scripts_sub: []const u8, rel_path: []const u8, src: []const u8) !void {
        const io = std.testing.io;
        const full_sub = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ scripts_sub, rel_path });
        defer allocator.free(full_sub);
        if (std.fs.path.dirname(full_sub)) |d| try tmp.dir.createDirPath(io, d);
        try tmp.dir.writeFile(io, .{ .sub_path = full_sub, .data = src });
    }

    test "discovers plugin FlowNodes from <plugin>/src/root.zig" {
        const allocator = std.testing.allocator;
        const io = std.testing.io;

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const tmp_path_z = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(tmp_path_z);
        const tmp_path = try allocator.dupe(u8, tmp_path_z);
        defer allocator.free(tmp_path);

        // Synthetic plugin with two FlowNodes. The discovery walk is
        // AST-based — it looks for `pub const FlowNodes = struct { ... }`
        // and folds every `pub const <name>` member. The init RHS shape
        // doesn't matter to the walk; `labelle.FlowNode(...)` is just
        // what the real call would look like.
        const root_src =
            \\const labelle = @import("labelle-core");
            \\
            \\pub const FlowNodes = struct {
            \\    pub const apply_impulse = labelle.FlowNode(.{ .impl = applyImpulseImpl });
            \\    pub const get_velocity = labelle.FlowNode(.{ .impl = getVelocityImpl });
            \\};
            \\
            \\fn applyImpulseImpl(game: anytype, entity: u32) void { _ = game; _ = entity; }
            \\fn getVelocityImpl(game: anytype, entity: u32) f32 { _ = game; _ = entity; return 0.0; }
            \\
        ;
        const plugin_dir = try writePluginRootZig(allocator, &tmp, "fake_box2d", root_src);
        defer allocator.free(plugin_dir);

        // `local:<abs>` resolves via cache.resolvePlugin to the path we
        // just wrote. Same shape `discoverPluginEvents` tolerates.
        const repo = try std.fmt.allocPrint(allocator, "local:{s}", .{plugin_dir});
        defer allocator.free(repo);
        const cfg: generator.ProjectConfig = .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{.{ .name = "fake_box2d", .repo = repo }},
        };

        var decls = try generator.main_zig.discoverPluginFlowDecls(
            allocator,
            cfg,
            tmp_path, // project_dir — `local:` is resolved relative to here
            "/nonexistent/scripts", // scripts_root — no game scripts in this case
            &.{}, // script_entries
        );
        defer decls.deinit();

        // Two FlowNodes discovered, both qualified by the plugin name.
        try std.testing.expectEqual(@as(usize, 2), decls.flow_nodes.len);
        try std.testing.expectEqualStrings("fake_box2d", decls.flow_nodes[0].module_import_path);
        try std.testing.expectEqualStrings("fake_box2d", decls.flow_nodes[0].module_sanitized);
        // The walk preserves declaration order — `apply_impulse` first.
        try std.testing.expectEqualStrings("apply_impulse", decls.flow_nodes[0].node_name);
        try std.testing.expectEqualStrings("get_velocity", decls.flow_nodes[1].node_name);
        // `is_script = false` for plugin entries.
        try std.testing.expect(!decls.flow_nodes[0].is_script);

        // No PinStyles declared — empty list.
        try std.testing.expectEqual(@as(usize, 0), decls.pin_styles.len);
    }

    test "discovers game-script FlowNodes per RFC §5" {
        const allocator = std.testing.allocator;
        const io = std.testing.io;

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try tmp.dir.createDirPath(io, "scripts");
        const tmp_path_z = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(tmp_path_z);
        const tmp_path = try allocator.dupe(u8, tmp_path_z);
        defer allocator.free(tmp_path);
        const scripts_root_z = try tmp.dir.realPathFileAlloc(io, "scripts", allocator);
        defer allocator.free(scripts_root_z);
        const scripts_root = try allocator.dupe(u8, scripts_root_z);
        defer allocator.free(scripts_root);

        // Canonical example from RFC §5 — game script declaring its
        // own FlowNodes block. The discovery walk treats it the same
        // way it treats a plugin module.
        const hits_src =
            \\const labelle = @import("labelle-core");
            \\
            \\var hits: i32 = 0;
            \\
            \\pub const FlowNodes = struct {
            \\    pub const set_hits = labelle.FlowNode(.{ .impl = setTotal });
            \\    pub const get_hits = labelle.FlowNode(.{ .impl = currentTotal });
            \\};
            \\
            \\fn setTotal(game: anytype, n: i32) void { _ = game; hits = n; }
            \\fn currentTotal(game: anytype) i32 { _ = game; return hits; }
            \\
        ;
        try writeScript(allocator, &tmp, "scripts", "hits.zig", hits_src);

        // Game-owned script entry — `plugin_name == null` is the
        // discriminator the discovery walk uses to gate the walk.
        const entries = [_]generator.script_scanner.ScriptScanner.ScriptEntry{
            .{
                .name = "hits",
                .filename = "hits.zig",
                .states = &.{},
                .sort_order = null,
                .subdir = null,
                .rel_path = "hits.zig",
                .plugin_name = null,
            },
        };

        var decls = try generator.main_zig.discoverPluginFlowDecls(
            allocator,
            .{ .name = "test-game", .backend = .raylib, .ecs = .mock },
            tmp_path,
            scripts_root,
            &entries,
        );
        defer decls.deinit();

        try std.testing.expectEqual(@as(usize, 2), decls.flow_nodes.len);
        // Game scripts use the rel_path as the import path; the
        // sanitized form runs through `pathToIdent` (strips `.zig`,
        // escapes `/`, `_`, etc.). For a flat `hits.zig` the result
        // is the bare `hits`.
        try std.testing.expectEqualStrings("hits.zig", decls.flow_nodes[0].module_import_path);
        try std.testing.expectEqualStrings("hits", decls.flow_nodes[0].module_sanitized);
        try std.testing.expectEqualStrings("set_hits", decls.flow_nodes[0].node_name);
        try std.testing.expectEqualStrings("get_hits", decls.flow_nodes[1].node_name);
        try std.testing.expect(decls.flow_nodes[0].is_script);
    }

    test "discovers PinStyles from both plugins and game scripts" {
        const allocator = std.testing.allocator;
        const io = std.testing.io;

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io, "scripts");
        const tmp_path_z = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(tmp_path_z);
        const tmp_path = try allocator.dupe(u8, tmp_path_z);
        defer allocator.free(tmp_path);

        // Plugin contributes PinStyles + FlowNodes both.
        const plugin_src =
            \\const labelle = @import("labelle-core");
            \\
            \\pub const FlowNodes = struct {
            \\    pub const apply_force = labelle.FlowNode(.{ .impl = stub });
            \\};
            \\
            \\pub const PinStyles = struct {
            \\    pub const BodyId = labelle.PinStyle{ .label = "Body" };
            \\};
            \\
            \\fn stub(game: anytype) void { _ = game; }
            \\
        ;
        const plugin_dir = try writePluginRootZig(allocator, &tmp, "fake_phys", plugin_src);
        defer allocator.free(plugin_dir);

        const scripts_root_z = try tmp.dir.realPathFileAlloc(io, "scripts", allocator);
        defer allocator.free(scripts_root_z);
        const scripts_root = try allocator.dupe(u8, scripts_root_z);
        defer allocator.free(scripts_root);

        const widgets_src =
            \\const labelle = @import("labelle-core");
            \\
            \\pub const PinStyles = struct {
            \\    pub const Widget = labelle.PinStyle{ .label = "UI Widget" };
            \\};
            \\
            \\pub const Widget = struct { id: u32 };
            \\
        ;
        try writeScript(allocator, &tmp, "scripts", "ui_widgets.zig", widgets_src);

        const repo = try std.fmt.allocPrint(allocator, "local:{s}", .{plugin_dir});
        defer allocator.free(repo);
        const cfg: generator.ProjectConfig = .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{.{ .name = "fake_phys", .repo = repo }},
        };
        const entries = [_]generator.script_scanner.ScriptScanner.ScriptEntry{
            .{
                .name = "ui_widgets",
                .filename = "ui_widgets.zig",
                .states = &.{},
                .sort_order = null,
                .subdir = null,
                .rel_path = "ui_widgets.zig",
                .plugin_name = null,
            },
        };

        var decls = try generator.main_zig.discoverPluginFlowDecls(
            allocator,
            cfg,
            tmp_path,
            scripts_root,
            &entries,
        );
        defer decls.deinit();

        // The plugin contributed 1 FlowNode + 1 PinStyle, the game
        // script contributed 1 PinStyle. Total: 1 FN, 2 PS.
        try std.testing.expectEqual(@as(usize, 1), decls.flow_nodes.len);
        try std.testing.expectEqualStrings("apply_force", decls.flow_nodes[0].node_name);
        try std.testing.expect(!decls.flow_nodes[0].is_script);

        try std.testing.expectEqual(@as(usize, 2), decls.pin_styles.len);
        // Plugin entry first (plugin pass runs before script pass).
        try std.testing.expectEqualStrings("BodyId", decls.pin_styles[0].type_name);
        try std.testing.expect(!decls.pin_styles[0].is_script);
        // Game-script entry second.
        try std.testing.expectEqualStrings("Widget", decls.pin_styles[1].type_name);
        try std.testing.expect(decls.pin_styles[1].is_script);
    }

    test "empty discovery: no plugins, no scripts declaring FlowNodes — returns empty slices, no error" {
        const allocator = std.testing.allocator;

        // No plugins, no entries — both lists must come back empty
        // without any allocation churn. The empty-case path is what
        // every pre-RFC project hits unchanged.
        var decls = try generator.main_zig.discoverPluginFlowDecls(
            allocator,
            .{ .name = "test-game", .backend = .raylib, .ecs = .mock },
            "/nonexistent/project",
            "/nonexistent/scripts",
            &.{},
        );
        defer decls.deinit();

        try std.testing.expectEqual(@as(usize, 0), decls.flow_nodes.len);
        try std.testing.expectEqual(@as(usize, 0), decls.pin_styles.len);
    }

    test "captures .constructs hint from FlowNode factory call (O5)" {
        // RFC-FLOW-VOCABULARY §1 / O5 — a `FlowNode(.{ ..., .constructs = "..." })`
        // factory call carries an editor hint declaring the Zig type the
        // node returns. The scanner extracts the literal string from the
        // source text and threads it onto `PluginFlowNode.constructs`;
        // an omitted field leaves the value `null`.
        const allocator = std.testing.allocator;
        const io = std.testing.io;

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const tmp_path_z = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(tmp_path_z);
        const tmp_path = try allocator.dupe(u8, tmp_path_z);
        defer allocator.free(tmp_path);

        const root_src =
            \\const labelle = @import("labelle-core");
            \\
            \\pub const FlowNodes = struct {
            \\    pub const ray_cast = labelle.FlowNode(.{
            \\        .impl = rayCastImpl,
            \\        .docs = "Returns a RayResult — wire it into a SetVariable.",
            \\        .constructs = "labelle_box2d.RayResult",
            \\    });
            \\    pub const apply_impulse = labelle.FlowNode(.{
            \\        .impl = applyImpulseImpl,
            \\    });
            \\};
            \\
            \\const RayResult = struct { hit: bool };
            \\fn rayCastImpl(game: anytype, x: f32) RayResult { _ = game; _ = x; return .{ .hit = true }; }
            \\fn applyImpulseImpl(game: anytype, entity: u32) void { _ = game; _ = entity; }
            \\
        ;
        const plugin_dir = try writePluginRootZig(allocator, &tmp, "fake_box2d", root_src);
        defer allocator.free(plugin_dir);

        const repo = try std.fmt.allocPrint(allocator, "local:{s}", .{plugin_dir});
        defer allocator.free(repo);
        const cfg: generator.ProjectConfig = .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{.{ .name = "fake_box2d", .repo = repo }},
        };

        var decls = try generator.main_zig.discoverPluginFlowDecls(
            allocator,
            cfg,
            tmp_path,
            "/nonexistent/scripts",
            &.{},
        );
        defer decls.deinit();

        try std.testing.expectEqual(@as(usize, 2), decls.flow_nodes.len);
        // First entry has `constructs` set — the value matches verbatim.
        try std.testing.expectEqualStrings("ray_cast", decls.flow_nodes[0].node_name);
        try std.testing.expect(decls.flow_nodes[0].constructs != null);
        try std.testing.expectEqualStrings(
            "labelle_box2d.RayResult",
            decls.flow_nodes[0].constructs.?,
        );
        // Second entry has no `.constructs` — value stays `null`.
        try std.testing.expectEqualStrings("apply_impulse", decls.flow_nodes[1].node_name);
        try std.testing.expect(decls.flow_nodes[1].constructs == null);
    }

    test "writePluginFlowNodesBlock surfaces constructs as a doc-comment (O5)" {
        // RFC-FLOW-VOCABULARY §1 / O5 — the emitter writes `/// constructs: <value>`
        // above the alias decl so the generated file is self-documenting.
        // The alias itself carries the value through the FlowNode
        // factory's struct field, so downstream consumers can also read
        // it via reflection; the comment is the human-readable signal.
        const allocator = std.testing.allocator;

        const flow_nodes = [_]PluginFlowNode{
            .{
                .module_import_path = "fake_box2d",
                .module_sanitized = "fake_box2d",
                .node_name = "ray_cast",
                .is_script = false,
                .constructs = "labelle_box2d.RayResult",
            },
            .{
                .module_import_path = "fake_box2d",
                .module_sanitized = "fake_box2d",
                .node_name = "apply_impulse",
                .is_script = false,
                .constructs = null,
            },
        };

        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try generator.main_zig.writePluginFlowNodesBlock(&aw.writer, &flow_nodes);
        const out = aw.written();

        // The constructs hint appears as a doc-comment above ray_cast.
        try std.testing.expect(std.mem.indexOf(u8, out, "/// constructs: labelle_box2d.RayResult") != null);
        // The alias decl follows directly.
        try std.testing.expect(std.mem.indexOf(u8, out, "pub const fake_box2d__ray_cast = @import(\"fake_box2d\").FlowNodes.ray_cast;") != null);
        // The apply_impulse alias has no `/// constructs:` comment.
        const apply_idx = std.mem.indexOf(u8, out, "pub const fake_box2d__apply_impulse").?;
        // Look in the ~64 bytes leading up to the alias — that's the
        // doc-comment slot for the immediately preceding entry.
        const window_start = if (apply_idx > 80) apply_idx - 80 else 0;
        const window = out[window_start..apply_idx];
        try std.testing.expect(std.mem.indexOf(u8, window, "/// constructs:") == null);
    }

    test "skips plugin-shipped scripts (plugin's root.zig already covers them)" {
        // Plugin-shipped scripts (entries with `plugin_name != null`)
        // are skipped by the game-script pass because their plugin
        // already gets walked at its `src/root.zig` root level. Re-
        // walking them as scripts would double-count entries. This
        // test pins the gate at the assembler level: a script entry
        // with `plugin_name` set contributes zero to the discovery
        // result.
        const allocator = std.testing.allocator;
        const io = std.testing.io;

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io, "scripts");
        const tmp_path_z = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(tmp_path_z);
        const tmp_path = try allocator.dupe(u8, tmp_path_z);
        defer allocator.free(tmp_path);

        const scripts_root_z = try tmp.dir.realPathFileAlloc(io, "scripts", allocator);
        defer allocator.free(scripts_root_z);
        const scripts_root = try allocator.dupe(u8, scripts_root_z);
        defer allocator.free(scripts_root);

        // Write a plugin-shipped script that DOES declare FlowNodes.
        // Even though the file exists and parses, the discovery walk
        // skips it because of the `plugin_name != null` gate.
        const ps_src =
            \\const labelle = @import("labelle-core");
            \\pub const FlowNodes = struct {
            \\    pub const should_be_skipped = labelle.FlowNode(.{ .impl = stub });
            \\};
            \\fn stub(game: anytype) void { _ = game; }
            \\
        ;
        try writeScript(allocator, &tmp, "scripts", ".plugin_foo/helper.zig", ps_src);

        const entries = [_]generator.script_scanner.ScriptScanner.ScriptEntry{
            .{
                .name = "helper",
                .filename = "helper.zig",
                .states = &.{},
                .sort_order = null,
                .subdir = null,
                .rel_path = ".plugin_foo/helper.zig",
                // The discriminator — non-null `plugin_name` means
                // "owned by plugin `foo`; skip the script-pass walk".
                .plugin_name = "foo",
            },
        };

        var decls = try generator.main_zig.discoverPluginFlowDecls(
            allocator,
            .{ .name = "test-game", .backend = .raylib, .ecs = .mock },
            tmp_path,
            scripts_root,
            &entries,
        );
        defer decls.deinit();

        // The plugin-shipped script's FlowNode was NOT picked up.
        try std.testing.expectEqual(@as(usize, 0), decls.flow_nodes.len);
    }
};
