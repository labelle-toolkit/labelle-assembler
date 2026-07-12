//! TypeScript check+emit at generate — e2e tests (labelle-engine#745,
//! epic labelle-engine#237).
//!
//! The unit halves (platform pin table, tarball URL golden, sha512
//! verify, cache-hit probe, zig→ts type mapping, d.ts + tsconfig
//! rendering goldens, the need probe, stem collisions) live inline in
//! `src/scripting_transpile.zig`. These tests close what only the REAL
//! `generate` can prove, through the `tsc_tool_override` seam (a staged
//! fake tsc — the real binary is a ~9 MB network fetch, exactly what the
//! suite must never depend on; the real toolchain's behavior was pinned
//! manually against tsc 7.0.2 during design):
//!
//!   1. a `.ts` project transpiles end to end — the target's script dir
//!      MATERIALIZES (symlink → real dir), the fake tsc's emitted `.js`
//!      embeds beside the copied plain `.js`, the generated
//!      `labelle-components.d.ts` + `tsconfig.json` land where the
//!      design says, and the tsconfig's `files` list is exactly right
//!      (game sources; the game's OWN labelle.d.ts copy suppressing the
//!      package contract — and the package contract present when the
//!      game has no copy);
//!   2. a type error (fake tsc exits nonzero) FAILS generate — the
//!      ticket's acceptance criterion;
//!   3. a `.js`-only project SKIPS the whole phase — poison override
//!      never invoked, symlink layout intact, no generated files: the
//!      no-fetch pin (the probe precedes tool resolution);
//!   4. a `.ts`/`.js` same-stem collision fails BEFORE the tool runs;
//!   5. removing every `.ts` restores the pre-transpile layout (stale
//!      tsconfig dropped, symlink back, only plain scripts registered).

const std = @import("std");
const zspec = @import("zspec");
const generate = @import("generator");
const h = @import("helpers.zig");

const io = std.testing.io;

const engine_template = h.engine_template;

test {
    zspec.runAll(@This());
}

fn indexOfOrFail(haystack: []const u8, needle: []const u8) !usize {
    return std.mem.indexOf(u8, haystack, needle) orelse {
        std.debug.print("expected to find:\n  {s}\nin generated output\n", .{needle});
        return error.MissingExpectedEmission;
    };
}

fn writeFileIn(dir: std.Io.Dir, rel: []const u8, body: []const u8) !void {
    if (std.fs.path.dirname(rel)) |sub| try dir.createDirPath(io, sub);
    var f = try dir.createFile(io, rel, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, body);
}

