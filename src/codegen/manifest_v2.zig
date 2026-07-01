//! Build-graph manifest **v2** type foundation + header-first version parse
//! (epic #453 item 3, PR 1 — see `docs/design/manifest-v2-build-graph.md`).
//!
//! This module is the TYPE + PARSE half of manifest-v2. It is fully ADDITIVE:
//! nothing here is wired into `build_files.zig` / codegen yet (that is PR 2/3).
//! The v1 splice (`manifest_splice.zig`) is untouched and remains the live
//! codegen route; a v1 (or field-less) manifest routes to it exactly as today.
//!
//! ## Why a header-first parse (the critical correction, design §3/§6)
//!
//! A v2 struct that makes `manifest_version` *mandatory* cannot be used to
//! route v1 manifests: the retained `backends/sokol/backend.manifest.zon` has
//! NO `manifest_version` field, and `.ignore_unknown_fields = true` only skips
//! *extra* fields — it does not supply a *missing required* one. A direct
//! `fromSliceAlloc(BackendManifestV2, …)` on a v1 manifest therefore fails to
//! parse *before* any `>= 2` gate can run. So we parse a tiny
//! `ManifestHeader { manifest_version: u8 = 1 }` FIRST (defaulted, so an absent
//! field reads as 1), then dispatch on a bounded range — mirroring
//! `plugin_manifest.zig`'s `< 1 or > SUPPORTED_MANIFEST_VERSION` discipline.

const std = @import("std");
const config = @import("../config.zig");
const splice = @import("manifest_splice.zig");
const backend_registry = @import("../backend_registry.zig");

const ProjectConfig = config.ProjectConfig;

/// Highest `manifest_version` this assembler release understands. v2 is the
/// build-graph schema below; v1 (or a field-less manifest) routes to the
/// existing splice + enum path. Bump when a new schema version lands that
/// older assemblers cannot safely treat as `ignore_unknown_fields`.
///
/// Mirrors `plugin_manifest.zig`'s `SUPPORTED_MANIFEST_VERSION` gate.
pub const SUPPORTED_MANIFEST_VERSION: u8 = 2;

/// Parsed FIRST, before the full schema (design §3). Defaulted so a v1 manifest
/// (no `manifest_version` field) reads as version 1 instead of failing to parse,
/// and `ignore_unknown_fields` makes it tolerate every OTHER field the real
/// manifest carries (v1 splice fields or the full v2 surface). This reads only
/// the version off ANY manifest shape.
pub const ManifestHeader = struct {
    manifest_version: u8 = 1,
};

