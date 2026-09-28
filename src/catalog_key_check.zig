//! Generate-time check that every STATIC asset-catalog key a game names
//! is actually registered (labelle-assembler#738).
//!
//! A shader-texture binding resolves its texture by catalog key at
//! runtime (`.texture = .{ .catalog = "fog_mask" }`). Before this pass a
//! misspelled key generated and built clean and only failed on the
//! device, as `AssetNotRegistered`, naming the material rather than the
//! file that authored the bad key. Generate already knows the full
//! registered set — project `.resources` plus the merged, namespaced
//! `<pack>__<name>` pack entries — so a static typo is catchable here.
//!
//! Two sources of static keys are checked:
//!
//!   1. **Zig literals.** Every `.catalog = "<key>"` in the game's
//!      `scripts/` and `components/` trees. Only string LITERALS are
//!      checked; a key computed at runtime (`.catalog = w.mask`) is left
//!      to the runtime `AssetNotRegistered` path, which still guards it.
//!   2. **Component fields that hold a catalog key.** A component opts
//!      its string fields in with a declaration inside its struct:
//!
//!          pub const WaterShader = struct {
//!              pub const catalog_keys = .{ "mask", "reflection" };
//!              mask: []const u8 = "reservoir_mask",
//!              ...
//!          };
//!
//!      Every string value those fields take in `prefabs/` and `scenes/`
//!      (`.jsonc`, at any nesting depth, so prefab bodies, scene entity
//!      `components` objects and overrides are all covered) is checked,
//!      and so is each field's string-literal default in the component.
//!      The declaration is an ordinary public decl, so the engine and
//!      the Zig compiler ignore it.
//!
//! Every unregistered key is reported — file, line, the component/field
//! (or `.catalog` literal) that authored it, and the closest registered
//! key — before generate fails with `error.UnregisteredCatalogKey`.
const std = @import("std");
const config = @import("config.zig");
const asset_validator = @import("asset_validator.zig");

pub const Error = error{ UnregisteredCatalogKey, OutOfMemory };

/// Which authoring construct named the bad key.
pub const Site = union(enum) {
    /// A `.catalog = "<key>"` string literal in a Zig source.
    catalog_literal,
    /// A `<component>.<field>` value in a prefab/scene, where the
    /// component declares `field` in its `catalog_keys`.
    component_field: struct { component: []const u8, field: []const u8 },
};

pub const Finding = struct {
    /// Path relative to the game directory, forward slashes.
    file: []const u8,
    /// 1-based; 0 when the key's text could not be located.
    line: usize,
    site: Site,
    key: []const u8,
    suggestion: ?[]const u8,
};

/// A component that declares catalog-key fields.
pub const KeyDecl = struct {
    component: []const u8,
    fields: []const []const u8,
    /// String-literal defaults of those fields in the component source,
    /// which apply wherever a prefab/scene omits the field.
    defaults: []const Default = &.{},
};

pub const Default = struct { field: []const u8, key: []const u8, line: usize };

pub const Literal = struct { key: []const u8, line: usize };

const max_file_bytes = 16 * 1024 * 1024;

/// Run the check over `game_dir` and print every finding. Returns
/// `error.UnregisteredCatalogKey` when at least one key is unregistered.
pub fn validate(
    allocator: std.mem.Allocator,
    game_dir: []const u8,
    resources: []const config.ResourceDef,
) Error!void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const findings = try check(arena, game_dir, resources);
    if (findings.len == 0) return;
    for (findings) |f| printFinding(arena, f);
    return error.UnregisteredCatalogKey;
}

