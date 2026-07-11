//! Schema-declared plugin parameters (labelle-assembler#591, epic
//! labelle-engine#237, RFC #730 rev 13).
//!
//! Plugin-specific options never become bespoke `PluginDep` fields — they
//! ride the generic `.params` bag on the `project.labelle` plugin entry:
//!
//!     .plugins = .{
//!         .{ .name = "scripting", .repo = "…", .version = "…",
//!            .params = .{ .language = "lua" } },
//!         .{ .name = "pathfinder", .repo = "…", .version = "…",
//!            .params = .{ .grid_size = 32 } },
//!     },
//!
//! This module owns the FULL mechanism, in four layers:
//!
//!   1. **Project-side parse** (`parseProjectConfig`): the `.params` keys are
//!      OPEN (each plugin publishes its own), so a closed typed struct can't
//!      parse them. The bag is extracted with a Zoir walk of the ZON source
//!      into dynamic `config.Param` values (str/i64/f64/bool), the literal is
//!      blanked to `null` IN PLACE (offsets preserved, so every other field's
//!      diagnostics stay put), the sanitized source rides the exact same
//!      typed `std.zon.parse` path as before, and the extracted bags are
//!      re-attached to the parsed `cfg.plugins`. A source that never spells
//!      `.params` takes the untouched fast path — byte-identical behavior.
//!
//!   2. **Schema declaration** (`ParamSchema`, validated by
//!      `validateSchema` at `plugin.labelle` load): the plugin publishes the
//!      params it accepts — name, type (`.str/.i64/.f64/.bool/.@"enum"` with
//!      `.values`), `default`, `required`.
//!
//!   3. **Generate-time validation + resolution** (`validateAndResolve`,
//!      orchestrated by `generate_phases.resolvePluginParams`): the project's
//!      declared bag is checked against the attached plugin's schema —
//!      unknown key, wrong type, out-of-vocabulary enum value, and missing
//!      required param are actionable errors naming plugin + param. The
//!      resolved set = project values + schema defaults.
//!
//!   4. **Comptime delivery** (`renderParamsModule` + the build.zig wiring in
//!      `build_files/build_zig.zig`): the resolved params are generated into
//!      a per-plugin `plugin_<name>_params.zig` module of `pub const` decls,
//!      injected into the plugin's module via the existing `overrideImport`
//!      machinery as `@import("plugin_config")` — zero runtime cost.
//!
//! Params-less plugins are byte-identical everywhere: no schema → no module,
//! no wiring, no output drift.

const std = @import("std");
const config = @import("config.zig");
const idents = @import("codegen/idents.zig");

const Zoir = std.zig.Zoir;

/// The import name a plugin reads its resolved params under:
/// `@import("plugin_config")`. Fixed across all plugins — each plugin module
/// gets its OWN generated module wired under this one name.
pub const PLUGIN_CONFIG_IMPORT = "plugin_config";

// ════════════════════════════════════════════════════════════════════════
// Layer 2 — schema declaration (plugin.labelle `.params`)
// ════════════════════════════════════════════════════════════════════════

/// The type vocabulary a plugin schema can declare for one parameter
/// (issue #591: `str/i64/f64/bool` + enums with allowed values). Spelled in
/// `plugin.labelle` as `.type = .str / .i64 / .f64 / .bool / .@"enum"`.
pub const ParamType = enum { str, @"i64", @"f64", bool, @"enum" };

/// One declared parameter in a plugin's `plugin.labelle` `.params` schema:
///
///     .params = .{
///         .{ .name = "language", .type = .@"enum",
///            .values = .{ "lua", "typescript" }, .required = true },
///         .{ .name = "grid_size", .type = .i64, .default = .{ .i64 = 32 } },
///     },
pub const ParamSchema = struct {
    /// Parameter name. Becomes a `pub const` in the generated per-plugin
    /// config module, so it must be a valid Zig identifier.
    name: []const u8,
    /// Value type the project must supply. `.@"enum"` values are spelled as
    /// strings in `project.labelle` and validated against `.values`.
    type: ParamType,
    /// When true, the project MUST set this param — generate fails otherwise.
    /// Mutually exclusive with `default` (a required param with a fallback is
    /// a contradiction; the schema is rejected at load).
    required: bool = false,
    /// Allowed values for `.type = .@"enum"` (must be non-empty there,
    /// and absent everywhere else).
    values: []const []const u8 = &.{},
    /// Fallback used when the project doesn't set the param. The union tag
    /// must match `.type` (enum defaults ride `.str` and must be a `.values`
    /// member). Optional params with NO default are simply omitted from the
    /// generated module — plugin code discovers them via `@hasDecl`.
    default: ?config.ParamValue = null,
};

