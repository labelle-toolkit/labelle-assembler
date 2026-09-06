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
    test "creates a live link at dst/folder → src/folder, relative where the platform allows" {
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
        try std.testing.expect(std.mem.endsWith(u8, target, "scripts"));

        // Relative is PREFERRED, not universal (#710). A relative symlink
        // survives moving the project, so it is what gets written wherever
        // one can be created. Windows without SeCreateSymbolicLinkPrivilege
        // cannot, and falls back to a junction — which stores an NT path and
        // has no relative form. Asserting relativity there would be
        // asserting the platform, not the contract.
        if (@import("builtin").os.tag != .windows) {
            try std.testing.expect(!std.fs.path.isAbsolute(target));
        }

        // The contract on every platform: it is a LINK, and it resolves
        // through to the source. This is what a copy could not do, and why
        // the junction is worth an absolute target.
        const contents = try tmp.dir.readFileAlloc(std.testing.io, "project/.labelle/target/scripts/foo.zig", std.testing.allocator, .limited(64));
        defer std.testing.allocator.free(contents);
        try std.testing.expect(std.mem.eql(u8, contents, "// hi"));

        // LIVE, not a snapshot: an edit made after linking is visible
        // through the link with no re-link. The copy fallback fails this,
        // which is the whole reason for the junction.
        try writeSample(tmp.dir, "project/scripts/foo.zig", "// edited");
        const after = try tmp.dir.readFileAlloc(std.testing.io, "project/.labelle/target/scripts/foo.zig", std.testing.allocator, .limited(64));
        defer std.testing.allocator.free(after);
        try std.testing.expectEqualStrings("// edited", after);
    }

    /// The identity of the LINK ENTRY at `sub` — not of whatever it points
    /// at — or null where the platform cannot express that.
    ///
    /// Needed because the obvious idempotence assertions cannot see a
    /// replacement (#699 review): a marker written through the link lands in
    /// the SOURCE directory and survives, and a recreated link has the same
    /// target text. Both pass against an implementation that rebuilds the
    /// link every call.
    ///
    /// Windows only, and that is where it matters. A junction is a real
    /// directory entry, so `follow_symlinks = false` opens the reparse point
    /// itself and its inode (the FileIndex) changes when the entry is
    /// recreated. A POSIX symlink is not a directory, so the same open fails
    /// with `error.NotDir` — and there is nothing to catch there anyway: a
    /// symlink's target text equals `relative_target`, so the reconcile
    /// returns early and the text assertion already pins it. The regression
    /// this guards is junction-specific.
    fn linkIdentity(dir: std.Io.Dir, sub: []const u8) !?std.Io.File.INode {
        if (@import("builtin").os.tag != .windows) return null;
        var entry = try dir.openDir(std.testing.io, sub, .{ .follow_symlinks = false });
        defer entry.close(std.testing.io);
        const st = try entry.stat(std.testing.io);
        return st.inode;
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

        var first_buf: [std.fs.max_path_bytes]u8 = undefined;
        const first_len = try tmp.dir.readLink(std.testing.io, "project/.labelle/target/scenes", &first_buf);
        const first_text = first_buf[0..first_len];
        const first_id = try linkIdentity(tmp.dir, "project/.labelle/target/scenes");

        try scanner.linkDir(std.testing.allocator, src_base, dst_base, "scenes");

        // Same target text...
        var second_buf: [std.fs.max_path_bytes]u8 = undefined;
        const second_len = try tmp.dir.readLink(std.testing.io, "project/.labelle/target/scenes", &second_buf);
        try std.testing.expectEqualStrings(first_text, second_buf[0..second_len]);

        // ...and the SAME ENTRY, not an identical replacement. The assertion
        // with teeth: it fails against an implementation that deletes and
        // recreates the link, which is what a Windows junction got before
        // the reconcile learned to recognise its absolute target.
        const second_id = try linkIdentity(tmp.dir, "project/.labelle/target/scenes");
        if (first_id) |a| try std.testing.expectEqual(a, second_id.?);
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
        // Relative where the platform can express it; a Windows junction
        // cannot (#710) — see the sibling test above.
        if (@import("builtin").os.tag != .windows) {
            try std.testing.expect(!std.fs.path.isAbsolute(target));
        }
        try std.testing.expect(std.mem.endsWith(u8, target, "deep"));

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
