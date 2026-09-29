//! Scene/prefab JSONC key classification: the one assembler-side copy of
//! the engine's key rules (labelle-assembler#651, #652).
//!
//! Every assembler walker that decides what a scene/prefab key MEANS: the
//! pack-namespace rewrite (`codegen/scan/pack_refs/{common,pass1,pass2}`),
//! the bare-name lint and `@` version gate (`scene_name_lint`), and the
//! scene manifest validator (`scene_manifest`). All of them classify through
//! this file, so they cannot drift from one another or from the engine.
//!
//! Two engine sources are mirrored byte-for-byte:
//!
//!   * **Key shapes:** labelle-engine `src/jsonc/unified_format.zig`
//!     (`isPascalCase`, `isComponentKeyShape`, `isTargetKey`,
//!     `isFlatComponentKey`). engine#806 widened flat-form content from
//!     PascalCase-only to include pack-namespaced `<prefix>__<Pascal>` keys,
//!     so a flat `rooms__Room` at entity scope is a real component (#652).
//!   * **String escapes:** labelle-engine `jsonc/src/parser.zig`
//!     `parseString`. The engine decodes exactly `\n \t \r \b \f \\ \" \/`
//!     and fails the WHOLE file with `error.InvalidEscape` on anything else,
//!     `\uXXXX` included. `\u` has never been supported (checked against
//!     every revision of that parser).
//!
//! **Why raw bytes can be classified directly (#651).** The textual walkers
//! see raw key spans, while the engine classifies decoded keys. Those two
//! agree for every key the engine can load. An accepted escape starts with
//! `\` and decodes to one of `\n \t \r \b \f \ " /`. None of those bytes (nor
//! `\` itself) is `A`-`Z`, `@` or `_`, and none of them appears in a
//! lowercase structural key (`prefab`, `children`, `components`, …). So the
//! first byte, every `__` position, the byte after the last `__`, and every
//! exact structural-name match are the same before and after decoding.
//! The only keys where raw and decoded bytes differ in meaning are keys
//! with an escape the engine REJECTS (`"\u0057orker"`, `"\u0040slot"`).
//! Those never reach the engine's classifier because the file fails to
//! load. `classifyRaw` returns `.unloadable` for them, so walkers treat
//! them as inert, and `scene_manifest` rejects such a file at build time
//! (`firstInvalidEscape`) instead of letting `std.json`, which DOES decode
//! `\u`, give it a meaning the engine never will. `decode` is the reference
//! implementation the tests check this against.

const std = @import("std");

// ── Decoded-key rules (byte-parity with engine unified_format.zig) ────────

/// PascalCase (RFC #596): first byte is ASCII `A`-`Z`. Empty and
/// non-ASCII-start names are structural.
pub fn isPascalCase(name: []const u8) bool {
    if (name.len == 0) return false;
    return name[0] >= 'A' and name[0] <= 'Z';
}

/// A component-shaped key: PascalCase, or pack-namespaced
/// `<prefix>__<Pascal>` with a nonempty prefix and a PascalCase suffix
/// after the LAST `__` (engine #803/#806: `industry__TendableWorkstation`
/// yes, `capacity__oops` no, `__Worker` no).
pub fn isComponentKeyShape(name: []const u8) bool {
    if (isPascalCase(name)) return true;
    const i = std.mem.lastIndexOf(u8, name, "__") orelse return false;
    if (i == 0) return false;
    return isPascalCase(name[i + 2 ..]);
}

/// `@<ref>` target-override key (engine #801). A bare `@` is structural.
pub fn isTargetKey(name: []const u8) bool {
    return name.len > 1 and name[0] == '@';
}

/// Flat patch content at entity scope: a component-shaped key or a `@`
/// target. Everything else at entity scope is structural.
pub fn isFlatComponentKey(name: []const u8) bool {
    return isComponentKeyShape(name) or isTargetKey(name);
}

// ── Escape decoding (byte-parity with engine jsonc parser.zig) ────────────

/// The byte an accepted escape letter decodes to, or null when the engine's
/// JSONC parser rejects the escape (`error.InvalidEscape`).
pub fn escapeByte(letter: u8) ?u8 {
    return switch (letter) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        'b' => 0x08,
        'f' => 0x0C,
        '\\' => '\\',
        '"' => '"',
        '/' => '/',
        else => null,
    };
}

/// Decode a raw string-literal body (the bytes between the quotes) the way
/// the engine does, into `buf`. `error.InvalidEscape` is exactly the
/// engine's load failure. A trailing lone `\` is also invalid there.
pub fn decode(raw: []const u8, buf: []u8) error{ InvalidEscape, NoSpaceLeft }![]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        var b = raw[i];
        if (b == '\\') {
            i += 1;
            if (i >= raw.len) return error.InvalidEscape;
            b = escapeByte(raw[i]) orelse return error.InvalidEscape;
        }
        if (n >= buf.len) return error.NoSpaceLeft;
        buf[n] = b;
        n += 1;
    }
    return buf[0..n];
}

/// Offset (within `raw`) of the first escape the engine rejects, or null.
pub fn invalidEscapeIn(raw: []const u8) ?usize {
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] != '\\') continue;
        if (i + 1 >= raw.len or escapeByte(raw[i + 1]) == null) return i;
        i += 1;
    }
    return null;
}

// ── Raw-key classification for the textual walkers ────────────────────────

pub const Class = enum {
    /// Lowercase structural key (`prefab`, `children`, `meta`, …) or any
    /// other non-content key.
    structural,
    /// Component-shaped key (PascalCase or `<prefix>__<Pascal>`).
    component,
    /// `@<ref>` target-override key.
    target,
    /// Carries an escape the engine rejects, so the file never loads and
    /// the key has no meaning. Walkers treat it as inert.
    unloadable,
};

/// Classify a raw key span (string-literal body, escapes undecoded) as the
/// engine classifies the decoded key. See the module doc for why no decode
/// buffer is needed.
pub fn classifyRaw(raw: []const u8) Class {
    if (invalidEscapeIn(raw) != null) return .unloadable;
    if (isTargetKey(raw)) return .target;
    if (isComponentKeyShape(raw)) return .component;
    return .structural;
}

pub fn rawIsTargetKey(raw: []const u8) bool {
    return classifyRaw(raw) == .target;
}

pub fn rawIsComponentKeyShape(raw: []const u8) bool {
    return classifyRaw(raw) == .component;
}

pub fn rawIsFlatComponentKey(raw: []const u8) bool {
    return switch (classifyRaw(raw)) {
        .component, .target => true,
        .structural, .unloadable => false,
    };
}

// ── Whole-file escape check (engine load parity) ───────────────────────────

/// Byte offset of the first string escape in `src` that the engine's JSONC
/// parser rejects, or null if it has none. Comment-aware, so a `\u` inside a
/// `//` or `/* */` comment is ignored exactly as the engine ignores it.
/// Strings are scanned for the escape wherever they sit: the engine's
/// parser decodes keys and values alike, and one bad escape fails the file.
pub fn firstInvalidEscape(src: []const u8) ?usize {
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            i = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            const close = std.mem.indexOfPos(u8, src, i + 2, "*/");
            i = if (close) |p| p + 2 else src.len;
            continue;
        }
        if (c == '"') {
            var j = i + 1;
            while (j < src.len) : (j += 1) {
                if (src[j] == '"') break;
                if (src[j] == '\\') {
                    if (j + 1 >= src.len or escapeByte(src[j + 1]) == null) return j;
                    j += 1;
                }
            }
            i = j + 1;
            continue;
        }
        i += 1;
    }
    return null;
}
