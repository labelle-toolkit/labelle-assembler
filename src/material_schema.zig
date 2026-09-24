//! Versioned, backend-neutral JSON authoring contract. Shared by generate and build.
const std = @import("std");
pub const Target = enum { spv, glsl, essl, mtl, dx11 };
pub const Kind = enum { scalar, vec2, vec3, vec4, mat4 };
pub const Parameter = struct { name: []const u8, kind: Kind, count: u16 = 1, defaults: []const f32 = &.{} };
pub const Texture = struct { name: []const u8, sampler: enum { point, linear } = .point };
pub const Descriptor = struct {
    version: u32,
    label: ?[]const u8 = null,
    fragment: []const u8,
    targets: []const Target,
    parameters: []const Parameter = &.{},
    textures: []const Texture = &.{},
    blend: enum { alpha, additive, modulate2x } = .alpha,
};
/// The shaderc that compiles game materials, and the GLSL profile it takes.
///
/// It MUST come from the same bgfx API the game links: the shader container
/// version and the GLSL dialect both changed at bgfx API 161 (labelle-bgfx
/// v0.24.0), and each runtime rejects the other's container. So the generator
/// picks one per project from its resolved bgfx pin
/// (`material_pipeline.toolchain`), never a single global pin.
pub const Toolchain = struct {
    url: []const u8,
    hash: []const u8,
    /// `-p` for `.glsl`. API 161's shaderc starts its GLSL profiles at 330
    /// (and the GL renderer loads `#version 430`); API 142 took 120.
    glsl_profile: []const u8,
    /// The bgfx API this shaderc belongs to, as `shaderc --version` reports it
    /// (`version 1.19.<api>.`). Used to reject a `-Dshaderc`/`LABELLE_SHADERC`
    /// override from the other API, which would otherwise get this profile
    /// and emit a container the linked runtime rejects.
    api: []const u8,
};
/// Does `shaderc --version` output belong to bgfx `api`? Matches the
/// `version <major>.<minor>.<api>` triple exactly, so 142 never matches 1142.
pub fn shadercReportsApi(version_output: []const u8, api: []const u8) bool {
    const key = "version ";
    const at = std.mem.indexOf(u8, version_output, key) orelse return false;
    var parts = std.mem.splitScalar(u8, version_output[at + key.len ..], '.');
    _ = parts.next() orelse return false; // major
    _ = parts.next() orelse return false; // minor
    const patch = parts.next() orelse return false;
    var end: usize = 0;
    while (end < patch.len and std.ascii.isDigit(patch[end])) end += 1;
    return end > 0 and std.mem.eql(u8, patch[0..end], api);
}
test "shadercReportsApi reads the API off shaderc --version" {
    try std.testing.expect(shadercReportsApi("shaderc, bgfx shader compiler tool, version 1.19.161.\n", "161"));
    try std.testing.expect(!shadercReportsApi("shaderc, bgfx shader compiler tool, version 1.19.161.\n", "142"));
    try std.testing.expect(shadercReportsApi("shaderc, bgfx shader compiler tool, version 1.18.142.", "142"));
    try std.testing.expect(!shadercReportsApi("version 1.19.1142.", "142"));
    try std.testing.expect(!shadercReportsApi("not a shaderc", "161"));
}
/// bgfx API 142: labelle-bgfx < 0.24.0. Container v11.
pub const toolchain_api142: Toolchain = .{
    .url = "https://github.com/labelle-toolkit/zbgfx/archive/934372f13b92e651c9e43613af6dff96d231e782.tar.gz",
    .hash = "zbgfx-0.12.0-Sm4IxBGjywYbjOha8_dczGXQq53qynqGka3vWDhKI3pD",
    .glsl_profile = "120",
    .api = "142",
};
/// bgfx API 161: labelle-bgfx >= 0.24.0. Container v12. Same zbgfx pin as
/// labelle-bgfx v0.24.0 (labelle-toolkit/zbgfx#1 merge).
pub const toolchain_api161: Toolchain = .{
    .url = "https://github.com/labelle-toolkit/zbgfx/archive/ba2786f11b8042afc2f90e10b2a6432bd24befae.tar.gz",
    .hash = "zbgfx-0.12.0-Sm4IxMnIDAdzAesVbziV41cUrt0j8cBIG8xGe7UL1fpY",
    .glsl_profile = "330",
    .api = "161",
};
pub const varying =
    \\vec4 v_color0 : COLOR0 = vec4(1.0, 1.0, 1.0, 1.0);
    \\vec2 v_texcoord0 : TEXCOORD0 = vec2(0.0, 0.0);
    \\vec2 a_position : POSITION;
    \\vec4 a_color0 : COLOR0;
    \\vec2 a_texcoord0 : TEXCOORD0;
    \\
