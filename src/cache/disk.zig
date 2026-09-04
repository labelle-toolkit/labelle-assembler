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

        if (!dirExists(src_path)) continue;

        const dst_path = try std.fs.path.join(allocator, &.{ target, subdir });
        defer allocator.free(dst_path);

        symlinkToCache(allocator, src_path, dst_path) catch |err| {
            std.log.err("labelle: could not link '{s}' to cache: {any}", .{ src_path, err });
            return error.CachePopulationFailed;
        };
    }

    try local.writeOrigin(allocator, target, companion_dir, assembler_version);
}

/// Populate a framework package (core, engine, gfx) into the cache from a source directory.
/// Creates a symlink from the cache location to the source directory.
pub fn populateFrameworkPackage(allocator: std.mem.Allocator, package: []const u8, version: []const u8, source_dir: []const u8) !void {
    // #685: `version` no longer names the slot — it is recorded in the
    // provenance marker so diagnostics can say which pin this local source
    // was installed *for* without pretending the slot holds that release.
    const target = try local.frameworkSlot(allocator, package);
    defer allocator.free(target);
    try symlinkToCache(allocator, source_dir, target);
    try local.writeOrigin(allocator, target, source_dir, version);
}

/// Populate a plugin into the cache from a source directory.
/// Creates a symlink from the cache location to the source directory.
pub fn populatePlugin(allocator: std.mem.Allocator, plugin: config.PluginDep, source_dir: []const u8) !void {
    // #685: reserved local-namespace slot, same as the framework packages.
    const target = try local.pluginSlot(allocator, plugin);
    defer allocator.free(target);
    try symlinkToCache(allocator, source_dir, target);
    try local.writeOrigin(allocator, target, source_dir, plugin.version);
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

    // Ensure parent directory exists
    if (std.fs.path.dirname(target)) |parent| {
        cwd.createDirPath(io, parent) catch |err| {
            std.log.err("labelle: could not create cache directory '{s}': {any}", .{ parent, err });
            return error.CachePopulationFailed;
        };
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
///     the evidence #685 was reported with. Only a parsed version that
///     DIFFERS from the slot name purges — a missing or unparseable
///     `build.zig.zon` leaves the slot alone (#688 review round 4).
///
/// Returns true when something was removed.
pub fn purgeLegacyLocalSlot(allocator: std.mem.Allocator, slot_path: []const u8) bool {
    const io = config.globalIo();

    if (isSymlink(slot_path)) {
        std.Io.Dir.cwd().deleteFile(io, slot_path) catch |err| {
            std.log.warn("labelle: could not remove locally-sourced cache slot '{s}': {any}", .{ slot_path, err });
            return false;
        };
        std.log.warn(
            "labelle: removed cache slot '{s}' — it was a symlink to a local checkout, not the pinned release (#685)",
            .{slot_path},
        );
        return true;
    }

    if (!dirExists(slot_path)) return false;
    const declared = declaredZonVersion(allocator, slot_path) orelse return false;
    defer allocator.free(declared);
    const slot_version = std.fs.path.basename(slot_path);
    if (std.mem.eql(u8, declared, slot_version)) return false;

    std.Io.Dir.cwd().deleteTree(io, slot_path) catch |err| {
        std.log.warn("labelle: could not remove mis-versioned cache slot '{s}': {any}", .{ slot_path, err });
        return false;
    };
    std.log.warn(
        "labelle: removed cache slot '{s}' — it holds {s} sources, not the {s} release (#685)",
        .{ slot_path, declared, slot_version },
    );
    return true;
}

/// The `.version` a package's own `build.zig.zon` declares, or null when
/// there isn't one to read. Caller owns the result.
fn declaredZonVersion(allocator: std.mem.Allocator, dir: []const u8) ?[]const u8 {
    const zon_path = std.fs.path.join(allocator, &.{ dir, "build.zig.zon" }) catch return null;
    defer allocator.free(zon_path);

    const content = std.Io.Dir.cwd().readFileAlloc(config.globalIo(), zon_path, allocator, .limited(256 * 1024)) catch return null;
    defer allocator.free(content);

    const key = ".version";
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, content, search, key)) |pos| {
        search = pos + key.len;
        // A field, not a suffix of some longer identifier.
        if (pos > 0 and !std.ascii.isWhitespace(content[pos - 1]) and
            content[pos - 1] != '{' and content[pos - 1] != ',') continue;

        var i = search;
        while (i < content.len and (content[i] == ' ' or content[i] == '\t')) i += 1;
        if (i >= content.len or content[i] != '=') continue;
        i += 1;
        while (i < content.len and (content[i] == ' ' or content[i] == '\t')) i += 1;
        if (i >= content.len or content[i] != '"') continue;
        const start = i + 1;
        const end = std.mem.indexOfScalarPos(u8, content, start, '"') orelse return null;
        return allocator.dupe(u8, content[start..end]) catch null;
    }
    return null;
}

