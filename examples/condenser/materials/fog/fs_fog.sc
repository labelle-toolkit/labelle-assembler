$input v_texcoord0, v_color0
#include <bgfx_shader.sh>
SAMPLER2D(s_tex, 0);
SAMPLER2D(s_fog_clean, 1);
SAMPLER2D(s_fog_mask, 2);
uniform vec4 u_material_rect;
// density, bounded phase, variation, light coupling
uniform vec4 u_fog;
uniform vec4 u_fog_motion;
uniform vec4 u_fog_opacity;
uniform vec4 u_fog_color;
// screen width, height, effect grid, enabled
uniform vec4 u_fog_grid;
// center.xy, width, intensity; up, down, grid, enabled; rgb, unused
uniform vec4 u_lamp[5];
#include <shared/lamp_footprint.sc>

void main()
{
    vec2 uv = (v_texcoord0 - u_material_rect.xy) / max(u_material_rect.zw-u_material_rect.xy, vec2(0.000001));
    vec2 pixel = uv * u_fog_grid.xy;
    vec2 cell = (floor(pixel / u_fog_grid.z) + vec2(0.5)) * u_fog_grid.z;
    // Keep the clean art at its original 618x330 pixel density. Only animated
    // modulation is cell-snapped; mask coverage retains structural edges.
    vec4 clean = texture2D(s_fog_clean, uv);
    vec4 mask = texture2D(s_fog_mask, uv);
    float light = condenserLampAt(pixel);
    vec3 lit = mix(clean.rgb, u_lamp[2].rgb, clamp(mask.g * light, 0.0, 1.0));
    float phase = u_fog.y * 6.2831853;
    vec2 p = (cell / max(u_fog_motion.x, 0.001) - u_fog_motion.zw) * 6.2831853;
    float coarse = sin(p.x) * cos(p.y);
    float fine = sin(2.0*p.x + phase) * cos(2.0*p.y - phase);
    float drift = u_fog_motion.x <= 0.0 ? 0.0 : mix(coarse, fine, u_fog_motion.y);
    float density = u_fog.x * (1.0 + u_fog.z * drift) * u_fog_grid.w;
    // Density changes optical depth; opacity separately fades that result.
    float veil = (1.0 - pow(max(1.0-mask.r, 0.001), density)) * u_fog_opacity.x;
    veil = clamp(veil, 0.0, 0.95);
    // Fog scatters the same lamp footprint used by the frame. The neutral
    // reference lamp is calibrated out, so density=1/variation=0 reproduces
    // the authored plate instead of adding a second haze layer.
    float scatter = (light - condenserReferenceLamp(pixel)) * u_fog.w;
    vec3 fogColor = clamp(u_fog_color.rgb + u_lamp[2].rgb * scatter, vec3(0.0), vec3(1.0));
    gl_FragColor = vec4(mix(lit, fogColor, veil) * v_color0.rgb, clean.a * v_color0.a);
}
