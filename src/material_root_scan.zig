//! Tokenized scan of `src/material_test_root.zig`, used by `build.zig`'s
//! configure-time coverage guard for `zig build test-materials` (#741).
//!
//! WHY THIS IS NOT A SUBSTRING SEARCH
//!
//! The guard originally compared the root's source against
//! `_ = @import("material_pipeline.zig");` with `std.mem.indexOf`. That
//! matches inside COMMENTS and STRING LITERALS, so commenting the import out
//! while leaving its `covered_material_modules` entry in place kept the guard
//! green (`zig build` exit 0) while the module silently dropped out of
//! `test-materials` — the exact drift the guard exists to stop. A guard you
//! can fool by commenting out the thing it guards is decorative.
//!
//! `std.zig.Tokenizer` emits no tokens for comments, so a commented-out
//! import contributes nothing. Only `@import` calls inside a TOP-LEVEL
//! `test { … }` block count: those are the ones the test binary is
//! guaranteed to analyze, which is what "covered" means here.
//!
//! A fully structural alternative — one list, no separate import lines,
//! `inline for (covered_material_modules) |m| _ = @import(m);` — does not
//! compile on Zig 0.16 (`error: @import operand must be a string literal`),
//! so the two declarations stay and are cross-checked against each other and
//! against the filesystem.

const std = @import("std");

/// What the guard learns from the root's source.
pub const Scan = struct {
    /// `@import("…")` operands appearing in ACTIVE code inside a top-level
    /// `test { … }` block.
    imports: []const []const u8,
    /// The string literals of the root's `covered_material_modules` array.
    listed: []const []const u8,
};

pub fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| {
        if (std.mem.eql(u8, h, needle)) return true;
    }
    return false;
}

/// Tokenize `source` and extract the two declarations the guard compares.
/// All allocation goes through `gpa` (an arena at the call site); slices
/// borrow `source`, which must outlive the result.
pub fn scan(gpa: std.mem.Allocator, source: []const u8) !Scan {
    const src_z = try gpa.dupeZ(u8, source);

    var toks: std.ArrayList(std.zig.Token) = .empty;
    var tz = std.zig.Tokenizer.init(src_z);
    while (true) {
        const t = tz.next();
        try toks.append(gpa, t);
        if (t.tag == .eof) break;
    }

    var imports: std.ArrayList([]const u8) = .empty;
    var listed: std.ArrayList([]const u8) = .empty;

    var depth: usize = 0;
    var test_depth: ?usize = null; // brace depth of the top-level `test` block we are in
    var list_depth: ?usize = null; // brace depth of the `covered_material_modules` initializer
    var pending_test = false;
    var pending_list = false;

    const items = toks.items;
    for (items, 0..) |t, i| {
        const text = src_z[t.loc.start..t.loc.end];
        switch (t.tag) {
            .l_brace => {
                depth += 1;
                if (pending_test) {
                    test_depth = depth;
                    pending_test = false;
                }
                if (pending_list) {
                    list_depth = depth;
                    pending_list = false;
                }
            },
            .r_brace => {
                if (test_depth) |d| {
                    if (d == depth) test_depth = null;
                }
                if (list_depth) |d| {
                    if (d == depth) list_depth = null;
                }
                depth -|= 1;
            },
            .keyword_test => {
                if (depth == 0) pending_test = true;
            },
            .identifier => {
                if (depth == 0 and std.mem.eql(u8, text, "covered_material_modules")) pending_list = true;
            },
            .semicolon => {
                // A top-level decl ended before any `{`: whatever was pending
                // was not the initializer we were waiting for.
                if (depth == 0) {
                    pending_test = false;
                    pending_list = false;
                }
            },
            .builtin => {
                if (test_depth == null) continue;
                if (!std.mem.eql(u8, text, "@import")) continue;
                if (i + 2 >= items.len) continue;
                if (items[i + 1].tag != .l_paren) continue;
                if (items[i + 2].tag != .string_literal) continue;
                const lit = src_z[items[i + 2].loc.start..items[i + 2].loc.end];
                if (plainStringBody(lit)) |name| try imports.append(gpa, name);
            },
            .string_literal => {
                if (list_depth == null) continue;
                if (plainStringBody(text)) |name| try listed.append(gpa, name);
            },
            else => {},
        }
    }

    return .{
        .imports = try imports.toOwnedSlice(gpa),
        .listed = try listed.toOwnedSlice(gpa),
    };
}

