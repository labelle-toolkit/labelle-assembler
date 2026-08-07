//! i18n, phase 1 (RFC-I18N in labelle-engine#811, tracking #809).
//!
//! Scans `locales/*.jsonc`, validates against the declared reference locale,
//! and emits `i18n.zig` into the target dir: a `Key` type, the `K` namespace
//! of comptime key constants, every locale baked into one rectangular table,
//! and `t` / `setLocale` / `activeLocale` / `locales`.
//!
//! The properties the RFC promises, held here:
//!
//!  - a misspelled key does not compile (`K.menu.new_gme` names a missing
//!    declaration at the call site)
//!  - the table is rectangular: a locale missing a key gets the reference
//!    locale's string in that slot, so no runtime path can fail and no
//!    fallback code exists
//!  - coverage diagnostics are usage-aware (§3.1): a key *used in code* and
//!    missing from a locale warns, naming the key and every locale missing
//!    it; an unused untranslated key is silent. `strict` promotes the warning
//!    to a build error. The used-set comes from usage_scan.zig -- the same
//!    conservative alias-widening scanner constants use, with root `K`.
//!
//! A project with no `locales/` emits nothing and keeps a byte-identical
//! build.zig; a stale generated file is deleted, mirroring constants_phase.
const std = @import("std");
const Allocator = std.mem.Allocator;
const locales_mod = @import("i18n_locales.zig");
const usage = @import("usage_scan.zig");

// Same local io as constants_phase, for the same reason: config.zig pulls in
// build_options and would make this file untestable standalone.
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

pub const GENERATED_FILENAME = "i18n.zig";

/// Mirror of config.I18nConfig, so this file does not import config.zig.
/// root.zig converts.
pub const Settings = struct {
    default: []const u8,
    reference: ?[]const u8 = null,
    strict: bool = false,
};

