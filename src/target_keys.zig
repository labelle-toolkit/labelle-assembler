//! Target-keyed `project.labelle` keys (labelle-cli RFC #471, item P1).
//!
//! The CLI is going target-agnostic: targets are strings a provider owns,
//! not a closed enum. Two `project.labelle` keys still spell targets:
//!
//!   * `.asset_compression` — keyed by target. It now accepts ANY
//!     identifier key. The keys this assembler generates for (`desktop`,
//!     `android`, `ios`, `wasm`) are read; `web` is a warned alias for
//!     `wasm`, kept indefinitely (owner decision D9); every other key is
//!     ignored for this assembler's targets, with a warning. Unknown keys
//!     are stripped BEFORE the strict typed parse (`stripUnknown`), so a
//!     project written for a newer target set keeps generating here.
//!   * `.platform` — deprecated. The CLI always passes `--target` /
//!     `--platform`, so the key only ever competes with the command line.
//!
//! The strip is silent; the warnings are a separate pass (`logWarnings`)
//! that `generate` runs once, so commands that merely read the config
//! (`install`, `check`, …) do not repeat them.
//!
//! The internal `Platform` enum and `Capability` stay as they are; making
//! them string-keyed is AS5, a separate RFC.

const std = @import("std");
const Zoir = std.zig.Zoir;
const Ast = std.zig.Ast;

/// The `.asset_compression` keys `config.AssetCompression` declares.
/// `web` is the alias for `wasm`.
pub const known_asset_compression_keys = [_][]const u8{ "desktop", "android", "ios", "wasm", "web" };

fn isKnownKey(name: []const u8) bool {
    for (known_asset_compression_keys) |k| {
        if (std.mem.eql(u8, k, name)) return true;
    }
    return false;
}

/// A parsed source, or null when it is not a well-formed ZON struct
/// literal (the strict typed parse owns that diagnostic).
const Doc = struct {
    ast: Ast,
    zoir: Zoir,

    fn init(gpa: std.mem.Allocator, source: [:0]const u8) !?Doc {
        var ast = try Ast.parse(gpa, source, .zon);
        errdefer ast.deinit(gpa);
        if (ast.errors.len != 0) {
            ast.deinit(gpa);
            return null;
        }
        var zoir = try std.zig.ZonGen.generate(gpa, ast, .{ .parse_str_lits = false });
        if (zoir.hasCompileErrors()) {
            zoir.deinit(gpa);
            ast.deinit(gpa);
            return null;
        }
        return .{ .ast = ast, .zoir = zoir };
    }

    fn deinit(self: *Doc, gpa: std.mem.Allocator) void {
        self.zoir.deinit(gpa);
        self.ast.deinit(gpa);
    }

    /// The root struct literal's fields, or null.
    fn root(self: Doc) ?@FieldType(Zoir.Node, "struct_literal") {
        return switch (Zoir.Node.Index.root.get(self.zoir)) {
            .struct_literal => |fields| fields,
            else => null,
        };
    }

    /// The value of top-level key `name`, or null.
    fn topLevel(self: Doc, name: []const u8) ?Zoir.Node.Index {
        const fields = self.root() orelse return null;
        for (fields.names, 0..) |n, i| {
            if (std.mem.eql(u8, n.get(self.zoir), name)) return fields.vals.at(@intCast(i));
        }
        return null;
    }

    /// The `.asset_compression` struct literal's fields, or null (absent,
    /// empty `.{}`, or not a struct literal — the typed parse's call).
    fn assetCompression(self: Doc) ?@FieldType(Zoir.Node, "struct_literal") {
        const node = self.topLevel("asset_compression") orelse return null;
        return switch (node.get(self.zoir)) {
            .struct_literal => |fields| fields,
            else => null,
        };
    }
};

