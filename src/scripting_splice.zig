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
const scripting_csharp = @import("scripting_csharp.zig");

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
/// One local pack's co-watched script dir (labelle-scripting#51), with
/// the same primary/fallback candidate pair the game-dir watch emits so
/// hot reload works regardless of the binary's launch cwd.
pub const PackWatchDir = struct {
    /// SOURCE `scripts/` dir relative to the generated TARGET dir (the
    /// game's cwd under `labelle run` → `zig build run` in
    /// `.labelle/<target>/`). Forward-slash normalized.
    from_target: []const u8,
    /// SOURCE `scripts/` dir relative to the PROJECT ROOT (a binary
    /// launched from the project root itself — the game-dir watch's
    /// fallback, applied per pack). Forward-slash normalized.
    from_root: []const u8,
    /// Reload-name namespace prefix the pack's scripts register under
    /// (`<pack>__`, `scan.packNamespacePrefix` + `__` — codex round-2
    /// #642). Emitted as the `watchDirNamed` prefix so the watcher keys
    /// each reload onto the pack's NAMESPACED registration, never the
    /// game's same-stem script. Ties the watch to the ACTUAL pack
    /// registration convention rather than a bare-stem guess.
    name_prefix: []const u8,
};

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
    /// Native-only staging geometry (RFC-LANGUAGE-PLUGINS rev 19 §7 "Native
    /// wiring contract"), resolved once by `detect` from the manifest
    /// `.languages` row (PRIMARY) or the frozen `NATIVE_LANGUAGES` table
    /// (fallback): `module_root` is the crate module-root filename required
    /// at the script-dir root (`mod.rs`/`game.cr`); `stage_subdir` is the
    /// plugin-crate-relative dir the game sources link over
    /// (`native/src/game`). Both null for embed splices —
    /// `stageNativeSources` reads them instead of a frozen-table lookup.
    module_root: ?[]const u8 = null,
    stage_subdir: ?[]const u8 = null,
    /// Runtime-output-staging CAPABILITY of the resolved language
    /// (labelle-assembler#619, migrated from #644's `language == "csharp"`
    /// decision): true when this language's link-less `.language_builds`
    /// outputs ARE the runtime payload (the CoreCLR/hostfxr contract) — the
    /// generated build.zig stages the publish dir beside the binary + sets
    /// the run-step assembly-dir env. Resolved once by `detect`: the
    /// manifest row's `.runtime_output` (PRIMARY) OR the frozen csharp
    /// fallback (`scripting_csharp.frozenRuntimeOutput`). Consumed at the
    /// build-steps wiring (`scripting_csharp.stagesRuntimeOutputs`, which
    /// ANDs it with the link-less + scripting-plugin-ownership checks). A
    /// plain bool — no ownership. Default false → byte-identical.
    runtime_output: bool = false,
    /// Toolchain-probe opt-in CAPABILITY (labelle-assembler#619, migrated
    /// from #644's csharp-scoped `ensureStepToolsOnPath` call): true when the
    /// assembler should PATH-probe this language's selected `.language_builds`
    /// argv[0]s at generate and fail pointedly on a missing tool. Resolved by
    /// `detect`: the row's `.probe_tools` (PRIMARY) OR the frozen csharp
    /// fallback (`scripting_csharp.frozenProbeTools`). Default false (no
    /// probe) → byte-identical; rust/crystal deliberately opt out.
    probe_tools: bool = false,
    /// Embed-only authoring→embed transpile source (typescript `.ts`/
    /// `.d.ts`), resolved once by `detect` from the row's `.transpile`
    /// capability (PRIMARY) or the frozen `EMBED_LANGUAGES` table (fallback).
    /// Null when the authored extension IS the embedded one (lua, ruby) or
    /// for native. The transpile phase and `collectDeclEmbeds` read it here
    /// rather than re-deriving from a table, so the `.ts`→embed knowledge is
    /// fully row-driven (rev 19 A3: the hard-coded `#586` gap dissolved into
    /// the row's `.transpile` presence, exactly as `min_pin` did).
    transpile: ?TranspileSource = null,
    /// Dev-mode hot-reload capability of the RESOLVED plugin package
    /// (labelle-assembler#637): true when the plugin's build.zig declares
    /// the `hot_reload` build option (labelle-scripting ≥ v0.12.0,
    /// labelle-scripting#47). Probed by CONTENT (`probeHotReload`), not by
    /// a semver compare — the same self-describing philosophy that
    /// dissolved the `min_pin` tables into manifest rows, and it stays
    /// correct for `local:` pins that carry no version at all. Gates BOTH
    /// dev-mode emissions: the generated build.zig's
    /// `.hot_reload = optimize == .Debug` dependency arg (an unknown dep
    /// option is a HARD build error on older plugins, so this one cannot
    /// ride a generated-code `@hasDecl`) and the generated main's
    /// `watchDir` splice (`emitHotReloadWatch`). Default false keeps every
    /// existing fixture/caller byte-identical.
    hot_reload_capable: bool = false,
    /// The SOURCE script dir as seen from the generated target dir
    /// (`../../scripts` for the canonical `.labelle/<target>/` layout),
    /// forward-slash normalized. Computed by root.zig (which knows both
    /// dirs) and threaded here for `emitHotReloadWatch` — the generated
    /// game runs with cwd = the target dir (`labelle run` → `zig build
    /// run` in `.labelle/<target>/`), and the watcher must poll the
    /// SOURCE tree the developer edits, not the staged view (a real COPY
    /// on Windows without symlink privileges — `scanner.linkDirAbs`'s
    /// fallback — where staged-dir watching would miss every edit).
    /// Null → the emission falls back to the cwd-relative `dir` alone.
    /// Borrowed (root.zig owns and frees it), like `scripts`.
    watch_dir_from_target: ?[]const u8 = null,
    /// LOCAL pack script source dirs to co-watch (labelle-scripting#51) —
    /// each carries the SAME primary/fallback pair the game-dir watch
    /// uses (`from_target` = SOURCE dir relative to the generated target
    /// dir, the game's cwd under `labelle run`; `from_root` = relative to
    /// the PROJECT ROOT, for a binary launched from there). Computed by
    /// root.zig for every `local:`/`@`-pinned pack that (a) ships a
    /// `scripts/` SOURCE dir AND (b) actually contributes at least one
    /// REGISTERED script to `scripts` (codex P2 #642: a pack the assembler
    /// never collected into the registered set has no reload target, so
    /// watching it would inject an unregistered script into the running
    /// VM on save). Published/cached packs are excluded (their cache copy
    /// is not the tree anyone edits), and nested plugin-bundled packs ride
    /// their plugin (empty `.repo`, never `isLocal`). Consumed by
    /// `emitHotReloadWatch`, which wraps the emitted `watchDir` calls in
    /// the comptime multi-root capability gate (see there). Borrowed
    /// (root.zig owns and frees both strings), like `scripts`.
    pack_watch_dirs: []const PackWatchDir = &.{},
    /// Did the transpile phase ACTUALLY check+emit into the target's
    /// materialized script dir this generate (`scripting_transpile
    /// .runPhase` returned non-null)? Set by root.zig right after the
    /// phase. THE watch-dir discriminator for hot reload (round-3 codex,
    /// PR #638) — the LANGUAGE having a transpile row is not enough: a
    /// js-only typescript project (the documented `// @ts-check`
    /// workflow) never transpiles, keeps the plain staged link/copy
    /// layout, and its `.js` SOURCES are the runnable files — it must
    /// watch the source tree exactly like ruby/lua (on Windows the
    /// staged copy would never see a save). Only when output was really
    /// materialized does the watch move to the target's own dir.
    transpile_emitted: bool = false,
    /// Set to the allocator when `detect` resolved this splice from a
    /// manifest `.languages` row and HEAP-DUPED the row-derived strings
    /// (`extension`, `module_root`, `stage_subdir`, `transpile.*`); `deinit`
    /// then frees exactly those. A null owner means every string is static
    /// (the frozen-table fallback, or a test/`.detect`-less literal), so
    /// `deinit` is a no-op and every existing caller stays byte-identical.
    owner: ?std.mem.Allocator = null,

    /// Free the row-derived strings `detect` duped from the manifest — a
    /// no-op for a frozen-fallback / literal splice (see `owner`).
    pub fn deinit(self: *ScriptingSplice) void {
        const a = self.owner orelse return;
        a.free(self.extension);
        if (self.module_root) |m| a.free(m);
        if (self.stage_subdir) |s| a.free(s);
        if (self.transpile) |t| {
            a.free(t.source_extension);
            a.free(t.declaration_suffix);
        }
        self.owner = null;
    }
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

        // Dev-mode hot-reload capability (labelle-assembler#637): one
        // content probe of the resolved package per generate — see the
        // field doc on `hot_reload_capable` for why a content probe (not
        // a semver compare) and what it gates.
        const hot_reload_capable = probeHotReload(allocator, plugin, game_dir);

        // Runtime-output + toolchain-probe capabilities (labelle-assembler
        // #619, migrated from #644's `language == "csharp"` decisions): the
        // manifest row's `.runtime_output`/`.probe_tools` (PRIMARY) OR the
        // frozen csharp fallback (`scripting_csharp.frozen*`, the demoted
        // hardcode — the shipped csharp manifest predates these). Resolved
        // once here and applied to every returned splice, so a future
        // runtime-loaded language rides its row with zero assembler changes.
        const lang_row = pmani.languageRow(declared.language);
        const runtime_output = (if (lang_row) |r| r.runtime_output else false) or
            scripting_csharp.frozenRuntimeOutput(declared.language);
        const probe_tools = (if (lang_row) |r| r.probe_tools else false) or
            scripting_csharp.frozenProbeTools(declared.language);

        // PRIMARY (rev 19): the manifest `.languages` capability row drives
        // the splice — `.kind` → family, `.extensions`/`.transpile` → the
        // embed extension + transpile source (embedded), `.module_root` +
        // `.stage_subdir` → the native staging geometry. The row's strings
        // are duped onto the splice (freed by `ScriptingSplice.deinit`)
        // because `pmani` is released when detect returns. A present row with
        // an incomplete NATIVE geometry (missing `.module_root`/
        // `.stage_subdir`) is not drivable → falls through to the frozen
        // table (rust/crystal covered there) or the integration-gap warning.
        if (lang_row) |row| {
            if (try spliceFromRow(allocator, plugin.name, declared.language, game_dir, row)) |s| {
                var out = s;
                out.hot_reload_capable = hot_reload_capable;
                out.runtime_output = runtime_output;
                out.probe_tools = probe_tools;
                return out;
            }
        }

        // FROZEN FALLBACK (Migration bullet): manifests predating `.languages`
        // rows keep resolving via the built-in tables — never extended again
        // (a new language comes via a manifest row, the python litmus test).
        if (embedRow(declared.language)) |row| {
            const resolved = try resolveEmbedScriptDir(allocator, game_dir, declared.language, row.extension, row.transpile);
            return .{
                .plugin_name = plugin.name,
                .language = declared.language,
                .dir = resolved.dir,
                .legacy = resolved.legacy,
                .extension = row.extension,
                .family = .embed,
                .transpile = row.transpile,
                .hot_reload_capable = hot_reload_capable,
                .runtime_output = runtime_output,
                .probe_tools = probe_tools,
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
                .module_root = row.module_root,
                .stage_subdir = row.stage_subdir,
                .runtime_output = runtime_output,
                .probe_tools = probe_tools,
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

// ── Dev-mode hot reload (labelle-assembler#637) ───────────────────────

/// Probe the resolved scripting package for the dev-mode hot-reload
/// surface: does its build.zig declare the `hot_reload` build option
/// (labelle-scripting ≥ v0.12.0, labelle-scripting#47)? Content probe by
/// design — a semver compare would misclassify `local:` pins (no version)
/// and re-grow exactly the assembler-side version tables the manifest
/// `.languages` rows dissolved. Anchored to the DECLARATION form
/// (`…option(bool, "hot_reload"`, whitespace-tolerant — see
/// `containsHotReloadOptionDecl`), never any quoted mention: a comment or
/// diagnostic string spelling `"hot_reload"` must not flip capability on,
/// because the generated build.zig would then pass an option the plugin
/// never declared — a hard `zig build` error (codex, PR #638). Any
/// resolution/read failure degrades to `false` (splice-less dev mode) —
/// the probe must never fail a generate that would otherwise succeed.
pub fn probeHotReload(
    allocator: std.mem.Allocator,
    plugin: config.PluginDep,
    game_dir: []const u8,
) bool {
    const plugin_dir = cache.resolvePlugin(allocator, plugin, game_dir) catch return false;
    defer allocator.free(plugin_dir);
    return probeHotReloadAt(allocator, plugin_dir);
}

/// `probeHotReload` over an already-resolved package dir (test seam).
pub fn probeHotReloadAt(allocator: std.mem.Allocator, plugin_dir: []const u8) bool {
    const build_path = std.fs.path.join(allocator, &.{ plugin_dir, "build.zig" }) catch return false;
    defer allocator.free(build_path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        config.globalIo(),
        build_path,
        allocator,
        .limited(1024 * 1024),
    ) catch return false;
    defer allocator.free(bytes);
    // Blank comments FIRST (round-3 codex, PR #638: a commented-out
    // sample declaration must not read as capable), then shape-match.
    blankCommentsForProbe(bytes);
    return containsHotReloadOptionDecl(bytes);
}

/// Blank out (overwrite with spaces) every `//` line comment and every
/// Zig multiline-string-literal line (`\\…`) in `buf`, so the declaration
/// matcher below only ever sees LIVE code — a commented-out
/// `// const hot_reload = b.option(bool, "hot_reload", …)` sample must
/// not flip capability on (round-3 codex on PR #638; the generated build
/// would then pass an option the plugin never declared — a hard error).
///
/// Precision chosen: a line-level scan that is STRING-LITERAL AWARE — a
/// `//` inside a `"…"` literal (a URL, say) does not truncate the line,
/// and backslash escapes inside strings are honored so `"…\"…"` doesn't
/// desync the state. Lines whose first non-whitespace token is `\\` are
/// multiline-string CONTENT and are blanked whole (a live declaration
/// can never legally sit inside one). Char literals (`'"'`) are NOT
/// modeled — a double-quote char literal preceding a live declaration on
/// the same line could hide it, which degrades toward NOT-capable (the
/// safe direction) and does not occur in build.zig convention. Offsets
/// are preserved (blank, never splice) so the matcher's cross-line scan
/// runs over the same buffer.
///
/// Public because the plugin-event consumption scan's gated-literal
/// downgrade probe (`scan/event_consumption.zig`, #635) reuses the same
/// blanking before searching for a quoted tag — a tag mentioned only in
/// a comment must not read as a live `@hasField` gate.
pub fn blankCommentsForProbe(buf: []u8) void {
    var i: usize = 0;
    while (i < buf.len) {
        const line_end = std.mem.indexOfScalarPos(u8, buf, i, '\n') orelse buf.len;
        var j = i;
        while (j < line_end and (buf[j] == ' ' or buf[j] == '\t')) : (j += 1) {}
        if (j + 1 < line_end and buf[j] == '\\' and buf[j + 1] == '\\') {
            // Multiline string-literal line: everything is string content.
            @memset(buf[j..line_end], ' ');
        } else {
            var in_string = false;
            while (j < line_end) : (j += 1) {
                const c = buf[j];
                if (in_string) {
                    if (c == '\\' and j + 1 < line_end) {
                        j += 1; // escaped char inside the literal
                    } else if (c == '"') {
                        in_string = false;
                    }
                } else if (c == '"') {
                    in_string = true;
                } else if (c == '/' and j + 1 < line_end and buf[j + 1] == '/') {
                    @memset(buf[j..line_end], ' ');
                    break;
                }
            }
        }
        i = line_end + 1;
    }
}

/// True when `src` contains the option DECLARATION
/// `option(bool, "hot_reload"` — whitespace/newline-tolerant between the
/// tokens, so both the single-line spelling and labelle-scripting's
/// multi-line `b.option(\n    bool,\n    "hot_reload",\n    …)` match.
/// Anchors on `option(` (receiver-agnostic — `b.option`, a renamed
/// builder) followed by exactly `bool` `,` `"hot_reload"`; a quoted
/// mention in a comment or diagnostic never has that shape, so it cannot
/// over-match (the codex P2 on PR #638).
fn containsHotReloadOptionDecl(src: []const u8) bool {
    const anchor = "option(";
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, src, search, anchor)) |at| {
        search = at + anchor.len;
        var i = skipZigWs(src, search);
        if (!std.mem.startsWith(u8, src[i..], "bool")) continue;
        i = skipZigWs(src, i + "bool".len);
        if (i >= src.len or src[i] != ',') continue;
        i = skipZigWs(src, i + 1);
        if (std.mem.startsWith(u8, src[i..], "\"hot_reload\"")) return true;
    }
    return false;
}

