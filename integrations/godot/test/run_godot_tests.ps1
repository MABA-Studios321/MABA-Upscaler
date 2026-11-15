# Runs the Godot-side checks of MABA Upscaler on a scratch project: the headless controller and
# jitter self-test, and (with -Render) the render test, which needs a GPU and opens a window.
#
#   powershell -ExecutionPolicy Bypass -File integrations\godot\test\run_godot_tests.ps1 -Godot D:\Tools\godot47\Godot_v4.7-stable_win64_console.exe [-Render] [-Moving] [-Tune] [-Save] [-Debug]
param(
    [string]$Godot = $env:GODOT,
    [switch]$Render, [switch]$Moving, [switch]$Debug, [switch]$Save, [switch]$Tune, [int]$TimeoutSeconds = 240, [int]$Retries = 3,
    [string]$Project = (Join-Path ([IO.Path]::GetTempPath()) "maba_godot_test_project")
)
$ErrorActionPreference = "Stop"
if (-not $Godot -or -not (Test-Path $Godot)) { throw "Pass -Godot <path to a Godot 4 console executable> (or set GODOT)." }
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$addon = Join-Path (Split-Path -Parent $here) "addons\maba_upscaler"

if (Test-Path $Project) { Remove-Item -Recurse -Force $Project }
New-Item -ItemType Directory -Force "$Project\addons" | Out-Null
Copy-Item $addon "$Project\addons\maba_upscaler" -Recurse
Copy-Item (Join-Path $here "render_test.gd") $Project
Set-Content "$Project\render_test.tscn" "[gd_scene load_steps=2 format=3]`n[ext_resource type=`"Script`" path=`"res://render_test.gd`" id=`"1`"]`n[node name=`"Root`" type=`"Node3D`"]`nscript = ExtResource(`"1`")" -Encoding ASCII
Set-Content "$Project\project.godot" "config_version=5`n[application]`nconfig/name=`"maba_godot_test`"`n[rendering]`nrenderer/rendering_method=`"forward_plus`"" -Encoding ASCII

# Godot writes warnings to stderr; do not let PowerShell turn those into terminating errors.
$ErrorActionPreference = "Continue"
& $Godot --headless --path $Project --import 2>&1 | Out-Null
# The self-test quits itself; a script error leaves Godot idle forever, so give it a watchdog.
$ctOut = Join-Path $Project "controller_out.txt"
$ct = Start-Process -FilePath $Godot -ArgumentList @("--headless", "--path", $Project, "--script", "res://addons/maba_upscaler/test_controller.gd") -RedirectStandardOutput $ctOut -RedirectStandardError "$ctOut.err" -PassThru -WindowStyle Hidden
if (-not $ct.WaitForExit(120000)) { $ct.Kill(); Write-Host "controller test timed out (a script error leaves Godot idle):" }
$out = ((Get-Content $ctOut -ErrorAction SilentlyContinue) + (Get-Content "$ctOut.err" -ErrorAction SilentlyContinue)) -join "`n"
Write-Host $out
if ($out -notmatch "ALL GODOT CONTROLLER TESTS PASSED") { throw "Godot controller tests failed" }

if ($Render) {
    $userArgs = @()
    if ($Moving -or $Debug -or $Save -or $Tune) { $userArgs += "--" }
    if ($Tune) { $userArgs += "--tune" }
    if ($Save) { $userArgs += "--save" }
    if ($Debug) { $userArgs += "--debug" }
    if ($Moving) { $userArgs += "--moving" }
    # Hard timeout and retry: on the author's machine Godot 4.7 now and then deadlocks at startup
    # (0% CPU, right after loading its own shader cache, before any addon code runs). A stuck run must
    # not hang the test forever, so it is killed and tried again.
    $outFile = Join-Path $Project "render_out.txt"
    $argList = @("--path", $Project, "--rendering-driver", "vulkan", "--resolution", "800x450", "res://render_test.tscn") + $userArgs
    $renderOut = ""
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        $proc = Start-Process -FilePath $Godot -ArgumentList $argList -RedirectStandardOutput $outFile -RedirectStandardError "$outFile.err" -PassThru -WindowStyle Normal
        $finished = $proc.WaitForExit($TimeoutSeconds * 1000)
        if (-not $finished) { $proc.Kill(); Write-Host "RENDER attempt $attempt timed out after $TimeoutSeconds s (process killed)" }
        $renderOut = ((Get-Content $outFile -ErrorAction SilentlyContinue) + (Get-Content "$outFile.err" -ErrorAction SilentlyContinue)) -join "`n"
        if ($finished -and $renderOut -match "RENDER done") { break }
    }    $renderOut -split "`n" | Where-Object { $_ -match "RENDER|MABADBG|ERROR|SCRIPT" } | ForEach-Object { Write-Host $_.TrimEnd() }
}
