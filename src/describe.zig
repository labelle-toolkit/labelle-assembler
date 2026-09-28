//! `labelle-assembler describe` — the backend/target facts of a project,
//! answered by the assembler itself (labelle-cli RFC #471, item D1).
//!
//! ## Why the assembler answers this
//!
//! The CLI used to re-derive these facts from its own mirror of the
//! assembler's enums, and the two drifted. RFC #471 finding 4 is the
//! concrete case: a third-party `.backend_package = .{ .name = "acme" }`
//! project with no `.backend` generates into `.labelle/acme_desktop`
//! (`backendName()`), while the CLI computed `.labelle/bgfx_desktop`
//! (`@tagName(default_backend)`). `describe` makes the assembler the single
//! source of those facts: the CLI asks, and never re-derives.
//!
//! Every answer here goes through the SAME code `generate` uses:
//!
//!   * backend identity: `ProjectConfig.effectiveBackendPackage()` (the
//!     `.backend` shorthand via `builtinProvider`, an explicit
//!     `.backend_package`, `default_backend`) and `backendName()`;
//!   * target dir: `<backendName()>_<target>`, the exact `allocPrint` that
//!     `generate` (root.zig) and `cmdGenerate` (main.zig) use;
//!   * asset format: `asset_compression.formatFor(platform)`;
//!   * support: `capabilities.requiredCapabilities` checked against the
//!     provider's declared `.capabilities` with `capabilities.validate`'s
//!     rules, plus the v2 manifest's `.platforms.<target>` entry
//!     (`manifest_v2_splice.platformEntry`, the gate that raises
//!     `error.V2PlatformUnsupported` during generation).
//!
//! ## Offline, config-only
//!
//! `describe` fetches nothing, writes nothing, and never generates. It reads
//! `project.labelle`, and — only when the backend package is already on
//! disk — that package's manifest. Package location is
//! `backend_registry.resolveBackendPackage`, which is pure path math over
//! the cache (`cache/resolve.zig`: "no git, no network, no writes").
//!
//! When the package is NOT installed, the declared capabilities come from
//! a snapshot of the first-party manifests at their `builtinProvider`
//! default versions (`builtin_snapshots` below). A third-party package that
//! is not installed has no knowable capabilities; like `validate`'s
//! back-compat rule for a provider that declares none, it reads as
//! supported, and `capabilities_source = "unknown"` says the answer is
//! unverified.
//!
//! Resolved GUI requirements (`.raw_gui_adapter`) are NOT part of the
//! answer: resolving the GUI plugin reads its `gui.labelle` from the
//! package cache, and the question `describe` answers is backend × target.

const std = @import("std");
const config = @import("config.zig");
const capabilities = @import("capabilities.zig");
const backend_registry = @import("backend_registry.zig");
const manifest_v2 = @import("codegen/manifest_v2.zig");
const manifest_splice = @import("codegen/manifest_splice.zig");
const provider_contracts = @import("root/provider_contracts.zig");
const generate_phases = @import("root/generate_phases.zig");

const Capability = config.Capability;
const ProjectConfig = config.ProjectConfig;

/// JSON schema tag, emitted as the document's first key so a consumer can
/// refuse a shape it does not know.
pub const SCHEMA = "labelle.describe/v1";

/// Where `supported` got the provider's declared capabilities from.
pub const CapabilitySource = enum {
    /// The installed package's `backend.manifest.v2.zon`.
    manifest,
    /// Not installed; a first-party backend at its `builtinProvider`
    /// default version, answered from `builtin_snapshots`.
    builtin,
    /// No declared set was read: not installed and not a known first-party
    /// version, or installed without a readable v2 manifest.
    unknown,
};

pub const Description = struct {
    /// The target name as asked.
    target: []const u8,
    /// `.labelle/<backendName()>_<target>`, relative to the project root.
    target_dir: []const u8,
    backend: Backend,
    /// The backend package's directory, present only when it is on disk.
    package_dir: ?[]const u8,
    asset_format: config.AssetFormat,
    supported: bool,
    /// Why `supported` is false. Null when supported.
    reason: ?[]const u8,
    capabilities_source: CapabilitySource,

    pub const Backend = struct {
        /// `backendName()` — the package name, e.g. "bgfx" or "acme".
        name: []const u8,
        /// Canonical provider id (`labelle.bgfx`), from the manifest when
        /// installed, derived for a first-party backend otherwise, else null.
        id: ?[]const u8,
        repo: ?[]const u8,
        version: ?[]const u8,
        /// The resolved directory of a `local:` / `@` package, else null.
        local_path: ?[]const u8,
    };
};

/// The target names this assembler can generate for. Today these are the
/// `Platform` tags; the CLI treats targets as strings (RFC #471 §3), and
/// making the codegen string-keyed is AS5, out of scope here.
pub fn parseTarget(target: []const u8) ?config.Platform {
    return std.meta.stringToEnum(config.Platform, target);
}

/// " desktop ios android wasm" — the accepted target names, for messages.
pub const target_list = blk: {
    var out: []const u8 = "";
    for (@typeInfo(config.Platform).@"enum".fields) |f| out = out ++ " " ++ f.name;
    break :blk out;
};

/// The generated target directory name (without `.labelle/`), exactly as
/// `generate` computes it.
pub fn targetDirName(allocator: std.mem.Allocator, cfg: ProjectConfig, target: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}_{s}", .{ cfg.backendName(), target });
}

/// A first-party manifest's `.capabilities`, recorded at the version
/// `builtinProvider` defaults to. Used ONLY when that package is not
/// installed. The test "builtin snapshots track builtinProvider" fails the
/// moment a default version moves without this table moving with it.
const BuiltinSnapshot = struct {
    backend: config.Backend,
    version: []const u8,
    capabilities: []const Capability,
};

