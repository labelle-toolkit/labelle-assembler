//! Engine + backend template loading, extracted from `root.zig`
//! (behavior-preserving split). Resolves the engine's `main.zig.template`
//! and the backend+platform lifecycle (entry-point) template — the latter
//! exclusively from the v2 manifest's per-platform `.entry` (#461).

const std = @import("std");
const config = @import("../config.zig");
const cache = @import("../cache.zig");
const backend_registry = @import("../backend_registry.zig");
const manifest_splice = @import("../codegen/manifest_splice.zig");
const manifest_v2 = @import("../codegen/manifest_v2.zig");
const manifest_v2_splice = @import("../codegen/manifest_v2_splice.zig");

const ProjectConfig = config.ProjectConfig;

/// Load the engine's main.zig template from the codegen/ directory.
pub fn loadEngineTemplate(allocator: std.mem.Allocator, game_dir: []const u8, cfg: ProjectConfig) ![]const u8 {
    const engine_path = try cache.resolveFrameworkPackage(allocator, "engine", cfg.engine_version, game_dir);
    defer allocator.free(engine_path);

    const tmpl_path = try std.fs.path.join(allocator, &.{ engine_path, "codegen", "main.zig.template" });
    defer allocator.free(tmpl_path);

    return std.Io.Dir.cwd().readFileAlloc(config.globalIo(), tmpl_path, allocator, .limited(256 * 1024)) catch |err| {
        std.debug.print("labelle: could not read engine template '{s}': {any}\n", .{ tmpl_path, err });
        return error.EngineTemplateNotFound;
    };
}

/// Load the backend+platform lifecycle (entry-point) template from the CLI cache.
///
/// The enum/v1 template path is gone (#461): the entry-point template is resolved
/// EXCLUSIVELY from the v2 manifest's `.platforms[<platform>].entry` (design §3).
/// `backend_manifest_name` is the v2 filename `generate` auto-detected — null means
/// the backend ships no v2 manifest, which is no longer a supported codegen input.
pub fn loadBackendTemplate(allocator: std.mem.Allocator, game_dir: []const u8, cfg: ProjectConfig, backend_manifest_name: ?[]const u8) ![]const u8 {
    // Every backend generates via its manifest — fail loudly if one ships none.
    try manifest_splice.requireManifestIfExternal(allocator, cfg, game_dir, backend_manifest_name);

    const name = backend_manifest_name orelse return error.ExternalBackendNeedsManifest;
    const m = try manifest_v2.loadNamedManifest(allocator, cfg, game_dir, name);
    defer std.zon.parse.free(allocator, m);
    const entry = manifest_v2_splice.platformEntry(m, cfg.platform) orelse {
        std.log.warn(
            "labelle: v2 backend '{s}' declares no `.platforms.{s}` entry — the platform is unsupported by this backend.",
            .{ cfg.backendName(), @tagName(cfg.platform) },
        );
        return error.V2PlatformUnsupported;
    };
    const backend_path = try backend_registry.resolveBackendPackage(allocator, cfg, game_dir);
    defer allocator.free(backend_path);
    const tmpl_path = try std.fs.path.join(allocator, &.{ backend_path, entry.entry });
    defer allocator.free(tmpl_path);
    return std.Io.Dir.cwd().readFileAlloc(config.globalIo(), tmpl_path, allocator, .limited(64 * 1024)) catch |err| {
        std.log.warn("labelle: could not read v2 entry template '{s}': {any}", .{ tmpl_path, err });
        return error.TemplateNotFound;
    };
}
