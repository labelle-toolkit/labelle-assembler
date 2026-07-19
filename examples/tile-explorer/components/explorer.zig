//! Marker + tuning for the entity that walks the island's path loop.
pub const Explorer = struct {
    pub const save = @import("labelle-core").Saveable(.transient, @This(), .{});
    /// Walk speed in world px/s.
    speed: f32 = 60.0,
    /// Index of the path-loop waypoint currently walked toward (see
    /// scripts/playing/10_explore.zig).
    waypoint: u8 = 1,
};
