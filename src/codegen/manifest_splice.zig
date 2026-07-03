//! Resolve-time backend-manifest helpers (pluggable-backends RFC, epic#386 /
//! #453 / #461).
//!
//! The v1/legacy build-graph splice — the raw-text `build_fragments` renderers
//! that produced a backend's build.zig from a `backend.manifest.zon` — was DELETED
//! in #461: every backend now generates its build.zig from a typed v2
//! `backend.manifest.v2.zon` (see `manifest_v2.zig` / `manifest_v2_splice.zig`).
//!
//! What remains here is the PLATFORM-INDEPENDENT, resolve-time slice that is NOT
//! codegen:
//!   - `requireManifestIfExternal` — an external backend must ship SOME manifest;
//!     a manifest-less external package is a hard error (it has no codegen route).
//!   - `manifestPathEnabled` / `manifestExists` — probe whether the resolved
//!     backend package ships the requested manifest file (used to gate the v2
//!     manifest load in `build_files`).
//!   - `ProviderManifest` / `loadProviderManifest` — the provider identity +
//!     declared-capabilities slice read at resolve time on EVERY target for
//!     capability negotiation (`capabilities.validate`), independent of codegen.
//!
//! Package LOCATION (`backendPackageDir`) routes through `backend_registry`, keyed
//! by `cfg.backendName()` (a STRING), so a third-party backend named only by
//! `.backend_package` — with no matching `Backend` enum tag — resolves through the
//! same registry, never through `@tagName(cfg.backend)`.

const std = @import("std");
const config = @import("../config.zig");
const backend_registry = @import("../backend_registry.zig");

const ProjectConfig = config.ProjectConfig;

/// The legacy (v1) manifest filename. Retained as the default probe name for the
/// external-manifest gate + provider-identity slice: a backend may ship this file
/// for its identity/capabilities even though the v1 build-graph splice is gone.
/// manifest-v2 (epic #453) opts a backend onto `backend.manifest.v2.zon`, and the
/// gates below key off THAT requested name when it is supplied.
pub const LEGACY_MANIFEST_NAME = "backend.manifest.zon";

/// True when the resolved backend package ships the requested manifest file.
///
/// `manifest_name` is the filename to probe, relative to the backend package
/// root. Null selects the production `backend.manifest.zon` name; the v2 codegen
/// passes `backend.manifest.v2.zon` so a v2-only backend (no legacy sibling) still
/// enables the manifest load path in `build_files`.
pub fn manifestPathEnabled(allocator: std.mem.Allocator, cfg: ProjectConfig, project_dir: []const u8, manifest_name: ?[]const u8) bool {
    return manifestExists(allocator, cfg, project_dir, manifest_name orelse LEGACY_MANIFEST_NAME);
}

/// Validate that an EXTERNAL backend actually ships a manifest. External backends
/// have NO built-in codegen fallback — the enum/v1 path is gone — so a manifest is
/// their ONLY codegen route: a manifest-less external package is a hard error,
/// surfaced here rather than producing a broken build.zig.
///
/// No-op for built-ins (`!cfg.isExternal()`). Call before the manifest-path
/// decision in the generators.
///
/// `manifest_name` is the required filename, relative to the backend package root.
/// Null selects `backend.manifest.zon`; the v2 codegen passes the v2 filename so
/// the requirement is keyed off the SAME manifest the loader will read (a v2-only
/// external must not be flagged manifest-less just because it ships no legacy
/// sibling).
pub fn requireManifestIfExternal(allocator: std.mem.Allocator, cfg: ProjectConfig, project_dir: []const u8, manifest_name: ?[]const u8) !void {
    if (!cfg.isExternal()) return;

    const name = manifest_name orelse LEGACY_MANIFEST_NAME;

    // Probe the manifest DIRECTLY (don't reuse `manifestExists`, which swallows
    // every error for built-in fallback probing). For external backends a broken
    // `local:` path / plugin-resolution failure / OOM is a real configuration
    // error and must propagate — only a genuinely absent manifest (FileNotFound)
    // maps to `ExternalBackendNeedsManifest`.
    const pkg_dir = try backendPackageDir(allocator, cfg, project_dir);
    defer allocator.free(pkg_dir);
    const manifest_path = try std.fs.path.join(allocator, &.{ pkg_dir, name });
    defer allocator.free(manifest_path);

    std.Io.Dir.cwd().access(config.globalIo(), manifest_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            // `warn`, not `err`: the hard failure is the returned error; this is
            // the human-readable hint.
            std.log.warn(
                "labelle-assembler: external backend '{s}' (backend_package) ships no {s} — " ++
                    "an external backend must declare its codegen via a manifest (the enum-path fallback no longer exists).",
                .{ cfg.backendName(), name },
            );
            return error.ExternalBackendNeedsManifest;
        },
        else => return err, // real resolution/access failure — surface it, don't mask it
    };
}

