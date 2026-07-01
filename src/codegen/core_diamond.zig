//! Generic core+gfx-diamond unification walk (epic #453 item 3, PR 2 — see
//! `docs/design/manifest-v2-build-graph.md` §5, "The generic core-diamond graph
//! walk"). This is the single **highest-regression-risk** seam in the whole v2
//! build graph (§5 "Why this is the highest regression risk"): it must reproduce
//! the behavior of the ~8 hand-written `overrideImport` sites in
//! `src/templates/build_zig.txt` EXACTLY, and the bug it prevents is invisible to
//! `zig build test` — it only surfaces as a `@compileError`/type-mismatch during
//! a cross-compile link in CI (two distinct `GamepadEvent`/`YAxis` types across
//! the engine↔backend seam).
//!
//! ## What this replaces (the current hand-written override sites)
//!
//! Today "unify every `labelle-core` onto the app's single `core_mod`" is
//! enforced by scattered `overrideImport` calls, each with a subtly different key
//! spelling and target module, each an `if`-guarded landmine (§5 table). The
//! concrete sites in `build_zig.txt` (repeated per-platform in `.deps`/`.ios_deps`/
//! `.android_deps` footers), that this ONE walk generalizes:
//!
//!   * `:28`  `gfx_mod`   ← `labelle-core`  (fixed diamond)
//!   * `:29`  `engine_mod`← `labelle-core`  (fixed diamond)
//!   * `:30`  `engine_mod`← `labelle-gfx`   (fixed diamond — the engine→gfx edge)
//!   * `:41`  `unifyGfxSubpackageCore` — hardcoded `{camera, spatial_grid,
//!            tilemap}` sub-packages ← `labelle-core`
//!   * `:71`  raylib `backend_input` ← `labelle-core`   (hyphen key)
//!   * `:85`  raylib transitive `sdl_gamepad` ← `labelle_core` (underscore, guard)
//!   * `:108` sokol transitive `sdl_gamepad` ← `labelle_core` (underscore, guard)
//!   * `:118` sokol Linux `backend_input` ← `labelle-core`   (hyphen, guard)
//!   * `:141` sdl `backend_input` ← `labelle_core`  (UNDERSCORE — SDL spells it
//!            differently, #258)
//!   * `:162` bgfx transitive `sdl_gamepad` ← `labelle_core` (underscore, guard)
//!   * `:812` bgfx-android `backend_input` ← `labelle-core` (hyphen, guard, #310)
//!
//! ## The collapse (§5 "The collapse")
//!
//! All of the above are instances of ONE rule with TWO singleton targets: for
//! every module reachable from a provider root, walk its `import_table`; wherever
//! a key resolves to a `labelle-core`/`labelle_core` provider, override it onto
//! the app's single `core_mod`; wherever a key resolves to a `labelle-gfx`/
//! `labelle_gfx` provider, override it onto the app's single `gfx_mod`; recurse
//! into everything else. The `if`-guards vanish (an absent import is simply never
//! visited — we only ever touch keys already present in an `import_table`), both
//! key spellings are handled for both singletons, the fixed engine→gfx edge is
//! PRESERVED rather than recursed-through (a walk that rewrote only the core
//! spellings would leave two `labelle-gfx` instances across the app/engine seam —
//! the renderer's `gfx.Texture` ≠ engine's; §5 review correction #4), and the
//! hardcoded `{camera, spatial_grid, tilemap}` list becomes "every transitive
//! sub-import that names core" — resilient if gfx restructures.
//!
//! ## Structure — why this is unit-testable WITHOUT a real `zig build`
//!
//! The walk in the generated `build.zig` runs at the CONSUMER's build time over
//! real `std.Build.Module` graphs, which cannot be synthesized in an assembler
//! unit test without a live `*std.Build`. So the traversal is extracted here into
//! a PURE function (`unifyCoreDiamond`) over a minimal synthetic module-graph
//! abstraction (`Module`: a name + a `import_table` that mirrors
//! `std.Build.Module`'s own `StringArrayHashMapUnmanaged(*Module)`). Tests build
//! tiny synthetic graphs and assert the invariant directly.
//!
//! `generated_walk_zig` is the exact `build.zig`-source MIRROR of that logic (over
//! `*std.Build.Module`, the §5 shape) that PR 3 will splice into the generated
//! `build.zig`. Both forms are kept byte-structurally identical so the tested
//! logic and the emitted code cannot drift; a test parses the generated source to
//! guard against a syntactically broken helper.
//!
//! **This PR is the helper + tests ONLY. Nothing here is wired into
//! `build_files.zig` / `build_zig.txt` yet — that is PR 3.**

