/// WebGPU gfx backend — satisfies the labelle-gfx Backend(Impl) contract.
/// Uses wgpu_native_zig (wgpu-native Zig bindings) for GPU rendering with vertex batching.
const std = @import("std");
const log = std.log.scoped(.wgpu_gfx);

// TODO: wire wgpu import once device/pipeline setup is implemented
// const wgpu = @import("wgpu");

// ── Backend types ──────────────────────────────────────────────────────

pub const Texture = struct {
    id: u32,
    width: i32,
    height: i32,
};

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    /// Convert to packed ABGR u32 for vertex data.
    pub fn toAbgr(self: Color) u32 {
        return (@as(u32, self.a) << 24) |
            (@as(u32, self.b) << 16) |
            (@as(u32, self.g) << 8) |
            @as(u32, self.r);
    }
};

pub const Rectangle = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const Vector2 = struct {
    x: f32,
    y: f32,
};

pub const Camera2D = struct {
    offset: Vector2 = .{ .x = 0, .y = 0 },
    target: Vector2 = .{ .x = 0, .y = 0 },
    rotation: f32 = 0,
    zoom: f32 = 1,
};

// ── Color constants ────────────────────────────────────────────────────

pub const white = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
pub const black = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
pub const red = Color{ .r = 255, .g = 0, .b = 0, .a = 255 };
pub const green = Color{ .r = 0, .g = 255, .b = 0, .a = 255 };
pub const blue = Color{ .r = 0, .g = 0, .b = 255, .a = 255 };
pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

// ── Vertex types ──────────────────────────────────────────────────────

/// Color vertex for shape rendering (position + packed ABGR color).
/// Pub: it is the element type of `consumeShapeBatch`'s return slices,
/// which the window module's render submitter consumes.
pub const ColorVertex = extern struct {
    position: [2]f32,
    color_packed: u32, // ABGR packed

    fn init(x: f32, y: f32, col: u32) ColorVertex {
        return .{ .position = .{ x, y }, .color_packed = col };
    }
};

/// Sprite vertex with position, UV, and packed ABGR color.
/// Pub: it is the element type of `consumeSpriteBatch`'s returned vertex
/// slice, which the window module's render submitter consumes.
pub const SpriteVertex = extern struct {
    position: [2]f32,
    uv: [2]f32,
    color_packed: u32, // ABGR packed

    fn init(x: f32, y: f32, u: f32, v: f32, col: u32) SpriteVertex {
        return .{ .position = .{ x, y }, .uv = .{ u, v }, .color_packed = col };
    }
};

// ── WGSL Shaders ──────────────────────────────────────────────────────

const shape_vs_source =
    \\struct Uniforms {
    \\    projection: mat4x4<f32>,
    \\};
    \\@group(0) @binding(0) var<uniform> uniforms: Uniforms;
    \\
    \\struct VertexInput {
    \\    @location(0) position: vec2<f32>,
    \\    @location(1) color_packed: u32,
    \\};
    \\
    \\struct VertexOutput {
    \\    @builtin(position) position: vec4<f32>,
    \\    @location(0) color: vec4<f32>,
    \\};
    \\
    \\@vertex
    \\fn main(in: VertexInput) -> VertexOutput {
    \\    var out: VertexOutput;
    \\    out.position = uniforms.projection * vec4<f32>(in.position, 0.0, 1.0);
    \\    // Unpack ABGR u32 to vec4<f32>
    \\    let c = in.color_packed;
    \\    out.color = vec4<f32>(
    \\        f32(c & 0xFFu) / 255.0,
    \\        f32((c >> 8u) & 0xFFu) / 255.0,
    \\        f32((c >> 16u) & 0xFFu) / 255.0,
    \\        f32((c >> 24u) & 0xFFu) / 255.0,
    \\    );
    \\    return out;
    \\}
;

const shape_fs_source =
    \\struct FragmentInput {
    \\    @location(0) color: vec4<f32>,
    \\};
    \\
    \\@fragment
    \\fn main(in: FragmentInput) -> @location(0) vec4<f32> {
    \\    return in.color;
    \\}
;

const sprite_vs_source =
    \\struct Uniforms {
    \\    projection: mat4x4<f32>,
    \\};
    \\@group(0) @binding(0) var<uniform> uniforms: Uniforms;
    \\
    \\struct VertexInput {
    \\    @location(0) position: vec2<f32>,
    \\    @location(1) uv: vec2<f32>,
    \\    @location(2) color_packed: u32,
    \\};
    \\
    \\struct VertexOutput {
    \\    @builtin(position) position: vec4<f32>,
    \\    @location(0) uv: vec2<f32>,
    \\    @location(1) color: vec4<f32>,
    \\};
    \\
    \\@vertex
    \\fn main(in: VertexInput) -> VertexOutput {
    \\    var out: VertexOutput;
    \\    out.position = uniforms.projection * vec4<f32>(in.position, 0.0, 1.0);
    \\    out.uv = in.uv;
    \\    // Unpack ABGR u32 to vec4<f32>
    \\    let c = in.color_packed;
    \\    out.color = vec4<f32>(
    \\        f32(c & 0xFFu) / 255.0,
    \\        f32((c >> 8u) & 0xFFu) / 255.0,
    \\        f32((c >> 16u) & 0xFFu) / 255.0,
    \\        f32((c >> 24u) & 0xFFu) / 255.0,
    \\    );
    \\    return out;
    \\}
;

const sprite_fs_source =
    \\@group(0) @binding(1) var t_diffuse: texture_2d<f32>;
    \\@group(0) @binding(2) var s_diffuse: sampler;
    \\
    \\struct FragmentInput {
    \\    @location(0) uv: vec2<f32>,
    \\    @location(1) color: vec4<f32>,
    \\};
    \\
    \\@fragment
    \\fn main(in: FragmentInput) -> @location(0) vec4<f32> {
    \\    let tex_color = textureSample(t_diffuse, s_diffuse, in.uv);
    \\    return tex_color * in.color;
    \\}
;

// ── Shape batch ───────────────────────────────────────────────────────

const MAX_SHAPE_VERTICES = 16384;
const MAX_SHAPE_INDICES = 32768;
const MAX_SPRITE_VERTICES = 8192;
const MAX_SPRITE_INDICES = 16384;
const MAX_SPRITE_QUADS = MAX_SPRITE_VERTICES / 4;

var shape_vertices: [MAX_SHAPE_VERTICES]ColorVertex = undefined;
var shape_indices: [MAX_SHAPE_INDICES]u32 = undefined;
var shape_vertex_count: usize = 0;
var shape_index_count: usize = 0;

var sprite_vertices: [MAX_SPRITE_VERTICES]SpriteVertex = undefined;
var sprite_indices: [MAX_SPRITE_INDICES]u32 = undefined;
var sprite_vertex_count: usize = 0;
var sprite_index_count: usize = 0;

/// Texture ID for each sprite quad, so the renderer knows which texture to bind.
var sprite_texture_ids: [MAX_SPRITE_QUADS]u32 = undefined;
var sprite_quad_count: usize = 0;

// ── Ordered draw-segment list ──────────────────────────────────────────
//
// Shapes and sprites live in two separate vertex/index buffers (distinct
// vertex formats + pipelines), but a frame must still composite them in
// strict submission order — a game may draw a shape *over* a sprite within
// one frame. We record that order as a list of contiguous same-kind
// segments. Each segment points into the index buffer of its kind (and,
// for sprites, into `sprite_texture_ids`). Consecutive draws of the same
// kind extend the current segment; a kind switch starts a new one. The
// window submitter walks this list in order, switching pipelines per
// segment, so painter's order is preserved with at most one drawIndexed
// per kind-run (plus the existing same-texture coalescing inside a sprite
// segment).

pub const SegmentKind = enum { shape, sprite };

/// One contiguous run of same-kind draws.
/// - `index_start`/`index_count`: offset+length into the relevant kind's
///   index buffer (shape_indices or sprite_indices).
/// - `quad_start`/`quad_count`: offset+length into `sprite_texture_ids`;
///   zero for shape segments.
pub const DrawSegment = struct {
    kind: SegmentKind,
    index_start: u32,
    index_count: u32,
    quad_start: u32 = 0,
    quad_count: u32 = 0,
};

/// A realistic frame has only a handful of shape/sprite kind switches, so a
/// modest cap covers any sane workload. On overflow we fail safe by DROPPING
/// the overflow draw from the segment stream: its geometry was already
/// appended to the (separate) shape/sprite vertex+index buffers, but no
/// segment references it, so it simply isn't drawn. We must NOT fold it into
/// the trailing segment — by the time we reach the overflow check the tail is
/// always the *opposite* kind (a same-kind tail is extended and returns
/// earlier), and shape vs. sprite segments draw from different index buffers,
/// so folding would make the draw over-read the wrong buffer. Only the
/// overflow tail goes unrendered; a warning is logged once per such frame.
const MAX_DRAW_SEGMENTS = 1024;

var draw_segments: [MAX_DRAW_SEGMENTS]DrawSegment = undefined;
var draw_segment_count: usize = 0;
var draw_segments_overflowed: bool = false;

/// Record that a shape draw of `n_indices` indices was just appended to the
/// shape index buffer. Extends the trailing shape segment, or opens a new
/// one on a kind switch. Call AFTER the indices have been appended is fine
/// — we derive `index_start` from the pre-append count, which we pass in.
fn noteShapeDraw(index_start: u32, n_indices: u32) void {
    if (draw_segment_count > 0) {
        const last = &draw_segments[draw_segment_count - 1];
        if (last.kind == .shape) {
            last.index_count += n_indices;
            return;
        }
    }
    if (draw_segment_count >= MAX_DRAW_SEGMENTS) {
        // Overflow: drop this draw from the segment stream (see
        // MAX_DRAW_SEGMENTS doc). The tail here is always a sprite segment,
        // which draws from the sprite index buffer — folding shape indices
        // into it would over-read the wrong buffer, so we drop instead.
        if (!draw_segments_overflowed) {
            log.warn("draw-segment list full ({d}); dropping overflow draws this frame", .{MAX_DRAW_SEGMENTS});
            draw_segments_overflowed = true;
        }
        return;
    }
    draw_segments[draw_segment_count] = .{
        .kind = .shape,
        .index_start = index_start,
        .index_count = n_indices,
    };
    draw_segment_count += 1;
}

