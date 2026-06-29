/// Raylib window backend — windowing lifecycle functions.
const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");

pub const ConfigFlags = struct {
    window_hidden: bool = false,
};

pub fn setConfigFlags(flags: ConfigFlags) void {
    if (flags.window_hidden) {
        rl.setConfigFlags(.{ .window_hidden = true });
    }
}

pub fn initWindow(width_px: i32, height_px: i32, title: [:0]const u8) void {
    quit_requested = false; // clear any prior latch so a re-init starts fresh
    rl.initWindow(width_px, height_px, title);
    rl.setExitKey(.escape);
}

pub fn closeWindow() void {
    rl.closeWindow();
}

pub fn windowShouldClose() bool {
    return quit_requested or rl.windowShouldClose();
}

/// Query whether the window is currently fullscreen. Mirrors the sokol
/// backend's `isFullscreen`.
pub fn isFullscreen() bool {
    return rl.isWindowFullscreen();
}

/// Switch the window to fullscreen (`on=true`) or windowed (`on=false`).
/// The generated frame loop polls `g.takeFullscreenRequest()` and calls
/// this when a script flipped `game.setFullscreen`. raylib only exposes a
/// *toggle*, so we toggle only when the current mode differs from the
/// requested one (idempotent).
pub fn setFullscreen(on: bool) void {
    if (rl.isWindowFullscreen() != on) rl.toggleFullscreen();
}

pub fn setTargetFPS(fps: i32) void {
    rl.setTargetFPS(fps);
}

pub fn getFrameTime() f32 {
    return rl.getFrameTime();
}

pub fn getScreenWidth() i32 {
    return rl.getScreenWidth();
}

pub fn getScreenHeight() i32 {
    return rl.getScreenHeight();
}

// ── Canonical window contract (labelle-core/src/window_contract.zig) ──────
// The uniform window surface the pluggable-backends contract standardizes on
// (labelle-assembler#386). raylib already exposes these values under its legacy
// `getScreenWidth`-style names (kept — the generated raylib run-loop templates
// still call them); the decls below are the canonical aliases so raylib
// satisfies `core.assertWindow`. Renaming the templates to call these instead
// (so backends can share one run-loop template) is a separate epic slice.
var quit_requested: bool = false;

/// Current framebuffer width.
pub fn width() i32 {
    return rl.getScreenWidth();
}
/// Current framebuffer height.
pub fn height() i32 {
    return rl.getScreenHeight();
}
/// Seconds elapsed for the last frame — the engine's `dt` source.
pub fn frameDuration() f64 {
    return @floatCast(rl.getFrameTime());
}
/// Ask the window to end the run loop. raylib has no native programmatic close,
/// so latch a flag that `windowShouldClose` ORs in (no behavior change unless
/// a script/engine calls this).
pub fn requestQuit() void {
    quit_requested = true;
}

pub fn beginDrawing() void {
    rl.beginDrawing();
}

pub fn endDrawing() void {
    rl.endDrawing();
}

pub fn clearBackground(r: u8, g: u8, b: u8, a: u8) void {
    rl.clearBackground(.{ .r = r, .g = g, .b = b, .a = a });
}

pub fn drawText(text: [:0]const u8, x: i32, y: i32, font_size: i32, r: u8, g: u8, b: u8, a: u8) void {
    rl.drawText(text, x, y, font_size, .{ .r = r, .g = g, .b = b, .a = a });
}

