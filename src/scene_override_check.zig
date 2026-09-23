//! Generate-time guards for `labelle run --scene=<name>` (assembler#751).
//!
//! The CLI hands the requested scene to the running game (`LABELLE_SCENE` →
//! `engine.requestedScene()`), never to this generator, so the generated
//! startup boots the initial prefab and switches afterwards (or the project's
//! own loading controller does — `.scene_override = .project`). Two setups
//! quietly defeat that, and this module finds them so `generate` can warn:
//!
//! - **No `.initial_prefab` with several scenes.** The boot scene then falls
//!   back to scan order (the alphabetically first scene), so adding a scene
//!   can silently change what a plain `labelle run` boots.
//! - **A project that reads `requestedScene()` itself but keeps the default
//!   `.scene_override = .generated`.** Its loading controller and the
//!   generated loop would both switch the boot scene.

const std = @import("std");
const config = @import("config.zig");

/// True when the boot scene is chosen by scan order among several scenes.
pub fn initialPrefabAmbiguous(initial_prefab: ?[]const u8, jsonc_scene_count: usize) bool {
    return initial_prefab == null and jsonc_scene_count > 1;
}

/// Does this Zig source CALL `requestedScene(`? Line comments are ignored,
/// so a loading controller that only mentions it in a doc comment does not
/// count. Text, not a parse: a `//` inside a string literal cuts the line
/// early, which can only miss a call, never invent one.
pub fn sourceReadsRequestedScene(source: []const u8) bool {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const code = if (std.mem.indexOf(u8, line, "//")) |c| line[0..c] else line;
        if (std.mem.indexOf(u8, code, "requestedScene(") != null) return true;
    }
    return false;
}

/// The first `.zig` file under `dir_path` (recursive) that calls
/// `requestedScene(`, as a caller-owned path, or null. A missing directory is
/// null, not an error: a project without `scripts/` has nothing to find.
pub fn findRequestedSceneReader(allocator: std.mem.Allocator, dir_path: []const u8) !?[]const u8 {
    const io = config.globalIo();
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch return null) |entry| {
        switch (entry.kind) {
            .directory => {
                const sub = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
                defer allocator.free(sub);
                if (try findRequestedSceneReader(allocator, sub)) |hit| return hit;
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                const rel = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
                const source = std.Io.Dir.cwd().readFileAlloc(io, rel, allocator, .limited(4 * 1024 * 1024)) catch {
                    allocator.free(rel);
                    continue;
                };
                defer allocator.free(source);
                if (sourceReadsRequestedScene(source)) return rel;
                allocator.free(rel);
            },
            else => {},
        }
    }
    return null;
}

test "the boot scene is ambiguous only with several scenes and no initial_prefab" {
    try std.testing.expect(initialPrefabAmbiguous(null, 2));
    try std.testing.expect(!initialPrefabAmbiguous(null, 1));
    try std.testing.expect(!initialPrefabAmbiguous(null, 0));
    try std.testing.expect(!initialPrefabAmbiguous("main", 3));
}

test "a requestedScene() call counts; a comment mentioning it does not" {
    try std.testing.expect(sourceReadsRequestedScene(
        \\fn bootScene() []const u8 {
        \\    return engine.requestedScene() orelse DEFAULT_BOOT_SCENE;
        \\}
    ));
    try std.testing.expect(sourceReadsRequestedScene("    if (engine.requestedScene() != null) {"));
    try std.testing.expect(!sourceReadsRequestedScene(
        \\// The boot-scene name comes from `engine.requestedScene()` (the
        \\/// `requestedScene()` override below wins over this default).
        \\const DEFAULT_BOOT_SCENE = "menu";
    ));
    try std.testing.expect(!sourceReadsRequestedScene("const x = 1; // see requestedScene()"));
    try std.testing.expect(!sourceReadsRequestedScene("pub fn tick() void {}"));
}
