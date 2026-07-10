//! Generate-time validation of studio plugin panels — labelle-assembler#577
//! (Asset Plugins Phase 3, RFC-ASSET-PLUGINS rev 4, engine #725/#729).
//!
//! A plugin (or a pack it bundles) ships one or more declarative
//! `studio/<name>.panel.jsonc` files describing a small form the studio
//! renders with its OWN kit — the plugin never ships editor JS. This pass
//! validates every such descriptor at `labelle generate` time, alongside the
//! Phase-1/2 asset + pack validation, so **the studio never sees an invalid
//! panel from a generated project**: a malformed panel is a build error with a
//! file (and, for parse errors, line) location, not a studio-side surprise.
//!
//! The reference schema is the studio POC's zod schema
//! (`labelle-studio` `src/services/pluginPanels.ts`, PR #73); this is a
//! faithful Zig port of it so the two agree on what a valid panel is:
//!
//! ```jsonc
//! {
//!   "id": "dungeon_generator",           // identifier
//!   "title": "Dungeon Generator",        // non-empty
//!   "icon": "grid",                       // optional hint
//!   "fields": [
//!     { "name": "seed",    "type": "number", "default": 42 },
//!     { "name": "density", "type": "slider", "min": 0.1, "max": 1.0, "default": 0.5 },
//!     { "name": "theme",   "type": "select", "options": ["stone", "crypt"] }
//!   ],
//!   "actions": [
//!     { "label": "Generate", "command": "generate", "target": "preview" }
//!   ]
//! }
//! ```
//!
//! Checks (mirrors the zod schema + its per-branch semantic pass):
//!   - top-level object with only `id/title/icon/fields/actions` (strict);
//!   - `id` an identifier, `title` non-empty, `icon` an optional string;
//!   - each field discriminated on `type` ∈ {number, slider, select, text,
//!     toggle}, strict per-branch keys, `name` non-empty; `slider` requires
//!     numeric `min`+`max`; `select` requires a non-empty `options` array;
//!   - each action has a non-empty `label`, an identifier `command`, and a
//!     `target` ∈ {preview, cli} (strict);
//!   - semantic: duplicate field names; `min > max`; a `default` outside
//!     `min..max`; a `select` `default` not among its `options`.
//!
//! All problems for one file are collected (an author fixes them in one pass),
//! each rendered as `<file>: <where>: <problem>` — the same shape the studio's
//! rules sidecar uses, because a panel author's error text is an agent's
//! compiler output.
//!
//! NOTE (deferred, pairs with engine#729): the RFC also calls for a
//! `"target": "preview"` command to name a handler the plugin's code declares.
//! The engine side declares handlers by RUNTIME subscription to the
//! `engine__editor_plugin_command` event (no static manifest of handler names
//! exists at generate time), so that cross-check can't be done here yet without
//! a declared-handler list. Tracked as a follow-up; the schema/semantic gate
//! below is the bulk of the acceptance ("the studio never sees an invalid
//! panel").

const std = @import("std");
const config = @import("config.zig");
const cache = @import("cache.zig");
const plugin_manifest = @import("plugin_manifest.zig");

/// The convention directory panels live in (`<unit>/studio/*.panel.jsonc`).
pub const STUDIO_DIR = "studio";
/// The panel-file suffix (matches the studio's `PANEL_SUFFIX`).
pub const PANEL_SUFFIX = ".panel.jsonc";
/// Panels are tiny declarative forms; cap the read so a mis-placed asset
/// under `studio/` can't turn validation into an unbounded read.
const MAX_PANEL_BYTES: usize = 256 * 1024;

/// Raised when any discovered panel fails validation. The per-error
/// diagnostics are printed before this is returned.
pub const Error = error{InvalidPanelDescriptor};

const Errors = std.ArrayList([]const u8);
const AllocErr = std.mem.Allocator.Error;

// ── Pure schema + semantic validation (no filesystem) ───────────────────

/// Validate one panel `source` (raw `.panel.jsonc` bytes) named `rel_path`
/// (used verbatim as the error prefix). Every problem is appended to `errors`
/// as an owned `<rel_path>: <where>: <problem>` string the caller must free.
/// Returns without appending when the panel is valid.
pub fn validatePanelSource(
    allocator: std.mem.Allocator,
    rel_path: []const u8,
    source: []const u8,
    errors: *Errors,
) AllocErr!void {
    const stripped = try stripJsonc(allocator, source);
    defer allocator.free(stripped);

    // Parse via the Scanner so a syntax error carries a line number (the
    // JSONC-strip preserves byte offsets, so the line lines up with the
    // original file).
    var scanner = std.json.Scanner.initCompleteInput(allocator, stripped);
    defer scanner.deinit();
    var diag: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diag);

    var parsed = std.json.parseFromTokenSource(std.json.Value, allocator, &scanner, .{}) catch {
        try addLine(allocator, errors, rel_path, "line {d}: not valid JSONC", .{diag.getLine()});
        return;
    };
    defer parsed.deinit();

    try validatePanelValue(allocator, rel_path, parsed.value, errors);
}

