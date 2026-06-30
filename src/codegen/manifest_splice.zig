//! Manifest-driven codegen splice (pluggable-backends RFC, assembler#378 /
//! epic#386 Phase 3 / Phase 5 seam).
//!
//! Resolves a backend's run-loop style + build.zig fragments from a MANIFEST
//! THAT SHIPS IN THE BACKEND PACKAGE (`backends/<dir>/backend.manifest.zon`)
//! instead of a hardcoded `switch (cfg.backend) => .<tag>` enum branch, for
//! the backend's DESKTOP target, with byte-identical output to the enum path.
//!
//! Gate (productionized from the throwaway POC): MANIFEST PRESENCE, not an env
//! var. A backend opts into the manifest path simply by shipping a
//! `backend.manifest.zon` AND being built for a target the manifest covers
//! (desktop). When no manifest is present — or the target is non-desktop — the
//! generator stays on the existing enum path. The splice is a strictly
//! parallel codepath: enum-driven backends (raylib/sdl/wgpu/null, and sokol
//! and bgfx on their non-desktop targets) are untouched.
//!
//! Currently shipped manifests: bgfx (desktop only — wasm/ios/android stay on
//! the enum path; bgfx-android in particular carries the NDK link-ordering the
//! POC flagged as non-declarative). sokol ships the POC manifest but is
//! desktop-callback; this module supports both `.callback` and `.loop` loop
//! styles so a single shape covers both backends.
//!
//! What this module replaces, branch-for-branch (bgfx-desktop example):
//!   - build_files.zig  `renderSection(.., "backend_bgfx", ..)`
//!       → `renderBackendDepSection`  (reads manifest `build_fragments.backend_dep`
//!         + `params.backend_dep`)
//!   - build_files.zig  `writeSection(.., "link_bgfx")`
//!       → `renderLinkSection`        (reads manifest `build_fragments.link`)
//!   - main_template.zig `use_callback_lifecycle = cfg.backend == .sokol or ...`
//!       → `loopStyle(manifest)`      (reads manifest `loop_style`; bgfx = `.loop`)
//!   - root.zig `loadBackendTemplate` backend→desktop.txt mapping
//!       → `mainLoopTemplateRel(manifest)` (reads manifest `main_loop_template`)
//!
//! None of the above names a backend enum tag. The ONLY place the splice
//! still touches the enum is `backendPackageDir`, which uses
//! `@tagName(cfg.backend)` to LOCATE the package so it can read the manifest.
//! That `@tagName` is the documented future seam: Phase 5 replaces it with a
//! backend *name string* → package registry (the manifest already carries
//! `dir_name`/`dep_name` as data so nothing downstream depends on the tag).
//! Building that registry is out of scope here — this lands the splice.

const std = @import("std");
const tpl = @import("../template.zig");
const config = @import("../config.zig");
const backend_registry = @import("../backend_registry.zig");

const ProjectConfig = config.ProjectConfig;

/// Manifest schema (mirrors `backends/<dir>/backend.manifest.zon`).
/// Desktop-only: mobile/wasm fields are intentionally absent — manifest-covered
/// backends fall back to the enum path on every non-desktop target.
pub const BackendManifest = struct {
    dir_name: []const u8,
    dep_name: []const u8,
    loop_style: LoopStyle,
    main_loop_template: []const u8,
    build_fragments: BuildFragments,
    params: Params,

    /// `.callback` → the windowing runtime owns the loop and the generated
    /// `main` registers init/frame/cleanup callbacks (sokol, bgfx-android,
    /// wasm). `.loop` → the generated `main` drives a `while (!shouldQuit())`
    /// desktop loop (raylib/bgfx-desktop). The enum path resolves this as
    /// `use_callback_lifecycle = cfg.backend == .sokol or ...`; the manifest
    /// carries it as data so the splice never names a backend tag.
    pub const LoopStyle = enum { callback, loop };

    pub const BuildFragments = struct {
        backend_dep: []const u8,
        link: []const u8,
    };

    /// Each entry is the ordered list of `{{placeholder}}` names the matching
    /// fragment consumes. The splice computes their values from cfg (same
    /// predicates as the enum path) and renders only this set. An empty list
    /// means the fragment is emitted verbatim (no substitution).
    pub const Params = struct {
        backend_dep: []const []const u8,
        link: []const []const u8,
    };
};

