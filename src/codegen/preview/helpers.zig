//! Module-scope preview helper snippets (clock/getenv wrapper + raylib
//! desktop PBO readback bridges). Extracted from `preview.zig`.

/// Module-scope helpers the preview blocks rely on. `getenv` and
/// `clock_gettime` are at module scope because `extern "c" fn`
/// must be; both names are unique within the generated main.zig.
/// `_preview_now_ms` is a tiny libc clock_gettime wrapper that
/// stands in for the now-removed `std.time.milliTimestamp`.
pub const PREVIEW_HELPERS =
    \\
    \\const _PreviewTimespec = extern struct { sec: isize, nsec: isize };
    \\const _preview_getenv = @extern(
    \\    *const fn (name: [*:0]const u8) callconv(.c) ?[*:0]const u8,
    \\    .{ .name = "getenv" },
    \\);
    \\const _preview_clock_gettime = @extern(
    \\    *const fn (clk_id: c_int, tp: *_PreviewTimespec) callconv(.c) c_int,
    \\    .{ .name = "clock_gettime" },
    \\);
    \\fn _preview_now_ms() u64 {
    \\    const CLOCK_MONOTONIC: c_int = if (@import("builtin").os.tag == .macos) 6 else 1;
    \\    var ts: _PreviewTimespec = undefined;
    \\    _ = _preview_clock_gettime(CLOCK_MONOTONIC, &ts);
    \\    return @intCast(@as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000));
    \\}
    \\
;

/// Raw GL externs + constants needed for the raylib desktop PBO-based
/// async readback path. Raylib links the platform's OpenGL loader on
/// desktop (CGL / GLX / WGL), so PBO entry points are present as
/// regular `extern "c"` symbols — `@extern` here resolves them at link
/// time without any extra dependency.
///
/// Concatenated into `module_vars` for raylib-desktop only. Other
/// loop backends (sdl/bgfx/wgpu) don't use these and don't ship them
/// (their readback story is a separate ticket). The constants are GL
/// 2.1 / 3.3 core values — stable across drivers and platforms.
pub const PREVIEW_READBACK_HELPERS =
    \\
    \\// ── Preview readback bridges (labelle-assembler#140) ──
    \\// All GL state + PBO ring + per-frame readback machinery now
    \\// lives in the external labelle-raylib package
    \\// (`src/window.zig:preview_pbo`). The
    \\// codegen owns only these tiny bridge fns that wrap
    \\// `engine.Preview` methods behind an `*anyopaque` boundary so
    \\// the backend module doesn't need an engine type-import.
    \\fn _preview_pbo_begin_bridge(ctx: *anyopaque, w: u32, h: u32) anyerror!void {
    \\    const p: *engine.Preview = @ptrCast(@alignCast(ctx));
    \\    return p.beginFrameStream(w, h);
    \\}
    \\fn _preview_pbo_publish_bridge(ctx: *anyopaque, pixels: []const u8) anyerror!void {
    \\    const p: *engine.Preview = @ptrCast(@alignCast(ctx));
    \\    return p.publishFrame(pixels);
    \\}
    \\fn _preview_pbo_end_bridge(ctx: *anyopaque) void {
    \\    const p: *engine.Preview = @ptrCast(@alignCast(ctx));
    \\    p.endFrameStream();
    \\}
    \\fn _preview_pbo_begin_ios_bridge(ctx: *anyopaque, w: u32, h: u32) anyerror!void {
    \\    const p: *engine.Preview = @ptrCast(@alignCast(ctx));
    \\    return p.beginFrameStreamIOSurface(w, h);
    \\}
    \\fn _preview_pbo_publish_ios_bridge(ctx: *anyopaque, pixels: []const u8) anyerror!void {
    \\    const p: *engine.Preview = @ptrCast(@alignCast(ctx));
    \\    return p.publishFrameIOSurface(pixels);
    \\}
    \\fn _preview_pbo_end_ios_bridge(ctx: *anyopaque) void {
    \\    const p: *engine.Preview = @ptrCast(@alignCast(ctx));
    \\    p.endFrameStreamIOSurface();
    \\}
    \\fn _preview_pbo_accepted_bridge(ctx: *anyopaque) bool {
    \\    const p: *const engine.Preview = @ptrCast(@alignCast(ctx));
    \\    return p.isFrameAccepted();
    \\}
    \\
;
