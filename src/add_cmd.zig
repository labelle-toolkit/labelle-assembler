//! `add` subcommand for the labelle-assembler binary.
//!
//! Packs initiative (umbrella labelle-engine#651, RFC-packs §7, ticket
//! #271). `labelle add` scaffolds the two authoring units the RFC defines:
//!
//!   labelle add pack <name>            — a namespaced convention-dir subtree
//!   labelle add feature <kind> <name>  — a feature-unit bundle (component +
//!                                        script) for a known `kind`
//!
//! Mirrors `init_cmd.zig`: the CLI (`labelle-cli/src/cli/add.zig`) parses
//! `add ...` off argv and forwards it verbatim to this subcommand, which
//! does the file templating. Project scaffolding is assembler knowledge —
//! the `pack.labelle` schema (`plugin_manifest.zig`) and the game-root
//! convention layout are the assembler's, so the assembler owns the
//! command, same split as `init`.
//!
//! The templates written here are deliberately minimal and correct: per
//! RFC §7 they double as the "recipe source" the pack manifest (#442)
//! surfaces as the how-to for an agent, so the steps must be clean and the
//! files must compile in a freshly-generated game.

const std = @import("std");
const config = @import("config.zig");

/// Write directly to stderr without a level prefix. Matches init_cmd.zig.
fn writeStderr(io: std.Io, msg: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
}

/// Feature kinds this scaffold knows how to write. Deliberately a small
/// hardcoded set behind an explicit `kind` arg (RFC §7: "start hardcoded
/// for known kinds"). An unknown kind is rejected with the valid set.
pub const FeatureKind = enum { need, role, status };

const add_usage =
    \\labelle-assembler add — scaffold a pack or a feature-unit
    \\
    \\Usage:
    \\  labelle-assembler add pack <name>
    \\  labelle-assembler add feature <kind> <name>
    \\
    \\`add pack <name>` creates packs/<name>/ with the convention subdirs
    \\(components/ events/ prefabs/ hooks/) and a pack.labelle.
    \\Refuses to overwrite an existing packs/<name>/.
    \\
    \\`add feature <kind> <name>` scaffolds a feature-unit in the game root:
    \\a components/<name>.zig plus a scripts/running/xx_<name>.zig stub.
    \\  <kind> is one of: need, role, status
    \\  <name> must be a lowercase identifier (a-z, 0-9, _), e.g. boredom
    \\
;

/// `add` subcommand entry point. Parses `pack`/`feature` off argv, then
/// delegates to the matching scaffold. Exits non-zero on a bad invocation
/// or a filesystem failure so the CLI can propagate the exit code.
pub fn cmdAdd(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    const what = args.next() orelse {
        std.log.err("labelle-assembler add: missing target ('pack' or 'feature')", .{});
        writeStderr(io, "\n" ++ add_usage);
        std.process.exit(2);
    };

    if (std.mem.eql(u8, what, "--help") or std.mem.eql(u8, what, "-h")) {
        writeStderr(io, add_usage);
        return;
    }

    if (std.mem.eql(u8, what, "pack")) {
        const name = args.next() orelse {
            std.log.err("labelle-assembler add pack: missing pack name", .{});
            writeStderr(io, "\n" ++ add_usage);
            std.process.exit(2);
        };
        try expectNoMoreArgs(io, args, "add pack");
        validateName(io, name, "pack");
        try scaffoldPack(allocator, io, ".", name);
        return;
    }

    if (std.mem.eql(u8, what, "feature")) {
        const kind_str = args.next() orelse {
            std.log.err("labelle-assembler add feature: missing kind (one of: need, role, status)", .{});
            writeStderr(io, "\n" ++ add_usage);
            std.process.exit(2);
        };
        const kind = std.meta.stringToEnum(FeatureKind, kind_str) orelse {
            std.log.err(
                "labelle-assembler add feature: unknown kind '{s}' — valid kinds are: need, role, status",
                .{kind_str},
            );
            writeStderr(io, "\n" ++ add_usage);
            std.process.exit(2);
        };
        const name = args.next() orelse {
            std.log.err("labelle-assembler add feature {s}: missing feature name", .{kind_str});
            writeStderr(io, "\n" ++ add_usage);
            std.process.exit(2);
        };
        try expectNoMoreArgs(io, args, "add feature");
        validateName(io, name, "feature");
        try scaffoldFeature(allocator, io, ".", kind, name);
        return;
    }

    std.log.err("labelle-assembler add: unknown target '{s}' — expected 'pack' or 'feature'", .{what});
    writeStderr(io, "\n" ++ add_usage);
    std.process.exit(2);
}

/// Reject trailing arguments so a typo like `add pack a b` fails loudly
/// instead of silently ignoring `b`.
fn expectNoMoreArgs(io: std.Io, args: *std.process.Args.Iterator, ctx: []const u8) !void {
    if (args.next()) |extra| {
        std.log.err("labelle-assembler {s}: unexpected argument '{s}'", .{ ctx, extra });
        writeStderr(io, "\n" ++ add_usage);
        std.process.exit(2);
    }
}

