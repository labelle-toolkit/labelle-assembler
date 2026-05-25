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

pub const AllScriptsIntegration = struct {
    test "flow ScriptEntry renders as @import(\"scripts/flows/<stem>.zig\") in AllScripts" {
        const allocator = std.testing.allocator;

        // The exact shape `flow_scanner.scanAndEmit` produces — keep
        // these in sync if the synthetic entry's fields ever change.
        const flow_entry: generator.script_scanner.ScriptScanner.ScriptEntry = .{
            .name = "move",
            .filename = "move.zig",
            .states = &.{},
            .sort_order = null,
            .subdir = null,
            .rel_path = "flows/move.zig",
            .plugin_name = null,
            .plugin_index = 0,
        };
        const entries: []const generator.script_scanner.ScriptScanner.ScriptEntry = &.{flow_entry};

        const empty_names: []const []const u8 = &.{};
        const empty_scene_manifests: []const generator.scene_manifest.SceneManifest = &.{};

        const main_zig = try generator.generateMainZigFromTemplate(
            allocator,
            tiny_engine_template,
            .{ .name = "test-game", .backend = .raylib, .ecs = .mock },
            tiny_lifecycle,
            entries,
            empty_names, // prefab_names
            empty_names, // jsonc_scene_names
            empty_scene_manifests,
            empty_names, // component_names
            empty_names, // hook_names
            empty_names, // event_names
            empty_names, // enum_names
            empty_names, // view_names
            empty_names, // gizmo_names
            empty_names, // animation_names
            &[_]generator.main_zig.PluginEvent{}, // plugin_events
            &[_]generator.main_zig.PluginFlowNode{}, // plugin_flow_nodes
            &[_]generator.main_zig.PluginPinStyle{}, // plugin_pin_styles
            &[_]generator.main_zig.PluginCoercion{}, // plugin_coercions
        );
        defer allocator.free(main_zig);

        // Byte-for-byte match with the existing AllScripts import
        // shape used for hand-authored scripts. If this drifts the
        // generated build won't find the file at `scripts/flows/...`.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@import(\"scripts/flows/move.zig\")") != null);
        // pathToIdent escapes `/` to `_s_` (injective — see issue #172),
        // so the binding name is `flows_s_move`.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const flows_s_move =") != null);
    }

    test "nested flow ScriptEntry renders its subdirectory in the AllScripts @import path" {
        const allocator = std.testing.allocator;

        // Recursive discovery (RFC FLOWS-JSONC §5) emits `rel_path`
        // values with subdirectories — `flows/enemy/patrol.zig` for a
        // flow at `scripts/flows/enemy/patrol.flow.jsonc`. The AllScripts
        // emit must carry that subdir through verbatim in the `@import`
        // so the generated build resolves the mirrored on-disk layout.
        const flow_entry: generator.script_scanner.ScriptScanner.ScriptEntry = .{
            .name = "patrol",
            .filename = "enemy/patrol.zig",
            .states = &.{},
            .sort_order = null,
            .subdir = null,
            .rel_path = "flows/enemy/patrol.zig",
            .plugin_name = null,
            .plugin_index = 0,
        };
        const entries: []const generator.script_scanner.ScriptScanner.ScriptEntry = &.{flow_entry};

        const empty_names: []const []const u8 = &.{};
        const empty_scene_manifests: []const generator.scene_manifest.SceneManifest = &.{};

        const main_zig = try generator.generateMainZigFromTemplate(
            allocator,
            tiny_engine_template,
            .{ .name = "test-game", .backend = .raylib, .ecs = .mock },
            tiny_lifecycle,
            entries,
            empty_names, // prefab_names
            empty_names, // jsonc_scene_names
            empty_scene_manifests,
            empty_names, // component_names
            empty_names, // hook_names
            empty_names, // event_names
            empty_names, // enum_names
            empty_names, // view_names
            empty_names, // gizmo_names
            empty_names, // animation_names
            &[_]generator.main_zig.PluginEvent{}, // plugin_events
            &[_]generator.main_zig.PluginFlowNode{}, // plugin_flow_nodes
            &[_]generator.main_zig.PluginPinStyle{}, // plugin_pin_styles
            &[_]generator.main_zig.PluginCoercion{}, // plugin_coercions
        );
        defer allocator.free(main_zig);

        // The subdirectory survives into the import path verbatim — a
        // flat `flows/patrol.zig` would silently resolve to the wrong
        // file (or fail the build).
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@import(\"scripts/flows/enemy/patrol.zig\")") != null);
        // pathToIdent escapes each `/` to `_s_` (injective — see issue
        // #172), so the nested path binds as `flows_s_enemy_s_patrol`.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const flows_s_enemy_s_patrol =") != null);

        // The emitted block must still parse as valid Zig — the nested
        // import line is the only moving part versus the flat case.
        const sentinel_src = try allocator.dupeZ(u8, main_zig);
        defer allocator.free(sentinel_src);
        var ast = try std.zig.Ast.parse(allocator, sentinel_src, .zig);
        defer ast.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    }
};