/// Collect every unregistered static key under `game_dir`. All returned
/// memory belongs to `arena`.
pub fn check(
    arena: std.mem.Allocator,
    game_dir: []const u8,
    resources: []const config.ResourceDef,
) error{OutOfMemory}![]Finding {
    var findings: std.ArrayList(Finding) = .empty;

    var zig_files: std.ArrayList(SourceFile) = .empty;
    try collect(arena, game_dir, "components", ".zig", &zig_files);
    const component_file_count = zig_files.items.len;
    try collect(arena, game_dir, "scripts", ".zig", &zig_files);

    // Component declarations come from `components/` only.
    var decls: std.ArrayList(KeyDecl) = .empty;
    for (zig_files.items[0..component_file_count]) |f| {
        const file_decls = try parseKeyDecls(arena, f.source);
        try decls.appendSlice(arena, file_decls);
        for (file_decls) |decl| for (decl.defaults) |d| {
            if (isRegistered(d.key, resources)) continue;
            try findings.append(arena, .{
                .file = f.rel,
                .line = d.line,
                .site = .{ .component_field = .{ .component = decl.component, .field = d.field } },
                .key = d.key,
                .suggestion = try suggest(arena, d.key, resources),
            });
        };
    }

    for (zig_files.items) |f| {
        for (try scanCatalogLiterals(arena, f.source)) |lit| {
            if (isRegistered(lit.key, resources)) continue;
            try findings.append(arena, .{
                .file = f.rel,
                .line = lit.line,
                .site = .catalog_literal,
                .key = lit.key,
                .suggestion = try suggest(arena, lit.key, resources),
            });
        }
    }

    if (decls.items.len > 0) {
        var json_files: std.ArrayList(SourceFile) = .empty;
        try collect(arena, game_dir, "prefabs", ".jsonc", &json_files);
        try collect(arena, game_dir, "scenes", ".jsonc", &json_files);
        for (json_files.items) |f| {
            try checkJsonSource(arena, f.rel, f.source, decls.items, resources, &findings);
        }
    }
    return findings.items;
}

/// Check one prefab/scene source against the component declarations.
/// Unparseable JSON is skipped: the scene/prefab parsers own that error.
pub fn checkJsonSource(
    arena: std.mem.Allocator,
    rel: []const u8,
    source: []const u8,
    decls: []const KeyDecl,
    resources: []const config.ResourceDef,
    findings: *std.ArrayList(Finding),
) error{OutOfMemory}!void {
    const stripped = try stripJsonc(arena, source);
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, stripped, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    try walkJson(arena, rel, source, parsed, decls, resources, findings);
}

fn walkJson(
    arena: std.mem.Allocator,
    rel: []const u8,
    source: []const u8,
    value: std.json.Value,
    decls: []const KeyDecl,
    resources: []const config.ResourceDef,
    findings: *std.ArrayList(Finding),
) error{OutOfMemory}!void {
    switch (value) {
        .array => |arr| for (arr.items) |item| {
            try walkJson(arena, rel, source, item, decls, resources, findings);
        },
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                const body = entry.value_ptr.*;
                if (body == .object) {
                    if (findDecl(decls, entry.key_ptr.*)) |decl| {
                        for (decl.fields) |field| {
                            const v = body.object.get(field) orelse continue;
                            if (v != .string) continue;
                            if (isRegistered(v.string, resources)) continue;
                            try findings.append(arena, .{
                                .file = rel,
                                .line = lineOfQuoted(source, v.string),
                                .site = .{ .component_field = .{ .component = decl.component, .field = field } },
                                .key = v.string,
                                .suggestion = try suggest(arena, v.string, resources),
                            });
                        }
                    }
                }
                try walkJson(arena, rel, source, body, decls, resources, findings);
            }
        },
        else => {},
    }
}

fn findDecl(decls: []const KeyDecl, component: []const u8) ?KeyDecl {
    for (decls) |d| if (std.mem.eql(u8, d.component, component)) return d;
    return null;
}

pub fn isRegistered(key: []const u8, resources: []const config.ResourceDef) bool {
    for (resources) |r| if (std.mem.eql(u8, r.name, key)) return true;
    return false;
}

