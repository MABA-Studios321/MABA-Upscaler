// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
#pragma once

#include "CoreMinimal.h"
#include "Modules/ModuleManager.h"

class FMabaUpscalerModule : public IModuleInterface
{
public:
	virtual void StartupModule() override;
	virtual void ShutdownModule() override;
};