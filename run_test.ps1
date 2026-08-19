<#
.SYNOPSIS
    Host orchestrator for the medLLM CPU Docker stress test.
.DESCRIPTION
    Runs the full measurement sequence end-to-end:
      1. Preflight: check LibreHardwareMonitor API reachable.
      2. Clear outputs, start thermal collector + thermal governor (background jobs).
      3. Start a `docker stats` sampler (background job) for container RAM/CPU%.
      4. `docker run` the llm-cpu-test image with --memory=7g --cpus=4 --cpuset-cpus=0-3,
         mounting the user's Q4_K_M GGUF and an ./out volume for metrics.
      5. Wait for the container to finish (orchestrator's wait) or for the governor to halt it.
      6. Stop collectors, write STOP files, wait for jobs.
      7. Invoke analyze.py -> out/report.md and print pass/fail summary.
.EXAMPLE
    .\run_test.ps1
    .\run_test.ps1 -GgufPath "D:\models\medLLM_V1_sft_16bit-Q4_K_M.gguf"
#>
[CmdletBinding()]
param(
    # Default: look for a model.gguf in the same folder as this script.
    # Override with -GgufPath "C:\path\to\your.gguf".
    [string]$GgufPath = ".\model.gguf",

    [string]$Image = "llm-cpu-test:latest",
    [string]$Container = "llm-stress",

    [int]   $MemoryGB = 7,
    [int]   $Cpus = 4,
    [string]$CpuSet = "0-3",
    [int]   $WarnTempC = 80,
    [int]   $HaltTempC = 83,

    [string]$LhmApiUrl = "http://localhost:8085/data.json",

    [switch]$Smoke = $false
)
$ErrorActionPreference = "Stop"

$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo   = Split-Path -Parent $here
$outDir = Join-Path $here "out"
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

# --- preflight: image -------------------------------------------------------
# docker image inspect returns "No such image" on stderr -> PowerShell w/
# ErrorActionPreference=Stop treats that as a terminating error. Use `docker
# images -q` instead - it returns empty string + exit 0 silently when no match.
$imgId = (docker images -q $Image 2>$null | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($imgId)) {
    Write-Host "Image '$Image' not found. Run .\build.ps1 first." -ForegroundColor Red
    exit 1
}
Write-Host ("Image OK: {0} (id {1})" -f $Image, $imgId.Substring(0, [Math]::Min(12, $imgId.Length))) -ForegroundColor DarkGray

# --- preflight: LHM --------------------------------------------------------
$preflight = & (Join-Path $here "check_lhm.ps1") -ApiUrl $LhmApiUrl
if ($LASTEXITCODE -ne 0) {
    Write-Host "Preflight (check_lhm.ps1) failed. Aborting." -ForegroundColor Red
    Write-Host $preflight
    exit $LASTEXITCODE
}
Write-Host $preflight -ForegroundColor DarkGray

# --- preflight: GGUF -------------------------------------------------------
# Resolve to an absolute path so Docker mount works regardless of PWD.
if (-not (Test-Path -LiteralPath $GgufPath)) {
    Write-Host "Model GGUF not found at: $GgufPath" -ForegroundColor Red
    Write-Host ""
    Write-Host "To fix:" -ForegroundColor Yellow
    Write-Host "  1. Place your .gguf file in the same folder as this script and rename it to 'model.gguf', OR"
    Write-Host "  2. Pass -GgufPath 'C:\path\to\your.gguf' when invoking run_test.ps1"
    Write-Host ""
    Write-Host "Example:"
    Write-Host "  .\run_test.ps1 -GgufPath 'C:\Users\me\Downloads\my-model-Q4_K_M.gguf' -LhmApiUrl 'http://localhost:8085/data.json'"
    exit 1
}
$GgufPath = (Resolve-Path -LiteralPath $GgufPath).ProviderPath
$ggufSize = (Get-Item -LiteralPath $GgufPath).Length
Write-Host ("GGUF: {0} ({1:N2} GB)" -f $GgufPath, ($ggufSize/1GB)) -ForegroundColor Green

# --- clean previous artifacts & container -----------------------------------
Get-ChildItem -Path $outDir -File -Filter "*.csv" -ErrorAction SilentlyContinue | Remove-Item -Force
Remove-Item -LiteralPath (Join-Path $outDir "STOP.collect") -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $outDir "halt_event.csv") -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $outDir "report.md")      -Force -ErrorAction SilentlyContinue
docker rm -f $Container 2>&1 | Out-Null

