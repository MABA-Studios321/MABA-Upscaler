// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
#include "MabaViewExtension.h"
#include "RenderGraphBuilder.h"
#include "PixelShaderUtils.h"
#include "SceneRendering.h"
#include "Runtime/Launch/Resources/Version.h"

IMPLEMENT_GLOBAL_SHADER(FMabaUpscalePS, "/Plugin/MabaUpscaler/MabaUpscale.usf", "MainPS", SF_Pixel);

bool FMabaViewExtension::bEnabled = true;
bool FMabaViewExtension::bQualityShader = true;
float FMabaViewExtension::Sharpness = 0.5f;

FMabaViewExtension::FMabaViewExtension(const FAutoRegister& AutoRegister)
	: FSceneViewExtensionBase(AutoRegister)
{
}

#if MABA_UE_HAS_VIEW_IN_SUBSCRIBE
void FMabaViewExtension::SubscribeToPostProcessingPass(EPostProcessingPass PassId, const FSceneView& View,
	FAfterPassCallbackDelegateArray& InOutPassCallbacks, bool bIsPassEnabled)
#else
void FMabaViewExtension::SubscribeToPostProcessingPass(EPostProcessingPass PassId,
	FAfterPassCallbackDelegateArray& InOutPassCallbacks, bool bIsPassEnabled)
#endif
{
	// After tonemap: the input is finished LDR gamma-space color, which is MABA's contract.
	if (PassId == EPostProcessingPass::Tonemap && bIsPassEnabled && bEnabled)
	{
		InOutPassCallbacks.Add(FAfterPassCallbackDelegate::CreateRaw(this, &FMabaViewExtension::UpscalePass));
	}
}

namespace
{
	void AddMabaPass(FRDGBuilder& GraphBuilder, FGlobalShaderMap* ShaderMap, bool bQuality,
		const FScreenPassTexture& Input, const FScreenPassRenderTarget& Output, float Sharpness)
	{
		const FIntPoint RenderSize = Input.ViewRect.Size();
		const FIntPoint Extent = Input.Texture->Desc.Extent;
		const FIntPoint OutputSize = Output.ViewRect.Size();

		FMabaUpscalePS::FPermutationDomain Permutation;
		Permutation.Set<FMabaUpscalePS::FQualityDim>(bQuality);
		TShaderMapRef<FMabaUpscalePS> Shader(ShaderMap, Permutation);
		FMabaUpscalePS::FParameters* Params = GraphBuilder.AllocParameters<FMabaUpscalePS::FParameters>();
		Params->MabaInput = Input.Texture;
		Params->MabaInputSampler = TStaticSamplerState<SF_Bilinear, AM_Clamp, AM_Clamp, AM_Clamp>::GetRHI();
		// zw is 1 / ALLOCATED texture size: the scene color texture can be larger than the view.
		Params->MabaInputSize = FVector4f(RenderSize.X, RenderSize.Y, 1.0f / Extent.X, 1.0f / Extent.Y);
		Params->MabaParams = FVector4f(Sharpness, 0.0f, 0.0f, 0.0f);
		Params->MabaOutputRect = FVector4f(Output.ViewRect.Min.X, Output.ViewRect.Min.Y,
			1.0f / OutputSize.X, 1.0f / OutputSize.Y);
		Params->RenderTargets[0] = Output.GetRenderTargetBinding();

		FPixelShaderUtils::AddFullscreenPass(GraphBuilder, ShaderMap,
			RDG_EVENT_NAME("MABA Upscale %s %dx%d -> %dx%d", bQuality ? TEXT("Quality") : TEXT("Fast"),
				RenderSize.X, RenderSize.Y, OutputSize.X, OutputSize.Y),
			Shader, Params, Output.ViewRect);
	}
}

FScreenPassTexture FMabaViewExtension::UpscalePass(FRDGBuilder& GraphBuilder, const FSceneView& View,
	const FPostProcessMaterialInputs& Inputs)
{
#if ENGINE_MAJOR_VERSION > 5 || (ENGINE_MAJOR_VERSION == 5 && ENGINE_MINOR_VERSION >= 4)
	// 5.4+: inputs are texture slices.
	const FScreenPassTexture SceneColor = FScreenPassTexture::CopyFromSlice(GraphBuilder,
		Inputs.GetInput(EPostProcessMaterialInput::SceneColor));
#else
	const FScreenPassTexture SceneColor = Inputs.GetInput(EPostProcessMaterialInput::SceneColor);
#endif
	if (!SceneColor.IsValid())
	{
		return SceneColor;
	}

	// If the engine asked this pass to write a specific target (it is the last pass in the
	// chain), that target must be filled even when MABA has nothing to do.
	FScreenPassRenderTarget Output = Inputs.OverrideOutput;
	const FIntPoint RenderSize = SceneColor.ViewRect.Size();
	const FIntPoint OutputSize = Output.IsValid() ? Output.ViewRect.Size() : View.UnscaledViewRect.Size();

	// The MABA core reads an image region that starts at texel (0,0).
	const bool bCanUpscale = bEnabled
		&& SceneColor.ViewRect.Min == FIntPoint::ZeroValue
		&& RenderSize.X >= 2 && RenderSize.Y >= 2
		&& OutputSize.X > RenderSize.X && OutputSize.Y > RenderSize.Y;
	if (!bCanUpscale)
	{
		if (Output.IsValid())
		{
			// The post-process callback always receives the renderer's FViewInfo.
			check(View.bIsViewInfo);
			AddDrawTexturePass(GraphBuilder, static_cast<const FViewInfo&>(View), SceneColor, Output);
			return FScreenPassTexture(Output.Texture, Output.ViewRect);
		}
		return SceneColor;
	}

	RDG_EVENT_SCOPE(GraphBuilder, "MABA Upscaler");

	if (!Output.IsValid())
	{
		FRDGTextureDesc OutputDesc = SceneColor.Texture->Desc;
		OutputDesc.Reset();
		OutputDesc.Extent = OutputSize;
		OutputDesc.Flags &= ~TexCreate_UAV;
		OutputDesc.Flags |= TexCreate_RenderTargetable | TexCreate_ShaderResource;
		OutputDesc.ClearValue = FClearValueBinding(FLinearColor::Black);
		FRDGTextureRef OutputTexture = GraphBuilder.CreateTexture(OutputDesc, TEXT("MABA Upscaled"));
		Output = FScreenPassRenderTarget(OutputTexture, FIntRect(FIntPoint::ZeroValue, OutputSize),
			ERenderTargetLoadAction::ENoAction);
	}

	AddMabaPass(GraphBuilder, GetGlobalShaderMap(View.GetFeatureLevel()), bQualityShader,
		SceneColor, Output, Sharpness);

	return FScreenPassTexture(Output.Texture, Output.ViewRect);
}