const builtin_snapshots = [_]BuiltinSnapshot{
    // labelle-bgfx v0.30.0 backend.manifest.v2.zon
    .{ .backend = .bgfx, .version = "0.30.0", .capabilities = &.{ .android, .surface_loss, .compressed_textures, .screenshots, .gamepad_polling, .raw_gui_adapter, .wasm } },
    // labelle-wgpu v0.3.0
    .{ .backend = .wgpu, .version = "0.3.0", .capabilities = &.{.compressed_textures} },
    // labelle-null v0.3.0
    .{ .backend = .null, .version = "0.3.0", .capabilities = &.{.headless} },
    // labelle-sdl v0.3.1
    .{ .backend = .sdl, .version = "0.3.1", .capabilities = &.{.gamepad_polling} },
    // labelle-raylib v0.3.0
    .{ .backend = .raylib, .version = "0.3.0", .capabilities = &.{ .screenshots, .compressed_textures, .fonts, .gamepad_polling, .wasm, .audio_ogg } },
    // labelle-sokol v0.8.0
    .{ .backend = .sokol, .version = "0.8.0", .capabilities = &.{ .screenshots, .compressed_textures, .fonts, .gamepad_polling, .raw_gui_adapter, .surface_loss, .wasm, .android, .ios, .audio_ogg } },
};

/// The snapshot for `bp` when it is a first-party package at its default
/// version from its official repo, else null.
fn builtinSnapshot(bp: config.PluginDep) ?BuiltinSnapshot {
    for (builtin_snapshots) |s| {
        const official = ProjectConfig.builtinProvider(s.backend) orelse continue;
        if (!std.mem.eql(u8, bp.name, official.name)) continue;
        if (!std.mem.eql(u8, bp.version, s.version)) continue;
        if (!config.sameRemote(bp.repo, official.repo)) continue;
        return s;
    }
    return null;
}

fn dirExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(config.globalIo(), path, .{}) catch return false;
    return true;
}

/// Answer `describe` for `cfg` and `target`. `project_dir` anchors
/// `local:` paths exactly as generation does. Every returned string is
/// owned by `arena`.
pub fn describe(arena: std.mem.Allocator, cfg_in: ProjectConfig, project_dir: []const u8, target: []const u8) !Description {
    return describeWith(arena, cfg_in, project_dir, target, .{ .editor_preview_env = generate_phases.editorPreviewEnv(arena) });
}

pub const Options = struct {
    /// The `LABELLE_EDITOR_PREVIEW` value (null: unset). `describe` reads
    /// the process environment; tests pass it explicitly.
    editor_preview_env: ?[]const u8 = null,
};

/// `describe` with the environment supplied.
pub fn describeWith(arena: std.mem.Allocator, cfg_in: ProjectConfig, project_dir: []const u8, target: []const u8, opts: Options) !Description {
    var cfg = cfg_in;
    const platform = parseTarget(target);
    if (platform) |p| cfg.platform = p;
    // Editor-preview mode, normalized exactly as `generate` does it.
    generate_phases.applyEditorPreview(&cfg, opts.editor_preview_env);

    const name = cfg.backendName();
    const bp = cfg.effectiveBackendPackage();

    var desc: Description = .{
        .target = target,
        .target_dir = try std.fmt.allocPrint(arena, ".labelle/{s}", .{try targetDirName(arena, cfg, target)}),
        .backend = .{
            .name = name,
            .id = null,
            .repo = if (bp) |b| b.repo else null,
            .version = if (bp) |b| b.version else null,
            .local_path = null,
        },
        .package_dir = null,
        .asset_format = if (platform) |p| cfg.asset_compression.formatFor(p) else .png,
        .supported = true,
        .reason = null,
        .capabilities_source = .unknown,
    };

    // Package location: pure path math, no fetch.
    const pkg_dir = try backend_registry.resolveBackendPackage(arena, cfg, project_dir);
    const installed = dirExists(pkg_dir);
    if (installed) desc.package_dir = pkg_dir;
    if (bp) |b| {
        if (b.isLocal()) desc.backend.local_path = pkg_dir;
    }

    if (platform == null) {
        if (installed) {
            // Still read the installed manifest, for the id and the source;
            // only the verdict is moot (no platform to judge it against).
            var probe = cfg;
            probe.platform = .desktop;
            const v = try provider_contracts.checkProvider(arena, probe, project_dir, .{ .emit_warnings = false });
            if (v.manifest_loaded) desc.capabilities_source = .manifest;
            desc.backend.id = v.id;
        } else if (bp) |b| {
            if (builtinSnapshot(b) != null) {
                desc.capabilities_source = .builtin;
                desc.backend.id = try std.fmt.allocPrint(arena, "labelle.{s}", .{name});
            }
        }
        desc.supported = false;
        desc.reason = try std.fmt.allocPrint(arena, "backend '{s}' has no target '{s}': this assembler generates for{s}", .{ name, target, target_list });
        return desc;
    }

    if (installed) {
        // THE check `generate` runs before codegen (manifest requirement,
        // version floors, v2 parse, lifecycle privilege, identity, id
        // collision, capabilities, platform entry, callback rule). A problem
        // there is exactly a `generate` failure, reported as the reason.
        const v = try provider_contracts.checkProvider(arena, cfg, project_dir, .{ .emit_warnings = false });
        if (v.manifest_loaded) desc.capabilities_source = .manifest;
        desc.backend.id = v.id;
        if (v.problem) |prob| {
            desc.supported = false;
            desc.reason = prob.message;
        }
        return desc;
    }

    // Not installed: only the config-only checks can run. Version floors
    // are one; capabilities come from the first-party snapshot, judged by
    // the same `capabilities.missingMessage` generate uses.
    if (try provider_contracts.floorProblem(arena, cfg, false)) |prob| {
        desc.supported = false;
        desc.reason = prob.message;
    }
    const b = bp orelse return desc;
    const snap = builtinSnapshot(b) orelse return desc;
    desc.capabilities_source = .builtin;
    // A first-party provider's id is derivable without its manifest
    // (`validateProviderIdentity`: "a built-in derives labelle.<name>").
    desc.backend.id = try std.fmt.allocPrint(arena, "labelle.{s}", .{name});
    if (!desc.supported) return desc;
    const required = try capabilities.requiredCapabilities(arena, cfg);
    if (try capabilities.missingMessage(arena, required, snap.capabilities, desc.backend.id.?)) |msg| {
        desc.supported = false;
        desc.reason = msg;
    }
    return desc;
}

