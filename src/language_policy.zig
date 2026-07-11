//! One-language-per-project policy (labelle-assembler#584, epic
//! labelle-engine#237, `RFC-LANGUAGE-PLUGINS.md` revs 8–9).
//!
//! Scripting languages ship as ONE plugin (`labelle-scripting`) whose
//! `.plugins` entry carries a **singular** `.params = .{ .language = "lua" }`
//! parameter (the v1 slice of the generic plugin-params bag — see
//! `config.PluginDep.Params`) — mixing is unrepresentable in config. This
//! module is the generate-time enforcement layer of that policy:
//!
//!   1. **`.params.language` rules** (`resolveProjectLanguage`): the value
//!      must be a supported language (`SUPPORTED_LANGUAGES`), and at most ONE
//!      `.plugins` entry may declare it — two scripting plugins are an error.
//!   2. **`requires_language` matching** (`checkRequiresLanguage`): a
//!      plugin/pack manifest that declares `requires_language` (symmetric
//!      with `depends_on_resources`) must match the project's declared
//!      language — a Lua-scripted pack fails loudly in a Rust project,
//!      naming both sides.
//!   3. **Script-dir scan** (`scanUnitLanguageDirs`): every language
//!      convention dir (`lua/ ts/ ruby/ rust/ crystal/ go/ csharp/` — see
//!      `conventionDir`) in the game root AND in every pack dir is walked.
//!      Files in a dir belonging to a language OTHER than the declared one
//!      are a hard error listing up to `MAX_LISTED_FILES` offenders; files
//!      with NO scripting plugin declared error with the attach hint; EMPTY
//!      language dirs are warn-only. Dir-presence detection is a
//!      cross-check, not the selector (RFC rev 8) — the declared
//!      `.params.language` is authoritative.
//!
//! Everything here is parse + validate ONLY: no codegen consumes
//! `.params.language` yet (the scripting plugin that does is a separate
//! ticket), so a project
//! that declares no language and ships no language dirs generates
//! byte-identical output. The orchestrator that feeds this module from the
//! parsed config + pack entries is `generate_phases.validateLanguagePolicy`,
//! which runs beside the pack-graph gate — BEFORE the target dir is created.

const std = @import("std");
const config = @import("config.zig");

/// The closed set of script languages the toolkit recognizes
/// (RFC-LANGUAGE-PLUGINS §2/§3 — the `labelle-scripting` sub-modules). Each
/// name usually doubles as the language's convention-dir name (`lua/`,
/// `rust/`, …) — `conventionDir` is the mapping's single source of truth
/// (typescript's dir is `ts/`). Widening this table is additive; validation
/// everywhere goes through `isSupportedLanguage` so there is exactly one
/// vocabulary.
pub const SUPPORTED_LANGUAGES = [_][]const u8{
    "lua",
    "typescript",
    "ruby",
    "rust",
    "crystal",
    "go",
    "csharp",
};

/// The convention-dir name for a language's scripts — labelle-scripting's
/// documented layout ("Drop scripts in your language's convention dir
/// (`lua/`, `ruby/`, `ts/`, …)"). Every language's dir is its
/// `SUPPORTED_LANGUAGES` name except typescript, whose dir is `ts/` (the
/// plugin README + `@embedFile("ts/player.js")` examples; the ecosystem
/// short form). This helper is the ONLY place the mapping lives: the
/// script-dir scan below and the scripting splice's copy/embed
/// (`scripting_splice.detect`) both consume it, so policy and codegen can
/// never police/embed different dirs.
pub fn conventionDir(language: []const u8) []const u8 {
    if (std.mem.eql(u8, language, "typescript")) return "ts";
    return language;
}

/// Comma-joined display form of `SUPPORTED_LANGUAGES` for diagnostics.
pub const SUPPORTED_LANGUAGES_LIST: []const u8 = blk: {
    var s: []const u8 = "";
    for (SUPPORTED_LANGUAGES, 0..) |lang, i| {
        if (i > 0) s = s ++ ", ";
        s = s ++ lang;
    }
    break :blk s;
};

