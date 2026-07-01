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
//! None of the above names a backend enum tag. Package LOCATION
//! (`backendPackageDir`) is likewise enum-free: it routes through
//! `backend_registry.resolveBackendPackage`, keyed by `cfg.backendName()` (a
//! STRING), so a third-party backend named only by `.backend_package` — with no
//! matching `Backend` enum tag — resolves + generates through this same registry
//! + its (v2) manifest, never through `@tagName(cfg.backend)` (open-config, #453
//! PR 11). The enum survives only as a shorthand for the 6 built-ins; the one
//! remaining enum-as-identity read is `cfg.isEnumTagBacked()` (config.zig), which
//! a name-only backend never satisfies.

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

    /// Canonical provider identity — a reverse-namespaced `<namespace>.<name>`
    /// (RFC "Provider identity & collision rules", §1616). Official providers
    /// live under the reserved `labelle.` namespace (`labelle.sokol`); a third
    /// party uses `<vendor>.<name>`. Optional for back-compat: an absent `.id`
    /// on a built-in is DERIVED as `labelle.<name>` (no error); on an external
    /// provider it warns (required-id is enforced in a later release). See
    /// `backend_registry.validateProviderIdentity`.
    id: ?[]const u8 = null,

    /// Capabilities this provider advertises (RFC "Capability negotiation",
    /// §1652). Defaults empty so pre-capability manifests keep parsing under
    /// `ignore_unknown_fields`; a non-empty set OPTS IN to enforcement
    /// (`capabilities.validate` fails on a missing required capability; an
    /// empty declared set only warns — the back-compat gate).
    capabilities: []const config.Capability = &.{},

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

/// The production (v1) manifest filename. Used whenever `manifest_name` is null,
/// so the enum/v1 splice + every root.zig generator keeps reading
/// `backend.manifest.zon` byte-for-byte as before. manifest-v2 (epic #453 item 3)
/// opts a backend onto a DIFFERENT filename (`backend.manifest.v2.zon`), and the
/// gate + external-manifest requirement below must key off THAT requested name —
/// otherwise a backend shipping ONLY the v2 manifest is wrongly treated as
/// manifest-less and never reaches the v2 codegen path.
pub const LEGACY_MANIFEST_NAME = "backend.manifest.zon";

/// True when the manifest path should be taken for this generation: the target
/// is a DESKTOP build (the only target manifests cover) AND the resolved
/// backend package ships the requested manifest file. Everything else —
/// non-desktop targets, and backends with no matching manifest — stays on the
/// enum path.
///
/// `manifest_name` is the filename to probe, relative to the backend package
/// root. Null selects the production `backend.manifest.zon` (v1). manifest-v2
/// passes the v2 filename so a v2-only backend (no legacy sibling) still enables
/// the manifest path.
///
/// This is the productionized gate: a backend opts in by SHIPPING A MANIFEST,
/// no env var. bgfx-desktop ships one (→ manifest path); sokol ships one too
/// (the POC artifact). raylib/sdl/wgpu/null ship none (→ enum path).
pub fn manifestPathEnabled(allocator: std.mem.Allocator, cfg: ProjectConfig, project_dir: []const u8, manifest_name: ?[]const u8) bool {
    // The V1 splice declares desktop fields only, so a null (production) name
    // keeps non-desktop targets (wasm/ios/android) on their enum branches (e.g.
    // bgfx-android's NDK ordering). An EXPLICIT `manifest_name` is the manifest-v2
    // opt-in (epic #453): v2 manifests carry a full per-platform matrix, so the
    // path is enabled on any platform when the named manifest exists. build_files
    // routes a v2 manifest to the v2 codegen and IGNORES a v1 manifest on a
    // non-desktop target (falling back to the enum path), so relaxing the gate
    // here cannot mis-drive the desktop-only v1 splice on android/ios/wasm.
    if (cfg.platform != .desktop and manifest_name == null) return false;
    return manifestExists(allocator, cfg, project_dir, manifest_name orelse LEGACY_MANIFEST_NAME);
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
///
/// `manifest_name` is the required filename, relative to the backend package
/// root. Null selects the production `backend.manifest.zon` (v1); manifest-v2
/// passes the v2 filename so the requirement is keyed off the SAME manifest the
/// gate/loader will read (a v2-only external must not be flagged manifest-less
/// just because it ships no legacy sibling).
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
            // the human-readable hint. Matches `loadManifest`'s warn-on-failure.
            std.log.warn(
                "labelle-assembler: external backend '{s}' (backend_package) ships no {s} — " ++
                    "an external backend must declare its codegen via a manifest (the enum-path fallback does not apply to external backends).",
                .{ cfg.backendName(), name },
            );
            return error.ExternalBackendNeedsManifest;
        },
        else => return err, // real resolution/access failure — surface it, don't mask it
    };
}

