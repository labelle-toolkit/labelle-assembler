//! Pack-namespace JSONC rewriting extracted from `codegen/scan.zig`
//! (behavior-preserving split, labelle-assembler#534 follow-up).
//!
//! Owns the `PackScan` result type and the streaming JSONC walkers that
//! rewrite a pack's OWN component keys / prefab references into the
//! invisible `<pack>__` namespace (Packs RFC §4, #440/#513/#516). Two
//! passes: `wrapFlatEntityComponents` (flat→wrapped normalization) then
//! `rewriteWrappedShapeRefs` (the scope-tracked rewrite). Re-exported from
//! the `scan.zig` barrel.

const std = @import("std");
const sanitize = @import("sanitize.zig");
const sanitizePluginIdent = sanitize.sanitizePluginIdent;

/// Scan result for one **pack** (Packs RFC §4, labelle-assembler#439).
///
/// A *pack* is a light, directory-scanned plugin: instead of contributing
/// components/events/prefabs through decl-modules (`pub const Components`),
/// it drops game-convention files into `components/ events/ prefabs/ hooks/`
/// subdirs — scanned the same way the game root is. `generate` copies each
/// subdir into `<target>/packs/<name>/<subdir>/` and records the scanned
/// stems here so the codegen block-writers can register them into the SAME
/// registries the game root feeds (the "unified set", RFC §4 / §6-1b).
///
/// `import_prefix` is the path the generated `main.zig` imports through,
/// e.g. `"packs/citizens"` — files live at
/// `<import_prefix>/{components,events,prefabs}/<name>.<ext>`.
///
/// Namespacing (#440): a pack's contributed component / prefab / pack-local
/// event names are registered in the generated global registry under the
/// invisible `<pack>__<Name>` prefix (see `packNamespacePrefix`) — authors
/// write local names (`.Worker`) and the assembler namespaces them so a pack
/// and the game root that both define `Worker` never collide. The physical
/// path is already pack-namespaced (`import_prefix`), so files never collide
/// on disk either.
///
/// Owned by `deinit` — `name`, `import_prefix`, and every string in the
/// four name slices are heap dupes made by the scan/copy pass.
pub const PackScan = struct {
    name: []const u8,
    import_prefix: []const u8,
    component_names: []const []const u8,
    event_names: []const []const u8,
    prefab_names: []const []const u8,
    /// Pack `hooks/*.zig` stems (#440). Registered into the SAME `GameHooks`
    /// receiver tuple as the game root's `hooks/`, under the `<pack>__` ident
    /// prefix so two packs shipping `overlay.zig` don't collide on the import
    /// alias / receiver-instance identifier.
    hook_names: []const []const u8 = &.{},

    pub fn deinit(self: *PackScan, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.import_prefix);
        freeNameSlice(allocator, self.component_names);
        freeNameSlice(allocator, self.event_names);
        freeNameSlice(allocator, self.prefab_names);
        freeNameSlice(allocator, self.hook_names);
    }

    fn freeNameSlice(allocator: std.mem.Allocator, names: []const []const u8) void {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }
};

/// Derive a pack's invisible namespace ident from its manifest `name`
/// (Packs RFC §4, #440). Every registry ident a pack contributes — the
/// component registry field (`<pfx>__<Pascal>`), the pack-local event
/// variant + its import alias, the prefab registration key, and the hook
/// import alias / receiver-instance ident — is prefixed `<pfx>__`, mirroring
/// the existing `<plugin>__<event>` convention (`plugin_registries.zig`).
/// The name is sanitized to a valid Zig identifier fragment the same way
/// plugin idents are, so a pack named `my-pack` namespaces as `my_pack__…`.
///
/// SAVE-STABILITY: the prefixed component name is the on-disk save key
/// (`serde.componentName`, engine-side), so a pack's `name` is **save-stable**
/// — renaming a shipped pack changes every component's save key and is
/// therefore a save migration, not a cosmetic rename. Treat a pack `name`
/// like a serialized schema field once the pack has shipped.
pub fn packNamespacePrefix(pack_name: []const u8, buf: *[128]u8) []const u8 {
    return sanitizePluginIdent(pack_name, buf);
}

/// Back-compat shim (#440). Rewrites only pack-owned component KEYS —
/// delegates to `rewritePackLocalRefs` with an empty prefab-name set so no
/// `"prefab"` values are touched. Kept because the unit tests below (and any
/// external caller) reference this narrower entry point directly. New call
/// sites should prefer `rewritePackLocalRefs`, which also rewrites pack-local
/// prefab references (chatgpt-codex finding #1).
pub fn rewritePackComponentKeys(
    allocator: std.mem.Allocator,
    src: []const u8,
    local_keys: []const []const u8,
    prefix: []const u8,
) ![]u8 {
    return rewritePackLocalRefs(allocator, src, local_keys, &.{}, prefix);
}

/// Rewrite a pack's own prefab/scene JSONC so **local references to the
/// pack's OWN components and prefabs** resolve in the unified registry
/// (Packs RFC §4, #440). Two kinds of reference are rewritten, both keeping
/// the `<pack>__` prefix invisible to the author:
///
///   1. **Component keys** — a component-declaration key whose content
///      exactly equals one of `component_keys` becomes `<prefix>__<Name>`
///      (`"Worker"` → `"citizens__Worker"`), byte-matching the field the
///      component registry emits.
///   2. **Prefab references** — a `"prefab"` string *value* whose **basename**
///      matches one of `prefab_names` becomes `<prefix>__<basename>`
///      (`"prefab": "worker"` → `"prefab": "citizens__worker"`), matching the
///      `addEmbeddedPrefab(&g, "citizens__worker", …)` registration key. A
///      composing prefab (`{ "prefab": "worker" }`) would otherwise reference
///      the bare `worker`, which is never registered (chatgpt-codex #1).
///      Subdirectory prefabs are keyed by BASENAME at registration
///      (`addEmbeddedPrefab` uses `std.fs.path.basename`), so both a bare
///      `"worker"` and a path `"enemies/goblin"` reference resolve to the same
///      basename-prefixed key (`citizens__goblin`) (chatgpt-codex L704).
///
/// **Context-awareness (chatgpt-codex #2).** Both rewrites are gated on the
/// current object *scope*, tracked precisely as we descend. A `"components"` /
/// `"overrides"` object is treated as a component map ONLY when its parent is
/// an ENTITY / prefab-patch scope (the wrapped shape the engine's `entityPatch`
/// / `prefabComponents` treat as the component map); a `"components"` /
/// `"overrides"` key nested inside a component's *value* (payload) is opaque
/// data and opens no component map. So a key of the SAME text as a pack
/// component appearing as payload — e.g.
/// `{ "Spawner": { "overrides": { "Worker": 3 } } }` — is left untouched, and
/// the payload never gets corrupted before deserialization.
///
/// Prefab-reference rewriting is likewise scoped to the *value* of a `"prefab"`
/// key that sits directly on an ENTITY scope — a `"prefab"` field appearing as
/// payload data inside a component's value (e.g.
/// `{ "Spawner": { "prefab": "worker" } }`) is component data, not an entity
/// reference, and is left alone (chatgpt-codex L288). Only pack-OWN prefabs are
/// rewritten — a reference to a non-pack (game-root / built-in) prefab is left
/// bare.
///
/// **Flat shape (#513, engine RFC #596).** The engine also accepts a *flat*
/// shape where PascalCase component keys sit directly on the entity object
/// with no `"components"`/`"overrides"` wrapper — and RFC #596 makes it the
/// recommended authoring shape, so real pack prefabs use it. Bare pack-local
/// keys there have the exact same collision problem, but an in-place key
/// rewrite is NOT viable: the engine's flat loader classifies entity-scope
/// keys by CASE (`unified_format.zig` `isPascalCase`), so a namespaced
/// `<pack>__Pascal` key (lowercase first byte) would demote to a structural
/// key and be dropped silently — with zero log signal, because the RFC #596
/// unknown-component warn-once only covers Pascal-cased unknowns (observed
/// as a runtime regression on the FP pilot, flying-platform-labelle#573).
/// Instead, a normalization pre-pass (`wrapFlatEntityComponents`) converts
/// any flat entity that declares pack-local components into the WRAPPED
/// shape — collecting ALL its PascalCase keys into a synthesized
/// `"components"` map (`"overrides"` for prefab references) — and the walk
/// below then namespaces the pack-local keys through the same
/// component-map scope rule it always used. See that function for the full
/// shape rules (mixed wrapper+flat entities, payload decoys, malformed-
/// input fallback).
///
/// **Accepted file shapes (#516).** Both passes recognize the three
/// top-level FILE shapes the engine dual-accepts, classified exactly like
/// the engine's `unified_format.zig` (`classifyTopLevel` / `isFileHeader` /
/// `rootObject` — the probes here are their byte-scanning twins):
///
///   1. **Plain entity object** — `{ …entity… }`: the document object IS
///      the entity (RFC #594; the only shape either pass walked before
///      #516).
///   2. **RFC #596 file-as-array bundle** — a top-level Array of sibling
///      entities. An OPTIONAL header element at index 0 — an object that
///      carries `meta` and no entity-shape key — is file metadata: skipped
///      byte-verbatim, never treated as an entity. A `meta` key on an
///      object that ALSO carries entity-shape keys does not make it a
///      header, and `meta`-carrying objects anywhere else are ordinary
///      entities / payload (see `isOnlyMetaHeaderObject`).
///   3. **Legacy `"root"`-wrapper** — `{ "root": { …entity… } }`
///      (v1.0 — v1.x, still dual-accepted): the document object is a
///      CONTAINER; the FIRST `"root"` member's object value is the entity
///      (engine `Object.get` is first-match — a duplicate later `"root"`
///      member is dead data, left verbatim; CodeRabbit on #521). Other
///      container members (`name`, dead flat keys the engine never reads)
///      are left verbatim — except `children`/`entities` arrays, which stay
///      live entity lists (the engine's `fileChildren` keeps consulting
///      them as the partial-migration fallback, labelle-engine#573).
///
/// A pack prefab authored in shape 2 or 3 previously got NO namespacing at
/// all — bare component keys and bare `"prefab"` refs loaded silently
/// unattached, the same failure class as #513, just via a different door.
///
/// String *values* (other than `"prefab"`) and JSONC comment text are never
/// rewritten. Returns an allocator-owned buffer; when nothing matches it is
/// still a fresh dupe of the input, so the caller frees unconditionally.
pub fn rewritePackLocalRefs(
    allocator: std.mem.Allocator,
    src: []const u8,
    component_keys: []const []const u8,
    prefab_names: []const []const u8,
    prefix: []const u8,
) ![]u8 {
    // Pass 1 (#513): flat-shape entities that declare pack-local components
    // are normalized into the wrapped shape, so pass 2's component-map scope
    // rule sees (and namespaces) their keys. A no-op for files with nothing
    // to wrap — those come back byte-identical.
    const normalized = try wrapFlatEntityComponents(allocator, src, component_keys);
    defer allocator.free(normalized);
    return rewriteWrappedShapeRefs(allocator, normalized, component_keys, prefab_names, prefix);
}

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
fn rewriteWrappedShapeRefs(
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
    const header_open = bundleHeaderOpen(src);
    const root_open = rootWrapperValueOpen(src);

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
                    containsKey(component_keys, content))
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
            if (isEntityListKey(k)) return .array_entities;
        }
    }
    return .array_other;
}

