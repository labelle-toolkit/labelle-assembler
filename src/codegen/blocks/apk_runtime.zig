//! Copied into Android output only when android.load_assets_from_apk is enabled.
const std = @import("std");

// Read compressed assets through AAsset_read, which supports deflated entries.
// No file-descriptor API: that only works with STORED zip members.
extern "android" fn AAssetManager_open(*anyopaque, [*:0]const u8, c_int) ?*anyopaque;
extern "android" fn AAsset_getLength64(*anyopaque) i64;
extern "android" fn AAsset_read(*anyopaque, [*]u8, usize) c_int;
extern "android" fn AAsset_close(*anyopaque) void;
const ActivityPrefix = extern struct {
    callbacks: ?*anyopaque,
    vm: ?*anyopaque,
    env: ?*anyopaque,
    clazz: ?*anyopaque,
    internal_data_path: ?[*:0]const u8,
    external_data_path: ?[*:0]const u8,
    sdk_version: c_int,
    instance: ?*anyopaque,
    asset_manager: ?*anyopaque,
};

/// Also used by tests with a short-reading/failing source. Never hand a
/// partially initialized byte buffer to a decoder.
pub fn readExact(source: anytype, bytes: []u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = try source.read(bytes[offset..][0..@min(bytes.len - offset, std.math.maxInt(c_int))]);
        if (n == 0) return error.UnexpectedEndOfAsset;
        if (n > bytes.len - offset) return error.InvalidAssetRead;
        offset += n;
    }
}

pub fn Runtime(comptime engine: type, comptime android: type) type {
    return struct {
        pub fn read(allocator: std.mem.Allocator, path: [:0]const u8) ![]u8 {
            const backend = android.get() orelse return error.AndroidBackendUnavailable;
            const raw = backend.get_native_activity() orelse return error.AndroidActivityUnavailable;
            const activity: *const ActivityPrefix = @ptrCast(@alignCast(raw));
            const manager = activity.asset_manager orelse return error.AndroidAssetManagerUnavailable;
            const asset = AAssetManager_open(manager, path.ptr, 2) orelse return error.AssetNotFound;
            defer AAsset_close(asset);
            const len = std.math.cast(usize, AAsset_getLength64(asset)) orelse return error.InvalidAssetLength;
            const bytes = try allocator.alloc(u8, len);
            errdefer allocator.free(bytes);
            const Source = struct {
                handle: *anyopaque,
                fn read(self: @This(), out: []u8) !usize {
                    const n = AAsset_read(self.handle, out.ptr, out.len);
                    if (n < 0) return error.AssetReadFailed;
                    return @intCast(n);
                }
            };
            try readExact(Source{ .handle = asset }, bytes);
            return bytes;
        }

        fn Loader(comptime base: engine.AssetLoaderVTable) type {
            return struct {
                fn decode(ext: [:0]const u8, path: []const u8, params: ?*const anyopaque, allocator: std.mem.Allocator) !engine.DecodedPayload {
                    // The catalog retains only the path. Re-acquire after a
                    // scene release/surface loss reads fresh bytes on its worker.
                    const terminated = try allocator.dupeZ(u8, path);
                    defer allocator.free(terminated);
                    const bytes = try read(allocator, terminated);
                    defer allocator.free(bytes);
                    return base.decode(ext, bytes, params, allocator);
                }
                const vtable: engine.AssetLoaderVTable = .{
                    .decode = decode,
                    .upload = base.upload,
                    .drop = base.drop,
                    .free = base.free,
                };
            };
        }

        /// Call immediately after registration, BEFORE acquire queues work.
        pub fn attach(g: anytype, name: []const u8, comptime kind: enum { image, audio, font }) !void {
            const entry = g.assets.entries.getPtr(name) orelse return error.AssetNotRegistered;
            if (entry.state != .registered or entry.refcount != 0) return error.AssetAlreadyAcquired;
            entry.loader = switch (kind) {
                .image => &Loader(engine.ImageLoader.vtable).vtable,
                .audio => &Loader(engine.AudioLoader.vtable).vtable,
                .font => &Loader(engine.FontLoader.vtable).vtable,
            };
        }
    };
}

test "APK reads tolerate partial chunks and reject premature EOF and failures" {
    const Source = struct {
        remaining: usize = 3,
        fail: bool = false,
        fn read(self: *@This(), out: []u8) !usize {
            if (self.fail) return error.AssetReadFailed;
            if (self.remaining == 0) return 0;
            self.remaining -= 1;
            out[0] = 'a';
            return 1;
        }
    };
    var source: Source = .{};
    var bytes: [3]u8 = undefined;
    try readExact(&source, &bytes);
    try std.testing.expectEqualStrings("aaa", &bytes);
    try std.testing.expectError(error.UnexpectedEndOfAsset, readExact(&source, &bytes));
    source.fail = true;
    try std.testing.expectError(error.AssetReadFailed, readExact(&source, &bytes));
}
