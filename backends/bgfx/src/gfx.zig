/// bgfx gfx backend — satisfies the labelle-gfx Backend(Impl) contract.
/// Uses bgfx transient vertex buffers for shape rendering, bgfx texture API for sprites.
///
/// This file is the public façade for the bgfx gfx backend. The
/// implementation is split across `gfx/` submodules to keep each
/// concern below the 1000-line ceiling enforced by labelle-assembler#188:
///
///   - `gfx/types.zig`     — value types (Texture, Color, …) + color constants
///   - `gfx/state.zig`     — screen / camera state + coordinate helpers
///   - `gfx/programs.zig`  — shader programs, vertex layout, white texture, submit helpers
///   - `gfx/draw.zig`      — shape primitives (rect / circle / line / triangle / polygon)
///   - `gfx/texture.zig`   — image decode (PNG/JPG/BMP/TGA via stb_image) + texture handle pool + drawTexturePro
///   - `gfx/font.zig`      — embedded 8x8 bitmap font + drawText
///
/// Submodules are private file-system neighbours. The public surface
/// is consumed via `b.dependency("labelle_bgfx", ...).module("gfx")`
/// which still points at this file.
const types = @import("gfx/types.zig");
const state = @import("gfx/state.zig");
const programs = @import("gfx/programs.zig");
const draw = @import("gfx/draw.zig");
const texture = @import("gfx/texture.zig");
const font = @import("gfx/font.zig");

// ── Backend types ──────────────────────────────────────────────────────

pub const Texture = types.Texture;
pub const Color = types.Color;
pub const Rectangle = types.Rectangle;
pub const Vector2 = types.Vector2;
pub const Camera2D = types.Camera2D;

// ── Color constants ────────────────────────────────────────────────────

pub const white = types.white;
pub const black = types.black;
pub const red = types.red;
pub const green = types.green;
pub const blue = types.blue;
pub const transparent = types.transparent;

pub const color = types.color;

// ── State / shader management ──────────────────────────────────────────

pub const setScreenSize = state.setScreenSize;
// Toggle aspect-fit off around `screen_fill` layers so backdrops stretch to
// the full framebuffer (no pillarbox stripes). Mirrors sokol/raylib.
pub const setApplyFit = state.setApplyFit;
// Physical↔design coordinate conversion for HiDPI input mapping. The
// camera's `framebufferToWorld` calls `screenToDesign` (guarded by
// `@hasDecl`) so mouse/touch in framebuffer pixels maps to design space.
pub const screenToDesign = state.screenToDesign;
pub const designToPhysical = state.designToPhysical;
pub const getDesignWidth = state.getDesignWidth;
pub const getDesignHeight = state.getDesignHeight;
pub const shutdownPrograms = programs.shutdownPrograms;
pub const areProgramsReady = programs.areProgramsReady;

// ── Draw primitives (Backend contract) ─────────────────────────────────

pub const drawRectangleRec = draw.drawRectangleRec;
pub const drawCircle = draw.drawCircle;
pub const drawLine = draw.drawLine;
pub const drawTriangle = draw.drawTriangle;
pub const drawPolygon = draw.drawPolygon;

// ── Texture / Sprite rendering ────────────────────────────────────────

pub const DecodedImage = texture.DecodedImage;
pub const loadTexture = texture.loadTexture;
pub const decodeImage = texture.decodeImage;
pub const uploadTexture = texture.uploadTexture;
pub const unloadTexture = texture.unloadTexture;
pub const drawTexturePro = texture.drawTexturePro;
// GPU-compressed (ASTC) upload — the labelle-gfx `loadTextureFromMemory` seam
// dispatches to these via `@hasDecl` when the blob is compressed (#341).
pub const isCompressed = texture.isCompressed;
pub const uploadCompressed = texture.uploadCompressed;
// Header-only dims for the async asset-catalog adapter (engine#450), which
// splits worker-thread decode from main-thread upload and so can't use the
// synchronous seam — it reads dims here to set DecodedImage before upload.
pub const compressedDims = texture.compressedDims;

// ── Text rendering ─────────────────────────────────────────────────────

pub const drawText = font.drawText;

// ── Utility functions (Backend contract) ──────────────────────────────

pub const beginMode2D = state.beginMode2D;
pub const endMode2D = state.endMode2D;
pub const getScreenWidth = state.getScreenWidth;
pub const getScreenHeight = state.getScreenHeight;
pub const setDesignSize = state.setDesignSize;
pub const screenToWorld = state.screenToWorld;
pub const worldToScreen = state.worldToScreen;