/// raylib's `TakeScreenshot` unconditionally prepends the binary's
/// current working directory to the path it's handed, mangling
/// absolute targets like `/tmp/foo.png` into `<cwd>//tmp/foo.png`
/// (see labelle-assembler#224).
///
/// The previous fix (#225) worked around this by asking raylib to
/// write into cwd under a temp name and then `std.c.rename`ing onto
/// the absolute target. That trick broke in three places (see
/// labelle-assembler#229):
///
///   1. `rename` returns `EXDEV` across mounts — `/tmp` is tmpfs on
///      most Linux installs, so the rename failed and the cleanup
///      branch `unlink`ed the temp file, leaving the user with no
///      screenshot at any path.
///   2. `std.c.getpid` / `rename` / `unlink` aren't declared on
///      Windows; the runtime OS gate didn't stop sema from analyzing
///      the dead branch, so Windows cross-compiles failed.
///   3. The Windows branch fell back to pid=0 in the temp name, so
///      two concurrent runs in the same cwd raced on the same file.
///
/// Option 4 from the ticket — mirror sokol's
/// `backends/sokol/src/screenshot/bmp.zig` pattern: grab the
/// framebuffer via raylib, encode to PNG in memory via
/// `ExportImageToMemory`, then write the bytes directly to the
/// destination path with libc `fopen` / `fwrite` / `fclose`. No temp
/// file, no rename, no cross-volume issue, no Windows-API hole, no
/// pid collision. libc is already on the link line via raylib's
/// own C dependencies.
pub fn takeScreenshot(path: [:0]const u8) void {
    const image = rl.loadImageFromScreen() catch {
        std.log.warn("screenshot: LoadImageFromScreen failed", .{});
        return;
    };
    defer rl.unloadImage(image);

    const png_bytes = rl.exportImageToMemory(image, ".png") catch {
        std.log.warn("screenshot: ExportImageToMemory failed", .{});
        return;
    };
    // Raylib allocates the PNG buffer with its internal allocator;
    // free it via MemFree regardless of how the libc write below goes.
    defer rl.memFree(@ptrCast(png_bytes.ptr));

    // libc `fopen` handles absolute and relative paths uniformly on
    // every supported target (POSIX + Windows MSVCRT/UCRT). The path
    // is already a `[*:0]const u8`, no copy needed.
    const fp = std.c.fopen(path.ptr, "wb") orelse {
        std.log.warn("screenshot: fopen failed for {s}", .{path});
        return;
    };
    defer _ = std.c.fclose(fp);
    const written = std.c.fwrite(png_bytes.ptr, 1, png_bytes.len, fp);
    if (written != png_bytes.len) {
        std.log.warn(
            "screenshot: short write to {s} ({d}/{d} bytes)",
            .{ path, written, png_bytes.len },
        );
    }
}

// ──────────────────────────────────────────────────────────────────
// PBO-based preview readback (labelle-assembler#140 raylib migration)
// ──────────────────────────────────────────────────────────────────
// Async GPU→CPU pixel readback for the Play-in-Editor preview. The
// raylib backend uses a 3-deep PBO ring to hide the readback latency:
//
//   frame N   : bind pbo[N % 3] → glReadPixels (async DMA into PBO)
//   frame N+2 : bind pbo[(N-2) % 3] → glMapBuffer → memcpy to CPU
//               → Preview.publishFrame → unmap
//
// The 2-frame priming gap is what hides the GPU→CPU stall.
//
// On macOS the engine API surface switches at comptime to the
// zero-copy IOSurface lifecycle (beginFrameStreamIOSurface /
// publishFrameIOSurface / endFrameStreamIOSurface). The producer-side
// pixel buffer stays RGBA8 — publishFrameIOSurface swizzles to BGRA
// internally during the IOSurface lock/copy.

/// Vtable exposing engine.Preview's preview methods to this backend
/// without an engine module dependency. The codegen builds a small
/// concrete instance pointing at its `*engine.Preview` and passes it
/// in via `preview_pbo.attach`.
pub const PreviewPboVtable = struct {
    ctx: *anyopaque,
    /// Linux/Windows SHM stream path.
    beginFrameStream: *const fn (ctx: *anyopaque, w: u32, h: u32) anyerror!void,
    publishFrame: *const fn (ctx: *anyopaque, pixels: []const u8) anyerror!void,
    endFrameStream: *const fn (ctx: *anyopaque) void,
    /// macOS IOSurface stream path (parallel triple — same lifecycle).
    beginFrameStreamIOSurface: *const fn (ctx: *anyopaque, w: u32, h: u32) anyerror!void,
    publishFrameIOSurface: *const fn (ctx: *anyopaque, pixels: []const u8) anyerror!void,
    endFrameStreamIOSurface: *const fn (ctx: *anyopaque) void,
    isFrameAccepted: *const fn (ctx: *anyopaque) bool,
};

