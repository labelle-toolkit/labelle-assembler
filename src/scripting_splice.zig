//! Scripting codegen splice (labelle-assembler#593, epic labelle-engine#237).
//!
//! The consuming half of the one-language-per-project policy (#584/#589,
//! `language_policy.zig` — parse + validate only): when THE scripting plugin
//! (resolved manifest name `"scripting"`, labelle-toolkit/labelle-scripting)
//! is attached with `.params = .{ .language = "…" }`, the generate pipeline
//!
//!   1. collects the game root's script-language sources from the `scripts/`
//!      convention dir — the SAME structure Zig scripts use
//!      (labelle-engine#237: extension-keyed coexistence, the two-layer
//!      architecture in one dir). Collection is TOP-LEVEL only with the Zig
//!      ordering convention (numeric prefixes first, stripped from the
//!      registered stem; state subdirs are Zig-only for now — a language
//!      file inside `scripts/<state>/` is a pointed generate error, see
//!      `resolveScriptDir`). The target's `scripts/` link (placed for the
//!      Zig scanner) doubles as the embed root. The DEPRECATED per-language
//!      dirs (`lua/`, `ts/`, … — `language_policy.legacyDir`) keep working
//!      for one release of grace: when `scripts/` holds no language files
//!      and the legacy dir does, the splice consumes the legacy dir
//!      verbatim (recursive `linkAndScan`, plain sorted stems — the
//!      pre-#237 behavior, byte-identical) with a pointed note; BOTH
//!      populated is a hard error (never merged). For typescript the
//!      transpile phase (labelle-engine#745, `scripting_transpile.zig`)
//!      then checks + emits `.ts` sources against the RESOLVED dir and the
//!      splice's entries are RE-collected from the materialized target dir
//!      (`collectEmbedScriptsAbs`, same ordering rules),
//!   2. registers each script with the plugin in the generated main BEFORE
//!      `PluginControllers.setup` boots the VM
//!      (`scripting.registerScript("<stem>", @embedFile("<dir>/<file>"))`
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
const cache = @import("cache.zig");
const config = @import("config.zig");
const language_policy = @import("language_policy.zig");
const plugin_manifest = @import("plugin_manifest.zig");
const scanner = @import("scanner.zig");
const script_scanner = @import("script_scanner.zig");
const scripting_declare = @import("scripting_declare.zig");

/// The resolved `plugin.labelle` name that identifies THE scripting plugin
/// (labelle-toolkit/labelle-scripting ships `.name = "scripting"`). Manifest
/// name == `.plugins` entry name is enforced at manifest load
/// (`PluginManifestNameMismatch`), so the entry is also spelled `scripting`
/// in project.labelle — which is the `@import` name the generated main and
/// the `labelle_scripting` dep/module names in the generated build use.
pub const SCRIPTING_MANIFEST_NAME = "scripting";

/// An AUTHORING extension in the script dir that the assembler turns into
/// the embed extension at generate time (labelle-engine#745): typescript's
/// `.ts` sources are type-checked + emitted to `.js` by the transpile
/// phase (`scripting_transpile.runPhase` — TS 7 native, fetched per
/// platform, no node/npm). Until #745 this row was a HARD-FAIL gate
/// (`rejectUntranspiledScripts`, the #586 placeholder); now its presence
/// marks the language transpilable and the phase consumes it.
pub const TranspileSource = struct {
    /// The authoring extension the transpile phase compiles (`.ts`).
    source_extension: []const u8,
    /// Suffix EXEMPT from "needs transpile" (`.d.ts`): declaration files
    /// carry no runtime code — they're the documented `// @ts-check`
    /// authoring companion (labelle-scripting README: "copy it or point
    /// at the resolved package's contract/ dir") and become typecheck
    /// INPUTS, so a copied `scripts/labelle.d.ts` never makes the phase
    /// run by itself and never fails generate. The same suffix is exempt
    /// from `resolveScriptDir`'s probes — a declaration file never marks
    /// a dir populated and never trips the state-subdir gate.
    declaration_suffix: []const u8,
};

/// One embeddable language: its `language_policy.SUPPORTED_LANGUAGES` name
/// (the convention DIR is `language_policy.SCRIPTS_DIR` for every language;
/// the legacy grace dir comes from `language_policy.legacyDir` — `ts/` for
/// typescript) and the source-file extension the collection + `@embedFile`
/// registration select the language's files by.
const EmbedLanguage = struct {
    language: []const u8,
    extension: []const u8,
    /// Non-null when the language ALSO has an authoring extension the
    /// transpile phase compiles into `extension` (typescript's `.ts`).
    transpile: ?TranspileSource = null,
};

/// Languages whose scripts are EMBEDDED as source and fed to the plugin's
/// VM via `registerScript` (the RFC's embedded-VM family). Widening is
/// additive — one row per language as its labelle-scripting sub-module
/// lands. Native-compiled languages (rust, crystal, go) integrate by
/// linking, not embedding — their rows live in `NATIVE_LANGUAGES`.
///
/// Every row's scripts live in the `scripts/` convention dir (the
/// extension selects the language — labelle-engine#237); the deprecated
/// per-language dirs ride the one-release grace fallback (`resolveScriptDir`).
///
/// typescript (labelle-scripting v0.3.0, quickjs-ng) EMBEDS `.js` only —
/// the runtime evaluates plain-JS ES modules. `.ts` sources reach that
/// form through the generate-time transpile phase (the `transpile` row,
/// labelle-engine#745): checked + emitted by the fetched TS 7 native
/// compiler, with type errors failing generate.
pub const EMBED_LANGUAGES = [_]EmbedLanguage{
    .{ .language = "lua", .extension = ".lua" },
    // ruby (labelle-scripting v0.3.0, mruby 3.4.0) embeds `.rb` sources —
    // no transpile row (ruby is what the VM runs); declare mode via
    // `tools/declare-ruby` (v0.9.0 — `scripting_declare.DECLARE_RUNNERS`).
    .{ .language = "ruby", .extension = ".rb" },
    .{ .language = "typescript", .extension = ".js", .transpile = .{
        .source_extension = ".ts",
        .declaration_suffix = ".d.ts",
    } },
};

/// One NATIVE-COMPILED language (labelle-engine#741, the RFC's second
/// family): the game's convention-dir sources compile via the plugin's
/// declared `.language_builds` steps (plugin_build_steps.zig) into a
/// staticlib linked into the game binary — no VM, no `registerScript`, no
/// `@embedFile`, no declare phase. The splice still emits the OTHER three
/// embed-row touchpoints (dep `-Dlanguage`, `scripting_enabled`
/// flag/alias, drainEvents tap + Controller.tick), and the generate
/// pipeline stages the game's sources over the plugin package's shipped
/// placeholder module (`stageNativeSources`).
const NativeLanguage = struct {
    /// `language_policy.SUPPORTED_LANGUAGES` name; the convention dir is
    /// `language_policy.SCRIPTS_DIR` (legacy grace dir: `legacyDir`) like
    /// every row.
    language: []const u8,
    /// Source extension collected by the staging validation (`.rs`).
    extension: []const u8,
    /// Package-relative dir the game's script-dir sources are staged
    /// OVER (replacing the plugin's shipped placeholder): the plugin
    /// crate's game-module dir (labelle-scripting `native/` crate —
    /// `lib.rs` declares `mod game;`, so the game's sources become
    /// `src/game/`).
    stage_subdir: []const u8,
    /// The file that must sit at the script dir's ROOT — `scripts/mod.rs`
    /// is rust's module root (was `rust/mod.rs`): the crate module root
    /// the plugin's crate resolves. Without it the staged crate cannot
    /// compile, so its absence is a generate-time error naming the
    /// convention, not a cargo error far from the author.
    module_root: []const u8,
};

/// The native-compiled rows. rust first (labelle-scripting PR #17, the
/// family's pattern-setter), crystal second (PR #19, scripting v0.7.0 —
/// same live-link staging over its own crate, `.link = .object` steps);
/// go lands as its plugin sub-module does.
pub const NATIVE_LANGUAGES = [_]NativeLanguage{
    .{
        .language = "rust",
        .extension = ".rs",
        .stage_subdir = "native/src/game",
        .module_root = "mod.rs",
    },
    .{
        .language = "crystal",
        .extension = ".cr",
        .stage_subdir = "native-crystal/src/game",
        // The crate's game-module root: native-crystal/src/main.cr
        // requires "./game/game" — scripts/game.cr is the mod.rs twin
        // (`Labelle::Game.register` composes the scripts).
        .module_root = "game.cr",
    },
};

fn embedRow(language: []const u8) ?EmbedLanguage {
    for (EMBED_LANGUAGES) |e| {
        if (std.mem.eql(u8, e.language, language)) return e;
    }
    return null;
}

fn nativeRow(language: []const u8) ?NativeLanguage {
    for (NATIVE_LANGUAGES) |n| {
        if (std.mem.eql(u8, n.language, language)) return n;
    }
    return null;
}

/// The source extension embedded for `language`, or null when the language
/// has no embeddable-source integration (native-compiled languages
/// included — they never embed).
pub fn embedExtension(language: []const u8) ?[]const u8 {
    const row = embedRow(language) orelse return null;
    return row.extension;
}

/// The source extension staged for a NATIVE-COMPILED `language`, or null
/// when the language has no native row.
pub fn nativeExtension(language: []const u8) ?[]const u8 {
    const row = nativeRow(language) orelse return null;
    return row.extension;
}

/// The transpile row for `language` (typescript's `.ts`/`.d.ts`), or null
/// when the language's authored sources ARE what embeds (lua, ruby) — the
/// transpile phase's gate (`scripting_transpile.runPhase` returns null).
pub fn transpileSource(language: []const u8) ?TranspileSource {
    const row = embedRow(language) orelse return null;
    return row.transpile;
}

/// Which integration family a detected splice belongs to — the axis every
/// emission/pipeline site that is NOT family-shared gates on. Shared for
/// both: the build dep's `.language` arg, the `scripting` alias +
/// `scripting_enabled` flag, the drainEvents tap and the Controller.tick
/// splice. Embed-only: the `<dir>/` copy+scan, `registerScript`/
/// `@embedFile`, the declare phase. Native-only: `stageNativeSources` +
/// the plugin's `.language_builds` steps (loaded independently by the
/// #586 wiring — the splice doesn't carry them).
pub const Family = enum { embed, native };

/// One collected embed script: what `registerScript` registers it AS and
/// which file `@embedFile` reads. Split because the `scripts/` convention
/// strips numeric ordering prefixes from the registered stem
/// (`10_spawner.rb` registers as "spawner") — the stem alone can no longer
/// reconstruct the embed path.
pub const EmbedScript = struct {
    /// Registered stem: ordering prefix + extension stripped, exactly as
    /// the Zig script scanner strips them (`script_scanner.stripPrefixAndExt`).
    /// Legacy-dir scripts keep the pre-#237 plain stem (no prefix
    /// stripping; subdirs joined with `/`) so unmigrated projects stay
    /// byte-identical through the grace release. Component-dir entries
    /// (`collectComponentEmbeds`) use the plain rel stem too — ordering
    /// prefixes are a scripts/-only convention.
    name: []const u8,
    /// TARGET-RELATIVE path — the whole `@embedFile("<file>")` argument
    /// (`scripts/10_spawner.rb`, `components/hunger.rb`, legacy
    /// `ts/ai/guard.js`). Target-relative because entries span TWO
    /// convention dirs now (labelle-engine#237's refinement: component
    /// declarations live in `components/`, scripts in the script dir) and
    /// because the declare runner's argv joins `<target>/<file>` directly.
    file: []const u8,
};

