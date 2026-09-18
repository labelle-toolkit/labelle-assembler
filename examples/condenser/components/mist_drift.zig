//! Horizontal drift for the mist plume. It is driven by its OWN sine —
//! different period, different phase, no shared clock with the water — so
//! the mist visibly moves independently of the reservoir's surface.
pub const MistDrift = struct {
    pub const save = @import("labelle-core").Saveable(.transient, @This(), .{});
    /// Scene X the drift oscillates around.
    base_x: f32 = 0,
    /// Peak horizontal excursion in SCENE px.
    amplitude: f32 = 18,
    /// Seconds per full drift cycle.
    period: f32 = 11,
    /// Phase offset in radians.
    phase: f32 = 0,
};
