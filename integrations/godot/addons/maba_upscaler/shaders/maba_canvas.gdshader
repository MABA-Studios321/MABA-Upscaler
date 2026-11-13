// MABA Upscaler - Godot canvas_item port of src/maba_upscaler.frag.glsl.
//
// Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
// SPDX-License-Identifier: Apache-2.0
//
// The quality path is derived from AMD FidelityFX Super Resolution 1.0 (EASU), MIT licence;
// keep THIRD_PARTY_NOTICES.md with any copy of this file.
//
// Used on a full-screen TextureRect that displays a SubViewport rendered at reduced scale.
// The SubViewport texture is the finished LDR image (its own tonemapping applies), which is
// MABA's input contract. Godot's shading language has no textureGather, so this port uses the
// gather-free texel-read path for both builds.
//
// input_size = (viewportW, viewportH, 1/viewportW, 1/viewportH); params.x = sharpness 0..1.

shader_type canvas_item;

uniform sampler2D src_linear : filter_linear, repeat_disable;
uniform sampler2D src_nearest : filter_nearest, repeat_disable;
uniform vec4 input_size;
uniform vec4 params;
uniform int quality = 0;

const float EDGE_LO = 10.0 / 255.0;
const float EDGE_HI = 24.0 / 255.0;
const float DARK_LO = 0.02;
const float DARK_HI = 0.12;

vec2 sharp_pos(vec2 pp, float brightness) {
	float s = params.x * clamp((brightness - DARK_LO) * (1.0 / (DARK_HI - DARK_LO)), 0.0, 1.0);
	return pp + s * pp * (pp - 1.0) * (1.0 - 2.0 * pp);
}

float diagonal(float f, float g, float j, float k) {
	float dFK = abs(f - k);
	float dGJ = abs(g - j);
	return clamp(0.5 + (dGJ - dFK) / (dGJ + dFK + 1.0 / 255.0), 0.0, 1.0);
}

float twist_weight(vec2 p, float preferFK) {
	return mix(max(p.x + p.y - 1.0, 0.0), min(p.x, p.y), preferFK);
}

vec3 texel(int x, int y) {
	return textureLod(src_nearest, (vec2(float(x), float(y)) + 0.5) * input_size.zw, 0.0).rgb;
}

float block_delta(float f, float g, float j, float k, vec2 pp) {
	vec2 p = sharp_pos(pp, max(max(f, g), max(j, k)));
	return (g - f) * (p.x - pp.x) + (j - f) * (p.y - pp.y)
		+ (f - g - j + k) * (twist_weight(p, diagonal(f, g, j, k)) - pp.x * pp.y);
}

void maba_set(inout vec2 dir, inout float len, float w,
		float lA, float lB, float lC, float lD, float lE) {
	float dirX = lD - lB;
	float lenX = max(abs(lD - lC), abs(lC - lB));
	lenX = clamp(abs(dirX) / max(lenX, 1.0 / 512.0), 0.0, 1.0);
	dir.x += dirX * w;
	len += lenX * lenX * w;
	float dirY = lE - lA;
	float lenY = max(abs(lE - lC), abs(lC - lA));
	lenY = clamp(abs(dirY) / max(lenY, 1.0 / 512.0), 0.0, 1.0);
	dir.y += dirY * w;
	len += lenY * lenY * w;
}

void maba_tap(inout float aC, inout float aW, vec2 off, vec2 dir, vec2 len2,
		float lob, float clp, float c) {
	vec2 v = vec2(off.x * dir.x + off.y * dir.y, off.y * dir.x - off.x * dir.y) * len2;
	float d2 = min(dot(v, v), clp);
	float wB = 0.4 * d2 - 1.0;
	float wA = lob * d2 - 1.0;
	wB *= wB;
	wA *= wA;
	wB = 1.5625 * wB - 0.5625;
	float w = wB * wA;
	aC += c * w;
	aW += w;
}