/// Everything the emission sites need, resolved once by `detect` and
/// threaded through `main_template.scripting_splice` (the same scoped
/// module-var pattern as `pack_scans`) + `BuildZigOptions.scripting`.
/// Borrows `plugin_name`/`language` from the parsed `ProjectConfig`;
/// `extension` is a static table slice; `scripts` is set by root.zig
/// after the collection (`collectEmbedScripts` — owned by root.zig).
/// Owns nothing.
pub const ScriptingSplice = struct {
    plugin_name: []const u8,
    language: []const u8,
    /// The dir the scripts live in and the `@embedFile` paths are rooted
    /// at, resolved once by `detect` so every emission site agrees:
    /// `language_policy.SCRIPTS_DIR` ("scripts" — the convention), or the
    /// language's DEPRECATED legacy dir (`lua/`, `ts/` —
    /// `language_policy.legacyDir`) when the one-release grace fallback
    /// engaged (`legacy` below).
    dir: []const u8,
    extension: []const u8,
    /// True when `detect`'s `resolveScriptDir` fell back to the deprecated
    /// per-language dir (scripts/ had no language files, the legacy dir
    /// did — note printed). Legacy keeps the pre-#237 semantics verbatim:
    /// recursive collection, plain sorted stems, no prefix stripping, and
    /// (native family) the pointed empty-dir error.
    legacy: bool = false,
    /// Embed vs native-compiled (see `Family`). `.embed` default keeps
    /// every pre-#741 fixture/caller byte-identical.
    family: Family = .embed,
    /// Always empty for `.native` splices — nothing embeds, so the
    /// registerScript builders (which iterate this) emit nothing.
    scripts: []const EmbedScript = &.{},
    /// Script-declared components (labelle-assembler#585): the parsed
    /// declare-mode schema, set by root.zig after
    /// `scripting_declare.runPhase` ran the plugin's runner over the
    /// collected script files (borrowed from the phase's `Schema` arena,
    /// alive through main.zig emission). Consumed by
    /// `registries.writeComponentRegistryBlock`, which registers each
    /// under its declared name against the generated
    /// `scripting_components.zig`. Empty (the default) for every
    /// declaration-less project — all emission sites stay byte-identical.
    declared_components: []const scripting_declare.DeclaredComponent = &.{},
    /// Script-declared events (labelle-engine#772): the schema's events,
    /// set by root.zig beside `declared_components` (same arena, same
    /// lifetime). Consumed by the game-events union writers
    /// (`blocks/events.zig` — one variant per declared event against the
    /// generated `scripting_events.zig`) and the `AllHookPayloads` gate
    /// (`blocks/hooks.zig`). Empty (the default) for every
    /// declaration-less project — all emission sites stay byte-identical.
    declared_events: []const scripting_declare.DeclaredEvent = &.{},
};

/// Detect the scripting splice for this project: the `.plugins` entry
/// declaring `.params.language` (the #589 parse — at most one exists, the
/// policy gate already ran) whose resolved manifest name is
/// `SCRIPTING_MANIFEST_NAME`. Returns null for every splice-less shape:
/// no `.params.language` declared, the declaring plugin ships no
/// `plugin.labelle`, its manifest name isn't `scripting`, or the language
/// has NEITHER an embed row nor a native row yet (warned — the attach is
/// policy-legal, the integration just hasn't landed).
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

        if (embedRow(declared.language)) |row| {
            // Probe by the runnable extension AND the transpile-gap
            // authoring extension (`.ts`), exempting declaration files
            // (`.d.ts`) — see `ProbeSpec`.
            var ext_buf: [2][]const u8 = .{ row.extension, undefined };
            var ext_len: usize = 1;
            var exempt: ?[]const u8 = null;
            if (row.transpile) |t| {
                ext_buf[1] = t.source_extension;
                ext_len = 2;
                exempt = t.declaration_suffix;
            }
            const resolved = try resolveScriptDir(allocator, game_dir, declared.language, .{
                .extensions = ext_buf[0..ext_len],
                .exempt_suffix = exempt,
            });
            return .{
                .plugin_name = plugin.name,
                .language = declared.language,
                .dir = resolved.dir,
                .legacy = resolved.legacy,
                .extension = row.extension,
                .family = .embed,
            };
        }
        if (nativeRow(declared.language)) |row| {
            const resolved = try resolveScriptDir(allocator, game_dir, declared.language, .{
                .extensions = &.{row.extension},
            });
            return .{
                .plugin_name = plugin.name,
                .language = declared.language,
                .dir = resolved.dir,
                .legacy = resolved.legacy,
                .extension = row.extension,
                .family = .native,
            };
        }
        std.log.warn(
            "labelle: script language \"{s}\" has no scripting integration yet " ++
                "(neither an embedded-VM nor a native-compiled row); " ++
                "the scripting plugin is wired but no {s}/ sources are consumed",
            .{ declared.language, language_policy.SCRIPTS_DIR },
        );
        return null;
    }
    // `declared.plugin_name` always names a member of `plugins` (it came
    // from the same slice), so this is unreachable in practice.
    return null;
}

// ── Script-dir resolution: scripts/ convention + legacy grace (#237) ──

/// The dir `detect` resolved the splice onto — `scripts/` (the convention)
/// or the language's deprecated legacy dir (one release of grace).
pub const ResolvedScriptDir = struct {
    dir: []const u8,
    legacy: bool,
};

const ProbeSpec = struct {
    /// Extensions that identify the language's files for the probes — the
    /// runnable extension plus any authoring extension the transpile phase
    /// compiles (`.ts`), so a `.ts`-only `scripts/` still selects
    /// `scripts/` (and then transpiles from there — labelle-engine#745 —
    /// instead of silently falling back to the legacy dir). This is what
    /// keeps the resolve probe and `scripting_transpile`'s need probe
    /// agreeing on WHICH dir a `.ts`-only project reads.
    extensions: []const []const u8,
    /// Suffix EXEMPT from every probe (`.d.ts`): declaration files carry no
    /// runtime code — a copied `scripts/labelle.d.ts` (even in a subdir)
    /// never counts as a script, never trips the state-subdir gate, and
    /// never marks `scripts/` populated.
    exempt_suffix: ?[]const u8 = null,

    fn matches(self: ProbeSpec, name: []const u8) bool {
        if (self.exempt_suffix) |suffix| {
            if (std.mem.endsWith(u8, name, suffix)) return false;
        }
        for (self.extensions) |ext| {
            if (std.mem.endsWith(u8, name, ext)) return true;
        }
        return false;
    }
};

/// Resolve which dir the splice reads the game's `language` scripts from
/// (labelle-engine#237's rollout contract):
///
///   - `scripts/` holds language files at its TOP LEVEL → `scripts/` (the
///     convention; state subdirs stay Zig-only, see below);
///   - `scripts/` has none but the legacy dir (`lua/`, `ts/` —
///     `language_policy.legacyDir`) has some → the legacy dir, with a
///     pointed deprecation note (one release of grace);
///   - BOTH populated → `error.LegacyScriptDirConflict` (never merged);
///   - NEITHER → `scripts/` (zero scripts — the plugin wires, nothing
///     embeds/stages).
///
/// Independent of which dir wins: a language file inside a `scripts/`
/// SUBDIR is `error.ScriptInStateSubdir` — state-scoped subdirs
/// (`scripts/<state>/`) are Zig-only until the scripting Controller grows
/// state awareness, and silently ignoring the file would be the exact
/// dead-script class this module polices. Dot-entries are skipped
/// everywhere (`.plugin_*`, `.gitkeep`).
pub fn resolveScriptDir(
    allocator: std.mem.Allocator,
    game_dir: []const u8,
    language: []const u8,
    spec: ProbeSpec,
) !ResolvedScriptDir {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    // Probe scripts/: top-level language files + subdir offenders.
    var top_count: usize = 0;
    var offenders: std.ArrayList([]const u8) = .empty;
    var offenders_total: usize = 0;
    defer {
        for (offenders.items) |p| allocator.free(p);
        offenders.deinit(allocator);
    }
    const scripts_path = try std.fs.path.join(allocator, &.{ game_dir, language_policy.SCRIPTS_DIR });
    defer allocator.free(scripts_path);
    if (cwd.openDir(io, scripts_path, .{ .iterate = true })) |scripts_dir_const| {
        var scripts_dir = scripts_dir_const;
        defer scripts_dir.close(io);
        var iter = scripts_dir.iterate();
        while (try iter.next(io)) |entry| {
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            switch (entry.kind) {
                .directory => {
                    var sub = scripts_dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                    defer sub.close(io);
                    const sub_prefix = try std.fs.path.join(allocator, &.{ language_policy.SCRIPTS_DIR, entry.name });
                    defer allocator.free(sub_prefix);
                    try collectMatchingFiles(allocator, io, sub, sub_prefix, spec, &offenders, &offenders_total);
                },
                else => {
                    if (spec.matches(entry.name)) top_count += 1;
                },
            }
        }
    } else |err| switch (err) {
        error.FileNotFound, error.NotDir => {},
        else => return err,
    }

    if (offenders_total > 0) {
        std.debug.print(
            "labelle-assembler: {s} scripts cannot live in {s}/ subdirectories yet — " ++
                "state-scoped subdirs ({s}/<state>/) are Zig-only until the scripting Controller grows state awareness:\n",
            .{ language, language_policy.SCRIPTS_DIR, language_policy.SCRIPTS_DIR },
        );
        for (offenders.items) |rel| std.debug.print("  {s}\n", .{rel});
        if (offenders_total > offenders.items.len) {
            std.debug.print("  ... and {d} more\n", .{offenders_total - offenders.items.len});
        }
        std.debug.print(
            "  move them to the top level of {s}/ (numeric prefixes order them: 01_foo, 02_bar).\n",
            .{language_policy.SCRIPTS_DIR},
        );
        return error.ScriptInStateSubdir;
    }

    // Probe the legacy dir (recursively — its old layout allowed subdirs).
    const legacy_dir = language_policy.legacyDir(language);
    var legacy_exists = false;
    var legacy_listed: std.ArrayList([]const u8) = .empty;
    var legacy_count: usize = 0;
    defer {
        for (legacy_listed.items) |p| allocator.free(p);
        legacy_listed.deinit(allocator);
    }
    const legacy_path = try std.fs.path.join(allocator, &.{ game_dir, legacy_dir });
    defer allocator.free(legacy_path);
    if (cwd.openDir(io, legacy_path, .{ .iterate = true })) |legacy_dir_const| {
        var ldir = legacy_dir_const;
        defer ldir.close(io);
        legacy_exists = true;
        try collectMatchingFiles(allocator, io, ldir, legacy_dir, spec, &legacy_listed, &legacy_count);
    } else |err| switch (err) {
        error.FileNotFound, error.NotDir => {},
        else => return err,
    }

    if (top_count > 0 and legacy_count > 0) {
        std.debug.print(
            "labelle-assembler: both {s}/ and the deprecated {s}/ dir contain {s} scripts — they are never merged:\n" ++
                "  {s}/: {d} file(s)\n  {s}/: {d} file(s)\n" ++
                "  move everything to {s}/ ({s}/ support ends next release).\n",
            .{
                language_policy.SCRIPTS_DIR, legacy_dir,                  language,
                language_policy.SCRIPTS_DIR, top_count,                   legacy_dir,
                legacy_count,                language_policy.SCRIPTS_DIR, legacy_dir,
            },
        );
        return error.LegacyScriptDirConflict;
    }

    if (top_count == 0 and legacy_count > 0) {
        std.log.warn(
            "labelle: {s}/ is deprecated — move scripts to {s}/ ({s}/ keeps working for one release of grace)",
            .{ legacy_dir, language_policy.SCRIPTS_DIR, legacy_dir },
        );
        return .{ .dir = legacy_dir, .legacy = true };
    }

    if (top_count == 0 and legacy_exists) {
        // The legacy dir EXISTS but holds no language sources, and
        // scripts/ has none either: keep the splice on the legacy dir
        // (silently — nothing is consumed, so no deprecation note) so its
        // pre-#237 semantics still apply — in particular the native
        // family's pointed "exists but empty" error
        // (`stageNativeSources`), which a dedicated per-language dir
        // earns and the shared scripts/ dir doesn't.
        return .{ .dir = legacy_dir, .legacy = true };
    }

    return .{ .dir = language_policy.SCRIPTS_DIR, .legacy = false };
}