/// Closest registered key: the edit-distance match `validateSceneAssets`
/// uses, else the longest registered key that is a prefix of `key` or
/// that `key` is a prefix of (catches `reservoir_mask_MISSING`, whose
/// edit distance is too large for a Levenshtein hint).
pub fn suggest(
    arena: std.mem.Allocator,
    key: []const u8,
    resources: []const config.ResourceDef,
) error{OutOfMemory}!?[]const u8 {
    if (try asset_validator.closestResource(arena, key, resources, asset_validator.SUGGESTION_THRESHOLD)) |s| return s;
    var best: ?[]const u8 = null;
    for (resources) |r| {
        if (r.name.len < 3 or key.len < 3) continue;
        if (!std.mem.startsWith(u8, key, r.name) and !std.mem.startsWith(u8, r.name, key)) continue;
        if (best == null or r.name.len > best.?.len) best = r.name;
    }
    return best;
}

// ── Zig source scanning ────────────────────────────────────────────────

/// Every `.catalog = "<key>"` string literal in `src`, with its 1-based
/// line. Line comments and multiline-string lines are ignored; a literal
/// containing an escape is skipped (not a plain catalog key).
pub fn scanCatalogLiterals(arena: std.mem.Allocator, src: []const u8) error{OutOfMemory}![]Literal {
    var out: std.ArrayList(Literal) = .empty;
    var lines = std.mem.splitScalar(u8, src, '\n');
    var line_no: usize = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        const line = codePart(raw);
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, line, i, ".catalog")) |at| {
            i = at + ".catalog".len;
            if (at > 0 and isIdentChar(line[at - 1])) continue;
            var j = i;
            if (j < line.len and isIdentChar(line[j])) continue;
            j = skipSpaces(line, j);
            if (j >= line.len or line[j] != '=') continue;
            j += 1;
            if (j < line.len and line[j] == '=') continue; // `==`
            j = skipSpaces(line, j);
            if (j >= line.len or line[j] != '"') continue;
            const start = j + 1;
            const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse continue;
            const key = line[start..end];
            i = end + 1;
            if (std.mem.indexOfScalar(u8, key, '\\') != null) continue;
            try out.append(arena, .{ .key = key, .line = line_no });
        }
    }
    return out.items;
}

/// Every `pub const catalog_keys = .{ "a", "b" };` in `src`, attributed
/// to the nearest preceding `pub const <Name> = [extern|packed] struct`.
/// A declaration with no enclosing struct header is ignored.
pub fn parseKeyDecls(arena: std.mem.Allocator, src: []const u8) error{OutOfMemory}![]KeyDecl {
    const code = try stripZigComments(arena, src);
    var out: std.ArrayList(KeyDecl) = .empty;
    const marker = "pub const catalog_keys";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, code, i, marker)) |at| {
        i = at + marker.len;
        if (i < code.len and isIdentChar(code[i])) continue;
        const open = std.mem.indexOfPos(u8, code, i, ".{") orelse break;
        const close = std.mem.indexOfScalarPos(u8, code, open, '}') orelse break;
        i = close + 1;
        const header = enclosingStruct(code[0..at]) orelse continue;
        var fields: std.ArrayList([]const u8) = .empty;
        var defaults: std.ArrayList(Default) = .empty;
        var body = code[open + 2 .. close];
        while (std.mem.indexOfScalar(u8, body, '"')) |q| {
            const end = std.mem.indexOfScalarPos(u8, body, q + 1, '"') orelse break;
            const field = body[q + 1 .. end];
            try fields.append(arena, field);
            if (fieldDefault(code, header.pos, field)) |d| try defaults.append(arena, d);
            body = body[end + 1 ..];
        }
        try out.append(arena, .{ .component = header.name, .fields = fields.items, .defaults = defaults.items });
    }
    return out.items;
}

