//! Script-declared components — declare-mode extraction + Zig codegen
//! (labelle-assembler#585; RFC-LANGUAGE-PLUGINS revs 6-7, epic
//! labelle-engine#237).
//!
//! Scripts declare components natively at chunk scope
//! (`labelle.component("Hunger", { level = 1.0 })`). At generate time this
//! phase — the second consumer of the #593 scripting splice — runs the
//! plugin's DECLARE-MODE RUNNER (`labelle-declare`, shipped inside the
//! labelle-scripting package under tools/declare/) over the project's
//! collected scripts. The runner executes only chunk bodies against a stub
//! `labelle` and prints ONE schema JSON on stdout — the runner↔assembler
//! contract:
//!
//!   {"components":[{"name":"Hunger","persist":"persistent",
//!     "fields":[{"name":"level","type":"f32","default":1.0},
//!               {"name":"starving","type":"bool","default":false}]}]}
//!
//! Types v1: f32 i32 u32 bool str vec2 entity ("persist": "persistent"
//! [default] | "transient"; enums land LATER and are rejected with a clear
//! error). From that schema the phase codegens `scripting_components.zig`
//! into the target — one real Zig struct per component, `Saveable`-decl'd
//! exactly like a hand-written `components/*.zig` — and the registry block
//! registers each by its declared name. Scenes, prefabs, save buckets,
//! typed Zig queries and the script contract's by-name dispatch all reach
//! them with zero further wiring.
//!
//! No-op guarantee: no scripts, or scripts with no declarations, emit
//! nothing — no file, no registry entries, byte-identical output (the
//! stale `scripting_components.zig` of a removed declaration set is
//! deleted, never regenerated).
//!
//! ── The exec slice (build + cache mechanics) ─────────────────────────
//! The runner binary is built FROM THE CONSUMING GAME'S staged plugin
//! package: `build.zig.zon` generation stages every plugin under
//! `<output>/.labelle/deps/labelle-<name>/` (deps_linker hardlinks), so
//! this phase — ordered right after it — invokes
//!
//!   zig build labelle-declare
//!       --cache-dir <output>/declare-tool/zig-cache
//!       --prefix    <output>/declare-tool
//!       (cwd = <output>/deps/labelle-scripting)
//!
//! via std.process and picks up `<output>/declare-tool/bin/labelle-declare`.
//! Building from the staged copy keeps the runner byte-consistent with the
//! plugin version the game links, and every artifact lands inside
//! `.labelle/` (never in the user's plugin checkout). The cache dir and
//! install prefix are EXTERNAL to the deps copy on purpose: deps are wiped
//! and re-hardlinked on every generate, so an in-package `zig-out/` would
//! force a from-scratch tool rebuild each time — parked under
//! `<output>/declare-tool/` they survive, and zig's content-keyed cache
//! (hardlinks preserve content) makes the warm re-generate a no-op build.
//! The resulting path is ALSO cached in-process (keyed by the package
//! dir), so the tests-target pass in the same process skips even the no-op
//! `zig build`. When the deps copy is missing (deps linking fell back to
//! cache-relative paths) the cache-resolved plugin dir is used instead.
//!
//! This narrow "exec `zig build <step>` inside a staged plugin package at
//! generate time" is deliberately the FIRST SLICE of the generic plugin
//! build hooks (labelle-assembler#586): when #586 lands its general
//! protocol, this hardcoded labelle-declare invocation folds into it —
//! until then the mechanics live here, scoped to THE scripting plugin.
//!
//! Hermetic-test seam: `declare_tool_override` (below) bypasses the
//! build-and-locate step entirely — the assembler's own suite must not
//! depend on a network fetch of the lua sources or a `zig` on PATH, and
//! an override hook is the right seam for any harness that sandboxes
//! subprocess builds.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const cache = @import("cache.zig");
const scanner = @import("scanner.zig");
const scan = @import("codegen/scan.zig");
const idents = @import("codegen/idents.zig");

/// The generated file name, written beside `main.zig` in the target dir.
/// The registry block imports it verbatim (`@import("scripting_components.zig")`).
pub const GENERATED_FILENAME = "scripting_components.zig";

/// Test seam: absolute path of a prebuilt declare tool. When set, the
/// build-and-locate step is skipped entirely and this binary is exec'd
/// over the scripts instead. Same scoped-threadlocal pattern as
/// `main_template.scripting_splice` — tests set it around a `generate`
/// call and clear it after.
pub threadlocal var declare_tool_override: ?[]const u8 = null;

// In-process cache of the last tool built (see the exec-slice doc above):
// the package dir it was built from and the resulting binary path. Fixed
// buffers, not allocator-owned — the cache outlives any single generate
// call's allocator (and test allocators must not see it as a leak).
threadlocal var cached_pkg: [std.fs.max_path_bytes]u8 = undefined;
threadlocal var cached_pkg_len: usize = 0;
threadlocal var cached_tool: [std.fs.max_path_bytes]u8 = undefined;
threadlocal var cached_tool_len: usize = 0;

// ── Schema model (the runner↔assembler contract) ─────────────────────

pub const Persist = enum { persistent, transient };

/// v1 field-type vocabulary. `enum`-typed fields are a known LATER —
/// `parseSchema` rejects them (and any other unknown type string) with a
/// clear error naming the component and field.
pub const FieldType = enum { f32, i32, u32, bool, str, vec2, entity };

pub const Vec2Default = struct { x: f64, y: f64 };

/// A field's type + default, carried together: the tag IS the schema
/// "type" and the payload the parsed "default".
pub const Default = union(FieldType) {
    f32: f64,
    i32: i32,
    u32: u32,
    bool: bool,
    str: []const u8,
    vec2: Vec2Default,
    entity: u64,
};

pub const DeclaredField = struct {
    name: []const u8,
    default: Default,
};

