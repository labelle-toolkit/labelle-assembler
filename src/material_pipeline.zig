//! Discover game-owned materials, validate before emission, stage build support.
const std = @import("std");
const config = @import("config.zig");
const scanner = @import("scanner.zig");
pub const schema = @import("material_schema.zig");
/// Whether the selected backend can consume game-owned `.sc` materials.
///
/// Keyed off the `.bgfx` ENUM TAG, never `backendName()` (PR #733 review,
/// same reasoning as `ProjectConfig.effectiveGamepad`): the name is the
/// resolved PACKAGE name, which a `.backend = .bgfx` project can override to
/// anything (`.backend_package = .{ .name = "bgfx_v2", .. }` — the in-tree v2
/// fixture — or a fork named `labelle-bgfx`). A literal `"bgfx"` string match
/// rejected every such compatible provider with `UnsupportedMaterialBackend`.
/// The tag survives the enum-as-shorthand resolution, so it is the reliable
/// "is bgfx" signal. `.null` is accepted because the tests target
/// (`testsTargetConfig`) force-substitutes it while the game still ships the
/// materials module.
///
/// LIMITATION (documented, like `effectiveGamepad`): a third-party bgfx-shaped
/// provider selected purely via `.backend_package` with `.backend` left at its
/// `.raylib` default is rejected; declare `.backend = .bgfx` alongside the
/// package. There is no material capability in the provider manifest yet.
pub fn requireBackend(cfg: config.ProjectConfig) error{UnsupportedMaterialBackend}!void {
    switch (cfg.backend) {
        .bgfx, .null => {},
        else => return error.UnsupportedMaterialBackend,
    }
}
/// The first labelle-bgfx release that implements material contract v2
/// (what `material_build.zig`'s generated module `@compileError`s without),
/// and the first labelle-core that declares it. Both pins must be at least
/// these for a project that owns `materials/`.
pub const min_bgfx_for_materials = "0.21.0";
pub const min_core_for_materials = "2.0.0";

pub const ContractError = error{ MaterialContractUnsupported, UnparsableVersionPin };

/// Reject, at GENERATE time, a project that owns materials but pins a
/// backend or core release that predates material contract v2 (PR #733 P1,
/// the "reject incompatible release pins" half). With the defaults
/// (`builtinProvider` bgfx 0.21.0 + the core 2.0.0 scaffold trio) this is
/// unreachable; an EXPLICIT `.backend_package` / `.core_version` that pins
/// an older release used to generate successfully and always fail at the
/// generated module's `@compileError` — a deep compile break instead of a
/// diagnostic naming the pin. Only release-shaped (semver) pins are
/// judged: a `local:…` checkout is resolved elsewhere and left alone. The
/// general generate-time floor check is labelle-assembler#739; this is the
/// materials-specific gate only.
///
/// Returns the offending side so the caller can name it; the tests target
/// (`.backend = .null`) is skipped like `requireBackend` skips it.
pub const ContractViolation = struct { what: []const u8, pinned: []const u8, floor: []const u8 };
pub fn contractViolation(cfg: config.ProjectConfig) error{UnparsableVersionPin}!?ContractViolation {
    if (cfg.backend != .bgfx) return null;
    if (cfg.effectiveBackendPackage()) |bp| {
        // The 0.21.0 floor is a fact about the OFFICIAL labelle-bgfx release
        // train only. A custom provider (`.backend_package` on another repo)
        // carries its OWN semver — comparing e.g. acme/bgfx 0.1.0 against
        // 0.21.0 would reject a contract-v2-capable provider as an obsolete
        // labelle-bgfx (#733 review, round 3). Such a provider is validated
        // by the generated module's `MATERIAL_CONTRACT_VERSION == 2` guard,
        // which covers arbitrary providers.
        if (isOfficialBgfx(bp) and config.isSemverVersion(bp.version) and !try config.pinAtLeast(bp.version, min_bgfx_for_materials))
            return .{ .what = "labelle-bgfx", .pinned = bp.version, .floor = min_bgfx_for_materials };
    }
    if (config.isSemverVersion(cfg.core_version) and !try config.pinAtLeast(cfg.core_version, min_core_for_materials))
        return .{ .what = "labelle-core", .pinned = cfg.core_version, .floor = min_core_for_materials };
    return null;
}
/// The resolved provider IS the official labelle-bgfx release train: the
/// builtin provider's repo (the enum-as-shorthand default, or an explicit
/// `.backend_package` that pins that same repo). Keyed off the REPO, never
/// the package name — the name is configurable (`requireBackend`).
///
/// Compared through `config.sameRemote`, never `std.mem.eql` (#742):
/// `parseProjectConfig` keeps `PluginDep.repo` verbatim and the fetch path
/// clones `github.com/labelle-toolkit/labelle-bgfx`,
/// `https://github.com/…/labelle-bgfx` and `….git` alike — so a raw string
/// compare classified those spellings of the OFFICIAL repo as a custom
/// provider, skipped `contractViolation`, and let an old pin fail at the
/// generated `MATERIAL_CONTRACT_VERSION` guard instead of at generate with
/// the pin named.
pub fn isOfficialBgfx(bp: config.PluginDep) bool {
    const official = config.ProjectConfig.builtinProvider(.bgfx) orelse return false;
    return config.sameRemote(bp.repo, official.repo);
}

