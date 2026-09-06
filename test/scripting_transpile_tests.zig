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
//!   1. a `scripts/*.ts` project transpiles end to end — the target's
//!      shared script dir MATERIALIZES (symlink → real dir, the game's
//!      ZIG scripts riding the copy so their generated imports keep
//!      resolving — the #237 shared-dir pin), the fake tsc's emitted
//!      `.js` embeds beside the copied plain `.js`, the generated
//!      `labelle-components.d.ts` + `tsconfig.json` land where the
//!      design says (and the d.ts is NEVER collected as a script), and
//!      the tsconfig's `files` list is exactly right (game sources; the
//!      game's OWN labelle.d.ts copy suppressing the package contract —
//!      and the package contract present when the game has no copy);
//!   2. a type error (fake tsc exits nonzero) FAILS generate — the
//!      ticket's acceptance criterion;
//!   3. a `.js`-only project SKIPS the whole phase — poison override
//!      never invoked, symlink layout intact, no generated files: the
//!      no-fetch pin (the probe precedes tool resolution);
//!   4. a `.ts`/`.js` same-stem collision fails BEFORE the tool runs;
//!   5. removing every `.ts` restores the pre-transpile layout (stale
//!      tsconfig dropped, symlink back, only plain scripts registered);
//!   6. transpiled output rides the scripts/ ORDERING convention —
//!      `10_a.ts` + `20_b.ts` register prefix-ordered with STRIPPED
//!      stems (#237 over #745);
//!   7. the LEGACY `ts/` grace dir still transpiles this release —
//!      pre-#237 plain stems, ts/-rooted embeds.

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
/// tsconfig row is exercisable), a `scripts/` dir holding a plain `.js`
/// script, a `.ts` script AND coexisting Zig scripts (top-level + state
/// subdir — the #237 shared structure), a component file (the d.ts
/// provider), the engine template fixture (exe main.zig emission), and
/// `out/`.
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
        try writeFileIn(game_root, "scripts/behavior.js",
            \\// @ts-check
            \\export function update(dt) {}
        );
        try writeFileIn(game_root, "scripts/enemy.ts",
            \\export function update(dt: number): void {}
        );
        // The ZIG layer sharing the dir (extension-keyed coexistence):
        // the transpile materialization must keep BOTH reachable in the
        // target, or the generated @import("scripts/…")s break.
        try writeFileIn(game_root, "scripts/01_move.zig", "pub fn tick() void {}\n");
        try writeFileIn(game_root, "scripts/playing/02_hud.zig", "pub fn tick() void {}\n");
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

    /// One file a fake tsc emits, relative to the tsconfig's `outDir`.
    ///
    /// `when_config_suffix` / `unless_config_suffix` gate it on which
    /// tsconfig the tool was handed (the declare pass and the script pass
    /// use different ones); both empty means always.
    const Emit = struct {
        when_config_suffix: []const u8 = "",
        unless_config_suffix: []const u8 = "",
        rel: []const u8,
        body: []const u8,
    };

    /// Stage an executable fake tsc and return its absolute path.
    ///
    /// Honors the REAL invocation contract — `<tool> -p <tsconfig>` — by
    /// pulling `outDir` out of the generated tsconfig (its rendering is a
    /// unit golden, so the extraction cannot drift silently) and emitting
    /// `emit` there, exactly where the real tsc 7.0.2 emits.
    ///
    /// Generated from `emit` rather than hand-written per test, because it
    /// has to exist twice. A `#!/bin/sh` script is not executable on
    /// Windows — no shebang, so `CreateProcess` fails with
    /// `error.InvalidExe` — and the whole transpile suite failed for a
    /// reason unrelated to what it tests (#699).
    ///
    /// The Windows side is a `.cmd`, which Zig's spawn does run, written in
    /// PURE batch — no PowerShell. A first cut delegated to a `.ps1`, and
    /// that failed in a way worth recording: under `zig build test` the
    /// spawned child's environment is stripped enough that .NET cannot
    /// initialise ("Loading managed Windows PowerShell failed with error
    /// 8009001d"), and PowerShell then exits `-65536` = `0xFFFF0000`, whose
    /// low 16 bits are ZERO — so the failure came back as exit 0 and the
    /// assembler reported a successful transpile that emitted nothing.
    /// Batch needs no runtime and cannot fail that way.
    ///
    /// Batch can parse the tsconfig because `writeJsonPath` emits `outDir`
    /// with FORWARD slashes and no escaping, on one line of its own; the
    /// stub splits that line at its first `:` and strips the quotes.
    fn stageEmittingFakeTsc(dir: std.Io.Dir, allocator: std.mem.Allocator, emit: []const Emit) ![:0]const u8 {
        const windows = @import("builtin").os.tag == .windows;
        const dir_abs = try dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(dir_abs);

        // Every emitted body travels as a FILE the stub copies, never as a
        // literal inside the script. The bodies end in a newline, and a
        // PowerShell single-quoted string cannot span lines — inlining them
        // produced a stub that parsed as garbage and exited 49 instead of
        // emitting anything. Files sidestep quoting in both shells.
        for (emit, 0..) |e, i| {
            const payload = try std.fmt.allocPrint(allocator, "fake-tsc.emit{d}", .{i});
            defer allocator.free(payload);
            var pf = try dir.createFile(io, payload, .{});
            defer pf.close(io);
            try pf.writeStreamingAll(io, e.body);
        }

        var body_aw = std.Io.Writer.Allocating.init(allocator);
        defer body_aw.deinit();
        const w = &body_aw.writer;

        if (windows) {
            try w.writeAll("@echo off\r\n");
            try w.writeAll("if not \"%~1\"==\"-p\" exit /b 3\r\n");
            try w.writeAll("set \"CFG=%~2\"\r\n");
            // Builtins ONLY — no `findstr`. It is an external exe, and the
            // stripped child PATH that hid PowerShell hides it too (the
            // first cut used it and every test exited 4, "outDir missing").
            //
            // `for /f` reads the tsconfig line by line with `:` and space as
            // delimiters, so the key line `    "outDir": "C:/x/y"` yields
            // token 1 `"outDir"` and remainder `"C:/x/y"`; the `~` modifier
            // strips the quotes from each. The drive colon survives because
            // the remainder is taken verbatim after the first delimiter.
            try w.writeAll("set \"OUT=\"\r\n");
            try w.writeAll("for /f \"usebackq tokens=1,* delims=: \" %%A in (\"%~2\") do if \"%%~A\"==\"outDir\" set \"OUT=%%~B\"\r\n");
            try w.writeAll("if not defined OUT exit /b 4\r\n");
            try w.writeAll("set \"OUT=%OUT:/=\\%\"\r\n");
            for (emit, 0..) |e, i| {
                // Gate on the tsconfig NAME by comparing its last N chars, so
                // `tsconfig.declare.json` matches only the declare pass.
                if (e.when_config_suffix.len > 0) {
                    try w.print("if not \"%CFG:~-{d}%\"==\"{s}\" goto emit_skip_{d}\r\n", .{ e.when_config_suffix.len, e.when_config_suffix, i });
                }
                if (e.unless_config_suffix.len > 0) {
                    try w.print("if \"%CFG:~-{d}%\"==\"{s}\" goto emit_skip_{d}\r\n", .{ e.unless_config_suffix.len, e.unless_config_suffix, i });
                }
                const rel_win = try allocator.dupe(u8, e.rel);
                defer allocator.free(rel_win);
                std.mem.replaceScalar(u8, rel_win, '/', '\\');
                // A failed emit must FAIL the stub. Batch does not stop on
                // error, so without the `||` an unwritable outDir reached the
                // final `exit /b 0` and the assembler reported a successful
                // transpile that produced nothing — the same misleading shape
                // the PowerShell cut had (#699 review). Exit 5 is outside the
                // real tsc's codes, so it reads as a fixture fault.
                if (std.fs.path.dirnameWindows(rel_win)) |rel_dir| {
                    try w.print("if not exist \"%OUT%\\{s}\\\" mkdir \"%OUT%\\{s}\" || exit /b 5\r\n", .{ rel_dir, rel_dir });
                }
                try w.print("copy /y \"{s}\\fake-tsc.emit{d}\" \"%OUT%\\{s}\" >nul || exit /b 5\r\n", .{ dir_abs, i, rel_win });
                try w.print(":emit_skip_{d}\r\n", .{i});
            }
            try w.writeAll("exit /b 0\r\n");
        } else {
            try w.writeAll("#!/bin/sh\n");
            try w.writeAll("[ \"$1\" = \"-p\" ] || exit 3\n");
            try w.writeAll("out=$(sed -n 's/^ *\"outDir\": \"\\(.*\\)\".*$/\\1/p' \"$2\")\n");
            try w.writeAll("[ -n \"$out\" ] || exit 4\n");
            for (emit, 0..) |e, i| {
                const gated = e.when_config_suffix.len > 0 or e.unless_config_suffix.len > 0;
                if (e.when_config_suffix.len > 0) {
                    try w.print("case \"$2\" in *{s})\n", .{e.when_config_suffix});
                }
                if (e.unless_config_suffix.len > 0) {
                    try w.print("case \"$2\" in *{s}) ;; *)\n", .{e.unless_config_suffix});
                }
                try w.print("mkdir -p \"$(dirname \"$out/{s}\")\"\n", .{e.rel});
                try w.print("cat \"{s}/fake-tsc.emit{d}\" > \"$out/{s}\"\n", .{ dir_abs, i, e.rel });
                if (gated) try w.writeAll(";; esac\n");
            }
            try w.writeAll("exit 0\n");
        }

        return stageToolScript(dir, allocator, "fake-tsc", body_aw.written());
    }

    /// Write `body` as an executable named `name` (`.cmd` on Windows) and
    /// return its absolute path.
    fn stageToolScript(dir: std.Io.Dir, allocator: std.mem.Allocator, name: []const u8, body: []const u8) ![:0]const u8 {
        const windows = @import("builtin").os.tag == .windows;
        const script_name = if (windows)
            try std.fmt.allocPrint(allocator, "{s}.cmd", .{name})
        else
            try allocator.dupe(u8, name);
        defer allocator.free(script_name);

        var f = try dir.createFile(io, script_name, .{ .permissions = .executable_file });
        defer f.close(io);
        try f.writeStreamingAll(io, body);
        return dir.realPathFileAlloc(io, script_name, allocator);
    }

    /// A fake declare runner that RECORDS its argv (one per line, to
    /// `recorded-args.txt` beside the fixture) and then prints
    /// `schema_json`. Same portable shape as the transpile stubs: the schema
    /// travels as a payload file, because it is JSON and `cmd` mangles `"`,
    /// `<`, `>`, `&` and `|`; batch has no `printf "%s\n" "$@"`, so the
    /// argv walk is a `shift` loop (#699).
    fn stageRecordingFakeDeclare(dir: std.Io.Dir, allocator: std.mem.Allocator, schema_json: []const u8) ![:0]const u8 {
        const windows = @import("builtin").os.tag == .windows;
        const dir_abs = try dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(dir_abs);

        {
            var f = try dir.createFile(io, "fake-declare.out", .{});
            defer f.close(io);
            try f.writeStreamingAll(io, schema_json);
        }

        var body_aw = std.Io.Writer.Allocating.init(allocator);
        defer body_aw.deinit();
        const w = &body_aw.writer;
        if (windows) {
            try w.writeAll("@echo off\r\n");
            try w.writeAll("setlocal enabledelayedexpansion\r\n");
            try w.print("break > \"{s}\\recorded-args.txt\"\r\n", .{dir_abs});
            try w.writeAll(":labelle_loop\r\n");
            try w.writeAll("if \"%~1\"==\"\" goto labelle_done\r\n");
            // Captured in quotes, echoed via delayed expansion: a `&`, `(`
            // or `|` in the path must be recorded, not parsed (#699 review).
            try w.writeAll("set \"ARG=%~1\"\r\n");
            try w.print("echo(!ARG!>> \"{s}\\recorded-args.txt\"\r\n", .{dir_abs});
            try w.writeAll("shift\r\n");
            try w.writeAll("goto labelle_loop\r\n");
            try w.writeAll(":labelle_done\r\n");
            try w.print("type \"{s}\\fake-declare.out\"\r\n", .{dir_abs});
            try w.writeAll("exit /b 0\r\n");
        } else {
            try w.writeAll("#!/bin/sh\n");
            try w.print("printf '%s\\n' \"$@\" > \"{s}/recorded-args.txt\"\n", .{dir_abs});
            try w.print("cat \"{s}/fake-declare.out\"\n", .{dir_abs});
            try w.writeAll("exit 0\n");
        }
        return stageToolScript(dir, allocator, "fake-declare", body_aw.written());
    }

    /// A fake tsc that only reports — no emit. `stdout_text` goes to stdout
    /// (where the real tsc prints diagnostics), `stderr_text` to stderr,
    /// then it exits `code`.
    fn stageReportingFakeTsc(dir: std.Io.Dir, allocator: std.mem.Allocator, stdout_text: []const u8, stderr_text: []const u8, code: u8) ![:0]const u8 {
        const windows = @import("builtin").os.tag == .windows;
        const dir_abs = try dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(dir_abs);

        // Payloads travel through files: the diagnostics carry `'`, `"`,
        // `(`, `)` and `{`, which neither `cmd` nor `sh` quotes the same way.
        {
            var f = try dir.createFile(io, "fake-tsc.out", .{});
            defer f.close(io);
            try f.writeStreamingAll(io, stdout_text);
        }
        {
            var f = try dir.createFile(io, "fake-tsc.err", .{});
            defer f.close(io);
            try f.writeStreamingAll(io, stderr_text);
        }

        var body_aw = std.Io.Writer.Allocating.init(allocator);
        defer body_aw.deinit();
        const w = &body_aw.writer;
        if (windows) {
            try w.writeAll("@echo off\r\n");
            if (stdout_text.len > 0) try w.print("type \"{s}\\fake-tsc.out\"\r\n", .{dir_abs});
            if (stderr_text.len > 0) try w.print("type \"{s}\\fake-tsc.err\" 1>&2\r\n", .{dir_abs});
            try w.print("exit /b {d}\r\n", .{code});
        } else {
            try w.writeAll("#!/bin/sh\n");
            if (stdout_text.len > 0) try w.print("cat \"{s}/fake-tsc.out\"\n", .{dir_abs});
            if (stderr_text.len > 0) try w.print("cat \"{s}/fake-tsc.err\" 1>&2\n", .{dir_abs});
            try w.print("exit {d}\n", .{code});
        }
        return stageToolScript(dir, allocator, "fake-tsc", body_aw.written());
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

/// The happy fake: emits the one `.js` the script pass expects, into the
/// tsconfig's `outDir`.
const happy_emit = [_]StagedTranspileProject.Emit{
    .{ .rel = "enemy.js", .body = "export function update(dt) { /* emitted-by-fake-tsc */ }\n" },
};

/// The type-error fake's diagnostic: tsc-shaped, on STDOUT (where the real
/// tsc prints), nonzero exit, nothing emitted (noEmitOnError).
const type_error_stdout =
    "scripts/enemy.ts(1,34): error TS2551: Property 'levl' does not exist on type '{ level: number; }'. Did you mean 'level'?\n";

/// The poison fake: reaching the tool AT ALL is the failure.
const poison_stderr = "poison fake tsc MUST NOT RUN\n";

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
    test "a scripts/enemy.ts project transpiles end to end: materialized dir (Zig scripts riding), emitted embed, generated d.ts + tsconfig" {
        const allocator = std.testing.allocator;
        var staged = try StagedTranspileProject.init(allocator);
        defer staged.deinit(allocator);
        var game_root = try staged.tmp.dir.openDir(io, "game", .{});
        defer game_root.close(io);
        // The game carries its OWN contract copy — the package's must
        // then stay OUT of the tsconfig (duplicate globals).
        try writeFileIn(game_root, "scripts/labelle.d.ts", "declare const labelle: any;\n");
        // A components-dir language file (#237 refinement): must survive
        // the transpile swap and stay registered FIRST.
        try writeFileIn(game_root, "components/glue.js", "export const GLUE = 1;\n");

        const fake = try StagedTranspileProject.stageEmittingFakeTsc(staged.tmp.dir, allocator, &happy_emit);
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
            staged.tmp.dir.readLink(io, "out/sokol_desktop/scripts", &link_buf),
        );

        // THE SHARED-DIR PIN (#237 over #745): the game's ZIG scripts —
        // top-level AND state-subdir — survived the materialization, so
        // the generated `@import("scripts/…")`s still resolve in the
        // target tree.
        try staged.tmp.dir.access(io, "out/sokol_desktop/scripts/01_move.zig", .{});
        try staged.tmp.dir.access(io, "out/sokol_desktop/scripts/playing/02_hud.zig", .{});

        // Copied plain script + fake-emitted transpile output, side by side.
        const behavior = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/scripts/behavior.js", allocator, .limited(4096));
        defer allocator.free(behavior);
        _ = try indexOfOrFail(behavior, "// @ts-check");
        const enemy = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/scripts/enemy.js", allocator, .limited(4096));
        defer allocator.free(enemy);
        _ = try indexOfOrFail(enemy, "emitted-by-fake-tsc");

        // The generated main registers BOTH (collection order), embedding
        // from the materialized dir — no `.ts` embed anywhere, and the
        // Zig scripts never leak into the language layer.
        const main_zig = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/main.zig", allocator, .limited(1 << 20));
        defer allocator.free(main_zig);
        const reg_behavior = try indexOfOrFail(main_zig, "scripting.registerScript(\"behavior\", @embedFile(\"scripts/behavior.js\"));");
        const reg_enemy = try indexOfOrFail(main_zig, "scripting.registerScript(\"enemy\", @embedFile(\"scripts/enemy.js\"));");
        try std.testing.expect(reg_behavior < reg_enemy);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".ts\")") == null);
        // The components-dir entry SURVIVED the post-transpile swap (the
        // re-collection replaces only the script-dir entries) and keeps
        // the components-first registration slot.
        const reg_glue = try indexOfOrFail(main_zig, "scripting.registerScript(\"glue\", @embedFile(\"components/glue.js\"));");
        try std.testing.expect(reg_glue < reg_behavior);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "registerScript(\"move\"") == null);
        // The generated declarations are typecheck INPUT, never a script:
        // no registration mentions them (their .d.ts suffix can't match
        // the .js collection).
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "labelle-components") == null);

        // The generated d.ts sits next to the copied scripts and maps the
        // game component's REAL field shapes (bigint ids, `| null`
        // optionals, vec2 object, string, number, boolean) under the
        // quoted registry key, plus the Entity class-merge overloads.
        const dts = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/scripts/labelle-components.d.ts", allocator, .limited(64 * 1024));
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
        try std.testing.expect(filesContainSuffix(files, "scripts/enemy.ts"));
        try std.testing.expect(filesContainSuffix(files, "scripts/labelle.d.ts"));
        try std.testing.expect(filesContainSuffix(files, "scripts/labelle-components.d.ts"));
        try std.testing.expect(!filesContainSuffix(files, "contract/labelle.d.ts"));
    }

    test "without a game-side labelle.d.ts the STAGED package's contract/labelle.d.ts joins the tsconfig" {
        const allocator = std.testing.allocator;
        var staged = try StagedTranspileProject.init(allocator);
        defer staged.deinit(allocator);
        // No ts/labelle.d.ts here — the fixture plugin ships contract/.

        const fake = try StagedTranspileProject.stageEmittingFakeTsc(staged.tmp.dir, allocator, &happy_emit);
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

        const fake = try StagedTranspileProject.stageReportingFakeTsc(staged.tmp.dir, allocator, type_error_stdout, "", 2);
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
            staged.tmp.dir.access(io, "out/sokol_desktop/scripts/enemy.js", .{}),
        );
    }

    test "a .js-only project skips the phase entirely: poison tool never runs, symlink layout intact, nothing generated" {
        const allocator = std.testing.allocator;
        var staged = try StagedTranspileProject.init(allocator);
        defer staged.deinit(allocator);
        var game_root = try staged.tmp.dir.openDir(io, "game", .{});
        defer game_root.close(io);
        // Remove the .ts source → a plain .js-only typescript project.
        try game_root.deleteFile(io, "scripts/enemy.ts");

        // POISON: the phase consulting the tool AT ALL fails generate —
        // and since tool resolution (and therefore the fetch) sits
        // BEHIND the need probe, a passing generate here is the pin that
        // .js-only projects never fetch the toolchain.
        const fake = try StagedTranspileProject.stageReportingFakeTsc(staged.tmp.dir, allocator, "", poison_stderr, 1);
        defer allocator.free(fake);
        generate.scripting_transpile.tsc_tool_override = fake;
        defer generate.scripting_transpile.tsc_tool_override = null;

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false });

        // The pre-#745 layout, byte-for-byte: the script dir is STILL the
        // linkAndScan symlink (the Zig scanner's shared link), and no
        // transpile artifacts exist — in the target OR through the link
        // into the game tree.
        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        _ = try staged.tmp.dir.readLink(io, "out/sokol_desktop/scripts", &link_buf);
        try std.testing.expectError(
            error.FileNotFound,
            staged.tmp.dir.access(io, "out/sokol_desktop/tsconfig.json", .{}),
        );
        try std.testing.expectError(
            error.FileNotFound,
            staged.tmp.dir.access(io, "game/scripts/labelle-components.d.ts", .{}),
        );
        const main_zig = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/main.zig", allocator, .limited(1 << 20));
        defer allocator.free(main_zig);
        _ = try indexOfOrFail(main_zig, "scripting.registerScript(\"behavior\", @embedFile(\"scripts/behavior.js\"));");
    }

    test "a same-stem .ts/.js pair fails generate BEFORE the tool runs (poison override untouched)" {
        const allocator = std.testing.allocator;
        var staged = try StagedTranspileProject.init(allocator);
        defer staged.deinit(allocator);
        var game_root = try staged.tmp.dir.openDir(io, "game", .{});
        defer game_root.close(io);
        // enemy.ts already exists — author the stale twin.
        try writeFileIn(game_root, "scripts/enemy.js", "export function update(dt) {}\n");

        const fake = try StagedTranspileProject.stageReportingFakeTsc(staged.tmp.dir, allocator, "", poison_stderr, 1);
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
        try writeFileIn(game_root, "scripts/labelle.d.ts", "declare const labelle: any;\n");

        const fake = try StagedTranspileProject.stageEmittingFakeTsc(staged.tmp.dir, allocator, &happy_emit);
        defer allocator.free(fake);
        generate.scripting_transpile.tsc_tool_override = fake;
        defer generate.scripting_transpile.tsc_tool_override = null;

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);

        // Pass 1: transpiling state — materialized dir + tsconfig.
        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false });
        try staged.tmp.dir.access(io, "out/sokol_desktop/tsconfig.json", .{});
        try staged.tmp.dir.access(io, "out/sokol_desktop/scripts/enemy.js", .{});

        // Pass 2: the author deletes the .ts — the phase skips, the
        // script-dir link reconciles back, the stale tsconfig is dropped,
        // and the emitted enemy.js is GONE (it lived only in the
        // materialized dir, which the re-link replaced).
        try game_root.deleteFile(io, "scripts/enemy.ts");
        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false });

        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        _ = try staged.tmp.dir.readLink(io, "out/sokol_desktop/scripts", &link_buf);
        try std.testing.expectError(
            error.FileNotFound,
            staged.tmp.dir.access(io, "out/sokol_desktop/tsconfig.json", .{}),
        );
        try std.testing.expectError(
            error.FileNotFound,
            staged.tmp.dir.access(io, "out/sokol_desktop/scripts/enemy.js", .{}),
        );
        const main_zig = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/main.zig", allocator, .limited(1 << 20));
        defer allocator.free(main_zig);
        _ = try indexOfOrFail(main_zig, "scripting.registerScript(\"behavior\", @embedFile(\"scripts/behavior.js\"));");
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "registerScript(\"enemy\"") == null);
    }

    test "transpiled output rides the ordering convention: 10_a.ts + 20_b.ts register prefix-ordered with STRIPPED stems" {
        const allocator = std.testing.allocator;
        var staged = try StagedTranspileProject.init(allocator);
        defer staged.deinit(allocator);
        var game_root = try staged.tmp.dir.openDir(io, "game", .{});
        defer game_root.close(io);
        // Replace the default fixture sources with the ordered pair (the
        // ticket's shape): the FILES keep their prefixes end to end, the
        // registered stems drop them — through transpile, not around it.
        try game_root.deleteFile(io, "scripts/enemy.ts");
        try game_root.deleteFile(io, "scripts/behavior.js");
        try writeFileIn(game_root, "scripts/20_b.ts", "export function update(dt: number): void {}\n");
        try writeFileIn(game_root, "scripts/10_a.ts", "export function update(dt: number): void {}\n");

        // A fake tsc that emits BOTH prefix-named outputs into outDir.
        const ordering_emit = [_]StagedTranspileProject.Emit{
            .{ .rel = "10_a.js", .body = "export function update(dt) {}\n" },
            .{ .rel = "20_b.js", .body = "export function update(dt) {}\n" },
        };
        const fake = try StagedTranspileProject.stageEmittingFakeTsc(staged.tmp.dir, allocator, &ordering_emit);
        defer allocator.free(fake);
        generate.scripting_transpile.tsc_tool_override = fake;
        defer generate.scripting_transpile.tsc_tool_override = null;

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false });

        const main_zig = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/main.zig", allocator, .limited(1 << 20));
        defer allocator.free(main_zig);
        const reg_a = try indexOfOrFail(main_zig, "scripting.registerScript(\"a\", @embedFile(\"scripts/10_a.js\"));");
        const reg_b = try indexOfOrFail(main_zig, "scripting.registerScript(\"b\", @embedFile(\"scripts/20_b.js\"));");
        try std.testing.expect(reg_a < reg_b);
        // Prefixed names never register (the stem stripped exactly like
        // the Zig scanner's).
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "registerScript(\"10_a\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "registerScript(\"20_b\"") == null);
    }

    test "LEGACY ts/ still transpiles through the grace release: ts/-rooted embeds, pre-#237 plain stems" {
        const allocator = std.testing.allocator;
        var staged = try StagedTranspileProject.init(allocator);
        defer staged.deinit(allocator);
        var game_root = try staged.tmp.dir.openDir(io, "game", .{});
        defer game_root.close(io);
        // Unmigrate: language sources move to the deprecated ts/ dir; the
        // Zig scripts stay in scripts/ (which then holds NO language
        // files, so resolve falls back to the legacy dir with the note).
        try game_root.deleteFile(io, "scripts/enemy.ts");
        try game_root.deleteFile(io, "scripts/behavior.js");
        try writeFileIn(game_root, "ts/behavior.js", "// @ts-check\nexport function update(dt) {}\n");
        try writeFileIn(game_root, "ts/enemy.ts", "export function update(dt: number): void {}\n");

        const fake = try StagedTranspileProject.stageEmittingFakeTsc(staged.tmp.dir, allocator, &happy_emit);
        defer allocator.free(fake);
        generate.scripting_transpile.tsc_tool_override = fake;
        defer generate.scripting_transpile.tsc_tool_override = null;

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false });

        // The LEGACY dir materialized (target/ts) and the embeds root
        // there — plain stems, byte-compatible with the pre-#237 release;
        // the shared scripts/ link stays a symlink (untouched by the
        // phase — it materializes only the RESOLVED dir).
        try staged.tmp.dir.access(io, "out/sokol_desktop/ts/enemy.js", .{});
        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        _ = try staged.tmp.dir.readLink(io, "out/sokol_desktop/scripts", &link_buf);
        const main_zig = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/main.zig", allocator, .limited(1 << 20));
        defer allocator.free(main_zig);
        _ = try indexOfOrFail(main_zig, "scripting.registerScript(\"behavior\", @embedFile(\"ts/behavior.js\"));");
        _ = try indexOfOrFail(main_zig, "scripting.registerScript(\"enemy\", @embedFile(\"ts/enemy.js\"));");
        // The generated d.ts landed in the materialized LEGACY dir and —
        // as everywhere — never registered.
        try staged.tmp.dir.access(io, "out/sokol_desktop/ts/labelle-components.d.ts", .{});
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "labelle-components") == null);
    }
};

