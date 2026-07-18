//! Schema-declared plugin params (labelle-assembler#591, epic
//! labelle-engine#237, RFC #730 rev 13) — the full mechanism behind the
//! generic `.params` bag that #589 shipped the v1 slice of.
//!
//! Three layers, all owned by this module:
//!
//!   1. **Open-bag parse** (`parseProjectConfig`). Params keys are
//!      plugin-declared, so no closed Zig struct can represent the bag and
//!      the strict typed parse (`ignore_unknown_fields = false`) would
//!      reject any key it doesn't know. The fix is a two-phase parse of
//!      `project.labelle`: a `std.zig.Zoir` walk extracts every plugin
//!      entry's `.params` literal into a dynamic key/value bag
//!      (`Param`/`ParamValue`, a tagged SCALAR union — string, i64, f64,
//!      bool, enum literal; ZON has no dynamic `std.zon.Value`, Zoir IS the
//!      dynamic representation), then each `.params` value is blanked to
//!      `.{}` (padded in place, newlines preserved, so every byte offset —
//!      and therefore every OTHER field's parse diagnostic — is exactly the
//!      typed parser's own), the unchanged typed parse runs on the
//!      sanitized copy, and the extracted bags are attached to the parsed
//!      `PluginDep.params_bag`. A source that never spells `.params` takes
//!      an untouched single-parse fast path.
//!
//!   2. **Schema declaration** (`parseSchemaFromManifestSource`). A plugin
//!      publishes the params it accepts under `.params_schema` in its
//!      `plugin.labelle`. The key is deliberately NOT `.params`: on the
//!      plugin side that spelling would read as the plugin *setting* param
//!      values; `.params_schema` says what it is — the schema the project's
//!      `.params` is validated against (and leaves `.params` free for a
//!      future presets concept). Each entry: `name` (lower_snake identifier
//!      — it becomes a Zig decl), `type` (`.str/.i64/.f64/.bool/.@"enum"`),
//!      `values` (enum vocabulary, each a valid identifier — they become
//!      Zig enum tags), `default` (a NATURAL scalar literal, type-matched),
//!      `required` (bool). Unknown entry keys hard-fail; the manifest's own
//!      typed parse is untouched (it ignores unknown fields, so an older
//!      assembler still loads a schema-bearing manifest — it simply never
//!      consumes the schema).
//!
//!   3. **Validation + comptime delivery** (`validateAndResolve`,
//!      `renderParamsModule`, `stage`). At generate time — beside the
//!      language-policy gate, BEFORE any target write — each declared bag is
//!      checked against the attached plugin's schema: unknown param, wrong
//!      type, out-of-vocabulary enum, missing required → actionable errors
//!      naming plugin + param + expectation. Resolution = project value,
//!      else schema default, else omitted (optional params — plugin code
//!      gates on `@hasDecl`). The resolved set is rendered as a Zig module
//!      (`plugin_<name>_params.zig`, staged next to the generated build.zig
//!      exactly like `plugin_<name>_build_hook.zig`) and injected into the
//!      plugin's module through the existing `overrideImport` machinery
//!      under the FIXED import name `plugin_params` — the same
//!      fixed-self-name convention as the packs' `@import("pack")`, so
//!      plugin source reads `@import("plugin_params")` without knowing its
//!      own project-declared name. Zero runtime cost.
//!
//! **Migration / supersede semantics (#589 → #591).** The natively
//! recognized `language` param stays: a SCHEMA-LESS plugin whose bag is
//! exactly `.{ .language = "…" }` passes validation untouched (the language
//! policy owns its rules), so every published scripting pin — whose
//! `plugin.labelle` predates the schema mechanism — keeps working, and the
//! #589 policy tests stay green unchanged. The moment a plugin declares a
//! `.params_schema`, the schema SUPERSEDES: it becomes the sole authority
//! on accepted keys and types (`language` included — a schema that wants it
//! must declare it), and the params module is delivered. The language
//! POLICY (supported vocabulary, one scripting plugin, dir scan) applies in
//! both worlds — `language_policy` reads the declaration through
//! `PluginDep.declaredLanguage`, which consults the typed fast-path field
//! and the generic bag. A schema-less plugin with any NON-`language` param
//! is an error (nothing may silently drop — the same strictness #589
//! guaranteed by construction).
//!
//! Params-less plugins (no schema anywhere, no bag) are byte-identical
//! everywhere: no staged module, no build.zig wiring, no output drift.

const std = @import("std");
const config = @import("config.zig");

// ============================================================================
// Types
// ============================================================================

/// One heterogeneous param value. ZON scalars only — a param is a plugin
/// build-configuration knob, not a data tree. `enum_tag` preserves the
/// `.platformer` (enum-literal) spelling distinctly from `"platformer"`
/// (string): enum-typed schema params accept both, str-typed params accept
/// only real strings.
pub const ParamValue = union(enum) {
    str: []const u8,
    int: i64,
    float: f64,
    boolean: bool,
    enum_tag: []const u8,

    /// The human name of the value's shape, for diagnostics.
    pub fn shapeName(self: ParamValue) []const u8 {
        return switch (self) {
            .str => "string",
            .int => "integer",
            .float => "float",
            .boolean => "bool",
            .enum_tag => "enum literal",
        };
    }
};

/// One project-declared param: a `.params` bag entry.
pub const Param = struct {
    name: []const u8,
    value: ParamValue,
};

/// The closed set of schema-declarable param types (#591): `str/i64/f64/
/// bool` plus `enum` with an allowed-values vocabulary. Spelled in the
/// manifest as enum literals (`.type = .i64`, `.type = .@"enum"`), matching
/// the house ZON style (`.mode = .copy_and_scan`).
pub const ParamType = enum {
    str,
    i64,
    f64,
    bool,
    @"enum",
};

pub const PARAM_TYPES_LIST = ".str, .i64, .f64, .bool, .@\"enum\"";

/// One schema entry a plugin declares under `.params_schema`.
pub const ParamSchema = struct {
    name: []const u8,
    type: ParamType,
    /// Enum vocabulary — required (non-empty) iff `type == .@"enum"`.
    values: []const []const u8 = &.{},
    /// Fallback when the project doesn't set the param. Mutually exclusive
    /// with `required` (a defaulted param is optional by definition).
    default: ?ParamValue = null,
    /// The project MUST set this param.
    required: bool = false,
};

/// One resolved param, ready for module emission. Owns all its strings
/// (the schema it came from dies with the manifest).
pub const ResolvedParam = struct {
    name: []const u8,
    type: ParamType,
    /// Enum vocabulary (owned) — emitted as the param's Zig enum type.
    values: []const []const u8,
    /// The resolved value; enum params normalize to `.enum_tag`.
    value: ParamValue,
};

/// All resolved params of one plugin. `plugin_name` is borrowed from the
/// `ProjectConfig.plugins` entry (alive for the whole generate run);
/// `params` is owned.
pub const ResolvedPluginParams = struct {
    plugin_name: []const u8,
    params: []ResolvedParam,
};

/// The fixed import name plugin code reads its params under —
/// `@import("plugin_params")`. Fixed (not `<plugin>_params`) so plugin
/// source never needs to know its own project-declared name, mirroring the
/// packs' fixed `@import("pack")` self-import. Each plugin's module gets
/// its OWN staged module bound under this name (import tables are
/// per-module, so the fixed name never collides across plugins).
pub const IMPORT_NAME = "plugin_params";

/// The manifest key a plugin declares its schema under. See the module doc
/// for why this is NOT `.params`.
pub const SCHEMA_KEY = "params_schema";

// ============================================================================
// Zoir helpers (shared by both walks)
// ============================================================================

const Ast = std.zig.Ast;
const Zoir = std.zig.Zoir;
const ZonGen = std.zig.ZonGen;

/// A parsed ZON document: the Ast (for source spans) + the Zoir (the
/// dynamic node tree). `null` when the source doesn't parse cleanly — the
/// caller falls back to the typed parser so syntax errors surface with the
/// exact diagnostics they have today.
const ZonDoc = struct {
    ast: Ast,
    zoir: Zoir,

    fn deinit(self: *ZonDoc, gpa: std.mem.Allocator) void {
        self.zoir.deinit(gpa);
        self.ast.deinit(gpa);
    }
};

fn parseZonDoc(gpa: std.mem.Allocator, source: [:0]const u8) !?ZonDoc {
    var ast = try Ast.parse(gpa, source, .zon);
    errdefer ast.deinit(gpa);
    if (ast.errors.len != 0) {
        ast.deinit(gpa);
        return null;
    }
    var zoir = try ZonGen.generate(gpa, ast, .{});
    errdefer zoir.deinit(gpa);
    if (zoir.hasCompileErrors()) {
        zoir.deinit(gpa);
        ast.deinit(gpa);
        return null;
    }
    return .{ .ast = ast, .zoir = zoir };
}

