// MABA Upscaler - RenderingDevice (Vulkan) port of src/maba_upscaler.frag.glsl.
//
// Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
// SPDX-License-Identifier: Apache-2.0
//
// The MABA_QUALITY path is derived from AMD FidelityFX Super Resolution 1.0 (EASU),
// Copyright (c) 2021 Advanced Micro Devices, Inc., used under the MIT licence. The full
// AMD notice is in THIRD_PARTY_NOTICES.md and must be kept with any copy of this file.
//
// Godot's compositor sees the 3D colour buffer in LINEAR space, before tonemapping. The
// core MABA maths expects a perceptual (gamma / sRGB-encoded) LDR image, so this port wraps
// the core maths in a linear<->gamma-2.2 conversion. uMabaParams.y selects it (1 = convert,
// 0 = pass through). The core functions below are otherwise identical to the reference.
//
// Vulkan always has textureGather, so MABA_GATHER is fixed to 1 and the GLES 3.0 fallback
// path from the reference is not needed here.

// Godot imports this file as an RDShaderFile (so it is baked into exported games): the two builds
// are named versions, selected with RDShaderFile.get_spirv(version); the defines land where the
// VERSION_DEFINES token sits in the fragment stage. test/compile_shaders.ps1 substitutes the same text.
#[versions]

fast = "#define MABA_QUALITY 0";
quality = "#define MABA_QUALITY 1";

#[vertex]
#version 450

layout(location = 0) out highp vec2 vMabaUV;

void main()
{
    highp vec2 p = vec2(float((gl_VertexIndex << 1) & 2), float(gl_VertexIndex & 2));
    vMabaUV = p;
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}

#[fragment]
#version 450

// Godot replaces this token with the selected version's defines (see #[versions] above). Without it
// the defines are silently dropped.
VERSION_DEFINES

precision mediump float;
precision mediump int;

#define MABA_GATHER 1

#ifndef MABA_QUALITY
#define MABA_QUALITY 0
#endif

#ifndef MABA_EDGE_LO
#define MABA_EDGE_LO (10.0 / 255.0)
#endif
#ifndef MABA_EDGE_HI
#define MABA_EDGE_HI (24.0 / 255.0)
#endif

#ifndef MABA_DARK_LO
#define MABA_DARK_LO 0.02
#endif
#ifndef MABA_DARK_HI
#define MABA_DARK_HI 0.12
#endif

layout(set = 0, binding = 0) uniform sampler2D uMabaInput;
layout(push_constant) uniform MabaConstants
{
    highp vec4 uMabaInputSize;   // xy = image region size in texels, zw = 1 / texture size
    mediump vec4 uMabaParams;    // x = sharpness 0..1; y = linear<->perceptual convert flag
};
layout(location = 0) in highp vec2 vMabaUV;
layout(location = 0) out mediump vec4 oMabaColor;

// Godot-specific colour-space glue. The reference shader assumes its input is already
// perceptual; here the input is linear, so convert in, run the core maths, convert out.
vec3 mabaToPerceptual(vec3 c)
{
    if (uMabaParams.y < 0.5) return c;
    return pow(max(c, vec3(0.0)), vec3(1.0 / 2.2));
}
vec4 mabaToPerceptual4(vec4 c)
{
    if (uMabaParams.y < 0.5) return c;
    return pow(max(c, vec4(0.0)), vec4(1.0 / 2.2));
}
vec3 mabaToLinear(vec3 c)
{
    if (uMabaParams.y < 0.5) return c;
    return pow(max(c, vec3(0.0)), vec3(2.2));
}

//----------------------------------------------------------------------------------------------
// 2x2 block reconstruction (the default path, and the low-contrast part of MABA_QUALITY).
//----------------------------------------------------------------------------------------------

