//! Project-local Position component. The flow codegen emits
//! `@import("components/Position.zig").Position`, so this file shadows
//! the engine-builtin `engine.Position` for the purposes of the smoke
//! fixture. Field shape matches `labelle-core.Position` so scene loaders
//! and the engine's position-aware helpers (e.g. renderer dirty
//! tracking) still recognise it.
pub const Position = struct {
    x: f32 = 0,
    y: f32 = 0,
};