/// Sweep every version-named slot a project's pins point at, dropping the
/// ones an older assembler poisoned with local sources. Called before the
/// cache-presence probes so the affected packages get re-fetched.
pub fn purgeLegacyLocalSlots(allocator: std.mem.Allocator, cfg: config.ProjectConfig) void {
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
        _ = purgeLegacyLocalSlot(allocator, slot);
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
            std.Io.Dir.cwd().deleteTree(config.globalIo(), slot) catch |err| {
                std.log.warn("labelle: could not remove locally-sourced assembler slot '{s}': {any}", .{ slot, err });
                break;
            };
            std.log.warn(
                "labelle: removed assembler cache slot '{s}' — its bundled packages were symlinks to a local checkout (#685)",
                .{slot},
            );
            break;
        }
    }

    for (cfg.plugins) |plugin| {
        purgeLegacyPluginSlot(allocator, packages_dir, plugin);
    }
    if (cfg.effectiveBackendPackage()) |bp| purgeLegacyPluginSlot(allocator, packages_dir, bp);

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
        if (!already) purgeLegacyPluginSlot(allocator, packages_dir, null_bp);
    }
}

fn purgeLegacyPluginSlot(allocator: std.mem.Allocator, packages_dir: []const u8, plugin: config.PluginDep) void {
    if (plugin.isLocal() or plugin.repo.len == 0 or plugin.version.len == 0) return;
    const slot = std.fs.path.join(allocator, &.{ packages_dir, "plugins", plugin.repo, plugin.version }) catch return;
    defer allocator.free(slot);
    _ = purgeLegacyLocalSlot(allocator, slot);
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

    try populateFrameworkPackage(alloc, "gfx", "1.29.0", src);

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

    try populateFrameworkPackage(alloc, "gfx", "1.29.0", src);

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

    // The poisoned slot, exactly as the old populate wrote it.
    const poisoned = try std.fs.path.join(alloc, &.{ home, "packages", "gfx", "1.29.0" });
    defer alloc.free(poisoned);
    try symlinkToCache(alloc, checkout, poisoned);
    try testing.expect(dirExists(poisoned));

    try testing.expect(purgeLegacyLocalSlot(alloc, poisoned));
    try testing.expect(!dirExists(poisoned));
    // The source checkout is untouched — only the link went away.
    try testing.expect(dirExists(checkout));

    // A genuine extracted release is left alone.
    const genuine = try std.fs.path.join(alloc, &.{ home, "packages", "core", "1.27.0" });
    defer alloc.free(genuine);
    try testing.expect(!purgeLegacyLocalSlot(alloc, genuine));
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

    try populateFrameworkPackage(alloc, "gfx", "1.29.0", src);

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

    purgeLegacyLocalSlots(alloc, cfg);

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

    try populateFrameworkPackage(alloc, "gfx", "1.31.0", src);

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

    try testing.expect(purgeLegacyLocalSlot(alloc, poisoned));
    try testing.expect(!dirExists(poisoned));

    try testing.expect(!purgeLegacyLocalSlot(alloc, genuine));
    try testing.expect(dirExists(genuine));
    try testing.expect(!purgeLegacyLocalSlot(alloc, unknown));
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
