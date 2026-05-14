/// Type definitions for the labelle-cli generator.
/// Pure types — no template or I/O dependencies.
const std = @import("std");
const builtin = @import("builtin");

/// Process-wide Io handle used by helpers in cache.zig / scanner.zig / etc.
/// that historically used `std.fs.cwd()` (which no longer exists on 0.16).
/// Must be initialized from `main()` by calling `initGlobalIo()` with the
/// process Init block, so the underlying Threaded impl sees the real env.
///
/// Tests don't call `main`, so `globalIo()` lazy-initializes a default
/// Threaded instance with empty argv0 / environ on first access.
var _global_threaded: std.Io.Threaded = undefined;
var _global_io: std.Io = undefined;
var _global_environ: std.process.Environ = .empty;
var _global_io_initialized: bool = false;

/// Initialize the process-wide Io. Call once from main() before any helpers
/// access globalIo(). The provided minimal block is forwarded into a
/// Threaded instance whose lifetime is the rest of the process.
pub fn initGlobalIo(minimal: std.process.Init.Minimal) void {
    _global_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .argv0 = .init(minimal.args),
        .environ = minimal.environ,
    });
    _global_io = _global_threaded.io();
    _global_environ = minimal.environ;
    _global_io_initialized = true;
}

pub fn globalIo() std.Io {
    if (!_global_io_initialized) {
        _global_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        _global_io = _global_threaded.io();
        _global_io_initialized = true;
    }
    return _global_io;
}

pub fn globalEnviron() std.process.Environ {
    if (builtin.is_test) return std.testing.environ;
    return _global_environ;
}

/// Graphics / windowing backend selection. `null` is a headless backend
/// (no graphics context, no input, no audio, no window) that drives the
/// generated `main()` through a fixed-frame tick loop — used for
/// lifecycle / determinism / integration tests that don't exercise
/// rendering. See `backends/null/` for the no-op implementations.
pub const Backend = enum { raylib, sokol, sdl, bgfx, wgpu, null };
pub const Platform = enum { desktop, ios, android, wasm };
pub const EcsChoice = enum { mock, zig_ecs, zflecs, mr_ecs };

/// CLI version — injected from root build.zig via build options.
pub const CLI_VERSION = @import("build_options").cli_version;

/// Library versions — from versions.zon, injected via build options.
/// These are the tested compatible versions for this CLI release.
pub const CORE_VERSION = @import("build_options").core_version;
pub const ENGINE_VERSION = @import("build_options").engine_version;
pub const GFX_VERSION = @import("build_options").gfx_version;

/// A plugin dependency declared in project.labelle.
/// Plugins are external packages with a repo URL and version tag.
/// Use `repo = "local:../../path"` for local development overrides.
pub const PluginDep = struct {
    name: []const u8,
    repo: []const u8 = "",
    version: []const u8 = "",
    /// Game states this plugin runs in. Empty = all states (plugin default).
    /// Overrides the plugin's own `Systems.game_states` if set.
    states: []const []const u8 = &.{},

    /// Returns true if this plugin uses a local path.
    /// Supports `local:../path` (relative to project) and `@libs/path` (inside project).
    pub fn isLocal(self: PluginDep) bool {
        return std.mem.startsWith(u8, self.repo, "local:") or
            std.mem.startsWith(u8, self.repo, "@");
    }

    /// Returns the local path portion of the repo string.
    /// `local:../foo` → `../foo`, `@libs/foo` → `libs/foo`.
    pub fn localPath(self: PluginDep) []const u8 {
        if (std.mem.startsWith(u8, self.repo, "local:"))
            return self.repo["local:".len..];
        if (std.mem.startsWith(u8, self.repo, "@"))
            return self.repo["@".len..];
        return self.repo;
    }
};

// ── iOS Configuration ──────────────────────────────────────────────

pub const Orientation = enum { portrait, landscape, all };

pub const IosConfig = struct {
    app_name: []const u8 = "",
    bundle_id: []const u8 = "",
    team_id: []const u8 = "",
    minimum_ios: []const u8 = "15.0",
    orientation: Orientation = .all,
    device_family: []const u8 = "1,2",
};

