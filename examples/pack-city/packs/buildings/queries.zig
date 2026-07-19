//! The buildings pack's verb surface. Only `count` is exposed
//! (pack.labelle `.exposes`); dependents like the traffic pack call it as
//! `@import("buildings").queries.count(game)` — never this file's path.
const Building = @import("components/building.zig").Building;

/// Number of standing buildings.
pub fn count(game: anytype) u32 {
    var n: u32 = 0;
    var view = game.ecs_backend.view(.{Building}, .{});
    defer view.deinit();
    while (view.next()) |_| n += 1;
    return n;
}
