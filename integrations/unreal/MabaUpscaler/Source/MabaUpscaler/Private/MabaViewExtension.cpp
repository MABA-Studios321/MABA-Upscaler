// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
#include "MabaViewExtension.h"
#include "MabaTemporal.h"          // the real C header (maba_temporal.h), synced into this plugin
#include "RenderGraphBuilder.h"
#include "PixelShaderUtils.h"
#include "SceneRendering.h"
#include "SceneRenderTargetParameters.h"
#include "Runtime/Launch/Resources/Version.h"

IMPLEMENT_GLOBAL_SHADER(FMabaUpscalePS, "/Plugin/MabaUpscaler/MabaUpscale.usf", "MainPS", SF_Pixel);
IMPLEMENT_GLOBAL_SHADER(FMabaTemporalPS, "/Plugin/MabaUpscaler/MabaTemporal.usf", "MainPS", SF_Pixel);

bool FMabaViewExtension::bEnabled = true;
bool FMabaViewExtension::bQualityShader = true;
float FMabaViewExtension::Sharpness = 0.5f;
float FMabaViewExtension::RenderScale = 1.0f;
bool FMabaViewExtension::bTemporal = false;
bool FMabaViewExtension::bOverrideAntiAliasing = true;
float FMabaViewExtension::HistoryWeight = 0.9f;
float FMabaViewExtension::DepthTolerance = 0.01f;
float FMabaViewExtension::ClipGamma = 1.25f;
bool FMabaViewExtension::bTemporalRanLastFrame = false;
std::atomic<uint32> FMabaViewExtension::ResetToken{ 1 };

FMabaViewExtension::FMabaViewExtension(const FAutoRegister& AutoRegister)
	: FSceneViewExtensionBase(AutoRegister)
{
}

namespace
{
	bool IsTemporalAAMethod(EAntiAliasingMethod Method)
	{
		return Method == AAM_TemporalAA || Method == AAM_TSR;
	}

	// Views MABA leaves alone: captures, reflection probes and anything that is not a normal
	// scene view.
	bool IsAuxiliaryView(const FSceneView& View)
	{
		return View.bIsSceneCapture || View.bIsReflectionCapture || View.bIsPlanarReflection;
	}
}