/// Cap on the offending-file list printed by the script-dir scan. Enough to
/// locate the problem without drowning the diagnostic when a whole foreign
/// source tree was dropped in; the total count is always reported.
pub const MAX_LISTED_FILES: usize = 10;

pub fn isSupportedLanguage(name: []const u8) bool {
    for (SUPPORTED_LANGUAGES) |lang| {
        if (std.mem.eql(u8, lang, name)) return true;
    }
    return false;
}

/// The project's declared script language plus the `.plugins` entry that
/// declared it (for diagnostics). Borrows both strings from the parsed
/// `ProjectConfig` — owns nothing.
pub const DeclaredLanguage = struct {
    language: []const u8,
    plugin_name: []const u8,
};

/// Resolve the project's declared script language from its `.plugins` list
/// (RFC rev 8: the plugin declaration carries a SINGULAR language, spelled
/// `.params = .{ .language = "…" }` — the plugin-params bag's v1 parameter).
///
/// Returns `null` when no plugin declares `.params.language` (a script-less
/// project — the overwhelmingly common case; a `.params` bag WITHOUT
/// `.language` counts as no declaration too). Errors on:
///   - `error.UnknownScriptLanguage` — a `.params.language` outside
///     `SUPPORTED_LANGUAGES`.
///   - `error.MultipleLanguagePlugins` — two `.plugins` entries both declare
///     `.params.language` (one script language per project; mixing is banned).
pub fn resolveProjectLanguage(
    plugins: []const config.PluginDep,
) error{ UnknownScriptLanguage, MultipleLanguagePlugins }!?DeclaredLanguage {
    var found: ?DeclaredLanguage = null;
    for (plugins) |p| {
        // `declaredLanguage` resolves BOTH spellings: the typed
        // `.params.language` fast path (#589) and a `language` string in the
        // generic `params_bag` (#591's tolerant parse) — the policy sees the
        // declaration no matter which parse produced the config.
        const lang = p.declaredLanguage() orelse continue;
        if (!isSupportedLanguage(lang)) {
            std.debug.print(
                "labelle-assembler: plugin '{s}' declares unknown script language \"{s}\".\n" ++
                    "  supported languages: {s}.\n",
                .{ p.name, lang, SUPPORTED_LANGUAGES_LIST },
            );
            return error.UnknownScriptLanguage;
        }
        if (found) |first| {
            std.debug.print(
                "labelle-assembler: at most ONE plugin may declare `.params.language` (one script language per project):\n" ++
                    "  plugin '{s}' declares .params.language = \"{s}\"\n" ++
                    "  plugin '{s}' declares .params.language = \"{s}\"\n" ++
                    "  remove one of the two declarations.\n",
                .{ first.plugin_name, first.language, p.name, lang },
            );
            return error.MultipleLanguagePlugins;
        }
        found = .{ .language = lang, .plugin_name = p.name };
    }
    return found;
}

