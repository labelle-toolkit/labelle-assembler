//! `labelle check` — the Packs enforcement "net" (labelle-cli#270).
//!
//! A static/token scan over a game's **packs** that reports the §6
//! convention violations the compile wall can't (yet) catch. Part of the
//! Packs initiative (RFC Flying-Platform/flying-platform-labelle#561 §6
//! "Enforcement — isolation is structural, not documented"; umbrella
//! labelle-engine#651).
//!
//! Enforcement is a stack (RFC §6): module isolation (compile, #498
//! PR 2) → the `PackView` registry partition + `@import("pack").Registry`
//! bridge (compile, #498 PRs 1/3) → `exposes` surfaces + `depends_on`
//! narrowing (compile, #498 PR 4) → generate-time validation
//! (`pack_validate.zig`, the DAG/cycle gate) → **this lint (the fast
//! no-build net)** → pit-of-success scaffolding. With the wall shipped
//! (`docs/packs.md`), the compile layer now also catches rule 1's TYPED
//! half (`view(.{Foreign})` — the foreign type is unreachable from a
//! pack module) and rule 4's literal cross-pack imports (dual-module /
//! out-of-module errors). The lint keeps both as the fast pre-build
//! diagnostic. What stays lint-ONLY, permanently, by design: rule 1's
//! STRING half — `game.ComponentRegistry` through the `anytype` `game`
//! param still resolves every name — plus `.global`-facet *writes*
//! (rule 2) and event *direction* (rule 3), RFC §6's "honest limit even
//! then".
//!
//! ## Rules
//!
//! 1. **cross-pack registry access on foreign names**
//!    (`cross_pack_registry_access`). The string-keyed registry is the
//!    escape hole module isolation leaves open (RFC §6-1b): a pack can
//!    recover a foreign type *without importing it* via
//!    `getType("<other>__X")` / `entityHasNamed(e, "<other>__X")`. Also
//!    flags `view(.{ForeignComponent})` when the component is
//!    unambiguously owned by another pack.
//!
//! 2. **raw `.global`-facet writes** (`raw_global_facet_write`). `.global`
//!    facets (e.g. `Locked`) are the shared multi-writer seam module
//!    isolation can't wall off, so a raw `Locked{…}` construction that
//!    bypasses the sanctioned API (`Locked.tryAcquire`) reintroduces
//!    double-claim. Flags direct construction of a global facet in any
//!    pack that does not own it.
//!
//! 3. **event-direction inversions** (`event_direction_inversion`).
//!    Events point *up* the `depends_on` DAG (RFC §6): a lower pack must
//!    not react to an event owned by a pack that depends on it. Uses the
//!    same `depends_on` graph `pack_validate.zig` already parses (#441).
//!    Subscription is detected heuristically — a reference to the higher
//!    pack's qualified event identifier (`<higher>__<event>`) in the lower
//!    pack's source. Precise on the emitted-name convention (#440), but
//!    best-effort (it can't see a subscription routed through a value the
//!    scanner can't trace); the *compile-time* direction wall is future
//!    work.
//!
//! 4. **cross-pack file imports** (`cross_pack_import`). A pack `@import`s a
//!    source file that lives inside ANOTHER pack's directory without
//!    declaring that pack in `depends_on`. This is the direct-TYPE-import
//!    reach-around engine #656 identified as the real ACL escape: instead of
//!    recovering a foreign type through the registry (rule 1) it imports the
//!    foreign component/type file outright. Detected TEXTUALLY — a literal
//!    relative-path `@import("../../other/x.zig")` whose resolved path is under a
//!    foreign pack's on-disk directory. This closes the *blatant* literal
//!    case; it deliberately does NOT chase semantic routes (a re-export
//!    chain, a type reached through a value, or an import via a named
//!    module) — those need Zig call-graph/semantic analysis the assembler
//!    does not do (engine #656). An import of a DECLARED dependency's file is
//!    allowed (the packs share a copied tree with no module wall yet, RFC §6
//!    "isolation is future work"); only imports into a NON-dependency pack
//!    are flagged.
//!
//! The token scan is deliberately anchored on high-confidence syntactic
//! shapes (a qualified `<pack>__` name, a `Facet{` construction) rather
//! than broad heuristics — a lint with false positives is worthless, so
//! this errs toward silence.
//!
//! Everything here is `std`-only and pure over its `Context` so the rule
//! logic is unit-testable with in-memory sources; `check_cmd.zig` builds
//! the `Context` from the discovered packs and drives the directory walk.

const std = @import("std");
const scanner = @import("scanner.zig");

// ── Findings ────────────────────────────────────────────────────────────

