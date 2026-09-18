//! `init` subcommand for the labelle-assembler binary.
//!
//! Issue #217, phase 3 — the `labelle` CLI used to scaffold new projects
//! in-process (`labelle-cli/src/cli/init.zig` imported the assembler's
//! `generator` module for the default version constants). Project
//! scaffolding is assembler knowledge: it writes a `project.labelle`
//! whose schema the assembler owns, and pins versions the assembler
//! defines. So the assembler now owns the `init` *command* too, and the
//! CLI shells out to `labelle-assembler init <name> [dir] [flags]`.
//!
//! Mirrors `cache_cmd.zig`: parses its own args, prints diagnostics, and
//! exits non-zero on failure so the CLI can propagate the exit code.
//!
//! Behavior is identical to the CLI's old `cmdInit` — same flags, same
//! files, same starter layout — including the #204 fix (scaffolds
//! `scenes/main.jsonc`, never `.zon`, since the generator only scans for
//! `.jsonc` scenes).

const std = @import("std");
const gen = @import("root.zig");
const config = @import("config.zig");
const escapeZonString = @import("zon_escape.zig").escapeZonString;

/// Write directly to stderr without a level prefix. Matches main.zig.
fn writeStderr(io: std.Io, msg: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
}

const init_usage =
    \\labelle-assembler init — scaffold a new project directory
    \\
    \\Usage:
    \\  labelle-assembler init <name> [--backend=X] [--ecs=X] [--gui=X] [--*-version=X] [dir]
    \\
    \\Creates <dir> (defaults to <name>) with a project.labelle plus the
    \\starter scripts/, scenes/, prefabs/, assets/, components/, hooks/
    \\layout, a scenes/main.jsonc, and a .gitignore.
    \\
    \\Flags:
    \\  --backend=X            Graphics backend (default raylib)
    \\  --ecs=X                ECS choice (default zig_ecs)
    \\  --gui=X                GUI plugin path (default none)
    \\  --core-version=X       Pin labelle-core version
    \\  --engine-version=X     Pin labelle-engine version
    \\  --gfx-version=X        Pin labelle-gfx version
    \\  --labelle-version=X    Pin labelle CLI version
    \\  --assembler-version=X  Pin assembler version
    \\
;

/// Fully resolved scaffolding parameters. Defaults match the CLI's former
/// in-process `cmdInit`; the version fields default to this assembler
/// build's pinned versions.
pub const InitOptions = struct {
    /// Project name — written into `.name` / `.title`. Required.
    name: []const u8,
    /// Target directory; defaults to `name` when the caller leaves it null.
    dir: ?[]const u8 = null,
    backend: []const u8 = "raylib",
    ecs: []const u8 = "zig_ecs",
    gui: ?[]const u8 = null,
    core_version: []const u8 = gen.CORE_VERSION,
    engine_version: []const u8 = gen.ENGINE_VERSION,
    gfx_version: []const u8 = gen.GFX_VERSION,
    labelle_version: []const u8 = gen.CLI_VERSION,
    /// Default to this binary's own version — a `labelle init` driven by
    /// this assembler pins the assembler that scaffolded it.
    assembler_version: []const u8 = gen.ASSEMBLER_VERSION,
};

