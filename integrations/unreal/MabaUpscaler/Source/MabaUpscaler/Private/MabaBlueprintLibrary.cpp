// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
#include "MabaBlueprintLibrary.h"
#include "MabaUpscalerModule.h"
#include "MabaViewExtension.h"
#include "HAL/IConsoleManager.h"

namespace
{
	// Code priority: wins over Project Settings and the ini, loses only to the console and the
	// command line, like any other engine setting made from code.
	template <typename T>
	void Set(const TCHAR* Name, T Value)
	{
		if (IConsoleVariable* CVar = IConsoleManager::Get().FindConsoleVariable(Name))
		{
			CVar->Set(Value, ECVF_SetByCode);
		}
	}
}

void UMabaBlueprintLibrary::SetMabaEnabled(bool bEnabled) { Set(TEXT("r.Maba.Enable"), bEnabled ? 1 : 0); }
void UMabaBlueprintLibrary::SetMabaMode(EMabaMode Mode) { Set(TEXT("r.Maba.Mode"), static_cast<int32>(Mode)); }
void UMabaBlueprintLibrary::SetMabaSharpness(float Sharpness) { Set(TEXT("r.Maba.Sharpness"), FMath::Clamp(Sharpness, 0.0f, 1.0f)); }
void UMabaBlueprintLibrary::SetMabaTargetFps(float TargetFps) { Set(TEXT("r.Maba.TargetFps"), FMath::Clamp(TargetFps, 15.0f, 240.0f)); }
void UMabaBlueprintLibrary::SetMabaTemporal(bool bTemporal) { Set(TEXT("r.Maba.Temporal"), bTemporal ? 1 : 0); }
void UMabaBlueprintLibrary::SetMabaShowStats(bool bShow) { Set(TEXT("r.Maba.ShowStats"), bShow ? 1 : 0); }

void UMabaBlueprintLibrary::ResetMabaHistory()
{
	FMabaViewExtension::ResetToken.fetch_add(1);
}

void UMabaBlueprintLibrary::SetMabaScaleRange(float MinScale, float MaxScale)
{
	MinScale = FMath::Clamp(MinScale, 0.35f, 1.0f);
	MaxScale = FMath::Clamp(MaxScale, MinScale, 1.0f);
	Set(TEXT("r.Maba.MinScale"), MinScale);
	Set(TEXT("r.Maba.MaxScale"), MaxScale);
}

FMabaStatus UMabaBlueprintLibrary::GetMabaStatus()
{
	const FMabaUpscalerModule::FStatus S = FMabaUpscalerModule::GetStatus();
	FMabaStatus Result;
	Result.bActive = S.bActive;
	Result.Mode = static_cast<EMabaMode>(FMath::Clamp(S.Mode, 0, 4));
	Result.RenderScale = S.Scale;
	Result.Rung = S.Rung;
	Result.bQualityKernel = S.bQualityShader;
	Result.bTemporalRequested = S.bTemporalRequested;
	Result.bTemporalRunning = S.bTemporalRunning;
	return Result;
}
