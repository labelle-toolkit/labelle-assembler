/// GUI plugin resolver — reads gui.labelle manifest and populates resolved_gui on ProjectConfig.
///
/// Lives in the generator package because the fields it produces
/// (`resolved_gui`) are consumed by the generator's `generate()` function.
/// Both the in-process CLI import path and the standalone
/// `labelle-assembler` binary call this through `root.zig`'s re-export.
const std = @import("std");
const config = @import("config.zig");
const cache = @import("cache.zig");

/// Resolve the GUI plugin reference in the config.
/// Reads gui.labelle from the plugin directory, validates the bridge for
/// the selected backend, and populates cfg.resolved_gui.
pub fn resolveGuiPlugin(allocator: std.mem.Allocator, cfg: *config.ProjectConfig, project_dir: []const u8) !void {
    const gui_ref = cfg.gui orelse return; // null = no GUI

    // Resolve plugin directory
    const plugin_dir = try resolvePluginDir(allocator, gui_ref, cfg.*, project_dir);

    // Read and parse gui.labelle manifest
    const manifest_path = try std.fs.path.join(allocator, &.{ plugin_dir, "gui.labelle" });
    defer allocator.free(manifest_path);

    const manifest_raw = std.Io.Dir.cwd().readFileAlloc(config.globalIo(), manifest_path, allocator, .limited(64 * 1024)) catch |err| {
        std.debug.print("labelle: could not read GUI manifest '{s}': {any}\n", .{ manifest_path, err });
        std.debug.print("  hint: GUI plugins must contain a gui.labelle manifest file\n", .{});
        return error.GuiManifestNotFound;
    };
    defer allocator.free(manifest_raw);

    const manifest_z = try allocator.dupeZ(u8, manifest_raw);
    // Do NOT defer-free manifest_z — the ZON parser returns string slices
    // that reference this buffer. It must stay alive as long as resolved_gui.
    errdefer allocator.free(manifest_z);

    const manifest = std.zon.parse.fromSliceAlloc(GuiLabelle, allocator, manifest_z, null, .{}) catch |err| {
        std.debug.print("labelle: could not parse GUI manifest '{s}': {any}\n", .{ manifest_path, err });
        return error.GuiManifestParseError;
    };

    // Resolve bridge directory for raw_backend GUIs
    var bridge_dir: ?[]const u8 = null;
    if (manifest.rendering == .raw_backend) {
        const bridges = manifest.bridges orelse {
            std.debug.print("labelle: GUI plugin '{s}' declares raw_backend rendering but has no bridges\n", .{manifest.name});
            return error.GuiMissingBridges;
        };

        const bridge_def = getBridgeForBackend(bridges, cfg.backend) orelse {
            std.debug.print("labelle: GUI plugin '{s}' requires a bridge for backend '{s}', but none is declared in gui.labelle.\n", .{ manifest.name, @tagName(cfg.backend) });
            std.debug.print("  available bridges:", .{});
            printAvailableBridges(bridges);
            std.debug.print("\n", .{});
            return error.GuiMissingBridge;
        };

        if (bridge_def.path) |rel_path| {
            // Local bridge path (relative to plugin directory)
            bridge_dir = try std.fs.path.resolve(allocator, &.{ plugin_dir, rel_path });
        } else {
            std.debug.print("labelle: GUI plugin '{s}' bridge for '{s}' has no .path (remote bridge resolution not yet supported)\n", .{ manifest.name, @tagName(cfg.backend) });
            return error.GuiBridgeResolutionNotSupported;
        }

        if (bridge_def.adapter.len == 0) {
            std.debug.print("labelle: GUI plugin '{s}' bridge for '{s}' has empty .adapter name\n", .{ manifest.name, @tagName(cfg.backend) });
            return error.GuiBridgeMissingAdapter;
        }

        cfg.resolved_gui = .{
            .name = manifest.name,
            .rendering = manifest.rendering,
            .lifecycle = manifest.lifecycle,
            .plugin_dir = plugin_dir,
            .bridge_dir = bridge_dir,
            .bridge_artifact = bridge_def.adapter,
        };
    } else {
        cfg.resolved_gui = .{
            .name = manifest.name,
            .rendering = manifest.rendering,
            .lifecycle = manifest.lifecycle,
            .plugin_dir = plugin_dir,
        };
    }
}

