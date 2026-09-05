/// Cache disk-layout operations: populate cache slots from local source
/// directories, copy / symlink trees, patch sibling-style path deps in
/// build.zig.zon files after the cache is populated.
///
/// This is the side of the cache that *writes* to disk (or symlinks /
/// copies into it). The pure path-math is in `resolve.zig`; the network
/// side (git clones) is in `fetch.zig`.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const env = @import("env.zig");
const local = @import("local.zig");
const resolve = @import("resolve.zig");

/// Populate the assembler cache from the assembler source directory.
/// `companion_dir` points at the labelle-assembler repo root (for dev) or
/// an install-time bundled directory. Symlinks `backends/` into
/// ~/.labelle/packages/assembler/{version}/. Missing subdirectories are
/// skipped silently so the same function works through the staged migration
/// as more subdirs (ecs, gui) move over.
pub fn populateAssemblerCache(allocator: std.mem.Allocator, assembler_version: []const u8, companion_dir: []const u8) !void {
    // #685: local sources go in the reserved `local/assembler` slot, never in
    // `assembler/<version>` — a slot named for a version must contain that
    // version.
    const target = try local.assemblerSlot(allocator);
    defer allocator.free(target);

    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    cwd.createDirPath(io, target) catch |err| {
        std.log.err("labelle: could not create cache directory '{s}': {any}", .{ target, err });
        return error.CachePopulationFailed;
    };

    const subdirs = [_][]const u8{ "backends", "ecs", "gui" };
    for (subdirs) |subdir| {
        const src_path = try std.fs.path.join(allocator, &.{ companion_dir, subdir });
        defer allocator.free(src_path);

        const dst_path = try std.fs.path.join(allocator, &.{ target, subdir });
        defer allocator.free(dst_path);

        // The checkout dropped this subdir: drop it from the slot too, or a
        // stale copy (or a link to a directory that no longer exists) stays
        // behind and is still compiled (#688 review round 7).
        if (!dirExists(src_path)) {
            if (local.pathExists(dst_path) or local.isSymlinkPath(dst_path)) {
                cwd.deleteTree(io, dst_path) catch |err| {
                    std.log.warn("labelle: could not drop stale bundled '{s}': {any}", .{ dst_path, err });
                    return error.CachePopulationFailed;
                };
            }
            continue;
        }

        symlinkToCache(allocator, src_path, dst_path) catch |err| {
            std.log.err("labelle: could not link '{s}' to cache: {any}", .{ src_path, err });
            return error.CachePopulationFailed;
        };
    }

    try local.writeOrigin(allocator, target, companion_dir, assembler_version, .discovered);
}

/// Populate a framework package (core, engine, gfx) into the cache from a source directory.
/// Creates a symlink from the cache location to the source directory.
///
/// `mode` says whether the caller found these sources by walking up from the
/// running binary (`.discovered`) or was handed the path by the user
/// (`.explicit`, i.e. `install <pkg> local:<path>`). It decides which
/// assemblers may later resolve through the slot — see `local.Origin.Mode`.
pub fn populateFrameworkPackage(
    allocator: std.mem.Allocator,
    package: []const u8,
    version: []const u8,
    source_dir: []const u8,
    mode: local.Origin.Mode,
) !void {
    // #685: `version` no longer names the slot — it is recorded in the
    // provenance marker so diagnostics can say which pin this local source
    // was installed *for* without pretending the slot holds that release.
    const target = try local.frameworkSlot(allocator, package);
    defer allocator.free(target);
    try symlinkToCache(allocator, source_dir, target);
    try local.writeOrigin(allocator, target, source_dir, version, mode);
}

/// Populate a plugin into the cache from a source directory.
/// Creates a symlink from the cache location to the source directory.
pub fn populatePlugin(allocator: std.mem.Allocator, plugin: config.PluginDep, source_dir: []const u8) !void {
    // #685: reserved local-namespace slot, same as the framework packages.
    const target = try local.pluginSlot(allocator, plugin);
    defer allocator.free(target);
    try symlinkToCache(allocator, source_dir, target);
    try local.writeOrigin(allocator, target, source_dir, plugin.version, .discovered);
}

/// Create a symlink from cache target to source directory.
/// The source_dir must be an absolute path (resolved via realpath).
/// Creates parent directories as needed.
pub fn symlinkToCache(allocator: std.mem.Allocator, source_dir: []const u8, target: []const u8) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    // Resolve source to absolute path. Dupe to plain []u8 so the free
    // doesn't trip on realPathFileAlloc's sentinel byte.
    const abs_source_z = cwd.realPathFileAlloc(io, source_dir, allocator) catch |err| {
        std.log.err("labelle: source directory not found '{s}': {any}", .{ source_dir, err });
        return error.CachePopulationFailed;
    };
    defer allocator.free(abs_source_z);
    const abs_source = try allocator.dupe(u8, abs_source_z);
    defer allocator.free(abs_source);

    // Ensure the parent directory exists — but only create it when it does
    // NOT, because on Windows `createDirPath` on a path that is already a
    // filesystem root (`C:\`) fails with `error.BadPathName` instead of
    // succeeding as a no-op. Any target whose parent is a drive root then
    // aborted population outright (#704 repro A).
    if (std.fs.path.dirname(target)) |parent| {
        if (!local.pathExists(parent)) {
            cwd.createDirPath(io, parent) catch |err| {
                std.log.err("labelle: could not create cache directory '{s}': {any}", .{ parent, err });
                return error.CachePopulationFailed;
            };
        }
    }

    // Create symlink (absolute target → source), fall back to copy on failure
    // (Windows requires admin/Developer Mode for symlinks)
    cwd.symLink(io, abs_source, target, .{ .is_directory = true }) catch |err| {
        if (err == error.PathAlreadyExists) {
            var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            if (std.Io.Dir.readLinkAbsolute(io, target, &link_buf)) |existing_len| {
                // A link already: keep it when it already points where we want.
                const existing = link_buf[0..existing_len];
                if (std.mem.eql(u8, existing, abs_source)) return;
                std.log.warn("labelle: cache entry '{s}' points to '{s}', expected '{s}'", .{ target, existing, abs_source });
                // NOT `catch return`: reporting success here would let the
                // caller rewrite the provenance marker with the NEW source
                // while the link still targets the old checkout, and
                // `active*Slot` trusts that marker (#688 review round 4).
                cwd.deleteFile(io, target) catch |del_err| {
                    std.log.warn("labelle: could not replace cache entry '{s}': {any}", .{ target, del_err });
                    return error.CachePopulationFailed;
                };
            } else |_| {
                // NOT a link — an earlier run took the copy fallback below (or
                // the platform has no directory symlinks at all). That copy is
                // a SNAPSHOT: it does not track the source, and the reserved
                // slot never changes name, so leaving it would serve stale
                // sources indefinitely. Repopulating is the whole point of the
                // call, so drop it (#688 review round 2).
                cwd.deleteTree(io, target) catch |del_err| {
                    std.log.warn("labelle: could not refresh cache entry '{s}': {any}", .{ target, del_err });
                    return error.CachePopulationFailed;
                };
            }
            // Recreate: link if the platform allows it, copy if it does not.
            cwd.symLink(io, abs_source, target, .{ .is_directory = true }) catch {
                copyDirRecursive(allocator, abs_source, target) catch |copy_err| {
                    std.log.err("labelle: could not link or copy '{s}' to '{s}': {any}", .{ abs_source, target, copy_err });
                    return error.CachePopulationFailed;
                };
            };
            return;
        }
        // Fall back to copying the directory
        copyDirRecursive(allocator, abs_source, target) catch |copy_err| {
            std.log.err("labelle: could not link or copy '{s}' to '{s}': {any}", .{ abs_source, target, copy_err });
            return error.CachePopulationFailed;
        };
    };
}