/// Validate one attached unit's `requires_language` against the project's
/// declared language (RFC rev 8: "validated on attach, so a Lua-scripted
/// pack fails loudly in a Rust project"). `unit_kind` is `"plugin"` or
/// `"pack"` — display only. A `null` requirement always passes (the unit
/// ships no language scripts).
///
/// Errors on:
///   - `error.UnknownScriptLanguage` — the requirement names a language
///     outside `SUPPORTED_LANGUAGES` (also rejected at manifest load; this
///     re-check keeps hand-built manifests in tests honest).
///   - `error.LanguageRequirementMismatch` — the requirement doesn't match
///     the project's declared language (including "project declares none").
pub fn checkRequiresLanguage(
    unit_kind: []const u8,
    unit_name: []const u8,
    requires: ?[]const u8,
    declared: ?DeclaredLanguage,
) error{ UnknownScriptLanguage, LanguageRequirementMismatch }!void {
    const req = requires orelse return;
    if (!isSupportedLanguage(req)) {
        std.debug.print(
            "labelle-assembler: {s} '{s}' declares requires_language \"{s}\", which is not a supported script language.\n" ++
                "  supported languages: {s}.\n",
            .{ unit_kind, unit_name, req, SUPPORTED_LANGUAGES_LIST },
        );
        return error.UnknownScriptLanguage;
    }
    if (declared) |d| {
        if (std.mem.eql(u8, d.language, req)) return;
        std.debug.print(
            "labelle-assembler: {s} '{s}' requires script language \"{s}\" but the project's declared language is \"{s}\" (plugin '{s}').\n" ++
                "  one script language per project: attach only {s}s matching the project language, or change the scripting plugin's `.params.language`.\n",
            .{ unit_kind, unit_name, req, d.language, d.plugin_name, unit_kind },
        );
        return error.LanguageRequirementMismatch;
    }
    std.debug.print(
        "labelle-assembler: {s} '{s}' requires script language \"{s}\" but the project declares no script language.\n" ++
            "  attach the scripting plugin in project.labelle with `.params = .{{ .language = \"{s}\" }}`.\n",
        .{ unit_kind, unit_name, req, req },
    );
    return error.LanguageRequirementMismatch;
}

/// Result of walking one `<unit>/<lang>/` convention dir: up to
/// `MAX_LISTED_FILES` relative paths (`<lang>/…`, each an owned string) plus
/// the TOTAL file count (which may exceed `listed.len`).
pub const LanguageDirScan = struct {
    listed: [][]const u8,
    total: usize,

    pub fn deinit(self: *LanguageDirScan, allocator: std.mem.Allocator) void {
        for (self.listed) |p| allocator.free(p);
        allocator.free(self.listed);
    }
};

/// Walk `<unit_root>/<lang>/` recursively, counting files and collecting up
/// to `MAX_LISTED_FILES` relative paths for diagnostics. Returns `null` when
/// the dir doesn't exist (or `<lang>` is a plain file — not a convention
/// dir). Dot-entries (`.gitkeep`, `.DS_Store`, hidden dirs) are skipped so a
/// placeholder-kept empty dir stays "empty" for the warn-only rule.
pub fn collectLanguageDirFiles(
    allocator: std.mem.Allocator,
    unit_root: []const u8,
    lang: []const u8,
) !?LanguageDirScan {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const dir_path = try std.fs.path.join(allocator, &.{ unit_root, lang });
    defer allocator.free(dir_path);
    var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    defer dir.close(io);

    var listed: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (listed.items) |p| allocator.free(p);
        listed.deinit(allocator);
    }
    var total: usize = 0;
    try walkCollect(allocator, io, dir, lang, &listed, &total);
    return .{ .listed = try listed.toOwnedSlice(allocator), .total = total };
}

fn walkCollect(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    rel_prefix: []const u8,
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
                try walkCollect(allocator, io, sub, sub_prefix, listed, total);
            },
            else => {
                total.* += 1;
                if (listed.items.len < MAX_LISTED_FILES) {
                    const rel = try std.fs.path.join(allocator, &.{ rel_prefix, entry.name });
                    errdefer allocator.free(rel);
                    try listed.append(allocator, rel);
                }
            },
        }
    }
}

