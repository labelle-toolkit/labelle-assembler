/// deps_linker — creates a deps/ directory with hardlinked copies of resolved packages.
/// Replaces long relative paths in build.zig.zon with short "deps/<name>" paths.
///
/// Uses hardlinks for files (works on all platforms without admin) and
/// creates directory structure manually. Falls back to file copy if
/// hardlinks fail (e.g. cross-device).
const std = @import("std");
const config = @import("config.zig");
const cache = @import("cache.zig");
const backend_registry = @import("backend_registry.zig");
const deps_sync = @import("deps_sync.zig");
const write_if_changed = @import("write_if_changed.zig");

const ProjectConfig = config.ProjectConfig;

pub const DepEntry = struct {
    zon_name: []const u8,
    link_name: []const u8,
    abs_path: []const u8,
};

/// Whether the shared SDL desktop-gamepad sub-package (`backends/sdl_gamepad`)
/// is staged for `cfg`. Built-in-specific: raylib/sokol/bgfx whose EFFECTIVE
/// gamepad source resolves to `.auto` (via `cfg.effectiveGamepad()` — so bgfx
/// with an absent `.gamepad` resolves to `.none` and stages nothing, per
/// assembler#533). An EXTERNAL backend is self-contained — it stages none of these
/// sub-packages (it declares its own gamepad source in its staged zon), so the
/// gate is OFF regardless of the enum. This is the exact predicate the
/// `if (!cfg.isExternal()) switch (cfg.effectiveBackend())` site below uses, factored out
/// so it's unit-testable without disk I/O.
///
/// DEFENSIVE DEAD CODE (post-#386 Phase 6c): every `Backend` tag now resolves to
/// an external provider via `builtinProvider`, so `isExternal()` is true for
/// EVERY config and the `.raylib, .sokol, .bgfx` arm below is unreachable —
/// pinned by the "stagesSdlGamepad: every built-in is now external" test. Kept
/// (not deleted) for a future bundled backend; do NOT add new tags here
/// (assembler#501 forbids enum growth).
pub fn stagesSdlGamepad(cfg: ProjectConfig) bool {
    if (cfg.isExternal()) return false;
    return switch (cfg.effectiveBackend()) {
        // Route through the resolver (never read `cfg.gamepad` directly): a bgfx
        // project with an ABSENT `.gamepad` resolves to `.none` (assembler#533),
        // so it stages no SDL, while raylib/sokol keep the `.auto` default.
        .raylib, .sokol, .bgfx => cfg.effectiveGamepad() == .auto,
        else => false,
    };
}

/// Whether the shared Android gamepad sub-package (`backends/android_gamepad`)
/// is staged for `cfg`. Built-in-specific: sokol/bgfx. OFF for an external
/// backend (self-contained). Mirrors the gated `switch (cfg.effectiveBackend())` site below.
///
/// DEFENSIVE DEAD CODE (post-#386 Phase 6c): every `Backend` tag now resolves to
/// an external provider via `builtinProvider`, so `isExternal()` is true for
/// EVERY config and the `.sokol, .bgfx` arm below is unreachable — pinned by the
/// "stagesAndroidGamepad: every built-in is now external" test. Kept (not
/// deleted) for a future bundled backend; do NOT add new tags here
/// (assembler#501 forbids enum growth).
pub fn stagesAndroidGamepad(cfg: ProjectConfig) bool {
    if (cfg.isExternal()) return false;
    return switch (cfg.effectiveBackend()) {
        .sokol, .bgfx => true,
        else => false,
    };
}

pub const DepsLinkOptions = struct {
    /// True (default) removes top-level `deps/` entries this pass did not
    /// stage (a dropped plugin, a switched backend) — except `keep`. Every
    /// staged package is reconciled IN PLACE either way (`deps_sync`, #674):
    /// `deps/` is never wiped, so unchanged files keep their identity and
    /// mtime and a live `zig build --watch` keeps its directory watches.
    ///
    /// The tests target (issue #83) runs second and sets this to false: it
    /// only adds the null backend's package to the dir the exe pass
    /// reconciled, and must not sweep the exe's chosen-backend package.
    prune: bool = true,
    /// Top-level entries the prune must leave alone: the packages ANOTHER
    /// pass of the same generate stages. The exe pass passes the tests
    /// target's backend link here — otherwise each generate would sweep it
    /// and the tests pass would re-stage it, churning the tree every run.
    keep: []const []const u8 = &.{},
};