/// Does the resolved backend package contain the named manifest file?
/// Resolution failures / a missing file both mean "no manifest" → enum path.
fn manifestExists(allocator: std.mem.Allocator, cfg: ProjectConfig, project_dir: []const u8, manifest_name: []const u8) bool {
    const pkg_dir = backendPackageDir(allocator, cfg, project_dir) catch return false;
    defer allocator.free(pkg_dir);
    const manifest_path = std.fs.path.join(allocator, &.{ pkg_dir, manifest_name }) catch return false;
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

/// The RESOLVE-TIME slice of a backend manifest: provider identity + declared
/// capabilities ONLY. Parsed with `ignore_unknown_fields`, so it reads the same
/// `backend.manifest.zon` the full `BackendManifest` does but ignores the
/// desktop-only splice fields (`dir_name`/`loop_style`/`build_fragments`/…).
///
/// This is deliberately DECOUPLED from `manifestPathEnabled` (which is
/// desktop-only, because the splice fragments it drives only cover desktop):
/// identity + capability negotiation happen at resolve time on EVERY target
/// (android/wasm/ios included), so they must not be gated behind the
/// desktop-only splice. A provider ships one manifest; this reads the
/// platform-independent half of it.
pub const ProviderManifest = struct {
    id: ?[]const u8 = null,
    capabilities: []const config.Capability = &.{},
};

/// Load the provider-identity / capability slice of `backend.manifest.zon`,
/// regardless of target platform. Returns `null` when the resolved backend
/// package ships NO manifest (a built-in with no manifest → identity derived,
/// capabilities un-enforced). Errors only on a genuine parse failure. Caller
/// frees the result with `freeProviderManifest`.
pub fn loadProviderManifest(allocator: std.mem.Allocator, cfg: ProjectConfig, project_dir: []const u8) !?ProviderManifest {
    const pkg_dir = backendPackageDir(allocator, cfg, project_dir) catch return null;
    defer allocator.free(pkg_dir);

    const manifest_path = try std.fs.path.join(allocator, &.{ pkg_dir, "backend.manifest.zon" });
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
    // manifest-v2 regression (#453): a backend shipping ONLY `backend.manifest.v2.zon`
    // — no legacy `backend.manifest.zon` — must be ACCEPTED when the requested name
    // is the v2 file, and still REJECTED when the (absent) legacy name is requested.
    // Proves the requirement gate keys off `manifest_name`, not the hardcoded legacy.
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
    // Post-#386 Phase 6c every built-in (incl. sokol) is external, so there is no
    // longer any non-external config to exercise the `!isExternal()` early return
    // (now defensive dead code). What IS still load-bearing: `backends/sokol` is
    // retained as the offline in-tree fixture and MUST ship a `backend.manifest.zon`
    // so the generic codegen tests can resolve a real manifest. Selecting it via an
    // explicit `.backend_package` (the post-flip shape) + the repo root as
    // project_dir (tests run with the assembler repo root as cwd) must be ACCEPTED.
    const alloc = std.testing.allocator;
    const cfg = config.ProjectConfig{
        .name = "g",
        .backend = .sokol,
        .backend_package = .{ .name = "sokol", .repo = "local:backends/sokol" },
    };
    try requireManifestIfExternal(alloc, cfg, ".", null);
}

// ── Tests: provider identity + capability slice (#453) ────────────────────

test "BackendManifest: an OLD manifest with no .id/.capabilities still parses" {
    // Back-compat: a pre-#453 manifest (no identity, no capabilities) must
    // still parse under `ignore_unknown_fields`; the new fields default (null /
    // empty). Byte-identical generation for such built-ins is unaffected.
    const alloc = std.testing.allocator;
    const src =
        \\.{
        \\    .dir_name = "legacy",
        \\    .dep_name = "labelle_legacy",
        \\    .loop_style = .loop,
        \\    .main_loop_template = "templates/desktop.txt",
        \\    .build_fragments = .{ .backend_dep = "a.txt", .link = "b.txt" },
        \\    .params = .{ .backend_dep = .{}, .link = .{} },
        \\}
    ;
    const src_z = try alloc.dupeZ(u8, src);
    defer alloc.free(src_z);

    const m = try std.zon.parse.fromSliceAlloc(BackendManifest, alloc, src_z, null, .{ .ignore_unknown_fields = true });
    defer std.zon.parse.free(alloc, m);

    try std.testing.expect(m.id == null);
    try std.testing.expectEqual(@as(usize, 0), m.capabilities.len);
}

test "ProviderManifest: parses the id + capability slice, ignoring splice fields" {
    // The decoupled resolve-time slice reads the SAME file the full manifest
    // does but only cares about `.id` / `.capabilities`; the desktop-only
    // splice fields are ignored (ignore_unknown_fields).
    const alloc = std.testing.allocator;
    const src =
        \\.{
        \\    .dir_name = "sokol",
        \\    .dep_name = "labelle_sokol",
        \\    .loop_style = .callback,
        \\    .main_loop_template = "templates/desktop.txt",
        \\    .build_fragments = .{ .backend_dep = "a.txt", .link = "b.txt" },
        \\    .params = .{ .backend_dep = .{}, .link = .{} },
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
