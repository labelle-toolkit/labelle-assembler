//! The PYTHON LITMUS TEST (labelle-assembler#619, RFC-LANGUAGE-PLUGINS
//! rev 16 §7 "python litmus").
//!
//! The acceptance criterion for the language-agnostic assembler: a language
//! the assembler has NEVER heard of — one whose name and extension appear
//! NOWHERE in `src/*.zig` — can be added, generated, and wired end-to-end
//! through the capability rows a language plugin declares in its
//! `plugin.labelle`, with ZERO assembler code naming it. If this suite goes
//! green while the fixture language never appears in assembler source, the
//! vocabulary, collection, policy, and splice paths are all genuinely
//! row-driven.
//!
//! Why the fixture language is "quokka"/".qk" and not literally "python":
//! the RFC names the criterion the *python* litmus, but "python" already
//! appears in assembler source as an ILLUSTRATIVE comment/test example (the
//! RFC's own "a language the tables never heard of, e.g. python" prose).
//! The META agnosticism proof below is a substring scan, which cannot tell
//! an illustrative comment from a hardcoded branch — so the FIXTURE uses a
//! genuinely novel identifier ("quokka", `.qk`) that no assembler comment or
//! branch mentions, making the "names it nowhere" proof unambiguous. It is
//! the python litmus in spirit: an embedded-VM language the assembler learns
//! entirely from a manifest capability row.
//!
//! "quokka" is a FAKE embedded-VM language: a fixture scripting plugin whose
//! manifest carries `.languages = .{ .{ .name = "quokka",
//! .extensions = .{".qk"}, .kind = .embedded } }` and a `scripts/*.qk`
//! source. It carries NO `.declare` capability (so the hermetic test never
//! shells `zig build <tool>`), which still exercises the full row-driven
//! path the RFC's litmus names: open-vocabulary policy admission, the
//! extension-keyed `scripts/` collection, the embed `registerScript` /
//! `@embedFile` registration, and the four family-shared splice touchpoints
//! (dep `.language` arg, alias + `scripting_enabled` flag, drainEvents tap,
//! Controller.tick). The declare/transpile capabilities are separately
//! proven row-driven by ts/crystal's own suites — the point THIS suite pins
//! is that the assembler learns a brand-new language from data alone.
//!
//! The two halves:
//!   1. `QUOKKA_LITMUS_GENERATE` — the fake quokka plugin generates a game
//!      end-to-end over the REAL `generate`, and the generated main/build
//!      carry the row-derived quokka wiring; a foreign FROZEN-language file
//!      (`.rb`) in the same project still errors, proving the combined
//!      (frozen ∪ row) vocabulary polices both ways.
//!   2. `QUOKKA_LITMUS_AGNOSTICISM` — a META test: "quokka" and ".qk"
//!      appear in NO `src/**/*.zig` file. This is the mechanical proof the
//!      generate above rode rows, not a hidden hardcoded branch.

const std = @import("std");
const zspec = @import("zspec");
const generate = @import("generator");
const h = @import("helpers.zig");

const engine_template = h.engine_template;
const io = std.testing.io;

test {
    zspec.runAll(@This());
}

fn writeFileIn(dir: std.Io.Dir, rel: []const u8, body: []const u8) !void {
    if (std.fs.path.dirname(rel)) |sub| try dir.createDirPath(io, sub);
    var f = try dir.createFile(io, rel, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, body);
}

fn indexOfOrFail(haystack: []const u8, needle: []const u8) !usize {
    return std.mem.indexOf(u8, haystack, needle) orelse {
        std.debug.print("expected to find:\n  {s}\nin generated output\n", .{needle});
        return error.MissingExpectedEmission;
    };
}

/// The in-tree sokol backend fixture as an ABSOLUTE `local:` repo (staged
/// games live in tmp dirs, so the repo-relative spelling can't resolve).
fn sokolFixtureRepoAbs(allocator: std.mem.Allocator) ![]const u8 {
    const abs = try std.Io.Dir.cwd().realPathFileAlloc(io, "backends/sokol", allocator);
    defer allocator.free(abs);
    return std.fmt.allocPrint(allocator, "local:{s}", .{abs});
}

