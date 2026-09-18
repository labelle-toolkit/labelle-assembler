const std = @import("std");
const m = @import("materials");
const core = @import("labelle-core");
test "compiled descriptors use shared core and caller owned binding storage" {
    var textures = m.fog.textures;
    textures[0].texture = @enumFromInt(1);
    const d = m.fog.descriptor(&textures);
    try core.shader_material.validateDescriptor(d);
    try std.testing.expect(d.textures.ptr == &textures);
    try std.testing.expect(d.shaders.spv.len > 0 and d.shaders.glsl.len > 0 and d.shaders.essl.len > 0 and d.shaders.mtl.len > 0);
    try std.testing.expectEqual(@as(usize, 0), d.shaders.dx11.len);
    try std.testing.expect(m.water.shaders.spv.len > 0 and m.lamp.shaders.spv.len > 0);
}
