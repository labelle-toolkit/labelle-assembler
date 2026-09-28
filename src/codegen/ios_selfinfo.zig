//! Zig 0.16 `std.debug.SelfInfo` override for iOS (labelle-assembler#774).
//!
//! Zig 0.16's default Mach-O `std.debug.SelfInfo`
//! (`std/debug/SelfInfo/MachO.zig`) calls
//! `_dyld_get_image_header_containing_address`, which the iOS SDK does not
//! export, so any panic or stack-trace path fails to LINK on iOS. A root
//! `debug.SelfInfo = void` opts the program out of self-debug-info (traces
//! print without symbols). The assembler emits it at the root of every iOS
//! `main.zig`, so every iOS backend gets it — not only the ones whose entry
//! template carries its own copy (labelle-sokol v0.8.1's `mobile.txt`).
//!
//! A root `debug` declared twice is a compile error, so the templates'
//! root `debug` decides (`rootDebugState`):
//!   * none → the assembler emits `OVERRIDE`;
//!   * one that declares `SelfInfo` (labelle-sokol v0.8.1's `mobile.txt`)
//!     → the template owns the override; the assembler emits nothing;
//!   * one WITHOUT `SelfInfo` → generate fails (`error.IosRootDebugWithoutSelfInfo`):
//!     the assembler cannot add a second `debug`, and skipping would leave
//!     the iOS link broken. The backend must declare `SelfInfo` in its
//!     `debug` (or drop its `debug`).
//! Backends may drop their own copy once they require an assembler that
//! emits it.

const std = @import("std");

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

pub const RootDebug = enum {
    /// No root `debug`: the assembler emits `OVERRIDE`.
    absent,
    /// A root `debug` that declares `SelfInfo` somewhere inside it: the
    /// template owns the override.
    with_selfinfo,
    /// A root `debug` with no `SelfInfo`: a second `debug` cannot be added,
    /// so generate must fail.
    without_selfinfo,
};

/// Classify `source`'s (a Zig source or a `{{hole}}` template) ROOT-level
/// `const`/`var debug`. Tokenizer-based with a brace-depth count, so a
/// comment, a string, a nested decl (`struct { const debug = … }`) or
/// `debug_draw` is not a root `debug`. The decl runs to its `;` at root
/// depth; it declares `SelfInfo` when a `const`/`var SelfInfo` appears
/// anywhere inside it (either arm of an `if … struct {…} else struct {}`).
/// Template holes (`{{x}}`) tokenize as balanced braces.
pub fn rootDebugState(allocator: std.mem.Allocator, source: []const u8) !RootDebug {
    const z = try allocator.dupeZ(u8, source);
    defer allocator.free(z);
    var tokenizer = std.zig.Tokenizer.init(z);
    var depth: usize = 0;
    var prev: std.zig.Token.Tag = .eof;
    var in_debug = false;
    var debug_depth: usize = 0;
    var result: RootDebug = .absent;
    while (true) {
        const tok = tokenizer.next();
        switch (tok.tag) {
            .eof => return result,
            .l_brace => depth += 1,
            .r_brace => depth -|= 1,
            .semicolon => if (in_debug and depth == debug_depth) {
                in_debug = false;
            },
            .identifier => {
                const text = z[tok.loc.start..tok.loc.end];
                const is_decl = prev == .keyword_const or prev == .keyword_var;
                if (!in_debug and depth == 0 and is_decl and std.mem.eql(u8, text, "debug")) {
                    in_debug = true;
                    debug_depth = depth;
                    if (result == .absent) result = .without_selfinfo;
                } else if (in_debug and is_decl and std.mem.eql(u8, text, "SelfInfo")) {
                    result = .with_selfinfo;
                }
            },
            else => {},
        }
        prev = tok.tag;
    }
}

/// True when `source` declares a ROOT-level `debug` (of any shape).
pub fn declaresRootDecl(allocator: std.mem.Allocator, source: []const u8) !bool {
    return (try rootDebugState(allocator, source)) != .absent;
}

test "rootDebugState: absent / with SelfInfo / without SelfInfo" {
    const a = std.testing.allocator;
    const S = RootDebug;
    try std.testing.expectEqual(S.with_selfinfo, try rootDebugState(a, "pub const debug = struct { pub const SelfInfo = void; };"));
    try std.testing.expectEqual(S.with_selfinfo, try rootDebugState(a, "{{module_vars}}\npub const debug = if (@import(\"builtin\").target.os.tag == .ios) struct {\n    pub const SelfInfo = void;\n} else struct {};\nconst after = 1;"));
    try std.testing.expectEqual(S.without_selfinfo, try rootDebugState(a, "pub const debug = struct { pub const other = 1; };"));
    try std.testing.expectEqual(S.without_selfinfo, try rootDebugState(a, "const debug = @import(\"my_debug.zig\");"));
    // `SelfInfo` OUTSIDE the root `debug` does not make it compatible.
    try std.testing.expectEqual(S.without_selfinfo, try rootDebugState(a, "const debug = struct {};\nconst X = struct { const SelfInfo = void; };"));
    // Not a root `debug`.
    try std.testing.expectEqual(S.absent, try rootDebugState(a, "pub const debug_draw = 1;"));
    try std.testing.expectEqual(S.absent, try rootDebugState(a, "// pub const debug = struct {};\nconst s = \"pub const debug\";"));
    try std.testing.expectEqual(S.absent, try rootDebugState(a, "const S = struct { const debug = struct { const SelfInfo = void; }; };"));
    try std.testing.expectEqual(S.absent, try rootDebugState(a, "fn f() void { std.debug.print(\"\", .{}); }"));
}
