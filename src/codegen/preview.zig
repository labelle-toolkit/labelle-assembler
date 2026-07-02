//! Preview-mode codegen string templates extracted from `main_zig.zig`
//! (part of labelle-toolkit/labelle-assembler#183). All snippets are
//! pure string literals consumed by `generateMainZigFromTemplate` via
//! `std.mem.concat` — no logic lives here. See
//! `docs/REFACTOR-PLAN-main-zig.md` for the full cut plan.

const std = @import("std");

// ============================================================
// Preview-mode codegen (PIE Phase 1, labelle-assembler#94)
// ============================================================
//
// Emit the `--preview-mode <host:port>` argv parser + `engine.Preview`
// lifecycle into every generated `main.zig`. The engine ships the
// primitives in `labelle-engine/src/preview_mode.zig` (re-exported via
// `engine.parsePreviewArgs` / `engine.Preview`) — this is the
// assembler's job of actually calling them at the right places.
//
// Loop backends (raylib desktop, sdl, bgfx, wgpu) get a single
// in-function block before the main loop plus a heartbeat call inside
// the loop body. Callback backends (sokol, raylib wasm) hoist
// `_preview` to module scope so `init` can connect, `frame` can
// heartbeat, and `cleanup` can sendBye + deinit cleanly.
//
// All snippets are emit-always: when `--preview-mode` is absent the
// runtime parse returns null and the rest of the block compiles down
// to a no-op `if (null) ...`. Keeping it unconditional avoids a
// project.labelle opt-in flag and matches the umbrella's "every
// generated binary speaks preview" intent (labelle-gui#59).

// PID is purely informational in the `hello` message — the editor
// uses it for UI display, not for any process management. Earlier
// snippets tried a per-OS comptime branch (`std.posix.getpid()` on
// POSIX, kernel32 on Windows) but `std.posix.getpid` isn't exposed
// in Zig 0.15.2's stdlib (only `std.os.linux.getpid` and
// `std.c.getpid` exist, and the latter requires linking libc which
// not every backend does). Simplest portable fix: send 0. A
// follow-up can wire the real PID once we settle on a stdlib import
// that's universal across our backends.

/// Workaround for Zig 0.16.0 wasm32-emscripten compile failure
/// (labelle-assembler#141). The default panic handler in 0.16.0
/// transitively imports `std.Io.Threaded`, whose posix wrappers fail
/// to type-check against emscripten's signal-enum shape
/// (`std/Io/Threaded.zig:15315` / `std/os/emscripten.zig:215`).
/// Overriding both `std_options_debug_io` and `panic` at the root
/// source keeps the default panic-handler chain from instantiating
/// `std.Io.Threaded`. This is the workaround recommended on the
/// Ziggit forum thread linked below and lands the documented fix
/// inside the generated `main.zig`.
///
/// Fixed upstream on Zig master by PR #31850 (lands in 0.17.0-dev);
/// drop this once labelle-toolkit moves off 0.16.x.
///
/// NOTE: this only neutralises the *implicit* path from the panic
/// handler. The generated preview-mode block (PREVIEW_INIT_CALLBACK)
/// still calls `std.Io.Threaded.init(...).io()` directly, which
/// re-instantiates the offending type. Skipping that on wasm is a
/// separate follow-up (the preview env-var is never set in a browser
/// context anyway).
///
/// References:
///   https://ziggit.dev/t/0-16-0-wasm32-emscripten-fails-to-build-because-of-default-panic-handler-recommended-workaround/15052
///   PR #31850 (Zig upstream)
///
/// Emitted only when `cfg.platform == .wasm`; lands near the top of
/// the generated `main.zig` so the two `pub const` decls are at
/// module root (Zig looks up these override names there).
pub const WASM_PANIC_WORKAROUND =
    \\
    \\// Zig 0.16.0 wasm32-emscripten: override the default panic handler to
    \\// avoid std.Io.Threaded import (which has broken posix wrappers on
    \\// emscripten). Fixed upstream in 0.17.0-dev (PR #31850); remove this
    \\// once labelle-toolkit moves off 0.16.
    \\// https://ziggit.dev/t/0-16-0-wasm32-emscripten-fails-to-build-because-of-default-panic-handler-recommended-workaround/15052
    \\pub const std_options_debug_io = std.Io.failing;
    \\pub const panic = std.debug.no_panic;
    \\
;

/// Reduced form of `WASM_PANIC_WORKAROUND` for backends whose `templates/wasm.txt`
/// ALREADY declares its own `pub const panic` (e.g. bgfx's browser-console
/// handler). Emitting the full workaround's `panic = no_panic` there is a
/// duplicate root decl, but the `std_options_debug_io` override is STILL required
/// and is INDEPENDENT of `panic`: `std.Options.debug_io` (std/std.zig) resolves to
/// the `std.Io.Threaded`-backed `debug_threaded_io` UNLESS root declares
/// `std_options_debug_io` — and that Threaded path is what fails to compile for
/// wasm32-emscripten on Zig 0.16 (labelle-assembler#141). So emit ONLY the
/// debug-io override here; the backend template owns `panic` (+ typically
/// `std_options`). Dropped once labelle-toolkit moves off Zig 0.16.x (PR #31850).
pub const WASM_DEBUG_IO_WORKAROUND =
    \\
    \\// Zig 0.16.0 wasm32-emscripten: override the default debug IO so the
    \\// std.Io.Threaded path (broken posix wrappers on emscripten) is never
    \\// instantiated. The backend's wasm template supplies its own `pub const
    \\// panic`, so only this half of the labelle-assembler#141 workaround is
    \\// emitted here. Fixed upstream in 0.17.0-dev (PR #31850).
    \\// https://ziggit.dev/t/0-16-0-wasm32-emscripten-fails-to-build-because-of-default-panic-handler-recommended-workaround/15052
    \\pub const std_options_debug_io = std.Io.failing;
    \\
;

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

