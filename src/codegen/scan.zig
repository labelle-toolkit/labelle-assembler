//! Discovery + scanning helpers extracted from `main_zig.zig`
//! (labelle-assembler#183, PoC slice).
//!
//! Owns the AST-walk that turns plugin / game-script source files into the
//! `PluginEvent` / `PluginFlowNode` / `PluginPinStyle` / `PluginCoercion`
//! data the orchestrator pours into the generated `main.zig` registries.
//! These functions are deliberately pure (allocator in / allocator-owned
//! data out) so they can be moved without touching the orchestrator's
//! template-slot wiring.
//!
//! ⚠️  Bit-identical contract: every string this module writes (the
//! sanitized plugin idents, the path-derived idents) feeds directly into
//! `main.zig` source. A typo here drifts the generated source for every
//! downstream backend. The orchestrator's tests already cover the
//! emission shape end-to-end; the helpers here also carry the
//! `pathToIdent` tests that were already in `main_zig.zig`.

const std = @import("std");
const config = @import("../config.zig");
const cache = @import("../cache.zig");
const script_scanner = @import("../script_scanner.zig");
const scanners = @import("../flow_catalog/scanners.zig");
const idents = @import("idents.zig");

const ProjectConfig = config.ProjectConfig;
const ScriptEntry = script_scanner.ScriptScanner.ScriptEntry;

/// Write a formatted message directly to stderr without a log-level prefix.
///
/// `std.log.err` is deliberately avoided here for the same reason as in
/// `src/scene_manifest.zig`: the assembler's test suite has negative-path
/// tests that `expectError(...)` from these emitters, and the test runner's
/// log interceptor would flag any `std.log.err` call as a hard failure even
/// when the surrounding test is *expecting* the error. Writing to stderr
/// directly (via the process-wide Io from `config.globalIo()`) keeps the
/// human-readable diagnostic in front of the user without tripping that
/// trap. Mirrors the `writeStderr` helpers in `main.zig` / `cache_cmd.zig`,
/// just with `bufPrint` for the `{d}` substitution; the format string is
/// printed verbatim on bufPrint overflow so the user still sees *something*.
fn stderrPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    std.Io.File.stderr().writeStreamingAll(config.globalIo(), msg) catch {};
}

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
///      CONTAINER; its object-valued `"root"` member is the entity. Other
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
/// header element walks as opaque `.payload`), and a root object carrying
/// an object-valued `"root"` key is the legacy wrapper (the document object
/// walks as `.file_container`, its `"root"` value as the entity). The
/// per-entity scope rules below are unchanged.
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
    const root_wrapped = isRootWrapperFile(src);

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
                // A root-wrapper file's document object is a container; only
                // its `"root"` value is entity content (engine `rootObject`).
                if (scope_stack.items.len == 0 and root_wrapped) break :blk .file_container;
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
    /// (v1.0 — v1.x, #516): a pure CONTAINER, not an entity. Its
    /// object-valued `"root"` member is the entity (engine `rootObject`);
    /// its `children`/`entities` arrays stay live entity lists (the
    /// engine's `fileChildren` keeps consulting them as the
    /// partial-migration fallback, labelle-engine#573); every other member
    /// — file metadata like `"name"`, dead flat keys — is opaque.
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
        .file_container => blk: {
            // Only an OBJECT-valued `"root"` can land here (childScope is
            // consulted for `{` opens only), matching the engine's
            // `getObject("root")` — an array/scalar `"root"` never becomes
            // the entity. A `"root"` key on a NESTED entity stays payload:
            // the engine unwraps the wrapper at file level only.
            if (pending_key) |k| {
                if (std.mem.eql(u8, k, "root")) break :blk .entity;
            }
            break :blk .payload;
        },
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

