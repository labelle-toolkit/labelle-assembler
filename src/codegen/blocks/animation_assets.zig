//! Shared by loop and callback initialization. Definitions must be loaded
//! before scene construction or script setup can spawn a prefab.
const std = @import("std");

const LoadStyle = @import("resource_loader.zig").LoadStyle;

pub fn emit(w: anytype, names: []const []const u8, style: LoadStyle) !void {
    if (names.len == 0) return;
    try w.writeAll("    if (comptime !@hasDecl(AssembledGame, \"loadAnimationJsoncSource\")) @compileError(\"JSONC animations require an engine with loadAnimationJsoncSource support\");\n");
    for (names) |name| {
        const escaped = std.zig.fmtString(name);
        switch (style) {
            .try_style => try w.print("    try g.loadAnimationJsoncSource(\"animations/{f}.jsonc\", @embedFile(\"animations/{f}.jsonc\"));\n", .{ escaped, escaped }),
            .catch_panic_style => try w.print("    g.loadAnimationJsoncSource(\"animations/{f}.jsonc\", @embedFile(\"animations/{f}.jsonc\")) catch @panic(\"failed to load animation: animations/{f}.jsonc\");\n", .{ escaped, escaped, escaped }),
        }
    }
    try w.writeAll("\n");
}
