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

pub const PluginFlowNodesAndPinStyles = struct {
    test "no FlowNodes / no PinStyles: empty PluginFlowNodes / PluginPinStyles struct{}" {
        // Back-compat path: a game with no plugin contributing FlowNodes
        // and no game scripts declaring them gets empty shells. The
        // editor and flow-codegen reflect on `@typeInfo(PluginFlowNodes)`
        // uniformly, so an empty struct{} keeps a single code path
        // downstream instead of a special-case branch.
        const allocator = std.testing.allocator;

        const main_zig = try generator.generateMainZigFromTemplate(
            allocator,
            tiny_template_phase2,
            .{ .name = "test-game", .backend = .raylib, .ecs = .mock, .y_axis = .up },
            tiny_lifecycle_phase2,
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
            &[_]generator.main_zig.PluginEvent{}, // plugin_events
            &[_]PluginFlowNode{}, // plugin_flow_nodes
            &[_]PluginPinStyle{}, // plugin_pin_styles
            &[_]PluginCoercion{}, // plugin_coercions
        );
        defer allocator.free(main_zig);

        // Both registries are always emitted — uniform reflection
        // surface even when discovery found zero entries.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const PluginFlowNodes = struct {") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const PluginPinStyles = struct {") != null);

        // No qualified entries — empty discovery means an empty body
        // (modulo the unconditional `resolve` helper on PluginFlowNodes).
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "__") == null or
            // The "__" might appear inside the docstring `<plugin>__<event>`
            // — the only deterministic check is that no `FlowNodes.` /
            // `PinStyles.` decl-rhs aliases got written.
            std.mem.indexOf(u8, main_zig, ".FlowNodes.") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".PinStyles.") == null);

        // `resolve` is emitted unconditionally so callers don't need to
        // gate on registry size before calling the resolver.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub fn resolve(") != null);

        // Emitted Zig parses cleanly.
        const sentinel_src = try allocator.dupeZ(u8, main_zig);
        defer allocator.free(sentinel_src);
        var ast = try std.zig.Ast.parse(allocator, sentinel_src, .zig);
        defer ast.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    }

    test "plugin FlowNodes: emits qualified <plugin>__<name> entries aliased to source decls" {
        // Mirrors RFC §1 + ticket §2: each discovered FlowNode entry
        // is `pub const <plugin>__<name> = @import("<plugin>").FlowNodes.<name>;`
        // — the alias carries the FlowNode-factory return value
        // (display_name, category, docs, kind, pins) and the `impl`
        // comptime decl through to downstream reflection.
        const allocator = std.testing.allocator;

        const flow_nodes = [_]PluginFlowNode{
            .{
                .module_import_path = "box2d",
                .module_sanitized = "box2d",
                .node_name = "apply_impulse",
                .is_script = false,
            },
            .{
                .module_import_path = "box2d",
                .module_sanitized = "box2d",
                .node_name = "get_velocity",
                .is_script = false,
            },
        };

        const main_zig = try generator.generateMainZigFromTemplate(
            allocator,
            tiny_template_phase2,
            .{ .name = "test-game", .backend = .raylib, .ecs = .mock, .y_axis = .up },
            tiny_lifecycle_phase2,
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
            &[_]generator.main_zig.PluginEvent{},
            &flow_nodes,
            &[_]PluginPinStyle{},
            &[_]PluginCoercion{}, // plugin_coercions
        );
        defer allocator.free(main_zig);

        // Plugin-qualified naming convention matches the
        // RFC-PLUGIN-EVENTS shape: `<plugin>__<name>`.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const box2d__apply_impulse = @import(\"box2d\").FlowNodes.apply_impulse;") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const box2d__get_velocity = @import(\"box2d\").FlowNodes.get_velocity;") != null);

        // The emitted Zig must parse cleanly — a typo in the decl
        // shape would silently round-trip past the indexOf checks.
        const sentinel_src = try allocator.dupeZ(u8, main_zig);
        defer allocator.free(sentinel_src);
        var ast = try std.zig.Ast.parse(allocator, sentinel_src, .zig);
        defer ast.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    }

    test "game-script FlowNodes: resolve through named module @import(\"script__<sanitized>\") (#240 Gap 2)" {
        // RFC §5: any module under the project tree exporting
        // `FlowNodes` is a palette source — not just plugins. Game
        // scripts use the `@import("scripts/<rel_path>")` form, same
        // as the existing `all_scripts_block`. The sanitized identifier
        // for `hits.zig` is `hits` (no escapes); for `flows/hit_counter.zig`
        // the `/` collapses to `_s_` via `pathToIdent`.
        const allocator = std.testing.allocator;

        const flow_nodes = [_]PluginFlowNode{
            .{
                .module_import_path = "hits.zig",
                .module_sanitized = "hits",
                .node_name = "set_hits",
                .is_script = true,
            },
            .{
                .module_import_path = "hits.zig",
                .module_sanitized = "hits",
                .node_name = "get_hits",
                .is_script = true,
            },
        };

        const main_zig = try generator.generateMainZigFromTemplate(
            allocator,
            tiny_template_phase2,
            .{ .name = "test-game", .backend = .raylib, .ecs = .mock, .y_axis = .up },
            tiny_lifecycle_phase2,
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
            &[_]generator.main_zig.PluginEvent{},
            &flow_nodes,
            &[_]PluginPinStyle{},
            &[_]PluginCoercion{}, // plugin_coercions
        );
        defer allocator.free(main_zig);

        // Game-script aliases use the NAMED module
        // `@import("script__<module_sanitized>")` (labelle-assembler#240
        // Gap 2) — NOT a path `@import("scripts/<rel>")`, which would put
        // the script file in both the root and `game` modules. The
        // `script__` prefix + sanitized name match the build.zig wiring
        // (`scan.promotedScriptModuleName`).
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const hits__set_hits = @import(\"script__hits\").FlowNodes.set_hits;") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const hits__get_hits = @import(\"script__hits\").FlowNodes.get_hits;") != null);
        // No path import of the script from the FlowNodes block.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@import(\"scripts/hits.zig\").FlowNodes") == null);
    }

    test "PinStyles: deduped last-write-wins, keyed by type name" {
        // Per RFC §1, "later declarations win for any duplicate type
        // key". The assembler dedupes upstream of the emitter so the
        // generated registry has at most one entry per type name.
        const allocator = std.testing.allocator;

        const pin_styles = [_]PluginPinStyle{
            // First declaration of BodyId — gets overridden.
            .{
                .module_import_path = "box2d",
                .module_sanitized = "box2d",
                .type_name = "BodyId",
                .is_script = false,
            },
            // PluginA's JointId — kept.
            .{
                .module_import_path = "box2d",
                .module_sanitized = "box2d",
                .type_name = "JointId",
                .is_script = false,
            },
            // Second BodyId — this is the one that survives dedupe.
            .{
                .module_import_path = "physics2",
                .module_sanitized = "physics2",
                .type_name = "BodyId",
                .is_script = false,
            },
        };

        const main_zig = try generator.generateMainZigFromTemplate(
            allocator,
            tiny_template_phase2,
            .{ .name = "test-game", .backend = .raylib, .ecs = .mock, .y_axis = .up },
            tiny_lifecycle_phase2,
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
            &[_]generator.main_zig.PluginEvent{},
            &[_]PluginFlowNode{},
            &pin_styles,
            &[_]PluginCoercion{},
        );
        defer allocator.free(main_zig);

        // JointId from box2d survives (no conflict).
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const JointId = @import(\"box2d\").PinStyles.JointId;") != null);
        // BodyId is the LATER physics2 declaration — last-write-wins.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const BodyId = @import(\"physics2\").PinStyles.BodyId;") != null);
        // The earlier box2d.BodyId did NOT survive dedupe — Zig would
        // reject the duplicate `pub const` if it had.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@import(\"box2d\").PinStyles.BodyId") == null);

        // Parse-check — duplicate decls would surface here.
        const sentinel_src = try allocator.dupeZ(u8, main_zig);
        defer allocator.free(sentinel_src);
        var ast = try std.zig.Ast.parse(allocator, sentinel_src, .zig);
        defer ast.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    }

    test "PinStyles: game-script module emits @import(\"scripts/<rel>\") form" {
        // Same per-source-kind import shape as FlowNodes — a game
        // script declaring `pub const PinStyles = struct { ... }` is
        // referenced through `@import("scripts/<rel_path>")`.
        const allocator = std.testing.allocator;

        const pin_styles = [_]PluginPinStyle{
            .{
                .module_import_path = "ui_types.zig",
                .module_sanitized = "ui_u_types",
                .type_name = "Widget",
                .is_script = true,
            },
        };

        const main_zig = try generator.generateMainZigFromTemplate(
            allocator,
            tiny_template_phase2,
            .{ .name = "test-game", .backend = .raylib, .ecs = .mock, .y_axis = .up },
            tiny_lifecycle_phase2,
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
            &[_]generator.main_zig.PluginEvent{},
            &[_]PluginFlowNode{},
            &pin_styles,
            &[_]PluginCoercion{},
        );
        defer allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const Widget = @import(\"scripts/ui_types.zig\").PinStyles.Widget;") != null);
    }

    test "resolve(): name resolver maps dotted form to qualified ident" {
        // Ticket §3: flow-codegen's eventual `CustomNode` lowering
        // calls `PluginFlowNodes.resolve("box2d.apply_impulse")` and
        // expects the canonical qualified field name back. The
        // generator emits the resolver as a comptime function on
        // `PluginFlowNodes`, so we verify its source shape here.
        const allocator = std.testing.allocator;

        const flow_nodes = [_]PluginFlowNode{
            .{
                .module_import_path = "box2d",
                .module_sanitized = "box2d",
                .node_name = "apply_impulse",
                .is_script = false,
            },
        };

        const main_zig = try generator.generateMainZigFromTemplate(
            allocator,
            tiny_template_phase2,
            .{ .name = "test-game", .backend = .raylib, .ecs = .mock, .y_axis = .up },
            tiny_lifecycle_phase2,
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
            &[_]generator.main_zig.PluginEvent{},
            &flow_nodes,
            &[_]PluginPinStyle{},
            &[_]PluginCoercion{}, // plugin_coercions
        );
        defer allocator.free(main_zig);

        // Resolver source — comptime; pure string ops over the dotted
        // form. Body shape pinned because flow-codegen's phase-3
        // `CustomNode` lowering depends on the contract.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub fn resolve(comptime dotted: []const u8) ?[]const u8") != null);
        // Splits on `.`, joins on `__` — same convention `PluginEvents`
        // uses for its event-name lookup. The module half passes through
        // `sanitizeModuleIdent` so digit-leading plugin names line up
        // with the `_`-prefixed decl shape (labelle-assembler#212).
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "std.mem.indexOfScalar(u8, dotted, '.')") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "sanitizeModuleIdent(module) ++ \"__\" ++ node") != null);
        // Membership check via @hasDecl on the enclosing struct —
        // `@field(PluginFlowNodes, resolved)` then reaches the entry
        // value.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@hasDecl(@This(), qualified)") != null);
    }

    test "resolve(): digit-prefixed plugin name sanitises module half to match decl emit (#212)" {
        // Regression for labelle-assembler#212: a plugin whose name
        // starts with a digit (e.g. `3d_test`) has its decl-side ident
        // prefixed with `_` by `sanitizePluginIdent` so the emitted
        // `pub const _3d_test__foo` is valid Zig. Pre-fix the
        // resolver body computed `qualified = module ++ "__" ++ node`
        // straight from the user-supplied dotted name, which would
        // miss the `_` prefix and silently return `null` for every
        // dotted reference into a digit-leading plugin.
        //
        // The fix mirrors `sanitizePluginIdent`'s digit-prefix +
        // non-identifier collapse in the generated `sanitizeModuleIdent`
        // helper. This test pins:
        //   1. The decl name keeps its `_3d_test__…` shape (unchanged).
        //   2. The resolver dispatches through `sanitizeModuleIdent`
        //      so the qualified ident it builds also picks up the `_`.
        const allocator = std.testing.allocator;

        const flow_nodes = [_]PluginFlowNode{
            .{
                .module_import_path = "3d_test",
                .module_sanitized = "_3d_test",
                .node_name = "render",
                .is_script = false,
            },
        };

        const main_zig = try generator.generateMainZigFromTemplate(
            allocator,
            tiny_template_phase2,
            .{ .name = "test-game", .backend = .raylib, .ecs = .mock, .y_axis = .up },
            tiny_lifecycle_phase2,
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
            &[_]generator.main_zig.PluginEvent{},
            &flow_nodes,
            &[_]PluginPinStyle{},
            &[_]PluginCoercion{},
        );
        defer allocator.free(main_zig);

        // Decl side: name carries the leading `_` per `sanitizePluginIdent`.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const _3d_test__render = @import(\"3d_test\").FlowNodes.render;") != null);

        // Resolver side: the body must funnel `module` through the
        // sanitizer before joining — otherwise `resolve(\"3d_test.render\")`
        // computes `3d_test__render` and misses the decl.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "sanitizeModuleIdent(module) ++ \"__\" ++ node") != null);
        // The sanitizer itself must be emitted: comptime body that
        // prefixes a `_` when the first byte is a digit.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "fn sanitizeModuleIdent(comptime name: []const u8) []const u8") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "name[0] >= '0' and name[0] <= '9'") != null);

        // Emitted Zig parses cleanly — guards against a typo in the
        // comptime helper that would silently round-trip the indexOf
        // checks above.
        const sentinel_src = try allocator.dupeZ(u8, main_zig);
        defer allocator.free(sentinel_src);
        var ast = try std.zig.Ast.parse(allocator, sentinel_src, .zig);
        defer ast.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    }

    test "FlowNodes + PinStyles: both blocks emit together in the same generated file" {
        // Integration: verify a project that contributes both
        // FlowNodes AND PinStyles gets both registries emitted in the
        // expected shape, neither silently dropped.
        const allocator = std.testing.allocator;

        const flow_nodes = [_]PluginFlowNode{
            .{
                .module_import_path = "box2d",
                .module_sanitized = "box2d",
                .node_name = "set_velocity",
                .is_script = false,
            },
        };
        const pin_styles = [_]PluginPinStyle{
            .{
                .module_import_path = "box2d",
                .module_sanitized = "box2d",
                .type_name = "BodyId",
                .is_script = false,
            },
        };

        const main_zig = try generator.generateMainZigFromTemplate(
            allocator,
            tiny_template_phase2,
            .{ .name = "test-game", .backend = .raylib, .ecs = .mock, .y_axis = .up },
            tiny_lifecycle_phase2,
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
            &[_]generator.main_zig.PluginEvent{},
            &flow_nodes,
            &pin_styles,
            &[_]PluginCoercion{},
        );
        defer allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const box2d__set_velocity = @import(\"box2d\").FlowNodes.set_velocity;") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const BodyId = @import(\"box2d\").PinStyles.BodyId;") != null);

        // Order pin — FlowNodes block precedes PinStyles block so the
        // generated source has a stable read order (both end up under
        // the same `{{game_events_block}}` scalar).
        const idx_flow = std.mem.indexOf(u8, main_zig, "pub const PluginFlowNodes = struct {").?;
        const idx_pin = std.mem.indexOf(u8, main_zig, "pub const PluginPinStyles = struct {").?;
        try std.testing.expect(idx_flow < idx_pin);
    }
};
