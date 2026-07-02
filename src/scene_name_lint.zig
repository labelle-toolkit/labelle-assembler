//! `labelle check` — bare pack-component name lint for game-root scenes
//! (labelle-assembler#490).
//!
//! A game-root scene/prefab must reference a pack component by its
//! **namespaced** registry key (`citizens__Worker`), NOT the bare local
//! name (`Worker`). A bare name silently **no-ops** as an unknown
//! component (RFC #596 accepts any PascalCase key at authoring time and
//! the engine warn-once-drops an unknown one at load): the entity loads
//! with the component missing and no error — a nasty debugging trap (it
//! cost real time in the pack-colony demo, where workers/workstations
//! silently didn't exist until the keys were namespaced).
//!
//! This lint is the counterpart to the pack-local component-key rewrite
//! (`scan.rewritePackLocalRefs`), which namespaces a *pack's own*
//! scene/prefab references at copy time. The game root's scenes are never
//! rewritten, so a game author who writes the bare pack-component name
//! gets no signal today. Rather than auto-rewrite the game root (riskier —
//! it mutates authored source and can't disambiguate when two packs export
//! the same un-prefixed name; tracked as a follow-up), we LINT: when a
//! game-root scene references a bare PascalCase name that is NOT a known
//! game-owned component but WOULD match a known pack component's
//! un-prefixed name, we emit an actionable "did you mean 'citizens__Worker'?"
//! finding.
//!
//! Precision over recall (mirrors `check.zig`): the lint fires ONLY when a
//! bare reference collides with a real pack component's un-prefixed name.
//! A name the game root itself owns (its own `components/*.zig`, or an
//! engine builtin like `Position`) is left alone, and a genuinely-unknown
//! name with no pack match keeps today's silent behavior — the engine's
//! own warn-once path is the backstop there.
//!
//! Everything here is `std`-only and pure over its inputs so the rule logic
//! is unit-testable with in-memory sources; `check_cmd.zig` builds the pack
//! component set + game-owned name set from the discovered packs and game
//! root, and drives the directory walk.
//!
//! The same reference walk also backs the #516 generate-time net over a
//! pack's COPIED prefabs (`findBareLocalRefs`, driven from root.zig after
//! the pack-local rewrite) — see that function for the survivor semantics.

const std = @import("std");
const check = @import("check.zig");

// ── Inputs ────────────────────────────────────────────────────────────────

/// A pack-contributed component: its bare un-prefixed Pascal name as an
/// author writes it (`Worker`) and the namespaced registry key the engine
/// actually registers it under (`citizens__Worker`, #440). Built by
/// `check_cmd` from the discovered packs.
pub const PackComponent = struct {
    /// The un-prefixed Pascal name, e.g. `Worker`.
    bare: []const u8,
    /// The emitted `<prefix>__<Pascal>` registry key, e.g. `citizens__Worker`.
    namespaced: []const u8,
};

/// Engine/gfx built-in component names that the assembler's codegen ALWAYS
/// registers into every project's component registry
/// (`writeComponentRegistryBlock` in `codegen/blocks/registries.zig`),
/// independent of the game's own `components/` and of any pack. A game
/// scene/prefab may reference one of these by its bare name legitimately, so
/// they are exempt from this lint even when a pack happens to ship a
/// same-named component (labelle-assembler#494, codex review). Keep in sync
/// with the hard-coded `engine.core.*` registrations in
/// `writeComponentRegistryBlock`.
pub const builtin_component_names = [_][]const u8{
    // #549 — `{ "VideoComponent": { "path": "intro", … } }` in any scene/prefab.
    "VideoComponent",
};

// ── Component-reference collection ─────────────────────────────────────────

/// One component-declaration reference found in a scene/prefab source: the
/// bare name (borrowed from `src`) and the byte offset of its first char
/// (for line/col reporting).
pub const CompRef = struct {
    name: []const u8,
    offset: usize,
};

/// Object/array scope kinds tracked while walking a scene/prefab JSONC.
/// Mirrors `scan.Scope` (the pack-rewrite walker) — the distinction that
/// matters is ENTITY (where a flat-form PascalCase key is a component, and
/// `components`/`overrides` open a component map) vs PAYLOAD (opaque
/// component data whose keys are NOT component references).
const Scope = enum {
    /// An entity / prefab-patch object. A `components`/`overrides` key opens
    /// a component map; a flat-form PascalCase key (RFC #596 axis 2) is a
    /// component reference directly here.
    entity,
    /// The value of a `components`/`overrides` key — its direct keys are
    /// component names.
    component_map,
    /// A component's value, or anything nested below it: opaque payload.
    payload,
    /// An array whose elements are entities (`children`/`entities`, plus a
    /// top-level bundle array per RFC #596 axis 3).
    array_entities,
    /// Any other array — payload/unknown lists. Elements are opaque.
    array_other,
};