/// v2 build-graph manifest. Parsed from `backends/<dir>/backend.manifest.zon`
/// only after `ManifestHeader.manifest_version >= 2`. Every field is DATA the
/// assembler wires generically — no backend enum tag appears, and no field is
/// raw Zig source (that was the v1 fragment mistake).
///
/// See design §3 for the full field-by-field rationale.
pub const BackendManifestV2 = struct {
    /// Present + defaulted so the same struct round-trips through the header
    /// pre-pass. The full struct is only ever parsed when the header already
    /// proved this is `>= 2`.
    manifest_version: u8 = 1,

    /// Package identity — carried forward from v1 `dir_name`/`dep_name`.
    dir_name: []const u8,
    dep_name: []const u8,
    /// Canonical namespaced ID checked for collisions (RFC "Provider identity").
    /// e.g. "labelle.sokol". Optional for back-compat (derived for built-ins).
    id: ?[]const u8 = null,

    /// Capabilities this provider advertises — CARRIED FORWARD FROM v1, not
    /// dropped. Feeds `capabilities.validate` (the resolve-time negotiation
    /// seam). Dropping it from v2 would let a backend opt into v2 and thereby
    /// bypass the check third-party providers are gated on. Same nominal type
    /// and back-compat rule as v1: an empty set only warns; a non-empty set
    /// opts into enforcement. Defaulted so a v2 manifest predating a given
    /// capability still parses.
    capabilities: []const config.Capability = &.{},

    /// Named modules the provider exposes. Replaces the four hand-written
    /// `.module("gfx"/"input"/"audio"/"window")` lines in every fragment.
    /// Platform-scoped modules (bgfx-Android's `android_app`) are declared under
    /// `.platforms.<p>.extra_modules`.
    modules: []const ModuleDecl,

    /// BASE `b.dependency` options — the set applied to EVERY platform. Names
    /// are declared here so they are comptime-known in generated source; values
    /// come from a closed predicate set (`DepOption.ValueSource`). Per-platform
    /// `PlatformEntry.dep_options` override-by-name and append to this base.
    /// Only options common to ALL supported platforms belong here — an option
    /// some platform must NOT pass is a per-platform append, never a base entry
    /// (there is no subtractive form).
    dep_options: []const DepOption = &.{},

    /// Per-platform, per-OS system libraries → `linkSystemLibrary`.
    system_libs: SystemLibs = .{},

    /// Per-platform Apple frameworks → `linkFramework` (Zig distinguishes these
    /// from system libs).
    frameworks: Frameworks = .{},

    /// The (backend × platform) matrix. Absent platform = unsupported.
    platforms: Platforms,

    /// OPTIONAL. Relative path to the provider's build hook (design §4). Absent
    /// = fully declarative backend, no hook compiled/called.
    ///
    /// This MUST point at a DEDICATED hook file (convention `backend.hook.zig`),
    /// NOT the provider's own `build.zig` — the latter carries top-level imports
    /// (e.g. `@import("sokol")`) resolvable only in the provider's build context,
    /// absent from the generated ROOT package the assembler imports the hook
    /// into. The dedicated hook file makes no package-local import assumptions;
    /// anything it needs from the provider package it takes through
    /// `HookContext.backend_dep`.
    build_hook: ?[]const u8 = null,

    pub const ModuleDecl = struct {
        /// Provider module name, e.g. "gfx".
        name: []const u8,
        /// Root import alias — the KEY the generated root imports this module
        /// under. Current templates import provider modules as
        /// `backend_gfx`/`backend_input`/… and lifecycle code does
        /// `@import("backend_gfx")`, so the alias MUST be preserved or v2 stops
        /// compiling at every `@import("backend_*")`. Defaults to
        /// `backend_<name>` so the common case needs no restatement (the default
        /// itself is applied by the wiring, PR 2+; here it is manifest data).
        root_alias: ?[]const u8 = null,
        /// Informational for `b.dependency`-sourced modules.
        source: []const u8,
    };

    pub const ArtifactDecl = struct {
        /// `b.dependency(...).artifact(name)`.
        name: []const u8,
        /// Force `-fPIC` (Android `.so` requirement, #147).
        pic: bool = false,
    };

    /// A `b.dependency` option. `name` is declarative (rendered into source, so
    /// comptime-known when build.zig compiles); `value` names ONE of a closed,
    /// assembler-known predicate set — never arbitrary runtime data (design §4).
    /// There is deliberately NO `DependencyOptions` type and NO `pre_wire` hook:
    /// a `b.dependency` options literal needs comptime-known field names, so a
    /// runtime `[]Flag` return cannot expand into it.
    pub const DepOption = struct {
        /// e.g. "with_imgui", "gamepad_hidapi", "dont_link_system_libs".
        name: []const u8,
        value: ValueSource,

        /// The closed predicate set the assembler knows how to compute — the
        /// exact `paramValue` predicates the v1 splice uses today
        /// (`manifest_splice.zig`), plus the literal-true/false the mobile
        /// `dont_link_system_libs` flag needs. Extending it is a deliberate
        /// schema + assembler change (the VALUE logic is trusted assembler
        /// code; the NAME is free manifest data).
        pub const ValueSource = enum {
            /// `cfg.resolved_gui.name == "imgui"` (with_imgui / gui_enabled).
            gui_is_imgui,
            /// `cfg.gamepad == .auto`.
            gamepad_enabled,
            /// `cfg.gamepad_hidapi`.
            gamepad_hidapi,
            /// literal `true` (e.g. `dont_link_system_libs = true` on mobile).
            true_literal,
            /// literal `false`.
            false_literal,
        };
    };

    /// Per-OS lists so the `switch (target.result.os.tag)` blocks in
    /// `.link_raylib`/`.link_sokol`/`.link_wgpu` become data.
    pub const OsLibs = struct {
        macos: []const []const u8 = &.{},
        linux: []const []const u8 = &.{},
        windows: []const []const u8 = &.{},
    };

    pub const SystemLibs = struct {
        desktop: OsLibs = .{},
        android: []const []const u8 = &.{},
        ios: []const []const u8 = &.{},
        /// usually empty — emcc handles these.
        wasm: []const []const u8 = &.{},
    };

    pub const Frameworks = struct {
        /// OpenGL(macos)/Metal etc.
        desktop: OsLibs = .{},
        ios: []const []const u8 = &.{},
    };

    pub const Target = union(enum) {
        /// desktop: `b.standardTargetOptions`.
        native,
        /// fixed cross target (wasm32-emscripten).
        triple: []const u8,
        /// computed by the `resolve_target` phase (design §4): iOS/Android.
        resolved,
    };

    pub const Package = union(enum) {
        binary,
        apk: struct { manifest: []const u8 },
        web: struct { shell: ?[]const u8 = null },
    };

    pub const RootBuildDep = struct {
        /// `build.zig.zon` key, e.g. "emsdk".
        name: []const u8,

        /// How the emitted `build.zig.zon` entry resolves. REQUIRED — a bare key
        /// name is not enough: `b.dependency(name, .{})` cannot invent a
        /// url+hash from an arbitrary name.
        resolution: Resolution,

        pub const Resolution = union(enum) {
            /// url+hash, emitted verbatim into build.zig.zon (as `dep_emsdk` does).
            remote: struct { url: []const u8, hash: []const u8 },
            /// relative/absolute path dependency.
            path: []const u8,
            /// A resolution the assembler already knows how to emit (emsdk is the
            /// only one today).
            builtin,
        };
    };

    pub const PlatformEntry = struct {
        /// Entry-point / main-loop template, replacing v1 `main_loop_template`.
        entry: []const u8,

        /// Run-loop style — MUST be per-platform, not top-level: bgfx-desktop is
        /// `.loop` while bgfx-Android is `.callback` (NativeActivity). `.callback`
        /// = windowing runtime owns the loop; `.loop` = generated main drives
        /// `while (!quit)`.
        loop_style: LoopStyle,

        /// How the cross-compile target is chosen. `.native` for desktop; a fixed
        /// `.triple` for wasm; and `.resolved` for iOS/Android, computed
        /// dynamically by the `resolve_target` phase (design §4).
        target: Target,

        /// Root-module PIC (Android `.so`). Static per-platform fact.
        pic: bool = false,

        /// `root_module.link_libc = true`. Captured per-platform because mobile
        /// specs set it and desktop does not.
        link_libc: bool = false,

        /// Artifacts scoped to THIS platform — presence differs by platform
        /// (bgfx-desktop links `bgfx`+`glfw`; bgfx-Android only `bgfx`).
        artifacts: []const ArtifactDecl = &.{},

        /// Per-platform `b.dependency` option additions/overrides, merged over
        /// the base `dep_options` to form the FINAL option set for THIS platform.
        /// The merge is a COMPTIME set operation keyed by `name` (override on
        /// collision, append otherwise), with NO subtractive form (design §3/§4).
        dep_options: []const DepOption = &.{},

        /// Extra platform-only modules (bgfx-Android `android_app`). These MUST
        /// set an explicit `root_alias` when the generated root imports them
        /// under a name that is not `backend_<module_name>` (bgfx-Android's
        /// `android_app` is published as `backend_app`).
        extra_modules: []const ModuleDecl = &.{},

        /// Root `build.zig.zon` build-time dependencies the hook resolves via
        /// `b.dependency` at consumer build time (e.g. wasm hooks call
        /// `b.dependency("emsdk", .{})`). Each entry carries its own resolution.
        root_build_deps: []const RootBuildDep = &.{},

        /// Packaging recipe handed to the shared platform-packager.
        package: Package,

        pub const LoopStyle = enum { callback, loop };
    };

    pub const Platforms = struct {
        desktop: ?PlatformEntry = null,
        android: ?PlatformEntry = null,
        ios: ?PlatformEntry = null,
        wasm: ?PlatformEntry = null,
    };
};

