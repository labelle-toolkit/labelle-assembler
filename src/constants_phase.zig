//! Game constants, phase 1 (RFC-CONSTANTS in labelle-engine#811 / #810).
//!
//! Scans `constants/*.yaml` in the game dir, parses each through the strict
//! subset (`constants_yaml.zig`), and emits `constants.zig` into the target
//! dir: one nested namespace per file, every value a `pub const` carrying the
//! literal exactly as written. `5.0` stays comptime_float and `5` stays
//! comptime_int, which is the distinction the RFC's scalar-kind rule needs.
//!
//! The invariant every assembler feature holds: a project with no `constants/`
//! directory emits nothing and keeps a byte-identical build.zig. A previously
//! generated `constants.zig` is deleted when the directory goes away, so a
//! stale module cannot shadow the feature being turned off.
//!
//! Phase 2 lives here too: after a successful emit, the game's .zig sources
//! are scanned (usage_scan.zig -- conservative alias widening, warnings only)
//! and every constant nothing reads is named with its yaml file and line.
//! Phase 3: packs ship their own constants, namespaced <pack>__<file>, and
//! the game overrides them by filename -- see runPhase.
const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("constants_yaml.zig");
const usage = @import("usage_scan.zig");

// Not config.globalIo(): config.zig pulls in build_options, which would make
// this file untestable standalone (`zig test src/constants_phase.zig`) for the
// sake of one accessor. Same mechanism, locally owned, lazily initialised.
var _threaded: std.Io.Threaded = undefined;
var _io: std.Io = undefined;
var _io_ready = false;

fn phaseIo() std.Io {
    if (!_io_ready) {
        _threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        _io = _threaded.io();
        _io_ready = true;
    }
    return _io;
}

pub const GENERATED_FILENAME = "constants.zig";

/// A pack that may ship constants: its declared name and resolved source dir.
pub const PackConstants = struct {
    name: []const u8,
    src_dir: []const u8,
};

