// MABA Upscaler - scene view extension: upscales the tonemapped scene color from render
// resolution (r.ScreenPercentage) to output resolution in one pixel-shader pass.
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

class FMabaViewExtension : public FSceneViewExtensionBase
{
public:
	FMabaViewExtension(const FAutoRegister& AutoRegister);

	virtual void SetupViewFamily(FSceneViewFamily& InViewFamily) override {}
	virtual void SetupView(FSceneViewFamily& InViewFamily, FSceneView& InView) override {}
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
};