const std = @import("std");
const testing = std.testing;

// ─────────────────────────────────────────────────────────────────────────
// Synthetic module-graph abstraction
// ─────────────────────────────────────────────────────────────────────────

/// A minimal stand-in for `std.Build.Module`, carrying only the surface the walk
/// touches: a name (for readable test assertions) and an `import_table` that is
/// the SAME container type `std.Build.Module` uses — `StringArrayHashMapUnmanaged`
/// keyed by import name, valued by the imported module. `allocator` mirrors
/// `std.Build.Module.owner.allocator`, which the real `overrideImport` reaches
/// through; keeping it on the node lets `overrideImport` below have the identical
/// `(m, name, module)` signature the template's helper has.
pub const Module = struct {
    name: []const u8,
    allocator: std.mem.Allocator,
    import_table: std.StringArrayHashMapUnmanaged(*Module) = .empty,

    /// Add/replace an import edge. Test-graph construction helper — NOT part of
    /// the walk (the walk only ever REPLACES existing values via `overrideImport`).
    pub fn addImport(self: *Module, name: []const u8, module: *Module) void {
        self.import_table.put(self.allocator, name, module) catch @panic("OOM");
    }
};

/// Visited set — pointer-identity keyed, exactly like the generated walk's
/// `AutoHashMapUnmanaged(*std.Build.Module, void)`. Bounds the recursion so a
/// cyclic import graph terminates.
pub const ModuleSet = std.AutoHashMapUnmanaged(*Module, void);

// ─────────────────────────────────────────────────────────────────────────
// Key predicates — BOTH spellings, for BOTH singletons
// ─────────────────────────────────────────────────────────────────────────

/// True for either spelling of the core import key. The hyphenated
/// `"labelle-core"` is the common spelling; SDL (#258) and several transitive
/// gamepad sub-packages (#271) spell it with an underscore, `"labelle_core"`.
/// Missing either spelling reintroduces the exact mismatch each override site was
/// added to fix.
pub fn isCoreKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "labelle-core") or std.mem.eql(u8, key, "labelle_core");
}

/// True for either spelling of the gfx import key. Handling `labelle-gfx` is what
/// preserves the fixed `engine_mod ← gfx` diamond edge (§5 review correction #4);
/// the underscore form is included for symmetry with core, so a provider that
/// spells gfx with an underscore is covered without a future patch.
pub fn isGfxKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "labelle-gfx") or std.mem.eql(u8, key, "labelle_gfx");
}

// ─────────────────────────────────────────────────────────────────────────
// The walk (pure logic — mirrored byte-for-byte by `generated_walk_zig`)
// ─────────────────────────────────────────────────────────────────────────

/// `overrideImport` for the synthetic graph — the faithful mirror of the
/// template's free helper (`build_zig.txt:341`), which does a `getOrPut` on the
/// module's own `import_table` allocator and replaces the value in place. Using
/// the SAME `getOrPut`-and-replace shape (rather than a bare `getPtr`) keeps this
/// identical to the real code path.
///
/// **Iterator-safety invariant:** the walk only ever calls this with a `key`
/// returned by a live `import_table` iterator, so the key ALWAYS exists →
/// `found_existing` is true → the value is replaced in place with no capacity
/// growth → the in-flight iterator stays valid. It never inserts a new key during
/// iteration. (This is also why the hand-written `if`-guards are unnecessary: the
/// walk cannot inject a dead import, because it only rewrites keys already
/// present — §5 "Over-application is also a bug".)
fn overrideImport(m: *Module, name: []const u8, module: *Module) void {
    const gop = m.import_table.getOrPut(m.allocator, name) catch @panic("OOM");
    if (!gop.found_existing) gop.key_ptr.* = name;
    gop.value_ptr.* = module;
}