// ── #685 migration: legacy locally-poisoned version slots ────────────

/// Remove a version-named cache slot that an older assembler populated with
/// local sources. Such a slot is named `gfx/1.29.0` but contains whatever
/// the monorepo working tree happened to hold, which is the whole of #685.
///
/// Two shapes, because `symlinkToCache` has two ways of populating:
///
///   * a SYMLINK — unambiguous: a genuine extracted release is never one,
///     so the link is dropped (the source checkout is untouched); and
///   * a real DIRECTORY, which the Windows copy fallback produces and which
///     is indistinguishable from an extracted release by shape. Its CONTENT
///     gives it away: a release declares its own version in `build.zig.zon`,
///     a copied working tree declares whatever it was at. That is exactly
///     the evidence #685 was reported with.
///
/// The content rule applies ONLY to SEMVER-shaped slot names (#688 review
/// round 5). A slot named for a branch or ref — `main`, `dev` — legitimately
/// holds an archive whose zon declares a release semver, and comparing the
/// two would delete a perfectly good cache on every `install`, breaking
/// offline use. A missing or unparseable zon also leaves the slot alone:
/// this repairs known damage, it does not guess.
///
/// Returns true when something was removed. A removal that FAILS is an
/// error, not a false: the poisoned slot is still there and every presence
/// probe would accept it, so the caller must abort rather than build it.
pub fn purgeLegacyLocalSlot(allocator: std.mem.Allocator, slot_path: []const u8, version: []const u8) error{PurgeFailed}!bool {
    const io = config.globalIo();

    // Containment, checked HERE rather than at each caller (#688 review
    // round 6): every purge target is built from a user-supplied version
    // string — a CLI argument, but also a `project.labelle` field, which no
    // argument validation covers — and this function DELETES. A version like
    // `../../../../tmp/1.2.3` would otherwise reach outside the cache.
    if (!withinPackagesDir(allocator, slot_path)) {
        std.log.warn("labelle: refusing to touch cache slot '{s}' — it is outside the package cache", .{slot_path});
        return false;
    }

    if (isSymlink(slot_path)) {
        std.Io.Dir.cwd().deleteFile(io, slot_path) catch |err| {
            std.log.warn("labelle: could not remove locally-sourced cache slot '{s}': {any}", .{ slot_path, err });
            return error.PurgeFailed;
        };
        std.log.warn(
            "labelle: removed cache slot '{s}' — it was a symlink to a local checkout, not the pinned release (#685)",
            .{slot_path},
        );
        return true;
    }

    if (!dirExists(slot_path)) return false;

    // The PIN decides, not the path's last component (#688 review round 7):
    // `release/1.2.3` is a supported ref whose slot basename reads as semver,
    // and its archive's manifest declares whatever that branch is at. Judging
    // it by content would delete a valid cache on every install.
    if (!isCanonicalSemver(version)) return false;

    const declared = declaredZonVersion(allocator, slot_path) orelse return false;
    defer allocator.free(declared);
    if (std.mem.eql(u8, declared, version)) return false;

    std.Io.Dir.cwd().deleteTree(io, slot_path) catch |err| {
        std.log.warn("labelle: could not remove mis-versioned cache slot '{s}': {any}", .{ slot_path, err });
        return error.PurgeFailed;
    };
    std.log.warn(
        "labelle: removed cache slot '{s}' — it holds {s} sources, not the {s} release (#685)",
        .{ slot_path, declared, version },
    );
    return true;
}

/// Whether `version` is a full `X.Y.Z` release, all three components
/// numeric.
///
/// Stricter than `config.isSemverVersion`, which accepts anything starting
/// with a digit — including the abbreviated `1.2` form, whose package
/// legitimately declares the canonical `1.2.0` in its manifest. Comparing
/// those two strings would classify a valid release as a copied checkout
/// and delete it (#688 review round 8). Anything short of a canonical
/// release is left alone.
fn isCanonicalSemver(version: []const u8) bool {
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, version, '.');
    while (it.next()) |part| {
        parts += 1;
        if (parts > 3 or part.len == 0) return false;
        for (part) |c| {
            if (!std.ascii.isDigit(c)) return false;
        }
    }
    return parts == 3;
}

/// Whether `path` lies strictly inside the packages directory, with no
/// `..` component to walk back out of it. A prefix test alone is not
/// enough: `<packages>/gfx/../../tmp/x` starts with the packages dir and
/// still escapes it.
fn withinPackagesDir(allocator: std.mem.Allocator, path: []const u8) bool {
    const packages_dir = env.getPackagesDir(allocator) catch return false;
    defer allocator.free(packages_dir);

    if (path.len <= packages_dir.len) return false;
    if (!std.mem.startsWith(u8, path, packages_dir)) return false;
    if (path[packages_dir.len] != '/' and path[packages_dir.len] != '\\') return false;

    var it = std.mem.tokenizeAny(u8, path[packages_dir.len + 1 ..], "/\\");
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return false;
    }

    // Lexical containment is not enough (#688 review round 8): a
    // slash-delimited pin nests, so `gfx/release/1.2.3` sits under
    // `gfx/release` — and a legacy `gfx/release` may itself be a SYMLINK to
    // a checkout, in which case the deletion below would land inside the
    // user's source tree while the string still reads as inside the cache.
    // Resolve the PARENT (the slot itself may be a link we must not follow,
    // or may not exist yet) and re-check containment on canonical paths.
    const parent = std.fs.path.dirname(path) orelse return false;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    const canon_parent = cwd.realPathFileAlloc(io, parent, allocator) catch return false;
    defer allocator.free(canon_parent);
    const canon_root = cwd.realPathFileAlloc(io, packages_dir, allocator) catch return false;
    defer allocator.free(canon_root);

    if (canon_parent.len < canon_root.len) return false;
    if (!std.mem.startsWith(u8, canon_parent, canon_root)) return false;
    if (canon_parent.len == canon_root.len) return true;
    return canon_parent[canon_root.len] == '/' or canon_parent[canon_root.len] == '\\';
}