pub const DeclaredComponent = struct {
    name: []const u8,
    persist: Persist,
    fields: []const DeclaredField,
};

/// A parsed schema. Owns every slice reachable from `components` via its
/// arena; `deinit` releases the lot.
pub const Schema = struct {
    arena: *std.heap.ArenaAllocator,
    components: []const DeclaredComponent,

    pub fn deinit(self: *Schema) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
        self.components = &.{};
    }
};

// ── Diagnostics ──────────────────────────────────────────────────────

/// Print a labelled generate-time diagnostic to stderr (the
/// `main_template` style — NOT `std.log.err`, which the Zig test runner
/// classifies as a test failure even for expected-error cases).
fn diag(comptime fmt: []const u8, args: anytype) void {
    const io = config.globalIo();
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "labelle-assembler: " ++ fmt ++ "\n", args) catch
        "labelle-assembler: script-declared components: diagnostic too long\n";
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
}

/// Relay a child process' stderr (already formatted, file-and-name
/// bearing) to our stderr verbatim.
fn relayChildStderr(text: []const u8) void {
    if (text.len == 0) return;
    const io = config.globalIo();
    std.Io.File.stderr().writeStreamingAll(io, text) catch {};
    if (text[text.len - 1] != '\n')
        std.Io.File.stderr().writeStreamingAll(io, "\n") catch {};
}

// ── Schema parsing ───────────────────────────────────────────────────

fn isIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    // `_` alone is Zig's discard token, not an identifier — `pub const _`
    // and `_: f32` both fail to compile.
    if (s.len == 1 and s[0] == '_') return false;
    for (s, 0..) |ch, i| {
        const ok = ch == '_' or
            (ch >= 'A' and ch <= 'Z') or
            (ch >= 'a' and ch <= 'z') or
            (i != 0 and ch >= '0' and ch <= '9');
        if (!ok) return false;
    }
    return true;
}

/// The generated file spells component and field names as BARE Zig
/// identifiers (`pub const <name> = struct { <field>: T = ..., }`), so a
/// Zig keyword (`error`, `align`, `struct`, …) passes the char-class check
/// above yet renders code that cannot compile in ANY position. The list is
/// the compiler's own tokenizer table, so it can never drift.
fn isZigKeyword(s: []const u8) bool {
    return std.zig.Token.keywords.has(s);
}

/// Primitive type/value names (`type`, `f32`, `u64`, `true`, …) are NOT
/// tokenizer keywords, but a decl spelling one is "name shadows primitive"
/// (breaks a component named `type`) — and they're reserved for FIELDS too,
/// so a declared field name stays spellable as a bare identifier in every
/// generated context, present and future. The compiler's own table again.
fn isZigPrimitive(s: []const u8) bool {
    return std.zig.primitives.isPrimitive(s);
}

/// Member decls EVERY rendered component struct carries (see
/// `renderComponentsFile`) — a field with one of these names would collide
/// with its own struct's generated decl.
const generated_member_decls = [_][]const u8{"save"};

/// Parse + validate one schema JSON document into typed components.
/// Validation is deliberately re-done here even though the lua runner
/// already validated: the schema is a CONTRACT — future runners (other
/// languages) feed the same seam, and a generate-time error beats
/// generated code that doesn't compile.
pub fn parseSchema(gpa: std.mem.Allocator, json_text: []const u8) !Schema {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const trimmed = std.mem.trim(u8, json_text, " \t\r\n");
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, trimmed, .{}) catch {
        diag("script component schema is not valid JSON: {s}", .{truncateForDiag(trimmed)});
        return error.ScriptSchemaInvalid;
    };

    const root_obj = switch (root) {
        .object => |o| o,
        else => {
            diag("script component schema: expected a top-level object", .{});
            return error.ScriptSchemaInvalid;
        },
    };
    const comps_val = root_obj.get("components") orelse {
        diag("script component schema: missing the \"components\" array", .{});
        return error.ScriptSchemaInvalid;
    };
    const comps_arr = switch (comps_val) {
        .array => |arr| arr,
        else => {
            diag("script component schema: \"components\" must be an array", .{});
            return error.ScriptSchemaInvalid;
        },
    };

    var components = try a.alloc(DeclaredComponent, comps_arr.items.len);
    for (comps_arr.items, 0..) |comp_val, i| {
        components[i] = try parseComponent(a, comp_val);
        // Duplicate names would generate two identical registry fields —
        // a confusing downstream compile error; catch them here. O(n²)
        // over a handful of declarations.
        for (components[0..i]) |prev| {
            if (std.mem.eql(u8, prev.name, components[i].name)) {
                diag("script component schema declares '{s}' twice", .{prev.name});
                return error.ScriptSchemaInvalid;
            }
        }
    }

    return .{ .arena = arena, .components = components };
}