/// Runs the phase. Returns true when a `constants.zig` was emitted (the build
/// wiring keys off this), false when neither the game nor any pack ships a
/// `constants/` directory.
///
/// Phase 3 (RFC-CONSTANTS section 1.1): packs bring their own, namespaced
/// `<pack>__<file>`, and the game overrides by carrying the prefixed name as
/// a filename -- `constants/citizens__hunger.yaml` retunes the citizens
/// pack's hunger domain. Every write under a pack's namespace is an override:
/// one that matches nothing the pack defines is an error, and an override
/// must keep the scalar kind it replaces. The game takes precedence.
///
/// Validation failures print `file:line: message` to stderr and return
/// `error.ConstantsInvalid`, matching the tone of the other phases: the value
/// someone mistyped is named, not summarised.
pub fn runPhase(
    allocator: Allocator,
    game_dir: []const u8,
    target_dir: []const u8,
    packs: []const PackConstants,
    /// False for the tests target: generate runs once per target, and the
    /// usage warnings would otherwise print twice and scan the tree twice.
    diagnostics: bool,
) !bool {
    const io = phaseIo();
    const cwd = std.Io.Dir.cwd();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Namespace registry: namespace ident -> (tree, defining file). Packs
    // load first, so a game override file finds its target already present;
    // everything then emits in one sorted pass.
    var reg: Registry = .{};
    var had_error = false;

    // 1. Pack constants (phase 3): packs ship their own, surfacing as
    //    C.<pack>__<stem>.*.
    for (packs) |pk| {
        const pdir_path = try std.fs.path.join(arena, &.{ pk.src_dir, "constants" });
        var pdir = cwd.openDir(io, pdir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue, // ships no constants
            else => return err, // permissions/I-O: silently dropping a pack is worse
        };
        defer pdir.close(io);
        const pfiles = try listYaml(arena, io, &pdir);
        for (pfiles) |name| {
            const stem = name[0 .. name.len - ".yaml".len];
            const display = try std.fmt.allocPrint(arena, "packs/{s}/constants/{s}", .{ pk.name, name });
            if (!isIdentifier(stem)) {
                std.debug.print("{s}: filename must be a Zig identifier (it becomes part of the C namespace)\n", .{display});
                had_error = true;
                continue;
            }
            const source = pdir.readFileAlloc(io, name, arena, .limited(1024 * 1024)) catch |err| switch (err) {
                error.StreamTooLong => {
                    std.debug.print("{s}: file exceeds 1 MiB\n", .{display});
                    had_error = true;
                    continue;
                },
                else => return err,
            };
            switch (try yaml.parse(arena, source)) {
                .fail => |e| {
                    std.debug.print("{s}:{d}: {s}\n", .{ display, e.line, e.msg });
                    had_error = true;
                },
                .root => |root| {
                    var pfx_buf: [128]u8 = undefined;
                    const pfx = sanitizePackIdent(pk.name, &pfx_buf);
                    const ns = try std.fmt.allocPrint(arena, "{s}__{s}", .{ pfx, stem });
                    // Composite collisions are possible with valid inputs:
                    // pack `a` + file `b__c.yaml` and pack `a__b` + file
                    // `c.yaml` both compose `a__b__c`. Two declarations of one
                    // namespace would not compile, and an override would apply
                    // to whichever the lookup found first.
                    if (reg.find(ns)) |existing| {
                        std.debug.print("{s}: namespace C.{s} is already defined by {s}\n", .{ display, ns, existing.file });
                        had_error = true;
                        continue;
                    }
                    const stored = try arena.create(yaml.Mapping);
                    stored.* = root;
                    try reg.entries.append(arena, .{ .ns = ns, .file = display, .tree = stored });
                },
            }
        }
    }

    // 2. Game constants: plain domains define; `<pack>__<domain>` filenames
    //    override, and the game takes precedence (RFC-CONSTANTS section 1.1).
    const src_path = try std.fs.path.join(arena, &.{ game_dir, "constants" });
    var game_files: []const []const u8 = &.{};
    var src_dir_opt: ?std.Io.Dir = cwd.openDir(io, src_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => null,
        else => return err,
    };
    defer if (src_dir_opt) |*d| d.close(io);
    if (src_dir_opt) |*d| game_files = try listYaml(arena, io, d);

    if (reg.entries.items.len == 0 and game_files.len == 0) {
        const stale = try std.fs.path.join(arena, &.{ target_dir, GENERATED_FILENAME });
        cwd.deleteFile(io, stale) catch {};
        return false;
    }

    for (game_files) |name| {
        const stem = name[0 .. name.len - ".yaml".len];
        const display = try std.fmt.allocPrint(arena, "constants/{s}", .{name});
        if (!isIdentifier(stem)) {
            std.debug.print("{s}: filename must be a Zig identifier (it becomes the C.{s} namespace)\n", .{ display, stem });
            had_error = true;
            continue;
        }
        const source = src_dir_opt.?.readFileAlloc(io, name, arena, .limited(1024 * 1024)) catch |err| switch (err) {
            error.StreamTooLong => {
                std.debug.print("{s}: file exceeds 1 MiB\n", .{display});
                had_error = true;
                continue;
            },
            else => return err,
        };
        var parsed: yaml.Mapping = undefined;
        switch (try yaml.parse(arena, source)) {
            .fail => |e| {
                std.debug.print("{s}:{d}: {s}\n", .{ display, e.line, e.msg });
                had_error = true;
                continue;
            },
            .root => |root| parsed = root,
        }

        if (std.mem.indexOf(u8, stem, "__") != null) {
            // Every write under a pack namespace is an override, and one that
            // matches nothing is an error -- a silent create here is exactly
            // the tuning-reverts-on-upgrade failure the rule prevents.
            const target = reg.find(stem) orelse {
                std.debug.print("{s}: overrides C.{s}, but no pack defines that namespace\n", .{ display, stem });
                had_error = true;
                continue;
            };
            if (!try mergeOverride(arena, display, target.tree, &parsed, "")) had_error = true;
        } else {
            if (reg.find(stem)) |existing| {
                std.debug.print("{s}: namespace C.{s} is already defined by {s}\n", .{ display, stem, existing.file });
                had_error = true;
                continue;
            }
            const stored = try arena.create(yaml.Mapping);
            stored.* = parsed;
            try reg.entries.append(arena, .{ .ns = stem, .file = display, .tree = stored });
        }
    }

    if (had_error) return error.ConstantsInvalid;

    // 3. Emit, sorted by namespace for determinism.
    std.mem.sort(Registry.Entry, reg.entries.items, {}, struct {
        fn lessThan(_: void, a: Registry.Entry, b: Registry.Entry) bool {
            return std.mem.order(u8, a.ns, b.ns) == .lt;
        }
    }.lessThan);

    var leaves: std.ArrayList(Leaf) = .empty;
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("//! Generated by labelle-assembler from constants/*.yaml " ++ [_]u8{0xe2} ++ [_]u8{0x80} ++ [_]u8{0x94} ++ " do not edit.\n" ++
        "//! Values are emitted verbatim, so 5.0 is comptime_float and 5 is\n" ++
        "//! comptime_int; they coerce at the use site (RFC-CONSTANTS " ++ [_]u8{0xc2} ++ [_]u8{0xa7} ++ "3).\n\npub const C = struct {\n");
    for (reg.entries.items) |e| {
        try w.print("    pub const @\"{s}\" = struct {{\n", .{e.ns});
        try emitMapping(w, e.tree, 2);
        try w.writeAll("    };\n");
        try collectLeaves(arena, &leaves, e.file, e.ns, e.tree);
    }
    try w.writeAll("};\n");

    if (had_error) return error.ConstantsInvalid;

    const dst = try std.fs.path.join(arena, &.{ target_dir, GENERATED_FILENAME });
    try cwd.writeFile(io, .{ .sub_path = dst, .data = out.writer.buffered() });

    // Phase 2: usage warnings. Never fails the build -- a warning that can be
    // wrong teaches people to ignore it, so the scan errs toward "used" and
    // this errs toward silence on any I/O trouble.
    if (diagnostics) warnUnused(arena, game_dir, packs, leaves.items) catch {};
    return true;
}

