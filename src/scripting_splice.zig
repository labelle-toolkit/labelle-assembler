//! Scripting codegen splice (labelle-assembler#593, epic labelle-engine#237).
//!
//! The consuming half of the one-language-per-project policy (#584/#589,
//! `language_policy.zig` — parse + validate only): when THE scripting plugin
//! (resolved manifest name `"scripting"`, labelle-toolkit/labelle-scripting)
//! is attached with `.params = .{ .language = "…" }`, the generate pipeline
//!
//!   1. copies the game root's convention dir (`lua/`, `ts/`, … —
//!      `language_policy.conventionDir`) into the target
//!      (`scanner.linkAndScan`, sorted stems — root.zig),
//!   2. registers each script with the plugin in the generated main BEFORE
//!      `PluginControllers.setup` boots the VM
//!      (`scripting.registerScript("<stem>", @embedFile("<dir>/<stem><ext>"))`
//!      — lifecycle loop/callback builders),
//!   3. emits the module-scope `const scripting = @import("<plugin>");` alias
//!      + the `const scripting_enabled = true;` flag backend templates gate
//!      their `script_contract` bind touchpoint on (double `@hasDecl`,
//!      mirroring the fullscreen/vsync drain convention — render.zig), and
//!      splices the per-frame `script_contract.drainEvents(&g)` tap between
//!      the plugin ticks and `g.dispatchEvents()` (the engine contract's
//!      "AFTER tick, BEFORE dispatchEvents" ordering — `tick_code`), and
//!   4. passes `.language = .<language>` to the plugin's `b.dependency` args
//!      in the generated build.zig (the plugin's `-Dlanguage` build option —
//!      `build_files/build_zig.zig`).
//!
//! This module owns the DETECTION + the language→extension table; the
//! emission sites live beside the code they extend so each stays
//! byte-identical for splice-less projects. A `.params.language` on a plugin
//! whose manifest is NOT named `scripting` (or that ships no manifest) is
//! policy-legal but splice-less — the plugin is wired like any other and
//! nothing embeds.

const std = @import("std");
const config = @import("config.zig");
const language_policy = @import("language_policy.zig");
const plugin_manifest = @import("plugin_manifest.zig");
const scripting_declare = @import("scripting_declare.zig");

/// The resolved `plugin.labelle` name that identifies THE scripting plugin
/// (labelle-toolkit/labelle-scripting ships `.name = "scripting"`). Manifest
/// name == `.plugins` entry name is enforced at manifest load
/// (`PluginManifestNameMismatch`), so the entry is also spelled `scripting`
/// in project.labelle — which is the `@import` name the generated main and
/// the `labelle_scripting` dep/module names in the generated build use.
pub const SCRIPTING_MANIFEST_NAME = "scripting";

/// An authoring extension in the script dir that the assembler cannot turn
/// into runnable source yet: `rejectUntranspiledScripts` hard-fails
/// generate on its presence instead of embedding something the VM will
/// choke on later (or worse, silently skipping it). This is the seam the
/// TS→JS transpile build hook (labelle-assembler#586) replaces: when #586
/// lands, the row's gap is deleted and `.ts` sources transpile instead of
/// erroring.
const TranspileGap = struct {
    /// The extension that needs the missing transpile step (`.ts`).
    source_extension: []const u8,
    /// Suffix EXEMPT from the gate (`.d.ts`): declaration files carry no
    /// runtime code — they're the documented `// @ts-check` authoring
    /// companion (labelle-scripting README: "copy it or point at the
    /// resolved package's contract/ dir"), so a copied `ts/labelle.d.ts`
    /// must never fail generate.
    declaration_suffix: []const u8,
    /// The pointed fix, printed under the offender list.
    hint: []const u8,
};

/// One embeddable language: its `language_policy.SUPPORTED_LANGUAGES` name
/// (the convention DIR comes from `language_policy.conventionDir` — `ts/`
/// for typescript) and the source-file extension the copy + `@embedFile`
/// registration collect.
const EmbedLanguage = struct {
    language: []const u8,
    extension: []const u8,
    /// Non-null when the language ALSO has an authoring extension the
    /// assembler can't run yet (typescript's `.ts` until #586).
    transpile_gap: ?TranspileGap = null,
};

