# Compile-checks every MABA shader with the NDK glslc: the GLSL builds (GLES / Vulkan), the test
# app shaders, the Godot RenderingDevice shaders, and the HLSL cores as used by Unity and Unreal
# (via glslc's HLSL front end; fxc is not needed).
# Usage: powershell -ExecutionPolicy Bypass -File test\compile_shaders.ps1 [-NdkVersion 30.0.14904198]
param(
    [string]$NdkVersion = "",
    [string]$SdkRoot = $(if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { "$env:LOCALAPPDATA\Android\Sdk" })
)
$ErrorActionPreference = "Stop"
if (-not $NdkVersion) {
    $NdkVersion = (Get-ChildItem (Join-Path $SdkRoot "ndk") -Directory |
        Sort-Object { [version]$_.Name } | Select-Object -Last 1).Name
}
$glslc = Join-Path $SdkRoot "ndk\$NdkVersion\shader-tools\windows-x86_64\glslc.exe"
if (-not (Test-Path $glslc)) { throw "glslc not found at $glslc" }

$root = Split-Path $PSScriptRoot -Parent
$src = Join-Path $root "src"
$tmp = Join-Path $env:TEMP "maba-shader-check"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

function Read-Text($path) { [System.IO.File]::ReadAllText($path) }

$frag = Read-Text (Join-Path $src "maba_upscaler.frag.glsl")
$vert = Read-Text (Join-Path $src "maba_upscaler.vert.glsl")
$temporal = Read-Text (Join-Path $src "maba_temporal.frag.glsl")
$temporalSr = Read-Text (Join-Path $src "maba_temporal_sr.frag.glsl")

# ---- GLSL: the core shaders --------------------------------------------------------------------
# glslc cannot emit SPIR-V for "#version 300 es"; the ES 3.0 builds (MABA_GATHER 0, temporal) use
# only ES 3.0 core syntax, so they are validated as 310 es. The real ES 3.0 compile is on-device.
$variants = @(
    @{ Name = "es-vert";            Stage = "vert"; Header = "#version 310 es`n"; Env = "opengl"; Std = "310es"; Body = $vert },
    @{ Name = "vulkan-vert";        Stage = "vert"; Header = "#version 450`n#define MABA_VULKAN 1`n"; Env = "vulkan1.0"; Std = "450"; Body = $vert },
    @{ Name = "es31-fast";          Stage = "frag"; Header = "#version 310 es`n#define MABA_GATHER 1`n"; Env = "opengl"; Std = "310es"; Body = $frag },
    @{ Name = "es31-quality";       Stage = "frag"; Header = "#version 310 es`n#define MABA_GATHER 1`n#define MABA_QUALITY 1`n"; Env = "opengl"; Std = "310es"; Body = $frag },
    @{ Name = "es31-fast-highp";    Stage = "frag"; Header = "#version 310 es`n#define MABA_GATHER 1`n#define MABA_HIGHP 1`n"; Env = "opengl"; Std = "310es"; Body = $frag },
    @{ Name = "es31-quality-highp"; Stage = "frag"; Header = "#version 310 es`n#define MABA_GATHER 1`n#define MABA_QUALITY 1`n#define MABA_HIGHP 1`n"; Env = "opengl"; Std = "310es"; Body = $frag },
    @{ Name = "es30-fast";          Stage = "frag"; Header = "#version 310 es`n#define MABA_GATHER 0`n"; Env = "opengl"; Std = "310es"; Body = $frag },
    # Explicit 0 must select the GLES path (the switches are tested by value, not by #ifdef).
    @{ Name = "es31-vulkan0";       Stage = "frag"; Header = "#version 310 es`n#define MABA_VULKAN 0`n#define MABA_HIGHP 0`n"; Env = "opengl"; Std = "310es"; Body = $frag },
    @{ Name = "vulkan-fast";        Stage = "frag"; Header = "#version 450`n#define MABA_VULKAN 1`n#define MABA_GATHER 1`n"; Env = "vulkan1.0"; Std = "450"; Body = $frag },
    @{ Name = "vulkan-quality";     Stage = "frag"; Header = "#version 450`n#define MABA_VULKAN 1`n#define MABA_GATHER 1`n#define MABA_QUALITY 1`n"; Env = "vulkan1.0"; Std = "450"; Body = $frag },
    @{ Name = "es-temporal";        Stage = "frag"; Header = "#version 310 es`n"; Env = "opengl"; Std = "310es"; Body = $temporal },
    @{ Name = "vulkan-temporal";    Stage = "frag"; Header = "#version 450`n#define MABA_VULKAN 1`n"; Env = "vulkan1.0"; Std = "450"; Body = $temporal },
    # Per-object motion vectors and the Catmull-Rom history resample (GL only).
    @{ Name = "es-temporal-velocity"; Stage = "frag"; Header = "#version 310 es`n#define MABA_TEMPORAL_VELOCITY 1`n#define MABA_TEMPORAL_SHARP 1`n"; Env = "opengl"; Std = "310es"; Body = $temporal },
    # Temporal super-resolution: accumulates at output resolution (resolve pass + present pass).
    @{ Name = "es-temporal-sr";         Stage = "frag"; Header = "#version 310 es`n"; Env = "opengl"; Std = "310es"; Body = $temporalSr },
    @{ Name = "es-temporal-sr-present"; Stage = "frag"; Header = "#version 310 es`n#define MABA_TSR_PRESENT 1`n"; Env = "opengl"; Std = "310es"; Body = $temporalSr }
)