/// A staged tmp game scripted in the FAKE "quokka" language: a scripting
/// plugin whose ONLY per-language knowledge is a manifest `.languages`
/// capability row (embedded, `.qk`), a `scripts/behavior.qk` source, the
/// engine template fixture, and `out/`.
const StagedQuokkaProject = struct {
    tmp: std.testing.TmpDir,
    game_abs: [:0]const u8,
    out_abs: [:0]const u8,

    fn init(allocator: std.mem.Allocator) !StagedQuokkaProject {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io, "out");
        try tmp.dir.createDirPath(io, "game");
        var game_root = try tmp.dir.openDir(io, "game", .{});
        defer game_root.close(io);

        // THE WHOLE INTEGRATION: one manifest capability row. No `.declare`
        // (hermetic — no tool build), no `.transpile` (the `.qk` source IS
        // the embedded source). `.kind = .embedded` + `.extensions` is all
        // the assembler needs to collect, embed, and register quokka.
        try writeFileIn(game_root, "plugins/scripting/plugin.labelle",
            \\.{
            \\    .name = "scripting",
            \\    .manifest_version = 1,
            \\    .languages = .{
            \\        .{ .name = "quokka", .extensions = .{".qk"}, .kind = .embedded },
            \\    },
            \\}
        );
        // The game's quokka behavior — collected by the extension-keyed
        // scripts/ scan and embedded as a script source.
        try writeFileIn(game_root, "scripts/behavior.qk",
            \\on update do |dt|
            \\end
        );
        // A Zig script sharing the dir — the ZIG scanner's file, invisible
        // to the quokka collection (extension-keyed coexistence).
        try writeFileIn(game_root, "scripts/01_move.zig", "pub fn tick() void {}\n");

        try writeFileIn(game_root, "engine-fixture/codegen/main.zig.template", engine_template);
        const game_abs = try tmp.dir.realPathFileAlloc(io, "game", allocator);
        errdefer allocator.free(game_abs);
        const out_abs = try tmp.dir.realPathFileAlloc(io, "out", allocator);
        return .{ .tmp = tmp, .game_abs = game_abs, .out_abs = out_abs };
    }

    fn deinit(self: *StagedQuokkaProject, allocator: std.mem.Allocator) void {
        allocator.free(self.game_abs);
        allocator.free(self.out_abs);
        self.tmp.cleanup();
    }

    fn config(self: *StagedQuokkaProject, backend_repo: []const u8) generate.ProjectConfig {
        _ = self;
        return .{
            .name = "quokka-game",
            .backend = .sokol,
            .backend_package = .{ .name = "sokol", .repo = backend_repo },
            .ecs = .mock,
            .engine_version = "local:engine-fixture",
            .y_axis = .up,
            .plugins = &.{
                // The one-language-per-project param names a language the
                // assembler source never mentions — admitted by the
                // manifest row alone.
                .{ .name = "scripting", .repo = "local:plugins/scripting", .params = .{ .language = "quokka" } },
            },
        };
    }
};

pub const QUOKKA_LITMUS_GENERATE = struct {
    test "a scripts/behavior.qk project generates end to end through the manifest row alone — zero assembler code names quokka" {
        const allocator = std.testing.allocator;
        var staged = try StagedQuokkaProject.init(allocator);
        defer staged.deinit(allocator);

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false });

        // ── Generated main: the embed registration + family-shared touchpoints ──
        const main_zig = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/main.zig", allocator, .limited(1 << 20));
        defer allocator.free(main_zig);
        // The quokka source is embedded and registered — driven by the
        // row's `.kind = .embedded` + `.extensions = .{".qk"}`.
        _ = try indexOfOrFail(main_zig, "scripting.registerScript(\"behavior\", @embedFile(\"scripts/behavior.qk\"));");
        _ = try indexOfOrFail(main_zig, "const scripting = @import(\"scripting\");");
        _ = try indexOfOrFail(main_zig, "const scripting_enabled = true;");
        // The coexisting Zig script never leaks into the language layer.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "registerScript(\"move\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "registerScript(\"01_move\"") == null);

        // The embedded source is staged where @embedFile resolves it.
        try staged.tmp.dir.access(io, "out/sokol_desktop/scripts/behavior.qk", .{});

        // ── Generated build: the plugin dep selects the quokka sub-module ──
        // `.language = .quokka` — the enum-literal arg, from the identifier
        // the row admitted, with NO assembler enum/switch naming quokka.
        const build_zig = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/build.zig", allocator, .limited(1 << 20));
        defer allocator.free(build_zig);
        _ = try indexOfOrFail(build_zig, ".language = .quokka");

        // No declare capability → no generated component file (skipped
        // silently, exactly like a runner-less embedded language).
        try std.testing.expectError(
            error.FileNotFound,
            staged.tmp.dir.access(io, "out/sokol_desktop/scripting_components.zig", .{}),
        );
    }

    test "a FROZEN-language file (.rb) in a quokka project errors — the combined (frozen ∪ row) vocabulary polices both ways" {
        // The row admits quokka; the frozen table still owns ruby. A `.rb`
        // in a quokka project is a FOREIGN-language file (nothing would run
        // it) — the same silent-death class the policy scan catches for any
        // language mismatch, now proven across the frozen/row boundary.
        const allocator = std.testing.allocator;
        var staged = try StagedQuokkaProject.init(allocator);
        defer staged.deinit(allocator);
        var game_root = try staged.tmp.dir.openDir(io, "game", .{});
        defer game_root.close(io);
        try writeFileIn(game_root, "scripts/intruder.rb", "class Intruder; end\n");

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try std.testing.expectError(
            error.ScriptLanguageMismatch,
            generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false }),
        );
    }
};