/// Index of the first non-whitespace byte at or after `start`.
fn skipZigWs(src: []const u8, start: usize) usize {
    var i = start;
    while (i < src.len) : (i += 1) {
        switch (src[i]) {
            ' ', '\t', '\r', '\n' => {},
            else => break,
        }
    }
    return i;
}

/// Compute one LOCAL pack's co-watch dirs for the dev splice
/// (labelle-scripting#51): the pack's `<pack_src_dir>/scripts` as seen
/// both from the generated TARGET dir (primary) and from the PROJECT
/// ROOT (`game_dir`, fallback) — the same primary/fallback pair the
/// game-dir watch emits (coderabbit #642), forward-slash normalized (the
/// separator-safe emitted-literal rule). Null when the pack ships no
/// `scripts/` dir (nothing to watch — the splice never registers a dir
/// that would fail to open at boot). OutOfMemory PROPAGATES (gemini #642:
/// the other resolution helpers in root.zig do — a real OOM must not be
/// silently mistaken for an absent dir); only the genuinely-absent
/// `openDir` cases (`FileNotFound`/`NotDir`) degrade to null. Caller owns
/// both returned strings.
pub fn packWatchDirs(
    allocator: std.mem.Allocator,
    game_dir: []const u8,
    target_dir: []const u8,
    pack_src_dir: []const u8,
    name_prefix: []const u8,
) !?PackWatchDir {
    const scripts_abs = try std.fs.path.join(allocator, &.{ pack_src_dir, "scripts" });
    defer allocator.free(scripts_abs);
    const io = config.globalIo();
    var probe = std.Io.Dir.cwd().openDir(io, scripts_abs, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    probe.close(io);

    const from_target = try std.fs.path.relative(allocator, "", null, target_dir, scripts_abs);
    errdefer allocator.free(from_target);
    for (from_target) |*ch| {
        if (ch.* == '\\') ch.* = '/';
    }
    const from_root = try std.fs.path.relative(allocator, "", null, game_dir, scripts_abs);
    errdefer allocator.free(from_root);
    for (from_root) |*ch| {
        if (ch.* == '\\') ch.* = '/';
    }
    const prefix_owned = try allocator.dupe(u8, name_prefix);
    return .{ .from_target = from_target, .from_root = from_root, .name_prefix = prefix_owned };
}

/// Does any REGISTERED embed script (`scripts`) come from the pack
/// `pack_name`'s copied tree (`packs/<pack_name>/…` target-relative
/// `file`)? The gate `emitHotReloadWatch`/root.zig use so a pack with no
/// registered script gets no watch (codex P2 #642). A `[128]u8` prefix
/// buffer covers every real pack name; longer names conservatively fail
/// the match (no watch) rather than truncate into a false positive.
pub fn packHasRegisteredScript(scripts: []const EmbedScript, pack_name: []const u8) bool {
    var buf: [128]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buf, "packs/{s}/", .{pack_name}) catch return false;
    for (scripts) |sc| {
        if (std.mem.startsWith(u8, sc.file, prefix)) return true;
    }
    return false;
}

/// Should the generated build.zig pass `.hot_reload = optimize == .Debug`
/// to the scripting plugin's `b.dependency` args? Extracted so the gate
/// set is auditable + unit-testable in one place (the `testsTargetConfig`
/// pattern):
///   - EMBED family only — the native family (rust/crystal/csharp) has no
///     reload story (`supports_reload = false`, RFC v1 scope);
///   - the resolved package must DECLARE the option (`hot_reload_capable`)
///     — passing an undeclared dependency option is a hard `zig build`
///     error, so this one cannot hide behind a generated-code `@hasDecl`;
///   - NEVER the tests target — tests exercise game logic, not the dev
///     loop, and must not compile the watcher in (the explicit pin the
///     tests target carries for gamepad/backend too, assembler#627);
///   - desktop only — wasm/android/ios have no editable source tree to
///     poll next to the running game;
///   - NOT the deprecated legacy per-language dir (`lua/`, `ts/` — the
///     one-release grace fallback): its recursive collection registers
///     subdir-joined stems (`ai/guard`) the plugin's FLAT-dir watcher can
///     never report (watch.zig maps plain filenames through the scripts/
///     stem rule), so reloads would target the wrong (or no) registration
///     — the codex P2 on PR #638. Migrating to `scripts/` turns hot
///     reload on; the deprecation carrot.
pub fn buildDepHotReload(
    splice: ScriptingSplice,
    is_tests_target: bool,
    platform: config.Platform,
) bool {
    return splice.family == .embed and
        splice.hot_reload_capable and
        !splice.legacy and
        !is_tests_target and
        platform == .desktop;
}