/// Find `name` in a struct-literal node; null when the node isn't a struct
/// literal or lacks the field.
fn structField(zoir: Zoir, node: Zoir.Node.Index, name: []const u8) ?Zoir.Node.Index {
    switch (node.get(zoir)) {
        .struct_literal => |s| {
            for (s.names, 0..) |n, i| {
                if (std.mem.eql(u8, n.get(zoir), name)) return s.vals.at(@intCast(i));
            }
            return null;
        },
        else => return null,
    }
}

/// Extract a scalar `ParamValue` from a Zoir node; `null` for non-scalar
/// shapes (struct/array literals) the caller diagnoses. All strings are
/// duped into `gpa` (Zoir storage dies with the doc).
fn scalarFromNode(gpa: std.mem.Allocator, zoir: Zoir, node: Zoir.Node.Index) !?ParamValue {
    return switch (node.get(zoir)) {
        .true => .{ .boolean = true },
        .false => .{ .boolean = false },
        .int_literal => |int| switch (int) {
            .small => |v| .{ .int = v },
            .big => |v| .{ .int = v.toInt(i64) catch return error.PluginParamIntOutOfRange },
        },
        .float_literal => |v| .{ .float = @floatCast(v) },
        .string_literal => |s| .{ .str = try gpa.dupe(u8, s) },
        .enum_literal => |s| .{ .enum_tag = try gpa.dupe(u8, s.get(zoir)) },
        else => null,
    };
}

fn freeParamValue(gpa: std.mem.Allocator, v: ParamValue) void {
    switch (v) {
        .str, .enum_tag => |s| gpa.free(s),
        else => {},
    }
}

// ============================================================================
// Layer 1 — project-side `.params` extraction + tolerant config parse
// ============================================================================

/// The extraction result: one optional bag per `.plugins` entry (index-
/// aligned), plus the sanitized source for the typed parse.
const ExtractedBags = struct {
    /// bags[i] belongs to plugins[i]; null = the entry declares no `.params`.
    bags: []?[]Param,
    /// The source with every `.params` VALUE blanked to `.{}` + spaces
    /// (newlines preserved — byte-identical length and line structure, so
    /// the typed parser's diagnostics for every other field are exact).
    sanitized: [:0]u8,

    /// Free everything, bags included — the error path.
    fn deinitDeep(self: *ExtractedBags, gpa: std.mem.Allocator) void {
        for (self.bags) |maybe_bag| if (maybe_bag) |bag| freeBag(gpa, bag);
        self.deinitShallow(gpa);
    }

    /// Free the scaffolding only — the bags were handed off.
    fn deinitShallow(self: *ExtractedBags, gpa: std.mem.Allocator) void {
        gpa.free(self.bags);
        gpa.free(self.sanitized);
    }
};

fn freeBag(gpa: std.mem.Allocator, bag: []Param) void {
    for (bag) |p| {
        gpa.free(p.name);
        freeParamValue(gpa, p.value);
    }
    gpa.free(bag);
}

/// Walk the project.labelle Zoir for `.plugins[i].params` literals; extract
/// each into a dynamic bag and blank its span in a copy of the source.
///
/// Returns `null` for every shape where the typed parse alone is the right
/// tool: no `.params` spelled anywhere (the fast path — no re-parse, no
/// copy), a source that doesn't parse as ZON (the typed parser owns syntax
/// diagnostics), or a top level/plugins shape the typed parser will reject
/// with its own message.
///
/// Hard-errors (`error.InvalidPluginParams`) when a `.params` VALUE exists
/// but isn't a struct literal, or a bag value isn't a scalar — the typed
/// parser never sees the original literal (it is blanked), so shape errors
/// on the bag itself must be diagnosed HERE, with the plugin named.
fn extractParamsBags(gpa: std.mem.Allocator, source: [:0]const u8) !?ExtractedBags {
    // Fast path: a project that never spells `.params` — the overwhelmingly
    // common case — is never re-parsed or copied. (`.font_params` etc. do
    // not contain the dotted spelling; a false positive only costs the walk.)
    if (std.mem.indexOf(u8, source, ".params") == null) return null;

    var doc = (try parseZonDoc(gpa, source)) orelse return null;
    defer doc.deinit(gpa);

    const plugins_node = structField(doc.zoir, .root, "plugins") orelse return null;
    const plugin_nodes: Zoir.Node.Index.Range = switch (plugins_node.get(doc.zoir)) {
        .array_literal => |r| r,
        else => return null, // `.{}` or a non-array — the typed parser diagnoses.
    };

    var bags = try gpa.alloc(?[]Param, plugin_nodes.len);
    errdefer gpa.free(bags);
    @memset(bags, null);
    errdefer for (bags) |maybe_bag| if (maybe_bag) |bag| freeBag(gpa, bag);

    var sanitized = try gpa.dupeZ(u8, source);
    errdefer gpa.free(sanitized);

    var any_params = false;
    for (0..plugin_nodes.len) |i| {
        const entry = plugin_nodes.at(@intCast(i));
        const params_node = structField(doc.zoir, entry, "params") orelse continue;

        // Diagnostics name the entry by its `.name` when it has one.
        const entry_label: []const u8 = blk: {
            const name_node = structField(doc.zoir, entry, "name") orelse break :blk "<unnamed>";
            break :blk switch (name_node.get(doc.zoir)) {
                .string_literal => |s| s,
                else => "<unnamed>",
            };
        };

        const entries: []Param = switch (params_node.get(doc.zoir)) {
            .empty_literal => try gpa.alloc(Param, 0),
            .struct_literal => |s| blk: {
                var list = try gpa.alloc(Param, s.names.len);
                var filled: usize = 0;
                errdefer {
                    for (list[0..filled]) |p| {
                        gpa.free(p.name);
                        freeParamValue(gpa, p.value);
                    }
                    gpa.free(list);
                }
                for (s.names, 0..) |n, j| {
                    const key = n.get(doc.zoir);
                    const val_node = s.vals.at(@intCast(j));
                    const value = scalarFromNode(gpa, doc.zoir, val_node) catch |err| switch (err) {
                        error.PluginParamIntOutOfRange => {
                            std.debug.print(
                                "labelle-assembler: plugin '{s}': param '{s}' is an integer that does not fit i64.\n" ++
                                    "  i64 is the widest integer param type; use a float literal for an f64 param.\n",
                                .{ entry_label, key },
                            );
                            return error.InvalidPluginParams;
                        },
                        else => |e| return e,
                    } orelse {
                        std.debug.print(
                            "labelle-assembler: plugin '{s}': param '{s}' must be a scalar — a string, integer, float, bool, or enum literal.\n" ++
                                "  nested struct/array literals are not param values.\n",
                            .{ entry_label, key },
                        );
                        return error.InvalidPluginParams;
                    };
                    errdefer freeParamValue(gpa, value);
                    const key_owned = try gpa.dupe(u8, key);
                    list[j] = .{ .name = key_owned, .value = value };
                    filled = j + 1;
                }
                break :blk list;
            },
            else => {
                std.debug.print(
                    "labelle-assembler: plugin '{s}': `.params` must be a struct literal, e.g. `.params = .{{ .language = \"lua\" }}`.\n",
                    .{entry_label},
                );
                return error.InvalidPluginParams;
            },
        };
        bags[i] = entries;
        any_params = true;

        // Blank the `.params` VALUE span to `.{}` + spaces so the STRICT
        // typed parse never sees the plugin-declared keys. EVERY newline in
        // the span is preserved (the `}` slides past a line break when the
        // literal opens with one), so byte offsets AND line numbers — and
        // therefore every other field's diagnostic — stay exact.
        const ast_node = params_node.getAstNode(doc.zoir);
        const span = doc.ast.getNodeSource(ast_node);
        const off = @intFromPtr(span.ptr) - @intFromPtr(doc.ast.source.ptr);
        std.debug.assert(span.len >= 3); // a struct literal is at least `.{}`
        sanitized[off] = '.'; // span[0..2] is always ".{"
        sanitized[off + 1] = '{';
        var closed = false;
        for (sanitized[off + 2 .. off + span.len]) |*b| {
            if (b.* == '\n') continue;
            if (!closed) {
                b.* = '}';
                closed = true;
            } else {
                b.* = ' ';
            }
        }
        // The span's last byte is the literal's own `}` (never a newline),
        // so the close brace always found a home.
        std.debug.assert(closed);
    }

    if (!any_params) {
        // `.params` appeared in the source but on no plugin entry (e.g. a
        // comment or an unrelated key) — plain typed parse handles it.
        gpa.free(bags);
        gpa.free(sanitized);
        return null;
    }

    return .{ .bags = bags, .sanitized = sanitized };
}

