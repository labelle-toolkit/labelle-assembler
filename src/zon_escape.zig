//! Escaping for values written into generated ZON source.
//!
//! Its own module because three unrelated callers need the same answer and
//! none of them should import another's command code: `init_cmd` scaffolds
//! `project.labelle`, `build_files/build_zig_zon` emits dependency paths,
//! and the splice test fixtures build plugin manifests.
//!
//! The recurring trap is Windows (#708). A backslash is the path separator
//! there AND the escape character in a Zig string literal, so any path
//! interpolated raw into a ZON literal is a parse error waiting for a
//! machine where `std.fs.path` hands back `\`:
//!
//!     C:\Users\User\.zvm\zig.exe  →  error: invalid escape character: 'U'
//!     ..\deps\labelle-physics     →  error: invalid escape character: 'd'
//!
//! On Linux and macOS the same code is silently fine, so this is exactly
//! the kind of defect CI on those platforms cannot see.
const std = @import("std");

/// Escape `value` for embedding inside a ZON double-quoted string literal.
/// Backslashes and double quotes are the only characters that would break
/// the literal. Returns an allocator-owned slice; the caller frees it.
pub fn escapeZonString(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (value) |c| {
        if (c == '\\' or c == '"') try out.append(allocator, '\\');
        try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

test "escapeZonString escapes quotes and backslashes" {
    const alloc = std.testing.allocator;

    const a = try escapeZonString(alloc, "say\"hi");
    defer alloc.free(a);
    try std.testing.expectEqualStrings("say\\\"hi", a);

    const b = try escapeZonString(alloc, "path\\to");
    defer alloc.free(b);
    try std.testing.expectEqualStrings("path\\\\to", b);

    const c = try escapeZonString(alloc, "plain");
    defer alloc.free(c);
    try std.testing.expectEqualStrings("plain", c);
}

test "escapeZonString: a Windows path survives a round-trip through the ZON parser (#708)" {
    // The regression that mattered: `\U` and `\d` are not valid Zig escapes,
    // so an unescaped Windows path made the generated file unparseable — on
    // Windows only, which is why it lived so long.
    const alloc = std.testing.allocator;

    inline for (.{
        "C:\\Users\\User\\.zvm\\0.16.0\\zig.exe",
        "..\\deps\\labelle-physics",
        "C:\\proj\\.labelle\\raylib_desktop",
    }) |raw| {
        const escaped = try escapeZonString(alloc, raw);
        defer alloc.free(escaped);

        const src = try std.fmt.allocPrintSentinel(alloc, ".{{ .path = \"{s}\" }}", .{escaped}, 0);
        defer alloc.free(src);

        const Parsed = struct { path: []const u8 };
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const parsed = try std.zon.parse.fromSliceAlloc(Parsed, arena.allocator(), src, null, .{});
        // Not just parseable — the value has to come back byte-identical.
        try std.testing.expectEqualStrings(raw, parsed.path);
    }
}