fn parseComponent(a: std.mem.Allocator, val: std.json.Value) !DeclaredComponent {
    const obj = switch (val) {
        .object => |o| o,
        else => {
            diag("script component schema: each components[] entry must be an object", .{});
            return error.ScriptSchemaInvalid;
        },
    };

    const name_val = obj.get("name") orelse {
        diag("script component schema: a component is missing its \"name\"", .{});
        return error.ScriptSchemaInvalid;
    };
    const name = switch (name_val) {
        .string => |s| s,
        else => {
            diag("script component schema: a component \"name\" must be a string", .{});
            return error.ScriptSchemaInvalid;
        },
    };
    if (!isIdentifier(name)) {
        diag("script-declared component '{s}' is not a valid identifier", .{name});
        return error.ScriptSchemaInvalid;
    }
    if (isZigKeyword(name)) {
        diag("script-declared component '{s}': the name is a Zig keyword — the generated `pub const {s} = struct` would not compile; pick another name", .{ name, name });
        return error.ScriptSchemaInvalid;
    }
    if (isZigPrimitive(name)) {
        diag("script-declared component '{s}': the name shadows a Zig primitive — the generated `pub const {s} = struct` would not compile; pick another name", .{ name, name });
        return error.ScriptSchemaInvalid;
    }
    if (std.mem.eql(u8, name, "Vec2")) {
        // The generated file reserves `Vec2` for the vec2-field backing
        // struct (see renderComponentsFile).
        diag("script-declared component name 'Vec2' is reserved by the generated file", .{});
        return error.ScriptSchemaInvalid;
    }

    var persist: Persist = .persistent;
    if (obj.get("persist")) |p_val| {
        const p_str = switch (p_val) {
            .string => |s| s,
            else => {
                diag("script-declared component '{s}': \"persist\" must be a string", .{name});
                return error.ScriptSchemaInvalid;
            },
        };
        persist = std.meta.stringToEnum(Persist, p_str) orelse {
            diag("script-declared component '{s}': unknown persist \"{s}\" (expected \"persistent\" or \"transient\")", .{ name, p_str });
            return error.ScriptSchemaInvalid;
        };
    }

    var fields: []DeclaredField = &.{};
    if (obj.get("fields")) |f_val| {
        const f_arr = switch (f_val) {
            .array => |arr| arr,
            else => {
                diag("script-declared component '{s}': \"fields\" must be an array", .{name});
                return error.ScriptSchemaInvalid;
            },
        };
        fields = try a.alloc(DeclaredField, f_arr.items.len);
        for (f_arr.items, 0..) |field_val, i| {
            fields[i] = try parseField(a, name, field_val);
            for (fields[0..i]) |prev| {
                if (std.mem.eql(u8, prev.name, fields[i].name)) {
                    diag("script-declared component '{s}' declares field '{s}' twice", .{ name, prev.name });
                    return error.ScriptSchemaInvalid;
                }
            }
        }
    }

    return .{
        .name = try a.dupe(u8, name),
        .persist = persist,
        .fields = fields,
    };
}

fn parseField(a: std.mem.Allocator, comp_name: []const u8, val: std.json.Value) !DeclaredField {
    const obj = switch (val) {
        .object => |o| o,
        else => {
            diag("script-declared component '{s}': each fields[] entry must be an object", .{comp_name});
            return error.ScriptSchemaInvalid;
        },
    };
    const name = switch (obj.get("name") orelse .null) {
        .string => |s| s,
        else => {
            diag("script-declared component '{s}': a field is missing its \"name\" string", .{comp_name});
            return error.ScriptSchemaInvalid;
        },
    };
    if (!isIdentifier(name)) {
        diag("script-declared component '{s}' field '{s}' is not a valid identifier", .{ comp_name, name });
        return error.ScriptSchemaInvalid;
    }
    if (isZigKeyword(name)) {
        diag("script-declared component '{s}' field '{s}': the name is a Zig keyword — the generated `{s}: <type> = ...` field would not compile; pick another name", .{ comp_name, name, name });
        return error.ScriptSchemaInvalid;
    }
    if (isZigPrimitive(name)) {
        diag("script-declared component '{s}' field '{s}': the name is a Zig primitive type/value name — reserved so generated code can always spell the field bare; pick another name", .{ comp_name, name });
        return error.ScriptSchemaInvalid;
    }
    for (generated_member_decls) |decl| {
        if (std.mem.eql(u8, name, decl)) {
            diag("script-declared component '{s}' field '{s}': the name collides with the `{s}` decl every generated component struct carries — pick another name", .{ comp_name, name, decl });
            return error.ScriptSchemaInvalid;
        }
    }
    const type_str = switch (obj.get("type") orelse .null) {
        .string => |s| s,
        else => {
            diag("script-declared component '{s}' field '{s}': missing \"type\" string", .{ comp_name, name });
            return error.ScriptSchemaInvalid;
        },
    };
    const field_type = std.meta.stringToEnum(FieldType, type_str) orelse {
        if (std.mem.eql(u8, type_str, "enum")) {
            diag("script-declared component '{s}' field '{s}': enum fields are not supported yet (schema v1 types: f32 i32 u32 bool str vec2 entity)", .{ comp_name, name });
        } else {
            diag("script-declared component '{s}' field '{s}': unknown type \"{s}\" (schema v1 types: f32 i32 u32 bool str vec2 entity)", .{ comp_name, name, type_str });
        }
        return error.ScriptSchemaInvalid;
    };
    const default_val = obj.get("default") orelse {
        diag("script-declared component '{s}' field '{s}': missing \"default\"", .{ comp_name, name });
        return error.ScriptSchemaInvalid;
    };

    const default: Default = switch (field_type) {
        .f32 => .{ .f32 = try expectNumber(comp_name, name, default_val) },
        .i32 => .{ .i32 = std.math.cast(i32, try expectInteger(comp_name, name, default_val)) orelse
            return failRange(comp_name, name, "i32") },
        .u32 => .{ .u32 = std.math.cast(u32, try expectInteger(comp_name, name, default_val)) orelse
            return failRange(comp_name, name, "u32") },
        .bool => switch (default_val) {
            .bool => |b| .{ .bool = b },
            else => {
                diag("script-declared component '{s}' field '{s}': bool default must be true/false", .{ comp_name, name });
                return error.ScriptSchemaInvalid;
            },
        },
        .str => switch (default_val) {
            .string => |s| .{ .str = try a.dupe(u8, s) },
            else => {
                diag("script-declared component '{s}' field '{s}': str default must be a string", .{ comp_name, name });
                return error.ScriptSchemaInvalid;
            },
        },
        .vec2 => switch (default_val) {
            .object => |vo| blk: {
                if (vo.count() != 2) return failVec2(comp_name, name);
                const x = vo.get("x") orelse return failVec2(comp_name, name);
                const y = vo.get("y") orelse return failVec2(comp_name, name);
                break :blk .{ .vec2 = .{
                    .x = try expectNumber(comp_name, name, x),
                    .y = try expectNumber(comp_name, name, y),
                } };
            },
            else => return failVec2(comp_name, name),
        },
        .entity => .{ .entity = std.math.cast(u64, try expectInteger(comp_name, name, default_val)) orelse
            return failRange(comp_name, name, "entity (u64)") },
    };

    return .{ .name = try a.dupe(u8, name), .default = default };
}