/// Which §6 convention a finding reports.
pub const Rule = enum {
    cross_pack_registry_access,
    raw_global_facet_write,
    event_direction_inversion,
    /// A game-root scene/prefab references a pack component by its BARE
    /// name (`Worker`) instead of its namespaced registry key
    /// (`citizens__Worker`). A bare name silently no-ops as an unknown
    /// component (RFC #596) — the entity loads with the component missing
    /// and no error. Reported by `scene_name_lint.zig`; see labelle-assembler#490.
    scene_bare_pack_component,

    /// A pack's source `@import`s a file that lives INSIDE another pack's
    /// directory without declaring that pack in `depends_on`
    /// (`@import("../../other/components/foo.zig")`). This is the blatant
    /// "reach around the ACL by importing a foreign file" escape flagged by
    /// engine #656 — a TYPE recovered by direct file import, sidestepping
    /// both module isolation and the string-keyed registry (RFC §6). Caught
    /// TEXTUALLY (a literal relative-path `@import` that resolves under a
    /// foreign pack's dir); the compiler-level "only calls exposed fns" wall
    /// stays out of the assembler's reach (see the module header note).
    cross_pack_import,

    /// Stable, human/CI-readable rule slug printed in the report.
    pub fn slug(self: Rule) []const u8 {
        return switch (self) {
            .cross_pack_registry_access => "cross-pack-registry-access",
            .raw_global_facet_write => "raw-global-facet-write",
            .event_direction_inversion => "event-direction-inversion",
            .scene_bare_pack_component => "scene-bare-pack-component",
            .cross_pack_import => "cross-pack-import",
        };
    }
};

/// One reported violation. All strings are borrowed from — or allocated in
/// — the arena the caller passes to the scan; they live as long as it does.
pub const Finding = struct {
    rule: Rule,
    /// File the violation was found in (as the walker joined it).
    file: []const u8,
    /// 1-based line / column of the offending token.
    line: usize,
    col: usize,
    /// Human-readable explanation (already formatted).
    message: []const u8,
};

// ── Context (built by check_cmd from the discovered packs) ───────────────

/// A `.global` facet type and the pack that owns (defines) it. `Locked` is
/// the canonical example (RFC §6). `owner_prefix == null` means the facet
/// has no in-project owner (e.g. it lives in an external `contracts`
/// package), in which case *every* pack is a consumer.
pub const GlobalFacet = struct {
    /// Bare type name as written in source, e.g. `Locked`.
    name: []const u8,
    owner_prefix: ?[]const u8,
};

/// A component type and the sanitized prefix of the pack that owns it.
pub const ComponentOwner = struct {
    /// The Pascal type name a `view(.{X})` would name, e.g. `Worker`.
    pascal: []const u8,
    owner_prefix: []const u8,
};

/// An event and the sanitized prefix of the pack that owns it. `qualified`
/// is the emitted `<owner_prefix>__<variant>` identifier (#440) a
/// subscriber would reference.
pub const EventOwner = struct {
    qualified: []const u8,
    owner_prefix: []const u8,
};

/// One OTHER pack, as the cross-pack-import rule (rule 4) sees it: its raw
/// manifest `name` (for the diagnostic), its canonical on-disk `dir` (used
/// for path-containment), and whether the current pack is ALLOWED to reach
/// it — true when the current pack declares it in `depends_on` or it is the
/// implicit `contracts` root. Only imports into a pack with `allowed == false`
/// are flagged. Populated by `check_cmd.zig` per (current-pack) scan.
pub const ForeignPack = struct {
    name: []const u8,
    dir: []const u8,
    allowed: bool,
};

/// Everything the per-source scan needs about the surrounding project.
/// Every slice is borrowed for the duration of the scan call.
pub const Context = struct {
    /// Sanitized namespace prefix of the pack whose file is being scanned.
    current_prefix: []const u8,
    /// Every pack's sanitized prefix (including the current one).
    pack_prefixes: []const []const u8,
    /// Component → owning-pack prefix, across all packs.
    components: []const ComponentOwner = &.{},
    /// Event qualified name → owning-pack prefix, across all packs.
    events: []const EventOwner = &.{},
    /// `.global` facets and their owners.
    global_facets: []const GlobalFacet = &.{},
    /// Sanitized prefixes of packs that (transitively) `depends_on` the
    /// current pack — i.e. the packs *higher* than it in the DAG. Used by
    /// rule 3: a reference to one of these packs' events is an inversion.
    dependents_of_current: []const []const u8 = &.{},
    /// Canonical on-disk directory of the pack being scanned. Rule 4 resolves
    /// each relative `@import` against the importing file's dir and compares
    /// the result to the foreign pack dirs. Empty (`""`, the default) DISABLES
    /// rule 4 — so the pure per-source unit tests, which pass synthetic file
    /// paths and no pack dirs, never trip it.
    current_pack_dir: []const u8 = "",
    /// Every OTHER pack's dir + allow-status, for rule 4. See `ForeignPack`.
    foreign_packs: []const ForeignPack = &.{},
};

// ── Accessor name sets ───────────────────────────────────────────────────

/// String-keyed registry accessors — the ones that can name a foreign type
/// via a plain string, sidestepping module isolation (RFC §6-1b). Kept
/// deliberately narrow (high confidence over broad coverage).
const string_accessors = [_][]const u8{
    "getType",
    "getTypeId",
    "entityHasNamed",
    "hasNamed",
    "getNamed",
};

/// Type-keyed view accessors — a raw cross-pack `view(.{ForeignComponent})`
/// (RFC §6 "STRICT encapsulation"). Legal over a pack's *own* components,
/// so a hit is only reported when the component is unambiguously foreign.
const view_accessors = [_][]const u8{
    "view",
    "viewMut",
};

