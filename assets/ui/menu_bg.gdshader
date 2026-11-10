// Shared menu background (0.16.0, "Gilded Ink").
//
// One full-screen ColorRect behind every menu: a radial ink-blue gradient,
// a slow low-frequency "smoke" at a few percent, an optional hex core
// lattice, a vignette, and the nebula art blended in at `art_mix`. A `tint`
// uniform takes the active deck's colour at a few percent; `offset` is the
// mouse parallax, written by Motion.parallax() at most once per frame.
//
// Everything is cheap enough for the GL Compatibility renderer and for the
// xvfb screenshot path: no texture lookups beyond the art, no loops.
shader_type canvas_item;

uniform vec4 bg_edge : source_color = vec4(0.043, 0.051, 0.078, 1.0);   // #0B0D14
uniform vec4 bg_centre : source_color = vec4(0.071, 0.086, 0.141, 1.0); // #121624
uniform vec4 tint : source_color = vec4(0.0, 0.0, 0.0, 0.0);
uniform float tint_amount : hint_range(0.0, 0.3) = 0.06;
uniform float smoke : hint_range(0.0, 0.2) = 0.045;
uniform float lattice : hint_range(0.0, 0.1) = 0.02;
uniform float vignette : hint_range(0.0, 1.0) = 0.55;
uniform float art_mix : hint_range(0.0, 1.0) = 0.0;
uniform float art_aspect = 1.7778;
uniform vec2 offset = vec2(0.0, 0.0);
uniform float speed = 1.0;
uniform sampler2D art : source_color, filter_linear, repeat_disable;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Distance to the nearest hex edge on a pointy-top lattice, 0 on the edge.
float hex_edge(vec2 p) {
	vec2 q = vec2(p.x * 1.1547, p.y + p.x * 0.5774);
	vec2 pi = floor(q);
	vec2 pf = fract(q);
	float v = mod(pi.x + pi.y, 3.0);
	float ca = step(1.0, v);
	float cb = step(2.0, v);
	vec2 ma = step(pf.xy, pf.yx);
	float e = dot(ma, 1.0 - pf.yx + ca * (pf.x + pf.y - 1.0) + cb * (pf.yx - 2.0 * pf.xy));
	return e;
}

void fragment() {
	vec2 uv = UV + offset;
	vec2 c = uv - vec2(0.5);
	float r = length(c * vec2(1.25, 1.0));
	vec3 col = mix(bg_centre.rgb, bg_edge.rgb, smoothstep(0.05, 0.95, r));

	// Nebula art, cover-fitted and sunk into the gradient.
	if (art_mix > 0.001) {
		vec2 vp = 1.0 / SCREEN_PIXEL_SIZE;
		float va = vp.x / max(vp.y, 1.0);
		vec2 auv = uv;
		if (va > art_aspect) {
			float s = art_aspect / va;
			auv.y = (uv.y - 0.5) * s + 0.5;
		} else {
			float s = va / art_aspect;
			auv.x = (uv.x - 0.5) * s + 0.5;
		}
		vec3 a = texture(art, clamp(auv, 0.0, 1.0)).rgb;
		col = mix(col, col + a * 0.9, art_mix);
	}

	// Smoke: two octaves of value noise drifting slowly in opposite directions.
	float t = TIME * 0.02 * speed;
	float n = vnoise(uv * 3.0 + vec2(t, -t * 0.6)) * 0.65
			+ vnoise(uv * 6.5 - vec2(t * 1.3, t * 0.4)) * 0.35;
	col += (n - 0.5) * smoke;

	// Core lattice: faint hex lines, fading towards the edges.
	if (lattice > 0.001) {
		float e = hex_edge(uv * vec2(22.0 * (1.0 / SCREEN_PIXEL_SIZE.x) / (1.0 / SCREEN_PIXEL_SIZE.y), 22.0));
		float line = 1.0 - smoothstep(0.0, 0.06, e);
		col += vec3(0.31, 0.79, 0.88) * line * lattice * (1.0 - smoothstep(0.2, 0.75, r));
	}

	col = mix(col, col + tint.rgb * 0.5, tint_amount * tint.a);
	col *= 1.0 - vignette * smoothstep(0.35, 1.05, r);
	COLOR = vec4(col, 1.0);
}