fn expectNumber(comp_name: []const u8, field_name: []const u8, val: std.json.Value) !f64 {
    return switch (val) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        else => {
            diag("script-declared component '{s}' field '{s}': default must be a number", .{ comp_name, field_name });
            return error.ScriptSchemaInvalid;
        },
    };
}

fn expectInteger(comp_name: []const u8, field_name: []const u8, val: std.json.Value) !i64 {
    return switch (val) {
        .integer => |n| n,
        else => {
            diag("script-declared component '{s}' field '{s}': default must be an integer", .{ comp_name, field_name });
            return error.ScriptSchemaInvalid;
        },
    };
}

fn failRange(comp_name: []const u8, field_name: []const u8, comptime what: []const u8) error{ScriptSchemaInvalid} {
    diag("script-declared component '{s}' field '{s}': default out of " ++ what ++ " range", .{ comp_name, field_name });
    return error.ScriptSchemaInvalid;
}

fn failVec2(comp_name: []const u8, field_name: []const u8) error{ScriptSchemaInvalid} {
    diag("script-declared component '{s}' field '{s}': vec2 default must be {{\"x\":<number>,\"y\":<number>}}", .{ comp_name, field_name });
    return error.ScriptSchemaInvalid;
}

fn truncateForDiag(s: []const u8) []const u8 {
    const cap = 200;
    return if (s.len <= cap) s else s[0..cap];
}

// ── Codegen: schema → scripting_components.zig ───────────────────────

/// The save-policy enum literal `renderComponentsFile` writes into the
/// generated `Saveable(.<policy>, …)` decl — persistent→`saveable` (core
/// has no `.persistent`), transient→`transient`. Public so the manifest
/// sidecar reports the SAME policy codegen emits.
pub fn savePolicyName(p: Persist) []const u8 {
    return switch (p) {
        .persistent => "saveable",
        .transient => "transient",
    };
}

/// The Zig type `renderComponentsFile` writes for a field — public so the
/// manifest sidecar reports the SAME field types codegen emits (`str` is
/// the slice type, `vec2` the generated-file-local backing struct,
/// `entity` the core Stored idiom's u64 id).
pub fn zigFieldTypeName(default: Default) []const u8 {
    return switch (default) {
        .f32 => "f32",
        .i32 => "i32",
        .u32 => "u32",
        .bool => "bool",
        .str => "[]const u8",
        .vec2 => "Vec2",
        .entity => "u64",
    };
}

/// Render the generated `scripting_components.zig` for `components`.
/// Each struct copies the canonical hand-written component shape (the
/// `examples/packs-demo` pack components / `labelle add feature`
/// scaffold): a `pub const save = @import("labelle-core").Saveable(...)`
/// decl plus defaulted fields. Persist maps persistent→`.saveable`,
/// transient→`.transient`. `entity` fields are the core `Stored` idiom —
/// a `u64` id field listed in the Saveable's `.entity_refs`, so save/load
/// remaps them like any hand-written ref.
pub fn renderComponentsFile(components: []const DeclaredComponent, w: anytype) !void {
    try w.writeAll(
        \\//! Script-declared components (labelle-assembler#585,
        \\//! RFC-LANGUAGE-PLUGINS). GENERATED from the declare-mode schema —
        \\//! do not edit; change the `labelle.component(...)` declarations in
        \\//! the game's scripts instead. Each struct is registered into the
        \\//! game's component registry under its declared name, so scenes,
        \\//! prefabs, save buckets, typed queries and the script contract's
        \\//! by-name dispatch all reach it like any components/*.zig file.
        \\
        \\
    );

    var any_vec2 = false;
    for (components) |comp| {
        for (comp.fields) |field| {
            if (field.default == .vec2) any_vec2 = true;
        }
    }
    if (any_vec2) {
        try w.writeAll(
            \\/// Plain {x,y} pair backing `vec2` schema fields (no core Vec2
            \\/// export exists; serde reflects nested structs fine).
            \\pub const Vec2 = struct { x: f32 = 0, y: f32 = 0 };
            \\
            \\
        );
    }

    for (components) |comp| {
        try w.print("pub const {s} = struct {{\n", .{comp.name});

        const policy = savePolicyName(comp.persist);
        var entity_ref_count: usize = 0;
        for (comp.fields) |field| {
            if (field.default == .entity) entity_ref_count += 1;
        }
        if (entity_ref_count == 0) {
            try w.print("    pub const save = @import(\"labelle-core\").Saveable(.{s}, @This(), .{{}});\n", .{policy});
        } else {
            try w.print("    pub const save = @import(\"labelle-core\").Saveable(.{s}, @This(), .{{\n", .{policy});
            try w.writeAll("        .entity_refs = &.{");
            var emitted: usize = 0;
            for (comp.fields) |field| {
                if (field.default != .entity) continue;
                if (emitted > 0) try w.writeAll(", ");
                try w.print("\"{s}\"", .{field.name});
                emitted += 1;
            }
            try w.writeAll("},\n    });\n");
        }

        if (comp.fields.len > 0) try w.writeAll("\n");
        for (comp.fields) |field| {
            try w.print("    {s}: {s} = ", .{ field.name, zigFieldTypeName(field.default) });
            switch (field.default) {
                .f32 => |v| try w.print("{d}", .{v}),
                .i32 => |v| try w.print("{d}", .{v}),
                .u32 => |v| try w.print("{d}", .{v}),
                .bool => |v| try w.print("{}", .{v}),
                .str => |v| try w.print("\"{f}\"", .{std.zig.fmtString(v)}),
                .vec2 => |v| try w.print(".{{ .x = {d}, .y = {d} }}", .{ v.x, v.y }),
                .entity => |v| try w.print("{d}", .{v}),
            }
            try w.writeAll(",\n");
        }
        try w.writeAll("};\n\n");
    }
}

