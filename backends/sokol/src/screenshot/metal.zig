//! Metal pixel readback for screenshot capture (labelle-assembler#213).
//!
//! Strategy: grab the current `CAMetalDrawable` from sokol_app, blit its
//! texture into a freshly-allocated MTLBuffer with storageModeShared
//! (macOS) / storageModeManaged + synchronize (iOS), then read bytes.
//! The drawable's native pixel format is BGRA8Unorm — we copy bytes
//! verbatim and let `screenshot.bmp.writeBmpFromBgra` skip the swizzle.
//!
//! Called from `window.takeScreenshot` AFTER `window.endFrame()`, which
//! ends with `sg.commit()` — the GPU queue has already submitted the
//! draw, and `sapp_metal_get_current_drawable` still points at the
//! frame's drawable until the next `frame_cb` begins. The blit encoder
//! we build here therefore runs against the just-presented texture.
//!
//! All libobjc plumbing lives behind explicit `@extern` declarations
//! so this file compiles cleanly on Darwin only (the wrapper in
//! `window.zig` gates the call on `comptime is_darwin`).

const std = @import("std");

// ── libobjc + Metal selector setup ────────────────────────────────────
// sokol_app.h exposes the current drawable as `const void*`; cast it
// back to an objc `id` (which `?*anyopaque` already models).
extern fn sapp_metal_get_current_drawable() ?*const anyopaque;

extern fn sel_registerName(name: [*:0]const u8) callconv(.c) ?*anyopaque;
const msgSend_void = @extern(
    *const fn (obj: ?*anyopaque, sel: ?*anyopaque) callconv(.c) void,
    .{ .name = "objc_msgSend" },
);
const msgSend_id = @extern(
    *const fn (obj: ?*anyopaque, sel: ?*anyopaque) callconv(.c) ?*anyopaque,
    .{ .name = "objc_msgSend" },
);
const msgSend_buf = @extern(
    *const fn (dev: ?*anyopaque, sel: ?*anyopaque, length: usize, opts: u64) callconv(.c) ?*anyopaque,
    .{ .name = "objc_msgSend" },
);
const msgSend_contents = @extern(
    *const fn (obj: ?*anyopaque, sel: ?*anyopaque) callconv(.c) ?*anyopaque,
    .{ .name = "objc_msgSend" },
);
const msgSend_copy = @extern(
    *const fn (
        encoder: ?*anyopaque,
        sel: ?*anyopaque,
        tex: ?*anyopaque,
        slice: usize,
        level: usize,
        origin_x: usize,
        origin_y: usize,
        origin_z: usize,
        size_w: usize,
        size_h: usize,
        size_d: usize,
        buf: ?*anyopaque,
        offset: usize,
        bytes_per_row: usize,
        bytes_per_image: usize,
    ) callconv(.c) void,
    .{ .name = "objc_msgSend" },
);
const msgSend_sync = @extern(
    *const fn (
        encoder: ?*anyopaque,
        sel: ?*anyopaque,
        buf: ?*anyopaque,
    ) callconv(.c) void,
    .{ .name = "objc_msgSend" },
);

// Storage modes — values are stable Metal enum constants.
const MTLResourceStorageModeShared: u64 = 0 << 4;
const MTLResourceStorageModeManaged: u64 = 1 << 4;

const is_macos = @import("builtin").target.os.tag == .macos;

