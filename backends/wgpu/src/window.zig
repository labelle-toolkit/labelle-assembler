/// WebGPU window backend — GLFW windowing + the wgpu render submitter.
///
/// The CPU side of rendering lives in gfx.zig (NDC vertex batching); this
/// file owns the GPU spine: instance → surface (Win32 HWND) → adapter →
/// device/queue → surface configure, and the per-frame acquire → upload →
/// render-pass → submit → present that drains gfx's shape + sprite batches.
/// The batch vertices are already NDC, so both pipelines are passthrough
/// WGSL modules with no projection uniform. Shapes draw first, then sprites
/// on top (matching draw-call submission order); the sprite path samples a
/// bound texture_2d and multiplies by the per-vertex color. Text atlases
/// stay TODO — HUD text routes through gfx's bitmap-font glyph rects in the
/// shape batch.
const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("zglfw");
const wgpu = @import("wgpu");
const gfx = @import("gfx");

pub const ConfigFlags = struct {
    window_hidden: bool = false,
};

/// The current render-surface dimensions, in PHYSICAL framebuffer pixels.
///
/// On a HiDPI/Retina display the GLFW framebuffer is larger than the logical
/// window size (e.g. 1600x1200 for a logical 800x600 window at 2x). We render
/// the wgpu swapchain at this physical size for crisp output, and feed it to
/// `gfx.setScreenSize` so the design canvas aspect-fits onto the real surface.
/// Seeded from `getFramebufferSize()` at window creation and reconciled every
/// frame by `ensureSurface()` (DPI move / resize / fullscreen toggle).
var screen_w: i32 = 800;
var screen_h: i32 = 600;
var glfw_window: ?*glfw.Window = null;
var target_fps_val: i32 = 60;
var window_hidden: bool = false;
/// Latched by `requestQuit()` and OR'd into `windowShouldClose`/`shouldQuit`
/// (GLFW also has its own close flag; this covers a programmatic engine quit).
var quit_requested: bool = false;
/// Previous `glfw.getTime()` reading, for `frameDuration()`.
var last_frame_time: f64 = 0;
/// Windowed-mode geometry, captured the moment we go fullscreen so
/// `setFullscreen(false)` restores the window to the same place + size
/// (GLFW's `setMonitor` needs explicit windowed coords on the way back).
var windowed_x: i32 = 0;
var windowed_y: i32 = 0;
var windowed_w: i32 = 800;
var windowed_h: i32 = 600;

pub fn setConfigFlags(flags: ConfigFlags) void {
    window_hidden = flags.window_hidden;
}

/// The physical framebuffer size of the render surface. On a Retina/HiDPI
/// display GLFW's framebuffer is larger than the logical window size (e.g.
/// 2x), and it's the size the wgpu swapchain must match for crisp rendering.
/// Returns the cached `screen_w/h` before the window exists.
fn framebufferSize() [2]i32 {
    if (glfw_window) |win| {
        const fb = win.getFramebufferSize();
        return .{ @intCast(fb[0]), @intCast(fb[1]) };
    }
    return .{ screen_w, screen_h };
}

/// Reconcile the wgpu surface with the current physical framebuffer size.
///
/// Called once per frame from `beginDrawing`. The expensive part — the wgpu
/// surface reconfigure — only runs when the framebuffer actually changed (a
/// DPI move, resize, or fullscreen toggle), `> 0`-guarded to skip minimized
/// windows. But `gfx.setScreenSize` is re-asserted EVERY frame: it's cheap,
/// and it keeps gfx's physical dimensions authoritative even if some other
/// code (an example main, a future codegen path) sets gfx's size to
/// something else mid-frame — otherwise gfx could drift to logical size
/// while the swapchain stays physical, breaking aspect-fit + `screenToDesign`
/// input. Mirrors the bgfx backend's per-frame `ensureSurface`.
fn ensureSurface() void {
    const fb = framebufferSize();
    if (fb[0] <= 0 or fb[1] <= 0) return; // minimized — nothing valid to apply
    if (fb[0] != screen_w or fb[1] != screen_h) {
        screen_w = fb[0];
        screen_h = fb[1];
        if (gpu_ready) {
            if (surface) |s| {
                if (device) |dev| {
                    s.configure(&wgpu.SurfaceConfiguration{
                        .device = dev,
                        .format = .bgra8_unorm,
                        .width = @intCast(screen_w),
                        .height = @intCast(screen_h),
                    });
                }
            }
        }
    }
    // Re-assert gfx's physical size every frame (cheap), so it can't drift.
    gfx.setScreenSize(screen_w, screen_h);
}

// ── GPU state ───────────────────────────────────────────────────────────

const ShapeVertex = extern struct { position: [2]f32, color_packed: u32 };
// Sprite vertex layout is owned by gfx.zig (the batch producer); alias it so
// the GPU-side stride / attribute offsets stay in lockstep with the CPU side.
const SpriteVertex = gfx.SpriteVertex;

var gpu_ready = false;
/// Whether the adapter advertised — and the device was created with — the
/// `texture_compression_astc` feature (#341). Gates `getOrCreateGpuTexture`'s
/// compressed (ASTC) path: when false, ASTC slots can't be uploaded (creating
/// an ASTC texture would fail), so they're skipped with a one-time warning.
var astc_supported = false;
var astc_unsupported_warned = false;
var io_threaded: ?std.Io.Threaded = null;
var instance: ?*wgpu.Instance = null;
var surface: ?*wgpu.Surface = null;
var device: ?*wgpu.Device = null;
var queue: ?*wgpu.Queue = null;
var shape_pipeline: ?*wgpu.RenderPipeline = null;
var vertex_buffer: ?*wgpu.Buffer = null;
var index_buffer: ?*wgpu.Buffer = null;
var clear_color = wgpu.Color{ .r = 0.96, .g = 0.96, .b = 0.96, .a = 1.0 };

