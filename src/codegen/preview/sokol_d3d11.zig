//! Sokol D3D11 staging-texture readback snippets (labelle-assembler#126,
//! slice 2 of #122). Extracted from `preview.zig` (behavior-preserving).

/// Sokol D3D11 staging-texture readback helpers (labelle-assembler#126,
/// slice 2 of #122). Mirrors the structure of the GL block above but
/// targets default sokol-on-Windows builds, which use D3D11 instead of
/// GL. Windows has no IOSurface equivalent that crosses processes
/// cheaply, so the path is CPU-side `CopyResource` + `Map` + memcpy
/// into the SHM ring (same protocol the GL path uses via
/// `Preview.beginFrameStream` / `publishFrame`).
///
/// Sokol back-buffer access:
///   - `sg_d3d11_device()`         → `ID3D11Device*` (public sokol-gfx API)
///   - `sg_d3d11_device_context()` → `ID3D11DeviceContext*` (public)
///   - `sapp_d3d11_get_swap_chain()` → `IDXGISwapChain*` (public sokol-app API)
///   - `IDXGISwapChain::GetBuffer(0, IID_ID3D11Texture2D, &bb)` via COM
///     vtable dispatch → the resolved back-buffer `ID3D11Texture2D*`.
///
/// The COM vtable indices used here (`Map`=14, `Unmap`=15,
/// `CopyResource`=47 on `ID3D11DeviceContext`; `GetBuffer`=9 on
/// `IDXGISwapChain`; `CreateTexture2D`=5 on `ID3D11Device`;
/// `Release`=2 on every interface) are stable across the D3D11 ABI
/// since D3D11 shipped in 2009 — this is the same dispatch shape
/// every Windows graphics driver uses internally.
///
/// Format note: DXGI swapchains created by sokol default to
/// `DXGI_FORMAT_B8G8R8A8_UNORM` (BGRA8). The SHM consumer expects
/// RGBA8 (matching the GL `glReadPixels(GL_RGBA, ...)` shape), so the
/// memcpy below swizzles BGRA→RGBA per pixel. A future variant of the
/// SHM protocol that carries the source pixel format could skip the
/// swizzle and let the consumer handle channel order — out of scope
/// for this slice. DXGI back buffers are top-down (row 0 = top), so
/// no row flip is needed (unlike the GL path, where `glReadPixels`
/// returns rows bottom-up).
pub const PREVIEW_READBACK_HELPERS_SOKOL_D3D11 =
    \\
    \\// ── Sokol D3D11 readback gating (labelle-assembler#126) ──
    \\// Default sokol-zig picks D3D11 on Windows desktop. The staging-
    \\// texture readback path only applies there; on Linux/Android sokol
    \\// runs GLCORE/GLES3 (the block above), and on Darwin sokol runs
    \\// Metal (slice 3, #125). The `comptime`-gated externs and the
    \\// `struct {}` else branch keep the D3D11 entry points off the
    \\// link line for non-Windows targets.
    \\const _sokol_preview_d3d11_enabled: bool = @import("builtin").os.tag == .windows;
    \\
    \\// Staging-texture ring + book-keeping at module scope (same
    \\// rationale as the GL block — sokol's `init` / `frame` / `cleanup`
    \\// callbacks have no shared local stack frame).
    \\//
    \\// `_preview_d3d11_staging` holds 3 `ID3D11Texture2D*` (opaque)
    \\// allocated on the first frame / on resize; the publish loop
    \\// `CopyResource`s the back-buffer into slot `N % 3` and `Map`s
    \\// slot `(N-2) % 3` — same 3-deep ring + 2-frame priming gap as
    \\// the GL PBO path keeps DMA / GPU stalls out of the frame loop.
    \\var _preview_d3d11_staging: [3]?*anyopaque = .{ null, null, null };
    \\var _preview_d3d11_initialized: bool = false;
    \\
    \\// COM dispatch helpers. D3D11 / DXGI interfaces are layouts where
    \\// the first field is a pointer to a function-pointer vtable. We
    \\// only need a handful of methods, all at well-known stable
    \\// indices (see helpers doc-comment above). The IID below is
    \\// `IID_ID3D11Texture2D` — `{6F15AAF2-D208-4E89-9AB4-489535D34F9C}`
    \\// in little-endian DWORD/WORD byte order.
    \\const _SokolPreviewD3d11 = if (_sokol_preview_d3d11_enabled) struct {
    \\    // D3D11_USAGE_STAGING = 3; CPU_ACCESS_READ = 0x20000.
    \\    // D3D11_MAP_READ = 1; DXGI_FORMAT_B8G8R8A8_UNORM = 87.
    \\    pub const USAGE_STAGING: c_uint = 3;
    \\    pub const CPU_ACCESS_READ: c_uint = 0x20000;
    \\    pub const MAP_READ: c_uint = 1;
    \\    pub const FORMAT_B8G8R8A8_UNORM: c_uint = 87;
    \\
    \\    // `_Guid` mirrors Windows `GUID` / `IID` — 16 bytes, mixed
    \\    // endianness in the binary form. Hand-coded byte sequence
    \\    // avoids dragging in Win32 headers from the generated code.
    \\    pub const _Guid = extern struct {
    \\        data1: u32,
    \\        data2: u16,
    \\        data3: u16,
    \\        data4: [8]u8,
    \\    };
    \\    pub const IID_ID3D11Texture2D: _Guid = .{
    \\        .data1 = 0x6F15AAF2,
    \\        .data2 = 0xD208,
    \\        .data3 = 0x4E89,
    \\        .data4 = .{ 0x9A, 0xB4, 0x48, 0x95, 0x35, 0xD3, 0x4F, 0x9C },
    \\    };
    \\
    \\    // Mapped subresource layout — matches D3D11_MAPPED_SUBRESOURCE.
    \\    pub const MappedSubresource = extern struct {
    \\        data: ?*anyopaque,
    \\        row_pitch: u32,
    \\        depth_pitch: u32,
    \\    };
    \\
    \\    // D3D11_TEXTURE2D_DESC. SampleDesc is `{count, quality}`.
    \\    pub const Texture2DDesc = extern struct {
    \\        width: u32,
    \\        height: u32,
    \\        mip_levels: u32,
    \\        array_size: u32,
    \\        format: c_uint,
    \\        sample_count: u32,
    \\        sample_quality: u32,
    \\        usage: c_uint,
    \\        bind_flags: c_uint,
    \\        cpu_access_flags: c_uint,
    \\        misc_flags: c_uint,
    \\    };
    \\
    \\    // Sokol C-symbol entry points — `sg_d3d11_device()`,
    \\    // `sg_d3d11_device_context()`, `sapp_d3d11_get_swap_chain()`
    \\    // are part of the public sokol-gfx / sokol-app API and link
    \\    // into any sokol-on-Windows build via the sokol-zig dep.
    \\    pub const sgDevice = @extern(
    \\        *const fn () callconv(.c) ?*anyopaque,
    \\        .{ .name = "sg_d3d11_device" },
    \\    );
    \\    pub const sgDeviceContext = @extern(
    \\        *const fn () callconv(.c) ?*anyopaque,
    \\        .{ .name = "sg_d3d11_device_context" },
    \\    );
    \\    pub const sappSwapChain = @extern(
    \\        *const fn () callconv(.c) ?*anyopaque,
    \\        .{ .name = "sapp_d3d11_get_swap_chain" },
    \\    );
    \\
    \\    // `Object` is a placeholder for any COM interface pointer; the
    \\    // first field is always a pointer to the vtable, which is
    \\    // itself a `[*]const *const fn () callconv(.c) i32`. We dispatch
    \\    // by indexing into that table at the documented method index.
    \\    pub const Object = extern struct { vtbl: [*]const *const anyopaque };
    \\
    \\    /// IDXGISwapChain::GetBuffer — vtable index 9.
    \\    /// Signature: HRESULT GetBuffer(UINT Buffer, REFIID riid, void** ppSurface).
    \\    pub fn swapChainGetBuffer(sc: *anyopaque, buffer: u32, riid: *const _Guid, out: *?*anyopaque) i32 {
    \\        const obj: *Object = @ptrCast(@alignCast(sc));
    \\        const fp: *const fn (*anyopaque, u32, *const _Guid, *?*anyopaque) callconv(.c) i32 = @ptrCast(obj.vtbl[9]);
    \\        return fp(sc, buffer, riid, out);
    \\    }
    \\
    \\    /// ID3D11Device::CreateTexture2D — vtable index 5.
    \\    /// Signature: HRESULT CreateTexture2D(const D3D11_TEXTURE2D_DESC*, const D3D11_SUBRESOURCE_DATA*, ID3D11Texture2D**).
    \\    pub fn deviceCreateTexture2D(dev: *anyopaque, desc: *const Texture2DDesc, out: *?*anyopaque) i32 {
    \\        const obj: *Object = @ptrCast(@alignCast(dev));
    \\        const fp: *const fn (*anyopaque, *const Texture2DDesc, ?*const anyopaque, *?*anyopaque) callconv(.c) i32 = @ptrCast(obj.vtbl[5]);
    \\        return fp(dev, desc, null, out);
    \\    }
    \\
    \\    /// ID3D11DeviceContext::Map — vtable index 14.
    \\    /// Signature: HRESULT Map(ID3D11Resource*, UINT subresource, D3D11_MAP, UINT flags, D3D11_MAPPED_SUBRESOURCE*).
    \\    pub fn contextMap(ctx: *anyopaque, resource: *anyopaque, subresource: u32, map_type: c_uint, flags: u32, out: *MappedSubresource) i32 {
    \\        const obj: *Object = @ptrCast(@alignCast(ctx));
    \\        const fp: *const fn (*anyopaque, *anyopaque, u32, c_uint, u32, *MappedSubresource) callconv(.c) i32 = @ptrCast(obj.vtbl[14]);
    \\        return fp(ctx, resource, subresource, map_type, flags, out);
    \\    }
    \\
    \\    /// ID3D11DeviceContext::Unmap — vtable index 15.
    \\    /// Signature: void Unmap(ID3D11Resource*, UINT subresource).
    \\    pub fn contextUnmap(ctx: *anyopaque, resource: *anyopaque, subresource: u32) void {
    \\        const obj: *Object = @ptrCast(@alignCast(ctx));
    \\        const fp: *const fn (*anyopaque, *anyopaque, u32) callconv(.c) void = @ptrCast(obj.vtbl[15]);
    \\        fp(ctx, resource, subresource);
    \\    }
    \\
    \\    /// ID3D11DeviceContext::CopyResource — vtable index 47.
    \\    /// Signature: void CopyResource(ID3D11Resource* dst, ID3D11Resource* src).
    \\    pub fn contextCopyResource(ctx: *anyopaque, dst: *anyopaque, src: *anyopaque) void {
    \\        const obj: *Object = @ptrCast(@alignCast(ctx));
    \\        const fp: *const fn (*anyopaque, *anyopaque, *anyopaque) callconv(.c) void = @ptrCast(obj.vtbl[47]);
    \\        fp(ctx, dst, src);
    \\    }
    \\
    \\    /// IUnknown::Release — vtable index 2. Used to release the
    \\    /// AddRef'd back-buffer pointer from `GetBuffer` and to drop
    \\    /// the staging textures on cleanup / resize.
    \\    pub fn release(obj_ptr: *anyopaque) u32 {
    \\        const obj: *Object = @ptrCast(@alignCast(obj_ptr));
    \\        const fp: *const fn (*anyopaque) callconv(.c) u32 = @ptrCast(obj.vtbl[2]);
    \\        return fp(obj_ptr);
    \\    }
    \\} else struct {};
    \\
