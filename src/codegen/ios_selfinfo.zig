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
//!     the build target's `os.tag == .ios` (or `!= .ios`) — the receiver
//!     `@import("builtin")[.target]`, or a root identifier bound to it
//!     (#784) — only the branch iOS takes is checked; otherwise EVERY
//!     branch must have it (a missing `else` fails). Names compare as the
//!     identifiers they spell: `@"debug"` is `debug` (#785);
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
        if (try identIs(arena, tree, vd.ast.mut_token + 1, "debug")) try found.append(arena, vd);
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
    if (!try iosValueHasSelfInfo(arena, tree, init)) return .{ .incompatible = try std.fmt.allocPrint(arena, "the root `debug` (line {d}) has no direct `pub const SelfInfo` in the value iOS selects", .{line}) };
    return .provided;
}

fn lineOf(tree: Ast, tok: Ast.TokenIndex) usize {
    return tree.tokenLocation(0, tok).line + 1;
}

/// Whether `node`, evaluated on iOS, is a struct literal with a direct
/// `pub const SelfInfo`. Conservative: anything it cannot see through
/// (an `@import`, an identifier, a call) is `false`.
fn iosValueHasSelfInfo(arena: std.mem.Allocator, tree: Ast, node: Ast.Node.Index) error{OutOfMemory}!bool {
    if (tree.nodeTag(node) == .grouped_expression) return iosValueHasSelfInfo(arena, tree, tree.nodeData(node).node_and_token[0]);
    var buf: [2]Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&buf, node)) |cd| {
        if (!std.mem.eql(u8, tree.tokenSlice(cd.ast.main_token), "struct")) return false;
        for (cd.ast.members) |m| {
            const vd = tree.fullVarDecl(m) orelse continue;
            if (vd.visib_token == null) continue;
            if (!std.mem.eql(u8, tree.tokenSlice(vd.ast.mut_token), "const")) continue;
            if (try identIs(arena, tree, vd.ast.mut_token + 1, "SelfInfo")) return true;
        }
        return false;
    }
    if (tree.fullIf(node)) |f| {
        const else_expr = f.ast.else_expr.unwrap();
        switch (try iosCondition(arena, tree, f.ast.cond_expr)) {
            .is_ios => return iosValueHasSelfInfo(arena, tree, f.ast.then_expr),
            .not_ios => return if (else_expr) |e| iosValueHasSelfInfo(arena, tree, e) else false,
            .unknown => {
                const e = else_expr orelse return false;
                return try iosValueHasSelfInfo(arena, tree, f.ast.then_expr) and try iosValueHasSelfInfo(arena, tree, e);
            },
        }
    }
    return false;
}

const Cond = enum { is_ios, not_ios, unknown };

/// Recognise `<target>.os.tag == .ios` / `.ios == <…>.os.tag` (and `!=`).
/// Anything else (`and`/`or`, a helper call, a different tag) is `unknown`.
fn iosCondition(arena: std.mem.Allocator, tree: Ast, node: Ast.Node.Index) error{OutOfMemory}!Cond {
    const tag = tree.nodeTag(node);
    if (tag == .grouped_expression) return iosCondition(arena, tree, tree.nodeData(node).node_and_token[0]);
    if (tag != .equal_equal and tag != .bang_equal) return .unknown;
    const lhs, const rhs = tree.nodeData(node).node_and_node;
    const matches = (try isOsTag(arena, tree, lhs) and try isIosLiteral(arena, tree, rhs)) or (try isOsTag(arena, tree, rhs) and try isIosLiteral(arena, tree, lhs));
    if (!matches) return .unknown;
    return if (tag == .equal_equal) .is_ios else .not_ios;
}

/// The BUILD TARGET's OS tag (#784): `B.target.os.tag` or `B.os.tag`, where
/// `B` is `@import("builtin")` or a root identifier bound to it. Any other
/// receiver (`settings.os.tag`, …) is not the target, so the condition it
/// appears in is `unknown`.
fn isOsTag(arena: std.mem.Allocator, tree: Ast, node: Ast.Node.Index) error{OutOfMemory}!bool {
    const os = try fieldOf(arena, tree, node, "tag") orelse return false;
    const recv = try fieldOf(arena, tree, os, "os") orelse return false;
    if (try isBuiltinRef(arena, tree, recv)) return true;
    const b = try fieldOf(arena, tree, recv, "target") orelse return false;
    return isBuiltinRef(arena, tree, b);
}

