//! Pass 1 of `rewritePackLocalRefs`: the flat→wrapped normalization
//! (`wrapFlatEntityComponents` + the `FlatWrap` walker). Behavior-preserving
//! split of `scan/pack_refs.zig`. Imports the shared scanners/probes from
//! `common.zig`; never imports pass 2, so the split stays acyclic.

const std = @import("std");
const common = @import("common.zig");

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
pub fn wrapFlatEntityComponents(
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

    const Error = common.Error;

    /// Nesting cap for both the recursion and the balanced-span scanner.
    /// Anything legitimately deeper than this is not a scene/prefab file;
    /// bail to the untouched-input path instead of trusting the process
    /// stack to an adversarial input.
    const max_depth: usize = common.max_depth;

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
            '{' => if (common.rootWrapperValueOpen(s)) |root_open|
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
            if (common.containsKey(self.component_keys, p.key)) has_local_flat = true;
        }
        const wrap = has_local_flat and !has_wrapper;

        try out.append(allocator, '{');
        var emitted_any = false;
        var wrapper_done = false;
        for (obj.pairs) |p| {
            if (wrap and common.isPascalCase(p.key)) {
                // Every Pascal pair moves into the single wrapper, emitted
                // at the FIRST Pascal pair's position (with its leading
                // trivia); later Pascal pairs were already emitted inside.
                if (wrapper_done) continue;
                if (emitted_any) try out.append(allocator, ',');
                try out.appendSlice(allocator, s[p.lead_start..p.key_start]);
                try out.appendSlice(allocator, if (is_reference) "\"overrides\": {" else "\"components\": {");
                var first = true;
                for (obj.pairs) |q| {
                    if (!common.isPascalCase(q.key)) continue;
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
            if (s[p.value_start] == '[' and common.isEntityListKey(p.key)) {
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
    /// (engine `isFileHeader`, see `common.isOnlyMetaHeaderObject`) is file
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
            if (s[i] == '{' and !(at_header_slot and common.isOnlyMetaHeaderObject(s, i))) {
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
    /// member, per `common.rootWrapperValueOpen` / the engine's first-match
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
            } else if (s[p.value_start] == '[' and common.isEntityListKey(p.key)) {
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

    // ── Scanner delegation ───────────────────────────────────────────
    // Thin wrappers over the shared `common.zig` scanners so the emit /
    // parse bodies above stay byte-for-byte unchanged from the pre-split
    // source. `common` owns the single implementation; pass 2's probes
    // call it directly.

    fn skipTrivia(self: *const FlatWrap, from: usize) usize {
        return common.skipTrivia(self.src, from);
    }

    fn scanString(self: *const FlatWrap, at: usize) Error!usize {
        return common.scanString(self.src, at);
    }

    fn scanValue(self: *const FlatWrap, at: usize) Error!usize {
        return common.scanValue(self.src, at);
    }
};
