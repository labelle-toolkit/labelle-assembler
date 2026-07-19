//! The buildings pack's verb surface. Only `count` is exposed
//! (pack.labelle `.exposes`); dependents like the traffic pack call it as
//! `@import("buildings").queries.count(game)` — never this file's path.
const Building = @import("components/building.zig").Building;

/// Number of standing buildings. Reaches the world through
/// `game.active_world.ecs_backend` — the same access path every tick
/// script in this game uses — so the query keeps working the moment the
/// active world matters (scene swap / multi-world), not just today.
pub fn count(game: anytype) u32 {
    var n: u32 = 0;
    var view = game.active_world.ecs_backend.view(.{Building}, .{});
    defer view.deinit();
    while (view.next()) |_| n += 1;
    return n;
}
