//! Windows directory junctions (#710).
//!
//! Zig 0.16's `std.Io.Dir.symLink` builds the reparse point itself with
//! `FSCTL_SET_REPARSE_POINT` (`Io/Threaded.zig:dirSymLinkWindows`), which
//! requires `SeCreateSymbolicLinkPrivilege`. An ordinary Windows account
//! does not hold it, so every `symLink` fails with `PermissionDenied` —
//! **even where `New-Item -ItemType SymbolicLink` succeeds**, because
//! PowerShell calls `CreateSymbolicLinkW` with
//! `SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE`, a path Zig's code cannot
//! reach. Every directory the assembler meant to link therefore became a
//! COPY: a snapshot that never sees a source edit.
//!
//! A junction is the other kind of directory reparse point
//! (`IO_REPARSE_TAG_MOUNT_POINT`) and needs no privilege whatsoever. Four
//! properties make it a drop-in here, all verified on Windows 11 26200 with
//! Developer Mode off and no admin:
//!
//!   * it is created unprivileged;
//!   * reads resolve through it;
//!   * `std.Io.Dir.readLink` handles the MOUNT_POINT tag alongside SYMLINK,
//!     so `isSymlinkPath` / `slotTracksSource` treat it as the link it is,
//!     with no change to the resolve side; and
//!   * `deleteTree` removes the junction itself rather than recursing into
//!     the target — the property that matters most, since these slots get
//!     purged and the target is the user's own checkout.
//!
//! Limits: a junction points at an ABSOLUTE local path. There is no
//! relative form (the reparse point stores an NT path, `\??\C:\...`), so a
//! caller that needs a relocatable link cannot use one.
const std = @import("std");
const builtin = @import("builtin");

// Zig 0.16 exposes neither `CreateFileW` nor `DeviceIoControl` through
// `std.os.windows`, so they are declared here.
extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: u32,
    dwShareMode: u32,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: u32,
    dwFlagsAndAttributes: u32,
    hTemplateFile: ?*anyopaque,
) callconv(.winapi) ?*anyopaque;

extern "kernel32" fn DeviceIoControl(
    hDevice: *anyopaque,
    dwIoControlCode: u32,
    lpInBuffer: ?*const anyopaque,
    nInBufferSize: u32,
    lpOutBuffer: ?*anyopaque,
    nOutBufferSize: u32,
    lpBytesReturned: *u32,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) i32;

extern "kernel32" fn CloseHandle(hObject: *anyopaque) callconv(.winapi) i32;

const GENERIC_WRITE: u32 = 0x40000000;
const FILE_SHARE_ALL: u32 = 0x00000007;
const OPEN_EXISTING: u32 = 3;
const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x02000000;
const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x00200000;
const FSCTL_SET_REPARSE_POINT: u32 = 0x000900A4;
const IO_REPARSE_TAG_MOUNT_POINT: u32 = 0xA0000003;
const INVALID_HANDLE_VALUE = @as(?*anyopaque, @ptrFromInt(std.math.maxInt(usize)));

pub const Error = error{
    /// Not Windows, or the target is not an absolute local path.
    Unsupported,
    JunctionFailed,
};

/// Whether `path` exists (local copy — this module sits below the cache).
fn pathExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(@import("config.zig").globalIo(), path, .{}) catch return false;
    return true;
}

/// Whether `path` is an empty directory. A directory that cannot be opened
/// or read counts as NON-empty: this gates a deletion, so the cautious
/// answer is the safe one.
fn dirIsEmpty(path: []const u8) bool {
    const io = @import("config.zig").globalIo();
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    const first = it.next(io) catch return false;
    return first == null;
}

