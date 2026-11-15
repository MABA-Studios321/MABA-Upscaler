// MABA-Upscaler 2 (Temporal) - RenderingDevice (Vulkan) resolve pass for Godot.
//
// Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
// SPDX-License-Identifier: Apache-2.0
//
// Godot port of src/maba_temporal.frag.glsl / maba_temporal.hlsl: depth + matrix reprojection.
// It runs at INTERNAL (render) resolution on the compositor's POST_TRANSPARENT colour (linear,
// pre-tonemap): the blend and the neighbourhood clamp are done in gamma-2.2 YCoCg and the result
// is written back as linear. It also writes this frame's depth, which is next frame's previous
// depth.
//
//   uCur        this frame's colour, rendered with a sub-texel projection jitter
//   uHist       last frame's resolve (same size)
//   uDepth      this frame's scene depth. Godot (Forward+ / Mobile) stores reversed-Z: 1 = near, 0 = far
//   uPrevDepth  last frame's depth, as written by this pass
//
// uCurToPrev maps this frame's UN-JITTERED clip space to last frame's UN-JITTERED clip space
// (prevViewProj * inverse(viewProj)), built in GDScript from the renderer's own matrices. Godot's
// projection already has the Vulkan y flip, so NDC y runs with the texture rows.
// uJitter.xy = this frame's jitter in texels (the image content was moved BY +jitter),
// uJitter.z = depth tolerance (relative, default 0.01).

#[vertex]
#version 450

layout(location = 0) out highp vec2 vUV;

void main()
{
    highp vec2 p = vec2(float((gl_VertexIndex << 1) & 2), float(gl_VertexIndex & 2));
    vUV = p;
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}

#[fragment]
#version 450

layout(set = 0, binding = 0) uniform sampler2D uCur;
layout(set = 0, binding = 1) uniform sampler2D uHist;
layout(set = 0, binding = 2) uniform sampler2D uDepth;
layout(set = 0, binding = 3) uniform sampler2D uPrevDepth;

layout(push_constant) uniform MabaTemporalConstants
{
    highp mat4 uCurToPrev;
    highp vec4 uSize;     // xy = size in texels, zw = 1 / size
    highp vec4 uJitter;   // xy = jitter now (texels), z = depth tolerance, w = 1: read the frame at +jitter (bilinear), 0: point sample
    highp vec4 uParams;   // x = history weight, y = reset (1 = ignore history), z = clip gamma, w = motion K
};

layout(location = 0) in highp vec2 vUV;
layout(location = 0) out highp vec4 oColor;
layout(location = 1) out highp float oDepth;

highp vec3 toGamma(highp vec3 c) { return pow(clamp(c, 0.0, 1.0), vec3(1.0 / 2.2)); }
highp vec3 toLinear(highp vec3 c) { return pow(clamp(c, 0.0, 1.0), vec3(2.2)); }

highp vec3 toYCoCg(highp vec3 c)
{
    return vec3(0.25 * c.r + 0.5 * c.g + 0.25 * c.b,
                0.5 * c.r - 0.5 * c.b,
               -0.25 * c.r + 0.5 * c.g - 0.25 * c.b);
}

highp vec3 fromYCoCg(highp vec3 c)
{
    return vec3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

void main()
{
    ivec2 ip = ivec2(gl_FragCoord.xy);
    ivec2 isize = ivec2(uSize.xy);
    highp vec2 texel = uSize.zw;
    highp vec2 uv = (vec2(ip) + 0.5) * texel;

    highp float depth = texelFetch(uDepth, ip, 0).r;
    oDepth = depth;

    // The current frame was rendered jittered: its content sits +jitter texels from where an
    // un-jittered frame would have it, so read it back at the shifted position.
    highp vec2 curPos = clamp(vec2(ip) + 0.5 + uJitter.xy * uJitter.w, vec2(0.5), uSize.xy - 0.5);
    highp vec3 cur = toGamma(textureLod(uCur, curPos * texel, 0.0).rgb);
    oColor = vec4(toLinear(cur), 1.0);

    if (uParams.y > 0.5)
        return;

    // Sky / infinitely far pixels have depth 0 (reversed-Z); keep them just inside the range so
    // the reprojection stays finite (they only rotate with the camera).
    highp float d = max(depth, 1e-6);
    highp vec4 pc = uCurToPrev * vec4(uv * 2.0 - 1.0, d, 1.0);
    if (pc.w <= 0.0)
        return;
    highp vec2 puv = pc.xy / pc.w * 0.5 + 0.5;
    if (any(lessThan(puv, vec2(0.0))) || any(greaterThan(puv, vec2(1.0))))
        return;

    highp float expected = pc.z / pc.w;
    highp vec2 huv = clamp(puv * uSize.xy, vec2(0.5), uSize.xy - 0.5) * texel;
    highp float prevDepth = textureLod(uPrevDepth, huv, 0.0).r;
    // Reversed-Z stores about 1 / z, so a relative difference is the meaningful test. Two sky
    // pixels always agree.
    highp float tol = uJitter.z * 5.0 * max(expected, 1e-6);
    bool bothSky = depth <= 1e-5 && prevDepth <= 1e-5;
    if (!bothSky && abs(expected - prevDepth) > tol)
        return;

    highp vec3 m1 = vec3(0.0), m2 = vec3(0.0);
    highp vec3 mn = vec3(1e9), mx = vec3(-1e9);
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            ivec2 p = clamp(ip + ivec2(dx, dy), ivec2(0), isize - 1);
            highp vec3 c = toYCoCg(toGamma(texelFetch(uCur, p, 0).rgb));
            m1 += c;
            m2 += c * c;
            mn = min(mn, c);
            mx = max(mx, c);
        }
    }
    highp vec3 mean = m1 * (1.0 / 9.0);
    highp vec3 sigma = sqrt(max(m2 * (1.0 / 9.0) - mean * mean, 0.0));
    highp vec3 lo = max(mean - uParams.z * sigma, mn);
    highp vec3 hi = min(mean + uParams.z * sigma, mx);

    highp vec3 hist = toYCoCg(toGamma(textureLod(uHist, huv, 0.0).rgb));
    hist = clamp(hist, lo, hi);

    // History is distrusted as the pixel moves: weight / (1 + K * motion in texels).
    highp float disp = length((puv - uv) * uSize.xy);
    highp float w = uParams.x / (1.0 + uParams.w * disp);

    highp vec3 outc = fromYCoCg(mix(toYCoCg(cur), hist, w));
    oColor = vec4(toLinear(outc), 1.0);
}