/// A copy of `source` with every unknown `.asset_compression` key blanked,
/// or null when there is none (the common case: no copy, no change).
///
/// Each stripped field — `.name = value` and its trailing comma — becomes
/// spaces, with every newline kept, so byte offsets and line numbers (and
/// so every other diagnostic) stay exact. The same technique as the
/// `.params` blanking in `plugin_params.extractParamsBags`. Caller frees.
pub fn stripUnknown(gpa: std.mem.Allocator, source: [:0]const u8) !?[:0]u8 {
    // Cheap pre-check: most projects never mention the key.
    if (std.mem.indexOf(u8, source, "asset_compression") == null) return null;

    var doc = (try Doc.init(gpa, source)) orelse return null;
    defer doc.deinit(gpa);
    const fields = doc.assetCompression() orelse return null;

    var out: ?[:0]u8 = null;
    errdefer if (out) |o| gpa.free(o);

    for (fields.names, 0..) |n, i| {
        if (isKnownKey(n.get(doc.zoir))) continue;
        const buf = out orelse blk: {
            out = try gpa.dupeZ(u8, source);
            break :blk out.?;
        };

        const value = fields.vals.at(@intCast(i)).getAstNode(doc.zoir);
        const first = doc.ast.firstToken(value);
        // `.name = value`: the field starts at the `.` three tokens back.
        std.debug.assert(first >= 3);
        const dot = first - 3;
        std.debug.assert(doc.ast.tokenTag(dot) == .period);
        var last = doc.ast.lastToken(value);
        if (doc.ast.tokenTag(last + 1) == .comma) last += 1;

        const start = doc.ast.tokenStart(dot);
        const end = doc.ast.tokenStart(last) + doc.ast.tokenSlice(last).len;
        for (buf[start..end]) |*b| {
            if (b.* != '\n') b.* = ' ';
        }
    }
    return out;
}

/// The deprecation and ignored-key findings for `source`, as log lines.
pub const Finding = union(enum) {
    /// `.asset_compression.<key>` names no target this assembler has.
    unknown_asset_compression_key: []const u8,
    /// `.asset_compression.web` (the alias) is set.
    web_alias,
    /// Both `.web` and `.wasm` are set; `.wasm` wins.
    web_and_wasm,
    /// `.platform` is set.
    platform_key,

    pub fn write(self: Finding, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .unknown_asset_compression_key => |k| try w.print(
                "`.asset_compression.{s}` names no target this assembler generates for " ++
                    "(desktop, android, ios, wasm); it is ignored",
                .{k},
            ),
            .web_alias => try w.writeAll(
                "`.asset_compression.web` is an alias for `.asset_compression.wasm`; " ++
                    "it keeps working, but prefer `.wasm` (the target's name)",
            ),
            .web_and_wasm => try w.writeAll(
                "`.asset_compression` sets both `.web` and `.wasm`; `.wasm` wins " ++
                    "(`.web` is only its alias) — drop `.web`",
            ),
            .platform_key => try w.writeAll(
                "`.platform` is deprecated: the target comes from the command line " ++
                    "(the labelle CLI passes `--platform` / `--target`), so remove the key",
            ),
        }
    }
};

/// Collect the findings for `source`, in source order. A source that is not
/// well-formed ZON has none (the typed parse reports it). Caller frees the
/// list with `gpa`; the key strings are copies owned by the same list's
/// allocator and freed by `freeFindings`.
pub fn findings(gpa: std.mem.Allocator, source: [:0]const u8) ![]Finding {
    var list: std.ArrayList(Finding) = .empty;
    errdefer freeFindingsList(gpa, &list);

    var doc = (try Doc.init(gpa, source)) orelse return list.toOwnedSlice(gpa);
    defer doc.deinit(gpa);

    if (doc.assetCompression()) |fields| {
        var has_web = false;
        var has_wasm = false;
        for (fields.names) |n| {
            const name = n.get(doc.zoir);
            if (std.mem.eql(u8, name, "web")) {
                has_web = true;
            } else if (std.mem.eql(u8, name, "wasm")) {
                has_wasm = true;
            } else if (!isKnownKey(name)) {
                try list.append(gpa, .{ .unknown_asset_compression_key = try gpa.dupe(u8, name) });
            }
        }
        if (has_web) try list.append(gpa, if (has_wasm) .web_and_wasm else .web_alias);
    }
    if (doc.topLevel("platform") != null) try list.append(gpa, .platform_key);

    return list.toOwnedSlice(gpa);
}

fn freeFindingsList(gpa: std.mem.Allocator, list: *std.ArrayList(Finding)) void {
    for (list.items) |f| switch (f) {
        .unknown_asset_compression_key => |k| gpa.free(k),
        else => {},
    };
    list.deinit(gpa);
}

