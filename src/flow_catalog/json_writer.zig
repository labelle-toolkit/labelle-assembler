//! JSON writer + sidecar file emission for the flow catalog. Extracted
//! from the original `src/flow_catalog.zig` as part of the per-concern
//! split (labelle-assembler#186).
//!
//! Hand-written for readability over the stdlib's `std.json.Stringify`
//! because the structure is small and we want stable, pretty-printed
//! output the user can diff and the editor can hand-parse without a
//! schema.

const std = @import("std");
const config = @import("../config.zig");
const types = @import("types.zig");

const FlowNodeEntry = types.FlowNodeEntry;
const PinStyleEntry = types.PinStyleEntry;
const EventEntry = types.EventEntry;
const CoercionEntry = types.CoercionEntry;
const ModuleGroup = types.ModuleGroup;
const SIDECAR_FILENAME = types.SIDECAR_FILENAME;

/// Emit the full catalog as JSON. Hand-written for readability over the
/// stdlib's `std.json.Stringify` because the structure is small and
/// we want stable, pretty-printed output the user can diff and the
/// editor can hand-parse without a schema.
pub fn writeCatalogJson(w: *std.Io.Writer, groups: []const ModuleGroup) !void {
    // ISO-8601 timestamp at minute resolution. The editor uses
    // mtime-keyed caching (not this string) so the exact format isn't
    // critical, but a human-readable one helps debugging.
    var ts_buf: [32]u8 = undefined;
    const ts = formatTimestamp(&ts_buf);

    try w.writeAll("{\n");
    try w.print("  \"generated_at\": \"{s}\",\n", .{ts});
    try w.writeAll("  \"plugins\": [");
    if (groups.len == 0) {
        try w.writeAll("]\n}\n");
        return;
    }
    try w.writeAll("\n");
    for (groups, 0..) |g, gi| {
        try w.writeAll("    {\n");
        try w.print("      \"name\": ", .{});
        try writeJsonString(w, g.name);
        try w.writeAll(",\n");
        try w.writeAll("      \"flow_nodes\": [");
        if (g.flow_nodes.len == 0) {
            try w.writeAll("],\n");
        } else {
            try w.writeAll("\n");
            for (g.flow_nodes, 0..) |n, ni| {
                try writeFlowNodeJson(w, n);
                if (ni + 1 < g.flow_nodes.len) try w.writeAll(",");
                try w.writeAll("\n");
            }
            try w.writeAll("      ],\n");
        }
        try w.writeAll("      \"pin_styles\": [");
        if (g.pin_styles.len == 0) {
            try w.writeAll("],\n");
        } else {
            try w.writeAll("\n");
            for (g.pin_styles, 0..) |s, si| {
                try writePinStyleJson(w, s);
                if (si + 1 < g.pin_styles.len) try w.writeAll(",");
                try w.writeAll("\n");
            }
            try w.writeAll("      ],\n");
        }
        // ── events ─────────────────────────────────────────────
        // labelle-engine#578 (engine lifecycle) + RFC-PLUGIN-EVENTS
        // (plugin events). `discoverInSource` populates this from
        // each module's `pub const Events` block; the editor renders
        // the entries as Event-node variants in the palette and uses
        // each event's typed payload pins to wire downstream nodes.
        try w.writeAll("      \"events\": [");
        if (g.events.len == 0) {
            try w.writeAll("],\n");
        } else {
            try w.writeAll("\n");
            for (g.events, 0..) |e, ei| {
                try writeEventJson(w, e);
                if (ei + 1 < g.events.len) try w.writeAll(",");
                try w.writeAll("\n");
            }
            try w.writeAll("      ],\n");
        }
        // ── coercions (RFC-FLOW-VOCABULARY §2 / O4) ──────────
        // `discoverInSource` populates this from each module's
        // `pub const Coercions` block. The editor's wire-fit check
        // accepts an edge whose (from_zig_type, to_zig_type) matches a
        // registered coercion; flow-codegen wraps the source expression
        // in `<qualified>.convert(...)` at the edge site.
        try w.writeAll("      \"coercions\": [");
        if (g.coercions.len == 0) {
            try w.writeAll("]\n");
        } else {
            try w.writeAll("\n");
            for (g.coercions, 0..) |c, ci| {
                try writeCoercionJson(w, c);
                if (ci + 1 < g.coercions.len) try w.writeAll(",");
                try w.writeAll("\n");
            }
            try w.writeAll("      ]\n");
        }
        try w.writeAll("    }");
        if (gi + 1 < groups.len) try w.writeAll(",");
        try w.writeAll("\n");
    }
    try w.writeAll("  ]\n}\n");
}

