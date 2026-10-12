//! Compile and run the emitted binding with both old and new engine surfaces.
const std = @import("std");
const h = @import("helpers.zig");

test "generated cursor binding runs on a new engine and compiles away on an old one" {
    const allocator = std.testing.allocator;
    var ctx = h.emptyCodegen(allocator);
    const setup = try ctx.buildCallbackInitCode();
    defer allocator.free(setup);
    const start = std.mem.indexOf(u8, setup, "    if (comptime @hasDecl(AssembledGame, \"bindCursorWindow\"))").?;
    const end = start + std.mem.indexOfScalar(u8, setup[start..], '\n').?;
    for ([_]bool{ false, true }) |modern| {
        const header = if (modern)
            "const AssembledGame = struct { calls: u32 = 0, pub fn bindCursorWindow(self: *@This(), comptime W: type) void { self.calls += 1; _ = W; } };\n"
        else
            "const AssembledGame = struct { calls: u32 = 0 };\n";
        const source = try std.fmt.allocPrint(allocator, "{s}const window = struct {{}};\nvar g = AssembledGame{{}};\ntest \"binding\" {{\n{s}\ntry @import(\"std\").testing.expectEqual(@as(u32, {d}), g.calls);\n}}\n", .{ header, setup[start..end], @intFromBool(modern) });
        defer allocator.free(source);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var file = try tmp.dir.createFile(std.testing.io, "binding.zig", .{});
        try file.writeStreamingAll(std.testing.io, source);
        file.close(std.testing.io);
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        defer allocator.free(root);
        const result = try std.process.run(allocator, std.testing.io, .{
            .argv = &.{ @import("test_options").zig_exe, "test", "binding.zig" },
            .cwd = .{ .path = root },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("cursor binding failed:\n{s}\n", .{result.stderr});
            return error.CursorBindingFailed;
        }
    }
}
