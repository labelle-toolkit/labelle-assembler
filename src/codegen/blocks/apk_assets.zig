//! Android byte-source selection. Packaging consumes apk_assets.json later.
const std = @import("std");
const config = @import("../../config.zig");
const LoadStyle = @import("resource_loader.zig").LoadStyle;
const lowerExt = @import("../idents.zig").lowerExtWithoutDot;
pub const runtime_source = @embedFile("apk_runtime.zig");

pub fn enabled(cfg: config.ProjectConfig) bool {
    return cfg.platform == .android and (if (cfg.android) |a| a.load_assets_from_apk else false);
}

pub fn validatePath(path: []const u8) !void {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfAny(u8, path, "\\\"\n\r\x00:") != null) return error.InvalidApkAssetPath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return error.InvalidApkAssetPath;
    }
}

pub fn emit(w: anytype, res: config.ResourceDef, style: LoadStyle) !void {
    // A lexical block gives JSON buffers a short lifetime. Font parameters
    // live in a comptime struct, including for callback-style startup.
    try w.writeAll("    {\n");
    const prefix = if (style == .try_style) "try " else "";
    const suffix = if (style == .try_style) ";\n" else " catch @panic(\"APK asset load failed\");\n";
    var ext_buf: [8]u8 = undefined;
    const kind = res.kind();
    const path = switch (kind) {
        .atlas => res.texture,
        .image => res.image,
        .sound => res.sound,
        .font => res.font,
        .invalid => return error.InvalidResourceDef,
    };
    try validatePath(path);
    const ext = lowerExt(&ext_buf, path);
    switch (kind) {
        .atlas => {
            try validatePath(res.json);
            try w.print("        const json = {s}ApkAssets.read(g.allocator, \"{s}\"){s}", .{ prefix, res.json, suffix });
            try w.writeAll("        defer g.allocator.free(json);\n");
            try w.print("        {s}g.registerAtlasFromMemory(\"{s}\", json, \"{s}\", \".{s}\"){s}", .{ prefix, res.name, path, ext, suffix });
        },
        .image => try w.print("        {s}g.assets.register(\"{s}\", .image, \".{s}\", \"{s}\"){s}", .{ prefix, res.name, ext, path, suffix }),
        .sound => try w.print("        {s}g.registerSoundFromMemory(\"{s}\", \"{s}\", \"{s}\"){s}", .{ prefix, res.name, ext, path, suffix }),
        .font => {
            const params = res.font_params orelse config.FontBakeParams{};
            try w.writeAll("        const Font = struct {\n            const ranges = [_]engine.CodepointRange{\n");
            for (params.ranges) |r| try w.print("                .{{ .first = 0x{X}, .last = 0x{X} }},\n", .{ r.first, r.last });
            try w.print("            }};\n            const params: engine.FontBakeParams = .{{ .pixel_height = {d}, .ranges = &ranges, .atlas_width = {d}, .atlas_height = {d} }};\n        }};\n", .{ params.pixel_height, params.atlas_width, params.atlas_height });
            try w.print("        {s}g.registerFontFromMemory(\"{s}\", \"{s}\", \"{s}\", &Font.params){s}", .{ prefix, res.name, ext, path, suffix });
        },
        .invalid => unreachable,
    }
    const loader = switch (kind) {
        .sound => "audio",
        .font => "font",
        else => "image",
    };
    try w.print("        {s}ApkAssets.attach(&g, \"{s}\", .{s}){s}", .{ prefix, res.name, loader, suffix });
    if (!(res.lazy orelse false)) {
        const method = switch (kind) {
            .atlas => "loadAtlasIfNeeded",
            .sound => "loadSoundIfNeeded",
            .font => "loadFontIfNeeded",
            .image => "assets.acquire",
            .invalid => unreachable,
        };
        try w.print("        _ = {s}g.{s}(\"{s}\"){s}", .{ prefix, method, res.name, suffix });
    }
    try w.writeAll("    }\n");
}

/// Paths are relative to the generated target directory; APK members live
/// at assets/<path>. Only selected textures appear, never wasm fallbacks.
pub fn manifest(allocator: std.mem.Allocator, resources: []const config.ResourceDef) ![]u8 {
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(allocator);
    for (resources) |res| {
        const paths = [_][]const u8{ res.json, res.texture, res.image, res.sound, res.font };
        for (paths) |path| {
            if (path.len == 0) continue;
            try validatePath(path);
            for (files.items) |seen| {
                if (std.mem.eql(u8, path, seen)) break;
            } else {
                try files.append(allocator, path);
            }
        }
    }
    return std.json.Stringify.valueAlloc(allocator, .{ .version = @as(u32, 1), .compression = "deflate", .files = files.items }, .{ .whitespace = .indent_2 });
}

test "APK manifest excludes fallback, deduplicates, rejects traversal" {
    const resources = [_]config.ResourceDef{ .{ .name = "a", .json = "assets/a.json", .texture = "assets/a.astc", .texture_fallback = "assets/a.png" }, .{ .name = "b", .image = "assets/a.astc" } };
    const bytes = try manifest(std.testing.allocator, &resources);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "a.png") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "a.astc"));
    try std.testing.expectError(error.InvalidApkAssetPath, validatePath("../assets/x"));
    try std.testing.expectError(error.InvalidApkAssetPath, validatePath("/tmp/x"));
    try std.testing.expectError(error.InvalidApkAssetPath, validatePath("a/../x"));
}
