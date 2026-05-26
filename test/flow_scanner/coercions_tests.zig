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

/// Build a minimal `Codegen` context whose only populated slice is
/// `plugin_coercions`. Mirrors the production orchestrator path
/// `main_template.zig` takes — `writePluginCoercionsBlock` only reads
/// `self.plugin_coercions`, so the rest stay empty.
fn coercionsCtx(allocator: std.mem.Allocator, coercions: []const PluginCoercion) generator.main_zig.Codegen {
    return .{
        .allocator = allocator,
        .cfg = .{ .name = "test-game", .ecs = .mock },
        .script_entries = &.{},
        .prefab_names = &.{},
        .jsonc_scene_names = &.{},
        .scene_manifests = &.{},
        .component_names = &.{},
        .hook_names = &.{},
        .event_names = &.{},
        .enum_names = &.{},
        .view_names = &.{},
        .gizmo_names = &.{},
        .animation_names = &.{},
        .plugin_events = &.{},
        .plugin_flow_nodes = &.{},
        .plugin_pin_styles = &.{},
        .plugin_coercions = coercions,
    };
}

const tiny_template_phase2 =
    \\const std = @import("std");
    \\const engine = @import("labelle-engine");
    \\{{game_events_block}}{{lifecycle}}
;

const tiny_lifecycle_phase2 =
    \\pub fn main() !void {}
    \\
;

pub const PluginCoercionsDiscovery = struct {
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

    test "discovers plugin Coercions from <plugin>/src/root.zig" {
        const allocator = std.testing.allocator;
        const io = std.testing.io;

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const tmp_path_z = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(tmp_path_z);
        const tmp_path = try allocator.dupe(u8, tmp_path_z);
        defer allocator.free(tmp_path);

        // Synthetic plugin declaring two coercions. The AST walk just
        // looks for `pub const Coercions = struct { ... }` and folds
        // every `pub const <name>` member; the init RHS shape isn't
        // inspected at discovery time (the From/To types resolve later
        // through Zig's comptime reflection on the emitted alias).
        const root_src =
            \\const labelle = @import("labelle-core");
            \\
            \\pub const BodyId = enum(u32) { _ };
            \\
            \\pub const Coercions = struct {
            \\    pub const body_to_entity = labelle.flow.Coercion(.{ .impl = bodyToEntity });
            \\    pub const int_to_float = labelle.flow.Coercion(.{ .impl = intToFloat });
            \\};
            \\
            \\fn bodyToEntity(b: BodyId) u32 { return @intFromEnum(b); }
            \\fn intToFloat(x: i32) f64 { return @floatFromInt(x); }
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

        try std.testing.expectEqual(@as(usize, 2), decls.coercions.len);
        try std.testing.expectEqualStrings("fake_box2d", decls.coercions[0].module_import_path);
        try std.testing.expectEqualStrings("fake_box2d", decls.coercions[0].module_sanitized);
        // Walk preserves declaration order.
        try std.testing.expectEqualStrings("body_to_entity", decls.coercions[0].name);
        try std.testing.expectEqualStrings("int_to_float", decls.coercions[1].name);
        try std.testing.expect(!decls.coercions[0].is_script);

        // FlowNodes / PinStyles slots are empty when the module only
        // declares Coercions — verify the three lists are independent.
        try std.testing.expectEqual(@as(usize, 0), decls.flow_nodes.len);
        try std.testing.expectEqual(@as(usize, 0), decls.pin_styles.len);
    }

    test "Coercions plugin entry emits the @import alias + From/To/convert reflect" {
        // writePluginCoercionsBlock's emission shape is:
        //   pub const <plugin>__<name> = @import("<plugin>").Coercions.<name>;
        // plus the `resolve` + `findByTypes` helpers. This test pins the
        // alias line and helper bodies' source shape.
        const allocator = std.testing.allocator;

        const coercions = [_]PluginCoercion{
            .{
                .module_import_path = "box2d",
                .module_sanitized = "box2d",
                .name = "body_to_entity",
                .is_script = false,
            },
        };

        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var ctx = coercionsCtx(allocator, &coercions);
        try ctx.writePluginCoercionsBlock(&aw.writer);
        const out = aw.writer.buffer[0..aw.writer.end];

        // The alias resolves against the source-module's `Coercions`
        // namespace so the comptime decls (`From`, `To`, `convert`)
        // pass through unchanged.
        try std.testing.expect(std.mem.indexOf(u8, out, "pub const box2d__body_to_entity = @import(\"box2d\").Coercions.body_to_entity;") != null);
        // resolve() and findByTypes() helpers — flow-codegen calls
        // findByTypes during edge codegen.
        try std.testing.expect(std.mem.indexOf(u8, out, "pub fn resolve(comptime dotted: []const u8) ?[]const u8") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "pub fn findByTypes(comptime From: type, comptime To: type) ?[]const u8") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "__is_labelle_coercion") != null);
    }

    test "Coercions: empty discovery emits the shell with stub helpers" {
        // Every project, even ones declaring no Coercions, gets a
        // `pub const PluginCoercions = struct { ... };` shell with the
        // resolve + findByTypes helpers. flow-codegen always calls them
        // — the empty case returns `null` and the wire-fit falls back
        // to the built-in rules without a separate branch.
        const allocator = std.testing.allocator;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var ctx = coercionsCtx(allocator, &.{});
        try ctx.writePluginCoercionsBlock(&aw.writer);
        const out = aw.writer.buffer[0..aw.writer.end];
        try std.testing.expect(std.mem.indexOf(u8, out, "pub const PluginCoercions = struct {") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "pub fn resolve(comptime dotted: []const u8) ?[]const u8") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "pub fn findByTypes(comptime From: type, comptime To: type) ?[]const u8") != null);
        // No alias lines in the empty case.
        try std.testing.expect(std.mem.indexOf(u8, out, "= @import(") == null);
    }

    test "Coercions: game-script module emits @import(\"scripts/<rel>\") form" {
        // Same per-source-kind branching as FlowNodes / PinStyles —
        // a game-script declaring `pub const Coercions` resolves
        // through `@import("scripts/<rel_path>")`.
        const allocator = std.testing.allocator;

        const coercions = [_]PluginCoercion{
            .{
                .module_import_path = "flows/bridges.zig",
                .module_sanitized = "flows_s_bridges",
                .name = "to_entity",
                .is_script = true,
            },
        };

        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var ctx = coercionsCtx(allocator, &coercions);
        try ctx.writePluginCoercionsBlock(&aw.writer);
        const out = aw.writer.buffer[0..aw.writer.end];

        try std.testing.expect(std.mem.indexOf(u8, out, "pub const flows_s_bridges__to_entity = @import(\"scripts/flows/bridges.zig\").Coercions.to_entity;") != null);
    }
};