# --- preflight: idle temperature cooldown -----------------------------------
# Wait for CPU package temp to drop below $MaxIdleTempC before starting, so
# the test doesn't trip the halt on the first thermal sample. Timeout after
# $CooldownTimeoutSec seconds if cooling is not improving.
$MaxIdleTempC       = 75
$CooldownTimeoutSec = 180
Write-Host ("Waiting for idle CPU temp <= {0}C (max {1}s) before starting..." -f $MaxIdleTempC, $CooldownTimeoutSec) -ForegroundColor Cyan
function Get-IdleTemp {
    try {
        $resp = Invoke-RestMethod -Uri $LhmApiUrl -TimeoutSec 3 -ErrorAction Stop
        function Walk($n) {
            if (-not $n) { return $null }
            if ($n.HardwareId -and $n.HardwareId -match '/intelcpu/|/amdcpu/' -and $n.Children) {
                $tg = $null
                foreach ($c in $n.Children) { if ($c.Text -match '^Temperatures$') { $tg = $c; break } }
                if ($tg -and $tg.Children) {
                    # Intel: "CPU Package" | AMD: "Tctl/Tdie", "Tctl", "Tdie" | Generic: "Package"
                    # Use contains match so "Tctl/Tdie" is caught (AMD names it that way).
                    foreach ($s in $tg.Children) {
                        if ($s.Text -match 'CPU Package') {
                            $raw = [string]$s.Value
                            $m = [regex]::Match($raw, '^[-+]?[0-9]*\.?[0-9]+')
                            if ($m.Success) { return [double]$m.Value }
                        }
                    }
                    foreach ($s in $tg.Children) {
                        if ($s.Text -match 'Tctl') {
                            $raw = [string]$s.Value
                            $m = [regex]::Match($raw, '^[-+]?[0-9]*\.?[0-9]+')
                            if ($m.Success) { return [double]$m.Value }
                        }
                    }
                    foreach ($s in $tg.Children) {
                        if ($s.Text -match 'Tdie') {
                            $raw = [string]$s.Value
                            $m = [regex]::Match($raw, '^[-+]?[0-9]*\.?[0-9]+')
                            if ($m.Success) { return [double]$m.Value }
                        }
                    }
                    foreach ($s in $tg.Children) {
                        if ($s.Text -match 'Package') {
                            $raw = [string]$s.Value
                            $m = [regex]::Match($raw, '^[-+]?[0-9]*\.?[0-9]+')
                            if ($m.Success) { return [double]$m.Value }
                        }
                    }
                }
            }
            if ($n.Children) { foreach ($child in $n.Children) { $h = Walk $child; if ($h) { return $h } } }
            return $null
        }
        return Walk $resp
    } catch { return $null }
}
$startWait = Get-Date
$waitedSec = 0
$sampledIdle = $null
do {
    $sampledIdle = Get-IdleTemp
    if ($sampledIdle -ne $null) {
        Write-Host ("  idle temp = {0:F1} C (need <= {1} C)" -f $sampledIdle, $MaxIdleTempC) -ForegroundColor DarkGray
        if ($sampledIdle -le $MaxIdleTempC) { break }
    } else {
        Write-Host "  (cannot read temp)" -ForegroundColor DarkGray
    }
    Start-Sleep -Seconds 5
    $waitedSec = ((Get-Date) - $startWait).TotalSeconds
} while ($waitedSec -lt $CooldownTimeoutSec)
if ($sampledIdle -gt $MaxIdleTempC) {
    Write-Host ("WARN: idle temp still {0:F1} C after {1}s. Proceeding anyway (governor will halt if needed)." -f $sampledIdle, $CooldownTimeoutSec) -ForegroundColor Yellow
} else {
    Write-Host ("OK: idle temp {0:F1} C. Proceeding." -f $sampledIdle) -ForegroundColor Green
}

# --- start collectors -------------------------------------------------------
Write-Host "Starting thermal collector + docker stats sampler ..." -ForegroundColor Cyan
if (-not $Smoke) { Write-Host "Starting governor (watch_and_halt) ..." -ForegroundColor Cyan }
$collectorJob = Start-Job -FilePath (Join-Path $here "collect_thermal.ps1") -ArgumentList $outDir, 1, $LhmApiUrl
$watcherJob   = $null
if (-not $Smoke) {
    $watcherJob = Start-Job -FilePath (Join-Path $here "watch_and_halt.ps1")   -ArgumentList $outDir, $Container, $WarnTempC, $HaltTempC
} else {
    Write-Host "SMOKE MODE: governor DISABLED. Thermal data still collected; no halt will trigger. Use with caution." -ForegroundColor Yellow
}

$statsCsv = Join-Path $outDir "docker_stats.csv"
"name,cpu_pct,mem_usage,mem_pct,net_io,block_io,pids,ts_iso" | Out-File -FilePath $statsCsv -Encoding ascii -Force
$statsScript = {
    param($Container,$Csv)
    while (-not (Test-Path (Join-Path (Split-Path $Csv) "STOP.collect"))) {
        $line = (docker stats --no-stream --format "{{.Name}},{{.CPUPerc}},{{.MemUsage}},{{.MemPerc}},{{.NetIO}},{{.BlockIO}},{{.PIDs}}" $Container 2>$null)
        if ($line) {
            $line = ($line -replace '%','') -replace ' ',''
            Add-Content -LiteralPath $Csv -Value ("$line,$(Get-Date -Format o)") -Encoding ascii
        }
        Start-Sleep -Seconds 2
    }
}
$statsJob = Start-Job -ScriptBlock $statsScript -ArgumentList $Container, $statsCsv

