const std = @import("std");
pub const LampShader = struct {
    pub const save = @import("labelle-core").Saveable(.transient, @This(), .{});
    unit: u32 = 0,
    enabled: bool = true,
    center: [2]f32 = .{ 309, 12 },
    width: f32 = 348,
    reach_up: f32 = 12,
    reach_down: f32 = 132,
    intensity: f32 = 1,
    spread: f32 = 0,
    softness: f32 = 6,
    falloff: f32 = 2,
    glow: f32 = 1,
    flicker: f32 = 0,
    flicker_speed: f32 = 8,
    phase: f32 = 0,
    color: [3]f32 = .{ 0.64, 0.85, 0.94 },
    grid_pixels: f32 = 6,

    pub fn validate(self: LampShader) !void {
        if (!std.math.isFinite(self.phase) or self.phase < 0 or self.phase >= 1) return error.InvalidPhase;
        inline for (.{ self.width, self.reach_up, self.reach_down, self.intensity, self.spread, self.softness, self.falloff, self.glow, self.flicker_speed }) |v| {
            if (!std.math.isFinite(v) or v < 0) return error.InvalidLampSetting;
        }
        for (self.center) |v| if (!std.math.isFinite(v)) return error.InvalidLampSetting;
        for (self.color) |v| if (!std.math.isFinite(v) or v < 0 or v > 1) return error.InvalidLampSetting;
        if (!std.math.isFinite(self.flicker) or self.flicker < 0 or self.flicker > 1) return error.InvalidLampSetting;
        if (!std.math.isFinite(self.grid_pixels) or self.grid_pixels < 1) return error.InvalidGrid;
    }

    /// CPU counterpart of the shader footprint, useful to gameplay and tests.
    pub fn influence(self: LampShader, pixel: [2]f32) f32 {
        if (!self.enabled or self.width <= 0 or self.intensity <= 0) return 0;
        const x = (@floor(pixel[0] / self.grid_pixels) + 0.5) * self.grid_pixels;
        const y = (@floor(pixel[1] / self.grid_pixels) + 0.5) * self.grid_pixels;
        const dy = y - self.center[1];
        const reach = if (dy < 0) self.reach_up else self.reach_down;
        if (reach <= 0) return 0;
        if (@abs(dy) >= reach) return 0;
        const half_width = self.width * 0.5 + self.spread * @abs(dy) / reach;
        const edge = half_width - @abs(x - self.center[0]);
        const horizontal: f32 = if (self.softness == 0) (if (edge >= 0) 1 else 0) else std.math.clamp(edge / self.softness, 0, 1);
        const vertical = std.math.clamp(1 - @abs(dy) / reach, 0, 1);
        return horizontal * std.math.pow(f32, vertical, self.falloff) * self.intensity * self.glow * self.flickerFactor();
    }

    pub fn flickerFactor(self: LampShader) f32 {
        return 1 - self.flicker * (0.5 + 0.5 * @sin(self.phase * 2 * std.math.pi));
    }

    pub fn advance(self: *LampShader, dt: f32) !void {
        try self.validate();
        if (!std.math.isFinite(dt) or dt < 0) return error.InvalidDelta;
        self.phase = @floatCast(@mod(@as(f64, self.phase) + @as(f64, dt) * self.flicker_speed, 1));
        if (self.phase >= 1) self.phase = 0;
    }
};