# ---- GLSL: test-app shaders (GLES only) --------------------------------------------------------
$appShaders = Join-Path $root "test\android\shaders"
foreach ($s in @(
        @{ Name = "app-scene3d-vert"; Stage = "vert"; File = "scene3d.vert.glsl" },
        @{ Name = "app-scene3d-frag"; Stage = "frag"; File = "scene3d.frag.glsl" },
        @{ Name = "app-bg";           Stage = "frag"; File = "bg.frag.glsl" },
        @{ Name = "app-pattern";      Stage = "frag"; File = "pattern.frag.glsl" },
        @{ Name = "app-blit";         Stage = "frag"; File = "blit.frag.glsl" })) {
    $variants += @{ Name = $s.Name; Stage = $s.Stage; Header = "#version 310 es`n"; Env = "opengl"; Std = "310es"
                    Body = (Read-Text (Join-Path $appShaders $s.File)) }
}

# ---- GLSL: MABA Frame Gen (warp passes) and the scene variants that write motion vectors -------
$framegen = Read-Text (Join-Path $src "maba_framegen.frag.glsl")
$variants += @{ Name = "framegen"; Stage = "frag"; Header = "#version 310 es`n"; Env = "opengl"; Std = "310es"; Body = $framegen }
# The developer / opt-in switches of the warp must keep compiling too.
$variants += @(
    @{ Name = "framegen-4taps";      Stage = "frag"; Header = "#version 310 es`n#define MABA_FG_PROBE_TAPS 4`n"; Env = "opengl"; Std = "310es"; Body = $framegen },
    @{ Name = "framegen-scale-all";  Stage = "frag"; Header = "#version 310 es`n#define MABA_FG_SCALE_MASK 7`n"; Env = "opengl"; Std = "310es"; Body = $framegen },
    @{ Name = "framegen-scale-none"; Stage = "frag"; Header = "#version 310 es`n#define MABA_FG_SCALE_MASK 0`n"; Env = "opengl"; Std = "310es"; Body = $framegen },
    @{ Name = "framegen-noedge";     Stage = "frag"; Header = "#version 310 es`n#define MABA_FG_NOEDGE 1`n"; Env = "opengl"; Std = "310es"; Body = $framegen }
)
$variants += @(
    @{ Name = "app-scene3d-vert-velocity"; Stage = "vert"; Header = "#version 310 es`n#define MABA_VELOCITY 1`n"; Env = "opengl"; Std = "310es"; Body = (Read-Text (Join-Path $root "test\android\shaders\scene3d.vert.glsl")) },
    @{ Name = "app-scene3d-frag-velocity"; Stage = "frag"; Header = "#version 310 es`n#define MABA_VELOCITY 1`n"; Env = "opengl"; Std = "310es"; Body = (Read-Text (Join-Path $root "test\android\shaders\scene3d.frag.glsl")) },
    @{ Name = "app-bg-velocity";           Stage = "frag"; Header = "#version 310 es`n#define MABA_VELOCITY 1`n"; Env = "opengl"; Std = "310es"; Body = (Read-Text (Join-Path $root "test\android\shaders\bg.frag.glsl")) }
)

