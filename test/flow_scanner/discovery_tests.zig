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

pub const FlowScanner = struct {
    test "emits a .zig per .flow.jsonc and the generated source parses as valid Zig" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const fx = try setupFixture(allocator, &tmp);
        defer allocator.free(fx.game_dir);
        defer allocator.free(fx.target_dir);

        var result = try flow_scanner.scanAndEmit(allocator, fx.game_dir, fx.target_dir, &.{});
        defer result.deinit();

        // One source → one entry → one emitted file.
        try std.testing.expectEqual(@as(usize, 1), result.entries.len);
        try std.testing.expectEqualStrings("move", result.entries[0].name);
        try std.testing.expectEqualStrings("flows/move.zig", result.entries[0].rel_path);
        try std.testing.expectEqual(@as(usize, 0), result.entries[0].states.len);

        // The emitted file lives at `<target>/scripts/flows/move.zig`,
        // which through the symlink is `<game>/scripts/flows/move.zig`.
        // Reading via the target path proves the symlink resolution
        // matches the assembler's runtime view.
        const out_path = try std.fs.path.join(allocator, &.{ fx.target_dir, "scripts", "flows", "move.zig" });
        defer allocator.free(out_path);

        const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, out_path, allocator, .limited(64 * 1024));
        defer allocator.free(source);

        // Smoke-check the prelude — confirms codegen used the
        // documented `@import("game")` shape rather than something
        // bespoke we'd have to special-case in main.zig wiring.
        try std.testing.expect(std.mem.indexOf(u8, source, "@import(\"game\")") != null);
        // Post Phase 6 (RFC-FLOW-VOCABULARY): the move fixture is an
        // Event-node-form flow (Event node listening to
        // `engine.entity_created`), so codegen emits a
        // `FlowEventHandler` struct with an `engine__entity_created`
        // dispatch method rather than the legacy lifecycle entry.
        try std.testing.expect(std.mem.indexOf(u8, source, "pub const FlowEventHandler = struct") != null);
        try std.testing.expect(std.mem.indexOf(u8, source, "pub fn engine__entity_created") != null);

        // `std.zig.Ast.parse` requires a sentinel-terminated slice
        // — copy onto a [:0]u8 so the parser's tokenizer is happy.
        const sentinel_src = try allocator.dupeZ(u8, source);
        defer allocator.free(sentinel_src);
        var ast = try std.zig.Ast.parse(allocator, sentinel_src, .zig);
        defer ast.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    }

    test "missing scripts/flows/ directory is a silent no-op" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        // Build the target shell but leave `scripts/flows/` absent —
        // the common case for any project that doesn't use the editor.
        const io = std.testing.io;
        try tmp.dir.createDirPath(io, "game/scripts");
        try tmp.dir.createDirPath(io, "game/.labelle/target");
        const game_dir_z = try tmp.dir.realPathFileAlloc(io, "game", allocator);
        defer allocator.free(game_dir_z);
        const game_dir = try allocator.dupe(u8, game_dir_z);
        defer allocator.free(game_dir);
        const target_dir_z = try tmp.dir.realPathFileAlloc(io, "game/.labelle/target", allocator);
        defer allocator.free(target_dir_z);
        const target_dir = try allocator.dupe(u8, target_dir_z);
        defer allocator.free(target_dir);
        try scanner.linkDir(allocator, game_dir, target_dir, "scripts");

        var result = try flow_scanner.scanAndEmit(allocator, game_dir, target_dir, &.{});
        defer result.deinit();

        try std.testing.expectEqual(@as(usize, 0), result.entries.len);
    }

    test "parse error in a flow surfaces with the file name and a typed error" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const io = std.testing.io;
        try tmp.dir.createDirPath(io, "game/scripts/flows");
        try tmp.dir.createDirPath(io, "game/.labelle/target");
        const game_dir_z = try tmp.dir.realPathFileAlloc(io, "game", allocator);
        defer allocator.free(game_dir_z);
        const game_dir = try allocator.dupe(u8, game_dir_z);
        defer allocator.free(game_dir);
        const target_dir_z = try tmp.dir.realPathFileAlloc(io, "game/.labelle/target", allocator);
        defer allocator.free(target_dir_z);
        const target_dir = try allocator.dupe(u8, target_dir_z);
        defer allocator.free(target_dir);
        try scanner.linkDir(allocator, game_dir, target_dir, "scripts");

        // Two nodes with the same `id` — caught by `parseFlow` as
        // `error.DuplicateNodeId`. Confirms scanner propagates typed
        // errors rather than swallowing them.
        const bad =
            \\{
            \\  "nodes": [
            \\    { "id": 99, "type": "Event", "name": "engine.entity_created", "pos": [0, 0] },
            \\    { "id": 1, "type": "Identifier", "pos": [0, 0], "name": "a" },
            \\    { "id": 1, "type": "Identifier", "pos": [0, 0], "name": "b" }
            \\  ],
            \\  "edges": []
            \\}
            \\
        ;
        try writeSample(tmp.dir, "game/scripts/flows/bad.flow.jsonc", bad);

        const result = flow_scanner.scanAndEmit(allocator, game_dir, target_dir, &.{});
        try std.testing.expectError(error.DuplicateNodeId, result);
    }

    test "recursively discovers .flow.jsonc files in scripts/flows/ subdirectories" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const fx = try setupFixture(allocator, &tmp);
        defer allocator.free(fx.game_dir);
        defer allocator.free(fx.target_dir);

        // A second flow nested one directory deep — RFC FLOWS-JSONC §5
        // makes flow discovery a recursive `scripts/flows/**` scan, so
        // this must be picked up alongside the flat `move` flow.
        try writeSample(tmp.dir, "game/scripts/flows/enemy/patrol.flow.jsonc", move_flow_body);

        var result = try flow_scanner.scanAndEmit(allocator, fx.game_dir, fx.target_dir, &.{});
        defer result.deinit();

        // Two sources → two entries. Sorted by relative path:
        // `enemy/patrol.flow.jsonc` < `move.flow.jsonc`.
        try std.testing.expectEqual(@as(usize, 2), result.entries.len);
        try std.testing.expectEqualStrings("patrol", result.entries[0].name);
        // The emitted `.zig` mirrors the source's subdirectory layout
        // so two flows sharing a stem in different dirs never collide.
        try std.testing.expectEqualStrings("flows/enemy/patrol.zig", result.entries[0].rel_path);
        try std.testing.expectEqualStrings("move", result.entries[1].name);
        try std.testing.expectEqualStrings("flows/move.zig", result.entries[1].rel_path);

        // The nested emission lands at the mirrored target path.
        const out_path = try std.fs.path.join(allocator, &.{ fx.target_dir, "scripts", "flows", "enemy", "patrol.zig" });
        defer allocator.free(out_path);
        const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, out_path, allocator, .limited(64 * 1024));
        defer allocator.free(source);
        // Post Phase 6 (RFC-FLOW-VOCABULARY): the fixture flow is
        // Event-node-form, so codegen emits a `FlowEventHandler` rather
        // than a lifecycle entry function.
        try std.testing.expect(std.mem.indexOf(u8, source, "pub const FlowEventHandler = struct") != null);
    }

    test "ignores non-.flow.jsonc files in scripts/flows/" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const fx = try setupFixture(allocator, &tmp);
        defer allocator.free(fx.game_dir);
        defer allocator.free(fx.target_dir);

        // Stray files that aren't `*.flow.jsonc` — a legacy `.flow.zon`
        // and a plain `.jsonc` — must not be picked up by discovery.
        try writeSample(tmp.dir, "game/scripts/flows/legacy.flow.zon", move_flow_body);
        try writeSample(tmp.dir, "game/scripts/flows/notes.jsonc", "{}\n");

        var result = try flow_scanner.scanAndEmit(allocator, fx.game_dir, fx.target_dir, &.{});
        defer result.deinit();

        // Only `move.flow.jsonc` is a flow source.
        try std.testing.expectEqual(@as(usize, 1), result.entries.len);
        try std.testing.expectEqualStrings("move", result.entries[0].name);
    }
};