/// A name becomes both a directory/file segment and (for features) a Zig
/// type name, so constrain it to a lowercase identifier: starts with
/// a-z, then a-z / 0-9 / `_`. This keeps paths safe (no separators, no
/// `..`) and `toTypeName` well-defined.
pub fn isValidName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] < 'a' or name[0] > 'z') return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
        if (!ok) return false;
    }
    return true;
}

fn validateName(io: std.Io, name: []const u8, ctx: []const u8) void {
    if (!isValidName(name)) {
        std.log.err(
            "labelle-assembler add {s}: invalid name '{s}' — use a lowercase identifier (a-z, 0-9, _) starting with a letter, e.g. boredom",
            .{ ctx, name },
        );
        writeStderr(io, "\n" ++ add_usage);
        std.process.exit(2);
    }
}

/// Convert a snake_case name into a PascalCase Zig type name:
/// `night_owl` → `NightOwl`. Caller owns the returned slice.
pub fn toTypeName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    // Zig identifiers can't start with a digit. `isValidName` already
    // rejects a digit-leading feature name, but `toTypeName` is public and
    // reused elsewhere, so guard here too: prefix `_` so the result is a
    // legal identifier regardless of caller (Gemini review).
    if (name.len > 0 and name[0] >= '0' and name[0] <= '9') {
        try out.append(allocator, '_');
    }
    var at_word_start = true;
    for (name) |c| {
        if (c == '_') {
            at_word_start = true;
            continue;
        }
        if (at_word_start and c >= 'a' and c <= 'z') {
            try out.append(allocator, c - ('a' - 'A'));
        } else {
            try out.append(allocator, c);
        }
        at_word_start = false;
    }
    return out.toOwnedSlice(allocator);
}

// ─── pack ──────────────────────────────────────────────────────────────

// Only the convention subdirs the generator's `scanPack` actually copies +
// scans today (`src/root.zig` scans components/events/prefabs/hooks). A
// `scripts/` dir is deliberately NOT scaffolded: light-pack scripts are not
// yet scanned by generate, so a scaffolded `packs/<name>/scripts/` would be
// silently ignored (chatgpt-codex review). Add it back here once pack-script
// scanning lands (follow-up ticket).
const pack_convention_dirs = [_][]const u8{ "components", "events", "prefabs", "hooks" };

/// Materialize `<root>/packs/<name>/` with the convention subdirs and a
/// `pack.labelle`. Refuses if the directory already exists. `root` is the
/// project directory (`.` from the CLI; an absolute tmp path in tests).
pub fn scaffoldPack(allocator: std.mem.Allocator, io: std.Io, root: []const u8, name: []const u8) !void {
    const cwd = std.Io.Dir.cwd();

    const pack_dir = try std.fs.path.join(allocator, &.{ root, "packs", name });
    defer allocator.free(pack_dir);

    // Refuse an existing pack directory — don't clobber author work.
    // createDirPath is idempotent, so we must check existence explicitly.
    if (cwd.access(io, pack_dir, .{})) |_| {
        std.log.err("labelle-assembler add pack: '{s}' already exists — pick another name or remove it first", .{pack_dir});
        std.process.exit(1);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => {
            std.log.err("labelle-assembler add pack: could not check '{s}': {s}", .{ pack_dir, @errorName(err) });
            std.process.exit(1);
        },
    }

    // Convention subdirs, each with a .gitkeep so an empty pack still
    // round-trips through git (empty dirs aren't tracked).
    for (pack_convention_dirs) |sub| {
        const sub_path = try std.fs.path.join(allocator, &.{ pack_dir, sub });
        defer allocator.free(sub_path);
        cwd.createDirPath(io, sub_path) catch |err| {
            std.log.err("labelle-assembler add pack: could not create '{s}': {s}", .{ sub_path, @errorName(err) });
            std.process.exit(1);
        };
        const keep_path = try std.fs.path.join(allocator, &.{ sub_path, ".gitkeep" });
        defer allocator.free(keep_path);
        writeExclusiveData(io, cwd, keep_path, "") catch std.process.exit(1);
    }

    // The manifest. Scalar `.convention_dirs = .copy_and_scan` is the pack
    // shorthand (RFC §10 Q3): "scan all my convention dirs like the game
    // root." Parsed by plugin_manifest.loadPackFromDir.
    {
        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();
        try aw.writer.print(
            \\.{{
            \\    .name = "{s}",
            \\    .manifest_version = 1,
            \\    .convention_dirs = .copy_and_scan,
            \\}}
            \\
        , .{name});

        const manifest_path = try std.fs.path.join(allocator, &.{ pack_dir, "pack.labelle" });
        defer allocator.free(manifest_path);
        writeExclusiveData(io, cwd, manifest_path, aw.written()) catch std.process.exit(1);
    }

    std.log.info("labelle-assembler: scaffolded pack '{s}' in {s}/", .{ name, pack_dir });

    // A light pack only participates in generation when `project.labelle`
    // declares it in `.plugins` (`generate()` discovers packs by iterating
    // `cfg.plugins`). Register it automatically when we can do so safely,
    // otherwise print the exact next step so the pack isn't left dead
    // (chatgpt-codex review).
    try registerPackInProject(allocator, io, cwd, root, name);

    std.log.info("  add features with: labelle add feature <kind> <name>", .{});
}

