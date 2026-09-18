$input v_texcoord0, v_color0
#include <bgfx_shader.sh>
SAMPLER2D(s_tex, 0);
SAMPLER2D(s_lamp_clean, 1);
SAMPLER2D(s_lamp_mask, 2);
uniform vec4 u_material_rect;
uniform vec4 u_lamp[5];
#include <shared/lamp_footprint.sc>

void main()
{
    vec2 uv = (v_texcoord0-u_material_rect.xy) / max(u_material_rect.zw-u_material_rect.xy, vec2(0.000001));
    vec2 pixel = uv * vec2(618.0, 330.0);
    float light = condenserLampAt(pixel);
    vec4 clean = texture2D(s_lamp_clean, uv);
    vec4 mask = texture2D(s_lamp_mask, uv);
    vec3 lit = mix(clean.rgb, u_lamp[2].rgb, clamp(mask.r*light, 0.0, 1.0));
    // The static tube was reconstructed out of s_lamp_clean. Never restore
    // baked light outside its authored source mask or a disabled lamp's width.
    vec3 source = texture2D(s_tex, v_texcoord0).rgb * u_lamp[2].rgb / vec3(0.64, 0.85, 0.94);
    float emission = mask.g * condenserLampSource(pixel);
    lit = mix(lit, source, emission);
    gl_FragColor = vec4(lit*v_color0.rgb, clean.a*v_color0.a);
}