/// `init` subcommand entry point. Parses argv, then delegates to
/// `scaffold`. Exits non-zero on a bad invocation; `scaffold` exits
/// non-zero on a filesystem failure.
pub fn cmdInit(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    var name: ?[]const u8 = null;
    var opts: InitOptions = .{ .name = "" };

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--backend=")) {
            opts.backend = arg["--backend=".len..];
        } else if (std.mem.startsWith(u8, arg, "--ecs=")) {
            opts.ecs = arg["--ecs=".len..];
        } else if (std.mem.startsWith(u8, arg, "--gui=")) {
            opts.gui = arg["--gui=".len..];
        } else if (std.mem.startsWith(u8, arg, "--core-version=")) {
            opts.core_version = arg["--core-version=".len..];
        } else if (std.mem.startsWith(u8, arg, "--engine-version=")) {
            opts.engine_version = arg["--engine-version=".len..];
        } else if (std.mem.startsWith(u8, arg, "--gfx-version=")) {
            opts.gfx_version = arg["--gfx-version=".len..];
        } else if (std.mem.startsWith(u8, arg, "--labelle-version=")) {
            opts.labelle_version = arg["--labelle-version=".len..];
        } else if (std.mem.startsWith(u8, arg, "--assembler-version=")) {
            opts.assembler_version = arg["--assembler-version=".len..];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            writeStderr(io, init_usage);
            return;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            std.log.err("labelle-assembler init: unknown flag '{s}'", .{arg});
            std.process.exit(2);
        } else if (name == null) {
            name = arg;
        } else if (opts.dir == null) {
            opts.dir = arg;
        } else {
            std.log.err("labelle-assembler init: unexpected argument '{s}'", .{arg});
            writeStderr(io, "\n" ++ init_usage);
            std.process.exit(2);
        }
    }

    opts.name = name orelse {
        std.log.err("labelle-assembler init: missing project name", .{});
        writeStderr(io, "\n" ++ init_usage);
        std.process.exit(2);
    };

    // #736 review (CodeRabbit): refuse a backend name the `Backend` enum does
    // not know BEFORE anything else. `scaffold` writes the value verbatim as
    // `.backend = .<x>`, so `--backend=bgxf` used to produce a project that
    // only failed when a later command parsed it — and the floor check below
    // silently treated the unknown name as "not my business".
    if (checkBackendName(opts.backend)) |_| {} else |_| {
        var buf: [512]u8 = undefined;
        std.log.err("labelle-assembler init: {s}", .{unknownBackendDiagnostic(opts.backend, &buf)});
        std.process.exit(2);
    }

    // #736 review: refuse a backend/core pairing that cannot compile BEFORE
    // a single file is written. Only the hard floor is fatal; a curated
    // floor warns and scaffolds, since the user asked for that core
    // explicitly and it does build. The version default never trips this
    // (the tests pin `config.CORE_VERSION` against the real provider).
    if (backendCoreFloorViolation(opts.backend, opts.core_version) catch |err| {
        std.log.err("labelle-assembler init: --core-version={s}: {s}", .{ opts.core_version, @errorName(err) });
        std.process.exit(2);
    }) |v| {
        var buf: [512]u8 = undefined;
        switch (v.severity) {
            .compile_break => {
                std.log.err("labelle-assembler init: {s}", .{v.describe(&buf)});
                std.process.exit(2);
            },
            .curated => std.log.warn("labelle-assembler init: {s}", .{v.describe(&buf)}),
        }
    }

    // #733 review (round 3): the core/engine/gfx trio must be coherent too —
    // an explicit `--engine-version=`/`--gfx-version=`/`--core-version=`
    // against the other two defaults used to pass the backend/core check
    // above and scaffold a set the trio test declared incompatible. Same
    // policy: a compile break refuses, a curated floor warns and scaffolds.
    if (trioFloorViolation(opts.core_version, opts.engine_version, opts.gfx_version) catch |err| {
        std.log.err("labelle-assembler init: core/engine/gfx version pins: {s}", .{@errorName(err)});
        std.process.exit(2);
    }) |v| {
        var buf: [1024]u8 = undefined;
        switch (v.severity()) {
            .compile_break => {
                std.log.err("labelle-assembler init: {s}", .{v.describe(&buf)});
                std.process.exit(2);
            },
            .curated => std.log.warn("labelle-assembler init: {s}", .{v.describe(&buf)}),
        }
    }

    try scaffold(allocator, io, opts);
}

// ── backend name validation ──────────────────────────────────────────

/// The `--backend=` value as a `config.Backend` tag, or `error.UnknownBackend`.
/// The enum is the single source of truth for what `init` accepts — the
/// same tag set `project.labelle`'s `.backend` parses — so the two cannot
/// drift.
pub fn checkBackendName(name: []const u8) error{UnknownBackend}!config.Backend {
    return std.meta.stringToEnum(config.Backend, name) orelse error.UnknownBackend;
}

/// The diagnostic for an unknown `--backend=` value: names the value and
/// lists every valid backend, derived from the enum (never a literal list).
pub fn unknownBackendDiagnostic(name: []const u8, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print("unknown --backend '{s}'; valid backends: ", .{name}) catch return "unknown --backend (diagnostic too long to render)";
    inline for (std.meta.fieldNames(config.Backend), 0..) |tag, i| {
        w.print("{s}{s}", .{ if (i == 0) "" else ", ", tag }) catch return "unknown --backend (diagnostic too long to render)";
    }
    return w.buffered();
}