pub fn createDepsLinks(
    allocator: std.mem.Allocator,
    cfg: ProjectConfig,
    target_dir: []const u8,
    project_dir: []const u8,
    opts: DepsLinkOptions,
) ![]const DepEntry {
    var deps: std.ArrayList(DepEntry) = .empty;
    // On any error return, the caller never receives `deps` (so can't call
    // freeDepEntries) — free the already-appended entries + the list backing
    // here. Fires ONLY on error; on success `toOwnedSlice` below transfers the
    // backing and leaves `deps` empty, so this is a no-op. Complements (doesn't
    // double-free with) the per-entry errdefers in the backend-dep block: those
    // fire only when an append itself fails (entry not yet in `deps`).
    errdefer {
        freeDepEntries(allocator, deps.items);
        deps.deinit(allocator);
    }

    // #685: this is the one place every framework/plugin dep is resolved
    // exactly once per generate, so it is where a build says out loud that a
    // package is NOT the version its pin names.
    const core_path = try cache.resolveFrameworkPackage(allocator, "core", cfg.core_version, project_dir);
    cache.warnIfLocallySourced(allocator, "core", cfg.core_version, core_path);
    try deps.append(allocator, .{ .zon_name = try allocator.dupe(u8, "labelle_core"), .link_name = try allocator.dupe(u8, "labelle-core"), .abs_path = core_path });

    const gfx_path = try cache.resolveFrameworkPackage(allocator, "gfx", cfg.gfx_version, project_dir);
    cache.warnIfLocallySourced(allocator, "gfx", cfg.gfx_version, gfx_path);
    try deps.append(allocator, .{ .zon_name = try allocator.dupe(u8, "labelle_gfx"), .link_name = try allocator.dupe(u8, "labelle-gfx"), .abs_path = gfx_path });

    const engine_path = try cache.resolveFrameworkPackage(allocator, "engine", cfg.engine_version, project_dir);
    cache.warnIfLocallySourced(allocator, "engine", cfg.engine_version, engine_path);
    try deps.append(allocator, .{ .zon_name = try allocator.dupe(u8, "engine"), .link_name = try allocator.dupe(u8, "labelle-engine"), .abs_path = engine_path });

    for (cfg.plugins) |plugin| {
        const plugin_path = try cache.resolvePlugin(allocator, plugin, project_dir);
        // A `local:` plugin declares its locality in `.repo`, not `.version`,
        // so it needs its own skip — it is already self-describing.
        if (!plugin.isLocal()) cache.warnIfLocallySourced(allocator, plugin.name, plugin.version, plugin_path);
        const zon_name = try std.fmt.allocPrint(allocator, "labelle_{s}", .{plugin.name});
        const link_name = try std.fmt.allocPrint(allocator, "labelle-{s}", .{plugin.name});
        try deps.append(allocator, .{ .zon_name = zon_name, .link_name = link_name, .abs_path = plugin_path });
    }

    // The assembler-bundled packages (built-in backends, ecs adapters, gui)
    // all come out of ONE slot, so they get ONE warning rather than one per
    // `resolveBundledPackage` call (#688 review). Probing the slot through
    // the same resolver the deps use keeps the two in step.
    {
        const asm_ver = config.assemblerPackageVersion(cfg.assembler_version);
        if (!config.isLocalVersion(asm_ver)) {
            const bundled = try cache.resolveBundledPackage(allocator, cfg.labelle_version, cfg.assembler_version, project_dir, "backends");
            defer allocator.free(bundled);
            cache.warnIfLocallySourced(allocator, "assembler", asm_ver, bundled);
        }
    }

    {
        // Tight scope: `zon_name`/`link_name`/`backend_path` are MOVED into the
        // DepEntry on a successful append (then owned by `deps`, freed by
        // freeDepEntries). The errdefers cover only the allocate→append window —
        // on success this inner block exits normally so they don't fire; on any
        // error up to and including the append they free the not-yet-moved
        // allocations. Scoped tightly so the later gamepad appends (also failable)
        // can't re-trigger them into a double-free. `subpath` is never moved, so
        // it's a plain `defer`.
        {
            const backend_info = try backend_registry.lookup(allocator, cfg.backendName());
            defer allocator.free(backend_info.subpath);
            errdefer allocator.free(backend_info.zon_name);
            errdefer allocator.free(backend_info.link_name);
            // Location seam: built-in → bundled `backends/{name}` slot; external
            // → the plugin checkout (`resolvePlugin`). The zon/link names follow
            // the same `labelle_{name}` / `labelle-{name}` convention either way.
            const backend_path = try backend_registry.resolveBackendPackage(allocator, cfg, project_dir);
            errdefer allocator.free(backend_path);
            // #688 review: the backend is resolved here, not in the loop above,
            // so it needs its own warning — a version-pinned backend served
            // from a local slot is exactly as misleading as a plugin one. An
            // explicitly `local:` backend declares its locality in `.repo` and
            // is skipped, matching the plugin loop.
            if (cfg.effectiveBackendPackage()) |bp| {
                if (!bp.isLocal()) cache.warnIfLocallySourced(allocator, bp.name, bp.version, backend_path);
            }
            try deps.append(allocator, .{ .zon_name = backend_info.zon_name, .link_name = backend_info.link_name, .abs_path = backend_path });
        }

        // Backend-owned transitive sub-package: the shared windowless-SDL
        // desktop gamepad source (`backends/sdl_gamepad/`, core#28). Both the
        // raylib and sokol desktop backends declare it as a relative-path dep
        // (`.labelle_sdl_gamepad = .{ .path = "../sdl_gamepad" }`) in their own
        // build.zig.zon. The backend zon is staged verbatim into
        // .labelle/deps/labelle-<backend>/ (its `.path` is NOT rewritten — only
        // local plugins/gui are), so `../sdl_gamepad` resolves to
        // .labelle/deps/sdl_gamepad. Stage the sub-package there under exactly
        // that link name so the path resolves. Other backends don't depend on
        // it, so only register it for raylib/sokol/bgfx. Gated on
        // `cfg.effectiveGamepad() == .auto`: the opt-out (`.none`, core#28 slice
        // 5 — and the assembler#533 bgfx default when `.gamepad` is absent) does
        // NOT stage the sub-package at all, so no SDL ends up in the build. (bgfx
        // desktop reads gamepads through GLFW by default (#315) but GLFW can't
        // decode Switch-mode Nintendo pads; routing the desktop getters through
        // the SDL HIDAPI source fixes that, mirroring raylib/sokol.)
        // Built-in-specific sub-package: skipped entirely for an EXTERNAL
        // backend, which is self-contained — its staged `build.zig.zon`
        // declares whatever gamepad source it needs. (`switch (cfg.effectiveBackend())` is
        // meaningless for an external backend with no enum tag.)
        if (stagesSdlGamepad(cfg)) {
            const gp_path = try cache.resolveBundledPackage(allocator, cfg.labelle_version, cfg.assembler_version, project_dir, "backends/sdl_gamepad");
            try deps.append(allocator, .{
                .zon_name = try allocator.dupe(u8, "labelle_sdl_gamepad"),
                .link_name = try allocator.dupe(u8, "sdl_gamepad"),
                .abs_path = gp_path,
            });
        }

        // Backend-owned transitive sub-package: the shared Android gamepad
        // source (`backends/android_gamepad/`, #310 Stage 4 — the #250 state
        // machine + #248 InputManager JNI glue). Both the sokol and bgfx
        // backends declare it as a relative-path dep
        // (`.labelle_android_gamepad = .{ .path = "../android_gamepad" }`) in
        // their own build.zig.zon. The backend zon is staged verbatim into
        // .labelle/deps/labelle-<backend>/ (its `.path` is NOT rewritten), so
        // `../android_gamepad` resolves to .labelle/deps/android_gamepad —
        // stage the sub-package there under exactly that link name. Both
        // backends import the `android_gamepad` MODULE on every target (its
        // Android-only symbols are internally gated), so this is staged
        // unconditionally for them — NOT gated on `cfg.gamepad` (unlike SDL,
        // it pulls no system library and is a no-op off Android).
        // Built-in-specific sub-package: skipped for an external backend (self-
        // contained; its staged zon declares its own Android gamepad source).
        if (stagesAndroidGamepad(cfg)) {
            const agp_path = try cache.resolveBundledPackage(allocator, cfg.labelle_version, cfg.assembler_version, project_dir, "backends/android_gamepad");
            try deps.append(allocator, .{
                .zon_name = try allocator.dupe(u8, "labelle_android_gamepad"),
                .link_name = try allocator.dupe(u8, "android_gamepad"),
                .abs_path = agp_path,
            });
        }
    }

    switch (cfg.ecs) {
        .mock => {},
        .zig_ecs, .zflecs, .mr_ecs => {
            const ecs_dep_name: []const u8 = switch (cfg.ecs) {
                .zig_ecs => "labelle_zig_ecs",
                .zflecs => "labelle_zflecs",
                .mr_ecs => "labelle_mr_ecs",
                .mock => unreachable,
            };
            const ecs_dir: []const u8 = switch (cfg.ecs) {
                .zig_ecs => "zig-ecs",
                .zflecs => "zflecs",
                .mr_ecs => "mr-ecs",
                .mock => unreachable,
            };
            var subpath_buf: [128]u8 = undefined;
            const subpath = std.fmt.bufPrint(&subpath_buf, "ecs/{s}", .{ecs_dir}) catch unreachable;
            const ecs_path = try cache.resolveBundledPackage(allocator, cfg.labelle_version, cfg.assembler_version, project_dir, subpath);
            const ecs_link_name: []const u8 = switch (cfg.ecs) {
                .zig_ecs => "labelle-zig-ecs",
                .zflecs => "labelle-zflecs",
                .mr_ecs => "labelle-mr-ecs",
                .mock => unreachable,
            };
            try deps.append(allocator, .{ .zon_name = try allocator.dupe(u8, ecs_dep_name), .link_name = try allocator.dupe(u8, ecs_link_name), .abs_path = ecs_path });
        },
    }

    if (cfg.resolved_gui) |gui| {
        try deps.append(allocator, .{ .zon_name = try allocator.dupe(u8, "labelle_gui"), .link_name = try allocator.dupe(u8, "labelle-gui"), .abs_path = try allocator.dupe(u8, gui.plugin_dir) });
        if (gui.bridge_dir) |bd| {
            try deps.append(allocator, .{ .zon_name = try allocator.dupe(u8, "gui_bridge"), .link_name = try allocator.dupe(u8, "gui-bridge"), .abs_path = try allocator.dupe(u8, bd) });
        }
    }

    // Create deps/ directory with hardlinked copies
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const deps_dir = try std.fs.path.join(allocator, &.{ target_dir, "deps" });
    defer allocator.free(deps_dir);

    // Never wiped (#674): each package below is reconciled in place, and
    // only top-level entries no pass stages are swept (`prune`).
    try cwd.createDirPath(io, deps_dir);
    if (opts.prune) try pruneStaleDeps(allocator, deps_dir, deps.items, opts.keep);

    for (deps.items) |dep| {
        const dest = try std.fs.path.join(allocator, &.{ deps_dir, dep.link_name });
        defer allocator.free(dest);

        // realPathFileAlloc returns [:0]u8 (sentinel-terminated) but we
        // unify the type with dep.abs_path []const u8. Dupe to a plain
        // []u8 to avoid the DebugAllocator size-mismatch panic on free
        // (the sentinel byte differs between allocated size and slice length).
        const abs: []const u8 = blk: {
            const resolved = cwd.realPathFileAlloc(io, dep.abs_path, allocator) catch break :blk dep.abs_path;
            defer allocator.free(resolved);
            break :blk allocator.dupe(u8, resolved) catch dep.abs_path;
        };
        defer if (abs.ptr != dep.abs_path.ptr) allocator.free(abs);

        // Skip-and-warn ONLY when the source is missing. The original
        // cascade bug (#87) was triggered when a `local:` plugin path
        // didn't exist and the propagated error tripped build_files.zig's
        // fallback codepath, which emitted depth-overshoot paths to the
        // global cache. Pre-checking source existence here neutralises
        // that path. The dep entry stays in the result list — the bad
        // path is still emitted in the zon, so zig surfaces a clear
        // "missing package" error at build time.
        //
        // Operational errors at syncTree time (PermissionDenied,
        // NoSpaceLeft, cross-device hardlink, etc.) propagate as fatal
        // — better to fail noisily than silently produce an incomplete
        // deps/ tree that confuses the user with a misleading error
        // much later.
        cwd.access(io, abs, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.log.warn("could not link dep '{s}': source '{s}' does not exist — skipping", .{ dep.link_name, abs });
                // Drop a stage left by an earlier generate: the zon still
                // points here, and a stale tree would build silently instead
                // of zig reporting the missing package (#674).
                try cwd.deleteTree(io, dest);
                continue;
            },
            else => return err,
        };
        // A package whose top-level zon `rewriteZonPaths` re-anchors below
        // keeps its existing (rewritten) dest zon — the rewrite reconciles it.
        var stats: deps_sync.Stats = .{};
        try deps_sync.syncTree(allocator, abs, dest, .{ .preserve_top_zon = zonIsRewritten(cfg, dep.link_name) }, &stats);
    }

    // Rewrite relative .path deps in local plugins' build.zig.zon files.
    // After hardlinking, the paths still point relative to the original location
    // which is wrong from .labelle/deps/. Resolve each path against the original
    // abs location and recompute the relative path from the new dest location.
    //
    // Idempotent (#674): the rewrite always reads the SOURCE package's zon
    // (never the already-rewritten dest), and writes only when the result
    // differs from what is staged — so it runs on every pass, and a second
    // generate leaves the rewritten zon (and its mtime) alone.
    {
        for (cfg.plugins) |plugin| {
            if (!plugin.isLocal()) continue;

            const link_name = try std.fmt.allocPrint(allocator, "labelle-{s}", .{plugin.name});
            defer allocator.free(link_name);

            const dest = try std.fs.path.join(allocator, &.{ deps_dir, link_name });
            defer allocator.free(dest);

            const plugin_path = try cache.resolvePlugin(allocator, plugin, project_dir);
            defer allocator.free(plugin_path);

            const abs_src = cwd.realPathFileAlloc(io, plugin_path, allocator) catch continue;
            defer allocator.free(abs_src);

            const abs_dest = cwd.realPathFileAlloc(io, dest, allocator) catch continue;
            defer allocator.free(abs_dest);

            // Resolution-anchor selection: prefer worktree-relative if
            // the dep's first `.path = "..."` target exists in the
            // worktree's filesystem layout. Falls back to PR #88's
            // main-checkout anchor for the single-worktree case (only
            // the game is worktreed; toolkit deps sit beside the main
            // checkout).
            const resolution_src = if (try firstPathDepResolvesInWorktree(allocator, abs_src))
                try allocator.dupe(u8, abs_src)
            else
                try cache.toMainCheckoutPath(allocator, abs_src, project_dir);
            defer allocator.free(resolution_src);

            try rewriteZonPaths(allocator, abs_src, resolution_src, abs_dest);
        }

        // A LOCAL external backend (`backend_package` with a `local:`/`@libs`
        // repo) is staged like a plugin into .labelle/deps/labelle-<name>, so its
        // own relative `.path` deps need the same re-anchoring — otherwise they
        // stay pointed at the original checkout. Built-in + non-local-external
        // backends skip this (a built-in's zon has no rewritable local deps here;
        // a fetched external resolves to a self-contained cache dir).
        if (cfg.backend_package) |bp| blk: {
            if (!bp.isLocal()) break :blk;

            const link_name = try std.fmt.allocPrint(allocator, "labelle-{s}", .{bp.name});
            defer allocator.free(link_name);

            const dest = try std.fs.path.join(allocator, &.{ deps_dir, link_name });
            defer allocator.free(dest);

            const backend_path = try cache.resolvePlugin(allocator, bp, project_dir);
            defer allocator.free(backend_path);

            const abs_src = cwd.realPathFileAlloc(io, backend_path, allocator) catch break :blk;
            defer allocator.free(abs_src);

            const abs_dest = cwd.realPathFileAlloc(io, dest, allocator) catch break :blk;
            defer allocator.free(abs_dest);

            const resolution_src = if (try firstPathDepResolvesInWorktree(allocator, abs_src))
                try allocator.dupe(u8, abs_src)
            else
                try cache.toMainCheckoutPath(allocator, abs_src, project_dir);
            defer allocator.free(resolution_src);

            try rewriteZonPaths(allocator, abs_src, resolution_src, abs_dest);
        }

        // Also rewrite GUI plugin/bridge paths — the GUI is resolved separately
        // from cfg.plugins but may also have local .path deps.
        // rewriteZonPaths is a no-op if no .path entries exist, so always safe to call.
        if (cfg.resolved_gui) |gui| {
            try rewriteLocalDep(allocator, cwd, gui.plugin_dir, deps_dir, "labelle-gui", project_dir);
            if (gui.bridge_dir) |bd|
                try rewriteLocalDep(allocator, cwd, bd, deps_dir, "gui-bridge", project_dir);
        }
    }

    return deps.toOwnedSlice(allocator);
}

