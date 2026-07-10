//! `tiles` pack generator script — the "small generator script" from the
//! RFC's fantasy-dungeon use case (labelle-engine#725, §use-case-2).
//!
//! The RFC's key insight is that a map generator needs NO new engine
//! machinery: "tiles are entities, tilesets are just atlases" — a generator
//! is an ORDINARY pack script. It's dir-scanned from `packs/tiles/scripts/`
//! and namespaced into the plugin's own script block, running each `playing`
//! tick after the game's scripts.
//!
//! This reference keeps the body deliberately tiny (headless `.null` backend,
//! no GPU): it logs the procedural room layout it would stamp out of the
//! `tiles__tileset` frames, proving the generator wiring end-to-end without
//! dragging in the full spawn API. A real vendor generator would call the
//! engine's prefab-instantiation API here to place `tiles__floor_tile` /
//! `tiles__wall_tile` entities on a grid.

pub const game_states = .{"playing"};

/// A 4-wide room silhouette: `#` wall, `.` floor. The generator "renders" one
/// row per tick so the log shows the layout being stamped deterministically.
const ROOM = [_][]const u8{
    "####",
    "#..#",
    "#..#",
    "####",
};

pub fn State(comptime EcsBackend: type) type {
    _ = EcsBackend;
    return struct {
        row: usize = 0,
    };
}

pub fn tick(game: anytype, state: anytype, _: anytype, _: f32) void {
    if (state.row >= ROOM.len) return;
    game.log.info("[fantasy-dungeon:tiles] generate row {d}: {s}", .{ state.row, ROOM[state.row] });
    state.row += 1;
}