// Sprite (textured-quad) GPU state. The texture bind group layout (binding
// 1 = texture_2d, binding 2 = sampler) is shared by every per-texture bind
// group; binding 0 is unused so the sprite shader's group layout matches the
// shape shader convention (kept simple — no uniform buffer since verts are
// already NDC).
var sprite_pipeline: ?*wgpu.RenderPipeline = null;
var sprite_vertex_buffer: ?*wgpu.Buffer = null;
var sprite_index_buffer: ?*wgpu.Buffer = null;
var sprite_bind_group_layout: ?*wgpu.BindGroupLayout = null;
var sprite_sampler: ?*wgpu.Sampler = null;

const MAX_VERTEX_BYTES: u64 = 16384 * @sizeOf(ShapeVertex);
const MAX_INDEX_BYTES: u64 = 32768 * @sizeOf(u32);
const MAX_SPRITE_VERTEX_BYTES: u64 = 8192 * @sizeOf(SpriteVertex);
const MAX_SPRITE_INDEX_BYTES: u64 = 16384 * @sizeOf(u32);

// ── GPU texture handle table ─────────────────────────────────────────────
// Maps a gfx texture id → its uploaded wgpu texture / view / bind group.
// Textures are created lazily on first draw (gfx loads pixels on a worker
// thread before the GPU may be ready), so this table is populated from
// submitFrame on the main/GL thread.
const MAX_GPU_TEXTURES = 256;
const GpuTexture = struct {
    texture: *wgpu.Texture,
    view: *wgpu.TextureView,
    bind_group: *wgpu.BindGroup,
};
var gpu_textures: [MAX_GPU_TEXTURES]?GpuTexture = [_]?GpuTexture{null} ** MAX_GPU_TEXTURES;

extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;

/// Passthrough shaders: gfx.zig batches vertices pre-transformed to NDC,
/// so no projection uniform is needed. Color arrives packed ABGR.
const shape_wgsl =
    \\struct VsOut {
    \\    @builtin(position) pos: vec4<f32>,
    \\    @location(0) color: vec4<f32>,
    \\};
    \\
    \\@vertex
    \\fn vs_main(@location(0) position: vec2<f32>, @location(1) color_packed: u32) -> VsOut {
    \\    var out: VsOut;
    \\    out.pos = vec4<f32>(position, 0.0, 1.0);
    \\    out.color = vec4<f32>(
    \\        f32(color_packed & 0xFFu) / 255.0,
    \\        f32((color_packed >> 8u) & 0xFFu) / 255.0,
    \\        f32((color_packed >> 16u) & 0xFFu) / 255.0,
    \\        f32((color_packed >> 24u) & 0xFFu) / 255.0,
    \\    );
    \\    return out;
    \\}
    \\
    \\@fragment
    \\fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    \\    return in.color;
    \\}
;

/// Textured-quad shaders. Like the shape module, vertices arrive pre-baked to
/// NDC so there is no projection uniform. The fragment stage samples the bound
/// texture and modulates by the unpacked ABGR vertex color (tint). Binding 0
/// is intentionally empty so the bind group layout's slot 0 stays unused,
/// keeping a single-group convention.
const sprite_wgsl =
    \\struct VsOut {
    \\    @builtin(position) pos: vec4<f32>,
    \\    @location(0) uv: vec2<f32>,
    \\    @location(1) color: vec4<f32>,
    \\};
    \\
    \\@vertex
    \\fn vs_main(@location(0) position: vec2<f32>, @location(1) uv: vec2<f32>, @location(2) color_packed: u32) -> VsOut {
    \\    var out: VsOut;
    \\    out.pos = vec4<f32>(position, 0.0, 1.0);
    \\    out.uv = uv;
    \\    out.color = vec4<f32>(
    \\        f32(color_packed & 0xFFu) / 255.0,
    \\        f32((color_packed >> 8u) & 0xFFu) / 255.0,
    \\        f32((color_packed >> 16u) & 0xFFu) / 255.0,
    \\        f32((color_packed >> 24u) & 0xFFu) / 255.0,
    \\    );
    \\    return out;
    \\}
    \\
    \\@group(0) @binding(1) var t_diffuse: texture_2d<f32>;
    \\@group(0) @binding(2) var s_diffuse: sampler;
    \\
    \\@fragment
    \\fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    \\    return textureSample(t_diffuse, s_diffuse, in.uv) * in.color;
    \\}
;

const log = std.log.scoped(.wgpu_window);

// ── Apple platform surface (Cocoa NSWindow → CAMetalLayer) ───────────────
// wgpu-native wants a CAMetalLayer to back the surface on macOS/iOS. GLFW
// gives us the NSWindow; we attach a fresh CAMetalLayer to its content view
// via the Objective-C runtime (no objc headers needed — three msgSends).
// Symbols resolve through the Foundation/QuartzCore frameworks the consuming
// executable links.
const ObjcId = ?*anyopaque;
extern "c" fn objc_getClass(name: [*:0]const u8) ObjcId;
extern "c" fn sel_registerName(name: [*:0]const u8) ?*anyopaque;
extern "c" fn objc_msgSend() void;