/// Scope of the object introduced by a `{`, given its parent's scope and
/// the key it is the value of. The document root (parent == null) is an
/// entity (scene root / flat-form entity object). Mirrors `scan.childScope`.
fn childScope(parent: ?Scope, pending_key: ?[]const u8) Scope {
    const p = parent orelse return .entity;
    return switch (p) {
        .array_entities => .entity,
        .entity => blk: {
            if (pending_key) |k| {
                if (std.mem.eql(u8, k, "components") or std.mem.eql(u8, k, "overrides")) {
                    break :blk .component_map;
                }
                if (std.mem.eql(u8, k, "root")) break :blk .entity;
            }
            break :blk .payload;
        },
        .component_map, .payload, .array_other => .payload,
    };
}

/// Scope of the array introduced by a `[`. A top-level bundle array (RFC
/// #596 axis 3) and a `children`/`entities` list on an entity carry entity
/// elements; every other array is opaque. Mirrors `scan.childArrayScope`
/// but additionally treats the document-root array as a bundle of entities.
fn childArrayScope(parent: ?Scope, pending_key: ?[]const u8) Scope {
    const p = parent orelse return .array_entities; // top-level bundle
    if (p == .entity) {
        if (pending_key) |k| {
            if (std.mem.eql(u8, k, "children") or std.mem.eql(u8, k, "entities")) {
                return .array_entities;
            }
        }
    }
    return .array_other;
}

/// True iff a key's first byte is an ASCII upper-case letter — the
/// PascalCase convention RFC #596 axis 2 uses to mark component keys.
fn isPascalCase(key: []const u8) bool {
    return key.len > 0 and key[0] >= 'A' and key[0] <= 'Z';
}

/// True iff the next significant byte at/after `from` (skipping whitespace
/// and JSONC comments) is a `:` — i.e. the preceding string literal was an
/// object key rather than a value. Pure lookahead. Mirrors
/// `scan.nextSignificantIsColon`.
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
            i = if (close) |q| q + 2 else src.len;
            continue;
        }
        return c == ':';
    }
    return false;
}

/// Collect every component-declaration reference from a scene/prefab JSONC
/// `src`: a key sitting in a `component_map` scope (`components`/`overrides`
/// map), or a flat-form PascalCase key sitting directly on an entity (RFC
/// #596 axis 2). Byte-offset-preserving so findings carry accurate
/// line/col. Never fails on malformed input — an unterminated string is
/// consumed to end-of-file and simply yields no further refs.
///
/// This is the read-only twin of `scan.rewritePackLocalRefs`'s walk; it
/// re-implements the scope tracking rather than sharing it because that
/// walker is coupled to in-place rewriting, and the two want different
/// outputs (a rewrite buffer vs. an offset list). It additionally collects
/// flat-form entity-scope PascalCase keys, which the pack rewrite (a #440
/// concern scoped to component maps) does not.
pub fn collectComponentRefs(arena: std.mem.Allocator, src: []const u8) ![]CompRef {
    var refs: std.ArrayList(CompRef) = .empty;

    var scope_stack: std.ArrayList(Scope) = .empty;
    defer scope_stack.deinit(arena);

    var pending_key: ?[]const u8 = null;

    const topScope = struct {
        fn f(stack: []const Scope) ?Scope {
            return if (stack.len > 0) stack[stack.len - 1] else null;
        }
    }.f;

    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];

        // JSONC comments — skip verbatim.
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            i = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            const close = std.mem.indexOfPos(u8, src, i + 2, "*/");
            i = if (close) |p| p + 2 else src.len;
            continue;
        }
        if (c == '{') {
            try scope_stack.append(arena, childScope(topScope(scope_stack.items), pending_key));
            pending_key = null;
            i += 1;
            continue;
        }
        if (c == '[') {
            try scope_stack.append(arena, childArrayScope(topScope(scope_stack.items), pending_key));
            pending_key = null;
            i += 1;
            continue;
        }
        if (c == '}' or c == ']') {
            if (scope_stack.items.len > 0) _ = scope_stack.pop();
            pending_key = null;
            i += 1;
            continue;
        }
        if (c == ',') {
            pending_key = null;
            i += 1;
            continue;
        }
        if (c == '"') {
            const content_start = i + 1;
            var j = content_start;
            while (j < src.len) : (j += 1) {
                if (src[j] == '\\' and j + 1 < src.len) {
                    j += 1;
                    continue;
                }
                if (src[j] == '"') break;
            }
            if (j >= src.len) break; // unterminated — stop
            const content = src[content_start..j];
            const is_key = nextSignificantIsColon(src, j + 1);

            if (is_key) {
                const scope = topScope(scope_stack.items) orelse .entity;
                const is_ref = switch (scope) {
                    // Every key in a component map is a component name.
                    .component_map => true,
                    // A flat-form PascalCase key on an entity is a component.
                    .entity => isPascalCase(content),
                    else => false,
                };
                if (is_ref) {
                    try refs.append(arena, .{ .name = content, .offset = content_start });
                }
                pending_key = content;
            } else {
                pending_key = null;
            }
            i = j + 1;
            continue;
        }

        i += 1;
    }

    return refs.toOwnedSlice(arena);
}