/// Emit the generated main's dev-mode watch splice (labelle-assembler#637):
/// register the game's SOURCE script dir with the scripting plugin's disk
/// watcher after `PluginControllers.setup` booted the VM. The pump needs no
/// splice of its own — the plugin's `Controller.tick` (already emitted by
/// the #593 tick splice) pumps the watcher internally when the plugin is
/// built with `-Dhot_reload=true` (labelle-scripting src/root.zig, the
/// tick-counted ~4 Hz cadence).
///
/// The emitted block is DOUBLE comptime-gated in the generated code:
///   - `@import("builtin").mode == .Debug` — `labelle run` and `labelle
///     build` share generated output; the optimize mode is the dev-vs-ship
///     signal (run defaults to Debug, release passes `-Doptimize`), so the
///     whole block folds out of release binaries;
///   - `@hasDecl(scripting, "hot_reload")` — belt-and-braces against a
///     plugin/assembler skew: with an older scripting the splice is a
///     comptime no-op, never a compile error.
///
/// Watch-path strategy, by what the game actually RUNS (round-3 codex:
/// the discriminator is `transpile_emitted` — output materialized this
/// generate — never the language):
///   - Source-run shapes (lua, ruby — and js-only typescript, the
///     documented `// @ts-check` workflow, where the authored `.js` IS
///     the runnable file and no transpile ran): primary =
///     `watch_dir_from_target` (the SOURCE tree relative to the generated
///     target dir, where the game's cwd normally is — see that field's doc
///     for the Windows staged-COPY trap), fallback = the project-root-
///     relative `dir` for a binary launched from the project root itself.
///     The runtime loads staged/embedded copies, but reload READS the
///     watched source file — the ruby model, Windows-correct because the
///     watch is on source, not staging.
///   - Transpile-EMITTED shapes (`.ts` sources present): the watcher
///     filters the EMBED extension (`.js` — the plugin's comptime
///     `scriptExtension`), and the runnable `.js` lives in the generated
///     target's materialized script dir (`scripting_transpile.runPhase`
///     deletes the staging link and copies+emits there) — the SOURCE
///     `.ts` would never match. So the watch registers the target's own
///     dir (cwd-relative `dir`), and live TS dev edits the emitted `.js`
///     (or re-runs generate for `.ts` changes) — labelle-scripting#47's
///     documented v1 limitation ("TS hot reload watches emitted .js — no
///     in-process tsc"); incremental transpile-on-watch belongs with the
///     TS7 transpile work (labelle-engine#745 follow-ups).
///     Windows-correct by construction: the emitted `.js` is generated
///     OUTPUT (the only runnable copy), not a staged mirror of source.
/// Failure to open logs and degrades — dev-mode wiring must never take
/// the game down.
///
/// Caller gates: emitted only for desktop targets (both lifecycle paths
/// pass their platform check first); this helper self-gates on the embed
/// family, the capability probe, AND the non-legacy dir (see
/// `buildDepHotReload`'s legacy rationale — recursive legacy stems can
/// never match the flat-dir watcher's reports), so every existing fixture
/// stays byte-identical.
pub fn emitHotReloadWatch(w: anytype, splice: ScriptingSplice) !void {
    if (splice.family != .embed or !splice.hot_reload_capable or splice.legacy) return;

    if (splice.transpile_emitted) {
        try w.writeAll(
            "\n" ++
                "    // Dev-mode script hot reload (labelle-assembler#637): Debug builds\n" ++
                "    // only — the comptime gate folds this out of release binaries, and\n" ++
                "    // the @hasDecl probe no-ops it against a scripting plugin predating\n" ++
                "    // the hot-reload surface (labelle-scripting v0.12.0). TRANSPILED\n" ++
                "    // language: the watcher filters the EMBED extension, so it watches\n" ++
                "    // this generated target's own script dir — where the transpile\n" ++
                "    // phase materialized the runnable output (generated OUTPUT, the\n" ++
                "    // only runnable copy — never a staged mirror of source, so this is\n" ++
                "    // Windows-correct by construction). v1 limitation (labelle-\n" ++
                "    // scripting#47): live-edit the emitted file here directly, or\n" ++
                "    // re-run `labelle generate` for authored-source changes.\n",
        );
    } else {
        try w.writeAll(
            "\n" ++
                "    // Dev-mode script hot reload (labelle-assembler#637): Debug builds\n" ++
                "    // only — the comptime gate folds this out of release binaries, and\n" ++
                "    // the @hasDecl probe no-ops it against a scripting plugin predating\n" ++
                "    // the hot-reload surface (labelle-scripting v0.12.0). Watches the\n" ++
                "    // SOURCE script dir (the tree the developer edits): staging is a\n" ++
                "    // symlink on POSIX but can be a real COPY on Windows, where the\n" ++
                "    // staged dir would never see an edit.\n",
        );
    }
    try w.writeAll(
        "    if (comptime (@import(\"builtin\").mode == .Debug and @hasDecl(scripting, \"hot_reload\"))) hot_reload: {\n" ++
            "        const HotReloadIo = struct {\n" ++
            "            var threaded: std.Io.Threaded = undefined;\n" ++
            "        };\n" ++
            "        // page_allocator on purpose: the watcher and reloaded sources\n" ++
            "        // live for the whole (dev) process — kept out of the game\n" ++
            "        // allocator's leak accounting.\n" ++
            "        HotReloadIo.threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});\n" ++
            "        const hot_reload_io = HotReloadIo.threaded.io();\n",
    );
    const watch_source = !splice.transpile_emitted;
    if (watch_source and splice.watch_dir_from_target != null) {
        const primary = splice.watch_dir_from_target.?;
        try w.print("        scripting.hot_reload.watchDir(hot_reload_io, std.heap.page_allocator, \"{s}\") catch {{\n", .{primary});
        try w.writeAll(
            "            // cwd is normally `.labelle/<target>/` (`labelle run` invokes\n" ++
                "            // `zig build run` there); fall back to the project-root-relative\n" ++
                "            // dir for a binary launched from the project root itself.\n",
        );
        try w.print("            scripting.hot_reload.watchDir(hot_reload_io, std.heap.page_allocator, \"{s}\") catch |watch_err| {{\n", .{splice.dir});
        try w.print("                std.debug.print(\"labelle: script hot reload disabled — could not open '{s}': {{s}}\\n\", .{{@errorName(watch_err)}});\n", .{splice.dir});
        try w.writeAll(
            "                break :hot_reload;\n" ++
                "            };\n" ++
                "        };\n",
        );
    } else {
        // Transpile-emitted: the target's own materialized dir,
        // cwd-relative (the game runs with cwd = the target dir). A
        // source-run splice without a computed relative path degrades to
        // the same single watch.
        try w.print("        scripting.hot_reload.watchDir(hot_reload_io, std.heap.page_allocator, \"{s}\") catch |watch_err| {{\n", .{splice.dir});
        try w.print("            std.debug.print(\"labelle: script hot reload disabled — could not open '{s}': {{s}}\\n\", .{{@errorName(watch_err)}});\n", .{splice.dir});
        try w.writeAll(
            "            break :hot_reload;\n" ++
                "        };\n",
        );
    }
    // Local pack script dirs (labelle-scripting#51): in-tree (`local:` /
    // `@libs`) packs are just as editable as the game's scripts, so their
    // SOURCE `scripts/` dirs co-watch. SOURCE-run shapes only — a
    // transpile-EMITTED project's pack sources are authored `.ts`, which
    // the embed-extension (`.js`) watcher can never match, so emitting
    // their watch would be a dead promise. The emitted block carries its
    // own comptime gate on the MULTI-ROOT watch layer (labelle-scripting
    // #51's `watchedRootCount` introspection decl, the same release as
    // multi-root `watchDir`): on the old single-slot layer every
    // `watchDir` REPLACED the previous root, so a second call would
    // silently clobber the game-dir watch above — against such a plugin
    // these calls must fold out entirely (@hasDecl, the belt-and-braces
    // convention the #638 splice already uses for `hot_reload` itself).
    if (!splice.transpile_emitted and splice.pack_watch_dirs.len > 0) {
        try w.writeAll(
            "        // Local pack script dirs (labelle-scripting#51): in-tree packs are\n" ++
                "        // just as editable as the game's scripts. Comptime-gated on\n" ++
                "        // `watchDirNamed` — the multi-root + namespaced-reload surface\n" ++
                "        // (the same labelle-scripting release as watchedRootCount). On an\n" ++
                "        // older single-slot plugin the decl is absent, so these fold away\n" ++
                "        // entirely and never clobber the game-dir watch above.\n" ++
                "        if (comptime @hasDecl(scripting.hot_reload, \"watchDirNamed\")) {\n",
        );
        for (splice.pack_watch_dirs) |pack| {
            // Same primary/fallback pair the game-dir watch above uses:
            // try the target-relative SOURCE dir first (the game's cwd
            // under `labelle run`), then the project-root-relative one
            // (a binary launched from the project root). Each is a
            // `watchDirNamed` under the pack's `<pack>__` reload prefix, so
            // every stem this root reports reloads onto the pack's
            // NAMESPACED registration — never the game's same-stem script
            // (codex round-2 #642). Per-pack failure just prints — it must
            // never `break :hot_reload` out and drop the game-dir watch.
            try w.print("            scripting.hot_reload.watchDirNamed(hot_reload_io, std.heap.page_allocator, \"{s}\", \"{s}\") catch {{\n", .{ pack.from_target, pack.name_prefix });
            try w.print("                scripting.hot_reload.watchDirNamed(hot_reload_io, std.heap.page_allocator, \"{s}\", \"{s}\") catch |pack_watch_err| {{\n", .{ pack.from_root, pack.name_prefix });
            try w.print("                    std.debug.print(\"labelle: pack script dir '{s}' not watched: {{s}}\\n\", .{{@errorName(pack_watch_err)}});\n", .{pack.from_root});
            try w.writeAll("                };\n");
            try w.writeAll("            };\n");
        }
        try w.writeAll("        }\n");
    }
    if (splice.transpile_emitted) {
        try w.print("        std.debug.print(\"labelle: script hot reload active — edit the generated {s}/*{s} (emitted output; re-run generate for authored-source changes) and save\\n\", .{{}});\n", .{ splice.dir, splice.extension });
    } else {
        try w.print("        std.debug.print(\"labelle: script hot reload active — edit {s}/*{s} and save\\n\", .{{}});\n", .{ splice.dir, splice.extension });
    }
    try w.writeAll("    }\n");
}