/// The machine form. Key order is fixed: `schema`, `target`, `target_dir`,
/// `backend`, then `package_dir` (only when installed), `asset_format`,
/// `supported`, `reason` (only when unsupported), `capabilities_source`.
/// `backend`'s five keys are always present; unknown values are `null`.
pub fn writeJson(w: *std.Io.Writer, d: Description) !void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    try s.objectField("schema");
    try s.write(SCHEMA);
    try s.objectField("target");
    try s.write(d.target);
    try s.objectField("target_dir");
    try s.write(d.target_dir);
    try s.objectField("backend");
    try s.write(d.backend);
    if (d.package_dir) |pd| {
        try s.objectField("package_dir");
        try s.write(pd);
    }
    try s.objectField("asset_format");
    try s.write(@tagName(d.asset_format));
    try s.objectField("supported");
    try s.write(d.supported);
    if (d.reason) |r| {
        try s.objectField("reason");
        try s.write(r);
    }
    try s.objectField("capabilities_source");
    try s.write(@tagName(d.capabilities_source));
    try s.endObject();
    try w.writeAll("\n");
}

/// The human form.
pub fn writeText(w: *std.Io.Writer, d: Description) !void {
    try w.print("target        {s}\n", .{d.target});
    try w.print("target dir    {s}\n", .{d.target_dir});
    try w.print("backend       {s}", .{d.backend.name});
    if (d.backend.id) |id| try w.print(" ({s})", .{id});
    try w.writeAll("\n");
    if (d.backend.repo) |r| try w.print("  repo        {s}\n", .{r});
    if (d.backend.version) |v| try w.print("  version     {s}\n", .{v});
    if (d.backend.local_path) |l| try w.print("  local path  {s}\n", .{l});
    if (d.package_dir) |pd| {
        try w.print("  installed   {s}\n", .{pd});
    } else {
        try w.writeAll("  installed   no\n");
    }
    try w.print("asset format  {s}\n", .{@tagName(d.asset_format)});
    if (d.supported) {
        try w.writeAll("supported     yes");
    } else {
        try w.writeAll("supported     NO");
    }
    switch (d.capabilities_source) {
        .manifest => try w.writeAll(" (from the installed manifest)\n"),
        .builtin => try w.writeAll(" (from the first-party manifest snapshot; package not installed)\n"),
        .unknown => try w.writeAll(" (unverified: package not installed)\n"),
    }
    if (d.reason) |r| try w.print("  reason      {s}\n", .{r});
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const cache_env = @import("cache/env.zig");

/// A throwaway project dir + an empty (nonexistent) cache root, so nothing
/// resolves to the developer's real `~/.labelle`.
const Fixture = struct {
    tmp: testing.TmpDir,
    arena_state: std.heap.ArenaAllocator,
    dir: []const u8,
    home: []const u8,

    fn init() !Fixture {
        var f: Fixture = .{
            .tmp = testing.tmpDir(.{}),
            .arena_state = std.heap.ArenaAllocator.init(testing.allocator),
            .dir = undefined,
            .home = undefined,
        };
        const a = f.arena_state.allocator();
        f.dir = try f.tmp.dir.realPathFileAlloc(testing.io, ".", a);
        f.home = try std.fs.path.join(a, &.{ f.dir, "asm-471-home" });
        cache_env.setCacheRootForTesting(f.home);
        return f;
    }

    fn deinit(f: *Fixture) void {
        cache_env.setCacheRootForTesting(null);
        f.arena_state.deinit();
        f.tmp.cleanup();
    }

    fn arena(f: *Fixture) std.mem.Allocator {
        return f.arena_state.allocator();
    }

    fn parse(f: *Fixture, source: []const u8) !ProjectConfig {
        const z = try f.arena().dupeZ(u8, source);
        return @import("plugin_params.zig").parseProjectConfig(f.arena(), z);
    }

    /// Install a fake package with `manifest` at `<home>/packages/<sub>`.
    fn installPackage(f: *Fixture, sub: []const u8, manifest: []const u8) !void {
        try f.installFile(sub, manifest_v2.V2_MANIFEST_NAME, manifest);
    }

    /// Create `<home>/packages/<sub>` and, unless `file_name` is null, one
    /// file in it.
    fn installFile(f: *Fixture, sub: []const u8, file_name: ?[]const u8, data: []const u8) !void {
        const rel = try std.fs.path.join(f.arena(), &.{ "asm-471-home", "packages", sub });
        try f.tmp.dir.createDirPath(testing.io, rel);
        const name = file_name orelse return;
        const file = try std.fs.path.join(f.arena(), &.{ rel, name });
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = file, .data = data });
        if (std.mem.eql(u8, name, manifest_v2.V2_MANIFEST_NAME)) try writeTemplates(f.tmp.dir, rel);
    }
};

