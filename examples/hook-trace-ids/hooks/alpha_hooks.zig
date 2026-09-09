//! Tuple slot 0. Declares no `labelle_receiver_id`, so without the
//! generated table its trace id would be DERIVED from `@typeName` — the
//! derivation the table exists to replace.
pub const AlphaHooks = struct {
    hits: u32 = 0,

    pub fn ping(self: *AlphaHooks, payload: anytype) void {
        _ = payload;
        self.hits += 1;
    }
};