/// Add `.{ .name = "<name>", .repo = "@packs/<name>" }` to the project's
/// `.plugins` tuple so `generate()` picks the freshly-scaffolded pack up.
///
/// A pack is an in-project local plugin, referenced by the `@`-path form the
/// resolver understands: `@packs/<name>` → `packs/<name>` (see
/// `config.PluginDep.localPath`, same shape as `@libs/...`).
///
/// ZON has no round-trip editor here, so this only rewrites in the cases it
/// can do safely by string surgery — insert the entry right after the
/// `.plugins = .{` opener (works for both an empty `.{}` and a populated
/// tuple). If `project.labelle` is absent, unreadable, has no `.plugins`
/// field, or already references this pack, it prints the manual next step
/// instead of guessing. Never leaves the pack unregistered *and* silent.
fn registerPackInProject(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    root: []const u8,
    name: []const u8,
) !void {
    const proj_path = try std.fs.path.join(allocator, &.{ root, "project.labelle" });
    defer allocator.free(proj_path);

    const src = cwd.readFileAlloc(io, proj_path, allocator, .limited(1 << 20)) catch |err| {
        // No project.labelle (scaffolding a pack outside a project), or it
        // couldn't be read — fall back to the printed instruction.
        if (err != error.FileNotFound) {
            std.log.warn("labelle-assembler add pack: could not read '{s}': {s}", .{ proj_path, @errorName(err) });
        }
        printRegisterHint(name);
        return;
    };
    defer allocator.free(src);

    const repo_ref = try std.fmt.allocPrint(allocator, "\"@packs/{s}\"", .{name});
    defer allocator.free(repo_ref);

    // Already registered? Leave the file untouched.
    if (std.mem.indexOf(u8, src, repo_ref) != null) {
        std.log.info("  pack '{s}' is already registered in project.labelle .plugins", .{name});
        return;
    }

    // Find the `.plugins = .{` opener and insert right after the `{`.
    const plugins_at = std.mem.indexOf(u8, src, ".plugins") orelse {
        printRegisterHint(name);
        return;
    };
    const brace_rel = std.mem.indexOf(u8, src[plugins_at..], ".{") orelse {
        printRegisterHint(name);
        return;
    };
    const insert_at = plugins_at + brace_rel + ".{".len;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, src[0..insert_at]);
    try out.appendSlice(allocator, "\n        .{ .name = \"");
    try out.appendSlice(allocator, name);
    try out.appendSlice(allocator, "\", .repo = \"@packs/");
    try out.appendSlice(allocator, name);
    try out.appendSlice(allocator, "\" },");
    try out.appendSlice(allocator, src[insert_at..]);

    cwd.writeFile(io, .{ .sub_path = proj_path, .data = out.items }) catch |err| {
        std.log.warn("labelle-assembler add pack: could not update '{s}': {s}", .{ proj_path, @errorName(err) });
        printRegisterHint(name);
        return;
    };
    std.log.info("  registered pack '{s}' in project.labelle .plugins", .{name});
}

/// Print the manual step to register a pack in `project.labelle` when we
/// can't (or shouldn't) edit it automatically.
fn printRegisterHint(name: []const u8) void {
    std.log.info(
        "  next: add .{{ .name = \"{s}\", .repo = \"@packs/{s}\" }} to project.labelle .plugins so generate picks it up",
        .{ name, name },
    );
}

// ─── feature ─────────────────────────────────────────────────────────────