fn inSet(set: []const []const u8, name: []const u8) bool {
    for (set) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

// ── Token model ──────────────────────────────────────────────────────────

const Tok = struct {
    tag: std.zig.Token.Tag,
    start: usize,
    end: usize,
};

fn tokenize(arena: std.mem.Allocator, src_z: [:0]const u8) ![]Tok {
    var list: std.ArrayList(Tok) = .empty;
    var tz = std.zig.Tokenizer.init(src_z);
    while (true) {
        const t = tz.next();
        if (t.tag == .eof) break;
        try list.append(arena, .{ .tag = t.tag, .start = t.loc.start, .end = t.loc.end });
    }
    return list.toOwnedSlice(arena);
}

/// 1-based line/column of a byte offset in `src`.
fn locOf(src: []const u8, offset: usize) struct { line: usize, col: usize } {
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

/// Decode a simple `"..."` string-literal token into its body, or `null`
/// for a form with escapes / multiline (`\\`) — registry name literals are
/// plain identifiers, so this loses nothing while staying unambiguous.
fn decodeStringLiteral(raw: []const u8) ?[]const u8 {
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return null;
    const inner = raw[1 .. raw.len - 1];
    if (std.mem.indexOfScalar(u8, inner, '\\') != null) return null;
    return inner;
}

fn containsStr(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| {
        if (std.mem.eql(u8, h, needle)) return true;
    }
    return false;
}

/// If `qualified` is a `<prefix>__…` name whose `<prefix>` is a *foreign*
/// pack (a declared pack, not the current one), return that prefix.
fn foreignPrefixOf(qualified: []const u8, ctx: Context) ?[]const u8 {
    const sep = std.mem.indexOf(u8, qualified, "__") orelse return null;
    const prefix = qualified[0..sep];
    if (prefix.len == 0) return null;
    if (std.mem.eql(u8, prefix, ctx.current_prefix)) return null;
    if (!containsStr(ctx.pack_prefixes, prefix)) return null;
    return prefix;
}

/// Resolve a bare component type name to its owning pack prefix, but only
/// when the answer is unambiguous *and* foreign: exactly one pack owns it,
/// that pack isn't the current one, and the current pack does not also
/// define a component of the same name (which would make the bare
/// reference its own). Ambiguity → `null` (silence over a false positive).
fn foreignComponentOwner(name: []const u8, ctx: Context) ?[]const u8 {
    var owner: ?[]const u8 = null;
    var count: usize = 0;
    for (ctx.components) |c| {
        if (!std.mem.eql(u8, c.pascal, name)) continue;
        if (std.mem.eql(u8, c.owner_prefix, ctx.current_prefix)) return null; // own type
        if (owner == null or !std.mem.eql(u8, owner.?, c.owner_prefix)) {
            owner = c.owner_prefix;
            count += 1;
        }
    }
    if (count != 1) return null;
    return owner;
}

/// True when the current pack owns a component named `name` (its own type).
fn currentOwnsComponent(name: []const u8, ctx: Context) bool {
    for (ctx.components) |c| {
        if (std.mem.eql(u8, c.pascal, name) and std.mem.eql(u8, c.owner_prefix, ctx.current_prefix)) return true;
    }
    return false;
}

// ── Per-source scan ──────────────────────────────────────────────────────

/// Scan one `.zig` source buffer, appending a `Finding` for every §6
/// violation. `file` is stored verbatim on each finding (borrowed). Pure
/// over `ctx`; all allocation goes through `arena`.
///
/// Never fails on malformed input: `std.zig.Tokenizer` yields
/// `.invalid` tokens rather than erroring, so a garbled file simply
/// produces no matches.
pub fn scanSource(
    arena: std.mem.Allocator,
    findings: *std.ArrayList(Finding),
    src: []const u8,
    file: []const u8,
    ctx: Context,
) !void {
    const src_z = try arena.dupeZ(u8, src);
    const toks = try tokenize(arena, src_z);

    var i: usize = 0;
    while (i < toks.len) : (i += 1) {
        const tk = toks[i];

        // Rule 4 — cross-pack file import `@import("…")`. A builtin token,
        // so handled before the identifier gate below.
        if (tk.tag == .builtin and std.mem.eql(u8, src[tk.start..tk.end], "@import") and
            i + 2 < toks.len and toks[i + 1].tag == .l_paren and toks[i + 2].tag == .string_literal)
        {
            try checkCrossPackImport(arena, findings, src, file, ctx, toks[i + 2]);
        }

        if (tk.tag != .identifier) continue;
        const name = src[tk.start..tk.end];

        // Rule 1 — registry accessor call.
        if ((inSet(&string_accessors, name) or inSet(&view_accessors, name)) and
            i + 1 < toks.len and toks[i + 1].tag == .l_paren)
        {
            try scanAccessorCall(arena, findings, src, file, ctx, toks, i, name);
        }

        // Rule 2 — global-facet construction `<Facet>{`.
        if (i + 1 < toks.len and toks[i + 1].tag == .l_brace) {
            try checkGlobalFacetWrite(arena, findings, src, file, ctx, toks, i, name);
        }

        // Rule 3 — reference to a higher pack's qualified event.
        try checkEventDirection(arena, findings, src, file, ctx, tk, name);
    }
}

fn scanAccessorCall(
    arena: std.mem.Allocator,
    findings: *std.ArrayList(Finding),
    src: []const u8,
    file: []const u8,
    ctx: Context,
    toks: []const Tok,
    ident_i: usize,
    accessor: []const u8,
) !void {
    const is_view = inSet(&view_accessors, accessor);
    const is_string = inSet(&string_accessors, accessor);

    var depth: usize = 0;
    var j = ident_i + 1; // the l_paren
    while (j < toks.len) : (j += 1) {
        const t = toks[j];
        switch (t.tag) {
            .l_paren, .l_brace, .l_bracket => depth += 1,
            .r_paren, .r_brace, .r_bracket => {
                depth -= 1;
                if (depth == 0) break;
            },
            .string_literal => if (is_string) {
                if (decodeStringLiteral(src[t.start..t.end])) |val| {
                    if (foreignPrefixOf(val, ctx)) |pfx| {
                        const msg = try std.fmt.allocPrint(
                            arena,
                            "pack '{s}' reads foreign registry name \"{s}\" (owned by pack '{s}') via {s}(...); cross-pack reads must go through the owner's published queries — a pack's own names resolve via @import(\"pack\").Registry, and foreign names die there at compile time; only the anytype `game` param still resolves them, which is exactly what this lint nets (RFC §6 / #498)",
                            .{ ctx.current_prefix, val, pfx, accessor },
                        );
                        try emit(arena, findings, .cross_pack_registry_access, src, file, t.start, msg);
                    }
                }
            },
            .identifier => if (is_view) {
                const cname = src[t.start..t.end];
                if (foreignComponentOwner(cname, ctx)) |owner_pfx| {
                    const msg = try std.fmt.allocPrint(
                        arena,
                        "pack '{s}' views foreign component '{s}' (owned by pack '{s}') via {s}(...); a pack's components are private — read through the owner's published queries. Since the pack module wall (#498) this also fails to compile; this lint is the fast pre-build diagnostic (RFC §6)",
                        .{ ctx.current_prefix, cname, owner_pfx, accessor },
                    );
                    try emit(arena, findings, .cross_pack_registry_access, src, file, t.start, msg);
                }
            },
            else => {},
        }
    }
}

fn checkGlobalFacetWrite(
    arena: std.mem.Allocator,
    findings: *std.ArrayList(Finding),
    src: []const u8,
    file: []const u8,
    ctx: Context,
    toks: []const Tok,
    ident_i: usize,
    name: []const u8,
) !void {
    for (ctx.global_facets) |gf| {
        if (!std.mem.eql(u8, gf.name, name)) continue;
        // The owner may construct its own facet freely.
        if (gf.owner_prefix) |op| {
            if (std.mem.eql(u8, op, ctx.current_prefix)) return;
        }
        // A pack that defines its OWN type of this name isn't touching the
        // shared facet — skip to avoid a false positive on a name clash.
        if (currentOwnsComponent(name, ctx)) return;
        // Qualified (`foo.Locked{}`) is a field/namespaced access we can't
        // confidently attribute to the facet — stay silent for precision.
        if (ident_i > 0 and toks[ident_i - 1].tag == .period) return;

        const msg = try std.fmt.allocPrint(
            arena,
            "pack '{s}' constructs the shared '.global' facet '{s}' directly (`{s}{{...}}`); global facets are multi-writer coordination primitives and must be mutated via their sanctioned API (e.g. `{s}.tryAcquire`), never a raw component write (RFC §6)",
            .{ ctx.current_prefix, name, name, name },
        );
        try emit(arena, findings, .raw_global_facet_write, src, file, toks[ident_i].start, msg);
        return;
    }
}

fn checkEventDirection(
    arena: std.mem.Allocator,
    findings: *std.ArrayList(Finding),
    src: []const u8,
    file: []const u8,
    ctx: Context,
    tk: Tok,
    name: []const u8,
) !void {
    for (ctx.events) |ev| {
        if (!std.mem.eql(u8, ev.qualified, name)) continue;
        if (std.mem.eql(u8, ev.owner_prefix, ctx.current_prefix)) return; // own event
        // Inversion iff the owner is *higher* than the current pack — i.e.
        // the owner (transitively) depends_on the current pack.
        if (containsStr(ctx.dependents_of_current, ev.owner_prefix)) {
            const msg = try std.fmt.allocPrint(
                arena,
                "pack '{s}' references event '{s}' owned by pack '{s}', which depends on '{s}' — a lower pack must not react to a higher pack's event (events point up the DAG; RFC §6)",
                .{ ctx.current_prefix, name, ev.owner_prefix, ctx.current_prefix },
            );
            try emit(arena, findings, .event_direction_inversion, src, file, tk.start, msg);
        }
        return;
    }
}

/// True when path `p` equals `base` or sits beneath it (`base/…`). Both are
/// canonical lexical paths (already `..`-resolved); this is a plain prefix
/// test guarded on a `/` boundary so `…/citizens` doesn't match `…/citizens2`.
fn pathUnder(p: []const u8, base: []const u8) bool {
    if (base.len == 0) return false;
    if (!std.mem.startsWith(u8, p, base)) return false;
    return p.len == base.len or p[base.len] == '/' or p[base.len] == '\\';
}

/// Rule 4 — a relative-path `@import` that resolves into a foreign pack dir.
/// `path_tok` is the string-literal argument. Silent unless `ctx.current_pack_dir`
/// is set (so the pure per-source tests, which don't populate pack dirs, are
/// unaffected). Only literal, relative, `.zig` file imports are considered —
/// module imports (`@import("std")`, `@import("game")`) never end in `.zig` and
/// can't textually name a foreign source file.
fn checkCrossPackImport(
    arena: std.mem.Allocator,
    findings: *std.ArrayList(Finding),
    src: []const u8,
    file: []const u8,
    ctx: Context,
    path_tok: Tok,
) !void {
    if (ctx.current_pack_dir.len == 0) return; // rule disabled (unit-test path)
    if (ctx.foreign_packs.len == 0) return; // nothing foreign to reach

    const path = decodeStringLiteral(src[path_tok.start..path_tok.end]) orelse return;
    // Only a relative FILE import can escape into another pack's tree. A bare
    // module name has no `.zig` suffix; a package/module import never does.
    if (!std.mem.endsWith(u8, path, ".zig")) return;

    // Resolve the import against the importing file's directory, lexically
    // collapsing `..`/`.`. `file` is the canonical pack-dir-joined path the
    // walker produced, so the result shares a canonical base with the foreign
    // pack dirs (both come from the same `resolvePlugin` realpath pass).
    const dir = std.fs.path.dirname(file) orelse ".";
    const resolved = std.fs.path.resolve(arena, &.{ dir, path }) catch return;

    // Staying inside the current pack is always fine.
    if (pathUnder(resolved, ctx.current_pack_dir)) return;

    for (ctx.foreign_packs) |fp| {
        if (!pathUnder(resolved, fp.dir)) continue;
        if (fp.allowed) return; // declared dependency (or contracts) — permitted
        const msg = try std.fmt.allocPrint(
            arena,
            "pack '{s}' @imports \"{s}\", a source file inside pack '{s}' — which it does not declare in depends_on; a pack may not reach around the ACL by importing another pack's files directly (add '{s}' to depends_on and go through its published surface, or drop the import). Since the pack module wall (#498) this also fails to compile; this lint is the fast pre-build diagnostic. RFC §6 / engine #656",
            .{ ctx.current_prefix, path, fp.name, fp.name },
        );
        try emit(arena, findings, .cross_pack_import, src, file, path_tok.start, msg);
        return;
    }
}

fn emit(
    arena: std.mem.Allocator,
    findings: *std.ArrayList(Finding),
    rule: Rule,
    src: []const u8,
    file: []const u8,
    offset: usize,
    message: []const u8,
) !void {
    const loc = locOf(src, offset);
    try findings.append(arena, .{
        .rule = rule,
        .file = file,
        .line = loc.line,
        .col = loc.col,
        .message = message,
    });
}

// ── Directory walk ───────────────────────────────────────────────────────

/// Recursively scan every `.zig` file under `pack_dir`, appending findings.
/// Each finding's `file` is `pack_dir`-joined and arena-owned. Unreadable
/// files are skipped silently (a missing/garbled file is not the lint's
/// concern — the build surfaces those). `io` is the process Io.
pub fn scanPackDir(
    arena: std.mem.Allocator,
    io: std.Io,
    findings: *std.ArrayList(Finding),
    pack_dir: []const u8,
    ctx: Context,
) !void {
    try walkDir(arena, io, findings, pack_dir, pack_dir, ctx);
}

fn walkDir(
    arena: std.mem.Allocator,
    io: std.Io,
    findings: *std.ArrayList(Finding),
    root: []const u8,
    dir_path: []const u8,
    ctx: Context,
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const child = try std.fs.path.join(arena, &.{ dir_path, entry.name });
        switch (entry.kind) {
            // Never descend into a nested repository root — a `git
            // worktree`, a submodule or a plain clone parked inside the
            // pack (#692). Its files belong to a different revision, so
            // every finding it produced would name a path the working
            // tree does not contain. The probe keys on the `.git` marker's
            // EXISTENCE, not its kind: a worktree's / submodule's `.git`
            // is a FILE holding a `gitdir:` pointer.
            .directory => {
                if (scanner.isRepoRootIo(io, dir, entry.name)) continue;
                try walkDir(arena, io, findings, root, child, ctx);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                const src = std.Io.Dir.cwd().readFileAlloc(io, child, arena, .limited(8 * 1024 * 1024)) catch continue;
                try scanSource(arena, findings, src, child, ctx);
            },
            else => {},
        }
    }
}

// ════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════

const testing = std.testing;

/// Test helper: scan `src` under a minimal single-pack context and return
/// the findings (arena-owned by the caller-provided arena).
fn scanOne(arena: std.mem.Allocator, src: []const u8, ctx: Context) ![]Finding {
    var findings: std.ArrayList(Finding) = .empty;
    try scanSource(arena, &findings, src, "test.zig", ctx);
    return findings.toOwnedSlice(arena);
}

test "rule 1: getType on a foreign namespaced name is flagged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context{
        .current_prefix = "production",
        .pack_prefixes = &.{ "production", "citizens" },
    };
    const src =
        \\pub fn work(game: anytype) void {
        \\    const T = game.getType("citizens__Worker");
        \\    _ = T;
        \\}
        \\
    ;
    const f = try scanOne(arena.allocator(), src, ctx);
    try testing.expectEqual(@as(usize, 1), f.len);
    try testing.expectEqual(Rule.cross_pack_registry_access, f[0].rule);
    try testing.expectEqual(@as(usize, 2), f[0].line);
}

