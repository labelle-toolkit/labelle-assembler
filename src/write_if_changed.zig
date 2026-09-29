//! Write-if-changed: the primitive that makes `generate` byte-stable (#674).
//!
//! `generate` re-emits the whole `.labelle/<target>/` tree on every run. With
//! unchanged inputs the bytes are identical, but a plain `createFile` +
//! write still bumps every mtime — and Zig's cache and `zig build --watch`
//! both key on the file, so an untouched mtime avoids even a no-op rebuild or
//! reconfigure. Every generated-file write goes through `writeIfChanged`: it
//! compares the file already on disk with the new bytes and leaves an
//! identical file alone (no open-for-write, so mtime and inode survive).

const std = @import("std");

/// True when `sub_path` (relative to `dir`) is a regular file whose bytes are
/// exactly `content`. Any error (missing file, a directory, unreadable) reads
/// as "not the same", which makes the caller write — the safe direction.
pub fn sameContent(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, content: []const u8) bool {
    const file = dir.openFile(io, sub_path, .{}) catch return false;
    defer file.close(io);
    const st = file.stat(io) catch return false;
    if (st.kind != .file or st.size != content.len) return false;

    var buf: [16 * 1024]u8 = undefined;
    var off: usize = 0;
    while (off < content.len) {
        const want = @min(buf.len, content.len - off);
        const n = file.readPositionalAll(io, buf[0..want], off) catch return false;
        if (n != want) return false;
        if (!std.mem.eql(u8, buf[0..n], content[off..][0..n])) return false;
        off += n;
    }
    return true;
}

/// True when `a_sub` (in `a_dir`) and `b_sub` (in `b_dir`) are both regular
/// files with identical bytes. Streams both — no size cap, no allocation.
/// Any error reads as "different" (the caller then copies — the safe side).
pub fn sameFiles(io: std.Io, a_dir: std.Io.Dir, a_sub: []const u8, b_dir: std.Io.Dir, b_sub: []const u8) bool {
    const a = a_dir.openFile(io, a_sub, .{}) catch return false;
    defer a.close(io);
    const b = b_dir.openFile(io, b_sub, .{}) catch return false;
    defer b.close(io);
    const as = a.stat(io) catch return false;
    const bs = b.stat(io) catch return false;
    if (as.kind != .file or bs.kind != .file or as.size != bs.size) return false;
    var abuf: [16 * 1024]u8 = undefined;
    var bbuf: [16 * 1024]u8 = undefined;
    var off: u64 = 0;
    while (off < as.size) {
        const want: usize = @intCast(@min(abuf.len, as.size - off));
        const na = a.readPositionalAll(io, abuf[0..want], off) catch return false;
        const nb = b.readPositionalAll(io, bbuf[0..want], off) catch return false;
        if (na != want or nb != want) return false;
        if (!std.mem.eql(u8, abuf[0..want], bbuf[0..want])) return false;
        off += want;
    }
    return true;
}

/// Write `content` to `sub_path` unless the file already holds exactly those
/// bytes. Returns true when it wrote. Parent directories must exist (same
/// contract as the `createFile` it replaces).
pub fn writeIfChanged(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, content: []const u8) !bool {
    if (sameContent(io, dir, sub_path, content)) return false;
    const file = try dir.createFile(io, sub_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
    return true;
}

test "writeIfChanged: identical bytes are not rewritten (mtime + inode survive)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expect(try writeIfChanged(io, tmp.dir, "a.txt", "hello"));
    const before = try tmp.dir.statFile(io, "a.txt", .{});

    // Mechanism, not just outcome: the second call must report it did NOT
    // write, and the file's identity/mtime must be unchanged.
    try std.testing.expect(!try writeIfChanged(io, tmp.dir, "a.txt", "hello"));
    const after = try tmp.dir.statFile(io, "a.txt", .{});
    try std.testing.expectEqual(before.inode, after.inode);
    try std.testing.expectEqual(before.mtime.nanoseconds, after.mtime.nanoseconds);
}

test "writeIfChanged: different bytes (same length or not) are written" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    _ = try writeIfChanged(io, tmp.dir, "a.txt", "hello");
    try std.testing.expect(try writeIfChanged(io, tmp.dir, "a.txt", "jello"));
    try std.testing.expect(try writeIfChanged(io, tmp.dir, "a.txt", "hi"));
    var buf: [8]u8 = undefined;
    const got = try tmp.dir.readFile(io, "a.txt", &buf);
    try std.testing.expectEqualStrings("hi", got);
}

test "sameContent: large content compares across buffer chunks" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const big = try std.testing.allocator.alloc(u8, 40 * 1024 + 7);
    defer std.testing.allocator.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i *% 31);
    _ = try writeIfChanged(io, tmp.dir, "big.bin", big);
    try std.testing.expect(sameContent(io, tmp.dir, "big.bin", big));
    big[big.len - 1] +%= 1;
    try std.testing.expect(!sameContent(io, tmp.dir, "big.bin", big));
    try std.testing.expect(!sameContent(io, tmp.dir, "missing.bin", big));
}
