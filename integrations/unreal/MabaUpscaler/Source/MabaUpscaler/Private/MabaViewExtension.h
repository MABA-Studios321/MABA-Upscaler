// MABA Upscaler - scene view extension: upscales the tonemapped scene color from render
// resolution (r.ScreenPercentage) to output resolution in one pixel-shader pass, optionally
// preceded by the MABA-Upscaler 2 (Temporal) resolve at render resolution.
// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
#pragma once

#include "CoreMinimal.h"
#include "GlobalShader.h"
#include "ShaderParameterStruct.h"
#include "SceneViewExtension.h"
#include "PostProcess/PostProcessMaterial.h"
#include "RenderGraphUtils.h"
#include "ScreenPass.h"
#include "Runtime/Launch/Resources/Version.h"
#include <atomic>

#define MABA_UE_HAS_VIEW_IN_SUBSCRIBE \
	(ENGINE_MAJOR_VERSION > 5 || (ENGINE_MAJOR_VERSION == 5 && ENGINE_MINOR_VERSION >= 5))

// One pixel shader, two builds: the fast build and the MABA_QUALITY (12-tap) build are a bool
// permutation, the standard UE way to compile a define both ways.
class FMabaUpscalePS : public FGlobalShader
{
public:
	DECLARE_GLOBAL_SHADER(FMabaUpscalePS)
	SHADER_USE_PARAMETER_STRUCT(FMabaUpscalePS, FGlobalShader)

	class FQualityDim : SHADER_PERMUTATION_BOOL("MABA_QUALITY");
	using FPermutationDomain = TShaderPermutationDomain<FQualityDim>;

	BEGIN_SHADER_PARAMETER_STRUCT(FParameters, )
		SHADER_PARAMETER_RDG_TEXTURE(Texture2D, MabaInput)
		SHADER_PARAMETER_SAMPLER(SamplerState, MabaInputSampler)
		SHADER_PARAMETER(FVector4f, MabaInputSize)    // xy = region size in texels, zw = 1 / texture extent
		SHADER_PARAMETER(FVector4f, MabaParams)       // x = sharpness
		SHADER_PARAMETER(FVector4f, MabaOutputRect)   // xy = output rect min in pixels, zw = 1 / output rect size
		RENDER_TARGET_BINDING_SLOTS()
	END_SHADER_PARAMETER_STRUCT()

	static bool ShouldCompilePermutation(const FGlobalShaderPermutationParameters& Parameters)
	{
		return IsFeatureLevelSupported(Parameters.Platform, ERHIFeatureLevel::ES3_1);
	}
};

// The temporal resolve: colour + depth in, colour + depth out (the pair is next frame's history).
class FMabaTemporalPS : public FGlobalShader
{
public:
	DECLARE_GLOBAL_SHADER(FMabaTemporalPS)
	SHADER_USE_PARAMETER_STRUCT(FMabaTemporalPS, FGlobalShader)

	BEGIN_SHADER_PARAMETER_STRUCT(FParameters, )
		SHADER_PARAMETER_RDG_TEXTURE(Texture2D, MabaCurrent)
		SHADER_PARAMETER_RDG_TEXTURE(Texture2D, MabaHistory)
		SHADER_PARAMETER_RDG_TEXTURE(Texture2D, MabaDepth)
		SHADER_PARAMETER_RDG_TEXTURE(Texture2D, MabaPrevDepth)
		SHADER_PARAMETER_SAMPLER(SamplerState, MabaLinearSampler)
		SHADER_PARAMETER_SAMPLER(SamplerState, MabaPointSampler)
		SHADER_PARAMETER(FMatrix44f, MabaInvViewProj)
		SHADER_PARAMETER(FMatrix44f, MabaPrevViewProj)
		SHADER_PARAMETER(FVector4f, MabaTParams)
		SHADER_PARAMETER(FVector4f, MabaTexel)
		SHADER_PARAMETER(FVector4f, MabaRegion)
		SHADER_PARAMETER(FVector4f, MabaJitter)
		RENDER_TARGET_BINDING_SLOTS()
	END_SHADER_PARAMETER_STRUCT()

	static bool ShouldCompilePermutation(const FGlobalShaderPermutationParameters& Parameters)
	{
		return IsFeatureLevelSupported(Parameters.Platform, ERHIFeatureLevel::SM5);
	}
};

// What the temporal tier keeps between frames for one view (render thread only).
struct FMabaTemporalHistory
{
	TRefCountPtr<IPooledRenderTarget> Color;   // last resolve, render-resolution region of a scene-colour-sized texture
	TRefCountPtr<IPooledRenderTarget> Depth;   // last scene depth, R32F
	FIntPoint Extent = FIntPoint::ZeroValue;   // allocated size of Color / Depth
	FIntPoint RenderSize = FIntPoint::ZeroValue;
	FMatrix PrevViewProj = FMatrix::Identity;  // last frame's UNJITTERED view-projection (double precision)
	uint32 LastFrame = 0;
	uint32 SeenResetToken = 0;                 // the FMabaViewExtension::ResetToken this history last honoured
	bool bValid = false;
};

class FMabaViewExtension : public FSceneViewExtensionBase
{
public:
	FMabaViewExtension(const FAutoRegister& AutoRegister);

	virtual void SetupViewFamily(FSceneViewFamily& InViewFamily) override {}
	// Game thread: applies the temporal tier's projection jitter (and, when the tier or the
	// spatial upscaler is on, takes the view out of the engine's own TAA / TSR).
	virtual void SetupView(FSceneViewFamily& InViewFamily, FSceneView& InView) override;
	virtual void BeginRenderViewFamily(FSceneViewFamily& InViewFamily) override {}

	// The FSceneView parameter was added to this hook in UE 5.5.
#if MABA_UE_HAS_VIEW_IN_SUBSCRIBE
	virtual void SubscribeToPostProcessingPass(EPostProcessingPass PassId, const FSceneView& View,
		FAfterPassCallbackDelegateArray& InOutPassCallbacks, bool bIsPassEnabled) override;
#else
	virtual void SubscribeToPostProcessingPass(EPostProcessingPass PassId,
		FAfterPassCallbackDelegateArray& InOutPassCallbacks, bool bIsPassEnabled) override;
#endif

	FScreenPassTexture UpscalePass(FRDGBuilder& GraphBuilder, const FSceneView& View,
		const FPostProcessMaterialInputs& Inputs);

	// Game-thread settings, read on the render thread. Plain scalars: a one-frame-stale read
	// is harmless.
	static bool bEnabled;
	static bool bQualityShader;   // quality (12-tap) build for the current rung
	static float Sharpness;
	static float RenderScale;     // r.ScreenPercentage / 100 as last set by this plugin (game thread)

	// Temporal tier.
	static bool bTemporal;
	static bool bOverrideAntiAliasing;   // take TAA / TSR off views MABA renders
	static float HistoryWeight;
	static float DepthTolerance;
	static float ClipGamma;
	// Last frame's outcome, for the stats overlay and Blueprint (render thread writes).
	static bool bTemporalRanLastFrame;
	// Bumped by ResetMabaHistory(): every view drops its history the next time it renders (game thread
	// writes, render thread reads; a stale read only delays the reset by a frame).
	static std::atomic<uint32> ResetToken;

private:
	TMap<const void*, TSharedPtr<FMabaTemporalHistory>> Histories;   // render thread
	TMap<const void*, uint32> JitterPhase;                           // game thread
};
