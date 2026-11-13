// fxc compile-check harness for the engine-neutral HLSL cores.
// Build: fxc /T ps_5_0 /E PSMain /nologo hlsl_check.hlsl
Texture2D t0 : register(t0);
Texture2D t1 : register(t1);
Texture2D t2 : register(t2);
Texture2D t3 : register(t3);
SamplerState s0 : register(s0);
SamplerState s1 : register(s1);

cbuffer Check : register(b0)
{
    float4 size;
    float4 params;
    float4 tparams;
    float2 texel;
    float2 region;
    float4x4 invVP;
    float4x4 prevVP;
};

#include "../../src/maba_upscaler.hlsl"
#include "../../src/maba_temporal.hlsl"

float4 PSMain(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target
{
    float4 a = MabaUpscaleFast(t0, s0, uv, size, params);
    float4 b = MabaUpscaleQuality(t0, s0, uv, size, params);
    float4 c = MabaUpscaleFastNoGather(t0, s0, uv, size, params);
    float4 d = MabaTemporalResolve(t0, t1, t2, t3, s0, s1, pos.xy, invVP, prevVP,
                                   tparams, texel, region);
    return a + b + c + d;
}