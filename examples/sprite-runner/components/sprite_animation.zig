// Re-export of the engine's `SpriteAnimation` component so the
// assembler's `components/*.zig` auto-discovery pulls it into the game's
// `ComponentRegistry` — required for scripts to attach it to entities
// (the engine ticks it once `setDriveSpriteAnimations(true)` is set).
pub const SpriteAnimation = @import("labelle-engine").SpriteAnimation;
