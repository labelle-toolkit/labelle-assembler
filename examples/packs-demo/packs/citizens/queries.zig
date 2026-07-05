//! Citizens' verb surface (RFC §6). Only `find_idle` is exposed;
//! `internal_reset` exists to prove non-exposed verbs are invisible
//! to dependents (the CI negative probe).
const Counter = @import("components/counter.zig").Counter;

/// First entity carrying a Counter, or null.
pub fn find_idle(game: anytype) ?u64 {
    var view = game.ecs_backend.view(.{Counter}, .{});
    defer view.deinit();
    while (view.next()) |e| return @intCast(e);
    return null;
}

/// NOT exposed — dependents must not see it.
pub fn internal_reset(game: anytype) void {
    _ = game;
}
