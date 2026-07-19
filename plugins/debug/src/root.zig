//! labelle-debug — Debug inspector plugin for LaBelle.

const std = @import("std");
const core = @import("labelle-core");
const engine = @import("labelle-engine");
const Position = core.Position;

var debug_visible: bool = false;
var show_entities: bool = false;
var show_perf: bool = true;
var time_scale_slider: f32 = 1.0;
var selected_entity: ?u32 = null;

/// Set to false to completely disable the debug inspector (e.g. for shipping builds).
/// Games can set this in setup: `@import("debug").enabled = false;`
pub var enabled: bool = true;

/// Key to toggle the debug inspector. Default: F12.
pub var toggle_key: engine.KeyboardKey = .f12;

/// Upper bound on the number of component types the inspector can
/// filter on. Games with more component types than this will see
/// their extra types appear in the browser but not in the filter
/// list (the loop in `drawEntityBrowser` gates on `i < MAX_COMPONENTS`).
/// Bumped from 32 → 128 based on PR #27 review; bump again if a game
/// legitimately exceeds that.
const MAX_COMPONENTS: usize = 128;
var component_filters: [MAX_COMPONENTS]bool = [_]bool{false} ** MAX_COMPONENTS;

// State persistence
const STATE_FILE = "debug_state.ini";
var state_dirty: bool = false;

// ── Performance section (labelle-engine#380) ─────────────────────────
//
// FPS/frame-time comes from the engine's always-on FrameProfiler
// (`game.frameStats()` / `game.frameHistory()`); per-script and
// per-plugin timings come from the engine's dispatch profiler
// (`game.scriptProfileRows()` / `game.pluginProfileRows()`). The plugin
// arms live capture via `game.setProfilingCapture(true)` while the
// Performance section is visible and hands the gate back to the
// LABELLE_PROFILE env var (`null`) when it closes, so an env-enabled
// headless dump keeps running. Engine reads are `@hasDecl`/`@hasField`
// gated: against an engine without the API the section degrades to a
// hint label instead of breaking the build.

/// Whether we currently hold the engine's capture override.
var capture_armed: bool = false;

/// One render-ready profiler table row, ns per lifecycle phase. Pure
/// data (no engine types) so sorting/formatting stay unit-testable.
const PerfRow = struct {
    name: []const u8,
    setup_ns: u64 = 0,
    tick_ns: u64 = 0,
    post_ns: u64 = 0,
    gui_ns: u64 = 0,

    /// Recurring per-frame cost — the sort key. Boot-time `setup` is
    /// deliberately excluded.
    fn frameNs(self: PerfRow) u64 {
        return self.tick_ns + self.post_ns + self.gui_ns;
    }
};

/// Upper bound on displayed rows per group (scripts / plugins).
const MAX_PERF_ROWS: usize = 64;

fn perfRowDesc(_: void, a: PerfRow, b: PerfRow) bool {
    return a.frameNs() > b.frameNs();
}

/// Insert `row` into `buf[0..count.*]`, keeping the buffer sorted by
/// per-frame cost (descending) and capped at `buf.len`. This gives
/// sort-then-truncate semantics in one streaming pass: with more units
/// than `buf.len`, the priciest rows survive REGARDLESS of their source
/// order (fixing the "truncate-before-sort drops late-registered hot
/// scripts" bug). `count` is updated in place; the top `count.*` rows
/// are left sorted so the renderer can emit them directly.
fn insertTopRow(buf: []PerfRow, count: *usize, row: PerfRow) void {
    const cost = row.frameNs();
    if (count.* < buf.len) {
        // Room left: shift the smaller tail right and drop `row` in.
        var i: usize = count.*;
        while (i > 0 and buf[i - 1].frameNs() < cost) : (i -= 1) buf[i] = buf[i - 1];
        buf[i] = row;
        count.* += 1;
    } else if (buf.len > 0 and buf[buf.len - 1].frameNs() < cost) {
        // Full: replace the current smallest only if `row` beats it.
        var i: usize = buf.len - 1;
        while (i > 0 and buf[i - 1].frameNs() < cost) : (i -= 1) buf[i] = buf[i - 1];
        buf[i] = row;
    }
}