/// The string-literal default of `field` (`<field>: []const u8 = "<key>",`),
/// searched line by line from the struct header at `from`. Null when the
/// field has no literal default.
fn fieldDefault(code: []const u8, from: usize, field: []const u8) ?Default {
    var line_no: usize = std.mem.count(u8, code[0..from], "\n") + 1;
    var lines = std.mem.splitScalar(u8, code[from..], '\n');
    while (lines.next()) |raw| : (line_no += 1) {
        const line = std.mem.trimStart(u8, raw, " \t");
        if (!std.mem.startsWith(u8, line, field)) continue;
        var j = skipSpaces(line, field.len);
        if (j >= line.len or line[j] != ':') continue;
        const eq = std.mem.indexOfScalarPos(u8, line, j, '=') orelse return null;
        j = skipSpaces(line, eq + 1);
        if (j >= line.len or line[j] != '"') return null;
        const end = std.mem.indexOfScalarPos(u8, line, j + 1, '"') orelse return null;
        const key = line[j + 1 .. end];
        if (std.mem.indexOfScalar(u8, key, '\\') != null) return null;
        return .{ .field = field, .key = key, .line = line_no };
    }
    return null;
}

const StructHeader = struct { name: []const u8, pos: usize };

/// The last `pub const <Name> = [extern |packed ]struct` in `prefix`.
fn enclosingStruct(prefix: []const u8) ?StructHeader {
    var result: ?StructHeader = null;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, prefix, i, "pub const ")) |at| {
        i = at + "pub const ".len;
        var j = i;
        while (j < prefix.len and isIdentChar(prefix[j])) j += 1;
        if (j == i) continue;
        const name = prefix[i..j];
        j = skipSpaces(prefix, j);
        if (j >= prefix.len or prefix[j] != '=') continue;
        var rest = std.mem.trimStart(u8, prefix[j + 1 ..], " \t\r\n");
        for ([_][]const u8{ "extern ", "packed " }) |q| {
            if (std.mem.startsWith(u8, rest, q)) rest = std.mem.trimStart(u8, rest[q.len..], " \t\r\n");
        }
        if (std.mem.startsWith(u8, rest, "struct") and
            (rest.len == "struct".len or !isIdentChar(rest["struct".len])))
        {
            result = .{ .name = name, .pos = at };
        }
    }
    return result;
}

/// `raw` minus any `//` comment outside a string literal; empty for a
/// `\\` multiline-string line.
fn codePart(raw: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, raw, " \t");
    if (std.mem.startsWith(u8, trimmed, "\\\\")) return "";
    var in_str = false;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (in_str) {
            if (c == '\\') {
                i += 1;
            } else if (c == '"') in_str = false;
        } else if (c == '"') {
            in_str = true;
        } else if (c == '\'') {
            // Char literal (`'"'`, `'\''`): skip it so its quote can't
            // open a phantom string.
            i += 1;
            if (i < raw.len and raw[i] == '\\') i += 1;
            while (i + 1 < raw.len and raw[i + 1] != '\'') i += 1;
            i += 1;
        } else if (c == '/' and i + 1 < raw.len and raw[i + 1] == '/') {
            return raw[0..i];
        }
    }
    return raw;
}

fn stripZigComments(arena: std.mem.Allocator, src: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        try out.appendSlice(arena, codePart(raw));
        try out.append(arena, '\n');
    }
    return out.items;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn skipSpaces(s: []const u8, from: usize) usize {
    var j = from;
    while (j < s.len and (s[j] == ' ' or s[j] == '\t')) j += 1;
    return j;
}

// ── JSONC helpers ──────────────────────────────────────────────────────

/// Blank `//` and `/* */` comments outside strings, preserving length and
/// newlines, so `std.json` can parse a `.jsonc` file.
fn stripJsonc(arena: std.mem.Allocator, source: []const u8) error{OutOfMemory}![]u8 {
    const out = try arena.dupe(u8, source);
    var i: usize = 0;
    var in_str = false;
    while (i < out.len) : (i += 1) {
        const c = out[i];
        if (in_str) {
            if (c == '\\') {
                i += 1;
            } else if (c == '"') in_str = false;
            continue;
        }
        if (c == '"') {
            in_str = true;
        } else if (c == '/' and i + 1 < out.len and out[i + 1] == '/') {
            while (i < out.len and out[i] != '\n') : (i += 1) out[i] = ' ';
        } else if (c == '/' and i + 1 < out.len and out[i + 1] == '*') {
            while (i < out.len and !(out[i] == '*' and i + 1 < out.len and out[i + 1] == '/')) : (i += 1) {
                if (out[i] != '\n') out[i] = ' ';
            }
            if (i + 1 < out.len) {
                out[i] = ' ';
                out[i + 1] = ' ';
                i += 1;
            }
        }
    }
    return out;
}

