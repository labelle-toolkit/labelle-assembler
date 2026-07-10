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

/// Interpret the `LABELLE_EDITOR_PREVIEW` env-var value (labelle-studio Play
/// mode). Documented spelling is `LABELLE_EDITOR_PREVIEW=1`; `true` is
/// accepted as a courtesy alias. Anything else — including `0`, `false`, and
/// the empty string — is OFF, so `LABELLE_EDITOR_PREVIEW=0` explicitly
/// disables preview even when a wrapper exported the var. Pure so the parsing
/// rule is unit-testable without touching the process environment.
pub fn editorPreviewEnvEnabled(value: []const u8) bool {
    return std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true");
}

test "editorPreviewEnvEnabled: '1'/'true' enable; '0'/'false'/empty/garbage don't" {
    try std.testing.expect(editorPreviewEnvEnabled("1"));
    try std.testing.expect(editorPreviewEnvEnabled("true"));
    try std.testing.expect(!editorPreviewEnvEnabled("0"));
    try std.testing.expect(!editorPreviewEnvEnabled("false"));
    try std.testing.expect(!editorPreviewEnvEnabled(""));
    try std.testing.expect(!editorPreviewEnvEnabled("yes"));
    try std.testing.expect(!editorPreviewEnvEnabled("TRUE"));
}

/// Graphics / windowing backend selection. `null` is a headless backend
/// (no graphics context, no input, no audio, no window) that drives the
/// generated `main()` through a fixed-frame tick loop — used for
/// lifecycle / determinism / integration tests that don't exercise
/// rendering. Extracted out-of-tree — see the labelle-null package for the
/// no-op implementations (resolved via builtinProvider, #386 Phase 6c).
pub const Backend = enum { raylib, sokol, sdl, bgfx, wgpu, null };
pub const Platform = enum { desktop, ios, android, wasm };

/// A capability a backend provider may declare it supports (and a project may
/// require). This is the DECLARATIVE MIRROR of the `@hasDecl`-gated optional
/// backend decls (RFC "Opening the ecosystem — Capability negotiation",
/// §1645-1683): the optional decl is the *mechanism*, the capability flag is
/// the *advertisement* the resolver reads WITHOUT compiling the provider, so a
/// missing capability surfaces as an early project-level error instead of a
/// deep `@compileError` in generated `main.zig`.
///
/// The set is the RFC's core seven (§1656-1665) EXTENDED with the platform
/// capabilities the codegen already branches on (`cfg.platform`) and the
/// OGG-decode backend seam:
///   - `screenshots`         — `takeScreenshot()` (headless CI, preview).
///   - `compressed_textures` — ASTC/KTX2 GPU-native upload path.
///   - `fonts`               — `decodeFont` / `uploadFontAtlas`.
///   - `gamepad_polling`     — the input source provides gamepad state.
///   - `raw_gui_adapter`     — in-backend imgui adapter (not just the C++ bridge).
///   - `headless`            — can run with no window surface.
///   - `surface_loss`        — implements `surfaceLost` / `surfaceRestored` (mobile).
///   - `wasm` / `android` / `ios` — the provider supports building for that platform.
///   - `audio_ogg`           — the provider decodes OGG/Vorbis audio.
///
/// Shared by the manifest parser (`BackendManifest.capabilities`) and the
/// project-side requirement derivation (`capabilities.requiredCapabilities`),
/// so a declared capability and a required capability are the SAME nominal type
/// — no string matching, and adding a variant is caught by the exhaustiveness
/// checker on both sides.
pub const Capability = enum {
    screenshots,
    compressed_textures,
    fonts,
    gamepad_polling,
    raw_gui_adapter,
    headless,
    surface_loss,
    wasm,
    android,
    ios,
    audio_ogg,
};

/// Project logical Y-axis convention (RFC-Y-AXIS-CONVENTION, epic
/// labelle-engine#640). Parsed from `project.labelle`'s `.y_axis` key and
/// emitted onto the generated game's `engine.GameConfigWithYAxis(..., .up|.down)`
/// call (mirrors the engine `core.YAxis` enum).
///
/// - `.up`: `y = 0` at the BOTTOM, +Y goes up — the math-/platformer-natural
///   convention every labelle game shipped with before the convention split.
/// - `.down`: `y = 0` at the TOP, +Y goes down — the screen-native default
///   the framework moves to.
///
/// There is intentionally NO default here in `project.labelle`: an absent
/// `.y_axis` is a hard error during the transition release (the unset-guard),
/// so no existing game silently flips when the framework default becomes
/// `.down`. See `requireYAxis` and RFC §4 / the Migration section.
pub const YAxis = enum { up, down };

/// Texture container a platform ships atlases in. `.png` (source, CPU-decoded
/// at load) or `.astc` (GPU-native compressed, zero decode — see #340).
pub const AssetFormat = enum { png, astc };

