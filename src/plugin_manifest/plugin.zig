//! Plugin manifest (`plugin.labelle`) support, extracted from
//! `plugin_manifest.zig` (behavior-preserving split, mirrors #539).
//!
//! Reads `plugin.labelle` from a plugin directory, validates it against
//! the project's plugin declaration, and exposes the convention
//! directories the generator should copy/scan in addition to the
//! hardcoded ones.
//!
//! See `docs/RFC-plugin-manifest.md` for the design and rationale.
//! Re-exported unchanged from the `plugin_manifest.zig` barrel.
const std = @import("std");
const config = @import("../config.zig");
const cache = @import("../cache.zig");
const common = @import("common.zig");
const language_policy = @import("../language_policy.zig");

const SUPPORTED_MANIFEST_VERSION = common.SUPPORTED_MANIFEST_VERSION;
const RESERVED_DIR_NAMES = common.RESERVED_DIR_NAMES;
const isReservedDirName = common.isReservedDirName;
const isSafeDirName = common.isSafeDirName;

pub const ConventionDirMode = enum {
    /// Copy every file matching `extension` from <game>/<name>/ to
    /// <target>/<name>/, then scan the file stems. Mirrors the
    /// existing `scanner.copyAndScan` path used for components,
    /// hooks, events, enums, prefabs, scenes, scripts, views, gizmos.
    copy_and_scan,
    /// Copy every file from <game>/<name>/ to <target>/<name>/
    /// recursively, no scanning. Mirrors `scanner.copyDirRecursive`
    /// used for assets/.
    copy_only,
    /// Like `copy_and_scan`, but the source directory is inside the
    /// **plugin's** cached package, not the consuming game's tree.
    /// Copies <plugin>/<name>/** into <target>/<name>/ and scans the
    /// file stems with `extension`. Enables a plugin to ship its own
    /// scripts, hooks, or other scanned assets that become part of the
    /// generated build alongside the game's own.
    ///
    /// See RFC-plugin-controllers §migration step 1 — pathfinder will
    /// use this mode to ship `libs/pathfinder/scripts/playing/01_advance.zig`
    /// as a 5-line per-frame bridge that every consuming game
    /// automatically picks up.
    ship_from_plugin,
};

pub const ConventionDir = struct {
    name: []const u8,
    /// File extension to scan (e.g. ".zig"). Required when
    /// `mode == .copy_and_scan`. Ignored / left null when
    /// `mode == .copy_only`.
    extension: ?[]const u8 = null,
    mode: ConventionDirMode,
};

