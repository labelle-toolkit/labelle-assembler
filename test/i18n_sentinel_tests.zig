//! i18n sentinel contract — the cimgui hand-off (flying-platform#786
//! friction #3).
//!
//! Every cimgui call site passes `t(...).ptr` / `tf(...).ptr` straight to C,
//! so both lookup paths MUST return `[:0]const u8` with a real NUL at
//! `.ptr[len]`. #656 already ships this: the baked table's strings are Zig
//! string literals (sentinel-backed by construction, including the
//! decoded-escape path), and the tf ring reserves its last byte so the
//! sentinel always has a home within the wrap-between-results discipline.
//! No `tz`/`tfz` siblings are needed -- `t`/`tf` ARE the null-terminated
//! variants.
//!
//! This suite is the regression lock: it generates a real `i18n.zig` through
//! the phase, then COMPILES AND RUNS a harness against it (`zig test`, via
//! the #586 `test_options.zig_exe` seam) whose comptime `@TypeOf` asserts
//! and runtime `.ptr[len] == 0` probes fail the moment either signature or
//! sentinel regresses. Text-level asserts cannot prove a type; this does.

const std = @import("std");
const zspec = @import("zspec");
const generator = @import("generator");
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

pub const SentinelContract = struct {
    test "generated t/tf return [:0]const u8 and the NUL is really there" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        // A locale exercising every string path: plain, interpolated,
        // decoded-escape ({{ }} -> literal braces), and a Zig-keyword key
        // (friction #2's @""-call-site shape, proving the lint stays a
        // warning end to end).
        try writeFileIn(tmp.dir, "game/locales/en.jsonc",
            \\{
            \\  "menu": { "play": "Play" },
            \\  "hud": { "stock": "{count} of {max}", "tip": "Set {{name}} here" },
            \\  "pause": { "resume": "Resume" }
            \\}
        );
        try tmp.dir.createDirPath(io, "target");

        var rel_buf: [96]u8 = undefined;
        const rel = try std.fmt.bufPrint(&rel_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
        const game = try std.fs.path.join(allocator, &.{ rel, "game" });
        defer allocator.free(game);
        const target = try std.fs.path.join(allocator, &.{ rel, "target" });
        defer allocator.free(target);

        try std.testing.expectEqual(true, try generator.i18n_phase.runPhase(
            allocator,
            game,
            target,
            .{ .default = "en" },
            &.{},
            true,
        ));

        // The harness the generated module must satisfy. Comptime first:
        // a signature regression fails the compile, not the run.
        try writeFileIn(tmp.dir, "target/sentinel_check.zig",
            \\const std = @import("std");
            \\const i18n = @import("i18n.zig");
            \\
            \\comptime {
            \\    if (@typeInfo(@TypeOf(i18n.t)).@"fn".return_type.? != [:0]const u8)
            \\        @compileError("t() lost its [:0] sentinel (flying-platform#786 friction #3)");
            \\    if (@typeInfo(@TypeOf(i18n.tf)).@"fn".return_type.? != [:0]const u8)
            \\        @compileError("tf() lost its [:0] sentinel (flying-platform#786 friction #3)");
            \\}
            \\
            \\test "static, decoded and keyword-keyed strings carry the NUL" {
            \\    const s = i18n.t(i18n.K.menu.play);
            \\    try std.testing.expectEqualStrings("Play", s);
            \\    try std.testing.expectEqual(@as(u8, 0), s.ptr[s.len]);
            \\
            \\    // Decoded-escape path: {{name}} decoded at generation time.
            \\    const d = i18n.t(i18n.K.hud.tip);
            \\    try std.testing.expectEqualStrings("Set {name} here", d);
            \\    try std.testing.expectEqual(@as(u8, 0), d.ptr[d.len]);
            \\
            \\    // A keyword key still works through @"" (the lint is
            \\    // ergonomics-only, never an error).
            \\    const r = i18n.t(i18n.K.pause.@"resume");
            \\    try std.testing.expectEqualStrings("Resume", r);
            \\    try std.testing.expectEqual(@as(u8, 0), r.ptr[r.len]);
            \\}
            \\
            \\test "tf ring results carry the NUL, result after result" {
            \\    // Two results in a row: the second must not disturb the
            \\    // first's sentinel, and both end NUL-terminated.
            \\    const a = i18n.tf(i18n.K.hud.stock, .{ .count = 3, .max = 9 });
            \\    const b = i18n.tf(i18n.K.hud.stock, .{ .count = 12, .max = 40 });
            \\    try std.testing.expectEqualStrings("3 of 9", a);
            \\    try std.testing.expectEqualStrings("12 of 40", b);
            \\    try std.testing.expectEqual(@as(u8, 0), a.ptr[a.len]);
            \\    try std.testing.expectEqual(@as(u8, 0), b.ptr[b.len]);
            \\}
        );

        const target_abs = try tmp.dir.realPathFileAlloc(io, "target", allocator);
        defer allocator.free(target_abs);
        const result = try std.process.run(allocator, io, .{
            .argv = &.{ test_options.zig_exe, "test", "sentinel_check.zig" },
            .cwd = .{ .path = target_abs },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        const ok = result.term == .exited and result.term.exited == 0;
        if (!ok) {
            std.debug.print("sentinel harness failed:\n{s}\n", .{result.stderr});
            return error.SentinelContractBroken;
        }
    }
};