// ── Collision gate ───────────────────────────────────────────────────

/// Reject a declared component whose registry name is already taken —
/// by the built-in `VideoComponent`, a game `components/*.zig`, or a
/// pack's namespaced `<pack>__<Pascal>` field. The error names BOTH
/// providers so the author knows which line to change. (Names come from
/// the same derivations `writeComponentRegistryBlock` emits, so the check
/// matches the generated field set exactly.)
pub fn checkCollisions(
    declared: []const DeclaredComponent,
    component_names: []const []const u8,
    pack_scans: []const scan.PackScan,
) !void {
    var pascal_buf: [128]u8 = undefined;
    var pack_pascal_buf: [128]u8 = undefined;
    var prefix_buf: [128]u8 = undefined;
    var full_buf: [280]u8 = undefined;

    for (declared) |comp| {
        if (std.mem.eql(u8, comp.name, "VideoComponent")) {
            diag("script-declared component 'VideoComponent' collides with the built-in engine VideoComponent — pick another name", .{});
            return error.ScriptComponentCollision;
        }
        for (component_names) |name| {
            const pascal = idents.pathToPascal(name, &pascal_buf);
            if (std.mem.eql(u8, pascal, comp.name)) {
                diag("script-declared component '{s}' collides with the game component components/{s}.zig — rename one (script declarations and components/ share one registry namespace)", .{ comp.name, name });
                return error.ScriptComponentCollision;
            }
        }
        for (pack_scans) |pack| {
            const prefix = scan.packNamespacePrefix(pack.name, &prefix_buf);
            for (pack.component_names) |name| {
                const pascal = idents.pathToPascal(name, &pack_pascal_buf);
                const full = std.fmt.bufPrint(&full_buf, "{s}__{s}", .{ prefix, pascal }) catch continue;
                if (std.mem.eql(u8, full, comp.name)) {
                    diag("script-declared component '{s}' collides with pack '{s}' component {s}.zig — rename one", .{ comp.name, pack.name, name });
                    return error.ScriptComponentCollision;
                }
            }
        }
    }
}

// ── The exec slice ───────────────────────────────────────────────────

/// Resolve (building if needed) the declare tool for the scripting plugin
/// package at `pkg_dir`, installing under `<output_dir>/declare-tool/`.
/// Returns a path valid for the rest of the process (override, or the
/// threadlocal cache buffer). See the module doc's exec-slice section for
/// the build+cache mechanics.
fn ensureDeclareTool(allocator: std.mem.Allocator, pkg_dir: []const u8, output_dir: []const u8) ![]const u8 {
    if (declare_tool_override) |p| return p;

    if (cached_tool_len > 0 and
        std.mem.eql(u8, cached_pkg[0..cached_pkg_len], pkg_dir) and
        cache.dirExists(cached_tool[0..cached_tool_len]))
    {
        return cached_tool[0..cached_tool_len];
    }

    // Cache dir + install prefix OUTSIDE the (wiped-per-generate) deps
    // copy — this is what makes re-generates warm; see the module doc.
    const prefix = try std.fs.path.join(allocator, &.{ output_dir, "declare-tool" });
    defer allocator.free(prefix);
    const zig_cache = try std.fs.path.join(allocator, &.{ prefix, "zig-cache" });
    defer allocator.free(zig_cache);

    const io = config.globalIo();
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "zig", "build", "labelle-declare", "--cache-dir", zig_cache, "--prefix", prefix },
        .cwd = .{ .path = pkg_dir },
    }) catch |err| {
        diag("could not run `zig build labelle-declare` in {s}: {s}", .{ pkg_dir, @errorName(err) });
        return error.DeclareToolBuildFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            relayChildStderr(result.stderr);
            diag("`zig build labelle-declare` failed (exit {d}) in {s}", .{ code, pkg_dir });
            return error.DeclareToolBuildFailed;
        },
        else => {
            relayChildStderr(result.stderr);
            diag("`zig build labelle-declare` terminated abnormally in {s}", .{pkg_dir});
            return error.DeclareToolBuildFailed;
        },
    }

    const exe_name = if (builtin.os.tag == .windows) "labelle-declare.exe" else "labelle-declare";
    const tool_path = try std.fs.path.join(allocator, &.{ prefix, "bin", exe_name });
    defer allocator.free(tool_path);
    if (!cache.dirExists(tool_path)) {
        diag("`zig build labelle-declare` succeeded but {s} is missing", .{tool_path});
        return error.DeclareToolBuildFailed;
    }
    if (pkg_dir.len > cached_pkg.len or tool_path.len > cached_tool.len)
        return error.NameTooLong;
    @memcpy(cached_pkg[0..pkg_dir.len], pkg_dir);
    cached_pkg_len = pkg_dir.len;
    @memcpy(cached_tool[0..tool_path.len], tool_path);
    cached_tool_len = tool_path.len;
    return cached_tool[0..cached_tool_len];
}

