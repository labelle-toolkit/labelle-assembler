//! VideoPlayer — wires a video decoder to a bgfx dynamic texture
//! (FP#549 Path A: Half 2 decode → Half 1 display).
//!
//! Generic over the decoder so the same wiring drives either backend decoder:
//!   - desktop: `video/desktop.zig` (ffmpeg)
//!   - Android: `video/android.zig` (AMediaCodec)
//! A decoder just needs `width()`, `height()`, `decodeFrame([]u8) bool`, and
//! `deinit()`. The player owns the dynamic texture (`gfx/texture.zig`): it
//! creates one sized to the video, paces decoded frames to the clip fps, uploads
//! each via `updateTexture`, and draws it with `drawTexturePro`.

const std = @import("std");
const texture = @import("../gfx/texture.zig");
const types = @import("../gfx/types.zig");

pub fn Player(comptime Decoder: type) type {
    return struct {
        const Self = @This();

        decoder: Decoder,
        tex: types.Texture,
        pixels: []u8,
        allocator: std.mem.Allocator,
        accum: f32 = 0, // seconds toward the next frame
        frame_dt: f32,

        /// Take an already-opened decoder (opening is platform-specific), create
        /// a dynamic texture sized to it, and allocate the RGBA frame buffer.
        pub fn init(allocator: std.mem.Allocator, decoder: Decoder, fps: f32) !Self {
            var dec = decoder;
            const w = dec.width();
            const h = dec.height();
            const tex = try texture.createDynamicTexture(w, h);
            errdefer texture.unloadTexture(tex);
            const pixels = try allocator.alloc(u8, @as(usize, w) * h * 4);
            return .{
                .decoder = dec,
                .tex = tex,
                .pixels = pixels,
                .allocator = allocator,
                .frame_dt = if (fps > 0) 1.0 / fps else 1.0 / 24.0,
            };
        }

        /// Advance playback by `dt` seconds: when a frame is due, decode the next
        /// one and upload it to the GPU texture. Holds the last frame otherwise,
        /// so the render loop runs at its own rate without stalling on decode.
        pub fn update(self: *Self, dt: f32) void {
            self.accum += dt;
            if (self.accum < self.frame_dt) return;
            self.accum -= self.frame_dt;
            if (self.decoder.decodeFrame(self.pixels)) {
                texture.updateTexture(self.tex, self.pixels);
            }
        }

        /// Draw the current video frame into `dest` (screen or world space, per
        /// the active camera mode).
        pub fn draw(self: *const Self, dest: types.Rectangle) void {
            const src = types.Rectangle{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(self.tex.width),
                .height = @floatFromInt(self.tex.height),
            };
            texture.drawTexturePro(self.tex, src, dest, .{ .x = 0, .y = 0 }, 0, types.white);
        }

        pub fn deinit(self: *Self) void {
            self.decoder.deinit();
            texture.unloadTexture(self.tex);
            self.allocator.free(self.pixels);
        }
    };
}
