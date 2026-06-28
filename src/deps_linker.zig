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

const ProjectConfig = config.ProjectConfig;

pub const DepEntry = struct {
    zon_name: []const u8,
    link_name: []const u8,
    abs_path: []const u8,
};

pub const DepsLinkOptions = struct {
    /// True (default) wipes `deps_dir` before re-creating it. The tests
    /// target (issue #83) sets this to false because the exe target's
    /// generate already populated `deps_dir` with the chosen-backend
    /// links — wiping it would orphan the exe's deps. The tests pass
    /// only adds the null backend's link to the existing dir.
    recreate: bool = true,
};

pub fn createDepsLinks(
    allocator: std.mem.Allocator,
    cfg: ProjectConfig,
    target_dir: []const u8,
    project_dir: []const u8,
    opts: DepsLinkOptions,
) ![]const DepEntry {
    var deps: std.ArrayList(DepEntry) = .empty;

    const core_path = try cache.resolveFrameworkPackage(allocator, "core", cfg.core_version, project_dir);
    try deps.append(allocator, .{ .zon_name = try allocator.dupe(u8, "labelle_core"), .link_name = try allocator.dupe(u8, "labelle-core"), .abs_path = core_path });

    const gfx_path = try cache.resolveFrameworkPackage(allocator, "gfx", cfg.gfx_version, project_dir);
    try deps.append(allocator, .{ .zon_name = try allocator.dupe(u8, "labelle_gfx"), .link_name = try allocator.dupe(u8, "labelle-gfx"), .abs_path = gfx_path });

    const engine_path = try cache.resolveFrameworkPackage(allocator, "engine", cfg.engine_version, project_dir);
    try deps.append(allocator, .{ .zon_name = try allocator.dupe(u8, "engine"), .link_name = try allocator.dupe(u8, "labelle-engine"), .abs_path = engine_path });

    for (cfg.plugins) |plugin| {
        const plugin_path = try cache.resolvePlugin(allocator, plugin, project_dir);
        const zon_name = try std.fmt.allocPrint(allocator, "labelle_{s}", .{plugin.name});
        const link_name = try std.fmt.allocPrint(allocator, "labelle-{s}", .{plugin.name});
        try deps.append(allocator, .{ .zon_name = zon_name, .link_name = link_name, .abs_path = plugin_path });
    }

    {
        const backend_info = try backend_registry.lookup(allocator, cfg.backendName());
        defer allocator.free(backend_info.subpath);
        const backend_path = try cache.resolveBundledPackage(allocator, cfg.labelle_version, cfg.assembler_version, project_dir, backend_info.subpath);
        // zon_name / link_name are moved into the DepEntry (freed by
        // freeDepEntries), so we don't free them here.
        try deps.append(allocator, .{ .zon_name = backend_info.zon_name, .link_name = backend_info.link_name, .abs_path = backend_path });

        // Backend-owned transitive sub-package: the shared windowless-SDL
        // desktop gamepad source (`backends/sdl_gamepad/`, core#28). Both the
        // raylib and sokol desktop backends declare it as a relative-path dep
        // (`.labelle_sdl_gamepad = .{ .path = "../sdl_gamepad" }`) in their own
        // build.zig.zon. The backend zon is staged verbatim into
        // .labelle/deps/labelle-<backend>/ (its `.path` is NOT rewritten — only
        // local plugins/gui are), so `../sdl_gamepad` resolves to
        // .labelle/deps/sdl_gamepad. Stage the sub-package there under exactly
        // that link name so the path resolves. Other backends don't depend on
        // it, so only register it for raylib/sokol/bgfx. Gated on `cfg.gamepad
        // == .auto`: the opt-out (`.none`, core#28 slice 5) does NOT stage the
        // sub-package at all, so no SDL ends up in the generated build. (bgfx
        // desktop reads gamepads through GLFW by default (#315) but GLFW can't
        // decode Switch-mode Nintendo pads; routing the desktop getters through
        // the SDL HIDAPI source fixes that, mirroring raylib/sokol.)
        switch (cfg.backend) {
            .raylib, .sokol, .bgfx => if (cfg.gamepad == .auto) {
                const gp_path = try cache.resolveBundledPackage(allocator, cfg.labelle_version, cfg.assembler_version, project_dir, "backends/sdl_gamepad");
                try deps.append(allocator, .{
                    .zon_name = try allocator.dupe(u8, "labelle_sdl_gamepad"),
                    .link_name = try allocator.dupe(u8, "sdl_gamepad"),
                    .abs_path = gp_path,
                });
            },
            else => {},
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
        switch (cfg.backend) {
            .sokol, .bgfx => {
                const agp_path = try cache.resolveBundledPackage(allocator, cfg.labelle_version, cfg.assembler_version, project_dir, "backends/android_gamepad");
                try deps.append(allocator, .{
                    .zon_name = try allocator.dupe(u8, "labelle_android_gamepad"),
                    .link_name = try allocator.dupe(u8, "android_gamepad"),
                    .abs_path = agp_path,
                });
            },
            else => {},
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

    if (opts.recreate) cwd.deleteTree(io, deps_dir) catch {};
    try cwd.createDirPath(io, deps_dir);

    for (deps.items) |dep| {
        const dest = try std.fs.path.join(allocator, &.{ deps_dir, dep.link_name });
        defer allocator.free(dest);

        // In additive mode (recreate=false), skip links that already
        // exist — created by a previous target's pass. Hardlinking on
        // top of an existing tree would error.
        if (!opts.recreate) {
            if (cwd.access(io, dest, .{})) |_| continue else |_| {}
        }

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
        // Operational errors at hardlinkTree time (PermissionDenied,
        // NoSpaceLeft, cross-device hardlink, etc.) propagate as fatal
        // — better to fail noisily than silently produce an incomplete
        // deps/ tree that confuses the user with a misleading error
        // much later.
        cwd.access(io, abs, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.log.warn("could not link dep '{s}': source '{s}' does not exist — skipping", .{ dep.link_name, abs });
                continue;
            },
            else => return err,
        };
        try hardlinkTree(allocator, abs, dest);
    }

    // Rewrite relative .path deps in local plugins' build.zig.zon files.
    // After hardlinking, the paths still point relative to the original location
    // which is wrong from .labelle/deps/. Resolve each path against the original
    // abs location and recompute the relative path from the new dest location.
    //
    // Only run in `recreate=true` (first-pass) mode. In additive mode the
    // first pass already rewrote every dest zon to be relative to its
    // .labelle/deps/<plugin>/ location; running rewriteZonPaths again on
    // those already-rewritten files would re-resolve the new paths against
    // the original `abs_src` (the plugin's source-tree location) and
    // produce a corrupted target (one extra `../` in practice). The set of
    // local plugins is identical between passes — only the bundled
    // backend/ECS deps differ — and bundled deps don't have local `.path`
    // entries to rewrite, so skipping is safe.
    if (opts.recreate) {
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

            try rewriteZonPaths(allocator, resolution_src, abs_dest);
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

/// Recursively hardlink a directory tree. Creates directories, hardlinks files.
/// Falls back to copy for files that can't be hardlinked (cross-device).
fn hardlinkTree(allocator: std.mem.Allocator, src_path: []const u8, dest_path: []const u8) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dest_path);

    var src_dir = try cwd.openDir(io, src_path, .{ .iterate = true });
    defer src_dir.close(io);

    var iter = src_dir.iterate();
    while (try iter.next(io)) |entry| {
        const src_sub = try std.fs.path.join(allocator, &.{ src_path, entry.name });
        defer allocator.free(src_sub);
        const dest_sub = try std.fs.path.join(allocator, &.{ dest_path, entry.name });
        defer allocator.free(dest_sub);

        switch (entry.kind) {
            .directory => {
                // Skip .zig-cache and zig-out inside packages
                if (std.mem.eql(u8, entry.name, ".zig-cache") or
                    std.mem.eql(u8, entry.name, "zig-out") or
                    std.mem.eql(u8, entry.name, ".git"))
                    continue;

                try hardlinkTree(allocator, src_sub, dest_sub);
            },
            .file => {
                try hardlinkOrCopy(allocator, src_sub, dest_sub);
            },
            .sym_link => {
                // Read symlink target and recreate it
                var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const target_len = src_dir.readLink(io, entry.name, &target_buf) catch continue;
                const target = target_buf[0..target_len];
                cwd.symLink(io, target, dest_sub, .{}) catch {};
            },
            else => {},
        }
    }
}

/// Create a hardlink, falling back to copy if hardlinks aren't supported
/// (cross-device, Windows without NTFS, etc).
/// Create a hardlink, falling back to copy. Works on macOS, Linux, and Windows.
/// Hardlinks share disk space (zero cost) and work without admin privileges.
fn hardlinkOrCopy(allocator: std.mem.Allocator, src: []const u8, dest: []const u8) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const builtin = @import("builtin");

    if (comptime builtin.os.tag == .windows) {
        // Windows: use CreateHardLinkW from kernel32
        windowsHardLink(allocator, src, dest) catch {
            try cwd.copyFile(src, cwd, dest, io, .{});
        };
    } else {
        // POSIX: hardLink (formerly posix.link)
        cwd.hardLink(src, cwd, dest, io, .{}) catch {
            try cwd.copyFile(src, cwd, dest, io, .{});
        };
    }
}

/// Windows hardlink via kernel32.CreateHardLinkW.
/// Works on NTFS without admin privileges.
fn windowsHardLink(allocator: std.mem.Allocator, src: []const u8, dest: []const u8) !void {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag != .windows) unreachable;

    // Zig 0.16 removed `std.os.windows.sliceToPrefixedFileW`; convert the
    // UTF-8 paths to NUL-terminated UTF-16LE ourselves. CreateHardLinkW is
    // a Win32 (not NT) call, so a plain wide path — no `\??\` prefix — is
    // what it expects.
    const src_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, src);
    defer allocator.free(src_w);
    const dest_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, dest);
    defer allocator.free(dest_w);

    const result = CreateHardLinkW(dest_w.ptr, src_w.ptr, null);
    if (result == 0) return error.PermissionDenied;
}

