/// labelle-cli generator — reads project.labelle, outputs .labelle/ assembler files.
/// Thin orchestrator that delegates to focused submodules.
const std = @import("std");

// ── Submodules ─────────────────────────────────────────────────────────
const config = @import("config.zig");
const cache = @import("cache.zig");
pub const scanner = @import("scanner.zig");
pub const scene_manifest = @import("scene_manifest.zig");
pub const asset_validator = @import("asset_validator.zig");
pub const lazy_inference = @import("lazy_inference.zig");
const main_zig = @import("main_zig.zig");
pub const script_scanner = @import("script_scanner.zig");
const build_files = @import("build_files.zig");
pub const template = @import("template.zig");
pub const plugin_manifest = @import("plugin_manifest.zig");
const gui_resolve = @import("gui_resolve.zig");

// Force test discovery for files that aren't transitively reached by
// any compiled function path during `addTest` runs.
test {
    _ = @import("plugin_manifest.zig");
    _ = @import("scene_manifest.zig");
    _ = @import("asset_validator.zig");
    _ = @import("lazy_inference.zig");
}

// ── Re-exports (preserve public API for tests and consumers) ──────────
pub const Backend = config.Backend;
pub const Platform = config.Platform;
pub const EcsChoice = config.EcsChoice;
pub const GuiPlugin = config.GuiPlugin;
pub const ResolvedGui = config.ResolvedGui;
pub const RenderingMode = config.RenderingMode;
pub const GuiLifecycle = config.GuiLifecycle;
pub const PluginDep = config.PluginDep;
pub const IosConfig = config.IosConfig;
pub const AndroidConfig = config.AndroidConfig;
pub const Orientation = config.Orientation;
pub const LayerSpace = config.LayerSpace;
pub const LayerDef = config.LayerDef;
pub const ResourceDef = config.ResourceDef;
pub const ProjectConfig = config.ProjectConfig;
pub const CLI_VERSION = config.CLI_VERSION;
pub const CORE_VERSION = config.CORE_VERSION;
pub const ENGINE_VERSION = config.ENGINE_VERSION;
pub const GFX_VERSION = config.GFX_VERSION;
pub const isLocalVersion = config.isLocalVersion;

pub const resolveGuiPlugin = gui_resolve.resolveGuiPlugin;

pub const generateMainZigFromTemplate = main_zig.generateMainZigFromTemplate;
pub const generateBuildZig = build_files.generateBuildZig;
pub const generateBuildZigZon = build_files.generateBuildZigZon;
pub const deps_linker = build_files.deps_linker;

pub const validateCache = cache.validateCache;
pub const getCacheRoot = cache.getCacheRoot;
pub const getPackagesDir = cache.getPackagesDir;
pub const populateAssemblerCache = cache.populateAssemblerCache;
pub const populateFrameworkPackage = cache.populateFrameworkPackage;
pub const populatePlugin = cache.populatePlugin;
pub const isFrameworkCached = cache.isFrameworkCached;
pub const isAssemblerCached = cache.isAssemblerCached;
pub const isPluginCached = cache.isPluginCached;
pub const fetchFrameworkPackage = cache.fetchFrameworkPackage;
pub const fetchPlugin = cache.fetchPlugin;
pub const fetchAssemblerPackages = cache.fetchAssemblerPackages;
pub const R2_BASE_URL = cache.R2_BASE_URL;
pub const patchCachedDeps = cache.patchCachedDeps;
pub const resolvePlugin = cache.resolvePlugin;
pub const resolveAssemblerPackage = cache.resolveAssemblerPackage;
pub const resolveBundledPackage = cache.resolveBundledPackage;