/// Scan ONE unit root (the game root, or a pack's source dir) for language
/// convention dirs and enforce the policy (RFC rev 8's generate-time layer):
///
///   - the DECLARED language's convention dir → fine, skipped entirely;
///   - another language's convention dir WITH files →
///     `error.ScriptLanguageMismatch`, listing up to `MAX_LISTED_FILES`
///     offenders + the fix;
///   - any convention dir WITH files but NO declared language →
///     `error.MissingScriptingPlugin`, with the attach hint;
///   - an EMPTY language dir → warn-only (a placeholder never fails a build);
///   - a language-NAME dir that is NOT the convention dir (`typescript/`,
///     whose convention dir is `ts/` — `conventionDir`) WITH files →
///     `error.MisplacedLanguageDir`. NOTHING ever consumes such a dir, so
///     scripts dropped there (an easy guess from the language vocabulary)
///     would otherwise be silently dead — fail loudly naming the real home.
///
/// `unit_label` names the scanned unit in diagnostics — `"project root"` or
/// `"pack 'sky'"`.
pub fn scanUnitLanguageDirs(
    allocator: std.mem.Allocator,
    unit_root: []const u8,
    unit_label: []const u8,
    declared: ?DeclaredLanguage,
) !void {
    for (SUPPORTED_LANGUAGES) |lang| {
        const dir = conventionDir(lang);

        // The language-name-≠-convention-dir trap (typescript/ vs ts/):
        // policed for EVERY language declaration state, because no
        // declaration state makes the dir meaningful.
        if (!std.mem.eql(u8, dir, lang)) {
            var maybe_misplaced = try collectLanguageDirFiles(allocator, unit_root, lang);
            if (maybe_misplaced) |*misplaced| {
                defer misplaced.deinit(allocator);
                if (misplaced.total > 0) {
                    std.debug.print(
                        "labelle-assembler: {s} contains {s}/ files, but the {s} script convention dir is {s}/:\n",
                        .{ unit_label, lang, lang, dir },
                    );
                    printListed(misplaced.*);
                    std.debug.print(
                        "  nothing reads {s}/ — move the scripts to {s}/ (or remove the directory).\n",
                        .{ lang, dir },
                    );
                    return error.MisplacedLanguageDir;
                }
                std.log.warn(
                    "labelle: {s} has an empty '{s}/' dir; ignoring it (the {s} script convention dir is '{s}/')",
                    .{ unit_label, lang, lang, dir },
                );
            }
        }

        if (declared) |d| {
            // The declared language's own dir is the legal home of the
            // project's scripts — nothing to police there in this ticket
            // (the scripting plugin consumes it, separately).
            if (std.mem.eql(u8, d.language, lang)) continue;
        }
        var scanned = (try collectLanguageDirFiles(allocator, unit_root, dir)) orelse continue;
        defer scanned.deinit(allocator);

        if (scanned.total == 0) {
            if (declared) |d| {
                std.log.warn(
                    "labelle: {s} has an empty '{s}/' script-language dir; ignoring it (the project's script language is \"{s}\")",
                    .{ unit_label, dir, d.language },
                );
            } else {
                std.log.warn(
                    "labelle: {s} has an empty '{s}/' script-language dir; ignoring it (no scripting plugin is declared)",
                    .{ unit_label, dir },
                );
            }
            continue;
        }

        if (declared) |d| {
            std.debug.print(
                "labelle-assembler: {s} contains {s}/ scripts but the project's script language is \"{s}\" (plugin '{s}'):\n",
                .{ unit_label, dir, d.language, d.plugin_name },
            );
            printListed(scanned);
            std.debug.print(
                "  one script language per project (RFC-LANGUAGE-PLUGINS): remove these files or change the scripting plugin's `.params.language`.\n",
                .{},
            );
            return error.ScriptLanguageMismatch;
        }

        std.debug.print(
            "labelle-assembler: {s} contains {s}/ scripts but no scripting plugin is declared:\n",
            .{ unit_label, dir },
        );
        printListed(scanned);
        std.debug.print(
            "  attach the scripting plugin in project.labelle to run them, e.g.\n" ++
                "    .plugins = .{{ .{{ .name = \"labelle-scripting\", .version = \"...\", .params = .{{ .language = \"{s}\" }} }} }}\n" ++
                "  or remove the {s}/ directory.\n",
            .{ lang, dir },
        );
        return error.MissingScriptingPlugin;
    }
}