/// Validate an already-parsed panel `std.json.Value`. Split out so tests can
/// drive the semantic checks directly and the file path stays a pure prefix.
fn validatePanelValue(
    allocator: std.mem.Allocator,
    rel_path: []const u8,
    root: std.json.Value,
    errors: *Errors,
) AllocErr!void {
    const obj = switch (root) {
        .object => |o| o,
        else => {
            try addAt(allocator, errors, rel_path, "<root>", "panel must be a JSON object", .{});
            return;
        },
    };

    // Strict top-level keys.
    {
        var it = obj.iterator();
        while (it.next()) |entry| {
            const k = entry.key_ptr.*;
            if (!isOneOf(k, &.{ "id", "title", "icon", "fields", "actions" }))
                try addAt(allocator, errors, rel_path, k, "unrecognized key", .{});
        }
    }

    // id: required identifier.
    if (obj.get("id")) |v| {
        switch (v) {
            .string => |s| if (!isIdentifier(s))
                try addAt(allocator, errors, rel_path, "id", "must be an identifier ([A-Za-z_][A-Za-z0-9_]*)", .{}),
            else => try addAt(allocator, errors, rel_path, "id", "must be a string", .{}),
        }
    } else try addAt(allocator, errors, rel_path, "id", "required", .{});

    // title: required non-empty string.
    if (obj.get("title")) |v| {
        switch (v) {
            .string => |s| if (s.len == 0)
                try addAt(allocator, errors, rel_path, "title", "must not be empty", .{}),
            else => try addAt(allocator, errors, rel_path, "title", "must be a string", .{}),
        }
    } else try addAt(allocator, errors, rel_path, "title", "required", .{});

    // icon: optional string.
    if (obj.get("icon")) |v| switch (v) {
        .string => {},
        else => try addAt(allocator, errors, rel_path, "icon", "must be a string", .{}),
    };

    // fields: optional array of field objects.
    if (obj.get("fields")) |v| {
        switch (v) {
            .array => |arr| try validateFields(allocator, rel_path, arr, errors),
            else => try addAt(allocator, errors, rel_path, "fields", "must be an array", .{}),
        }
    }

    // actions: optional array of action objects.
    if (obj.get("actions")) |v| {
        switch (v) {
            .array => |arr| try validateActions(allocator, rel_path, arr, errors),
            else => try addAt(allocator, errors, rel_path, "actions", "must be an array", .{}),
        }
    }
}

const FIELD_TYPES = [_][]const u8{ "number", "slider", "select", "text", "toggle" };

fn validateFields(
    allocator: std.mem.Allocator,
    rel_path: []const u8,
    arr: std.json.Array,
    errors: *Errors,
) AllocErr!void {
    // Track field names to flag duplicates (they'd collide as dispatch keys).
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(allocator);

    for (arr.items, 0..) |item, i| {
        const obj = switch (item) {
            .object => |o| o,
            else => {
                try addField(allocator, errors, rel_path, i, null, "must be an object", .{});
                continue;
            },
        };

        // `type` discriminator.
        const type_val = obj.get("type") orelse {
            try addField(allocator, errors, rel_path, i, null, "missing `type`", .{});
            continue;
        };
        const ftype = switch (type_val) {
            .string => |s| s,
            else => {
                try addField(allocator, errors, rel_path, i, null, "`type` must be a string", .{});
                continue;
            },
        };
        if (!isOneOf(ftype, &FIELD_TYPES)) {
            try addField(allocator, errors, rel_path, i, null, "unknown field type \"{s}\" (one of number/slider/select/text/toggle)", .{ftype});
            continue;
        }

        // name: required non-empty string, common to every branch.
        const name: ?[]const u8 = switch (obj.get("name") orelse std.json.Value{ .null = {} }) {
            .string => |s| if (s.len == 0) null else s,
            else => null,
        };
        if (name == null)
            try addField(allocator, errors, rel_path, i, null, "`name` must be a non-empty string", .{});

        // Strict per-branch key set.
        const allowed: []const []const u8 = if (std.mem.eql(u8, ftype, "select"))
            &.{ "type", "name", "options", "default" }
        else if (std.mem.eql(u8, ftype, "number") or std.mem.eql(u8, ftype, "slider"))
            &.{ "type", "name", "min", "max", "default" }
        else // text, toggle
            &.{ "type", "name", "default" };
        {
            var it = obj.iterator();
            while (it.next()) |e| {
                if (!isOneOf(e.key_ptr.*, allowed))
                    try addField(allocator, errors, rel_path, i, name, "unrecognized key \"{s}\" for a {s} field", .{ e.key_ptr.*, ftype });
            }
        }

        try validateFieldBranch(allocator, rel_path, i, name, ftype, obj, errors);

        // Duplicate-name check (only meaningful for a valid name).
        if (name) |n| {
            for (seen.items) |prev| {
                if (std.mem.eql(u8, prev, n)) {
                    try addField(allocator, errors, rel_path, i, name, "duplicate field name", .{});
                    break;
                }
            }
            try seen.append(allocator, n);
        }
    }
}