/// Recursive spec-matching file collection (rel paths under `rel_prefix`,
/// capped at `language_policy.MAX_LISTED_FILES`; `total` keeps the true
/// count). Dot-entries skipped — the policy scan's rule.
fn collectMatchingFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    rel_prefix: []const u8,
    spec: ProbeSpec,
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
                try collectMatchingFiles(allocator, io, sub, sub_prefix, spec, listed, total);
            },
            else => {
                if (!spec.matches(entry.name)) continue;
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

// ── Embed-script collection (the scripts/ convention + legacy grace) ──

/// Collect the game's embed scripts for an `.embed` splice and place the
/// target link:
///
///   `scripts/` (the convention): TOP-LEVEL `<extension>` files only
///   (subdir offenders already errored in `detect`'s `resolveScriptDir`),
///   ordered by the ZIG scripts/ convention — numeric prefixes first
///   (ascending, `01_` before `02_`), unprefixed after, alphabetically by
///   stripped stem; the prefix is stripped from the registered `name`
///   exactly as the Zig scanner strips it (`stripPrefixAndExt`). Duplicate
///   numeric prefixes are `error.DuplicateSortOrder`, mirroring the Zig
///   scanner's validation (one scope: the language's top level). The
///   target's `scripts/` link is (re)placed idempotently — it's the same
///   link root.zig lays down for the Zig scanner; the two scanners share
///   the dir and each sees only its own extension.
///
///   Legacy dir (grace): the pre-#237 behavior VERBATIM —
///   `scanner.linkAndScan` (recursive, plain sorted stems, subdirs joined
///   with `/`, no prefix stripping), stems doubling as names with
///   `file = <dir>/<stem><ext>`. Unmigrated projects stay byte-identical.
///
/// SCRIPT-DIR entries only — `components/` language files are collected by
/// `collectComponentEmbeds` and concatenated FIRST by root.zig.
///
/// Returns owned entries (both strings allocated); free with
/// `freeEmbedScripts`. A missing dir collects empty (the plugin wires,
/// nothing embeds).
pub fn collectEmbedScripts(
    allocator: std.mem.Allocator,
    game_dir: []const u8,
    target_dir: []const u8,
    splice: ScriptingSplice,
) ![]EmbedScript {
    if (splice.legacy) {
        const stems = try scanner.linkAndScan(allocator, game_dir, target_dir, splice.dir, splice.extension);
        defer scanner.freeNames(allocator, stems);
        return embedScriptsFromStems(allocator, stems, splice.dir, splice.extension);
    }

    // The convention dir: link (idempotent — root.zig already linked it
    // for the Zig scanner; a correct link is a no-op reconcile) + collect
    // the top level.
    try scanner.linkDir(allocator, game_dir, target_dir, splice.dir);

    const dir_path = try std.fs.path.join(allocator, &.{ game_dir, splice.dir });
    defer allocator.free(dir_path);
    return collectOrderedTopLevelAbs(allocator, dir_path, splice);
}

/// Collect the game's `components/` LANGUAGE files for an `.embed` splice
/// (labelle-engine#237's refinement: declaration files live where their
/// KIND lives — `components/hunger.rb` next to `components/worker.zig`).
/// Extension-keyed coexistence exactly like the script dir: the Zig
/// component scan keeps `.zig`, this collects only `splice.extension`.
///
/// Entries register BEFORE the script-dir entries (root.zig concatenates
/// components-first) so the view constants a declaration defines exist by
/// the time scripts load. Order: plain alphabetical by rel path, names =
/// plain rel stems (subdirs joined with `/` — components/ subdirs are
/// organizational, mirroring the Zig component scan) — NO ordering-prefix
/// machinery; numeric prefixes are a scripts/-only convention.
///
/// For a transpile-row language (typescript), authoring-extension sources
/// in `components/` are a pointed error (`error.ComponentsDirNeedsTranspile`)
/// — the transpile phase materializes only the SCRIPT dir, so a
/// `components/foo.ts` would silently never run (`.d.ts` declaration
/// files exempt, as everywhere). Runnable `components/*.js` embeds fine.
///
/// The target's `components/` link is root.zig's existing
/// `linkAndScan(components, ".zig")` — the whole dir is exposed, so the
/// `@embedFile("components/<rel>")` paths resolve with no extra placement.
/// A missing dir collects empty. Free with `freeEmbedScripts`.
pub fn collectComponentEmbeds(
    allocator: std.mem.Allocator,
    game_dir: []const u8,
    splice: ScriptingSplice,
) ![]EmbedScript {
    return collectDeclEmbeds(allocator, game_dir, splice, .components);
}

/// Collect the game's `events/` LANGUAGE files for an `.embed` splice
/// (labelle-engine#772: event declarations live where their kind lives —
/// `events/hunger__feed.rb` next to `events/hunger__feed.zig`, the same
/// #237 refinement `components/` follows). Same mechanics as
/// `collectComponentEmbeds` in every respect — extension-keyed
/// coexistence with the Zig event scan, alphabetical order, plain rel
/// stems, the transpile pointed error (`error.EventsDirNeedsTranspile`),
/// missing dir collects empty.
///
/// Entries register BETWEEN the component declarations and the script
/// dir's entries (root.zig concatenates components → events → scripts) so
/// the event-name constants a declaration defines (`HungerFeed =
/// Labelle.event ...`) exist by the time scripts load. The target's
/// `events/` link is root.zig's existing `linkAndScan(events, ".zig")`,
/// so the `@embedFile("events/<rel>")` paths resolve with no extra
/// placement. Free with `freeEmbedScripts`.
pub fn collectEventEmbeds(
    allocator: std.mem.Allocator,
    game_dir: []const u8,
    splice: ScriptingSplice,
) ![]EmbedScript {
    return collectDeclEmbeds(allocator, game_dir, splice, .events);
}

/// The declaration convention dirs a language may drop files into —
/// `collectDeclEmbeds`' axis. Each carries its dir name and the
/// dir-specific transpile-gap error.
const DeclDir = enum {
    components,
    events,

    fn dirName(self: DeclDir) []const u8 {
        return switch (self) {
            .components => "components",
            .events => "events",
        };
    }

    fn transpileError(self: DeclDir) anyerror {
        return switch (self) {
            .components => error.ComponentsDirNeedsTranspile,
            .events => error.EventsDirNeedsTranspile,
        };
    }
};

/// The shared components/-and-events/ declaration-file collection (see
/// the two public wrappers for the per-dir contracts).
fn collectDeclEmbeds(
    allocator: std.mem.Allocator,
    game_dir: []const u8,
    splice: ScriptingSplice,
    decl_dir: DeclDir,
) ![]EmbedScript {
    const io = config.globalIo();
    const dir_path = try std.fs.path.join(allocator, &.{ game_dir, decl_dir.dirName() });
    defer allocator.free(dir_path);

    var out: std.ArrayList(EmbedScript) = .empty;
    errdefer freeEmbedScriptList(allocator, &out);

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return out.toOwnedSlice(allocator),
        else => return err,
    };
    defer dir.close(io);

    const transpile: ?TranspileSource = if (embedRow(splice.language)) |row| row.transpile else null;
    try collectDeclEmbedsWalk(allocator, io, dir, "", splice, transpile, decl_dir, &out);

    // Deterministic order: plain alphabetical by target-relative file.
    std.mem.sortUnstable(EmbedScript, out.items, {}, struct {
        fn lessThan(_: void, a: EmbedScript, b: EmbedScript) bool {
            return std.mem.order(u8, a.file, b.file) == .lt;
        }
    }.lessThan);

    return out.toOwnedSlice(allocator);
}

fn collectDeclEmbedsWalk(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    rel_prefix: []const u8,
    splice: ScriptingSplice,
    transpile: ?TranspileSource,
    decl_dir: DeclDir,
    out: *std.ArrayList(EmbedScript),
) !void {
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        switch (entry.kind) {
            .directory => {
                var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                defer sub.close(io);
                const sub_prefix = if (rel_prefix.len == 0)
                    try allocator.dupe(u8, entry.name)
                else
                    try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel_prefix, entry.name });
                defer allocator.free(sub_prefix);
                try collectDeclEmbedsWalk(allocator, io, sub, sub_prefix, splice, transpile, decl_dir, out);
            },
            else => {
                // Authoring sources the assembler can't run from here: the
                // transpile phase covers the SCRIPT dir only (the doc's
                // pointed-error rule — never silently dead).
                if (transpile) |t| {
                    if (std.mem.endsWith(u8, entry.name, t.source_extension) and
                        !std.mem.endsWith(u8, entry.name, t.declaration_suffix))
                    {
                        std.debug.print(
                            "labelle-assembler: {s}/{s}{s}{s} is a {s} authoring source, but the transpile step covers only the script dir.\n" ++
                                "  author runnable {s} in {s}/ (or keep {s} sources in {s}/).\n",
                            .{
                                decl_dir.dirName(),
                                rel_prefix,
                                if (rel_prefix.len == 0) "" else "/",
                                entry.name,
                                t.source_extension,
                                splice.extension,
                                decl_dir.dirName(),
                                t.source_extension,
                                splice.dir,
                            },
                        );
                        return decl_dir.transpileError();
                    }
                }
                if (!std.mem.endsWith(u8, entry.name, splice.extension)) continue;
                const rel_stem_len = entry.name.len - splice.extension.len;
                const name = if (rel_prefix.len == 0)
                    try allocator.dupe(u8, entry.name[0..rel_stem_len])
                else
                    try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel_prefix, entry.name[0..rel_stem_len] });
                errdefer allocator.free(name);
                const file = if (rel_prefix.len == 0)
                    try std.fmt.allocPrint(allocator, "{s}/{s}", .{ decl_dir.dirName(), entry.name })
                else
                    try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ decl_dir.dirName(), rel_prefix, entry.name });
                errdefer allocator.free(file);
                try out.append(allocator, .{ .name = name, .file = file });
            },
        }
    }
}

/// Three-way `concatEmbeds` — root.zig's registration order: component
/// declarations → EVENT declarations (labelle-engine#772: their name
/// constants must exist when scripts load, and component view constants
/// before those) → the script dir's entries. Same shallow contract as
/// `concatEmbeds`: free the result with `allocator.free`, inputs keep
/// ownership.
pub fn concatEmbeds3(
    allocator: std.mem.Allocator,
    first: []const EmbedScript,
    second: []const EmbedScript,
    third: []const EmbedScript,
) ![]EmbedScript {
    const out = try allocator.alloc(EmbedScript, first.len + second.len + third.len);
    @memcpy(out[0..first.len], first);
    @memcpy(out[first.len..][0..second.len], second);
    @memcpy(out[first.len + second.len ..], third);
    return out;
}

/// Concatenate two embed collections into ONE emission slice — root.zig's
/// components-first ordering (`concat(component_embeds, script_embeds)`).
/// SHALLOW: the result's entries borrow the inputs' strings; free the
/// returned slice with `allocator.free` (NOT `freeEmbedScripts`) and keep
/// freeing the inputs as before.
pub fn concatEmbeds(
    allocator: std.mem.Allocator,
    first: []const EmbedScript,
    second: []const EmbedScript,
) ![]EmbedScript {
    const out = try allocator.alloc(EmbedScript, first.len + second.len);
    @memcpy(out[0..first.len], first);
    @memcpy(out[first.len..], second);
    return out;
}

/// The same collection over a FULLY-RESOLVED directory, no link placement
/// — the transpile phase's post-emission re-scan (labelle-engine#745): the
/// target's script dir was MATERIALIZED (copied game tree + tsc-emitted
/// `.js`), so the embeddable set must be re-collected from THAT dir, under
/// the SAME rules the game-dir collection uses — ordering prefixes strip
/// and order (a `10_a.ts` emits `10_a.js` and registers as "a", before
/// `20_b`'s), duplicate orders error, and the generated
/// `labelle-components.d.ts` is never collected (it doesn't carry the
/// embed extension). Legacy splices keep the pre-#237 recursive
/// plain-stem semantics (`scanner.scanDirAbs`), so a grace-window `ts/`
/// project transpiles AND registers exactly as it embedded before.
pub fn collectEmbedScriptsAbs(
    allocator: std.mem.Allocator,
    abs_dir: []const u8,
    splice: ScriptingSplice,
) ![]EmbedScript {
    if (splice.legacy) {
        const stems = try scanner.scanDirAbs(allocator, abs_dir, splice.extension);
        defer scanner.freeNames(allocator, stems);
        return embedScriptsFromStems(allocator, stems, splice.dir, splice.extension);
    }
    return collectOrderedTopLevelAbs(allocator, abs_dir, splice);
}

/// Legacy stems → entries: names stay the plain stems (subdirs joined
/// with `/`, numeric prefixes KEPT — byte-identical registration through
/// the grace release), files re-derive as `<dir>/<stem><ext>`
/// (target-relative, like every entry).
fn embedScriptsFromStems(
    allocator: std.mem.Allocator,
    stems: []const []const u8,
    dir: []const u8,
    extension: []const u8,
) ![]EmbedScript {
    var out: std.ArrayList(EmbedScript) = .empty;
    errdefer freeEmbedScriptList(allocator, &out);
    try out.ensureTotalCapacity(allocator, stems.len);
    for (stems) |stem| {
        const name = try allocator.dupe(u8, stem);
        errdefer allocator.free(name);
        const file = try std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ dir, stem, extension });
        errdefer allocator.free(file);
        out.appendAssumeCapacity(.{ .name = name, .file = file });
    }
    return out.toOwnedSlice(allocator);
}