// ── Android Configuration ──────────────────────────────────────────

pub const AndroidConfig = struct {
    app_name: []const u8 = "",
    package_name: []const u8 = "", // e.g. "com.labelle.mygame"
    min_sdk_version: u32 = 28, // Android 9 (Pie) — NativeActivity + GLES3
    target_sdk_version: u32 = 34, // Android 14
    orientation: Orientation = .all,
};

pub const LayerSpace = enum { world, screen, screen_fill };

pub const LayerDef = struct {
    name: []const u8,
    order: i8 = 0,
    space: LayerSpace = .world,
};

/// Half-open codepoint range `[first, last)` baked into a font atlas.
/// Structurally identical to `labelle-gfx`'s `CodepointRange` and
/// `labelle-engine`'s `font_types.CodepointEntry` source range — the
/// assembler copies field-by-field at codegen time to bridge nominal
/// type differences across the three repos.
pub const CodepointRange = struct {
    first: u32,
    last: u32,
};

/// Bake-time parameters for a font resource. Carried alongside the
/// `.ttf` / `.otf` bytes into the font loader's `decode` via the
/// catalog's `WorkRequest.params` slot (`?*const anyopaque`). The
/// loader casts back to `*const engine.FontBakeParams`, then the
/// assembler-generated `FontBackendAdapter.decode` copies into the
/// graphics backend's mirror struct (labelle-gfx#258's
/// `FontBakeParams`) before calling `decodeFont`.
///
/// Defaults match the engine + gfx contracts: 16 px pixel height,
/// ASCII printable range (0x20..0x7F), 512×512 atlas.
pub const FontBakeParams = struct {
    pixel_height: f32 = 16,
    ranges: []const CodepointRange = &.{ .{ .first = 0x20, .last = 0x7F } },
    atlas_width: u32 = 512,
    atlas_height: u32 = 512,
};

/// Discriminator for `ResourceDef`. Picked by inspecting which of the
/// resource's path fields are populated; validation rejects entries
/// that set more than one or none. Drives the assembler's emission
/// dispatch: atlas → `loadAtlasFromMemory`, sound →
/// `loadSoundFromMemory`, font → `loadFontFromMemory`.
pub const ResourceKind = enum {
    atlas,
    sound,
    font,
    invalid,
};

/// Sentinel returned by `ResourceDef.validate` to surface what went
/// wrong with a malformed entry. The CLI maps these to actionable
/// stderr diagnostics before bailing.
pub const ResourceValidationError = enum {
    ok,
    /// No asset-path field set — caller forgot to declare what this
    /// resource points at. Tell the user to add `.json`/`.texture`
    /// (atlas), `.sound`, or `.font`.
    no_path,
    /// More than one of `.json`+`.texture` / `.sound` / `.font` set
    /// on the same entry. A resource is exactly one asset kind.
    multiple_paths,
    /// Atlas is half-declared: one of `.json` / `.texture` is set
    /// but not the other. Both are required for an atlas resource.
    atlas_incomplete,
    /// `.font_params` set on a non-font resource. Indicates a typo
    /// — e.g. user meant `.font = "..."` but wrote `.font_params`
    /// on an atlas or sound entry.
    font_params_misplaced,
};