# ---- GLSL: Godot RenderingDevice shaders (#[vertex] / #[fragment] sections) --------------------
$godot = Join-Path $root "integrations\godot\addons\maba_upscaler\shaders"
foreach ($g in @(
        @{ Name = "godot-upscaler-fast";    File = "maba_upscaler.glsl"; Quality = 0 },
        @{ Name = "godot-upscaler-quality"; File = "maba_upscaler.glsl"; Quality = 1 },
        @{ Name = "godot-blit";             File = "maba_blit.glsl";     Quality = -1 },
@{ Name = "godot-temporal";         File = "maba_temporal.glsl"; Quality = -1 })) {
    $text = (Read-Text (Join-Path $godot $g.File)).Replace("`r`n", "`n")
    $vi = $text.IndexOf("#[vertex]"); $fi = $text.IndexOf("#[fragment]")
    $vs = $text.Substring($vi + 9, $fi - ($vi + 9)).Trim()
    $fs = $text.Substring($fi + 11).Trim()
    # Godot replaces the VERSION_DEFINES token with the selected #[versions] entry at import time.
    $def = if ($g.Quality -ge 0) { "#define MABA_QUALITY $($g.Quality)" } else { "" }
    $fs = $fs.Replace("VERSION_DEFINES", $def)
    $variants += @{ Name = "$($g.Name)-vert"; Stage = "vert"; Header = ""; Env = "vulkan1.0"; Std = "450"; Body = $vs }
    $variants += @{ Name = "$($g.Name)-frag"; Stage = "frag"; Header = ""; Env = "vulkan1.0"; Std = "450"; Body = $fs }
}