/// The scripts/-convention collection core over one absolute dir: TOP
/// LEVEL only, Zig ordering, prefix-stripped names, duplicate-order
/// validation. Shared by the game-dir collection and the transpile
/// phase's materialized-dir re-scan.
fn collectOrderedTopLevelAbs(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    splice: ScriptingSplice,
) ![]EmbedScript {
    const io = config.globalIo();

    const Collected = struct {
        script: EmbedScript,
        sort_order: ?u32,
    };
    var entries: std.ArrayList(Collected) = .empty;
    defer entries.deinit(allocator);
    errdefer for (entries.items) |e| {
        allocator.free(e.script.name);
        allocator.free(e.script.file);
    };

    if (std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close(io);
        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            // Skip only directories (matching `resolveScriptDir`'s probe,
            // so "populated" and "collected" can never disagree — e.g. on
            // a symlinked script file).
            if (entry.kind == .directory) continue;
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            if (!std.mem.endsWith(u8, entry.name, splice.extension)) continue;
            const name = try allocator.dupe(u8, script_scanner.stripPrefixAndExt(entry.name, splice.extension));
            errdefer allocator.free(name);
            const file = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ splice.dir, entry.name });
            errdefer allocator.free(file);
            try entries.append(allocator, .{
                .script = .{ .name = name, .file = file },
                .sort_order = script_scanner.extractSortOrder(entry.name),
            });
        }
    } else |err| switch (err) {
        error.FileNotFound, error.NotDir => {},
        else => return err,
    }

    // The Zig scripts/ ordering: numbered before unnumbered, numbered
    // ascending, then alphabetical by stripped name (filename tiebreak for
    // full determinism).
    std.mem.sortUnstable(Collected, entries.items, {}, struct {
        fn lessThan(_: void, a: Collected, b: Collected) bool {
            const a_has = a.sort_order != null;
            const b_has = b.sort_order != null;
            if (a_has != b_has) return a_has;
            if (a.sort_order) |a_order| {
                if (b.sort_order) |b_order| {
                    if (a_order != b_order) return a_order < b_order;
                }
            }
            const by_name = std.mem.order(u8, a.script.name, b.script.name);
            if (by_name != .eq) return by_name == .lt;
            return std.mem.order(u8, a.script.file, b.script.file) == .lt;
        }
    }.lessThan);

    // Duplicate-prefix validation — the Zig scanner's rule, one scope
    // (the language's top level). Sorted, so duplicates are adjacent.
    var i: usize = 1;
    while (i < entries.items.len) : (i += 1) {
        const a = entries.items[i - 1];
        const b = entries.items[i];
        const a_order = a.sort_order orelse continue;
        const b_order = b.sort_order orelse continue;
        if (a_order != b_order) continue;
        std.debug.print(
            "error: duplicate {s} script order {d:0>2} in {s}/:\n  - {s}\n  - {s}\n",
            .{ splice.language, a_order, splice.dir, a.script.file, b.script.file },
        );
        return error.DuplicateSortOrder;
    }

    var out = try allocator.alloc(EmbedScript, entries.items.len);
    for (entries.items, 0..) |e, idx| out[idx] = e.script;
    entries.clearRetainingCapacity(); // ownership moved to `out`
    return out;
}

fn freeEmbedScriptList(allocator: std.mem.Allocator, list: *std.ArrayList(EmbedScript)) void {
    for (list.items) |s| {
        allocator.free(s.name);
        allocator.free(s.file);
    }
    list.deinit(allocator);
}

/// Free a `collectEmbedScripts` result (entries own both strings).
pub fn freeEmbedScripts(allocator: std.mem.Allocator, scripts: []EmbedScript) void {
    for (scripts) |s| {
        allocator.free(s.name);
        allocator.free(s.file);
    }
    allocator.free(scripts);
}

// ── Native-language game-source staging (labelle-engine#741) ──────────

/// Stage the game's native-language sources over the scripting plugin's
/// STAGED package: LINK `<game>/<dir>` at `<output>/deps/labelle-
/// <plugin>/<stage_subdir>` (replacing the plugin's shipped placeholder
/// module) so the plugin's declared `.language_builds` step (cargo)
/// compiles the GAME's scripts into the linked staticlib. Runs AFTER
/// `deps_linker.createDepsLinks` (build.zig.zon generation), the same
/// ordering dependency the declare phase has.
///
/// The placement is `scanner.linkDirAbs` — the SAME primitive
/// `linkAndScan` uses for embed-language script dirs — so the staged
/// view is LIVE: editing `scripts/*.rs` and rerunning the generated `zig
/// build` compiles the current sources without a re-generate, exactly
/// like editing `scripts/*.lua` does. (A copy went stale the moment the
/// author's edit loop started — the silent-staleness class `labelle
/// run`'s stale-binary rule exists for.) The primitive also owns the
/// Windows posture: symlink first, copy fallback when symlinks are
/// denied — on that fallback the staged sources are as stale-until-
/// regenerate as every OTHER linked game dir on the same machine, no
/// new behavior. Its reconcile step (real dir → deleteTree + relink)
/// is what removes the shipped placeholder: hardlinked placeholder
/// FILES are unlinked, never written through, so the shared-cache
/// bytes are untouched.
///
/// Hard rules:
///   - Deps staging MUST have produced the staged copy. When
///     `createDepsLinks` fell back ("falling back to cache-relative dep
///     paths"), `{package}` resolves to the SHARED plugin cache
///     (`~/.labelle`) — placing a link to game sources there would leak
///     one project's tree into every other consumer of the plugin, so
///     this fails generate instead (`error.NativeScriptsDepsUnstaged`),
///     BEFORE any placement. Same staged-first probe as
///     `scripting_declare.resolvePluginPackageDir`, minus the cache
///     fallback that function is allowed (it only READS).
///   - A missing `<dir>/` is a no-op (scripting plugin attached, zero
///     scripts — exactly how the embed rows treat a missing script dir):
///     the shipped placeholder stays and registers nothing.
///   - `scripts/` with no `<ext>` sources is ALSO a no-op: the shared
///     convention dir legitimately holds a Zig-only game's scripts, so
///     "exists but no native sources" is indistinguishable from "zero
///     native scripts yet" — the placeholder stays. Only the LEGACY dir
///     (`splice.legacy` — `rust/` exists but holds no `.rs`) keeps the
///     pointed `error.NativeScriptDirEmpty`: a dedicated per-language dir
///     with nothing in it can only be a half-finished setup, and cargo
///     would otherwise fail far from the author.
///   - `<dir>/<module_root>` (rust: `scripts/mod.rs`) is REQUIRED once any
///     source exists: it becomes the crate's game-module root
///     (`error.NativeScriptsMissingModuleRoot` names the convention).
///
/// Validation walks the SOURCE dir (`<ext>` files, dot-entries skipped;
/// the walk is recursive so LEGACY-dir module subtrees keep working —
/// `scripts/` subdir sources were already gated by `resolveScriptDir`'s
/// state-subdir error at detect); the link then exposes the whole dir
/// as-is — a stray non-`<ext>` file (notes.toml), and for `scripts/` the
/// game's `.zig` scripts, IS visible to cargo through the link, unlike
/// the earlier copy design. Benign by construction: rustc compiles only
/// the modules `mod.rs` reachably declares, and the crate's Cargo.toml
/// lives in the plugin's `native/`, not the game dir. Idempotent: the
/// primitive's correct-link no-op also serves the tests-target pass,
/// whose deps tree is NOT re-staged (`recreate_deps = false`).
pub fn stageNativeSources(
    allocator: std.mem.Allocator,
    game_dir: []const u8,
    output_dir: []const u8,
    splice: ScriptingSplice,
) !void {
    if (splice.family != .native) return; // embed splices never stage
    const row = nativeRow(splice.language) orelse return;

    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    // Collect the game's sources FIRST: a project with no <dir>/ stages
    // nothing (the placeholder stays), so the deps probe below only gates
    // projects that actually place a link.
    const src_dir_path = try std.fs.path.join(allocator, &.{ game_dir, splice.dir });
    defer allocator.free(src_dir_path);
    var src_dir = cwd.openDir(io, src_dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer src_dir.close(io);

    var rel_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (rel_paths.items) |p| allocator.free(p);
        rel_paths.deinit(allocator);
    }
    try collectNativeSources(allocator, io, src_dir, "", splice.extension, &rel_paths);

    if (rel_paths.items.len == 0) {
        // The shared scripts/ dir with zero native sources is a normal
        // Zig-only shape — no-op, the placeholder stays (module doc). The
        // pointed error is legacy-dir-only: a dedicated rust/ with no .rs
        // can only be a half-finished setup.
        if (!splice.legacy) return;
        std.debug.print(
            "labelle-assembler: {s}/ exists but contains no {s} sources.\n" ++
                "  the scripting plugin (language \"{s}\") compiles {s}/ into the game — " ++
                "add {s}/{s} (the crate's game-module root) or remove the empty directory.\n",
            .{ splice.dir, splice.extension, splice.language, splice.dir, splice.dir, row.module_root },
        );
        return error.NativeScriptDirEmpty;
    }

    var has_module_root = false;
    for (rel_paths.items) |rel| {
        if (std.mem.eql(u8, rel, row.module_root)) has_module_root = true;
    }
    if (!has_module_root) {
        std.debug.print(
            "labelle-assembler: {s}/ has {s} sources but no {s}/{s} — the file that becomes " ++
                "the plugin crate's game-module root ({s}/{s}).\n" ++
                "  declare your scripts there; its `pub fn register(...)` composes them.\n",
            .{ splice.dir, splice.extension, splice.dir, row.module_root, row.stage_subdir, row.module_root },
        );
        return error.NativeScriptsMissingModuleRoot;
    }

    // The staged package — never the shared cache (module doc).
    var link_buf: [256]u8 = undefined;
    const link_name = std.fmt.bufPrint(&link_buf, "labelle-{s}", .{splice.plugin_name}) catch
        return error.NameTooLong;
    const staged_pkg = try std.fs.path.join(allocator, &.{ output_dir, "deps", link_name });
    defer allocator.free(staged_pkg);
    if (!cache.dirExists(staged_pkg)) {
        std.debug.print(
            "labelle-assembler: cannot stage {s}/ sources: the scripting plugin has no staged deps copy at {s}\n" ++
                "  (deps staging fell back to cache-relative paths — see the \"createDepsLinks failed\" warning above).\n" ++
                "  game sources are never placed into the shared plugin cache; fix the deps staging failure and regenerate.\n",
            .{ splice.dir, staged_pkg },
        );
        return error.NativeScriptsDepsUnstaged;
    }

    // The pinned plugin must actually ship the crate the sources stage
    // into (`native/src/` for rust) — a pre-native plugin version cannot
    // consume them, so fail here with the fix rather than letting cargo
    // fail against a half-staged package.
    const stage_parent = std.fs.path.dirname(row.stage_subdir).?;
    const parent_path = try std.fs.path.join(allocator, &.{ staged_pkg, stage_parent });
    defer allocator.free(parent_path);
    if (!cache.dirExists(parent_path)) {
        std.debug.print(
            "labelle-assembler: the pinned scripting plugin ships no {s}/ crate — it predates " ++
                "{s} (native-compiled) support.\n" ++
                "  pin a labelle-scripting version whose package ships {s}/ (the release that added {s}).\n",
            .{ stage_parent, splice.language, row.stage_subdir, splice.language },
        );
        return error.NativeCrateLayoutMissing;
    }

    // Place the LIVE link (module doc): linkDirAbs reconciles whatever is
    // at the destination — the shipped placeholder dir (hardlinked files
    // unlinked, cache bytes untouched), a stale link, or the correct link
    // (no-op) — then links the game dir so edits flow through without a
    // re-generate, matching the embed script dirs' linkAndScan layout.
    const dest_root = try std.fs.path.join(allocator, &.{ staged_pkg, row.stage_subdir });
    defer allocator.free(dest_root);
    try scanner.linkDirAbs(allocator, src_dir_path, dest_root);
}

