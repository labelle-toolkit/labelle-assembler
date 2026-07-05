//! Pass 2 of `rewritePackLocalRefs`: the scope-tracked streaming walk over
//! wrapped-shape JSONC (`rewriteWrappedShapeRefs` + the `Scope` model).
//! Behavior-preserving split of `scan/pack_refs.zig`. Imports the shared
//! scanners/probes from `common.zig`; never imports pass 1, so the split
//! stays acyclic.

const std = @import("std");
const common = @import("common.zig");

/// Pass 2 of `rewritePackLocalRefs`: the scope-tracked streaming walk over
/// wrapped-shape JSONC. On its own it rewrites component keys only inside
/// genuine `"components"`/`"overrides"` maps (and `"prefab"` values on
/// entity scopes) — flat-shape component keys are invisible to it, which is
/// why `wrapFlatEntityComponents` must run first (#513).
///
/// The document's top-level container shape is classified ONCE before the
/// walk descends (#516), mirroring the engine's `unified_format.zig`: a
/// root Array is an RFC #596 bundle (elements are entities; an only-`meta`
/// header element walks as opaque `.payload`), and a root object whose
/// FIRST `"root"` entry is object-valued is the legacy wrapper (the
/// document object walks as `.file_container`, that first entry's value as
/// the entity — a duplicate later `"root"` member is dead data and stays
/// opaque, CodeRabbit on #521). The per-entity scope rules below are
/// unchanged.
pub fn rewriteWrappedShapeRefs(
    allocator: std.mem.Allocator,
    src: []const u8,
    component_keys: []const []const u8,
    prefab_names: []const []const u8,
    prefix: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // Container-shape probes (#516) — engine-parity twins of
    // `classifyTopLevel`/`isFileHeader`/`rootObject`. Computed against THIS
    // pass's input (pass 1 may have shifted byte offsets), and cheap: each
    // is a single bounded scan of the document head.
    const header_open = common.bundleHeaderOpen(src);
    const root_open = common.rootWrapperValueOpen(src);

    // Object-nesting context. Each open `{`/`[` pushes the *scope* of the
    // container it introduces so we can tell an entity/prefab-patch object
    // (where `components`/`overrides`/`prefab` are meaningful) apart from a
    // component *payload* (opaque data that must never be rewritten). See
    // `Scope` for the frame kinds and `childScope`/`childArrayScope` for the
    // transitions.
    var scope_stack: std.ArrayList(Scope) = .empty;
    defer scope_stack.deinit(allocator);

    // The most-recent object key at the current level, awaiting its value.
    // Drives both "is the next `{` a component map?" and "is this string the
    // value of a `prefab` key?". Reset whenever the pending key's value is
    // consumed (a value string, a container open/close, or a `,`).
    var pending_key: ?[]const u8 = null;

    const topScope = struct {
        fn f(stack: []const Scope) ?Scope {
            return if (stack.len > 0) stack[stack.len - 1] else null;
        }
    }.f;

    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];

        // JSONC line comment — copy verbatim to end of line.
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            const nl = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
            try out.appendSlice(allocator, src[i..nl]);
            i = nl;
            continue;
        }
        // JSONC block comment — copy verbatim to the closing `*/`.
        if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            const close = std.mem.indexOfPos(u8, src, i + 2, "*/");
            const end = if (close) |p| p + 2 else src.len;
            try out.appendSlice(allocator, src[i..end]);
            i = end;
            continue;
        }
        // Container open — the object/array is the value of `pending_key`.
        if (c == '{') {
            const sc: Scope = blk: {
                // A bundle's header element is file metadata, not an entity
                // (the engine's `classifyTopLevel` slices it off before the
                // entity walk) — everything inside is opaque.
                if (header_open) |ho| {
                    if (i == ho) break :blk .payload;
                }
                if (root_open) |ro| {
                    // THE root binding — the FIRST `"root"` entry's object
                    // value (engine `Object.get` is first-match). Routed by
                    // byte offset so a duplicate later `"root"` member does
                    // NOT ride this path: it is dead data the engine never
                    // reads and falls through to `.payload` via
                    // `childScope(.file_container, …)` (CodeRabbit on #521).
                    if (i == ro) break :blk .entity;
                    // The document object of a root-wrapper file is a
                    // container; every member but that one value is opaque.
                    if (scope_stack.items.len == 0) break :blk .file_container;
                }
                break :blk childScope(topScope(scope_stack.items), pending_key);
            };
            try scope_stack.append(allocator, sc);
            pending_key = null;
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        if (c == '[') {
            try scope_stack.append(allocator, childArrayScope(topScope(scope_stack.items), pending_key));
            pending_key = null;
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        if (c == '}' or c == ']') {
            if (scope_stack.items.len > 0) _ = scope_stack.pop();
            pending_key = null;
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        // A comma ends the current key/value pair — clear any pending key so
        // a primitive value (number/bool/null) can't leak into the next pair.
        if (c == ',') {
            pending_key = null;
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        // String literal — capture its inner content, then decide whether it
        // is a component-declaration key, a `"prefab"` value, or neither.
        if (c == '"') {
            const content_start = i + 1;
            var j = content_start;
            while (j < src.len) : (j += 1) {
                if (src[j] == '\\' and j + 1 < src.len) {
                    j += 1; // skip the escaped char
                    continue;
                }
                if (src[j] == '"') break;
            }
            // `j` is the closing quote (or src.len for an unterminated
            // string — pass it through untouched rather than guessing).
            if (j >= src.len) {
                try out.appendSlice(allocator, src[i..]);
                i = src.len;
                continue;
            }
            const content = src[content_start..j];
            const is_key = nextSignificantIsColon(src, j + 1);

            // The text emitted after `<prefix>__`, or null to pass the literal
            // through untouched. Component keys keep their exact spelling; a
            // prefab value is namespaced by its BASENAME so a subdir prefab
            // reference lands on the same registered key.
            var rewrite_to: ?[]const u8 = null;
            if (is_key) {
                // Component-declaration key: only when the enclosing object is
                // a genuine component map (parent scope is an entity/patch).
                if (topScope(scope_stack.items) == .component_map and
                    common.containsKey(component_keys, content))
                {
                    rewrite_to = content;
                }
            } else {
                // Value position: rewrite a pack-owned prefab reference, but
                // only when the `"prefab"` key sits directly on an ENTITY scope
                // (not a component payload field named `prefab`).
                if (pending_key) |k| {
                    if (std.mem.eql(u8, k, "prefab") and
                        topScope(scope_stack.items) == .entity)
                    {
                        rewrite_to = prefabBasenameMatch(prefab_names, content);
                    }
                }
            }

            if (rewrite_to) |txt| {
                try out.append(allocator, '"');
                try out.appendSlice(allocator, prefix);
                try out.appendSlice(allocator, "__");
                try out.appendSlice(allocator, txt);
                try out.append(allocator, '"');
            } else {
                try out.appendSlice(allocator, src[i .. j + 1]);
            }

            // Track the pending key for the container-type / prefab-value
            // lookups above; a value string closes the pending pair.
            if (is_key) {
                pending_key = content;
            } else {
                pending_key = null;
            }
            i = j + 1;
            continue;
        }

        try out.append(allocator, c);
        i += 1;
    }

    return out.toOwnedSlice(allocator);
}

/// Object/array scope kinds tracked while walking pack JSONC in
/// `rewritePackLocalRefs`. The distinction that matters is ENTITY (where
/// `components`/`overrides`/`prefab` carry engine meaning) vs PAYLOAD (opaque
/// component data that must never be rewritten). See the engine's
/// `labelle-engine/src/jsonc/unified_format.zig` for the authoritative shape.
const Scope = enum {
    /// An entity / prefab-patch object. `components`/`overrides` open a
    /// component map here; a `prefab` string value is an entity reference.
    entity,
    /// The value of a `components`/`overrides` key sitting on an entity — its
    /// direct keys are component names.
    component_map,
    /// A component's value, or anything nested below it: opaque payload data.
    /// Never opens a component map and never treats `prefab` as a reference.
    payload,
    /// An array whose elements are entities (a `children`/`entities` list,
    /// or the document-root array of an RFC #596 bundle, #516).
    array_entities,
    /// Any other array — payload arrays, unknown lists. Elements are opaque.
    array_other,
    /// The document-root object of a legacy `"root"`-wrapper file
    /// (v1.0 — v1.x, #516): a pure CONTAINER, not an entity. Its FIRST
    /// `"root"` member's object value is the entity (engine `rootObject` /
    /// first-match `Object.get`; routed by byte offset in
    /// `rewriteWrappedShapeRefs`, so a duplicate later `"root"` member is
    /// dead data and stays opaque — CodeRabbit on #521); its
    /// `children`/`entities` arrays stay live entity lists (the engine's
    /// `fileChildren` keeps consulting them as the partial-migration
    /// fallback, labelle-engine#573); every other member — file metadata
    /// like `"name"`, dead flat keys — is opaque.
    file_container,
};

/// Scope of the object introduced by a `{`, given its parent's scope and the
/// key it is the value of. The document root (parent == null) is an entity
/// (prefab-root / entity object) — `rewriteWrappedShapeRefs` pre-empts this
/// with `.file_container`/`.payload` for the root-wrapper and bundle-header
/// container shapes (#516) before consulting `childScope`. See `Scope`.
fn childScope(parent: ?Scope, pending_key: ?[]const u8) Scope {
    const p = parent orelse return .entity;
    return switch (p) {
        .array_entities => .entity,
        .entity => blk: {
            if (pending_key) |k| {
                if (std.mem.eql(u8, k, "components") or std.mem.eql(u8, k, "overrides")) {
                    break :blk .component_map;
                }
            }
            // Any other object field on an entity (`meta`, etc.) is opaque.
            break :blk .payload;
        },
        // A root-wrapper container's object members are all opaque: the ONE
        // live `"root"` value (FIRST entry — engine `Object.get` is
        // first-match) is routed to `.entity` by byte offset in
        // `rewriteWrappedShapeRefs` BEFORE childScope is consulted, so a
        // duplicate later `"root"` member lands here and stays dead-data
        // verbatim (CodeRabbit on #521).
        .file_container => .payload,
        // A component's value, or anything already inside payload, stays opaque.
        .component_map, .payload, .array_other => .payload,
    };
}

/// Scope of the array introduced by a `[`. The document-root array is an
/// RFC #596 file-as-array bundle — its elements are sibling entities
/// (#516, engine `classifyTopLevel`). Below the root, only a
/// `children`/`entities` list directly on an entity (or on a root-wrapper's
/// document object — the `fileChildren` fallback) carries entity elements;
/// every other array is opaque.
fn childArrayScope(parent: ?Scope, pending_key: ?[]const u8) Scope {
    const p = parent orelse return .array_entities;
    if (p == .entity or p == .file_container) {
        if (pending_key) |k| {
            if (common.isEntityListKey(k)) return .array_entities;
        }
    }
    return .array_other;
}

/// If `content` (the value of a `"prefab"` key) names one of the pack's OWN
/// prefabs by BASENAME, return that basename — the text `addEmbeddedPrefab`
/// registers under `<prefix>__<basename>`. Both a bare `"worker"` and a subdir
/// path `"enemies/goblin"` map to their basename, matching the registration
/// key that `std.fs.path.basename` produces (chatgpt-codex L704). Returns null
/// for a foreign/game-root prefab reference.
fn prefabBasenameMatch(prefab_names: []const []const u8, content: []const u8) ?[]const u8 {
    const content_base = std.fs.path.basename(content);
    for (prefab_names) |p| {
        if (std.mem.eql(u8, std.fs.path.basename(p), content_base)) return content_base;
    }
    return null;
}

/// True iff the next significant byte at/after `from` (skipping whitespace
/// and JSONC comments) is a `:` — i.e. the preceding string literal was an
/// object key rather than a value. Pure lookahead; consumes nothing.
fn nextSignificantIsColon(src: []const u8, from: usize) bool {
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
        return c == ':';
    }
    return false;
}