/// Parsed and validated `plugin.labelle` manifest.
///
/// Ownership: every string field (`name`, each `ConventionDir.name`
/// and `ConventionDir.extension`) is a heap allocation made by the
/// ZON parser via `parseString → toOwnedSlice`. Strings are deep
/// copies, *not* references into the source buffer — the source
/// buffer is freed immediately after parsing in `loadFromDir`.
/// Call `deinit` to release all heap allocations owned by the
/// manifest.
pub const PluginManifest = struct {
    name: []const u8,
    manifest_version: u8,
    convention_dirs: []const ConventionDir = &.{},

    /// Plugin-level assets (Asset-Plugins RFC Phase 2, labelle-assembler#576).
    /// Same `ResourceDef` shape as `project.labelle` / `pack.labelle`. Paths
    /// are relative to the plugin root (e.g. `assets/ui.json`). The assembler
    /// merges these into the game resource list namespaced `<plugin>__<name>`,
    /// copied+repathed into `packs/<plugin>/…` — exactly like a pack's
    /// `.resources` (Phase 1). Empty/absent = a code-only plugin (every plugin
    /// before this ticket) → byte-identical output.
    resources: []const config.ResourceDef = &.{},

    /// Names of packs BUNDLED inside this plugin at `<plugin>/packs/<name>/`
    /// (Asset-Plugins RFC Phase 2, labelle-assembler#576). Each nested pack has
    /// the identical structure to a game-local pack (its own `pack.labelle` +
    /// convention dirs) and registers through the SAME pack machinery — copy,
    /// scan, `pack__` namespacing, resource merge — as if declared directly in
    /// `project.labelle`. Empty/absent = a plugin that bundles no packs.
    packs: []const []const u8 = &.{},

    /// Game (or other unit) atlases this plugin's own `.resources`/prefabs
    /// deliberately draw from (Asset-Plugins RFC Phase 2). Same contract as a
    /// pack's `depends_on_resources`: every entry must resolve in the merged
    /// resource list. Empty/absent = self-contained.
    depends_on_resources: []const []const u8 = &.{},

    /// Script language this plugin's shipped scripts are written in
    /// (RFC-LANGUAGE-PLUGINS revs 8–9, assembler#584) — symmetric with
    /// `depends_on_resources`. Validated at load against
    /// `language_policy.SUPPORTED_LANGUAGES`, and at attach against the
    /// project's declared `.params.language` (a Lua-scripted plugin fails
    /// loudly in a Rust project, naming both sides). Absent = the plugin
    /// ships no language scripts (every plugin before this ticket) →
    /// byte-identical.
    requires_language: ?[]const u8 = null,

    /// SPDX-style license identifier for a shipped/sold plugin (Asset-Plugins
    /// RFC Phase 2, labelle-cli#300). Surfaced by `labelle plugins`. Optional.
    license: ?[]const u8 = null,

    /// Author/vendor of the plugin (Asset-Plugins RFC Phase 2). Surfaced by
    /// `labelle plugins`. Optional.
    author: ?[]const u8 = null,

    /// Allocator that owns the parsed strings and slice. Stored on
    /// the manifest so the caller doesn't have to remember to pass
    /// the right allocator to deinit.
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PluginManifest) void {
        // Free every heap-allocated field individually.
        // std.zon.parse.free walks slices and structs recursively,
        // so passing `self.convention_dirs` frees each element's
        // nested `name` and `extension` strings in addition to the
        // outer slice.
        std.zon.parse.free(self.allocator, self.name);
        std.zon.parse.free(self.allocator, self.convention_dirs);
        std.zon.parse.free(self.allocator, self.resources);
        std.zon.parse.free(self.allocator, self.packs);
        std.zon.parse.free(self.allocator, self.depends_on_resources);
        std.zon.parse.free(self.allocator, self.requires_language);
        std.zon.parse.free(self.allocator, self.license);
        std.zon.parse.free(self.allocator, self.author);
    }
};

// ── Errors ─────────────────────────────────────────────────────────
//
// loadOptional uses an inferred error set so it composes cleanly with
// std.fs and std.zon error unions across Zig versions. The manifest-
// specific validation errors the caller might want to match on are:
//
//   error.PluginManifestParseError         — ZON parser rejected the file
//   error.PluginManifestNameMismatch       — plugin.labelle name != .plugins entry name
//   error.PluginManifestReservedDirName    — plugin tried to claim a reserved name
//   error.PluginManifestUnsafeDirName      — convention_dir name is not a safe relative segment
//   error.PluginManifestMissingExtension   — copy_and_scan entry omitted its required extension
//   error.PluginManifestUnknownVersion     — manifest_version is < 1 or > what we support
//   error.PluginManifestUnknownLanguage    — requires_language names a language outside
//                                             language_policy.SUPPORTED_LANGUAGES (#584)
//
// The pack-manifest path (`loadPackFromDir`) additionally raises:
//   error.PackAndPluginManifestConflict    — a pack.labelle dir ALSO ships
//                                             decl-module content (mutually exclusive)

/// Read and parse `plugin.labelle` for the given plugin if it exists.
///
/// Returns `null` when the plugin has no manifest file (legal — many
/// plugins like labelle-pathfinder don't need one). Returns a parsed
/// `PluginManifest` on success. Errors on parse failure, name
/// mismatch, reserved-name collision, or an unsupported manifest_version.
///
/// The returned manifest's strings are backed by `raw` inside the
/// struct — call `deinit` to release them.
pub fn loadOptional(
    allocator: std.mem.Allocator,
    plugin: config.PluginDep,
    project_dir: []const u8,
) !?PluginManifest {
    const plugin_dir = try cache.resolvePlugin(allocator, plugin, project_dir);
    defer allocator.free(plugin_dir);
    return loadFromDir(allocator, plugin_dir, plugin.name);
}