/// Runs the phase. Returns true when `i18n.zig` was emitted.
pub fn runPhase(
    allocator: Allocator,
    game_dir: []const u8,
    target_dir: []const u8,
    settings: ?Settings,
) !bool {
    const io = phaseIo();
    const cwd = std.Io.Dir.cwd();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src_path = try std.fs.path.join(arena, &.{ game_dir, "locales" });
    var src_dir = cwd.openDir(io, src_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            const stale = try std.fs.path.join(arena, &.{ target_dir, GENERATED_FILENAME });
            cwd.deleteFile(io, stale) catch {};
            return false;
        },
        else => return err,
    };
    defer src_dir.close(io);

    // Tags, from filenames, sorted for determinism.
    var tags: std.ArrayList([]const u8) = .empty;
    var iter = src_dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonc")) continue;
        try tags.append(arena, try arena.dupe(u8, entry.name[0 .. entry.name.len - ".jsonc".len]));
    }
    std.mem.sort([]const u8, tags.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    if (tags.items.len == 0) {
        const stale = try std.fs.path.join(arena, &.{ target_dir, GENERATED_FILENAME });
        cwd.deleteFile(io, stale) catch {};
        return false;
    }

    // §8: `.default` is mandatory whenever locales/ exists. No implicit "en" --
    // a shipping language is a product decision, not a filename guess.
    const cfg = settings orelse {
        std.debug.print("locales/ exists but project.labelle declares no .i18n block. Add: .i18n = .{{ .default = \"{s}\" }}\n", .{tags.items[0]});
        return error.I18nInvalid;
    };
    const default_idx = indexOfTag(tags.items, cfg.default) orelse {
        std.debug.print("i18n.default = \"{s}\" names no locale file. Scanned: {s}\n", .{ cfg.default, try joinTags(arena, tags.items) });
        return error.I18nInvalid;
    };
    const reference_tag = cfg.reference orelse cfg.default;
    const reference_idx = indexOfTag(tags.items, reference_tag) orelse {
        std.debug.print("i18n.reference = \"{s}\" names no locale file. Scanned: {s}\n", .{ reference_tag, try joinTags(arena, tags.items) });
        return error.I18nInvalid;
    };

    // Parse every locale.
    var parsed = try arena.alloc(locales_mod.Locale, tags.items.len);
    var had_error = false;
    for (tags.items, 0..) |tag, i| {
        const fname = try std.fmt.allocPrint(arena, "{s}.jsonc", .{tag});
        const source = src_dir.readFileAlloc(io, fname, arena, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
            error.StreamTooLong => {
                std.debug.print("locales/{s}: file exceeds 4 MiB\n", .{fname});
                had_error = true;
                parsed[i] = .{ .entries = &.{} };
                continue;
            },
            else => return err,
        };
        switch (try locales_mod.parse(arena, source)) {
            .fail => |e| {
                std.debug.print("locales/{s}: {s}\n", .{ fname, e.msg });
                had_error = true;
                parsed[i] = .{ .entries = &.{} };
            },
            .ok => |l| parsed[i] = l,
        }
    }
    if (had_error) return error.I18nInvalid;

    const reference = parsed[reference_idx];
    if (reference.entries.len == 0) {
        std.debug.print("locales/{s}.jsonc: the reference locale defines no keys\n", .{reference_tag});
        return error.I18nInvalid;
    }
    if (reference.entries.len > 65535) {
        std.debug.print("i18n: {d} keys exceeds the u16 key space\n", .{reference.entries.len});
        return error.I18nInvalid;
    }

    // §3 row 3: a key in L that the reference lacks is a build error -- it
    // catches renames that updated one file only.
    for (tags.items, 0..) |tag, i| {
        if (i == reference_idx) continue;
        for (parsed[i].entries) |e| {
            if (reference.get(e.key) == null) {
                std.debug.print("locales/{s}.jsonc: key '{s}' is absent from the reference locale ({s}) -- a rename that updated one file only?\n", .{ tag, e.key, reference_tag });
                had_error = true;
            }
        }
    }
    if (had_error) return error.I18nInvalid;

    // §3.1: usage-aware coverage. The used-set comes from the shared scanner
    // with root K; a used key missing from a locale warns (or errors under
    // strict), naming every locale missing it. Unused gaps stay silent --
    // they are the normal state mid-feature.
    var marks = usage.Marks.init(arena);
    try collectMarks(arena, &marks, game_dir);

    for (reference.entries) |re| {
        if (!marks.covers(re.key)) continue;
        var missing: std.ArrayList([]const u8) = .empty;
        for (tags.items, 0..) |tag, i| {
            if (i == reference_idx) continue;
            if (parsed[i].get(re.key) == null) try missing.append(arena, tag);
        }
        if (missing.items.len == 0) continue;
        const list = try std.mem.join(arena, ", ", missing.items);
        if (cfg.strict) {
            std.debug.print("error: i18n: K.{s} is used but missing from: {s} (strict)\n", .{ re.key, list });
            had_error = true;
        } else {
            std.debug.print("warning: i18n: K.{s} is used but missing from: {s} (backfilled with {s})\n", .{ re.key, list, reference_tag });
        }
    }
    if (had_error) return error.I18nInvalid;

    // Emit.
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try emitModule(w, tags.items, parsed, reference, reference_idx, default_idx);

    const dst = try std.fs.path.join(arena, &.{ target_dir, GENERATED_FILENAME });
    try cwd.writeFile(io, .{ .sub_path = dst, .data = out.writer.buffered() });
    return true;
}

fn indexOfTag(tags: []const []const u8, tag: []const u8) ?usize {
    for (tags, 0..) |t, i| {
        if (std.mem.eql(u8, t, tag)) return i;
    }
    return null;
}

fn joinTags(arena: Allocator, tags: []const []const u8) ![]const u8 {
    return std.mem.join(arena, ", ", tags);
}

// ---------------------------------------------------------------------------
// codegen
// ---------------------------------------------------------------------------

