//! Cross-package version FLOORS — the one place the assembler knows which
//! backend/core and core/engine/gfx pairings cannot be shipped together.
//!
//! Two tables live here, moved out of `init_cmd.zig` (#739) so every door
//! that writes or resolves a pin runs the SAME validator instead of
//! growing a second copy:
//!
//!   * `bgfx_core_floors`  — what the resolved bgfx provider requires of
//!     `.core_version` (#731/#736).
//!   * `trio_floors`       — core ⇄ engine ⇄ gfx coherence (#733).
//!
//! The doors, all through `enforce` / the `*Violation` functions below:
//!
//!   * `init`              — refuses a bad `--backend`/`--core-version`/
//!     `--engine-version`/`--gfx-version` before a file is written.
//!   * `generate` / `check`— the only place the RESOLVED backend package
//!     (an explicit `.backend_package`, or the builtin provider the
//!     `.backend` tag is shorthand for) and `.core_version` are both in
//!     hand; `init` has no `--backend-package` flag, so an explicit
//!     package is reachable ONLY here (#739).
//!   * `upgrade`           — validates the PROSPECTIVE pins before the
//!     rewrite lands, so a bump cannot move `.core_version` below the
//!     floor of the backend the project already pins (#739).
//!
//! Severity split (#736): a `compile_break` refuses — the pairing cannot
//! build at all, and the alternative is a `@compileError` deep inside a
//! dependency; a `curated` floor warns and proceeds — it builds, it is
//! just not the pairing the backend was released against.

const std = @import("std");
const config = @import("config.zig");

/// The pin comparison lives in `config` (PR #733) so the generate-time
/// materials contract gate shares it; the guards below keep the short name.
const pinAtLeast = config.pinAtLeast;

// ── backend ⇄ core floor validation ──────────────────────────────────
//
// PRODUCTION check, not a test helper (#736 review): `checkTrioFloors`
// below guards the DEFAULTS `build.zig` bakes in, but `init` also takes
// `--backend=` and `--core-version=` from the user, and nothing stopped
// `labelle init --backend=bgfx --core-version=1.26.0` from writing a
// project that dies inside the backend at the first `labelle build` — the
// exact standalone failure #731 shipped in its examples, reachable through
// the front door. The table is the ONE place the bgfx floors live; the
// test helper further down exercises this same code, so the two cannot
// drift.

pub const FloorSeverity = enum {
    /// An older core fails to COMPILE inside the backend.
    compile_break,
    /// The pairing builds, but is not the one the backend was released
    /// against — the scaffold default never picks it, an explicit
    /// `--core-version` gets a warning.
    curated,
};

/// One floor the builtin bgfx provider puts on the project's core.
const BackendCoreFloor = struct {
    backend_at_least: []const u8,
    core_at_least: []const u8,
    severity: FloorSeverity,
    /// Why, in the words the diagnostic prints.
    why: []const u8,
};

/// Strictest first. `providerCoreFloorViolation` reports the hard floor
/// when one is violated (that is the actionable one), else the strictest
/// curated floor; either way the diagnostic recommends the strictest core.
///
/// bgfx >= 0.15.0 floors core >= 1.28.0 — a COMPILE break: the backend's
/// `src/gfx/types.zig` types a struct field as `core.BackendTextureId`
/// (core#328 phase 3), which is analyzed eagerly, so an older core dies
/// inside the backend with "root source file struct 'root' has no member
/// named 'BackendTextureId'". That is exactly how #731's examples (core
/// 1.26.0 + bgfx 0.20.0) failed a standalone `labelle build`.
///
/// bgfx >= 0.20.0 floors core >= 1.32.0 — a CURATED floor, like the gfx
/// 1.28 one in `checkTrioFloors`: 0.20.0 does compile against core 1.28.0
/// (its v1.32.0 `PixelWaterDraw` / `PIXEL_WATER_*` names are reached only
/// through `@hasField(MaterialEffect, "pixel_water")`-gated paths or lazy
/// top-level aliases — verified standalone), but 1.32.0 is the core it was
/// released against (its build.zig.zon) and the only core on which the
/// pixel_water effect the default backend ships is reachable. The scaffold
/// pairs the default backend with the core it was released against, not
/// merely one it happens to compile on.
///
/// bgfx >= 0.21.0 floors core >= 2.0.0 — a COMPILE break (PR #733): the
/// first contract-v2 backend dropped the PixelWater contract and names
/// core's `shader_material` contract with no `@hasDecl` probe, and asserts
/// `MATERIAL_CONTRACT_VERSION == 2`; core 2.0.0 is the release that
/// declares both. The scaffold trio (core 2.0.0 / gfx 2.0.0 / engine
/// 3.0.0) and this default moved together for that reason.
const bgfx_core_floors = [_]BackendCoreFloor{
    .{
        .backend_at_least = "0.21.0",
        .core_at_least = "2.0.0",
        .severity = .compile_break,
        .why = "the backend names core's `shader_material` contract ungated and asserts material contract v2, which only core >= 2.0.0 declares — it fails to compile",
    },
    .{
        .backend_at_least = "0.20.0",
        .core_at_least = "1.32.0",
        .severity = .curated,
        .why = "its pixel_water effect is unreachable on an older core",
    },
    .{
        .backend_at_least = "0.15.0",
        .core_at_least = "1.28.0",
        .severity = .compile_break,
        .why = "the backend types a struct field as `core.BackendTextureId`, which an older core lacks — it fails to compile",
    },
};

/// A backend/core pairing that violates a floor, with everything the
/// user-facing diagnostic names.
pub const FloorViolation = struct {
    backend: []const u8,
    backend_version: []const u8,
    core_version: []const u8,
    core_floor: []const u8,
    /// The strictest floor for this backend — what to pass instead.
    recommended_core: []const u8,
    severity: FloorSeverity,
    why: []const u8,

    /// The diagnostic, rendered into `buf`. Names the backend and its real
    /// provider version, the floor violated, the core requested, why, and
    /// the core to pass instead.
    pub fn describe(self: FloorViolation, buf: []u8) []const u8 {
        // "requires" only when it is a compile break; a curated floor that
        // still builds says what it is, so the warning does not contradict
        // the scaffold that follows it.
        const verb: []const u8 = switch (self.severity) {
            .compile_break => "requires",
            .curated => "is released against",
        };
        return std.fmt.bufPrint(
            buf,
            "{s} {s} {s} labelle-core >= {s}; got {s} ({s}). Pass --core-version={s}, the core it was released against.",
            .{ self.backend, self.backend_version, verb, self.core_floor, self.core_version, self.why, self.recommended_core },
        ) catch "backend/core version floor violated (diagnostic too long to render)";
    }
};

