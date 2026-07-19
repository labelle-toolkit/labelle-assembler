//! Background cloud — drifts left and wraps.
pub const Cloud = struct {
    pub const save = @import("labelle-core").Saveable(.transient, @This(), .{});
    /// Drift speed in world px/s (leftward).
    drift: f32 = 12.0,
};