/// Generic core+gfx-diamond unification. Walks the provider module graph rooted at
/// `root`; overrides any core import onto `core_mod` and any gfx import onto
/// `gfx_mod`, preserving the existing key spelling; recurses into every other
/// import. Idempotent and bounded by `visited` (so a re-run, or a cyclic graph,
/// terminates). `gpa` backs only the `visited` set.
///
/// The assembler runs this once rooted at each imported provider module (`gfx`,
/// `engine`, and every backend `.modules` entry — `input`/`audio`/`window`/…),
/// plus once rooted at `gfx_mod` itself to unify core inside gfx's own
/// sub-packages (a key matched as `labelle-gfx` is OVERRIDDEN, not recursed into,
/// so the sub-packages under the app's `gfx_mod` are reached by the `gfx_mod`-
/// rooted call — §5 note).
pub fn unifyCoreDiamond(
    gpa: std.mem.Allocator,
    root: *Module,
    core_mod: *Module,
    gfx_mod: *Module,
    visited: *ModuleSet,
) void {
    if (visited.contains(root)) return;
    visited.put(gpa, root, {}) catch @panic("OOM");
    var it = root.import_table.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (isCoreKey(key)) {
            overrideImport(root, key, core_mod); // preserve the existing key spelling
        } else if (isGfxKey(key)) {
            overrideImport(root, key, gfx_mod); // the engine→gfx edge the fixed diamond had
        } else {
            unifyCoreDiamond(gpa, entry.value_ptr.*, core_mod, gfx_mod, visited); // recurse
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────
// The generated-code mirror (spliced into build.zig by PR 3 — UNWIRED here)
// ─────────────────────────────────────────────────────────────────────────

/// The `build.zig`-source form of `unifyCoreDiamond`, over real
/// `*std.Build.Module`, structurally identical to the pure logic above and to the
/// §5 snippet. PR 3 splices this beside the existing free `overrideImport`
/// (`build_zig.txt:341`, unchanged) and replaces the ~8 hand-written override
/// sites + the fixed diamond + `unifyGfxSubpackageCore` with calls to it.
///
/// Kept here, beside the tested logic, so the two cannot drift. It is NOT
/// referenced by any codegen path in this PR (verified: generation output is
/// byte-unchanged). `unifyCoreDiamondTests` parses this to guard against a
/// syntactically broken helper.
pub const generated_walk_zig =
    \\/// Generic core+gfx-diamond unification (labelle-assembler#453, design §5).
    \\/// Replaces the hand-written per-backend `overrideImport` sites AND the fixed
    \\/// `engine_mod ← gfx` edge AND `unifyGfxSubpackageCore`. Walks the provider
    \\/// module graph; overrides any labelle-core import onto `core_mod` and any
    \\/// labelle-gfx import onto `gfx_mod` (preserving the key spelling); recurses
    \\/// otherwise. Idempotent, bounded by `visited`. Only rewrites keys already
    \\/// present in an import_table, so it can never inject a dead import (the old
    \\/// `if`-guards are subsumed) and never grows a table mid-iteration.
    \\fn unifyCoreDiamond(
    \\    gpa: std.mem.Allocator,
    \\    root: *std.Build.Module,
    \\    core_mod: *std.Build.Module,
    \\    gfx_mod: *std.Build.Module,
    \\    visited: *std.AutoHashMapUnmanaged(*std.Build.Module, void),
    \\) void {
    \\    if (visited.contains(root)) return;
    \\    visited.put(gpa, root, {}) catch @panic("OOM");
    \\    var it = root.import_table.iterator();
    \\    while (it.next()) |entry| {
    \\        const key = entry.key_ptr.*;
    \\        if (std.mem.eql(u8, key, "labelle-core") or std.mem.eql(u8, key, "labelle_core")) {
    \\            overrideImport(root, key, core_mod);
    \\        } else if (std.mem.eql(u8, key, "labelle-gfx") or std.mem.eql(u8, key, "labelle_gfx")) {
    \\            overrideImport(root, key, gfx_mod);
    \\        } else {
    \\            unifyCoreDiamond(gpa, entry.value_ptr.*, core_mod, gfx_mod, visited);
    \\        }
    \\    }
    \\}
    \\
;

// ─────────────────────────────────────────────────────────────────────────
// Tests — the point of this PR (§5, §8 PR 2)
// ─────────────────────────────────────────────────────────────────────────

/// Test-graph builder. Owns every `Module` and their `import_table`s in one
/// arena so a single `deinit` frees the whole synthetic graph. Nodes' `allocator`
/// is the arena allocator, so `overrideImport`'s `getOrPut` uses it.
const TestGraph = struct {
    arena: std.heap.ArenaAllocator,

    fn init(base: std.mem.Allocator) TestGraph {
        return .{ .arena = std.heap.ArenaAllocator.init(base) };
    }
    fn deinit(self: *TestGraph) void {
        self.arena.deinit();
    }
    /// Create a fresh module node.
    fn mod(self: *TestGraph, name: []const u8) *Module {
        const a = self.arena.allocator();
        const m = a.create(Module) catch @panic("OOM");
        m.* = .{ .name = name, .allocator = a };
        return m;
    }
    /// Wire an import edge `from` --(key)--> `to`.
    fn link(_: *TestGraph, from: *Module, key: []const u8, to: *Module) void {
        from.addImport(key, to);
    }
};

/// Assert `m.import_table.get(key)` resolves to `expected`.
fn expectImport(m: *Module, key: []const u8, expected: *Module) !void {
    const got = m.import_table.get(key) orelse {
        std.debug.print("module '{s}' has no import '{s}'\n", .{ m.name, key });
        return error.MissingImport;
    };
    try testing.expectEqual(expected, got);
}

test "isCoreKey / isGfxKey: both spellings, nothing else" {
    try testing.expect(isCoreKey("labelle-core"));
    try testing.expect(isCoreKey("labelle_core"));
    try testing.expect(!isCoreKey("labelle-gfx"));
    try testing.expect(!isCoreKey("core"));

    try testing.expect(isGfxKey("labelle-gfx"));
    try testing.expect(isGfxKey("labelle_gfx"));
    try testing.expect(!isGfxKey("labelle-core"));
    try testing.expect(!isGfxKey("gfx"));
}

// (a) BOTH core key spellings on one module are rewritten onto the single
// core_mod. Covers the hyphen sites (:28/:29/:71/:118/:812) and the
// underscore sites (:85/:108/:141/:162) landing on the same singleton.
test "both core key spellings rewritten to core_mod" {
    var g = TestGraph.init(testing.allocator);
    defer g.deinit();

    const core_mod = g.mod("core_mod");
    const gfx_mod = g.mod("gfx_mod");
    const stale_core_a = g.mod("stale_core_a"); // a distinct pinned core tarball
    const stale_core_b = g.mod("stale_core_b");
    const root = g.mod("input");
    g.link(root, "labelle-core", stale_core_a);
    g.link(root, "labelle_core", stale_core_b);

    var visited: ModuleSet = .empty;
    defer visited.deinit(testing.allocator);
    unifyCoreDiamond(testing.allocator, root, core_mod, gfx_mod, &visited);

    try expectImport(root, "labelle-core", core_mod);
    try expectImport(root, "labelle_core", core_mod);
}

// (b) The engine→gfx edge is rewritten to gfx_mod (NOT recursed through) —
// this is the fixed diamond's third override (:30), whose omission left two
// labelle-gfx instances across the app/engine seam (§5 correction #4).
test "engine→gfx edge rewritten to gfx_mod, core alongside" {
    var g = TestGraph.init(testing.allocator);
    defer g.deinit();

    const core_mod = g.mod("core_mod");
    const gfx_mod = g.mod("gfx_mod");
    const stale_gfx = g.mod("stale_gfx");
    const stale_core = g.mod("stale_core");
    const engine = g.mod("engine");
    g.link(engine, "labelle-core", stale_core);
    g.link(engine, "labelle-gfx", stale_gfx);

    var visited: ModuleSet = .empty;
    defer visited.deinit(testing.allocator);
    unifyCoreDiamond(testing.allocator, engine, core_mod, gfx_mod, &visited);

    try expectImport(engine, "labelle-core", core_mod);
    try expectImport(engine, "labelle-gfx", gfx_mod);
    // The stale gfx instance was OVERRIDDEN, not recursed into: it is not in
    // the visited set (proves the gfx edge is an override branch, not a recurse
    // branch — the §5 note).
    try testing.expect(!visited.contains(stale_gfx));
}

// (c) Recursion reaches core imports nested one level down under a
// non-core/non-gfx key (the transitive `input → sdl_gamepad → labelle_core`
// shape of #271).
test "recursion into nested non-core import unifies transitive core" {
    var g = TestGraph.init(testing.allocator);
    defer g.deinit();

    const core_mod = g.mod("core_mod");
    const gfx_mod = g.mod("gfx_mod");
    const stale_core = g.mod("stale_core");
    const input = g.mod("input");
    const sdl_gamepad = g.mod("sdl_gamepad");
    g.link(input, "sdl_gamepad", sdl_gamepad); // not core/gfx → recurse
    g.link(sdl_gamepad, "labelle_core", stale_core); // underscore, transitive

    var visited: ModuleSet = .empty;
    defer visited.deinit(testing.allocator);
    unifyCoreDiamond(testing.allocator, input, core_mod, gfx_mod, &visited);

    try expectImport(sdl_gamepad, "labelle_core", core_mod);
    try testing.expect(visited.contains(input));
    try testing.expect(visited.contains(sdl_gamepad));
}

// (d) Idempotence — running the walk a SECOND time (fresh visited set) over
// the already-unified graph produces the same result and changes nothing.
test "idempotent: a second run over an already-unified graph is a no-op" {
    var g = TestGraph.init(testing.allocator);
    defer g.deinit();

    const core_mod = g.mod("core_mod");
    const gfx_mod = g.mod("gfx_mod");
    const engine = g.mod("engine");
    const input = g.mod("input");
    const sdl_gamepad = g.mod("sdl_gamepad");
    g.link(engine, "labelle-core", g.mod("stale_core_1"));
    g.link(engine, "labelle-gfx", g.mod("stale_gfx"));
    g.link(engine, "input", input);
    g.link(input, "sdl_gamepad", sdl_gamepad);
    g.link(sdl_gamepad, "labelle_core", g.mod("stale_core_2"));

    var v1: ModuleSet = .empty;
    defer v1.deinit(testing.allocator);
    unifyCoreDiamond(testing.allocator, engine, core_mod, gfx_mod, &v1);

    // Snapshot the resolved edges after the first run.
    const after1_engine_core = engine.import_table.get("labelle-core").?;
    const after1_engine_gfx = engine.import_table.get("labelle-gfx").?;
    const after1_sdl_core = sdl_gamepad.import_table.get("labelle_core").?;

    var v2: ModuleSet = .empty;
    defer v2.deinit(testing.allocator);
    unifyCoreDiamond(testing.allocator, engine, core_mod, gfx_mod, &v2);

    try testing.expectEqual(after1_engine_core, engine.import_table.get("labelle-core").?);
    try testing.expectEqual(after1_engine_gfx, engine.import_table.get("labelle-gfx").?);
    try testing.expectEqual(after1_sdl_core, sdl_gamepad.import_table.get("labelle_core").?);
    // And of course they equal the singletons.
    try expectImport(engine, "labelle-core", core_mod);
    try expectImport(engine, "labelle-gfx", gfx_mod);
    try expectImport(sdl_gamepad, "labelle_core", core_mod);
}

// (e) Absent-import no-op — a graph with no core/gfx imports anywhere is left
// untouched, and a leaf with an EMPTY import_table does not crash. This is the
// guard-free equivalent of the hand-written `if`-guards: nothing to override,
// no dead import injected (#258).
test "absent core/gfx imports: no-op, no dead imports injected" {
    var g = TestGraph.init(testing.allocator);
    defer g.deinit();

    const core_mod = g.mod("core_mod");
    const gfx_mod = g.mod("gfx_mod");
    const audio = g.mod("audio"); // imports nothing core/gfx
    const window = g.mod("window"); // leaf, empty import_table
    g.link(audio, "some_dep", window);

    var visited: ModuleSet = .empty;
    defer visited.deinit(testing.allocator);
    unifyCoreDiamond(testing.allocator, audio, core_mod, gfx_mod, &visited);

    // No core/gfx key was invented anywhere.
    try testing.expect(audio.import_table.get("labelle-core") == null);
    try testing.expect(audio.import_table.get("labelle_core") == null);
    try testing.expect(audio.import_table.get("labelle-gfx") == null);
    try testing.expect(window.import_table.count() == 0);
    // The one real edge is untouched.
    try expectImport(audio, "some_dep", window);
}

// (f) Cycle / visited-set termination — a graph with a back-edge (A→B→A) must
// terminate, and core imports on both nodes still get unified.
test "cyclic import graph terminates and still unifies core" {
    var g = TestGraph.init(testing.allocator);
    defer g.deinit();

    const core_mod = g.mod("core_mod");
    const gfx_mod = g.mod("gfx_mod");
    const a = g.mod("a");
    const b = g.mod("b");
    g.link(a, "b", b);
    g.link(b, "a", a); // back-edge → cycle
    g.link(a, "labelle-core", g.mod("stale_a"));
    g.link(b, "labelle_core", g.mod("stale_b"));

    var visited: ModuleSet = .empty;
    defer visited.deinit(testing.allocator);
    // Termination is the assertion: if the visited set didn't bound recursion
    // this would stack-overflow rather than return.
    unifyCoreDiamond(testing.allocator, a, core_mod, gfx_mod, &visited);

    try expectImport(a, "labelle-core", core_mod);
    try expectImport(b, "labelle_core", core_mod);
    try testing.expect(visited.contains(a));
    try testing.expect(visited.contains(b));
}

// (g) A graph mirroring the REAL backend shape: engine → gfx + core, gfx →
// core + a sub-package (camera) → core, and a backend input → sdl_gamepad →
// core (underscore). The assembler runs the walk rooted at each provider
// (engine, gfx_mod, input) with the two singletons; the whole graph must end
// fully unified. Combines the fixed diamond (:28-30), the gfx sub-package
// unification (:41, gfx#276), and the transitive underscore case (:85/:271).
test "real backend shape fully unifies to the two singletons" {
    var g = TestGraph.init(testing.allocator);
    defer g.deinit();

    const core_mod = g.mod("core_mod");
    const gfx_mod = g.mod("gfx_mod");

    // gfx_mod's own graph: imports core + a `camera` sub-package that also
    // imports core (gfx#276 — the sub-package's core MUST be the singleton).
    const camera = g.mod("camera");
    g.link(gfx_mod, "labelle-core", g.mod("gfx_stale_core"));
    g.link(gfx_mod, "camera", camera);
    g.link(camera, "labelle-core", g.mod("camera_stale_core"));

    // engine imports a stale gfx + stale core.
    const engine = g.mod("engine");
    g.link(engine, "labelle-gfx", g.mod("engine_stale_gfx"));
    g.link(engine, "labelle-core", g.mod("engine_stale_core"));

    // backend `input` reaches core transitively through sdl_gamepad
    // (underscore key), like desktop raylib/sokol/bgfx.
    const input = g.mod("input");
    const sdl_gamepad = g.mod("sdl_gamepad");
    g.link(input, "sdl_gamepad", sdl_gamepad);
    g.link(sdl_gamepad, "labelle_core", g.mod("gp_stale_core"));

    // The assembler runs the walk once per imported provider root, sharing the
    // singletons. A shared visited set across roots is fine (idempotent).
    var visited: ModuleSet = .empty;
    defer visited.deinit(testing.allocator);
    unifyCoreDiamond(testing.allocator, engine, core_mod, gfx_mod, &visited);
    unifyCoreDiamond(testing.allocator, gfx_mod, core_mod, gfx_mod, &visited);
    unifyCoreDiamond(testing.allocator, input, core_mod, gfx_mod, &visited);

    // Fixed diamond.
    try expectImport(engine, "labelle-gfx", gfx_mod);
    try expectImport(engine, "labelle-core", core_mod);
    // gfx + its sub-package (gfx#276).
    try expectImport(gfx_mod, "labelle-core", core_mod);
    try expectImport(camera, "labelle-core", core_mod);
    // Transitive underscore core (#271).
    try expectImport(sdl_gamepad, "labelle_core", core_mod);
}

// The generated build.zig mirror must at least be syntactically valid Zig, so
// PR 3 can splice it without breaking the generated build. Parse-only (the
// helper references `std.Build.Module` + the template's free `overrideImport`,
// so a full AstGen would need that surrounding context).
test "generated_walk_zig parses as valid Zig" {
    const src_z = try testing.allocator.dupeZ(u8, generated_walk_zig);
    defer testing.allocator.free(src_z);
    var ast = try std.zig.Ast.parse(testing.allocator, src_z, .zig);
    defer ast.deinit(testing.allocator);
    if (ast.errors.len != 0) {
        std.debug.print("generated_walk_zig has {d} parse error(s)\n", .{ast.errors.len});
        return error.GeneratedWalkParseError;
    }
    // Sanity: the mirror carries both key spellings for both singletons and
    // the recursion — a cheap drift guard against the pure logic above.
    try testing.expect(std.mem.indexOf(u8, generated_walk_zig, "labelle-core") != null);
    try testing.expect(std.mem.indexOf(u8, generated_walk_zig, "labelle_core") != null);
    try testing.expect(std.mem.indexOf(u8, generated_walk_zig, "labelle-gfx") != null);
    try testing.expect(std.mem.indexOf(u8, generated_walk_zig, "labelle_gfx") != null);
}