fn validateFieldBranch(
    allocator: std.mem.Allocator,
    rel_path: []const u8,
    idx: usize,
    name: ?[]const u8,
    ftype: []const u8,
    obj: std.json.ObjectMap,
    errors: *Errors,
) AllocErr!void {
    if (std.mem.eql(u8, ftype, "number") or std.mem.eql(u8, ftype, "slider")) {
        const is_slider = std.mem.eql(u8, ftype, "slider");
        const min = try numberField(allocator, rel_path, idx, name, obj, "min", is_slider, errors);
        const max = try numberField(allocator, rel_path, idx, name, obj, "max", is_slider, errors);
        const default = try numberField(allocator, rel_path, idx, name, obj, "default", false, errors);

        if (min != null and max != null and min.? > max.?)
            try addField(allocator, errors, rel_path, idx, name, "min ({d}) exceeds max ({d})", .{ min.?, max.? });
        if (default) |d| {
            if ((min != null and d < min.?) or (max != null and d > max.?))
                try addField(allocator, errors, rel_path, idx, name, "default ({d}) is outside min..max", .{d});
        }
    } else if (std.mem.eql(u8, ftype, "select")) {
        try validateSelect(allocator, rel_path, idx, name, obj, errors);
    } else if (std.mem.eql(u8, ftype, "text")) {
        if (obj.get("default")) |v| switch (v) {
            .string => {},
            else => try addField(allocator, errors, rel_path, idx, name, "`default` must be a string", .{}),
        };
    } else if (std.mem.eql(u8, ftype, "toggle")) {
        if (obj.get("default")) |v| switch (v) {
            .bool => {},
            else => try addField(allocator, errors, rel_path, idx, name, "`default` must be a boolean", .{}),
        };
    }
}

/// Read a numeric field. `required` flags a hard-required key (slider min/max);
/// a present-but-non-numeric value is always an error. Returns the value when
/// present and numeric, else null.
fn numberField(
    allocator: std.mem.Allocator,
    rel_path: []const u8,
    idx: usize,
    name: ?[]const u8,
    obj: std.json.ObjectMap,
    key: []const u8,
    required: bool,
    errors: *Errors,
) AllocErr!?f64 {
    if (obj.get(key)) |v| {
        switch (v) {
            .integer => |n| return @floatFromInt(n),
            .float => |f| return f,
            else => {
                try addField(allocator, errors, rel_path, idx, name, "`{s}` must be a number", .{key});
                return null;
            },
        }
    }
    if (required)
        try addField(allocator, errors, rel_path, idx, name, "a slider requires a numeric `{s}`", .{key});
    return null;
}

fn validateSelect(
    allocator: std.mem.Allocator,
    rel_path: []const u8,
    idx: usize,
    name: ?[]const u8,
    obj: std.json.ObjectMap,
    errors: *Errors,
) AllocErr!void {
    const options_val = obj.get("options") orelse {
        try addField(allocator, errors, rel_path, idx, name, "a select requires an `options` array", .{});
        return;
    };
    const options = switch (options_val) {
        .array => |a| a,
        else => {
            try addField(allocator, errors, rel_path, idx, name, "`options` must be an array", .{});
            return;
        },
    };
    if (options.items.len == 0)
        try addField(allocator, errors, rel_path, idx, name, "`options` must have at least one entry", .{});

    var all_strings = true;
    for (options.items) |opt| switch (opt) {
        .string => |s| if (s.len == 0) {
            all_strings = false;
            try addField(allocator, errors, rel_path, idx, name, "`options` entries must be non-empty strings", .{});
        },
        else => {
            all_strings = false;
            try addField(allocator, errors, rel_path, idx, name, "`options` entries must be strings", .{});
        },
    };

    // default: optional string that must be one of the options.
    if (obj.get("default")) |v| switch (v) {
        .string => |d| {
            if (all_strings) {
                var found = false;
                for (options.items) |opt| switch (opt) {
                    .string => |s| if (std.mem.eql(u8, s, d)) {
                        found = true;
                    },
                    else => {},
                };
                if (!found)
                    try addField(allocator, errors, rel_path, idx, name, "default \"{s}\" is not one of the options", .{d});
            }
        },
        else => try addField(allocator, errors, rel_path, idx, name, "`default` must be a string", .{}),
    };
}