pub const FlowSortOrder = struct {
    test "numeric-prefixed flows extract their sort_order from the basename" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const fx = try setupFixture(allocator, &tmp);
        defer allocator.free(fx.game_dir);
        defer allocator.free(fx.target_dir);

        // Stem `01_input` carries a numeric prefix; scanner must lift
        // it to `sort_order = 1` (parity with `01_input.zig` scripts).
        try writeSample(tmp.dir, "game/scripts/flows/01_input.flow.jsonc", move_flow_body);

        var result = try flow_scanner.scanAndEmit(allocator, fx.game_dir, fx.target_dir, &.{});
        defer result.deinit();

        // Two entries — the `move.flow.jsonc` from setupFixture plus our
        // new `01_input.flow.jsonc`. The numbered one sorts first.
        try std.testing.expectEqual(@as(usize, 2), result.entries.len);
        try std.testing.expectEqualStrings("01_input", result.entries[0].name);
        try std.testing.expectEqual(@as(?u32, 1), result.entries[0].sort_order);
        try std.testing.expectEqualStrings("move", result.entries[1].name);
        try std.testing.expectEqual(@as(?u32, null), result.entries[1].sort_order);
    }

    test "numeric-prefixed flows sort numerically (2 before 10), not alphabetically" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const io = std.testing.io;
        try tmp.dir.createDirPath(io, "game/scripts/flows");
        try tmp.dir.createDirPath(io, "game/.labelle/target");
        const game_dir_z = try tmp.dir.realPathFileAlloc(io, "game", allocator);
        defer allocator.free(game_dir_z);
        const game_dir = try allocator.dupe(u8, game_dir_z);
        defer allocator.free(game_dir);
        const target_dir_z = try tmp.dir.realPathFileAlloc(io, "game/.labelle/target", allocator);
        defer allocator.free(target_dir_z);
        const target_dir = try allocator.dupe(u8, target_dir_z);
        defer allocator.free(target_dir);
        try scanner.linkDir(allocator, game_dir, target_dir, "scripts");

        // The exact failure mode the old `.sort_order = null` code
        // shipped: `10_late` would sort *before* `2_early` because
        // `'1' < '2'` in raw string order. The numeric sort_order fix
        // makes `2` come first.
        try writeSample(tmp.dir, "game/scripts/flows/10_late.flow.jsonc", move_flow_body);
        try writeSample(tmp.dir, "game/scripts/flows/2_early.flow.jsonc", move_flow_body);

        var result = try flow_scanner.scanAndEmit(allocator, game_dir, target_dir, &.{});
        defer result.deinit();

        try std.testing.expectEqual(@as(usize, 2), result.entries.len);
        try std.testing.expectEqualStrings("2_early", result.entries[0].name);
        try std.testing.expectEqual(@as(?u32, 2), result.entries[0].sort_order);
        try std.testing.expectEqualStrings("10_late", result.entries[1].name);
        try std.testing.expectEqual(@as(?u32, 10), result.entries[1].sort_order);
    }

    test "unprefixed flows keep sort_order=null and sort after numbered flows alphabetically" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const io = std.testing.io;
        try tmp.dir.createDirPath(io, "game/scripts/flows");
        try tmp.dir.createDirPath(io, "game/.labelle/target");
        const game_dir_z = try tmp.dir.realPathFileAlloc(io, "game", allocator);
        defer allocator.free(game_dir_z);
        const game_dir = try allocator.dupe(u8, game_dir_z);
        defer allocator.free(game_dir);
        const target_dir_z = try tmp.dir.realPathFileAlloc(io, "game/.labelle/target", allocator);
        defer allocator.free(target_dir_z);
        const target_dir = try allocator.dupe(u8, target_dir_z);
        defer allocator.free(target_dir);
        try scanner.linkDir(allocator, game_dir, target_dir, "scripts");

        // Mix numbered + unnumbered: numbered sort first, unnumbered
        // alphabetically after. Mirrors the script scanner's per-scope
        // sort policy (`script_scanner.zig:489-504`).
        try writeSample(tmp.dir, "game/scripts/flows/zebra.flow.jsonc", move_flow_body);
        try writeSample(tmp.dir, "game/scripts/flows/01_first.flow.jsonc", move_flow_body);
        try writeSample(tmp.dir, "game/scripts/flows/apple.flow.jsonc", move_flow_body);

        var result = try flow_scanner.scanAndEmit(allocator, game_dir, target_dir, &.{});
        defer result.deinit();

        try std.testing.expectEqual(@as(usize, 3), result.entries.len);
        try std.testing.expectEqualStrings("01_first", result.entries[0].name);
        try std.testing.expectEqual(@as(?u32, 1), result.entries[0].sort_order);
        try std.testing.expectEqualStrings("apple", result.entries[1].name);
        try std.testing.expectEqual(@as(?u32, null), result.entries[1].sort_order);
        try std.testing.expectEqualStrings("zebra", result.entries[2].name);
        try std.testing.expectEqual(@as(?u32, null), result.entries[2].sort_order);
    }
};

