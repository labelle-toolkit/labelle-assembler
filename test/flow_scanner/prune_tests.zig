//! Tests for `flow_scanner`'s orphan-sidecar pruning (#632).
//!
//! `scanAndEmit` writes `<stem>.zig` next to each `<stem>.flow.jsonc`
//! but historically never pruned: removing or renaming a flow left the
//! stale sidecar behind, where its qualified plugin-event tags acted as
//! phantom consumers for the #630 consumption filter (#631 skips them
//! scan-side via the pairing rule; this pass removes them from disk).
//!
//! Pruning is a standalone `pruneStaleSidecars` pass — `root.zig` runs
//! it BEFORE script discovery so a project declaring a state named
//! `flows` never scoops an orphan sidecar into its `flows`-state script
//! set ahead of the delete (codex #639 review). These tests drive that
//! function directly.
//!
//! Safety predicate pinned here: a `.zig` under `scripts/flows/**` is
//! deleted only when BOTH (1) it has no paired sibling `.flow.jsonc`
//! AND (2) its first line starts with flow_codegen's generated-file
//! header. Hand-authored `.zig` (no header) is kept even when unpaired.
//!
//! Fixture layout matches `discovery_tests.zig` (per-domain files are
//! self-contained by convention — issue #185):
//!
//! ```
//! <tmp>/game/scripts/flows/**/<stem>.flow.jsonc ← author-edited source
//! <tmp>/game/.labelle/target/scripts/      ← symlink → ../../scripts
//! <tmp>/game/.labelle/target/scripts/flows/**/<stem>.zig
//! ```

const std = @import("std");
const zspec = @import("zspec");
const generator = @import("generator");

const flow_scanner = generator.flow_scanner;
const scanner = generator.scanner;
const script_scanner = generator.script_scanner;

/// Same 3-node Event-form fixture `discovery_tests.zig` uses — the
/// emitted sidecar carries the real flow_codegen header, which is
/// exactly what the prune predicate keys on.
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

/// Build the canonical `<game>/.labelle/target/` shape (real `scripts/`
/// on the game side, symlinked on the target side) with a single
/// `move.flow.jsonc` planted. Mirrors `discovery_tests.setupFixture`.
fn setupFixture(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) !struct { game_dir: []const u8, target_dir: []const u8 } {
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "game/scripts/flows");
    try tmp.dir.createDirPath(io, "game/.labelle/target");

    const game_dir_z = try tmp.dir.realPathFileAlloc(io, "game", allocator);
    defer allocator.free(game_dir_z);
    const game_dir = try allocator.dupe(u8, game_dir_z);
    const target_dir_z = try tmp.dir.realPathFileAlloc(io, "game/.labelle/target", allocator);
    defer allocator.free(target_dir_z);
    const target_dir = try allocator.dupe(u8, target_dir_z);

    try writeSample(tmp.dir, "game/scripts/flows/move.flow.jsonc", move_flow_body);
    try scanner.linkDir(allocator, game_dir, target_dir, "scripts");

    return .{ .game_dir = game_dir, .target_dir = target_dir };
}

fn expectFlowFileExists(tmp: *std.testing.TmpDir, rel: []const u8) !void {
    try tmp.dir.access(std.testing.io, rel, .{});
}

fn expectFlowFileGone(tmp: *std.testing.TmpDir, rel: []const u8) !void {
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, rel, .{}));
}

