//! Tuple slot 1. A second receiver for the same event, so the trace has
//! more than one delivery to align — with a single receiver "aligned"
//! would be true whatever the emitter did.
pub const BetaHooks = struct {
    hits: u32 = 0,

    pub fn ping(self: *BetaHooks, payload: anytype) void {
        _ = payload;
        self.hits += 1;
    }
};