/// Validate a plugin's declared `.params` schema at `plugin.labelle` load
/// time (called from `plugin_manifest/plugin.zig::loadFromDir`). Rejects, with
/// a diagnostic naming the plugin and the offending entry:
///   - a `name` that is not a valid Zig identifier (it becomes a `pub const`
///     in the generated config module),
///   - duplicate `name`s,
///   - `.@"enum"` without `.values` / `.values` on a non-enum type,
///   - a `default` whose union tag doesn't match `.type`,
///   - an enum `default` outside `.values`,
///   - `required = true` combined with a `default`.
pub fn validateSchema(plugin_name: []const u8, schema: []const ParamSchema) error{PluginManifestInvalidParams}!void {
    for (schema, 0..) |p, i| {
        if (!idents.isValidZigIdentifier(p.name)) {
            std.debug.print(
                "labelle: plugin '{s}' declares param '{s}', which is not a valid identifier\n  param names become `pub const` decls in the generated plugin_config module\n",
                .{ plugin_name, p.name },
            );
            return error.PluginManifestInvalidParams;
        }
        for (schema[0..i]) |prev| {
            if (std.mem.eql(u8, prev.name, p.name)) {
                std.debug.print(
                    "labelle: plugin '{s}' declares param '{s}' twice in its .params schema\n",
                    .{ plugin_name, p.name },
                );
                return error.PluginManifestInvalidParams;
            }
        }
        if (p.type == .@"enum") {
            if (p.values.len == 0) {
                std.debug.print(
                    "labelle: plugin '{s}' param '{s}' has .type = .@\"enum\" but no .values\n  enum params must list their allowed values, e.g. .values = .{{ \"lua\", \"typescript\" }}\n",
                    .{ plugin_name, p.name },
                );
                return error.PluginManifestInvalidParams;
            }
        } else if (p.values.len != 0) {
            std.debug.print(
                "labelle: plugin '{s}' param '{s}' sets .values but .type = .{s}\n  .values is only valid on .type = .@\"enum\" params\n",
                .{ plugin_name, p.name, @tagName(p.type) },
            );
            return error.PluginManifestInvalidParams;
        }
        if (p.default) |d| {
            if (p.required) {
                std.debug.print(
                    "labelle: plugin '{s}' param '{s}' is required AND has a default — pick one\n",
                    .{ plugin_name, p.name },
                );
                return error.PluginManifestInvalidParams;
            }
            if (!defaultMatchesType(d, p.type)) {
                std.debug.print(
                    "labelle: plugin '{s}' param '{s}' declares .type = .{s} but its default is .{s}\n",
                    .{ plugin_name, p.name, @tagName(p.type), @tagName(d) },
                );
                return error.PluginManifestInvalidParams;
            }
            if (p.type == .@"enum" and !stringInList(d.str, p.values)) {
                std.debug.print(
                    "labelle: plugin '{s}' param '{s}' default \"{s}\" is not one of its .values\n",
                    .{ plugin_name, p.name, d.str },
                );
                return error.PluginManifestInvalidParams;
            }
        }
    }
}

fn defaultMatchesType(d: config.ParamValue, t: ParamType) bool {
    return switch (t) {
        .str, .@"enum" => d == .str,
        .@"i64" => d == .i64,
        .@"f64" => d == .f64,
        .bool => d == .bool,
    };
}

