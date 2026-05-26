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

pub fn initWindow(width: i32, height: i32, title: [:0]const u8) void {
    rl.initWindow(width, height, title);
    rl.setExitKey(.escape);
}

pub fn closeWindow() void {
    rl.closeWindow();
}

pub fn windowShouldClose() bool {
    return rl.windowShouldClose();
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

/// Returns true if `path` is an absolute filesystem path.
///
/// POSIX: leading '/'.
/// Windows: drive-letter form ("C:\foo" / "C:/foo") or leading
/// backslash ("\foo"). The drive-letter case is detected via the ':'
/// at index 1 — anything else is treated as relative (raylib will
/// then prepend cwd, which is the behavior the relative branch
/// already relies on).
fn isAbsolutePath(path: [:0]const u8) bool {
    if (path.len == 0) return false;
    if (builtin.target.os.tag == .windows) {
        if (path[0] == '\\' or path[0] == '/') return true;
        if (path.len >= 3 and path[1] == ':' and (path[2] == '\\' or path[2] == '/')) return true;
        return false;
    }
    return path[0] == '/';
}

/// raylib's `TakeScreenshot` unconditionally prepends the binary's
/// current working directory to the path it's handed, mangling
/// absolute targets like `/tmp/foo.png` into
/// `<cwd>//tmp/foo.png` (see labelle-assembler#224). For absolute
/// paths we work around it by asking raylib to write to a relative
/// temp file inside cwd and then renaming that file to the intended
/// absolute target via libc `rename` (which handles absolute paths
/// fine on every platform). Relative paths flow through unchanged.
pub fn takeScreenshot(path: [:0]const u8) void {
    if (!isAbsolutePath(path)) {
        rl.takeScreenshot(path);
        return;
    }

    // Pick a process-unique temp name so concurrent renderers (or a
    // crashed previous run) can't clobber each other's intermediate
    // file. `.png` extension matters — raylib picks the encoder by
    // looking at the extension.
    var name_buf: [64]u8 = undefined;
    const pid: i32 = if (builtin.target.os.tag == .windows) 0 else @intCast(std.c.getpid());
    const tmp_name = std.fmt.bufPrintZ(
        &name_buf,
        "_labelle_screenshot_{d}.png",
        .{pid},
    ) catch {
        // bufPrintZ only fails if the buffer is too small; 64 bytes
        // is far more than the formatted name needs, but if we ever
        // hit it, fall through to a fixed name.
        const fallback: [:0]const u8 = "_labelle_screenshot.png";
        rl.takeScreenshot(fallback);
        _ = std.c.rename(fallback.ptr, path.ptr);
        return;
    };

    rl.takeScreenshot(tmp_name);
    // `rename` accepts the relative tmp path (resolved against the
    // process cwd — the same cwd raylib just wrote into) and an
    // absolute destination. On failure, try to delete the stale
    // tmp file so it doesn't accumulate in cwd. POSIX `unlink` is
    // ubiquitous; on Windows we fall through and leave the file —
    // Option A's main consumer is desktop labelle, and on Windows
    // the tmp file just lingers harmlessly until the next run
    // overwrites it (same fixed name shape, same process cwd).
    if (std.c.rename(tmp_name.ptr, path.ptr) != 0) {
        if (builtin.target.os.tag != .windows) {
            _ = std.c.unlink(tmp_name.ptr);
        }
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

    // ── GL extern decls — raylib's libGL/CGL/WGL link gives us these. ──
    const glPixelStorei = @extern(
        *const fn (pname: c_uint, param: c_int) callconv(.c) void,
        .{ .name = "glPixelStorei" },
    );
    const glGenBuffers = @extern(
        *const fn (n: c_int, buffers: [*]c_uint) callconv(.c) void,
        .{ .name = "glGenBuffers" },
    );
    const glDeleteBuffers = @extern(
        *const fn (n: c_int, buffers: [*]const c_uint) callconv(.c) void,
        .{ .name = "glDeleteBuffers" },
    );
    const glBindBuffer = @extern(
        *const fn (target: c_uint, buffer: c_uint) callconv(.c) void,
        .{ .name = "glBindBuffer" },
    );
    const glBufferData = @extern(
        *const fn (target: c_uint, size: isize, data: ?*const anyopaque, usage: c_uint) callconv(.c) void,
        .{ .name = "glBufferData" },
    );
    const glReadPixels = @extern(
        *const fn (x: c_int, y: c_int, w: c_int, h: c_int, fmt: c_uint, ty: c_uint, data: ?*anyopaque) callconv(.c) void,
        .{ .name = "glReadPixels" },
    );
    const glMapBuffer = @extern(
        *const fn (target: c_uint, access: c_uint) callconv(.c) ?*anyopaque,
        .{ .name = "glMapBuffer" },
    );
    const glUnmapBuffer = @extern(
        *const fn (target: c_uint) callconv(.c) u8,
        .{ .name = "glUnmapBuffer" },
    );

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
            glDeleteBuffers(3, &pbos);
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