pub const ResourceDef = struct {
    name: []const u8,

    // ── Atlas (legacy image resource — JSON sprite map + PNG/RGBA texture)
    json: []const u8 = "",
    texture: []const u8 = "",

    // ── Sound (Phase 4, #447). `.wav` / `.ogg` path relative to the
    // project root. Mutually exclusive with the atlas / font paths.
    sound: []const u8 = "",

    // ── Font (Phase 4, #448). `.ttf` / `.otf` path. Pairs with
    // `font_params` to control the bake (pixel size + glyph ranges +
    // atlas dimensions). Mutually exclusive with atlas / sound paths.
    font: []const u8 = "",

    /// Bake parameters for font resources. Ignored on atlas/sound
    /// entries — `validate()` reports `font_params_misplaced` if set
    /// alongside `.json` / `.texture` / `.sound`. Default applies
    /// when the user omits `font_params` on a font resource: 16 px,
    /// ASCII printable, 512×512 atlas — matches the engine + gfx
    /// `FontBakeParams` defaults.
    font_params: ?FontBakeParams = null,

    /// Controls whether this resource is decoded eagerly at `init()`
    /// time or deferred until a script calls
    /// `game.loadAtlasIfNeeded(name)` / `loadSoundIfNeeded(name)` /
    /// `loadFontIfNeeded(name)`.
    ///
    /// Applies to all three resource kinds. The `lazy_inference` pass
    /// (ticket #48) fills in `null` based on whether any scene's
    /// `assets:` block references the name; explicit values always
    /// win.
    ///
    /// - `null` (field omitted): the assembler picks a default.
    ///   Lazy when the resource appears in any scene's `assets:`
    ///   list, eager otherwise.
    /// - `true`: always lazy — generated init calls `register*FromMemory`.
    /// - `false`: always eager — generated init calls `load*FromMemory`.
    lazy: ?bool = null,

    /// Classify which kind of asset this resource declares, based on
    /// which path fields are populated. Returns `.invalid` for empty
    /// or multi-kind entries — call `validate()` for the structured
    /// reason.
    pub fn kind(self: ResourceDef) ResourceKind {
        const has_atlas = self.json.len > 0 or self.texture.len > 0;
        const has_sound = self.sound.len > 0;
        const has_font = self.font.len > 0;
        const count: u8 = @as(u8, @intFromBool(has_atlas)) + @intFromBool(has_sound) + @intFromBool(has_font);
        if (count != 1) return .invalid;
        if (has_atlas) {
            // Both halves of the atlas pair must be set; one-without-
            // the-other is .invalid so the caller surfaces a clear
            // diagnostic instead of generating broken codegen.
            if (self.json.len == 0 or self.texture.len == 0) return .invalid;
            return .atlas;
        }
        if (has_sound) return .sound;
        return .font;
    }

    /// Structured validation result. The CLI translates the enum
    /// variants into actionable stderr diagnostics that point at the
    /// offending `name` and tell the user what to add or remove.
    pub fn validate(self: ResourceDef) ResourceValidationError {
        const has_atlas = self.json.len > 0 or self.texture.len > 0;
        const has_sound = self.sound.len > 0;
        const has_font = self.font.len > 0;
        const count: u8 = @as(u8, @intFromBool(has_atlas)) + @intFromBool(has_sound) + @intFromBool(has_font);
        if (count == 0) return .no_path;
        if (count > 1) return .multiple_paths;
        if (has_atlas and (self.json.len == 0 or self.texture.len == 0)) return .atlas_incomplete;
        if (self.font_params != null and !has_font) return .font_params_misplaced;
        return .ok;
    }
};

/// Returns true if a version string is a local path override.
pub fn isLocalVersion(version: []const u8) bool {
    return std.mem.startsWith(u8, version, "local:");
}

/// Returns the path portion of a "local:..." version string.
pub fn localVersionPath(version: []const u8) []const u8 {
    return version["local:".len..];
}

// ── GUI Plugin System ────────────────────────────────────────────────

/// GUI plugin reference as declared in project.labelle.
/// Parsed from ZON: `.gui = .{ .path = "../plugins/imgui" }` or
/// `.gui = .{ .package = "labelle_imgui", .version = "0.2.0" }`.
/// `.gui = .{ .plugin = "imgui" }` — references a declared plugin by name.
/// When null in ProjectConfig, means no GUI (StubGui).
pub const GuiPlugin = struct {
    path: ?[]const u8 = null,
    /// Reference a declared plugin by name (from .plugins list).
    plugin: ?[]const u8 = null,
    package: ?[]const u8 = null,
    version: ?[]const u8 = null,
    url: ?[]const u8 = null,
    hash: ?[]const u8 = null,
};

/// How a GUI plugin renders — determines whether a bridge is needed.
pub const RenderingMode = enum { render_interface, raw_backend };