// ── RFC-FLOW-VOCABULARY §1 — CustomNode lowering (labelle-assembler#238) ──
//
// The assembler must thread a `CustomNodeRegistry` into flow codegen so
// `.flow.jsonc` `CustomNode` references resolve to the qualified
// `game_mod.PluginFlowNodes.<module>__<node>` decls the
// `PluginFlowNodes` block emits. Before #238 `scanAndEmit` always passed
// a `null` registry, so *any* `CustomNode` failed with
// `error.UnknownFlowNode` — the bug was latent only because no in-tree
// flow referenced a CustomNode.
//
// These tests drive the full assembler path: discover a game-script
// `FlowNodes` block (which computes the `is_void` command-vs-reporter
// flag), feed the discovered node list into `scanAndEmit`, and assert the
// generated `.zig` lowers the CustomNode to the right call shape — a bare
// statement for a `void` command, a `const n<id>_value = ...` binding for
// a value-returning reporter (RFC §6).

// A game-script module declaring two FlowNodes: a `void`-returning
// command (`log_i32`) and an `i32`-returning reporter (`read_count`).
// The discovery walk resolves each impl's return type to set `is_void`,
// which is exactly what decides the lowering shape below.
const log_script_src =
    \\const labelle = @import("labelle-core");
    \\
    \\var counter: i32 = 0;
    \\
    \\pub const FlowNodes = struct {
    \\    pub const log_i32 = labelle.FlowNode(.{ .impl = logI32 });
    \\    pub const read_count = labelle.FlowNode(.{ .impl = readCount });
    \\};
    \\
    \\fn logI32(game: anytype, value: i32) void { _ = game; counter += value; }
    \\fn readCount(game: anytype) i32 { _ = game; return counter; }
    \\
