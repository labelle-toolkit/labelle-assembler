//! Identifier sanitization helpers extracted from `codegen/scan.zig`
//! (behavior-preserving split, labelle-assembler#534 follow-up).
//!
//! Pure, allocation-free string mappings that turn plugin names / paths
//! into valid Zig identifier fragments. Every string these emit feeds
//! directly into generated `main.zig` source, so the mappings are a
//! bit-identical contract — see the doc-comments on each fn. Re-exported
//! from the `scan.zig` barrel; the discovery passes reach them through it.

const std = @import("std");
const config = @import("../../config.zig");

/// Write a formatted message directly to stderr without a log-level prefix.
///
/// `std.log.err` is deliberately avoided here for the same reason as in
/// `src/scene_manifest.zig`: the assembler's test suite has negative-path
/// tests that `expectError(...)` from these emitters, and the test runner's
/// log interceptor would flag any `std.log.err` call as a hard failure even
/// when the surrounding test is *expecting* the error. Writing to stderr
/// directly (via the process-wide Io from `config.globalIo()`) keeps the
/// human-readable diagnostic in front of the user without tripping that
/// trap. Mirrors the `writeStderr` helpers in `main.zig` / `cache_cmd.zig`,
/// just with `bufPrint` for the `{d}` substitution; the format string is
/// printed verbatim on bufPrint overflow so the user still sees *something*.
fn stderrPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    std.Io.File.stderr().writeStreamingAll(config.globalIo(), msg) catch {};
}
/// Sanitize a plugin name (e.g. `labelle-box2d`) into a Zig identifier
/// fragment safe for embedding in a union variant tag. Non-identifier
/// bytes (`-`, `.`, `/`, …) collapse to `_`. The output is written
/// into the caller's buffer and returned as a sub-slice. The mapping
/// is collapsing rather than escaping, so two plugin names that
/// sanitize to the same identifier (e.g. `foo-bar` and `foo_bar`)
/// would collide — but the resulting duplicate variant name is
/// rejected by `MergeHookPayloads`' duplicate-field check at
/// comptime, surfacing the conflict immediately rather than silently.
pub fn sanitizePluginIdent(name: []const u8, buf: *[128]u8) []const u8 {
    var i: usize = 0;
    // A leading digit is invalid in a Zig identifier — prefix `_`.
    if (name.len > 0 and std.ascii.isDigit(name[0])) {
        buf[i] = '_';
        i += 1;
    }
    for (name) |c| {
        if (i >= buf.len) break;
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '_' => buf[i] = c,
            else => buf[i] = '_',
        }
        i += 1;
    }
    return buf[0..i];
}
/// Convert a path-style name to a valid Zig identifier: "enemies/goblin" -> "enemies_s_goblin".
/// Strips the `.zig` extension first, then escapes every character that is not
/// a valid identifier character into a distinct `_<tag>_` sequence.
///
/// The mapping is **injective**: distinct input paths always produce distinct
/// identifiers. Naively replacing `/`, `+`, and `.` all with `_` would collapse
/// e.g. `enemy/patrol` and `enemy_patrol` (or `a/b/c` and `a/b_c`) onto the same
/// identifier, emitting duplicate `pub const` lines in the generated `main.zig`.
/// To stay injective we must also escape literal `_` in the input — otherwise a
/// path containing `_` could alias an escaped separator.
///
/// Escape table (each maps to a sequence Zig accepts in an identifier):
///   `_` (literal) -> `_u_`   (`u`nderscore)
///   `/`           -> `_s_`   (`s`lash)
///   `.`           -> `_d_`   (`d`ot)
///   `+`           -> `_p_`   (`p`lus)
/// Any other non-`[A-Za-z0-9]` byte -> `_x<2-hex>_`.
///
/// Because every `_` in the output is the start of one of these escapes, no two
/// distinct inputs can decode to the same identifier. The `.` escape covers
/// plugin-shipped scripts that land under `.plugin_<name>/…`, whose leading dot
/// would otherwise produce an identifier that Zig rejects.
pub fn pathToIdent(name: []const u8, buf: *[256]u8) []const u8 {
    // Strip .zig extension
    const end = if (std.mem.endsWith(u8, name, ".zig")) name.len - 4 else name.len;
    var i: usize = 0;
    const append = struct {
        fn f(b: *[256]u8, idx: *usize, bytes: []const u8) void {
            if (idx.* + bytes.len > b.len) {
                stderrPrint("labelle: path too long for identifier (max {d} chars): too many escaped chars\n", .{b.len});
                @panic("path exceeds identifier buffer size");
            }
            @memcpy(b[idx.*..][0..bytes.len], bytes);
            idx.* += bytes.len;
        }
    }.f;
    // A leading digit makes the result invalid as a Zig identifier
    // (`pub const 2x2_tile = ...` won't compile). Prefix a `_`. It
    // can't alias an escape sequence — every escape is `_` followed
    // by a letter (`u`/`s`/`d`/`p`/`x`), never a digit — so the
    // mapping stays injective.
    if (end > 0 and name[0] >= '0' and name[0] <= '9') append(buf, &i, "_");
    for (name[0..end]) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9' => append(buf, &i, &.{c}),
            '_' => append(buf, &i, "_u_"),
            '/' => append(buf, &i, "_s_"),
            '.' => append(buf, &i, "_d_"),
            '+' => append(buf, &i, "_p_"),
            else => {
                const hex = "0123456789abcdef";
                append(buf, &i, &.{ '_', 'x', hex[c >> 4], hex[c & 0x0f], '_' });
            },
        }
    }
    return buf[0..i];
}

