//! In-project `@libs/<lib>` test fan-out (labelle-assembler#691) — the
//! EXECUTION acceptance, not another "the step is present" pin.
//!
//! `test/build_zig_tests.zig` already asserts the emitted bytes contain a
//! per-lib `addSystemCommand` chained onto the master `test` step. That
//! family of test is exactly what let #691 through: the step was there,
//! and it still did not run the library's tests.
//!
//! Two things were wrong with the emitted block:
//!
//!   1. `argv[0]` was the bare string `"zig"`, resolved from PATH. labelle
//!      manages the toolchain (labelle-cli#279) and spawns the managed
//!      binary directly, so a labelle project is NOT required to have any
//!      `zig` on PATH — and on such a machine the fan-out died with
//!      `failed to spawn and capture stdio from zig: FileNotFound`. On a
//!      machine that did have one, the library was tested by a DIFFERENT
//!      compiler than the one driving the build.
//!   2. The Run step used the default `.check` stdio, which CAPTURES the
//!      child and discards it on success, so a passing library produced no
//!      output whatsoever — the observation that opened #691 ("a library
//!      can ship green tests that CI never runs").
//!
//! So the tests below drive the EMITTED lines for real:
//!
//!   * a library whose test FAILS makes `zig build test` fail (the
//!     regression check #691 asks for), and the failure names the test;
//!   * the same library, passing, exits 0 AND prints its test counts;
//!   * both run with a PATH containing NO `zig` at all, which is the
//!     shape that used to fail outright.
//!
//! The block is spliced out of the REAL generated build.zig (every
//! functional line carries the `lib_test` marker) rather than hand-mirrored,
//! so this pins the shipped bytes — the #586 `plugin_build_steps_tests.zig`
//! precedent.

const std = @import("std");
const zspec = @import("zspec");
const generate = @import("generator");
const h = @import("helpers.zig");
const test_options = @import("test_options");

const io = std.testing.io;

test {
    zspec.runAll(@This());
}

fn writeFileIn(dir: std.Io.Dir, rel: []const u8, body: []const u8) !void {
    if (std.fs.path.dirname(rel)) |sub| try dir.createDirPath(io, sub);
    var f = try dir.createFile(io, rel, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, body);
}

/// A library `build.zig` in the shape in-project libs actually ship:
/// a public module plus a `test` step running a real test artifact.
const lib_build_zig =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\    const mod = b.createModule(.{
    \\        .root_source_file = b.path("src/root.zig"),
    \\        .target = target,
    \\        .optimize = optimize,
    \\    });
    \\    const unit_tests = b.addTest(.{ .root_module = mod });
    \\    const test_step = b.step("test", "Run unit tests");
    \\    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    \\}
;

const failing_lib_src =
    \\const std = @import("std");
    \\pub fn answer() u32 {
    \\    return 42;
    \\}
    \\test "the deliberately failing in-project lib test" {
    \\    try std.testing.expectEqual(@as(u32, 43), answer());
    \\}
;

const passing_lib_src =
    \\const std = @import("std");
    \\pub fn answer() u32 {
    \\    return 42;
    \\}
    \\test "the deliberately passing in-project lib test" {
    \\    try std.testing.expectEqual(@as(u32, 42), answer());
    \\}
;

/// The `@libs/fanout` fan-out block, spliced out of the real generated
/// build.zig. Every functional emitted line carries `lib_test`; the block
/// references only `b` and `test_step`, so it drops straight into a
/// minimal build script.
fn splicedFanOutBlock(allocator: std.mem.Allocator) ![]const u8 {
    const build_zig = try h.genSokolBuildZigV2(allocator, .{
        .name = "fanout-game",
        .backend = .sokol,
        .ecs = .mock,
        .plugins = &.{
            .{ .name = "fanout", .repo = "@libs/fanout" },
        },
    }, .{ .is_tests_target = true });
    defer allocator.free(build_zig);

    var spliced: std.ArrayList(u8) = .empty;
    errdefer spliced.deinit(allocator);
    var lines = std.mem.splitScalar(u8, build_zig, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "lib_test") == null) continue;
        try spliced.appendSlice(allocator, line);
        try spliced.append(allocator, '\n');
    }
    if (spliced.items.len == 0) return error.NoFanOutEmitted;
    return spliced.toOwnedSlice(allocator);
}

