//! `init` subcommand for the labelle-assembler binary.
//!
//! Issue #217, phase 3 — the `labelle` CLI used to scaffold new projects
//! in-process (`labelle-cli/src/cli/init.zig` imported the assembler's
//! `generator` module for the default version constants). Project
//! scaffolding is assembler knowledge: it writes a `project.labelle`
//! whose schema the assembler owns, and pins versions the assembler
//! defines. So the assembler now owns the `init` *command* too, and the
//! CLI shells out to `labelle-assembler init <name> [dir] [flags]`.
//!
//! Mirrors `cache_cmd.zig`: parses its own args, prints diagnostics, and
//! exits non-zero on failure so the CLI can propagate the exit code.
//!
//! Behavior is identical to the CLI's old `cmdInit` — same flags, same
//! files, same starter layout — including the #204 fix (scaffolds
//! `scenes/main.jsonc`, never `.zon`, since the generator only scans for
//! `.jsonc` scenes).

const std = @import("std");
const gen = @import("root.zig");
const config = @import("config.zig");

/// Write directly to stderr without a level prefix. Matches main.zig.
fn writeStderr(io: std.Io, msg: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
}

/// Escape `value` for embedding inside a ZON double-quoted string literal.
/// Backslashes and double quotes are the only characters that would break
/// the literal — a project name or version containing either would
/// otherwise produce a `project.labelle` that fails to parse. Returns an
/// allocator-owned slice; the caller frees it.
fn escapeZonString(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (value) |c| {
        if (c == '\\' or c == '"') try out.append(allocator, '\\');
        try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

const init_usage =
    \\labelle-assembler init — scaffold a new project directory
    \\
    \\Usage:
    \\  labelle-assembler init <name> [--backend=X] [--ecs=X] [--gui=X] [--*-version=X] [dir]
    \\
    \\Creates <dir> (defaults to <name>) with a project.labelle plus the
    \\starter scripts/, scenes/, prefabs/, assets/, components/, hooks/
    \\layout, a scenes/main.jsonc, and a .gitignore.
    \\
    \\Flags:
    \\  --backend=X            Graphics backend (default raylib)
    \\  --ecs=X                ECS choice (default zig_ecs)
    \\  --gui=X                GUI plugin path (default none)
    \\  --core-version=X       Pin labelle-core version
    \\  --engine-version=X     Pin labelle-engine version
    \\  --gfx-version=X        Pin labelle-gfx version
    \\  --labelle-version=X    Pin labelle CLI version
    \\  --assembler-version=X  Pin assembler version
    \\
;

/// Fully resolved scaffolding parameters. Defaults match the CLI's former
/// in-process `cmdInit`; the version fields default to this assembler
/// build's pinned versions.
pub const InitOptions = struct {
    /// Project name — written into `.name` / `.title`. Required.
    name: []const u8,
    /// Target directory; defaults to `name` when the caller leaves it null.
    dir: ?[]const u8 = null,
    backend: []const u8 = "raylib",
    ecs: []const u8 = "zig_ecs",
    gui: ?[]const u8 = null,
    core_version: []const u8 = gen.CORE_VERSION,
    engine_version: []const u8 = gen.ENGINE_VERSION,
    gfx_version: []const u8 = gen.GFX_VERSION,
    labelle_version: []const u8 = gen.CLI_VERSION,
    /// Default to this binary's own version — a `labelle init` driven by
    /// this assembler pins the assembler that scaffolded it.
    assembler_version: []const u8 = gen.ASSEMBLER_VERSION,
};

/// `init` subcommand entry point. Parses argv, then delegates to
/// `scaffold`. Exits non-zero on a bad invocation; `scaffold` exits
/// non-zero on a filesystem failure.
pub fn cmdInit(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    var name: ?[]const u8 = null;
    var opts: InitOptions = .{ .name = "" };

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--backend=")) {
            opts.backend = arg["--backend=".len..];
        } else if (std.mem.startsWith(u8, arg, "--ecs=")) {
            opts.ecs = arg["--ecs=".len..];
        } else if (std.mem.startsWith(u8, arg, "--gui=")) {
            opts.gui = arg["--gui=".len..];
        } else if (std.mem.startsWith(u8, arg, "--core-version=")) {
            opts.core_version = arg["--core-version=".len..];
        } else if (std.mem.startsWith(u8, arg, "--engine-version=")) {
            opts.engine_version = arg["--engine-version=".len..];
        } else if (std.mem.startsWith(u8, arg, "--gfx-version=")) {
            opts.gfx_version = arg["--gfx-version=".len..];
        } else if (std.mem.startsWith(u8, arg, "--labelle-version=")) {
            opts.labelle_version = arg["--labelle-version=".len..];
        } else if (std.mem.startsWith(u8, arg, "--assembler-version=")) {
            opts.assembler_version = arg["--assembler-version=".len..];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            writeStderr(io, init_usage);
            return;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            std.log.err("labelle-assembler init: unknown flag '{s}'", .{arg});
            std.process.exit(2);
        } else if (name == null) {
            name = arg;
        } else if (opts.dir == null) {
            opts.dir = arg;
        } else {
            std.log.err("labelle-assembler init: unexpected argument '{s}'", .{arg});
            writeStderr(io, "\n" ++ init_usage);
            std.process.exit(2);
        }
    }

    opts.name = name orelse {
        std.log.err("labelle-assembler init: missing project name", .{});
        writeStderr(io, "\n" ++ init_usage);
        std.process.exit(2);
    };

    try scaffold(allocator, io, opts);
}