;
pub fn identifier(name: []const u8) bool {
    if (name.len == 0 or name.len > 63) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}
pub fn materialName(name: []const u8) bool {
    if (!identifier(name)) return false;
    for ([_][]const u8{ "_", "core", "sm", "parameters", "textures", "shaders", "label", "blend", "descriptor", "bindings" }) |reserved| {
        if (std.mem.eql(u8, name, reserved)) return false;
    }
    return true;
}
pub fn relativePath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return false;
    // Portable project paths, including on Windows; reject drive/UNC paths.
    if (std.mem.indexOfAny(u8, path, "\\:\x00") != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |p| if (p.len == 0 or std.mem.eql(u8, p, ".") or std.mem.eql(u8, p, "..")) return false;
    return true;
}
pub fn parse(a: std.mem.Allocator, json: []const u8) !std.json.Parsed(Descriptor) {
    const parsed = try std.json.parseFromSlice(Descriptor, a, json, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    const d = parsed.value;
    if (d.version != 1) return error.UnsupportedMaterialVersion;
    if (!relativePath(d.fragment) or !std.mem.endsWith(u8, d.fragment, ".sc")) return error.InvalidFragmentPath;
    if (d.targets.len == 0) return error.MissingShaderTargets;
    for (d.targets, 0..) |t, i| for (d.targets[0..i]) |prev| {
        if (t == prev) return error.DuplicateShaderTarget;
    };
    if (d.parameters.len > 16 or d.textures.len > 4) return error.TooManyMaterialBindings;
    var registers: usize = 1; // automatic u_material_rect
    for (d.parameters, 0..) |p, i| {
        try bindingName(p.name);
        if (p.count == 0) return error.InvalidParameterCount;
        registers += @as(usize, p.count) * (if (p.kind == .mat4) @as(usize, 4) else 1);
        if (registers > 64) return error.TooManyMaterialRegisters;
        const channels: usize = switch (p.kind) {
            .scalar => 1,
            .vec2 => 2,
            .vec3 => 3,
            .vec4 => 4,
            .mat4 => 16,
        };
        if (p.defaults.len != 0 and p.defaults.len != channels * p.count) return error.InvalidParameterDefaults;
        for (p.defaults) |v| if (!std.math.isFinite(v)) return error.NonFiniteParameterDefault;
        for (d.parameters[0..i]) |prev| if (std.mem.eql(u8, prev.name, p.name)) return error.DuplicateMaterialBinding;
        for (d.textures) |t| if (std.mem.eql(u8, t.name, p.name)) return error.DuplicateMaterialBinding;
    }
    for (d.textures, 0..) |t, i| {
        try bindingName(t.name);
        for (d.textures[0..i]) |prev| if (std.mem.eql(u8, prev.name, t.name)) return error.DuplicateMaterialBinding;
    }
    return parsed;
}
fn bindingName(name: []const u8) !void {
    if (!identifier(name)) return error.InvalidMaterialBindingName;
    for ([_][]const u8{ "s_tex", "u_material_rect", "u_viewRect", "u_viewTexel", "u_view", "u_invView", "u_proj", "u_invProj", "u_viewProj", "u_invViewProj", "u_model", "u_modelView", "u_modelViewProj", "u_alphaRef4" }) |reserved| {
        if (std.mem.eql(u8, name, reserved)) return error.ReservedMaterialBinding;
    }
}
/// Includes are literal paths within the tracked materials/header trees.
pub fn validateIncludes(source: []const u8) !void {
    // C preprocessing splices escaped newlines before removing comments. Do
    // likewise so comments/continuations cannot hide an escaping include.
    const clean = try std.heap.page_allocator.alloc(u8, source.len);
    defer std.heap.page_allocator.free(clean);
    var n: usize = 0;
    var i: usize = 0;
    while (i < source.len) {
        if (source[i] == '\\' and i + 1 < source.len) {
            if (source[i + 1] == '\n') {
                i += 2;
                continue;
            }
            if (i + 2 < source.len and source[i + 1] == '\r' and source[i + 2] == '\n') {
                i += 3;
                continue;
            }
        }
        clean[n] = source[i];
        n += 1;
        i += 1;
    }
    i = 0;
    var quote_char: u8 = 0;
    while (i < n) : (i += 1) {
        if (quote_char != 0) {
            if (clean[i] == '\\' and i + 1 < n) {
                i += 1;
                continue;
            }
            if (clean[i] == quote_char) quote_char = 0;
            continue;
        }
        if (clean[i] == '"' or clean[i] == '\'') {
            quote_char = clean[i];
            continue;
        }
        if (clean[i] != '/' or i + 1 >= n) continue;
        if (clean[i + 1] == '/') {
            while (i < n and clean[i] != '\n') : (i += 1) clean[i] = ' ';
        } else if (clean[i + 1] == '*') {
            clean[i] = ' ';
            clean[i + 1] = ' ';
            i += 2;
            while (i < n) : (i += 1) {
                if (clean[i] == '*' and i + 1 < n and clean[i + 1] == '/') {
                    clean[i] = ' ';
                    clean[i + 1] = ' ';
                    i += 1;
                    break;
                }
                if (clean[i] != '\n') clean[i] = ' ';
            }
        }
    }
    var lines = std.mem.splitScalar(u8, clean[0..n], '\n');
    while (lines.next()) |line| {
        var rest = std.mem.trimStart(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, rest, "#")) continue;
        rest = std.mem.trimStart(u8, rest[1..], " \t");
        if (!std.mem.startsWith(u8, rest, "include")) continue;
        rest = std.mem.trimStart(u8, rest[7..], " \t");
        if (rest.len < 3 or (rest[0] != '"' and rest[0] != '<')) return error.NonLiteralShaderInclude;
        const close: u8 = if (rest[0] == '"') '"' else '>';
        const end = std.mem.indexOfScalar(u8, rest[1..], close) orelse return error.InvalidShaderInclude;
        if (!relativePath(rest[1 .. end + 1])) return error.EscapingShaderInclude;
    }
}
pub fn profile(target: Target, glsl_profile: []const u8) []const u8 {
    return switch (target) {
        .spv => "spirv",
        .glsl => glsl_profile,
        .essl => "300_es",
        .mtl => "metal",
        .dx11 => "s_5_0",
    };
}
/// shaderc's `--platform` for a shader language, given the project's target
/// platform (`config.Platform`'s tag name, or `"tests"`).
///
/// `--platform` selects which `BX_PLATFORM_*` macro shaderc defines, so it has
/// to follow the REAL target, not the language: Metal is macOS *and* iOS, and
/// ESSL is Android *and* WebGL2-on-Emscripten. Compiling both halves of such a
/// pair against one fixed platform silently takes the wrong branch of any
/// `#if BX_PLATFORM_*` in the shader (labelle-assembler#740).
///
/// Names are shaderc's own spelling, read off `shaderc --help` for the pinned
/// toolchain builds (API 142 and 161 list the same names) (android, asm.js, ios, linux, orbis, osx, windows) — note
/// Emscripten is spelled `asm.js`, not `emscripten` or `wasm`.
///
/// Only the two ambiguous pairs are platform-keyed; every other
/// language/platform combination keeps the pre-#740 mapping, so desktop and
/// Android output stay byte-identical.
pub fn platform(target: Target, project_platform: []const u8) []const u8 {
    if (target == .mtl and std.mem.eql(u8, project_platform, "ios")) return "ios";
    if (target == .essl and std.mem.eql(u8, project_platform, "wasm")) return "asm.js";
    return switch (target) {
        .spv, .glsl => "linux",
        .essl => "android",
        .mtl => "osx",
        .dx11 => "windows",
    };
}
// Zig string escaping is shared by descriptors and build-file generation.
pub fn quote(w: *std.Io.Writer, s: []const u8) !void {
    try w.print("\"{f}\"", .{std.zig.fmtString(s)});
}
pub fn render(w: *std.Io.Writer, name: []const u8, d: Descriptor) !void {
    try w.print("pub const @\"{s}\" = struct {{\n", .{name});
    try w.writeAll("const sm = @import(\"labelle-core\").shader_material;\npub const label = ");
    try quote(w, d.label orelse name);
    try w.print(";\npub const blend: sm.Blend = .{s};\n", .{@tagName(d.blend)});
    try w.writeAll("pub const parameters = [_]sm.Parameter{\n");
    for (d.parameters) |p| {
        try w.writeAll(".{ .name = ");
        try quote(w, p.name);
        try w.print(", .kind = .{s}, .count = {d}, .defaults = &.{{", .{ @tagName(p.kind), p.count });
        for (p.defaults) |v| try w.print("{e},", .{v});
        try w.writeAll("} },\n");
    }
    try w.writeAll("};\npub const textures = [_]sm.TextureBinding{\n");
    for (d.textures) |t| {
        try w.writeAll(".{ .name = ");
        try quote(w, t.name);
        try w.print(", .sampler = .{s} }},\n", .{@tagName(t.sampler)});
    }
    try w.writeAll("};\npub const shaders = sm.ShaderVariants{\n");
    for (d.targets) |t| try w.print(".{s} = @embedFile(\"{s}.{s}.bin\"),\n", .{ @tagName(t), name, @tagName(t) });
    try w.writeAll("};\n/// Bindings are borrowed until create returns; keep the caller's array alive.\npub fn descriptor(bindings: *const [textures.len]sm.TextureBinding) sm.Descriptor {\nreturn .{ .label = ");
    try quote(w, d.label orelse name);
    try w.print(", .blend = .{s}, .parameters = &parameters, .textures = bindings, .shaders = shaders }};\n}}\n}};\n", .{@tagName(d.blend)});
}