/// Lifecycle hooks declared by a GUI plugin.
pub const GuiLifecycle = struct {
    init: bool = false,
    shutdown: bool = false,
};

/// Resolved GUI plugin — populated by the CLI after parsing project.labelle
/// and reading the plugin's gui.labelle manifest. Generators use this,
/// not the raw GuiPlugin reference.
pub const ResolvedGui = struct {
    name: []const u8,
    rendering: RenderingMode,
    lifecycle: GuiLifecycle = .{},
    plugin_dir: []const u8,
    /// Absolute path to bridge directory (raw_backend only).
    bridge_dir: ?[]const u8 = null,
    /// Bridge artifact name (e.g., "rlimgui_bridge", "nuklear_raylib_bridge").
    bridge_artifact: []const u8 = "",
};

pub const ProjectConfig = struct {
    name: []const u8,
    description: []const u8 = "",
    version: []const u8 = "0.1.0",
    title: []const u8 = "LaBelle v2",
    width: u32 = 800,
    height: u32 = 600,
    target_fps: u32 = 60,
    backend: Backend = .raylib,
    platform: Platform = .desktop,
    ecs: EcsChoice = .mock,
    /// GUI plugin reference — parsed from project.labelle.
    /// null means no GUI (StubGui injected).
    gui: ?GuiPlugin = null,
    layers: []const LayerDef = &.{
        .{ .name = "background", .order = 0, .space = .screen },
        .{ .name = "world", .order = 1, .space = .world },
        .{ .name = "ui", .order = 2, .space = .screen },
    },

    // Framework version pinning (defaults from versions.zon)
    core_version: []const u8 = CORE_VERSION,
    engine_version: []const u8 = ENGINE_VERSION,
    gfx_version: []const u8 = GFX_VERSION,
    labelle_version: []const u8 = CLI_VERSION,

    /// Explicit initial scene name. When set, the generator uses this for the first
    /// `g.setScene()` call instead of relying on filesystem scan order (scene_names[0]).
    initial_scene: ?[]const u8 = null,
    /// Sprite atlas resources — each entry declares a named atlas with frame data and texture.
    resources: []const ResourceDef = &.{},
    /// When true, the window is created hidden (no visible window). Useful for headless testing in CI.
    hidden: bool = false,
    /// When true, embed scene files into the binary via @embedFile (for release builds).
    /// Plugins — each declares its repo and version. Empty = no plugin deps.
    plugins: []const PluginDep = &.{},

    /// Game states for the state machine. Scripts in `scripts/<state>/` only run
    /// when that state is active. First element is the initial state.
    /// Defaults to a single "running" state when omitted.
    states: []const []const u8 = &.{"running"},

    /// iOS configuration — parsed from project.labelle `.ios` section.
    /// Defaults to null (derived from project name/title when absent).
    ios: ?IosConfig = null,

    /// Android configuration — parsed from project.labelle `.android` section.
    android: ?AndroidConfig = null,

    /// Pinned assembler version (Phase 3 of RFC #122).
    /// When set, the CLI resolves the assembler binary from the cache at
    /// `~/.labelle/assembler/<version>/labelle-assembler` instead of using
    /// the in-process generator. The LABELLE_ASSEMBLER env var overrides this.
    assembler_version: ?[]const u8 = null,

    /// Resolved GUI plugin — populated by the CLI after reading gui.labelle manifest.
    /// NOT parsed from ZON. Generators check this field, not `gui`.
    resolved_gui: ?ResolvedGui = null,

    /// Check if a plugin is enabled by name.
    pub fn hasPlugin(self: ProjectConfig, name: []const u8) bool {
        for (self.plugins) |p| {
            if (std.mem.eql(u8, p.name, name)) return true;
        }
        return false;
    }

    /// Get a plugin by name.
    pub fn getPlugin(self: ProjectConfig, name: []const u8) ?PluginDep {
        for (self.plugins) |p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }

    /// Returns true if a GUI plugin is resolved and active.
    pub fn hasGui(self: ProjectConfig) bool {
        return self.resolved_gui != null;
    }
};
