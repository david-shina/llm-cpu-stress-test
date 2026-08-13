<#
.SYNOPSIS
    One-shot bootstrap for the llm-cpu-stress-test.
.DESCRIPTION
    Walks a fresh user from clone -> results without needing to read the README.
    Performs prerequisite checks, prompts for anything missing, auto-builds the
    Docker image if needed, and delegates to run_test.ps1.

    Can be fully non-interactive if all parameters are supplied:
        .\run.ps1 -Smoke -LhmApiUrl "http://localhost:8085/data.json" -GgufPath ".\model.gguf"
.EXAMPLE
    .\run.ps1
    .\run.ps1 -Smoke
    .\run.ps1 -GgufPath "D:\models\my.gguf" -LhmApiUrl "http://192.168.1.50:8085/data.json"
#>
[CmdletBinding()]
param(
    [switch]$Smoke = $false,
    [string]$LhmApiUrl = "",
    [string]$GgufPath = ""
)
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $here

function Write-Step  { param($t) Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Write-OK    { param($t) Write-Host "  [OK] $t" -ForegroundColor Green }
function Write-Fail  { param($t) Write-Host "  [FAIL] $t" -ForegroundColor Red }
function Write-Hint  { param($t) Write-Host "  $t" -ForegroundColor Yellow }

# -----------------------------------------------------------------------------
Write-Step "Prerequisite: Docker Desktop"
$dockerOk = $false
try { $null = docker ps 2>&1; if ($LASTEXITCODE -eq 0) { $dockerOk = $true } } catch {}
if ($dockerOk) {
    Write-OK "Docker daemon is running."
} else {
    Write-Fail "Docker daemon is not reachable."
    Write-Hint "Start Docker Desktop from the Start Menu, wait until the tray icon says 'running', then re-run this script."
    exit 1
}

# -----------------------------------------------------------------------------
Write-Step "Prerequisite: Python 3"
$pyOk = $false
foreach ($py in @("python","python3","py")) {
    $v = & $py --version 2>&1
    if ($LASTEXITCODE -eq 0 -and ($v -match "Python 3")) { $pyOk = $true; Write-OK "$py -> $v"; break }
}
if (-not $pyOk) {
    Write-Fail "Python 3 not found on PATH."
    Write-Hint "Install from https://www.python.org/downloads/ (check 'Add Python to PATH'), restart PowerShell, re-run."
    exit 1
}

# -----------------------------------------------------------------------------
Write-Step "Prerequisite: LibreHardwareMonitor API"
if ($LhmApiUrl -ne "") {
    Write-Host "  Using provided LHM URL: $LhmApiUrl"
    $url = $LhmApiUrl
} else {
    # Try localhost first
    $url = "http://localhost:8085/data.json"
    try { $null = Invoke-RestMethod -Uri $url -TimeoutSec 3 -ErrorAction Stop; Write-OK "LHM at localhost:8085 reachable" }
    catch {
        Write-Host "  localhost:8085 did not respond. Your LAN IPs:"
        $ips = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -match '^192\.168|^10\.' }).IPAddress
        if (-not $ips) { $ips = @("192.168.x.x") }
        foreach ($ip in $ips) { Write-Host "    $ip  ->  http://${ip}:8085/data.json" }
        $typed = Read-Host "  Paste LHM API URL (or Enter to abort)"
        if ([string]::IsNullOrWhiteSpace($typed)) {
            Write-Fail "No LHM URL provided. Launch LibreHardwareMonitor as admin (enable Web Server on port 8085), then re-run."
            exit 1
        }
        $url = $typed.Trim('"').Trim("'")
    }
}
# Validate the chosen URL via check_lhm.ps1
$chk = & (Join-Path $here "check_lhm.ps1") -ApiUrl $url 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host $chk
    Write-Fail "LHM preflight failed for $url"
    Write-Hint "Launch LibreHardwareMonitor as Administrator, enable Web Server on port 8085, then re-run."
    exit 1
}
Write-Host $chk -ForegroundColor DarkGray

# -----------------------------------------------------------------------------
Write-Step "Locate GGUF model file"
if ($GgufPath -ne "") {
    Write-Host "  Using provided GGUF: $GgufPath"
    if (-not (Test-Path -LiteralPath $GgufPath)) {
        Write-Fail "File not found: $GgufPath"
        exit 1
    }
} else {
    # Look for model.gguf or any single *.gguf in the script folder.
    $modelDefault = Join-Path $here "model.gguf"
    $candidates   = Get-ChildItem -Path $here -Filter "*.gguf" -File -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $modelDefault) {
        $GgufPath = $modelDefault; Write-OK "Found model.gguf in this folder"
    } elseif ($candidates -and $candidates.Count -eq 1) {
        $GgufPath = $candidates[0].FullName; Write-OK "Found $($candidates[0].Name)"
    } else {
        Write-Host "  No .gguf file found in this folder."
        $typed = Read-Host "  Drag your .gguf file here, or paste its full path"
        if ([string]::IsNullOrWhiteSpace($typed)) {
            Write-Fail "No GGUF provided. Obtain a llama.cpp-compatible GGUF, place it here (or pass -GgufPath), re-run."
            exit 1
        }
        $GgufPath = $typed.Trim('"').Trim("'")
        if (-not (Test-Path -LiteralPath $GgufPath)) { Write-Fail "Not found: $GgufPath"; exit 1 }
    }
}
$sizeGB = [math]::Round((Get-Item -LiteralPath $GgufPath).Length / 1GB, 2)
Write-OK "GGUF: $GgufPath ($sizeGB GB)"

# -----------------------------------------------------------------------------
Write-Step "Docker image: llm-cpu-test:latest"
$imgId = (docker images -q llm-cpu-test:latest 2>$null | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($imgId)) {
    Write-Host "  Image not found. Auto-building (~10 min, first time only) ..."
    & (Join-Path $here "build.ps1")
    if ($LASTEXITCODE -ne 0) { Write-Fail "build.ps1 failed"; exit 1 }
} else {
    Write-OK "Image already built (id $($imgId.Substring(0,[Math]::Min(12,$imgId.Length))))"
}

# -----------------------------------------------------------------------------
Write-Step "Select test mode"
$runSmoke = $Smoke
if (-not $Smoke) {
    Write-Host "  [1] Smoke  - single prompt, no governor, ~2 min  (best first run)"
    Write-Host "  [2] Full   - 4 stages with thermal governor, 3-6 min"
    $choice = Read-Host "  Choose 1 or 2 (Enter = 1)"
    if ($choice -eq "2" -or $choice -match "full") { $runSmoke = $false }
    else { $runSmoke = $true }
}

# -----------------------------------------------------------------------------
Write-Step "Running test ($(if ($runSmoke) {'smoke'} else {'full'}))"
$runArgs = @("-LhmApiUrl", $url, "-GgufPath", $GgufPath)
if ($runSmoke) { $runArgs += "-Smoke" }
& (Join-Path $here "run_test.ps1") @runArgs
$testRc = $LASTEXITCODE

# -----------------------------------------------------------------------------
Write-Step "Done"
$report = Join-Path $here "out\report.md"
if (Test-Path -LiteralPath $report) {
    Write-Host "  Report: $report"
    Write-Host "  Quick view: cat .\out\report.md"
    Write-Host ""
    Write-Host "  --- report.md (tail) ---" -ForegroundColor DarkGray
    Get-Content -LiteralPath $report -Tail 20 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
} else {
    Write-Host "  No report was produced. Check out\ for raw artifacts."
}
if ($testRc -eq 3) { Write-Hint "Test was halted by thermal governor (see out\halt_event.csv)." }
exit $testRc