/// Body of a simple `"…"` literal, or `null` when it carries escapes —
/// module file names never do, so declining the escaped form loses nothing
/// and keeps the decode unambiguous.
fn plainStringBody(raw: []const u8) ?[]const u8 {
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return null;
    const inner = raw[1 .. raw.len - 1];
    if (std.mem.indexOfScalar(u8, inner, '\\') != null) return null;
    return inner;
}

// ── tests ────────────────────────────────────────────────────────────────

const test_root_shape =
    \\const std = @import("std");
    \\test {
    \\    _ = @import("material_pipeline.zig");
    \\    _ = @import("component_collisions.zig");
    \\}
    \\pub const covered_material_modules = [_][]const u8{
    \\    "material_pipeline.zig",
    \\};
    \\test "in-binary half" {
    \\    try std.testing.expect(covered_material_modules.len >= 1);
    \\}
;

test "scan sees active imports inside the test block and the coverage list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try scan(arena.allocator(), test_root_shape);

    // `@import("std")` is outside the test block, so it is not coverage.
    try std.testing.expect(!contains(got.imports, "std"));
    try std.testing.expect(contains(got.imports, "material_pipeline.zig"));
    try std.testing.expect(contains(got.imports, "component_collisions.zig"));
    try std.testing.expectEqual(@as(usize, 2), got.imports.len);

    try std.testing.expectEqual(@as(usize, 1), got.listed.len);
    try std.testing.expect(contains(got.listed, "material_pipeline.zig"));
}

test "a COMMENTED-OUT import is not coverage (#743 review: the substring guard accepted it)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const commented =
        \\test {
        \\    // _ = @import("material_pipeline.zig");
        \\    _ = @import("material_schema.zig");
        \\}
        \\pub const covered_material_modules = [_][]const u8{
        \\    "material_pipeline.zig",
        \\    "material_schema.zig",
        \\};
    ;
    const got = try scan(arena.allocator(), commented);

    // The mechanism, not just the value: a raw substring search DOES find the
    // commented-out line, which is why the old guard passed. The tokenizer
    // must not, while still seeing the live import beside it.
    try std.testing.expect(std.mem.indexOf(u8, commented, "_ = @import(\"material_pipeline.zig\");") != null);
    try std.testing.expect(!contains(got.imports, "material_pipeline.zig"));
    try std.testing.expect(contains(got.imports, "material_schema.zig"));

    // The list still claims it — which is precisely the disagreement the
    // guard turns into a build failure.
    try std.testing.expect(contains(got.listed, "material_pipeline.zig"));
}

test "a doc-comment or string literal mentioning an import is not coverage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const decoys =
        \\//! Once upon a time this file had _ = @import("material_ghost.zig");
        \\test {
        \\    const decoy = "_ = @import(\"material_decoy.zig\");";
        \\    _ = decoy;
        \\    _ = @import("material_real.zig");
        \\}
    ;
    const got = try scan(arena.allocator(), decoys);
    try std.testing.expect(!contains(got.imports, "material_ghost.zig"));
    try std.testing.expect(!contains(got.imports, "material_decoy.zig"));
    try std.testing.expect(contains(got.imports, "material_real.zig"));
    try std.testing.expectEqual(@as(usize, 1), got.imports.len);
}

test "imports outside a top-level test block do not count as coverage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A file-scope const is only analyzed if something references it, so it
    // is no guarantee the module's tests run.
    const got = try scan(arena.allocator(),
        \\const unused = @import("material_lazy.zig");
        \\pub fn f() void {
        \\    _ = @import("material_nested.zig");
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), got.imports.len);
    try std.testing.expectEqual(@as(usize, 0), got.listed.len);
}

test "a commented-out coverage entry is not listed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try scan(arena.allocator(),
        \\pub const covered_material_modules = [_][]const u8{
        \\    "material_build.zig",
        \\    // "material_pipeline.zig",
        \\};
    );
    try std.testing.expectEqual(@as(usize, 1), got.listed.len);
    try std.testing.expect(contains(got.listed, "material_build.zig"));
}
