//! Cache-management subcommands for the labelle-assembler binary.
//!
//! Issue #217, phase 1 — the `labelle` CLI used to carry compiled-in copies
//! of this logic (it imported the assembler's `generator` module and called
//! `cache.fetchPlugin` / `cache.validateCache` / `cache.populate*` in
//! process). The assembler owns `cache.zig`, so it now also owns the
//! *commands* that drive it: `install`, `clean`, `upgrade`. The CLI shells
//! out to `labelle-assembler <subcommand>` instead.
//!
//! Each handler mirrors `main.zig:cmdGenerate` — it parses its own args,
//! prints diagnostics to stderr/stdout, and exits non-zero on failure so
//! the CLI can propagate the exit code.
//!
//! Not handled here: the `assembler` binary itself. `install assembler
//! <version>` and `upgrade assembler` download/pin the assembler *binary*,
//! which is a chicken-and-egg problem (the assembler can't fetch itself).
//! That stays in the CLI bootstrap. These handlers reject an `assembler`
//! package argument with a clear message.

const std = @import("std");
const gen = @import("root.zig");
const cache = @import("cache.zig");
const config = @import("config.zig");

/// Write directly to stderr without a level prefix. Matches main.zig.
fn writeStderr(io: std.Io, msg: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
}

// ── install ──────────────────────────────────────────────────────────

const install_usage =
    \\labelle-assembler install — fetch packages into the local cache
    \\
    \\Usage:
    \\  labelle-assembler install --project-root <path>   Install deps for a project
    \\  labelle-assembler install <pkg> <version>         Cache a specific package
    \\  labelle-assembler install <version>               Cache core+engine+gfx at a version
    \\
    \\Packages: core, engine, gfx
    \\
;

/// `install` subcommand. Three forms, matching the legacy CLI behavior:
///   install --project-root <p>   → ensure every dep in project.labelle is cached
///   install <pkg> <version>      → cache one framework package
///   install <version>            → cache core/engine/gfx at one version
pub fn cmdInstall(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    var project_root: ?[]const u8 = null;
    var positionals: std.ArrayList([]const u8) = .empty;
    defer positionals.deinit(allocator);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--project-root")) {
            project_root = args.next() orelse {
                std.log.err("labelle-assembler install: --project-root requires a value", .{});
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, arg, "--project-root=")) {
            project_root = arg["--project-root=".len..];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            writeStderr(io, install_usage);
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.log.err("labelle-assembler install: unknown flag '{s}'", .{arg});
            std.process.exit(2);
        } else {
            try positionals.append(allocator, arg);
        }
    }

    // Form 1: install deps for a project.
    if (positionals.items.len == 0) {
        const root = project_root orelse {
            writeStderr(io, install_usage);
            std.process.exit(2);
        };
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const cfg = readProjectConfig(arena.allocator(), io, root) catch {
            std.log.err("labelle-assembler install: failed to read project.labelle in '{s}'", .{root});
            std.process.exit(1);
        };
        ensureCache(allocator, cfg) catch |err| {
            std.log.err("labelle-assembler install: {s}", .{@errorName(err)});
            std.process.exit(1);
        };
        std.log.info("labelle-assembler: all packages cached", .{});
        return;
    }

    // Reject the `assembler` package — the CLI owns binary bootstrap.
    if (std.mem.eql(u8, positionals.items[0], "assembler")) {
        std.log.err("labelle-assembler install: the 'assembler' package is managed by the labelle CLI bootstrap, not the assembler binary", .{});
        std.process.exit(2);
    }

    // Form 3: install <version> — cache core/engine/gfx at one version.
    if (positionals.items.len == 1) {
        const version = positionals.items[0];
        std.log.info("labelle-assembler: caching core/engine/gfx at version {s}", .{version});
        const packages = [_][]const u8{ "core", "engine", "gfx" };
        for (packages) |pkg| {
            if (!try cache.isFrameworkCached(allocator, pkg, version)) {
                fetchFrameworkWithFallback(allocator, pkg, version) catch |err| {
                    std.log.err("labelle-assembler install: failed to fetch {s} {s}: {s}", .{ pkg, version, @errorName(err) });
                    std.process.exit(1);
                };
            } else {
                std.log.info("  {s} {s} already cached", .{ pkg, version });
            }
        }
        std.log.info("labelle-assembler: done", .{});
        return;
    }

    // Form 2: install <pkg> <version>.
    const pkg_name = positionals.items[0];
    const version = positionals.items[1];
    if (std.mem.eql(u8, pkg_name, "core") or
        std.mem.eql(u8, pkg_name, "engine") or
        std.mem.eql(u8, pkg_name, "gfx"))
    {
        std.log.info("labelle-assembler: fetching {s} {s}", .{ pkg_name, version });
        fetchFrameworkWithFallback(allocator, pkg_name, version) catch |err| {
            std.log.err("labelle-assembler install: failed to fetch {s}: {s}", .{ pkg_name, @errorName(err) });
            std.process.exit(1);
        };
    } else {
        std.log.err("labelle-assembler install: unknown package '{s}' (known: core, engine, gfx)", .{pkg_name});
        std.process.exit(2);
    }
    std.log.info("labelle-assembler: done", .{});
}