/// Lower-level entry point: read and parse `plugin.labelle` from a
/// known plugin directory. The caller already resolved the plugin
/// name to a path (for example via `cache.resolvePlugin`).
///
/// `expected_name` is what `project.labelle`'s `.plugins` entry calls
/// the plugin — the manifest's `name` field must match.
///
/// Returns `null` if the plugin has no `plugin.labelle` (legal — many
/// plugins like labelle-pathfinder don't need one). Errors on:
///   - ZON parse failure                  → PluginManifestParseError
///   - name mismatch                      → PluginManifestNameMismatch
///   - unsupported manifest_version       → PluginManifestUnknownVersion
///   - reserved convention_dir name       → PluginManifestReservedDirName
///   - unsafe convention_dir name         → PluginManifestUnsafeDirName
///   - missing extension on copy_and_scan → PluginManifestMissingExtension
///
/// The returned manifest owns its strings as deep heap copies made by
/// the ZON parser; the source buffer is freed before returning. Call
/// `PluginManifest.deinit` to release them.
///
/// Exposed publicly so tests and tooling can exercise the manifest
/// machinery without needing the full plugin-cache resolution path.
pub fn loadFromDir(
    allocator: std.mem.Allocator,
    plugin_dir: []const u8,
    expected_name: []const u8,
) !?PluginManifest {
    const manifest_path = try std.fs.path.join(allocator, &.{ plugin_dir, "plugin.labelle" });
    defer allocator.free(manifest_path);

    // Read the file. If the file does not exist, return null — this is
    // a legal "no manifest" plugin (e.g. labelle-pathfinder).
    const cwd = std.Io.Dir.cwd();
    const raw_bytes = cwd.readFileAlloc(config.globalIo(), manifest_path, allocator, .limited(64 * 1024)) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer allocator.free(raw_bytes);

    // ZON parser needs a sentinel-terminated buffer.
    const raw_z = try allocator.dupeZ(u8, raw_bytes);
    defer allocator.free(raw_z);

    // Parse with the typed ZON struct (matches gui_resolve.zig pattern).
    // The parser allocates fresh string copies via parseString →
    // toOwnedSlice, so raw_z can be freed immediately after parsing
    // succeeds — the returned slices are independent heap allocations.
    //
    // ignore_unknown_fields = true is intentional forward-compat: a
    // manifest from a future plugin that adds a new optional field
    // should still load in an older CLI. Hard-incompat changes bump
    // manifest_version (checked below) rather than adding fields.
    const parsed = std.zon.parse.fromSliceAlloc(ZonManifest, allocator, raw_z, null, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.print(
            "labelle: failed to parse plugin.labelle for plugin '{s}' at {s}\n  parser error: {any}\n  see docs/RFC-plugin-manifest.md for the manifest schema\n",
            .{ expected_name, manifest_path, err },
        );
        return error.PluginManifestParseError;
    };
    // From here on, validation may reject the manifest and we have to
    // free everything the parser allocated. zon.parse.free walks
    // structs recursively, so passing the whole `parsed` value frees
    // every nested string and slice.
    errdefer std.zon.parse.free(allocator, parsed);

    // ── Validate name matches the project's plugin declaration ──
    if (!std.mem.eql(u8, parsed.name, expected_name)) {
        std.debug.print(
            "labelle: plugin.labelle name mismatch\n  project.labelle declares plugin '{s}'\n  but its plugin.labelle has name = '{s}'\n  at {s}\n",
            .{ expected_name, parsed.name, manifest_path },
        );
        return error.PluginManifestNameMismatch;
    }

    // ── Validate manifest_version ──
    // Valid versions: 1 <= v <= SUPPORTED_MANIFEST_VERSION. Version 0 is
    // not a real schema version — probably a plugin author who forgot to
    // set the field or typed 0 by accident — and should be flagged the
    // same way as an unknown future version.
    if (parsed.manifest_version < 1 or parsed.manifest_version > SUPPORTED_MANIFEST_VERSION) {
        std.debug.print(
            "labelle: plugin '{s}' has manifest_version {d}\n  but this labelle-cli release supports manifest_version 1..{d}\n  fix the plugin.labelle manifest or upgrade/downgrade labelle-cli\n",
            .{ expected_name, parsed.manifest_version, SUPPORTED_MANIFEST_VERSION },
        );
        return error.PluginManifestUnknownVersion;
    }

    // ── Validate every convention_dir entry ──
    for (parsed.convention_dirs) |dir| {
        // Reserved names — mustn't shadow a hardcoded convention dir.
        if (isReservedDirName(dir.name)) {
            std.debug.print(
                "labelle: plugin '{s}' tried to declare convention_dir '{s}'\n  but '{s}' is reserved for first-class engine concepts.\n  reserved names: ",
                .{ expected_name, dir.name, dir.name },
            );
            for (RESERVED_DIR_NAMES, 0..) |name, i| {
                if (i > 0) std.debug.print(", ", .{});
                std.debug.print("{s}", .{name});
            }
            std.debug.print("\n  pick a different directory name for this plugin.\n", .{});
            return error.PluginManifestReservedDirName;
        }

        // Path-traversal guard. `dir.name` is concatenated into a path
        // passed to copyAndScan / copyDirRecursive, so a malicious or
        // buggy plugin declaring "../../etc" or "/abs/path" could
        // read/write outside the game root. Require a plain relative
        // segment: non-empty, no path separators, no `..` or `.`,
        // no leading `/` or `\`, no null bytes.
        if (!isSafeDirName(dir.name)) {
            std.debug.print(
                "labelle: plugin '{s}' declared convention_dir name '{s}' that is not a safe relative directory name\n  directory names must be plain single segments (no '/', '\\', '..', '.', absolute paths, or NUL)\n",
                .{ expected_name, dir.name },
            );
            return error.PluginManifestUnsafeDirName;
        }

        // Scan modes require an explicit extension. root.zig used to
        // silently default to ".zig", which hid typos and surprised
        // plugin authors scanning .jsonc or .zon files. The RFC marks
        // extension as required for these modes — enforce it here at
        // load time with a clear diagnostic. `copy_only` skips scanning
        // entirely so extension is irrelevant and must stay null-or-anything.
        const needs_extension = dir.mode == .copy_and_scan or dir.mode == .ship_from_plugin;
        if (needs_extension and dir.extension == null) {
            std.debug.print(
                "labelle: plugin '{s}' declared convention_dir '{s}' with mode .{s}\n  but 'extension' is missing. scan modes require a file extension (e.g. \".zig\").\n  use mode .copy_only if you want to copy every file regardless of extension.\n",
                .{ expected_name, dir.name, @tagName(dir.mode) },
            );
            return error.PluginManifestMissingExtension;
        }
    }

    // ── Validate every nested `.packs` name (Phase 2, #576) ──
    // A nested pack name is concatenated into `<plugin>/packs/<name>/` and into
    // the target `packs/<name>/…`, so it must be a plain relative segment for
    // the same path-traversal reason `convention_dirs` names are guarded.
    for (parsed.packs) |pack_name| {
        if (!isSafeDirName(pack_name)) {
            std.debug.print(
                "labelle: plugin '{s}' declared nested pack name '{s}' that is not a safe relative directory name\n  pack names must be plain single segments (no '/', '\\', '..', '.', absolute paths, or NUL)\n",
                .{ expected_name, pack_name },
            );
            return error.PluginManifestUnsafeDirName;
        }
    }

    // ── Validate `requires_language` vocabulary (#584) ──
    // The value must come from the closed language table. The MATCH against
    // the project's declared `.params.language` needs project context and runs in
    // the generate-time policy gate (`language_policy.checkRequiresLanguage`);
    // this load-time check rejects typos at the source with the manifest named.
    if (parsed.requires_language) |req| {
        if (!language_policy.isSupportedLanguage(req)) {
            std.debug.print(
                "labelle: plugin '{s}' declares requires_language \"{s}\"\n  which is not a supported script language ({s})\n  at {s}\n",
                .{ expected_name, req, language_policy.SUPPORTED_LANGUAGES_LIST, manifest_path },
            );
            return error.PluginManifestUnknownLanguage;
        }
    }

    return PluginManifest{
        .name = parsed.name,
        .manifest_version = parsed.manifest_version,
        .convention_dirs = parsed.convention_dirs,
        .resources = parsed.resources,
        .packs = parsed.packs,
        .depends_on_resources = parsed.depends_on_resources,
        .requires_language = parsed.requires_language,
        .license = parsed.license,
        .author = parsed.author,
        .allocator = allocator,
    };
}