/// Generate all assembler files into output_dir/.labelle/{backend}_{platform}/.
pub fn generate(allocator: std.mem.Allocator, cfg_in: ProjectConfig, output_dir: []const u8, game_dir: []const u8) !void {
    // Shadow the caller's cfg with a mutable copy. Ticket #48's lazy
    // default-inference pass needs to rewrite `cfg.resources[i].lazy`
    // in place, and we don't want to surprise callers by touching
    // their parsed slice.
    var cfg = cfg_in;
    const mutable_resources = try allocator.dupe(ResourceDef, cfg.resources);
    defer allocator.free(mutable_resources);
    cfg.resources = mutable_resources;

    const cwd = std.fs.cwd();

    // Target subfolder: .labelle/raylib_desktop/, .labelle/sokol_ios/, etc.
    const target_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ @tagName(cfg.backend), @tagName(cfg.platform) });
    defer allocator.free(target_name);
    const target_dir = try std.fs.path.join(allocator, &.{ output_dir, target_name });
    defer allocator.free(target_dir);
    try cwd.makePath(target_dir);

    // Load backend lifecycle template
    const backend_tmpl = try loadBackendTemplate(allocator, game_dir, cfg);
    defer allocator.free(backend_tmpl);

    // Copy game folders into target dir and scan file stems in one pass.
    // Folders that need scanning use copyAndScan; assets is copy-only.
    const prefab_names = try scanner.copyAndScan(allocator, game_dir, target_dir, "prefabs", ".jsonc");
    defer scanner.freeNames(allocator, prefab_names);

    const jsonc_scene_names = try scanner.copyAndScan(allocator, game_dir, target_dir, "scenes", ".jsonc");
    defer scanner.freeNames(allocator, jsonc_scene_names);

    // Parse each scene file's top-level manifest (assets: array + unknown-key
    // guard). Reads the *copied* scenes from target_dir so parser errors point
    // at the same files the engine will load. Hard-aborts on typos like
    // "asest" so a misspelled key cannot silently disable preloading.
    const scenes_target = try std.fs.path.join(allocator, &.{ target_dir, "scenes" });
    defer allocator.free(scenes_target);
    const scene_manifests = try scene_manifest.parseSceneDir(allocator, scenes_target, jsonc_scene_names);
    defer scene_manifest.freeManifests(allocator, scene_manifests);

    // Reject scene `assets:` entries that don't match a resource
    // declared in project.labelle. Runs before any codegen so typos
    // like `backgroud` surface as a build error against the scene file
    // rather than a confusing "atlas not found" panic at runtime.
    // Ticket #47.
    try asset_validator.validateSceneAssets(allocator, scene_manifests, cfg.resources);

    // Resolve the implicit `lazy` default on each resource entry.
    // Explicit `lazy = true/false` wins; null falls back to `true`
    // (lazy) when the resource is referenced by any scene's `assets:`
    // list, or to `false` (eager) otherwise. The eager fallback keeps
    // unmigrated projects — the ones without `assets:` blocks — using
    // the old always-eager behavior. Ticket #48.
    try lazy_inference.resolveLazyDefaults(allocator, mutable_resources, scene_manifests);

    // Copy all script files (including subdirectories) into target dir.
    // Then use ScriptScanner to parse directory-based state binding.
    const script_names_unused = try scanner.copyAndScan(allocator, game_dir, target_dir, "scripts", ".zig");
    scanner.freeNames(allocator, script_names_unused);

    const scripts_target = try std.fs.path.join(allocator, &.{ target_dir, "scripts" });
    defer allocator.free(scripts_target);
    var script_scan = script_scanner.ScriptScanner.init(allocator, cfg.states);
    defer script_scan.deinit();
    try script_scan.scanDir(scripts_target);
    const script_entries = script_scan.getEntries();

    const component_names = try scanner.copyAndScan(allocator, game_dir, target_dir, "components", ".zig");
    defer scanner.freeNames(allocator, component_names);

    const hook_names = try scanner.copyAndScan(allocator, game_dir, target_dir, "hooks", ".zig");
    defer scanner.freeNames(allocator, hook_names);

    const event_names = try scanner.copyAndScan(allocator, game_dir, target_dir, "events", ".zig");
    defer scanner.freeNames(allocator, event_names);

    const enum_names = try scanner.copyAndScan(allocator, game_dir, target_dir, "enums", ".zig");
    defer scanner.freeNames(allocator, enum_names);

    const view_names = try scanner.copyAndScan(allocator, game_dir, target_dir, "views", ".zon");
    defer scanner.freeNames(allocator, view_names);

    const gizmo_names = try scanner.copyAndScan(allocator, game_dir, target_dir, "gizmos", ".zon");
    defer scanner.freeNames(allocator, gizmo_names);

    const animation_names = try scanner.copyAndScan(allocator, game_dir, target_dir, "animations", ".zon");
    defer scanner.freeNames(allocator, animation_names);

    // Copy-only folders (no scanning needed)
    try scanner.copyDirRecursive(allocator, game_dir, target_dir, "assets");

    // ── Plugin-declared convention directories ────────────────────────
    // Each plugin in cfg.plugins may ship a `plugin.labelle` manifest at
    // its root that declares additional directories the CLI should copy
    // and/or scan from the game project. See
    // `docs/RFC-plugin-manifest.md` for the design.
    //
    // The manifest is read regardless of `plugin.states` (game-state
    // gating affects runtime, not generate-time layout). Missing source
    // directories are silently tolerated, matching the behavior of the
    // hardcoded scans above.
    //
    // Duplicate directory declarations across plugins are a hard error
    // (RFC E3). A single name can be claimed by exactly one plugin to
    // keep the "who owns this directory" story unambiguous and prevent
    // conflicting copy passes.
    //
    // All manifests are loaded first and kept alive until every copy
    // pass has run, so the duplicate-detection hash map (which stores
    // slices into parsed manifest memory) stays valid across plugins.
    //
    // Pre-reserve capacity up front so the per-plugin append cannot
    // fail. If we used a fallible append, a successful loadOptional
    // followed by an OOM-on-resize would leak the parsed manifest
    // (it wouldn't have made it into the cleanup list).
    var loaded_manifests = std.ArrayListUnmanaged(plugin_manifest.PluginManifest){};
    defer {
        for (loaded_manifests.items) |*m| m.deinit();
        loaded_manifests.deinit(allocator);
    }
    try loaded_manifests.ensureTotalCapacity(allocator, cfg.plugins.len);

    var owner_of_dir = std.StringHashMapUnmanaged([]const u8){};
    defer owner_of_dir.deinit(allocator);

    for (cfg.plugins) |plugin| {
        const maybe_manifest = try plugin_manifest.loadOptional(allocator, plugin, game_dir);
        const manifest = maybe_manifest orelse continue;
        // Capacity was reserved above — this cannot fail, so there's
        // no window where `manifest` is owned but outside the cleanup
        // list's reach.
        loaded_manifests.appendAssumeCapacity(manifest);

        for (manifest.convention_dirs) |dir| {
            // Duplicate detection is *cross-plugin only*. A single plugin
            // is allowed to declare the same directory name in multiple
            // convention_dirs entries with different extensions — that's
            // the RFC Q3 multi-extension pattern (e.g. a plugin wanting
            // both .zig and .zon files under state_machines/). Only error
            // when a different plugin already claimed the name.
            if (owner_of_dir.get(dir.name)) |prev_owner| {
                if (!std.mem.eql(u8, prev_owner, plugin.name)) {
                    std.debug.print(
                        "labelle: two plugins want the same convention directory '{s}':\n  - plugin '{s}' already declared it\n  - plugin '{s}' is trying to declare it again\n  each plugin must use a unique directory name\n",
                        .{ dir.name, prev_owner, plugin.name },
                    );
                    return error.PluginManifestDuplicateDir;
                }
                // Same plugin re-declaring the name (multi-extension) —
                // don't overwrite the claim, just keep going and let the
                // copy pass below handle it.
            } else {
                try owner_of_dir.put(allocator, dir.name, plugin.name);
            }

            switch (dir.mode) {
                .copy_and_scan => {
                    // `extension` is required for copy_and_scan and is
                    // validated by plugin_manifest.loadFromDir at load
                    // time, so .? here is safe.
                    const ext = dir.extension.?;
                    const names = try scanner.copyAndScan(
                        allocator,
                        game_dir,
                        target_dir,
                        dir.name,
                        ext,
                    );
                    // v1: name list is computed but not exposed to codegen.
                    // Future RFC will decide how plugins drive main.zig
                    // generation from these names.
                    scanner.freeNames(allocator, names);
                },
                .copy_only => {
                    try scanner.copyDirRecursive(
                        allocator,
                        game_dir,
                        target_dir,
                        dir.name,
                    );
                },
                .ship_from_plugin => {
                    // Plugin-shipped content: source dir lives in the
                    // plugin's cached package rather than the consuming
                    // game. Resolves the plugin's path up-front because
                    // copyAndScan takes a base and a folder-under-base.
                    // Silently skips if the plugin doesn't actually ship
                    // the declared directory — matches copy_and_scan's
                    // missing-source tolerance so a plugin author can
                    // declare the convention eagerly and ship content
                    // incrementally.
                    const ext = dir.extension.?;
                    const plugin_src_dir = try cache.resolvePlugin(allocator, plugin, game_dir);
                    defer allocator.free(plugin_src_dir);
                    const names = try scanner.copyAndScan(
                        allocator,
                        plugin_src_dir,
                        target_dir,
                        dir.name,
                        ext,
                    );
                    scanner.freeNames(allocator, names);
                },
            }
        }
    }

    // ── Plugin-shipped scripts (RFC-plugin-controllers §2, step-1 half 3) ─
    //
    // A plugin can ship its own `scripts/` directory that the assembler
    // copies into the generated build alongside the game's own `scripts/`.
    // These are discovered via a convention — any plugin that has a
    // top-level `scripts/` dir in its cached package contributes scripts —
    // rather than via an explicit `plugin.labelle` entry, because `scripts`
    // is a reserved convention name (see RESERVED_DIR_NAMES) that the
    // plugin manifest already forbids plugins from claiming.
    //
    // Layout in the generated target:
    //   <target>/scripts/                         ← game's own scripts (unchanged)
    //   <target>/scripts/.plugin_<name>/<rel>     ← each plugin's scripts,
    //                                               isolated per plugin so
    //                                               they form their own
    //                                               numeric-prefix scope
    //
    // Scanning is driven by the `ScriptScanner` (see addPluginBlock below),
    // so the duplicate-prefix validator treats each plugin block as
    // independent. Cross-plugin prefix collisions are impossible by
    // construction. Game-vs-plugin collisions are also impossible — the
    // game scripts live under `scripts/` while plugin scripts live under
    // `scripts/.plugin_<name>/`, which the scanner treats as a different
    // namespace.
    //
    // Plugins without a `scripts/` dir contribute nothing — backward-compat
    // with every existing plugin (labelle-fsm, labelle-pathfinding today).
    for (cfg.plugins) |plugin| {
        const plugin_src_dir = cache.resolvePlugin(allocator, plugin, game_dir) catch continue;
        defer allocator.free(plugin_src_dir);

        const plugin_scripts_src = try std.fs.path.join(allocator, &.{ plugin_src_dir, "scripts" });
        defer allocator.free(plugin_scripts_src);

        // Probe for existence — plugins without a `scripts/` dir are the
        // norm and must not error.
        _ = cwd.openDir(plugin_scripts_src, .{}) catch continue;

        // Destination: `<target>/scripts/.plugin_<name>/`. The leading `.`
        // prevents accidental collision with a game state directory (states
        // must be lowercase alphanumeric + `_`, per `isValidStateName`, so
        // `.plugin_foo` can never be mistaken for a state dir by the
        // scanner).
        const plugin_dst_subdir = try std.fmt.allocPrint(allocator, ".plugin_{s}", .{plugin.name});
        defer allocator.free(plugin_dst_subdir);
        const plugin_scripts_dst = try std.fs.path.join(allocator, &.{ target_dir, "scripts", plugin_dst_subdir });
        defer allocator.free(plugin_scripts_dst);

        const names = try scanner.copyAndScanAbs(
            allocator,
            plugin_scripts_src,
            plugin_scripts_dst,
            ".zig",
        );
        scanner.freeNames(allocator, names);

        // Feed the plugin's scripts into the scanner as a new block,
        // isolated under the plugin's namespace so the duplicate-prefix
        // validator treats it independently of the game block.
        try script_scan.scanPluginDir(plugin_scripts_dst, plugin.name);
    }

    // Generate build.zig.zon
    const zon = try build_files.generateBuildZigZon(allocator, cfg, target_dir, output_dir, game_dir);
    defer allocator.free(zon);
    try scanner.writeFile(target_dir, "build.zig.zon", zon);

    // Generate build.zig
    const build_zig = try build_files.generateBuildZig(allocator, cfg);
    defer allocator.free(build_zig);
    try scanner.writeFile(target_dir, "build.zig", build_zig);

    // Generate main.zig — load engine template from codegen/ directory
    const engine_template = try loadEngineTemplate(allocator, game_dir, cfg);
    defer allocator.free(engine_template);
    const main_zig_content = try main_zig.generateMainZigFromTemplate(allocator, engine_template, cfg, backend_tmpl, script_entries, prefab_names, jsonc_scene_names, scene_manifests, component_names, hook_names, event_names, enum_names, view_names, gizmo_names, animation_names);
    defer allocator.free(main_zig_content);
    try scanner.writeFile(target_dir, "main.zig", main_zig_content);
}

