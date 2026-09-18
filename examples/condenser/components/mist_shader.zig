const std = @import("std");

/// A transparent, game-owned layer anchored to the matching reservoir.
pub const MistShader = struct {
    pub const save = @import("labelle-core").Saveable(.transient, @This(), .{});
    unit: u32 = 0,
    enabled: bool = true,
    height: f32 = 54,
    density: f32 = 1.4,
    opacity: f32 = 0.42,
    wisp_size: f32 = 96,
    turbulence: f32 = 0.45,
    drift_velocity: [2]f32 = .{ 12, -3 },
    grid_pixels: f32 = 6,
    light_coupling: f32 = 0.35,
    color: [3]f32 = .{ 0.48, 0.67, 0.74 },
    phase: [2]f32 = .{ 0, 0 },

    pub fn validate(self: MistShader) !void {
        inline for (.{ self.height, self.density, self.light_coupling }) |v| {
            if (!std.math.isFinite(v) or v < 0) return error.InvalidMistSetting;
        }
        inline for (.{ self.opacity, self.turbulence }) |v| {
            if (!std.math.isFinite(v) or v < 0 or v > 1) return error.InvalidMistSetting;
        }
        if (!std.math.isFinite(self.wisp_size) or self.wisp_size <= 0) return error.InvalidMistSetting;
        if (!std.math.isFinite(self.grid_pixels) or self.grid_pixels < 1) return error.InvalidGrid;
        for (self.drift_velocity) |v| if (!std.math.isFinite(v)) return error.InvalidMistSetting;
        for (self.color) |v| if (!std.math.isFinite(v) or v < 0 or v > 1) return error.InvalidMistSetting;
        for (self.phase) |v| if (!std.math.isFinite(v) or v < 0 or v >= 1) return error.InvalidPhase;
    }

    pub fn advance(self: *MistShader, dt: f32) !void {
        try self.validate();
        if (!std.math.isFinite(dt) or dt < 0) return error.InvalidDelta;
        for (&self.phase, self.drift_velocity) |*phase, velocity| {
            phase.* = @floatCast(@mod(@as(f64, phase.*) + @as(f64, dt) * velocity / self.wisp_size, 1));
            if (phase.* >= 1) phase.* = 0;
        }
    }

    pub fn surfaceY(top: f32, height: f32, level: f32) f32 {
        return top + height * (1 - std.math.clamp(level, 0, 1));
    }
};
