//! The event the integration dispatches. Both receivers below handle it,
//! so one emit produces one deliver record per receiver — which is what
//! makes the id-per-tuple-slot comparison meaningful.
pub const Ping = struct {
    n: u32 = 0,
};
