/// Sokol window backend — windowing lifecycle via sokol_app.
const std = @import("std");
const builtin = @import("builtin");
const sokol = @import("sokol");
const sapp = sokol.app;
const sg = sokol.gfx;
const sgl = sokol.gl;
const sglue = sokol.glue;
const slog = sokol.log;

// ──────────────────────────────────────────────────────────────────
// Headless preview mode (labelle-assembler#140 — no-window preview)
// ──────────────────────────────────────────────────────────────────
// When `LABELLE_PREVIEW` is set, the game runs without sokol-app: no
// NSWindow, no dock icon. We create an MTLDevice directly, hand it to
// sokol-gfx via a custom sg_environment, and drive the frame loop at
// ~60Hz. The Path-A IOSurface ring publishes frames to the gui's
// Game View consumer — that's the only visible surface.
//
// Public API below (initGfx, width, height, metalDevice, requestQuit,
// beginPass) branches internally on `headless_mode`, so the codegen
// needs zero changes.
var headless_mode: bool = false;
var headless_w: i32 = 0;
var headless_h: i32 = 0;
var headless_mtl_device: ?*anyopaque = null;
var headless_quit_requested: bool = false;

extern "c" fn MTLCreateSystemDefaultDevice() ?*anyopaque;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn nanosleep(rqtp: *const std.c.timespec, rmtp: ?*std.c.timespec) c_int;

/// Re-export `sokol.gfx` so the generated `main.zig` (which only depends
/// on `backend_window`, not directly on `sokol`) can reach sg.Image,
/// sg.View, sg.Attachments, sg.makeImage, sg.makeView, sg.destroyImage,
/// sg.destroyView, sg.ImageDesc, etc. Used by the Path-A IOSurface ring
/// the Play-in-Editor preview producer builds at module scope — every
/// member of the ring is an sg-flavoured handle, so without this re-
/// export the codegen would either need a parallel `sokol` dep on the
/// root module (cross-cutting concern) or duplicate the type defs.
pub const gfx_types = sokol.gfx;

pub const ConfigFlags = struct {
    window_hidden: bool = false,
};

/// Set config flags before initialization.
/// Note: sokol_app does not natively support hidden windows. This is a
/// no-op stub for API compatibility; the flag is stored but has no effect
/// on the sokol backend (sokol_app always shows the window).
pub fn setConfigFlags(_: ConfigFlags) void {}

/// sokol_gl pipeline with alpha blending enabled. The default sgl pipeline
/// has blend disabled, which makes atlas sprites render their transparent
/// pixels as opaque (the underlying layer doesn't show through). We create
/// this once in initGfx and load it on every beginFrame so all sgl draws —
/// textured sprites, rectangles, circles, text — get correct alpha blending.
var alpha_pipeline: sgl.Pipeline = .{};

pub fn initGfx() void {
    // Headless preview mode supplies its own MTLDevice; sglue.environment()
    // reads from sapp which isn't valid (sokol-app never ran).
    const env: sg.Environment = if (headless_mode) .{
        .defaults = .{
            .color_format = .BGRA8,
            .depth_format = .DEPTH_STENCIL,
            .sample_count = 1,
        },
        .metal = .{ .device = headless_mtl_device },
    } else sglue.environment();

    sg.setup(.{
        .environment = env,
        .logger = .{ .func = slog.func },
    });
    sgl.setup(.{
        .logger = .{ .func = slog.func },
    });
    alpha_pipeline = sgl.makePipeline(.{
        .colors = .{ .{ .blend = .{
            .enabled = true,
            .src_factor_rgb = .SRC_ALPHA,
            .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
            .src_factor_alpha = .ONE,
            .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
        } }, .{}, .{}, .{}, .{}, .{}, .{}, .{} },
    });
}

/// Screenshot capture — best-effort. The raylib backend uses raylib's
/// builtin `TakeScreenshot`, which reads the just-presented framebuffer
/// and picks the format from the extension. sokol-gfx has no equivalent
/// one-shot helper: a real implementation would have to drive a
/// per-backend pixel readback (Metal blit-encoder, GL `glReadPixels`,
/// D3D11 staging texture) plus a PNG/BMP encoder, all of which already
/// exist in scattered form in this backend (`preview_pbo`, `preview_mtl`,
/// `dr_wav` is audio-only) but are wired for the preview readback path.
///
/// For now the sokol template wires the call site exactly like raylib's
/// so labelle-cli#227 can ship the CLI flag + engine helper, with sokol
/// emitting a one-line warning instead of writing a file. Follow-up
/// ticket should reuse `preview_pbo` / `preview_mtl`'s readback ring
/// for a real implementation.
pub fn takeScreenshot(path: [:0]const u8) void {
    std.log.warn(
        "screenshot requested but not supported on sokol backend yet ({s})",
        .{path},
    );
}