fn validateActions(
    allocator: std.mem.Allocator,
    rel_path: []const u8,
    arr: std.json.Array,
    errors: *Errors,
) AllocErr!void {
    for (arr.items, 0..) |item, i| {
        const obj = switch (item) {
            .object => |o| o,
            else => {
                try addAction(allocator, errors, rel_path, i, "must be an object", .{});
                continue;
            },
        };

        // Strict keys.
        {
            var it = obj.iterator();
            while (it.next()) |e| {
                if (!isOneOf(e.key_ptr.*, &.{ "label", "command", "target" }))
                    try addAction(allocator, errors, rel_path, i, "unrecognized key \"{s}\"", .{e.key_ptr.*});
            }
        }

        switch (obj.get("label") orelse std.json.Value{ .null = {} }) {
            .string => |s| if (s.len == 0)
                try addAction(allocator, errors, rel_path, i, "`label` must not be empty", .{}),
            else => try addAction(allocator, errors, rel_path, i, "`label` must be a non-empty string", .{}),
        }
        switch (obj.get("command") orelse std.json.Value{ .null = {} }) {
            .string => |s| if (!isIdentifier(s))
                try addAction(allocator, errors, rel_path, i, "`command` must be an identifier ([A-Za-z_][A-Za-z0-9_]*)", .{}),
            else => try addAction(allocator, errors, rel_path, i, "`command` must be a string", .{}),
        }
        switch (obj.get("target") orelse std.json.Value{ .null = {} }) {
            .string => |s| if (!isOneOf(s, &.{ "preview", "cli" }))
                try addAction(allocator, errors, rel_path, i, "`target` must be \"preview\" or \"cli\"", .{}),
            else => try addAction(allocator, errors, rel_path, i, "`target` must be \"preview\" or \"cli\"", .{}),
        }
    }
}

// ── Discovery + filesystem entry point ──────────────────────────────────

/// Discover and validate every `studio/*.panel.jsonc` a declared plugin (or a
/// pack it DECLARES) ships, printing a diagnostic per problem. Returns
/// `error.InvalidPanelDescriptor` if any panel is invalid. Additive: a project
/// with no panels is unaffected, and a plugin dir that can't be resolved/read
/// is skipped (other passes report a genuinely missing plugin).
pub fn validatePluginPanels(
    allocator: std.mem.Allocator,
    cfg: config.ProjectConfig,
    game_dir: []const u8,
) !void {
    var errors: Errors = .empty;
    defer {
        for (errors.items) |e| allocator.free(e);
        errors.deinit(allocator);
    }

    try collectPluginPanelErrors(allocator, cfg, game_dir, &errors);

    if (errors.items.len == 0) return;

    for (errors.items) |e|
        std.debug.print("labelle-assembler: invalid studio panel: {s}\n", .{e});
    return Error.InvalidPanelDescriptor;
}

/// The scoped discovery: for each declared plugin, validate ONLY (a) the
/// plugin-root `studio/` dir and (b) the `studio/` dir of each pack the plugin
/// DECLARES in `plugin.labelle`'s `.packs` — the exact set the pack-discovery
/// path registers (`generate_phases.discoverNestedPacks`). It deliberately does
/// NOT walk every descendant directory: an UNDECLARED pack (e.g.
/// `packs/experimental/`) or a non-shipped `examples/` tree is not part of
/// generation, so a broken panel there must never fail `labelle generate`
/// (assembler#588 review). Split from `validatePluginPanels` so tests can
/// inspect the collected diagnostics.
fn collectPluginPanelErrors(
    allocator: std.mem.Allocator,
    cfg: config.ProjectConfig,
    game_dir: []const u8,
    errors: *Errors,
) !void {
    for (cfg.plugins) |plugin| {
        const plugin_dir = cache.resolvePlugin(allocator, plugin, game_dir) catch continue;
        defer allocator.free(plugin_dir);

        // (a) The plugin's OWN `studio/` (the plugin itself is declared in
        //     project.labelle, so this is always shipped).
        try scanStudioDir(allocator, plugin_dir, plugin_dir, errors);

        // (b) Only the packs the plugin DECLARES via `plugin.labelle .packs`.
        //     A plugin with no `plugin.labelle` (or an empty `.packs`) adds
        //     nothing here — same tolerance the pack-discovery path has.
        var pmani = (plugin_manifest.loadOptional(allocator, plugin, game_dir) catch continue) orelse continue;
        defer pmani.deinit();
        for (pmani.packs) |nested_name| {
            const pack_dir = try std.fs.path.join(allocator, &.{ plugin_dir, "packs", nested_name });
            defer allocator.free(pack_dir);
            try scanStudioDir(allocator, plugin_dir, pack_dir, errors);
        }
    }
}

