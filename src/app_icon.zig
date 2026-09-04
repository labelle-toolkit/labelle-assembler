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
const ico = @import("ico.zig");

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

// ── Desktop icon artifacts (labelle-cli#359) ─────────────────────────
//
// Two more consumers of the same icon on desktop:
//
//   * the RUNTIME window icon — the generated `main.zig` embeds the icon
//     PNG (`@embedFile(iconEmbedPath(cfg))`) and hands it to the backend
//     after `initWindow` (labelle-bgfx `setWindowIconPng`, gated on
//     `@hasDecl` so other backends fold it away), and
//   * the WINDOWS EXE ICON — an `ICON` resource compiled from
//     `app_icon.rc` → `app_icon.ico`, added by the generated `build.zig`
//     on Windows targets only.
//
// `@embedFile` can only reach files under the module root (the target
// dir), and a project's `app_icon` is relative to the PROJECT root — it
// may live outside the linked `assets/` (e.g. `icon.png` at the root),
// where no symlink brings it into the target. So a custom icon is COPIED
// to `<target>/app_icon.png`; the default already lands at
// `default_icon.png`. The two never coexist (same stale-cleanup rule as
// `injectDefaultIcon`), and the CLI's `default_icon.png` contract is
// untouched.

/// Target-relative path of the staged copy of a CUSTOM `app_icon`.
pub const custom_icon_rel_path = "app_icon.png";
/// Target-relative path of the Windows icon container.
pub const windows_ico_rel_path = "app_icon.ico";
/// Target-relative path of the resource script naming it.
pub const windows_rc_rel_path = "app_icon.rc";
/// The whole resource script: resource id 1, type ICON, the `.ico` beside
/// it. Zig's built-in resource compiler handles this when cross-compiling.
pub const windows_rc_source = "1 ICON \"" ++ windows_ico_rel_path ++ "\"\n";

/// The target-relative path the generated `main.zig` should `@embedFile`
/// for the window icon: the staged custom copy, or the injected default.
pub fn iconEmbedPath(cfg: ProjectConfig) []const u8 {
    return if (hasOwnIcon(cfg)) custom_icon_rel_path else default_icon_rel_path;
}

/// Read the effective icon's PNG bytes: the bundled default (no disk
/// read), or `<game_dir>/<app_icon>`. A custom icon that is missing or
/// unreadable is a HARD error naming the path — a project that names an
/// icon and silently ships the stock one is the bug cli#340 fixed, and
/// the generated `@embedFile` would fail the build anyway, only later and
/// less clearly. Caller frees the result (the default is duplicated so
/// ownership is uniform).
pub fn readIconBytes(allocator: std.mem.Allocator, cfg: ProjectConfig, game_dir: []const u8) ![]u8 {
    if (!hasOwnIcon(cfg)) return allocator.dupe(u8, default_icon_bytes);
    const io = config.globalIo();
    const path = try std.fs.path.join(allocator, &.{ game_dir, cfg.app_icon.? });
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 << 20)) catch |err| {
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &buf,
            "labelle-assembler: app_icon not found or unreadable at {s} ({s})\n  `.app_icon` in project.labelle is resolved relative to the project root.\n  Fix the path or remove `.app_icon` to use the bundled default icon.\n",
            .{ path, @errorName(err) },
        ) catch "labelle-assembler: app_icon not found or unreadable\n";
        std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
        return error.AppIconNotFound;
    };
}