// ── ZON-parseable manifest type ───────────────────────────────────
//
// Mirrors the public-facing PluginManifest but without the lifetime
// fields, since the parser only knows about ZON-shaped data.
const ZonManifest = struct {
    name: []const u8,
    manifest_version: u8,
    convention_dirs: []const ConventionDir = &.{},
    // Asset-Plugins Phase 2 (#576 / cli#300). All optional/additive; an older
    // manifest that omits them parses to the byte-identical empty/null defaults.
    resources: []const config.ResourceDef = &.{},
    packs: []const []const u8 = &.{},
    depends_on_resources: []const []const u8 = &.{},
    license: ?[]const u8 = null,
    author: ?[]const u8 = null,
    // Language plugins P1 (#584). Optional/additive — absent parses to the
    // byte-identical null default.
    requires_language: ?[]const u8 = null,
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "ZonManifest: parses minimal manifest with one convention dir" {
    const src =
        \\.{
        \\    .name = "fsm",
        \\    .manifest_version = 1,
        \\    .convention_dirs = .{
        \\        .{
        \\            .name = "state_machines",
        \\            .extension = ".zig",
        \\            .mode = .copy_and_scan,
        \\        },
        \\    },
        \\}
    ;
    const src_z = try testing.allocator.dupeZ(u8, src);
    defer testing.allocator.free(src_z);

    const parsed = try std.zon.parse.fromSliceAlloc(ZonManifest, testing.allocator, src_z, null, .{});
    defer std.zon.parse.free(testing.allocator, parsed);

    try testing.expectEqualStrings("fsm", parsed.name);
    try testing.expectEqual(@as(u8, 1), parsed.manifest_version);
    try testing.expectEqual(@as(usize, 1), parsed.convention_dirs.len);
    try testing.expectEqualStrings("state_machines", parsed.convention_dirs[0].name);
    try testing.expectEqualStrings(".zig", parsed.convention_dirs[0].extension.?);
    try testing.expectEqual(ConventionDirMode.copy_and_scan, parsed.convention_dirs[0].mode);
}

test "ZonManifest: parses copy_only mode without extension" {
    const src =
        \\.{
        \\    .name = "fsm",
        \\    .manifest_version = 1,
        \\    .convention_dirs = .{
        \\        .{
        \\            .name = "fsm_assets",
        \\            .mode = .copy_only,
        \\        },
        \\    },
        \\}
    ;
    const src_z = try testing.allocator.dupeZ(u8, src);
    defer testing.allocator.free(src_z);

    const parsed = try std.zon.parse.fromSliceAlloc(ZonManifest, testing.allocator, src_z, null, .{});
    defer std.zon.parse.free(testing.allocator, parsed);

    try testing.expectEqual(ConventionDirMode.copy_only, parsed.convention_dirs[0].mode);
    try testing.expect(parsed.convention_dirs[0].extension == null);
}

test "ZonManifest: parses manifest with no convention_dirs" {
    const src =
        \\.{
        \\    .name = "marker_only",
        \\    .manifest_version = 1,
        \\}
    ;
    const src_z = try testing.allocator.dupeZ(u8, src);
    defer testing.allocator.free(src_z);

    const parsed = try std.zon.parse.fromSliceAlloc(ZonManifest, testing.allocator, src_z, null, .{});
    defer std.zon.parse.free(testing.allocator, parsed);

    try testing.expectEqualStrings("marker_only", parsed.name);
    try testing.expectEqual(@as(usize, 0), parsed.convention_dirs.len);
}

test "ZonManifest: parses ship_from_plugin mode with extension" {
    const src =
        \\.{
        \\    .name = "pathfinder",
        \\    .manifest_version = 1,
        \\    .convention_dirs = .{
        \\        .{
        \\            .name = "scripts",
        \\            .extension = ".zig",
        \\            .mode = .ship_from_plugin,
        \\        },
        \\    },
        \\}
    ;
    const src_z = try testing.allocator.dupeZ(u8, src);
    defer testing.allocator.free(src_z);

    // Note: "scripts" *is* reserved for the hardcoded engine convention,
    // so at the load level this entry would hit the reserved-name guard.
    // The raw ZON parser only cares about the shape of the enum, though.
    const parsed = try std.zon.parse.fromSliceAlloc(ZonManifest, testing.allocator, src_z, null, .{});
    defer std.zon.parse.free(testing.allocator, parsed);

    try testing.expectEqual(ConventionDirMode.ship_from_plugin, parsed.convention_dirs[0].mode);
    try testing.expectEqualStrings(".zig", parsed.convention_dirs[0].extension.?);
}

test "loadFromDir: rejects ship_from_plugin without extension" {
    // Scan modes need an explicit extension so the plugin author can't
    // accidentally ship a mixed-extension directory that the scanner
    // silently treats as .zig-only. Same rule as copy_and_scan.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeManifestFile(tmp.dir,
        \\.{
        \\    .name = "pathfinder",
        \\    .manifest_version = 1,
        \\    .convention_dirs = .{
        \\        .{
        \\            .name = "pathfinder_scripts",
        \\            .mode = .ship_from_plugin,
        \\        },
        \\    },
        \\}
    );

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const result = loadFromDir(testing.allocator, tmp_path, "pathfinder");
    try testing.expectError(error.PluginManifestMissingExtension, result);
}

