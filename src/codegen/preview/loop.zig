//! Preview snippets for loop-style backends (raylib desktop, sdl, bgfx,
//! wgpu): setup, readback, heartbeat, input dispatch. Extracted from `preview.zig`.

/// In-function preview setup for loop-style main()s. Parses argv,
/// dials the editor, assigns directly into `g.preview`, sends `hello`.
/// Pasted AFTER `var g = AssembledGame.init(...)` so the engine's
/// ECS lifecycle (createEntity / destroyEntity / addComponent) can
/// emit Phase 2 telemetry from the very first scene load
/// (labelle-engine#520).
///
/// Ownership note: `Game.deinit` owns the `Preview` teardown. The
/// `defer` here only emits the graceful `bye` frame; the socket
/// close + arena deinit run inside `g.deinit()` (registered earlier
/// in the same scope, so LIFO runs `sendBye` first, then `g.deinit`).
pub const PREVIEW_LOOP_SETUP =
    \\    // ── Preview mode (labelle-assembler#94, labelle-engine#520) ──
    \\    // Connect to the editor's TCP listener when `LABELLE_PREVIEW=host:port`
    \\    // is set in the environment. (Zig 0.16 removed `std.process.argsAlloc`
    \\    // and the easy path to argv without changing `pub fn main()`'s
    \\    // signature, so the env-var hand-off is the smallest restoration.)
    \\    if (_preview_getenv("LABELLE_PREVIEW")) |_env_z| {
    \\        const _host_port = std.mem.span(_env_z);
    \\        if (_host_port.len > 0) {
    \\            var _preview_threaded = std.Io.Threaded.init(allocator, .{});
    \\            defer _preview_threaded.deinit();
    \\            g.preview = engine.Preview.connect(_preview_threaded.io(), allocator, _host_port) catch |err| blk: {
    \\                std.debug.print("labelle: preview-mode connect to '{s}' failed: {s}\n", .{ _host_port, @errorName(err) });
    \\                break :blk null;
    \\            };
    \\            if (g.preview) |*_p| _p.sendHello("labelle-engine", 0) catch {};
    \\        }
    \\    }
    \\    defer if (g.preview) |*_p| {
    \\        _p.sendBye(.normal) catch {};
    \\    };
    \\
;

/// Raylib-desktop-only addendum to `PREVIEW_LOOP_SETUP`. Declares the
/// PBO ring + CPU staging buffer locals that `PREVIEW_READBACK_LOOP`
/// uses, and registers the deferred GL/SHM teardown. Pasted right
/// after `PREVIEW_LOOP_SETUP` so both run inside `main()`'s scope and
/// `g` is already bound.
///
/// The `endFrameStream` defer lives here (not in `PREVIEW_LOOP_SETUP`)
/// because only the readback path actually opens the SHM ring. Other
/// loop backends never call `beginFrameStream`, so calling
/// `endFrameStream` would be a no-op but the symbol `_gl_delete_buffers`
/// in the same defer block isn't available to them — splitting keeps
/// the non-raylib loop backends compiling unchanged.
///
/// macOS path (labelle-assembler#121, labelle-engine#547): when the
/// generated game is built for macOS, the engine exposes a zero-copy
/// IOSurface variant of the same lifecycle triple
/// (`beginFrameStreamIOSurface` / `publishFrameIOSurface` /
/// `endFrameStreamIOSurface`). The teardown defer here picks the
/// matching `end*` at comptime so the right side is closed.
pub const PREVIEW_READBACK_SETUP =
    \\    // labelle-assembler#140 — preview readback is now
    \\    // backend-internal. Wire engine.Preview methods into the
    \\    // backend vtable + register cleanup. The bridges below
    \\    // are emitted at module scope by PREVIEW_READBACK_HELPERS.
    \\    if (g.preview) |*_p| {
    \\        window.preview_pbo.attach(.{
    \\            .ctx = @ptrCast(_p),
    \\            .beginFrameStream = _preview_pbo_begin_bridge,
    \\            .publishFrame = _preview_pbo_publish_bridge,
    \\            .endFrameStream = _preview_pbo_end_bridge,
    \\            .beginFrameStreamIOSurface = _preview_pbo_begin_ios_bridge,
    \\            .publishFrameIOSurface = _preview_pbo_publish_ios_bridge,
    \\            .endFrameStreamIOSurface = _preview_pbo_end_ios_bridge,
    \\            .isFrameAccepted = _preview_pbo_accepted_bridge,
    \\        }, allocator);
    \\    }
    \\    defer window.preview_pbo.deinit();
    \\
;

