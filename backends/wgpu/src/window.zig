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

var screen_w: i32 = 800;
var screen_h: i32 = 600;
var glfw_window: ?*glfw.Window = null;
var target_fps_val: i32 = 60;
var window_hidden: bool = false;

pub fn setConfigFlags(flags: ConfigFlags) void {
    window_hidden = flags.window_hidden;
}

// ── GPU state ───────────────────────────────────────────────────────────

const ShapeVertex = extern struct { position: [2]f32, color_packed: u32 };
// Sprite vertex layout is owned by gfx.zig (the batch producer); alias it so
// the GPU-side stride / attribute offsets stay in lockstep with the CPU side.
const SpriteVertex = gfx.SpriteVertex;

var gpu_ready = false;
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

    const device_resp = adapter.requestDeviceSync(instance.?, null, io, std.Io.Duration.fromMilliseconds(10));
    device = device_resp.device orelse {
        log.warn("wgpu device request failed; rendering disabled", .{});
        return;
    };
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
    // drawSprites gates on `sprite_pipeline` alone and then unwraps the
    // buffers, so the pipeline must not be visible until both buffers exist
    // — otherwise a buffer-creation failure here would leave a non-null
    // pipeline with null buffers and panic the first sprite draw.
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

    const px = gfx.getTexturePixels(id) orelse return null;
    if (px.width == 0 or px.height == 0) return null;

    const tex = dev.createTexture(&wgpu.TextureDescriptor{
        .usage = wgpu.TextureUsages.texture_binding | wgpu.TextureUsages.copy_dst,
        .size = .{ .width = px.width, .height = px.height, .depth_or_array_layers = 1 },
        .format = .rgba8_unorm,
    }) orelse return null;

    // Upload RGBA8 rows (4 bytes/pixel, tightly packed — no row padding).
    q.writeTexture(
        &wgpu.TexelCopyTextureInfo{ .texture = tex, .origin = .{} },
        px.pixels.ptr,
        px.pixels.len,
        &wgpu.TexelCopyBufferLayout{
            .bytes_per_row = px.width * 4,
            .rows_per_image = px.height,
        },
        &wgpu.Extent3D{ .width = px.width, .height = px.height, .depth_or_array_layers = 1 },
    );

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

pub fn initWindow(width: i32, height: i32, title: [:0]const u8) void {
    screen_w = width;
    screen_h = height;

    glfw.init() catch return;

    // WebGPU uses GLFW without an OpenGL context. Hints are set via the
    // typed windowHint API (zglfw 0.10 — there is no options-struct
    // create overload; that shape belongs to mach-glfw).
    glfw.windowHint(.client_api, .no_api);
    glfw.windowHint(.visible, !window_hidden);
    glfw_window = glfw.createWindow(
        @intCast(width),
        @intCast(height),
        title,
        null,
        null,
    ) catch return;

    gfx.setScreenSize(width, height);
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
}

pub fn windowShouldClose() bool {
    if (glfw_window) |win| return win.shouldClose();
    return true;
}

pub fn setTargetFPS(fps: i32) void {
    target_fps_val = fps;
}

pub fn beginDrawing() void {
    const input = @import("input");
    input.newFrame();
}

/// Drain the gfx shape + sprite batches into the GPU: acquire the surface
/// texture, clear + draw the batched triangles (shapes first, sprites on top),
/// submit, present.
pub fn endDrawing() void {
    if (!gpu_ready) return;

    const shape_batch = gfx.consumeShapeBatch();
    const sprite_batch = gfx.consumeSpriteBatch();

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

    submitFrame(texture, shape_batch.vertices, shape_batch.indices, sprite_batch.vertices, sprite_batch.indices, sprite_batch.texture_ids);
}

fn submitFrame(
    texture: *wgpu.Texture,
    vertices: []const gfx.ColorVertex,
    indices: []const u32,
    sprite_vertices: []const SpriteVertex,
    sprite_indices: []const u32,
    sprite_texture_ids: []const u32,
) void {
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

    // --- Shapes / text / gizmos (drawn first, under sprites) ---
    if (indices.len > 0) {
        const vbytes = vertices.len * @sizeOf(ShapeVertex);
        const ibytes = indices.len * @sizeOf(u32);
        queue.?.writeBuffer(vertex_buffer.?, 0, vertices.ptr, vbytes);
        queue.?.writeBuffer(index_buffer.?, 0, indices.ptr, ibytes);
        pass.setPipeline(shape_pipeline.?);
        pass.setVertexBuffer(0, vertex_buffer.?, 0, vbytes);
        pass.setIndexBuffer(index_buffer.?, .uint32, 0, ibytes);
        pass.drawIndexed(@intCast(indices.len), 1, 0, 0, 0);
    }

    // --- Sprites (textured quads, drawn on top of shapes) ---
    // KNOWN LIMITATION: shapes and sprites are drained as two separate
    // batches, so every sprite composites above every shape regardless of
    // the per-call submission order — a game cannot draw a shape *over* a
    // sprite within one frame. Immediate backends (raylib) preserve strict
    // painter's order. Fixing this needs a single interleaved command
    // stream tagged by primitive kind; tracked as a follow-up. The common
    // case (sprites = world, shapes/gizmos = HUD on top) is unaffected by
    // intent but inverted here — documented so it isn't mistaken for a bug.
    drawSprites(pass, sprite_vertices, sprite_indices, sprite_texture_ids);

    pass.end();
    pass.release();

    const command = encoder.finish(null) orelse return;
    defer command.release();
    queue.?.submit(&[_]*const wgpu.CommandBuffer{command});
}

/// Upload the sprite batch once, then issue one draw per contiguous run of
/// quads that share a texture, binding that texture's bind group. The batch is
/// laid out as 4 verts / 6 indices per quad, with one texture id per quad
/// (see gfx.consumeSpriteBatch). Quads whose texture failed to upload are
/// skipped so the rest of the batch still renders. Sprite rendering is a no-op
/// if the pipeline failed to initialize.
fn drawSprites(
    pass: *wgpu.RenderPassEncoder,
    vertices: []const SpriteVertex,
    indices: []const u32,
    texture_ids: []const u32,
) void {
    if (texture_ids.len == 0 or indices.len == 0) return;
    const pipeline = sprite_pipeline orelse return;

    const vbytes = vertices.len * @sizeOf(SpriteVertex);
    const ibytes = indices.len * @sizeOf(u32);
    if (vbytes > MAX_SPRITE_VERTEX_BYTES or ibytes > MAX_SPRITE_INDEX_BYTES) return;

    queue.?.writeBuffer(sprite_vertex_buffer.?, 0, vertices.ptr, vbytes);
    queue.?.writeBuffer(sprite_index_buffer.?, 0, indices.ptr, ibytes);
    pass.setPipeline(pipeline);
    pass.setVertexBuffer(0, sprite_vertex_buffer.?, 0, vbytes);
    pass.setIndexBuffer(sprite_index_buffer.?, .uint32, 0, ibytes);

    // Coalesce consecutive same-texture quads into a single drawIndexed call.
    var quad: usize = 0;
    while (quad < texture_ids.len) {
        const tex_id = texture_ids[quad];
        var run_end = quad + 1;
        while (run_end < texture_ids.len and texture_ids[run_end] == tex_id) run_end += 1;

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