/// The `.version` a package's own `build.zig.zon` declares, or null when
/// there isn't one to read. Caller owns the result.
///
/// Skips `//` comments and string literals while scanning (#688 review
/// round 5): a manifest carrying a commented-out `.version` above the real
/// field would otherwise report the commented value, and the caller DELETES
/// a directory on a mismatch.
pub fn declaredZonVersion(allocator: std.mem.Allocator, dir: []const u8) ?[]const u8 {
    const zon_path = std.fs.path.join(allocator, &.{ dir, "build.zig.zon" }) catch return null;
    defer allocator.free(zon_path);

    const content = std.Io.Dir.cwd().readFileAlloc(config.globalIo(), zon_path, allocator, .limited(256 * 1024)) catch return null;
    defer allocator.free(content);

    const key = ".version";
    var i: usize = 0;
    while (i < content.len) {
        switch (content[i]) {
            '/' => {
                if (i + 1 < content.len and content[i + 1] == '/') {
                    i = std.mem.indexOfScalarPos(u8, content, i, '\n') orelse content.len;
                    continue;
                }
                i += 1;
            },
            '"' => {
                // Skip the literal, honouring backslash escapes.
                i += 1;
                while (i < content.len and content[i] != '"') : (i += 1) {
                    if (content[i] == '\\') i += 1;
                }
                i += 1;
            },
            '.' => {
                if (!std.mem.startsWith(u8, content[i..], key)) {
                    i += 1;
                    continue;
                }
                var j = i + key.len;
                while (j < content.len and (content[j] == ' ' or content[j] == '\t')) j += 1;
                if (j >= content.len or content[j] != '=') {
                    i += 1;
                    continue;
                }
                j += 1;
                while (j < content.len and (content[j] == ' ' or content[j] == '\t')) j += 1;
                if (j >= content.len or content[j] != '"') {
                    i += 1;
                    continue;
                }
                const start = j + 1;
                const end = std.mem.indexOfScalarPos(u8, content, start, '"') orelse return null;
                return allocator.dupe(u8, content[start..end]) catch null;
            },
            else => i += 1,
        }
    }
    return null;
}

/// Sweep every version-named slot a project's pins point at, dropping the
/// ones an older assembler poisoned with local sources. Called before the
/// cache-presence probes so the affected packages get re-fetched.
pub fn purgeLegacyLocalSlots(allocator: std.mem.Allocator, cfg: config.ProjectConfig) !void {
    const packages_dir = env.getPackagesDir(allocator) catch return;
    defer allocator.free(packages_dir);

    const framework = [_]struct { name: []const u8, version: []const u8 }{
        .{ .name = "core", .version = cfg.core_version },
        .{ .name = "engine", .version = cfg.engine_version },
        .{ .name = "gfx", .version = cfg.gfx_version },
    };
    for (framework) |pkg| {
        if (config.isLocalVersion(pkg.version)) continue;
        const slot = std.fs.path.join(allocator, &.{ packages_dir, pkg.name, pkg.version }) catch continue;
        defer allocator.free(slot);
        _ = try purgeLegacyLocalSlot(allocator, slot, pkg.version);
    }

    // The assembler slot is a real directory whose backends/ecs/gui SUBDIRS
    // were symlinked out of the monorepo. Drop the whole slot when any of
    // them is a link, so the release is re-fetched intact.
    const asm_ver = cfg.assembler_version orelse cfg.labelle_version;
    if (!config.isLocalVersion(asm_ver)) blk: {
        const slot = std.fs.path.join(allocator, &.{ packages_dir, "assembler", asm_ver }) catch break :blk;
        defer allocator.free(slot);
        for ([_][]const u8{ "backends", "ecs", "gui" }) |subdir| {
            const sub = std.fs.path.join(allocator, &.{ slot, subdir }) catch continue;
            defer allocator.free(sub);
            if (!isSymlink(sub)) continue;
            // Same containment the generic purge applies: `assembler_version`
            // comes from `project.labelle` and is joined straight into this
            // path, so an escaping pin would aim this deleteTree outside the
            // cache (#688 review round 7).
            if (!withinPackagesDir(allocator, slot)) {
                std.log.warn("labelle: refusing to touch assembler slot '{s}' — it is outside the package cache", .{slot});
                break;
            }
            std.Io.Dir.cwd().deleteTree(config.globalIo(), slot) catch |err| {
                std.log.warn("labelle: could not remove locally-sourced assembler slot '{s}': {any}", .{ slot, err });
                return error.PurgeFailed;
            };
            std.log.warn(
                "labelle: removed assembler cache slot '{s}' — its bundled packages were symlinks to a local checkout (#685)",
                .{slot},
            );
            break;
        }
    }

    for (cfg.plugins) |plugin| {
        try purgeLegacyPluginSlot(allocator, packages_dir, plugin);
    }
    if (cfg.effectiveBackendPackage()) |bp| try purgeLegacyPluginSlot(allocator, packages_dir, bp);

    // A GUI `.package` rides the same `plugins/<repo>/<version>` path a
    // declared plugin does, but is referenced through `cfg.gui`, not
    // `cfg.plugins` — so a slot an older project poisoned as a local plugin
    // survived this sweep and `gui_resolve` went on loading the checkout
    // instead of the pinned GUI release (#688 review round 5).
    if (cfg.gui) |gui| blk: {
        const pkg = gui.package orelse break :blk;
        const ver = gui.version orelse break :blk;
        if (pkg.len == 0 or ver.len == 0 or config.isLocalVersion(ver)) break :blk;
        const slot = std.fs.path.join(allocator, &.{ packages_dir, "plugins", pkg, ver }) catch break :blk;
        defer allocator.free(slot);
        _ = try purgeLegacyLocalSlot(allocator, slot, ver);
    }

    // The tests target (#83) ALWAYS forces `.backend = .null`, so `validateCache`
    // requires the null provider whatever the project's own backend is — and
    // `isPluginCached` would accept a legacy symlinked `labelle-null` slot as
    // cached, leaving the tests target compiling an old local checkout forever
    // (#688 review). Sweep it too, deduplicated against the project backend.
    const tests_target_cfg = config.ProjectConfig{ .name = cfg.name, .backend = .null };
    if (tests_target_cfg.effectiveBackendPackage()) |null_bp| {
        const already = if (cfg.effectiveBackendPackage()) |bp|
            std.mem.eql(u8, bp.name, null_bp.name)
        else
            false;
        if (!already) try purgeLegacyPluginSlot(allocator, packages_dir, null_bp);
    }
}

fn purgeLegacyPluginSlot(allocator: std.mem.Allocator, packages_dir: []const u8, plugin: config.PluginDep) !void {
    if (plugin.isLocal() or plugin.repo.len == 0 or plugin.version.len == 0) return;
    const slot = std.fs.path.join(allocator, &.{ packages_dir, "plugins", plugin.repo, plugin.version }) catch return;
    defer allocator.free(slot);
    _ = try purgeLegacyLocalSlot(allocator, slot, plugin.version);
}

/// Whether `path` exists and is accessible. Public so the cache
/// subcommand handlers (cache_cmd.zig) can probe monorepo source dirs
/// before deciding between a local symlink and a remote clone.
pub fn dirExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(config.globalIo(), path, .{}) catch return false;
    return true;
}

/// Check if a path is a symlink.
pub fn isSymlink(path: []const u8) bool {
    var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    _ = std.Io.Dir.readLinkAbsolute(config.globalIo(), path, &link_buf) catch return false;
    return true;
}

/// Recursively copy a directory tree.
pub fn copyDirRecursive(allocator: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, dst) catch {};

    var src_dir = try cwd.openDir(io, src, .{ .iterate = true });
    defer src_dir.close(io);

    var iter = src_dir.iterate();
    while (try iter.next(io)) |entry| {
        const src_sub = try std.fs.path.join(allocator, &.{ src, entry.name });
        defer allocator.free(src_sub);
        const dst_sub = try std.fs.path.join(allocator, &.{ dst, entry.name });
        defer allocator.free(dst_sub);

        switch (entry.kind) {
            .directory => try copyDirRecursive(allocator, src_sub, dst_sub),
            .file => {
                cwd.copyFile(src_sub, cwd, dst_sub, io, .{}) catch |err| {
                    std.log.warn("labelle: could not copy '{s}': {any}", .{ src_sub, err });
                    return err;
                };
            },
            else => {},
        }
    }
}