;

// An `OnCall` subgraph that feeds a Literal into the `log_i32` command's
// first positional pin (`arg0`). The command returns `void`, so codegen
// must emit a bare `@TypeOf(game_mod.PluginFlowNodes.log__log_i32).impl(game, ...)`
// statement.
const command_customnode_flow =
    \\{
    \\  "name": "do_log",
    \\  "event": { "type": "OnCall" },
    \\  "nodes": [
    \\    { "id": 1, "type": "Literal", "pos": [0, 0], "value": "7" },
    \\    { "id": 2, "type": "CustomNode", "pos": [120, 0], "name": "log.log_i32" }
    \\  ],
    \\  "edges": [
    \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "arg0" } }
    \\  ]
    \\}
    \\
;

// An `OnCall` subgraph that reads the reporter (`read_count`) and routes
// its value to an `Output`. The reporter is non-void, so codegen must
// bind the result to `const n<id>_value = game_mod.PluginFlowNodes.
// log__read_count.impl(game)`.
const reporter_customnode_flow =
    \\{
    \\  "name": "read",
    \\  "event": { "type": "OnCall" },
    \\  "nodes": [
    \\    { "id": 1, "type": "CustomNode", "pos": [0, 0], "name": "log.read_count" },
    \\    { "id": 2, "type": "Output", "pos": [120, 0], "name": "out", "value_type": "i32" }
    \\  ],
    \\  "edges": [
    \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "value" } }
    \\  ]
    \\}
    \\
