/// Default app-icon / launch-image injection (issue #66).
///
/// A freshly scaffolded game declares no `app_icon` in `project.labelle`,
/// which used to surface as a blank OS window icon on desktop and the
/// stock Android launcher icon on the home screen — a poor first
/// impression for `labelle run`.
///
/// To fix that, the assembler ships a bundled "labelle" branded PNG and
/// injects it into the generated build tree whenever the project does
/// NOT declare its own icon. A project that sets `app_icon` suppresses
/// the default entirely — no behavior change for games that already
/// ship their own icon assets.
const std = @import("std");
const config = @import("config.zig");

const ProjectConfig = config.ProjectConfig;

/// The bundled default icon, embedded into the assembler binary so a
/// `labelle` install stays self-contained (no separate asset download).
/// 512×512 opaque RGB PNG — the "labelle" branded logo. Stored under
/// `src/` because `@embedFile` only reaches files inside the module's
/// package path (the assembler's root source file lives in `src/`).
///
/// RGB, not RGBA: the art is fully opaque, so an alpha plane would be a
/// constant 255 costing ~60KB of embedded binary for nothing. Consumers
/// that need four channels should ask their decoder for RGBA (stb_image
/// takes a desired-channel count).
///
/// 512 is the largest size any current consumer needs (Android's
/// xxxhdpi launcher mipmap is 192). Regenerate this — and any future
/// higher-density or iOS 1024 variant — from the 2048×2048 master at
/// `assets/default_icon_master.png`, which is the source of truth and
/// deliberately NOT under `src/` so it never lands in the binary.
pub const default_icon_bytes = @embedFile("assets/default_icon.png");

/// Path, relative to the generated target dir, where the default icon
/// is written when the project provides none.
///
/// It lands at the target-dir root — NOT under `assets/`. The
/// assembler links the project's `assets/` into the target as a
/// *directory symlink* back to the source (`scanner.linkDir`), so the
/// target's `assets/` is not a real, writable directory: writing into
/// it fails (`error.NotDir`) and would otherwise pollute the source
/// project. The target-dir root is assembler-owned and safe to write.
pub const default_icon_rel_path = "default_icon.png";

/// True when the project declares a usable icon of its own — a
/// non-null, non-empty `app_icon`. A stray `.app_icon = ""` is
/// treated as "no icon" so the project still receives the default
/// rather than an empty, unusable path.
fn hasOwnIcon(cfg: ProjectConfig) bool {
    const icon = cfg.app_icon orelse return false;
    return icon.len != 0;
}

/// Resolve the effective app-icon path for a project.
///
/// Returns the project's declared `app_icon` when it sets a non-empty
/// one, otherwise the bundled default's target-relative path. Never
/// returns null — every generated build has an icon, the question is
/// only whose.
pub fn effectiveIconPath(cfg: ProjectConfig) []const u8 {
    return if (hasOwnIcon(cfg)) cfg.app_icon.? else default_icon_rel_path;
}

/// Returns true when the assembler must inject the bundled default
/// icon into the generated build tree — i.e. the project declares no
/// `app_icon` of its own (null or empty).
pub fn usesDefaultIcon(cfg: ProjectConfig) bool {
    return !hasOwnIcon(cfg);
}

/// Inject the bundled default icon into the generated target dir when
/// the project declares no `app_icon`. A no-op when the project ships
/// its own icon — `app_icon` being set means the default must NOT be
/// emitted (issue #66 override precedence).
///
/// The icon is written at the target-dir root (see
/// `default_icon_rel_path`): `target_dir` is created by the assembler
/// before this runs and is a real, writable directory, whereas
/// `target_dir/assets` is a symlink to the source project.
pub fn injectDefaultIcon(allocator: std.mem.Allocator, cfg: ProjectConfig, target_dir: []const u8) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    const icon_path = try std.fs.path.join(allocator, &.{ target_dir, default_icon_rel_path });
    defer allocator.free(icon_path);

    if (!usesDefaultIcon(cfg)) {
        // The project ships its own icon — drop a default left behind
        // by an earlier generate so a stale copy doesn't linger in
        // the target after the project adopts a custom `app_icon`.
        cwd.deleteFile(io, icon_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return;
    }

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

test "default_icon_bytes: is a 512x512 opaque-RGB PNG" {
    // Guards the documented contract against a careless art swap: the
    // packaging layer scales this into launcher mipmaps, so a wrong size
    // or a surprise alpha plane would surface as a bad icon on-device
    // rather than a build failure.
    //
    // IHDR is the mandatory first chunk: 8-byte magic, 4-byte length,
    // 4-byte type, then width/height as big-endian u32.
    try std.testing.expect(default_icon_bytes.len > 26);
    try std.testing.expectEqualSlices(u8, "IHDR", default_icon_bytes[12..16]);

    const width = std.mem.readInt(u32, default_icon_bytes[16..20], .big);
    const height = std.mem.readInt(u32, default_icon_bytes[20..24], .big);
    try std.testing.expectEqual(@as(u32, 512), width);
    try std.testing.expectEqual(@as(u32, 512), height);

    // Color type 2 = truecolour (RGB, no alpha) at 8 bits per channel.
    try std.testing.expectEqual(@as(u8, 8), default_icon_bytes[24]);
    try std.testing.expectEqual(@as(u8, 2), default_icon_bytes[25]);
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

test "injectDefaultIcon: removes a stale default after the project adopts an app_icon" {
    const allocator = std.testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(target_dir);

    const icon_path = try std.fs.path.join(allocator, &.{ target_dir, default_icon_rel_path });
    defer allocator.free(icon_path);

    // First generate: no app_icon -> the default lands in the target.
    try injectDefaultIcon(allocator, ProjectConfig{ .name = "game" }, target_dir);
    try cwd.access(io, icon_path, .{});

    // Project later adopts its own icon -> the stale default is dropped.
    const cfg = ProjectConfig{ .name = "game", .app_icon = "assets/custom.png" };
    try injectDefaultIcon(allocator, cfg, target_dir);
    try std.testing.expectError(error.FileNotFound, cwd.access(io, icon_path, .{}));
}

test "usesDefaultIcon: an empty app_icon string still gets the default" {
    // A stray `.app_icon = ""` is not a usable icon — treat it as unset.
    try std.testing.expect(usesDefaultIcon(.{ .name = "game", .app_icon = "" }));
    try std.testing.expectEqualStrings(default_icon_rel_path, effectiveIconPath(.{ .name = "game", .app_icon = "" }));
}
