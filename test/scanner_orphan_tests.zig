//! scanner.copyAndScan / scanner.copyAndScanAbs — orphan pruning (#45).
//!
//! The copy-based scanner paths (used for plugin-shipped directories that
//! cannot be symlinked because their source lives outside the game tree)
//! must behave as a *true mirror*: when a source file is deleted, its stale
//! copy in the generated target tree must be pruned. Otherwise the orphan
//! stays in `.labelle/<target>/...` and the generated `main.zig` keeps it
//! in the comptime registry, so deleted code keeps running.
//!
//! These tests run the copy twice — once with a file present, once after
//! deleting it — and assert the orphan is gone the second time, while
//! legitimate surviving files and the `.bridge.zig` legacy artifact are
//! left intact.

const std = @import("std");
const zspec = @import("zspec");
const generator = @import("generator");
const scanner = generator.scanner;

test {
    zspec.runAll(@This());
}

fn writeSample(dir: std.Io.Dir, rel: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(rel)) |parent| try dir.createDirPath(std.testing.io, parent);
    const f = try dir.createFile(std.testing.io, rel, .{});
    defer f.close(std.testing.io);
    try f.writeStreamingAll(std.testing.io, content);
}

fn exists(dir: std.Io.Dir, rel: []const u8) bool {
    dir.access(std.testing.io, rel, .{}) catch return false;
    return true;
}

pub const CopyAndScanPrune = struct {
    test "prunes a stale top-level file after its source is deleted" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try tmp.dir.createDirPath(std.testing.io, "plugin/scripts");
        try writeSample(tmp.dir, "plugin/scripts/keep.zig", "// keep");
        try writeSample(tmp.dir, "plugin/scripts/foo.zig", "// foo");
        try tmp.dir.createDirPath(std.testing.io, "target");

        const src_base = try tmp.dir.realPathFileAlloc(std.testing.io, "plugin", std.testing.allocator);
        defer std.testing.allocator.free(src_base);
        const dst_base = try tmp.dir.realPathFileAlloc(std.testing.io, "target", std.testing.allocator);
        defer std.testing.allocator.free(dst_base);

        // First generate — both files copied.
        const n1 = try scanner.copyAndScan(std.testing.allocator, src_base, dst_base, "scripts", ".zig");
        scanner.freeNames(std.testing.allocator, n1);
        try std.testing.expect(exists(tmp.dir, "target/scripts/foo.zig"));
        try std.testing.expect(exists(tmp.dir, "target/scripts/keep.zig"));

        // Delete the source, regenerate.
        try tmp.dir.deleteFile(std.testing.io, "plugin/scripts/foo.zig");
        const n2 = try scanner.copyAndScan(std.testing.allocator, src_base, dst_base, "scripts", ".zig");
        defer scanner.freeNames(std.testing.allocator, n2);

        // The orphan is gone; the survivor stays.
        try std.testing.expect(!exists(tmp.dir, "target/scripts/foo.zig"));
        try std.testing.expect(exists(tmp.dir, "target/scripts/keep.zig"));

        // The returned name list no longer reports the deleted stem.
        try std.testing.expect(n2.len == 1);
        try std.testing.expect(std.mem.eql(u8, n2[0], "keep"));
    }

    test "prunes a stale file inside a nested subfolder" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try tmp.dir.createDirPath(std.testing.io, "plugin/prefabs/enemies");
        try writeSample(tmp.dir, "plugin/prefabs/enemies/goblin.jsonc", "g");
        try writeSample(tmp.dir, "plugin/prefabs/enemies/orc.jsonc", "o");
        try tmp.dir.createDirPath(std.testing.io, "target");

        const src_base = try tmp.dir.realPathFileAlloc(std.testing.io, "plugin", std.testing.allocator);
        defer std.testing.allocator.free(src_base);
        const dst_base = try tmp.dir.realPathFileAlloc(std.testing.io, "target", std.testing.allocator);
        defer std.testing.allocator.free(dst_base);

        const n1 = try scanner.copyAndScan(std.testing.allocator, src_base, dst_base, "prefabs", ".jsonc");
        scanner.freeNames(std.testing.allocator, n1);
        try std.testing.expect(exists(tmp.dir, "target/prefabs/enemies/orc.jsonc"));

        try tmp.dir.deleteFile(std.testing.io, "plugin/prefabs/enemies/orc.jsonc");
        const n2 = try scanner.copyAndScan(std.testing.allocator, src_base, dst_base, "prefabs", ".jsonc");
        defer scanner.freeNames(std.testing.allocator, n2);

        try std.testing.expect(!exists(tmp.dir, "target/prefabs/enemies/orc.jsonc"));
        try std.testing.expect(exists(tmp.dir, "target/prefabs/enemies/goblin.jsonc"));
        try std.testing.expect(n2.len == 1);
        try std.testing.expect(std.mem.eql(u8, n2[0], "enemies/goblin"));
    }

    test "prunes an entire subfolder once its source dir is removed" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try tmp.dir.createDirPath(std.testing.io, "plugin/scenes/extra");
        try writeSample(tmp.dir, "plugin/scenes/main.jsonc", "m");
        try writeSample(tmp.dir, "plugin/scenes/extra/side.jsonc", "s");
        try tmp.dir.createDirPath(std.testing.io, "target");

        const src_base = try tmp.dir.realPathFileAlloc(std.testing.io, "plugin", std.testing.allocator);
        defer std.testing.allocator.free(src_base);
        const dst_base = try tmp.dir.realPathFileAlloc(std.testing.io, "target", std.testing.allocator);
        defer std.testing.allocator.free(dst_base);

        const n1 = try scanner.copyAndScan(std.testing.allocator, src_base, dst_base, "scenes", ".jsonc");
        scanner.freeNames(std.testing.allocator, n1);
        try std.testing.expect(exists(tmp.dir, "target/scenes/extra/side.jsonc"));

        // Remove the whole `extra/` subfolder from the source.
        try tmp.dir.deleteTree(std.testing.io, "plugin/scenes/extra");
        const n2 = try scanner.copyAndScan(std.testing.allocator, src_base, dst_base, "scenes", ".jsonc");
        defer scanner.freeNames(std.testing.allocator, n2);

        try std.testing.expect(!exists(tmp.dir, "target/scenes/extra"));
        try std.testing.expect(exists(tmp.dir, "target/scenes/main.jsonc"));
        try std.testing.expect(n2.len == 1);
    }

    test "preserves the .bridge.zig legacy artifact during the sweep" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try tmp.dir.createDirPath(std.testing.io, "plugin/scripts");
        try writeSample(tmp.dir, "plugin/scripts/a.zig", "a");
        try tmp.dir.createDirPath(std.testing.io, "target/scripts");
        // A `.bridge.zig` exists in the target but has no source — the
        // copy pass deliberately never copies it, and the orphan sweep
        // must not delete it either.
        try writeSample(tmp.dir, "target/scripts/.bridge.zig", "legacy");

        const src_base = try tmp.dir.realPathFileAlloc(std.testing.io, "plugin", std.testing.allocator);
        defer std.testing.allocator.free(src_base);
        const dst_base = try tmp.dir.realPathFileAlloc(std.testing.io, "target", std.testing.allocator);
        defer std.testing.allocator.free(dst_base);

        const names = try scanner.copyAndScan(std.testing.allocator, src_base, dst_base, "scripts", ".zig");
        defer scanner.freeNames(std.testing.allocator, names);

        try std.testing.expect(exists(tmp.dir, "target/scripts/.bridge.zig"));
        try std.testing.expect(exists(tmp.dir, "target/scripts/a.zig"));
    }
};

