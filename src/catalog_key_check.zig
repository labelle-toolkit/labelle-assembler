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
//! Two sources of static keys are checked, both over the game's own
//! `components/` and `scripts/` (packs: #803):
//!
//!   1. **Zig literals.** Every `.catalog = "<key>"` string literal,
//!      found with the Zig tokenizer (so comments, line breaks and
//!      multiline strings need no special casing). A key computed at
//!      runtime (`.catalog = w.mask`) is left to the runtime
//!      `AssetNotRegistered` path, which still guards it. A key the game
//!      registers itself — the leading string literal of any
//!      `register...("<key>", ...)` call — counts as registered.
//!   2. **Component fields that hold a catalog key.** A component opts
//!      its string fields in with a declaration in its struct:
//!
//!          pub const WaterShader = struct {
//!              pub const catalog_keys = .{ "mask", "reflection" };
//!              mask: []const u8 = "reservoir_mask",
//!              ...
//!          };
//!
//!      Read with the Zig parser from each root-level component struct.
//!      Every string value those fields take in `prefabs/` and `scenes/`
//!      is checked (component sites located by the scene walker
//!      `scene_name_lint.collectComponentRefs`, so opaque payload that
//!      happens to reuse a component name is not), and so is each
//!      field's string-literal default in the component.
//!
//! Every unregistered key is reported — file, line, the component/field
//! (or `.catalog` literal) that authored it, and the closest registered
//! key — before generate fails with `error.UnregisteredCatalogKey`.
const std = @import("std");
const config = @import("config.zig");
const asset_validator = @import("asset_validator.zig");
const scanner = @import("scanner.zig");
const scene_name_lint = @import("scene_name_lint.zig");
const i18n_locales = @import("i18n_locales.zig");

pub const Error = error{ UnregisteredCatalogKey, OutOfMemory };