/// Locate the scripting plugin package to build the tool from: the staged
/// `<output>/deps/labelle-<name>/` copy (the exact package the game
/// builds against), falling back to the cache/local resolution when deps
/// staging fell back. Caller frees.
fn resolvePluginPackageDir(
    allocator: std.mem.Allocator,
    plugins: []const config.PluginDep,
    plugin_name: []const u8,
    output_dir: []const u8,
    project_dir: []const u8,
) ![]const u8 {
    var link_buf: [256]u8 = undefined;
    const link_name = std.fmt.bufPrint(&link_buf, "labelle-{s}", .{plugin_name}) catch
        return error.NameTooLong;
    const staged = try std.fs.path.join(allocator, &.{ output_dir, "deps", link_name });
    if (cache.dirExists(staged)) return staged;
    allocator.free(staged);

    for (plugins) |plugin| {
        if (std.mem.eql(u8, plugin.name, plugin_name))
            return cache.resolvePlugin(allocator, plugin, project_dir);
    }
    diag("scripting plugin '{s}' not found among the project's plugins", .{plugin_name});
    return error.DeclareToolBuildFailed;
}

/// Exec the declare tool over the copied `<language>/` scripts and parse
/// its stdout as the schema. A nonzero exit relays the tool's stderr (the
/// file-and-name-bearing declaration error) and fails generation.
fn runDeclareTool(
    allocator: std.mem.Allocator,
    tool_path: []const u8,
    target_dir: []const u8,
    language: []const u8,
    extension: []const u8,
    script_names: []const []const u8,
) !Schema {
    var argv: std.ArrayList([]const u8) = .empty;
    defer {
        // argv[0] is borrowed (tool_path); the script paths are owned. The
        // len guard covers the ensureTotalCapacity-failed path (empty list).
        if (argv.items.len > 0) for (argv.items[1..]) |p| allocator.free(p);
        argv.deinit(allocator);
    }
    try argv.ensureTotalCapacity(allocator, script_names.len + 1);
    argv.appendAssumeCapacity(tool_path);
    for (script_names) |stem| {
        var name_buf: [512]u8 = undefined;
        const file_name = std.fmt.bufPrint(&name_buf, "{s}{s}", .{ stem, extension }) catch
            return error.NameTooLong;
        const p = try std.fs.path.join(allocator, &.{ target_dir, language, file_name });
        argv.appendAssumeCapacity(p);
    }

    const io = config.globalIo();
    const result = std.process.run(allocator, io, .{ .argv = argv.items }) catch |err| {
        diag("could not run the declare tool {s}: {s}", .{ tool_path, @errorName(err) });
        return error.ScriptDeclarationFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            relayChildStderr(result.stderr);
            diag("script component declarations failed (declare tool exit {d})", .{code});
            return error.ScriptDeclarationFailed;
        },
        else => {
            relayChildStderr(result.stderr);
            diag("the declare tool terminated abnormally", .{});
            return error.ScriptDeclarationFailed;
        },
    }

    return parseSchema(allocator, result.stdout);
}

// ── Phase orchestration (called from root.zig's generate) ────────────

pub const PhaseOptions = struct {
    plugins: []const config.PluginDep,
    plugin_name: []const u8,
    language: []const u8,
    extension: []const u8,
    script_names: []const []const u8,
    output_dir: []const u8,
    target_dir: []const u8,
    project_dir: []const u8,
    /// Game-root component stems (collision gate).
    component_names: []const []const u8,
    /// Pack scans (collision gate against `<pack>__<Pascal>` fields).
    pack_scans: []const scan.PackScan,
};

/// Run the whole declare phase for an active scripting splice: build (or
/// reuse) the runner, extract the schema, gate collisions, and write the
/// generated `scripting_components.zig` into the target. Returns the
/// owned Schema when at least one component was declared (the caller
/// threads `schema.components` onto the splice and keeps the Schema alive
/// through main.zig emission), null for both no-op shapes (no scripts at
/// all; scripts but no declarations). Both no-op shapes also delete a
/// stale generated file left by a previously-declaring project state.
pub fn runPhase(allocator: std.mem.Allocator, opts: PhaseOptions) !?Schema {
    if (opts.script_names.len == 0) {
        removeStaleGeneratedFile(allocator, opts.target_dir);
        return null;
    }

    const pkg_dir = try resolvePluginPackageDir(
        allocator,
        opts.plugins,
        opts.plugin_name,
        opts.output_dir,
        opts.project_dir,
    );
    defer allocator.free(pkg_dir);

    const tool_path = try ensureDeclareTool(allocator, pkg_dir, opts.output_dir);
    var schema = try runDeclareTool(
        allocator,
        tool_path,
        opts.target_dir,
        opts.language,
        opts.extension,
        opts.script_names,
    );
    errdefer schema.deinit();

    if (schema.components.len == 0) {
        schema.deinit();
        removeStaleGeneratedFile(allocator, opts.target_dir);
        return null;
    }

    try checkCollisions(schema.components, opts.component_names, opts.pack_scans);

    var rendered: std.Io.Writer.Allocating = .init(allocator);
    defer rendered.deinit();
    try renderComponentsFile(schema.components, &rendered.writer);
    try scanner.writeFile(opts.target_dir, GENERATED_FILENAME, rendered.writer.buffered());

    return schema;
}