/// Init-callback preview block. Runs once at startup, AFTER
/// `g = AssembledGame.init(...)` — `g.preview` is the canonical
/// storage; no module-level `_preview` needed.
///
/// Note: the original `catch &[_][:0]u8{}` form gave `_argv` a
/// `[]const [:0]u8` type, which doesn't satisfy `argsFree`'s
/// `[][:0]u8` parameter. The `if/else |_|` shape pulls the alloc
/// success path into its own scope where `_argv`'s type matches.
pub const PREVIEW_INIT_CALLBACK =
    \\    // ── Preview mode (labelle-assembler#94, labelle-engine#520) ──
    \\    // Sokol callback path: connect once in `init`, frame-callback
    \\    // pulses the heartbeat, cleanup-callback sends bye. Storage is
    \\    // `g.preview` (Game owns the lifecycle); see PREVIEW_LOOP_SETUP
    \\    // above for the env-var rationale.
    \\    if (_preview_getenv("LABELLE_PREVIEW")) |_env_z| {
    \\        const _host_port = std.mem.span(_env_z);
    \\        if (_host_port.len > 0) {
    \\            var _preview_threaded = std.Io.Threaded.init(allocator, .{});
    \\            defer _preview_threaded.deinit();
    \\            g.preview = engine.Preview.connect(_preview_threaded.io(), allocator, _host_port) catch |err| blk: {
    \\                std.debug.print("labelle: preview-mode connect to '{s}' failed: {s}\n", .{ _host_port, @errorName(err) });
    \\                break :blk null;
    \\            };
    \\            if (g.preview) |*_p| {
    \\                _p.sendHello("labelle-engine", 0) catch {};
    \\                // labelle-assembler#140 Phase B: wire the engine.Preview
    \\                // methods into the backend's preview_mtl vtable so the
    \\                // backend can drive IOSurface stream lifecycle without
    \\                // needing an engine type-import. Bridges declared at
    \\                // module scope (see PREVIEW_READBACK_HELPERS_METAL_SOKOL).
    \\                if (comptime @hasDecl(window, "preview_mtl")) {
    \\                    window.preview_mtl.attach(.{
    \\                        .ctx = @ptrCast(_p),
    \\                        .beginStream = _preview_mtl_begin_stream_bridge,
    \\                        .getSurfaceAt = _preview_mtl_get_surface_bridge,
    \\                        .signalSlotReady = _preview_mtl_signal_bridge,
    \\                        .endStream = _preview_mtl_end_stream_bridge,
    \\                        .isFrameAccepted = _preview_mtl_accepted_bridge,
    \\                    });
    \\                }
    \\                if (comptime @hasDecl(window, "hideWindow")) window.hideWindow();
    \\            }
    \\        }
    \\    }
    \\
;

/// Cleanup-callback preview teardown. Only emits the graceful `bye`
/// frame — `Game.deinit` (called by `{{cleanup_code}}` immediately
/// after) owns the actual socket + arena teardown
/// (labelle-engine#520).
pub const PREVIEW_CLEANUP_CALLBACK =
    \\    if (g.preview) |*_p| _p.sendBye(.normal) catch {};
    \\
;

/// Heartbeat for sokol's frame callback (one extra indent level vs.
/// the loop variant, since sokol's `frame` body sits at function scope
/// not inside a `while`).
///
/// Same poll-before-write ordering as the loop variant: drain any
/// `subscribe` / `unsubscribe` frames the editor sent BEFORE the
/// heartbeat write so a malformed subscription can't poison the
/// outbound flush. See the loop variant for the full rationale.
pub const PREVIEW_HEARTBEAT_CALLBACK =
    \\    if (g.preview) |*_p| {
    \\        _p.pollSubscription() catch {};
    \\        _p.tickHeartbeat(_preview_now_ms()) catch {};
    \\        while (_p.popInputEvent()) |_ev| {
    \\            switch (_ev) {
    \\                .mouse_pos => |_m| _preview_input_mouse_pos(_m.x, _m.y),
    \\                .mouse_button => |_m| _preview_input_mouse_button(_m.button, _m.down),
    \\            }
    \\        }
    \\    }
    \\
;

/// Sokol-specific PBO readback (labelle-assembler#122 slice 1). Same
/// 3-deep PBO ring + 2-frame priming as raylib's `PREVIEW_READBACK_*`
/// (labelle-engine#544), reshaped for sokol's callback lifecycle:
///
///   - State (PBO ids, frame counter, last published dims, CPU staging
///     buffer) lives at *module scope* because the sokol `init` /
///     `frame` / `cleanup` callbacks have no shared local scope.
///   - GL externs are gated by `_sokol_preview_gl_enabled`, a comptime
///     boolean derived from `builtin.os.tag`. Default sokol build picks
///     GLCORE on Linux + GLES3 on Android/web, Metal on macOS/iOS,
///     D3D11 on Windows. Slice 1 only handles the GL paths; Metal /
///     D3D11 are deferred to slices 2 and 3 (#122 follow-ups). The
///     externs hide behind a struct-namespace so non-GL builds never
///     reference unresolved symbols at link time.
///   - The frame block + init seed + cleanup teardown are also gated
///     on the comptime flag — `comptime if (... ) { ... }` elides the
///     entire block on Metal/D3D11 targets, leaving the control-plane
///     wiring (hello/heartbeat/bye) intact but no pixel publish.
pub const PREVIEW_READBACK_HELPERS_SOKOL =
    \\
    \\// ── Sokol PBO readback gating (labelle-assembler#122 slice 1) ──
    \\// Default sokol-zig picks GLCORE on Linux desktop, GLES3 on Android
    \\// and emscripten, Metal on Darwin, D3D11 on Windows. The GL PBO
    \\// path only applies to the first two; Metal / D3D11 are separate
    \\// slices (IOSurface, staging). Comptime-gating on builtin.os.tag
    \\// keeps the GL externs out of non-GL link lines so e.g. a sokol
    \\// macOS build (Metal) doesn't fail to resolve `glReadPixels`.
    \\// Android in Zig is `os.tag == .linux` with `abi == .android` /
    \\// `.androideabi`, so the simple `.linux` arm already covers both
    \\// desktop GLCORE and Android GLES3. Emscripten / wasm32 is left
    \\// as a no-op for now — WebGL2 has limited PBO support and slice 1
    \\// doesn't ship a wasm story (see PR body / #122 follow-ups).
    \\const _sokol_preview_gl_enabled: bool = switch (@import("builtin").os.tag) {
    \\    .linux => true,
    \\    else => false,
    \\};
    \\
    \\// PBO state at module scope — sokol's init / frame / cleanup
    \\// callbacks are separate functions, so the locals raylib's main()
    \\// uses for the same purpose need to live at file scope here.
    \\// `_preview_allocator` mirrors the allocator the game uses; it's
    \\// stashed in the init callback so frame + cleanup can reach the
    \\// CPU staging buffer without re-deriving it from `g`.
    \\var _preview_allocator: std.mem.Allocator = std.mem.Allocator{ .ptr = undefined, .vtable = undefined };
    \\var _preview_pbos: [3]c_uint = .{ 0, 0, 0 };
    \\var _preview_pbo_bytes: usize = 0;
    \\var _preview_pbo_initialized: bool = false;
    \\var _preview_frame_idx: u64 = 0;
    \\var _preview_last_w: u32 = 0;
    \\var _preview_last_h: u32 = 0;
    \\var _preview_pixel_buf: []u8 = &[_]u8{};
    \\
    \\// GL extern decls live inside a struct-namespace gated on
    \\// `_sokol_preview_gl_enabled`. The `else struct {}` branch holds
    \\// no symbols, so a Metal / D3D11 sokol build never emits an
    \\// undefined-symbol reference to `glReadPixels` etc.
    \\const _SokolPreviewGl = if (_sokol_preview_gl_enabled) struct {
    \\    pub const PIXEL_PACK_BUFFER: c_uint = 0x88EB;
    \\    pub const STREAM_READ: c_uint = 0x88E1;
    \\    // GL_MAP_READ_BIT — bit-flag for glMapBufferRange's access.
    \\    // Core in GL 3.0+ AND GLES 3.0+; glMapBuffer is desktop-only
    \\    // and ships on GLES only as `GL_OES_mapbuffer`, so the range
    \\    // variant is the portable choice for Android GLES3 builds.
    \\    pub const MAP_READ_BIT: c_uint = 0x0001;
    \\    pub const PACK_ALIGNMENT: c_uint = 0x0D05;
    \\    pub const RGBA: c_uint = 0x1908;
    \\    pub const UNSIGNED_BYTE: c_uint = 0x1401;
    \\    pub const pixelStorei = @extern(
    \\        *const fn (pname: c_uint, param: c_int) callconv(.c) void,
    \\        .{ .name = "glPixelStorei" },
    \\    );
    \\    pub const genBuffers = @extern(
    \\        *const fn (n: c_int, buffers: [*]c_uint) callconv(.c) void,
    \\        .{ .name = "glGenBuffers" },
    \\    );
    \\    pub const deleteBuffers = @extern(
    \\        *const fn (n: c_int, buffers: [*]const c_uint) callconv(.c) void,
    \\        .{ .name = "glDeleteBuffers" },
    \\    );
    \\    pub const bindBuffer = @extern(
    \\        *const fn (target: c_uint, buffer: c_uint) callconv(.c) void,
    \\        .{ .name = "glBindBuffer" },
    \\    );
    \\    pub const bufferData = @extern(
    \\        *const fn (target: c_uint, size: isize, data: ?*const anyopaque, usage: c_uint) callconv(.c) void,
    \\        .{ .name = "glBufferData" },
    \\    );
    \\    pub const readPixels = @extern(
    \\        *const fn (x: c_int, y: c_int, w: c_int, h: c_int, fmt: c_uint, ty: c_uint, data: ?*anyopaque) callconv(.c) void,
    \\        .{ .name = "glReadPixels" },
    \\    );
    \\    pub const mapBufferRange = @extern(
    \\        *const fn (target: c_uint, offset: isize, length: isize, access: c_uint) callconv(.c) ?*anyopaque,
    \\        .{ .name = "glMapBufferRange" },
    \\    );
    \\    pub const unmapBuffer = @extern(
    \\        *const fn (target: c_uint) callconv(.c) u8,
    \\        .{ .name = "glUnmapBuffer" },
    \\    );
    \\} else struct {};
    \\