// ── Build hook ABI (types only — NOT invoked here) ───────────────────────

/// Versioned with the hook ABI, independent of `SUPPORTED_MANIFEST_VERSION`.
/// The assembler asserts compatibility before calling a hook (same discipline
/// as `plugin_manifest.zig`'s version gate). Bumps only on a breaking
/// `HookContext`/ABI change.
pub const HOOK_ABI_VERSION: u8 = 2;

/// `post_wire` context (design §4). Every field is valid because `post_wire`
/// runs strictly AFTER `b.dependency` and after the root exe/lib is created.
/// TYPES ONLY in this PR — no hook is imported or invoked.
pub const HookContext = struct {
    /// Asserted `== HOOK_ABI_VERSION` before the hook is called.
    manifest_version: u8,
    /// Resolved (non-optional here).
    backend_dep: *std.Build.Dependency,
    root_module: *std.Build.Module,
    /// For linkLibrary/setLibCFile/addLibraryPath.
    root_artifact: *std.Build.Step.Compile,
    /// From `resolve_target` for iOS/Android.
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    platform: config.Platform,

    /// iOS SDK path resolved in `resolve_target`, so `post_wire`'s
    /// configureSdkPaths/addExeSdkPaths consume it without re-shelling xcrun.
    ios_sdk_path: ?[]const u8,

    /// Android target SDK version — the libc.txt / addLibraryPath paths embed
    /// `usr/lib/<triple>/<target_sdk_version>`. REQUIRED for Android: the
    /// assembler MUST populate it (from `cfg.android.target_sdk_version`, which
    /// always defaults to a concrete 34) before calling `post_wire` on an
    /// Android build. It is `?u32` only because `HookContext` is shared with the
    /// non-Android platforms (where it is meaningfully null); the Android arm
    /// must PANIC on null rather than paper over it with a silent default (a
    /// `orelse 34` would emit a wrong `usr/lib/<triple>/34` path while appearing
    /// to honor the user's `target_sdk_version`).
    android_target_sdk: ?u32,
};

