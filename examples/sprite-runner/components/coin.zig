//! A spinning coin the runner can pick up. The 4-frame spin is a
//! `SpriteAnimation` attached by the run script; this component is the
//! gameplay half (pickup radius + marker for the query).
pub const Coin = struct {
    pub const save = @import("labelle-core").Saveable(.transient, @This(), .{});
    /// Pickup half-extent in world px.
    radius: f32 = 14.0,
};