/// Patch build.zig.zon files in cached packages to rewrite sibling path deps
/// (e.g. `../labelle-core`) to point to other cached packages.
/// Must be called after all framework packages are cached.
pub fn patchCachedDeps(allocator: std.mem.Allocator, cfg: config.ProjectConfig) !void {
    // Only patch non-local packages
    const packages = [_]struct { name: []const u8, version: []const u8 }{
        .{ .name = "engine", .version = cfg.engine_version },
        .{ .name = "gfx", .version = cfg.gfx_version },
    };

    for (packages) |pkg| {
        if (config.isLocalVersion(pkg.version)) continue;

        const pkg_dir = try resolve.resolveFrameworkPackage(allocator, pkg.name, pkg.version, null);
        defer allocator.free(pkg_dir);

        // Never patch symlinked packages — they point to local repos that must not be mutated.
        if (isSymlink(pkg_dir)) continue;

        // Patch the main build.zig.zon (root: core is sibling → "../labelle-core")
        try patchZonFile(allocator, pkg_dir, "build.zig.zon", false);

        // Patch subpackage build.zig.zon files (scene/, camera/, etc.)
        // Subpackages are one level deeper → "../../labelle-core"
        const io = config.globalIo();
        var dir = std.Io.Dir.cwd().openDir(io, pkg_dir, .{ .iterate = true }) catch continue;
        defer dir.close(io);

        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            const sub_zon = try std.fs.path.join(allocator, &.{ pkg_dir, entry.name, "build.zig.zon" });
            defer allocator.free(sub_zon);
            if (std.Io.Dir.cwd().access(io, sub_zon, .{})) |_| {
                const sub_dir = try std.fs.path.join(allocator, &.{ pkg_dir, entry.name });
                defer allocator.free(sub_dir);
                try patchZonFile(allocator, sub_dir, "build.zig.zon", true);
            } else |_| {}
        }
    }
}

/// Patch a single build.zig.zon file in the global cache, rewriting
/// labelle-core path deps to work after deps_linker hardlinks the package
/// into .labelle/deps/ alongside core. In the deps layout, packages are
/// siblings, so core is at "../labelle-core" from a root package or
/// "../../labelle-core" from a subpackage (scene/, camera/).
fn patchZonFile(allocator: std.mem.Allocator, dir_path: []const u8, filename: []const u8, is_subpackage: bool) !void {
    const file_path = try std.fs.path.join(allocator, &.{ dir_path, filename });
    defer allocator.free(file_path);

    const io = config.globalIo();
    const content = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(256 * 1024)) catch return;
    defer allocator.free(content);

    // After deps_linker, all packages are siblings under .labelle/deps/.
    // Root build.zig.zon: core is at "../labelle-core"
    // Subpackage build.zig.zon (scene/, camera/): core is at "../../labelle-core"
    const target = if (is_subpackage) "../../labelle-core" else "../labelle-core";

    // Normalize all core path variants to the correct target for this depth.
    // Use a placeholder to avoid "../labelle-core" matching inside "../../labelle-core".
    var result = try allocator.dupe(u8, content);
    const step1 = try replaceAll(allocator, result, "../../labelle-core", "\x00CORE_REF\x00");
    allocator.free(result);
    const step2 = try replaceAll(allocator, step1, "../labelle-core", "\x00CORE_REF\x00");
    allocator.free(step1);
    const step3 = try replaceAll(allocator, step2, "\x00CORE_REF\x00", target);
    allocator.free(step2);
    result = step3;

    // Only write if changed
    if (!std.mem.eql(u8, content, result)) {
        const file = try std.Io.Dir.cwd().createFile(io, file_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, result);
    }
    allocator.free(result);
}

/// Simple string replace-all helper.
fn replaceAll(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < haystack.len) {
        if (i + needle.len <= haystack.len and std.mem.eql(u8, haystack[i..][0..needle.len], needle)) {
            try list.appendSlice(allocator, replacement);
            i += needle.len;
        } else {
            try list.append(allocator, haystack[i]);
            i += 1;
        }
    }
    return list.toOwnedSlice(allocator);
}

// ── Tests: #685 — a local install must not occupy a version slot ─────

const testing = std.testing;

/// Point LABELLE_HOME at `home` for the duration of a test. Returns the
/// previous `std.testing.environ` for the caller to restore.
///
/// PosixBlock-only construction (mirrors the hermetic probe in resolve.zig),
/// so callers skip on Windows.
fn setTestCacheHome(envp: *const [1:null]?[*:0]const u8) std.process.Environ {
    const saved = testing.environ;
    testing.environ = .{ .block = .{ .slice = envp } };
    return saved;
}

/// Write `body` into `dir/VERSION` — a stand-in for "which release's source
/// actually lives here", so a test can tell 1.29.0 sources from 1.30.0 ones.
fn writeVersionStamp(dir: []const u8, body: []const u8) !void {
    const io = config.globalIo();
    const path = try std.fs.path.join(testing.allocator, &.{ dir, "VERSION" });
    defer testing.allocator.free(path);
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, body);
}

fn readVersionStamp(allocator: std.mem.Allocator, dir: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ dir, "VERSION" });
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(config.globalIo(), path, allocator, .limited(4096));
}

test "populateFrameworkPackage: local sources never occupy the pinned version slot (#685)" {
    // The #679 reproduction, in miniature: a sibling checkout holding gfx
    // 1.30.0 sources is installed while the project pins 1.29.0. Before the
    // fix, `~/.labelle/packages/gfx/1.29.0` became a symlink to that checkout
    // and every later resolve of "gfx 1.29.0" handed back 1.30.0 code.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "home");
    try tmp.dir.createDirPath(testing.io, "toolkit/labelle-core");
    try tmp.dir.createDirPath(testing.io, "toolkit/labelle-gfx");

    const home = try tmp.dir.realPathFileAlloc(testing.io, "home", alloc);
    defer alloc.free(home);
    const src = try tmp.dir.realPathFileAlloc(testing.io, "toolkit/labelle-gfx", alloc);
    defer alloc.free(src);

    // The working tree is 1.30.0 — NOT the pinned version.
    try writeVersionStamp(src, "1.30.0");

    const home_env = try std.fmt.allocPrintSentinel(alloc, "LABELLE_HOME={s}", .{home}, 0);
    defer alloc.free(home_env);
    const envp = [_:null]?[*:0]const u8{home_env.ptr};
    const saved_environ = setTestCacheHome(&envp);
    defer testing.environ = saved_environ;

    try populateFrameworkPackage(alloc, "gfx", "1.29.0", src, .discovered);

    // The invariant: the slot named for a version was not touched.
    const version_slot = try std.fs.path.join(alloc, &.{ home, "packages", "gfx", "1.29.0" });
    defer alloc.free(version_slot);
    try testing.expect(!dirExists(version_slot));

    // The local sources landed in the reserved slot instead, with provenance.
    const slot = try local.frameworkSlot(alloc, "gfx");
    defer alloc.free(slot);
    try testing.expect(dirExists(slot));

    const stamp = try readVersionStamp(alloc, slot);
    defer alloc.free(stamp);
    try testing.expectEqualStrings("1.30.0", stamp);

    const origin = local.readOrigin(alloc, slot) orelse return error.TestUnexpectedResult;
    defer origin.deinit(alloc);
    try testing.expectEqualStrings(src, origin.source);
    try testing.expectEqualStrings("1.29.0", origin.pinned);
}