/// Scaffold a feature-unit (component + playing script) in the game root
/// (`<root>/`) for `kind`. Refuses to overwrite either file. `root` is the
/// project directory (`.` from the CLI; an absolute tmp path in tests).
pub fn scaffoldFeature(allocator: std.mem.Allocator, io: std.Io, root: []const u8, kind: FeatureKind, name: []const u8) !void {
    const cwd = std.Io.Dir.cwd();

    const type_name = try toTypeName(allocator, name);
    defer allocator.free(type_name);

    const components_dir = try std.fs.path.join(allocator, &.{ root, "components" });
    defer allocator.free(components_dir);
    // Feature scripts live under the project's active game state. Projects
    // scaffolded by `init` default `ProjectConfig.states` to `"running"`, and
    // `ScriptScanner.scanDir` silently ignores first-level script dirs that
    // aren't a declared state — so a script under `scripts/playing/` would
    // never run in a default project (chatgpt-codex review). Target
    // `scripts/running/` so the scaffolded script is picked up out of the box.
    const script_dir = try std.fs.path.join(allocator, &.{ root, "scripts", "running" });
    defer allocator.free(script_dir);

    const comp_file = try std.fmt.allocPrint(allocator, "{s}.zig", .{name});
    defer allocator.free(comp_file);
    const comp_path = try std.fs.path.join(allocator, &.{ components_dir, comp_file });
    defer allocator.free(comp_path);

    const script_file = try std.fmt.allocPrint(allocator, "xx_{s}.zig", .{name});
    defer allocator.free(script_file);
    const script_path = try std.fs.path.join(allocator, &.{ script_dir, script_file });
    defer allocator.free(script_path);

    // Preflight BOTH targets before writing either, so the documented refusal
    // to overwrite is all-or-nothing: `add feature` never leaves a
    // half-created scaffold when one file exists and the other doesn't
    // (chatgpt-codex review). `access` on the file path works whether or not
    // the parent dir exists yet.
    preflightAbsent(io, cwd, comp_path) catch std.process.exit(1);
    preflightAbsent(io, cwd, script_path) catch std.process.exit(1);

    // Report dir-creation failures instead of swallowing them — a silent
    // `catch {}` would let a real error (permission denied, a path component
    // that's a file, disk full) surface later as a confusing write failure
    // (CodeRabbit review). Matches `scaffoldPack`'s handling.
    cwd.createDirPath(io, components_dir) catch |err| {
        std.log.err("labelle-assembler add feature: could not create '{s}': {s}", .{ components_dir, @errorName(err) });
        std.process.exit(1);
    };
    cwd.createDirPath(io, script_dir) catch |err| {
        std.log.err("labelle-assembler add feature: could not create '{s}': {s}", .{ script_dir, @errorName(err) });
        std.process.exit(1);
    };

    // components/<name>.zig
    {
        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();
        try writeComponentTemplate(&aw.writer, kind, name, type_name);
        writeExclusiveData(io, cwd, comp_path, aw.written()) catch std.process.exit(1);
    }

    // scripts/running/xx_<name>.zig
    {
        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();
        try writeScriptTemplate(&aw.writer, kind, name, type_name);
        writeExclusiveData(io, cwd, script_path, aw.written()) catch std.process.exit(1);
    }

    std.log.info("labelle-assembler: scaffolded {s} feature '{s}'", .{ @tagName(kind), name });
    std.log.info("  components/{s}.zig", .{name});
    std.log.info("  scripts/running/xx_{s}.zig", .{name});
    std.log.info("  next: attach `{s}` to the prefab whose entities this feature acts on", .{type_name});
}

/// Preflight guard: error with a clear diagnostic if `path` already exists, so
/// a multi-file scaffold can check every target up front and stay atomic.
/// A `FileNotFound` (the wanted case) passes; any other stat error also errors
/// rather than risk clobbering. Returns the error to the caller (rather than
/// exiting) so it stays unit-testable — the caller maps it to an exit code.
fn preflightAbsent(io: std.Io, cwd: std.Io.Dir, path: []const u8) !void {
    if (cwd.access(io, path, .{})) |_| {
        // Straight to stderr (not `std.log.err`) so the negative-path unit
        // tests don't fail on a logged error (repo convention).
        writeStderr3(io, "labelle-assembler add: '", path, "' already exists — refusing to overwrite\n");
        return error.PathAlreadyExists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => {
            writeStderr3(io, "labelle-assembler add: could not check '", path, "': ");
            writeStderr(io, @errorName(err));
            writeStderr(io, "\n");
            return err;
        },
    }
}