/// Quiet-exit handler for the upstream sokol-gfx SIGSEGV in
/// `_sg_mtl_garbage_collect` during `sg_shutdown` (labelle-assembler#140).
/// Bug lives in sokol-gfx's deferred-release queue, not our cleanup.
/// By the time the signal fires the game has already published its
/// last frame to the editor consumer, so an immediate `_exit(0)` keeps
/// the gui's preview state machine in a clean disconnect instead of
/// surfacing a crash dump.
fn quietExitOnShutdownCrash(_: std.posix.SIG, _: *const std.posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    // _exit(2) bypasses atexit handlers — important because the
    // crash happens INSIDE sokol's teardown, and running more cleanup
    // would re-enter the broken state.
    std.c._exit(0);
}

pub fn shutdownGfx() void {
    sgl.destroyPipeline(alpha_pipeline);
    sgl.shutdown();

    // labelle-assembler#140 workaround — install the quiet-exit handler
    // ONLY on the Darwin/Metal path where the upstream crash reproduces.
    // Linux/Windows/etc. take the normal sg.shutdown path and crash
    // legitimately on any real bug.
    if (builtin.target.os.tag == .macos or builtin.target.os.tag == .ios) {
        var sa: std.posix.Sigaction = .{
            .handler = .{ .sigaction = quietExitOnShutdownCrash },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.SIGINFO,
        };
        std.posix.sigaction(std.posix.SIG.SEGV, &sa, null);
        std.posix.sigaction(std.posix.SIG.BUS, &sa, null);
        std.posix.sigaction(std.posix.SIG.ABRT, &sa, null);
    }

    sg.shutdown();
}

/// Request that the sokol_app event loop terminate on the next iteration.
/// Mirrors `rl.closeWindow` / `sdl.quit` — the generated frame callback
/// polls `g.isRunning()` and calls this when a script called `game.quit()`.
pub fn requestQuit() void {
    if (headless_mode) {
        headless_quit_requested = true;
        return;
    }
    sapp.requestQuit();
}

pub fn width() i32 {
    return if (headless_mode) headless_w else sapp.width();
}

pub fn height() i32 {
    return if (headless_mode) headless_h else sapp.height();
}

/// Duration of the last frame in seconds.
/// Use this for dt in the frame callback instead of a hardcoded value.
///
/// In headless preview mode sokol-app never ran, so `sapp.frameDuration()`
/// returns ~0 — which causes divide-by-zero or stalled physics in game
/// code that derives delta-time from this. `runHeadless` paces at ~60 Hz
/// via `nanosleep`, so 1/60 is the truthful answer there.
pub fn frameDuration() f64 {
    if (headless_mode) return 1.0 / 60.0;
    return sapp.frameDuration();
}

pub fn beginFrame() sg.PassAction {
    sgl.defaults();
    // sgl.defaults() resets to the default non-blended pipeline; load our
    // alpha-blended pipeline so sprites render transparency correctly.
    sgl.loadPipeline(alpha_pipeline);
    var pass_action: sg.PassAction = .{};
    pass_action.colors[0] = .{
        .load_action = .CLEAR,
        // Match the raylib backend's default clear color (30, 30, 35) so
        // projects render the same backdrop regardless of backend.
        .clear_value = .{ .r = 30.0 / 255.0, .g = 30.0 / 255.0, .b = 35.0 / 255.0, .a = 1.0 },
    };
    return pass_action;
}

/// Editor-mode override for the next `beginPass`. When non-null, `beginPass`
/// routes the game's render into these attachments (Path-A offscreen
/// IOSurface render target — labelle-assembler#133) instead of the
/// sokol_app swapchain. The override stays set across frames; the host
/// flips it on/off around each frame's render via `setEditorRenderTarget`
/// / `clearEditorRenderTarget`. Defaults to null so the standalone /
/// non-editor path renders to the swapchain as before.
var current_editor_render_target: ?sg.Attachments = null;

/// Route the next `beginPass` into these attachments instead of the
/// swapchain. The Path-A producer (Metal/IOSurface ring) populates one
/// `sg.Attachments` per ring slot during ring (re)negotiation, then on
/// each frame the host picks `_write_slot` and passes the corresponding
/// attachments through this shim before `g.render()`. The pass clears
/// to the same color the swapchain path uses.
pub fn setEditorRenderTarget(attachments: sg.Attachments) void {
    current_editor_render_target = attachments;
}

/// Clear the editor render-target override so the next `beginPass`
/// returns to the swapchain. Called after the host's frame body emits
/// `signalSlotReady` for the just-rendered slot — keeps the override
/// strictly one-frame scoped even if a later frame skips the
/// `setEditorRenderTarget` call (e.g. transient ring re-negotiation
/// or editor disconnect).
pub fn clearEditorRenderTarget() void {
    current_editor_render_target = null;
}

