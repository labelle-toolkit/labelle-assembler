//! Backend-dispatched lifecycle section render for the generated
//! `main.zig` — the `{{lifecycle}}` scalar.
//!
//! Extracted from `main_template.zig`'s orchestrator (labelle-assembler
//! file-size refactor). This is the stateful block: it renders the
//! per-backend lifecycle (sokol / raylib-wasm / bgfx-android callback
//! paths + the loop path for raylib-desktop / sdl / bgfx-desktop / wgpu)
//! by feeding the backend `lifecycle_tmpl` to `tpl.render` with the
//! per-target hole set. Preview-mode wiring (GL/D3D11/Metal readback,
//! heartbeat, input dispatch) is concatenated into the relevant holes.
//!
//! State threaded from the orchestrator:
//!   - `cfg`, `allocator` — read off `self` (Codegen).
//!   - `lifecycle_tmpl` — the backend's lifecycle template text.
//!   - `hooks_init` — the already-rendered `hooks_init_block` scalar
//!     (the loop/callback templates re-embed it).
//!   - `loop_style_ovr` — the manifest-driven run-loop override
//!     (assembler#378). Passed by value so this module stays decoupled
//!     from the orchestrator's `threadlocal` (avoids an import cycle).
//!
//! The lifecycle builders this calls (`buildGuiDrawCode`,
//! `buildCallbackInitCode`, `buildCallbackCleanupCode`,
//! `buildImmersiveEntryCode`, `buildSetupCode`) are themselves mixin
//! methods on the same `Codegen`, dispatched through `self`. Pure move:
//! every `tpl.render` hole set + concat order is byte-identical to the
//! inline section it replaces.

const std = @import("std");
const builtin = @import("builtin");
const tpl = @import("../../template.zig");
const config = @import("../../config.zig");
const preview = @import("../preview.zig");
const manifest_splice = @import("../manifest_splice.zig");

const PREVIEW_HELPERS = preview.PREVIEW_HELPERS;
const PREVIEW_READBACK_HELPERS = preview.PREVIEW_READBACK_HELPERS;
const PREVIEW_LOOP_SETUP = preview.PREVIEW_LOOP_SETUP;
const PREVIEW_READBACK_SETUP = preview.PREVIEW_READBACK_SETUP;
const PREVIEW_HEARTBEAT_LOOP = preview.PREVIEW_HEARTBEAT_LOOP;
const PREVIEW_INPUT_DISPATCH = preview.PREVIEW_INPUT_DISPATCH;
const PREVIEW_INPUT_DISPATCH_STUB = preview.PREVIEW_INPUT_DISPATCH_STUB;
const PREVIEW_READBACK_LOOP = preview.PREVIEW_READBACK_LOOP;
const PREVIEW_INIT_CALLBACK = preview.PREVIEW_INIT_CALLBACK;
const PREVIEW_CLEANUP_CALLBACK = preview.PREVIEW_CLEANUP_CALLBACK;
const PREVIEW_HEARTBEAT_CALLBACK = preview.PREVIEW_HEARTBEAT_CALLBACK;
const PREVIEW_READBACK_INIT_SOKOL = preview.PREVIEW_READBACK_INIT_SOKOL;
const PREVIEW_READBACK_FRAME_SOKOL = preview.PREVIEW_READBACK_FRAME_SOKOL;
const PREVIEW_READBACK_CLEANUP_SOKOL = preview.PREVIEW_READBACK_CLEANUP_SOKOL;
const PREVIEW_READBACK_HELPERS_SOKOL = preview.PREVIEW_READBACK_HELPERS_SOKOL;
const PREVIEW_READBACK_HELPERS_SOKOL_D3D11 = preview.PREVIEW_READBACK_HELPERS_SOKOL_D3D11;
const PREVIEW_READBACK_HELPERS_METAL_SOKOL = preview.PREVIEW_READBACK_HELPERS_METAL_SOKOL;
const PREVIEW_READBACK_INIT_SOKOL_D3D11 = preview.PREVIEW_READBACK_INIT_SOKOL_D3D11;
const PREVIEW_READBACK_INIT_METAL_SOKOL = preview.PREVIEW_READBACK_INIT_METAL_SOKOL;
const PREVIEW_READBACK_FRAME_SOKOL_D3D11 = preview.PREVIEW_READBACK_FRAME_SOKOL_D3D11;
const PREVIEW_PRE_RENDER_METAL_SOKOL = preview.PREVIEW_PRE_RENDER_METAL_SOKOL;
const PREVIEW_READBACK_FRAME_METAL_SOKOL = preview.PREVIEW_READBACK_FRAME_METAL_SOKOL;
const PREVIEW_READBACK_CLEANUP_SOKOL_D3D11 = preview.PREVIEW_READBACK_CLEANUP_SOKOL_D3D11;
const PREVIEW_READBACK_CLEANUP_METAL_SOKOL = preview.PREVIEW_READBACK_CLEANUP_METAL_SOKOL;