extern "kernel32" fn CreateHardLinkW(
    lpFileName: [*:0]const u16,
    lpExistingFileName: [*:0]const u16,
    lpSecurityAttributes: ?*anyopaque,
) callconv(.winapi) c_int;

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
    try rewriteZonPaths(allocator, resolution_src, abs_dest);
}

/// Rewrite relative `.path` dependencies in a hardlinked build.zig.zon.
/// `src_dir` is the original absolute path of the package.
/// `dest_dir` is the new absolute path under .labelle/deps/.
///
/// For each `.path = "../some/dep"` entry, resolves it against src_dir to get
/// the absolute target, then computes the relative path from dest_dir.
/// Writes via a temp file + rename to avoid corrupting the original hardlinked file.
fn rewriteZonPaths(allocator: std.mem.Allocator, src_dir: []const u8, dest_dir: []const u8) !void {
    const zon_path = try std.fs.path.join(allocator, &.{ dest_dir, "build.zig.zon" });
    defer allocator.free(zon_path);

    const io = config.globalIo();
    const content = std.Io.Dir.cwd().readFileAlloc(io, zon_path, allocator, .limited(256 * 1024)) catch |err| {
        std.debug.print("labelle: warning: could not read {s}: {any}\n", .{ zon_path, err });
        return;
    };
    defer allocator.free(content);

    // Quick check: skip files without relative .path deps
    if (std.mem.indexOf(u8, content, ".path") == null) return;

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

    // Only write if changed
    if (!std.mem.eql(u8, content, result.items)) {
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

    try tmp.dir.createDirPath(std.testing.io,"project/libs/needs_machine");
    try tmp.dir.createDirPath(std.testing.io,"project/.labelle/deps/labelle-needs_machine");
    try tmp.dir.createDirPath(std.testing.io,"labelle-fsm");

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

    const dest_zon = try tmp.dir.createFile(std.testing.io, "project/.labelle/deps/labelle-needs_machine/build.zig.zon", .{});
    defer dest_zon.close(std.testing.io);
    try dest_zon.writeStreamingAll(std.testing.io, zon_content);

    const src_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "project/libs/needs_machine", alloc);
    defer alloc.free(src_abs);
    const dest_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "project/.labelle/deps/labelle-needs_machine", alloc);
    defer alloc.free(dest_abs);

    try rewriteZonPaths(alloc, src_abs, dest_abs);

    const result = try tmp.dir.readFileAlloc(std.testing.io, "project/.labelle/deps/labelle-needs_machine/build.zig.zon", alloc, .limited(64 * 1024));
    defer alloc.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, ".url = \"https://example.com/core.tar.gz\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"../../../labelle-fsm\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, ".path = \"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "../../../../labelle-fsm") != null);
}