/// True when the manifest path should be taken for this generation: the target
/// is a DESKTOP build (the only target manifests cover) AND the resolved
/// backend package ships a `backend.manifest.zon`. Everything else — non-desktop
/// targets, and backends with no manifest — stays on the enum path.
///
/// This is the productionized gate: a backend opts in by SHIPPING A MANIFEST,
/// no env var. bgfx-desktop ships one (→ manifest path); sokol ships one too
/// (the POC artifact). raylib/sdl/wgpu/null ship none (→ enum path).
pub fn manifestPathEnabled(allocator: std.mem.Allocator, cfg: ProjectConfig, project_dir: []const u8) bool {
    // Manifests declare desktop fields only; non-desktop targets (wasm/ios/
    // android) keep their enum branches (e.g. bgfx-android's NDK ordering).
    if (cfg.platform != .desktop) return false;
    return manifestExists(allocator, cfg, project_dir);
}

/// Validate that an EXTERNAL backend actually ships a `backend.manifest.zon`.
/// External backends have NO enum-path codegen fallback — the enum-path
/// platform selection (`loadBackendTemplate`'s `cfg.backend == .null` /
/// `cfg.backend == .sokol` branches) reads the closed enum, which is meaningless
/// for a backend with no enum tag, and would silently fall to the `.raylib`
/// default. So the manifest splice is their ONLY codegen route: a manifest-less
/// external package is a hard error, surfaced here rather than producing a
/// raylib-shaped build for a non-raylib backend.
///
/// No-op for built-ins (`!cfg.isExternal()`), which keep their enum-path
/// fallback when they ship no manifest (raylib/sdl/wgpu/null). Call before the
/// manifest-path decision in the generators.
pub fn requireManifestIfExternal(allocator: std.mem.Allocator, cfg: ProjectConfig, project_dir: []const u8) !void {
    if (!cfg.isExternal()) return;

    // Probe the manifest DIRECTLY (don't reuse `manifestExists`, which swallows
    // every error for built-in fallback probing). For external backends a broken
    // `local:` path / plugin-resolution failure / OOM is a real configuration
    // error and must propagate — only a genuinely absent manifest (FileNotFound)
    // maps to `ExternalBackendNeedsManifest`.
    const pkg_dir = try backendPackageDir(allocator, cfg, project_dir);
    defer allocator.free(pkg_dir);
    const manifest_path = try std.fs.path.join(allocator, &.{ pkg_dir, "backend.manifest.zon" });
    defer allocator.free(manifest_path);

    std.Io.Dir.cwd().access(config.globalIo(), manifest_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            // `warn`, not `err`: the hard failure is the returned error; this is
            // the human-readable hint. Matches `loadManifest`'s warn-on-failure.
            std.log.warn(
                "labelle-assembler: external backend '{s}' (backend_package) ships no backend.manifest.zon — " ++
                    "an external backend must declare its codegen via a manifest (the enum-path fallback does not apply to external backends).",
                .{cfg.backendName()},
            );
            return error.ExternalBackendNeedsManifest;
        },
        else => return err, // real resolution/access failure — surface it, don't mask it
    };
}

/// Does the resolved backend package contain a `backend.manifest.zon`?
/// Resolution failures / a missing file both mean "no manifest" → enum path.
fn manifestExists(allocator: std.mem.Allocator, cfg: ProjectConfig, project_dir: []const u8) bool {
    const pkg_dir = backendPackageDir(allocator, cfg, project_dir) catch return false;
    defer allocator.free(pkg_dir);
    const manifest_path = std.fs.path.join(allocator, &.{ pkg_dir, "backend.manifest.zon" }) catch return false;
    defer allocator.free(manifest_path);
    std.Io.Dir.cwd().access(config.globalIo(), manifest_path, .{}) catch return false;
    return true;
}

