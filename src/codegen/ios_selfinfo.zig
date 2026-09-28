//! Zig 0.16 `std.debug.SelfInfo` override for iOS (labelle-assembler#774).
//!
//! Zig 0.16's default Mach-O `std.debug.SelfInfo`
//! (`std/debug/SelfInfo/MachO.zig`) calls
//! `_dyld_get_image_header_containing_address`, which the iOS SDK does not
//! export, so any panic or stack-trace path fails to LINK on iOS. A root
//! `pub const debug` whose iOS value has `pub const SelfInfo = void` opts the
//! program out of self-debug-info (traces print without symbols). The
//! assembler guarantees every iOS `main.zig` has exactly one such decl.
//!
//! ## Ownership is decided on the RENDERED main.zig
//!
//! A backend entry template (labelle-sokol v0.8.1's `mobile.txt`) or the
//! engine template may already declare a root `debug`, and a second one is
//! a compile error. Deciding from the raw templates was wrong (a decl inside
//! a `{{#if}}` block that renders away still "counted"), so the codegen
//! renders `SLOT` where the override belongs and `finalize` judges the
//! FINAL text, parsed with `std.zig.Ast`:
//!
//!   * no root `debug` → `SLOT` becomes `OVERRIDE`;
//!   * exactly one root `pub const debug` whose iOS value is a struct with a
//!     DIRECT `pub const SelfInfo` → accepted; `SLOT` is removed. For
//!     `if (<cond>) A else B`: when `<cond>` is recognisably
//!     `….os.tag == .ios` (or `!= .ios`) only the branch iOS takes is
//!     checked; otherwise EVERY branch must have it (a missing `else` fails);
//!   * a non-`pub` root `debug`, or one whose iOS value has no direct
//!     `pub const SelfInfo` (a private one, one in a nested type, an
//!     `@import`, …) → `error.IosRootDebugWithoutSelfInfo`: a second root
//!     `debug` cannot be added, and skipping would leave the link broken;
//!   * more than one root `debug` → `error.IosDuplicateRootDebug`.
//!
//! Backends may drop their own copy once they require an assembler that
//! emits it.

const std = @import("std");
const Ast = std.zig.Ast;

/// The placeholder the codegen writes (iOS only) where `OVERRIDE` goes. A
/// line comment, so it is inert for the parser `finalize` runs.
pub const SLOT = "// @labelle-assembler:ios-selfinfo-slot@\n";

/// Emitted at module root on an iOS generate. The `os.tag` guard keeps it
/// inert should the file ever be compiled for another target.
pub const OVERRIDE =
    \\
    \\// Zig 0.16 on iOS (labelle-assembler#774): the default Mach-O
    \\// `std.debug.SelfInfo` calls `_dyld_get_image_header_containing_address`,
    \\// which the iOS SDK does not export, so any panic/stack-trace path fails to
    \\// LINK. `void` opts out of self-debug-info (traces print without symbols).
    \\pub const debug = if (@import("builtin").target.os.tag == .ios) struct {
    \\    pub const SelfInfo = void;
    \\} else struct {};
    \\
;

pub const Verdict = union(enum) {
    /// No root `debug`: emit `OVERRIDE`.
    absent,
    /// One compatible root `debug`: emit nothing.
    provided,
    /// A root `debug` that cannot serve (the payload says why, with its line).
    incompatible: []const u8,
    /// Two or more root `debug` decls (the payload names their lines).
    duplicate: []const u8,
};

/// Judge the rendered `source`'s root `debug` decls. Strings in the result
/// are owned by `arena`. A source that does not parse is judged `.absent`:
/// it will not compile anyway, and the compiler's own error is the useful
/// one.
pub fn judge(arena: std.mem.Allocator, source: []const u8) !Verdict {
    const z = try arena.dupeZ(u8, source);
    var tree = try Ast.parse(arena, z, .zig);
    if (tree.errors.len != 0) return .absent;

    var found: std.ArrayList(Ast.full.VarDecl) = .empty;
    for (tree.rootDecls()) |node| {
        const vd = tree.fullVarDecl(node) orelse continue;
        if (std.mem.eql(u8, tree.tokenSlice(vd.ast.mut_token + 1), "debug")) try found.append(arena, vd);
    }
    if (found.items.len == 0) return .absent;
    if (found.items.len > 1) {
        var lines: std.ArrayList(u8) = .empty;
        for (found.items, 0..) |vd, i| try lines.print(arena, "{s}{d}", .{ if (i == 0) "" else ", ", lineOf(tree, vd.ast.mut_token) });
        return .{ .duplicate = lines.items };
    }
    const vd = found.items[0];
    const line = lineOf(tree, vd.ast.mut_token);
    if (vd.visib_token == null) return .{ .incompatible = try std.fmt.allocPrint(arena, "the root `debug` (line {d}) is not `pub`, so std cannot read it", .{line}) };
    if (!std.mem.eql(u8, tree.tokenSlice(vd.ast.mut_token), "const")) return .{ .incompatible = try std.fmt.allocPrint(arena, "the root `debug` (line {d}) is a `var`, not a `pub const`", .{line}) };
    const init = vd.ast.init_node.unwrap() orelse return .{ .incompatible = try std.fmt.allocPrint(arena, "the root `debug` (line {d}) has no value", .{line}) };
    if (!iosValueHasSelfInfo(tree, init)) return .{ .incompatible = try std.fmt.allocPrint(arena, "the root `debug` (line {d}) has no direct `pub const SelfInfo` in the value iOS selects", .{line}) };
    return .provided;
}