/// Namespaces awaiting emission, insertion-ordered until the final sort.
const Registry = struct {
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        ns: []const u8,
        file: []const u8,
        tree: *yaml.Mapping,
    };

    fn find(self: *const Registry, ns: []const u8) ?*Entry {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.ns, ns)) return e;
        }
        return null;
    }
};

/// Sorted `*.yaml` names in a directory.
fn listYaml(arena: Allocator, io: std.Io, dir: *std.Io.Dir) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".yaml")) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return names.items;
}

/// Applies a game override file onto a pack's tree, in place. Returns false
/// (after printing) on any violation of the two rules: every key must match
/// one the pack defines, and a scalar keeps its kind.
fn mergeOverride(
    arena: Allocator,
    display: []const u8,
    base: *yaml.Mapping,
    override: *const yaml.Mapping,
    prefix: []const u8,
) Allocator.Error!bool {
    var ok = true;
    for (override.entries.items) |oe| {
        const path = if (prefix.len == 0)
            oe.key
        else
            try std.fmt.allocPrint(arena, "{s}.{s}", .{ prefix, oe.key });

        const be = findEntry(base, oe.key) orelse {
            std.debug.print("{s}:{d}: '{s}' overrides nothing -- the pack does not define it. A typo here, or a key the pack renamed, would otherwise silently keep the pack's value\n", .{ display, oe.line, path });
            ok = false;
            continue;
        };
        switch (oe.node) {
            .mapping => |om| switch (be.node) {
                .mapping => |bm| {
                    if (!try mergeOverride(arena, display, bm, om, path)) ok = false;
                },
                .scalar => {
                    std.debug.print("{s}:{d}: '{s}' is a value in the pack, not a block\n", .{ display, oe.line, path });
                    ok = false;
                },
            },
            .scalar => |os| switch (be.node) {
                .mapping => {
                    std.debug.print("{s}:{d}: '{s}' is a block in the pack, not a value\n", .{ display, oe.line, path });
                    ok = false;
                },
                .scalar => |bs| {
                    if (os.kind != bs.kind) {
                        std.debug.print("{s}:{d}: '{s}' changes kind from {s} to {s} -- values are untyped and coerce at the use site, so an int-for-float override can change behaviour without changing the number. Keep the kind: write {s}\n", .{ display, os.line, path, @tagName(bs.kind), @tagName(os.kind), exampleOfKind(bs.kind) });
                        ok = false;
                    } else {
                        // Carry the overriding file, so an unused warning for
                        // this leaf points at the game's line in the game's
                        // file rather than the game's line in the pack's file.
                        var replaced = os;
                        replaced.src = display;
                        be.node = .{ .scalar = replaced };
                    }
                },
            },
        }
    }
    return ok;
}

