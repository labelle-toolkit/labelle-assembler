//! VideoBackend — satisfies labelle-core's VideoInterface (FP#549).
//!
//! A small handle pool over `VideoPlayer`: the engine/game calls `openVideo` by
//! resource name, and this resolves the name to a clip and builds the right
//! per-platform decoder + player. So a project plays a video with *just the
//! asset name* (a `VideoComponent` or `game.openVideo("intro")`), no path or
//! codec knowledge needed.
//!
//! Name resolution (until a generated catalog lands):
//!   - desktop: `assets/<name>` (probed for native size/fps via ffprobe).
//!   - Android: the `<name>` asset in the APK, via the bgfx shell's running
//!     NativeActivity AAssetManager.
//!
//! Audio note: in-engine audio for these players needs the audio *module*'s
//! mixer, which the gfx module must not import (it would fork a second mixer).
//! So this first cut is video-only; audio is wired via an injection seam (the
//! player's AudioHooks, fed by the assembler) in a follow-up. The decode/audio/
//! AAudio path is already proven in the example + bgfx-Android app.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("../gfx/types.zig");
const player_mod = @import("player.zig");
const desktop = @import("desktop.zig");
const android = @import("android.zig");

const is_android = builtin.abi == .android or builtin.abi == .androideabi;
const Decoder = if (is_android) android.VideoDecoder else desktop.VideoDecoder;

// Android asset access: the bgfx Android shell exposes the running
// NativeActivity (C export); its AAssetManager resolves bundled clips by name.
extern fn labelle_bgfx_get_native_activity() ?*anyopaque;
const AAssetManager = opaque {};
const AAsset = opaque {};
extern fn AAssetManager_open(*AAssetManager, [*:0]const u8, c_int) ?*AAsset;
extern fn AAsset_openFileDescriptor64(*AAsset, *i64, *i64) c_int;
extern fn AAsset_close(*AAsset) void;
const AASSET_MODE_STREAMING: c_int = 2;

pub const VideoBackend = struct {
    const Player = player_mod.Player(Decoder);
    const MAX = 8;

    const Slot = struct {
        player: Player = undefined,
        w: u32 = 0,
        h: u32 = 0,
        used: bool = false,
    };

    var slots: [MAX]Slot = [_]Slot{.{}} ** MAX;
    const alloc = std.heap.page_allocator;

    fn freeSlot() ?usize {
        for (&slots, 0..) |*s, i| if (!s.used) return i;
        return null;
    }
    fn slotPtr(id: u32) ?*Slot {
        if (id == 0 or id > MAX) return null;
        const s = &slots[id - 1];
        return if (s.used) s else null;
    }

    /// Open a video by resource name. Returns a handle (0 = failure).
    pub fn openVideo(name: [:0]const u8) u32 {
        const idx = freeSlot() orelse return 0;
        if (is_android) {
            const act = labelle_bgfx_get_native_activity() orelse return 0;
            // ANativeActivity field 8 is `assetManager` (callbacks, vm, env,
            // clazz, internalDataPath, externalDataPath, sdkVersion, instance,
            // assetManager…).
            const fields: [*]const ?*anyopaque = @ptrCast(@alignCast(act));
            const am: *AAssetManager = @ptrCast(fields[8] orelse return 0);
            const asset = AAssetManager_open(am, name, AASSET_MODE_STREAMING) orelse return 0;
            defer AAsset_close(asset);
            var start: i64 = 0;
            var len: i64 = 0;
            const fd = AAsset_openFileDescriptor64(asset, &start, &len);
            if (fd < 0) return 0;
            var dec = android.VideoDecoder.openFd(alloc, fd, start, len) catch return 0;
            const w = dec.width();
            const h = dec.height();
            const pl = Player.init(alloc, dec, 24.0) catch {
                dec.deinit();
                return 0;
            };
            slots[idx] = .{ .player = pl, .w = w, .h = h, .used = true };
        } else {
            var pathbuf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&pathbuf, "assets/{s}", .{name}) catch return 0;
            const info = desktop.probe(alloc, path) orelse return 0;
            const dec = desktop.VideoDecoder.open(alloc, path, info.w, info.h, info.fps) catch return 0;
            const pl = Player.init(alloc, dec, info.fps) catch return 0;
            slots[idx] = .{ .player = pl, .w = info.w, .h = info.h, .used = true };
        }
        return @intCast(idx + 1);
    }

    pub fn updateVideo(id: u32, dt: f32) void {
        if (slotPtr(id)) |s| s.player.update(dt);
    }

    pub fn drawVideo(id: u32, x: f32, y: f32, w: f32, h: f32) void {
        if (slotPtr(id)) |s| s.player.draw(.{ .x = x, .y = y, .width = w, .height = h });
    }

    pub fn isVideoPlaying(id: u32) bool {
        return slotPtr(id) != null;
    }

    pub fn videoDimensions(id: u32) struct { w: u32, h: u32 } {
        if (slotPtr(id)) |s| return .{ .w = s.w, .h = s.h };
        return .{ .w = 0, .h = 0 };
    }

    pub fn closeVideo(id: u32) void {
        if (slotPtr(id)) |s| {
            s.player.deinit();
            s.used = false;
        }
    }
};