test "loadFromDir: parses ship_from_plugin mode end-to-end" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeManifestFile(tmp.dir,
        \\.{
        \\    .name = "pathfinder",
        \\    .manifest_version = 1,
        \\    .convention_dirs = .{
        \\        .{
        \\            .name = "pathfinder_bridges",
        \\            .extension = ".zig",
        \\            .mode = .ship_from_plugin,
        \\        },
        \\    },
        \\}
    );

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var manifest = (try loadFromDir(testing.allocator, tmp_path, "pathfinder")).?;
    defer manifest.deinit();

    try testing.expectEqual(ConventionDirMode.ship_from_plugin, manifest.convention_dirs[0].mode);
    try testing.expectEqualStrings("pathfinder_bridges", manifest.convention_dirs[0].name);
    try testing.expectEqualStrings(".zig", manifest.convention_dirs[0].extension.?);
}

test "ZonManifest: parses manifest with multiple convention dirs (different extensions on same name)" {
    const src =
        \\.{
        \\    .name = "fsm",
        \\    .manifest_version = 1,
        \\    .convention_dirs = .{
        \\        .{ .name = "state_machines", .extension = ".zig",  .mode = .copy_and_scan },
        \\        .{ .name = "state_machines", .extension = ".zon",  .mode = .copy_and_scan },
        \\    },
        \\}
    ;
    const src_z = try testing.allocator.dupeZ(u8, src);
    defer testing.allocator.free(src_z);

    const parsed = try std.zon.parse.fromSliceAlloc(ZonManifest, testing.allocator, src_z, null, .{});
    defer std.zon.parse.free(testing.allocator, parsed);

    try testing.expectEqual(@as(usize, 2), parsed.convention_dirs.len);
    try testing.expectEqualStrings(".zig", parsed.convention_dirs[0].extension.?);
    try testing.expectEqualStrings(".zon", parsed.convention_dirs[1].extension.?);
}