fn findEntry(m: *yaml.Mapping, key: []const u8) ?*yaml.Mapping.Entry {
    for (m.entries.items) |*e| {
        if (std.mem.eql(u8, e.key, key)) return e;
    }
    return null;
}

fn exampleOfKind(kind: yaml.ScalarKind) []const u8 {
    return switch (kind) {
        .int => "5, not 5.0",
        .float => "5.0, not 5",
        .bool => "true or false",
        .string => "a quoted string",
    };
}

/// One emitted constant: where it can be addressed from code, and where it
/// was written, so the warning points at the yaml rather than at nothing.
const Leaf = struct {
    /// Root-relative dotted path, domain first: "decay.hunger.rate".
    path: []const u8,
    file: []const u8,
    line: usize,
};

fn collectLeaves(
    arena: Allocator,
    leaves: *std.ArrayList(Leaf),
    file: []const u8,
    prefix: []const u8,
    m: *const yaml.Mapping,
) Allocator.Error!void {
    for (m.entries.items) |e| {
        const path = try std.fmt.allocPrint(arena, "{s}.{s}", .{ prefix, e.key });
        switch (e.node) {
            .mapping => |child| try collectLeaves(arena, leaves, file, path, child),
            .scalar => |sc| try leaves.append(arena, .{ .path = path, .file = sc.src orelse file, .line = sc.line }),
        }
    }
}

/// Scans every .zig file under the game dir (skipping generated and vendored
/// trees) and prints one warning per constant nothing reads.
fn warnUnused(arena: Allocator, game_dir: []const u8, packs: []const PackConstants, leaves: []const Leaf) !void {
    var marks = usage.Marks.init(arena);
    try collectMarks(arena, &marks, game_dir);
    // A cached pack's sources live outside the game tree, and its scripts are
    // the likeliest readers of its own constants -- not scanning them would
    // fire false "unused" warnings, the direction the design forbids.
    for (packs) |pk| {
        if (!isUnderDir(pk.src_dir, game_dir)) {
            try collectMarks(arena, &marks, pk.src_dir);
        }
    }

    for (leaves) |leaf| {
        if (!marks.covers(leaf.path)) {
            std.debug.print("warning: {s}:{d}: C.{s} is never read\n", .{ leaf.file, leaf.line, leaf.path });
        }
    }
}

/// Skipped wholesale: generated output, vendored deps, caches, VCS.
const skip_dirs = [_][]const u8{ ".labelle", ".git", "deps", "zig-out", "zig-cache", ".zig-cache" };

fn collectMarks(arena: Allocator, marks: *usage.Marks, dir_path: []const u8) !void {
    const io = phaseIo();
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch blk: {
        // An aborted iteration may have hidden uses; widen rather than warn
        // falsely.
        marks.all = true;
        break :blk null;
    }) |entry| {
        switch (entry.kind) {
            .directory => {
                var skip = false;
                for (skip_dirs) |d| {
                    if (std.mem.eql(u8, entry.name, d)) skip = true;
                }
                if (skip) continue;
                const sub = try std.fs.path.join(arena, &.{ dir_path, entry.name });
                try collectMarks(arena, marks, sub);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                // An unreadable file could contain uses. Missing them fires
                // false "unused" warnings -- the forbidden direction -- so
                // widen instead of skipping silently.
                const source = dir.readFileAlloc(io, entry.name, arena, .limited(4 * 1024 * 1024)) catch {
                    marks.all = true;
                    continue;
                };
                try usage.scanSource(marks, .{}, source);
            },
            else => {},
        }
    }
}