// ── clean ────────────────────────────────────────────────────────────

const clean_usage =
    \\labelle-assembler clean — prune unused cached package versions
    \\
    \\Usage:
    \\  labelle-assembler clean [--dry-run] [--project-root <path>]
    \\
    \\Keeps the versions referenced by project.labelle (if found) plus the
    \\assembler's built-in default versions; removes everything else under
    \\~/.labelle/packages/.
    \\
;

/// `clean` subcommand. Removes cached package versions that are neither
/// the assembler's built-in defaults nor referenced by project.labelle.
pub fn cmdClean(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    var dry_run = false;
    var project_root: []const u8 = ".";

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--project-root")) {
            project_root = args.next() orelse {
                std.log.err("labelle-assembler clean: --project-root requires a value", .{});
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, arg, "--project-root=")) {
            project_root = arg["--project-root=".len..];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            writeStderr(io, clean_usage);
            return;
        } else {
            std.log.err("labelle-assembler clean: unknown option '{s}'", .{arg});
            writeStderr(io, "\n" ++ clean_usage);
            std.process.exit(2);
        }
    }

    const packages_dir = cache.getPackagesDir(allocator) catch {
        std.log.err("labelle-assembler clean: could not determine packages directory", .{});
        std.process.exit(1);
    };
    defer allocator.free(packages_dir);

    std.log.info("labelle-assembler: scanning {s}", .{packages_dir});

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var kept = std.StringHashMap(std.StringHashMap(void)).init(arena_alloc);

    const pkg_names = [_][]const u8{ "core", "engine", "gfx", "cli" };
    const default_versions = [_][]const u8{
        gen.CORE_VERSION, gen.ENGINE_VERSION, gen.GFX_VERSION, gen.CLI_VERSION,
    };
    for (pkg_names, 0..) |name, i| {
        var version_set = std.StringHashMap(void).init(arena_alloc);
        try version_set.put(default_versions[i], {});
        try kept.put(name, version_set);
    }

    if (readProjectConfigQuiet(arena_alloc, io, project_root)) |cfg| {
        const project_refs = [_]struct { name: []const u8, version: []const u8 }{
            .{ .name = "core", .version = cfg.core_version },
            .{ .name = "engine", .version = cfg.engine_version },
            .{ .name = "gfx", .version = cfg.gfx_version },
            .{ .name = "cli", .version = cfg.labelle_version },
        };
        for (project_refs) |ref| {
            if (config.isLocalVersion(ref.version)) continue;
            if (kept.getPtr(ref.name)) |set| try set.put(ref.version, {});
        }
        std.log.info("  found project.labelle in '{s}'", .{project_root});
    } else |_| {
        std.log.info("  no project.labelle found — keeping default versions only", .{});
    }

    var removed_count: u32 = 0;
    for (pkg_names) |pkg_name| {
        const pkg_dir_path = std.fs.path.join(arena_alloc, &.{ packages_dir, pkg_name }) catch continue;

        var pkg_dir = std.Io.Dir.cwd().openDir(io, pkg_dir_path, .{ .iterate = true }) catch continue;
        defer pkg_dir.close(io);

        const version_set = kept.get(pkg_name) orelse continue;

        var it = pkg_dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .directory and entry.kind != .sym_link) continue;
            if (version_set.contains(entry.name)) continue;

            if (dry_run) {
                std.log.info("  would remove {s}/{s}", .{ pkg_name, entry.name });
            } else {
                const full_path = std.fs.path.join(arena_alloc, &.{ pkg_dir_path, entry.name }) catch continue;
                if (entry.kind == .sym_link) {
                    std.Io.Dir.cwd().deleteFile(io, full_path) catch |err| {
                        std.log.warn("  could not remove {s}/{s}: {s}", .{ pkg_name, entry.name, @errorName(err) });
                        continue;
                    };
                } else {
                    std.Io.Dir.cwd().deleteTree(io, full_path) catch |err| {
                        std.log.warn("  could not remove {s}/{s}: {s}", .{ pkg_name, entry.name, @errorName(err) });
                        continue;
                    };
                }
                std.log.info("  removed {s}/{s}", .{ pkg_name, entry.name });
            }
            removed_count += 1;
        }
    }

    if (removed_count == 0) {
        std.log.info("  nothing to clean", .{});
    } else if (dry_run) {
        std.log.info("  {d} version(s) would be removed (run without --dry-run to delete)", .{removed_count});
    } else {
        std.log.info("  cleaned {d} old version(s)", .{removed_count});
    }
}