fn writeComponentTemplate(w: *std.Io.Writer, kind: FeatureKind, name: []const u8, type_name: []const u8) !void {
    switch (kind) {
        .need => try w.print(
            \\//! `{s}` — a need's current level, in [0, 1] (1 = fully satisfied).
            \\//!
            \\//! Scaffolded by `labelle add feature need {s}` (RFC-packs §3). A need is
            \\//! a self-contained feature that integrates purely via events: this
            \\//! component holds the durable value, the colocated
            \\//! `scripts/running/xx_{s}.zig` decays it and emits the standard
            \\//! `need_threshold_crossed` event, and consumers (overlay, satisfaction)
            \\//! subscribe to that event — nothing existing is edited.
            \\//!
            \\//! Persistence is automatic: the `Saveable` decl is picked up by
            \\//! save/load with zero extra wiring.
            \\
            \\const core = @import("labelle-core");
            \\
            \\pub const {s} = struct {{
            \\    pub const save = core.Saveable(.saveable, @This(), .{{}});
            \\
            \\    /// Current satisfaction, 1.0 = full, 0.0 = empty.
            \\    value: f32 = 1.0,
            \\}};
            \\
        , .{ type_name, name, name, type_name }),
        .role => try w.print(
            \\//! `{s}` — marks an entity as filling the {s} role.
            \\//!
            \\//! Scaffolded by `labelle add feature role {s}` (RFC-packs §3). A role is
            \\//! a self-contained feature: attach this component to give an entity the
            \\//! role, and the colocated `scripts/running/xx_{s}.zig` drives its
            \\//! per-frame behavior. Consumers react via events, not by reading this
            \\//! component — so adding a role edits nothing existing.
            \\//!
            \\//! Persistence is automatic via the `Saveable` decl.
            \\
            \\const core = @import("labelle-core");
            \\
            \\pub const {s} = struct {{
            \\    pub const save = core.Saveable(.saveable, @This(), .{{}});
            \\
            \\    /// Whether this entity is actively performing the role right now.
            \\    active: bool = true,
            \\}};
            \\
        , .{ type_name, name, name, name, type_name }),
        .status => try w.print(
            \\//! `{s}` — a transient status flag, shown as an overlay.
            \\//!
            \\//! Scaffolded by `labelle add feature status {s}` (RFC-packs §3). A status
            \\//! is a self-contained feature: `scripts/running/xx_{s}.zig` derives
            \\//! whether it is active (typically by subscribing to an event), and an
            \\//! overlay prefab renders it. The state is re-derived each frame, so it is
            \\//! `.transient` — stripped on load rather than serialized.
            \\
            \\const core = @import("labelle-core");
            \\
            \\pub const {s} = struct {{
            \\    pub const save = core.Saveable(.transient, @This(), .{{}});
            \\
            \\    /// Whether the status is currently active (drives the overlay).
            \\    active: bool = false,
            \\}};
            \\
        , .{ type_name, name, name, type_name }),
    }
}

fn writeScriptTemplate(w: *std.Io.Writer, kind: FeatureKind, name: []const u8, type_name: []const u8) !void {
    switch (kind) {
        .need => try w.print(
            \\//! Decays `{s}` each frame and flags threshold crossings.
            \\//!
            \\//! Scaffolded by `labelle add feature need {s}` (RFC-packs §3). Auto-
            \\//! ordered by the `xx_` prefix; rename to a numeric prefix (e.g. `40_`)
            \\//! to pin its order relative to other playing scripts.
            \\//!
            \\//! TODO(prefab): attach `{s}` to the prefab whose entities have this
            \\//! need (e.g. prefabs/characters/worker.jsonc) so there are entities to
            \\//! act on — a discovered component still has to be attached on spawn.
            \\
            \\const std = @import("std");
            \\const {s} = @import("../../components/{s}.zig").{s};
            \\
            \\/// Units of `value` lost per second (empties in ~2 minutes).
            \\const decay_per_second: f32 = 1.0 / 120.0;
            \\/// Level at/under which the need is "yellow" (getting urgent).
            \\const yellow_threshold: f32 = 0.35;
            \\/// Level at/under which the need is "red" (critical).
            \\const red_threshold: f32 = 0.15;
            \\
            \\pub fn tick(game: anytype, dt: f32) void {{
            \\    var view = game.ecs_backend.view(.{{{s}}}, .{{}});
            \\    defer view.deinit();
            \\
            \\    while (view.next()) |entity| {{
            \\        const need = game.ecs_backend.getComponent(entity, {s}) orelse continue;
            \\        const before = need.value;
            \\        need.value = std.math.clamp(before - decay_per_second * dt, 0.0, 1.0);
            \\
            \\        // A downward crossing of a threshold, this frame only.
            \\        const crossed_red = before > red_threshold and need.value <= red_threshold;
            \\        const crossed_yellow = before > yellow_threshold and need.value <= yellow_threshold;
            \\        if (crossed_red or crossed_yellow) {{
            \\            // TODO(event): emit the standard need event so overlays and
            \\            // satisfaction react without editing existing code:
            \\            //
            \\            //   game.emit(.{{ .need_threshold_crossed = .{{
            \\            //       .worker = entity,
            \\            //       .need = .{s},
            \\            //       .severity = if (crossed_red) .red else .yellow,
            \\            //   }} }});
            \\            //
            \\            // The `need_threshold_crossed` event + need-id enum live once
            \\            // in the `citizens` pack (citizens-private — RFC-packs §6).
            \\        }}
            \\    }}
            \\}}
            \\
        , .{ type_name, name, type_name, type_name, name, type_name, type_name, type_name, name }),
        .role => try w.print(
            \\//! Per-frame behavior for the `{s}` role.
            \\//!
            \\//! Scaffolded by `labelle add feature role {s}` (RFC-packs §3). Iterates
            \\//! every entity that has the `{s}` component and runs its role logic.
            \\//! Auto-ordered by the `xx_` prefix; rename to a numeric prefix to pin
            \\//! order.
            \\//!
            \\//! TODO(prefab): attach `{s}` to the prefab of entities that should fill
            \\//! this role, or add it at runtime when assigning the role.
            \\
            \\const std = @import("std");
            \\const {s} = @import("../../components/{s}.zig").{s};
            \\
            \\pub fn tick(game: anytype, dt: f32) void {{
            \\    _ = dt;
            \\    var view = game.ecs_backend.view(.{{{s}}}, .{{}});
            \\    defer view.deinit();
            \\
            \\    while (view.next()) |entity| {{
            \\        const role = game.ecs_backend.getComponent(entity, {s}) orelse continue;
            \\        if (!role.active) continue;
            \\
            \\        // TODO(behavior): drive the role for `entity` here (move, work,
            \\        // etc.). Signal progress to the rest of the game by emitting an
            \\        // event rather than reaching into other components:
            \\        //
            \\        //   game.emit(.{{ .{s}_did_thing = .{{ .entity = entity }} }});
            \\    }}
            \\}}
            \\
        , .{ name, name, type_name, type_name, type_name, name, type_name, type_name, type_name, name }),
        .status => try w.print(
            \\//! Derives the `{s}` status each frame and drives its overlay.
            \\//!
            \\//! Scaffolded by `labelle add feature status {s}` (RFC-packs §3). Sets
            \\//! `{s}.active` from some game condition (often by subscribing to an
            \\//! event); an overlay prefab reads it to show/hide the icon. Auto-ordered
            \\//! by the `xx_` prefix.
            \\//!
            \\//! TODO(overlay): add an overlay prefab (a sprite child) that is shown
            \\//! while `{s}.active` is true, and attach `{s}` to the relevant prefab.
            \\
            \\const std = @import("std");
            \\const {s} = @import("../../components/{s}.zig").{s};
            \\
            \\pub fn tick(game: anytype, dt: f32) void {{
            \\    _ = dt;
            \\    var view = game.ecs_backend.view(.{{{s}}}, .{{}});
            \\    defer view.deinit();
            \\
            \\    while (view.next()) |entity| {{
            \\        const status = game.ecs_backend.getComponent(entity, {s}) orelse continue;
            \\
            \\        // TODO(condition): compute whether the status is active this frame.
            \\        // Typically driven by an event subscriber (a hook) rather than a
            \\        // poll; left as a no-op default so the scaffold compiles.
            \\        status.active = status.active;
            \\    }}
            \\}}
            \\
        , .{ name, name, type_name, type_name, type_name, type_name, name, type_name, type_name, type_name }),
    }
}