/// The `.ts`-present generate error's fix line (pub so the test pinning the
/// message and the emission stay one string).
pub const TS_TRANSPILE_HINT: []const u8 =
    "transpile not yet available (labelle-assembler#586) — author .js against " ++
    "contract/labelle.d.ts (ts/ dir, // @ts-check); .d.ts declaration files are fine.";

/// Languages whose scripts are EMBEDDED as source and fed to the plugin's
/// VM via `registerScript` (the RFC's embedded-VM family). Widening is
/// additive — one row per language as its labelle-scripting sub-module
/// lands. Native-compiled languages (rust, crystal, go) integrate by
/// linking, not embedding, and get their own splice in a later ticket, so
/// they are deliberately absent.
///
/// typescript (labelle-scripting v0.3.0, quickjs-ng) embeds `.js` ONLY:
/// the runtime evaluates plain-JS ES modules, and the TS→JS transpile hook
/// doesn't exist yet (#586) — so a `.ts` source in `ts/` fails generate
/// loudly (`rejectUntranspiledScripts`) rather than silently not running
/// or erroring at VM load, far from the author.
pub const EMBED_LANGUAGES = [_]EmbedLanguage{
    .{ .language = "lua", .extension = ".lua" },
    .{ .language = "typescript", .extension = ".js", .transpile_gap = .{
        .source_extension = ".ts",
        .declaration_suffix = ".d.ts",
        .hint = TS_TRANSPILE_HINT,
    } },
};

fn embedRow(language: []const u8) ?EmbedLanguage {
    for (EMBED_LANGUAGES) |e| {
        if (std.mem.eql(u8, e.language, language)) return e;
    }
    return null;
}

/// The source extension embedded for `language`, or null when the language
/// has no embeddable-source integration yet.
pub fn embedExtension(language: []const u8) ?[]const u8 {
    const row = embedRow(language) orelse return null;
    return row.extension;
}

/// Everything the emission sites need, resolved once by `detect` and
/// threaded through `main_template.scripting_splice` (the same scoped
/// module-var pattern as `pack_scans`) + `BuildZigOptions.scripting`.
/// Borrows `plugin_name`/`language` from the parsed `ProjectConfig`;
/// `extension` is a static table slice; `script_names` is set by root.zig
/// after the `<language>/` copy (owned by root.zig's scan, sorted —
/// `scanner.linkAndScan` stems relative to the language dir, subdirs joined
/// with `/`). Owns nothing.
pub const ScriptingSplice = struct {
    plugin_name: []const u8,
    language: []const u8,
    /// The convention dir the scripts live in and the `@embedFile` paths
    /// are rooted at — `language_policy.conventionDir(language)` (`lua/`,
    /// `ts/`), resolved once by `detect` so every emission site agrees.
    dir: []const u8,
    extension: []const u8,
    script_names: []const []const u8 = &.{},
    /// Script-declared components (labelle-assembler#585): the parsed
    /// declare-mode schema, set by root.zig after
    /// `scripting_declare.runPhase` ran the plugin's runner over
    /// `script_names` (borrowed from the phase's `Schema` arena, alive
    /// through main.zig emission). Consumed by
    /// `registries.writeComponentRegistryBlock`, which registers each
    /// under its declared name against the generated
    /// `scripting_components.zig`. Empty (the default) for every
    /// declaration-less project — all emission sites stay byte-identical.
    declared_components: []const scripting_declare.DeclaredComponent = &.{},
};

