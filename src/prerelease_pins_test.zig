//! #783: pre-release / build-suffixed pins end to end — the fetch path, the
//! version floors and `upgrade backend` must agree on what such a pin is.
//!
//! * fetch: `1.2.3-rc.1` is the tag `v1.2.3-rc.1` (`config.versionToGitRef`,
//!   table-tested in `version_ref.zig`);
//! * floors: a pre-release SUBJECT is judged as its release, a pre-release
//!   REQUIREMENT is undecidable (`version_floors.subjectPin`);
//! * `upgrade backend` writes it and reaches the same floor verdict
//!   `generate` does, because both call `version_floors.verdict`.
const std = @import("std");
const testing = std.testing;
const config = @import("config.zig");
const version_floors = @import("version_floors.zig");
const upgrade_backend = @import("upgrade_backend.zig");

test "subjectPin: table — releases as written, suffixed semver as MAJOR.MINOR.PATCH, refs undecidable (#783)" {
    const Case = struct { pin: []const u8, judged: ?[]const u8 };
    const cases = [_]Case{
        .{ .pin = "0.31.0", .judged = "0.31.0" },
        .{ .pin = "1.2", .judged = "1.2" },
        .{ .pin = "0.31.0-rc.1", .judged = "0.31.0" },
        .{ .pin = "0.31.0+b.5", .judged = "0.31.0" },
        .{ .pin = "0.31.0-rc.1+b.5", .judged = "0.31.0" },
        .{ .pin = "main", .judged = null },
        .{ .pin = "local:../labelle-bgfx", .judged = null },
        .{ .pin = "159-fix", .judged = null },
        .{ .pin = "1.2.3-", .judged = null },
        .{ .pin = "1.2-rc.1", .judged = null },
    };
    for (cases) |c| {
        errdefer std.debug.print("pin '{s}'\n", .{c.pin});
        var buf: [64]u8 = undefined;
        const got = version_floors.subjectPin(&buf, c.pin);
        if (c.judged) |want| try testing.expectEqualStrings(want, got.?) else try testing.expect(got == null);
    }
}

fn bgfxCfg(bgfx: []const u8, core: []const u8) config.ProjectConfig {
    return .{
        .name = "g",
        .backend = .bgfx,
        .core_version = core,
        .backend_package = .{ .name = "bgfx", .repo = "github.com/labelle-toolkit/labelle-bgfx", .version = bgfx },
    };
}

test "backend floor: a pre-release backend pin is floored as its release; a pre-release core is undecidable (#783)" {
    // bgfx >= 0.26.0 needs core >= 2.1.0 (compile break).
    const hit = (try version_floors.verdict(bgfxCfg("0.31.0-rc.1", "2.0.0"))).backend.?;
    try testing.expectEqual(version_floors.FloorSeverity.compile_break, hit.severity);
    try testing.expectEqualStrings("0.31.0-rc.1", hit.backend_version); // quoted as written
    try testing.expectEqualStrings("2.1.0", hit.core_floor);
    // Mechanism: the same pin under a satisfying core is clean — the
    // suffix itself is not what trips it.
    try testing.expect((try version_floors.verdict(bgfxCfg("0.31.0-rc.1", "2.1.0"))).backend == null);
    try testing.expect((try version_floors.verdict(bgfxCfg("0.31.0+b.5", "2.1.0"))).backend == null);
    // A branch pin stays unjudged, as before.
    try testing.expect((try version_floors.verdict(bgfxCfg("main", "2.0.0"))).backend == null);
    // Requirement side: `2.1.0-rc.1` may or may not carry the 2.1.0 API —
    // undecidable, so no verdict either way (a release 2.0.0 IS judged).
    try testing.expect((try version_floors.verdict(bgfxCfg("0.31.0", "2.1.0-rc.1"))).backend == null);
    try testing.expect((try version_floors.verdict(bgfxCfg("0.31.0", "2.0.0"))).backend != null);
}

test "trio floor: pre-release subject judged, pre-release requirement skipped (#783)" {
    // engine >= 3.0.0 requires gfx >= 2.0.0 (and core >= 2.0.0).
    const t = (try version_floors.trioFloorViolation("2.0.0", "3.0.0-rc.1", "1.30.1")).?;
    try testing.expectEqualStrings("engine", @tagName(t.floor.subject));
    try testing.expectEqualStrings("gfx", @tagName(t.floor.requires));
    // gfx 2.0.0-rc.1 as the requirement is undecidable for the engine rule;
    // as a SUBJECT (gfx >= 2.0.0 requires core >= 2.0.0, engine >= 3.0.0)
    // it is judged as 2.0.0 and those pins satisfy it.
    try testing.expect((try version_floors.trioFloorViolation("2.0.0", "3.0.0", "2.0.0-rc.1")) == null);
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
