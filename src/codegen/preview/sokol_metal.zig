//! Sokol Metal/IOSurface readback snippets (labelle-assembler#131/#133,
//! Path A). Extracted from `preview.zig` (behavior-preserving).

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