fn stringInList(needle: []const u8, list: []const []const u8) bool {
    for (list) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

// ════════════════════════════════════════════════════════════════════════
// Layer 1 — project-side parse (the open `.params` bag)
// ════════════════════════════════════════════════════════════════════════

/// Parse `project.labelle` source, handling the OPEN `.params` bags on
/// `.plugins` entries that the closed typed struct cannot represent.
///
/// Drop-in replacement for
/// `std.zon.parse.fromSliceAlloc(config.ProjectConfig, …)`: every other
/// field parses through the exact same typed path with the same
/// unknown-field strictness. A source that never spells `.params` takes an
/// untouched fast path. Attached bags land on `cfg.plugins[i].params` as
/// dynamic `config.Param` values.
///
/// ARENA-ONLY, like the plain typed parse it wraps: `ProjectConfig` carries
/// comptime-default slice fields (e.g. `.layers`) that `std.zon.parse.free`
/// chokes on (the pre-existing caveat every parse call site documents), so
/// parse into an arena. Every allocation here — including the attached
/// params — is made with `gpa`, so the arena reclaims everything.
pub fn parseProjectConfig(gpa: std.mem.Allocator, source: [:0]const u8) !config.ProjectConfig {
    // The typed ProjectConfig parse is comptime-heavy (same quota the parse
    // call sites always carried).
    @setEvalBranchQuota(10000);
    // Fast path: no `.params` anywhere in the source → the plain typed parse,
    // byte-identical behavior for every pre-#591 project.
    if (std.mem.indexOf(u8, source, ".params") == null) {
        return std.zon.parse.fromSliceAlloc(config.ProjectConfig, gpa, source, null, .{});
    }

    var extraction = try extractPluginParams(gpa, source);
    defer extraction.deinit(gpa);

    const parse_source: [:0]const u8 = extraction.sanitized orelse source;
    var cfg = try std.zon.parse.fromSliceAlloc(config.ProjectConfig, gpa, parse_source, null, .{});
    errdefer std.zon.parse.free(gpa, cfg);

    if (extraction.per_entry.len > 0) {
        // The walk iterated the same `.plugins` array literal the typed parse
        // consumed, so the counts always agree; keep the skew loud regardless.
        if (cfg.plugins.len != extraction.per_entry.len) return error.PluginParamsSkew;
        const plugins = try gpa.dupe(config.PluginDep, cfg.plugins);
        // Shallow container swap — the entries' strings moved into `plugins`.
        gpa.free(cfg.plugins);
        cfg.plugins = plugins;
        for (extraction.per_entry, plugins) |*maybe, *p| {
            if (maybe.*) |params| {
                p.params = params;
                maybe.* = null; // ownership moved into cfg
            }
        }
    }
    return cfg;
}

/// Result of the Zoir walk over one project.labelle source: the sanitized
/// copy (non-empty `.params` literals blanked to `null`, offsets preserved)
/// plus the extracted bag per `.plugins` entry, index-aligned.
const Extraction = struct {
    sanitized: ?[:0]u8 = null,
    per_entry: []?[]config.Param = &.{},

    fn deinit(self: *Extraction, gpa: std.mem.Allocator) void {
        if (self.sanitized) |s| gpa.free(s);
        for (self.per_entry) |maybe| {
            if (maybe) |params| freeParams(gpa, params);
        }
        gpa.free(self.per_entry);
    }
};

/// Free a `[]config.Param` slice allocated by this module (names and string
/// values are owned dupes).
pub fn freeParams(gpa: std.mem.Allocator, params: []const config.Param) void {
    for (params) |p| {
        gpa.free(p.name);
        switch (p.value) {
            .str => |s| gpa.free(s),
            else => {},
        }
    }
    gpa.free(params);
}

/// Walk the ZON source for `.plugins[i].params` literals. Returns an empty
/// extraction (nothing sanitized, no entries) whenever the source doesn't
/// parse or has no plugins list — the typed parse right after owns ALL
/// diagnostics for malformed ZON, so this walk never duplicates them.
fn extractPluginParams(gpa: std.mem.Allocator, source: [:0]const u8) !Extraction {
    var ast = try std.zig.Ast.parse(gpa, source, .zon);
    defer ast.deinit(gpa);
    var zoir = try std.zig.ZonGen.generate(gpa, ast, .{});
    defer zoir.deinit(gpa);
    if (zoir.hasCompileErrors()) return .{};

    const root_fields = switch (Zoir.Node.Index.root.get(zoir)) {
        .struct_literal => |s| s,
        else => return .{},
    };
    const plugins_range: Zoir.Node.Index.Range = blk: {
        for (root_fields.names, 0..) |nm, i| {
            if (std.mem.eql(u8, nm.get(zoir), "plugins")) {
                switch (root_fields.vals.at(@intCast(i)).get(zoir)) {
                    .array_literal => |r| break :blk r,
                    else => return .{}, // `.plugins = .{}` or malformed — nothing to extract
                }
            }
        }
        return .{};
    };

    var out = Extraction{
        .per_entry = try gpa.alloc(?[]config.Param, plugins_range.len),
    };
    for (out.per_entry) |*e| e.* = null;
    errdefer out.deinit(gpa);

    for (0..plugins_range.len) |i| {
        const entry_fields = switch (plugins_range.at(@intCast(i)).get(zoir)) {
            .struct_literal => |s| s,
            else => continue,
        };
        // Locate `.name` (for diagnostics) and `.params` on this entry.
        var entry_name: []const u8 = "<unnamed>";
        var params_field: ?u32 = null;
        for (entry_fields.names, 0..) |nm, j| {
            const nm_s = nm.get(zoir);
            if (std.mem.eql(u8, nm_s, "name")) {
                switch (entry_fields.vals.at(@intCast(j)).get(zoir)) {
                    .string_literal => |s| entry_name = s,
                    else => {},
                }
            } else if (std.mem.eql(u8, nm_s, "params")) {
                params_field = @intCast(j);
            }
        }
        const pj = params_field orelse continue;
        const params_node = entry_fields.vals.at(pj);
        switch (params_node.get(zoir)) {
            // `.params = .{}` — present-but-empty bag; the typed parse
            // already lands it on the empty slice, nothing to extract.
            .empty_literal => {},
            // `.params = null` — parses natively too.
            .null => {},
            .struct_literal => |bag| {
                out.per_entry[i] = try collectParams(gpa, zoir, bag, entry_name);
                if (out.sanitized == null) out.sanitized = try gpa.dupeZ(u8, source);
                blankNodeToNull(&ast, zoir, params_node, out.sanitized.?);
            },
            else => {
                std.debug.print(
                    "labelle-assembler: plugin '{s}': `.params` must be a struct literal like `.{{ .key = value }}`\n",
                    .{entry_name},
                );
                return error.InvalidPluginParams;
            },
        }
    }
    return out;
}

/// Convert one `.params = .{ … }` struct literal into owned dynamic values.
fn collectParams(
    gpa: std.mem.Allocator,
    zoir: Zoir,
    bag: anytype,
    plugin_label: []const u8,
) ![]config.Param {
    var out = try gpa.alloc(config.Param, bag.names.len);
    var count: usize = 0;
    errdefer freeParams(gpa, out[0..count]);

    for (bag.names, 0..) |nm, i| {
        const key = nm.get(zoir);
        const value: config.ParamValue = switch (bag.vals.at(@intCast(i)).get(zoir)) {
            .string_literal => |s| .{ .str = try gpa.dupe(u8, s) },
            // `.language = .lua` — an enum-literal spelling of an enum/str
            // param is accepted as its string form.
            .enum_literal => |s| .{ .str = try gpa.dupe(u8, s.get(zoir)) },
            .int_literal => |int| switch (int) {
                .small => |v| .{ .i64 = v },
                .big => |v| .{ .i64 = v.toInt(i64) catch {
                    std.debug.print(
                        "labelle-assembler: plugin '{s}': param '{s}' value does not fit in i64\n",
                        .{ plugin_label, key },
                    );
                    return error.InvalidPluginParams;
                } },
            },
            .float_literal => |f| .{ .f64 = @floatCast(f) },
            .true => .{ .bool = true },
            .false => .{ .bool = false },
            else => {
                std.debug.print(
                    "labelle-assembler: plugin '{s}': param '{s}' has an unsupported value\n  supported: string, integer, float, bool, enum literal\n",
                    .{ plugin_label, key },
                );
                return error.InvalidPluginParams;
            },
        };
        out[count] = .{ .name = try gpa.dupe(u8, key), .value = value };
        count += 1;
    }
    return out;
}

/// Blank the byte span of `node` in `buf` to `null` + trailing spaces, so
/// the sanitized source stays byte-length-identical (every other field's
/// parse diagnostics keep their exact locations) and the typed parse lands
/// this `.params` on its `null` default. The span of a non-empty struct
/// literal (`.{ .k = v }`) is always ≥ "null".len.
fn blankNodeToNull(ast: *const std.zig.Ast, zoir: Zoir, node: Zoir.Node.Index, buf: []u8) void {
    const ast_node = node.getAstNode(zoir);
    // NOT `nodeToSpan` — that helper collapses multi-line nodes onto the main
    // token's line. First-to-last token covers the full literal.
    const first = ast.firstToken(ast_node);
    const last = ast.lastToken(ast_node);
    const start = ast.tokenStart(first);
    const end = ast.tokenStart(last) + @as(u32, @intCast(ast.tokenSlice(last).len));
    std.debug.assert(end - start >= "null".len);
    @memset(buf[start..end], ' ');
    @memcpy(buf[start..][0.."null".len], "null");
}

// ════════════════════════════════════════════════════════════════════════
// Layer 3 — generate-time validation + resolution
// ════════════════════════════════════════════════════════════════════════

/// Validate one plugin's declared `.params` (from project.labelle) against
/// its schema (from plugin.labelle) and resolve the final param set —
/// project values first, schema defaults for the rest. Optional params with
/// neither a value nor a default are omitted (plugin code uses `@hasDecl`).
///
/// Every returned string is duped into `gpa` (the schema strings live in the
/// manifest's own allocation, which the caller frees before delivery); free
/// the result with `freeParams`.
///
/// Errors, each with an actionable diagnostic naming plugin + param:
///   - `error.PluginParamUnknown`       — a declared key the schema doesn't have
///   - `error.PluginParamTypeMismatch`  — value type ≠ schema type
///   - `error.PluginParamInvalidValue`  — enum value outside `.values`
///   - `error.PluginParamMissingRequired`
pub fn validateAndResolve(
    gpa: std.mem.Allocator,
    plugin_name: []const u8,
    declared: []const config.Param,
    schema: []const ParamSchema,
) ![]config.Param {
    // ── Validate every declared key against the schema ──
    for (declared) |d| {
        const entry: ParamSchema = blk: {
            for (schema) |s| {
                if (std.mem.eql(u8, s.name, d.name)) break :blk s;
            }
            std.debug.print(
                "labelle-assembler: plugin '{s}' does not accept param '{s}'.\n  declared params:",
                .{ plugin_name, d.name },
            );
            for (schema) |s| std.debug.print(" {s}", .{s.name});
            std.debug.print("\n  fix the `.params` entry in project.labelle.\n", .{});
            return error.PluginParamUnknown;
        };
        switch (entry.type) {
            .str => if (d.value != .str) return typeMismatch(plugin_name, d, "a string"),
            .@"enum" => {
                if (d.value != .str) return typeMismatch(plugin_name, d, "a string (enum value)");
                if (!stringInList(d.value.str, entry.values)) {
                    std.debug.print(
                        "labelle-assembler: plugin '{s}' param '{s}' = \"{s}\" is not an allowed value.\n  allowed:",
                        .{ plugin_name, d.name, d.value.str },
                    );
                    for (entry.values) |v| std.debug.print(" \"{s}\"", .{v});
                    std.debug.print("\n", .{});
                    return error.PluginParamInvalidValue;
                }
            },
            .@"i64" => if (d.value != .i64) return typeMismatch(plugin_name, d, "an integer"),
            // An integer literal is a fine f64 (`.speed = 2`).
            .@"f64" => if (d.value != .f64 and d.value != .i64) return typeMismatch(plugin_name, d, "a number"),
            .bool => if (d.value != .bool) return typeMismatch(plugin_name, d, "a bool"),
        }
    }

    // ── Resolve in schema order: project value, else default, else skip ──
    var out: std.ArrayList(config.Param) = .empty;
    errdefer {
        for (out.items) |p| {
            gpa.free(p.name);
            switch (p.value) {
                .str => |s| gpa.free(s),
                else => {},
            }
        }
        out.deinit(gpa);
    }
    for (schema) |s| {
        const value: config.ParamValue = blk: {
            for (declared) |d| {
                if (std.mem.eql(u8, d.name, s.name)) {
                    // Widen an integer literal onto an f64 param.
                    if (s.type == .@"f64" and d.value == .i64) {
                        break :blk .{ .f64 = @floatFromInt(d.value.i64) };
                    }
                    break :blk d.value;
                }
            }
            if (s.default) |dflt| break :blk dflt;
            if (s.required) {
                std.debug.print(
                    "labelle-assembler: plugin '{s}' requires param '{s}' ({s}) but project.labelle does not set it.\n  add it to the plugin entry: `.params = .{{ .{s} = … }}`\n",
                    .{ plugin_name, s.name, @tagName(s.type), s.name },
                );
                return error.PluginParamMissingRequired;
            }
            continue; // optional, no default → omitted from the module
        };
        const owned_value: config.ParamValue = switch (value) {
            .str => |str| .{ .str = try gpa.dupe(u8, str) },
            else => value,
        };
        errdefer switch (owned_value) {
            .str => |str| gpa.free(str),
            else => {},
        };
        try out.append(gpa, .{ .name = try gpa.dupe(u8, s.name), .value = owned_value });
    }
    return out.toOwnedSlice(gpa);
}

fn typeMismatch(plugin_name: []const u8, d: config.Param, expected: []const u8) error{PluginParamTypeMismatch} {
    std.debug.print(
        "labelle-assembler: plugin '{s}' param '{s}' must be {s}, got {s}.\n",
        .{ plugin_name, d.name, expected, @tagName(d.value) },
    );
    return error.PluginParamTypeMismatch;
}

// ════════════════════════════════════════════════════════════════════════
// Layer 4 — comptime delivery (the generated per-plugin config module)
// ════════════════════════════════════════════════════════════════════════

/// The staged filename for one plugin's generated params module, e.g.
/// `plugin_scripting_params.zig`. Caller frees.
pub fn paramsModuleFilename(gpa: std.mem.Allocator, plugin_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(gpa, "plugin_{s}_params.zig", .{plugin_name});
}

/// Render the generated `plugin_<name>_params.zig` module: one `pub const`
/// per resolved param, read by plugin code as `@import("plugin_config")`
/// comptime values. Strings (str + enum values) are `[]const u8`; a plugin
/// wanting a real enum does `std.meta.stringToEnum(...)` at comptime.
pub fn renderParamsModule(
    gpa: std.mem.Allocator,
    plugin_name: []const u8,
    resolved: []const config.Param,
) ![]const u8 {
    var alloc_writer: std.Io.Writer.Allocating = .init(gpa);
    errdefer alloc_writer.deinit();
    const w = &alloc_writer.writer;

    try w.print(
        "//! Generated by labelle-assembler — do not edit.\n" ++
            "//! Resolved `.params` for plugin '{s}' (schema: its plugin.labelle;\n" ++
            "//! values: project.labelle + schema defaults). Plugin code reads these\n" ++
            "//! as `@import(\"{s}\")` comptime values.\n\n",
        .{ plugin_name, PLUGIN_CONFIG_IMPORT },
    );
    for (resolved) |p| {
        switch (p.value) {
            .str => |s| {
                try w.print("pub const {s}: []const u8 = ", .{p.name});
                try idents.writeZigString(w, s);
                try w.writeAll(";\n");
            },
            .i64 => |v| try w.print("pub const {s}: i64 = {d};\n", .{ p.name, v }),
            .f64 => |v| try w.print("pub const {s}: f64 = {d};\n", .{ p.name, v }),
            .bool => |v| try w.print("pub const {s}: bool = {};\n", .{ p.name, v }),
        }
    }

    var arr_list = alloc_writer.toArrayList();
    return arr_list.toOwnedSlice(gpa);
}

// ════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════

const testing = std.testing;

// ── Layer 1: project-side parse ─────────────────────────────────────

test "parseProjectConfig: params-less source takes the fast path (byte-identical)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src: [:0]const u8 =
        \\.{
        \\    .name = "game",
        \\    .plugins = .{
        \\        .{ .name = "pathfinding", .version = "4.0.1" },
        \\    },
        \\}
    ;
    const cfg = try parseProjectConfig(arena.allocator(), src);
    try testing.expectEqualStrings("game", cfg.name);
    try testing.expectEqual(@as(usize, 1), cfg.plugins.len);
    try testing.expect(cfg.plugins[0].params == null);
}

