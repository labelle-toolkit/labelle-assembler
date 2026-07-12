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
//!   3. **Shared-dir scan** (`scanUnitLanguageDirs`): script-language files
//!      live in the SAME structure Zig files use (labelle-engine#237) —
//!      scripts in `scripts/` (`SCRIPTS_DIR`), component DECLARATIONS in
//!      `components/` (the #237 refinement: files live where their kind
//!      lives), the extension selecting the language in both. The scan
//!      polices BOTH dirs by EXTENSION (`scriptExtensions`): files of a
//!      language OTHER than the declared one are a hard error listing up
//!      to `MAX_LISTED_FILES` offenders; language files with NO scripting
//!      plugin declared error with the attach hint (`.zig` belongs to no
//!      script language — the Zig scanners own it, so Zig + script-language
//!      files coexist in one dir).
//!      The old per-language dirs (`lua/ ts/ ruby/ rust/ crystal/ go/
//!      csharp/` — `legacyDir`) are DEPRECATED but still policed the old
//!      way for the one-release grace window: foreign-language legacy dirs
//!      with files are a hard error, no-plugin files get the attach hint,
//!      EMPTY legacy dirs are warn-only. Dir/extension detection is a
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
/// (RFC-LANGUAGE-PLUGINS §2/§3 — the `labelle-scripting` sub-modules).
/// Widening this table is additive; validation everywhere goes through
/// `isSupportedLanguage` so there is exactly one vocabulary. Each language
/// carries an extension set (`scriptExtensions`) and a deprecated legacy
/// dir name (`legacyDir`); the scripts themselves live in `SCRIPTS_DIR`.
pub const SUPPORTED_LANGUAGES = [_][]const u8{
    "lua",
    "typescript",
    "ruby",
    "rust",
    "crystal",
    "go",
    "csharp",
};

/// The convention dir script-language files live in — the SAME `scripts/`
/// structure Zig scripts use (labelle-engine#237's convention decision):
/// `scripts/hunger.rb` sits exactly where `scripts/hunger.zig` would, the
/// extension selects the language, and Zig + script-language files coexist
/// in one dir (the two-layer architecture in one structure). The Zig
/// conventions apply cross-language where the runtime supports them:
/// numeric ordering prefixes immediately; state-scoped subdirs
/// (`scripts/<state>/`) stay Zig-ONLY until the scripting Controller grows
/// state awareness.
pub const SCRIPTS_DIR: []const u8 = "scripts";

/// The DEPRECATED per-language dir a language's scripts used to live in
/// (`lua/`, `ruby/`, `rust/`, … — typescript's was `ts/`, the ecosystem
/// short form). Kept working for ONE release of grace: when `scripts/`
/// holds no language files and the legacy dir does, the scripting splice
/// consumes the legacy dir with a pointed deprecation note
/// (`scripting_splice.detect`); both populated is a hard error (never
/// merged). This helper is the ONLY place the mapping lives — the
/// legacy-dir policing below and the splice's grace fallback both consume
/// it, so policy and codegen can never police/read different dirs.
pub fn legacyDir(language: []const u8) []const u8 {
    if (std.mem.eql(u8, language, "typescript")) return "ts";
    return language;
}