/// Free all DepEntry fields and the slice itself.
pub fn freeDepEntries(allocator: std.mem.Allocator, deps: []const DepEntry) void {
    for (deps) |dep| {
        allocator.free(dep.zon_name);
        allocator.free(dep.link_name);
        allocator.free(dep.abs_path);
    }
    allocator.free(deps);
}

/// Whether `rewriteZonPaths` owns the top-level `build.zig.zon` of the
/// package staged as `link_name`: local plugins, a local external backend,
/// and the GUI plugin/bridge — exactly the rewrite loop's set above.
fn zonIsRewritten(cfg: ProjectConfig, link_name: []const u8) bool {
    if (std.mem.eql(u8, link_name, "labelle-gui") or std.mem.eql(u8, link_name, "gui-bridge"))
        return cfg.resolved_gui != null;
    if (!std.mem.startsWith(u8, link_name, "labelle-")) return false;
    const name = link_name["labelle-".len..];
    for (cfg.plugins) |plugin| {
        if (plugin.isLocal() and std.mem.eql(u8, plugin.name, name)) return true;
    }
    if (cfg.backend_package) |bp| {
        if (bp.isLocal() and std.mem.eql(u8, bp.name, name)) return true;
    }
    return false;
}

/// Sweep top-level `deps/` entries that neither this pass (`staged`) nor
/// another pass of the same generate (`keep`) stages.
fn pruneStaleDeps(allocator: std.mem.Allocator, deps_dir: []const u8, staged: []const DepEntry, keep: []const []const u8) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    var stale: std.ArrayList([]const u8) = .empty;
    defer {
        for (stale.items) |n| allocator.free(n);
        stale.deinit(allocator);
    }
    {
        var dir = try cwd.openDir(io, deps_dir, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        outer: while (try it.next(io)) |entry| {
            for (staged) |d| if (std.mem.eql(u8, d.link_name, entry.name)) continue :outer;
            for (keep) |k| if (std.mem.eql(u8, k, entry.name)) continue :outer;
            try stale.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }
    for (stale.items) |name| {
        const p = try std.fs.path.join(allocator, &.{ deps_dir, name });
        defer allocator.free(p);
        try cwd.deleteTree(io, p);
    }
}


/// Resolve src/dest to absolute paths and call rewriteZonPaths.
/// `project_dir` is used to remap abs_src to its main-checkout equivalent
/// when in a worktree (see cache.toMainCheckoutPath).
fn rewriteLocalDep(allocator: std.mem.Allocator, cwd: std.Io.Dir, src_path: []const u8, deps_dir: []const u8, link_name: []const u8, project_dir: []const u8) !void {
    const io = config.globalIo();
    const dest = try std.fs.path.join(allocator, &.{ deps_dir, link_name });
    defer allocator.free(dest);
    const abs_src = cwd.realPathFileAlloc(io, src_path, allocator) catch return;
    defer allocator.free(abs_src);
    const abs_dest = cwd.realPathFileAlloc(io, dest, allocator) catch return;
    defer allocator.free(abs_dest);
    const resolution_src = if (try firstPathDepResolvesInWorktree(allocator, abs_src))
        try allocator.dupe(u8, abs_src)
    else
        try cache.toMainCheckoutPath(allocator, abs_src, project_dir);
    defer allocator.free(resolution_src);
    try rewriteZonPaths(allocator, abs_src, resolution_src, abs_dest);
}

/// Stage a package's `build.zig.zon` under .labelle/deps/ with its relative
/// `.path` dependencies re-anchored for the new location.
/// `pkg_dir` is the package's real source dir — the zon is ALWAYS read from
/// there, never from the staged copy, so the rewrite is idempotent (#674).
/// `src_dir` is the resolution anchor for relative paths (the package dir or
/// its main-checkout equivalent, see `firstPathDepResolvesInWorktree`).
/// `dest_dir` is the new absolute path under .labelle/deps/.
///
/// For each `.path = "../some/dep"` entry, resolves it against src_dir to get
/// the absolute target, then computes the relative path from dest_dir.
/// Writes only when the staged zon differs from the result, via delete +
/// temp file + rename so a hardlinked staged zon never writes through to the
/// original package file.
fn rewriteZonPaths(allocator: std.mem.Allocator, pkg_dir: []const u8, src_dir: []const u8, dest_dir: []const u8) !void {
    const zon_path = try std.fs.path.join(allocator, &.{ dest_dir, "build.zig.zon" });
    defer allocator.free(zon_path);
    const pkg_zon = try std.fs.path.join(allocator, &.{ pkg_dir, "build.zig.zon" });
    defer allocator.free(pkg_zon);

    const io = config.globalIo();
    const content = std.Io.Dir.cwd().readFileAlloc(io, pkg_zon, allocator, .limited(256 * 1024)) catch |err| switch (err) {
        // No zon in the package: nothing to stage or rewrite.
        error.FileNotFound => return,
        else => {
            std.debug.print("labelle: warning: could not read {s}: {any}\n", .{ pkg_zon, err });
            return;
        },
    };
    defer allocator.free(content);

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < content.len) {
        // Look for `.path` token
        if (i + 5 <= content.len and std.mem.eql(u8, content[i..][0..5], ".path")) {
            const prefix_start = i;
            var j = i + 5;
            // skip whitespace after `.path`
            while (j < content.len and (content[j] == ' ' or content[j] == '\t')) j += 1;
            // expect `=`
            if (j < content.len and content[j] == '=') {
                j += 1;
                // skip whitespace after `=`
                while (j < content.len and (content[j] == ' ' or content[j] == '\t')) j += 1;
                // expect opening quote
                if (j < content.len and content[j] == '"') {
                    j += 1;
                    const path_start = j;
                    while (j < content.len and content[j] != '"') j += 1;
                    const rel_path = content[path_start..j];
                    if (j < content.len) j += 1; // skip closing quote
                    i = j;

                    // Only rewrite relative paths (starting with . or ..)
                    if (rel_path.len > 0 and rel_path[0] == '.') {
                        // Resolve against original source directory
                        const abs_target = try std.fs.path.join(allocator, &.{ src_dir, rel_path });
                        defer allocator.free(abs_target);

                        // Compute relative path from dest directory using std.fs.path
                        const new_rel = try computeRelativePath(allocator, dest_dir, abs_target);
                        defer allocator.free(new_rel);

                        try result.appendSlice(allocator, ".path = \"");
                        try result.appendSlice(allocator, new_rel);
                        try result.append(allocator, '"');
                        continue;
                    }
                    // Not relative — emit original text
                    try result.appendSlice(allocator, content[prefix_start..i]);
                    continue;
                }
            }
            // Not a `.path = "..."` pattern — emit as-is
            try result.appendSlice(allocator, content[prefix_start..j]);
            i = j;
            continue;
        }
        try result.append(allocator, content[i]);
        i += 1;
    }

    // Only write if the STAGED zon differs from the result (#674) — on a
    // repeat generate it already holds exactly these bytes.
    if (!write_if_changed.sameContent(io, std.Io.Dir.cwd(), zon_path, result.items)) {
        const cwd = std.Io.Dir.cwd();

        // Delete the hardlink first so we never rewrite the original package file.
        cwd.deleteFile(io, zon_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        // Write via temp file + rename for atomicity.
        const tmp_path = try std.fs.path.join(allocator, &.{ dest_dir, "build.zig.zon.tmp" });
        defer allocator.free(tmp_path);

        cwd.deleteFile(io, tmp_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        const file = try cwd.createFile(io, tmp_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, result.items);

        try cwd.rename(tmp_path, cwd, zon_path, io);
    }
}

/// Compute a relative path from `from_dir` to `to_path`.
/// Uses std.fs.path.relative for cross-platform correctness, then
/// normalizes to forward slashes for ZON portability.
/// Heuristic: does the dep's *first* `.path = "..."` reference resolve to an
/// existing directory under `abs_src`'s worktree-native layout?
///
/// Used to pick the resolution anchor for `rewriteZonPaths`. PR #88 anchored
/// all `local:` paths at the main checkout (assuming toolkit deps sit beside
/// it), but that breaks parallel-worktree setups where everything is worktreed
/// under the same parent. When the worktree-relative target exists, prefer it;
/// otherwise fall through to `cache.toMainCheckoutPath` so the original
/// single-worktree pattern still works.
///
/// Reads at most 64 KiB of the source `build.zig.zon`. No-op (returns false)
/// for packages without `.path` deps or with unreadable manifests.
fn firstPathDepResolvesInWorktree(allocator: std.mem.Allocator, abs_src: []const u8) !bool {
    const io = config.globalIo();
    const zon_path = try std.fs.path.join(allocator, &.{ abs_src, "build.zig.zon" });
    defer allocator.free(zon_path);

    const content = std.Io.Dir.cwd().readFileAlloc(io, zon_path, allocator, .limited(64 * 1024)) catch return false;
    defer allocator.free(content);

    const path_marker = ".path = \"";
    const start = std.mem.indexOf(u8, content, path_marker) orelse return false;
    const after = start + path_marker.len;
    const end_rel = std.mem.indexOfScalar(u8, content[after..], '"') orelse return false;
    const rel = content[after .. after + end_rel];
    if (rel.len == 0 or rel[0] != '.') return false;

    const target = try std.fs.path.join(allocator, &.{ abs_src, rel });
    defer allocator.free(target);
    var dir = std.Io.Dir.cwd().openDir(io, target, .{}) catch return false;
    dir.close(io);
    return true;
}

fn computeRelativePath(allocator: std.mem.Allocator, from_dir: []const u8, to_path: []const u8) ![]u8 {
    // Resolve `..` components in to_path before computing relative path.
    const resolved_to = try std.fs.path.resolve(allocator, &.{to_path});
    defer allocator.free(resolved_to);

    const rel = try std.fs.path.relative(allocator, "", null, from_dir, resolved_to);

    // ZON files should always use forward slashes.
    if (comptime @import("builtin").os.tag == .windows) {
        for (rel) |*c| if (c.* == '\\') {
            c.* = '/';
        };
    }
    return rel;
}

// ── Tests ────────────────────────────────────────────────────────────

test "computeRelativePath: sibling directories" {
    const alloc = std.testing.allocator;
    const result = try computeRelativePath(alloc, "/home/user/project/.labelle/deps/labelle-needs_machine", "/home/user/labelle-fsm");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("../../../../labelle-fsm", result);
}

test "computeRelativePath: same parent" {
    const alloc = std.testing.allocator;
    const result = try computeRelativePath(alloc, "/a/b/deps/pkg1", "/a/b/deps/pkg2");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("../pkg2", result);
}

test "computeRelativePath: child directory" {
    const alloc = std.testing.allocator;
    const result = try computeRelativePath(alloc, "/a/b", "/a/b/c/d");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("c/d", result);
}

test "computeRelativePath: resolves dot-dot in target" {
    const alloc = std.testing.allocator;
    const result = try computeRelativePath(alloc, "/a/b", "/a/b/c/../d");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("d", result);
}

test "rewriteZonPaths: rewrites relative path deps" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "project/libs/needs_machine");
    try tmp.dir.createDirPath(std.testing.io, "project/.labelle/deps/labelle-needs_machine");
    try tmp.dir.createDirPath(std.testing.io, "labelle-fsm");

    const zon_content =
        \\.{
        \\    .name = .test_pkg,
        \\    .dependencies = .{
        \\        .@"labelle-fsm" = .{
        \\            .path = "../../../labelle-fsm",
        \\        },
        \\        .@"labelle-core" = .{
        \\            .url = "https://example.com/core.tar.gz",
        \\            .hash = "abc123",
        \\        },
        \\    },
        \\}
    ;

    // The zon lives in the SOURCE package; the rewrite reads it from there.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project/libs/needs_machine/build.zig.zon", .data = zon_content });

    const src_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "project/libs/needs_machine", alloc);
    defer alloc.free(src_abs);
    const dest_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "project/.labelle/deps/labelle-needs_machine", alloc);
    defer alloc.free(dest_abs);

    try rewriteZonPaths(alloc, src_abs, src_abs, dest_abs);

    const result = try tmp.dir.readFileAlloc(std.testing.io, "project/.labelle/deps/labelle-needs_machine/build.zig.zon", alloc, .limited(64 * 1024));
    defer alloc.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, ".url = \"https://example.com/core.tar.gz\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"../../../labelle-fsm\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, ".path = \"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "../../../../labelle-fsm") != null);

    // The source package's zon is never written through.
    const original = try tmp.dir.readFileAlloc(std.testing.io, "project/libs/needs_machine/build.zig.zon", alloc, .limited(64 * 1024));
    defer alloc.free(original);
    try std.testing.expectEqualStrings(zon_content, original);

    // #674: a second rewrite (the next generate, or the tests-target pass)
    // re-derives from the SOURCE, so it neither double-rewrites the path nor
    // touches the staged file — same inode, same mtime, same bytes.
    const staged = "project/.labelle/deps/labelle-needs_machine/build.zig.zon";
    const before = try tmp.dir.statFile(std.testing.io, staged, .{});
    try rewriteZonPaths(alloc, src_abs, src_abs, dest_abs);
    const after = try tmp.dir.statFile(std.testing.io, staged, .{});
    try std.testing.expectEqual(before.inode, after.inode);
    try std.testing.expectEqual(before.mtime.nanoseconds, after.mtime.nanoseconds);
    const again = try tmp.dir.readFileAlloc(std.testing.io, staged, alloc, .limited(64 * 1024));
    defer alloc.free(again);
    try std.testing.expectEqualStrings(result, again);
}