test "rule 1: entityHasNamed on a foreign name is flagged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context{
        .current_prefix = "production",
        .pack_prefixes = &.{ "production", "citizens" },
    };
    const f = try scanOne(arena.allocator(),
        \\const x = entityHasNamed(ecs, e, "citizens__Locked");
    , ctx);
    try testing.expectEqual(@as(usize, 1), f.len);
    try testing.expectEqual(Rule.cross_pack_registry_access, f[0].rule);
}

test "rule 1: getType on the pack's OWN namespaced name is clean" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context{
        .current_prefix = "citizens",
        .pack_prefixes = &.{ "production", "citizens" },
    };
    const f = try scanOne(arena.allocator(),
        \\const T = game.getType("citizens__Worker");
    , ctx);
    try testing.expectEqual(@as(usize, 0), f.len);
}

test "rule 1: getType on a non-pack prefix (engine primitive) is clean" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context{
        .current_prefix = "citizens",
        .pack_prefixes = &.{ "production", "citizens" },
    };
    // `engine` is not a declared pack — not a cross-pack access.
    const f = try scanOne(arena.allocator(),
        \\const T = game.getType("engine__Position");
    , ctx);
    try testing.expectEqual(@as(usize, 0), f.len);
}

test "rule 1: view of a foreign component is flagged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context{
        .current_prefix = "production",
        .pack_prefixes = &.{ "production", "citizens" },
        .components = &.{
            .{ .pascal = "Worker", .owner_prefix = "citizens" },
        },
    };
    const f = try scanOne(arena.allocator(),
        \\pub fn tick(game: anytype) void {
        \\    var it = game.view(.{Worker});
        \\    _ = it;
        \\}
    , ctx);
    try testing.expectEqual(@as(usize, 1), f.len);
    try testing.expectEqual(Rule.cross_pack_registry_access, f[0].rule);
}