/// Record that a sprite quad draw of `n_indices` indices (6) and one quad
/// was just appended. Extends the trailing sprite segment, or opens a new
/// one on a kind switch.
fn noteSpriteDraw(index_start: u32, n_indices: u32, quad_start: u32) void {
    if (draw_segment_count > 0) {
        const last = &draw_segments[draw_segment_count - 1];
        if (last.kind == .sprite) {
            last.index_count += n_indices;
            last.quad_count += 1;
            return;
        }
    }
    if (draw_segment_count >= MAX_DRAW_SEGMENTS) {
        // Overflow: drop this draw from the segment stream (see
        // MAX_DRAW_SEGMENTS doc). The tail here is always a shape segment,
        // which draws from the shape index buffer — folding sprite indices
        // into it would over-read the wrong buffer, so we drop instead.
        if (!draw_segments_overflowed) {
            log.warn("draw-segment list full ({d}); dropping overflow draws this frame", .{MAX_DRAW_SEGMENTS});
            draw_segments_overflowed = true;
        }
        return;
    }
    draw_segments[draw_segment_count] = .{
        .kind = .sprite,
        .index_start = index_start,
        .index_count = n_indices,
        .quad_start = quad_start,
        .quad_count = 1,
    };
    draw_segment_count += 1;
}

/// Reset the ordered segment list for the next frame.
fn resetSegments() void {
    draw_segment_count = 0;
    draw_segments_overflowed = false;
}

// ── Texture storage ────────────────────────────────────────────────────

const MAX_TEXTURES = 256;

const TextureSlot = struct {
    /// Raw RGBA8 pixel data (owned).
    pixels: ?[]u8 = null,
    width: i32 = 0,
    height: i32 = 0,
    active: bool = false,
};

var textures: [MAX_TEXTURES]TextureSlot = [_]TextureSlot{.{}} ** MAX_TEXTURES;
var next_texture_id: u32 = 1;

// ── State ──────────────────────────────────────────────────────────────

var screen_w: i32 = 800;
var screen_h: i32 = 600;
var active_camera: ?Camera2D = null;

pub fn setScreenSize(w: i32, h: i32) void {
    screen_w = w;
    screen_h = h;
}

// ── Camera coordinate transform ────────────────────────────────────────

fn transformX(x: f32) f32 {
    if (active_camera) |cam| {
        return (x - cam.target.x) * cam.zoom + cam.offset.x;
    }
    return x;
}

fn transformY(y: f32) f32 {
    if (active_camera) |cam| {
        return (y - cam.target.y) * cam.zoom + cam.offset.y;
    }
    return y;
}

/// Convert screen X to NDC (-1..1).
fn toNdcX(x: f32) f32 {
    const sw: f32 = @floatFromInt(screen_w);
    return (transformX(x) / sw) * 2.0 - 1.0;
}

/// Convert screen Y to NDC (-1..1), flipped for GPU.
fn toNdcY(y: f32) f32 {
    const sh: f32 = @floatFromInt(screen_h);
    return 1.0 - (transformY(y) / sh) * 2.0;
}

// ── Shape batch helpers ───────────────────────────────────────────────

/// Check whether the shape batch has room for the given number of vertices and indices.
fn hasShapeCapacity(verts: usize, idxs: usize) bool {
    return (shape_vertex_count + verts <= MAX_SHAPE_VERTICES) and
        (shape_index_count + idxs <= MAX_SHAPE_INDICES);
}

/// Check whether the sprite batch has room for the given number of vertices and indices.
fn hasSpriteCapacity(verts: usize, idxs: usize) bool {
    return (sprite_vertex_count + verts <= MAX_SPRITE_VERTICES) and
        (sprite_index_count + idxs <= MAX_SPRITE_INDICES);
}

fn appendShapeVertex(v: ColorVertex) void {
    shape_vertices[shape_vertex_count] = v;
    shape_vertex_count += 1;
}

fn appendShapeIndex(idx: u32) void {
    shape_indices[shape_index_count] = idx;
    shape_index_count += 1;
}

fn appendSpriteVertex(v: SpriteVertex) void {
    sprite_vertices[sprite_vertex_count] = v;
    sprite_vertex_count += 1;
}

fn appendSpriteIndex(idx: u32) void {
    sprite_indices[sprite_index_count] = idx;
    sprite_index_count += 1;
}

/// Reset shape batch for the next frame.
pub fn resetShapeBatch() void {
    shape_vertex_count = 0;
    shape_index_count = 0;
}

/// Reset sprite batch for the next frame.
pub fn resetSpriteBatch() void {
    sprite_vertex_count = 0;
    sprite_index_count = 0;
    sprite_quad_count = 0;
}

/// Consume shape batch data for GPU submission (called once per frame at endDrawing).
/// Resets the batch after returning — the returned slices are valid until the next draw call.
pub fn consumeShapeBatch() struct { vertices: []const ColorVertex, indices: []const u32 } {
    const vcount = shape_vertex_count;
    const icount = shape_index_count;
    resetShapeBatch();
    return .{
        .vertices = shape_vertices[0..vcount],
        .indices = shape_indices[0..icount],
    };
}

/// Consume sprite batch data for GPU submission (called once per frame at endDrawing).
/// Resets the batch after returning — the returned slices are valid until the next draw call.
/// `texture_ids` has one entry per quad (every 4 vertices / 6 indices).
pub fn consumeSpriteBatch() struct { vertices: []const SpriteVertex, indices: []const u32, texture_ids: []const u32 } {
    const vcount = sprite_vertex_count;
    const icount = sprite_index_count;
    const qcount = sprite_quad_count;
    resetSpriteBatch();
    return .{
        .vertices = sprite_vertices[0..vcount],
        .indices = sprite_indices[0..icount],
        .texture_ids = sprite_texture_ids[0..qcount],
    };
}

/// Backward-compatible alias for `consumeShapeBatch`.
pub const getShapeBatch = consumeShapeBatch;

/// Backward-compatible alias for `consumeSpriteBatch`.
pub const getSpriteBatch = consumeSpriteBatch;

/// Unified per-frame snapshot for the GPU submitter: both vertex/index
/// buffers, the per-quad texture ids, and the ordered draw-segment stream
/// that records shape/sprite submission order. Slices are valid until the
/// next draw call.
pub const Frame = struct {
    shape_vertices: []const ColorVertex,
    shape_indices: []const u32,
    sprite_vertices: []const SpriteVertex,
    sprite_indices: []const u32,
    sprite_texture_ids: []const u32,
    segments: []const DrawSegment,
};

/// Consume the whole frame at once and reset all batch state — including
/// the segment list — exactly ONCE. This is the path the window submitter
/// uses. `consumeShapeBatch`/`consumeSpriteBatch` remain for standalone
/// tests, but mixing them with `consumeFrame` in the same frame would
/// double-drain the vertex/index buffers, so callers pick one.
pub fn consumeFrame() Frame {
    const shape_vcount = shape_vertex_count;
    const shape_icount = shape_index_count;
    const sprite_vcount = sprite_vertex_count;
    const sprite_icount = sprite_index_count;
    const qcount = sprite_quad_count;
    const seg_count = draw_segment_count;

    resetShapeBatch();
    resetSpriteBatch();
    resetSegments();

    return .{
        .shape_vertices = shape_vertices[0..shape_vcount],
        .shape_indices = shape_indices[0..shape_icount],
        .sprite_vertices = sprite_vertices[0..sprite_vcount],
        .sprite_indices = sprite_indices[0..sprite_icount],
        .sprite_texture_ids = sprite_texture_ids[0..qcount],
        .segments = draw_segments[0..seg_count],
    };
}

// ── Draw primitives (Backend contract) ─────────────────────────────────

pub fn drawRectangleRec(rec: Rectangle, tint: Color) void {
    if (!hasShapeCapacity(4, 6)) {
        log.warn("shape batch full, dropping rectangle primitive", .{});
        return;
    }
    const col = tint.toAbgr();
    const x = rec.x;
    const y = rec.y;
    const w = rec.width;
    const h = rec.height;
    const base: u32 = @intCast(shape_vertex_count);
    const index_start: u32 = @intCast(shape_index_count);

    // 4 vertices for the rectangle
    appendShapeVertex(ColorVertex.init(toNdcX(x), toNdcY(y), col));
    appendShapeVertex(ColorVertex.init(toNdcX(x + w), toNdcY(y), col));
    appendShapeVertex(ColorVertex.init(toNdcX(x + w), toNdcY(y + h), col));
    appendShapeVertex(ColorVertex.init(toNdcX(x), toNdcY(y + h), col));

    // 2 triangles (CCW winding)
    appendShapeIndex(base + 0);
    appendShapeIndex(base + 1);
    appendShapeIndex(base + 2);
    appendShapeIndex(base + 0);
    appendShapeIndex(base + 2);
    appendShapeIndex(base + 3);

    noteShapeDraw(index_start, 6);
}

