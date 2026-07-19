//! A glowing orb that bobs on a sine path so its bright core drifts through
//! the bloom threshold. Pure marker + per-orb phase so the motion is
//! deterministic and each orb bobs out of step with its neighbors.
pub const Orb = struct {
    pub const save = @import("labelle-core").Saveable(.transient, @This(), .{});
    /// Vertical bob amplitude in world px.
    amplitude: f32 = 14.0,
    /// Phase offset (radians) so orbs don't bob in unison.
    phase: f32 = 0.0,
    /// Baseline Y the bob oscillates around (captured on first tick).
    base_y: f32 = 0.0,
    /// Whether `base_y` has been captured yet.
    anchored: bool = false,
};