;

pub const CustomNodeRegistry = struct {
    test "CustomNode references lower to PluginFlowNodes impl calls instead of UnknownFlowNode" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const fx = try setupFixture(allocator, &tmp);
        defer allocator.free(fx.game_dir);
        defer allocator.free(fx.target_dir);
        // setupFixture plants a `move.flow.jsonc` (no CustomNode); drop it
        // so the assertions below target only the CustomNode fixtures.
        try tmp.dir.deleteFile(std.testing.io, "game/scripts/flows/move.flow.jsonc");

        // Plant the game-script `FlowNodes` module next to `flows/`, then
        // the two CustomNode flows that reference it.
        try writeSample(tmp.dir, "game/scripts/log.zig", log_script_src);
        try writeSample(tmp.dir, "game/scripts/flows/do_log.flow.jsonc", command_customnode_flow);
        try writeSample(tmp.dir, "game/scripts/flows/read.flow.jsonc", reporter_customnode_flow);

        // Discover the script's FlowNodes — same call the orchestrator
        // makes ahead of the flow scan (root.zig). The walk reads the
        // source through `<target>/scripts/log.zig` (the symlink), and
        // computes `is_void` per impl return type.
        const scripts_root = try std.fs.path.join(allocator, &.{ fx.target_dir, "scripts" });
        defer allocator.free(scripts_root);
        const entries = [_]generator.script_scanner.ScriptScanner.ScriptEntry{
            .{
                .name = "log",
                .filename = "log.zig",
                .states = &.{},
                .sort_order = null,
                .subdir = null,
                .rel_path = "log.zig",
                .plugin_name = null,
            },
        };
        var decls = try generator.main_zig.discoverPluginFlowDecls(
            allocator,
            .{ .name = "test-game", .backend = .raylib, .ecs = .mock },
            fx.game_dir,
            scripts_root,
            &entries,
        );
        defer decls.deinit();

        // The void command resolves `is_void = true`; the reporter resolves
        // `is_void = false` — the flag that drives the lowering shape.
        try std.testing.expectEqual(@as(usize, 2), decls.flow_nodes.len);
        for (decls.flow_nodes) |fn_| {
            if (std.mem.eql(u8, fn_.node_name, "log_i32")) {
                try std.testing.expect(fn_.is_void);
            } else {
                try std.testing.expectEqualStrings("read_count", fn_.node_name);
                try std.testing.expect(!fn_.is_void);
            }
        }

        // Feed the discovered nodes into the scan — without #238 this
        // errored as `UnknownFlowNode` on the first CustomNode.
        var result = try flow_scanner.scanAndEmit(allocator, fx.game_dir, fx.target_dir, decls.flow_nodes);
        defer result.deinit();

        // Command lowering — a bare impl-call statement, no value binding.
        {
            const out_path = try std.fs.path.join(allocator, &.{ fx.target_dir, "scripts", "flows", "do_log.zig" });
            defer allocator.free(out_path);
            const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, out_path, allocator, .limited(64 * 1024));
            defer allocator.free(source);
            try std.testing.expect(std.mem.indexOf(u8, source, "@TypeOf(game_mod.PluginFlowNodes.log__log_i32).impl(game,") != null);
            // A command never binds a value for its own node.
            try std.testing.expect(std.mem.indexOf(u8, source, "= @TypeOf(game_mod.PluginFlowNodes.log__log_i32).impl") == null);

            const sentinel_src = try allocator.dupeZ(u8, source);
            defer allocator.free(sentinel_src);
            var ast = try std.zig.Ast.parse(allocator, sentinel_src, .zig);
            defer ast.deinit(allocator);
            try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
        }

        // Reporter lowering — the result binds to `const n<id>_value = ...`.
        {
            const out_path = try std.fs.path.join(allocator, &.{ fx.target_dir, "scripts", "flows", "read.zig" });
            defer allocator.free(out_path);
            const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, out_path, allocator, .limited(64 * 1024));
            defer allocator.free(source);
            try std.testing.expect(std.mem.indexOf(u8, source, "= @TypeOf(game_mod.PluginFlowNodes.log__read_count).impl(game)") != null);
            try std.testing.expect(std.mem.indexOf(u8, source, "_value = @TypeOf(game_mod.PluginFlowNodes.log__read_count).impl") != null);

            const sentinel_src = try allocator.dupeZ(u8, source);
            defer allocator.free(sentinel_src);
            var ast = try std.zig.Ast.parse(allocator, sentinel_src, .zig);
            defer ast.deinit(allocator);
            try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
        }
    }

    test "an unregistered CustomNode name surfaces as UnknownFlowNode" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const fx = try setupFixture(allocator, &tmp);
        defer allocator.free(fx.game_dir);
        defer allocator.free(fx.target_dir);
        try tmp.dir.deleteFile(std.testing.io, "game/scripts/flows/move.flow.jsonc");

        // A CustomNode naming a node that was never discovered — the
        // registry is empty for it, so codegen must reject it rather than
        // emit a dangling `PluginFlowNodes` reference.
        try writeSample(tmp.dir, "game/scripts/flows/do_log.flow.jsonc", command_customnode_flow);

        const result = flow_scanner.scanAndEmit(allocator, fx.game_dir, fx.target_dir, &.{});
        try std.testing.expectError(error.UnknownFlowNode, result);
    }
};

