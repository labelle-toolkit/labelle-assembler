//! `Coin` — tags a collectible. `radius` sets the pickup half-extent used
//! for the AABB-ish overlap test in the collect script. Auto-discovered
//! from `components/`; queried with `view(.{Coin})`. Its `f32` field
//! doubles as the non-zero-size marker zig-ecs's `tryGet` requires.
pub const Coin = struct {
    /// Pickup radius (world units). Overlap within `player_radius + radius`
    /// collects the coin.
    radius: f32 = 8,
};