// ── Lint ────────────────────────────────────────────────────────────────

/// 1-based line/column of a byte offset in `src`. Public because the #516
/// generate-time net driver (root.zig) also positions its bundle-header
/// warning with it (#521).
pub fn locOf(src: []const u8, offset: usize) struct { line: usize, col: usize } {
    var line: usize = 1;
    var col: usize = 1;
    const end = @min(offset, src.len);
    for (src[0..end]) |c| {
        if (c == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .col = col };
}

fn containsStr(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| {
        if (std.mem.eql(u8, h, needle)) return true;
    }
    return false;
}

/// Lint one scene/prefab source buffer, appending a `check.Finding`
/// (`scene_bare_pack_component`) for every bare component reference that
/// silently no-ops but matches a pack component's un-prefixed name. `file`
/// is stored verbatim on each finding (borrowed). Pure; all allocation is
/// on `arena`.
///
/// A reference is flagged iff ALL of:
///   1. it is NOT already namespaced or otherwise game-owned — i.e. neither
///      the game root's own scanned `components/*.zig` names (`game_owned`)
///      NOR an engine/gfx built-in the codegen always registers
///      (`builtin_component_names`, e.g. `VideoComponent`) claims that bare
///      name. A built-in must be exempt even when a pack ships a same-named
///      component, or a legitimate `{ "VideoComponent": … }` is falsely
///      flagged + mis-suggested to `pack__VideoComponent`
///      (labelle-assembler#494, codex review); and
///   2. some pack DOES contribute a component whose un-prefixed name equals
///      the bare reference — that pack component is only reachable via its
///      `<pack>__<Name>` key, so the bare form is the trap.
/// Everything else (a correct namespaced reference, an engine builtin, a
/// genuinely-unknown name) is silent, preserving today's behavior.
pub fn lintSource(
    arena: std.mem.Allocator,
    findings: *std.ArrayList(check.Finding),
    src: []const u8,
    file: []const u8,
    pack_components: []const PackComponent,
    game_owned: []const []const u8,
) !void {
    const refs = try collectComponentRefs(arena, src);
    for (refs) |ref| {
        // A name the game root itself owns is a legitimate bare reference.
        if (containsStr(game_owned, ref.name)) continue;
        // An engine/gfx built-in the codegen always registers (e.g.
        // `VideoComponent`) is likewise legitimate by its bare name — even
        // when a pack ships a same-named component (labelle-assembler#494).
        if (containsStr(&builtin_component_names, ref.name)) continue;

        // Gather the namespaced candidates whose un-prefixed name matches.
        var candidates: std.ArrayList([]const u8) = .empty;
        for (pack_components) |pc| {
            if (std.mem.eql(u8, pc.bare, ref.name)) {
                if (!containsStr(candidates.items, pc.namespaced)) {
                    try candidates.append(arena, pc.namespaced);
                }
            }
        }
        if (candidates.items.len == 0) continue; // genuinely unknown — silent

        const loc = locOf(src, ref.offset);
        const suggestion = if (candidates.items.len == 1)
            try std.fmt.allocPrint(arena, "'{s}'", .{candidates.items[0]})
        else blk: {
            var aw: std.Io.Writer.Allocating = .init(arena);
            const w = &aw.writer;
            try w.writeAll("one of ");
            for (candidates.items, 0..) |cand, idx| {
                if (idx != 0) try w.writeAll(", ");
                try w.print("'{s}'", .{cand});
            }
            break :blk aw.written();
        };
        const msg = try std.fmt.allocPrint(
            arena,
            "scene references component '{s}' by its bare name, but '{s}' is a pack component registered only under its namespaced key; a bare pack-component name silently no-ops as an unknown component (RFC #596). Did you mean {s}?",
            .{ ref.name, ref.name, suggestion },
        );
        try findings.append(arena, .{
            .rule = .scene_bare_pack_component,
            .file = file,
            .line = loc.line,
            .col = loc.col,
            .message = msg,
        });
    }
}

// ── Directory walk ────────────────────────────────────────────────────────

/// Recursively lint every `.jsonc` file under `dir_path` (a game-root
/// `scenes/` or `prefabs/` tree), appending findings. Each finding's `file`
/// is `dir_path`-joined and arena-owned. A missing dir / unreadable file is
/// skipped silently — the build surfaces those; the lint is a net, not a
/// gate.
pub fn scanScenesDir(
    arena: std.mem.Allocator,
    io: std.Io,
    findings: *std.ArrayList(check.Finding),
    dir_path: []const u8,
    pack_components: []const PackComponent,
    game_owned: []const []const u8,
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const child = try std.fs.path.join(arena, &.{ dir_path, entry.name });
        switch (entry.kind) {
            .directory => try scanScenesDir(arena, io, findings, child, pack_components, game_owned),
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".jsonc")) continue;
                const src = std.Io.Dir.cwd().readFileAlloc(io, child, arena, .limited(8 * 1024 * 1024)) catch continue;
                try lintSource(arena, findings, src, child, pack_components, game_owned);
            },
            else => {},
        }
    }
}