/// The floor the BUILTIN provider for `backend_name` puts on `core_version`,
/// or null when the pairing is fine. Reads the real `builtinProvider`
/// default, so a provider bump moves the check with it. A backend name the
/// enum does not know, a backend with no versioned provider, and a core pin
/// that is not a release version (`local:…`, resolved elsewhere) are all
/// "fine" here — they are other checks' business.
pub fn backendCoreFloorViolation(backend_name: []const u8, core_version: []const u8) error{UnparsableVersionPin}!?FloorViolation {
    const backend = std.meta.stringToEnum(config.Backend, backend_name) orelse return null;
    const provider = config.ProjectConfig.builtinProvider(backend) orelse return null;
    return providerCoreFloorViolation(backend, provider.version, core_version);
}

/// `backendCoreFloorViolation` with the provider version supplied — the
/// seam the table tests use, so the floors are exercised by exactly the
/// code `init` runs.
fn providerCoreFloorViolation(backend: config.Backend, backend_version: []const u8, core_version: []const u8) error{UnparsableVersionPin}!?FloorViolation {
    const floors: []const BackendCoreFloor = switch (backend) {
        .bgfx => &bgfx_core_floors,
        else => return null,
    };
    if (!config.isSemverVersion(core_version)) return null;

    var worst: ?FloorViolation = null;
    for (floors) |f| {
        if (!try pinAtLeast(backend_version, f.backend_at_least)) continue;
        if (try pinAtLeast(core_version, f.core_at_least)) continue;
        const v: FloorViolation = .{
            .backend = @tagName(backend),
            .backend_version = backend_version,
            .core_version = core_version,
            .core_floor = f.core_at_least,
            .recommended_core = floors[0].core_at_least,
            .severity = f.severity,
            .why = f.why,
        };
        // A compile break beats a curated floor; among equals, keep the
        // strictest (first).
        if (worst == null or (v.severity == .compile_break and worst.?.severity != .compile_break)) worst = v;
    }
    return worst;
}

// ── core ⇄ engine ⇄ gfx trio floor validation ─────────────────────────
//
// PRODUCTION check (#733 review, round 3 — the same shape #736's Major had):
// the trio floors used to live only in a test helper, so
// `labelle-assembler init game --engine-version=2.12.2` combined that explicit
// pin with the core/gfx 2.0.0 defaults, passed the backend/core-only validator
// above, and wrote the exact combination the test declared incompatible. The
// table below is the ONE place the trio floors live; `checkTrioFloors` (the
// test helper) wraps this same function. Scope: `init` only — generate/upgrade
// is labelle-assembler#739's.

const TrioPackage = enum {
    core,
    engine,
    gfx,

    fn label(self: TrioPackage) []const u8 {
        return switch (self) {
            .core => "labelle-core",
            .engine => "labelle-engine",
            .gfx => "labelle-gfx",
        };
    }
    fn flag(self: TrioPackage) []const u8 {
        return switch (self) {
            .core => "--core-version",
            .engine => "--engine-version",
            .gfx => "--gfx-version",
        };
    }
    fn curatedDefault(self: TrioPackage) []const u8 {
        return switch (self) {
            .core => config.CORE_VERSION,
            .engine => config.ENGINE_VERSION,
            .gfx => config.GFX_VERSION,
        };
    }
};

/// One floor: `subject >= subject_at_least` puts `requires >= floor` on the
/// project.
const TrioFloor = struct {
    subject: TrioPackage,
    subject_at_least: []const u8,
    requires: TrioPackage,
    floor: []const u8,
    severity: FloorSeverity,
    /// Why, in the words the diagnostic prints.
    why: []const u8,
};

/// Strictest (newest line) first, so the reported violation is the
/// actionable one. The 2.0.0 line (PR #733, game-owned shader materials):
/// gfx 2.0.0 dispatches generic material draws through core 2.0.0's
/// `shader_material` contract (its build.zig.zon pins core 2.0.0), and
/// engine 3.0.0's entity material API is built on gfx 2.0.0 (its
/// build.zig.zon pins gfx 2.0.0). The 1.x core carried the specialized
/// PixelWater contract these replaced, and engine <= 2.12.x still compiles
/// its PixelWater simulation against it — so nothing below the 2.0.0 line
/// mixes with anything on it, in either direction.
///
/// #679: gfx >= 1.30.0 re-exports `core.TextureId` rather than declaring its
/// own (labelle-gfx#328). That type landed in core 1.28.0, and the assembler
/// unifies every package onto the project's `core_version` — so gfx 1.30.x
/// against core < 1.28.0 dies inside the dependency with "root source file
/// struct 'root' has no member named 'TextureId'". Engine >= 2.12.1 is the
/// matching half (`game.nativeTextureId` compiles against the typed gfx
/// surface, labelle-engine#813 phase 4) — CURATED, the engine takes no
/// direct gfx dependency.
///
/// engine >= 2.11.0 floors core >= 1.27.0: core's `ChildrenComponent` went
/// ArrayList-backed and `addChild` takes an allocator (labelle-core#65/#66),
/// and the engine takes a REAL module dependency on core — an older core
/// fails to compile.
///
/// engine >= 2.11.0 also floors gfx >= 1.28.0, but that one is a CURATED
/// floor, not a compile break: the engine module takes no direct gfx
/// dependency (the renderer arrives via `RenderImpl`), and its post-fx
/// passthrough is `@hasDecl`-gated — labelle-engine `src/game/post_fx_mixin.zig`
/// says in so many words that "an older gfx (< v1.28.0) … compiles to a
/// no-op". So the pairing BUILDS; it just silently drops the post-fx stack
/// the engine advertises. A curated set is what `labelle init` stamps and
/// `upgrade all` writes, so it must be the coherent set, not merely one
/// that compiles — hence the assertion, with the distinction recorded here
/// so nobody later "fixes" a legitimate compile failure by relaxing it.
const trio_floors = [_]TrioFloor{
    .{ .subject = .gfx, .subject_at_least = "2.0.0", .requires = .core, .floor = "2.0.0", .severity = .compile_break, .why = "gfx 2.x dispatches material draws through core's `shader_material` contract, which only core >= 2.0.0 declares" },
    .{ .subject = .gfx, .subject_at_least = "2.0.0", .requires = .engine, .floor = "3.0.0", .severity = .compile_break, .why = "an engine below 3.0.0 still compiles the PixelWater simulation the 2.0.0 line removed from core and gfx" },
    .{ .subject = .engine, .subject_at_least = "3.0.0", .requires = .core, .floor = "2.0.0", .severity = .compile_break, .why = "engine 3.x's entity material API is built on core 2.0.0's `shader_material` contract" },
    .{ .subject = .engine, .subject_at_least = "3.0.0", .requires = .gfx, .floor = "2.0.0", .severity = .compile_break, .why = "engine 3.x is built against gfx 2.0.0's generic material draw (its build.zig.zon pins it)" },
    // The REVERSE direction of the same 2.0.0 line (#742): the four rules
    // above trigger only on a NEW gfx or engine, so a project that pins the
    // new CORE against the old engine/gfx — `init --engine-version=2.12.2
    // --gfx-version=1.30.1` over the default core 2.0.0, the pairing that
    // needs BOTH explicit overrides to reach — passed every rule and got
    // scaffolded. Same facts, stated from core's side: engine <= 2.12.x
    // still compiles the PixelWater simulation core 2.0.0 removed, and gfx
    // <= 1.x dispatches through that removed contract. Ordered AFTER the
    // gfx/engine-subject rules so an old core under a NEW gfx keeps naming
    // gfx as the subject (the pin the user just moved).
    .{ .subject = .core, .subject_at_least = "2.0.0", .requires = .engine, .floor = "3.0.0", .severity = .compile_break, .why = "core 2.0.0 removed the PixelWater contract an engine below 3.0.0 still compiles against" },
    .{ .subject = .core, .subject_at_least = "2.0.0", .requires = .gfx, .floor = "2.0.0", .severity = .compile_break, .why = "core 2.0.0 replaced the specialized PixelWater contract with `shader_material`, which only gfx >= 2.0.0 dispatches through" },
    .{ .subject = .gfx, .subject_at_least = "1.30.0", .requires = .core, .floor = "1.28.0", .severity = .compile_break, .why = "gfx >= 1.30.0 re-exports `core.TextureId`, which landed in core 1.28.0 — an older core fails to compile" },
    .{ .subject = .gfx, .subject_at_least = "1.30.0", .requires = .engine, .floor = "2.12.1", .severity = .curated, .why = "engine 2.12.1 is the half released against gfx's typed TextureId surface" },
    .{ .subject = .engine, .subject_at_least = "2.11.0", .requires = .core, .floor = "1.27.0", .severity = .compile_break, .why = "engine >= 2.11.0 takes core's allocator-taking `ChildrenComponent` — an older core fails to compile" },
    .{ .subject = .engine, .subject_at_least = "2.11.0", .requires = .gfx, .floor = "1.28.0", .severity = .curated, .why = "the engine's post-fx passthrough compiles to a no-op on an older gfx, silently dropping the post-fx stack" },
};