/// Detect the scripting splice for this project: the `.plugins` entry
/// declaring `.params.language` (the #589 parse — at most one exists, the
/// policy gate already ran) whose resolved manifest name is
/// `SCRIPTING_MANIFEST_NAME`. Returns null for every splice-less shape:
/// no `.params.language` declared, the declaring plugin ships no
/// `plugin.labelle`, its manifest name isn't `scripting`, or the language
/// has no embeddable extension yet (warned — the attach is policy-legal,
/// the embed integration just hasn't landed).
///
/// Runs AFTER `generate_phases.validateLanguagePolicy`, so the re-parse and
/// re-load here surface no new errors in practice; `try` keeps any skew
/// loud. Same re-read-per-phase pattern as `copyPluginConventionDirs`.
pub fn detect(
    allocator: std.mem.Allocator,
    plugins: []const config.PluginDep,
    game_dir: []const u8,
) !?ScriptingSplice {
    const declared = (try language_policy.resolveProjectLanguage(plugins)) orelse return null;

    for (plugins) |plugin| {
        if (!std.mem.eql(u8, plugin.name, declared.plugin_name)) continue;

        var pmani = (try plugin_manifest.loadOptional(allocator, plugin, game_dir)) orelse return null;
        defer pmani.deinit();
        if (!std.mem.eql(u8, pmani.name, SCRIPTING_MANIFEST_NAME)) return null;

        const ext = embedExtension(declared.language) orelse {
            std.log.warn(
                "labelle: script language \"{s}\" has no embeddable-source integration yet; " ++
                    "the scripting plugin is wired but no {s}/ scripts are embedded",
                .{ declared.language, declared.language },
            );
            return null;
        };

        return .{
            .plugin_name = plugin.name,
            .language = declared.language,
            .dir = language_policy.conventionDir(declared.language),
            .extension = ext,
        };
    }
    // `declared.plugin_name` always names a member of `plugins` (it came
    // from the same slice), so this is unreachable in practice.
    return null;
}

/// Fail generate when the splice's script dir holds sources the assembler
/// cannot run yet (the language's `TranspileGap` — today: `.ts` files in a
/// typescript project's `ts/`, minus `.d.ts` declaration files). The copy +
/// scan collect only `splice.extension` files, so without this gate a
/// `.ts`-authored script would neither embed nor error — a script that
/// silently never runs. Listing caps at `language_policy.MAX_LISTED_FILES`
/// (the script-dir scan's rule); a missing dir or a gap-less language
/// (lua) is a no-op. Runs against the game-root SOURCE dir, before the
/// target link — root.zig calls it right ahead of the script copy.
pub fn rejectUntranspiledScripts(
    allocator: std.mem.Allocator,
    game_dir: []const u8,
    splice: ScriptingSplice,
) !void {
    const row = embedRow(splice.language) orelse return;
    const gap = row.transpile_gap orelse return;

    const io = config.globalIo();
    const dir_path = try std.fs.path.join(allocator, &.{ game_dir, splice.dir });
    defer allocator.free(dir_path);
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer dir.close(io);

    var listed: std.ArrayList([]const u8) = .empty;
    defer {
        for (listed.items) |p| allocator.free(p);
        listed.deinit(allocator);
    }
    var total: usize = 0;
    try walkUntranspiled(allocator, io, dir, splice.dir, gap, &listed, &total);
    if (total == 0) return;

    std.debug.print(
        "labelle-assembler: {s}/ contains {s} sources, but the assembler has no {s}→{s} transpile step yet:\n",
        .{ splice.dir, gap.source_extension, gap.source_extension, row.extension },
    );
    for (listed.items) |rel| std.debug.print("  {s}\n", .{rel});
    if (total > listed.items.len) {
        std.debug.print("  ... and {d} more\n", .{total - listed.items.len});
    }
    std.debug.print("  {s}\n", .{gap.hint});
    return error.ScriptNeedsTranspile;
}

