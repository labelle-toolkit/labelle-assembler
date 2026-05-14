//! scanner.linkDir / scanner.linkAndScan — game-dir symlink layout (#71).
//!
//! The subject code creates relative directory symlinks from the
//! assembler's generated target tree back into the game project, so
//! edits propagate without re-running generate. Tests verify:
//!   1. Fresh link creation.
//!   2. Idempotent re-run when the link already points at the right
//!      target (no-op, no surprise re-create).
//!   3. Migration from a legacy copy-based tree — any real directory
//!      at the link path is removed and replaced.
//!   4. `linkAndScan` returns sorted stems and walks nested folders.
//!
//! All tests use a fresh tmpDir per case so the filesystem state is
//! hermetic.

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

pub const LinkDir = struct {
    test "creates relative symlink at dst/folder → src/folder" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        // Layout: tmp/project/scripts/foo.zig, tmp/project/.labelle/target/
        try tmp.dir.createDirPath(std.testing.io, "project/scripts");
        try writeSample(tmp.dir, "project/scripts/foo.zig", "// hi");
        try tmp.dir.createDirPath(std.testing.io, "project/.labelle/target");

        const src_base = try tmp.dir.realPathFileAlloc(std.testing.io, "project", std.testing.allocator);
        defer std.testing.allocator.free(src_base);
        const dst_base = try tmp.dir.realPathFileAlloc(std.testing.io, "project/.labelle/target", std.testing.allocator);
        defer std.testing.allocator.free(dst_base);

        try scanner.linkDir(std.testing.allocator, src_base, dst_base, "scripts");

        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        const target_len = try tmp.dir.readLink(std.testing.io, "project/.labelle/target/scripts", &link_buf);
        const target = link_buf[0..target_len];
        // Must be a relative path — not an absolute one — so the
        // link survives project-directory moves.
        try std.testing.expect(!std.fs.path.isAbsolute(target));
        try std.testing.expect(std.mem.endsWith(u8, target, "scripts"));

        // The link must resolve to the source file.
        const contents = try tmp.dir.readFileAlloc(std.testing.io, "project/.labelle/target/scripts/foo.zig", std.testing.allocator, .limited(64));
        defer std.testing.allocator.free(contents);
        try std.testing.expect(std.mem.eql(u8, contents, "// hi"));
    }

    test "re-run is idempotent when link already points at correct target" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try tmp.dir.createDirPath(std.testing.io, "project/scenes");
        try tmp.dir.createDirPath(std.testing.io, "project/.labelle/target");

        const src_base = try tmp.dir.realPathFileAlloc(std.testing.io, "project", std.testing.allocator);
        defer std.testing.allocator.free(src_base);
        const dst_base = try tmp.dir.realPathFileAlloc(std.testing.io, "project/.labelle/target", std.testing.allocator);
        defer std.testing.allocator.free(dst_base);

        try scanner.linkDir(std.testing.allocator, src_base, dst_base, "scenes");

        // Second call must not fail (no FileExists error) and must
        // preserve the original link.
        try scanner.linkDir(std.testing.allocator, src_base, dst_base, "scenes");
    }

    test "replaces a legacy copy-based directory with a symlink" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try tmp.dir.createDirPath(std.testing.io, "project/prefabs");
        try writeSample(tmp.dir, "project/prefabs/new.jsonc", "new content");
        // Simulate an older generate that left a real directory
        // (with stale content) at the target path.
        try tmp.dir.createDirPath(std.testing.io, "project/.labelle/target/prefabs");
        try writeSample(tmp.dir, "project/.labelle/target/prefabs/stale.jsonc", "old copy");

        const src_base = try tmp.dir.realPathFileAlloc(std.testing.io, "project", std.testing.allocator);
        defer std.testing.allocator.free(src_base);
        const dst_base = try tmp.dir.realPathFileAlloc(std.testing.io, "project/.labelle/target", std.testing.allocator);
        defer std.testing.allocator.free(dst_base);

        try scanner.linkDir(std.testing.allocator, src_base, dst_base, "prefabs");

        // Old copy is gone — the stale file is no longer reachable
        // through the target path (because it wasn't in source).
        const open_result = tmp.dir.openFile(std.testing.io, "project/.labelle/target/prefabs/stale.jsonc", .{});
        try std.testing.expect(open_result == error.FileNotFound);

        // New file from source IS reachable via the link.
        const f = try tmp.dir.openFile(std.testing.io, "project/.labelle/target/prefabs/new.jsonc", .{});
        f.close(std.testing.io);
    }

    test "creates intermediate directories when folder is nested" {
        // Plugin-declared convention dirs can be nested (e.g.
        // `foo/bar`). `linkDir` must make the immediate parent of
        // the symlink exist before calling symLink, otherwise
        // FileNotFound on the parent fails the create.
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try tmp.dir.createDirPath(std.testing.io, "project/nested/deep");
        try writeSample(tmp.dir, "project/nested/deep/thing.zig", "");
        try tmp.dir.createDirPath(std.testing.io, "project/.labelle/target");

        const src_base = try tmp.dir.realPathFileAlloc(std.testing.io, "project", std.testing.allocator);
        defer std.testing.allocator.free(src_base);
        const dst_base = try tmp.dir.realPathFileAlloc(std.testing.io, "project/.labelle/target", std.testing.allocator);
        defer std.testing.allocator.free(dst_base);

        try scanner.linkDir(std.testing.allocator, src_base, dst_base, "nested/deep");

        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        const target_len = try tmp.dir.readLink(std.testing.io, "project/.labelle/target/nested/deep", &link_buf);
        const target = link_buf[0..target_len];
        try std.testing.expect(!std.fs.path.isAbsolute(target));

        // And the file through the link is reachable.
        const f = try tmp.dir.openFile(std.testing.io, "project/.labelle/target/nested/deep/thing.zig", .{});
        f.close(std.testing.io);
    }

    test "missing source is silently skipped" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try tmp.dir.createDirPath(std.testing.io, "project/.labelle/target");

        const src_base = try tmp.dir.realPathFileAlloc(std.testing.io, "project", std.testing.allocator);
        defer std.testing.allocator.free(src_base);
        const dst_base = try tmp.dir.realPathFileAlloc(std.testing.io, "project/.labelle/target", std.testing.allocator);
        defer std.testing.allocator.free(dst_base);

        // `assets` doesn't exist in source — should not error,
        // matching the old copyDirRecursive behavior.
        try scanner.linkDir(std.testing.allocator, src_base, dst_base, "assets");

        // Link must not have been created.
        const open_result = tmp.dir.openDir(std.testing.io, "project/.labelle/target/assets", .{});
        try std.testing.expect(open_result == error.FileNotFound);
    }
};