test "parseProjectConfig: open `.params` bags parse into dynamic values (#591)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src: [:0]const u8 =
        \\.{
        \\    .name = "game",
        \\    .width = 640,
        \\    .plugins = .{
        \\        .{ .name = "scripting", .version = "0.1.0", .params = .{ .language = "lua" } },
        \\        .{ .name = "pathfinding", .version = "4.0.1" },
        \\        .{ .name = "pathfinder", .version = "1.0.0", .params = .{
        \\            .grid_size = 32,
        \\            .speed = 1.5,
        \\            .debug = true,
        \\            .mode = .grid,
        \\        } },
        \\    },
        \\}
    ;
    const cfg = try parseProjectConfig(arena.allocator(), src);
    // Every other field still parses through the typed path.
    try testing.expectEqualStrings("game", cfg.name);
    try testing.expectEqual(@as(u32, 640), cfg.width);
    try testing.expectEqual(@as(usize, 3), cfg.plugins.len);

    const scripting = cfg.plugins[0].params.?;
    try testing.expectEqual(@as(usize, 1), scripting.len);
    try testing.expectEqualStrings("language", scripting[0].name);
    try testing.expectEqualStrings("lua", scripting[0].value.str);

    try testing.expect(cfg.plugins[1].params == null);

    const pf = cfg.plugins[2].params.?;
    try testing.expectEqual(@as(usize, 4), pf.len);
    try testing.expectEqualStrings("grid_size", pf[0].name);
    try testing.expectEqual(@as(i64, 32), pf[0].value.i64);
    try testing.expectEqual(@as(f64, 1.5), pf[1].value.f64);
    try testing.expect(pf[2].value.bool);
    // Enum-literal spelling lands as its string form.
    try testing.expectEqualStrings("grid", pf[3].value.str);
}