fn printListed(scanned: LanguageDirScan) void {
    for (scanned.listed) |rel| std.debug.print("  {s}\n", .{rel});
    if (scanned.total > scanned.listed.len) {
        std.debug.print("  ... and {d} more\n", .{scanned.total - scanned.listed.len});
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "isSupportedLanguage: table membership is exact (no case folding)" {
    for (SUPPORTED_LANGUAGES) |lang| {
        try testing.expect(isSupportedLanguage(lang));
    }
    try testing.expect(!isSupportedLanguage("cobol"));
    try testing.expect(!isSupportedLanguage("Lua"));
    try testing.expect(!isSupportedLanguage(""));
}

test "SUPPORTED_LANGUAGES_LIST: comma-joined display form" {
    try testing.expectEqualStrings(
        "lua, typescript, ruby, rust, crystal, go, csharp",
        SUPPORTED_LANGUAGES_LIST,
    );
}

test "conventionDir: typescript maps to ts/; every other language dirs under its own name" {
    try testing.expectEqualStrings("ts", conventionDir("typescript"));
    for (SUPPORTED_LANGUAGES) |lang| {
        if (std.mem.eql(u8, lang, "typescript")) continue;
        try testing.expectEqualStrings(lang, conventionDir(lang));
    }
}

test "resolveProjectLanguage: no declaration → null (script-less project)" {
    const plugins = [_]config.PluginDep{
        .{ .name = "pathfinding", .version = "4.0.1" },
    };
    try testing.expect((try resolveProjectLanguage(&plugins)) == null);
    try testing.expect((try resolveProjectLanguage(&.{})) == null);
}

test "resolveProjectLanguage: `.params` bag WITHOUT `.language` → null (#584)" {
    // A plugin may carry a `.params` bag that sets no `.language` (today the
    // bag has no other parameter; schema-declared params are the follow-up
    // ticket). That is NOT a script-language declaration.
    const plugins = [_]config.PluginDep{
        .{ .name = "pathfinding", .version = "4.0.1", .params = .{} },
    };
    try testing.expect((try resolveProjectLanguage(&plugins)) == null);
}

test "resolveProjectLanguage: one valid declaration → language + owning plugin" {
    const plugins = [_]config.PluginDep{
        .{ .name = "pathfinding", .version = "4.0.1" },
        .{ .name = "labelle-scripting", .version = "0.1.0", .params = .{ .language = "lua" } },
    };
    const declared = (try resolveProjectLanguage(&plugins)).?;
    try testing.expectEqualStrings("lua", declared.language);
    try testing.expectEqualStrings("labelle-scripting", declared.plugin_name);
}

test "resolveProjectLanguage: unknown vocabulary errors (#584)" {
    const plugins = [_]config.PluginDep{
        .{ .name = "labelle-scripting", .params = .{ .language = "cobol" } },
    };
    try testing.expectError(error.UnknownScriptLanguage, resolveProjectLanguage(&plugins));
}

test "resolveProjectLanguage: two `.params.language` declarations error (#584)" {
    // Two scripting plugins — even AGREEING on the language — are an error:
    // the policy is one scripting plugin entry, singular `.params.language`.
    const plugins = [_]config.PluginDep{
        .{ .name = "labelle-scripting", .params = .{ .language = "lua" } },
        .{ .name = "acme-scripting", .params = .{ .language = "rust" } },
    };
    try testing.expectError(error.MultipleLanguagePlugins, resolveProjectLanguage(&plugins));

    const agreeing = [_]config.PluginDep{
        .{ .name = "labelle-scripting", .params = .{ .language = "lua" } },
        .{ .name = "acme-scripting", .params = .{ .language = "lua" } },
    };
    try testing.expectError(error.MultipleLanguagePlugins, resolveProjectLanguage(&agreeing));
}

test "checkRequiresLanguage: absent requirement and exact match both pass" {
    const declared = DeclaredLanguage{ .language = "lua", .plugin_name = "labelle-scripting" };
    try checkRequiresLanguage("pack", "dungeon", null, declared);
    try checkRequiresLanguage("pack", "dungeon", "lua", declared);
    // Absent requirement also passes on a project with NO declared language.
    try checkRequiresLanguage("plugin", "physics", null, null);
}

test "checkRequiresLanguage: mismatch errors naming both sides (#584)" {
    const declared = DeclaredLanguage{ .language = "rust", .plugin_name = "labelle-scripting" };
    try testing.expectError(
        error.LanguageRequirementMismatch,
        checkRequiresLanguage("pack", "dungeon", "lua", declared),
    );
}

test "checkRequiresLanguage: requirement with no declared language errors" {
    try testing.expectError(
        error.LanguageRequirementMismatch,
        checkRequiresLanguage("pack", "dungeon", "ruby", null),
    );
}

test "checkRequiresLanguage: unknown vocabulary errors" {
    const declared = DeclaredLanguage{ .language = "lua", .plugin_name = "labelle-scripting" };
    try testing.expectError(
        error.UnknownScriptLanguage,
        checkRequiresLanguage("pack", "dungeon", "cobol", declared),
    );
}

// ── script-dir scan (filesystem) ────────────────────────────────────

fn writeTestFile(dir: std.Io.Dir, rel: []const u8, body: []const u8) !void {
    const tio = testing.io;
    if (std.fs.path.dirname(rel)) |sub| try dir.createDirPath(tio, sub);
    var f = try dir.createFile(tio, rel, .{});
    defer f.close(tio);
    try f.writeStreamingAll(tio, body);
}

test "collectLanguageDirFiles: nested files counted, dotfiles skipped, listing capped" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "rust/lib.rs", "pub fn a() {}\n");
    try writeTestFile(tmp.dir, "rust/native/collision.rs", "pub fn b() {}\n");
    try writeTestFile(tmp.dir, "rust/.gitkeep", ""); // dotfile — not a script
    // 10 more files to push the total past MAX_LISTED_FILES.
    for (0..MAX_LISTED_FILES) |i| {
        var buf: [64]u8 = undefined;
        const rel = try std.fmt.bufPrint(&buf, "rust/extra/mod_{d}.rs", .{i});
        try writeTestFile(tmp.dir, rel, "pub fn x() {}\n");
    }

    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);

    var scanned = (try collectLanguageDirFiles(allocator, root, "rust")).?;
    defer scanned.deinit(allocator);

    try testing.expectEqual(@as(usize, 2 + MAX_LISTED_FILES), scanned.total);
    try testing.expectEqual(MAX_LISTED_FILES, scanned.listed.len);
    for (scanned.listed) |rel| {
        try testing.expect(std.mem.startsWith(u8, rel, "rust"));
    }
}