/// Write the desktop icon artifacts into `target_dir` (see the section
/// comment): the staged custom copy (or remove a stale one), plus
/// `app_icon.ico` and `app_icon.rc`. Desktop only — other platforms
/// package their icon elsewhere (APK mipmaps, `.app` bundle, favicon) and
/// never embed it, so they get nothing here. Runs after
/// `injectDefaultIcon` (which owns `default_icon.png`).
pub fn writeDesktopIconArtifacts(allocator: std.mem.Allocator, cfg: ProjectConfig, game_dir: []const u8, target_dir: []const u8) !void {
    if (cfg.platform != .desktop) return;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    const png = try readIconBytes(allocator, cfg, game_dir);
    defer allocator.free(png);

    const custom_path = try std.fs.path.join(allocator, &.{ target_dir, custom_icon_rel_path });
    defer allocator.free(custom_path);
    if (hasOwnIcon(cfg)) {
        try cwd.writeFile(io, .{ .sub_path = custom_path, .data = png });
    } else {
        cwd.deleteFile(io, custom_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    // The Windows `.ico`. An icon must never be able to fail a whole desktop
    // generate: the build does not depend on it, and a broken icon is a
    // cosmetic problem, so anything `buildIco` cannot handle degrades to the
    // BUNDLED DEFAULT for the exe icon — loudly, naming the file and the
    // reason, because silently shipping the stock icon for a project that
    // asked for its own is the bug cli#340 exists to prevent.
    //
    // Note the split: a MISSING or unreadable `app_icon` is still a hard error
    // (`readIconBytes`, above) — that is a broken path in `project.labelle`,
    // which the author must fix. This branch is only for a file that IS there
    // and cannot be turned into an ICO: a PNG this reader declines
    // (interlaced, damaged), one whose size no ICONDIRENTRY can state, or
    // bytes that are not a PNG at all.
    //
    // Only the Windows exe icon degrades. The RUNTIME window icon still embeds
    // the project's own file (staged above); if the backend cannot decode it
    // either, it warns and shows no icon — it never takes the game down.
    const ico_bytes = ico.buildIco(allocator, png) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        var buf: [768]u8 = undefined;
        const why: []const u8 = switch (err) {
            error.NotPng => "it is not a PNG (app icons must be PNG)",
            error.IcoFallbackUnrepresentable => "it could not be decoded (interlaced or damaged PNG) and its size cannot be described in a Windows .ico — re-save it as a NON-INTERLACED, square PNG of at most 256x256",
            else => "it could not be encoded as a Windows .ico",
        };
        const msg = std.fmt.bufPrint(
            &buf,
            "labelle-assembler: WARNING: using the bundled default icon for the Windows exe icon — app_icon {s}: {s} ({s})\n",
            .{ effectiveIconPath(cfg), why, @errorName(err) },
        ) catch "labelle-assembler: WARNING: using the bundled default icon for the Windows exe icon\n";
        std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
        // The bundled default is a plain 8-bit PNG this encoder is tested
        // against, so this cannot fail for a reason the project caused; if it
        // ever does, that is an assembler bug and should surface.
        break :blk try ico.buildIco(allocator, default_icon_bytes);
    };
    defer allocator.free(ico_bytes);

    const ico_path = try std.fs.path.join(allocator, &.{ target_dir, windows_ico_rel_path });
    defer allocator.free(ico_path);
    try cwd.writeFile(io, .{ .sub_path = ico_path, .data = ico_bytes });

    const rc_path = try std.fs.path.join(allocator, &.{ target_dir, windows_rc_rel_path });
    defer allocator.free(rc_path);
    try cwd.writeFile(io, .{ .sub_path = rc_path, .data = windows_rc_source });
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

test "writeDesktopIconArtifacts: an undecodable custom icon degrades to the default .ico, not a failed generate" {
    // The regression guard (Codex on #687): a project whose `app_icon` this
    // reader cannot decode must still GENERATE. Only the Windows exe icon
    // degrades — loudly — and everything else is written as usual.
    const allocator = std.testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const game_dir = try std.fs.path.join(allocator, &.{ root, "game" });
    defer allocator.free(game_dir);
    const target_dir = try std.fs.path.join(allocator, &.{ root, "target" });
    defer allocator.free(target_dir);
    try cwd.createDirPath(io, game_dir);
    try cwd.createDirPath(io, target_dir);

    // A real PNG, 512x512 per its IHDR, that does not decode — the one shape
    // `buildIco` can neither read nor describe verbatim.
    const png = try ico.encodePng(allocator, &[_]u8{0} ** (4 * 4 * 4), 4, 4);
    defer allocator.free(png);
    std.mem.writeInt(u32, png[16..20], 512, .big);
    std.mem.writeInt(u32, png[20..24], 512, .big);
    const src_icon = try std.fs.path.join(allocator, &.{ game_dir, "icon.png" });
    defer allocator.free(src_icon);
    try cwd.writeFile(io, .{ .sub_path = src_icon, .data = png });

    const cfg = ProjectConfig{ .name = "game", .app_icon = "icon.png" };
    try writeDesktopIconArtifacts(allocator, cfg, game_dir, target_dir);

    // The .ico is the DEFAULT's four entries (256/48/32/16), not a refusal…
    const ico_path = try std.fs.path.join(allocator, &.{ target_dir, windows_ico_rel_path });
    defer allocator.free(ico_path);
    const ico_bytes = try cwd.readFileAlloc(io, ico_path, allocator, .limited(4 << 20));
    defer allocator.free(ico_bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 1, 0, 4, 0 }, ico_bytes[0..6]);
    const from_default = try ico.buildIco(allocator, default_icon_bytes);
    defer allocator.free(from_default);
    try std.testing.expectEqualSlices(u8, from_default, ico_bytes);

    // …and the rest is untouched: the .rc is there, and the RUNTIME icon still
    // embeds the project's OWN file (the backend decodes it, or warns and shows
    // nothing — that is not the assembler's call to make).
    const rc_path = try std.fs.path.join(allocator, &.{ target_dir, windows_rc_rel_path });
    defer allocator.free(rc_path);
    try cwd.access(io, rc_path, .{});
    const staged_path = try std.fs.path.join(allocator, &.{ target_dir, custom_icon_rel_path });
    defer allocator.free(staged_path);
    const staged = try cwd.readFileAlloc(io, staged_path, allocator, .limited(1 << 20));
    defer allocator.free(staged);
    try std.testing.expectEqualSlices(u8, png, staged);
}

test "writeDesktopIconArtifacts: a palette-optimised 512 icon builds a real .ico" {
    // The exact user-facing case from the review: a 1-bit INDEXED 512x512
    // app_icon (what palette optimisation produces) must yield the project's
    // OWN four entries — not the default, and not an error.
    const allocator = std.testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir);

    const edge: u32 = 512;
    const plte = [_]u8{ 255, 0, 0, 0, 0, 255 };
    const samples = try allocator.alloc(u8, edge * edge);
    defer allocator.free(samples);
    for (0..edge) |y| for (0..edge) |x| {
        samples[y * edge + x] = if (x < edge / 2) 0 else 1;
    };
    const png = try ico.encodePngPackedForTest(allocator, samples, edge, edge, 1, 3, &plte);
    defer allocator.free(png);
    const src_icon = try std.fs.path.join(allocator, &.{ dir, "icon.png" });
    defer allocator.free(src_icon);
    try cwd.writeFile(io, .{ .sub_path = src_icon, .data = png });

    try writeDesktopIconArtifacts(allocator, .{ .name = "game", .app_icon = "icon.png" }, dir, dir);

    const ico_path = try std.fs.path.join(allocator, &.{ dir, windows_ico_rel_path });
    defer allocator.free(ico_path);
    const ico_bytes = try cwd.readFileAlloc(io, ico_path, allocator, .limited(4 << 20));
    defer allocator.free(ico_bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 1, 0, 4, 0 }, ico_bytes[0..6]);
    // Not the default: the art is this project's red/blue split.
    const from_default = try ico.buildIco(allocator, default_icon_bytes);
    defer allocator.free(from_default);
    try std.testing.expect(!std.mem.eql(u8, from_default, ico_bytes));
}