// ── Tests (moved verbatim from scan.zig) ─────────────────────────────

test "pathToIdent: plain name is unchanged" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("health", pathToIdent("health", &buf));
}

test "pathToIdent: strips the .zig extension" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("patrol", pathToIdent("patrol.zig", &buf));
}

test "pathToIdent: distinct separators do not collide (issue #172)" {
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    // The classic collision: a slash-separated path vs the same text with a
    // literal underscore. Pre-fix both became `enemy_patrol`.
    const slash = pathToIdent("enemy/patrol", &a);
    const under = pathToIdent("enemy_patrol", &b);
    try std.testing.expect(!std.mem.eql(u8, slash, under));
    try std.testing.expectEqualStrings("enemy_s_patrol", slash);
    try std.testing.expectEqualStrings("enemy_u_patrol", under);
}

test "pathToIdent: nested path vs underscore variant do not collide" {
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    // `a/b/c` vs `a/b_c` — pre-fix both became `a_b_c`.
    try std.testing.expect(!std.mem.eql(
        u8,
        pathToIdent("a/b/c", &a),
        pathToIdent("a/b_c", &b),
    ));
}

test "pathToIdent: dot and plus map to distinct escapes" {
    var d: [256]u8 = undefined;
    var p: [256]u8 = undefined;
    var s: [256]u8 = undefined;
    try std.testing.expectEqualStrings("a_d_b", pathToIdent("a.b", &d));
    try std.testing.expectEqualStrings("a_p_b", pathToIdent("a+b", &p));
    try std.testing.expectEqualStrings("a_s_b", pathToIdent("a/b", &s));
    // ...and none of them collide with each other.
    try std.testing.expect(!std.mem.eql(u8, pathToIdent("a.b", &d), pathToIdent("a+b", &p)));
}

test "pathToIdent: a leading digit is prefixed to stay a valid identifier" {
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    // `2x2_tile` would otherwise emit `2x2_u_tile`, which Zig rejects
    // as an identifier. The `_` prefix keeps it valid.
    try std.testing.expectEqualStrings("_2x2_u_tile", pathToIdent("2x2_tile", &a));
    // The prefix must not collapse two distinct digit-leading paths.
    try std.testing.expect(!std.mem.eql(
        u8,
        pathToIdent("0a", &a),
        pathToIdent("1a", &b),
    ));
}

test "pathToIdent: every distinct path yields a distinct identifier" {
    const cases = [_][]const u8{
        "enemy/patrol",
        "enemy_patrol",
        "enemy.patrol",
        "enemy+patrol",
        "a/b/c",
        "a/b_c",
        "a_b/c",
        "a/b.c",
        ".plugin_core/script",
        "plugin_core/script",
    };
    var bufs: [cases.len][256]u8 = undefined;
    var id_list: [cases.len][]const u8 = undefined;
    for (cases, 0..) |c, i| id_list[i] = pathToIdent(c, &bufs[i]);
    for (id_list, 0..) |x, i| {
        for (id_list[i + 1 ..]) |y| {
            try std.testing.expect(!std.mem.eql(u8, x, y));
        }
    }
}

test "pathToIdent: leading dot from plugin scripts stays a valid identifier" {
    var buf: [256]u8 = undefined;
    const ident = pathToIdent(".plugin_core/patrol", &buf);
    // Must not begin with `.` and the first byte must be a valid identifier start.
    try std.testing.expect(ident[0] == '_');
    try std.testing.expectEqualStrings("_d_plugin_u_core_s_patrol", ident);
}