test "parseProjectConfig: `.params = .{}` is a present-but-empty bag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src: [:0]const u8 =
        \\.{
        \\    .name = "game",
        \\    .plugins = .{
        \\        .{ .name = "scripting", .params = .{} },
        \\    },
        \\}
    ;
    const cfg = try parseProjectConfig(arena.allocator(), src);
    try testing.expect(cfg.plugins[0].params != null);
    try testing.expectEqual(@as(usize, 0), cfg.plugins[0].params.?.len);
}

test "parseProjectConfig: a typo'd field OUTSIDE `.params` is still a hard parse error" {
    // The sanitizer only touches `.params` literals; the typed parse keeps
    // its default `ignore_unknown_fields = false` strictness everywhere else.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src: [:0]const u8 =
        \\.{
        \\    .name = "game",
        \\    .plugins = .{
        \\        .{ .name = "scripting", .verison = "0.1.0", .params = .{ .language = "lua" } },
        \\    },
        \\}
    ;
    try testing.expectError(error.ParseZon, parseProjectConfig(arena.allocator(), src));
}

test "parseProjectConfig: an unsupported `.params` value shape errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const nested: [:0]const u8 =
        \\.{
        \\    .name = "game",
        \\    .plugins = .{
        \\        .{ .name = "p", .params = .{ .opts = .{ .nested = 1 } } },
        \\    },
        \\}
    ;
    try testing.expectError(error.InvalidPluginParams, parseProjectConfig(arena.allocator(), nested));

    const not_a_bag: [:0]const u8 =
        \\.{
        \\    .name = "game",
        \\    .plugins = .{
        \\        .{ .name = "p", .params = "lua" },
        \\    },
        \\}
    ;
    try testing.expectError(error.InvalidPluginParams, parseProjectConfig(arena.allocator(), not_a_bag));
}