pub fn beginPass(pass_action: sg.PassAction) void {
    if (current_editor_render_target) |attachments| {
        sg.beginPass(.{ .action = pass_action, .attachments = attachments });
        return;
    }
    if (headless_mode) {
        // No swapchain in headless preview mode. Route the pass into a
        // small fallback offscreen attachments so the game's draws
        // complete (this happens for the very first frames before
        // preview_mtl arms its IOSurface ring + the editor accepts).
        sg.beginPass(.{ .action = pass_action, .attachments = headlessFallbackAttachments() });
        return;
    }
    sg.beginPass(.{ .action = pass_action, .swapchain = sglue.swapchain() });
}

// ── Headless fallback render target ──────────────────────────────
var headless_fallback_attachments: sg.Attachments = .{};
var headless_fallback_color_img: sg.Image = .{};
var headless_fallback_color_view: sg.View = .{};
var headless_fallback_depth_img: sg.Image = .{};
var headless_fallback_depth_view: sg.View = .{};

fn headlessFallbackAttachments() sg.Attachments {
    // sg.Attachments isn't a handle (no .id) so use the color-view's
    // id as the lazy-init sentinel.
    if (headless_fallback_color_view.id != 0) return headless_fallback_attachments;

    // Build everything in locals first; only commit to module-scope
    // statics when all four handles validate. If any creation fails
    // (pool exhaustion / driver error), return an empty
    // `sg.Attachments` and leave `headless_fallback_color_view.id == 0`
    // so the next call retries the lazy-init cleanly instead of
    // caching broken attachments forever.
    const color_img = sg.makeImage(.{
        .width = 16,
        .height = 16,
        .pixel_format = .BGRA8,
        .usage = .{ .color_attachment = true, .immutable = true },
    });
    if (color_img.id == 0) return .{};
    const color_view = sg.makeView(.{
        .color_attachment = .{ .image = color_img },
    });
    if (color_view.id == 0) {
        sg.destroyImage(color_img);
        return .{};
    }
    const depth_img = sg.makeImage(.{
        .width = 16,
        .height = 16,
        .pixel_format = .DEPTH_STENCIL,
        .usage = .{ .depth_stencil_attachment = true, .immutable = true },
    });
    if (depth_img.id == 0) {
        sg.destroyView(color_view);
        sg.destroyImage(color_img);
        return .{};
    }
    const depth_view = sg.makeView(.{
        .depth_stencil_attachment = .{ .image = depth_img },
    });
    if (depth_view.id == 0) {
        sg.destroyImage(depth_img);
        sg.destroyView(color_view);
        sg.destroyImage(color_img);
        return .{};
    }

    var att: sg.Attachments = .{};
    att.colors[0] = color_view;
    att.depth_stencil = depth_view;

    // All four handles valid — commit to module scope.
    headless_fallback_color_img = color_img;
    headless_fallback_color_view = color_view;
    headless_fallback_depth_img = depth_img;
    headless_fallback_depth_view = depth_view;
    headless_fallback_attachments = att;
    return att;
}

/// Flush queued sokol-gl primitives (sprites, gizmos, sgl-rendered text)
/// to the active sokol-gfx pass. The frame-loop template calls this
/// **between** scene rendering (`g.render()` / `g.renderGizmos()`) and
/// GUI rendering (`g.guiBegin()` / drawGui / `g.guiEnd()`), so sgl
/// primitives land in the framebuffer before any imgui draws are
/// emitted. The original `endFrame` flushed sgl AFTER `simgui.render()`
/// had already submitted the GUI's draw calls in the same pass — and
/// since draws are layered in submission order, the sprites painted on
/// top of the GUI and hid it entirely. See labelle-toolkit/labelle-imgui#4.
pub fn flushScene() void {
    sgl.draw();
}

pub fn endFrame() void {
    // No `sgl.draw()` here on purpose — `flushScene()` already drained
    // the queue between scene rendering and GUI rendering. Calling
    // `sgl.draw()` a second time would *re-submit* the same vertex /
    // command buffers (sokol-gl rewinds them on `sg_commit`, not on
    // `sgl_draw`), painting the sprites a second time on top of any
    // GUI submitted between the two flushes — which is exactly the
    // labelle-imgui#4 symptom this split fixes.
    sg.endPass();
    sg.commit();
}

