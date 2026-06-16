/// Pure-data value types, color constants, and vertex formats for the
/// WebGPU gfx backend. State-free and side-effect-free, so every other
/// gfx submodule can import it without creating cycles.

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

pub fn color(r: u8, g: u8, b: u8, a: u8) Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}

// ── Vertex types ──────────────────────────────────────────────────────

/// Color vertex for shape rendering (position + packed ABGR color).
/// Pub: it is the element type of `consumeShapeBatch`'s return slices,
/// which the window module's render submitter consumes.
pub const ColorVertex = extern struct {
    position: [2]f32,
    color_packed: u32, // ABGR packed

    pub fn init(x: f32, y: f32, col: u32) ColorVertex {
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

    pub fn init(x: f32, y: f32, u: f32, v: f32, col: u32) SpriteVertex {
        return .{ .position = .{ x, y }, .uv = .{ u, v }, .color_packed = col };
    }
};
