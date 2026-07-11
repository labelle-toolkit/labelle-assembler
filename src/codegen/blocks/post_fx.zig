//! Post-fx setup emit helper (labelle-gfx#305 Phase 2 Slice C).
//!
//! Emits the gated `g.setPostFx(...)` call that seeds the game's INITIAL
//! post-fx stack from `project.labelle`'s `.post_fx` block. Emitted into BOTH
//! lifecycle paths (loop + callback) in the SAME lexical slot — right after
//! the JSONC scene block and before `runner.setup(&g)`.
//!
//! `g.setPostFx` returns void (infallible), so — unlike `setSceneAssets` —
//! there is no `try` / `catch @panic` split between the loop path and the
//! callback path: both emit the IDENTICAL statement.
//!
//! The whole call is gated on `@hasDecl(AssembledGame, "setPostFx")` so it is
//! forward-compatible: a game built against an older engine (no
//! `Game.setPostFx`) folds the call away at comptime — no flag day. And when
//! `.post_fx` is empty this writes NOTHING, so back-compat projects stay
//! byte-identical.

const std = @import("std");
const config = @import("../../config.zig");
const ProjectConfig = config.ProjectConfig;
const PostFxPass = config.PostFxPass;

/// Emit `if (@hasDecl(AssembledGame, "setPostFx")) g.setPostFx(&.{ ... });`
/// seeding the declared static post-fx stack. No-op (writes nothing) when
/// `.post_fx` is empty, so back-compat projects are byte-identical.
/// `g.setPostFx` returns void, so the loop and callback paths emit the SAME
/// statement (no try / catch@panic split).
pub fn emitPostFxSetup(w: anytype, cfg: ProjectConfig, indent: []const u8) !void {
    if (cfg.post_fx.len == 0) return;
    try w.print("{s}if (@hasDecl(AssembledGame, \"setPostFx\")) g.setPostFx(&.{{\n", .{indent});
    for (cfg.post_fx) |pass| {
        try w.print("{s}    engine.PostPass{{ .kind = .{s}, .uniforms = .{{ ", .{ indent, @tagName(pass) });
        try writeUniforms(w, pass);
        try w.writeAll(" } },\n");
    }
    try w.print("{s}}});\n", .{indent});
}

/// RFC §2.2 friendly-param -> `PostPassUniforms` slot mapping. Emit ONLY the
/// slots this kind uses (keeps output minimal + deterministic for tests).
///   - bloom:       threshold→scalar0, intensity→scalar1, radius→scalar2
///   - vignette:    intensity→scalar0, radius→scalar1, softness→scalar2,
///                  tint→(r,g,b)
///   - color_grade: strength→scalar0, lut→aux_texture
///   - crt:         curvature→scalar0, scanline→scalar1, mask→scalar2,
///                  aberration→scalar3
fn writeUniforms(w: anytype, pass: PostFxPass) !void {
    switch (pass) {
        .bloom => |b| try w.print(".scalar0 = {d}, .scalar1 = {d}, .scalar2 = {d}", .{ b.threshold, b.intensity, b.radius }),
        .vignette => |v| try w.print(".scalar0 = {d}, .scalar1 = {d}, .scalar2 = {d}, .r = {d}, .g = {d}, .b = {d}", .{ v.intensity, v.radius, v.softness, v.tint[0], v.tint[1], v.tint[2] }),
        .color_grade => |c| try w.print(".scalar0 = {d}, .aux_texture = {d}", .{ c.strength, c.lut }),
        .crt => |c| try w.print(".scalar0 = {d}, .scalar1 = {d}, .scalar2 = {d}, .scalar3 = {d}", .{ c.curvature, c.scanline, c.mask, c.aberration }),
    }
}
