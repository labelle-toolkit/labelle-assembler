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
        const registration = std.mem.indexOf(u8, source, "g.loadAnimationJsoncSource(\"animations/props/spin.jsonc\", @embedFile(\"animations/props/spin.jsonc\"))").?;
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

fn writeFile(dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(std.testing.io, parent);
    const file = try dir.createFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, data);
}

test "emitted animation registration compiles and runs in a void callback" {
    const allocator = std.testing.allocator;
    var ctx = h.emptyCodegen(allocator);
    ctx.animation_jsonc_names = &.{"props/spin"};
    const callback = try ctx.buildCallbackInitCode();
    defer allocator.free(callback);
    // Registration is the first block from the real callback builder.
    // Compile that exact block in the void ABI used by mobile/direct-init
    // templates; unrelated renderer plumbing is deliberately stubbed out.
    const end = std.mem.indexOf(u8, callback, "\n\n").?;
    const header =
        \\const std = @import("std");
        \\const AssembledGame = struct {
        \\    calls: usize = 0,
        \\    pub fn loadAnimationJsoncSource(self: *@This(), name: []const u8, source: []const u8) error{WrongSource}!void {
        \\        if (!std.mem.eql(u8, name, "animations/props/spin.jsonc") or !std.mem.eql(u8, source, "{}")) return error.WrongSource;
        \\        self.calls += 1;
        \\    }
        \\};
        \\var g = AssembledGame{};
        \\export fn init() callconv(.c) void {
        \\
    ;
    const footer =
        \\}
        \\test "callback loads embedded source exactly once" {
        \\    init();
        \\    try std.testing.expectEqual(@as(usize, 1), g.calls);
        \\}
        \\
    ;
    const harness = try std.mem.concat(allocator, u8, &.{ header, callback[0..end], "\n", footer });
    defer allocator.free(harness);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "animations/props/spin.jsonc", "{}");
    try writeFile(tmp.dir, "callback.zig", harness);
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ @import("test_options").zig_exe, "test", "callback.zig" },
        .cwd = .{ .path = root },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("callback compile/run failed:\n{s}\n", .{result.stderr});
        return error.AnimationCallbackFailed;
    }
}