fn attachMetalLayer(nswindow: *anyopaque) ?*anyopaque {
    // objc_msgSend must be called through a prototype matching each message's
    // exact ABI (arm64 has no generic variadic form), so cast per signature.
    const msgId = @as(*const fn (ObjcId, ?*anyopaque) callconv(.c) ObjcId, @ptrCast(&objc_msgSend));
    const msgSetBool = @as(*const fn (ObjcId, ?*anyopaque, i8) callconv(.c) void, @ptrCast(&objc_msgSend));
    const msgSetId = @as(*const fn (ObjcId, ?*anyopaque, ObjcId) callconv(.c) void, @ptrCast(&objc_msgSend));

    const metal_class = objc_getClass("CAMetalLayer") orelse return null;
    const layer = msgId(metal_class, sel_registerName("layer")) orelse return null; // +[CAMetalLayer layer]

    const content_view = msgId(nswindow, sel_registerName("contentView")) orelse return null;
    msgSetBool(content_view, sel_registerName("setWantsLayer:"), 1); // setWantsLayer:YES
    msgSetId(content_view, sel_registerName("setLayer:"), layer);
    return layer;
}

fn createSurface(win: *glfw.Window) ?*wgpu.Surface {
    switch (builtin.target.os.tag) {
        .windows => {
            const hwnd = glfw.getWin32Window(win) orelse {
                log.warn("no Win32 HWND from GLFW; rendering disabled", .{});
                return null;
            };
            const surface_desc = wgpu.surfaceDescriptorFromWindowsHWND(.{
                .hinstance = GetModuleHandleW(null).?,
                .hwnd = hwnd,
            });
            return instance.?.createSurface(&surface_desc);
        },
        .macos => {
            const nswindow = glfw.getCocoaWindow(win) orelse {
                log.warn("no Cocoa NSWindow from GLFW; rendering disabled", .{});
                return null;
            };
            const layer = attachMetalLayer(nswindow) orelse {
                log.warn("failed to attach CAMetalLayer; rendering disabled", .{});
                return null;
            };
            const surface_desc = wgpu.surfaceDescriptorFromMetalLayer(.{ .layer = layer });
            return instance.?.createSurface(&surface_desc);
        },
        else => {
            log.warn("wgpu surface creation only wired for Windows/macOS so far; rendering disabled", .{});
            return null;
        },
    }
}

fn initGpu() void {
    const win = glfw_window orelse return;

    instance = wgpu.Instance.create(null) orelse {
        log.warn("wgpu instance creation failed; rendering disabled", .{});
        return;
    };

    surface = createSurface(win) orelse {
        log.warn("wgpu surface creation failed; rendering disabled", .{});
        // createSurface returns null on platforms without a wired surface
        // (e.g. Linux) as well as on a genuine failure — release the
        // instance we just created so it doesn't leak on that path.
        instance.?.release();
        instance = null;
        return;
    };

    io_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    const io = io_threaded.?.io();

    const adapter_resp = instance.?.requestAdapterSync(&wgpu.RequestAdapterOptions{
        .compatible_surface = surface,
    }, io, std.Io.Duration.fromMilliseconds(10));
    const adapter = adapter_resp.adapter orelse {
        log.warn("wgpu adapter request failed: {s}; rendering disabled", .{adapter_resp.message orelse "?"});
        return;
    };

    // Request the ASTC compressed-texture feature so `uploadCompressed`'s
    // ASTC textures can be created (#341 / labelle-gfx#269). It's a DEVICE
    // FEATURE that must be enabled at device creation — without it, creating
    // an `astc*_unorm` texture fails. Best-effort: only ask for it when the
    // adapter actually advertises it (asking for an unsupported feature makes
    // `requestDevice` fail outright, which would disable ALL rendering), so on
    // hardware without ASTC we get a normal device and the loader simply can't
    // produce ASTC textures. `astc_supported` gates the upload path below.
    astc_supported = adapter.hasFeature(.texture_compression_astc);
    var required_features = [_]wgpu.FeatureName{.texture_compression_astc};
    const device_desc = wgpu.DeviceDescriptor{
        .required_feature_count = if (astc_supported) required_features.len else 0,
        .required_features = &required_features,
        .required_limits = null,
    };
    const device_resp = adapter.requestDeviceSync(instance.?, &device_desc, io, std.Io.Duration.fromMilliseconds(10));
    device = device_resp.device orelse {
        log.warn("wgpu device request failed; rendering disabled", .{});
        return;
    };
    if (astc_supported) {
        log.info("wgpu: ASTC compressed-texture feature enabled", .{});
    }
    // The adapter is only needed to create the device; drop our reference now.
    defer adapter.release();
    queue = device.?.getQueue() orelse return;

    surface.?.configure(&wgpu.SurfaceConfiguration{
        .device = device.?,
        .format = .bgra8_unorm,
        .width = @intCast(screen_w),
        .height = @intCast(screen_h),
    });

    const shader = device.?.createShaderModule(&wgpu.shaderModuleWGSLDescriptor(.{
        .code = shape_wgsl,
    })) orelse {
        log.warn("wgpu shader module creation failed; rendering disabled", .{});
        return;
    };
    defer shader.release();

    const attributes = [_]wgpu.VertexAttribute{
        .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
        .{ .format = .uint32, .offset = 8, .shader_location = 1 },
    };
    const vertex_layout = wgpu.VertexBufferLayout{
        .array_stride = @sizeOf(ShapeVertex),
        .attribute_count = attributes.len,
        .attributes = &attributes,
    };
    const color_target = wgpu.ColorTargetState{
        .format = .bgra8_unorm,
        .blend = &wgpu.BlendState{
            .color = .{ .src_factor = .src_alpha, .dst_factor = .one_minus_src_alpha, .operation = .add },
            .alpha = .{ .src_factor = .one, .dst_factor = .one_minus_src_alpha, .operation = .add },
        },
    };
    shape_pipeline = device.?.createRenderPipeline(&wgpu.RenderPipelineDescriptor{
        .vertex = .{
            .module = shader,
            .entry_point = wgpu.StringView.fromSlice("vs_main"),
            .buffer_count = 1,
            .buffers = &[_]wgpu.VertexBufferLayout{vertex_layout},
        },
        .fragment = &wgpu.FragmentState{
            .module = shader,
            .entry_point = wgpu.StringView.fromSlice("fs_main"),
            .target_count = 1,
            .targets = &[_]wgpu.ColorTargetState{color_target},
        },
        .primitive = .{},
        .multisample = .{},
    }) orelse {
        log.warn("wgpu pipeline creation failed; rendering disabled", .{});
        return;
    };

    vertex_buffer = device.?.createBuffer(&wgpu.BufferDescriptor{
        .size = MAX_VERTEX_BYTES,
        .usage = wgpu.BufferUsages.vertex | wgpu.BufferUsages.copy_dst,
    }) orelse return;
    index_buffer = device.?.createBuffer(&wgpu.BufferDescriptor{
        .size = MAX_INDEX_BYTES,
        .usage = wgpu.BufferUsages.index | wgpu.BufferUsages.copy_dst,
    }) orelse return;

    initSpritePipeline();

    gpu_ready = true;
}

