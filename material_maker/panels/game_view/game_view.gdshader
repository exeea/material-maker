shader_type spatial;

// A material's exported maps on the ground, seen from above as MegaMek's ground shader samples them: every map read
// twice, the second read 2.37 times larger, turned by 34 degrees and offset, the two blended by a smooth world field.
// Positions are in metres: the view's height spans view_metres, one repeat of the maps spans repeat_metres, and the
// flat-topped hexes of the grid span hex_metres from point to point. The material settings the game reads from the
// .tres apply as in Godot: the albedo tint, the normal map strength and the roughness and metallic factors.

uniform sampler2D albedo_map : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D orm_map : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_map : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 albedo_tint : source_color;
uniform float normal_scale;
uniform float roughness_factor;
uniform float metallic_factor;
uniform float hex_metres;
uniform float repeat_metres;
uniform float view_metres;
uniform bool grid;

const mat2 TURN = mat2(vec2(.8253, .5646), vec2(-.5646, .8253));

varying vec2 metres;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7)))*43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	f = f*f*(3.0-2.0*f);
	return mix(mix(hash(i), hash(i+vec2(1.0, 0.0)), f.x), mix(hash(i+vec2(0.0, 1.0)), hash(i+vec2(1.0, 1.0)), f.x), f.y);
}

// Distance in metres from p to the nearest edge of the hexes, one centred at the origin
float hex_edge_distance(vec2 p) {
	float radius = hex_metres*.5;
	vec2 cell = vec2(3.0*radius, sqrt(3.0)*radius);
	vec2 a = mod(p+cell*.5, cell)-cell*.5;
	vec2 b = mod(p, cell)-cell*.5;
	vec2 h = abs(dot(a, a) < dot(b, b) ? a : b);
	return sqrt(3.0)*.5*radius-max(h.y, dot(h, vec2(sqrt(3.0)*.5, .5)));
}

// The camera shows two units of height
void vertex() {
	metres = (MODEL_MATRIX*vec4(VERTEX, 1.0)).xz*view_metres*.5;
}

void fragment() {
	vec2 a = metres/repeat_metres;
	vec2 b = TURN*a/2.37+.31;
	float t = smoothstep(.2, .8, noise(metres/34.0)*.65+noise(metres/13.0+.19)*.35);
	ALBEDO = albedo_tint.rgb*mix(texture(albedo_map, a).rgb, texture(albedo_map, b).rgb, t);
	vec3 orm = mix(texture(orm_map, a).rgb, texture(orm_map, b).rgb, t);
	AO = orm.r;
	ROUGHNESS = orm.g*roughness_factor;
	METALLIC = orm.b*metallic_factor;
	vec3 na = texture(normal_map, a).rgb*2.0-1.0;
	vec3 nb = texture(normal_map, b).rgb*2.0-1.0;
	nb.xy = transpose(TURN)*nb.xy;
	NORMAL_MAP = normalize(mix(na, nb, t))*.5+.5;
	NORMAL_MAP_DEPTH = normal_scale;
	if (grid) {
		float edge = hex_edge_distance(metres);
		float line = 1.0-smoothstep(0.0, 1.5*fwidth(edge), edge);
		ALBEDO = mix(ALBEDO, vec3(1.0, .85, .2), line*.8);
	}
}