/// Heartbeat tick — rate-limited inside `tickHeartbeat`. Safe to
/// call every frame; ~4 Hz on the wire regardless of FPS.
///
/// `pollSubscription` runs first so a malformed subscribe frame
/// doesn't poison the same flush as the heartbeat write. It's
/// non-blocking (peeks the socket via `EAGAIN`) and drains any
/// `subscribe` / `unsubscribe` JSON lines the editor sent since
/// the last tick — without it the engine never reads the
/// `subscribed_components` set that gates `component_changed`
/// frames (labelle-engine#520 paired with labelle-assembler#96).
pub const PREVIEW_HEARTBEAT_LOOP =
    \\        if (g.preview) |*_p| {
    \\            _p.pollSubscription() catch {};
    \\            _p.tickHeartbeat(_preview_now_ms()) catch {};
    \\            // Drain editor → game input events (labelle-assembler#143).
    \\            // The imgui plugin's sokol bridge exposes thin shims over
    \\            // `simgui_add_*_event`; we link weakly so projects without
    \\            // the plugin still build.
    \\            while (_p.popInputEvent()) |_ev| {
    \\                switch (_ev) {
    \\                    .mouse_pos => |_m| _preview_input_mouse_pos(_m.x, _m.y),
    \\                    .mouse_button => |_m| _preview_input_mouse_button(_m.button, _m.down),
    \\                }
    \\            }
    \\        }
    \\
;

/// Wrappers around the imgui sokol bridge's mouse-event exports.
/// Emitted only when the project's gui plugin is *imgui* specifically —
/// the `imgui_bridge_mouse_*` externs only resolve against the imgui
/// bridge. Projects with a different gui plugin (clay, simple-raylib,
/// simple-sokol, …) or no gui at all get `PREVIEW_INPUT_DISPATCH_STUB`,
/// so the `_preview_input_*` symbols still resolve in PREVIEW_HEARTBEAT_LOOP
/// (the drain just discards events).
pub const PREVIEW_INPUT_DISPATCH =
    \\extern fn imgui_bridge_mouse_pos(x: f32, y: f32) void;
    \\extern fn imgui_bridge_mouse_button(button: i32, down: bool) void;
    \\
    \\fn _preview_input_mouse_pos(x: f32, y: f32) void {
    \\    imgui_bridge_mouse_pos(x, y);
    \\}
    \\fn _preview_input_mouse_button(button: i32, down: bool) void {
    \\    imgui_bridge_mouse_button(button, down);
    \\}
    \\
;

pub const PREVIEW_INPUT_DISPATCH_STUB =
    \\fn _preview_input_mouse_pos(_: f32, _: f32) void {}
    \\fn _preview_input_mouse_button(_: i32, _: bool) void {}
    \\
;

/// PBO-based async GPU→CPU readback that runs inside the raylib desktop
/// frame loop, between `g.render*` and `window.endFrame()`
/// (labelle-engine#544).
///
/// Translates the imgui-preview PoC's 3-deep PBO ring into the
/// generated main:
///
///   frame N   : bind pbo[N % 3] → glReadPixels (async DMA into PBO)
///   frame N+2 : bind pbo[(N-2) % 3] → glMapBuffer → memcpy to CPU
///               → Preview.publishFrame → unmap
///
/// The 2-frame priming gap is what hides the GPU→CPU stall; the first
/// two frames only kick off readback and publish nothing. From frame
/// 2 onwards we always have a mature PBO to map.
///
/// Resize handling: the screen dims are read every frame from
/// `window.width()`/`window.height()`. When they differ from the last
/// published dims we tear the PBO ring + CPU buffer down, re-issue
/// `Preview.beginFrameStream(w,h)` (idempotent — internally re-offers
/// + frees the prior SHM ring), and reset the priming counter. The
/// editor responds with a fresh `frame_accept` and publishes resume
/// on the next pass through the priming gap.
///
/// All allocator failures + GL errors are swallowed; preview is a
/// best-effort sidecar, never a reason to crash the game.
///
/// macOS path (labelle-assembler#121, labelle-engine#547): the per-frame
/// glReadPixels + PBO ring is identical, but the engine API surface
/// switches at comptime to the zero-copy IOSurface triple
/// (`beginFrameStreamIOSurface` / `publishFrameIOSurface`). The
/// producer-side pixel buffer stays RGBA8 — `publishFrameIOSurface`
/// does the RGBA→BGRA swizzle internally during the IOSurface
/// lock/copy, so no producer-side format change is needed.
pub const PREVIEW_READBACK_LOOP =
    \\        if (g.preview) |*_p| {
    \\            _ = _p;
    \\            window.preview_pbo.frame();
    \\        }
    \\
;