/// A staged lua project parameterized by whether its scripting plugin's
/// manifest carries a `.languages` row for lua. `with_row = false` rides the
/// FROZEN `EMBED_LANGUAGES`/`SUPPORTED_LANGUAGES` fallback (today's published
/// labelle-scripting); `with_row = true` rides the manifest capability row
/// (the migrated form). The BACK-COMPAT proof asserts the two generate
/// byte-identical output — migrating lua/ruby onto rows shifts nothing.
fn stageLuaProject(allocator: std.mem.Allocator, out_root: []const u8, with_row: bool) !struct {
    tmp: std.testing.TmpDir,
    game_abs: [:0]const u8,
    out_abs: [:0]const u8,
} {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const out_sub = out_root;
    try tmp.dir.createDirPath(io, out_sub);
    try tmp.dir.createDirPath(io, "game");
    var game_root = try tmp.dir.openDir(io, "game", .{});
    defer game_root.close(io);

    const manifest = if (with_row)
        \\.{
        \\    .name = "scripting",
        \\    .manifest_version = 1,
        \\    .languages = .{
        \\        .{ .name = "lua", .extensions = .{".lua"}, .kind = .embedded },
        \\    },
        \\}
    else
        \\.{ .name = "scripting", .manifest_version = 1 }
    ;
    try writeFileIn(game_root, "plugins/scripting/plugin.labelle", manifest);
    try writeFileIn(game_root, "scripts/behavior.lua", "return {}\n");
    try writeFileIn(game_root, "scripts/01_move.zig", "pub fn tick() void {}\n");
    try writeFileIn(game_root, "engine-fixture/codegen/main.zig.template", engine_template);

    const game_abs = try tmp.dir.realPathFileAlloc(io, "game", allocator);
    errdefer allocator.free(game_abs);
    const out_abs = try tmp.dir.realPathFileAlloc(io, out_sub, allocator);
    return .{ .tmp = tmp, .game_abs = game_abs, .out_abs = out_abs };
}

