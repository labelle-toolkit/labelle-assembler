//! Tests for `catalog_key_check.zig` (labelle-assembler#738).
const std = @import("std");
const config = @import("config.zig");
const ck = @import("catalog_key_check.zig");

const testing = std.testing;

const test_resources = [_]config.ResourceDef{
    .{ .name = "fog_mask" },
    .{ .name = "reservoir_mask" },
    .{ .name = "reservoir_reflection" },
    .{ .name = "sky__clouds" },
};

test "scanZigKeys: .catalog literals with lines; comments, runtime keys and look-alikes skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\const a = .{ .name = "s", .texture = .{ .catalog = "fog_mask" } };
        \\// .texture = .{ .catalog = "commented_out" },
        \\const b = .{ .catalog = w.mask };
        \\const c = .{ .catalog="fog_maks" }; // .catalog = "trailing_comment"
        \\const eq = x.catalog == "cmp";
        \\const d = .{ .catalogue = "other_field" };
        \\const q = '"'; const e = .{ .catalog = "reservoir_mask" };
        \\const m =
        \\    \\ .catalog = "inside_multiline_string"
        \\;
        \\const split = .{
        \\    .catalog =
        \\        "split_key",
        \\};
    ;
    const keys = try ck.scanZigKeys(arena.allocator(), src);
    try testing.expectEqual(@as(usize, 4), keys.catalog.len);
    try testing.expectEqualStrings("fog_mask", keys.catalog[0].key);
    try testing.expectEqual(@as(usize, 1), keys.catalog[0].line);
    try testing.expectEqualStrings("fog_maks", keys.catalog[1].key);
    try testing.expectEqual(@as(usize, 4), keys.catalog[1].line);
    try testing.expectEqualStrings("reservoir_mask", keys.catalog[2].key);
    try testing.expectEqual(@as(usize, 7), keys.catalog[2].line);
    try testing.expectEqualStrings("split_key", keys.catalog[3].key);
    try testing.expectEqual(@as(usize, 13), keys.catalog[3].line);
    try testing.expectEqual(@as(usize, 0), keys.registered.len);
}

test "scanZigKeys: leading string argument of register calls, any spacing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\try g.assets.register("runtime_mask", .image, bytes);
        \\try g.registerImageFromMemory (
        \\    "other_mask", bytes);
        \\r.registerCatalogTexture(handle, tex);
        \\// register("commented")
        \\unregister("not_a_registration");
    ;
    const keys = try ck.scanZigKeys(arena.allocator(), src);
    try testing.expectEqual(@as(usize, 2), keys.registered.len);
    try testing.expectEqualStrings("runtime_mask", keys.registered[0]);
    try testing.expectEqualStrings("other_mask", keys.registered[1]);
}

test "parseKeyDecls: catalog_keys and defaults of the component struct itself" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\const std = @import("std");
        \\pub const WaterShader = struct {
        \\    // pub const catalog_keys = .{ "commented" };
        \\    pub const Tuning = struct { mask: []const u8 = "nested_default" };
        \\    pub fn f(self: @This()) void { _ = self; }
        \\    pub const catalog_keys = .{ "mask", "reflection" };
        \\    mask: []const u8 =
        \\        "reservoir_mask",
        \\    reflection: []const u8 = default_reflection,
        \\};
        \\const default_reflection = "x";
        \\pub const Plain = struct { x: f32 = 0 };
    ;
    const decls = try ck.parseKeyDecls(arena.allocator(), src);
    try testing.expectEqual(@as(usize, 1), decls.len);
    try testing.expectEqualStrings("WaterShader", decls[0].component);
    try testing.expectEqual(@as(usize, 2), decls[0].fields.len);
    try testing.expectEqualStrings("mask", decls[0].fields[0]);
    try testing.expectEqualStrings("reflection", decls[0].fields[1]);
    // Only the OUTER `mask` has a literal default (not Tuning's).
    try testing.expectEqual(@as(usize, 1), decls[0].defaults.len);
    try testing.expectEqualStrings("reservoir_mask", decls[0].defaults[0].key);
    try testing.expectEqual(@as(usize, 8), decls[0].defaults[0].line);
}

test "parseKeyDecls: a source that does not parse yields nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const decls = try ck.parseKeyDecls(arena.allocator(), "pub const A = struct { pub const catalog_keys = .{\"m\"} ");
    try testing.expectEqual(@as(usize, 0), decls.len);
}

test "suggest: edit distance first, prefix fallback for long suffixes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("fog_mask", (try ck.suggest(a, "fog_maks", &test_resources)).?);
    try testing.expectEqualStrings("reservoir_mask", (try ck.suggest(a, "reservoir_mask_MISSING", &test_resources)).?);
    try testing.expect((try ck.suggest(a, "zzzzzzzzzz", &test_resources)) == null);
}