/// A trio pin set that violates a floor, with everything the diagnostic names.
pub const TrioViolation = struct {
    core_version: []const u8,
    engine_version: []const u8,
    gfx_version: []const u8,
    floor: TrioFloor,

    fn pinOf(self: TrioViolation, pkg: TrioPackage) []const u8 {
        return switch (pkg) {
            .core => self.core_version,
            .engine => self.engine_version,
            .gfx => self.gfx_version,
        };
    }

    /// What to pass instead: the curated default of the required package
    /// when it satisfies the floor (it always does for the shipped table),
    /// else the floor itself.
    pub fn recommended(self: TrioViolation) []const u8 {
        const def = self.floor.requires.curatedDefault();
        const ok = config.isSemverVersion(def) and (config.pinAtLeast(def, self.floor.floor) catch false);
        return if (ok) def else self.floor.floor;
    }

    pub fn severity(self: TrioViolation) FloorSeverity {
        return self.floor.severity;
    }

    /// The diagnostic, rendered into `buf`: names the subject pin, the
    /// required package and floor, all three pins as given, why, and the
    /// flag to pass.
    pub fn describe(self: TrioViolation, buf: []u8) []const u8 {
        const verb: []const u8 = switch (self.floor.severity) {
            .compile_break => "requires",
            .curated => "is released against",
        };
        return std.fmt.bufPrint(
            buf,
            "{s} {s} {s} {s} >= {s}; got core {s} / engine {s} / gfx {s} ({s}). Pass {s}={s} (the curated set is core {s} / engine {s} / gfx {s}).",
            .{
                self.floor.subject.label(),  self.pinOf(self.floor.subject), verb,
                self.floor.requires.label(), self.floor.floor,               self.core_version,
                self.engine_version,         self.gfx_version,               self.floor.why,
                self.floor.requires.flag(),  self.recommended(),             config.CORE_VERSION,
                config.ENGINE_VERSION,       config.GFX_VERSION,
            },
        ) catch "core/engine/gfx version floor violated (diagnostic too long to render)";
    }
};

/// The floor the three pins violate, or null when the trio is coherent. A
/// compile break beats a curated floor; among equals the first (strictest)
/// wins.
///
/// A pin that is not a release version (`local:…`, a branch name) is
/// resolved elsewhere and cannot be compared, so the rules that READ it are
/// skipped — but ONLY those (#746 review). A blanket early return on any
/// unparseable pin suppressed every rule in the table, including rules whose
/// subject and requirement are both known releases: `core_version =
/// "local:../core"` with engine 3.0.0 / gfx 1.30.1 sailed through `generate`,
/// `check` and `upgrade` even though the table independently states that
/// engine 3.x requires gfx >= 2.0.0, a pairing that cannot compile whatever
/// the local core turns out to be. Each rule reads exactly two pins — its
/// subject and its requirement — so decidability is per rule, not per trio.
pub fn trioFloorViolation(core_version: []const u8, engine_version: []const u8, gfx_version: []const u8) error{UnparsableVersionPin}!?TrioViolation {
    var worst: ?TrioViolation = null;
    for (trio_floors) |f| {
        const v: TrioViolation = .{ .core_version = core_version, .engine_version = engine_version, .gfx_version = gfx_version, .floor = f };
        // This rule's own two pins. A rule is decidable iff BOTH are
        // release-shaped; the third pin is only ever quoted in the
        // diagnostic and never compared.
        if (!config.isSemverVersion(v.pinOf(f.subject))) continue;
        if (!config.isSemverVersion(v.pinOf(f.requires))) continue;
        if (!try pinAtLeast(v.pinOf(f.subject), f.subject_at_least)) continue;
        if (try pinAtLeast(v.pinOf(f.requires), f.floor)) continue;
        if (worst == null or (f.severity == .compile_break and worst.?.floor.severity != .compile_break)) worst = v;
    }
    return worst;
}