/// Parse a `project.labelle` source into a `ProjectConfig`, tolerating
/// plugin-declared `.params` keys (see the module doc, layer 1). This is
/// THE parse every project.labelle site routes through; behavior for a
/// source without `.params` is byte-identical to the plain typed parse
/// (same call, same diagnostics, single pass).
pub fn parseProjectConfig(
    gpa: std.mem.Allocator,
    source: [:0]const u8,
) !config.ProjectConfig {
    // The typed ProjectConfig parse is comptime-heavy (the callers'
    // pre-#591 parse sites carried the same quota).
    @setEvalBranchQuota(10000);
    var extraction = (try extractParamsBags(gpa, source)) orelse
        return std.zon.parse.fromSliceAlloc(config.ProjectConfig, gpa, source, null, .{});
    errdefer extraction.deinitDeep(gpa);

    const cfg = try std.zon.parse.fromSliceAlloc(config.ProjectConfig, gpa, extraction.sanitized, null, .{});

    // Attach the extracted bags. The Zoir walk and the typed parse consumed
    // the same `.plugins` array, so the counts agree by construction.
    std.debug.assert(cfg.plugins.len == extraction.bags.len);
    // The plugins slice is a fresh parser-owned heap allocation; casting
    // away const to attach the bags is sound (same pattern as root.zig
    // swapping cfg.resources for the merged list, one level deeper).
    const plugins = @constCast(cfg.plugins);
    for (plugins, extraction.bags) |*p, maybe_bag| {
        if (maybe_bag) |bag| p.params_bag = bag;
    }

    // Bags are now owned by cfg (`std.zon.parse.free`-compatible shapes —
    // plain gpa slices/strings/tagged unions); free only the scaffolding.
    extraction.deinitShallow(gpa);
    return cfg;
}

// ============================================================================
// Layer 2 — plugin-side `.params_schema` parse
// ============================================================================

fn isLowerSnakeIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!(s[0] == '_' or (s[0] >= 'a' and s[0] <= 'z'))) return false;
    for (s[1..]) |c| {
        const ok = c == '_' or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9');
        if (!ok) return false;
    }
    return true;
}

fn isIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!(s[0] == '_' or std.ascii.isAlphabetic(s[0]))) return false;
    for (s[1..]) |c| {
        if (!(c == '_' or std.ascii.isAlphanumeric(c))) return false;
    }
    return true;
}

pub fn freeSchema(gpa: std.mem.Allocator, schema: []const ParamSchema) void {
    for (schema) |s| {
        gpa.free(s.name);
        for (s.values) |v| gpa.free(v);
        gpa.free(s.values);
        if (s.default) |d| freeParamValue(gpa, d);
    }
    gpa.free(schema);
}

/// Parse `.params_schema` out of a raw `plugin.labelle` source. Returns an
/// empty slice when the key is absent (every schema-less plugin — the
/// byte-identity default) or when the source doesn't parse as ZON (the
/// manifest's own typed parse owns syntax diagnostics; this walk never
/// duplicates them).
///
/// Shape violations hard-fail with `error.PluginManifestInvalidParamsSchema`
/// and a diagnostic naming the plugin, the entry, and the fix — including
/// UNKNOWN ENTRY KEYS (the manifest-wide `ignore_unknown_fields = true`
/// forward-compat rule deliberately does NOT extend inside schema entries:
/// a typo'd `.requird` must not silently make a param optional).
pub fn parseSchemaFromManifestSource(
    gpa: std.mem.Allocator,
    source: [:0]const u8,
    plugin_name: []const u8,
) ![]const ParamSchema {
    if (std.mem.indexOf(u8, source, SCHEMA_KEY) == null) return &.{};

    var doc = (try parseZonDoc(gpa, source)) orelse return &.{};
    defer doc.deinit(gpa);

    const schema_node = structField(doc.zoir, .root, SCHEMA_KEY) orelse return &.{};
    const entry_nodes: Zoir.Node.Index.Range = switch (schema_node.get(doc.zoir)) {
        .array_literal => |r| r,
        .empty_literal => return &.{},
        else => {
            std.debug.print(
                "labelle-assembler: plugin '{s}': `.{s}` must be a list of schema entries, e.g.\n" ++
                    "    .{s} = .{{ .{{ .name = \"grid_size\", .type = .i64, .default = 32 }} }}\n",
                .{ plugin_name, SCHEMA_KEY, SCHEMA_KEY },
            );
            return error.PluginManifestInvalidParamsSchema;
        },
    };

    var list: std.ArrayList(ParamSchema) = .empty;
    errdefer {
        for (list.items) |s| {
            gpa.free(s.name);
            for (s.values) |v| gpa.free(v);
            gpa.free(s.values);
            if (s.default) |d| freeParamValue(gpa, d);
        }
        list.deinit(gpa);
    }

    for (0..entry_nodes.len) |i| {
        const entry = entry_nodes.at(@intCast(i));
        const fields = switch (entry.get(doc.zoir)) {
            .struct_literal => |s| s,
            else => {
                std.debug.print(
                    "labelle-assembler: plugin '{s}': `.{s}` entry {d} must be a struct literal (.{{ .name = …, .type = … }}).\n",
                    .{ plugin_name, SCHEMA_KEY, i },
                );
                return error.PluginManifestInvalidParamsSchema;
            },
        };

        var name: ?[]const u8 = null;
        errdefer if (name) |n| gpa.free(n);
        var param_type: ?ParamType = null;
        var values: []const []const u8 = &.{};
        errdefer {
            for (values) |v| gpa.free(v);
            gpa.free(values);
        }
        var default: ?ParamValue = null;
        errdefer if (default) |d| freeParamValue(gpa, d);
        var required = false;

        for (fields.names, 0..) |n, j| {
            const key = n.get(doc.zoir);
            const val_node = fields.vals.at(@intCast(j));
            if (std.mem.eql(u8, key, "name")) {
                name = switch (val_node.get(doc.zoir)) {
                    .string_literal => |s| try gpa.dupe(u8, s),
                    else => {
                        std.debug.print(
                            "labelle-assembler: plugin '{s}': schema entry {d}: `.name` must be a string.\n",
                            .{ plugin_name, i },
                        );
                        return error.PluginManifestInvalidParamsSchema;
                    },
                };
            } else if (std.mem.eql(u8, key, "type")) {
                param_type = switch (val_node.get(doc.zoir)) {
                    .enum_literal => |s| std.meta.stringToEnum(ParamType, s.get(doc.zoir)) orelse {
                        std.debug.print(
                            "labelle-assembler: plugin '{s}': schema entry {d}: unknown param type `.{s}`.\n" ++
                                "  supported types: {s}.\n",
                            .{ plugin_name, i, s.get(doc.zoir), PARAM_TYPES_LIST },
                        );
                        return error.PluginManifestInvalidParamsSchema;
                    },
                    else => {
                        std.debug.print(
                            "labelle-assembler: plugin '{s}': schema entry {d}: `.type` must be an enum literal ({s}).\n",
                            .{ plugin_name, i, PARAM_TYPES_LIST },
                        );
                        return error.PluginManifestInvalidParamsSchema;
                    },
                };
            } else if (std.mem.eql(u8, key, "values")) {
                const value_nodes: Zoir.Node.Index.Range = switch (val_node.get(doc.zoir)) {
                    .array_literal => |r| r,
                    .empty_literal => {
                        std.debug.print(
                            "labelle-assembler: plugin '{s}': schema entry {d}: `.values` must not be empty.\n",
                            .{ plugin_name, i },
                        );
                        return error.PluginManifestInvalidParamsSchema;
                    },
                    else => {
                        std.debug.print(
                            "labelle-assembler: plugin '{s}': schema entry {d}: `.values` must be a list of strings.\n",
                            .{ plugin_name, i },
                        );
                        return error.PluginManifestInvalidParamsSchema;
                    },
                };
                const vals = try gpa.alloc([]const u8, value_nodes.len);
                var vals_filled: usize = 0;
                errdefer {
                    for (vals[0..vals_filled]) |v| gpa.free(v);
                    gpa.free(vals);
                }
                for (0..value_nodes.len) |k| {
                    vals[k] = switch (value_nodes.at(@intCast(k)).get(doc.zoir)) {
                        .string_literal => |s| try gpa.dupe(u8, s),
                        else => {
                            std.debug.print(
                                "labelle-assembler: plugin '{s}': schema entry {d}: every `.values` entry must be a string.\n",
                                .{ plugin_name, i },
                            );
                            return error.PluginManifestInvalidParamsSchema;
                        },
                    };
                    vals_filled = k + 1;
                }
                values = vals;
            } else if (std.mem.eql(u8, key, "default")) {
                default = (try scalarFromNode(gpa, doc.zoir, val_node)) orelse {
                    std.debug.print(
                        "labelle-assembler: plugin '{s}': schema entry {d}: `.default` must be a scalar literal.\n",
                        .{ plugin_name, i },
                    );
                    return error.PluginManifestInvalidParamsSchema;
                };
            } else if (std.mem.eql(u8, key, "required")) {
                required = switch (val_node.get(doc.zoir)) {
                    .true => true,
                    .false => false,
                    else => {
                        std.debug.print(
                            "labelle-assembler: plugin '{s}': schema entry {d}: `.required` must be a bool.\n",
                            .{ plugin_name, i },
                        );
                        return error.PluginManifestInvalidParamsSchema;
                    },
                };
            } else {
                // The ticket's "unknown schema keys hard-fail".
                std.debug.print(
                    "labelle-assembler: plugin '{s}': schema entry {d}: unknown key '.{s}'.\n" ++
                        "  accepted keys: .name, .type, .values, .default, .required.\n",
                    .{ plugin_name, i, key },
                );
                return error.PluginManifestInvalidParamsSchema;
            }
        }

        const entry_name = name orelse {
            std.debug.print(
                "labelle-assembler: plugin '{s}': schema entry {d} is missing `.name`.\n",
                .{ plugin_name, i },
            );
            return error.PluginManifestInvalidParamsSchema;
        };
        const entry_type = param_type orelse {
            std.debug.print(
                "labelle-assembler: plugin '{s}': schema param '{s}' is missing `.type` ({s}).\n",
                .{ plugin_name, entry_name, PARAM_TYPES_LIST },
            );
            return error.PluginManifestInvalidParamsSchema;
        };

        // `name` becomes a Zig decl in the generated module, and the enum
        // param's TYPE decl is its PascalCase twin — lower_snake makes both
        // valid and collision-free by construction.
        if (!isLowerSnakeIdent(entry_name)) {
            std.debug.print(
                "labelle-assembler: plugin '{s}': schema param '{s}' is not a lower_snake_case identifier.\n" ++
                    "  param names become Zig decls in the generated params module ([a-z_][a-z0-9_]*).\n",
                .{ plugin_name, entry_name },
            );
            return error.PluginManifestInvalidParamsSchema;
        }
        for (list.items) |prev| {
            if (std.mem.eql(u8, prev.name, entry_name)) {
                std.debug.print(
                    "labelle-assembler: plugin '{s}': schema declares param '{s}' twice.\n",
                    .{ plugin_name, entry_name },
                );
                return error.PluginManifestInvalidParamsSchema;
            }
        }

        // values ⇔ enum pairing; vocabulary entries become Zig enum tags.
        if (entry_type == .@"enum") {
            if (values.len == 0) {
                std.debug.print(
                    "labelle-assembler: plugin '{s}': enum param '{s}' needs `.values` (its allowed vocabulary).\n",
                    .{ plugin_name, entry_name },
                );
                return error.PluginManifestInvalidParamsSchema;
            }
            for (values, 0..) |v, vi| {
                if (!isIdent(v)) {
                    std.debug.print(
                        "labelle-assembler: plugin '{s}': enum param '{s}': value \"{s}\" is not a valid identifier.\n" ++
                            "  enum values become Zig enum tags in the generated params module.\n",
                        .{ plugin_name, entry_name, v },
                    );
                    return error.PluginManifestInvalidParamsSchema;
                }
                // A duplicate tag would render `enum { topdown, topdown }` —
                // a generated module that fails to COMPILE instead of a
                // manifest error here (#591 review P2).
                for (values[0..vi]) |prev_v| {
                    if (std.mem.eql(u8, prev_v, v)) {
                        std.debug.print(
                            "labelle-assembler: plugin '{s}': enum param '{s}': duplicate value \"{s}\" in `.values`.\n" ++
                                "  each vocabulary entry becomes a Zig enum tag — remove the duplicate.\n",
                            .{ plugin_name, entry_name, v },
                        );
                        return error.PluginManifestInvalidParamsSchema;
                    }
                }
            }
            // Two enum params whose names NORMALIZE to the same PascalCase
            // type decl (`mode` / `mode_`, `foo_bar` / `foo__bar`) would
            // render duplicate `pub const <Type>` decls — the same
            // compile-instead-of-manifest-error failure (#591 review P2).
            // Param DECLS can never collide with type decls by construction
            // (names are validated lower_snake, rendered types start
            // uppercase), so enum-type-vs-enum-type is the only collision
            // the render can produce.
            const type_name = try pascalCase(gpa, entry_name);
            defer gpa.free(type_name);
            for (list.items) |prev| {
                if (prev.type != .@"enum") continue;
                const prev_type_name = try pascalCase(gpa, prev.name);
                defer gpa.free(prev_type_name);
                if (std.mem.eql(u8, prev_type_name, type_name)) {
                    std.debug.print(
                        "labelle-assembler: plugin '{s}': enum params '{s}' and '{s}' both render the Zig type '{s}' in the generated params module.\n" ++
                            "  rename one so their PascalCase forms differ.\n",
                        .{ plugin_name, prev.name, entry_name, type_name },
                    );
                    return error.PluginManifestInvalidParamsSchema;
                }
            }
        } else if (values.len != 0) {
            std.debug.print(
                "labelle-assembler: plugin '{s}': param '{s}' sets `.values` but its type is .{s} — `.values` is enum-only.\n",
                .{ plugin_name, entry_name, @tagName(entry_type) },
            );
            return error.PluginManifestInvalidParamsSchema;
        }

        // required × default is a contradiction (a defaulted param is
        // optional by definition) — a schema bug, rejected at the source.
        if (required and default != null) {
            std.debug.print(
                "labelle-assembler: plugin '{s}': param '{s}' is `.required = true` AND has a `.default` — pick one.\n",
                .{ plugin_name, entry_name },
            );
            return error.PluginManifestInvalidParamsSchema;
        }

        // The default must satisfy the param's own type rules.
        if (default) |d| {
            const coerced = coerceValue(entry_type, values, d) orelse {
                std.debug.print(
                    "labelle-assembler: plugin '{s}': param '{s}': `.default` does not match type .{s}{s}.\n",
                    .{ plugin_name, entry_name, @tagName(entry_type), if (entry_type == .@"enum") " (or is outside `.values`)" else "" },
                );
                return error.PluginManifestInvalidParamsSchema;
            };
            default = coerced;
        }

        try list.append(gpa, .{
            .name = entry_name,
            .type = entry_type,
            .values = values,
            .default = default,
            .required = required,
        });
        // Ownership moved into the list; disarm the per-entry errdefers.
        name = null;
        values = &.{};
        default = null;
    }

    return try list.toOwnedSlice(gpa);
}