/// Metal device pointer (MTLDevice*) for the Play-in-Editor preview's
/// macOS/iOS Path-A producer (labelle-assembler#131). Returns the same
/// device sokol acquires for the swapchain — safe to call any number
/// of times per frame. `null` on non-Metal builds and pre-init
/// (sapp not valid yet).
///
/// Path A wraps each IOSurface as an `MTLTexture` via
/// `[device newTextureWithDescriptor:iosurface:plane:]` — the device
/// pointer is the *only* sokol-side resource we still need. The
/// drawable accessor that the Path-B blit chain needed
/// (`sapp_metal_get_current_drawable`, lived on the
/// `feat/expose-cached-metal-drawable` sokol-zig fork) is gone from
/// the generated source. The fork itself is now vestigial — its
/// removal is a separate cleanup step.
pub fn metalDevice() ?*const anyopaque {
    if (comptime builtin.target.os.tag != .macos and builtin.target.os.tag != .ios) return null;
    if (headless_mode) return headless_mtl_device;
    return sapp.getEnvironment().metal.device;
}

/// Hide the sokol-app window from the screen (labelle-assembler#137).
///
/// Called by the generated `main.zig` once the Play-in-Editor preview
/// connection succeeds — the editor's Game View tab is the user-facing
/// surface in that mode, and the standalone sokol-app window is at
/// best redundant and at worst a foot-gun (closing it tears down the
/// whole preview subprocess).
///
/// Why "hide" not "never open": sokol-app insists on creating a real
/// platform window because the Metal swapchain (and the GL/D3D11
/// contexts) need an NSWindow / HWND attached at init time. The
/// cheapest reliable suppression is therefore post-creation — let
/// sokol bring the window up, then yank it off-screen before the user
/// ever sees it. `orderOut:` (macOS) / `ShowWindow(SW_HIDE)` (Win32)
/// are the platform-specific knobs for that; both leave the window
/// fully functional from a swapchain-lifecycle standpoint, just
/// invisible.
///
/// macOS-only for this slice. Windows D3D11 + Linux GL can land as
/// follow-ups; the call is a no-op on every other platform so callers
/// can invoke it unconditionally inside a comptime-agnostic block.
pub fn hideWindow() void {
    // Currently a no-op on macOS pending a way to suppress the standalone
    // sokol-app window without breaking Path-A's IOSurface pipeline.
    // Every approach tried in this session regressed something:
    //
    // - [NSWindow orderOut:]               → suspended sokol's frame
    //   callbacks (Metal display link), Game View went black.
    // - [NSApp setActivationPolicy:Accessory] → also stopped frame
    //   callbacks, Game View black.
    // - [NSWindow setAlphaValue:0.0]       → display link treated the
    //   alpha-0 window as occluded, frame callbacks stopped.
    // - [NSWindow setFrameOrigin: far off-screen] → window landed on a
    //   phantom screen with mismatched backing scale, the IOSurface
    //   dimensions stopped matching the MTLTexture descriptor and
    //   `_mtlValidateStrideTextureParameters` aborted in-frame.
    //
    // For now the standalone game window stays visible during
    // LABELLE_PREVIEW runs on macOS. Game View renders normally;
    // the user just has an extra window they can ignore or move
    // behind the editor. Real fix is tracked separately.
    _ = sapp;
}

/// The sokol app descriptor type — re-exported so callers don't need to
/// import sokol directly (used by mobile sokol_main return type).
pub const Desc = sapp.Desc;

// ──────────────────────────────────────────────────────────────────
// Preview-mode bridges (labelle-assembler#140 architecture rethink)
// ──────────────────────────────────────────────────────────────────
// These were previously emitted inline by the assembler codegen as
// `\\`-escaped Zig source in `PREVIEW_READBACK_HELPERS_METAL_SOKOL`.
// They're pure backend-specific Metal/objc runtime bindings — the
// generated `main.zig` shouldn't have known about libobjc, Metal
// pixel formats, MTLTextureDescriptor, or IOSurface texture
// wrapping. Moving them here is step one of the preview-decoupling:
// the codegen template now just aliases `window.PreviewMtlBridge`,
// and a future migration moves the per-frame state + frame logic
// across the same seam.

/// Comptime gate equivalent to the codegen's old `_sokol_preview_metal_enabled`.
/// The codegen `PREVIEW_READBACK_HELPERS_METAL_SOKOL` template now reads:
///   const _sokol_preview_metal_enabled = window.preview_metal_enabled;
/// so the truth-value lives in the backend module.
pub const preview_metal_enabled: bool = switch (builtin.target.os.tag) {
    .macos, .ios => true,
    else => false,
};