/// Does the resolved backend package contain the named manifest file?
/// Resolution failures / a missing file both mean "no manifest" → false.
fn manifestExists(allocator: std.mem.Allocator, cfg: ProjectConfig, project_dir: []const u8, manifest_name: []const u8) bool {
    const pkg_dir = backendPackageDir(allocator, cfg, project_dir) catch return false;
    defer allocator.free(pkg_dir);
    const manifest_path = std.fs.path.join(allocator, &.{ pkg_dir, manifest_name }) catch return false;
    defer allocator.free(manifest_path);
    std.Io.Dir.cwd().access(config.globalIo(), manifest_path, .{}) catch return false;
    return true;
}

/// Resolve the backend package directory (the cached/local `backends/<dir>/` slot)
/// the same way `loadBackendTemplate` / `deps_linker` do. Caller owns the returned
/// path. Routed through `backend_registry` — keyed by `cfg.backendName()`, a
/// string, NOT `@tagName` directly.
fn backendPackageDir(allocator: std.mem.Allocator, cfg: ProjectConfig, project_dir: []const u8) ![]const u8 {
    return backend_registry.resolveBackendPackage(allocator, cfg, project_dir);
}

/// The RESOLVE-TIME slice of a backend manifest: provider identity + declared
/// capabilities ONLY. Parsed with `ignore_unknown_fields`, so it reads the same
/// `backend.manifest.zon` a backend may ship for identity but ignores every other
/// field.
///
/// This is deliberately DECOUPLED from codegen: identity + capability negotiation
/// happen at resolve time on EVERY target (android/wasm/ios included). A provider
/// ships one manifest; this reads the platform-independent half of it. (The v2
/// codegen path reads identity/capabilities off `BackendManifestV2` directly; this
/// is the fallback for a backend that ships only a legacy `backend.manifest.zon`.)
pub const ProviderManifest = struct {
    id: ?[]const u8 = null,
    capabilities: []const config.Capability = &.{},
};

/// Load the provider-identity / capability slice of `backend.manifest.zon`,
/// regardless of target platform. Returns `null` when the resolved backend package
/// ships NO manifest. Errors only on a genuine parse failure. Caller frees the
/// result with `freeProviderManifest`.
pub fn loadProviderManifest(allocator: std.mem.Allocator, cfg: ProjectConfig, project_dir: []const u8) !?ProviderManifest {
    const pkg_dir = backendPackageDir(allocator, cfg, project_dir) catch return null;
    defer allocator.free(pkg_dir);

    const manifest_path = try std.fs.path.join(allocator, &.{ pkg_dir, LEGACY_MANIFEST_NAME });
    defer allocator.free(manifest_path);

    const raw = std.Io.Dir.cwd().readFileAlloc(config.globalIo(), manifest_path, allocator, .limited(64 * 1024)) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer allocator.free(raw);
    const raw_z = try allocator.dupeZ(u8, raw);
    defer allocator.free(raw_z);

    return std.zon.parse.fromSliceAlloc(ProviderManifest, allocator, raw_z, null, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.log.warn("labelle-assembler: failed to parse backend.manifest.zon (identity/capabilities) at {s}: {any}", .{ manifest_path, err });
        return error.BackendManifestParseError;
    };
}

pub fn freeProviderManifest(allocator: std.mem.Allocator, m: ProviderManifest) void {
    std.zon.parse.free(allocator, m);
}

// ── Tests: external-backend manifest gate (open-config, epic #386 Phase 5) ──

test "requireManifestIfExternal: external backend WITH a manifest is accepted" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // project_dir + a sibling stub backend that SHIPS backend.manifest.zon.
    try tmp.dir.createDirPath(std.testing.io, "project");
    try tmp.dir.createDirPath(std.testing.io, "stubbackend");
    {
        const f = try tmp.dir.createFile(std.testing.io, "stubbackend/backend.manifest.zon", .{});
        defer f.close(std.testing.io);
        // Presence is all requireManifestIfExternal checks — contents unused.
        try f.writeStreamingAll(std.testing.io, ".{}\n");
    }

    const project_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "project", alloc);
    defer alloc.free(project_abs);

    const cfg = config.ProjectConfig{
        .name = "stubgame",
        .backend_package = .{ .name = "stubbackend", .repo = "local:../stubbackend" },
    };

    try requireManifestIfExternal(alloc, cfg, project_abs, null);
}