pub const FlowSidecarPrune = struct {
    test "removing a flow's .flow.jsonc prunes its generated sidecar" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const fx = try setupFixture(allocator, &tmp);
        defer allocator.free(fx.game_dir);
        defer allocator.free(fx.target_dir);

        // Emit the sidecar…
        {
            var result = try flow_scanner.scanAndEmit(allocator, fx.game_dir, fx.target_dir, &.{});
            defer result.deinit();
            try std.testing.expectEqual(@as(usize, 1), result.entries.len);
        }
        try expectFlowFileExists(&tmp, "game/scripts/flows/move.zig");

        // …and it really is a marked generated file — pins the emitter
        // header the prune predicate depends on, so a flow_codegen
        // header change breaks HERE instead of silently disabling
        // pruning.
        {
            const source = try tmp.dir.readFileAlloc(std.testing.io, "game/scripts/flows/move.zig", allocator, .limited(64 * 1024));
            defer allocator.free(source);
            try std.testing.expect(std.mem.startsWith(u8, source, "//! Generated by labelle-gui codegen"));
        }

        // Delete the source; prune. The orphan sidecar must be removed.
        try tmp.dir.deleteFile(std.testing.io, "game/scripts/flows/move.flow.jsonc");
        try flow_scanner.pruneStaleSidecars(allocator, fx.game_dir);
        try expectFlowFileGone(&tmp, "game/scripts/flows/move.zig");
    }

    test "renaming a flow prunes the old sidecar and emits the new one" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const fx = try setupFixture(allocator, &tmp);
        defer allocator.free(fx.game_dir);
        defer allocator.free(fx.target_dir);

        {
            var result = try flow_scanner.scanAndEmit(allocator, fx.game_dir, fx.target_dir, &.{});
            defer result.deinit();
        }
        try expectFlowFileExists(&tmp, "game/scripts/flows/move.zig");

        // Author renames `move` → `walk` (delete + re-create, same body).
        try tmp.dir.deleteFile(std.testing.io, "game/scripts/flows/move.flow.jsonc");
        try writeSample(tmp.dir, "game/scripts/flows/walk.flow.jsonc", move_flow_body);

        // Prune (drops the old orphan) then re-scan (emits the new one) —
        // the same order `root.zig` runs them in.
        try flow_scanner.pruneStaleSidecars(allocator, fx.game_dir);
        var result = try flow_scanner.scanAndEmit(allocator, fx.game_dir, fx.target_dir, &.{});
        defer result.deinit();

        try std.testing.expectEqual(@as(usize, 1), result.entries.len);
        try std.testing.expectEqualStrings("walk", result.entries[0].name);
        try expectFlowFileGone(&tmp, "game/scripts/flows/move.zig");
        try expectFlowFileExists(&tmp, "game/scripts/flows/walk.zig");
    }

    test "an unpaired hand-authored .zig without the generated header is kept" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const fx = try setupFixture(allocator, &tmp);
        defer allocator.free(fx.game_dir);
        defer allocator.free(fx.target_dir);

        // Unpaired `.zig` files that fail the header half of the
        // predicate: a plain helper, and a file SHORTER than the marker
        // (exercises the short-read branch).
        const hand_authored =
            \\//! Hand-written helper that strayed into flows/.
            \\pub fn helper() void {}
            \\
        ;
        try writeSample(tmp.dir, "game/scripts/flows/helper.zig", hand_authored);
        try writeSample(tmp.dir, "game/scripts/flows/tiny.zig", "//!x\n");

        try flow_scanner.pruneStaleSidecars(allocator, fx.game_dir);

        // Both survive — warned, never deleted.
        try expectFlowFileExists(&tmp, "game/scripts/flows/helper.zig");
        try expectFlowFileExists(&tmp, "game/scripts/flows/tiny.zig");
    }

    test "paired sidecars are untouched" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const fx = try setupFixture(allocator, &tmp);
        defer allocator.free(fx.game_dir);
        defer allocator.free(fx.target_dir);

        // Emit the sidecar, then prune with the source still present —
        // the paired (generated-header) file must NOT be deleted.
        {
            var result = try flow_scanner.scanAndEmit(allocator, fx.game_dir, fx.target_dir, &.{});
            defer result.deinit();
        }
        try flow_scanner.pruneStaleSidecars(allocator, fx.game_dir);
        try expectFlowFileExists(&tmp, "game/scripts/flows/move.zig");
    }

    test "prunes a nested orphan sidecar in a flows/ subdirectory" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const fx = try setupFixture(allocator, &tmp);
        defer allocator.free(fx.game_dir);
        defer allocator.free(fx.target_dir);

        // Emit a nested flow, then remove its source — the mirrored
        // subdirectory sidecar must be pruned too (recursive walk).
        try writeSample(tmp.dir, "game/scripts/flows/enemy/patrol.flow.jsonc", move_flow_body);
        {
            var result = try flow_scanner.scanAndEmit(allocator, fx.game_dir, fx.target_dir, &.{});
            defer result.deinit();
            try std.testing.expectEqual(@as(usize, 2), result.entries.len);
        }
        try expectFlowFileExists(&tmp, "game/scripts/flows/enemy/patrol.zig");

        try tmp.dir.deleteFile(std.testing.io, "game/scripts/flows/enemy/patrol.flow.jsonc");
        try flow_scanner.pruneStaleSidecars(allocator, fx.game_dir);

        try expectFlowFileGone(&tmp, "game/scripts/flows/enemy/patrol.zig");
        // The paired `move` sidecar (source still present) stays.
        try expectFlowFileExists(&tmp, "game/scripts/flows/move.zig");
    }

    test "orphan under a state named 'flows' is pruned before script discovery captures it" {
        // The codex #639 ordering bug: a project that declares a state
        // named `flows` binds `scripts/flows/<name>.zig` as a
        // `flows`-state script. If an orphan sidecar is captured before
        // it's pruned, the generated game imports a file the prune then
        // deletes. `root.zig` runs `pruneStaleSidecars` first; this pins
        // that a subsequent `ScriptScanner.scanDir` never sees the orphan.
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const fx = try setupFixture(allocator, &tmp);
        defer allocator.free(fx.game_dir);
        defer allocator.free(fx.target_dir);

        // Emit `move.zig`, then delete its source to strand it — a
        // generated-header orphan sitting in `scripts/flows/`.
        {
            var result = try flow_scanner.scanAndEmit(allocator, fx.game_dir, fx.target_dir, &.{});
            defer result.deinit();
        }
        try tmp.dir.deleteFile(std.testing.io, "game/scripts/flows/move.flow.jsonc");
        try expectFlowFileExists(&tmp, "game/scripts/flows/move.zig");

        // Prune FIRST (the root.zig order), then run the script scanner
        // against the staged tree with `flows` declared as a state.
        try flow_scanner.pruneStaleSidecars(allocator, fx.game_dir);

        const scripts_target = try std.fs.path.join(allocator, &.{ fx.target_dir, "scripts" });
        defer allocator.free(scripts_target);
        var script_scan = script_scanner.ScriptScanner.init(allocator, &.{"flows"});
        defer script_scan.deinit();
        try script_scan.scanDir(scripts_target);

        // The orphan is gone AND was never captured as a `flows`-state
        // script — no dangling `@import` in the generated registry.
        try expectFlowFileGone(&tmp, "game/scripts/flows/move.zig");
        for (script_scan.getEntries()) |entry| {
            try std.testing.expect(std.mem.indexOf(u8, entry.rel_path, "move") == null);
        }
    }
};
