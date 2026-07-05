//! Sokol GL PBO readback snippets (labelle-assembler#122 slice 1).
//! Extracted from `preview.zig` (behavior-preserving).

/// Sokol-specific PBO readback (labelle-assembler#122 slice 1). Same
/// 3-deep PBO ring + 2-frame priming as raylib's `PREVIEW_READBACK_*`
/// (labelle-engine#544), reshaped for sokol's callback lifecycle:
///
///   - State (PBO ids, frame counter, last published dims, CPU staging
///     buffer) lives at *module scope* because the sokol `init` /
///     `frame` / `cleanup` callbacks have no shared local scope.
///   - GL externs are gated by `_sokol_preview_gl_enabled`, a comptime
///     boolean derived from `builtin.os.tag`. Default sokol build picks
///     GLCORE on Linux + GLES3 on Android/web, Metal on macOS/iOS,
///     D3D11 on Windows. Slice 1 only handles the GL paths; Metal /
///     D3D11 are deferred to slices 2 and 3 (#122 follow-ups). The
///     externs hide behind a struct-namespace so non-GL builds never
///     reference unresolved symbols at link time.
///   - The frame block + init seed + cleanup teardown are also gated
///     on the comptime flag — `comptime if (... ) { ... }` elides the
///     entire block on Metal/D3D11 targets, leaving the control-plane
///     wiring (hello/heartbeat/bye) intact but no pixel publish.
pub const PREVIEW_READBACK_HELPERS_SOKOL =
    \\
    \\// ── Sokol PBO readback gating (labelle-assembler#122 slice 1) ──
    \\// Default sokol-zig picks GLCORE on Linux desktop, GLES3 on Android
    \\// and emscripten, Metal on Darwin, D3D11 on Windows. The GL PBO
    \\// path only applies to the first two; Metal / D3D11 are separate
    \\// slices (IOSurface, staging). Comptime-gating on builtin.os.tag
    \\// keeps the GL externs out of non-GL link lines so e.g. a sokol
    \\// macOS build (Metal) doesn't fail to resolve `glReadPixels`.
    \\// Android in Zig is `os.tag == .linux` with `abi == .android` /
    \\// `.androideabi`, so the simple `.linux` arm already covers both
    \\// desktop GLCORE and Android GLES3. Emscripten / wasm32 is left
    \\// as a no-op for now — WebGL2 has limited PBO support and slice 1
    \\// doesn't ship a wasm story (see PR body / #122 follow-ups).
    \\const _sokol_preview_gl_enabled: bool = switch (@import("builtin").os.tag) {
    \\    .linux => true,
    \\    else => false,
    \\};
    \\
    \\// PBO state at module scope — sokol's init / frame / cleanup
    \\// callbacks are separate functions, so the locals raylib's main()
    \\// uses for the same purpose need to live at file scope here.
    \\// `_preview_allocator` mirrors the allocator the game uses; it's
    \\// stashed in the init callback so frame + cleanup can reach the
    \\// CPU staging buffer without re-deriving it from `g`.
    \\var _preview_allocator: std.mem.Allocator = std.mem.Allocator{ .ptr = undefined, .vtable = undefined };
    \\var _preview_pbos: [3]c_uint = .{ 0, 0, 0 };
    \\var _preview_pbo_bytes: usize = 0;
    \\var _preview_pbo_initialized: bool = false;
    \\var _preview_frame_idx: u64 = 0;
    \\var _preview_last_w: u32 = 0;
    \\var _preview_last_h: u32 = 0;
    \\var _preview_pixel_buf: []u8 = &[_]u8{};
    \\
    \\// GL extern decls live inside a struct-namespace gated on
    \\// `_sokol_preview_gl_enabled`. The `else struct {}` branch holds
    \\// no symbols, so a Metal / D3D11 sokol build never emits an
    \\// undefined-symbol reference to `glReadPixels` etc.
    \\const _SokolPreviewGl = if (_sokol_preview_gl_enabled) struct {
    \\    pub const PIXEL_PACK_BUFFER: c_uint = 0x88EB;
    \\    pub const STREAM_READ: c_uint = 0x88E1;
    \\    // GL_MAP_READ_BIT — bit-flag for glMapBufferRange's access.
    \\    // Core in GL 3.0+ AND GLES 3.0+; glMapBuffer is desktop-only
    \\    // and ships on GLES only as `GL_OES_mapbuffer`, so the range
    \\    // variant is the portable choice for Android GLES3 builds.
    \\    pub const MAP_READ_BIT: c_uint = 0x0001;
    \\    pub const PACK_ALIGNMENT: c_uint = 0x0D05;
    \\    pub const RGBA: c_uint = 0x1908;
    \\    pub const UNSIGNED_BYTE: c_uint = 0x1401;
    \\    pub const pixelStorei = @extern(
    \\        *const fn (pname: c_uint, param: c_int) callconv(.c) void,
    \\        .{ .name = "glPixelStorei" },
    \\    );
    \\    pub const genBuffers = @extern(
    \\        *const fn (n: c_int, buffers: [*]c_uint) callconv(.c) void,
    \\        .{ .name = "glGenBuffers" },
    \\    );
    \\    pub const deleteBuffers = @extern(
    \\        *const fn (n: c_int, buffers: [*]const c_uint) callconv(.c) void,
    \\        .{ .name = "glDeleteBuffers" },
    \\    );
    \\    pub const bindBuffer = @extern(
    \\        *const fn (target: c_uint, buffer: c_uint) callconv(.c) void,
    \\        .{ .name = "glBindBuffer" },
    \\    );
    \\    pub const bufferData = @extern(
    \\        *const fn (target: c_uint, size: isize, data: ?*const anyopaque, usage: c_uint) callconv(.c) void,
    \\        .{ .name = "glBufferData" },
    \\    );
    \\    pub const readPixels = @extern(
    \\        *const fn (x: c_int, y: c_int, w: c_int, h: c_int, fmt: c_uint, ty: c_uint, data: ?*anyopaque) callconv(.c) void,
    \\        .{ .name = "glReadPixels" },
    \\    );
    \\    pub const mapBufferRange = @extern(
    \\        *const fn (target: c_uint, offset: isize, length: isize, access: c_uint) callconv(.c) ?*anyopaque,
    \\        .{ .name = "glMapBufferRange" },
    \\    );
    \\    pub const unmapBuffer = @extern(
    \\        *const fn (target: c_uint) callconv(.c) u8,
    \\        .{ .name = "glUnmapBuffer" },
    \\    );
    \\} else struct {};
    \\