test "rule 1: view of the pack's own component is clean" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context{
        .current_prefix = "citizens",
        .pack_prefixes = &.{ "production", "citizens" },
        .components = &.{
            .{ .pascal = "Worker", .owner_prefix = "citizens" },
        },
    };
    const f = try scanOne(arena.allocator(),
        \\var it = game.view(.{Worker});
    , ctx);
    try testing.expectEqual(@as(usize, 0), f.len);
}

test "rule 1: view of an ambiguously-owned component is not flagged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Both citizens and production define a `Worker`; a bare `Worker` in a
    // THIRD pack is ambiguous → silence over a false positive.
    const ctx = Context{
        .current_prefix = "guard",
        .pack_prefixes = &.{ "production", "citizens", "guard" },
        .components = &.{
            .{ .pascal = "Worker", .owner_prefix = "citizens" },
            .{ .pascal = "Worker", .owner_prefix = "production" },
        },
    };
    const f = try scanOne(arena.allocator(),
        \\var it = game.view(.{Worker});
    , ctx);
    try testing.expectEqual(@as(usize, 0), f.len);
}

test "rule 2: raw global-facet construction is flagged in a consumer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context{
        .current_prefix = "production",
        .pack_prefixes = &.{ "production", "contracts" },
        .global_facets = &.{
            .{ .name = "Locked", .owner_prefix = "contracts" },
        },
    };
    const f = try scanOne(arena.allocator(),
        \\pub fn claim(game: anytype, e: u64) void {
        \\    game.addComponent(e, Locked{ .owner = 1 });
        \\}
    , ctx);
    try testing.expectEqual(@as(usize, 1), f.len);
    try testing.expectEqual(Rule.raw_global_facet_write, f[0].rule);
}