;

/// Init-callback addendum for the D3D11 staging-texture ring. Stashes
/// the allocator into the shared module-scope slot (`_preview_allocator`)
/// so the frame + cleanup callbacks can grow / free the CPU staging
/// buffer. The GL block stashes the same slot — both blocks are
/// mutually exclusive at comptime (`.linux` vs `.windows`), so only
/// one ever runs.
pub const PREVIEW_READBACK_INIT_SOKOL_D3D11 =
    \\    if (comptime _sokol_preview_d3d11_enabled) {
    \\        _preview_allocator = allocator;
    \\    }
    \\
;

/// Per-frame D3D11 readback for sokol's `frame` callback. Comptime-gated
/// on `_sokol_preview_d3d11_enabled` — the entire block evaporates on
/// non-Windows builds, leaving only the heartbeat path intact.
///
/// Algorithm mirrors the GL path (`PREVIEW_READBACK_FRAME_SOKOL`):
///   - read current screen dims via `window.width()` / `window.height()`
///   - on resize / first frame, (re)negotiate the SHM ring with the
///     editor + (re)create the 3-deep staging-texture ring + reset the
///     priming counter
///   - `IDXGISwapChain::GetBuffer(0)` → resolved back-buffer Texture2D
///   - `ID3D11DeviceContext::CopyResource(staging[N % 3], backbuffer)`
///   - release the back-buffer reference
///   - from frame 2 onwards, `Map(staging[(N-2) % 3], D3D11_MAP_READ)` +
///     memcpy with BGRA→RGBA swizzle into `_preview_pixel_buf`, then
///     `publishFrame`
///
/// Sokol's `window.endFrame()` calls `sg.endPass(); sg.commit();`. We
/// inject this BEFORE `endFrame()` so `CopyResource` queues up after
/// all of sokol's draw calls but before the swap — matching the GL
/// path's pre-commit placement and ensuring the staging copy reflects
/// the rendered frame, not the next one.
pub const PREVIEW_READBACK_FRAME_SOKOL_D3D11 =
    \\        if (comptime _sokol_preview_d3d11_enabled) {
    \\            if (g.preview) |*_p| _readback_d3d11: {
    \\                const _sw_i = window.width();
    \\                const _sh_i = window.height();
    \\                if (_sw_i <= 0 or _sh_i <= 0) break :_readback_d3d11;
    \\                const _sw: u32 = @intCast(_sw_i);
    \\                const _sh: u32 = @intCast(_sh_i);
    \\                const _needed_bytes: usize = @as(usize, _sw) * @as(usize, _sh) * 4;
    \\
    \\                const _device_opt = _SokolPreviewD3d11.sgDevice();
    \\                const _ctx_opt = _SokolPreviewD3d11.sgDeviceContext();
    \\                const _swap_opt = _SokolPreviewD3d11.sappSwapChain();
    \\                if (_device_opt == null or _ctx_opt == null or _swap_opt == null) break :_readback_d3d11;
    \\                const _device = @as(*anyopaque, @ptrCast(@constCast(_device_opt.?)));
    \\                const _ctx = @as(*anyopaque, @ptrCast(@constCast(_ctx_opt.?)));
    \\                const _swap = @as(*anyopaque, @ptrCast(@constCast(_swap_opt.?)));
    \\
    \\                if (_sw != _preview_last_w or _sh != _preview_last_h) {
    \\                    _p.beginFrameStream(_sw, _sh) catch break :_readback_d3d11;
    \\                    // Tear down the old ring (if any) before creating
    \\                    // the new one — staging dims must match the
    \\                    // back-buffer or `CopyResource` will fail silently.
    \\                    if (_preview_d3d11_initialized) {
    \\                        for (&_preview_d3d11_staging) |*_slot| {
    \\                            if (_slot.*) |_p_ptr| {
    \\                                _ = _SokolPreviewD3d11.release(_p_ptr);
    \\                                _slot.* = null;
    \\                            }
    \\                        }
    \\                    }
    \\                    const _staging_desc: _SokolPreviewD3d11.Texture2DDesc = .{
    \\                        .width = _sw,
    \\                        .height = _sh,
    \\                        .mip_levels = 1,
    \\                        .array_size = 1,
    \\                        .format = _SokolPreviewD3d11.FORMAT_B8G8R8A8_UNORM,
    \\                        .sample_count = 1,
    \\                        .sample_quality = 0,
    \\                        .usage = _SokolPreviewD3d11.USAGE_STAGING,
    \\                        .bind_flags = 0,
    \\                        .cpu_access_flags = _SokolPreviewD3d11.CPU_ACCESS_READ,
    \\                        .misc_flags = 0,
    \\                    };
    \\                    var _alloc_ok = true;
    \\                    for (&_preview_d3d11_staging) |*_slot| {
    \\                        var _new_tex: ?*anyopaque = null;
    \\                        const _hr = _SokolPreviewD3d11.deviceCreateTexture2D(_device, &_staging_desc, &_new_tex);
    \\                        if (_hr < 0 or _new_tex == null) {
    \\                            _alloc_ok = false;
    \\                            break;
    \\                        }
    \\                        _slot.* = _new_tex;
    \\                    }
    \\                    if (!_alloc_ok) {
    \\                        // Rollback any partial ring on failure so the
    \\                        // next resize attempt starts clean.
    \\                        for (&_preview_d3d11_staging) |*_slot| {
    \\                            if (_slot.*) |_p_ptr| {
    \\                                _ = _SokolPreviewD3d11.release(_p_ptr);
    \\                                _slot.* = null;
    \\                            }
    \\                        }
    \\                        break :_readback_d3d11;
    \\                    }
    \\                    _preview_d3d11_initialized = true;
    \\                    if (_preview_pixel_buf.len != _needed_bytes) {
    \\                        if (_preview_pixel_buf.len != 0) _preview_allocator.free(_preview_pixel_buf);
    \\                        _preview_pixel_buf = _preview_allocator.alloc(u8, _needed_bytes) catch &[_]u8{};
    \\                    }
    \\                    // Only commit the new dims once the CPU buffer is
    \\                    // the right size — same recovery logic as the GL
    \\                    // path. A transient alloc failure leaves
    \\                    // `last_w/h` stale so the next frame re-runs the
    \\                    // resize block.
    \\                    if (_preview_pixel_buf.len == _needed_bytes) {
    \\                        _preview_last_w = _sw;
    \\                        _preview_last_h = _sh;
    \\                        _preview_frame_idx = 0;
    \\                    }
    \\                }
    \\
    \\                if (!_p.isFrameAccepted() or _preview_pixel_buf.len != _needed_bytes or !_preview_d3d11_initialized) break :_readback_d3d11;
    \\
    \\                // Grab the back-buffer (Buffer 0 in DXGI; that's the
    \\                // resolved swap-chain surface, top-down origin). The
    \\                // returned pointer is AddRef'd by `GetBuffer` — we
    \\                // must `Release` after `CopyResource` to keep DXGI
    \\                // from leaking the reference across resizes.
    \\                var _backbuffer: ?*anyopaque = null;
    \\                const _hr_get = _SokolPreviewD3d11.swapChainGetBuffer(_swap, 0, &_SokolPreviewD3d11.IID_ID3D11Texture2D, &_backbuffer);
    \\                if (_hr_get < 0 or _backbuffer == null) break :_readback_d3d11;
    \\                defer _ = _SokolPreviewD3d11.release(_backbuffer.?);
    \\
    \\                const _write_idx: usize = @intCast(_preview_frame_idx % 3);
    \\                const _write_tex = _preview_d3d11_staging[_write_idx] orelse break :_readback_d3d11;
    \\                _SokolPreviewD3d11.contextCopyResource(_ctx, _write_tex, _backbuffer.?);
    \\
    \\                if (_preview_frame_idx >= 2) {
    \\                    const _read_idx: usize = @intCast((_preview_frame_idx - 2) % 3);
    \\                    const _read_tex = _preview_d3d11_staging[_read_idx] orelse break :_readback_d3d11;
    \\                    var _mapped: _SokolPreviewD3d11.MappedSubresource = .{ .data = null, .row_pitch = 0, .depth_pitch = 0 };
    \\                    const _hr_map = _SokolPreviewD3d11.contextMap(_ctx, _read_tex, 0, _SokolPreviewD3d11.MAP_READ, 0, &_mapped);
    \\                    if (_hr_map >= 0 and _mapped.data != null) {
    \\                        const _src_base: [*]const u8 = @ptrCast(_mapped.data.?);
    \\                        const _row_bytes: usize = @as(usize, _sw) * 4;
    \\                        const _row_pitch: usize = @intCast(_mapped.row_pitch);
    \\                        var _y: u32 = 0;
    \\                        // DXGI back buffers are top-down (row 0 = top),
    \\                        // so no row-flip — but the swapchain format is
    \\                        // BGRA8 while the SHM consumer expects RGBA8,
    \\                        // so swizzle channels 0/2 per pixel during the
    \\                        // copy. `row_pitch` from `Map` may be padded
    \\                        // above `width*4`, so we walk pitched rows
    \\                        // explicitly instead of treating the staging
    \\                        // texture as a flat array.
    \\                        while (_y < _sh) : (_y += 1) {
    \\                            const _src_row = _src_base + (@as(usize, _y) * _row_pitch);
    \\                            const _dst_row = _preview_pixel_buf.ptr + (@as(usize, _y) * _row_bytes);
    \\                            var _x: u32 = 0;
    \\                            while (_x < _sw) : (_x += 1) {
    \\                                const _off: usize = @as(usize, _x) * 4;
    \\                                _dst_row[_off + 0] = _src_row[_off + 2];
    \\                                _dst_row[_off + 1] = _src_row[_off + 1];
    \\                                _dst_row[_off + 2] = _src_row[_off + 0];
    \\                                _dst_row[_off + 3] = _src_row[_off + 3];
    \\                            }
    \\                        }
    \\                        _SokolPreviewD3d11.contextUnmap(_ctx, _read_tex, 0);
    \\                        _p.publishFrame(_preview_pixel_buf) catch {};
    \\                    } else if (_hr_map >= 0) {
    \\                        // Map succeeded but returned a null pointer —
    \\                        // pair the call with Unmap anyway so the
    \\                        // staging texture isn't left in a mapped
    \\                        // state.
    \\                        _SokolPreviewD3d11.contextUnmap(_ctx, _read_tex, 0);
    \\                    }
    \\                }
    \\                _preview_frame_idx +%= 1;
    \\            }
    \\        }
    \\