test "resolveFrameworkPackage: a pinned version resolves to the release, not the sibling checkout (#685)" {
    // Same setup, then the half that actually bit #679: resolving the pin.
    // A released assembler (running outside the monorepo) must get the
    // 1.29.0 release; the monorepo's own binary gets the local slot, and
    // says so.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "home/packages/gfx/1.29.0");
    try tmp.dir.createDirPath(testing.io, "toolkit/labelle-core");
    try tmp.dir.createDirPath(testing.io, "toolkit/labelle-gfx");
    try tmp.dir.createDirPath(testing.io, "toolkit/labelle-assembler/zig-out/bin");
    try tmp.dir.createDirPath(testing.io, "elsewhere/bin");

    const home = try tmp.dir.realPathFileAlloc(testing.io, "home", alloc);
    defer alloc.free(home);
    const src = try tmp.dir.realPathFileAlloc(testing.io, "toolkit/labelle-gfx", alloc);
    defer alloc.free(src);
    const release = try tmp.dir.realPathFileAlloc(testing.io, "home/packages/gfx/1.29.0", alloc);
    defer alloc.free(release);
    const monorepo_bin = try tmp.dir.realPathFileAlloc(testing.io, "toolkit/labelle-assembler/zig-out/bin", alloc);
    defer alloc.free(monorepo_bin);
    const outside_bin = try tmp.dir.realPathFileAlloc(testing.io, "elsewhere/bin", alloc);
    defer alloc.free(outside_bin);

    try writeVersionStamp(src, "1.30.0");
    try writeVersionStamp(release, "1.29.0");

    const home_env = try std.fmt.allocPrintSentinel(alloc, "LABELLE_HOME={s}", .{home}, 0);
    defer alloc.free(home_env);
    const envp = [_:null]?[*:0]const u8{home_env.ptr};
    const saved_environ = setTestCacheHome(&envp);
    defer testing.environ = saved_environ;

    try populateFrameworkPackage(alloc, "gfx", "1.29.0", src, .discovered);

    {
        // A released binary: the pin means the release.
        local.setProbeStartForTesting(outside_bin);
        defer local.setProbeStartForTesting(null);

        const path = try resolve.resolveFrameworkPackage(alloc, "gfx", "1.29.0", null);
        defer alloc.free(path);
        const stamp = try readVersionStamp(alloc, path);
        defer alloc.free(stamp);
        try testing.expectEqualStrings("1.29.0", stamp);
        try testing.expect(!local.isLocalSlotPath(alloc, path));
    }

    {
        // The monorepo's own binary: local sources, honestly named.
        local.setProbeStartForTesting(monorepo_bin);
        defer local.setProbeStartForTesting(null);

        const path = try resolve.resolveFrameworkPackage(alloc, "gfx", "1.29.0", null);
        defer alloc.free(path);
        const stamp = try readVersionStamp(alloc, path);
        defer alloc.free(stamp);
        try testing.expectEqualStrings("1.30.0", stamp);
        try testing.expect(local.isLocalSlotPath(alloc, path));
    }
}

test "purgeLegacyLocalSlot: drops a version slot symlinked at a local checkout (#685)" {
    // Migration: caches populated by an older assembler already hold poisoned
    // slots. A version slot that is a symlink can only have come from a local
    // install, so it is removed and re-fetched. A real extracted release
    // directory is never a symlink and must survive.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "home/packages/gfx");
    try tmp.dir.createDirPath(testing.io, "home/packages/core/1.27.0");
    try tmp.dir.createDirPath(testing.io, "checkout");

    const home = try tmp.dir.realPathFileAlloc(testing.io, "home", alloc);
    defer alloc.free(home);
    const checkout = try tmp.dir.realPathFileAlloc(testing.io, "checkout", alloc);
    defer alloc.free(checkout);

    const home_env = try std.fmt.allocPrintSentinel(alloc, "LABELLE_HOME={s}", .{home}, 0);
    defer alloc.free(home_env);
    const envp = [_:null]?[*:0]const u8{home_env.ptr};
    const saved_environ = setTestCacheHome(&envp);
    defer testing.environ = saved_environ;

    // The poisoned slot, exactly as the old populate wrote it.
    const poisoned = try std.fs.path.join(alloc, &.{ home, "packages", "gfx", "1.29.0" });
    defer alloc.free(poisoned);
    try symlinkToCache(alloc, checkout, poisoned);
    try testing.expect(dirExists(poisoned));

    try testing.expect(try purgeLegacyLocalSlot(alloc, poisoned, "1.29.0"));
    try testing.expect(!dirExists(poisoned));
    // The source checkout is untouched — only the link went away.
    try testing.expect(dirExists(checkout));

    // A genuine extracted release is left alone.
    const genuine = try std.fs.path.join(alloc, &.{ home, "packages", "core", "1.27.0" });
    defer alloc.free(genuine);
    try testing.expect(!try purgeLegacyLocalSlot(alloc, genuine, "1.27.0"));
    try testing.expect(dirExists(genuine));
}

test "frameworkVersionPath / pluginVersionPath: remote fetch targets ignore an active local slot (#688 review)" {
    // `archiveFetch` DELETES its target before extracting, so a remote fetch
    // routed through the context-sensitive build resolver would overwrite the
    // reserved local slot with one release — reachable through a single-package
    // `install` run inside the monorepo. The write path must be version-named.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "home");
    try tmp.dir.createDirPath(testing.io, "toolkit/labelle-core");
    try tmp.dir.createDirPath(testing.io, "toolkit/labelle-gfx");
    try tmp.dir.createDirPath(testing.io, "toolkit/labelle-assembler/zig-out/bin");

    const home = try tmp.dir.realPathFileAlloc(testing.io, "home", alloc);
    defer alloc.free(home);
    const src = try tmp.dir.realPathFileAlloc(testing.io, "toolkit/labelle-gfx", alloc);
    defer alloc.free(src);
    const bin = try tmp.dir.realPathFileAlloc(testing.io, "toolkit/labelle-assembler/zig-out/bin", alloc);
    defer alloc.free(bin);

    const home_env = try std.fmt.allocPrintSentinel(alloc, "LABELLE_HOME={s}", .{home}, 0);
    defer alloc.free(home_env);
    const envp = [_:null]?[*:0]const u8{home_env.ptr};
    const saved_environ = setTestCacheHome(&envp);
    defer testing.environ = saved_environ;

    try populateFrameworkPackage(alloc, "gfx", "1.29.0", src, .discovered);

    local.setProbeStartForTesting(bin);
    defer local.setProbeStartForTesting(null);

    // The build resolver honours the slot …
    const resolved = try resolve.resolveFrameworkPackage(alloc, "gfx", "1.31.0", null);
    defer alloc.free(resolved);
    try testing.expect(local.isLocalSlotPath(alloc, resolved));

    // … the fetch target never does.
    const fetch_target = try resolve.frameworkVersionPath(alloc, "gfx", "1.31.0");
    defer alloc.free(fetch_target);
    const expected = try std.fs.path.join(alloc, &.{ home, "packages", "gfx", "1.31.0" });
    defer alloc.free(expected);
    try testing.expectEqualStrings(expected, fetch_target);

    const plugin: config.PluginDep = .{ .name = "physics", .repo = "github.com/labelle-toolkit/labelle-physics", .version = "0.4.0" };
    const plugin_target = try resolve.pluginVersionPath(alloc, plugin);
    defer alloc.free(plugin_target);
    const expected_plugin = try std.fs.path.join(alloc, &.{ home, "packages", "plugins", plugin.repo, plugin.version });
    defer alloc.free(expected_plugin);
    try testing.expectEqualStrings(expected_plugin, plugin_target);
}

