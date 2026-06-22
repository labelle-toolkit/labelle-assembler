/// Shape primitives (rect / circle / line / triangle / polygon) and the
/// textured-quad sprite draw for the WebGPU backend. State-free: positions
/// are mapped to NDC via `state.toNdcX/toNdcY` (which apply the active
/// camera + the HiDPI design→physical aspect-fit) and appended into the
/// shared batch buffers in `batch.zig`.
const std = @import("std");
const types = @import("types.zig");
const state = @import("state.zig");
const batch = @import("batch.zig");

const log = std.log.scoped(.wgpu_gfx);

const Color = types.Color;
const Rectangle = types.Rectangle;
const Vector2 = types.Vector2;
const Texture = types.Texture;
const ColorVertex = types.ColorVertex;
const SpriteVertex = types.SpriteVertex;

const toNdcX = state.toNdcX;
const toNdcY = state.toNdcY;

// ── Draw primitives (Backend contract) ─────────────────────────────────

pub fn drawRectangleRec(rec: Rectangle, tint: Color) void {
    if (!batch.hasShapeCapacity(4, 6)) {
        log.warn("shape batch full, dropping rectangle primitive", .{});
        return;
    }
    const col = tint.toAbgr();
    const x = rec.x;
    const y = rec.y;
    const w = rec.width;
    const h = rec.height;
    const base: u32 = @intCast(batch.shapeVertexCount());
    const index_start: u32 = @intCast(batch.shapeIndexCount());

    // 4 vertices for the rectangle
    batch.appendShapeVertex(ColorVertex.init(toNdcX(x), toNdcY(y), col));
    batch.appendShapeVertex(ColorVertex.init(toNdcX(x + w), toNdcY(y), col));
    batch.appendShapeVertex(ColorVertex.init(toNdcX(x + w), toNdcY(y + h), col));
    batch.appendShapeVertex(ColorVertex.init(toNdcX(x), toNdcY(y + h), col));

    // 2 triangles (CCW winding)
    batch.appendShapeIndex(base + 0);
    batch.appendShapeIndex(base + 1);
    batch.appendShapeIndex(base + 2);
    batch.appendShapeIndex(base + 0);
    batch.appendShapeIndex(base + 2);
    batch.appendShapeIndex(base + 3);

    batch.noteShapeDraw(index_start, 6);
}

pub fn drawCircle(center_x: f32, center_y: f32, radius: f32, tint: Color) void {
    const segments: u32 = 36;
    if (!batch.hasShapeCapacity(segments + 2, segments * 3)) {
        log.warn("shape batch full, dropping circle primitive", .{});
        return;
    }
    const col = tint.toAbgr();
    const base: u32 = @intCast(batch.shapeVertexCount());
    const index_start: u32 = @intCast(batch.shapeIndexCount());

    // Center vertex
    batch.appendShapeVertex(ColorVertex.init(toNdcX(center_x), toNdcY(center_y), col));

    // Perimeter vertices
    var i: u32 = 0;
    while (i <= segments) : (i += 1) {
        const angle = (@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments))) * 2.0 * std.math.pi;
        const px = center_x + @cos(angle) * radius;
        const py = center_y + @sin(angle) * radius;
        batch.appendShapeVertex(ColorVertex.init(toNdcX(px), toNdcY(py), col));
    }

    // Fan triangles (center + 2 consecutive perimeter vertices)
    i = 0;
    while (i < segments) : (i += 1) {
        batch.appendShapeIndex(base); // center
        batch.appendShapeIndex(base + i + 1);
        batch.appendShapeIndex(base + i + 2);
    }

    batch.noteShapeDraw(index_start, segments * 3);
}