;

/// Init-callback addendum that stashes the game's allocator into the
/// module-scope `_preview_allocator` so the frame + cleanup callbacks
/// can grow / free the CPU staging buffer without reaching back through
/// `g`. Gated on `_sokol_preview_gl_enabled` for symmetry with the
/// other blocks — on non-GL targets the allocator slot stays at its
/// undefined sentinel but nothing ever calls through it.
pub const PREVIEW_READBACK_INIT_SOKOL =
    \\    if (comptime _sokol_preview_gl_enabled) {
    \\        _preview_allocator = allocator;
    \\    }
    \\
;

/// Per-frame PBO readback for sokol's `frame` callback. Comptime-gated
/// on `_sokol_preview_gl_enabled` — the entire block evaporates on
/// Metal / D3D11 builds, leaving only the heartbeat path intact.
///
/// Algorithm mirrors raylib's `PREVIEW_READBACK_LOOP` (#120):
///   - read current screen dims via `window.width()` / `window.height()`
///   - on resize / first frame, (re)negotiate the SHM ring with the
///     editor + (re)size the PBOs + CPU buffer + reset the priming
///     counter
///   - issue glReadPixels into `pbo[N % 3]` (async DMA)
///   - from frame 2 onwards, glMapBuffer `pbo[(N-2) % 3]` + memcpy
///     into the CPU buffer with bottom-up → top-down row flip, then
///     `publishFrame`
///
/// The flush ordering is the catch: sokol's `window.endFrame()` calls
/// `sg.endPass(); sg.commit();`. We inject the readback BEFORE
/// `window.endFrame()` so glReadPixels still hits the swapchain
/// framebuffer (FBO 0 / GL_BACK) before the swap. Same shape as
/// raylib's pre-`endFrame()` placement.
pub const PREVIEW_READBACK_FRAME_SOKOL =
    \\        if (comptime _sokol_preview_gl_enabled) {
    \\            if (g.preview) |*_p| _readback: {
    \\                const _sw_i = window.width();
    \\                const _sh_i = window.height();
    \\                if (_sw_i <= 0 or _sh_i <= 0) break :_readback;
    \\                const _sw: u32 = @intCast(_sw_i);
    \\                const _sh: u32 = @intCast(_sh_i);
    \\                const _needed_bytes: usize = @as(usize, _sw) * @as(usize, _sh) * 4;
    \\
    \\                if (_sw != _preview_last_w or _sh != _preview_last_h) {
    \\                    _p.beginFrameStream(_sw, _sh) catch break :_readback;
    \\                    if (!_preview_pbo_initialized) {
    \\                        _SokolPreviewGl.genBuffers(3, &_preview_pbos);
    \\                        _preview_pbo_initialized = true;
    \\                    }
    \\                    _SokolPreviewGl.pixelStorei(_SokolPreviewGl.PACK_ALIGNMENT, 4);
    \\                    for (_preview_pbos) |_pbo_id| {
    \\                        _SokolPreviewGl.bindBuffer(_SokolPreviewGl.PIXEL_PACK_BUFFER, _pbo_id);
    \\                        _SokolPreviewGl.bufferData(_SokolPreviewGl.PIXEL_PACK_BUFFER, @intCast(_needed_bytes), null, _SokolPreviewGl.STREAM_READ);
    \\                    }
    \\                    _SokolPreviewGl.bindBuffer(_SokolPreviewGl.PIXEL_PACK_BUFFER, 0);
    \\                    _preview_pbo_bytes = _needed_bytes;
    \\                    if (_preview_pixel_buf.len != _needed_bytes) {
    \\                        if (_preview_pixel_buf.len != 0) _preview_allocator.free(_preview_pixel_buf);
    \\                        _preview_pixel_buf = _preview_allocator.alloc(u8, _needed_bytes) catch &[_]u8{};
    \\                    }
    \\                    // Only commit the new dims once the CPU buffer
    \\                    // is the right size — otherwise a transient
    \\                    // alloc failure would leave us with `last_w/h`
    \\                    // matching the screen, skipping the resize block
    \\                    // on every subsequent frame and stranding the
    \\                    // readback in a permanent break state.
    \\                    if (_preview_pixel_buf.len == _needed_bytes) {
    \\                        _preview_last_w = _sw;
    \\                        _preview_last_h = _sh;
    \\                        _preview_frame_idx = 0;
    \\                    }
    \\                }
    \\
    \\                if (!_p.isFrameAccepted() or _preview_pixel_buf.len != _needed_bytes) break :_readback;
    \\
    \\                const _write_idx: usize = @intCast(_preview_frame_idx % 3);
    \\                _SokolPreviewGl.bindBuffer(_SokolPreviewGl.PIXEL_PACK_BUFFER, _preview_pbos[_write_idx]);
    \\                _SokolPreviewGl.readPixels(0, 0, _sw_i, _sh_i, _SokolPreviewGl.RGBA, _SokolPreviewGl.UNSIGNED_BYTE, null);
    \\
    \\                if (_preview_frame_idx >= 2) {
    \\                    const _read_idx: usize = @intCast((_preview_frame_idx - 2) % 3);
    \\                    _SokolPreviewGl.bindBuffer(_SokolPreviewGl.PIXEL_PACK_BUFFER, _preview_pbos[_read_idx]);
    \\                    const _mapped = _SokolPreviewGl.mapBufferRange(
    \\                        _SokolPreviewGl.PIXEL_PACK_BUFFER,
    \\                        0,
    \\                        @intCast(_preview_pbo_bytes),
    \\                        _SokolPreviewGl.MAP_READ_BIT,
    \\                    );
    \\                    if (_mapped) |_src| {
    \\                        const _src_ptr: [*]const u8 = @ptrCast(_src);
    \\                        const _row_bytes: usize = @as(usize, _sw) * 4;
    \\                        var _y: u32 = 0;
    \\                        while (_y < _sh) : (_y += 1) {
    \\                            const _src_row = _src_ptr + (@as(usize, _sh - 1 - _y) * _row_bytes);
    \\                            const _dst_row = _preview_pixel_buf.ptr + (@as(usize, _y) * _row_bytes);
    \\                            @memcpy(_dst_row[0.._row_bytes], _src_row[0.._row_bytes]);
    \\                        }
    \\                        // glUnmapBuffer returns GL_FALSE (0) if the
    \\                        // buffer contents became corrupt during the
    \\                        // map (e.g. context loss, screen-resolution
    \\                        // change racing with the readback). In that
    \\                        // case our memcpy above read garbage —
    \\                        // skip publishFrame so the editor doesn't
    \\                        // display a torn frame.
    \\                        if (_SokolPreviewGl.unmapBuffer(_SokolPreviewGl.PIXEL_PACK_BUFFER) != 0) {
    \\                            _p.publishFrame(_preview_pixel_buf) catch {};
    \\                        }
    \\                    }
    \\                }
    \\                _SokolPreviewGl.bindBuffer(_SokolPreviewGl.PIXEL_PACK_BUFFER, 0);
    \\                _preview_frame_idx +%= 1;
    \\            }
    \\        }
    \\