fn emitModule(
    w: *std.Io.Writer,
    tags: []const []const u8,
    parsed: []const locales_mod.Locale,
    reference: locales_mod.Locale,
    reference_idx: usize,
    default_idx: usize,
) !void {
    _ = reference_idx;
    try w.writeAll("//! Generated by labelle-assembler from locales/*.jsonc -- do not edit.\n");
    try w.writeAll("//! The table is rectangular: gaps are backfilled with the reference\n");
    try w.writeAll("//! locale's string at build time, so no runtime path can fail and no\n");
    try w.writeAll("//! fallback code exists (RFC-I18N section 3.1 / 5).\n\n");

    // Key type: non-exhaustive u16 enum; K's constants are the only names.
    try w.writeAll("pub const Key = enum(u16) { _ };\n\n");

    // K: nested namespaces of typed constants, indices in sorted-key order
    // (deterministic -- RFC Open Question 3).
    try w.writeAll("pub const K = struct {\n");
    try emitKeyTree(w, reference.entries, 1);
    try w.writeAll("};\n\n");

    // Locale tags, sorted; index is the runtime locale index.
    try w.writeAll("const tags = [_][:0]const u8{");
    for (tags, 0..) |t, i| {
        if (i != 0) try w.writeAll(", ");
        try w.writeAll("\"");
        try writeEscaped(w, t);
        try w.writeAll("\"");
    }
    try w.writeAll("};\n\n");

    // The rectangular table: [locale][key], reference string where a locale
    // has no translation.
    try w.print("const table = [{d}][{d}][:0]const u8{{\n", .{ tags.len, reference.entries.len });
    for (tags, 0..) |tag, li| {
        try w.print("    // {s}\n", .{tag});
        try w.writeAll("    .{\n");
        for (reference.entries) |re| {
            const s = parsed[li].get(re.key) orelse re.value;
            try w.writeAll("        \"");
            try writeEscaped(w, s);
            try w.writeAll("\",\n");
        }
        try w.writeAll("    },\n");
    }
    try w.writeAll("};\n\n");

    try w.print("var active: usize = {d}; // i18n.default\n\n", .{default_idx});

    try w.writeAll(
        \\/// The translated string for a key, in the active locale. Zero-cost:
        \\/// a table lookup with a comptime index, no allocation, no failure
        \\/// path. The sentinel means it hands directly to cimgui.
        \\pub fn t(comptime key: Key) [:0]const u8 {
        \\    return table[active][@intFromEnum(key)];
        \\}
        \\
        \\/// Switches the active locale. Returns false (and changes nothing)
        \\/// for a tag no locale file declared.
        \\pub fn setLocale(tag: []const u8) bool {
        \\    for (tags, 0..) |t_, i| {
        \\        if (std.mem.eql(u8, t_, tag)) {
        \\            active = i;
        \\            return true;
        \\        }
        \\    }
        \\    return false;
        \\}
        \\
        \\pub fn activeLocale() [:0]const u8 {
        \\    return tags[active];
        \\}
        \\
        \\/// Every locale this build carries, for the Options selector.
        \\pub fn locales() []const [:0]const u8 {
        \\    return &tags;
        \\}
        \\
        \\/// Startup hook for the LABELLE_LOCALE dev/CI override (RFC-I18N
        \\/// section 8): pass the env var's value, or null. An unknown tag is
        \\/// ignored -- it must not be able to break a player's run if it leaks
        \\/// into a shipped environment.
        \\pub fn initFromEnvValue(v: ?[]const u8) void {
        \\    if (v) |tag| _ = setLocale(tag);
        \\}
        \\
        \\const std = @import("std");
        \\
    );
}