;

/// Cleanup-callback teardown for the sokol D3D11 staging-texture ring.
/// Runs BEFORE `PREVIEW_CLEANUP_CALLBACK` (which sends the graceful
/// `bye`), matching the GL block's LIFO ordering. Gated on
/// `_sokol_preview_d3d11_enabled`; on non-Windows builds the staging
/// state is never initialized so there's nothing to free either.
///
/// Shares `_preview_pixel_buf` with the GL block, but since the two
/// blocks are mutually exclusive at comptime only one cleanup path
/// ever runs — the buffer is freed exactly once.
pub const PREVIEW_READBACK_CLEANUP_SOKOL_D3D11 =
    \\    if (comptime _sokol_preview_d3d11_enabled) {
    \\        if (g.preview) |*_p| _p.endFrameStream();
    \\        if (_preview_d3d11_initialized) {
    \\            for (&_preview_d3d11_staging) |*_slot| {
    \\                if (_slot.*) |_p_ptr| {
    \\                    _ = _SokolPreviewD3d11.release(_p_ptr);
    \\                    _slot.* = null;
    \\                }
    \\            }
    \\            _preview_d3d11_initialized = false;
    \\        }
    \\        if (_preview_pixel_buf.len != 0) _preview_allocator.free(_preview_pixel_buf);
    \\    }
    \\
;