/// 1-based line of the first `"<key>"` in `source`; 0 if absent.
fn lineOfQuoted(source: []const u8, key: []const u8) usize {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, source, i, key)) |at| {
        i = at + 1;
        if (at == 0 or source[at - 1] != '"') continue;
        const end = at + key.len;
        if (end >= source.len or source[end] != '"') continue;
        return std.mem.count(u8, source[0..at], "\n") + 1;
    }
    return 0;
}

// ── File collection & output ───────────────────────────────────────────

const SourceFile = struct { rel: []const u8, source: []const u8 };

/// Read every `*<ext>` file under `<game_dir>/<sub>` (recursively), in a
/// stable sorted order. A missing directory contributes nothing.
fn collect(
    arena: std.mem.Allocator,
    game_dir: []const u8,
    sub: []const u8,
    ext: []const u8,
    out: *std.ArrayList(SourceFile),
) error{OutOfMemory}!void {
    const abs = try std.fs.path.join(arena, &.{ game_dir, sub });
    const start = out.items.len;
    try collectDir(arena, abs, sub, ext, out);
    std.mem.sort(SourceFile, out.items[start..], {}, struct {
        fn lt(_: void, a: SourceFile, b: SourceFile) bool {
            return std.mem.lessThan(u8, a.rel, b.rel);
        }
    }.lt);
}

fn collectDir(
    arena: std.mem.Allocator,
    abs: []const u8,
    rel: []const u8,
    ext: []const u8,
    out: *std.ArrayList(SourceFile),
) error{OutOfMemory}!void {
    const io = config.globalIo();
    var dir = std.Io.Dir.cwd().openDir(io, abs, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch return) |entry| {
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        const child_abs = try std.fs.path.join(arena, &.{ abs, entry.name });
        const child_rel = try std.fmt.allocPrint(arena, "{s}/{s}", .{ rel, entry.name });
        switch (entry.kind) {
            .directory => try collectDir(arena, child_abs, child_rel, ext, out),
            .file, .sym_link => {
                if (!std.mem.endsWith(u8, entry.name, ext)) continue;
                const source = std.Io.Dir.cwd().readFileAlloc(io, child_abs, arena, .limited(max_file_bytes)) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => continue,
                };
                try out.append(arena, .{ .rel = child_rel, .source = source });
            },
            else => {},
        }
    }
}

fn printFinding(arena: std.mem.Allocator, f: Finding) void {
    const what = switch (f.site) {
        .catalog_literal => std.fmt.allocPrint(arena, "`.catalog = \"{s}\"`", .{f.key}),
        .component_field => |c| std.fmt.allocPrint(arena, "{s}.{s} = \"{s}\"", .{ c.component, c.field, f.key }),
    } catch return;
    const hint = if (f.suggestion) |s|
        std.fmt.allocPrint(arena, "  Did you mean '{s}'?\n", .{s}) catch return
    else
        "  No close match among registered keys.\n";
    const msg = std.fmt.allocPrint(
        arena,
        "labelle-assembler: {s}:{d}: {s} names catalog key '{s}', which is not registered.\n{s}" ++
            "  Registered keys are project.labelle's `.resources` names (plus pack resources, namespaced `<pack>__<name>`).\n",
        .{ f.file, f.line, what, f.key, hint },
    ) catch return;
    std.Io.File.stderr().writeStreamingAll(config.globalIo(), msg) catch {};
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const test_resources = [_]config.ResourceDef{
    .{ .name = "fog_mask" },
    .{ .name = "reservoir_mask" },
    .{ .name = "reservoir_reflection" },
    .{ .name = "sky__clouds" },
};

test "scanCatalogLiterals: finds literals with their lines, skips comments and runtime keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\const a = .{ .name = "s", .texture = .{ .catalog = "fog_mask" } };
        \\// .texture = .{ .catalog = "commented_out" },
        \\const b = .{ .catalog = w.mask };
        \\const c = .{ .catalog="fog_maks" }; // .catalog = "trailing_comment"
        \\if (x.catalog == "cmp") {}
        \\const d = .{ .catalogue = "other_field" };
        \\const q = '"'; const e = .{ .catalog = "reservoir_mask" };
        \\    \\ .catalog = "inside_multiline_string"
    ;
    const lits = try scanCatalogLiterals(arena.allocator(), src);
    try testing.expectEqual(@as(usize, 3), lits.len);
    try testing.expectEqualStrings("fog_mask", lits[0].key);
    try testing.expectEqual(@as(usize, 1), lits[0].line);
    try testing.expectEqualStrings("fog_maks", lits[1].key);
    try testing.expectEqual(@as(usize, 4), lits[1].line);
    try testing.expectEqualStrings("reservoir_mask", lits[2].key);
    try testing.expectEqual(@as(usize, 7), lits[2].line);
}

