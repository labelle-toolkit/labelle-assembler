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
const manifest_v2 = @import("../manifest_v2.zig");

/// Which preview-mode wiring a callback lifecycle emits (assembler#501). The
/// three callback branches used to hard-code this; it is now a computed value.
///   - `sokol_readback`: sokol's full GL/D3D11/Metal readback superset (#122).
///   - `callback_basic`: the generic emscripten INIT/HEARTBEAT callbacks the
///     raylib/bgfx wasm else-path fills (backend-agnostic).
///   - `none`: no preview wiring (bgfx-android, declared third-party callback).
const CallbackPreview = enum { none, sokol_readback, callback_basic };

/// Which Android registration seam a callback lifecycle wires (assembler#501).
///   - `bgfx_shell`: the bgfx NativeActivity shell register + immersive hook.
///   - `none`: no Android registration (sokol routes its own via
///     `immersive_entry`; third-party desktop callbacks have none).
const AndroidRegister = enum { none, bgfx_shell };

/// The fixed, assembler-computed shape of a callback lifecycle (assembler#501).
/// For the six built-ins it is derived from the existing enum predicates
/// (byte-identical behavior); for a declared third-party callback backend it is
/// computed from the manifest `.platforms.<p>.lifecycle` declaration. Every
/// callback template hole is then a value keyed on this shape, rendered through
/// ONE `tpl.render` call (the superset-hole collapse of the former three).
const LifecycleShape = struct {
    /// Emit `var runner: Runner = undefined;` at module scope.
    runner: bool,
    /// Emit the `{{cleanup_code}}` callback body (`buildCallbackCleanupCode`).
    cleanup: bool,
    /// Emit the `{{allocator_decl/expr/local_decl/cleanup}}` holes (sokol).
    allocator: bool,
    /// Emit the imgui `{{gui_event_extern}}`/`{{gui_event_forward}}` holes.
    gui_event: bool,
    /// `{{module_vars}}` input dispatch is the imgui-conditional variant
    /// (else the safe no-op stub). sokol/bgfx-android use the conditional
    /// variant; wasm/third-party use the stub.
    imgui_dispatch: bool,
    preview: CallbackPreview,
    android: AndroidRegister,
};

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
            /// Manifest-declared callback-lifecycle blocks (assembler#501).
            /// Non-null lifts the callback-external rejection AND drives the
            /// shape for a genuine third-party (non-enum-tag) callback backend.
            /// Passed by value (like `loop_style_ovr`) so this module stays
            /// decoupled from the orchestrator's `threadlocal`.
            lifecycle_ovr: ?manifest_v2.BackendManifestV2.PlatformEntry.Lifecycle,
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
            // for an extracted bgfx/sokol.
            //
            // WASM (bgfx-wasm epic labelle-bgfx#8): the callback `else` branch
            // below is the GENERIC emscripten `emscripten_set_main_loop` path —
            // it fills only backend-agnostic template holes, and the wasm shape
            // (loop callback, `g.tick`, no module-scope runner) is shipped by the
            // backend's OWN `templates/wasm.txt`. So any FIRST-PARTY (enum-tag-
            // backed) external backend on wasm — raylib, sokol, bgfx — is safe
            // through it. Post-#386 raylib/bgfx are external too, so keying only
            // off `== .sokol` left every other first-party wasm backend wrongly
            // rejected (the else branch went unreachable at the flip). What stays
            // rejected is a genuine THIRD-PARTY callback backend named only by
            // string (`cfg.backend` at its `.raylib` default, `backendName()` !=
            // the tag): `isEnumTagBacked()` is false for it, so it never inherits
            // the raylib-shaped wasm wiring against an unvalidated template.
            // Built-ins are unaffected (`isExternal()` is false).
            //
            // A DECLARED callback backend (assembler#501) is also handled: its
            // manifest `.platforms.<p>.lifecycle` names the assembler-known
            // blocks its entry template consumes, so the third-party dispatch
            // branch below has a real shape to render. An UNDECLARED callback
            // external stays rejected — the fail-fast is the safety property.
            const callback_dispatch_handled = is_bgfx_android or cfg.backend == .sokol or
                (cfg.platform == .wasm and cfg.isEnumTagBacked()) or lifecycle_ovr != null;
            if (use_callback_lifecycle and cfg.isExternal() and !callback_dispatch_handled) {
                // Silenced under test (the Zig test runner fails any test that
                // emits a `std.log.err`, even when the error is the asserted
                // outcome — see env.zig's HOME-missing log for the same gate).
                // The returned error is the hard signal; this is the human hint.
                if (!builtin.is_test) {
                    std.log.err(
                        "labelle-assembler: external backend '{s}' declares a callback run-loop " ++
                            "(loop_style = .callback) but does NOT declare its lifecycle blocks — " ++
                            "add `.platforms.<platform>.lifecycle` to its backend.manifest.v2.zon so " ++
                            "codegen knows which callback blocks its entry template consumes " ++
                            "(assembler#501). Loop-style external backends need no such declaration.",
                        .{cfg.backendName()},
                    );
                }
                return error.ExternalCallbackBackendUnsupported;
            }

            if (use_callback_lifecycle) {
                // The fixed shape of this callback lifecycle (assembler#501).
                // For the six built-ins it is derived from the SAME enum
                // predicates as before (byte-identical output); for a declared
                // third-party callback backend it comes from the manifest
                // `.lifecycle`. Sokol/bgfx-android are matched FIRST, so the
                // declared branch only ever covers a genuine non-enum-tag
                // callback backend (the wasm else-shape is the remaining
                // first-party fall-through). Every callback hole below is a
                // value keyed on this shape, rendered through ONE `tpl.render`.
                const shape: LifecycleShape = if (cfg.backend == .sokol)
                    .{ .runner = true, .cleanup = true, .allocator = true, .gui_event = true, .imgui_dispatch = true, .preview = .sokol_readback, .android = .none }
                else if (is_bgfx_android)
                    .{ .runner = true, .cleanup = false, .allocator = false, .gui_event = false, .imgui_dispatch = true, .preview = .none, .android = .bgfx_shell }
                else if (lifecycle_ovr) |decl|
                    // Declared third-party callback backend: only the fixed
                    // engine-facing blocks are declarable — the sokol readback,
                    // imgui-bridge externs, and bgfx shell reference backend-
                    // private symbols and stay keyed to the built-in branches.
                    .{ .runner = decl.runner_module_var, .cleanup = decl.cleanup_callback, .allocator = decl.allocator_holes, .gui_event = decl.gui_events, .imgui_dispatch = false, .preview = .none, .android = .none }
                else
                    // Raylib/bgfx wasm (first-party): the generic emscripten
                    // callback else-path — module-scope runner, INIT/HEARTBEAT
                    // preview callbacks, no backend-specific holes.
                    .{ .runner = true, .cleanup = false, .allocator = false, .gui_event = false, .imgui_dispatch = false, .preview = .callback_basic, .android = .none };

                const is_wasm = cfg.platform == .wasm;

                // Module-scope `runner` decl — needed by every callback-path
                // backend whose `init_code` ASSIGNS `runner = Runner.init(...)`
                // (sokol mobile/desktop and bgfx-android both split init from
                // the per-frame tick, so the runner can't be an init-scope
                // local like the loop path).
                const runner_decl: []const u8 = if (shape.runner) "var runner: Runner = undefined;\n" else "";
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
                const sokol_readback_helpers: []const u8 = if (shape.preview == .sokol_readback)
                    try std.mem.concat(allocator, u8, &.{
                        PREVIEW_READBACK_HELPERS_SOKOL,
                        PREVIEW_READBACK_HELPERS_SOKOL_D3D11,
                        PREVIEW_READBACK_HELPERS_METAL_SOKOL,
                    })
                else
                    "";
                defer if (shape.preview == .sokol_readback) allocator.free(sokol_readback_helpers);
                // PREVIEW_INPUT_DISPATCH emits `extern fn imgui_bridge_mouse_*`
                // symbols, which only exist when the gui plugin is imgui. Gate
                // narrowly on plugin name — other gui plugins (clay, simple-raylib,
                // simple-sokol, …) would link-fail on these externs. The stub
                // variant provides safe no-ops for those projects. Only the
                // sokol/bgfx-android shapes take the imgui-conditional dispatch;
                // wasm/third-party always take the safe stub.
                const input_dispatch_cb: []const u8 = if (cfg.resolved_gui) |gui|
                    (if (std.mem.eql(u8, gui.name, "imgui")) PREVIEW_INPUT_DISPATCH else PREVIEW_INPUT_DISPATCH_STUB)
                else
                    PREVIEW_INPUT_DISPATCH_STUB;
                const input_dispatch: []const u8 = if (shape.imgui_dispatch) input_dispatch_cb else PREVIEW_INPUT_DISPATCH_STUB;
                const module_vars = try std.mem.concat(allocator, u8, &.{ runner_decl, PREVIEW_HELPERS, sokol_readback_helpers, input_dispatch });
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

                // ── Callback lifecycle holes (assembler#501) ──────────────
                // Every hole is a value keyed on `shape`; the superset is
                // rendered through ONE `tpl.render`. Holes a given entry
                // template does not declare are harmlessly ignored (unknown
                // struct keys); a shape must fill every hole its template DOES
                // declare (`tpl.render` leaves truly-absent holes verbatim).

                const cleanup_code: []const u8 = if (shape.cleanup) try self.buildCallbackCleanupCode() else "";
                defer if (shape.cleanup) allocator.free(cleanup_code);

                // Allocator holes (sokol shape): module-scope decl + inner
                // alias + init expr + cleanup. wasm uses c_allocator (GPA is
                // incompatible with wasm32-emscripten); the inner alias is empty
                // on wasm to avoid shadowing the module-scope decl
                // (labelle-cli#198). Empty for every non-allocator shape.
                const allocator_decl: []const u8 = if (!shape.allocator)
                    ""
                else if (is_wasm)
                    "// Use c_allocator for Emscripten — delegates to emscripten's malloc/free\n// which respects ALLOW_MEMORY_GROWTH. GPA is incompatible with wasm32-emscripten.\nconst allocator = std.heap.c_allocator;"
                else
                    "var gpa = std.heap.DebugAllocator(.{}).init;";
                const allocator_expr: []const u8 = if (!shape.allocator) "" else if (is_wasm) "std.heap.c_allocator" else "gpa.allocator()";
                const allocator_cleanup: []const u8 = if (!shape.allocator) "" else if (is_wasm) "" else "    _ = gpa.deinit();\n";
                const allocator_local_decl: []const u8 = if (!shape.allocator) "" else if (is_wasm) "" else "    const allocator = gpa.allocator();\n";

                // Wire the GUI bridge into sokol's event callback so widgets see
                // mouse / keyboard input. labelle-imgui's sokol bridge exports
                // `imgui_bridge_handle_event`; only the sokol shape declares the
                // holes, and only when a GUI plugin is configured.
                const gui_event_extern: []const u8 = if (shape.gui_event and cfg.hasGui())
                    "extern fn imgui_bridge_handle_event(ev: [*c]const @import(\"backend_input\").Event) bool;\n\n"
                else
                    "";
                const gui_event_forward: []const u8 = if (shape.gui_event and cfg.hasGui())
                    "    _ = imgui_bridge_handle_event(ev);\n"
                else
                    "";

                // Preview-mode wiring. The sokol shape emits ALL THREE readback
                // helper slots (GL slice 1 #124, D3D11 slice 2 #126, Metal slice
                // 3 #125), each keyed on `_sokol_preview_{gl,d3d11,metal}_enabled`
                // so exactly one path is live per target. The wasm callback-basic
                // shape emits only the generic emscripten INIT/HEARTBEAT
                // callbacks; every other shape emits nothing.
                //
                // Wasm-emscripten gate (labelle-assembler#141): sokol's preview
                // slots reference `std.Io.Threaded` (broken under wasm32-
                // emscripten, Threaded.zig:15315 / emscripten.zig:215), so they
                // go empty on wasm. See ziglang/zig#31849 + PR #31850.
                const sokol_preview = shape.preview == .sokol_readback;
                const preview_setup: []const u8 = blk: {
                    if (sokol_preview) break :blk if (is_wasm) "" else try std.mem.concat(allocator, u8, &.{
                        PREVIEW_INIT_CALLBACK,
                        PREVIEW_READBACK_INIT_SOKOL,
                        PREVIEW_READBACK_INIT_SOKOL_D3D11,
                        PREVIEW_READBACK_INIT_METAL_SOKOL,
                    });
                    if (shape.preview == .callback_basic) break :blk if (is_wasm) "" else PREVIEW_INIT_CALLBACK;
                    break :blk "";
                };
                defer if (sokol_preview and !is_wasm) allocator.free(preview_setup);
                const preview_readback: []const u8 = blk: {
                    if (sokol_preview) break :blk if (is_wasm) "" else try std.mem.concat(allocator, u8, &.{
                        PREVIEW_READBACK_FRAME_SOKOL,
                        PREVIEW_READBACK_FRAME_SOKOL_D3D11,
                        // Path A (#131): the Metal block runs in the pre-endFrame
                        // slot alongside GL / D3D11; the `{{preview_readback_post}}`
                        // hole below is empty (kept so scaffolding expands cleanly).
                        PREVIEW_READBACK_FRAME_METAL_SOKOL,
                    });
                    break :blk "";
                };
                defer if (sokol_preview and !is_wasm) allocator.free(preview_readback);
                const preview_cleanup: []const u8 = blk: {
                    if (sokol_preview) break :blk if (is_wasm) "" else try std.mem.concat(allocator, u8, &.{
                        PREVIEW_READBACK_CLEANUP_SOKOL,
                        PREVIEW_READBACK_CLEANUP_SOKOL_D3D11,
                        PREVIEW_READBACK_CLEANUP_METAL_SOKOL,
                        PREVIEW_CLEANUP_CALLBACK,
                    });
                    break :blk "";
                };
                defer if (sokol_preview and !is_wasm) allocator.free(preview_cleanup);
                const preview_heartbeat: []const u8 = switch (shape.preview) {
                    .sokol_readback, .callback_basic => if (is_wasm) "" else PREVIEW_HEARTBEAT_CALLBACK,
                    .none => "",
                };
                // Path A render-target wiring (#133) — sokol only, comptime-gated
                // on `_sokol_preview_metal_enabled` (empty on non-Darwin targets).
                const preview_pre_render: []const u8 = if (sokol_preview) PREVIEW_PRE_RENDER_METAL_SOKOL else "";
                // Path A (#131): the Metal readback moved to the pre-endFrame
                // slot, so this hole is always empty.
                const preview_readback_post: []const u8 = "";

                // `{{immersive_entry}}` — sokol Android immersive-mode call +
                // backend-context registration, emitted into `sokol_main()`
                // (UI thread, pre-callback registration). Empty (but allocated)
                // off Android; only the sokol shape emits it.
                const immersive_entry: []const u8 = if (sokol_preview) try self.buildImmersiveEntryCode() else "";
                defer if (sokol_preview) allocator.free(immersive_entry);

                // bgfx-on-Android registration seam (#310 Stage 4) + immersive
                // hook — only the bgfx_shell android shape emits them. The bgfx
                // shell chains `onWindowFocusChanged` (a UI-thread framework
                // callback) and invokes the engine's UI-thread system-bar hide;
                // the hook-based `enableImmersiveMode()` can't work under
                // native_app_glue. See backends/bgfx/src/android_app.zig.
                const android_backend_register: []const u8 = if (shape.android == .bgfx_shell) BGFX_ANDROID_BACKEND_REGISTER else "";
                const immersive_register: []const u8 = if (shape.android == .bgfx_shell and (if (cfg.android) |a| a.immersive_mode else false))
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

                // ONE render for every callback shape — the superset-hole
                // collapse of the former three per-branch `tpl.render` calls
                // (assembler#501). `init_code` doubles as `setup_code` (the wasm
                // else-path's hole spelling); each template consumes only the
                // holes it declares. `g.preview` is the canonical preview
                // storage — init dials/assigns/seeds the PBO allocator, frame
                // heartbeats + reads back pixels, cleanup tears it down.
                try tpl.render(lifecycle_tmpl, .{
                    .module_vars = module_vars,
                    .width = w_str,
                    .height = h_str,
                    .title = cfg.title,
                    .fps = fps_str,
                    .init_code = init_code,
                    .setup_code = init_code,
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
                    .preview_setup = preview_setup,
                    .preview_heartbeat = preview_heartbeat,
                    .preview_pre_render = preview_pre_render,
                    .preview_readback = preview_readback,
                    .preview_readback_post = preview_readback_post,
                    .preview_cleanup = preview_cleanup,
                    .immersive_entry = immersive_entry,
                    .android_backend_register = android_backend_register,
                    .immersive_register = immersive_register,
                }, bw);
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
                // Match on the RESOLVED backend NAME, not `!isExternal()`.
                // Post-#386 flip, `.backend = .raylib` resolves to the external
                // labelle-raylib package (`isExternal()` is now true even for the
                // default raylib), yet labelle-raylib's desktop template STILL
                // carries the `{{preview_setup}}`/`{{preview_readback}}` holes this
                // block fills — so a `!isExternal()` gate emits them EMPTY and the
                // editor preview connects but publishes no frames (the #409 gate,
                // written while raylib was still bundled, over-fired after the
                // flip). `backendName()` is "raylib" for both the (former) bundled
                // build and the tag-matched external default, so the PBO readback
                // fires for raylib desktop either way. A THIRD-PARTY external
                // backend leaves `cfg.backend` at its `.raylib` enum default but
                // resolves a differently-NAMED package, so `backendName()` is NOT
                // "raylib" — it correctly stays on the empty-readback path (the
                // #409 intent: don't emit raylib's PBO readback against a window
                // module with no `preview_pbo`), same as null/sdl/bgfx/wgpu.
                const is_raylib_desktop = std.mem.eql(u8, cfg.backendName(), "raylib");
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