/// The file extensions that identify `language`'s sources inside the shared
/// `scripts/` dir — the extension IS the language selector now
/// (labelle-engine#237). Includes authoring extensions the assembler can't
/// run yet (typescript's `.ts`, gated separately by the #586 transpile
/// check) so misplaced sources are attributed to their language rather
/// than silently unmatched. `.zig` deliberately belongs to NO script
/// language: the Zig script scanner owns it. The scripting splice's
/// embed/native rows each use one of these extensions — a test in
/// `scripting_splice.zig` pins the two tables' agreement.
pub fn scriptExtensions(language: []const u8) []const []const u8 {
    if (std.mem.eql(u8, language, "lua")) return &.{".lua"};
    if (std.mem.eql(u8, language, "typescript")) return &.{ ".js", ".ts" };
    if (std.mem.eql(u8, language, "ruby")) return &.{".rb"};
    if (std.mem.eql(u8, language, "rust")) return &.{".rs"};
    if (std.mem.eql(u8, language, "crystal")) return &.{".cr"};
    if (std.mem.eql(u8, language, "go")) return &.{".go"};
    if (std.mem.eql(u8, language, "csharp")) return &.{".cs"};
    return &.{};
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

/// Scan ONE unit root (the game root, or a pack's source dir) for
/// script-language sources and enforce the policy (RFC rev 8's
/// generate-time layer, re-homed on the `scripts/` convention —
/// labelle-engine#237):
///
///   `scripts/` and `components/` (the shared convention dirs — policed by
///   EXTENSION, since the extension is the language selector there; `.zig`
///   belongs to no script language and is invisible to this scan):
///   - the DECLARED language's files → fine, skipped entirely (the
///     scripting splice consumes them and owns the deeper checks — the
///     state-subdir gate, the transpile machinery, the components/
///     authoring-source guard);
///   - another language's files → `error.ScriptLanguageMismatch`, listing
///     up to `MAX_LISTED_FILES` offenders + the fix;
///   - language files but NO declared language →
///     `error.MissingScriptingPlugin`, with the attach hint.
///
///   Legacy per-language dirs (`lua/`, `ts/`, … — `legacyDir`; one release
///   of grace, the splice prints the deprecation note when it consumes one):
///   - the DECLARED language's legacy dir → skipped (the splice's grace
///     fallback owns it, including the both-populated conflict);
///   - another language's legacy dir WITH files →
///     `error.ScriptLanguageMismatch`;
///   - any legacy dir WITH files but NO declared language →
///     `error.MissingScriptingPlugin`;
///   - an EMPTY legacy dir → warn-only (a placeholder never fails a build);
///   - a language-NAME dir that never was a convention dir (`typescript/` —
///     its legacy dir is `ts/`) WITH files → `error.MisplacedLanguageDir`.
///     NOTHING ever consumed such a dir, so scripts dropped there would be
///     silently dead — fail loudly naming the real home (`scripts/`).
///
/// `unit_label` names the scanned unit in diagnostics — `"project root"` or
/// `"pack 'sky'"`. (Pack `scripts/` language sources aren't consumed yet —
/// the splice reads only the game root — but the same policing keeps them
/// honest for when they are.)
pub fn scanUnitLanguageDirs(
    allocator: std.mem.Allocator,
    unit_root: []const u8,
    unit_label: []const u8,
    declared: ?DeclaredLanguage,
) !void {
    for (SUPPORTED_LANGUAGES) |lang| {
        const dir = legacyDir(lang);

        // The language-name-≠-dir trap (typescript/ vs ts/): policed for
        // EVERY language declaration state, because no declaration state
        // makes the dir meaningful.
        if (!std.mem.eql(u8, dir, lang)) {
            var maybe_misplaced = try collectLanguageDirFiles(allocator, unit_root, lang);
            if (maybe_misplaced) |*misplaced| {
                defer misplaced.deinit(allocator);
                if (misplaced.total > 0) {
                    std.debug.print(
                        "labelle-assembler: {s} contains {s}/ files, but script-language files live in the {s}/ convention dir:\n",
                        .{ unit_label, lang, SCRIPTS_DIR },
                    );
                    printListed(misplaced.*);
                    std.debug.print(
                        "  nothing reads {s}/ — move the scripts to {s}/ (or remove the directory).\n",
                        .{ lang, SCRIPTS_DIR },
                    );
                    return error.MisplacedLanguageDir;
                }
                std.log.warn(
                    "labelle: {s} has an empty '{s}/' dir; ignoring it (script-language files live in '{s}/')",
                    .{ unit_label, lang, SCRIPTS_DIR },
                );
            }
        }

        if (declared) |d| {
            // The declared language's own legacy dir is grace-tolerated for
            // one release — the scripting splice consumes it (with the
            // deprecation note) and errors when scripts/ is ALSO populated.
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
                "  and move them to {s}/ ({s}/ is deprecated), or remove the {s}/ directory.\n",
            .{ lang, SCRIPTS_DIR, dir, dir },
        );
        return error.MissingScriptingPlugin;
    }

    try scanSharedDirLanguages(allocator, unit_root, unit_label, declared, SCRIPTS_DIR);
    try scanSharedDirLanguages(allocator, unit_root, unit_label, declared, "components");
}

/// The shared-convention-dir half of `scanUnitLanguageDirs`: walk ONE
/// extension-keyed shared dir (`scripts/` — and, since labelle-engine#237's
/// refinement, `components/`, where the declared language's DECLARATION
/// files live beside the Zig components) once, bucket every file by the
/// language its extension belongs to (`scriptExtensions`; unmatched
/// extensions — `.zig`, `.md`, editor droppings — are invisible), and
/// enforce the same two rules the legacy dirs get: foreign language →
/// mismatch, no declared language → attach hint. The DECLARED language's
/// files are never collected — the scripting splice owns them (collection,
/// state-subdir gate, ordering, the components/ transpile guard). Buckets
/// error in `SUPPORTED_LANGUAGES` order so diagnostics are deterministic.
fn scanSharedDirLanguages(
    allocator: std.mem.Allocator,
    unit_root: []const u8,
    unit_label: []const u8,
    declared: ?DeclaredLanguage,
    shared_dir: []const u8,
) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const dir_path = try std.fs.path.join(allocator, &.{ unit_root, shared_dir });
    defer allocator.free(dir_path);
    var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer dir.close(io);

    var buckets: [SUPPORTED_LANGUAGES.len]LanguageBucket = @splat(.{});
    defer for (&buckets) |*b| b.deinit(allocator);
    try walkSharedCollect(allocator, io, dir, shared_dir, declared, &buckets);

    for (SUPPORTED_LANGUAGES, &buckets) |lang, *bucket| {
        if (bucket.total == 0) continue;
        const scanned = LanguageDirScan{ .listed = bucket.listed.items, .total = bucket.total };

        if (declared) |d| {
            std.debug.print(
                "labelle-assembler: {s} {s}/ contains {s} files but the project's script language is \"{s}\" (plugin '{s}'):\n",
                .{ unit_label, shared_dir, lang, d.language, d.plugin_name },
            );
            printListed(scanned);
            std.debug.print(
                "  one script language per project (RFC-LANGUAGE-PLUGINS): remove these files or change the scripting plugin's `.params.language`.\n",
                .{},
            );
            return error.ScriptLanguageMismatch;
        }

        std.debug.print(
            "labelle-assembler: {s} {s}/ contains {s} files but no scripting plugin is declared:\n",
            .{ unit_label, shared_dir, lang },
        );
        printListed(scanned);
        std.debug.print(
            "  attach the scripting plugin in project.labelle to run them, e.g.\n" ++
                "    .plugins = .{{ .{{ .name = \"labelle-scripting\", .version = \"...\", .params = .{{ .language = \"{s}\" }} }} }}\n" ++
                "  or remove the files.\n",
            .{lang},
        );
        return error.MissingScriptingPlugin;
    }
}

