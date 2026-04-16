/// Marker component that opts an entity into the per-frame jump
/// animator (scripts/playing/jump_animator.zig). Carries a u8 padding
/// byte for the same reason as `SpriteMarker` — zig-ecs's `tryGet`
/// rejects `@sizeOf == 0` types, and the smoke example deliberately
/// doesn't pull in the assembler #58 fix yet to keep the test focused
/// on the streaming pipeline.
pub const JumpAnim = struct {
    _: u8 = 0,
};