pub fn drawLine(start_x: f32, start_y: f32, end_x: f32, end_y: f32, thickness: f32, tint: Color) void {
    if (!batch.hasShapeCapacity(4, 6)) {
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

    const base: u32 = @intCast(batch.shapeVertexCount());
    const index_start: u32 = @intCast(batch.shapeIndexCount());

    // Quad from 4 offset vertices
    batch.appendShapeVertex(ColorVertex.init(toNdcX(start_x + perp_x), toNdcY(start_y + perp_y), col));
    batch.appendShapeVertex(ColorVertex.init(toNdcX(start_x - perp_x), toNdcY(start_y - perp_y), col));
    batch.appendShapeVertex(ColorVertex.init(toNdcX(end_x - perp_x), toNdcY(end_y - perp_y), col));
    batch.appendShapeVertex(ColorVertex.init(toNdcX(end_x + perp_x), toNdcY(end_y + perp_y), col));

    batch.appendShapeIndex(base + 0);
    batch.appendShapeIndex(base + 1);
    batch.appendShapeIndex(base + 2);
    batch.appendShapeIndex(base + 0);
    batch.appendShapeIndex(base + 2);
    batch.appendShapeIndex(base + 3);

    batch.noteShapeDraw(index_start, 6);
}

/// Filled triangle through the three absolute vertices `v1`, `v2`,
/// `v3` (design-pixel space — position + scale already applied by the
/// caller). Point/Color signature matches the labelle-gfx Backend
/// contract; the three vertices are batched as one shape triangle.
pub fn drawTriangle(v1: Vector2, v2: Vector2, v3: Vector2, tint: Color) void {
    if (!batch.hasShapeCapacity(3, 3)) {
        log.warn("shape batch full, dropping triangle primitive", .{});
        return;
    }
    const col = tint.toAbgr();
    const base: u32 = @intCast(batch.shapeVertexCount());
    const index_start: u32 = @intCast(batch.shapeIndexCount());

    batch.appendShapeVertex(ColorVertex.init(toNdcX(v1.x), toNdcY(v1.y), col));
    batch.appendShapeVertex(ColorVertex.init(toNdcX(v2.x), toNdcY(v2.y), col));
    batch.appendShapeVertex(ColorVertex.init(toNdcX(v3.x), toNdcY(v3.y), col));

    batch.appendShapeIndex(base + 0);
    batch.appendShapeIndex(base + 1);
    batch.appendShapeIndex(base + 2);

    batch.noteShapeDraw(index_start, 3);
}

/// Filled convex polygon through the absolute rim vertices in `points`
/// (design-pixel space — centre + scale already applied by the caller).
/// Slice/Color signature matches the labelle-gfx Backend contract; the
/// rim is batched as a triangle fan anchored at `points[0]`.
/// Max rim points a single polygon may carry. Guards the u32 index math
/// below from overflow (a count this large could never fit the shape batch
/// anyway); the gfx renderer already clamps polygon/arc tessellation to 128.
pub const max_polygon_points: usize = 256;

pub fn drawPolygon(points: []const Vector2, tint: Color) void {
    if (points.len < 3) return;
    if (points.len > max_polygon_points) {
        log.warn("polygon has {d} rim points (> max {d}), dropping", .{ points.len, max_polygon_points });
        return;
    }
    const num_verts: u32 = @intCast(points.len);
    const num_triangles: u32 = num_verts - 2;
    const num_indices: u32 = num_triangles * 3;
    if (!batch.hasShapeCapacity(num_verts, num_indices)) {
        log.warn("shape batch full, dropping polygon primitive", .{});
        return;
    }
    const col = tint.toAbgr();
    const base: u32 = @intCast(batch.shapeVertexCount());
    const index_start: u32 = @intCast(batch.shapeIndexCount());

    for (points) |p| {
        batch.appendShapeVertex(ColorVertex.init(toNdcX(p.x), toNdcY(p.y), col));
    }

    // Fan triangles: (points[0], points[i+1], points[i+2]).
    var i: u32 = 0;
    while (i < num_triangles) : (i += 1) {
        batch.appendShapeIndex(base);
        batch.appendShapeIndex(base + i + 1);
        batch.appendShapeIndex(base + i + 2);
    }

    batch.noteShapeDraw(index_start, num_indices);
}

pub fn drawPoly(center_x: f32, center_y: f32, sides: i32, radius: f32, rotation: f32, tint: Color) void {
    if (sides < 3 or radius <= 0) return;
    const num_sides: u32 = @intCast(sides);
    if (!batch.hasShapeCapacity(num_sides + 2, num_sides * 3)) {
        log.warn("shape batch full, dropping polygon primitive", .{});
        return;
    }
    const col = tint.toAbgr();
    const base: u32 = @intCast(batch.shapeVertexCount());
    const index_start: u32 = @intCast(batch.shapeIndexCount());

    // Convert rotation from degrees to radians (consistent with drawTexturePro / raylib convention)
    const rot_rad = rotation * std.math.pi / 180.0;

    // Center vertex
    batch.appendShapeVertex(ColorVertex.init(toNdcX(center_x), toNdcY(center_y), col));

    // Perimeter vertices
    var i: u32 = 0;
    while (i <= num_sides) : (i += 1) {
        const angle = rot_rad + (@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(num_sides))) * 2.0 * std.math.pi;
        const px = center_x + @cos(angle) * radius;
        const py = center_y + @sin(angle) * radius;
        batch.appendShapeVertex(ColorVertex.init(toNdcX(px), toNdcY(py), col));
    }

    // Fan triangles
    i = 0;
    while (i < num_sides) : (i += 1) {
        batch.appendShapeIndex(base);
        batch.appendShapeIndex(base + i + 1);
        batch.appendShapeIndex(base + i + 2);
    }

    batch.noteShapeDraw(index_start, num_sides * 3);
}