// ── Header-first bounded version parse (design §3/§6) ─────────────────────

/// Errors the header-first parse can surface:
///   error.BackendManifestParseError    — ZON parser rejected the file
///   error.BackendManifestUnknownVersion — manifest_version is < 1 or
///                                          > SUPPORTED_MANIFEST_VERSION
///
/// (The parse-failure error name matches `manifest_splice.zig`'s `loadManifest`
/// so callers can match on a single `BackendManifestParseError`.)

/// A manifest parsed and routed by version. The caller frees it with `free`.
pub const ParsedManifest = union(enum) {
    /// v1 (or a field-less legacy manifest) — the existing splice type.
    v1: splice.BackendManifest,
    /// v2 build-graph manifest.
    v2: BackendManifestV2,

    pub fn free(self: ParsedManifest, allocator: std.mem.Allocator) void {
        switch (self) {
            .v1 => |m| std.zon.parse.free(allocator, m),
            .v2 => |m| std.zon.parse.free(allocator, m),
        }
    }
};

/// Parse ONLY the version header off any manifest shape (v1 or v2). Defaulted +
/// `ignore_unknown_fields`, so an absent `manifest_version` reads as 1 and every
/// other field is skipped. The header carries no heap allocations, but callers
/// that want symmetry may `std.zon.parse.free` the result (a no-op).
pub fn parseHeader(allocator: std.mem.Allocator, raw_z: [:0]const u8) !ManifestHeader {
    return std.zon.parse.fromSliceAlloc(ManifestHeader, allocator, raw_z, null, .{
        .ignore_unknown_fields = true,
    }) catch return error.BackendManifestParseError;
}