fn lineOf(tree: Ast, tok: Ast.TokenIndex) usize {
    return tree.tokenLocation(0, tok).line + 1;
}

/// Whether `node`, evaluated on iOS, is a struct literal with a direct
/// `pub const SelfInfo`. Conservative: anything it cannot see through
/// (an `@import`, an identifier, a call) is `false`.
fn iosValueHasSelfInfo(tree: Ast, node: Ast.Node.Index) bool {
    if (tree.nodeTag(node) == .grouped_expression) return iosValueHasSelfInfo(tree, tree.nodeData(node).node_and_token[0]);
    var buf: [2]Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&buf, node)) |cd| {
        if (!std.mem.eql(u8, tree.tokenSlice(cd.ast.main_token), "struct")) return false;
        for (cd.ast.members) |m| {
            const vd = tree.fullVarDecl(m) orelse continue;
            if (vd.visib_token == null) continue;
            if (!std.mem.eql(u8, tree.tokenSlice(vd.ast.mut_token), "const")) continue;
            if (std.mem.eql(u8, tree.tokenSlice(vd.ast.mut_token + 1), "SelfInfo")) return true;
        }
        return false;
    }
    if (tree.fullIf(node)) |f| {
        const else_expr = f.ast.else_expr.unwrap();
        switch (iosCondition(tree, f.ast.cond_expr)) {
            .is_ios => return iosValueHasSelfInfo(tree, f.ast.then_expr),
            .not_ios => return if (else_expr) |e| iosValueHasSelfInfo(tree, e) else false,
            .unknown => {
                const e = else_expr orelse return false;
                return iosValueHasSelfInfo(tree, f.ast.then_expr) and iosValueHasSelfInfo(tree, e);
            },
        }
    }
    return false;
}

const Cond = enum { is_ios, not_ios, unknown };

/// Recognise `<…>.os.tag == .ios` / `.ios == <…>.os.tag` (and `!=`).
/// Anything else (`and`/`or`, a helper call, a different tag) is `unknown`.
fn iosCondition(tree: Ast, node: Ast.Node.Index) Cond {
    const tag = tree.nodeTag(node);
    if (tag == .grouped_expression) return iosCondition(tree, tree.nodeData(node).node_and_token[0]);
    if (tag != .equal_equal and tag != .bang_equal) return .unknown;
    const lhs, const rhs = tree.nodeData(node).node_and_node;
    const matches = (isOsTag(tree, lhs) and isIosLiteral(tree, rhs)) or (isOsTag(tree, rhs) and isIosLiteral(tree, lhs));
    if (!matches) return .unknown;
    return if (tag == .equal_equal) .is_ios else .not_ios;
}

/// `<anything>.os.tag`.
fn isOsTag(tree: Ast, node: Ast.Node.Index) bool {
    if (tree.nodeTag(node) != .field_access) return false;
    const obj, const field = tree.nodeData(node).node_and_token;
    if (!std.mem.eql(u8, tree.tokenSlice(field), "tag")) return false;
    if (tree.nodeTag(obj) != .field_access) return false;
    return std.mem.eql(u8, tree.tokenSlice(tree.nodeData(obj).node_and_token[1]), "os");
}

/// `.ios`.
fn isIosLiteral(tree: Ast, node: Ast.Node.Index) bool {
    return tree.nodeTag(node) == .enum_literal and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "ios");
}

pub const Error = error{ IosRootDebugWithoutSelfInfo, IosDuplicateRootDebug };

/// Resolve `SLOT` in the rendered iOS `main.zig` per `judge`. Returns the
/// final text (owned by `allocator`); on an incompatible or duplicate root
/// `debug`, writes a diagnostic to stderr and returns the error.
pub fn finalize(allocator: std.mem.Allocator, rendered: []const u8) ![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const verdict = try judge(arena, rendered);
    const replacement: []const u8 = switch (verdict) {
        .absent => OVERRIDE,
        .provided => "",
        .incompatible => |why| {
            printErr(arena, "labelle-assembler: the generated iOS main.zig declares a root `debug`, but {s}.\n" ++
                "  An iOS build needs `pub const debug` with `pub const SelfInfo = void` (Zig 0.16's Mach-O SelfInfo references a\n" ++
                "  symbol the iOS SDK does not export), and the assembler cannot add a second root `debug`. Fix the backend/engine\n" ++
                "  template that declares it (add `pub const SelfInfo = void;` to the struct iOS selects), or remove it and let the\n" ++
                "  assembler emit it (#774).\n", .{why});
            return error.IosRootDebugWithoutSelfInfo;
        },
        .duplicate => |lines| {
            printErr(arena, "labelle-assembler: the generated iOS main.zig declares more than one root `debug` (lines {s}).\n" ++
                "  The backend entry template and the engine template are rendered into the same file; exactly one may own\n" ++
                "  `debug.SelfInfo` — drop it from the backend template (#774).\n", .{lines});
            return error.IosDuplicateRootDebug;
        },
    };
    const at = std.mem.indexOf(u8, rendered, SLOT) orelse {
        // No slot (a template without the hook-imports hole): nothing to
        // resolve, but an absent `debug` is still the assembler's to add.
        if (replacement.len == 0) return allocator.dupe(u8, rendered);
        return std.mem.concat(allocator, u8, &.{ rendered, replacement });
    };
    return std.mem.concat(allocator, u8, &.{ rendered[0..at], replacement, rendered[at + SLOT.len ..] });
}