/// Per-platform `AssetFormat` selection. ASTC support is mandatory on
/// Android/iOS GLES/Metal and desktop GLES/Metal/Vulkan, but spotty on the web
/// (Safari yes, desktop browsers via extensions) — so the default is `.png`
/// everywhere and each platform opts into `.astc` explicitly.
pub const AssetCompression = struct {
    desktop: AssetFormat = .png,
    android: AssetFormat = .png,
    ios: AssetFormat = .png,
    web: AssetFormat = .png,

    /// The selected format for `platform`.
    pub fn formatFor(self: AssetCompression, platform: Platform) AssetFormat {
        return switch (platform) {
            .desktop => self.desktop,
            .android => self.android,
            .ios => self.ios,
            .wasm => self.web,
        };
    }
};

/// Desktop gamepad source selection (core#28 slice 5).
///
/// The DEFAULT when `.gamepad` is omitted is backend-aware — see
/// `ProjectConfig.effectiveGamepad()`: raylib/sokol default to `.auto`, bgfx
/// defaults to `.none` (assembler#533, bgfx is a pure renderer with no native
/// input so it should not pull SDL unless the project opts in explicitly).
///
/// - `.auto`: the shared windowless-SDL desktop gamepad source
///   (`backends/sdl_gamepad/`) is staged, SDL2 is linked, and the raylib /
///   sokol / bgfx desktop backends route their gamepad queries through it — on
///   ALL desktop OSes including Linux.
/// - `.none`: opt out entirely. `sdl_gamepad` is NOT staged, SDL2 is NOT
///   linked, and both backends' desktop gamepad queries resolve to a
///   truly-disabled path (return false/0/empty). For raylib this means NO
///   GLFW-native fallback — gamepad input is off. No SDL anywhere in the
///   generated build.
///
/// NOTE: a Linux→udev native path (so `.auto` could avoid SDL on Linux) is
/// deferred; `.auto` keeps SDL on Linux for now.
pub const GamepadSource = enum { auto, none };
pub const EcsChoice = enum { mock, zig_ecs, zflecs, mr_ecs };

/// CLI version — injected from root build.zig via build options.
pub const CLI_VERSION = @import("build_options").cli_version;

/// Library versions — from versions.zon, injected via build options.
/// These are the tested compatible versions for this CLI release.
pub const CORE_VERSION = @import("build_options").core_version;
pub const ENGINE_VERSION = @import("build_options").engine_version;
pub const GFX_VERSION = @import("build_options").gfx_version;

/// This assembler binary's own version — stamped into `assembler_version`
/// of a freshly scaffolded project.labelle by the `init` subcommand.
/// Defaults to the package version (build.zig.zon) via build options.
pub const ASSEMBLER_VERSION = @import("build_options").assembler_version;

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

    /// Plugin-specific parameters — the generic `.params` bag (assembler#584
    /// design review). Plugin options deliberately do NOT become bespoke
    /// `PluginDep` fields; they ride this one nested literal:
    ///
    ///     .{ .name = "scripting", .repo = "github.com/labelle-toolkit/labelle-scripting",
    ///        .version = "…", .params = .{ .language = "lua" } },
    ///
    /// `Params` below is the v1 slice of the mechanism. `null` = the plugin
    /// takes no parameters (every entry before #584) → byte-identical default.
    params: ?Params = null,

    /// V1 slice of the GENERIC plugin-params mechanism: a closed struct whose
    /// only recognized parameter today is `.language`. Schema-declared params
    /// — each plugin publishing the keys it accepts, the assembler validating
    /// `.params` against that schema — land with the plugin params follow-up
    /// ticket; widening this struct in the meantime is additive. An unknown
    /// key inside `.params` is a hard parse error BY CONSTRUCTION: the
    /// project.labelle parse runs with the default
    /// `ignore_unknown_fields = false`, so a stray key fails with
    /// `error.ParseZon` exactly like a typo'd key on the plugin entry itself —
    /// nothing silently drops.
    pub const Params = struct {
        /// Script language this plugin provides (RFC-LANGUAGE-PLUGINS revs
        /// 8–9, epic labelle-engine#237, assembler#584). Set on the ONE
        /// scripting plugin entry (`labelle-scripting`):
        /// `.params = .{ .language = "lua" }`. Deliberately SINGULAR — one
        /// script language per project; mixing is unrepresentable in config.
        /// Validated at generate time (`language_policy`): the value must be
        /// a supported language and at most one `.plugins` entry may set it.
        /// Parse + validate only for now — no codegen consumes it yet (the
        /// scripting plugin that does lands separately).
        language: ?[]const u8 = null,
    };

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
    /// Launch the game fullscreen with the status bar and title bar
    /// hidden, via the built-in `Theme.NoTitleBar.Fullscreen` Android
    /// framework theme (no custom APK resources required).
    ///
    /// Scope: this covers the **status bar** and title bar only. It does
    /// NOT hide the Android **navigation bar** (the on-screen
    /// back/home/recents buttons) — true immersive-sticky nav-bar hiding
    /// requires runtime native code (JNI `WindowInsetsController` calls)
    /// and is a planned follow-up.
    immersive_mode: bool = false,
};

