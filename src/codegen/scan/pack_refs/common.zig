//! Shared scanning primitives for the two pack-namespace rewrite passes
//! (`pass1.zig` flat-wrap, `pass2.zig` scope walk) — behavior-preserving
//! split of `scan/pack_refs.zig` (labelle-assembler#534 follow-up).
//!
//! Owns the low-level JSONC byte scanners (`skipTrivia`/`scanString`/
//! `scanValue`/`scanBalanced`), the pure key classifiers (`isPascalCase`/
//! `isEntityListKey`/`containsKey`), and the container-shape probes that
//! mirror the engine's `unified_format.zig` (`isOnlyMetaHeaderObject`/
//! `bundleHeaderOpen`/`rootWrapperValueOpen`/`bundleHeaderLegacyEntitiesOffset`).
//! Both passes consume these — the probes and each pass import THIS module and
//! never each other, so the split stays acyclic. Before the split the probes
//! reached the scanners by constructing a throwaway `FlatWrap`; now they call
//! the free functions here directly.

const std = @import("std");

pub const Error = error{ Malformed, OutOfMemory };

/// Nesting cap for both the flat-wrap recursion and the balanced-span
/// scanner. Anything legitimately deeper than this is not a scene/prefab
/// file; the callers bail to the untouched-input path instead of trusting
/// the process stack to an adversarial input.
pub const max_depth: usize = 128;

/// Skip whitespace and JSONC line/block comments starting at `from`;
/// returns the index of the next significant byte (or `src.len`).
pub fn skipTrivia(src: []const u8, from: usize) usize {
    var i = from;
    while (i < src.len) {
        const c = src[i];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            i = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            const close = std.mem.indexOfPos(u8, src, i + 2, "*/");
            i = if (close) |p| p + 2 else src.len;
            continue;
        }
        break;
    }
    return i;
}

/// Scan a string literal starting at the opening `"`; returns one past
/// the closing quote. Backslash escapes are honored the same way pass 2
/// honors them (skip the escaped byte).
pub fn scanString(src: []const u8, at: usize) Error!usize {
    var j = at + 1;
    while (j < src.len) : (j += 1) {
        if (src[j] == '\\' and j + 1 < src.len) {
            j += 1;
            continue;
        }
        if (src[j] == '"') return j + 1;
    }
    return error.Malformed;
}

/// Scan one JSON value starting at `at`; returns one past its end.
/// Containers are scanned with strict `{`/`[` matching, primitives run
/// to the next delimiter.
pub fn scanValue(src: []const u8, at: usize) Error!usize {
    if (at >= src.len) return error.Malformed;
    switch (src[at]) {
        '"' => return scanString(src, at),
        '{', '[' => return scanBalanced(src, at),
        else => {
            // number / true / false / null.
            var j = at;
            while (j < src.len) : (j += 1) {
                const c = src[j];
                if (c == ',' or c == '}' or c == ']' or c == ' ' or
                    c == '\t' or c == '\r' or c == '\n' or c == '/')
                {
                    break;
                }
            }
            if (j == at) return error.Malformed;
            return j;
        },
    }
}

/// Scan past a balanced container starting at `at` (`{` or `[`),
/// string- and comment-aware, with STRICT bracket matching — a `]`
/// closing a `{` (or any mismatch) is `Malformed`, never a wrong span.
/// Wrong spans are the one failure mode that could corrupt output, so
/// this scanner refuses rather than guesses.
pub fn scanBalanced(src: []const u8, at: usize) Error!usize {
    var expected: [max_depth]u8 = undefined;
    var sp: usize = 0;
    var i = at;
    while (i < src.len) {
        const c = src[i];
        if (c == '"') {
            i = try scanString(src, i);
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            i = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            const close = std.mem.indexOfPos(u8, src, i + 2, "*/");
            i = if (close) |p| p + 2 else src.len;
            continue;
        }
        if (c == '{' or c == '[') {
            if (sp >= max_depth) return error.Malformed;
            expected[sp] = if (c == '{') '}' else ']';
            sp += 1;
        } else if (c == '}' or c == ']') {
            if (sp == 0 or expected[sp - 1] != c) return error.Malformed;
            sp -= 1;
            if (sp == 0) return i + 1;
        }
        i += 1;
    }
    return error.Malformed;
}