/// Validate the panel files DIRECTLY in `<unit_dir_abs>/studio/` (non-recursive
/// — a `studio/` dir is a flat file list by convention). `root_abs` anchors the
/// unit-relative path used in diagnostics. A missing `studio/` dir is a no-op.
fn scanStudioDir(
    allocator: std.mem.Allocator,
    root_abs: []const u8,
    unit_dir_abs: []const u8,
    errors: *Errors,
) AllocErr!void {
    const io = config.globalIo();
    const studio_abs = try std.fs.path.join(allocator, &.{ unit_dir_abs, STUDIO_DIR });
    defer allocator.free(studio_abs);

    var dir = std.Io.Dir.cwd().openDir(io, studio_abs, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch return) |entry| {
        if (entry.kind != .file or !isPanelFile(entry.name)) continue;

        const abs = try std.fs.path.join(allocator, &.{ studio_abs, entry.name });
        defer allocator.free(abs);
        // `abs` is built under `root_abs`, so a readable unit-relative path is
        // just the prefix-stripped suffix (borrowed; no allocation).
        const rel = relTo(root_abs, abs);

        const source = std.Io.Dir.cwd().readFileAlloc(io, abs, allocator, .limited(MAX_PANEL_BYTES)) catch |err| {
            try addLine(allocator, errors, rel, "could not read panel file: {s}", .{@errorName(err)});
            continue;
        };
        defer allocator.free(source);
        try validatePanelSource(allocator, rel, source, errors);
    }
}

/// The path of `abs` relative to `root_abs` (a borrowed suffix), for readable
/// diagnostics — e.g. `studio/x.panel.jsonc` or
/// `packs/dungeon/studio/x.panel.jsonc`. Falls back to `abs` if it isn't a
/// prefix (shouldn't happen — `abs` is always built under `root_abs`).
fn relTo(root_abs: []const u8, abs: []const u8) []const u8 {
    if (std.mem.startsWith(u8, abs, root_abs)) {
        var r = abs[root_abs.len..];
        while (r.len > 0 and (r[0] == '/' or r[0] == '\\')) r = r[1..];
        if (r.len > 0) return r;
    }
    return abs;
}

fn isPanelFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, PANEL_SUFFIX) and name.len > PANEL_SUFFIX.len;
}

// ── Small helpers ───────────────────────────────────────────────────────