/// Header-first bounded parse + dispatch (design §6 step 1):
///   1. Parse `ManifestHeader` to read `manifest_version` (absent ⇒ 1).
///   2. Reject `< 1` or `> SUPPORTED_MANIFEST_VERSION` with a readable error —
///      an older assembler must NOT silently accept a future manifest and skip
///      its unknown fields (that would generate an incomplete build graph).
///   3. Dispatch: `<= 1` → re-parse into the v1 `BackendManifest` (the existing
///      splice type, unchanged); `2..SUPPORTED` → re-parse into `BackendManifestV2`.
///
/// Both re-parses use `ignore_unknown_fields = true`, matching the repo-wide
/// forward-compat convention (additive fields tolerated within a major; a hard
/// incompatibility bumps `manifest_version` and is caught by the bound above).
///
/// Caller frees the result via `ParsedManifest.free`.
pub fn parseManifest(allocator: std.mem.Allocator, raw_z: [:0]const u8) !ParsedManifest {
    const header = try parseHeader(allocator, raw_z);
    const v = header.manifest_version;

    if (v < 1 or v > SUPPORTED_MANIFEST_VERSION) {
        std.log.warn(
            "labelle-assembler: backend.manifest.zon declares manifest_version {d}, " ++
                "but this assembler release supports manifest_version 1..{d} — " ++
                "upgrade/downgrade the assembler or fix the manifest.",
            .{ v, SUPPORTED_MANIFEST_VERSION },
        );
        return error.BackendManifestUnknownVersion;
    }

    if (v <= 1) {
        const m = std.zon.parse.fromSliceAlloc(splice.BackendManifest, allocator, raw_z, null, .{
            .ignore_unknown_fields = true,
        }) catch return error.BackendManifestParseError;
        return .{ .v1 = m };
    }

    const m = std.zon.parse.fromSliceAlloc(BackendManifestV2, allocator, raw_z, null, .{
        .ignore_unknown_fields = true,
    }) catch return error.BackendManifestParseError;
    return .{ .v2 = m };
}

/// Load + header-first parse a NAMED manifest file from the resolved backend
/// package (design §6 step 1 dispatch). `filename` is relative to the backend
/// package root — `"backend.manifest.zon"` for the production v1 file, or a v2
/// fixture like `"backend.manifest.v2.zon"` for the byte-anchor test. Routed
/// through `backend_registry.resolveBackendPackage` exactly as the v1
/// `manifest_splice.loadManifest` locates the package. Caller frees via
/// `ParsedManifest.free`.
pub fn loadNamedManifest(
    allocator: std.mem.Allocator,
    cfg: ProjectConfig,
    project_dir: []const u8,
    filename: []const u8,
) !ParsedManifest {
    const pkg_dir = try backend_registry.resolveBackendPackage(allocator, cfg, project_dir);
    defer allocator.free(pkg_dir);

    const manifest_path = try std.fs.path.join(allocator, &.{ pkg_dir, filename });
    defer allocator.free(manifest_path);

    const raw = try std.Io.Dir.cwd().readFileAlloc(config.globalIo(), manifest_path, allocator, .limited(64 * 1024));
    defer allocator.free(raw);
    const raw_z = try allocator.dupeZ(u8, raw);
    defer allocator.free(raw_z);

    return parseManifest(allocator, raw_z);
}

// ============================================================================
// Tests — parse + v1-passthrough + version-bound rejection (design §8 PR 1)
// ============================================================================

