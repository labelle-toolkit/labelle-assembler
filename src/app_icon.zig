/// Default app-icon / launch-image injection (issue #66).
///
/// A freshly scaffolded game declares no `app_icon` in `project.labelle`,
/// which used to surface as a blank OS window icon on desktop and the
/// stock Android launcher icon on the home screen — a poor first
/// impression for `labelle run`.
///
/// To fix that, the assembler ships a bundled "Labelle" branded PNG and
/// injects it into the generated build tree whenever the project does
/// NOT declare its own icon. A project that sets `app_icon` suppresses
/// the default entirely — no behavior change for games that already
/// ship their own icon assets.
const std = @import("std");
const config = @import("config.zig");

const ProjectConfig = config.ProjectConfig;

/// The bundled default icon, embedded into the assembler binary so a
/// `labelle` install stays self-contained (no separate asset download).
/// 512×512 RGBA PNG — the "Labelle" branded logo. Stored under `src/`
/// because `@embedFile` only reaches files inside the module's package
/// path (the assembler's root source file lives in `src/`).
pub const default_icon_bytes = @embedFile("assets/default_icon.png");

/// Path, relative to the generated target dir, where the default icon
/// is written when the project provides none. Lives under `assets/` so
/// it sits alongside the project's own copied assets and is reachable
/// by the same `@embedFile("assets/...")` codegen the resource pipeline
/// already emits.
pub const default_icon_rel_path = "assets/default_icon.png";

/// Resolve the effective app-icon path for a project.
///
/// Returns the project's declared `app_icon` verbatim when set, otherwise
/// the bundled default's target-relative path. Never returns null — every
/// generated build has an icon, the question is only whose.
pub fn effectiveIconPath(cfg: ProjectConfig) []const u8 {
    return cfg.app_icon orelse default_icon_rel_path;
}

/// Returns true when the assembler must inject the bundled default icon
/// into the generated build tree — i.e. the project declared no
/// `app_icon` of its own.
pub fn usesDefaultIcon(cfg: ProjectConfig) bool {
    return cfg.app_icon == null;
}

/// Inject the bundled default icon into `target_dir/assets/` when the
/// project declares no `app_icon`. A no-op when the project ships its
/// own icon — `app_icon` being set means the default must NOT be
/// emitted (issue #66 override precedence).
///
/// The `assets/` directory is created if missing; it normally already
/// exists because `root.zig` links the project's `assets/` folder into
/// the target before this runs, but a project without an `assets/` dir
/// must still receive the default.
pub fn injectDefaultIcon(allocator: std.mem.Allocator, cfg: ProjectConfig, target_dir: []const u8) !void {
    if (!usesDefaultIcon(cfg)) return;

    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    const assets_dir = try std.fs.path.join(allocator, &.{ target_dir, "assets" });
    defer allocator.free(assets_dir);
    try cwd.createDirPath(io, assets_dir);

    const icon_path = try std.fs.path.join(allocator, &.{ target_dir, default_icon_rel_path });
    defer allocator.free(icon_path);

    // Plain (non-exclusive) write: regenerating an existing target must
    // refresh the default icon rather than fail on a stale copy.
    try cwd.writeFile(io, .{ .sub_path = icon_path, .data = default_icon_bytes });
}

test "effectiveIconPath: falls back to the bundled default when unset" {
    const cfg = ProjectConfig{ .name = "game" };
    try std.testing.expectEqualStrings(default_icon_rel_path, effectiveIconPath(cfg));
}

test "effectiveIconPath: uses the project's app_icon verbatim when set" {
    const cfg = ProjectConfig{ .name = "game", .app_icon = "assets/my_icon.png" };
    try std.testing.expectEqualStrings("assets/my_icon.png", effectiveIconPath(cfg));
}

test "usesDefaultIcon: true only when app_icon is absent" {
    try std.testing.expect(usesDefaultIcon(.{ .name = "game" }));
    try std.testing.expect(!usesDefaultIcon(.{ .name = "game", .app_icon = "assets/icon.png" }));
}

test "default_icon_bytes: is a non-empty PNG" {
    // PNG magic: 0x89 'P' 'N' 'G' 0x0D 0x0A 0x1A 0x0A
    try std.testing.expect(default_icon_bytes.len > 8);
    const png_magic = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
    try std.testing.expectEqualSlices(u8, &png_magic, default_icon_bytes[0..8]);
}

test "injectDefaultIcon: writes the default into a fresh target without app_icon" {
    const allocator = std.testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(target_dir);

    const cfg = ProjectConfig{ .name = "game" };
    try injectDefaultIcon(allocator, cfg, target_dir);

    const icon_path = try std.fs.path.join(allocator, &.{ target_dir, default_icon_rel_path });
    defer allocator.free(icon_path);
    const written = try cwd.readFileAlloc(io, icon_path, allocator, .limited(1 << 20));
    defer allocator.free(written);
    try std.testing.expectEqualSlices(u8, default_icon_bytes, written);
}

test "injectDefaultIcon: is a no-op when the project declares its own app_icon" {
    const allocator = std.testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(target_dir);

    const cfg = ProjectConfig{ .name = "game", .app_icon = "assets/custom.png" };
    try injectDefaultIcon(allocator, cfg, target_dir);

    // The default must NOT have been emitted — `app_icon` being set
    // means the project owns its icon.
    const icon_path = try std.fs.path.join(allocator, &.{ target_dir, default_icon_rel_path });
    defer allocator.free(icon_path);
    try std.testing.expectError(error.FileNotFound, cwd.access(io, icon_path, .{}));
}