/// The two array-valued entity-list keys the engine walks (`children` on any
/// entity scope, legacy `entities` at file level). Shared between pass 2's
/// `childArrayScope` and pass 1's flat-wrap recursion so the two walks can
/// never disagree about where entities live.
fn isEntityListKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "children") or std.mem.eql(u8, key, "entities");
}

/// Byte-parity twin of the engine's `unified_format.zig` `isPascalCase`
/// (RFC #596): an entity-scope key is a flat component declaration iff its
/// first byte is an ASCII uppercase letter; everything else (lowercase
/// structural keys like `prefab`/`children`/`meta`/`ref`, empty, non-ASCII
/// start) is structural. The flat-wrap transform must classify keys EXACTLY
/// like the engine's flat loader, or the copy's shape drifts from what the
/// author's file would have meant at game root.
fn isPascalCase(name: []const u8) bool {
    if (name.len == 0) return false;
    return name[0] >= 'A' and name[0] <= 'Z';
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
fn isOnlyMetaHeaderObject(src: []const u8, open: usize) bool {
    // The FlatWrap scanning primitives only read `.src`; a probe instance
    // reuses them without threading a full walker through.
    const probe = FlatWrap{ .src = src, .component_keys = &.{} };
    var has_meta = false;
    var i = open + 1;
    while (true) {
        i = probe.skipTrivia(i);
        if (i >= src.len) return false;
        if (src[i] == '}') return has_meta;
        if (src[i] != '"') return false;
        const key_end = probe.scanString(i) catch return false;
        const key = src[i + 1 .. key_end - 1];
        if (std.mem.eql(u8, key, "meta")) {
            has_meta = true;
        } else if (std.mem.eql(u8, key, "prefab") or
            std.mem.eql(u8, key, "children") or
            std.mem.eql(u8, key, "components") or
            std.mem.eql(u8, key, "overrides") or
            std.mem.eql(u8, key, "ref") or
            isPascalCase(key))
        {
            // Any entity-shape key disqualifies — this is an entity that
            // happens to carry a `meta` field, not a file header.
            return false;
        }
        i = probe.skipTrivia(key_end);
        if (i >= src.len or src[i] != ':') return false;
        i = probe.skipTrivia(i + 1);
        const value_end = probe.scanValue(i) catch return false;
        i = probe.skipTrivia(value_end);
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
fn bundleHeaderOpen(src: []const u8) ?usize {
    const probe = FlatWrap{ .src = src, .component_keys = &.{} };
    const root_start = probe.skipTrivia(0);
    if (root_start >= src.len or src[root_start] != '[') return null;
    const first = probe.skipTrivia(root_start + 1);
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
    const probe = FlatWrap{ .src = src, .component_keys = &.{} };
    var i = header + 1;
    while (true) {
        i = probe.skipTrivia(i);
        if (i >= src.len) return null;
        if (src[i] == '}') return null;
        if (src[i] != '"') return null;
        const key_start = i + 1;
        const key_end = probe.scanString(i) catch return null;
        if (std.mem.eql(u8, src[key_start .. key_end - 1], "entities")) return key_start;
        i = probe.skipTrivia(key_end);
        if (i >= src.len or src[i] != ':') return null;
        i = probe.skipTrivia(i + 1);
        const value_end = probe.scanValue(i) catch return null;
        i = probe.skipTrivia(value_end);
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
fn rootWrapperValueOpen(src: []const u8) ?usize {
    const probe = FlatWrap{ .src = src, .component_keys = &.{} };
    var i = probe.skipTrivia(0);
    if (i >= src.len or src[i] != '{') return null;
    i += 1;
    while (true) {
        i = probe.skipTrivia(i);
        if (i >= src.len) return null;
        if (src[i] == '}') return null; // no "root" key — plain shape
        if (src[i] != '"') return null;
        const key_end = probe.scanString(i) catch return null;
        const key = src[i + 1 .. key_end - 1];
        i = probe.skipTrivia(key_end);
        if (i >= src.len or src[i] != ':') return null;
        i = probe.skipTrivia(i + 1);
        if (i >= src.len) return null;
        if (std.mem.eql(u8, key, "root")) return if (src[i] == '{') i else null;
        const value_end = probe.scanValue(i) catch return null;
        i = probe.skipTrivia(value_end);
        if (i >= src.len) return null;
        if (src[i] == ',') {
            i += 1;
            continue;
        }
        return null;
    }
}

/// Pass 1 of `rewritePackLocalRefs` (#513): normalize FLAT-shape entities
/// (engine RFC #596) into the WRAPPED shape wherever they declare one of the
/// pack's own components, so pass 2's wrapped-shape walk can namespace them.
///
/// **Why a shape conversion instead of prefixing the flat key in place?**
/// The engine's flat loader classifies entity-scope keys by case: PascalCase
/// keys are component declarations, lowercase keys are structural
/// (`unified_format.zig` `isPascalCase`). A namespaced key
/// (`citizens__Worker`) starts lowercase, so an in-place rewrite would
/// demote the component to a silently-dropped structural key — and the
/// RFC #596 unknown-component warn-once would not fire either, since it only
/// covers Pascal-cased unknowns. Observed as a zero-signal runtime
/// regression on the FP pilot (flying-platform-labelle#573). The wrapped
/// shape has no case rule — `"components"`/`"overrides"` map keys are
/// component names verbatim — so it is the only shape in which a `<pack>__`
/// key can attach today, and converting to it is self-contained in the
/// assembler (no engine release required). If/when the engine's flat loader
/// learns to accept `<pack>__Pascal` keys (they are the documented
/// global-registry key format — a prerequisite for engine v2.0, which drops
/// the wrapper entirely), this pass can flip to an in-place key rewrite.
///
/// **What is transformed.** For each entity object (the file's entity
/// content in any of the three accepted top-level shapes — see `emitRoot` —
/// or an element of a `children`/`entities` array; the same entity scopes
/// pass 2 walks)
/// whose top-level keys include at least one of the pack's own component
/// names (`component_keys`, Pascal forms) and which carries no explicit
/// wrapper yet: ALL PascalCase keys — engine components like `Position` AND
/// the pack-local ones — move, values byte-verbatim, into one synthesized
/// wrapper map inserted at the first moved key's position, relative order
/// kept. Lowercase structural keys (`prefab`, `children`, `meta`, `ref`, …)
/// stay at entity scope in their original order. Moving ALL Pascal keys
/// together is load-bearing: the engine's "wrapper wins" rule DROPS any key
/// left flat beside a wrapper, so a partial move would lose components.
///
/// **Wrapper spelling.** `"overrides"` when the entity is a prefab
/// reference (string-valued `"prefab"` key — mirrors `entityPatch`'s
/// `is_reference`), `"components"` otherwise. The engine does accept
/// `"components"` on a reference, but warns it as a legacy spelling
/// (RFC #560); `"overrides"` is the warning-free patch-map form.
///
/// **What is NOT transformed.**
///   - An entity with no pack-local flat key is left byte-identical — flat
///     engine-only entities load fine as-is (flat is RFC #596's recommended
///     shape), so everything the bug can't affect stays minimal-diff.
///   - A HYBRID entity — a `"components"` or `"overrides"` wrapper key AND
///     flat Pascal keys COEXISTING in the author's text — is left
///     byte-verbatim, whether inline or reference. That mix is rejected as
///     `error.HybridForm` by this repo's scene validator
///     (`scene_manifest.zig`, RFC #596 axis 2 — deliberately no reference
///     check there) and gated the same way engine-side (#597, "wrapper
///     wins" warn-once at load); the copy must keep tripping those
///     diagnostics on the author's own bytes instead of masking the error
///     with a second wrapper. Pure flat — Pascal keys with NO wrapper key
///     anywhere on the entity — is never hybrid; that is exactly the shape
///     this pass converts.
///   - Component payloads: a Pascal key INSIDE a moved value — the decoy,
///     `{ "Spawner": { "SkyBody": 3 } }` — is payload, copied verbatim.
///   - JSONC comments ride along verbatim with the pair they precede.
///
/// **Safety valve.** The transform re-emits parsed pieces, so it only runs
/// when it can account for the whole file structurally; on any surprise
/// (unbalanced containers, missing colon, a scalar root, or pathological
/// nesting) it returns the input untouched and pass 2 proceeds exactly as
/// before. Same conservative posture as the original #440 boundary: never
/// guess on bytes we would rewrite. A file where no entity qualifies is
/// returned byte-identical (trailing commas and all), so no-op inputs
/// round-trip exactly.
///
/// Returns an allocator-owned buffer; a content-preserving dupe when
/// nothing qualifies, so the caller frees unconditionally.
fn wrapFlatEntityComponents(
    allocator: std.mem.Allocator,
    src: []const u8,
    component_keys: []const []const u8,
) ![]u8 {
    // A pack with no components has no key that could qualify an entity.
    if (component_keys.len == 0) return allocator.dupe(u8, src);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var walker = FlatWrap{ .src = src, .component_keys = component_keys };
    const parsed = blk: {
        walker.emitRoot(allocator, &out) catch |err| switch (err) {
            error.Malformed => break :blk false,
            error.OutOfMemory => return error.OutOfMemory,
        };
        break :blk true;
    };
    if (!parsed or !walker.wrapped_any) return allocator.dupe(u8, src);
    return out.toOwnedSlice(allocator);
}

/// Recursive-descent walker for `wrapFlatEntityComponents` (#513). Parses
/// just enough JSONC structure — strings, comments, strictly-balanced
/// containers — to re-emit entity objects with their flat component keys
/// collected into a wrapper; every value span is copied byte-verbatim.
/// Errors with `Malformed` on anything it cannot fully account for, and the
/// caller then keeps the input untouched.
const FlatWrap = struct {
    src: []const u8,
    component_keys: []const []const u8,
    /// Set when at least one wrapper was synthesized. When it stays false
    /// the caller returns the INPUT verbatim, so byte fidelity of no-op
    /// files (their trailing commas, exact separators) holds by
    /// construction rather than by emitter carefulness.
    wrapped_any: bool = false,

    const Error = error{ Malformed, OutOfMemory };

    /// Nesting cap for both the recursion and the balanced-span scanner.
    /// Anything legitimately deeper than this is not a scene/prefab file;
    /// bail to the untouched-input path instead of trusting the process
    /// stack to an adversarial input.
    const max_depth: usize = 128;

    /// One parsed `"key": value` pair at an object's top level. All fields
    /// are byte offsets into `src`; spans are emitted verbatim so trivia
    /// (whitespace + comments) rides along with its pair.
    const Pair = struct {
        /// Start of the pair's leading trivia (right after `{`, or after
        /// the previous pair's `,`).
        lead_start: usize,
        /// Opening `"` of the key literal.
        key_start: usize,
        /// Key content (between the quotes, escapes unprocessed).
        key: []const u8,
        /// First byte of the value (past `:` and any trivia).
        value_start: usize,
        /// One past the last byte of the value.
        value_end: usize,
        /// One past the pair's trailing trivia (between the value and its
        /// `,` / the enclosing `}`) — stays attached to the pair if moved.
        post_end: usize,
    };

    const ParsedObject = struct {
        pairs: []Pair,
        /// Start of the trivia between the last separator and `}`. Equals
        /// `close_brace` when the last pair's own `post` span already
        /// carried that trivia (the no-trailing-comma case).
        close_trivia_start: usize,
        close_brace: usize,
        /// One past `}`.
        end: usize,
    };

    /// Emit the whole document: leading trivia, the file's entity content,
    /// trailing trivia. All three engine-accepted top-level shapes are
    /// walked (#516, engine `unified_format.zig`):
    ///
    ///   - **Plain entity object** — the root `{ … }` IS the entity
    ///     (RFC #594, the recommended shape).
    ///   - **RFC #596 file-as-array bundle** — a root `[ … ]` of sibling
    ///     entities, with an optional only-`meta` header element at index 0
    ///     (engine `classifyTopLevel`). See `emitBundle`.
    ///   - **Legacy `"root"`-wrapper** — `{ "root": { … } }` (v1.0 — v1.x,
    ///     engine `rootObject`): the document object is a container, not an
    ///     entity. See `emitFileContainer`.
    ///
    /// A scalar root falls back to the untouched-input path via `Malformed`.
    fn emitRoot(self: *FlatWrap, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) Error!void {
        const s = self.src;
        const start = self.skipTrivia(0);
        try out.appendSlice(allocator, s[0..start]);
        if (start >= s.len) return; // comment/whitespace-only file
        const end = switch (s[start]) {
            '[' => try self.emitBundle(allocator, out, start),
            '{' => if (rootWrapperValueOpen(s)) |root_open|
                try self.emitFileContainer(allocator, out, start, root_open)
            else
                try self.emitEntityObject(allocator, out, start, 0),
            else => return error.Malformed,
        };
        try out.appendSlice(allocator, s[end..]);
    }

    /// Emit one entity object, wrapping its flat component keys when it
    /// qualifies (see `wrapFlatEntityComponents` doc for the rules), and
    /// recursing into its `children`/`entities` arrays either way. Returns
    /// the index one past the object's `}`.
    fn emitEntityObject(
        self: *FlatWrap,
        allocator: std.mem.Allocator,
        out: *std.ArrayList(u8),
        at: usize,
        depth: usize,
    ) Error!usize {
        if (depth > max_depth) return error.Malformed;
        const s = self.src;
        const obj = try self.parseObject(allocator, at);
        defer allocator.free(obj.pairs);

        // Entity classification. `is_reference` (string-valued `prefab`,
        // mirroring the engine's `entityPatch`) picks the wrapper SPELLING
        // only. ANY pre-existing wrapper key — `components` OR `overrides`,
        // reference or not — blocks the wrap entirely: a wrapper key
        // coexisting with flat Pascal keys is the RFC #596 HYBRID form,
        // rejected as `error.HybridForm` by this repo's scene validator
        // (`scene_manifest.zig`, which deliberately has no reference check
        // either) and gated the same way engine-side (#597). The author's
        // text must keep tripping that diagnostic — synthesizing a second
        // wrapper next to the existing one would mask the error (codex P2
        // on #515).
        var is_reference = false;
        var has_wrapper = false;
        var has_local_flat = false;
        for (obj.pairs) |p| {
            if (std.mem.eql(u8, p.key, "prefab") and s[p.value_start] == '"') is_reference = true;
            if (std.mem.eql(u8, p.key, "components") or std.mem.eql(u8, p.key, "overrides")) has_wrapper = true;
            if (containsKey(self.component_keys, p.key)) has_local_flat = true;
        }
        const wrap = has_local_flat and !has_wrapper;

        try out.append(allocator, '{');
        var emitted_any = false;
        var wrapper_done = false;
        for (obj.pairs) |p| {
            if (wrap and isPascalCase(p.key)) {
                // Every Pascal pair moves into the single wrapper, emitted
                // at the FIRST Pascal pair's position (with its leading
                // trivia); later Pascal pairs were already emitted inside.
                if (wrapper_done) continue;
                if (emitted_any) try out.append(allocator, ',');
                try out.appendSlice(allocator, s[p.lead_start..p.key_start]);
                try out.appendSlice(allocator, if (is_reference) "\"overrides\": {" else "\"components\": {");
                var first = true;
                for (obj.pairs) |q| {
                    if (!isPascalCase(q.key)) continue;
                    if (!first) try out.append(allocator, ',');
                    if (first) {
                        // Its original lead was spent on the wrapper key.
                        try out.append(allocator, ' ');
                        try out.appendSlice(allocator, s[q.key_start..q.value_end]);
                    } else {
                        try out.appendSlice(allocator, s[q.lead_start..q.value_end]);
                    }
                    try out.appendSlice(allocator, s[q.value_end..q.post_end]);
                    first = false;
                }
                try out.appendSlice(allocator, " }");
                wrapper_done = true;
                emitted_any = true;
                self.wrapped_any = true;
                continue;
            }
            // Structural pair (or an untransformed entity's pair): verbatim,
            // except that entity-list arrays recurse so nested flat entities
            // are reached. Payload values (`meta`, component values, …) are
            // copied as-is — the decoy guarantee.
            if (emitted_any) try out.append(allocator, ',');
            try out.appendSlice(allocator, s[p.lead_start..p.value_start]);
            if (s[p.value_start] == '[' and isEntityListKey(p.key)) {
                _ = try self.emitEntityArray(allocator, out, p.value_start, depth + 1);
            } else {
                try out.appendSlice(allocator, s[p.value_start..p.value_end]);
            }
            try out.appendSlice(allocator, s[p.value_end..p.post_end]);
            emitted_any = true;
        }
        try out.appendSlice(allocator, s[obj.close_trivia_start..obj.close_brace]);
        try out.append(allocator, '}');
        return obj.end;
    }

    /// Emit an entity-list array: object elements recurse as entities,
    /// anything else is copied verbatim. Returns one past the `]`.
    fn emitEntityArray(
        self: *FlatWrap,
        allocator: std.mem.Allocator,
        out: *std.ArrayList(u8),
        at: usize,
        depth: usize,
    ) Error!usize {
        if (depth > max_depth) return error.Malformed;
        const s = self.src;
        try out.append(allocator, '[');
        var i = at + 1;
        var lead_start = i;
        var emitted_any = false;
        while (true) {
            i = self.skipTrivia(i);
            if (i >= s.len) return error.Malformed;
            if (s[i] == ']') {
                // Empty array, or trivia after a trailing comma.
                try out.appendSlice(allocator, s[lead_start..i]);
                try out.append(allocator, ']');
                return i + 1;
            }
            if (emitted_any) try out.append(allocator, ',');
            try out.appendSlice(allocator, s[lead_start..i]);
            if (s[i] == '{') {
                i = try self.emitEntityObject(allocator, out, i, depth + 1);
            } else {
                const vend = try self.scanValue(i);
                try out.appendSlice(allocator, s[i..vend]);
                i = vend;
            }
            emitted_any = true;
            const post = self.skipTrivia(i);
            try out.appendSlice(allocator, s[i..post]);
            i = post;
            if (i >= s.len) return error.Malformed;
            if (s[i] == ',') {
                i += 1;
                lead_start = i;
                continue;
            }
            if (s[i] == ']') {
                try out.append(allocator, ']');
                return i + 1;
            }
            return error.Malformed;
        }
    }

    /// Emit an RFC #596 file-as-array bundle (#516): sibling entity
    /// elements at the file top level, walked exactly like an entity-list
    /// array — except that an only-`meta` header element at index 0
    /// (engine `isFileHeader`, see `isOnlyMetaHeaderObject`) is file
    /// metadata, not an entity: it is copied byte-verbatim and never
    /// wrapped or recursed into. Returns one past the `]`.
    fn emitBundle(
        self: *FlatWrap,
        allocator: std.mem.Allocator,
        out: *std.ArrayList(u8),
        at: usize,
    ) Error!usize {
        const s = self.src;
        try out.append(allocator, '[');
        var i = at + 1;
        var lead_start = i;
        var emitted_any = false;
        var at_header_slot = true;
        while (true) {
            i = self.skipTrivia(i);
            if (i >= s.len) return error.Malformed;
            if (s[i] == ']') {
                // Empty bundle, or trivia after a trailing comma.
                try out.appendSlice(allocator, s[lead_start..i]);
                try out.append(allocator, ']');
                return i + 1;
            }
            if (emitted_any) try out.append(allocator, ',');
            try out.appendSlice(allocator, s[lead_start..i]);
            if (s[i] == '{' and !(at_header_slot and isOnlyMetaHeaderObject(s, i))) {
                i = try self.emitEntityObject(allocator, out, i, 1);
            } else {
                // The header element (opaque metadata), or a non-object
                // element (malformed for the engine) — copied verbatim,
                // same as `emitEntityArray` does for non-object elements.
                const vend = try self.scanValue(i);
                try out.appendSlice(allocator, s[i..vend]);
                i = vend;
            }
            at_header_slot = false;
            emitted_any = true;
            const post = self.skipTrivia(i);
            try out.appendSlice(allocator, s[i..post]);
            i = post;
            if (i >= s.len) return error.Malformed;
            if (s[i] == ',') {
                i += 1;
                lead_start = i;
                continue;
            }
            if (s[i] == ']') {
                try out.append(allocator, ']');
                return i + 1;
            }
            return error.Malformed;
        }
    }

    /// Emit a legacy `"root"`-wrapper file (#516; v1.0 — v1.x, engine
    /// `rootObject`): the document object is a CONTAINER, not an entity.
    /// The pair whose value opens at `root_open` — the FIRST `"root"`
    /// member, per `rootWrapperValueOpen` / the engine's first-match
    /// `Object.get` — descends as the entity; a duplicate later `"root"`
    /// member is dead data the engine never reads and is copied verbatim
    /// (CodeRabbit on #521). `children`/`entities` arrays at container
    /// level stay live entity lists (the engine's `fileChildren` keeps
    /// consulting them as the partial-migration fallback,
    /// labelle-engine#573); every other member — file metadata like
    /// `"name"`, dead flat keys the engine never reads — is copied verbatim
    /// and never wrapped. Returns one past the container's `}`.
    fn emitFileContainer(
        self: *FlatWrap,
        allocator: std.mem.Allocator,
        out: *std.ArrayList(u8),
        at: usize,
        root_open: usize,
    ) Error!usize {
        const s = self.src;
        const obj = try self.parseObject(allocator, at);
        defer allocator.free(obj.pairs);

        try out.append(allocator, '{');
        var emitted_any = false;
        for (obj.pairs) |p| {
            if (emitted_any) try out.append(allocator, ',');
            try out.appendSlice(allocator, s[p.lead_start..p.value_start]);
            if (p.value_start == root_open) {
                _ = try self.emitEntityObject(allocator, out, p.value_start, 1);
            } else if (s[p.value_start] == '[' and isEntityListKey(p.key)) {
                _ = try self.emitEntityArray(allocator, out, p.value_start, 1);
            } else {
                try out.appendSlice(allocator, s[p.value_start..p.value_end]);
            }
            try out.appendSlice(allocator, s[p.value_end..p.post_end]);
            emitted_any = true;
        }
        try out.appendSlice(allocator, s[obj.close_trivia_start..obj.close_brace]);
        try out.append(allocator, '}');
        return obj.end;
    }

    /// Parse the top-level `"key": value` pairs of the object opening at
    /// `at`. Records byte spans only — nothing is emitted here — so the
    /// caller can classify the pairs before deciding on a layout.
    fn parseObject(self: *const FlatWrap, allocator: std.mem.Allocator, at: usize) Error!ParsedObject {
        const s = self.src;
        if (at >= s.len or s[at] != '{') return error.Malformed;
        var pairs: std.ArrayList(Pair) = .empty;
        errdefer pairs.deinit(allocator);
        var i = at + 1;
        var lead_start = i;
        while (true) {
            i = self.skipTrivia(i);
            if (i >= s.len) return error.Malformed;
            if (s[i] == '}') {
                // Empty object, or trivia after a trailing comma.
                return .{
                    .pairs = try pairs.toOwnedSlice(allocator),
                    .close_trivia_start = lead_start,
                    .close_brace = i,
                    .end = i + 1,
                };
            }
            if (s[i] != '"') return error.Malformed;
            const key_start = i;
            const key_end = try self.scanString(i);
            i = self.skipTrivia(key_end);
            if (i >= s.len or s[i] != ':') return error.Malformed;
            i = self.skipTrivia(i + 1);
            if (i >= s.len) return error.Malformed;
            const value_start = i;
            const value_end = try self.scanValue(i);
            const post_end = self.skipTrivia(value_end);
            try pairs.append(allocator, .{
                .lead_start = lead_start,
                .key_start = key_start,
                .key = s[key_start + 1 .. key_end - 1],
                .value_start = value_start,
                .value_end = value_end,
                .post_end = post_end,
            });
            i = post_end;
            if (i >= s.len) return error.Malformed;
            if (s[i] == ',') {
                i += 1;
                lead_start = i;
                continue;
            }
            if (s[i] == '}') {
                return .{
                    .pairs = try pairs.toOwnedSlice(allocator),
                    .close_trivia_start = i,
                    .close_brace = i,
                    .end = i + 1,
                };
            }
            return error.Malformed;
        }
    }

    /// Skip whitespace and JSONC line/block comments starting at `from`;
    /// returns the index of the next significant byte (or `src.len`).
    fn skipTrivia(self: *const FlatWrap, from: usize) usize {
        const s = self.src;
        var i = from;
        while (i < s.len) {
            const c = s[i];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                i += 1;
                continue;
            }
            if (c == '/' and i + 1 < s.len and s[i + 1] == '/') {
                i = std.mem.indexOfScalarPos(u8, s, i, '\n') orelse s.len;
                continue;
            }
            if (c == '/' and i + 1 < s.len and s[i + 1] == '*') {
                const close = std.mem.indexOfPos(u8, s, i + 2, "*/");
                i = if (close) |p| p + 2 else s.len;
                continue;
            }
            break;
        }
        return i;
    }

    /// Scan a string literal starting at the opening `"`; returns one past
    /// the closing quote. Backslash escapes are honored the same way pass 2
    /// honors them (skip the escaped byte).
    fn scanString(self: *const FlatWrap, at: usize) Error!usize {
        const s = self.src;
        var j = at + 1;
        while (j < s.len) : (j += 1) {
            if (s[j] == '\\' and j + 1 < s.len) {
                j += 1;
                continue;
            }
            if (s[j] == '"') return j + 1;
        }
        return error.Malformed;
    }

    /// Scan one JSON value starting at `at`; returns one past its end.
    /// Containers are scanned with strict `{`/`[` matching, primitives run
    /// to the next delimiter.
    fn scanValue(self: *const FlatWrap, at: usize) Error!usize {
        const s = self.src;
        if (at >= s.len) return error.Malformed;
        switch (s[at]) {
            '"' => return self.scanString(at),
            '{', '[' => return self.scanBalanced(at),
            else => {
                // number / true / false / null.
                var j = at;
                while (j < s.len) : (j += 1) {
                    const c = s[j];
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
    fn scanBalanced(self: *const FlatWrap, at: usize) Error!usize {
        const s = self.src;
        var expected: [max_depth]u8 = undefined;
        var sp: usize = 0;
        var i = at;
        while (i < s.len) {
            const c = s[i];
            if (c == '"') {
                i = try self.scanString(i);
                continue;
            }
            if (c == '/' and i + 1 < s.len and s[i + 1] == '/') {
                i = std.mem.indexOfScalarPos(u8, s, i, '\n') orelse s.len;
                continue;
            }
            if (c == '/' and i + 1 < s.len and s[i + 1] == '*') {
                const close = std.mem.indexOfPos(u8, s, i + 2, "*/");
                i = if (close) |p| p + 2 else s.len;
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
};

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

fn containsKey(keys: []const []const u8, needle: []const u8) bool {
    for (keys) |k| {
        if (std.mem.eql(u8, k, needle)) return true;
    }
    return false;
}

// ── Tests (moved verbatim from scan.zig) ─────────────────────────────

test "packNamespacePrefix: sanitizes the pack name into a Zig ident fragment" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("citizens", packNamespacePrefix("citizens", &buf));
    // Non-identifier bytes collapse to `_`, same as plugin idents.
    try std.testing.expectEqualStrings("my_pack", packNamespacePrefix("my-pack", &buf));
}

test "rewritePackComponentKeys: rewrites only pack-owned component KEYS" {
    const allocator = std.testing.allocator;
    const src =
        \\{
        \\    "components": {
        \\        "Worker": { "hp": 3, "label": "Worker" },
        \\        "Position": { "x": 0 }
        \\    }
        \\}
    ;
    const out = try rewritePackComponentKeys(allocator, src, &.{"Worker"}, "citizens");
    defer allocator.free(out);

    // Pack-owned key rewritten …
    try std.testing.expect(std.mem.indexOf(u8, out, "\"citizens__Worker\":") != null);
    // … built-in `Position` untouched …
    try std.testing.expect(std.mem.indexOf(u8, out, "\"Position\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "citizens__Position") == null);
    // … and the VALUE `"Worker"` (not a key) left alone.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"label\": \"Worker\"") != null);
}

test "rewritePackComponentKeys: leaves a matching name in a comment alone" {
    const allocator = std.testing.allocator;
    const src =
        \\{
        \\    // "Worker": legacy note, not a real key
        \\    "components": { "Worker": {} }
        \\}
    ;
    const out = try rewritePackComponentKeys(allocator, src, &.{"Worker"}, "citizens");
    defer allocator.free(out);

    // The real key was rewritten …
    try std.testing.expect(std.mem.indexOf(u8, out, "{ \"citizens__Worker\": {} }") != null);
    // … but the comment text is preserved verbatim.
    try std.testing.expect(std.mem.indexOf(u8, out, "// \"Worker\": legacy note") != null);
}

test "rewritePackComponentKeys: no matches yields a content-preserving dupe" {
    const allocator = std.testing.allocator;
    const src = "{ \"Position\": { \"x\": 0 } }";
    const out = try rewritePackComponentKeys(allocator, src, &.{"Worker"}, "citizens");
    defer allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "rewritePackLocalRefs: payload data key matching a component name is NOT rewritten (chatgpt-codex #2)" {
    const allocator = std.testing.allocator;
    // `Worker` is a pack-owned component. It appears BOTH as a real component
    // declaration key (must be rewritten) AND as a nested payload-data key
    // inside `Spawner.counts` (must be left alone — rewriting it corrupts the
    // payload before deserialization).
    const src =
        \\{
        \\    "components": {
        \\        "Worker": { "hp": 3 },
        \\        "Spawner": { "counts": { "Worker": 3 } }
        \\    }
        \\}
    ;
    const out = try rewritePackLocalRefs(allocator, src, &.{"Worker"}, &.{}, "citizens");
    defer allocator.free(out);

    // The real component-declaration key IS rewritten …
    try std.testing.expect(std.mem.indexOf(u8, out, "\"citizens__Worker\": { \"hp\": 3 }") != null);
    // … the `Spawner` declaration key is also under `components` (not a pack
    // component, so untouched) …
    try std.testing.expect(std.mem.indexOf(u8, out, "\"Spawner\":") != null);
    // … but the nested payload key `"Worker"` inside `counts` is NOT rewritten.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"counts\": { \"Worker\": 3 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "citizens__Worker\": 3") == null);
}

test "rewritePackLocalRefs: keys inside an overrides wrapper are rewritten" {
    const allocator = std.testing.allocator;
    const src =
        \\{ "prefab": "base", "overrides": { "Worker": { "hp": 9 } } }
    ;
    // `base` is not a pack prefab here, so the ref is left alone; the override
    // component key IS a pack component, so it is namespaced.
    const out = try rewritePackLocalRefs(allocator, src, &.{"Worker"}, &.{}, "citizens");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"prefab\": \"base\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"citizens__Worker\":") != null);
}

test "rewritePackLocalRefs: a pack-local prefab reference value is rewritten (chatgpt-codex #1)" {
    const allocator = std.testing.allocator;
    // A pack prefab composing another SAME-pack prefab by local name. The
    // `"prefab"` value must resolve to the namespaced registration key.
    const src =
        \\{
        \\    "children": [
        \\        { "prefab": "worker", "components": { "Position": { "x": 1 } } },
        \\        { "prefab": "external" }
        \\    ]
        \\}
    ;
    // `worker` is pack-owned; `external` is NOT (a game-root/foreign prefab).
    const out = try rewritePackLocalRefs(allocator, src, &.{}, &.{"worker"}, "citizens");
    defer allocator.free(out);

    // The same-pack reference is namespaced …
    try std.testing.expect(std.mem.indexOf(u8, out, "\"prefab\": \"citizens__worker\"") != null);
    // … the foreign reference is left bare …
    try std.testing.expect(std.mem.indexOf(u8, out, "\"prefab\": \"external\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "citizens__external") == null);
    // … and `Position` (built-in, not pack-owned) is untouched.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"Position\":") != null);
}

test "rewritePackLocalRefs: nested overrides inside a component payload is NOT a component map (CR L224)" {
    const allocator = std.testing.allocator;
    // `Worker` is a pack component. It appears as a real declaration key AND
    // deep inside `Spawner`'s payload under a nested `overrides` object. The
    // nested `overrides` must NOT open a component map — it's payload data.
    const src =
        \\{
        \\    "components": {
        \\        "Worker": { "hp": 3 },
        \\        "Spawner": { "overrides": { "Worker": 3 } }
        \\    }
        \\}
    ;
    const out = try rewritePackLocalRefs(allocator, src, &.{"Worker"}, &.{}, "citizens");
    defer allocator.free(out);

    // The real component key IS namespaced …
    try std.testing.expect(std.mem.indexOf(u8, out, "\"citizens__Worker\": { \"hp\": 3 }") != null);
    // … but the payload `Worker` under the nested `overrides` is untouched.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"overrides\": { \"Worker\": 3 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "citizens__Worker\": 3") == null);
}

test "rewritePackLocalRefs: a payload field named prefab is NOT rewritten (codex L288)" {
    const allocator = std.testing.allocator;
    // `worker` is a pack prefab. The `prefab` key here is a component-payload
    // field (inside `Spawner`'s value), not an entity reference — leave it bare.
    const src =
        \\{ "components": { "Spawner": { "prefab": "worker" } } }
    ;
    const out = try rewritePackLocalRefs(allocator, src, &.{}, &.{"worker"}, "citizens");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"prefab\": \"worker\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "citizens__worker") == null);
}

test "rewritePackLocalRefs: subdir pack prefab ref resolves to the basename-prefixed key (codex L704)" {
    const allocator = std.testing.allocator;
    // Pack prefab scanned as `enemies/goblin`; `addEmbeddedPrefab` registers it
    // as `citizens__goblin` (basename). Both a bare and a path-spelled ref must
    // land on that same key.
    const src =
        \\{
        \\    "children": [
        \\        { "prefab": "goblin" },
        \\        { "prefab": "enemies/goblin" }
        \\    ]
        \\}
    ;
    const out = try rewritePackLocalRefs(allocator, src, &.{}, &.{"enemies/goblin"}, "citizens");
    defer allocator.free(out);
    // Both references collapse to the basename-prefixed registration key.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"prefab\": \"citizens__goblin\"") != null);
    // …and neither retains the raw subdir spelling.
    try std.testing.expect(std.mem.indexOf(u8, out, "citizens__enemies/goblin") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"prefab\": \"goblin\"") == null);
}

test "rewritePackLocalRefs: flat-shape entity is wrapped and pack keys namespaced (#513)" {
    const allocator = std.testing.allocator;
    // RFC #596 flat shape: PascalCase component keys directly at entity
    // scope. `SkyBody` is pack-owned (must be namespaced); `Position` is an
    // engine component (spelling untouched) — but BOTH must move into the
    // wrapper, because the engine's "wrapper wins" rule drops any key left
    // flat beside a wrapper.
    const src =
        \\{
        \\    "SkyBody": { "role": "sun" },
        \\    "Position": { "x": 0 }
        \\}
    ;
    const out = try rewritePackLocalRefs(allocator, src, &.{"SkyBody"}, &.{}, "sky");
    defer allocator.free(out);

    // An inline entity (no `prefab`) wraps into `"components"` …
    try std.testing.expect(std.mem.indexOf(u8, out, "\"components\": {") != null);
    // … the pack key is namespaced, payload verbatim …
    try std.testing.expect(std.mem.indexOf(u8, out, "\"sky__SkyBody\": { \"role\": \"sun\" }") != null);
    // … the engine key moved in untouched …
    try std.testing.expect(std.mem.indexOf(u8, out, "\"Position\": { \"x\": 0 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "sky__Position") == null);
    // … and no bare flat key survived at entity scope.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"SkyBody\":") == null);
}

test "rewritePackLocalRefs: flat decoy payload sharing a pack component spelling is NOT touched (#513)" {
    const allocator = std.testing.allocator;
    // `SkyBody` is pack-owned. It appears as a real flat declaration AND as
    // payload data inside `Spawner`'s value. `Spawner` (Pascal → a component
    // declaration by the engine's own case rule) moves into the wrapper as a
    // unit with its payload byte-verbatim — the inner `SkyBody` stays bare.
    const src =
        \\{ "SkyBody": { "role": "sun" }, "Spawner": { "SkyBody": 3 } }
    ;
    const out = try rewritePackLocalRefs(allocator, src, &.{"SkyBody"}, &.{}, "sky");
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"sky__SkyBody\": { \"role\": \"sun\" }") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"Spawner\": { \"SkyBody\": 3 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "sky__SkyBody\": 3") == null);
}

test "rewritePackLocalRefs: flat entity with no pack-local key is left byte-identical (#513)" {
    const allocator = std.testing.allocator;
    // Engine-only flat entity — loads fine as-is (flat is RFC #596's
    // recommended shape), so the copy stays minimal-diff. Includes the
    // ticket's decoy spelling: a payload key matching the pack component
    // under a non-pack Pascal key must not qualify the entity for wrapping
    // (it is not at entity scope).
    const src =
        \\{ "Position": { "x": 0 }, "Spawner": { "SkyBody": 3 } }
    ;
    const out = try rewritePackLocalRefs(allocator, src, &.{"SkyBody"}, &.{}, "sky");
    defer allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "rewritePackLocalRefs: mixed-shape file rewrites wrapped sibling and LAST flat child (#513)" {
    const allocator = std.testing.allocator;
    // Regression shape from the FP pilot (flying-platform-labelle#573): a
    // children list whose first element is already wrapped and whose LAST
    // element — no trailing comma after it — is flat; the hand-conversion
    // missed exactly that last element. Pack-local prefab VALUES must keep
    // rewriting in both shapes.
    const src =
        \\{
        \\    "children": [
        \\        { "prefab": "cloud", "overrides": { "SkyBody": { "role": "cloud" } } },
        \\        // the sun rides last
        \\        { "prefab": "sun", "SkyBody": { "role": "sun" } }
        \\    ]
        \\}
    ;
    const out = try rewritePackLocalRefs(allocator, src, &.{"SkyBody"}, &.{ "cloud", "sun" }, "sky");
    defer allocator.free(out);

    // Wrapped sibling: byte-stable except the key/value namespacing.
    try std.testing.expect(std.mem.indexOf(u8, out, "{ \"prefab\": \"sky__cloud\", \"overrides\": { \"sky__SkyBody\": { \"role\": \"cloud\" } } }") != null);
    // The comment between array elements rides along verbatim.
    try std.testing.expect(std.mem.indexOf(u8, out, "// the sun rides last") != null);
    // Flat LAST child: normalized into the wrapped shape and namespaced.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"prefab\": \"sky__sun\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"overrides\": { \"SkyBody\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"overrides\": { \"sky__SkyBody\": { \"role\": \"sun\" }") != null);
    // No bare pack key survived anywhere.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"SkyBody\"") == null);
}

test "rewritePackLocalRefs: flat prefab reference wraps its patch as overrides, not components (#513)" {
    const allocator = std.testing.allocator;
    // Decision (#513): a flat REFERENCE entity's Pascal keys wrap into
    // `"overrides"` — the engine's `entityPatch` treats `"components"` on a
    // prefab reference as a warned legacy synonym (RFC #560), while
    // `"overrides"` is the warning-free patch-map spelling. Inline entities
    // (no `prefab`) wrap into `"components"` instead. Note this entity is
    // PURE flat (no wrapper key anywhere), so it is NOT the HybridForm mix
    // — a pre-existing `overrides`/`components` key would block the wrap
    // entirely (see the hybrid tests below).
    const src =
        \\{ "prefab": "base", "Position": { "x": 5 }, "SkyBody": { "role": "moon" } }
    ;
    const out = try rewritePackLocalRefs(allocator, src, &.{"SkyBody"}, &.{}, "sky");
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"overrides\": {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"components\"") == null);
    // Engine keys ride into the patch untouched; pack keys namespaced; the
    // foreign prefab VALUE stays bare.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"Position\": { \"x\": 5 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"sky__SkyBody\": { \"role\": \"moon\" }") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"prefab\": \"base\"") != null);
}

test "rewritePackLocalRefs: flat root and flat child both wrap (#513)" {
    const allocator = std.testing.allocator;
    // The wrap must recurse through `children` exactly like pass 2's scope
    // walk — a flat prefab-root entity AND a flat child entity each get
    // their own wrapper.
    const src =
        \\{
        \\    "SkyBody": { "role": "root" },
        \\    "children": [
        \\        { "CloudDrift": { "v": 2 } }
        \\    ]
        \\}
    ;
    const out = try rewritePackLocalRefs(allocator, src, &.{ "SkyBody", "CloudDrift" }, &.{}, "sky");
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"sky__SkyBody\": { \"role\": \"root\" }") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"sky__CloudDrift\": { \"v\": 2 }") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "\"components\": {"));
}

test "rewritePackLocalRefs: entity mixing wrapper and flat keys is left for the engine warn (#513)" {
    const allocator = std.testing.allocator;
    // A wrapper key coexisting with flat Pascal keys is the RFC #596
    // HYBRID form: this repo's scene validator hard-rejects it
    // (`error.HybridForm`, `scene_manifest.zig`) and the engine gates it
    // at load ("wrapper wins" warn-once, #597). The copy must not behave
    // differently from the same file at game root, so the flat key stays
    // byte-verbatim (keeping those diagnostics alive) and only the
    // wrapper's contents are namespaced.
    const src =
        \\{ "components": { "SkyBody": { "role": "sun" } }, "CloudDrift": { "v": 1 } }
    ;
    const out = try rewritePackLocalRefs(allocator, src, &.{ "SkyBody", "CloudDrift" }, &.{}, "sky");
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"sky__SkyBody\":") != null);
    // The flat key beside the wrapper is neither moved nor namespaced.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"CloudDrift\": { \"v\": 1 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "sky__CloudDrift") == null);
}

test "rewritePackLocalRefs: inline entity mixing overrides with flat keys is left for the HybridForm diagnostic (#513)" {
    const allocator = std.testing.allocator;
    // An `overrides` key coexisting with flat Pascal keys is the RFC #596
    // HYBRID form on ANY entity — inline included: the repo's scene
    // validator rejects it as `error.HybridForm` with deliberately no
    // reference check (`scene_manifest.zig`), and engine #597 gates the
    // same mix at every entity site. Wrapping the flat key into a second
    // (`components`) wrapper here would mask the author's error, so the
    // entity must come back byte-identical (codex P2 on #515 — this
    // REVERSES the expectation CodeRabbit's round-1 sketch suggested).
    // Hybrid = wrapper key AND flat Pascal keys COEXIST; pure flat (no
    // wrapper key at all) still wraps — see the flat-reference test above.
    const src =
        \\{ "overrides": { "unused": 1 }, "SkyBody": { "role": "sun" } }
    ;
    const out = try rewritePackLocalRefs(allocator, src, &.{"SkyBody"}, &.{}, "sky");
    defer allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "rewritePackLocalRefs: JSONC comments survive the flat wrap verbatim (#513)" {
    const allocator = std.testing.allocator;
    // Line comment leading a moved pair, block comment inside a moved
    // payload, block comment trailing a structural pair — all must come out
    // byte-verbatim (comments travel with the pair they precede).
    const src =
        \\{
        \\    // the sun body
        \\    "SkyBody": { /* payload note */ "role": "sun" },
        \\    "prefab": "base" /* keep me */
        \\}
    ;
    const out = try rewritePackLocalRefs(allocator, src, &.{"SkyBody"}, &.{}, "sky");
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "// the sun body") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/* payload note */") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/* keep me */") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"sky__SkyBody\":") != null);
}

test "rewritePackLocalRefs: flat wrap is idempotent across a second run (#513)" {
    const allocator = std.testing.allocator;
    // `generate` re-copies sources every run, but the rewrite must also be
    // stable if it ever sees its own output: the namespaced keys no longer
    // match the local key set, and the synthesized wrapper suppresses any
    // further flat detection.
    const src =
        \\{ "prefab": "sun", "SkyBody": { "role": "sun" } }
    ;
    const once = try rewritePackLocalRefs(allocator, src, &.{"SkyBody"}, &.{"sun"}, "sky");
    defer allocator.free(once);
    const twice = try rewritePackLocalRefs(allocator, once, &.{"SkyBody"}, &.{"sun"}, "sky");
    defer allocator.free(twice);

    try std.testing.expect(std.mem.indexOf(u8, once, "\"prefab\": \"sky__sun\"") != null);
    try std.testing.expectEqualStrings(once, twice);
}

test "rewritePackLocalRefs: wrapped file with trailing comma round-trips byte-identically (#513)" {
    const allocator = std.testing.allocator;
    // The wrap pass re-emits parsed pieces, so guarantee the no-op path
    // returns the INPUT bytes exactly — a JSONC trailing comma is the
    // canonical detail a re-emitter would otherwise normalize away.
    const src =
        \\{
        \\    "components": { "Position": { "x": 0 } },
        \\}
    ;
    const out = try rewritePackLocalRefs(allocator, src, &.{"SkyBody"}, &.{}, "sky");
    defer allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "rewritePackLocalRefs: bundle meta header is skipped and flat sibling entities wrap (#516)" {
    const allocator = std.testing.allocator;
    // RFC #596 file-as-array bundle with the optional only-`meta` header at
    // index 0 (engine `classifyTopLevel`/`isFileHeader`). The header is file
    // metadata — byte-verbatim, never wrapped — while the flat sibling
    // entities compose with pass 1: wrapped, then namespaced.
    const src =
        \\[
        \\    { "meta": { "author": "fp", "note": "SkyBody here is data" } },
        \\    { "SkyBody": { "role": "sun" }, "Position": { "x": 0 } },
        \\    { "prefab": "cloud", "SkyBody": { "role": "cloud" } }
        \\]
    ;
    const out = try rewritePackLocalRefs(allocator, src, &.{"SkyBody"}, &.{"cloud"}, "sky");
    defer allocator.free(out);

    // Header element: byte-verbatim — its `meta` payload is opaque even
    // where it spells a pack component's name.
    try std.testing.expect(std.mem.indexOf(u8, out, "{ \"meta\": { \"author\": \"fp\", \"note\": \"SkyBody here is data\" } }") != null);
    // Inline sibling: wrapped into `components`, pack key namespaced, the
    // engine key untouched.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"components\": { \"sky__SkyBody\": { \"role\": \"sun\" },") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"Position\": { \"x\": 0 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "sky__Position") == null);
    // Reference sibling: wrapped into `overrides`, prefab value namespaced.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"prefab\": \"sky__cloud\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"overrides\": { \"sky__SkyBody\": { \"role\": \"cloud\" }") != null);
}

test "rewritePackLocalRefs: bundle without a header namespaces wrapped entities and prefab refs (#516)" {
    const allocator = std.testing.allocator;
    // No header: index 0 carries entity-shape keys, so it is an entity, not
    // metadata (engine `classifyTopLevel`). Both elements are already in the
    // WRAPPED shape, so pass 1 has nothing to normalize — this exercises
    // pass 2's own bundle recognition in isolation.
    const src =
        \\[
        \\    { "components": { "Worker": { "hp": 3 } } },
        \\    { "prefab": "worker", "overrides": { "Worker": { "hp": 9 } } }
        \\]
    ;
    const out = try rewritePackLocalRefs(allocator, src, &.{"Worker"}, &.{"worker"}, "citizens");
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"components\": { \"citizens__Worker\": { \"hp\": 3 } }") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"prefab\": \"citizens__worker\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"overrides\": { \"citizens__Worker\": { \"hp\": 9 } }") != null);
}