pub fn drawCircle(center_x: f32, center_y: f32, radius: f32, tint: Color) void {
    const segments: u32 = 36;
    if (!hasShapeCapacity(segments + 2, segments * 3)) {
        log.warn("shape batch full, dropping circle primitive", .{});
        return;
    }
    const col = tint.toAbgr();
    const base: u32 = @intCast(shape_vertex_count);
    const index_start: u32 = @intCast(shape_index_count);

    // Center vertex
    appendShapeVertex(ColorVertex.init(toNdcX(center_x), toNdcY(center_y), col));

    // Perimeter vertices
    var i: u32 = 0;
    while (i <= segments) : (i += 1) {
        const angle = (@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments))) * 2.0 * std.math.pi;
        const px = center_x + @cos(angle) * radius;
        const py = center_y + @sin(angle) * radius;
        appendShapeVertex(ColorVertex.init(toNdcX(px), toNdcY(py), col));
    }

    // Fan triangles (center + 2 consecutive perimeter vertices)
    i = 0;
    while (i < segments) : (i += 1) {
        appendShapeIndex(base); // center
        appendShapeIndex(base + i + 1);
        appendShapeIndex(base + i + 2);
    }

    noteShapeDraw(index_start, segments * 3);
}

pub fn drawLine(start_x: f32, start_y: f32, end_x: f32, end_y: f32, thickness: f32, tint: Color) void {
    if (!hasShapeCapacity(4, 6)) {
        log.warn("shape batch full, dropping line primitive", .{});
        return;
    }
    const col = tint.toAbgr();
    const dx = end_x - start_x;
    const dy = end_y - start_y;
    const len = @sqrt(dx * dx + dy * dy);

    if (len < 0.0001) return; // skip degenerate lines

    // Perpendicular offset for thickness
    const perp_x = -dy / len * (thickness * 0.5);
    const perp_y = dx / len * (thickness * 0.5);

    const base: u32 = @intCast(shape_vertex_count);
    const index_start: u32 = @intCast(shape_index_count);

    // Quad from 4 offset vertices
    appendShapeVertex(ColorVertex.init(toNdcX(start_x + perp_x), toNdcY(start_y + perp_y), col));
    appendShapeVertex(ColorVertex.init(toNdcX(start_x - perp_x), toNdcY(start_y - perp_y), col));
    appendShapeVertex(ColorVertex.init(toNdcX(end_x - perp_x), toNdcY(end_y - perp_y), col));
    appendShapeVertex(ColorVertex.init(toNdcX(end_x + perp_x), toNdcY(end_y + perp_y), col));

    appendShapeIndex(base + 0);
    appendShapeIndex(base + 1);
    appendShapeIndex(base + 2);
    appendShapeIndex(base + 0);
    appendShapeIndex(base + 2);
    appendShapeIndex(base + 3);

    noteShapeDraw(index_start, 6);
}

pub fn drawTriangle(x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32, tint: Color) void {
    if (!hasShapeCapacity(3, 3)) {
        log.warn("shape batch full, dropping triangle primitive", .{});
        return;
    }
    const col = tint.toAbgr();
    const base: u32 = @intCast(shape_vertex_count);
    const index_start: u32 = @intCast(shape_index_count);

    appendShapeVertex(ColorVertex.init(toNdcX(x1), toNdcY(y1), col));
    appendShapeVertex(ColorVertex.init(toNdcX(x2), toNdcY(y2), col));
    appendShapeVertex(ColorVertex.init(toNdcX(x3), toNdcY(y3), col));

    appendShapeIndex(base + 0);
    appendShapeIndex(base + 1);
    appendShapeIndex(base + 2);

    noteShapeDraw(index_start, 3);
}

pub fn drawPoly(center_x: f32, center_y: f32, sides: i32, radius: f32, rotation: f32, tint: Color) void {
    if (sides < 3 or radius <= 0) return;
    const num_sides: u32 = @intCast(sides);
    if (!hasShapeCapacity(num_sides + 2, num_sides * 3)) {
        log.warn("shape batch full, dropping polygon primitive", .{});
        return;
    }
    const col = tint.toAbgr();
    const base: u32 = @intCast(shape_vertex_count);
    const index_start: u32 = @intCast(shape_index_count);

    // Convert rotation from degrees to radians (consistent with drawTexturePro / raylib convention)
    const rot_rad = rotation * std.math.pi / 180.0;

    // Center vertex
    appendShapeVertex(ColorVertex.init(toNdcX(center_x), toNdcY(center_y), col));

    // Perimeter vertices
    var i: u32 = 0;
    while (i <= num_sides) : (i += 1) {
        const angle = rot_rad + (@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(num_sides))) * 2.0 * std.math.pi;
        const px = center_x + @cos(angle) * radius;
        const py = center_y + @sin(angle) * radius;
        appendShapeVertex(ColorVertex.init(toNdcX(px), toNdcY(py), col));
    }

    // Fan triangles
    i = 0;
    while (i < num_sides) : (i += 1) {
        appendShapeIndex(base);
        appendShapeIndex(base + i + 1);
        appendShapeIndex(base + i + 2);
    }

    noteShapeDraw(index_start, num_sides * 3);
}

// ── Texture / Sprite rendering ─────────────────────────────────────────

pub fn drawTexturePro(texture: Texture, source: Rectangle, dest: Rectangle, origin: Vector2, rotation: f32, tint: Color) void {
    if (!hasSpriteCapacity(4, 6)) {
        log.warn("sprite batch full, dropping sprite primitive", .{});
        return;
    }
    const col = tint.toAbgr();

    // Capture the pre-append offsets for the ordered segment record.
    const seg_index_start: u32 = @intCast(sprite_index_count);
    const seg_quad_start: u32 = @intCast(sprite_quad_count);

    // Track which texture this quad uses so the renderer can bind correctly.
    if (sprite_quad_count < MAX_SPRITE_QUADS) {
        sprite_texture_ids[sprite_quad_count] = texture.id;
        sprite_quad_count += 1;
    }

    // UV coordinates from source rectangle
    const tex_w: f32 = @floatFromInt(texture.width);
    const tex_h: f32 = @floatFromInt(texture.height);
    const uv_x0 = source.x / tex_w;
    const uv_y0 = source.y / tex_h;
    const uv_x1 = (source.x + source.width) / tex_w;
    const uv_y1 = (source.y + source.height) / tex_h;

    // Local corner positions relative to origin
    const x0 = -origin.x;
    const y0 = -origin.y;
    const x1 = dest.width - origin.x;
    const y1 = dest.height - origin.y;

    // Rotation
    const cos_r = @cos(rotation * std.math.pi / 180.0);
    const sin_r = @sin(rotation * std.math.pi / 180.0);

    const base: u32 = @intCast(sprite_vertex_count);

    // Top-left
    const tx0 = dest.x + (x0 * cos_r - y0 * sin_r);
    const ty0 = dest.y + (x0 * sin_r + y0 * cos_r);
    appendSpriteVertex(SpriteVertex.init(toNdcX(tx0), toNdcY(ty0), uv_x0, uv_y0, col));

    // Top-right
    const tx1 = dest.x + (x1 * cos_r - y0 * sin_r);
    const ty1 = dest.y + (x1 * sin_r + y0 * cos_r);
    appendSpriteVertex(SpriteVertex.init(toNdcX(tx1), toNdcY(ty1), uv_x1, uv_y0, col));

    // Bottom-right
    const tx2 = dest.x + (x1 * cos_r - y1 * sin_r);
    const ty2 = dest.y + (x1 * sin_r + y1 * cos_r);
    appendSpriteVertex(SpriteVertex.init(toNdcX(tx2), toNdcY(ty2), uv_x1, uv_y1, col));

    // Bottom-left
    const tx3 = dest.x + (x0 * cos_r - y1 * sin_r);
    const ty3 = dest.y + (x0 * sin_r + y1 * cos_r);
    appendSpriteVertex(SpriteVertex.init(toNdcX(tx3), toNdcY(ty3), uv_x0, uv_y1, col));

    // 2 triangles (CCW)
    appendSpriteIndex(base + 0);
    appendSpriteIndex(base + 1);
    appendSpriteIndex(base + 2);
    appendSpriteIndex(base + 0);
    appendSpriteIndex(base + 2);
    appendSpriteIndex(base + 3);

    noteSpriteDraw(seg_index_start, 6, seg_quad_start);
}

// Zig 0.16 removed `std.fs.cwd()` in favour of `std.Io.Dir.cwd()`, which
// requires an `Io` parameter threaded through the call site. This is
// the legacy path-based texture loader — production texture loading
// goes through `decodeImage` + `uploadTexture` on caller-provided
// bytes and never touches the FS directly. Rather than thread `Io`
// through the backend for a one-shot loader, we use libc `fopen` /
// `fread` / `fclose` to keep the existing `(path) !Texture` signature.
// The `link_libc = true` flag on the gfx module (see
// backends/wgpu/build.zig) pulls libc in.
const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;

pub fn loadTexture(path: [:0]const u8) !Texture {
    // Read the file from disk via libc. See the rationale block above.
    const file = std.c.fopen(path.ptr, "rb") orelse return error.LoadFailed;
    defer _ = std.c.fclose(file);

    if (fseek(file, 0, SEEK_END) != 0) return error.LoadFailed;
    const file_size_signed = ftell(file);
    if (file_size_signed < 18) return error.LoadFailed; // Too small for any image header
    if (fseek(file, 0, SEEK_SET) != 0) return error.LoadFailed;
    const file_size: usize = @intCast(file_size_signed);

    const allocator = std.heap.page_allocator;
    const file_buf = allocator.alloc(u8, file_size) catch return error.LoadFailed;
    defer allocator.free(file_buf);

    const bytes_read = std.c.fread(file_buf.ptr, 1, file_size, file);
    if (bytes_read != file_size) return error.LoadFailed;

    const decoded = try decodeImage("", file_buf[0..bytes_read], allocator);
    defer allocator.free(decoded.pixels);
    return uploadTexture(decoded);
}