;

/// Cleanup-callback teardown for the sokol PBO ring. Runs BEFORE
/// `PREVIEW_CLEANUP_CALLBACK` (which sends the graceful `bye`) so the
/// engine still has its socket open when the producer tears down the
/// SHM ring — matches raylib's LIFO ordering. Gated on the same
/// `_sokol_preview_gl_enabled` flag; on non-GL builds the PBO state
/// is never initialized so there's nothing to free either.
pub const PREVIEW_READBACK_CLEANUP_SOKOL =
    \\    if (comptime _sokol_preview_gl_enabled) {
    \\        if (g.preview) |*_p| _p.endFrameStream();
    \\        if (_preview_pbo_initialized) _SokolPreviewGl.deleteBuffers(3, &_preview_pbos);
    \\        if (_preview_pixel_buf.len != 0) _preview_allocator.free(_preview_pixel_buf);
    \\    }
    \\
;

/// Sokol D3D11 staging-texture readback helpers (labelle-assembler#126,
/// slice 2 of #122). Mirrors the structure of the GL block above but
/// targets default sokol-on-Windows builds, which use D3D11 instead of
/// GL. Windows has no IOSurface equivalent that crosses processes
/// cheaply, so the path is CPU-side `CopyResource` + `Map` + memcpy
/// into the SHM ring (same protocol the GL path uses via
/// `Preview.beginFrameStream` / `publishFrame`).
///
/// Sokol back-buffer access:
///   - `sg_d3d11_device()`         → `ID3D11Device*` (public sokol-gfx API)
///   - `sg_d3d11_device_context()` → `ID3D11DeviceContext*` (public)
///   - `sapp_d3d11_get_swap_chain()` → `IDXGISwapChain*` (public sokol-app API)
///   - `IDXGISwapChain::GetBuffer(0, IID_ID3D11Texture2D, &bb)` via COM
///     vtable dispatch → the resolved back-buffer `ID3D11Texture2D*`.
///
/// The COM vtable indices used here (`Map`=14, `Unmap`=15,
/// `CopyResource`=47 on `ID3D11DeviceContext`; `GetBuffer`=9 on
/// `IDXGISwapChain`; `CreateTexture2D`=5 on `ID3D11Device`;
/// `Release`=2 on every interface) are stable across the D3D11 ABI
/// since D3D11 shipped in 2009 — this is the same dispatch shape
/// every Windows graphics driver uses internally.
///
/// Format note: DXGI swapchains created by sokol default to
/// `DXGI_FORMAT_B8G8R8A8_UNORM` (BGRA8). The SHM consumer expects
/// RGBA8 (matching the GL `glReadPixels(GL_RGBA, ...)` shape), so the
/// memcpy below swizzles BGRA→RGBA per pixel. A future variant of the
/// SHM protocol that carries the source pixel format could skip the
/// swizzle and let the consumer handle channel order — out of scope
/// for this slice. DXGI back buffers are top-down (row 0 = top), so
/// no row flip is needed (unlike the GL path, where `glReadPixels`
/// returns rows bottom-up).
pub const PREVIEW_READBACK_HELPERS_SOKOL_D3D11 =
    \\
    \\// ── Sokol D3D11 readback gating (labelle-assembler#126) ──
    \\// Default sokol-zig picks D3D11 on Windows desktop. The staging-
    \\// texture readback path only applies there; on Linux/Android sokol
    \\// runs GLCORE/GLES3 (the block above), and on Darwin sokol runs
    \\// Metal (slice 3, #125). The `comptime`-gated externs and the
    \\// `struct {}` else branch keep the D3D11 entry points off the
    \\// link line for non-Windows targets.
    \\const _sokol_preview_d3d11_enabled: bool = @import("builtin").os.tag == .windows;
    \\
    \\// Staging-texture ring + book-keeping at module scope (same
    \\// rationale as the GL block — sokol's `init` / `frame` / `cleanup`
    \\// callbacks have no shared local stack frame).
    \\//
    \\// `_preview_d3d11_staging` holds 3 `ID3D11Texture2D*` (opaque)
    \\// allocated on the first frame / on resize; the publish loop
    \\// `CopyResource`s the back-buffer into slot `N % 3` and `Map`s
    \\// slot `(N-2) % 3` — same 3-deep ring + 2-frame priming gap as
    \\// the GL PBO path keeps DMA / GPU stalls out of the frame loop.
    \\var _preview_d3d11_staging: [3]?*anyopaque = .{ null, null, null };
    \\var _preview_d3d11_initialized: bool = false;
    \\
    \\// COM dispatch helpers. D3D11 / DXGI interfaces are layouts where
    \\// the first field is a pointer to a function-pointer vtable. We
    \\// only need a handful of methods, all at well-known stable
    \\// indices (see helpers doc-comment above). The IID below is
    \\// `IID_ID3D11Texture2D` — `{6F15AAF2-D208-4E89-9AB4-489535D34F9C}`
    \\// in little-endian DWORD/WORD byte order.
    \\const _SokolPreviewD3d11 = if (_sokol_preview_d3d11_enabled) struct {
    \\    // D3D11_USAGE_STAGING = 3; CPU_ACCESS_READ = 0x20000.
    \\    // D3D11_MAP_READ = 1; DXGI_FORMAT_B8G8R8A8_UNORM = 87.
    \\    pub const USAGE_STAGING: c_uint = 3;
    \\    pub const CPU_ACCESS_READ: c_uint = 0x20000;
    \\    pub const MAP_READ: c_uint = 1;
    \\    pub const FORMAT_B8G8R8A8_UNORM: c_uint = 87;
    \\
    \\    // `_Guid` mirrors Windows `GUID` / `IID` — 16 bytes, mixed
    \\    // endianness in the binary form. Hand-coded byte sequence
    \\    // avoids dragging in Win32 headers from the generated code.
    \\    pub const _Guid = extern struct {
    \\        data1: u32,
    \\        data2: u16,
    \\        data3: u16,
    \\        data4: [8]u8,
    \\    };
    \\    pub const IID_ID3D11Texture2D: _Guid = .{
    \\        .data1 = 0x6F15AAF2,
    \\        .data2 = 0xD208,
    \\        .data3 = 0x4E89,
    \\        .data4 = .{ 0x9A, 0xB4, 0x48, 0x95, 0x35, 0xD3, 0x4F, 0x9C },
    \\    };
    \\
    \\    // Mapped subresource layout — matches D3D11_MAPPED_SUBRESOURCE.
    \\    pub const MappedSubresource = extern struct {
    \\        data: ?*anyopaque,
    \\        row_pitch: u32,
    \\        depth_pitch: u32,
    \\    };
    \\
    \\    // D3D11_TEXTURE2D_DESC. SampleDesc is `{count, quality}`.
    \\    pub const Texture2DDesc = extern struct {
    \\        width: u32,
    \\        height: u32,
    \\        mip_levels: u32,
    \\        array_size: u32,
    \\        format: c_uint,
    \\        sample_count: u32,
    \\        sample_quality: u32,
    \\        usage: c_uint,
    \\        bind_flags: c_uint,
    \\        cpu_access_flags: c_uint,
    \\        misc_flags: c_uint,
    \\    };
    \\
    \\    // Sokol C-symbol entry points — `sg_d3d11_device()`,
    \\    // `sg_d3d11_device_context()`, `sapp_d3d11_get_swap_chain()`
    \\    // are part of the public sokol-gfx / sokol-app API and link
    \\    // into any sokol-on-Windows build via the sokol-zig dep.
    \\    pub const sgDevice = @extern(
    \\        *const fn () callconv(.c) ?*anyopaque,
    \\        .{ .name = "sg_d3d11_device" },
    \\    );
    \\    pub const sgDeviceContext = @extern(
    \\        *const fn () callconv(.c) ?*anyopaque,
    \\        .{ .name = "sg_d3d11_device_context" },
    \\    );
    \\    pub const sappSwapChain = @extern(
    \\        *const fn () callconv(.c) ?*anyopaque,
    \\        .{ .name = "sapp_d3d11_get_swap_chain" },
    \\    );
    \\
    \\    // `Object` is a placeholder for any COM interface pointer; the
    \\    // first field is always a pointer to the vtable, which is
    \\    // itself a `[*]const *const fn () callconv(.c) i32`. We dispatch
    \\    // by indexing into that table at the documented method index.
    \\    pub const Object = extern struct { vtbl: [*]const *const anyopaque };
    \\
    \\    /// IDXGISwapChain::GetBuffer — vtable index 9.
    \\    /// Signature: HRESULT GetBuffer(UINT Buffer, REFIID riid, void** ppSurface).
    \\    pub fn swapChainGetBuffer(sc: *anyopaque, buffer: u32, riid: *const _Guid, out: *?*anyopaque) i32 {
    \\        const obj: *Object = @ptrCast(@alignCast(sc));
    \\        const fp: *const fn (*anyopaque, u32, *const _Guid, *?*anyopaque) callconv(.c) i32 = @ptrCast(obj.vtbl[9]);
    \\        return fp(sc, buffer, riid, out);
    \\    }
    \\
    \\    /// ID3D11Device::CreateTexture2D — vtable index 5.
    \\    /// Signature: HRESULT CreateTexture2D(const D3D11_TEXTURE2D_DESC*, const D3D11_SUBRESOURCE_DATA*, ID3D11Texture2D**).
    \\    pub fn deviceCreateTexture2D(dev: *anyopaque, desc: *const Texture2DDesc, out: *?*anyopaque) i32 {
    \\        const obj: *Object = @ptrCast(@alignCast(dev));
    \\        const fp: *const fn (*anyopaque, *const Texture2DDesc, ?*const anyopaque, *?*anyopaque) callconv(.c) i32 = @ptrCast(obj.vtbl[5]);
    \\        return fp(dev, desc, null, out);
    \\    }
    \\
    \\    /// ID3D11DeviceContext::Map — vtable index 14.
    \\    /// Signature: HRESULT Map(ID3D11Resource*, UINT subresource, D3D11_MAP, UINT flags, D3D11_MAPPED_SUBRESOURCE*).
    \\    pub fn contextMap(ctx: *anyopaque, resource: *anyopaque, subresource: u32, map_type: c_uint, flags: u32, out: *MappedSubresource) i32 {
    \\        const obj: *Object = @ptrCast(@alignCast(ctx));
    \\        const fp: *const fn (*anyopaque, *anyopaque, u32, c_uint, u32, *MappedSubresource) callconv(.c) i32 = @ptrCast(obj.vtbl[14]);
    \\        return fp(ctx, resource, subresource, map_type, flags, out);
    \\    }
    \\
    \\    /// ID3D11DeviceContext::Unmap — vtable index 15.
    \\    /// Signature: void Unmap(ID3D11Resource*, UINT subresource).
    \\    pub fn contextUnmap(ctx: *anyopaque, resource: *anyopaque, subresource: u32) void {
    \\        const obj: *Object = @ptrCast(@alignCast(ctx));
    \\        const fp: *const fn (*anyopaque, *anyopaque, u32) callconv(.c) void = @ptrCast(obj.vtbl[15]);
    \\        fp(ctx, resource, subresource);
    \\    }
    \\
    \\    /// ID3D11DeviceContext::CopyResource — vtable index 47.
    \\    /// Signature: void CopyResource(ID3D11Resource* dst, ID3D11Resource* src).
    \\    pub fn contextCopyResource(ctx: *anyopaque, dst: *anyopaque, src: *anyopaque) void {
    \\        const obj: *Object = @ptrCast(@alignCast(ctx));
    \\        const fp: *const fn (*anyopaque, *anyopaque, *anyopaque) callconv(.c) void = @ptrCast(obj.vtbl[47]);
    \\        fp(ctx, dst, src);
    \\    }
    \\
    \\    /// IUnknown::Release — vtable index 2. Used to release the
    \\    /// AddRef'd back-buffer pointer from `GetBuffer` and to drop
    \\    /// the staging textures on cleanup / resize.
    \\    pub fn release(obj_ptr: *anyopaque) u32 {
    \\        const obj: *Object = @ptrCast(@alignCast(obj_ptr));
    \\        const fp: *const fn (*anyopaque) callconv(.c) u32 = @ptrCast(obj.vtbl[2]);
    \\        return fp(obj_ptr);
    \\    }
    \\} else struct {};
    \\