test "rule 2: the owner constructing its own facet is clean" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context{
        .current_prefix = "contracts",
        .pack_prefixes = &.{ "production", "contracts" },
        .global_facets = &.{
            .{ .name = "Locked", .owner_prefix = "contracts" },
        },
    };
    const f = try scanOne(arena.allocator(),
        \\pub fn tryAcquire(e: u64) Locked {
        \\    return Locked{ .owner = e };
        \\}
    , ctx);
    try testing.expectEqual(@as(usize, 0), f.len);
}

test "rule 2: the sanctioned API call is clean" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context{
        .current_prefix = "production",
        .pack_prefixes = &.{ "production", "contracts" },
        .global_facets = &.{
            .{ .name = "Locked", .owner_prefix = "contracts" },
        },
    };
    // `Locked.tryAcquire(...)` is `Locked` `.` `tryAcquire` — no `{`.
    const f = try scanOne(arena.allocator(),
        \\const ok = Locked.tryAcquire(game, e);
    , ctx);
    try testing.expectEqual(@as(usize, 0), f.len);
}

test "rule 3: a lower pack referencing a higher pack's event is flagged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // production depends_on citizens → production higher, citizens lower.
    // citizens referencing production's event is an inversion.
    const ctx = Context{
        .current_prefix = "citizens",
        .pack_prefixes = &.{ "production", "citizens" },
        .events = &.{
            .{ .qualified = "production__item_produced", .owner_prefix = "production" },
        },
        .dependents_of_current = &.{"production"},
    };
    const f = try scanOne(arena.allocator(),
        \\pub fn on_event(ev: GameEvents) void {
        \\    switch (ev) {
        \\        .production__item_produced => react(),
        \\        else => {},
        \\    }
        \\}
    , ctx);
    try testing.expectEqual(@as(usize, 1), f.len);
    try testing.expectEqual(Rule.event_direction_inversion, f[0].rule);
}

