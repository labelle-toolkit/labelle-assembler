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
        const src = generator.game_shim_source;

        // `@import("game")` users expect both decls at the root.
        try std.testing.expect(std.mem.indexOf(u8, src, "pub const Game") != null);
        try std.testing.expect(std.mem.indexOf(u8, src, "pub const EntityId") != null);

        // The shim must source those decls from labelle-engine — the
        // codegen-emitted flow files assume `Game` / `EntityId` have
        // the engine's hook semantics.
        try std.testing.expect(std.mem.indexOf(u8, src, "@import(\"labelle-engine\")") != null);
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

    test "plugins present: emits a PluginEvents blk: union and merges it into AllHookPayloads" {
        const allocator = std.testing.allocator;

        // Mirrors bouncing-ball's `.plugins = .{.{ .name = \"box2d\" }}`:
        // a single plugin with an identifier-safe name. The codegen
        // doesn't load the plugin module — the `@hasDecl` walk is
        // emitted as comptime Zig in main.zig, not run here.
        const cfg: generator.ProjectConfig = .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{
                .{ .name = "box2d", .repo = "local:../labelle-box2d" },
            },
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
        );
        defer allocator.free(main_zig);

        // PluginEvents decl is emitted as a `pub const` so flow-codegen
        // (phase 3) can reference it via the module-level import path.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const PluginEvents = blk: {") != null);
        // The comptime walk uses the same `@hasDecl(plugin, \"Events\")`
        // convention `Components`/`Systems`/`GizmoCategories` already
        // use (RFC §1, §2).
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@hasDecl(_entry.module, \"Events\")") != null);
        // Plugin-qualified variant tag — `<plugin>__<event>` — uses `__`
        // as the separator because `.` is not a valid Zig identifier
        // character. The codegen builds the name with `++ \"__\" ++`.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_entry.name ++ \"__\" ++ _d.name") != null);
        // The plugin module is imported by its project.labelle name —
        // the exact same `@import(\"box2d\")` form `SystemRegistry`
        // and `ComponentRegistryWithPlugins` already use.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@import(\"box2d\")") != null);
        // Merged into the SAME AllHookPayloads — no parallel dispatcher.
        try std.testing.expect(std.mem.indexOf(
            u8,
            main_zig,
            "AllHookPayloads = engine.core.MergeHookPayloads(.{ engine.HookPayload(EcsBackend.Entity), PluginEvents })",
        ) != null);

        // Validate the emitted Zig parses cleanly — `@Union` / `@Enum`
        // / `comptime var` arrangements are easy to break silently.
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
        );
        defer allocator.free(main_zig);

        // `.name` is the sanitized identifier (used as the variant
        // prefix). `.module` keeps the original string for `@import`.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".name = \"labelle_imgui\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@import(\"labelle-imgui\")") != null);
    }

    test "GameEvents and PluginEvents both flow into the same AllHookPayloads merge" {
        const allocator = std.testing.allocator;

        const cfg: generator.ProjectConfig = .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{
                .{ .name = "box2d", .repo = "" },
            },
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
        );
        defer allocator.free(main_zig);

        // Both unions appear in the merge expression, in this order —
        // `engine.HookPayload(EcsBackend.Entity)` first (the lifecycle
        // hooks), then `GameEvents` (events/*.zig scan), then
        // `PluginEvents` (plugin `pub const Events` discovery).
        const merge_str = "engine.core.MergeHookPayloads(.{ engine.HookPayload(EcsBackend.Entity), GameEvents, PluginEvents })";
        try std.testing.expect(std.mem.indexOf(u8, main_zig, merge_str) != null);
        // Game-side decl is also `pub` (so flow-codegen can reference
        // it by name from a generated handler in phase 3).
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const GameEvents = union(enum)") != null);
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