/// Recursive `<ext>`-filtered collection of `dir`'s files as rel paths
/// (subdirs joined with the platform separator) — VALIDATION input only
/// (`NativeScriptDirEmpty` / module-root); placement links the whole dir.
/// Dot-entries skipped — `.gitkeep`/`.DS_Store` are not sources, so a dir
/// holding only those is "empty" for the `NativeScriptDirEmpty` rule
/// (matching the language-policy scan's dot rule).
fn collectNativeSources(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    rel_prefix: []const u8,
    extension: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        switch (entry.kind) {
            .directory => {
                var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                defer sub.close(io);
                const sub_prefix = if (rel_prefix.len == 0)
                    try allocator.dupe(u8, entry.name)
                else
                    try std.fs.path.join(allocator, &.{ rel_prefix, entry.name });
                defer allocator.free(sub_prefix);
                try collectNativeSources(allocator, io, sub, sub_prefix, extension, out);
            },
            else => {
                if (!std.mem.endsWith(u8, entry.name, extension)) continue;
                const rel = if (rel_prefix.len == 0)
                    try allocator.dupe(u8, entry.name)
                else
                    try std.fs.path.join(allocator, &.{ rel_prefix, entry.name });
                errdefer allocator.free(rel);
                try out.append(allocator, rel);
            },
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "embedExtension: lua maps to .lua, ruby to .rb, typescript embeds .js; native-compiled languages are absent" {
    try testing.expectEqualStrings(".lua", embedExtension("lua").?);
    try testing.expectEqualStrings(".rb", embedExtension("ruby").?);
    // typescript embeds PLAIN JS (quickjs-ng runs ES modules; `.ts`
    // reaches that form through the #745 transpile phase) — never `.ts`.
    try testing.expectEqualStrings(".js", embedExtension("typescript").?);
    try testing.expect(embedExtension("rust") == null);
    try testing.expect(embedExtension("cobol") == null);
}

test "transpileSource: only typescript carries a transpile row — .ts sources, .d.ts declarations exempt" {
    try testing.expect(transpileSource("lua") == null);
    try testing.expect(transpileSource("ruby") == null);
    // Native and unknown languages have no EMBED row at all.
    try testing.expect(transpileSource("rust") == null);
    try testing.expect(transpileSource("cobol") == null);
    const src = transpileSource("typescript").?;
    try testing.expectEqualStrings(".ts", src.source_extension);
    try testing.expectEqualStrings(".d.ts", src.declaration_suffix);
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
        .{ .name = "scripting", .repo = "local:plugins/scripting", .params = .{ .language = "lua" } },
    };
    const splice = (try detect(allocator, &plugins, project_dir)).?;
    try testing.expectEqualStrings("scripting", splice.plugin_name);
    try testing.expectEqualStrings("lua", splice.language);
    // The scripts/ convention (labelle-engine#237): no lua/ files exist,
    // so the resolve lands on the default — scripts/, non-legacy.
    try testing.expectEqualStrings("scripts", splice.dir);
    try testing.expect(!splice.legacy);
    try testing.expectEqualStrings(".lua", splice.extension);
    try testing.expectEqual(@as(usize, 0), splice.scripts.len);
}

test "detect: a typescript declaration splices with the scripts/ convention dir and the .js embed extension" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "plugins/scripting/plugin.labelle",
        \\.{ .name = "scripting", .manifest_version = 1 }
    );
    const project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(project_dir);

    const plugins = [_]config.PluginDep{
        .{ .name = "scripting", .repo = "local:plugins/scripting", .params = .{ .language = "typescript" } },
    };
    const splice = (try detect(allocator, &plugins, project_dir)).?;
    try testing.expectEqualStrings("scripting", splice.plugin_name);
    try testing.expectEqualStrings("typescript", splice.language);
    // Same scripts/ home as every language (ts/ is only the legacy grace
    // dir now); the embed extension stays the runnable .js.
    try testing.expectEqualStrings("scripts", splice.dir);
    try testing.expect(!splice.legacy);
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
        .{ .name = "labelle-scripting", .repo = "local:plugins/scripting", .params = .{ .language = "lua" } },
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
        .{ .name = "acme", .repo = "local:plugins/acme", .params = .{ .language = "lua" } },
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

test "detect: a rust declaration splices as the NATIVE family — scripts/ dir, .rs extension, no embed" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "plugins/scripting/plugin.labelle",
        \\.{ .name = "scripting", .manifest_version = 1 }
    );
    const project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(project_dir);

    const plugins = [_]config.PluginDep{
        .{ .name = "scripting", .repo = "local:plugins/scripting", .params = .{ .language = "rust" } },
    };
    const splice = (try detect(allocator, &plugins, project_dir)).?;
    try testing.expectEqualStrings("scripting", splice.plugin_name);
    try testing.expectEqualStrings("rust", splice.language);
    try testing.expectEqualStrings("scripts", splice.dir);
    try testing.expect(!splice.legacy);
    try testing.expectEqualStrings(".rs", splice.extension);
    try testing.expectEqual(Family.native, splice.family);
    // Nothing embeds for a native splice — the registerScript builders
    // iterate `scripts`, which stays empty for the family.
    try testing.expectEqual(@as(usize, 0), splice.scripts.len);
}

test "NATIVE_LANGUAGES: rust + crystal row shapes — extension, crate stage dir, module root; nativeExtension table" {
    const rust = nativeRow("rust").?;
    try testing.expectEqualStrings(".rs", rust.extension);
    try testing.expectEqualStrings("native/src/game", rust.stage_subdir);
    try testing.expectEqualStrings("mod.rs", rust.module_root);

    // Crystal (labelle-scripting PR #19 / v0.7.0): its OWN crate
    // (`native-crystal/`) beside rust's, game.cr as the module root the
    // crate's main.cr requires.
    const crystal = nativeRow("crystal").?;
    try testing.expectEqualStrings(".cr", crystal.extension);
    try testing.expectEqualStrings("native-crystal/src/game", crystal.stage_subdir);
    try testing.expectEqualStrings("game.cr", crystal.module_root);

    try testing.expectEqualStrings(".rs", nativeExtension("rust").?);
    try testing.expectEqualStrings(".cr", nativeExtension("crystal").?);
    // Embed languages never appear in the native table (and vice versa —
    // the families are disjoint; detect() checks embed first).
    try testing.expect(nativeExtension("lua") == null);
    try testing.expect(nativeExtension("ruby") == null);
    try testing.expect(nativeExtension("typescript") == null);
    try testing.expect(nativeExtension("go") == null);
}

test "detect: a crystal declaration splices as the NATIVE family — scripts/ dir, .cr extension" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "plugins/scripting/plugin.labelle",
        \\.{ .name = "scripting", .manifest_version = 1 }
    );
    const project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(project_dir);

    const plugins = [_]config.PluginDep{
        .{ .name = "scripting", .repo = "local:plugins/scripting", .params = .{ .language = "crystal" } },
    };
    const splice = (try detect(allocator, &plugins, project_dir)).?;
    try testing.expectEqualStrings("crystal", splice.language);
    try testing.expectEqualStrings("scripts", splice.dir);
    try testing.expect(!splice.legacy);
    try testing.expectEqualStrings(".cr", splice.extension);
    try testing.expectEqual(Family.native, splice.family);
    try testing.expectEqual(@as(usize, 0), splice.scripts.len);
}

// ── resolveScriptDir: the scripts/ convention + legacy grace (#237) ───

test "detect: legacy grace — lua/ scripts with an empty scripts/ resolve onto the deprecated dir (note printed)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "plugins/scripting/plugin.labelle",
        \\.{ .name = "scripting", .manifest_version = 1 }
    );
    // The unmigrated project shape: lua/ populated (nested subdirs were
    // legal there), scripts/ holding only Zig scripts.
    try writeTestFile(tmp.dir, "lua/behavior.lua", "return {}\n");
    try writeTestFile(tmp.dir, "lua/ai/guard.lua", "return {}\n");
    try writeTestFile(tmp.dir, "scripts/01_move.zig", "pub fn tick() void {}\n");
    const project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(project_dir);

    const plugins = [_]config.PluginDep{
        .{ .name = "scripting", .repo = "local:plugins/scripting", .params = .{ .language = "lua" } },
    };
    const splice = (try detect(allocator, &plugins, project_dir)).?;
    try testing.expectEqualStrings("lua", splice.dir);
    try testing.expect(splice.legacy);
    // (The deprecation note is a std.log.warn — tolerated by the test
    // runner; the RESULT is the pin, the note's wording is the fallback
    // branch's only exit.)
}

test "detect: BOTH scripts/ and the legacy dir populated → pointed conflict error (never merged)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "plugins/scripting/plugin.labelle",
        \\.{ .name = "scripting", .manifest_version = 1 }
    );
    try writeTestFile(tmp.dir, "scripts/spawner.lua", "return {}\n");
    try writeTestFile(tmp.dir, "lua/behavior.lua", "return {}\n");
    const project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(project_dir);

    const plugins = [_]config.PluginDep{
        .{ .name = "scripting", .repo = "local:plugins/scripting", .params = .{ .language = "lua" } },
    };
    try testing.expectError(error.LegacyScriptDirConflict, detect(allocator, &plugins, project_dir));
}

test "detect: a language file in a scripts/ subdir is the pointed state-subdir error — even when the legacy dir would win" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "plugins/scripting/plugin.labelle",
        \\.{ .name = "scripting", .manifest_version = 1 }
    );
    // State subdirs are Zig-only until the scripting Controller grows
    // state awareness — a language file there must FAIL generate, never
    // be silently ignored (and never silently excluded by a legacy
    // fallback that would leave it dead).
    try writeTestFile(tmp.dir, "scripts/playing/10_spawner.lua", "return {}\n");
    const project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(project_dir);

    const plugins = [_]config.PluginDep{
        .{ .name = "scripting", .repo = "local:plugins/scripting", .params = .{ .language = "lua" } },
    };
    try testing.expectError(error.ScriptInStateSubdir, detect(allocator, &plugins, project_dir));

    // The legacy-populated variant: scripts/ top level empty, lua/ has
    // scripts — the subdir offender STILL errors (it precedes the
    // fallback decision by design).
    try writeTestFile(tmp.dir, "lua/behavior.lua", "return {}\n");
    try testing.expectError(error.ScriptInStateSubdir, detect(allocator, &plugins, project_dir));
}

test "resolveScriptDir: negative controls — zig/organizational subdirs don't trip the gate; .d.ts is exempt everywhere" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Zig state subdirs + non-language files in subdirs are the Zig
    // scanner's business — the language probe must not see them.
    try writeTestFile(tmp.dir, "scripts/behavior.lua", "return {}\n");
    try writeTestFile(tmp.dir, "scripts/playing/02_hud.zig", "pub fn tick() void {}\n");
    try writeTestFile(tmp.dir, "scripts/playing/README.md", "# notes\n");
    try writeTestFile(tmp.dir, "scripts/.plugin_fake/evil.lua", "-- dot-dirs are skipped\n");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);

    const lua = try resolveScriptDir(allocator, root, "lua", .{ .extensions = &.{".lua"} });
    try testing.expectEqualStrings("scripts", lua.dir);
    try testing.expect(!lua.legacy);

    // typescript: a declaration file is NOT a script — subdir-placed
    // labelle.d.ts neither trips the state-subdir gate nor marks
    // scripts/ populated (a .js-in-ts/ project with a copied d.ts in
    // scripts/ still legacy-falls-back).
    var tmp2 = testing.tmpDir(.{});
    defer tmp2.cleanup();
    try writeTestFile(tmp2.dir, "scripts/types/labelle.d.ts", "declare const labelle: any;\n");
    try writeTestFile(tmp2.dir, "ts/behavior.js", "export function update(dt) {}\n");
    const root2 = try tmp2.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root2);
    const ts = try resolveScriptDir(allocator, root2, "typescript", .{
        .extensions = &.{ ".js", ".ts" },
        .exempt_suffix = ".d.ts",
    });
    try testing.expectEqualStrings("ts", ts.dir);
    try testing.expect(ts.legacy);

    // …while a runnable .ts in scripts/ top level DOES mark it populated
    // (the transpile gate owns the pointed error downstream) — so the
    // same project WITHOUT the legacy dir resolves onto scripts/.
    var tmp3 = testing.tmpDir(.{});
    defer tmp3.cleanup();
    try writeTestFile(tmp3.dir, "scripts/enemy.ts", "export function update(dt: number) {}\n");
    const root3 = try tmp3.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root3);
    const ts3 = try resolveScriptDir(allocator, root3, "typescript", .{
        .extensions = &.{ ".js", ".ts" },
        .exempt_suffix = ".d.ts",
    });
    try testing.expectEqualStrings("scripts", ts3.dir);
    try testing.expect(!ts3.legacy);
}