fn isIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    const c0 = s[0];
    if (!(std.ascii.isAlphabetic(c0) or c0 == '_')) return false;
    for (s[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

fn isOneOf(s: []const u8, set: []const []const u8) bool {
    for (set) |x| {
        if (std.mem.eql(u8, s, x)) return true;
    }
    return false;
}

/// Append `<rel_path>: <message>` (no `where` segment) — for parse/read errors.
fn addLine(
    allocator: std.mem.Allocator,
    errors: *Errors,
    rel_path: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) AllocErr!void {
    const msg = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(msg);
    try errors.append(allocator, try std.fmt.allocPrint(allocator, "{s}: {s}", .{ rel_path, msg }));
}

/// Append `<rel_path>: <where>: <message>`. `fmt`/`args` build the message.
fn addAt(
    allocator: std.mem.Allocator,
    errors: *Errors,
    rel_path: []const u8,
    where: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) AllocErr!void {
    const msg = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(msg);
    try errors.append(allocator, try std.fmt.allocPrint(allocator, "{s}: {s}: {s}", .{ rel_path, where, msg }));
}

/// Append a `fields[i] ("name"): <msg>` diagnostic (name omitted when null).
fn addField(
    allocator: std.mem.Allocator,
    errors: *Errors,
    rel_path: []const u8,
    idx: usize,
    name: ?[]const u8,
    comptime fmt: []const u8,
    args: anytype,
) AllocErr!void {
    const where = if (name) |n|
        try std.fmt.allocPrint(allocator, "fields[{d}] (\"{s}\")", .{ idx, n })
    else
        try std.fmt.allocPrint(allocator, "fields[{d}]", .{idx});
    defer allocator.free(where);
    try addAt(allocator, errors, rel_path, where, fmt, args);
}

/// Append an `actions[i]: <msg>` diagnostic.
fn addAction(
    allocator: std.mem.Allocator,
    errors: *Errors,
    rel_path: []const u8,
    idx: usize,
    comptime fmt: []const u8,
    args: anytype,
) AllocErr!void {
    const where = try std.fmt.allocPrint(allocator, "actions[{d}]", .{idx});
    defer allocator.free(where);
    try addAt(allocator, errors, rel_path, where, fmt, args);
}

/// Strip JSONC line + block comments and trailing commas, overwriting comment
/// runs with spaces so `std.json` error offsets line up with the original
/// file. A trimmed port of `scene_manifest.stripJsonc` (kept local so the
/// panel validator has no cross-module coupling).
fn stripJsonc(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, source.len);
    @memcpy(out, source);

    var i: usize = 0;
    var in_string = false;
    while (i < out.len) {
        const c = out[i];
        if (in_string) {
            if (c == '\\' and i + 1 < out.len) {
                i += 2;
                continue;
            }
            if (c == '"') in_string = false;
            i += 1;
            continue;
        }
        if (c == '"') {
            in_string = true;
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < out.len) {
            const next = out[i + 1];
            if (next == '/') {
                while (i < out.len and out[i] != '\n') : (i += 1) out[i] = ' ';
                continue;
            }
            if (next == '*') {
                out[i] = ' ';
                out[i + 1] = ' ';
                i += 2;
                while (i + 1 < out.len and !(out[i] == '*' and out[i + 1] == '/')) : (i += 1) {
                    if (out[i] != '\n') out[i] = ' ';
                }
                if (i + 1 < out.len) {
                    out[i] = ' ';
                    out[i + 1] = ' ';
                    i += 2;
                }
                continue;
            }
        }
        i += 1;
    }

    // Blank trailing commas (`, }` / `, ]`) so std.json accepts the dialect.
    in_string = false;
    i = 0;
    while (i < out.len) : (i += 1) {
        const c = out[i];
        if (in_string) {
            if (c == '\\' and i + 1 < out.len) {
                i += 1;
                continue;
            }
            if (c == '"') in_string = false;
            continue;
        }
        if (c == '"') {
            in_string = true;
            continue;
        }
        if (c == ',') {
            var j = i + 1;
            while (j < out.len and (out[j] == ' ' or out[j] == '\t' or out[j] == '\n' or out[j] == '\r')) : (j += 1) {}
            if (j < out.len and (out[j] == '}' or out[j] == ']')) out[i] = ' ';
        }
    }

    return out;
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

/// Parse + validate a source string, returning the joined diagnostics (or an
/// empty string when valid). Test-only convenience.
fn diagnose(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var errors: Errors = .empty;
    defer {
        for (errors.items) |e| allocator.free(e);
        errors.deinit(allocator);
    }
    try validatePanelSource(allocator, "studio/x.panel.jsonc", source, &errors);
    return std.mem.join(allocator, "\n", errors.items);
}

fn expectValid(source: []const u8) !void {
    const out = try diagnose(testing.allocator, source);
    defer testing.allocator.free(out);
    if (out.len != 0) {
        std.debug.print("expected valid, got:\n{s}\n", .{out});
        return error.TestUnexpectedResult;
    }
}

fn expectRejects(source: []const u8, needle: []const u8) !void {
    const out = try diagnose(testing.allocator, source);
    defer testing.allocator.free(out);
    if (std.mem.indexOf(u8, out, needle) == null) {
        std.debug.print("expected a diagnostic containing \"{s}\", got:\n{s}\n", .{ needle, out });
        return error.TestUnexpectedResult;
    }
}

test "accepts a full, well-formed panel (with JSONC comments + trailing commas)" {
    try expectValid(
        \\{
        \\  // the dungeon vendor's panel
        \\  "id": "dungeon_generator",
        \\  "title": "Dungeon Generator",
        \\  "icon": "grid",
        \\  "fields": [
        \\    { "name": "seed",    "type": "number", "default": 42 },
        \\    { "name": "density", "type": "slider", "min": 0.1, "max": 1.0, "default": 0.5 },
        \\    { "name": "theme",   "type": "select", "options": ["stone", "crypt", "lava"], "default": "crypt" },
        \\    { "name": "label",   "type": "text",   "default": "room" },
        \\    { "name": "caves",   "type": "toggle", "default": true },
        \\  ],
        \\  "actions": [
        \\    { "label": "Generate",       "command": "generate",       "target": "preview" },
        \\    { "label": "Save as scene",  "command": "generate_scene", "target": "cli" },
        \\  ],
        \\}
    );
}

test "accepts a minimal panel (no fields/actions)" {
    try expectValid(
        \\{ "id": "p", "title": "P" }
    );
}

test "rejects malformed JSONC with a line number" {
    try expectRejects(
        \\{
        \\  "id": "p",
        \\  "title":
        \\}
    , "not valid JSONC");
}

test "rejects a non-object root" {
    try expectRejects("[]", "panel must be a JSON object");
}

test "rejects a missing id and a bad id" {
    try expectRejects(
        \\{ "title": "P" }
    , "id: required");
    try expectRejects(
        \\{ "id": "9bad", "title": "P" }
    , "must be an identifier");
}

test "rejects an empty title and a missing title" {
    try expectRejects(
        \\{ "id": "p", "title": "" }
    , "title: must not be empty");
    try expectRejects(
        \\{ "id": "p" }
    , "title: required");
}

test "rejects unknown top-level and field keys (strict)" {
    try expectRejects(
        \\{ "id": "p", "title": "P", "extra": 1 }
    , "extra: unrecognized key");
    try expectRejects(
        \\{ "id": "p", "title": "P", "fields": [ { "name": "s", "type": "number", "step": 2 } ] }
    , "unrecognized key \"step\"");
}

test "rejects an unknown field type" {
    try expectRejects(
        \\{ "id": "p", "title": "P", "fields": [ { "name": "s", "type": "color" } ] }
    , "unknown field type \"color\"");
}

test "rejects a field with an empty/missing name" {
    try expectRejects(
        \\{ "id": "p", "title": "P", "fields": [ { "type": "number" } ] }
    , "`name` must be a non-empty string");
}

test "rejects a slider missing min/max" {
    try expectRejects(
        \\{ "id": "p", "title": "P", "fields": [ { "name": "d", "type": "slider" } ] }
    , "a slider requires a numeric `min`");
}

test "rejects min > max and a default outside the range" {
    try expectRejects(
        \\{ "id": "p", "title": "P", "fields": [ { "name": "d", "type": "slider", "min": 1.0, "max": 0.0 } ] }
    , "min (1) exceeds max (0)");
    try expectRejects(
        \\{ "id": "p", "title": "P", "fields": [ { "name": "d", "type": "number", "min": 0, "max": 10, "default": 42 } ] }
    , "default (42) is outside min..max");
}

test "rejects a select without options and a default not among options" {
    try expectRejects(
        \\{ "id": "p", "title": "P", "fields": [ { "name": "t", "type": "select" } ] }
    , "a select requires an `options` array");
    try expectRejects(
        \\{ "id": "p", "title": "P", "fields": [ { "name": "t", "type": "select", "options": ["a","b"], "default": "z" } ] }
    , "default \"z\" is not one of the options");
}

test "rejects duplicate field names" {
    try expectRejects(
        \\{ "id": "p", "title": "P", "fields": [
        \\  { "name": "seed", "type": "number" },
        \\  { "name": "seed", "type": "text" }
        \\] }
    , "duplicate field name");
}

test "rejects a bad action (empty label, non-identifier command, bad target)" {
    try expectRejects(
        \\{ "id": "p", "title": "P", "actions": [ { "label": "", "command": "go", "target": "preview" } ] }
    , "`label` must not be empty");
    try expectRejects(
        \\{ "id": "p", "title": "P", "actions": [ { "label": "Go", "command": "9go", "target": "preview" } ] }
    , "`command` must be an identifier");
    try expectRejects(
        \\{ "id": "p", "title": "P", "actions": [ { "label": "Go", "command": "go", "target": "server" } ] }
    , "`target` must be \"preview\" or \"cli\"");
}

test "collects multiple problems in one pass" {
    const out = try diagnose(testing.allocator,
        \\{ "id": "9", "title": "", "fields": [ { "name": "d", "type": "slider" } ] }
    );
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "must be an identifier") != null);
    try testing.expect(std.mem.indexOf(u8, out, "title: must not be empty") != null);
    try testing.expect(std.mem.indexOf(u8, out, "a slider requires a numeric `min`") != null);
}

