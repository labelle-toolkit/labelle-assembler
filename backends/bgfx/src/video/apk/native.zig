//! Minimal NativeActivity native lib that verifies the Android AMediaCodec
//! decoder *inside a real app process* (FP#549 Half 2).
//!
//! The bare `adb shell` harness (`video/test_decode.zig`) proved AMediaExtractor
//! works on-device but couldn't create the codec — a CLI process lacks the
//! Binder threadpool + JVM/ART context the codec service needs. A NativeActivity
//! runs in a normal app process (forked from zygote, with ART + binder), so
//! AMediaCodec should succeed here. This is the on-device proof the CLI can't
//! give — and the same shell shape the real intro (Path B) would use.
//!
//! Flow: `ANativeActivity_onCreate` → open the bundled `dectest.mp4` asset via
//! AAssetManager → fd → `android.VideoDecoder` → decode frames → `__android_log`
//! the result (read back with `adb logcat`).

const std = @import("std");
const android = @import("android");
const audio = @import("audio");

extern "c" fn usleep(usec: u32) c_int;

const c = @cImport({
    @cInclude("decode_shim.h");
});

const TAG = "DECTEST";

fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    _ = c.__android_log_print(c.ANDROID_LOG_INFO, TAG, "%s", s.ptr);
}

/// NativeActivity entry point. The framework loads `libdecodetest.so` (named in
/// the manifest's `android.app.lib_name`) and calls this. We run the decode
/// test synchronously — it's fast (a handful of frames) so it won't ANR.
export fn ANativeActivity_onCreate(activity: *c.ANativeActivity, saved: ?*anyopaque, saved_size: usize) void {
    _ = saved;
    _ = saved_size;
    log("ANativeActivity_onCreate: running AMediaCodec decode test", .{});
    runTest(activity);
}

fn runTest(activity: *c.ANativeActivity) void {
    const am = activity.assetManager;
    if (am == null) {
        log("FAIL: no assetManager", .{});
        return;
    }

    const asset = c.AAssetManager_open(am, "dectest.mp4", c.AASSET_MODE_STREAMING);
    if (asset == null) {
        log("FAIL: asset open (dectest.mp4)", .{});
        return;
    }
    defer _ = c.AAsset_close(asset);

    // openFileDescriptor only works if the asset is stored UNCOMPRESSED in the
    // APK (packaged with aapt2 `-0 mp4`).
    var start: c.off64_t = 0;
    var length: c.off64_t = 0;
    const fd = c.AAsset_openFileDescriptor64(asset, &start, &length);
    if (fd < 0) {
        log("FAIL: openFileDescriptor (asset compressed?)", .{});
        return;
    }
    log("asset fd={d} start={d} len={d}", .{ fd, start, length });

    var dec = android.VideoDecoder.openFd(std.heap.page_allocator, fd, start, length) catch |e| {
        log("FAIL: decoder open: {s}", .{@errorName(e)});
        return;
    };
    defer dec.deinit();

    const w = dec.width();
    const h = dec.height();
    log("decoder ready: {d}x{d}", .{ w, h });
    if (w == 0 or h == 0) {
        log("FAIL: zero dimensions", .{});
        return;
    }

    const buf = std.heap.page_allocator.alloc(u8, @as(usize, w) * h * 4) catch {
        log("FAIL: alloc", .{});
        return;
    };
    defer std.heap.page_allocator.free(buf);

    var frames: u32 = 0;
    var tries: u32 = 0;
    while (frames < 10 and tries < 2000) : (tries += 1) {
        if (dec.decodeFrame(buf)) |_| {
            frames += 1;
            if (frames == 1) {
                log("frame0 px0 = ({d},{d},{d},{d})", .{ buf[0], buf[1], buf[2], buf[3] });
            }
        }
    }

    if (frames > 0) {
        log("RESULT PASS: decoded {d} frames in {d} tries", .{ frames, tries });
    } else {
        log("RESULT FAIL: no frames in {d} tries", .{tries});
    }

    // -- AAudio output device test (#306): start the device (mixing silence is
    // fine — we only need the callback to fire) and confirm it's pulling frames.
    audio.ensureInit();
    _ = usleep(500_000); // let the audio thread run ~0.5s
    const mixed = audio.deviceFramesMixed();
    log("AAUDIO frames mixed in ~0.5s = {d}", .{mixed});
    if (mixed > 0) {
        log("AAUDIO PASS: output device live (#306)", .{});
    } else {
        log("AAUDIO FAIL: device produced no frames", .{});
    }
    audio.deinit();
}