/// Resolve the backend package directory (the cached/local `backends/<dir>/`
/// slot) the same way `loadBackendTemplate` / `deps_linker` do. Caller owns the
/// returned path.
///
/// Locate the backend package so the splice can read its manifest (chicken-and-
/// egg: the dir name lives in the manifest we haven't read yet, so we resolve by
/// the backend's *name*). Now routed through the `backend_registry` — keyed by
/// `cfg.backendName()`, a string, NOT `@tagName` directly. The only residual
/// enum coupling is config *parsing* (`.backend` is still the closed enum, so
/// `backendName()` only yields built-in names today); opening config to an
/// arbitrary name+package is the next step, after which a third-party backend
/// flows through this same registry lookup with no enum entry.
fn backendPackageDir(allocator: std.mem.Allocator, cfg: ProjectConfig, project_dir: []const u8) ![]const u8 {
    // Routed through `resolveBackendPackage` so an EXTERNAL backend (resolved via
    // the plugin infra) reads its manifest from the plugin checkout, while a
    // built-in resolves to its `backends/{name}` bundled slot exactly as before.
    return backend_registry.resolveBackendPackage(allocator, cfg, project_dir);
}

/// Load + parse `backend.manifest.zon` from the backend package.
/// Caller must `free` with `freeManifest`.
pub fn loadManifest(allocator: std.mem.Allocator, cfg: ProjectConfig, project_dir: []const u8) !BackendManifest {
    const pkg_dir = try backendPackageDir(allocator, cfg, project_dir);
    defer allocator.free(pkg_dir);

    const manifest_path = try std.fs.path.join(allocator, &.{ pkg_dir, "backend.manifest.zon" });
    defer allocator.free(manifest_path);

    const raw = try std.Io.Dir.cwd().readFileAlloc(config.globalIo(), manifest_path, allocator, .limited(64 * 1024));
    defer allocator.free(raw);
    const raw_z = try allocator.dupeZ(u8, raw);
    defer allocator.free(raw_z);

    return std.zon.parse.fromSliceAlloc(BackendManifest, allocator, raw_z, null, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.log.warn("labelle-assembler: failed to parse backend.manifest.zon at {s}: {any}", .{ manifest_path, err });
        return error.BackendManifestParseError;
    };
}

pub fn freeManifest(allocator: std.mem.Allocator, m: BackendManifest) void {
    std.zon.parse.free(allocator, m);
}

/// Read a build fragment file from the backend package. Caller owns bytes.
fn readFragment(allocator: std.mem.Allocator, cfg: ProjectConfig, project_dir: []const u8, rel: []const u8) ![]const u8 {
    const pkg_dir = try backendPackageDir(allocator, cfg, project_dir);
    defer allocator.free(pkg_dir);
    const path = try std.fs.path.join(allocator, &.{ pkg_dir, rel });
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(config.globalIo(), path, allocator, .limited(64 * 1024));
}

// ── Param computation ───────────────────────────────────────────────────
// Values are computed with the SAME predicates the enum path uses
// (build_files.zig backend-dep switch). Keyed by the param name the manifest
// declares, so the splice feeds exactly the set the fragment needs and no more.