// ── Filesystem discovery (the `studio/` scan + declared-scope seam) ──────

fn writePanel(dir: std.Io.Dir, rel: []const u8, body: []const u8) !void {
    if (std.fs.path.dirname(rel)) |sub| try dir.createDirPath(testing.io, sub);
    var f = try dir.createFile(testing.io, rel, .{});
    defer f.close(testing.io);
    try f.writeStreamingAll(testing.io, body);
}

test "scanStudioDir: validates files directly in studio/, ignoring non-studio files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writePanel(tmp.dir, "studio/generator.panel.jsonc",
        \\{ "id": "g", "title": "Generator", "actions": [ { "label": "Go", "command": "go", "target": "preview" } ] }
    );
    try writePanel(tmp.dir, "studio/broken.panel.jsonc",
        \\{ "id": "b", "title": "B", "fields": [ { "name": "s", "type": "slider" } ] }
    );
    // NOT under `studio/` — must be ignored (only studio/*.panel.jsonc count).
    try writePanel(tmp.dir, "notstudio/decoy.panel.jsonc",
        \\{ this is not even json }
    );

    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    var errors: Errors = .empty;
    defer {
        for (errors.items) |e| testing.allocator.free(e);
        errors.deinit(testing.allocator);
    }
    try scanStudioDir(testing.allocator, root, root, &errors);

    // Only the broken slider contributes problems: the decoy and the valid
    // panel add nothing.
    try testing.expect(errors.items.len >= 1);
    var saw_min = false;
    for (errors.items) |e| {
        try testing.expect(std.mem.indexOf(u8, e, "studio/broken.panel.jsonc") != null);
        try testing.expect(std.mem.indexOf(u8, e, "decoy") == null);
        try testing.expect(std.mem.indexOf(u8, e, "generator") == null);
        if (std.mem.indexOf(u8, e, "a slider requires a numeric `min`") != null) saw_min = true;
    }
    try testing.expect(saw_min);
}