test "rewriteZonPaths: skips files without .path deps" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io,"src");
    try tmp.dir.createDirPath(std.testing.io,"dest");

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

    const dest_zon = try tmp.dir.createFile(std.testing.io, "dest/build.zig.zon", .{});
    defer dest_zon.close(std.testing.io);
    try dest_zon.writeStreamingAll(std.testing.io, zon_content);

    const src_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "src", alloc);
    defer alloc.free(src_abs);
    const dest_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "dest", alloc);
    defer alloc.free(dest_abs);

    try rewriteZonPaths(alloc, src_abs, dest_abs);

    const result = try tmp.dir.readFileAlloc(std.testing.io, "dest/build.zig.zon", alloc, .limited(64 * 1024));
    defer alloc.free(result);
    try std.testing.expectEqualStrings(zon_content, result);
}

test "hardlinkTree: errors on missing source" {
    // Pins the precondition that createDepsLinks's source-pre-check relies
    // on — if hardlinkTree were ever changed to silently succeed on a
    // missing source, the source-FileNotFound branch in createDepsLinks
    // would never trigger and the worktree cascade bug (#87) could
    // re-emerge through a different path.
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io,"dest_parent");
    const dest_parent = try tmp.dir.realPathFileAlloc(std.testing.io, "dest_parent", alloc);
    defer alloc.free(dest_parent);

    const missing_src = try std.fs.path.join(alloc, &.{ dest_parent, "does_not_exist" });
    defer alloc.free(missing_src);
    const dest = try std.fs.path.join(alloc, &.{ dest_parent, "linked" });
    defer alloc.free(dest);

    const result = hardlinkTree(alloc, missing_src, dest);
    try std.testing.expectError(error.FileNotFound, result);
}