test "rewritePackLocalRefs: bundle LAST element without trailing comma still wraps (#516)" {
    const allocator = std.testing.allocator;
    // The #573 regression shape transposed to a bundle: the LAST element —
    // flat, with no trailing comma after it — must still be reached and
    // wrapped, and the comment between elements rides along verbatim.
    const src =
        \\[
        \\    { "meta": { "v": 1 } },
        \\    // the sun rides last
        \\    { "SkyBody": { "role": "sun" } }
        \\]
    ;
    const out = try rewritePackLocalRefs(allocator, src, &.{"SkyBody"}, &.{}, "sky");
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "{ \"meta\": { \"v\": 1 } }") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "// the sun rides last") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"components\": { \"sky__SkyBody\": { \"role\": \"sun\" }") != null);
    // No bare pack key survived anywhere.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"SkyBody\"") == null);
}

test "rewritePackLocalRefs: root-wrapper file descends into the root entity (#516)" {
    const allocator = std.testing.allocator;
    // Legacy v1.0 — v1.x shape (engine `rootObject`): the document object is
    // a container; the entity is the object-valued `"root"` member. The
    // flat root entity wraps + namespaces exactly like a plain-shape file,
    // and the file-level `"name"` metadata stays verbatim.
    const src =
        \\{
        \\    "name": "sun",
        \\    "root": {
        \\        "SkyBody": { "role": "sun" },
        \\        "Position": { "x": 0 }
        \\    }
        \\}
    ;
    const out = try rewritePackLocalRefs(allocator, src, &.{"SkyBody"}, &.{}, "sky");
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\": \"sun\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"components\": { \"sky__SkyBody\": { \"role\": \"sun\" },") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"Position\": { \"x\": 0 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "sky__Position") == null);
}

