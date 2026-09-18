$input v_texcoord0, v_color0
#include <bgfx_shader.sh>
uniform vec4 u_material_rect;
// left, width, live surface Y, height above surface (screen pixels).
uniform vec4 u_mist_bounds;
// density, opacity, pixel grid, enabled (includes live water state).
uniform vec4 u_mist_style;
// wavelength, turbulence, wrapped translation.xy.
uniform vec4 u_mist_motion;
// RGB tint, lamp response.
uniform vec4 u_mist_color;
uniform vec4 u_lamp[5];
#include <shared/lamp_footprint.sc>

void main()
{
    vec2 uv = (v_texcoord0-u_material_rect.xy) / max(u_material_rect.zw-u_material_rect.xy, vec2(0.000001));
    vec2 pixel = uv * vec2(618.0, 330.0);
    vec2 cell = (floor(pixel/u_mist_style.z)+vec2(0.5))*u_mist_style.z;
    float above = u_mist_bounds.z-pixel.y;
    float left = pixel.x-u_mist_bounds.x;
    float height = max(u_mist_bounds.w, 0.001);
    // Exact bounds keep wisps out of the liquid and neighbouring chambers.
    float clip = step(0.0, left)*step(left, u_mist_bounds.y)*step(0.0, above)*step(above, u_mist_bounds.w);
    vec2 p = ((cell-vec2(u_mist_bounds.x,u_mist_bounds.z))/u_mist_motion.x-u_mist_motion.zw)*6.2831853;
    // Periodic domain-warped wisps wrap continuously without scrolling any art.
    float warp = u_mist_motion.y*sin(p.x+p.y);
    float broad = sin(p.x+warp)*cos(p.y*2.0+warp);
    float fine = sin(p.x*3.0-p.y*2.0)*cos(p.y*3.0+p.x);
    float wisps = smoothstep(-0.55, 0.85, mix(broad, fine, u_mist_motion.y*0.45));
    float rise = clamp((u_mist_bounds.z-cell.y)/height, 0.0, 1.0);
    float fade = (1.0-smoothstep(0.12,1.0,rise))*smoothstep(0.0,0.12,rise);
    float edge = smoothstep(0.0,18.0,min(cell.x-u_mist_bounds.x,u_mist_bounds.x+u_mist_bounds.y-cell.x));
    float alpha = (1.0-exp(-wisps*u_mist_style.x))*u_mist_style.y*fade*edge*clip*u_mist_style.w;
    vec3 color = clamp(u_mist_color.rgb+u_lamp[2].rgb*condenserLampAt(pixel)*u_mist_color.w,vec3(0.0),vec3(1.0));
    gl_FragColor = vec4(color*v_color0.rgb,alpha*v_color0.a);
}