test "describe: .backend shorthand resolves through builtinProvider" {
    var f = try Fixture.init();
    defer f.deinit();
    const cfg = try f.parse(".{ .name = \"g\", .backend = .sokol }");
    const d = try describe(f.arena(), cfg, f.dir, "desktop");
    try testing.expectEqualStrings(".labelle/sokol_desktop", d.target_dir);
    try testing.expectEqualStrings("sokol", d.backend.name);
    try testing.expectEqualStrings("labelle.sokol", d.backend.id.?);
    try testing.expectEqualStrings("github.com/labelle-toolkit/labelle-sokol", d.backend.repo.?);
    try testing.expectEqualStrings(ProjectConfig.builtinProvider(.sokol).?.version, d.backend.version.?);
    try testing.expect(d.backend.local_path == null);
    try testing.expect(d.package_dir == null);
    try testing.expect(d.supported);
    try testing.expectEqual(CapabilitySource.builtin, d.capabilities_source);
}

test "describe: no .backend at all resolves to default_backend (bgfx)" {
    var f = try Fixture.init();
    defer f.deinit();
    const cfg = try f.parse(".{ .name = \"g\" }");
    const d = try describe(f.arena(), cfg, f.dir, "desktop");
    try testing.expectEqualStrings(".labelle/bgfx_desktop", d.target_dir);
    try testing.expectEqualStrings("bgfx", d.backend.name);
}

test "describe: an explicit .backend_package wins, and a local package reports local_path + package_dir from its manifest" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.createDirPath(testing.io, "vendor/bgfx");
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "vendor/bgfx/" ++ manifest_v2.V2_MANIFEST_NAME, .data = test_manifest_desktop_android });
    try writeTemplates(f.tmp.dir, "vendor/bgfx");
    const cfg = try f.parse(
        \\.{ .name = "g", .backend = .bgfx,
        \\   .backend_package = .{ .name = "bgfx", .repo = "local:vendor/bgfx", .version = "0.99.0" } }
    );
    const d = try describe(f.arena(), cfg, f.dir, "android");
    const expected = try std.fs.path.join(f.arena(), &.{ f.dir, "vendor", "bgfx" });
    try testing.expectEqualStrings(".labelle/bgfx_android", d.target_dir);
    try testing.expectEqualStrings("local:vendor/bgfx", d.backend.repo.?);
    try testing.expectEqualStrings("0.99.0", d.backend.version.?);
    try testing.expectEqualStrings(expected, d.backend.local_path.?);
    try testing.expectEqualStrings(expected, d.package_dir.?);
    try testing.expectEqualStrings("labelle.bgfx", d.backend.id.?);
    try testing.expectEqual(CapabilitySource.manifest, d.capabilities_source);
    try testing.expect(d.supported);

    // The same manifest cannot do wasm, so describe says unsupported.
    const w = try describe(f.arena(), cfg, f.dir, "wasm");
    try testing.expect(!w.supported);
    // generate's order: capability negotiation runs before the platform
    // entry, and this manifest declares no `.wasm` capability either.
    try testing.expect(std.mem.indexOf(u8, w.reason.?, "does not support capability 'wasm'") != null);
}

test "describe: a third-party .backend_package with no .backend names the target dir after the package (RFC #471 finding 4)" {
    var f = try Fixture.init();
    defer f.deinit();
    const cfg = try f.parse(
        \\.{ .name = "g", .backend_package = .{ .name = "acme", .repo = "github.com/acme/labelle-acme", .version = "1.0.0" } }
    );
    const d = try describe(f.arena(), cfg, f.dir, "desktop");
    try testing.expectEqualStrings(".labelle/acme_desktop", d.target_dir);
    try testing.expectEqualStrings("acme", d.backend.name);
    try testing.expect(d.backend.id == null);
    // Not installed and not first-party: unverifiable, so not refused.
    try testing.expectEqual(CapabilitySource.unknown, d.capabilities_source);
    try testing.expect(d.supported);
    try testing.expect(d.package_dir == null);

    // Once installed, its manifest answers — and the dir name still matches
    // what `generate` would create.
    try f.installPackage("plugins/github.com/acme/labelle-acme/1.0.0", test_manifest_acme);
    const i = try describe(f.arena(), cfg, f.dir, "desktop");
    try testing.expectEqualStrings("acme.acme", i.backend.id.?);
    try testing.expect(i.package_dir != null);
    try testing.expectEqual(CapabilitySource.manifest, i.capabilities_source);
    try testing.expect(i.supported);
    const gen_name = try std.fmt.allocPrint(f.arena(), "{s}_{s}", .{ cfg.backendName(), @tagName(config.Platform.desktop) });
    try testing.expectEqualStrings(i.target_dir[".labelle/".len..], gen_name);
}

test "describe: an unsupported pair (raylib + ios) is supported=false with a reason" {
    var f = try Fixture.init();
    defer f.deinit();
    const cfg = try f.parse(".{ .name = \"g\", .backend = .raylib }");
    const d = try describe(f.arena(), cfg, f.dir, "ios");
    try testing.expect(!d.supported);
    // `capabilities.validate`'s own diagnostic: the message generate prints.
    try testing.expectEqualStrings(
        "labelle-assembler: backend provider 'labelle.raylib' does not support capability 'ios' required by this project.\n  Choose a provider that advertises 'ios', or remove the requirement.",
        d.reason.?,
    );
    // The same backend is fine on wasm.
    const w = try describe(f.arena(), cfg, f.dir, "wasm");
    try testing.expect(w.supported);
    try testing.expect(w.reason == null);
}