test "parseProjectConfig: malformed ZON defers to the typed parse's diagnostics" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src: [:0]const u8 =
        \\.{
        \\    .name = "game"
        \\    .plugins = .{},
        \\}
    ;
    try testing.expectError(error.ParseZon, parseProjectConfig(arena.allocator(), src));
}

test "parseProjectConfig: multi-key bag parses in declaration order (leak-checked arena)" {
    // The arena wraps testing.allocator, so the test still leak-checks every
    // allocation the parse + extraction made.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src: [:0]const u8 =
        \\.{
        \\    .name = "game",
        \\    .plugins = .{
        \\        .{ .name = "scripting", .params = .{ .language = "lua", .heap_kb = 256 } },
        \\    },
        \\}
    ;
    const cfg = try parseProjectConfig(arena.allocator(), src);
    try testing.expectEqualStrings("lua", cfg.plugins[0].params.?[0].value.str);
    try testing.expectEqual(@as(i64, 256), cfg.plugins[0].params.?[1].value.i64);
}

// ── Layer 2: schema validation ──────────────────────────────────────

test "validateSchema: a well-formed schema passes" {
    try validateSchema("scripting", &.{
        .{ .name = "language", .type = .@"enum", .values = &.{ "lua", "typescript" }, .required = true },
        .{ .name = "grid_size", .type = .@"i64", .default = .{ .i64 = 32 } },
        .{ .name = "speed", .type = .@"f64" },
        .{ .name = "debug", .type = .bool, .default = .{ .bool = false } },
        .{ .name = "label", .type = .str },
    });
}