test "purgeLegacyLocalSlots: sweeps the implicit null backend the tests target needs (#688 review)" {
    // `validateCache` ALWAYS requires the null provider (the tests target forces
    // `.backend = .null`), so a legacy symlinked `labelle-null` slot left behind
    // would keep reporting cached and the tests target would keep compiling an
    // old local checkout. The sweep must cover it even when the project's own
    // backend is something else.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "home");
    try tmp.dir.createDirPath(testing.io, "checkout");

    const home = try tmp.dir.realPathFileAlloc(testing.io, "home", alloc);
    defer alloc.free(home);
    const checkout = try tmp.dir.realPathFileAlloc(testing.io, "checkout", alloc);
    defer alloc.free(checkout);

    const home_env = try std.fmt.allocPrintSentinel(alloc, "LABELLE_HOME={s}", .{home}, 0);
    defer alloc.free(home_env);
    const envp = [_:null]?[*:0]const u8{home_env.ptr};
    const saved_environ = setTestCacheHome(&envp);
    defer testing.environ = saved_environ;

    const cfg = config.ProjectConfig{ .name = "demo", .backend = .bgfx };
    const null_bp = (config.ProjectConfig{ .name = "demo", .backend = .null }).effectiveBackendPackage().?;

    const poisoned = try std.fs.path.join(alloc, &.{ home, "packages", "plugins", null_bp.repo, null_bp.version });
    defer alloc.free(poisoned);
    try std.Io.Dir.cwd().createDirPath(config.globalIo(), std.fs.path.dirname(poisoned).?);
    try symlinkToCache(alloc, checkout, poisoned);
    try testing.expect(dirExists(poisoned));

    try purgeLegacyLocalSlots(alloc, cfg);

    try testing.expect(!dirExists(poisoned));
    try testing.expect(dirExists(checkout));
}

test "symlinkToCache: a stale COPIED slot is dropped and repopulated (#688 review)" {
    // The copy fallback (Windows without symlink privileges) leaves a real
    // directory in the slot. `symlinkToCache` used to hit PathAlreadyExists,
    // fail to read it as a link, and return SUCCESS without touching it — so
    // the probe reporting the copy stale bought nothing: `ensureCache` called
    // populate, populate no-opped, and generation resolved the same snapshot.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "home");
    try tmp.dir.createDirPath(testing.io, "toolkit/labelle-gfx");

    const home = try tmp.dir.realPathFileAlloc(testing.io, "home", alloc);
    defer alloc.free(home);
    const src = try tmp.dir.realPathFileAlloc(testing.io, "toolkit/labelle-gfx", alloc);
    defer alloc.free(src);
    try writeVersionStamp(src, "1.31.0");

    const home_env = try std.fmt.allocPrintSentinel(alloc, "LABELLE_HOME={s}", .{home}, 0);
    defer alloc.free(home_env);
    const envp = [_:null]?[*:0]const u8{home_env.ptr};
    const saved_environ = setTestCacheHome(&envp);
    defer testing.environ = saved_environ;

    // Stand in for the copy fallback's output: a real directory holding an
    // out-of-date snapshot.
    const slot = try local.frameworkSlot(alloc, "gfx");
    defer alloc.free(slot);
    try std.Io.Dir.cwd().createDirPath(config.globalIo(), slot);
    try writeVersionStamp(slot, "1.29.0");
    try testing.expect(!local.isSymlinkPath(slot));

    try populateFrameworkPackage(alloc, "gfx", "1.31.0", src, .discovered);

    // Refreshed: it tracks the source again, and serves current sources.
    try testing.expect(local.isSymlinkPath(slot));
    const stamp = try readVersionStamp(alloc, slot);
    defer alloc.free(stamp);
    try testing.expectEqualStrings("1.31.0", stamp);
}

test "purgeLegacyLocalSlot: drops a COPIED version slot whose contents are a different version (#688 review)" {
    // The gap the symlink test leaves: `symlinkToCache`'s copy fallback
    // (Windows without symlink privileges) put local sources into the
    // version slot as a REAL directory, which no shape test can tell from an
    // extracted release. `labelle-assembler clean` is not the remedy either
    // — it keeps whatever the project pins, which is exactly the affected
    // slot. Content decides: a release declares its own version.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "home/packages/gfx/1.29.0");
    try tmp.dir.createDirPath(testing.io, "home/packages/core/1.27.0");
    try tmp.dir.createDirPath(testing.io, "home/packages/engine/2.4.0");

    const home = try tmp.dir.realPathFileAlloc(testing.io, "home", alloc);
    defer alloc.free(home);

    const home_env = try std.fmt.allocPrintSentinel(alloc, "LABELLE_HOME={s}", .{home}, 0);
    defer alloc.free(home_env);
    const envp = [_:null]?[*:0]const u8{home_env.ptr};
    const saved_environ = setTestCacheHome(&envp);
    defer testing.environ = saved_environ;

    // A copied working tree: the slot says 1.29.0, the sources say 1.31.0.
    const poisoned = try std.fs.path.join(alloc, &.{ home, "packages", "gfx", "1.29.0" });
    defer alloc.free(poisoned);
    try writeZon(poisoned, ".{\n    .name = .labelle_gfx,\n    .version = \"1.31.0\",\n}\n");

    // A genuine extracted release: slot and sources agree.
    const genuine = try std.fs.path.join(alloc, &.{ home, "packages", "core", "1.27.0" });
    defer alloc.free(genuine);
    try writeZon(genuine, ".{\n    .name = .labelle_core,\n    .version = \"1.27.0\",\n}\n");

    // No readable zon at all: left alone rather than guessed at.
    const unknown = try std.fs.path.join(alloc, &.{ home, "packages", "engine", "2.4.0" });
    defer alloc.free(unknown);

    try testing.expect(try purgeLegacyLocalSlot(alloc, poisoned, "1.29.0"));
    try testing.expect(!dirExists(poisoned));

    try testing.expect(!try purgeLegacyLocalSlot(alloc, genuine, "1.27.0"));
    try testing.expect(dirExists(genuine));
    try testing.expect(!try purgeLegacyLocalSlot(alloc, unknown, "2.4.0"));
    try testing.expect(dirExists(unknown));
}

fn writeZon(dir: []const u8, body: []const u8) !void {
    const io = config.globalIo();
    const path = try std.fs.path.join(testing.allocator, &.{ dir, "build.zig.zon" });
    defer testing.allocator.free(path);
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, body);
}

