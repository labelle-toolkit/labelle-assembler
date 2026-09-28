//! Assembler-provided plugin build options (labelle-assembler#776).
//!
//! Some options only the assembler knows the value of are handed to a
//! plugin's `b.dependency("labelle_<name>", .{ ... })` in the generated
//! build.zig. Today there is one: `ios_sdk_path`, the iOS SDK root a plugin
//! that compiles C needs for system headers (labelle-box2d adds
//! `<sdk>/usr/include`).
//!
//! Zig refuses a `-D` option the dependency's `build.zig` does not declare
//! ("invalid option"), so an option may only be passed to a plugin that
//! takes it. Passing `ios_sdk_path` to EVERY plugin on an iOS generate broke
//! every plugin that does not declare it (#776). A plugin opts in in one of
//! two ways:
//!
//!   1. **Manifest (the contract):** `plugin.labelle` lists it —
//!      `.build_options = .{ "ios_sdk_path" }`. Validated at manifest load
//!      against `provided` (an unknown name fails loudly).
//!   2. **Detection (back-compat):** the plugin's own `build.zig` contains
//!      the string literal `"ios_sdk_path"` — the name argument of its
//!      `b.option(...)` call. This keeps plugins that already declare the
//!      option (labelle-box2d, labelle-box2d-physctl, labelle-ios) receiving
//!      it with no manifest change. The scan uses the Zig tokenizer, so a
//!      comment mentioning the name does not count. A plugin that declares
//!      the option indirectly (e.g. a name built at comptime, or in an
//!      imported file) must use the manifest key.
//!
//! A plugin with neither gets no `ios_sdk_path`, and its iOS build no longer
//! fails on an unknown option.

const std = @import("std");
const config = @import("config.zig");
const cache = @import("cache.zig");
const plugin_manifest = @import("plugin_manifest.zig");

pub const ios_sdk_path = "ios_sdk_path";

/// Every option the assembler can supply to a plugin dependency.
pub const provided = [_][]const u8{ios_sdk_path};

/// `provided`, comma-separated, for diagnostics.
pub const provided_list = blk: {
    var out: []const u8 = "";
    for (provided, 0..) |p, i| out = out ++ (if (i == 0) "" else ", ") ++ p;
    break :blk out;
};

pub fn isProvided(name: []const u8) bool {
    for (provided) |p| if (std.mem.eql(u8, p, name)) return true;
    return false;
}

/// True when `source` (a `build.zig`) contains the string literal
/// `"<option>"` outside comments — the name argument of a
/// `b.option(T, "<option>", ...)` declaration.
pub fn buildZigMentionsOption(allocator: std.mem.Allocator, source: []const u8, option: []const u8) !bool {
    const z = try allocator.dupeZ(u8, source);
    defer allocator.free(z);
    var tokenizer = std.zig.Tokenizer.init(z);
    while (true) {
        const tok = tokenizer.next();
        switch (tok.tag) {
            .eof => return false,
            .string_literal => {
                const lit = z[tok.loc.start..tok.loc.end];
                if (lit.len == option.len + 2 and std.mem.eql(u8, lit[1 .. lit.len - 1], option)) return true;
            },
            else => {},
        }
    }
}