/// Emits the nested K namespaces. Entries are sorted by dotted key, which
/// groups shared prefixes contiguously, so a single pass with a segment stack
/// suffices. Every declaration is @""-quoted so a key named like a Zig
/// keyword ("error", "test") still generates.
fn emitKeyTree(w: *std.Io.Writer, entries: []const locales_mod.Entry, base_depth: usize) !void {
    var stack: [16][]const u8 = undefined;
    var depth: usize = 0;

    for (entries, 0..) |e, idx| {
        // Split the key into segments.
        var segs: [16][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, e.key, '.');
        while (it.next()) |seg| {
            segs[n] = seg;
            n += 1;
        }

        // Find common prefix length with the open stack.
        var common: usize = 0;
        while (common < depth and common < n - 1 and std.mem.eql(u8, stack[common], segs[common])) common += 1;

        // Close namespaces below the common prefix.
        while (depth > common) {
            depth -= 1;
            try writeIndent(w, base_depth + depth);
            try w.writeAll("};\n");
        }
        // Open namespaces down to the leaf's parent.
        while (depth < n - 1) {
            try writeIndent(w, base_depth + depth);
            try w.print("pub const @\"{s}\" = struct {{\n", .{segs[depth]});
            stack[depth] = segs[depth];
            depth += 1;
        }
        // The leaf.
        try writeIndent(w, base_depth + depth);
        try w.print("pub const @\"{s}\": Key = @enumFromInt({d});\n", .{ segs[n - 1], idx });
    }
    while (depth > 0) {
        depth -= 1;
        try writeIndent(w, base_depth + depth);
        try w.writeAll("};\n");
    }
}

fn writeIndent(w: *std.Io.Writer, depth: usize) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try w.writeAll("    ");
}

fn writeEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '\\' => try w.writeAll("\\\\"),
        '"' => try w.writeAll("\\\""),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        '\r' => try w.writeAll("\\r"),
        else => try w.writeByte(c),
    };
}

/// Same walk constants_phase uses; kept separate so each phase stays
/// standalone-testable. Skips generated and vendored trees.
const skip_dirs = [_][]const u8{ ".labelle", ".git", "deps", "zig-out", "zig-cache", ".zig-cache" };

fn collectMarks(arena: Allocator, marks: *usage.Marks, dir_path: []const u8) !void {
    const io = phaseIo();
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
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
                const source = dir.readFileAlloc(io, entry.name, arena, .limited(4 * 1024 * 1024)) catch continue;
                try usage.scanSource(marks, .{ .module_name = "i18n", .root_symbol = "K" }, source);
            },
            else => {},
        }
    }
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn tmpPaths(tmp: *std.testing.TmpDir, alloc: Allocator) !struct { game: []const u8, target: []const u8 } {
    var rel_buf: [96]u8 = undefined;
    const rel = try std.fmt.bufPrint(&rel_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    return .{
        .game = try std.fs.path.join(alloc, &.{ rel, "game" }),
        .target = try std.fs.path.join(alloc, &.{ rel, "target" }),
    };
}

test "no locales dir: nothing emitted, stale file cleaned" {
    const io = phaseIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "game");
    try tmp.dir.createDirPath(io, "target");
    try tmp.dir.writeFile(io, .{ .sub_path = "target/" ++ GENERATED_FILENAME, .data = "// stale\n" });

    const p = try tmpPaths(&tmp, testing.allocator);
    defer testing.allocator.free(p.game);
    defer testing.allocator.free(p.target);

    try testing.expectEqual(false, try runPhase(testing.allocator, p.game, p.target, null));
    try testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "target/" ++ GENERATED_FILENAME, .{}));
}

test "locales without .i18n.default is an error" {
    const io = phaseIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "game/locales");
    try tmp.dir.createDirPath(io, "target");
    try tmp.dir.writeFile(io, .{ .sub_path = "game/locales/en.jsonc", .data = "{ \"menu\": { \"play\": \"Play\" } }" });

    const p = try tmpPaths(&tmp, testing.allocator);
    defer testing.allocator.free(p.game);
    defer testing.allocator.free(p.target);

    try testing.expectError(error.I18nInvalid, runPhase(testing.allocator, p.game, p.target, null));
}