const LanguageBucket = struct {
    listed: std.ArrayList([]const u8) = .empty,
    total: usize = 0,

    fn deinit(self: *LanguageBucket, allocator: std.mem.Allocator) void {
        for (self.listed.items) |p| allocator.free(p);
        self.listed.deinit(allocator);
    }
};

/// One recursive walk of a shared convention dir (`scripts/`,
/// `components/`), bucketing files by extension-owning language.
/// Dot-entries skipped (same rule as `walkCollect`); the declared
/// language's files are skipped entirely — their policing belongs to the
/// scripting splice.
fn walkSharedCollect(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    rel_prefix: []const u8,
    declared: ?DeclaredLanguage,
    buckets: *[SUPPORTED_LANGUAGES.len]LanguageBucket,
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
                try walkSharedCollect(allocator, io, sub, sub_prefix, declared, buckets);
            },
            else => {
                for (SUPPORTED_LANGUAGES, buckets) |lang, *bucket| {
                    if (declared) |d| {
                        if (std.mem.eql(u8, d.language, lang)) continue;
                    }
                    const matches = for (scriptExtensions(lang)) |ext| {
                        if (std.mem.endsWith(u8, entry.name, ext)) break true;
                    } else false;
                    if (!matches) continue;
                    bucket.total += 1;
                    if (bucket.listed.items.len < MAX_LISTED_FILES) {
                        const rel = try std.fs.path.join(allocator, &.{ rel_prefix, entry.name });
                        errdefer allocator.free(rel);
                        try bucket.listed.append(allocator, rel);
                    }
                    break; // extensions are disjoint across languages
                }
            },
        }
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

test "legacyDir: typescript maps to ts/; every other language's legacy dir is its own name; none is scripts/" {
    try testing.expectEqualStrings("ts", legacyDir("typescript"));
    for (SUPPORTED_LANGUAGES) |lang| {
        if (std.mem.eql(u8, lang, "typescript")) continue;
        try testing.expectEqualStrings(lang, legacyDir(lang));
    }
    // The grace fallback keys on legacy ≠ convention — no language's legacy
    // dir may ever collide with the scripts/ home.
    for (SUPPORTED_LANGUAGES) |lang| {
        try testing.expect(!std.mem.eql(u8, legacyDir(lang), SCRIPTS_DIR));
    }
}

