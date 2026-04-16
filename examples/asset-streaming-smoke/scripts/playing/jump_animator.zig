// Jump animator — cycles through jump_0001..jump_0009 frames on
// every entity tagged with the `JumpAnim` marker component. Proves
// the asset-streaming pipeline keeps re-resolving sprite_name →
// source_rect after the initial load (the engine's
// `resolveAtlasSprites` runs every frame and treats sprite_name
// changes as cache misses).
//
// Doesn't use the engine's `AnimationDef` machinery — that expects a
// `folder/variant_NNNN.png` naming convention which the smoke's
// jump.png atlas doesn't follow (frames are just `jump_NNNN.png`).
// A bespoke 30-line cycler is simpler than retrofitting the atlas to
// the convention.

const std = @import("std");

const JumpAnim = @import("../../components/jump_anim.zig").JumpAnim;

pub const game_states = .{"playing"};

const FRAME_COUNT: u8 = 9;
// Roughly 100ms / frame → ~10fps cycle, slow enough to be visually
// obvious in the auto-screenshot timing window.
const SECONDS_PER_FRAME: f32 = 0.1;

pub fn State(comptime EcsBackend: type) type {
    _ = EcsBackend;
    return struct {
        timer: f32 = 0,
        frame: u8 = 0,
        // sprite_name buffer lives on the script's State so the
        // slice handed to the Sprite component stays valid past the
        // end of `tick` — the engine's renderer reads sprite_name
        // every frame and would dangle on a stack-local buffer.
        // Each frame name is "jump_NNNN.png" → 13 chars; 16 is fine.
        name_buf: [16]u8 = undefined,
    };
}

pub fn tick(game: anytype, state: anytype, _: anytype, dt: f32) void {
    const Sprite = @TypeOf(game.*).SpriteComp;

    state.timer += dt;
    if (state.timer < SECONDS_PER_FRAME) return;
    state.timer = 0;
    state.frame = (state.frame + 1) % FRAME_COUNT;

    const name = std.fmt.bufPrint(&state.name_buf, "jump_{d:0>4}.png", .{state.frame + 1}) catch return;

    var v = game.active_world.ecs_backend.view(.{ Sprite, JumpAnim }, .{});
    defer v.deinit();
    while (v.next()) |entity| {
        const sprite = game.active_world.ecs_backend.getComponent(entity, Sprite) orelse continue;
        // The engine's resolveAtlasSprites checks sprite_name on
        // every tick and re-derives source_rect on cache miss; just
        // overwriting the field is enough — no markVisualDirty call
        // needed from script-land.
        sprite.sprite_name = name;
    }
}