// Godot does not allow `return` inside fragment(), so the upscale lives in a function.
vec3 maba_upscale(vec2 uv) {
	vec2 pos = clamp(uv * input_size.xy - 0.5, vec2(0.0), input_size.xy - 1.001);
	vec2 fp = floor(pos);
	vec2 pp = pos - fp;
	int x = int(fp.x);
	int y = int(fp.y);

	vec3 f3 = texel(x, y);
	vec3 g3 = texel(x + 1, y);
	vec3 j3 = texel(x, y + 1);
	vec3 k3 = texel(x + 1, y + 1);

	if (quality == 0) {
		vec2 p = sharp_pos(pp, max(max(f3.g, g3.g), max(j3.g, k3.g)));
		float w = twist_weight(p, diagonal(f3.g, g3.g, j3.g, k3.g));
		return f3 + (g3 - f3) * p.x + (j3 - f3) * p.y + (f3 - g3 - j3 + k3) * w;
	}

	vec3 color = texture(src_linear, min(uv * input_size.xy, input_size.xy - 0.5) * input_size.zw).rgb;
	float f = f3.g, g = g3.g, j = j3.g, k = k3.g;
	float mn = min(min(f, g), min(j, k));
	float mx = max(max(f, g), max(j, k));
	float bd = block_delta(f, g, j, k, pp);
	float contrast = mx - mn;

	if (contrast < EDGE_LO || fp.x < 1.0 || fp.y < 1.0
			|| fp.x + 2.5 > input_size.x || fp.y + 2.5 > input_size.y) {
		return clamp(color + bd, 0.0, 1.0);
	}

	float b = texel(x, y - 1).g;
	float c = texel(x + 1, y - 1).g;
	float i = texel(x - 1, y + 1).g;
	float e = texel(x - 1, y).g;
	float l = texel(x + 2, y + 1).g;
	float h = texel(x + 2, y).g;
	float o = texel(x + 1, y + 2).g;
	float n = texel(x, y + 2).g;

	vec2 dir = vec2(0.0);
	float len = 0.0;
	maba_set(dir, len, (1.0 - pp.x) * (1.0 - pp.y), b, e, f, g, j);
	maba_set(dir, len, pp.x * (1.0 - pp.y), c, f, g, h, k);
	maba_set(dir, len, (1.0 - pp.x) * pp.y, f, i, j, k, n);
	maba_set(dir, len, pp.x * pp.y, g, j, k, l, o);

	float dirR = dot(dir, dir);
	if (dirR < 1.0 / 8192.0) {
		dir = vec2(1.0, 0.0);
	} else {
		dir *= inversesqrt(dirR);
	}
	len = len * 0.5;
	len *= len;
	float stretch = 1.0 / max(abs(dir.x), abs(dir.y));
	vec2 len2 = vec2(1.0 + (stretch - 1.0) * len, 1.0 - 0.5 * len);
	float lob = 0.5 - 0.29 * len;
	float clp = 1.0 / lob;

	float aC = 0.0;
	float aW = 0.0;
	maba_tap(aC, aW, vec2(0.0, -1.0) - pp, dir, len2, lob, clp, b);
	maba_tap(aC, aW, vec2(1.0, -1.0) - pp, dir, len2, lob, clp, c);
	maba_tap(aC, aW, vec2(-1.0, 1.0) - pp, dir, len2, lob, clp, i);
	maba_tap(aC, aW, vec2(0.0, 1.0) - pp, dir, len2, lob, clp, j);
	maba_tap(aC, aW, vec2(0.0, 0.0) - pp, dir, len2, lob, clp, f);
	maba_tap(aC, aW, vec2(-1.0, 0.0) - pp, dir, len2, lob, clp, e);
	maba_tap(aC, aW, vec2(1.0, 1.0) - pp, dir, len2, lob, clp, k);
	maba_tap(aC, aW, vec2(2.0, 1.0) - pp, dir, len2, lob, clp, l);
	maba_tap(aC, aW, vec2(2.0, 0.0) - pp, dir, len2, lob, clp, h);
	maba_tap(aC, aW, vec2(1.0, 0.0) - pp, dir, len2, lob, clp, g);
	maba_tap(aC, aW, vec2(1.0, 2.0) - pp, dir, len2, lob, clp, o);
	maba_tap(aC, aW, vec2(0.0, 2.0) - pp, dir, len2, lob, clp, n);

	float edgeG = clamp(aC / aW, mn, mx);
	float bilG = mix(mix(f, g, pp.x), mix(j, k, pp.x), pp.y);
	float gain = 1.0 + params.x * smoothstep(DARK_LO, DARK_HI, bilG);
	float outG = clamp(bilG + (edgeG - bilG) * gain, mn, mx);
	float blend = clamp((contrast - EDGE_LO) * (1.0 / (EDGE_HI - EDGE_LO)), 0.0, 1.0);
	return clamp(color + mix(bd, outG - bilG, blend), 0.0, 1.0);
}

void fragment() {
	COLOR = vec4(maba_upscale(UV), 1.0);
}