const testing = std.testing;

/// A faithful (abridged) synthetic v2 manifest exercising the full surface:
/// identity, capabilities, modules (with an explicit `root_alias`), base
/// `dep_options`, per-OS system_libs/frameworks, all four platform entries with
/// per-platform `dep_options`/artifacts/`link_libc`/`pic`/`root_build_deps`, and
/// a `build_hook`.
const synthetic_v2 =
    \\.{
    \\    .manifest_version = 2,
    \\    .dir_name = "sokol",
    \\    .dep_name = "labelle_sokol",
    \\    .id = "labelle.sokol",
    \\    .capabilities = .{ .screenshots, .raw_gui_adapter, .audio_ogg },
    \\    .modules = .{
    \\        .{ .name = "gfx", .source = "src/gfx.zig" },
    \\        .{ .name = "input", .source = "src/input.zig" },
    \\    },
    \\    .dep_options = .{
    \\        .{ .name = "with_imgui", .value = .gui_is_imgui },
    \\    },
    \\    .system_libs = .{
    \\        .android = .{ "android", "log", "GLESv3", "EGL" },
    \\    },
    \\    .frameworks = .{
    \\        .desktop = .{ .macos = .{ "IOSurface", "CoreFoundation" } },
    \\        .ios = .{ "Foundation", "UIKit", "Metal" },
    \\    },
    \\    .platforms = .{
    \\        .desktop = .{
    \\            .entry = "templates/desktop.txt",
    \\            .loop_style = .callback,
    \\            .target = .native,
    \\            .artifacts = .{ .{ .name = "sokol_clib" } },
    \\            .dep_options = .{
    \\                .{ .name = "gamepad_enabled", .value = .gamepad_enabled },
    \\                .{ .name = "gamepad_hidapi", .value = .gamepad_hidapi },
    \\            },
    \\            .package = .binary,
    \\        },
    \\        .android = .{
    \\            .entry = "templates/mobile.txt",
    \\            .loop_style = .callback,
    \\            .target = .resolved,
    \\            .pic = true,
    \\            .link_libc = true,
    \\            .artifacts = .{ .{ .name = "sokol_clib", .pic = true } },
    \\            .dep_options = .{ .{ .name = "dont_link_system_libs", .value = .true_literal } },
    \\            .package = .{ .apk = .{ .manifest = "AndroidManifest.xml.tmpl" } },
    \\        },
    \\        .wasm = .{
    \\            .entry = "templates/wasm.txt",
    \\            .loop_style = .callback,
    \\            .target = .{ .triple = "wasm32-emscripten" },
    \\            .artifacts = .{ .{ .name = "sokol_clib" } },
    \\            .root_build_deps = .{ .{ .name = "emsdk", .resolution = .builtin } },
    \\            .package = .{ .web = .{ .shell = null } },
    \\        },
    \\    },
    \\    .build_hook = "backend.hook.zig",
    \\}
;

/// An existing-style v1 manifest — NO `manifest_version` field, exactly the
/// shape `backends/sokol/backend.manifest.zon` ships.
const legacy_v1 =
    \\.{
    \\    .dir_name = "sokol",
    \\    .dep_name = "labelle_sokol",
    \\    .loop_style = .callback,
    \\    .main_loop_template = "templates/desktop.txt",
    \\    .build_fragments = .{ .backend_dep = "build_fragments/backend_dep.txt", .link = "build_fragments/link.txt" },
    \\    .params = .{ .backend_dep = .{ "with_imgui" }, .link = .{} },
    \\    .id = "labelle.sokol",
    \\    .capabilities = .{ .screenshots, .wasm },
    \\}
;

fn dupeZ(src: []const u8) ![:0]const u8 {
    return testing.allocator.dupeZ(u8, src);
}