const water_decl = [_]ck.KeyDecl{.{ .component = "WaterShader", .fields = &.{ "mask", "reflection" } }};

test "checkJsonSource: typo'd prefab binding reported with component, field, line, hint (JSONC)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Comments and trailing commas: the JSONC the scene parser accepts.
    const src =
        \\// reservoir
        \\{
        \\  "Position": { "x": 1, },
        \\  "WaterShader": {
        \\    /* bound in 20_shader_effects.zig */
        \\    "mask": "reservoir_mask_MISSING",
        \\    "reflection": "reservoir_reflection",
        \\  },
        \\}
    ;
    var findings: std.ArrayList(ck.Finding) = .empty;
    try ck.checkJsonSource(a, "prefabs/reservoir.jsonc", src, &water_decl, &test_resources, &findings);
    try testing.expectEqual(@as(usize, 1), findings.items.len);
    const f = findings.items[0];
    try testing.expectEqualStrings("prefabs/reservoir.jsonc", f.file);
    try testing.expectEqual(@as(usize, 6), f.line);
    try testing.expectEqualStrings("reservoir_mask_MISSING", f.key);
    try testing.expectEqualStrings("WaterShader", f.site.component_field.component);
    try testing.expectEqualStrings("mask", f.site.component_field.field);
    try testing.expectEqualStrings("reservoir_mask", f.suggestion.?);
}

test "checkJsonSource: scene component maps are checked, payload reusing the name is not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\{ "entities": [
        \\  { "prefab": "reservoir", "components": { "WaterShader": { "mask": "sky__clouds" } } },
        \\  { "components": { "Config": { "WaterShader": { "mask": "ordinary_value" } } } },
        \\  { "components": { "WaterShader": { "reflection": "reservoir_reflect" } } }
        \\] }
    ;
    var findings: std.ArrayList(ck.Finding) = .empty;
    try ck.checkJsonSource(a, "scenes/main.jsonc", src, &water_decl, &test_resources, &findings);
    // Only the real component site with a typo; `Config`'s payload is opaque.
    try testing.expectEqual(@as(usize, 1), findings.items.len);
    try testing.expectEqualStrings("reservoir_reflect", findings.items[0].key);
    try testing.expectEqual(@as(usize, 4), findings.items[0].line);
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
        // A key the game registers from code is bound at runtime by design.
        .{ "scripts/playing/runtime.zig", "try g.assets.register(\"runtime_mask\", .image, b);\nconst u = .{ .catalog = \"runtime_mask\" };\n" },
        // Vendored trees are not game source.
        .{ "scripts/node_modules/pkg/x.zig", "const v = .{ .catalog = \"vendored_MISSING\" };\n" },
        .{ "prefabs/reservoir.jsonc", "{ \"WaterShader\": { \"mask\": \"reservoir_mask\" } }\n" },
    });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const game_dir = try tmp.dir.realPathFileAlloc(config.globalIo(), ".", arena.allocator());
    const findings = try ck.check(arena.allocator(), game_dir, &test_resources);
    try testing.expectEqual(@as(usize, 0), findings.len);
    try ck.validate(testing.allocator, game_dir, &test_resources);
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
    const findings = try ck.check(arena.allocator(), game_dir, &test_resources);
    try testing.expectEqual(@as(usize, 2), findings.len);

    try testing.expectEqualStrings("scripts/playing/fx.zig", findings[0].file);
    try testing.expectEqual(@as(usize, 2), findings[0].line);
    try testing.expect(findings[0].site == .catalog_literal);
    try testing.expectEqualStrings("fog_mask_MISSING", findings[0].key);
    try testing.expectEqualStrings("fog_mask", findings[0].suggestion.?);

    try testing.expectEqualStrings("prefabs/reservoir.jsonc", findings[1].file);
    try testing.expect(findings[1].site == .component_field);
    try testing.expectEqualStrings("reservoir_mask_MISSING", findings[1].key);

    try testing.expectError(error.UnregisteredCatalogKey, ck.validate(testing.allocator, game_dir, &test_resources));
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
    const findings = try ck.check(arena.allocator(), game_dir, &test_resources);
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expectEqualStrings("components/water_shader.zig", findings[0].file);
    try testing.expectEqual(@as(usize, 3), findings[0].line);
    try testing.expectEqualStrings("mask", findings[0].site.component_field.field);
    try testing.expectEqualStrings("reservoir_mask_MISSING", findings[0].key);
}