/// Byte-parity twin of the engine's `unified_format.zig` `isPascalCase`
/// (RFC #596): an entity-scope key is a flat component declaration iff its
/// first byte is an ASCII uppercase letter; everything else (lowercase
/// structural keys like `prefab`/`children`/`meta`/`ref`, empty, non-ASCII
/// start) is structural. The flat-wrap transform must classify keys EXACTLY
/// like the engine's flat loader, or the copy's shape drifts from what the
/// author's file would have meant at game root.
pub fn isPascalCase(name: []const u8) bool {
    if (name.len == 0) return false;
    return name[0] >= 'A' and name[0] <= 'Z';
}

/// Byte-parity twin of the engine's `unified_format.zig` `isTargetKey`
/// (labelle-engine#801): `"@<ref>"` on a prefab reference's override map
/// targets a ref-named entity inside the referenced prefab's body. Like
/// PascalCase component keys, `@` keys are flat patch CONTENT at entity
/// scope — pass 1 must move them into the synthesized wrapper and pass 2
/// must open a component map for their values, or the copy's shape drifts
/// from the author's meaning.
pub fn isTargetKey(name: []const u8) bool {
    return name.len > 1 and name[0] == '@';
}

/// A flat patch-content key at entity scope: PascalCase component
/// (RFC #596 axis 2) or `@` target (labelle-engine#801).
pub fn isFlatComponentKey(name: []const u8) bool {
    return isPascalCase(name) or isTargetKey(name);
}

/// The two array-valued entity-list keys the engine walks (`children` on any
/// entity scope, legacy `entities` at file level). Shared between pass 2's
/// `childArrayScope` and pass 1's flat-wrap recursion so the two walks can
/// never disagree about where entities live.
pub fn isEntityListKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "children") or std.mem.eql(u8, key, "entities");
}

pub fn containsKey(keys: []const []const u8, needle: []const u8) bool {
    for (keys) |k| {
        if (std.mem.eql(u8, k, needle)) return true;
    }
    return false;
}

/// Byte-parity twin of the engine's `unified_format.zig` `isFileHeader`
/// (RFC #596, #516): true iff the object opening at `open` is a file-level
/// metadata header — it carries a `"meta"` key and NO entity-shape key
/// (`prefab`, `children`, `components`, `overrides`, `ref`, or any
/// PascalCase key). Other lowercase keys are tolerated on a header, exactly
/// as the engine tolerates them. `{}` carries no `meta` and is NOT a header
/// (the engine treats it as an entity and rejects it at load), and any
/// object this scanner cannot fully account for is not a header either —
/// both rewrite passes then keep treating the element as an entity, so the
/// author's error surfaces through the normal load diagnostics instead of
/// being skipped silently. Shared by pass 1 (`FlatWrap.emitBundle`) and
/// pass 2 (via `bundleHeaderOpen`) so the two walks can never disagree
/// about what a header is.
pub fn isOnlyMetaHeaderObject(src: []const u8, open: usize) bool {
    var has_meta = false;
    var i = open + 1;
    while (true) {
        i = skipTrivia(src, i);
        if (i >= src.len) return false;
        if (src[i] == '}') return has_meta;
        if (src[i] != '"') return false;
        const key_end = scanString(src, i) catch return false;
        const key = src[i + 1 .. key_end - 1];
        if (std.mem.eql(u8, key, "meta")) {
            has_meta = true;
        } else if (std.mem.eql(u8, key, "prefab") or
            std.mem.eql(u8, key, "children") or
            std.mem.eql(u8, key, "components") or
            std.mem.eql(u8, key, "overrides") or
            std.mem.eql(u8, key, "ref") or
            isFlatComponentKey(key))
        {
            // Any entity-shape key disqualifies — this is an entity that
            // happens to carry a `meta` field, not a file header.
            return false;
        }
        i = skipTrivia(src, key_end);
        if (i >= src.len or src[i] != ':') return false;
        i = skipTrivia(src, i + 1);
        const value_end = scanValue(src, i) catch return false;
        i = skipTrivia(src, value_end);
        if (i >= src.len) return false;
        if (src[i] == ',') {
            i += 1;
            continue;
        }
        if (src[i] == '}') return has_meta;
        return false;
    }
}

