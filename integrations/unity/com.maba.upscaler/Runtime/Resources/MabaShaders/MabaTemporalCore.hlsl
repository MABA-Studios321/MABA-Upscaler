//==============================================================================================
// MABA-Upscaler 2 (Temporal) - engine-neutral HLSL core (Unity / Unreal). Canonical: src/.
//
// Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
// SPDX-License-Identifier: Apache-2.0
//
// Faithful port of maba_temporal.frag.glsl. Runs at RENDER resolution; its output is then
// upscaled by maba_upscaler.hlsl. History and depth ping-pong between two slots.
//
// Contract: invViewProj = inverse of CURRENT UNJITTERED view-proj; prevViewProj = PREVIOUS
// frame's UNJITTERED view-proj; both GL-style (NDC y up, matching texel row 0 = bottom of the
// image). Depth textures hold GL window depth: [0,1], 0 = near, 1 = far - convert reversed-Z
// depth (1 - d) before passing it in, or leave it as the engine stores it and define
// MABA_REVERSED_Z 1 (Unreal). Define MABA_VULKAN 1 for matrices with [0,1] NDC z.
// Engines whose screen rows run top to bottom (Unreal) define MABA_Y_DOWN 1: pixel row 0 is then the
// TOP of the image, and the jitter's y is in the same top-down texel units.
// tparams = (historyWeight, depthTolerance, reset, clipGamma); texel = 1/allocated texture size;
// region = render size in texels; jitter = this frame's jitter in texels, with the image content
// moved BY +jitter (see maba_temporal.h). Reset on camera cuts / resolution changes / first frame.
//==============================================================================================
#ifndef MABA_TEMPORAL_HLSL
#define MABA_TEMPORAL_HLSL

#ifndef MABA_VULKAN
#define MABA_VULKAN 0
#endif
#ifndef MABA_REVERSED_Z
#define MABA_REVERSED_Z 0   // 1: depth textures and matrices are reversed-Z (1 = near, 0 = far)
#endif
#ifndef MABA_Y_DOWN
#define MABA_Y_DOWN 0       // 1: pixel row 0 is the top of the image (NDC y points up)
#endif

// How fast history is distrusted as a pixel moves: weight / (1 + K * motion in texels). See
// maba_temporal.frag.glsl for the measurement behind the default.
#ifndef MABA_TEMPORAL_MOTION_K
#define MABA_TEMPORAL_MOTION_K 4.0
#endif

float3 MabaTToYCoCg(float3 c)
{
    return float3(0.25 * c.r + 0.5 * c.g + 0.25 * c.b,
                  0.5 * c.r - 0.5 * c.b,
                 -0.25 * c.r + 0.5 * c.g - 0.25 * c.b);
}

float3 MabaTFromYCoCg(float3 c)
{
    return float3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

float4 MabaTemporalResolve(
    Texture2D curTex, Texture2D histTex, Texture2D depthTex, Texture2D prevDepthTex,
    SamplerState sampLinear, SamplerState sampPoint,
    float2 pixel, float4x4 invViewProj, float4x4 prevViewProj,
    float4 tparams, float2 texel, float2 region, float2 jitter)
{
    int2 ip = int2(pixel);
    int2 size = int2(region);
    // The current frame was rendered jittered: its content sits +jitter texels from where an
    // unjittered frame would have it. Read it back at the shifted position so every frame and
    // the history share one unjittered grid (without this the output is off by up to half a
    // texel and loses ~2.7 dB). curTex must use a LINEAR sampler.
    float2 curPos = clamp(float2(ip) + 0.5 + jitter, 0.5, region - 0.5);
    float3 cur = curTex.SampleLevel(sampLinear, curPos * texel, 0).rgb;
    float rawDepth = depthTex.Load(int3(ip, 0)).r;
#if MABA_REVERSED_Z
    float depth = 1.0 - rawDepth;   // 0 = near .. 1 = far from here on
#else
    float depth = rawDepth;
#endif

    if (tparams.z > 0.5 || depth >= 1.0 || depth <= 0.0)
        return float4(cur, 1.0);

    float2 ndc = (float2(ip) + 0.5) / region * 2.0 - 1.0;
#if MABA_Y_DOWN
    ndc.y = -ndc.y;
#endif
#if MABA_VULKAN
    float ndcZ = rawDepth;   // the matrices use the same z convention as the depth buffer
#else
    float ndcZ = depth * 2.0 - 1.0;
#endif
    float4 wp = mul(invViewProj, float4(ndc, ndcZ, 1.0));
    wp.xyz /= wp.w;
    float4 pc = mul(prevViewProj, float4(wp.xyz, 1.0));
    if (pc.w <= 0.0)
        return float4(cur, 1.0);
    float2 puv = pc.xy / pc.w * 0.5 + 0.5;
#if MABA_Y_DOWN
    puv.y = 1.0 - puv.y;
#endif
    if (any(puv < 0.0) || any(puv > 1.0))
        return float4(cur, 1.0);

#if MABA_VULKAN
    float expected = pc.z / pc.w;
#else
    float expected = pc.z / pc.w * 0.5 + 0.5;
#endif
    // Keep the previous-frame sample half a texel inside the image region.
    float2 huv = clamp(puv * region, 0.5, region - 0.5) * texel;
    float prevDepth = prevDepthTex.SampleLevel(sampPoint, huv, 0).r;
#if MABA_REVERSED_Z
    // Reversed-Z stores about 1 / z, so a relative difference is the meaningful test: reject when
    // the surface now there is more than ~5% (at the default tolerance) nearer or farther.
    float tol = tparams.y * 5.0 * max(expected, 1e-6);
#else
    float tol = tparams.y * (0.1 + expected);
#endif
    if (abs(expected - prevDepth) > tol)
        return float4(cur, 1.0);

    float3 m1 = 0.0, m2 = 0.0;
    float3 mn = 1e9, mx = -1e9;
    for (int dy = -1; dy <= 1; dy++)
    {
        for (int dx = -1; dx <= 1; dx++)
        {
            int2 p = clamp(ip + int2(dx, dy), int2(0, 0), size - 1);
            float3 c = MabaTToYCoCg(curTex.Load(int3(p, 0)).rgb);
            m1 += c;
            m2 += c * c;
            mn = min(mn, c);
            mx = max(mx, c);
        }
    }
    float3 mean = m1 * (1.0 / 9.0);
    float3 sigma = sqrt(max(m2 * (1.0 / 9.0) - mean * mean, 0.0));
    float gamma = tparams.w;
    float3 lo = max(mean - gamma * sigma, mn);
    float3 hi = min(mean + gamma * sigma, mx);

    float3 hist = MabaTToYCoCg(histTex.SampleLevel(sampLinear, huv, 0).rgb);
    hist = clamp(hist, lo, hi);

    float2 uv = (float2(ip) + 0.5) / region;
    float disp = length((puv - uv) * region);
    float w = tparams.x / (1.0 + MABA_TEMPORAL_MOTION_K * disp);

    float3 outc = MabaTFromYCoCg(lerp(MabaTToYCoCg(cur), hist, w));
    return float4(saturate(outc), 1.0);
}

#endif // MABA_TEMPORAL_HLSL