test "validateSchema: rejects malformed schemas with one error per rule" {
    // Not a valid identifier (becomes a `pub const`).
    try testing.expectError(error.PluginManifestInvalidParams, validateSchema("p", &.{
        .{ .name = "grid-size", .type = .@"i64" },
    }));
    // Duplicate name.
    try testing.expectError(error.PluginManifestInvalidParams, validateSchema("p", &.{
        .{ .name = "x", .type = .@"i64" },
        .{ .name = "x", .type = .str },
    }));
    // Enum without values.
    try testing.expectError(error.PluginManifestInvalidParams, validateSchema("p", &.{
        .{ .name = "mode", .type = .@"enum" },
    }));
    // Values on a non-enum.
    try testing.expectError(error.PluginManifestInvalidParams, validateSchema("p", &.{
        .{ .name = "x", .type = .@"i64", .values = &.{"a"} },
    }));
    // Default tag mismatch.
    try testing.expectError(error.PluginManifestInvalidParams, validateSchema("p", &.{
        .{ .name = "x", .type = .@"i64", .default = .{ .str = "32" } },
    }));
    // Enum default outside values.
    try testing.expectError(error.PluginManifestInvalidParams, validateSchema("p", &.{
        .{ .name = "mode", .type = .@"enum", .values = &.{"grid"}, .default = .{ .str = "mesh" } },
    }));
    // required + default contradiction.
    try testing.expectError(error.PluginManifestInvalidParams, validateSchema("p", &.{
        .{ .name = "x", .type = .@"i64", .required = true, .default = .{ .i64 = 1 } },
    }));
}