// ── Row-driven splice resolution (rev 19 §7, PRIMARY) ─────────────────

/// Normalize an extension to the leading-dot form every scan/`endsWith`
/// comparison uses (rev 19 A1: `.extensions` rows are authored dot-spelled,
/// `".rb"`). Tolerant of a dotless spelling (`"rb"`) — the dot is prepended
/// when absent — so a manifest written either way resolves and the migration
/// is forgiving. Returns an allocator-owned copy (freed via
/// `ScriptingSplice.deinit`).
fn dupDotExtension(allocator: std.mem.Allocator, ext: []const u8) ![]u8 {
    if (ext.len > 0 and ext[0] == '.') return allocator.dupe(u8, ext);
    return std.fmt.allocPrint(allocator, ".{s}", .{ext});
}

/// Build the embed splice's `resolveScriptDir` probe: the runnable embed
/// extension plus (for a transpiled row) the authoring source extension,
/// exempting declaration files — the same probe shape the pre-row code
/// inlined, shared now by the row PRIMARY path and the frozen fallback.
fn resolveEmbedScriptDir(
    allocator: std.mem.Allocator,
    game_dir: []const u8,
    language: []const u8,
    embed_ext: []const u8,
    transpile: ?TranspileSource,
) !ResolvedScriptDir {
    var ext_buf: [2][]const u8 = .{ embed_ext, undefined };
    var ext_len: usize = 1;
    var exempt: ?[]const u8 = null;
    if (transpile) |t| {
        ext_buf[1] = t.source_extension;
        ext_len = 2;
        exempt = t.declaration_suffix;
    }
    return resolveScriptDir(allocator, game_dir, language, .{
        .extensions = ext_buf[0..ext_len],
        .exempt_suffix = exempt,
    });
}

/// Resolve a splice from a manifest `.languages` row (rev 19 — the PRIMARY
/// path for every manifest carrying rows). Returns an OWNED splice (row
/// strings duped, `owner` set) or null when the row cannot drive a splice on
/// its own (empty `.extensions`, or a native row missing `.module_root`/
/// `.stage_subdir`) — the caller then falls through to the frozen table.
///
/// Derivations (rev 19 §7):
///   - EMBEDDED: `.extensions[0]` is the AUTHORED source. The registered/
///     embedded extension is `.transpile.emits` when the row transpiles
///     (authored `.ts` → embedded `.js`), else the authored extension
///     verbatim (lua/ruby: authored IS embedded) — dissolving the old
///     `EmbedLanguage.extension` / `TranspileGap.source_extension` split.
///     The declaration companion suffix (`.d.ts`) is the assembler-owned
///     transpile-codegen residue (the RFC's "honest boundary"): the row
///     does not carry it, so it is derived `".d" ++ <source>` — reproducing
///     `.d.ts` for the only transpiled language.
///   - NATIVE: `.extensions[0]` is the staged source extension; the staging
///     geometry (`.module_root`, `.stage_subdir`) rides the row (B1).
fn spliceFromRow(
    allocator: std.mem.Allocator,
    plugin_name: []const u8,
    language: []const u8,
    game_dir: []const u8,
    row: plugin_manifest.LanguageRow,
) !?ScriptingSplice {
    if (row.extensions.len == 0) return null; // malformed → frozen fallback
    const authored = row.extensions[0];

    switch (row.kind) {
        .embedded => {
            var transpile: ?TranspileSource = null;
            errdefer if (transpile) |t| {
                allocator.free(t.source_extension);
                allocator.free(t.declaration_suffix);
            };
            const embed_ext: []u8 = blk: {
                if (row.transpile) |t| {
                    const src_ext = try dupDotExtension(allocator, authored);
                    errdefer allocator.free(src_ext);
                    const decl = try std.fmt.allocPrint(allocator, ".d{s}", .{src_ext});
                    transpile = .{ .source_extension = src_ext, .declaration_suffix = decl };
                    break :blk try dupDotExtension(allocator, t.emits);
                }
                break :blk try dupDotExtension(allocator, authored);
            };
            errdefer allocator.free(embed_ext);

            const resolved = try resolveEmbedScriptDir(allocator, game_dir, language, embed_ext, transpile);
            return .{
                .plugin_name = plugin_name,
                .language = language,
                .dir = resolved.dir,
                .legacy = resolved.legacy,
                .extension = embed_ext,
                .family = .embed,
                .transpile = transpile,
                .owner = allocator,
            };
        },
        .native => {
            const module_root_src = row.module_root orelse return null;
            const stage_subdir_src = row.stage_subdir orelse return null;

            const ext = try dupDotExtension(allocator, authored);
            errdefer allocator.free(ext);
            const module_root = try allocator.dupe(u8, module_root_src);
            errdefer allocator.free(module_root);
            const stage_subdir = try allocator.dupe(u8, stage_subdir_src);
            errdefer allocator.free(stage_subdir);

            const resolved = try resolveScriptDir(allocator, game_dir, language, .{ .extensions = &.{ext} });
            return .{
                .plugin_name = plugin_name,
                .language = language,
                .dir = resolved.dir,
                .legacy = resolved.legacy,
                .extension = ext,
                .family = .native,
                .module_root = module_root,
                .stage_subdir = stage_subdir,
                .owner = allocator,
            };
        },
    }
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
                    // #692: a nested checkout under `scripts/` is another
                    // branch's tree — reporting its files as policy
                    // offenders points the user at paths that are not in
                    // the working tree. `script_scanner` already prunes
                    // these, so without the same probe here the probe and
                    // the registry disagree about what `scripts/` holds.
                    if (scanner.isRepoRoot(scripts_dir, entry.name)) continue;
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
                // #692 — see `collectMatchingFiles`'s caller.
                if (scanner.isRepoRootIo(io, dir, entry.name)) continue;
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
/// For a transpile-row language (typescript, rev 20 option (b)), an
/// authoring-extension source in `components/` (`components/hunger.ts`)
/// registers + embeds as its EMITTED twin (`components/hunger.js`): the
/// assembler transpiles the declaration dirs BEFORE the declare phase
/// (`scripting_transpile.transpileDeclDirs`), so the `.js` exists in the
/// target for both the declare tool's argv and the runtime `@embedFile`.
/// `.d.ts` declaration files are typecheck inputs, never embedded. Runnable
/// `components/*.js` embeds directly.
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
/// stems, the transpile authoring→emitted mapping (rev 20 option (b)),
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

    // Row-driven (rev 19): the authoring→embed transpile source rides the
    // splice (resolved by `detect` from the manifest row / frozen fallback),
    // not a re-lookup of the frozen table here.
    // PRIMARY: the splice's row-derived transpile source (rev 19, resolved
    // by `detect` from the manifest `.transpile` row). Frozen fallback:
    // `transpileSource(language)` (the `EMBED_LANGUAGES` table) for pins
    // predating `.transpile` rows or a manifest carrying `.declare` without
    // `.transpile` — the SAME fallback `runPhase`/`transpileDeclDirs` use,
    // so the authoring→emitted (`.ts`→`.js`) mapping stays consistent
    // across the collection and the transpile that emits it (rev 20).
    const transpile: ?TranspileSource = splice.transpile orelse transpileSource(splice.language);
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
                // #692: without this, a worktree parked under the decl
                // dir gets its scripts EMBEDDED into the shipped binary —
                // another branch's code running in the built game.
                if (scanner.isRepoRootIo(io, dir, entry.name)) continue;
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
                // The stem (rel-prefixed, extension-stripped) and the emitted
                // extension differ only for a TRANSPILE-row language: an
                // authoring `components/hunger.ts` registers + embeds as its
                // EMITTED `hunger.js` (RFC-LANGUAGE-PLUGINS rev 20 option (b) —
                // the assembler transpiles the declaration dirs BEFORE declare,
                // `scripting_transpile.transpileDeclDirs`, so the emitted `.js`
                // exists in the target for both the declare tool and the
                // runtime `@embedFile`). `.d.ts` declaration files are
                // typecheck inputs, never embeds — skipped. For a
                // non-transpile language the authored extension IS the embed
                // extension, so this collapses to the plain collection.
                var stem_ext: []const u8 = splice.extension;
                if (transpile) |t| {
                    if (std.mem.endsWith(u8, entry.name, t.declaration_suffix)) continue;
                    if (std.mem.endsWith(u8, entry.name, t.source_extension)) {
                        // A transpiled authoring source: strip the AUTHORING
                        // extension for the stem, but register/embed the
                        // EMITTED extension below.
                        stem_ext = t.source_extension;
                    } else if (!std.mem.endsWith(u8, entry.name, splice.extension)) {
                        continue;
                    }
                } else if (!std.mem.endsWith(u8, entry.name, splice.extension)) {
                    continue;
                }
                const rel_stem_len = entry.name.len - stem_ext.len;
                const stem = entry.name[0..rel_stem_len];
                const name = if (rel_prefix.len == 0)
                    try allocator.dupe(u8, stem)
                else
                    try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel_prefix, stem });
                errdefer allocator.free(name);
                // The embedded/declared file always carries the EMBED
                // extension (`.js` for typescript — the emitted twin).
                const file = if (rel_prefix.len == 0)
                    try std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ decl_dir.dirName(), stem, splice.extension })
                else
                    try std.fmt.allocPrint(allocator, "{s}/{s}/{s}{s}", .{ decl_dir.dirName(), rel_prefix, stem, splice.extension });
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
    // Row-driven (rev 19): the staging geometry rides the splice (resolved
    // by `detect` from the manifest `.languages` row / frozen fallback), not
    // a re-lookup of the frozen `NATIVE_LANGUAGES` table.
    const module_root = splice.module_root orelse return;
    const stage_subdir = splice.stage_subdir orelse return;

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
            .{ splice.dir, splice.extension, splice.language, splice.dir, splice.dir, module_root },
        );
        return error.NativeScriptDirEmpty;
    }

    var has_module_root = false;
    for (rel_paths.items) |rel| {
        if (std.mem.eql(u8, rel, module_root)) has_module_root = true;
    }
    if (!has_module_root) {
        std.debug.print(
            "labelle-assembler: {s}/ has {s} sources but no {s}/{s} — the file that becomes " ++
                "the plugin crate's game-module root ({s}/{s}).\n" ++
                "  declare your scripts there; its `pub fn register(...)` composes them.\n",
            .{ splice.dir, splice.extension, splice.dir, module_root, stage_subdir, module_root },
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

    // Self-describing crate-layout gate (rev 19 B2): the `.native` row
    // DECLARING `.stage_subdir` is the pinned manifest's CLAIM to ship that
    // crate, so a missing crate parent is a plugin-PACKAGING error naming the
    // pin — no version compare (symmetric with rev 17's missing-`.declare`-
    // tool handling). Fail here with the fix rather than letting cargo fail
    // against a half-staged package.
    const stage_parent = std.fs.path.dirname(stage_subdir).?;
    const parent_path = try std.fs.path.join(allocator, &.{ staged_pkg, stage_parent });
    defer allocator.free(parent_path);
    if (!cache.dirExists(parent_path)) {
        std.debug.print(
            "labelle-assembler: the pinned scripting plugin's \"{s}\" language row declares " ++
                ".stage_subdir = \"{s}\", but its package ships no {s}/ crate to stage into — " ++
                "a plugin-packaging error.\n" ++
                "  pin a labelle-scripting version whose package ships {s}/.\n",
            .{ splice.language, stage_subdir, stage_parent, stage_subdir },
        );
        return error.NativeCrateLayoutMissing;
    }

    // Place the LIVE link (module doc): linkDirAbs reconciles whatever is
    // at the destination — the shipped placeholder dir (hardlinked files
    // unlinked, cache bytes untouched), a stale link, or the correct link
    // (no-op) — then links the game dir so edits flow through without a
    // re-generate, matching the embed script dirs' linkAndScan layout.
    const dest_root = try std.fs.path.join(allocator, &.{ staged_pkg, stage_subdir });
    defer allocator.free(dest_root);
    try scanner.linkDirAbs(allocator, src_dir_path, dest_root);
}

// ── C# dev `.csproj` for IDE support (labelle-assembler#617) ──────────

/// Emit a dev `.csproj` into the game root for a csharp game: a first-class C#
/// project the author opens in Visual Studio / Rider / VS Code for IntelliSense
/// + build-in-place over the game's `scripts/` + `components/` + `events/` C#
/// sources, referencing the shipped Labelle surface
/// (native-csharp/src/{Labelle,Glue,Declare}.cs) from the resolved plugin
/// package `plugin_src_dir`. It is NOT the build path — the real build is
/// `labelle generate` → the plugin's `.language_builds` `dotnet publish` step
/// (the assembler stages `scripts/` over the plugin crate and hostfxr loads the
/// emitted managed .dll). This is a regenerated dev aid so the author edits the
/// files they ship, with full IntelliSense. Only the `Labelle.cs`/`Glue.cs`/
/// `Declare.cs` surface (never the `src/game` placeholder) is referenced, so
/// the game's own `scripts/Game.cs` is the sole `Game.Register`.
pub fn emitCsharpDevProject(
    allocator: std.mem.Allocator,
    game_dir: []const u8,
    project_name: []const u8,
    plugin_src_dir: []const u8,
) !void {
    const io = config.globalIo();

    // The csproj lives in the game root; the surface refs are relative to it,
    // '/'-separated (MSBuild accepts '/' on every OS — portable output).
    const rel_raw = try std.fs.path.relative(allocator, "", null, game_dir, plugin_src_dir);
    defer allocator.free(rel_raw);
    const rel = try allocator.dupe(u8, rel_raw);
    defer allocator.free(rel);
    for (rel) |*c| {
        if (c.* == '\\') c.* = '/';
    }

    const body = try renderCsharpDevProject(allocator, rel);
    defer allocator.free(body);

    const name = try std.fmt.allocPrint(allocator, "{s}.csproj", .{project_name});
    defer allocator.free(name);
    const path = try std.fs.path.join(allocator, &.{ game_dir, name });
    defer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body });
}