/// Materialize a new project directory from `opts`. Exits the process
/// non-zero on a filesystem failure (the CLI propagates the exit code).
/// Split out from `cmdInit` so it can be unit-tested without building an
/// `Args.Iterator`.
pub fn scaffold(allocator: std.mem.Allocator, io: std.Io, opts: InitOptions) !void {
    const dir = opts.dir orelse opts.name;
    const cwd = std.Io.Dir.cwd();

    cwd.createDirPath(io, dir) catch |err| {
        std.log.err("labelle-assembler init: could not create '{s}': {s}", .{ dir, @errorName(err) });
        std.process.exit(1);
    };

    // Write project.labelle
    {
        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();
        const w = &aw.writer;

        // Escape every value that lands inside a `"..."` ZON literal — a
        // name/path/version containing a quote or backslash would
        // otherwise produce an unparseable project.labelle. `backend` and
        // `ecs` are enum tags (`.{s}`, no quotes); they're validated
        // against fixed enums downstream, so they're left unescaped.
        const name_z = try escapeZonString(allocator, opts.name);
        defer allocator.free(name_z);
        const core_z = try escapeZonString(allocator, opts.core_version);
        defer allocator.free(core_z);
        const engine_z = try escapeZonString(allocator, opts.engine_version);
        defer allocator.free(engine_z);
        const gfx_z = try escapeZonString(allocator, opts.gfx_version);
        defer allocator.free(gfx_z);
        const labelle_z = try escapeZonString(allocator, opts.labelle_version);
        defer allocator.free(labelle_z);
        const assembler_z = try escapeZonString(allocator, opts.assembler_version);
        defer allocator.free(assembler_z);

        try w.print(
            \\.{{
            \\    .name = "{s}",
            \\    .title = "{s}",
            \\    .width = 800,
            \\    .height = 600,
            \\    .target_fps = 60,
            \\    .backend = .{s},
            \\    // Logical Y-axis convention (RFC-Y-AXIS-CONVENTION). `.down` is
            \\    // the screen-native default for new projects (y=0 at the top,
            \\    // +Y down); use `.up` for the math-/platformer-natural bottom
            \\    // origin. This key is REQUIRED — an absent `.y_axis` is a hard
            \\    // build error during the convention transition.
            \\    .y_axis = .down,
            \\    .ecs = .{s},
            \\
        , .{ name_z, name_z, opts.backend, opts.ecs });

        // GUI plugin reference (null = no GUI, or a plugin ref)
        if (opts.gui) |gui_path| {
            const gui_z = try escapeZonString(allocator, gui_path);
            defer allocator.free(gui_z);
            try w.print(
                \\    .gui = .{{ .path = "{s}" }},
                \\
            , .{gui_z});
        }

        try w.print(
            \\    .plugins = .{{}},
            \\    .layers = .{{
            \\        .{{ .name = "background", .order = 0, .space = .screen }},
            \\        .{{ .name = "world", .order = 1, .space = .world }},
            \\        .{{ .name = "ui", .order = 2, .space = .screen }},
            \\    }},
            \\    .core_version = "{s}",
            \\    .engine_version = "{s}",
            \\    .gfx_version = "{s}",
            \\    .labelle_version = "{s}",
            \\    .assembler_version = "{s}",
            \\}}
            \\
        , .{ core_z, engine_z, gfx_z, labelle_z, assembler_z });

        const path = try std.fs.path.join(allocator, &.{ dir, "project.labelle" });
        defer allocator.free(path);
        cwd.writeFile(io, .{
            .sub_path = path,
            .data = aw.written(),
            .flags = .{ .exclusive = true },
        }) catch |err| {
            std.log.err("labelle-assembler init: could not write '{s}': {s}", .{ path, @errorName(err) });
            std.process.exit(1);
        };
    }

    // Create starter directories
    const dirs = [_][]const u8{ "scripts", "scenes", "prefabs", "assets", "components", "hooks" };
    for (dirs) |subdir| {
        const path = try std.fs.path.join(allocator, &.{ dir, subdir });
        defer allocator.free(path);
        cwd.createDirPath(io, path) catch {};
    }

    // Write a starter scene.
    //
    // NOTE: The assembler scans `scenes/` for `.jsonc` files only — the
    // legacy `.zon` extension is silently ignored, so a freshly scaffolded
    // project with `main.zon` would build but render nothing (see #204).
    // Keep this in JSONC to match what the assembler actually loads.
    //
    // FORMAT: emit flat-form unified shape from day one (RFC #594 / engine
    // #592). Top-level `"children"` — no `"root":` wrapper, no legacy
    // `"entities"` key, no `"components"` on prefab refs (use
    // `"overrides"`). The loader still dual-accepts the old shape, but new
    // projects scaffold clean so `labelle audit unification` reports zero
    // findings out of the box.
    {
        const path = try std.fs.path.join(allocator, &.{ dir, "scenes", "main.jsonc" });
        defer allocator.free(path);
        cwd.writeFile(io, .{
            .sub_path = path,
            .data =
                \\{
                \\    "name": "main",
                \\    "children": []
                \\}
                \\
            ,
            .flags = .{ .exclusive = true },
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                std.log.err("labelle-assembler init: could not write '{s}': {s}", .{ path, @errorName(err) });
                std.process.exit(1);
            },
        };
    }

    // Write .gitignore
    {
        const path = try std.fs.path.join(allocator, &.{ dir, ".gitignore" });
        defer allocator.free(path);
        cwd.writeFile(io, .{
            .sub_path = path,
            .data = ".labelle/\n",
            .flags = .{ .exclusive = true },
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                std.log.err("labelle-assembler init: could not write '{s}': {s}", .{ path, @errorName(err) });
                std.process.exit(1);
            },
        };
    }

    std.log.info("labelle-assembler: created project '{s}' in {s}/", .{ opts.name, dir });
    std.log.info("  next: cd {s} && labelle run", .{dir});
}