/// Pure CPU decode, safe from a worker thread. wgpu's backend ships
/// hand-rolled BMP, TGA and PNG decoders (no stb_image link). We sniff
/// the signature and dispatch: PNG first (it has an unambiguous 8-byte
/// magic), then BMP, then TGA (which has no magic, so it's the
/// last-resort fallback). The caller's allocator owns the returned
/// `pixels` buffer and frees it on both the success and the discard
/// paths.
pub fn decodeImage(
    _: [:0]const u8,
    data: []const u8,
    allocator: std.mem.Allocator,
) !DecodedImage {
    if (decodePng(data, allocator)) |img| return img;
    if (decodeBmp(data, allocator)) |img| return img;
    if (decodeTga(data, allocator)) |img| return img;
    return error.LoadFailed;
}

/// Main/GL-thread GPU upload. This wgpu backend currently retains its
/// decoded pixels in the texture slot (drawTexturePro uploads them
/// lazily via `wgpuQueueWriteTexture` — or a stub path, depending on
/// renderer state), so we COPY `decoded.pixels` into a fresh
/// page_allocator buffer that the slot owns. We do NOT free
/// `decoded.pixels` — the caller owns that buffer on both the success
/// and the discard paths.
pub fn uploadTexture(decoded: DecodedImage) !Texture {
    const id = next_texture_id;
    if (id >= MAX_TEXTURES) return error.LoadFailed;
    if (decoded.width == 0 or decoded.height == 0) return error.LoadFailed;

    const owned = std.heap.page_allocator.alloc(u8, decoded.pixels.len) catch return error.LoadFailed;
    @memcpy(owned, decoded.pixels);

    const w: i32 = @intCast(decoded.width);
    const h: i32 = @intCast(decoded.height);
    textures[id] = .{ .pixels = owned, .width = w, .height = h, .active = true };
    next_texture_id += 1;
    return Texture{ .id = id, .width = w, .height = h };
}

pub fn unloadTexture(texture: Texture) void {
    if (texture.id >= MAX_TEXTURES) return;
    const slot = &textures[texture.id];
    if (slot.pixels) |px| {
        std.heap.page_allocator.free(px);
    }
    slot.* = .{};
}

/// CPU-side description of a loaded texture's pixel data, used by the GPU
/// submitter (window.zig) to lazily create + upload a wgpu texture the
/// first time the texture id is drawn. The `pixels` slice is borrowed
/// (owned by the texture slot) and stays valid until `unloadTexture`.
pub const TexturePixels = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
};

/// Look up the RGBA8 pixel buffer for a texture id. Returns null for an
/// unknown / inactive id. The returned slice is borrowed (see above).
pub fn getTexturePixels(id: u32) ?TexturePixels {
    if (id == 0 or id >= MAX_TEXTURES) return null;
    const slot = &textures[id];
    if (!slot.active) return null;
    const px = slot.pixels orelse return null;
    return .{
        .pixels = px,
        .width = @intCast(slot.width),
        .height = @intCast(slot.height),
    };
}

// ── Image decoding helpers ─────────────────────────────────────────────

/// CPU-decoded image owned by the caller's allocator. See sokol's
/// `DecodedImage` doc-comment for why this is defined per-backend
/// instead of imported from labelle-gfx — same reasoning applies.
pub const DecodedImage = struct {
    pixels: []u8,
    width: u32,
    height: u32,
};

/// Decode an uncompressed 24-bit or 32-bit BMP to RGBA8.
fn decodeBmp(data: []const u8, allocator: std.mem.Allocator) ?DecodedImage {
    if (data.len < 54) return null;
    if (data[0] != 'B' or data[1] != 'M') return null;

    const pixel_offset = std.mem.readInt(u32, data[10..14], .little);
    const w_signed = std.mem.readInt(i32, data[18..22], .little);
    const h_signed = std.mem.readInt(i32, data[22..26], .little);
    const bpp = std.mem.readInt(u16, data[28..30], .little);

    if (w_signed <= 0) return null;
    const width: u32 = @intCast(w_signed);
    // BMP height can be negative (top-down); handle both.
    const flip = h_signed > 0;
    const height: u32 = if (h_signed < 0) @intCast(-h_signed) else @intCast(h_signed);

    if (bpp != 24 and bpp != 32) return null; // Only uncompressed RGB/RGBA

    const bytes_per_pixel: u32 = @as(u32, bpp) / 8;
    const row_size = ((width * bytes_per_pixel + 3) / 4) * 4; // BMP rows are 4-byte aligned

    const out_size = @as(usize, width) * @as(usize, height) * 4;
    const pixels = allocator.alloc(u8, out_size) catch return null;

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const src_y = if (flip) height - 1 - y else y;
        const row_off = @as(usize, pixel_offset) + @as(usize, src_y) * @as(usize, row_size);
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const src = row_off + @as(usize, x) * @as(usize, bytes_per_pixel);
            const dst = (@as(usize, y) * @as(usize, width) + @as(usize, x)) * 4;
            if (src + bytes_per_pixel > data.len or dst + 4 > pixels.len) {
                allocator.free(pixels);
                return null;
            }
            // BMP stores BGR(A)
            pixels[dst + 0] = data[src + 2]; // R
            pixels[dst + 1] = data[src + 1]; // G
            pixels[dst + 2] = data[src + 0]; // B
            pixels[dst + 3] = if (bytes_per_pixel == 4) data[src + 3] else 255;
        }
    }

    return DecodedImage{ .pixels = pixels, .width = width, .height = height };
}

/// Decode an uncompressed TGA (type 2) to RGBA8.
fn decodeTga(data: []const u8, allocator: std.mem.Allocator) ?DecodedImage {
    if (data.len < 18) return null;

    const image_type = data[2];
    if (image_type != 2) return null; // Only uncompressed true-color

    const width: u32 = std.mem.readInt(u16, data[12..14], .little);
    const height: u32 = std.mem.readInt(u16, data[14..16], .little);
    const bpp = data[16];
    const descriptor = data[17];

    if (width == 0 or height == 0) return null;
    if (bpp != 24 and bpp != 32) return null;

    const id_len: usize = data[0];
    const pixel_offset: usize = 18 + id_len;
    const bytes_per_pixel: usize = @as(usize, bpp) / 8;
    // Bit 5 of descriptor: 0 = bottom-up (default TGA), 1 = top-down
    const top_down = (descriptor & 0x20) != 0;

    const out_size = @as(usize, width) * @as(usize, height) * 4;
    const pixels = allocator.alloc(u8, out_size) catch return null;

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const src_y = if (!top_down) height - 1 - y else y;
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const src = pixel_offset + (@as(usize, src_y) * @as(usize, width) + @as(usize, x)) * bytes_per_pixel;
            const dst = (@as(usize, y) * @as(usize, width) + @as(usize, x)) * 4;
            if (src + bytes_per_pixel > data.len or dst + 4 > pixels.len) {
                allocator.free(pixels);
                return null;
            }
            // TGA stores BGR(A)
            pixels[dst + 0] = data[src + 2]; // R
            pixels[dst + 1] = data[src + 1]; // G
            pixels[dst + 2] = data[src + 0]; // B
            pixels[dst + 3] = if (bytes_per_pixel == 4) data[src + 3] else 255;
        }
    }

    return DecodedImage{ .pixels = pixels, .width = width, .height = height };
}