test "requireManifestIfExternal: external backend WITHOUT a manifest errors" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Sibling stub backend dir exists but ships NO backend.manifest.zon.
    try tmp.dir.createDirPath(std.testing.io, "project");
    try tmp.dir.createDirPath(std.testing.io, "stubbackend");

    const project_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "project", alloc);
    defer alloc.free(project_abs);

    const cfg = config.ProjectConfig{
        .name = "stubgame",
        .backend_package = .{ .name = "stubbackend", .repo = "local:../stubbackend" },
    };

    try std.testing.expectError(
        error.ExternalBackendNeedsManifest,
        requireManifestIfExternal(alloc, cfg, project_abs, null),
    );
}

test "requireManifestIfExternal: a v2-only backend (no legacy sibling) is keyed off the requested name" {
    // manifest-v2 (#453): a backend shipping ONLY `backend.manifest.v2.zon` — no
    // legacy `backend.manifest.zon` — must be ACCEPTED when the requested name is
    // the v2 file, and still REJECTED when the (absent) legacy name is requested.
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "project");
    try tmp.dir.createDirPath(std.testing.io, "stubbackend");
    {
        // v2 manifest present; NO legacy `backend.manifest.zon`.
        const f = try tmp.dir.createFile(std.testing.io, "stubbackend/backend.manifest.v2.zon", .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, ".{ .manifest_version = 2 }\n");
    }

    const project_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "project", alloc);
    defer alloc.free(project_abs);

    const cfg = config.ProjectConfig{
        .name = "stubgame",
        .backend_package = .{ .name = "stubbackend", .repo = "local:../stubbackend" },
    };

    // Requesting the v2 name → accepted (the file exists).
    try requireManifestIfExternal(alloc, cfg, project_abs, "backend.manifest.v2.zon");
    // Requesting the legacy name (or null) → still errors, since it is absent.
    try std.testing.expectError(
        error.ExternalBackendNeedsManifest,
        requireManifestIfExternal(alloc, cfg, project_abs, null),
    );
}

test "requireManifestIfExternal: the retained in-tree sokol fixture ships a manifest (accepted)" {
    // `backends/sokol` is the offline in-tree fixture; it ships a
    // `backend.manifest.zon` (identity/capabilities slice) so the codegen tests can
    // resolve a real backend package. Selecting it via an explicit
    // `.backend_package` + the repo root as project_dir must be ACCEPTED.
    const alloc = std.testing.allocator;
    const cfg = config.ProjectConfig{
        .name = "g",
        .backend = .sokol,
        .backend_package = .{ .name = "sokol", .repo = "local:backends/sokol" },
    };
    try requireManifestIfExternal(alloc, cfg, ".", null);
}

// ── Tests: provider identity + capability slice (#453) ────────────────────

test "ProviderManifest: parses the id + capability slice, ignoring other fields" {
    const alloc = std.testing.allocator;
    const src =
        \\.{
        \\    .dir_name = "sokol",
        \\    .dep_name = "labelle_sokol",
        \\    .id = "labelle.sokol",
        \\    .capabilities = .{ .screenshots, .raw_gui_adapter, .audio_ogg },
        \\}
    ;
    const src_z = try alloc.dupeZ(u8, src);
    defer alloc.free(src_z);

    const pm = try std.zon.parse.fromSliceAlloc(ProviderManifest, alloc, src_z, null, .{ .ignore_unknown_fields = true });
    defer std.zon.parse.free(alloc, pm);

    try std.testing.expectEqualStrings("labelle.sokol", pm.id.?);
    try std.testing.expectEqual(@as(usize, 3), pm.capabilities.len);
    try std.testing.expectEqual(config.Capability.screenshots, pm.capabilities[0]);
}

test "loadProviderManifest: reads the retained sokol fixture's id + capabilities" {
    // The in-tree sokol fixture is the reference manifest; it must expose the
    // canonical id and a non-empty capability set through the decoupled loader.
    const alloc = std.testing.allocator;
    const cfg = config.ProjectConfig{
        .name = "g",
        .backend = .sokol,
        .backend_package = .{ .name = "sokol", .repo = "local:backends/sokol" },
    };
    const pm = (try loadProviderManifest(alloc, cfg, ".")).?;
    defer freeProviderManifest(alloc, pm);

    try std.testing.expectEqualStrings("labelle.sokol", pm.id.?);
    try std.testing.expect(pm.capabilities.len > 0);
}