pub const FlowEventHandlerMarker = struct {
    test "Event-node-form flow sets ScriptEntry.has_event_handler = true" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const fx = try setupFixture(allocator, &tmp);
        defer allocator.free(fx.game_dir);
        defer allocator.free(fx.target_dir);

        // Plant an Event-node-form flow alongside the `move` flow the
        // fixture ships (also Event-node-form, post-Phase 6). Both
        // flows declare an in-graph `Event` node, so flow-codegen's
        // `renderNewFormEventEntry` emits `pub const FlowEventHandler`
        // for each and flow_scanner flips the marker.
        try writeSample(tmp.dir, "game/scripts/flows/hit_counter.flow.jsonc", new_form_on_event_flow_body);
        // Also plant an `OnCall` subgraph — its marker stays `false`
        // (subgraphs aren't event-driven, no `FlowEventHandler`).
        try writeSample(tmp.dir, "game/scripts/flows/compute.flow.jsonc", oncall_subgraph_flow_body);

        var result = try flow_scanner.scanAndEmit(allocator, fx.game_dir, fx.target_dir, &.{});
        defer result.deinit();

        // Three entries: `hit_counter` + `move` (both Event-node-form)
        // and `compute` (OnCall subgraph).
        try std.testing.expectEqual(@as(usize, 3), result.entries.len);
        for (result.entries) |entry| {
            if (std.mem.eql(u8, entry.name, "compute")) {
                // OnCall subgraph — no `FlowEventHandler` decl.
                try std.testing.expect(!entry.has_event_handler);
            } else {
                try std.testing.expect(entry.has_event_handler);
            }
        }
    }
};
