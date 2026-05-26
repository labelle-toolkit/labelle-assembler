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
    // Single-row scratch — `h` can be in the thousands so heap-allocing
    // a half-buffer would be wasteful; one row's worth fits on the stack
    // for any sane resolution (4096 width × 4 = 16 KiB).
    var scratch: [4096 * 4]u8 = undefined;
    while (top < bot) : ({
        top += 1;
        bot -= 1;
    }) {
        const top_off = @as(usize, top) * stride;
        const bot_off = @as(usize, bot) * stride;
        const row_bytes = @min(stride, scratch.len);
        if (stride > scratch.len) {
            // Width > 4096 — extremely unusual; fall back to byte-wise
            // swap so we don't truncate.
            var i: usize = 0;
            while (i < stride) : (i += 1) {
                const tmp = buf[top_off + i];
                buf[top_off + i] = buf[bot_off + i];
                buf[bot_off + i] = tmp;
            }
        } else {
            @memcpy(scratch[0..row_bytes], buf[top_off .. top_off + row_bytes]);
            @memcpy(buf[top_off .. top_off + row_bytes], buf[bot_off .. bot_off + row_bytes]);
            @memcpy(buf[bot_off .. bot_off + row_bytes], scratch[0..row_bytes]);
        }
    }
}