/// For `<obj>.<name>` (either spelling of `name`), `obj`; otherwise null.
fn fieldOf(arena: std.mem.Allocator, tree: Ast, node: Ast.Node.Index, name: []const u8) error{OutOfMemory}!?Ast.Node.Index {
    const n = unparen(tree, node);
    if (tree.nodeTag(n) != .field_access) return null;
    const obj, const field = tree.nodeData(n).node_and_token;
    return if (try identIs(arena, tree, field, name)) obj else null;
}

fn unparen(tree: Ast, node: Ast.Node.Index) Ast.Node.Index {
    var n = node;
    while (tree.nodeTag(n) == .grouped_expression) n = tree.nodeData(n).node_and_token[0];
    return n;
}

/// `@import("builtin")`, or an identifier that a root `const` binds to it.
/// The `debug` value is evaluated at root, so root decls are its scope.
fn isBuiltinRef(arena: std.mem.Allocator, tree: Ast, node: Ast.Node.Index) error{OutOfMemory}!bool {
    const n = unparen(tree, node);
    if (try isImportBuiltin(arena, tree, n)) return true;
    if (tree.nodeTag(n) != .identifier) return false;
    const ident = try identName(arena, tree, tree.nodeMainToken(n));
    for (tree.rootDecls()) |d| {
        const vd = tree.fullVarDecl(d) orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(vd.ast.mut_token), "const")) continue;
        if (!try identIs(arena, tree, vd.ast.mut_token + 1, ident)) continue;
        const init = vd.ast.init_node.unwrap() orelse return false;
        return isImportBuiltin(arena, tree, unparen(tree, init));
    }
    return false;
}

fn isImportBuiltin(arena: std.mem.Allocator, tree: Ast, node: Ast.Node.Index) error{OutOfMemory}!bool {
    var buf: [2]Ast.Node.Index = undefined;
    const params = tree.builtinCallParams(&buf, node) orelse return false;
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) return false;
    if (params.len != 1 or tree.nodeTag(params[0]) != .string_literal) return false;
    const path = try decode(arena, tree.tokenSlice(tree.nodeMainToken(params[0]))) orelse return false;
    return std.mem.eql(u8, path, "builtin");
}

/// `.ios`.
fn isIosLiteral(arena: std.mem.Allocator, tree: Ast, node: Ast.Node.Index) error{OutOfMemory}!bool {
    return tree.nodeTag(node) == .enum_literal and try identIs(arena, tree, tree.nodeMainToken(node), "ios");
}

/// Whether identifier token `tok` names `name`, reading `@"…"` as the
/// identifier it spells (#785): `@"debug"` IS `debug`.
fn identIs(arena: std.mem.Allocator, tree: Ast, tok: Ast.TokenIndex, name: []const u8) error{OutOfMemory}!bool {
    return std.mem.eql(u8, try identName(arena, tree, tok), name);
}

/// The identifier token `tok` spells: `@"…"` decoded (no length limit), a
/// bare identifier as-is. A quoted one that does not decode is returned raw
/// (it will not compile anyway, and equals no real name).
fn identName(arena: std.mem.Allocator, tree: Ast, tok: Ast.TokenIndex) error{OutOfMemory}![]const u8 {
    const s = tree.tokenSlice(tok);
    if (!std.mem.startsWith(u8, s, "@\"")) return s;
    return try decode(arena, s[1..]) orelse s;
}