// ── declaration-file transpile BEFORE declare (rev 20 option (b), #773) ──
// The full option-(b) path end to end: a typescript project authoring its
// component/event declarations as `.ts`. The assembler must (1) NOT reject
// `components/*.ts`/`events/*.ts` (the lifted gate), (2) transpile the
// declaration dirs into the target BEFORE declare (fake tsc emits the `.js`),
// (3) hand the declare tool ONLY the emitted declaration `.js` (components ++
// events — never scripts), (4) thread the schema into scripting_components.zig
// / scripting_events.zig, and (5) register the emitted `.js` from the
// materialized dirs. Both the tsc AND the declare runner are staged fakes
// (the real ones fetch tsc / build a quickjs exe — the non-hermetic steps the
// override seams exist to bypass); the declare runner RECORDS its argv so the
// "declare over the emitted declaration .js, decls-only" contract is pinned.

/// A typescript scripting plugin whose `.languages` row carries BOTH a
/// `.transpile` capability (so the embed extension resolves to `.js`) and a
/// `.declare` capability (so the generic declare path picks up the ts tool).
/// The `.transpile` pins are minimal — `detect` reads only `.emits`, and the
/// tsc fetch is bypassed by `tsc_tool_override`.
const ts_decl_plugin_manifest =
    \\.{ .name = "scripting", .manifest_version = 1,
    \\   .languages = .{
    \\       .{ .name = "typescript", .extensions = .{".ts"}, .kind = .embedded,
    \\          .transpile = .{ .emits = "js", .toolchain = "tsc", .version = "7.0.2",
    \\                          .fetch_url = "https://registry.npmjs.org/@typescript/typescript-{platform}/-/typescript-{platform}-{version}.tgz" },
    \\          .declare = .{ .tool = "labelle-declare-ts", .dir = "tools/declare-ts", .events = true } },
    \\   },
    \\}