pub const LayerSpace = enum { world, screen, screen_fill };

pub const LayerDef = struct {
    name: []const u8,
    order: i8 = 0,
    space: LayerSpace = .world,
    /// Optional camera tag binding (Camera-Bound Layers RFC, engine#723/#724).
    /// When set, this layer's `gfx.LayerConfig` carries `.camera = "<tag>"`,
    /// binding the layer to the camera registered under that tag. `null` (the
    /// default) emits the pre-RFC `LayerConfig` literal byte-for-byte, so
    /// projects that author no binding see zero output drift. Validated at
    /// generate time: the tag must be ≤ 15 chars and a valid identifier
    /// (`[A-Za-z_][A-Za-z0-9_]*`).
    ///
    /// REQUIRES gfx ≥ 1.26.0 (the release that adds `LayerConfig.camera`). The
    /// assembler stays version-agnostic by design (RFC: "passes the tag through
    /// verbatim, no resolution at generate time"), so authoring `.camera` on an
    /// older gfx pin makes the generated `main.zig` fail to compile on that
    /// field. Opt-in: only projects that use the binding take on the floor.
    camera: ?[]const u8 = null,
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

/// Whether `version` looks like a semantic version number — i.e. it starts
/// with a digit (`1.2.3`, `0.31.0`, `2`). Used to decide how a version maps
/// to a git ref: semver-shaped versions are published as `v`-prefixed tags
/// (`v1.2.3`), while anything else is treated as a branch / ref name.
pub fn isSemverVersion(version: []const u8) bool {
    // A package release version is digits and dots only, with at least
    // one dot (`1.13.0`, `0.31.0`). "Starts with a digit" was too loose
    // — a digit-leading branch ref like `159-fix` or `2026/dev` would be
    // mis-classified and clone-mangled into `v159-fix` (#159 review).
    if (version.len == 0 or !std.ascii.isDigit(version[0])) return false;
    var has_dot = false;
    for (version) |c| {
        if (c == '.') {
            has_dot = true;
        } else if (!std.ascii.isDigit(c)) {
            return false;
        }
    }
    return has_dot;
}

/// Map a package `version` string to the git ref to clone.
///
/// A semver-shaped version (`1.2.3`) maps to the published release tag
/// `v1.2.3`. Anything else — `dev`, `main`, a feature-branch name — is a
/// ref in its own right and is used verbatim. Blindly prepending `v` to a
/// non-numeric version produced bogus refs like `vdev` that failed deep
/// inside `git clone` (issue #159).
///
/// Returns an allocator-owned slice; the caller frees it.
pub fn versionToGitRef(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    if (isSemverVersion(version)) {
        return std.fmt.allocPrint(allocator, "v{s}", .{version});
    }
    return allocator.dupe(u8, version);
}

test "versionToGitRef: semver versions get a `v` prefix" {
    const alloc = std.testing.allocator;
    inline for (.{
        .{ "1.2.3", "v1.2.3" },
        .{ "0.31.0", "v0.31.0" },
        .{ "1.13.0", "v1.13.0" },
    }) |case| {
        const ref = try versionToGitRef(alloc, case[0]);
        defer alloc.free(ref);
        try std.testing.expectEqualStrings(case[1], ref);
    }
}

test "versionToGitRef: non-numeric versions are used verbatim as a ref" {
    const alloc = std.testing.allocator;
    // The #159 regression: `dev` must not become `vdev`. Digit-leading
    // branch refs (`159-fix`, `2026/dev`) must also pass through verbatim
    // — they are not semver despite the leading digit.
    inline for (.{ "dev", "main", "feature/foo", "159-fix", "2026/dev" }) |branch| {
        const ref = try versionToGitRef(alloc, branch);
        defer alloc.free(ref);
        try std.testing.expectEqualStrings(branch, ref);
    }
}

test "isSemverVersion: classifies version strings" {
    try std.testing.expect(isSemverVersion("1.0.0"));
    try std.testing.expect(isSemverVersion("0.31.0"));
    try std.testing.expect(!isSemverVersion("dev"));
    try std.testing.expect(!isSemverVersion("main"));
    try std.testing.expect(!isSemverVersion(""));
    // Digit-leading branch refs are not semver.
    try std.testing.expect(!isSemverVersion("159-fix"));
    try std.testing.expect(!isSemverVersion("2026/dev"));
    try std.testing.expect(!isSemverVersion("159")); // no dot — treated as a ref
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
    /// External graphics backend declared by NAME + package (epic #386 Phase 5,
    /// the open-config seam). When set, the backend is *external*: it is named
    /// and located through the plugin-resolution infra (the registry +
    /// `resolvePlugin`) exactly like a plugin, and the closed `.backend` enum is
    /// IGNORED. When null (the default), the built-in `.backend` enum is the
    /// selection — that fast-path is unchanged and byte-identical.
    ///
    /// Reuses `PluginDep` so an external backend can live anywhere a plugin can:
    /// a `local:../path` checkout, an `@libs/...` in-project dir, or a fetched
    /// `github` repo. The package follows the SAME `backends/{name}` convention
    /// the registry derives (`labelle_{name}` zon dep, `labelle-{name}` link),
    /// and MUST ship a `backend.manifest.zon` — the manifest splice is its only
    /// codegen route (see `isExternal` / `backend_registry.resolveBackendPackage`).
    backend_package: ?PluginDep = null,
    /// Capabilities the project EXPLICITLY requires of its resolved backend
    /// provider (RFC "Capability negotiation", §1668). This is the explicit
    /// half of the required set; the other half is DERIVED by the assembler
    /// from the platform / GUI / asset-compression selection (see
    /// `capabilities.requiredCapabilities`). A CI screenshot target, whose
    /// need isn't derivable from a `project.labelle` field, declares
    /// `.requires = &.{ .screenshots }` here. Defaults empty — an ordinary
    /// desktop project derives everything and lists nothing.
    requires: []const Capability = &.{},
    platform: Platform = .desktop,
    /// Logical Y-axis convention (RFC-Y-AXIS-CONVENTION / epic
    /// labelle-engine#640). Emitted onto the generated game's
    /// `engine.GameConfigWithYAxis(..., .up|.down)` call. Optional in the
    /// struct so the assembler can detect an *absent* key and raise the
    /// transition-release unset-guard (`requireYAxis`) — an unset `.y_axis`
    /// must be a hard error so no existing game silently flips. Existing
    /// (y-up) games declare `.y_axis = .up`; new screen-native projects use
    /// `.y_axis = .down`.
    y_axis: ?YAxis = null,
    ecs: EcsChoice = .mock,
    /// Desktop gamepad source. `.auto` stages + links + routes the shared SDL
    /// desktop gamepad source for raylib/sokol/bgfx desktop; `.none` opts out
    /// entirely (no SDL, truly-disabled gamepad). See `GamepadSource`.
    ///
    /// OPTIONAL so an ABSENT key (`null`) is distinguishable from an explicit
    /// `.auto`: the two must resolve differently on bgfx. NEVER read this field
    /// directly — always go through `effectiveGamepad()`, which applies the
    /// backend-aware default (bgfx → `.none`, all other desktop backends →
    /// `.auto`). See that method for the rationale.
    gamepad: ?GamepadSource = null,
    /// Opt into SDL's HIDAPI raw-HID driver for the desktop gamepad source.
    /// HIDAPI decodes Nintendo/8BitDo Switch-mode pads that GLFW/sokol can't,
    /// but its per-connect device init blocks the render thread for ~2-3s on
    /// some platforms (notably macOS Bluetooth Xbox pads). OFF by default — the
    /// OS-native controller driver handles Xbox/PlayStation/standard pads with
    /// no hitch. Set `true` only when you need Switch raw-HID decode and accept
    /// the connect stall. No effect when `gamepad = .none`.
    gamepad_hidapi: bool = false,
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

    /// Explicit initial prefab name. When set, the generator emits this prefab for
    /// startup instead of relying on filesystem scan order (`jsonc_scene_names[0]`,
    /// i.e. the first discovered scene in `scenes/*.jsonc`). Part of RFC #560
    /// (unify scenes and prefabs): `.initial_scene` was renamed to `.initial_prefab`
    /// for symmetry with the unified vocabulary.
    initial_prefab: ?[]const u8 = null,
    /// Deprecated legacy alias for `initial_prefab`. Still accepted in `project.labelle`
    /// for one or two release cycles (RFC #560 / issue #565). When both are present,
    /// `initial_prefab` wins. Prefer reading `resolvedInitialPrefab()` instead of this
    /// field directly so the legacy alias is honored consistently.
    initial_scene: ?[]const u8 = null,
    /// Sprite atlas resources — each entry declares a named atlas with frame data and texture.
    resources: []const ResourceDef = &.{},
    /// Per-platform texture-compression selection. When a platform is set to
    /// `.astc`, the generator references each atlas's pre-converted `<name>.astc`
    /// sibling (produced by `labelle astc`) instead of the source `.png`, so the
    /// engine uploads GPU-native compressed blocks with zero CPU decode
    /// (labelle-gfx#269 / #340). Defaults to `.png` everywhere — fully opt-in,
    /// and falls back to the `.png` when no `.astc` sibling exists.
    asset_compression: AssetCompression = .{},

    /// Project app icon / launch image, as a path relative to the project
    /// root (e.g. `"assets/icon.png"`).
    ///
    /// Today this field only governs default-icon injection: when it is
    /// null or empty the assembler injects a bundled default "Labelle"
    /// branded icon so a freshly scaffolded game doesn't surface a blank
    /// OS window icon / stock Android launcher icon (issue #66); setting
    /// a non-empty path suppresses the default. Wiring the icon through
    /// to the platform launcher (Android `ic_launcher` mipmaps, desktop
    /// window icon) is a follow-up.
    app_icon: ?[]const u8 = null,
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

    /// Editor-preview build (labelle-studio Play mode, wasm only). Not meant
    /// to be set in `project.labelle` — activated per-generation by the
    /// `LABELLE_EDITOR_PREVIEW=1` env var (read in `generate`; the studio
    /// spawns `labelle build --platform=wasm` with it set and the env
    /// propagates through the CLI into the assembler child) or by the
    /// assembler's own `--editor-preview` flag. When true AND the platform is
    /// wasm, the generated wasm main.zig binds the engine's `editor_api`
    /// (bind / shouldTick sim gate / per-frame editor sync) and the generated
    /// build.zig threads `.editor_preview = true` into the backend hook's
    /// `post_wire` so the emcc link keeps the `editor_*` exports alive.
    /// `generate` normalizes this OFF for every non-wasm platform, so a
    /// stray env var can never perturb a desktop/android/ios build.
    editor_preview: bool = false,

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

    /// Provider package a BUILT-IN `.backend` enum tag resolves to. As of #386
    /// Phase 6c ALL six backends are extracted out-of-tree, so every arm returns
    /// a provider package and production codegen is fully backend-agnostic. The
    /// return type stays optional for callers, but there are no `null` arms.
    ///
    /// This is the enum-as-shorthand seam (epic #386, Phase 5): the closed
    /// `Backend` enum stays as the backward-compatible spelling, but a tag is
    /// just a *shorthand* for a provider. `.backend = .<tag>` transparently
    /// resolves to the fetched package (`isExternal()` ⇒ true) with no
    /// project-config change.
    fn builtinProvider(backend: Backend) ?PluginDep {
        return switch (backend) {
            // Extracted out-of-tree (#386 Phase 6c) — `.backend = .<tag>` resolves
            // to the provider package, not a bundled slot.
            // 0.6.x ships the editor-preview wasm template holes + hook field
            // (labelle-bgfx#25, comment fix in 0.6.2) — paired with this
            // assembler's LABELLE_EDITOR_PREVIEW support so a preview build
            // resolves a hole-bearing backend. 0.6.3 grows the emcc export
            // list with `_editor_set_state` (editor contract v1.1). 0.6.4
            // declares the bgfx-Android callback lifecycle SHAPE in its v2
            // manifest (#461), so the assembler selects it from data instead of
            // the `is_bgfx_android` enum branch. The hole-bearing wasm template
            // requires assembler ≥ 0.74.0. 0.6.5 honors an external EMSDK for a
            // host-managed emsdk (assembler#535 / labelle-studio#25) — paired
            // with this assembler's EMSDK-aware preflight (#536). 0.6.6 =
            // labelle-bgfx#30 fix: don't auto-select Direct3D on Windows (was
            // crashing at first sprite draw — engine#683) + #31 desktop-video
            // Windows fix.
            .bgfx => .{ .name = "bgfx", .repo = "github.com/labelle-toolkit/labelle-bgfx", .version = "0.6.6" },
            .wgpu => .{ .name = "wgpu", .repo = "github.com/labelle-toolkit/labelle-wgpu", .version = "0.3.0" },
            .null => .{ .name = "null", .repo = "github.com/labelle-toolkit/labelle-null", .version = "0.3.0" },
            .sdl => .{ .name = "sdl", .repo = "github.com/labelle-toolkit/labelle-sdl", .version = "0.3.1" },
            .raylib => .{ .name = "raylib", .repo = "github.com/labelle-toolkit/labelle-raylib", .version = "0.3.0" },
            // 0.2.1 declares the sokol callback lifecycle SHAPE in its v2
            // manifest (#461) — the assembler selects it from data instead of
            // the `cfg.backend == .sokol` enum branch.
            .sokol => .{ .name = "sokol", .repo = "github.com/labelle-toolkit/labelle-sokol", .version = "0.2.1" },
        };
    }

    /// The provider package this config effectively resolves its backend from,
    /// or `null` when the backend is bundled. An explicit `.backend_package`
    /// always wins; otherwise a built-in enum tag may resolve to a provider via
    /// `builtinProvider` (the enum-as-shorthand). This is the ONE place that
    /// composes the two, so `backendName()` / `isExternal()` /
    /// `backend_registry.resolveBackendPackage` all agree on whether a backend
    /// is external and which package it is.
    pub fn effectiveBackendPackage(self: ProjectConfig) ?PluginDep {
        return self.backend_package orelse builtinProvider(self.backend);
    }

    /// The canonical backend NAME as a string (e.g. "bgfx").
    ///
    /// This is the pluggable-backends seam (epic #386, Phase 5): name-layer
    /// code reads `backendName()` instead of `@tagName(self.backend)` directly,
    /// so the package-layout conventions (see `backend_registry`) are derived
    /// from a string rather than a closed enum tag. For a bundled built-in this
    /// is just the enum tag; for an external backend (explicit package OR an
    /// enum tag that resolves to a provider) it's the provider name.
    pub fn backendName(self: ProjectConfig) []const u8 {
        if (self.effectiveBackendPackage()) |bp| return bp.name;
        return @tagName(self.backend);
    }

    /// Resolve the effective desktop gamepad source, applying the backend-aware
    /// default when `.gamepad` is ABSENT from project.labelle (assembler#533).
    ///
    /// An explicit `.gamepad` (either `.auto` or `.none`) is honored verbatim on
    /// EVERY backend — writing `.gamepad = .auto` on a bgfx project still links
    /// SDL2. Only when the key is OMITTED does the default kick in:
    ///
    ///   - `.bgfx` → `.none`. bgfx is a pure renderer with no native input, so
    ///     `.auto` would silently pull in SDL2 — a heavyweight system dependency
    ///     that's painful on Windows. A bgfx project should build with zero
    ///     system deps by default and opt into gamepad explicitly.
    ///   - every other desktop backend (raylib/sokol/sdl/…) → `.auto`, the
    ///     historical default (unchanged).
    ///
    /// We key off the `.bgfx` ENUM TAG, not `backendName()` (assembler#534
    /// review evaluated + rejected the name/capability alternatives):
    ///   - The tag `.bgfx` IS the canonical identity of the built-in bgfx: the
    ///     rest of the gamepad wiring (`deps_linker.stagesSdlGamepad`'s
    ///     `switch (cfg.backend)`) already keys off it, so routing this decision
    ///     through the same tag keeps the two in lockstep. A `.backend = .bgfx`
    ///     project retains that tag even when it resolves to a fetched provider
    ///     package (the enum-as-shorthand), so the tag is present on the real
    ///     production path.
    ///   - `backendName()` is NOT a reliable "is bgfx" signal: it returns the
    ///     resolved PACKAGE name, which is not guaranteed to be "bgfx" — the
    ///     in-tree v2 fixture package is literally named "bgfx_v2", and an
    ///     external bgfx could ship as "labelle-bgfx" or anything else. A string
    ///     match on "bgfx" would MISS those (wrongly re-enabling SDL).
    ///   - There is no CAPABILITY signal to key off instead: the natural
    ///     candidate `.gamepad_polling` is DECLARED by bgfx (its `.auto` gamepad
    ///     IS the shared SDL source), so it's advertised by every windowed
    ///     backend and cannot separate a renderer-only backend from an
    ///     input-capable one. Adding a dedicated "no native gamepad" capability
    ///     (and threading the resolved manifest into this pure config method) is
    ///     deliberately out of scope for this change.
    ///
    /// LIMITATION (conscious + documented): a genuine THIRD-PARTY renderer-only
    /// backend selected purely via `.backend_package` (with `.backend` left at
    /// its default) therefore falls back to `.auto`. Such a project opts out
    /// explicitly with `.gamepad = .none`.
    ///
    /// This is the SINGLE source of truth for the gamepad decision — every reader
    /// (`deps_linker.stagesSdlGamepad`, the codegen `gamepad_enabled` dep-option)
    /// routes through here so they can never disagree. Never read `.gamepad`
    /// directly.
    pub fn effectiveGamepad(self: ProjectConfig) GamepadSource {
        return self.gamepad orelse (if (self.backend == .bgfx) .none else .auto);
    }

    /// True when the backend resolves from a PACKAGE (external) rather than the
    /// bundled slot — either an explicit `.backend_package` or a built-in enum
    /// tag mapped to a provider via `builtinProvider` (the enum-as-shorthand).
    /// The external path is purely additive: when this is false the assembler
    /// stays on the unchanged built-in codepath (byte-identical output). The
    /// behavioral `switch (cfg.backend)` sites (built-in-specific sub-package
    /// staging / per-backend build fragments) are gated OFF when this is true —
    /// an external backend is self-contained (its own staged `build.zig.zon`
    /// declares its deps) and generates exclusively through its manifest.
    pub fn isExternal(self: ProjectConfig) bool {
        return self.effectiveBackendPackage() != null;
    }

    /// True when this backend is a built-in identified by the closed `Backend`
    /// enum tag — i.e. the resolved backend NAME equals the current enum tag's
    /// spelling. This is the enum-as-shorthand identity check (epic #386 Phase 5,
    /// #453 PR 11): it covers both a plain `.backend = .<tag>` shorthand and an
    /// explicit `.backend_package` that is a local dev-override of a built-in
    /// (e.g. `.backend = .bgfx` + `.backend_package = .{ .name = "bgfx", .. }`),
    /// because both resolve `backendName()` back to the tag spelling.
    ///
    /// It returns FALSE for a genuine THIRD-PARTY backend named only by string
    /// (`.backend_package = .{ .name = "acme_foo", .. }`), whose `cfg.backend`
    /// sits at the meaningless `.raylib` default. Such a backend must therefore
    /// route ENTIRELY through `backend_registry` + its (v2) manifest and MUST
    /// NOT reach the enum `switch (cfg.backend)` codegen — which would mis-emit
    /// raylib-shaped wiring. This is the ONE remaining place the enum tag is read
    /// as an *identity*; a non-enum name never consults it.
    pub fn isEnumTagBacked(self: ProjectConfig) bool {
        return std.mem.eql(u8, self.backendName(), @tagName(self.backend));
    }

    /// The unset-`.y_axis` build guard (RFC-Y-AXIS-CONVENTION Migration §,
    /// epic labelle-engine#640). During the transition release an *absent*
    /// `.y_axis` is a hard error naming BOTH choices, so no existing game
    /// silently flips upside-down when the framework default becomes `.down`.
    /// Returns the parsed convention, or an error after writing the guidance
    /// to stderr when the key is missing. Call before emitting the game config.
    pub fn requireYAxis(self: ProjectConfig) error{MissingYAxis}!YAxis {
        return self.y_axis orelse {
            const io = globalIo();
            const msg =
                "labelle-assembler: project.labelle is missing `.y_axis`: " ++
                "set `.y_axis = .up` to keep current (bottom-origin) behavior, " ++
                "or `.y_axis = .down` for the new screen-native default.\n";
            std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
            return error.MissingYAxis;
        };
    }

    /// Resolves the explicit initial prefab name, honoring the deprecated
    /// `initial_scene` legacy alias. `initial_prefab` wins when both are set.
    /// Returns null when neither is configured (caller falls back to scan order).
    pub fn resolvedInitialPrefab(self: ProjectConfig) ?[]const u8 {
        return self.initial_prefab orelse self.initial_scene;
    }

    /// Normalizes the deprecated `initial_scene` alias into `initial_prefab`.
    /// Call once right after parsing `project.labelle`. Emits a deprecation
    /// warning when the legacy field is the one providing the value.
    pub fn normalizeInitialPrefab(self: *ProjectConfig) void {
        if (self.initial_scene) |legacy| {
            if (self.initial_prefab == null) {
                std.log.warn(
                    "project.labelle: `.initial_scene` is deprecated; rename it to `.initial_prefab` (`.initial_scene` will be removed in a future release)",
                    .{},
                );
                self.initial_prefab = legacy;
            } else {
                std.log.warn(
                    "project.labelle: both `.initial_prefab` and `.initial_scene` are set; `.initial_scene` is deprecated and ignored",
                    .{},
                );
            }
            self.initial_scene = null;
        }
    }
};

test "AssetCompression.formatFor maps platforms; default is png everywhere" {
    const def = AssetCompression{};
    inline for (.{ Platform.desktop, .android, .ios, .wasm }) |p| {
        try std.testing.expectEqual(AssetFormat.png, def.formatFor(p));
    }
    const mixed = AssetCompression{ .android = .astc, .ios = .astc, .desktop = .astc, .web = .png };
    try std.testing.expectEqual(AssetFormat.astc, mixed.formatFor(.android));
    try std.testing.expectEqual(AssetFormat.astc, mixed.formatFor(.ios));
    try std.testing.expectEqual(AssetFormat.astc, mixed.formatFor(.desktop));
    try std.testing.expectEqual(AssetFormat.png, mixed.formatFor(.wasm)); // web -> wasm
}

test "PluginDep: `.params = .{ .language = … }` parses from ZON and defaults to null (#584)" {
    // The project.labelle `.plugins` entries parse through the same typed ZON
    // path `main.zig` uses; `.params` is additive — an entry that omits it
    // must land on the byte-identical `null` default.
    const alloc = std.testing.allocator;
    const src: [:0]const u8 =
        \\.{
        \\    .{ .name = "labelle-scripting", .version = "0.1.0", .params = .{ .language = "lua" } },
        \\    .{ .name = "pathfinding", .version = "4.0.1" },
        \\}
    ;
    const parsed = try std.zon.parse.fromSliceAlloc([]const PluginDep, alloc, src, null, .{});
    defer std.zon.parse.free(alloc, parsed);
    try std.testing.expectEqual(@as(usize, 2), parsed.len);
    try std.testing.expectEqualStrings("lua", parsed[0].params.?.language.?);
    try std.testing.expect(parsed[1].params == null);
}

test "PluginDep: an EMPTY `.params` bag parses — every param stays null (#584)" {
    // `.params = .{}` is legal: the bag is present, no parameter is set. The
    // policy layer treats it exactly like an absent bag (no script language
    // declared).
    const alloc = std.testing.allocator;
    const src: [:0]const u8 =
        \\.{
        \\    .{ .name = "labelle-scripting", .version = "0.1.0", .params = .{} },
        \\}
    ;
    const parsed = try std.zon.parse.fromSliceAlloc([]const PluginDep, alloc, src, null, .{});
    defer std.zon.parse.free(alloc, parsed);
    try std.testing.expect(parsed[0].params != null);
    try std.testing.expect(parsed[0].params.?.language == null);
}

test "PluginDep: an unknown key inside `.params` is a hard parse error (#584)" {
    // BY CONSTRUCTION: the project.labelle parse uses the default
    // `ignore_unknown_fields = false`, so a key `Params` doesn't declare
    // fails the parse — nothing silently drops. Schema-declared params (a
    // plugin publishing its own accepted keys) are the plugin params
    // follow-up ticket.
    const alloc = std.testing.allocator;
    const src: [:0]const u8 =
        \\.{
        \\    .{ .name = "labelle-scripting", .version = "0.1.0", .params = .{ .lenguage = "lua" } },
        \\}
    ;
    // Diagnostics rather than `null`: (a) the parser's owned
    // unexpected-field note would leak on the null path (std.zon quirk),
    // (b) it lets us pin the diagnostic that names the stray key.
    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(alloc);
    try std.testing.expectError(
        error.ParseZon,
        std.zon.parse.fromSliceAlloc([]const PluginDep, alloc, src, &diag, .{}),
    );
    const rendered = try std.fmt.allocPrint(alloc, "{f}", .{&diag});
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "unexpected field 'lenguage'") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "supported: 'language'") != null);
}