fn emitMapping(w: *std.Io.Writer, m: *const yaml.Mapping, depth: usize) std.Io.Writer.Error!void {
    for (m.entries.items) |e| {
        try writeIndent(w, depth);
        switch (e.node) {
            .mapping => |child| {
                // @""-quoted: a key named like a Zig keyword or primitive
                // ("fn", "type", "bool") would otherwise emit a declaration
                // that does not compile. The generated name is identical for
                // ordinary keys; call sites for awkward ones use C.a.@"fn".
                try w.print("pub const @\"{s}\" = struct {{\n", .{e.key});
                try emitMapping(w, child, depth + 1);
                try writeIndent(w, depth);
                try w.writeAll("};\n");
            },
            .scalar => |sc| switch (sc.kind) {
                // Verbatim: the emitted literal is the YAML text, which is
                // what keeps int/float distinct and `1.20` printing as 1.20.
                .int, .float, .bool => try w.print("pub const @\"{s}\" = {s};\n", .{ e.key, sc.text }),
                .string => {
                    try w.print("pub const @\"{s}\" = \"", .{e.key});
                    try writeEscaped(w, sc.text);
                    try w.writeAll("\";\n");
                },
            },
        }
    }
}

fn writeIndent(w: *std.Io.Writer, depth: usize) std.Io.Writer.Error!void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try w.writeAll("    ");
}

fn writeEscaped(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| switch (c) {
        '\\' => try w.writeAll("\\\\"),
        '"' => try w.writeAll("\\\""),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        '\r' => try w.writeAll("\\r"),
        else => {
            // Remaining control bytes would land raw inside a Zig string
            // literal, which does not compile. \xNN keeps the generated file
            // parseable whatever the YAML carried.
            if (c < 0x20 or c == 0x7F) {
                try w.print("\\x{x:0>2}", .{c});
            } else {
                try w.writeByte(c);
            }
        },
    };
}

/// Prefix containment on a path-component boundary. A bare prefix test calls
/// `<root>/game-pack` a child of `<root>/game` and then skips scanning it,
/// which produces false "unused" warnings for that pack's constants.
fn isUnderDir(child: []const u8, parent: []const u8) bool {
    if (!std.mem.startsWith(u8, child, parent)) return false;
    if (child.len == parent.len) return true;
    const c = child[parent.len];
    return c == '/' or c == '\\';
}

/// Mirror of codegen/scan/sanitize.zig's sanitizePluginIdent, which cannot be
/// imported here without dragging build_options in. A pack named `my-pack`
/// already surfaces as `my_pack__*` everywhere else in the pipeline; constants
/// must agree or a valid pack is rejected the moment it ships a tuning value.
fn sanitizePackIdent(name: []const u8, buf: *[128]u8) []const u8 {
    var i: usize = 0;
    if (name.len > 0 and std.ascii.isDigit(name[0])) {
        buf[i] = '_';
        i += 1;
    }
    for (name) |c| {
        if (i >= buf.len) break;
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '_' => buf[i] = c,
            else => buf[i] = '_',
        }
        i += 1;
    }
    return buf[0..i];
}

fn isIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!std.ascii.isAlphabetic(s[0]) and s[0] != '_') return false;
    for (s[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "runPhase: no constants dir emits nothing and cleans a stale file" {
    const io = phaseIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "game");
    try tmp.dir.createDirPath(io, "target");
    // A stale file from a previous run with constants/ present.
    try tmp.dir.writeFile(io, .{ .sub_path = "target/" ++ GENERATED_FILENAME, .data = "// stale\n" });

    var rel_buf: [96]u8 = undefined;
    const rel = try std.fmt.bufPrint(&rel_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const game = try std.fs.path.join(testing.allocator, &.{ rel, "game" });
    defer testing.allocator.free(game);
    const target = try std.fs.path.join(testing.allocator, &.{ rel, "target" });
    defer testing.allocator.free(target);

    try testing.expectEqual(false, try runPhase(testing.allocator, game, target, &.{}, true));
    // The stale file is gone.
    try testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "target/" ++ GENERATED_FILENAME, .{}));
}

