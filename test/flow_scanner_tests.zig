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

test {
    zspec.runAll(@This());
}

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
    \\  "event": { "type": "OnCreate", "arg_entity": "entity" },
    \\  "nodes": [
    \\    { "id": 1, "type": "GetComponent", "pos": [0, 0], "component": "Position" },
    \\    { "id": 2, "type": "Literal", "pos": [0, 0], "value": "1.0" },
    \\    { "id": 3, "type": "BinOp", "pos": [0, 0], "op": "add" },
    \\    { "id": 4, "type": "SetField", "pos": [0, 0], "target": "Position.x" }
    \\  ],
    \\  "edges": [
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

pub const FlowScanner = struct {
    test "emits a .zig per .flow.jsonc and the generated source parses as valid Zig" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const fx = try setupFixture(allocator, &tmp);
        defer allocator.free(fx.game_dir);
        defer allocator.free(fx.target_dir);

        var result = try flow_scanner.scanAndEmit(allocator, fx.game_dir, fx.target_dir);
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
        try std.testing.expect(std.mem.indexOf(u8, source, "pub fn onCreate") != null);

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

        var result = try flow_scanner.scanAndEmit(allocator, game_dir, target_dir);
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
            \\  "event": { "type": "OnCreate", "arg_entity": "entity" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Identifier", "pos": [0, 0], "name": "a" },
            \\    { "id": 1, "type": "Identifier", "pos": [0, 0], "name": "b" }
            \\  ],
            \\  "edges": []
            \\}
            \\
        ;
        try writeSample(tmp.dir, "game/scripts/flows/bad.flow.jsonc", bad);

        const result = flow_scanner.scanAndEmit(allocator, game_dir, target_dir);
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

        var result = try flow_scanner.scanAndEmit(allocator, fx.game_dir, fx.target_dir);
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
        try std.testing.expect(std.mem.indexOf(u8, source, "pub fn onCreate") != null);
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

        var result = try flow_scanner.scanAndEmit(allocator, fx.game_dir, fx.target_dir);
        defer result.deinit();

        // Only `move.flow.jsonc` is a flow source.
        try std.testing.expectEqual(@as(usize, 1), result.entries.len);
        try std.testing.expectEqualStrings("move", result.entries[0].name);
    }
};

// ── AllScripts integration ──────────────────────────────────────────────
//
// Verifies the synthetic ScriptEntry produced by the scanner flows
// through `generateMainZigFromTemplate` and lands as a real `@import`
// in the AllScripts block — byte-for-byte matching the format the
// existing emit uses for hand-authored scripts. This is the contract
// that makes "wire flows into AllScripts" actually work end-to-end.

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

// ── `game` module binding (labelle-assembler#116) ──────────────────────
//
// Flow files emitted by labelle-gui's `flow-codegen` start with
// `const game_mod = @import("game");`, so the generated `build.zig` must
// expose a `"game"` module. These tests pin the shape we ship: a
// project-local `game.zig` shim re-exporting `Game` / `EntityId` from
// labelle-engine, wired via `b.createModule` and added to every exe /
// test root_module that includes flow-derived script files. See the
// PR body for the alias-vs-shim rationale.

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

pub const PluginEvents = struct {
    test "no plugins, no game events: AllHookPayloads stays the original engine.HookPayload form" {
        const allocator = std.testing.allocator;

        const cfg: generator.ProjectConfig = .{
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
        const cfg: generator.ProjectConfig = .{
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
        const cfg: generator.ProjectConfig = .{
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

        const cfg: generator.ProjectConfig = .{
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
};

// ── Flow sort-order (RFC-PLUGIN-EVENTS O3, phase 1 fix) ─────────────────
//
// Pre-RFC, `flow_scanner.zig:188` hard-coded `.sort_order = null` for
// every emitted ScriptEntry. That parked all flows in the unnumbered
// tail of the script scanner's sort, with raw `rel_path` as the
// tiebreaker — so `10_x.flow.jsonc` sorted before `2_x.flow.jsonc`
// (string-lex). RFC-PLUGIN-EVENTS O3 makes flows follow the same
// numeric-prefix convention scripts use (`script_scanner.zig:3-13`)
// by reusing `extractSortOrder`. These tests pin the new behaviour
// against the exact failure mode the previous code shipped.

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

        var result = try flow_scanner.scanAndEmit(allocator, fx.game_dir, fx.target_dir);
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

        var result = try flow_scanner.scanAndEmit(allocator, game_dir, target_dir);
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

        var result = try flow_scanner.scanAndEmit(allocator, game_dir, target_dir);
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

// ── RFC-PLUGIN-EVENTS phase 4 (labelle-assembler#175) ───────────────────
//
// `flow_scanner` flips `ScriptEntry.has_event_handler` on new-form
// `OnEvent` flows (those whose `event.OnEvent.name` is set —
// `flow_io.zig:333-360` validates the form) so the assembler's
// `game_hooks_block` / `hooks_init_block` emit knows which entries
// own a `pub const FlowEventHandler = struct { ... };` decl
// (flow-codegen `1182a80`, `codegen.zig:654-752`). Lifecycle flows
// (`OnCreate` / `OnUpdate` / `OnDestroy` / `OnCall`) and legacy
// `OnEvent` (still `setup()`-style raw-slot binding via
// `module`+`callback`) keep the default `false` and stay out of the
// receiver tuple. These tests pin the marker behaviour so phase 4's
// `GameHooks` wiring picks up the right entries.

const new_form_on_event_flow_body =
    \\{
    \\  "name": "hit_counter",
    \\  "event": { "type": "OnEvent", "name": "box2d.collision_begin" },
    \\  "nodes": [
    \\    { "id": 1, "type": "Literal", "pos": [0, 0], "value": "1.0" },
    \\    { "id": 2, "type": "Output", "pos": [0, 0], "name": "out", "value_type": "f32" }
    \\  ],
    \\  "edges": [
    \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "value" } }
    \\  ]
    \\}
    \\
;

pub const FlowEventHandlerMarker = struct {
    test "new-form OnEvent flow sets ScriptEntry.has_event_handler = true" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const fx = try setupFixture(allocator, &tmp);
        defer allocator.free(fx.game_dir);
        defer allocator.free(fx.target_dir);

        // Plant a new-form `OnEvent` flow next to the lifecycle `move`
        // flow `setupFixture` ships. The new-form flow carries `name`
        // (RFC §7), so flow-codegen's `renderNewFormEventEntry` emits a
        // `pub const FlowEventHandler` decl and flow_scanner flips the
        // marker.
        try writeSample(tmp.dir, "game/scripts/flows/hit_counter.flow.jsonc", new_form_on_event_flow_body);

        var result = try flow_scanner.scanAndEmit(allocator, fx.game_dir, fx.target_dir);
        defer result.deinit();

        // Two entries. `hit_counter` is the new-form OnEvent flow,
        // `move` is the lifecycle OnCreate flow from the fixture.
        try std.testing.expectEqual(@as(usize, 2), result.entries.len);
        for (result.entries) |entry| {
            if (std.mem.eql(u8, entry.name, "hit_counter")) {
                try std.testing.expect(entry.has_event_handler);
            } else {
                // Lifecycle (OnCreate) flow — no `FlowEventHandler`
                // decl, stays out of the receiver tuple.
                try std.testing.expectEqualStrings("move", entry.name);
                try std.testing.expect(!entry.has_event_handler);
            }
        }
    }
};

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
