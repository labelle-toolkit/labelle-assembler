//! Cross-pack call through the EXPOSED surface only. Anything else —
//! citizens' files, its non-exposed verbs, the `game` shim, the
//! foreign registry name — is a compile error (docs/packs.md; the CI
//! step probes each).
const citizens = @import("citizens");

pub fn tick(game: anytype, dt: f32) void {
    _ = dt;
    _ = citizens.queries.find_idle(game);
}