test "detect: an integration gap (declared language in NEITHER table) → null with a warning" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "plugins/scripting/plugin.labelle",
        \\.{ .name = "scripting", .manifest_version = 1 }
    );
    const project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(project_dir);

    // `go` is policy-supported (SUPPORTED_LANGUAGES) but has neither an
    // embed row nor a native row yet — so the splice is skipped. The
    // skip logs via `std.log.warn`, which the Zig test runner tolerates
    // (only a logged `err` fails a test — see the same gate noted in
    // render.zig).
    const plugins = [_]config.PluginDep{
        .{ .name = "scripting", .repo = "local:plugins/scripting", .params = .{ .language = "go" } },
    };
    try testing.expect((try detect(allocator, &plugins, project_dir)) == null);
}

// ── the typescript fixtures (transpile phase re-scan seam, #745) ─────

const ts_splice_fixture = ScriptingSplice{
    .plugin_name = "scripting",
    .language = "typescript",
    .dir = "scripts",
    .extension = ".js",
};

/// The grace-fallback twin: detect resolved the deprecated ts/ dir.
const ts_legacy_splice_fixture = ScriptingSplice{
    .plugin_name = "scripting",
    .language = "typescript",
    .dir = "ts",
    .legacy = true,
    .extension = ".js",
};

test "collectEmbedScriptsAbs: the transpile re-scan — ordering + stripping over a materialized dir; the generated d.ts is never a script" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The exact materialized-dir shape the transpile phase leaves behind
    // for a scripts/-convention project (labelle-engine#745 over #237):
    // tsc-emitted `.js` twins of `10_a.ts`/`20_b.ts` (prefixes intact in
    // the FILENAME), a copied plain `.js`, the copied game tree's `.zig`
    // scripts + state subdir, and the generated components declaration.
    try writeTestFile(tmp.dir, "materialized/10_a.js", "export function update(dt) {}\n");
    try writeTestFile(tmp.dir, "materialized/20_b.js", "export function update(dt) {}\n");
    try writeTestFile(tmp.dir, "materialized/plain.js", "export function update(dt) {}\n");
    try writeTestFile(tmp.dir, "materialized/01_move.zig", "pub fn tick() void {}\n");
    try writeTestFile(tmp.dir, "materialized/playing/02_hud.zig", "pub fn tick() void {}\n");
    try writeTestFile(tmp.dir, "materialized/labelle-components.d.ts", "declare global {}\n");
    try writeTestFile(tmp.dir, "materialized/labelle.d.ts", "declare const labelle: any;\n");
    const abs = try tmp.dir.realPathFileAlloc(testing.io, "materialized", allocator);
    defer allocator.free(abs);

    const scripts = try collectEmbedScriptsAbs(allocator, abs, ts_splice_fixture);
    defer freeEmbedScripts(allocator, scripts);

    // Prefix order first (10 before 20), unprefixed after; stems stripped
    // exactly like the game-dir collection; .zig/.d.ts invisible.
    try testing.expectEqual(@as(usize, 3), scripts.len);
    try testing.expectEqualStrings("a", scripts[0].name);
    try testing.expectEqualStrings("scripts/10_a.js", scripts[0].file);
    try testing.expectEqualStrings("b", scripts[1].name);
    try testing.expectEqualStrings("scripts/20_b.js", scripts[1].file);
    try testing.expectEqualStrings("plain", scripts[2].name);

    // Duplicate orders error here exactly like the game-dir collection —
    // including the cross-source shape only the re-scan can see (an
    // emitted 10_a.js colliding with a hand-authored 10_z.js).
    try writeTestFile(tmp.dir, "materialized/10_z.js", "export function update(dt) {}\n");
    try testing.expectError(error.DuplicateSortOrder, collectEmbedScriptsAbs(allocator, abs, ts_splice_fixture));
}

test "collectEmbedScriptsAbs: LEGACY re-scan keeps pre-#237 semantics — recursive, plain stems, no stripping; d.ts still excluded" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A materialized legacy ts/ (grace release): nested subdirs were
    // legal there, stems keep prefixes and join with '/'.
    try writeTestFile(tmp.dir, "materialized/10_boot.js", "export function update(dt) {}\n");
    try writeTestFile(tmp.dir, "materialized/ai/guard.js", "export function update(dt) {}\n");
    try writeTestFile(tmp.dir, "materialized/labelle-components.d.ts", "declare global {}\n");
    const abs = try tmp.dir.realPathFileAlloc(testing.io, "materialized", allocator);
    defer allocator.free(abs);

    const scripts = try collectEmbedScriptsAbs(allocator, abs, ts_legacy_splice_fixture);
    defer freeEmbedScripts(allocator, scripts);

    try testing.expectEqual(@as(usize, 2), scripts.len);
    try testing.expectEqualStrings("10_boot", scripts[0].name);
    try testing.expectEqualStrings("ts/10_boot.js", scripts[0].file);
    try testing.expectEqualStrings("ai/guard", scripts[1].name);
    try testing.expectEqualStrings("ts/ai/guard.js", scripts[1].file);
}

// ── collectComponentEmbeds: declarations beside the Zig components ────

test "collectComponentEmbeds: components/*.<ext> collect alphabetically with plain stems — .zig invisible, subdirs organizational, no prefix machinery" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The #237 refinement shape: declarations beside the Zig components,
    // extension-keyed. `10_zeta.rb` deliberately carries a numeric prefix
    // — components/ has NO ordering-prefix convention, so the name keeps
    // it and the order stays alphabetical by path.
    try writeTestFile(tmp.dir, "components/hunger.rb", "Hunger = Labelle.component \"Hunger\", level: 0.875\n");
    try writeTestFile(tmp.dir, "components/10_zeta.rb", "Zeta = Labelle.component \"Zeta\"\n");
    try writeTestFile(tmp.dir, "components/needs/thirst.rb", "Thirst = Labelle.component \"Thirst\"\n");
    try writeTestFile(tmp.dir, "components/worker.zig", "pub const Worker = struct {};\n");
    try writeTestFile(tmp.dir, "components/.hidden.rb", "ignored\n");
    try writeTestFile(tmp.dir, "components/README.md", "# not a source\n");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);

    const splice = ScriptingSplice{
        .plugin_name = "scripting",
        .language = "ruby",
        .dir = "scripts",
        .extension = ".rb",
    };
    const embeds = try collectComponentEmbeds(allocator, root, splice);
    defer freeEmbedScripts(allocator, embeds);

    try testing.expectEqual(@as(usize, 3), embeds.len);
    // Alphabetical by target-relative file; names are PLAIN rel stems.
    try testing.expectEqualStrings("10_zeta", embeds[0].name);
    try testing.expectEqualStrings("components/10_zeta.rb", embeds[0].file);
    try testing.expectEqualStrings("hunger", embeds[1].name);
    try testing.expectEqualStrings("components/hunger.rb", embeds[1].file);
    try testing.expectEqualStrings("needs/thirst", embeds[2].name);
    try testing.expectEqualStrings("components/needs/thirst.rb", embeds[2].file);

    // Missing dir collects empty (negative control).
    var tmp2 = testing.tmpDir(.{});
    defer tmp2.cleanup();
    const root2 = try tmp2.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root2);
    const none = try collectComponentEmbeds(allocator, root2, splice);
    defer freeEmbedScripts(allocator, none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "collectComponentEmbeds: a typescript authoring source in components/ is a pointed error; runnable .js and .d.ts pass" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Runnable .js + a declaration file: both fine (the .d.ts is not a
    // script anywhere; the .js embeds like any component-dir language
    // file).
    try writeTestFile(tmp.dir, "components/glue.js", "export const GLUE = 1;\n");
    try writeTestFile(tmp.dir, "components/labelle.d.ts", "declare const labelle: any;\n");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);

    const embeds = try collectComponentEmbeds(allocator, root, ts_splice_fixture);
    defer freeEmbedScripts(allocator, embeds);
    try testing.expectEqual(@as(usize, 1), embeds.len);
    try testing.expectEqualStrings("glue", embeds[0].name);
    try testing.expectEqualStrings("components/glue.js", embeds[0].file);

    // An authoring .ts source would be silently dead (the transpile
    // phase materializes only the SCRIPT dir) — pointed error instead.
    try writeTestFile(tmp.dir, "components/shape.ts", "export type Shape = { w: number };\n");
    try testing.expectError(
        error.ComponentsDirNeedsTranspile,
        collectComponentEmbeds(allocator, root, ts_splice_fixture),
    );

    // Gap-less languages never trip the guard — a stray .ts in a lua
    // project's components/ is the POLICY scan's business, not this one's
    // (negative control mirroring the scripts/-side rule).
    var tmp2 = testing.tmpDir(.{});
    defer tmp2.cleanup();
    try writeTestFile(tmp2.dir, "components/notes.ts", "// not a lua source\n");
    const root2 = try tmp2.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root2);
    const lua_splice = ScriptingSplice{
        .plugin_name = "scripting",
        .language = "lua",
        .dir = "scripts",
        .extension = ".lua",
    };
    const none = try collectComponentEmbeds(allocator, root2, lua_splice);
    defer freeEmbedScripts(allocator, none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "concatEmbeds: components-first emission order — shallow result, inputs keep ownership" {
    const allocator = testing.allocator;
    const comps = [_]EmbedScript{
        .{ .name = "hunger", .file = "components/hunger.rb" },
    };
    const scripts = [_]EmbedScript{
        .{ .name = "spawner", .file = "scripts/10_spawner.rb" },
        .{ .name = "feed", .file = "scripts/feed.rb" },
    };
    const combined = try concatEmbeds(allocator, &comps, &scripts);
    defer allocator.free(combined);

    try testing.expectEqual(@as(usize, 3), combined.len);
    try testing.expectEqualStrings("hunger", combined[0].name);
    try testing.expectEqualStrings("spawner", combined[1].name);
    try testing.expectEqualStrings("feed", combined[2].name);
    // Shallow: the entries alias the inputs' strings.
    try testing.expectEqual(comps[0].file.ptr, combined[0].file.ptr);

    // Either side empty passes through (the zero-scripts /
    // zero-declarations shapes).
    const none = try concatEmbeds(allocator, &.{}, &scripts);
    defer allocator.free(none);
    try testing.expectEqual(@as(usize, 2), none.len);
}

// ── collectEmbedScripts: ordering, coexistence, legacy verbatim ───────

test "collectEmbedScripts: numeric prefixes order first and strip from the stem — the Zig scripts/ convention (ordering pin)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The ticket's example plus an unprefixed tail: 10_spawner.rb before
    // 20_hunger.rb (stems "spawner"/"hunger"), 02_boot before both,
    // unprefixed after, alphabetically.
    try writeTestFile(tmp.dir, "scripts/20_hunger.rb", "class Hunger; end\n");
    try writeTestFile(tmp.dir, "scripts/10_spawner.rb", "class Spawner; end\n");
    try writeTestFile(tmp.dir, "scripts/02_boot.rb", "class Boot; end\n");
    try writeTestFile(tmp.dir, "scripts/zeta.rb", "class Zeta; end\n");
    try writeTestFile(tmp.dir, "scripts/alpha.rb", "class Alpha; end\n");
    try tmp.dir.createDirPath(testing.io, "target");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);
    const target = try tmp.dir.realPathFileAlloc(testing.io, "target", allocator);
    defer allocator.free(target);

    const splice = ScriptingSplice{
        .plugin_name = "scripting",
        .language = "ruby",
        .dir = "scripts",
        .extension = ".rb",
    };
    const scripts = try collectEmbedScripts(allocator, root, target, splice);
    defer freeEmbedScripts(allocator, scripts);

    try testing.expectEqual(@as(usize, 5), scripts.len);
    try testing.expectEqualStrings("boot", scripts[0].name);
    try testing.expectEqualStrings("scripts/02_boot.rb", scripts[0].file);
    try testing.expectEqualStrings("spawner", scripts[1].name);
    try testing.expectEqualStrings("scripts/10_spawner.rb", scripts[1].file);
    try testing.expectEqualStrings("hunger", scripts[2].name);
    try testing.expectEqualStrings("scripts/20_hunger.rb", scripts[2].file);
    try testing.expectEqualStrings("alpha", scripts[3].name);
    try testing.expectEqualStrings("zeta", scripts[4].name);

    // Stripping parity is BY CONSTRUCTION (the same function the Zig
    // scanner uses) — pin one exotic case both ways anyway.
    try testing.expectEqualStrings(
        script_scanner.stripPrefixAndExt("10x.rb", ".rb"),
        "10x", // digits without '_' are not a prefix
    );
}