test "iconEmbedPath: default_icon.png when unset, the staged app_icon.png when custom" {
    try std.testing.expectEqualStrings(default_icon_rel_path, iconEmbedPath(.{ .name = "game" }));
    try std.testing.expectEqualStrings(default_icon_rel_path, iconEmbedPath(.{ .name = "game", .app_icon = "" }));
    try std.testing.expectEqualStrings(custom_icon_rel_path, iconEmbedPath(.{ .name = "game", .app_icon = "icon.png" }));
}

test "writeDesktopIconArtifacts: default icon → .ico + .rc, no staged app_icon.png" {
    const allocator = std.testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(target_dir);

    try writeDesktopIconArtifacts(allocator, .{ .name = "game" }, target_dir, target_dir);

    const rc_path = try std.fs.path.join(allocator, &.{ target_dir, windows_rc_rel_path });
    defer allocator.free(rc_path);
    const rc = try cwd.readFileAlloc(io, rc_path, allocator, .limited(1 << 10));
    defer allocator.free(rc);
    try std.testing.expectEqualStrings("1 ICON \"app_icon.ico\"\n", rc);

    const ico_path = try std.fs.path.join(allocator, &.{ target_dir, windows_ico_rel_path });
    defer allocator.free(ico_path);
    const ico_bytes = try cwd.readFileAlloc(io, ico_path, allocator, .limited(4 << 20));
    defer allocator.free(ico_bytes);
    // ICONDIR: reserved 0, type 1, four entries (256/48/32/16 from the 512 default).
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 1, 0, 4, 0 }, ico_bytes[0..6]);

    const custom_path = try std.fs.path.join(allocator, &.{ target_dir, custom_icon_rel_path });
    defer allocator.free(custom_path);
    try std.testing.expectError(error.FileNotFound, cwd.access(io, custom_path, .{}));
}