test "parseKeyDecls: attributes catalog_keys to the enclosing component struct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\const std = @import("std");
        \\pub const WaterShader = struct {
        \\    // pub const catalog_keys = .{ "commented" };
        \\    pub const catalog_keys = .{ "mask", "reflection" };
        \\    mask: []const u8 = "reservoir_mask",
        \\};
        \\pub const Plain = struct { x: f32 = 0 };
    ;
    const decls = try parseKeyDecls(arena.allocator(), src);
    try testing.expectEqual(@as(usize, 1), decls.len);
    try testing.expectEqualStrings("WaterShader", decls[0].component);
    try testing.expectEqual(@as(usize, 2), decls[0].fields.len);
    try testing.expectEqualStrings("mask", decls[0].fields[0]);
    try testing.expectEqualStrings("reflection", decls[0].fields[1]);
    // Only `mask` has a literal default.
    try testing.expectEqual(@as(usize, 1), decls[0].defaults.len);
    try testing.expectEqualStrings("mask", decls[0].defaults[0].field);
    try testing.expectEqualStrings("reservoir_mask", decls[0].defaults[0].key);
    try testing.expectEqual(@as(usize, 5), decls[0].defaults[0].line);
}

test "suggest: edit distance first, prefix fallback for long suffixes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("fog_mask", (try suggest(a, "fog_maks", &test_resources)).?);
    try testing.expectEqualStrings("reservoir_mask", (try suggest(a, "reservoir_mask_MISSING", &test_resources)).?);
    try testing.expect((try suggest(a, "zzzzzzzzzz", &test_resources)) == null);
}

test "checkJsonSource: typo'd prefab binding is reported with component, field, line and hint" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decls = [_]KeyDecl{.{ .component = "WaterShader", .fields = &.{ "mask", "reflection" } }};
    const src =
        \\// reservoir
        \\{
        \\  "Position": { "x": 1 },
        \\  "WaterShader": {
        \\    "mask": "reservoir_mask_MISSING",
        \\    "reflection": "reservoir_reflection",
        \\    "water_level": 0.5
        \\  }
        \\}
    ;
    var findings: std.ArrayList(Finding) = .empty;
    try checkJsonSource(a, "prefabs/reservoir.jsonc", src, &decls, &test_resources, &findings);
    try testing.expectEqual(@as(usize, 1), findings.items.len);
    const f = findings.items[0];
    try testing.expectEqualStrings("prefabs/reservoir.jsonc", f.file);
    try testing.expectEqual(@as(usize, 5), f.line);
    try testing.expectEqualStrings("reservoir_mask_MISSING", f.key);
    try testing.expectEqualStrings("WaterShader", f.site.component_field.component);
    try testing.expectEqualStrings("mask", f.site.component_field.field);
    try testing.expectEqualStrings("reservoir_mask", f.suggestion.?);
}