/// Decode a non-interlaced, 8-bit PNG to RGBA8.
///
/// Supported subset (returns `null` for anything outside it):
///   • Bit depth: 8 only (1/2/4/16 rejected).
///   • Interlace: 0 (none) only — Adam7 interlacing is rejected.
///   • Color types:
///       0  grayscale            → gray replicated to RGB, A = 255
///       2  truecolor (RGB)      → RGB, A = 255
///       3  indexed (palette)    → PLTE lookup, optional tRNS for alpha
///       4  grayscale+alpha      → gray replicated to RGB, A from sample
///       6  truecolor+alpha      → RGBA passthrough
///
/// PNG pipeline: validate the 8-byte signature, walk IHDR/PLTE/tRNS/IDAT/
/// IEND chunks, concatenate all IDAT data, zlib-inflate it (std
/// `compress.flate` — no DEFLATE is hand-rolled), then unfilter the
/// scanlines (filter types 0–4: None/Sub/Up/Average/Paeth) and expand
/// each pixel to RGBA8. Chunk CRCs are not verified (we trust the
/// inflate + structural checks). The caller's allocator owns the
/// returned `pixels`.
fn decodePng(data: []const u8, allocator: std.mem.Allocator) ?DecodedImage {
    const sig = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
    if (data.len < sig.len or !std.mem.eql(u8, data[0..sig.len], &sig)) return null;

    var width: u32 = 0;
    var height: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: u8 = 0;
    var interlace: u8 = 0;
    var seen_ihdr = false;

    // Palette (color type 3): up to 256 RGB entries + optional per-index alpha.
    var palette: [256][3]u8 = undefined;
    var palette_alpha: [256]u8 = [_]u8{255} ** 256;
    var palette_len: usize = 0;

    // Concatenated IDAT payload (the zlib stream). Owned here, freed below.
    var idat: std.ArrayListUnmanaged(u8) = .empty;
    defer idat.deinit(allocator);

    // Walk chunks: 4-byte length, 4-byte type, length bytes data, 4-byte CRC.
    var pos: usize = sig.len;
    var saw_iend = false;
    while (data.len - pos >= 8) {
        const chunk_len = std.mem.readInt(u32, data[pos..][0..4], .big);
        const ctype = data[pos + 4 ..][0..4];
        const body_start = pos + 8;
        // Bounds via subtraction so a malformed `chunk_len` (e.g.
        // 0xFFFFFFFF) can't overflow `usize` and bypass the check. We
        // need `chunk_len` body bytes plus a 4-byte trailing CRC.
        if (data.len - body_start < chunk_len) return null; // truncated body
        if (data.len - body_start - chunk_len < 4) return null; // missing CRC
        const body_end = body_start + chunk_len;
        const body = data[body_start..body_end];

        if (std.mem.eql(u8, ctype, "IHDR")) {
            if (chunk_len != 13) return null;
            width = std.mem.readInt(u32, body[0..4], .big);
            height = std.mem.readInt(u32, body[4..8], .big);
            bit_depth = body[8];
            color_type = body[9];
            // body[10] = compression (only 0 defined), body[11] = filter
            // method (only 0 defined), body[12] = interlace.
            interlace = body[12];
            seen_ihdr = true;
        } else if (std.mem.eql(u8, ctype, "PLTE")) {
            if (chunk_len % 3 != 0) return null;
            palette_len = chunk_len / 3;
            if (palette_len > 256) return null;
            var i: usize = 0;
            while (i < palette_len) : (i += 1) {
                palette[i] = .{ body[i * 3 + 0], body[i * 3 + 1], body[i * 3 + 2] };
            }
        } else if (std.mem.eql(u8, ctype, "tRNS")) {
            // For indexed images, tRNS is a list of per-index alpha values.
            // (We only support tRNS for color type 3; other types fall back
            // to opaque alpha, which is a documented limitation.)
            if (color_type == 3) {
                const n = @min(chunk_len, palette_alpha.len);
                var i: usize = 0;
                while (i < n) : (i += 1) palette_alpha[i] = body[i];
            }
        } else if (std.mem.eql(u8, ctype, "IDAT")) {
            idat.appendSlice(allocator, body) catch return null;
        } else if (std.mem.eql(u8, ctype, "IEND")) {
            saw_iend = true;
            break;
        }

        pos = body_end + 4; // skip CRC
    }

    if (!seen_ihdr or !saw_iend) return null;
    if (width == 0 or height == 0) return null;
    if (interlace != 0) return null; // Adam7 not supported
    if (bit_depth != 8) return null; // only 8-bit samples supported
    if (color_type == 3 and palette_len == 0) return null;

    // Samples (bytes) per pixel in the raw (filtered) scanline.
    const channels: usize = switch (color_type) {
        0 => 1, // grayscale
        2 => 3, // truecolor
        3 => 1, // indexed (1 byte = palette index)
        4 => 2, // grayscale + alpha
        6 => 4, // truecolor + alpha
        else => return null,
    };

    // Inflate the concatenated IDAT zlib stream. Each scanline is
    // prefixed by a 1-byte filter type, so raw size = h * (1 + w*channels).
    // `width`/`height` come straight from untrusted IHDR, so the size
    // arithmetic uses checked ops — an overflowed product would otherwise
    // under-allocate `raw` and let the unfilter loop write out of bounds.
    const stride = std.math.mul(usize, width, channels) catch return null; // bytes per row, no filter byte
    const row_len = std.math.add(usize, stride, 1) catch return null; // + filter byte
    const raw_size = std.math.mul(usize, height, row_len) catch return null;

    const raw = allocator.alloc(u8, raw_size) catch return null;
    defer allocator.free(raw);

    {
        var in_reader = std.Io.Reader.fixed(idat.items);
        var out_writer = std.Io.Writer.fixed(raw);
        // Empty window buffer = "direct" mode; flate reads straight from the
        // fixed input. `.zlib` container handles the 2-byte zlib header +
        // Adler-32 footer that wraps PNG's DEFLATE stream.
        var decompress = std.compress.flate.Decompress.init(&in_reader, .zlib, &.{});
        const n = decompress.reader.streamRemaining(&out_writer) catch return null;
        if (n != raw_size) return null; // wrong amount of data
    }

    // Output RGBA8 buffer. Checked arithmetic for the same untrusted-dims
    // overflow reason as `raw_size` above. (No `errdefer` here: this
    // function returns `?DecodedImage`, not an error union, so an errdefer
    // would never fire — the failure paths below free `pixels` manually.)
    const out_size = std.math.mul(usize, std.math.mul(usize, width, height) catch return null, 4) catch return null;
    const pixels = allocator.alloc(u8, out_size) catch return null;

    // Unfilter scanlines in place within `raw` (we overwrite the filtered
    // bytes with reconstructed ones, row by row, top to bottom).
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const row_off = y * (1 + stride);
        const filter = raw[row_off];
        const cur = raw[row_off + 1 ..][0..stride];
        const prev: ?[]const u8 = if (y == 0)
            null
        else
            raw[(y - 1) * (1 + stride) + 1 ..][0..stride];

        var i: usize = 0;
        while (i < stride) : (i += 1) {
            const a: i32 = if (i >= channels) cur[i - channels] else 0; // left
            const b: i32 = if (prev) |p| p[i] else 0; // up
            const c: i32 = if (prev != null and i >= channels) prev.?[i - channels] else 0; // up-left
            const x: i32 = cur[i];
            const recon: i32 = switch (filter) {
                0 => x, // None
                1 => x + a, // Sub
                2 => x + b, // Up
                3 => x + @divFloor(a + b, 2), // Average
                4 => x + paeth(a, b, c), // Paeth
                else => {
                    allocator.free(pixels);
                    return null;
                },
            };
            cur[i] = @truncate(@as(u32, @bitCast(recon)));
        }

        // Expand this reconstructed scanline to RGBA8.
        var px: usize = 0;
        while (px < width) : (px += 1) {
            const dst = (y * @as(usize, width) + px) * 4;
            switch (color_type) {
                0 => { // grayscale
                    const g = cur[px];
                    pixels[dst + 0] = g;
                    pixels[dst + 1] = g;
                    pixels[dst + 2] = g;
                    pixels[dst + 3] = 255;
                },
                2 => { // truecolor RGB
                    const s = px * 3;
                    pixels[dst + 0] = cur[s + 0];
                    pixels[dst + 1] = cur[s + 1];
                    pixels[dst + 2] = cur[s + 2];
                    pixels[dst + 3] = 255;
                },
                3 => { // indexed
                    const idx = cur[px];
                    if (idx >= palette_len) {
                        allocator.free(pixels);
                        return null;
                    }
                    pixels[dst + 0] = palette[idx][0];
                    pixels[dst + 1] = palette[idx][1];
                    pixels[dst + 2] = palette[idx][2];
                    pixels[dst + 3] = palette_alpha[idx];
                },
                4 => { // grayscale + alpha
                    const s = px * 2;
                    const g = cur[s + 0];
                    pixels[dst + 0] = g;
                    pixels[dst + 1] = g;
                    pixels[dst + 2] = g;
                    pixels[dst + 3] = cur[s + 1];
                },
                6 => { // truecolor + alpha
                    const s = px * 4;
                    pixels[dst + 0] = cur[s + 0];
                    pixels[dst + 1] = cur[s + 1];
                    pixels[dst + 2] = cur[s + 2];
                    pixels[dst + 3] = cur[s + 3];
                },
                else => unreachable,
            }
        }
    }

    return DecodedImage{ .pixels = pixels, .width = width, .height = height };
}

