//! Shared by loop and callback initialization. Definitions must be loaded
//! before scene construction or script setup can spawn a prefab.
const std = @import("std");

pub fn emit(w: anytype, names: []const []const u8) !void {
    if (names.len == 0) return;
    try w.writeAll("    if (comptime !@hasDecl(AssembledGame, \"loadAnimationJsoncSource\")) @compileError(\"JSONC animations require an engine with loadAnimationJsoncSource support\");\n");
    for (names) |name| {
        try w.print("    try g.loadAnimationJsoncSource(\"animations/{f}.jsonc\", @embedFile(\"animations/{f}.jsonc\"));\n", .{ std.zig.fmtString(name), std.zig.fmtString(name) });
    }
    try w.writeAll("\n");
}