fn walkUntranspiled(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    rel_prefix: []const u8,
    gap: TranspileGap,
    listed: *std.ArrayList([]const u8),
    total: *usize,
) !void {
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        switch (entry.kind) {
            .directory => {
                var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                defer sub.close(io);
                const sub_prefix = try std.fs.path.join(allocator, &.{ rel_prefix, entry.name });
                defer allocator.free(sub_prefix);
                try walkUntranspiled(allocator, io, sub, sub_prefix, gap, listed, total);
            },
            else => {
                if (!std.mem.endsWith(u8, entry.name, gap.source_extension)) continue;
                if (std.mem.endsWith(u8, entry.name, gap.declaration_suffix)) continue;
                total.* += 1;
                if (listed.items.len < language_policy.MAX_LISTED_FILES) {
                    const rel = try std.fs.path.join(allocator, &.{ rel_prefix, entry.name });
                    errdefer allocator.free(rel);
                    try listed.append(allocator, rel);
                }
            },
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "embedExtension: lua maps to .lua, typescript embeds .js; native-compiled languages are absent" {
    try testing.expectEqualStrings(".lua", embedExtension("lua").?);
    // typescript embeds PLAIN JS (quickjs-ng runs ES modules; TS→JS
    // transpile is the #586 gap) — never `.ts`.
    try testing.expectEqualStrings(".js", embedExtension("typescript").?);
    try testing.expect(embedExtension("rust") == null);
    try testing.expect(embedExtension("cobol") == null);
}

test "EMBED_LANGUAGES: lua has no transpile gap; typescript gates .ts (exempting .d.ts) with the pointed #586 hint" {
    try testing.expect(embedRow("lua").?.transpile_gap == null);
    const gap = embedRow("typescript").?.transpile_gap.?;
    try testing.expectEqualStrings(".ts", gap.source_extension);
    try testing.expectEqualStrings(".d.ts", gap.declaration_suffix);
    // The pointed fix names the authoring workflow that works TODAY and
    // the ticket that lifts the gate.
    try testing.expect(std.mem.indexOf(u8, gap.hint, "author .js against contract/labelle.d.ts (ts/ dir, // @ts-check)") != null);
    try testing.expect(std.mem.indexOf(u8, gap.hint, "labelle-assembler#586") != null);
}

fn writeTestFile(dir: std.Io.Dir, rel: []const u8, body: []const u8) !void {
    const tio = testing.io;
    if (std.fs.path.dirname(rel)) |sub| try dir.createDirPath(tio, sub);
    var f = try dir.createFile(tio, rel, .{});
    defer f.close(tio);
    try f.writeStreamingAll(tio, body);
}

test "detect: scripting manifest + .params.language → splice with the entry's import name" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "plugins/scripting/plugin.labelle",
        \\.{ .name = "scripting", .manifest_version = 1 }
    );
    const project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(project_dir);

    const plugins = [_]config.PluginDep{
        .{ .name = "pathfinding", .repo = "local:plugins/pathfinding" },
        .{ .name = "scripting", .repo = "local:plugins/scripting", .params = &.{ .{ .name = "language", .value = .{ .str = "lua" } } } },
    };
    const splice = (try detect(allocator, &plugins, project_dir)).?;
    try testing.expectEqualStrings("scripting", splice.plugin_name);
    try testing.expectEqualStrings("lua", splice.language);
    try testing.expectEqualStrings("lua", splice.dir);
    try testing.expectEqualStrings(".lua", splice.extension);
    try testing.expectEqual(@as(usize, 0), splice.script_names.len);
}

test "detect: a typescript declaration splices with the ts/ convention dir and the .js embed extension" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "plugins/scripting/plugin.labelle",
        \\.{ .name = "scripting", .manifest_version = 1 }
    );
    const project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(project_dir);

    const plugins = [_]config.PluginDep{
        .{ .name = "scripting", .repo = "local:plugins/scripting", .params = &.{ .{ .name = "language", .value = .{ .str = "typescript" } } } },
    };
    const splice = (try detect(allocator, &plugins, project_dir)).?;
    try testing.expectEqualStrings("scripting", splice.plugin_name);
    try testing.expectEqualStrings("typescript", splice.language);
    // dir ≠ language for typescript: scripts live in `ts/` (the
    // labelle-scripting convention) and embed paths root there.
    try testing.expectEqualStrings("ts", splice.dir);
    try testing.expectEqualStrings(".js", splice.extension);
}

test "detect: no .params.language anywhere → null (script-less project)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(project_dir);

    const plugins = [_]config.PluginDep{
        .{ .name = "pathfinding", .repo = "local:plugins/pathfinding" },
    };
    try testing.expect((try detect(allocator, &plugins, project_dir)) == null);
    try testing.expect((try detect(allocator, &.{}, project_dir)) == null);
}

test "detect: .params.language on a manifest-less plugin → null (no splice)" {
    // The #589 policy-test staging shape: an EMPTY local plugin dir, no
    // plugin.labelle. Policy-legal, but nothing identifies it as THE
    // scripting plugin, so nothing embeds.
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, "plugins/scripting");
    const project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(project_dir);

    const plugins = [_]config.PluginDep{
        .{ .name = "labelle-scripting", .repo = "local:plugins/scripting", .params = &.{ .{ .name = "language", .value = .{ .str = "lua" } } } },
    };
    try testing.expect((try detect(allocator, &plugins, project_dir)) == null);
}