/// Stage `<tmp>/libs/fanout/` plus `<tmp>/.labelle/tests/build.zig` holding
/// the spliced block — the exact two-levels-up geometry the emitted
/// `b.path("../../libs/fanout")` cwd assumes.
fn stage(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, lib_src: []const u8) !void {
    try tmp.dir.createDirPath(io, "libs/fanout/src");
    try writeFileIn(tmp.dir, "libs/fanout/build.zig", lib_build_zig);
    try writeFileIn(tmp.dir, "libs/fanout/src/root.zig", lib_src);

    const block = try splicedFanOutBlock(allocator);
    defer allocator.free(block);

    const harness = try std.fmt.allocPrint(allocator,
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {{
        \\    const test_step = b.step("test", "Run game-side tests");
        \\{s}}}
        \\
    , .{block});
    defer allocator.free(harness);

    try tmp.dir.createDirPath(io, ".labelle/tests");
    try writeFileIn(tmp.dir, ".labelle/tests/build.zig", harness);
}

const RunOutcome = struct {
    exited_zero: bool,
    output: []const u8,

    fn deinit(self: RunOutcome, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
    }
};

/// Drive `zig build test` on the staged harness with a PATH that contains
/// NO `zig`. The parent compiler comes from the build-options `zig_exe`
/// seam (#586); everything the fan-out spawns has to come from
/// `b.graph.zig_exe`, because PATH cannot supply it.
fn runHarness(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) !RunOutcome {
    const harness_abs = try tmp.dir.realPathFileAlloc(io, ".labelle/tests", allocator);
    defer allocator.free(harness_abs);
    // An existing-but-zig-less directory: an outright bogus PATH entry
    // would be a weaker control (some spawners treat it as "unset").
    try tmp.dir.createDirPath(io, "empty-bin");
    const empty_bin = try tmp.dir.realPathFileAlloc(io, "empty-bin", allocator);
    defer allocator.free(empty_bin);

    var env = try std.testing.environ.createMap(allocator);
    defer env.deinit();
    try env.put("PATH", empty_bin);

    const result = try std.process.run(allocator, io, .{
        .argv = &.{ test_options.zig_exe, "build", "test" },
        .cwd = .{ .path = harness_abs },
        .environ_map = &env,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const output = try std.fmt.allocPrint(allocator, "{s}{s}", .{ result.stdout, result.stderr });
    return .{
        .exited_zero = result.term == .exited and result.term.exited == 0,
        .output = output,
    };
}

pub const LIB_TEST_FANOUT_E2E = struct {
    test "acceptance: an in-project lib whose test FAILS fails `zig build test` (#691)" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try stage(allocator, &tmp, failing_lib_src);

        const outcome = try runHarness(allocator, &tmp);
        defer outcome.deinit(allocator);

        if (outcome.exited_zero) {
            std.debug.print(
                "the fan-out did NOT run the lib's tests — `zig build test` passed with a failing lib:\n{s}\n",
                .{outcome.output},
            );
            return error.FailingLibTestDidNotFailTheBuild;
        }
        // …and it failed FOR THE RIGHT REASON: the lib's own test ran.
        // Without this the assertion above would also be satisfied by a
        // fan-out that cannot spawn its child at all.
        if (std.mem.indexOf(u8, outcome.output, "the deliberately failing in-project lib test") == null) {
            std.debug.print("build failed, but not on the lib's test:\n{s}\n", .{outcome.output});
            return error.FanOutFailedForTheWrongReason;
        }
    }

    test "a passing in-project lib exits 0 and REPORTS its test counts (#691)" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try stage(allocator, &tmp, passing_lib_src);

        const outcome = try runHarness(allocator, &tmp);
        defer outcome.deinit(allocator);

        if (!outcome.exited_zero) {
            std.debug.print("passing lib should not fail the build:\n{s}\n", .{outcome.output});
            return error.PassingLibFailedTheBuild;
        }
        // The whole point of #691: silence is indistinguishable from
        // "never ran". The child's summary has to reach the operator.
        if (std.mem.indexOf(u8, outcome.output, "1/1 tests passed") == null) {
            std.debug.print("no evidence the lib's tests ran:\n{s}\n", .{outcome.output});
            return error.LibTestCountsNotReported;
        }
    }
};

pub const LIB_TEST_FANOUT_EMISSION = struct {
    test "the fan-out spawns the parent build's zig, never a PATH `zig` (#691)" {
        const allocator = std.testing.allocator;
        const build_zig = try h.genSokolBuildZigV2(allocator, .{
            .name = "fanout-game",
            .backend = .sokol,
            .ecs = .mock,
            .plugins = &.{
                .{ .name = "fanout", .repo = "@libs/fanout" },
            },
        }, .{ .is_tests_target = true });
        defer allocator.free(build_zig);

        try std.testing.expect(std.mem.indexOf(
            u8,
            build_zig,
            "b.addSystemCommand(&.{ b.graph.zig_exe, \"build\", \"test\", \"--summary\", \"all\" })",
        ) != null);
        // The bare-string spelling is the bug — it must not come back.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "&.{ \"zig\", \"build\", \"test\" }") == null);
        // …and the child's output is inherited, not captured-and-dropped.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "lib_test.stdio = .inherit;") != null);
    }
};
