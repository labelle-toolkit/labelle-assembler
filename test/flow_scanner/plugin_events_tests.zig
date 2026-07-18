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

pub const PluginEvents = struct {
    test "no plugins, no game events: AllHookPayloads stays the original engine.HookPayload form" {
        const allocator = std.testing.allocator;

        const cfg: generator.ProjectConfig = .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            // No plugins, no events/ scan — the pre-RFC backward-compat
            // shape that every existing game keeps building on.
        };

        const main_zig = try generator.generateMainZigFromTemplate(
            allocator,
            tiny_template_with_events,
            cfg,
            tiny_lifecycle_events,
            &.{},
            &.{}, // prefab_names
            &.{}, // jsonc_scene_names
            &.{}, // scene_manifests
            &.{}, // component_names
            &.{}, // hook_names
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

        // The legacy single-payload form — every shipped game has this
        // exact line today, and our RFC-PLUGIN-EVENTS phase 1 must not
        // touch it when neither game events nor plugins exist.
        try std.testing.expect(std.mem.indexOf(
            u8,
            main_zig,
            "const AllHookPayloads = engine.HookPayload(EcsBackend.Entity);",
        ) != null);
        // `PluginEvents` decl must NOT exist in the no-plugin case.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "PluginEvents") == null);
    }

    test "plugins present: emits a PluginEvents union(enum) literal and merges it into AllHookPayloads" {
        const allocator = std.testing.allocator;

        // Mirrors bouncing-ball's `.plugins = .{.{ .name = \"box2d\" }}`:
        // a single plugin with an identifier-safe name. The discovery
        // walk runs at assembler time (against `<plugin>/src/root.zig`),
        // but here we drive the codegen directly with a pre-built
        // `plugin_events` slice so the test doesn't depend on a real
        // checkout on disk.
        const cfg: generator.ProjectConfig = .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{
                .{ .name = "box2d", .repo = "local:../labelle-box2d" },
            },
        };

        const pe = [_]generator.main_zig.PluginEvent{
            .{ .plugin_import_name = "box2d", .plugin_sanitized = "box2d", .event_name = "collision_begin" },
        };

        const main_zig = try generator.generateMainZigFromTemplate(
            allocator,
            tiny_template_with_events,
            cfg,
            tiny_lifecycle_events,
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
            &.{},
            &pe, // plugin_events
            &.{}, // plugin_flow_nodes
            &.{}, // plugin_pin_styles
            &.{}, // plugin_coercions
        );
        defer allocator.free(main_zig);

        // PluginEvents decl is emitted as a `pub const union(enum)`
        // literal — no `@Union` builtin (its zero-field result is
        // uninstantiable, see writePluginEventsBlock for context).
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const PluginEvents = union(enum) {") != null);
        // Plugin-qualified variant tag — `<plugin>__<event>` — uses `__`
        // as the separator because `.` is not a valid Zig identifier
        // character. The codegen writes the field out directly.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "box2d__collision_begin") != null);
        // The plugin module is imported by its project.labelle name —
        // the exact same `@import(\"box2d\")` form `SystemRegistry`
        // and `ComponentRegistryWithPlugins` already use.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@import(\"box2d\")") != null);
        // Merged into the SAME AllHookPayloads — no parallel dispatcher.
        // RFC-PLUGIN-EVENTS phase 3: when plugins declare events,
        // `GameEvents` widens to fold in `PluginEvents` (via the
        // assembler-emitted `MergeHookPayloads(.{ GameEventsRaw,
        // PluginEvents })`), so `AllHookPayloads` only references the
        // widened `GameEvents`. Without any events/*.zig scan,
        // `GameEvents = PluginEvents` directly (skipping the merge).
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const GameEvents = PluginEvents;") != null);
        try std.testing.expect(std.mem.indexOf(
            u8,
            main_zig,
            "AllHookPayloads = engine.core.MergeHookPayloads(.{ engine.HookPayload(EcsBackend.Entity), GameEvents })",
        ) != null);

        // Validate the emitted Zig parses cleanly — a literal
        // `union(enum)` with the wrong field syntax would silently
        // round-trip past the indexOf checks above.
        const sentinel_src = try allocator.dupeZ(u8, main_zig);
        defer allocator.free(sentinel_src);
        var ast = try std.zig.Ast.parse(allocator, sentinel_src, .zig);
        defer ast.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    }

    test "plugin name with dashes is sanitized to a Zig-identifier-safe prefix" {
        const allocator = std.testing.allocator;

        // A hyphenated name (`labelle-imgui`) is a plausible
        // project.labelle entry; the variant tag `<plugin>__<event>`
        // must collapse `-` to `_` so it parses as a Zig identifier.
        const cfg: generator.ProjectConfig = .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{
                .{ .name = "labelle-imgui", .repo = "" },
            },
        };

        const pe = [_]generator.main_zig.PluginEvent{
            .{ .plugin_import_name = "labelle-imgui", .plugin_sanitized = "labelle_imgui", .event_name = "frame_start" },
        };

        const main_zig = try generator.generateMainZigFromTemplate(
            allocator,
            tiny_template_with_events,
            cfg,
            tiny_lifecycle_events,
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
            &.{},
            &pe, // plugin_events
            &.{}, // plugin_flow_nodes
            &.{}, // plugin_pin_styles
            &.{}, // plugin_coercions
        );
        defer allocator.free(main_zig);

        // The sanitized identifier is used as the variant tag prefix
        // (`<plugin_sanitized>__<event>`); the original name is what
        // `@import(...)` resolves against.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "labelle_imgui__frame_start") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@import(\"labelle-imgui\")") != null);
    }

    test "GameEvents widens to fold PluginEvents into the same AllHookPayloads merge" {
        const allocator = std.testing.allocator;

        const cfg: generator.ProjectConfig = .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{
                .{ .name = "box2d", .repo = "" },
            },
        };

        const pe = [_]generator.main_zig.PluginEvent{
            .{ .plugin_import_name = "box2d", .plugin_sanitized = "box2d", .event_name = "collision_begin" },
        };

        const main_zig = try generator.generateMainZigFromTemplate(
            allocator,
            tiny_template_with_events,
            cfg,
            tiny_lifecycle_events,
            &.{},
            &.{},
            &.{},
            &.{},
            &.{},
            &.{},
            &.{"player_attacked"}, // event_names — one game event
            &.{},
            &.{},
            &.{},
            &.{},
            &pe, // plugin_events
            &.{}, // plugin_flow_nodes
            &.{}, // plugin_pin_styles
            &.{}, // plugin_coercions
        );
        defer allocator.free(main_zig);

        // RFC-PLUGIN-EVENTS phase 3: when both game events AND plugins
        // are present, the assembler emits `GameEventsRaw` (the
        // events/*.zig scan) + `PluginEvents` (the plugin walk) and
        // **widens** `GameEvents` to fold both into a single merged
        // union via `MergeHookPayloads`. The engine main template's
        // `GameConfig(..., GameEvents)` slot lands on the merged type
        // unchanged (no template rename), so `game.emit(...)` accepts
        // both flavours.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const GameEventsRaw = union(enum)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const PluginEvents = union(enum)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const GameEvents = engine.core.MergeHookPayloads(.{ GameEventsRaw, PluginEvents })") != null);

        // `AllHookPayloads` only references the widened `GameEvents`
        // (not `PluginEvents` again) — referencing both would re-emit
        // every plugin variant twice and trip `MergeHookPayloads`'
        // duplicate-field check.
        const merge_str = "engine.core.MergeHookPayloads(.{ engine.HookPayload(EcsBackend.Entity), GameEvents })";
        try std.testing.expect(std.mem.indexOf(u8, main_zig, merge_str) != null);
    }

    test "every plugin event elided (#630): v1 shape kept, elision comments emitted, no PluginEvents decl" {
        const allocator = std.testing.allocator;

        const cfg: generator.ProjectConfig = .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{
                .{ .name = "box2d", .repo = "" },
            },
        };

        // The consumption filter partitioned the whole discovery list
        // into `elided` — the codegen sees an EMPTY consumed list plus
        // the elided remainder through the scoped threadlocal (the same
        // wiring `root.zig` uses).
        const elided = [_]generator.main_zig.PluginEvent{
            .{ .plugin_import_name = "box2d", .plugin_sanitized = "box2d", .event_name = "collision_begin" },
        };
        defer generator.main_zig.main_template.plugin_events_elided = &.{};
        generator.main_zig.main_template.plugin_events_elided = &elided;

        const main_zig = try generator.generateMainZigFromTemplate(
            allocator,
            tiny_template_with_events,
            cfg,
            tiny_lifecycle_events,
            &.{},
            &.{},
            &.{},
            &.{},
            &.{},
            &.{},
            &.{}, // event_names — no game events either
            &.{},
            &.{},
            &.{},
            &.{},
            &.{}, // plugin_events — everything was filtered out
            &.{}, // plugin_flow_nodes
            &.{}, // plugin_pin_styles
            &.{}, // plugin_coercions
        );
        defer allocator.free(main_zig);

        // The v1 no-plugin-events shape: `GameEvents = void` (the
        // engine's `has_events` gate elides the event buffer), the
        // legacy single-payload `AllHookPayloads`, and NO `PluginEvents`
        // decl anywhere.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const GameEvents = void;") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const AllHookPayloads = engine.HookPayload(EcsBackend.Entity);") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const PluginEvents") == null);
        // …but the generated file still explains where the variant went.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "// elided (no consumer): box2d__collision_begin") != null);
    }
};
