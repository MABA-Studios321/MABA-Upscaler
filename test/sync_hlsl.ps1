# Syncs the canonical HLSL cores from src/ into the Unity package and the UE plugin.
# Run after editing src/maba_upscaler.hlsl or src/maba_temporal.hlsl.
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$unity = Join-Path $root "integrations\unity\com.maba.upscaler\Runtime\Resources\MabaShaders"
$ue = Join-Path $root "integrations\unreal\MabaUpscaler\Shaders"
New-Item -ItemType Directory -Force -Path $unity, $ue | Out-Null
Copy-Item (Join-Path $root "src\maba_upscaler.hlsl") (Join-Path $unity "MabaCore.hlsl") -Force
Copy-Item (Join-Path $root "src\maba_temporal.hlsl") (Join-Path $unity "MabaTemporalCore.hlsl") -Force
Copy-Item (Join-Path $root "src\maba_upscaler.hlsl") (Join-Path $ue "MabaCore.ush") -Force
Copy-Item (Join-Path $root "src\maba_temporal.hlsl") (Join-Path $ue "MabaTemporalCore.ush") -Force
# The FSR1-derived quality kernel ships in both plugins, so its licence notice must travel with
# them when they are copied on their own.
# $unity is <package>\Runtime\Resources\MabaShaders and $ue is <plugin>\Shaders.
foreach ($dst in @((Join-Path $unity "..\..\.."), (Join-Path $ue ".."))) {
    Copy-Item (Join-Path $root "NOTICE") (Join-Path $dst "NOTICE") -Force
    Copy-Item (Join-Path $root "THIRD_PARTY_NOTICES.md") (Join-Path $dst "THIRD_PARTY_NOTICES.md") -Force
}
# The UE plugin runs the real C controller header, not a port.
Copy-Item (Join-Path $root "src\maba_upscaler.h") (Join-Path $ue "..\Source\MabaUpscaler\Private\MabaController.h") -Force
"Synced HLSL cores and licence notices to Unity and Unreal, C controller header to Unreal."