test "runPhase: files become namespaces, values stay verbatim, order is by filename" {
    const io = phaseIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "game/constants");
    try tmp.dir.createDirPath(io, "target");
    try tmp.dir.writeFile(io, .{ .sub_path = "game/constants/decay.yaml", .data =
        \\hunger:
        \\  rate: 0.02
        \\health:
        \\  drain_rate: 0.0   # DISABLED
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "game/constants/construction.yaml", .data =
        \\build_time: 5.0
        \\max_workers: 4
        \\site_label: "em obras"
        \\enabled: true
        \\
    });
    // Not .yaml: ignored, not an error.
    try tmp.dir.writeFile(io, .{ .sub_path = "game/constants/notes.txt", .data = "irrelevant" });

    var rel_buf: [96]u8 = undefined;
    const rel = try std.fmt.bufPrint(&rel_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const game = try std.fs.path.join(testing.allocator, &.{ rel, "game" });
    defer testing.allocator.free(game);
    const target = try std.fs.path.join(testing.allocator, &.{ rel, "target" });
    defer testing.allocator.free(target);

    try testing.expectEqual(true, try runPhase(testing.allocator, game, target, &.{}, true));

    const generated = try tmp.dir.readFileAlloc(io, "target/" ++ GENERATED_FILENAME, testing.allocator, .limited(64 * 1024));
    defer testing.allocator.free(generated);

    // construction sorts before decay, so namespaces come in that order.
    const c_at = std.mem.indexOf(u8, generated, "pub const @\"construction\" = struct {").?;
    const d_at = std.mem.indexOf(u8, generated, "pub const @\"decay\" = struct {").?;
    try testing.expect(c_at < d_at);

    try testing.expect(std.mem.indexOf(u8, generated, "pub const @\"build_time\" = 5.0;") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "pub const @\"max_workers\" = 4;") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "pub const @\"site_label\" = \"em obras\";") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "pub const @\"enabled\" = true;") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "pub const @\"drain_rate\" = 0.0;") != null);

    // And the generated file is real Zig with the values reachable: compile it.
    // (The ast-check is cheap and catches emitter breakage structurally.)
    const source_z = try testing.allocator.dupeZ(u8, generated);
    defer testing.allocator.free(source_z);
    var ast = try std.zig.Ast.parse(testing.allocator, source_z, .zig);
    defer ast.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), ast.errors.len);
}

test "runPhase: a bad value names the file and line and fails the phase" {
    const io = phaseIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "game/constants");
    try tmp.dir.createDirPath(io, "target");
    try tmp.dir.writeFile(io, .{ .sub_path = "game/constants/flags.yaml", .data = "enabled: no\n" });

    var rel_buf: [96]u8 = undefined;
    const rel = try std.fmt.bufPrint(&rel_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const game = try std.fs.path.join(testing.allocator, &.{ rel, "game" });
    defer testing.allocator.free(game);
    const target = try std.fs.path.join(testing.allocator, &.{ rel, "target" });
    defer testing.allocator.free(target);

    try testing.expectError(error.ConstantsInvalid, runPhase(testing.allocator, game, target, &.{}, true));
    // Nothing half-written.
    try testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "target/" ++ GENERATED_FILENAME, .{}));
}

test "runPhase: a non-identifier filename is rejected" {
    const io = phaseIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "game/constants");
    try tmp.dir.createDirPath(io, "target");
    try tmp.dir.writeFile(io, .{ .sub_path = "game/constants/ship-speeds.yaml", .data = "a: 1\n" });

    var rel_buf: [96]u8 = undefined;
    const rel = try std.fmt.bufPrint(&rel_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const game = try std.fs.path.join(testing.allocator, &.{ rel, "game" });
    defer testing.allocator.free(game);
    const target = try std.fs.path.join(testing.allocator, &.{ rel, "target" });
    defer testing.allocator.free(target);

    try testing.expectError(error.ConstantsInvalid, runPhase(testing.allocator, game, target, &.{}, true));
}

