//! `Parallax` — opts an entity into the per-frame scroll driver
//! (`scripts/playing/10_parallax_scroll.zig`). `speed` is the leftward
//! scroll rate in world units per second; a larger value reads as
//! "closer to the camera", which is what sells the parallax depth cue
//! (near ground scrolls faster than the far ridge line).
//!
//! Auto-discovered from `components/` by the assembler's component
//! scan — no explicit registration in `project.labelle` needed (same
//! convention as examples/asset-streaming-smoke's `JumpAnim`).
//!
//! Carries a real `f32` field, so unlike a bare marker it needs no
//! padding byte to satisfy zig-ecs's non-zero-size `tryGet` guard.
pub const Parallax = struct {
    /// Leftward scroll speed, world units per second.
    speed: f32 = 0,
};