test "collectLanguageDirFiles: absent dir → null" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);
    try testing.expect((try collectLanguageDirFiles(allocator, root, "lua")) == null);
}

test "scanUnitLanguageDirs: a rust/ file in a lua project is a hard error (#584)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "rust/native/collision.rs", "pub fn solve() {}\n");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);

    const declared = DeclaredLanguage{ .language = "lua", .plugin_name = "labelle-scripting" };
    try testing.expectError(
        error.ScriptLanguageMismatch,
        scanUnitLanguageDirs(allocator, root, "project root", declared),
    );
}

test "scanUnitLanguageDirs: language files with NO scripting plugin error with the attach hint" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "lua/player_ai.lua", "return {}\n");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);

    try testing.expectError(
        error.MissingScriptingPlugin,
        scanUnitLanguageDirs(allocator, root, "project root", null),
    );
}

test "scanUnitLanguageDirs: the declared language's own dir passes" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "lua/player_ai.lua", "return {}\n");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);

    const declared = DeclaredLanguage{ .language = "lua", .plugin_name = "labelle-scripting" };
    try scanUnitLanguageDirs(allocator, root, "project root", declared);
}

test "scanUnitLanguageDirs: an EMPTY foreign language dir is warn-only" {
    const allocator = testing.allocator;
    const tio = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Empty rust/ (and a dotfile-only go/ — placeholders don't count as
    // scripts) in a lua project: warn, never fail.
    try tmp.dir.createDirPath(tio, "rust");
    try writeTestFile(tmp.dir, "go/.gitkeep", "");
    const root = try tmp.dir.realPathFileAlloc(tio, ".", allocator);
    defer allocator.free(root);

    const declared = DeclaredLanguage{ .language = "lua", .plugin_name = "labelle-scripting" };
    try scanUnitLanguageDirs(allocator, root, "project root", declared);
    // Same for a project with no scripting plugin at all.
    try scanUnitLanguageDirs(allocator, root, "project root", null);
}

test "scanUnitLanguageDirs: typescript scripts live in ts/ — skipped when declared, mismatch/attach errors otherwise" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "ts/behavior.js", "export function update(dt) {}\n");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);

    // Declared typescript → ts/ is the legal home (the conventionDir keys
    // the declared-language skip, or the scan would reject its own scripts).
    const ts_declared = DeclaredLanguage{ .language = "typescript", .plugin_name = "scripting" };
    try scanUnitLanguageDirs(allocator, root, "project root", ts_declared);

    // Declared lua → ts/ files are a foreign language, hard error.
    const lua_declared = DeclaredLanguage{ .language = "lua", .plugin_name = "scripting" };
    try testing.expectError(
        error.ScriptLanguageMismatch,
        scanUnitLanguageDirs(allocator, root, "project root", lua_declared),
    );

    // No plugin at all → the attach hint (spelling the POLICY vocabulary
    // "typescript", not the dir name).
    try testing.expectError(
        error.MissingScriptingPlugin,
        scanUnitLanguageDirs(allocator, root, "project root", null),
    );
}