test "collectMarks walks the game tree and skips generated dirs" {
    const io = phaseIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "game/scripts/playing");
    try tmp.dir.createDirPath(io, "game/libs/needs");
    try tmp.dir.createDirPath(io, "game/.labelle/target");
    try tmp.dir.writeFile(io, .{
        .sub_path = "game/scripts/playing/10_decay.zig",
        .data = "const C = @import(\"constants\").C;\nconst cfg = C.decay.hunger;\npub fn tick() f32 { return cfg.rate; }\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "game/libs/needs/config.zig",
        .data = "const C = @import(\"constants\").C;\npub const t = C.construction.build_time;\n",
    });
    // A use inside generated output must NOT count -- it is our own emission.
    try tmp.dir.writeFile(io, .{
        .sub_path = "game/.labelle/target/main.zig",
        .data = "const C = @import(\"constants\").C;\npub const x = C.construction.max_workers;\n",
    });

    var rel_buf: [96]u8 = undefined;
    const rel = try std.fmt.bufPrint(&rel_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const game = try std.fs.path.join(testing.allocator, &.{ rel, "game" });
    defer testing.allocator.free(game);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var marks = usage.Marks.init(arena_state.allocator());
    try collectMarks(arena_state.allocator(), &marks, game);

    try testing.expect(marks.covers("decay.hunger.rate")); // via the alias subtree
    try testing.expect(marks.covers("construction.build_time")); // direct, from libs/
    try testing.expect(!marks.covers("construction.max_workers")); // only in .labelle
    try testing.expect(!marks.covers("decay.health.drain_rate"));
}

