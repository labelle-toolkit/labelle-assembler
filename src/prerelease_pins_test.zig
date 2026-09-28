//! #783: pre-release / build-suffixed pins end to end — the fetch path, the
//! version gates and `upgrade backend` must agree on what such a pin is.
//!
//! * fetch: `1.2.3-rc.1` is the tag `v1.2.3-rc.1` (`config.versionToGitRef`,
//!   table-tested in `version_ref.zig`);
//! * gates (version floors, material toolchain/contract): every
//!   `isTagVersion` pin is compared, judged as its `MAJOR.MINOR.PATCH`
//!   (`config.parsePin`);
//! * `upgrade backend` writes it and reaches the same floor verdict
//!   `generate` does, because both call `version_floors.verdict`.
const std = @import("std");
const testing = std.testing;
const config = @import("config.zig");
const version_floors = @import("version_floors.zig");
const upgrade_backend = @import("upgrade_backend.zig");
const material_pipeline = @import("material_pipeline.zig");
const schema = @import("material_schema.zig");

test "parsePin: table — suffixed semver judged as MAJOR.MINOR.PATCH (#783)" {
    const Case = struct { pin: []const u8, want: []const u8 };
    const cases = [_]Case{
        .{ .pin = "0.31.0", .want = "0.31.0" },
        .{ .pin = "1.2", .want = "1.2.0" },
        .{ .pin = "0.31.0-rc.1", .want = "0.31.0" },
        .{ .pin = "0.31.0+b.5", .want = "0.31.0" },
        .{ .pin = "0.31.0-rc.1+b.5", .want = "0.31.0" },
    };
    for (cases) |c| {
        errdefer std.debug.print("pin '{s}'\n", .{c.pin});
        const v = try config.parsePin(c.pin);
        // Mechanism: the suffix is dropped, not merely ignored by `order`.
        try testing.expect(v.pre == null and v.build == null);
        var buf: [32]u8 = undefined;
        try testing.expectEqualStrings(c.want, try std.fmt.bufPrint(&buf, "{d}.{d}.{d}", .{ v.major, v.minor, v.patch }));
    }
    try testing.expect(try config.pinAtLeast("2.1.0-rc.1", "2.1.0"));
    try testing.expect(!try config.pinAtLeast("2.0.0+ci.5", "2.1.0"));
}

fn bgfxCfg(bgfx: []const u8, core: []const u8) config.ProjectConfig {
    return .{
        .name = "g",
        .backend = .bgfx,
        .core_version = core,
        .backend_package = .{ .name = "bgfx", .repo = "github.com/labelle-toolkit/labelle-bgfx", .version = bgfx },
    };
}

test "backend floor: suffixed pins on either side are compared as their release (#783)" {
    // bgfx >= 0.26.0 needs core >= 2.1.0 (compile break).
    const hit = (try version_floors.verdict(bgfxCfg("0.31.0-rc.1", "2.0.0"))).backend.?;
    try testing.expectEqual(version_floors.FloorSeverity.compile_break, hit.severity);
    try testing.expectEqualStrings("0.31.0-rc.1", hit.backend_version); // quoted as written
    try testing.expectEqualStrings("2.1.0", hit.core_floor);
    // Requirement side: build metadata below the floor is still below it...
    try testing.expectEqualStrings("2.0.0+ci.5", (try version_floors.verdict(bgfxCfg("0.31.0", "2.0.0+ci.5"))).backend.?.core_version);
    // ...a pre-release of the floor release passes (permissive, like any dev pin)...
    try testing.expect((try version_floors.verdict(bgfxCfg("0.31.0", "2.1.0-rc.1"))).backend == null);
    // ...and the same pins with a satisfying core are clean.
    try testing.expect((try version_floors.verdict(bgfxCfg("0.31.0-rc.1", "2.1.0"))).backend == null);
    try testing.expect((try version_floors.verdict(bgfxCfg("0.31.0+b.5", "2.1.0"))).backend == null);
    // Control: a branch pin is still never judged.
    try testing.expect((try version_floors.verdict(bgfxCfg("main", "2.0.0"))).backend == null);
}