;

/// Sokol Metal/IOSurface readback — Path A (labelle-assembler#131,
/// floooh/sokol#1510).
///
/// Path B (drawable→blit→getBytes) shipped in #128 but was permanently
/// gated behind a stub: sokol-zig's `sapp_get_swapchain()` returns the
/// *next* drawable each call, not the just-rendered one. The original
/// fork (`labelle-toolkit/sokol-zig` branch
/// `feat/expose-cached-metal-drawable`) cached the post-present
/// drawable, but Apple recycles drawables to the pool after present —
/// so by the time our readback fires, the drawable's `texture` is
/// either invalid or owned by a different frame.
///
/// Path A flips the producer side: we **own** the render target. The
/// engine allocates an `IOSurface` ring up front
/// (`Preview.beginFrameStreamIOSurface`); per surface we ask the
/// `MTLDevice` to make an `MTLTexture` wrapping it via
/// `newTextureWithDescriptor:iosurface:plane:`. Those textures get
/// injected into sokol-gfx as external `sg_image`s
/// (`ImageDesc.mtl_textures[…]`) with `color_attachment = true`, so
/// the game's render pass can be redirected to write straight into
/// our IOSurface (zero-copy: the editor samples the same surface).
/// At end-of-frame we call `Preview.signalSlotReady(slot)`
/// (labelle-engine#553) — no pixel touch, just a `header.latest` bump.
///
/// **Known gap**: actually *redirecting* the game's render pass into
/// our offscreen target needs hooks the current sokol+labelle
/// integration doesn't have. The gfx layer always uses sokol-app's
/// swapchain (`window.beginPass(pass_action)`); we'd need either
/// (a) a `gfx.setEditorRenderTarget(image, attachments)` shim that
/// flips `sg_begin_pass` to our attachments + adds a fullscreen-quad
/// copy to the swapchain afterward, or (b) a separate render path
/// for editor mode that does the offscreen pass + the swapchain
/// blit. Both are scoped as follow-ups. **For this PR**: the
/// IOSurface ring is allocated and signalled, but contents are
/// whatever IOSurfaceCreate left there (zero-filled in practice).
/// The editor sees a black Game View, but the SHM handshake +
/// frame_published cadence work end-to-end.
///
/// libobjc binding is minimised vs. Path B: we only need
/// `newTextureWithDescriptor:iosurface:plane:` (texture-from-surface
/// wrap) and `release` (cleanup). No blit encoder, no command queue,
/// no `getBytes` — the whole post-frame copy chain is gone.
///
/// State is module-scope (parallels the GL block) because sokol's
/// init/frame/cleanup callbacks don't share a stack frame.
/// `_preview_allocator` is the SAME slot the GL block stashes — the
/// gates are mutually exclusive (GL = .linux, Metal = .macos/.ios)
/// so they never race for it.
pub const PREVIEW_READBACK_HELPERS_METAL_SOKOL =
    \\
    \\// ── Sokol Metal/IOSurface preview seam (labelle-assembler#140) ─
    \\// All Path-A state + ring management + cleanup now lives in the
    \\// backend module (`backends/sokol/src/window.zig:preview_mtl`).
    \\// The codegen owns only:
    \\//   1. The comptime enable gate (aliased from the backend).
    \\//   2. Five tiny bridge fns that wrap `engine.Preview` methods
    \\//      behind an `*anyopaque` boundary so the backend never needs
    \\//      an engine type-import (the engine module would otherwise
    \\//      have to be wired through the backend's build graph too).
    \\//   3. The vtable-attach call inside the init callback (see
    \\//      PREVIEW_INIT_CALLBACK below).
    \\const _sokol_preview_metal_enabled = window.preview_metal_enabled;
    \\
    \\// Bridge fns — pure wrappers over the engine.Preview methods the
    \\// backend's preview_mtl namespace drives via its vtable. These
    \\// live in module scope because the vtable is wired up once during
    \\// init and persists for the program's lifetime.
    \\fn _preview_mtl_begin_stream_bridge(ctx: *anyopaque, w: u32, h: u32) anyerror!void {
    \\    const p: *engine.Preview = @ptrCast(@alignCast(ctx));
    \\    return p.beginFrameStreamIOSurface(w, h);
    \\}
    \\fn _preview_mtl_get_surface_bridge(ctx: *anyopaque, slot: u32) ?*anyopaque {
    \\    const p: *engine.Preview = @ptrCast(@alignCast(ctx));
    \\    // getIOSurfaceAt returns `??*opaque` — outer optional means
    \\    // "slot in range", inner means "IOSurfaceRef itself nullable".
    \\    const maybe_ref = p.getIOSurfaceAt(slot) orelse return null;
    \\    const ref = maybe_ref orelse return null;
    \\    return @ptrCast(ref);
    \\}
    \\fn _preview_mtl_signal_bridge(ctx: *anyopaque, slot: u32) anyerror!void {
    \\    const p: *engine.Preview = @ptrCast(@alignCast(ctx));
    \\    return p.signalSlotReady(slot);
    \\}
    \\fn _preview_mtl_end_stream_bridge(ctx: *anyopaque) void {
    \\    const p: *engine.Preview = @ptrCast(@alignCast(ctx));
    \\    p.endFrameStreamIOSurface();
    \\}
    \\fn _preview_mtl_accepted_bridge(ctx: *anyopaque) bool {
    \\    const p: *const engine.Preview = @ptrCast(@alignCast(ctx));
    \\    return p.isFrameAccepted();
    \\}
    \\
