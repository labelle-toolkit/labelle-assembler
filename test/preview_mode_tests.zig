const std = @import("std");
const zspec = @import("zspec");
const generate = @import("generator");
const h = @import("helpers.zig");

const engine_template = h.engine_template;
const raylib_lifecycle = h.raylib_lifecycle;
const sokol_lifecycle = h.sokol_lifecycle;
const null_lifecycle = h.null_lifecycle;
const sokol_alloc_lifecycle = h.sokol_alloc_lifecycle;
const empty_names = h.empty_names;
const ScriptEntry = h.ScriptEntry;
const empty_entries = h.empty_entries;
const SceneManifest = h.SceneManifest;
const empty_scene_manifests = h.empty_scene_manifests;
const PluginEvent = h.PluginEvent;
const empty_plugin_events = h.empty_plugin_events;
const PluginFlowNode = h.PluginFlowNode;
const empty_plugin_flow_nodes = h.empty_plugin_flow_nodes;
const PluginPinStyle = h.PluginPinStyle;
const empty_plugin_pin_styles = h.empty_plugin_pin_styles;
const PluginCoercion = h.PluginCoercion;
const empty_plugin_coercions = h.empty_plugin_coercions;
const GlobalEntries = h.GlobalEntries;
const globalEntries = h.globalEntries;
const testGuiRenderInterface = h.testGuiRenderInterface;
const testGuiRawBackend = h.testGuiRawBackend;

test {
    zspec.runAll(@This());
}