test "collectEmbedScripts: duplicate numeric prefixes error like the Zig scanner (negative + control)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "scripts/10_ai.lua", "return {}\n");
    try writeTestFile(tmp.dir, "scripts/10_boot.lua", "return {}\n");
    try tmp.dir.createDirPath(testing.io, "target");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);
    const target = try tmp.dir.realPathFileAlloc(testing.io, "target", allocator);
    defer allocator.free(target);

    const splice = ScriptingSplice{
        .plugin_name = "scripting",
        .language = "lua",
        .dir = "scripts",
        .extension = ".lua",
    };
    try testing.expectError(error.DuplicateSortOrder, collectEmbedScripts(allocator, root, target, splice));

    // Control: renumbering one of them collects cleanly.
    try tmp.dir.rename("scripts/10_boot.lua", tmp.dir, "scripts/11_boot.lua", testing.io);
    const scripts = try collectEmbedScripts(allocator, root, target, splice);
    defer freeEmbedScripts(allocator, scripts);
    try testing.expectEqual(@as(usize, 2), scripts.len);
    try testing.expectEqualStrings("ai", scripts[0].name);
    try testing.expectEqualStrings("boot", scripts[1].name);
}

test "collectEmbedScripts + ScriptScanner: one mixed scripts/ dir, two scanners, disjoint extension-keyed views (coexistence pin)" {
    // THE two-layer-in-one-structure pin (labelle-engine#237): .zig and
    // .lua files share scripts/; the Zig scanner sees ONLY .zig (its
    // state-subdir machinery intact), the language collection ONLY .lua.
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "scripts/01_move.zig", "pub fn tick() void {}\n");
    try writeTestFile(tmp.dir, "scripts/hud.zig", "pub fn tick() void {}\n");
    try writeTestFile(tmp.dir, "scripts/playing/02_camera.zig", "pub fn tick() void {}\n");
    try writeTestFile(tmp.dir, "scripts/01_spawner.lua", "return {}\n");
    try writeTestFile(tmp.dir, "scripts/hunger.lua", "return {}\n");
    try tmp.dir.createDirPath(testing.io, "target");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);
    const target = try tmp.dir.realPathFileAlloc(testing.io, "target", allocator);
    defer allocator.free(target);
    const scripts_path = try std.fs.path.join(allocator, &.{ root, "scripts" });
    defer allocator.free(scripts_path);

    // Layer 1: the ZIG scanner — .zig only, .lua invisible. Note BOTH
    // layers use order 01 without colliding: the duplicate-order scopes
    // are per-scanner, exactly like the per-plugin scopes.
    var zig_scan = script_scanner.ScriptScanner.init(allocator, &.{"playing"});
    defer zig_scan.deinit();
    try zig_scan.scanDir(scripts_path);
    const zig_entries = zig_scan.getEntries();
    try testing.expectEqual(@as(usize, 3), zig_entries.len);
    for (zig_entries) |e| {
        try testing.expect(std.mem.endsWith(u8, e.filename, ".zig"));
    }
    try testing.expectEqualStrings("move", zig_entries[0].name);
    try testing.expectEqualStrings("hud", zig_entries[1].name);
    try testing.expectEqualStrings("camera", zig_entries[2].name);

    // Layer 2: the language collection — .lua only, .zig invisible, the
    // state-scoped playing/ dir not descended into.
    const splice = ScriptingSplice{
        .plugin_name = "scripting",
        .language = "lua",
        .dir = "scripts",
        .extension = ".lua",
    };
    const lua_scripts = try collectEmbedScripts(allocator, root, target, splice);
    defer freeEmbedScripts(allocator, lua_scripts);
    try testing.expectEqual(@as(usize, 2), lua_scripts.len);
    try testing.expectEqualStrings("spawner", lua_scripts[0].name);
    try testing.expectEqualStrings("scripts/01_spawner.lua", lua_scripts[0].file);
    try testing.expectEqualStrings("hunger", lua_scripts[1].name);

    // And the shared target link exists once, serving both layers.
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = try tmp.dir.readLink(testing.io, "target/scripts", &link_buf);
}

test "collectEmbedScripts: legacy dir keeps the pre-#237 behavior verbatim — recursive, plain sorted stems, no stripping" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The old ruby fixture shape: a numbered stem (NOT stripped — legacy
    // registration names are byte-stable through the grace release) and a
    // nested subdir (joined with '/').
    try writeTestFile(tmp.dir, "ruby/10_ball.rb", "class Ball; end\n");
    try writeTestFile(tmp.dir, "ruby/npc/vendor.rb", "class Vendor; end\n");
    try tmp.dir.createDirPath(testing.io, "target");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);
    const target = try tmp.dir.realPathFileAlloc(testing.io, "target", allocator);
    defer allocator.free(target);

    const splice = ScriptingSplice{
        .plugin_name = "scripting",
        .language = "ruby",
        .dir = "ruby",
        .legacy = true,
        .extension = ".rb",
    };
    const scripts = try collectEmbedScripts(allocator, root, target, splice);
    defer freeEmbedScripts(allocator, scripts);

    try testing.expectEqual(@as(usize, 2), scripts.len);
    try testing.expectEqualStrings("10_ball", scripts[0].name);
    try testing.expectEqualStrings("ruby/10_ball.rb", scripts[0].file);
    try testing.expectEqualStrings("npc/vendor", scripts[1].name);
    try testing.expectEqualStrings("ruby/npc/vendor.rb", scripts[1].file);

    // linkAndScan placed the legacy dir's target link.
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = try tmp.dir.readLink(testing.io, "target/ruby", &link_buf);
}

test "collectEmbedScripts: a missing scripts/ dir collects empty (plugin wired, nothing embeds)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "target");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);
    const target = try tmp.dir.realPathFileAlloc(testing.io, "target", allocator);
    defer allocator.free(target);

    const splice = ScriptingSplice{
        .plugin_name = "scripting",
        .language = "lua",
        .dir = "scripts",
        .extension = ".lua",
    };
    const scripts = try collectEmbedScripts(allocator, root, target, splice);
    defer freeEmbedScripts(allocator, scripts);
    try testing.expectEqual(@as(usize, 0), scripts.len);
}

test "EMBED/NATIVE extensions agree with the policy's scriptExtensions vocabulary (single-source pin)" {
    // language_policy.scriptExtensions drives the scripts/-content policing
    // and the resolve probes attribute files through the same extensions —
    // a row whose extension the policy doesn't know would be policed as
    // foreign in its own project.
    for (EMBED_LANGUAGES) |row| {
        const exts = language_policy.scriptExtensions(row.language);
        var found = false;
        for (exts) |e| {
            if (std.mem.eql(u8, e, row.extension)) found = true;
        }
        try testing.expect(found);
        if (row.transpile) |t| {
            var src_found = false;
            for (exts) |e| {
                if (std.mem.eql(u8, e, t.source_extension)) src_found = true;
            }
            try testing.expect(src_found);
        }
    }
    for (NATIVE_LANGUAGES) |row| {
        const exts = language_policy.scriptExtensions(row.language);
        var found = false;
        for (exts) |e| {
            if (std.mem.eql(u8, e, row.extension)) found = true;
        }
        try testing.expect(found);
    }
}

// ── stageNativeSources (labelle-engine#741) ──────────────────────────

const rust_splice_fixture = ScriptingSplice{
    .plugin_name = "scripting",
    .language = "rust",
    .dir = "scripts",
    .extension = ".rs",
    .family = .native,
};

/// The grace-fallback twin: detect resolved the deprecated rust/ dir.
const rust_legacy_splice_fixture = ScriptingSplice{
    .plugin_name = "scripting",
    .language = "rust",
    .dir = "rust",
    .legacy = true,
    .extension = ".rs",
    .family = .native,
};

/// A staged-plugin-package fixture: `out/deps/labelle-scripting/native/
/// src/game/mod.rs` (the shipped placeholder), plus a game root. Both
/// paths returned absolute; caller frees.
const NativeStagingFixture = struct {
    tmp: std.testing.TmpDir,
    game_abs: [:0]const u8,
    out_abs: [:0]const u8,

    fn init(allocator: std.mem.Allocator, opts: struct {
        stage_deps: bool = true,
        ship_crate: bool = true,
    }) !NativeStagingFixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "game");
        try tmp.dir.createDirPath(testing.io, "out");
        if (opts.stage_deps) {
            if (opts.ship_crate) {
                try writeTestFile(
                    tmp.dir,
                    "out/deps/labelle-scripting/native/src/game/mod.rs",
                    "// placeholder — REPLACED AT GENERATE\npub fn register() {}\n",
                );
            } else {
                try tmp.dir.createDirPath(testing.io, "out/deps/labelle-scripting");
            }
        }
        const game_abs = try tmp.dir.realPathFileAlloc(testing.io, "game", allocator);
        errdefer allocator.free(game_abs);
        const out_abs = try tmp.dir.realPathFileAlloc(testing.io, "out", allocator);
        return .{ .tmp = tmp, .game_abs = game_abs, .out_abs = out_abs };
    }

    fn deinit(self: *NativeStagingFixture, allocator: std.mem.Allocator) void {
        allocator.free(self.game_abs);
        allocator.free(self.out_abs);
        self.tmp.cleanup();
    }
};

test "stageNativeSources: LINKS the game dir over the placeholder — live view, subdirs in, edits flow without re-staging" {
    const allocator = testing.allocator;
    var fx = try NativeStagingFixture.init(allocator, .{});
    defer fx.deinit(allocator);

    // The convention shape: mod.rs at the TOP LEVEL of the shared scripts/
    // dir (subdir .rs sources are gated earlier, at detect's resolve).
    try writeTestFile(fx.tmp.dir, "game/scripts/mod.rs", "mod player;\npub fn register() {}\n");
    try writeTestFile(fx.tmp.dir, "game/scripts/player.rs", "pub struct Player;\n");
    // Foreign files: validation counts only .rs sources, but the LINK
    // exposes the whole game dir (delta from the earlier copy design,
    // documented on stageNativeSources) — asserted further down. The
    // game's ZIG scripts share the dir now and ride along the same way.
    try writeTestFile(fx.tmp.dir, "game/scripts/notes.toml", "# not a source\n");
    try writeTestFile(fx.tmp.dir, "game/scripts/01_move.zig", "pub fn tick() void {}\n");

    try stageNativeSources(allocator, fx.game_abs, fx.out_abs, rust_splice_fixture);

    // The placement is the linkAndScan primitive: a symlink whose text is
    // RELATIVE (survives a project move) — the same mechanism pin the
    // scanner_symlink suite makes for embed script dirs.
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link_len = try fx.tmp.dir.readLink(testing.io, "out/deps/labelle-scripting/native/src/game", &link_buf);
    try testing.expect(!std.fs.path.isAbsolute(link_buf[0..link_len]));

    const game_mod = try fx.tmp.dir.readFileAlloc(testing.io, "out/deps/labelle-scripting/native/src/game/mod.rs", allocator, .limited(4096));
    defer allocator.free(game_mod);
    // The PLACEHOLDER is gone — the game's scripts/mod.rs is the module root.
    try testing.expect(std.mem.indexOf(u8, game_mod, "REPLACED AT GENERATE") == null);
    try testing.expect(std.mem.indexOf(u8, game_mod, "mod player;") != null);

    try fx.tmp.dir.access(testing.io, "out/deps/labelle-scripting/native/src/game/player.rs", .{});
    // The delta from the copy design: non-.rs files ARE reachable through
    // the link — the game's Zig scripts included. Benign — rustc compiles
    // only what mod.rs declares.
    try fx.tmp.dir.access(testing.io, "out/deps/labelle-scripting/native/src/game/notes.toml", .{});
    try fx.tmp.dir.access(testing.io, "out/deps/labelle-scripting/native/src/game/01_move.zig", .{});

    // THE STALENESS PIN (the codex P2): edit a game source AFTER staging —
    // the staged view sees the new bytes WITHOUT re-staging, so the
    // generated `zig build`'s cargo step compiles current sources. A copy
    // design fails exactly here.
    try writeTestFile(fx.tmp.dir, "game/scripts/player.rs", "pub struct Player { hp: u32 }\n");
    const staged_player = try fx.tmp.dir.readFileAlloc(testing.io, "out/deps/labelle-scripting/native/src/game/player.rs", allocator, .limited(4096));
    defer allocator.free(staged_player);
    try testing.expect(std.mem.indexOf(u8, staged_player, "hp: u32") != null);

    // Deletions flow too — a removed game file is gone from the staged
    // view immediately (no second staging pass needed)…
    try fx.tmp.dir.deleteFile(testing.io, "game/scripts/player.rs");
    try testing.expectError(
        error.FileNotFound,
        fx.tmp.dir.access(testing.io, "out/deps/labelle-scripting/native/src/game/player.rs", .{}),
    );
    // …and a re-run over the correct link is a no-op reconcile (the
    // tests-target pass re-runs staging over surviving deps).
    try stageNativeSources(allocator, fx.game_abs, fx.out_abs, rust_splice_fixture);
    try fx.tmp.dir.access(testing.io, "out/deps/labelle-scripting/native/src/game/mod.rs", .{});
}