test "rewriteZonPaths: skips files without .path deps" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.createDirPath(std.testing.io, "dest");

    const zon_content =
        \\.{
        \\    .name = .test_pkg,
        \\    .dependencies = .{
        \\        .@"labelle-core" = .{
        \\            .url = "https://example.com/core.tar.gz",
        \\            .hash = "abc123",
        \\        },
        \\    },
        \\}
    ;

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/build.zig.zon", .data = zon_content });
    // Staged copy already current (what syncTree's hardlink leaves).
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "dest/build.zig.zon", .data = zon_content });
    const before = try tmp.dir.statFile(std.testing.io, "dest/build.zig.zon", .{});

    const src_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "src", alloc);
    defer alloc.free(src_abs);
    const dest_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "dest", alloc);
    defer alloc.free(dest_abs);

    try rewriteZonPaths(alloc, src_abs, src_abs, dest_abs);

    const result = try tmp.dir.readFileAlloc(std.testing.io, "dest/build.zig.zon", alloc, .limited(64 * 1024));
    defer alloc.free(result);
    try std.testing.expectEqualStrings(zon_content, result);
    // Nothing to rewrite and already current: not re-written.
    const after = try tmp.dir.statFile(std.testing.io, "dest/build.zig.zon", .{});
    try std.testing.expectEqual(before.inode, after.inode);
    try std.testing.expectEqual(before.mtime.nanoseconds, after.mtime.nanoseconds);
}