vec2 MabaSharpPos(vec2 pp, float brightness)
{
    float s = uMabaParams.x
            * clamp((brightness - MABA_DARK_LO) * (1.0 / (MABA_DARK_HI - MABA_DARK_LO)), 0.0, 1.0);
    return pp + s * pp * (pp - 1.0) * (1.0 - 2.0 * pp);   // = mix(pp, smoothstep(pp), s)
}

float MabaDiagonal(float f, float g, float j, float k)
{
    float dFK = abs(f - k);
    float dGJ = abs(g - j);
    return clamp(0.5 + (dGJ - dFK) / (dGJ + dFK + 1.0 / 255.0), 0.0, 1.0);
}

float MabaTwistWeight(vec2 p, float preferFK)
{
    return mix(max(p.x + p.y - 1.0, 0.0), min(p.x, p.y), preferFK);
}

float MabaBlockDelta(float f, float g, float j, float k, vec2 pp)
{
    vec2 p = MabaSharpPos(pp, max(max(f, g), max(j, k)));
    return (g - f) * (p.x - pp.x) + (j - f) * (p.y - pp.y)
         + (f - g - j + k) * (MabaTwistWeight(p, MabaDiagonal(f, g, j, k)) - pp.x * pp.y);
}

highp vec2 MabaPos()
{
    return clamp(vMabaUV * uMabaInputSize.xy - 0.5, vec2(0.0), uMabaInputSize.xy - 1.001);
}

vec3 MabaBilinear()
{
    highp vec2 uv = min(vMabaUV * uMabaInputSize.xy, uMabaInputSize.xy - 0.5) * uMabaInputSize.zw;
    return textureLod(uMabaInput, uv, 0.0).rgb;
}

#if !MABA_QUALITY

void main()
{
    highp vec2 pos = MabaPos();
    highp vec2 fp = floor(pos);
    vec2 pp = pos - fp;
    vec3 color = mabaToPerceptual(MabaBilinear());

    // 1 gather (green as luma) + the bilinear colour, same as the reference fast build.
    vec4 q = mabaToPerceptual4(textureGather(uMabaInput, (fp + 1.0) * uMabaInputSize.zw, 1));
    float delta = MabaBlockDelta(q.w, q.z, q.x, q.y, pp);
    oMabaColor = vec4(mabaToLinear(clamp(color + delta, 0.0, 1.0)), 1.0);
}

#else
//----------------------------------------------------------------------------------------------
// MABA_QUALITY path: FSR 1.0 EASU-style kernel on luma only.
//----------------------------------------------------------------------------------------------