/// Resolve the plugin directory from a GuiPlugin reference.
///
/// Supports four declaration shapes (see config.GuiPlugin):
///   .path    — a local directory, relative to the project.
///   .plugin  — a named entry in `.plugins`, resolved from the plugin cache.
///   .package — a repo-style package, resolved from the package cache
///              (`~/.labelle/packages/plugins/{package}/{version}`),
///              fetched on demand if absent. Same layout cache.zig uses
///              for regular declared plugins.
///   .url     — a git URL, fetched into a deterministic per-URL cache
///              slot (`~/.labelle/packages/gui-url/{url-hash}/{ref}`).
///              `.version` is mapped to a git ref via `versionToGitRef`
///              (semver → `v`-tag) like every other fetch path, and
///              `.hash` — when set — is the expected commit SHA the
///              checkout is verified against (see cache.fetchGuiUrl).
fn resolvePluginDir(allocator: std.mem.Allocator, ref: config.GuiPlugin, cfg: config.ProjectConfig, project_dir: []const u8) ![]const u8 {
    if (ref.path) |rel_path| {
        // Local path — resolve relative to project directory
        return std.fs.path.resolve(allocator, &.{ project_dir, rel_path });
    }
    if (ref.plugin) |name| {
        // Reference a declared plugin by name — resolve from the plugin cache
        for (cfg.plugins) |plugin| {
            if (std.mem.eql(u8, plugin.name, name)) {
                return cache.resolvePlugin(allocator, plugin, project_dir);
            }
        }
        std.log.err("labelle: GUI references plugin '{s}', but no plugin with that name is declared in .plugins", .{name});
        return error.GuiPluginNotFound;
    }
    if (ref.package) |package| {
        // Package reference — resolve from the package cache, fetching
        // into ~/.labelle/packages/plugins/{package}/{version} if absent.
        const version = ref.version orelse {
            std.log.err("labelle: GUI plugin '.package = \"{s}\"' requires a '.version'", .{package});
            return error.GuiPluginMissingVersion;
        };

        const dir = try cache.resolveGuiPackage(allocator, package, version, project_dir);
        errdefer allocator.free(dir);

        // `local:` versions resolve to an existing on-disk path; never fetched.
        if (config.isLocalVersion(version)) return dir;

        if (!cache.dirExists(dir)) {
            std.log.info("labelle: fetching GUI plugin package {s} {s}", .{ package, version });
            cache.fetchGuiPackage(allocator, package, version) catch |err| {
                std.log.err("labelle: could not fetch GUI plugin package '{s}' {s}: {s}", .{ package, version, @errorName(err) });
                return error.GuiPluginFetchFailed;
            };
        }
        return dir;
    }
    if (ref.url) |url| {
        // URL reference — fetch the repo into a deterministic per-URL
        // cache slot. `.version`, when set, names the git ref to check
        // out; otherwise the repo's default branch is used.
        //
        // `.version` is routed through `config.versionToGitRef` exactly
        // like every other fetch path (framework/plugin fetchers and the
        // `.package` branch above): a semver `.version` (`0.3.0`) maps to
        // the published release tag `v0.3.0`, while a branch name is used
        // verbatim. Using `.version` raw here would have skipped the
        // `v`-prefix and failed to find a semver release tag.
        const clone_ref: ?[]u8 = if (ref.version) |v|
            try config.versionToGitRef(allocator, v)
        else
            null;
        defer if (clone_ref) |r| allocator.free(r);

        // Cache slot keyed by the resolved git ref ("default" when the
        // repo's default branch is used implicitly).
        const slot = clone_ref orelse "default";

        const dir = try cache.resolveGuiUrl(allocator, url, slot);
        errdefer allocator.free(dir);

        if (!cache.dirExists(dir)) {
            std.log.info("labelle: fetching GUI plugin from {s} ({s})", .{ url, slot });
            // `.hash`, when set, is the expected commit SHA the checkout
            // must resolve to — fetchGuiUrl verifies it (see its doc
            // comment for the `.url`+`hash` contract). When null the
            // plugin is fetched unpinned and fetchGuiUrl warns.
            cache.fetchGuiUrl(allocator, url, slot, clone_ref, ref.hash) catch |err| {
                std.log.err("labelle: could not fetch GUI plugin from '{s}': {s}", .{ url, @errorName(err) });
                return error.GuiPluginFetchFailed;
            };
        } else if (ref.hash) |sha| {
            // Cache HIT against a pinned `.hash`: the cached checkout may
            // come from an earlier unpinned (or differently-pinned) fetch,
            // so the cache slot's existence alone proves nothing. Re-verify
            // the checked-out commit against `.hash` on *every* resolution.
            // `.url` checkouts retain their `.git` directory precisely so
            // this re-verification can run (see cache.fetchGuiUrl). A
            // mismatched or unverifiable checkout is a hard error — the
            // build must never proceed against an unexpected revision.
            cache.verifyGuiUrlHash(allocator, dir, sha) catch {
                return error.GuiUrlHashMismatch;
            };
        }
        return dir;
    }
    // Malformed GuiPlugin — none of the four reference fields is set.
    std.log.err("labelle: GUI plugin reference must set one of .path, .plugin, .package, or .url", .{});
    return error.GuiPluginResolutionNotSupported;
}