pub const preview_pbo = struct {
    const is_macos = builtin.target.os.tag == .macos;

    // ── GL constants for PBO readback ──
    const GL_PIXEL_PACK_BUFFER: c_uint = 0x88EB;
    const GL_STREAM_READ: c_uint = 0x88E1;
    const GL_READ_ONLY: c_uint = 0x88B8;
    const GL_PACK_ALIGNMENT: c_uint = 0x0D05;
    const GL_RGBA: c_uint = 0x1908;
    const GL_UNSIGNED_BYTE: c_uint = 0x1401;

    const is_windows = builtin.target.os.tag == .windows;

    // ── GL 1.1 entry points: exported by opengl32.dll on Windows and by
    //    libGL/CGL elsewhere, so a direct @extern link reference resolves. ──
    const glPixelStorei = @extern(
        *const fn (pname: c_uint, param: c_int) callconv(.c) void,
        .{ .name = "glPixelStorei" },
    );
    const glReadPixels = @extern(
        *const fn (x: c_int, y: c_int, w: c_int, h: c_int, fmt: c_uint, ty: c_uint, data: ?*anyopaque) callconv(.c) void,
        .{ .name = "glReadPixels" },
    );

    // ── GL 2.0+ entry points (VBO/PBO): NOT exported by opengl32.dll on
    //    Windows — a link-time @extern there fails ("undefined symbol:
    //    glGenBuffers"). Resolve them at runtime via wglGetProcAddress once a
    //    GL context is current (raylib creates one in initWindow, before
    //    frame() runs). On Linux/macOS the libGL/CGL link provides them, so
    //    @extern stays. ──
    const GenBuffersFn = *const fn (n: c_int, buffers: [*]c_uint) callconv(.c) void;
    const DeleteBuffersFn = *const fn (n: c_int, buffers: [*]const c_uint) callconv(.c) void;
    const BindBufferFn = *const fn (target: c_uint, buffer: c_uint) callconv(.c) void;
    const BufferDataFn = *const fn (target: c_uint, size: isize, data: ?*const anyopaque, usage: c_uint) callconv(.c) void;
    const MapBufferFn = *const fn (target: c_uint, access: c_uint) callconv(.c) ?*anyopaque;
    const UnmapBufferFn = *const fn (target: c_uint) callconv(.c) u8;

    const Gl2 = struct {
        glGenBuffers: GenBuffersFn,
        glDeleteBuffers: DeleteBuffersFn,
        glBindBuffer: BindBufferFn,
        glBufferData: BufferDataFn,
        glMapBuffer: MapBufferFn,
        glUnmapBuffer: UnmapBufferFn,
    };

    extern fn wglGetProcAddress(name: [*:0]const u8) callconv(.c) ?*anyopaque;

    fn wglProc(comptime T: type, name: [*:0]const u8) ?T {
        const p = wglGetProcAddress(name) orelse return null;
        // Some ICDs signal failure with the sentinels 1, 2, 3, or -1
        // instead of null; treating those as callable pointers crashes.
        const addr = @intFromPtr(p);
        if (addr <= 3 or addr == std.math.maxInt(usize)) return null;
        return @ptrFromInt(addr);
    }

    var gl2_cache: ?Gl2 = null;

    /// Lazily resolve the GL 2.0+ entry points. Returns null if a GL context
    /// is not yet current (Windows) — the caller then no-ops for this frame.
    fn gl2() ?Gl2 {
        if (gl2_cache) |g| return g;
        const g: Gl2 = if (is_windows) .{
            .glGenBuffers = wglProc(GenBuffersFn, "glGenBuffers") orelse return null,
            .glDeleteBuffers = wglProc(DeleteBuffersFn, "glDeleteBuffers") orelse return null,
            .glBindBuffer = wglProc(BindBufferFn, "glBindBuffer") orelse return null,
            .glBufferData = wglProc(BufferDataFn, "glBufferData") orelse return null,
            .glMapBuffer = wglProc(MapBufferFn, "glMapBuffer") orelse return null,
            .glUnmapBuffer = wglProc(UnmapBufferFn, "glUnmapBuffer") orelse return null,
        } else .{
            .glGenBuffers = @extern(GenBuffersFn, .{ .name = "glGenBuffers" }),
            .glDeleteBuffers = @extern(DeleteBuffersFn, .{ .name = "glDeleteBuffers" }),
            .glBindBuffer = @extern(BindBufferFn, .{ .name = "glBindBuffer" }),
            .glBufferData = @extern(BufferDataFn, .{ .name = "glBufferData" }),
            .glMapBuffer = @extern(MapBufferFn, .{ .name = "glMapBuffer" }),
            .glUnmapBuffer = @extern(UnmapBufferFn, .{ .name = "glUnmapBuffer" }),
        };
        gl2_cache = g;
        return g;
    }

    // ── Module-scope state ──
    var allocator: std.mem.Allocator = undefined;
    var allocator_set: bool = false;
    var vt: ?PreviewPboVtable = null;
    var pbos: [3]c_uint = .{ 0, 0, 0 };
    var pbo_initialized: bool = false;
    var frame_idx: u64 = 0;
    var last_w: u32 = 0;
    var last_h: u32 = 0;
    var pixel_buf: []u8 = &[_]u8{};

    /// Wire the engine.Preview vtable + the allocator the backend uses
    /// for the CPU pixel-staging buffer. Called once after the gui's
    /// preview handshake succeeds, before the first frame.
    pub fn attach(vtable: PreviewPboVtable, alloc: std.mem.Allocator) void {
        vt = vtable;
        allocator = alloc;
        allocator_set = true;
    }

    /// Per-frame readback. Should be called between raylib's
    /// `endDrawing` and the swap (or wherever the swapchain is still
    /// readable). No-op if the editor hasn't accepted the stream yet.
    pub fn frame() void {
        const vtable = vt orelse return;
        if (!allocator_set) return;

        const sw_i = rl.getScreenWidth();
        const sh_i = rl.getScreenHeight();
        if (sw_i <= 0 or sh_i <= 0) return;
        const sw: u32 = @intCast(sw_i);
        const sh: u32 = @intCast(sh_i);
        const needed_bytes: usize = @as(usize, sw) * @as(usize, sh) * 4;

        // Resolve GL 2.0+ entry points (runtime-loaded on Windows). No-op the
        // frame if a GL context isn't current yet.
        const g = gl2() orelse return;
        const glGenBuffers = g.glGenBuffers;
        const glBindBuffer = g.glBindBuffer;
        const glBufferData = g.glBufferData;
        const glMapBuffer = g.glMapBuffer;
        const glUnmapBuffer = g.glUnmapBuffer;

        // Resize / first-frame: (re)negotiate the SHM ring with the editor
        // and (re)size the PBOs + CPU staging buffer.
        if (sw != last_w or sh != last_h) {
            if (is_macos) {
                vtable.beginFrameStreamIOSurface(vtable.ctx, sw, sh) catch return;
            } else {
                vtable.beginFrameStream(vtable.ctx, sw, sh) catch return;
            }
            if (!pbo_initialized) {
                glGenBuffers(3, &pbos);
                pbo_initialized = true;
            }
            glPixelStorei(GL_PACK_ALIGNMENT, 4);
            for (pbos) |pbo_id| {
                glBindBuffer(GL_PIXEL_PACK_BUFFER, pbo_id);
                glBufferData(GL_PIXEL_PACK_BUFFER, @intCast(needed_bytes), null, GL_STREAM_READ);
            }
            glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
            if (pixel_buf.len != needed_bytes) {
                if (pixel_buf.len != 0) allocator.free(pixel_buf);
                pixel_buf = allocator.alloc(u8, needed_bytes) catch &[_]u8{};
            }
            // Only commit the resize state when the CPU staging buffer
            // matches `needed_bytes` — otherwise the next frame would
            // see `sw == last_w and sh == last_h`, skip realloc, and
            // stall the preview indefinitely. Leaving these unchanged
            // means the next frame retries the (re)negotiation path.
            if (pixel_buf.len == needed_bytes) {
                last_w = sw;
                last_h = sh;
                frame_idx = 0;
            }
        }

        if (!vtable.isFrameAccepted(vtable.ctx) or pixel_buf.len != needed_bytes) return;

        // Async DMA into write PBO.
        const write_idx: usize = @intCast(frame_idx % 3);
        glBindBuffer(GL_PIXEL_PACK_BUFFER, pbos[write_idx]);
        glReadPixels(0, 0, sw_i, sh_i, GL_RGBA, GL_UNSIGNED_BYTE, null);

        // From frame 2 onwards, map the oldest PBO and publish.
        if (frame_idx >= 2) {
            const read_idx: usize = @intCast((frame_idx - 2) % 3);
            glBindBuffer(GL_PIXEL_PACK_BUFFER, pbos[read_idx]);
            const mapped_opt = glMapBuffer(GL_PIXEL_PACK_BUFFER, GL_READ_ONLY);
            if (mapped_opt) |src| {
                const src_ptr: [*]const u8 = @ptrCast(src);
                // GL returns rows bottom-up; editor expects top-down RGBA8.
                const row_bytes: usize = @as(usize, sw) * 4;
                var y: u32 = 0;
                while (y < sh) : (y += 1) {
                    const src_row = src_ptr + (@as(usize, sh - 1 - y) * row_bytes);
                    const dst_row = pixel_buf.ptr + (@as(usize, y) * row_bytes);
                    @memcpy(dst_row[0..row_bytes], src_row[0..row_bytes]);
                }
                _ = glUnmapBuffer(GL_PIXEL_PACK_BUFFER);
                if (is_macos) {
                    vtable.publishFrameIOSurface(vtable.ctx, pixel_buf) catch {};
                } else {
                    vtable.publishFrame(vtable.ctx, pixel_buf) catch {};
                }
            }
            // Map failed (driver bug / context loss) — skip this frame.
        }
        glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
        frame_idx +%= 1;
    }

    /// Tear-down hook. Frees the CPU buffer, deletes the PBOs, asks the
    /// engine to close the SHM/IOSurface ring. Safe to call when no
    /// stream was ever started.
    pub fn deinit() void {
        if (pixel_buf.len != 0) {
            if (allocator_set) allocator.free(pixel_buf);
            pixel_buf = &[_]u8{};
        }
        if (pbo_initialized) {
            if (gl2()) |g| g.glDeleteBuffers(3, &pbos);
            pbo_initialized = false;
            pbos = .{ 0, 0, 0 };
        }
        if (vt) |vtable| {
            if (is_macos) vtable.endFrameStreamIOSurface(vtable.ctx) else vtable.endFrameStream(vtable.ctx);
        }
        last_w = 0;
        last_h = 0;
        frame_idx = 0;
    }
};