/// Offset of the `{` opening an RFC #596 bundle's optional header element,
/// or null when the file is not array-rooted or its first element is not an
/// only-`meta` header (#516). Mirrors the engine's `classifyTopLevel`:
/// header detection inspects the FIRST array element only — a
/// `meta`-carrying object anywhere else is an ordinary entity / payload.
pub fn bundleHeaderOpen(src: []const u8) ?usize {
    const root_start = skipTrivia(src, 0);
    if (root_start >= src.len or src[root_start] != '[') return null;
    const first = skipTrivia(src, root_start + 1);
    if (first >= src.len or src[first] != '{') return null;
    return if (isOnlyMetaHeaderObject(src, first)) first else null;
}

/// Offset (key content start, for line/col reporting) of a legacy
/// `"entities"` key inside an RFC #596 bundle's file-header element, or
/// null when the file is not a bundle, has no header, or the header
/// carries no such key (#521 codex P2).
///
/// PARITY NOTE — `entities` is deliberately NOT a header disqualifier:
/// the engine's `isFileHeader` (v1.66.0) tolerates every lowercase key
/// except `prefab`/`children`/`components`/`overrides`/`ref`, so
/// `{ "meta": …, "entities": […] }` IS a header to the engine, and
/// `classifyTopLevel` extracts only its `meta` — the `entities` list is
/// dead data the loader never reads. The rewrite therefore keeps skipping
/// the element byte-verbatim (rewriting inside it would mutate bytes the
/// engine consumes as metadata); this probe exists solely so `generate`
/// can surface the dead list as a warning — a bundle header carrying a
/// legacy entity list is almost certainly an authoring mistake.
pub fn bundleHeaderLegacyEntitiesOffset(src: []const u8) ?usize {
    const header = bundleHeaderOpen(src) orelse return null;
    var i = header + 1;
    while (true) {
        i = skipTrivia(src, i);
        if (i >= src.len) return null;
        if (src[i] == '}') return null;
        if (src[i] != '"') return null;
        const key_start = i + 1;
        const key_end = scanString(src, i) catch return null;
        if (std.mem.eql(u8, src[key_start .. key_end - 1], "entities")) return key_start;
        i = skipTrivia(src, key_end);
        if (i >= src.len or src[i] != ':') return null;
        i = skipTrivia(src, i + 1);
        const value_end = scanValue(src, i) catch return null;
        i = skipTrivia(src, value_end);
        if (i >= src.len) return null;
        if (src[i] == ',') {
            i += 1;
            continue;
        }
        return null;
    }
}

/// Offset of the `{` opening the root-wrapper's entity value, or null when
/// the file is not the legacy v1.0 — v1.x root-wrapper shape (#516).
/// Mirrors the engine's `rootObject` (`file_obj.getObject("root") orelse
/// file_obj`): the FIRST `"root"` entry decides (the engine's `Object.get`
/// returns the first match) — a non-object first `"root"` value means the
/// file object itself is the entity, and a duplicate LATER `"root"` member
/// is dead data the engine never reads. Returning the byte offset rather
/// than a bool is what lets both passes route exactly ONE member to the
/// entity path, so that duplicate stays verbatim (CodeRabbit on #521). A
/// document head this scanner cannot account for is treated as
/// not-a-wrapper, keeping today's plain-shape behavior for malformed input.
pub fn rootWrapperValueOpen(src: []const u8) ?usize {
    var i = skipTrivia(src, 0);
    if (i >= src.len or src[i] != '{') return null;
    i += 1;
    while (true) {
        i = skipTrivia(src, i);
        if (i >= src.len) return null;
        if (src[i] == '}') return null; // no "root" key — plain shape
        if (src[i] != '"') return null;
        const key_end = scanString(src, i) catch return null;
        const key = src[i + 1 .. key_end - 1];
        i = skipTrivia(src, key_end);
        if (i >= src.len or src[i] != ':') return null;
        i = skipTrivia(src, i + 1);
        if (i >= src.len) return null;
        if (std.mem.eql(u8, key, "root")) return if (src[i] == '{') i else null;
        const value_end = scanValue(src, i) catch return null;
        i = skipTrivia(src, value_end);
        if (i >= src.len) return null;
        if (src[i] == ',') {
            i += 1;
            continue;
        }
        return null;
    }
}