test "describe: an unknown target is unsupported and names the backend and the target" {
    var f = try Fixture.init();
    defer f.deinit();
    const cfg = try f.parse(".{ .name = \"g\", .backend = .bgfx }");
    const d = try describe(f.arena(), cfg, f.dir, "switch");
    try testing.expect(!d.supported);
    try testing.expectEqualStrings(".labelle/bgfx_switch", d.target_dir);
    try testing.expect(std.mem.indexOf(u8, d.reason.?, "backend 'bgfx' has no target 'switch'") != null);
}

test "describe: asset_format follows asset_compression per target" {
    var f = try Fixture.init();
    defer f.deinit();
    const cfg = try f.parse(".{ .name = \"g\", .backend = .bgfx, .asset_compression = .{ .android = .astc, .web = .astc } }");
    try testing.expectEqual(config.AssetFormat.astc, (try describe(f.arena(), cfg, f.dir, "android")).asset_format);
    try testing.expectEqual(config.AssetFormat.astc, (try describe(f.arena(), cfg, f.dir, "wasm")).asset_format);
    try testing.expectEqual(config.AssetFormat.png, (try describe(f.arena(), cfg, f.dir, "desktop")).asset_format);
}

test "describe: offline — nothing is fetched or written to the cache" {
    var f = try Fixture.init();
    defer f.deinit();
    const cfg = try f.parse(".{ .name = \"g\", .backend = .bgfx }");
    for ([_][]const u8{ "desktop", "android", "wasm", "ios", "switch" }) |t| {
        const d = try describe(f.arena(), cfg, f.dir, t);
        try testing.expect(d.package_dir == null);
    }
    // The cache root was never created: no fetch landed, no marker written.
    try testing.expectError(error.FileNotFound, f.tmp.dir.access(testing.io, "asm-471-home", .{}));
    // And the project dir holds no generated output.
    try testing.expectError(error.FileNotFound, f.tmp.dir.access(testing.io, ".labelle", .{}));
}

test "describe: JSON shape (golden)" {
    var f = try Fixture.init();
    defer f.deinit();
    const cfg = try f.parse(".{ .name = \"g\", .backend = .raylib, .asset_compression = .{ .ios = .astc } }");
    const d = try describe(f.arena(), cfg, f.dir, "ios");
    var out: std.Io.Writer.Allocating = .init(f.arena());
    try writeJson(&out.writer, d);
    const golden =
        \\{
        \\  "schema": "labelle.describe/v1",
        \\  "target": "ios",
        \\  "target_dir": ".labelle/raylib_ios",
        \\  "backend": {
        \\    "name": "raylib",
        \\    "id": "labelle.raylib",
        \\    "repo": "github.com/labelle-toolkit/labelle-raylib",
        \\    "version": "0.3.0",
        \\    "local_path": null
        \\  },
        \\  "asset_format": "astc",
        \\  "supported": false,
        \\  "reason": "labelle-assembler: backend provider 'labelle.raylib' does not support capability 'ios' required by this project.\n  Choose a provider that advertises 'ios', or remove the requirement.",
        \\  "capabilities_source": "builtin"
        \\}
        \\
    ;
    try testing.expectEqualStrings(golden, out.written());

    // And the installed, supported form carries `package_dir` and no `reason`.
    try f.installPackage("plugins/github.com/labelle-toolkit/labelle-raylib/0.3.0", try manifestV2(f.arena(), "labelle.raylib", ".screenshots", loop_desktop));
    const i = try describe(f.arena(), cfg, f.dir, "desktop");
    var out2: std.Io.Writer.Allocating = .init(f.arena());
    try writeJson(&out2.writer, i);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, f.arena(), out2.written(), .{});
    const obj = parsed.object;
    try testing.expect(obj.get("package_dir") != null);
    try testing.expect(obj.get("reason") == null);
    try testing.expect(obj.get("supported").?.bool);
    try testing.expectEqualStrings("manifest", obj.get("capabilities_source").?.string);
}

test "describe: builtin snapshots track builtinProvider's default versions" {
    // Bumping a `builtinProvider` default without re-snapshotting that
    // version's `.capabilities` here would make `describe` answer for a
    // version nobody installs. Every Backend tag must have a snapshot, at
    // exactly the default version.
    inline for (@typeInfo(config.Backend).@"enum".fields) |field| {
        const tag: config.Backend = @enumFromInt(field.value);
        const official = ProjectConfig.builtinProvider(tag).?;
        const snap = builtinSnapshot(official) orelse {
            std.debug.print("no describe snapshot for builtin '{s}' at {s}\n", .{ field.name, official.version });
            return error.TestExpectedSnapshot;
        };
        try testing.expectEqual(tag, snap.backend);
    }
}

test "describe: human output" {
    var f = try Fixture.init();
    defer f.deinit();
    const cfg = try f.parse(".{ .name = \"g\", .backend = .raylib }");
    const d = try describe(f.arena(), cfg, f.dir, "ios");
    var out: std.Io.Writer.Allocating = .init(f.arena());
    try writeText(&out.writer, d);
    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "target dir    .labelle/raylib_ios\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "backend       raylib (labelle.raylib)\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "supported     NO") != null);
    try testing.expect(std.mem.indexOf(u8, text, "reason      labelle-assembler: backend provider 'labelle.raylib'") != null);
}