// ── gui.labelle manifest types (ZON-parseable) ──────────────────────

const BridgeDef = struct {
    adapter: []const u8 = "",
    path: ?[]const u8 = null,
};

const Bridges = struct {
    raylib: ?BridgeDef = null,
    sokol: ?BridgeDef = null,
    sdl: ?BridgeDef = null,
    bgfx: ?BridgeDef = null,
    wgpu: ?BridgeDef = null,
};

const LibraryDef = struct {
    package: []const u8 = "",
};

const GuiLabelle = struct {
    name: []const u8,
    library: LibraryDef = .{},
    rendering: config.RenderingMode,
    lifecycle: config.GuiLifecycle = .{},
    bridges: ?Bridges = null,
};

fn getBridgeForBackend(bridges: Bridges, backend: config.Backend) ?BridgeDef {
    return switch (backend) {
        .raylib => bridges.raylib,
        .sokol => bridges.sokol,
        .sdl => bridges.sdl,
        .bgfx => bridges.bgfx,
        .wgpu => bridges.wgpu,
        // Null backend has no GUI surface to bridge to — every GUI plugin
        // is incompatible by definition. Caller's null-bridge branch already
        // emits the right "no bridge for backend X" diagnostic.
        .null => null,
    };
}

fn printAvailableBridges(bridges: Bridges) void {
    var first = true;
    inline for (.{ "raylib", "sokol", "sdl", "bgfx", "wgpu" }) |name| {
        if (@field(bridges, name) != null) {
            if (!first) std.debug.print(",", .{});
            std.debug.print(" {s}", .{name});
            first = false;
        }
    }
}

// ── Tests ────────────────────────────────────────────────────────────

test "resolvePluginDir: malformed GuiPlugin (no field set) is rejected" {
    const alloc = std.testing.allocator;
    const cfg: config.ProjectConfig = .{ .name = "t" };
    const ref: config.GuiPlugin = .{};
    try std.testing.expectError(
        error.GuiPluginResolutionNotSupported,
        resolvePluginDir(alloc, ref, cfg, "/tmp/project"),
    );
}

test "resolvePluginDir: .package without .version is rejected" {
    const alloc = std.testing.allocator;
    const cfg: config.ProjectConfig = .{ .name = "t" };
    const ref: config.GuiPlugin = .{ .package = "github.com/labelle-toolkit/labelle-imgui" };
    try std.testing.expectError(
        error.GuiPluginMissingVersion,
        resolvePluginDir(alloc, ref, cfg, "/tmp/project"),
    );
}

test "resolvePluginDir: .package with a local: version resolves the local dir" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Project dir with a sibling local GUI plugin checkout.
    try tmp.dir.createDirPath(std.testing.io, "project");
    try tmp.dir.createDirPath(std.testing.io, "gui-plugin");

    const project_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "project", alloc);
    defer alloc.free(project_abs);
    const plugin_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "gui-plugin", alloc);
    defer alloc.free(plugin_abs);

    const cfg: config.ProjectConfig = .{ .name = "t" };
    const ref: config.GuiPlugin = .{
        .package = "github.com/labelle-toolkit/labelle-imgui",
        .version = "local:../gui-plugin",
    };

    const dir = try resolvePluginDir(alloc, ref, cfg, project_abs);
    defer alloc.free(dir);

    try std.testing.expectEqualStrings(plugin_abs, dir);
}

