//! Pack-namespace JSONC rewriting extracted from `codegen/scan.zig`
//! (behavior-preserving split, labelle-assembler#534 follow-up).
//!
//! Owns the `PackScan` result type and orchestrates the two streaming JSONC
//! walkers that rewrite a pack's OWN component keys / prefab references into
//! the invisible `<pack>__` namespace (Packs RFC §4, #440/#513/#516). The
//! two passes live in sibling submodules that share their scanning
//! primitives via `pack_refs/common.zig` and never import each other:
//!
//!   - `pack_refs/pass1.zig` — `wrapFlatEntityComponents` (flat→wrapped
//!     normalization), then
//!   - `pack_refs/pass2.zig` — `rewriteWrappedShapeRefs` (the scope-tracked
//!     rewrite).
//!
//! `rewritePackLocalRefs` here is the thin orchestrator (pass 1 then pass 2);
//! the public surface below is re-exported from the `scan.zig` barrel.

const std = @import("std");
const sanitize = @import("sanitize.zig");
const sanitizePluginIdent = sanitize.sanitizePluginIdent;
const common = @import("pack_refs/common.zig");
const pass1 = @import("pack_refs/pass1.zig");
const pass2 = @import("pack_refs/pass2.zig");

/// Offset (key content start, for line/col reporting) of a legacy
/// `"entities"` key inside an RFC #596 bundle's file-header element, or
/// null (see `common.bundleHeaderLegacyEntitiesOffset`). Re-exported so
/// `generate` can surface the dead list as a warning. Part of the public
/// surface the `scan.zig` barrel re-exports.
pub const bundleHeaderLegacyEntitiesOffset = common.bundleHeaderLegacyEntitiesOffset;

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
    /// True when the pack ships a root-level `queries.zig` / `commands.zig`
    /// (RFC §6 verb surfaces, #498 PR 4). Copied beside the convention dirs;
    /// `__pack_root.zig` re-exports them and `__surface.zig` narrows them to
    /// the manifest's `exposes` lists.
    has_queries: bool = false,
    has_commands: bool = false,

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
/// Instead, a normalization pre-pass (`pass1.wrapFlatEntityComponents`)
/// converts any flat entity that declares pack-local components into the
/// WRAPPED shape — collecting ALL its PascalCase keys into a synthesized
/// `"components"` map (`"overrides"` for prefab references) — and the walk
/// below then namespaces the pack-local keys through the same
/// component-map scope rule it always used. See that function for the full
/// shape rules (mixed wrapper+flat entities, payload decoys, malformed-
/// input fallback).
///
/// **Accepted file shapes (#516).** Both passes recognize the three
/// top-level FILE shapes the engine dual-accepts, classified exactly like
/// the engine's `unified_format.zig` (`classifyTopLevel` / `isFileHeader` /
/// `rootObject` — the probes in `pack_refs/common.zig` are their
/// byte-scanning twins):
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
///      entities / payload (see `common.isOnlyMetaHeaderObject`).
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
    const normalized = try pass1.wrapFlatEntityComponents(allocator, src, component_keys);
    defer allocator.free(normalized);
    return pass2.rewriteWrappedShapeRefs(allocator, normalized, component_keys, prefab_names, prefix);
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
