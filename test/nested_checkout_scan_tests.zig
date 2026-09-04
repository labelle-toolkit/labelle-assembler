//! Nested-repository pruning in the project scan (labelle-assembler#692).
//!
//! `git worktree add` inside a project (the workflow this toolkit's own
//! agents use) leaves a second, third, … checkout of the SAME project
//! sitting inside the working tree. Every scanner walk used to descend
//! into them and pick up that other branch's scripts, components, tests
//! and libs — duplicate compilation at best, and code from an unrelated
//! branch in the build graph at worst.
//!
//! The rule under test is deliberately NOT "skip `.worktrees`": the
//! directory can be called anything, and a submodule or a plain nested
//! clone has the identical problem. What marks a nested checkout is that
//! its root holds a `.git` ENTRY — and for a worktree (and a submodule)
//! that entry is a FILE containing a `gitdir:` pointer, not a directory.
//!
//! The acceptance is the one #692 names: a fixture with a nested checkout
//! under an arbitrarily-named directory scans the same file count as one
//! without it.

const std = @import("std");
const zspec = @import("zspec");
const generator = @import("generator");
const scanner = generator.scanner;

const io = std.testing.io;

test {
    zspec.runAll(@This());
}

fn writeSample(dir: std.Io.Dir, rel: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(rel)) |parent| try dir.createDirPath(io, parent);
    const f = try dir.createFile(io, rel, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, content);
}

/// The clean baseline: two real script files, nothing else.
fn stageBaseline(dir: std.Io.Dir, root: []const u8) !void {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try writeSample(dir, try std.fmt.bufPrint(&buf, "{s}/scripts/alpha.zig", .{root}), "// alpha");
    try writeSample(dir, try std.fmt.bufPrint(&buf, "{s}/scripts/nested/beta.zig", .{root}), "// beta");
}

fn scanScripts(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, root: []const u8) ![][]const u8 {
    const abs = try tmp.dir.realPathFileAlloc(io, root, allocator);
    defer allocator.free(abs);
    const scripts = try std.fs.path.join(allocator, &.{ abs, "scripts" });
    defer allocator.free(scripts);
    return scanner.scanDirAbs(allocator, scripts, ".zig");
}