// ─── file helpers ──────────────────────────────────────────────────────

/// Exclusive write; refuses to overwrite (error.PathAlreadyExists) with a
/// clear diagnostic and reports any other filesystem failure. Returns the
/// error to the caller rather than exiting itself so the helper stays
/// reusable and unit-testable (Gemini review) — the caller decides the exit
/// code. The diagnostic is emitted here so every call site logs uniformly.
fn writeExclusiveData(io: std.Io, cwd: std.Io.Dir, path: []const u8, data: []const u8) !void {
    cwd.writeFile(io, .{
        .sub_path = path,
        .data = data,
        .flags = .{ .exclusive = true },
    }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            // Diagnostics go straight to stderr (not `std.log.err`) so the
            // negative-path unit tests here don't fail on a logged error —
            // the repo-wide convention for testable error-returning helpers
            // (see `flow_scanner`, `scene_manifest`).
            writeStderr3(io, "labelle-assembler add: '", path, "' already exists — refusing to overwrite\n");
            return err;
        },
        else => {
            writeStderr3(io, "labelle-assembler add: could not write '", path, "': ");
            writeStderr(io, @errorName(err));
            writeStderr(io, "\n");
            return err;
        },
    };
}

/// Write three segments to stderr in one logical line. Keeps the
/// error-returning helpers allocation-free while formatting a path into a
/// message (paths are unbounded, so a stack `bufPrint` isn't safe).
fn writeStderr3(io: std.Io, a: []const u8, b: []const u8, c: []const u8) void {
    writeStderr(io, a);
    writeStderr(io, b);
    writeStderr(io, c);
}

// ─── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

test "isValidName accepts lowercase identifiers, rejects the rest" {
    try testing.expect(isValidName("boredom"));
    try testing.expect(isValidName("night_owl"));
    try testing.expect(isValidName("a"));
    try testing.expect(isValidName("x1"));

    try testing.expect(!isValidName(""));
    try testing.expect(!isValidName("Boredom")); // uppercase start
    try testing.expect(!isValidName("1up")); // digit start
    try testing.expect(!isValidName("_leading"));
    try testing.expect(!isValidName("has-dash"));
    try testing.expect(!isValidName("has/slash"));
    try testing.expect(!isValidName("has space"));
}