/// Severity marker mirroring the engine's traffic light (green < 1ms,
/// yellow 1-5ms, red > 5ms). Text markers because the GuiInterface has
/// no colored-label API yet (follow-up).
fn severityMark(ns: u64) []const u8 {
    if (ns >= 5_000_000) return "!";
    if (ns >= 1_000_000) return "*";
    return "";
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

/// Format one phase cell: "0.45" / "1.20*" / "6.00!" (ms + severity
/// marker), or "-" when the phase cost is zero (never ran / below
/// clock resolution).
fn fmtPhase(buf: []u8, ns: u64) [:0]const u8 {
    if (ns == 0) return std.fmt.bufPrintZ(buf, "-", .{}) catch "?";
    return std.fmt.bufPrintZ(buf, "{d:.2}{s}", .{ nsToMs(ns), severityMark(ns) }) catch "?";
}

/// Read a phase Stat's live ns from an engine profile row, tolerating
/// older engines whose rows lack the phase field (e.g. `setup` /
/// plugin `draw_gui` pre-2.5): missing fields read as 0.
fn phaseNs(row: anytype, comptime phase: []const u8) u64 {
    if (comptime !@hasField(@TypeOf(row), phase)) return 0;
    return @field(row, phase).last_ns;
}

/// True when env var `name` is set and non-empty. Desktop/libc only
/// (same constraint as the engine's profiler gate); wasm and no-libc
/// builds always report false.
fn envTruthy(comptime name: [*:0]const u8) bool {
    const builtin = @import("builtin");
    if (comptime builtin.cpu.arch == .wasm32 or builtin.os.tag == .emscripten) return false;
    if (comptime !builtin.link_libc) return false;
    const raw = std.c.getenv(name) orelse return false;
    return std.mem.span(raw).len > 0;
}

/// Arm/disarm the engine's live per-unit capture to track panel
/// visibility. Disarming passes `null` (not `false`) so a user-set
/// LABELLE_PROFILE keeps its headless dump.
fn syncProfilingCapture(game: anytype, want: bool) void {
    const Game = @TypeOf(game.*);
    if (comptime !@hasDecl(Game, "setProfilingCapture")) return;
    if (want == capture_armed) return;
    game.setProfilingCapture(if (want) true else null);
    capture_armed = want;
}

/// FPS header + (when Show Performance is on) min/avg/max and the
/// frame-time mini-graph, all fed by the engine's FrameProfiler.
fn drawFpsHeader(game: anytype, comptime Gui: type) void {
    const Game = @TypeOf(game.*);
    // Both accessors are gated under one capability check — an engine
    // exposing frameStats but not frameTimeMs must still compile.
    if (comptime !(@hasDecl(Game, "frameStats") and @hasDecl(Game, "frameTimeMs"))) {
        Gui.label("FPS: n/a (engine lacks frameStats)");
        return;
    }
    const st = game.frameStats();
    var fps_buf: [64]u8 = undefined;
    Gui.label(std.fmt.bufPrintZ(&fps_buf, "FPS: {d:.0} | Frame: {d:.1}ms", .{ st.fps, game.frameTimeMs() }) catch "?");

    if (!show_perf) return;

    var mm_buf: [96]u8 = undefined;
    Gui.label(std.fmt.bufPrintZ(&mm_buf, "min {d:.1} / avg {d:.1} / max {d:.1} ms", .{ st.min_ms, st.avg_ms, st.max_ms }) catch "?");

    if (comptime @hasDecl(Game, "frameHistory")) {
        // Mini graph: newest 40 frames, one char each, full bar = 33.3ms
        // (30 FPS). Keep the buffer one byte larger than the bar so the
        // null terminator doesn't clobber the last char.
        const bar_len: usize = 40;
        var hist_buf: [bar_len]f32 = undefined;
        const hist = game.frameHistory(&hist_buf);
        if (hist.len > 0) {
            var bar: [bar_len + 1]u8 = undefined;
            const full_ms: f32 = 33.3;
            for (hist, 0..) |ms, i| {
                const ratio = @min(ms / full_ms, 1.0);
                bar[i] = if (ratio > 0.8) '!' else if (ratio > 0.5) '#' else if (ratio > 0.2) '=' else '.';
            }
            bar[hist.len] = 0;
            var graph_buf: [64]u8 = undefined;
            Gui.label(std.fmt.bufPrintZ(&graph_buf, "[{s}]", .{bar[0..hist.len :0]}) catch "?");
        }
    }
}

/// Sorted per-unit timing tables (scripts, then plugin systems).
///
/// Each block collects the top `MAX_PERF_ROWS` by per-frame cost via a
/// streaming inserter, so with more units than the cap the priciest
/// survive regardless of source order. The scripts and plugins accessors
/// are gated INDEPENDENTLY (`@hasDecl`) so an engine exposing only one
/// still compiles.
fn drawPerfTables(game: anytype, comptime Gui: type) void {
    const Game = @TypeOf(game.*);
    var rows_buf: [MAX_PERF_ROWS]PerfRow = undefined;

    if (comptime @hasDecl(Game, "scriptProfileRows")) {
        var count: usize = 0;
        for (game.scriptProfileRows()) |r| insertTopRow(&rows_buf, &count, .{
            .name = r.name,
            .setup_ns = phaseNs(r, "setup"),
            .tick_ns = phaseNs(r, "tick"),
            .gui_ns = phaseNs(r, "draw_gui"),
        });
        drawPerfGroup(Gui, "Scripts", rows_buf[0..count], false);
    }
    if (comptime @hasDecl(Game, "pluginProfileRows")) {
        var count: usize = 0;
        for (game.pluginProfileRows()) |r| insertTopRow(&rows_buf, &count, .{
            .name = r.name,
            .setup_ns = phaseNs(r, "setup"),
            .tick_ns = phaseNs(r, "tick"),
            .post_ns = phaseNs(r, "post_tick"),
            .gui_ns = phaseNs(r, "draw_gui"),
        });
        drawPerfGroup(Gui, "Plugins", rows_buf[0..count], true);
    }
}

/// One table: header, rows sorted by per-frame cost (desc), total footer.
fn drawPerfGroup(
    comptime Gui: type,
    comptime title: [:0]const u8,
    rows: []PerfRow,
    comptime show_post: bool,
) void {
    if (rows.len == 0) return;
    std.mem.sort(PerfRow, rows, {}, perfRowDesc);

    // Sum the total UNCONDITIONALLY, before the table-render branch —
    // if `beginTable` returns false (collapsed / clipped) the row loop
    // is skipped, and a total computed inside it would print stale/zero.
    var total_ns: u64 = 0;
    for (rows) |r| total_ns += r.frameNs();

    Gui.spacing();
    Gui.label(title ++ " (ms, last frame; * >1ms, ! >5ms):");
    const cols: i32 = if (show_post) 5 else 4;
    if (Gui.beginTable(title, cols)) {
        Gui.tableNextRow();
        _ = Gui.tableNextColumn();
        Gui.label("name");
        _ = Gui.tableNextColumn();
        Gui.label("tick");
        if (show_post) {
            _ = Gui.tableNextColumn();
            Gui.label("post");
        }
        _ = Gui.tableNextColumn();
        Gui.label("gui");
        _ = Gui.tableNextColumn();
        Gui.label("setup");

        for (rows) |r| {
            Gui.tableNextRow();
            var name_buf: [96]u8 = undefined;
            _ = Gui.tableNextColumn();
            Gui.label(std.fmt.bufPrintZ(&name_buf, "{s}", .{r.name}) catch "?");
            var cell: [24]u8 = undefined;
            _ = Gui.tableNextColumn();
            Gui.label(fmtPhase(&cell, r.tick_ns));
            if (show_post) {
                _ = Gui.tableNextColumn();
                Gui.label(fmtPhase(&cell, r.post_ns));
            }
            _ = Gui.tableNextColumn();
            Gui.label(fmtPhase(&cell, r.gui_ns));
            _ = Gui.tableNextColumn();
            Gui.label(fmtPhase(&cell, r.setup_ns));
        }
        Gui.endTable();
    }
    var total_buf: [64]u8 = undefined;
    Gui.label(std.fmt.bufPrintZ(&total_buf, "Total {s}: {d:.2}ms", .{ title, nsToMs(total_ns) }) catch "?");
}

pub const Systems = struct {
    pub fn setup(game: anytype) void {
        loadDebugState(game);
        // Open the inspector at boot when LABELLE_DEBUG_OPEN is set —
        // skips the F12 for headless screenshot runs and quick triage.
        if (envTruthy("LABELLE_DEBUG_OPEN")) debug_visible = true;
    }

    pub fn drawGui(game: anytype) void {
        if (!enabled) return;

        const Gui = @TypeOf(game.*).Gui;
        if (!Gui.supportsWidgets()) return;

        var dirty = false;

        // F12 toggles visibility
        if (game.isKeyPressed(toggle_key)) {
            debug_visible = !debug_visible;
            dirty = true;
        }

        // Keep the engine's live per-unit capture in step with panel
        // visibility (runs even when hidden, so closing disarms it).
        syncProfilingCapture(game, debug_visible and show_perf);

        // Save before early return so F12-to-hide is persisted
        if (dirty and !debug_visible) {
            saveDebugState(game);
            return;
        }

        if (!debug_visible) return;

        if (Gui.beginWindow("Debug Inspector")) {
            // ── FPS + performance (engine-fed, labelle-engine#380) ──
            drawFpsHeader(game, Gui);
            if (show_perf) drawPerfTables(game, Gui);

            {
                const prev = show_perf;
                _ = Gui.checkbox("Show Performance", &show_perf);
                if (show_perf != prev) dirty = true;
            }

            Gui.separator();

            // ── Stats ──
            if (Gui.treeNode("Stats")) {
                var buf: [64]u8 = undefined;
                Gui.label(std.fmt.bufPrintZ(&buf, "Entities: {d}", .{game.active_world.ecs_backend.entityCount()}) catch "?");
                var frame_buf: [64]u8 = undefined;
                Gui.label(std.fmt.bufPrintZ(&frame_buf, "Frame: {d}", .{game.frame_number}) catch "?");
                Gui.treePop();
            }

            Gui.separator();

            // ── Time Control ──
            if (game.isPaused()) {
                if (Gui.button("Resume")) game.resume_();
            } else {
                if (Gui.button("Pause")) game.pause();
            }
            Gui.sameLine();
            if (Gui.button("0.25x")) { game.setTimeScale(0.25); dirty = true; }
            Gui.sameLine();
            if (Gui.button("0.5x")) { game.setTimeScale(0.5); dirty = true; }
            Gui.sameLine();
            if (Gui.button("1x")) { game.setTimeScale(1.0); dirty = true; }
            Gui.sameLine();
            if (Gui.button("2x")) { game.setTimeScale(2.0); dirty = true; }

            time_scale_slider = game.getTimeScale();
            _ = Gui.sliderFloat("Time Scale", &time_scale_slider, 0, 3);
            if (time_scale_slider != game.getTimeScale()) {
                game.setTimeScale(time_scale_slider);
                dirty = true;
            }

            Gui.separator();

            if (Gui.treeNode("Gizmos")) {
                var gizmos_on = game.gizmos_enabled;
                if (Gui.checkbox("Master Toggle", &gizmos_on)) {
                    game.gizmos_enabled = gizmos_on;
                    dirty = true;
                }

                // Category 0 = uncategorized (always present)
                var cat0_enabled = game.isGizmoCategoryEnabled(0);
                if (Gui.checkbox("Uncategorized", &cat0_enabled)) {
                    game.setGizmoCategory(0, cat0_enabled);
                    dirty = true;
                }

                // Auto-discovered categories from plugins
                const categories = @TypeOf(game.*).gizmo_categories;
                for (categories) |cat| {
                    var cat_on = game.isGizmoCategoryEnabled(cat.id);
                    var name_buf: [64]u8 = undefined;
                    const name_z = std.fmt.bufPrintZ(&name_buf, "{s}", .{cat.name}) catch "?";
                    if (Gui.checkbox(name_z, &cat_on)) {
                        game.setGizmoCategory(cat.id, cat_on);
                        dirty = true;
                    }
                }

                Gui.treePop();
            }

            Gui.separator();
            {
                const prev = show_entities;
                _ = Gui.checkbox("Entity Browser", &show_entities);
                if (show_entities != prev) dirty = true;
            }
        }
        Gui.endWindow();

        if (dirty) state_dirty = true;
        if (state_dirty) {
            saveDebugState(game);
            state_dirty = false;
        }

        if (show_entities) {
            drawEntityBrowser(game, Gui);
            drawEntityDetail(game, Gui);
        }
    }
};

fn drawEntityBrowser(game: anytype, comptime Gui: type) void {
    const Reg = @TypeOf(game.*).ComponentRegistry;
    const comp_names = comptime Reg.names();

    if (Gui.beginWindow("Entity Browser")) {
        Gui.label("Filter:");
        inline for (comp_names, 0..) |name, i| {
            if (i < MAX_COMPONENTS) {
                const prev = component_filters[i];
                // Copy the component name into a null-terminated
                // buffer rather than relying on `@ptrCast` on a
                // `[]const u8` — the registry's `names()` is free
                // to return slices that aren't sentinel-terminated,
                // and `[*:0]` reads past the end on those.
                var name_buf: [128]u8 = undefined;
                const name_z = std.fmt.bufPrintZ(&name_buf, "{s}", .{name}) catch "?";
                _ = Gui.checkbox(name_z, &component_filters[i]);
                if (component_filters[i] != prev) state_dirty = true;
                if ((i + 1) % 4 != 0 and i + 1 < comp_names.len) Gui.sameLine();
            }
        }

        Gui.separator();

        if (Gui.beginTable("entities", 4)) {
            Gui.tableNextRow();
            _ = Gui.tableNextColumn();
            Gui.label("ID");
            _ = Gui.tableNextColumn();
            Gui.label("Position");
            _ = Gui.tableNextColumn();
            Gui.label("Components");
            _ = Gui.tableNextColumn();
            Gui.label("");

            var iter = game.active_world.ecs_backend.query(.{Position});
            defer deinitIter(&iter, game.allocator);

            var count: usize = 0;
            while (iter.next()) |result| {
                if (count >= 50) break;

                const entity = result.entity;
                const pos: *const Position = result.comp_0;

                var passes = true;
                inline for (comp_names, 0..) |name, i| {
                    if (i < MAX_COMPONENTS and component_filters[i]) {
                        if (!Reg.entityHasNamed(&game.active_world.ecs_backend, entity, name)) {
                            passes = false;
                        }
                    }
                }
                if (!passes) continue;

                Gui.tableNextRow();

                _ = Gui.tableNextColumn();
                var id_buf: [16]u8 = undefined;
                Gui.label(std.fmt.bufPrintZ(&id_buf, "{d}", .{entity}) catch "?");

                _ = Gui.tableNextColumn();
                var pos_buf: [48]u8 = undefined;
                Gui.label(std.fmt.bufPrintZ(&pos_buf, "({d:.0}, {d:.0})", .{ pos.x, pos.y }) catch "?");

                _ = Gui.tableNextColumn();
                var tags_buf: [256]u8 = undefined;
                var tags_len: usize = 0;

                inline for (comp_names) |name| {
                    if (Reg.entityHasNamed(&game.active_world.ecs_backend, entity, name)) {
                        if (tags_len + name.len + 1 < tags_buf.len) {
                            @memcpy(tags_buf[tags_len .. tags_len + name.len], name);
                            tags_len += name.len;
                            tags_buf[tags_len] = ' ';
                            tags_len += 1;
                        }
                    }
                }
                if (tags_len > 0) {
                    tags_buf[tags_len] = 0;
                    Gui.label(@ptrCast(tags_buf[0..tags_len :0]));
                }

                _ = Gui.tableNextColumn();
                var sel_buf: [24]u8 = undefined;
                const sel_label = std.fmt.bufPrintZ(&sel_buf, "Select##{d}", .{entity}) catch "?";
                if (Gui.button(sel_label)) {
                    selected_entity = entity;
                }

                count += 1;
            }
            Gui.endTable();
        }

        var total_buf: [48]u8 = undefined;
        Gui.label(std.fmt.bufPrintZ(&total_buf, "Total: {d}", .{game.active_world.ecs_backend.entityCount()}) catch "?");
    }
    Gui.endWindow();
}

fn drawEntityDetail(game: anytype, comptime Gui: type) void {
    const entity = selected_entity orelse return;
    const Reg = @TypeOf(game.*).ComponentRegistry;
    const comp_names = comptime Reg.names();

    if (!game.active_world.ecs_backend.entityExists(entity)) {
        selected_entity = null;
        return;
    }

    if (Gui.beginWindow("Entity Detail")) {
        var id_buf: [32]u8 = undefined;
        Gui.label(std.fmt.bufPrintZ(&id_buf, "Entity: {d}", .{entity}) catch "?");

        if (Gui.button("Deselect")) {
            selected_entity = null;
        }

        Gui.separator();

        // Position (always show, not in registry)
        if (game.active_world.ecs_backend.getComponent(entity, Position)) |pos| {
            if (Gui.treeNode("Position")) {
                var buf: [64]u8 = undefined;
                Gui.label(std.fmt.bufPrintZ(&buf, "x: {d:.2}", .{pos.x}) catch "?");
                var buf2: [64]u8 = undefined;
                Gui.label(std.fmt.bufPrintZ(&buf2, "y: {d:.2}", .{pos.y}) catch "?");
                Gui.treePop();
            }
        }

        // Each registered component
        inline for (comp_names) |name| {
            const T = Reg.getType(name);
            if (game.active_world.ecs_backend.getComponent(entity, T)) |comp| {
                var name_buf: [128]u8 = undefined;
                const name_z = std.fmt.bufPrintZ(&name_buf, "{s}", .{name}) catch "?";
                if (Gui.treeNode(name_z)) {
                    showStructFields(Gui, comp, T);
                    Gui.treePop();
                }
            }
        }
    }
    Gui.endWindow();
}

/// Display all fields of a struct in the GUI.
fn showStructFields(comptime Gui: type, ptr: anytype, comptime T: type) void {
    const info = @typeInfo(T);
    if (info != .@"struct") return;

    inline for (info.@"struct".fields) |field| {
        if (field.name[0] == '_') continue;

        var buf: [128]u8 = undefined;
        const value = @field(ptr.*, field.name);
        const label = formatField(&buf, field.name, field.type, value) catch "?";
        Gui.label(label);
    }
}

/// Deinit a query iterator — handles both mock (0 args) and real ECS (1 arg: allocator).
fn deinitIter(iter: anytype, alloc: anytype) void {
    const DeinitFn = @TypeOf(@TypeOf(iter.*).deinit);
    const params = @typeInfo(DeinitFn).@"fn".params;
    if (params.len == 1) {
        iter.deinit();
    } else {
        iter.deinit(alloc);
    }
}

/// Log a warning through the game's log sink if available, otherwise stderr.
fn logWarn(game: anytype, comptime fmt: []const u8, args: anytype) void {
    const Game = @TypeOf(game.*);
    if (@hasField(Game, "log")) {
        game.log.warn("[debug] " ++ fmt, args);
    } else {
        std.debug.print("debug-plugin: " ++ fmt ++ "\n", args);
    }
}

// ── Gizmo state persistence ──────────────────────────────────────────

fn loadDebugState(game: anytype) void {
    // Stubbed during 0.16 migration: std.fs.cwd() removed, file IO now
    // takes an io param the plugin doesn't have. Restoring via a thin
    // libc fopen() helper is a follow-up.
    _ = game;
}

/// Parse a debug_state.ini string and apply values to game + module state.
fn applyDebugState(game: anytype, content: []const u8) void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t\r");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
        const on = std.mem.eql(u8, val, "1");

        if (std.mem.eql(u8, key, "gizmos_enabled")) {
            game.gizmos_enabled = on;
        } else if (std.mem.eql(u8, key, "debug_visible")) {
            debug_visible = on;
        } else if (std.mem.eql(u8, key, "show_perf")) {
            show_perf = on;
        } else if (std.mem.eql(u8, key, "show_entities")) {
            show_entities = on;
        } else if (std.mem.eql(u8, key, "time_scale")) {
            const scale = std.fmt.parseFloat(f32, val) catch continue;
            game.setTimeScale(scale);
        } else if (std.mem.startsWith(u8, key, "category_")) {
            const id_str = key["category_".len..];
            const id = std.fmt.parseInt(u8, id_str, 10) catch continue;
            game.setGizmoCategory(id, on);
        } else if (std.mem.startsWith(u8, key, "filter_")) {
            const id_str = key["filter_".len..];
            const id = std.fmt.parseInt(usize, id_str, 10) catch continue;
            if (id < MAX_COMPONENTS) component_filters[id] = on;
        }
    }
}

