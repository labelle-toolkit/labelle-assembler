//! Small, allocation-free string helpers used by the main.zig generator
//! to derive Zig identifiers and to escape strings for emission.
//!
//! Extracted from `src/main_zig.zig` as the second step of the cut plan
//! in `docs/REFACTOR-PLAN-main-zig.md` (labelle-assembler#183). These
//! are pure leaf utilities — no allocations, no I/O, no template state
//! — that several upcoming submodules (`validate.zig`, the per-block
//! emitters, the lifecycle builders) will reach through this single
//! module rather than re-importing back from `main_zig.zig`.
//!
//! Companion identifier helpers `pathToIdent` and `sanitizePluginIdent`
//! live in `codegen/scan.zig` because they were already moved alongside
//! the discovery passes that consume them in the PoC extraction. Keeping
//! them there avoids a churn-only second move; this file is only the
//! helpers that did NOT travel with scan.

const std = @import("std");

/// Strip the leading dot from a path extension. `".wav"` → `"wav"`,
/// `""` / `"."` → `""`. Matches the contract of
/// `Game.registerSoundFromMemory` / `registerFontFromMemory`'s
/// `file_type` parameter (lower-case extension without the dot).
pub fn extWithoutDot(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (ext.len <= 1) return "";
    return ext[1..];
}

/// Returns true iff `name` is a valid bare Zig identifier — first
/// character `[A-Za-z_]`, rest `[A-Za-z0-9_]`. Doesn't reject Zig
/// keywords; in practice resource names like `fn` are vanishingly
/// rare and the resulting compile error names the line clearly.
///
/// Font resources need this guard because `emitResourceLoad` for
/// `.font` interpolates the resource name into Zig identifier
/// positions (`{name}_ranges`, `{name}_params`) — a hyphenated name
/// like `"ui-font"` would generate `const ui-font_ranges = ...`, which
/// is uncompilable. Atlas + sound emissions only place names inside
/// string literals so they're unaffected. Bugbot caught the gap on
/// #105.
pub fn isValidZigIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    const first = name[0];
    const first_ok = (first >= 'A' and first <= 'Z') or (first >= 'a' and first <= 'z') or first == '_';
    if (!first_ok) return false;
    for (name[1..]) |c| {
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
        if (!ok) return false;
    }
    return true;
}

/// Write a Zig double-quoted string literal for `s`, escaping `\` and `"` so
/// that asset names or scene names containing those characters produce valid
/// generated source rather than a compile error.
pub fn writeZigString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

/// Derive a PascalCase type name from a script/component path:
/// `jump_anim` -> `JumpAnim`, `enemy/patrol` -> `EnemyPatrol`,
/// `health.zig` -> `Health`. Every non-alphanumeric byte (`_`, `/`,
/// `.`, `+`, …) is treated as a word boundary.
///
/// Distinct from `pathToIdent`, which builds a *unique* identifier
/// (issue #172) and so must *escape* separators rather than collapse
/// them — feeding `pathToIdent`'s output here would turn `jump_anim`
/// into `JumpUAnim` (the `_u_` underscore-escape leaks through).
pub fn pathToPascal(name: []const u8, pascal_buf: *[128]u8) []const u8 {
    const end = if (std.mem.endsWith(u8, name, ".zig")) name.len - 4 else name.len;
    var i: usize = 0;
    var capitalize_next = true;
    for (name[0..end]) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9' => {
                if (i >= pascal_buf.len) break;
                pascal_buf[i] = if (capitalize_next) std.ascii.toUpper(c) else c;
                i += 1;
                capitalize_next = false;
            },
            else => capitalize_next = true,
        }
    }
    return pascal_buf[0..i];
}
