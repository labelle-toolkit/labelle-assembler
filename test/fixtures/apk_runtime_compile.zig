// Compile every generated runtime path against the catalog's public ABI.
const std = @import("std");
const Engine = struct {
    pub const DecodedPayload = enum { image, audio, font };
    pub const AssetEntry = struct {
        state: enum { registered, ready } = .registered,
        refcount: u32 = 0,
        loader: *const AssetLoaderVTable = &ImageLoader.vtable,
    };
    pub const AssetLoaderVTable = struct {
        decode: *const fn ([:0]const u8, []const u8, ?*const anyopaque, std.mem.Allocator) anyerror!DecodedPayload,
        upload: *const fn (*AssetEntry, DecodedPayload, std.mem.Allocator) anyerror!void,
        drop: *const fn (std.mem.Allocator, DecodedPayload) void,
        free: *const fn (*AssetEntry) void,
    };
    pub const ImageLoader = struct {
        fn decode(_: [:0]const u8, _: []const u8, _: ?*const anyopaque, _: std.mem.Allocator) !DecodedPayload {
            return .image;
        }
        fn upload(_: *AssetEntry, _: DecodedPayload, _: std.mem.Allocator) !void {}
        fn drop(_: std.mem.Allocator, _: DecodedPayload) void {}
        fn free(_: *AssetEntry) void {}
        pub const vtable: AssetLoaderVTable = .{ .decode = decode, .upload = upload, .drop = drop, .free = free };
    };
    pub const AudioLoader = ImageLoader;
    pub const FontLoader = ImageLoader;
};
const Android = struct {
    const Context = struct { get_native_activity: *const fn () callconv(.c) ?*anyopaque };
    extern fn activity() callconv(.c) ?*anyopaque;
    pub fn get() ?Context {
        return .{ .get_native_activity = activity };
    }
};
const Runtime = @import("apk").Runtime(Engine, Android);
export fn checkRuntime() void {
    const allocator = std.heap.page_allocator;
    var g = struct { assets: struct { entries: std.StringHashMap(Engine.AssetEntry) } }{ .assets = .{ .entries = std.StringHashMap(Engine.AssetEntry).init(allocator) } };
    defer g.assets.entries.deinit();
    g.assets.entries.put("asset", .{}) catch unreachable;
    inline for (.{ .image, .audio, .font }) |kind| Runtime.attach(&g, "asset", kind) catch unreachable;
    const entry = g.assets.entries.getPtr("asset").?;
    _ = entry.loader.decode(".png", "assets/test.png", null, allocator) catch return;
}