// ── loadFromDir integration tests against a real (tmp) plugin dir ──

fn writeManifestFile(tmp_dir: std.Io.Dir, body: []const u8) !void {
    var f = try tmp_dir.createFile(testing.io, "plugin.labelle", .{});
    defer f.close(testing.io);
    try f.writeStreamingAll(testing.io, body);
}

test "loadFromDir: returns null when plugin.labelle is missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const result = try loadFromDir(testing.allocator, tmp_path, "fsm");
    try testing.expect(result == null);
}

test "loadFromDir: parses a valid manifest" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeManifestFile(tmp.dir,
        \\.{
        \\    .name = "fsm",
        \\    .manifest_version = 1,
        \\    .convention_dirs = .{
        \\        .{
        \\            .name = "state_machines",
        \\            .extension = ".zig",
        \\            .mode = .copy_and_scan,
        \\        },
        \\    },
        \\}
    );

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var manifest = (try loadFromDir(testing.allocator, tmp_path, "fsm")).?;
    defer manifest.deinit();

    try testing.expectEqualStrings("fsm", manifest.name);
    try testing.expectEqual(@as(u8, 1), manifest.manifest_version);
    try testing.expectEqual(@as(usize, 1), manifest.convention_dirs.len);
    try testing.expectEqualStrings("state_machines", manifest.convention_dirs[0].name);
    try testing.expectEqualStrings(".zig", manifest.convention_dirs[0].extension.?);
    try testing.expectEqual(ConventionDirMode.copy_and_scan, manifest.convention_dirs[0].mode);
}

test "loadFromDir: errors on name mismatch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeManifestFile(tmp.dir,
        \\.{
        \\    .name = "fsm",
        \\    .manifest_version = 1,
        \\}
    );

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const result = loadFromDir(testing.allocator, tmp_path, "different_name");
    try testing.expectError(error.PluginManifestNameMismatch, result);
}

test "loadFromDir: errors on manifest_version higher than supported" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeManifestFile(tmp.dir,
        \\.{
        \\    .name = "fsm",
        \\    .manifest_version = 99,
        \\}
    );

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const result = loadFromDir(testing.allocator, tmp_path, "fsm");
    try testing.expectError(error.PluginManifestUnknownVersion, result);
}

test "loadFromDir: errors on manifest_version zero" {
    // manifest_version = 0 is not a real schema version — catch the
    // "plugin author forgot to set it / typed 0 by accident" case with
    // the same error as an unknown future version.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeManifestFile(tmp.dir,
        \\.{
        \\    .name = "fsm",
        \\    .manifest_version = 0,
        \\}
    );

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const result = loadFromDir(testing.allocator, tmp_path, "fsm");
    try testing.expectError(error.PluginManifestUnknownVersion, result);
}

