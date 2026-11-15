# Builds and runs every host-side test, and the three-way controller parity check.
#
#   powershell -ExecutionPolicy Bypass -File test\run_host_tests.ps1
#
# Needs gcc on PATH. The Java and C# parity runners are skipped (and reported) when no JDK / dotnet
# is found. Exit code 0 only if everything that ran passed.
$ErrorActionPreference = "Continue"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$native = Join-Path $here "native"
$tmp = Join-Path $env:TEMP "maba_host_tests"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
New-Item -ItemType Directory -Force $tmp | Out-Null
$failed = 0
$skipped = @()

function Step($name, [scriptblock]$body) {
    $ok = $false
    try { $ok = & $body } catch { Write-Host "  error: $_" }
    if ($ok) { Write-Host ("PASS  {0}" -f $name) } else { Write-Host ("FAIL  {0}" -f $name); $script:failed++ }
}

$gcc = (Get-Command gcc -ErrorAction SilentlyContinue).Source
if (-not $gcc) { throw "gcc not found on PATH" }

# ---- C tests: each prints an "ALL ... PASSED" line and exits 0 ---------------------------------
# test_framegen is built for three render heights (1x, 2x, 3x the reference): the warp must give the
# same result on the same scene whatever the resolution.
$cases = @(
    @{ name = "test_controller"; exe = "test_controller"; defs = @() },
    @{ name = "test_temporal";   exe = "test_temporal";   defs = @() },
    @{ name = "test_framegen (render x1)"; exe = "test_framegen_x1"; defs = @("-DGRID_SCALE=1"); src = "test_framegen" },
    @{ name = "test_framegen (render x2)"; exe = "test_framegen_x2"; defs = @("-DGRID_SCALE=2"); src = "test_framegen" },
    @{ name = "test_framegen (render x3)"; exe = "test_framegen_x3"; defs = @("-DGRID_SCALE=3"); src = "test_framegen" }
)
foreach ($c in $cases) {
    $src = if ($c.src) { $c.src } else { $c.name }
    $exe = $c.exe
    $defs = $c.defs
    Step "C: $($c.name)" {
        & gcc -std=c99 -O2 -Wall -Wextra @defs -o "$tmp\$exe.exe" "$native\$src.c" -lm 2>&1 | ForEach-Object { Write-Host "  $_" }
        if ($LASTEXITCODE -ne 0) { return $false }
        $o = & "$tmp\$exe.exe" 2>&1
        $o | Where-Object { $_ -match 'FAIL' } | ForEach-Object { Write-Host "  $_" }
        return ($LASTEXITCODE -eq 0)
    }
}

# ---- Controller parity: the same 45,000-frame trace through C, Java and C# ---------------------
& "$tmp\test_controller.exe" trace | Out-File -Encoding ascii "$tmp\trace_c.txt"
Copy-Item "$tmp\trace_c.txt" "$native\trace_c.txt" -Force

$jdk = if ($env:JAVA_HOME -and (Test-Path "$env:JAVA_HOME\bin\javac.exe")) { $env:JAVA_HOME }
       elseif (Test-Path "C:\Program Files\Android\Android Studio\jbr\bin\javac.exe") { "C:\Program Files\Android\Android Studio\jbr" }
       else { $null }
if ($jdk) {
    Step "parity C == Java" {
        $src = Join-Path $here "android\src\com\maba\upscalertest"
        $out = Join-Path $tmp "java"
        New-Item -ItemType Directory -Force $out | Out-Null
        & "$jdk\bin\javac.exe" -nowarn -d $out "$src\DynController.java" "$src\MabaController.java" "$src\Parity.java" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { return $false }
        & "$jdk\bin\java.exe" -cp $out com.maba.upscalertest.Parity | Out-File -Encoding ascii "$tmp\trace_java.txt"
        Copy-Item "$tmp\trace_java.txt" "$native\trace_java.txt" -Force
        $d = Compare-Object (Get-Content "$tmp\trace_c.txt") (Get-Content "$tmp\trace_java.txt")
        if ($d) { Write-Host ("  {0} differing lines" -f @($d).Count) }
        return (-not $d)
    }
} else { $skipped += "parity C == Java (no JDK)" }

$dotnet = (Get-Command dotnet -ErrorAction SilentlyContinue).Source
if ($dotnet) {
    Step "parity C == C#" {
        & dotnet run --project "$native\parity_cs" 2>$null | Out-File -Encoding ascii "$tmp\trace_cs.txt"
        Copy-Item "$tmp\trace_cs.txt" "$native\trace_cs.txt" -Force
        $d = Compare-Object (Get-Content "$tmp\trace_c.txt") (Get-Content "$tmp\trace_cs.txt")
        if ($d) { Write-Host ("  {0} differing lines" -f @($d).Count) }
        return ((-not $d) -and ((Get-Content "$tmp\trace_cs.txt" | Measure-Object -Line).Lines -gt 1000))
    }
} else { $skipped += "parity C == C# (no dotnet)" }

# ---- Plugin copies must match their sources (HLSL cores, C headers, notices, READMEs) -----------
Step "plugins in sync with src/ (sync_hlsl.ps1 -Check)" {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here "sync_hlsl.ps1") -Check | Out-Host
    return ($LASTEXITCODE -eq 0)
}

""
if ($skipped.Count) { "Skipped: " + ($skipped -join "; ") }
if ($failed -eq 0) { "ALL HOST TESTS PASSED"; exit 0 } else { "$failed FAILED"; exit 1 }
