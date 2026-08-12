<#
.SYNOPSIS
    Host-side CPU temperature sampler.
.DESCRIPTION
    Polls the LibreHardwareMonitor REST API (default http://localhost:8085/data.json;
    override with -ApiUrl) once per second and appends rows to docker/out/thermal.csv:
        timestamp_iso,temp_c,sensor_name
    Runs in the background under run_test.ps1 (Start-Job). Stops when the file
    `docker/out/STOP.collect` is created (signal from the orchestrator).
.NOTES
    LibreHardwareMonitor exposes a NESTED tree (see check_lhm.ps1 for the structure).
    We recursively locate the CPU node via HardwareId, then its Temperatures group,
    then the "CPU Package" sensor. Polling interval deliberately 1s because the
    disqual cap is 85C and halt threshold is 83C; 2s risks missing the trigger window.
#>
[CmdletBinding()]
param(
    [string]$OutDir = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "out"),
    [int]   $IntervalSec = 1,
    [string]$ApiUrl = "http://localhost:8085/data.json"
)
$ErrorActionPreference = "Continue"

if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$csv = Join-Path $OutDir "thermal.csv"
$stopFile = Join-Path $OutDir "STOP.collect"

"timestamp_iso,temp_c,sensor_name" | Out-File -FilePath $csv -Encoding ascii -Force

function Find-CpuPackageTemp {
    param($Node)
    if (-not $Node) { return $null }
    $isCpu = $false
    if ($Node.HardwareId -and $Node.HardwareId -match '/intelcpu/|/amdcpu/') { $isCpu = $true }
    elseif ($Node.Text -match 'Intel Core i[3579]|AMD Ryzen|AMD EPYC|12th Gen Intel|13th Gen Intel|11th Gen Intel|10th Gen Intel') { $isCpu = $true }
    if ($isCpu -and $Node.Children) {
        $tempGroup = $null
        foreach ($c in $Node.Children) { if ($c.Text -and $c.Text -match '^Temperatures$') { $tempGroup = $c; break } }
        if ($tempGroup -and $tempGroup.Children) {
            foreach ($s in $tempGroup.Children) {
                if ($s.Text -and $s.Text -match '^CPU Package$|^Tctl$|^CPU$') { return $s }
            }
            foreach ($s in $tempGroup.Children) {
                if ($s.Text -and $s.Text -match 'Package|Tctl') { return $s }
            }
        }
    }
    if ($Node.Children) {
        foreach ($child in $Node.Children) {
            $hit = Find-CpuPackageTemp -Node $child
            if ($hit) { return $hit }
        }
    }
    return $null
}

function Get-CpuTemp {
    try {
        $resp = Invoke-RestMethod -Uri $ApiUrl -TimeoutSec 3 -ErrorAction Stop
    } catch { return $null }
    $s = Find-CpuPackageTemp -Node $resp
    if (-not $s) { return $null }
    # LHM's Value field can be either a bare number ("61.0") or a string with a unit suffix ("72.0 C").
    $raw = [string]$s.Value
    $m = [regex]::Match($raw, '^[-+]?[0-9]*\.?[0-9]+')
    if (-not $m.Success) { return $null }
    return [pscustomobject]@{ Value = [double]$m.Value; Name = [string]$s.Text }
}

while (-not (Test-Path -LiteralPath $stopFile)) {
    $t = Get-CpuTemp
    if ($t) {
        $row = "{0:O},{1:F1},{2}" -f (Get-Date), $t.Value, $t.Name
        Add-Content -LiteralPath $csv -Value $row -Encoding ascii
    } else {
        Add-Content -LiteralPath $csv -Value ("{0:O},," -f (Get-Date)) -Encoding ascii
    }
    Start-Sleep -Seconds $IntervalSec
}

Write-Host "collect_thermal: stop signal received, exiting." -ForegroundColor Yellow