/// The dev `.csproj` bytes (see `emitCsharpDevProject`). `plugin_src_rel` is the
/// game-root-relative, '/'-separated path to the plugin's `native-csharp/src`.
/// Split out for a hermetic byte test.
pub fn renderCsharpDevProject(
    allocator: std.mem.Allocator,
    plugin_src_rel: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\<Project Sdk="Microsoft.NET.Sdk">
        \\
        \\  <!--
        \\    GENERATED by `labelle generate` (labelle-assembler#617). A dev-only C#
        \\    project for IDE IntelliSense + build-in-place: open it (or the game
        \\    folder) in Visual Studio / Rider / VS Code to edit scripts/, components/
        \\    and events/ with full completion against the Labelle scripting surface.
        \\    It is NOT the build path — `labelle generate` stages scripts/ over the
        \\    scripting plugin's native-csharp crate and its `.language_builds`
        \\    `dotnet publish` step emits the managed assembly the game loads through
        \\    hostfxr. Regenerated each generate; do not hand-edit.
        \\  -->
        \\  <PropertyGroup>
        \\    <TargetFramework>net7.0</TargetFramework>
        \\    <Nullable>enable</Nullable>
        \\    <ImplicitUsings>enable</ImplicitUsings>
        \\    <LangVersion>latest</LangVersion>
        \\    <AllowUnsafeBlocks>true</AllowUnsafeBlocks>
        \\    <EnableDynamicLoading>true</EnableDynamicLoading>
        \\    <AssemblyName>labelle_csharp_scripts</AssemblyName>
        \\    <RootNamespace>Labelle</RootNamespace>
        \\    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
        \\    <NoWarn>$(NoWarn);CA2255</NoWarn>
        \\  </PropertyGroup>
        \\
        \\  <ItemGroup>
        \\    <!-- The game's C# sources, edited in place. -->
        \\    <Compile Include="scripts/**/*.cs" />
        \\    <Compile Include="components/**/*.cs" />
        \\    <Compile Include="events/**/*.cs" />
        \\    <!-- The shipped Labelle scripting surface (resolved plugin package). -->
        \\    <Compile Include="{[rel]s}/Labelle.cs" Link="Labelle/Labelle.cs" />
        \\    <Compile Include="{[rel]s}/Glue.cs" Link="Labelle/Glue.cs" />
        \\    <Compile Include="{[rel]s}/Declare.cs" Link="Labelle/Declare.cs" />
        \\  </ItemGroup>
        \\
        \\</Project>
        \\
    , .{ .rel = plugin_src_rel });
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
                // #692: another branch's `.rs`/`.cs` sources must not
                // join the native module's source set.
                if (scanner.isRepoRootIo(io, dir, entry.name)) continue;
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

// ── Row-driven PRIMARY path (rev 19 §7): detect reads `.languages` ────

test "detect (PRIMARY): a `.languages` embedded row drives the splice — derived embed ext, owner set, leading-dot spelling" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A manifest carrying a `.languages` ruby row (dot-spelled `.extensions`,
    // A1) — the row, not the frozen table, resolves the splice.
    try writeTestFile(tmp.dir, "plugins/scripting/plugin.labelle",
        \\.{ .name = "scripting", .manifest_version = 1,
        \\   .languages = .{
        \\     .{ .name = "ruby", .extensions = .{".rb"}, .kind = .embedded,
        \\        .declare = .{ .tool = "labelle-declare-ruby", .dir = "tools/declare-ruby", .events = true } },
        \\   } }
    );
    const project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(project_dir);

    const plugins = [_]config.PluginDep{
        .{ .name = "scripting", .repo = "local:plugins/scripting", .params = .{ .language = "ruby" } },
    };
    var splice = (try detect(allocator, &plugins, project_dir)).?;
    defer splice.deinit();
    try testing.expect(splice.owner != null); // row-derived strings are owned
    try testing.expectEqualStrings("ruby", splice.language);
    try testing.expectEqual(Family.embed, splice.family);
    // Non-transpiled embed: the authored `.extensions[0]` IS the embed ext.
    try testing.expectEqualStrings(".rb", splice.extension);
    try testing.expect(splice.transpile == null);
    try testing.expect(splice.module_root == null);
}

test "detect (PRIMARY): a transpiled embedded row derives the embed ext from `.transpile.emits` (authored .ts → embedded .js)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // `.emits` is dotless in the sketch/manifest ("js"); the derivation
    // normalizes it to the leading-dot embed extension the scan uses.
    try writeTestFile(tmp.dir, "plugins/scripting/plugin.labelle",
        \\.{ .name = "scripting", .manifest_version = 1,
        \\   .languages = .{
        \\     .{ .name = "typescript", .extensions = .{".ts"}, .kind = .embedded,
        \\        .transpile = .{ .emits = "js", .toolchain = "tsc", .version = "7.0.2",
        \\                        .fetch_url = "https://example.invalid/{platform}-{version}.tgz" } },
        \\   } }
    );
    const project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(project_dir);

    const plugins = [_]config.PluginDep{
        .{ .name = "scripting", .repo = "local:plugins/scripting", .params = .{ .language = "typescript" } },
    };
    var splice = (try detect(allocator, &plugins, project_dir)).?;
    defer splice.deinit();
    try testing.expectEqual(Family.embed, splice.family);
    // Embed ext = `.transpile.emits`, dot-normalized.
    try testing.expectEqualStrings(".js", splice.extension);
    // The authoring source rides the splice: `.ts` authored, `.d.ts`
    // declaration companion derived (`.d` ++ source).
    const t = splice.transpile.?;
    try testing.expectEqualStrings(".ts", t.source_extension);
    try testing.expectEqualStrings(".d.ts", t.declaration_suffix);
}

test "detect (PRIMARY): a native row carries the staging geometry (.module_root + .stage_subdir, rev 19 B1)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "plugins/scripting/plugin.labelle",
        \\.{ .name = "scripting", .manifest_version = 1,
        \\   .languages = .{
        \\     .{ .name = "rust", .extensions = .{".rs"}, .kind = .native,
        \\        .module_root = "mod.rs", .stage_subdir = "native/src/game",
        \\        .declare = .{ .tool = "labelle-declare-rs", .dir = "tools/declare-rs", .events = true } },
        \\   } }
    );
    const project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(project_dir);

    const plugins = [_]config.PluginDep{
        .{ .name = "scripting", .repo = "local:plugins/scripting", .params = .{ .language = "rust" } },
    };
    var splice = (try detect(allocator, &plugins, project_dir)).?;
    defer splice.deinit();
    try testing.expectEqual(Family.native, splice.family);
    try testing.expectEqualStrings(".rs", splice.extension);
    try testing.expectEqualStrings("mod.rs", splice.module_root.?);
    try testing.expectEqualStrings("native/src/game", splice.stage_subdir.?);
    try testing.expect(splice.transpile == null);
}