/// libobjc + Metal runtime bindings used by the macOS Path-A preview
/// producer (#131). Wraps an IOSurface as an `MTLTexture` so sokol-gfx
/// can render directly into shared editor-visible memory.
///
/// MTLPixelFormatBGRA8Unorm = 80 — matches the IOSurface's BGRA8 pixel
/// format the engine producer negotiates (preview_iosurface.kPixelFormat_BGRA8).
///
/// On non-Darwin this resolves to an empty struct so no libobjc / Metal
/// symbols leak into the link line.
pub const PreviewMtlBridge = if (preview_metal_enabled) struct {
    pub const MTLPixelFormatBGRA8Unorm: u64 = 80;
    pub const MTLStorageModeShared: u64 = 0;
    pub const MTLStorageModeManaged: u64 = 1;
    pub const MTLTextureUsageShaderRead: u64 = 0x01;
    pub const MTLTextureUsageRenderTarget: u64 = 0x04;
    pub const MTLTextureType2D: u64 = 2;

    // libobjc primitives. Each typed `objc_msgSend` variant is a separate
    // @extern with a concrete signature — the libobjc symbol is variadic
    // but every call site has a fixed shape.
    pub const sel_registerName = @extern(
        *const fn (name: [*:0]const u8) callconv(.c) ?*anyopaque,
        .{ .name = "sel_registerName" },
    );
    pub const objc_getClass = @extern(
        *const fn (name: [*:0]const u8) callconv(.c) ?*anyopaque,
        .{ .name = "objc_getClass" },
    );

    // msgSend(obj, sel) -> void  (for `release`)
    pub const msgSend_void = @extern(
        *const fn (obj: ?*anyopaque, sel: ?*anyopaque) callconv(.c) void,
        .{ .name = "objc_msgSend" },
    );
    // msgSend(cls, sel) -> id  (for `[MTLTextureDescriptor alloc]` style)
    pub const msgSend_id = @extern(
        *const fn (obj: ?*anyopaque, sel: ?*anyopaque) callconv(.c) ?*anyopaque,
        .{ .name = "objc_msgSend" },
    );
    // [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:width:height:mipmapped:]
    pub const msgSend_texdesc = @extern(
        *const fn (cls: ?*anyopaque, sel: ?*anyopaque, fmt: u64, w: usize, h: usize, mip: u8) callconv(.c) ?*anyopaque,
        .{ .name = "objc_msgSend" },
    );
    // single-arg u64 setters
    pub const msgSend_set_u64 = @extern(
        *const fn (obj: ?*anyopaque, sel: ?*anyopaque, v: u64) callconv(.c) void,
        .{ .name = "objc_msgSend" },
    );
    // [device newTextureWithDescriptor:iosurface:plane:]
    pub const msgSend_newtex_iosurf = @extern(
        *const fn (
            obj: ?*anyopaque,
            sel: ?*anyopaque,
            desc: ?*anyopaque,
            iosurface: ?*anyopaque,
            plane: usize,
        ) callconv(.c) ?*anyopaque,
        .{ .name = "objc_msgSend" },
    );

    // Selector cache — looked up lazily on first frame.
    pub var sel_release: ?*anyopaque = null;
    pub var sel_setStorageMode: ?*anyopaque = null;
    pub var sel_setUsage: ?*anyopaque = null;
    pub var sel_texDesc: ?*anyopaque = null;
    pub var sel_newTextureWithDescriptorIOSurfacePlane: ?*anyopaque = null;
    pub var cls_MTLTextureDescriptor: ?*anyopaque = null;

    pub fn loadSelectors() void {
        if (sel_release != null) return;
        sel_release = sel_registerName("release");
        sel_setStorageMode = sel_registerName("setStorageMode:");
        sel_setUsage = sel_registerName("setUsage:");
        sel_texDesc = sel_registerName(
            "texture2DDescriptorWithPixelFormat:width:height:mipmapped:",
        );
        sel_newTextureWithDescriptorIOSurfacePlane = sel_registerName(
            "newTextureWithDescriptor:iosurface:plane:",
        );
        cls_MTLTextureDescriptor = objc_getClass("MTLTextureDescriptor");
    }

    /// Wrap `iosurface` as an `MTLTexture` whose backing store is the
    /// surface bytes. Width/height/format must match the IOSurface.
    /// Usage: ShaderRead | RenderTarget. Returns null on alloc failure.
    pub fn createIOSurfaceTexture(
        device: ?*anyopaque,
        iosurface: ?*anyopaque,
        w: u32,
        h: u32,
    ) ?*anyopaque {
        const cls = cls_MTLTextureDescriptor orelse return null;
        const desc = msgSend_texdesc(
            cls,
            sel_texDesc,
            MTLPixelFormatBGRA8Unorm,
            @intCast(w),
            @intCast(h),
            0,
        ) orelse return null;
        msgSend_set_u64(desc, sel_setStorageMode, MTLStorageModeShared);
        msgSend_set_u64(desc, sel_setUsage, MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget);
        return msgSend_newtex_iosurf(
            device,
            sel_newTextureWithDescriptorIOSurfacePlane,
            desc,
            iosurface,
            0,
        );
    }

    pub fn release(obj: ?*anyopaque) void {
        if (obj) |o| msgSend_void(o, sel_release);
    }
} else struct {};

