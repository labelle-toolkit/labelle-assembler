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

/// A filesystem path, ready to embed in a ZON string literal: separators
/// normalised to `/`, then escaped. Returns an allocator-owned slice.
///
/// Only the HOST separator is rewritten, never `\` unconditionally. On
/// Windows `std.fs.path.sep` is `\` and every separator becomes `/`; on
/// POSIX it is already `/`, so this is a no-op and a backslash — which is
/// ordinary filename data there — survives into `escapeZonString`, which
/// escapes it. Rewriting `\` on both platforms would silently turn a POSIX
/// `dep\name` into a different path, `dep/name` (#708 review).
///
/// Normalising at all is a portability choice: `std.fs.path.relative`
/// yields `\` on Windows while the deps-linked emitter hardcodes `/`, so
/// without this the same project produced different manifests on different
/// hosts. Zig's build system takes `/` on every platform.
pub fn zonPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const normalised = try allocator.dupe(u8, path);
    defer allocator.free(normalised);
    if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, normalised, std.fs.path.sep, '/');
    return escapeZonString(allocator, normalised);
}

test "zonPath: normalises host separators and escapes what is left (#708 review)" {
    const alloc = std.testing.allocator;
    const builtin = @import("builtin");

    if (builtin.os.tag == .windows) {
        // `\` is the separator here, so it becomes `/` and nothing needs
        // escaping afterwards.
        const w = try zonPath(alloc, "..\\deps\\labelle-physics");
        defer alloc.free(w);
        try std.testing.expectEqualStrings("../deps/labelle-physics", w);
    } else {
        // `\` is ORDINARY FILENAME DATA here. Rewriting it would name a
        // different path, so it must survive — escaped, not translated.
        const p = try zonPath(alloc, "deps/dep\\name");
        defer alloc.free(p);
        try std.testing.expectEqualStrings("deps/dep\\\\name", p);

        // And it must still round-trip to the byte-identical original.
        const src = try std.fmt.allocPrintSentinel(alloc, ".{{ .path = \"{s}\" }}", .{p}, 0);
        defer alloc.free(src);
        const Parsed = struct { path: []const u8 };
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const parsed = try std.zon.parse.fromSliceAlloc(Parsed, arena.allocator(), src, null, .{});
        try std.testing.expectEqualStrings("deps/dep\\name", parsed.path);
    }

    // A forward-slash path is untouched on every platform.
    const q = try zonPath(alloc, "../deps/labelle-core");
    defer alloc.free(q);
    try std.testing.expectEqualStrings("../deps/labelle-core", q);
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