test "scanUnitLanguageDirs: a typescript/ dir with files is a MISPLACED-dir error in every declaration state" {
    // `typescript/` is the language NAME, not its convention dir (`ts/` —
    // conventionDir); nothing ever reads it, so scripts dropped there would
    // be silently dead. Loud in all three states — including declared
    // typescript, where the declared-language skip must NOT excuse it.
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "typescript/behavior.js", "export function update(dt) {}\n");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);

    const ts_declared = DeclaredLanguage{ .language = "typescript", .plugin_name = "scripting" };
    const lua_declared = DeclaredLanguage{ .language = "lua", .plugin_name = "scripting" };
    try testing.expectError(error.MisplacedLanguageDir, scanUnitLanguageDirs(allocator, root, "project root", ts_declared));
    try testing.expectError(error.MisplacedLanguageDir, scanUnitLanguageDirs(allocator, root, "project root", lua_declared));
    try testing.expectError(error.MisplacedLanguageDir, scanUnitLanguageDirs(allocator, root, "project root", null));
}

test "scanUnitLanguageDirs: an EMPTY typescript/ dir is warn-only, like every empty language dir" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, "typescript");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);

    try scanUnitLanguageDirs(allocator, root, "project root", null);
    const ts_declared = DeclaredLanguage{ .language = "typescript", .plugin_name = "scripting" };
    try scanUnitLanguageDirs(allocator, root, "project root", ts_declared);
}

test "scanUnitLanguageDirs: no language dirs at all is a clean pass" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);
    try scanUnitLanguageDirs(allocator, root, "project root", null);
    const declared = DeclaredLanguage{ .language = "lua", .plugin_name = "labelle-scripting" };
    try scanUnitLanguageDirs(allocator, root, "project root", declared);
}