/// The entry templates the fixture manifests name, so a supported case
/// passes generate's template check.
fn writeTemplates(dir: std.Io.Dir, pkg_rel: []const u8) !void {
    var buf: [512]u8 = undefined;
    for ([_][]const u8{ "t/d.txt", "t/a.txt", "templates/desktop.txt", "templates/android.txt" }) |t| {
        const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ pkg_rel, t });
        try dir.createDirPath(testing.io, std.fs.path.dirname(path).?);
        try dir.writeFile(testing.io, .{ .sub_path = path, .data = "" });
    }
}

/// A v2 manifest for the fixtures. `id` null omits `.id`; `platforms` is
/// the `.platforms` body.
fn manifestV2(a: std.mem.Allocator, id: ?[]const u8, caps: []const u8, platforms: []const u8) ![]const u8 {
    const id_line = if (id) |i| try std.fmt.allocPrint(a, "    .id = \"{s}\",\n", .{i}) else "";
    return std.fmt.allocPrint(a,
        \\.{{
        \\    .manifest_version = 2,
        \\    .dir_name = "x",
        \\    .dep_name = "labelle_x",
        \\{s}    .capabilities = .{{ {s} }},
        \\    .modules = .{{}},
        \\    .platforms = .{{ {s} }},
        \\}}
    , .{ id_line, caps, platforms });
}

const loop_desktop = ".desktop = .{ .entry = \"t/d.txt\", .loop_style = .loop, .target = .native, .package = .binary },";
const callback_desktop = ".desktop = .{ .entry = \"t/d.txt\", .loop_style = .callback, .target = .native, .package = .binary },";
const callback_desktop_declared = ".desktop = .{ .entry = \"t/d.txt\", .loop_style = .callback, .target = .native, .package = .binary, .lifecycle = .{ .runner_module_var = true } },";
const privileged_desktop = ".desktop = .{ .entry = \"t/d.txt\", .loop_style = .callback, .target = .native, .package = .binary, .lifecycle = .{ .preview = .sokol_readback } },";
const loop_android = ".android = .{ .entry = \"t/a.txt\", .loop_style = .loop, .target = .resolved, .package = .{ .apk = .{} } },";

const acme_cfg = ".{ .name = \"g\", .y_axis = .up, .backend_package = .{ .name = \"acme\", .repo = \"github.com/acme/labelle-acme\", .version = \"1.0.0\" } }";
const acme_dir = "plugins/github.com/acme/labelle-acme/1.0.0";
const sokol_cfg = ".{ .name = \"g\", .y_axis = .up, .backend = .sokol }";
const sokol_dir = "plugins/github.com/labelle-toolkit/labelle-sokol/" ++ ProjectConfig.builtinProvider(.sokol).?.version;
const bgfx_dir = "plugins/github.com/labelle-toolkit/labelle-bgfx/" ++ ProjectConfig.builtinProvider(.bgfx).?.version;

fn caseManifest(a: std.mem.Allocator, c: Case) ![]const u8 {
    if (c.raw) |r| {
        if (!std.mem.eql(u8, r, "BUILD_HOOK")) return r;
        const base = try manifestV2(a, "acme.acme", ".screenshots", loop_desktop);
        // Splice `.build_hook` in before the closing brace.
        return std.fmt.allocPrint(a, "{s}    .build_hook = \"backend.hook.zig\",\n}}", .{base[0 .. base.len - 1]});
    }
    return manifestV2(a, c.id, c.caps, c.platforms);
}

/// One row of the describe ↔ generate agreement table.
const Case = struct {
    name: []const u8,
    cfg: [:0]const u8,
    target: []const u8 = "desktop",
    /// Package dir under the cache's `packages/`.
    pkg: []const u8,
    /// File to write there (null: an empty package dir).
    file: ?[]const u8 = manifest_v2.V2_MANIFEST_NAME,
    /// The manifest: `id`, capabilities and platforms, or `raw` verbatim.
    id: ?[]const u8 = null,
    caps: []const u8 = ".screenshots, .android",
    platforms: []const u8 = loop_desktop,
    raw: ?[]const u8 = null,
    /// The error generate fails with, or null when it passes every check.
    expect: ?[]const u8,
    /// The `backend.id` describe reports (checked whenever set, supported
    /// or not).
    expect_id: ?[]const u8 = null,
    /// `LABELLE_EDITOR_PREVIEW`, as the environment would carry it.
    env: ?[]const u8 = null,
};