pub const LinkAndScan = struct {
    test "returns sorted stems for top-level files" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try tmp.dir.createDirPath(std.testing.io, "project/scripts");
        try writeSample(tmp.dir, "project/scripts/zebra.zig", "");
        try writeSample(tmp.dir, "project/scripts/alpha.zig", "");
        try writeSample(tmp.dir, "project/scripts/mike.zig", "");
        try writeSample(tmp.dir, "project/scripts/README.md", ""); // non-matching ext
        try tmp.dir.createDirPath(std.testing.io, "project/.labelle/target");

        const src_base = try tmp.dir.realPathFileAlloc(std.testing.io, "project", std.testing.allocator);
        defer std.testing.allocator.free(src_base);
        const dst_base = try tmp.dir.realPathFileAlloc(std.testing.io, "project/.labelle/target", std.testing.allocator);
        defer std.testing.allocator.free(dst_base);

        const names = try scanner.linkAndScan(std.testing.allocator, src_base, dst_base, "scripts", ".zig");
        defer scanner.freeNames(std.testing.allocator, names);

        try std.testing.expect(names.len == 3);
        try std.testing.expect(std.mem.eql(u8, names[0], "alpha"));
        try std.testing.expect(std.mem.eql(u8, names[1], "mike"));
        try std.testing.expect(std.mem.eql(u8, names[2], "zebra"));
    }

    test "preserves nested subfolder structure in stem paths" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try tmp.dir.createDirPath(std.testing.io, "project/prefabs/enemies");
        try writeSample(tmp.dir, "project/prefabs/enemies/goblin.jsonc", "");
        try writeSample(tmp.dir, "project/prefabs/player.jsonc", "");
        try tmp.dir.createDirPath(std.testing.io, "project/.labelle/target");

        const src_base = try tmp.dir.realPathFileAlloc(std.testing.io, "project", std.testing.allocator);
        defer std.testing.allocator.free(src_base);
        const dst_base = try tmp.dir.realPathFileAlloc(std.testing.io, "project/.labelle/target", std.testing.allocator);
        defer std.testing.allocator.free(dst_base);

        const names = try scanner.linkAndScan(std.testing.allocator, src_base, dst_base, "prefabs", ".jsonc");
        defer scanner.freeNames(std.testing.allocator, names);

        try std.testing.expect(names.len == 2);
        try std.testing.expect(std.mem.eql(u8, names[0], "enemies/goblin"));
        try std.testing.expect(std.mem.eql(u8, names[1], "player"));
    }
};