test "rewritePackLocalRefs: root-wrapper children and pack prefab refs are namespaced (#516)" {
    const allocator = std.testing.allocator;
    // The walk under `"root"` must reach nested entities exactly like the
    // plain shape — wrapped component maps, `"prefab"` value refs, AND a
    // flat LAST child (no trailing comma) that needs pass 1.
    const src =
        \\{
        \\    "root": {
        \\        "components": { "SkyBody": { "role": "root" } },
        \\        "children": [
        \\            { "prefab": "cloud", "overrides": { "CloudDrift": { "v": 2 } } },
        \\            { "CloudDrift": { "v": 3 } }
        \\        ]
        \\    }
        \\}
    ;
    const out = try rewritePackLocalRefs(allocator, src, &.{ "SkyBody", "CloudDrift" }, &.{"cloud"}, "sky");
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"sky__SkyBody\": { \"role\": \"root\" }") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"prefab\": \"sky__cloud\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"overrides\": { \"sky__CloudDrift\": { \"v\": 2 } }") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"components\": { \"sky__CloudDrift\": { \"v\": 3 }") != null);
}

test "rewritePackLocalRefs: only the FIRST root member is the entity — a duplicate is dead data (#516, CodeRabbit #521)" {
    const allocator = std.testing.allocator;
    // Engine `Object.get` is first-match: the first `"root"` entry is THE
    // root binding, and a duplicated later `"root"` member is dead data the
    // engine never reads — it must stay byte-verbatim (bare keys and all)
    // through BOTH passes, not get rewritten as a second entity.
    const src =
        \\{
        \\    "root": { "SkyBody": { "role": "sun" } },
        \\    "root": { "components": { "SkyBody": { "role": "dead" } } }
        \\}
    ;
    const out = try rewritePackLocalRefs(allocator, src, &.{"SkyBody"}, &.{}, "sky");
    defer allocator.free(out);

    // First root: wrapped + namespaced …
    try std.testing.expect(std.mem.indexOf(u8, out, "\"components\": { \"sky__SkyBody\": { \"role\": \"sun\" }") != null);
    // … the duplicate stays byte-verbatim, its bare key included …
    try std.testing.expect(std.mem.indexOf(u8, out, "\"root\": { \"components\": { \"SkyBody\": { \"role\": \"dead\" } } }") != null);
    // … so exactly one namespacing happened in the whole file.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "sky__SkyBody"));

    // Idempotency holds across the duplicate too.
    const twice = try rewritePackLocalRefs(allocator, out, &.{"SkyBody"}, &.{}, "sky");
    defer allocator.free(twice);
    try std.testing.expectEqualStrings(out, twice);
}