/// Best-effort cleanup of a stale `scripting_components.zig` (a project
/// whose declarations were all removed): nothing imports it anymore, but
/// a lingering generated file misleads readers of the target dir.
fn removeStaleGeneratedFile(allocator: std.mem.Allocator, target_dir: []const u8) void {
    const io = config.globalIo();
    const path = std.fs.path.join(allocator, &.{ target_dir, GENERATED_FILENAME }) catch return;
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// The pinned example schema from the ticket (whitespace-insensitive JSON).
const example_schema =
    \\{ "components": [ { "name": "Hunger", "persist": "persistent",
    \\    "fields": [ {"name":"level","type":"f32","default":1.0},
    \\                {"name":"starving","type":"bool","default":false} ] } ] }
;

test "parseSchema: the ticket's example parses into the typed model" {
    var schema = try parseSchema(testing.allocator, example_schema);
    defer schema.deinit();
    try testing.expectEqual(@as(usize, 1), schema.components.len);
    const comp = schema.components[0];
    try testing.expectEqualStrings("Hunger", comp.name);
    try testing.expectEqual(Persist.persistent, comp.persist);
    try testing.expectEqual(@as(usize, 2), comp.fields.len);
    try testing.expectEqualStrings("level", comp.fields[0].name);
    try testing.expectEqual(@as(f64, 1.0), comp.fields[0].default.f32);
    try testing.expectEqualStrings("starving", comp.fields[1].name);
    try testing.expectEqual(false, comp.fields[1].default.bool);
}

test "parseSchema: persist defaults to persistent; transient parses; every v1 type lands" {
    var schema = try parseSchema(testing.allocator,
        \\{"components":[{"name":"Kitchen","persist":"transient","fields":[
        \\  {"name":"heat","type":"u32","default":7},
        \\  {"name":"owner","type":"entity","default":0},
        \\  {"name":"pos","type":"vec2","default":{"x":4.0,"y":-2}},
        \\  {"name":"label","type":"str","default":"a\"b"},
        \\  {"name":"n","type":"i32","default":-3}
        \\]},{"name":"Marker","fields":[]}]}
    );
    defer schema.deinit();
    try testing.expectEqual(@as(usize, 2), schema.components.len);
    const kitchen = schema.components[0];
    try testing.expectEqual(Persist.transient, kitchen.persist);
    try testing.expectEqual(@as(u32, 7), kitchen.fields[0].default.u32);
    try testing.expectEqual(@as(u64, 0), kitchen.fields[1].default.entity);
    try testing.expectEqual(@as(f64, 4.0), kitchen.fields[2].default.vec2.x);
    try testing.expectEqual(@as(f64, -2.0), kitchen.fields[2].default.vec2.y);
    try testing.expectEqualStrings("a\"b", kitchen.fields[3].default.str);
    try testing.expectEqual(@as(i32, -3), kitchen.fields[4].default.i32);
    // Field-less + persist-less component: the schema default.
    try testing.expectEqual(Persist.persistent, schema.components[1].persist);
    try testing.expectEqual(@as(usize, 0), schema.components[1].fields.len);
}

test "parseSchema: enums (and any unknown type) are rejected LOUDLY, not guessed" {
    try testing.expectError(error.ScriptSchemaInvalid, parseSchema(testing.allocator,
        \\{"components":[{"name":"Mood","fields":[{"name":"state","type":"enum","default":"happy"}]}]}
    ));
    try testing.expectError(error.ScriptSchemaInvalid, parseSchema(testing.allocator,
        \\{"components":[{"name":"Mood","fields":[{"name":"state","type":"f64","default":1}]}]}
    ));
}

test "parseSchema: malformed documents reject (bad JSON, bad names, ranges, duplicates, reserved Vec2)" {
    const bad_cases = [_][]const u8{
        "not json at all",
        \\{"components":[{"name":"","fields":[]}]}
        ,
        \\{"components":[{"name":"Has Space","fields":[]}]}
        ,
        \\{"components":[{"name":"Vec2","fields":[]}]}
        ,
        \\{"components":[{"name":"A","fields":[]},{"name":"A","fields":[]}]}
        ,
        \\{"components":[{"name":"A","fields":[{"name":"x","type":"i32","default":1},{"name":"x","type":"i32","default":2}]}]}
        ,
        \\{"components":[{"name":"A","persist":"forever","fields":[]}]}
        ,
        \\{"components":[{"name":"A","fields":[{"name":"n","type":"i32","default":3000000000}]}]}
        ,
        \\{"components":[{"name":"A","fields":[{"name":"n","type":"u32","default":-1}]}]}
        ,
        \\{"components":[{"name":"A","fields":[{"name":"n","type":"i32"}]}]}
        ,
        \\{"components":[{"name":"A","fields":[{"name":"p","type":"vec2","default":{"x":1}}]}]}
        ,
    };
    for (bad_cases) |case| {
        try testing.expectError(error.ScriptSchemaInvalid, parseSchema(testing.allocator, case));
    }
}

test "parseSchema: reserved names reject — keyword/primitive fields, the generated `save` decl, keyword/primitive components" {
    // Every name below passes the char-class identifier check yet is
    // reserved (PR #598 finding 1): keywords break generated code in any
    // position, primitives break decl position (`pub const type = struct`
    // is "name shadows primitive") and are reserved for fields too, and
    // `save` collides with the decl every generated struct carries.
    const reserved_cases = [_][]const u8{
        // Field named the `type` primitive.
        \\{"components":[{"name":"A","fields":[{"name":"type","type":"f32","default":0}]}]}
        ,
        // Fields named Zig keywords → `error: i32 = 0,` is a parse error.
        \\{"components":[{"name":"A","fields":[{"name":"error","type":"i32","default":0}]}]}
        ,
        \\{"components":[{"name":"A","fields":[{"name":"align","type":"u32","default":0}]}]}
        ,
        // Field named `save` → collides with the generated Saveable decl.
        \\{"components":[{"name":"A","fields":[{"name":"save","type":"bool","default":false}]}]}
        ,
        // Component named the `type` primitive → "name shadows primitive".
        \\{"components":[{"name":"type","fields":[]}]}
        ,
        // Component named a Zig keyword → `pub const error = struct` fails.
        \\{"components":[{"name":"error","fields":[]}]}
        ,
        // `_` is the discard token, not an identifier — component or field.
        \\{"components":[{"name":"_","fields":[]}]}
        ,
        \\{"components":[{"name":"A","fields":[{"name":"_","type":"f32","default":0}]}]}
        ,
    };
    for (reserved_cases) |case| {
        try testing.expectError(error.ScriptSchemaInvalid, parseSchema(testing.allocator, case));
    }
    // The gate is exact — a name merely CONTAINING a keyword still passes.
    var schema = try parseSchema(testing.allocator,
        \\{"components":[{"name":"ErrorLog","fields":[{"name":"save_count","type":"u32","default":0},{"name":"type_name","type":"str","default":""}]}]}
    );
    schema.deinit();
}

/// Render `components` into a caller-freed buffer.
fn renderForTest(components: []const DeclaredComponent) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try renderComponentsFile(components, &aw.writer);
    var arr = aw.toArrayList();
    errdefer arr.deinit(testing.allocator);
    return arr.toOwnedSlice(testing.allocator);
}