// ──────────────────────────────────────────────────────────────────
// Preview-mode Path-A state + lifecycle (labelle-assembler#140 Phase B)
// ──────────────────────────────────────────────────────────────────
// Phase A moved the libobjc/Metal bindings (PreviewMtlBridge) into
// this module. Phase B moves the per-frame ring management, the
// associated module-scope state, and the cleanup teardown.
//
// To avoid an engine dependency on this backend module (and the
// resulting type-instance ambiguity in the build graph), the
// codegen passes engine.Preview's relevant methods through this
// vtable. The backend module never sees an `engine.Preview` type.

pub const PreviewIOSurfaceVtable = struct {
    /// Opaque pointer to the host's `engine.Preview` instance. The
    /// backend never dereferences it; passes it back verbatim.
    ctx: *anyopaque,
    beginStream: *const fn (ctx: *anyopaque, w: u32, h: u32) anyerror!void,
    getSurfaceAt: *const fn (ctx: *anyopaque, slot: u32) ?*anyopaque,
    signalSlotReady: *const fn (ctx: *anyopaque, slot: u32) anyerror!void,
    endStream: *const fn (ctx: *anyopaque) void,
    isFrameAccepted: *const fn (ctx: *anyopaque) bool,
};

/// Path-A state + frame/cleanup hooks. The codegen calls these from
/// init/frame/cleanup callbacks. All state lives here; the generated
/// main.zig no longer carries `_preview_mtl_*` vars or the
/// ring-management block.
pub const preview_mtl = if (preview_metal_enabled) struct {
    pub const RING_MAX: u32 = 8;
    var initialized: bool = false;
    var ring_size: u32 = 0;
    var textures: [RING_MAX]?*anyopaque = [_]?*anyopaque{null} ** RING_MAX;
    var sg_images: [RING_MAX]sg.Image = [_]sg.Image{.{}} ** RING_MAX;
    var views: [RING_MAX]sg.View = [_]sg.View{.{}} ** RING_MAX;
    var attachments: [RING_MAX]sg.Attachments = [_]sg.Attachments{.{}} ** RING_MAX;
    var depth_img: sg.Image = .{};
    var depth_view: sg.View = .{};
    var target_active: bool = false;
    var write_slot: u32 = 0;
    var last_w: u32 = 0;
    var last_h: u32 = 0;
    var vt: ?PreviewIOSurfaceVtable = null;

    /// Wire the engine.Preview vtable. Called once after the gui's
    /// preview handshake succeeds, before the first frame.
    pub fn attach(vtable: PreviewIOSurfaceVtable) void {
        vt = vtable;
    }

    /// Pre-render hook. Negotiates the ring with the editor on resize,
    /// picks the next write slot, redirects the next `beginPass` into
    /// the offscreen IOSurface render target via `setEditorRenderTarget`.
    /// No-op if the editor hasn't accepted the frame stream yet.
    pub fn beginFrame() void {
        const vtable = vt orelse return;

        // Use width()/height() wrappers so headless mode returns the
        // configured dims (sapp isn't running in headless).
        const sw_i = width();
        const sh_i = height();
        if (sw_i <= 0 or sh_i <= 0) return;
        const sw: u32 = @intCast(sw_i);
        const sh: u32 = @intCast(sh_i);

        const device = @as(?*anyopaque, @constCast(metalDevice())) orelse return;
        PreviewMtlBridge.loadSelectors();

        if (!initialized or sw != last_w or sh != last_h) {
            // Tear down any prior ring before reallocating.
            if (initialized) {
                var i: u32 = 0;
                while (i < ring_size) : (i += 1) {
                    if (views[i].id != 0) {
                        sg.destroyView(views[i]);
                        views[i] = .{};
                    }
                    attachments[i] = .{};
                    // Order matters: destroy the sokol image first (it
                    // holds an internal reference to the MTLTexture but
                    // does NOT retain it), then release the MTLTexture.
                    if (sg_images[i].id != 0) {
                        sg.destroyImage(sg_images[i]);
                        sg_images[i] = .{};
                    }
                    if (textures[i]) |t| {
                        PreviewMtlBridge.release(t);
                        textures[i] = null;
                    }
                }
                initialized = false;
            }

            vtable.beginStream(vtable.ctx, sw, sh) catch return;

            // (Re)alloc shared depth-stencil image.
            if (depth_view.id != 0) {
                sg.destroyView(depth_view);
                depth_view = .{};
            }
            if (depth_img.id != 0) {
                sg.destroyImage(depth_img);
                depth_img = .{};
            }
            depth_img = sg.makeImage(.{
                .width = @intCast(sw),
                .height = @intCast(sh),
                .pixel_format = .DEPTH_STENCIL,
                .usage = .{ .depth_stencil_attachment = true, .immutable = true },
            });
            if (depth_img.id == 0) return;
            depth_view = sg.makeView(.{
                .depth_stencil_attachment = .{ .image = depth_img },
            });
            if (depth_view.id == 0) return;

            // Allocate ring slots (up to RING_MAX) until we hit the first
            // null IOSurface — the engine's producer maintains its own
            // ring size (default 3) and exposes slots via `getSurfaceAt`.
            var alloc_ok = true;
            var slot: u32 = 0;
            while (slot < RING_MAX) : (slot += 1) {
                const iosurf = vtable.getSurfaceAt(vtable.ctx, slot) orelse break;
                const mtl_tex = PreviewMtlBridge.createIOSurfaceTexture(device, iosurf, sw, sh) orelse {
                    alloc_ok = false;
                    break;
                };
                textures[slot] = mtl_tex;
                var desc: sg.ImageDesc = .{
                    .width = @intCast(sw),
                    .height = @intCast(sh),
                    .pixel_format = .BGRA8,
                    .usage = .{ .color_attachment = true, .immutable = true },
                };
                desc.mtl_textures[0] = @ptrCast(mtl_tex);
                desc.mtl_textures[1] = @ptrCast(mtl_tex);
                const img = sg.makeImage(desc);
                if (img.id == 0) {
                    alloc_ok = false;
                    break;
                }
                sg_images[slot] = img;
                const view = sg.makeView(.{
                    .color_attachment = .{ .image = img },
                });
                if (view.id == 0) {
                    alloc_ok = false;
                    break;
                }
                views[slot] = view;
                var att: sg.Attachments = .{};
                att.colors[0] = view;
                att.depth_stencil = depth_view;
                attachments[slot] = att;
            }

            if (!alloc_ok) {
                // Roll back partial ring; reset state so next attempt is clean.
                // Order matters: destroy the sokol image first (it holds an
                // internal reference to the MTLTexture but does NOT retain
                // it), then release the MTLTexture.
                var i: u32 = 0;
                while (i <= slot and i < RING_MAX) : (i += 1) {
                    if (views[i].id != 0) {
                        sg.destroyView(views[i]);
                        views[i] = .{};
                    }
                    attachments[i] = .{};
                    if (sg_images[i].id != 0) {
                        sg.destroyImage(sg_images[i]);
                        sg_images[i] = .{};
                    }
                    if (textures[i]) |t| {
                        PreviewMtlBridge.release(t);
                        textures[i] = null;
                    }
                }
                return;
            }

            ring_size = slot;
            initialized = true;
            last_w = sw;
            last_h = sh;
            write_slot = 0;
        }

        if (!vtable.isFrameAccepted(vtable.ctx)) return;
        if (ring_size == 0) return;

        setEditorRenderTarget(attachments[write_slot]);
        target_active = true;
    }

    /// Post-render hook. Signals the just-written slot to the editor
    /// and clears the render-target redirect. No-op if `beginFrame`
    /// didn't activate a target this frame.
    pub fn endFrame() void {
        const vtable = vt orelse return;
        if (!target_active) return;
        vtable.signalSlotReady(vtable.ctx, write_slot) catch {};
        clearEditorRenderTarget();
        target_active = false;
        write_slot = (write_slot + 1) % ring_size;
    }

    /// Cleanup hook. Destroys all sokol resources + MTLTextures + the
    /// shared depth attachments, then asks the engine to tear down
    /// the IOSurface ring.
    pub fn deinit() void {
        const vtable_opt = vt;
        clearEditorRenderTarget();
        var i: u32 = 0;
        while (i < ring_size) : (i += 1) {
            if (views[i].id != 0) {
                sg.destroyView(views[i]);
                views[i] = .{};
            }
            attachments[i] = .{};
            // Order matters: destroy the sokol image first (it holds an
            // internal reference to the MTLTexture but does NOT retain it),
            // then release the MTLTexture. Reversing the order leaves
            // sg_image pointing at freed Metal memory.
            if (sg_images[i].id != 0) {
                sg.destroyImage(sg_images[i]);
                sg_images[i] = .{};
            }
            if (textures[i]) |t| {
                PreviewMtlBridge.release(t);
                textures[i] = null;
            }
        }
        if (depth_view.id != 0) {
            sg.destroyView(depth_view);
            depth_view = .{};
        }
        if (depth_img.id != 0) {
            sg.destroyImage(depth_img);
            depth_img = .{};
        }
        ring_size = 0;
        initialized = false;
        target_active = false;
        if (vtable_opt) |vtable| vtable.endStream(vtable.ctx);
    }
} else struct {
    pub fn attach(_: PreviewIOSurfaceVtable) void {}
    pub fn beginFrame() void {}
    pub fn endFrame() void {}
    pub fn deinit() void {}
};

