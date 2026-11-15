# Syncs the canonical sources from src/ (and the plugin READMEs from integrations/) into the Unity
# package, the UE plugin and the Godot addon, so each plugin folder is self-contained when copied
# on its own.
#
#   powershell -ExecutionPolicy Bypass -File test\sync_hlsl.ps1           copy everything
#   powershell -ExecutionPolicy Bypass -File test\sync_hlsl.ps1 -Check    only compare; exit 1 if any copy differs
#
# Run it after editing src/maba_upscaler.hlsl, src/maba_temporal.hlsl, src/maba_upscaler.h,
# src/maba_temporal.h, NOTICE, THIRD_PARTY_NOTICES.md or a plugin README.
# (The Godot shaders and the C# controller / jitter ports are hand ports, not copies: they are
# covered by the host parity tests and test\run_godot_tests.ps1.)
param([switch]$Check)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$unityPkg = Join-Path $root "integrations\unity\com.maba.upscaler"
$unity = Join-Path $unityPkg "Runtime\Resources\MabaShaders"
$uePlugin = Join-Path $root "integrations\unreal\MabaUpscaler"
$ue = Join-Path $uePlugin "Shaders"
$ueSrc = Join-Path $uePlugin "Source\MabaUpscaler\Private"
$godot = Join-Path $root "integrations\godot\addons\maba_upscaler"

function P($rel) { Join-Path $root $rel }
# (source, destination) pairs. A destination is a verbatim copy of its source.
$pairs = @(
    @((P "src\maba_upscaler.hlsl"), (Join-Path $unity "MabaCore.hlsl")),
    @((P "src\maba_temporal.hlsl"), (Join-Path $unity "MabaTemporalCore.hlsl")),
    @((P "src\maba_upscaler.hlsl"), (Join-Path $ue "MabaCore.ush")),
    @((P "src\maba_temporal.hlsl"), (Join-Path $ue "MabaTemporalCore.ush")),
    # The UE plugin runs the real C controller and jitter headers, not ports.
    @((P "src\maba_upscaler.h"), (Join-Path $ueSrc "MabaController.h")),
    @((P "src\maba_temporal.h"), (Join-Path $ueSrc "MabaTemporal.h")),
    # The FSR1-derived quality kernel ships in the Unity and UE plugins, so its licence notice
    # must travel with them. (The Godot addon has its own, shorter notices file.)
    @((P "NOTICE"), (Join-Path $unityPkg "NOTICE")),
    @((P "THIRD_PARTY_NOTICES.md"), (Join-Path $unityPkg "THIRD_PARTY_NOTICES.md")),
    @((P "NOTICE"), (Join-Path $uePlugin "NOTICE")),
    @((P "THIRD_PARTY_NOTICES.md"), (Join-Path $uePlugin "THIRD_PARTY_NOTICES.md")),
    # Each plugin folder carries its own README (the one in integrations/<engine>/ is the source).
    @((P "integrations\unity\README.md"), (Join-Path $unityPkg "README.md")),
    @((P "integrations\unreal\README.md"), (Join-Path $uePlugin "README.md")),
    @((P "integrations\godot\README.md"), (Join-Path $godot "README.md"))
)

$stale = 0
foreach ($p in $pairs) {
    $src = $p[0]; $dst = $p[1]
    if (-not (Test-Path $src)) { throw "missing source: $src" }
    $same = (Test-Path $dst) -and ((Get-FileHash $src -Algorithm SHA256).Hash -eq (Get-FileHash $dst -Algorithm SHA256).Hash)
    if ($Check) {
        if (-not $same) { Write-Host "DIFFERS  $($dst.Substring($root.Length + 1))" -ForegroundColor Red; $stale++ }
    } else {
        New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
        if (-not $same) { Copy-Item $src $dst -Force; Write-Host "updated  $($dst.Substring($root.Length + 1))" }
    }
}
if ($Check) {
    if ($stale -gt 0) { Write-Host "$stale plugin file(s) are out of sync with their source. Run test\sync_hlsl.ps1." -ForegroundColor Red; exit 1 }
    Write-Host "All $($pairs.Count) synced plugin files match their sources." -ForegroundColor Green
} else {
    Write-Host "Synced $($pairs.Count) files (HLSL cores, C headers, notices, READMEs) into the Unity, Unreal and Godot plugin folders."
}