test "isOfficialBgfx accepts every spelling of the official repo, rejects a custom provider — #742" {
    const official = config.ProjectConfig.builtinProvider(.bgfx) orelse return error.TestUnexpectedResult;
    // The `https://` and `.git` spellings the fetch path accepts are the
    // OFFICIAL train, so the materials floor gate judges them.
    inline for (.{
        "github.com/labelle-toolkit/labelle-bgfx",
        "https://github.com/labelle-toolkit/labelle-bgfx",
        "https://github.com/labelle-toolkit/labelle-bgfx.git",
        "github.com/labelle-toolkit/labelle-bgfx.git",
    }) |spelling| {
        try std.testing.expect(isOfficialBgfx(.{ .name = "bgfx", .repo = spelling, .version = "0.20.0" }));
    }
    try std.testing.expect(isOfficialBgfx(official));

    // A genuinely custom provider carries its own semver and stays custom —
    // the generated module's contract guard covers it instead.
    inline for (.{
        "github.com/acme/labelle-bgfx",
        "https://github.com/acme/labelle-bgfx.git",
        "local:../labelle-bgfx",
    }) |custom| {
        try std.testing.expect(!isOfficialBgfx(.{ .name = "bgfx", .repo = custom, .version = "0.1.0" }));
    }
}