test "material schema rejects invalid paths versions reserved bindings and duplicate targets" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedMaterialVersion, parse(a, "{\"version\":2,\"fragment\":\"f.sc\",\"targets\":[\"spv\"]}"));
    try std.testing.expectError(error.InvalidFragmentPath, parse(a, "{\"version\":1,\"fragment\":\"../f.sc\",\"targets\":[\"spv\"]}"));
    try std.testing.expectError(error.DuplicateShaderTarget, parse(a, "{\"version\":1,\"fragment\":\"f.sc\",\"targets\":[\"spv\",\"spv\"]}"));
    try std.testing.expectError(error.ReservedMaterialBinding, parse(a, "{\"version\":1,\"fragment\":\"f.sc\",\"targets\":[\"spv\"],\"parameters\":[{\"name\":\"u_material_rect\",\"kind\":\"vec4\"}]}"));
    try std.testing.expect(!relativePath("C:/f.sc"));
    try std.testing.expect(!relativePath("a\\f.sc"));
    try std.testing.expect(!materialName("sm"));
    try std.testing.expect(!materialName("core"));
    try std.testing.expect(!materialName("textures"));
    try std.testing.expectError(error.ReservedMaterialBinding, bindingName("u_viewProj"));
    try std.testing.expectError(error.EscapingShaderInclude, validateIncludes("#include \"../shared/f.sc\""));
    try std.testing.expectError(error.NonLiteralShaderInclude, validateIncludes("#include HEADER"));
    try std.testing.expectError(error.EscapingShaderInclude, validateIncludes("/* prefix */ #/**/include \"../outside.sc\""));
    try std.testing.expectError(error.EscapingShaderInclude, validateIncludes("#inc\\\nlude \"../outside.sc\""));
    try validateIncludes("#include <bgfx_shader.sh>\n#include \"lib/color.sh\"");
}
test "material schema validates shapes and generates caller-owned textures and explicit variants" {
    const a = std.testing.allocator;
    const p = try parse(a, "{\"version\":1,\"fragment\":\"fog.sc\",\"targets\":[\"spv\",\"essl\"],\"parameters\":[{\"name\":\"u_density\",\"kind\":\"scalar\",\"defaults\":[0.5]}],\"textures\":[{\"name\":\"s_noise\",\"sampler\":\"linear\"}]}");
    defer p.deinit();
    var out = std.Io.Writer.Allocating.init(a);
    defer out.deinit();
    try render(&out.writer, "fog", p.value);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "*const [textures.len]sm.TextureBinding") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "fog.spv.bin") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "fog.essl.bin") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "fog.mtl.bin") == null);
    try std.testing.expectError(error.InvalidParameterDefaults, parse(a, "{\"version\":1,\"fragment\":\"f.sc\",\"targets\":[\"spv\"],\"parameters\":[{\"name\":\"u_x\",\"kind\":\"vec4\",\"defaults\":[1]}]}"));
}
test "material schema accepts the modulate2x blend and emits it" {
    const a = std.testing.allocator;
    const p = try parse(a, "{\"version\":1,\"fragment\":\"light.sc\",\"targets\":[\"essl\"],\"blend\":\"modulate2x\"}");
    defer p.deinit();
    var out = std.Io.Writer.Allocating.init(a);
    defer out.deinit();
    try render(&out.writer, "light", p.value);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), ".blend = .modulate2x") != null);
}
test "shaderc platform follows the real target for the ambiguous metal/essl pairs (#740)" {
    // The two pairs the fixed mapping got wrong.
    try std.testing.expectEqualStrings("osx", platform(.mtl, "desktop"));
    try std.testing.expectEqualStrings("ios", platform(.mtl, "ios"));
    try std.testing.expectEqualStrings("android", platform(.essl, "android"));
    try std.testing.expectEqualStrings("asm.js", platform(.essl, "wasm"));
    // Everything else is unchanged on every platform, so desktop/Android
    // binaries stay byte-identical to the pre-#740 pipeline.
    inline for (.{ "desktop", "ios", "android", "wasm", "tests" }) |p| {
        try std.testing.expectEqualStrings("linux", platform(.spv, p));
        try std.testing.expectEqualStrings("linux", platform(.glsl, p));
        try std.testing.expectEqualStrings("windows", platform(.dx11, p));
    }
    // A platform string the pipeline never emits falls back to the language map.
    try std.testing.expectEqualStrings("osx", platform(.mtl, "tests"));
    try std.testing.expectEqualStrings("android", platform(.essl, "tests"));
}