// ── Texture / Sprite rendering ─────────────────────────────────────────

pub fn drawTexturePro(texture: Texture, source: Rectangle, dest: Rectangle, origin: Vector2, rotation: f32, tint: Color) void {
    if (!batch.hasSpriteCapacity(4, 6)) {
        log.warn("sprite batch full, dropping sprite primitive", .{});
        return;
    }
    const col = tint.toAbgr();

    // Capture the pre-append offsets for the ordered segment record.
    const seg_index_start: u32 = @intCast(batch.spriteIndexCount());
    const seg_quad_start: u32 = @intCast(batch.spriteQuadCount());

    // Track which texture this quad uses so the renderer can bind correctly.
    batch.appendSpriteTextureId(texture.id);

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

    const base: u32 = @intCast(batch.spriteVertexCount());

    // Top-left
    const tx0 = dest.x + (x0 * cos_r - y0 * sin_r);
    const ty0 = dest.y + (x0 * sin_r + y0 * cos_r);
    batch.appendSpriteVertex(SpriteVertex.init(toNdcX(tx0), toNdcY(ty0), uv_x0, uv_y0, col));

    // Top-right
    const tx1 = dest.x + (x1 * cos_r - y0 * sin_r);
    const ty1 = dest.y + (x1 * sin_r + y0 * cos_r);
    batch.appendSpriteVertex(SpriteVertex.init(toNdcX(tx1), toNdcY(ty1), uv_x1, uv_y0, col));

    // Bottom-right
    const tx2 = dest.x + (x1 * cos_r - y1 * sin_r);
    const ty2 = dest.y + (x1 * sin_r + y1 * cos_r);
    batch.appendSpriteVertex(SpriteVertex.init(toNdcX(tx2), toNdcY(ty2), uv_x1, uv_y1, col));

    // Bottom-left
    const tx3 = dest.x + (x0 * cos_r - y1 * sin_r);
    const ty3 = dest.y + (x0 * sin_r + y1 * cos_r);
    batch.appendSpriteVertex(SpriteVertex.init(toNdcX(tx3), toNdcY(ty3), uv_x0, uv_y1, col));

    // 2 triangles (CCW)
    batch.appendSpriteIndex(base + 0);
    batch.appendSpriteIndex(base + 1);
    batch.appendSpriteIndex(base + 2);
    batch.appendSpriteIndex(base + 0);
    batch.appendSpriteIndex(base + 2);
    batch.appendSpriteIndex(base + 3);

    batch.noteSpriteDraw(seg_index_start, 6, seg_quad_start);
}