pub fn freeFindings(gpa: std.mem.Allocator, fs: []Finding) void {
    for (fs) |f| switch (f) {
        .unknown_asset_compression_key => |k| gpa.free(k),
        else => {},
    };
    gpa.free(fs);
}

/// Log every finding for `source` as a warning. `generate` calls this once
/// per run. Never fails the run: a warning that cannot be computed (OOM) is
/// dropped.
pub fn logWarnings(gpa: std.mem.Allocator, source: [:0]const u8) void {
    const fs = findings(gpa, source) catch return;
    defer freeFindings(gpa, fs);
    for (fs) |f| {
        var buf: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        f.write(&w) catch {};
        std.log.warn("project.labelle: {s}", .{w.buffered()});
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "target keys: stripUnknown leaves a source with only known keys alone" {
    const srcs = [_][:0]const u8{
        ".{ .name = \"g\" }",
        ".{ .name = \"g\", .asset_compression = .{} }",
        ".{ .name = \"g\", .asset_compression = .{ .android = .astc, .web = .astc } }",
        ".{ .name = \"g\", .asset_compression = .{ .desktop = .png, .android = .astc, .ios = .astc, .wasm = .astc, .web = .png } }",
        // Malformed: the typed parse's business.
        ".{ .name = \"g\", .asset_compression = .{ .xbox = } }",
    };
    for (srcs) |src| try testing.expect((try stripUnknown(testing.allocator, src)) == null);
}

test "target keys: stripUnknown blanks unknown keys in place, keeping offsets and newlines" {
    const src: [:0]const u8 =
        \\.{
        \\    .name = "g",
        \\    .asset_compression = .{
        \\        .xbox = .astc,
        \\        .android = .astc,
        \\        .@"ps-5" = .png
        \\    },
        \\}
    ;
    const out = (try stripUnknown(testing.allocator, src)).?;
    defer testing.allocator.free(out);
    try testing.expectEqual(src.len, out.len);
    for (src, out) |a, b| {
        // Newlines never move; every other byte is either kept or blanked.
        if (a == '\n') try testing.expectEqual(@as(u8, '\n'), b);
        if (b != ' ') try testing.expectEqual(a, b);
    }
    try testing.expect(std.mem.indexOf(u8, out, "xbox") == null);
    try testing.expect(std.mem.indexOf(u8, out, "ps-5") == null);
    try testing.expect(std.mem.indexOf(u8, out, ".android = .astc,") != null);
    // The stripped source is still valid ZON with the known key intact.
    const stripped_again = try stripUnknown(testing.allocator, out);
    try testing.expect(stripped_again == null);
}

test "target keys: findings name unknown keys, the web alias, both spellings, and .platform" {
    const src: [:0]const u8 = ".{ .name = \"g\", .platform = .android, .asset_compression = .{ .xbox = .astc, .web = .astc } }";
    const fs = try findings(testing.allocator, src);
    defer freeFindings(testing.allocator, fs);
    try testing.expectEqual(@as(usize, 3), fs.len);
    try testing.expectEqualStrings("xbox", fs[0].unknown_asset_compression_key);
    try testing.expectEqual(Finding.web_alias, fs[1]);
    try testing.expectEqual(Finding.platform_key, fs[2]);

    const both = try findings(testing.allocator, ".{ .name = \"g\", .asset_compression = .{ .web = .png, .wasm = .astc } }");
    defer freeFindings(testing.allocator, both);
    try testing.expectEqual(@as(usize, 1), both.len);
    try testing.expectEqual(Finding.web_and_wasm, both[0]);

    const none = try findings(testing.allocator, ".{ .name = \"g\", .asset_compression = .{ .wasm = .astc } }");
    defer freeFindings(testing.allocator, none);
    try testing.expectEqual(@as(usize, 0), none.len);

    // Malformed ZON yields nothing (and does not crash).
    const bad = try findings(testing.allocator, ".{ .platform = }");
    defer freeFindings(testing.allocator, bad);
    try testing.expectEqual(@as(usize, 0), bad.len);
}

test "target keys: every finding renders a message" {
    const all = [_]Finding{ .{ .unknown_asset_compression_key = "xbox" }, .web_alias, .web_and_wasm, .platform_key };
    for (all) |f| {
        var buf: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try f.write(&w);
        try testing.expect(w.buffered().len > 0);
    }
}

// ── Through the real project.labelle parse ──────────────────────────────

const config = @import("config.zig");
const plugin_params = @import("plugin_params.zig");

fn parseForTest(arena: std.mem.Allocator, src: [:0]const u8) !config.ProjectConfig {
    return plugin_params.parseProjectConfig(arena, src);
}

test "target keys: Flying Platform's exact asset_compression literal gives identical results (RFC #471 P1 regression)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // The literal FP ships, verbatim.
    const cfg = try parseForTest(arena.allocator(), ".{ .name = \"fp\", .asset_compression = .{ .android = .astc, .web = .astc } }");
    const ac = cfg.asset_compression;
    // Pre-P1 behaviour: desktop/ios default png; android and wasm (via `.web`) astc.
    try testing.expectEqual(config.AssetFormat.png, ac.formatFor(.desktop));
    try testing.expectEqual(config.AssetFormat.astc, ac.formatFor(.android));
    try testing.expectEqual(config.AssetFormat.png, ac.formatFor(.ios));
    try testing.expectEqual(config.AssetFormat.astc, ac.formatFor(.wasm));
    // And nothing is stripped or rewritten: the parse saw the source as is.
    try testing.expect((try stripUnknown(testing.allocator, ".{ .name = \"fp\", .asset_compression = .{ .android = .astc, .web = .astc } }")) == null);
}

test "target keys: .wasm is read, wins over the .web alias, and absent keys stay png" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(config.AssetFormat.astc, (try parseForTest(a, ".{ .name = \"g\", .asset_compression = .{ .wasm = .astc } }")).asset_compression.formatFor(.wasm));
    try testing.expectEqual(config.AssetFormat.png, (try parseForTest(a, ".{ .name = \"g\", .asset_compression = .{ .wasm = .png, .web = .astc } }")).asset_compression.formatFor(.wasm));
    try testing.expectEqual(config.AssetFormat.astc, (try parseForTest(a, ".{ .name = \"g\", .asset_compression = .{ .wasm = .astc, .web = .png } }")).asset_compression.formatFor(.wasm));
    try testing.expectEqual(config.AssetFormat.png, (try parseForTest(a, ".{ .name = \"g\" }")).asset_compression.formatFor(.wasm));
    try testing.expectEqual(config.AssetFormat.png, (try parseForTest(a, ".{ .name = \"g\", .asset_compression = .{} }")).asset_compression.formatFor(.wasm));
}