/// Build the textured-quad pipeline: bind group layout (texture + sampler),
/// a clamp/nearest sampler, the sprite render pipeline, and its vertex/index
/// buffers. Failures here log + leave `sprite_pipeline` null; the shape path
/// stays fully functional and sprite draws are skipped (with a warning) until
/// the pipeline exists. Must run after `device`/`queue` are live.
fn initSpritePipeline() void {
    const dev = device orelse return;

    const sprite_shader = dev.createShaderModule(&wgpu.shaderModuleWGSLDescriptor(.{
        .code = sprite_wgsl,
    })) orelse {
        log.warn("wgpu sprite shader module creation failed; sprite rendering disabled", .{});
        return;
    };
    defer sprite_shader.release();

    // Bind group layout: binding 1 = sampled texture_2d, binding 2 = sampler.
    const bgl_entries = [_]wgpu.BindGroupLayoutEntry{
        .{
            .binding = 1,
            .visibility = wgpu.ShaderStages.fragment,
            .texture = .{ .sample_type = .float, .view_dimension = .@"2d" },
        },
        .{
            .binding = 2,
            .visibility = wgpu.ShaderStages.fragment,
            .sampler = .{ .@"type" = .filtering },
        },
    };
    sprite_bind_group_layout = dev.createBindGroupLayout(&wgpu.BindGroupLayoutDescriptor{
        .entry_count = bgl_entries.len,
        .entries = &bgl_entries,
    }) orelse {
        log.warn("wgpu sprite bind group layout creation failed; sprite rendering disabled", .{});
        return;
    };

    const pipeline_layout = dev.createPipelineLayout(&wgpu.PipelineLayoutDescriptor{
        .bind_group_layout_count = 1,
        .bind_group_layouts = &[_]*wgpu.BindGroupLayout{sprite_bind_group_layout.?},
    }) orelse {
        log.warn("wgpu sprite pipeline layout creation failed; sprite rendering disabled", .{});
        return;
    };
    defer pipeline_layout.release();

    sprite_sampler = dev.createSampler(&wgpu.SamplerDescriptor{
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .mag_filter = .nearest,
        .min_filter = .nearest,
    }) orelse {
        log.warn("wgpu sprite sampler creation failed; sprite rendering disabled", .{});
        return;
    };

    const attributes = [_]wgpu.VertexAttribute{
        .{ .format = .float32x2, .offset = 0, .shader_location = 0 }, // position
        .{ .format = .float32x2, .offset = 8, .shader_location = 1 }, // uv
        .{ .format = .uint32, .offset = 16, .shader_location = 2 }, // color_packed
    };
    const vertex_layout = wgpu.VertexBufferLayout{
        .array_stride = @sizeOf(SpriteVertex),
        .attribute_count = attributes.len,
        .attributes = &attributes,
    };
    // Same straight-alpha blend as the shape pipeline.
    const color_target = wgpu.ColorTargetState{
        .format = .bgra8_unorm,
        .blend = &wgpu.BlendState{
            .color = .{ .src_factor = .src_alpha, .dst_factor = .one_minus_src_alpha, .operation = .add },
            .alpha = .{ .src_factor = .one, .dst_factor = .one_minus_src_alpha, .operation = .add },
        },
    };
    const pipeline = dev.createRenderPipeline(&wgpu.RenderPipelineDescriptor{
        .layout = pipeline_layout,
        .vertex = .{
            .module = sprite_shader,
            .entry_point = wgpu.StringView.fromSlice("vs_main"),
            .buffer_count = 1,
            .buffers = &[_]wgpu.VertexBufferLayout{vertex_layout},
        },
        .fragment = &wgpu.FragmentState{
            .module = sprite_shader,
            .entry_point = wgpu.StringView.fromSlice("fs_main"),
            .target_count = 1,
            .targets = &[_]wgpu.ColorTargetState{color_target},
        },
        .primitive = .{},
        .multisample = .{},
    }) orelse {
        log.warn("wgpu sprite pipeline creation failed; sprite rendering disabled", .{});
        return;
    };

    // Create the vertex/index buffers BEFORE publishing `sprite_pipeline`.
    // submitFrame gates sprite segments on `sprite_pipeline` alone and then
    // unwraps the buffers, so the pipeline must not be visible until both
    // buffers exist — otherwise a buffer-creation failure here would leave a
    // non-null pipeline with null buffers and panic the first sprite draw.
    const vbuf = dev.createBuffer(&wgpu.BufferDescriptor{
        .size = MAX_SPRITE_VERTEX_BYTES,
        .usage = wgpu.BufferUsages.vertex | wgpu.BufferUsages.copy_dst,
    }) orelse {
        log.warn("wgpu sprite vertex buffer creation failed; sprite rendering disabled", .{});
        pipeline.release();
        return;
    };
    const ibuf = dev.createBuffer(&wgpu.BufferDescriptor{
        .size = MAX_SPRITE_INDEX_BYTES,
        .usage = wgpu.BufferUsages.index | wgpu.BufferUsages.copy_dst,
    }) orelse {
        log.warn("wgpu sprite index buffer creation failed; sprite rendering disabled", .{});
        vbuf.release();
        pipeline.release();
        return;
    };

    sprite_vertex_buffer = vbuf;
    sprite_index_buffer = ibuf;
    sprite_pipeline = pipeline;
}

