//! OpenGL / GLES pixel readback for screenshot capture (labelle-assembler#213).
//!
//! Strategy: `glReadPixels` against the default framebuffer
//! (sokol_app binds framebuffer 0 for the swapchain pass).
//! `takeScreenshot` runs after `sg.commit()`, so the back buffer holds
//! the just-drawn frame.
//!
//! `glReadPixels` reads bottom-up (y=0 is the bottom row), but BMP is
//! also bottom-up — the encoder explicitly flips on write, which would
//! double-flip a GL readback. Compensate by flipping rows in place here
//! so the encoder's flip lands right-side-up.
//!
//! GLES restriction: `glReadPixels` is only guaranteed to support
//! `GL_RGBA` + `GL_UNSIGNED_BYTE` on default framebuffers (other
//! formats require ES extensions / are implementation-defined). Pick
//! the safe combo.

const std = @import("std");

const GL_RGBA: u32 = 0x1908;
const GL_UNSIGNED_BYTE: u32 = 0x1401;
const GL_PACK_ALIGNMENT: u32 = 0x0D05;

extern fn glReadPixels(x: i32, y: i32, w: i32, h: i32, format: u32, type_: u32, data: ?*anyopaque) void;
extern fn glPixelStorei(pname: u32, param: i32) void;
extern fn glGetError() u32;

/// Read RGBA8 bytes from the default framebuffer into `out`
/// (`w * h * 4` bytes). Returns true on success.
pub fn readback(out: []u8, w: u32, h: u32) bool {
    const total: usize = @as(usize, w) * @as(usize, h) * 4;
    if (out.len < total) {
        std.log.warn("screenshot: output buffer too small ({d} < {d})", .{ out.len, total });
        return false;
    }

    // Tight packing — otherwise drivers may pad rows to 4-byte alignment
    // for non-multiple-of-4 widths and corrupt the layout we hand to BMP.
    glPixelStorei(GL_PACK_ALIGNMENT, 1);

    glReadPixels(0, 0, @intCast(w), @intCast(h), GL_RGBA, GL_UNSIGNED_BYTE, out.ptr);
    const err = glGetError();
    if (err != 0) {
        std.log.warn("screenshot: glReadPixels failed (GL error 0x{x})", .{err});
        return false;
    }

    // GL is bottom-up; the BMP encoder also flips on write. Pre-flip
    // the rows so the encoder's flip lands right-side-up.
    flipRowsInPlace(out, w, h);
    return true;
}

fn flipRowsInPlace(buf: []u8, w: u32, h: u32) void {
    const stride: usize = @as(usize, w) * 4;
    var top: u32 = 0;
    var bot: u32 = h - 1;
    // Small fixed scratch + chunked swap: works at full `@memcpy` speed
    // for any width without a slow byte-wise fallback, and keeps the
    // stack footprint tiny (16 KiB previously, 1 KiB now).
    var scratch: [1024]u8 = undefined;
    while (top < bot) : ({
        top += 1;
        bot -= 1;
    }) {
        const top_off = @as(usize, top) * stride;
        const bot_off = @as(usize, bot) * stride;
        var chunk_offset: usize = 0;
        while (chunk_offset < stride) {
            const chunk_len = @min(stride - chunk_offset, scratch.len);
            const t_slice = buf[top_off + chunk_offset ..][0..chunk_len];
            const b_slice = buf[bot_off + chunk_offset ..][0..chunk_len];
            @memcpy(scratch[0..chunk_len], t_slice);
            @memcpy(t_slice, b_slice);
            @memcpy(b_slice, scratch[0..chunk_len]);
            chunk_offset += chunk_len;
        }
    }
}