test "contractViolation names an OLD official bgfx pinned with the `https://…/.git` spelling — #742" {
    // BEFORE: the raw-string compare made this a custom provider, the gate
    // returned null, and the project failed at the generated
    // `MATERIAL_CONTRACT_VERSION == 2` guard deep inside the build.
    const cfg: config.ProjectConfig = .{
        .name = "g",
        .backend = .bgfx,
        .backend_package = .{ .name = "bgfx", .repo = "https://github.com/labelle-toolkit/labelle-bgfx.git", .version = "0.20.0" },
        .core_version = "2.0.0",
        .engine_version = "3.0.0",
        .gfx_version = "2.0.0",
    };
    const v = (try contractViolation(cfg)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("labelle-bgfx", v.what);
    try std.testing.expectEqualStrings("0.20.0", v.pinned);
    try std.testing.expectEqualStrings(min_bgfx_for_materials, v.floor);
    try std.testing.expectError(error.MaterialContractUnsupported, requireContract(cfg));

    // A contract-v2 pin in the same spelling is still accepted (the fix
    // normalizes the spelling; it does not reject the repo).
    var ok = cfg;
    ok.backend_package = .{ .name = "bgfx", .repo = "https://github.com/labelle-toolkit/labelle-bgfx.git", .version = min_bgfx_for_materials };
    try std.testing.expect((try contractViolation(ok)) == null);

    // A CUSTOM provider on its own semver is still left to the generated
    // guard — the normalization must not widen the gate.
    var custom = cfg;
    custom.backend_package = .{ .name = "bgfx", .repo = "github.com/acme/bgfx-provider", .version = "0.1.0" };
    try std.testing.expect((try contractViolation(custom)) == null);
}
pub fn requireContract(cfg: config.ProjectConfig) ContractError!void {
    if (try contractViolation(cfg)) |_| return error.MaterialContractUnsupported;
}
pub fn stage(a: std.mem.Allocator, game_dir: []const u8, target_dir: []const u8, cfg: config.ProjectConfig) ![][]const u8 {
    const io = config.globalIo();
    const root = try std.fs.path.join(a, &.{ game_dir, "materials" });
    defer a.free(root);
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return a.alloc([]const u8, 0),
        else => return err,
    };
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |n| a.free(n);
        names.deinit(a);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory or entry.name[0] == '.') continue;
        const rel = try std.fs.path.join(a, &.{ entry.name, "material.json" });
        defer a.free(rel);
        const bytes = dir.readFileAlloc(io, rel, a, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer a.free(bytes);
        if (!schema.materialName(entry.name)) {
            std.log.err("materials/{s}: expected identifier directory name (max 63 bytes; generated-symbol names are reserved)", .{entry.name});
            return error.InvalidMaterialName;
        }
        for (names.items) |n| if (std.ascii.eqlIgnoreCase(n, entry.name)) {
            // Case-insensitive: the generated module exports one Zig decl per
            // folder, and a case-only difference collides on the many hosts
            // whose filesystems fold case.
            std.log.err("materials/{s}: collides with materials/{s} (material folder names must be unique ignoring case)", .{ entry.name, n });
            return error.DuplicateMaterialName;
        };
        const parsed = schema.parse(a, bytes) catch |err| {
            std.log.err("materials/{s}: {s}", .{ rel, @errorName(err) });
            return err;
        };
        defer parsed.deinit();
        const fragment = try std.fs.path.join(a, &.{ entry.name, parsed.value.fragment });
        defer a.free(fragment);
        dir.access(io, fragment, .{}) catch |err| {
            std.log.err("materials/{s}: fragment '{s}' unavailable ({s})", .{ rel, parsed.value.fragment, @errorName(err) });
            return error.MissingMaterialFragment;
        };
        const name = try a.dupe(u8, entry.name);
        errdefer a.free(name);
        try names.append(a, name);
    }
    if (names.items.len != 0) {
        requireBackend(cfg) catch |err| {
            std.log.err("game-owned .sc materials require bgfx (selected backend: {s})", .{cfg.backendName()});
            return err;
        };
        if (try contractViolation(cfg)) |v| {
            std.log.err("materials/: game-owned materials require material contract v2 (labelle-bgfx >= {s} on labelle-core >= {s}); project pins {s} {s}. Bump the pin, or drop it to take the default.", .{ min_bgfx_for_materials, min_core_for_materials, v.what, v.pinned });
            return error.MaterialContractUnsupported;
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.less);
        try scanner.linkDir(a, game_dir, target_dir, "materials");
        try scanner.writeFile(target_dir, "material_build.zig", @embedFile("material_build.zig"));
        try scanner.writeFile(target_dir, "material_schema.zig", @embedFile("material_schema.zig"));
    }
    return names.toOwnedSlice(a);
}
pub fn emit(w: *std.Io.Writer, names: []const []const u8, platform: []const u8) !void {
    if (names.len == 0) return;
    try w.writeAll("    const materials_mod = @import(\"material_build.zig\").create(b, target, optimize, core_mod, &.{\n");
    for (names) |name| try w.print("        .{{ .name = \"{s}\", .json = @embedFile(\"materials/{s}/material.json\") }},\n", .{ name, name });
    try w.print("    }}, \"{s}\");\n    overrideImport(game_mod, \"materials\", materials_mod);\n", .{platform});
}
pub fn emitImport(w: *std.Io.Writer, names: []const []const u8, artifact: []const u8) !void {
    if (names.len != 0) try w.print("    {s}.root_module.addImport(\"materials\", materials_mod);\n", .{artifact});
}

test "materials build emission has explicit embedded descriptors and empty no-op" {
    _ = schema;
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try emit(&out.writer, &.{}, "desktop");
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
    try emit(&out.writer, &.{ "fog", "lamp" }, "desktop");
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "materials/fog/material.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "materials/lamp/material.json") != null);
}

test "requireBackend: keyed off the .bgfx enum tag, not the resolved package name (#733 P2)" {
    // A `.backend = .bgfx` project whose provider package is NOT literally named
    // "bgfx" — the in-tree v2 fixture spelling this repo itself uses — must be
    // accepted: the tag is the identity, the name is configurable.
    try requireBackend(.{
        .name = "g",
        .backend = .bgfx,
        .backend_package = .{ .name = "bgfx_v2", .repo = "local:backends/bgfx_v2" },
    });
    // Plain enum-as-shorthand default and the tests-target `.null` substitution.
    try requireBackend(.{ .name = "g", .backend = .bgfx });
    try requireBackend(.{ .name = "g", .backend = .null });
    // A non-bgfx backend is still rejected — including one whose PACKAGE is
    // named "bgfx" (the name must not be the signal in either direction).
    try std.testing.expectError(error.UnsupportedMaterialBackend, requireBackend(.{ .name = "g", .backend = .sokol }));
    try std.testing.expectError(error.UnsupportedMaterialBackend, requireBackend(.{
        .name = "g",
        .backend = .sokol,
        .backend_package = .{ .name = "bgfx", .repo = "local:backends/bgfx_v2" },
    }));
}