// ── Layer 3: validation + resolution ────────────────────────────────

const test_schema = [_]ParamSchema{
    .{ .name = "language", .type = .@"enum", .values = &.{ "lua", "typescript" }, .required = true },
    .{ .name = "grid_size", .type = .@"i64", .default = .{ .i64 = 32 } },
    .{ .name = "speed", .type = .@"f64" },
    .{ .name = "debug", .type = .bool, .default = .{ .bool = false } },
};

test "validateAndResolve: project values win, defaults fill, optional-no-default omitted" {
    const gpa = testing.allocator;
    const resolved = try validateAndResolve(gpa, "scripting", &.{
        .{ .name = "language", .value = .{ .str = "lua" } },
        .{ .name = "debug", .value = .{ .bool = true } },
    }, &test_schema);
    defer freeParams(gpa, resolved);

    try testing.expectEqual(@as(usize, 3), resolved.len);
    try testing.expectEqualStrings("language", resolved[0].name);
    try testing.expectEqualStrings("lua", resolved[0].value.str);
    try testing.expectEqualStrings("grid_size", resolved[1].name);
    try testing.expectEqual(@as(i64, 32), resolved[1].value.i64); // default
    // `speed` (optional, no default) is omitted — @hasDecl territory.
    try testing.expectEqualStrings("debug", resolved[2].name);
    try testing.expect(resolved[2].value.bool);
}

test "validateAndResolve: an integer literal widens onto an f64 param" {
    const gpa = testing.allocator;
    const resolved = try validateAndResolve(gpa, "p", &.{
        .{ .name = "language", .value = .{ .str = "lua" } },
        .{ .name = "speed", .value = .{ .i64 = 2 } },
    }, &test_schema);
    defer freeParams(gpa, resolved);
    try testing.expectEqual(@as(f64, 2.0), resolved[2].value.f64);
}

test "validateAndResolve: unknown key / wrong type / bad enum / missing required all error (#591 acceptance)" {
    const gpa = testing.allocator;
    try testing.expectError(error.PluginParamUnknown, validateAndResolve(gpa, "p", &.{
        .{ .name = "language", .value = .{ .str = "lua" } },
        .{ .name = "grid_szie", .value = .{ .i64 = 32 } },
    }, &test_schema));
    try testing.expectError(error.PluginParamTypeMismatch, validateAndResolve(gpa, "p", &.{
        .{ .name = "language", .value = .{ .str = "lua" } },
        .{ .name = "grid_size", .value = .{ .str = "32" } },
    }, &test_schema));
    try testing.expectError(error.PluginParamInvalidValue, validateAndResolve(gpa, "p", &.{
        .{ .name = "language", .value = .{ .str = "cobol" } },
    }, &test_schema));
    try testing.expectError(error.PluginParamMissingRequired, validateAndResolve(gpa, "p", &.{
        .{ .name = "debug", .value = .{ .bool = true } },
    }, &test_schema));
}

test "validateAndResolve: an empty bag against an all-optional schema resolves defaults only" {
    const gpa = testing.allocator;
    const schema = [_]ParamSchema{
        .{ .name = "grid_size", .type = .@"i64", .default = .{ .i64 = 32 } },
        .{ .name = "speed", .type = .@"f64" },
    };
    const resolved = try validateAndResolve(gpa, "p", &.{}, &schema);
    defer freeParams(gpa, resolved);
    try testing.expectEqual(@as(usize, 1), resolved.len);
    try testing.expectEqual(@as(i64, 32), resolved[0].value.i64);
}

// ── Layer 4: module rendering ───────────────────────────────────────

test "renderParamsModule: one typed pub const per resolved param" {
    const gpa = testing.allocator;
    const rendered = try renderParamsModule(gpa, "pathfinder", &.{
        .{ .name = "language", .value = .{ .str = "lua" } },
        .{ .name = "grid_size", .value = .{ .i64 = 32 } },
        .{ .name = "speed", .value = .{ .f64 = 1.5 } },
        .{ .name = "debug", .value = .{ .bool = false } },
    });
    defer gpa.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "pub const language: []const u8 = \"lua\";\n") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "pub const grid_size: i64 = 32;\n") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "pub const speed: f64 = 1.5;\n") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "pub const debug: bool = false;\n") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "plugin 'pathfinder'") != null);
}

test "paramsModuleFilename: plugin_<name>_params.zig" {
    const gpa = testing.allocator;
    const name = try paramsModuleFilename(gpa, "scripting");
    defer gpa.free(name);
    try testing.expectEqualStrings("plugin_scripting_params.zig", name);
}
