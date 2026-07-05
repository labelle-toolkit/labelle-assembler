//! Backend manifest-v2 auto-detection + per-platform override resolution,
//! extracted from `root.zig` (behavior-preserving split). These probe the
//! resolved backend package for a `backend.manifest.v2.zon` and read the
//! loop-style / lifecycle overrides the orchestrator threads into `main.zig`
//! codegen. Every probe swallows I/O errors and falls back to null, matching
//! the rest of `generate`'s manifest-probing discipline.

const std = @import("std");
const config = @import("../config.zig");
const backend_registry = @import("../backend_registry.zig");
const manifest_v2 = @import("../codegen/manifest_v2.zig");
const manifest_v2_splice = @import("../codegen/manifest_v2_splice.zig");

const ProjectConfig = config.ProjectConfig;

/// Auto-detect whether the resolved backend package ships a v2 build-graph
/// manifest (`backend.manifest.v2.zon`) and, if so, return its canonical
/// filename so `generate` drives the manifest-v2 codegen path (epic #453,
/// closing the #472 P2 gap). Returns `V2_MANIFEST_NAME` (a static string, so no
/// allocation to free) when the package ships one, else `null` → the v1/enum
/// path, unchanged.
///
/// LIVE AUTO-DETECTION (the #472 P2 cutover shipped): whether this fires on a
/// real `generate` depends ONLY on the resolved backend package shipping the
/// file — no caller opt-in. The in-tree sokol package (`local:backends/sokol`)
/// and the v2 fixtures ship one; a fetched provider repo opts in per-repo by
/// adding the file. When it fires, the detected name is threaded through every
/// downstream site (template selection, loop-style, build.zig/zon, hook staging)
/// — see test/build_zig_tests.zig `MANIFEST_V2_GENERATE_CUTOVER`. For a
/// dual-manifest backend the v2 DESKTOP build.zig stays byte-identical to the
/// v1/enum splice (the §7 anchor test).
///
/// GRACEFUL DEGRADATION: any probe I/O error (package resolution failure, a
/// missing dir, an access error, OOM building the path) falls back to null (the
/// v1/enum path) rather than crashing — mirroring the swallow-and-fall-back
/// discipline the rest of `generate`'s manifest probing uses
/// (`manifest_splice.manifestExists`). A genuine external-backend
/// misconfiguration is still surfaced separately by `requireManifestIfExternal`.
pub fn detectV2ManifestName(allocator: std.mem.Allocator, cfg: ProjectConfig, project_dir: []const u8) ?[]const u8 {
    const pkg_dir = backend_registry.resolveBackendPackage(allocator, cfg, project_dir) catch return null;
    defer allocator.free(pkg_dir);
    const manifest_path = std.fs.path.join(allocator, &.{ pkg_dir, manifest_v2.V2_MANIFEST_NAME }) catch return null;
    defer allocator.free(manifest_path);
    std.Io.Dir.cwd().access(config.globalIo(), manifest_path, .{}) catch return null;
    return manifest_v2.V2_MANIFEST_NAME;
}

/// Resolve the run-loop-style override for `main.zig` codegen from the v2 backend
/// manifest's PER-PLATFORM `.platforms[<platform>].loop_style` (bgfx-desktop is
/// `.loop`, bgfx-android `.callback` — the style MUST be per-platform). `null` →
/// no manifest name detected (the enum/v1 path is gone, so a backend that ships no
/// v2 manifest cannot generate). A load error is swallowed (fall back to null,
/// same probing discipline as the rest of the manifest detection).
pub fn resolveLoopStyleOverride(
    allocator: std.mem.Allocator,
    cfg: ProjectConfig,
    game_dir: []const u8,
    backend_manifest_name: ?[]const u8,
) !?manifest_v2.BackendManifestV2.PlatformEntry.LoopStyle {
    const name = backend_manifest_name orelse return null;
    const m = manifest_v2.loadNamedManifest(allocator, cfg, game_dir, name) catch return null;
    defer std.zon.parse.free(allocator, m);
    const entry = manifest_v2_splice.platformEntry(m, cfg.platform) orelse return null;
    return entry.loop_style;
}

/// Resolve the callback-lifecycle-blocks declaration for `main.zig` codegen from
/// the v2 backend manifest's `.platforms[<platform>].lifecycle` (assembler#501).
/// `null` → no declaration (built-ins keep the enum-predicate shape; an
/// UNDECLARED callback external is still rejected in `lifecycle/render.zig`).
///
/// Lifecycle blocks are a v2-ONLY concept — the v1 splice has no such field — so
/// this only inspects the detected named v2 manifest. Mirrors the `.v2` case of
/// `resolveLoopStyleOverride`; a load error is swallowed (fall back to null, same
/// probing discipline). The returned `Lifecycle` is a copy of trivial bool
/// flags, so it stays valid after the parsed manifest is freed.
pub fn resolveLifecycleOverride(
    allocator: std.mem.Allocator,
    cfg: ProjectConfig,
    game_dir: []const u8,
    backend_manifest_name: ?[]const u8,
) !?manifest_v2.BackendManifestV2.PlatformEntry.Lifecycle {
    const name = backend_manifest_name orelse return null;
    const m = manifest_v2.loadNamedManifest(allocator, cfg, game_dir, name) catch return null;
    defer std.zon.parse.free(allocator, m);
    const entry = manifest_v2_splice.platformEntry(m, cfg.platform) orelse return null;
    return entry.lifecycle;
}
