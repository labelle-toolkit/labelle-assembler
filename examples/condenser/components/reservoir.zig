//! Marker identifying one condenser unit's reservoir, so the drop script can
//! pair a falling drop with the `PixelWater` entity it should ripple.
//!
//! Deliberately NOT a copy of any water state: the authoritative fill level
//! lives on the built-in `PixelWater` component and is read back through
//! `game.pixelWater(entity)`, which is what makes the drops land on the
//! CURRENT surface rather than on a number the script happens to remember.
pub const Reservoir = struct {
    pub const save = @import("labelle-core").Saveable(.transient, @This(), .{});
    /// Which condenser unit this basin belongs to (0 = left, 1 = right).
    unit: u32 = 0,
};