/// A staged tmp typescript game project (the scripting_splice_tests
/// `StagedTsProject` shape): `game/` with a manifest-bearing scripting
/// plugin that SHIPS a `contract/labelle.d.ts` (so the package-contract
/// tsconfig row is exercisable), a `ts/` dir holding a plain `.js`
/// script AND a `.ts` script, a component file (the d.ts provider), the
/// engine template fixture (exe main.zig emission), and `out/`.
const StagedTranspileProject = struct {
    tmp: std.testing.TmpDir,
    game_abs: [:0]const u8,
    out_abs: [:0]const u8,

    fn init(allocator: std.mem.Allocator) !StagedTranspileProject {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io, "out");
        try tmp.dir.createDirPath(io, "game");
        var game_root = try tmp.dir.openDir(io, "game", .{});
        defer game_root.close(io);
        try writeFileIn(game_root, "plugins/scripting/plugin.labelle",
            \\.{ .name = "scripting", .manifest_version = 1 }
        );
        // The shipped contract d.ts (labelle-scripting >= 0.3.0 ships
        // contract/labelle.d.ts in its package).
        try writeFileIn(game_root, "plugins/scripting/contract/labelle.d.ts",
            \\declare const labelle: { log(msg: unknown): void };
            \\
        );
        try writeFileIn(game_root, "ts/behavior.js",
            \\// @ts-check
            \\export function update(dt) {}
        );
        try writeFileIn(game_root, "ts/enemy.ts",
            \\export function update(dt: number): void {}
        );
        // A game component with the mapping-interesting field types —
        // the generated d.ts golden's provider.
        try writeFileIn(game_root, "components/ship.zig",
            \\pub const Ship = struct {
            \\    pub const save = @import("labelle-core").Saveable(.saveable, @This(), .{
            \\        .entity_refs = &.{"owner"},
            \\    });
            \\    owner: u64 = 0,
            \\    target: ?u64 = null,
            \\    pos: Vec2 = .{},
            \\    label: []const u8 = "",
            \\    hp: f32 = 100,
            \\    docked: bool = false,
            \\};
        );
        try writeFileIn(game_root, "engine-fixture/codegen/main.zig.template", engine_template);
        const game_abs = try tmp.dir.realPathFileAlloc(io, "game", allocator);
        errdefer allocator.free(game_abs);
        const out_abs = try tmp.dir.realPathFileAlloc(io, "out", allocator);
        return .{ .tmp = tmp, .game_abs = game_abs, .out_abs = out_abs };
    }

    fn deinit(self: *StagedTranspileProject, allocator: std.mem.Allocator) void {
        allocator.free(self.game_abs);
        allocator.free(self.out_abs);
        self.tmp.cleanup();
    }

    /// Stage an executable fake tsc and point `tsc_tool_override` at it
    /// (caller clears the override). The happy fake honors the REAL
    /// invocation contract — `<tool> -p <tsconfig>` — by pulling
    /// `outDir` out of the generated tsconfig (its rendering is a unit
    /// golden, so the extraction can't drift silently) and emitting a
    /// known `.js` there, exactly where the real tsc 7.0.2 emits.
    fn stageFakeTsc(self: *StagedTranspileProject, allocator: std.mem.Allocator, body: []const u8) ![:0]const u8 {
        var f = try self.tmp.dir.createFile(io, "fake-tsc", .{ .permissions = .executable_file });
        defer f.close(io);
        try f.writeStreamingAll(io, body);
        return self.tmp.dir.realPathFileAlloc(io, "fake-tsc", allocator);
    }

    fn config(self: *StagedTranspileProject, backend_repo: []const u8) generate.ProjectConfig {
        _ = self;
        return .{
            .name = "transpile-game",
            .backend = .sokol,
            .backend_package = .{ .name = "sokol", .repo = backend_repo },
            .ecs = .mock,
            .engine_version = "local:engine-fixture",
            .y_axis = .up,
            .plugins = &.{
                .{ .name = "scripting", .repo = "local:plugins/scripting", .params = .{ .language = "typescript" } },
            },
        };
    }
};

/// The happy fake: `$1` must be `-p` (the invocation contract), emit
/// `enemy.js` into the tsconfig's `outDir`.
const happy_fake_tsc =
    \\#!/bin/sh
    \\[ "$1" = "-p" ] || exit 3
    \\out=$(sed -n 's/^ *"outDir": "\(.*\)".*$/\1/p' "$2")
    \\[ -n "$out" ] || exit 4
    \\printf 'export function update(dt) { /* emitted-by-fake-tsc */ }\n' > "$out/enemy.js"
    \\exit 0
    \\
;

/// The type-error fake: a tsc-shaped diagnostic on STDOUT (where the
/// real tsc prints), nonzero exit, nothing emitted (noEmitOnError).
const type_error_fake_tsc =
    \\#!/bin/sh
    \\echo "ts/enemy.ts(1,34): error TS2551: Property 'levl' does not exist on type '{ level: number; }'. Did you mean 'level'?"
    \\exit 2
    \\
;

/// The poison fake: reaching the tool AT ALL is the failure.
const poison_fake_tsc =
    \\#!/bin/sh
    \\echo "poison fake tsc MUST NOT RUN" >&2
    \\exit 1
    \\