test "detect (PRIMARY): dotless `.extensions` is tolerated — the derivation normalizes to leading-dot" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The pre-A1 dotless spelling ("lua") still resolves — `dupDotExtension`
    // prepends the dot, so the migration is forgiving.
    try writeTestFile(tmp.dir, "plugins/scripting/plugin.labelle",
        \\.{ .name = "scripting", .manifest_version = 1,
        \\   .languages = .{
        \\     .{ .name = "lua", .extensions = .{"lua"}, .kind = .embedded },
        \\   } }
    );
    const project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(project_dir);

    const plugins = [_]config.PluginDep{
        .{ .name = "scripting", .repo = "local:plugins/scripting", .params = .{ .language = "lua" } },
    };
    var splice = (try detect(allocator, &plugins, project_dir)).?;
    defer splice.deinit();
    try testing.expectEqualStrings(".lua", splice.extension);
}

test "detect (FALLBACK): a native row missing `.stage_subdir` falls through to the frozen table" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // An incomplete native row (no `.stage_subdir`) cannot drive staging on
    // its own → `spliceFromRow` returns null and detect falls through to the
    // frozen `NATIVE_LANGUAGES` table, which covers rust.
    try writeTestFile(tmp.dir, "plugins/scripting/plugin.labelle",
        \\.{ .name = "scripting", .manifest_version = 1,
        \\   .languages = .{
        \\     .{ .name = "rust", .extensions = .{".rs"}, .kind = .native, .module_root = "mod.rs" },
        \\   } }
    );
    const project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(project_dir);

    const plugins = [_]config.PluginDep{
        .{ .name = "scripting", .repo = "local:plugins/scripting", .params = .{ .language = "rust" } },
    };
    var splice = (try detect(allocator, &plugins, project_dir)).?;
    defer splice.deinit();
    try testing.expectEqual(Family.native, splice.family);
    // Frozen fallback → static strings (owner null), rust's frozen geometry.
    try testing.expect(splice.owner == null);
    try testing.expectEqualStrings("native/src/game", splice.stage_subdir.?);
    try testing.expectEqualStrings("mod.rs", splice.module_root.?);
}

// ── the typescript fixtures (transpile phase re-scan seam, #745) ─────

const ts_splice_fixture = ScriptingSplice{
    .plugin_name = "scripting",
    .language = "typescript",
    .dir = "scripts",
    .extension = ".js",
    // rev 19: the transpile source rides the splice — `collectDeclEmbeds`
    // reads it here (was a frozen-table lookup) to map `.ts` authoring
    // sources in components/events dirs to their emitted `.js` twin (rev 20
    // option (b)); `.d.ts` declaration files are skipped.
    .transpile = .{ .source_extension = ".ts", .declaration_suffix = ".d.ts" },
};

/// The grace-fallback twin: detect resolved the deprecated ts/ dir.
const ts_legacy_splice_fixture = ScriptingSplice{
    .plugin_name = "scripting",
    .language = "typescript",
    .dir = "ts",
    .legacy = true,
    .extension = ".js",
    .transpile = .{ .source_extension = ".ts", .declaration_suffix = ".d.ts" },
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

test "collectComponentEmbeds: a typescript authoring .ts registers as its emitted .js; runnable .js and .d.ts handled" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Runnable .js + a declaration file: the .js embeds like any
    // component-dir language file; the .d.ts is a typecheck input, never a
    // script anywhere.
    try writeTestFile(tmp.dir, "components/glue.js", "export const GLUE = 1;\n");
    try writeTestFile(tmp.dir, "components/labelle.d.ts", "declare const labelle: any;\n");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);

    const embeds = try collectComponentEmbeds(allocator, root, ts_splice_fixture);
    defer freeEmbedScripts(allocator, embeds);
    try testing.expectEqual(@as(usize, 1), embeds.len);
    try testing.expectEqualStrings("glue", embeds[0].name);
    try testing.expectEqualStrings("components/glue.js", embeds[0].file);

    // An authoring .ts source registers + embeds as its EMITTED .js twin
    // (RFC-LANGUAGE-PLUGINS rev 20 option (b): the transpile-decl phase
    // emits it into the target for both the declare tool and @embedFile).
    try writeTestFile(tmp.dir, "components/shape.ts", "export const Shape = labelle.component(\"Shape\", { w: 1.0 });\n");
    const embeds2 = try collectComponentEmbeds(allocator, root, ts_splice_fixture);
    defer freeEmbedScripts(allocator, embeds2);
    try testing.expectEqual(@as(usize, 2), embeds2.len);
    // Alphabetical by target-relative file: components/glue.js < components/shape.js.
    try testing.expectEqualStrings("glue", embeds2[0].name);
    try testing.expectEqualStrings("components/glue.js", embeds2[0].file);
    try testing.expectEqualStrings("shape", embeds2[1].name);
    try testing.expectEqualStrings("components/shape.js", embeds2[1].file);

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
    // rev 19: the staging geometry rides the splice — `stageNativeSources`
    // reads these here (was a frozen `NATIVE_LANGUAGES` lookup).
    .module_root = "mod.rs",
    .stage_subdir = "native/src/game",
};

/// The grace-fallback twin: detect resolved the deprecated rust/ dir.
const rust_legacy_splice_fixture = ScriptingSplice{
    .plugin_name = "scripting",
    .language = "rust",
    .dir = "rust",
    .legacy = true,
    .extension = ".rs",
    .family = .native,
    .module_root = "mod.rs",
    .stage_subdir = "native/src/game",
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

    // The placement is the linkAndScan primitive: a LINK, not a copy, so an
    // edit reaches the staged crate without re-staging — asserted below.
    // Its text is relative where the platform can express that (surviving a
    // project move), which Windows without symlink privileges cannot: it
    // gets a junction, and a junction stores an NT path with no relative
    // form (#710). Same pin as the scanner_symlink suite for embed dirs.
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link_len = try fx.tmp.dir.readLink(testing.io, "out/deps/labelle-scripting/native/src/game", &link_buf);
    if (@import("builtin").os.tag != .windows) {
        try testing.expect(!std.fs.path.isAbsolute(link_buf[0..link_len]));
    }

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

test "collectEventEmbeds: a typescript authoring .ts registers as its emitted .js; .d.ts exempt" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "events/labelle.d.ts", "declare const labelle: any;\n");
    try writeTestFile(tmp.dir, "events/hit.ts", "export const Hit = labelle.event(\"hit\", { damage: 1.0 });\n");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);

    // The authoring .ts registers + embeds as its EMITTED .js twin (rev 20
    // option (b)); the .d.ts is a typecheck input, never embedded.
    const embeds = try collectEventEmbeds(allocator, root, ts_splice_fixture);
    defer freeEmbedScripts(allocator, embeds);
    try testing.expectEqual(@as(usize, 1), embeds.len);
    try testing.expectEqualStrings("hit", embeds[0].name);
    try testing.expectEqualStrings("events/hit.js", embeds[0].file);
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

test "renderCsharpDevProject: globs the in-place convention dirs + refs the resolved Labelle surface" {
    const allocator = testing.allocator;
    const body = try renderCsharpDevProject(allocator, "../../native-csharp/src");
    defer allocator.free(body);

    // The author's in-place sources are game-root-relative globs.
    try testing.expect(std.mem.indexOf(u8, body, "<Compile Include=\"scripts/**/*.cs\" />") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<Compile Include=\"components/**/*.cs\" />") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<Compile Include=\"events/**/*.cs\" />") != null);
    // The three Labelle surface files, from the resolved plugin package — and
    // NOT the src/game placeholder (only the game's own scripts/Game.cs backs
    // Game.Register).
    try testing.expect(std.mem.indexOf(u8, body, "../../native-csharp/src/Labelle.cs\" Link=\"Labelle/Labelle.cs\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "../../native-csharp/src/Glue.cs\" Link=\"Labelle/Glue.cs\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "../../native-csharp/src/Declare.cs\" Link=\"Labelle/Declare.cs\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "src/game") == null);
    // Unsafe P/Invoke in Glue.cs + hostfxr dynamic-load config must be on for
    // the project to build.
    try testing.expect(std.mem.indexOf(u8, body, "<AllowUnsafeBlocks>true</AllowUnsafeBlocks>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<EnableDynamicLoading>true</EnableDynamicLoading>") != null);
}

// ── Dev-mode hot reload (labelle-assembler#637) — probe + gate tests ──

test "probeHotReloadAt: true only when the package build.zig DECLARES the hot_reload option" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // v0.12.0 shape: the multi-line option declaration is present.
    try writeTestFile(tmp.dir, "capable/build.zig",
        \\const hot_reload = b.option(
        \\    bool,
        \\    "hot_reload",
        \\    "dev-mode script hot reload",
        \\) orelse false;
    );
    // Pre-v0.12.0 shape: a build.zig without the option — an unquoted
    // comment mention must NOT count (it would re-open the unknown-dep-
    // option hard error the probe exists to prevent).
    try writeTestFile(tmp.dir, "older/build.zig",
        \\// TODO: hot_reload support lands in a later release
        \\const language = b.option([]const u8, "language", "…");
    );
    // The codex-P2 shape (PR #638): a QUOTED mention outside a declaration
    // — comment or diagnostic string — must not flip capability on either.
    try writeTestFile(tmp.dir, "mention/build.zig",
        \\// mentions "hot_reload" in a comment
        \\const msg = "pass \"hot_reload\" once the plugin supports it";
        \\const language = b.option([]const u8, "language", "…");
    );
    // The round-3 shape: a COMMENTED-OUT sample of the real declaration —
    // the raw text has the exact live shape, so only comment-blanking
    // keeps it incapable.
    try writeTestFile(tmp.dir, "commented/build.zig",
        \\// const hot_reload = b.option(bool, "hot_reload", "dev-mode script hot reload") orelse false;
        \\const language = b.option([]const u8, "language", "…");
    );

    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);
    const capable = try std.fs.path.join(allocator, &.{ root, "capable" });
    defer allocator.free(capable);
    const older = try std.fs.path.join(allocator, &.{ root, "older" });
    defer allocator.free(older);
    const mention = try std.fs.path.join(allocator, &.{ root, "mention" });
    defer allocator.free(mention);
    const commented = try std.fs.path.join(allocator, &.{ root, "commented" });
    defer allocator.free(commented);
    const missing = try std.fs.path.join(allocator, &.{ root, "no-such-plugin" });
    defer allocator.free(missing);

    try testing.expect(probeHotReloadAt(allocator, capable));
    try testing.expect(!probeHotReloadAt(allocator, older));
    try testing.expect(!probeHotReloadAt(allocator, mention));
    try testing.expect(!probeHotReloadAt(allocator, commented));
    // Resolution/read failures degrade to false, never error.
    try testing.expect(!probeHotReloadAt(allocator, missing));
}

