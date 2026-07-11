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
const cache = @import("cache.zig");
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
/// linking, not embedding — their rows live in `NATIVE_LANGUAGES`.
///
/// typescript (labelle-scripting v0.3.0, quickjs-ng) embeds `.js` ONLY:
/// the runtime evaluates plain-JS ES modules, and the TS→JS transpile hook
/// doesn't exist yet (#586) — so a `.ts` source in `ts/` fails generate
/// loudly (`rejectUntranspiledScripts`) rather than silently not running
/// or erroring at VM load, far from the author.
pub const EMBED_LANGUAGES = [_]EmbedLanguage{
    .{ .language = "lua", .extension = ".lua" },
    // ruby (labelle-scripting v0.3.0, mruby 3.4.0) embeds `.rb` sources —
    // no transpile gap (ruby is what the VM runs) and no declare mode yet
    // (`scripting_declare.DECLARE_LANGUAGE` gates that phase to lua;
    // `Component.ref` views resolve at runtime against real components).
    .{ .language = "ruby", .extension = ".rb" },
    .{ .language = "typescript", .extension = ".js", .transpile_gap = .{
        .source_extension = ".ts",
        .declaration_suffix = ".d.ts",
        .hint = TS_TRANSPILE_HINT,
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
    /// `language_policy.SUPPORTED_LANGUAGES` name; the convention dir
    /// comes from `language_policy.conventionDir` like every row.
    language: []const u8,
    /// Source extension collected by the staging copy (`.rs`).
    extension: []const u8,
    /// Package-relative dir the game's convention-dir sources are staged
    /// OVER (replacing the plugin's shipped placeholder): the plugin
    /// crate's game-module dir (labelle-scripting `native/` crate —
    /// `lib.rs` declares `mod game;`, so the game's sources become
    /// `src/game/`).
    stage_subdir: []const u8,
    /// The file that must sit at the convention dir's ROOT: the crate
    /// module root the plugin's crate resolves (`mod.rs` for rust —
    /// without it the staged crate cannot compile, so its absence is a
    /// generate-time error naming the convention, not a cargo error far
    /// from the author).
    module_root: []const u8,
};

/// The native-compiled rows. rust first (labelle-scripting PR #17, the
/// family's pattern-setter); crystal/go land as their plugin sub-modules
/// do.
pub const NATIVE_LANGUAGES = [_]NativeLanguage{
    .{
        .language = "rust",
        .extension = ".rs",
        .stage_subdir = "native/src/game",
        .module_root = "mod.rs",
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

/// Which integration family a detected splice belongs to — the axis every
/// emission/pipeline site that is NOT family-shared gates on. Shared for
/// both: the build dep's `.language` arg, the `scripting` alias +
/// `scripting_enabled` flag, the drainEvents tap and the Controller.tick
/// splice. Embed-only: the `<dir>/` copy+scan, `registerScript`/
/// `@embedFile`, the declare phase. Native-only: `stageNativeSources` +
/// the plugin's `.language_builds` steps (loaded independently by the
/// #586 wiring — the splice doesn't carry them).
pub const Family = enum { embed, native };

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
    /// Embed vs native-compiled (see `Family`). `.embed` default keeps
    /// every pre-#741 fixture/caller byte-identical.
    family: Family = .embed,
    /// Always empty for `.native` splices — nothing embeds, so the
    /// registerScript builders (which iterate this) emit nothing.
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

        if (embedExtension(declared.language)) |ext| {
            return .{
                .plugin_name = plugin.name,
                .language = declared.language,
                .dir = language_policy.conventionDir(declared.language),
                .extension = ext,
                .family = .embed,
            };
        }
        if (nativeExtension(declared.language)) |ext| {
            return .{
                .plugin_name = plugin.name,
                .language = declared.language,
                .dir = language_policy.conventionDir(declared.language),
                .extension = ext,
                .family = .native,
            };
        }
        std.log.warn(
            "labelle: script language \"{s}\" has no scripting integration yet " ++
                "(neither an embedded-VM nor a native-compiled row); " ++
                "the scripting plugin is wired but no {s}/ sources are consumed",
            .{ declared.language, language_policy.conventionDir(declared.language) },
        );
        return null;
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

// ── Native-language game-source staging (labelle-engine#741) ──────────

/// Stage the game's native-language sources over the scripting plugin's
/// STAGED package: `<game>/<dir>/**<ext>` → `<output>/deps/labelle-
/// <plugin>/<stage_subdir>/`, replacing the plugin's shipped placeholder
/// module so the plugin's declared `.language_builds` step (cargo)
/// compiles the GAME's scripts into the linked staticlib. Runs AFTER
/// `deps_linker.createDepsLinks` (build.zig.zon generation), the same
/// ordering dependency the declare phase has.
///
/// Hard rules:
///   - Deps staging MUST have produced the staged copy. When
///     `createDepsLinks` fell back ("falling back to cache-relative dep
///     paths"), `{package}` resolves to the SHARED plugin cache
///     (`~/.labelle`) — writing game sources there would poison every
///     other project's copy of the plugin, so this fails generate instead
///     (`error.NativeScriptsDepsUnstaged`). Same staged-first probe as
///     `scripting_declare.resolvePluginPackageDir`, minus the cache
///     fallback that function is allowed (it only READS).
///   - The staged tree's FILES are hardlinks into the shared cache
///     (`deps_linker.hardlinkTree`). The placeholder dir is therefore
///     DELETED first (unlinking never touches cache bytes) and the game
///     sources written as fresh copies — never opened-for-write in
///     place, which could scribble through a hardlink into the cache.
///   - A missing `<dir>/` is a no-op (scripting plugin attached, zero
///     scripts — exactly how the embed rows treat a missing script dir):
///     the shipped placeholder stays and registers nothing.
///   - An EXISTING `<dir>/` with no `<ext>` sources is a pointed error
///     (`error.NativeScriptDirEmpty`) — unlike a missing dir it can only
///     be a half-finished setup, and cargo would otherwise fail far from
///     the author.
///   - `<dir>/<module_root>` (rust: `rust/mod.rs`) is REQUIRED once any
///     source exists: it becomes the crate's game-module root
///     (`error.NativeScriptsMissingModuleRoot` names the convention).
///
/// Copies `<ext>` files only (+ subdirs, recursively), sorted
/// (deterministic copy order), dot-entries skipped. Idempotent: the
/// delete+recopy also serves the tests-target pass, whose deps tree is
/// NOT re-staged (`recreate_deps = false`).
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
    // projects that actually write.
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
        std.debug.print(
            "labelle-assembler: {s}/ exists but contains no {s} sources.\n" ++
                "  the scripting plugin (language \"{s}\") compiles {s}/ into the game — " ++
                "add {s}/{s} (the crate's game-module root) or remove the empty directory.\n",
            .{ splice.dir, splice.extension, splice.language, splice.dir, splice.dir, row.module_root },
        );
        return error.NativeScriptDirEmpty;
    }
    std.mem.sort([]const u8, rel_paths.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

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
                "  game sources are never written into the shared plugin cache; fix the deps staging failure and regenerate.\n",
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
                "  pin a labelle-scripting version whose package ships {s}/ (PR #17 or later).\n",
            .{ stage_parent, splice.language, row.stage_subdir },
        );
        return error.NativeCrateLayoutMissing;
    }

    const dest_root = try std.fs.path.join(allocator, &.{ staged_pkg, row.stage_subdir });
    defer allocator.free(dest_root);
    // Placeholder out: DELETE, never overwrite in place (hardlink rule
    // above). deleteTree is delete-if-exists, so a plugin shipping no
    // placeholder dir is fine too.
    try cwd.deleteTree(io, dest_root);
    try cwd.createDirPath(io, dest_root);

    for (rel_paths.items) |rel| {
        if (std.fs.path.dirname(rel)) |sub| {
            const sub_path = try std.fs.path.join(allocator, &.{ dest_root, sub });
            defer allocator.free(sub_path);
            try cwd.createDirPath(io, sub_path);
        }
        const src_path = try std.fs.path.join(allocator, &.{ src_dir_path, rel });
        defer allocator.free(src_path);
        const dst_path = try std.fs.path.join(allocator, &.{ dest_root, rel });
        defer allocator.free(dst_path);
        try cwd.copyFile(src_path, cwd, dst_path, io, .{});
    }
}

/// Recursive `<ext>`-filtered collection of `dir`'s files as rel paths
/// (subdirs joined with the platform separator). Dot-entries skipped —
/// `.gitkeep`/`.DS_Store` are not sources, so a dir holding only those is
/// "empty" for the `NativeScriptDirEmpty` rule (matching the
/// language-policy scan's dot rule).
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
    // typescript embeds PLAIN JS (quickjs-ng runs ES modules; TS→JS
    // transpile is the #586 gap) — never `.ts`.
    try testing.expectEqualStrings(".js", embedExtension("typescript").?);
    try testing.expect(embedExtension("rust") == null);
    try testing.expect(embedExtension("cobol") == null);
}