pub const NESTED_CHECKOUT_PRUNING = struct {
    test "a nested checkout under an arbitrary name scans the same as no checkout at all (#692)" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try stageBaseline(tmp.dir, "clean");

        try stageBaseline(tmp.dir, "dirty");
        // A worktree checked out INSIDE the scanned tree, under a name
        // that carries no special meaning. Its `.git` is a FILE — the
        // exact shape `git worktree add` produces.
        try writeSample(tmp.dir, "dirty/scripts/some-branch/.git", "gitdir: /elsewhere/.git/worktrees/some-branch\n");
        try writeSample(tmp.dir, "dirty/scripts/some-branch/scripts/alpha.zig", "// stale copy from another branch");
        try writeSample(tmp.dir, "dirty/scripts/some-branch/scripts/gamma.zig", "// a file that exists ONLY on that branch");

        const clean = try scanScripts(allocator, &tmp, "clean");
        defer scanner.freeNames(allocator, clean);
        const dirty = try scanScripts(allocator, &tmp, "dirty");
        defer scanner.freeNames(allocator, dirty);

        try std.testing.expectEqual(clean.len, dirty.len);
        for (clean, dirty) |c, d| try std.testing.expectEqualStrings(c, d);
        // The other branch's exclusive file must not have leaked in.
        for (dirty) |name| {
            try std.testing.expect(std.mem.indexOf(u8, name, "gamma") == null);
        }
    }

    test "a nested checkout whose .git is a DIRECTORY is pruned too (plain nested clone, #692)" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try stageBaseline(tmp.dir, "clean");
        try stageBaseline(tmp.dir, "dirty");
        try tmp.dir.createDirPath(io, "dirty/scripts/vendored/.git/objects");
        try writeSample(tmp.dir, "dirty/scripts/vendored/scripts/delta.zig", "// vendored clone");

        const clean = try scanScripts(allocator, &tmp, "clean");
        defer scanner.freeNames(allocator, clean);
        const dirty = try scanScripts(allocator, &tmp, "dirty");
        defer scanner.freeNames(allocator, dirty);

        try std.testing.expectEqual(clean.len, dirty.len);
    }

    test "generated/cache/vendored dirs are pruned by name (#692)" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try stageBaseline(tmp.dir, "clean");
        try stageBaseline(tmp.dir, "dirty");
        for ([_][]const u8{ ".labelle", "zig-out", ".zig-cache", "zig-cache", "zig-pkg", "node_modules" }) |name| {
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            try writeSample(tmp.dir, try std.fmt.bufPrint(&buf, "dirty/scripts/{s}/leaked.zig", .{name}), "// generated");
        }

        const clean = try scanScripts(allocator, &tmp, "clean");
        defer scanner.freeNames(allocator, clean);
        const dirty = try scanScripts(allocator, &tmp, "dirty");
        defer scanner.freeNames(allocator, dirty);

        try std.testing.expectEqual(clean.len, dirty.len);
    }

    test "an ordinary subdirectory is still walked (negative control, #692)" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try stageBaseline(tmp.dir, "proj");
        try writeSample(tmp.dir, "proj/scripts/playing/epsilon.zig", "// real project code");

        const names = try scanScripts(allocator, &tmp, "proj");
        defer scanner.freeNames(allocator, names);

        var found = false;
        for (names) |n| {
            if (std.mem.eql(u8, n, "playing/epsilon")) found = true;
        }
        try std.testing.expect(found);
        try std.testing.expectEqual(@as(usize, 3), names.len);
    }
};

pub const NESTED_CHECKOUT_COPY_PRUNING = struct {
    test "copyAndScan does not mirror a nested checkout into the generated tree (#692)" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try writeSample(tmp.dir, "src/plugin/scripts/alpha.zig", "// alpha");
        try writeSample(tmp.dir, "src/plugin/scripts/wt/.git", "gitdir: /elsewhere\n");
        try writeSample(tmp.dir, "src/plugin/scripts/wt/scripts/alpha.zig", "// stale");

        const src_base = try tmp.dir.realPathFileAlloc(io, "src/plugin", allocator);
        defer allocator.free(src_base);
        try tmp.dir.createDirPath(io, "out");
        const dst_base = try tmp.dir.realPathFileAlloc(io, "out", allocator);
        defer allocator.free(dst_base);

        const names = try scanner.copyAndScan(allocator, src_base, dst_base, "scripts", ".zig");
        defer scanner.freeNames(allocator, names);

        try std.testing.expectEqual(@as(usize, 1), names.len);
        try std.testing.expectEqualStrings("alpha", names[0]);
        // …and nothing was copied either.
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "out/scripts/wt", .{}));
    }

    test "copyDirRecursive skips a nested checkout in an asset tree (#692)" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try writeSample(tmp.dir, "src/pack/assets/tile.png", "PNG");
        try writeSample(tmp.dir, "src/pack/assets/upstream/.git", "gitdir: /elsewhere\n");
        try writeSample(tmp.dir, "src/pack/assets/upstream/huge.bin", "0000");

        const src_base = try tmp.dir.realPathFileAlloc(io, "src/pack", allocator);
        defer allocator.free(src_base);
        try tmp.dir.createDirPath(io, "out");
        const dst_base = try tmp.dir.realPathFileAlloc(io, "out", allocator);
        defer allocator.free(dst_base);

        try scanner.copyDirRecursive(allocator, src_base, dst_base, "assets");

        try tmp.dir.access(io, "out/assets/tile.png", .{});
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "out/assets/upstream", .{}));
    }
};
