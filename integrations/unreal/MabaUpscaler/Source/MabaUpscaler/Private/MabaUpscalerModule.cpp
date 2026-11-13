// MABA Upscaler module: registers the view extension and drives r.ScreenPercentage from the
// real C controller (maba_upscaler.h, synced into this plugin as MabaController.h).
// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
#include "MabaUpscalerModule.h"
#include "MabaViewExtension.h"
#include "MabaController.h"
#include "HAL/IConsoleManager.h"
#include "Containers/Ticker.h"
#include "Engine/Engine.h"
#include "Interfaces/IPluginManager.h"
#include "Misc/CoreDelegates.h"
#include "Misc/Paths.h"
#include "ShaderCore.h"

namespace
{
	TAutoConsoleVariable<bool> CVarEnable(
		TEXT("r.Maba.Enable"), true,
		TEXT("MABA Upscaler: upscale the tonemapped scene from render resolution to output."));
	TAutoConsoleVariable<int32> CVarMode(
		TEXT("r.Maba.Mode"), 0,
		TEXT("0 Dynamic, 1 Ultra Quality (0.77), 2 Quality (0.67), 3 Balanced (0.59), 4 Performance (0.50)"));
	TAutoConsoleVariable<float> CVarSharpness(
		TEXT("r.Maba.Sharpness"), 0.5f,
		TEXT("MABA sharpening strength, 0..1."));
	TAutoConsoleVariable<float> CVarTargetFps(
		TEXT("r.Maba.TargetFps"), 60.0f,
		TEXT("Frame rate the Dynamic mode holds."));

	MabaUpscaler GController;
	bool GControllerInit = false;
	float GAppliedTargetFps = 0.0f;
	float GAppliedScreenPct = -1.0f;   // last value this plugin wrote to r.ScreenPercentage
	bool GActive = false;              // true while this plugin owns r.ScreenPercentage
	TSharedPtr<FMabaViewExtension, ESPMode::ThreadSafe> GViewExtension;
	FTSTicker::FDelegateHandle GTickerHandle;
	FDelegateHandle GPostEngineInitHandle;

	void SetScreenPercentage(float Percent)
	{
		if (Percent == GAppliedScreenPct)
		{
			return;
		}
		if (IConsoleVariable* ScreenPct = IConsoleManager::Get().FindConsoleVariable(TEXT("r.ScreenPercentage")))
		{
			ScreenPct->Set(Percent, ECVF_SetByCode);
			GAppliedScreenPct = Percent;
		}
	}

	void TickController(float DeltaSeconds)
	{
		if (!CVarEnable.GetValueOnGameThread())
		{
			FMabaViewExtension::bEnabled = false;
			if (GActive)
			{
				// Hand the resolution back: without the upscale pass a lowered screen
				// percentage would just be a blurry engine upscale.
				SetScreenPercentage(100.0f);
				GActive = false;
				GAppliedScreenPct = -1.0f;
			}
			return;
		}

		const float TargetFps = CVarTargetFps.GetValueOnGameThread();
		if (!GControllerInit)
		{
			MabaInit(&GController, MABA_MODE_DYNAMIC, TargetFps);
			GAppliedTargetFps = TargetFps;
			GControllerInit = true;
		}

		const int32 Mode = FMath::Clamp(CVarMode.GetValueOnGameThread(), 0, 4);
		int Rung;
		if (Mode == 0)
		{
			// MabaSetTargetFps resets the controller's counters, so only call it when the
			// budget really changed; calling it every tick would freeze Dynamic mode.
			if (TargetFps != GAppliedTargetFps)
			{
				MabaSetTargetFps(&GController, TargetFps);
				GAppliedTargetFps = TargetFps;
			}
			// Present-to-present timing. UE's own GPU profiling can replace this later; the
			// hysteresis controller still settles correctly, it just learns by missing frames.
			MabaUpdateDynamic(&GController, DeltaSeconds * 1000.0f);
			Rung = GController.rung;
		}
		else
		{
			Rung = MabaModeRung((MabaMode)Mode);
		}

		FMabaViewExtension::bQualityShader = MabaRungQuality(Rung) != 0;
		FMabaViewExtension::Sharpness = FMath::Clamp(CVarSharpness.GetValueOnGameThread(), 0.0f, 1.0f);
		FMabaViewExtension::bEnabled = true;
		GActive = true;
		SetScreenPercentage(MabaRungScale(Rung) * 100.0f);
	}

	void RegisterViewExtension()
	{
		if (!GViewExtension.IsValid() && GEngine)
		{
			GViewExtension = FSceneViewExtensions::NewExtension<FMabaViewExtension>();
		}
	}
}

void FMabaUpscalerModule::StartupModule()
{
	// The shader directory must be mapped before global shaders compile (PostConfigInit).
	const TSharedPtr<IPlugin> Plugin = IPluginManager::Get().FindPlugin(TEXT("MabaUpscaler"));
	if (Plugin.IsValid())
	{
		AddShaderSourceDirectoryMapping(TEXT("/Plugin/MabaUpscaler"),
			FPaths::Combine(Plugin->GetBaseDir(), TEXT("Shaders")));
	}

	// View extensions register with GEngine, which does not exist yet at PostConfigInit.
	if (GEngine)
	{
		RegisterViewExtension();
	}
	else
	{
		GPostEngineInitHandle = FCoreDelegates::OnPostEngineInit.AddStatic(&RegisterViewExtension);
	}

	GTickerHandle = FTSTicker::GetCoreTicker().AddTicker(FTickerDelegate::CreateLambda([](float DeltaSeconds)
	{
		TickController(DeltaSeconds);
		return true;
	}), 0.0f);
}

void FMabaUpscalerModule::ShutdownModule()
{
	FTSTicker::GetCoreTicker().RemoveTicker(GTickerHandle);
	GTickerHandle.Reset();
	FCoreDelegates::OnPostEngineInit.Remove(GPostEngineInitHandle);
	GPostEngineInitHandle.Reset();
	FMabaViewExtension::bEnabled = false;
	GViewExtension.Reset();
}

IMPLEMENT_MODULE(FMabaUpscalerModule, MabaUpscaler)