test "scriptExtensions: every language owns at least one extension; extensions are disjoint across languages; .zig belongs to none" {
    for (SUPPORTED_LANGUAGES) |lang| {
        try testing.expect(scriptExtensions(lang).len > 0);
    }
    try testing.expectEqual(@as(usize, 0), scriptExtensions("cobol").len);

    // Disjointness is what lets the scripts/ scan attribute a file to ONE
    // language (and lets two scanners share the dir without contention).
    for (SUPPORTED_LANGUAGES, 0..) |a, i| {
        for (SUPPORTED_LANGUAGES[i + 1 ..]) |b| {
            for (scriptExtensions(a)) |ea| {
                for (scriptExtensions(b)) |eb| {
                    try testing.expect(!std.mem.eql(u8, ea, eb));
                }
            }
        }
    }
    // .zig is the ZIG script scanner's — never a script-language extension.
    for (SUPPORTED_LANGUAGES) |lang| {
        for (scriptExtensions(lang)) |ext| {
            try testing.expect(!std.mem.eql(u8, ext, ".zig"));
        }
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

test "resolveProjectLanguage: the enum-literal bag spelling (.lua) resolves — and its vocabulary is checked (#591 P2)" {
    // A schema-declared enum `language` param arrives in the generic bag as
    // an ENUM TAG (`.params = .{ .language = .lua }`). The policy resolves
    // it through `PluginDep.declaredLanguage` — before the fix the enum
    // spelling read as "no declaration" and the one-language checks (and
    // the scripting splice downstream) silently skipped.
    const Param = @import("plugin_params.zig").Param;
    const lua_bag = [_]Param{.{ .name = "language", .value = .{ .enum_tag = "lua" } }};
    const plugins = [_]config.PluginDep{
        .{ .name = "scripting", .params_bag = &lua_bag },
    };
    const declared = (try resolveProjectLanguage(&plugins)).?;
    try testing.expectEqualStrings("lua", declared.language);
    try testing.expectEqualStrings("scripting", declared.plugin_name);

    // The closed-vocabulary check applies to the enum spelling too.
    const bad_bag = [_]Param{.{ .name = "language", .value = .{ .enum_tag = "cobol" } }};
    const bad = [_]config.PluginDep{.{ .name = "scripting", .params_bag = &bad_bag }};
    try testing.expectError(error.UnknownScriptLanguage, resolveProjectLanguage(&bad));
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

test "scanUnitLanguageDirs: legacy ts/ scripts — skipped when declared (grace), mismatch/attach errors otherwise" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "ts/behavior.js", "export function update(dt) {}\n");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);

    // Declared typescript → ts/ is the grace-tolerated legacy home (the
    // legacyDir keys the declared-language skip; the splice owns the
    // deprecation note + both-populated conflict).
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
    // `typescript/` is the language NAME — never a convention dir, never a
    // legacy dir (`ts/` — legacyDir); nothing ever reads it, so scripts
    // dropped there would be silently dead. Loud in all three states —
    // including declared typescript, where the declared-language skip must
    // NOT excuse it. The message now names scripts/ as the real home.
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

// ── scripts/-content policing (the shared convention dir, #237) ──────

test "scanUnitLanguageDirs: a foreign-extension file in scripts/ is a hard error (extension-keyed mismatch)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The old rust/-dir-in-a-lua-project protection, re-homed: a .rs in
    // the shared scripts/ dir would be silently dead (neither the Zig
    // scanner nor the lua splice reads it) — same silent-death class,
    // same error. Nested placement is caught too (the walk is recursive).
    try writeTestFile(tmp.dir, "scripts/enemy.rs", "pub struct Enemy;\n");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);

    const declared = DeclaredLanguage{ .language = "lua", .plugin_name = "labelle-scripting" };
    try testing.expectError(
        error.ScriptLanguageMismatch,
        scanUnitLanguageDirs(allocator, root, "project root", declared),
    );

    var tmp2 = testing.tmpDir(.{});
    defer tmp2.cleanup();
    try writeTestFile(tmp2.dir, "scripts/playing/enemy.rb", "class Enemy; end\n");
    const root2 = try tmp2.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root2);
    try testing.expectError(
        error.ScriptLanguageMismatch,
        scanUnitLanguageDirs(allocator, root2, "project root", declared),
    );
}