/// Map an ASTC block size to the matching wgpu `TextureFormat`, or null if it
/// isn't one of the LDR block sizes the enum exposes. We use the Unorm (not
/// sRGB) variants to match the backend's RGBA8 textures (`rgba8_unorm`) and
/// surface (`bgra8_unorm`), so ASTC sprites sample with the same linear-vs-sRGB
/// convention as the PNG/BMP path — no gamma mismatch between formats.
fn astcFormat(block_x: u8, block_y: u8) ?wgpu.TextureFormat {
    return switch ((@as(u16, block_x) << 8) | block_y) {
        0x0404 => .astc4x4_unorm,
        0x0504 => .astc5x4_unorm,
        0x0505 => .astc5x5_unorm,
        0x0605 => .astc6x5_unorm,
        0x0606 => .astc6x6_unorm,
        0x0805 => .astc8x5_unorm,
        0x0806 => .astc8x6_unorm,
        0x0808 => .astc8x8_unorm,
        0x0a05 => .astc10x5_unorm,
        0x0a06 => .astc10x6_unorm,
        0x0a08 => .astc10x8_unorm,
        0x0a0a => .astc10x10_unorm,
        0x0c0a => .astc12x10_unorm,
        0x0c0c => .astc12x12_unorm,
        else => null,
    };
}

/// Create + upload an ASTC wgpu texture from a validated compressed slot (#341).
/// The block payload is written verbatim (zero CPU decode); the data layout is
/// the COMPRESSED-block grid, not pixels: each row of blocks is 16 bytes per
/// block, so `bytes_per_row = ceil(w/block_x) * 16` and `rows_per_image =
/// ceil(h/block_y)`. Returns null when ASTC isn't enabled on the device (the
/// adapter lacked the feature) or any GPU step fails.
fn createAstcTexture(
    dev: *wgpu.Device,
    q: *wgpu.Queue,
    c: gfx.CompressedTexture,
) ?*wgpu.Texture {
    if (!astc_supported) {
        if (!astc_unsupported_warned) {
            log.warn("wgpu: ASTC texture skipped — adapter lacks texture_compression_astc", .{});
            astc_unsupported_warned = true;
        }
        return null;
    }
    if (c.width == 0 or c.height == 0) return null;
    const fmt = astcFormat(c.block_x, c.block_y) orelse return null;

    const tex = dev.createTexture(&wgpu.TextureDescriptor{
        .usage = wgpu.TextureUsages.texture_binding | wgpu.TextureUsages.copy_dst,
        .size = .{ .width = c.width, .height = c.height, .depth_or_array_layers = 1 },
        .format = fmt,
    }) orelse return null;

    // Compressed data layout: blocks, not texels. One ASTC block = 16 bytes.
    const blocks_x = (c.width + c.block_x - 1) / c.block_x;
    const blocks_y = (c.height + c.block_y - 1) / c.block_y;
    q.writeTexture(
        &wgpu.TexelCopyTextureInfo{ .texture = tex, .origin = .{} },
        c.blocks.ptr,
        c.blocks.len,
        &wgpu.TexelCopyBufferLayout{
            .bytes_per_row = blocks_x * 16,
            .rows_per_image = blocks_y,
        },
        &wgpu.Extent3D{ .width = c.width, .height = c.height, .depth_or_array_layers = 1 },
    );
    return tex;
}