test "init refuses an unknown --backend with a diagnostic listing the enum's backends — #736 review (CodeRabbit)" {
    // The mechanism: an unknown name is an ERROR (not a silent pass-through
    // the scaffold writes verbatim), and every real tag is accepted.
    try std.testing.expectError(error.UnknownBackend, checkBackendName("bgxf"));
    try std.testing.expectError(error.UnknownBackend, checkBackendName(""));
    try std.testing.expectError(error.UnknownBackend, checkBackendName("BGFX"));
    for (std.enums.values(config.Backend)) |tag| {
        try std.testing.expectEqual(tag, try checkBackendName(@tagName(tag)));
    }
    // The diagnostic names the offending value and every valid backend.
    var buf: [512]u8 = undefined;
    const msg = unknownBackendDiagnostic("bgxf", &buf);
    try std.testing.expect(std.mem.indexOf(u8, msg, "'bgxf'") != null);
    for (std.enums.values(config.Backend)) |tag| {
        try std.testing.expect(std.mem.indexOf(u8, msg, @tagName(tag)) != null);
    }
    try std.testing.expectEqualStrings("unknown --backend 'bgxf'; valid backends: raylib, sokol, sdl, bgfx, wgpu, null", msg);
}

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

const FloorSeverity = enum {
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
/// wins. Pins that are not release versions (`local:…`) are resolved
/// elsewhere and leave the trio unjudged.
pub fn trioFloorViolation(core_version: []const u8, engine_version: []const u8, gfx_version: []const u8) error{UnparsableVersionPin}!?TrioViolation {
    if (!config.isSemverVersion(core_version) or !config.isSemverVersion(engine_version) or !config.isSemverVersion(gfx_version)) return null;
    var worst: ?TrioViolation = null;
    for (trio_floors) |f| {
        const v: TrioViolation = .{ .core_version = core_version, .engine_version = engine_version, .gfx_version = gfx_version, .floor = f };
        if (!try pinAtLeast(v.pinOf(f.subject), f.subject_at_least)) continue;
        if (try pinAtLeast(v.pinOf(f.requires), f.floor)) continue;
        if (worst == null or (f.severity == .compile_break and worst.?.floor.severity != .compile_break)) worst = v;
    }
    return worst;
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
    try std.testing.expect(std.mem.indexOf(u8, msg, "Pass --engine-version=3.0.0") != null);

    // The other direction and the other package: an old gfx or core under
    // the new engine is refused too, naming the right flag.
    const g = (try trioFloorViolation("2.0.0", "3.0.0", "1.30.1")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(FloorSeverity.compile_break, g.severity());
    try std.testing.expect(std.mem.indexOf(u8, g.describe(&buf), "Pass --gfx-version=2.0.0") != null);
    const c = (try trioFloorViolation("1.32.0", "3.0.0", "2.0.0")) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, c.describe(&buf), "Pass --core-version=2.0.0") != null);

    // A CURATED floor is reported as a warning-shaped violation, and a
    // compile break wins over it when both are tripped.
    const w = (try trioFloorViolation("1.28.0", "2.12.0", "1.30.1")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(FloorSeverity.curated, w.severity());
    try std.testing.expect(std.mem.indexOf(u8, w.describe(&buf), "is released against labelle-engine >= 2.12.1") != null);
    const both = (try trioFloorViolation("1.27.0", "2.12.0", "1.30.1")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(FloorSeverity.compile_break, both.severity());

    // Accepted: the defaults, every earlier curated set, and non-release pins.
    try std.testing.expect((try trioFloorViolation(config.CORE_VERSION, config.ENGINE_VERSION, config.GFX_VERSION)) == null);
    try std.testing.expect((try trioFloorViolation("2.0.0", "3.0.0", "2.0.0")) == null);
    try std.testing.expect((try trioFloorViolation("1.32.0", "2.12.2", "1.30.1")) == null);
    try std.testing.expect((try trioFloorViolation("local:../labelle-core", "2.12.2", "2.0.0")) == null);
    try std.testing.expectError(error.UnparsableVersionPin, trioFloorViolation("1.2.3.4", "3.0.0", "2.0.0"));
}

/// Materialize a new project directory from `opts`. Exits the process
/// non-zero on a filesystem failure (the CLI propagates the exit code).
/// Split out from `cmdInit` so it can be unit-tested without building an
/// `Args.Iterator`.
pub fn scaffold(allocator: std.mem.Allocator, io: std.Io, opts: InitOptions) !void {
    const dir = opts.dir orelse opts.name;
    const cwd = std.Io.Dir.cwd();

    cwd.createDirPath(io, dir) catch |err| {
        std.log.err("labelle-assembler init: could not create '{s}': {s}", .{ dir, @errorName(err) });
        std.process.exit(1);
    };

    // Write project.labelle
    {
        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();
        const w = &aw.writer;

        // Escape every value that lands inside a `"..."` ZON literal — a
        // name/path/version containing a quote or backslash would
        // otherwise produce an unparseable project.labelle. `backend` and
        // `ecs` are enum tags (`.{s}`, no quotes); they're validated
        // against fixed enums downstream, so they're left unescaped.
        const name_z = try escapeZonString(allocator, opts.name);
        defer allocator.free(name_z);
        const core_z = try escapeZonString(allocator, opts.core_version);
        defer allocator.free(core_z);
        const engine_z = try escapeZonString(allocator, opts.engine_version);
        defer allocator.free(engine_z);
        const gfx_z = try escapeZonString(allocator, opts.gfx_version);
        defer allocator.free(gfx_z);
        const labelle_z = try escapeZonString(allocator, opts.labelle_version);
        defer allocator.free(labelle_z);
        const assembler_z = try escapeZonString(allocator, opts.assembler_version);
        defer allocator.free(assembler_z);

        try w.print(
            \\.{{
            \\    .name = "{s}",
            \\    .title = "{s}",
            \\    .width = 800,
            \\    .height = 600,
            \\    .target_fps = 60,
            \\    .backend = .{s},
            \\    // Logical Y-axis convention (RFC-Y-AXIS-CONVENTION). `.down` is
            \\    // the screen-native default for new projects (y=0 at the top,
            \\    // +Y down); use `.up` for the math-/platformer-natural bottom
            \\    // origin. This key is REQUIRED — an absent `.y_axis` is a hard
            \\    // build error during the convention transition.
            \\    .y_axis = .down,
            \\    .ecs = .{s},
            \\
        , .{ name_z, name_z, opts.backend, opts.ecs });

        // GUI plugin reference (null = no GUI, or a plugin ref)
        if (opts.gui) |gui_path| {
            const gui_z = try escapeZonString(allocator, gui_path);
            defer allocator.free(gui_z);
            try w.print(
                \\    .gui = .{{ .path = "{s}" }},
                \\
            , .{gui_z});
        }

        try w.print(
            \\    .plugins = .{{}},
            \\    .layers = .{{
            \\        .{{ .name = "background", .order = 0, .space = .screen }},
            \\        .{{ .name = "world", .order = 1, .space = .world }},
            \\        .{{ .name = "ui", .order = 2, .space = .screen }},
            \\    }},
            \\    .core_version = "{s}",
            \\    .engine_version = "{s}",
            \\    .gfx_version = "{s}",
            \\    .labelle_version = "{s}",
            \\    .assembler_version = "{s}",
            \\}}
            \\
        , .{ core_z, engine_z, gfx_z, labelle_z, assembler_z });

        const path = try std.fs.path.join(allocator, &.{ dir, "project.labelle" });
        defer allocator.free(path);
        cwd.writeFile(io, .{
            .sub_path = path,
            .data = aw.written(),
            .flags = .{ .exclusive = true },
        }) catch |err| {
            std.log.err("labelle-assembler init: could not write '{s}': {s}", .{ path, @errorName(err) });
            std.process.exit(1);
        };
    }

    // Create starter directories
    const dirs = [_][]const u8{ "scripts", "scenes", "prefabs", "assets", "components", "hooks" };
    for (dirs) |subdir| {
        const path = try std.fs.path.join(allocator, &.{ dir, subdir });
        defer allocator.free(path);
        cwd.createDirPath(io, path) catch {};
    }

    // Write a starter scene.
    //
    // NOTE: The assembler scans `scenes/` for `.jsonc` files only — the
    // legacy `.zon` extension is silently ignored, so a freshly scaffolded
    // project with `main.zon` would build but render nothing (see #204).
    // Keep this in JSONC to match what the assembler actually loads.
    //
    // FORMAT: emit flat-form unified shape from day one (RFC #594 / engine
    // #592). Top-level `"children"` — no `"root":` wrapper, no legacy
    // `"entities"` key, no `"components"` on prefab refs (use
    // `"overrides"`). The loader still dual-accepts the old shape, but new
    // projects scaffold clean so `labelle audit unification` reports zero
    // findings out of the box.
    {
        const path = try std.fs.path.join(allocator, &.{ dir, "scenes", "main.jsonc" });
        defer allocator.free(path);
        cwd.writeFile(io, .{
            .sub_path = path,
            .data =
            \\{
            \\    "name": "main",
            \\    "children": []
            \\}
            \\
            ,
            .flags = .{ .exclusive = true },
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                std.log.err("labelle-assembler init: could not write '{s}': {s}", .{ path, @errorName(err) });
                std.process.exit(1);
            },
        };
    }

    // Write .gitignore
    {
        const path = try std.fs.path.join(allocator, &.{ dir, ".gitignore" });
        defer allocator.free(path);
        cwd.writeFile(io, .{
            .sub_path = path,
            .data = ".labelle/\n",
            .flags = .{ .exclusive = true },
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                std.log.err("labelle-assembler init: could not write '{s}': {s}", .{ path, @errorName(err) });
                std.process.exit(1);
            },
        };
    }

    std.log.info("labelle-assembler: created project '{s}' in {s}/", .{ opts.name, dir });
    std.log.info("  next: cd {s} && labelle run", .{dir});
}

// ─── Tests ─────────────────────────────────────────────────────────────
//
// Regression guard for #204: the assembler scans `scenes/` for `.jsonc`
// only, so scaffolding a `.zon` scene produced an empty game. The CLI's
// old test for this moved here with the command itself.

test "scaffold writes scenes/main.jsonc (not .zon) — #204 regression" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = config.globalIo();

    // scaffold resolves paths relative to cwd, so we pass an absolute path
    // as the target dir. Materialize a subdir first so we can realpath it.
    try tmp.dir.createDirPath(io, "init-204");
    const project_dir = try tmp.dir.realPathFileAlloc(io, "init-204", alloc);
    defer alloc.free(project_dir);

    try scaffold(alloc, io, .{ .name = "init-204", .dir = project_dir });

    // Confirm scenes/main.jsonc exists and starts with `{` (JSONC, not ZON).
    const scene_bytes = try tmp.dir.readFileAlloc(
        io,
        "init-204/scenes/main.jsonc",
        alloc,
        .limited(4096),
    );
    defer alloc.free(scene_bytes);
    try std.testing.expect(scene_bytes.len > 0);
    try std.testing.expectEqual(@as(u8, '{'), scene_bytes[0]);

    // And scenes/main.zon must NOT exist (would silently shadow the real scene).
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(io, "init-204/scenes/main.zon", .{}),
    );
}

