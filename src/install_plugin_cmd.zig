//! `labelle-assembler install plugin <name> local:<path>` (#772) — an
//! UNCOMMITTED, per-plugin local-source override.
//!
//! A game pins every plugin to a release in project.labelle, so a fresh
//! clone builds with no sibling checkouts. To work on ONE plugin against
//! that game, a developer used to have to edit the committed pin to
//! `.repo = "local:<path>"` (which the next generate also copies into the
//! committed labelle.lock), or run a monorepo-built assembler whose
//! auto-discovery swaps in EVERY `labelle-<name>` sibling at once.
//!
//! This is the plugin counterpart of `install <pkg> local:<path>` for
//! core/engine/gfx (#704): the checkout is linked into the plugin's reserved
//! local slot (`packages/local/plugins/<name>-<hash>`) with an `.explicit`
//! provenance marker. `resolve.resolvePlugin` already prefers an active
//! local slot over the pinned release, and an `.explicit` marker activates
//! wherever the assembler runs — including the released binary the CLI
//! shells out to. Nothing in the project changes; every build that
//! resolves through the override warns (`warnIfLocallySourced`).
//!
//!   install plugin <name> local:<path>   point <name> at a checkout
//!   install plugin <name>                show whether <name> is overridden
//!   install plugin <name> --unlink       drop the override (back to the pin)
//!
//! `<path>` is the PLUGIN directory — the directory holding its
//! `build.zig.zon` — also for a `.subdir` pin (#771): an override replaces
//! where the plugin lives, so the subdir is not re-applied to it.
//! `labelle-assembler clean` also drops every override.
const std = @import("std");
const cache = @import("cache.zig");
const config = @import("config.zig");

const local = cache.localSlots;

pub const Error = error{
    UnknownPlugin,
    PluginAlreadyLocal,
    NotALocalSpec,
    LocalSourceNotFound,
    NotAPluginCheckout,
    TooManyArguments,
    MissingPluginName,
};

pub const Action = union(enum) {
    status,
    link: []const u8,
    unlink,
};

/// Parse the positionals after `install plugin`. Pure, so the argument
/// contract is testable without a process exit.
pub fn parseAction(rest: []const []const u8, unlink: bool) Error!struct { name: []const u8, action: Action } {
    if (rest.len == 0) return error.MissingPluginName;
    if (rest.len > 2) return error.TooManyArguments;
    const name = rest[0];
    if (rest.len == 1) return .{ .name = name, .action = if (unlink) .unlink else .status };
    if (unlink) return error.TooManyArguments;
    // Only a SOURCE path is an override. A version here would be a second,
    // uncommitted pin competing with the committed one — the pin in
    // project.labelle is the one place a plugin's release is chosen.
    if (!config.isLocalVersion(rest[1])) return error.NotALocalSpec;
    return .{ .name = name, .action = .{ .link = rest[1] } };
}