fn writeFlowNodeJson(w: *std.Io.Writer, n: FlowNodeEntry) !void {
    try w.writeAll("        {\n");
    try w.writeAll("          \"qualified\": ");
    try writeJsonString(w, n.qualified);
    try w.writeAll(",\n          \"display_name\": ");
    try writeJsonString(w, n.display_name);
    try w.writeAll(",\n          \"category\": ");
    try writeJsonString(w, n.category);
    try w.writeAll(",\n          \"docs\": ");
    try writeJsonString(w, n.docs);
    try w.writeAll(",\n          \"kind\": ");
    try writeJsonString(w, n.kind);
    try w.writeAll(",\n          \"pins\": [");
    if (n.pins.len == 0) {
        try w.writeAll("],\n");
    } else {
        try w.writeAll("\n");
        for (n.pins, 0..) |p, pi| {
            try w.writeAll("            { \"name\": ");
            try writeJsonString(w, p.name);
            try w.writeAll(", \"label\": ");
            try writeJsonString(w, p.label);
            try w.writeAll(", \"zig_type\": ");
            try writeJsonString(w, p.zig_type);
            try w.writeAll(", \"dir\": ");
            try writeJsonString(w, p.dir);
            try w.writeAll(", \"default\": ");
            if (p.default) |d| try writeJsonString(w, d) else try w.writeAll("null");
            try w.writeAll(" }");
            if (pi + 1 < n.pins.len) try w.writeAll(",");
            try w.writeAll("\n");
        }
        try w.writeAll("          ],\n");
    }
    try w.writeAll("          \"return_type\": ");
    if (n.return_type) |rt| try writeJsonString(w, rt) else try w.writeAll("null");
    try w.writeAll("\n        }");
}

fn writePinStyleJson(w: *std.Io.Writer, s: PinStyleEntry) !void {
    try w.writeAll("        { \"zig_type\": ");
    try writeJsonString(w, s.zig_type);
    try w.writeAll(", \"label\": ");
    try writeJsonString(w, s.label);
    try w.print(", \"color\": [{d}, {d}, {d}] }}", .{ s.color[0], s.color[1], s.color[2] });
}

/// Emit one event entry as JSON, shape:
///   `{ "qualified": "box2d.collision_begin",
///      "name": "collision_begin",
///      "pins": [ { "name", "label", "zig_type", "dir" }, ... ] }`
/// `dir` is always `"output"` for events — the on-disk Event-node form
/// fans the payload struct's fields out as data outputs (consumed by
/// downstream `SetVariable` / `CustomNode` nodes). Mirrors the pin
/// shape `writeFlowNodeJson` emits minus the `default` field (events
/// payloads don't carry defaults — they're produced, never authored).
fn writeEventJson(w: *std.Io.Writer, e: EventEntry) !void {
    try w.writeAll("        {\n          \"qualified\": ");
    try writeJsonString(w, e.qualified);
    try w.writeAll(",\n          \"name\": ");
    try writeJsonString(w, e.name);
    try w.writeAll(",\n          \"pins\": [");
    if (e.pins.len == 0) {
        try w.writeAll("]\n");
    } else {
        try w.writeAll("\n");
        for (e.pins, 0..) |p, pi| {
            try w.writeAll("            { \"name\": ");
            try writeJsonString(w, p.name);
            try w.writeAll(", \"label\": ");
            try writeJsonString(w, p.label);
            try w.writeAll(", \"zig_type\": ");
            try writeJsonString(w, p.zig_type);
            try w.writeAll(", \"dir\": ");
            try writeJsonString(w, p.dir);
            try w.writeAll(" }");
            if (pi + 1 < e.pins.len) try w.writeAll(",");
            try w.writeAll("\n");
        }
        try w.writeAll("          ]\n");
    }
    try w.writeAll("        }");
}