test "contractViolation: an explicit pre-contract-v2 bgfx or core pin is rejected at generate time; defaults and local pins pass (#733 P1)" {
    // The defaults: builtinProvider bgfx + the scaffold core — unreachable.
    try std.testing.expect((try contractViolation(.{ .name = "g", .backend = .bgfx })) == null);
    try requireContract(.{ .name = "g", .backend = .bgfx });
    // An explicit OLD backend pin (what material-demo / pack-city carry) with
    // materials/ → named, not a deep @compileError.
    const old_bgfx = try contractViolation(.{
        .name = "g",
        .backend = .bgfx,
        .backend_package = .{ .name = "bgfx", .repo = "github.com/labelle-toolkit/labelle-bgfx", .version = "0.20.0" },
        .core_version = "2.0.0",
    }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("labelle-bgfx", old_bgfx.what);
    try std.testing.expectEqualStrings("0.20.0", old_bgfx.pinned);
    try std.testing.expectEqualStrings("0.21.0", old_bgfx.floor);
    // An explicit OLD core under a new backend.
    const old_core = try contractViolation(.{
        .name = "g",
        .backend = .bgfx,
        .backend_package = .{ .name = "bgfx", .repo = "github.com/labelle-toolkit/labelle-bgfx", .version = "0.21.0" },
        .core_version = "1.32.0",
    }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("labelle-core", old_core.what);
    try std.testing.expectEqualStrings("1.32.0", old_core.pinned);
    try std.testing.expectError(error.MaterialContractUnsupported, requireContract(.{ .name = "g", .backend = .bgfx, .core_version = "1.32.0" }));
    // The released pair, and anything newer, passes; an abbreviated pin too.
    try requireContract(.{
        .name = "g",
        .backend = .bgfx,
        .backend_package = .{ .name = "bgfx", .repo = "github.com/labelle-toolkit/labelle-bgfx", .version = "0.21.0" },
        .core_version = "2.0.0",
    });
    try requireContract(.{ .name = "g", .backend = .bgfx, .core_version = "2.1" });
    // Non-release pins are resolved elsewhere — not judged here.
    try requireContract(.{
        .name = "g",
        .backend = .bgfx,
        .backend_package = .{ .name = "bgfx", .repo = "local:../labelle-bgfx", .version = "local:../labelle-bgfx" },
        .core_version = "local:../labelle-core",
    });
    // The tests target substitutes `.null`; other backends are `requireBackend`'s business.
    try requireContract(.{ .name = "g", .backend = .null, .core_version = "1.26.0" });
    try requireContract(.{ .name = "g", .backend = .sokol, .core_version = "1.26.0" });
    // A dotted-but-unparsable pin surfaces as the named error, not a crash.
    try std.testing.expectError(error.UnparsableVersionPin, requireContract(.{ .name = "g", .backend = .bgfx, .core_version = "1.2.3.4" }));
}

test "contractViolation: the 0.21.0 floor applies to the OFFICIAL labelle-bgfx only — a custom provider's own semver is not judged (#733 round 3)" {
    // A compatible custom provider with its own version line, selected by a
    // `.backend = .bgfx` project: ACCEPTED at generate (the generated
    // MATERIAL_CONTRACT_VERSION guard validates it instead).
    try requireContract(.{
        .name = "g",
        .backend = .bgfx,
        .backend_package = .{ .name = "bgfx_v2", .repo = "github.com/acme/bgfx", .version = "0.1.0" },
        .core_version = "2.0.0",
    });
    try std.testing.expect(!isOfficialBgfx(.{ .name = "bgfx_v2", .repo = "github.com/acme/bgfx", .version = "0.1.0" }));
    // The official train, pinned explicitly or via the default, is judged:
    // 0.20.0 still rejected, whatever the package is CALLED.
    try std.testing.expect(isOfficialBgfx(config.ProjectConfig.builtinProvider(.bgfx).?));
    const v = (try contractViolation(.{
        .name = "g",
        .backend = .bgfx,
        .backend_package = .{ .name = "bgfx_v2", .repo = "github.com/labelle-toolkit/labelle-bgfx", .version = "0.20.0" },
        .core_version = "2.0.0",
    })) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("labelle-bgfx", v.what);
    try std.testing.expectEqualStrings("0.20.0", v.pinned);
    // The core floor is about labelle-core itself and still applies under a
    // custom provider.
    try std.testing.expectError(error.MaterialContractUnsupported, requireContract(.{
        .name = "g",
        .backend = .bgfx,
        .backend_package = .{ .name = "bgfx_v2", .repo = "github.com/acme/bgfx", .version = "0.1.0" },
        .core_version = "1.32.0",
    }));
}