/// Which authoring construct named the bad key.
pub const Site = union(enum) {
    /// A `.catalog = "<key>"` string literal in a Zig source.
    catalog_literal,
    /// A `<component>.<field>` value in a prefab/scene or the field's
    /// default in the component, where the component lists `field` in
    /// its `catalog_keys`.
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

/// Static keys read from one Zig source.
pub const ZigKeys = struct {
    /// `.catalog = "<key>"` literals.
    catalog: []const Literal,
    /// Leading string argument of `register...(` calls.
    registered: []const []const u8,
};

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
    declared: []const config.ResourceDef,
) error{OutOfMemory}![]Finding {
    var findings: std.ArrayList(Finding) = .empty;

    var zig_files: std.ArrayList(SourceFile) = .empty;
    try collect(arena, game_dir, "components", ".zig", &zig_files);
    const component_file_count = zig_files.items.len;
    try collect(arena, game_dir, "scripts", ".zig", &zig_files);

    // Registered = declared resources + keys the game's own code registers.
    var registered: std.ArrayList(config.ResourceDef) = .empty;
    try registered.appendSlice(arena, declared);
    const zig_keys = try arena.alloc(ZigKeys, zig_files.items.len);
    for (zig_files.items, zig_keys) |f, *k| {
        k.* = try scanZigKeys(arena, f.source);
        for (k.registered) |key| try registered.append(arena, .{ .name = key });
    }
    const resources = registered.items;

    for (zig_files.items, zig_keys) |f, k| {
        for (k.catalog) |lit| {
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
/// Each component site the scene walker reports is parsed on its own; a
/// site that is not a parseable object is skipped (the scene/prefab
/// parsers own that error).
pub fn checkJsonSource(
    arena: std.mem.Allocator,
    rel: []const u8,
    source: []const u8,
    decls: []const KeyDecl,
    resources: []const config.ResourceDef,
    findings: *std.ArrayList(Finding),
) error{OutOfMemory}!void {
    const refs = scene_name_lint.collectComponentRefs(arena, source) catch return error.OutOfMemory;
    for (refs) |ref| {
        const decl = findDecl(decls, ref.name) orelse continue;
        const span = componentObject(source, ref.offset + ref.name.len) orelse continue;
        const body = source[span[0]..span[1]];
        const stripped = try i18n_locales.stripJsonc(arena, body);
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, stripped.text, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        if (parsed != .object) continue;
        for (decl.fields) |field| {
            const v = parsed.object.get(field) orelse continue;
            if (v != .string) continue;
            if (isRegistered(v.string, resources)) continue;
            const at = quotedOffset(body, v.string);
            try findings.append(arena, .{
                .file = rel,
                .line = if (at) |o| scene_name_lint.locOf(source, span[0] + o).line else 0,
                .site = .{ .component_field = .{ .component = decl.component, .field = field } },
                .key = v.string,
                .suggestion = try suggest(arena, v.string, resources),
            });
        }
    }
}

/// `[start, end)` of the `{ ... }` object that is the value of the key
/// whose content ends at `name_end` (the key's closing quote), or null
/// when the value is not an object. String- and comment-aware.
fn componentObject(src: []const u8, name_end: usize) ?[2]usize {
    var i = skipJsonTrivia(src, name_end + 1);
    if (i >= src.len or src[i] != ':') return null;
    i = skipJsonTrivia(src, i + 1);
    if (i >= src.len or src[i] != '{') return null;
    const start = i;
    var depth: usize = 0;
    while (i < src.len) : (i += 1) {
        switch (src[i]) {
            '"' => {
                i += 1;
                while (i < src.len and src[i] != '"') : (i += 1) {
                    if (src[i] == '\\') i += 1;
                }
            },
            '/' => if (i + 1 < src.len and (src[i + 1] == '/' or src[i + 1] == '*')) {
                i = skipJsonTrivia(src, i) - 1;
            },
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return .{ start, i + 1 };
            },
            else => {},
        }
    }
    return null;
}

/// Index of the first non-whitespace, non-comment byte at or after `from`.
fn skipJsonTrivia(src: []const u8, from: usize) usize {
    var i = from;
    while (i < src.len) {
        if (std.ascii.isWhitespace(src[i])) {
            i += 1;
        } else if (std.mem.startsWith(u8, src[i..], "//")) {
            i = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
        } else if (std.mem.startsWith(u8, src[i..], "/*")) {
            i = if (std.mem.indexOfPos(u8, src, i + 2, "*/")) |p| p + 2 else src.len;
        } else break;
    }
    return i;
}

/// Offset of the first `"<key>"` in `src`, or null.
fn quotedOffset(src: []const u8, key: []const u8) ?usize {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, src, i, key)) |at| {
        i = at + 1;
        if (at == 0 or src[at - 1] != '"') continue;
        const end = at + key.len;
        if (end >= src.len or src[end] != '"') continue;
        return at;
    }
    return null;
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

// ── Zig sources ────────────────────────────────────────────────────────

/// Token-level scan of one Zig source for `.catalog = "<key>"` literals
/// and `register...("<key>"` calls. Comments, whitespace and line breaks
/// are the tokenizer's business; a literal with an escape is skipped
/// (not a plain catalog key).
pub fn scanZigKeys(arena: std.mem.Allocator, src: []const u8) error{OutOfMemory}!ZigKeys {
    const src_z = try arena.dupeZ(u8, src);
    var catalog: std.ArrayList(Literal) = .empty;
    var registered: std.ArrayList([]const u8) = .empty;

    // A 4-token window: the three before `cur`.
    var w: [3]std.zig.Token = undefined;
    var seen: usize = 0;
    var tok = std.zig.Tokenizer.init(src_z);
    while (true) {
        const cur = tok.next();
        if (cur.tag == .eof) break;
        if (cur.tag == .string_literal and seen >= 3) {
            const key = plainString(src, cur);
            // `.catalog = "<key>"`
            if (key != null and w[0].tag == .period and w[1].tag == .identifier and
                std.mem.eql(u8, src[w[1].loc.start..w[1].loc.end], "catalog") and w[2].tag == .equal)
            {
                try catalog.append(arena, .{ .key = key.?, .line = lineAt(src, cur.loc.start) });
            }
            // `register...("<key>"`
            if (key != null and w[1].tag == .identifier and
                std.mem.startsWith(u8, src[w[1].loc.start..w[1].loc.end], "register") and w[2].tag == .l_paren)
            {
                try registered.append(arena, key.?);
            }
        }
        w[0] = w[1];
        w[1] = w[2];
        w[2] = cur;
        seen += 1;
    }
    return .{ .catalog = catalog.items, .registered = registered.items };
}

/// Every root-level `const Name = struct { ... }` in `src` that declares
/// `pub const catalog_keys = .{ "a", "b" };` as a DIRECT member, with the
/// string-literal defaults of those fields. A source that does not parse
/// yields nothing (the Zig build reports it).
pub fn parseKeyDecls(arena: std.mem.Allocator, src: []const u8) error{OutOfMemory}![]KeyDecl {
    const src_z = try arena.dupeZ(u8, src);
    var ast = try std.zig.Ast.parse(arena, src_z, .zig);
    if (ast.errors.len > 0) return &.{};

    var out: std.ArrayList(KeyDecl) = .empty;
    for (ast.rootDecls()) |decl| {
        const vd = ast.fullVarDecl(decl) orelse continue;
        const name = ast.tokenSlice(vd.ast.mut_token + 1);
        const init_node = vd.ast.init_node.unwrap() orelse continue;
        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const container = ast.fullContainerDecl(&buf, init_node) orelse continue;
        if (ast.tokenTag(container.ast.main_token) != .keyword_struct) continue;

        var keys: ?[]const []const u8 = null;
        var lits: std.ArrayList(Default) = .empty;
        for (container.ast.members) |m| {
            if (ast.fullVarDecl(m)) |mvd| {
                if (!std.mem.eql(u8, ast.tokenSlice(mvd.ast.mut_token + 1), "catalog_keys")) continue;
                const list = mvd.ast.init_node.unwrap() orelse continue;
                keys = try stringElements(arena, &ast, list);
            } else if (ast.fullContainerField(m)) |field| {
                if (field.ast.tuple_like) continue;
                const value = field.ast.value_expr.unwrap() orelse continue;
                if (ast.nodeTag(value) != .string_literal) continue;
                const tok_i = ast.nodeMainToken(value);
                const key = plainTokenString(ast.tokenSlice(tok_i)) orelse continue;
                try lits.append(arena, .{
                    .field = ast.tokenSlice(field.ast.main_token),
                    .key = key,
                    .line = lineAt(src, ast.tokenStart(tok_i)),
                });
            }
        }
        const fields = keys orelse continue;
        var defaults: std.ArrayList(Default) = .empty;
        for (fields) |f| for (lits.items) |d| {
            if (std.mem.eql(u8, d.field, f)) try defaults.append(arena, d);
        };
        try out.append(arena, .{ .component = name, .fields = fields, .defaults = defaults.items });
    }
    return out.items;
}

/// The string-literal elements of an anonymous list `.{ "a", "b" }`.
fn stringElements(arena: std.mem.Allocator, ast: *const std.zig.Ast, node: std.zig.Ast.Node.Index) error{OutOfMemory}![]const []const u8 {
    var buf: [2]std.zig.Ast.Node.Index = undefined;
    const list = ast.fullArrayInit(&buf, node) orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (list.ast.elements) |el| {
        if (ast.nodeTag(el) != .string_literal) continue;
        const s = plainTokenString(ast.tokenSlice(ast.nodeMainToken(el))) orelse continue;
        try out.append(arena, s);
    }
    return out.items;
}

fn plainString(src: []const u8, tok: std.zig.Token) ?[]const u8 {
    return plainTokenString(src[tok.loc.start..tok.loc.end]);
}

/// Contents of a `"..."` token without escapes, else null.
fn plainTokenString(text: []const u8) ?[]const u8 {
    if (text.len < 2 or text[0] != '"' or text[text.len - 1] != '"') return null;
    const inner = text[1 .. text.len - 1];
    if (std.mem.indexOfScalar(u8, inner, '\\') != null) return null;
    return inner;
}

fn lineAt(src: []const u8, pos: usize) usize {
    return std.mem.count(u8, src[0..pos], "\n") + 1;
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
        // Caches, vendored trees and nested repositories are not game source.
        if (entry.kind == .directory and scanner.isSkippableDir(dir, entry.name)) continue;
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

test {
    _ = @import("catalog_key_check_test.zig");
}