test "stageNativeSources: the LEGACY rust/ dir stages verbatim through the grace release — nested module subtrees included" {
    const allocator = testing.allocator;
    var fx = try NativeStagingFixture.init(allocator, .{});
    defer fx.deinit(allocator);

    // The unmigrated shape: rust/ with a nested module dir (legal in the
    // legacy layout; under scripts/ the same nesting is the resolve-time
    // state-subdir error).
    try writeTestFile(fx.tmp.dir, "game/rust/mod.rs", "mod player;\nmod ai;\npub fn register() {}\n");
    try writeTestFile(fx.tmp.dir, "game/rust/player.rs", "pub struct Player;\n");
    try writeTestFile(fx.tmp.dir, "game/rust/ai/brain.rs", "pub fn think() {}\n");

    try stageNativeSources(allocator, fx.game_abs, fx.out_abs, rust_legacy_splice_fixture);

    const game_mod = try fx.tmp.dir.readFileAlloc(testing.io, "out/deps/labelle-scripting/native/src/game/mod.rs", allocator, .limited(4096));
    defer allocator.free(game_mod);
    try testing.expect(std.mem.indexOf(u8, game_mod, "REPLACED AT GENERATE") == null);
    try fx.tmp.dir.access(testing.io, "out/deps/labelle-scripting/native/src/game/player.rs", .{});
    try fx.tmp.dir.access(testing.io, "out/deps/labelle-scripting/native/src/game/ai/brain.rs", .{});
}

test "stageNativeSources: no scripts/ dir at all → no-op, the shipped placeholder stays (zero scripts)" {
    const allocator = testing.allocator;
    var fx = try NativeStagingFixture.init(allocator, .{});
    defer fx.deinit(allocator);

    try stageNativeSources(allocator, fx.game_abs, fx.out_abs, rust_splice_fixture);

    const game_mod = try fx.tmp.dir.readFileAlloc(testing.io, "out/deps/labelle-scripting/native/src/game/mod.rs", allocator, .limited(4096));
    defer allocator.free(game_mod);
    try testing.expect(std.mem.indexOf(u8, game_mod, "REPLACED AT GENERATE") != null);
}

test "stageNativeSources: a Zig-only scripts/ (zero .rs) is a NO-OP — the placeholder stays, nothing is linked over the crate" {
    // The shared-dir consequence: scripts/ existing without native sources
    // is every Zig game's normal state, NOT a half-finished setup — so no
    // pointed error, and crucially NO link either (linking a .rs-less dir
    // over the crate's game module would break the plugin build).
    const allocator = testing.allocator;
    var fx = try NativeStagingFixture.init(allocator, .{});
    defer fx.deinit(allocator);

    try writeTestFile(fx.tmp.dir, "game/scripts/01_move.zig", "pub fn tick() void {}\n");
    try writeTestFile(fx.tmp.dir, "game/scripts/.gitkeep", "");

    try stageNativeSources(allocator, fx.game_abs, fx.out_abs, rust_splice_fixture);

    const game_mod = try fx.tmp.dir.readFileAlloc(testing.io, "out/deps/labelle-scripting/native/src/game/mod.rs", allocator, .limited(4096));
    defer allocator.free(game_mod);
    try testing.expect(std.mem.indexOf(u8, game_mod, "REPLACED AT GENERATE") != null);
}

test "stageNativeSources: a LEGACY rust/ dir with no .rs sources keeps the pointed error (unlike a missing dir)" {
    const allocator = testing.allocator;
    var fx = try NativeStagingFixture.init(allocator, .{});
    defer fx.deinit(allocator);

    // .gitkeep is a dot-entry — the dir is "empty" for the rule. A
    // DEDICATED per-language dir with nothing in it can only be a
    // half-finished setup, so the legacy path errors where scripts/
    // no-ops.
    try writeTestFile(fx.tmp.dir, "game/rust/.gitkeep", "");
    try writeTestFile(fx.tmp.dir, "game/rust/README.md", "no sources here\n");

    try testing.expectError(
        error.NativeScriptDirEmpty,
        stageNativeSources(allocator, fx.game_abs, fx.out_abs, rust_legacy_splice_fixture),
    );
}

test "stageNativeSources: .rs sources without the scripts/mod.rs module root fail pointing at the convention" {
    const allocator = testing.allocator;
    var fx = try NativeStagingFixture.init(allocator, .{});
    defer fx.deinit(allocator);

    try writeTestFile(fx.tmp.dir, "game/scripts/player.rs", "pub struct Player;\n");

    try testing.expectError(
        error.NativeScriptsMissingModuleRoot,
        stageNativeSources(allocator, fx.game_abs, fx.out_abs, rust_splice_fixture),
    );
}

test "stageNativeSources: deps staging fell back to the shared cache → HARD error, nothing placed" {
    // The load-bearing negative: when `createDepsLinks` degraded, the
    // `{package}` resolution falls back to the SHARED plugin cache — and
    // game sources must never be placed there (a link there would leak
    // one project's tree into every consumer). The staged-deps probe is
    // the same one the declare phase uses; here its miss is fatal.
    const allocator = testing.allocator;
    var fx = try NativeStagingFixture.init(allocator, .{ .stage_deps = false });
    defer fx.deinit(allocator);

    try writeTestFile(fx.tmp.dir, "game/scripts/mod.rs", "pub fn register() {}\n");

    try testing.expectError(
        error.NativeScriptsDepsUnstaged,
        stageNativeSources(allocator, fx.game_abs, fx.out_abs, rust_splice_fixture),
    );
    // And nothing was created under out/ — the error fired before any write.
    try testing.expectError(
        error.FileNotFound,
        fx.tmp.dir.access(testing.io, "out/deps/labelle-scripting", .{}),
    );
}

test "stageNativeSources: a staged plugin package without the native/ crate fails naming the pin fix" {
    const allocator = testing.allocator;
    var fx = try NativeStagingFixture.init(allocator, .{ .ship_crate = false });
    defer fx.deinit(allocator);

    try writeTestFile(fx.tmp.dir, "game/scripts/mod.rs", "pub fn register() {}\n");

    try testing.expectError(
        error.NativeCrateLayoutMissing,
        stageNativeSources(allocator, fx.game_abs, fx.out_abs, rust_splice_fixture),
    );
}

test "stageNativeSources: an embed-family splice is a no-op (family gate)" {
    const allocator = testing.allocator;
    var fx = try NativeStagingFixture.init(allocator, .{ .stage_deps = false });
    defer fx.deinit(allocator);

    // Even with a source dir present and NO staged deps (the hard-error
    // shape for natives), an embed splice must never reach the staging
    // logic — root.zig gates on family, and so does the function itself.
    try writeTestFile(fx.tmp.dir, "game/scripts/player.lua", "-- lua\n");
    const lua_splice = ScriptingSplice{
        .plugin_name = "scripting",
        .language = "lua",
        .dir = "scripts",
        .extension = ".lua",
    };
    try stageNativeSources(allocator, fx.game_abs, fx.out_abs, lua_splice);
}

// ── collectEventEmbeds: declarations beside the Zig events (#772) ─────

test "collectEventEmbeds: events/*.<ext> collect alphabetically with plain stems — .zig invisible, extension-keyed (the v0.85.0 rule)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The #772 shape: event declarations beside the Zig events,
    // extension-keyed — the Zig scan keeps .zig, this collects only the
    // splice's extension. The stray .lua under a RUBY splice is the
    // non-selected-language forward-compat rule: ignored, exactly like
    // scripts/.
    try writeTestFile(tmp.dir, "events/hunger__feed.rb", "HungerFeed = Labelle.event \"hunger__feed\", entity: Labelle.id, amount: 0.5\n");
    try writeTestFile(tmp.dir, "events/combat/hit.rb", "Hit = Labelle.event \"combat__hit\", damage: 1\n");
    try writeTestFile(tmp.dir, "events/door_opened.zig", "pub const DoorOpened = struct {};\n");
    try writeTestFile(tmp.dir, "events/wave.lua", "Wave = labelle.event(\"wave\", {})\n");
    try writeTestFile(tmp.dir, "events/.hidden.rb", "ignored\n");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);

    const splice = ScriptingSplice{
        .plugin_name = "scripting",
        .language = "ruby",
        .dir = "scripts",
        .extension = ".rb",
    };
    const embeds = try collectEventEmbeds(allocator, root, splice);
    defer freeEmbedScripts(allocator, embeds);

    try testing.expectEqual(@as(usize, 2), embeds.len);
    // Alphabetical by target-relative file; names are PLAIN rel stems.
    try testing.expectEqualStrings("combat/hit", embeds[0].name);
    try testing.expectEqualStrings("events/combat/hit.rb", embeds[0].file);
    try testing.expectEqualStrings("hunger__feed", embeds[1].name);
    try testing.expectEqualStrings("events/hunger__feed.rb", embeds[1].file);

    // Missing events/ collects empty (negative control).
    var tmp2 = testing.tmpDir(.{});
    defer tmp2.cleanup();
    const root2 = try tmp2.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root2);
    const none = try collectEventEmbeds(allocator, root2, splice);
    defer freeEmbedScripts(allocator, none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "collectEventEmbeds: a typescript authoring source in events/ is its own pointed error; .d.ts exempt" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "events/labelle.d.ts", "declare const labelle: any;\n");
    try writeTestFile(tmp.dir, "events/hit.ts", "export type Hit = { damage: number };\n");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);

    try testing.expectError(
        error.EventsDirNeedsTranspile,
        collectEventEmbeds(allocator, root, ts_splice_fixture),
    );
}

test "concatEmbeds3: components -> events -> scripts registration order (the #772 order pin) — shallow, inputs keep ownership" {
    const allocator = testing.allocator;
    const comps = [_]EmbedScript{
        .{ .name = "hunger", .file = "components/hunger.rb" },
    };
    const events = [_]EmbedScript{
        .{ .name = "hunger__feed", .file = "events/hunger__feed.rb" },
    };
    const scripts = [_]EmbedScript{
        .{ .name = "spawner", .file = "scripts/10_spawner.rb" },
        .{ .name = "feed_watcher", .file = "scripts/feed_watcher.rb" },
    };
    const combined = try concatEmbeds3(allocator, &comps, &events, &scripts);
    defer allocator.free(combined);

    // The ORDER is the contract (each layer's constants must exist when
    // the next loads): components, then events, then the script dir.
    try testing.expectEqual(@as(usize, 4), combined.len);
    try testing.expectEqualStrings("hunger", combined[0].name);
    try testing.expectEqualStrings("hunger__feed", combined[1].name);
    try testing.expectEqualStrings("components/hunger.rb", combined[0].file);
    try testing.expectEqualStrings("events/hunger__feed.rb", combined[1].file);
    try testing.expectEqualStrings("scripts/10_spawner.rb", combined[2].file);
    try testing.expectEqualStrings("scripts/feed_watcher.rb", combined[3].file);

    // Shallow: the result borrows the inputs' strings.
    try testing.expectEqual(comps[0].name.ptr, combined[0].name.ptr);
    try testing.expectEqual(events[0].name.ptr, combined[1].name.ptr);
    try testing.expectEqual(scripts[0].name.ptr, combined[2].name.ptr);

    // Empty middle (no event declarations) degrades to the pre-#772
    // two-way shape byte-for-byte.
    const no_events = try concatEmbeds3(allocator, &comps, &.{}, &scripts);
    defer allocator.free(no_events);
    try testing.expectEqual(@as(usize, 3), no_events.len);
    try testing.expectEqualStrings("hunger", no_events[0].name);
    try testing.expectEqualStrings("spawner", no_events[1].name);
}
