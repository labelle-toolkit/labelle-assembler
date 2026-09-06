/// `build.zig.zon` generator for the labelle-cli assembler.
///
/// Extracted from the former single-file `build_files.zig` (behavior-preserving
/// split, mirrors #539/#541). Emits the generated project's `build.zig.zon`
/// dependency manifest — either off the shared `.labelle/deps/` hardlinks or, as
/// a fallback, cache-relative paths.
const std = @import("std");
const tpl = @import("../template.zig");
const config = @import("../config.zig");
const cache = @import("../cache.zig");
const backend_registry = @import("../backend_registry.zig");
const manifest_splice = @import("../codegen/manifest_splice.zig");
const manifest_v2 = @import("../codegen/manifest_v2.zig");
const manifest_v2_splice = @import("../codegen/manifest_v2_splice.zig");
const zonPath = @import("../zon_escape.zig").zonPath;
pub const deps_linker = @import("../deps_linker.zig");

const ProjectConfig = config.ProjectConfig;

// Build file template
const build_zig_zon_tmpl = @embedFile("../templates/build_zig_zon.txt");

// ============================================================
// build.zig.zon generator
// ============================================================

pub const BuildZigZonOptions = struct {
    /// True (default) wipes the shared `.labelle/deps/` directory before
    /// recreating it. The tests target (issue #83) sets this to false so
    /// the second-pass generation merges its null-backend dep into the
    /// existing dir without orphaning the exe target's chosen-backend dep.
    recreate_deps: bool = true,
    /// Which backend manifest file to load, relative to the resolved backend
    /// package root (manifest-v2, epic #453 item 3, PR 7). Null (default) keeps
    /// the PRODUCTION path 100% unchanged: emsdk is emitted for any wasm build
    /// via the hardcoded `dep_emsdk` section. When set AND the named manifest is
    /// `manifest_version >= 2`, the wasm emsdk dependency is instead driven by the
    /// manifest's `.platforms.wasm.root_build_deps` (design §3 `RootBuildDep`,
    /// review #459 finding 2) — a `.builtin` emsdk resolves to that same pinned
    /// section, so the emitted zon stays byte-identical. Mirrors
    /// `BuildZigOptions.backend_manifest_name`.
    backend_manifest_name: ?[]const u8 = null,
};

/// The `build.zig.zon` dependency KEY for the backend on the manifest-v2 path.
///
/// A v2 backend's generated `build.zig` resolves its provider modules via
/// `b.dependency(m.dep_name, ..)` (e.g. `b.dependency("acme_foo", ..)` for a
/// third-party backend), so the `build.zig.zon` dependency entry MUST be keyed
/// by `m.dep_name` — NOT the `labelle_<name>` derivation the zon generator /
/// deps-linker otherwise uses. The two diverge for a third-party backend whose
/// package name is not `labelle_*` (acme_foo → dep key `labelle_acme_foo` in the
/// zon vs `b.dependency("acme_foo")` in build.zig), so Zig can't resolve the
/// backend dependency. For a BUILT-IN v2 backend `m.dep_name` already equals the
/// `labelle_<name>` derivation (sokol → `labelle_sokol`), so the emitted key is
/// byte-unchanged.
///
/// Returns null — meaning "keep the `labelle_<name>` derivation" — for the
/// v1/enum path, when no manifest is requested, or when the requested manifest
/// isn't enabled for this target. Allocator-owned; caller frees. Errors
/// propagate exactly as the root-build-deps load does (a broken v2 manifest
/// fails zon generation, matching the build.zig generator — #468 finding 1).
fn v2BackendDepName(
    allocator: std.mem.Allocator,
    cfg: ProjectConfig,
    project_dir: ?[]const u8,
    backend_manifest_name: ?[]const u8,
) !?[]const u8 {
    const pd = project_dir orelse return null;
    const name = backend_manifest_name orelse return null;
    if (!manifest_splice.manifestPathEnabled(allocator, cfg, pd, name)) return null;
    const m = try manifest_v2.loadNamedManifest(allocator, cfg, pd, name);
    defer std.zon.parse.free(allocator, m);
    return try allocator.dupe(u8, m.dep_name);
}

