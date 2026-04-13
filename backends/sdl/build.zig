const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // SDL2 install prefix. On Linux and Windows, SDL2 headers and
    // libraries live in system-wide paths that Zig finds automatically;
    // no prefix is needed. On macOS, SDL2 is typically installed via
    // Homebrew under /opt/homebrew (Apple Silicon) or /usr/local
    // (Intel), and Zig doesn't search those by default.
    //
    // Override via `-Dsdl-prefix=/custom/path` for non-standard installs.
    const sdl_prefix: []const u8 = b.option(
        []const u8,
        "sdl-prefix",
        "SDL2 install prefix (auto-detected on macOS Homebrew, unused on Linux/Windows)",
    ) orelse detectSdlPrefix(target.result.os.tag);

    // Shared SDL2 C import module — ensures a single set of opaque types.
    // Only include/library *paths* are set here for @cImport resolution.
    // Actual linkSystemLibrary calls are deferred to the final executable
    // to prevent duplicate dylib entries when multiple modules import sdl.
    const sdl_mod = b.addModule("sdl", .{
        .root_source_file = b.path("src/sdl.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSdlPaths(b, sdl_mod, sdl_prefix);

    // ── Gfx backend module ──────────────────────────────────────────
    const gfx_mod = b.addModule("gfx", .{
        .root_source_file = b.path("src/gfx.zig"),
        .target = target,
        .optimize = optimize,
    });
    gfx_mod.addImport("sdl", sdl_mod);

    // ── Input backend module ────────────────────────────────────────
    const input_mod = b.addModule("input", .{
        .root_source_file = b.path("src/input.zig"),
        .target = target,
        .optimize = optimize,
    });
    input_mod.addImport("sdl", sdl_mod);

    // ── Audio backend module ────────────────────────────────────────
    // audio.zig has its own @cImport for SDL_mixer, so it needs the
    // paths directly; cImports don't propagate through module imports.
    const audio_mod = b.addModule("audio", .{
        .root_source_file = b.path("src/audio.zig"),
        .target = target,
        .optimize = optimize,
    });
    audio_mod.addImport("sdl", sdl_mod);
    addSdlPaths(b, audio_mod, sdl_prefix);

    // ── Window backend module ───────────────────────────────────────
    const window_mod = b.addModule("window", .{
        .root_source_file = b.path("src/window.zig"),
        .target = target,
        .optimize = optimize,
    });
    window_mod.addImport("sdl", sdl_mod);
    window_mod.addImport("gfx", gfx_mod);
    window_mod.addImport("input", input_mod);
    window_mod.addImport("audio", audio_mod);
}

/// Probe common macOS Homebrew prefixes for an SDL2 install. Returns
/// an empty string on Linux/Windows (system search handles it) or if
/// no SDL2 install is found.
fn detectSdlPrefix(os_tag: std.Target.Os.Tag) []const u8 {
    if (os_tag != .macos) return "";
    if (dirExists("/opt/homebrew/include/SDL2")) return "/opt/homebrew";
    if (dirExists("/usr/local/include/SDL2")) return "/usr/local";
    return "";
}

fn addSdlPaths(b: *std.Build, mod: *std.Build.Module, prefix: []const u8) void {
    if (prefix.len == 0) return;
    const include_path = b.pathJoin(&.{ prefix, "include" });
    const lib_path = b.pathJoin(&.{ prefix, "lib" });
    mod.addIncludePath(.{ .cwd_relative = include_path });
    mod.addLibraryPath(.{ .cwd_relative = lib_path });
}

fn dirExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}