void MabaSet(inout vec2 dir, inout float len, float w,
             float lA, float lB, float lC, float lD, float lE)
{
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

void MabaTap(inout float aC, inout float aW, vec2 off, vec2 dir, vec2 len2,
             float lob, float clp, float c)
{
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

void main()
{
    highp vec2 pos = MabaPos();
    highp vec2 fp = floor(pos);
    vec2 pp = pos - fp;
    vec3 color = mabaToPerceptual(MabaBilinear());

    vec4 q = mabaToPerceptual4(textureGather(uMabaInput, (fp + 1.0) * uMabaInputSize.zw, 1));
    float f = q.w, g = q.z, j = q.x, k = q.y;
    float mn = min(min(f, g), min(j, k));
    float mx = max(max(f, g), max(j, k));
    float blockDelta = MabaBlockDelta(f, g, j, k, pp);
    float contrast = mx - mn;

    if (contrast < MABA_EDGE_LO || any(lessThan(fp, vec2(1.0)))
        || any(greaterThan(fp + 2.5, uMabaInputSize.xy)))
    {
        oMabaColor = vec4(mabaToLinear(clamp(color + blockDelta, 0.0, 1.0)), 1.0);
        return;
    }

    highp vec2 p0 = (fp + vec2(1.0, -1.0)) * uMabaInputSize.zw;
    vec4 ijfe = mabaToPerceptual4(textureGather(uMabaInput, p0 + vec2(-1.0, 2.0) * uMabaInputSize.zw, 1));
    vec4 klhg = mabaToPerceptual4(textureGather(uMabaInput, p0 + vec2( 1.0, 2.0) * uMabaInputSize.zw, 1));

    vec4 bczz = mabaToPerceptual4(textureGather(uMabaInput, p0, 1));
    vec4 zzon = mabaToPerceptual4(textureGather(uMabaInput, p0 + vec2(0.0, 4.0) * uMabaInputSize.zw, 1));
    float b = bczz.x, c = bczz.y;
    float i = ijfe.x, e = ijfe.w;
    float l = klhg.y, h = klhg.z;
    float o = zzon.z, n = zzon.w;

    vec2 dir = vec2(0.0);
    float len = 0.0;
    MabaSet(dir, len, (1.0 - pp.x) * (1.0 - pp.y), b, e, f, g, j);
    MabaSet(dir, len, pp.x * (1.0 - pp.y),         c, f, g, h, k);
    MabaSet(dir, len, (1.0 - pp.x) * pp.y,         f, i, j, k, n);
    MabaSet(dir, len, pp.x * pp.y,                 g, j, k, l, o);

    float dirR = dot(dir, dir);
    bool zro = dirR < (1.0 / 8192.0);
    dir = zro ? vec2(1.0, 0.0) : dir * inversesqrt(dirR);

    len = len * 0.5;
    len *= len;
    float stretch = 1.0 / max(abs(dir.x), abs(dir.y));
    vec2 len2 = vec2(1.0 + (stretch - 1.0) * len, 1.0 - 0.5 * len);
    float lob = 0.5 - 0.29 * len;
    float clp = 1.0 / lob;

    float aC = 0.0;
    float aW = 0.0;
    MabaTap(aC, aW, vec2( 0.0, -1.0) - pp, dir, len2, lob, clp, b);
    MabaTap(aC, aW, vec2( 1.0, -1.0) - pp, dir, len2, lob, clp, c);
    MabaTap(aC, aW, vec2(-1.0,  1.0) - pp, dir, len2, lob, clp, i);
    MabaTap(aC, aW, vec2( 0.0,  1.0) - pp, dir, len2, lob, clp, j);
    MabaTap(aC, aW, vec2( 0.0,  0.0) - pp, dir, len2, lob, clp, f);
    MabaTap(aC, aW, vec2(-1.0,  0.0) - pp, dir, len2, lob, clp, e);
    MabaTap(aC, aW, vec2( 1.0,  1.0) - pp, dir, len2, lob, clp, k);
    MabaTap(aC, aW, vec2( 2.0,  1.0) - pp, dir, len2, lob, clp, l);
    MabaTap(aC, aW, vec2( 2.0,  0.0) - pp, dir, len2, lob, clp, h);
    MabaTap(aC, aW, vec2( 1.0,  0.0) - pp, dir, len2, lob, clp, g);
    MabaTap(aC, aW, vec2( 1.0,  2.0) - pp, dir, len2, lob, clp, o);
    MabaTap(aC, aW, vec2( 0.0,  2.0) - pp, dir, len2, lob, clp, n);

    float edgeG = clamp(aC / aW, mn, mx);

    float bilG = mix(mix(f, g, pp.x), mix(j, k, pp.x), pp.y);
    float gain = 1.0 + 0.5 * uMabaParams.x * smoothstep(MABA_DARK_LO, MABA_DARK_HI, bilG);   // MABA_QUALITY_GAIN 0.5
    float outG = clamp(bilG + (edgeG - bilG) * gain, mn, mx);

    float blend = clamp((contrast - MABA_EDGE_LO) * (1.0 / (MABA_EDGE_HI - MABA_EDGE_LO)), 0.0, 1.0);
    oMabaColor = vec4(mabaToLinear(clamp(color + mix(blockDelta, outG - bilG, blend), 0.0, 1.0)), 1.0);
}
#endif