// ─── Tests ─────────────────────────────────────────────────────────────
//
// Regression guard for #204: the assembler scans `scenes/` for `.jsonc`
// only, so scaffolding a `.zon` scene produced an empty game. The CLI's
// old test for this moved here with the command itself.

test "scaffold writes scenes/main.jsonc (not .zon) — #204 regression" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = config.globalIo();

    // scaffold resolves paths relative to cwd, so we pass an absolute path
    // as the target dir. Materialize a subdir first so we can realpath it.
    try tmp.dir.createDirPath(io, "init-204");
    const project_dir = try tmp.dir.realPathFileAlloc(io, "init-204", alloc);
    defer alloc.free(project_dir);

    try scaffold(alloc, io, .{ .name = "init-204", .dir = project_dir });

    // Confirm scenes/main.jsonc exists and starts with `{` (JSONC, not ZON).
    const scene_bytes = try tmp.dir.readFileAlloc(
        io,
        "init-204/scenes/main.jsonc",
        alloc,
        .limited(4096),
    );
    defer alloc.free(scene_bytes);
    try std.testing.expect(scene_bytes.len > 0);
    try std.testing.expectEqual(@as(u8, '{'), scene_bytes[0]);

    // And scenes/main.zon must NOT exist (would silently shadow the real scene).
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(io, "init-204/scenes/main.zon", .{}),
    );
}