test "default naming no file is an error; a key absent from the reference is an error" {
    const io = phaseIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "game/locales");
    try tmp.dir.createDirPath(io, "target");
    try tmp.dir.writeFile(io, .{ .sub_path = "game/locales/en.jsonc", .data = "{ \"menu\": { \"play\": \"Play\" } }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "game/locales/pt.jsonc", .data = "{ \"menu\": { \"play\": \"Jogar\", \"quit\": \"Sair\" } }" });

    const p = try tmpPaths(&tmp, testing.allocator);
    defer testing.allocator.free(p.game);
    defer testing.allocator.free(p.target);

    // BCP-47 typo shape: pt_BR for a file that does not exist.
    try testing.expectError(error.I18nInvalid, runPhase(testing.allocator, p.game, p.target, .{ .default = "pt_BR" }));
    // pt has menu.quit which en (the reference) lacks -- the rename catch.
    try testing.expectError(error.I18nInvalid, runPhase(testing.allocator, p.game, p.target, .{ .default = "en" }));
}

test "emission: K tree, rectangular backfilled table, default index" {
    const io = phaseIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "game/locales");
    try tmp.dir.createDirPath(io, "target");
    try tmp.dir.writeFile(io, .{ .sub_path = "game/locales/en.jsonc", .data = "{ \"menu\": { \"play\": \"Play\", \"quit\": \"Quit\" }, \"hud\": { \"stock\": \"Stock\" } }" });
    // pt is missing hud.stock -- it must be backfilled with en's string.
    try tmp.dir.writeFile(io, .{ .sub_path = "game/locales/pt-BR.jsonc", .data = "{ \"menu\": { \"play\": \"Jogar\", \"quit\": \"Sair\" } }" });

    const p = try tmpPaths(&tmp, testing.allocator);
    defer testing.allocator.free(p.game);
    defer testing.allocator.free(p.target);

    try testing.expectEqual(true, try runPhase(testing.allocator, p.game, p.target, .{ .default = "pt-BR", .reference = "en" }));

    const generated = try tmp.dir.readFileAlloc(io, "target/" ++ GENERATED_FILENAME, testing.allocator, .limited(256 * 1024));
    defer testing.allocator.free(generated);

    // Keys sorted: hud.stock=0, menu.play=1, menu.quit=2.
    try testing.expect(std.mem.indexOf(u8, generated, "pub const @\"stock\": Key = @enumFromInt(0);") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "pub const @\"play\": Key = @enumFromInt(1);") != null);
    // en sorts before pt-BR; default (pt-BR) is index 1.
    try testing.expect(std.mem.indexOf(u8, generated, "var active: usize = 1;") != null);
    // The pt-BR row backfills hud.stock with en's "Stock".
    const pt_row = std.mem.indexOf(u8, generated, "// pt-BR").?;
    try testing.expect(std.mem.indexOfPos(u8, generated, pt_row, "\"Stock\"") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "\"Jogar\"") != null);

    // Structurally valid Zig.
    const src_z = try testing.allocator.dupeZ(u8, generated);
    defer testing.allocator.free(src_z);
    var ast = try std.zig.Ast.parse(testing.allocator, src_z, .zig);
    defer ast.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), ast.errors.len);
}

test "strict: a used key missing from a locale fails the build" {
    const io = phaseIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "game/locales");
    try tmp.dir.createDirPath(io, "game/scripts");
    try tmp.dir.createDirPath(io, "target");
    try tmp.dir.writeFile(io, .{ .sub_path = "game/locales/en.jsonc", .data = "{ \"menu\": { \"play\": \"Play\" }, \"hud\": { \"gold\": \"Gold\" } }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "game/locales/pt.jsonc", .data = "{ \"menu\": { \"play\": \"Jogar\" } }" });
    // The game renders hud.gold, which pt lacks.
    try tmp.dir.writeFile(io, .{
        .sub_path = "game/scripts/ui.zig",
        .data = "const K = @import(\"i18n\").K;\npub fn f() void { _ = K.hud.gold; }\n",
    });

    const p = try tmpPaths(&tmp, testing.allocator);
    defer testing.allocator.free(p.game);
    defer testing.allocator.free(p.target);

    // Non-strict: warns, emits.
    try testing.expectEqual(true, try runPhase(testing.allocator, p.game, p.target, .{ .default = "en" }));
    // Strict: the same gap is a build error.
    try testing.expectError(error.I18nInvalid, runPhase(testing.allocator, p.game, p.target, .{ .default = "en", .strict = true }));
}