// ============================================================================
// Layer 3 — generate-time validation + resolution
// ============================================================================

/// Coerce a project-declared (or default) value onto a schema type.
/// Returns the normalized value, or null when the shapes don't fit:
///   - str    ← string only
///   - i64    ← integer only
///   - f64    ← float or integer (ZON's own int→float coercion, mirrored)
///   - bool   ← bool only
///   - enum   ← string or enum literal whose tag is in `values`
///     (normalized to `.enum_tag` so emission has one spelling)
/// The returned value ALIASES the input's string memory (no copies).
fn coerceValue(param_type: ParamType, values: []const []const u8, v: ParamValue) ?ParamValue {
    switch (param_type) {
        .str => return if (v == .str) v else null,
        .i64 => return if (v == .int) v else null,
        .f64 => return switch (v) {
            .float => v,
            .int => |x| .{ .float = @floatFromInt(x) },
            else => null,
        },
        .bool => return if (v == .boolean) v else null,
        .@"enum" => {
            const tag = switch (v) {
                .str => |s| s,
                .enum_tag => |s| s,
                else => return null,
            };
            for (values) |allowed| {
                if (std.mem.eql(u8, allowed, tag)) return .{ .enum_tag = tag };
            }
            return null;
        },
    }
}

fn joinNames(gpa: std.mem.Allocator, comptime what: []const u8, names: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    if (names.len == 0) {
        try w.writeAll("(none — the plugin declares " ++ what ++ ")");
    } else {
        for (names, 0..) |n, i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("{s}", .{fieldName(n)});
        }
    }
    var arr = aw.toArrayList();
    errdefer arr.deinit(gpa);
    return arr.toOwnedSlice(gpa);
}

fn fieldName(n: anytype) []const u8 {
    return if (comptime @TypeOf(n) == ParamSchema) n.name else n;
}

pub fn freeResolved(gpa: std.mem.Allocator, params: []ResolvedParam) void {
    for (params) |p| {
        gpa.free(p.name);
        for (p.values) |v| gpa.free(v);
        gpa.free(p.values);
        freeParamValue(gpa, p.value);
    }
    gpa.free(params);
}

pub fn freeResolvedList(gpa: std.mem.Allocator, list: *std.ArrayList(ResolvedPluginParams)) void {
    for (list.items) |e| freeResolved(gpa, e.params);
    list.deinit(gpa);
}