;

/// Init-callback addendum for the D3D11 staging-texture ring. Stashes
/// the allocator into the shared module-scope slot (`_preview_allocator`)
/// so the frame + cleanup callbacks can grow / free the CPU staging
/// buffer. The GL block stashes the same slot — both blocks are
/// mutually exclusive at comptime (`.linux` vs `.windows`), so only
/// one ever runs.
pub const PREVIEW_READBACK_INIT_SOKOL_D3D11 =
    \\    if (comptime _sokol_preview_d3d11_enabled) {
    \\        _preview_allocator = allocator;
    \\    }
    \\
;

/// Init-callback addendum for the Metal readback. Mirrors the GL
/// variant — the `_preview_allocator` slot is declared by the GL
/// block above and shared between paths (mutually exclusive at
/// runtime, so no contention). Selector cache is lazy-loaded on
/// first frame instead of here to keep the init callback's failure
/// surface narrow (sokol's init runs before the Metal device exists
/// in some sokol-app configs).
pub const PREVIEW_READBACK_INIT_METAL_SOKOL =
    \\    if (comptime _sokol_preview_metal_enabled) {
    \\        _preview_allocator = allocator;
    \\    }
    \\
;

/// Per-frame D3D11 readback for sokol's `frame` callback. Comptime-gated
/// on `_sokol_preview_d3d11_enabled` — the entire block evaporates on
/// non-Windows builds, leaving only the heartbeat path intact.
///
/// Algorithm mirrors the GL path (`PREVIEW_READBACK_FRAME_SOKOL`):
///   - read current screen dims via `window.width()` / `window.height()`
///   - on resize / first frame, (re)negotiate the SHM ring with the
///     editor + (re)create the 3-deep staging-texture ring + reset the
///     priming counter
///   - `IDXGISwapChain::GetBuffer(0)` → resolved back-buffer Texture2D
///   - `ID3D11DeviceContext::CopyResource(staging[N % 3], backbuffer)`
///   - release the back-buffer reference
///   - from frame 2 onwards, `Map(staging[(N-2) % 3], D3D11_MAP_READ)` +
///     memcpy with BGRA→RGBA swizzle into `_preview_pixel_buf`, then
///     `publishFrame`
///
/// Sokol's `window.endFrame()` calls `sg.endPass(); sg.commit();`. We
/// inject this BEFORE `endFrame()` so `CopyResource` queues up after
/// all of sokol's draw calls but before the swap — matching the GL
/// path's pre-commit placement and ensuring the staging copy reflects
/// the rendered frame, not the next one.
pub const PREVIEW_READBACK_FRAME_SOKOL_D3D11 =
    \\        if (comptime _sokol_preview_d3d11_enabled) {
    \\            if (g.preview) |*_p| _readback_d3d11: {
    \\                const _sw_i = window.width();
    \\                const _sh_i = window.height();
    \\                if (_sw_i <= 0 or _sh_i <= 0) break :_readback_d3d11;
    \\                const _sw: u32 = @intCast(_sw_i);
    \\                const _sh: u32 = @intCast(_sh_i);
    \\                const _needed_bytes: usize = @as(usize, _sw) * @as(usize, _sh) * 4;
    \\
    \\                const _device_opt = _SokolPreviewD3d11.sgDevice();
    \\                const _ctx_opt = _SokolPreviewD3d11.sgDeviceContext();
    \\                const _swap_opt = _SokolPreviewD3d11.sappSwapChain();
    \\                if (_device_opt == null or _ctx_opt == null or _swap_opt == null) break :_readback_d3d11;
    \\                const _device = @as(*anyopaque, @ptrCast(@constCast(_device_opt.?)));
    \\                const _ctx = @as(*anyopaque, @ptrCast(@constCast(_ctx_opt.?)));
    \\                const _swap = @as(*anyopaque, @ptrCast(@constCast(_swap_opt.?)));
    \\
    \\                if (_sw != _preview_last_w or _sh != _preview_last_h) {
    \\                    _p.beginFrameStream(_sw, _sh) catch break :_readback_d3d11;
    \\                    // Tear down the old ring (if any) before creating
    \\                    // the new one — staging dims must match the
    \\                    // back-buffer or `CopyResource` will fail silently.
    \\                    if (_preview_d3d11_initialized) {
    \\                        for (&_preview_d3d11_staging) |*_slot| {
    \\                            if (_slot.*) |_p_ptr| {
    \\                                _ = _SokolPreviewD3d11.release(_p_ptr);
    \\                                _slot.* = null;
    \\                            }
    \\                        }
    \\                    }
    \\                    const _staging_desc: _SokolPreviewD3d11.Texture2DDesc = .{
    \\                        .width = _sw,
    \\                        .height = _sh,
    \\                        .mip_levels = 1,
    \\                        .array_size = 1,
    \\                        .format = _SokolPreviewD3d11.FORMAT_B8G8R8A8_UNORM,
    \\                        .sample_count = 1,
    \\                        .sample_quality = 0,
    \\                        .usage = _SokolPreviewD3d11.USAGE_STAGING,
    \\                        .bind_flags = 0,
    \\                        .cpu_access_flags = _SokolPreviewD3d11.CPU_ACCESS_READ,
    \\                        .misc_flags = 0,
    \\                    };
    \\                    var _alloc_ok = true;
    \\                    for (&_preview_d3d11_staging) |*_slot| {
    \\                        var _new_tex: ?*anyopaque = null;
    \\                        const _hr = _SokolPreviewD3d11.deviceCreateTexture2D(_device, &_staging_desc, &_new_tex);
    \\                        if (_hr < 0 or _new_tex == null) {
    \\                            _alloc_ok = false;
    \\                            break;
    \\                        }
    \\                        _slot.* = _new_tex;
    \\                    }
    \\                    if (!_alloc_ok) {
    \\                        // Rollback any partial ring on failure so the
    \\                        // next resize attempt starts clean.
    \\                        for (&_preview_d3d11_staging) |*_slot| {
    \\                            if (_slot.*) |_p_ptr| {
    \\                                _ = _SokolPreviewD3d11.release(_p_ptr);
    \\                                _slot.* = null;
    \\                            }
    \\                        }
    \\                        break :_readback_d3d11;
    \\                    }
    \\                    _preview_d3d11_initialized = true;
    \\                    if (_preview_pixel_buf.len != _needed_bytes) {
    \\                        if (_preview_pixel_buf.len != 0) _preview_allocator.free(_preview_pixel_buf);
    \\                        _preview_pixel_buf = _preview_allocator.alloc(u8, _needed_bytes) catch &[_]u8{};
    \\                    }
    \\                    // Only commit the new dims once the CPU buffer is
    \\                    // the right size — same recovery logic as the GL
    \\                    // path. A transient alloc failure leaves
    \\                    // `last_w/h` stale so the next frame re-runs the
    \\                    // resize block.
    \\                    if (_preview_pixel_buf.len == _needed_bytes) {
    \\                        _preview_last_w = _sw;
    \\                        _preview_last_h = _sh;
    \\                        _preview_frame_idx = 0;
    \\                    }
    \\                }
    \\
    \\                if (!_p.isFrameAccepted() or _preview_pixel_buf.len != _needed_bytes or !_preview_d3d11_initialized) break :_readback_d3d11;
    \\
    \\                // Grab the back-buffer (Buffer 0 in DXGI; that's the
    \\                // resolved swap-chain surface, top-down origin). The
    \\                // returned pointer is AddRef'd by `GetBuffer` — we
    \\                // must `Release` after `CopyResource` to keep DXGI
    \\                // from leaking the reference across resizes.
    \\                var _backbuffer: ?*anyopaque = null;
    \\                const _hr_get = _SokolPreviewD3d11.swapChainGetBuffer(_swap, 0, &_SokolPreviewD3d11.IID_ID3D11Texture2D, &_backbuffer);
    \\                if (_hr_get < 0 or _backbuffer == null) break :_readback_d3d11;
    \\                defer _ = _SokolPreviewD3d11.release(_backbuffer.?);
    \\
    \\                const _write_idx: usize = @intCast(_preview_frame_idx % 3);
    \\                const _write_tex = _preview_d3d11_staging[_write_idx] orelse break :_readback_d3d11;
    \\                _SokolPreviewD3d11.contextCopyResource(_ctx, _write_tex, _backbuffer.?);
    \\
    \\                if (_preview_frame_idx >= 2) {
    \\                    const _read_idx: usize = @intCast((_preview_frame_idx - 2) % 3);
    \\                    const _read_tex = _preview_d3d11_staging[_read_idx] orelse break :_readback_d3d11;
    \\                    var _mapped: _SokolPreviewD3d11.MappedSubresource = .{ .data = null, .row_pitch = 0, .depth_pitch = 0 };
    \\                    const _hr_map = _SokolPreviewD3d11.contextMap(_ctx, _read_tex, 0, _SokolPreviewD3d11.MAP_READ, 0, &_mapped);
    \\                    if (_hr_map >= 0 and _mapped.data != null) {
    \\                        const _src_base: [*]const u8 = @ptrCast(_mapped.data.?);
    \\                        const _row_bytes: usize = @as(usize, _sw) * 4;
    \\                        const _row_pitch: usize = @intCast(_mapped.row_pitch);
    \\                        var _y: u32 = 0;
    \\                        // DXGI back buffers are top-down (row 0 = top),
    \\                        // so no row-flip — but the swapchain format is
    \\                        // BGRA8 while the SHM consumer expects RGBA8,
    \\                        // so swizzle channels 0/2 per pixel during the
    \\                        // copy. `row_pitch` from `Map` may be padded
    \\                        // above `width*4`, so we walk pitched rows
    \\                        // explicitly instead of treating the staging
    \\                        // texture as a flat array.
    \\                        while (_y < _sh) : (_y += 1) {
    \\                            const _src_row = _src_base + (@as(usize, _y) * _row_pitch);
    \\                            const _dst_row = _preview_pixel_buf.ptr + (@as(usize, _y) * _row_bytes);
    \\                            var _x: u32 = 0;
    \\                            while (_x < _sw) : (_x += 1) {
    \\                                const _off: usize = @as(usize, _x) * 4;
    \\                                _dst_row[_off + 0] = _src_row[_off + 2];
    \\                                _dst_row[_off + 1] = _src_row[_off + 1];
    \\                                _dst_row[_off + 2] = _src_row[_off + 0];
    \\                                _dst_row[_off + 3] = _src_row[_off + 3];
    \\                            }
    \\                        }
    \\                        _SokolPreviewD3d11.contextUnmap(_ctx, _read_tex, 0);
    \\                        _p.publishFrame(_preview_pixel_buf) catch {};
    \\                    } else if (_hr_map >= 0) {
    \\                        // Map succeeded but returned a null pointer —
    \\                        // pair the call with Unmap anyway so the
    \\                        // staging texture isn't left in a mapped
    \\                        // state.
    \\                        _SokolPreviewD3d11.contextUnmap(_ctx, _read_tex, 0);
    \\                    }
    \\                }
    \\                _preview_frame_idx +%= 1;
    \\            }
    \\        }
    \\