/// Whether the plugin in `plugin_dir` takes `option`: its manifest lists
/// it in `.build_options`, or its `build.zig` declares it.
pub fn pluginTakesOption(allocator: std.mem.Allocator, plugin_dir: []const u8, plugin_name: []const u8, option: []const u8) !bool {
    if (try plugin_manifest.loadFromDir(allocator, plugin_dir, plugin_name)) |m| {
        var manifest = m;
        defer manifest.deinit();
        for (manifest.build_options) |o| if (std.mem.eql(u8, o, option)) return true;
    }
    const build_zig = try std.fs.path.join(allocator, &.{ plugin_dir, "build.zig" });
    defer allocator.free(build_zig);
    const source = std.Io.Dir.cwd().readFileAlloc(config.globalIo(), build_zig, allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(source);
    return buildZigMentionsOption(allocator, source, option);
}

/// The names of `cfg.plugins` that take `option`. Caller frees the slice
/// (the names borrow from `cfg`).
pub fn pluginsTakingOption(allocator: std.mem.Allocator, cfg: config.ProjectConfig, project_dir: []const u8, option: []const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(allocator);
    for (cfg.plugins) |plugin| {
        const dir = try cache.resolvePlugin(allocator, plugin, project_dir);
        defer allocator.free(dir);
        if (try pluginTakesOption(allocator, dir, plugin.name, option)) try names.append(allocator, plugin.name);
    }
    return names.toOwnedSlice(allocator);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "buildZigMentionsOption: a b.option name literal counts; comments and other strings do not" {
    const a = testing.allocator;
    try testing.expect(try buildZigMentionsOption(a,
        \\const ios_sdk_path = b.option([]const u8, "ios_sdk_path", "iOS SDK path");
    , ios_sdk_path));
    try testing.expect(!try buildZigMentionsOption(a,
        \\// the assembler used to pass "ios_sdk_path" to every plugin
        \\const x = b.option(bool, "hot_reload", "ios_sdk_path is not taken");
    , ios_sdk_path));
    try testing.expect(!try buildZigMentionsOption(a, "const s = \"ios_sdk_path_v2\";", ios_sdk_path));
}

test "pluginTakesOption: manifest opt-in, build.zig detection, neither" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    defer a.free(root);

    // Manifest opt-in, build.zig silent on it.
    try tmp.dir.createDirPath(testing.io, "m");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "m/plugin.labelle", .data = ".{ .name = \"m\", .manifest_version = 1, .build_options = .{ \"ios_sdk_path\" } }" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "m/build.zig", .data = "pub fn build(b: *std.Build) void { _ = b; }" });
    // Detection only: no manifest.
    try tmp.dir.createDirPath(testing.io, "d");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "d/build.zig", .data = "_ = b.option([]const u8, \"ios_sdk_path\", \"sdk\");" });
    // Neither: a manifest without the key and a build.zig without the option.
    try tmp.dir.createDirPath(testing.io, "n");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "n/plugin.labelle", .data = ".{ .name = \"n\", .manifest_version = 1 }" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "n/build.zig", .data = "// no ios_sdk_path option here\n" });
    // No build.zig, no manifest.
    try tmp.dir.createDirPath(testing.io, "e");

    const join = std.fs.path.join;
    const m = try join(a, &.{ root, "m" });
    defer a.free(m);
    const d = try join(a, &.{ root, "d" });
    defer a.free(d);
    const n = try join(a, &.{ root, "n" });
    defer a.free(n);
    const e = try join(a, &.{ root, "e" });
    defer a.free(e);
    try testing.expect(try pluginTakesOption(a, m, "m", ios_sdk_path));
    try testing.expect(try pluginTakesOption(a, d, "d", ios_sdk_path));
    try testing.expect(!try pluginTakesOption(a, n, "n", ios_sdk_path));
    try testing.expect(!try pluginTakesOption(a, e, "e", ios_sdk_path));
}

test "plugin.labelle: an unknown .build_options entry fails the manifest load" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = testing.allocator;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "plugin.labelle", .data = ".{ .name = \"p\", .manifest_version = 1, .build_options = .{ \"ios_sdk_pth\" } }" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    defer a.free(root);
    try testing.expectError(error.PluginManifestUnknownBuildOption, plugin_manifest.loadFromDir(a, root, "p"));
}

test "pluginsTakingOption: resolves each .plugins entry and keeps only the takers" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    defer a.free(root);
    try tmp.dir.createDirPath(testing.io, "libs/box2d");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "libs/box2d/build.zig", .data = "const p = b.option([]const u8, \"ios_sdk_path\", \"sdk\");" });
    try tmp.dir.createDirPath(testing.io, "libs/fsm");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "libs/fsm/build.zig", .data = "pub fn build(b: *std.Build) void { _ = b; }" });
    try tmp.dir.createDirPath(testing.io, "libs/ios");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "libs/ios/plugin.labelle", .data = ".{ .name = \"ios\", .manifest_version = 2, .build_options = .{ \"ios_sdk_path\" } }" });

    const cfg: config.ProjectConfig = .{
        .name = "g",
        .plugins = &.{
            .{ .name = "fsm", .repo = "local:libs/fsm" },
            .{ .name = "box2d", .repo = "local:libs/box2d" },
            .{ .name = "ios", .repo = "local:libs/ios" },
        },
    };
    const names = try pluginsTakingOption(a, cfg, root, ios_sdk_path);
    defer a.free(names);
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("box2d", names[0]);
    try testing.expectEqualStrings("ios", names[1]);
}