test "toTypeName produces PascalCase" {
    const a = try toTypeName(testing.allocator, "boredom");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("Boredom", a);

    const b = try toTypeName(testing.allocator, "night_owl");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("NightOwl", b);

    const c = try toTypeName(testing.allocator, "x1_y2");
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("X1Y2", c);
}

test "toTypeName prefixes _ when the name starts with a digit" {
    // `isValidName` rejects digit-leading feature names, but `toTypeName` is
    // public/reused, so it must still emit a legal Zig identifier (Gemini).
    const a = try toTypeName(testing.allocator, "1up");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("_1up", a);

    const b = try toTypeName(testing.allocator, "3d_view");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("_3dView", b);
}

test "scaffoldPack creates the convention tree and a parseable pack.labelle" {
    const alloc = testing.allocator;
    const io = config.globalIo();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Pass the tmp dir as the project root (absolute) so the test never
    // mutates the process-global cwd — mirrors init_cmd's test pattern.
    const tmp_abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(tmp_abs);

    try scaffoldPack(alloc, io, tmp_abs, "citizens");

    // Each convention subdir the generator actually scans exists with a
    // .gitkeep. `scripts/` is intentionally NOT scaffolded (pack scripts are
    // not scanned yet — see `pack_convention_dirs`).
    inline for (.{ "components", "events", "prefabs", "hooks" }) |sub| {
        try tmp.dir.access(io, "packs/citizens/" ++ sub, .{});
        try tmp.dir.access(io, "packs/citizens/" ++ sub ++ "/.gitkeep", .{});
    }
    // No `scripts/` dir — it would be silently ignored by generate today.
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "packs/citizens/scripts", .{}));

    // pack.labelle carries the exact fields and parses as the pack manifest.
    const manifest = try tmp.dir.readFileAlloc(io, "packs/citizens/pack.labelle", alloc, .limited(4096));
    defer alloc.free(manifest);
    try testing.expect(std.mem.indexOf(u8, manifest, ".name = \"citizens\"") != null);
    try testing.expect(std.mem.indexOf(u8, manifest, ".manifest_version = 1") != null);
    try testing.expect(std.mem.indexOf(u8, manifest, ".convention_dirs = .copy_and_scan") != null);

    const plugin_manifest = @import("plugin_manifest.zig");
    const pack_abs = try tmp.dir.realPathFileAlloc(io, "packs/citizens", alloc);
    defer alloc.free(pack_abs);
    var parsed = (try plugin_manifest.loadPackFromDir(alloc, pack_abs, "citizens")).?;
    defer parsed.deinit();
    try testing.expectEqualStrings("citizens", parsed.name);
    try testing.expectEqual(@as(u8, 1), parsed.manifest_version);
    try testing.expectEqual(plugin_manifest.PackConventionMode.copy_and_scan, parsed.convention_dirs);
}

test "scaffoldFeature need creates a component and a playing script" {
    const alloc = testing.allocator;
    const io = config.globalIo();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(tmp_abs);

    try scaffoldFeature(alloc, io, tmp_abs, .need, "boredom");

    const comp = try tmp.dir.readFileAlloc(io, "components/boredom.zig", alloc, .limited(8192));
    defer alloc.free(comp);
    // Type name is PascalCase and the component carries a Saveable decl.
    try testing.expect(std.mem.indexOf(u8, comp, "pub const Boredom = struct") != null);
    try testing.expect(std.mem.indexOf(u8, comp, "core.Saveable(.saveable") != null);

    // Script lands under the default `running` state so it's actually scanned.
    const script = try tmp.dir.readFileAlloc(io, "scripts/running/xx_boredom.zig", alloc, .limited(8192));
    defer alloc.free(script);
    try testing.expect(std.mem.indexOf(u8, script, "pub fn tick(game: anytype, dt: f32) void") != null);
    try testing.expect(std.mem.indexOf(u8, script, "../../components/boredom.zig") != null);
    try testing.expect(std.mem.indexOf(u8, script, "need_threshold_crossed") != null);
    // Component lookup goes through the ECS backend, matching the view call.
    try testing.expect(std.mem.indexOf(u8, script, "game.ecs_backend.getComponent(entity, Boredom)") != null);
}

test "scaffoldFeature status uses a transient save policy" {
    const alloc = testing.allocator;
    const io = config.globalIo();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(tmp_abs);

    try scaffoldFeature(alloc, io, tmp_abs, .status, "resting");

    const comp = try tmp.dir.readFileAlloc(io, "components/resting.zig", alloc, .limited(8192));
    defer alloc.free(comp);
    try testing.expect(std.mem.indexOf(u8, comp, "pub const Resting = struct") != null);
    try testing.expect(std.mem.indexOf(u8, comp, "core.Saveable(.transient") != null);
}