test "writeDesktopIconArtifacts: a custom icon is staged as app_icon.png and its .ico built" {
    const allocator = std.testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    // Project root with `icon.png` OUTSIDE assets/ — the case the staging exists for.
    const game_dir = try std.fs.path.join(allocator, &.{ root, "game" });
    defer allocator.free(game_dir);
    const target_dir = try std.fs.path.join(allocator, &.{ root, "target" });
    defer allocator.free(target_dir);
    try cwd.createDirPath(io, game_dir);
    try cwd.createDirPath(io, target_dir);

    const px = [_]u8{ 1, 2, 3, 255 } ** (8 * 8);
    const png = try ico.encodePng(allocator, &px, 8, 8);
    defer allocator.free(png);
    const src_icon = try std.fs.path.join(allocator, &.{ game_dir, "icon.png" });
    defer allocator.free(src_icon);
    try cwd.writeFile(io, .{ .sub_path = src_icon, .data = png });

    const cfg = ProjectConfig{ .name = "game", .app_icon = "icon.png" };
    try writeDesktopIconArtifacts(allocator, cfg, game_dir, target_dir);

    const staged_path = try std.fs.path.join(allocator, &.{ target_dir, custom_icon_rel_path });
    defer allocator.free(staged_path);
    const staged = try cwd.readFileAlloc(io, staged_path, allocator, .limited(1 << 20));
    defer allocator.free(staged);
    try std.testing.expectEqualSlices(u8, png, staged);

    const ico_path = try std.fs.path.join(allocator, &.{ target_dir, windows_ico_rel_path });
    defer allocator.free(ico_path);
    const ico_bytes = try cwd.readFileAlloc(io, ico_path, allocator, .limited(1 << 20));
    defer allocator.free(ico_bytes);
    // An 8-square source: one 8x8 entry, nothing upscaled.
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 1, 0, 1, 0 }, ico_bytes[0..6]);
    try std.testing.expectEqual(@as(u8, 8), ico_bytes[6]);

    // Project drops its icon → the staged copy is removed, the default's .ico takes over.
    try writeDesktopIconArtifacts(allocator, .{ .name = "game" }, game_dir, target_dir);
    try std.testing.expectError(error.FileNotFound, cwd.access(io, staged_path, .{}));
}

test "writeDesktopIconArtifacts: a missing custom icon fails loudly (never the default)" {
    const allocator = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir);
    const cfg = ProjectConfig{ .name = "game", .app_icon = "assets/nope.png" };
    try std.testing.expectError(error.AppIconNotFound, writeDesktopIconArtifacts(allocator, cfg, dir, dir));
}

test "writeDesktopIconArtifacts: non-desktop platforms write nothing" {
    const allocator = std.testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir);
    inline for (.{ .android, .wasm, .ios }) |plat| {
        try writeDesktopIconArtifacts(allocator, .{ .name = "game", .platform = plat }, dir, dir);
    }
    const rc_path = try std.fs.path.join(allocator, &.{ dir, windows_rc_rel_path });
    defer allocator.free(rc_path);
    try std.testing.expectError(error.FileNotFound, cwd.access(io, rc_path, .{}));
}