test "resolveGuiUrl: deterministic, distinct per-URL, ref is the leaf component" {
    const alloc = std.testing.allocator;

    const a1 = try cache.resolveGuiUrl(alloc, "https://example.com/gui.git", "v1.0.0");
    defer alloc.free(a1);
    const a2 = try cache.resolveGuiUrl(alloc, "https://example.com/gui.git", "v1.0.0");
    defer alloc.free(a2);
    const b = try cache.resolveGuiUrl(alloc, "https://example.com/other.git", "v1.0.0");
    defer alloc.free(b);

    // Same URL + ref → identical path.
    try std.testing.expectEqualStrings(a1, a2);
    // Different URL → different path.
    try std.testing.expect(!std.mem.eql(u8, a1, b));
    // The ref is the final path component.
    try std.testing.expectEqualStrings("v1.0.0", std.fs.path.basename(a1));
    // The slot lives under the packages/gui-url tree.
    try std.testing.expect(std.mem.indexOf(u8, a1, "gui-url") != null);
}

test "resolveGuiPackage: local: version bypasses the cache and resolves on disk" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "project");
    try tmp.dir.createDirPath(std.testing.io, "imgui-src");

    const project_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "project", alloc);
    defer alloc.free(project_abs);
    const src_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "imgui-src", alloc);
    defer alloc.free(src_abs);

    const dir = try cache.resolveGuiPackage(
        alloc,
        "github.com/labelle-toolkit/labelle-imgui",
        "local:../imgui-src",
        project_abs,
    );
    defer alloc.free(dir);

    try std.testing.expectEqualStrings(src_abs, dir);
}

test "resolvePluginDir: .url with a semver .version uses the v-prefixed tag as the cache slot" {
    // Regression for the opencode MAJOR: the `.url` path must route
    // `.version` through config.versionToGitRef just like every other
    // fetch path — a semver `.version` resolves to the `v`-prefixed
    // release tag. The cache slot is keyed by the resolved git ref, so
    // a semver `.version` lands under a `v`-prefixed leaf.
    const alloc = std.testing.allocator;

    const git_ref = try config.versionToGitRef(alloc, "0.3.0");
    defer alloc.free(git_ref);
    try std.testing.expectEqualStrings("v0.3.0", git_ref);

    const dir = try cache.resolveGuiUrl(alloc, "https://example.com/gui.git", git_ref);
    defer alloc.free(dir);
    // The slot leaf is the resolved git ref, not the raw version.
    try std.testing.expectEqualStrings("v0.3.0", std.fs.path.basename(dir));
}

test "resolvePluginDir: .url with a branch .version uses the ref verbatim as the cache slot" {
    // The other half of versionToGitRef: a non-semver `.version` (a
    // branch name) is used verbatim — no `v` prefix.
    const alloc = std.testing.allocator;

    const git_ref = try config.versionToGitRef(alloc, "main");
    defer alloc.free(git_ref);
    try std.testing.expectEqualStrings("main", git_ref);

    const dir = try cache.resolveGuiUrl(alloc, "https://example.com/gui.git", git_ref);
    defer alloc.free(dir);
    try std.testing.expectEqualStrings("main", std.fs.path.basename(dir));
}

test "resolveGuiPackage: a release version maps to the packages/plugins cache slot" {
    const alloc = std.testing.allocator;

    const dir = try cache.resolveGuiPackage(
        alloc,
        "github.com/labelle-toolkit/labelle-imgui",
        "0.3.0",
        null,
    );
    defer alloc.free(dir);

    // Same layout regular declared plugins use: plugins/{repo}/{version}.
    try std.testing.expect(std.mem.indexOf(u8, dir, "plugins") != null);
    try std.testing.expect(std.mem.endsWith(u8, dir, "github.com/labelle-toolkit/labelle-imgui/0.3.0"));
}