/// PNG Paeth predictor (filter type 4). Operates on i32 to avoid the
/// wraparound that the spec's byte arithmetic would otherwise mask.
fn paeth(a: i32, b: i32, c: i32) i32 {
    const p = a + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

// ── Text rendering (bitmap font atlas) ─────────────────────────────────

/// Minimal 8x8 bitmap font for basic text rendering.
/// Each character is an 8x8 monospaced glyph stored as 8 bytes (1 bit per pixel, MSB-left).
/// Printable ASCII range: 0x20 (' ') through 0x7E ('~').
const FONT_GLYPH_W = 8;
const FONT_GLYPH_H = 8;

// Embedded 8x8 font data for printable ASCII (space through '~', 95 glyphs).
// Each glyph is 8 rows of 8 bits packed into u8.
const font_data = initFontData();

fn initFontData() [95][8]u8 {
    // Minimal embedded bitmap font (subset — uppercase letters, digits, punctuation).
    // Unset glyphs render as hollow rectangles.
    var data: [95][8]u8 = [_][8]u8{.{ 0, 0, 0, 0, 0, 0, 0, 0 }} ** 95;

    // Space (0x20) — blank
    // '!' (0x21)
    data[0x21 - 0x20] = .{ 0x18, 0x18, 0x18, 0x18, 0x18, 0x00, 0x18, 0x00 };
    // '0' - '9'
    data[0x30 - 0x20] = .{ 0x3C, 0x66, 0x6E, 0x7E, 0x76, 0x66, 0x3C, 0x00 }; // 0
    data[0x31 - 0x20] = .{ 0x18, 0x38, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00 }; // 1
    data[0x32 - 0x20] = .{ 0x3C, 0x66, 0x06, 0x0C, 0x18, 0x30, 0x7E, 0x00 }; // 2
    data[0x33 - 0x20] = .{ 0x3C, 0x66, 0x06, 0x1C, 0x06, 0x66, 0x3C, 0x00 }; // 3
    data[0x34 - 0x20] = .{ 0x0C, 0x1C, 0x3C, 0x6C, 0x7E, 0x0C, 0x0C, 0x00 }; // 4
    data[0x35 - 0x20] = .{ 0x7E, 0x60, 0x7C, 0x06, 0x06, 0x66, 0x3C, 0x00 }; // 5
    data[0x36 - 0x20] = .{ 0x1C, 0x30, 0x60, 0x7C, 0x66, 0x66, 0x3C, 0x00 }; // 6
    data[0x37 - 0x20] = .{ 0x7E, 0x06, 0x0C, 0x18, 0x18, 0x18, 0x18, 0x00 }; // 7
    data[0x38 - 0x20] = .{ 0x3C, 0x66, 0x66, 0x3C, 0x66, 0x66, 0x3C, 0x00 }; // 8
    data[0x39 - 0x20] = .{ 0x3C, 0x66, 0x66, 0x3E, 0x06, 0x0C, 0x38, 0x00 }; // 9
    // A-Z
    data[0x41 - 0x20] = .{ 0x18, 0x3C, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x00 }; // A
    data[0x42 - 0x20] = .{ 0x7C, 0x66, 0x66, 0x7C, 0x66, 0x66, 0x7C, 0x00 }; // B
    data[0x43 - 0x20] = .{ 0x3C, 0x66, 0x60, 0x60, 0x60, 0x66, 0x3C, 0x00 }; // C
    data[0x44 - 0x20] = .{ 0x78, 0x6C, 0x66, 0x66, 0x66, 0x6C, 0x78, 0x00 }; // D
    data[0x45 - 0x20] = .{ 0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x7E, 0x00 }; // E
    data[0x46 - 0x20] = .{ 0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x60, 0x00 }; // F
    data[0x47 - 0x20] = .{ 0x3C, 0x66, 0x60, 0x6E, 0x66, 0x66, 0x3E, 0x00 }; // G
    data[0x48 - 0x20] = .{ 0x66, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x66, 0x00 }; // H
    data[0x49 - 0x20] = .{ 0x3C, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00 }; // I
    data[0x4A - 0x20] = .{ 0x06, 0x06, 0x06, 0x06, 0x06, 0x66, 0x3C, 0x00 }; // J
    data[0x4B - 0x20] = .{ 0x66, 0x6C, 0x78, 0x70, 0x78, 0x6C, 0x66, 0x00 }; // K
    data[0x4C - 0x20] = .{ 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x7E, 0x00 }; // L
    data[0x4D - 0x20] = .{ 0x63, 0x77, 0x7F, 0x6B, 0x63, 0x63, 0x63, 0x00 }; // M
    data[0x4E - 0x20] = .{ 0x66, 0x76, 0x7E, 0x7E, 0x6E, 0x66, 0x66, 0x00 }; // N
    data[0x4F - 0x20] = .{ 0x3C, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00 }; // O
    data[0x50 - 0x20] = .{ 0x7C, 0x66, 0x66, 0x7C, 0x60, 0x60, 0x60, 0x00 }; // P
    data[0x51 - 0x20] = .{ 0x3C, 0x66, 0x66, 0x66, 0x6A, 0x6C, 0x36, 0x00 }; // Q
    data[0x52 - 0x20] = .{ 0x7C, 0x66, 0x66, 0x7C, 0x6C, 0x66, 0x66, 0x00 }; // R
    data[0x53 - 0x20] = .{ 0x3C, 0x66, 0x60, 0x3C, 0x06, 0x66, 0x3C, 0x00 }; // S
    data[0x54 - 0x20] = .{ 0x7E, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00 }; // T
    data[0x55 - 0x20] = .{ 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00 }; // U
    data[0x56 - 0x20] = .{ 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x18, 0x00 }; // V
    data[0x57 - 0x20] = .{ 0x63, 0x63, 0x63, 0x6B, 0x7F, 0x77, 0x63, 0x00 }; // W
    data[0x58 - 0x20] = .{ 0x66, 0x66, 0x3C, 0x18, 0x3C, 0x66, 0x66, 0x00 }; // X
    data[0x59 - 0x20] = .{ 0x66, 0x66, 0x66, 0x3C, 0x18, 0x18, 0x18, 0x00 }; // Y
    data[0x5A - 0x20] = .{ 0x7E, 0x06, 0x0C, 0x18, 0x30, 0x60, 0x7E, 0x00 }; // Z
    // a-z (lowercase)
    data[0x61 - 0x20] = .{ 0x00, 0x00, 0x3C, 0x06, 0x3E, 0x66, 0x3E, 0x00 }; // a
    data[0x62 - 0x20] = .{ 0x60, 0x60, 0x7C, 0x66, 0x66, 0x66, 0x7C, 0x00 }; // b
    data[0x63 - 0x20] = .{ 0x00, 0x00, 0x3C, 0x66, 0x60, 0x66, 0x3C, 0x00 }; // c
    data[0x64 - 0x20] = .{ 0x06, 0x06, 0x3E, 0x66, 0x66, 0x66, 0x3E, 0x00 }; // d
    data[0x65 - 0x20] = .{ 0x00, 0x00, 0x3C, 0x66, 0x7E, 0x60, 0x3C, 0x00 }; // e
    data[0x66 - 0x20] = .{ 0x1C, 0x30, 0x30, 0x7C, 0x30, 0x30, 0x30, 0x00 }; // f
    data[0x67 - 0x20] = .{ 0x00, 0x00, 0x3E, 0x66, 0x66, 0x3E, 0x06, 0x3C }; // g
    data[0x68 - 0x20] = .{ 0x60, 0x60, 0x7C, 0x66, 0x66, 0x66, 0x66, 0x00 }; // h
    data[0x69 - 0x20] = .{ 0x18, 0x00, 0x38, 0x18, 0x18, 0x18, 0x3C, 0x00 }; // i
    data[0x6A - 0x20] = .{ 0x0C, 0x00, 0x1C, 0x0C, 0x0C, 0x0C, 0x6C, 0x38 }; // j
    data[0x6B - 0x20] = .{ 0x60, 0x60, 0x66, 0x6C, 0x78, 0x6C, 0x66, 0x00 }; // k
    data[0x6C - 0x20] = .{ 0x38, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00 }; // l
    data[0x6D - 0x20] = .{ 0x00, 0x00, 0x76, 0x7F, 0x6B, 0x63, 0x63, 0x00 }; // m
    data[0x6E - 0x20] = .{ 0x00, 0x00, 0x7C, 0x66, 0x66, 0x66, 0x66, 0x00 }; // n
    data[0x6F - 0x20] = .{ 0x00, 0x00, 0x3C, 0x66, 0x66, 0x66, 0x3C, 0x00 }; // o
    data[0x70 - 0x20] = .{ 0x00, 0x00, 0x7C, 0x66, 0x66, 0x7C, 0x60, 0x60 }; // p
    data[0x71 - 0x20] = .{ 0x00, 0x00, 0x3E, 0x66, 0x66, 0x3E, 0x06, 0x06 }; // q
    data[0x72 - 0x20] = .{ 0x00, 0x00, 0x6C, 0x76, 0x60, 0x60, 0x60, 0x00 }; // r
    data[0x73 - 0x20] = .{ 0x00, 0x00, 0x3E, 0x60, 0x3C, 0x06, 0x7C, 0x00 }; // s
    data[0x74 - 0x20] = .{ 0x30, 0x30, 0x7C, 0x30, 0x30, 0x30, 0x1C, 0x00 }; // t
    data[0x75 - 0x20] = .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x66, 0x3E, 0x00 }; // u
    data[0x76 - 0x20] = .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x3C, 0x18, 0x00 }; // v
    data[0x77 - 0x20] = .{ 0x00, 0x00, 0x63, 0x6B, 0x7F, 0x7F, 0x36, 0x00 }; // w
    data[0x78 - 0x20] = .{ 0x00, 0x00, 0x66, 0x3C, 0x18, 0x3C, 0x66, 0x00 }; // x
    data[0x79 - 0x20] = .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x3E, 0x06, 0x3C }; // y
    data[0x7A - 0x20] = .{ 0x00, 0x00, 0x7E, 0x0C, 0x18, 0x30, 0x7E, 0x00 }; // z
    // Common punctuation
    data[0x2E - 0x20] = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00 }; // .
    data[0x2C - 0x20] = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x30 }; // ,
    data[0x3A - 0x20] = .{ 0x00, 0x18, 0x18, 0x00, 0x00, 0x18, 0x18, 0x00 }; // :
    data[0x3B - 0x20] = .{ 0x00, 0x18, 0x18, 0x00, 0x00, 0x18, 0x18, 0x30 }; // ;
    data[0x2D - 0x20] = .{ 0x00, 0x00, 0x00, 0x7E, 0x00, 0x00, 0x00, 0x00 }; // -
    data[0x3D - 0x20] = .{ 0x00, 0x00, 0x7E, 0x00, 0x7E, 0x00, 0x00, 0x00 }; // =
    data[0x28 - 0x20] = .{ 0x0C, 0x18, 0x30, 0x30, 0x30, 0x18, 0x0C, 0x00 }; // (
    data[0x29 - 0x20] = .{ 0x30, 0x18, 0x0C, 0x0C, 0x0C, 0x18, 0x30, 0x00 }; // )
    data[0x5B - 0x20] = .{ 0x3C, 0x30, 0x30, 0x30, 0x30, 0x30, 0x3C, 0x00 }; // [
    data[0x5D - 0x20] = .{ 0x3C, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x3C, 0x00 }; // ]
    data[0x2F - 0x20] = .{ 0x02, 0x06, 0x0C, 0x18, 0x30, 0x60, 0x40, 0x00 }; // /
    data[0x3F - 0x20] = .{ 0x3C, 0x66, 0x06, 0x0C, 0x18, 0x00, 0x18, 0x00 }; // ?

    return data;
}

