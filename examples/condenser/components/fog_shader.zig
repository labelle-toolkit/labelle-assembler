const std = @import("std");
pub const FogShader = struct {
    pub const save = @import("labelle-core").Saveable(.transient, @This(), .{});
    unit: u32 = 0,
    enabled: bool = true,
    density: f32 = 1,
    opacity: f32 = 1,
    speed: f32 = 0.12,
    variation: f32 = 0.18,
    wisp_size: f32 = 48,
    turbulence: f32 = 0.25,
    /// Signed screen px/s, multiplied by speed. Zero stops translation.
    drift_velocity: [2]f32 = .{ 6, 0 },
    light_coupling: f32 = 0.35,
    grid_pixels: f32 = 6,
    color: [3]f32 = .{ 0.48, 0.65, 0.73 },
    phase: f32 = 0,
    drift_phase: [2]f32 = .{ 0, 0 },

    pub fn validate(self: FogShader) !void {
        if (!std.math.isFinite(self.phase) or self.phase < 0 or self.phase >= 1) return error.InvalidPhase;
        for (self.drift_phase) |v| if (!std.math.isFinite(v) or v < 0 or v >= 1) return error.InvalidPhase;
        inline for (.{ self.density, self.speed, self.light_coupling, self.wisp_size }) |v| {
            if (!std.math.isFinite(v) or v < 0) return error.InvalidFogSetting;
        }
        if (!std.math.isFinite(self.variation) or self.variation < 0 or self.variation > 1) return error.InvalidFogSetting;
        inline for (.{ self.opacity, self.turbulence }) |v| {
            if (!std.math.isFinite(v) or v < 0 or v > 1) return error.InvalidFogSetting;
        }
        for (self.drift_velocity) |v| if (!std.math.isFinite(v)) return error.InvalidFogSetting;
        if (!std.math.isFinite(self.grid_pixels) or self.grid_pixels < 1) return error.InvalidGrid;
        for (self.color) |v| if (!std.math.isFinite(v) or v < 0 or v > 1) return error.InvalidFogSetting;
    }

    pub fn advance(self: *FogShader, dt: f32) !void {
        try self.validate();
        if (!std.math.isFinite(dt) or dt < 0) return error.InvalidDelta;
        // A bounded phase prevents long-session precision loss; shader motion
        // is periodic in this phase, so the wrap is continuous.
        const next = @as(f64, self.phase) + @as(f64, dt) * self.speed;
        self.phase = @floatCast(@mod(next, 1));
        if (self.phase >= 1) self.phase = 0;
        if (self.wisp_size > 0) {
            for (&self.drift_phase, self.drift_velocity) |*phase, velocity| {
                phase.* = @floatCast(@mod(@as(f64, phase.*) + @as(f64, dt) * self.speed * velocity / self.wisp_size, 1));
                if (phase.* >= 1) phase.* = 0;
            }
        }
    }
};