/// Validate one plugin's effective `.params` bag against its schema and
/// resolve the final param set (project values + schema defaults, in SCHEMA
/// order — deterministic output owned by the plugin author).
///
/// Returns null — no params module — for the two schema-less OK shapes:
/// no/empty bag, and the native `language`-only fast path (see the module
/// doc's supersede semantics). A schema-less plugin with any other param is
/// `error.UnknownPluginParam`. With a schema, the errors are:
///
///   - `error.UnknownPluginParam`         — bag key not in the schema
///   - `error.PluginParamTypeMismatch`    — value shape ≠ declared type
///   - `error.PluginParamInvalidEnumValue`— enum value outside `.values`
///   - `error.MissingRequiredPluginParam` — `.required` param not set
///
/// Every diagnostic names the plugin, the param, and the expectation.
/// The returned params are fully OWNED (caller frees via `freeResolved`);
/// `bag` and `schema` may die right after this returns.
pub fn validateAndResolve(
    gpa: std.mem.Allocator,
    plugin_name: []const u8,
    bag: []const Param,
    schema: []const ParamSchema,
) !?[]ResolvedParam {
    if (schema.len == 0) {
        if (bag.len == 0) return null;
        // Native fast path (#589 compat): a schema-less plugin whose bag is
        // exactly the singular string `language` — the shape every published
        // scripting pin uses — is the language policy's business, not ours.
        // Deliberately STRING-only: the enum-literal spelling
        // (`.language = .lua`) belongs to the schema world, so against a
        // schema-less plugin it takes the LOUD error below (which names the
        // fix) rather than widening the legacy surface. The policy accessor
        // (`PluginDep.declaredLanguage`) recognizes both spellings, so the
        // one-language checks still ran before this error fires.
        if (bag.len == 1 and std.mem.eql(u8, bag[0].name, "language") and bag[0].value == .str) {
            return null;
        }
        const offender = for (bag) |p| {
            if (!std.mem.eql(u8, p.name, "language") or p.value != .str) break p;
        } else bag[0];
        std.debug.print(
            "labelle-assembler: plugin '{s}' accepts no params — its plugin.labelle declares no `.{s}` — but the project sets param '{s}'.\n" ++
                "  schema-less plugins accept only the native `.language` string; remove the param or upgrade the plugin.\n",
            .{ plugin_name, SCHEMA_KEY, offender.name },
        );
        return error.UnknownPluginParam;
    }

    // Schema present — it SUPERSEDES: the sole authority on keys + types.
    for (bag) |p| {
        const entry: ParamSchema = for (schema) |s| {
            if (std.mem.eql(u8, s.name, p.name)) break s;
        } else {
            const accepted = try joinNames(gpa, "no params", schema);
            defer gpa.free(accepted);
            std.debug.print(
                "labelle-assembler: plugin '{s}' does not accept param '{s}'.\n" ++
                    "  params declared by the plugin: {s}.\n",
                .{ plugin_name, p.name, accepted },
            );
            return error.UnknownPluginParam;
        };

        if (coerceValue(entry.type, entry.values, p.value) == null) {
            if (entry.type == .@"enum" and (p.value == .str or p.value == .enum_tag)) {
                const vocab = try joinNames(gpa, "no values", entry.values);
                defer gpa.free(vocab);
                std.debug.print(
                    "labelle-assembler: plugin '{s}': param '{s}' = \"{s}\" is outside the allowed values.\n" ++
                        "  allowed: {s}.\n",
                    .{ plugin_name, p.name, switch (p.value) {
                        .str, .enum_tag => |s| s,
                        else => unreachable,
                    }, vocab },
                );
                return error.PluginParamInvalidEnumValue;
            }
            std.debug.print(
                "labelle-assembler: plugin '{s}': param '{s}' expects {s} but got {s}.\n",
                .{ plugin_name, p.name, switch (entry.type) {
                    .str => "a string",
                    .i64 => "an integer (i64)",
                    .f64 => "a float (f64)",
                    .bool => "a bool",
                    .@"enum" => "an enum value (string or enum literal)",
                }, p.value.shapeName() },
            );
            return error.PluginParamTypeMismatch;
        }
    }

    var resolved: std.ArrayList(ResolvedParam) = .empty;
    errdefer {
        for (resolved.items) |p| {
            gpa.free(p.name);
            for (p.values) |v| gpa.free(v);
            gpa.free(p.values);
            freeParamValue(gpa, p.value);
        }
        resolved.deinit(gpa);
    }
    for (schema) |s| {
        const project_value: ?ParamValue = for (bag) |p| {
            if (std.mem.eql(u8, p.name, s.name)) break p.value;
        } else null;

        const value = if (project_value) |v|
            coerceValue(s.type, s.values, v).? // pre-validated above
        else if (s.default) |d|
            d
        else if (s.required) {
            const vocab: []const u8 = if (s.type == .@"enum") try joinNames(gpa, "no values", s.values) else "";
            defer if (s.type == .@"enum") gpa.free(vocab);
            std.debug.print(
                "labelle-assembler: plugin '{s}' requires param '{s}' (.{s}{s}{s}) but the project does not set it.\n" ++
                    "  add it to the plugin's entry in project.labelle: `.params = .{{ .{s} = … }}`.\n",
                .{ plugin_name, s.name, @tagName(s.type), if (s.type == .@"enum") ", one of: " else "", vocab, s.name },
            );
            return error.MissingRequiredPluginParam;
        } else continue; // optional, unset, no default — omitted (`@hasDecl`).

        // Deep-copy: the schema (and the bag) die with their manifests.
        const name_owned = try gpa.dupe(u8, s.name);
        errdefer gpa.free(name_owned);
        var values_owned = try gpa.alloc([]const u8, s.values.len);
        var values_filled: usize = 0;
        errdefer {
            for (values_owned[0..values_filled]) |v| gpa.free(v);
            gpa.free(values_owned);
        }
        for (s.values, 0..) |v, i| {
            values_owned[i] = try gpa.dupe(u8, v);
            values_filled = i + 1;
        }
        const value_owned: ParamValue = switch (value) {
            .str => |v| .{ .str = try gpa.dupe(u8, v) },
            .enum_tag => |v| .{ .enum_tag = try gpa.dupe(u8, v) },
            else => value,
        };
        errdefer freeParamValue(gpa, value_owned);
        try resolved.append(gpa, .{
            .name = name_owned,
            .type = s.type,
            .values = values_owned,
            .value = value_owned,
        });
    }
    return try resolved.toOwnedSlice(gpa);
}

// ============================================================================
// Layer 3 — module emission + staging
// ============================================================================

/// PascalCase twin of a lower_snake param name — the generated enum TYPE
/// decl (`grid_mode` → `GridMode`). Collision-free by construction: param
/// names are validated lower_snake, so no param can spell the PascalCase
/// twin. Caller owns the result.
fn pascalCase(gpa: std.mem.Allocator, snake: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var upper_next = true;
    for (snake) |c| {
        if (c == '_') {
            upper_next = true;
            continue;
        }
        try out.append(gpa, if (upper_next) std.ascii.toUpper(c) else c);
        upper_next = false;
    }
    if (out.items.len == 0) try out.appendSlice(gpa, "P"); // "_" alone
    return out.toOwnedSlice(gpa);
}

/// Render the comptime params module for one plugin — the file staged as
/// `plugin_<name>_params.zig` and imported by the plugin's code as
/// `@import("plugin_params")`. Deterministic: schema declaration order,
/// stable text (golden-tested). `std.zig.fmtId` quotes any name/tag that
/// needs it (a `.values` entry like "error" emits as `.@"error"`).
pub fn renderParamsModule(
    gpa: std.mem.Allocator,
    plugin_name: []const u8,
    params: []const ResolvedParam,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.print(
        "//! Generated by labelle-assembler (#591) — resolved `.params` for plugin '{s}'.\n" ++
            "//! Comptime plugin configuration: the assembler injects this module into the\n" ++
            "//! plugin as `@import(\"{s}\")`. Do not edit; regenerated every `labelle generate`.\n",
        .{ plugin_name, IMPORT_NAME },
    );
    for (params) |p| {
        try w.writeByte('\n');
        switch (p.value) {
            .str => |v| try w.print("pub const {f}: []const u8 = \"{f}\";\n", .{ std.zig.fmtId(p.name), std.zig.fmtString(v) }),
            .int => |v| try w.print("pub const {f}: i64 = {d};\n", .{ std.zig.fmtId(p.name), v }),
            .float => |v| try w.print("pub const {f}: f64 = {d};\n", .{ std.zig.fmtId(p.name), v }),
            .boolean => |v| try w.print("pub const {f}: bool = {s};\n", .{ std.zig.fmtId(p.name), if (v) "true" else "false" }),
            .enum_tag => |v| {
                const type_name = try pascalCase(gpa, p.name);
                defer gpa.free(type_name);
                try w.print("pub const {s} = enum {{", .{type_name});
                for (p.values, 0..) |tag, i| {
                    if (i > 0) try w.writeByte(',');
                    try w.print(" {f}", .{std.zig.fmtId(tag)});
                }
                try w.writeAll(" };\n");
                try w.print("pub const {f}: {s} = .{f};\n", .{ std.zig.fmtId(p.name), type_name, std.zig.fmtId(v) });
            },
        }
    }

    var arr = aw.toArrayList();
    errdefer arr.deinit(gpa);
    return arr.toOwnedSlice(gpa);
}

/// The staged sibling file name next to the generated build.zig. MUST agree
/// with the `b.path("plugin_<name>_params.zig")` the build.zig emitter
/// writes (`build_files/build_zig.zig`). Caller owns the result.
pub fn stagedName(gpa: std.mem.Allocator, plugin_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "plugin_{s}_params.zig", .{plugin_name});
}