/// `{{android_backend_register}}` body for the bgfx-Android `android_main`
/// hole (#310 Stage 4). Registers the bgfx backend's Android JNI seam with
/// core ONCE at startup — emitted in `android_main` BEFORE `run()`, so it
/// runs before the event loop starts and therefore before the first
/// `onWindowFocusChanged` (the immersive re-hide path) AND before the first
/// gamepad poll. (It previously sat in `gameInit`, which the shell fires on
/// the first INIT_WINDOW *inside* the loop — that runs after the window's
/// first focus event, so the launch immersive hide found no context
/// registered and no-op'd. Moving it ahead of `run` fixes the launch hide.)
/// Core's gamepad source + the engine's immersive mode then reach the
/// running ANativeActivity / InputManager through the bgfx adapter's
/// `AndroidBackendContext` instead of linking any backend symbol directly.
/// Emitted unconditionally on bgfx-Android (gamepad detection needs it even
/// when immersive mode is off). Replaces the removed sokol-compat shims.
const BGFX_ANDROID_BACKEND_REGISTER =
    \\    // Register the bgfx Android backend seam with core (labelle-core#310):
    \\    // core's gamepad source and the engine's immersive mode reach the
    \\    // running ANativeActivity / InputManager JNI glue through this context
    \\    // instead of linking any backend symbol directly. Runs once at startup,
    \\    // before the first frame polls the gamepad source. The context comes
    \\    // from the bgfx backend adapter surfaced as `backend_input.android`;
    \\    // `engine.core` is labelle-engine's re-export of labelle-core. See
    \\    // backends/bgfx/src/android.zig.
    \\    engine.core.registerAndroidBackend(@import("backend_input").android.backendContext());
    \\
;