test "rewritePackLocalRefs: meta on an entity-shaped element is NOT a bundle header (#516)" {
    const allocator = std.testing.allocator;
    // Engine `isFileHeader` parity: a `meta` key does NOT make an object a
    // header when entity-shape keys coexist — index 0 here is an ENTITY
    // carrying authoring metadata, so it must be walked and namespaced. The
    // decoy in element 1 (`meta`-keyed object data inside a component
    // payload) is opaque either way.
    const src =
        \\[
        \\    { "meta": { "note": "an entity, not a header" }, "SkyBody": { "role": "sun" } },
        \\    { "Spawner": { "meta": { "SkyBody": 3 } } }
        \\]
    ;
    const out = try rewritePackLocalRefs(allocator, src, &.{"SkyBody"}, &.{}, "sky");
    defer allocator.free(out);

    // Element 0 was treated as an entity: wrapped + namespaced …
    try std.testing.expect(std.mem.indexOf(u8, out, "\"sky__SkyBody\": { \"role\": \"sun\" }") != null);
    // … its `meta` stays structural at entity scope (not moved, not renamed) …
    try std.testing.expect(std.mem.indexOf(u8, out, "\"meta\": { \"note\": \"an entity, not a header\" }") != null);
    // … and the payload decoy is untouched.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"meta\": { \"SkyBody\": 3 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "sky__SkyBody\": 3") == null);
}