/// Run Zig's front-end (parse → AstGen) over `src` and fail on any parse
/// or AstGen-level compile error — the same gate `main_template.zig` uses
/// (imports stay unresolved, so no engine/core checkout is needed).
fn expectAstGenOk(src: []const u8) !void {
    const src_z = try testing.allocator.dupeZ(u8, src);
    defer testing.allocator.free(src_z);
    var ast = try std.zig.Ast.parse(testing.allocator, src_z, .zig);
    defer ast.deinit(testing.allocator);
    if (ast.errors.len != 0) {
        std.debug.print("expectAstGenOk: {d} parse error(s)\n", .{ast.errors.len});
        return error.AstGenParseError;
    }
    var zir = try std.zig.AstGen.generate(testing.allocator, ast);
    defer zir.deinit(testing.allocator);
    if (zir.hasCompileErrors()) {
        std.debug.print("expectAstGenOk: AstGen reported compile errors\n", .{});
        return error.AstGenCompileError;
    }
}

test "renderComponentsFile: schema → struct golden (canonical Saveable shape) + AstGen" {
    var schema = try parseSchema(testing.allocator, example_schema);
    defer schema.deinit();
    const got = try renderForTest(schema.components);
    defer testing.allocator.free(got);

    const golden =
        "pub const Hunger = struct {\n" ++
        "    pub const save = @import(\"labelle-core\").Saveable(.saveable, @This(), .{});\n" ++
        "\n" ++
        "    level: f32 = 1,\n" ++
        "    starving: bool = false,\n" ++
        "};\n\n";
    try testing.expect(std.mem.endsWith(u8, got, golden));
    // No vec2 fields → no Vec2 backing decl.
    try testing.expect(std.mem.indexOf(u8, got, "Vec2") == null);
    try expectAstGenOk(got);
}

test "renderComponentsFile: transient policy, entity_refs, str escaping, vec2 backing decl + AstGen" {
    var schema = try parseSchema(testing.allocator,
        \\{"components":[
        \\ {"name":"Assignment","persist":"transient","fields":[
        \\   {"name":"worker","type":"entity","default":0},
        \\   {"name":"station","type":"entity","default":0},
        \\   {"name":"label","type":"str","default":"a\"b\\c"},
        \\   {"name":"spot","type":"vec2","default":{"x":1.5,"y":-2}},
        \\   {"name":"slots","type":"u32","default":4}]},
        \\ {"name":"Dead","persist":"transient","fields":[]}
        \\]}
    );
    defer schema.deinit();
    const got = try renderForTest(schema.components);
    defer testing.allocator.free(got);

    // Policy + the core Stored idiom: entity fields are u64 ids listed in
    // .entity_refs (field order preserved).
    try testing.expect(std.mem.indexOf(u8, got, "    pub const save = @import(\"labelle-core\").Saveable(.transient, @This(), .{\n" ++
        "        .entity_refs = &.{\"worker\", \"station\"},\n" ++
        "    });\n") != null);
    try testing.expect(std.mem.indexOf(u8, got, "    worker: u64 = 0,\n") != null);
    // str defaults escape as Zig string literals.
    try testing.expect(std.mem.indexOf(u8, got, "    label: []const u8 = \"a\\\"b\\\\c\",\n") != null);
    // vec2 fields ride the emitted-once backing struct.
    try testing.expect(std.mem.indexOf(u8, got, "pub const Vec2 = struct { x: f32 = 0, y: f32 = 0 };") != null);
    try testing.expect(std.mem.indexOf(u8, got, "    spot: Vec2 = .{ .x = 1.5, .y = -2 },\n") != null);
    try testing.expect(std.mem.indexOf(u8, got, "    slots: u32 = 4,\n") != null);
    // Zero-field marker still carries its Saveable decl.
    try testing.expect(std.mem.indexOf(u8, got, "pub const Dead = struct {\n" ++
        "    pub const save = @import(\"labelle-core\").Saveable(.transient, @This(), .{});\n" ++
        "};\n") != null);
    try expectAstGenOk(got);
}

test "checkCollisions: game components, packs, and the VideoComponent built-in all gate" {
    const declared = [_]DeclaredComponent{
        .{ .name = "Hunger", .persist = .persistent, .fields = &.{} },
    };
    // Clean set: no collision.
    try checkCollisions(&declared, &.{ "worker", "room_state" }, &.{});
    // Game component with the same Pascal name (components/hunger.zig).
    try testing.expectError(
        error.ScriptComponentCollision,
        checkCollisions(&declared, &.{"hunger"}, &.{}),
    );
    // Built-in.
    const video = [_]DeclaredComponent{
        .{ .name = "VideoComponent", .persist = .persistent, .fields = &.{} },
    };
    try testing.expectError(error.ScriptComponentCollision, checkCollisions(&video, &.{}, &.{}));
    // Pack-namespaced field: citizens pack's counter.zig → citizens__Counter.
    const packish = [_]DeclaredComponent{
        .{ .name = "citizens__Counter", .persist = .persistent, .fields = &.{} },
    };
    const pack = scan.PackScan{
        .name = "citizens",
        .import_prefix = "packs/citizens",
        .component_names = &.{"counter"},
        .event_names = &.{},
        .prefab_names = &.{},
    };
    try testing.expectError(
        error.ScriptComponentCollision,
        checkCollisions(&packish, &.{}, &.{pack}),
    );
}