// ── upgrade ──────────────────────────────────────────────────────────

const upgrade_usage =
    \\labelle-assembler upgrade — bump version fields in project.labelle
    \\
    \\Usage:
    \\  labelle-assembler upgrade --project-root <path> [pkg [version]]
    \\
    \\Packages: core, engine, gfx, cli, all
    \\  (no pkg)   upgrade core/engine/gfx/cli to the assembler's defaults
    \\  <pkg>      upgrade one package (to <version>, or the default if omitted)
    \\
;

/// `upgrade` subcommand. Rewrites version fields in project.labelle.
/// The `assembler` package is intentionally not handled here — pinning
/// the assembler binary version is a CLI-bootstrap concern.
pub fn cmdUpgrade(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    var project_root: ?[]const u8 = null;
    var positionals: std.ArrayList([]const u8) = .empty;
    defer positionals.deinit(allocator);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--project-root")) {
            project_root = args.next() orelse {
                std.log.err("labelle-assembler upgrade: --project-root requires a value", .{});
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, arg, "--project-root=")) {
            project_root = arg["--project-root=".len..];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            writeStderr(io, upgrade_usage);
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.log.err("labelle-assembler upgrade: unknown flag '{s}'", .{arg});
            std.process.exit(2);
        } else {
            try positionals.append(allocator, arg);
        }
    }

    const root = project_root orelse {
        std.log.err("labelle-assembler upgrade: --project-root is required", .{});
        std.process.exit(2);
    };

    if (positionals.items.len > 0 and std.mem.eql(u8, positionals.items[0], "assembler")) {
        std.log.err("labelle-assembler upgrade: 'assembler' is pinned by the labelle CLI bootstrap, not the assembler binary", .{});
        std.process.exit(2);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const cfg = readProjectConfig(arena_alloc, io, root) catch {
        std.log.err("labelle-assembler upgrade: failed to read project.labelle in '{s}'", .{root});
        std.process.exit(1);
    };

    const labelle_path = try std.fs.path.join(arena_alloc, &.{ root, "project.labelle" });
    var content = std.Io.Dir.cwd().readFileAlloc(io, labelle_path, arena_alloc, .limited(1024 * 1024)) catch {
        std.log.err("labelle-assembler upgrade: could not read '{s}'", .{labelle_path});
        std.process.exit(1);
    };

    if (positionals.items.len == 0) {
        std.log.info("labelle-assembler: upgrading to compatible set (core={s}, engine={s}, gfx={s}, cli={s})", .{
            gen.CORE_VERSION, gen.ENGINE_VERSION, gen.GFX_VERSION, gen.CLI_VERSION,
        });
        content = try replaceVersionField(arena_alloc, content, "core_version", cfg.core_version, gen.CORE_VERSION);
        content = try replaceVersionField(arena_alloc, content, "engine_version", cfg.engine_version, gen.ENGINE_VERSION);
        content = try replaceVersionField(arena_alloc, content, "gfx_version", cfg.gfx_version, gen.GFX_VERSION);
        content = try replaceVersionField(arena_alloc, content, "labelle_version", cfg.labelle_version, gen.CLI_VERSION);
    } else {
        const pkg = positionals.items[0];
        const default_version: []const u8 = if (std.mem.eql(u8, pkg, "core"))
            gen.CORE_VERSION
        else if (std.mem.eql(u8, pkg, "engine"))
            gen.ENGINE_VERSION
        else if (std.mem.eql(u8, pkg, "gfx"))
            gen.GFX_VERSION
        else
            gen.CLI_VERSION;
        const version = if (positionals.items.len > 1) positionals.items[1] else default_version;

        if (std.mem.eql(u8, pkg, "core")) {
            content = try replaceVersionField(arena_alloc, content, "core_version", cfg.core_version, version);
        } else if (std.mem.eql(u8, pkg, "engine")) {
            content = try replaceVersionField(arena_alloc, content, "engine_version", cfg.engine_version, version);
        } else if (std.mem.eql(u8, pkg, "gfx")) {
            content = try replaceVersionField(arena_alloc, content, "gfx_version", cfg.gfx_version, version);
        } else if (std.mem.eql(u8, pkg, "labelle") or std.mem.eql(u8, pkg, "cli")) {
            content = try replaceVersionField(arena_alloc, content, "labelle_version", cfg.labelle_version, version);
        } else if (std.mem.eql(u8, pkg, "all")) {
            content = try replaceVersionField(arena_alloc, content, "core_version", cfg.core_version, gen.CORE_VERSION);
            content = try replaceVersionField(arena_alloc, content, "engine_version", cfg.engine_version, gen.ENGINE_VERSION);
            content = try replaceVersionField(arena_alloc, content, "gfx_version", cfg.gfx_version, gen.GFX_VERSION);
            content = try replaceVersionField(arena_alloc, content, "labelle_version", cfg.labelle_version, gen.CLI_VERSION);
        } else {
            std.log.err("labelle-assembler upgrade: unknown package '{s}' (packages: core, engine, gfx, cli, all)", .{pkg});
            std.process.exit(2);
        }
        std.log.info("labelle-assembler: upgrading {s} to {s}", .{ pkg, version });
    }

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = labelle_path, .data = content }) catch {
        std.log.err("labelle-assembler upgrade: could not write '{s}'", .{labelle_path});
        std.process.exit(1);
    };

    std.log.info("labelle-assembler: project.labelle updated", .{});
    std.log.info("  run 'labelle generate' to regenerate build files", .{});
}