/// The `.plugins` entry named `name`.
pub fn findPlugin(cfg: config.ProjectConfig, name: []const u8) ?config.PluginDep {
    for (cfg.plugins) |p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

/// Link `spec` (`local:<path>`) into `plugin`'s reserved local slot as an
/// EXPLICIT override. Returns the resolved source; caller owns it.
pub fn addOverride(
    allocator: std.mem.Allocator,
    plugin: config.PluginDep,
    spec: []const u8,
    project_root: ?[]const u8,
) ![]const u8 {
    // A `local:`/`@` pin already resolves straight to its path and never
    // consults a slot, so an override would be silently ignored.
    if (plugin.isLocal()) return error.PluginAlreadyLocal;
    // An invalid `.subdir` makes `resolvePlugin` fail before it ever reaches
    // the slot, so an override installed for it could never be used: refuse
    // (and say why) before writing anything (Codex review).
    if (cache.pluginSubdir.problem(plugin) != null) return error.InvalidPluginSubdir;

    const source = try cache.resolveLocalSource(allocator, spec, project_root);
    errdefer allocator.free(source);

    if (!cache.isDirectory(source)) return error.LocalSourceNotFound;
    const zon = try std.fs.path.join(allocator, &.{ source, "build.zig.zon" });
    defer allocator.free(zon);
    if (!local.pathExists(zon)) return error.NotAPluginCheckout;

    const declared = cache.declaredZonVersion(allocator, source);
    defer if (declared) |d| allocator.free(d);

    try cache.populatePluginMode(allocator, plugin, source, declared orelse "unknown", .explicit);
    return source;
}

/// The checkout an EXPLICIT override registered for `plugin`, if one is
/// registered and its source is still on disk. Caller owns the result.
pub fn explicitSource(allocator: std.mem.Allocator, plugin: config.PluginDep) !?[]const u8 {
    const slot = try local.pluginSlot(allocator, plugin);
    defer allocator.free(slot);
    const origin = local.readOrigin(allocator, slot) orelse return null;
    defer origin.deinit(allocator);
    if (origin.mode != .explicit) return null;
    if (!local.pathExists(slot) or !local.pathExists(origin.source)) return null;
    return try allocator.dupe(u8, origin.source);
}

/// Honour an explicit override for `plugin` from the populate side,
/// returning whether one is registered (the caller must then neither fetch
/// nor auto-discover: both would write over, or around, the path the user
/// typed). A slot the platform COPIED rather than linked (Windows without
/// symlink rights, where junctions also failed) is a snapshot, so it is
/// re-copied — same reasoning as `refreshExplicitLocalSlot` for frameworks.
pub fn refreshExplicit(allocator: std.mem.Allocator, plugin: config.PluginDep) !bool {
    const slot = try local.pluginSlot(allocator, plugin);
    defer allocator.free(slot);
    const origin = local.readOrigin(allocator, slot) orelse return false;
    defer origin.deinit(allocator);
    if (origin.mode != .explicit) return false;
    if (!local.pathExists(origin.source)) return false;
    if (local.pathExists(slot) and local.slotTracksSource(slot)) return true;
    try cache.populatePluginMode(allocator, plugin, origin.source, origin.pinned, .explicit);
    return true;
}

/// Drop `plugin`'s EXPLICIT override — slot and marker. Returns whether
/// there was one. A `.discovered` slot (monorepo auto-discovery) shares the
/// path but is not an override, so it is left alone: removing it would
/// silently switch a monorepo build to the release, or be recreated on the
/// next install (Codex review). Never recurses into the checkout: a link
/// entry is removed as a link (a junction via `deleteTree`, which drops the
/// reparse point itself — #710), a copied slot as the copy it is.
pub fn removeOverride(allocator: std.mem.Allocator, plugin: config.PluginDep) !bool {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    const slot = try local.pluginSlot(allocator, plugin);
    defer allocator.free(slot);
    const marker = try local.originPath(allocator, slot);
    defer allocator.free(marker);

    const origin = local.readOrigin(allocator, slot) orelse return false;
    const explicit = origin.mode == .explicit;
    origin.deinit(allocator);
    if (!explicit) return false;

    var removed = false;
    if (local.pathExists(slot) or local.isSymlinkPath(slot)) {
        cwd.deleteFile(io, slot) catch try cwd.deleteTree(io, slot);
        removed = true;
    }
    if (local.pathExists(marker)) {
        try cwd.deleteFile(io, marker);
        removed = true;
    }
    return removed;
}

/// Run `install plugin …` against an already-parsed project. Logs and
/// returns the error; `cache_cmd` owns the exit code.
pub fn run(
    allocator: std.mem.Allocator,
    cfg: config.ProjectConfig,
    rest: []const []const u8,
    unlink_flag: bool,
    project_root: ?[]const u8,
) !void {
    const parsed = parseAction(rest, unlink_flag) catch |err| {
        switch (err) {
            error.NotALocalSpec => std.log.err(
                "labelle-assembler install plugin: '{s}' is not a 'local:<path>' — the release a plugin " ++
                    "builds is chosen by its pin in project.labelle; an override only names a checkout",
                .{rest[1]},
            ),
            else => std.log.err(
                "labelle-assembler install plugin: expected 'install plugin <name> local:<path>', " ++
                    "'install plugin <name>' or 'install plugin <name> --unlink'",
                .{},
            ),
        }
        return err;
    };

    const plugin = findPlugin(cfg, parsed.name) orelse {
        std.log.err("labelle-assembler install plugin: project.labelle declares no plugin named '{s}'", .{parsed.name});
        if (cfg.plugins.len > 0) {
            std.log.err("  declared plugins:", .{});
            for (cfg.plugins) |p| std.log.err("    {s}", .{p.name});
        }
        return error.UnknownPlugin;
    };

    switch (parsed.action) {
        .status => {
            if (try explicitSource(allocator, plugin)) |src| {
                defer allocator.free(src);
                std.log.info("  plugin {s}: LOCAL override → '{s}' (instead of {s} {s})", .{ plugin.name, src, plugin.repo, plugin.version });
            } else if (plugin.isLocal()) {
                std.log.info("  plugin {s}: pinned to the local path '{s}' in project.labelle", .{ plugin.name, plugin.repo });
            } else {
                std.log.info("  plugin {s}: no local override — builds the pinned {s} {s}", .{ plugin.name, plugin.repo, plugin.version });
            }
        },
        .unlink => {
            if (try removeOverride(allocator, plugin)) {
                std.log.info("  plugin {s}: local override removed — the next build uses the pinned {s} {s}", .{ plugin.name, plugin.repo, plugin.version });
            } else {
                std.log.info("  plugin {s}: no local override to remove", .{plugin.name});
            }
        },
        .link => |spec| {
            const source = addOverride(allocator, plugin, spec, project_root) catch |err| {
                switch (err) {
                    // Logs the reason, naming the plugin.
                    error.InvalidPluginSubdir => cache.pluginSubdir.validate(plugin) catch {},
                    error.PluginAlreadyLocal => std.log.err(
                        "labelle-assembler install plugin: '{s}' is already pinned to the local path '{s}' in project.labelle — an override would never be consulted",
                        .{ plugin.name, plugin.repo },
                    ),
                    error.LocalSourceNotFound => std.log.err(
                        "labelle-assembler install plugin: not a directory: '{s}'",
                        .{config.localVersionPath(spec)},
                    ),
                    error.NotAPluginCheckout => std.log.err(
                        "labelle-assembler install plugin: '{s}' has no build.zig.zon — point it at the plugin directory itself{s}",
                        .{ config.localVersionPath(spec), if (plugin.subdir.len > 0) " (the pin's '.subdir' is NOT re-applied to an override)" else "" },
                    ),
                    else => std.log.err("labelle-assembler install plugin: could not link '{s}': {s}", .{ spec, @errorName(err) }),
                }
                return err;
            };
            defer allocator.free(source);
            std.log.warn(
                "  plugin {s}: LOCAL sources from '{s}' will be built instead of the pinned {s} {s} — " ++
                    "run 'labelle-assembler install plugin {s} --unlink' to go back",
                .{ plugin.name, source, plugin.repo, plugin.version, plugin.name },
            );
        },
    }
}

// ── Tests ────────────────────────────────────────────────────────────

test "install plugin: argument contract" {
    const a = try parseAction(&.{ "debug", "local:../x" }, false);
    try std.testing.expectEqualStrings("debug", a.name);
    try std.testing.expectEqualStrings("local:../x", a.action.link);
    try std.testing.expect((try parseAction(&.{"debug"}, false)).action == .status);
    try std.testing.expect((try parseAction(&.{"debug"}, true)).action == .unlink);
    try std.testing.expectError(error.NotALocalSpec, parseAction(&.{ "debug", "1.2.3" }, false));
    try std.testing.expectError(error.TooManyArguments, parseAction(&.{ "debug", "local:x" }, true));
    try std.testing.expectError(error.TooManyArguments, parseAction(&.{ "a", "b", "c" }, false));
    try std.testing.expectError(error.MissingPluginName, parseAction(&.{}, false));
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    home: []const u8,
    checkout: []const u8,

    fn init(alloc: std.mem.Allocator) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(std.testing.io, "home/packages");
        try tmp.dir.createDirPath(std.testing.io, "checkout/src");
        try tmp.dir.writeFile(std.testing.io, .{
            .sub_path = "checkout/build.zig.zon",
            .data = ".{ .name = .labelle_debug, .version = \"9.9.9\", .paths = .{\"\"} }\n",
        });
        const home = try realPath(&tmp, "home", alloc);
        errdefer alloc.free(home);
        const checkout = try realPath(&tmp, "checkout", alloc);
        env_setup(home, home);
        return .{ .tmp = tmp, .home = home, .checkout = checkout };
    }

    /// Plain-slice copy: the fixture stores `[]const u8`, and freeing a
    /// `[:0]u8` through that type would drop the sentinel byte.
    fn realPath(tmp: *std.testing.TmpDir, sub: []const u8, alloc: std.mem.Allocator) ![]const u8 {
        const z = try tmp.dir.realPathFileAlloc(std.testing.io, sub, alloc);
        defer alloc.free(z);
        return alloc.dupe(u8, z);
    }

    fn env_setup(home: ?[]const u8, probe: ?[]const u8) void {
        cache.cacheEnv.setCacheRootForTesting(home);
        // Probe from inside the fixture, where no `labelle-core` sibling
        // exists: auto-discovery is OFF, as for a released binary.
        local.setProbeStartForTesting(probe);
    }

    fn deinit(self: *Fixture, alloc: std.mem.Allocator) void {
        env_setup(null, null);
        alloc.free(self.home);
        alloc.free(self.checkout);
        self.tmp.cleanup();
    }
};