// ── Post-rewrite net for pack copies (#516) ───────────────────────────────

/// A bare pack-LOCAL component reference that survived the pack-copy
/// rewrite: its name plus 1-based line/col in the rewritten source.
pub const BareLocalRef = struct {
    name: []const u8,
    line: usize,
    col: usize,
};

/// Generate-time net over a pack's COPIED prefabs (#516). After
/// `scan.rewritePackLocalRefs` runs, NO component-declaration reference in
/// the copy should still equal one of the pack's OWN bare component names
/// (`local_keys`, Pascal forms) — the rewrite namespaces every declaration
/// position it understands. A survivor means the component will NOT attach
/// at load: either the file's shape escaped the rewrite walkers (the #516
/// failure class), or it is the deliberately-untouched RFC #596 HYBRID
/// form (wrapper + flat keys mixed — an authoring error the engine
/// warn-drops), or the key is dead data the engine never reads (e.g. a
/// flat key beside a `"root"` wrapper). All of those deserve a loud
/// generate-time warning instead of a silent no-op.
///
/// Pure over its inputs (arena-owned result) so it is unit-testable with
/// in-memory sources; `rewritePackPrefabRefs` (root.zig) drives it over
/// each rewritten copy and logs. Reuses `collectComponentRefs` — the same
/// recall-oriented walk the game-root lint trusts, which already covers
/// the bundle and root-wrapper container shapes.
pub fn findBareLocalRefs(
    arena: std.mem.Allocator,
    src: []const u8,
    local_keys: []const []const u8,
) ![]BareLocalRef {
    const refs = try collectComponentRefs(arena, src);
    var out: std.ArrayList(BareLocalRef) = .empty;
    // No-op under the documented arena contract, but keeps the growth path
    // leak-free if a future caller passes a general-purpose allocator
    // (Gemini on #521).
    errdefer out.deinit(arena);
    for (refs) |ref| {
        if (!containsStr(local_keys, ref.name)) continue;
        const loc = locOf(src, ref.offset);
        try out.append(arena, .{ .name = ref.name, .line = loc.line, .col = loc.col });
    }
    return out.toOwnedSlice(arena);
}

// ════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════

const testing = std.testing;