/// Build a sokol app descriptor without starting the event loop.
/// Used on mobile targets where sokol calls sokol_main() and reads its
/// return value as sapp_desc — the host must NOT call sapp_run() itself.
pub fn makeDesc(desc: struct {
    init_cb: *const fn () callconv(.c) void,
    frame_cb: *const fn () callconv(.c) void,
    cleanup_cb: *const fn () callconv(.c) void,
    event_cb: ?*const fn ([*c]const sapp.Event) callconv(.c) void = null,
    w: i32 = 800,
    h: i32 = 600,
    title: [:0]const u8 = "LaBelle v2",
}) sapp.Desc {
    // Android emulators typically support GLES 3.0 but not 3.1.
    // Sokol defaults to 3.1 on Android, which causes EGL_BAD_CONFIG on emulators.
    // Request 3.0 explicitly so the app works on both real devices and emulators.
    // std.Target.isAndroid() is not available in Zig 0.15.2; check ABI directly.
    // .android covers arm64/x86_64; .androideabi covers arm/x86.
    const is_android = comptime builtin.target.abi == .android or
        builtin.target.abi == .androideabi;
    return .{
        .init_cb = desc.init_cb,
        .frame_cb = desc.frame_cb,
        .cleanup_cb = desc.cleanup_cb,
        .event_cb = desc.event_cb orelse null,
        .width = desc.w,
        .height = desc.h,
        .window_title = desc.title,
        .gl = if (is_android) .{ .major_version = 3, .minor_version = 0 } else .{},
        .high_dpi = true,
        .logger = .{ .func = slog.func },
    };
}