test "loadFromDir: errors when plugin tries to declare a reserved name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeManifestFile(tmp.dir,
        \\.{
        \\    .name = "fsm",
        \\    .manifest_version = 1,
        \\    .convention_dirs = .{
        \\        .{
        \\            .name = "components",
        \\            .extension = ".zig",
        \\            .mode = .copy_and_scan,
        \\        },
        \\    },
        \\}
    );

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const result = loadFromDir(testing.allocator, tmp_path, "fsm");
    try testing.expectError(error.PluginManifestReservedDirName, result);
}

test "loadFromDir: errors when plugin tries to declare the packs reserved name" {
    // `packs` is reserved for the pack-scan layout (#439) — a plugin must not
    // claim it and write into `<target>/packs/`, colliding with scanned packs.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeManifestFile(tmp.dir,
        \\.{
        \\    .name = "fsm",
        \\    .manifest_version = 1,
        \\    .convention_dirs = .{
        \\        .{
        \\            .name = "packs",
        \\            .extension = ".zig",
        \\            .mode = .copy_and_scan,
        \\        },
        \\    },
        \\}
    );

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const result = loadFromDir(testing.allocator, tmp_path, "fsm");
    try testing.expectError(error.PluginManifestReservedDirName, result);
}

test "loadFromDir: errors on malformed ZON" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeManifestFile(tmp.dir,
        \\.{
        \\    .name = "fsm"
        \\    .manifest_version = 1   // missing comma above
        \\}
    );

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const result = loadFromDir(testing.allocator, tmp_path, "fsm");
    try testing.expectError(error.PluginManifestParseError, result);
}

test "loadFromDir: parses copy_only mode end-to-end" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeManifestFile(tmp.dir,
        \\.{
        \\    .name = "fsm",
        \\    .manifest_version = 1,
        \\    .convention_dirs = .{
        \\        .{
        \\            .name = "fsm_extras",
        \\            .mode = .copy_only,
        \\        },
        \\    },
        \\}
    );

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var manifest = (try loadFromDir(testing.allocator, tmp_path, "fsm")).?;
    defer manifest.deinit();

    try testing.expectEqual(ConventionDirMode.copy_only, manifest.convention_dirs[0].mode);
    try testing.expectEqualStrings("fsm_extras", manifest.convention_dirs[0].name);
}

test "loadFromDir: rejects path traversal in convention_dir name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeManifestFile(tmp.dir,
        \\.{
        \\    .name = "evil",
        \\    .manifest_version = 1,
        \\    .convention_dirs = .{
        \\        .{
        \\            .name = "../../etc",
        \\            .extension = ".zig",
        \\            .mode = .copy_and_scan,
        \\        },
        \\    },
        \\}
    );

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const result = loadFromDir(testing.allocator, tmp_path, "evil");
    try testing.expectError(error.PluginManifestUnsafeDirName, result);
}

test "loadFromDir: rejects absolute path in convention_dir name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeManifestFile(tmp.dir,
        \\.{
        \\    .name = "evil",
        \\    .manifest_version = 1,
        \\    .convention_dirs = .{
        \\        .{
        \\            .name = "/tmp/absolute",
        \\            .extension = ".zig",
        \\            .mode = .copy_and_scan,
        \\        },
        \\    },
        \\}
    );

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const result = loadFromDir(testing.allocator, tmp_path, "evil");
    try testing.expectError(error.PluginManifestUnsafeDirName, result);
}

test "loadFromDir: rejects copy_and_scan without extension" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeManifestFile(tmp.dir,
        \\.{
        \\    .name = "fsm",
        \\    .manifest_version = 1,
        \\    .convention_dirs = .{
        \\        .{
        \\            .name = "state_machines",
        \\            .mode = .copy_and_scan,
        \\        },
        \\    },
        \\}
    );

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const result = loadFromDir(testing.allocator, tmp_path, "fsm");
    try testing.expectError(error.PluginManifestMissingExtension, result);
}