/// Read the contents of the current drawable's texture into `out` (RGBA-
/// sized buffer, w*h*4 bytes). Returns true on success, false on any
/// readback step that can fail (no drawable, alloc failure, etc.).
///
/// `out` receives BGRA bytes on success — see `bmp.writeBmpFromBgra`.
/// `mtl_device` is the MTLDevice pointer (from `window.metalDevice()`).
pub fn readback(out: []u8, w: u32, h: u32, mtl_device: ?*const anyopaque) bool {
    const device = @as(?*anyopaque, @constCast(mtl_device)) orelse {
        std.log.warn("screenshot: Metal device unavailable", .{});
        return false;
    };
    const drawable = @as(?*anyopaque, @constCast(sapp_metal_get_current_drawable())) orelse {
        std.log.warn("screenshot: no current drawable (frame not rendered?)", .{});
        return false;
    };

    const sel_release = sel_registerName("release");
    const sel_texture = sel_registerName("texture");
    const sel_newCommandQueue = sel_registerName("newCommandQueue");
    const sel_commandBuffer = sel_registerName("commandBuffer");
    const sel_blitCommandEncoder = sel_registerName("blitCommandEncoder");
    const sel_endEncoding = sel_registerName("endEncoding");
    const sel_commit = sel_registerName("commit");
    const sel_waitUntilCompleted = sel_registerName("waitUntilCompleted");
    const sel_newBufferWithLength = sel_registerName("newBufferWithLength:options:");
    const sel_contents = sel_registerName("contents");
    const sel_copyFromTexture = sel_registerName(
        "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:",
    );
    const sel_synchronizeResource = sel_registerName("synchronizeResource:");

    const texture = msgSend_id(drawable, sel_texture) orelse {
        std.log.warn("screenshot: drawable has no texture", .{});
        return false;
    };

    const bytes_per_row: usize = @as(usize, w) * 4;
    const total: usize = bytes_per_row * @as(usize, h);
    if (out.len < total) {
        std.log.warn("screenshot: output buffer too small ({d} < {d})", .{ out.len, total });
        return false;
    }

    // macOS: storageModeShared so CPU + GPU view the same backing store
    // (no manual synchronize call needed). iOS: storageModeManaged isn't
    // valid on iOS at all (Shared is the only CPU-visible mode), so use
    // Shared everywhere — the synchronize call is then a no-op but kept
    // gated under is_macos so the macOS path doesn't pay for it.
    const storage_mode = MTLResourceStorageModeShared;

    const buffer = msgSend_buf(device, sel_newBufferWithLength, total, storage_mode) orelse {
        std.log.warn("screenshot: newBufferWithLength failed", .{});
        return false;
    };
    defer msgSend_void(buffer, sel_release);

    const queue = msgSend_id(device, sel_newCommandQueue) orelse {
        std.log.warn("screenshot: newCommandQueue failed", .{});
        return false;
    };
    defer msgSend_void(queue, sel_release);

    const cmd_buf = msgSend_id(queue, sel_commandBuffer) orelse {
        std.log.warn("screenshot: commandBuffer failed", .{});
        return false;
    };
    // commandBuffer is autoreleased — don't release manually.

    const blit = msgSend_id(cmd_buf, sel_blitCommandEncoder) orelse {
        std.log.warn("screenshot: blitCommandEncoder failed", .{});
        return false;
    };

    msgSend_copy(
        blit,
        sel_copyFromTexture,
        texture,
        0, // sourceSlice
        0, // sourceLevel
        0, // origin x
        0, // origin y
        0, // origin z
        @as(usize, w), // size w
        @as(usize, h), // size h
        1, // size d
        buffer,
        0, // dest offset
        bytes_per_row,
        total,
    );

    // On macOS with storageModeManaged the GPU's write must be flushed
    // back to CPU-visible memory via synchronizeResource: before reading.
    // Shared mode skips this — left in place as a comment-only marker
    // in case we revisit Managed-mode for cross-process readback.
    if (is_macos) {
        // No-op for Shared; would be required for Managed.
        _ = sel_synchronizeResource;
    }

    msgSend_void(blit, sel_endEncoding);
    msgSend_void(cmd_buf, sel_commit);
    msgSend_void(cmd_buf, sel_waitUntilCompleted);

    const contents = msgSend_contents(buffer, sel_contents) orelse {
        std.log.warn("screenshot: buffer.contents returned null", .{});
        return false;
    };
    const src_bytes: [*]const u8 = @ptrCast(contents);
    @memcpy(out[0..total], src_bytes[0..total]);
    return true;
}