const cases = [_]Case{
    .{ .name = "happy: loop backend with its id", .cfg = sokol_cfg, .pkg = sokol_dir, .id = "labelle.sokol", .expect = null, .expect_id = "labelle.sokol" },
    .{ .name = "happy: built-in without .id derives labelle.<name>", .cfg = sokol_cfg, .pkg = sokol_dir, .expect = null, .expect_id = "labelle.sokol" },
    .{ .name = "happy: third-party with a vendor id", .cfg = acme_cfg, .pkg = acme_dir, .id = "acme.acme", .expect = null, .expect_id = "acme.acme" },
    .{ .name = "happy: declared callback lifecycle", .cfg = acme_cfg, .pkg = acme_dir, .id = "acme.acme", .platforms = callback_desktop_declared, .expect = null, .expect_id = "acme.acme" },
    .{ .name = "happy: an android entry + capability", .cfg = acme_cfg, .target = "android", .pkg = acme_dir, .id = "acme.acme", .caps = ".android, .surface_loss", .platforms = loop_android, .expect = null, .expect_id = "acme.acme" },
    .{ .name = "no manifest at all", .cfg = acme_cfg, .pkg = acme_dir, .file = null, .expect = "ExternalBackendNeedsManifest" },
    .{ .name = "legacy-only manifest", .cfg = acme_cfg, .pkg = acme_dir, .file = manifest_splice.LEGACY_MANIFEST_NAME, .raw = ".{ .id = \"acme.acme\", .capabilities = .{ .screenshots } }", .expect = "ExternalBackendNeedsManifest" },
    .{ .name = "unparseable v2 manifest", .cfg = acme_cfg, .pkg = acme_dir, .raw = ".{ .manifest_version = 2, .dir_name = }", .expect = "BackendManifestParseError" },
    .{ .name = "reserved namespace", .cfg = acme_cfg, .pkg = acme_dir, .id = "labelle.bgfx", .expect = "ReservedProviderNamespace" },
    .{ .name = "shorthand id drift", .cfg = sokol_cfg, .pkg = sokol_dir, .id = "labelle.bgfx", .expect = "ProviderIdDrift" },
    .{ .name = "malformed id", .cfg = acme_cfg, .pkg = acme_dir, .id = "acme", .expect = "MalformedProviderId" },
    .{ .name = "privileged lifecycle from a third party", .cfg = acme_cfg, .pkg = acme_dir, .id = "acme.acme", .platforms = privileged_desktop, .expect = "PrivilegedLifecycleRequiresReservedNamespace", .expect_id = "acme.acme" },
    .{ .name = "undeclared callback lifecycle", .cfg = acme_cfg, .pkg = acme_dir, .id = "acme.acme", .platforms = callback_desktop, .expect = "ExternalCallbackBackendUnsupported", .expect_id = "acme.acme" },
    .{ .name = "missing capability", .cfg = acme_cfg, .target = "android", .pkg = acme_dir, .id = "acme.acme", .caps = ".screenshots", .platforms = loop_android, .expect = "UnsupportedCapability", .expect_id = "acme.acme" },
    .{ .name = "missing platform entry", .cfg = acme_cfg, .target = "android", .pkg = acme_dir, .id = "acme.acme", .caps = ".android, .surface_loss", .expect = "V2PlatformUnsupported", .expect_id = "acme.acme" },
    .{ .name = "entry template missing", .cfg = acme_cfg, .pkg = acme_dir, .id = "acme.acme", .platforms = ".desktop = .{ .entry = \"t/missing.txt\", .loop_style = .loop, .target = .native, .package = .binary },", .expect = "TemplateNotFound", .expect_id = "acme.acme" },
    .{ .name = "unknown builtin root build dep", .cfg = acme_cfg, .pkg = acme_dir, .id = "acme.acme", .platforms = ".desktop = .{ .entry = \"t/d.txt\", .loop_style = .loop, .target = .native, .package = .binary, .root_build_deps = .{ .{ .name = \"ndk\", .resolution = .builtin } } },", .expect = "UnknownBuiltinRootDep", .expect_id = "acme.acme" },
    .{ .name = "declared build hook missing", .cfg = acme_cfg, .pkg = acme_dir, .raw = "BUILD_HOOK", .expect = "FileNotFound", .expect_id = "acme.acme" },
    .{ .name = "version floor (bgfx 0.30.0 on core 1.32.0)", .cfg = ".{ .name = \"g\", .y_axis = .up, .backend = .bgfx, .core_version = \"1.32.0\", .engine_version = \"2.12.2\", .gfx_version = \"1.30.1\" }", .pkg = bgfx_dir, .id = "labelle.bgfx", .expect = "VersionFloorViolation", .expect_id = "labelle.bgfx" },
    .{ .name = "entry template is a directory", .cfg = acme_cfg, .pkg = acme_dir, .id = "acme.acme", .platforms = ".desktop = .{ .entry = \"t\", .loop_style = .loop, .target = .native, .package = .binary },", .expect = "TemplateNotFound", .expect_id = "acme.acme" },
    .{ .name = "editor preview via env on wasm, no v2 wasm entry", .cfg = acme_cfg, .target = "wasm", .env = "1", .pkg = acme_dir, .id = "acme.acme", .caps = ".wasm", .expect = "EditorPreviewUnsupportedByBackend", .expect_id = "acme.acme" },
    .{ .name = "editor preview via env is normalized off on desktop", .cfg = acme_cfg, .env = "1", .pkg = acme_dir, .id = "acme.acme", .expect = null, .expect_id = "acme.acme" },
    .{ .name = "editor preview env '0' stays off on wasm (platform entry is the problem)", .cfg = acme_cfg, .target = "wasm", .env = "0", .pkg = acme_dir, .id = "acme.acme", .caps = ".wasm", .expect = "V2PlatformUnsupported", .expect_id = "acme.acme" },
    .{ .name = "editor preview via project key on wasm, no v2 wasm entry", .cfg = ".{ .name = \"g\", .y_axis = .up, .editor_preview = true, .backend_package = .{ .name = \"acme\", .repo = \"github.com/acme/labelle-acme\", .version = \"1.0.0\" } }", .target = "wasm", .pkg = acme_dir, .id = "acme.acme", .caps = ".wasm", .expect = "EditorPreviewUnsupportedByBackend", .expect_id = "acme.acme" },
    .{ .name = "editor preview via project key is normalized off on desktop", .cfg = ".{ .name = \"g\", .y_axis = .up, .editor_preview = true, .backend_package = .{ .name = \"acme\", .repo = \"github.com/acme/labelle-acme\", .version = \"1.0.0\" } }", .pkg = acme_dir, .id = "acme.acme", .expect = null, .expect_id = "acme.acme" },
};