test "EMBED_LANGUAGES: lua and ruby have no transpile gap; typescript gates .ts (exempting .d.ts) with the pointed #586 hint" {
    try testing.expect(embedRow("lua").?.transpile_gap == null);
    try testing.expect(embedRow("ruby").?.transpile_gap == null);
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
        .{ .name = "scripting", .repo = "local:plugins/scripting", .params = .{ .language = "lua" } },
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
        .{ .name = "scripting", .repo = "local:plugins/scripting", .params = .{ .language = "typescript" } },
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

test "detect: a rust declaration splices as the NATIVE family — rust/ dir, .rs extension, no embed" {
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
    try testing.expectEqualStrings("rust", splice.dir);
    try testing.expectEqualStrings(".rs", splice.extension);
    try testing.expectEqual(Family.native, splice.family);
    // Nothing embeds for a native splice — the registerScript builders
    // iterate script_names, which stays empty for the family.
    try testing.expectEqual(@as(usize, 0), splice.script_names.len);
}

test "NATIVE_LANGUAGES: rust row shape — extension, crate stage dir, module root; nativeExtension table" {
    const rust = nativeRow("rust").?;
    try testing.expectEqualStrings(".rs", rust.extension);
    try testing.expectEqualStrings("native/src/game", rust.stage_subdir);
    try testing.expectEqualStrings("mod.rs", rust.module_root);

    try testing.expectEqualStrings(".rs", nativeExtension("rust").?);
    // Embed languages never appear in the native table (and vice versa —
    // the families are disjoint; detect() checks embed first).
    try testing.expect(nativeExtension("lua") == null);
    try testing.expect(nativeExtension("ruby") == null);
    try testing.expect(nativeExtension("typescript") == null);
    try testing.expect(nativeExtension("crystal") == null);
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

    // `crystal` is policy-supported (SUPPORTED_LANGUAGES) but has neither
    // an embed row nor a native row yet — so the splice is skipped. The
    // skip logs via `std.log.warn`, which the Zig test runner tolerates
    // (only a logged `err` fails a test — see the same gate noted in
    // render.zig).
    const plugins = [_]config.PluginDep{
        .{ .name = "scripting", .repo = "local:plugins/scripting", .params = .{ .language = "crystal" } },
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

// ── stageNativeSources (labelle-engine#741) ──────────────────────────

const rust_splice_fixture = ScriptingSplice{
    .plugin_name = "scripting",
    .language = "rust",
    .dir = "rust",
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

test "stageNativeSources: replaces the placeholder with the game's sorted .rs tree (subdirs in, foreign files out)" {
    const allocator = testing.allocator;
    var fx = try NativeStagingFixture.init(allocator, .{});
    defer fx.deinit(allocator);

    try writeTestFile(fx.tmp.dir, "game/rust/mod.rs", "mod player;\nmod ai;\npub fn register() {}\n");
    try writeTestFile(fx.tmp.dir, "game/rust/player.rs", "pub struct Player;\n");
    try writeTestFile(fx.tmp.dir, "game/rust/ai/brain.rs", "pub fn think() {}\n");
    // Foreign files never stage: not sources (.toml), dot-entries.
    try writeTestFile(fx.tmp.dir, "game/rust/notes.toml", "# not a source\n");
    try writeTestFile(fx.tmp.dir, "game/rust/.hidden.rs", "// dot-entry\n");

    try stageNativeSources(allocator, fx.game_abs, fx.out_abs, rust_splice_fixture);

    const game_mod = try fx.tmp.dir.readFileAlloc(testing.io, "out/deps/labelle-scripting/native/src/game/mod.rs", allocator, .limited(4096));
    defer allocator.free(game_mod);
    // The PLACEHOLDER body is gone — the game's mod.rs is the module root.
    try testing.expect(std.mem.indexOf(u8, game_mod, "REPLACED AT GENERATE") == null);
    try testing.expect(std.mem.indexOf(u8, game_mod, "mod player;") != null);

    try fx.tmp.dir.access(testing.io, "out/deps/labelle-scripting/native/src/game/player.rs", .{});
    try fx.tmp.dir.access(testing.io, "out/deps/labelle-scripting/native/src/game/ai/brain.rs", .{});
    try testing.expectError(
        error.FileNotFound,
        fx.tmp.dir.access(testing.io, "out/deps/labelle-scripting/native/src/game/notes.toml", .{}),
    );
    try testing.expectError(
        error.FileNotFound,
        fx.tmp.dir.access(testing.io, "out/deps/labelle-scripting/native/src/game/.hidden.rs", .{}),
    );

    // Idempotent (the tests-target pass re-runs it over surviving deps):
    // a removed game file disappears from the staged tree on the next run.
    try fx.tmp.dir.deleteFile(testing.io, "game/rust/player.rs");
    try stageNativeSources(allocator, fx.game_abs, fx.out_abs, rust_splice_fixture);
    try testing.expectError(
        error.FileNotFound,
        fx.tmp.dir.access(testing.io, "out/deps/labelle-scripting/native/src/game/player.rs", .{}),
    );
}

test "stageNativeSources: no rust/ dir at all → no-op, the shipped placeholder stays (zero scripts)" {
    const allocator = testing.allocator;
    var fx = try NativeStagingFixture.init(allocator, .{});
    defer fx.deinit(allocator);

    try stageNativeSources(allocator, fx.game_abs, fx.out_abs, rust_splice_fixture);

    const game_mod = try fx.tmp.dir.readFileAlloc(testing.io, "out/deps/labelle-scripting/native/src/game/mod.rs", allocator, .limited(4096));
    defer allocator.free(game_mod);
    try testing.expect(std.mem.indexOf(u8, game_mod, "REPLACED AT GENERATE") != null);
}

test "stageNativeSources: a rust/ dir with no .rs sources is a pointed error (unlike a missing dir)" {
    const allocator = testing.allocator;
    var fx = try NativeStagingFixture.init(allocator, .{});
    defer fx.deinit(allocator);

    // .gitkeep is a dot-entry — the dir is "empty" for the rule.
    try writeTestFile(fx.tmp.dir, "game/rust/.gitkeep", "");
    try writeTestFile(fx.tmp.dir, "game/rust/README.md", "no sources here\n");

    try testing.expectError(
        error.NativeScriptDirEmpty,
        stageNativeSources(allocator, fx.game_abs, fx.out_abs, rust_splice_fixture),
    );
}

test "stageNativeSources: .rs sources without the mod.rs module root fail pointing at the convention" {
    const allocator = testing.allocator;
    var fx = try NativeStagingFixture.init(allocator, .{});
    defer fx.deinit(allocator);

    try writeTestFile(fx.tmp.dir, "game/rust/player.rs", "pub struct Player;\n");

    try testing.expectError(
        error.NativeScriptsMissingModuleRoot,
        stageNativeSources(allocator, fx.game_abs, fx.out_abs, rust_splice_fixture),
    );
}

test "stageNativeSources: deps staging fell back to the shared cache → HARD error, nothing written" {
    // The load-bearing negative: when `createDepsLinks` degraded, the
    // `{package}` resolution falls back to the SHARED plugin cache — and
    // game sources must never be written there. The staged-deps probe is
    // the same one the declare phase uses; here its miss is fatal.
    const allocator = testing.allocator;
    var fx = try NativeStagingFixture.init(allocator, .{ .stage_deps = false });
    defer fx.deinit(allocator);

    try writeTestFile(fx.tmp.dir, "game/rust/mod.rs", "pub fn register() {}\n");

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

    try writeTestFile(fx.tmp.dir, "game/rust/mod.rs", "pub fn register() {}\n");

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
    try writeTestFile(fx.tmp.dir, "game/lua/player.lua", "-- lua\n");
    const lua_splice = ScriptingSplice{
        .plugin_name = "scripting",
        .language = "lua",
        .dir = "lua",
        .extension = ".lua",
    };
    try stageNativeSources(allocator, fx.game_abs, fx.out_abs, lua_splice);
}