/// Create a directory junction at `link` pointing at `target`.
///
/// `target` must be an absolute local path. `link` may already exist only
/// if it is an EMPTY directory — which is the ordinary case here, since
/// Zig's `symLink` leaves one behind when its privilege check fails. A
/// non-empty `link` is refused rather than converted or deleted.
///
/// Returns `error.Unsupported` off Windows so callers can keep one code
/// path and fall through to their own fallback.
pub fn create(allocator: std.mem.Allocator, target: []const u8, link: []const u8) Error!void {
    if (builtin.os.tag != .windows) return error.Unsupported;
    // A mount point stores an NT path, so a relative or UNC target has no
    // representation here. Say so rather than writing a broken reparse point.
    if (!std.fs.path.isAbsolute(target) or std.mem.startsWith(u8, target, "\\\\")) {
        return error.Unsupported;
    }

    const io = @import("config.zig").globalIo();
    const cwd = std.Io.Dir.cwd();

    // Parent first, leaf separately — `createDirPath` on the leaf would
    // succeed for an EXISTING directory and lose the distinction the
    // cleanup below depends on. Guarded on existence because
    // `createDirPath` on a drive root fails with BadPathName (#704).
    if (std.fs.path.dirname(link)) |parent| {
        if (!pathExists(parent)) cwd.createDirPath(io, parent) catch return error.JunctionFailed;
    }

    // The reparse point is set on an existing, EMPTY directory.
    //
    // An existing one is not automatically ours to use, and never ours to
    // delete (#710 review). An empty directory here is the ordinary case —
    // Zig's own `symLink` creates the directory BEFORE its privilege check
    // fails, so it leaves one behind on the very path that sends us here.
    // But a NON-empty directory is somebody's data: converting it would
    // hide the contents behind the junction, and an unconditional cleanup
    // would delete them outright. Refuse instead.
    var created = true;
    cwd.createDir(io, link, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {
            if (!dirIsEmpty(link)) return error.JunctionFailed;
            created = false;
        },
        else => return error.JunctionFailed,
    };
    // Armed only for a directory THIS call created, so a pre-existing one
    // survives a failure untouched.
    errdefer if (created) cwd.deleteTree(io, link) catch {};

    var link_w: [std.os.windows.PATH_MAX_WIDE:0]u16 = undefined;
    const link_len = std.unicode.wtf8ToWtf16Le(&link_w, link) catch return error.JunctionFailed;
    link_w[link_len] = 0;

    const handle = CreateFileW(
        &link_w,
        GENERIC_WRITE,
        FILE_SHARE_ALL,
        null,
        OPEN_EXISTING,
        // BACKUP_SEMANTICS to open a directory at all; OPEN_REPARSE_POINT so
        // the handle is the directory itself rather than anything it points at.
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
        null,
    );
    if (handle == null or handle == INVALID_HANDLE_VALUE) return error.JunctionFailed;
    defer _ = CloseHandle(handle.?);

    // SubstituteName is the NT form the filesystem resolves; PrintName is
    // the Win32 form tools display.
    const subst = std.fmt.allocPrint(allocator, "\\??\\{s}", .{target}) catch return error.JunctionFailed;
    defer allocator.free(subst);

    var subst_w: [std.os.windows.PATH_MAX_WIDE]u16 = undefined;
    const subst_len = std.unicode.wtf8ToWtf16Le(&subst_w, subst) catch return error.JunctionFailed;
    var print_w: [std.os.windows.PATH_MAX_WIDE]u16 = undefined;
    const print_len = std.unicode.wtf8ToWtf16Le(&print_w, target) catch return error.JunctionFailed;

    const subst_bytes = subst_len * 2;
    const print_bytes = print_len * 2;
    // PathBuffer holds SubstituteName then PrintName, each NUL-terminated.
    const path_bytes = subst_bytes + 2 + print_bytes + 2;

    // REPARSE_DATA_BUFFER: an 8-byte common header (tag, data length,
    // reserved), then the mount-point body (four u16 offsets/lengths)
    // followed by PathBuffer. ReparseDataLength counts everything after the
    // common header, so body + paths.
    const header_len = 8;
    const body_len = 8;
    var buf = [_]u8{0} ** std.os.windows.MAXIMUM_REPARSE_DATA_BUFFER_SIZE;
    if (header_len + body_len + path_bytes > buf.len) return error.JunctionFailed;

    std.mem.writeInt(u32, buf[0..4], IO_REPARSE_TAG_MOUNT_POINT, .little);
    std.mem.writeInt(u16, buf[4..6], @intCast(body_len + path_bytes), .little);
    std.mem.writeInt(u16, buf[6..8], 0, .little);
    std.mem.writeInt(u16, buf[8..10], 0, .little); // SubstituteNameOffset
    std.mem.writeInt(u16, buf[10..12], @intCast(subst_bytes), .little);
    std.mem.writeInt(u16, buf[12..14], @intCast(subst_bytes + 2), .little); // PrintNameOffset
    std.mem.writeInt(u16, buf[14..16], @intCast(print_bytes), .little);

    const paths = buf[header_len + body_len ..];
    @memcpy(paths[0..subst_bytes], std.mem.sliceAsBytes(subst_w[0..subst_len]));
    @memcpy(paths[subst_bytes + 2 ..][0..print_bytes], std.mem.sliceAsBytes(print_w[0..print_len]));

    var returned: u32 = 0;
    const total: u32 = @intCast(header_len + body_len + path_bytes);
    if (DeviceIoControl(handle.?, FSCTL_SET_REPARSE_POINT, &buf, total, null, 0, &returned, null) == 0) {
        return error.JunctionFailed;
    }
}

