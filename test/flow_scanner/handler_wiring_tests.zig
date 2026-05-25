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

pub const FlowHandlerWiring = struct {
    test "new-form OnEvent flow is threaded into GameHooks receiver tuple" {
        const allocator = std.testing.allocator;

        // Synthetic entry matching exactly what `flow_scanner` emits
        // for a new-form `OnEvent` flow. Other entries on the same
        // slice (legacy / lifecycle) keep `has_event_handler = false`
        // and must be skipped by the emission.
        const flow_entries: []const generator.script_scanner.ScriptScanner.ScriptEntry = &.{
            // Lifecycle flow — `setup()`-style, no event handler.
            .{
                .name = "tick",
                .filename = "tick.zig",
                .states = &.{},
                .sort_order = null,
                .subdir = null,
                .rel_path = "flows/tick.zig",
                .has_event_handler = false,
            },
            // New-form OnEvent flow — phase 3 codegen emits
            // `pub const FlowEventHandler` for this entry, so phase 4
            // appends it to the GameHooks tuple.
            .{
                .name = "hit_counter",
                .filename = "hit_counter.zig",
                .states = &.{},
                .sort_order = null,
                .subdir = null,
                .rel_path = "flows/hit_counter.zig",
                .has_event_handler = true,
            },
        };

        const cfg: generator.ProjectConfig = .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{
                // Plugin presence is what makes `PluginEvents` non-empty
                // and unlocks the new-form event flow path.
                .{ .name = "box2d", .repo = "" },
            },
        };

        const main_zig = try generator.generateMainZigFromTemplate(
            allocator,
            tiny_template_with_hooks,
            cfg,
            tiny_lifecycle_hooks,
            flow_entries,
            &.{}, // prefab_names
            &.{}, // jsonc_scene_names
            &.{}, // scene_manifests
            &.{}, // component_names
            &.{}, // hook_names — zero engine-side hooks, so the
                  // GameHooks tuple is ONLY the flow handler. This is
                  // the bouncing-ball shape (no hooks/, one flow).
            &.{}, // event_names
            &.{}, // enum_names
            &.{}, // view_names
            &.{}, // gizmo_names
            &.{}, // animation_names
            &.{}, // plugin_events
            &.{}, // plugin_flow_nodes
            &.{}, // plugin_pin_styles
            &.{}, // plugin_coercions
        );
        defer allocator.free(main_zig);

        // Phase 4 contract part 1: `GameHooks = engine.MergeHooks(...)`
        // — NOT `struct {}` — because there IS a receiver in the
        // tuple. The receiver type is the inline `@import` because
        // `AllScripts` is declared after `GameHooks` in the engine
        // template, so we can't borrow the alias.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const GameHooks = engine.MergeHooks(AllHookPayloads, .{") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "*@import(\"scripts/flows/hit_counter.zig\").FlowEventHandler") != null);
        // Lifecycle flow must NOT appear in the tuple — `tick.zig`
        // has no `FlowEventHandler` decl, only an OnCreate-style
        // entrypoint.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "*@import(\"scripts/flows/tick.zig\")") == null);

        // Phase 4 contract part 2: a stable `var <ident>_flow_handler`
        // declaration so `&<ident>_flow_handler` can take a pointer.
        // `pathToIdent` escapes `/` to `_s_` (injective — issue #172),
        // so the binding name is `flows_s_hit_u_counter_flow_handler`.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "var flows_s_hit_u_counter_flow_handler: @import(\"scripts/flows/hit_counter.zig\").FlowEventHandler = .{};") != null);

        // Phase 4 contract part 3: the address of the materialised
        // handler is wired into the merged-hooks receiver tuple. This
        // is what `setHooks` walks to inject `game_ptr` and what
        // `MergeHooks.emit` walks on each dispatch.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "&flows_s_hit_u_counter_flow_handler") != null);

        // Sanity: the emitted Zig parses cleanly — the inline
        // `@import` inside a tuple literal is a common Zig 0.16
        // sharp-edge to keep an eye on.
        const sentinel_src = try allocator.dupeZ(u8, main_zig);
        defer allocator.free(sentinel_src);
        var ast = try std.zig.Ast.parse(allocator, sentinel_src, .zig);
        defer ast.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    }

    test "multiple new-form OnEvent flows preserve scanner-sorted order in the receiver tuple" {
        // RFC-PLUGIN-EVENTS O3: when two flows listen to the same (or
        // different) events, they fire in scanner-sorted order —
        // numeric-prefix first, alphabetical fallback. `flow_scanner`
        // already sorts entries this way before handing them to
        // `generateMainZigFromTemplate`, so phase 4's job is to
        // preserve that order through to the emitted tuple. This
        // test pins the order through the codegen layer.
        const allocator = std.testing.allocator;

        // Scanner-sort order would put `01_first` before `02_second`,
        // and both before unprefixed `apple`. Feed them to the emitter
        // in that order and assert the receiver tuple reads the same
        // way.
        const flow_entries: []const generator.script_scanner.ScriptScanner.ScriptEntry = &.{
            .{ .name = "01_first", .filename = "01_first.zig", .states = &.{}, .sort_order = 1, .subdir = null, .rel_path = "flows/01_first.zig", .has_event_handler = true },
            .{ .name = "02_second", .filename = "02_second.zig", .states = &.{}, .sort_order = 2, .subdir = null, .rel_path = "flows/02_second.zig", .has_event_handler = true },
            .{ .name = "apple", .filename = "apple.zig", .states = &.{}, .sort_order = null, .subdir = null, .rel_path = "flows/apple.zig", .has_event_handler = true },
        };

        const cfg: generator.ProjectConfig = .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{ .{ .name = "box2d", .repo = "" } },
        };

        const main_zig = try generator.generateMainZigFromTemplate(
            allocator,
            tiny_template_with_hooks,
            cfg,
            tiny_lifecycle_hooks,
            flow_entries,
            &.{},
            &.{},
            &.{},
            &.{},
            &.{},
            &.{},
            &.{},
            &.{},
            &.{},
            &.{},
            &[_]generator.main_zig.PluginEvent{}, // plugin_events
            &[_]generator.main_zig.PluginFlowNode{}, // plugin_flow_nodes
            &[_]generator.main_zig.PluginPinStyle{}, // plugin_pin_styles
            &[_]generator.main_zig.PluginCoercion{}, // plugin_coercions
        );
        defer allocator.free(main_zig);

        // The receiver tuple is a single bracketed list; find each
        // entry's offset and assert they appear in scanner order. The
        // exact `&<ident>_flow_handler` form is what `setHooks` /
        // `MergeHooks.emit` walks at runtime.
        const idx_01 = std.mem.indexOf(u8, main_zig, "&flows_s_01_u_first_flow_handler").?;
        const idx_02 = std.mem.indexOf(u8, main_zig, "&flows_s_02_u_second_flow_handler").?;
        const idx_apple = std.mem.indexOf(u8, main_zig, "&flows_s_apple_flow_handler").?;
        try std.testing.expect(idx_01 < idx_02);
        try std.testing.expect(idx_02 < idx_apple);
    }

    test "consumable-event priority front-loads flows ahead of the scanner-sorted tail" {
        // RFC-PLUGIN-EVENTS O4 / phase 7 (labelle-core#16). A flow that
        // listens to a consumable event sets `priority` in its
        // `.flow.jsonc`; `flow_scanner` lifts that onto
        // `ScriptEntry.event_priority`, and the assembler sorts
        // priority-set flows ahead of the scanner-sorted tail, priority
        // descending. The runtime `MergeHooks.emit` then iterates the
        // tuple in declaration order and breaks on the first handler
        // that returns `true` — so the highest-priority consumer wins.
        //
        // This test pins the order through the codegen layer: feed three
        // flows in scanner order with mixed priorities, assert the
        // emitted receiver tuple front-loads them by priority (desc)
        // and leaves the un-priority flow on the tail.
        const allocator = std.testing.allocator;

        // Input is in scanner-sorted order (`01_low` before `02_high`
        // before unprefixed `notification`). With the phase-7 sort,
        // the priority-set entries float to the front in desc order
        // (high before low), and the no-priority flow sinks to the tail.
        const flow_entries: []const generator.script_scanner.ScriptScanner.ScriptEntry = &.{
            // Low-priority consumable listener — priority 10.
            .{
                .name = "01_low",
                .filename = "01_low.zig",
                .states = &.{},
                .sort_order = 1,
                .subdir = null,
                .rel_path = "flows/01_low.zig",
                .has_event_handler = true,
                .event_priority = 10,
            },
            // High-priority consumable listener — priority 100. Sorts
            // ahead of `01_low` despite the later scanner position.
            .{
                .name = "02_high",
                .filename = "02_high.zig",
                .states = &.{},
                .sort_order = 2,
                .subdir = null,
                .rel_path = "flows/02_high.zig",
                .has_event_handler = true,
                .event_priority = 100,
            },
            // No-priority flow (notification listener, or a consumable
            // listener happy with the default bucket). Stays on the
            // scanner-sorted tail.
            .{
                .name = "notification",
                .filename = "notification.zig",
                .states = &.{},
                .sort_order = null,
                .subdir = null,
                .rel_path = "flows/notification.zig",
                .has_event_handler = true,
                .event_priority = null,
            },
        };

        const cfg: generator.ProjectConfig = .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{.{ .name = "box2d", .repo = "" }},
        };

        const main_zig = try generator.generateMainZigFromTemplate(
            allocator,
            tiny_template_with_hooks,
            cfg,
            tiny_lifecycle_hooks,
            flow_entries,
            &.{},
            &.{},
            &.{},
            &.{},
            &.{},
            &.{},
            &.{},
            &.{},
            &.{},
            &.{},
            &[_]generator.main_zig.PluginEvent{},
            &[_]generator.main_zig.PluginFlowNode{},
            &[_]generator.main_zig.PluginPinStyle{},
            &[_]generator.main_zig.PluginCoercion{}, // plugin_coercions
        );
        defer allocator.free(main_zig);

        const idx_high = std.mem.indexOf(u8, main_zig, "&flows_s_02_u_high_flow_handler").?;
        const idx_low = std.mem.indexOf(u8, main_zig, "&flows_s_01_u_low_flow_handler").?;
        const idx_notif = std.mem.indexOf(u8, main_zig, "&flows_s_notification_flow_handler").?;

        // Priority-descending sort: `02_high` (100) before `01_low` (10).
        try std.testing.expect(idx_high < idx_low);
        // Priority-set flows precede the no-priority tail: both before
        // the notification flow.
        try std.testing.expect(idx_low < idx_notif);

        // Same order in the type-level `MergeHooks(...)` tuple — the
        // receiver-type tuple and the runtime tuple must agree on
        // index-by-index (`MergeHooks.emit` looks each receiver up by
        // tuple position).
        const type_high = std.mem.indexOf(u8, main_zig, "*@import(\"scripts/flows/02_high.zig\").FlowEventHandler").?;
        const type_low = std.mem.indexOf(u8, main_zig, "*@import(\"scripts/flows/01_low.zig\").FlowEventHandler").?;
        const type_notif = std.mem.indexOf(u8, main_zig, "*@import(\"scripts/flows/notification.zig\").FlowEventHandler").?;
        try std.testing.expect(type_high < type_low);
        try std.testing.expect(type_low < type_notif);
    }

    test "ties on priority preserve scanner sort" {
        // Stable-sort semantics: two flows sharing the same priority
        // fall back to their input (scanner-sort) order. Otherwise the
        // emitted tuple would jitter run-to-run, surfacing as flaky
        // ordering-sensitive integration tests.
        const allocator = std.testing.allocator;

        const flow_entries: []const generator.script_scanner.ScriptScanner.ScriptEntry = &.{
            .{
                .name = "01_alpha",
                .filename = "01_alpha.zig",
                .states = &.{},
                .sort_order = 1,
                .subdir = null,
                .rel_path = "flows/01_alpha.zig",
                .has_event_handler = true,
                .event_priority = 50,
            },
            .{
                .name = "02_beta",
                .filename = "02_beta.zig",
                .states = &.{},
                .sort_order = 2,
                .subdir = null,
                .rel_path = "flows/02_beta.zig",
                .has_event_handler = true,
                .event_priority = 50,
            },
        };

        const cfg: generator.ProjectConfig = .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{.{ .name = "box2d", .repo = "" }},
        };

        const main_zig = try generator.generateMainZigFromTemplate(
            allocator,
            tiny_template_with_hooks,
            cfg,
            tiny_lifecycle_hooks,
            flow_entries,
            &.{},
            &.{},
            &.{},
            &.{},
            &.{},
            &.{},
            &.{},
            &.{},
            &.{},
            &.{},
            &[_]generator.main_zig.PluginEvent{},
            &[_]generator.main_zig.PluginFlowNode{},
            &[_]generator.main_zig.PluginPinStyle{},
            &[_]generator.main_zig.PluginCoercion{}, // plugin_coercions
        );
        defer allocator.free(main_zig);

        const idx_alpha = std.mem.indexOf(u8, main_zig, "&flows_s_01_u_alpha_flow_handler").?;
        const idx_beta = std.mem.indexOf(u8, main_zig, "&flows_s_02_u_beta_flow_handler").?;
        try std.testing.expect(idx_alpha < idx_beta);
    }

    test "no new-form OnEvent flows: GameHooks stays struct{} when no hooks/ either" {
        // Regression guard: a project with only lifecycle flows (or
        // legacy `OnEvent` flows) and no hooks/ must keep the v1
        // `const GameHooks = struct {};` shape. Threading a phantom
        // `MergeHooks(...)` here would change the `Game.setHooks`
        // codepath (`HooksIsMerged` branch in `game.zig:412`) for
        // every shipped game that doesn't use new-form events.
        const allocator = std.testing.allocator;

        const flow_entries: []const generator.script_scanner.ScriptScanner.ScriptEntry = &.{
            // Lifecycle flow only — no `FlowEventHandler` to wire.
            .{
                .name = "tick",
                .filename = "tick.zig",
                .states = &.{},
                .sort_order = null,
                .subdir = null,
                .rel_path = "flows/tick.zig",
                .has_event_handler = false,
            },
        };

        const cfg: generator.ProjectConfig = .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        };

        const main_zig = try generator.generateMainZigFromTemplate(
            allocator,
            tiny_template_with_hooks,
            cfg,
            tiny_lifecycle_hooks,
            flow_entries,
            &.{},
            &.{},
            &.{},
            &.{},
            &.{},
            &.{},
            &.{},
            &.{},
            &.{},
            &.{},
            &[_]generator.main_zig.PluginEvent{}, // plugin_events
            &[_]generator.main_zig.PluginFlowNode{}, // plugin_flow_nodes
            &[_]generator.main_zig.PluginPinStyle{}, // plugin_pin_styles
            &[_]generator.main_zig.PluginCoercion{}, // plugin_coercions
        );
        defer allocator.free(main_zig);

        // Empty-hooks shape unchanged.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const GameHooks = struct {};") != null);
        // No `MergeHooks` decl — phase 4 wiring stays out of the way.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "engine.MergeHooks(") == null);
        // `hooks_init` keeps the empty-struct init form.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "var hooks = GameHooks{};") != null);
    }
};