fn tmpPaths(tmp: *std.testing.TmpDir, alloc: Allocator) !struct { game: []const u8, target: []const u8, root: []const u8 } {
    var rel_buf: [96]u8 = undefined;
    const rel = try std.fmt.bufPrint(&rel_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    return .{
        .game = try std.fs.path.join(alloc, &.{ rel, "game" }),
        .target = try std.fs.path.join(alloc, &.{ rel, "target" }),
        .root = try alloc.dupe(u8, rel),
    };
}

test "phase 3: pack constants surface namespaced, game override wins, kind kept" {
    const io = phaseIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "game/constants");
    try tmp.dir.createDirPath(io, "target");
    try tmp.dir.createDirPath(io, "thepack/constants");
    try tmp.dir.writeFile(io, .{ .sub_path = "thepack/constants/hunger.yaml", .data = "rate: 0.02\nlimit: 4\nnested:\n  deep: 1.5\n" });
    // The game retunes rate and the nested value; limit rides through.
    try tmp.dir.writeFile(io, .{ .sub_path = "game/constants/citizens__hunger.yaml", .data = "rate: 0.05\nnested:\n  deep: 2.5\n" });
    // And ships a plain domain of its own.
    try tmp.dir.writeFile(io, .{ .sub_path = "game/constants/ui.yaml", .data = "margin: 8\n" });

    const paths = try tmpPaths(&tmp, testing.allocator);
    defer testing.allocator.free(paths.game);
    defer testing.allocator.free(paths.target);
    defer testing.allocator.free(paths.root);
    const pack_dir = try std.fs.path.join(testing.allocator, &.{ paths.root, "thepack" });
    defer testing.allocator.free(pack_dir);

    const packs = [_]PackConstants{.{ .name = "citizens", .src_dir = pack_dir }};
    try testing.expectEqual(true, try runPhase(testing.allocator, paths.game, paths.target, &packs, true));

    const generated = try tmp.dir.readFileAlloc(io, "target/" ++ GENERATED_FILENAME, testing.allocator, .limited(64 * 1024));
    defer testing.allocator.free(generated);

    try testing.expect(std.mem.indexOf(u8, generated, "pub const @\"citizens__hunger\" = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "pub const @\"rate\" = 0.05;") != null); // overridden
    try testing.expect(std.mem.indexOf(u8, generated, "pub const @\"limit\" = 4;") != null); // pack default rides
    try testing.expect(std.mem.indexOf(u8, generated, "pub const @\"deep\" = 2.5;") != null); // deep override
    try testing.expect(std.mem.indexOf(u8, generated, "pub const @\"ui\" = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "0.02") == null); // the pack value is gone
}

test "phase 3: an override matching nothing is an error" {
    const io = phaseIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "game/constants");
    try tmp.dir.createDirPath(io, "target");
    try tmp.dir.createDirPath(io, "thepack/constants");
    try tmp.dir.writeFile(io, .{ .sub_path = "thepack/constants/hunger.yaml", .data = "rate: 0.02\n" });
    // 'rte' is the RFC's own typo example.
    try tmp.dir.writeFile(io, .{ .sub_path = "game/constants/citizens__hunger.yaml", .data = "rte: 0.05\n" });

    const paths = try tmpPaths(&tmp, testing.allocator);
    defer testing.allocator.free(paths.game);
    defer testing.allocator.free(paths.target);
    defer testing.allocator.free(paths.root);
    const pack_dir = try std.fs.path.join(testing.allocator, &.{ paths.root, "thepack" });
    defer testing.allocator.free(pack_dir);

    const packs = [_]PackConstants{.{ .name = "citizens", .src_dir = pack_dir }};
    try testing.expectError(error.ConstantsInvalid, runPhase(testing.allocator, paths.game, paths.target, &packs, true));
}

test "phase 3: an override changing scalar kind is an error" {
    const io = phaseIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "game/constants");
    try tmp.dir.createDirPath(io, "target");
    try tmp.dir.createDirPath(io, "thepack/constants");
    try tmp.dir.writeFile(io, .{ .sub_path = "thepack/constants/hunger.yaml", .data = "rate: 0.02\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "game/constants/citizens__hunger.yaml", .data = "rate: 5\n" });

    const paths = try tmpPaths(&tmp, testing.allocator);
    defer testing.allocator.free(paths.game);
    defer testing.allocator.free(paths.target);
    defer testing.allocator.free(paths.root);
    const pack_dir = try std.fs.path.join(testing.allocator, &.{ paths.root, "thepack" });
    defer testing.allocator.free(pack_dir);

    const packs = [_]PackConstants{.{ .name = "citizens", .src_dir = pack_dir }};
    try testing.expectError(error.ConstantsInvalid, runPhase(testing.allocator, paths.game, paths.target, &packs, true));
}

test "phase 3: an override file for a namespace no pack defines is an error" {
    const io = phaseIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "game/constants");
    try tmp.dir.createDirPath(io, "target");
    try tmp.dir.writeFile(io, .{ .sub_path = "game/constants/citizens__hunger.yaml", .data = "rate: 0.05\n" });

    const paths = try tmpPaths(&tmp, testing.allocator);
    defer testing.allocator.free(paths.game);
    defer testing.allocator.free(paths.target);
    defer testing.allocator.free(paths.root);

    try testing.expectError(error.ConstantsInvalid, runPhase(testing.allocator, paths.game, paths.target, &.{}, true));
}

test "phase 3: pack constants alone (no game constants dir) still emit" {
    const io = phaseIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "game");
    try tmp.dir.createDirPath(io, "target");
    try tmp.dir.createDirPath(io, "thepack/constants");
    try tmp.dir.writeFile(io, .{ .sub_path = "thepack/constants/ship.yaml", .data = "speed: 280\n" });

    const paths = try tmpPaths(&tmp, testing.allocator);
    defer testing.allocator.free(paths.game);
    defer testing.allocator.free(paths.target);
    defer testing.allocator.free(paths.root);
    const pack_dir = try std.fs.path.join(testing.allocator, &.{ paths.root, "thepack" });
    defer testing.allocator.free(pack_dir);

    const packs = [_]PackConstants{.{ .name = "transport", .src_dir = pack_dir }};
    try testing.expectEqual(true, try runPhase(testing.allocator, paths.game, paths.target, &packs, true));

    const generated = try tmp.dir.readFileAlloc(io, "target/" ++ GENERATED_FILENAME, testing.allocator, .limited(64 * 1024));
    defer testing.allocator.free(generated);
    try testing.expect(std.mem.indexOf(u8, generated, "pub const @\"transport__ship\" = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "pub const @\"speed\" = 280;") != null);
}
