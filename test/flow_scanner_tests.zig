//! Integration tests for `flow_scanner` — the `.flow.zon` discovery
//! and codegen pass that Part B of labelle-gui#94 wires into the
//! assembler.
//!
//! Layout exercised per test:
//!
//! ```
//! <tmp>/game/scripts/flows/<stem>.flow.zon  ← author-edited source
//! <tmp>/game/.labelle/target/scripts/      ← symlink → ../../scripts
//! <tmp>/game/.labelle/target/scripts/flows/<stem>.zig
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
const move_flow_zon =
    \\.{
    \\    .event = .{ .OnCreate = .{ .arg_entity = "entity" } },
    \\    .nodes = .{
    \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .GetComponent = .{ .type = "Position" } } },
    \\        .{ .id = 2, .pos = .{0, 0}, .kind = .{ .BinOp = .{ .op = .add } } },
    \\        .{ .id = 3, .pos = .{0, 0}, .kind = .{ .SetField = .{ .target = "Position.x" } } },
    \\    },
    \\    .links = .{
    \\        .{ .from = .{ .node = 1, .pin = "x" }, .to = .{ .node = 2, .pin = "a" } },
    \\        .{ .from = .{ .node = 2, .pin = "result" }, .to = .{ .node = 3, .pin = "value" } },
    \\    },
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

    // Plant the .flow.zon fixture.
    try writeSample(tmp.dir, "game/scripts/flows/move.flow.zon", move_flow_zon);

    // Symlink target/scripts → ../../scripts (matches scanner.linkDir).
    try scanner.linkDir(allocator, game_dir, target_dir, "scripts");

    return .{ .game_dir = game_dir, .target_dir = target_dir };
}

pub const FlowScanner = struct {
    test "emits a .zig per .flow.zon and the generated source parses as valid Zig" {
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
            \\.{
            \\    .event = .{ .OnCreate = .{ .arg_entity = "entity" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .Identifier = .{ .name = "a" } } },
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .Identifier = .{ .name = "b" } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        try writeSample(tmp.dir, "game/scripts/flows/bad.flow.zon", bad);

        const result = flow_scanner.scanAndEmit(allocator, game_dir, target_dir);
        try std.testing.expectError(error.DuplicateNodeId, result);
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
        // pathToIdent replaces `/` and `.` with `_`, so the binding
        // name is `flows_move`.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const flows_move =") != null);
    }
};