test "rule 3: a higher pack referencing a lower pack's event is clean" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // production (higher) reacting to citizens (lower) event is fine —
    // events point up.
    const ctx = Context{
        .current_prefix = "production",
        .pack_prefixes = &.{ "production", "citizens" },
        .events = &.{
            .{ .qualified = "citizens__worker_died", .owner_prefix = "citizens" },
        },
        .dependents_of_current = &.{}, // nothing depends on production here
    };
    const f = try scanOne(arena.allocator(),
        \\const tag = GameEvents.citizens__worker_died;
    , ctx);
    try testing.expectEqual(@as(usize, 0), f.len);
}

/// A fixture path in HOST-absolute form.
///
/// The rule-4 tests compare an `@import` that `checkCrossPackImport` has run
/// through `std.fs.path.resolve` against the pack dirs in `Context`. On
/// Windows that resolve turns a rooted `/proj/...` into `C:\proj\...`, so a
/// POSIX literal on the other side of the comparison never matched and the
/// rule silently found nothing (#699).
///
/// Resolving the fixture the same way mirrors production, where both sides
/// come from one `resolvePlugin` realpath pass — which is exactly what the
/// comment on `checkCrossPackImport` promises.
fn fixturePath(arena: std.mem.Allocator, posix: []const u8) ![]const u8 {
    return std.fs.path.resolve(arena, &.{posix});
}

test "rule 4: importing a non-dependency pack's file is flagged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context{
        .current_prefix = "production",
        .pack_prefixes = &.{ "production", "citizens" },
        .current_pack_dir = try fixturePath(arena.allocator(), "/proj/packs/production"),
        .foreign_packs = &.{
            .{ .name = "citizens", .dir = try fixturePath(arena.allocator(), "/proj/packs/citizens"), .allowed = false },
        },
    };
    var findings: std.ArrayList(Finding) = .empty;
    try scanSource(arena.allocator(), &findings,
        \\const Worker = @import("../../citizens/components/worker.zig").Worker;
    , try fixturePath(arena.allocator(), "/proj/packs/production/scripts/00_work.zig"), ctx);
    try testing.expectEqual(@as(usize, 1), findings.items.len);
    try testing.expectEqual(Rule.cross_pack_import, findings.items[0].rule);
    try testing.expect(std.mem.indexOf(u8, findings.items[0].message, "citizens") != null);
}

test "rule 4: importing a DECLARED-dependency pack's file is allowed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Same import, but citizens is a declared dependency (allowed = true).
    const ctx = Context{
        .current_prefix = "production",
        .pack_prefixes = &.{ "production", "citizens" },
        .current_pack_dir = try fixturePath(arena.allocator(), "/proj/packs/production"),
        .foreign_packs = &.{
            .{ .name = "citizens", .dir = try fixturePath(arena.allocator(), "/proj/packs/citizens"), .allowed = true },
        },
    };
    var findings: std.ArrayList(Finding) = .empty;
    try scanSource(arena.allocator(), &findings,
        \\const Worker = @import("../../citizens/components/worker.zig").Worker;
    , try fixturePath(arena.allocator(), "/proj/packs/production/scripts/00_work.zig"), ctx);
    try testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "rule 4: a pack importing its OWN file is clean" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context{
        .current_prefix = "production",
        .pack_prefixes = &.{ "production", "citizens" },
        .current_pack_dir = try fixturePath(arena.allocator(), "/proj/packs/production"),
        .foreign_packs = &.{
            .{ .name = "citizens", .dir = try fixturePath(arena.allocator(), "/proj/packs/citizens"), .allowed = false },
        },
    };
    var findings: std.ArrayList(Finding) = .empty;
    try scanSource(arena.allocator(), &findings,
        \\const Local = @import("../components/thing.zig").Thing;
    , try fixturePath(arena.allocator(), "/proj/packs/production/scripts/00_work.zig"), ctx);
    try testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "rule 4: a module import (no .zig) is never a cross-pack import" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context{
        .current_prefix = "production",
        .pack_prefixes = &.{ "production", "citizens" },
        .current_pack_dir = try fixturePath(arena.allocator(), "/proj/packs/production"),
        .foreign_packs = &.{
            .{ .name = "citizens", .dir = try fixturePath(arena.allocator(), "/proj/packs/citizens"), .allowed = false },
        },
    };
    var findings: std.ArrayList(Finding) = .empty;
    try scanSource(arena.allocator(), &findings,
        \\const std = @import("std");
        \\const game = @import("game");
    , try fixturePath(arena.allocator(), "/proj/packs/production/scripts/00_work.zig"), ctx);
    try testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "rule 4: disabled (no current_pack_dir) never fires" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Default Context (current_pack_dir == "") — the pure unit-test shape.
    const ctx = Context{
        .current_prefix = "production",
        .pack_prefixes = &.{ "production", "citizens" },
    };
    var findings: std.ArrayList(Finding) = .empty;
    try scanSource(arena.allocator(), &findings,
        \\const W = @import("../../citizens/components/worker.zig").Worker;
    , "test.zig", ctx);
    try testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "rule 4: a sibling-prefix dir does not false-match (citizens vs citizens2)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Import resolves under /proj/packs/citizens2, which is a declared dep;
    // the /proj/packs/citizens boundary must not swallow it.
    const ctx = Context{
        .current_prefix = "production",
        .pack_prefixes = &.{ "production", "citizens", "citizens2" },
        .current_pack_dir = try fixturePath(arena.allocator(), "/proj/packs/production"),
        .foreign_packs = &.{
            .{ .name = "citizens", .dir = try fixturePath(arena.allocator(), "/proj/packs/citizens"), .allowed = false },
            .{ .name = "citizens2", .dir = try fixturePath(arena.allocator(), "/proj/packs/citizens2"), .allowed = true },
        },
    };
    var findings: std.ArrayList(Finding) = .empty;
    try scanSource(arena.allocator(), &findings,
        \\const W = @import("../../citizens2/components/worker.zig").Worker;
    , try fixturePath(arena.allocator(), "/proj/packs/production/scripts/00_work.zig"), ctx);
    try testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "clean pack source produces no findings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context{
        .current_prefix = "citizens",
        .pack_prefixes = &.{ "production", "citizens", "contracts" },
        .components = &.{.{ .pascal = "Worker", .owner_prefix = "citizens" }},
        .global_facets = &.{.{ .name = "Locked", .owner_prefix = "contracts" }},
    };
    const f = try scanOne(arena.allocator(),
        \\pub fn decay(game: anytype) void {
        \\    var it = game.view(.{Worker});
        \\    while (it.next()) |w| {
        \\        _ = w;
        \\    }
        \\}
    , ctx);
    try testing.expectEqual(@as(usize, 0), f.len);
}