/// Emit one coercion entry as JSON, shape:
///   `{ "qualified": "box2d.body_to_entity",
///      "name": "body_to_entity",
///      "from_zig_type": "BodyId",
///      "to_zig_type": "u32",
///      "docs": "..." }`
/// The editor's wire-fit check keys off `from_zig_type` +
/// `to_zig_type`; flow-codegen's edge codegen reads `qualified` to
/// produce the `<qualified>.convert(...)` call site.
fn writeCoercionJson(w: *std.Io.Writer, c: CoercionEntry) !void {
    try w.writeAll("        { \"qualified\": ");
    try writeJsonString(w, c.qualified);
    try w.writeAll(", \"name\": ");
    try writeJsonString(w, c.name);
    try w.writeAll(", \"from_zig_type\": ");
    try writeJsonString(w, c.from_zig_type);
    try w.writeAll(", \"to_zig_type\": ");
    try writeJsonString(w, c.to_zig_type);
    try w.writeAll(", \"docs\": ");
    try writeJsonString(w, c.docs);
    try w.writeAll(" }");
}

/// Write a JSON string literal — wraps in double quotes, escapes the
/// subset of bytes JSON requires (`"`, `\`, control chars below 0x20)
/// and pass-throughs everything else. UTF-8 source bytes ride along
/// unchanged because JSON is UTF-8 itself.
fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

/// Format the current UTC timestamp as `"YYYY-MM-DDTHH:MM:SSZ"`. Pure
/// epoch arithmetic so we don't depend on system locale settings or a
/// `strftime`-style call.
fn formatTimestamp(buf: *[32]u8) []const u8 {
    const epoch_secs: u64 = blk: {
        // `std.time.timestamp` was removed in 0.16; use `clock_gettime`
        // through libc the same way `tests.zig` does.
        var ts: std.posix.timespec = undefined;
        _ = std.posix.system.clock_gettime(.REALTIME, &ts);
        break :blk @intCast(ts.sec);
    };

    // Days since 1970-01-01 + seconds-of-day.
    const secs_per_day: u64 = 86400;
    const day = epoch_secs / secs_per_day;
    const sod = epoch_secs % secs_per_day;
    const hour: u32 = @intCast(sod / 3600);
    const minute: u32 = @intCast((sod % 3600) / 60);
    const second: u32 = @intCast(sod % 60);

    // Howard Hinnant's days-from-civil algorithm in reverse — Zig
    // stdlib has the same calculation behind `std.time.epoch` but the
    // shape moved between 0.15 and 0.16 enough that doing it inline
    // is the smallest dependency.
    var y: i64 = 1970;
    var d_remain: i64 = @intCast(day);
    while (true) {
        const days_in_year: i64 = if (isLeapYear(y)) 366 else 365;
        if (d_remain < days_in_year) break;
        d_remain -= days_in_year;
        y += 1;
    }
    var month: u32 = 1;
    const months = [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    while (month <= 12) {
        const days_in_month: i64 = blk: {
            var dim: i64 = months[month - 1];
            if (month == 2 and isLeapYear(y)) dim += 1;
            break :blk dim;
        };
        if (d_remain < days_in_month) break;
        d_remain -= days_in_month;
        month += 1;
    }
    const day_of_month: u32 = @intCast(d_remain + 1);

    return std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ y, month, day_of_month, hour, minute, second }) catch "1970-01-01T00:00:00Z";
}

fn isLeapYear(y: i64) bool {
    if (@mod(y, 4) != 0) return false;
    if (@mod(y, 100) != 0) return true;
    return @mod(y, 400) == 0;
}

/// Write `<target_dir>/flow_catalog.json`. Mirrors the pattern other
/// generated artifacts (`main.zig`, `build.zig`) use.
pub fn writeSidecar(target_dir: []const u8, bytes: []const u8) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, target_dir, .{});
    defer dir.close(io);
    const file = try dir.createFile(io, SIDECAR_FILENAME, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}