;

/// Pre-render Metal Path-A block for sokol's `frame` callback
/// (labelle-assembler#133 — closes the render-into-IOSurface gap
/// that #131/#132 left as a TODO). Emits into a new `{{preview_pre_render}}`
/// template slot that fires AFTER `g.tick(dt)` and BEFORE
/// `window.beginFrame()` / `window.beginPass()` so the swapchain-vs-
/// offscreen decision is made before sokol-gfx commits to either.
/// Comptime-gated on `_sokol_preview_metal_enabled` — evaporates on
/// Linux (GL) and Windows (D3D11) builds.
///
/// Responsibilities (per frame):
///   1. First frame OR resize: tear down any prior ring; ask the
///      engine to `beginFrameStreamIOSurface(w, h)` so a fresh
///      IOSurface ring lands in shm; for each slot wrap the
///      IOSurface as `MTLTexture` (`createIOSurfaceTexture`) +
///      inject into sokol-gfx as an external color-attachment
///      `sg.Image` (`mtl_textures[…]`) + build the per-slot
///      `sg.View` + `sg.Attachments` so the per-frame call site
///      can flip the gfx layer with a single struct copy.
///   2. If the editor has accepted a frame, pick `_write_slot`
///      (`_preview_frame_idx % ring_size`), stash it on the shared
///      `_preview_mtl_write_slot`, set `_preview_mtl_target_active`
///      and call `window.setEditorRenderTarget` so the next
///      `window.beginPass` routes `g.render()` into the Path-A
///      offscreen target. The post-render block consumes
///      `_preview_mtl_target_active` to decide whether to publish.
///
/// Pixel ordering: the IOSurface stores BGRA8 (matches sokol's
/// default Metal swapchain format), so the alpha pipeline + sgl
/// vertex stream produce identical output whether the pass lands
/// in the swapchain or our IOSurface — no shader / pipeline
/// reconfiguration needed.
pub const PREVIEW_PRE_RENDER_METAL_SOKOL =
    \\        if (comptime _sokol_preview_metal_enabled) window.preview_mtl.beginFrame();
    \\
