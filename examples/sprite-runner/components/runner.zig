//! The jogging robot — marker + tuning.
pub const Runner = struct {
    pub const save = @import("labelle-core").Saveable(.transient, @This(), .{});
    /// Run speed in world px/s.
    speed: f32 = 90.0,
};