pub const GameModuleBinding = struct {
    test "generateBuildZig declares a game_mod from a local game.zig and wires it into the exe imports" {
        const allocator = std.testing.allocator;

        const cfg: generator.ProjectConfig = .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        };

        const build_zig = try generator.generateBuildZig(allocator, cfg, .{});
        defer allocator.free(build_zig);

        // Module declaration: rooted at `game.zig`, with `labelle-engine`
        // in its import table so `@import("labelle-engine")` resolves
        // inside the shim.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "const game_mod = b.createModule(.{") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, ".root_source_file = b.path(\"game.zig\")") != null);

        // Imports on the exe root_module: `"game"` keyed at `game_mod`.
        // String-matching on the literal pair is the contract the
        // codegen relies on — `@import("game")` won't resolve without
        // this exact wiring.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, ".{ .name = \"game\", .module = game_mod }") != null);

        // Test step must also import `"game"` so test files (and
        // flow-derived `.zig` files reached via the AllScripts wrapper)
        // see the same module.
        const test_step_idx = std.mem.indexOf(u8, build_zig, "addTest(").?;
        const game_in_tests = std.mem.indexOfPos(u8, build_zig, test_step_idx, ".{ .name = \"game\", .module = game_mod }");
        try std.testing.expect(game_in_tests != null);
    }

    test "game.zig shim re-exports Game and EntityId from labelle-engine" {
        const allocator = std.testing.allocator;
        // No plugins (or no plugin events) → empty list.
        const empty_pe: []const generator.main_zig.PluginEvent = &.{};
        const src = try generator.generateGameShim(allocator, empty_pe);
        defer allocator.free(src);

        // `@import("game")` users expect both decls at the root.
        try std.testing.expect(std.mem.indexOf(u8, src, "pub const Game") != null);
        try std.testing.expect(std.mem.indexOf(u8, src, "pub const EntityId") != null);

        // The shim must source those decls from labelle-engine — the
        // codegen-emitted flow files assume `Game` / `EntityId` have
        // the engine's hook semantics.
        try std.testing.expect(std.mem.indexOf(u8, src, "@import(\"labelle-engine\")") != null);

        // No plugin events → no `PluginEvents` block. The shim stays a tiny
        // re-export of `Game`/`EntityId`; only projects with events to
        // resolve (phase 3) get the union.
        try std.testing.expect(std.mem.indexOf(u8, src, "PluginEvents") == null);
    }

    test "game.zig shim re-exports PluginEvents when plugins are declared" {
        // RFC-PLUGIN-EVENTS phase 3 shim caveat: new-form `OnEvent`
        // flow handlers reflect against `@FieldType(game.PluginEvents,
        // "<tag>")`, so the `game.zig` shim must expose the union next
        // to `Game`/`EntityId`. The shim emission is now driven by the
        // pre-discovered event list — same shape `writePluginEventsBlock`
        // writes into `main.zig`.
        const allocator = std.testing.allocator;
        const pe = [_]generator.main_zig.PluginEvent{
            .{
                .plugin_import_name = "box2d",
                .plugin_sanitized = "box2d",
                .event_name = "collision_begin",
            },
        };
        const src = try generator.generateGameShim(allocator, &pe);
        defer allocator.free(src);

        // The static prelude still re-exports the engine types verbatim.
        try std.testing.expect(std.mem.indexOf(u8, src, "pub const Game") != null);
        try std.testing.expect(std.mem.indexOf(u8, src, "pub const EntityId") != null);

        // The plugin-events block — shape-pinned by the same union the
        // assembler emits into `main.zig`. flow-codegen's resolver
        // reflects on this union, so the shim must spell `pub const
        // PluginEvents` and import the plugin module by its declared
        // name.
        try std.testing.expect(std.mem.indexOf(u8, src, "pub const PluginEvents = union(enum) {") != null);
        try std.testing.expect(std.mem.indexOf(u8, src, "@import(\"box2d\")") != null);
        // Qualified-tag mapping is mechanical: `<plugin>.<event>` →
        // `<plugin>__<event>`. The shim builds the tag the same way
        // `main.zig` does, so the resolver consumes a single canonical
        // form.
        try std.testing.expect(std.mem.indexOf(u8, src, "box2d__collision_begin") != null);
    }
};