test "a non-release pin suppresses only the rules that READ it — #746 review" {
    // engine 3.x requires gfx >= 2.0.0. That rule's subject (engine) and
    // requirement (gfx) are both known releases, so a `local:` CORE — a pin
    // neither side of the rule reads — must not hide it.
    const local_core = (try trioFloorViolation("local:../labelle-core", "3.0.0", "1.30.1")) orelse
        return error.TestUnexpectedResult;
    // Assert WHICH rule fired, not merely that something did: the value
    // alone would also appear if some unrelated rule had matched.
    try std.testing.expectEqual(TrioPackage.engine, local_core.floor.subject);
    try std.testing.expectEqual(TrioPackage.gfx, local_core.floor.requires);
    try std.testing.expectEqual(FloorSeverity.compile_break, local_core.severity());
    // The unparseable pin is still quoted verbatim in the diagnostic.
    var buf: [1024]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, local_core.describe(&buf), "local:../labelle-core") != null);

    // Symmetrically, a `local:` GFX leaves the core-2.x/engine-3.x rule
    // decidable.
    const local_gfx = (try trioFloorViolation("2.0.0", "2.12.2", "local:../labelle-gfx")) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(TrioPackage.core, local_gfx.floor.subject);
    try std.testing.expectEqual(TrioPackage.engine, local_gfx.floor.requires);

    // A rule is skipped when it is genuinely undecidable: with BOTH the
    // subject and the requirement of every applicable rule unparseable there
    // is nothing to judge.
    try std.testing.expect((try trioFloorViolation("local:../c", "local:../e", "local:../g")) == null);
    // ...and a `local:` pin must not INVENT a violation where the decidable
    // rules are all satisfied.
    try std.testing.expect((try trioFloorViolation("local:../labelle-core", "3.0.0", "2.0.0")) == null);
    try std.testing.expect((try trioFloorViolation("2.0.0", "3.0.0", "local:../labelle-gfx")) == null);
}