pub const LUA_ROW_BACKCOMPAT = struct {
    test "byte-identity: a lua project generates the SAME main.zig + build.zig whether it rides the frozen fallback or an equivalent `.languages` row (#619 migration safety)" {
        const allocator = std.testing.allocator;
        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);

        const luaConfig = struct {
            fn make(backend: []const u8) generate.ProjectConfig {
                return .{
                    .name = "lua-game",
                    .backend = .sokol,
                    .backend_package = .{ .name = "sokol", .repo = backend },
                    .ecs = .mock,
                    .engine_version = "local:engine-fixture",
                    .y_axis = .up,
                    .plugins = &.{
                        .{ .name = "scripting", .repo = "local:plugins/scripting", .params = .{ .language = "lua" } },
                    },
                };
            }
        };

        // Frozen-fallback generate (no `.languages` row).
        var frozen = try stageLuaProject(allocator, "out", false);
        defer {
            allocator.free(frozen.game_abs);
            allocator.free(frozen.out_abs);
            frozen.tmp.cleanup();
        }
        try generate.generate(allocator, luaConfig.make(backend_repo), frozen.out_abs, frozen.game_abs, .{ .is_tests_target = false });
        const frozen_main = try frozen.tmp.dir.readFileAlloc(io, "out/sokol_desktop/main.zig", allocator, .limited(1 << 20));
        defer allocator.free(frozen_main);
        const frozen_build = try frozen.tmp.dir.readFileAlloc(io, "out/sokol_desktop/build.zig", allocator, .limited(1 << 20));
        defer allocator.free(frozen_build);

        // Row-driven generate (equivalent `.languages` row).
        var rowed = try stageLuaProject(allocator, "out", true);
        defer {
            allocator.free(rowed.game_abs);
            allocator.free(rowed.out_abs);
            rowed.tmp.cleanup();
        }
        try generate.generate(allocator, luaConfig.make(backend_repo), rowed.out_abs, rowed.game_abs, .{ .is_tests_target = false });
        const rowed_main = try rowed.tmp.dir.readFileAlloc(io, "out/sokol_desktop/main.zig", allocator, .limited(1 << 20));
        defer allocator.free(rowed_main);
        const rowed_build = try rowed.tmp.dir.readFileAlloc(io, "out/sokol_desktop/build.zig", allocator, .limited(1 << 20));
        defer allocator.free(rowed_build);

        // The row path must be byte-identical to the frozen fallback:
        // migrating lua/ruby onto capability rows is a no-op on output.
        try std.testing.expectEqualStrings(frozen_main, rowed_main);
        try std.testing.expectEqualStrings(frozen_build, rowed_build);
        // And the embed registration really is present (not both empty).
        _ = try indexOfOrFail(frozen_main, "scripting.registerScript(\"behavior\", @embedFile(\"scripts/behavior.lua\"));");
    }
};

pub const QUOKKA_LITMUS_AGNOSTICISM = struct {
    test "META: 'quokka' and '.qk' appear in NO src/**/*.zig — the assembler learns the language from data alone (#619)" {
        const allocator = std.testing.allocator;
        var src = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
        defer src.close(io);

        var offenders: std.ArrayList([]const u8) = .empty;
        defer {
            for (offenders.items) |o| allocator.free(o);
            offenders.deinit(allocator);
        }
        try scanForLitmusLanguage(allocator, src, "src", &offenders);

        if (offenders.items.len != 0) {
            std.debug.print(
                "the litmus is broken: the assembler source NAMES the litmus language.\n" ++
                    "  a language plugin must be addable with ZERO assembler changes (RFC-LANGUAGE-PLUGINS §7).\n" ++
                    "  offending files (contain \"quokka\" or a \".qk\" literal):\n",
                .{},
            );
            for (offenders.items) |o| std.debug.print("    {s}\n", .{o});
            return error.AssemblerNamesLitmusLanguage;
        }
    }
};

/// Recursively scan `src/**/*.zig` for either the identifier `quokka` or a
/// `.qk` string literal — the two spellings a hidden hardcoded branch for
/// the litmus language would use. Records offending relative paths.
fn scanForLitmusLanguage(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    rel_prefix: []const u8,
    offenders: *std.ArrayList([]const u8),
) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        switch (entry.kind) {
            .directory => {
                var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                defer sub.close(io);
                const sub_prefix = try std.fs.path.join(allocator, &.{ rel_prefix, entry.name });
                defer allocator.free(sub_prefix);
                try scanForLitmusLanguage(allocator, sub, sub_prefix, offenders);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                const body = dir.readFileAlloc(io, entry.name, allocator, .limited(1 << 22)) catch continue;
                defer allocator.free(body);
                // "quokka" the identifier, or a `.qk` STRING literal
                // (`".qk"`) — the two forms a hardcode would take.
                if (std.mem.indexOf(u8, body, "quokka") != null or
                    std.mem.indexOf(u8, body, "\".qk\"") != null)
                {
                    const rel = try std.fs.path.join(allocator, &.{ rel_prefix, entry.name });
                    errdefer allocator.free(rel);
                    try offenders.append(allocator, rel);
                }
            },
            else => {},
        }
    }
}
