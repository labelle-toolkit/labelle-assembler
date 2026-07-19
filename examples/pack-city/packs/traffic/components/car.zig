//! A car driving along the street. `speed` is world px/s; the pack's
//! drive script wraps it off the right edge back to the left.
pub const Car = struct {
    pub const save = @import("labelle-core").Saveable(.transient, @This(), .{});
    speed: f32 = 70.0,
};