test "scanUnitLanguageDirs: language files in scripts/ with NO scripting plugin error with the attach hint" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "scripts/player_ai.lua", "return {}\n");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);

    try testing.expectError(
        error.MissingScriptingPlugin,
        scanUnitLanguageDirs(allocator, root, "project root", null),
    );
}

test "scanUnitLanguageDirs: the declared language's scripts/ files pass — the splice owns them" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "scripts/player_ai.lua", "return {}\n");
    // Even in a state subdir: the policy skips declared-language files
    // entirely — the state-subdir gate is the SPLICE's pointed error
    // (scripting_splice.detect), not a policy mismatch.
    try writeTestFile(tmp.dir, "scripts/playing/boss.lua", "return {}\n");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);

    const declared = DeclaredLanguage{ .language = "lua", .plugin_name = "labelle-scripting" };
    try scanUnitLanguageDirs(allocator, root, "project root", declared);
}

test "scanUnitLanguageDirs: a Zig-only scripts/ is invisible to the language scan (coexistence negative control)" {
    // THE back-compat pin: every existing Zig game (and pack) has
    // scripts/*.zig and NO scripting plugin — the extension-keyed scan
    // must never see them. Same for non-language files (.md, dotfiles).
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "scripts/01_move.zig", "pub fn tick() void {}\n");
    try writeTestFile(tmp.dir, "scripts/playing/02_hud.zig", "pub fn tick() void {}\n");
    try writeTestFile(tmp.dir, "scripts/README.md", "# scripts\n");
    try writeTestFile(tmp.dir, "scripts/.gitkeep", "");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);

    try scanUnitLanguageDirs(allocator, root, "project root", null);
    const declared = DeclaredLanguage{ .language = "lua", .plugin_name = "labelle-scripting" };
    try scanUnitLanguageDirs(allocator, root, "project root", declared);
}

test "scanUnitLanguageDirs: components/ is policed like scripts/ — declared-language declarations pass, foreign extensions error (#237 refinement)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The canonical declare-mode shape: a ruby declaration beside the Zig
    // components — the declared language's own files pass.
    try writeTestFile(tmp.dir, "components/hunger.rb", "Hunger = Labelle.component \"Hunger\"\n");
    try writeTestFile(tmp.dir, "components/worker.zig", "pub const Worker = struct {};\n");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);

    const ruby_declared = DeclaredLanguage{ .language = "ruby", .plugin_name = "scripting" };
    try scanUnitLanguageDirs(allocator, root, "project root", ruby_declared);

    // A FOREIGN language's file in components/ errors exactly like in
    // scripts/ (nothing would ever read it — the silent-death class).
    const lua_declared = DeclaredLanguage{ .language = "lua", .plugin_name = "scripting" };
    try testing.expectError(
        error.ScriptLanguageMismatch,
        scanUnitLanguageDirs(allocator, root, "project root", lua_declared),
    );

    // No scripting plugin at all → the attach hint.
    try testing.expectError(
        error.MissingScriptingPlugin,
        scanUnitLanguageDirs(allocator, root, "project root", null),
    );
}

test "scanUnitLanguageDirs: a Zig-only components/ is invisible to the language scan (coexistence negative control)" {
    // Every existing game has components/*.zig and no scripting plugin —
    // the extension-keyed scan must never see them (the scripts/-side
    // control's components twin).
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "components/worker.zig", "pub const Worker = struct {};\n");
    try writeTestFile(tmp.dir, "components/needs/hunger.zig", "pub const Hunger = struct {};\n");
    try writeTestFile(tmp.dir, "components/.gitkeep", "");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);

    try scanUnitLanguageDirs(allocator, root, "project root", null);
    const declared = DeclaredLanguage{ .language = "lua", .plugin_name = "labelle-scripting" };
    try scanUnitLanguageDirs(allocator, root, "project root", declared);
}

test "scanUnitLanguageDirs: mixed scripts/ — declared-language + zig files coexist; ONE foreign file still errors" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "scripts/01_move.zig", "pub fn tick() void {}\n");
    try writeTestFile(tmp.dir, "scripts/behavior.lua", "return {}\n");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);

    const declared = DeclaredLanguage{ .language = "lua", .plugin_name = "labelle-scripting" };
    try scanUnitLanguageDirs(allocator, root, "project root", declared);

    // Drop one ruby file into the same dir → mismatch (extension-keyed).
    try writeTestFile(tmp.dir, "scripts/feed.rb", "class Feed; end\n");
    try testing.expectError(
        error.ScriptLanguageMismatch,
        scanUnitLanguageDirs(allocator, root, "project root", declared),
    );
}