;

/// The in-tree sokol backend fixture as an ABSOLUTE `local:` repo (staged
/// games live in tmp dirs, so the repo-relative spelling can't resolve).
fn sokolFixtureRepoAbs(allocator: std.mem.Allocator) ![]const u8 {
    const abs = try std.Io.Dir.cwd().realPathFileAlloc(io, "backends/sokol", allocator);
    defer allocator.free(abs);
    return std.fmt.allocPrint(allocator, "local:{s}", .{abs});
}

/// Read the generated tsconfig's `files` array back as parsed JSON —
/// the assertion surface for the contract-row tests.
fn readTsconfigFiles(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, parsed_out: *std.json.Parsed(std.json.Value)) !std.json.Array {
    const bytes = try tmp.dir.readFileAlloc(io, "out/sokol_desktop/tsconfig.json", allocator, .limited(1 << 20));
    defer allocator.free(bytes);
    parsed_out.* = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    return parsed_out.value.object.get("files").?.array;
}

fn filesContainSuffix(files: std.json.Array, suffix: []const u8) bool {
    for (files.items) |item| {
        if (std.mem.endsWith(u8, item.string, suffix)) return true;
    }
    return false;
}

pub const TRANSPILE_E2E = struct {
    test "a ts/enemy.ts project transpiles end to end: materialized dir, emitted embed, generated d.ts + tsconfig" {
        const allocator = std.testing.allocator;
        var staged = try StagedTranspileProject.init(allocator);
        defer staged.deinit(allocator);
        var game_root = try staged.tmp.dir.openDir(io, "game", .{});
        defer game_root.close(io);
        // The game carries its OWN contract copy — the package's must
        // then stay OUT of the tsconfig (duplicate globals).
        try writeFileIn(game_root, "ts/labelle.d.ts", "declare const labelle: any;\n");

        const fake = try staged.stageFakeTsc(allocator, happy_fake_tsc);
        defer allocator.free(fake);
        generate.scripting_transpile.tsc_tool_override = fake;
        defer generate.scripting_transpile.tsc_tool_override = null;

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false });

        // The target's script dir MATERIALIZED: a real directory now, not
        // the linkAndScan symlink (readLink refuses a real dir).
        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        try std.testing.expectError(
            error.NotLink,
            staged.tmp.dir.readLink(io, "out/sokol_desktop/ts", &link_buf),
        );

        // Copied plain script + fake-emitted transpile output, side by side.
        const behavior = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/ts/behavior.js", allocator, .limited(4096));
        defer allocator.free(behavior);
        _ = try indexOfOrFail(behavior, "// @ts-check");
        const enemy = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/ts/enemy.js", allocator, .limited(4096));
        defer allocator.free(enemy);
        _ = try indexOfOrFail(enemy, "emitted-by-fake-tsc");

        // The generated main registers BOTH (sorted stems), embedding
        // from the materialized dir — and no `.ts` embed anywhere.
        const main_zig = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/main.zig", allocator, .limited(1 << 20));
        defer allocator.free(main_zig);
        const reg_behavior = try indexOfOrFail(main_zig, "scripting.registerScript(\"behavior\", @embedFile(\"ts/behavior.js\"));");
        const reg_enemy = try indexOfOrFail(main_zig, "scripting.registerScript(\"enemy\", @embedFile(\"ts/enemy.js\"));");
        try std.testing.expect(reg_behavior < reg_enemy);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".ts\")") == null);

        // The generated d.ts sits next to the copied scripts and maps the
        // game component's REAL field shapes (bigint ids, `| null`
        // optionals, vec2 object, string, number, boolean) under the
        // quoted registry key, plus the Entity class-merge overloads.
        const dts = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/ts/labelle-components.d.ts", allocator, .limited(64 * 1024));
        defer allocator.free(dts);
        _ = try indexOfOrFail(dts, "\"Ship\": { owner: bigint; target: bigint | null; pos: { x: number; y: number }; label: string; hp: number; docked: boolean };");
        _ = try indexOfOrFail(dts, "interface Entity {");
        _ = try indexOfOrFail(dts, "get<K extends keyof LabelleComponents>(name: K): LabelleComponents[K] | null;");

        // The tsconfig at the target root: game sources in, the game's
        // OWN labelle.d.ts copy in, the generated d.ts in — and the
        // PACKAGE contract OUT (the game copy supersedes it).
        var parsed: std.json.Parsed(std.json.Value) = undefined;
        const files = try readTsconfigFiles(allocator, &staged.tmp, &parsed);
        defer parsed.deinit();
        try std.testing.expect(filesContainSuffix(files, "ts/enemy.ts"));
        try std.testing.expect(filesContainSuffix(files, "ts/labelle.d.ts"));
        try std.testing.expect(filesContainSuffix(files, "ts/labelle-components.d.ts"));
        try std.testing.expect(!filesContainSuffix(files, "contract/labelle.d.ts"));
    }

    test "without a game-side labelle.d.ts the STAGED package's contract/labelle.d.ts joins the tsconfig" {
        const allocator = std.testing.allocator;
        var staged = try StagedTranspileProject.init(allocator);
        defer staged.deinit(allocator);
        // No ts/labelle.d.ts here — the fixture plugin ships contract/.

        const fake = try staged.stageFakeTsc(allocator, happy_fake_tsc);
        defer allocator.free(fake);
        generate.scripting_transpile.tsc_tool_override = fake;
        defer generate.scripting_transpile.tsc_tool_override = null;

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false });

        var parsed: std.json.Parsed(std.json.Value) = undefined;
        const files = try readTsconfigFiles(allocator, &staged.tmp, &parsed);
        defer parsed.deinit();
        try std.testing.expect(filesContainSuffix(files, "contract/labelle.d.ts"));
        // …resolved through the STAGED deps copy, never the raw plugin
        // checkout (the declare phase's staged-first resolution).
        var found_staged = false;
        for (files.items) |item| {
            if (std.mem.indexOf(u8, item.string, "deps/labelle-scripting") != null) found_staged = true;
        }
        try std.testing.expect(found_staged);
    }

    test "a type error fails generate with ScriptTypecheckFailed (fake tsc relays the tsc-shaped diagnostic)" {
        const allocator = std.testing.allocator;
        var staged = try StagedTranspileProject.init(allocator);
        defer staged.deinit(allocator);

        const fake = try staged.stageFakeTsc(allocator, type_error_fake_tsc);
        defer allocator.free(fake);
        generate.scripting_transpile.tsc_tool_override = fake;
        defer generate.scripting_transpile.tsc_tool_override = null;

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try std.testing.expectError(
            error.ScriptTypecheckFailed,
            generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false }),
        );
        // noEmitOnError + the failure: no emitted enemy.js reached the
        // materialized dir (only the copied plain script is there).
        try std.testing.expectError(
            error.FileNotFound,
            staged.tmp.dir.access(io, "out/sokol_desktop/ts/enemy.js", .{}),
        );
    }

    test "a .js-only project skips the phase entirely: poison tool never runs, symlink layout intact, nothing generated" {
        const allocator = std.testing.allocator;
        var staged = try StagedTranspileProject.init(allocator);
        defer staged.deinit(allocator);
        var game_root = try staged.tmp.dir.openDir(io, "game", .{});
        defer game_root.close(io);
        // Remove the .ts source → a plain .js-only typescript project.
        try game_root.deleteFile(io, "ts/enemy.ts");

        // POISON: the phase consulting the tool AT ALL fails generate —
        // and since tool resolution (and therefore the fetch) sits
        // BEHIND the need probe, a passing generate here is the pin that
        // .js-only projects never fetch the toolchain.
        const fake = try staged.stageFakeTsc(allocator, poison_fake_tsc);
        defer allocator.free(fake);
        generate.scripting_transpile.tsc_tool_override = fake;
        defer generate.scripting_transpile.tsc_tool_override = null;

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false });

        // The pre-#745 layout, byte-for-byte: the script dir is STILL the
        // linkAndScan symlink, and no transpile artifacts exist.
        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        _ = try staged.tmp.dir.readLink(io, "out/sokol_desktop/ts", &link_buf);
        try std.testing.expectError(
            error.FileNotFound,
            staged.tmp.dir.access(io, "out/sokol_desktop/tsconfig.json", .{}),
        );
        try std.testing.expectError(
            error.FileNotFound,
            staged.tmp.dir.access(io, "game/ts/labelle-components.d.ts", .{}),
        );
        const main_zig = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/main.zig", allocator, .limited(1 << 20));
        defer allocator.free(main_zig);
        _ = try indexOfOrFail(main_zig, "scripting.registerScript(\"behavior\", @embedFile(\"ts/behavior.js\"));");
    }

    test "a same-stem .ts/.js pair fails generate BEFORE the tool runs (poison override untouched)" {
        const allocator = std.testing.allocator;
        var staged = try StagedTranspileProject.init(allocator);
        defer staged.deinit(allocator);
        var game_root = try staged.tmp.dir.openDir(io, "game", .{});
        defer game_root.close(io);
        // enemy.ts already exists — author the stale twin.
        try writeFileIn(game_root, "ts/enemy.js", "export function update(dt) {}\n");

        const fake = try staged.stageFakeTsc(allocator, poison_fake_tsc);
        defer allocator.free(fake);
        generate.scripting_transpile.tsc_tool_override = fake;
        defer generate.scripting_transpile.tsc_tool_override = null;

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try std.testing.expectError(
            error.ScriptTranspileCollision,
            generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false }),
        );
    }

    test "removing every .ts restores the pre-transpile layout on the next generate (stale artifacts dropped)" {
        const allocator = std.testing.allocator;
        var staged = try StagedTranspileProject.init(allocator);
        defer staged.deinit(allocator);
        var game_root = try staged.tmp.dir.openDir(io, "game", .{});
        defer game_root.close(io);
        try writeFileIn(game_root, "ts/labelle.d.ts", "declare const labelle: any;\n");

        const fake = try staged.stageFakeTsc(allocator, happy_fake_tsc);
        defer allocator.free(fake);
        generate.scripting_transpile.tsc_tool_override = fake;
        defer generate.scripting_transpile.tsc_tool_override = null;

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);

        // Pass 1: transpiling state — materialized dir + tsconfig.
        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false });
        try staged.tmp.dir.access(io, "out/sokol_desktop/tsconfig.json", .{});
        try staged.tmp.dir.access(io, "out/sokol_desktop/ts/enemy.js", .{});

        // Pass 2: the author deletes the .ts — the phase skips, the
        // script-dir link reconciles back, the stale tsconfig is dropped,
        // and the emitted enemy.js is GONE (it lived only in the
        // materialized dir, which the re-link replaced).
        try game_root.deleteFile(io, "ts/enemy.ts");
        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false });

        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        _ = try staged.tmp.dir.readLink(io, "out/sokol_desktop/ts", &link_buf);
        try std.testing.expectError(
            error.FileNotFound,
            staged.tmp.dir.access(io, "out/sokol_desktop/tsconfig.json", .{}),
        );
        try std.testing.expectError(
            error.FileNotFound,
            staged.tmp.dir.access(io, "out/sokol_desktop/ts/enemy.js", .{}),
        );
        const main_zig = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/main.zig", allocator, .limited(1 << 20));
        defer allocator.free(main_zig);
        _ = try indexOfOrFail(main_zig, "scripting.registerScript(\"behavior\", @embedFile(\"ts/behavior.js\"));");
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "registerScript(\"enemy\"") == null);
    }
};