// syncTree (the staging primitive) is tested in deps_sync.zig.

// ── External-backend gating (open-config, epic #386 Phase 5) ─────────

test "stagesSdlGamepad: every built-in is now external → stages NOTHING" {
    // As of #386 Phase 6c ALL six built-ins (incl. sokol, the last extraction)
    // resolve to external provider packages, so `isExternal()` is true for every
    // bare `.backend = .<tag>` config and the behavioral switch is gated OFF: an
    // external backend is self-contained and carries its own gamepad source, so
    // the assembler never stages the sibling sub-package — even with
    // `.gamepad = .auto`. (The `.raylib, .sokol, .bgfx` switch arm is now
    // defensive dead code, reachable only if a future backend ships bundled.)
    inline for (@typeInfo(config.Backend).@"enum".fields) |f| {
        const tag = @field(config.Backend, f.name);
        try std.testing.expect(!stagesSdlGamepad(.{ .name = "g", .backend = tag, .gamepad = .auto }));
        try std.testing.expect(!stagesSdlGamepad(.{ .name = "g", .backend = tag, .gamepad = .none }));
    }
}

test "stagesSdlGamepad/AndroidGamepad: an external backend stages NEITHER" {
    // The behavioral switches are skipped for an external backend: it is
    // self-contained, so no built-in gamepad sub-package is staged — even
    // though `.gamepad = .auto` (default) and `.backend` is whatever (ignored).
    const cfg = config.ProjectConfig{
        .name = "stubgame",
        .backend_package = .{ .name = "stubbackend", .repo = "local:../stub" },
        .gamepad = .auto,
    };
    try std.testing.expect(cfg.isExternal());
    try std.testing.expect(!stagesSdlGamepad(cfg));
    try std.testing.expect(!stagesAndroidGamepad(cfg));
}

test "stagesAndroidGamepad: every built-in is now external → stages NOTHING" {
    // Same as the SDL case: post-#386 every built-in resolves to an external
    // provider, so the android-gamepad staging switch is gated OFF for them all
    // (sokol included). Each external backend carries its own android gamepad
    // source; the `.sokol, .bgfx` switch arm is now defensive dead code.
    inline for (@typeInfo(config.Backend).@"enum".fields) |f| {
        const tag = @field(config.Backend, f.name);
        try std.testing.expect(!stagesAndroidGamepad(.{ .name = "g", .backend = tag }));
    }
}
