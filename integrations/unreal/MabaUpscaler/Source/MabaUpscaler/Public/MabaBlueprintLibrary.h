// MABA Upscaler - Blueprint / C++ control API.
// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
#pragma once

#include "CoreMinimal.h"
#include "Kismet/BlueprintFunctionLibrary.h"
#include "MabaSettings.h"
#include "MabaBlueprintLibrary.generated.h"

/** What MABA is doing right now (read-only). */
USTRUCT(BlueprintType)
struct MABAUPSCALER_API FMabaStatus
{
	GENERATED_BODY()

	/** False when MABA is switched off. */
	UPROPERTY(BlueprintReadOnly, Category = "MABA")
	bool bActive = false;

	UPROPERTY(BlueprintReadOnly, Category = "MABA")
	EMabaMode Mode = EMabaMode::Dynamic;

	/** Render scale in use, 0.35 .. 1.0 (1.0 = native, nothing upscaled). */
	UPROPERTY(BlueprintReadOnly, Category = "MABA")
	float RenderScale = 1.0f;

	/** Position on the 1% ladder, -15 .. 51. */
	UPROPERTY(BlueprintReadOnly, Category = "MABA")
	int32 Rung = 0;

	/** True when the 12-tap quality kernel is in use. */
	UPROPERTY(BlueprintReadOnly, Category = "MABA")
	bool bQualityKernel = false;

	/** The temporal tier was asked for. */
	UPROPERTY(BlueprintReadOnly, Category = "MABA")
	bool bTemporalRequested = false;

	/** The temporal resolve pass actually ran on the last frame. */
	UPROPERTY(BlueprintReadOnly, Category = "MABA")
	bool bTemporalRunning = false;
};

UCLASS()
class MABAUPSCALER_API UMabaBlueprintLibrary : public UBlueprintFunctionLibrary
{
	GENERATED_BODY()

public:
	/** Switch MABA on or off (r.Maba.Enable). */
	UFUNCTION(BlueprintCallable, Category = "MABA Upscaler")
	static void SetMabaEnabled(bool bEnabled);

	/** Choose Dynamic or one of the fixed presets (r.Maba.Mode). */
	UFUNCTION(BlueprintCallable, Category = "MABA Upscaler")
	static void SetMabaMode(EMabaMode Mode);

	/** Sharpening strength, 0..1 (r.Maba.Sharpness). */
	UFUNCTION(BlueprintCallable, Category = "MABA Upscaler")
	static void SetMabaSharpness(float Sharpness);

	/** Frame rate Dynamic mode holds (r.Maba.TargetFps). */
	UFUNCTION(BlueprintCallable, Category = "MABA Upscaler")
	static void SetMabaTargetFps(float TargetFps);

	/** Narrow Dynamic mode's render-scale range (r.Maba.MinScale / MaxScale). */
	UFUNCTION(BlueprintCallable, Category = "MABA Upscaler")
	static void SetMabaScaleRange(float MinScale, float MaxScale);

	/** Turn the temporal tier on or off (r.Maba.Temporal). */
	UFUNCTION(BlueprintCallable, Category = "MABA Upscaler")
	static void SetMabaTemporal(bool bTemporal);

	/**
	 * Drop the temporal history of every view (camera cut, teleport, level switch). The next frame
	 * starts fresh. Engine camera cuts (Sequencer, Set Game Camera Cut This Frame) already do this.
	 */
	UFUNCTION(BlueprintCallable, Category = "MABA Upscaler")
	static void ResetMabaHistory();

	/** Show or hide the on-screen stats line (r.Maba.ShowStats). */
	UFUNCTION(BlueprintCallable, Category = "MABA Upscaler")
	static void SetMabaShowStats(bool bShow);

	/** Snapshot of what MABA did on the last game-thread tick. */
	UFUNCTION(BlueprintPure, Category = "MABA Upscaler")
	static FMabaStatus GetMabaStatus();
};