fn saveDebugState(game: anytype) void {
    // Stubbed during 0.16 migration — see loadDebugState above.
    _ = game;
}

/// Serialize debug state into a buffer. Returns bytes written.
fn serializeDebugState(game: anytype, buf: *[4096]u8) usize {
    var pos: usize = 0;

    const fields = .{
        .{ "debug_visible", debug_visible },
        .{ "show_perf", show_perf },
        .{ "show_entities", show_entities },
        .{ "gizmos_enabled", game.gizmos_enabled },
    };
    inline for (fields) |f| {
        const line = std.fmt.bufPrint(buf[pos..], "{s}={s}\n", .{ f[0], if (f[1]) "1" else "0" }) catch return pos;
        pos += line.len;
    }

    // Time scale
    {
        const line = std.fmt.bufPrint(buf[pos..], "time_scale={d:.2}\n", .{game.getTimeScale()}) catch return pos;
        pos += line.len;
    }

    // Gizmo categories
    {
        const line = std.fmt.bufPrint(buf[pos..], "category_0={s}\n", .{if (game.isGizmoCategoryEnabled(0)) "1" else "0"}) catch return pos;
        pos += line.len;
    }
    const categories = @TypeOf(game.*).gizmo_categories;
    for (categories) |cat| {
        const line = std.fmt.bufPrint(buf[pos..], "category_{d}={s}\n", .{ cat.id, if (game.isGizmoCategoryEnabled(cat.id)) "1" else "0" }) catch return pos;
        pos += line.len;
    }

    // Component filters
    for (0..MAX_COMPONENTS) |i| {
        if (component_filters[i]) {
            const line = std.fmt.bufPrint(buf[pos..], "filter_{d}=1\n", .{i}) catch return pos;
            pos += line.len;
        }
    }

    return pos;
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

const GizmoCategoryEntry = struct { name: []const u8, id: u8 };

const MockGame = struct {
    gizmos_enabled: bool = true,
    time_scale: f32 = 1.0,
    category_enabled: [32]bool = [_]bool{true} ** 32,

    pub const gizmo_categories = [_]GizmoCategoryEntry{
        .{ .name = "Workers", .id = 1 },
        .{ .name = "Navigation", .id = 2 },
    };

    pub fn setTimeScale(self: *MockGame, scale: f32) void {
        self.time_scale = scale;
    }
    pub fn getTimeScale(self: *const MockGame) f32 {
        return self.time_scale;
    }
    pub fn setGizmoCategory(self: *MockGame, cat: u8, on: bool) void {
        if (cat < 32) self.category_enabled[cat] = on;
    }
    pub fn isGizmoCategoryEnabled(self: *const MockGame, cat: u8) bool {
        if (cat >= 32) return false;
        return self.category_enabled[cat];
    }
};

fn resetModuleState() void {
    debug_visible = false;
    show_perf = true;
    show_entities = false;
    component_filters = [_]bool{false} ** MAX_COMPONENTS;
}

test "roundtrip: save then load restores state" {
    resetModuleState();
    var game = MockGame{};

    // Set non-default state
    debug_visible = true;
    show_perf = false;
    show_entities = true;
    game.gizmos_enabled = false;
    game.time_scale = 0.5;
    game.setGizmoCategory(0, false);
    game.setGizmoCategory(1, false);
    game.setGizmoCategory(2, true);
    component_filters[3] = true;
    component_filters[7] = true;

    // Serialize
    var buf: [4096]u8 = undefined;
    const len = serializeDebugState(&game, &buf);
    const content = buf[0..len];

    // Reset everything
    resetModuleState();
    game = MockGame{};

    // Deserialize
    applyDebugState(&game, content);

    try testing.expect(debug_visible == true);
    try testing.expect(show_perf == false);
    try testing.expect(show_entities == true);
    try testing.expect(game.gizmos_enabled == false);
    try testing.expectApproxEqAbs(@as(f32, 0.5), game.time_scale, 0.01);
    try testing.expect(game.category_enabled[0] == false);
    try testing.expect(game.category_enabled[1] == false);
    try testing.expect(game.category_enabled[2] == true);
    try testing.expect(component_filters[3] == true);
    try testing.expect(component_filters[7] == true);
    try testing.expect(component_filters[0] == false);

    resetModuleState();
}

test "CRLF line endings are handled" {
    resetModuleState();
    var game = MockGame{};

    const content = "debug_visible=1\r\nshow_perf=0\r\ngizmos_enabled=0\r\ntime_scale=2.00\r\n";
    applyDebugState(&game, content);

    try testing.expect(debug_visible == true);
    try testing.expect(show_perf == false);
    try testing.expect(game.gizmos_enabled == false);
    try testing.expectApproxEqAbs(@as(f32, 2.0), game.time_scale, 0.01);

    resetModuleState();
}

test "unknown keys are ignored" {
    resetModuleState();
    var game = MockGame{};

    const content = "debug_visible=1\nfoo_bar=1\nunknown=hello\nshow_perf=0\n";
    applyDebugState(&game, content);

    try testing.expect(debug_visible == true);
    try testing.expect(show_perf == false);
    // game state unchanged for unknown keys
    try testing.expect(game.gizmos_enabled == true);

    resetModuleState();
}

test "empty content does nothing" {
    resetModuleState();
    var game = MockGame{};
    game.gizmos_enabled = false;

    applyDebugState(&game, "");

    try testing.expect(game.gizmos_enabled == false);
    try testing.expect(debug_visible == false);

    resetModuleState();
}

fn formatField(buf: []u8, name: []const u8, comptime T: type, value: T) ![:0]u8 {
    return switch (@typeInfo(T)) {
        .float => std.fmt.bufPrintZ(buf, "{s}: {d:.3}", .{ name, value }),
        .int, .comptime_int => std.fmt.bufPrintZ(buf, "{s}: {d}", .{ name, value }),
        .bool => std.fmt.bufPrintZ(buf, "{s}: {s}", .{ name, if (value) "true" else "false" }),
        .@"enum" => std.fmt.bufPrintZ(buf, "{s}: {s}", .{ name, @tagName(value) }),
        else => std.fmt.bufPrintZ(buf, "{s}: ({s})", .{ name, @typeName(T) }),
    };
}

test "perf rows sort by per-frame cost, setup excluded" {
    var rows = [_]PerfRow{
        .{ .name = "cheap", .tick_ns = 50_000, .setup_ns = 900_000_000 },
        .{ .name = "hot", .tick_ns = 1_200_000, .post_ns = 300_000 },
        .{ .name = "mid", .tick_ns = 220_000, .gui_ns = 400_000 },
    };
    std.mem.sort(PerfRow, &rows, {}, perfRowDesc);
    try testing.expectEqualStrings("hot", rows[0].name);
    try testing.expectEqualStrings("mid", rows[1].name);
    // 900ms of setup must NOT outrank recurring cost.
    try testing.expectEqualStrings("cheap", rows[2].name);
    try testing.expectEqual(@as(u64, 1_500_000), rows[0].frameNs());
}

test "insertTopRow keeps the priciest N even when a hot row is beyond the cap" {
    // MAX_PERF_ROWS+ units where the PRICIEST rows are registered LAST
    // (indices past the cap) — exactly what truncate-before-sort drops.
    // The streaming inserter must still land them in the top-N.
    var buf: [MAX_PERF_ROWS]PerfRow = undefined;
    var count: usize = 0;

    var i: usize = 0;
    while (i < MAX_PERF_ROWS) : (i += 1) {
        insertTopRow(&buf, &count, .{ .name = "cheap", .tick_ns = 1_000 });
    }
    try testing.expectEqual(MAX_PERF_ROWS, count);

    // Expensive rows arriving AFTER the buffer is already full.
    insertTopRow(&buf, &count, .{ .name = "priciest", .tick_ns = 9_000_000 });
    insertTopRow(&buf, &count, .{ .name = "second", .tick_ns = 2_000_000 });

    try testing.expectEqual(MAX_PERF_ROWS, count); // never exceeds the cap
    try testing.expectEqualStrings("priciest", buf[0].name); // late hot rows kept
    try testing.expectEqualStrings("second", buf[1].name);
    try testing.expectEqualStrings("cheap", buf[count - 1].name); // smallest evicted
}

test "insertTopRow leaves rows sorted descending by frame cost" {
    var buf: [4]PerfRow = undefined;
    var count: usize = 0;
    insertTopRow(&buf, &count, .{ .name = "b", .tick_ns = 500 });
    insertTopRow(&buf, &count, .{ .name = "d", .tick_ns = 100 });
    insertTopRow(&buf, &count, .{ .name = "a", .tick_ns = 900 });
    insertTopRow(&buf, &count, .{ .name = "c", .tick_ns = 300 });
    try testing.expectEqual(@as(usize, 4), count);
    try testing.expectEqualStrings("a", buf[0].name);
    try testing.expectEqualStrings("b", buf[1].name);
    try testing.expectEqualStrings("c", buf[2].name);
    try testing.expectEqualStrings("d", buf[3].name);
}

test "severity marks: green blank, yellow *, red !" {
    try testing.expectEqualStrings("", severityMark(0));
    try testing.expectEqualStrings("", severityMark(999_999));
    try testing.expectEqualStrings("*", severityMark(1_000_000));
    try testing.expectEqualStrings("*", severityMark(4_999_999));
    try testing.expectEqualStrings("!", severityMark(5_000_000));
}

test "fmtPhase renders ms with marker, dash for zero" {
    var buf: [24]u8 = undefined;
    try testing.expectEqualStrings("-", fmtPhase(&buf, 0));
    try testing.expectEqualStrings("0.45", fmtPhase(&buf, 450_000));
    try testing.expectEqualStrings("1.20*", fmtPhase(&buf, 1_200_000));
    try testing.expectEqualStrings("6.00!", fmtPhase(&buf, 6_000_000));
}

test "phaseNs tolerates rows without the phase field" {
    const Old = struct { name: []const u8, tick: struct { last_ns: u64 } };
    const r = Old{ .name = "x", .tick = .{ .last_ns = 42 } };
    try testing.expectEqual(@as(u64, 42), phaseNs(r, "tick"));
    try testing.expectEqual(@as(u64, 0), phaseNs(r, "setup"));
}