test "rewritePackLocalRefs: container-shape rewrites are idempotent (#516)" {
    const allocator = std.testing.allocator;
    // Same stability contract as the #513 idempotency test, over both new
    // container shapes: the namespaced keys/values no longer match the local
    // key and prefab sets, so a second run is byte-identical.
    const bundle =
        \\[
        \\    { "meta": { "v": 1 } },
        \\    { "prefab": "sun", "SkyBody": { "role": "sun" } }
        \\]
    ;
    const once = try rewritePackLocalRefs(allocator, bundle, &.{"SkyBody"}, &.{"sun"}, "sky");
    defer allocator.free(once);
    const twice = try rewritePackLocalRefs(allocator, once, &.{"SkyBody"}, &.{"sun"}, "sky");
    defer allocator.free(twice);
    try std.testing.expect(std.mem.indexOf(u8, once, "\"prefab\": \"sky__sun\"") != null);
    try std.testing.expectEqualStrings(once, twice);

    const wrapper =
        \\{ "root": { "prefab": "sun", "SkyBody": { "role": "sun" } } }
    ;
    const w_once = try rewritePackLocalRefs(allocator, wrapper, &.{"SkyBody"}, &.{"sun"}, "sky");
    defer allocator.free(w_once);
    const w_twice = try rewritePackLocalRefs(allocator, w_once, &.{"SkyBody"}, &.{"sun"}, "sky");
    defer allocator.free(w_twice);
    try std.testing.expect(std.mem.indexOf(u8, w_once, "\"prefab\": \"sky__sun\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, w_once, "\"overrides\": { \"sky__SkyBody\": { \"role\": \"sun\" }") != null);
    try std.testing.expectEqualStrings(w_once, w_twice);
}