test "effectiveGamepad: bgfx defaults to .none, other backends to .auto, explicit honored (assembler#533)" {
    // ABSENT `.gamepad` (null): backend-aware default.
    try std.testing.expectEqual(GamepadSource.none, (ProjectConfig{ .name = "g", .backend = .bgfx }).effectiveGamepad());
    inline for (.{ Backend.raylib, .sokol, .sdl, .wgpu, .null }) |b| {
        try std.testing.expectEqual(GamepadSource.auto, (ProjectConfig{ .name = "g", .backend = b }).effectiveGamepad());
    }

    // The default keys off the `.bgfx` ENUM TAG (assembler#534). A `.backend =
    // .bgfx` project keeps that tag even when the tag resolves to a fetched
    // provider package (the enum-as-shorthand) OR is pinned to a `local:`
    // dev-override whose package name differs (the in-tree fixture is named
    // "bgfx_v2") — so the tag, not the package name, is the reliable signal.
    try std.testing.expectEqual(GamepadSource.none, (ProjectConfig{
        .name = "g",
        .backend = .bgfx,
        .backend_package = .{ .name = "bgfx_v2", .repo = "local:backends/bgfx_v2" },
    }).effectiveGamepad());
    // Documented limitation (assembler#534): a THIRD-PARTY renderer-only backend
    // selected purely via `.backend_package`, with `.backend` left at its
    // default, falls back to `.auto` — no capability signal marks it as needing
    // SDL for gamepad (`.gamepad_polling` is declared even by bgfx). It opts out
    // with an explicit `.gamepad = .none`.
    try std.testing.expectEqual(GamepadSource.auto, (ProjectConfig{
        .name = "g",
        .backend_package = .{ .name = "acme_vulkan", .repo = "local:../v" },
    }).effectiveGamepad());
    try std.testing.expectEqual(GamepadSource.none, (ProjectConfig{
        .name = "g",
        .backend_package = .{ .name = "acme_vulkan", .repo = "local:../v" },
        .gamepad = .none,
    }).effectiveGamepad());

    // EXPLICIT `.gamepad` is honored verbatim on EVERY backend — an explicit
    // `.auto` on bgfx still enables gamepad (opts back into SDL), and an explicit
    // `.none` on raylib still opts out.
    inline for (@typeInfo(Backend).@"enum".fields) |f| {
        const tag = @field(Backend, f.name);
        try std.testing.expectEqual(GamepadSource.auto, (ProjectConfig{ .name = "g", .backend = tag, .gamepad = .auto }).effectiveGamepad());
        try std.testing.expectEqual(GamepadSource.none, (ProjectConfig{ .name = "g", .backend = tag, .gamepad = .none }).effectiveGamepad());
    }
}