pub fn generateBuildZigZon(allocator: std.mem.Allocator, cfg: ProjectConfig, target_dir: ?[]const u8, output_dir: ?[]const u8, project_dir: ?[]const u8, opts: BuildZigZonOptions) ![]const u8 {
    var alloc_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer alloc_writer.deinit();
    const w = &alloc_writer.writer;

    // Create deps/ hardlinks in .labelle/deps/ (shared across targets).
    // On failure (e.g. a `local:` plugin pointing at a non-existent
    // directory), log loudly and fall back to cache-relative paths.
    // Silent failure used to mask the underlying issue and surface
    // later as cryptic "package's path-relative dep doesn't resolve"
    // errors during `zig build` — see labelle-toolkit/labelle-cli#174.
    const deps_parent = output_dir orelse target_dir;
    const resolved_deps: ?[]const deps_linker.DepEntry = if (deps_parent != null and project_dir != null)
        deps_linker.createDepsLinks(allocator, cfg, deps_parent.?, project_dir.?, .{ .recreate = opts.recreate_deps }) catch |err| blk: {
            // OOM is not recoverable by retrying with cache-relative
            // paths — those need allocation too. Propagate so the caller
            // can fail cleanly instead of papering over the failure.
            if (err == error.OutOfMemory) return err;
            // Cache location is configurable via `LABELLE_HOME` (see
            // `src/cache.zig`), so we don't hardcode `~/.labelle/...`
            // in the user-facing message — and we route via std.log.warn
            // for proper level / sink integration with the rest of the
            // CLI's output.
            std.log.warn(
                "createDepsLinks failed ({s}); falling back to cache-relative dep paths.\n" ++
                    "  This often masks the real cause: a `local:` plugin path that doesn't exist,\n" ++
                    "  or a missing entry in the package cache. Check your project.labelle plugins.",
                .{@errorName(err)},
            );
            break :blk null;
        }
    else
        null;
    // Free `resolved_deps` on every subsequent error path. This defer must be
    // installed here — immediately after assignment — because fallible calls
    // below (e.g. `v2BackendDepName`) can return before the
    // `if (resolved_deps) |deps|` block, leaking the entries otherwise.
    defer if (resolved_deps) |deps| deps_linker.freeDepEntries(allocator, deps);

    // Zig 0.16 validates `build.zig.zon` fingerprints with the formula
    // `(fingerprint >> 32) == std.hash.Crc32.hash(name)` where `name`
    // is the literal `.name` field in the zon file — *not* the project
    // name from project.labelle. The template hardcodes
    // `.name = .generated_game,` so the CRC seed is fixed too. The
    // lower 32 bits are a free-form "fork ID" derived from cfg.name so
    // regenerating yields a stable value per project (no gratuitous
    // cache invalidation). The previous FNV-1a-based hash produced
    // fingerprints rejected by Zig 0.16's validator.
    //
    // The id half can't be 0 (reserved by Zig 0.16 for "unhashed") or
    // 0xffffffff (reserved for "explicitly opted out of dedup"). Both
    // reservations are checked in `std.zon.Manifest`; a project name
    // whose Wyhash happens to land on either would generate a zon
    // file that fails validation despite the correct CRC half. Clamp
    // to a safe non-reserved value.
    const zon_package_name = "generated_game";
    const name_crc: u32 = std.hash.Crc32.hash(zon_package_name);
    const fork_id: u32 = blk: {
        var h = std.hash.Wyhash.init(0xa11e11e);
        h.update(cfg.name);
        const raw: u32 = @truncate(h.final());
        // Coerce away the two reserved sentinels.
        break :blk switch (raw) {
            0 => 1,
            0xffffffff => 0xfffffffe,
            else => raw,
        };
    };
    const hash: u64 = (@as(u64, name_crc) << 32) | @as(u64, fork_id);
    var hash_buf: [16]u8 = undefined;
    const hash_str = std.fmt.bufPrint(&hash_buf, "{x}", .{hash}) catch unreachable;

    try tpl.renderSection(build_zig_zon_tmpl, "header", .{ .hash = hash_str, .version = cfg.version }, w);

    // Manifest-v2 backend dep key: the generated build.zig calls
    // `b.dependency(m.dep_name, ..)`, so the zon backend entry must be keyed by
    // `m.dep_name` (see `v2BackendDepName`). Null → keep the `labelle_<name>`
    // derivation (v1/enum path, byte-unchanged; also unchanged for a built-in v2
    // backend whose `dep_name` already equals the derivation).
    const v2_backend_dep_name = try v2BackendDepName(allocator, cfg, project_dir, opts.backend_manifest_name);
    defer if (v2_backend_dep_name) |n| allocator.free(n);

    if (resolved_deps) |deps| {
        // Freed by the `defer` installed right after `resolved_deps` is
        // assigned (above), so it also covers the fallible calls in between.
        // Deps are at .labelle/deps/, zon is at .labelle/<target>/
        const prefix = if (output_dir != null and target_dir != null) "../deps" else "deps";
        // The deps-linker names the backend entry by the `labelle_<name>`
        // convention; on the v2 path that entry (and ONLY it) is re-keyed to
        // `m.dep_name` so build.zig and build.zig.zon agree on the backend dep.
        const derived_backend_zon = try std.fmt.allocPrint(allocator, "labelle_{s}", .{cfg.backendName()});
        defer allocator.free(derived_backend_zon);
        for (deps) |dep| {
            const zon_name = if (v2_backend_dep_name) |dn|
                (if (std.mem.eql(u8, dep.zon_name, derived_backend_zon)) dn else dep.zon_name)
            else
                dep.zon_name;
            try w.print("        .{s} = .{{\n", .{zon_name});
            try w.print("            .path = \"{s}/{s}\",\n", .{ prefix, dep.link_name });
            try w.writeAll("        },\n");
        }
    } else {
        // Fallback: relative paths (for tests without target_dir)
        try generateZonPathsFallback(allocator, cfg, target_dir, project_dir, v2_backend_dep_name, w);
    }

    // Root build-time deps a backend hook resolves via `b.dependency` at consumer
    // build time (design §3 `RootBuildDep`). On the manifest-v2 path (PR 7) the
    // wasm emsdk dep is driven by the manifest's `.platforms.wasm.root_build_deps`;
    // a `.builtin` emsdk reuses the pinned `dep_emsdk` section so the emitted zon
    // is byte-identical to the enum path. The production/enum path keeps the
    // hardcoded per-platform emsdk emission unchanged.
    var v2_root_deps_emitted = false;
    // Mirror `generateBuildZig`'s manifest gate + load so the two generators
    // agree: gate the load on `manifestPathEnabled` (a missing manifest → enum
    // fallback in BOTH), and propagate load errors with `try` rather than
    // swallowing them with `catch null`. A v2 manifest that fails to load must
    // error in build.zig.zon generation exactly as it does in build.zig
    // generation — otherwise a build.zig that resolved its hook deps against a
    // v2 manifest could be paired with a build.zig.zon that silently fell back
    // to enum output, producing a divergent (and broken) pair. #468 finding 1.
    if (project_dir) |pd| {
        if (opts.backend_manifest_name) |name| {
            if (manifest_splice.manifestPathEnabled(allocator, cfg, pd, name)) {
                const m = try manifest_v2.loadNamedManifest(allocator, cfg, pd, name);
                defer std.zon.parse.free(allocator, m);
                const dep_emsdk = tpl.getSection(build_zig_zon_tmpl, "dep_emsdk") orelse "";
                try manifest_v2_splice.emitRootBuildDepsV2(m, cfg.platform, dep_emsdk, w);
                v2_root_deps_emitted = true;
            }
        }
    }
    if (!v2_root_deps_emitted and cfg.platform == .wasm) {
        try tpl.writeSection(build_zig_zon_tmpl, "dep_emsdk", w);
    }

    try tpl.writeSection(build_zig_zon_tmpl, "footer", w);

    var arr_list = alloc_writer.toArrayList();
    return arr_list.toOwnedSlice(allocator);
}

