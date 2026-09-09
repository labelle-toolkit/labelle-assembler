//! Drives the dispatch and prints what the TRACER recorded (#727/#858).
//!
//! Frame 1 emits `ping`. The generated loop drains at the TOP of the next
//! iteration (see the engine's `HOOK-DELIVERY-CONTRACT.md` §2), so the
//! records do not exist yet when frame 1 ends — frame 2 is the first
//! frame that can read them. Printing on frame 1 would produce nothing
//! and the CI comparison would pass vacuously against an empty list, so
//! the probe waits and then asserts it found something.
//!
//! What is printed is deliberately the RUNTIME value:
//! `record.receiver` is whatever the engine's `ReceiverIdAt` resolved,
//! which — in a build carrying the generated table — is
//! `hook_receiver_ids[slot]`. The CI step diffs those lines against the
//! ids in the generated `hook_routes.json`, so the assertion spans the
//! whole chain rather than any single half of it.

pub const game_states = .{"playing"};

pub fn State(comptime EcsBackend: type) type {
    _ = EcsBackend;
    return struct {
        frame: u32 = 0,
        printed: bool = false,
    };
}

pub fn tick(game: anytype, state: anytype, _: anytype, _: f32) void {
    state.frame += 1;

    if (state.frame == 1) {
        game.emit(.{ .ping = .{ .n = 1 } });
        return;
    }
    if (state.printed) return;
    state.printed = true;

    const t = &game.hook_tracer;
    var delivers: u32 = 0;
    for (0..t.count()) |i| {
        const r = t.at(i);
        if (r.phase != .deliver) continue;
        delivers += 1;
        // One line per delivery, in dispatch order. `kind` proves WHERE
        // the id came from: `table` is the contract, `derived` would mean
        // the generated table never reached the engine.
        game.log.info(
            "[trace] slot={d} receiver={s} kind={s}",
            .{ r.index, r.receiver, @tagName(r.receiver_id_kind) },
        );
    }
    // A vacuous run is a FAILED run: if nothing was delivered there is
    // nothing for CI to compare, and a silent empty list would look like
    // agreement.
    game.log.info("[trace] deliver_count={d}", .{delivers});
}
