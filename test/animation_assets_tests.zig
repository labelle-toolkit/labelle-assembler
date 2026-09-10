const std = @import("std");
const h = @import("helpers.zig");

test "JSONC animations load before scenes in loop and callback lifecycle" {
    var ctx = h.emptyCodegen(std.testing.allocator);
    ctx.animation_jsonc_names = &.{ "props/spin", "odd\"name" };
    ctx.jsonc_scene_names = &.{"main"};
    ctx.cfg.initial_prefab = "main";
    const loop = try ctx.buildSetupCode();
    defer std.testing.allocator.free(loop);
    const callback = try ctx.buildCallbackInitCode();
    defer std.testing.allocator.free(callback);
    for ([_][]const u8{ loop, callback }) |source| {
        const registration = std.mem.indexOf(u8, source, "try g.loadAnimationJsoncSource(\"animations/props/spin.jsonc\", @embedFile(\"animations/props/spin.jsonc\"));").?;
        try std.testing.expect(registration < std.mem.indexOf(u8, source, "g.setScene(").?);
        try std.testing.expect(std.mem.indexOf(u8, source, "animations/odd\\\"name.jsonc") != null);
    }
}

test "games without JSONC definitions have no new engine API dependency" {
    var ctx = h.emptyCodegen(std.testing.allocator);
    ctx.animation_names = &.{"legacy"};
    const loop = try ctx.buildSetupCode();
    defer std.testing.allocator.free(loop);
    try std.testing.expect(std.mem.indexOf(u8, loop, "loadAnimationJsoncSource") == null);
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    try ctx.writeAnimationRegistryBlock(&writer.writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.written(), "animations/legacy.zon") != null);
}