const debug_pin: config.PluginDep = .{
    .name = "debug",
    .repo = "github.com/labelle-toolkit/labelle-assembler",
    .version = "0.118.0",
    .subdir = "plugins/debug",
};

test "install plugin: link makes resolvePlugin take the EXPLICIT slot, unlink goes back to the pinned subdir" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    // Before: the pin resolves inside the cached release archive.
    const pinned_path = try cache.resolvePlugin(alloc, debug_pin, null);
    defer alloc.free(pinned_path);
    const archive = try cache.pluginVersionPath(alloc, debug_pin);
    defer alloc.free(archive);
    const expected_pinned = try std.fs.path.join(alloc, &.{ archive, "plugins/debug" });
    defer alloc.free(expected_pinned);
    try std.testing.expectEqualStrings(expected_pinned, pinned_path);
    try std.testing.expect(try explicitSource(alloc, debug_pin) == null);

    const spec = try std.fmt.allocPrint(alloc, "local:{s}", .{fx.checkout});
    defer alloc.free(spec);
    const src = try addOverride(alloc, debug_pin, spec, null);
    defer alloc.free(src);

    // The mechanism: an `.explicit` marker on the reserved plugin slot, which
    // is what lets a RELEASED binary (no monorepo, probe finds nothing)
    // resolve through it.
    const slot = try local.pluginSlot(alloc, debug_pin);
    defer alloc.free(slot);
    const origin = local.readOrigin(alloc, slot) orelse return error.TestUnexpectedResult;
    defer origin.deinit(alloc);
    try std.testing.expectEqual(local.Origin.Mode.explicit, origin.mode);
    try std.testing.expectEqualStrings("9.9.9", origin.pinned);

    // resolvePlugin returns the slot itself — the subdir is NOT re-applied.
    const overridden = try cache.resolvePlugin(alloc, debug_pin, null);
    defer alloc.free(overridden);
    try std.testing.expectEqualStrings(slot, overridden);
    try std.testing.expect(cache.isLocalSlotPath(alloc, overridden));
    // The build sees the checkout's files through the slot.
    const through = try std.fs.path.join(alloc, &.{ overridden, "build.zig.zon" });
    defer alloc.free(through);
    try std.testing.expect(local.pathExists(through));
    // Populate side: an explicit override is honoured, not fetched over.
    try std.testing.expect(try refreshExplicit(alloc, debug_pin));

    const src_now = (try explicitSource(alloc, debug_pin)) orelse return error.TestUnexpectedResult;
    defer alloc.free(src_now);

    // Back again.
    try std.testing.expect(try removeOverride(alloc, debug_pin));
    try std.testing.expect(!try removeOverride(alloc, debug_pin));
    const after = try cache.resolvePlugin(alloc, debug_pin, null);
    defer alloc.free(after);
    try std.testing.expectEqualStrings(expected_pinned, after);
    try std.testing.expect(!try refreshExplicit(alloc, debug_pin));
    // Unlinking dropped the LINK, never the checkout behind it.
    const kept = try std.fs.path.join(alloc, &.{ fx.checkout, "build.zig.zon" });
    defer alloc.free(kept);
    try std.testing.expect(local.pathExists(kept));
}