;

/// The fake tsc for the declaration+script transpile: emits the KNOWN `.js`
/// for whichever tsconfig it is handed (`tsconfig.declare.json` -> the
/// declaration dirs' `.js`; the script tsconfig -> the script `.js`). Honors
/// the `<tool> -p <tsconfig>` contract and reads `outDir` from the config.
const decl_emit = [_]StagedTranspileProject.Emit{
    .{ .when_config_suffix = "tsconfig.declare.json", .rel = "components/hunger.js", .body = "export const Hunger = labelle.component(\"Hunger\", { level: 0.875 });\n" },
    .{ .when_config_suffix = "tsconfig.declare.json", .rel = "events/feed.js", .body = "export const Feed = labelle.event(\"hunger__feed\", { amount: 0.5 });\n" },
    .{ .unless_config_suffix = "tsconfig.declare.json", .rel = "logic.js", .body = "export function update(dt) {}\n" },
};

const decl_schema_json =
    \\{"components":[{"name":"Hunger","persist":"persistent","fields":[{"name":"level","type":"f32","default":0.875}]}],"events":[{"name":"hunger__feed","fields":[{"name":"amount","type":"f32","default":0.5}]}]}
;

pub const DECL_TRANSPILE_E2E = struct {
    test "a typescript project declaring in components/*.ts + events/*.ts: transpile-before-declare, decls-only argv, schema + embeds flow (rev 20 option (b))" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io, "out");
        try tmp.dir.createDirPath(io, "game");
        var game = try tmp.dir.openDir(io, "game", .{});
        defer game.close(io);

        try writeFileIn(game, "plugins/scripting/plugin.labelle", ts_decl_plugin_manifest);
        try writeFileIn(game, "plugins/scripting/contract/labelle.d.ts",
            \\declare const labelle: { component(n: string, s?: object, o?: object): any; event(n: string, s?: object): string; id: number };
            \\
        );
        // Authored declarations as `.ts` — the gate that used to reject
        // these (ComponentsDirNeedsTranspile / EventsDirNeedsTranspile) is
        // lifted; they transpile to `.js` and feed the declare tool.
        try writeFileIn(game, "components/hunger.ts",
            \\export const Hunger = labelle.component("Hunger", { level: 0.875 });
        );
        try writeFileIn(game, "events/feed.ts",
            \\export const Feed = labelle.event("hunger__feed", { amount: 0.5 });
        );
        // A gameplay script (transpiled AFTER declare) — proves the reorder
        // and that scripts never reach the declare tool's argv.
        try writeFileIn(game, "scripts/logic.ts",
            \\export function update(dt: number): void {}
        );
        try writeFileIn(game, "engine-fixture/codegen/main.zig.template", engine_template);
        const game_abs = try tmp.dir.realPathFileAlloc(io, "game", allocator);
        defer allocator.free(game_abs);
        const out_abs = try tmp.dir.realPathFileAlloc(io, "out", allocator);
        defer allocator.free(out_abs);

        // Fake tsc, through the portable helper (#699).
        const fake_tsc = try StagedTranspileProject.stageEmittingFakeTsc(tmp.dir, allocator, &decl_emit);
        defer allocator.free(fake_tsc);
        generate.scripting_transpile.tsc_tool_override = fake_tsc;
        defer generate.scripting_transpile.tsc_tool_override = null;

        // Fake declare runner that RECORDS its argv, then echoes the schema —
        // through the portable helper, since a `#!/bin/sh` body is not
        // executable on Windows (#699).
        const fake_declare = try StagedTranspileProject.stageRecordingFakeDeclare(tmp.dir, allocator, decl_schema_json);
        defer allocator.free(fake_declare);
        generate.scripting_declare.declare_tool_override = fake_declare;
        defer generate.scripting_declare.declare_tool_override = null;

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        const cfg = generate.ProjectConfig{
            .name = "ts-decl-game",
            .backend = .sokol,
            .backend_package = .{ .name = "sokol", .repo = backend_repo },
            .ecs = .mock,
            .engine_version = "local:engine-fixture",
            .y_axis = .up,
            .plugins = &.{
                .{ .name = "scripting", .repo = "local:plugins/scripting", .params = .{ .language = "typescript" } },
            },
        };
        // is_tests_target = false so the game main.zig is emitted (the
        // registration assertions below read it); the declare phase runs
        // regardless (it gates on the splice + declaration files).
        try generate.generate(allocator, cfg, out_abs, game_abs, .{ .is_tests_target = false });

        // (2) The declaration dirs transpiled into the target BEFORE declare:
        // the emitted `.js` exist where the declare tool + @embedFile read them.
        try tmp.dir.access(io, "out/sokol_desktop/components/hunger.js", .{});
        try tmp.dir.access(io, "out/sokol_desktop/events/feed.js", .{});

        // (3) The declare tool saw ONLY the emitted declaration `.js`
        // (components ++ events) — never the gameplay script, never a `.ts`.
        const recorded = try tmp.dir.readFileAlloc(io, "recorded-args.txt", allocator, .limited(1 << 16));
        defer allocator.free(recorded);
        _ = try indexOfOrFail(recorded, "components/hunger.js");
        _ = try indexOfOrFail(recorded, "events/feed.js");
        try std.testing.expect(std.mem.indexOf(u8, recorded, "logic") == null);
        try std.testing.expect(std.mem.indexOf(u8, recorded, ".ts") == null);

        // (4) The schema flowed into the generated component + event files.
        const comps = try tmp.dir.readFileAlloc(io, "out/sokol_desktop/scripting_components.zig", allocator, .limited(1 << 20));
        defer allocator.free(comps);
        _ = try indexOfOrFail(comps, "Hunger");
        const events = try tmp.dir.readFileAlloc(io, "out/sokol_desktop/scripting_events.zig", allocator, .limited(1 << 20));
        defer allocator.free(events);
        // The generated event type is PascalCase (`hunger__feed` ->
        // `HungerFeed`); the raw union-variant name lives in main.zig's
        // event-union row, not in this file.
        _ = try indexOfOrFail(events, "pub const HungerFeed = struct {");

        // (5) The generated main registers the emitted declaration `.js` from
        // the materialized dirs (components-first), plus the transpiled script.
        const main_zig = try tmp.dir.readFileAlloc(io, "out/sokol_desktop/main.zig", allocator, .limited(1 << 20));
        defer allocator.free(main_zig);
        const reg_hunger = try indexOfOrFail(main_zig, "scripting.registerScript(\"hunger\", @embedFile(\"components/hunger.js\"));");
        const reg_feed = try indexOfOrFail(main_zig, "scripting.registerScript(\"feed\", @embedFile(\"events/feed.js\"));");
        const reg_logic = try indexOfOrFail(main_zig, "scripting.registerScript(\"logic\", @embedFile(\"scripts/logic.js\"));");
        // components-first, events next, scripts last (the #772 order).
        try std.testing.expect(reg_hunger < reg_feed);
        try std.testing.expect(reg_feed < reg_logic);
        // No `.ts` embed anywhere.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".ts\")") == null);
    }
};