/// True iff the file's top-level value is an object carrying an
/// object-valued `"root"` key — the legacy v1.0 — v1.x root-wrapper shape,
/// still dual-accepted by the engine (#516). Mirrors the engine's
/// `rootObject` (`file_obj.getObject("root") orelse file_obj`): the FIRST
/// `"root"` entry decides (the engine's `Object.get` returns the first
/// match), and a non-object `"root"` value means the file object itself is
/// the entity. A document head this scanner cannot account for is treated
/// as not-a-wrapper, keeping today's plain-shape behavior for malformed
/// input.
fn isRootWrapperFile(src: []const u8) bool {
    const probe = FlatWrap{ .src = src, .component_keys = &.{} };
    var i = probe.skipTrivia(0);
    if (i >= src.len or src[i] != '{') return false;
    i += 1;
    while (true) {
        i = probe.skipTrivia(i);
        if (i >= src.len) return false;
        if (src[i] == '}') return false; // no "root" key — plain shape
        if (src[i] != '"') return false;
        const key_end = probe.scanString(i) catch return false;
        const key = src[i + 1 .. key_end - 1];
        i = probe.skipTrivia(key_end);
        if (i >= src.len or src[i] != ':') return false;
        i = probe.skipTrivia(i + 1);
        if (i >= src.len) return false;
        if (std.mem.eql(u8, key, "root")) return src[i] == '{';
        const value_end = probe.scanValue(i) catch return false;
        i = probe.skipTrivia(value_end);
        if (i >= src.len) return false;
        if (src[i] == ',') {
            i += 1;
            continue;
        }
        return false;
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
            '{' => if (isRootWrapperFile(s))
                try self.emitFileContainer(allocator, out, start)
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
    /// Its object-valued `"root"` member descends as the entity;
    /// `children`/`entities` arrays at container level stay live entity
    /// lists (the engine's `fileChildren` keeps consulting them as the
    /// partial-migration fallback, labelle-engine#573); every other member
    /// — file metadata like `"name"`, dead flat keys the engine never
    /// reads — is copied verbatim and never wrapped. Returns one past the
    /// container's `}`.
    fn emitFileContainer(
        self: *FlatWrap,
        allocator: std.mem.Allocator,
        out: *std.ArrayList(u8),
        at: usize,
    ) Error!usize {
        const s = self.src;
        const obj = try self.parseObject(allocator, at);
        defer allocator.free(obj.pairs);

        try out.append(allocator, '{');
        var emitted_any = false;
        for (obj.pairs) |p| {
            if (emitted_any) try out.append(allocator, ',');
            try out.appendSlice(allocator, s[p.lead_start..p.value_start]);
            if (std.mem.eql(u8, p.key, "root") and s[p.value_start] == '{') {
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

/// Rewrite a pack's copied `hooks/*.zig` source so a handler written with the
/// pack's BARE local event name receives its `<pack>__`-prefixed event
/// (chatgpt-codex finding #3).
///
/// The engine's hook dispatcher (`labelle-core/src/dispatcher.zig`) matches a
/// receiver's handler-fn NAME against the `GameEvents` variant tag. Pack
/// events are folded into `GameEvents` under the invisible `<pack>__<event>`
/// tag, so a pack hook's natural `pub fn worker_died(self, data)` would (a)
/// never receive `citizens__worker_died`, and worse (b) trip the dispatcher's
/// comptime guard — a 2-param handler whose name matches no variant is a hard
/// `@compileError`. To keep the prefix invisible, this renames each qualifying
/// handler's DECL to the prefixed tag (`worker_died` → `citizens__worker_died`)
/// in the copied source, exactly mirroring the JSONC key/prefab rewrite.
///
/// A handler qualifies only when it is a `pub fn`, takes exactly two
/// parameters (the `(self, data)` shape the dispatcher treats as a handler),
/// and its name equals the BASENAME/variant of one of the pack's own
/// `event_names` (`eventVariantName` — so a subdir event `combat/worker_died`
/// still matches a `pub fn worker_died`, since the emitted tag is
/// `<pack>__worker_died`) (chatgpt-codex L435). Handlers for engine / plugin /
/// game events (bare names that are already valid variant tags — e.g. `tick`,
/// `game_init`) are left untouched, so a pack hook keeps receiving those. Only
/// the declaration site is renamed; a pack that also calls its handler
/// internally by the bare name would surface a clean compile error rather than
/// a silent mis-dispatch.
///
/// **Receiver-scoped (CodeRabbit L435).** The rename is confined to the DIRECT
/// members of the hook file's receiver container — the `pub const <Pascal> =
/// struct { … }` whose name is `pathToPascal(hook_stem)` (the exact type the
/// generated `GameHooks` tuple references). Top-level `pub fn`s and unrelated
/// helper structs elsewhere in the file are never touched, so a helper API that
/// happens to share an event name (and arity) keeps its name and any internal
/// callers stay valid.
///
/// Returns an allocator-owned buffer; a content-preserving dupe when nothing
/// matches, so the caller frees unconditionally.
pub fn rewritePackHookHandlerNames(
    allocator: std.mem.Allocator,
    src: []const u8,
    event_names: []const []const u8,
    prefix: []const u8,
    hook_stem: []const u8,
) ![]u8 {
    if (event_names.len == 0) return allocator.dupe(u8, src);

    var receiver_buf: [128]u8 = undefined;
    const receiver = idents.pathToPascal(hook_stem, &receiver_buf);

    const src_z = try allocator.dupeZ(u8, src);
    defer allocator.free(src_z);

    var ast = try std.zig.Ast.parse(allocator, src_z, .zig);
    defer ast.deinit(allocator);

    // Collect the byte offsets of every handler-fn name token to rename —
    // scoped to the receiver container so unrelated decls are never renamed.
    var sites: std.ArrayList(usize) = .empty;
    defer sites.deinit(allocator);
    try collectReceiverHandlerNameOffsets(allocator, &ast, ast.rootDecls(), receiver, event_names, &sites);

    if (sites.items.len == 0) return allocator.dupe(u8, src);
    std.mem.sort(usize, sites.items, {}, std.sort.asc(usize));

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var cursor: usize = 0;
    for (sites.items) |off| {
        // Each recorded offset is the start of a bare event-name token. Emit
        // everything up to it, then the `<prefix>__` insertion; the original
        // name bytes follow untouched (cursor advances past the prefix only).
        try out.appendSlice(allocator, src[cursor..off]);
        try out.appendSlice(allocator, prefix);
        try out.appendSlice(allocator, "__");
        cursor = off;
    }
    try out.appendSlice(allocator, src[cursor..]);
    return out.toOwnedSlice(allocator);
}

/// Find the hook file's receiver container — the root-level
/// `const <receiver> = struct/union/enum { … }` whose name is the Pascal form
/// of the hook stem — and collect the byte offsets of its DIRECT handler-fn
/// name tokens into `sites`. Only that one container is walked, and its members
/// are NOT recursed into, so top-level helpers and unrelated helper structs are
/// never renamed (CodeRabbit L435). See `rewritePackHookHandlerNames`.
fn collectReceiverHandlerNameOffsets(
    allocator: std.mem.Allocator,
    ast: *std.zig.Ast,
    root_decls: []const std.zig.Ast.Node.Index,
    receiver: []const u8,
    event_names: []const []const u8,
    sites: *std.ArrayList(usize),
) !void {
    for (root_decls) |decl| {
        const vd = ast.fullVarDecl(decl) orelse continue;
        const name_tok = vd.ast.mut_token + 1;
        if (!std.mem.eql(u8, ast.tokenSlice(name_tok), receiver)) continue;
        const init_node = vd.ast.init_node.unwrap() orelse continue;
        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const container = ast.fullContainerDecl(&buf, init_node) orelse continue;
        collectDirectHandlerNameOffsets(allocator, ast, container.ast.members, event_names, sites) catch |e| return e;
        // Exactly one receiver container matters; stop after the first match.
        return;
    }
}

/// Record the source byte offset of each qualifying `pub fn <event>(self, data)`
/// name token among `members` (the receiver's DIRECT members — no recursion).
/// A handler matches when its name equals the basename/variant of a pack event.
fn collectDirectHandlerNameOffsets(
    allocator: std.mem.Allocator,
    ast: *std.zig.Ast,
    members: []const std.zig.Ast.Node.Index,
    event_names: []const []const u8,
    sites: *std.ArrayList(usize),
) !void {
    for (members) |m| {
        var fn_buf: [1]std.zig.Ast.Node.Index = undefined;
        const fp = ast.fullFnProto(&fn_buf, m) orelse continue;
        if (fp.visib_token == null) continue;
        const nt = fp.name_token orelse continue;
        const name = ast.tokenSlice(nt);
        if (matchesEventBasename(event_names, name) and fnProtoParamCount(ast, fp) == 2) {
            // `tokenSlice` returns a sub-slice of `ast.source`; its pointer
            // offset is the byte position we splice at.
            const off = @intFromPtr(name.ptr) - @intFromPtr(ast.source.ptr);
            try sites.append(allocator, off);
        }
    }
}

/// True iff `handler_name` equals the emitted variant BASENAME of one of the
/// pack's `event_names` (`eventVariantName` strips any subdir + `.zig`), so a
/// handler `pub fn worker_died` matches a pack event scanned as
/// `combat/worker_died` (chatgpt-codex L435).
fn matchesEventBasename(event_names: []const []const u8, handler_name: []const u8) bool {
    for (event_names) |e| {
        if (std.mem.eql(u8, idents.eventVariantName(e), handler_name)) return true;
    }
    return false;
}

fn fnProtoParamCount(ast: *std.zig.Ast, fp: std.zig.Ast.full.FnProto) usize {
    var count: usize = 0;
    var it = fp.iterate(ast);
    while (it.next()) |_| count += 1;
    return count;
}

/// A single discovered `pub const <event_name> = struct {...}` declaration
/// inside a plugin's `pub const Events = struct { ... }`. Owned by
/// `PluginEvents.deinit` — all three strings (`plugin_import_name`,
/// `plugin_sanitized`, `event_name`) are heap-allocated dupes so the
/// caller need not keep the plugin's source buffer alive.
pub const PluginEvent = struct {
    /// Plugin name as it appears in `project.labelle` (e.g. `box2d`,
    /// `labelle-physics`). Used for the `@import("<name>")` reference
    /// emitted into the union variant type.
    plugin_import_name: []const u8,
    /// Sanitized identifier form of `plugin_import_name` (e.g.
    /// `labelle-physics` → `labelle_physics`). Used as the prefix in
    /// the qualified variant tag.
    plugin_sanitized: []const u8,
    /// Bare event identifier (e.g. `collision_begin`).
    event_name: []const u8,
};

/// Collection of `PluginEvent`s with an allocator-aware `deinit`. The
/// list itself and every string inside it live in the same allocator.
pub const PluginEvents = struct {
    entries: []PluginEvent,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PluginEvents) void {
        for (self.entries) |e| {
            self.allocator.free(e.plugin_import_name);
            self.allocator.free(e.plugin_sanitized);
            self.allocator.free(e.event_name);
        }
        self.allocator.free(self.entries);
        self.entries = &.{};
    }
};

/// Walk each plugin's source tree and collect every `pub const <name> = struct`
/// declaration sitting inside the plugin's top-level `pub const Events = struct`.
/// Mirrors the on-disk convention RFC-PLUGIN-EVENTS phase 1 codified, but at
/// assembler time so the emitted `PluginEvents` union can be a written-out
/// `union(enum) { … }` literal — `@Union(.auto, …)` with zero fields produces
/// an uninstantiable type (rejected by `std.ArrayList`'s `@memset(undefined)`
/// in 0.16), which is the root cause of the plugin-controllers CI failure.
///
/// Plugins without `src/root.zig` or without a `Events` decl contribute zero
/// entries — that's the back-compat path every existing plugin (labelle-fsm,
/// labelle-pathfinding, the plugin-controllers demo plugin) takes.
pub fn discoverPluginEvents(
    allocator: std.mem.Allocator,
    cfg: ProjectConfig,
    project_dir: []const u8,
) !PluginEvents {
    var entries: std.ArrayList(PluginEvent) = .empty;
    errdefer {
        for (entries.items) |e| {
            allocator.free(e.plugin_import_name);
            allocator.free(e.plugin_sanitized);
            allocator.free(e.event_name);
        }
        entries.deinit(allocator);
    }

    // ── Engine pass (labelle-engine#578) ─────────────────────────────
    //
    // The engine is a peer dependency, not a plugin, so it doesn't
    // appear in `cfg.plugins` — but it does declare a `pub const
    // Events` block (`labelle-engine/src/root.zig`) that flows want to
    // listen to under the `engine.<event>` dotted form. Walk the
    // engine's `src/root.zig` here so the same `Events` discovery
    // pipeline that handles plugins folds in `engine__game_init` /
    // `engine__tick` / etc. without a separate code path.
    //
    // The "name" stored on each discovered `PluginEvent` is the
    // literal string `engine` — this matches the on-disk JSONC dot
    // form (`engine.tick`) and the qualified tag the engine's
    // `emitEngineEvent` helper passes to `@unionInit(GameEvents,
    // "engine__<event>", ...)`. The actual Zig module name is
    // `labelle-engine` (not `engine`) — `writePluginEventsBlock`
    // special-cases the `engine` prefix when emitting the `@import`
    // target.
    blk_engine: {
        const engine_dir = cache.resolveFrameworkPackage(
            allocator,
            "engine",
            cfg.engine_version,
            project_dir,
        ) catch break :blk_engine;
        defer allocator.free(engine_dir);
        try discoverEventsFromRoot(allocator, &entries, engine_dir, "engine");
    }

    // ── Plugin pass ─────────────────────────────────────────────────
    for (cfg.plugins) |plugin| {
        const plugin_dir = cache.resolvePlugin(allocator, plugin, project_dir) catch continue;
        defer allocator.free(plugin_dir);
        try discoverEventsFromRoot(allocator, &entries, plugin_dir, plugin.name);
    }

    return .{
        .entries = try entries.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Helper: load `<module_dir>/src/root.zig`, AST-walk it for a top-
/// level `pub const Events = struct { ... }` declaration, and append
/// every `pub const <event_name> = struct {...}` child as a
/// `PluginEvent` keyed by `module_name`. Used by both the engine pass
/// and the plugin loop in `discoverPluginEvents`.
///
/// Missing `src/root.zig` (or unreadable source / parse failure) is
/// silently tolerated — the same back-compat path every existing
/// plugin without an `Events` decl already takes.
fn discoverEventsFromRoot(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(PluginEvent),
    module_dir: []const u8,
    module_name: []const u8,
) !void {
    const root_path = try std.fs.path.join(allocator, &.{ module_dir, "src", "root.zig" });
    defer allocator.free(root_path);

    const io = config.globalIo();
    // Tolerate any non-OOM read failure (missing root.zig, parse errors,
    // permission issues) — same back-compat path every existing plugin
    // without an `Events` decl takes. OOM is *not* swallowed: it
    // propagates so the caller's allocator sees a clean failure path
    // instead of an empty-discovery false negative under memory pressure.
    const src = std.Io.Dir.cwd().readFileAlloc(io, root_path, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer allocator.free(src);

    const src_z = try allocator.dupeZ(u8, src);
    defer allocator.free(src_z);

    var ast = try std.zig.Ast.parse(allocator, src_z, .zig);
    defer ast.deinit(allocator);

    var name_buf: [128]u8 = undefined;
    const sanitized = sanitizePluginIdent(module_name, &name_buf);

    const root_decls = ast.rootDecls();
    for (root_decls) |decl_idx| {
        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const vd = ast.fullVarDecl(decl_idx) orelse continue;
        // Only `pub const Events = …` qualifies — non-pub or
        // non-`Events` declarations are skipped silently so
        // a module can have its own internal `const Events` helper
        // without leaking into the union.
        if (vd.visib_token == null) continue;
        const name_tok = vd.ast.mut_token + 1;
        const decl_name = ast.tokenSlice(name_tok);
        if (!std.mem.eql(u8, decl_name, "Events")) continue;

        const init_node = vd.ast.init_node.unwrap() orelse continue;
        const container = ast.fullContainerDecl(&buf, init_node) orelse continue;

        for (container.ast.members) |m| {
            const member_vd = ast.fullVarDecl(m) orelse continue;
            if (member_vd.visib_token == null) continue;
            // Skip non-type members — `pub const FOO = 42;` inside
            // `Events` is unusual but not a syntax error, and we
            // only care about struct/union type aliases.
            const event_init = member_vd.ast.init_node.unwrap() orelse continue;
            if (ast.fullContainerDecl(&buf, event_init) == null) continue;

            const event_name_tok = member_vd.ast.mut_token + 1;
            const event_name = ast.tokenSlice(event_name_tok);

            // Errdefer-per-dupe so a mid-chain OOM (or the final
            // `append`) can't strand the already-duped strings. Each
            // errdefer is cancelled once `append` succeeds and the
            // entry takes ownership of all three slices.
            const duped_import_name = try allocator.dupe(u8, module_name);
            errdefer allocator.free(duped_import_name);
            const duped_sanitized = try allocator.dupe(u8, sanitized);
            errdefer allocator.free(duped_sanitized);
            const duped_event_name = try allocator.dupe(u8, event_name);
            errdefer allocator.free(duped_event_name);

            try entries.append(allocator, .{
                .plugin_import_name = duped_import_name,
                .plugin_sanitized = duped_sanitized,
                .event_name = duped_event_name,
            });
        }
    }
}

// ── RFC-FLOW-VOCABULARY phase 2 — FlowNodes + PinStyles discovery ──────
//
// Walk each plugin's `src/root.zig` and each game-script `.zig` file for
// `pub const FlowNodes` and `pub const PinStyles` declarations. The
// convention parallels `Events` / `Components` / `Systems`:
//
//   pub const FlowNodes = struct {
//       pub const apply_impulse = labelle.FlowNode(.{ .impl = applyImpulseImpl });
//       pub const get_velocity  = labelle.FlowNode(.{ .impl = getVelocityImpl });
//   };
//
//   pub const PinStyles = struct {
//       pub const BodyId = labelle.PinStyle{ .label = "Body", .color = ... };
//   };
//
// Per RFC §5, any module under the project tree (plugins OR game
// scripts) that exports `FlowNodes` is a palette source. The
// emitted `PluginFlowNodes` registry the editor and flow-codegen
// (phase 3 `CustomNode` lowering) consume is keyed by a
// plugin-qualified identifier (`<module>__<name>`), same convention
// as `PluginEvents`, so a flow's on-disk dotted name
// (`box2d.apply_impulse`) maps to a Zig identifier
// (`box2d__apply_impulse`).
//
// Phase 5 (parallel ticket) adds the actual `FlowNodes` declarations
// to labelle-box2d; this discovery is the first real consumer.

/// One discovered `pub const <name> = labelle.FlowNode(...)` decl
/// inside a `pub const FlowNodes = struct { ... }` block. Both the
/// import path and the module-qualified identifier are kept so the
/// emitter can write the registry entry verbatim without re-deriving
/// either at codegen time.
pub const PluginFlowNode = struct {
    /// Identifier used by Zig's `@import(...)` for the source
    /// module. For plugins, this is the project.labelle `.name` (the
    /// same string `@import` resolves against in the generated
    /// main.zig). For game-script modules, this is the relative path
    /// under `scripts/` (e.g. `hits.zig` or `flows/hit_counter.zig`),
    /// emitted as `@import("scripts/<rel_path>")` to match how
    /// `all_scripts_block` already references game scripts.
    module_import_path: []const u8,
    /// Sanitized identifier form of the source module. For plugins
    /// this is the same `sanitizePluginIdent` output as
    /// `PluginEvent.plugin_sanitized` (e.g. `labelle-box2d` →
    /// `labelle_box2d`). For game-script modules this is
    /// `pathToIdent` of the rel_path (escaped per the standard
    /// path→ident mapping so `flows/hit_counter.zig` becomes
    /// `flows_s_hit_u_counter`). Used as the prefix in the qualified
    /// registry decl name `<module_sanitized>__<node_name>`.
    module_sanitized: []const u8,
    /// Bare node identifier as declared inside `FlowNodes` (e.g.
    /// `apply_impulse`).
    node_name: []const u8,
    /// `true` when the source is a game-script module; `false` for
    /// plugin modules. Drives which `@import` form the emitter
    /// writes — plugins resolve as `@import("<name>")`, scripts as
    /// `@import("scripts/<rel_path>")`.
    is_script: bool,
    /// `true` when the node's `impl` fn returns `void` — a **command**
    /// (RFC-FLOW-VOCABULARY §6). flow-codegen's `CustomNode` lowering
    /// emits a bare statement for commands and binds the result to
    /// `n<id>_value` for reporters (non-void). The assembler computes
    /// this once at discovery time so flow-codegen consumes the
    /// precomputed flag rather than re-reflecting the impl. An explicit
    /// `.kind = .command` / `.kind = .reporter` in the FlowNode factory
    /// call overrides the inferred return-type default — same rule the
    /// editor catalog applies in `flow_catalog/discovery.zig`.
    is_void: bool = true,
    /// Fully-qualified Zig type name the node constructs, captured
    /// from a `.constructs = "..."` field in the source `FlowNode`
    /// factory call, or `null` when the source omits it
    /// (RFC-FLOW-VOCABULARY §1, open question O5). The string is
    /// extracted textually from the init expression — the AST scan
    /// doesn't evaluate the factory call, so the source must spell
    /// the value as a literal `"..."` string. Threaded through to
    /// the editor (phase 4) so the palette can suggest constructor
    /// nodes for struct-typed `SetVariable` targets.
    constructs: ?[]const u8 = null,
};

/// One discovered `pub const <TypeName> = labelle.PinStyle{ ... }`
/// decl inside a `pub const PinStyles = struct { ... }` block. The
/// editor merges these on top of `default_pin_styles`; per RFC §1,
/// later declarations win for duplicate type keys, so the assembler
/// dedups by `type_name` (last-write-wins) before emitting.
pub const PluginPinStyle = struct {
    /// Same shape as `PluginFlowNode.module_import_path`.
    module_import_path: []const u8,
    /// Same shape as `PluginFlowNode.module_sanitized`.
    module_sanitized: []const u8,
    /// Zig type name (e.g. `BodyId`). The emitted registry uses this
    /// verbatim as the decl name — duplicates across modules collapse
    /// to last-write-wins.
    type_name: []const u8,
    /// Same meaning as `PluginFlowNode.is_script`.
    is_script: bool,
};

/// One discovered `pub const <name> = labelle.flow.Coercion(...)` decl
/// inside a `pub const Coercions = struct { ... }` block
/// (RFC-FLOW-VOCABULARY §2 / O4). Same ownership pattern as
/// `PluginFlowNode` / `PluginPinStyle` — every string is a
/// heap-allocated dupe owned by the enclosing `PluginFlowDecls`.
///
/// The qualified emitted decl name is `<module_sanitized>__<name>`
/// matching the FlowNodes / Events convention.
pub const PluginCoercion = struct {
    /// Same shape as `PluginFlowNode.module_import_path`.
    module_import_path: []const u8,
    /// Same shape as `PluginFlowNode.module_sanitized`. Used as the
    /// `<module>__<name>` prefix on the emitted registry decl.
    module_sanitized: []const u8,
    /// Bare coercion identifier as declared inside `Coercions` (e.g.
    /// `body_to_entity`).
    name: []const u8,
    /// Same meaning as `PluginFlowNode.is_script`.
    is_script: bool,
};

/// Collection of discovered FlowNodes + PinStyles + Coercions with an
/// allocator-aware `deinit`. Same ownership story as `PluginEvents`
/// — every string field on every entry is a heap-allocated dupe so
/// callers need not keep source buffers alive.
pub const PluginFlowDecls = struct {
    flow_nodes: []PluginFlowNode,
    pin_styles: []PluginPinStyle,
    /// RFC-FLOW-VOCABULARY §2 / O4 — plugin-declared coercions. Empty
    /// when no module declares a `pub const Coercions` block; the
    /// emitter still writes an empty `PluginCoercions = struct {}`
    /// shell so downstream reflection (flow-codegen edge wrap) is
    /// uniform.
    coercions: []PluginCoercion,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PluginFlowDecls) void {
        for (self.flow_nodes) |fn_| {
            self.allocator.free(fn_.module_import_path);
            self.allocator.free(fn_.module_sanitized);
            self.allocator.free(fn_.node_name);
            if (fn_.constructs) |c| self.allocator.free(c);
        }
        self.allocator.free(self.flow_nodes);
        self.flow_nodes = &.{};
        for (self.pin_styles) |ps| {
            self.allocator.free(ps.module_import_path);
            self.allocator.free(ps.module_sanitized);
            self.allocator.free(ps.type_name);
        }
        self.allocator.free(self.pin_styles);
        self.pin_styles = &.{};
        for (self.coercions) |co| {
            self.allocator.free(co.module_import_path);
            self.allocator.free(co.module_sanitized);
            self.allocator.free(co.name);
        }
        self.allocator.free(self.coercions);
        self.coercions = &.{};
    }
};

/// Extract the literal string value of a `.constructs = "..."` field
/// from the source text of a `FlowNode(.{...})` factory call
/// (RFC-FLOW-VOCABULARY §1 / O5). Returns an allocator-owned dupe of
/// the unescaped value, or `null` when the field is absent / not a
/// plain string literal.
///
/// Scan strategy is deliberately tolerant: walks the source byte by
/// byte while tracking whether we're inside a string or comment, so a
/// `.constructs` keyword appearing inside another string (e.g. as part
/// of `.docs`) doesn't trigger a false match. Stops at the first
/// match — multiple `.constructs` fields aren't valid Zig anyway, so
/// "last wins" never comes into play. A truly malformed factory call
/// surfaces as a Zig compile error at the consumer site, not here.
fn extractConstructsString(allocator: std.mem.Allocator, src: []const u8) ?[]u8 {
    const needle = ".constructs";
    var i: usize = 0;
    while (i + needle.len <= src.len) : (i += 1) {
        const c = src[i];
        // Skip over Zig string literals so a `.docs = ".constructs = ..."`
        // doesn't false-match. The scanner only handles the `"..."`
        // form (no `\\` multiline strings) — the factory's typical
        // usage stays well within that subset.
        if (c == '"') {
            i += 1;
            while (i < src.len) : (i += 1) {
                if (src[i] == '\\' and i + 1 < src.len) {
                    i += 1; // skip escaped char
                    continue;
                }
                if (src[i] == '"') break;
            }
            continue;
        }
        // Skip line comments.
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            while (i < src.len and src[i] != '\n') : (i += 1) {}
            continue;
        }
        if (!std.mem.startsWith(u8, src[i..], needle)) continue;
        // Verify the byte before isn't an identifier char — otherwise
        // we'd match `.subconstructs` or `.foo_constructs`.
        if (i > 0) {
            const prev = src[i - 1];
            if ((prev >= 'a' and prev <= 'z') or (prev >= 'A' and prev <= 'Z') or
                (prev >= '0' and prev <= '9') or prev == '_')
            {
                continue;
            }
        }
        // Verify the byte after the keyword isn't an identifier char
        // either (so `.constructs_x` is rejected).
        const after_kw = i + needle.len;
        if (after_kw < src.len) {
            const next = src[after_kw];
            if ((next >= 'a' and next <= 'z') or (next >= 'A' and next <= 'Z') or
                (next >= '0' and next <= '9') or next == '_')
            {
                continue;
            }
        }
        // Skip whitespace and the `=`, expect a `"..."` literal.
        var j = after_kw;
        while (j < src.len and (src[j] == ' ' or src[j] == '\t' or src[j] == '\n' or src[j] == '\r')) : (j += 1) {}
        if (j >= src.len or src[j] != '=') return null;
        j += 1;
        while (j < src.len and (src[j] == ' ' or src[j] == '\t' or src[j] == '\n' or src[j] == '\r')) : (j += 1) {}
        if (j >= src.len or src[j] != '"') return null;
        const start = j + 1;
        var k = start;
        while (k < src.len) : (k += 1) {
            if (src[k] == '\\' and k + 1 < src.len) {
                k += 1;
                continue;
            }
            if (src[k] == '"') break;
        }
        if (k >= src.len) return null;
        return allocator.dupe(u8, src[start..k]) catch null;
    }
    return null;
}

/// Resolve a FlowNode's command-vs-reporter shape — `true` for a
/// `void`-returning (command) impl, `false` for a value-returning
/// (reporter) one. Mirrors the editor-catalog rule in
/// `flow_catalog/discovery.zig` so the two discovery paths agree:
///
///   1. An explicit `.kind = .command` / `.kind = .reporter` in the
///      `labelle.FlowNode(.{...})` factory call always wins.
///   2. Otherwise the impl's declared return type decides: `void` (or
///      an impl we can't resolve / that omits a return type) is a
///      command; anything else is a reporter.
///
/// `init_src` is the FlowNode factory call's source text; `ast` is the
/// already-parsed module AST so we can walk back to the impl fn's
/// prototype. A non-resolvable `impl` (defined in a sibling file)
/// degrades to `is_void = true` — the command shape — matching the
/// catalog's "no pin info" fallback, since we have no return type to
/// promote it to a reporter.
fn flowNodeIsVoid(ast: *std.zig.Ast, init_src: []const u8) bool {
    const cfg_src = scanners.innerCallArg(init_src);

    // Explicit `.kind` override — same precedence as the catalog.
    if (scanners.scanFieldEnumLit(cfg_src, ".kind")) |ek| {
        if (std.mem.eql(u8, ek, "command")) return true;
        if (std.mem.eql(u8, ek, "reporter")) return false;
    }

    // Infer from the impl's return type. Skip the implicit
    // `game: anytype` — we only care about the return, not the params.
    const impl_name = scanners.scanFieldIdent(cfg_src, ".impl") orelse return true;
    if (impl_name.len == 0) return true;
    const fn_node = scanners.findFnByName(ast, impl_name) orelse return true;
    var fn_buf: [1]std.zig.Ast.Node.Index = undefined;
    const fp = ast.fullFnProto(&fn_buf, fn_node) orelse return true;
    const rt_node = fp.ast.return_type.unwrap() orelse return true;
    const rt = std.mem.trim(u8, ast.getNodeSource(rt_node), " \t\r\n");
    // A fallible command (`!void` / `anyerror!void`) is still a command —
    // the error union adds no output pin. Kept in lock-step with the
    // editor-catalog inference in `flow_catalog/discovery.zig`.
    return std.mem.eql(u8, rt, "void") or std.mem.endsWith(u8, rt, "!void");
}

/// Walk one `.zig` source buffer for `pub const FlowNodes`,
/// `pub const PinStyles`, and `pub const Coercions` decls, appending
/// each discovered nested member to the corresponding output list.
/// The three outputs share the same `module_import_path` /
/// `module_sanitized` / `is_script` values (passed in by the caller),
/// so the per-module identification is decided once at the call site
/// rather than re-derived per entry.
///
/// Buffer is the file contents; the caller owns it. The parsed AST
/// is local to this function; only `allocator.dupe`d strings outlive
/// the call.
fn scanFlowDeclsInSource(
    allocator: std.mem.Allocator,
    src: []const u8,
    module_import_path: []const u8,
    module_sanitized: []const u8,
    is_script: bool,
    flow_nodes_out: *std.ArrayList(PluginFlowNode),
    pin_styles_out: *std.ArrayList(PluginPinStyle),
    coercions_out: *std.ArrayList(PluginCoercion),
) !void {
    const src_z = try allocator.dupeZ(u8, src);
    defer allocator.free(src_z);

    var ast = try std.zig.Ast.parse(allocator, src_z, .zig);
    defer ast.deinit(allocator);

    const root_decls = ast.rootDecls();
    for (root_decls) |decl_idx| {
        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const vd = ast.fullVarDecl(decl_idx) orelse continue;
        // Non-pub helpers (e.g. an internal `const FlowNodes` used by
        // the module itself) are skipped silently — same precedent
        // `discoverPluginEvents` follows.
        if (vd.visib_token == null) continue;
        const name_tok = vd.ast.mut_token + 1;
        const decl_name = ast.tokenSlice(name_tok);

        const is_flow_nodes = std.mem.eql(u8, decl_name, "FlowNodes");
        const is_pin_styles = std.mem.eql(u8, decl_name, "PinStyles");
        const is_coercions = std.mem.eql(u8, decl_name, "Coercions");
        if (!is_flow_nodes and !is_pin_styles and !is_coercions) continue;

        const init_node = vd.ast.init_node.unwrap() orelse continue;
        const container = ast.fullContainerDecl(&buf, init_node) orelse continue;

        for (container.ast.members) |m| {
            const member_vd = ast.fullVarDecl(m) orelse continue;
            if (member_vd.visib_token == null) continue;
            // Skip non-value members defensively. The init token for a
            // `pub const apply_impulse = labelle.FlowNode(.{...})` is
            // always present; a `pub const X: T = …` (typed) decl also
            // exposes init_node. The `unwrap()` filter just ensures we
            // never trip on a malformed entry.
            const member_init = member_vd.ast.init_node.unwrap() orelse continue;

            const member_name_tok = member_vd.ast.mut_token + 1;
            const member_name = ast.tokenSlice(member_name_tok);

            if (is_flow_nodes) {
                // RFC-FLOW-VOCABULARY §1 / O5 — capture an optional
                // `.constructs = "..."` field from the factory call's
                // source text. The scanner doesn't evaluate the
                // expression (would require a full compile), so it
                // extracts the literal string verbatim. A non-string
                // `.constructs` (e.g. a comptime expression) is
                // silently ignored — that's a forward-compatible
                // refinement, not a contract worth enforcing here.
                const init_src = ast.getNodeSource(member_init);
                // Errdefer-per-allocation: `constructs_value` is an
                // optional dupe owned by `extractConstructsString`;
                // it leaks if any subsequent dupe or the `append`
                // fails. Each errdefer is cancelled once `append`
                // moves ownership into the entry.
                const constructs_value = extractConstructsString(allocator, init_src);
                errdefer if (constructs_value) |c| allocator.free(c);

                // Command-vs-reporter shape (RFC-FLOW-VOCABULARY §6).
                // Resolved once here so flow-codegen's `CustomNode`
                // lowering consumes the precomputed flag — no allocation,
                // borrows nothing past this loop iteration.
                const is_void = flowNodeIsVoid(&ast, init_src);

                const duped_path = try allocator.dupe(u8, module_import_path);
                errdefer allocator.free(duped_path);
                const duped_sanitized = try allocator.dupe(u8, module_sanitized);
                errdefer allocator.free(duped_sanitized);
                const duped_name = try allocator.dupe(u8, member_name);
                errdefer allocator.free(duped_name);

                try flow_nodes_out.append(allocator, .{
                    .module_import_path = duped_path,
                    .module_sanitized = duped_sanitized,
                    .node_name = duped_name,
                    .is_script = is_script,
                    .is_void = is_void,
                    .constructs = constructs_value,
                });
            } else if (is_pin_styles) {
                const duped_path = try allocator.dupe(u8, module_import_path);
                errdefer allocator.free(duped_path);
                const duped_sanitized = try allocator.dupe(u8, module_sanitized);
                errdefer allocator.free(duped_sanitized);
                const duped_name = try allocator.dupe(u8, member_name);
                errdefer allocator.free(duped_name);

                try pin_styles_out.append(allocator, .{
                    .module_import_path = duped_path,
                    .module_sanitized = duped_sanitized,
                    .type_name = duped_name,
                    .is_script = is_script,
                });
            } else {
                // Coercions block (RFC-FLOW-VOCABULARY §2 / O4).
                // Same shape as FlowNodes — each member is a
                // `labelle.flow.Coercion(.{ .impl = ... })` factory
                // call; the assembler doesn't need to peer inside the
                // call because the From/To types are resolved at
                // comptime in the emitted alias and surfaced via
                // reflection (`PluginCoercions.<qualified>.From` etc.).
                // The flow_catalog sidecar (parallel walk in
                // `flow_catalog.zig`) extracts the textual types for
                // the editor's wire-fit check.
                const duped_path = try allocator.dupe(u8, module_import_path);
                errdefer allocator.free(duped_path);
                const duped_sanitized = try allocator.dupe(u8, module_sanitized);
                errdefer allocator.free(duped_sanitized);
                const duped_name = try allocator.dupe(u8, member_name);
                errdefer allocator.free(duped_name);

                try coercions_out.append(allocator, .{
                    .module_import_path = duped_path,
                    .module_sanitized = duped_sanitized,
                    .name = duped_name,
                    .is_script = is_script,
                });
            }
        }
    }
}

/// Discover `pub const FlowNodes` and `pub const PinStyles` decls
/// across both plugin modules and game-script modules.
///
/// **Plugins** are walked via `<plugin>/src/root.zig` (same convention
/// as `discoverPluginEvents`). Plugins without a `FlowNodes` or
/// `PinStyles` decl contribute zero entries — the back-compat path
/// every existing plugin takes today.
///
/// **Game scripts** are walked from `scripts_root`. Each
/// `ScriptEntry` whose `plugin_name == null` (i.e. game-owned, not a
/// plugin-shipped script) is parsed from
/// `<scripts_root>/<entry.rel_path>`. Per RFC §5, any module in the
/// project tree that exports `FlowNodes` is a palette source — the
/// canonical example is `bouncing-ball/scripts/hits.zig`.
///
/// Plugin-shipped scripts (those with `entry.plugin_name != null`,
/// which live under `<scripts_root>/.plugin_<name>/...`) are skipped
/// here: their containing plugin already gets walked at its
/// `src/root.zig` root decl level. Re-walking them as game scripts
/// would double-count entries and break the qualified-name
/// convention.
///
/// Missing source files / parse errors on individual modules are
/// skipped silently rather than failing the whole `generate` —
/// matches the `discoverPluginEvents` tolerance for plugins without
/// a `src/root.zig`. A genuinely broken script will surface its
/// error later when the generated `main.zig` tries to compile it.
pub fn discoverPluginFlowDecls(
    allocator: std.mem.Allocator,
    cfg: ProjectConfig,
    project_dir: []const u8,
    scripts_root: []const u8,
    script_entries: []const ScriptEntry,
) !PluginFlowDecls {
    var flow_nodes: std.ArrayList(PluginFlowNode) = .empty;
    errdefer {
        for (flow_nodes.items) |e| {
            allocator.free(e.module_import_path);
            allocator.free(e.module_sanitized);
            allocator.free(e.node_name);
            if (e.constructs) |c| allocator.free(c);
        }
        flow_nodes.deinit(allocator);
    }
    var pin_styles: std.ArrayList(PluginPinStyle) = .empty;
    errdefer {
        for (pin_styles.items) |e| {
            allocator.free(e.module_import_path);
            allocator.free(e.module_sanitized);
            allocator.free(e.type_name);
        }
        pin_styles.deinit(allocator);
    }
    var coercions: std.ArrayList(PluginCoercion) = .empty;
    errdefer {
        for (coercions.items) |e| {
            allocator.free(e.module_import_path);
            allocator.free(e.module_sanitized);
            allocator.free(e.name);
        }
        coercions.deinit(allocator);
    }

    // ── Plugin pass ─────────────────────────────────────────────
    for (cfg.plugins) |plugin| {
        const plugin_dir = cache.resolvePlugin(allocator, plugin, project_dir) catch continue;
        defer allocator.free(plugin_dir);

        const root_path = try std.fs.path.join(allocator, &.{ plugin_dir, "src", "root.zig" });
        defer allocator.free(root_path);

        const io = config.globalIo();
        // Plugins without a `src/root.zig` (or with an unreadable one) are
        // skipped per the back-compat policy. OOM is propagated rather
        // than masked as "this plugin contributes nothing" — same
        // rationale as `discoverEventsFromRoot`.
        const src = std.Io.Dir.cwd().readFileAlloc(io, root_path, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer allocator.free(src);

        var name_buf: [128]u8 = undefined;
        const sanitized = sanitizePluginIdent(plugin.name, &name_buf);

        scanFlowDeclsInSource(
            allocator,
            src,
            plugin.name,
            sanitized,
            false, // is_script
            &flow_nodes,
            &pin_styles,
            &coercions,
        ) catch continue; // tolerate per-plugin parse failures
    }

    // ── Game-script pass (RFC §5) ───────────────────────────────
    // Only walks game-owned entries — plugin-shipped scripts are
    // already covered by their plugin's root.zig pass above. See
    // the function's doc-comment for the rationale.
    var ident_buf: [256]u8 = undefined;
    for (script_entries) |entry| {
        if (entry.plugin_name != null) continue;

        const script_path = try std.fs.path.join(allocator, &.{ scripts_root, entry.rel_path });
        defer allocator.free(script_path);

        const io = config.globalIo();
        // Unreadable / missing script source is treated as "contributes
        // nothing" — the generated `main.zig` will surface a clearer
        // error when it tries to compile the script. OOM stays a hard
        // failure rather than silently swallowing memory pressure.
        const src = std.Io.Dir.cwd().readFileAlloc(io, script_path, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer allocator.free(src);

        const sanitized = pathToIdent(entry.rel_path, &ident_buf);

        scanFlowDeclsInSource(
            allocator,
            src,
            entry.rel_path,
            sanitized,
            true, // is_script
            &flow_nodes,
            &pin_styles,
            &coercions,
        ) catch continue;
    }

    // Each `toOwnedSlice` resets its source ArrayList to empty, so the
    // top-level errdefer chains above stop covering already-detached
    // slices the moment a *later* `toOwnedSlice` fails. Stage each
    // owned slice into a local first and guard it with a slice-shaped
    // errdefer so a mid-sequence OOM still frees everything cleanly
    // before the struct-return packages them up.
    const flow_nodes_slice = try flow_nodes.toOwnedSlice(allocator);
    errdefer {
        for (flow_nodes_slice) |e| {
            allocator.free(e.module_import_path);
            allocator.free(e.module_sanitized);
            allocator.free(e.node_name);
            if (e.constructs) |c| allocator.free(c);
        }
        allocator.free(flow_nodes_slice);
    }

    const pin_styles_slice = try pin_styles.toOwnedSlice(allocator);
    errdefer {
        for (pin_styles_slice) |e| {
            allocator.free(e.module_import_path);
            allocator.free(e.module_sanitized);
            allocator.free(e.type_name);
        }
        allocator.free(pin_styles_slice);
    }

    const coercions_slice = try coercions.toOwnedSlice(allocator);

    return .{
        .flow_nodes = flow_nodes_slice,
        .pin_styles = pin_styles_slice,
        .coercions = coercions_slice,
        .allocator = allocator,
    };
}

/// Deduplicate `PluginPinStyle` entries by `type_name`, keeping the
/// last occurrence (RFC §1: "later declarations win for any
/// duplicate type key"). Allocates a new slice owned by the caller;
/// strings inside are still borrowed from the input entries' lifetime
/// (the caller's `PluginFlowDecls`). Iteration over the input is
/// reverse: the first time we see a type name, we keep it (which
/// corresponds to the last-write in the input order); a second sight
/// is dropped.
///
/// Quadratic over the entry count — fine for the small registry
/// sizes (≤ a few dozen per typical project); a HashMap would be
/// overkill and would force a string allocation for every key.
pub fn dedupePinStyles(
    allocator: std.mem.Allocator,
    pin_styles: []const PluginPinStyle,
) ![]PluginPinStyle {
    var kept: std.ArrayList(PluginPinStyle) = .empty;
    errdefer kept.deinit(allocator);
    // Walk in reverse so the first time we see a name corresponds to
    // the last declaration in input order; later passes that already
    // recorded the name skip the entry.
    var i: usize = pin_styles.len;
    while (i > 0) {
        i -= 1;
        const ps = pin_styles[i];
        var already = false;
        for (kept.items) |k| {
            if (std.mem.eql(u8, k.type_name, ps.type_name)) {
                already = true;
                break;
            }
        }
        if (!already) try kept.append(allocator, ps);
    }
    // Reverse `kept` to restore source order (filtered).
    const out = try kept.toOwnedSlice(allocator);
    std.mem.reverse(PluginPinStyle, out);
    return out;
}

/// One game-script module that exports `pub const FlowNodes` and is
/// therefore promoted to a NAMED build-system module
/// (labelle-assembler#240, Gap 2). A game script reached by both the
/// **root** module (path-imported by `AllScripts` in main.zig for hook
/// registration) and the **game** module (the shim's `PluginFlowNodes`)
/// would be a member of two modules — which Zig forbids. Promotion to a
/// named module sidesteps the conflict: the file is the root of its own
/// module, and both the exe/root module and the `game` module add it as
/// an `@import("<named>")` import.
///
/// `module_name` is the build-system module name (also the string every
/// `@import("<named>")` consumer uses). `rel_path` is the script's path
/// under `scripts/` (so build.zig can `b.path("scripts/<rel>")` the
/// root source file).
pub const PromotedScript = struct {
    /// Named build-system module name, e.g. `script__bouncing_u_ball`.
    /// Built by `promotedScriptModuleName` from `module_sanitized` so it
    /// matches the `<module_sanitized>__<node>` decl prefix used in the
    /// `PluginFlowNodes` block. Caller owns the bytes.
    module_name: []const u8,
    /// Script path under `scripts/`, e.g. `bouncing_ball.zig`. Caller
    /// owns the bytes.
    rel_path: []const u8,
};

/// Build the named-module name for a FlowNodes-bearing game script from
/// its `module_sanitized` form (the `pathToIdent` of its rel_path). The
/// `script__` prefix namespaces it away from plugin module names (which
/// are the project.labelle `.name` verbatim) so a game script and a
/// plugin can never collide on the module-name string. Reusing
/// `module_sanitized` keeps the name byte-identical to the
/// `<module_sanitized>__<node>` decl prefix in `PluginFlowNodes`, which
/// is the invariant the three emission sites (build.zig wiring,
/// main.zig `PluginFlowNodes` + `AllScripts`, and the shim) all depend
/// on. Caller owns the returned bytes.
pub fn promotedScriptModuleName(
    allocator: std.mem.Allocator,
    module_sanitized: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "script__{s}", .{module_sanitized});
}

/// Collect the deduplicated set of game scripts that must be promoted to
/// named modules — every `is_script` FlowNode's source module, keyed by
/// `module_sanitized` so a script declaring N FlowNodes yields ONE
/// promoted module. Plugin-contributed nodes (`is_script == false`) are
/// skipped: plugins are already named modules (Gap 2 doesn't apply).
///
/// Caller owns the returned slice and each `PromotedScript`'s
/// `module_name` / `rel_path` bytes — free via `freePromotedScripts`.
pub fn collectPromotedScripts(
    allocator: std.mem.Allocator,
    flow_nodes: []const PluginFlowNode,
) ![]PromotedScript {
    var out: std.ArrayList(PromotedScript) = .empty;
    errdefer {
        for (out.items) |p| {
            allocator.free(p.module_name);
            allocator.free(p.rel_path);
        }
        out.deinit(allocator);
    }
    for (flow_nodes) |fn_| {
        if (!fn_.is_script) continue;
        // Dedupe by sanitized module — one named module per script file.
        var seen = false;
        for (out.items) |p| {
            if (std.mem.eql(u8, p.module_name[("script__".len)..], fn_.module_sanitized)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        const module_name = try promotedScriptModuleName(allocator, fn_.module_sanitized);
        errdefer allocator.free(module_name);
        const rel_path = try allocator.dupe(u8, fn_.module_import_path);
        try out.append(allocator, .{ .module_name = module_name, .rel_path = rel_path });
    }
    return out.toOwnedSlice(allocator);
}

/// Free a slice returned by `collectPromotedScripts`.
pub fn freePromotedScripts(allocator: std.mem.Allocator, scripts: []const PromotedScript) void {
    for (scripts) |p| {
        allocator.free(p.module_name);
        allocator.free(p.rel_path);
    }
    allocator.free(scripts);
}

/// Sanitize a plugin name (e.g. `labelle-box2d`) into a Zig identifier
/// fragment safe for embedding in a union variant tag. Non-identifier
/// bytes (`-`, `.`, `/`, …) collapse to `_`. The output is written
/// into the caller's buffer and returned as a sub-slice. The mapping
/// is collapsing rather than escaping, so two plugin names that
/// sanitize to the same identifier (e.g. `foo-bar` and `foo_bar`)
/// would collide — but the resulting duplicate variant name is
/// rejected by `MergeHookPayloads`' duplicate-field check at
/// comptime, surfacing the conflict immediately rather than silently.
pub fn sanitizePluginIdent(name: []const u8, buf: *[128]u8) []const u8 {
    var i: usize = 0;
    // A leading digit is invalid in a Zig identifier — prefix `_`.
    if (name.len > 0 and std.ascii.isDigit(name[0])) {
        buf[i] = '_';
        i += 1;
    }
    for (name) |c| {
        if (i >= buf.len) break;
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '_' => buf[i] = c,
            else => buf[i] = '_',
        }
        i += 1;
    }
    return buf[0..i];
}

/// Convert a path-style name to a valid Zig identifier: "enemies/goblin" -> "enemies_s_goblin".
/// Strips the `.zig` extension first, then escapes every character that is not
/// a valid identifier character into a distinct `_<tag>_` sequence.
///
/// The mapping is **injective**: distinct input paths always produce distinct
/// identifiers. Naively replacing `/`, `+`, and `.` all with `_` would collapse
/// e.g. `enemy/patrol` and `enemy_patrol` (or `a/b/c` and `a/b_c`) onto the same
/// identifier, emitting duplicate `pub const` lines in the generated `main.zig`.
/// To stay injective we must also escape literal `_` in the input — otherwise a
/// path containing `_` could alias an escaped separator.
///
/// Escape table (each maps to a sequence Zig accepts in an identifier):
///   `_` (literal) -> `_u_`   (`u`nderscore)
///   `/`           -> `_s_`   (`s`lash)
///   `.`           -> `_d_`   (`d`ot)
///   `+`           -> `_p_`   (`p`lus)
/// Any other non-`[A-Za-z0-9]` byte -> `_x<2-hex>_`.
///
/// Because every `_` in the output is the start of one of these escapes, no two
/// distinct inputs can decode to the same identifier. The `.` escape covers
/// plugin-shipped scripts that land under `.plugin_<name>/…`, whose leading dot
/// would otherwise produce an identifier that Zig rejects.
pub fn pathToIdent(name: []const u8, buf: *[256]u8) []const u8 {
    // Strip .zig extension
    const end = if (std.mem.endsWith(u8, name, ".zig")) name.len - 4 else name.len;
    var i: usize = 0;
    const append = struct {
        fn f(b: *[256]u8, idx: *usize, bytes: []const u8) void {
            if (idx.* + bytes.len > b.len) {
                stderrPrint("labelle: path too long for identifier (max {d} chars): too many escaped chars\n", .{b.len});
                @panic("path exceeds identifier buffer size");
            }
            @memcpy(b[idx.*..][0..bytes.len], bytes);
            idx.* += bytes.len;
        }
    }.f;
    // A leading digit makes the result invalid as a Zig identifier
    // (`pub const 2x2_tile = ...` won't compile). Prefix a `_`. It
    // can't alias an escape sequence — every escape is `_` followed
    // by a letter (`u`/`s`/`d`/`p`/`x`), never a digit — so the
    // mapping stays injective.
    if (end > 0 and name[0] >= '0' and name[0] <= '9') append(buf, &i, "_");
    for (name[0..end]) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9' => append(buf, &i, &.{c}),
            '_' => append(buf, &i, "_u_"),
            '/' => append(buf, &i, "_s_"),
            '.' => append(buf, &i, "_d_"),
            '+' => append(buf, &i, "_p_"),
            else => {
                const hex = "0123456789abcdef";
                append(buf, &i, &.{ '_', 'x', hex[c >> 4], hex[c & 0x0f], '_' });
            },
        }
    }
    return buf[0..i];
}

// ── Tests (moved verbatim from main_zig.zig) ─────────────────────────

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

test "rewritePackHookHandlerNames: bare pack-event handler is renamed to the prefixed tag (chatgpt-codex #3)" {
    const allocator = std.testing.allocator;
    // A pack hook: a handler for the pack's OWN event (`worker_died`, bare),
    // plus a handler for a built-in engine event (`tick`, must stay bare so it
    // keeps matching the un-prefixed engine variant), plus a private helper
    // that happens to share the event name (must NOT be renamed).
    const src =
        \\const std = @import("std");
        \\pub const Overlay = struct {
        \\    pub fn worker_died(self: *Overlay, data: anytype) void {
        \\        _ = self;
        \\        _ = data;
        \\    }
        \\    pub fn tick(self: *Overlay, data: anytype) void {
        \\        _ = self;
        \\        _ = data;
        \\    }
        \\    fn helper(self: *Overlay) void {
        \\        _ = self;
        \\    }
        \\};
    ;
    const out = try rewritePackHookHandlerNames(allocator, src, &.{"worker_died"}, "citizens", "overlay");
    defer allocator.free(out);

    // The pack-event handler DECL is renamed to the prefixed tag …
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn citizens__worker_died(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn worker_died(") == null);
    // … the engine-event handler keeps its bare name …
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn tick(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "citizens__tick") == null);
    // … the private helper (not a pack event) is untouched.
    try std.testing.expect(std.mem.indexOf(u8, out, "fn helper(") != null);
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

test "rewritePackHookHandlerNames: subdir pack event matches a bare handler (codex L435)" {
    const allocator = std.testing.allocator;
    // Pack event scanned as `combat/worker_died`; the emitted tag is
    // `citizens__worker_died`, so a `pub fn worker_died` must be renamed.
    const src =
        \\pub const Overlay = struct {
        \\    pub fn worker_died(self: *Overlay, data: anytype) void {
        \\        _ = self;
        \\        _ = data;
        \\    }
        \\};
    ;
    const out = try rewritePackHookHandlerNames(allocator, src, &.{"combat/worker_died"}, "citizens", "overlay");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn citizens__worker_died(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn worker_died(") == null);
}

test "rewritePackHookHandlerNames: a top-level helper fn is NOT renamed (CR L435)" {
    const allocator = std.testing.allocator;
    // A top-level `pub fn worker_died(_, _)` helper (2 params, name matches the
    // event) sits OUTSIDE the receiver container — it must be left alone. Only
    // the same-named method INSIDE the `Overlay` receiver is renamed.
    const src =
        \\pub fn worker_died(a: u32, b: u32) u32 {
        \\    return a + b;
        \\}
        \\pub const Overlay = struct {
        \\    pub fn worker_died(self: *Overlay, data: anytype) void {
        \\        _ = self;
        \\        _ = worker_died(1, 2);
        \\        _ = data;
        \\    }
        \\};
    ;
    const out = try rewritePackHookHandlerNames(allocator, src, &.{"worker_died"}, "citizens", "overlay");
    defer allocator.free(out);
    // The top-level helper decl keeps its bare name …
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn worker_died(a: u32, b: u32) u32") != null);
    // … the receiver method is renamed …
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn citizens__worker_died(self: *Overlay") != null);
    // … and the internal call to the helper still resolves (unchanged).
    try std.testing.expect(std.mem.indexOf(u8, out, "_ = worker_died(1, 2);") != null);
}

test "rewritePackHookHandlerNames: no pack events is a content-preserving dupe" {
    const allocator = std.testing.allocator;
    const src = "pub const H = struct { pub fn tick(self: *H, d: anytype) void { _ = self; _ = d; } };";
    const out = try rewritePackHookHandlerNames(allocator, src, &.{}, "citizens", "h");
    defer allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "pathToIdent: plain name is unchanged" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("health", pathToIdent("health", &buf));
}

test "pathToIdent: strips the .zig extension" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("patrol", pathToIdent("patrol.zig", &buf));
}

test "pathToIdent: distinct separators do not collide (issue #172)" {
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    // The classic collision: a slash-separated path vs the same text with a
    // literal underscore. Pre-fix both became `enemy_patrol`.
    const slash = pathToIdent("enemy/patrol", &a);
    const under = pathToIdent("enemy_patrol", &b);
    try std.testing.expect(!std.mem.eql(u8, slash, under));
    try std.testing.expectEqualStrings("enemy_s_patrol", slash);
    try std.testing.expectEqualStrings("enemy_u_patrol", under);
}

test "pathToIdent: nested path vs underscore variant do not collide" {
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    // `a/b/c` vs `a/b_c` — pre-fix both became `a_b_c`.
    try std.testing.expect(!std.mem.eql(
        u8,
        pathToIdent("a/b/c", &a),
        pathToIdent("a/b_c", &b),
    ));
}

test "pathToIdent: dot and plus map to distinct escapes" {
    var d: [256]u8 = undefined;
    var p: [256]u8 = undefined;
    var s: [256]u8 = undefined;
    try std.testing.expectEqualStrings("a_d_b", pathToIdent("a.b", &d));
    try std.testing.expectEqualStrings("a_p_b", pathToIdent("a+b", &p));
    try std.testing.expectEqualStrings("a_s_b", pathToIdent("a/b", &s));
    // ...and none of them collide with each other.
    try std.testing.expect(!std.mem.eql(u8, pathToIdent("a.b", &d), pathToIdent("a+b", &p)));
}

test "pathToIdent: a leading digit is prefixed to stay a valid identifier" {
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    // `2x2_tile` would otherwise emit `2x2_u_tile`, which Zig rejects
    // as an identifier. The `_` prefix keeps it valid.
    try std.testing.expectEqualStrings("_2x2_u_tile", pathToIdent("2x2_tile", &a));
    // The prefix must not collapse two distinct digit-leading paths.
    try std.testing.expect(!std.mem.eql(
        u8,
        pathToIdent("0a", &a),
        pathToIdent("1a", &b),
    ));
}

test "pathToIdent: every distinct path yields a distinct identifier" {
    const cases = [_][]const u8{
        "enemy/patrol",
        "enemy_patrol",
        "enemy.patrol",
        "enemy+patrol",
        "a/b/c",
        "a/b_c",
        "a_b/c",
        "a/b.c",
        ".plugin_core/script",
        "plugin_core/script",
    };
    var bufs: [cases.len][256]u8 = undefined;
    var id_list: [cases.len][]const u8 = undefined;
    for (cases, 0..) |c, i| id_list[i] = pathToIdent(c, &bufs[i]);
    for (id_list, 0..) |x, i| {
        for (id_list[i + 1 ..]) |y| {
            try std.testing.expect(!std.mem.eql(u8, x, y));
        }
    }
}

test "pathToIdent: leading dot from plugin scripts stays a valid identifier" {
    var buf: [256]u8 = undefined;
    const ident = pathToIdent(".plugin_core/patrol", &buf);
    // Must not begin with `.` and the first byte must be a valid identifier start.
    try std.testing.expect(ident[0] == '_');
    try std.testing.expectEqualStrings("_d_plugin_u_core_s_patrol", ident);
}