fn lintOne(
    arena: std.mem.Allocator,
    src: []const u8,
    pack_components: []const PackComponent,
    game_owned: []const []const u8,
) ![]check.Finding {
    var findings: std.ArrayList(check.Finding) = .empty;
    try lintSource(arena, &findings, src, "scenes/main.jsonc", pack_components, game_owned);
    return findings.toOwnedSlice(arena);
}

test "collectComponentRefs: flat-form top-level PascalCase key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const refs = try collectComponentRefs(arena.allocator(),
        \\{ "name": "main", "Worker": { "hunger": 0 } }
    );
    try testing.expectEqual(@as(usize, 1), refs.len);
    try testing.expectEqualStrings("Worker", refs[0].name);
}

test "collectComponentRefs: keys inside a components map" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const refs = try collectComponentRefs(arena.allocator(),
        \\{ "components": { "Worker": {}, "Position": { "x": 1 } } }
    );
    try testing.expectEqual(@as(usize, 2), refs.len);
    try testing.expectEqualStrings("Worker", refs[0].name);
    try testing.expectEqualStrings("Position", refs[1].name);
}

test "collectComponentRefs: component payload keys are not refs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // The `Nested` key sits inside Worker's payload — opaque data, not a ref.
    const refs = try collectComponentRefs(arena.allocator(),
        \\{ "components": { "Worker": { "Nested": { "x": 1 } } } }
    );
    try testing.expectEqual(@as(usize, 1), refs.len);
    try testing.expectEqualStrings("Worker", refs[0].name);
}

test "collectComponentRefs: walks children entities" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const refs = try collectComponentRefs(arena.allocator(),
        \\{ "children": [ { "Worker": {} }, { "components": { "Enemy": {} } } ] }
    );
    try testing.expectEqual(@as(usize, 2), refs.len);
    try testing.expectEqualStrings("Worker", refs[0].name);
    try testing.expectEqualStrings("Enemy", refs[1].name);
}

test "collectComponentRefs: bundle array elements are entities" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const refs = try collectComponentRefs(arena.allocator(),
        \\[ { "meta": {} }, { "Worker": {} } ]
    );
    try testing.expectEqual(@as(usize, 1), refs.len);
    try testing.expectEqualStrings("Worker", refs[0].name);
}

test "lint: bare pack-component name is flagged with a namespaced suggestion" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try lintOne(
        arena.allocator(),
        \\{ "components": { "Worker": { "hunger": 0 } } }
    ,
        &.{.{ .bare = "Worker", .namespaced = "citizens__Worker" }},
        &.{},
    );
    try testing.expectEqual(@as(usize, 1), f.len);
    try testing.expectEqual(check.Rule.scene_bare_pack_component, f[0].rule);
    try testing.expect(std.mem.indexOf(u8, f[0].message, "citizens__Worker") != null);
}

test "lint: the correct namespaced key is silent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try lintOne(
        arena.allocator(),
        \\{ "components": { "citizens__Worker": { "hunger": 0 } } }
    ,
        &.{.{ .bare = "Worker", .namespaced = "citizens__Worker" }},
        &.{},
    );
    try testing.expectEqual(@as(usize, 0), f.len);
}

test "lint: a genuinely-unknown name (no pack match) keeps today's behavior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try lintOne(
        arena.allocator(),
        \\{ "components": { "Widget": {} } }
    ,
        &.{.{ .bare = "Worker", .namespaced = "citizens__Worker" }},
        &.{},
    );
    try testing.expectEqual(@as(usize, 0), f.len);
}

test "lint: a game-owned component of the same name is not flagged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // The game root defines its own `Worker` — a bare reference is legit.
    const f = try lintOne(
        arena.allocator(),
        \\{ "components": { "Worker": {} } }
    ,
        &.{.{ .bare = "Worker", .namespaced = "citizens__Worker" }},
        &.{"Worker"},
    );
    try testing.expectEqual(@as(usize, 0), f.len);
}

test "lint: a built-in component name is not flagged even if a pack ships one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // `VideoComponent` is an engine built-in the codegen always registers, so
    // a bare scene reference is legitimate — even though a pack here also
    // defines a `VideoComponent` (labelle-assembler#494, codex review). It
    // must NOT be flagged / mis-suggested to `media__VideoComponent`.
    const f = try lintOne(
        arena.allocator(),
        \\{ "components": { "VideoComponent": { "path": "intro" } } }
    ,
        &.{.{ .bare = "VideoComponent", .namespaced = "media__VideoComponent" }},
        &.{},
    );
    try testing.expectEqual(@as(usize, 0), f.len);
}