# Start the test container.
# NOTE: llama-server is run inside the container on its own port 8080; we do NOT
# publish the port here - stress comes from `ab` inside the container (loopback).
Write-Host "Starting container '$Container' (memory=${MemoryGB}g, cpus=$Cpus, cpuset=$CpuSet) ..." -ForegroundColor Cyan
# In smoke mode, pass MODE=smoke env var to llm_run.sh so it only runs stage 1
# (single-shot MedQA prompt) and exits immediately after capturing model text.
$envArg = @()
if ($Smoke) { $envArg = @("-e", "MODE=smoke") }
# Native docker commands emit progress/warnings on stderr; under
# ErrorActionPreference=Stop those surface as terminating NativeCommandError.
# Wrap with local Continue so our explicit $LASTEXITCODE check governs failure.
$dockerRunOut = & { $ErrorActionPreference = 'Continue'; docker run -d `
    --name $Container `
    --memory="${MemoryGB}g" `
    --memory-swap="0" `
    --cpus=$Cpus `
    --cpuset-cpus=$CpuSet `
    @envArg `
    -v "${GgufPath}:/models/medLLM_V1_sft_16bit-Q4_K_M.gguf:ro" `
    -v "${outDir}:/out" `
    $Image 2>&1 }
$dockerRunRc = $LASTEXITCODE
Write-Host $dockerRunOut
if ($dockerRunRc -ne 0) {
    Write-Host "docker run failed. Stopping collectors and exiting." -ForegroundColor Red
    New-Item -ItemType File -Path (Join-Path $outDir "STOP.collect") -Force | Out-Null
    $collectorJob | Stop-Job -PassThru | Remove-Job
    if ($watcherJob) { $watcherJob | Stop-Job -PassThru | Remove-Job }
    $statsJob     | Stop-Job -PassThru | Remove-Job
    exit 1
}

# Wait for container to exit (it exits on test completion) or governor to halt it.
Write-Host "Container started. Waiting for llm_run.sh to finish (up to 20 min) ..." -ForegroundColor Cyan
$waited = 0; $maxWaitSec = 1200
while ($true) {
    $state = (docker inspect -f '{{.State.Running}}' $Container 2>$null)
    if ($state -ne "true") {
        Write-Host "Container stopped running (state=$state). Exit code will be read below." -ForegroundColor DarkGray
        break
    }
    if (Test-Path -LiteralPath (Join-Path $outDir "halt_event.csv")) {
        Write-Host "Thermal halt triggered (halt_event.csv present). Container should be stopping." -ForegroundColor Yellow
    }
    Start-Sleep -Seconds 3
    $waited += 3
    if ($waited -ge $maxWaitSec) {
        Write-Host "Wait timeout ($maxWaitSec s). Forcing stop." -ForegroundColor Red
        docker stop $Container 2>&1 | Out-Null
        break
    }
}

# Capture container exit code so analyze.py can flag a crash vs clean.
$exitCode = docker inspect -f '{{.State.ExitCode}}' $Container 2>$null
"container_exit_code,${exitCode}" | Out-File -FilePath (Join-Path $outDir "exit_code.csv") -Encoding ascii -Force

# --- teardown collectors ----------------------------------------------------
Write-Host "Stopping collectors ..." -ForegroundColor Cyan
New-Item -ItemType File -Path (Join-Path $outDir "STOP.collect") -Force | Out-Null
Start-Sleep -Seconds 2
$collectorJob | Stop-Job -PassThru | Remove-Job
if ($watcherJob) { $watcherJob | Stop-Job -PassThru | Remove-Job }
$statsJob     | Stop-Job -PassThru | Remove-Job

docker rm -f $Container 2>&1 | Out-Null

# --- analysis ---------------------------------------------------------------
Write-Host "Generating report ..." -ForegroundColor Cyan
$analyze = Join-Path $here "analyze.py"
if (Get-Command python -ErrorAction SilentlyContinue) {
    python $analyze $outDir
} elseif (Get-Command python3 -ErrorAction SilentlyContinue) {
    python3 $analyze $outDir
} elseif (Get-Command py -ErrorAction SilentlyContinue) {
    py -3 $analyze $outDir
} else {
    Write-Host "Python not found on PATH. Skipping report generation. Raw outputs are in $outDir." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Done. See:" -ForegroundColor Green
Write-Host "  $outDir\report.md" -ForegroundColor Green
Write-Host "  $outDir\thermal.csv  docker_stats.csv  llama_bench.out  single_shot.out  stress_ab.out  soak.out" -ForegroundColor DarkGray
Write-Host ""
if (Test-Path -LiteralPath (Join-Path $outDir "halt_event.csv")) {
    Write-Host "RESULT: HALTED by thermal governor. Review halt_event.csv." -ForegroundColor Red
    exit 3
}
if ($exitCode -ne "0" -and $exitCode -ne "137") {
    Write-Host "RESULT: container exited with code $exitCode (may indicate OOM or error)." -ForegroundColor Yellow
}
Write-Host "RESULT: OK - container finished normally." -ForegroundColor Green