/// Rewrite `.<field> = "<old>"` to `.<field> = "<new>"` in ZON content.
/// Returns the input unchanged when the field is absent. Arena-allocated;
/// the caller's arena owns the result.
fn replaceVersionField(
    allocator: std.mem.Allocator,
    content: []const u8,
    field_name: []const u8,
    old_value: []const u8,
    new_value: []const u8,
) ![]u8 {
    const search = try std.fmt.allocPrint(allocator, ".{s} = \"{s}\"", .{ field_name, old_value });
    const replace = try std.fmt.allocPrint(allocator, ".{s} = \"{s}\"", .{ field_name, new_value });
    if (std.mem.indexOf(u8, content, search)) |idx| {
        var result: std.ArrayList(u8) = .empty;
        try result.appendSlice(allocator, content[0..idx]);
        try result.appendSlice(allocator, replace);
        try result.appendSlice(allocator, content[idx + search.len ..]);
        return result.toOwnedSlice(allocator);
    }
    return try allocator.dupe(u8, content);
}

// ── cache population (ported from labelle-cli/src/cli/cache.zig) ──────

/// Ensure every dependency declared in `cfg` is present in the local cache.
/// No-op when the cache already validates.
pub fn ensureCache(allocator: std.mem.Allocator, cfg: config.ProjectConfig) !void {
    const missing = try cache.validateCache(allocator, cfg);
    defer {
        for (missing) |m| allocator.free(m);
        allocator.free(missing);
    }
    if (missing.len == 0) return;

    std.log.info("labelle-assembler: populating package cache", .{});

    const framework = [_]struct { name: []const u8, version: []const u8 }{
        .{ .name = "core", .version = cfg.core_version },
        .{ .name = "engine", .version = cfg.engine_version },
        .{ .name = "gfx", .version = cfg.gfx_version },
    };
    for (framework) |pkg| {
        if (!try cache.isFrameworkCached(allocator, pkg.name, pkg.version)) {
            try fetchFrameworkWithFallback(allocator, pkg.name, pkg.version);
        }
    }

    const asm_ver = cfg.assembler_version orelse cfg.labelle_version;
    if (!try cache.isAssemblerCached(allocator, asm_ver)) {
        try fetchAssemblerWithFallback(allocator, asm_ver);
    }

    for (cfg.plugins) |plugin| {
        if (!try cache.isPluginCached(allocator, plugin)) {
            try fetchPluginWithFallback(allocator, plugin);
        }
    }

    try cache.patchCachedDeps(allocator, cfg);
    std.log.info("  cache populated", .{});
}

