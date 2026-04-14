/// Nuklear GUI adapter — satisfies the engine GuiInterface contract
/// including the standard widget API for debug tooling.
pub const nk = @import("nuklear");
const c = nk.c;

extern fn nk_bridge_init() void;
extern fn nk_bridge_begin() void;
extern fn nk_bridge_end() void;
extern fn nk_bridge_shutdown() void;
extern fn nk_bridge_get_context() *c.nk_context;

pub fn init() void {
    nk_bridge_init();
}

pub fn shutdown() void {
    nk_bridge_shutdown();
}

pub fn begin() void {
    // Reset the per-frame window counter so `beginWindow` staggers
    // siblings correctly (see `windows_this_frame` below).
    windows_this_frame = 0;
    nk_bridge_begin();
}

pub fn end() void {
    nk_bridge_end();
}

pub fn getContext() *c.nk_context {
    return nk_bridge_get_context();
}

pub fn wantsMouse() bool {
    return c.nk_item_is_any_active(nk_bridge_get_context()) != 0;
}

pub fn wantsKeyboard() bool {
    // Nuklear captures the keyboard when any widget has focus —
    // typically a text input or similar active editor. Reporting
    // false unconditionally (the pre-fix behaviour) meant games
    // happily consumed keypresses meant for an active text field.
    return c.nk_item_is_any_active(nk_bridge_get_context()) != 0;
}

// ── Standard widget API ────────────────────────────────────

// Monotonic counter of windows opened this frame. Used to stagger
// the initial position of each window so multiple `beginWindow`
// calls on the same frame don't stack perfectly on top of each
// other. Reset at the start of every frame in `begin()` — the
// previous code decremented in `endWindow`, which made sequential
// siblings see the same offset (0) and overlap perfectly.
var windows_this_frame: u32 = 0;
var in_table: bool = false;
var table_columns: i32 = 1;

pub fn beginWindow(name: [*:0]const u8) bool {
    const ctx = nk_bridge_get_context();
    const offset: f32 = @as(f32, @floatFromInt(windows_this_frame)) * 30;
    windows_this_frame += 1;
    return c.nk_begin(ctx, name, .{ .x = 20 + offset, .y = 20 + offset, .w = 400, .h = 500 }, c.NK_WINDOW_BORDER | c.NK_WINDOW_MOVABLE | c.NK_WINDOW_SCALABLE | c.NK_WINDOW_TITLE | c.NK_WINDOW_MINIMIZABLE);
}

pub fn endWindow() void {
    c.nk_end(nk_bridge_get_context());
    // Do NOT touch `windows_this_frame` here — decrementing would
    // collapse sequential siblings onto the same offset. The
    // counter is reset in `begin()` once per frame.
}

pub fn separator() void {
    if (in_table) return;
    const ctx = nk_bridge_get_context();
    c.nk_layout_row_dynamic(ctx, 5, 1);
    c.nk_spacing(ctx, 1);
}

pub fn spacing() void {
    if (in_table) return;
    const ctx = nk_bridge_get_context();
    c.nk_layout_row_dynamic(ctx, 5, 1);
    c.nk_spacing(ctx, 1);
}

pub fn sameLine() void {
    // No-op in Nuklear — use tables for multi-column layouts
}

pub fn label(str: [*:0]const u8) void {
    const ctx = nk_bridge_get_context();
    if (!in_table) {
        c.nk_layout_row_dynamic(ctx, 20, 1);
    }
    c.nk_label(ctx, str, c.NK_TEXT_LEFT);
}

pub fn textFmt(fmt: [*:0]const u8, args: anytype) void {
    const ctx = nk_bridge_get_context();
    if (!in_table) {
        c.nk_layout_row_dynamic(ctx, 20, 1);
    }
    @call(.auto, c.nk_labelf, .{ ctx, c.NK_TEXT_LEFT, fmt } ++ args);
}

pub fn button(str: [*:0]const u8) bool {
    const ctx = nk_bridge_get_context();
    if (!in_table) {
        c.nk_layout_row_dynamic(ctx, 30, 1);
    }
    return c.nk_button_label(ctx, str);
}

pub fn checkbox(str: [*:0]const u8, val: *bool) bool {
    const ctx = nk_bridge_get_context();
    if (!in_table) {
        c.nk_layout_row_dynamic(ctx, 25, 1);
    }
    const old = val.*;
    _ = c.nk_checkbox_label(ctx, str, val);
    return val.* != old;
}

pub fn sliderFloat(str: [*:0]const u8, val: *f32, min: f32, max: f32) bool {
    const ctx = nk_bridge_get_context();
    c.nk_layout_row_dynamic(ctx, 20, 1);
    c.nk_label(ctx, str, c.NK_TEXT_LEFT);
    c.nk_layout_row_dynamic(ctx, 25, 1);
    const old = val.*;
    _ = c.nk_slider_float(ctx, min, val, max, (max - min) / 100.0);
    return val.* != old;
}

pub fn treeNode(str: [*:0]const u8) bool {
    const ctx = nk_bridge_get_context();
    var hash: u32 = 5381;
    var i: usize = 0;
    while (str[i] != 0) : (i += 1) {
        hash = hash *% 33 +% str[i];
    }
    return c.nk_tree_push_hashed(ctx, c.NK_TREE_NODE, str, c.NK_MINIMIZED, "debug", 5, @as(c_int, @intCast(hash % 0x7FFFFFFF)));
}

pub fn treePop() void {
    c.nk_tree_pop(nk_bridge_get_context());
}

pub fn beginTable(_: [*:0]const u8, columns: i32) bool {
    const ctx = nk_bridge_get_context();
    in_table = true;
    table_columns = columns;
    c.nk_layout_row_dynamic(ctx, 20, columns);
    return true;
}

pub fn endTable() void {
    in_table = false;
    table_columns = 1;
}

pub fn tableNextRow() void {
    const ctx = nk_bridge_get_context();
    c.nk_layout_row_dynamic(ctx, 20, table_columns);
}

pub fn tableNextColumn() bool {
    return true;
}