# ---- HLSL: the engine cores, as Unity and Unreal use them ---------------------------------------
$hlslUpscaler = @'
#include "maba_upscaler.hlsl"
Texture2D T; SamplerState S; float4 Size; float4 P;
float4 Fast(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target { return MabaUpscaleFast(T, S, uv, Size, P); }
float4 Quality(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target { return MabaUpscaleQuality(T, S, uv, Size, P); }
float4 NoGather(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target { return MabaUpscaleFastNoGather(T, S, uv, Size, P); }
'@
$hlslNoGather = @'
#define MABA_NO_GATHER 1
#include "maba_upscaler.hlsl"
Texture2D T; SamplerState S; float4 Size; float4 P;
float4 NoGather(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target { return MabaUpscaleFastNoGather(T, S, uv, Size, P); }
'@
$hlslTemporal = @'
#include "maba_temporal.hlsl"
Texture2D A; Texture2D B; Texture2D C; Texture2D D; SamplerState L; SamplerState N;
float4x4 I; float4x4 Pv; float4 TP; float4 Tx; float4 Rg; float4 Jt;
float4 Frag(float4 pos : SV_Position) : SV_Target { return MabaTemporalResolve(A, B, C, D, L, N, pos.xy, I, Pv, TP, Tx.xy, Rg.xy, Jt.xy); }
'@
# Unreal's pixel shader with the engine include stubbed and the core include pointed at src/.
$usf = (Read-Text (Join-Path $root "integrations\unreal\MabaUpscaler\Shaders\MabaUpscale.usf")).
    Replace('#include "/Engine/Public/Platform.ush"', '').
    Replace('#include "/Plugin/MabaUpscaler/MabaCore.ush"', '#include "maba_upscaler.hlsl"')
$usfT = (Read-Text (Join-Path $root "integrations\unreal\MabaUpscaler\Shaders\MabaTemporal.usf")).
    Replace('#include "/Engine/Public/Platform.ush"', '').
    Replace('#include "/Plugin/MabaUpscaler/MabaTemporalCore.ush"', '#include "maba_temporal.hlsl"')
# The temporal core the way Unreal configures it (reversed-Z, y down, [0,1] NDC z).
$hlslTemporalUe = "#define MABA_VULKAN 1`n#define MABA_REVERSED_Z 1`n#define MABA_Y_DOWN 1`n" + $hlslTemporal
# Unity's depth copy pass body (between HLSLPROGRAM and ENDHLSL, pragmas removed).
$unityShaders = Join-Path $root "integrations\unity\com.maba.upscaler\Runtime\Resources\MabaShaders"
$dc = (Read-Text (Join-Path $unityShaders "MabaDepthCopy.shader")).Replace("`r`n", "`n")
$dcBody = ($dc.Substring($dc.IndexOf("HLSLPROGRAM") + 11, $dc.IndexOf("ENDHLSL") - $dc.IndexOf("HLSLPROGRAM") - 11) -split "`n" |
    Where-Object { $_ -notmatch '^\s*#pragma' }) -join "`n"

$variants += @(
    @{ Name = "hlsl-fast";        Hlsl = $true; Entry = "Fast";     Body = $hlslUpscaler },
    @{ Name = "hlsl-quality";     Hlsl = $true; Entry = "Quality";  Body = $hlslUpscaler },
    @{ Name = "hlsl-nogather";    Hlsl = $true; Entry = "NoGather"; Body = $hlslUpscaler },
    @{ Name = "hlsl-no-gather-1"; Hlsl = $true; Entry = "NoGather"; Body = $hlslNoGather },
    @{ Name = "hlsl-temporal";    Hlsl = $true; Entry = "Frag";     Body = $hlslTemporal },
    @{ Name = "hlsl-temporal-ue"; Hlsl = $true; Entry = "Frag";     Body = $hlslTemporalUe },
    @{ Name = "ue-temporal";      Hlsl = $true; Entry = "MainPS";   Body = $usfT },
    @{ Name = "ue-fast";          Hlsl = $true; Entry = "MainPS";   Body = "#define MABA_QUALITY 0`n" + $usf },
    @{ Name = "ue-quality";       Hlsl = $true; Entry = "MainPS";   Body = "#define MABA_QUALITY 1`n" + $usf },
    @{ Name = "unity-depthcopy";  Hlsl = $true; Entry = "Frag";     Body = $dcBody }
)

# ---- Compile ----------------------------------------------------------------------------------
$fail = 0
foreach ($v in $variants) {
    $ext = if ($v.Hlsl) { "hlsl" } else { "glsl" }
    $in = Join-Path $tmp ("$($v.Name).$ext")
    $out = Join-Path $tmp ("$($v.Name).spv")
    [System.IO.File]::WriteAllText($in, $(if ($v.Hlsl) { $v.Body } else { $v.Header + $v.Body }))
    if ($v.Hlsl) {
        $glslcArgs = @("-x", "hlsl", "-fshader-stage=frag", "-fentry-point=$($v.Entry)", "-fauto-bind-uniforms",
                  "-I", $src, "-o", $out, $in)
    } else {
        $glslcArgs = @("-x", "glsl", "-std=$($v.Std)", "--target-env=$($v.Env)", "-fshader-stage=$($v.Stage)")
        if ($v.Env -eq "opengl") { $glslcArgs += "-fauto-map-locations" }
        $glslcArgs += @("-o", $out, $in)
    }
    # glslc reports errors on stderr. Under Windows PowerShell 5.1 with "Stop", the first stderr
    # line would abort the whole script before the PASS/FAIL summary, so relax it for the call.
    $ErrorActionPreference = "Continue"
    $log = & $glslc @glslcArgs 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = "Stop"
    if ($code -eq 0) { Write-Host "PASS  $($v.Name)" -ForegroundColor Green }
    else {
        $log | ForEach-Object { Write-Host "      $_" }
        Write-Host "FAIL  $($v.Name)" -ForegroundColor Red
        $fail++
    }
}
if ($fail -gt 0) { throw "$fail of $($variants.Count) shader variant(s) failed to compile" }
Write-Host "All $($variants.Count) shader variants compiled." -ForegroundColor Green
