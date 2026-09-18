// Game-owned port of the original water shader. Only impacts move the surface.
$input v_texcoord0, v_color0

#include <bgfx_shader.sh>

SAMPLER2D(s_tex, 0);
SAMPLER2D(s_water_mask, 1);
SAMPLER2D(s_water_reflect, 2);

uniform vec4 u_material_rect;
uniform vec4 u_water_head[2];
uniform vec4 u_water_color[3];
uniform vec4 u_water_params[3];
uniform vec4 u_water_ripples[8];

#define WATER_MAX_RIPPLES 8

#define WATER_WAVE_CELLS 16.0

#define WATER_REFLECT_CELLS 11.0
#define WATER_TAU 6.2831853

float waterQuant(float v, float g)
{
	return floor(v / g + 0.5) * g;
}

void main()
{

	vec4 art = texture2D(s_tex, v_texcoord0);
	vec3 base_rgb = art.rgb * v_color0.rgb;
	float base_a = art.a;

	vec2 span = max(u_material_rect.zw - u_material_rect.xy, vec2(1e-6, 1e-6));
	vec2 local_uv = (v_texcoord0 - u_material_rect.xy) / span;

	vec2 logical = max(u_water_head[0].xy, vec2(1.0, 1.0));
	float grid = max(u_water_head[0].z, 1.0);
	float ripple_count = u_water_head[0].w;

	float has_mask = u_water_head[1].y;
	float has_reflect = u_water_head[1].z;

	float level = clamp(u_water_params[0].x, 0.0, 1.0);
	float time = u_water_params[0].y;
	float amplitude = 0.0;
	float period = max(u_water_params[0].w, 1e-4);

	float reflect_opacity = clamp(u_water_params[1].y, 0.0, 1.0);
	float ripple_duration = max(u_water_params[1].z, 1e-4);
	float ripple_radius = max(u_water_params[1].w, 1e-4);
	float ripple_strength = u_water_params[2].x;

	vec2 local_px = local_uv * logical;

	vec2 cell = (floor(local_px / grid) + vec2(0.5, 0.5)) * grid;

	float surface_y = logical.y * (1.0 - level);

	float wave = 0.0;

	float ripple = 0.0;
	for (int i = 0; i < WATER_MAX_RIPPLES; ++i)
	{
		if (float(i) >= ripple_count) continue;
		vec4 r = u_water_ripples[i];
		float age = time - r.y;

		if (age < 0.0 || age >= ripple_duration) continue;
		float dist = abs(cell.x - r.x);
		float falloff = max(0.0, 1.0 - dist / ripple_radius);
		float fade = 1.0 - age / ripple_duration;
		ripple += ripple_strength * r.z * falloff * fade *
			sin(WATER_TAU * (dist / ripple_radius - age / ripple_duration));
	}

	float offset = waterQuant(wave + ripple, grid);
	float surface = surface_y + offset;

	surface = mix(surface, min(surface, surface_y), step(1.0 - 1e-6, level));

	vec2 cell_uv = clamp(cell / logical, vec2(0.0, 0.0), vec2(1.0, 1.0));
	vec4 mask_texel = texture2D(s_water_mask, cell_uv);
	float mask_a = mix(1.0, mask_texel.a * max(mask_texel.r, max(mask_texel.g, mask_texel.b)), has_mask);

	float below = step(surface, cell.y);
	float coverage = mask_a * below * step(1e-6, level);

	float depth_span = max(logical.y - surface, 1e-4);
	float depth = clamp((cell.y - surface) / depth_span, 0.0, 1.0);
	vec3 body_rgb = mix(u_water_color[1].rgb, u_water_color[0].rgb, depth);
	float body_a = mix(u_water_color[1].a, u_water_color[0].a, depth);

	float shift = 0.0;
	vec2 reflect_uv = clamp(
		vec2((cell.x + shift) / logical.x, cell.y / logical.y),
		vec2(0.0, 0.0), vec2(1.0, 1.0));
	vec4 reflect_texel = texture2D(s_water_reflect, reflect_uv);
	float reflect_mix = reflect_opacity * has_reflect * reflect_texel.a;
	vec3 water_rgb = mix(body_rgb, reflect_texel.rgb, reflect_mix);

	float crest_scale = max(amplitude + abs(ripple_strength), 1e-4);
	float crest = clamp(0.5 + 0.5 * (offset / crest_scale), 0.0, 1.0);
	float highlight = u_water_color[2].a * (1.0 - step(grid, cell.y - surface)) * crest;
	water_rgb = mix(water_rgb, u_water_color[2].rgb, highlight);

	float water_a = coverage * body_a;
	float comp_a = water_a + base_a * (1.0 - water_a);
	vec3 comp_pre = water_rgb * water_a + base_rgb * base_a * (1.0 - water_a);
	vec3 comp_rgb = comp_a > 0.0 ? comp_pre / comp_a : vec3(0.0, 0.0, 0.0);

	gl_FragColor = vec4(comp_rgb, comp_a * v_color0.a);
}