/// Lazily create + upload the GPU texture for a gfx texture id, returning its
/// bind group (cached in `gpu_textures`). Runs on the main/GL thread from
/// submitFrame. Returns null if the id is unknown or any GPU step fails.
fn getOrCreateGpuTexture(id: u32) ?*wgpu.BindGroup {
    if (id == 0 or id >= MAX_GPU_TEXTURES) return null;
    if (gpu_textures[id]) |gt| return gt.bind_group;

    const dev = device orelse return null;
    const q = queue orelse return null;
    const layout = sprite_bind_group_layout orelse return null;
    const sampler = sprite_sampler orelse return null;

    // GPU-compressed (ASTC) slots upload the raw blocks as-is to an ASTC
    // texture (#341); everything else is RGBA8. A compressed id never surfaces
    // through `getTexturePixels` (it returns null for compressed slots), so the
    // two paths are mutually exclusive.
    const tex = if (gfx.getCompressedTexture(id)) |c|
        createAstcTexture(dev, q, c) orelse return null
    else blk: {
        const px = gfx.getTexturePixels(id) orelse return null;
        if (px.width == 0 or px.height == 0) return null;

        const t = dev.createTexture(&wgpu.TextureDescriptor{
            .usage = wgpu.TextureUsages.texture_binding | wgpu.TextureUsages.copy_dst,
            .size = .{ .width = px.width, .height = px.height, .depth_or_array_layers = 1 },
            .format = .rgba8_unorm,
        }) orelse return null;

        // Upload RGBA8 rows (4 bytes/pixel, tightly packed — no row padding).
        q.writeTexture(
            &wgpu.TexelCopyTextureInfo{ .texture = t, .origin = .{} },
            px.pixels.ptr,
            px.pixels.len,
            &wgpu.TexelCopyBufferLayout{
                .bytes_per_row = px.width * 4,
                .rows_per_image = px.height,
            },
            &wgpu.Extent3D{ .width = px.width, .height = px.height, .depth_or_array_layers = 1 },
        );
        break :blk t;
    };

    const view = tex.createView(null) orelse {
        tex.release();
        return null;
    };

    const bg_entries = [_]wgpu.BindGroupEntry{
        .{ .binding = 1, .texture_view = view },
        .{ .binding = 2, .sampler = sampler },
    };
    const bind_group = dev.createBindGroup(&wgpu.BindGroupDescriptor{
        .layout = layout,
        .entry_count = bg_entries.len,
        .entries = &bg_entries,
    }) orelse {
        view.release();
        tex.release();
        return null;
    };

    gpu_textures[id] = .{ .texture = tex, .view = view, .bind_group = bind_group };
    return bind_group;
}

pub fn initWindow(width_px: i32, height_px: i32, title: [:0]const u8) void {
    // `width_px`/`height_px` are the LOGICAL design canvas (project width/height).
    // (Params suffixed `_px` so they don't shadow the module-level `width()`/
    // `height()` window-contract decls.)
    // Reset per-window contract state so a close→reopen starts clean (else a
    // prior `requestQuit` would close the new window immediately + the first
    // `frameDuration` would be a huge time-since-old-baseline). Mirrors raylib.
    quit_requested = false;
    last_frame_time = 0;
    gpu_ready = false; // set true by initGpu() below on success; a failed re-init stays not-ready
    screen_w = width_px;
    screen_h = height_px;

    glfw.init() catch return;

    // WebGPU uses GLFW without an OpenGL context. Hints are set via the
    // typed windowHint API (zglfw 0.10 — there is no options-struct
    // create overload; that shape belongs to mach-glfw).
    glfw.windowHint(.client_api, .no_api);
    glfw.windowHint(.visible, !window_hidden);
    glfw_window = glfw.createWindow(
        @intCast(width_px),
        @intCast(height_px),
        title,
        null,
        null,
    ) catch return;

    // The window was requested at the LOGICAL width/height. Tell gfx that's
    // the design canvas. On a HiDPI/Retina display the backing framebuffer
    // is larger (e.g. 2x); seed `screen_w/h` + the gfx physical size from the
    // real framebuffer so the swapchain renders at full Retina sharpness and
    // the design canvas aspect-fits onto it. wgpu has no template
    // `setDesignSize` call (the generated main never invokes it for this
    // backend), so window.zig sets it here. Mirrors the bgfx backend.
    gfx.setDesignSize(width_px, height_px);
    const fb = framebufferSize();
    screen_w = fb[0];
    screen_h = fb[1];
    gfx.setScreenSize(screen_w, screen_h);

    initGpu();

    const input = @import("input");
    if (glfw_window) |win| {
        input.setWindow(win);
    }
}

pub fn closeWindow() void {
    // Release lazily-created GPU textures + their views / bind groups.
    for (&gpu_textures) |*slot| {
        if (slot.*) |gt| {
            gt.bind_group.release();
            gt.view.release();
            gt.texture.release();
            slot.* = null;
        }
    }
    if (sprite_pipeline) |p| {
        p.release();
        sprite_pipeline = null;
    }
    if (sprite_vertex_buffer) |b| {
        b.release();
        sprite_vertex_buffer = null;
    }
    if (sprite_index_buffer) |b| {
        b.release();
        sprite_index_buffer = null;
    }
    if (sprite_sampler) |s| {
        s.release();
        sprite_sampler = null;
    }
    if (sprite_bind_group_layout) |l| {
        l.release();
        sprite_bind_group_layout = null;
    }

    if (glfw_window) |win| win.destroy();
    glfw.terminate();
    glfw_window = null;
    // The GPU resources above are released — mark not-ready so a stray
    // `endDrawing`/`ensureSurface` after close (or before a re-init's `initGpu`)
    // hits the `if (!gpu_ready) return` guard instead of touching freed handles.
    gpu_ready = false;
}

pub fn windowShouldClose() bool {
    if (quit_requested) return true;
    if (glfw_window) |win| return win.shouldClose();
    return true;
}