/// Fallback: compute relative paths when deps/ symlinks aren't available.
/// `v2_backend_dep_name` (see `v2BackendDepName`) re-keys the backend dep entry
/// on the manifest-v2 path so it matches `b.dependency(m.dep_name, ..)` in the
/// generated build.zig; null keeps the `labelle_<name>` derivation.
fn generateZonPathsFallback(allocator: std.mem.Allocator, cfg: ProjectConfig, target_dir: ?[]const u8, project_dir: ?[]const u8, v2_backend_dep_name: ?[]const u8, w: anytype) !void {
    const abs_target: ?[]const u8 = if (target_dir) |td|
        std.Io.Dir.cwd().realPathFileAlloc(config.globalIo(), td, allocator) catch null
    else
        null;
    defer if (abs_target) |at| allocator.free(at);

    const core_abs = try cache.resolveFrameworkPackage(allocator, "core", cfg.core_version, project_dir);
    defer allocator.free(core_abs);
    const core_path = try relativePath(allocator, abs_target, core_abs);
    defer allocator.free(core_path);
    const gfx_abs = try cache.resolveFrameworkPackage(allocator, "gfx", cfg.gfx_version, project_dir);
    defer allocator.free(gfx_abs);
    const gfx_path = try relativePath(allocator, abs_target, gfx_abs);
    defer allocator.free(gfx_path);
    const engine_abs = try cache.resolveFrameworkPackage(allocator, "engine", cfg.engine_version, project_dir);
    defer allocator.free(engine_abs);
    const engine_path = try relativePath(allocator, abs_target, engine_abs);
    defer allocator.free(engine_path);

    try tpl.renderSection(build_zig_zon_tmpl, "dep_core_path", .{ .core_path = core_path, .gfx_path = gfx_path, .engine_path = engine_path }, w);

    for (cfg.plugins) |plugin| {
        const p_abs = try cache.resolvePlugin(allocator, plugin, project_dir);
        defer allocator.free(p_abs);
        const p = try relativePath(allocator, abs_target, p_abs);
        defer allocator.free(p);
        try w.print("        .labelle_{s} = .{{ .path = \"{s}\" }},\n", .{ plugin.name, p });
    }

    {
        const bn = cfg.backendName();
        // Location seam: built-in → bundled slot; external → plugin checkout.
        const bp_abs = try backend_registry.resolveBackendPackage(allocator, cfg, project_dir);
        defer allocator.free(bp_abs);
        const bp = try relativePath(allocator, abs_target, bp_abs);
        defer allocator.free(bp);
        if (cfg.isExternal()) {
            // External backends have no per-name `dep_<name>_path` template
            // section — emit the dep inline (same shape as the plugin loop and
            // the built-in template sections: `.labelle_<name> = .{ .path }`).
            // On the v2 path the entry is keyed by `m.dep_name` so it matches
            // `b.dependency(m.dep_name, ..)` in the generated build.zig; the
            // v1/enum path keeps the `labelle_<name>` derivation.
            if (v2_backend_dep_name) |dn| {
                try w.print("        .{s} = .{{ .path = \"{s}\" }},\n", .{ dn, bp });
            } else {
                try w.print("        .labelle_{s} = .{{ .path = \"{s}\" }},\n", .{ bn, bp });
            }
        } else {
            // Built-in: keep the embedded per-name template section so the
            // generated zon stays byte-identical to before this change.
            var sb: [64]u8 = undefined;
            const section = std.fmt.bufPrint(&sb, "dep_{s}_path", .{bn}) catch unreachable;
            try tpl.renderSection(build_zig_zon_tmpl, section, .{ .backend_path = bp }, w);
        }
    }

    switch (cfg.ecs) {
        .mock => {},
        .zig_ecs, .zflecs, .mr_ecs => {
            const dn: []const u8 = switch (cfg.ecs) {
                .zig_ecs => "labelle_zig_ecs",
                .zflecs => "labelle_zflecs",
                .mr_ecs => "labelle_mr_ecs",
                .mock => unreachable,
            };
            const dd: []const u8 = switch (cfg.ecs) {
                .zig_ecs => "zig-ecs",
                .zflecs => "zflecs",
                .mr_ecs => "mr-ecs",
                .mock => unreachable,
            };
            var spb: [128]u8 = undefined;
            const sp = std.fmt.bufPrint(&spb, "ecs/{s}", .{dd}) catch unreachable;
            const ep_abs = try cache.resolveBundledPackage(allocator, cfg.labelle_version, cfg.assembler_version, project_dir, sp);
            defer allocator.free(ep_abs);
            const ep = try relativePath(allocator, abs_target, ep_abs);
            defer allocator.free(ep);
            try tpl.renderSection(build_zig_zon_tmpl, "dep_ecs_path", .{ .ecs_dep_name = dn, .ecs_path = ep }, w);
        },
    }

    if (cfg.resolved_gui) |gui| {
        const gp = try relativePath(allocator, abs_target, gui.plugin_dir);
        defer allocator.free(gp);
        try tpl.renderSection(build_zig_zon_tmpl, "dep_gui_path", .{ .gui_dep_name = "labelle_gui", .gui_path = gp }, w);
        if (gui.bridge_dir) |bd| {
            const bp = try relativePath(allocator, abs_target, bd);
            defer allocator.free(bp);
            try tpl.renderSection(build_zig_zon_tmpl, "dep_gui_bridge_path", .{ .bridge_path = bp }, w);
        }
    }
}

/// Compute a relative path from `from_dir` to `to_path`, ready to embed in a
/// ZON string literal.
/// If from_dir is null, uses `to_path` as-is (absolute).
/// Both must be absolute paths when from_dir is provided. Returns an allocator-owned string.
///
/// `zonPath` does two things on the way out, both of which only matter on
/// Windows (#708) — which is why CI on Linux and macOS could never have
/// caught them: it normalises the host separator to the `/` the deps-linked
/// emitter above hardcodes, so the same project yields the same manifest on
/// every host, and it escapes the result, because a backslash is both the
/// Windows separator and the escape character in a Zig string literal
/// (`..\deps\x` read back as `error: invalid escape character: 'd'`).
///
/// Only the HOST separator is rewritten: a backslash is ordinary filename
/// data on POSIX and must survive escaped rather than be translated into a
/// different path (#708 review).
fn relativePath(allocator: std.mem.Allocator, from_dir: ?[]const u8, to_path: []const u8) ![]const u8 {
    const raw = if (from_dir == null)
        try allocator.dupe(u8, to_path)
    else
        try std.fs.path.relative(allocator, "", null, from_dir.?, to_path);
    defer allocator.free(raw);

    return zonPath(allocator, raw);
}
