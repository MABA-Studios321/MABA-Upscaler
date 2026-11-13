// MABA Upscaler - full-screen blit used to resample the upscaled image back into the
// viewport's internal colour buffer (see maba_compositor_effect.gd for why this is needed).
//
// Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
// SPDX-License-Identifier: Apache-2.0

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

precision mediump float;
precision mediump int;

layout(set = 0, binding = 0) uniform sampler2D uTex;
layout(location = 0) in highp vec2 vUV;
layout(location = 0) out mediump vec4 oColor;

void main()
{
    oColor = textureLod(uTex, vUV, 0.0);
}