test "BackendManifestV2: a synthetic v2 manifest parses with the right fields" {
    const src_z = try dupeZ(synthetic_v2);
    defer testing.allocator.free(src_z);

    const m = try std.zon.parse.fromSliceAlloc(BackendManifestV2, testing.allocator, src_z, null, .{
        .ignore_unknown_fields = true,
    });
    defer std.zon.parse.free(testing.allocator, m);

    try testing.expectEqual(@as(u8, 2), m.manifest_version);
    try testing.expectEqualStrings("sokol", m.dir_name);
    try testing.expectEqualStrings("labelle_sokol", m.dep_name);
    try testing.expectEqualStrings("labelle.sokol", m.id.?);

    // capabilities carried forward (v1 negotiation retained in v2)
    try testing.expectEqual(@as(usize, 3), m.capabilities.len);
    try testing.expectEqual(config.Capability.screenshots, m.capabilities[0]);

    // modules + default root_alias (null → assembler derives backend_<name>)
    try testing.expectEqual(@as(usize, 2), m.modules.len);
    try testing.expectEqualStrings("gfx", m.modules[0].name);
    try testing.expect(m.modules[0].root_alias == null);
    try testing.expectEqualStrings("src/input.zig", m.modules[1].source);

    // base dep_options: only the universally-shared with_imgui
    try testing.expectEqual(@as(usize, 1), m.dep_options.len);
    try testing.expectEqualStrings("with_imgui", m.dep_options[0].name);
    try testing.expectEqual(BackendManifestV2.DepOption.ValueSource.gui_is_imgui, m.dep_options[0].value);

    // per-OS system libs + frameworks
    try testing.expectEqual(@as(usize, 4), m.system_libs.android.len);
    try testing.expectEqualStrings("GLESv3", m.system_libs.android[2]);
    try testing.expectEqual(@as(usize, 2), m.frameworks.desktop.macos.len);
    try testing.expectEqual(@as(usize, 3), m.frameworks.ios.len);

    // desktop platform entry: native target, appended gamepad dep_options
    const desktop = m.platforms.desktop.?;
    try testing.expectEqual(BackendManifestV2.Target.native, desktop.target);
    try testing.expectEqual(BackendManifestV2.PlatformEntry.LoopStyle.callback, desktop.loop_style);
    try testing.expectEqual(@as(usize, 1), desktop.artifacts.len);
    try testing.expectEqualStrings("sokol_clib", desktop.artifacts[0].name);
    try testing.expectEqual(@as(usize, 2), desktop.dep_options.len);
    try testing.expectEqual(BackendManifestV2.DepOption.ValueSource.gamepad_hidapi, desktop.dep_options[1].value);
    try testing.expect(desktop.package == .binary);

    // android platform entry: resolved target, pic + link_libc, apk package
    const android = m.platforms.android.?;
    try testing.expectEqual(BackendManifestV2.Target.resolved, android.target);
    try testing.expect(android.pic);
    try testing.expect(android.link_libc);
    try testing.expect(android.artifacts[0].pic);
    try testing.expectEqual(BackendManifestV2.DepOption.ValueSource.true_literal, android.dep_options[0].value);
    try testing.expectEqualStrings("AndroidManifest.xml.tmpl", android.package.apk.manifest);

    // wasm platform entry: fixed triple + builtin-resolved emsdk root dep
    const wasm = m.platforms.wasm.?;
    try testing.expectEqualStrings("wasm32-emscripten", wasm.target.triple);
    try testing.expectEqual(@as(usize, 1), wasm.root_build_deps.len);
    try testing.expectEqualStrings("emsdk", wasm.root_build_deps[0].name);
    try testing.expect(wasm.root_build_deps[0].resolution == .builtin);
    try testing.expect(wasm.package.web.shell == null);

    // ios platform absent = unsupported in this synthetic manifest
    try testing.expect(m.platforms.ios == null);

    try testing.expectEqualStrings("backend.hook.zig", m.build_hook.?);
}