test "loadFromDir: parses Phase-2 .resources/.packs/depends_on_resources/license/author (#576)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Asset-Plugins Phase 2: a full plugin declares its OWN atlases, bundles
    // nested packs, overlays game atlases, and carries provenance metadata.
    try writeManifestFile(tmp.dir,
        \\.{
        \\    .name = "dungeon_kit",
        \\    .manifest_version = 1,
        \\    .license = "MIT",
        \\    .author = "acme",
        \\    .resources = .{
        \\        .{ .name = "ui", .json = "assets/ui.json", .texture = "assets/ui.png" },
        \\    },
        \\    .packs = .{ "dungeon", "props" },
        \\    .depends_on_resources = .{ "characters" },
        \\}
    );

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var manifest = (try loadFromDir(testing.allocator, tmp_path, "dungeon_kit")).?;
    defer manifest.deinit();

    try testing.expectEqual(@as(usize, 1), manifest.resources.len);
    try testing.expectEqualStrings("ui", manifest.resources[0].name);
    try testing.expectEqualStrings("assets/ui.json", manifest.resources[0].json);
    try testing.expectEqual(@as(usize, 2), manifest.packs.len);
    try testing.expectEqualStrings("dungeon", manifest.packs[0]);
    try testing.expectEqualStrings("props", manifest.packs[1]);
    try testing.expectEqual(@as(usize, 1), manifest.depends_on_resources.len);
    try testing.expectEqualStrings("characters", manifest.depends_on_resources[0]);
    try testing.expectEqualStrings("MIT", manifest.license.?);
    try testing.expectEqualStrings("acme", manifest.author.?);
}

test "loadFromDir: Phase-2 fields absent → empty/null (byte-identity default)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeManifestFile(tmp.dir,
        \\.{ .name = "code_only", .manifest_version = 1 }
    );

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var manifest = (try loadFromDir(testing.allocator, tmp_path, "code_only")).?;
    defer manifest.deinit();

    try testing.expectEqual(@as(usize, 0), manifest.resources.len);
    try testing.expectEqual(@as(usize, 0), manifest.packs.len);
    try testing.expectEqual(@as(usize, 0), manifest.depends_on_resources.len);
    try testing.expect(manifest.license == null);
    try testing.expect(manifest.author == null);
    try testing.expect(manifest.requires_language == null); // #584
}

test "loadFromDir: parses requires_language (#584)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A plugin whose shipped scripts are Lua declares the requirement
    // (symmetric with depends_on_resources); the attach-time match against
    // the project's `.params.language` runs in the generate gate.
    try writeManifestFile(tmp.dir,
        \\.{
        \\    .name = "lua_toolkit",
        \\    .manifest_version = 1,
        \\    .requires_language = "lua",
        \\}
    );

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var manifest = (try loadFromDir(testing.allocator, tmp_path, "lua_toolkit")).?;
    defer manifest.deinit();

    try testing.expectEqualStrings("lua", manifest.requires_language.?);
}

test "loadFromDir: rejects an unknown requires_language (#584)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeManifestFile(tmp.dir,
        \\.{
        \\    .name = "lua_toolkit",
        \\    .manifest_version = 1,
        \\    .requires_language = "cobol",
        \\}
    );

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const result = loadFromDir(testing.allocator, tmp_path, "lua_toolkit");
    try testing.expectError(error.PluginManifestUnknownLanguage, result);
}

test "loadFromDir: rejects a nested pack name that escapes the plugin dir (#576)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A `.packs` entry is joined into `<plugin>/packs/<name>/` — a traversal
    // segment would let a plugin reach outside its own tree.
    try writeManifestFile(tmp.dir,
        \\.{
        \\    .name = "evil",
        \\    .manifest_version = 1,
        \\    .packs = .{ "../../etc" },
        \\}
    );

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const result = loadFromDir(testing.allocator, tmp_path, "evil");
    try testing.expectError(error.PluginManifestUnsafeDirName, result);
}

test "loadFromDir: ignore_unknown_fields allows forward-compat manifests" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A future v1-compatible manifest that adds a hypothetical `author`
    // field. An older CLI should silently ignore the unknown field and
    // still load the rest of the manifest.
    try writeManifestFile(tmp.dir,
        \\.{
        \\    .name = "fsm",
        \\    .manifest_version = 1,
        \\    .author = "future-you",
        \\    .convention_dirs = .{
        \\        .{
        \\            .name = "state_machines",
        \\            .extension = ".zig",
        \\            .mode = .copy_and_scan,
        \\        },
        \\    },
        \\}
    );

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var manifest = (try loadFromDir(testing.allocator, tmp_path, "fsm")).?;
    defer manifest.deinit();

    try testing.expectEqualStrings("fsm", manifest.name);
    try testing.expectEqual(@as(usize, 1), manifest.convention_dirs.len);
}