fn printErr(arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(arena, fmt, args) catch return;
    std.Io.File.stderr().writeStreamingAll(@import("../config.zig").globalIo(), msg) catch {};
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn judgeTag(src: []const u8) !std.meta.Tag(Verdict) {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    return std.meta.activeTag(try judge(arena.allocator(), src));
}

test "judge: none / provided / incompatible / duplicate" {
    const T = std.meta.Tag(Verdict);
    // None.
    try testing.expectEqual(T.absent, try judgeTag("const std = @import(\"std\");\nconst debug_draw = 1;\nfn f() void { std.debug.print(\"\", .{}); }\nconst S = struct { const debug = 1; };"));
    // Provided: plain struct, and the conditional form with the iOS arm first.
    try testing.expectEqual(T.provided, try judgeTag("pub const debug = struct { pub const SelfInfo = void; };"));
    try testing.expectEqual(T.provided, try judgeTag("pub const debug = if (@import(\"builtin\").target.os.tag == .ios) struct {\n    pub const SelfInfo = void;\n} else struct {};"));
    try testing.expectEqual(T.provided, try judgeTag("const builtin = @import(\"builtin\");\npub const debug = if (builtin.os.tag != .ios) struct {} else struct { pub const SelfInfo = void; };"));
    try testing.expectEqual(T.provided, try judgeTag("pub const debug = if (.ios == @import(\"builtin\").os.tag) struct { pub const SelfInfo = void; } else struct {};"));
    // Unrecognisable condition: every branch must have it.
    try testing.expectEqual(T.provided, try judgeTag("pub const debug = if (want()) struct { pub const SelfInfo = void; } else struct { pub const SelfInfo = void; };"));
    try testing.expectEqual(T.incompatible, try judgeTag("pub const debug = if (want()) struct { pub const SelfInfo = void; } else struct {};"));
    try testing.expectEqual(T.incompatible, try judgeTag("pub const debug = if (want()) struct { pub const SelfInfo = void; };"));
    // The wrong branch: SelfInfo only where iOS does NOT go.
    try testing.expectEqual(T.incompatible, try judgeTag("pub const debug = if (@import(\"builtin\").target.os.tag == .ios) struct {} else struct { pub const SelfInfo = void; };"));
    // Private root `debug`, private / nested / var SelfInfo, opaque values.
    try testing.expectEqual(T.incompatible, try judgeTag("const debug = struct { pub const SelfInfo = void; };"));
    try testing.expectEqual(T.incompatible, try judgeTag("pub var debug = struct { pub const SelfInfo = void; };"));
    try testing.expectEqual(T.incompatible, try judgeTag("pub const debug = struct { const SelfInfo = void; };"));
    try testing.expectEqual(T.incompatible, try judgeTag("pub const debug = struct { pub const Inner = struct { pub const SelfInfo = void; }; };"));
    try testing.expectEqual(T.incompatible, try judgeTag("pub const debug = @import(\"my_debug.zig\");"));
    // Duplicates.
    try testing.expectEqual(T.duplicate, try judgeTag("pub const debug = struct { pub const SelfInfo = void; };\npub const debug = struct { pub const SelfInfo = void; };"));
}

test "finalize: the slot becomes the override, disappears, or the call fails" {
    const a = testing.allocator;
    const absent = try finalize(a, "const std = @import(\"std\");\n" ++ SLOT ++ "fn f() void {}\n");
    defer a.free(absent);
    try testing.expectEqualStrings("const std = @import(\"std\");\n" ++ OVERRIDE ++ "fn f() void {}\n", absent);
    const provided = try finalize(a, SLOT ++ "pub const debug = struct { pub const SelfInfo = void; };\n");
    defer a.free(provided);
    try testing.expectEqualStrings("pub const debug = struct { pub const SelfInfo = void; };\n", provided);
    try testing.expectError(error.IosRootDebugWithoutSelfInfo, finalize(a, SLOT ++ "const debug = struct { pub const SelfInfo = void; };\n"));
    try testing.expectError(error.IosDuplicateRootDebug, finalize(a, SLOT ++ "pub const debug = struct { pub const SelfInfo = void; };\npub const debug = struct {};\n"));
}