test "symlinkToCache: a link that cannot be replaced fails population (#688 review)" {
    // `catch return` on the replace path reported success, so
    // `populateFrameworkPackage` went on to rewrite the provenance marker
    // with the NEW source while the link still targeted the old checkout —
    // and `active*Slot` trusts that marker.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "home");
    try tmp.dir.createDirPath(testing.io, "old");
    try tmp.dir.createDirPath(testing.io, "new");

    const home = try tmp.dir.realPathFileAlloc(testing.io, "home", alloc);
    defer alloc.free(home);
    const old_src = try tmp.dir.realPathFileAlloc(testing.io, "old", alloc);
    defer alloc.free(old_src);
    const new_src = try tmp.dir.realPathFileAlloc(testing.io, "new", alloc);
    defer alloc.free(new_src);

    const home_env = try std.fmt.allocPrintSentinel(alloc, "LABELLE_HOME={s}", .{home}, 0);
    defer alloc.free(home_env);
    const envp = [_:null]?[*:0]const u8{home_env.ptr};
    const saved_environ = setTestCacheHome(&envp);
    defer testing.environ = saved_environ;

    // A slot linked at the OLD checkout, inside a directory made read-only
    // so the link cannot be unlinked.
    const slot = try local.frameworkSlot(alloc, "gfx");
    defer alloc.free(slot);
    const parent = std.fs.path.dirname(slot).?;
    try std.Io.Dir.cwd().createDirPath(config.globalIo(), parent);
    try std.Io.Dir.cwd().symLink(testing.io, old_src, slot, .{ .is_directory = true });

    const parent_z = try alloc.dupeZ(u8, parent);
    defer alloc.free(parent_z);
    if (std.c.chmod(parent_z, 0o500) != 0) return error.SkipZigTest;
    defer _ = std.c.chmod(parent_z, 0o700);

    if (symlinkToCache(alloc, new_src, slot)) |_| {
        // Reported success. That is only legitimate if the link REALLY was
        // replaced — which happens when the test runs as root and the
        // permission bits mean nothing. Otherwise it is the defect: success
        // with the old link still in place, after which the caller rewrites
        // the marker to name the new source.
        var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try std.Io.Dir.readLinkAbsolute(config.globalIo(), slot, &link_buf);
        if (std.mem.eql(u8, link_buf[0..len], new_src)) return error.SkipZigTest;
        std.debug.print(
            "symlinkToCache reported success but '{s}' still points at '{s}'\n",
            .{ slot, link_buf[0..len] },
        );
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expectEqual(error.CachePopulationFailed, err);
        // The link still points where it did — and, crucially, population
        // did not get far enough to rewrite the marker.
        var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try std.Io.Dir.readLinkAbsolute(config.globalIo(), slot, &link_buf);
        try testing.expectEqualStrings(old_src, link_buf[0..len]);
    }
}

test "purgeLegacyLocalSlot: a non-semver ref slot is never judged by its zon version (#688 review)" {
    // `versionToGitRef` supports branch/ref pins, and a `main` slot holds an
    // archive whose zon declares a RELEASE semver — nothing to do with the
    // directory name. Judging it by content would delete a perfectly good
    // cache on every install and break offline use.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "home/packages/gfx/main");

    const home = try tmp.dir.realPathFileAlloc(testing.io, "home", alloc);
    defer alloc.free(home);

    const home_env = try std.fmt.allocPrintSentinel(alloc, "LABELLE_HOME={s}", .{home}, 0);
    defer alloc.free(home_env);
    const envp = [_:null]?[*:0]const u8{home_env.ptr};
    const saved_environ = setTestCacheHome(&envp);
    defer testing.environ = saved_environ;

    const ref_slot = try std.fs.path.join(alloc, &.{ home, "packages", "gfx", "main" });
    defer alloc.free(ref_slot);
    try writeZon(ref_slot, ".{\n    .name = .labelle_gfx,\n    .version = \"1.31.0\",\n}\n");

    try testing.expect(!try purgeLegacyLocalSlot(alloc, ref_slot, "main"));
    try testing.expect(dirExists(ref_slot));
}

test "declaredZonVersion: a commented-out version does not decide a deletion (#688 review)" {
    // The scan drives a `deleteTree`, so a manifest carrying a commented
    // `.version` above the real field must not report the commented value.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "pkg");
    const pkg = try tmp.dir.realPathFileAlloc(testing.io, "pkg", alloc);
    defer alloc.free(pkg);

    try writeZon(pkg,
        \\.{
        \\    .name = .labelle_gfx,
        \\    // .version = "1.31.0",  ← bumped next release
        \\    .version = "1.29.0",
        \\    .fingerprint = 0x0,
        \\}
        \\
    );

    const declared = declaredZonVersion(alloc, pkg) orelse return error.TestUnexpectedResult;
    defer alloc.free(declared);
    try testing.expectEqualStrings("1.29.0", declared);
}

test "purgeLegacyLocalSlots: sweeps a slot referenced only through the GUI package (#688 review)" {
    // A `.gui = .{ .package = …, .version = … }` rides the same
    // `plugins/<repo>/<version>` path a declared plugin does, but is not in
    // `cfg.plugins` — so a slot an older project poisoned as a local plugin
    // survived the sweep and gui_resolve kept loading the checkout.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "home");
    try tmp.dir.createDirPath(testing.io, "checkout");

    const home = try tmp.dir.realPathFileAlloc(testing.io, "home", alloc);
    defer alloc.free(home);
    const checkout = try tmp.dir.realPathFileAlloc(testing.io, "checkout", alloc);
    defer alloc.free(checkout);

    const home_env = try std.fmt.allocPrintSentinel(alloc, "LABELLE_HOME={s}", .{home}, 0);
    defer alloc.free(home_env);
    const envp = [_:null]?[*:0]const u8{home_env.ptr};
    const saved_environ = setTestCacheHome(&envp);
    defer testing.environ = saved_environ;

    const gui_pkg = "github.com/labelle-toolkit/labelle-imgui";
    const poisoned = try std.fs.path.join(alloc, &.{ home, "packages", "plugins", gui_pkg, "0.3.0" });
    defer alloc.free(poisoned);
    try std.Io.Dir.cwd().createDirPath(config.globalIo(), std.fs.path.dirname(poisoned).?);
    try symlinkToCache(alloc, checkout, poisoned);
    try testing.expect(dirExists(poisoned));

    const cfg = config.ProjectConfig{
        .name = "demo",
        .gui = .{ .package = gui_pkg, .version = "0.3.0" },
    };
    try purgeLegacyLocalSlots(alloc, cfg);

    try testing.expect(!dirExists(poisoned));
    try testing.expect(dirExists(checkout));
}

test "purgeLegacyLocalSlot: refuses a target outside the package cache (#688 review)" {
    // Purge targets are built from user-supplied version strings — including
    // `project.labelle` fields, which no CLI-argument validation covers — and
    // this function deletes. A version like `../../../../tmp/1.2.3` must not
    // reach outside the cache.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "home/packages/gfx");
    try tmp.dir.createDirPath(testing.io, "outside");
    try tmp.dir.createDirPath(testing.io, "checkout");

    const home = try tmp.dir.realPathFileAlloc(testing.io, "home", alloc);
    defer alloc.free(home);
    const outside = try tmp.dir.realPathFileAlloc(testing.io, "outside", alloc);
    defer alloc.free(outside);
    const checkout = try tmp.dir.realPathFileAlloc(testing.io, "checkout", alloc);
    defer alloc.free(checkout);

    const home_env = try std.fmt.allocPrintSentinel(alloc, "LABELLE_HOME={s}", .{home}, 0);
    defer alloc.free(home_env);
    const envp = [_:null]?[*:0]const u8{home_env.ptr};
    const saved_environ = setTestCacheHome(&envp);
    defer testing.environ = saved_environ;

    // A symlink outside the cache — exactly what an escaping version reaches.
    const victim = try std.fs.path.join(alloc, &.{ outside, "1.2.3" });
    defer alloc.free(victim);
    try symlinkToCache(alloc, checkout, victim);
    try testing.expect(dirExists(victim));

    // Named directly …
    try testing.expect(!try purgeLegacyLocalSlot(alloc, victim, "1.2.3"));
    try testing.expect(dirExists(victim));

    // … and reached by traversal from a path that starts inside the cache,
    // which a prefix test alone would wave through.
    const traversed = try std.fs.path.join(alloc, &.{ home, "packages", "gfx", "..", "..", "..", "outside", "1.2.3" });
    defer alloc.free(traversed);
    try testing.expect(!try purgeLegacyLocalSlot(alloc, traversed, "1.2.3"));
    try testing.expect(dirExists(victim));
}