// ── Canonical window contract (labelle-core `assertWindow`) ──────────────
// Additive aliases so the wgpu backend satisfies the canonical window contract
// (width/height/frameDuration/requestQuit) ahead of its out-of-tree extraction
// (#386), mirroring the in-tree raylib/null conformance (#411). The desktop
// template still calls the legacy names + a fixed 0.016 dt, so generated output
// is byte-identical; these exist for the contract guard + manifest-driven
// templates.

/// Current framebuffer width (physical pixels, HiDPI-aware — `screen_w` is
/// reconciled from `getFramebufferSize()` each frame by `ensureSurface`).
pub fn width() i32 {
    return screen_w;
}
/// Current framebuffer height (physical pixels).
pub fn height() i32 {
    return screen_h;
}
/// Seconds elapsed since the previous call — the engine's `dt` source. GLFW's
/// monotonic clock; the first call seeds the baseline and returns one nominal
/// 60 Hz step rather than the (large) time-since-glfwInit.
pub fn frameDuration() f64 {
    const now = glfw.getTime();
    if (last_frame_time == 0) {
        last_frame_time = now;
        return 1.0 / 60.0;
    }
    const dt = now - last_frame_time;
    last_frame_time = now;
    return dt;
}
/// Ask the window to end the run loop. GLFW has its own close flag too, but a
/// programmatic engine/script quit latches here; `windowShouldClose`/`shouldQuit`
/// OR it in (no behavior change unless something calls this).
pub fn requestQuit() void {
    quit_requested = true;
}
/// Canonical alias of `windowShouldClose` (loop-style backends own the
/// `while (!shouldQuit())` loop). Presence signals loop-ownership to the contract.
pub fn shouldQuit() bool {
    return windowShouldClose();
}

/// Query whether the window is currently fullscreen. Mirrors the bgfx
/// backend: GLFW reports a window bound to a monitor as fullscreen. Returns
/// false before the window exists.
pub fn isFullscreen() bool {
    const win = glfw_window orelse return false;
    return win.getMonitor() != null;
}

/// Switch to fullscreen (`on=true`) or windowed (`on=false`). Mirrors the
/// bgfx backend's GLFW approach: GLFW has no toggle primitive, so going
/// fullscreen binds the window to the primary monitor at its current video
/// mode (saving the windowed geometry first); going windowed restores the
/// saved geometry. The resulting PHYSICAL framebuffer change is picked up by
/// `ensureSurface()` on the next `beginDrawing` (which reconfigures the wgpu
/// surface + tells gfx the new physical size), so no resize is done here —
/// this keeps the surface and gfx exactly in step with the live framebuffer
/// rather than guessing the framebuffer from the monitor's logical video
/// mode (wrong on HiDPI). Idempotent — a no-op when already in the requested
/// mode or before the window exists.
pub fn setFullscreen(on: bool) void {
    const win = glfw_window orelse return;
    const already = win.getMonitor() != null;
    if (already == on) return;
    if (on) {
        // Remember where the window was so we can come back to it.
        const pos = win.getPos();
        const size = win.getSize();
        windowed_x = pos[0];
        windowed_y = pos[1];
        windowed_w = size[0];
        windowed_h = size[1];
        const monitor = glfw.getPrimaryMonitor() orelse return;
        const mode = glfw.getVideoMode(monitor) catch return;
        win.setMonitor(monitor, 0, 0, mode.width, mode.height, mode.refresh_rate);
    } else {
        win.setMonitor(null, windowed_x, windowed_y, windowed_w, windowed_h, 0);
    }
}

pub fn setTargetFPS(fps: i32) void {
    target_fps_val = fps;
}

pub fn beginDrawing() void {
    const input = @import("input");
    input.newFrame();
    // Reconcile the wgpu surface with the current physical framebuffer size
    // (DPI move, resize, fullscreen toggle) every frame, so HiDPI changes are
    // picked up without a dedicated resize callback. Mirrors bgfx.
    ensureSurface();
}

/// Drain the gfx frame into the GPU: acquire the surface texture, clear,
/// then replay the ordered draw-segment stream so shapes and sprites
/// composite in strict painter's (submission) order, submit, present.
pub fn endDrawing() void {
    if (!gpu_ready) return;

    const frame = gfx.consumeFrame();

    var surface_texture: wgpu.SurfaceTexture = undefined;
    surface.?.getCurrentTexture(&surface_texture);
    const texture = surface_texture.texture orelse return;
    defer texture.release();
    // Once a swapchain texture has been acquired it must ALWAYS be
    // presented — even when an intermediate step below bails — or the
    // acquire/present pairing breaks and a transient GPU failure can
    // wedge the swapchain permanently. submitFrame's early returns just
    // skip the draw; the present still runs.
    defer _ = surface.?.present();

    submitFrame(texture, frame);
}