test "create: junctions link, resolve, read back, and delete without touching the target (#710)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "source");

    const target = try tmp.dir.realPathFileAlloc(io, "source", alloc);
    defer alloc.free(target);
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    // A file to find through the link, and to still find afterwards.
    {
        const marker = try std.fs.path.join(alloc, &.{ target, "keep.txt" });
        defer alloc.free(marker);
        const f = try cwd.createFile(io, marker, .{});
        try f.writeStreamingAll(io, "precious");
        f.close(io);
    }

    const link = try std.fs.path.join(alloc, &.{ root, "link" });
    defer alloc.free(link);
    try create(alloc, target, link);

    // Reads resolve through it.
    {
        const through = try std.fs.path.join(alloc, &.{ link, "keep.txt" });
        defer alloc.free(through);
        const content = try cwd.readFileAlloc(io, through, alloc, .limited(64));
        defer alloc.free(content);
        try std.testing.expectEqualStrings("precious", content);
    }

    // The resolve side asks `readLink`, which must see a junction as a link
    // — this is what makes `slotTracksSource` work without any change.
    var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.readLinkAbsolute(io, link, &link_buf);
    try std.testing.expectEqualStrings(target, link_buf[0..n]);

    // The safety property: purging the slot must not reach the checkout.
    try cwd.deleteTree(io, link);
    const survivor = try std.fs.path.join(alloc, &.{ target, "keep.txt" });
    defer alloc.free(survivor);
    const content = try cwd.readFileAlloc(io, survivor, alloc, .limited(64));
    defer alloc.free(content);
    try std.testing.expectEqualStrings("precious", content);
}

test "create: a relative or UNC target is unsupported, not a broken reparse point (#710)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(root);

    const link = try std.fs.path.join(alloc, &.{ root, "rel" });
    defer alloc.free(link);
    try std.testing.expectError(error.Unsupported, create(alloc, "..\\sibling", link));
    try std.testing.expectError(error.Unsupported, create(alloc, "\\\\server\\share", link));
}

test "create: a NON-EMPTY existing directory is refused, never converted or deleted (#710 review)" {
    // The cleanup path is a `deleteTree`. If an existing directory could
    // reach it, a failed junction would delete whatever was already there —
    // so a non-empty one must be refused outright, and left intact.
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "source");
    try tmp.dir.createDirPath(io, "occupied");

    const target = try tmp.dir.realPathFileAlloc(io, "source", alloc);
    defer alloc.free(target);
    const occupied = try tmp.dir.realPathFileAlloc(io, "occupied", alloc);
    defer alloc.free(occupied);

    const bystander = try std.fs.path.join(alloc, &.{ occupied, "do-not-delete.txt" });
    defer alloc.free(bystander);
    {
        const f = try cwd.createFile(io, bystander, .{});
        try f.writeStreamingAll(io, "mine");
        f.close(io);
    }

    try std.testing.expectError(error.JunctionFailed, create(alloc, target, occupied));

    // Still a plain directory, contents untouched.
    try std.testing.expect(!isLink(occupied));
    const content = try cwd.readFileAlloc(io, bystander, alloc, .limited(64));
    defer alloc.free(content);
    try std.testing.expectEqualStrings("mine", content);
}

test "create: an EMPTY existing directory is adopted — the path symLink leaves behind (#710 review)" {
    // Zig's `symLink` creates the directory before its privilege check
    // fails, so it leaves an empty one on exactly the path that falls
    // through to a junction. Refusing that would make the fallback useless.
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "source");
    try tmp.dir.createDirPath(io, "empty");

    const target = try tmp.dir.realPathFileAlloc(io, "source", alloc);
    defer alloc.free(target);
    const empty = try tmp.dir.realPathFileAlloc(io, "empty", alloc);
    defer alloc.free(empty);

    try create(alloc, target, empty);
    try std.testing.expect(isLink(empty));

    var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.readLinkAbsolute(io, empty, &link_buf);
    try std.testing.expectEqualStrings(target, link_buf[0..n]);
}

fn isLink(path: []const u8) bool {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    _ = std.Io.Dir.readLinkAbsolute(@import("config.zig").globalIo(), path, &buf) catch return false;
    return true;
}

/// Create a directory link at `link` pointing at `target`: a symlink where
/// the platform allows one, a junction where it does not.
///
/// The one place that decision is made, so production and tests take the
/// same path — a test that hand-rolled `symLink` would simply fail on
/// Windows, which is how 83 of the Windows job's tests came to be skipped
/// (#699).
///
/// `error.PathAlreadyExists` passes through unchanged: a caller with a
/// reconcile path needs to tell "cannot link here" from "something is
/// already here". Any other failure returns the ORIGINAL symlink error, so
/// the caller still learns why linking was impossible.
pub fn linkDir(allocator: std.mem.Allocator, target: []const u8, link: []const u8) !void {
    const io = @import("config.zig").globalIo();
    return std.Io.Dir.cwd().symLink(io, target, link, .{ .is_directory = true }) catch |err| {
        if (err == error.PathAlreadyExists) return err;
        create(allocator, target, link) catch return err;
    };
}