test "containsHotReloadOptionDecl: declaration forms match; non-declaration spellings never do" {
    // Single-line and multi-line declarations, any receiver name.
    try testing.expect(containsHotReloadOptionDecl(
        "const hot_reload = b.option(bool, \"hot_reload\", \"…\") orelse false;",
    ));
    try testing.expect(containsHotReloadOptionDecl(
        "const hot_reload = builder.option(\n    bool,\n    \"hot_reload\",\n    \"…\",\n) orelse false;",
    ));
    // A quoted mention with no declaration shape around it.
    try testing.expect(!containsHotReloadOptionDecl(
        "// the \"hot_reload\" option is not declared here",
    ));
    // A declaration of a DIFFERENT type/name never matches.
    try testing.expect(!containsHotReloadOptionDecl(
        "const x = b.option([]const u8, \"hot_reload\", \"…\");",
    ));
    try testing.expect(!containsHotReloadOptionDecl(
        "const x = b.option(bool, \"hot_reload_extra\", \"…\");",
    ));
    // …and `"hot_reload_extra"` starts with the quoted name — make sure the
    // exact-name positive still holds beside it in one source.
    try testing.expect(containsHotReloadOptionDecl(
        "const a = b.option(bool, \"hot_reload_extra\", \"…\");\n" ++
            "const b_ = b.option(bool, \"hot_reload\", \"…\");",
    ));
}

test "detect: a local scripting plugin with the hot_reload option probes capable; one without stays incapable" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "plugins/scripting/plugin.labelle",
        \\.{ .name = "scripting", .manifest_version = 1 }
    );
    try writeTestFile(tmp.dir, "plugins/scripting/build.zig",
        \\const hot_reload = b.option(bool, "hot_reload", "…") orelse false;
    );
    const project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(project_dir);

    const plugins = [_]config.PluginDep{
        .{ .name = "scripting", .repo = "local:plugins/scripting", .params = .{ .language = "lua" } },
    };
    const splice = (try detect(allocator, &plugins, project_dir)).?;
    try testing.expect(splice.hot_reload_capable);

    // Remove the option → the same detect resolves incapable.
    try writeTestFile(tmp.dir, "plugins/scripting/build.zig",
        \\const language = b.option([]const u8, "language", "…");
    );
    const splice_old = (try detect(allocator, &plugins, project_dir)).?;
    try testing.expect(!splice_old.hot_reload_capable);
}

test "buildDepHotReload: embed+capable+exe+desktop only — tests target, native, non-desktop and incapable all pin false" {
    const capable = ScriptingSplice{
        .plugin_name = "scripting",
        .language = "ruby",
        .dir = "scripts",
        .extension = ".rb",
        .hot_reload_capable = true,
    };
    try testing.expect(buildDepHotReload(capable, false, .desktop));
    // The tests target NEVER compiles the watcher in — the explicit pin,
    // like testsTargetConfig's gamepad/backend overrides (assembler#627).
    try testing.expect(!buildDepHotReload(capable, true, .desktop));
    // Non-desktop platforms have no editable source tree beside the binary.
    try testing.expect(!buildDepHotReload(capable, false, .android));
    try testing.expect(!buildDepHotReload(capable, false, .wasm));

    var incapable = capable;
    incapable.hot_reload_capable = false;
    try testing.expect(!buildDepHotReload(incapable, false, .desktop));

    var native = capable;
    native.family = .native;
    try testing.expect(!buildDepHotReload(native, false, .desktop));

    // The deprecated legacy per-language dir never gets hot reload: its
    // recursive subdir-joined stems (`ai/guard`) can't match the plugin's
    // flat-dir watcher reports (codex P2, PR #638).
    var legacy = capable;
    legacy.legacy = true;
    try testing.expect(!buildDepHotReload(legacy, false, .desktop));
}

test "emitHotReloadWatch: capable embed splice emits the Debug-gated source-tree watch with the cwd fallback" {
    const allocator = testing.allocator;
    const splice = ScriptingSplice{
        .plugin_name = "scripting",
        .language = "ruby",
        .dir = "scripts",
        .extension = ".rb",
        .hot_reload_capable = true,
        .watch_dir_from_target = "../../scripts",
    };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try emitHotReloadWatch(&aw.writer, splice);
    const out = aw.written();

    // The double comptime gate: Debug-only + @hasDecl version probe.
    try testing.expect(std.mem.indexOf(u8, out, "if (comptime (@import(\"builtin\").mode == .Debug and @hasDecl(scripting, \"hot_reload\")))") != null);
    // Primary: the SOURCE tree relative to the target dir (the game's cwd
    // under `labelle run`), then the project-root-relative fallback.
    const primary = std.mem.indexOf(u8, out, "scripting.hot_reload.watchDir(hot_reload_io, std.heap.page_allocator, \"../../scripts\") catch {").?;
    const fallback = std.mem.indexOf(u8, out, "scripting.hot_reload.watchDir(hot_reload_io, std.heap.page_allocator, \"scripts\") catch |watch_err| {").?;
    try testing.expect(primary < fallback);
    // Failure degrades (never takes the game down), success announces.
    try testing.expect(std.mem.indexOf(u8, out, "script hot reload disabled") != null);
    try testing.expect(std.mem.indexOf(u8, out, "script hot reload active — edit scripts/*.rb and save") != null);
}

test "emitHotReloadWatch: no relative path → single cwd-relative watch; incapable/native splices emit nothing" {
    const allocator = testing.allocator;

    var no_rel = ScriptingSplice{
        .plugin_name = "scripting",
        .language = "lua",
        .dir = "scripts",
        .extension = ".lua",
        .hot_reload_capable = true,
    };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try emitHotReloadWatch(&aw.writer, no_rel);
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "scripting.hot_reload.watchDir(hot_reload_io, std.heap.page_allocator, \"scripts\") catch |watch_err| {") != null);
    // Exactly one watchDir call — no fallback nesting without a primary.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "watchDir"));

    var aw2: std.Io.Writer.Allocating = .init(allocator);
    defer aw2.deinit();
    no_rel.hot_reload_capable = false;
    try emitHotReloadWatch(&aw2.writer, no_rel);
    try testing.expectEqual(@as(usize, 0), aw2.written().len);

    var aw3: std.Io.Writer.Allocating = .init(allocator);
    defer aw3.deinit();
    no_rel.hot_reload_capable = true;
    no_rel.family = .native;
    try emitHotReloadWatch(&aw3.writer, no_rel);
    try testing.expectEqual(@as(usize, 0), aw3.written().len);
}

test "emitHotReloadWatch: a LEGACY-dir splice emits nothing even when capable (codex P2, PR #638)" {
    const allocator = testing.allocator;
    const legacy = ScriptingSplice{
        .plugin_name = "scripting",
        .language = "lua",
        .dir = "lua",
        .legacy = true,
        .extension = ".lua",
        .hot_reload_capable = true,
    };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try emitHotReloadWatch(&aw.writer, legacy);
    try testing.expectEqual(@as(usize, 0), aw.written().len);
}

test "emitHotReloadWatch: a TRANSPILED splice watches the target's own emitted dir, never a source-relative path (codex P1, PR #638)" {
    const allocator = testing.allocator;
    const ts = ScriptingSplice{
        .plugin_name = "scripting",
        .language = "typescript",
        .dir = "scripts",
        .extension = ".js",
        .hot_reload_capable = true,
        .transpile = .{ .source_extension = ".ts", .declaration_suffix = ".d.ts" },
        // Output really materialized this generate (root.zig's runPhase
        // seam) — THE discriminator (round 3): a transpile ROW alone means
        // nothing, a js-only project keeps the source watch.
        .transpile_emitted = true,
        // Even a (mistakenly) computed source-relative path must be ignored:
        // the watcher filters `.js` and the runnable output lives in the
        // TARGET's materialized dir, not the source tree.
        .watch_dir_from_target = "../../scripts",
    };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try emitHotReloadWatch(&aw.writer, ts);
    const out = aw.written();

    // Single watch of the cwd-relative target dir (cwd = the target).
    try testing.expect(std.mem.indexOf(u8, out, "scripting.hot_reload.watchDir(hot_reload_io, std.heap.page_allocator, \"scripts\") catch |watch_err| {") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "watchDir"));
    try testing.expect(std.mem.indexOf(u8, out, "../../scripts") == null);
    // The v1-limitation messaging: live-edit the emitted output.
    try testing.expect(std.mem.indexOf(u8, out, "edit the generated scripts/*.js (emitted output; re-run generate for authored-source changes) and save") != null);
    try testing.expect(std.mem.indexOf(u8, out, "TRANSPILED") != null);
}