/// Upload both vertex/index buffers once, then walk the ordered segment
/// stream. Shapes and sprites keep separate vertex formats + pipelines, so
/// each segment switches the pipeline/buffers for its kind and draws its
/// index range. Draw order now follows per-call submission order via the
/// segment stream — a shape can composite over a sprite within one frame,
/// matching the immediate (raylib) backends. Sprite segments retain the
/// same contiguous same-texture coalescing as before.
fn submitFrame(texture: *wgpu.Texture, frame: gfx.Frame) void {
    const view = texture.createView(null) orelse return;
    defer view.release();

    const encoder = device.?.createCommandEncoder(&.{}) orelse return;
    defer encoder.release();

    const color_attachment = wgpu.ColorAttachment{
        .view = view,
        .load_op = .clear,
        .store_op = .store,
        .clear_value = clear_color,
    };
    const pass = encoder.beginRenderPass(&wgpu.RenderPassDescriptor{
        .color_attachment_count = 1,
        .color_attachments = &[_]wgpu.ColorAttachment{color_attachment},
    }) orelse return;

    // Byte sizes are frame-constant (the buffers are uploaded whole), so
    // compute them once here and reuse for both the upload guards and the
    // per-segment buffer binds below.
    const shape_vbytes = frame.shape_vertices.len * @sizeOf(ShapeVertex);
    const shape_ibytes = frame.shape_indices.len * @sizeOf(u32);
    const sprite_vbytes = frame.sprite_vertices.len * @sizeOf(SpriteVertex);
    const sprite_ibytes = frame.sprite_indices.len * @sizeOf(u32);

    // Upload the shape vertex/index buffers once (guarded by the byte caps).
    var shape_uploaded = false;
    if (frame.shape_indices.len > 0 and shape_vbytes <= MAX_VERTEX_BYTES and shape_ibytes <= MAX_INDEX_BYTES) {
        queue.?.writeBuffer(vertex_buffer.?, 0, frame.shape_vertices.ptr, shape_vbytes);
        queue.?.writeBuffer(index_buffer.?, 0, frame.shape_indices.ptr, shape_ibytes);
        shape_uploaded = true;
    }

    // Upload the sprite vertex/index buffers once (guarded by the byte caps).
    var sprite_uploaded = false;
    if (frame.sprite_indices.len > 0 and sprite_vbytes <= MAX_SPRITE_VERTEX_BYTES and sprite_ibytes <= MAX_SPRITE_INDEX_BYTES) {
        queue.?.writeBuffer(sprite_vertex_buffer.?, 0, frame.sprite_vertices.ptr, sprite_vbytes);
        queue.?.writeBuffer(sprite_index_buffer.?, 0, frame.sprite_indices.ptr, sprite_ibytes);
        sprite_uploaded = true;
    }

    // Replay segments in submission order, switching pipeline per kind.
    for (frame.segments) |seg| {
        switch (seg.kind) {
            .shape => {
                if (!shape_uploaded) continue;
                const sp = shape_pipeline orelse continue;
                pass.setPipeline(sp);
                pass.setVertexBuffer(0, vertex_buffer.?, 0, shape_vbytes);
                pass.setIndexBuffer(index_buffer.?, .uint32, 0, shape_ibytes);
                pass.drawIndexed(seg.index_count, 1, seg.index_start, 0, 0);
            },
            .sprite => {
                if (!sprite_uploaded) continue;
                const sp = sprite_pipeline orelse continue;
                pass.setPipeline(sp);
                pass.setVertexBuffer(0, sprite_vertex_buffer.?, 0, sprite_vbytes);
                pass.setIndexBuffer(sprite_index_buffer.?, .uint32, 0, sprite_ibytes);
                drawSpriteRange(pass, frame.sprite_texture_ids, seg.quad_start, seg.quad_count);
            },
        }
    }

    pass.end();
    pass.release();

    const command = encoder.finish(null) orelse return;
    defer command.release();
    queue.?.submit(&[_]*const wgpu.CommandBuffer{command});
}

/// Draw the quads in `[quad_start, quad_start+quad_count)` of an
/// already-bound sprite pipeline/buffers, issuing one drawIndexed per
/// contiguous run of quads that share a texture (binding that texture's
/// bind group). Each quad is 4 verts / 6 indices; `first_index = quad*6`.
/// Quads whose texture failed to upload are skipped so the rest still
/// renders. Assumes the sprite pipeline + vertex/index buffers are already
/// set by the caller for this segment.
fn drawSpriteRange(
    pass: *wgpu.RenderPassEncoder,
    texture_ids: []const u32,
    quad_start: u32,
    quad_count: u32,
) void {
    const start: usize = quad_start;
    const end: usize = start + quad_count;
    if (end > texture_ids.len) return;

    var quad: usize = start;
    while (quad < end) {
        const tex_id = texture_ids[quad];
        var run_end = quad + 1;
        while (run_end < end and texture_ids[run_end] == tex_id) run_end += 1;

        if (getOrCreateGpuTexture(tex_id)) |bind_group| {
            pass.setBindGroup(0, bind_group, 0, null);
            const index_count: u32 = @intCast((run_end - quad) * 6);
            const first_index: u32 = @intCast(quad * 6);
            pass.drawIndexed(index_count, 1, first_index, 0, 0);
        }
        quad = run_end;
    }
}

pub fn clearBackground(r: u8, g: u8, b: u8, a: u8) void {
    clear_color = .{
        .r = @as(f64, @floatFromInt(r)) / 255.0,
        .g = @as(f64, @floatFromInt(g)) / 255.0,
        .b = @as(f64, @floatFromInt(b)) / 255.0,
        .a = @as(f64, @floatFromInt(a)) / 255.0,
    };
}

pub fn drawText(text: [:0]const u8, x: i32, y: i32, font_size: i32, r: u8, g: u8, b: u8, a: u8) void {
    // Route through gfx's bitmap-font glyph rects so HUD text lands in the
    // same shape batch the submitter drains.
    gfx.drawText(text, @floatFromInt(x), @floatFromInt(y), @floatFromInt(font_size), .{ .r = r, .g = g, .b = b, .a = a });
}
