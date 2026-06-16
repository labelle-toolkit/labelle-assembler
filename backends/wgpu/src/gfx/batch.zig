/// Vertex/index batch state + the ordered draw-segment stream for the
/// WebGPU backend. Owns the shape + sprite vertex/index buffers, the
/// per-quad texture-id table, and the segment list that records
/// shape/sprite submission order. The draw/font submodules append into
/// these buffers; the window submitter drains them once per frame via
/// `consumeFrame`.
const std = @import("std");
const types = @import("types.zig");

const log = std.log.scoped(.wgpu_gfx);

const ColorVertex = types.ColorVertex;
const SpriteVertex = types.SpriteVertex;

// ── Shape batch ───────────────────────────────────────────────────────

pub const MAX_SHAPE_VERTICES = 16384;
pub const MAX_SHAPE_INDICES = 32768;
pub const MAX_SPRITE_VERTICES = 8192;
pub const MAX_SPRITE_INDICES = 16384;
pub const MAX_SPRITE_QUADS = MAX_SPRITE_VERTICES / 4;

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
pub fn noteShapeDraw(index_start: u32, n_indices: u32) void {
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
pub fn noteSpriteDraw(index_start: u32, n_indices: u32, quad_start: u32) void {
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

// ── Batch accessors (used by the draw/font submodules) ─────────────────

pub fn shapeVertexCount() usize {
    return shape_vertex_count;
}

pub fn shapeIndexCount() usize {
    return shape_index_count;
}

pub fn spriteVertexCount() usize {
    return sprite_vertex_count;
}

pub fn spriteIndexCount() usize {
    return sprite_index_count;
}

pub fn spriteQuadCount() usize {
    return sprite_quad_count;
}

/// Check whether the shape batch has room for the given number of vertices and indices.
pub fn hasShapeCapacity(verts: usize, idxs: usize) bool {
    return (shape_vertex_count + verts <= MAX_SHAPE_VERTICES) and
        (shape_index_count + idxs <= MAX_SHAPE_INDICES);
}

/// Check whether the sprite batch has room for the given number of vertices and indices.
pub fn hasSpriteCapacity(verts: usize, idxs: usize) bool {
    return (sprite_vertex_count + verts <= MAX_SPRITE_VERTICES) and
        (sprite_index_count + idxs <= MAX_SPRITE_INDICES);
}

pub fn appendShapeVertex(v: ColorVertex) void {
    shape_vertices[shape_vertex_count] = v;
    shape_vertex_count += 1;
}

pub fn appendShapeIndex(idx: u32) void {
    shape_indices[shape_index_count] = idx;
    shape_index_count += 1;
}

pub fn appendSpriteVertex(v: SpriteVertex) void {
    sprite_vertices[sprite_vertex_count] = v;
    sprite_vertex_count += 1;
}

pub fn appendSpriteIndex(idx: u32) void {
    sprite_indices[sprite_index_count] = idx;
    sprite_index_count += 1;
}

/// Record a sprite quad's texture id (one per 4 verts / 6 indices). No-op
/// past the quad cap so the buffer never overruns.
pub fn appendSpriteTextureId(id: u32) void {
    if (sprite_quad_count < MAX_SPRITE_QUADS) {
        sprite_texture_ids[sprite_quad_count] = id;
        sprite_quad_count += 1;
    }
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
