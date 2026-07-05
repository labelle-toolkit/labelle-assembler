//! Preview-mode codegen string templates extracted from `main_zig.zig`
//! (part of labelle-toolkit/labelle-assembler#183). All snippets are
//! pure string literals consumed by `generateMainZigFromTemplate` via
//! `std.mem.concat` — no logic lives here. See
//! `docs/REFACTOR-PLAN-main-zig.md` for the full cut plan.
//!
//! ── Barrel ──────────────────────────────────────────────────────────
//! This file was a single ~1300-line module; it is now a thin barrel that
//! re-exports the public surface from focused sub-modules under `preview/`
//! (behavior-preserving split). Every symbol keeps its original name and
//! identity so existing `preview.<Name>` call sites are unchanged:
//!
//!   - `preview/wasm_workaround.zig` — Zig 0.16 wasm32-emscripten panic /
//!                                     debug-io workarounds
//!   - `preview/helpers.zig`         — module-scope clock/getenv helper +
//!                                     raylib desktop PBO readback bridges
//!   - `preview/loop.zig`            — loop-backend snippets (raylib/sdl/
//!                                     bgfx/wgpu): setup, readback, heartbeat,
//!                                     input dispatch
//!   - `preview/callback.zig`        — callback-backend snippets (sokol,
//!                                     raylib wasm): init/cleanup/heartbeat
//!   - `preview/sokol_gl.zig`        — sokol GL PBO readback
//!   - `preview/sokol_d3d11.zig`     — sokol D3D11 staging-texture readback
//!   - `preview/sokol_metal.zig`     — sokol Metal/IOSurface readback (Path A)
//!   - `preview/editor.zig`          — editor-preview codegen (labelle-studio)

const wasm_workaround = @import("preview/wasm_workaround.zig");
const helpers = @import("preview/helpers.zig");
const loop = @import("preview/loop.zig");
const callback = @import("preview/callback.zig");
const sokol_gl = @import("preview/sokol_gl.zig");
const sokol_d3d11 = @import("preview/sokol_d3d11.zig");
const sokol_metal = @import("preview/sokol_metal.zig");
const editor = @import("preview/editor.zig");

// ── Zig 0.16 wasm32-emscripten workarounds (preview/wasm_workaround.zig) ──
pub const WASM_PANIC_WORKAROUND = wasm_workaround.WASM_PANIC_WORKAROUND;
pub const WASM_DEBUG_IO_WORKAROUND = wasm_workaround.WASM_DEBUG_IO_WORKAROUND;

// ── Module-scope preview helpers (preview/helpers.zig) ──────────────
pub const PREVIEW_HELPERS = helpers.PREVIEW_HELPERS;
pub const PREVIEW_READBACK_HELPERS = helpers.PREVIEW_READBACK_HELPERS;

// ── Loop-backend snippets (preview/loop.zig) ────────────────────────
pub const PREVIEW_LOOP_SETUP = loop.PREVIEW_LOOP_SETUP;
pub const PREVIEW_READBACK_SETUP = loop.PREVIEW_READBACK_SETUP;
pub const PREVIEW_HEARTBEAT_LOOP = loop.PREVIEW_HEARTBEAT_LOOP;
pub const PREVIEW_INPUT_DISPATCH = loop.PREVIEW_INPUT_DISPATCH;
pub const PREVIEW_INPUT_DISPATCH_STUB = loop.PREVIEW_INPUT_DISPATCH_STUB;
pub const PREVIEW_READBACK_LOOP = loop.PREVIEW_READBACK_LOOP;

// ── Callback-backend snippets (preview/callback.zig) ────────────────
pub const PREVIEW_INIT_CALLBACK = callback.PREVIEW_INIT_CALLBACK;
pub const PREVIEW_CLEANUP_CALLBACK = callback.PREVIEW_CLEANUP_CALLBACK;
pub const PREVIEW_HEARTBEAT_CALLBACK = callback.PREVIEW_HEARTBEAT_CALLBACK;

// ── Sokol GL PBO readback (preview/sokol_gl.zig) ────────────────────
pub const PREVIEW_READBACK_HELPERS_SOKOL = sokol_gl.PREVIEW_READBACK_HELPERS_SOKOL;
pub const PREVIEW_READBACK_INIT_SOKOL = sokol_gl.PREVIEW_READBACK_INIT_SOKOL;
pub const PREVIEW_READBACK_FRAME_SOKOL = sokol_gl.PREVIEW_READBACK_FRAME_SOKOL;
pub const PREVIEW_READBACK_CLEANUP_SOKOL = sokol_gl.PREVIEW_READBACK_CLEANUP_SOKOL;

// ── Sokol D3D11 staging-texture readback (preview/sokol_d3d11.zig) ──
pub const PREVIEW_READBACK_HELPERS_SOKOL_D3D11 = sokol_d3d11.PREVIEW_READBACK_HELPERS_SOKOL_D3D11;
pub const PREVIEW_READBACK_INIT_SOKOL_D3D11 = sokol_d3d11.PREVIEW_READBACK_INIT_SOKOL_D3D11;
pub const PREVIEW_READBACK_FRAME_SOKOL_D3D11 = sokol_d3d11.PREVIEW_READBACK_FRAME_SOKOL_D3D11;
pub const PREVIEW_READBACK_CLEANUP_SOKOL_D3D11 = sokol_d3d11.PREVIEW_READBACK_CLEANUP_SOKOL_D3D11;

// ── Sokol Metal/IOSurface readback (preview/sokol_metal.zig) ────────
pub const PREVIEW_READBACK_HELPERS_METAL_SOKOL = sokol_metal.PREVIEW_READBACK_HELPERS_METAL_SOKOL;
pub const PREVIEW_READBACK_INIT_METAL_SOKOL = sokol_metal.PREVIEW_READBACK_INIT_METAL_SOKOL;
pub const PREVIEW_PRE_RENDER_METAL_SOKOL = sokol_metal.PREVIEW_PRE_RENDER_METAL_SOKOL;
pub const PREVIEW_READBACK_FRAME_METAL_SOKOL = sokol_metal.PREVIEW_READBACK_FRAME_METAL_SOKOL;
pub const PREVIEW_READBACK_CLEANUP_METAL_SOKOL = sokol_metal.PREVIEW_READBACK_CLEANUP_METAL_SOKOL;

// ── Editor-preview codegen (preview/editor.zig) ─────────────────────
pub const EDITOR_PREVIEW_BIND = editor.EDITOR_PREVIEW_BIND;
pub const EDITOR_PREVIEW_SIM_OPEN = editor.EDITOR_PREVIEW_SIM_OPEN;
pub const EDITOR_PREVIEW_SIM_CLOSE = editor.EDITOR_PREVIEW_SIM_CLOSE;