// ── Glyph atlas ────────────────────────────────────────────────────────
//
// Text renders through the textured-sprite path: the embedded 8x8 bitmap
// font is baked ONCE into an RGBA8 atlas texture, and each printable glyph
// is drawn as a single sampled sprite quad (vs. the old per-pixel solid
// shape-quad rasterizer). The atlas lays the 95 printable glyphs in a
// FONT_ATLAS_COLS x FONT_ATLAS_ROWS grid; each cell carries the 8x8 glyph
// plus FONT_ATLAS_PAD px of transparent padding on every side so nearest
// sampling at a quad edge can never bleed into a neighbouring cell.
//
// Per-texel encoding: white RGB (255,255,255) with alpha = coverage (255
// where the font bit is set, 0 where clear); padding texels are fully
// transparent (0,0,0,0). The sprite fragment shader computes `texel *
// vColor`, so a quad tinted by `tint` yields (tint.rgb, tint.a * coverage)
// — correctly tinted text with crisp edges under the nearest sampler.
const FONT_ATLAS_COLS = 16;
const FONT_ATLAS_ROWS = 6; // 16*6 = 96 cells >= 95 glyphs
const FONT_ATLAS_PAD = 1; // transparent border px around each glyph cell
const FONT_ATLAS_CELL_W = FONT_GLYPH_W + 2 * FONT_ATLAS_PAD; // 10
const FONT_ATLAS_CELL_H = FONT_GLYPH_H + 2 * FONT_ATLAS_PAD; // 10
const FONT_ATLAS_W = FONT_ATLAS_COLS * FONT_ATLAS_CELL_W; // 160
const FONT_ATLAS_H = FONT_ATLAS_ROWS * FONT_ATLAS_CELL_H; // 60

/// Texture id of the baked glyph atlas, or 0 = "not built yet". Texture id
/// 0 is never handed out (`next_texture_id` starts at 1), so it's a safe
/// sentinel. Built lazily on the first `drawText`.
var font_atlas_texture_id: u32 = 0;

/// Render the embedded bitmap font into an RGBA8 pixel buffer laid out as
/// the glyph atlas described above. White-RGB + alpha-coverage encoding;
/// padding texels are transparent.
fn buildFontAtlasPixels(buf: *[FONT_ATLAS_W * FONT_ATLAS_H * 4]u8) void {
    // Start fully transparent — this also covers all padding texels.
    @memset(buf, 0);
    for (font_data, 0..) |glyph, gi| {
        const cell_col = gi % FONT_ATLAS_COLS;
        const cell_row = gi / FONT_ATLAS_COLS;
        const origin_x = cell_col * FONT_ATLAS_CELL_W + FONT_ATLAS_PAD;
        const origin_y = cell_row * FONT_ATLAS_CELL_H + FONT_ATLAS_PAD;
        for (glyph, 0..) |row_bits, row| {
            var c: usize = 0;
            while (c < FONT_GLYPH_W) : (c += 1) {
                const set = (row_bits >> @intCast(FONT_GLYPH_W - 1 - c)) & 1 == 1;
                if (!set) continue; // leave transparent
                const px = origin_x + c;
                const py = origin_y + row;
                const idx = (py * FONT_ATLAS_W + px) * 4;
                buf[idx + 0] = 255; // R
                buf[idx + 1] = 255; // G
                buf[idx + 2] = 255; // B
                buf[idx + 3] = 255; // A = coverage
            }
        }
    }
}

/// Build + upload the glyph atlas texture if it hasn't been built yet.
/// Returns the texture id, or 0 on failure (upload error).
fn ensureFontAtlas() u32 {
    if (font_atlas_texture_id != 0) return font_atlas_texture_id;
    var pixels: [FONT_ATLAS_W * FONT_ATLAS_H * 4]u8 = undefined;
    buildFontAtlasPixels(&pixels);
    // uploadTexture COPIES the pixels into a slot it owns, so a stack
    // buffer that dies at return is fine.
    const tex = uploadTexture(.{
        .pixels = pixels[0..],
        .width = FONT_ATLAS_W,
        .height = FONT_ATLAS_H,
    }) catch {
        log.warn("failed to upload glyph atlas; text will not render", .{});
        return 0;
    };
    font_atlas_texture_id = tex.id;
    return font_atlas_texture_id;
}

pub fn drawText(text: [:0]const u8, x: f32, y: f32, size: f32, tint: Color) void {
    const atlas_id = ensureFontAtlas();
    if (atlas_id == 0) return; // atlas build failed; nothing to draw

    const col = tint.toAbgr();
    const scale = size / @as(f32, FONT_GLYPH_H);
    const glyph_w: f32 = @as(f32, FONT_GLYPH_W) * scale;

    const atlas_w_f: f32 = @as(f32, FONT_ATLAS_W);
    const atlas_h_f: f32 = @as(f32, FONT_ATLAS_H);

    var cursor_x = x;
    for (text) |ch| {
        if (ch == 0) break; // NUL terminator
        // Printable, non-space glyphs emit one textured quad. Space (0x20)
        // and out-of-range chars emit nothing but still advance the cursor,
        // keeping metrics identical to the old rasterizer (width == n_chars
        // * glyph_w).
        if (ch > 0x20 and ch <= 0x7E) {
            if (!hasSpriteCapacity(4, 6)) {
                log.warn("sprite batch full, dropping text glyphs", .{});
                return;
            }

            const gi: usize = ch - 0x20;
            const cell_col = gi % FONT_ATLAS_COLS;
            const cell_row = gi / FONT_ATLAS_COLS;
            // Inner 8x8 region (padding excluded) — UVs map exactly to it,
            // so nearest sampling never picks a padding/neighbour texel.
            const inner_x: f32 = @floatFromInt(cell_col * FONT_ATLAS_CELL_W + FONT_ATLAS_PAD);
            const inner_y: f32 = @floatFromInt(cell_row * FONT_ATLAS_CELL_H + FONT_ATLAS_PAD);
            const uv_x0 = inner_x / atlas_w_f;
            const uv_y0 = inner_y / atlas_h_f;
            const uv_x1 = (inner_x + @as(f32, FONT_GLYPH_W)) / atlas_w_f;
            const uv_y1 = (inner_y + @as(f32, FONT_GLYPH_H)) / atlas_h_f;

            // Screen rect for the whole glyph cell (same metrics as before).
            const gx0 = cursor_x;
            const gy0 = y;
            const gx1 = cursor_x + glyph_w;
            const gy1 = y + size;

            const seg_index_start: u32 = @intCast(sprite_index_count);
            const seg_quad_start: u32 = @intCast(sprite_quad_count);

            if (sprite_quad_count < MAX_SPRITE_QUADS) {
                sprite_texture_ids[sprite_quad_count] = atlas_id;
                sprite_quad_count += 1;
            }

            const base: u32 = @intCast(sprite_vertex_count);
            // TL, TR, BR, BL — matches drawTexturePro winding/index pattern.
            appendSpriteVertex(SpriteVertex.init(toNdcX(gx0), toNdcY(gy0), uv_x0, uv_y0, col));
            appendSpriteVertex(SpriteVertex.init(toNdcX(gx1), toNdcY(gy0), uv_x1, uv_y0, col));
            appendSpriteVertex(SpriteVertex.init(toNdcX(gx1), toNdcY(gy1), uv_x1, uv_y1, col));
            appendSpriteVertex(SpriteVertex.init(toNdcX(gx0), toNdcY(gy1), uv_x0, uv_y1, col));

            appendSpriteIndex(base + 0);
            appendSpriteIndex(base + 1);
            appendSpriteIndex(base + 2);
            appendSpriteIndex(base + 0);
            appendSpriteIndex(base + 2);
            appendSpriteIndex(base + 3);

            noteSpriteDraw(seg_index_start, 6, seg_quad_start);
        }
        cursor_x += glyph_w;
    }
}

// ── Utility functions ──────────────────────────────────────────────────

pub fn color(r: u8, g: u8, b: u8, a: u8) Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}

pub fn beginMode2D(camera: Camera2D) void {
    active_camera = camera;
}

pub fn endMode2D() void {
    active_camera = null;
}

pub fn getScreenWidth() i32 {
    return screen_w;
}

pub fn getScreenHeight() i32 {
    return screen_h;
}

/// No-op: wgpu backend handles DPI scaling via its own screen size queries.
pub fn setDesignSize(_: i32, _: i32) void {}

pub fn screenToWorld(pos: Vector2, camera: Camera2D) Vector2 {
    return .{
        .x = (pos.x - camera.offset.x) / camera.zoom + camera.target.x,
        .y = (pos.y - camera.offset.y) / camera.zoom + camera.target.y,
    };
}

pub fn worldToScreen(pos: Vector2, camera: Camera2D) Vector2 {
    return .{
        .x = (pos.x - camera.target.x) * camera.zoom + camera.offset.x,
        .y = (pos.y - camera.target.y) * camera.zoom + camera.offset.y,
    };
}

// ── PNG decoder tests ──────────────────────────────────────────────────
// Each fixture is a real PNG (produced by zlib + the PNG spec, see the
// generator in PR #293's history) embedded as a byte array so the test
// is self-contained and exercises the full sniff → inflate → unfilter →
// RGBA8 pipeline.

// ── Ordered draw-segment tests ─────────────────────────────────────────
// Pure-CPU: drive the draw API and assert consumeFrame() yields segments
// in submission order with correct index/quad ranges. No GPU needed.