test "scanPackDir: walks a temp pack tree and reports a nested violation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "scripts");
    try tmp.dir.writeFile(io, .{
        .sub_path = "scripts/00_work.zig",
        .data =
        \\pub fn work(game: anytype) void {
        \\    _ = game.getType("citizens__Worker");
        \\}
        ,
    });
    // A clean sibling file must not trip anything.
    try tmp.dir.writeFile(io, .{
        .sub_path = "scripts/01_idle.zig",
        .data = "pub fn idle() void {}",
    });

    const pack_dir = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const ctx = Context{
        .current_prefix = "production",
        .pack_prefixes = &.{ "production", "citizens" },
    };

    var findings: std.ArrayList(Finding) = .empty;
    try scanPackDir(arena, io, &findings, pack_dir, ctx);
    try testing.expectEqual(@as(usize, 1), findings.items.len);
    try testing.expectEqual(Rule.cross_pack_registry_access, findings.items[0].rule);
    try testing.expect(std.mem.endsWith(u8, findings.items[0].file, "00_work.zig"));
}

// ── Nested-checkout pruning (labelle-assembler#692) ─────────────────────

/// One offending source, as a plain quoted literal so the fixture stays
/// readable next to the assertions.
const violating_source = "pub fn work(game: anytype) void {\n    _ = game.getType(\"citizens__Worker\");\n}\n";

fn lintCtx() Context {
    return .{
        .current_prefix = "production",
        .pack_prefixes = &.{ "production", "citizens" },
    };
}

test "scanPackDir: a nested git checkout inside the pack is not walked (#692)" {
    // A `git worktree` / submodule / nested clone parked in the pack holds
    // a DIFFERENT revision. Linting it reports violations against files
    // that are not in the working tree — the reader has no way to act on
    // the diagnostic, and no way to see why it appeared.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "scripts");
    try tmp.dir.writeFile(io, .{
        .sub_path = "scripts/01_idle.zig",
        .data = "pub fn idle() void {}",
    });
    // The nested checkout, under a name that carries no special meaning —
    // the prune must not be keyed on `.worktrees`. `git worktree add`
    // writes `.git` as a FILE holding a `gitdir:` pointer, so the probe
    // tests the entry's existence, never its kind.
    try tmp.dir.createDirPath(io, "verify-821/scripts");
    try tmp.dir.writeFile(io, .{
        .sub_path = "verify-821/.git",
        .data = "gitdir: /somewhere/.git/worktrees/verify-821\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "verify-821/scripts/00_work.zig",
        .data = violating_source,
    });

    const pack_dir = try tmp.dir.realPathFileAlloc(io, ".", arena);

    var findings: std.ArrayList(Finding) = .empty;
    try scanPackDir(arena, io, &findings, pack_dir, lintCtx());
    for (findings.items) |f| {
        std.debug.print("check descended into a nested checkout: {s}\n", .{f.file});
    }
    try testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "scanPackDir: a nested clone whose .git is a DIRECTORY is not walked (#692)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "vendor/upstream/.git/objects");
    try tmp.dir.createDirPath(io, "vendor/upstream/scripts");
    try tmp.dir.writeFile(io, .{
        .sub_path = "vendor/upstream/scripts/00_work.zig",
        .data = violating_source,
    });

    const pack_dir = try tmp.dir.realPathFileAlloc(io, ".", arena);

    var findings: std.ArrayList(Finding) = .empty;
    try scanPackDir(arena, io, &findings, pack_dir, lintCtx());
    try testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "scanPackDir: an ordinary dir named worktrees is still walked (#692 negative control)" {
    // The prune keys on the `.git` marker, never on the name: a plain
    // folder that happens to be called `worktrees` holds real pack source.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "worktrees/scripts");
    try tmp.dir.writeFile(io, .{
        .sub_path = "worktrees/scripts/00_work.zig",
        .data = violating_source,
    });

    const pack_dir = try tmp.dir.realPathFileAlloc(io, ".", arena);

    var findings: std.ArrayList(Finding) = .empty;
    try scanPackDir(arena, io, &findings, pack_dir, lintCtx());
    try testing.expectEqual(@as(usize, 1), findings.items.len);
    try testing.expect(std.mem.endsWith(u8, findings.items[0].file, "00_work.zig"));
}