test "emitHotReloadWatch: local pack dirs emit namespaced dual candidates inside the multi-root gate, after the game watch (#51/#642)" {
    const allocator = testing.allocator;
    const splice = ScriptingSplice{
        .plugin_name = "scripting",
        .language = "ruby",
        .dir = "scripts",
        .extension = ".rb",
        .hot_reload_capable = true,
        .watch_dir_from_target = "../../scripts",
        .pack_watch_dirs = &.{
            .{ .from_target = "../../packs/sky/scripts", .from_root = "packs/sky/scripts", .name_prefix = "sky__" },
            .{ .from_target = "../../libs/colony/scripts", .from_root = "libs/colony/scripts", .name_prefix = "colony__" },
        },
    };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try emitHotReloadWatch(&aw.writer, splice);
    const out = aw.written();

    // The pack watches sit INSIDE their own comptime multi-root gate, keyed
    // on `watchDirNamed` (the multi-root + namespaced-reload surface) — an
    // OLD single-slot plugin lacks it, folding them out entirely so it never
    // sees a second watch call that would clobber the game-dir watch.
    const gate = std.mem.indexOf(u8, out, "if (comptime @hasDecl(scripting.hot_reload, \"watchDirNamed\"))").?;
    // Dual candidate per pack (coderabbit #642), each a `watchDirNamed`
    // under the pack's `<pack>__` reload prefix (codex round-2 #642) so the
    // reload keys onto the pack's namespaced registration.
    const sky_primary = std.mem.indexOf(u8, out, "scripting.hot_reload.watchDirNamed(hot_reload_io, std.heap.page_allocator, \"../../packs/sky/scripts\", \"sky__\") catch {").?;
    const sky_fallback = std.mem.indexOf(u8, out, "scripting.hot_reload.watchDirNamed(hot_reload_io, std.heap.page_allocator, \"packs/sky/scripts\", \"sky__\") catch |pack_watch_err| {").?;
    const colony_primary = std.mem.indexOf(u8, out, "scripting.hot_reload.watchDirNamed(hot_reload_io, std.heap.page_allocator, \"../../libs/colony/scripts\", \"colony__\") catch {").?;
    const colony_fallback = std.mem.indexOf(u8, out, "scripting.hot_reload.watchDirNamed(hot_reload_io, std.heap.page_allocator, \"libs/colony/scripts\", \"colony__\") catch |pack_watch_err| {").?;
    // Game dir watched FIRST (plain watchDir, primary + fallback), then
    // each pack's namespaced primary before its fallback, inside the gate.
    const game_primary = std.mem.indexOf(u8, out, "scripting.hot_reload.watchDir(hot_reload_io, std.heap.page_allocator, \"../../scripts\") catch {").?;
    try testing.expect(game_primary < gate);
    try testing.expect(gate < sky_primary and sky_primary < sky_fallback);
    try testing.expect(sky_fallback < colony_primary and colony_primary < colony_fallback);
    try testing.expect(std.mem.indexOf(u8, out, "not watched") != null);
    // Per-pack failure degrades: the last `break :hot_reload` is the game
    // watch's own fallback, BEFORE the gate — no pack path breaks out.
    try testing.expect(std.mem.lastIndexOf(u8, out, "break :hot_reload;").? < gate);
    // 2 game watches (plain watchDir) + 4 namespaced pack watches.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, ".watchDir(hot_reload_io"));
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, out, ".watchDirNamed(hot_reload_io"));
}

test "emitHotReloadWatch: no pack dirs -> no gate; transpile-emitted ignores pack dirs (#51)" {
    const allocator = testing.allocator;

    // No local packs (the published/cached-only shape — root.zig collects
    // nothing for them): the emission is byte-identical to the pre-#51
    // single-watch shape, no multi-root gate at all.
    const no_packs = ScriptingSplice{
        .plugin_name = "scripting",
        .language = "lua",
        .dir = "scripts",
        .extension = ".lua",
        .hot_reload_capable = true,
    };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try emitHotReloadWatch(&aw.writer, no_packs);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "watchDirNamed") == null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, aw.written(), ".watchDir(hot_reload_io"));

    // Transpile-emitted: pack sources are authored `.ts` the `.js` watcher
    // can never match — pack dirs must NOT emit even when computed.
    var ts = no_packs;
    ts.language = "typescript";
    ts.extension = ".js";
    ts.transpile = .{ .source_extension = ".ts", .declaration_suffix = ".d.ts" };
    ts.transpile_emitted = true;
    ts.pack_watch_dirs = &.{.{ .from_target = "../../packs/sky/scripts", .from_root = "packs/sky/scripts", .name_prefix = "sky__" }};
    var aw2: std.Io.Writer.Allocating = .init(allocator);
    defer aw2.deinit();
    try emitHotReloadWatch(&aw2.writer, ts);
    try testing.expect(std.mem.indexOf(u8, aw2.written(), "packs/sky") == null);
    try testing.expect(std.mem.indexOf(u8, aw2.written(), "watchDirNamed") == null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, aw2.written(), ".watchDir(hot_reload_io"));

    // And the incapable/native/legacy no-emission shapes hold with pack
    // dirs set (the existing gates run first).
    var incapable = no_packs;
    incapable.hot_reload_capable = false;
    incapable.pack_watch_dirs = &.{.{ .from_target = "../../packs/sky/scripts", .from_root = "packs/sky/scripts", .name_prefix = "sky__" }};
    var aw3: std.Io.Writer.Allocating = .init(allocator);
    defer aw3.deinit();
    try emitHotReloadWatch(&aw3.writer, incapable);
    try testing.expectEqual(@as(usize, 0), aw3.written().len);
}

test "packWatchDirs: scripts/ present -> dual target/root-relative paths + namespace; absent -> null (#51/#642)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "game/.labelle/desktop");
    try tmp.dir.createDirPath(testing.io, "game/libs/sky/scripts");
    try tmp.dir.createDirPath(testing.io, "game/libs/bare"); // no scripts/

    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);
    const game_dir = try std.fs.path.join(allocator, &.{ root, "game" });
    defer allocator.free(game_dir);
    const target_dir = try std.fs.path.join(allocator, &.{ root, "game", ".labelle", "desktop" });
    defer allocator.free(target_dir);
    const sky = try std.fs.path.join(allocator, &.{ root, "game", "libs", "sky" });
    defer allocator.free(sky);
    const bare = try std.fs.path.join(allocator, &.{ root, "game", "libs", "bare" });
    defer allocator.free(bare);

    const pair = (try packWatchDirs(allocator, game_dir, target_dir, sky, "sky__")).?;
    defer allocator.free(pair.from_target);
    defer allocator.free(pair.from_root);
    defer allocator.free(pair.name_prefix);
    // Primary is relative to the target dir (cwd under `labelle run`);
    // fallback is relative to the project root (a root-launched binary);
    // the namespace is carried through for the emitted watchDirNamed.
    try testing.expectEqualStrings("../../libs/sky/scripts", pair.from_target);
    try testing.expectEqualStrings("libs/sky/scripts", pair.from_root);
    try testing.expectEqualStrings("sky__", pair.name_prefix);
    // No scripts/ dir -> nothing to watch.
    try testing.expectEqual(@as(?PackWatchDir, null), try packWatchDirs(allocator, game_dir, target_dir, bare, "bare__"));
}

test "packHasRegisteredScript: matches only packs contributing a registered embed (#642)" {
    const scripts = [_]EmbedScript{
        .{ .name = "spawner", .file = "scripts/10_spawner.rb" },
        .{ .name = "count", .file = "packs/sky/scripts/10_count.rb" },
        .{ .name = "hunger", .file = "components/hunger.rb" },
    };
    // A pack with a registered embed script matches; one with none (its
    // scripts were never collected into the registered set) does not — so
    // it gets no watch (codex P2 #642).
    try testing.expect(packHasRegisteredScript(&scripts, "sky"));
    try testing.expect(!packHasRegisteredScript(&scripts, "colony"));
    // A prefix that is not a full pack-dir segment must not false-match
    // (`packs/sk/` vs `packs/sky/`).
    try testing.expect(!packHasRegisteredScript(&scripts, "sk"));
    try testing.expect(!packHasRegisteredScript(&.{}, "sky"));
}

test "blankCommentsForProbe: comments blank, string-embedded // survives, multiline-string lines blank" {
    const allocator = testing.allocator;

    // A commented-out declaration blanks away; a live one on a later line
    // survives — including one PRECEDED by a string literal containing
    // `//` (the URL shape), which must not truncate the line.
    const src =
        "// const hot_reload = b.option(bool, \"hot_reload\", \"…\") orelse false;\n" ++
        "const url = \"https://example.com//x\"; const hot_reload = b.option(bool, \"hot_reload\", \"…\");\n" ++
        "\\\\option(bool, \"hot_reload\"\n";
    const buf = try allocator.dupe(u8, src);
    defer allocator.free(buf);
    blankCommentsForProbe(buf);

    // Line 1 (comment) and line 3 (multiline-string content) are blanked;
    // line 2's live declaration survives intact.
    try testing.expect(std.mem.indexOf(u8, buf, "// const") == null);
    try testing.expect(std.mem.indexOf(u8, buf, "\\\\option") == null);
    try testing.expect(std.mem.indexOf(u8, buf, "const hot_reload = b.option(bool, \"hot_reload\", \"…\");") != null);
    try testing.expect(containsHotReloadOptionDecl(buf));

    // The pure commented-out shape alone: blanked → no match.
    const commented_only = try allocator.dupe(u8, "// const hot_reload = b.option(bool, \"hot_reload\", \"…\") orelse false;\n");
    defer allocator.free(commented_only);
    try testing.expect(containsHotReloadOptionDecl(commented_only)); // raw text matches…
    blankCommentsForProbe(commented_only);
    try testing.expect(!containsHotReloadOptionDecl(commented_only)); // …blanked text doesn't.
}

test "emitHotReloadWatch: a JS-ONLY typescript splice (transpile row, no emitted output) watches the SOURCE tree like ruby/lua" {
    const allocator = testing.allocator;
    const js_only = ScriptingSplice{
        .plugin_name = "scripting",
        .language = "typescript",
        .dir = "scripts",
        .extension = ".js",
        .hot_reload_capable = true,
        // The language HAS a transpile row — but nothing was emitted this
        // generate (`transpile_emitted` stays false): the authored `.js`
        // sources ARE the runnable files (the `// @ts-check` workflow), so
        // the watch must target the source tree (round-3 codex, PR #638 —
        // on Windows the staged copy would never see a save).
        .transpile = .{ .source_extension = ".ts", .declaration_suffix = ".d.ts" },
        .watch_dir_from_target = "../../scripts",
    };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try emitHotReloadWatch(&aw.writer, js_only);
    const out = aw.written();

    // Source-tree primary + cwd fallback — the ruby/lua shape.
    const primary = std.mem.indexOf(u8, out, "scripting.hot_reload.watchDir(hot_reload_io, std.heap.page_allocator, \"../../scripts\") catch {").?;
    const fallback = std.mem.indexOf(u8, out, "scripting.hot_reload.watchDir(hot_reload_io, std.heap.page_allocator, \"scripts\") catch |watch_err| {").?;
    try testing.expect(primary < fallback);
    // The plain source-edit message (with the runnable .js extension) —
    // not the emitted-output variant.
    try testing.expect(std.mem.indexOf(u8, out, "edit scripts/*.js and save") != null);
    try testing.expect(std.mem.indexOf(u8, out, "emitted output") == null);
}