test "scanStudioDir: a unit with no studio/ dir is a clean no-op" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePanel(tmp.dir, "components/foo.zig", "// not a panel");

    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    var errors: Errors = .empty;
    defer errors.deinit(testing.allocator);
    try scanStudioDir(testing.allocator, root, root, &errors);
    try testing.expectEqual(@as(usize, 0), errors.items.len);
}

test "discovery scope: a DECLARED pack's broken panel fails; an UNDECLARED pack's does NOT" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A plugin that declares ONLY the `shipped` pack in its manifest.
    try writePanel(tmp.dir, "plugin.labelle",
        \\.{
        \\    .name = "myplugin",
        \\    .manifest_version = 1,
        \\    .packs = .{ "shipped" },
        \\}
    );
    // Plugin-root panel: valid.
    try writePanel(tmp.dir, "studio/root.panel.jsonc",
        \\{ "id": "r", "title": "Root" }
    );
    // DECLARED pack with a broken panel → MUST fail generate.
    try writePanel(tmp.dir, "packs/shipped/studio/broken.panel.jsonc",
        \\{ "id": "s", "title": "S", "fields": [ { "name": "x", "type": "slider" } ] }
    );
    // UNDECLARED pack (not in `.packs`) with a broken panel → MUST be ignored:
    // it isn't part of generation, so it must never fail `labelle generate`.
    try writePanel(tmp.dir, "packs/experimental/studio/wild.panel.jsonc",
        \\{ this is not even json }
    );

    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    // A local-path plugin whose dir IS the tmp root (absolute → game_dir is
    // ignored by the resolver).
    const repo = try std.fmt.allocPrint(testing.allocator, "local:{s}", .{root});
    defer testing.allocator.free(repo);
    const plugins = [_]config.PluginDep{.{ .name = "myplugin", .repo = repo }};
    const cfg = config.ProjectConfig{ .name = "test", .plugins = &plugins };

    var errors: Errors = .empty;
    defer {
        for (errors.items) |e| testing.allocator.free(e);
        errors.deinit(testing.allocator);
    }
    try collectPluginPanelErrors(testing.allocator, cfg, root, &errors);

    // The declared pack's broken slider is reported…
    var saw_shipped = false;
    for (errors.items) |e| {
        // …and NOTHING from the undeclared `experimental` pack or the valid
        // root panel is.
        try testing.expect(std.mem.indexOf(u8, e, "experimental") == null);
        try testing.expect(std.mem.indexOf(u8, e, "wild") == null);
        try testing.expect(std.mem.indexOf(u8, e, "root.panel.jsonc") == null);
        if (std.mem.indexOf(u8, e, "packs/shipped/studio/broken.panel.jsonc") != null and
            std.mem.indexOf(u8, e, "a slider requires a numeric `min`") != null) saw_shipped = true;
    }
    try testing.expect(saw_shipped);
}