test "install plugin: --unlink leaves a DISCOVERED slot alone" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    try cache.populatePluginMode(alloc, debug_pin, fx.checkout, "0.118.0", .discovered);
    try std.testing.expect(!try removeOverride(alloc, debug_pin));
    const slot = try local.pluginSlot(alloc, debug_pin);
    defer alloc.free(slot);
    const origin = local.readOrigin(alloc, slot) orelse return error.TestUnexpectedResult;
    defer origin.deinit(alloc);
    try std.testing.expectEqual(local.Origin.Mode.discovered, origin.mode);
    try std.testing.expect(local.pathExists(slot));
}

test "install plugin: an override for one plugin leaves every other pin on its release" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    const fsm: config.PluginDep = .{ .name = "fsm", .repo = "github.com/labelle-toolkit/labelle-fsm", .version = "0.5.0" };
    const spec = try std.fmt.allocPrint(alloc, "local:{s}", .{fx.checkout});
    defer alloc.free(spec);
    const src = try addOverride(alloc, debug_pin, spec, null);
    defer alloc.free(src);

    const fsm_path = try cache.resolvePlugin(alloc, fsm, null);
    defer alloc.free(fsm_path);
    try std.testing.expect(!cache.isLocalSlotPath(alloc, fsm_path));
    try std.testing.expect(try explicitSource(alloc, fsm) == null);
}