pub const CopyAndScanAbsPrune = struct {
    test "prunes a stale orphan when source/dest paths differ" {
        // Mirrors the plugin-shipped-scripts path:
        // `<plugin>/scripts/**` → `<target>/scripts/.plugin_<name>/**`.
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try tmp.dir.createDirPath(std.testing.io, "plugin/scripts");
        try writeSample(tmp.dir, "plugin/scripts/controller.zig", "c");
        try writeSample(tmp.dir, "plugin/scripts/loading.zig", "l");
        try tmp.dir.createDirPath(std.testing.io, "target/scripts");

        const src_dir = try tmp.dir.realPathFileAlloc(std.testing.io, "plugin/scripts", std.testing.allocator);
        defer std.testing.allocator.free(src_dir);

        // Destination subdir does not exist yet — copyAndScanAbs creates it.
        const target_root = try tmp.dir.realPathFileAlloc(std.testing.io, "target", std.testing.allocator);
        defer std.testing.allocator.free(target_root);
        const dst_dir = try std.fs.path.join(std.testing.allocator, &.{ target_root, "scripts", ".plugin_demo" });
        defer std.testing.allocator.free(dst_dir);

        const n1 = try scanner.copyAndScanAbs(std.testing.allocator, src_dir, dst_dir, ".zig");
        scanner.freeNames(std.testing.allocator, n1);
        try std.testing.expect(exists(tmp.dir, "target/scripts/.plugin_demo/loading.zig"));

        // Plugin upgrade drops `loading.zig`.
        try tmp.dir.deleteFile(std.testing.io, "plugin/scripts/loading.zig");
        const n2 = try scanner.copyAndScanAbs(std.testing.allocator, src_dir, dst_dir, ".zig");
        defer scanner.freeNames(std.testing.allocator, n2);

        try std.testing.expect(!exists(tmp.dir, "target/scripts/.plugin_demo/loading.zig"));
        try std.testing.expect(exists(tmp.dir, "target/scripts/.plugin_demo/controller.zig"));
        try std.testing.expect(n2.len == 1);
        try std.testing.expect(std.mem.eql(u8, n2[0], "controller"));
    }
};