test "draw segments: shape -> sprite -> shape preserves submission order" {
    // Clear any state leaked from a prior test in this process.
    _ = consumeFrame();
    setScreenSize(800, 600);

    const tex = Texture{ .id = 1, .width = 16, .height = 16 };

    // Shape (rect = 6 indices), then sprite (1 quad = 6 indices), then shape.
    drawRectangleRec(.{ .x = 0, .y = 0, .width = 10, .height = 10 }, white);
    drawTexturePro(tex, .{ .x = 0, .y = 0, .width = 16, .height = 16 }, .{ .x = 0, .y = 0, .width = 16, .height = 16 }, .{ .x = 0, .y = 0 }, 0, white);
    drawRectangleRec(.{ .x = 20, .y = 20, .width = 10, .height = 10 }, red);

    const frame = consumeFrame();

    try std.testing.expectEqual(@as(usize, 3), frame.segments.len);

    // Segment 0: shape, first 6 shape indices.
    try std.testing.expectEqual(SegmentKind.shape, frame.segments[0].kind);
    try std.testing.expectEqual(@as(u32, 0), frame.segments[0].index_start);
    try std.testing.expectEqual(@as(u32, 6), frame.segments[0].index_count);

    // Segment 1: sprite, first 6 sprite indices, quad 0.
    try std.testing.expectEqual(SegmentKind.sprite, frame.segments[1].kind);
    try std.testing.expectEqual(@as(u32, 0), frame.segments[1].index_start);
    try std.testing.expectEqual(@as(u32, 6), frame.segments[1].index_count);
    try std.testing.expectEqual(@as(u32, 0), frame.segments[1].quad_start);
    try std.testing.expectEqual(@as(u32, 1), frame.segments[1].quad_count);

    // Segment 2: shape, next 6 shape indices (offset 6, since the sprite
    // lives in a SEPARATE index buffer).
    try std.testing.expectEqual(SegmentKind.shape, frame.segments[2].kind);
    try std.testing.expectEqual(@as(u32, 6), frame.segments[2].index_start);
    try std.testing.expectEqual(@as(u32, 6), frame.segments[2].index_count);

    // Buffers: 2 shape rects = 8 verts / 12 indices; 1 sprite = 4 verts / 6
    // indices / 1 texture id.
    try std.testing.expectEqual(@as(usize, 8), frame.shape_vertices.len);
    try std.testing.expectEqual(@as(usize, 12), frame.shape_indices.len);
    try std.testing.expectEqual(@as(usize, 4), frame.sprite_vertices.len);
    try std.testing.expectEqual(@as(usize, 6), frame.sprite_indices.len);
    try std.testing.expectEqual(@as(usize, 1), frame.sprite_texture_ids.len);
    try std.testing.expectEqual(@as(u32, 1), frame.sprite_texture_ids[0]);
}

test "draw segments: consecutive same-kind draws coalesce into one segment" {
    _ = consumeFrame();
    setScreenSize(800, 600);

    const tex = Texture{ .id = 2, .width = 16, .height = 16 };

    // sprite, sprite, shape: the two sprites must merge into one segment.
    drawTexturePro(tex, .{ .x = 0, .y = 0, .width = 16, .height = 16 }, .{ .x = 0, .y = 0, .width = 16, .height = 16 }, .{ .x = 0, .y = 0 }, 0, white);
    drawTexturePro(tex, .{ .x = 0, .y = 0, .width = 16, .height = 16 }, .{ .x = 16, .y = 0, .width = 16, .height = 16 }, .{ .x = 0, .y = 0 }, 0, white);
    drawRectangleRec(.{ .x = 0, .y = 0, .width = 10, .height = 10 }, white);

    const frame = consumeFrame();

    try std.testing.expectEqual(@as(usize, 2), frame.segments.len);

    // Segment 0: one sprite segment spanning both quads.
    try std.testing.expectEqual(SegmentKind.sprite, frame.segments[0].kind);
    try std.testing.expectEqual(@as(u32, 0), frame.segments[0].index_start);
    try std.testing.expectEqual(@as(u32, 12), frame.segments[0].index_count);
    try std.testing.expectEqual(@as(u32, 0), frame.segments[0].quad_start);
    try std.testing.expectEqual(@as(u32, 2), frame.segments[0].quad_count);

    // Segment 1: the trailing shape.
    try std.testing.expectEqual(SegmentKind.shape, frame.segments[1].kind);
    try std.testing.expectEqual(@as(u32, 0), frame.segments[1].index_start);
    try std.testing.expectEqual(@as(u32, 6), frame.segments[1].index_count);
}

test "draw segments: consumeFrame resets the segment list exactly once" {
    _ = consumeFrame();
    drawRectangleRec(.{ .x = 0, .y = 0, .width = 10, .height = 10 }, white);
    const first = consumeFrame();
    try std.testing.expectEqual(@as(usize, 1), first.segments.len);

    // Next frame starts empty — no leakage.
    const second = consumeFrame();
    try std.testing.expectEqual(@as(usize, 0), second.segments.len);
    try std.testing.expectEqual(@as(usize, 0), second.shape_indices.len);
    try std.testing.expectEqual(@as(usize, 0), second.sprite_indices.len);
}

test "decodePng: 2x2 truecolor+alpha (filter None)" {
    // Pixels (row-major): (255,0,0,255) (0,255,0,128) / (0,0,255,255) (255,255,0,64)
    const png_rgba_2x2 = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x06, 0x00, 0x00, 0x00, 0x72, 0xb6, 0x0d, 0x24, 0x00, 0x00, 0x00, 0x16, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0xf8, 0xcf, 0xc0, 0xf0, 0x1f, 0x08, 0x1b, 0x18, 0x80, 0x34, 0x10, 0x30, 0x38, 0x00, 0x00, 0x42, 0x15, 0x07, 0xba, 0x58, 0x65, 0x3e, 0xfa, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 };
    const img = decodePng(&png_rgba_2x2, std.testing.allocator) orelse return error.DecodeFailed;
    defer std.testing.allocator.free(img.pixels);
    try std.testing.expectEqual(@as(u32, 2), img.width);
    try std.testing.expectEqual(@as(u32, 2), img.height);
    const want = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 255, 255, 255, 0, 64 };
    try std.testing.expectEqualSlices(u8, &want, img.pixels);
}

test "decodePng: 3x1 truecolor RGB with Sub filter" {
    // Pixels: (10,20,30) (40,60,80) (200,100,50), all alpha padded to 255.
    const png_rgb_sub_3x1 = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x94, 0x82, 0x83, 0xe3, 0x00, 0x00, 0x00, 0x12, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0xe4, 0x12, 0x91, 0x93, 0xd3, 0x30, 0x5a, 0xa0, 0xf1, 0x08, 0x00, 0x07, 0x36, 0x02, 0x60, 0x4d, 0x9d, 0x20, 0xcd, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 };
    const img = decodePng(&png_rgb_sub_3x1, std.testing.allocator) orelse return error.DecodeFailed;
    defer std.testing.allocator.free(img.pixels);
    try std.testing.expectEqual(@as(u32, 3), img.width);
    try std.testing.expectEqual(@as(u32, 1), img.height);
    const want = [_]u8{ 10, 20, 30, 255, 40, 60, 80, 255, 200, 100, 50, 255 };
    try std.testing.expectEqualSlices(u8, &want, img.pixels);
}

test "decodePng: 2x2 indexed palette with tRNS alpha" {
    // Palette: idx0=red(255,0,0) a=255, idx1=green(0,255,0) a=128.
    // Indices row-major: 0,1 / 1,0
    const png_indexed_2x2 = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x03, 0x00, 0x00, 0x00, 0x45, 0x68, 0xfd, 0x16, 0x00, 0x00, 0x00, 0x06, 0x50, 0x4c, 0x54, 0x45, 0xff, 0x00, 0x00, 0x00, 0xff, 0x00, 0xd2, 0x87, 0xef, 0x71, 0x00, 0x00, 0x00, 0x02, 0x74, 0x52, 0x4e, 0x53, 0xff, 0x80, 0x08, 0x0f, 0xb3, 0x6a, 0x00, 0x00, 0x00, 0x0c, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x60, 0x60, 0x04, 0x42, 0x00, 0x00, 0x0c, 0x00, 0x03, 0x15, 0x9e, 0x18, 0xfc, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 };
    const img = decodePng(&png_indexed_2x2, std.testing.allocator) orelse return error.DecodeFailed;
    defer std.testing.allocator.free(img.pixels);
    try std.testing.expectEqual(@as(u32, 2), img.width);
    try std.testing.expectEqual(@as(u32, 2), img.height);
    const want = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 128, 0, 255, 0, 128, 255, 0, 0, 255 };
    try std.testing.expectEqualSlices(u8, &want, img.pixels);
}

test "decodePng: 1x2 grayscale+alpha with Up filter" {
    // Row0 (gray=100, a=255), Row1 (gray=50, a=128); row1 uses Up filter.
    const png_gray_alpha_up_1x2 = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x08, 0x04, 0x00, 0x00, 0x00, 0x33, 0x88, 0x7e, 0xac, 0x00, 0x00, 0x00, 0x0e, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x48, 0xf9, 0xcf, 0x74, 0xae, 0x11, 0x00, 0x08, 0x19, 0x02, 0xb5, 0xd5, 0xbb, 0x84, 0x9c, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 };
    const img = decodePng(&png_gray_alpha_up_1x2, std.testing.allocator) orelse return error.DecodeFailed;
    defer std.testing.allocator.free(img.pixels);
    try std.testing.expectEqual(@as(u32, 1), img.width);
    try std.testing.expectEqual(@as(u32, 2), img.height);
    const want = [_]u8{ 100, 100, 100, 255, 50, 50, 50, 128 };
    try std.testing.expectEqualSlices(u8, &want, img.pixels);
}

test "decodePng: rejects non-PNG and routes through decodeImage" {
    const not_png = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    try std.testing.expect(decodePng(&not_png, std.testing.allocator) == null);

    // decodeImage should dispatch a real PNG to the PNG decoder.
    const png_rgba_2x2 = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x06, 0x00, 0x00, 0x00, 0x72, 0xb6, 0x0d, 0x24, 0x00, 0x00, 0x00, 0x16, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0xf8, 0xcf, 0xc0, 0xf0, 0x1f, 0x08, 0x1b, 0x18, 0x80, 0x34, 0x10, 0x30, 0x38, 0x00, 0x00, 0x42, 0x15, 0x07, 0xba, 0x58, 0x65, 0x3e, 0xfa, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 };
    const img = try decodeImage("", &png_rgba_2x2, std.testing.allocator);
    defer std.testing.allocator.free(img.pixels);
    try std.testing.expectEqual(@as(u32, 2), img.width);
}