test "detect: .params.language on a differently-named manifest → null" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "plugins/acme/plugin.labelle",
        \\.{ .name = "acme", .manifest_version = 1 }
    );
    const project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(project_dir);

    const plugins = [_]config.PluginDep{
        .{ .name = "acme", .repo = "local:plugins/acme", .params = &.{ .{ .name = "language", .value = .{ .str = "lua" } } } },
    };
    try testing.expect((try detect(allocator, &plugins, project_dir)) == null);
}

test "detect: scripting manifest WITHOUT .params.language → null (policy owns the hint)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "plugins/scripting/plugin.labelle",
        \\.{ .name = "scripting", .manifest_version = 1 }
    );
    const project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(project_dir);

    const plugins = [_]config.PluginDep{
        .{ .name = "scripting", .repo = "local:plugins/scripting" },
    };
    try testing.expect((try detect(allocator, &plugins, project_dir)) == null);
}

test "detect: an embeddable-extension gap (declared language outside the table) → null with a warning" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "plugins/scripting/plugin.labelle",
        \\.{ .name = "scripting", .manifest_version = 1 }
    );
    const project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(project_dir);

    // `rust` is policy-supported (SUPPORTED_LANGUAGES) but native-compiled —
    // no embed row — so the splice is skipped. The skip logs via
    // `std.log.warn`, which the Zig test runner tolerates (only a logged
    // `err` fails a test — see the same gate noted in render.zig).
    const plugins = [_]config.PluginDep{
        .{ .name = "scripting", .repo = "local:plugins/scripting", .params = &.{ .{ .name = "language", .value = .{ .str = "rust" } } } },
    };
    try testing.expect((try detect(allocator, &plugins, project_dir)) == null);
}

// ── the .ts transpile gate (#586 seam) ───────────────────────────────

const ts_splice_fixture = ScriptingSplice{
    .plugin_name = "scripting",
    .language = "typescript",
    .dir = "ts",
    .extension = ".js",
};

test "rejectUntranspiledScripts: a .js-only ts/ passes — including a copied labelle.d.ts and a missing dir" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);

    // No ts/ dir at all → no-op (the plugin is wired, nothing embeds).
    try rejectUntranspiledScripts(allocator, root, ts_splice_fixture);

    // Runnable .js + the documented @ts-check companion (`.d.ts` carries
    // no runtime code — copying the plugin's contract d.ts next to the
    // scripts is the README workflow, so it must never fail generate).
    try writeTestFile(tmp.dir, "ts/behavior.js", "// @ts-check\nexport function update(dt) {}\n");
    try writeTestFile(tmp.dir, "ts/labelle.d.ts", "declare const labelle: any;\n");
    try rejectUntranspiledScripts(allocator, root, ts_splice_fixture);
}

test "rejectUntranspiledScripts: a .ts source (top-level or nested) fails generate loudly" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The exact silent-death shape without the gate: authored .ts beside
    // embedded .js — the scan collects only .js, so `enemy.ts` would
    // never run and never error.
    try writeTestFile(tmp.dir, "ts/behavior.js", "export function update(dt) {}\n");
    try writeTestFile(tmp.dir, "ts/enemy.ts", "export function update(dt: number) {}\n");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);
    try testing.expectError(
        error.ScriptNeedsTranspile,
        rejectUntranspiledScripts(allocator, root, ts_splice_fixture),
    );

    // Nested subdirs gate too (stems may live in `ts/ai/…`).
    var tmp2 = testing.tmpDir(.{});
    defer tmp2.cleanup();
    try writeTestFile(tmp2.dir, "ts/ai/guard.ts", "export function update(dt: number) {}\n");
    const root2 = try tmp2.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root2);
    try testing.expectError(
        error.ScriptNeedsTranspile,
        rejectUntranspiledScripts(allocator, root2, ts_splice_fixture),
    );
}

test "rejectUntranspiledScripts: gap-less languages are a no-op (a stray .ts in lua/ is not this gate's business)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "lua/notes.ts", "// not a lua source; not embedded, not policed here\n");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);

    const lua_splice = ScriptingSplice{
        .plugin_name = "scripting",
        .language = "lua",
        .dir = "lua",
        .extension = ".lua",
    };
    try rejectUntranspiledScripts(allocator, root, lua_splice);
}
