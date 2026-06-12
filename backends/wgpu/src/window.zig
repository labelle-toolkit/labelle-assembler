/// WebGPU window backend — GLFW windowing + the wgpu render submitter.
///
/// The CPU side of rendering lives in gfx.zig (NDC vertex batching); this
/// file owns the GPU spine: instance → surface (Win32 HWND) → adapter →
/// device/queue → surface configure, and the per-frame acquire → upload →
/// render-pass → submit → present that drains gfx's shape batch. The batch
/// vertices are already NDC, so the pipeline is a passthrough WGSL module
/// with no uniforms/bind groups. Sprites + text atlases stay TODO (the
/// shape path covers gizmo-rendered games end to end).
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

const MAX_VERTEX_BYTES: u64 = 16384 * @sizeOf(ShapeVertex);
const MAX_INDEX_BYTES: u64 = 32768 * @sizeOf(u32);

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

    gpu_ready = true;
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

/// Drain the gfx shape batch into the GPU: acquire the surface texture,
/// clear + draw the batched triangles, submit, present.
pub fn endDrawing() void {
    if (!gpu_ready) return;

    const batch = gfx.consumeShapeBatch();

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

    submitFrame(texture, batch.vertices, batch.indices);
}

fn submitFrame(texture: *wgpu.Texture, vertices: []const gfx.ColorVertex, indices: []const u32) void {
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
    pass.end();
    pass.release();

    const command = encoder.finish(null) orelse return;
    defer command.release();
    queue.?.submit(&[_]*const wgpu.CommandBuffer{command});
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