test "describe: agrees with generate's provider check on every case (supported/reason = generate's outcome)" {
    for (cases) |c| {
        var f = try Fixture.init();
        defer f.deinit();
        const a = f.arena();
        const manifest = try caseManifest(a, c);
        try f.installFile(c.pkg, c.file, manifest);
        var cfg = try f.parse(c.cfg);

        const d = try describeWith(a, cfg, f.dir, c.target, .{ .editor_preview_env = c.env });
        // The check `generate` runs, on the same config, normalized the way
        // `generate` normalizes it.
        cfg.platform = parseTarget(c.target).?;
        generate_phases.applyEditorPreview(&cfg, c.env);
        const v = try provider_contracts.checkProvider(a, cfg, f.dir, .{ .emit_warnings = false });

        errdefer std.debug.print("case '{s}': supported={} reason={?s}\n", .{ c.name, d.supported, d.reason });
        if (c.expect_id) |want_id| try testing.expectEqualStrings(want_id, d.backend.id.?);
        if (c.expect) |want| {
            const p = v.problem orelse return error.TestExpectedProblem;
            try testing.expectEqualStrings(want, @errorName(p.err));
            try testing.expect(!d.supported);
            try testing.expectEqualStrings(p.message, d.reason.?);
            try testing.expect(d.backend.id == null or !std.mem.eql(u8, want, "ReservedProviderNamespace"));
        } else {
            try testing.expect(v.problem == null);
            try testing.expect(d.supported);
            try testing.expect(d.reason == null);
            try testing.expect(d.backend.id != null);
            try testing.expectEqual(CapabilitySource.manifest, d.capabilities_source);
        }
        // A manifest that was not parsed never reads as the capability source.
        if (!v.manifest_loaded) try testing.expect(d.capabilities_source != .manifest);
    }
}

test "describe: the failing cases fail the real generate with the same error" {
    const gen = @import("root.zig");
    for (cases) |c| {
        const want = c.expect orelse continue;
        // `generate` reads LABELLE_EDITOR_PREVIEW from the process
        // environment, which a test cannot set; those rows are covered by
        // the shared-check agreement above.
        if (c.env != null) continue;
        var f = try Fixture.init();
        defer f.deinit();
        const a = f.arena();
        const manifest = try caseManifest(a, c);
        try f.installFile(c.pkg, c.file, manifest);
        var cfg = try f.parse(c.cfg);
        cfg.platform = parseTarget(c.target).?;
        const out = try std.fs.path.join(a, &.{ f.dir, ".labelle" });
        errdefer std.debug.print("case '{s}'\n", .{c.name});
        if (gen.generate(testing.allocator, cfg, out, f.dir, .{})) |_| {
            return error.TestExpectedError;
        } else |err| {
            try testing.expectEqualStrings(want, @errorName(err));
        }
    }
}

test "describe: an installed .sokol whose manifest has no .id reports the derived labelle.sokol" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.installFile(sokol_dir, manifest_v2.V2_MANIFEST_NAME, try manifestV2(f.arena(), null, ".screenshots", loop_desktop));
    const d = try describe(f.arena(), try f.parse(sokol_cfg), f.dir, "desktop");
    try testing.expect(d.supported);
    try testing.expectEqual(CapabilitySource.manifest, d.capabilities_source);
    try testing.expectEqualStrings("labelle.sokol", d.backend.id.?);
}

test "describe: an unknown target still reads the installed manifest for backend.id and capabilities_source" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.installFile(acme_dir, manifest_v2.V2_MANIFEST_NAME, try manifestV2(f.arena(), "acme.acme", ".screenshots", loop_desktop));
    const d = try describe(f.arena(), try f.parse(acme_cfg), f.dir, "xbox");
    try testing.expect(!d.supported);
    try testing.expect(std.mem.indexOf(u8, d.reason.?, "backend 'acme' has no target 'xbox'") != null);
    try testing.expectEqualStrings("acme.acme", d.backend.id.?);
    try testing.expectEqual(CapabilitySource.manifest, d.capabilities_source);
    try testing.expect(d.package_dir != null);
}

test "describe: an installed package dir with no manifest keeps capabilities_source unknown" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.installFile("plugins/github.com/labelle-toolkit/labelle-raylib/0.3.0", null, "");
    const d = try describe(f.arena(), try f.parse(".{ .name = \"g\", .backend = .raylib }"), f.dir, "desktop");
    try testing.expect(!d.supported);
    try testing.expectEqual(CapabilitySource.unknown, d.capabilities_source);
    try testing.expect(d.package_dir != null);
}

const test_manifest_desktop_android =
    \\.{
    \\    .manifest_version = 2,
    \\    .dir_name = "bgfx",
    \\    .dep_name = "labelle_bgfx",
    \\    .id = "labelle.bgfx",
    \\    .capabilities = .{ .android, .surface_loss, .screenshots },
    \\    .modules = .{},
    \\    .platforms = .{
    \\        .desktop = .{ .entry = "templates/desktop.txt", .loop_style = .loop, .target = .native, .package = .binary },
    \\        .android = .{ .entry = "templates/android.txt", .loop_style = .callback, .target = .resolved, .package = .{ .apk = .{} }, .lifecycle = .{} },
    \\    },
    \\}
;

const test_manifest_acme =
    \\.{
    \\    .manifest_version = 2,
    \\    .dir_name = "acme",
    \\    .dep_name = "labelle_acme",
    \\    .id = "acme.acme",
    \\    .capabilities = .{ .screenshots },
    \\    .modules = .{},
    \\    .platforms = .{
    \\        .desktop = .{ .entry = "templates/desktop.txt", .loop_style = .loop, .target = .native, .package = .binary },
    \\    },
    \\}
;