test "the 2.x core line floors an OLD engine/gfx pinned under it — #742" {
    var buf: [1024]u8 = undefined;
    // The exact command that survived the front-door proof: BOTH overrides
    // explicit, the core left at its 2.0.0 default. Every pre-#742 rule
    // keyed off a NEW gfx or engine, so this scaffolded clean.
    const v = (try trioFloorViolation(config.CORE_VERSION, "2.12.2", "1.30.1")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(FloorSeverity.compile_break, v.severity());
    try std.testing.expectEqual(TrioPackage.core, v.floor.subject);
    try std.testing.expectEqual(TrioPackage.engine, v.floor.requires);
    const msg = v.describe(&buf);
    // Names all three pins, the floor, and the flag to pass. The flag VALUE
    // is `recommended()` — the curated default, which moves with releases —
    // so it is asserted from `config.*_VERSION`, not a literal; the FLOOR
    // is the literal `>= 3.0.0` above.
    try std.testing.expect(std.mem.startsWith(u8, msg, "labelle-core 2.0.0 requires labelle-engine >= 3.0.0; got core 2.0.0 / engine 2.12.2 / gfx 1.30.1 ("));
    try std.testing.expect(std.mem.indexOf(u8, msg, "PixelWater") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Pass --engine-version=" ++ config.ENGINE_VERSION) != null);

    // The gfx half of the same reverse direction, reported when the engine
    // is already on the 3.x line.
    const g = (try trioFloorViolation("2.0.0", "3.0.0", "1.30.1")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(FloorSeverity.compile_break, g.severity());
    try std.testing.expect(std.mem.indexOf(u8, g.describe(&buf), "Pass --gfx-version=" ++ config.GFX_VERSION) != null);
    // ...and with BOTH old, core is still the subject and the engine floor
    // is named first (the table order the older rules rely on).
    const both = (try trioFloorViolation("2.0.0", "2.6.0", "1.28.1")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(TrioPackage.core, both.floor.subject);

    // Mechanism check: an OLD core under a NEW gfx still names GFX as the
    // subject — the new rules must not steal the diagnostic from the rule
    // that describes the pin the user moved.
    const old_core = (try trioFloorViolation("1.32.0", "3.0.0", "2.0.0")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(TrioPackage.gfx, old_core.floor.subject);

    // Still accepted: the curated 2.0.0 set, and every coherent 1.x set —
    // the new rules key off core >= 2.0.0 and must not touch the 1.x line.
    try std.testing.expect((try trioFloorViolation("2.0.0", "3.0.0", "2.0.0")) == null);
    try std.testing.expect((try trioFloorViolation("1.32.0", "2.12.2", "1.30.1")) == null);
    try std.testing.expect((try trioFloorViolation("1.24.0", "2.7.0", "1.27.0")) == null);
    // A non-release CORE pin leaves the rules whose subject is core
    // unjudged — but no longer the whole table (#746 review): engine 2.12.2
    // / gfx 1.30.1 is a coherent 1.x-era pair, so nothing else fires here
    // and the result is still null, for the RIGHT reason.
    try std.testing.expect((try trioFloorViolation("local:../labelle-core", "2.12.2", "1.30.1")) == null);
    // The same local core with an engine/gfx pair the table DOES reject is
    // now caught; see the dedicated test below.
}

// ── the resolved-config gate (#739): generate / check / upgrade ──────
//
// `init` validates the FLAGS. Everything below validates a CONFIG — the
// same two tables, applied where the pins are already written down.

/// Which OFFICIAL backend `bp` is, identified from the RESOLVED PACKAGE
/// alone — or null for a third-party provider.
///
/// Deliberately does NOT consult `cfg.backend` (#746 review, P1). When a
/// project selects a backend purely through `.backend_package`, the
/// `.backend` enum is IGNORED and sits at its meaningless `.raylib` default
/// (see `ProjectConfig.isEnumTagBacked`). Asking "is this package the
/// official provider for `cfg.backend`?" therefore compared an explicit
/// bgfx package against the raylib remote, answered "not official", and
/// silently dropped the bgfx/core floor for exactly the configs that most
/// need it: `.backend_package = .{ .repo = "github.com/labelle-toolkit/
/// labelle-bgfx", .version = "0.21.0" }` with `core_version = "1.32.0"`
/// sailed through `generate`, `check` and `upgrade` and then failed to
/// compile inside the backend.
///
/// The floors are facts about the official release train only: a
/// third-party bgfx-shaped provider carries its own semver, so comparing
/// e.g. acme/bgfx 0.1.0 against 0.21.0 would reject a perfectly good
/// provider as an obsolete labelle-bgfx (same reasoning as
/// `material_pipeline`'s `isOfficialBgfx`). Compared through
/// `config.sameRemote`, so every spelling of the official remote the fetch
/// path accepts is judged (#742).
pub fn officialBackendOf(bp: config.PluginDep) ?config.Backend {
    for (std.enums.values(config.Backend)) |b| {
        const official = config.ProjectConfig.builtinProvider(b) orelse continue;
        if (config.sameRemote(bp.repo, official.repo)) return b;
    }
    return null;
}

/// Is `bp` an official provider package at all?
pub fn isOfficialProvider(bp: config.PluginDep) bool {
    return officialBackendOf(bp) != null;
}

/// The backend/core floor the project's RESOLVED backend package puts on
/// its `.core_version`, or null when the pairing is fine.
///
/// This is the seam `init` cannot reach: `effectiveBackendPackage()` is an
/// explicit `.backend_package` when there is one, else the builtin provider
/// the `.backend` enum tag is shorthand for — and `init` has no
/// `--backend-package` flag, so an explicit package is only ever seen here
/// (#739). A non-official provider and a non-release pin are left alone.
///
/// The floor TABLE is chosen by the backend the PACKAGE identifies, never
/// by `cfg.backend` — see `officialBackendOf`.
pub fn configBackendCoreFloorViolation(cfg: config.ProjectConfig) error{UnparsableVersionPin}!?FloorViolation {
    const bp = cfg.effectiveBackendPackage() orelse return null;
    const backend = officialBackendOf(bp) orelse return null;
    if (!config.isSemverVersion(bp.version)) return null;
    return providerCoreFloorViolation(backend, bp.version, cfg.core_version);
}

test "an explicit bgfx `.backend_package` is floored even though `.backend` is the ignored default — #746 review" {
    // The config `ProjectConfig` documents as ignoring `.backend`: the
    // provider is named ONLY by `.backend_package`, so `.backend` sits at
    // its `.raylib` default and means nothing.
    const cfg: config.ProjectConfig = .{
        .name = "p",
        .backend = .raylib, // ignored — the package selects the backend
        .backend_package = .{ .name = "bgfx", .repo = "github.com/labelle-toolkit/labelle-bgfx", .version = "0.21.0" },
        .core_version = "1.32.0",
        .engine_version = config.ENGINE_VERSION,
        .gfx_version = config.GFX_VERSION,
    };

    // Assert the MECHANISM, not just the value: the package must identify
    // BGFX, not the `.raylib` tag beside it.
    try std.testing.expectEqual(config.Backend.bgfx, officialBackendOf(cfg.backend_package.?).?);

    // 0.21.0 hard-floors core >= 2.0.0, so this pairing must be refused.
    const v = (try configBackendCoreFloorViolation(cfg)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(FloorSeverity.compile_break, v.severity);
    try std.testing.expectEqualStrings("bgfx", v.backend);
    try std.testing.expectEqualStrings("0.21.0", v.backend_version);

    // The old code path: `isOfficialProvider(cfg.backend, bp)` compared the
    // bgfx package against the RAYLIB remote and returned false, so the
    // floor was skipped entirely. Pin that the two remotes really do differ,
    // so this test cannot pass for the wrong reason.
    const raylib_official = config.ProjectConfig.builtinProvider(.raylib).?;
    try std.testing.expect(!config.sameRemote(cfg.backend_package.?.repo, raylib_official.repo));

    // A genuine third-party provider is still left alone, whatever its pin.
    const third_party: config.ProjectConfig = .{
        .name = "p",
        .backend = .bgfx,
        .backend_package = .{ .name = "acme_bgfx", .repo = "github.com/acme/bgfx", .version = "0.1.0" },
        .core_version = "1.32.0",
        .engine_version = config.ENGINE_VERSION,
        .gfx_version = config.GFX_VERSION,
    };
    try std.testing.expect(officialBackendOf(third_party.backend_package.?) == null);
    try std.testing.expect((try configBackendCoreFloorViolation(third_party)) == null);
}

pub const EnforceError = error{ VersionFloorViolation, UnparsableVersionPin };

/// What the two tables say about a config, with no side effects: the
/// violations found (if any) and whether the project must be REFUSED.
///
/// Split out from `enforce` so the policy is testable without emitting
/// `std.log.err` — and so a test asserts WHICH path ran (backend table vs
/// trio table, refuse vs warn), not merely that something happened.
pub const Verdict = struct {
    backend: ?FloorViolation = null,
    trio: ?TrioViolation = null,

    /// A compile break on either table: the pairing cannot build.
    pub fn refused(self: Verdict) bool {
        if (self.backend) |v| if (v.severity == .compile_break) return true;
        if (self.trio) |v| if (v.severity() == .compile_break) return true;
        return false;
    }

    /// A curated floor tripped with no compile break: it builds, but it is
    /// not the pairing the backend/trio was released as.
    pub fn warned(self: Verdict) bool {
        return !self.refused() and (self.backend != null or self.trio != null);
    }
};

/// Run BOTH tables over a config.
pub fn verdict(cfg: config.ProjectConfig) error{UnparsableVersionPin}!Verdict {
    return .{
        .backend = try configBackendCoreFloorViolation(cfg),
        .trio = try trioFloorViolation(cfg.core_version, cfg.engine_version, cfg.gfx_version),
    };
}

/// `verdict` plus the #736 severity policy: a compile break is refused with
/// `error.VersionFloorViolation`, a curated floor logs a warning and
/// proceeds. `ctx` prefixes the diagnostic with the command that is
/// speaking (`"labelle-assembler generate"`).
///
/// Used by `generate`, `check` and `upgrade`. `upgrade` calls it on the
/// PROSPECTIVE config — the pins as they would be written — so the refusal
/// happens before `project.labelle` is rewritten, not after.
pub fn enforce(cfg: config.ProjectConfig, ctx: []const u8) EnforceError!void {
    const v = try verdict(cfg);
    // Both diagnostics are printed before refusing: a hand-edited project
    // that broke both pairings should learn both in one run.
    if (v.backend) |b| {
        var buf: [512]u8 = undefined;
        switch (b.severity) {
            .compile_break => std.log.err("{s}: {s}", .{ ctx, b.describe(&buf) }),
            .curated => std.log.warn("{s}: {s}", .{ ctx, b.describe(&buf) }),
        }
    }
    if (v.trio) |t| {
        var buf: [1024]u8 = undefined;
        switch (t.severity()) {
            .compile_break => std.log.err("{s}: {s}", .{ ctx, t.describe(&buf) }),
            .curated => std.log.warn("{s}: {s}", .{ ctx, t.describe(&buf) }),
        }
    }
    if (v.refused()) return error.VersionFloorViolation;
}

test "the resolved-config gate judges an explicit .backend_package init can never see — #739" {
    const base: config.ProjectConfig = .{
        .name = "g",
        .backend = .bgfx,
        .core_version = "2.0.0",
        .engine_version = "3.0.0",
        .gfx_version = "2.0.0",
    };

    // The BUILTIN provider (no `.backend_package`): the enum-as-shorthand
    // default is the official train, so a hand-edited `.core_version` below
    // its hard floor is refused with the same diagnostic `init` gives.
    var builtin_old_core = base;
    builtin_old_core.core_version = "1.32.0";
    builtin_old_core.engine_version = "2.12.2";
    builtin_old_core.gfx_version = "1.30.1";
    const v = (try configBackendCoreFloorViolation(builtin_old_core)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(FloorSeverity.compile_break, v.severity);
    try std.testing.expectEqualStrings("2.0.0", v.core_floor);
    try std.testing.expect((try verdict(builtin_old_core)).refused());
    // ...and the trio ITSELF is coherent there, so the refusal comes from
    // the backend table, not the trio one (assert which path ran).
    try std.testing.expect((try trioFloorViolation(builtin_old_core.core_version, builtin_old_core.engine_version, builtin_old_core.gfx_version)) == null);

    // An EXPLICIT `.backend_package` — unreachable from `init`, which has no
    // `--backend-package` flag — is judged too, in every spelling of the
    // official remote (#742).
    inline for (.{
        "github.com/labelle-toolkit/labelle-bgfx",
        "https://github.com/labelle-toolkit/labelle-bgfx.git",
    }) |spelling| {
        var explicit = base;
        explicit.backend_package = .{ .name = "bgfx", .repo = spelling, .version = "0.20.0" };
        explicit.core_version = "1.26.0"; // below bgfx 0.15.0's HARD floor
        explicit.engine_version = "2.6.0";
        explicit.gfx_version = "1.28.1";
        const e = (try configBackendCoreFloorViolation(explicit)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(FloorSeverity.compile_break, e.severity);
        try std.testing.expectEqualStrings("1.28.0", e.core_floor);
        try std.testing.expect((try verdict(explicit)).refused());
    }

    // A CURATED floor warns and PASSES: bgfx 0.20.0 on core 1.28.0 builds.
    var curated = base;
    curated.backend_package = .{ .name = "bgfx", .repo = "github.com/labelle-toolkit/labelle-bgfx", .version = "0.20.0" };
    curated.core_version = "1.28.0";
    curated.engine_version = "2.12.2";
    curated.gfx_version = "1.30.1";
    const c = (try configBackendCoreFloorViolation(curated)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(FloorSeverity.curated, c.severity);
    // Curated = WARN, not refuse: the project still generates.
    try std.testing.expect(!(try verdict(curated)).refused());
    try std.testing.expect((try verdict(curated)).warned());

    // Not this validator's business: a CUSTOM provider (its own semver), a
    // `local:` checkout, a backend with no floors, and a non-release core.
    var custom = base;
    custom.backend_package = .{ .name = "bgfx", .repo = "github.com/acme/bgfx-provider", .version = "0.1.0" };
    try std.testing.expect((try configBackendCoreFloorViolation(custom)) == null);
    var local = base;
    local.backend_package = .{ .name = "bgfx", .repo = "local:../labelle-bgfx", .version = "0.1.0" };
    try std.testing.expect((try configBackendCoreFloorViolation(local)) == null);
    var raylib = base;
    raylib.backend = .raylib;
    raylib.core_version = "1.26.0";
    raylib.engine_version = "2.6.0";
    raylib.gfx_version = "1.28.1";
    try std.testing.expect((try configBackendCoreFloorViolation(raylib)) == null);
    try std.testing.expect(!(try verdict(raylib)).refused());
    var local_core = base;
    local_core.core_version = "local:../labelle-core";
    try std.testing.expect((try configBackendCoreFloorViolation(local_core)) == null);

    // The curated defaults — what every fresh scaffold and every
    // `upgrade all` writes — pass the gate clean (no warning either), and
    // `enforce` (the logging wrapper the commands call) returns.
    try std.testing.expect(!(try verdict(base)).refused());
    try std.testing.expect(!(try verdict(base)).warned());
    try enforce(base, "t");
    try enforce(.{ .name = "g" }, "t");
    try std.testing.expect(!(try verdict(.{ .name = "g" })).warned());
}

test "the resolved-config gate refuses an incoherent TRIO on a floorless backend — #739" {
    // The trio half is backend-independent: a `.backend = .null` project
    // (or raylib, or a `local:` backend) still cannot mix the 2.0.0 line
    // with the 1.x line.
    const cfg: config.ProjectConfig = .{
        .name = "g",
        .backend = .null,
        .core_version = "2.0.0",
        .engine_version = "2.12.2",
        .gfx_version = "1.30.1",
    };
    // Assert WHICH table refused: the backend one has nothing to say here.
    try std.testing.expect((try configBackendCoreFloorViolation(cfg)) == null);
    const v = try verdict(cfg);
    try std.testing.expect(v.backend == null);
    try std.testing.expect(v.trio != null);
    try std.testing.expect(v.refused());
}

test "init refuses --engine-version=2.12.2 under the 2.0.0 core/gfx defaults with a named diagnostic; defaults pass — #733 review round 3" {
    var buf: [1024]u8 = undefined;
    // The front-door failure: the explicit engine pin against the curated
    // core/gfx defaults trips a COMPILE-BREAK floor (refused, not warned),
    // and the diagnostic names all three pins, the floor, and the flag.
    const v = (try trioFloorViolation(config.CORE_VERSION, "2.12.2", config.GFX_VERSION)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(FloorSeverity.compile_break, v.severity());
    try std.testing.expectEqual(TrioPackage.engine, v.floor.requires);
    try std.testing.expectEqualStrings("3.0.0", v.floor.floor);
    const msg = v.describe(&buf);
    try std.testing.expect(std.mem.startsWith(u8, msg, "labelle-gfx 2.0.0 requires labelle-engine >= 3.0.0; got core 2.0.0 / engine 2.12.2 / gfx 2.0.0 ("));
    try std.testing.expect(std.mem.indexOf(u8, msg, "PixelWater") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Pass --engine-version=" ++ config.ENGINE_VERSION) != null);

    // The other direction and the other package: an old gfx or core under
    // the new engine is refused too, naming the right flag.
    const g = (try trioFloorViolation("2.0.0", "3.0.0", "1.30.1")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(FloorSeverity.compile_break, g.severity());
    try std.testing.expect(std.mem.indexOf(u8, g.describe(&buf), "Pass --gfx-version=" ++ config.GFX_VERSION) != null);
    const c = (try trioFloorViolation("1.32.0", "3.0.0", "2.0.0")) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, c.describe(&buf), "Pass --core-version=" ++ config.CORE_VERSION) != null);

    // A CURATED floor is reported as a warning-shaped violation, and a
    // compile break wins over it when both are tripped.
    const w = (try trioFloorViolation("1.28.0", "2.12.0", "1.30.1")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(FloorSeverity.curated, w.severity());
    try std.testing.expect(std.mem.indexOf(u8, w.describe(&buf), "is released against labelle-engine >= 2.12.1") != null);
    const both = (try trioFloorViolation("1.27.0", "2.12.0", "1.30.1")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(FloorSeverity.compile_break, both.severity());

    // Accepted: the defaults and every earlier curated set.
    try std.testing.expect((try trioFloorViolation(config.CORE_VERSION, config.ENGINE_VERSION, config.GFX_VERSION)) == null);
    try std.testing.expect((try trioFloorViolation("2.0.0", "3.0.0", "2.0.0")) == null);
    try std.testing.expect((try trioFloorViolation("1.32.0", "2.12.2", "1.30.1")) == null);
    // A non-release CORE pin used to suppress the WHOLE table; now it
    // suppresses only the rules that read core (#746 review). gfx 2.0.0 with
    // engine 2.12.2 is a compile break the table states without reference to
    // core, so it is caught even though the core pin is unresolvable here.
    const local_core_bad_pair = (try trioFloorViolation("local:../labelle-core", "2.12.2", "2.0.0")) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(TrioPackage.gfx, local_core_bad_pair.floor.subject);
    try std.testing.expectEqual(TrioPackage.engine, local_core_bad_pair.floor.requires);
    // ...and the same local core over a COHERENT engine/gfx pair is still
    // accepted, so the rule above is the table firing, not the local pin.
    try std.testing.expect((try trioFloorViolation("local:../labelle-core", "3.0.0", "2.0.0")) == null);
    try std.testing.expectError(error.UnparsableVersionPin, trioFloorViolation("1.2.3.4", "3.0.0", "2.0.0"));
}

/// Test-shaped wrapper over the PRODUCTION trio validator `init` runs
/// (`trioFloorViolation`): a curated set must be COHERENT, so any floor
/// violation — compile break or curated — fails the assertion. The table
/// the tests pin is the table the user hits (#733 review, round 3).
fn checkTrioFloors(core_version: []const u8, engine_version: []const u8, gfx_version: []const u8) !void {
    if (try trioFloorViolation(core_version, engine_version, gfx_version)) |_| return error.TestUnexpectedResult;
}

test "scaffold pins a MUTUALLY COMPATIBLE trio — #679 regression" {
    // The curated core/engine/gfx defaults in `build.zig` are what every
    // fresh `labelle init` stamps, so an incoherent trio fails `labelle
    // build` before the user has written a line of code. The CI
    // `curated-set` job compiles the real thing; this test is the cheap,
    // hermetic half — it encodes the cross-package floors so a one-package
    // bump cannot land green and be caught only on a cold user machine.
    //
    // Read from `config.*_VERSION` (the build options), NOT from a
    // scaffolded file, so `-Dcore_version=` overrides are checked too.
    // See `checkTrioFloors` for what each floor is and why.
    try std.testing.expect(config.isSemverVersion(config.CORE_VERSION));
    try std.testing.expect(config.isSemverVersion(config.ENGINE_VERSION));
    try std.testing.expect(config.isSemverVersion(config.GFX_VERSION));

    try checkTrioFloors(config.CORE_VERSION, config.ENGINE_VERSION, config.GFX_VERSION);
}

test "curated-trio floors reject each incoherent combination — #683 review" {
    // The floors themselves, against synthetic trios: the test above can
    // only ever see whatever `build.zig` defaults to today, so without
    // these a floor could be silently dropped and still go green.
    try checkTrioFloors("2.0.0", "3.0.0", "2.0.0"); // the current curated set (PR #733)
    try checkTrioFloors("1.32.0", "2.12.2", "1.30.1"); // the #736 curated set — still coherent
    try checkTrioFloors("1.28.0", "2.12.2", "1.30.1"); // the pre-#731 curated set — still coherent

    // The 2.0.0 line does not mix with the 1.x line in any direction:
    // gfx 2.0.0 needs core 2.0.0 + engine 3.0.0; engine 3.0.0 needs
    // core 2.0.0 + gfx 2.0.0.
    try std.testing.expectError(error.TestUnexpectedResult, checkTrioFloors("1.32.0", "3.0.0", "2.0.0"));
    try std.testing.expectError(error.TestUnexpectedResult, checkTrioFloors("2.0.0", "2.12.2", "2.0.0"));
    try std.testing.expectError(error.TestUnexpectedResult, checkTrioFloors("2.0.0", "3.0.0", "1.30.1"));
    try std.testing.expectError(error.TestUnexpectedResult, checkTrioFloors("1.32.0", "3.0.0", "1.30.1"));

    // gfx >= 1.30.0 needs core >= 1.28.0 and engine >= 2.12.1.
    try std.testing.expectError(error.TestUnexpectedResult, checkTrioFloors("1.27.0", "2.12.2", "1.30.1"));
    try std.testing.expectError(error.TestUnexpectedResult, checkTrioFloors("1.28.0", "2.12.0", "1.30.1"));

    // engine >= 2.11.0 needs core >= 1.27.0 and gfx >= 1.28.0. The gfx half
    // is the floor #683 review found missing: this trio used to pass.
    try std.testing.expectError(error.TestUnexpectedResult, checkTrioFloors("1.26.0", "2.11.0", "1.29.0"));
    try std.testing.expectError(error.TestUnexpectedResult, checkTrioFloors("1.27.0", "2.11.0", "1.27.0"));

    // Below every floor, nothing is asserted — old coherent sets stay legal.
    try checkTrioFloors("1.24.0", "2.7.0", "1.27.0");
}

/// The builtin backend providers are curated WITH the trio (#731 review):
/// a `labelle init --backend=bgfx` scaffold pairs `src/config.zig`'s bgfx
/// default with the core default above. The floors themselves live in
/// `bgfx_core_floors` (see the rationale there); this helper is a thin
/// test-shaped wrapper over the PRODUCTION validator `init` runs, so the
/// table the tests pin is the table the user hits (#736 review).
fn checkBgfxProviderFloors(core_version: []const u8, bgfx_version: []const u8) !void {
    if (try providerCoreFloorViolation(.bgfx, bgfx_version, core_version)) |_| return error.TestUnexpectedResult;
}

test "scaffold core default pairs with the builtin bgfx provider — #731 review" {
    // Read the REAL default from `builtinProvider`, not a copy of its version
    // string, so a provider bump that forgets the trio fails here.
    const bgfx = config.ProjectConfig.builtinProvider(.bgfx) orelse return error.TestUnexpectedResult;
    try std.testing.expect(config.isSemverVersion(bgfx.version));
    try checkBgfxProviderFloors(config.CORE_VERSION, bgfx.version);
}

test "bgfx-provider floors reject the #731 pairings" {
    try checkBgfxProviderFloors("2.0.0", "0.21.0"); // the curated pairing (PR #733)
    try checkBgfxProviderFloors("1.32.0", "0.20.0"); // the #736 curated pairing — still coherent
    // bgfx >= 0.21.0 is contract-v2: the hard floor is core 2.0.0, so the
    // #736 core is rejected under the new provider default.
    try std.testing.expectError(error.TestUnexpectedResult, checkBgfxProviderFloors("1.32.0", "0.21.0"));
    try std.testing.expectError(error.TestUnexpectedResult, checkBgfxProviderFloors("1.28.0", "0.21.0"));
    // What #731 shipped: the bgfx 0.20.0 default over the core 1.28.0 scaffold default.
    try std.testing.expectError(error.TestUnexpectedResult, checkBgfxProviderFloors("1.28.0", "0.20.0"));
    // What #731's examples pinned: bgfx 0.20.0 over core 1.26.0 — the compile break.
    try std.testing.expectError(error.TestUnexpectedResult, checkBgfxProviderFloors("1.26.0", "0.20.0"));
    try std.testing.expectError(error.TestUnexpectedResult, checkBgfxProviderFloors("1.26.0", "0.15.0"));
    // Below every floor, nothing is asserted — old coherent pairings stay legal.
    try checkBgfxProviderFloors("1.26.0", "0.13.1");
}

test "init refuses --backend=bgfx --core-version=1.26.0 with a named diagnostic, accepts 2.0.0 — #736 review" {
    const bgfx = config.ProjectConfig.builtinProvider(.bgfx) orelse return error.TestUnexpectedResult;
    var buf: [512]u8 = undefined;
    var want_buf: [128]u8 = undefined;

    // The front-door failure: the hard floor is the one reported (it is the
    // actionable one), the diagnostic names backend + REAL provider version,
    // the floor, the requested core, and recommends the curated core. Under
    // the contract-v2 default (bgfx 0.21.0, PR #733) the strictest hard
    // floor is core 2.0.0 and every 1.x core trips it.
    const v = (try backendCoreFloorViolation("bgfx", "1.26.0")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(FloorSeverity.compile_break, v.severity);
    try std.testing.expectEqualStrings("2.0.0", v.core_floor);
    try std.testing.expectEqualStrings("2.0.0", v.recommended_core);
    const msg = v.describe(&buf);
    const want = try std.fmt.bufPrint(&want_buf, "bgfx {s} requires labelle-core >= 2.0.0; got 1.26.0 (", .{bgfx.version});
    try std.testing.expect(std.mem.startsWith(u8, msg, want));
    try std.testing.expect(std.mem.indexOf(u8, msg, "shader_material") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "--core-version=2.0.0") != null);

    // The #736 curated core is now a compile break too (not a warning): the
    // default provider no longer compiles on it.
    const c = (try backendCoreFloorViolation("bgfx", "1.32.0")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(FloorSeverity.compile_break, c.severity);
    try std.testing.expectEqualStrings("2.0.0", c.core_floor);

    // The CURATED (warn-and-scaffold) severity still exists for the older
    // provider: bgfx 0.20.0 over core 1.28.0 builds, so it is a WARNING.
    const w = (try providerCoreFloorViolation(.bgfx, "0.20.0", "1.28.0")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(FloorSeverity.curated, w.severity);
    try std.testing.expectEqualStrings("1.32.0", w.core_floor);
    const wmsg = w.describe(&buf);
    try std.testing.expect(std.mem.indexOf(u8, wmsg, "is released against labelle-core >= 1.32.0; got 1.28.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, wmsg, "requires") == null);

    // Accepted: the curated core, the scaffold's own default, and anything newer.
    try std.testing.expect((try backendCoreFloorViolation("bgfx", "2.0.0")) == null);
    try std.testing.expect((try backendCoreFloorViolation("bgfx", config.CORE_VERSION)) == null);
    try std.testing.expect((try backendCoreFloorViolation("bgfx", "2.1")) == null);

    // Not this validator's business: other backends, a non-release core pin,
    // a backend name the enum does not know (init's own parser rejects it).
    try std.testing.expect((try backendCoreFloorViolation("raylib", "1.26.0")) == null);
    try std.testing.expect((try backendCoreFloorViolation("null", "1.0.0")) == null);
    try std.testing.expect((try backendCoreFloorViolation("bgfx", "local:../labelle-core")) == null);
    try std.testing.expect((try backendCoreFloorViolation("klingon", "1.0.0")) == null);

    // A dotted-but-unparsable core pin surfaces as the named error, not a crash.
    try std.testing.expectError(error.UnparsableVersionPin, backendCoreFloorViolation("bgfx", "1.2.3.4"));
}

test "pinAtLeast normalizes the abbreviated `X.Y` pin form, and names a bad one — #683 review" {
    // `config.isSemverVersion` admits both of these, so `zig build test
    // -Dgfx_version=1.30` used to reach `catch unreachable` and crash with
    // no useful message.
    try std.testing.expect(config.isSemverVersion("1.30"));
    try std.testing.expect(try pinAtLeast("1.30", "1.30.0"));
    try std.testing.expect(try pinAtLeast("1.30", "1.28.0"));
    try std.testing.expect(!(try pinAtLeast("1.29", "1.30.0")));
    try std.testing.expect(try pinAtLeast("2.12.2", "2.12"));

    // The dotted non-semver form `isSemverVersion` also admits fails
    // cleanly rather than trapping.
    try std.testing.expect(config.isSemverVersion("1.2.3.4"));
    try std.testing.expectError(error.UnparsableVersionPin, pinAtLeast("1.2.3.4", "1.0.0"));
    try std.testing.expectError(error.UnparsableVersionPin, pinAtLeast("1.0.0", "1.2.3.4"));

    // And an abbreviated pin flows through the real guard.
    try checkTrioFloors("1.28", "2.13", "1.30");
}