test "parseHeader: reads the version off both v1 (absent → 1) and v2 shapes" {
    {
        const v1_z = try dupeZ(legacy_v1);
        defer testing.allocator.free(v1_z);
        const h = try parseHeader(testing.allocator, v1_z);
        try testing.expectEqual(@as(u8, 1), h.manifest_version);
    }
    {
        const v2_z = try dupeZ(synthetic_v2);
        defer testing.allocator.free(v2_z);
        const h = try parseHeader(testing.allocator, v2_z);
        try testing.expectEqual(@as(u8, 2), h.manifest_version);
    }
}

test "parseManifest: v1-passthrough — a field-less v1 manifest routes to the v1 path" {
    const v1_z = try dupeZ(legacy_v1);
    defer testing.allocator.free(v1_z);

    const parsed = try parseManifest(testing.allocator, v1_z);
    defer parsed.free(testing.allocator);

    try testing.expect(parsed == .v1);
    // The v1 splice fields are all present and unchanged.
    try testing.expectEqualStrings("sokol", parsed.v1.dir_name);
    try testing.expectEqual(splice.BackendManifest.LoopStyle.callback, parsed.v1.loop_style);
    try testing.expectEqualStrings("templates/desktop.txt", parsed.v1.main_loop_template);
    try testing.expectEqual(@as(usize, 1), parsed.v1.params.backend_dep.len);
}

test "parseManifest: a v2 manifest routes to the v2 path" {
    const v2_z = try dupeZ(synthetic_v2);
    defer testing.allocator.free(v2_z);

    const parsed = try parseManifest(testing.allocator, v2_z);
    defer parsed.free(testing.allocator);

    try testing.expect(parsed == .v2);
    try testing.expectEqual(@as(u8, 2), parsed.v2.manifest_version);
    try testing.expectEqualStrings("labelle.sokol", parsed.v2.id.?);
    try testing.expect(parsed.v2.platforms.desktop != null);
}

test "parseManifest: rejects manifest_version > SUPPORTED with a clear error" {
    const src =
        \\.{
        \\    .manifest_version = 99,
        \\    .dir_name = "future",
        \\    .dep_name = "labelle_future",
        \\    .modules = .{},
        \\    .platforms = .{},
        \\}
    ;
    const src_z = try dupeZ(src);
    defer testing.allocator.free(src_z);

    try testing.expectError(
        error.BackendManifestUnknownVersion,
        parseManifest(testing.allocator, src_z),
    );
}

test "parseManifest: rejects manifest_version < 1 (zero) with a clear error" {
    // manifest_version = 0 is not a real schema version — flagged the same way
    // as an unknown future version (mirrors plugin_manifest.zig).
    const src =
        \\.{
        \\    .manifest_version = 0,
        \\    .dir_name = "bogus",
        \\    .dep_name = "labelle_bogus",
        \\}
    ;
    const src_z = try dupeZ(src);
    defer testing.allocator.free(src_z);

    try testing.expectError(
        error.BackendManifestUnknownVersion,
        parseManifest(testing.allocator, src_z),
    );
}

test "parseManifest: a malformed manifest surfaces BackendManifestParseError" {
    const src =
        \\.{
        \\    .manifest_version = 2
        \\    .dir_name = "oops"   // missing comma above
        \\}
    ;
    const src_z = try dupeZ(src);
    defer testing.allocator.free(src_z);

    try testing.expectError(
        error.BackendManifestParseError,
        parseManifest(testing.allocator, src_z),
    );
}

test "HookContext + HOOK_ABI_VERSION: type surface is stable (compile-time only)" {
    // Types-only in PR 1: assert the ABI constant and that the required Android
    // field is nullable-but-present. No hook is imported or invoked.
    try testing.expectEqual(@as(u8, 2), HOOK_ABI_VERSION);
    const FieldType = @FieldType(HookContext, "android_target_sdk");
    try testing.expectEqual(?u32, FieldType);
    try testing.expectEqual(?[]const u8, @FieldType(HookContext, "ios_sdk_path"));
}
