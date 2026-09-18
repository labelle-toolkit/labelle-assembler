//! One condensation drop: it falls under gravity from the machine's coils,
//! contacts the reservoir's CURRENT water surface, emits exactly ONE ripple,
//! and waits before the next release.
//!
//! All the geometry here is in NATIVE ART PIXELS on the 103x55 canvas (the
//! script multiplies by the x6 enlargement when it writes the position), so
//! the numbers match the measurements on the assets branch directly.
pub const Drop = struct {
    pub const save = @import("labelle-core").Saveable(.transient, @This(), .{});
    /// The reservoir (`Reservoir.unit`) this drop falls into.
    unit: u32 = 0,
    /// Impact X in RESERVOIR-LOCAL native px — what `addWaterRipple` takes.
    /// The five measured emitters are local x 21, 28, 43, 51, 65.
    local_x: f32 = 0,
    /// Native canvas Y the drop is released from (the reference releases at
    /// native y 2..5).
    release_y: f32 = 2,
    /// Downward acceleration in native px/s^2. The reference's fall is
    /// accelerating, not grid-stepped.
    gravity: f32 = 230,
    /// Seconds between one impact and the next release.
    interval: f32 = 1.6,
    /// Start-of-run offset so the five emitters do not drip in unison.
    phase: f32 = 0,

    // ── Runtime ──────────────────────────────────────────────────────
    /// Seconds since this drop was released (negative while waiting).
    t: f32 = 0,
    /// Set the instant the drop crosses the surface, so exactly one ripple
    /// is emitted per fall no matter how many frames the crossing spans.
    rippled: bool = false,
    /// Whether `t` has been seeded from `phase` yet.
    started: bool = false,
};
