//! Game-owned contained water. Simulation time and impacts never live in gfx.
const std = @import("std");
pub const WaterShader = struct {
    pub const save = @import("labelle-core").Saveable(.transient, @This(), .{});
    enabled: bool = true,
    mask: []const u8 = "reservoir_mask",
    reflection: []const u8 = "reservoir_reflection",
    logical_size: [2]f32 = .{ 93, 6 },
    grid_pixels: f32 = 1,
    water_level: f32 = 0.8333,
    reflection_opacity: f32 = 0.35,
    ripple_duration_seconds: f32 = 0.9,
    ripple_radius_pixels: f32 = 14,
    ripple_strength_pixels: f32 = 1,
    // Linear RGBA: the original shader palette, converted exactly once.
    deep_color: [4]f32 = color(0x0F1719),
    surface_color: [4]f32 = color(0x7AA5BB),
    highlight_color: [4]f32 = color(0x425F6C),
    time: f32 = 0,
    ripple_count: usize = 0,
    ripples: [8][4]f32 = .{.{ 0, 0, 0, 0 }} ** 8,

    pub fn validate(self: WaterShader) !void {
        if (self.ripple_count > self.ripples.len) return error.InvalidRippleCount;
        if (!std.math.isFinite(self.time)) return error.NonFiniteValue;
        for (self.ripples) |r| {
            for (r) |v| if (!std.math.isFinite(v)) return error.NonFiniteValue;
            if (r[2] < 0 or r[2] > 1) return error.InvalidStrength;
        }
        inline for (.{ self.logical_size[0], self.logical_size[1], self.grid_pixels, self.ripple_duration_seconds, self.ripple_radius_pixels }) |v| {
            if (!std.math.isFinite(v) or v <= 0) return error.InvalidPositiveSetting;
        }
        inline for (.{ self.water_level, self.reflection_opacity }) |v| {
            if (!std.math.isFinite(v) or v < 0 or v > 1) return error.InvalidUnitSetting;
        }
        if (!std.math.isFinite(self.ripple_strength_pixels) or self.ripple_strength_pixels < 0) return error.InvalidStrength;
        inline for (.{ self.deep_color, self.surface_color, self.highlight_color }) |rgba| {
            for (rgba) |v| if (!std.math.isFinite(v) or v < 0 or v > 1) return error.InvalidColor;
        }
    }

    /// Optional-field patch: missing inherits, explicit zero/false replaces.
    /// Validate a candidate before committing so a bad edit is atomic.
    pub fn patch(self: *WaterShader, changes: anytype) !void {
        var candidate = self.*;
        inline for (std.meta.fields(@TypeOf(changes))) |field| {
            const value = @field(changes, field.name);
            if (@typeInfo(@TypeOf(value)) == .optional) {
                if (value) |v| @field(candidate, field.name) = v;
            } else @field(candidate, field.name) = value;
        }
        try candidate.validate();
        candidate.expire();
        self.* = candidate;
    }

    pub fn setLevel(self: *WaterShader, level: f32) !void {
        if (!std.math.isFinite(level)) return error.NonFiniteValue;
        try self.patch(.{ .water_level = std.math.clamp(level, 0, 1) });
    }

    /// Expiry is permanent, including duration edits and shrinking bounds.
    fn expire(self: *WaterShader) void {
        var live: usize = 0;
        for (self.ripples[0..self.ripple_count]) |r| {
            const age = self.time - r[1];
            if (self.enabled and self.water_level > 0 and age >= 0 and age < self.ripple_duration_seconds and r[0] >= 0 and r[0] < self.logical_size[0]) {
                self.ripples[live] = r;
                live += 1;
            }
        }
        @memset(self.ripples[live..], .{ 0, 0, 0, 0 });
        self.ripple_count = live;
    }

    pub fn advance(self: *WaterShader, dt: f32) !void {
        try self.validate();
        const next = self.time + dt;
        if (!std.math.isFinite(dt) or !std.math.isFinite(next)) return error.NonFiniteValue;
        if (dt < 0) return error.NegativeDelta;
        self.time = next;
        self.expire();
        // No continuous wave phase exists. Rebase all live timestamps equally.
        if (self.time >= 4096) {
            for (self.ripples[0..self.ripple_count]) |*r| r[1] -= self.time;
            self.time = 0;
        }
    }

    pub fn impact(self: *WaterShader, x: f32, strength: f32) !void {
        try self.validate();
        if (!std.math.isFinite(x) or !std.math.isFinite(strength)) return error.NonFiniteValue;
        if (!self.enabled or self.water_level <= 0) return error.EmptyReservoir;
        if (x < 0 or x >= self.logical_size[0]) return error.RippleOutOfBounds;
        self.expire();
        var slot = self.ripple_count;
        if (slot == self.ripples.len) {
            slot = 0;
            for (self.ripples[1..], 1..) |r, i| {
                if (r[1] < self.ripples[slot][1]) slot = i;
            }
        } else self.ripple_count += 1;
        self.ripples[slot] = .{ x, self.time, std.math.clamp(strength, 0, 1), 0 };
    }
};

fn color(comptime rgb: u24) [4]f32 {
    var out: [4]f32 = .{ 0, 0, 0, 1 };
    inline for (0..3) |i| {
        const byte: u8 = @truncate(rgb >> (8 * (2 - i)));
        const v = @as(f32, @floatFromInt(byte)) / 255;
        out[i] = if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
    }
    return out;
}