;

/// Init-callback addendum that stashes the game's allocator into the
/// module-scope `_preview_allocator` so the frame + cleanup callbacks
/// can grow / free the CPU staging buffer without reaching back through
/// `g`. Gated on `_sokol_preview_gl_enabled` for symmetry with the
/// other blocks — on non-GL targets the allocator slot stays at its
/// undefined sentinel but nothing ever calls through it.
pub const PREVIEW_READBACK_INIT_SOKOL =
    \\    if (comptime _sokol_preview_gl_enabled) {
    \\        _preview_allocator = allocator;
    \\    }
    \\
;

/// Per-frame PBO readback for sokol's `frame` callback. Comptime-gated
/// on `_sokol_preview_gl_enabled` — the entire block evaporates on
/// Metal / D3D11 builds, leaving only the heartbeat path intact.
///
/// Algorithm mirrors raylib's `PREVIEW_READBACK_LOOP` (#120):
///   - read current screen dims via `window.width()` / `window.height()`
///   - on resize / first frame, (re)negotiate the SHM ring with the
///     editor + (re)size the PBOs + CPU buffer + reset the priming
///     counter
///   - issue glReadPixels into `pbo[N % 3]` (async DMA)
///   - from frame 2 onwards, glMapBuffer `pbo[(N-2) % 3]` + memcpy
///     into the CPU buffer with bottom-up → top-down row flip, then
///     `publishFrame`
///
/// The flush ordering is the catch: sokol's `window.endFrame()` calls
/// `sg.endPass(); sg.commit();`. We inject the readback BEFORE
/// `window.endFrame()` so glReadPixels still hits the swapchain
/// framebuffer (FBO 0 / GL_BACK) before the swap. Same shape as
/// raylib's pre-`endFrame()` placement.
pub const PREVIEW_READBACK_FRAME_SOKOL =
    \\        if (comptime _sokol_preview_gl_enabled) {
    \\            if (g.preview) |*_p| _readback: {
    \\                const _sw_i = window.width();
    \\                const _sh_i = window.height();
    \\                if (_sw_i <= 0 or _sh_i <= 0) break :_readback;
    \\                const _sw: u32 = @intCast(_sw_i);
    \\                const _sh: u32 = @intCast(_sh_i);
    \\                const _needed_bytes: usize = @as(usize, _sw) * @as(usize, _sh) * 4;
    \\
    \\                if (_sw != _preview_last_w or _sh != _preview_last_h) {
    \\                    _p.beginFrameStream(_sw, _sh) catch break :_readback;
    \\                    if (!_preview_pbo_initialized) {
    \\                        _SokolPreviewGl.genBuffers(3, &_preview_pbos);
    \\                        _preview_pbo_initialized = true;
    \\                    }
    \\                    _SokolPreviewGl.pixelStorei(_SokolPreviewGl.PACK_ALIGNMENT, 4);
    \\                    for (_preview_pbos) |_pbo_id| {
    \\                        _SokolPreviewGl.bindBuffer(_SokolPreviewGl.PIXEL_PACK_BUFFER, _pbo_id);
    \\                        _SokolPreviewGl.bufferData(_SokolPreviewGl.PIXEL_PACK_BUFFER, @intCast(_needed_bytes), null, _SokolPreviewGl.STREAM_READ);
    \\                    }
    \\                    _SokolPreviewGl.bindBuffer(_SokolPreviewGl.PIXEL_PACK_BUFFER, 0);
    \\                    _preview_pbo_bytes = _needed_bytes;
    \\                    if (_preview_pixel_buf.len != _needed_bytes) {
    \\                        if (_preview_pixel_buf.len != 0) _preview_allocator.free(_preview_pixel_buf);
    \\                        _preview_pixel_buf = _preview_allocator.alloc(u8, _needed_bytes) catch &[_]u8{};
    \\                    }
    \\                    // Only commit the new dims once the CPU buffer
    \\                    // is the right size — otherwise a transient
    \\                    // alloc failure would leave us with `last_w/h`
    \\                    // matching the screen, skipping the resize block
    \\                    // on every subsequent frame and stranding the
    \\                    // readback in a permanent break state.
    \\                    if (_preview_pixel_buf.len == _needed_bytes) {
    \\                        _preview_last_w = _sw;
    \\                        _preview_last_h = _sh;
    \\                        _preview_frame_idx = 0;
    \\                    }
    \\                }
    \\
    \\                if (!_p.isFrameAccepted() or _preview_pixel_buf.len != _needed_bytes) break :_readback;
    \\
    \\                const _write_idx: usize = @intCast(_preview_frame_idx % 3);
    \\                _SokolPreviewGl.bindBuffer(_SokolPreviewGl.PIXEL_PACK_BUFFER, _preview_pbos[_write_idx]);
    \\                _SokolPreviewGl.readPixels(0, 0, _sw_i, _sh_i, _SokolPreviewGl.RGBA, _SokolPreviewGl.UNSIGNED_BYTE, null);
    \\
    \\                if (_preview_frame_idx >= 2) {
    \\                    const _read_idx: usize = @intCast((_preview_frame_idx - 2) % 3);
    \\                    _SokolPreviewGl.bindBuffer(_SokolPreviewGl.PIXEL_PACK_BUFFER, _preview_pbos[_read_idx]);
    \\                    const _mapped = _SokolPreviewGl.mapBufferRange(
    \\                        _SokolPreviewGl.PIXEL_PACK_BUFFER,
    \\                        0,
    \\                        @intCast(_preview_pbo_bytes),
    \\                        _SokolPreviewGl.MAP_READ_BIT,
    \\                    );
    \\                    if (_mapped) |_src| {
    \\                        const _src_ptr: [*]const u8 = @ptrCast(_src);
    \\                        const _row_bytes: usize = @as(usize, _sw) * 4;
    \\                        var _y: u32 = 0;
    \\                        while (_y < _sh) : (_y += 1) {
    \\                            const _src_row = _src_ptr + (@as(usize, _sh - 1 - _y) * _row_bytes);
    \\                            const _dst_row = _preview_pixel_buf.ptr + (@as(usize, _y) * _row_bytes);
    \\                            @memcpy(_dst_row[0.._row_bytes], _src_row[0.._row_bytes]);
    \\                        }
    \\                        // glUnmapBuffer returns GL_FALSE (0) if the
    \\                        // buffer contents became corrupt during the
    \\                        // map (e.g. context loss, screen-resolution
    \\                        // change racing with the readback). In that
    \\                        // case our memcpy above read garbage —
    \\                        // skip publishFrame so the editor doesn't
    \\                        // display a torn frame.
    \\                        if (_SokolPreviewGl.unmapBuffer(_SokolPreviewGl.PIXEL_PACK_BUFFER) != 0) {
    \\                            _p.publishFrame(_preview_pixel_buf) catch {};
    \\                        }
    \\                    }
    \\                }
    \\                _SokolPreviewGl.bindBuffer(_SokolPreviewGl.PIXEL_PACK_BUFFER, 0);
    \\                _preview_frame_idx +%= 1;
    \\            }
    \\        }
    \\
;

/// Cleanup-callback teardown for the sokol PBO ring. Runs BEFORE
/// `PREVIEW_CLEANUP_CALLBACK` (which sends the graceful `bye`) so the
/// engine still has its socket open when the producer tears down the
/// SHM ring — matches raylib's LIFO ordering. Gated on the same
/// `_sokol_preview_gl_enabled` flag; on non-GL builds the PBO state
/// is never initialized so there's nothing to free either.
pub const PREVIEW_READBACK_CLEANUP_SOKOL =
    \\    if (comptime _sokol_preview_gl_enabled) {
    \\        if (g.preview) |*_p| _p.endFrameStream();
    \\        if (_preview_pbo_initialized) _SokolPreviewGl.deleteBuffers(3, &_preview_pbos);
    \\        if (_preview_pixel_buf.len != 0) _preview_allocator.free(_preview_pixel_buf);
    \\    }
    \\
;
