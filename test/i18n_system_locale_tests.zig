//! i18n device-language boot (RFC-I18N section 8, flying-platform#917).
//!
//! The generated main hands the backend's `window.systemLocale()` to the
//! i18n module's `applySystemLocale`, which must turn an OS spelling
//! (`pt-BR`, `pt_BR.UTF-8`, `EN-us`) into a shipped locale — exact tag, then
//! the bare language, then any tag of the same language — keep the
//! `.i18n.default` for a language the build doesn't ship, and never override
//! an explicit `setLocale()`.
//!
//! Same shape as `i18n_sentinel_tests.zig`: generate a real `i18n.zig`
//! through the phase, then COMPILE AND RUN a harness against it (`zig test`,
//! via the #586 `test_options.zig_exe` seam), since the behavior lives in
//! emitted source text.

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

const Locale = struct { tag: []const u8, body: []const u8 };

/// Generates `i18n.zig` from `locales` (default `en`), writes `harness` next
/// to it and runs it with `zig test`.
fn generateAndRun(locales: []const Locale, harness: []const u8) !void {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    for (locales) |l| {
        var path_buf: [64]u8 = undefined;
        try writeFileIn(tmp.dir, try std.fmt.bufPrint(&path_buf, "game/locales/{s}.jsonc", .{l.tag}), l.body);
    }
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
    try writeFileIn(tmp.dir, "target/system_locale_check.zig", harness);

    const target_abs = try tmp.dir.realPathFileAlloc(io, "target", allocator);
    defer allocator.free(target_abs);
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ test_options.zig_exe, "test", "system_locale_check.zig" },
        .cwd = .{ .path = target_abs },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const ok = result.term == .exited and result.term.exited == 0;
    if (!ok) {
        std.debug.print("system-locale harness failed:\n{s}\n", .{result.stderr});
        return error.SystemLocaleResolutionBroken;
    }
}

pub const SystemLocale = struct {
    test "device spellings resolve to the shipped locale; unknown languages keep the default; setLocale wins" {
        try generateAndRun(&.{
            .{ .tag = "en", .body = "{ \"menu\": { \"play\": \"Play\" } }" },
            .{ .tag = "pt", .body = "{ \"menu\": { \"play\": \"Jogar\" } }" },
        },
            \\const std = @import("std");
            \\const i18n = @import("i18n.zig");
            \\
            \\// One test: the module's active locale is process-global, so the
            \\// steps run in order against the same state.
            \\test "applySystemLocale resolution order" {
            \\    // A language the build doesn't ship leaves the default active.
            \\    try std.testing.expect(!i18n.applySystemLocale("de-DE"));
            \\    try std.testing.expectEqualStrings("en", i18n.activeLocale());
            \\    try std.testing.expect(!i18n.applySystemLocale(""));
            \\
            \\    // Region tag -> bare language (Android / web / macOS spelling).
            \\    try std.testing.expect(i18n.applySystemLocale("pt-BR"));
            \\    try std.testing.expectEqualStrings("pt", i18n.activeLocale());
            \\    try std.testing.expectEqualStrings("Jogar", i18n.t(i18n.K.menu.play));
            \\
            \\    // POSIX spelling (Linux LANG) and case-insensitivity.
            \\    try std.testing.expect(i18n.applySystemLocale("EN_us.UTF-8"));
            \\    try std.testing.expectEqualStrings("en", i18n.activeLocale());
            \\    try std.testing.expect(i18n.applySystemLocale("pt_PT@euro"));
            \\    try std.testing.expectEqualStrings("pt", i18n.activeLocale());
            \\
            \\    // An explicit choice outranks the device language.
            \\    try std.testing.expect(i18n.setLocale("en"));
            \\    try std.testing.expect(!i18n.applySystemLocale("pt-BR"));
            \\    try std.testing.expectEqualStrings("en", i18n.activeLocale());
            \\}
        );
    }

    test "a region-only locale serves every region of its language" {
        try generateAndRun(&.{
            .{ .tag = "en", .body = "{ \"menu\": { \"play\": \"Play\" } }" },
            .{ .tag = "pt-BR", .body = "{ \"menu\": { \"play\": \"Jogar\" } }" },
        },
            \\const std = @import("std");
            \\const i18n = @import("i18n.zig");
            \\
            \\test "pt-PT and bare pt find pt-BR" {
            \\    try std.testing.expect(i18n.applySystemLocale("pt-PT"));
            \\    try std.testing.expectEqualStrings("pt-BR", i18n.activeLocale());
            \\    try std.testing.expect(i18n.applySystemLocale("en-GB"));
            \\    try std.testing.expectEqualStrings("en", i18n.activeLocale());
            \\    try std.testing.expect(i18n.applySystemLocale("pt"));
            \\    try std.testing.expectEqualStrings("pt-BR", i18n.activeLocale());
            \\}
        );
    }
};