void FMabaViewExtension::SetupView(FSceneViewFamily& InViewFamily, FSceneView& InView)
{
	// Nothing is upscaled at 100%: leave the project's own anti-aliasing alone.
	if (!bEnabled || RenderScale >= 0.999f || IsAuxiliaryView(InView))
	{
		return;
	}

	// MABA upscales AFTER the tonemapper. The engine's TAA / TSR would upscale before it (and
	// jitter the view themselves), so while MABA is rendering the view it is taken out of them.
	if (bOverrideAntiAliasing)
	{
		if (IsTemporalAAMethod(InView.AntiAliasingMethod))
		{
			InView.AntiAliasingMethod = AAM_None;
		}
		if (InView.PrimaryScreenPercentageMethod == EPrimaryScreenPercentageMethod::TemporalUpscale)
		{
			InView.PrimaryScreenPercentageMethod = EPrimaryScreenPercentageMethod::SpatialUpscale;
		}
	}

	// The temporal tier needs the SM5 scene textures (depth), a view state to key its history by,
	// and a view nobody else is already jittering.
	if (!bTemporal || InView.State == nullptr || InView.GetFeatureLevel() < ERHIFeatureLevel::SM5
		|| IsTemporalAAMethod(InView.AntiAliasingMethod)
		|| !InView.ViewMatrices.GetTemporalAAJitter().IsZero())
	{
		return;
	}

	if (JitterPhase.Num() > 64)
	{
		JitterPhase.Reset();   // views come and go in the editor; the phase is cosmetic
	}
	uint32& Phase = JitterPhase.FindOrAdd(InView.State);
	// Halton(2,3), 16 phases, centred to [-0.5, 0.5] render texel (maba_temporal.h).
	const float JitterX = MabaHalton((int)Phase + 1, 2) - 0.5f;
	const float JitterY = MabaHalton((int)Phase + 1, 3) - 0.5f;
	Phase = (Phase + 1) % MABA_TEMPORAL_PHASES;

	// The render size is not final yet (the screen percentage is applied later): predict it from
	// the scale this plugin set. A one-pixel error changes the jitter by well under 0.1%.
	const float RenderW = FMath::Max(2.0f, FMath::CeilToFloat(InView.UnscaledViewRect.Width() * RenderScale));
	const float RenderH = FMath::Max(2.0f, FMath::CeilToFloat(InView.UnscaledViewRect.Height() * RenderScale));
	// Content moves BY (+JitterX, +JitterY) texels, y down (the engine's own TAA uses the same
	// convention: x * 2 / width, y * -2 / height in NDC).
	InView.ViewMatrices.HackAddTemporalAAProjectionJitter(
		FVector2D(JitterX * 2.0 / RenderW, -JitterY * 2.0 / RenderH));
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
#if MABA_UE_HAS_VIEW_IN_SUBSCRIBE
		// At 100% (the controller reached native) there is nothing to upscale. Not subscribing
		// also spares the full-screen copy the engine would otherwise require from this pass when
		// it is the last one in the chain. (Before UE 5.5 the hook has no view, so there the pass
		// subscribes and UpscalePass copies at native.)
		// The scaled view rectangle lives on the renderer's FViewInfo, not on FSceneView.
		if (View.bIsViewInfo)
		{
			const FIntRect& RenderRect = static_cast<const FViewInfo&>(View).ViewRect;
			if (RenderRect.Width() >= View.UnscaledViewRect.Width()
				&& RenderRect.Height() >= View.UnscaledViewRect.Height())
			{
				return;
			}
		}
#endif
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

	// MABA-Upscaler 2 (Temporal) resolve at render resolution. Returns the resolved colour (same
	// extent as the scene colour, valid in the render-size region) and refreshes the history.
	FScreenPassTexture AddMabaTemporalPass(FRDGBuilder& GraphBuilder, FGlobalShaderMap* ShaderMap,
		const FSceneView& View, const FScreenPassTexture& SceneColor, FRDGTextureRef SceneDepth,
		FMabaTemporalHistory& History, const FVector2D& JitterNdc,
		float HistoryWeight, float DepthTolerance, float ClipGamma)
	{
		const FIntPoint RenderSize = SceneColor.ViewRect.Size();
		const FIntPoint Extent = SceneColor.Texture->Desc.Extent;
		const uint32 Frame = View.Family ? View.Family->FrameNumber : 0u;

		// History is dropped on a camera cut, a render-size or texture change, or a gap in frames.
		const bool bReset = View.bCameraCut || !History.bValid || !History.Color.IsValid()
			|| !History.Depth.IsValid() || History.Extent != Extent || History.RenderSize != RenderSize
			|| (Frame - History.LastFrame) > 2u
			|| History.SeenResetToken != FMabaViewExtension::ResetToken.load();

		FRDGTextureRef PrevColor = bReset ? SceneColor.Texture : GraphBuilder.RegisterExternalTexture(History.Color);
		FRDGTextureRef PrevDepth = bReset ? SceneDepth : GraphBuilder.RegisterExternalTexture(History.Depth);

		// Unjittered view-projection, in double precision. Reprojection uses one matrix that goes
		// straight from current clip space to previous clip space: the huge world offsets cancel
		// in double precision on the CPU instead of costing float precision on the GPU.
		const FMatrix CurViewProj = View.ViewMatrices.GetViewMatrix() * View.ViewMatrices.ComputeProjectionNoAAMatrix();
		const FMatrix CurToPrev = CurViewProj.Inverse() * History.PrevViewProj;

		FRDGTextureDesc ColorDesc = FRDGTextureDesc::Create2D(Extent, SceneColor.Texture->Desc.Format,
			FClearValueBinding::Black, TexCreate_RenderTargetable | TexCreate_ShaderResource);
		FRDGTextureDesc DepthDesc = FRDGTextureDesc::Create2D(Extent, PF_R32_FLOAT,
			FClearValueBinding::Black, TexCreate_RenderTargetable | TexCreate_ShaderResource);
		FRDGTextureRef Resolved = GraphBuilder.CreateTexture(ColorDesc, TEXT("MABA Temporal Resolve"));
		FRDGTextureRef ResolvedDepth = GraphBuilder.CreateTexture(DepthDesc, TEXT("MABA Temporal Depth"));

		FMabaTemporalPS::FParameters* Params = GraphBuilder.AllocParameters<FMabaTemporalPS::FParameters>();
		Params->MabaCurrent = SceneColor.Texture;
		Params->MabaHistory = PrevColor;
		Params->MabaDepth = SceneDepth;
		Params->MabaPrevDepth = PrevDepth;
		Params->MabaLinearSampler = TStaticSamplerState<SF_Bilinear, AM_Clamp, AM_Clamp, AM_Clamp>::GetRHI();
		Params->MabaPointSampler = TStaticSamplerState<SF_Point, AM_Clamp, AM_Clamp, AM_Clamp>::GetRHI();
		// UE matrices are row-vector (v * M); the shared HLSL core multiplies column vectors.
		Params->MabaInvViewProj = FMatrix44f(CurToPrev.GetTransposed());
		Params->MabaPrevViewProj = FMatrix44f::Identity;
		Params->MabaTParams = FVector4f(HistoryWeight, DepthTolerance, bReset ? 1.0f : 0.0f, ClipGamma);
		Params->MabaTexel = FVector4f(1.0f / Extent.X, 1.0f / Extent.Y, 0.0f, 0.0f);
		Params->MabaRegion = FVector4f(RenderSize.X, RenderSize.Y, 0.0f, 0.0f);
		// Engine NDC jitter back to texels: x * W / 2, and y flipped to screen rows (down).
		Params->MabaJitter = FVector4f(JitterNdc.X * RenderSize.X * 0.5, -JitterNdc.Y * RenderSize.Y * 0.5, 0.0f, 0.0f);
		Params->RenderTargets[0] = FRenderTargetBinding(Resolved, ERenderTargetLoadAction::ENoAction);
		Params->RenderTargets[1] = FRenderTargetBinding(ResolvedDepth, ERenderTargetLoadAction::ENoAction);

		TShaderMapRef<FMabaTemporalPS> Shader(ShaderMap);
		FPixelShaderUtils::AddFullscreenPass(GraphBuilder, ShaderMap,
			RDG_EVENT_NAME("MABA Temporal %dx%d%s", RenderSize.X, RenderSize.Y, bReset ? TEXT(" (reset)") : TEXT("")),
			Shader, Params, FIntRect(FIntPoint::ZeroValue, RenderSize));

		GraphBuilder.QueueTextureExtraction(Resolved, &History.Color);
		GraphBuilder.QueueTextureExtraction(ResolvedDepth, &History.Depth);
		History.Extent = Extent;
		History.RenderSize = RenderSize;
		History.PrevViewProj = CurViewProj;
		History.LastFrame = Frame;
		History.SeenResetToken = FMabaViewExtension::ResetToken.load();
		History.bValid = true;

		return FScreenPassTexture(Resolved, SceneColor.ViewRect);
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
		bTemporalRanLastFrame = false;
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

	FGlobalShaderMap* ShaderMap = GetGlobalShaderMap(View.GetFeatureLevel());

	// Temporal tier: only when SetupView jittered this view (so the resolve can undo the jitter),
	// the scene depth exists, and the view has a state to key the history by.
	FScreenPassTexture Source = SceneColor;
	const FVector2D JitterNdc = View.ViewMatrices.GetTemporalAAJitter();
	const bool bJittered = !JitterNdc.IsZero();
	const bool bHasDepth = Inputs.SceneTextures.SceneTextures.GetUniformBuffer() != nullptr;
	bool bRanTemporal = false;
	if (bTemporal && bJittered && bHasDepth && View.State != nullptr && View.GetFeatureLevel() >= ERHIFeatureLevel::SM5)
	{
		FRDGTextureRef SceneDepth = Inputs.SceneTextures.SceneTextures->GetParameters()->SceneDepthTexture;
		if (SceneDepth != nullptr)
		{
			TSharedPtr<FMabaTemporalHistory> History = Histories.FindOrAdd(View.State);
			if (!History.IsValid())
			{
				History = MakeShared<FMabaTemporalHistory>();
				Histories[View.State] = History;
			}
			Source = AddMabaTemporalPass(GraphBuilder, ShaderMap, View, SceneColor, SceneDepth, *History,
				JitterNdc, HistoryWeight, DepthTolerance, ClipGamma);
			bRanTemporal = true;

			// Forget views that stopped rendering (closed viewports, destroyed players).
			const uint32 Frame = View.Family ? View.Family->FrameNumber : 0u;
			for (auto It = Histories.CreateIterator(); It; ++It)
			{
				if (It.Value().IsValid() && (Frame - It.Value()->LastFrame) > 120u)
				{
					It.RemoveCurrent();
				}
			}
		}
	}
	bTemporalRanLastFrame = bRanTemporal;

	AddMabaPass(GraphBuilder, ShaderMap, bQualityShader, Source, Output, Sharpness);

	return FScreenPassTexture(Output.Texture, Output.ViewRect);
}
