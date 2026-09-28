//! #782 end to end, on the REAL filesystem probe (no injected `access`):
//! a `git+https:` backend repo whose cache path the host cannot name. On
//! Windows (the `cache-windows` CI job) this used to panic inside
//! `Dir.access` with OBJECT_NAME_INVALID; it must now come back as an
//! error / an unsupported `describe` naming the fix. On POSIX the same path
//! is nameable and simply not installed.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const describe = @import("describe.zig");
const backend_registry = @import("backend_registry.zig");
const cache = @import("cache.zig");
const cache_env = @import("cache/env.zig");
const config = @import("config.zig");

const repo = "git+https://github.com/labelle-toolkit/labelle-sokol";

const Fixture = struct {
    tmp: testing.TmpDir,
    arena_state: std.heap.ArenaAllocator,
    dir: []const u8,

    fn init() !Fixture {
        var f: Fixture = .{ .tmp = testing.tmpDir(.{}), .arena_state = std.heap.ArenaAllocator.init(testing.allocator), .dir = undefined };
        const a = f.arena_state.allocator();
        f.dir = try f.tmp.dir.realPathFileAlloc(testing.io, ".", a);
        cache_env.setCacheRootForTesting(try std.fs.path.join(a, &.{ f.dir, "home" }));
        return f;
    }

    fn deinit(f: *Fixture) void {
        cache_env.setCacheRootForTesting(null);
        f.arena_state.deinit();
        f.tmp.cleanup();
    }

    fn cfg(f: *Fixture) !config.ProjectConfig {
        const a = f.arena_state.allocator();
        const v = config.ProjectConfig.builtinProvider(.sokol).?.version;
        const src = try std.fmt.allocPrintSentinel(a, ".{{ .name = \"g\", .backend = .sokol, .backend_package = .{{ .name = \"sokol\", .repo = \"{s}\", .version = \"{s}\" }} }}", .{ repo, v }, 0);
        return @import("plugin_params.zig").parseProjectConfig(a, src);
    }
};

test "describe (real probe): a git+https backend repo is an error on Windows, not a panic (#782)" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena_state.allocator();
    const c = try f.cfg();

    const d = try describe.describe(a, c, f.dir, "desktop");
    try testing.expect(d.package_dir == null);
    try testing.expectEqual(describe.CapabilitySource.unknown, d.capabilities_source);

    if (builtin.os.tag == .windows) {
        // The mechanism: the resolver refused the path before any probe.
        try testing.expectError(error.UnusableCachePath, backend_registry.resolveBackendPackage(a, c, f.dir));
        try testing.expect(!d.supported);
        try testing.expectEqualStrings("UnusableCachePath", d.package_access_error.?);
        try testing.expect(std.mem.indexOf(u8, d.reason.?, "contains ':'") != null);
        try testing.expect(std.mem.indexOf(u8, d.reason.?, "Spell it 'github.com/labelle-toolkit/labelle-sokol'") != null);
    } else {
        // POSIX names the verbatim path; it is just not installed.
        const p = try backend_registry.resolveBackendPackage(a, c, f.dir);
        try testing.expect(std.mem.indexOf(u8, p, "git+https:") != null);
        try testing.expect(d.package_access_error == null);
    }
}

test "isPluginCached (real probe): an unnameable repo errors on Windows instead of panicking (#782)" {
    var f = try Fixture.init();
    defer f.deinit();
    const plugin: config.PluginDep = .{ .name = "sokol", .repo = repo, .version = "1.0.0" };
    if (builtin.os.tag == .windows) {
        try testing.expectError(error.UnusableCachePath, cache.isPluginCached(testing.allocator, plugin));
    } else {
        try testing.expect(!try cache.isPluginCached(testing.allocator, plugin));
    }
}
