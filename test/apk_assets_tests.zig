const std = @import("std");
const h = @import("helpers.zig");
const apk = @import("generator").main_zig.apk_assets;

test "APK opt-in changes both lifecycle paths without embedding binary assets" {
    var ctx = h.emptyCodegen(std.testing.allocator);
    ctx.cfg.platform = .android;
    ctx.cfg.android = .{ .load_assets_from_apk = true };
    ctx.cfg.resources = &.{
        .{ .name = "ship", .json = "assets/ship.json", .texture = "assets/ship.astc", .texture_fallback = "assets/ship.png", .lazy = true },
        .{ .name = "logo", .image = "assets/logo.png", .lazy = false },
        .{ .name = "music", .sound = "assets/music.ogg", .lazy = true },
        .{ .name = "face", .font = "assets/face.ttf", .lazy = true },
    };
    const loop = try ctx.buildSetupCode();
    defer std.testing.allocator.free(loop);
    const callback = try ctx.buildCallbackInitCode();
    defer std.testing.allocator.free(callback);
    for ([_][]const u8{ loop, callback }) |source| {
        try std.testing.expect(std.mem.indexOf(u8, source, "@embedFile(\"assets/") == null);
        try std.testing.expect(std.mem.indexOf(u8, source, "ship.png") == null);
        try std.testing.expect(std.mem.indexOf(u8, source, "ApkAssets.read(g.allocator, \"assets/ship.json\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, source, "loadAtlasIfNeeded(\"ship\")") == null);
        const attach = std.mem.indexOf(u8, source, "ApkAssets.attach(&g, \"logo\", .image)").?;
        try std.testing.expect(attach < std.mem.indexOf(u8, source, "g.assets.acquire(\"logo\")").?);
        try std.testing.expect(std.mem.indexOf(u8, source, "&Font.params") != null);
    }
    ctx.cfg.android = .{};
    const legacy = try ctx.buildSetupCode();
    defer std.testing.allocator.free(legacy);
    try std.testing.expect(std.mem.indexOf(u8, legacy, "ApkAssets") == null);
    try std.testing.expect(std.mem.indexOf(u8, legacy, "@embedFile(\"assets/ship.astc\")") != null);
    ctx.cfg.android = .{ .load_assets_from_apk = true };
    ctx.cfg.platform = .desktop;
    try std.testing.expect(!apk.enabled(ctx.cfg));
}

test {
    std.testing.refAllDecls(apk);
}