/// Load the engine's main.zig template from the codegen/ directory.
fn loadEngineTemplate(allocator: std.mem.Allocator, game_dir: []const u8, cfg: ProjectConfig) ![]const u8 {
    const engine_path = try cache.resolveFrameworkPackage(allocator, "engine", cfg.engine_version, game_dir);
    defer allocator.free(engine_path);

    const tmpl_path = try std.fs.path.join(allocator, &.{ engine_path, "codegen", "main.zig.template" });
    defer allocator.free(tmpl_path);

    return std.fs.cwd().readFileAlloc(allocator, tmpl_path, 256 * 1024) catch |err| {
        std.debug.print("labelle: could not read engine template '{s}': {any}\n", .{ tmpl_path, err });
        return error.EngineTemplateNotFound;
    };
}

/// Load the backend+platform lifecycle template from the CLI cache.
fn loadBackendTemplate(allocator: std.mem.Allocator, game_dir: []const u8, cfg: ProjectConfig) ![]const u8 {
    const backend_name = @tagName(cfg.backend);
    const platform_name = if (cfg.backend == .sokol and (cfg.platform == .ios or cfg.platform == .android))
        "mobile"
    else if (cfg.backend == .sokol and cfg.platform == .wasm)
        "desktop" // sokol uses a single template for desktop and wasm
    else
        @tagName(cfg.platform);
    const tmpl_filename = try std.fmt.allocPrint(allocator, "{s}.txt", .{platform_name});
    defer allocator.free(tmpl_filename);

    // Resolve backend path from the assembler cache slot.
    var backend_subpath_buf: [128]u8 = undefined;
    const backend_subpath = std.fmt.bufPrint(&backend_subpath_buf, "backends/{s}", .{backend_name}) catch unreachable;
    const backend_path = try cache.resolveBundledPackage(allocator, cfg.labelle_version, cfg.assembler_version, game_dir, backend_subpath);
    defer allocator.free(backend_path);

    const tmpl_path = try std.fs.path.join(allocator, &.{ backend_path, "templates", tmpl_filename });
    defer allocator.free(tmpl_path);

    return std.fs.cwd().readFileAlloc(allocator, tmpl_path, 64 * 1024) catch |err| {
        std.debug.print("labelle: could not read backend template '{s}': {any}\n", .{ tmpl_path, err });
        return error.TemplateNotFound;
    };
}