;

/// Post-render Metal Path-A block for sokol's `frame` callback
/// (labelle-assembler#133). Emits into the existing `{{preview_readback}}`
/// slot (right after `g.render()` / `flushScene()` / GUI rendering,
/// before `window.endFrame()` commits the pass). Comptime-gated on
/// `_sokol_preview_metal_enabled`.
///
/// Responsibilities:
///   - If the pre-render block armed the editor target (handshake +
///     ring init + isFrameAccepted all passed), publish the just-
///     rendered slot via `signalSlotReady` and advance
///     `_preview_frame_idx`.
///   - Always call `window.clearEditorRenderTarget()` so the next
///     frame's `window.beginPass` defaults back to the swapchain
///     even if the pre-render block bails (editor disconnects,
///     transient ring rebuild, etc.). One-frame-scoped override
///     contract — see the shim in `backends/sokol/src/window.zig`.
pub const PREVIEW_READBACK_FRAME_METAL_SOKOL =
    \\        if (comptime _sokol_preview_metal_enabled) window.preview_mtl.endFrame();
    \\
;

/// Cleanup-callback teardown for the sokol D3D11 staging-texture ring.
/// Runs BEFORE `PREVIEW_CLEANUP_CALLBACK` (which sends the graceful
/// `bye`), matching the GL block's LIFO ordering. Gated on
/// `_sokol_preview_d3d11_enabled`; on non-Windows builds the staging
/// state is never initialized so there's nothing to free either.
///
/// Shares `_preview_pixel_buf` with the GL block, but since the two
/// blocks are mutually exclusive at comptime only one cleanup path
/// ever runs — the buffer is freed exactly once.
pub const PREVIEW_READBACK_CLEANUP_SOKOL_D3D11 =
    \\    if (comptime _sokol_preview_d3d11_enabled) {
    \\        if (g.preview) |*_p| _p.endFrameStream();
    \\        if (_preview_d3d11_initialized) {
    \\            for (&_preview_d3d11_staging) |*_slot| {
    \\                if (_slot.*) |_p_ptr| {
    \\                    _ = _SokolPreviewD3d11.release(_p_ptr);
    \\                    _slot.* = null;
    \\                }
    \\            }
    \\            _preview_d3d11_initialized = false;
    \\        }
    \\        if (_preview_pixel_buf.len != 0) _preview_allocator.free(_preview_pixel_buf);
    \\    }
    \\
;

/// Cleanup-callback teardown for the Path-A Metal ring. Runs BEFORE
/// `PREVIEW_CLEANUP_CALLBACK` (the graceful `bye`) so the engine
/// still has its socket open when the IOSurface producer tears
/// down — matches the GL + raylib LIFO ordering.
///
/// Order matters: we destroy the sokol images first (they hold an
/// internal reference to the MTLTexture but do NOT retain it —
/// sokol's `mtl_textures[]` injection is borrowed), then release
/// the MTLTextures (which drop their retain on the underlying
/// IOSurface), then ask the engine to tear down the IOSurface
/// ring + control-plane shm region. Doing the engine teardown
/// first would leave the MTLTextures pointing at potentially
/// freed IOSurface backing storage during the release window.
pub const PREVIEW_READBACK_CLEANUP_METAL_SOKOL =
    \\    if (comptime _sokol_preview_metal_enabled) window.preview_mtl.deinit();
    \\
;
