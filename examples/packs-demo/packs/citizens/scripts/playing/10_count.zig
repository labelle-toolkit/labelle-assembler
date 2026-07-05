//! Pack-internal script: the sanctioned surfaces in one file — the
//! engine substrate, a within-module relative import, and the
//! @import("pack").Registry bridge (own names resolve; foreign names
//! are comptime errors — see the CI negative probe).
const engine = @import("labelle-engine");
const Counter = @import("../../components/counter.zig").Counter;
const Registry = @import("pack").Registry;

comptime {
    // The bridge resolves the pack's own namespaced name to the exact
    // type the relative import reaches.
    if (Registry.getType("citizens__Counter") != Counter) @compileError("bridge type mismatch");
}

pub fn tick(game: anytype, dt: f32) void {
    _ = dt;
    var view = game.ecs_backend.view(.{Counter}, .{});
    defer view.deinit();
    while (view.next()) |e| {
        if (game.ecs_backend.getComponent(e, Counter)) |c| c.n += 1;
    }
}