/// Fetch a framework package: symlink from the monorepo checkout when the
/// assembler is running inside it, else shallow-clone from the repo.
fn fetchFrameworkWithFallback(allocator: std.mem.Allocator, name: []const u8, version: []const u8) !void {
    if (findRepoRoot(allocator)) |repo_root| {
        defer allocator.free(repo_root);
        const dir_name: []const u8 = if (std.mem.eql(u8, name, "core"))
            "labelle-core"
        else if (std.mem.eql(u8, name, "engine"))
            "labelle-engine"
        else if (std.mem.eql(u8, name, "gfx"))
            "labelle-gfx"
        else
            name;
        const src = try std.fs.path.join(allocator, &.{ repo_root, dir_name });
        defer allocator.free(src);
        if (cache.dirExists(src)) {
            std.log.info("  caching {s} {s} (local)", .{ name, version });
            try cache.populateFrameworkPackage(allocator, name, version, src);
            return;
        }
    }
    std.log.info("  fetching {s} {s} (remote)", .{ name, version });
    try cache.fetchFrameworkPackage(allocator, name, version);
}

/// Fetch assembler-bundled packages (backends, ecs, gui): symlink from the
/// monorepo when available, else clone the assembler repo at the tag.
fn fetchAssemblerWithFallback(allocator: std.mem.Allocator, version: []const u8) !void {
    if (findRepoRoot(allocator)) |repo_root| {
        defer allocator.free(repo_root);
        const companion = try std.fs.path.join(allocator, &.{ repo_root, "labelle-assembler" });
        defer allocator.free(companion);
        if (cache.dirExists(companion)) {
            std.log.info("  caching assembler {s} (local)", .{version});
            try cache.populateAssemblerCache(allocator, version, companion);
            return;
        }
    }
    std.log.info("  fetching assembler {s} (remote)", .{version});
    try cache.fetchAssemblerPackages(allocator, version);
}

/// Fetch a plugin: symlink from the monorepo when available, else clone.
fn fetchPluginWithFallback(allocator: std.mem.Allocator, plugin: config.PluginDep) !void {
    if (findRepoRoot(allocator)) |repo_root| {
        defer allocator.free(repo_root);
        const plugin_dir = try std.fmt.allocPrint(allocator, "labelle-{s}", .{plugin.name});
        defer allocator.free(plugin_dir);
        const src = try std.fs.path.join(allocator, &.{ repo_root, plugin_dir });
        defer allocator.free(src);
        if (cache.dirExists(src)) {
            std.log.info("  caching plugin {s} {s} (local)", .{ plugin.name, plugin.version });
            try cache.populatePlugin(allocator, plugin, src);
            return;
        }
    }
    std.log.info("  fetching plugin {s} {s} (remote)", .{ plugin.name, plugin.version });
    try cache.fetchPlugin(allocator, plugin);
}

/// Walk up from the assembler executable's directory looking for the
/// monorepo root (identified by a `labelle-core` sibling). Returns null
/// when the binary isn't running inside the monorepo checkout.
fn findRepoRoot(allocator: std.mem.Allocator) ?[]const u8 {
    const io = config.globalIo();
    const exe_path = std.process.executablePathAlloc(io, allocator) catch return null;
    defer allocator.free(exe_path);

    var dir = std.fs.path.dirname(exe_path) orelse return null;
    var depth: u8 = 0;
    while (depth < 6) : (depth += 1) {
        const marker = std.fs.path.join(allocator, &.{ dir, "labelle-core" }) catch return null;
        defer allocator.free(marker);
        std.Io.Dir.cwd().access(io, marker, .{}) catch {
            dir = std.fs.path.dirname(dir) orelse return null;
            continue;
        };
        return allocator.dupe(u8, dir) catch return null;
    }
    return null;
}

// ── project.labelle reading ──────────────────────────────────────────

/// Read + parse project.labelle. Mirrors main.zig:readProjectConfig.
fn readProjectConfig(allocator: std.mem.Allocator, io: std.Io, project_dir: []const u8) !config.ProjectConfig {
    @setEvalBranchQuota(10000);
    const labelle_path = try std.fs.path.join(allocator, &.{ project_dir, "project.labelle" });
    defer allocator.free(labelle_path);

    const source_raw = try std.Io.Dir.cwd().readFileAlloc(io, labelle_path, allocator, .limited(1024 * 1024));
    defer allocator.free(source_raw);

    const source = try allocator.dupeZ(u8, source_raw);
    return try std.zon.parse.fromSliceAlloc(config.ProjectConfig, allocator, source, null, .{});
}

/// readProjectConfig that returns an error instead of treating a missing
/// file as fatal — used by `clean`, where no project.labelle is normal.
fn readProjectConfigQuiet(allocator: std.mem.Allocator, io: std.Io, project_dir: []const u8) !config.ProjectConfig {
    return readProjectConfig(allocator, io, project_dir);
}

test {
    std.testing.refAllDecls(@This());
}