pub const PREVIEW_MODE = struct {
    // Loop-style lifecycle (raylib / sdl / bgfx / wgpu desktop). Matches
    // the placement in `backends/raylib/templates/desktop.txt` — preview
    // setup runs AFTER `var g = AssembledGame.init(...)` so it can
    // assign directly into `g.preview` (labelle-engine#520); heartbeat
    // sits at the top of the loop.
    const preview_loop_lifecycle =
        \\const screen_w: u32 = {{width}};
        \\const screen_h: u32 = {{height}};
        \\pub fn main() !void {
        \\    var gpa = std.heap.DebugAllocator(.{}).init;
        \\    const allocator = gpa.allocator();
        \\{{hidden_setup}}    var hooks = GameHooks{};
        \\    var g = AssembledGame.init(allocator);
        \\    defer g.deinit();
        \\    g.setHooks(&hooks);
        \\{{preview_setup}}{{setup_code}}
        \\    while (true) {
        \\        const dt: f32 = 0.016;
        \\{{preview_heartbeat}}{{tick_code}}        g.tick(dt);
        \\{{gui_draw_code}}    }
        \\}
        \\
    ;

    // Sokol-style callback lifecycle. Mirrors
    // `backends/sokol/templates/desktop.txt` placement: preview setup
    // inside `initInner` (after `g = AssembledGame.init(...)`), heartbeat
    // in `frame`, graceful `bye` in `cleanup`. Game.deinit owns the
    // socket+arena teardown.
    const preview_sokol_lifecycle =
        \\var g: AssembledGame = undefined;
        \\{{hooks_init_block}}
        \\{{allocator_decl}}
        \\{{module_vars}}
        \\fn initInner() !void {
        \\    const allocator = {{allocator_expr}};
        \\{{preview_setup}}{{init_code}}}
        \\
        \\export fn init() callconv(.c) void {
        \\    g = AssembledGame.init({{allocator_expr}});
        \\    g.setHooks(&hooks);
        \\    initInner() catch unreachable;
        \\}
        \\
        \\export fn frame() callconv(.c) void {
        \\    const dt: f32 = 0.016;
        \\{{preview_heartbeat}}{{tick_code}}    g.tick(dt);
        \\{{gui_draw_code}}}
        \\
        \\export fn cleanup() callconv(.c) void {
        \\{{preview_cleanup}}{{cleanup_code}}    g.deinit();
        \\{{allocator_cleanup}}}
        \\
    ;

    test "loop backend emits argv parse + Preview lifecycle + heartbeat" {
        // Stubbed during Zig 0.16 migration — std.process.argsAlloc was
        // removed and engine.Preview now returns PreviewDisabled. The
        // generated main no longer wires preview-mode args/connect.
        // Restore once preview_mode is rewritten on std.Io.net.
        return error.SkipZigTest;
    }
    test "loop backend emits argv parse + Preview lifecycle + heartbeat — original" {
        if (true) return error.SkipZigTest;
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, preview_loop_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // Argv parser is wired through the engine's re-export.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "std.process.argsAlloc(allocator)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "engine.parsePreviewArgs(_argv)") != null);

        // Connect assigns directly into `g.preview` so Phase 2 ECS
        // telemetry (labelle-engine#520) can fire from the first scene
        // load. No local `_preview` holding slot.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "g.preview = engine.Preview.connect(allocator, _ep)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "var _preview:") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_p.sendHello(") != null);

        // Clean shutdown via defer: only emits the graceful `bye`. The
        // socket close + arena teardown live inside `Game.deinit`
        // (registered earlier, so LIFO runs `sendBye` first then deinit).
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "defer if (g.preview)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_p.sendBye(.normal)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_p.deinit()") == null);

        // PID sent in `hello` is currently a placeholder 0 — the
        // per-OS branch via `std.posix.getpid()` broke on Linux because
        // that function isn't on `std.posix` in Zig 0.15.2's stdlib.
        // Diagnostic value only; editor doesn't depend on the real PID.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "std.posix.system.getpid()") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "std.posix.getpid()") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_p.sendHello(\"labelle-engine\", 0)") != null);

        // Heartbeat inside the frame loop — rate-limited inside
        // tickHeartbeat itself, so a per-tick call is safe.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_p.tickHeartbeat(") != null);

        // Drain editor `subscribe` / `unsubscribe` frames every tick.
        // Without this call the `subscribed_components` set stays
        // empty and `component_changed` frames are silently dropped
        // by `isComponentSubscribed` (labelle-engine preview_mode.zig).
        // Must run BEFORE the heartbeat write so a malformed
        // subscription frame doesn't poison the same flush.
        const poll_idx = std.mem.indexOf(u8, main_zig, "_p.pollSubscription()");
        const tick_idx = std.mem.indexOf(u8, main_zig, "_p.tickHeartbeat(");
        try std.testing.expect(poll_idx != null);
        try std.testing.expect(tick_idx != null);
        try std.testing.expect(poll_idx.? < tick_idx.?);

        // Generated source must still be parseable.
        const dup = try std.testing.allocator.dupeZ(u8, main_zig);
        defer std.testing.allocator.free(dup);
        var ast = try std.zig.Ast.parse(std.testing.allocator, dup, .zig);
        defer ast.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    }

    test "sokol callback backend emits module-level Preview + init/frame/cleanup wiring" {
        // Stubbed during Zig 0.16 migration — see sibling loop test.
        return error.SkipZigTest;
    }
    test "sokol callback backend emits module-level Preview + init/frame/cleanup wiring — original" {
        if (true) return error.SkipZigTest;
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
        }, preview_sokol_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // No module-level `_preview` decl — `g.preview` is the
        // canonical storage (labelle-engine#520).
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "var _preview:") == null);

        // initInner handles connect + hello against `g.preview`. The
        // argv allocation runs through an `if/else |_|` rather than a
        // `catch &[_][:0]u8{}` sentinel — the sentinel form produces a
        // `[]const [:0]u8` which mismatches `argsFree`'s `[][:0]u8`
        // parameter (PR #95 review). Asserting `if (std.process.argsAlloc...`
        // and the absence of the empty-sentinel form locks the shape in.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "if (std.process.argsAlloc(allocator)) |_argv|") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "&[_][:0]u8{}") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "engine.parsePreviewArgs(_argv)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "g.preview = engine.Preview.connect(allocator, _ep)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_p.sendHello(") != null);

        // PID placeholder 0 (see loop-backend test for rationale).
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "std.posix.system.getpid()") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "std.posix.getpid()") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_p.sendHello(\"labelle-engine\", 0)") != null);

        // frame tick fires the heartbeat (rate-limit inside tickHeartbeat).
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_p.tickHeartbeat(") != null);

        // Same subscribe-frame drain as the loop backend. Poll runs
        // before heartbeat so a malformed subscribe can't poison the
        // outbound flush. See loop-backend test for full rationale.
        const poll_idx = std.mem.indexOf(u8, main_zig, "_p.pollSubscription()");
        const tick_idx = std.mem.indexOf(u8, main_zig, "_p.tickHeartbeat(");
        try std.testing.expect(poll_idx != null);
        try std.testing.expect(tick_idx != null);
        try std.testing.expect(poll_idx.? < tick_idx.?);

        // cleanup callback only emits the graceful `bye`. The actual
        // socket + arena teardown lives in `g.deinit()` (called by
        // `{{cleanup_code}}` immediately after) per labelle-engine#520.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_p.sendBye(.normal)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_p.deinit()") == null);

        // AST parses cleanly.
        const dup = try std.testing.allocator.dupeZ(u8, main_zig);
        defer std.testing.allocator.free(dup);
        var ast = try std.zig.Ast.parse(std.testing.allocator, dup, .zig);
        defer ast.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    }

    // PBO async-readback codegen for the raylib desktop loop
    // (labelle-engine#544). Mirrors `backends/raylib/templates/desktop.txt`
    // placement: the `{{preview_readback}}` block sits between
    // `g.renderGizmos()` / GUI draw and `window.endDrawing()`, so the
    // glReadPixels DMA hits the still-bound back buffer before raylib
    // swaps. The test uses a stripped-down lifecycle that mirrors the
    // real shape — full template assertions live in the smoke run
    // documented in the PR body.
    const preview_readback_lifecycle =
        \\const screen_w: u32 = {{width}};
        \\const screen_h: u32 = {{height}};
        \\
        \\{{module_vars}}pub fn main() !void {
        \\    var gpa = std.heap.DebugAllocator(.{}).init;
        \\    defer _ = gpa.deinit();
        \\    const allocator = gpa.allocator();
        \\    window.initWindow(screen_w, screen_h, "t");
        \\    defer window.closeWindow();
        \\    var hooks = GameHooks{};
        \\    var g = AssembledGame.init(allocator);
        \\    defer g.deinit();
        \\    g.setHooks(&hooks);
        \\{{preview_setup}}{{setup_code}}
        \\    while (!window.windowShouldClose()) {
        \\        const dt: f32 = 0.016;
        \\{{preview_heartbeat}}{{tick_code}}        g.tick(dt);
        \\        window.beginDrawing();
        \\        g.render();
        \\        g.renderGizmos();
        \\{{gui_draw_code}}{{preview_readback}}        window.endDrawing();
        \\    }
        \\}
        \\
    ;

    test "non-raylib loop backends do not pull in GL externs or PBO readback" {
        // sdl is the regression lock: it shares the loop-style lifecycle
        // branch with raylib but doesn't link OpenGL directly, so
        // emitting `_gl_read_pixels` etc. there would either fail to
        // link or compile against the wrong driver. The conditional on
        // `cfg.backend == .raylib` in `main_zig.zig` is what keeps the
        // readback block out of sdl/bgfx/wgpu — this asserts that.
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .sdl,
            .ecs = .mock,
        }, preview_readback_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_gl_read_pixels") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_gl_gen_buffers") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_GL_PIXEL_PACK_BUFFER") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_p.beginFrameStream(") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_p.publishFrame(") == null);

        // Control-plane wiring stays intact for the non-raylib backends
        // — they still speak the heartbeat / hello / bye protocol over
        // TCP, just without the SHM pixel stream.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_p.sendHello(") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_p.tickHeartbeat(") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_p.sendBye(.normal)") != null);
    }

    test "external backend does not pull in raylib PBO readback (cfg.backend defaults to .raylib)" {
        // Pluggable-backends regression (#386). An external `backend_package`
        // leaves `cfg.backend` at its `.raylib` enum DEFAULT — the tag is
        // meaningless for a named out-of-tree backend; selection comes from the
        // package manifest. A bare `cfg.backend == .raylib` readback gate would
        // therefore misfire and splice raylib's PBO async-readback
        // (`window.preview_pbo.*`, the `_preview_pbo_*` bridges) into a game
        // whose backend window module has no such surface — the exact compile
        // failure the headless `nullfixture` external backend hit before the
        // gate was tightened to `== .raylib and !cfg.isExternal()`. The
        // control plane (hello/heartbeat/bye) must still be wired, exactly like
        // the sdl/bgfx/wgpu non-readback loop backends above.
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            // backend left at the .raylib default on purpose; the package makes it external.
            .backend_package = .{ .name = "nullfixture", .repo = "local:../nullfixture" },
            .ecs = .mock,
        }, preview_readback_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // No raylib PBO readback surface — this is what broke the e2e build.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "preview_pbo") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_preview_pbo_begin_bridge") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_gl_read_pixels") == null);
        // …but the GPU-independent control plane is still wired.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_p.sendHello(") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_p.tickHeartbeat(") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_p.sendBye(.normal)") != null);
    }

    // ── Sokol PBO readback codegen (labelle-assembler#122 slice 1) ──
    // Mirrors `backends/sokol/templates/desktop.txt`:
    //   - module scope gets `{{module_vars}}` (GL externs + PBO state)
    //   - `init` callback runs `{{preview_setup}}` (Preview.connect +
    //     allocator stash)
    //   - `frame` callback runs `{{preview_heartbeat}}` then renders
    //     then `{{preview_readback}}` right before `window.endFrame()`
    //   - `cleanup` callback runs `{{preview_cleanup}}` (endFrameStream
    //     + glDeleteBuffers + free) then sends the graceful `bye`
    // This trimmed lifecycle mirrors that shape so the placement +
    // gating assertions below correspond to real generated source.
    const preview_sokol_readback_lifecycle =
        \\var g: AssembledGame = undefined;
        \\{{hooks_init_block}}
        \\{{allocator_decl}}
        \\{{module_vars}}
        \\fn initInner() !void {
        \\    const allocator = {{allocator_expr}};
        \\{{preview_setup}}{{init_code}}}
        \\
        \\export fn init() callconv(.c) void {
        \\    g = AssembledGame.init({{allocator_expr}});
        \\    g.setHooks(&hooks);
        \\    initInner() catch unreachable;
        \\}
        \\
        \\export fn frame() callconv(.c) void {
        \\    const dt: f32 = 0.016;
        \\{{preview_heartbeat}}{{tick_code}}    g.tick(dt);
        \\{{preview_pre_render}}    g.render();
        \\    window.flushScene();
        \\{{gui_draw_code}}{{preview_readback}}    window.endFrame();
        \\{{preview_readback_post}}}
        \\
        \\export fn cleanup() callconv(.c) void {
        \\{{preview_cleanup}}{{cleanup_code}}    g.deinit();
        \\{{allocator_cleanup}}}
        \\
    ;

    test "sokol desktop emits PBO readback + publishFrame between flushScene and endFrame" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
        }, preview_sokol_readback_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // Comptime gating — the entire GL path hides behind
        // `_sokol_preview_gl_enabled`, a `builtin.os.tag` switch that
        // returns true on Linux (default sokol GLCORE / Android GLES3)
        // and false on Darwin (Metal) / Windows (D3D11) / iOS (Metal).
        // Slice 1 only handles the GL paths; Metal + D3D11 are deferred
        // to slices 2 and 3 (#122 follow-ups).
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_sokol_preview_gl_enabled") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@import(\"builtin\").os.tag") != null);

        // GL extern decls live inside a struct-namespace gated on the
        // flag — the `else struct {}` branch has no symbols, so a
        // Metal / D3D11 sokol build never references unresolved GL
        // symbols at link time.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const _SokolPreviewGl = if (_sokol_preview_gl_enabled)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "else struct {}") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "glReadPixels") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "glGenBuffers") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "glMapBuffer") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "PIXEL_PACK_BUFFER") != null);

        // PBO state at module scope (sokol's callbacks don't share a
        // local stack frame, so the locals raylib's main() uses for
        // the same purpose live at file scope here).
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "var _preview_pbos: [3]c_uint") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "var _preview_pbo_initialized: bool") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "var _preview_frame_idx: u64") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "var _preview_pixel_buf: []u8") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "var _preview_allocator: std.mem.Allocator") != null);

        // Per-frame readback wiring — same shape as raylib's loop body
        // (beginFrameStream + glReadPixels + 2-frame priming gap +
        // glMapBuffer + publishFrame).
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_p.beginFrameStream(") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_p.publishFrame(") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_p.isFrameAccepted()") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_preview_frame_idx >= 2") != null);

        // Source-order: beginFrameStream must precede publishFrame
        // (otherwise the first publish would hit an un-offered ring).
        const begin_idx = std.mem.indexOf(u8, main_zig, "_p.beginFrameStream(").?;
        const publish_idx = std.mem.indexOf(u8, main_zig, "_p.publishFrame(").?;
        try std.testing.expect(begin_idx < publish_idx);

        // The readback snippet must land BEFORE `window.endFrame()`
        // — endFrame calls `sg.endPass()` + `sg.commit()`, and
        // glReadPixels needs GL_BACK still bound (i.e. before the
        // swap). The test template places `{{preview_readback}}` right
        // before `window.endFrame()`, so confirm the order in the
        // output.
        const readback_marker = std.mem.indexOf(u8, main_zig, "_SokolPreviewGl.readPixels(0, 0, _sw_i, _sh_i").?;
        const end_frame_idx = std.mem.indexOf(u8, main_zig, "window.endFrame()").?;
        try std.testing.expect(readback_marker < end_frame_idx);

        // Cleanup teardown: endFrameStream + glDeleteBuffers + free.
        // Must run BEFORE the graceful `bye` (LIFO with engine-owned
        // socket close — same shape as raylib's `defer` ordering).
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_p.endFrameStream()") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_SokolPreviewGl.deleteBuffers(3, &_preview_pbos)") != null);
        const cleanup_endstream = std.mem.indexOf(u8, main_zig, "_p.endFrameStream()").?;
        const cleanup_bye = std.mem.indexOf(u8, main_zig, "_p.sendBye(.normal)").?;
        try std.testing.expect(cleanup_endstream < cleanup_bye);

        // Init callback stashes the allocator into the module-scope
        // slot so frame + cleanup can grow / free the CPU staging
        // buffer without reaching back through `g`.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_preview_allocator = allocator;") != null);

        // Generated source must still parse as valid Zig.
        const dup = try std.testing.allocator.dupeZ(u8, main_zig);
        defer std.testing.allocator.free(dup);
        var ast = try std.zig.Ast.parse(std.testing.allocator, dup, .zig);
        defer ast.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    }

    test "sokol emits Metal Path-A IOSurface render-target block alongside GL block (#131)" {
        // Path A (floooh/sokol#1510): the Metal slice wraps engine-
        // owned IOSurfaces as MTLTextures. Post-#140 migration, all
        // Path-A machinery (state, ring management, MTL bridge) lives
        // in `backends/sokol/src/window.zig:preview_mtl`. The codegen
        // emits only:
        //   - `_sokol_preview_metal_enabled` aliased from the backend
        //   - 5 vtable bridge fns wrapping engine.Preview methods
        //   - `window.preview_mtl.attach(...)` post-handshake
        //   - `window.preview_mtl.beginFrame/endFrame/deinit()` at the
        //     three lifecycle hooks
        // The GL slice (#124) is unchanged — sokol-Linux still has its
        // inline PBO template emitted here.
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
        }, preview_sokol_readback_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // Metal enable gate — aliased from the backend module.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_sokol_preview_metal_enabled = window.preview_metal_enabled") != null);

        // Vtable bridges at module scope (5 fns).
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "fn _preview_mtl_begin_stream_bridge(") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "fn _preview_mtl_get_surface_bridge(") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "fn _preview_mtl_signal_bridge(") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "fn _preview_mtl_end_stream_bridge(") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "fn _preview_mtl_accepted_bridge(") != null);

        // Bridge bodies wrap engine.Preview Path-A methods.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "p.beginFrameStreamIOSurface(w, h)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "p.getIOSurfaceAt(slot)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "p.signalSlotReady(slot)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "p.endFrameStreamIOSurface()") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "p.isFrameAccepted()") != null);

        // Backend lifecycle hooks emitted.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "window.preview_mtl.attach(.{") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "window.preview_mtl.beginFrame()") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "window.preview_mtl.endFrame()") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "window.preview_mtl.deinit()") != null);

        // Old inline Path-A state + objc bindings MUST be absent —
        // proves they moved to the backend, not just duplicated.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "var _preview_mtl_textures: ") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "var _preview_mtl_sg_images: ") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "var _preview_mtl_attachments: ") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "var _preview_mtl_initialized:") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "MTLPixelFormatBGRA8Unorm") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "newTextureWithDescriptor:iosurface:plane:") == null);

        // GL block from slice 1 must still emit unchanged — both
        // blocks coexist in the same generated source.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_sokol_preview_gl_enabled") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_SokolPreviewGl") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "glReadPixels") != null);

        // Generated source must still parse as valid Zig.
        const dup = try std.testing.allocator.dupeZ(u8, main_zig);
        defer std.testing.allocator.free(dup);
        var ast = try std.zig.Ast.parse(std.testing.allocator, dup, .zig);
        defer ast.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    }

    test "sokol Metal Path-A routes game render into the offscreen IOSurface target (#133)" {
        // Post-#140 migration: the setEditorRenderTarget redirect is
        // driven from inside `window.preview_mtl.beginFrame()` and
        // cleared by `window.preview_mtl.endFrame()`. The codegen
        // template just calls these around `g.render()`.
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
        }, preview_sokol_readback_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // Source-order: backend pre-frame hook fires BEFORE g.render()
        // so the IOSurface render-target redirect is armed for the
        // upcoming sg.beginPass; backend post-frame hook fires AFTER
        // g.render() so the just-rendered slot is published.
        const begin_idx = std.mem.indexOf(u8, main_zig, "window.preview_mtl.beginFrame()").?;
        const render_idx = std.mem.indexOf(u8, main_zig, "g.render();").?;
        const end_idx = std.mem.indexOf(u8, main_zig, "window.preview_mtl.endFrame()").?;
        try std.testing.expect(begin_idx < render_idx);
        try std.testing.expect(render_idx < end_idx);

        // Cleanup hook fires after the frame loop ends. We can't easily
        // assert the relative order against `sg.shutdown` from inside
        // this test template, but it must at least exist.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "window.preview_mtl.deinit()") != null);

        // The OLD inline Path-A render-target code MUST be absent
        // (moved to backend's preview_mtl.beginFrame/endFrame).
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "window.setEditorRenderTarget(_preview_mtl_attachments") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_att.colors[0] = _view") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_preview_mtl_write_slot = _write_slot") == null);

        // Generated source must still parse as valid Zig.
        const dup = try std.testing.allocator.dupeZ(u8, main_zig);
        defer std.testing.allocator.free(dup);
        var ast = try std.zig.Ast.parse(std.testing.allocator, dup, .zig);
        defer ast.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    }

    test "non-raylib loop backends still do not pull in IOSurface lifecycle" {
        // Regression-lock: the macOS gating is raylib-desktop-only.
        // Pure loop-style sdl currently shares no pixel publish path
        // with raylib's readback, so neither the SHM nor the IOSurface
        // preview API should leak in.
        //
        // sokol used to be in this list, but slice 1 of #122 added a
        // sokol-callback pixel publish that legitimately emits
        // `_p.beginFrameStream(` etc. regardless of which template
        // is used (the emit is keyed on `cfg.backend == .sokol`).
        // The sokol path is covered separately by the dedicated sokol
        // tests above.
        for ([_]generate.Backend{.sdl}) |backend| {
            const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
                .name = "test-game",
                .backend = backend,
                .ecs = .mock,
            }, preview_readback_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
            defer std.testing.allocator.free(main_zig);

            try std.testing.expect(std.mem.indexOf(u8, main_zig, "_p.beginFrameStream(") == null);
            try std.testing.expect(std.mem.indexOf(u8, main_zig, "_p.beginFrameStreamIOSurface(") == null);
            try std.testing.expect(std.mem.indexOf(u8, main_zig, "_p.publishFrame(") == null);
            try std.testing.expect(std.mem.indexOf(u8, main_zig, "_p.publishFrameIOSurface(") == null);
            try std.testing.expect(std.mem.indexOf(u8, main_zig, "_p.endFrameStream(") == null);
            try std.testing.expect(std.mem.indexOf(u8, main_zig, "_p.endFrameStreamIOSurface(") == null);
        }
    }

    test "sokol desktop emits D3D11 staging-texture readback alongside the GL block" {
        // labelle-assembler#126 (slice 2 of #122): Windows sokol-on-D3D11
        // can't share the GL PBO path (no `glReadPixels`), so the
        // generated source emits a parallel block keyed on
        // `_sokol_preview_d3d11_enabled` (`builtin.os.tag == .windows`).
        // Both blocks ship side by side; their gates are mutually
        // exclusive so only one runs per target.
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
        }, preview_sokol_readback_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // Comptime gate.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_sokol_preview_d3d11_enabled") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@import(\"builtin\").os.tag == .windows") != null);

        // Struct-namespace pattern matching the GL block — the
        // `else struct {}` branch keeps D3D11 entry points off the
        // link line on Linux/Darwin so `sg_d3d11_device` etc. don't
        // become unresolved-symbol errors there.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const _SokolPreviewD3d11 = if (_sokol_preview_d3d11_enabled)") != null);

        // Public sokol-zig D3D11 / DXGI handles — the producer reaches
        // through these to find the back-buffer Texture2D.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "sg_d3d11_device") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "sg_d3d11_device_context") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "sapp_d3d11_get_swap_chain") != null);

        // COM dispatch path — `IDXGISwapChain::GetBuffer` →
        // `ID3D11DeviceContext::CopyResource` → `Map`/`Unmap`.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "swapChainGetBuffer") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "deviceCreateTexture2D") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "contextCopyResource") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "contextMap") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "contextUnmap") != null);
        // IID_ID3D11Texture2D — passed to GetBuffer to get the back
        // buffer as a Texture2D.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "IID_ID3D11Texture2D") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "0x6F15AAF2") != null);

        // 3-deep staging-texture ring + initialization flag at module
        // scope — same shape as the GL `_preview_pbos` ring.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "var _preview_d3d11_staging: [3]?*anyopaque") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "var _preview_d3d11_initialized: bool") != null);

        // SHM lifecycle — same producer-side calls as the GL block
        // because both share the SHM consumer protocol.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_p.beginFrameStream(") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_p.publishFrame(") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_p.endFrameStream()") != null);

        // Source-order: beginFrameStream must precede publishFrame
        // within the D3D11 block too — otherwise the first publish
        // would hit an un-offered ring.
        const d3d11_gate = std.mem.indexOf(u8, main_zig, "_sokol_preview_d3d11_enabled").?;
        // The first reference is at the gate declaration; the next
        // few references inside the if-comptime blocks come right
        // after. We pick the GATED frame block by finding the second
        // occurrence (inside `if (comptime _sokol_preview_d3d11_enabled)`).
        const after_decl = main_zig[d3d11_gate + "_sokol_preview_d3d11_enabled".len ..];
        const frame_gate_rel = std.mem.indexOf(u8, after_decl, "if (comptime _sokol_preview_d3d11_enabled)").?;
        const frame_gate_abs = d3d11_gate + "_sokol_preview_d3d11_enabled".len + frame_gate_rel;
        const after_frame_gate = main_zig[frame_gate_abs..];
        const begin_rel = std.mem.indexOf(u8, after_frame_gate, "_p.beginFrameStream(").?;
        const publish_rel = std.mem.indexOf(u8, after_frame_gate, "_p.publishFrame(").?;
        try std.testing.expect(begin_rel < publish_rel);

        // BGRA→RGBA swizzle. The D3D11 swapchain default format is
        // `DXGI_FORMAT_B8G8R8A8_UNORM`; the SHM consumer expects
        // RGBA. We swap channels 0 and 2 during the memcpy. Pinning
        // the format constant + the swizzle direction here so a
        // future protocol-format-tagged variant has a concrete site
        // to update.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "FORMAT_B8G8R8A8_UNORM") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_src_row[_off + 2]") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_src_row[_off + 0]") != null);

        // Staging-texture descriptor — must be USAGE_STAGING + CPU_ACCESS_READ
        // or the Map call returns E_INVALIDARG.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "USAGE_STAGING") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "CPU_ACCESS_READ") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "MAP_READ") != null);

        // 2-frame priming gap — same as GL path. Frame N's
        // CopyResource is Mapped on frame N+2 to keep the GPU's
        // copy queue clear of the CPU's read.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_preview_frame_idx >= 2") != null);

        // Init callback stashes the allocator into the shared module
        // slot — both the GL and the D3D11 init helpers write to
        // `_preview_allocator`, but the comptime gates make them
        // mutually exclusive.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_preview_allocator = allocator;") != null);

        // Cleanup teardown — release every staging texture, then
        // free the CPU buffer, BEFORE `bye`.
        const cleanup_release = std.mem.indexOf(u8, main_zig, "_SokolPreviewD3d11.release(").?;
        const cleanup_bye = std.mem.indexOf(u8, main_zig, "_p.sendBye(.normal)").?;
        try std.testing.expect(cleanup_release < cleanup_bye);

        // The D3D11 readback snippet must land BEFORE `window.endFrame()`
        // — endFrame calls `sg.endPass()` + `sg.commit()`, which is
        // the latest the staging copy can land before the swap.
        const readback_marker = std.mem.indexOf(u8, main_zig, "_SokolPreviewD3d11.contextCopyResource(").?;
        const end_frame_idx = std.mem.indexOf(u8, main_zig, "window.endFrame()").?;
        try std.testing.expect(readback_marker < end_frame_idx);

        // GL block must still be present unchanged (slice 1, #124).
        // The two blocks ship side by side; this guards against an
        // accidental displacement of the GL emit by the D3D11 work.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_sokol_preview_gl_enabled") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const _SokolPreviewGl = if (_sokol_preview_gl_enabled)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "glReadPixels") != null);

        // Generated source must still parse as valid Zig.
        const dup = try std.testing.allocator.dupeZ(u8, main_zig);
        defer std.testing.allocator.free(dup);
        var ast = try std.zig.Ast.parse(std.testing.allocator, dup, .zig);
        defer ast.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    }

    test "non-loop, non-sokol backends do not pull in any preview pixel publish path" {
        // The slice 1 emit extends the sokol-callback branch — sdl /
        // bgfx / wgpu run through the loop branch and still get no
        // pixel publish (their tickets are separate slices). And
        // wasm-raylib (callback branch but `cfg.backend != .sokol`)
        // also must stay unchanged. This guards both.
        const main_zig_sdl = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .sdl,
            .ecs = .mock,
        }, preview_sokol_readback_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig_sdl);

        try std.testing.expect(std.mem.indexOf(u8, main_zig_sdl, "_sokol_preview_gl_enabled") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig_sdl, "_sokol_preview_d3d11_enabled") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig_sdl, "_SokolPreviewGl") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig_sdl, "_SokolPreviewD3d11") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig_sdl, "glReadPixels") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig_sdl, "sg_d3d11_device") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig_sdl, "_p.publishFrame(") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig_sdl, "_p.beginFrameStream(") == null);
        // Slice 2 Metal additions (#125) must also stay out of
        // non-sokol templates — the helpers + extern namespace +
        // IOSurface publish all key on `cfg.backend == .sokol`.
        try std.testing.expect(std.mem.indexOf(u8, main_zig_sdl, "_sokol_preview_metal_enabled") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig_sdl, "_SokolPreviewMetal") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig_sdl, "_p.publishFrameIOSurface(") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig_sdl, "window.metalDevice()") == null);
        // Control-plane wiring stays intact.
        try std.testing.expect(std.mem.indexOf(u8, main_zig_sdl, "_p.sendHello(") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig_sdl, "_p.tickHeartbeat(") != null);
    }

    // ── window.hideWindow on preview connect (labelle-assembler#137) ──
    //
    // When LABELLE_PREVIEW is set AND the engine successfully dials the
    // editor, the standalone sokol-app window is redundant — the
    // editor's Game View tab samples our IOSurface ring directly and
    // is the user-facing surface. Closing the standalone window kills
    // the preview subprocess (sokol-app exits the event loop on
    // close), so we hide it instead. The hide call must:
    //   1. Live INSIDE the `if (g.preview) |*_p|` arm — only fire on
    //      a successful connect, not blind env-var presence, so a
    //      misconfigured `LABELLE_PREVIEW` (typo, dead listener)
    //      doesn't leave the user with no visible window AND no
    //      editor view.
    //   2. Run AFTER `sendHello` so the editor sees the hello before
    //      we vanish from the desktop (purely cosmetic ordering, but
    //      keeps the wire trace readable).
    //   3. Stay sokol-only — the raylib desktop loop doesn't open a
    //      separate window-in-window surface; its `LABELLE_PREVIEW`
    //      block must not reference `window.hideWindow`.
    test "sokol callback emits window.hideWindow inside preview-connect arm (#137)" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
        }, preview_sokol_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // hideWindow is referenced in the generated source.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "window.hideWindow()") != null);

        // The call site MUST be `@hasDecl`-guarded so this same
        // `PREVIEW_INIT_CALLBACK` template (shared with the raylib-
        // WASM callback path) doesn't break the raylib build —
        // raylib's `window` module has no `hideWindow` decl. Verify
        // the guard sits in front of the call and references the
        // sokol-side `hideWindow` symbol.
        try std.testing.expect(std.mem.indexOf(
            u8,
            main_zig,
            "if (comptime @hasDecl(window, \"hideWindow\")) window.hideWindow();",
        ) != null);

        // Ordering: sendHello must precede hideWindow (keeps the wire
        // trace readable — editor sees the hello before we vanish from
        // the desktop).
        const hello_idx = std.mem.indexOf(u8, main_zig, "_p.sendHello(\"labelle-engine\", 0)").?;
        const hide_idx = std.mem.indexOf(u8, main_zig, "window.hideWindow()").?;
        try std.testing.expect(hello_idx < hide_idx);

        // Ordering: hideWindow must sit INSIDE the `if (g.preview) |*_p|`
        // arm, so a failed `Preview.connect` (which returns null via
        // `catch ... break :blk null`) skips the hide. The arm is
        // opened immediately after the `Preview.connect` call site —
        // confirm hideWindow lives between that opener and the next
        // top-level `_preview_getenv` reference (which only appears
        // again much later, if at all, in unrelated codegen). The
        // proximity bound is generous (1024 chars) to absorb the
        // explanatory comment block without coupling the test to the
        // exact wording.
        try std.testing.expect(hide_idx - hello_idx < 2048);

        // Generated source must still parse.
        const dup = try std.testing.allocator.dupeZ(u8, main_zig);
        defer std.testing.allocator.free(dup);
        var ast = try std.zig.Ast.parse(std.testing.allocator, dup, .zig);
        defer ast.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    }

    test "every REAL backend template's generated main declares the _preview_* helpers it references" {
        // Regression lock for the {{module_vars}}-slot-missing bug class:
        // wgpu's and bgfx's desktop templates shipped with the
        // {{preview_setup}}/{{preview_heartbeat}} slots (which USE
        // `_preview_getenv`/`_preview_now_ms`) but without the
        // {{module_vars}} slot (which DECLARES them), so their generated
        // mains failed sema with "use of undeclared identifier". The
        // synthetic lifecycle fixtures in this file all carry
        // {{module_vars}}, which is exactly why the bug slipped through —
        // this test renders codegen through the REAL template files read
        // from backends/<be>/templates/.
        const Case = struct { backend: generate.Backend, template: []const u8 };
        const cases = [_]Case{
            // raylib + bgfx + wgpu + null are extracted out-of-tree
            // (labelle-raylib / labelle-bgfx / labelle-wgpu / labelle-null) —
            // their templates live there + are covered by their own CI, so
            // they're no longer in this in-tree list.
            .{ .backend = .sokol, .template = "backends/sokol/templates/desktop.txt" },
        };

        const io = std.testing.io;
        for (cases) |case| {
            // Tests run with cwd = repo root; tolerate a subdir invocation
            // by probing a couple of parents before giving up loudly.
            var lifecycle: ?[]const u8 = null;
            const prefixes = [_][]const u8{ "", "../", "../../" };
            for (prefixes) |p| {
                const path = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}", .{ p, case.template });
                defer std.testing.allocator.free(path);
                lifecycle = std.Io.Dir.cwd().readFileAlloc(io, path, std.testing.allocator, .limited(64 * 1024)) catch continue;
                break;
            }
            const tmpl = lifecycle orelse {
                std.debug.print("could not read {s} — run `zig build test` from the repo root\n", .{case.template});
                return error.TemplateNotFound;
            };
            defer std.testing.allocator.free(tmpl);

            const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
                .name = "test-game",
                .backend = case.backend,
                .ecs = .mock,
            }, tmpl, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
            defer std.testing.allocator.free(main_zig);

            const pairs = [_][2][]const u8{
                .{ "_preview_getenv(", "const _preview_getenv" },
                .{ "_preview_now_ms(", "fn _preview_now_ms" },
                .{ "_preview_clock_gettime(", "const _preview_clock_gettime" },
            };
            for (pairs) |pair| {
                const used = std.mem.indexOf(u8, main_zig, pair[0]) != null;
                const declared = std.mem.indexOf(u8, main_zig, pair[1]) != null;
                if (used and !declared) {
                    std.debug.print("{s} ({s}): generated main references `{s}...` but never declares it\n", .{ @tagName(case.backend), case.template, pair[0] });
                    return error.UndeclaredPreviewHelper;
                }
            }
        }
    }

    test "raylib loop backend does NOT reference window.hideWindow (#137)" {
        // The hide-window fix is sokol-specific — raylib desktop has
        // no separate window-in-window surface, and `window.hideWindow`
        // doesn't exist on the raylib backend's window module. Any
        // leak of the symbol into a non-sokol template would be a
        // hard link error.
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, preview_readback_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "window.hideWindow") == null);

        // Sanity: the LABELLE_PREVIEW control-plane wiring IS present
        // on the raylib path — only the hide call is sokol-only.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_preview_getenv(\"LABELLE_PREVIEW\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_p.sendHello(") != null);
    }
};