/// Mixin factory for `Codegen`. Reads `cfg`, `allocator` from `self` and
/// dispatches the lifecycle builders (`buildGuiDrawCode`, etc.) through
/// `self` too.
pub fn Mixin(comptime Self: type) type {
    return struct {
        /// Render the `{{lifecycle}}` scalar into `w`. `loop_style_ovr`
        /// is the manifest-driven run-loop override (null keeps the
        /// enum-based selection).
        pub fn renderLifecycle(
            self: *Self,
            w: anytype,
            lifecycle_tmpl: []const u8,
            hooks_init: []const u8,
            loop_style_ovr: ?manifest_splice.BackendManifest.LoopStyle,
        ) !void {
            const allocator = self.allocator;
            const cfg = self.cfg;
            const bw = w;

            const tick_code = if (cfg.plugins.len > 0)
                "        const scaled_dt = dt * g.time_scale;\n" ++
                "        if (scaled_dt > 0) {\n" ++
                "            runner.tick(&g, scaled_dt);\n" ++
                "            PluginSystems.tick(&g, scaled_dt);\n" ++
                "            PluginSystems.postTick(&g, scaled_dt);\n" ++
                "        }\n" ++
                "        g.dispatchEvents();\n" ++
                "        // Update profiling pointers (debug only)\n" ++
                "        if (comptime @TypeOf(runner).profiling_enabled) {\n" ++
                "            g.script_profile_ptr = @ptrCast(@alignCast(&runner.profile));\n" ++
                "            g.script_profile_count = @TypeOf(runner).script_count;\n" ++
                "        }\n" ++
                "        if (comptime PluginSystems.profiling_enabled) {\n" ++
                "            g.plugin_profile_ptr = @ptrCast(@alignCast(&PluginSystems.plugin_profile));\n" ++
                "            g.plugin_profile_count = PluginSystems.plugin_system_count;\n" ++
                "        }\n"
            else
                "        const scaled_dt = dt * g.time_scale;\n" ++
                "        if (scaled_dt > 0) {\n" ++
                "            runner.tick(&g, scaled_dt);\n" ++
                "        }\n" ++
                "        g.dispatchEvents();\n" ++
                "        if (comptime @TypeOf(runner).profiling_enabled) {\n" ++
                "            g.script_profile_ptr = @ptrCast(@alignCast(&runner.profile));\n" ++
                "            g.script_profile_count = @TypeOf(runner).script_count;\n" ++
                "        }\n";

            const gui_draw_code = try self.buildGuiDrawCode();
            defer allocator.free(gui_draw_code);

            var w_buf: [16]u8 = undefined;
            var h_buf: [16]u8 = undefined;
            var fps_buf: [16]u8 = undefined;
            const w_str = std.fmt.bufPrint(&w_buf, "{d}", .{cfg.width}) catch unreachable;
            const h_str = std.fmt.bufPrint(&h_buf, "{d}", .{cfg.height}) catch unreachable;
            const fps_str = std.fmt.bufPrint(&fps_buf, "{d}", .{cfg.target_fps}) catch unreachable;

            const hidden_setup: []const u8 = if (cfg.hidden)
                "    window.setConfigFlags(.{ .window_hidden = true });\n"
            else
                "";

            // bgfx-on-Android (#303) inverts its desktop loop into the same
            // init/frame callback shape sokol/wasm use: the NativeActivity
            // shell (`backends/bgfx/src/android_app.zig`) owns the event+frame
            // loop and calls back into the game per-frame. So it shares the
            // callback-lifecycle path (module-scope `g`/`runner`, void-safe
            // `init_code` via `buildCallbackInitCode`) rather than the
            // procedural loop path the bgfx DESKTOP template uses.
            const is_bgfx_android = cfg.backend == .bgfx and cfg.platform == .android;
            // Manifest-driven run-loop splice (assembler#378): when the backend
            // manifest supplied a `loop_style`, resolve callback-vs-loop from THAT
            // (data), not the `cfg.backend == .sokol` enum branch. For
            // bgfx-desktop the manifest declares `.loop` → callback false (the
            // desktop `while (!shouldQuit())` path); for sokol-desktop it declares
            // `.callback` → true. Both match the enum path → byte-identical output.
            // Null override keeps the enum path verbatim for every other target.
            const use_callback_lifecycle = if (loop_style_ovr) |ls|
                ls == .callback
            else
                cfg.backend == .sokol or cfg.platform == .wasm or is_bgfx_android;

            // A callback-style EXTERNAL backend is only safe where the callback
            // dispatch below has a real branch for it. That dispatch keys off
            // `cfg.backend`, which the enum-as-shorthand PRESERVES even when the
            // backend resolves to a package (#386): `.backend = .bgfx` stays
            // `.bgfx`, so `is_bgfx_android` and the `== .sokol` branch still fire
            // for an extracted bgfx/sokol. What has NO branch is a callback
            // external that falls through to the raylib-wasm fallback (e.g. a
            // third-party backend, whose `cfg.backend` sits at the `.raylib`
            // default, or any external on wasm) — that would inherit
            // raylib-specific wiring, so fail fast there. Built-ins are
            // unaffected (`isExternal()` is false).
            const callback_dispatch_handled = is_bgfx_android or cfg.backend == .sokol;
            if (use_callback_lifecycle and cfg.isExternal() and !callback_dispatch_handled) {
                // Silenced under test (the Zig test runner fails any test that
                // emits a `std.log.err`, even when the error is the asserted
                // outcome — see env.zig's HOME-missing log for the same gate).
                // The returned error is the hard signal; this is the human hint.
                if (!builtin.is_test) {
                    std.log.err(
                        "labelle-assembler: external backend '{s}' declares a callback run-loop " ++
                            "(loop_style = .callback), which codegen does not support yet — only " ++
                            "loop-style external backends are wired today (epic #386). Use a loop-style " ++
                            "backend, or follow up on the callback-dispatch externalization.",
                        .{cfg.backendName()},
                    );
                }
                return error.ExternalCallbackBackendUnsupported;
            }

            if (use_callback_lifecycle) {
                // Module-scope `runner` decl — needed by every callback-path
                // backend whose `init_code` ASSIGNS `runner = Runner.init(...)`
                // (sokol mobile/desktop and bgfx-android both split init from
                // the per-frame tick, so the runner can't be an init-scope
                // local like the loop path). Raylib-wasm takes the `else`
                // branch below and declares its own runner inside `main()`.
                const callback_runner: []const u8 = if (cfg.backend == .sokol or is_bgfx_android) "var runner: Runner = undefined;\n" else "";
                // Sokol-backend builds get ALL THREE readback helper blocks
                // emitted side-by-side:
                //   - GL PBO ring (labelle-assembler#122 slice 1, #124) —
                //     fires on Linux/Android via `_sokol_preview_gl_enabled`.
                //   - D3D11 staging-texture ring (labelle-assembler#126,
                //     slice 2 of #122) — fires on Windows via
                //     `_sokol_preview_d3d11_enabled`.
                //   - Metal/IOSurface ring (labelle-assembler#125, slice 3
                //     of #122) — fires on macOS/iOS via
                //     `_sokol_preview_metal_enabled`.
                // The three gates are mutually exclusive (Linux vs Windows
                // vs Darwin), so only one block's runtime code path is
                // reachable per target. The `else struct {}` branches in
                // each helper namespace keep unresolved-symbol references
                // off the link line on the inactive targets.
                // Emit-unconditional for `cfg.backend == .sokol` keeps the
                // generated source uniform across desktop / mobile
                // templates; wasm routes through the raylib branch below
                // and stays out of all three readback paths for now.
                const sokol_readback_helpers: []const u8 = if (cfg.backend == .sokol)
                    try std.mem.concat(allocator, u8, &.{
                        PREVIEW_READBACK_HELPERS_SOKOL,
                        PREVIEW_READBACK_HELPERS_SOKOL_D3D11,
                        PREVIEW_READBACK_HELPERS_METAL_SOKOL,
                    })
                else
                    "";
                defer if (cfg.backend == .sokol) allocator.free(sokol_readback_helpers);
                // PREVIEW_INPUT_DISPATCH emits `extern fn imgui_bridge_mouse_*`
                // symbols, which only exist when the gui plugin is imgui. Gate
                // narrowly on plugin name — other gui plugins (clay, simple-raylib,
                // simple-sokol, …) would link-fail on these externs. The stub
                // variant provides safe no-ops for those projects.
                const input_dispatch_cb: []const u8 = if (cfg.resolved_gui) |gui|
                    (if (std.mem.eql(u8, gui.name, "imgui")) PREVIEW_INPUT_DISPATCH else PREVIEW_INPUT_DISPATCH_STUB)
                else
                    PREVIEW_INPUT_DISPATCH_STUB;
                const module_vars = try std.mem.concat(allocator, u8, &.{ callback_runner, PREVIEW_HELPERS, sokol_readback_helpers, input_dispatch_cb });
                defer allocator.free(module_vars);
                const init_code = try self.buildCallbackInitCode();
                defer allocator.free(init_code);

                const platform_comment: []const u8 = if (is_bgfx_android)
                    "Android: the bgfx NativeActivity shell (android_app.zig) drives the lifecycle"
                else switch (cfg.platform) {
                    .ios => "iOS: sokol bindings accessed through engine.sokol (no direct sokol import)",
                    .android => "Android: sokol handles the app lifecycle via NativeActivity",
                    .wasm => "WASM: Emscripten drives the main loop via callbacks",
                    .desktop => "",
                };
                const entry_comment: []const u8 = if (is_bgfx_android)
                    "Android entry — the game owns android_main; the bgfx shell runs the loop"
                else switch (cfg.platform) {
                    .ios => "iOS entry — no main(), sokol handles the app lifecycle",
                    .android => "Android entry — no main(), sokol handles the NativeActivity lifecycle",
                    .wasm => "WASM entry — Emscripten drives the main loop via callbacks",
                    .desktop => "",
                };

                if (cfg.backend == .sokol) {
                    const cleanup_code = try self.buildCallbackCleanupCode();
                    defer allocator.free(cleanup_code);
                    const is_wasm = cfg.platform == .wasm;
                    const allocator_decl: []const u8 = if (is_wasm)
                        "// Use c_allocator for Emscripten — delegates to emscripten's malloc/free\n// which respects ALLOW_MEMORY_GROWTH. GPA is incompatible with wasm32-emscripten.\nconst allocator = std.heap.c_allocator;"
                    else
                        "var gpa = std.heap.DebugAllocator(.{}).init;";
                    const allocator_expr: []const u8 = if (is_wasm) "std.heap.c_allocator" else "gpa.allocator()";
                    const allocator_cleanup: []const u8 = if (is_wasm) "" else "    _ = gpa.deinit();\n";
                    // For wasm, `allocator` is already declared at module scope
                    // by `{{allocator_decl}}` above, so re-declaring it inside
                    // `initInner` would trigger Zig's "local constant shadows
                    // declaration" error (labelle-cli#198). For desktop, the
                    // module scope only has `var gpa = ...`, so we still need
                    // the inner alias.
                    const allocator_local_decl: []const u8 = if (is_wasm) "" else "    const allocator = gpa.allocator();\n";

                    // Wire the GUI bridge into sokol's event callback so widgets
                    // see mouse / keyboard input. labelle-imgui's sokol bridge
                    // exports `imgui_bridge_handle_event` for exactly this — when
                    // a GUI plugin is configured we forward each event to it.
                    // Without this hook simgui's IO state stays empty and ImGui
                    // buttons/sliders never respond.
                    const gui_event_extern: []const u8 = if (cfg.hasGui())
                        "extern fn imgui_bridge_handle_event(ev: [*c]const @import(\"backend_input\").Event) bool;\n\n"
                    else
                        "";
                    const gui_event_forward: []const u8 = if (cfg.hasGui())
                        "    _ = imgui_bridge_handle_event(ev);\n"
                    else
                        "";

                    // Readback hookups (labelle-assembler#122). Each
                    // lifecycle slot gets ALL THREE backend variants
                    // concatenated (GL slice 1 #124, D3D11 slice 2 #126,
                    // Metal slice 3 #125):
                    //   - init   : stash the allocator into the module-scope
                    //              slot (idempotent across the three gates —
                    //              exactly one branch fires per target)
                    //   - frame  : pre-endFrame slot carries GL + D3D11
                    //              (both rely on a flush-on-read primitive
                    //              that's safe before `sg.commit()`); the
                    //              Metal block runs in the post-endFrame
                    //              slot because Metal needs `sg.commit()`
                    //              to land the swapchain texture before our
                    //              own command buffer can read it.
                    //   - cleanup: endFrameStream + ring teardown for each,
                    //              then the graceful `bye`. Buffer free
                    //              guarded so the inactive blocks are
                    //              no-ops.
                    // The three paths evaporate on the non-matching OS via
                    // their `_sokol_preview_{gl,d3d11,metal}_enabled` flags.
                    //
                    // Wasm-emscripten gate (labelle-assembler#141): preview
                    // mode is useless in a browser tab (no `LABELLE_PREVIEW`
                    // env, no TCP socket out), and `std.Io.Threaded.init` +
                    // `.io()` instantiates the vtable that references
                    // `childWaitPosix` → triggers the Zig 0.16
                    // `Threaded.zig:15315` / `emscripten.zig:215` enum
                    // mismatches. Emit empty strings for the preview slots
                    // on wasm so the generated `main.zig` never references
                    // `std.Io.Threaded`. See ziglang/zig#31849 + PR #31850
                    // for the upstream fix; this is the workaround for now.
                    const preview_setup_sokol = if (is_wasm)
                        try allocator.dupe(u8, "")
                    else
                        try std.mem.concat(allocator, u8, &.{
                            PREVIEW_INIT_CALLBACK,
                            PREVIEW_READBACK_INIT_SOKOL,
                            PREVIEW_READBACK_INIT_SOKOL_D3D11,
                            PREVIEW_READBACK_INIT_METAL_SOKOL,
                        });
                    defer allocator.free(preview_setup_sokol);
                    // Wasm-emscripten gate (labelle-assembler#141, same
                    // rationale as `preview_setup_sokol` above). Heartbeat
                    // + readback + cleanup all touch `g.preview`'s public
                    // methods, and Zig's lazy compilation may still pull
                    // the `popInputEvent` / `tickHeartbeat` codepaths into
                    // the wasm exe even when `g.preview` is statically
                    // null. Emit empty strings so the generated `main.zig`
                    // never references Preview's IO surface on wasm.
                    const preview_readback_sokol = if (is_wasm)
                        try allocator.dupe(u8, "")
                    else
                        try std.mem.concat(allocator, u8, &.{
                            PREVIEW_READBACK_FRAME_SOKOL,
                            PREVIEW_READBACK_FRAME_SOKOL_D3D11,
                            // Path A (#131): the Metal block no longer depends
                            // on a swapchain drawable, so it can run in the
                            // pre-endFrame slot alongside GL / D3D11. The
                            // `{{preview_readback_post}}` template hole gets
                            // an empty string below — kept in the template so
                            // existing test scaffolding still expands cleanly,
                            // but no longer carries any Metal payload.
                            PREVIEW_READBACK_FRAME_METAL_SOKOL,
                        });
                    defer allocator.free(preview_readback_sokol);
                    const preview_cleanup_sokol = if (is_wasm)
                        try allocator.dupe(u8, "")
                    else
                        try std.mem.concat(allocator, u8, &.{
                            PREVIEW_READBACK_CLEANUP_SOKOL,
                            PREVIEW_READBACK_CLEANUP_SOKOL_D3D11,
                            PREVIEW_READBACK_CLEANUP_METAL_SOKOL,
                            PREVIEW_CLEANUP_CALLBACK,
                        });
                    defer allocator.free(preview_cleanup_sokol);
                    const preview_heartbeat_sokol: []const u8 = if (is_wasm) "" else PREVIEW_HEARTBEAT_CALLBACK;

                    // `{{immersive_entry}}` — Android immersive-mode call,
                    // emitted into `sokol_main()` (UI thread, pre-callback
                    // registration) so the bars are hidden at launch. Empty
                    // for non-Android / non-immersive projects; the shared
                    // sokol `desktop.txt` has no such hole, so an empty
                    // value there is a harmless no-op.
                    const immersive_entry = try self.buildImmersiveEntryCode();
                    defer allocator.free(immersive_entry);

                    try tpl.render(lifecycle_tmpl, .{
                        .module_vars = module_vars,
                        .width = w_str,
                        .height = h_str,
                        .title = cfg.title,
                        .fps = fps_str,
                        .init_code = init_code,
                        .tick_code = tick_code,
                        .gui_draw_code = gui_draw_code,
                        .gui_event_extern = gui_event_extern,
                        .gui_event_forward = gui_event_forward,
                        .cleanup_code = cleanup_code,
                        .platform_comment = platform_comment,
                        .entry_comment = entry_comment,
                        .hidden_setup = hidden_setup,
                        .hooks_init_block = hooks_init,
                        .allocator_decl = allocator_decl,
                        .allocator_expr = allocator_expr,
                        .allocator_local_decl = allocator_local_decl,
                        .allocator_cleanup = allocator_cleanup,
                        // Preview-mode wiring (labelle-assembler#94,
                        // labelle-engine#520). `g.preview` is the canonical
                        // storage; init dials + assigns + seeds the PBO
                        // allocator, frame heartbeats + reads back pixels,
                        // cleanup tears down PBO state then emits the
                        // graceful `bye`, and `g.deinit` owns the socket +
                        // arena teardown.
                        .preview_setup = preview_setup_sokol,
                        .preview_heartbeat = preview_heartbeat_sokol,
                        // Path A render-target wiring (#133) — fires BEFORE
                        // `window.beginFrame()` so the swapchain-vs-offscreen
                        // decision is made before sokol-gfx commits to either.
                        // Empty under non-Darwin targets (the block is
                        // comptime-gated on `_sokol_preview_metal_enabled`).
                        // GL (#124) and D3D11 (#126) keep their existing
                        // pre-endFrame slot — their readback model is a
                        // post-commit copy, not a render redirect.
                        .preview_pre_render = PREVIEW_PRE_RENDER_METAL_SOKOL,
                        .preview_readback = preview_readback_sokol,
                        // Path A (#131): the Metal block is part of the
                        // pre-endFrame readback now, so the post-endFrame
                        // hole is empty. Kept in the template so the
                        // placeholder still expands cleanly; retiring it
                        // entirely is a separate cleanup step.
                        .preview_readback_post = "",
                        .preview_cleanup = preview_cleanup_sokol,
                        .immersive_entry = immersive_entry,
                    }, bw);
                } else if (is_bgfx_android) {
                    // bgfx-on-Android (#303): the generated game owns
                    // `android_main` and registers an init + frame callback
                    // with the bgfx NativeActivity shell, which drives the
                    // event/frame loop. Holes mirror `backends/bgfx/templates/
                    // android.txt`. `init_code` comes from the callback builder
                    // (void-safe — the shell's callback is `callconv(.c) void`,
                    // no error channel), `tick_code` is the shared engine-tick
                    // block, and the preview-mode readback slots are empty:
                    // bgfx has no on-device preview path yet (its desktop
                    // readback is a separate, unshipped ticket like sdl/wgpu).
                    //
                    // `{{android_backend_register}}` (#310 Stage 4): register the
                    // bgfx backend's Android JNI seam with core at the top of
                    // `gameInit`, before the first frame polls the gamepad source.
                    // Replaces the old sokol-compat shims (now removed from the
                    // template). Emitted UNCONDITIONALLY on bgfx-Android — gamepad
                    // detection needs it even when immersive mode is off — mirroring
                    // the sokol path (`buildImmersiveEntryCode`). `engine.core` is
                    // labelle-engine's re-export of labelle-core; the context comes
                    // from the bgfx backend adapter surfaced as `backend_input.android`.
                    //
                    // Immersive mode (bgfx-immersive). The engine's hook-based
                    // `enableImmersiveMode()` does NOT work on bgfx: native_app_glue
                    // owns `onContentRectChanged`, so the launch hook installs too
                    // late / clobbers the glue and the system-bar hide never fires.
                    // And the hide (`WindowInsetsController.hide()`) MUST run on the
                    // UI thread — the glue runs `gameFrame` on its app thread, so it
                    // can't be driven from the frame loop either (Android throws even
                    // from a JVM-attached app-thread; verified on-device).
                    //
                    // Instead the bgfx shell chains `onWindowFocusChanged` — a
                    // framework callback the OS fires ON THE UI THREAD at launch and
                    // on every focus regain — and invokes a registered callback from
                    // there. We register the engine's UI-thread hide
                    // (`engine.android.applyImmersiveUiThread`) via the shell's
                    // `setImmersiveCallback` in `android_main`, before `run()`. The
                    // generated `main` owns both the shell (`android_app`) and the
                    // engine, satisfying the backend-cannot-depend-on-engine rule.
                    const bgfx_immersive = if (cfg.android) |a| a.immersive_mode else false;
                    const immersive_register: []const u8 = if (bgfx_immersive)
                        "    // Android immersive mode (project.labelle `.android.immersive_mode`):\n" ++
                        "    // register the engine's UI-thread system-bar hide with the bgfx shell.\n" ++
                        "    // The shell chains onWindowFocusChanged (a UI-thread framework callback)\n" ++
                        "    // and invokes this on launch + every focus regain, so the bars hide at\n" ++
                        "    // launch and re-hide after a swipe / returning from the shade. The\n" ++
                        "    // hook-based enableImmersiveMode() can't work under native_app_glue.\n" ++
                        "    // See labelle-engine src/android.zig (applyImmersiveUiThread) and\n" ++
                        "    // backends/bgfx/src/android_app.zig (setImmersiveCallback / focusHook).\n" ++
                        "    android_app.setImmersiveCallback(&engine.android.applyImmersiveUiThread);\n"
                    else
                        "";

                    try tpl.render(lifecycle_tmpl, .{
                        .module_vars = module_vars,
                        .width = w_str,
                        .height = h_str,
                        .title = cfg.title,
                        .fps = fps_str,
                        .init_code = init_code,
                        .tick_code = tick_code,
                        .gui_draw_code = gui_draw_code,
                        .hooks_init_block = hooks_init,
                        .platform_comment = platform_comment,
                        .entry_comment = entry_comment,
                        .preview_setup = "",
                        .preview_heartbeat = "",
                        .android_backend_register = BGFX_ANDROID_BACKEND_REGISTER,
                        .immersive_register = immersive_register,
                    }, bw);
                } else {
                    // Raylib wasm: emscripten-driven callback loop. Preview
                    // setup runs once in main() before the loop is handed
                    // to emscripten; heartbeats fire inside `gameFrame`.
                    // No cleanup callback — emscripten keeps running after
                    // main returns, and the editor reads EOF on tab close.
                    //
                    // Wasm-emscripten gate (labelle-assembler#141): preview
                    // mode is useless in a browser tab, and the explicit
                    // `std.Io.Threaded.init` in PREVIEW_INIT_CALLBACK pulls
                    // the broken Zig 0.16 posix wrappers into the wasm exe
                    // (Threaded.zig:15315 / emscripten.zig:215). Emit empty
                    // strings on wasm. Both branches of this `if/else` land
                    // on wasm in practice, but keep the gate explicit so
                    // the intent is local.
                    const is_wasm_raylib = cfg.platform == .wasm;
                    try tpl.render(lifecycle_tmpl, .{
                        .width = w_str,
                        .height = h_str,
                        .title = cfg.title,
                        .fps = fps_str,
                        .setup_code = init_code,
                        .tick_code = tick_code,
                        .gui_draw_code = gui_draw_code,
                        .hidden_setup = hidden_setup,
                        .hooks_init_block = hooks_init,
                        .preview_setup = if (is_wasm_raylib) "" else PREVIEW_INIT_CALLBACK,
                        .preview_heartbeat = if (is_wasm_raylib) "" else PREVIEW_HEARTBEAT_CALLBACK,
                    }, bw);
                }
            } else {
                const setup_code = try self.buildSetupCode();
                defer allocator.free(setup_code);

                // Raylib desktop gets the PBO async-readback block + the GL
                // externs that drive it (labelle-engine#544). The PoC at
                // imgui-preview-poc/src/game.zig is the reference shape.
                // Other loop backends (sdl/bgfx/wgpu) keep an empty readback
                // slot until their per-backend tickets land — sokol's readback
                // already runs through its own callback path. raylib WASM
                // takes the callback branch above, so this only fires for
                // raylib desktop.
                // An EXTERNAL backend leaves `cfg.backend` at its `.raylib`
                // enum default (the tag is meaningless for a named package —
                // selection comes from the manifest, #386). A bare `== .raylib`
                // would therefore misfire on every external backend and emit
                // raylib's PBO async-readback against a window module that has
                // no `preview_pbo`. External backends take the empty-readback
                // path the other loop backends (null/sdl/bgfx/wgpu) use until
                // they declare their own preview support.
                const is_raylib_desktop = cfg.backend == .raylib and !cfg.isExternal();
                // Preview mouse-input forwarding is sokol-only: the
                // `imgui_bridge_mouse_*` externs `PREVIEW_INPUT_DISPATCH`
                // declares are exported solely by the *sokol* imgui bridge
                // (`bridges/sokol`). The raylib imgui bridge (`bridges/raylib`,
                // rlImGui) does NOT export them — rlImGui reads raylib's own
                // input each frame — so a raylib+imgui build that emitted the
                // imgui dispatch failed to link with
                // `undefined symbol: _imgui_bridge_mouse_button`. This loop
                // lifecycle path is reached by raylib desktop (and other loop
                // backends), so it must always take the STUB; the imgui
                // dispatch lives on the sokol-callback site above.
                const input_dispatch: []const u8 = PREVIEW_INPUT_DISPATCH_STUB;
                const module_vars_loop = if (is_raylib_desktop)
                    try std.mem.concat(allocator, u8, &.{ PREVIEW_HELPERS, PREVIEW_READBACK_HELPERS, input_dispatch })
                else
                    try std.mem.concat(allocator, u8, &.{ PREVIEW_HELPERS, input_dispatch });
                defer allocator.free(module_vars_loop);
                const preview_setup_loop = if (is_raylib_desktop)
                    try std.mem.concat(allocator, u8, &.{ PREVIEW_LOOP_SETUP, PREVIEW_READBACK_SETUP })
                else
                    PREVIEW_LOOP_SETUP;
                defer if (is_raylib_desktop) allocator.free(preview_setup_loop);
                const readback_block = if (is_raylib_desktop) PREVIEW_READBACK_LOOP else "";

                try tpl.render(lifecycle_tmpl, .{
                    .width = w_str,
                    .height = h_str,
                    .title = cfg.title,
                    .fps = fps_str,
                    .setup_code = setup_code,
                    .tick_code = tick_code,
                    .gui_draw_code = gui_draw_code,
                    .hidden_setup = hidden_setup,
                    .hooks_init_block = hooks_init,
                    .module_vars = module_vars_loop,
                    // Preview-mode wiring (labelle-assembler#94). Always
                    // emitted; runtime parse returns null when the flag is
                    // absent so the block is a no-op for non-preview runs.
                    .preview_setup = preview_setup_loop,
                    .preview_heartbeat = PREVIEW_HEARTBEAT_LOOP,
                    .preview_readback = readback_block,
                }, bw);
            }
        }
    };
}