test "scaffold writes a project.labelle with the requested fields" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = config.globalIo();

    try tmp.dir.createDirPath(io, "init-fields");
    const project_dir = try tmp.dir.realPathFileAlloc(io, "init-fields", alloc);
    defer alloc.free(project_dir);

    try scaffold(alloc, io, .{
        .name = "init-fields",
        .dir = project_dir,
        .backend = "sokol",
        .ecs = "zflecs",
    });

    const labelle = try tmp.dir.readFileAlloc(
        io,
        "init-fields/project.labelle",
        alloc,
        .limited(4096),
    );
    defer alloc.free(labelle);

    try std.testing.expect(std.mem.indexOf(u8, labelle, ".name = \"init-fields\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, labelle, ".backend = .sokol") != null);
    try std.testing.expect(std.mem.indexOf(u8, labelle, ".ecs = .zflecs") != null);
    try std.testing.expect(std.mem.indexOf(u8, labelle, ".assembler_version = ") != null);
    // RFC-Y-AXIS-CONVENTION (#370): a scaffolded project pins the explicit
    // screen-native default so it satisfies the unset-`.y_axis` build guard.
    try std.testing.expect(std.mem.indexOf(u8, labelle, ".y_axis = .down,") != null);
}

test "scaffold pins real fetchable framework versions — #159 regression" {
    // A freshly scaffolded project.labelle must pin semver-shaped, fetchable
    // versions. Scaffolding "dev" (or any non-numeric string) made the fetch
    // synthesize a bogus `vdev` git ref and fail. Guard against a regression
    // back to "dev" defaults.
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = config.globalIo();

    try tmp.dir.createDirPath(io, "init-159");
    const project_dir = try tmp.dir.realPathFileAlloc(io, "init-159", alloc);
    defer alloc.free(project_dir);

    try scaffold(alloc, io, .{ .name = "init-159", .dir = project_dir });

    const labelle = try tmp.dir.readFileAlloc(
        io,
        "init-159/project.labelle",
        alloc,
        .limited(4096),
    );
    defer alloc.free(labelle);

    // Parse it back and confirm each scaffolded framework version satisfies
    // the proper semver shape via config.isSemverVersion (digits-and-dots
    // with at least one dot) — i.e. it maps to a real `v<x.y.z>` release tag
    // rather than a bogus ref like `vdev`. Asserting the full semver shape
    // (not merely "starts with a digit") stops a stale non-semver default
    // from slipping through.
    const src = try alloc.dupeZ(u8, labelle);
    defer alloc.free(src);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const cfg = try std.zon.parse.fromSliceAlloc(config.ProjectConfig, arena.allocator(), src, null, .{});
    try std.testing.expect(config.isSemverVersion(cfg.core_version));
    try std.testing.expect(config.isSemverVersion(cfg.engine_version));
    try std.testing.expect(config.isSemverVersion(cfg.gfx_version));
}

/// The pin comparison lives in `config` (PR #733) so the generate-time
/// materials contract gate shares it; the guards below keep the short name.
const pinAtLeast = config.pinAtLeast;

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
test "scaffold emits flat-form scenes — RFC #594 / engine #592 regression" {
    // Lock in "new projects start clean" for the v2.0 unified-format
    // foundation. The four legacy patterns `labelle audit unification`
    // flags are:
    //   1. top-level `"entities"` key   (legacy_entities)
    //   2. top-level `"root":` wrapper  (legacy_root_wrapper)
    //   3. `"components"` on a prefab ref (legacy_components_on_ref)
    //   4. legacy `"assets":` array      (legacy_assets)
    //
    // None of these may appear in a freshly scaffolded scene. This is the
    // load-bearing guard for the assertion in PR engine#594 phase 2: a
    // fresh `labelle init` produces an audit-clean tree.
    //
    // Detection here mirrors audit.zig's surface checks — top-level key
    // names parsed out of the scaffolded JSONC. The audit binary itself
    // lives in labelle-cli; we can't link it in here, but the shape it
    // looks for is small enough to assert directly.
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = config.globalIo();

    try tmp.dir.createDirPath(io, "init-flat");
    const project_dir = try tmp.dir.realPathFileAlloc(io, "init-flat", alloc);
    defer alloc.free(project_dir);

    try scaffold(alloc, io, .{ .name = "init-flat", .dir = project_dir });

    const scene = try tmp.dir.readFileAlloc(
        io,
        "init-flat/scenes/main.jsonc",
        alloc,
        .limited(4096),
    );
    defer alloc.free(scene);

    // Positive: flat-form must use top-level "children".
    try std.testing.expect(std.mem.indexOf(u8, scene, "\"children\"") != null);

    // Negative: none of the four legacy patterns may appear.
    try std.testing.expect(std.mem.indexOf(u8, scene, "\"entities\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, scene, "\"root\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, scene, "\"components\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, scene, "\"assets\"") == null);
}

test "scaffold writes a parseable project.labelle for a name with a quote" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = config.globalIo();

    try tmp.dir.createDirPath(io, "init-escape");
    const project_dir = try tmp.dir.realPathFileAlloc(io, "init-escape", alloc);
    defer alloc.free(project_dir);

    // A name containing both a double quote and a backslash — verbatim
    // interpolation would produce an unparseable project.labelle.
    try scaffold(alloc, io, .{
        .name = "ev\"il\\game",
        .dir = project_dir,
        .core_version = "1.0\"0",
    });

    const labelle = try tmp.dir.readFileAlloc(
        io,
        "init-escape/project.labelle",
        alloc,
        .limited(4096),
    );
    defer alloc.free(labelle);

    // The escaped form must be present...
    try std.testing.expect(std.mem.indexOf(u8, labelle, "ev\\\"il\\\\game") != null);
    try std.testing.expect(std.mem.indexOf(u8, labelle, "1.0\\\"0") != null);

    // ...and the file must still parse as ZON.
    const src = try alloc.dupeZ(u8, labelle);
    defer alloc.free(src);
    // Parse into an arena: ProjectConfig carries comptime-default slice
    // fields (e.g. `.layers`) that std.zon.parse.free would choke on.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const cfg = try std.zon.parse.fromSliceAlloc(config.ProjectConfig, arena.allocator(), src, null, .{});
    try std.testing.expectEqualStrings("ev\"il\\game", cfg.name);
    try std.testing.expectEqualStrings("1.0\"0", cfg.core_version);
}