test "scaffold writes a project.labelle with the requested fields" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = config.globalIo();

    try tmp.dir.createDirPath(io, "init-fields");
    const project_dir = try tmp.dir.realPathFileAlloc(io, "init-fields", alloc);
    defer alloc.free(project_dir);

    try scaffold(alloc, io, .{
        .name = "init-fields",
        .dir = project_dir,
        .backend = "sokol",
        .ecs = "zflecs",
    });

    const labelle = try tmp.dir.readFileAlloc(
        io,
        "init-fields/project.labelle",
        alloc,
        .limited(4096),
    );
    defer alloc.free(labelle);

    try std.testing.expect(std.mem.indexOf(u8, labelle, ".name = \"init-fields\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, labelle, ".backend = .sokol") != null);
    try std.testing.expect(std.mem.indexOf(u8, labelle, ".ecs = .zflecs") != null);
    try std.testing.expect(std.mem.indexOf(u8, labelle, ".assembler_version = ") != null);
    // RFC-Y-AXIS-CONVENTION (#370): a scaffolded project pins the explicit
    // screen-native default so it satisfies the unset-`.y_axis` build guard.
    try std.testing.expect(std.mem.indexOf(u8, labelle, ".y_axis = .down,") != null);
}

test "scaffold pins real fetchable framework versions — #159 regression" {
    // A freshly scaffolded project.labelle must pin semver-shaped, fetchable
    // versions. Scaffolding "dev" (or any non-numeric string) made the fetch
    // synthesize a bogus `vdev` git ref and fail. Guard against a regression
    // back to "dev" defaults.
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = config.globalIo();

    try tmp.dir.createDirPath(io, "init-159");
    const project_dir = try tmp.dir.realPathFileAlloc(io, "init-159", alloc);
    defer alloc.free(project_dir);

    try scaffold(alloc, io, .{ .name = "init-159", .dir = project_dir });

    const labelle = try tmp.dir.readFileAlloc(
        io,
        "init-159/project.labelle",
        alloc,
        .limited(4096),
    );
    defer alloc.free(labelle);

    // Parse it back and confirm each scaffolded framework version satisfies
    // the proper semver shape via config.isSemverVersion (digits-and-dots
    // with at least one dot) — i.e. it maps to a real `v<x.y.z>` release tag
    // rather than a bogus ref like `vdev`. Asserting the full semver shape
    // (not merely "starts with a digit") stops a stale non-semver default
    // from slipping through.
    const src = try alloc.dupeZ(u8, labelle);
    defer alloc.free(src);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const cfg = try std.zon.parse.fromSliceAlloc(config.ProjectConfig, arena.allocator(), src, null, .{});
    try std.testing.expect(config.isSemverVersion(cfg.core_version));
    try std.testing.expect(config.isSemverVersion(cfg.engine_version));
    try std.testing.expect(config.isSemverVersion(cfg.gfx_version));
}

/// `a >= b` on two semver strings, for the curated-trio floor guard below.
/// Both sides are `build.zig` literals, so a malformed one is a bug in the
/// pins themselves — assert rather than silently pass.
fn pinAtLeast(pin: []const u8, floor: []const u8) bool {
    const p = std.SemanticVersion.parse(pin) catch unreachable;
    const f = std.SemanticVersion.parse(floor) catch unreachable;
    return p.order(f) != .lt;
}

test "scaffold pins a MUTUALLY COMPATIBLE trio — #679 regression" {
    // The curated core/engine/gfx defaults in `build.zig` are what every
    // fresh `labelle init` stamps, so an incoherent trio fails `labelle
    // build` before the user has written a line of code. The CI
    // `curated-set` job compiles the real thing; this test is the cheap,
    // hermetic half — it encodes the cross-package floors so a one-package
    // bump cannot land green and be caught only on a cold user machine.
    //
    // #679: gfx >= 1.30.0 re-exports `core.TextureId` rather than declaring
    // its own (labelle-gfx#328). That type landed in core 1.28.0, and the
    // assembler unifies every package onto the project's `core_version` —
    // so gfx 1.30.x against core < 1.28.0 dies inside the dependency with
    // "root source file struct 'root' has no member named 'TextureId'".
    // Engine >= 2.12.1 is the matching half (`game.nativeTextureId`
    // compiles against the typed gfx surface, labelle-engine#813 phase 4).
    //
    // Earlier floors kept: engine >= 2.11.0 needs core >= 1.27.0
    // (allocator-taking `ChildrenComponent`, labelle-core#65/#66).
    //
    // Read from `config.*_VERSION` (the build options), NOT from a
    // scaffolded file, so `-Dcore_version=` overrides are checked too.
    try std.testing.expect(config.isSemverVersion(config.CORE_VERSION));
    try std.testing.expect(config.isSemverVersion(config.ENGINE_VERSION));
    try std.testing.expect(config.isSemverVersion(config.GFX_VERSION));

    if (pinAtLeast(config.GFX_VERSION, "1.30.0")) {
        try std.testing.expect(pinAtLeast(config.CORE_VERSION, "1.28.0"));
        try std.testing.expect(pinAtLeast(config.ENGINE_VERSION, "2.12.1"));
    }
    if (pinAtLeast(config.ENGINE_VERSION, "2.11.0")) {
        try std.testing.expect(pinAtLeast(config.CORE_VERSION, "1.27.0"));
    }
}

test "scaffold emits flat-form scenes — RFC #594 / engine #592 regression" {
    // Lock in "new projects start clean" for the v2.0 unified-format
    // foundation. The four legacy patterns `labelle audit unification`
    // flags are:
    //   1. top-level `"entities"` key   (legacy_entities)
    //   2. top-level `"root":` wrapper  (legacy_root_wrapper)
    //   3. `"components"` on a prefab ref (legacy_components_on_ref)
    //   4. legacy `"assets":` array      (legacy_assets)
    //
    // None of these may appear in a freshly scaffolded scene. This is the
    // load-bearing guard for the assertion in PR engine#594 phase 2: a
    // fresh `labelle init` produces an audit-clean tree.
    //
    // Detection here mirrors audit.zig's surface checks — top-level key
    // names parsed out of the scaffolded JSONC. The audit binary itself
    // lives in labelle-cli; we can't link it in here, but the shape it
    // looks for is small enough to assert directly.
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = config.globalIo();

    try tmp.dir.createDirPath(io, "init-flat");
    const project_dir = try tmp.dir.realPathFileAlloc(io, "init-flat", alloc);
    defer alloc.free(project_dir);

    try scaffold(alloc, io, .{ .name = "init-flat", .dir = project_dir });

    const scene = try tmp.dir.readFileAlloc(
        io,
        "init-flat/scenes/main.jsonc",
        alloc,
        .limited(4096),
    );
    defer alloc.free(scene);

    // Positive: flat-form must use top-level "children".
    try std.testing.expect(std.mem.indexOf(u8, scene, "\"children\"") != null);

    // Negative: none of the four legacy patterns may appear.
    try std.testing.expect(std.mem.indexOf(u8, scene, "\"entities\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, scene, "\"root\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, scene, "\"components\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, scene, "\"assets\"") == null);
}

test "escapeZonString escapes quotes and backslashes" {
    const alloc = std.testing.allocator;

    const a = try escapeZonString(alloc, "say\"hi");
    defer alloc.free(a);
    try std.testing.expectEqualStrings("say\\\"hi", a);

    const b = try escapeZonString(alloc, "path\\to");
    defer alloc.free(b);
    try std.testing.expectEqualStrings("path\\\\to", b);

    const c = try escapeZonString(alloc, "plain");
    defer alloc.free(c);
    try std.testing.expectEqualStrings("plain", c);
}

test "scaffold writes a parseable project.labelle for a name with a quote" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = config.globalIo();

    try tmp.dir.createDirPath(io, "init-escape");
    const project_dir = try tmp.dir.realPathFileAlloc(io, "init-escape", alloc);
    defer alloc.free(project_dir);

    // A name containing both a double quote and a backslash — verbatim
    // interpolation would produce an unparseable project.labelle.
    try scaffold(alloc, io, .{
        .name = "ev\"il\\game",
        .dir = project_dir,
        .core_version = "1.0\"0",
    });

    const labelle = try tmp.dir.readFileAlloc(
        io,
        "init-escape/project.labelle",
        alloc,
        .limited(4096),
    );
    defer alloc.free(labelle);

    // The escaped form must be present...
    try std.testing.expect(std.mem.indexOf(u8, labelle, "ev\\\"il\\\\game") != null);
    try std.testing.expect(std.mem.indexOf(u8, labelle, "1.0\\\"0") != null);

    // ...and the file must still parse as ZON.
    const src = try alloc.dupeZ(u8, labelle);
    defer alloc.free(src);
    // Parse into an arena: ProjectConfig carries comptime-default slice
    // fields (e.g. `.layers`) that std.zon.parse.free would choke on.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const cfg = try std.zon.parse.fromSliceAlloc(config.ProjectConfig, arena.allocator(), src, null, .{});
    try std.testing.expectEqualStrings("ev\"il\\game", cfg.name);
    try std.testing.expectEqualStrings("1.0\"0", cfg.core_version);
}
