/// Marker component attached to every sprite in scenes/main.jsonc.
/// Zig-ecs's `entt`-style storage rejects zero-sized components at
/// `tryGet` (see component_storage.zig's @compileError), so we carry
/// a single padding byte to make the type addressable — matches the
/// pattern used by examples/raylib/components/player.zig.
pub const SpriteMarker = struct {
    _: u8 = 0,
};