/// Decode the string literal `quoted` (with its quotes), or null if invalid.
fn decode(arena: std.mem.Allocator, quoted: []const u8) error{OutOfMemory}!?[]const u8 {
    return std.zig.string_literal.parseAlloc(arena, quoted) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
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

test "judge: only the build target's os.tag selects the iOS branch (#784)" {
    const T = std.meta.Tag(Verdict);
    // A non-builtin `.os.tag` is an unknown condition: SelfInfo in one branch fails.
    try testing.expectEqual(T.incompatible, try judgeTag("const settings = @import(\"settings.zig\");\npub const debug = if (settings.os.tag == .ios) struct { pub const SelfInfo = void; } else struct {};"));
    try testing.expectEqual(T.incompatible, try judgeTag("pub const debug = if (settings.target.os.tag == .ios) struct { pub const SelfInfo = void; } else struct {};"));
    try testing.expectEqual(T.incompatible, try judgeTag("pub const debug = if (@import(\"settings\").os.tag == .ios) struct { pub const SelfInfo = void; } else struct {};"));
    // `builtin` not bound to @import("builtin") in this file is not the target.
    try testing.expectEqual(T.incompatible, try judgeTag("pub const debug = if (builtin.os.tag == .ios) struct { pub const SelfInfo = void; } else struct {};"));
    try testing.expectEqual(T.incompatible, try judgeTag("const builtin = @import(\"my_builtin.zig\");\npub const debug = if (builtin.target.os.tag == .ios) struct { pub const SelfInfo = void; } else struct {};"));
    // ...but in every branch it is fine.
    try testing.expectEqual(T.provided, try judgeTag("pub const debug = if (settings.os.tag == .ios) struct { pub const SelfInfo = void; } else struct { pub const SelfInfo = void; };"));
    // The real builtin forms still select the iOS branch.
    try testing.expectEqual(T.provided, try judgeTag("pub const debug = if (@import(\"builtin\").os.tag == .ios) struct { pub const SelfInfo = void; } else struct {};"));
    try testing.expectEqual(T.provided, try judgeTag("const builtin = @import(\"builtin\");\npub const debug = if (builtin.target.os.tag == .ios) struct { pub const SelfInfo = void; } else struct {};"));
    try testing.expectEqual(T.provided, try judgeTag("pub const debug = if (bi.os.tag == .ios) struct { pub const SelfInfo = void; } else struct {};\nconst bi = @import(\"builtin\");"));
    try testing.expectEqual(T.provided, try judgeTag("const @\"builtin\" = @import(\"builtin\");\npub const debug = if (builtin.os.tag == .ios) struct { pub const SelfInfo = void; } else struct {};"));
}

test "judge: a quoted builtin binding longer than 256 bytes still selects the iOS branch" {
    const T = std.meta.Tag(Verdict);
    const long = "b" ** 300;
    // Bound quoted, referenced quoted; and bound bare, referenced quoted.
    try testing.expectEqual(T.provided, try judgeTag("const @\"" ++ long ++ "\" = @import(\"builtin\");\npub const debug = if (@\"" ++ long ++ "\".target.os.tag == .ios) struct { pub const SelfInfo = void; } else struct {};"));
    try testing.expectEqual(T.provided, try judgeTag("const " ++ long ++ " = @import(\"builtin\");\npub const debug = if (@\"" ++ long ++ "\".os.tag == .ios) struct { pub const SelfInfo = void; } else struct {};"));
    // `SelfInfo` in ONE arm is only accepted when the condition is recognised
    // (an unknown one needs it in both), so these pass only via selection.
    try testing.expectEqual(T.provided, try judgeTag("const @\"" ++ long ++ "\" = @import(\"builtin\");\npub const debug = if (@\"" ++ long ++ "\".os.tag != .ios) struct {} else struct { pub const SelfInfo = void; };"));
    // A long name differing only in its last byte is not the binding.
    try testing.expectEqual(T.incompatible, try judgeTag("const @\"" ++ long ++ "\" = @import(\"builtin\");\npub const debug = if (@\"" ++ long[1..] ++ "c\".os.tag == .ios) struct { pub const SelfInfo = void; } else struct {};"));
}

test "judge: quoted @\"debug\" / @\"SelfInfo\" identifiers (#785)" {
    const T = std.meta.Tag(Verdict);
    try testing.expectEqual(T.provided, try judgeTag("pub const @\"debug\" = struct { pub const SelfInfo = void; };"));
    try testing.expectEqual(T.provided, try judgeTag("pub const debug = struct { pub const @\"SelfInfo\" = void; };"));
    try testing.expectEqual(T.provided, try judgeTag("pub const @\"debug\" = struct { pub const @\"SelfInfo\" = void; };"));
    try testing.expectEqual(T.incompatible, try judgeTag("pub const @\"debug\" = struct {};"));
    try testing.expectEqual(T.duplicate, try judgeTag("pub const debug = struct { pub const SelfInfo = void; };\npub const @\"debug\" = struct { pub const SelfInfo = void; };"));
    // A different quoted name is not `debug`.
    try testing.expectEqual(T.absent, try judgeTag("pub const @\"debug2\" = struct {};"));
}

test "finalize: a quoted root debug is accepted, a quoted duplicate is rejected (#785)" {
    const a = testing.allocator;
    const src = "pub const @\"debug\" = struct { pub const @\"SelfInfo\" = void; };\n";
    const out = try finalize(a, SLOT ++ src);
    defer a.free(out);
    try testing.expectEqualStrings(src, out);
    try testing.expect(std.mem.indexOf(u8, out, "pub const debug") == null);
    try testing.expectError(error.IosDuplicateRootDebug, finalize(a, SLOT ++ "pub const debug = struct { pub const SelfInfo = void; };\n" ++ src));
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