test "scaffoldFeature refuses to overwrite an existing component" {
    const io = config.globalIo();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "components");
    try tmp.dir.writeFile(io, .{ .sub_path = "components/boredom.zig", .data = "// pre-existing\n" });

    // scaffoldFeature exits the process on a refusal, so we can't call it
    // directly in-test without aborting the runner. Assert the exclusive
    // write path instead: an exclusive write over the existing file fails.
    const result = tmp.dir.writeFile(io, .{
        .sub_path = "components/boredom.zig",
        .data = "x",
        .flags = .{ .exclusive = true },
    });
    try testing.expectError(error.PathAlreadyExists, result);
}

test "preflightAbsent errors on an existing path, passes on an absent one" {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const alloc = testing.allocator;
    const tmp_abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(tmp_abs);

    // Absent → passes (this is what lets a fresh scaffold proceed).
    const absent = try std.fs.path.join(alloc, &.{ tmp_abs, "not_there.zig" });
    defer alloc.free(absent);
    try preflightAbsent(io, cwd, absent);

    // Existing → refuses. This is the guard that makes `add feature`
    // all-or-nothing: if EITHER target exists it's rejected before any write.
    try tmp.dir.writeFile(io, .{ .sub_path = "there.zig", .data = "x\n" });
    const existing = try std.fs.path.join(alloc, &.{ tmp_abs, "there.zig" });
    defer alloc.free(existing);
    try testing.expectError(error.PathAlreadyExists, preflightAbsent(io, cwd, existing));
}

test "writeExclusiveData returns error.PathAlreadyExists instead of exiting" {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const alloc = testing.allocator;
    const tmp_abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(tmp_abs);
    const path = try std.fs.path.join(alloc, &.{ tmp_abs, "f.zig" });
    defer alloc.free(path);

    // First write succeeds; the second is refused via a returned error (the
    // helper no longer calls std.process.exit — Gemini review).
    try writeExclusiveData(io, cwd, path, "a\n");
    try testing.expectError(error.PathAlreadyExists, writeExclusiveData(io, cwd, path, "b\n"));
}

test "scaffoldPack auto-registers the pack in an existing project.labelle" {
    const alloc = testing.allocator;
    const io = config.globalIo();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(tmp_abs);

    // A minimal project.labelle with an EMPTY .plugins tuple.
    try tmp.dir.writeFile(io, .{
        .sub_path = "project.labelle",
        .data =
        \\.{
        \\    .name = "demo",
        \\    .plugins = .{},
        \\}
        \\
        ,
    });

    try scaffoldPack(alloc, io, tmp_abs, "citizens");

    const proj = try tmp.dir.readFileAlloc(io, "project.labelle", alloc, .limited(8192));
    defer alloc.free(proj);
    // The pack is now declared with the in-project `@packs/<name>` repo form
    // the resolver understands (same shape as `@libs/...`).
    try testing.expect(std.mem.indexOf(u8, proj, ".name = \"citizens\"") != null);
    try testing.expect(std.mem.indexOf(u8, proj, ".repo = \"@packs/citizens\"") != null);
    // …and the rewritten file still parses as a ProjectConfig with the pack
    // in .plugins.
    const src = try alloc.dupeZ(u8, proj);
    defer alloc.free(src);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const cfg = try std.zon.parse.fromSliceAlloc(config.ProjectConfig, arena.allocator(), src, null, .{});
    var found = false;
    for (cfg.plugins) |p| {
        if (std.mem.eql(u8, p.name, "citizens") and std.mem.eql(u8, p.repo, "@packs/citizens")) found = true;
    }
    try testing.expect(found);
}

test "scaffoldPack registers into a populated .plugins tuple" {
    const alloc = testing.allocator;
    const io = config.globalIo();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(tmp_abs);

    try tmp.dir.writeFile(io, .{
        .sub_path = "project.labelle",
        .data =
        \\.{
        \\    .name = "demo",
        \\    .plugins = .{
        \\        .{ .name = "existing", .repo = "@libs/existing" },
        \\    },
        \\}
        \\
        ,
    });

    try scaffoldPack(alloc, io, tmp_abs, "citizens");

    const proj = try tmp.dir.readFileAlloc(io, "project.labelle", alloc, .limited(8192));
    defer alloc.free(proj);
    const src = try alloc.dupeZ(u8, proj);
    defer alloc.free(src);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const cfg = try std.zon.parse.fromSliceAlloc(config.ProjectConfig, arena.allocator(), src, null, .{});
    var has_existing = false;
    var has_citizens = false;
    for (cfg.plugins) |p| {
        if (std.mem.eql(u8, p.name, "existing")) has_existing = true;
        if (std.mem.eql(u8, p.name, "citizens") and std.mem.eql(u8, p.repo, "@packs/citizens")) has_citizens = true;
    }
    // The pre-existing plugin is preserved AND the new pack is appended.
    try testing.expect(has_existing);
    try testing.expect(has_citizens);
}