/// Run the sokol application loop with callbacks. Forwards each field
/// explicitly because Zig treats `run`'s anon-struct parameter and
/// `makeDesc`'s anon-struct parameter as distinct types — passing one
/// to the other directly would fail to compile.
pub fn run(desc: struct {
    init_cb: *const fn () callconv(.c) void,
    frame_cb: *const fn () callconv(.c) void,
    cleanup_cb: *const fn () callconv(.c) void,
    event_cb: ?*const fn ([*c]const sapp.Event) callconv(.c) void = null,
    w: i32 = 800,
    h: i32 = 600,
    title: [:0]const u8 = "LaBelle v2",
}) void {
    // Headless preview branch — when LABELLE_PREVIEW is set on Darwin,
    // skip sokol-app entirely (no NSWindow, no dock icon) and drive
    // sokol-gfx ourselves against a manually-acquired MTLDevice. The
    // Path-A IOSurface ring (preview_mtl) is the only visible surface.
    const is_darwin = builtin.target.os.tag == .macos or builtin.target.os.tag == .ios;
    if (is_darwin) {
        if (getenv("LABELLE_PREVIEW")) |raw| {
            const env_val = std.mem.span(raw);
            if (env_val.len > 0) {
                runHeadless(.{
                    .init_cb = desc.init_cb,
                    .frame_cb = desc.frame_cb,
                    .cleanup_cb = desc.cleanup_cb,
                    .w = desc.w,
                    .h = desc.h,
                });
                return;
            }
        }
    }

    sapp.run(makeDesc(.{
        .init_cb = desc.init_cb,
        .frame_cb = desc.frame_cb,
        .cleanup_cb = desc.cleanup_cb,
        .event_cb = desc.event_cb,
        .w = desc.w,
        .h = desc.h,
        .title = desc.title,
    }));
}

/// Run the game without sokol-app. Creates an MTLDevice, lets the game
/// init sokol-gfx against it (via `initGfx`'s headless branch), drives
/// a ~60 Hz frame loop. Darwin-only — `MTLCreateSystemDefaultDevice` is
/// the entry point. Headless preview only path.
fn runHeadless(desc: struct {
    init_cb: *const fn () callconv(.c) void,
    frame_cb: *const fn () callconv(.c) void,
    cleanup_cb: *const fn () callconv(.c) void,
    w: i32 = 800,
    h: i32 = 600,
}) void {
    const device = MTLCreateSystemDefaultDevice() orelse {
        std.debug.print("labelle: runHeadless: MTLCreateSystemDefaultDevice returned null; aborting preview.\n", .{});
        return;
    };

    headless_mode = true;
    headless_mtl_device = device;
    headless_w = desc.w;
    headless_h = desc.h;
    headless_quit_requested = false;
    defer {
        headless_mode = false;
        headless_mtl_device = null;
    }

    desc.init_cb();
    defer desc.cleanup_cb();

    // ~60 Hz frame loop via libc nanosleep (Zig 0.16 moved std.Thread.sleep
    // to an Io-context API we don't have here).
    const frame_ns: c_long = @intCast(std.time.ns_per_s / 60);
    while (!headless_quit_requested) {
        desc.frame_cb();
        const ts = std.c.timespec{ .sec = 0, .nsec = frame_ns };
        _ = nanosleep(&ts, null);
    }
}