/// Write each resolved plugin's params module into the target dir (next to
/// the generated build.zig — the `plugin_build_hook.stage` pattern). No-op
/// when nothing resolved: params-less projects stay byte-identical.
pub fn stage(
    gpa: std.mem.Allocator,
    resolved: []const ResolvedPluginParams,
    target_dir: []const u8,
) !void {
    if (resolved.len == 0) return;

    const io = config.globalIo();
    var dir = try std.Io.Dir.cwd().openDir(io, target_dir, .{});
    defer dir.close(io);

    for (resolved) |r| {
        const content = try renderParamsModule(gpa, r.plugin_name, r.params);
        defer gpa.free(content);
        const dest_name = try stagedName(gpa, r.plugin_name);
        defer gpa.free(dest_name);
        const file = try dir.createFile(io, dest_name, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, content);
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

// ── layer 1: extraction + tolerant parse ────────────────────────────

test "extractParamsBags: no `.params` anywhere → null (single-parse fast path)" {
    const src: [:0]const u8 =
        \\.{ .name = "game", .plugins = .{ .{ .name = "pathfinding", .version = "4.0.1" } } }
    ;
    try testing.expect((try extractParamsBags(testing.allocator, src)) == null);
}

test "extractParamsBags: every scalar shape lands in the bag; the span is blanked in place" {
    const src: [:0]const u8 =
        \\.{
        \\    .name = "game",
        \\    .plugins = .{
        \\        .{ .name = "acme", .params = .{
        \\            .label = "hud",
        \\            .grid_size = 32,
        \\            .gravity = 9.81,
        \\            .debug_draw = true,
        \\            .mode = .platformer,
        \\        } },
        \\    },
        \\}
    ;
    var extraction = (try extractParamsBags(testing.allocator, src)).?;
    defer extraction.deinitDeep(testing.allocator);

    try testing.expectEqual(@as(usize, 1), extraction.bags.len);
    const bag = extraction.bags[0].?;
    try testing.expectEqual(@as(usize, 5), bag.len);
    try testing.expectEqualStrings("label", bag[0].name);
    try testing.expectEqualStrings("hud", bag[0].value.str);
    try testing.expectEqualStrings("grid_size", bag[1].name);
    try testing.expectEqual(@as(i64, 32), bag[1].value.int);
    try testing.expectEqualStrings("gravity", bag[2].name);
    try testing.expectApproxEqAbs(@as(f64, 9.81), bag[2].value.float, 1e-12);
    try testing.expectEqualStrings("debug_draw", bag[3].name);
    try testing.expect(bag[3].value.boolean);
    try testing.expectEqualStrings("mode", bag[4].name);
    try testing.expectEqualStrings("platformer", bag[4].value.enum_tag);

    // Sanitized: byte length AND line structure preserved (the `}` slid
    // past the literal's opening line break — every newline survives), the
    // plugin-declared keys gone; everything outside the span untouched.
    try testing.expectEqual(src.len, extraction.sanitized.len);
    try testing.expectEqual(
        std.mem.count(u8, src, "\n"),
        std.mem.count(u8, extraction.sanitized, "\n"),
    );
    try testing.expect(std.mem.indexOf(u8, extraction.sanitized, ".params = .{") != null);
    try testing.expect(std.mem.indexOf(u8, extraction.sanitized, "grid_size") == null);
    try testing.expect(std.mem.indexOf(u8, extraction.sanitized, "platformer") == null);
    try testing.expect(std.mem.indexOf(u8, extraction.sanitized, ".name = \"acme\"") != null);
}

test "extractParamsBags: a single-line bag blanks byte-for-byte to `.{}` + spaces" {
    const src: [:0]const u8 =
        \\.{ .plugins = .{ .{ .name = "acme", .params = .{ .grid_size = 32 } } } }
    ;
    var extraction = (try extractParamsBags(testing.allocator, src)).?;
    defer extraction.deinitDeep(testing.allocator);

    // Everything outside the `.params` VALUE span is untouched; the span
    // itself becomes `.{}` padded with spaces to its exact original length.
    const span = ".{ .grid_size = 32 }";
    const start = std.mem.indexOf(u8, src, span).?;
    try testing.expectEqualStrings(src[0..start], extraction.sanitized[0..start]);
    try testing.expectEqualStrings(".{}", extraction.sanitized[start .. start + 3]);
    for (extraction.sanitized[start + 3 .. start + span.len]) |b| {
        try testing.expectEqual(@as(u8, ' '), b);
    }
    try testing.expectEqualStrings(src[start + span.len ..], extraction.sanitized[start + span.len ..]);
}

test "extractParamsBags: bags are index-aligned; params-less and empty-bag entries distinguished" {
    const src: [:0]const u8 =
        \\.{ .plugins = .{
        \\    .{ .name = "a" },
        \\    .{ .name = "b", .params = .{} },
        \\    .{ .name = "c", .params = .{ .x = 1 } },
        \\} }
    ;
    var extraction = (try extractParamsBags(testing.allocator, src)).?;
    defer extraction.deinitDeep(testing.allocator);
    try testing.expectEqual(@as(usize, 3), extraction.bags.len);
    try testing.expect(extraction.bags[0] == null);
    try testing.expectEqual(@as(usize, 0), extraction.bags[1].?.len);
    try testing.expectEqual(@as(usize, 1), extraction.bags[2].?.len);
}

test "extractParamsBags: a non-struct `.params` value errors naming the plugin" {
    const src: [:0]const u8 =
        \\.{ .plugins = .{ .{ .name = "acme", .params = "lua" } } }
    ;
    try testing.expectError(error.InvalidPluginParams, extractParamsBags(testing.allocator, src));
}

test "extractParamsBags: a nested (non-scalar) param value errors naming the key" {
    const src: [:0]const u8 =
        \\.{ .plugins = .{ .{ .name = "acme", .params = .{ .grid = .{ .w = 1 } } } } }
    ;
    try testing.expectError(error.InvalidPluginParams, extractParamsBags(testing.allocator, src));
}

test "extractParamsBags: an integer beyond i64 errors with the pointed hint" {
    const src: [:0]const u8 =
        \\.{ .plugins = .{ .{ .name = "acme", .params = .{ .n = 99999999999999999999999999 } } } }
    ;
    try testing.expectError(error.InvalidPluginParams, extractParamsBags(testing.allocator, src));
}

test "extractParamsBags: `.params` outside any plugin entry → null (typed parse owns it)" {
    // `.params` on the top level is not the plugin mechanism — the strict
    // typed parse rejects it as an unknown ProjectConfig field.
    const src: [:0]const u8 =
        \\.{ .name = "game", .params = .{ .x = 1 } }
    ;
    try testing.expect((try extractParamsBags(testing.allocator, src)) == null);
}

test "parseProjectConfig: heterogeneous bag parses; bag attached; other fields intact (#591)" {
    const src: [:0]const u8 =
        \\.{
        \\    .name = "params-game",
        \\    .plugins = .{
        \\        .{ .name = "pathfinder", .version = "4.0.1", .params = .{ .grid_size = 32, .mode = .platformer } },
        \\        .{ .name = "plain", .version = "1.0.0" },
        \\    },
        \\}
    ;
    // Arena, not `std.zon.parse.free`: a FULL ProjectConfig has fields the
    // zon freer chokes on (pre-existing — see the cache_cmd/init_cmd test
    // parses, which arena for the same reason). The extraction/attach
    // allocation hygiene is covered by the extractParamsBags tests above,
    // which do run under the leak-checking testing allocator.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = try parseProjectConfig(arena.allocator(), src);

    try testing.expectEqualStrings("params-game", cfg.name);
    try testing.expectEqual(@as(usize, 2), cfg.plugins.len);
    try testing.expectEqualStrings("4.0.1", cfg.plugins[0].version);
    const bag = cfg.plugins[0].params_bag.?;
    try testing.expectEqual(@as(usize, 2), bag.len);
    try testing.expectEqualStrings("grid_size", bag[0].name);
    try testing.expectEqual(@as(i64, 32), bag[0].value.int);
    try testing.expectEqualStrings("platformer", bag[1].value.enum_tag);
    try testing.expect(cfg.plugins[1].params_bag == null);
    // The blanked `.{}` parses to a present-but-empty typed Params.
    try testing.expect(cfg.plugins[0].params != null);
    try testing.expect(cfg.plugins[0].params.?.language == null);
}

test "parseProjectConfig: `.plugin_events = .all` parses; omitted defaults to .consumed (#630)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const src_all: [:0]const u8 =
        \\.{
        \\    .name = "all-events-game",
        \\    .plugin_events = .all,
        \\}
    ;
    const cfg_all = try parseProjectConfig(arena.allocator(), src_all);
    try testing.expectEqual(config.PluginEventsMode.all, cfg_all.plugin_events);

    // Omitted key → the consumption filter is the default.
    const src_default: [:0]const u8 =
        \\.{ .name = "default-events-game" }
    ;
    const cfg_default = try parseProjectConfig(arena.allocator(), src_default);
    try testing.expectEqual(config.PluginEventsMode.consumed, cfg_default.plugin_events);
}

test "parseProjectConfig: the legacy `.language` bag keeps its typed spelling AND rides the bag (#589 compat)" {
    const src: [:0]const u8 =
        \\.{
        \\    .name = "lua-game",
        \\    .plugins = .{
        \\        .{ .name = "labelle-scripting", .version = "0.1.0", .params = .{ .language = "lua" } },
        \\    },
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = try parseProjectConfig(arena.allocator(), src);

    const bag = cfg.plugins[0].params_bag.?;
    try testing.expectEqual(@as(usize, 1), bag.len);
    try testing.expectEqualStrings("language", bag[0].name);
    try testing.expectEqualStrings("lua", bag[0].value.str);
    // The language policy reads the declaration through declaredLanguage.
    try testing.expectEqualStrings("lua", cfg.plugins[0].declaredLanguage().?);
}

test "parseProjectConfig: no `.params` in the source is the plain typed parse (byte-identical path)" {
    const src: [:0]const u8 =
        \\.{ .name = "plain-game", .plugins = .{ .{ .name = "pathfinding", .version = "4.0.1" } } }
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = try parseProjectConfig(arena.allocator(), src);
    try testing.expectEqualStrings("plain-game", cfg.name);
    try testing.expect(cfg.plugins[0].params == null);
    try testing.expect(cfg.plugins[0].params_bag == null);
}

test "parseProjectConfig: strictness outside `.params` is untouched — a typo'd key still hard-fails" {
    const src: [:0]const u8 =
        \\.{
        \\    .name = "typo-game",
        \\    .plugins = .{
        \\        .{ .name = "acme", .verzion = "1.0.0", .params = .{ .x = 1 } },
        \\    },
        \\}
    ;
    // Arena: the std parser's unknown-field error allocates a "supported: …"
    // note that only a non-null Diagnostics ever frees (the #589 config test
    // passes `&diag` for the same reason); parseProjectConfig — like every
    // pre-#591 readProjectConfig — parses diag-less.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.ParseZon, parseProjectConfig(arena.allocator(), src));
}

test "parseProjectConfig: a syntax error defers to the typed parser's own diagnostics" {
    const src: [:0]const u8 =
        \\.{ .name = "broken" .plugins = .{} }
    ;
    try testing.expectError(error.ParseZon, parseProjectConfig(testing.allocator, src));
}

// ── layer 2: schema parse ────────────────────────────────────────────

test "parseSchemaFromManifestSource: absent key → empty schema (byte-identity default)" {
    const src: [:0]const u8 =
        \\.{ .name = "acme", .manifest_version = 1 }
    ;
    const schema = try parseSchemaFromManifestSource(testing.allocator, src, "acme");
    defer freeSchema(testing.allocator, schema);
    try testing.expectEqual(@as(usize, 0), schema.len);
}

test "parseSchemaFromManifestSource: every type parses — defaults typed, natural literals" {
    const src: [:0]const u8 =
        \\.{
        \\    .name = "acme",
        \\    .manifest_version = 1,
        \\    .params_schema = .{
        \\        .{ .name = "label", .type = .str, .default = "hud" },
        \\        .{ .name = "grid_size", .type = .i64, .default = 32 },
        \\        .{ .name = "gravity", .type = .f64, .default = 9.81 },
        \\        .{ .name = "debug_draw", .type = .bool, .default = false },
        \\        .{ .name = "mode", .type = .@"enum", .values = .{ "platformer", "topdown" }, .default = "platformer" },
        \\        .{ .name = "seed", .type = .i64, .required = true },
        \\    },
        \\}
    ;
    const schema = try parseSchemaFromManifestSource(testing.allocator, src, "acme");
    defer freeSchema(testing.allocator, schema);

    try testing.expectEqual(@as(usize, 6), schema.len);
    try testing.expectEqualStrings("label", schema[0].name);
    try testing.expectEqual(ParamType.str, schema[0].type);
    try testing.expectEqualStrings("hud", schema[0].default.?.str);
    try testing.expectEqual(@as(i64, 32), schema[1].default.?.int);
    try testing.expectApproxEqAbs(@as(f64, 9.81), schema[2].default.?.float, 1e-12);
    try testing.expect(!schema[3].default.?.boolean);
    try testing.expectEqual(ParamType.@"enum", schema[4].type);
    try testing.expectEqual(@as(usize, 2), schema[4].values.len);
    // Enum defaults normalize to the enum_tag spelling.
    try testing.expectEqualStrings("platformer", schema[4].default.?.enum_tag);
    try testing.expect(schema[5].required);
    try testing.expect(schema[5].default == null);
}

test "parseSchemaFromManifestSource: an int default on an f64 param widens (ZON coercion mirrored)" {
    const src: [:0]const u8 =
        \\.{ .params_schema = .{ .{ .name = "gravity", .type = .f64, .default = 10 } } }
    ;
    const schema = try parseSchemaFromManifestSource(testing.allocator, src, "acme");
    defer freeSchema(testing.allocator, schema);
    try testing.expectApproxEqAbs(@as(f64, 10.0), schema[0].default.?.float, 1e-12);
}

test "parseSchemaFromManifestSource: unknown entry keys hard-fail (the ticket's rule)" {
    const src: [:0]const u8 =
        \\.{ .params_schema = .{ .{ .name = "seed", .type = .i64, .requird = true } } }
    ;
    try testing.expectError(
        error.PluginManifestInvalidParamsSchema,
        parseSchemaFromManifestSource(testing.allocator, src, "acme"),
    );
}

test "parseSchemaFromManifestSource: shape rules reject at load" {
    const cases = [_][:0]const u8{
        // missing name / missing type
        \\.{ .params_schema = .{ .{ .type = .i64 } } }
        ,
        \\.{ .params_schema = .{ .{ .name = "seed" } } }
        ,
        // unknown type
        \\.{ .params_schema = .{ .{ .name = "seed", .type = .u128 } } }
        ,
        // enum without values / empty values / values on a non-enum
        \\.{ .params_schema = .{ .{ .name = "mode", .type = .@"enum" } } }
        ,
        \\.{ .params_schema = .{ .{ .name = "mode", .type = .@"enum", .values = .{} } } }
        ,
        \\.{ .params_schema = .{ .{ .name = "seed", .type = .i64, .values = .{ "a" } } } }
        ,
        // vocabulary entry that can't be a Zig enum tag
        \\.{ .params_schema = .{ .{ .name = "mode", .type = .@"enum", .values = .{ "no spaces" } } } }
        ,
        // default/type mismatch + enum default outside the vocabulary
        \\.{ .params_schema = .{ .{ .name = "seed", .type = .i64, .default = "x" } } }
        ,
        \\.{ .params_schema = .{ .{ .name = "mode", .type = .@"enum", .values = .{ "a" }, .default = "b" } } }
        ,
        // required × default contradiction
        \\.{ .params_schema = .{ .{ .name = "seed", .type = .i64, .default = 1, .required = true } } }
        ,
        // duplicate param names
        \\.{ .params_schema = .{ .{ .name = "seed", .type = .i64 }, .{ .name = "seed", .type = .str } } }
        ,
        // a name that can't be a Zig decl
        \\.{ .params_schema = .{ .{ .name = "Grid-Size", .type = .i64 } } }
        ,
        // duplicate enum vocabulary entry (would RENDER `enum { topdown,
        // topdown }` — a generated module that fails to compile) (#591 P2)
        \\.{ .params_schema = .{ .{ .name = "mode", .type = .@"enum", .values = .{ "topdown", "topdown" } } } }
        ,
        // two enum params normalizing to the SAME PascalCase type decl
        // (`mode` / `mode_` → `Mode`) — duplicate `pub const Mode` (#591 P2)
        \\.{ .params_schema = .{
        \\    .{ .name = "mode", .type = .@"enum", .values = .{ "a" } },
        \\    .{ .name = "mode_", .type = .@"enum", .values = .{ "b" } },
        \\} }
        ,
        // same collision through underscore runs (`foo_bar` / `foo__bar`)
        \\.{ .params_schema = .{
        \\    .{ .name = "foo_bar", .type = .@"enum", .values = .{ "a" } },
        \\    .{ .name = "foo__bar", .type = .@"enum", .values = .{ "b" } },
        \\} }
        ,
    };
    for (cases) |src| {
        try testing.expectError(
            error.PluginManifestInvalidParamsSchema,
            parseSchemaFromManifestSource(testing.allocator, src, "acme"),
        );
    }
}

test "parseSchemaFromManifestSource: distinct PascalCase enums + a non-enum near-name are NOT collisions" {
    // Positive control for the #591 P2 collision checks: `mode` (enum) vs
    // `mode_kind` (enum, distinct PascalCase) vs `mode_` (a NON-enum param —
    // it renders no type decl, so its PascalCase twin never exists).
    const src: [:0]const u8 =
        \\.{ .params_schema = .{
        \\    .{ .name = "mode", .type = .@"enum", .values = .{ "a", "b" } },
        \\    .{ .name = "mode_kind", .type = .@"enum", .values = .{ "x" } },
        \\    .{ .name = "mode_", .type = .i64, .default = 1 },
        \\} }
    ;
    const schema = try parseSchemaFromManifestSource(testing.allocator, src, "acme");
    defer freeSchema(testing.allocator, schema);
    try testing.expectEqual(@as(usize, 3), schema.len);
}

// ── layer 3: validation + resolution ────────────────────────────────

const test_schema = [_]ParamSchema{
    .{ .name = "grid_size", .type = .i64, .default = .{ .int = 32 } },
    .{ .name = "mode", .type = .@"enum", .values = &.{ "platformer", "topdown" }, .required = true },
    .{ .name = "gravity", .type = .f64, .default = .{ .float = 9.81 } },
    .{ .name = "label", .type = .str },
};

test "validateAndResolve: schema-less + empty bag → null (no module, byte identity)" {
    try testing.expect((try validateAndResolve(testing.allocator, "plain", &.{}, &.{})) == null);
}

test "validateAndResolve: schema-less + the singular string `language` → null (native fast path, #589 pins)" {
    const bag = [_]Param{.{ .name = "language", .value = .{ .str = "lua" } }};
    try testing.expect((try validateAndResolve(testing.allocator, "labelle-scripting", &bag, &.{})) == null);
}

test "validateAndResolve: schema-less + any other param is an unknown-param error" {
    const bag = [_]Param{.{ .name = "grid_size", .value = .{ .int = 32 } }};
    try testing.expectError(
        error.UnknownPluginParam,
        validateAndResolve(testing.allocator, "plain", &bag, &.{}),
    );
    // Even beside a legal language entry.
    const mixed = [_]Param{
        .{ .name = "language", .value = .{ .str = "lua" } },
        .{ .name = "grid_size", .value = .{ .int = 32 } },
    };
    try testing.expectError(
        error.UnknownPluginParam,
        validateAndResolve(testing.allocator, "plain", &mixed, &.{}),
    );
}

test "validateAndResolve: schema SUPERSEDES — an undeclared `language` is unknown once a schema exists" {
    const bag = [_]Param{.{ .name = "language", .value = .{ .str = "lua" } }};
    try testing.expectError(
        error.UnknownPluginParam,
        validateAndResolve(testing.allocator, "acme", &bag, &test_schema),
    );
}

test "validateAndResolve: project values + defaults resolve in schema order; optionals without defaults omitted" {
    const bag = [_]Param{
        .{ .name = "mode", .value = .{ .enum_tag = "topdown" } },
        .{ .name = "grid_size", .value = .{ .int = 64 } },
    };
    const resolved = (try validateAndResolve(testing.allocator, "acme", &bag, &test_schema)).?;
    defer freeResolved(testing.allocator, resolved);

    // Schema order — not bag order; `label` (optional, no default) omitted.
    try testing.expectEqual(@as(usize, 3), resolved.len);
    try testing.expectEqualStrings("grid_size", resolved[0].name);
    try testing.expectEqual(@as(i64, 64), resolved[0].value.int);
    try testing.expectEqualStrings("mode", resolved[1].name);
    try testing.expectEqualStrings("topdown", resolved[1].value.enum_tag);
    try testing.expectEqualStrings("gravity", resolved[2].name);
    try testing.expectApproxEqAbs(@as(f64, 9.81), resolved[2].value.float, 1e-12);
}

test "validateAndResolve: enum accepts the string spelling too; int widens onto f64" {
    const bag = [_]Param{
        .{ .name = "mode", .value = .{ .str = "platformer" } },
        .{ .name = "gravity", .value = .{ .int = 10 } },
    };
    const resolved = (try validateAndResolve(testing.allocator, "acme", &bag, &test_schema)).?;
    defer freeResolved(testing.allocator, resolved);
    try testing.expectEqualStrings("platformer", resolved[1].value.enum_tag);
    try testing.expectApproxEqAbs(@as(f64, 10.0), resolved[2].value.float, 1e-12);
}

test "validateAndResolve: unknown param names the accepted set" {
    const bag = [_]Param{
        .{ .name = "mode", .value = .{ .str = "topdown" } },
        .{ .name = "grid_sise", .value = .{ .int = 64 } },
    };
    try testing.expectError(
        error.UnknownPluginParam,
        validateAndResolve(testing.allocator, "acme", &bag, &test_schema),
    );
}

test "validateAndResolve: wrong type errors per class" {
    const wrong_int = [_]Param{
        .{ .name = "mode", .value = .{ .str = "topdown" } },
        .{ .name = "grid_size", .value = .{ .str = "32" } },
    };
    try testing.expectError(
        error.PluginParamTypeMismatch,
        validateAndResolve(testing.allocator, "acme", &wrong_int, &test_schema),
    );
    const wrong_str = [_]Param{
        .{ .name = "mode", .value = .{ .str = "topdown" } },
        .{ .name = "label", .value = .{ .int = 1 } },
    };
    try testing.expectError(
        error.PluginParamTypeMismatch,
        validateAndResolve(testing.allocator, "acme", &wrong_str, &test_schema),
    );
    // A float does NOT narrow onto i64.
    const float_on_int = [_]Param{
        .{ .name = "mode", .value = .{ .str = "topdown" } },
        .{ .name = "grid_size", .value = .{ .float = 32.5 } },
    };
    try testing.expectError(
        error.PluginParamTypeMismatch,
        validateAndResolve(testing.allocator, "acme", &float_on_int, &test_schema),
    );
}

test "validateAndResolve: out-of-vocabulary enum lists the allowed values" {
    const bag = [_]Param{.{ .name = "mode", .value = .{ .enum_tag = "sideways" } }};
    try testing.expectError(
        error.PluginParamInvalidEnumValue,
        validateAndResolve(testing.allocator, "acme", &bag, &test_schema),
    );
}

test "validateAndResolve: missing required errors naming plugin + param + expectation" {
    try testing.expectError(
        error.MissingRequiredPluginParam,
        validateAndResolve(testing.allocator, "acme", &.{}, &test_schema),
    );
}

// ── layer 3: emission golden ─────────────────────────────────────────

/// Run Zig's front-end (parse → AstGen) over `src`, failing on any parse or
/// AstGen-level error — the emitted module must always compile.
fn expectAstGenOk(src: []const u8) !void {
    const src_z = try testing.allocator.dupeZ(u8, src);
    defer testing.allocator.free(src_z);
    var ast = try std.zig.Ast.parse(testing.allocator, src_z, .zig);
    defer ast.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), ast.errors.len);
    var zir = try std.zig.AstGen.generate(testing.allocator, ast);
    defer zir.deinit(testing.allocator);
    try testing.expect(!zir.hasCompileErrors());
}