fn paramValue(name: []const u8, cfg: ProjectConfig) []const u8 {
    if (std.mem.eql(u8, name, "with_imgui") or std.mem.eql(u8, name, "gui_enabled")) {
        // sokol spells this `with_imgui`, bgfx spells it `gui_enabled`; both are
        // the same imgui-only predicate (true iff the resolved gui plugin is
        // imgui). Two names, one computation — matches both enum branches.
        return if (cfg.resolved_gui) |gui|
            (if (std.mem.eql(u8, gui.name, "imgui")) "true" else "false")
        else
            "false";
    }
    if (std.mem.eql(u8, name, "gamepad_enabled")) {
        return if (cfg.gamepad == .auto) "true" else "false";
    }
    if (std.mem.eql(u8, name, "gamepad_hidapi")) {
        return if (cfg.gamepad_hidapi) "true" else "false";
    }
    return "";
}

/// Render the fragment against the manifest-declared param set using the
/// dynamic template engine (runtime string map — the param list is data, not a
/// comptime struct). Equivalent to the enum path's
/// `tpl.renderSection(.., .{ .with_imgui = .., .. })`.
fn renderFragmentWithParams(
    allocator: std.mem.Allocator,
    fragment: []const u8,
    param_names: []const []const u8,
    cfg: ProjectConfig,
    w: anytype,
) !void {
    var data = tpl.TemplateData{
        .scalars = std.StringHashMap([]const u8).init(allocator),
        .lists = std.StringHashMap([]const tpl.ListItem).init(allocator),
    };
    defer data.scalars.deinit();
    defer data.lists.deinit();
    for (param_names) |name| {
        try data.scalars.put(name, paramValue(name, cfg));
    }
    try tpl.renderDynamic(fragment, data, w);
}

/// Splice replacement for the backend-dep enum branch
/// (`renderSection(.., "backend_<tag>", ..)`).
pub fn renderBackendDepSection(
    allocator: std.mem.Allocator,
    m: BackendManifest,
    cfg: ProjectConfig,
    project_dir: []const u8,
    w: anytype,
) !void {
    const fragment = try readFragment(allocator, cfg, project_dir, m.build_fragments.backend_dep);
    defer allocator.free(fragment);
    try renderFragmentWithParams(allocator, fragment, m.params.backend_dep, cfg, w);
}

/// Splice replacement for the link enum branch (`writeSection(.., "link_<tag>")`).
pub fn renderLinkSection(
    allocator: std.mem.Allocator,
    m: BackendManifest,
    cfg: ProjectConfig,
    project_dir: []const u8,
    w: anytype,
) !void {
    const fragment = try readFragment(allocator, cfg, project_dir, m.build_fragments.link);
    defer allocator.free(fragment);
    // No params declared → emit verbatim (matches the enum path's
    // `writeSection`, which does no substitution). bgfx's `link` and sokol's
    // `link` are both verbatim.
    if (m.params.link.len == 0) {
        try w.writeAll(fragment);
    } else {
        try renderFragmentWithParams(allocator, fragment, m.params.link, cfg, w);
    }
}

/// Splice replacement for `use_callback_lifecycle = cfg.backend == .sokol or ...`
/// — the run-loop selector. sokol's manifest declares `.callback`, bgfx's
/// declares `.loop`; the caller turns this into `ls == .callback`.
pub fn loopStyle(m: BackendManifest) BackendManifest.LoopStyle {
    return m.loop_style;
}

/// Splice replacement for the `loadBackendTemplate` backend→`desktop.txt`
/// mapping. Returns the main-loop template path relative to the backend
/// package root.
pub fn mainLoopTemplateRel(m: BackendManifest) []const u8 {
    return m.main_loop_template;
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

    try requireManifestIfExternal(alloc, cfg, project_abs);
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
        requireManifestIfExternal(alloc, cfg, project_abs),
    );
}

test "requireManifestIfExternal: a built-in backend is a no-op even with no manifest" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "project");
    const project_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "project", alloc);
    defer alloc.free(project_abs);

    // Built-in sokol ships no manifest — must NOT error (keeps enum path).
    // (raylib is now extracted out-of-tree (#386); sokol is the last bundled one.)
    const cfg = config.ProjectConfig{ .name = "g", .backend = .sokol };
    try requireManifestIfExternal(alloc, cfg, project_abs);
}