test "install plugin: rejects local pins, missing dirs and non-plugin dirs" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    var bad_subdir = debug_pin;
    bad_subdir.subdir = "../plugin";
    const ok_spec = try std.fmt.allocPrint(alloc, "local:{s}", .{fx.checkout});
    defer alloc.free(ok_spec);
    try std.testing.expectError(error.InvalidPluginSubdir, addOverride(alloc, bad_subdir, ok_spec, null));
    try std.testing.expect(try explicitSource(alloc, bad_subdir) == null);

    const local_pin: config.PluginDep = .{ .name = "caretaker", .repo = "@libs/caretaker" };
    try std.testing.expectError(error.PluginAlreadyLocal, addOverride(alloc, local_pin, "local:x", null));

    const missing = try std.fmt.allocPrint(alloc, "local:{s}/nope", .{fx.home});
    defer alloc.free(missing);
    try std.testing.expectError(error.LocalSourceNotFound, addOverride(alloc, debug_pin, missing, null));

    // A directory without build.zig.zon — e.g. the monorepo ROOT of a
    // `.subdir` pin instead of the plugin directory inside it.
    const not_plugin = try std.fmt.allocPrint(alloc, "local:{s}/src", .{fx.checkout});
    defer alloc.free(not_plugin);
    try std.testing.expectError(error.NotAPluginCheckout, addOverride(alloc, debug_pin, not_plugin, null));
    try std.testing.expect(try explicitSource(alloc, debug_pin) == null);
}

test "install plugin: an override whose checkout was deleted falls back to the pin" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    try fx.tmp.dir.createDirPath(std.testing.io, "gone");
    try fx.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "gone/build.zig.zon", .data = ".{ .version = \"1.0.0\" }\n" });
    const gone = try fx.tmp.dir.realPathFileAlloc(std.testing.io, "gone", alloc);
    defer alloc.free(gone);
    const spec = try std.fmt.allocPrint(alloc, "local:{s}", .{gone});
    defer alloc.free(spec);
    const src = try addOverride(alloc, debug_pin, spec, null);
    defer alloc.free(src);

    try fx.tmp.dir.deleteTree(std.testing.io, "gone");
    try std.testing.expect(try explicitSource(alloc, debug_pin) == null);
    try std.testing.expect(!try refreshExplicit(alloc, debug_pin));
    const path = try cache.resolvePlugin(alloc, debug_pin, null);
    defer alloc.free(path);
    try std.testing.expect(!cache.isLocalSlotPath(alloc, path));
}