test "purgeLegacyLocalSlot: a ref ending in a semver component is judged by the PIN (#688 review)" {
    // `release/1.2.3` is a supported ref whose slot basename reads as semver.
    // Judging it by content would delete a valid remote cache on every
    // install; the pin decides, and `release/1.2.3` is not semver.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "home/packages/gfx/release/1.2.3");

    const home = try tmp.dir.realPathFileAlloc(testing.io, "home", alloc);
    defer alloc.free(home);

    const home_env = try std.fmt.allocPrintSentinel(alloc, "LABELLE_HOME={s}", .{home}, 0);
    defer alloc.free(home_env);
    const envp = [_:null]?[*:0]const u8{home_env.ptr};
    const saved_environ = setTestCacheHome(&envp);
    defer testing.environ = saved_environ;

    const slot = try std.fs.path.join(alloc, &.{ home, "packages", "gfx", "release", "1.2.3" });
    defer alloc.free(slot);
    try writeZon(slot, ".{\n    .name = .labelle_gfx,\n    .version = \"1.31.0\",\n}\n");

    try testing.expect(!try purgeLegacyLocalSlot(alloc, slot, "release/1.2.3"));
    try testing.expect(dirExists(slot));
}

test "purgeLegacyLocalSlots: an escaping assembler pin cannot aim the sweep outside the cache (#688 review)" {
    // The assembler branch builds its path directly and deletes the whole
    // slot, so it needs the same containment the generic purge has.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "home/packages");
    try tmp.dir.createDirPath(testing.io, "victim");
    try tmp.dir.createDirPath(testing.io, "checkout");

    const home = try tmp.dir.realPathFileAlloc(testing.io, "home", alloc);
    defer alloc.free(home);
    const victim = try tmp.dir.realPathFileAlloc(testing.io, "victim", alloc);
    defer alloc.free(victim);
    const checkout = try tmp.dir.realPathFileAlloc(testing.io, "checkout", alloc);
    defer alloc.free(checkout);

    const home_env = try std.fmt.allocPrintSentinel(alloc, "LABELLE_HOME={s}", .{home}, 0);
    defer alloc.free(home_env);
    const envp = [_:null]?[*:0]const u8{home_env.ptr};
    const saved_environ = setTestCacheHome(&envp);
    defer testing.environ = saved_environ;

    // The escaping pin's slot, carrying the symlinked `backends/` that makes
    // the assembler branch delete the whole directory.
    const escaping = "../../../victim";
    const bait = try std.fs.path.join(alloc, &.{ victim, "backends" });
    defer alloc.free(bait);
    try symlinkToCache(alloc, checkout, bait);

    const cfg = config.ProjectConfig{ .name = "demo", .assembler_version = escaping };
    try purgeLegacyLocalSlots(alloc, cfg);

    try testing.expect(dirExists(victim));
    try testing.expect(dirExists(checkout));
}

test "isCanonicalSemver: only a full X.Y.Z release authorises a content-based purge (#688 review)" {
    // `config.isSemverVersion` accepts anything starting with a digit,
    // including the abbreviated `1.2` whose package legitimately declares
    // `1.2.0` — and the caller DELETES on a mismatch.
    try testing.expect(isCanonicalSemver("1.2.3"));
    try testing.expect(isCanonicalSemver("0.31.0"));

    try testing.expect(!isCanonicalSemver("1.2"));
    try testing.expect(!isCanonicalSemver("2"));
    try testing.expect(!isCanonicalSemver("1.2.3.4"));
    try testing.expect(!isCanonicalSemver("1.2.3-rc1"));
    try testing.expect(!isCanonicalSemver("main"));
    try testing.expect(!isCanonicalSemver("release/1.2.3"));
    try testing.expect(!isCanonicalSemver(""));
}

test "purgeLegacyLocalSlot: an abbreviated pin never deletes a canonical release (#688 review)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "home/packages/gfx/1.2");

    const home = try tmp.dir.realPathFileAlloc(testing.io, "home", alloc);
    defer alloc.free(home);

    const home_env = try std.fmt.allocPrintSentinel(alloc, "LABELLE_HOME={s}", .{home}, 0);
    defer alloc.free(home_env);
    const envp = [_:null]?[*:0]const u8{home_env.ptr};
    const saved_environ = setTestCacheHome(&envp);
    defer testing.environ = saved_environ;

    const slot = try std.fs.path.join(alloc, &.{ home, "packages", "gfx", "1.2" });
    defer alloc.free(slot);
    try writeZon(slot, ".{\n    .name = .labelle_gfx,\n    .version = \"1.2.0\",\n}\n");

    try testing.expect(!try purgeLegacyLocalSlot(alloc, slot, "1.2"));
    try testing.expect(dirExists(slot));
}

test "purgeLegacyLocalSlot: a symlinked ancestor cannot smuggle a deletion out of the cache (#688 review)" {
    // A slash-delimited pin nests, so `gfx/release/1.2.3` sits under
    // `gfx/release` — and a legacy `gfx/release` may itself be a symlink to a
    // checkout. The lexical containment test reads that path as inside the
    // cache while it resolves into the user's source tree.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "home/packages/gfx");
    try tmp.dir.createDirPath(testing.io, "checkout/1.2.3");

    const home = try tmp.dir.realPathFileAlloc(testing.io, "home", alloc);
    defer alloc.free(home);
    const checkout = try tmp.dir.realPathFileAlloc(testing.io, "checkout", alloc);
    defer alloc.free(checkout);

    const home_env = try std.fmt.allocPrintSentinel(alloc, "LABELLE_HOME={s}", .{home}, 0);
    defer alloc.free(home_env);
    const envp = [_:null]?[*:0]const u8{home_env.ptr};
    const saved_environ = setTestCacheHome(&envp);
    defer testing.environ = saved_environ;

    // `packages/gfx/release` → the checkout. The pin `release/1.2.3` then
    // names `packages/gfx/release/1.2.3`, i.e. `checkout/1.2.3`.
    const ancestor = try std.fs.path.join(alloc, &.{ home, "packages", "gfx", "release" });
    defer alloc.free(ancestor);
    try std.Io.Dir.cwd().symLink(testing.io, checkout, ancestor, .{ .is_directory = true });

    const inside = try std.fs.path.join(alloc, &.{ home, "packages", "gfx", "release", "1.2.3" });
    defer alloc.free(inside);
    try writeZon(inside, ".{\n    .name = .labelle_gfx,\n    .version = \"9.9.9\",\n}\n");

    try testing.expect(!try purgeLegacyLocalSlot(alloc, inside, "1.2.3"));

    const victim = try std.fs.path.join(alloc, &.{ checkout, "1.2.3" });
    defer alloc.free(victim);
    try testing.expect(dirExists(victim));
}