test "renderParamsModule: golden — every type, deterministic text, compiles" {
    const params = [_]ResolvedParam{
        .{ .name = "grid_size", .type = .i64, .values = &.{}, .value = .{ .int = 64 } },
        .{ .name = "mode", .type = .@"enum", .values = &.{ "platformer", "topdown" }, .value = .{ .enum_tag = "topdown" } },
        .{ .name = "gravity", .type = .f64, .values = &.{}, .value = .{ .float = 9.81 } },
        .{ .name = "debug_draw", .type = .bool, .values = &.{}, .value = .{ .boolean = false } },
        .{ .name = "label", .type = .str, .values = &.{}, .value = .{ .str = "hud \"main\"" } },
    };
    const module = try renderParamsModule(testing.allocator, "pathfinder", &params);
    defer testing.allocator.free(module);

    try testing.expectEqualStrings(
        \\//! Generated by labelle-assembler (#591) — resolved `.params` for plugin 'pathfinder'.
        \\//! Comptime plugin configuration: the assembler injects this module into the
        \\//! plugin as `@import("plugin_params")`. Do not edit; regenerated every `labelle generate`.
        \\
        \\pub const grid_size: i64 = 64;
        \\
        \\pub const Mode = enum { platformer, topdown };
        \\pub const mode: Mode = .topdown;
        \\
        \\pub const gravity: f64 = 9.81;
        \\
        \\pub const debug_draw: bool = false;
        \\
        \\pub const label: []const u8 = "hud \"main\"";
        \\
    , module);
    try expectAstGenOk(module);
}

test "renderParamsModule: keyword-shaped enum tags quote via fmtId and still compile" {
    const params = [_]ResolvedParam{
        .{ .name = "on_fail", .type = .@"enum", .values = &.{ "@\"error\"", "ignore" }, .value = .{ .enum_tag = "ignore" } },
    };
    // NOTE: values are validated identifiers at schema load ("error" IS a
    // valid identifier lexically); fmtId quotes it on emission.
    const raw = [_]ResolvedParam{
        .{ .name = "on_fail", .type = .@"enum", .values = &.{ "error", "ignore" }, .value = .{ .enum_tag = "error" } },
    };
    _ = params;
    const module = try renderParamsModule(testing.allocator, "acme", &raw);
    defer testing.allocator.free(module);
    try testing.expect(std.mem.indexOf(u8, module, "enum { @\"error\", ignore }") != null);
    try testing.expect(std.mem.indexOf(u8, module, "pub const on_fail: OnFail = .@\"error\";") != null);
    try expectAstGenOk(module);
}

test "stagedName agrees with the build.zig emitter's b.path spelling" {
    const name = try stagedName(testing.allocator, "pathfinder");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("plugin_pathfinder_params.zig", name);
}