test "lint: flat-form top-level bare reference is flagged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try lintOne(
        arena.allocator(),
        \\{ "name": "main", "Worker": {} }
    ,
        &.{.{ .bare = "Worker", .namespaced = "citizens__Worker" }},
        &.{},
    );
    try testing.expectEqual(@as(usize, 1), f.len);
    try testing.expectEqual(check.Rule.scene_bare_pack_component, f[0].rule);
}

test "lint: ambiguous bare name lists every candidate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try lintOne(
        arena.allocator(),
        \\{ "components": { "Worker": {} } }
    ,
        &.{
            .{ .bare = "Worker", .namespaced = "citizens__Worker" },
            .{ .bare = "Worker", .namespaced = "labor__Worker" },
        },
        &.{},
    );
    try testing.expectEqual(@as(usize, 1), f.len);
    try testing.expect(std.mem.indexOf(u8, f[0].message, "citizens__Worker") != null);
    try testing.expect(std.mem.indexOf(u8, f[0].message, "labor__Worker") != null);
}

test "scanScenesDir: walks a temp scenes tree and reports a bare reference" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "scenes");
    try tmp.dir.writeFile(io, .{
        .sub_path = "scenes/main.jsonc",
        .data =
        \\{ "components": { "Worker": {} } }
        ,
    });
    // A clean sibling with the correct namespaced key must not trip.
    try tmp.dir.writeFile(io, .{
        .sub_path = "scenes/ok.jsonc",
        .data =
        \\{ "components": { "citizens__Worker": {} } }
        ,
    });

    const scenes_dir = try tmp.dir.realPathFileAlloc(io, "scenes", arena);
    var findings: std.ArrayList(check.Finding) = .empty;
    try scanScenesDir(
        arena,
        io,
        &findings,
        scenes_dir,
        &.{.{ .bare = "Worker", .namespaced = "citizens__Worker" }},
        &.{},
    );
    try testing.expectEqual(@as(usize, 1), findings.items.len);
    try testing.expectEqual(check.Rule.scene_bare_pack_component, findings.items[0].rule);
    try testing.expect(std.mem.endsWith(u8, findings.items[0].file, "main.jsonc"));
}

test "findBareLocalRefs: leftover bare pack key in a hybrid entity is reported with line/col (#516)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // The RFC #596 HYBRID form is left byte-verbatim by the pack rewrite
    // (scan.zig, codex P2 on #515), so its flat `CloudDrift` stays bare —
    // exactly the survivor the net must surface. The namespaced sibling
    // and the non-pack `Position` are silent.
    const refs = try findBareLocalRefs(arena.allocator(),
        \\{
        \\    "components": { "sky__SkyBody": {}, "Position": { "x": 1 } },
        \\    "CloudDrift": { "v": 1 }
        \\}
    , &.{ "SkyBody", "CloudDrift" });
    try testing.expectEqual(@as(usize, 1), refs.len);
    try testing.expectEqualStrings("CloudDrift", refs[0].name);
    try testing.expectEqual(@as(usize, 3), refs[0].line);
    try testing.expectEqual(@as(usize, 6), refs[0].col);
}

test "findBareLocalRefs: a correctly rewritten copy is silent, payload decoys included (#516)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // What a copy looks like after a correct rewrite: every declaration is
    // namespaced; the pack name surviving inside a payload (`Spawner`'s
    // value) is opaque data, not a declaration.
    const refs = try findBareLocalRefs(arena.allocator(),
        \\{ "components": { "sky__SkyBody": {}, "Spawner": { "SkyBody": 3 } } }
    , &.{"SkyBody"});
    try testing.expectEqual(@as(usize, 0), refs.len);
}

test "findBareLocalRefs: covers bundle and root-wrapper containers (#516)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // A survivor inside a bundle element…
    const bundle_refs = try findBareLocalRefs(arena.allocator(),
        \\[ { "meta": {} }, { "components": { "SkyBody": {} } } ]
    , &.{"SkyBody"});
    try testing.expectEqual(@as(usize, 1), bundle_refs.len);
    // …and inside a root-wrapper's entity are both reachable by the walk.
    const wrapper_refs = try findBareLocalRefs(arena.allocator(),
        \\{ "root": { "SkyBody": {} } }
    , &.{"SkyBody"});
    try testing.expectEqual(@as(usize, 1), wrapper_refs.len);
}