test "trio floor: suffixed subject and requirement are compared as their release (#783)" {
    // engine >= 3.0.0 requires gfx >= 2.0.0.
    const t = (try version_floors.trioFloorViolation("2.0.0", "3.0.0-rc.1", "1.30.1")).?;
    try testing.expectEqualStrings("engine", @tagName(t.floor.subject));
    try testing.expectEqualStrings("gfx", @tagName(t.floor.requires));
    const b = (try version_floors.trioFloorViolation("2.0.0", "3.0.0", "1.30.1+ci.2")).?;
    try testing.expectEqualStrings("gfx", @tagName(b.floor.requires));
    try testing.expect((try version_floors.trioFloorViolation("2.0.0", "3.0.0", "2.0.0-rc.1")) == null);
}

test "material gates: a suffixed official bgfx pin picks the toolchain and floor of its release (#783)" {
    try testing.expectEqual(schema.toolchain_api142, material_pipeline.toolchain(bgfxCfg("0.23.0-rc.1", "2.1.0")));
    try testing.expectEqual(schema.toolchain_api161, material_pipeline.toolchain(bgfxCfg("0.24.0+b.1", "2.1.0")));
    const v = (try material_pipeline.contractViolation(bgfxCfg("0.20.0-rc.1", "2.1.0"))).?;
    try testing.expectEqualStrings("labelle-bgfx", v.what);
    try testing.expectEqualStrings("0.20.0-rc.1", v.pinned);
    // Control: a branch pin still falls back to the newest toolchain.
    try testing.expectEqual(schema.toolchain_api161, material_pipeline.toolchain(bgfxCfg("main", "2.1.0")));
}

test "upgrade backend and the fetch path agree on a pre-release pin (#783)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const on_core = ".{ .name = \"g\", .backend = .bgfx, .core_version = \"2.0.0\", .engine_version = \"3.0.0\", .gfx_version = \"2.0.0\" }";

    // Refused by the SAME floor `generate` would apply to the written pin.
    const r = try upgrade_backend.plan(a, on_core, "0.31.0-rc.1");
    try testing.expectEqual(upgrade_backend.Outcome.Kind.refuse, r.kind);
    try testing.expect(std.mem.indexOf(u8, r.message, "requires labelle-core >= 2.1.0") != null);

    // On a core that satisfies it: written, and fetched as its own tag.
    const ok_src = ".{ .name = \"g\", .backend = .bgfx, .core_version = \"2.1.0\", .engine_version = \"3.0.0\", .gfx_version = \"2.0.0\" }";
    const w = try upgrade_backend.plan(a, ok_src, "0.31.0-rc.1");
    try testing.expectEqual(upgrade_backend.Outcome.Kind.rewrite, w.kind);
    try testing.expect(std.mem.indexOf(u8, w.content, ".version = \"0.31.0-rc.1\"") != null);
    try testing.expectEqualStrings("v0.31.0-rc.1", try config.versionToGitRef(a, "0.31.0-rc.1"));
}

test "upgrade backend: isStrictSemver / isRelease, and every builtinProvider default is a release (#783)" {
    for ([_][]const u8{ "1.2.3", "0.30.0", "1.2.3-rc.1", "1.2.3+b.5", "1.2.3-alpha.1+sha.abc" }) |v| try testing.expect(upgrade_backend.isStrictSemver(v));
    for ([_][]const u8{ "1.2.3.4", "1.2", "v1.2.3", "", "main", "1.2.3-", "1.2.3-01", "1_0.2.3", "1_0.2.3-rc.1", "1.2_0.3+b" }) |v| {
        errdefer std.debug.print("'{s}' accepted\n", .{v});
        try testing.expect(!upgrade_backend.isStrictSemver(v));
    }
    // Mechanism: `std.SemanticVersion` alone accepts the underscore core;
    // the fetch-path predicate is what refuses it.
    _ = try std.SemanticVersion.parse("1_0.2.3-rc.1");
    try testing.expect(!config.isTagVersion("1_0.2.3-rc.1"));
    try testing.expect(upgrade_backend.isRelease("1.2.3"));
    for ([_][]const u8{ "1.2.3-rc.1", "1.2.3+b.5", "1.2", "1.2.3.4" }) |v| try testing.expect(!upgrade_backend.isRelease(v));
    inline for (@typeInfo(config.Backend).@"enum".fields) |f| {
        try testing.expect(upgrade_backend.isRelease(config.ProjectConfig.builtinProvider(@enumFromInt(f.value)).?.version));
    }
}