test "checkJsonSource: nested scene components with valid keys pass" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decls = [_]KeyDecl{.{ .component = "WaterShader", .fields = &.{"mask"} }};
    const src =
        \\{ "entities": [ { "prefab": "reservoir", "components": { "WaterShader": { "mask": "sky__clouds" } } } ] }
    ;
    var findings: std.ArrayList(Finding) = .empty;
    try checkJsonSource(a, "scenes/main.jsonc", src, &decls, &test_resources, &findings);
    try testing.expectEqual(@as(usize, 0), findings.items.len);
}

fn writeTree(dir: std.Io.Dir, files: []const [2][]const u8) !void {
    const io = config.globalIo();
    for (files) |f| {
        if (std.fs.path.dirname(f[0])) |parent| try dir.createDirPath(io, parent);
        try dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
    }
}

const fixture_component =
    \\pub const WaterShader = struct {
    \\    pub const catalog_keys = .{ "mask" };
    \\    mask: []const u8 = "reservoir_mask",
    \\};
;

test "check: a game with only registered keys produces no findings" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTree(tmp.dir, &.{
        .{ "components/water_shader.zig", fixture_component },
        .{ "scripts/playing/fx.zig", "const t = .{ .catalog = \"fog_mask\" };\n" },
        .{ "prefabs/reservoir.jsonc", "{ \"WaterShader\": { \"mask\": \"reservoir_mask\" } }\n" },
    });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const game_dir = try tmp.dir.realPathFileAlloc(config.globalIo(), ".", arena.allocator());
    const findings = try check(arena.allocator(), game_dir, &test_resources);
    try testing.expectEqual(@as(usize, 0), findings.len);
    try validate(testing.allocator, game_dir, &test_resources);
}

test "check: typo'd keys in a script literal and a prefab field are both reported" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTree(tmp.dir, &.{
        .{ "components/water_shader.zig", fixture_component },
        .{ "scripts/playing/fx.zig", "const ok = 1;\nconst t = .{ .catalog = \"fog_mask_MISSING\" };\n" },
        .{ "prefabs/reservoir.jsonc", "{ \"WaterShader\": { \"mask\": \"reservoir_mask_MISSING\" } }\n" },
    });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const game_dir = try tmp.dir.realPathFileAlloc(config.globalIo(), ".", arena.allocator());
    const findings = try check(arena.allocator(), game_dir, &test_resources);
    try testing.expectEqual(@as(usize, 2), findings.len);

    try testing.expectEqualStrings("scripts/playing/fx.zig", findings[0].file);
    try testing.expectEqual(@as(usize, 2), findings[0].line);
    try testing.expect(findings[0].site == .catalog_literal);
    try testing.expectEqualStrings("fog_mask_MISSING", findings[0].key);
    try testing.expectEqualStrings("fog_mask", findings[0].suggestion.?);

    try testing.expectEqualStrings("prefabs/reservoir.jsonc", findings[1].file);
    try testing.expect(findings[1].site == .component_field);
    try testing.expectEqualStrings("reservoir_mask_MISSING", findings[1].key);

    try testing.expectError(error.UnregisteredCatalogKey, validate(testing.allocator, game_dir, &test_resources));
}

test "check: a typo'd component default is reported against the component file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTree(tmp.dir, &.{
        .{
            "components/water_shader.zig",
            \\pub const WaterShader = struct {
            \\    pub const catalog_keys = .{ "mask" };
            \\    mask: []const u8 = "reservoir_mask_MISSING",
            \\};
        },
        // The prefab omits `mask`, so the default is what ships.
        .{ "prefabs/reservoir.jsonc", "{ \"WaterShader\": {} }\n" },
    });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const game_dir = try tmp.dir.realPathFileAlloc(config.globalIo(), ".", arena.allocator());
    const findings = try check(arena.allocator(), game_dir, &test_resources);
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expectEqualStrings("components/water_shader.zig", findings[0].file);
    try testing.expectEqual(@as(usize, 3), findings[0].line);
    try testing.expectEqualStrings("mask", findings[0].site.component_field.field);
    try testing.expectEqualStrings("reservoir_mask_MISSING", findings[0].key);
}