test "rewritePackLocalRefs: engine-only bundle and root-wrapper round-trip byte-identically (#516)" {
    const allocator = std.testing.allocator;
    // Nothing pack-owned anywhere: pass 1 wraps nothing (input dupe by
    // construction) and pass 2 matches nothing — the copies must come back
    // byte-identical, header, comments, and trailing commas included.
    const bundle =
        \\[
        \\    { "meta": { "author": "fp" } },
        \\    // a plain engine entity
        \\    { "Position": { "x": 1 } },
        \\    { "prefab": "external", "overrides": { "Position": { "x": 2 } } },
        \\]
    ;
    const out = try rewritePackLocalRefs(allocator, bundle, &.{"SkyBody"}, &.{"sun"}, "sky");
    defer allocator.free(out);
    try std.testing.expectEqualStrings(bundle, out);

    const wrapper =
        \\{
        \\    "name": "thing",
        \\    "root": { "components": { "Position": { "x": 0 } }, },
        \\}
    ;
    const w_out = try rewritePackLocalRefs(allocator, wrapper, &.{"SkyBody"}, &.{"sun"}, "sky");
    defer allocator.free(w_out);
    try std.testing.expectEqualStrings(wrapper, w_out);
}

test "bundleHeaderLegacyEntitiesOffset: dead entities on a header are flagged, not rewritten (#521 codex)" {
    const allocator = std.testing.allocator;
    // Engine parity (v1.66.0 `isFileHeader`): `entities` does NOT
    // disqualify a header — the engine still consumes the element as file
    // metadata and extracts only `meta`, so the list inside is dead data it
    // never loads. The rewrite must keep the element byte-verbatim
    // (mutating it would rewrite engine-metadata bytes); this probe is what
    // lets `generate` warn about the probable authoring mistake instead.
    const src =
        \\[
        \\    { "meta": { "v": 1 }, "entities": [ { "SkyBody": { "role": "dead" } } ] },
        \\    { "SkyBody": { "role": "sun" } }
        \\]
    ;
    // The probe points at the header's `entities` key …
    const off = bundleHeaderLegacyEntitiesOffset(src);
    try std.testing.expect(off != null);
    try std.testing.expect(std.mem.startsWith(u8, src[off.?..], "entities"));
    // … an entity-first bundle (no header) and a clean header report nothing …
    try std.testing.expect(bundleHeaderLegacyEntitiesOffset("[ { \"Position\": {} } ]") == null);
    try std.testing.expect(bundleHeaderLegacyEntitiesOffset("[ { \"meta\": {} } ]") == null);
    // … and the rewrite still skips the whole header verbatim: the dead
    // pack key inside it stays bare while the live sibling namespaces.
    const out = try rewritePackLocalRefs(allocator, src, &.{"SkyBody"}, &.{}, "sky");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"entities\": [ { \"SkyBody\": { \"role\": \"dead\" } } ]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"components\": { \"sky__SkyBody\": { \"role\": \"sun\" }") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "sky__SkyBody"));
}