test "target keys: an unknown asset_compression key parses and is ignored per target" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = try parseForTest(arena.allocator(),
        \\.{
        \\    .name = "g",
        \\    .asset_compression = .{ .xbox = .astc, .android = .astc, .@"switch" = .astc },
        \\}
    );
    const ac = cfg.asset_compression;
    try testing.expectEqual(config.AssetFormat.png, ac.formatFor(.desktop));
    try testing.expectEqual(config.AssetFormat.astc, ac.formatFor(.android));
    try testing.expectEqual(config.AssetFormat.png, ac.formatFor(.ios));
    try testing.expectEqual(config.AssetFormat.png, ac.formatFor(.wasm));
}

test "target keys: a typo elsewhere still gets the typed parse's error on the right line" {
    const src: [:0]const u8 =
        \\.{
        \\    .name = "g",
        \\    .asset_compression = .{ .xbox = .astc },
        \\    .titel = "typo",
        \\}
    ;
    const stripped = (try stripUnknown(testing.allocator, src)).?;
    defer testing.allocator.free(stripped);
    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(testing.allocator);
    try testing.expectError(error.ParseZon, std.zon.parse.fromSliceAlloc(config.ProjectConfig, testing.allocator, stripped, &diag, .{}));
    var it = diag.iterateErrors();
    const e = it.next().?;
    const loc = e.getLocation(&diag);
    try testing.expectEqual(@as(usize, 3), loc.line); // 0-based: the `.titel` line
    // And a known key with a wrong value is still the typed parse's error.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.ParseZon, parseForTest(arena.allocator(), ".{ .name = \"g\", .asset_compression = .{ .android = .jpeg } }"));
}
