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
//! A root `debug` declared twice is a compile error, so the override is
//! skipped when the backend's entry template (or the engine template)
//! already declares a root `debug`; that template then owns it. Backends
//! may drop their own copy once they require an assembler that emits it.

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

/// True when `source` (a Zig source or a `{{hole}}` template) declares a
/// ROOT-level `const`/`var` named `name`. Uses the Zig tokenizer with a
/// brace-depth count, so a comment, a string, a nested decl
/// (`struct { const debug = … }`) or `debug_draw` does not count. Template
/// holes (`{{x}}`) tokenize as balanced braces.
pub fn declaresRootDecl(allocator: std.mem.Allocator, source: []const u8, name: []const u8) !bool {
    const z = try allocator.dupeZ(u8, source);
    defer allocator.free(z);
    var tokenizer = std.zig.Tokenizer.init(z);
    var depth: usize = 0;
    var prev: std.zig.Token.Tag = .eof;
    while (true) {
        const tok = tokenizer.next();
        switch (tok.tag) {
            .eof => return false,
            .l_brace => depth += 1,
            .r_brace => depth -|= 1,
            .identifier => if (depth == 0 and (prev == .keyword_const or prev == .keyword_var) and
                std.mem.eql(u8, z[tok.loc.start..tok.loc.end], name)) return true,
            else => {},
        }
        prev = tok.tag;
    }
}

test "declaresRootDecl: root decls only" {
    const a = std.testing.allocator;
    try std.testing.expect(try declaresRootDecl(a, "pub const debug = struct { pub const SelfInfo = void; };", "debug"));
    try std.testing.expect(try declaresRootDecl(a, "{{module_vars}}\nconst debug = if (x) struct {} else struct {};", "debug"));
    try std.testing.expect(!try declaresRootDecl(a, "pub const debug_draw = 1;", "debug"));
    try std.testing.expect(!try declaresRootDecl(a, "// pub const debug = struct {};\nconst s = \"pub const debug\";", "debug"));
    try std.testing.expect(!try declaresRootDecl(a, "const S = struct { const debug = 1; };", "debug"));
    try std.testing.expect(!try declaresRootDecl(a, "fn f() void { std.debug.print(\"\", .{}); }", "debug"));
}
