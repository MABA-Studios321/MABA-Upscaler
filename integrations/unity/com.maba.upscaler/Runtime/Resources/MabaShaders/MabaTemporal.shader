// MABA-Upscaler 2 (Temporal) - Unity resolve pass, run at render resolution.
// _Depth / _PrevDepth are the GL-convention depth copies written by MABA/DepthCopy.
// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
Shader "MABA/Temporal"
{
    SubShader
    {
        Cull Off ZTest Always ZWrite Off

        Pass
        {
            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag
            #pragma target 3.5
            #include "MabaTemporalCore.hlsl"

            Texture2D _MabaInput;
            Texture2D _History;
            Texture2D _Depth;
            Texture2D _PrevDepth;
            SamplerState sampler_LinearClamp;
            SamplerState sampler_PointClamp;
            float4x4 _InvVP;
            float4x4 _PrevVP;
            float4 _TParams;
            float4 _Texel;
            float4 _Region;

            float4 Vert(uint id : SV_VertexID) : SV_Position
            {
                float2 p = float2((id << 1) & 2, id & 2);
                return float4(p * 2.0 - 1.0, 0.0, 1.0);
            }

            float4 Frag(float4 pos : SV_Position) : SV_Target
            {
                return MabaTemporalResolve(_MabaInput, _History, _Depth, _PrevDepth,
                    sampler_LinearClamp, sampler_PointClamp, pos.xy, _InvVP, _PrevVP,
                    _TParams, _Texel.xy, _Region.xy);
            }
            ENDHLSL
        }
    }
}
