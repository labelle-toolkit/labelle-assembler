//! `Player` — tags the single homing entity and carries its movement
//! `speed` (world units per second). Auto-discovered from `components/`
//! by the assembler's component scan; the collect script queries it with
//! `view(.{Player})`. A real `f32` field means no padding byte is needed
//! to clear zig-ecs's non-zero-size `tryGet` guard.
pub const Player = struct {
    /// Homing speed toward the nearest coin, world units per second.
    speed: f32 = 300,
};
